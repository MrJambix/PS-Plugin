-- The CASC reader against the synthetic store in mock/casc_fixture.lua.
-- Every structure there is built byte by byte, so a layout mistake in the
-- reader is a failing test and not a mystery in the game.

local mock = require("mock_core")
mock.install()

local inflate = require("jcore/lib/inflate")
local make_casc = require("jcore/services/casc")
local fixture = require("casc_fixture")

local rep, floor = string.rep, math.floor

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- Hex of a 32-bit value that may be a float: the harness's %x refuses
--- anything past 2^31.
local function h32(v)
    return string.format("%04x%04x", floor(v / 65536), v % 65536)
end
local function unhex(h) return (h:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end)) end

local function fake_rt()
    local logged = {}
    local store = { data = {}, touches = 0 }
    function store:touch() self.touches = self.touches + 1 end
    local rt = {
        inflate = inflate,
        storage = { store = function() return store end },
        log = { for_tag = function()
            return { fmt = function(level, f, ...) logged[#logged + 1] = level .. ": " .. string.format(f, ...) end }
        end },
    }
    return rt, store, logged
end

local TARGET, OTHER, UNLOCAL, ABSENT = fixture.TARGET, fixture.OTHER, fixture.UNLOCAL, fixture.ABSENT

local T = {}

T[#T + 1] = { "jenkins lookup3 matches the reference vectors", function()
    local casc = make_casc(fake_rt())
    local function check(s, pc, pb)
        local c, b = casc.hashlittle2(s)
        assert_eq(h32(c), pc, "pc of " .. s)
        assert_eq(h32(b), pb, "pb of " .. s)
    end
    check("", "deadbeef", "deadbeef")
    check("Four score and seven years ago", "17770551", "ce7226e6")
    check("a", "58d68708", "582647ac")
    check("abcdefghijklm", "928128f9", "0f04ab68")
    -- name hashes: upper-cased, backslashed, low word first in the file
    local h1 = casc.name_hash("Interface/Icons/ClassIcon_Warrior.blp")
    assert_eq(fixture.hex(h1), "8c83628439efdb58", "ClassIcon_Warrior, as the real root stores it")
    assert_eq(fixture.hex(casc.name_hash("Interface/Glues/CharacterCreate/UI-CharacterCreate-Classes.blp")),
        "00e51bd0bacecbfe", "class sheet")
    local h2 = casc.name_hash("interface\\icons\\CLASSICON_WARRIOR.BLP")
    assert(h1 == h2, "case and slashes are normalised")
end }

T[#T + 1] = { "index bucket of an encoded key", function()
    local casc = make_casc(fake_rt())
    local b = casc._internal.bucket_of
    assert_eq(b(unhex("f4e084a5058076e751")), 7, "the real client's encoding key")
    assert_eq(b(unhex("80f22a1ff423dcb517")), 0, "the real class sheet")
    assert_eq(b(unhex("ed7373250cf0402250")), 6, "the real root")
    assert_eq(b(rep("\0", 9)), 0, "zero key")
end }

T[#T + 1] = { "32-bit helpers", function()
    local casc = make_casc(fake_rt())
    local i = casc._internal
    assert_eq(h32(i.xor32(4294967295, 252645135)), "f0f0f0f0", "xor32")
    assert_eq(i.xor32(2147483648, 2147483648), 0, "xor32 high bit")
    assert_eq(i.xor32(-1, 0), 4294967295, "xor32 folds a negative")
    assert_eq(i.rot32(1, 1), 2, "rot32 1")
    assert_eq(i.rot32(2 ^ 31, 1), 1, "rot32 wraps")
    assert_eq(h32(i.rot32(305419896, 8)), "34567812", "rot32 8")
    assert_eq(i.cmp("\0\1", "\0\2"), -1, "cmp lt")
    assert_eq(i.cmp("\255\0", "\1\0"), 1, "cmp unsigned")
    assert_eq(i.cmp("ab", "ab"), 0, "cmp eq")
end }

T[#T + 1] = { ".build.info and the build config parse", function()
    local casc = make_casc(fake_rt())
    local rows = casc._internal.parse_build_info(
        "A!STRING:0|Build Key!HEX:16|Product!STRING:0\nx|abc|wow\ny|def|wow_classic_era\n")
    assert_eq(#rows, 2, "rows")
    assert_eq(rows[2]["Build Key"], "def", "cell")
    assert_eq(rows[2].Product, "wow_classic_era", "product")
    local cfg = casc._internal.parse_config("# c\nroot = abc\nencoding = 11 22\nencoding-size = 1 2\n")
    assert_eq(cfg.root, "abc", "root"); assert_eq(cfg.encoding, "11 22", "encoding")
end }

T[#T + 1] = { "without a CASC client the reader says so and nothing raises", function()
    local casc = make_casc(fake_rt())
    mock.wow_fs = {}
    local ok, why = casc.available()
    assert_eq(ok, false, "available")
    assert(why and why:find("build.info", 1, true), tostring(why))
    local bytes, err, permanent = casc.read(TARGET)
    assert(not bytes and err, "read fails")
    assert_eq(permanent, false, "not permanent: the client may just be starting")
end }

T[#T + 1] = { "a full walk: build, index, encoding, root, archive, in two chunk shapes", function()
    local rt, store = fake_rt()
    local casc = make_casc(rt)
    mock.wow_fs = {}
    local fx = fixture.build_store(casc, mock.wow_fs)

    local ok, why = casc.available()
    assert(ok, tostring(why))
    assert_eq(casc.build().product, "wow_classic_era", "product row picked by the Active flag")
    assert_eq(store.data.build, fixture.BUILD_KEY, "store keyed by build")

    -- the pieces on their own
    local entry = casc._internal.find_local(fx.enc_ekey)
    assert(entry and entry.archive == 0, "encoding is in archive 0")
    local ekey = casc._internal.ckey_to_ekey(fx.target_ckey)
    assert_eq(ekey, fx.target_ekey, "ckey -> ekey through the straddled page table")

    -- both paths registered before the first read: one scan answers both
    casc.want(OTHER)
    local steps = 0
    local function step() steps = steps + 1 end
    local bytes, err = casc.read(TARGET, step)
    assert(bytes, tostring(err))
    assert(bytes == fixture.TARGET_BYTES, "target bytes (headerless zlib container)")
    assert(steps > 0, "step was called")

    local s = casc.stats()
    assert_eq(s.scans, 1, "one root scan")
    assert_eq(s.root_version, 2, "root version")
    assert_eq(s.root_blocks, 2, "root blocks")

    local other, err2 = casc.read(OTHER)
    assert(other == fixture.OTHER_BYTES, tostring(err2) .. " (two raw chunks)")
    assert_eq(casc.stats().scans, 1, "the same scan answered every wanted path")

    local looked = casc.lookup(TARGET)
    assert(looked and looked.fdid == 100 and looked.archive == 1, "lookup: fdid and archive")
    assert_eq(casc.lookup(OTHER).fdid, 101, "other fdid")
    assert_eq(casc.lookup(UNLOCAL), nil, "a path nobody asked for is unknown, not missing")

    local none, err3, permanent = casc.read(UNLOCAL)
    assert(not none and permanent, "not local is permanent: " .. tostring(err3))
    assert_eq(casc.stats().scans, 2, "a path never asked for costs one more scan")
    assert_eq(casc.lookup(UNLOCAL), false, "in the root but not local is remembered as missing")
    none, err3, permanent = casc.read(ABSENT)
    assert(not none and permanent, "absent is permanent: " .. tostring(err3))
    assert_eq(casc.stats().scans, 3, "and so does the next")
    assert_eq(casc.lookup(ABSENT), false, "absent remembered")
    none, err3, permanent = casc.read(ABSENT)
    assert(not none and permanent, "still absent")
    assert_eq(casc.stats().scans, 3, "remembered: no scan the second time")

    local saved = store.data.files[casc.key(TARGET)]
    assert(saved and saved.ekey == fx.target_ekey and saved.size > 0, "persisted entry")
    assert(store.touches > 0, "store touched")
    assert_eq(store.data.idx_versions[1], fx.versions[0], "index versions persisted")
end }

T[#T + 1] = { "a second session reads from the store without a scan", function()
    local rt, store = fake_rt()
    local casc = make_casc(rt)
    mock.wow_fs = {}
    fixture.build_store(casc, mock.wow_fs)
    assert(casc.read(TARGET), "first session")

    local rt2, store2 = fake_rt()
    store2.data = store.data
    local casc2 = make_casc(rt2)
    local bytes = casc2.read(TARGET)
    assert(bytes == fixture.TARGET_BYTES, "read from the persisted entry")
    assert_eq(casc2.stats().scans, 0, "no scan")
end }

T[#T + 1] = { "a new client build empties the store", function()
    local rt, store = fake_rt()
    local casc = make_casc(rt)
    mock.wow_fs = {}
    fixture.build_store(casc, mock.wow_fs)
    assert(casc.read(TARGET), "first build")

    local rt2, store2 = fake_rt()
    store2.data = store.data
    store2.data.build = "0000000000000000000000000000dead"
    local casc2 = make_casc(rt2)
    assert(casc2.available(), "available")
    assert_eq(next(store2.data.files), nil, "files dropped")
    assert(casc2.read(TARGET), "resolves again")
    assert_eq(casc2.stats().scans, 1, "one scan after the reset")
end }

T[#T + 1] = { "legacy and version-1 root layouts", function()
    for _, v in ipairs({ 0, 1 }) do
        local casc = make_casc(fake_rt())
        mock.wow_fs = {}
        fixture.build_store(casc, mock.wow_fs, { root_version = v })
        local bytes, err = casc.read(TARGET)
        assert(bytes == fixture.TARGET_BYTES, "root v" .. v .. ": " .. tostring(err))
        assert_eq(casc.stats().root_version, v, "detected version")
    end
end }

T[#T + 1] = { "index versions fall back to probing when shmem is useless", function()
    local casc = make_casc(fake_rt())
    mock.wow_fs = {}
    fixture.build_store(casc, mock.wow_fs)
    mock.wow_fs["Data/data/shmem"] = rep("\255", 0x150)
    local bytes, err = casc.read(TARGET)
    assert(bytes == fixture.TARGET_BYTES, tostring(err))
end }


-- --- where the install root is, and why it would not open --------------------------

T[#T + 1] = { "a loader that resolves from the client folder: the root is found one level up", function()
    local rt, store = fake_rt()
    local casc = make_casc(rt)
    local laid = {}
    fixture.build_store(casc, laid)
    mock.wow_fs = {}
    for path, bytes in pairs(laid) do mock.wow_fs["../" .. path] = bytes end

    assert(casc.available(), "the archives open")
    assert_eq(casc.stats().root, "../", "through ../")
    assert_eq(store.data.root, "../", "remembered")
    local bytes = casc.read(fixture.TARGET)
    assert_eq(bytes, fixture.TARGET_BYTES, "and every read goes through it")
end }

T[#T + 1] = { "nothing opens: the reason and what the loader will open are saved, once", function()
    local rt, store, logged = fake_rt()
    rt.assets = { flavor = function() return "_classic_era_" end }
    rt.world = { game_version = function() return "Vanilla" end }
    mock.wow_fs = { ["_classic_era_/WTF/Config.wtf"] = "x" }
    local casc = make_casc(rt)

    assert(not casc.available(), "not readable")
    local d = casc.diagnosis()
    assert(d, "a diagnosis")
    assert(tostring(d.error):find(".build.info", 1, true), "the error names the file")
    assert_eq(d.client_folder, "_classic_era_", "the client folder")
    assert_eq(d.game_version, "Vanilla", "the client")
    assert(store.touches > 0, "saved to disk")

    local by = {}
    for i = 1, #d.probes do by[d.probes[i].path] = d.probes[i] end
    assert(by[".build.info"] and by[".build.info"].readable == false, "the root's .build.info: not readable")
    assert(by["../.build.info"], "one level up was tried")
    local control = by["_classic_era_/WTF/Config.wtf"]
    assert(control and control.readable == true and control.size == 1, "a file the loader does open, as a control")

    local warnings = 0
    for i = 1, #logged do if logged[i]:find("not readable", 1, true) then warnings = warnings + 1 end end
    casc.available()
    local again = 0
    for i = 1, #logged do if logged[i]:find("not readable", 1, true) then again = again + 1 end end
    assert_eq(warnings, 1, "warned once")
    assert_eq(again, 1, "not again")
end }

T[#T + 1] = { "nothing opens, for the same reason as last session: debug only; a new reason is said", function()
    -- 1.8.3: this user's loader can never read the archives, and every
    -- session warned about it again.
    local function count(logged, prefix)
        local n = 0
        for i = 1, #logged do
            if logged[i]:find("not readable", 1, true) and logged[i]:sub(1, #prefix) == prefix then n = n + 1 end
        end
        return n
    end
    mock.wow_fs = {}
    local rt, store, logged = fake_rt()
    rt.world = { game_version = function() return "Forever" end }
    store.data.diagnosis = { error = ".build.info is not readable (is this a CASC client?)" }
    local casc = make_casc(rt)
    assert(not casc.available(), "not readable")
    assert_eq(count(logged, "debug: "), 1, "said at debug")
    assert_eq(#logged - count(logged, "debug: "), 0, "and at nothing louder")
    assert(casc.diagnosis() and casc.diagnosis().game_version == "Forever", "this session's diagnosis is saved")

    local rt2, store2, logged2 = fake_rt()
    store2.data.diagnosis = { error = "build config 0123 is not readable" }
    local casc2 = make_casc(rt2)
    assert(not casc2.available(), "not readable")
    assert_eq(count(logged2, "info: "), 1, "a different reason from last time is said at info")
end }

T[#T + 1] = { "the archives open: an old diagnosis is cleared", function()
    local rt, store = fake_rt()
    store.data.diagnosis = { error = "from a session where nothing opened" }
    local casc = make_casc(rt)
    mock.wow_fs = {}
    fixture.build_store(casc, mock.wow_fs)
    assert(casc.available(), "the archives open")
    assert_eq(casc.diagnosis(), nil, "the old reason is gone")
    assert_eq(casc.stats().root, "", "at the plain root")
end }

return T

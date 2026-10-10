-- JCore 1.5.15: the Forever client's own creature cache (services/creatures).
-- The real file the Forever beta wrote (build 70205, 16 creatures) is parsed
-- as it is, then records built here check what the real file has none of:
-- an elite, a rare, a record whose layout does not add up. Then the service
-- is booted as Forever and finds the file in the client folder by itself.
--
-- Era never reads it: jcore_era_client_test.lua.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
package.loaded["common/utility/spell_helper"] = {
    is_spell_castable = function() return false end,
}
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

local floor = math.floor

local function le32(v)
    return string.char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256)
end

--- One creature record, laid out as the client writes it.
local function encode(rec)
    local bitbuf = {}
    local function put(v, n)
        for k = n - 1, 0, -1 do bitbuf[#bitbuf + 1] = floor(v / 2 ^ k) % 2 end
    end
    put(rec.title and (#rec.title + 1) or 0, 11)
    put(0, 11)
    put(0, 6)
    put(rec.leader and 1 or 0, 1)
    put(#rec.name + 1, 11)
    put(0, 11)
    for _ = 2, 4 do put(0, 11); put(0, 11) end
    local bytes = {}
    for k = 1, #bitbuf, 8 do
        local v = 0
        for j = 0, 7 do v = v * 2 + (bitbuf[k + j] or 0) end
        bytes[#bytes + 1] = string.char(v)
    end
    local one = 0x3f800000
    local s = table.concat(bytes) .. rec.name .. "\0"
        .. le32(rec.flags or 0) .. le32(0) .. le32(0)
        .. string.char(rec.ctype) .. le32(rec.family or 0) .. string.char(rec.rank)
        .. le32(0) .. le32(0)
    local n = rec.displays or 1
    s = s .. le32(n) .. le32(one)
    for k = 1, n do s = s .. le32(1000 + k) .. le32(one) .. le32(one) end
    local q = rec.quest_items or {}
    s = s .. le32(one) .. le32(one) .. le32(#q) .. le32(0) .. string.rep(le32(0), 8)
    if rec.title then s = s .. rec.title .. "\0" end
    for k = 1, #q do s = s .. le32(q[k]) end
    return s .. (rec.extra or "")
end

local function cache_file(records)
    local s = "BOMW" .. le32(70205) .. "SUne" .. le32(688) .. le32(4) .. le32(0)
    for _, rec in ipairs(records) do
        local body = encode(rec)
        s = s .. le32(rec.id) .. le32(#body) .. body
    end
    return s
end

local real = assert(jtest.read_file("tools/jtest/mock/fixtures/forever_creaturecache_70205.wdb"),
    "the fixture is missing")

-- As the loader has it in the game: the sandbox is the client folder itself
-- (answered on Era, 2026-10-02), so the client's files sit at its root.
mock.wow_fs["WTF/Config.wtf"] = 'SET textLocale "enUS"\nSET audioLocale "enUS"\n'

local JCore, ctx, parse

local T = {}

T[#T + 1] = { "boot as Forever", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    JCore = _G.JCore
    mock.frame(3)
    fail_on_errors("boot")
    ctx = JCore.register({ id = "jtest.creatures", name = "Creatures test", version = "1.0.0" })
    assert(ctx.creatures, "ctx.creatures is handed to plugins")
    parse = JCore.creatures._parse
    assert(type(parse) == "function", "the parser is reachable")
end }

T[#T + 1] = { "the real Forever cache: 16 creatures, every one in the known layout", function()
    local rows, build, locale, count, unchecked = parse(real)
    assert(rows, "parsed: " .. tostring(build))
    assert_eq(build, 70205, "build")
    assert_eq(locale, "enUS", "locale")
    assert_eq(count, 16, "records")
    assert_eq(unchecked, 0, "records outside the layout")
    assert_eq(rows[705].name, "Ragged Young Wolf", "705")
    assert_eq(rows[705].type, 1, "a wolf is a beast")
    assert_eq(rows[705].family, 1, "of the wolf family")
    assert_eq(rows[705].classification, 0, "normal")
    assert(rows[705].quest_items and #rows[705].quest_items == 1, "it drops one quest item")
    assert_eq(rows[707].name, "Rockjaw Trogg", "707")
    assert_eq(rows[707].type, 7, "humanoid")
    assert_eq(rows[416].name, "Imp", "416")
    assert_eq(rows[416].type, 3, "a demon")
    assert_eq(rows[416].family, 23, "of the imp family")
    assert_eq(rows[708].family, 5, "a boar")
    assert_eq(rows[721].type, 8, "a rabbit is a critter")
    assert_eq(rows[267279].name, "Cadoc Winterheart", "a Forever-only npc id")
    assert_eq(rows[267279].title, "Mountaineer's Assistant", "with its title")
    assert_eq(rows[5595].name, "Ironforge Guard", "four models")
    for id, r in pairs(rows) do
        assert(r.checked, "record " .. tostring(id) .. " holds to the layout")
    end
end }

T[#T + 1] = { "the real Era cache (build 70003): every record in Era's layout, tameable and family (JCore 1.8.6)", function()
    local era = assert(jtest.read_file("tools/jtest/mock/fixtures/era_creaturecache_70003.wdb"), "the Era fixture")
    local rows, build, locale, count, unchecked, layout = parse(era)
    assert(rows, "parsed: " .. tostring(build))
    assert_eq(build, 70003, "build")
    assert_eq(layout, "Era 70003", "the layout chosen")
    assert_eq(unchecked, 0, "every record holds to its exact length")
    assert(count > 900, "the whole file: " .. tostring(count))
    assert_eq(rows[3566].name, "Flatland Prowler", "3566")
    assert_eq(rows[3566].tameable, true, "tameable")
    assert_eq(rows[3566].family, 2, "a cat")
    assert_eq(rows[3631].family, 27, "Deviate Stinglash: a wind serpent")
    assert_eq(rows[3631].classification, 1, "elite")
    assert_eq(rows[4310].type, 7, "Cor Grimtotem is humanoid")
    assert_eq(rows[4310].tameable, false, "and cannot be tamed")
    assert_eq(rows[3032].title, "Shaman Trainer", "a title read past Era's extra header bit")

    local _, _, _, _, _, flayout = parse(real)
    assert_eq(flayout, "Forever 70205", "the Forever file keeps its own layout")
end }

T[#T + 1] = { "ranks, titles and quest items from records built to the layout", function()
    local file = cache_file({
        { id = 1001, name = "Mottled Boar", ctype = 1, family = 5, rank = 0 },
        { id = 1002, name = "Kobold Taskmaster", ctype = 7, rank = 1, title = "Foreman", quest_items = { 1234, 5678 } },
        { id = 1003, name = "Mother Fang", ctype = 1, family = 3, rank = 4, displays = 3 },
        { id = 1004, name = "Hogger", ctype = 7, rank = 2, leader = true },
        { id = 1005, name = "Onyxia", ctype = 2, rank = 3 },
    })
    local rows, _, _, count, unchecked = parse(file)
    assert_eq(count, 5, "records")
    assert_eq(unchecked, 0, "all hold")
    assert_eq(rows[1002].classification, 1, "elite")
    assert_eq(rows[1002].title, "Foreman", "title")
    assert_eq(rows[1002].quest_items[2], 5678, "second quest item")
    assert_eq(rows[1003].classification, 4, "rare")
    assert_eq(rows[1003].family, 3, "after three models")
    assert_eq(rows[1004].classification, 2, "rare elite")
    assert_eq(rows[1004].leader, true, "leader bit")
    assert_eq(rows[1005].classification, 3, "boss")
end }

T[#T + 1] = { "a record that does not add up keeps its name and loses its rank", function()
    local file = cache_file({
        { id = 2001, name = "Longer Than It Says", ctype = 7, rank = 1, extra = "\1\2\3" },
        { id = 2002, name = "Odd Rank", ctype = 7, rank = 9 },
        { id = 2003, name = "Fine", ctype = 7, rank = 1 },
    })
    local rows, _, _, count, unchecked = parse(file)
    assert_eq(count, 3, "records")
    assert_eq(unchecked, 2, "two outside the layout")
    assert_eq(rows[2001].name, "Longer Than It Says", "name kept")
    assert_eq(rows[2001].classification, nil, "no rank from a record that does not add up")
    assert_eq(rows[2002].classification, nil, "no rank out of range")
    assert_eq(rows[2003].classification, 1, "the next record is still read")
    -- Truncated mid-record: what came before stays.
    local cut = file:sub(1, #file - 10)
    local rows2, _, _, count2 = parse(cut)
    assert_eq(count2, 2, "the cut record is dropped")
    assert_eq(rows2[2002].name, "Odd Rank", "the earlier ones remain")
    assert_eq(parse("WMOB" .. string.rep("\0", 40)), nil, "a wrong magic is refused")
    assert_eq(parse("BOM"), nil, "a short file is refused")
end }

T[#T + 1] = { "the service finds the file in the client folder and answers by npc id", function()
    mock.wow_fs["Cache/WDB/enUS/creaturecache.wdb"] = real
    local n = ctx.creatures.load(true)
    if n ~= 16 then
        local st = ctx.creatures.stats()
        error("read " .. tostring(n) .. ": " .. tostring(st.error) .. " tried " .. table.concat(st.tried or {}, ", "))
    end
    local st = ctx.creatures.stats()
    assert_eq(st.path, "Cache/WDB/enUS/creaturecache.wdb", "path")
    assert_eq(st.build, 70205, "build")
    assert_eq(ctx.creatures.name(705), "Ragged Young Wolf", "name")
    assert_eq(ctx.creatures.classification(705), 0, "normal")
    assert_eq(ctx.creatures.info(99999), nil, "an unknown id")
    assert_eq(ctx.creatures.info(nil), nil, "no id")
    fail_on_errors("load")
end }

T[#T + 1] = { "classification_of: the client's answer first, the cache's when it says 0", function()
    mock.wow_fs["Cache/WDB/enUS/creaturecache.wdb"] = cache_file({
        { id = 3001, name = "Elite Guard", ctype = 7, rank = 1 },
    })
    ctx.creatures.load(true)
    local function unit(native, npc)
        return {
            get_classification = function() return native end,
            get_npc_id = function() return npc end,
        }
    end
    assert_eq(ctx.creatures.classification_of(unit(0, 3001)), 1, "0 from the client, elite from the cache")
    assert_eq(ctx.creatures.classification_of(unit(4, 3001)), 4, "a real answer wins")
    assert_eq(ctx.creatures.classification_of(unit(0, 4242)), 0, "unknown stays normal")
    assert_eq(ctx.creatures.classification_of(nil), 0, "no unit")
end }

T[#T + 1] = { "no cache file: nothing known, and the reason kept", function()
    mock.wow_fs["Cache/WDB/enUS/creaturecache.wdb"] = nil
    assert_eq(ctx.creatures.load(true), 0, "nothing read")
    assert_eq(ctx.creatures.info(705), nil, "nothing known")
    local st = ctx.creatures.stats()
    assert_eq(st.error, "no creature cache found", "why")
    assert_eq(st.tried[#st.tried], "Cache/WDB/enUS/creaturecache.wdb", "the bare path was tried last")
    fail_on_errors("missing")
end }

return T

-- A synthetic CASC store, laid into mock.wow_fs byte by byte: .build.info,
-- a build config, the shared-memory index versions, sixteen local indices,
-- two archives, an encoding file split across a raw and a zlib chunk, and a
-- root file in any of its three layouts. Shared by the casc unit tests and
-- the boot test's "game:" asset check.

local image = require("jcore/lib/image")

local char, rep, concat, floor = string.char, string.rep, table.concat, math.floor

local F = {}

F.BUILD_KEY = "3645f0fe9dc5215ea90eaf7cdb7379ce"
F.TARGET = "Interface/Icons/Target.png"       -- a PNG, so the asset pipeline can load it
F.OTHER = "Interface/Icons/Other.blp"
F.UNLOCAL = "Sound/Missing.ogg"                 -- in the root, not in the archives
F.ABSENT = "Interface/Icons/Nope.blp"           -- not in the root at all

F.TARGET_BYTES = image.solid_png(8, 8, 200, 100, 50, 255) .. rep("\0", 0)
F.OTHER_BYTES = "OTHER:" .. rep("xyz", 100)

-- --- byte builders --------------------------------------------------------------

local function u8(n) return char(n % 256) end
local function u16le(n) return char(n % 256, floor(n / 256) % 256) end
local function u16be(n) return char(floor(n / 256) % 256, n % 256) end
local function u32le(n)
    return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256)
end
local function u32be(n)
    return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end
local function u24be(n) return char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256) end
local function ube(n, bytes)
    local out = {}
    for i = bytes, 1, -1 do
        out[i] = char(n % 256)
        n = floor(n / 256)
    end
    return concat(out)
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function key16(seed)
    local t = {}
    for i = 1, 16 do t[i] = char((seed * 31 + i * 17) % 256) end
    return concat(t)
end

F.u8, F.u16le, F.u32le, F.u32be, F.hex, F.key16 = u8, u16le, u32le, u32be, hex, key16

--- A BLTE container from a list of { kind, plain } chunks. `single` writes
--- the headerless form with one chunk.
function F.blte(chunks, single)
    local bodies = {}
    for i, c in ipairs(chunks) do
        if c[1] == "Z" then bodies[i] = "Z" .. jtest.deflate(c[2], 6)
        else bodies[i] = "N" .. c[2] end
    end
    if single then
        return "BLTE" .. u32be(0) .. bodies[1]
    end
    local header_size = 12 + 24 * #chunks
    local parts = { "BLTE", u32be(header_size), u8(0x0F), u24be(#chunks) }
    for i, c in ipairs(chunks) do
        parts[#parts + 1] = u32be(#bodies[i]) .. u32be(#c[2]) .. rep("\0", 16)
    end
    return concat(parts) .. concat(bodies)
end

--- Lays files into archives and builds everything that points at them.
---@param casc table The casc module (for its hash, compare and bucket helpers).
---@param fs table The table standing in for the WoW folder (mock.wow_fs).
---@param opts? { root_version?: integer }
function F.build_store(casc, fs, opts)
    opts = opts or {}
    local blte = F.blte

    local root_ckey, root_ekey = key16(1), key16(2)
    local enc_ckey, enc_ekey = key16(3), key16(4)
    local target_ckey, target_ekey = key16(5), key16(6)
    local other_ckey, other_ekey = key16(7), key16(8)
    local unlocal_ckey, unlocal_ekey = key16(9), key16(10)

    local records = {
        { path = F.TARGET, fdid = 100, ckey = target_ckey },
        { path = F.OTHER, fdid = 101, ckey = other_ckey },
        { path = F.UNLOCAL, fdid = 250, ckey = unlocal_ckey },
    }
    local deltas, ckeys, hashes = {}, {}, {}
    local prev = -1
    for i, r in ipairs(records) do
        deltas[i] = u32le(r.fdid - prev - 1)
        prev = r.fdid
        ckeys[i] = r.ckey
        hashes[i] = casc.name_hash(r.path)
    end
    local root
    if opts.root_version == 1 then
        root = "TSFM" .. u32le(#records) .. u32le(#records)
            .. u32le(#records) .. u32le(0) .. u32le(0x173F6)
            .. concat(deltas) .. concat(ckeys) .. concat(hashes)
    elseif opts.root_version == 0 then
        root = u32le(#records) .. u32le(0) .. u32le(4294967295)
            .. concat(deltas) .. concat(ckeys) .. concat(hashes)
    else
        -- A decoy block first, in another locale, holding TARGET under a
        -- different content key: the enUS copy must win.
        local decoy_ckey = key16(11)
        root = "TSFM" .. u32le(24) .. u32le(2) .. u32le(#records + 1) .. u32le(#records + 1) .. u32le(0)
            .. u32le(1) .. u32le(0x4) .. u32le(0x80) .. u32le(0) .. u8(4)
            .. u32le(100) .. decoy_ckey .. casc.name_hash(F.TARGET)
            .. u32le(#records) .. u32le(0x173F6) .. u32le(0x80) .. u32le(0) .. u8(4)
            .. concat(deltas) .. concat(ckeys) .. concat(hashes)
    end
    local half = floor(#root / 2)
    local root_blte = blte({ { "Z", root:sub(1, half) }, { "Z", root:sub(half + 1) } })

    -- encoding: header, one page table row, one 1 KB page, sorted by ckey
    local entries = {
        { ckey = root_ckey, ekey = root_ekey, size = #root },
        { ckey = enc_ckey, ekey = enc_ekey, size = 0 },
        { ckey = target_ckey, ekey = target_ekey, size = #F.TARGET_BYTES },
        { ckey = other_ckey, ekey = other_ekey, size = #F.OTHER_BYTES },
        { ckey = unlocal_ckey, ekey = unlocal_ekey, size = 10 },
        { ckey = key16(11), ekey = key16(12), size = 5 },
    }
    table.sort(entries, function(a, b) return casc._internal.cmp(a.ckey, b.ckey) < 0 end)
    local page = {}
    for _, e in ipairs(entries) do
        page[#page + 1] = u8(1) .. ube(e.size, 5) .. e.ckey .. e.ekey
    end
    local page_bytes = concat(page)
    page_bytes = page_bytes .. rep("\0", 1024 - #page_bytes)
    local encoding = "EN" .. u8(1) .. u8(16) .. u8(16) .. u16be(1) .. u16be(1) .. u32be(1) .. u32be(0) .. u8(0) .. u32be(0)
        .. entries[1].ckey .. rep("\0", 16)
        .. page_bytes
    -- split so the page table straddles a raw chunk and a zlib chunk
    local enc_blte = blte({ { "N", encoding:sub(1, 30) }, { "Z", encoding:sub(31) } })

    local target_blte = blte({ { "Z", F.TARGET_BYTES } }, true)
    local other_blte = blte({ { "N", F.OTHER_BYTES:sub(1, 100) }, { "N", F.OTHER_BYTES:sub(101) } })

    -- archives: a 30-byte local header, then the container
    local archives = { [0] = {}, [1] = {} }
    local placed = {}
    local function place(archive, ekey, container)
        local parts = archives[archive]
        local offset = 0
        for i = 1, #parts do offset = offset + #parts[i] end
        local record = ekey:reverse() .. u32le(30 + #container) .. u16le(0) .. u32le(0) .. u32le(0) .. container
        parts[#parts + 1] = record
        placed[#placed + 1] = { ekey = ekey, archive = archive, offset = offset, size = #record }
    end
    place(0, enc_ekey, enc_blte)
    place(0, "\1\2\3\4\5\6\7\8\9\10\11\12\13\14\15\16", blte({ { "N", "padding" } }, true))
    place(0, root_ekey, root_blte)
    place(1, target_ekey, target_blte)
    place(1, other_ekey, other_blte)
    fs["Data/data/data.000"] = concat(archives[0])
    fs["Data/data/data.001"] = concat(archives[1])

    -- indices: one per bucket, versions from shmem
    local versions = {}
    for b = 0, 15 do versions[b] = 0x10 + (b % 3) end
    local by_bucket = {}
    for _, p in ipairs(placed) do
        local b = casc._internal.bucket_of(p.ekey:sub(1, 9))
        by_bucket[b] = by_bucket[b] or {}
        table.insert(by_bucket[b], p)
    end
    for b = 0, 15 do
        local list = by_bucket[b] or {}
        table.sort(list, function(x, y) return casc._internal.cmp(x.ekey:sub(1, 9), y.ekey:sub(1, 9)) < 0 end)
        local ents = {}
        for _, p in ipairs(list) do
            ents[#ents + 1] = p.ekey:sub(1, 9) .. ube(p.archive * 1073741824.0 + p.offset, 5) .. u32le(p.size)
        end
        local body = concat(ents)
        local header = u32le(16) .. u32le(0) .. u16le(7) .. u8(b) .. u8(0) .. u8(4) .. u8(5) .. u8(9) .. u8(30) .. rep("\0", 8)
        header = header .. rep("\0", 8) -- 24 -> 32
        fs[string.format("Data/data/%02x%08x.idx", b, versions[b])] = header .. u32le(#body) .. u32le(0) .. body
    end
    local shmem = rep("\0", 0x110)
    for b = 0, 15 do shmem = shmem .. u32le(versions[b]) end
    fs["Data/data/shmem"] = shmem

    fs[".build.info"] = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Version!STRING:0|Product!STRING:0\n"
        .. "us|0|" .. rep("a", 32) .. "|" .. rep("b", 32) .. "|11.0.0.1|wow\n"
        .. "us|1|" .. F.BUILD_KEY .. "|" .. rep("c", 32) .. "|1.15.9.69722|wow_classic_era\n"
    fs["Data/config/36/45/" .. F.BUILD_KEY] = "# Build Configuration\n\nroot = " .. hex(root_ckey) .. "\n"
        .. "encoding = " .. hex(enc_ckey) .. " " .. hex(enc_ekey) .. "\nencoding-size = 1 2\n"

    return {
        root = root, root_ekey = hex(root_ekey), enc_ekey = hex(enc_ekey), target_ekey = hex(target_ekey),
        target_ckey = hex(target_ckey), versions = versions,
    }
end

return F

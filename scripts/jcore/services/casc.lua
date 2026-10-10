-- JCore / casc -- the game's own files, read out of its data archives.
--
-- Depends on: util, log, storage, inflate.
--
-- WHY THIS EXISTS
-- Every texture the client draws -- class icons, role icons, spell art --
-- lives inside the CASC store under Data/, which no directory listing and
-- no addon can reach. The loader's sandbox, though, will read any byte range
-- of any file under the WoW folder. That is enough: the store is a handful
-- of documented structures, and this module walks them.
--
-- THE WALK, for one path such as Interface/Icons/ClassIcon_Warrior.blp:
--
--   .build.info          -> the build config hash for the running product
--   Data/config/xx/yy/.. -> the root file's content key, the encoding file's
--                           encoded key
--   Data/data/shmem      -> which version of each local index is current
--   Data/data/NN000000VV.idx  encoded key -> archive number, offset, size
--   Data/data/data.NNN   -> a 30-byte local header, then a BLTE container:
--                           chunks that are raw or zlib
--   encoding             -> content key -> encoded key, by page
--   root                 -> name hash -> file id, content key, by block
--
-- The root file is the expensive step: several megabytes of zlib to inflate
-- in Lua and scan. It is done ONCE per client build, for every path anyone
-- has asked for so far, and the answers are kept in scripts_data. A later
-- session never touches the root again unless a new path is asked for or
-- the client has been patched.
--
-- COOPERATIVE
-- Everything heavy takes a `step` callback and calls it between units of
-- work. The asset registry runs these inside its pump coroutine, where
-- `step` yields when the frame's budget is spent, so a root scan costs a
-- couple of milliseconds a frame for a while rather than one long stall.
--
-- FAILURE IS AN ANSWER
-- Every native read is guarded and every structure check names what was
-- wrong. A path that is not in the archives is remembered as such for the
-- build, so it is not looked for again.

return function(rt)
    local storage = rt.storage
    local inflate = rt.inflate
    local log = rt.log.for_tag("JCore/casc")

    local M = {}

    local byte, sub, char, format, floor = string.byte, string.sub, string.char, string.format, math.floor
    local M32 = 4294967296

    -- --- bytes ----------------------------------------------------------------

    local function u8(s, o) return byte(s, o + 1) or 0 end
    local function u16le(s, o)
        local a, b = byte(s, o + 1, o + 2)
        return (a or 0) + (b or 0) * 256
    end
    local function u16be(s, o)
        local a, b = byte(s, o + 1, o + 2)
        return (a or 0) * 256 + (b or 0)
    end
    -- Float constants throughout: a build with 32-bit integers (the offline
    -- harness) overflows on 255 * 16777216, and a float multiply is exact to
    -- 2^53 everywhere.
    local function u32le(s, o)
        local a, b, c, d = byte(s, o + 1, o + 4)
        return (a or 0) + (b or 0) * 256.0 + (c or 0) * 65536.0 + (d or 0) * 16777216.0
    end
    local function u32be(s, o)
        local a, b, c, d = byte(s, o + 1, o + 4)
        return ((a or 0) * 256.0 + (b or 0)) * 65536.0 + (c or 0) * 256.0 + (d or 0)
    end
    local function u24be(s, o)
        local a, b, c = byte(s, o + 1, o + 3)
        return (a or 0) * 65536.0 + (b or 0) * 256.0 + (c or 0)
    end
    --- Big-endian integer of `n` bytes, as a float (exact to 2^53).
    local function ube(s, o, n)
        local v = 0.0
        for i = 1, n do v = v * 256.0 + (byte(s, o + i) or 0) end
        return v
    end

    local function hex(s)
        return (s:gsub(".", function(c) return format("%02x", byte(c)) end))
    end
    local function unhex(h)
        return (h:gsub("%x%x", function(cc) return char(tonumber(cc, 16)) end))
    end

    --- Byte-wise comparison of two binary strings of equal length: -1, 0, 1.
    --- Not `<`: that goes through strcoll, which is locale-dependent.
    local function cmp(a, b)
        for i = 1, #a do
            local x, y = byte(a, i), byte(b, i)
            if x ~= y then return x < y and -1 or 1 end
        end
        return 0
    end

    -- --- 32-bit arithmetic without a bit library --------------------------------
    --
    -- The name hash needs xor and rotate. LuaJIT has `bit`; Lua 5.3 has
    -- operators LuaJIT cannot parse, reachable through load(); and the
    -- offline harness has 32-bit integers, so the xor is done in 16-bit
    -- halves that every build represents exactly.

    local xor16
    do
        local bitlib = rawget(_G, "bit")
        if bitlib and bitlib.bxor then
            local bxor = bitlib.bxor
            xor16 = function(a, b) return bxor(a, b) % 65536 end
        else
            local ok, chunk = pcall(load, "return function(a, b) return (a ~ b) & 0xFFFF end")
            local f = ok and type(chunk) == "function" and chunk()
            if type(f) == "function" and pcall(f, 1, 2) then
                xor16 = f
            else
                xor16 = function(a, b)
                    local r, p = 0, 1
                    while a > 0 or b > 0 do
                        local ab, bb = a % 2, b % 2
                        if ab ~= bb then r = r + p end
                        a, b, p = floor(a / 2), floor(b / 2), p * 2
                    end
                    return r
                end
            end
        end
    end

    local POW2 = {}
    for i = 0, 40 do POW2[i] = 2 ^ i end

    local function xor32(a, b)
        a, b = a % M32, b % M32
        local ah, al = floor(a / 65536), a % 65536
        local bh, bl = floor(b / 65536), b % 65536
        return xor16(ah, bh) * 65536.0 + xor16(al, bl)
    end
    local function rot32(x, k)
        return ((x * POW2[k]) % M32) + floor(x / POW2[32 - k])
    end

    -- --- jenkins lookup3, hashlittle2 -------------------------------------------
    --
    -- The root file keys every path by this hash of its upper-cased,
    -- backslashed name, with both seeds zero: high word from the primary
    -- result, low word from the secondary.

    local function hashlittle2(key)
        local length = #key
        local a = (3735928559 + length) % M32  -- 0xdeadbeef
        local b, c = a, a
        local p = 1
        local function mix()
            a = (a - c) % M32; a = xor32(a, rot32(c, 4));  c = (c + b) % M32
            b = (b - a) % M32; b = xor32(b, rot32(a, 6));  a = (a + c) % M32
            c = (c - b) % M32; c = xor32(c, rot32(b, 8));  b = (b + a) % M32
            a = (a - c) % M32; a = xor32(a, rot32(c, 16)); c = (c + b) % M32
            b = (b - a) % M32; b = xor32(b, rot32(a, 19)); a = (a + c) % M32
            c = (c - b) % M32; c = xor32(c, rot32(b, 4));  b = (b + a) % M32
        end
        while length > 12 do
            a = (a + u32le(key, p - 1)) % M32
            b = (b + u32le(key, p + 3)) % M32
            c = (c + u32le(key, p + 7)) % M32
            mix()
            length = length - 12
            p = p + 12
        end
        if length == 0 then return c, b end
        local function k(i) return byte(key, p + i) or 0 end
        a = (a + k(0) + k(1) * 256.0 + k(2) * 65536.0 + k(3) * 16777216.0) % M32
        b = (b + k(4) + k(5) * 256.0 + k(6) * 65536.0 + k(7) * 16777216.0) % M32
        c = (c + k(8) + k(9) * 256.0 + k(10) * 65536.0 + k(11) * 16777216.0) % M32
        -- final
        c = xor32(c, b); c = (c - rot32(b, 14)) % M32
        a = xor32(a, c); a = (a - rot32(c, 11)) % M32
        b = xor32(b, a); b = (b - rot32(a, 25)) % M32
        c = xor32(c, b); c = (c - rot32(b, 16)) % M32
        a = xor32(a, c); a = (a - rot32(c, 4)) % M32
        b = xor32(b, a); b = (b - rot32(a, 14)) % M32
        c = xor32(c, b); c = (c - rot32(b, 24)) % M32
        return c, b
    end

    --- Normalises a game path the way the root hashes it.
    local function norm_name(path)
        return (tostring(path):gsub("/", "\\"):upper())
    end

    --- The 8-byte little-endian hash as the root stores it.
    ---@param path string
    ---@return string hash8
    ---@return number pc
    ---@return number pb
    local function name_hash(path)
        local pc, pb = hashlittle2(norm_name(path))
        local function le4(v)
            return char(v % 256, floor(v / 256) % 256, floor(v / 65536) % 256, floor(v / 16777216) % 256)
        end
        return le4(pb) .. le4(pc), pc, pb
    end
    M.name_hash = name_hash
    M.hashlittle2 = hashlittle2

    -- --- natives -----------------------------------------------------------------

    -- WHERE THE INSTALL ROOT IS. Every path below is relative to it -- where
    -- .build.info and Data/ live -- and the loader resolves paths from there:
    -- addon files load as "_classic_era_/Interface/AddOns/...". But on
    -- 2026-10-01 this reader had never opened the archives in the game, and
    -- nothing anywhere said why. So the first time .build.info will not open
    -- at the root, a few other spellings of the root are tried, and whichever
    -- opens it is used for every read after (see ensure_build).
    local root = ""

    local function raw_read(path)
        local ok, data = pcall(core.read_file, path)
        if ok and type(data) == "string" and #data > 0 then return data end
        return nil
    end
    local function read_file(path)
        return raw_read(root .. path)
    end
    local function read_partial(path, offset, size)
        local ok, data = pcall(core.read_file_partial, root .. path, offset, size)
        if ok and type(data) == "string" and #data > 0 then return data end
        return nil
    end
    local function file_size(path)
        local ok, n = pcall(core.get_file_size, root .. path)
        return ok and tonumber(n) or 0
    end

    -- --- persistent state ----------------------------------------------------------

    local store = storage.store("jcore.casc")
    local data = store.data

    local function reset_store(build)
        data.build = build
        data.files = {}
        data.idx_versions = nil
        store:touch()
    end

    -- --- build ------------------------------------------------------------------------

    local PRODUCT_BY_FLAVOR = {
        ["_retail_"] = "wow", ["_ptr_"] = "wowt", ["_xptr_"] = "wowxptr", ["_beta_"] = "wow_beta",
        ["_classic_"] = "wow_classic", ["_classic_ptr_"] = "wow_classic_ptr", ["_classic_beta_"] = "wow_classic_beta",
        ["_classic_era_"] = "wow_classic_era", ["_classic_era_ptr_"] = "wow_classic_era_ptr",
        ["_anniversary_"] = "wow_classic",
    }

    local build = nil        -- { product, key, version, root_ckey, encoding_ekey }
    local build_err = nil

    --- Parses .build.info: a pipe-separated table whose header names and
    --- types each column.
    local function parse_build_info(text)
        local rows, cols = {}, nil
        for line in text:gmatch("[^\r\n]+") do
            local cells = {}
            for cell in (line .. "|"):gmatch("([^|]*)|") do cells[#cells + 1] = cell end
            if not cols then
                cols = {}
                for i = 1, #cells do cols[i] = cells[i]:match("^([^!]*)") end
            else
                local row = {}
                for i = 1, #cols do row[cols[i]] = cells[i] end
                rows[#rows + 1] = row
            end
        end
        return rows
    end

    local function parse_config(text)
        local out = {}
        for line in text:gmatch("[^\r\n]+") do
            local k, v = line:match("^%s*([%w%-_]+)%s*=%s*(.-)%s*$")
            if k then out[k] = v end
        end
        return out
    end

    --- Which product folder the client is running from, from the assets
    --- service's probe when it exists, else the row .build.info marks active.
    --- A folder this table has never heard of (Forever's) is asked its own
    --- product, through its .flavor.info; the known folders answer from the
    --- table as they always have.
    local function running_product(rows)
        local flavor = rt.assets and rt.assets.flavor and rt.assets.flavor()
        local want = flavor and PRODUCT_BY_FLAVOR[flavor]
        if not want and flavor and rt.assets.product then
            want = rt.assets.product()
        end
        if want then
            for i = 1, #rows do
                if rows[i].Product == want then return rows[i] end
            end
        end
        for i = 1, #rows do
            if rows[i].Active == "1" then return rows[i] end
        end
        return rows[1]
    end

    --- Reads .build.info and the build config. Cached for the session.
    ---@return table|nil build
    ---@return string|nil err
    local function client_folder()
        local assets = rt.assets
        if not assets or type(assets.flavor) ~= "function" then return "" end
        local ok, f = pcall(assets.flavor)
        return (ok and type(f) == "string") and f or ""
    end

    --- The spellings of the install root to try, the plain one first.
    local function root_candidates()
        local out = { "", "../", "./" }
        local folder = client_folder()
        if folder ~= "" then out[#out + 1] = folder .. "/../" end
        return out
    end

    --- WHY THE ARCHIVES WOULD NOT OPEN, written down once a session where it
    --- outlives the session: into this reader's store, which JCore saves as
    --- scripts_data/jcore/jcore.casc.json. With the error, every root spelling
    --- tried and a handful of probe paths -- each with whether the loader
    --- will size it and read it -- so the answer to "what does the loader let
    --- us open" is on disk after one session in the game. Cleared as soon as
    --- the archives do open.
    local diagnosed = false
    local function note_failure(err)
        if diagnosed then return end
        diagnosed = true
        local folder = client_folder()
        local paths = {
            ".build.info", "../.build.info", "./.build.info", ".product.db",
            "Data/data/shmem", "Data/data/data.000", "Data/config",
        }
        if folder ~= "" then
            paths[#paths + 1] = folder .. "/.flavor.info"
            paths[#paths + 1] = folder .. "/WTF/Config.wtf"
            paths[#paths + 1] = folder .. "/../.build.info"
        end
        local probes = {}
        for i = 1, #paths do
            local p = paths[i]
            local ok_size, size = pcall(core.get_file_size, p)
            local ok_read, head = pcall(core.read_file_partial, p, 0, 16)
            probes[#probes + 1] = {
                path = p,
                size = ok_size and tonumber(size) or -1,
                readable = ok_read and type(head) == "string" and #head > 0 or false,
            }
        end
        local world = rt.world
        local version = world and type(world.game_version) == "function" and world.game_version() or ""
        -- Said once, at info. When the last session's diagnosis already gave
        -- the same reason, nothing has changed: this loader's files are the
        -- client folder and the archives sit above it (answered 2026-10-02),
        -- so the line goes to the debug log only.
        local before = data.diagnosis
        local again = type(before) == "table" and before.error == err
        data.diagnosis = {
            error = err,
            client_folder = folder,
            game_version = version,
            at = core.time(),
            probes = probes,
        }
        store:touch()
        log.fmt(again and "debug" or "info",
            "game archives not readable: %s -- what the loader will open is saved in scripts_data/jcore/jcore.casc.json",
            tostring(err))
    end

    local function ensure_build()
        if build then return build end
        if build_err then return nil, build_err end

        local text
        local candidates = root_candidates()
        for i = 1, #candidates do
            text = raw_read(candidates[i] .. ".build.info")
            if text then
                root = candidates[i]
                break
            end
        end
        if not text then
            build_err = ".build.info is not readable (is this a CASC client?)"
            note_failure(build_err)
            return nil, build_err
        end
        if root ~= "" then
            log.fmt("info", "install root reached as %q", root)
        end
        local rows = parse_build_info(text)
        local row = running_product(rows)
        if not row or not row["Build Key"] or #row["Build Key"] ~= 32 then
            build_err = ".build.info has no usable build row"
            return nil, build_err
        end
        local key = row["Build Key"]:lower()
        local cfg_text = read_file("Data/config/" .. key:sub(1, 2) .. "/" .. key:sub(3, 4) .. "/" .. key)
        if not cfg_text then
            build_err = "build config " .. key .. " is not readable"
            note_failure(build_err)
            return nil, build_err
        end
        local cfg = parse_config(cfg_text)
        local root_ckey = cfg.root and cfg.root:match("^(%x+)")
        local enc_ckey, enc_ekey = (cfg.encoding or ""):match("^(%x+)%s+(%x+)")
        if not root_ckey or not enc_ekey then
            build_err = "build config lacks root or encoding keys"
            return nil, build_err
        end

        build = {
            product = row.Product, key = key, version = row.Version,
            root_ckey = root_ckey:lower(), encoding_ckey = enc_ckey:lower(), encoding_ekey = enc_ekey:lower(),
        }
        if data.build ~= key then
            log.fmt("info", "new client build %s (%s); the file index starts empty", tostring(row.Version), key:sub(1, 8))
            reset_store(key)
        end
        if data.diagnosis then
            data.diagnosis = nil
            store:touch()
        end
        data.root = root
        return build
    end

    -- --- local indices ---------------------------------------------------------------

    local idx_versions = nil     -- bucket (0..15) -> version integer
    local idx_cache = {}         -- bucket -> parsed index

    --- The current version of each of the sixteen index files, from the
    --- shared-memory file the client keeps beside them, or by probing.
    local function ensure_idx_versions()
        if idx_versions then return idx_versions end
        if type(data.idx_versions) == "table" and #data.idx_versions == 16 then
            -- Verified below: a patch may have moved them on.
            local ok = true
            for b = 0, 15 do
                if file_size(format("Data/data/%02x%08x.idx", b, data.idx_versions[b + 1])) == 0 then ok = false break end
            end
            if ok then
                idx_versions = {}
                for b = 0, 15 do idx_versions[b] = data.idx_versions[b + 1] end
                return idx_versions
            end
        end

        local versions = {}
        local shmem = read_partial("Data/data/shmem", 0x110, 64)
        if shmem and #shmem >= 64 then
            local plausible = true
            for b = 0, 15 do
                local v = u32le(shmem, b * 4)
                if v > 0xFFFF then plausible = false break end
                versions[b] = v
            end
            if plausible then
                for b = 0, 15 do
                    if file_size(format("Data/data/%02x%08x.idx", b, versions[b])) == 0 then plausible = false break end
                end
            end
            if not plausible then versions = {} end
        end

        for b = 0, 15 do
            if not versions[b] then
                for v = 0x80, 0, -1 do
                    if file_size(format("Data/data/%02x%08x.idx", b, v)) > 0 then
                        versions[b] = v
                        break
                    end
                end
                if not versions[b] then return nil, format("no index file for bucket %02x", b) end
            end
        end

        idx_versions = versions
        data.idx_versions = {}
        for b = 0, 15 do data.idx_versions[b + 1] = versions[b] end
        store:touch()
        return versions
    end

    --- Which index file holds an encoded key.
    local function bucket_of(ekey9)
        local b = 0
        for i = 1, 9 do b = xor16(b, byte(ekey9, i)) end
        return xor16(b % 16, floor(b / 16))
    end

    --- Parses one index file: header, then sorted fixed-size entries.
    local function load_idx(bucket)
        local cached = idx_cache[bucket]
        if cached then return cached end
        local versions, err = ensure_idx_versions()
        if not versions then return nil, err end
        local path = format("Data/data/%02x%08x.idx", bucket, versions[bucket])
        local raw = read_file(path)
        if not raw then return nil, "index " .. path .. " is not readable" end

        local header_hash_size = u32le(raw, 0)
        local version = u16le(raw, 8)
        local span_size, span_offs, key_bytes, offs_bits = u8(raw, 12), u8(raw, 13), u8(raw, 14), u8(raw, 15)
        if version ~= 7 or key_bytes < 1 or key_bytes > 16 or span_offs < 1 or span_offs > 8 then
            return nil, format("index %s has an unexpected layout (version %d)", path, version)
        end
        local header_end = 8 + header_hash_size
        local entries_at = header_end + (16 - header_end % 16) % 16
        local entries_size = u32le(raw, entries_at)
        local entry_len = key_bytes + span_offs + span_size
        local first = entries_at + 8
        local count = floor(entries_size / entry_len)

        local idx = {
            raw = raw, first = first, count = count, entry_len = entry_len,
            key_bytes = key_bytes, span_offs = span_offs, span_size = span_size, offs_bits = offs_bits,
        }
        idx_cache[bucket] = idx
        return idx
    end

    --- archive number, offset and size for an encoded key, or nil.
    ---@param ekey_hex string
    local function find_local(ekey_hex)
        local ekey = unhex(ekey_hex)
        local bucket = bucket_of(sub(ekey, 1, 9))
        local idx, err = load_idx(bucket)
        if not idx then return nil, err end
        local key = sub(ekey, 1, idx.key_bytes)
        local raw, first, len = idx.raw, idx.first, idx.entry_len
        local lo, hi = 0, idx.count - 1
        while lo <= hi do
            local mid = floor((lo + hi) / 2)
            local at = first + mid * len
            local c = cmp(sub(raw, at + 1, at + idx.key_bytes), key)
            if c == 0 then
                local v = ube(raw, at + idx.key_bytes, idx.span_offs)
                local per = POW2[idx.offs_bits]
                local archive = floor(v / per)
                local offset = v % per
                local size = u32le(raw, at + idx.key_bytes + idx.span_offs)
                return { archive = archive, offset = offset, size = size }
            elseif c < 0 then
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        return nil, "not in the local index"
    end

    -- --- BLTE ---------------------------------------------------------------------------

    local LOCAL_HEADER = 30

    --- Opens the BLTE container at an archive position: parses its chunk
    --- table and decodes chunks on demand, so a page of the encoding file
    --- costs one chunk and not the whole file.
    ---@return table|nil reader
    ---@return string|nil err
    local function blte_open(archive, offset, size)
        local path = format("Data/data/data.%03d", archive)
        local head = read_partial(path, offset + LOCAL_HEADER, 12)
        if not head or #head < 8 then return nil, "archive " .. path .. " is not readable at " .. offset end
        if sub(head, 1, 4) ~= "BLTE" then return nil, "no BLTE header at " .. path .. ":" .. offset end
        local header_size = u32be(head, 4)
        local chunks = {}
        local data_at
        if header_size == 0 then
            chunks[1] = { comp = size - LOCAL_HEADER - 8, decomp = nil, at = 8 }
            data_at = 8
        else
            local table_bytes = read_partial(path, offset + LOCAL_HEADER, header_size)
            if not table_bytes or #table_bytes < header_size then return nil, "truncated BLTE header" end
            local count = u24be(table_bytes, 9)
            local p = 12
            local at = header_size
            local decoded = 0
            for i = 1, count do
                local comp, decomp = u32be(table_bytes, p), u32be(table_bytes, p + 4)
                chunks[i] = { comp = comp, decomp = decomp, at = at, start = decoded }
                at = at + comp
                decoded = decoded + decomp
                p = p + 24
            end
            data_at = header_size
        end

        local reader = { chunks = chunks, path = path, base = offset + LOCAL_HEADER, cache = {} }

        --- Decoded bytes of chunk i.
        function reader:chunk(i, step)
            local hit = self.cache[i]
            if hit then return hit end
            local c = self.chunks[i]
            if not c then return nil, "no chunk " .. i end
            local raw = read_partial(self.path, self.base + c.at, c.comp)
            if not raw or #raw < c.comp then return nil, "truncated chunk " .. i end
            local kind = sub(raw, 1, 1)
            local out, err
            if kind == "N" then
                out = sub(raw, 2)
            elseif kind == "Z" then
                out, err = inflate.zlib(sub(raw, 2), { step = step })
                if not out then return nil, "chunk " .. i .. ": " .. tostring(err) end
            elseif kind == "E" then
                return nil, "chunk " .. i .. " is encrypted"
            elseif kind == "F" then
                return nil, "chunk " .. i .. " is a nested frame"
            else
                return nil, format("chunk %d has unknown encoding %q", i, kind)
            end
            if c.decomp and #out ~= c.decomp then
                return nil, format("chunk %d decoded to %d bytes, expected %d", i, #out, c.decomp)
            end
            self.cache[i] = out
            return out
        end

        --- The whole file, decoded.
        function reader:read_all(step)
            local parts = {}
            for i = 1, #self.chunks do
                local out, err = self:chunk(i, step)
                if not out then return nil, err end
                parts[i] = out
                if step then step() end
            end
            local all = table.concat(parts)
            self.cache = {}
            return all
        end

        --- `len` decoded bytes from decoded offset `off` (0-based), reading
        --- only the chunks that cover them. Needs a chunk table.
        function reader:slice(off, len, step)
            if #self.chunks == 1 and not self.chunks[1].decomp then
                local all, err = self:chunk(1, step)
                if not all then return nil, err end
                return sub(all, off + 1, off + len)
            end
            local parts = {}
            local need_from, need_to = off, off + len - 1
            for i = 1, #self.chunks do
                local c = self.chunks[i]
                local c_from, c_to = c.start, c.start + c.decomp - 1
                if c_to >= need_from and c_from <= need_to then
                    local out, err = self:chunk(i, step)
                    if not out then return nil, err end
                    local a = math.max(need_from, c_from) - c_from
                    local b = math.min(need_to, c_to) - c_from
                    parts[#parts + 1] = sub(out, a + 1, b + 1)
                end
                if c_from > need_to then break end
            end
            return table.concat(parts)
        end

        return reader
    end

    --- Opens the container for an encoded key.
    local function open_ekey(ekey_hex)
        local entry, err = find_local(ekey_hex)
        if not entry then return nil, err end
        local reader, err2 = blte_open(entry.archive, entry.offset, entry.size)
        if not reader then return nil, err2 end
        reader.entry = entry
        return reader
    end

    -- --- encoding --------------------------------------------------------------------------

    local encoding = nil     -- { reader, ckey_size, ekey_size, page_kb, pages, table_at, pages_at }

    local function ensure_encoding(step)
        if encoding then return encoding end
        local b, err = ensure_build()
        if not b then return nil, err end
        local reader, err2 = open_ekey(b.encoding_ekey)
        if not reader then return nil, "encoding file: " .. tostring(err2) end
        local head = reader:slice(0, 22, step)
        if not head or #head < 22 or sub(head, 1, 2) ~= "EN" then return nil, "encoding file has a bad header" end
        local ckey_size, ekey_size = u8(head, 3), u8(head, 4)
        local page_kb = u16be(head, 5)
        local pages = u32be(head, 9)
        local espec_size = u32be(head, 18)
        encoding = {
            reader = reader, ckey_size = ckey_size, ekey_size = ekey_size, page_kb = page_kb, pages = pages,
            table_at = 22 + espec_size, pages_at = 22 + espec_size + pages * (ckey_size + 16),
        }
        return encoding
    end

    --- The encoded key for a content key, through the encoding file's page
    --- table: one page read per lookup.
    ---@param ckey_hex string
    local function ckey_to_ekey(ckey_hex, step)
        local enc, err = ensure_encoding(step)
        if not enc then return nil, err end
        local ckey = unhex(ckey_hex)
        local cs, es = enc.ckey_size, enc.ekey_size

        if not enc.table then
            local t, err2 = enc.reader:slice(enc.table_at, enc.pages * (cs + 16), step)
            if not t then return nil, "encoding page table: " .. tostring(err2) end
            enc.table = t
        end
        local t = enc.table
        local lo, hi, page = 0, enc.pages - 1, 0
        while lo <= hi do
            local mid = floor((lo + hi) / 2)
            local at = mid * (cs + 16)
            if cmp(sub(t, at + 1, at + cs), ckey) <= 0 then
                page = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end

        local page_bytes = enc.page_kb * 1024
        local pg, err3 = enc.reader:slice(enc.pages_at + page * page_bytes, page_bytes, step)
        if not pg then return nil, "encoding page " .. page .. ": " .. tostring(err3) end
        local p = 0
        while p + 6 + cs + es <= #pg do
            local key_count = u8(pg, p)
            if key_count == 0 then break end
            local this = sub(pg, p + 7, p + 6 + cs)
            if this == ckey then
                return hex(sub(pg, p + 7 + cs, p + 6 + cs + es))
            end
            p = p + 6 + cs + key_count * es
        end
        return nil, "content key not in the encoding file"
    end

    -- --- root ----------------------------------------------------------------------------------

    local wanted = {}        -- lower path -> true, awaiting a root scan
    local stats = { scans = 0, scan_ms = 0, resolved = 0, missing = 0, reads = 0, read_bytes = 0, errors = 0 }

    --- Walks the root file once for every wanted path, filling the store
    --- with what it finds and remembering what it does not.
    local function scan_root(step)
        local b, err = ensure_build()
        if not b then return nil, err end
        local names = {}
        for path in pairs(wanted) do
            if data.files[path] == nil then names[#names + 1] = path end
        end
        if #names == 0 then return true end

        local t0 = core.time()
        local root_ekey, err2 = ckey_to_ekey(b.root_ckey, step)
        if not root_ekey then return nil, "root file: " .. tostring(err2) end
        local reader, err3 = open_ekey(root_ekey)
        if not reader then return nil, "root file: " .. tostring(err3) end
        local root, err4 = reader:read_all(step)
        if not root then return nil, "root file: " .. tostring(err4) end

        -- Header: legacy has none; "TSFM" then either (total, named) or
        -- (headerSize, version, total, named).
        local p, version, total, named = 0, 0, -1, -1
        if sub(root, 1, 4) == "TSFM" then
            local a, c = u32le(root, 4), u32le(root, 8)
            if a >= 12 and a <= 64 and c <= 10 then
                version, total, named = c, u32le(root, 12), u32le(root, 16)
                p = a
            else
                version, total, named = 1, a, c
                p = 12
            end
        end
        local all_named = total == named

        local by_hash = {}
        for i = 1, #names do by_hash[name_hash(names[i])] = names[i] end
        local found = {}        -- path -> { fdid, ckey, locale }

        local size = #root
        local blocks = 0
        while p + 12 <= size do
            local n = u32le(root, p)
            local locale, content, no_hash
            if version >= 2 then
                locale = u32le(root, p + 4)
                local cf1, cf2 = u32le(root, p + 8), u32le(root, p + 12)
                content = cf1
                no_hash = (not all_named) and (floor(cf1 / 268435456) % 2 == 1 or floor(cf2 / 268435456) % 2 == 1)
                p = p + 17
            else
                content, locale = u32le(root, p + 4), u32le(root, p + 8)
                no_hash = version >= 1 and (floor(content / 268435456) % 2 == 1)
                p = p + 12
            end
            if n > 5000000 or p + 20 * n > size then
                return nil, format("root file block %d is implausible", blocks + 1)
            end
            local deltas_at, ckeys_at = p, p + 4 * n
            local hashes_at = ckeys_at + 16 * n
            p = hashes_at + (no_hash and 0 or 8 * n)
            blocks = blocks + 1

            if not no_hash and next(by_hash) then
                local region_end = hashes_at + 8 * n
                for h, path in pairs(by_hash) do
                    local from = hashes_at + 1
                    while true do
                        local at = string.find(root, h, from, true)
                        if not at or at + 7 > region_end then break end
                        if (at - 1 - hashes_at) % 8 == 0 then
                            local i = (at - 1 - hashes_at) / 8
                            local prior = found[path]
                            -- enUS or every locale wins over another locale's copy.
                            local ours = locale == 4294967295 or floor(locale / 2) % 2 == 1
                            if not prior or (ours and not prior.ours) then
                                local fdid = -1
                                for j = 0, i do
                                    local d = u32le(root, deltas_at + 4 * j)
                                    if d >= 2147483648 then d = d - M32 end
                                    fdid = fdid + 1 + d
                                end
                                found[path] = {
                                    fdid = fdid, ckey = hex(sub(root, ckeys_at + 16 * i + 1, ckeys_at + 16 * i + 16)),
                                    locale = locale, content = content, ours = ours,
                                }
                            end
                            break
                        end
                        from = at + 1
                    end
                end
            end
            if step and blocks % 8 == 0 then step() end
        end

        if p ~= size then
            log.fmt("warn", "root file walk ended at %d of %d bytes (version %d); answers may be incomplete", p, size, version)
        end

        for i = 1, #names do
            local path = names[i]
            local f = found[path]
            if f then
                local ekey = ckey_to_ekey(f.ckey, step)
                local entry = ekey and find_local(ekey)
                if entry then
                    data.files[path] = {
                        fdid = f.fdid, ckey = f.ckey, ekey = ekey,
                        archive = entry.archive, offset = entry.offset, size = entry.size,
                    }
                    stats.resolved = stats.resolved + 1
                else
                    data.files[path] = false
                    stats.missing = stats.missing + 1
                    log.fmt("debug", "%s is in the root but not in the local archives", path)
                end
            else
                data.files[path] = false
                stats.missing = stats.missing + 1
            end
            wanted[path] = nil
        end
        store:touch()

        stats.scans = stats.scans + 1
        stats.scan_ms = (core.time() - t0) * 1000
        stats.root_version = version
        stats.root_blocks = blocks
        stats.root_bytes = size
        log.fmt("info", "root scan: %d block(s), %d byte(s), %d path(s) resolved, %d missing, %.0f ms of frames",
            blocks, size, stats.resolved, stats.missing, stats.scan_ms)
        return true
    end

    -- --- public ----------------------------------------------------------------------------------

    --- Normalises a game path to the key everything here is stored under.
    ---@param path string
    ---@return string
    function M.key(path)
        return (tostring(path):gsub("\\", "/"):gsub("^/+", ""):lower())
    end

    --- Registers a path for the next root scan, so one scan answers every
    --- path asked for so far rather than one scan per path.
    ---@param path string
    function M.want(path)
        local key = M.key(path)
        -- Before any build has been resolved there is no file table yet;
        -- asking early is normal (sheets register at plugin start) and must
        -- not raise, because that start has the rotation behind it.
        local files = data.files
        if files == nil or files[key] == nil then wanted[key] = true end
    end

    --- Whether this client keeps its files in a CASC store this module can
    --- open. Cheap after the first call.
    ---@return boolean
    ---@return string|nil reason
    function M.available()
        local b, err = ensure_build()
        if not b then return false, err end
        return true, nil
    end

    ---@return table|nil build { product, key, version }
    function M.build()
        return (ensure_build())
    end

    --- What is known about a path without reading anything: a resolved
    --- entry, false for a path the build does not have, nil for unknown.
    function M.lookup(path)
        local files = data.files
        if files == nil then return nil end
        return files[M.key(path)]
    end

    --- The bytes of a game file. Heavy on first use of a path (a root scan
    --- for every wanted path); a chunk read and inflate afterwards. Meant to
    --- be called inside a coroutine with a `step` that yields.
    ---@param path string
    ---@param step? fun()
    ---@return string|nil bytes
    ---@return string|nil err
    ---@return boolean permanent Whether the failure will not change for this build.
    function M.read(path, step)
        local key = M.key(path)
        local b, err = ensure_build()
        if not b then stats.errors = stats.errors + 1 return nil, err, false end
        -- A store written by an older revision can carry a build without a
        -- file table; treat that as nothing resolved yet.
        if data.files == nil then data.files = {} end

        local entry = data.files[key]
        if entry == nil then
            wanted[key] = true
            local ok, err2 = scan_root(step)
            if not ok then stats.errors = stats.errors + 1 return nil, err2, false end
            entry = data.files[key]
        end
        if entry == false then return nil, "not in the game's archives for this build", true end
        if not entry then return nil, "unresolved", false end

        local reader, err3 = blte_open(entry.archive, entry.offset, entry.size)
        if not reader then stats.errors = stats.errors + 1 return nil, err3, false end
        local bytes, err4 = reader:read_all(step)
        if not bytes then stats.errors = stats.errors + 1 return nil, err4, false end
        stats.reads = stats.reads + 1
        stats.read_bytes = stats.read_bytes + #bytes
        return bytes, nil, false
    end

    function M.stats()
        local known, missing = 0, 0
        for _, v in pairs(data.files or {}) do
            if v then known = known + 1 else missing = missing + 1 end
        end
        local pending = 0
        for _ in pairs(wanted) do pending = pending + 1 end
        return {
            build = build and build.version or nil, product = build and build.product or nil,
            available = build ~= nil, error = build_err, root = root,
            known = known, missing = missing, pending = pending,
            scans = stats.scans, scan_ms = stats.scan_ms, reads = stats.reads, read_bytes = stats.read_bytes,
            errors = stats.errors, root_version = stats.root_version, root_blocks = stats.root_blocks,
        }
    end

    --- Why the archives would not open, as saved (see note_failure), or nil.
    ---@return table|nil
    function M.diagnosis()
        return data.diagnosis
    end

    -- Exposed for tests.
    M._internal = {
        parse_build_info = parse_build_info, parse_config = parse_config,
        bucket_of = bucket_of, cmp = cmp, xor32 = xor32, rot32 = rot32,
        blte_open = blte_open, find_local = find_local, ckey_to_ekey = ckey_to_ekey,
    }

    return M
end

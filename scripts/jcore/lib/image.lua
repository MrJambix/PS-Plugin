-- JCore / image -- leaf module, depends on nothing.
--
-- Decoders for the art formats an addon ships on disk, and a PNG encoder so
-- the result can be handed to core.graphics.load_texture.
--
-- WHY THIS EXISTS
-- The native texture loader decodes the usual web formats (PNG, JPEG, BMP,
-- GIF, TGA) from raw bytes. Nearly every icon a WoW addon carries is a BLP,
-- Blizzard's own container, which nothing outside the client reads. So "import
-- the icons from every addon" is really "read the BLP, unpack it to RGBA and
-- wrap it in the one format the loader is guaranteed to take". PNG with
-- STORED deflate blocks needs no compressor at all: the only arithmetic is a
-- CRC-32 per chunk and an Adler-32 over the raw pixels.
--
-- COST
-- A 64x64 icon is four thousand pixels and decodes in well under a
-- millisecond. A 1024x1024 texture is a million and would stall a frame, so
-- every decoder takes a `step` callback that is called once per row (or per
-- block) and can yield the surrounding coroutine. The assets service runs
-- decodes on a per-frame budget through exactly that hook. Mip levels are
-- used the same way: a caller that only needs a 64px thumbnail asks for the
-- mip that fits and never decodes the big level at all.

local M = {}

-- --- bit operations --------------------------------------------------------
--
-- LuaJIT ships `bit`; a plain 5.1 build would not. The fallbacks below are
-- slow (they loop over bits) and exist so the module loads and stays correct
-- everywhere, not to be fast.

local band, bor, bxor, rshift, lshift
do
    local lib = rawget(_G, "bit") or rawget(_G, "bit32")
    if lib and lib.band and lib.bxor and lib.rshift then
        band, bor, bxor, rshift, lshift = lib.band, lib.bor, lib.bxor, lib.rshift, lib.lshift
    else
        -- Inputs are folded to unsigned first: on a build with 32-bit
        -- integers (LUA_32BITS, fengari) a literal such as 0xFFFFFFFF is
        -- already -1, and the loops below stop on a negative operand. The
        -- place value `p` starts as a float for the same reason, so bit 31
        -- does not overflow an integer multiply.
        local floor = math.floor
        local M32 = 4294967296
        band = function(a, b)
            a, b = a % M32, b % M32
            local r, p = 0, 1.0
            while a > 0 and b > 0 do
                if a % 2 == 1 and b % 2 == 1 then r = r + p end
                a, b, p = floor(a / 2), floor(b / 2), p * 2
            end
            return r
        end
        bor = function(a, b)
            a, b = a % M32, b % M32
            local r, p = 0, 1.0
            while a > 0 or b > 0 do
                if a % 2 == 1 or b % 2 == 1 then r = r + p end
                a, b, p = floor(a / 2), floor(b / 2), p * 2
            end
            return r
        end
        bxor = function(a, b)
            a, b = a % M32, b % M32
            local r, p = 0, 1.0
            while a > 0 or b > 0 do
                if (a % 2) ~= (b % 2) then r = r + p end
                a, b, p = floor(a / 2), floor(b / 2), p * 2
            end
            return r
        end
        rshift = function(a, n) return floor((a % M32) / (2 ^ n)) end
        lshift = function(a, n) return (a * (2 ^ n)) % M32 end
    end
end

--- Normalises a bit-op result to an unsigned 32-bit value. LuaJIT's bit
--- library answers SIGNED 32-bit numbers, so 0xFFFFFFFF comes back as -1;
--- Lua's floored modulo turns that into the value a file format expects.
local function u32(x)
    return x % 4294967296
end

local byte, char, sub, concat = string.byte, string.char, string.sub, table.concat
local floor = math.floor

-- --- byte readers (0-based offsets, like the format specs) ------------------

local function u8(s, o)
    return byte(s, o + 1) or 0
end

local function u16le(s, o)
    local a, b = byte(s, o + 1, o + 2)
    return (a or 0) + (b or 0) * 256
end

local function u32le(s, o)
    local a, b, c, d = byte(s, o + 1, o + 4)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

local function be32(n)
    n = u32(n)
    return char(floor(n / 16777216) % 256, floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
end

-- --- format sniffing --------------------------------------------------------

--- What the bytes are, from their signature. "tga" is a guess by structure
--- (the format has no magic at the front), which is why the sniff also takes
--- the file extension as a hint.
---@param bytes string
---@param ext_hint? string lower-case extension without the dot
---@return "png"|"jpg"|"gif"|"bmp"|"blp"|"blp1"|"tga"|"unknown"
function M.sniff(bytes, ext_hint)
    if type(bytes) ~= "string" or #bytes < 4 then return "unknown" end
    local head4 = sub(bytes, 1, 4)
    if head4 == "\137PNG" then return "png" end
    if sub(bytes, 1, 3) == "\255\216\255" then return "jpg" end
    if sub(bytes, 1, 3) == "GIF" then return "gif" end
    if sub(bytes, 1, 2) == "BM" then return "bmp" end
    if head4 == "BLP2" then return "blp" end
    if head4 == "BLP1" or head4 == "BLP0" then return "blp1" end
    if #bytes >= 26 and sub(bytes, -18, -2) == "TRUEVISION-XFILE." then return "tga" end
    if ext_hint == "tga" then return "tga" end
    -- Structural TGA guess: a plausible header with a known image type.
    if #bytes >= 18 then
        local image_type = u8(bytes, 2)
        local depth = u8(bytes, 16)
        local cmap = u8(bytes, 1)
        if (image_type == 2 or image_type == 3 or image_type == 10 or image_type == 11)
            and (depth == 8 or depth == 24 or depth == 32) and (cmap == 0 or cmap == 1) then
            return "tga"
        end
    end
    return "unknown"
end

--- Whether the native loader is expected to decode these bytes as they are.
---@param kind string
---@return boolean
function M.native_loadable(kind)
    return kind == "png" or kind == "jpg" or kind == "gif" or kind == "bmp" or kind == "tga"
end

-- --- dimensions without decoding --------------------------------------------

--- Width and height from the header alone, for formats the native loader
--- takes but whose size it only reports on first load.
---@param bytes string
---@param kind? string
---@return integer|nil w
---@return integer|nil h
function M.dimensions(bytes, kind)
    kind = kind or M.sniff(bytes)
    if kind == "png" and #bytes >= 24 then
        local a, b, c, d = byte(bytes, 17, 20)
        local e, f, g, h = byte(bytes, 21, 24)
        return a * 16777216 + b * 65536 + c * 256 + d, e * 16777216 + f * 65536 + g * 256 + h
    elseif kind == "gif" and #bytes >= 10 then
        return u16le(bytes, 6), u16le(bytes, 8)
    elseif kind == "bmp" and #bytes >= 26 then
        return u32le(bytes, 18), u32le(bytes, 22)
    elseif kind == "tga" and #bytes >= 18 then
        return u16le(bytes, 12), u16le(bytes, 14)
    elseif (kind == "blp" or kind == "blp1") and #bytes >= 20 then
        return u32le(bytes, 12), u32le(bytes, 16)
    elseif kind == "jpg" then
        -- Walk the marker segments to the first start-of-frame.
        local i = 2
        local n = #bytes
        while i + 9 <= n do
            if byte(bytes, i + 1) ~= 0xFF then return nil end
            local marker = byte(bytes, i + 2)
            if marker == 0xFF then
                i = i + 1
            else
                if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    local h = byte(bytes, i + 6) * 256 + byte(bytes, i + 7)
                    local w = byte(bytes, i + 8) * 256 + byte(bytes, i + 9)
                    return w, h
                end
                local len = byte(bytes, i + 3) * 256 + byte(bytes, i + 4)
                i = i + 2 + len
            end
        end
    end
    return nil
end

-- --- CRC-32 and Adler-32 ----------------------------------------------------

local crc_table
local function build_crc_table()
    crc_table = {}
    for n = 0, 255 do
        local c = n
        for _ = 1, 8 do
            if band(c, 1) == 1 then
                c = bxor(rshift(c, 1), 0xEDB88320)
            else
                c = rshift(c, 1)
            end
        end
        crc_table[n] = u32(c)
    end
end

--- CRC-32 of a string, optionally continuing from a previous value.
---@param s string
---@param crc? number running value from a previous call
---@return number
function M.crc32(s, crc)
    if not crc_table then build_crc_table() end
    local c = bxor(crc or 0, 0xFFFFFFFF)
    for i = 1, #s do
        c = bxor(crc_table[band(bxor(c, byte(s, i)), 0xFF)], rshift(c, 8))
    end
    return u32(bxor(c, 0xFFFFFFFF))
end

--- Adler-32, resumable: pass the previous (a, b) pair to continue.
---@param s string
---@param a? number
---@param b? number
---@return number a
---@return number b
local function adler32_step(s, a, b)
    a = a or 1
    b = b or 0
    local n = #s
    local i = 1
    -- 5552 is the largest block for which the sums cannot overflow before the
    -- modulo, per zlib.
    while i <= n do
        local last = math.min(n, i + 5551)
        for j = i, last do
            a = a + byte(s, j)
            b = b + a
        end
        a = a % 65521
        b = b % 65521
        i = last + 1
    end
    return a, b
end

-- --- PNG encoder ------------------------------------------------------------

local function png_chunk(kind, data)
    local body = kind .. data
    return be32(#data) .. body .. be32(M.crc32(body))
end

--- Builds an RGBA8 PNG from decoded rows.
---
--- `rows[y]` is a string of width*4 bytes, red first, top row first. Each
--- row is prefixed with the "no filter" byte and the whole image goes into
--- stored deflate blocks, which is legal PNG that any decoder takes and costs
--- no compression work here. `step` is called after every block and may
--- yield the enclosing coroutine.
---@param rows string[]
---@param w integer
---@param h integer
---@param step? fun()
---@return string png
function M.encode_png(rows, w, h, step)
    local raw = {}
    for y = 1, h do
        raw[y] = "\0" .. rows[y]
    end
    local pixels = concat(raw)

    local blocks = {}
    local n = #pixels
    local pos = 1
    local a, b = 1, 0
    while pos <= n do
        local len = math.min(65535, n - pos + 1)
        local final = (pos + len > n) and 1 or 0
        local piece = sub(pixels, pos, pos + len - 1)
        local nlen = bxor(len, 0xFFFF)
        blocks[#blocks + 1] = char(final, len % 256, floor(len / 256), nlen % 256, floor(nlen / 256)) .. piece
        a, b = adler32_step(piece, a, b)
        pos = pos + len
        if step then step() end
    end
    if n == 0 then
        blocks[1] = char(1, 0, 0, 255, 255)
    end

    local zlib = "\120\1" .. concat(blocks) .. be32(b * 65536 + a)

    local ihdr = be32(w) .. be32(h) .. char(8, 6, 0, 0, 0)
    return "\137PNG\r\n\26\n"
        .. png_chunk("IHDR", ihdr)
        .. png_chunk("IDAT", zlib)
        .. png_chunk("IEND", "")
end

-- --- DXT block decoding -----------------------------------------------------

local function rgb565(v)
    local r = rshift(v, 11)
    local g = band(rshift(v, 5), 63)
    local b = band(v, 31)
    -- Expand 5/6-bit channels to 8 bits by replicating the high bits.
    return bor(lshift(r, 3), rshift(r, 2)), bor(lshift(g, 2), rshift(g, 4)), bor(lshift(b, 3), rshift(b, 2))
end

--- Decodes one 4x4 DXT colour block into the 16-entry `out` array of
--- {r,g,b,a} quads (as four parallel arrays for speed). `force_four` is set
--- for DXT3/DXT5, whose colour block is always in 4-colour mode.
local function dxt_color_block(s, o, force_four, pr, pg, pb, pa)
    local c0 = u16le(s, o)
    local c1 = u16le(s, o + 2)
    local r0, g0, b0 = rgb565(c0)
    local r1, g1, b1 = rgb565(c1)
    local r2, g2, b2, r3, g3, b3, a3
    if c0 > c1 or force_four then
        r2 = floor((2 * r0 + r1) / 3); g2 = floor((2 * g0 + g1) / 3); b2 = floor((2 * b0 + b1) / 3)
        r3 = floor((r0 + 2 * r1) / 3); g3 = floor((g0 + 2 * g1) / 3); b3 = floor((b0 + 2 * b1) / 3)
        a3 = 255
    else
        r2 = floor((r0 + r1) / 2); g2 = floor((g0 + g1) / 2); b2 = floor((b0 + b1) / 2)
        r3, g3, b3, a3 = 0, 0, 0, 0
    end
    local n = 0
    for row = 0, 3 do
        local bits = u8(s, o + 4 + row)
        for col = 0, 3 do
            local idx = band(rshift(bits, col * 2), 3)
            n = n + 1
            if idx == 0 then pr[n], pg[n], pb[n], pa[n] = r0, g0, b0, 255
            elseif idx == 1 then pr[n], pg[n], pb[n], pa[n] = r1, g1, b1, 255
            elseif idx == 2 then pr[n], pg[n], pb[n], pa[n] = r2, g2, b2, 255
            else pr[n], pg[n], pb[n], pa[n] = r3, g3, b3, a3 end
        end
    end
end

local function dxt3_alpha_block(s, o, pa)
    local n = 0
    for i = 0, 7 do
        local v = u8(s, o + i)
        n = n + 1
        pa[n] = band(v, 15) * 17
        n = n + 1
        pa[n] = rshift(v, 4) * 17
    end
end

local function dxt5_alpha_block(s, o, pa)
    local a0 = u8(s, o)
    local a1 = u8(s, o + 1)
    local alphas = { a0, a1 }
    if a0 > a1 then
        for i = 1, 6 do
            alphas[i + 2] = floor(((7 - i) * a0 + i * a1) / 7)
        end
    else
        for i = 1, 4 do
            alphas[i + 2] = floor(((5 - i) * a0 + i * a1) / 5)
        end
        alphas[7] = 0
        alphas[8] = 255
    end
    -- 48 bits of 3-bit indices, little endian, in two 24-bit halves.
    for half = 0, 1 do
        local base = o + 2 + half * 3
        local bits = u8(s, base) + u8(s, base + 1) * 256 + u8(s, base + 2) * 65536
        for i = 0, 7 do
            local idx = band(rshift(bits, i * 3), 7)
            pa[half * 8 + i + 1] = alphas[idx + 1]
        end
    end
end

--- Decodes a DXT1/3/5 mip level into RGBA rows.
local function decode_dxt(s, o, w, h, mode, step)
    local bw = floor((w + 3) / 4)
    local bh = floor((h + 3) / 4)
    local block_size = (mode == 1) and 8 or 16

    -- Row buffers: bytes are accumulated per pixel as small strings and
    -- joined once per row. Four block rows are produced per pass.
    local rows = {}
    local pr, pg, pb, pa = {}, {}, {}, {}

    for by = 0, bh - 1 do
        local line = {}
        for r = 0, 3 do line[r] = {} end

        for bx = 0, bw - 1 do
            local bo = o + (by * bw + bx) * block_size
            if mode == 1 then
                dxt_color_block(s, bo, false, pr, pg, pb, pa)
            elseif mode == 3 then
                dxt_color_block(s, bo + 8, true, pr, pg, pb, pa)
                dxt3_alpha_block(s, bo, pa)
            else
                dxt_color_block(s, bo + 8, true, pr, pg, pb, pa)
                dxt5_alpha_block(s, bo, pa)
            end
            local n = 0
            for r = 0, 3 do
                local dest = line[r]
                for c = 0, 3 do
                    n = n + 1
                    if bx * 4 + c < w then
                        dest[#dest + 1] = char(pr[n], pg[n], pb[n], pa[n])
                    end
                end
            end
        end

        for r = 0, 3 do
            local y = by * 4 + r
            if y < h then rows[y + 1] = concat(line[r]) end
        end
        if step then step() end
    end
    return rows
end

-- --- BLP2 -------------------------------------------------------------------

--- Header of a BLP2 file, or nil with a reason.
---@param bytes string
---@return table|nil header
---@return string|nil err
function M.blp_header(bytes)
    if type(bytes) ~= "string" or #bytes < 148 then return nil, "too short" end
    local magic = sub(bytes, 1, 4)
    if magic ~= "BLP2" then
        if magic == "BLP1" or magic == "BLP0" then return nil, "BLP1 (Warcraft III) is not supported" end
        return nil, "not a BLP"
    end
    local header = {
        type           = u32le(bytes, 4),
        encoding       = u8(bytes, 8),
        alpha_depth    = u8(bytes, 9),
        alpha_encoding = u8(bytes, 10),
        has_mips       = u8(bytes, 11),
        width          = u32le(bytes, 12),
        height         = u32le(bytes, 16),
        mip_offsets    = {},
        mip_sizes      = {},
    }
    for i = 0, 15 do
        header.mip_offsets[i] = u32le(bytes, 20 + i * 4)
        header.mip_sizes[i] = u32le(bytes, 84 + i * 4)
    end
    if header.type ~= 1 then return nil, "JPEG-compressed BLP is not supported" end
    if header.width == 0 or header.height == 0 or header.width > 8192 or header.height > 8192 then
        return nil, "implausible dimensions"
    end
    return header
end

--- Picks the mip level whose larger side fits in `max_dim`, walking down
--- only through levels the file actually stores.
local function choose_mip(header, max_dim)
    local level, w, h = 0, header.width, header.height
    if not max_dim or max_dim <= 0 then return 0, w, h end
    while (w > max_dim or h > max_dim) and level < 15 do
        local next_level = level + 1
        if header.mip_offsets[next_level] == 0 or header.mip_sizes[next_level] == 0 then break end
        level = next_level
        w = math.max(1, floor(w / 2))
        h = math.max(1, floor(h / 2))
    end
    return level, w, h
end

--- Decodes a BLP2 into RGBA rows.
---@param bytes string
---@param opts? { max_dim?: integer, step?: fun() }
---@return table|nil image { w, h, rows, level, full_w, full_h }
---@return string|nil err
function M.decode_blp(bytes, opts)
    opts = opts or {}
    local header, err = M.blp_header(bytes)
    if not header then return nil, err end

    local level, w, h = choose_mip(header, opts.max_dim)
    local offset = header.mip_offsets[level]
    local size = header.mip_sizes[level]
    if offset == 0 or size == 0 or offset + size > #bytes then
        return nil, "mip level " .. level .. " is missing or truncated"
    end

    local step = opts.step
    local rows

    if header.encoding == 1 then
        -- Palettised. 256 BGRA entries live in the header; the level holds
        -- one index byte per pixel followed by the alpha plane.
        local pal = {}
        for i = 0, 255 do
            local b, g, r = byte(bytes, 149 + i * 4, 151 + i * 4)
            pal[i] = char(r or 0, g or 0, b or 0)
        end
        local count = w * h
        if size < count then return nil, "palette level too small" end
        local alpha_base = offset + count
        local depth = header.alpha_depth
        rows = {}
        local opaque = char(255)
        for y = 0, h - 1 do
            local line = {}
            local row_base = offset + y * w
            for x = 0, w - 1 do
                local idx = byte(bytes, row_base + x + 1) or 0
                local a
                if depth == 8 then
                    a = char(byte(bytes, alpha_base + y * w + x + 1) or 255)
                elseif depth == 1 then
                    local p = y * w + x
                    local v = byte(bytes, alpha_base + floor(p / 8) + 1) or 255
                    a = band(rshift(v, p % 8), 1) == 1 and opaque or "\0"
                elseif depth == 4 then
                    local p = y * w + x
                    local v = byte(bytes, alpha_base + floor(p / 2) + 1) or 255
                    local nib = (p % 2 == 0) and band(v, 15) or rshift(v, 4)
                    a = char(nib * 17)
                else
                    a = opaque
                end
                line[x + 1] = pal[idx] .. a
            end
            rows[y + 1] = concat(line)
            if step then step() end
        end
    elseif header.encoding == 2 then
        local mode
        if header.alpha_encoding == 7 then mode = 5
        elseif header.alpha_encoding == 1 then mode = 3
        else mode = 1 end
        rows = decode_dxt(bytes, offset, w, h, mode, step)
    elseif header.encoding == 3 then
        -- Uncompressed BGRA.
        if size < w * h * 4 then return nil, "ARGB level too small" end
        rows = {}
        for y = 0, h - 1 do
            local line = {}
            local row_base = offset + y * w * 4
            for x = 0, w - 1 do
                local p = row_base + x * 4
                local b, g, r, a = byte(bytes, p + 1, p + 4)
                line[x + 1] = char(r or 0, g or 0, b or 0, a or 255)
            end
            rows[y + 1] = concat(line)
            if step then step() end
        end
    else
        return nil, "unknown BLP encoding " .. tostring(header.encoding)
    end

    return {
        w = w, h = h, rows = rows, level = level,
        full_w = header.width, full_h = header.height,
    }
end

-- --- TGA --------------------------------------------------------------------

--- Decodes an uncompressed or RLE true-colour / greyscale TGA into RGBA rows.
--- The native loader already reads TGA; this is the fallback for a build
--- whose loader does not.
---@param bytes string
---@param opts? { step?: fun() }
---@return table|nil image { w, h, rows }
---@return string|nil err
function M.decode_tga(bytes, opts)
    opts = opts or {}
    if type(bytes) ~= "string" or #bytes < 18 then return nil, "too short" end
    local id_len = u8(bytes, 0)
    local cmap_type = u8(bytes, 1)
    local image_type = u8(bytes, 2)
    local cmap_len = u16le(bytes, 5)
    local cmap_bits = u8(bytes, 7)
    local w = u16le(bytes, 12)
    local h = u16le(bytes, 14)
    local depth = u8(bytes, 16)
    local desc = u8(bytes, 17)
    local top_down = band(desc, 32) ~= 0

    if w == 0 or h == 0 or w > 8192 or h > 8192 then return nil, "implausible dimensions" end
    local rle = image_type == 10 or image_type == 11 or image_type == 9
    local base = image_type == 10 and 2 or image_type == 11 and 3 or image_type == 9 and 1 or image_type
    if base ~= 2 and base ~= 3 and base ~= 1 then return nil, "unsupported TGA type " .. image_type end
    if depth ~= 8 and depth ~= 16 and depth ~= 24 and depth ~= 32 then
        return nil, "unsupported TGA depth " .. depth
    end

    local pos = 18 + id_len
    local palette
    if cmap_type == 1 then
        palette = {}
        local entry = floor(cmap_bits / 8)
        for i = 0, cmap_len - 1 do
            local p = pos + i * entry
            if entry >= 3 then
                local b, g, r = byte(bytes, p + 1, p + 3)
                local a = entry == 4 and (byte(bytes, p + 4) or 255) or 255
                palette[i] = char(r or 0, g or 0, b or 0, a)
            else
                local v = byte(bytes, p + 1) or 0
                palette[i] = char(v, v, v, 255)
            end
        end
        pos = pos + cmap_len * entry
    end

    local bpp = floor(depth / 8)
    local function read_pixel(p)
        if base == 1 and palette then
            return palette[byte(bytes, p + 1) or 0] or "\0\0\0\255"
        elseif base == 3 or bpp == 1 then
            local v = byte(bytes, p + 1) or 0
            return char(v, v, v, 255)
        elseif bpp == 2 then
            local v = u16le(bytes, p)
            local r = band(rshift(v, 10), 31) * 8
            local g = band(rshift(v, 5), 31) * 8
            local b = band(v, 31) * 8
            return char(r, g, b, 255)
        else
            local b, g, r = byte(bytes, p + 1, p + 3)
            local a = (bpp == 4) and (byte(bytes, p + 4) or 255) or 255
            return char(r or 0, g or 0, b or 0, a)
        end
    end

    local count = w * h
    local pixels = {}
    if rle then
        local i = 0
        while i < count do
            local packet = byte(bytes, pos + 1)
            if not packet then break end
            pos = pos + 1
            local run = band(packet, 127) + 1
            if band(packet, 128) ~= 0 then
                local px = read_pixel(pos)
                pos = pos + bpp
                for _ = 1, run do
                    i = i + 1
                    pixels[i] = px
                end
            else
                for _ = 1, run do
                    i = i + 1
                    pixels[i] = read_pixel(pos)
                    pos = pos + bpp
                end
            end
        end
        for j = i + 1, count do pixels[j] = "\0\0\0\0" end
    else
        if pos + count * bpp > #bytes then return nil, "truncated TGA" end
        for i = 0, count - 1 do
            pixels[i + 1] = read_pixel(pos + i * bpp)
        end
    end

    local rows = {}
    local step = opts.step
    for y = 0, h - 1 do
        local src_row = top_down and y or (h - 1 - y)
        local line = {}
        local b = src_row * w
        for x = 1, w do line[x] = pixels[b + x] end
        rows[y + 1] = concat(line)
        if step then step() end
    end
    return { w = w, h = h, rows = rows }
end

-- --- convenience ------------------------------------------------------------

--- Turns any supported bytes into something the native loader takes.
---
--- Returns the ORIGINAL bytes untouched for formats the loader reads itself,
--- and a freshly encoded PNG for a BLP. `converted` says which happened.
---@param bytes string
---@param opts? { ext?: string, max_dim?: integer, step?: fun(), force_tga?: boolean }
---@return string|nil out
---@return table info { kind, w, h, converted, err }
function M.to_native(bytes, opts)
    opts = opts or {}
    local kind = M.sniff(bytes, opts.ext)
    local info = { kind = kind, converted = false }

    if kind == "blp" then
        local img, err = M.decode_blp(bytes, { max_dim = opts.max_dim, step = opts.step })
        if not img then
            info.err = err
            return nil, info
        end
        info.w, info.h, info.converted = img.w, img.h, true
        info.full_w, info.full_h, info.level = img.full_w, img.full_h, img.level
        return M.encode_png(img.rows, img.w, img.h, opts.step), info
    end

    if kind == "tga" and opts.force_tga then
        local img, err = M.decode_tga(bytes, { step = opts.step })
        if not img then
            info.err = err
            return nil, info
        end
        info.w, info.h, info.converted = img.w, img.h, true
        return M.encode_png(img.rows, img.w, img.h, opts.step), info
    end

    if kind == "blp1" then
        info.err = "BLP1 is not supported"
        return nil, info
    end
    if kind == "unknown" then
        info.err = "unrecognised image format"
        return nil, info
    end

    info.w, info.h = M.dimensions(bytes, kind)
    return bytes, info
end

--- A solid-colour PNG, for placeholders and tests.
---@param w integer
---@param h integer
---@param r integer
---@param g integer
---@param b integer
---@param a? integer
---@return string png
function M.solid_png(w, h, r, g, b, a)
    local px = char(r, g, b, a or 255)
    local row = string.rep(px, w)
    local rows = {}
    for y = 1, h do rows[y] = row end
    return M.encode_png(rows, w, h)
end

return M

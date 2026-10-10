-- Tests for scripts/jcore/lib/image.lua, run offline by tools/jtest/run.js.
--
-- Every fixture is built by hand here so the test needs no files on disk.
-- Offsets in comments are 0-based, like the format specs and image.lua.

local image = require("jcore/lib/image")

local char, byte, rep, concat = string.char, string.byte, string.rep, table.concat

-- --- helpers ---------------------------------------------------------------

local function u16le(n) return char(n % 256, math.floor(n / 256) % 256) end
local function u32le(n)
    return char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function u16be(n) return char(math.floor(n / 256) % 256, n % 256) end

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", byte(c)) end))
end

local function eq(actual, expected, label)
    if actual ~= expected then
        local a, e = tostring(actual), tostring(expected)
        if type(actual) == "string" and type(expected) == "string" then
            a, e = hex(actual), hex(expected)
        end
        error((label or "value") .. ": expected " .. e .. ", got " .. a, 2)
    end
end

local function eq_pixels(actual, expected, label)
    if actual ~= expected then
        eq(#actual, #expected, (label or "pixels") .. " length")
        for i = 1, #expected, 4 do
            local ar, ag, ab, aa = byte(actual, i, i + 3)
            local er, eg, eb, ea = byte(expected, i, i + 3)
            if ar ~= er or ag ~= eg or ab ~= eb or aa ~= ea then
                error(string.format("%s: pixel %d expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
                    label or "pixels", (i - 1) / 4, er, eg, eb, ea, ar, ag, ab, aa), 2)
            end
        end
        error((label or "pixels") .. ": differ", 2)
    end
end

local function decode_png(png, label)
    local w, h, rgba = jtest.png_decode(png)
    if not w then error((label or "png") .. ": pngjs failed: " .. tostring(h), 2) end
    return w, h, rgba
end

--- BLP2 header + palette. `mips` is a list of { offset = n, size = n };
--- `palette` maps index -> { b, g, r, a } (missing entries are zero).
local function blp2(opts)
    local parts = {
        "BLP2",
        u32le(opts.type or 1),
        char(opts.encoding, opts.alpha_depth or 0, opts.alpha_encoding or 0, opts.has_mips or 0),
        u32le(opts.width), u32le(opts.height),
    }
    for i = 0, 15 do
        local m = opts.mips[i + 1]
        parts[#parts + 1] = u32le(m and m.offset or 0)
    end
    for i = 0, 15 do
        local m = opts.mips[i + 1]
        parts[#parts + 1] = u32le(m and m.size or 0)
    end
    local pal = {}
    for i = 0, 255 do
        local e = opts.palette and opts.palette[i]
        pal[i + 1] = e and char(e[1], e[2], e[3], e[4] or 0) or "\0\0\0\0"
    end
    parts[#parts + 1] = concat(pal)
    local header = concat(parts)
    assert(#header == 1172, "BLP2 header should be 1172 bytes, got " .. #header)
    return header .. (opts.data or "")
end

--- TGA header. Fields default to zero.
local function tga_header(o)
    return char(o.id_len or 0, o.cmap_type or 0, o.image_type)
        .. u16le(o.cmap_first or 0) .. u16le(o.cmap_len or 0) .. char(o.cmap_bits or 0)
        .. u16le(0) .. u16le(0)
        .. u16le(o.w) .. u16le(o.h)
        .. char(o.depth, o.desc or 0)
end

-- Fixtures shared by the sniff / dimensions tests.
local GIF = "GIF89a" .. u16le(13) .. u16le(7) .. char(0xF7, 0, 0) .. rep("\0", 16)
local BMP = "BM" .. u32le(70) .. u32le(0) .. u32le(54)
    .. u32le(40) .. u32le(21) .. u32le(9) .. u16le(1) .. u16le(24) .. rep("\0", 24)
local JPG = "\255\216"
    .. "\255\224" .. u16be(16) .. "JFIF\0" .. char(1, 1, 0) .. u16be(1) .. u16be(1) .. char(0, 0)
    .. "\255\192" .. u16be(17) .. char(8) .. u16be(33) .. u16be(17) .. char(3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1)
    .. "\255\217"
local TGA_PLAIN = tga_header({ image_type = 2, w = 2, h = 2, depth = 24 }) .. rep("\0", 12)

-- --- tests -------------------------------------------------------------------

local T = {}

T[#T + 1] = { "crc32 standard check values", function()
    -- fengari has 32-bit integers, so the hex literal wraps negative; fold it
    -- to unsigned the same way image.lua's u32() does before comparing.
    local CHECK = 0xCBF43926 % 2 ^ 32   -- 3421780262
    eq(image.crc32(""), 0, "crc32('')")
    eq(image.crc32("123456789"), CHECK, "crc32('123456789')")
    -- Resumable: continuing must equal the one-shot value.
    local part = image.crc32("12345")
    eq(image.crc32("6789", part), CHECK, "crc32 resumed")
    -- Agrees with pngjs on a chunk body (the PNG round-trip tests rely on it).
    eq(image.crc32("IEND"), 0xAE426082 % 2 ^ 32, "crc32('IEND')")
end }

T[#T + 1] = { "solid_png round-trips through pngjs", function()
    local png = image.solid_png(4, 3, 10, 20, 30, 255)
    eq(png:sub(1, 8), "\137PNG\r\n\26\n", "png signature")
    local w, h, rgba = decode_png(png, "solid")
    eq(w, 4, "width"); eq(h, 3, "height")
    eq_pixels(rgba, rep(char(10, 20, 30, 255), 12), "solid pixels")
end }

T[#T + 1] = { "encode_png gradient round-trips exactly", function()
    local w, h = 5, 3
    local rows, expected = {}, {}
    for y = 1, h do
        local line = {}
        for x = 1, w do
            local px = char((x * 40 + y) % 256, (200 - x * 10 - y * 20) % 256, (x * y * 37) % 256, (255 - x * 7 - y * 11) % 256)
            line[x] = px
            expected[#expected + 1] = px
        end
        rows[y] = concat(line)
    end
    local steps = 0
    local png = image.encode_png(rows, w, h, function() steps = steps + 1 end)
    assert(steps >= 1, "step callback should be called at least once")
    local dw, dh, rgba = decode_png(png, "gradient")
    eq(dw, w, "width"); eq(dh, h, "height")
    eq_pixels(rgba, concat(expected), "gradient pixels")

    -- Every chunk CRC must match what pngjs would compute for the same data;
    -- the decode above already proves that, so also check a pngjs-encoded
    -- PNG of the same pixels decodes to the same thing (sanity on the harness).
    local ref = jtest.png_encode(w, h, concat(expected))
    local rw, rh, rrgba = decode_png(ref, "reference")
    eq(rw, w); eq(rh, h)
    eq_pixels(rrgba, rgba, "reference vs ours")
end }

T[#T + 1] = { "encode_png of an empty image still yields valid zlib", function()
    local png = image.encode_png({}, 0, 0)
    eq(image.sniff(png), "png")
    local dw, dh = image.dimensions(png, "png")
    eq(dw, 0, "w"); eq(dh, 0, "h")
end }

T[#T + 1] = { "dimensions from headers", function()
    local png = image.solid_png(4, 3, 0, 0, 0)
    local w, h = image.dimensions(png)
    eq(w, 4, "png w"); eq(h, 3, "png h")

    w, h = image.dimensions(GIF)
    eq(w, 13, "gif w"); eq(h, 7, "gif h")

    w, h = image.dimensions(BMP)
    eq(w, 21, "bmp w"); eq(h, 9, "bmp h")

    w, h = image.dimensions(JPG)
    eq(w, 17, "jpg w"); eq(h, 33, "jpg h")

    w, h = image.dimensions(TGA_PLAIN, "tga")
    eq(w, 2, "tga w"); eq(h, 2, "tga h")

    local blp = blp2({ encoding = 1, width = 4, height = 2, mips = {} })
    w, h = image.dimensions(blp)
    eq(w, 4, "blp w"); eq(h, 2, "blp h")

    eq(image.dimensions("\255\216\255\217"), nil, "jpg without SOF")
    eq(image.dimensions("nope"), nil, "unknown")
end }

T[#T + 1] = { "sniff classifies signatures", function()
    eq(image.sniff(image.solid_png(1, 1, 0, 0, 0)), "png", "png")
    eq(image.sniff(GIF), "gif", "gif")
    eq(image.sniff(BMP), "bmp", "bmp")
    eq(image.sniff(JPG), "jpg", "jpg")
    eq(image.sniff(TGA_PLAIN), "tga", "tga by structure")
    eq(image.sniff(TGA_PLAIN .. rep("\0", 8) .. "TRUEVISION-XFILE.\0"), "tga", "tga by footer")
    eq(image.sniff(rep("\0", 18), "tga"), "tga", "tga by extension hint")
    eq(image.sniff(rep("\0", 18)), "unknown", "zeros are unknown")
    eq(image.sniff(blp2({ encoding = 1, width = 1, height = 1, mips = {} })), "blp", "blp2")
    eq(image.sniff("BLP1" .. rep("\0", 20)), "blp1", "blp1")
    eq(image.sniff("BLP0" .. rep("\0", 20)), "blp1", "blp0")
    eq(image.sniff("ab"), "unknown", "too short")
    eq(image.sniff(nil), "unknown", "nil")
    eq(image.native_loadable("png"), true)
    eq(image.native_loadable("blp"), false)
end }

-- Shared palette fixture: 4x2, 8-bit alpha, one mip.
local function palette_blp()
    local indices = char(0, 5, 0, 5, 5, 0, 5, 0)
    local alphas = char(10, 20, 30, 40, 50, 60, 70, 80)
    local bytes = blp2({
        encoding = 1, alpha_depth = 8, alpha_encoding = 0, has_mips = 0,
        width = 4, height = 2,
        mips = { { offset = 1172, size = 4 * 2 * 2 } },
        palette = { [0] = { 1, 2, 3, 0 }, [5] = { 40, 50, 60, 0 } },
        data = indices .. alphas,
    })
    local p0, p5 = { 3, 2, 1 }, { 60, 50, 40 }
    local expected_rows = {
        char(3, 2, 1, 10) .. char(60, 50, 40, 20) .. char(3, 2, 1, 30) .. char(60, 50, 40, 40),
        char(60, 50, 40, 50) .. char(3, 2, 1, 60) .. char(60, 50, 40, 70) .. char(3, 2, 1, 80),
    }
    return bytes, expected_rows
end

T[#T + 1] = { "blp_header parses fields", function()
    local bytes = palette_blp()
    local h, err = image.blp_header(bytes)
    assert(h, err)
    eq(h.type, 1, "type"); eq(h.encoding, 1, "encoding"); eq(h.alpha_depth, 8, "alpha_depth")
    eq(h.alpha_encoding, 0, "alpha_encoding"); eq(h.has_mips, 0, "has_mips")
    eq(h.width, 4, "width"); eq(h.height, 2, "height")
    eq(h.mip_offsets[0], 1172, "mip_offsets[0]"); eq(h.mip_sizes[0], 16, "mip_sizes[0]")
    eq(h.mip_offsets[1], 0, "mip_offsets[1]")

    local _, e = image.blp_header("BLP1" .. rep("\0", 200))
    eq(e, "BLP1 (Warcraft III) is not supported", "blp1 error")
    _, e = image.blp_header("short")
    eq(e, "too short", "short error")
    _, e = image.blp_header(blp2({ type = 0, encoding = 1, width = 1, height = 1, mips = {} }))
    eq(e, "JPEG-compressed BLP is not supported", "jpeg error")
    _, e = image.blp_header(blp2({ encoding = 1, width = 0, height = 1, mips = {} }))
    eq(e, "implausible dimensions", "zero-size error")
end }

T[#T + 1] = { "decode_blp palette with 8-bit alpha", function()
    local bytes, expected = palette_blp()
    local steps = 0
    local img, err = image.decode_blp(bytes, { step = function() steps = steps + 1 end })
    assert(img, err)
    eq(img.w, 4, "w"); eq(img.h, 2, "h"); eq(img.level, 0, "level")
    eq(img.full_w, 4, "full_w"); eq(img.full_h, 2, "full_h")
    eq(#img.rows, 2, "row count")
    eq(steps, 2, "one step per row")
    -- rows[1] pixel 1 is R=3,G=2,B=1,A=10
    eq(img.rows[1]:sub(1, 4), char(3, 2, 1, 10), "rows[1] pixel 1")
    eq(img.rows[1]:sub(5, 8), char(60, 50, 40, 20), "rows[1] pixel 2")
    eq_pixels(img.rows[1], expected[1], "row 1")
    eq_pixels(img.rows[2], expected[2], "row 2")
end }

T[#T + 1] = { "to_native converts palette BLP to a PNG pngjs can read", function()
    local bytes, expected = palette_blp()
    local out, info = image.to_native(bytes, { ext = "blp" })
    assert(out, info.err)
    eq(info.kind, "blp", "kind"); eq(info.converted, true, "converted")
    eq(info.w, 4, "info.w"); eq(info.h, 2, "info.h"); eq(info.level, 0, "info.level")
    eq(image.sniff(out), "png", "output is png")
    local w, h, rgba = decode_png(out, "to_native")
    eq(w, 4, "w"); eq(h, 2, "h")
    eq_pixels(rgba, expected[1] .. expected[2], "to_native pixels")
end }

T[#T + 1] = { "to_native passes native formats through and reports errors", function()
    local png = image.solid_png(2, 2, 1, 2, 3)
    local out, info = image.to_native(png)
    eq(out, png, "png passthrough")
    eq(info.converted, false); eq(info.kind, "png"); eq(info.w, 2); eq(info.h, 2)

    out, info = image.to_native(GIF)
    eq(out, GIF, "gif passthrough"); eq(info.w, 13); eq(info.h, 7)

    out, info = image.to_native("BLP1" .. rep("\0", 200))
    eq(out, nil, "blp1 rejected"); eq(info.err, "BLP1 is not supported")

    out, info = image.to_native("garbage bytes here")
    eq(out, nil, "unknown rejected"); eq(info.err, "unrecognised image format")

    -- Truncated BLP: header ok, mip data missing.
    out, info = image.to_native(blp2({ encoding = 1, width = 4, height = 2,
        mips = { { offset = 1172, size = 8 } } }))
    eq(out, nil, "truncated rejected")
    eq(info.err, "mip level 0 is missing or truncated")
end }

T[#T + 1] = { "decode_blp palette with 1-bit and 4-bit alpha", function()
    -- 8x1, 1-bit alpha: bits 0b10100101 -> pixels 0,2,5,7 opaque.
    local bytes = blp2({
        encoding = 1, alpha_depth = 1, width = 8, height = 1,
        mips = { { offset = 1172, size = 9 } },
        palette = { [0] = { 0, 0, 255, 0 } },
        data = rep("\0", 8) .. char(0xA5),
    })
    local img, err = image.decode_blp(bytes)
    assert(img, err)
    local expect = {}
    for p = 0, 7 do
        local on = (p == 0 or p == 2 or p == 5 or p == 7)
        expect[#expect + 1] = char(255, 0, 0, on and 255 or 0)
    end
    eq_pixels(img.rows[1], concat(expect), "1-bit alpha")

    -- 2x1, 4-bit alpha: byte 0xF3 -> pixel 0 low nibble 3 -> 51, pixel 1 high nibble 15 -> 255.
    bytes = blp2({
        encoding = 1, alpha_depth = 4, width = 2, height = 1,
        mips = { { offset = 1172, size = 3 } },
        palette = { [0] = { 0, 0, 0, 0 } },
        data = "\0\0" .. char(0xF3),
    })
    img, err = image.decode_blp(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(0, 0, 0, 51) .. char(0, 0, 0, 255), "4-bit alpha")
end }

T[#T + 1] = { "decode_blp DXT1 blocks", function()
    local function dxt1(index_byte)
        return blp2({
            encoding = 2, alpha_depth = 0, alpha_encoding = 0, width = 4, height = 4,
            mips = { { offset = 1172, size = 8 } },
            data = u16le(0xF800) .. u16le(0x001F) .. rep(char(index_byte), 4),
        })
    end
    local img, err = image.decode_blp(dxt1(0x00))
    assert(img, err)
    eq(img.w, 4, "w"); eq(img.h, 4, "h"); eq(#img.rows, 4, "rows")
    for y = 1, 4 do
        eq_pixels(img.rows[y], rep(char(255, 0, 0, 255), 4), "red row " .. y)
    end

    img, err = image.decode_blp(dxt1(0x55))
    assert(img, err)
    for y = 1, 4 do
        eq_pixels(img.rows[y], rep(char(0, 0, 255, 255), 4), "blue row " .. y)
    end

    -- Indices 2 and 3 in 4-colour mode: thirds between red and blue.
    img, err = image.decode_blp(dxt1(0xAA))
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(170, 0, 85, 255), 4), "two-thirds red")
    img, err = image.decode_blp(dxt1(0xFF))
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(85, 0, 170, 255), 4), "one-third red")

    -- 3-colour mode (c0 <= c1): index 3 is transparent black.
    local three = blp2({
        encoding = 2, width = 4, height = 4,
        mips = { { offset = 1172, size = 8 } },
        data = u16le(0x001F) .. u16le(0xF800) .. rep(char(0xFF), 4),
    })
    img, err = image.decode_blp(three)
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(0, 0, 0, 0), 4), "3-colour transparent")

    -- Non-multiple-of-4 size: 6x5 uses 2x2 blocks but only keeps 6x5 pixels.
    local odd = blp2({
        encoding = 2, width = 6, height = 5,
        mips = { { offset = 1172, size = 8 * 4 } },
        data = rep(u16le(0xF800) .. u16le(0x001F) .. rep("\0", 4), 4),
    })
    img, err = image.decode_blp(odd)
    assert(img, err)
    eq(img.w, 6); eq(img.h, 5); eq(#img.rows, 5, "rows for 6x5")
    for y = 1, 5 do eq(#img.rows[y], 24, "row " .. y .. " bytes") end
end }

T[#T + 1] = { "decode_blp DXT5 block", function()
    local block = char(255, 0) .. rep("\0", 6)         -- alpha: a0=255, a1=0, all indices 0
        .. u16le(0x07E0) .. u16le(0x0000) .. rep("\0", 4)  -- colour: c0=green, indices 0
    local bytes = blp2({
        encoding = 2, alpha_depth = 8, alpha_encoding = 7, width = 4, height = 4,
        mips = { { offset = 1172, size = 16 } },
        data = block,
    })
    local img, err = image.decode_blp(bytes)
    assert(img, err)
    for y = 1, 4 do
        eq_pixels(img.rows[y], rep(char(0, 255, 0, 255), 4), "green row " .. y)
    end

    -- Alpha index 1 everywhere -> a1 = 0. 3-bit indices all 1: 0b001001001... = 0x49 0x92 0x24 per half.
    block = char(255, 0) .. char(0x49, 0x92, 0x24, 0x49, 0x92, 0x24)
        .. u16le(0x07E0) .. u16le(0x0000) .. rep("\0", 4)
    bytes = blp2({
        encoding = 2, alpha_depth = 8, alpha_encoding = 7, width = 4, height = 4,
        mips = { { offset = 1172, size = 16 } },
        data = block,
    })
    img, err = image.decode_blp(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(0, 255, 0, 0), 4), "alpha index 1")

    -- Alpha index 2 with a0=255,a1=0 -> (6*255)/7 = 218.
    block = char(255, 0) .. char(0x92, 0x24, 0x49, 0x92, 0x24, 0x49)
        .. u16le(0x07E0) .. u16le(0x0000) .. rep("\0", 4)
    bytes = blp2({
        encoding = 2, alpha_depth = 8, alpha_encoding = 7, width = 4, height = 4,
        mips = { { offset = 1172, size = 16 } },
        data = block,
    })
    img, err = image.decode_blp(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(0, 255, 0, 218), 4), "alpha index 2")
end }

T[#T + 1] = { "decode_blp DXT3 block", function()
    -- Alpha nibbles: 0x0F -> pixel0 = 15*17 = 255, pixel1 = 0; repeat.
    local block = rep(char(0x0F), 8) .. u16le(0x07E0) .. u16le(0x0000) .. rep("\0", 4)
    local bytes = blp2({
        encoding = 2, alpha_depth = 8, alpha_encoding = 1, width = 4, height = 4,
        mips = { { offset = 1172, size = 16 } },
        data = block,
    })
    local img, err = image.decode_blp(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], rep(char(0, 255, 0, 255) .. char(0, 255, 0, 0), 2), "dxt3 alpha")
end }

T[#T + 1] = { "decode_blp uncompressed BGRA", function()
    local bytes = blp2({
        encoding = 3, alpha_depth = 8, width = 2, height = 1,
        mips = { { offset = 1172, size = 8 } },
        data = char(1, 2, 3, 4) .. char(5, 6, 7, 8),
    })
    local img, err = image.decode_blp(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(3, 2, 1, 4) .. char(7, 6, 5, 8), "bgra")
end }

T[#T + 1] = { "decode_blp max_dim picks a stored mip", function()
    -- 8x8 palette image, no alpha, mip 0 (64 bytes) and mip 1 (4x4, 16 bytes).
    local mip0 = rep("\0", 64)
    local mip1 = rep(char(5), 16)
    local bytes = blp2({
        encoding = 1, alpha_depth = 0, has_mips = 1, width = 8, height = 8,
        mips = { { offset = 1172, size = 64 }, { offset = 1172 + 64, size = 16 } },
        palette = { [0] = { 1, 2, 3, 0 }, [5] = { 40, 50, 60, 0 } },
        data = mip0 .. mip1,
    })
    local img, err = image.decode_blp(bytes, { max_dim = 4 })
    assert(img, err)
    eq(img.level, 1, "level"); eq(img.w, 4, "w"); eq(img.h, 4, "h")
    eq(img.full_w, 8, "full_w"); eq(img.full_h, 8, "full_h")
    eq(#img.rows, 4, "rows")
    for y = 1, 4 do eq_pixels(img.rows[y], rep(char(60, 50, 40, 255), 4), "mip1 row " .. y) end

    -- Asking for a size no stored mip fits stops at the last stored level.
    img, err = image.decode_blp(bytes, { max_dim = 1 })
    assert(img, err)
    eq(img.level, 1, "level clamps to stored mips"); eq(img.w, 4)

    -- No limit -> level 0, full size.
    img, err = image.decode_blp(bytes)
    assert(img, err)
    eq(img.level, 0); eq(img.w, 8); eq(img.h, 8)
    eq_pixels(img.rows[1], rep(char(3, 2, 1, 255), 8), "mip0 row")

    -- max_dim that already fits -> level 0.
    img = image.decode_blp(bytes, { max_dim = 8 })
    eq(img.level, 0, "fits at level 0")

    -- to_native carries the level through.
    local out, info = image.to_native(bytes, { max_dim = 4 })
    assert(out, info.err)
    eq(info.level, 1); eq(info.w, 4); eq(info.h, 4); eq(info.full_w, 8)
    local w, h = decode_png(out, "mip png")
    eq(w, 4); eq(h, 4)
end }

T[#T + 1] = { "decode_tga 24-bit uncompressed bottom-up", function()
    -- File order is bottom row first; pixels are stored BGR.
    local bottom = char(30, 20, 10) .. char(60, 50, 40)
    local top = char(90, 80, 70) .. char(120, 110, 100)
    local bytes = tga_header({ image_type = 2, w = 2, h = 2, depth = 24, desc = 0 }) .. bottom .. top
    eq(image.sniff(bytes), "tga", "sniff")
    local steps = 0
    local img, err = image.decode_tga(bytes, { step = function() steps = steps + 1 end })
    assert(img, err)
    eq(img.w, 2, "w"); eq(img.h, 2, "h"); eq(steps, 2, "steps")
    eq_pixels(img.rows[1], char(70, 80, 90, 255) .. char(100, 110, 120, 255), "top row")
    eq_pixels(img.rows[2], char(10, 20, 30, 255) .. char(40, 50, 60, 255), "bottom row")

    -- Same pixels flagged top-down (descriptor bit 5) keep file order.
    bytes = tga_header({ image_type = 2, w = 2, h = 2, depth = 24, desc = 32 }) .. bottom .. top
    img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(10, 20, 30, 255) .. char(40, 50, 60, 255), "top-down row 1")

    -- Truncated data is rejected.
    local _, e = image.decode_tga(tga_header({ image_type = 2, w = 2, h = 2, depth = 24 }) .. bottom)
    eq(e, "truncated TGA", "truncated")

    -- to_native with force_tga produces a PNG of the decoded rows.
    bytes = tga_header({ image_type = 2, w = 2, h = 2, depth = 24, desc = 0 }) .. bottom .. top
    local out, info = image.to_native(bytes, { force_tga = true })
    assert(out, info.err)
    eq(info.converted, true); eq(info.kind, "tga")
    local w, h, rgba = decode_png(out, "tga png")
    eq(w, 2); eq(h, 2)
    eq_pixels(rgba, char(70, 80, 90, 255) .. char(100, 110, 120, 255) .. char(10, 20, 30, 255) .. char(40, 50, 60, 255), "tga png pixels")
    -- Without force_tga the bytes pass through untouched.
    out, info = image.to_native(bytes)
    eq(out, bytes, "tga passthrough"); eq(info.converted, false)
end }

T[#T + 1] = { "decode_tga 32-bit RLE", function()
    -- 2x2 top-down. Packet 1: run of 2 x BGRA(1,2,3,4). Packet 2: raw 2 pixels.
    local data = char(0x81) .. char(1, 2, 3, 4)
        .. char(0x01) .. char(5, 6, 7, 8) .. char(9, 10, 11, 12)
    local bytes = tga_header({ image_type = 10, w = 2, h = 2, depth = 32, desc = 32 + 8 }) .. data
    eq(image.sniff(bytes), "tga", "sniff rle")
    local img, err = image.decode_tga(bytes)
    assert(img, err)
    eq(img.w, 2); eq(img.h, 2)
    eq_pixels(img.rows[1], char(3, 2, 1, 4) .. char(3, 2, 1, 4), "run packet row")
    eq_pixels(img.rows[2], char(7, 6, 5, 8) .. char(11, 10, 9, 12), "raw packet row")

    -- Bottom-up RLE flips the rows.
    bytes = tga_header({ image_type = 10, w = 2, h = 2, depth = 32, desc = 8 }) .. data
    img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(7, 6, 5, 8) .. char(11, 10, 9, 12), "bottom-up row 1")
    eq_pixels(img.rows[2], char(3, 2, 1, 4) .. char(3, 2, 1, 4), "bottom-up row 2")

    -- A short RLE stream pads the remaining pixels with transparent black.
    bytes = tga_header({ image_type = 10, w = 2, h = 2, depth = 32, desc = 32 }) .. char(0x81) .. char(1, 2, 3, 4)
    img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[2], rep("\0\0\0\0", 2), "padded row")
end }

T[#T + 1] = { "decode_tga greyscale, 16-bit and colour-mapped", function()
    -- 8-bit greyscale (type 3), 2x1.
    local bytes = tga_header({ image_type = 3, w = 2, h = 1, depth = 8, desc = 32 }) .. char(7, 200)
    local img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(7, 7, 7, 255) .. char(200, 200, 200, 255), "grey")

    -- 16-bit ARRRRRGG GGGBBBBB: r=31,g=0,b=31 -> 0x7C1F -> (248,0,248).
    bytes = tga_header({ image_type = 2, w = 1, h = 1, depth = 16, desc = 32 }) .. u16le(0x7C1F)
    img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(248, 0, 248, 255), "16-bit")

    -- Colour-mapped (type 1), 24-bit palette with two entries, 2x1.
    bytes = tga_header({ image_type = 1, cmap_type = 1, cmap_len = 2, cmap_bits = 24, w = 2, h = 1, depth = 8, desc = 32 })
        .. char(1, 2, 3) .. char(4, 5, 6)
        .. char(1, 0)
    img, err = image.decode_tga(bytes)
    assert(img, err)
    eq_pixels(img.rows[1], char(6, 5, 4, 255) .. char(3, 2, 1, 255), "colour-mapped")

    -- Unsupported type.
    local _, e = image.decode_tga(tga_header({ image_type = 7, w = 1, h = 1, depth = 8 }) .. "\0")
    eq(e, "unsupported TGA type 7", "bad type")
end }

return T

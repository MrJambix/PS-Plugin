-- The pure-Lua inflater against Node's zlib as the oracle: every block type,
-- the window flush, the raw and zlib wrappers, and the ways it must fail.

local inflate = require("jcore/lib/inflate")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label,
            tostring(want):sub(1, 60), tostring(got):sub(1, 60)), 2)
    end
end

--- Deterministic pseudo-text, compressible but not trivially so.
local function prose(n)
    local words = { "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "warrior", "shaman",
        "Interface", "Icons", "ClassIcon", "BLTE", "root", "encoding", "0123456789", "zlib" }
    local parts, len, seed = {}, 0, 12345
    while len < n do
        seed = (seed * 1103515245 + 12345) % 2147483648
        local w = words[(seed % #words) + 1]
        parts[#parts + 1] = w
        len = len + #w + 1
    end
    return table.concat(parts, " "):sub(1, n)
end

--- Every byte value, in a pattern with some repetition.
local function binary(n)
    local t = {}
    for i = 1, n do t[i] = string.char((i * 7 + math.floor(i / 13)) % 256) end
    return table.concat(t)
end

local function roundtrip(label, plain, level, opts)
    local z = jtest.deflate(plain, level)
    local out, err = inflate.zlib(z, opts)
    assert(out, label .. ": " .. tostring(err))
    assert_eq(#out, #plain, label .. " length")
    assert(out == plain, label .. ": content differs")
    return z
end

local T = {}

T[#T + 1] = { "empty input", function()
    roundtrip("empty", "", 6)
    roundtrip("empty stored", "", 0)
end }

T[#T + 1] = { "tiny inputs use fixed codes", function()
    roundtrip("a", "a", 6)
    roundtrip("hello", "hello hello hello hello", 6)
    roundtrip("hello stored", "hello hello hello hello", 0)
end }

T[#T + 1] = { "dynamic blocks over compressible text", function()
    roundtrip("prose 8k", prose(8000), 9)
    roundtrip("prose 8k fast", prose(8000), 1)
end }

T[#T + 1] = { "every byte value, overlapping copies", function()
    roundtrip("binary 4k", binary(4096), 6)
    roundtrip("runs", string.rep("ab", 3000) .. string.rep("x", 1000) .. string.rep("abc", 500), 6)
end }

T[#T + 1] = { "stored blocks larger than one block", function()
    -- Stored blocks hold at most 65535 bytes, so this is several of them.
    roundtrip("stored 70k", prose(70000), 0)
end }

T[#T + 1] = { "the window flushes and copies still reach back", function()
    local steps = 0
    local plain = prose(150000) .. binary(20000) .. prose(10000)
    roundtrip("flush 180k", plain, 6, { step = function() steps = steps + 1 end })
    assert(steps >= 80, "step every 2 KB of output: 180 KB should give 80+, got " .. steps)
end }

T[#T + 1] = { "raw deflate without the zlib wrapper", function()
    local plain = prose(3000)
    local z = jtest.deflate(plain, 6)
    local raw = z:sub(3, #z - 4)
    local out, err = inflate.raw(raw)
    assert(out, tostring(err))
    assert(out == plain, "raw content differs")
end }

T[#T + 1] = { "the oracle agrees with itself on the same bytes", function()
    -- Guards the fixture, not the inflater: Node inflates what Node deflated.
    local plain = prose(2000)
    local back = jtest.inflate(jtest.deflate(plain, 6))
    assert(back == plain, "oracle roundtrip")
end }

T[#T + 1] = { "bad input fails with a reason, never raises", function()
    local out, err = inflate.zlib("")
    assert(not out and err, "empty")
    out, err = inflate.zlib("\120\156" .. string.rep("\255", 40))
    assert(not out and err, "garbage after header: " .. tostring(err))
    out, err = inflate.zlib("\0\0" .. string.rep("\0", 10))
    assert(not out and err and err:find("not deflate", 1, true), "bad CM: " .. tostring(err))
    out, err = inflate.zlib("\120\157" .. string.rep("\0", 10))
    assert(not out and err and err:find("header check", 1, true), "bad FCHECK: " .. tostring(err))
    local z = jtest.deflate(prose(5000), 6)
    out, err = inflate.zlib(z:sub(1, math.floor(#z / 2)))
    assert(not out and err, "truncated: " .. tostring(err))
    out, err = inflate.zlib(jtest.deflate(prose(5000), 6), { limit = 100 })
    assert(not out and err and err:find("limit", 1, true), "limit: " .. tostring(err))
end }

return T

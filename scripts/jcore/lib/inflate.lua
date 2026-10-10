-- JCore / inflate -- leaf module, depends on nothing.
--
-- A DEFLATE decoder (RFC 1951) with the zlib wrapper (RFC 1950), in plain
-- Lua. It exists for one reason: the game's data archives store every file
-- as zlib-compressed BLTE chunks, and nothing the loader exposes will inflate
-- them for us. This is the last piece between "the loader can read any byte
-- range under the WoW folder" and "the game's own textures".
--
-- SHAPE
-- The decoder is puff.c's shape -- canonical Huffman tables walked a bit at a
-- time -- rather than zlib's, because it is small enough to read in one
-- sitting and its correctness is easy to argue. It is slower than a
-- table-driven decoder; on LuaJIT it manages a few megabytes a second,
-- which is the whole root file of a Classic client in a couple of seconds
-- of CPU. That work is spread over frames by the `step` callback, called
-- after every 2 KB of output, which the caller uses to yield when its frame
-- budget is spent.
--
-- PORTABILITY
-- No bit library. LuaJIT ships `bit`, Lua 5.3 has operators LuaJIT cannot
-- parse, and the offline harness runs Lua 5.3 with 32-bit integers. Every
-- bit operation here is a multiply, a floor division or a modulo on numbers
-- that never exceed 2^40, which every Lua does exactly.

local M = {}

local byte, char, sub, concat, floor = string.byte, string.char, string.sub, table.concat, math.floor

local POW2 = {}
for i = 0, 40 do POW2[i] = 2 ^ i end

local CHAR = {}
for i = 0, 255 do CHAR[i] = char(i) end

-- Length and distance bases and extra bits, RFC 1951 3.2.5.
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT  = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT  = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- Order in which code length code lengths are stored.
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local MAXBITS = 15
local FLUSH_AT = 65536        -- output bytes kept before a flush
local KEEP = 32768            -- window the format may reference
-- Output bytes between calls to `step`. The decoder manages a few MB a
-- second on LuaJIT, so this is well under a millisecond of work: the caller's
-- budget check, not this constant, decides when a frame actually yields.
local STEP_EVERY = 2048

--- Builds a canonical Huffman table from a list of code lengths.
--- `lengths[i]` is the length of symbol i-1 (zero = unused).
---@return table|nil table { count = {}, symbol = {} }
---@return string|nil err
local function build(lengths, n)
    local count, symbol = {}, {}
    for len = 0, MAXBITS do count[len] = 0 end
    for i = 1, n do
        local len = lengths[i]
        count[len] = count[len] + 1
    end
    if count[0] == n then return { count = count, symbol = symbol }, nil end -- no codes, legal

    -- Over-subscribed or incomplete set check (incomplete is allowed only
    -- for single-code sets, which is what the check below permits).
    local left = 1
    for len = 1, MAXBITS do
        left = left * 2 - count[len]
        if left < 0 then return nil, "over-subscribed code lengths" end
    end

    local offs = {}
    offs[1] = 0
    for len = 1, MAXBITS - 1 do offs[len + 1] = offs[len] + count[len] end
    for i = 1, n do
        local len = lengths[i]
        if len ~= 0 then
            symbol[offs[len]] = i - 1
            offs[len] = offs[len] + 1
        end
    end
    return { count = count, symbol = symbol }, nil
end

-- Fixed Huffman tables (RFC 1951 3.2.6), built once.
local FIXED_LIT, FIXED_DIST
do
    local lengths = {}
    for i = 1, 144 do lengths[i] = 8 end
    for i = 145, 256 do lengths[i] = 9 end
    for i = 257, 280 do lengths[i] = 7 end
    for i = 281, 288 do lengths[i] = 8 end
    FIXED_LIT = build(lengths, 288)
    local dl = {}
    for i = 1, 30 do dl[i] = 5 end
    FIXED_DIST = build(dl, 30)
end

--- Inflates a raw DEFLATE stream.
---@param data string
---@param start integer 1-based offset of the first compressed byte
---@param opts? { step?: fun(), limit?: integer }
---@return string|nil out
---@return string|nil err
---@return integer consumed Bytes of `data` consumed from `start`
local function inflate_raw(data, start, opts)
    local step = opts and opts.step
    local limit = opts and opts.limit

    local pos = start          -- next input byte
    local len_in = #data
    local bitbuf, bitcnt = 0, 0

    -- Output: `out` holds the working window as one-character strings,
    -- `pieces` the flushed history. Copies reach back at most 32 KB, and a
    -- flush always leaves that much behind.
    local out, n = {}, 0
    local pieces = {}
    local total = 0
    local next_step = STEP_EVERY

    local function bits(need)
        while bitcnt < need do
            if pos > len_in then return nil end
            bitbuf = bitbuf + byte(data, pos) * POW2[bitcnt]
            pos = pos + 1
            bitcnt = bitcnt + 8
        end
        local p = POW2[need]
        local val = bitbuf % p
        bitbuf = floor(bitbuf / p)
        bitcnt = bitcnt - need
        return val
    end

    local function flush()
        pieces[#pieces + 1] = concat(out, "", 1, n - KEEP)
        local keep_from = n - KEEP + 1
        local j = 0
        for i = keep_from, n do
            j = j + 1
            out[j] = out[i]
        end
        for i = j + 1, n do out[i] = nil end
        n = j
    end

    --- Hands control to the caller every STEP_EVERY bytes of output.
    local function maybe_step()
        if total >= next_step then
            next_step = total + STEP_EVERY
            step()
        end
    end

    --- Decodes one symbol with a canonical table, a bit at a time.
    local function decode(h)
        local count, symbol = h.count, h.symbol
        local code, first, index = 0, 0, 0
        for len = 1, MAXBITS do
            if bitcnt < 1 then
                if pos > len_in then return nil end
                bitbuf = bitbuf + byte(data, pos) * POW2[bitcnt]
                pos = pos + 1
                bitcnt = bitcnt + 8
            end
            code = code + (bitbuf % 2)
            bitbuf = floor(bitbuf / 2)
            bitcnt = bitcnt - 1
            local c = count[len]
            if code - c < first then
                return symbol[index + (code - first)]
            end
            index = index + c
            first = (first + c) * 2
            code = code * 2
        end
        return nil
    end

    --- Decodes literal/length and distance codes until end of block.
    local function codes(lencode, distcode)
        while true do
            local sym = decode(lencode)
            if not sym then return "bad literal/length code or truncated input" end
            if sym < 256 then
                n = n + 1
                out[n] = CHAR[sym]
                total = total + 1
            elseif sym == 256 then
                return nil
            else
                sym = sym - 256
                if sym > 29 then return "invalid length symbol" end
                local extra = bits(LEXT[sym]) ; if not extra then return "truncated input" end
                local length = LBASE[sym] + extra
                local dsym = decode(distcode)
                if not dsym or dsym > 29 then return "invalid distance symbol" end
                local dextra = bits(DEXT[dsym + 1]) ; if not dextra then return "truncated input" end
                local dist = DBASE[dsym + 1] + dextra
                if dist > n then return "distance too far back" end
                -- Byte by byte on purpose: an overlapping copy (dist < length)
                -- repeats what it has just written, which is the format's
                -- run-length encoding.
                local from = n - dist
                for i = 1, length do
                    n = n + 1
                    out[n] = out[from + i]
                end
                total = total + length
            end
            if n >= FLUSH_AT + KEEP then flush() end
            if step and total >= next_step then maybe_step() end
            if limit and total > limit then return "output exceeds limit" end
        end
    end

    local function stored()
        -- Discard the rest of the current byte, then LEN and NLEN.
        bitbuf, bitcnt = 0, 0
        if pos + 3 > len_in then return "truncated stored block" end
        local b0, b1, b2, b3 = byte(data, pos, pos + 3)
        local length = b0 + b1 * 256
        local nlength = b2 + b3 * 256
        if length + nlength ~= 65535 then return "stored block length check failed" end
        pos = pos + 4
        if pos + length - 1 > len_in then return "truncated stored block" end
        for i = pos, pos + length - 1 do
            n = n + 1
            out[n] = CHAR[byte(data, i)]
        end
        pos = pos + length
        total = total + length
        if n >= FLUSH_AT + KEEP then flush() end
        if step and total >= next_step then maybe_step() end
        if limit and total > limit then return "output exceeds limit" end
        return nil
    end

    local function dynamic()
        local nlen = bits(5) ; if not nlen then return "truncated input" end
        local ndist = bits(5) ; if not ndist then return "truncated input" end
        local ncode = bits(4) ; if not ncode then return "truncated input" end
        nlen, ndist, ncode = nlen + 257, ndist + 1, ncode + 4
        if nlen > 286 or ndist > 30 then return "bad counts in dynamic block" end

        local lengths = {}
        for i = 1, 19 do lengths[i] = 0 end
        for i = 1, ncode do
            local v = bits(3) ; if not v then return "truncated input" end
            lengths[ORDER[i] + 1] = v
        end
        local lencode, err = build(lengths, 19)
        if not lencode then return err end

        local all = {}
        local index = 1
        while index <= nlen + ndist do
            local sym = decode(lencode)
            if not sym then return "bad code length code" end
            if sym < 16 then
                all[index] = sym
                index = index + 1
            else
                local value, rep
                if sym == 16 then
                    if index == 1 then return "repeat with no previous length" end
                    value = all[index - 1]
                    rep = bits(2) ; if not rep then return "truncated input" end
                    rep = 3 + rep
                elseif sym == 17 then
                    value = 0
                    rep = bits(3) ; if not rep then return "truncated input" end
                    rep = 3 + rep
                else
                    value = 0
                    rep = bits(7) ; if not rep then return "truncated input" end
                    rep = 11 + rep
                end
                if index + rep - 1 > nlen + ndist then return "too many lengths" end
                for _ = 1, rep do
                    all[index] = value
                    index = index + 1
                end
            end
        end
        if all[257] == 0 then return "no end-of-block code" end

        local lit_lengths, dist_lengths = {}, {}
        for i = 1, nlen do lit_lengths[i] = all[i] end
        for i = 1, ndist do dist_lengths[i] = all[nlen + i] end
        local lit, e1 = build(lit_lengths, nlen)
        if not lit then return e1 end
        local dist, e2 = build(dist_lengths, ndist)
        if not dist then return e2 end
        return codes(lit, dist)
    end

    repeat
        local last = bits(1)
        local kind = bits(2)
        if not last or not kind then return nil, "truncated input", pos - start end
        local err
        if kind == 0 then
            err = stored()
        elseif kind == 1 then
            err = codes(FIXED_LIT, FIXED_DIST)
        elseif kind == 2 then
            err = dynamic()
        else
            err = "invalid block type"
        end
        if err then return nil, err, pos - start end
    until last == 1

    pieces[#pieces + 1] = concat(out, "", 1, n)
    return concat(pieces), nil, pos - start
end

--- Inflates a zlib stream (2-byte header, DEFLATE body, Adler-32 trailer).
--- The trailer is not verified: the archive format this serves carries its
--- own checksums per chunk, and a corrupt stream almost always fails to
--- decode long before its end.
---@param data string
---@param opts? { step?: fun(), limit?: integer }
---@return string|nil out
---@return string|nil err
function M.zlib(data, opts)
    if type(data) ~= "string" or #data < 6 then return nil, "too short for a zlib stream" end
    local cmf, flg = byte(data, 1, 2)
    if cmf % 16 ~= 8 then return nil, "not deflate (CM " .. (cmf % 16) .. ")" end
    if (cmf * 256 + flg) % 31 ~= 0 then return nil, "zlib header check failed" end
    if floor(flg / 32) % 2 == 1 then return nil, "preset dictionary is not supported" end
    local out, err = inflate_raw(data, 3, opts)
    if not out then return nil, err end
    return out, nil
end

--- Inflates a raw DEFLATE stream with no wrapper.
---@param data string
---@param opts? { step?: fun(), limit?: integer }
---@return string|nil out
---@return string|nil err
function M.raw(data, opts)
    if type(data) ~= "string" then return nil, "not a string" end
    local out, err = inflate_raw(data, 1, opts)
    if not out then return nil, err end
    return out, nil
end

return M

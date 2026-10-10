-- JCore / json -- leaf module, depends on nothing.
--
-- Written rather than borrowed because the two things that need it -- the HTTP
-- service and on-disk storage -- are both load-bearing, and a runtime that
-- fails to boot because an optional third-party JSON library is missing is a
-- worse outcome than carrying two hundred lines.
--
-- Decoding is strict enough to reject malformed input with a useful message
-- instead of returning a half-built table. Encoding is deterministic: object
-- keys come out sorted, so a settings file written twice with the same content
-- is byte-identical and diffs cleanly.
--
-- LUA HAS NO NULL
-- A JSON null cannot be stored as nil, because a nil value in a Lua table is
-- indistinguishable from an absent key -- `{"a": null}` and `{}` would decode
-- to the same thing. Nulls decode to json.null, a unique sentinel, and encode
-- back to null. Compare against json.null rather than testing for nil.

local M = {}

local NULL = setmetatable({}, { __tostring = function() return "null" end })
M.null = NULL

-- --- encoding ---------------------------------------------------------------

local ESCAPE = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

local function escape_char(c)
    local mapped = ESCAPE[c]
    if mapped then return mapped end
    return string.format("\\u%04x", c:byte())
end

local function encode_string(s)
    -- Control characters below 0x20 are illegal raw in a JSON string, so they
    -- go through the \u escape even though they are not in the table above.
    return '"' .. s:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        -- JSON has no way to spell these. Writing them out produces a document
        -- no parser will read back, so refuse rather than emit one.
        error("json: cannot encode " .. tostring(n))
    end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    -- 17 significant digits round-trips an IEEE double exactly.
    return string.format("%.17g", n)
end

--- Is this table an array? Empty tables encode as arrays, which is the
--- convention that keeps a list that happens to be empty from becoming {}.
local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true
end

local encode_value

local function encode_table(t, indent, depth)
    if t == NULL then return "null" end
    if depth > 200 then error("json: nesting too deep (cyclic table?)") end

    local newline, pad, pad_inner = "", "", ""
    if indent then
        newline = "\n"
        pad = string.rep(indent, depth)
        pad_inner = string.rep(indent, depth + 1)
    end

    if is_array(t) then
        local n = #t
        if n == 0 then return "[]" end
        local parts = {}
        for i = 1, n do
            parts[i] = pad_inner .. encode_value(t[i], indent, depth + 1)
        end
        return "[" .. newline .. table.concat(parts, "," .. newline) .. newline .. pad .. "]"
    end

    -- Keys are sorted so the same table always produces the same bytes.
    -- Without this a settings file rewrites itself differently every save and
    -- nobody can tell a real change from a reordering.
    local keys = {}
    for k in pairs(t) do
        if type(k) == "string" or type(k) == "number" then
            keys[#keys + 1] = k
        end
    end
    if #keys == 0 then return "{}" end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for i = 1, #keys do
        local k = keys[i]
        parts[i] = pad_inner .. encode_string(tostring(k)) .. ":" ..
            (indent and " " or "") .. encode_value(t[k], indent, depth + 1)
    end
    return "{" .. newline .. table.concat(parts, "," .. newline) .. newline .. pad .. "}"
end

encode_value = function(v, indent, depth)
    local kind = type(v)
    if v == NULL then return "null" end
    if kind == "nil" then return "null" end
    if kind == "boolean" then return v and "true" or "false" end
    if kind == "number" then return encode_number(v) end
    if kind == "string" then return encode_string(v) end
    if kind == "table" then return encode_table(v, indent, depth) end
    error("json: cannot encode a " .. kind)
end

--- Serialises a value.
---@param value any
---@param opts? { pretty?: boolean, indent?: string }
---@return string|nil json
---@return string|nil error
function M.encode(value, opts)
    opts = opts or {}
    local indent = opts.pretty and (opts.indent or "  ") or nil
    local ok, result = pcall(encode_value, value, indent, 0)
    if not ok then return nil, tostring(result) end
    return result
end

-- --- decoding ---------------------------------------------------------------

local UNESCAPE = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local Parser = {}
Parser.__index = Parser

function Parser:error(message)
    -- Report a line number rather than a byte offset. A byte offset into a
    -- fifty-kilobyte API response tells nobody anything.
    local line = 1
    for _ in self.text:sub(1, self.pos):gmatch("\n") do line = line + 1 end
    error(string.format("json: %s at line %d (offset %d)", message, line, self.pos), 0)
end

function Parser:skip_space()
    local _, stop = self.text:find("^[ \t\r\n]*", self.pos)
    self.pos = stop + 1
end

function Parser:peek()
    return self.text:sub(self.pos, self.pos)
end

function Parser:expect(char)
    if self:peek() ~= char then
        self:error("expected '" .. char .. "' but found '" .. self:peek() .. "'")
    end
    self.pos = self.pos + 1
end

--- Encodes a code point as UTF-8. Lua 5.1 has no utf8 library and this
--- runtime may be on it, so the four cases are spelled out.
local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

function Parser:parse_string()
    self:expect('"')
    local parts = {}
    local n = 0

    while true do
        local char = self:peek()
        if char == "" then self:error("unterminated string") end

        if char == '"' then
            self.pos = self.pos + 1
            return table.concat(parts, "", 1, n)
        end

        if char == "\\" then
            self.pos = self.pos + 1
            local code = self:peek()
            self.pos = self.pos + 1

            if code == "u" then
                local hex = self.text:sub(self.pos, self.pos + 3)
                if not hex:match("^%x%x%x%x$") then self:error("bad \\u escape") end
                self.pos = self.pos + 4
                local value = tonumber(hex, 16)

                -- A character outside the basic plane arrives as a surrogate
                -- pair. Decoding the halves separately produces two invalid
                -- code points instead of one valid character.
                if value >= 0xD800 and value <= 0xDBFF and self.text:sub(self.pos, self.pos + 1) == "\\u" then
                    local low_hex = self.text:sub(self.pos + 2, self.pos + 5)
                    local low = tonumber(low_hex, 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        self.pos = self.pos + 6
                        value = 0x10000 + (value - 0xD800) * 0x400 + (low - 0xDC00)
                    end
                end

                n = n + 1
                parts[n] = utf8_char(value)
            else
                local mapped = UNESCAPE[code]
                if not mapped then self:error("bad escape '\\" .. code .. "'") end
                n = n + 1
                parts[n] = mapped
            end
        else
            -- Take the whole run up to the next quote or backslash in one go
            -- rather than a character at a time; most strings have no escapes
            -- at all and this makes them a single substring.
            local chunk_end = self.text:find('["\\]', self.pos)
            if not chunk_end then self:error("unterminated string") end
            n = n + 1
            parts[n] = self.text:sub(self.pos, chunk_end - 1)
            self.pos = chunk_end
        end
    end
end

function Parser:parse_number()
    local start, stop = self.text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", self.pos)
    if not start then self:error("bad number") end
    local value = tonumber(self.text:sub(start, stop))
    if not value then self:error("bad number '" .. self.text:sub(start, stop) .. "'") end
    self.pos = stop + 1
    return value
end

function Parser:parse_value(depth)
    if depth > 200 then self:error("nesting too deep") end
    self:skip_space()
    local char = self:peek()

    if char == "" then self:error("unexpected end of input") end
    if char == '"' then return self:parse_string() end
    if char == "{" then return self:parse_object(depth) end
    if char == "[" then return self:parse_array(depth) end
    if char == "-" or char:match("%d") then return self:parse_number() end

    if self.text:sub(self.pos, self.pos + 3) == "true" then
        self.pos = self.pos + 4
        return true
    end
    if self.text:sub(self.pos, self.pos + 4) == "false" then
        self.pos = self.pos + 5
        return false
    end
    if self.text:sub(self.pos, self.pos + 3) == "null" then
        self.pos = self.pos + 4
        return NULL
    end

    self:error("unexpected character '" .. char .. "'")
end

function Parser:parse_object(depth)
    self:expect("{")
    local out = {}
    self:skip_space()

    if self:peek() == "}" then
        self.pos = self.pos + 1
        return out
    end

    while true do
        self:skip_space()
        local key = self:parse_string()
        self:skip_space()
        self:expect(":")
        out[key] = self:parse_value(depth + 1)
        self:skip_space()

        local char = self:peek()
        if char == "," then
            self.pos = self.pos + 1
        elseif char == "}" then
            self.pos = self.pos + 1
            return out
        else
            self:error("expected ',' or '}'")
        end
    end
end

function Parser:parse_array(depth)
    self:expect("[")
    local out = {}
    local n = 0
    self:skip_space()

    if self:peek() == "]" then
        self.pos = self.pos + 1
        return out
    end

    while true do
        n = n + 1
        out[n] = self:parse_value(depth + 1)
        self:skip_space()

        local char = self:peek()
        if char == "," then
            self.pos = self.pos + 1
        elseif char == "]" then
            self.pos = self.pos + 1
            return out
        else
            self:error("expected ',' or ']'")
        end
    end
end

--- Parses a JSON document.
---
--- Returns nil plus a message on bad input rather than raising, because the
--- usual caller is holding an HTTP response from a server it does not control
--- and a malformed body is an ordinary outcome, not a bug.
---@param text string
---@return any|nil value
---@return string|nil error
function M.decode(text)
    if type(text) ~= "string" then return nil, "json: expected a string" end
    if text == "" then return nil, "json: empty input" end

    local parser = setmetatable({ text = text, pos = 1 }, Parser)
    local ok, result = pcall(parser.parse_value, parser, 0)
    if not ok then return nil, tostring(result) end

    parser:skip_space()
    if parser.pos <= #text then
        return nil, "json: trailing content after the document"
    end
    return result
end

--- Replaces every json.null in a decoded tree with nil, in place.
---
--- Use it when a document is going straight into settings and the difference
--- between "explicitly null" and "absent" does not matter. Do NOT use it on
--- anything where that difference is load-bearing.
---@param value any
---@return any
function M.strip_nulls(value)
    if type(value) ~= "table" or value == NULL then
        if value == NULL then return nil end
        return value
    end
    for k, v in pairs(value) do
        if v == NULL then
            value[k] = nil
        elseif type(v) == "table" then
            M.strip_nulls(v)
        end
    end
    return value
end

return M

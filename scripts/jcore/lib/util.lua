-- JCore / util -- leaf module, depends on nothing.

local unpack_fn = table.unpack or unpack

local M = {}

M.unpack = unpack_fn

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function M.round(v)
    return math.floor(v + 0.5)
end

function M.lerp(a, b, t)
    return a + (b - a) * t
end

--- Linear map of `v` from [in_lo, in_hi] onto [out_lo, out_hi], clamped.
function M.remap(v, in_lo, in_hi, out_lo, out_hi)
    if in_hi == in_lo then return out_lo end
    return M.clamp(out_lo + (v - in_lo) / (in_hi - in_lo) * (out_hi - out_lo),
        math.min(out_lo, out_hi), math.max(out_lo, out_hi))
end

function M.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function M.shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

--- Copies `src` over `dst` in place, recursing into plain tables. Used for
--- option tables where a caller supplies a partial override of a default.
function M.deep_merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            M.deep_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

--- Removes the first element equal to `value`. Returns true when one went.
function M.array_remove(t, value)
    for i = 1, #t do
        if t[i] == value then
            table.remove(t, i)
            return true
        end
    end
    return false
end

--- Stable insertion sort by `key_fn` ascending.
---
--- table.sort is NOT stable and, worse, raises "invalid order function" on
--- LuaJIT when the comparator is inconsistent. Both matter here: subscriber and
--- draw lists are sorted by a numeric priority with many ties, and ties must
--- keep registration order so that two plugins at the same priority always run
--- in the order they registered rather than in an order that shifts per frame.
function M.stable_sort_by(t, key_fn)
    for i = 2, #t do
        local item = t[i]
        local key = key_fn(item)
        local j = i - 1
        while j >= 1 and key_fn(t[j]) > key do
            t[j + 1] = t[j]
            j = j - 1
        end
        t[j + 1] = item
    end
    return t
end

--- Wraps `fn` so it can never raise into the caller. Returns ok, result...
function M.safe_call(fn, ...)
    return pcall(fn, ...)
end

--- Identifier sanitiser for menu ids and log namespaces: lowercase, and only
--- [a-z0-9_.] survives. Menu widget ids are the persistence key, so they have
--- to be derived deterministically from a plugin id and never contain the
--- separator characters the menu path uses.
function M.slug(s)
    s = tostring(s or ""):lower()
    s = s:gsub("[^%w_%.]", "_")
    s = s:gsub("_+", "_")
    s = s:gsub("^_+", ""):gsub("_+$", "")
    if s == "" then s = "unnamed" end
    return s
end

--- "1.2.3" -> 10203, so versions compare as plain numbers.
function M.parse_version(v)
    local major, minor, patch = tostring(v):match("^(%d+)%.(%d+)%.?(%d*)")
    if not major then return nil end
    return tonumber(major) * 10000 + tonumber(minor) * 100 + (tonumber(patch) or 0)
end

--- Fixed-capacity ring buffer, used for timing samples. Never reallocates.
---@param capacity integer
function M.ring(capacity)
    return {
        cap = capacity,
        n = 0,
        head = 0,
        data = {},
        push = function(self, v)
            self.head = (self.head % self.cap) + 1
            self.data[self.head] = v
            if self.n < self.cap then self.n = self.n + 1 end
        end,
        avg = function(self)
            if self.n == 0 then return 0 end
            local sum = 0
            for i = 1, self.n do sum = sum + self.data[i] end
            return sum / self.n
        end,
        max = function(self)
            local m = 0
            for i = 1, self.n do
                if self.data[i] > m then m = self.data[i] end
            end
            return m
        end,
    }
end

return M

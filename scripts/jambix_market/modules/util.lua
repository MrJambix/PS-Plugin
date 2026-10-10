-- Jambix Market / util -- money text, a calendar clock, guarded calls.
--
-- The loader's Lua has no os.time(), and core.time() counts from injection,
-- so it cannot date anything that has to survive a reload: price history,
-- sales rates, the ledger. The clock here is epoch seconds (local time),
-- built once from core.get_local_time() and advanced with core.time().

local U = {}

local floor, abs = math.floor, math.abs

-- --- clock -----------------------------------------------------------------

--- Days from 1970-01-01 to a calendar date (Howard Hinnant's algorithm).
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + floor(yoe / 4) - floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
U.days_from_civil = days_from_civil

--- Epoch seconds for a { year, month, day, hour, minute, second } table.
function U.epoch_of(t)
    if type(t) ~= "table" or not tonumber(t.year) then return nil end
    return days_from_civil(t.year, t.month or 1, t.day or 1) * 86400
        + (t.hour or 0) * 3600 + (t.minute or 0) * 60 + (t.second or 0)
end

local offset = nil            -- epoch - core.time()
local synced_at = -math.huge  -- core.time() of the last sync

--- Seconds since 1970 in local time. Re-read from the calendar every ten
--- minutes, so a clock change is picked up without a native call per use.
function U.now()
    local t = core.time()
    if not offset or t - synced_at > 600 then
        local ok, lt = pcall(core.get_local_time)
        local e = ok and U.epoch_of(lt) or nil
        if e then
            offset = e - t
        elseif not offset then
            offset = 0
        end
        synced_at = t
    end
    return offset + t
end

--- The calendar day an epoch second falls on (days since 1970).
function U.day(epoch)
    return floor((epoch or U.now()) / 86400)
end

-- --- money -----------------------------------------------------------------

local function thousands(n)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

--- "12g 34s 56c". Zero parts are left out; past 100 gold the copper is too.
---@param copper number|nil
---@return string
function U.money(copper)
    if copper == nil then return "-" end
    local neg = copper < 0
    local c = floor(abs(copper) + 0.5)
    local g = floor(c / 10000)
    local s = floor(c / 100) % 100
    c = c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = thousands(g) .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 and g < 100 then parts[#parts + 1] = c .. "c" end
    if #parts == 0 then parts[1] = "0c" end
    return (neg and "-" or "") .. table.concat(parts, " ")
end

--- A signed money string: "+1g 20s" / "-35s".
function U.signed(copper)
    if copper == nil then return "-" end
    if copper > 0 then return "+" .. U.money(copper) end
    return U.money(copper)
end

--- How long ago, in the shortest words: "40s", "12m", "3h", "2d".
function U.ago(seconds)
    if not seconds then return "never" end
    seconds = floor(seconds)
    if seconds < 60 then return seconds .. "s" end
    if seconds < 3600 then return floor(seconds / 60) .. "m" end
    if seconds < 172800 then return floor(seconds / 3600) .. "h" end
    return floor(seconds / 86400) .. "d"
end

--- "+12%" / "-3%"; "-" for an unknown.
function U.pct(fraction)
    if not fraction then return "-" end
    local p = floor(fraction * 100 + (fraction >= 0 and 0.5 or -0.5))
    return (p > 0 and "+" or "") .. p .. "%"
end

--- A per-day rate: "12/d", "0.5/d", "-" for unknown.
function U.rate(per_day)
    if not per_day then return "-" end
    if per_day >= 10 then return floor(per_day + 0.5) .. "/d" end
    return string.format("%.1f/d", per_day)
end

--- The table key for an id: "2589" whether the id arrived as an integer or
--- as a float (tostring(2589.0) is "2589.0" on Lua 5.3, and an auction id
--- past 2^31 is a float on some builds).
function U.key(id)
    return string.format("%.0f", tonumber(id) or 0)
end

-- --- rolls ---------------------------------------------------------------------
--
-- One item id covers every random suffix: a Bandit Cloak "of the Monkey" and
-- one "of the Owl" are the same id at very different prices. Forever writes
-- the roll into the item link as a bonus id (the user's own auctions,
-- 2026-10-09: "item:9779::::::::18:1485::1:1:12741:1:2...", Bandit Cloak,
-- bonus 12741), after the retail layout:
--   item:id:enchant:gem1:gem2:gem3:gem4:suffix:unique:linkLevel:spec:
--        modifiersMask:context:numBonusIDs:bonus1:bonus2:...
-- The link level and spec are the VIEWER's (18 = the user's level), so they
-- are not part of the roll; neither are enchants, gems or modifiers.

--- The roll an item link carries: "" for none (the item as it always is),
--- the bonus ids sorted and joined by "." ("12741", "6654.12741"), and a
--- classic suffix field as "s<id>" after them. Also the name the link shows
--- (with its "of the ..."), and the item id. Nil for anything not an item link.
---@param link string|nil
---@return string|nil var
---@return string|nil name
---@return integer|nil item_id
function U.link_variant(link)
    if type(link) ~= "string" or link == "" then return nil end
    local body = link:match("item:([%-%d:]*)")
    if not body then return nil end
    local f = {}
    for v in (body .. ":"):gmatch("([^:]*):") do f[#f + 1] = v end
    local id = tonumber(f[1])
    if not id or id <= 0 then return nil end
    local bonus = {}
    local n = tonumber(f[13]) or 0
    for i = 1, n do
        local b = tonumber(f[13 + i])
        if b and b ~= 0 then bonus[#bonus + 1] = b end
    end
    table.sort(bonus)
    local parts = {}
    for i = 1, #bonus do parts[i] = string.format("%.0f", bonus[i]) end
    local suffix = tonumber(f[7])
    if suffix and suffix ~= 0 then parts[#parts + 1] = "s" .. string.format("%.0f", suffix) end
    local name = link:match("|h%[(.-)%]|h")
    if name == "" then name = nil end
    return table.concat(parts, "."), name, id
end

--- The key of one roll of an item: "9779:12741", or just "9779" for an item
--- with no roll (the same key the item itself has everywhere else).
function U.vkey(id, var)
    if var == nil or var == "" then return U.key(id) end
    return U.key(id) .. ":" .. var
end

--- The key of a HOLDING: gear Auto holds is always "id:roll" -- "13127:" for
--- gear with no roll -- so it can never share a key (and a mode) with a
--- vendor flip or resale of the same item ("13127"). `var` nil: not gear.
function U.hkey(id, var)
    if var == nil then return U.key(id) end
    return U.key(id) .. ":" .. var
end

--- The item id and roll of a key made by U.vkey or U.hkey ("" for no roll).
function U.unvkey(vkey)
    if type(vkey) == "number" then return vkey, "" end
    local id, var = tostring(vkey):match("^(%-?%d+):?(.*)$")
    return tonumber(id), var or ""
end

-- --- guarded calls -----------------------------------------------------------

--- Calls fn(...) and returns its first result, or nil if it raised.
function U.try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
    return nil
end

--- A field read off a game object's method, guarded.
function U.method(obj, name, ...)
    if obj == nil then return nil end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or type(fn) ~= "function" then return nil end
    local ok2, a = pcall(fn, obj, ...)
    if ok2 then return a end
    return nil
end

function U.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Item quality -> the game's colour, 0-255 as the JCore toolkit takes it.
U.QUALITY_COLOR = {
    [0] = { 157, 157, 157, 255 }, [1] = { 235, 235, 240, 255 }, [2] = { 30, 255, 0, 255 },
    [3] = { 0, 112, 221, 255 }, [4] = { 163, 53, 238, 255 }, [5] = { 255, 128, 0, 255 },
}

return U

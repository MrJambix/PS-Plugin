-- JCore / creatures -- what the Forever client itself knows about each
-- creature, read from its own creature cache (JCore 1.5.15).
--
-- WHY
-- On Forever get_name answers "" for every unit and get_classification 0
-- (3,293 of 3,293 recorded reads), so neither a name nor elite / rare / boss
-- could be read from a unit there. The client knows both: every creature the
-- server has described to it is kept in Cache/WDB/<locale>/creaturecache.wdb,
-- the server's creature-query answer as the client stores it. The loader's
-- file sandbox is the client folder (answered on Era, 2026-10-02), so the
-- file is readable in the game.
--
-- WHEN IT IS WRITTEN
-- The client writes the file when it exits: on 2026-10-03 its time matched the
-- end of the session before, not the one running. A new client build wipes it
-- (after patch 1.60.1.70205 it held 16 creatures). So it holds what EARLIER
-- sessions saw. It is read once, the first time anyone asks, and again only
-- on a reload.
--
-- THE LAYOUT (build 70205; every one of its 16 records checked offline)
-- A 24-byte header: "BOMW", the build, the locale reversed ("SUne"), three
-- more u32s. Then records until the file ends: id u32, size u32, and size
-- bytes of:
--   bits, most significant first: title length 11, alternate title 11,
--     cursor 6, leader 1, then four times (name 11, alternate name 11). Each
--     length counts the string's zero byte; 0 means absent.
--   the names, byte-aligned, each with its zero byte.
--   flags u32 x3, creature type u8, family u32, classification u8, two proxy
--     creature ids u32, display count u32, total probability f32, per display
--     (id u32, scale f32, probability f32), health and energy multipliers
--     f32, quest item count u32, quest currency count u32, eight u32s
--     (movement, scaling and required expansion, vignette, class,
--     difficulty, widget set and its condition).
--   the title, alternate title and cursor strings, then the quest item ids
--     and the quest currency ids, u32 each.
-- Every record is held to that exact length. One that does not add up keeps
-- its name (the start of the record, which is the part least likely to move)
-- and drops the rest, so a changed layout costs the rank, never a wrong one.
-- The classification ids are WoW's own -- 0 normal, 1 elite, 2 rare elite,
-- 3 boss, 4 rare, 5 trivial, 6 minus -- the numbers get_classification
-- answers on the clients where it works.
--
-- EVERY OTHER CLIENT: an inert service. Nothing is read, info() answers nil.
--
-- THE BEAST LOOKUP (JCore 1.8.6), on Era as well, and only when asked:
-- beast(npc_id) answers whether the client says the creature can be tamed
-- (type flags bit 0, CREATURE_TYPE_FLAG_TAMEABLE) and its family, for a hunter's
-- tame marks. On Era the file is read the first time that is asked, never
-- before. info(), name() and classification() still answer nil there, so no
-- Era name or rank changes.
--
-- ERA'S LAYOUT (build 70003, every one of its 977 records checked offline)
-- differs from Forever's in two places. One more header bit after the cursor
-- length (set on trainers and the like), and one more u32 after the two proxy
-- creature ids, before the display count. The layout is chosen per file: the
-- one under which more of its first records hold to their exact length.

local HEADER = 24
local BEFORE_DISPLAYS = 34   -- flags 12, type 1, family 4, rank 1, proxies 8, count 4, probability 4
-- flag_bits: header bits after the cursor length before the leader bit;
-- pre: bytes between the proxies and the display count.
local LAYOUTS = {
    { name = "Forever 70205", flag_bits = 0, pre = 0 },
    { name = "Era 70003", flag_bits = 1, pre = 4 },
}
local SAMPLE = 24            -- records tried with each layout before choosing
local PER_DISPLAY = 12
local AFTER_DISPLAYS = 48    -- two multipliers, two counts, eight u32s
local MAX_LIST = 64          -- more displays / quest items than this is not a record
local MAX_CLASSIFICATION = 6
local MAX_TYPE = 15

local byte = string.byte
local floor = math.floor

-- Floats throughout: a u32 above 2^31 must not wrap on a 32-bit integer Lua.
local function u32(s, i)
    local a, b, c, d = byte(s, i, i + 3)
    if not d then return nil end
    return floor(a + b * 256.0 + c * 65536.0 + d * 16777216.0)
end

--- Reads `n` bits, most significant first, from the record starting at
--- byte `start`; `bit` counts from 0. Returns the value and the next bit.
local function bits(s, start, bit, n)
    local v = 0
    for _ = 1, n do
        local b = byte(s, start + floor(bit / 8)) or 0
        local shift = 7 - bit % 8
        v = v * 2 + floor(b / 2 ^ shift) % 2
        bit = bit + 1
    end
    return v, bit
end

--- One record, from byte `i` to byte `stop` inclusive. nil when not even a
--- name can be read.
local function parse_record(s, i, stop, id, layout)
    layout = layout or LAYOUTS[1]
    local bit = 0
    local title, title_alt, cursor, leader
    title, bit = bits(s, i, bit, 11)
    title_alt, bit = bits(s, i, bit, 11)
    cursor, bit = bits(s, i, bit, 6)
    bit = bit + layout.flag_bits
    leader, bit = bits(s, i, bit, 1)
    local lens = {}
    for k = 1, 8 do lens[k], bit = bits(s, i, bit, 11) end

    local p = i + floor((bit + 7) / 8)
    local strings = {}
    for k = 1, 8 do
        local len = lens[k]
        if len > 0 then
            if p + len - 1 > stop then return nil end
            strings[k] = s:sub(p, p + len - 2)
            p = p + len
        else
            strings[k] = ""
        end
    end
    if strings[1] == "" then return nil end

    local row = { id = id, name = strings[1], leader = leader == 1, checked = false }
    local a = p
    if a + BEFORE_DISPLAYS - 1 > stop then return row end
    local pre = layout.pre
    if a + BEFORE_DISPLAYS + pre - 1 > stop then return row end
    local displays = u32(s, a + 26 + pre)
    if not displays or displays > MAX_LIST then return row end
    local d = a + BEFORE_DISPLAYS + pre + displays * PER_DISPLAY
    if d + AFTER_DISPLAYS - 1 > stop then return row end
    local items, currencies = u32(s, d + 8), u32(s, d + 12)
    if not items or not currencies or items > MAX_LIST or currencies > MAX_LIST then return row end
    local tail = d + AFTER_DISPLAYS
    local expected = (tail - a) + title + title_alt + cursor + 4 * items + 4 * currencies
    if stop - a + 1 ~= expected then return row end
    local ctype, rank = byte(s, a + 12), byte(s, a + 17)
    if ctype > MAX_TYPE or rank > MAX_CLASSIFICATION then return row end

    row.checked = true
    row.flags = u32(s, a)
    -- CREATURE_TYPE_FLAG_TAMEABLE (1.8.6): a hunter can tame it.
    row.tameable = floor(row.flags % 2) == 1
    row.type = ctype
    row.family = u32(s, a + 13)
    row.classification = rank
    if title > 0 then row.title = s:sub(tail, tail + title - 2) end
    local q = tail + title + title_alt + cursor
    if items > 0 then
        row.quest_items = {}
        for k = 1, items do row.quest_items[k] = u32(s, q + 4 * (k - 1)) end
    end
    return row
end

--- Every record of a creature cache. Returns rows by id, the header's
--- build and locale, and how many records did not hold to the layout;
--- or nil and why.
local function parse(s)
    if type(s) ~= "string" or #s < HEADER then return nil, "too short" end
    if s:sub(1, 4) ~= "BOMW" then return nil, "not a creature cache" end
    local build = u32(s, 5)
    local locale = s:sub(9, 12):reverse()
    local n = #s
    -- Which layout this file is in: the one more of its first records hold to.
    local layout, best = LAYOUTS[1], -1
    for k = 1, #LAYOUTS do
        local L, held, seen, at = LAYOUTS[k], 0, 0, HEADER + 1
        while at + 7 <= n and seen < SAMPLE do
            local id, size = u32(s, at), u32(s, at + 4)
            if not id or not size or (id == 0 and size == 0) then break end
            local stop = at + 7 + size
            if stop > n then break end
            if size > 0 then
                seen = seen + 1
                local ok, row = pcall(parse_record, s, at + 8, stop, id, L)
                if ok and row and row.checked then held = held + 1 end
            end
            at = stop + 1
        end
        if held > best then layout, best = L, held end
    end
    local rows, unchecked, count = {}, 0, 0
    local pos = HEADER + 1
    while pos + 7 <= n do
        local id, size = u32(s, pos), u32(s, pos + 4)
        if not id or not size or (id == 0 and size == 0) then break end
        local first, stop = pos + 8, pos + 7 + size
        if stop > n then break end
        if size > 0 then
            local ok, row = pcall(parse_record, s, first, stop, id, layout)
            if ok and row then
                rows[id] = row
                count = count + 1
                if not row.checked then unchecked = unchecked + 1 end
            end
        end
        pos = stop + 1
    end
    return rows, build, locale, count, unchecked, layout.name
end

return function(rt)
    local log = rt.log.for_tag("JCore/creatures")
    local events = rt.events

    local M = {}
    M._parse = parse

    local rows = {}
    local state = {
        read = false,      -- tried yet
        forever = nil,     -- the client, decided on first use
        path = nil, count = 0, unchecked = 0, build = nil, locale = nil,
        error = nil, tried = {},
    }

    local function on_forever()
        if state.forever ~= nil then return state.forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return false end
        state.forever = c.forever == true
        return state.forever
    end

    local function read(path)
        local ok, data = pcall(core.read_file, path)
        if ok and type(data) == "string" and #data >= HEADER then return data end
        return nil
    end

    --- The client folder's prefix, as the asset registry found it ("" when
    --- the sandbox is the client folder itself), and the folder's locale
    --- from its Config.wtf.
    local function candidates()
        local prefixes, seen = {}, {}
        local function add_prefix(p)
            if type(p) == "string" and not seen[p] then
                seen[p] = true
                prefixes[#prefixes + 1] = p
            end
        end
        local assets = rt.assets
        if assets and type(assets.flavor) == "function" then
            local ok, folder = pcall(assets.flavor)
            if ok and type(folder) == "string" and folder ~= "" then add_prefix(folder .. "/") end
        end
        add_prefix("")
        local locales, lseen = {}, {}
        local function add_locale(l)
            if type(l) == "string" and l:match("^%a%a%a%a$") and not lseen[l] then
                lseen[l] = true
                locales[#locales + 1] = l
            end
        end
        for i = 1, #prefixes do
            local config = read(prefixes[i] .. "WTF/Config.wtf")
            if config then add_locale(config:match('SET%s+textLocale%s+"(%a%a%a%a)"')) end
        end
        add_locale("enUS")
        local out = {}
        for i = 1, #prefixes do
            for j = 1, #locales do
                out[#out + 1] = prefixes[i] .. "Cache/WDB/" .. locales[j] .. "/creaturecache.wdb"
            end
        end
        return out
    end

    --- Reads the cache now. Called on first use; `force` reads it again.
    --- `any_client`: read it on any client (beast(), 1.8.6) -- without it, only
    --- on Forever, as before.
    function M.load(force, any_client)
        if state.read and not force and not (any_client and state.error == "not Forever") then
            return state.count
        end
        state.read = true
        rows, state.count, state.unchecked, state.path, state.error = {}, 0, 0, nil, nil
        state.tried = {}
        if not on_forever() and not any_client then
            state.error = "not Forever"
            return 0
        end
        local paths = candidates()
        for i = 1, #paths do
            state.tried[#state.tried + 1] = paths[i]
            local data = read(paths[i])
            if data then
                local parsed, build, locale, count, unchecked, layout = parse(data)
                if parsed then
                    rows, state.path, state.build, state.locale = parsed, paths[i], build, locale
                    state.layout = layout
                    state.count, state.unchecked = count, unchecked
                    local ranked = 0
                    for _, r in pairs(rows) do
                        if (r.classification or 0) > 0 then ranked = ranked + 1 end
                    end
                    state.ranked = ranked
                    local line = string.format(
                        "creatures: %d from %s (build %s, %s): %d with a rank, %d not in the known layout",
                        count, paths[i], tostring(build), tostring(locale), ranked, unchecked)
                    log.fmt("info", "%s", line)
                    if events then pcall(events.emit, "jcore.recorder.trace", line) end
                    return count
                end
                state.error = tostring(build)  -- parse's reason
            end
        end
        state.error = state.error or "no creature cache found"
        log.fmt("info", "creatures: none read (%s)", state.error)
        if events then
            pcall(events.emit, "jcore.recorder.trace", "creatures: none read (" .. state.error .. ")")
        end
        return 0
    end

    --- What the client's cache says about a creature id, or nil: { id, name,
    --- title, type, family, classification, quest_items, leader, checked }.
    --- type, family and classification are nil on a record that did not
    --- hold to the layout. Read-only.
    ---@param npc_id integer|nil
    ---@return table|nil
    function M.info(npc_id)
        -- Era: nil, as before 1.8.6 (beast() is the one answer it gives).
        if not on_forever() then return nil end
        if not state.read then M.load() end
        npc_id = tonumber(npc_id)
        if not npc_id or npc_id <= 0 then return nil end
        return rows[npc_id]
    end

    ---@param npc_id integer|nil
    ---@return string|nil
    function M.name(npc_id)
        local r = M.info(npc_id)
        return r and r.name or nil
    end

    --- WoW's classification id, or nil when the cache does not say.
    ---@param npc_id integer|nil
    ---@return integer|nil
    function M.classification(npc_id)
        local r = M.info(npc_id)
        return r and r.classification or nil
    end

    --- The classification of a unit: the client's own answer when it gives
    --- one, else (Forever) the cache's by npc id. 0 when neither knows.
    ---@param unit game_object
    ---@return integer
    function M.classification_of(unit)
        if not unit then return 0 end
        local ok, native = pcall(unit.get_classification, unit)
        native = ok and tonumber(native) or 0
        if native ~= 0 or not on_forever() then return native end
        local okn, npc = pcall(unit.get_npc_id, unit)
        return (okn and M.classification(npc)) or 0
    end

    --- Whether the client says a creature can be tamed, and its family: {
    --- tameable, family, type, name, classification }, or nil when its cache
    --- does not know the creature in its exact layout. On any client; on Era
    --- the file is read the first time this is asked. The cache holds what
    --- EARLIER sessions saw (it is written when the client exits).
    ---@param npc_id integer|nil
    ---@return table|nil
    function M.beast(npc_id)
        if not state.read or state.error == "not Forever" then M.load(false, true) end
        npc_id = tonumber(npc_id)
        if not npc_id or npc_id <= 0 then return nil end
        local r = rows[npc_id]
        if not r or not r.checked then return nil end
        return { tameable = r.tameable == true, family = r.family, type = r.type, name = r.name,
                 classification = r.classification }
    end

    function M.stats()
        return {
            layout = state.layout,
            read = state.read, path = state.path, count = state.count, ranked = state.ranked or 0,
            unchecked = state.unchecked, build = state.build, locale = state.locale,
            error = state.error, tried = state.tried,
        }
    end

    return M
end

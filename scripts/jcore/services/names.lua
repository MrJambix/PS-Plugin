-- JCore / names -- what a unit is called, on every client (JCore 1.6.0).
--
-- On Era a unit's name is get_name's answer, and that is all this does there.
--
-- FOREVER. get_name answers "" for every unit there (and "Unknown" for many
-- quest givers and town npcs), so the name is gathered instead, in order:
--   1. get_name, when it does give a real name;
--   2. a name heard for THIS unit this session (players are named only so:
--      a player's name is not a fact about every player of their class);
--   3. a name LEARNED for its kind, by npc id, kept across sessions in the
--      jcore.names store: UNIT_SPELLCAST_SENT carries the name of what you
--      cast at, which is your target, and a plugin with another source (the
--      game's own Lua, a tooltip) hands its names in through learn();
--   4. the client's own creature cache (services/creatures.lua), which knows
--      every creature an earlier session met.
-- Placeholders ("Unknown") are never learned and never answered.
--
-- This took over from Jambix AIO's own copy (esp/forever.lua and
-- react/init.lua, AIO 1.45.0 to 1.54.2): its saved names (the
-- jambix.aio.forever_names store) are taken in once, the first time this
-- store is empty.

local PLACEHOLDER = { ["Unknown"] = true, ["Unknown Being"] = true, ["UNKNOWNOBJECT"] = true }
local CLIENT_TTL = 2.0   -- seconds a unit's own get_name answer is kept

local function real(name)
    return type(name) == "string" and name ~= "" and not PLACEHOLDER[name]
end

return function(rt)
    local log = rt.log.for_tag("JCore/names")
    local events = rt.events
    local units = rt.units

    local M = {}
    M.is_placeholder = function(name) return PLACEHOLDER[name] == true end

    local forever = nil
    local function on_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return false end
        forever = c.forever == true
        return forever
    end

    local store, npc_names = nil, nil
    local guid_names = {}           -- guid -> name, this session
    local client_seen = {}          -- guid -> { name, at }
    local stats = { learned = 0, imported = 0 }

    --- The kept names, opened on first use (Forever only).
    local function kept()
        if npc_names then return npc_names end
        npc_names = {}
        local storage = rt.storage
        if not (storage and storage.store) then return npc_names end
        local ok, s = pcall(storage.store, "jcore.names")
        if not ok or type(s) ~= "table" then return npc_names end
        store = s
        if type(s.data.npcs) ~= "table" then s.data.npcs = {} end
        npc_names = s.data.npcs
        if next(npc_names) == nil then
            -- Jambix AIO kept these itself until JCore 1.6.0.
            local ok_a, old = pcall(storage.store, "jambix.aio.forever_names")
            local from = ok_a and type(old) == "table" and type(old.data) == "table" and old.data.npcs
            if type(from) == "table" then
                for id, name in pairs(from) do
                    if real(name) then
                        npc_names[tostring(id)] = name
                        stats.imported = stats.imported + 1
                    end
                end
                if stats.imported > 0 then
                    s:touch()
                    log.fmt("info", "took in %d names kept by Jambix AIO", stats.imported)
                end
            end
        end
        for id, name in pairs(npc_names) do
            if not real(name) then npc_names[id] = nil end
        end
        return npc_names
    end

    local function npc_of(unit)
        if not unit then return 0 end
        local ok, id = pcall(unit.get_npc_id, unit)
        return ok and tonumber(id) or 0
    end

    --- Teach a name: for this unit (by guid), and for its kind (by npc id)
    --- unless it is a player. Forever only; a no-op elsewhere.
    ---@param unit_or_guid game_object|string
    ---@param npc_id? integer
    ---@param name string
    function M.learn(unit_or_guid, npc_id, name)
        if not on_forever() or not real(name) then return end
        local guid = type(unit_or_guid) == "string" and unit_or_guid or units.guid(unit_or_guid)
        if guid then guid_names[guid] = name end
        if npc_id == nil and type(unit_or_guid) ~= "string" then npc_id = npc_of(unit_or_guid) end
        npc_id = tonumber(npc_id) or 0
        if npc_id > 0 then
            local names = kept()
            local key = tostring(npc_id)
            if names[key] ~= name then
                names[key] = name
                stats.learned = stats.learned + 1
                if store then store:touch() end
            end
        end
    end

    --- A unit's name and where it came from ("client", "known", "learned",
    --- "cache"), or nil when nothing names it. On Era: get_name, "client".
    ---@param unit game_object
    ---@return string|nil name
    ---@return string|nil source
    function M.of(unit)
        if not unit then return nil end
        if not on_forever() then
            local ok, name = pcall(unit.get_name, unit)
            if ok and type(name) == "string" and name ~= "" then return name, "client" end
            return nil
        end
        local guid = units.guid(unit)
        local now = core.time()
        local seen = guid and client_seen[guid]
        if not seen or now >= seen.at then
            local ok, name = pcall(unit.get_name, unit)
            seen = { name = (ok and real(name)) and name or false, at = now + CLIENT_TTL }
            if guid then client_seen[guid] = seen end
            if seen.name then M.learn(guid, npc_of(unit), seen.name) end
        end
        if seen.name then return seen.name, "client" end
        local n = guid and guid_names[guid]
        if n then return n, "known" end
        local npc = npc_of(unit)
        if npc > 0 then
            n = kept()[tostring(npc)]
            if real(n) then return n, "learned" end
            local creatures = rt.creatures
            if creatures and creatures.name then
                local ok_c, c = pcall(creatures.name, npc)
                if ok_c and real(c) then return c, "cache" end
            end
        end
        return nil
    end

    --- The name kept for a creature id (Forever), or the cache's, or nil.
    ---@param npc_id integer
    ---@return string|nil
    function M.for_npc(npc_id)
        npc_id = tonumber(npc_id) or 0
        if npc_id <= 0 or not on_forever() then return nil end
        local n = kept()[tostring(npc_id)]
        if real(n) then return n end
        local creatures = rt.creatures
        if creatures and creatures.name then
            local ok, c = pcall(creatures.name, npc_id)
            if ok and real(c) then return c end
        end
        return nil
    end

    function M.stats()
        local n = 0
        for _ in pairs(npc_names or {}) do n = n + 1 end
        return { kept = n, learned = stats.learned, imported = stats.imported, forever = on_forever() }
    end

    -- --- what teaches it (Forever) ------------------------------------------

    -- UNIT_SPELLCAST_SENT: (unit, target name, cast guid, spell id), and what
    -- you cast at is your target. Recorded on Forever:
    -- "player", "Roiling Winds", ..., 1752.
    events.on("jcore.game_event.UNIT_SPELLCAST_SENT", function(args)
        if not on_forever() then return end
        if type(args) ~= "table" or args[1] ~= "player" or not real(args[2]) then return end
        local combat = rt.combat
        local ok, target = pcall(function() return combat and combat.target and combat.target() end)
        if not ok or not target then return end
        M.learn(target, nil, args[2])
    end, { owner = "jcore", priority = 0 })

    events.on("jcore.unit.removed", function(guid)
        if guid then client_seen[guid] = nil end
    end, { owner = "jcore", priority = 0 })

    return M
end

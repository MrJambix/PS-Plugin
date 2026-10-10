-- Jambix AIO / sense -- situational awareness, separate from acting on it.
--
-- Everything else in the plugin decides what to PRESS. This module decides
-- what is TRUE, publishes it, and lets the rotation, the hardcore layer and
-- the narrator each do what they want with it. Keeping the two apart is what
-- lets the player be told *why* something happened: the reason already exists
-- as a value rather than being implicit in a branch somewhere.
--
-- STEALTH, AND WHY IT IS NOT A NAME MATCH
-- Auras carry a TYPE, and the enum has a STEALTH member. Matching "Stealth",
-- "Prowl", "Shadowmeld", "Vanish" and every PvE equivalent by name would be a
-- list that is wrong on the first server with a custom mob; the type is the
-- game's own answer and covers all of them.
--
-- THE HARDER PROBLEM: something you CANNOT see
-- A stealthed rogue is not in the object manager, so no aura check will find
-- it. What is observable is the moment it LEAVES: a hostile player who was
-- two yards away and is suddenly gone did not walk away in one tick. That
-- transition is the signal worth having, and on a hardcore character it is
-- the difference between being opened on and being ready for it.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat

    local M = {}

    local STEALTH_TYPE = nil
    do
        local enums = P.enums
        if enums and enums.buff_type and type(enums.buff_type.STEALTH) == "number" then
            STEALTH_TYPE = enums.buff_type.STEALTH
        end
    end

    -- guid -> { name, at, distance } for hostile players seen recently.
    local seen_players = {}
    -- Active suspicion that something stealthed is nearby.
    local suspicion = { until_time = 0, name = nil, distance = 0 }

    local SEEN_MEMORY = 6.0        -- how long a sighting stays relevant
    local VANISH_RANGE = 40        -- only care about ones that were close

    -- --- stealth ------------------------------------------------------------

    --- Is this unit stealthed right now?
    ---
    --- Answers false rather than nil when the aura type is unavailable, so a
    --- caller never has to distinguish "not stealthed" from "cannot tell" --
    --- both mean "do not act on stealth".
    ---@param unit game_object
    ---@return boolean
    function M.is_stealthed(unit)
        if not unit or not unit:is_valid() then return false end
        if not STEALTH_TYPE then return false end

        local ok, auras = pcall(unit.get_auras, unit)
        if not ok or type(auras) ~= "table" then return false end

        for i = 1, #auras do
            local aura = auras[i]
            if aura and aura.type == STEALTH_TYPE then return true end
        end
        return false
    end

    --- Every stealthed unit we can currently see. A stealthed enemy that is
    --- VISIBLE is one we have detected, which is worth marking on the overlay.
    ---@return game_objects_table
    function M.visible_stealthed()
        local out = {}
        local list = units.units()
        local player = units.player()
        if not player then return out end

        for i = 1, #list do
            local unit = list[i]
            if unit:get_guid() ~= player:get_guid() and M.is_stealthed(unit) then
                out[#out + 1] = unit
            end
        end
        return out
    end

    ---@return boolean
    function M.player_stealthed()
        local player = units.player()
        return player ~= nil and M.is_stealthed(player)
    end

    -- --- the vanish heuristic -----------------------------------------------

    local function remember_players()
        local player = units.player()
        if not player then return end

        local now = core.time()
        local players = units.players()

        for i = 1, #players do
            local other = players[i]
            local guid = other:get_guid()
            if guid and guid ~= player:get_guid() and player:can_attack(other) then
                local distance = units.distance(other)
                if distance <= VANISH_RANGE then
                    local ok, name = pcall(other.get_name, other)
                    seen_players[guid] = {
                        name = (ok and name) or "someone",
                        at = now,
                        distance = distance,
                    }
                end
            end
        end

        for guid, row in pairs(seen_players) do
            if (now - row.at) > SEEN_MEMORY then seen_players[guid] = nil end
        end
    end

    --- A hostile player leaving the object manager is either a stealth or a
    --- zone change. Distance decides: something that was inside stealth-opener
    --- range did not simply run out of sight in one tick.
    ctx.on("jcore.unit.removed", function(guid)
        if not P.opt("sense_stealth_watch", true) then return end

        local row = seen_players[guid]
        if not row then return end
        seen_players[guid] = nil

        local now = core.time()
        if (now - row.at) > 1.5 then return end       -- stale sighting
        if row.distance > P.opt("sense_vanish_range", 25) then return end

        suspicion.until_time = now + P.opt("sense_vanish_memory", 12)
        suspicion.name = row.name
        suspicion.distance = row.distance

        log.fmt("warn", "%s vanished %.0f yards away", row.name, row.distance)
        ctx.emit("jambix.aio.sense", {
            kind = "stealth_vanish",
            severity = "danger",
            title = "Stealth nearby",
            why = string.format("%s vanished %.0f yards away",
                row.name, row.distance),
        })
    end)

    --- True while we have reason to think something stealthed is close.
    ---@return boolean
    ---@return string|nil who
    function M.stealth_suspected()
        if core.time() >= suspicion.until_time then return false, nil end
        return true, suspicion.name
    end

    -- --- other observations -------------------------------------------------

    local last_seen_stealthed = {}

    local function watch_visible_stealth()
        if not P.opt("sense_stealth_watch", true) then return end

        local now = core.time()
        local stealthed = M.visible_stealthed()

        for i = 1, #stealthed do
            local unit = stealthed[i]
            local guid = unit:get_guid()
            if guid and (not last_seen_stealthed[guid]
                or (now - last_seen_stealthed[guid]) > 20) then
                last_seen_stealthed[guid] = now
                local ok, name = pcall(unit.get_name, unit)
                local hostile = units.player() and units.player():can_attack(unit)
                ctx.emit("jambix.aio.sense", {
                    kind = "stealth_seen",
                    severity = hostile and "danger" or "info",
                    title = "Stealthed unit",
                    why = string.format("%s is stealthed %.0f yards away",
                        (ok and name) or "something", units.distance(unit)),
                })
            end
        end

        for guid, at in pairs(last_seen_stealthed) do
            if (now - at) > 60 then last_seen_stealthed[guid] = nil end
        end
    end

    --- Are we flagged for, or engaged in, player combat?
    ---
    --- Distinct from "a hostile player is nearby": on a PvP realm one is
    --- normal and the other is a fight. Used to switch the overlay and the
    --- alerts into a more paranoid mode.
    ---@return boolean
    function M.pvp_active()
        local player = units.player()
        if not player then return false end

        local players = units.players()
        local range = P.opt("alert_player_range", 60)

        for i = 1, #players do
            local other = players[i]
            if other:get_guid() ~= player:get_guid()
                and player:can_attack(other)
                and units.distance(other) <= range then
                return true
            end
        end
        return false
    end

    ctx.tick(function()
        if not P.master_on() then return end
        remember_players()
        watch_visible_stealth()
    end, { interval = 0.3, priority = 55 })

    function M.stats()
        local suspected, who = M.stealth_suspected()
        local tracked = 0
        for _ in pairs(seen_players) do tracked = tracked + 1 end
        return {
            stealth_type = STEALTH_TYPE ~= nil,
            visible_stealthed = #M.visible_stealthed(),
            suspected = suspected,
            suspect_name = who,
            tracked_players = tracked,
            pvp = M.pvp_active(),
        }
    end

    return M
end

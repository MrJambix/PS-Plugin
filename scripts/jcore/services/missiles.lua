-- JCore / missiles -- projectiles in flight, classified once per tick.
--
-- Depends on: util, log, cache, units, geometry.
--
-- A missile is the only advance warning the client gives that damage is about
-- to arrive. Anything that reacts rather than predicts -- a defensive, a
-- reflect, a step out of a stack -- wants to read them, and every one of those
-- plugins would otherwise call get_all_missiles and walk the list itself.
--
-- The sweep here does the walk once and answers the question consumers
-- actually have, which is never "what is in the air" but "what is in the air
-- aimed at me, and how long do I have". Time to impact is derived from the
-- missile's remaining travel and its speed, so a caller compares seconds
-- against a cast time rather than comparing yards against nothing.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local units = rt.units
    local geometry = rt.geometry
    local events = rt.events
    local log = rt.log.for_tag("JCore/missiles")

    local try = cache.try

    local M = {}

    local tick = cache.new("missiles.tick", { scope = "tick" })

    -- Missiles already announced, so a new arrival raises exactly one event
    -- rather than one per frame it stays in the air. Keyed on caster and
    -- spell, which is as close to an identity as a missile row gives us.
    local announced = {}
    local announced_age = {}
    local ANNOUNCE_TTL = 10.0

    --- Every missile currently in flight.
    ---@return missile[]
    function M.all()
        local value, hit = tick:get("all")
        if hit then return value or {} end
        return tick:put("all", try(core.object_manager.get_all_missiles) or {})
    end

    --- Seconds until a missile reaches its impact point.
    ---
    --- Returns math.huge for a missile with no usable speed rather than zero:
    --- a caller testing `time_to_impact(m) < 1` should not treat an unknown as
    --- an emergency.
    ---@param missile missile
    ---@return number
    function M.time_to_impact(missile)
        if not missile then return math.huge end
        local speed = missile.speed
        if not speed or speed <= 0 then return math.huge end

        local from = missile.current_position
        local to = missile.impact_position
        if not from or not to then return math.huge end

        return geometry.distance(from, to) / speed
    end

    --- Distance a missile still has to travel.
    ---@param missile missile
    ---@return number
    function M.distance_remaining(missile)
        if not missile or not missile.current_position or not missile.impact_position then
            return math.huge
        end
        return geometry.distance(missile.current_position, missile.impact_position)
    end

    --- Missiles whose target is `unit`.
    ---
    --- Falls back to an impact-position test when the row carries no target,
    --- which is how ground-targeted and untargeted projectiles arrive. The
    --- radius is deliberately generous -- a missile landing two yards away
    --- still hits.
    ---@param unit game_object
    ---@param radius? number yards, for untargeted missiles
    ---@return missile[]
    function M.aimed_at(unit, radius)
        if not unit then return {} end
        radius = radius or 3.0

        local pos = units.position(unit)
        local list = M.all()
        local out = {}
        local n = 0

        for i = 1, #list do
            local missile = list[i]
            if missile then
                local match = false
                if missile.target and missile.target == unit then
                    match = true
                elseif pos and missile.impact_position then
                    match = geometry.distance(missile.impact_position, pos) <= radius
                end
                if match then
                    n = n + 1
                    out[n] = missile
                end
            end
        end
        return out
    end

    --- Missiles aimed at the local player.
    ---@param radius? number
    ---@return missile[]
    function M.incoming(radius)
        local value, hit = tick:get("incoming")
        if hit and not radius then return value or {} end

        local player = units.player()
        if not player then return {} end

        local result = M.aimed_at(player, radius)
        if not radius then tick:put("incoming", result) end
        return result
    end

    --- The soonest impact on the player, or nil when nothing is coming.
    ---@return missile|nil missile
    ---@return number seconds
    function M.next_incoming()
        local list = M.incoming()
        local best, best_time = nil, math.huge
        for i = 1, #list do
            local eta = M.time_to_impact(list[i])
            if eta < best_time then
                best, best_time = list[i], eta
            end
        end
        return best, best_time
    end

    --- Is anything due to land on the player within `seconds`?
    --- The check a reactive defensive wants.
    ---@param seconds number
    ---@return boolean
    function M.incoming_within(seconds)
        local _, eta = M.next_incoming()
        return eta <= seconds
    end

    --- Missiles fired by a given unit.
    ---@param unit game_object
    ---@return missile[]
    function M.from(unit)
        if not unit then return {} end
        local list = M.all()
        local out = {}
        local n = 0
        for i = 1, #list do
            local missile = list[i]
            if missile and (missile.caster == unit or missile.source == unit) then
                n = n + 1
                out[n] = missile
            end
        end
        return out
    end

    --- Missiles of a given spell, or any of a list of spells.
    ---@param spell_id integer|integer[]
    ---@return missile[]
    function M.of_spell(spell_id)
        local list = M.all()
        local out = {}
        local n = 0

        local wanted
        if type(spell_id) == "table" then
            wanted = {}
            for i = 1, #spell_id do wanted[spell_id[i]] = true end
        end

        for i = 1, #list do
            local missile = list[i]
            if missile then
                local id = missile.spell_id
                if (wanted and wanted[id]) or id == spell_id then
                    n = n + 1
                    out[n] = missile
                end
            end
        end
        return out
    end

    ---@param spell_id integer|integer[]
    ---@return boolean
    function M.any_of_spell(spell_id)
        return #M.of_spell(spell_id) > 0
    end

    -- --- events -------------------------------------------------------------

    --- Raises jcore.missile.launched once per new projectile.
    ---
    --- Called from the update phase by the runtime. Without the seen-set this
    --- would fire every frame a missile stays airborne, which for a slow
    --- projectile is thirty events for one cast.
    function M._poll()
        local list = M.all()
        if #list == 0 then
            if next(announced) then
                announced, announced_age = {}, {}
            end
            return
        end

        local now = core.time()
        for i = 1, #list do
            local missile = list[i]
            if missile and missile.spell_id then
                local caster = missile.caster or missile.source
                local caster_guid = caster and units.guid(caster) or "?"
                local key = caster_guid .. "|" .. tostring(missile.spell_id)

                if not announced[key] then
                    announced[key] = true
                    events.emit("jcore.missile.launched", missile)
                end
                announced_age[key] = now
            end
        end

        -- Expire the seen-set so a spell cast twice in a fight raises twice.
        -- Without this the set grows for the session and the second cast of
        -- anything is silent.
        for key, at in pairs(announced_age) do
            if (now - at) > ANNOUNCE_TTL then
                announced[key] = nil
                announced_age[key] = nil
            end
        end
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local _, eta = M.next_incoming()
        return {
            in_flight = #M.all(),
            incoming  = #M.incoming(),
            next_eta  = eta,
            tracked   = util.count(announced),
        }
    end

    return M
end

-- JCore / combat -- combat state, derived events, and time-to-die.
--
-- Depends on: util, log, events, units.
--
-- Everything here is derived by polling the unit cache that has already been
-- built this tick, so it costs almost nothing on top. What it buys is that
-- state TRANSITIONS become events: a plugin that wants to reset its state when
-- a pull starts subscribes to jcore.combat.enter instead of keeping its own
-- was_in_combat flag, and every plugin then agrees on when the pull happened.

return function(rt)
    local util = rt.util
    local events = rt.events
    local units = rt.units
    local log = rt.log.for_tag("JCore/combat")

    local M = {}

    local in_combat = false
    local combat_started = 0
    local combat_ended = 0

    local current_target_guid = nil
    local was_dead = false
    local last_map_id = nil

    -- guid -> { samples = ring of {t, hp_fraction}, last_seen }
    local ttd_tracking = {}
    local TTD_WINDOW = 10.0     -- seconds of history kept per unit
    -- Four samples a second, not one a frame. Only the first and the last
    -- sample in the window enter the estimate, and a frame's worth of health
    -- change is noise; a sample a frame kept six hundred tables per enemy and
    -- shifted the whole list down every frame to drop the oldest.
    local TTD_STEP = 0.25
    local TTD_MIN_SAMPLES = 4
    local TTD_UNKNOWN = math.huge

    -- --- polling ------------------------------------------------------------

    local function poll_combat(player, now)
        local state = player:is_in_combat()
        if state == in_combat then return end

        in_combat = state
        if state then
            combat_started = now
            log.debug("combat enter")
            events.emit("jcore.combat.enter")
        else
            combat_ended = now
            -- Health history from the last pull is meaningless for the next
            -- one, and keeping it makes the first TTD reading after a pull
            -- wildly optimistic.
            ttd_tracking = {}
            log.fmt("debug", "combat leave after %.1fs", combat_started > 0 and (now - combat_started) or 0)
            events.emit("jcore.combat.leave", combat_started > 0 and (now - combat_started) or 0)
        end
    end

    local function poll_target(player)
        local target = player:get_target()
        local guid = (target and target:is_valid()) and target:get_guid() or nil
        if guid == current_target_guid then return end
        local previous = current_target_guid
        current_target_guid = guid
        events.emit("jcore.target.changed", target, previous)
    end

    local function poll_death(player)
        local dead = player:is_dead() or player:is_ghost()
        if dead == was_dead then return end
        was_dead = dead
        if dead then
            log.info("player died")
            events.emit("jcore.player.died")
        else
            events.emit("jcore.player.revived")
        end
    end

    local function poll_zone()
        local map_id = core.get_map_id()
        if map_id == last_map_id then return end
        local previous = last_map_id
        last_map_id = map_id
        -- The first poll of a session is not a zone change, it is the initial
        -- reading. Emitting it would make every plugin run its zone-change
        -- reset before it has finished loading.
        if previous ~= nil then
            ttd_tracking = {}
            log.fmt("info", "zone changed: %s -> %s", tostring(previous), tostring(map_id))
            events.emit("jcore.zone.changed", map_id, previous)
        end
    end

    local function poll_ttd(now)
        local enemies = units.enemies()

        for i = 1, #enemies do
            local unit = enemies[i]
            -- Off the sweep's row: the guid is already there.
            local guid = units.guid(unit)
            if guid then
                local track = ttd_tracking[guid]
                if not track then
                    track = { samples = {}, last_seen = now, sampled = -math.huge }
                    ttd_tracking[guid] = track
                end
                track.last_seen = now

                if (now - track.sampled) >= TTD_STEP then
                    track.sampled = now
                    local samples = track.samples
                    samples[#samples + 1] = { t = now, hp = units.health_fraction(unit) }

                    -- Drop anything outside the window from the front.
                    while #samples > 1 and (now - samples[1].t) > TTD_WINDOW do
                        table.remove(samples, 1)
                    end
                end
            end
        end

        -- Reap units we have not seen for a full window. Without this the table
        -- grows for the whole session in any zone with respawns.
        for guid, track in pairs(ttd_tracking) do
            if (now - track.last_seen) > TTD_WINDOW then
                ttd_tracking[guid] = nil
            end
        end
    end

    --- The core's per-tick combat poll. Registered by main.lua right after the
    --- unit sweep, so it always reads a fresh cache.
    function M._poll()
        local player = units.player()
        if not player then
            -- Loading screen. Treat it as a combat drop so plugins reset,
            -- rather than leaving them believing a fight is still running.
            if in_combat then
                in_combat = false
                ttd_tracking = {}
                events.emit("jcore.combat.leave", 0)
            end
            return
        end

        local now = core.time()
        poll_combat(player, now)
        poll_target(player)
        poll_death(player)
        poll_zone()
        if in_combat then poll_ttd(now) end
    end

    -- --- accessors ----------------------------------------------------------

    ---@return boolean
    function M.in_combat() return in_combat end

    --- Seconds since the pull, 0 when out of combat.
    ---@return number
    function M.duration()
        if not in_combat then return 0 end
        return core.time() - combat_started
    end

    --- Seconds since combat dropped, 0 while in combat. Useful for "did we
    --- just finish a pull" upkeep decisions.
    ---@return number
    function M.time_since_combat()
        if in_combat or combat_ended == 0 then return 0 end
        return core.time() - combat_ended
    end

    ---@return game_object|nil
    function M.target()
        local player = units.player()
        if not player then return nil end
        local target = player:get_target()
        if target and target:is_valid() then return target end
        return nil
    end

    --- True while the player is casting or channelling anything.
    ---@return boolean
    function M.is_busy()
        local player = units.player()
        if not player then return false end
        local ok, casting = pcall(player.is_casting_spell, player)
        if ok and casting then return true end
        local ok_ch, channelling = pcall(player.is_channelling_spell, player)
        return ok_ch and channelling == true
    end

    --- Seconds until the player's current cast or channel completes. 0 when
    --- idle. Lets a rotation decide whether it is worth queueing behind.
    ---@return number
    function M.cast_remaining()
        local player = units.player()
        if not player then return 0 end

        -- EVERY ONE OF THESE IS A pcall, and that is not defensive habit.
        -- These four accessors are read off the player object, and a build
        -- that does not implement one raises rather than answering nil. This
        -- function is called from the first line of the rotation priority
        -- walk, so an error here does not degrade the rotation -- it takes
        -- the whole tick with it, every tick, for as long as the condition
        -- lasts. A character channelling on such a build simply stops doing
        -- anything, with nothing in the log to say why.
        local end_time

        local ok_cast, casting = pcall(player.is_casting_spell, player)
        local ok_chan, channelling = pcall(player.is_channelling_spell, player)

        if ok_cast and casting then
            local ok_end, value = pcall(player.get_active_spell_cast_end_time, player)
            if not ok_end then return 0 end
            end_time = value
        elseif ok_chan and channelling then
            local ok_end, value = pcall(player.get_active_channel_cast_end_time, player)
            if not ok_end then return 0 end
            end_time = value
        else
            return 0
        end

        if type(end_time) ~= "number" then return 0 end

        if not end_time or end_time <= 0 then return 0 end
        -- Cast timestamps are in milliseconds of game time.
        return math.max(0, (end_time - core.game_time()) / 1000.0)
    end

    --- Estimated seconds until `unit` dies at its recent damage-taken rate.
    ---
    --- Returns math.huge when there is not enough history yet, or when the unit
    --- is not losing health -- both are "do not know", and a rotation that
    --- treats a huge number as "it will be alive a while" behaves correctly in
    --- both cases without a special check.
    ---
    --- The estimate is a plain two-point slope across the window rather than a
    --- fit, because the useful signal is the average over the last few seconds
    --- and a fit mostly buys sensitivity to burst noise.
    ---@param unit game_object
    ---@return number seconds
    function M.time_to_die(unit)
        if not unit then return 0 end
        -- A unit in this sweep was valid this frame, and its guid and death
        -- are on its row; anything else is asked the slow way.
        local guid
        if units.snapshot(unit) then
            if units.is_dead(unit) then return 0 end
            guid = units.guid(unit)
        else
            if not unit:is_valid() or unit:is_dead() then return 0 end
            guid = unit:get_guid()
        end
        local track = guid and ttd_tracking[guid]
        if not track then return TTD_UNKNOWN end

        local samples = track.samples
        local n = #samples
        if n < TTD_MIN_SAMPLES then return TTD_UNKNOWN end

        local first, last = samples[1], samples[n]
        local elapsed = last.t - first.t
        local lost = first.hp - last.hp
        if elapsed <= 0 or lost <= 0 then return TTD_UNKNOWN end

        local rate = lost / elapsed  -- health fraction per second
        return last.hp / rate
    end

    --- Convenience wrapper: "will it still be alive in `seconds`?"
    ---@param unit game_object
    ---@param seconds number
    ---@return boolean
    function M.lives_longer_than(unit, seconds)
        return M.time_to_die(unit) > seconds
    end

    function M.stats()
        return {
            in_combat = in_combat,
            duration  = M.duration(),
            target    = current_target_guid,
            tracked   = util.count(ttd_tracking),
            map_id    = last_map_id,
        }
    end

    return M
end

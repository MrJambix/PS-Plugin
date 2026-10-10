-- Jambix AIO / field -- read the fight, then decide what kind of fight it is.
--
-- WHAT WAS MISSING
-- The rotation knew what it was standing next to -- targeting.lua counts
-- enemies and finds clusters -- but it never asked the question that decides
-- everything: AM I WINNING THIS? A priority list that fires the same rules at
-- one boar and at four is not a rotation, it is a macro. And a rotation that
-- notices trouble only when health gets low notices it about eight seconds
-- after the moment it could have done something.
--
-- THE RACE
-- Every fight in this game is one comparison:
--
--     how long until everything on me is dead      (their health / my damage)
--     how long until I am dead                     (my health / their damage)
--
-- Both sides are MEASURED, not assumed. Their health is read off the units;
-- my damage is the rate that health is actually falling, which folds in the
-- pet, procs, weapon speed and every other thing I could not compute; their
-- damage is the rate my own bar is falling. No spell coefficients, no gear
-- table, nothing that goes stale.
--
-- When the first number is smaller, keep killing. When it is not, the fight
-- is already lost and the only question is whether that is fixable with a
-- defensive or only with a head start.
--
-- WHY ADDS ARE HANDLED SEPARATELY
-- A second mob arriving changes the answer to the race INSTANTLY, and the
-- health bar will not reflect it for several seconds. So the roster is
-- watched for arrivals directly: a new enemy engaging after the fight started
-- is an event, not a number to be inferred later. That is the difference
-- between "I have adds" and "I am at 40% and do not know why".
--
-- Hostiles closing on us that have NOT engaged yet are tracked too, because a
-- patrol fifteen yards out and approaching is about to be part of this fight,
-- and the cheapest moment to deal with that is before it arrives.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local targeting = P.targeting

    local M = {}

    -- --- the vocabulary -----------------------------------------------------
    --
    -- One word for the shape of the fight, and one for what to do about it.
    -- The class rule lists read these; they do not re-derive them.

    M.SHAPES = { "IDLE", "SINGLE", "PAIR", "PACK", "ELITE", "BOSS" }
    M.PLANS = { "BURN", "AOE", "CONTROL", "SURVIVE", "FLEE" }

    local state = {
        shape = "IDLE",
        plan = "BURN",
        count = 0,               -- engaged with me
        inbound = 0,             -- closing, not engaged yet
        elites = 0,
        casters = 0,
        runners = 0,
        my_dps = 0,              -- absolute health per second, measured
        their_dps = 0,
        enemy_hp = 0,            -- total remaining, absolute
        my_hp = 0,
        time_to_clear = math.huge,
        time_to_live = math.huge,
        winning = true,
        escalating = false,      -- an add landed recently
        last_add_at = 0,
        reason = "",
    }
    M.state = state

    -- --- the roster ---------------------------------------------------------
    --
    -- Who is on us, when they arrived, and how fast their health is moving.

    local roster = {}            -- guid -> row
    local approach = {}          -- guid -> { distance, at }
    local recent = {}            -- guid -> last time it was engaged with us
    local combat_started = 0

    -- How long a guid stays "something we have already met". Long enough to
    -- cover a mob walking out of range and back, or a threat read blipping
    -- while it picks a new target; short enough that a genuine second pull of
    -- the same creature still counts as an add.
    local REMEMBER_FOR = 20.0

    local SAMPLE_EVERY = 0.25
    local WINDOW = 5.0
    local last_sample = 0

    local function max_health(unit)
        local ok, value = pcall(unit.get_max_health, unit)
        if not ok or type(value) ~= "number" or value <= 0 then return 0 end
        return value
    end

    --- Absolute health, via the fraction so one helper owns the unit-reading.
    local function health_of(unit)
        return units.health_fraction(unit) * max_health(unit)
    end

    --- Health per second this unit is losing. Negative means it is healing.
    local function slope_of(row)
        local n = #row.samples
        if n < 2 then return 0 end
        local first, last = row.samples[1], row.samples[n]
        local dt = last.t - first.t
        if dt < 0.5 then return 0 end
        return (first.hp - last.hp) / dt      -- positive while we are winning
    end

    --- Classification: elite, rare and boss mobs are worth more than their
    --- health bar says, because they hit harder and last longer. The numbers
    --- are WoW's own creature classification ids.
    local NORMAL, ELITE, RARE_ELITE, BOSS, RARE = 0, 1, 2, 3, 4

    -- JCore's units.classification answers per client (1.6.0): the creature
    -- cache's rank on Forever, where get_classification is 0 for every unit.
    local units_service = P.units

    local function classification_of(unit)
        if units_service and units_service.classification then
            local ok, value = pcall(units_service.classification, unit)
            if ok and type(value) == "number" then return value end
        end
        local ok, value = pcall(unit.get_classification, unit)
        if not ok or type(value) ~= "number" then return NORMAL end
        return value
    end

    -- --- the sweep ----------------------------------------------------------

    local function refresh()
        local now = core.time()
        if (now - last_sample) < SAMPLE_EVERY then return end
        last_sample = now

        local player = units.player()
        if not player then roster, approach = {}, {}; return end

        local in_combat = combat.in_combat()
        if not in_combat then
            roster = {}
            combat_started = 0
            state.escalating = false
        elseif combat_started == 0 then
            combat_started = now
        end

        local range = P.tune_secs("rot_target_range", 30)
        local engaged = targeting.my_enemies(range)

        local seen = {}
        local added = 0

        for i = 1, #engaged do
            local unit = engaged[i]
            local ok, guid = pcall(unit.get_guid, unit)
            if ok and guid then
                seen[guid] = true
                local row = roster[guid]
                if not row then
                    row = {
                        unit = unit, guid = guid,
                        first_seen = now, samples = {},
                        max_hp = max_health(unit),
                        classification = classification_of(unit),
                    }
                    roster[guid] = row

                    -- An arrival AFTER the fight began is an add. The first
                    -- second is the pull itself, not an add: everything that
                    -- comes with the opener shows up in the same instant.
                    --
                    -- AND IT MUST BE SOMETHING NEW. The live log kept saying
                    -- "1 more joined the fight (1 on us now)", which cannot be
                    -- true -- if one joined and one is present, nothing
                    -- joined. The roster drops anything it stops seeing, and a
                    -- mob that steps out of range for a moment, or whose
                    -- threat read blips while it retargets, comes straight
                    -- back and was being announced as an add each time.
                    local seen_before = recent[guid]
                    if in_combat and combat_started > 0
                        and (now - combat_started) > 1.0
                        and not seen_before then
                        added = added + 1
                    end
                    recent[guid] = now
                else
                    row.unit = unit
                    -- Re-read rather than trust the value taken when the row
                    -- was created: a roster row outlives a pull whenever the
                    -- same unit is engaged again, and an elite that was read
                    -- as normal once would stay wrong for the session.
                    row.classification = classification_of(unit)
                end

                row.samples[#row.samples + 1] = { t = now, hp = health_of(unit) }
                while #row.samples > 2 and (now - row.samples[1].t) > WINDOW do
                    table.remove(row.samples, 1)
                end
            end
        end

        -- Anything that stopped being engaged -- dead, fled, or out of range.
        for guid in pairs(roster) do
            if not seen[guid] then roster[guid] = nil end
        end

        for guid, at in pairs(recent) do
            if (now - at) > REMEMBER_FOR then recent[guid] = nil end
        end

        if added > 0 then
            state.last_add_at = now
            local total = 0
            for _ in pairs(roster) do total = total + 1 end
            log.fmt("warn", "%d more joined the fight (%d on us now)", added, total)
            ctx.emit("jambix.aio.field_adds", added, total)
            if P.narrate then
                P.narrate.say("warn",
                    added == 1 and "Add" or (added .. " adds"),
                    string.format("%d enemies on you now", total),
                    "field_adds")
            end
        end
        state.escalating = (now - state.last_add_at) < 6.0

        -- --- hostiles closing in, not yet engaged --------------------------
        -- A patrol walking into the fight is part of the fight. Distance
        -- shrinking over consecutive samples is the whole test; a mob that is
        -- merely nearby and stationary is not a problem.

        local inbound = 0
        local nearby = units.enemies_within(range)
        local still_here = {}

        for i = 1, #nearby do
            local unit = nearby[i]
            local ok, guid = pcall(unit.get_guid, unit)
            if ok and guid and not roster[guid] then
                still_here[guid] = true
                local distance = units.distance(unit)
                local previous = approach[guid]
                if previous and (now - previous.at) < 3.0 then
                    local closed = previous.distance - distance
                    -- A yard and a half over the sample window is a walk, not
                    -- a rounding error or a mob milling about.
                    if closed > 1.5 and distance < range then
                        inbound = inbound + 1
                    end
                end
                approach[guid] = { distance = distance, at = now }
            end
        end
        for guid in pairs(approach) do
            if not still_here[guid] then approach[guid] = nil end
        end
        state.inbound = inbound

        -- --- totals ---------------------------------------------------------

        local count, elites, casters, runners = 0, 0, 0, 0
        local enemy_hp, my_dps = 0, 0

        for _, row in pairs(roster) do
            count = count + 1
            local unit = row.unit
            if unit and unit:is_valid() and not unit:is_dead() then
                enemy_hp = enemy_hp + health_of(unit)
                my_dps = my_dps + slope_of(row)

                local class = row.classification
                if class == ELITE or class == RARE_ELITE or class == BOSS then
                    elites = elites + 1
                end

                local ok_cast, casting = pcall(unit.is_casting_spell, unit)
                if ok_cast and casting then casters = casters + 1 end

                -- A runner is a nearly-dead mob moving away: it is about to
                -- pull whatever it reaches. Worth a snare, and worth knowing
                -- about before it arrives back with company.
                if units.health_fraction(unit) < 0.25 then
                    local ok_move, moving = pcall(unit.is_moving, unit)
                    if ok_move and moving then
                        local previous = row.last_distance
                        local distance = units.distance(unit)
                        if previous and distance > previous + 0.5 then
                            runners = runners + 1
                        end
                        row.last_distance = distance
                    end
                end
            end
        end

        state.count, state.elites = count, elites
        state.casters, state.runners = casters, runners
        state.enemy_hp = enemy_hp
        state.my_dps = math.max(my_dps, 0)

        -- Their damage comes from the resource module, which already measures
        -- our own bar. Converting to absolute keeps both sides of the race in
        -- the same units.
        local my_max = max_health(player)
        state.my_hp = units.health_fraction(player) * my_max
        local res = P.resources
        state.their_dps = res and math.max(-res.hp_rate(), 0) * my_max or 0

        state.time_to_clear = state.my_dps > 0
            and (enemy_hp / state.my_dps) or math.huge
        state.time_to_live = state.their_dps > 0
            and (state.my_hp / state.their_dps) or math.huge

        state.shape = M.classify_shape(count, elites)
        state.plan, state.reason = M.decide()
    end

    -- --- classification -----------------------------------------------------

    ---@param count integer
    ---@param elites integer
    ---@return string
    function M.classify_shape(count, elites)
        if count == 0 then return "IDLE" end
        if elites > 0 then
            -- One elite is a real fight; a pack containing one is worse than
            -- either on its own, which the plan below accounts for.
            for _, row in pairs(roster) do
                if row.classification == BOSS then return "BOSS" end
            end
            return "ELITE"
        end
        if count == 1 then return "SINGLE" end
        if count == 2 then return "PAIR" end
        return "PACK"
    end

    --- Is spreading damage better than concentrating it?
    ---
    --- Not a count. Killing one mob removes its damage from the fight; an AoE
    --- that leaves everything alive removes none of it. So AoE wins when
    --- there are enough targets that the total damage dealt beats the value of
    --- taking one out of the fight sooner -- which is roughly three, and is
    --- checked against what the class can actually DO rather than assumed.
    ---@return boolean
    ---@return integer clustered
    function M.aoe_worth_it()
        local radius = P.opt("rot_aoe_radius", 8)
        local clustered = targeting.aoe_count(radius)
        if clustered < 2 then return false, clustered end

        -- No point planning an AoE the active profile cannot deliver.
        if not M.class_has_aoe() then return false, clustered end

        -- Against elites, concentrating is almost always right: they last
        -- long enough that removing one from the fight matters more than
        -- chipping all of them.
        if state.elites > 0 and clustered < 4 then return false, clustered end

        return clustered >= P.tune_secs("rot_aoe_min_targets", 3), clustered
    end

    --- Does this class have anything that hits more than one thing?
    ---
    --- Declared by the class module rather than inferred from its rules: a
    --- rule predicate is a closure, and there is no way to ask a closure what
    --- it would have done. A wrong answer here only decides whether the plan
    --- is allowed to say AOE, and the rules still check their own counts.
    ---@return boolean
    function M.class_has_aoe()
        local rot = P.rotation
        local class_module = rot and rot.active_class()
        return class_module ~= nil and class_module.aoe_capable == true
    end

    -- --- the plan -----------------------------------------------------------

    --- How much of a head start the race needs before we call it winnable.
    ---
    --- Not one, because the measurement is noisy and because being exactly
    --- level with the mob means dying to one unlucky crit. A quarter again is
    --- the margin, and it is the only tunable in this file that is a taste
    --- rather than a measurement -- so it is derived from how hard we are
    --- being hit, and a heavier hitter demands a bigger margin.
    -- Past this much life left, the ratio stops mattering: whatever the
    -- numbers say, a fight with half a minute of runway is one to keep
    -- fighting rather than one to panic about.
    local SAFE_RUNWAY = 30.0

    local function margin()
        if state.their_dps <= 0 or state.my_hp <= 0 then return 1.25 end
        local hits_left = state.time_to_live
        if hits_left < 5 then return 1.6 end
        if hits_left < 10 then return 1.35 end
        return 1.25
    end

    ---@return string plan
    ---@return string reason
    function M.decide()
        if state.count == 0 then return "BURN", "nothing engaged" end

        -- THE RACE. Both sides measured; neither assumed -- and when one of
        -- them CANNOT be measured, that is not a verdict either.
        --
        -- The live log: "losing the race: infs to clear against 128s to live".
        -- Nothing was wrong. Our damage rate read as zero -- every mob was at
        -- full health because the pull had only just started -- so clear time
        -- was infinite, infinity is not less than anything, and the plan went
        -- to SURVIVE with two minutes of life in the bar. That suppressed
        -- bursting and fired defensives, on no evidence at all.
        local clear, live = state.time_to_clear, state.time_to_live

        -- THE LIFE SIDE COMES FIRST, because it is the half that can end the
        -- fight. Past half a minute of runway there is no emergency whatever
        -- the ratio says, and the ratio is exactly what went wrong in the live
        -- log: our damage rate read as zero -- every mob still at full health
        -- three seconds into a pull -- so clear time was infinite, infinity is
        -- not less than anything, and the plan went to SURVIVE with two
        -- minutes of life left. That suppressed bursting and fired defensives
        -- on no evidence at all.
        if live > SAFE_RUNWAY then
            state.winning = true
            return M.pick_offence()
        end

        -- Inside the runway, an unmeasurable clear time is not ignorance any
        -- more: we are being killed and nothing we are doing is showing up on
        -- anything. That is the definition of losing.
        local winnable = clear < math.huge and clear < (live / margin())
        state.winning = winnable

        -- A fight we are losing is first a problem for defensives, and only
        -- then a problem for our legs. The split is how much time is left: a
        -- defensive that buys six seconds is worthless with three seconds of
        -- life in the bar.
        if not winnable and live < math.huge then
            local clear_text = clear == math.huge
                and "nothing landing" or string.format("%.0fs to clear", clear)
            if live <= (P.derived_secs and P.derived_secs("rot_flee_runway", 4) or 4) then
                return "FLEE", string.format(
                    "%.0fs to live, %s -- cannot win this", live, clear_text)
            end
            return "SURVIVE", string.format(
                "losing the race: %s against %.0fs to live", clear_text, live)
        end

        -- Winning, but about to stop: adds and inbound patrols change the
        -- answer before the health bar does. Controlling them now is cheaper
        -- than out-damaging them later.
        if state.escalating or state.inbound > 0 then
            local extra = state.inbound
            if state.count >= 3 or (state.count + extra) >= 3 then
                return "CONTROL", string.format(
                    "%d on us%s -- take the pressure off before it builds",
                    state.count,
                    extra > 0 and string.format(", %d more closing", extra) or "")
            end
        end

        return M.pick_offence()
    end

    --- BURN or AOE: the choice when nothing is going wrong.
    ---@return string plan
    ---@return string reason
    function M.pick_offence()
        local aoe, clustered = M.aoe_worth_it()
        if aoe then
            return "AOE", string.format("%d clustered", clustered)
        end

        return "BURN", state.count == 1 and "one target"
            or string.format("%d up, killing them in order", state.count)
    end

    -- --- what the rules ask -------------------------------------------------

    --- May damage be spread right now?
    ---
    --- A veto rather than a decision: each AoE rule keeps its own target
    --- minimum, because how many things a spell reaches is a property of the
    --- spell. This answers the separate question of whether spreading is the
    --- right idea at all.
    ---@return boolean
    function M.spread_ok()
        if state.plan == "FLEE" then return false end
        -- Against a short pack containing an elite, concentrating takes a mob
        -- out of the fight sooner and that is worth more than chipping all of
        -- them. A big enough pack flips it back.
        if state.elites > 0 and state.count < 4 then return false end
        return true
    end

    ---@return string
    function M.plan() return state.plan end

    ---@return string
    function M.shape() return state.shape end

    ---@return boolean
    function M.winning() return state.winning end

    ---@return boolean
    function M.escalating() return state.escalating end

    ---@return integer engaged
    ---@return integer inbound
    function M.counts() return state.count, state.inbound end

    ---@return integer
    function M.elites() return state.elites end

    ---@return integer
    function M.casters() return state.casters end

    ---@return integer
    function M.runners() return state.runners end

    --- Seconds until everything on us is dead at the rate we are killing it.
    ---@return number
    function M.time_to_clear() return state.time_to_clear end

    --- Seconds until we are dead at the rate we are being hit.
    ---@return number
    function M.time_to_live() return state.time_to_live end

    --- True when the fight is going badly enough to spend a global cooldown
    --- on not dying. The single question a defensive rule should ask.
    ---@return boolean
    function M.in_trouble()
        return state.plan == "SURVIVE" or state.plan == "FLEE"
    end

    --- The nearly-dead mob heading away from us, if there is one. A snare on
    --- this is worth more than any damage: it is about to bring friends.
    ---@return game_object|nil
    function M.runner()
        for _, row in pairs(roster) do
            local unit = row.unit
            if unit and unit:is_valid() and not unit:is_dead()
                and units.health_fraction(unit) < 0.25 then
                local ok, moving = pcall(unit.is_moving, unit)
                if ok and moving and row.last_distance then
                    local distance = units.distance(unit)
                    if distance > row.last_distance + 0.5 then return unit end
                end
            end
        end
        return nil
    end

    --- The engaged enemy currently casting, for interrupt selection. Prefers
    --- whatever is closest to finishing, because that is the one an interrupt
    --- still catches.
    ---@return game_object|nil
    function M.caster()
        local best, best_remaining = nil, math.huge
        for _, row in pairs(roster) do
            local unit = row.unit
            if unit and unit:is_valid() and not unit:is_dead() then
                local ok, casting = pcall(unit.is_casting_spell, unit)
                if ok and casting then
                    local ok_end, finish = pcall(unit.get_active_spell_cast_end_time, unit)
                    local remaining = (ok_end and type(finish) == "number")
                        and (finish - core.game_time()) or 0
                    if remaining < best_remaining then
                        best, best_remaining = unit, remaining
                    end
                end
            end
        end
        return best
    end

    --- Everything engaged with us, weakest first.
    ---
    --- Killing the weakest first takes a whole mob's damage out of the fight
    --- soonest, which is the entire reason focus-firing beats spreading when
    --- an AoE is not worth it.
    ---@return game_objects_table
    function M.by_weakest()
        local out = {}
        for _, row in pairs(roster) do
            local unit = row.unit
            if unit and unit:is_valid() and not unit:is_dead() then
                out[#out + 1] = unit
            end
        end
        table.sort(out, function(a, b)
            return units.health_fraction(a) < units.health_fraction(b)
        end)
        return out
    end

    local last_plan, last_shape, last_count = "BURN", "IDLE", 0

    local function announce()
        local changed = state.plan ~= last_plan
            or state.shape ~= last_shape
            or state.count ~= last_count

        if changed then
            -- One event carrying the whole read, for anything else that wants
            -- to know what kind of fight this is -- the readout, another
            -- plugin, or a test. Emitted on any change of substance rather
            -- than only on a change of plan, because "still SURVIVE but now
            -- three of them" is a different situation.
            ctx.emit("jambix.aio.field", M.stats())
            last_shape, last_count = state.shape, state.count
        end

        if state.plan == last_plan then return end

        -- Only the plans that mean something has gone wrong are worth saying
        -- out loud. Switching between BURN and AOE is ordinary.
        if state.plan == "SURVIVE" or state.plan == "FLEE"
            or state.plan == "CONTROL" then
            log.fmt("warn", "plan: %s -- %s", state.plan, state.reason)
            if P.narrate then
                P.narrate.say(state.plan == "FLEE" and "danger" or "warn",
                    state.plan == "FLEE" and "Break off"
                        or (state.plan == "SURVIVE" and "Defensives" or "Too many"),
                    state.reason, "field_plan")
            end
        else
            log.fmt("debug", "plan: %s -- %s", state.plan, state.reason)
        end

        ctx.emit("jambix.aio.field_plan", state.plan, state.reason)
        last_plan = state.plan
    end

    function M.stats()
        local function secs(v)
            if v == math.huge then return "--" end
            return string.format("%.0fs", v)
        end
        return {
            shape = state.shape,
            plan = state.plan,
            reason = state.reason,
            count = state.count,
            inbound = state.inbound,
            elites = state.elites,
            casters = state.casters,
            runners = state.runners,
            winning = state.winning,
            escalating = state.escalating,
            clear = secs(state.time_to_clear),
            live = secs(state.time_to_live),
            my_dps = state.my_dps,
            their_dps = state.their_dps,
        }
    end

    ctx.tick(function()
        refresh()
        announce()
    end)

    return M
end

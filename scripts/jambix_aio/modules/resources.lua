-- Jambix AIO / resources -- health and power as things that have a DIRECTION.
--
-- THE BUG THIS MODULE EXISTS TO FIX
-- A warlock at 30% mana and 70% health taps for mana. Now it is at 55% mana
-- and 50% health, so it drains life to get health back, which costs mana, so
-- it taps again. Every individual decision reads correct against a threshold
-- and the character dies anyway, because nothing was looking at where the two
-- bars were HEADED -- only at where they were.
--
-- A threshold cannot see a spiral. A slope can. So this module keeps a short
-- history of both bars and answers the questions the thresholds could not:
--
--   * Is health falling, and how long until it runs out at this rate?
--   * Is power falling, and how long until it runs out at this rate?
--   * Given both, is spending health to buy power actually a trade that ends
--     with us alive, or is it the next step of the spiral?
--
-- WHY SLOPES AND NOT JUST "AM I TAKING DAMAGE"
-- Health falling is normal; a levelling warlock is meant to end most pulls
-- around half health. What is not normal is health falling with no prospect
-- of the fight ending first. time_to_empty compared against the target's
-- time_to_die is the whole judgement, and it is the one the old thresholds
-- could not express.
--
-- WHAT THIS MODULE DOES NOT DO
-- It never casts anything. It answers questions, and the class rule lists
-- decide what to do with the answers. That keeps the spiral logic in one
-- place instead of restated, differently and wrongly, in nine class files.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat

    local M = {}

    -- Lines with no slider behind them: worked out from live data
    -- (modules/auto.lua), else the default. Never the menu (1.39.0).
    local function derived(id, default_pct)
        if P.derived then return P.derived(id, default_pct) end
        return default_pct / 100
    end
    local function derived_secs(id, default)
        if P.derived_secs then return P.derived_secs(id, default) end
        return default
    end

    -- --- sampling -----------------------------------------------------------
    --
    -- A ring of samples over a short window. Short, because a levelling fight
    -- is fifteen seconds and a window longer than the fight would average the
    -- pull and the recovery together into a slope of roughly zero -- which is
    -- exactly the wrong answer at both ends.

    local WINDOW = 6.0            -- seconds of history
    local SAMPLE_EVERY = 0.25     -- seconds between samples
    local MAX_SAMPLES = math.ceil(WINDOW / SAMPLE_EVERY) + 2

    local samples = {}            -- { t, hp, power } newest last
    local last_sample = 0

    local function push(t, hp, power)
        samples[#samples + 1] = { t = t, hp = hp, power = power }
        while #samples > MAX_SAMPLES do table.remove(samples, 1) end
        while #samples > 2 and (t - samples[1].t) > WINDOW do
            table.remove(samples, 1)
        end
    end

    --- Fraction per second, negative while the bar is draining.
    ---
    --- Deliberately the crude two-point slope over the window rather than a
    --- regression: the question is "are we losing this bar and how fast", and
    --- a regression buys precision that no decision here is sensitive to.
    ---@param field string "hp" or "power"
    ---@return number
    local function slope(field)
        if #samples < 2 then return 0 end
        local first, last = samples[1], samples[#samples]
        local dt = last.t - first.t
        if dt < 0.5 then return 0 end        -- too short to mean anything
        return (last[field] - first[field]) / dt
    end

    --- Seconds until this bar reaches zero at the current rate.
    ---
    --- Returns math.huge when the bar is steady or rising, which is the right
    --- answer and the one every caller wants: "no deadline".
    ---@param field string
    ---@param current number 0..1
    ---@return number
    local function time_to_empty(field, current)
        local rate = slope(field)
        if rate >= -0.001 then return math.huge end
        return current / -rate
    end

    -- --- current state ------------------------------------------------------

    local state = {
        hp = 1, power = 1,
        hp_rate = 0, power_rate = 0,
        hp_empty = math.huge, power_empty = math.huge,
        posture = "HEALTHY",
        has_power = false,
    }
    M.state = state

    --- The primary resource fraction, using whatever the active profile calls
    --- its power. A rage or energy class has no mana crisis to manage, and
    --- says so through has_power rather than by reading 0/0 as "empty".
    ---@return number fraction
    ---@return boolean has_power
    local function read_power()
        local class_module = P.rotation and P.rotation.active_class()
        if not class_module then return 1, false end

        local profile = P.rotation.active_profile and P.rotation.active_profile(class_module)
        local resource = (profile and profile.power) or class_module.power
        if resource ~= "MANA" then return 1, false end

        local current, maximum = P.power(resource), P.power_max(resource)
        if not maximum or maximum <= 0 then return 1, false end
        return current / maximum, true
    end

    -- --- posture ------------------------------------------------------------
    --
    -- One word for "how much trouble are the bars in", so that nine class
    -- files can ask one question instead of each inventing its own thresholds.
    --
    --   HEALTHY   spend freely
    --   CONSERVE  the fight is affordable but the next one is not; stop
    --             spending the expensive resource on things the cheap one can
    --             do, and take any free recovery on offer
    --   RECOVER   one of the bars will not last this fight; recovering is now
    --             worth a global cooldown that would otherwise be damage
    --   CRITICAL  we are losing. Nothing but staying alive.

    local function classify(hp, power, has_power, hp_empty, power_empty, fight_left)
        if hp <= P.tune("res_critical_hp", 25) then return "CRITICAL" end

        -- Health that runs out before the fight does is critical even at a
        -- comfortable-looking percentage. This is the case the old thresholds
        -- could not see: 45% health is fine, and 45% health falling by 8% a
        -- second with twelve seconds of mob left is not.
        if hp_empty < fight_left and hp_empty < 8 then return "CRITICAL" end

        if has_power and power <= P.tune("res_critical_power", 10) then
            return "RECOVER"
        end
        if hp_empty < fight_left then return "RECOVER" end
        if has_power and power_empty < fight_left then return "RECOVER" end

        if hp <= P.tune("res_conserve_hp", 55) then return "CONSERVE" end
        if has_power and power <= P.tune("res_conserve_power", 35) then
            return "CONSERVE"
        end
        return "HEALTHY"
    end

    -- --- the health-for-power trade -----------------------------------------

    --- May we pay `cost` of our health bar to gain power right now?
    ---
    --- THIS IS THE ANSWER TO THE SPIRAL. Four separate reasons to refuse, and
    --- a warlock only needs to hit one of them to be saved from itself:
    ---
    ---   1. The cost would take us below the floor. Obvious, and the only one
    ---      the old threshold check implemented.
    ---   2. Health is falling fast enough that the cost plus the incoming
    ---      damage empties the bar before the fight ends. Paying health we do
    ---      not have yet is how a full mana bar ends up on a corpse.
    ---   3. We are already in trouble. CRITICAL spends nothing on anything.
    ---   4. Power is not actually the binding constraint. Tapping at 70% mana
    ---      because the floor allows it is free damage thrown away.
    ---
    ---@param cost number fraction of MAX health the trade costs, e.g. 0.15
    ---@param opts? table { floor?: number, need_power?: number }
    ---@return boolean ok
    ---@return string reason
    function M.may_trade_health(cost, opts)
        opts = opts or {}
        local floor = opts.floor or P.tune("res_trade_floor_hp", 50)
        local need = opts.need_power or derived("res_trade_power", 35)

        if not state.has_power then return false, "no mana bar" end
        if state.power > need then return false, "mana is not the problem yet" end
        if state.posture == "CRITICAL" then return false, "too much trouble" end

        local after = state.hp - (cost or 0)
        if after < floor then
            return false, string.format("would leave %.0f%% health", after * 100)
        end

        -- The predictive half. Project the cost forward at the rate health is
        -- ALREADY moving, over the time the fight has left.
        local fight_left = M.fight_left()
        if fight_left > 0 and fight_left < math.huge then
            local horizon = math.min(fight_left, 10)
            local projected = state.hp - cost + (state.hp_rate * horizon)
            if projected < P.tune("res_critical_hp", 25) then
                return false, string.format(
                    "health is falling %.0f%%/s; the trade ends at %.0f%%",
                    -state.hp_rate * 100, projected * 100)
            end
        end

        return true, "affordable"
    end

    --- How long the current fight has left, as a deadline for the judgements
    --- above. No target and no combat means no deadline at all.
    ---@return number seconds, or math.huge
    function M.fight_left()
        if not combat.in_combat() then return math.huge end
        local target = combat.target()
        if not target or not target:is_valid() or target:is_dead() then
            -- In combat with something we cannot see. Assume a normal pull
            -- rather than no deadline, because "no deadline" would license
            -- spending we may not be able to afford.
            return derived_secs("res_unknown_fight", 12)
        end
        local ttd = combat.time_to_die(target)
        if not ttd or ttd <= 0 or ttd == math.huge then
            return derived_secs("res_unknown_fight", 12)
        end
        return ttd
    end

    --- Is spending a global cooldown on recovery worth it right now?
    ---
    --- Recovery is never free: the cast is damage not done, which makes the
    --- fight longer, which costs more health. It is worth it only when the
    --- bar in question will not otherwise last.
    ---@return boolean
    function M.should_recover()
        return state.posture == "RECOVER" or state.posture == "CRITICAL"
    end

    ---@return boolean
    function M.may_spend_freely()
        return state.posture == "HEALTHY"
    end

    -- --- queries the class files use ---------------------------------------

    ---@return number 0..1
    function M.hp() return state.hp end

    ---@return number 0..1
    function M.power() return state.power end

    ---@return string
    function M.posture() return state.posture end

    ---@return number fraction per second, negative while falling
    function M.hp_rate() return state.hp_rate end

    ---@return number
    function M.power_rate() return state.power_rate end

    ---@return number seconds, or math.huge
    function M.hp_empty() return state.hp_empty end

    ---@return number seconds, or math.huge
    function M.power_empty() return state.power_empty end

    --- True when health is draining faster than a levelling pull should.
    --- Used to refuse trades and to explain a refusal to the player.
    ---@return boolean
    function M.bleeding()
        return state.hp_rate < -derived("res_bleeding_rate", 4)
    end

    -- --- the sampler --------------------------------------------------------

    local last_posture = "HEALTHY"

    local function sample()
        local now = core.time()
        if (now - last_sample) < SAMPLE_EVERY then return end
        last_sample = now

        local player = units.player()
        if not player then
            samples = {}
            return
        end

        -- Death and resurrection are discontinuities, not slopes. Sampling
        -- across them would read a corpse as "health falling 100% per second"
        -- and a resurrection as a miraculous recovery.
        if player:is_dead() then
            samples = {}
            state.hp, state.hp_rate, state.hp_empty = 0, 0, math.huge
            state.posture = "CRITICAL"
            return
        end

        local hp = units.health_fraction(player)
        local power, has_power = read_power()

        push(now, hp, power)

        state.hp, state.power, state.has_power = hp, power, has_power
        state.hp_rate = slope("hp")
        state.power_rate = has_power and slope("power") or 0
        state.hp_empty = time_to_empty("hp", hp)
        state.power_empty = has_power and time_to_empty("power", power) or math.huge

        state.posture = classify(hp, power, has_power,
            state.hp_empty, state.power_empty, M.fight_left())

        if state.posture ~= last_posture then
            -- Only the bad transitions are worth a line; recovering back to
            -- HEALTHY is the expected end of every fight.
            if state.posture == "CRITICAL" or state.posture == "RECOVER" then
                log.fmt("debug", "resources: %s (hp %.0f%% %+.1f%%/s, mana %.0f%% %+.1f%%/s)",
                    state.posture, hp * 100, state.hp_rate * 100,
                    power * 100, state.power_rate * 100)
                ctx.emit("jambix.aio.resource_posture", state.posture, {
                    hp = hp, power = power,
                    hp_rate = state.hp_rate, power_rate = state.power_rate,
                })
            end
            last_posture = state.posture
        end
    end

    function M.stats()
        local function secs(v)
            if v == math.huge then return "--" end
            return string.format("%.0fs", v)
        end
        return {
            posture = state.posture,
            hp = state.hp,
            power = state.power,
            has_power = state.has_power,
            hp_rate = state.hp_rate,
            power_rate = state.power_rate,
            hp_empty = secs(state.hp_empty),
            power_empty = secs(state.power_empty),
            samples = #samples,
        }
    end

    ctx.tick(function() sample() end)

    return M
end

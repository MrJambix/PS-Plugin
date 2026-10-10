-- Jambix AIO / react / behavior -- what kind of moment this is.
--
-- TWO AXES, NOT ONE LIST
-- "How much trouble am I in" and "what kind of fight is this" are separate
-- questions: a boss fight can be going perfectly, and a fight with one boar
-- can be an emergency. So there are two answers, and a rule reads both.
--
--   mode     NORMAL -> DEFENSIVE -> EMERGENCY -> ESCAPE, and RECOVERY on the
--            way back down
--   context  BOSS, AOE, PVP, or none
--
-- UP IS IMMEDIATE, DOWN IS EARNED
-- Trouble is acted on the frame it is seen. Leaving it is not: the situation
-- has to have stayed better for a while (DWELL) before the mode steps down,
-- and stepping down from EMERGENCY or ESCAPE goes through RECOVERY rather than
-- straight to NORMAL -- the fight that nearly killed us is not over because
-- one potion landed. Together with the latches' two lines, that is what stops
-- the mode flickering when health hovers around a threshold.

return function(P)
    local M = {}

    local LEVEL = { NORMAL = 0, RECOVERY = 1, DEFENSIVE = 2, EMERGENCY = 3, ESCAPE = 4 }
    local NAME = { [0] = "NORMAL", [1] = "RECOVERY", [2] = "DEFENSIVE", [3] = "EMERGENCY", [4] = "ESCAPE" }
    M.LEVEL, M.NAME = LEVEL, NAME

    -- Seconds the demand must stay below the current mode before stepping down.
    local DWELL = { [1] = 3.0, [2] = 1.5, [3] = 1.5, [4] = 2.5 }
    -- Seconds in EMERGENCY with nothing left to press before it becomes ESCAPE.
    local OPTIONS_FAILING_AFTER = 2.0

    local mode, context = 0, nil
    local since = -math.huge
    local lower_since = nil
    local why = "nothing happening"

    --- Have the survival options run out? Nothing defensive ready, nothing in
    --- the bag, still being hit, and health still going the wrong way.
    ---@param W table
    ---@return boolean
    local function options_failing(W)
        local pl = W.player
        if pl.defensives_ready > 0 then return false end
        if pl.healthstone or pl.potion then return false end
        if W.enemies.on_me < 1 then return false end
        return pl.hp_rate < 0
    end

    --- The mode the situation asks for right now, before any dwell.
    ---@param W table
    ---@param now number
    ---@return integer level
    ---@return string reason
    local function demand(W, now)
        local sit, pl = W.sit, W.player

        if not pl.in_combat then
            if mode == LEVEL.NORMAL then return LEVEL.NORMAL, "out of combat" end
            if pl.hp < 0.6 or sit.mana_low then
                return LEVEL.RECOVERY, string.format("out of combat at %.0f%% health", pl.hp * 100)
            end
            return LEVEL.NORMAL, "out of combat"
        end

        if sit.flee then return LEVEL.ESCAPE, "the fight cannot be won: " .. (W.field.reason or "") end
        if mode >= LEVEL.EMERGENCY and (now - since) >= OPTIONS_FAILING_AFTER and options_failing(W) then
            return LEVEL.ESCAPE, "survival options exhausted"
        end

        if sit.bailout then return LEVEL.EMERGENCY, "hardcore bail-out" end
        if sit.hp_critical then
            return LEVEL.EMERGENCY, string.format("critical health (%.0f%%)", pl.hp * 100)
        end
        if sit.danger_extreme then
            return LEVEL.EMERGENCY, string.format("danger %d", math.floor(W.env.danger + 0.5))
        end
        if sit.hp_low and W.enemies.on_me >= 2 and pl.hp_rate < -0.04 then
            return LEVEL.EMERGENCY, string.format("%d on you and falling", W.enemies.on_me)
        end

        if sit.hp_low then return LEVEL.DEFENSIVE, string.format("low health (%.0f%%)", pl.hp * 100) end
        if sit.danger_high then
            return LEVEL.DEFENSIVE, string.format("danger %d", math.floor(W.env.danger + 0.5))
        end
        if sit.losing then
            -- The field's own reason already says "losing the race: ..." when
            -- that is its plan; the trace read "losing the race: losing the
            -- race: 26s to clear" (1.55.4).
            local why = W.field.reason or ""
            if why == "" then
                why = "losing the race"
            elseif why:find("losing the race", 1, true) ~= 1 then
                why = "losing the race: " .. why
            end
            return LEVEL.DEFENSIVE, why
        end
        -- Two on us and the race lost on paper, counted from each mob's first
        -- hit (tactics.lua): seconds before the field's health-bar measure can
        -- show the add. Control and heals rise; nothing defensive fires on it.
        if sit.outnumbered then
            local plan = W.plan
            if plan then
                return LEVEL.DEFENSIVE, string.format("outnumbered: %d on you, %.0fs to live against %.0fs to clear",
                    plan.on_me or 0, plan.ttl or 0, plan.ttc or 0)
            end
            return LEVEL.DEFENSIVE, "outnumbered"
        end
        if sit.incoming then return LEVEL.DEFENSIVE, "a big cast is coming at you" end

        if mode == LEVEL.RECOVERY and (pl.hp < 0.6 or W.env.danger > 25) then
            return LEVEL.RECOVERY, "still recovering"
        end
        return LEVEL.NORMAL, "nothing pressing"
    end

    local function pick_context(W)
        if W.env.pvp then return "PVP" end
        if W.env.boss then return "BOSS" end
        if W.sit.aoe then return "AOE" end
        return nil
    end

    --- Advances the state machine. Returns the transition, when there was one.
    ---@param W table
    ---@param now number
    ---@return table|nil change { from, to, why } for the mode
    ---@return table|nil context_change { from, to }
    function M.update(W, now)
        local want, reason = demand(W, now)
        local change = nil

        if want > mode then
            change = { from = NAME[mode], to = NAME[want], why = reason }
            mode, since, lower_since, why = want, now, nil, reason
        elseif want < mode then
            lower_since = lower_since or now
            if (now - lower_since) >= (DWELL[mode] or 1.5) then
                -- Out of an emergency, the way down passes through recovery.
                local target = want
                if mode >= LEVEL.EMERGENCY and want < LEVEL.RECOVERY then target = LEVEL.RECOVERY end
                if target ~= mode then
                    change = { from = NAME[mode], to = NAME[target], why = reason }
                    mode, since, lower_since, why = target, now, nil, reason
                end
            end
        else
            lower_since = nil
            why = reason
        end

        local ctx_change = nil
        local want_ctx = pick_context(W)
        if want_ctx ~= context then
            ctx_change = { from = context, to = want_ctx }
            context = want_ctx
        end

        W.mode, W.mode_level, W.context = NAME[mode], mode, context
        W.mode_why, W.mode_age = why, now - since
        return change, ctx_change
    end

    ---@return string mode
    ---@return string|nil context
    ---@return string why
    function M.current()
        return NAME[mode], context, why
    end

    --- Combat is over and nothing carried over: back to the floor.
    ---@param now number
    function M.reset(now)
        mode, context, since, lower_since, why = 0, nil, now, nil, "reset"
    end

    return M
end

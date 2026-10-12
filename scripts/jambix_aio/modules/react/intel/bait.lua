-- Jambix AIO / react / intel / bait -- bait opportunity detection (PvP
-- intelligence, Stage 8 / brief Phase 7): a moment to make a player spend
-- something -- its gap closer, its defensive, its interrupt, its trinket --
-- because the predictor says it will, and we have the counter ready.
--
-- OBSERVED  what is ready on our side (the spellbook), the target's class
--           and distance, its defensive up or not, its trinket seen used
--           (pvp.lua), its defensives seen (the ledger), the threat level,
--           the control plan's hold, our mana.
-- INFERRED  that the player will take the bait: the predictor's pattern,
--           read only through intel.sure at PREDICT.threshold with the
--           evidence line met; every bait carries that confidence, scaled
--           by how good the counter is.
-- UNKNOWN   whether the bait is taken (the predictor's later observation
--           says, and its calibration pays for a miss).
--
-- THE GATES, before any bait: the threat under BAIT.max_threat (never
-- while Stage 2 says HIGH or CRITICAL); we are not controlled; nothing of
-- ours holds the target (the control plan's hold); the target is a player
-- in reach with no defensive up.
--
-- WHAT ACTS: one reaction, "Intel: the bait" (rules/intel.lua), presses the
-- cheap shot a mobility or a trinket bait asks for (Concussive Shot),
-- scored below the survival and escape bands. The defensive bait is a hold
-- on our burst, said here (S.bait.hold_burst) for the burst's own gate to
-- read, and advice until it does; the interrupt bait is advice only --
-- nothing here cancels a cast (the brief: never, unless the user's own
-- reaction with stop_cast does).

return function(P, lib, data, K)
    local book = P.spellbook
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KB, KP, RANK = K.BAIT, K.PREDICT, K.RANK
    local sure = lib.sure

    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    --- The module's switch (the Reactions page, *Cooldown baiting*).
    function M.enabled() return opt("intel_bait", true) == true end

    local function ready(name)
        return type(name) == "string" and book.known(name) and book.ready(name)
    end

    --- A prediction of the target's, read the one allowed way: sure, not
    --- adapting, and the bait's confidence is the rate scaled by the
    --- evidence behind it (two chances: half).
    local function predicted(f, key)
        local e = f.predict and f.predict[key] or nil
        if not e then return nil, 0 end
        local v = sure(e, KP.threshold)
        if v == nil or not e.sure or e.adapting then return nil, (e.p or 0) * (e.reliability or 0) end
        return v, (e.p or 0) * (e.reliability or 0)
    end

    local T = {
        target = nil, list = {}, hold_burst = nil, hold_why = "",
        blocked = nil, candidates = 0,
    }
    M.T = T

    local pool = {}
    local function take(i)
        local b = pool[i]
        if not b then
            b = {}
            pool[i] = b
        end
        return b
    end

    -- --- the four baits --------------------------------------------------------------

    --- Mobility: it closes the gap the moment it is slowed, and we have the
    --- counter ready (the trap with room for it, Scatter Shot, the clip).
    local function mobility(S, f, b)
        local v, conf = predicted(f, "mobility_when_slowed")
        if not v then return false end
        local tg = S.env.target
        if (tg.gap or huge) <= KB.melee_gap then return false end           -- already on us: nothing to bait
        if not ready(KB.cheap_slow) then return false end
        local counter, factor = nil, 0
        for i = 1, #KB.counters do
            local c = KB.counters[i]
            if ready(c.name) and (c.room == nil or (tg.gap or huge) >= c.room) then
                counter, factor = c.name, c.factor
                break
            end
        end
        if not counter then return false end
        b.kind, b.guid, b.name = "mobility", f.guid, f.name
        b.conf = conf * factor
        b.press, b.counter = KB.cheap_slow, counter
        b.v = string.format("bait its charge: %s with %s ready", KB.cheap_slow, counter)
        b.why = string.format("%s (%.2f); %s ready, %.0f yd between you", v, conf, counter, tg.gap or 0)
        return true
    end

    --- Defensive: hold the burst while its defensive is unseen, or known to
    --- come at a health it is about to reach; keep the pressure with the
    --- fillers until it is spent.
    local function defensive(S, f, b)
        if not S.me.power_counted or (S.me.power_pct or 1) < KB.min_power then return false end
        local burst = nil
        for name in pairs(data.OUR_BURSTS) do
            if ready(name) then burst = name break end
        end
        if not burst then return false end
        local names = f.class and data.CLASS_DEFENSIVES[f.class] or nil
        if not names or #names == 0 then return false end
        local cds = lib.cooldowns
        local unseen = {}
        for i = 1, #names do
            local seen = cds and cds.seen and cds.seen(S, f.guid, names[i]) or nil
            if not seen then unseen[#unseen + 1] = names[i] end
        end
        local thr, tconf = predicted(f, "defensive_threshold")
        local hp = f.hp or 1
        local why, conf
        if thr then
            local at = tonumber(thr:match("(%d+)%%")) or 0
            if hp * 100 > at + KB.defensive_margin * 100 then return false end      -- far above: the burst lands before it pops
            why = string.format("%s (%.2f); it is at %d%%", thr, tconf, floor(hp * 100 + 0.5))
            conf = tconf
        elseif #unseen > 0 then
            why = string.format("%s unseen this session; pressure with the fillers until it is spent", table.concat(unseen, ", "))
            conf = KB.unseen_conf
        else
            return false
        end
        b.kind, b.guid, b.name = "defensive", f.guid, f.name
        b.conf, b.hold = conf, burst
        b.v = string.format("hold %s: %s", burst, thr and "its defensive is due" or "its defensive is unseen")
        b.why = why
        return true
    end

    --- Interrupt: it interrupts your casts and is in reach to; we have the
    --- cast to show it. Advice only: nothing here cancels a cast.
    local function interrupt(S, f, b)
        local v, conf = predicted(f, "interrupts_casts")
        if not v then return false end
        if not ready(KB.cancellable_cast) then return false end
        local name = f.class and data.CLASS_INTERRUPT[f.class] or nil
        if not name then return false end
        local reach = data.INTERRUPT_REACH[name] or 5
        local tg = S.env.target
        if (tg.gap or huge) > reach then return false end
        b.kind, b.guid, b.name = "interrupt", f.guid, f.name
        b.conf = conf
        b.v = string.format("draw its %s: start %s, stop it, then the real cast", name, KB.cancellable_cast)
        b.why = string.format("%s (%.2f); %s reaches %d yd, it is at %.0f", v, conf, name, reach, tg.gap or 0)
        return true
    end

    --- Trinket: it breaks a control at once; a cheap control first draws the
    --- trinket, the real one after -- only while losing the cheap one costs
    --- nothing (the threat low, no burst up on it).
    local function trinket(S, f, b)
        local v, conf = predicted(f, "escape_after_control")
        if not v then return false end
        if f.st and f.st.trinket_down then return false end                   -- the real control goes now
        if f.st and f.st.burst then return false end
        if RANK[S.threat.level] > RANK[KB.cc_max_threat] then return false end
        if not (ready(KB.cheap_control) and ready(KB.real_control)) then return false end
        b.kind, b.guid, b.name = "cc", f.guid, f.name
        b.conf = conf
        b.press, b.counter = KB.cheap_control, KB.real_control
        b.v = string.format("draw the trinket with %s, then %s", KB.cheap_control, KB.real_control)
        b.why = string.format("%s (%.2f); its trinket not seen used, %s and %s ready", v, conf, KB.cheap_control, KB.real_control)
        return true
    end

    -- --- the tick ---------------------------------------------------------------------

    function M.update(W, S, now)
        T.target, T.hold_burst, T.hold_why, T.blocked, T.candidates = nil, nil, "", nil, 0
        for i = #T.list, 1, -1 do T.list[i] = nil end
        if not S.active then return T end
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        if not tg or tg.dead then return T end
        -- The gates.
        if RANK[S.threat.level] >= RANK[KB.max_threat] then T.blocked = "threat " .. tostring(S.threat.level) return T end
        if S.me.controlled then T.blocked = "you are controlled" return T end
        if S.cc and S.cc.hold then T.blocked = "a control on it is being kept" return T end
        if tg.st and (tg.st.immune or tg.st.avoid) then
            T.blocked = "its defensive is up (" .. tostring(tg.st.immune_name or tg.st.avoid_name) .. ")"
            return T
        end
        -- A player that changed its ways is not baited on its old ones.
        for _, e in pairs(tg.predict or {}) do
            if e.adapting then T.blocked = "it is adapting: " .. tostring(e.adapt_why) return T end
        end
        local n = 0
        for _, fn in ipairs({ mobility, defensive, interrupt, trinket }) do
            local b = take(n + 1)
            b.press, b.counter, b.hold = nil, nil, nil
            if fn(S, tg, b) then
                n = n + 1
                T.list[n] = b
            end
        end
        T.candidates = n
        table.sort(T.list, function(a, c) return a.conf > c.conf end)
        T.target = T.list[1]
        for i = 1, n do
            if T.list[i].kind == "defensive" then
                T.hold_burst, T.hold_why = T.list[i].hold, T.list[i].why
                break
            end
        end
        return T
    end

    function M.reset()
        T.target, T.hold_burst, T.hold_why, T.blocked, T.candidates = nil, nil, "", nil, 0
        for i = #T.list, 1, -1 do T.list[i] = nil end
    end

    --- The readout's piece.
    function M.line(S)
        if T.target then return string.format("bait: %s (%.2f)", T.target.v, T.target.conf) end
        if T.blocked and S.predict and S.predict.top then return "bait: none -- " .. T.blocked end
        return nil
    end

    return M
end

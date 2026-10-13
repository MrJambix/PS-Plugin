-- Jambix AIO / react / intel / predict -- opponent prediction (PvP
-- intelligence, Stage 7 / brief Phase 6; reworked on the 2026-10-12 review):
-- what a player tends to do, from what it was seen doing this session,
-- with the estimate and the evidence for it kept apart.
--
-- EVERY PATTERN IS A QUESTION WITH FOUR PARTS (data.PATTERNS):
--   the chance      when the question is asked (our slow lands, its burst
--                   starts, a fight begins...) -- and only when the player
--                   COULD answer: an ability the ledger saw go down is not
--                   a chance (skipped, counted, said);
--   the hit         what answers yes;
--   the miss        what answers no -- recorded only while the inputs a
--                   miss rests on have been seen live this session
--                   (T.inputs); without them the chance is "unverified",
--                   never a miss, because a silent feed looks like a miss;
--   the attribution who did it: observed (weight 1) or inferred (half,
--                   and the basis says so).
--
-- TWO NUMBERS, NEVER ONE. `p` is the estimated rate (hits over chances,
-- faded, blended with a prior that weighs two chances). `reliability` is
-- the evidence behind it (weighted chances over chances plus two): two
-- chances read 0.5 and are labelled LOW however high the rate. A prediction
-- is "sure" at p >= threshold with the evidence line met, and carries its
-- label everywhere. A rule reads one only through intel.sure.
--
-- TWO CLOCKS. The recent encounter (this fight with the player, the last
-- two minutes, a 60 s half-life) and the session tendency (every fight
-- with it, a 600 s half-life). The headline follows the recent when it has
-- evidence, the session otherwise; when the two disagree by a margin the
-- player is ADAPTING, said so, and the baits stand down.
--
-- FORECASTS ARE SCORED WHEN MADE. Every chance snapshots the forecast as
-- it stood (p, reliability, sure), including a weak or a wrong one, and
-- the outcome is scored against that snapshot (a Brier score, the bands,
-- the sure ones' hit count); nothing later rewrites a past forecast. A
-- sure forecast that misses moves the pattern's prior down a step, one
-- that holds moves it up half.
--
-- UNKNOWN: chasing through bad terrain (needs the walk map behind the
-- player; listed as not built); anything across sessions (nothing is
-- persisted); on Forever, every input until T.inputs has seen it.

return function(P, lib, data, K)
    local floor, max, min, huge, abs = math.floor, math.max, math.min, math.huge, math.abs
    local KP = K.PREDICT

    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    --- The module's switch (the Reactions page, *Opponent prediction*).
    function M.enabled() return opt("intel_predict", true) == true end
    --- The counting's switch (*Opponent pattern learning*): off, the counts
    --- freeze and the predictions stand as they are.
    function M.learning() return opt("intel_learn", true) == true end

    local function spell_name(id)
        if lib.spell_name then return lib.spell_name(id) end
        return nil
    end

    local PATTERNS = data.PATTERNS
    local BY_KEY = {}
    for i = 1, #PATTERNS do BY_KEY[PATTERNS[i].key] = PATTERNS[i] end
    M.PATTERNS = PATTERNS

    local BREAKER_NAMES = {}
    for _, list in pairs(data.BREAKERS) do
        for i = 1, #list do BREAKER_NAMES[list[i].name] = true end
    end

    local cds = lib.cooldowns

    -- --- the tick's table ---------------------------------------------------------------

    local T = {
        target = nil, top = nil, players = 0, observed = 0, skipped = 0, unverified = 0,
        alerts = {}, calibration = {}, ledger = {},
        -- The inputs seen live this session: a pattern's miss rests on them.
        inputs = { enemy_casts = 0, enemy_auras = 0, our_casts = 0, our_interrupted = 0,
                   control_ends = 0, foe_target = 0, motion = 0 },
        not_built = data.NOT_BUILT_PATTERNS,
    }
    M.T = T

    local function live(name) return (T.inputs[name] or 0) > 0 end

    --- Every input this pattern's miss needs has been seen this session.
    ---@return boolean ok
    ---@return string|nil why
    local function needs_live(key)
        local def = BY_KEY[key]
        local needs = def and def.needs or nil
        for i = 1, #(needs or {}) do
            local n = needs[i]
            if n == "enemy_events" then
                if not (live("enemy_casts") or live("enemy_auras")) then
                    return false, "no enemy cast or aura event seen this session"
                end
            elseif not live(n) then
                return false, "no " .. (data.INPUT_WORDS[n] or n) .. " seen this session"
            end
        end
        return true, nil
    end
    M.needs_live = needs_live

    -- --- the enemy's abilities: ready, down, estimated, unknown ---------------------

    --- What the ledger says of one of the player's abilities.
    ---@return string state "ready" (seen, back), "down" (seen, running), "estimated" (never seen, the tables have it), "unknown"
    ---@return number|nil back seconds until back, when down
    function M.availability(S, f, name)
        local seen = cds and cds.seen and cds.seen(S, f.guid, name) or nil
        if seen then
            if seen.state == "down" then return "down", seen.ready_in or 0 end
            if seen.state == "ready" then return "ready", 0 end
            return "unknown", nil
        end
        local fact = cds and cds.fact and cds.fact(name, f.class) or nil
        if fact then return "estimated", nil end
        return "unknown", nil
    end

    --- One of these abilities could be used now ("ready", "estimated" or
    --- "unknown"); false, and why, when every one is down or the class has none.
    local function any_usable(S, f, names)
        if not names or #names == 0 then return false, "its class has none" end
        local down = {}
        for i = 1, #names do
            local a, back = M.availability(S, f, names[i])
            if a ~= "down" then return true, names[i] .. " " .. a end
            down[#down + 1] = string.format("%s back in %.0fs", names[i], back or 0)
        end
        return false, table.concat(down, ", ")
    end

    -- --- per player ------------------------------------------------------------------------

    local function pat_of(f)
        local p = f.pat
        if not p then
            p = { cats = {}, scan_at = -huge, pending = {}, alerted = {}, encounter = 0,
                  last_mobility_at = -huge, last_interrupt_at = -huge, last_interrupt = nil, last_breaker_at = -huge,
                  burst_was = nil, control_was = nil, trinket_was = false,
                  pet_window = nil, pet_next = -huge, in_combat_was = f.in_combat == true,
                  openers = {}, waiting_opener = false, opener_since = -huge,
                  watching_defensive = false, defensive_fc = nil, defensive_since = -huge }
            f.pat = p
        end
        return p
    end

    local function cat_of(p, key)
        local c = p.cats[key]
        if not c then
            -- The prior: the central database's rate for this class and
            -- pattern when enough fights back it (central.lua), else 0.5.
            local prior, backing, level = KP.prior, 0, nil
            if lib.central and lib.central.prior_for and p.class then
                local cp, n, lvl = lib.central.prior_for(p.class, key)
                if cp then prior, backing, level = cp, n, lvl end
            end
            c = { events = {}, values = {}, prior = prior, prior_fights = backing, prior_level = level, hits = 0, total = 0, skipped = 0, unverified = 0,
                  skip_why = nil, unverified_why = nil,
                  recent = { hw = 0, mw = 0, n = 0, p = KP.prior }, earlier = { hw = 0, mw = 0, n = 0, p = KP.prior },
                  session = { hw = 0, mw = 0, n = 0, p = KP.prior },
                  p = KP.prior, n = 0, reliability = 0, label = "none", basis = "none", sure = false,
                  adapting = false, adapt_why = nil, last_at = -huge }
            p.cats[key] = c
        end
        return c
    end

    local function label_of(rel)
        local bands = KP.reliability_bands
        for i = 1, #bands do
            if rel < bands[i].below then return bands[i].label end
        end
        return bands[#bands].label
    end

    --- The forecast as it stands, snapshotted when a chance opens.
    local function forecast(c)
        if not c then return { p = KP.prior, rel = 0, sure = false, n = 0 } end
        return { p = c.p, rel = c.reliability, sure = c.sure, n = c.n }
    end

    local S_now = nil           -- the picture, for the context an observation carries

    --- The outcome scored against the forecast made when the chance opened.
    local function score_forecast(key, fc, hit, c, f)
        local L = T.ledger[key]
        if not L then
            L = { forecasts = 0, brier = 0, right = 0,
                  bands = { low = { n = 0, hits = 0 }, mid = { n = 0, hits = 0 }, high = { n = 0, hits = 0 } } }
            T.ledger[key] = L
        end
        local y = hit and 1 or 0
        L.forecasts = L.forecasts + 1
        L.brier = L.brier + (fc.p - y) ^ 2
        local band = fc.p < KP.band_low and "low" or fc.p < KP.threshold and "mid" or "high"
        L.bands[band].n = L.bands[band].n + 1
        if hit then L.bands[band].hits = L.bands[band].hits + 1 end
        if (fc.p >= 0.5) == hit then L.right = L.right + 1 end
        -- The network's observation: the forecast as it stood, the outcome,
        -- what it rested on (central.lua keeps it for the fight's batch).
        if lib.central and lib.central.observe then
            local S = S_now
            local ok, data_why = needs_live(key)
            local fight = lib.debrief and lib.debrief.T and lib.debrief.T.fight or nil
            lib.central.observe({
                pattern = key, enemy_class = f and f.class or "?", p = fc.p, reliability = fc.rel, sure = fc.sure,
                basis = c.basis, evidence = fc.n, inputs_ok = ok, hit = hit,
                t = fight and (S and S.now or 0) - fight.started_at or nil,
                context = { mode = S and S.mode and S.mode.kind or nil, threat = S and S.threat and S.threat.level or nil,
                            me_hp = S and S.me and S.me.hp or nil, controlled = S and S.me and S.me.controlled or false },
            })
        end
        if fc.sure then
            local cal = T.calibration[key]
            if not cal then
                cal = { predicted = 0, right = 0 }
                T.calibration[key] = cal
            end
            cal.predicted = cal.predicted + 1
            if hit then
                cal.right = cal.right + 1
                c.prior = min(KP.prior_max, c.prior + KP.prior_step / 2)
            else
                c.prior = max(KP.prior_min, c.prior - KP.prior_step)
            end
        end
    end

    --- A chance skipped: the player could not answer (the ability down,
    --- the class without it). Counted and said, never scored.
    local function skip(f, key, why)
        local c = cat_of(pat_of(f), key)
        c.skipped, c.skip_why = c.skipped + 1, why
        T.skipped = T.skipped + 1
    end

    --- A chance that cannot be scored as a miss: the input a miss rests on
    --- has not been seen this session. Counted and said.
    local function unverified(f, key, why)
        local c = cat_of(pat_of(f), key)
        c.unverified, c.unverified_why = c.unverified + 1, why
        T.unverified = T.unverified + 1
    end

    --- One observation. `hit` yes or no; `w` 1 observed, less inferred;
    --- `fc` the forecast the chance opened with (nil: a measurement with no
    --- forecast, such as the health a defensive appeared at).
    local function observe(f, key, hit, at, w, value, fc, why)
        if not M.learning() then return end
        local p = pat_of(f)
        local c = cat_of(p, key)
        if not hit then
            local ok, miss_why = needs_live(key)
            if not ok then
                c.unverified, c.unverified_why = c.unverified + 1, miss_why
                T.unverified = T.unverified + 1
                return
            end
        end
        local ev = c.events
        ev[#ev + 1] = { at = at, hit = hit, w = w or 1, why = why, enc = p.encounter }
        while #ev > KP.keep do table.remove(ev, 1) end
        if value ~= nil then
            c.values[#c.values + 1] = value
            while #c.values > KP.keep do table.remove(c.values, 1) end
        end
        c.total = c.total + 1
        if hit then c.hits = c.hits + 1 end
        c.last_at = at
        if fc then score_forecast(key, fc, hit, c, f) end
        T.observed = T.observed + 1
    end

    --- The two clocks, the estimate and the evidence.
    local function weigh(p, c, now)
        local R, E, Sn = c.recent, c.earlier, c.session
        R.hw, R.mw, E.hw, E.mw, Sn.hw, Sn.mw = 0, 0, 0, 0, 0, 0
        for i = 1, #c.events do
            local e = c.events[i]
            local age = max(0, now - e.at)
            local ws = e.w * 0.5 ^ (age / KP.half_life_session)
            if e.hit then Sn.hw = Sn.hw + ws else Sn.mw = Sn.mw + ws end
            if e.enc == p.encounter and age <= KP.recent_window then
                local wr = e.w * 0.5 ^ (age / KP.half_life_recent)
                if e.hit then R.hw = R.hw + wr else R.mw = R.mw + wr end
            else
                if e.hit then E.hw = E.hw + ws else E.mw = E.mw + ws end
            end
        end
        local function rate(hw, n) return (hw + KP.prior_weight * c.prior) / (n + KP.prior_weight) end
        R.n, E.n, Sn.n = R.hw + R.mw, E.hw + E.mw, Sn.hw + Sn.mw
        R.p, E.p, Sn.p = rate(R.hw, R.n), rate(E.hw, E.n), rate(Sn.hw, Sn.n)
        if R.n >= KP.min_samples then
            c.p, c.n, c.basis = R.p, R.n, "recent"
        else
            c.p, c.n, c.basis = Sn.p, Sn.n, "session"
        end
        c.reliability = c.n / (c.n + KP.evidence_k)
        c.label = c.n > 0 and label_of(c.reliability) or "none"
        c.sure = c.n >= KP.min_samples and c.p >= KP.threshold
        c.adapting, c.adapt_why = false, nil
        if R.n >= KP.adapt_min_recent and E.n >= KP.adapt_min_earlier and abs(R.p - E.p) >= KP.adapt_gap then
            c.adapting = true
            c.adapt_why = string.format("earlier %.2f over %.1f chance(s), now %.2f over %.1f: it changed",
                E.p, E.n, R.p, R.n)
        end
    end

    local function mean(values)
        if #values == 0 then return nil end
        local s = 0
        for i = 1, #values do s = s + values[i] end
        return s / #values
    end

    -- --- the chances, from the player's events ------------------------------------------

    local function scan_recent(S, f, p, now)
        local list = f.recent or {}
        local newest = p.scan_at
        for i = 1, #list do
            local row = list[i]
            if row.at > p.scan_at then
                local name, kind = row.name, row.kind
                if kind == "buff" or kind == "debuff" then
                    T.inputs.enemy_auras = T.inputs.enemy_auras + 1
                else
                    T.inputs.enemy_casts = T.inputs.enemy_casts + 1
                end
                if (kind == "cast" or kind == "start" or kind == "channel" or kind == "buff") and data.MOBILITY[name] then
                    p.last_mobility_at = row.at
                end
                if kind == "buff" then
                    local cover = data.PROTECTION[name]
                    if cover and cover ~= "fear" then
                        local hp = f.hp or 1
                        -- The defensive seen: its health is the threshold's
                        -- measure; the episode under watch (if any) is a hit
                        -- against the forecast it opened with.
                        observe(f, "defensive_threshold", true, row.at, 1, hp, p.watching_defensive and p.defensive_fc or nil, name)
                        p.watching_defensive, p.defensive_fc = false, nil
                        observe(f, "saving_cooldowns_until_low", hp <= KP.defensive_low, row.at, 1, nil, nil,
                            string.format("%s at %d%%", name, floor(hp * 100 + 0.5)))
                    end
                end
                if kind == "cast" and data.INTERRUPTS[name] then
                    p.last_interrupt_at, p.last_interrupt = row.at, name
                end
                if kind == "cast" and BREAKER_NAMES[name] then p.last_breaker_at = row.at end
                if p.waiting_opener and kind == "cast" and row.at >= p.opener_since then
                    local same = false
                    for k = 1, #p.openers do if p.openers[k] == name then same = true end end
                    if #p.openers > 0 then
                        observe(f, "same_opener", same, row.at, 1, name, p.pending.opener, name)
                    end
                    p.openers[#p.openers + 1] = name
                    while #p.openers > KP.keep do table.remove(p.openers, 1) end
                    p.waiting_opener, p.pending.opener = false, nil
                end
            end
            if row.at > newest then newest = row.at end
        end
        p.scan_at = newest
    end

    --- A burst starts: the chance for a second within the window; the
    --- window passing quietly is the miss (resolved here, not at the next burst).
    local function read_bursts(f, p, now)
        local b = f.st and f.st.burst_name or nil
        if b and b ~= p.burst_was then
            local pend = p.pending.burst_stack
            if pend then
                observe(f, "over_committing", true, now, 1, nil, pend.fc,
                    string.format("%s %.0fs after %s", b, now - pend.at, pend.name))
            end
            p.pending.burst_stack = { at = now, name = b, fc = forecast(p.cats.over_committing) }
        end
        p.burst_was = b
        local pend = p.pending.burst_stack
        if pend and (now - pend.at) > KP.burst_window then
            observe(f, "over_committing", false, now, 1, nil, pend.fc, "nothing stacked on " .. pend.name)
            p.pending.burst_stack = nil
        end
    end

    --- Our control lands: the chance to escape it -- a trinket (polled off
    --- its auras) or a breaker (a cast event), while either is usable.
    local function read_control(S, f, p, now)
        local h = f.cc and f.cc.held or nil
        local ours = h ~= nil and h.ours ~= "no" and h.breaks
        if ours and h.name ~= p.control_was then
            local trinket_up = not (f.st and f.st.trinket_down)
            local breakers = f.class and data.BREAKERS[f.class] or nil
            local names = {}
            for i = 1, #(breakers or {}) do names[i] = breakers[i].name end
            local usable, why = any_usable(S, f, names)
            if trinket_up or usable then
                p.pending.escape = { at = now, name = h.name, fc = forecast(p.cats.escape_after_control),
                                     breaker_path = usable }
            else
                skip(f, "escape_after_control", "its trinket is down and " .. why)
            end
        end
        if p.control_was and not (ours and h) then T.inputs.control_ends = T.inputs.control_ends + 1 end
        p.control_was = ours and h.name or nil
        local pend = p.pending.escape
        if pend then
            local trinket = f.st ~= nil and f.st.trinket_down == true and not p.trinket_was
            if trinket or p.last_breaker_at >= pend.at then
                observe(f, "escape_after_control", true, now, 1, nil, pend.fc,
                    trinket and ("the trinket after " .. pend.name) or ("a breaker after " .. pend.name))
                p.pending.escape = nil
            elseif (now - pend.at) > KP.control_window then
                -- A miss by the breaker path rests on cast events; the
                -- trinket path is polled and always live.
                if pend.breaker_path and not live("enemy_casts") then
                    unverified(f, "escape_after_control", "no enemy cast event seen this session (a breaker would be one)")
                else
                    observe(f, "escape_after_control", false, now, 1, nil, pend.fc, pend.name .. " held")
                end
                p.pending.escape = nil
            end
        end
        p.trinket_was = f.st ~= nil and f.st.trinket_down == true
    end

    --- Does it go for the pet: ONE chance per window of pet_window seconds
    --- in combat with your pet out, opened the first time its target is read
    --- (you or the pet; an ally opens nothing), with the forecast as it stood
    --- then. The hit: it targets the pet within the window (the next window
    --- opens pet_window later). The miss: the window ends with it on you.
    --- A window it leaves the picture in (no read for pet_gap) or that the
    --- fight ends early closes with no answer. Live on 2026-10-12 a sample a
    --- second made 60 of a session's 80 checks this one pattern, and a fight
    --- where a rogue simply stayed on you counted 40 times.
    local function read_pet(S, f, p, now)
        local w = p.pet_window
        if w and (now - w.last) > KP.pet_gap then p.pet_window, w = nil, nil end
        if not (S.pet.alive and f.in_combat) then
            if w and w.on_me and (now - w.opened) >= KP.pet_window * 0.5 then
                observe(f, "targeting_pet", false, now, 1, nil, w.fc, "it stayed on you")
            end
            p.pet_window = nil
            return
        end
        if not w then
            if now < (p.pet_next or -huge) then return end
            if not (f.targets_pet or f.targets_me) then return end
            w = { opened = now, last = now, on_me = false, fc = forecast(p.cats.targeting_pet) }
            p.pet_window = w
        end
        w.last = now
        if f.targets_pet then
            observe(f, "targeting_pet", true, now, 1, nil, w.fc, "on the pet")
            p.pet_window, p.pet_next = nil, now + KP.pet_window
            return
        end
        if f.targets_me then w.on_me = true end
        if (now - w.opened) >= KP.pet_window then
            if w.on_me then observe(f, "targeting_pet", false, now, 1, nil, w.fc, "on you through the window") end
            p.pet_window = nil
        end
    end

    --- A fight with the player begins: a new encounter, and the chance to
    --- see its opener (within the window; none seen is no answer).
    local function read_encounter(f, p, now)
        if f.in_combat and not p.in_combat_was then
            p.encounter = p.encounter + 1
            p.waiting_opener, p.opener_since = true, now
            p.pending.opener = #p.openers > 0 and forecast(p.cats.same_opener) or nil
        end
        if p.waiting_opener and (now - p.opener_since) > KP.opener_window then
            if #p.openers > 0 then unverified(f, "same_opener", "no cast seen within the opening window") end
            p.waiting_opener, p.pending.opener = false, nil
        end
        p.in_combat_was = f.in_combat == true
    end

    --- The defensive episode: the player under pressure (its health below
    --- the watch line in combat, a defensive of its class usable) will pop
    --- one, or fall to the floor without.
    local function read_defensive(S, f, p, now)
        local hp = f.hp or 1
        if not p.watching_defensive then
            if f.in_combat and hp <= KP.defensive_watch and hp > KP.defensive_floor then
                local usable, why = any_usable(S, f, f.class and data.CLASS_DEFENSIVES[f.class] or nil)
                if usable then
                    p.watching_defensive, p.defensive_since = true, now
                    p.defensive_fc = forecast(p.cats.defensive_threshold)
                else
                    -- Said once per fall below the line.
                    if not p.defensive_skipped_at or (now - p.defensive_skipped_at) > 30 then
                        skip(f, "defensive_threshold", why)
                        p.defensive_skipped_at = now
                    end
                end
            end
        elseif hp <= KP.defensive_floor or f.dead or not f.in_combat then
            observe(f, "defensive_threshold", false, now, 1, nil, p.defensive_fc,
                f.dead and "died without one" or (not f.in_combat and "the fight ended without one") or "under the floor without one")
            p.watching_defensive, p.defensive_fc = false, nil
        end
    end

    local function resolve_ours(f, p, now)
        local slow = p.pending.slow
        if slow then
            if p.last_mobility_at > slow.at and p.last_mobility_at <= slow.at + KP.slow_window then
                observe(f, "mobility_when_slowed", true, p.last_mobility_at, 1, nil, slow.fc,
                    string.format("a gap closer %.1fs after %s", p.last_mobility_at - slow.at, slow.name))
                p.pending.slow = nil
            elseif (now - slow.at) > KP.slow_window then
                observe(f, "mobility_when_slowed", false, now, 1, nil, slow.fc, "nothing after " .. slow.name)
                p.pending.slow = nil
            end
        end
        local burst = p.pending.burst
        if burst then
            if (f.closing or 0) < -KP.retreat_speed then
                observe(f, "retreating_when_pressured", true, now, 1, nil, burst.fc,
                    string.format("opening the distance %.1fs after %s", now - burst.at, burst.name))
                p.pending.burst = nil
            elseif (now - burst.at) > KP.retreat_window then
                observe(f, "retreating_when_pressured", false, now, 1, nil, burst.fc, "stayed through " .. burst.name)
                p.pending.burst = nil
            end
        end
    end

    -- --- our own casts (init.lua hands them over) ----------------------------------

    --- A player within its interrupt's reach of us, the interrupt usable:
    --- the one our cast is a chance for.
    local function can_interrupt(S, f)
        local name = f.class and data.CLASS_INTERRUPT[f.class] or nil
        if not name then return false, "its class has no interrupt" end
        local reach = data.INTERRUPT_REACH[name] or 5
        if (f.dist or huge) > reach then return false, name .. " out of reach" end
        local a, back = M.availability(S, f, name)
        if a == "down" then return false, string.format("%s back in %.0fs", name, back or 0) end
        return true, name
    end

    --- Our cast went off (UNIT_SPELLCAST_SUCCEEDED for "player"): a slow or
    --- a burst opens a chance for the target's pattern; a cast with a cast
    --- time that went through is a miss for every player that could have
    --- interrupted it.
    function M.on_our_cast(S, spell_id, target_guid, now)
        if not M.enabled() then return end
        S_now = S
        T.inputs.our_casts = T.inputs.our_casts + 1
        local name = spell_name(tonumber(spell_id))
        if not name then return end
        local f = target_guid and S.foes[target_guid] or nil
        if f then
            local p = pat_of(f)
            p.class = f.class
            if data.OUR_SLOW_CASTS[name] then
                local closers = f.class and data.CLASS_GAP_CLOSERS[f.class] or nil
                local usable, why = any_usable(S, f, closers)
                if usable then
                    p.pending.slow = { at = now, name = name, fc = forecast(p.cats.mobility_when_slowed) }
                else
                    skip(f, "mobility_when_slowed", why)
                end
            elseif data.OUR_BURSTS[name] then
                if live("motion") then
                    p.pending.burst = { at = now, name = name, fc = forecast(p.cats.retreating_when_pressured) }
                else
                    unverified(f, "retreating_when_pressured", "no player movement read this session")
                end
            end
        end
        if data.OUR_CASTS[name] then
            for _, o in pairs(S.foes) do
                if not o.dead then
                    local ok = can_interrupt(S, o)
                    if ok then
                        observe(o, "interrupts_casts", false, now, 1, nil, forecast(pat_of(o).cats.interrupts_casts),
                            name .. " went through")
                    end
                end
            end
        end
    end

    --- Our cast was interrupted (UNIT_SPELLCAST_INTERRUPTED for "player"):
    --- the player seen casting an interrupt just now did it; none seen, the
    --- player on us in reach is the likely one, at half weight.
    function M.on_our_interrupted(S, spell_id, now)
        if not M.enabled() then return end
        S_now = S
        T.inputs.our_interrupted = T.inputs.our_interrupted + 1
        local who, observed = nil, false
        for _, f in pairs(S.foes) do
            local p = f.pat
            if p and (now - p.last_interrupt_at) <= KP.interrupt_window then
                if not who or p.last_interrupt_at > who.pat.last_interrupt_at then who = f end
                observed = true
            end
        end
        if not who then
            local best = huge
            for _, f in pairs(S.foes) do
                if f.targets_me and not f.dead and (f.dist or huge) < best and can_interrupt(S, f) then
                    who, best = f, f.dist or huge
                end
            end
        end
        if not who then return end
        local name = spell_name(tonumber(spell_id)) or "your cast"
        local fc = forecast(pat_of(who).cats.interrupts_casts)
        if observed then
            observe(who, "interrupts_casts", true, now, 1, nil, fc,
                string.format("%s on %s", who.pat.last_interrupt or "an interrupt", name))
        else
            observe(who, "interrupts_casts", true, now, KP.inferred_weight, nil, fc,
                string.format("%s interrupted, no kick seen: the player on you, inferred", name))
        end
    end

    -- --- the predictions ----------------------------------------------------------------

    local function consequence(key, c)
        local def = BY_KEY[key]
        if not def then return key end
        if key == "defensive_threshold" then
            local m = mean(c.values)
            return string.format(def.consequence, floor((m or 0) * 100 + 0.5))
        elseif key == "same_opener" then
            return string.format(def.consequence, tostring(c.values[#c.values] or "?"))
        end
        return def.consequence
    end

    local function build(f, p, now)
        local out = f.predict
        if not out then
            out = {}
            f.predict = out
        end
        for key in pairs(out) do if not p.cats[key] then out[key] = nil end end
        local top = nil
        for key, c in pairs(p.cats) do
            weigh(p, c, now)
            if c.n > 0 or c.skipped > 0 or c.unverified > 0 then
                local e = out[key] or {}
                out[key] = e
                local def = BY_KEY[key] or {}
                e.category, e.v = key, consequence(key, c)
                e.p, e.conf, e.reliability, e.label = c.p, c.p, c.reliability, c.label
                e.samples, e.n, e.hits, e.total, e.prior, e.basis = c.n, c.n, c.hits, c.total, c.prior, c.basis
                e.recent_p, e.recent_n, e.session_p, e.session_n = c.recent.p, c.recent.n, c.session.p, c.session.n
                e.skipped, e.skip_why, e.unverified, e.unverified_why = c.skipped, c.skip_why, c.unverified, c.unverified_why
                e.adapting, e.adapt_why = c.adapting, c.adapt_why
                e.sure = c.sure and c.n > 0
                local data_ok, data_why = needs_live(key)
                e.data = data_ok and "ok" or ("unverified: " .. tostring(data_why))
                e.prior_fights = c.prior_fights
                e.why = string.format("%d of %d chance(s) this session (%s: %.1f for, %.1f against; reliability %s; prior %.2f%s)%s%s",
                    c.hits, c.total, c.basis,
                    c.basis == "recent" and c.recent.hw or c.session.hw, c.basis == "recent" and c.recent.mw or c.session.mw,
                    c.label, c.prior, (c.prior_fights or 0) > 0 and string.format(", the database's over %d fights%s", c.prior_fights,
                        c.prior_level and (" at the " .. tostring(c.prior_level) .. " level") or "") or "",
                    c.skipped > 0 and string.format("; %d skipped: %s", c.skipped, tostring(c.skip_why)) or "",
                    c.unverified > 0 and string.format("; %d unverified: %s", c.unverified, tostring(c.unverified_why)) or "")
                e.response, e.fallback = def.response, def.fallback
                e.ledger = T.ledger[key]
                if e.sure and not e.adapting and not (top and top.p >= e.p) then top = e end
                if e.sure and not e.adapting and not p.alerted[key] then
                    p.alerted[key] = true
                    T.alerts[#T.alerts + 1] = { guid = f.guid, name = f.name, key = key, text = e.v, conf = e.p,
                                                label = e.label, n = e.n }
                    while #T.alerts > KP.keep do table.remove(T.alerts, 1) end
                elseif not e.sure then
                    p.alerted[key] = nil
                end
            else
                out[key] = nil
            end
        end
        return top
    end

    function M.update(W, S, now)
        S_now = S
        T.target, T.top, T.players = nil, nil, 0
        if not S.active then return T end
        local tg_guid = S.env.target.guid
        local any_target, any_motion = false, false
        for _, f in pairs(S.foes) do
            if f.targets_me or f.targets_pet then any_target = true end
            if (f.closing or 0) ~= 0 or f.moving then any_motion = true end
        end
        if any_target then T.inputs.foe_target = T.inputs.foe_target + 1 end
        if any_motion then T.inputs.motion = T.inputs.motion + 1 end
        for _, f in pairs(S.foes) do
            local p = pat_of(f)
            p.class = f.class
            read_encounter(f, p, now)
            scan_recent(S, f, p, now)
            resolve_ours(f, p, now)
            read_bursts(f, p, now)
            read_control(S, f, p, now)
            read_pet(S, f, p, now)
            read_defensive(S, f, p, now)
            local top = build(f, p, now)
            if next(p.cats) then T.players = T.players + 1 end
            if f.guid == tg_guid then T.target, T.top = f.predict, top end
        end
        return T
    end

    --- A prediction's estimated rate for a player (0 when none).
    function M.confidence(S, guid, key)
        local f = guid and S and S.foes and S.foes[guid] or nil
        local e = f and f.predict and f.predict[key] or nil
        return e and e.p or 0
    end

    --- The evidence behind it, 0 to 1 (0 when none).
    function M.reliability(S, guid, key)
        local f = guid and S and S.foes and S.foes[guid] or nil
        local e = f and f.predict and f.predict[key] or nil
        return e and e.reliability or 0
    end

    --- The player's surest pattern that is not adapting, and its rate:
    --- "none", 0 when nothing is sure.
    function M.pattern(S, guid)
        local f = guid and S and S.foes and S.foes[guid] or nil
        local best, p = "none", 0
        if f and f.predict then
            for key, e in pairs(f.predict) do
                if e.sure and not e.adapting and e.p > p then best, p = key, e.p end
            end
            if best == "none" then
                for _, e in pairs(f.predict) do
                    if e.p > p then p = e.p end
                end
            end
        end
        return best, p
    end

    --- The inputs seen this session, in words.
    function M.inputs_text()
        local I = T.inputs
        local function w(n, k) return string.format("%s %d%s", n, I[k], I[k] > 0 and "" or " (unverified)") end
        return table.concat({ w("casts", "enemy_casts"), w("auras", "enemy_auras"), w("interrupted", "our_interrupted"),
                              w("control ends", "control_ends"), w("targets", "foe_target"), w("motion", "motion") }, ", ")
    end

    function M.reset()
        for i = #T.alerts, 1, -1 do T.alerts[i] = nil end
        for k in pairs(T.calibration) do T.calibration[k] = nil end
        for k in pairs(T.ledger) do T.ledger[k] = nil end
        for k in pairs(T.inputs) do T.inputs[k] = 0 end
        T.target, T.top, T.players, T.observed, T.skipped, T.unverified = nil, nil, 0, 0, 0, 0
    end

    --- The readout's piece.
    function M.line(S)
        if not T.target then return nil end
        if T.top then
            return string.format("predict: %s (p %.2f, reliability %s, n%.1f)", T.top.v, T.top.p, T.top.label, T.top.n)
        end
        local adapting, forming, fp = nil, nil, 0
        for key, e in pairs(T.target) do
            if e.adapting then adapting = e end
            if e.p > fp and e.n > 0 then forming, fp = key, e.p end
        end
        if adapting then return "predict: adapting -- " .. tostring(adapting.adapt_why) end
        if forming and fp >= KP.forming_show then return string.format("predict: forming (%s p %.2f)", forming, fp) end
        return nil
    end

    return M
end

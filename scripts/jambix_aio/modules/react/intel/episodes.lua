-- Jambix AIO / react / intel / episodes -- the decision episodes (the brief
-- "PvP Combat Experience & Lessons Learned Collector", 2026-10-12): a
-- bounded window around a tactical opportunity, with the state before,
-- what happened during, the state after, and what was said and done --
-- so that a fight becomes training records a reader can check, not
-- damage numbers.
--
-- AN EPISODE ANSWERS THE BRIEF'S TEN QUESTIONS, EACH FROM A NAMED SOURCE:
--   1 the situation      `before`: a snapshot of you, the player, the threat
--   2 the behaviour      `trigger`: the event that opened it, with its source
--                        (an event, a row, an inference) and whether observed
--   3 the prediction     the tied pattern's entry as it stood (rate,
--                        evidence, sure, inputs) -- or none
--   4 the recommendation the tactical state's first action, the move, the
--                        bait, the hold, as they stood
--   5 what you did       your casts in the window with their targets, and
--                        whether you moved -- "unknown" where nothing is readable
--   6 what came next     `events` (bounded) and `after`
--   7 the prediction's outcome   HIT / MISS / CENSORED / INVALID / NONE
--   8 the recommendation's      FOLLOWED / NOT_FOLLOWED / UNKNOWN, by a rule
--                        per kind of recommendation (a spell cast or not; a
--                        move seen or not; a hold kept or not; else UNKNOWN)
--   9 the result         one of the measurable categories (score.lua
--                        EPISODES says the exact rule for each), the primary
--                        and every one that applies; UNKNOWN when the window
--                        was cut or the inputs were not live
--  10 the lesson         a candidate, worded from the type and the result,
--                        with a confidence from how many comparable
--                        episodes this session said the same -- never a
--                        rule from one anecdote, never causation claimed.
--
-- CONTAMINATION: a duplicate trigger (same type, same player, within the
-- dedupe window) opens nothing and is counted; a trigger that was inferred
-- flags `unattributed`; a tied pattern whose inputs were never seen live
-- makes the prediction INVALID and flags `feeds_missing`; a window cut
-- short (the player gone, you dead, the fight over) is CENSORED and the
-- result UNKNOWN; a result that would rest on inferred data flags
-- `guess_only` and reads UNKNOWN; under the test harness every episode
-- carries `test_data` and the network client refuses to queue it.

return function(P, lib, data, K)
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KE, RANK = K.EPISODES, K.RANK
    local book = P.spellbook

    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end
    function M.enabled() return opt("intel_episodes", true) == true end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end
    local function sure(x, th)
        if type(x) ~= "table" or x.v == nil then return nil end
        if (x.conf or 0) < (th or 0) then return nil end
        return x.v
    end
    -- The ids come from the layer's seeded generator (intel/init.lua
    -- lib.random_hex): an unseeded one would give every player the same.
    local function random_hex(n)
        if lib.random_hex then return lib.random_hex(n) end
        local t = {}
        for i = 1, n do t[i] = string.format("%x", math.random(0, 15)) end
        return table.concat(t)
    end

    --- Under the test harness, unless the context says a test may upload.
    function M.test_data()
        local ctx = P.ctx
        if ctx and ctx.test_data == true then return true end
        -- A plain global read: the game's sandbox promises neither _G nor rawget.
        if jtest ~= nil then return not (ctx and ctx.allow_test_upload == true) end
        return false
    end

    local TYPES = data.EPISODE_TYPES
    local BY_KEY = {}
    for i = 1, #TYPES do BY_KEY[TYPES[i].key] = TYPES[i] end
    M.TYPES = TYPES

    local T = {
        open = {}, closed = {}, count = 0, by_type = {}, last = nil,
        dropped_dup = 0, dropped_full = 0, dropped_outside = 0, comparable = {},
        fight_start = nil,
    }
    M.T = T

    -- --- snapshots ------------------------------------------------------------------------

    local function ready_count(S, set)
        local n = 0
        for i = 1, #(S.me.abilities[set] or {}) do
            if S.me.abilities[set][i].ready then n = n + 1 end
        end
        return n
    end

    -- The threat as the previous tick read it: the trigger's own event
    -- raises the threat in the tick it is seen (a gap closer, a burst), and
    -- "before" means before the behaviour, not with it.
    local prev_threat = { level = "INFORMATIONAL", score = 0 }

    local function snapshot(S, foe, before)
        local me, env = S.me, S.env
        local threat = before and prev_threat or (S.threat or prev_threat)
        local snap = {
            hp = me.hp or 1, power_pct = me.power_pct, controlled = me.controlled == true,
            rooted = me.root ~= nil, snared = me.snare ~= nil, moving = me.moving == true,
            zone = env.target.zone, gap = env.target.gap, flag = me.flag == true,
            defensives_ready = ready_count(S, "defensives"), escapes_ready = ready_count(S, "escapes"),
            controls_ready = ready_count(S, "controls"), slows_ready = ready_count(S, "slows"),
            threat = threat.level or "INFORMATIONAL", threat_score = threat.score or 0,
            attackers = S.attackers or 0, melee_attackers = S.melee_attackers or 0,
            state = S.tactic and S.tactic.state or "NONE", move = S.pos and S.pos.advice or "none",
            bait = S.bait and S.bait.target and S.bait.target.kind or nil,
            hold = S.cc and S.cc.hold ~= nil, pet_recall = S.cc and S.cc.pet and S.cc.pet.recall == true,
        }
        if foe then
            local h = foe.cc and foe.cc.held or nil
            snap.foe = { hp = foe.hp or 1, dist = foe.dist, on_me = foe.targets_me == true, in_combat = foe.in_combat == true,
                         burst = foe.st and foe.st.burst_name or nil, immune = foe.st and foe.st.immune_name or nil,
                         avoid = foe.st and foe.st.avoid_name or nil, control = foe.control and foe.control.name or nil,
                         held_ours = h and h.ours ~= "no" and h.breaks and h.name or nil,
                         trinket_down = foe.st ~= nil and foe.st.trinket_down == true }
        end
        return snap
    end

    local function prediction_of(S, foe, def, pattern)
        pattern = pattern or def.pattern
        if not (pattern and foe and foe.predict and foe.predict[pattern]) then
            return { pattern = pattern, p = nil, reliability = 0, sure = false, n = 0, basis = "none", data = "ok", text = "none" }
        end
        local e = foe.predict[pattern]
        return { pattern = pattern, p = e.p, reliability = e.reliability, sure = e.sure == true, n = e.n or 0,
                 basis = e.basis, data = e.data or "ok", adapting = e.adapting == true, text = e.v,
                 threshold = pattern == "defensive_threshold" and tonumber((e.v or ""):match("(%d+)%%")) or nil }
    end

    -- --- the comparable count: the confidence of a lesson candidate ----------------------

    local function comparable_key(e) return e.type .. "|" .. tostring(e.enemy_class) end

    local function note_comparable(e)
        local c = T.comparable[comparable_key(e)]
        if not c then
            c = { n = 0, results = {}, followed = 0 }
            T.comparable[comparable_key(e)] = c
        end
        c.n = c.n + 1
        if e.result.primary ~= "UNKNOWN" then c.results[e.result.primary] = (c.results[e.result.primary] or 0) + 1 end
        if e.recommendation.outcome == "FOLLOWED" then c.followed = c.followed + 1 end
        return c
    end

    local function confidence_of(c, e)
        local n = c.n
        local same = c.results[e.result.primary] or 0
        local agree = n > 0 and same / n or 0
        local KC = KE.confidence
        if e.result.primary == "UNKNOWN" then return "none" end
        if n < KC.low_below then return "candidate" end
        if agree < KC.agree then return "contested" end
        if n < KC.moderate_below then return "low" end
        if n < KC.high_below then return "moderate" end
        return "high"
    end

    -- --- the outcome rules ------------------------------------------------------------------

    local SPELL_WORDS = { "Wing Clip", "Concussive Shot", "Scatter Shot", "Intimidation", "Feign Death", "Deterrence", "Freezing Trap",
                          "Aimed Shot", "Arcane Shot", "Multi-Shot", "Serpent Sting", "Rapid Fire", "Hunter's Mark", "Aspect of the Monkey",
                          "Aspect of the Hawk", "Mend Pet", "Auto Shot", "Summon Hawk", "Bestial Wrath" }
    local MOVE_WORDS = { "step out", "walk", "keep the distance", "break line of sight", "run to allies", "line of sight" }

    local function spell_in(text)
        for i = 1, #SPELL_WORDS do
            if text:sub(1, #SPELL_WORDS[i]) == SPELL_WORDS[i] then return SPELL_WORDS[i] end
        end
        return nil
    end
    local function move_in(text)
        for i = 1, #MOVE_WORDS do
            if text:find(MOVE_WORDS[i], 1, true) then return true end
        end
        return false
    end

    local function cast_in(e, name, target_guid)
        for i = 1, #e.actions do
            local a = e.actions[i]
            if a.name == name and (target_guid == nil or a.target == target_guid) then return true end
        end
        return false
    end
    local function any_cast_at(e, guid)
        for i = 1, #e.actions do if e.actions[i].target == guid and e.actions[i].damage then return true end end
        return false
    end
    local function any_cast_not_at(e, guid)
        for i = 1, #e.actions do if e.actions[i].target and e.actions[i].target ~= guid then return true end end
        return false
    end

    --- Was the recommendation followed? A rule per kind; UNKNOWN where
    --- nothing readable says.
    local function judge_recommendation(e)
        local r = e.recommendation
        local text = r.action or ""
        if r.bait and r.bait_press and cast_in(e, r.bait_press) then return "FOLLOWED", "the bait's " .. r.bait_press .. " was cast" end
        local spell = spell_in(text)
        if spell then
            if cast_in(e, spell) then return "FOLLOWED", spell .. " was cast" end
            if e.ready_at_open[spell] then return "NOT_FOLLOWED", spell .. " was ready and not cast" end
            return "UNKNOWN", spell .. " was not ready (or not known): nothing to follow"
        end
        if text == "no damage on it" or r.hold then
            if any_cast_at(e, e.foe) then return "NOT_FOLLOWED", "a damaging cast went at the held player" end
            return "FOLLOWED", "nothing damaging went at the held player"
        end
        if text == "shoot another" then
            if any_cast_not_at(e, e.foe) then return "FOLLOWED", "a cast went at another" end
            if #e.actions > 0 then return "NOT_FOLLOWED", "every cast went at it" end
            return "UNKNOWN", "no cast in the window"
        end
        if move_in(text) or r.move == "increase" or r.move == "break_los" or r.move == "regain_los" then
            if not e.motion_live then return "UNKNOWN", "your movement is not read" end
            local gain = (e.after.gap or 0) - (e.before.gap or 0)
            if e.moved and gain >= KE.gap_improved then return "FOLLOWED", string.format("you moved and the gap grew %.0f yd", gain) end
            if e.moved then return "NOT_FOLLOWED", string.format("you moved but the gap changed %.0f yd", gain) end
            return "NOT_FOLLOWED", "you did not move"
        end
        if r.move == "hold" and text == "" then
            if e.moved then return "NOT_FOLLOWED", "you moved" end
            return "FOLLOWED", "you held"
        end
        return "UNKNOWN", "not an observable recommendation (" .. text .. ")"
    end

    --- Did the tied prediction come true in the window?
    local function judge_prediction(e, S)
        local p = e.prediction
        if not p.pattern then return "NONE", "no pattern tied to this episode" end
        if p.text == "none" then return "NONE", "no prediction stood" end
        if e.censored then return "CENSORED", e.censored end
        if p.data ~= "ok" then return "INVALID", "the pattern's inputs were not live: " .. tostring(p.data) end
        if not e.trigger.observed then return "INVALID", "the trigger was inferred" end
        local key = p.pattern
        if key == "mobility_when_slowed" then
            if e.flags.reached_melee then return "HIT", "it reached melee" end
            return "MISS", "it did not reach melee in the window"
        elseif key == "over_committing" then
            if e.flags.second_burst then return "HIT", "a second burst followed" end
            return "MISS", "no second burst in the window"
        elseif key == "same_opener" then
            if e.flags.opener_name then
                if e.flags.opener_name == (p.text or ""):match("it opens with (.+)$") then return "HIT", "it opened with " .. e.flags.opener_name end
                return "MISS", "it opened with " .. e.flags.opener_name
            end
            return "CENSORED", "no opener seen in the window"
        elseif key == "defensive_threshold" then
            if p.threshold and e.flags.defensive_hp then
                local d = math.abs(e.flags.defensive_hp * 100 - p.threshold)
                if d <= KE.threshold_tolerance * 100 then return "HIT", string.format("the defensive came at %d%%, predicted %d%%", floor(e.flags.defensive_hp * 100 + 0.5), p.threshold) end
                return "MISS", string.format("the defensive came at %d%%, predicted %d%%", floor(e.flags.defensive_hp * 100 + 0.5), p.threshold)
            end
            return "MISS", "no defensive at the predicted health"
        end
        return "NONE", "no rule for " .. key
    end

    --- The measurable result: the rules of score.lua EPISODES, in order.
    local function judge_result(e)
        local b, a = e.before, e.after
        if e.censored or not a then return { primary = "UNKNOWN", all = {}, why = e.censored or "no after state" } end
        if e.guess_only then return { primary = "UNKNOWN", all = {}, why = "the result would rest on inferred data: " .. e.guess_only } end
        local all, why = {}, {}
        local function add(cat, text) all[#all + 1] = cat; why[#why + 1] = cat .. ": " .. text end
        local hp_d = a.hp - b.hp
        local fb, fa = b.foe, a.foe
        local threat_fell = RANK[a.threat] < RANK[b.threat]
        local threat_rose = RANK[a.threat] > RANK[b.threat]
        if e.died then
            add("SITUATION_WORSENED", "you died")
        else
            if hp_d >= -KE.hp_better and (threat_fell or a.attackers < b.attackers or (b.controlled and not a.controlled)) then
                add("SURVIVAL_IMPROVED", string.format("health held (%+d%%) and %s", floor(hp_d * 100 + 0.5),
                    threat_fell and ("the threat fell to " .. a.threat) or a.attackers < b.attackers and "fewer on you" or "the control on you ended"))
            end
            if ((b.zone == "melee" or b.zone == "dead_zone") and a.zone == "ranged")
                or (b.gap and a.gap and (a.gap - b.gap) >= KE.gap_improved and (fb and fb.on_me)) then
                add("POSITION_IMPROVED", string.format("%s -> %s (%.0f yd)", tostring(b.zone), tostring(a.zone), (a.gap or 0) - (b.gap or 0)))
            end
            if e.flags.control_held then add("CONTROL_SUCCESSFUL", e.flags.control_held) end
            if fb and fa then
                if (fb.hp - fa.hp) >= KE.foe_hp_drop and not b.controlled then
                    add("DAMAGE_OPPORTUNITY_CREATED", string.format("it lost %d%%", floor((fb.hp - fa.hp) * 100 + 0.5)))
                elseif (fb.immune or fb.avoid) and not (fa.immune or fa.avoid) then
                    add("DAMAGE_OPPORTUNITY_CREATED", "its defensive ended")
                end
            end
            if (e.flags.foe_spent and not e.flags.we_spent) or (b.defensives_ready > 0 and a.defensives_ready >= b.defensives_ready and not e.flags.we_spent and threat_fell) then
                add("COOLDOWN_SAVED", e.flags.foe_spent and ("it spent " .. e.flags.foe_spent .. ", you spent nothing") or "the threat fell with your defensives unspent")
            end
            if e.flags.foe_died then add("OBJECTIVE_PROGRESS", "it died") end
            if not b.flag and a.flag then add("OBJECTIVE_PROGRESS", "you took the flag") end
            if hp_d <= -KE.hp_worse or threat_rose or (not b.controlled and a.controlled)
                or (b.zone == "ranged" and (a.zone == "melee" or a.zone == "dead_zone")) then
                add("SITUATION_WORSENED", string.format("health %+d%%%s%s%s", floor(hp_d * 100 + 0.5),
                    threat_rose and (", the threat rose to " .. a.threat) or "", (not b.controlled and a.controlled) and ", you were controlled" or "",
                    (b.zone == "ranged" and (a.zone == "melee" or a.zone == "dead_zone")) and (", it reached " .. tostring(a.zone)) or ""))
            end
        end
        if #all == 0 then return { primary = "NO_MEASURABLE_CHANGE", all = {}, why = "nothing measurable moved" } end
        -- The primary: the worsening outranks an improvement that happened alongside it; else the first found.
        local primary = all[1]
        for i = 1, #all do if all[i] == "SITUATION_WORSENED" then primary = "SITUATION_WORSENED" end end
        return { primary = primary, all = all, why = table.concat(why, "; ") }
    end

    -- --- open and close ----------------------------------------------------------------------

    local function dup(def, guid, now)
        for i = 1, #T.open do
            local e = T.open[i]
            if e.type == def.key and e.foe == guid then return true end
        end
        local last = T.last
        if last and last.type == def.key and last.foe == guid and (now - last.t_open) < KE.dedupe_window then return true end
        return false
    end

    local function open(S, now, def, foe, trigger_text, source, observed, pattern)
        local guid = foe and foe.guid or nil
        if dup(def, guid, now) then
            T.dropped_dup = T.dropped_dup + 1
            return nil
        end
        if #T.open >= KE.max_open or T.count >= KE.max_per_fight then
            T.dropped_full = T.dropped_full + 1
            return nil
        end
        local inputs_ok, inputs_why = true, nil
        if def.pattern and lib.predict and lib.predict.needs_live then inputs_ok, inputs_why = lib.predict.needs_live(def.pattern) end
        local motion_live = lib.predict and lib.predict.T and (lib.predict.T.inputs.motion or 0) > 0 or false
        local X = S.tactic
        local e = {
            id = random_hex(24), type = def.key, label = def.label, foe = guid, enemy_class = foe and foe.class or "?",
            foe_name = foe and foe.name or nil, unit = foe and foe.unit or nil, t_open = now, t = T.fight_start and (now - T.fight_start) or 0, horizon = def.horizon,
            trigger = { text = trigger_text, source = source, observed = observed ~= false },
            before = snapshot(S, foe, true), after = nil,
            prediction = prediction_of(S, foe, def, pattern),
            recommendation = { state = X and X.state or "NONE", action = X and X.actions and X.actions[1] or "",
                               move = S.pos and S.pos.advice or "none", bait = S.bait and S.bait.target and S.bait.target.kind or nil,
                               bait_press = S.bait and S.bait.target and S.bait.target.press or nil, hold = S.cc and S.cc.hold ~= nil },
            actions = {}, events = {}, flags = {}, moved = false, motion_live = motion_live,
            ready_at_open = {},
            quality = { duplicate = false, unattributed = observed == false, feeds_missing = not inputs_ok, feeds_why = inputs_why,
                        incomplete = false, guess_only = false, unsupported = false, test_data = M.test_data() },
            died = false, censored = nil, guess_only = nil, closed = false,
        }
        for i = 1, #SPELL_WORDS do
            local name = SPELL_WORDS[i]
            if book.known(name) and book.ready(name) then e.ready_at_open[name] = true end
        end
        if e.before.foe and foe then
            -- A result read off an inferred role or an inferred target is a guess: said, and the result UNKNOWN.
            local role_conf = foe.inferred and foe.inferred.role and foe.inferred.role.conf or 0
            if def.needs_role and role_conf < 0.5 then e.guess_only = "the player's role is inferred at " .. tostring(role_conf) end
        end
        if lib.client and lib.client.forever and def.unsupported_on_forever then
            e.quality.unsupported = true
            e.quality.unsupported_why = def.unsupported_on_forever
        end
        T.open[#T.open + 1] = e
        return e
    end

    local function push_event(e, now, text)
        if #e.events >= KE.events_keep then return end
        e.events[#e.events + 1] = { t = floor((now - e.t_open) * 10 + 0.5) / 10, text = text }
    end

    local function close(e, S, now, censored)
        if e.closed then return end
        e.closed = true
        e.censored = censored
        e.t_close = now
        local foe = e.foe and S.foes[e.foe] or nil
        e.after = (not censored or censored == "the fight ended") and snapshot(S, foe) or nil
        -- A dead player's row is gone and its health reads stale: dead is 0.
        if e.after and e.after.foe and e.flags.foe_died then e.after.foe.hp = 0 end
        if censored then e.quality.incomplete = true end
        if e.guess_only then e.quality.guess_only = true end
        local po, pwhy = judge_prediction(e, S)
        e.prediction.outcome, e.prediction.outcome_why = po, pwhy
        local ro, rwhy = judge_recommendation(e)
        e.recommendation.outcome, e.recommendation.outcome_why = ro, rwhy
        e.result = judge_result(e)
        -- The lesson candidate.
        local def = BY_KEY[e.type] or {}
        local actions = {}
        for i = 1, #e.actions do actions[#actions + 1] = e.actions[i].name end
        local c = note_comparable(e)
        local confidence = confidence_of(c, e)
        local candidate = nil
        if e.result.primary ~= "UNKNOWN" then
            candidate = string.format("when %s (vs %s): \"%s\" was %s and the result was %s (%d of %d comparable episode(s) this session)",
                e.label, string.lower(e.enemy_class or "?"), e.recommendation.action ~= "" and e.recommendation.action or ("move " .. tostring(e.recommendation.move)),
                string.lower(e.recommendation.outcome):gsub("_", " "), string.lower(e.result.primary):gsub("_", " "),
                c.results[e.result.primary] or 0, c.n)
        end
        e.lesson = {
            situation = string.format("%s vs %s, %s", tostring(lib.my_class and lib.my_class() or "?"), tostring(e.enemy_class), tostring(S.mode and S.mode.kind or "?")),
            observed = e.trigger.text, prediction = e.prediction.text,
            recommendation = e.recommendation.action ~= "" and e.recommendation.action or ("move " .. tostring(e.recommendation.move)),
            action = #actions > 0 and table.concat(actions, ", ") or (e.moved and "moved" or "unknown"),
            outcome = e.result.primary .. (e.result.why ~= "" and (" -- " .. e.result.why) or ""),
            candidate = candidate, confidence = confidence,
        }
        -- Kept, bounded.
        T.closed[#T.closed + 1] = e
        while #T.closed > KE.max_per_fight do table.remove(T.closed, 1) end
        T.count = T.count + 1
        T.by_type[e.type] = (T.by_type[e.type] or 0) + 1
        T.last = e
        for i = #T.open, 1, -1 do if T.open[i] == e then table.remove(T.open, i) end end
        return e
    end

    -- --- the triggers, once a tick --------------------------------------------------------------

    local prev = {}          -- per player: what the last tick saw
    local prev_me = { zone = nil, root = false, attackers = 0, pet_recall = false }

    local function melee_class(f)
        local c = f.class
        return c == "WARRIOR" or c == "ROGUE" or c == "PALADIN" or (sure(f.inferred and f.inferred.role, 0.5) == "melee")
    end

    local function feed_open(S, f, p, now)
        for i = 1, #T.open do
            local e = T.open[i]
            if e.foe == f.guid then
                if S.env.target.guid == f.guid and S.env.target.zone == "melee" then e.flags.reached_melee = true end
                if p.burst_started and e.before.foe and e.before.foe.burst and p.burst_started ~= e.before.foe.burst then e.flags.second_burst = true end
                if p.opener then e.flags.opener_name = p.opener end
                if p.defensive_hp then e.flags.defensive_hp = p.defensive_hp end
                if p.trinket then e.flags.foe_spent = e.flags.foe_spent or "its trinket"; push_event(e, now, "it trinkets") end
                if p.burst_started then e.flags.foe_spent = e.flags.foe_spent or p.burst_started; push_event(e, now, "it " .. p.burst_started) end
                if p.control_landed then
                    e.flags.control_landed_at = now
                    push_event(e, now, "your " .. p.control_landed .. " lands")
                end
                local h = f.cc and f.cc.held or nil
                if h and h.ours ~= "no" and h.breaks and (now - (e.flags.control_landed_at or e.t_open)) >= KE.control_held then
                    e.flags.control_held = e.flags.control_held or string.format("your %s held %.0f s", h.name, now - (e.flags.control_landed_at or e.t_open))
                end
                if p.died then e.flags.foe_died = true; push_event(e, now, "it dies") end
            end
        end
    end

    local function open_windows(W, S, now)
        -- The fight running now, or none (never the last one: live 2026-10-13
        -- an episode opened between fights, or on a fight's first tick before
        -- the debrief opened it, was timed from the fight before). The
        -- debrief's T.fight stays on a closed fight: T.open says it runs.
        local D = lib.debrief and lib.debrief.T or nil
        local fight = D and D.open and D.fight or nil
        T.fight_start = fight and fight.started_at or nil
        -- You: a root under pressure, the dead zone, the pet, the numbers.
        local me = S.me
        local rooted = me.root ~= nil
        if rooted and not prev_me.root and (S.attackers or 0) > 0 then
            local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
            local e = open(S, now, BY_KEY.rooted_under_pressure, tg, string.format("%s on you with %d player(s) on you", me.root.name or "a root", S.attackers), me.root.source or "aura", true)
        end
        prev_me.root = rooted
        local zone = S.env.target.zone
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        if tg and zone == "dead_zone" and prev_me.zone ~= "dead_zone" and prev_me.zone ~= "melee" then
            open(S, now, BY_KEY.dead_zone_entry, tg, string.format("%s inside your minimum range (%.0f yd)", tg.name, S.env.target.gap or 0), "row", true)
        end
        prev_me.zone = zone
        local recall = S.cc and S.cc.pet and S.cc.pet.recall == true
        if recall and not prev_me.pet_recall then
            local f = S.cc.pet.guid and S.foes[S.cc.pet.guid] or nil
            open(S, now, BY_KEY.pet_breaks_cc, f, S.cc.pet.why or "the pet is on a held player", "row", true)
        end
        prev_me.pet_recall = recall
        local attackers = S.attackers or 0
        if attackers >= 2 and prev_me.attackers < 2 then
            open(S, now, BY_KEY.outnumbered, tg, string.format("%d players on you", attackers), "row", true)
        end
        prev_me.attackers = attackers
        -- Each player.
        for guid, f in pairs(S.foes) do
            local p = prev[guid]
            if not p then
                p = { scan_at = -huge, in_combat = f.in_combat, burst = f.st and f.st.burst_name or nil, hp = f.hp or 1,
                      immune = f.st and (f.st.immune_name or f.st.avoid_name) or nil, trinket = f.st and f.st.trinket_down or false,
                      held = f.cc and f.cc.held and f.cc.held.name or nil, adapting = false }
                prev[guid] = p
            end
            local tick = {}
            -- Its events since the last look.
            local newest = p.scan_at
            for i = 1, #(f.recent or {}) do
                local row = f.recent[i]
                if row.at > p.scan_at then
                    local kind, name = row.kind, row.name
                    local mob = (kind == "cast" or kind == "start" or kind == "buff") and data.MOBILITY[name] or nil
                    if mob and mob.closes and melee_class(f) then
                        open(S, now, BY_KEY.gap_close_attempt, f, string.format("%s %s at %.0f yd", f.name, name, f.dist or 0), row.source or "event", true)
                    elseif name == "Blink" and (kind == "cast" or kind == "buff") then
                        open(S, now, BY_KEY.blink, f, string.format("%s blinks", f.name), row.source or "event", true)
                    end
                    if kind == "buff" then
                        local cover = data.PROTECTION[name]
                        if cover and cover ~= "fear" then tick.defensive_hp = f.hp or 1 end
                    end
                    if kind == "cast" and p.waiting_opener then
                        tick.opener = name
                        p.waiting_opener = false
                    end
                    if row.at > newest then newest = row.at end
                end
            end
            p.scan_at = newest
            -- A rogue opening on you.
            if f.class == "ROGUE" and f.in_combat and f.targets_me and not p.in_combat then
                open(S, now, BY_KEY.rogue_opener, f, string.format("%s opens on you", f.name), "row", true)
                p.waiting_opener = true
            end
            if f.in_combat and not p.in_combat and f.class ~= "ROGUE" then p.waiting_opener = true end
            p.in_combat = f.in_combat
            -- Its burst.
            local b = f.st and f.st.burst_name or nil
            if b and b ~= p.burst then
                tick.burst_started = b
                open(S, now, BY_KEY.enemy_burst, f, string.format("%s %s", f.name, b), "aura", true)
            end
            p.burst = b
            -- Its defensive: popped, or dropped.
            local immune = f.st and (f.st.immune_name or f.st.avoid_name) or nil
            if immune and immune ~= p.immune then
                open(S, now, BY_KEY.defensive_change, f, string.format("%s %s at %d%%", f.name, immune, floor((f.hp or 1) * 100 + 0.5)), "aura", true)
                tick.defensive_hp = tick.defensive_hp or f.hp or 1
            end
            local adapting, adapting_key = false, nil
            for key, x in pairs(f.predict or {}) do if x.adapting then adapting, adapting_key = true, key end end
            if adapting and not p.adapting then
                -- An inferred trigger: the prediction it tests is the pattern that changed.
                open(S, now, BY_KEY.defensive_change, f, f.name .. " changed its ways (the predictor: adapting on " .. tostring(adapting_key) .. ")",
                    "inferred", false, adapting_key)
            end
            p.immune, p.adapting = immune, adapting
            -- Its trinket.
            local trinket = f.st ~= nil and f.st.trinket_down == true
            if trinket and not p.trinket then tick.trinket = true end
            p.trinket = trinket
            -- A kill window.
            if (f.hp or 1) <= K.CC.kill_hp and p.hp > K.CC.kill_hp and not f.dead then
                open(S, now, BY_KEY.kill_opportunity, f, string.format("%s at %d%%", f.name, floor((f.hp or 1) * 100 + 0.5)), "row", true)
            end
            p.hp = f.hp or 1
            -- Our control landing on it.
            local held = f.cc and f.cc.held and f.cc.held.ours ~= "no" and f.cc.held.breaks and f.cc.held.name or nil
            if held and held ~= p.held then tick.control_landed = held end
            p.held = held
            feed_open(S, f, tick, now)
        end
    end

    function M.update(W, S, now)
        if not M.enabled() then return T end
        -- New windows only while PvP is on; the open ones are fed and closed
        -- whatever the picture says (a death or a departure ends PvP too).
        if S.active then open_windows(W, S, now) end
        local me = S.me
        -- The windows: feed, then close the ones past their horizon or cut.
        local rows = W.enemies and W.enemies.list or {}
        local n = W.enemies and W.enemies.count or 0
        local dead = {}
        for i = 1, n do if rows[i] and rows[i].dead and rows[i].guid then dead[rows[i].guid] = true end end
        local units = P.units
        for i = #T.open, 1, -1 do
            local e = T.open[i]
            if me.moving then e.moved = true end
            local f = e.foe and S.foes[e.foe] or nil
            -- Its death: off the rows, or off the unit (the picture drops a dead player at once).
            -- (only a unit still there that the game calls dead: one gone has left)
            local died = e.foe and dead[e.foe] or (e.unit and lib.unit_dead and lib.unit_dead(e.unit))
            if e.foe and died then
                e.flags.foe_died = true
                push_event(e, now, "it dies")
                close(e, S, now, nil)
            elseif e.foe and f and (now - (f.at or -huge)) > 1.5 then
                close(e, S, now, "the player left the picture")
            elseif e.foe and not f then
                close(e, S, now, "the player left the picture")
            elseif (now - e.t_open) >= e.horizon then
                close(e, S, now, nil)
            end
        end
        if S.threat then prev_threat.level, prev_threat.score = S.threat.level, S.threat.score end
        return T
    end

    --- Your own cast (init.lua hands it over): what you did, and at whom.
    function M.on_our_cast(name, target_guid, now)
        if not name then return end
        local damaging = data.OUR_DAMAGE and data.OUR_DAMAGE[name] == true
        for i = 1, #T.open do
            local e = T.open[i]
            if #e.actions < KE.actions_keep then
                e.actions[#e.actions + 1] = { name = name, target = target_guid, t = floor((now - e.t_open) * 10 + 0.5) / 10, damage = damaging }
            end
            if data.OUR_COOLDOWNS and data.OUR_COOLDOWNS[name] then e.flags.we_spent = e.flags.we_spent or name end
            push_event(e, now, "you " .. name)
        end
    end

    --- You died: every open window is cut, worsened.
    function M.on_death(S, now)
        for i = #T.open, 1, -1 do
            local e = T.open[i]
            e.died = true
            e.after = snapshot(S, e.foe and S.foes[e.foe] or nil)
            close(e, S, now, nil)
        end
    end

    --- The fight ended (debrief.lua): the open windows are cut; the fight's
    --- episodes and their summary are handed back, and the slate wiped.
    --- started_at (the fight's start, the debrief's clock): each episode is
    --- timed from it, one that opened just before it at 0; one whose window
    --- closed before the fight began is no part of it and is dropped (counted).
    function M.close_fight(S, now, started_at)
        for i = #T.open, 1, -1 do close(T.open[i], S, now, "the fight ended") end
        if started_at then
            for i = #T.closed, 1, -1 do
                local e = T.closed[i]
                if (e.t_open + (e.horizon or 0)) < started_at then
                    table.remove(T.closed, i)
                    T.dropped_outside = T.dropped_outside + 1
                else
                    e.t = math.max(0, e.t_open - started_at)
                end
            end
        end
        local list = {}
        for i = 1, #T.closed do list[i] = M.compact(T.closed[i]) end
        local summary = M.summary()
        -- The slate wiped for the next fight; the last episode stays readable.
        for i = #T.closed, 1, -1 do T.closed[i] = nil end
        T.count, T.dropped_dup, T.dropped_full, T.dropped_outside = 0, 0, 0, 0
        for k in pairs(T.by_type) do T.by_type[k] = nil end
        for k in pairs(prev) do prev[k] = nil end
        return list, summary
    end

    --- The fight's summary: the brief's list.
    function M.summary()
        local s = { episodes = #T.closed, by_type = {}, prediction = { HIT = 0, MISS = 0, CENSORED = 0, INVALID = 0, NONE = 0 },
                    recommendation = { FOLLOWED = 0, NOT_FOLLOWED = 0, UNKNOWN = 0 }, results = {},
                    threats = {}, cooldowns = { ours = {}, theirs = {} }, position_changes = 0, lessons = {},
                    dropped_duplicates = T.dropped_dup, dropped_full = T.dropped_full, dropped_outside = T.dropped_outside,
                    inputs = lib.predict and lib.predict.inputs_text and lib.predict.inputs_text() or "" }
        local seen_lesson = {}
        for i = 1, #T.closed do
            local e = T.closed[i]
            s.by_type[e.type] = (s.by_type[e.type] or 0) + 1
            s.prediction[e.prediction.outcome] = (s.prediction[e.prediction.outcome] or 0) + 1
            s.recommendation[e.recommendation.outcome] = (s.recommendation[e.recommendation.outcome] or 0) + 1
            s.results[e.result.primary] = (s.results[e.result.primary] or 0) + 1
            if e.type == "enemy_burst" or e.type == "outnumbered" then s.threats[#s.threats + 1] = e.trigger.text end
            for j = 1, #e.actions do
                if data.OUR_COOLDOWNS and data.OUR_COOLDOWNS[e.actions[j].name] then s.cooldowns.ours[e.actions[j].name] = (s.cooldowns.ours[e.actions[j].name] or 0) + 1 end
            end
            if e.flags.foe_spent then s.cooldowns.theirs[e.flags.foe_spent] = (s.cooldowns.theirs[e.flags.foe_spent] or 0) + 1 end
            if e.after and e.before.zone ~= e.after.zone then s.position_changes = s.position_changes + 1 end
            if e.lesson and e.lesson.candidate then
                -- One line per type, class and result: the latest, which carries the most comparable episodes.
                local key = e.type .. "|" .. e.enemy_class .. "|" .. e.result.primary
                local at = seen_lesson[key]
                if at then
                    s.lessons[at] = { text = e.lesson.candidate, confidence = e.lesson.confidence }
                else
                    s.lessons[#s.lessons + 1] = { text = e.lesson.candidate, confidence = e.lesson.confidence }
                    seen_lesson[key] = #s.lessons
                end
            end
        end
        return s
    end

    --- The upload form: bounded, no names.
    function M.compact(e)
        local function side(x)
            if not x then return nil end
            return { hp = x.hp, zone = x.zone, gap = x.gap, threat = x.threat, attackers = x.attackers, controlled = x.controlled,
                     defensives_ready = x.defensives_ready, foe_hp = x.foe and x.foe.hp or nil, foe_on_me = x.foe and x.foe.on_me or nil }
        end
        local actions = {}
        for i = 1, #e.actions do actions[i] = e.actions[i].name end
        local trigger = e.trigger.text
        if e.foe_name and e.foe_name ~= "" then trigger = trigger:gsub(e.foe_name, "the player") end
        return {
            id = e.id, type = e.type, enemy_class = e.enemy_class, t = floor((e.t or 0) + 0.5), horizon = e.horizon,
            trigger = { text = trigger, observed = e.trigger.observed, source = e.trigger.source },
            before = side(e.before), after = side(e.after),
            prediction = { pattern = e.prediction.pattern, p = e.prediction.p, reliability = e.prediction.reliability, sure = e.prediction.sure,
                           outcome = e.prediction.outcome },
            recommendation = { action = e.recommendation.action, move = e.recommendation.move, bait = e.recommendation.bait,
                               outcome = e.recommendation.outcome },
            actions = actions, moved = e.moved,
            result = { primary = e.result.primary, all = e.result.all },
            quality = { unattributed = e.quality.unattributed, feeds_missing = e.quality.feeds_missing, incomplete = e.quality.incomplete,
                        guess_only = e.quality.guess_only, unsupported = e.quality.unsupported, test_data = e.quality.test_data },
            lesson = e.lesson and { confidence = e.lesson.confidence, candidate = e.lesson.candidate and e.lesson.candidate:gsub(tostring(e.foe_name or "\1"), "the player") or nil } or nil,
        }
    end

    function M.reset()
        for i = #T.open, 1, -1 do T.open[i] = nil end
        for i = #T.closed, 1, -1 do T.closed[i] = nil end
        T.count, T.dropped_dup, T.dropped_full, T.dropped_outside, T.last = 0, 0, 0, 0, nil
        for k in pairs(T.by_type) do T.by_type[k] = nil end
        for k in pairs(T.comparable) do T.comparable[k] = nil end
        for k in pairs(prev) do prev[k] = nil end
        prev_me.zone, prev_me.root, prev_me.attackers, prev_me.pet_recall = nil, false, 0, false
    end

    --- The page's lines for the last fight's summary.
    function M.lines(summary)
        local s = summary or M.summary()
        if not s or s.episodes == 0 then return {} end
        local results = {}
        for k, v in pairs(s.results) do results[#results + 1] = string.format("%s %d", string.lower(k):gsub("_", " "), v) end
        table.sort(results)
        local out = {
            string.format("Episodes: %d -- predictions hit %d, miss %d, censored %d, invalid %d; recommendations followed %d, not %d, unknown %d",
                s.episodes, s.prediction.HIT, s.prediction.MISS, s.prediction.CENSORED, s.prediction.INVALID,
                s.recommendation.FOLLOWED, s.recommendation.NOT_FOLLOWED, s.recommendation.UNKNOWN),
            "Results: " .. (#results > 0 and table.concat(results, ", ") or "none measured"),
        }
        for i = 1, min(2, #s.lessons) do out[#out + 1] = string.format("Candidate (%s): %s", s.lessons[i].confidence, s.lessons[i].text) end
        return out
    end

    return M
end

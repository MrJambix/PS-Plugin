-- Jambix AIO / react / intel / debrief -- the lessons of each fight with a
-- player (PvP intelligence, Stage 11-a / brief Phase 16, asked for on
-- 2026-10-12: "each PvP fight should also be a lessons learned: what the
-- player used, what I could have used to win or play better").
--
-- OBSERVED  the fight's record: when it began and ended, who was in it
--           (class, role as inferred, their health low), what each used
--           (their cast and aura events), the controls they put on you, their
--           bursts, their trinket, what you used (your own cast events),
--           your health low, how long you were controlled, the threat's
--           peak, the states, the baits, the holds, how it ended.
-- INFERRED  the lessons: what stayed ready that could have turned it --
--           counted as seconds of a window (a melee player on you with a
--           slow ready and none cast for 8 s; a HIGH threat with a defensive
--           ready; the trap never laid; a kill window at 25% that got away;
--           your own control broken by your own hit) -- and the outcome
--           when nobody died (fled, reset, draw). Each lesson says the
--           seconds and the names it rests on.
-- UNKNOWN   its health beyond what the row reads, damage numbers (no
--           read), what an ally did.
--
-- Nothing here decides. The debrief goes to the log, the Reactions page's
-- *Fight debriefs* section, a banner (the outcome and the first lesson),
-- the fight log on disk (jambix.aio.fights.json, the last KEEP), and, with
-- *Share my fights* on and a central address configured, to the central
-- database (intel/central.lua) stripped of every name.

return function(P, lib, data, K)
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KD = K.DEBRIEF

    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    function M.enabled() return opt("intel_debrief", true) == true end
    function M.says() return opt("intel_debrief_say", true) == true end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function spell_name(id)
        if lib.spell_name then return lib.spell_name(id) end
        return nil
    end

    local function sure(x, th)
        if type(x) ~= "table" or x.v == nil then return nil end
        if (x.conf or 0) < (th or 0) then return nil end
        return x.v
    end

    local function clock_text(s)
        s = max(0, floor((s or 0) + 0.5))
        return string.format("%d:%02d", floor(s / 60), s % 60)
    end

    local function bump(t, name, n)
        if not name or name == "" then return end
        t[name] = (t[name] or 0) + (n or 1)
    end

    local function top_used(t, limit)
        local list = {}
        for name, n in pairs(t) do list[#list + 1] = { name = name, n = n } end
        table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
        local out = {}
        for i = 1, min(limit or 6, #list) do out[#out + 1] = string.format("%s %d", list[i].name, list[i].n) end
        return table.concat(out, ", ")
    end

    -- --- the fight log on disk -----------------------------------------------------------

    local FILE = "jambix.aio.fights.json"
    local log_loaded, fights = false, {}

    local function storage()
        local ctx = P.ctx
        return ctx and ctx.storage or nil
    end

    local function load_log()
        if log_loaded then return end
        log_loaded = true
        local st = storage()
        local data_in = st and st.read_json and try(st.read_json, FILE) or nil
        if type(data_in) == "table" and type(data_in.fights) == "table" then fights = data_in.fights end
    end

    local function save_log()
        local st = storage()
        if not (st and st.write_json) then return false end
        return try(st.write_json, FILE, { version = 1, fights = fights }) == true
    end

    function M.log() load_log() return fights end

    -- --- the fight -----------------------------------------------------------------------

    local T = { open = false, fight = nil, last = nil, count = 0, said = 0, shared = 0 }
    M.T = T

    local F = nil                 -- the fight being recorded
    local next_id = 0
    local closed_at = -huge       -- when the last one closed (no new one for a moment)

    --- A player the picture saw this second and that is not dead (the
    --- picture keeps a player a while after its last row, and never marks
    --- it dead: a dead one is read off the rows in tick).
    local function fresh(foe, now)
        return foe ~= nil and (now - (foe.at or -huge)) < 1.0 and not foe.dead
    end

    local function new_fight(S, now)
        next_id = next_id + 1
        return {
            id = next_id, started_at = now, ended_at = nil, duration = 0,
            mode = S.mode and S.mode.kind or "world_pvp", client = S.client and S.client.name or "?",
            outcome = nil, outcome_why = "",
            me = { class = lib.my_class and lib.my_class() or "?", level = S.me.level, hp_min = S.me.hp or 1, died = false,
                   used = {}, controlled_for = 0, defensive_used_at = nil, slow_used_at = -huge, last_cast_at = -huge,
                   last_cast_target = nil },
            foes = {}, foe_order = {},
            moments = {}, unused = {}, lessons = {},
            windows = { danger_defensive = 0, melee_unslowed = 0, melee_on_me = 0, kill = {}, stoppable = 0 },
            predictions = { forecasts = 0, right = 0, brier = 0, brier_sum = 0, patterns = {} },
            baits = { offered = 0, kinds = {} }, holds = 0,
            threat_peak = { level = "INFORMATIONAL", score = 0, at = 0 },
            states = {}, last_scan = {}, ledger_at_start = {},
            last_tick = now,
        }
    end

    local function moment(f, now, text)
        local m = f.moments
        if #m >= KD.moments_keep then table.remove(m, 1) end
        m[#m + 1] = { t = now - f.started_at, text = text }
    end

    local function foe_of(f, foe, now)
        local r = f.foes[foe.guid]
        if not r then
            r = { guid = foe.guid, unit = foe.unit, name = foe.name, class = foe.class or "?", role = nil, level = foe.level,
                  used = {}, controls_on_me = {}, bursts = 0, trinket = false, defensives = {},
                  hp_min = foe.hp or 1, died = false, fled = false, time_on_me = 0, seen_at = now,
                  burst_was = nil, trinket_was = false, low_since = nil, low_min = nil, control_was = nil, control_left_was = 0 }
            f.foes[foe.guid] = r
            f.foe_order[#f.foe_order + 1] = foe.guid
            moment(f, now, string.format("%s (%s) joins", foe.name, r.class))
        end
        return r
    end

    local function snapshot_ledger(S, f)
        local L = S.predict and S.predict.ledger or {}
        for key, l in pairs(L) do
            f.ledger_at_start[key] = { forecasts = l.forecasts, right = l.right, brier = l.brier }
        end
    end

    --- The picture's enemy-event counters, copied (the fight's feeds are the
    --- difference between its start and its end).
    local function events_now(S)
        local ev = S.events or {}
        local by = {}
        for k, v in pairs(ev.unresolved_by or {}) do by[k] = v end
        return { casts = ev.casts or 0, auras = ev.auras or 0, unresolved = ev.unresolved or 0, by = by,
                 not_player = ev.not_player or 0, not_hostile = ev.not_hostile or 0, not_own = ev.not_own or 0 }
    end

    local function start(S, now)
        F = new_fight(S, now)
        T.open, T.fight = true, F
        F.events_at_start = events_now(S)
        snapshot_ledger(S, F)
        moment(F, now, "the fight begins (" .. tostring(F.mode) .. ")")
    end

    --- Our own cast (init.lua hands it over): what you used.
    function M.on_our_cast(spell_id, target_guid, now)
        if not F then return end
        local name = spell_name(tonumber(spell_id))
        if not name then return end
        bump(F.me.used, name)
        F.me.last_cast_at, F.me.last_cast_target, F.me.last_cast_name = now, target_guid, name
        if data.OUR_SLOW_CASTS[name] then F.me.slow_used_at = now end
        if F.me_sets and F.me_sets.defensives[name] then
            F.me.defensive_used_at = F.me.defensive_used_at or now
            moment(F, now, "you " .. name)
        end
        if name == KD.trap then F.me.trap_laid = true; moment(F, now, "you lay " .. name) end
    end

    local function read_sets(S, f)
        if f.me_sets then return end
        local sets = {}
        for _, set in ipairs({ "defensives", "escapes", "controls", "slows", "interrupts" }) do
            local names = {}
            for i = 1, #(S.me.abilities[set] or {}) do
                local row = S.me.abilities[set][i]
                if row.known then names[row.name] = true end
            end
            sets[set] = names
        end
        f.me_sets = sets
    end

    local function any_ready(S, set)
        for i = 1, #(S.me.abilities[set] or {}) do
            local row = S.me.abilities[set][i]
            if row.ready then return row.name end
        end
        return nil
    end

    local function tick(W, S, now)
        local f = F
        local dt = max(0, min(1, now - f.last_tick))
        f.last_tick = now
        f.duration = now - f.started_at
        read_sets(S, f)
        local me = f.me
        me.hp_min = min(me.hp_min, S.me.hp or 1)
        if S.me.controlled then me.controlled_for = me.controlled_for + dt end
        -- The control on you, as it lands.
        local c = S.me.control
        local cname = c and c.name or nil
        if cname and cname ~= f.me_control_was then
            local who = nil
            moment(f, now, string.format("%s on you (%.0fs%s)", cname, c.left or 0, c.from_player and ", a player's" or ""))
            f.me_control_pending = cname
        end
        f.me_control_was = cname
        -- The threat's peak, the states, the baits, the holds.
        local Tt = S.threat
        if Tt and (Tt.score or 0) > f.threat_peak.score then
            f.threat_peak.level, f.threat_peak.score, f.threat_peak.at = Tt.level, Tt.score, now - f.started_at
        end
        local X = S.tactic
        if X and X.changed and X.state ~= "NONE" and X.state ~= "IDLE" then
            f.states[#f.states + 1] = X.state
            if #f.states > KD.moments_keep then table.remove(f.states, 1) end
            moment(f, now, "state " .. X.state)
        end
        local B = S.bait
        local bk = B and B.target and B.target.kind or nil
        if bk and bk ~= f.bait_was then
            f.baits.offered = f.baits.offered + 1
            bump(f.baits.kinds, bk)
            moment(f, now, "bait: " .. tostring(B.target.v))
        end
        f.bait_was = bk
        local H = S.cc and S.cc.hold or nil
        if H and H.name ~= f.hold_was then
            f.holds = f.holds + 1
            moment(f, now, "hold: " .. tostring(H.why))
        end
        f.hold_was = H and H.name or nil

        -- Each player in the fight.
        local melee_on_me, slow_ready = false, any_ready(S, "slows")
        for _, foe in pairs(S.foes) do
            local fighting = foe.in_combat or foe.targets_me or foe.targets_pet
            if (fighting or f.foes[foe.guid]) and fresh(foe, now) then
                local r = foe_of(f, foe, now)
                r.name, r.class = foe.name, foe.class or r.class
                r.role = sure(foe.inferred and foe.inferred.role, 0.5) or r.role
                r.hp_min = min(r.hp_min, foe.hp or 1)
                if foe.dead and not r.died then
                    r.died = true
                    moment(f, now, r.name .. " dies")
                end
                if foe.targets_me then r.time_on_me = r.time_on_me + dt end
                if foe.targets_me and (foe.dist or huge) <= KD.melee_reach then melee_on_me = true end
                -- What it used: its events since the last look.
                local since = f.last_scan[foe.guid] or -huge
                local newest = since
                for i = 1, #(foe.recent or {}) do
                    local row = foe.recent[i]
                    if row.at > since then
                        -- What it used is its own doing: another's shield on
                        -- it, another class's spell, is said, not counted.
                        local own = not (lib.own and lib.own(foe, row) == false)
                        if not own then
                            local cover = row.kind == "buff" and data.PROTECTION[row.name]
                            if cover and cover ~= "fear" then
                                moment(f, now, string.format("%s gets %s from another at %d%%", r.name, row.name, floor((foe.hp or 1) * 100 + 0.5)))
                            end
                        elseif row.kind == "cast" or row.kind == "start" or row.kind == "channel" then
                            bump(r.used, row.name)
                        elseif row.kind == "buff" then
                            local cover = data.PROTECTION[row.name]
                            if cover and cover ~= "fear" then
                                bump(r.used, row.name)
                                r.defensives[#r.defensives + 1] = row.name
                                moment(f, now, string.format("%s %s at %d%%", r.name, row.name, floor((foe.hp or 1) * 100 + 0.5)))
                            end
                        end
                        if row.at > newest then newest = row.at end
                    end
                end
                f.last_scan[foe.guid] = newest
                -- The control it put on you.
                if f.me_control_pending and foe.targets_me then
                    bump(r.controls_on_me, f.me_control_pending)
                    f.me_control_pending = nil
                end
                -- Its burst, its trinket.
                local b = foe.st and foe.st.burst_name or nil
                if b and b ~= r.burst_was then
                    r.bursts = r.bursts + 1
                    bump(r.used, b)
                    moment(f, now, r.name .. " " .. b)
                end
                r.burst_was = b
                local td = foe.st ~= nil and foe.st.trinket_down == true
                if td and not r.trinket_was then
                    r.trinket = true
                    moment(f, now, r.name .. " trinkets")
                end
                r.trinket_was = td
                -- The kill window: under the line, and what came of it.
                if not foe.dead and (foe.hp or 1) <= KD.kill_hp then
                    if not r.low_since then r.low_since, r.low_min = now, foe.hp or 1 end
                    r.low_min = min(r.low_min or 1, foe.hp or 1)
                elseif r.low_since then
                    local held = now - r.low_since
                    if held >= KD.kill_window_min and not foe.dead then
                        f.windows.kill[#f.windows.kill + 1] = { name = r.name, seconds = held, hp = r.low_min or 0 }
                    end
                    r.low_since, r.low_min = nil, nil
                end
                -- Your own control on it, broken by your own hit.
                local h = foe.cc and foe.cc.held or nil
                local held_ours = h and h.ours == "yes" and h.breaks and h.name or nil
                -- Who broke it, named: a hit of yours at it (a damaging cast
                -- within the window), else your pet on it, else your running
                -- attack at it; otherwise not yours to answer for (an ally, a
                -- tick, its own trinket) and no lesson.
                if r.control_was and not held_ours and r.control_left_was > KD.own_break_left then
                    local by = nil
                    if (now - me.last_cast_at) <= KD.own_break_window and me.last_cast_target == foe.guid
                        and (data.OUR_DAMAGE[me.last_cast_name or ""] or KD.breaking_casts[me.last_cast_name or ""]) then
                        by = "your " .. me.last_cast_name
                    elseif (foe.cc and foe.cc.pet_on) or (S.cc and S.cc.pet and S.cc.pet.guid == foe.guid) then
                        by = "your pet"
                    elseif S.env.target.guid == foe.guid and W.player and (W.player.auto_attacking or W.player.shooting) then
                        by = "your running attack"
                    end
                    if by then
                        f.windows.own_break = (f.windows.own_break or 0) + 1
                        f.own_break_by = f.own_break_by or {}
                        f.own_break_by[by] = (f.own_break_by[by] or 0) + 1
                        moment(f, now, string.format("%s broke your %s on %s (%.1fs left)", by, r.control_was, r.name, r.control_left_was))
                    else
                        moment(f, now, string.format("your %s on %s ended early (%.1fs left): no hit of yours seen", r.control_was, r.name, r.control_left_was))
                    end
                end
                r.control_was, r.control_left_was = held_ours, h and h.left or 0
            end
        end
        -- Death, read off the rows and the unit: the picture drops a dead
        -- player at once, so it is never seen dead there.
        local list, n = W.enemies and W.enemies.list or {}, W.enemies and W.enemies.count or 0
        for i = 1, n do
            local row = list[i]
            local rec = row and row.guid and f.foes[row.guid] or nil
            if rec and not rec.died and row.dead then
                rec.died = true
                moment(f, now, rec.name .. " dies")
            end
        end
        -- Off the unit: only one still there that the game calls dead (a
        -- unit gone is a player that left: a Vanish, stealth, out of sight).
        for _, guid in ipairs(f.foe_order) do
            local rec = f.foes[guid]
            if not rec.died and rec.unit and lib.unit_dead and lib.unit_dead(rec.unit) then
                rec.died = true
                moment(f, now, rec.name .. " dies")
            end
        end
        -- The windows a lesson rests on.
        if melee_on_me then
            f.windows.melee_on_me = f.windows.melee_on_me + dt
            if slow_ready and (now - me.slow_used_at) > KD.slow_recent then
                f.windows.melee_unslowed = f.windows.melee_unslowed + dt
            end
        end
        local danger = Tt and K.RANK[Tt.level] and K.RANK[Tt.level] >= K.RANK.HIGH or (S.me.hp or 1) <= KD.low_hp
        if danger and any_ready(S, "defensives") and not me.defensive_used_at then
            f.windows.danger_defensive = f.windows.danger_defensive + dt
        end
        if Tt and Tt.incoming_cast and any_ready(S, "controls") then
            f.windows.stoppable = f.windows.stoppable + dt
        end
    end

    -- --- the lessons ------------------------------------------------------------------------

    local function outcome_of(S, f, why)
        if f.me.died then return "lost", "you died" end
        local alive, dead, n = 0, 0, 0
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            n = n + 1
            if r.died then dead = dead + 1 else alive = alive + 1 end
        end
        if n > 0 and dead == n then return "won", dead == 1 and (f.foes[f.foe_order[1]].name .. " died") or (dead .. " died") end
        if dead > 0 then return "won", string.format("%d of %d died, the rest left", dead, n) end
        if why == "they left" then return "fled", "they left alive" end
        if why == "combat ended" then
            if (f.me.hp_min or 1) <= KD.low_hp then return "reset", "you got away low" end
            return "draw", "the fight ended with everyone standing"
        end
        return "draw", why or "the fight ended"
    end

    local function lessons_of(S, f)
        local L = {}
        local W = f.windows
        local me = f.me
        local function add(code, text, seconds) L[#L + 1] = { code = code, text = text, seconds = seconds or 0 } end
        -- What stayed ready that could have turned it.
        if W.danger_defensive >= KD.lesson_min then
            local names = {}
            for name in pairs(f.me_sets and f.me_sets.defensives or {}) do names[#names + 1] = name end
            table.sort(names)
            add("defensive_unused", string.format("%s stayed ready through %.0f s of danger (HIGH threat or under %d%%): a defensive is for that moment",
                table.concat(names, " / "), W.danger_defensive, floor(KD.low_hp * 100 + 0.5)), W.danger_defensive)
        end
        if W.melee_unslowed >= KD.lesson_min then
            add("slow_unused", string.format("a melee player was on you for %.0f s with a slow ready and none cast: clip or Concussive Shot first, then the range", W.melee_unslowed), W.melee_unslowed)
        end
        if f.me_sets and f.me_sets.controls[KD.trap] and not me.trap_laid and W.melee_on_me >= KD.trap_min then
            add("trap_unused", string.format("%s was never laid while a melee player spent %.0f s on you: the trap is the reset", KD.trap, W.melee_on_me), W.melee_on_me)
        end
        for i = 1, #W.kill do
            local k = W.kill[i]
            add("kill_missed", string.format("kill window missed: %s was at %d%% for %.0f s and lived -- Aimed Shot, Multi-Shot, the pet, Intimidation", k.name, floor(k.hp * 100 + 0.5), k.seconds), k.seconds)
        end
        if (W.own_break or 0) > 0 then
            local by = {}
            for who, n in pairs(f.own_break_by or {}) do by[#by + 1] = string.format("%s %d", who, n) end
            table.sort(by)
            add("own_cc_broken", string.format("you broke your own control %d time(s)%s: no damage on a trapped or scattered player (the hold reaction says when)",
                W.own_break, #by > 0 and (" (" .. table.concat(by, ", ") .. ")") or ""), W.own_break * 5)
        end
        if W.stoppable >= KD.lesson_min then
            add("cast_unstopped", string.format("%.0f s of dangerous casts at you with a stopper ready: Scatter Shot or Intimidation on the caster", W.stoppable), W.stoppable)
        end
        -- What beat you.
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            local ctl = top_used(r.controls_on_me, 3)
            if ctl ~= "" then
                add("controlled", string.format("%s controlled you with %s (%.0f s under control in all): trinket, Will of the Forsaken or distance before it lands", r.name, ctl, me.controlled_for), me.controlled_for)
            end
            if r.bursts > 0 and f.outcome == "lost" then
                add("burst_lost", string.format("%s's burst (%d) took the fight: a defensive or line of sight through the window", r.name, r.bursts), 10)
            end
            if r.trinket and f.outcome ~= "won" then
                add("trinket_spent", string.format("%s spent its trinket: the next control would have held", r.name), 5)
            end
        end
        -- What held.
        if f.outcome == "won" and me.trap_laid then add("trap_won", KD.trap .. " laid and the fight won: keep that opener", 1) end
        if f.outcome == "won" and f.holds > 0 then add("hold_won", "your controls were kept (the hold stood " .. f.holds .. " time(s))", 1) end
        -- The predictor's score this fight.
        local pr = f.predictions
        if pr.forecasts > 0 then
            add("forecasts", string.format("%d forecast(s) made this fight, %d on the right side (Brier %.2f)", pr.forecasts, pr.right, pr.brier), 0)
        end
        table.sort(L, function(a, b) return a.seconds > b.seconds end)
        local out = {}
        for i = 1, min(KD.lessons_keep, #L) do out[i] = L[i] end
        return out
    end

    local function close(S, now, why)
        local f = F
        if not f then return end
        F = nil
        T.open = false
        closed_at = now
        f.ended_at, f.duration = now, now - f.started_at
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            if r.low_since and not r.died then
                local held = now - r.low_since
                if held >= KD.kill_window_min then
                    f.windows.kill[#f.windows.kill + 1] = { name = r.name, seconds = held, hp = r.low_min or 0 }
                end
            end
            if not r.died and why == "they left" then r.fled = true end
        end
        f.outcome, f.outcome_why = outcome_of(S, f, why)
        -- The predictor's ledger, this fight's share.
        local L = S.predict and S.predict.ledger or {}
        for key, l in pairs(L) do
            local before = f.ledger_at_start[key] or { forecasts = 0, right = 0, brier = 0 }
            local d = l.forecasts - before.forecasts
            if d > 0 then
                f.predictions.forecasts = f.predictions.forecasts + d
                f.predictions.right = f.predictions.right + (l.right - before.right)
                f.predictions.brier_sum = f.predictions.brier_sum + (l.brier - before.brier)
            end
        end
        -- The fight's Brier score is the mean over its forecasts (0 = every one
        -- right and sure, 0.25 = a coin): until 2026-10-13 the sum went up as it.
        f.predictions.brier = f.predictions.forecasts > 0 and f.predictions.brier_sum / f.predictions.forecasts or 0
        for _, guid in ipairs(f.foe_order) do
            local foe = S.foes[guid]
            local cats = foe and foe.pat and foe.pat.cats or nil
            if cats then
                local r = f.foes[guid]
                r.patterns = {}
                for key, c in pairs(cats) do
                    if c.total > 0 then r.patterns[key] = { hits = c.hits, total = c.total } end
                end
            end
        end
        f.lessons = lessons_of(S, f)
        -- What reached us of the enemy this fight: the events kept, the ones
        -- dropped and why (the token kinds that did not resolve). On a client
        -- that reports nothing of an enemy, every "it used" reads empty, and
        -- this says why.
        do
            local a, b = f.events_at_start or events_now(S), events_now(S)
            local by = {}
            for k, v in pairs(b.by) do
                local d = v - (a.by[k] or 0)
                if d > 0 then by[k] = d end
            end
            f.feeds = { casts = b.casts - a.casts, auras = b.auras - a.auras, unresolved = b.unresolved - a.unresolved,
                        unresolved_by = by, not_hostile = b.not_hostile - a.not_hostile, not_own = b.not_own - a.not_own }
            f.events_at_start = nil
        end
        -- The decision episodes of the fight, and their summary (the collector).
        if lib.episodes and lib.episodes.close_fight then
            f.episodes, f.episodes_summary = lib.episodes.close_fight(S, now, f.started_at)
        end
        moment(f, now, string.format("the fight ends: %s (%s)", f.outcome, f.outcome_why))
        f.last_scan, f.ledger_at_start, f.windows_text = nil, nil, nil
        T.last, T.count = f, T.count + 1
        -- Keep, say, write, share: each step on its own, so one failing (a
        -- file, a banner, the network) is logged and never stops the
        -- others or the layer. Live on 2026-10-12 a failure here (os.time
        -- in the sandbox) took the whole intel build down on every tick.
        local function step(what, fn)
            local ok, err = pcall(fn)
            if not ok then
                T.errors = (T.errors or 0) + 1
                T.last_error = what .. ": " .. tostring(err)
                if P.log and P.log.fmt then P.log.fmt("warn", "fight debrief: %s failed: %s", what, tostring(err)) end
            end
            return ok
        end
        step("the local log", function()
            load_log()
            fights[#fights + 1] = M.record(f)
            while #fights > KD.keep do table.remove(fights, 1) end
            save_log()
        end)
        step("the log line", function()
            if P.log and P.log.fmt then
                P.log.fmt("info", "fight debrief: %s vs %s in %s -- %s", f.outcome, M.foes_text(f), clock_text(f.duration),
                    f.lessons[1] and f.lessons[1].text or "no lesson")
            end
        end)
        step("the banner", function()
            if M.says() and P.narrate and P.narrate.say then
                local first = f.lessons[1] and f.lessons[1].text or f.outcome_why
                P.narrate.say(f.outcome == "lost" and "warn" or "info",
                    string.format("fight %s vs %s", f.outcome, M.foes_text(f)), first, "intel_debrief")
                T.said = T.said + 1
            end
        end)
        step("sharing", function()
            if lib.central and lib.central.share then
                if lib.central.share(f) then T.shared = T.shared + 1 end
            end
        end)
        return f
    end

    --- The fight as the log keeps it (names kept here: this is your own file).
    function M.record(f)
        local foes = {}
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            foes[#foes + 1] = { name = r.name, class = r.class, role = r.role, level = r.level, used = r.used,
                                controls_on_me = r.controls_on_me, bursts = r.bursts, trinket = r.trinket,
                                defensives = r.defensives, hp_min = r.hp_min, died = r.died, fled = r.fled,
                                time_on_me = r.time_on_me, patterns = r.patterns }
        end
        local lessons = {}
        for i = 1, #f.lessons do lessons[i] = { code = f.lessons[i].code, text = f.lessons[i].text } end
        local moments = {}
        for i = 1, #f.moments do moments[i] = string.format("%s %s", clock_text(f.moments[i].t), f.moments[i].text) end
        return {
            id = f.id, at = (lib.wall_time and lib.wall_time()) or 0, duration = floor(f.duration + 0.5), mode = f.mode, client = f.client,
            outcome = f.outcome, outcome_why = f.outcome_why,
            me = { class = f.me.class, level = f.me.level, hp_min = f.me.hp_min, died = f.me.died, used = f.me.used,
                   controlled_for = f.me.controlled_for, trap_laid = f.me.trap_laid == true },
            foes = foes, lessons = lessons, moments = moments,
            predictions = f.predictions, baits = f.baits, holds = f.holds, threat_peak = f.threat_peak, states = f.states, feeds = f.feeds,
            episodes = f.episodes, episodes_summary = f.episodes_summary,
        }
    end

    function M.foes_text(f)
        local parts = {}
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            parts[#parts + 1] = string.format("%s (%s)", r.name, string.lower(r.class or "?"))
        end
        return #parts > 0 and table.concat(parts, ", ") or "nobody"
    end

    -- --- the tick ---------------------------------------------------------------------------

    local quiet_since = nil

    function M.update(W, S, now)
        if not M.enabled() then
            if F then close(S, now, "switched off") end
            return T
        end
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        local fighting = S.active and (S.attackers > 0 or (S.me.in_combat and fresh(tg, now) and tg.in_combat))
        if not F then
            if fighting and (now - closed_at) >= KD.restart_after then start(S, now) end
            return T
        end
        tick(W, S, now)
        -- Over? Everyone in it dead; nobody left fighting for a while; they went.
        local any_alive, any_fighting, any_seen = false, false, false
        for _, guid in ipairs(F.foe_order) do
            local rec = F.foes[guid]
            local foe = S.foes[guid]
            if not rec.died then
                any_alive = true
                -- Seen: a row this second (the picture keeps a player a while after its last).
                if foe and (now - (foe.at or -huge)) < 1.0 then
                    any_seen = true
                    if foe.in_combat or foe.targets_me or foe.targets_pet then any_fighting = true end
                end
            end
        end
        if not any_alive and #F.foe_order > 0 then
            close(S, now, "they died")
        elseif not any_seen then
            -- A class that can go unseen and come back (a rogue's Vanish and
            -- stealth, a druid's Prowl) gets longer: its return is the same fight.
            local wait = KD.gone_after
            for _, guid in ipairs(F.foe_order) do
                local rec = F.foes[guid]
                if not rec.died and KD.stealthy[tostring(rec.class)] then wait = math.max(wait, KD.stealth_gone_after) end
            end
            quiet_since = quiet_since or now
            if (now - quiet_since) >= wait then close(S, now, "they left") end
        elseif not any_fighting and not S.me.in_combat then
            quiet_since = quiet_since or now
            if (now - quiet_since) >= KD.end_after then close(S, now, "combat ended") end
        else
            quiet_since = nil
        end
        return T
    end

    --- You died (init.lua, before the picture forgets everyone).
    function M.on_death(S, now)
        if not F then return end
        F.me.died = true
        moment(F, now, "you die")
        close(S, now, "you died")
    end

    function M.reset()
        F, T.open, T.fight = nil, false, nil
        quiet_since = nil
    end

    -- --- the words ------------------------------------------------------------------------

    --- The Reactions page's lines: the last fight, and the central database.
    function M.lines()
        local out = {}
        local f = T.last
        if not f then
            load_log()
            local n = #fights
            out[1] = n > 0 and string.format("No fight this session yet; %d in the log (%s).", n, FILE) or "No fight with a player yet."
        else
            out[#out + 1] = string.format("Last fight: %s vs %s in %s (%s) -- %s", string.upper(f.outcome or "?"), M.foes_text(f),
                clock_text(f.duration), tostring(f.mode), f.outcome_why)
            for _, guid in ipairs(f.foe_order) do
                local r = f.foes[guid]
                local used = top_used(r.used, 6)
                out[#out + 1] = string.format("%s used: %s%s", r.name, used ~= "" and used or "nothing seen",
                    r.trinket and "; trinket" or "")
            end
            out[#out + 1] = "You used: " .. (top_used(f.me.used, 8) ~= "" and top_used(f.me.used, 8) or "nothing recorded")
            if f.feeds then
                local by = {}
                for k, v in pairs(f.feeds.unresolved_by or {}) do by[#by + 1] = k .. " " .. v end
                table.sort(by)
                out[#out + 1] = string.format("Enemy events this fight: %d cast(s), %d aura(s) kept; %d dropped%s%s",
                    f.feeds.casts, f.feeds.auras, f.feeds.unresolved, #by > 0 and (" (unresolved: " .. table.concat(by, ", ") .. ")") or "",
                    (f.feeds.not_own or 0) > 0 and string.format("; %d not the player's own (another's aura, another class's spell)", f.feeds.not_own) or "")
            end
            out[#out + 1] = string.format("You: low %d%%, controlled %.0f s; threat peak %s %d at %s; states %s",
                floor((f.me.hp_min or 1) * 100 + 0.5), f.me.controlled_for, f.threat_peak.level, floor(f.threat_peak.score + 0.5),
                clock_text(f.threat_peak.at), #f.states > 0 and table.concat(f.states, " > ") or "-")
            if #f.lessons == 0 then
                out[#out + 1] = "Lessons: none this time"
            else
                for i = 1, #f.lessons do out[#out + 1] = string.format("Lesson %d: %s", i, f.lessons[i].text) end
            end
            if lib.episodes and f.episodes_summary then
                for _, line in ipairs(lib.episodes.lines(f.episodes_summary)) do out[#out + 1] = line end
            end
        end
        if lib.central and lib.central.status then out[#out + 1] = "Central: " .. lib.central.status() end
        if lib.fieldcheck and lib.fieldcheck.lines then
            local ok, lines = pcall(lib.fieldcheck.lines)
            if ok and type(lines) == "table" then for i = 1, #lines do out[#out + 1] = lines[i] end end
        end
        return out
    end

    return M
end

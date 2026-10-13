-- Jambix AIO / react / intel / history -- Stage 11-b of PVP_INTEL_PLAN.md
-- (the brief's Phase 16, analytics): what the layer said in each fight, and
-- how good it was, kept across sessions.
--
-- Per fight (the debrief's: it opens and closes with debrief.lua's record),
-- a bounded ring of what was observed, predicted and recommended, and why:
-- an entry each time the state or its first action changes, and each time
-- a forecast is scored (confirmed or contradicted). Five metrics, and no
-- kill or win rate:
--
--   predictions   forecasts scored this fight, how many right (predict.lua's
--                 ledger, this fight's share)
--   preservation  our major cooldowns spent, and how many while a defensive
--                 already up was enough (cooldowns.sufficient) -- spent for
--                 nothing
--   overlap       our control on a player already held, our defensive while
--                 another of ours covers
--   stability     state changes per 10 s
--   invalid       a first action naming an ability of ours that was not
--                 trained or not ready when it was said
--
-- Each fight's figures go to jambix.aio.history.json (the newest KH.keep),
-- to the Live view, and on Forever to the recorder's trace. Measurable only:
-- a fight with no forecast scored says "no forecast", never 0%.

return function(P, lib, data, K)
    local book = P.spellbook
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KH = K.HISTORY

    local M = {}

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end
    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end
    function M.enabled() return opt("intel_history", true) == true end

    -- Our abilities, by name, as a first action can begin with them.
    local OURS = {}
    for _, set in ipairs({ data.OUR_COOLDOWNS, data.OUR_DAMAGE, data.OUR_SLOW_CASTS }) do
        for name in pairs(set or {}) do OURS[#OURS + 1] = name end
    end
    for _, name in ipairs({ "Feign Death", "Disengage", "Viper Sting", "Aspect of the Monkey", "Aspect of the Cheetah",
                            "Aspect of the Hawk", "Concussive Shot", "Wing Clip" }) do OURS[#OURS + 1] = name end
    table.sort(OURS, function(a, b) return #a > #b end)     -- the longest name first ("Aimed Shot" before "Aim")
    local function our_ability(text)
        if type(text) ~= "string" then return nil end
        for i = 1, #OURS do
            local n = OURS[i]
            if text:sub(1, #n) == n then return n end
        end
        return nil
    end
    -- Our controls a target can already be held under.
    local CONTROLS = { ["Scatter Shot"] = true, ["Wyvern Sting"] = true, ["Intimidation"] = true, ["Scare Beast"] = true }
    -- Our defensives (the protection already up makes another one an overlap).
    local DEFENSIVES = { ["Deterrence"] = true }

    -- --- the log on disk ----------------------------------------------------------------

    local FILE = "jambix.aio.history.json"
    local loaded, log = false, {}
    local function storage() local ctx = P.ctx return ctx and ctx.storage or nil end
    local function load_log()
        if loaded then return end
        loaded = true
        local st = storage()
        local d = st and st.read_json and try(st.read_json, FILE) or nil
        if type(d) == "table" and type(d.fights) == "table" then log = d.fights end
    end
    local function save_log()
        local st = storage()
        if not (st and st.write_json) then return false end
        return try(st.write_json, FILE, { version = 1, fights = log }) == true
    end
    function M.log() load_log() return log end

    -- --- the fight ------------------------------------------------------------------------

    local T = { open = false, fight = nil, last = nil, totals = nil, at = -huge }
    M.T = T
    local F = nil

    local function ledger_sum(S)
        local n, right = 0, 0
        for _, l in pairs(S.predict and S.predict.ledger or {}) do
            n, right = n + (l.forecasts or 0), right + (l.right or 0)
        end
        return n, right
    end

    local function push(f, e)
        f.n = f.n + 1
        local i = ((f.n - 1) % KH.ring) + 1
        f.ring[i] = e
    end

    --- The ring, oldest first.
    function M.entries(f)
        f = f or F or T.last
        if not f then return {} end
        local out = {}
        local first = max(1, f.n - KH.ring + 1)
        for k = first, f.n do out[#out + 1] = f.ring[((k - 1) % KH.ring) + 1] end
        return out
    end

    local function open(S, now)
        local n, right = ledger_sum(S)
        F = { started_at = now, ring = {}, n = 0, changes = 0, last_state = nil, last_action = nil,
              forecasts_at_start = n, right_at_start = right, forecasts = 0, right = 0, seen_forecasts = n, seen_right = right,
              majors = 0, wasted = 0, wasted_why = {}, overlap = 0, overlap_why = {}, invalid = 0, invalid_why = {},
              mode = S.mode and S.mode.kind or "?" }
        T.open, T.fight = true, F
    end

    local function prediction_text(S)
        local PR = S.predict and S.predict.target or nil
        if not PR then return nil end
        local best = nil
        for _, e in pairs(PR) do if not best or (e.p or 0) > (best.p or 0) then best = e end end
        return best and string.format("%s p%.2f%s", tostring(best.v), best.p or 0, best.sure and "" or " (forming)") or nil
    end

    local function note(why_list, text)
        if #why_list < 6 then why_list[#why_list + 1] = text end
    end

    local function tick(S, now)
        local X = S.tactic or {}
        local state, action = X.state or "NONE", X.actions and X.actions[1] or nil
        if state ~= F.last_state or action ~= F.last_action then
            local changed = F.last_state ~= nil and state ~= F.last_state
            if changed then F.changes = F.changes + 1 end
            push(F, { t = now - F.started_at, kind = "recommendation", state = state, action = action, why = X.why or "",
                      conf = X.conf or 0, threat = S.threat and S.threat.level or nil, prediction = prediction_text(S),
                      changed = changed })
            F.last_state, F.last_action = state, action
            -- Said now: is it ours, trained and ready?
            local name = our_ability(action)
            if name and book and not (try(book.known, name) and try(book.ready, name)) then
                F.invalid = F.invalid + 1
                note(F.invalid_why, string.format("%s said while %s", name, try(book.known, name) and "not ready" or "not trained"))
            end
        end
        -- The forecasts scored since the last look.
        local n, right = ledger_sum(S)
        if n > F.seen_forecasts then
            local hits = right - F.seen_right
            local misses = (n - F.seen_forecasts) - hits
            push(F, { t = now - F.started_at, kind = "forecast", confirmed = hits, contradicted = misses,
                      prediction = prediction_text(S) })
        end
        F.seen_forecasts, F.seen_right = n, right
        F.forecasts, F.right = n - F.forecasts_at_start, right - F.right_at_start
    end

    local function pct(a, b) return b > 0 and floor(a / b * 100 + 0.5) or nil end

    --- The figures of one fight (or the totals), as one line.
    local function figures(f)
        local dur = max(f.duration or 0, 1)
        local acc = pct(f.right or 0, f.forecasts or 0)
        local kept = (f.majors or 0) > 0 and pct((f.majors or 0) - (f.wasted or 0), f.majors) or nil
        return string.format("predictions %s, majors %s, overlap %d, %.1f changes/10 s, invalid %d",
            acc and string.format("%d%% of %d", acc, f.forecasts) or "no forecast scored",
            kept and string.format("%d kept well of %d", (f.majors or 0) - (f.wasted or 0), f.majors) or "none spent",
            f.overlap or 0, (f.changes or 0) / dur * 10, f.invalid or 0)
    end
    M.figures = figures

    local function totals()
        load_log()
        local t = { fights = #log, forecasts = 0, right = 0, majors = 0, wasted = 0, overlap = 0, changes = 0, duration = 0, invalid = 0 }
        for i = 1, #log do
            local f = log[i]
            for _, k in ipairs({ "forecasts", "right", "majors", "wasted", "overlap", "changes", "duration", "invalid" }) do
                t[k] = t[k] + (tonumber(f[k]) or 0)
            end
        end
        T.totals = t
        return t
    end

    local function close(S, now, outcome)
        local f = F
        if not f then return end
        F, T.open, T.fight = nil, false, nil
        f.duration = now - f.started_at
        local summary = {
            at = lib.wall_time and lib.wall_time() or 0, duration = f.duration, mode = f.mode, outcome = outcome or "?",
            forecasts = f.forecasts, right = f.right, majors = f.majors, wasted = f.wasted, overlap = f.overlap,
            changes = f.changes, invalid = f.invalid,
            why = { wasted = f.wasted_why, overlap = f.overlap_why, invalid = f.invalid_why },
            measurable = f.forecasts > 0 or f.majors > 0 or f.changes > 0,
        }
        f.summary = summary
        T.last = f
        load_log()
        log[#log + 1] = summary
        while #log > KH.keep do table.remove(log, 1) end
        save_log()
        totals()
        -- On Forever, the recorder's trace keeps it beside what the client answered.
        if S.client and S.client.forever and P.ctx and P.ctx.emit then
            pcall(P.ctx.emit, "jcore.recorder.trace", "intel history: " .. figures(summary))
        end
    end

    --- Once a tick, after the debrief: the fight opens and closes with its record.
    function M.update(W, S, now)
        if not M.enabled() then
            if F then close(S, now, "switched off") end
            return T
        end
        local D = lib.debrief and lib.debrief.T or nil
        if D and D.open and not F then open(S, now) end
        if F and not (D and D.open) then
            close(S, now, D and D.last and D.last.outcome or nil)
            return T
        end
        if not F or (now - T.at) < KH.every then return T end
        T.at = now
        tick(S, now)
        return T
    end

    --- Our own cast (init.lua hands it over): a major spent for nothing, a
    --- control on a player already held, a defensive over another.
    function M.on_our_cast(name, target_guid, S, now)
        if not F or type(name) ~= "string" then return end
        local C = lib.cooldowns
        if data.OUR_COOLDOWNS[name] then
            F.majors = F.majors + 1
            if C and C.sufficient and DEFENSIVES[name] then
                local ok_p, why_p = C.sufficient("physical")
                local ok_s, why_s = C.sufficient("spell")
                if ok_p or ok_s then
                    F.wasted = F.wasted + 1
                    note(F.wasted_why, string.format("%s while %s", name, ok_p and why_p or why_s))
                end
            end
        end
        if CONTROLS[name] then
            local f = target_guid and S.foes and S.foes[target_guid] or nil
            local h = f and f.cc and f.cc.held or nil
            if h and (h.left or 0) >= KH.overlap_left then
                F.overlap = F.overlap + 1
                note(F.overlap_why, string.format("%s on %s already held by %s (%.1f s left)", name, f.name or "?", tostring(h.name), h.left or 0))
            end
        elseif DEFENSIVES[name] then
            local pr = S.cds and S.cds.protection or nil
            if pr and (pr.left or 0) >= KH.overlap_left and pr.left < huge and #(pr.names or {}) > 0 then
                F.overlap = F.overlap + 1
                note(F.overlap_why, string.format("%s while %s covered you (%.1f s left)", name, table.concat(pr.names, " and "), pr.left))
            end
        end
    end

    --- The Live view's lines: this fight (or the last), and every fight kept.
    function M.lines()
        local out = {}
        if F then
            out[#out + 1] = "History (this fight): " .. figures({ duration = (T.at - F.started_at), forecasts = F.forecasts, right = F.right,
                majors = F.majors, wasted = F.wasted, overlap = F.overlap, changes = F.changes, invalid = F.invalid })
        elseif T.last then
            out[#out + 1] = "History (last fight): " .. figures(T.last.summary)
            local w = T.last.summary.why
            if #w.wasted > 0 then out[#out + 1] = "  spent for nothing: " .. table.concat(w.wasted, "; ") end
            if #w.overlap > 0 then out[#out + 1] = "  overlap: " .. table.concat(w.overlap, "; ") end
            if #w.invalid > 0 then out[#out + 1] = "  invalid: " .. table.concat(w.invalid, "; ") end
        end
        local t = T.totals or totals()
        if t.fights > 0 then out[#out + 1] = string.format("History (%d fights kept): %s", t.fights, figures(t)) end
        return out
    end

    --- Logging out mid-fight: the fight is closed and written as it stands.
    function M.on_logout(S, now)
        if F then close(S, now, "logged out") end
    end

    function M.reset()
        F, T.open, T.fight, T.at = nil, false, nil, -huge
    end

    return M
end

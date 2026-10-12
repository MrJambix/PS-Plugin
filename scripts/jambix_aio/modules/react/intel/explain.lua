-- Jambix AIO / react / intel / explain -- the picture, the threat, the
-- state and the move, in words (PvP intelligence, Stage 4 / brief Phase 15).
--
-- Every recommendation says why. This gathers what the layer concluded
-- this tick into one table (summary) for whoever shows it -- the readout's
-- rows, the Reactions window's Live view (Stage 5), the alerts -- and
-- never shows an inference as a fact: a guessed thing carries its
-- confidence, an unknown thing is listed as unknown.
--
-- Alerts go through the narration module (narrate.say: a banner with the
-- raid-warning sound for danger, quieter for the rest), one per change of
-- state or of move advice, keyed so the same one does not repeat; with
-- `intel_alerts` off nothing is said on screen and the readout keeps it.

return function(P, lib, K)
    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    function M.alerts_on() return opt("intel_alerts", true) == true end

    local summary = {
        state = "NONE", state_why = "", state_conf = 0,
        threat = "INFORMATIONAL", threat_why = "", threat_score = 0,
        action = nil, action_why = "", action_conf = 0,
        move = "none", move_why = "", move_conf = 0,
        control = "", control_why = "",
        predictions = {},
        inputs = "",
        bait = "", bait_why = "",
        cooldowns = {}, suppressed = {}, unknown = {},
    }
    M.summary_table = summary

    local last_said = { state = nil, move = nil, at = -math.huge }
    local SAY_EVERY = 3.0     -- seconds between two alerts of this layer

    --- Gathers the tick's conclusions. Called after the state and the move.
    ---@param S table the picture
    ---@param now number
    function M.update(S, now)
        local T, X, Pm, C = S.threat, S.tactic, S.pos, S.cds
        summary.state, summary.state_why, summary.state_conf = X.state, X.why or "", X.conf or 0
        summary.threat, summary.threat_score = T.level, math.floor((T.score or 0) + 0.5)
        summary.threat_why = T.highest and T.highest.why or ""
        summary.action = X.actions and X.actions[1] or nil
        summary.action_why, summary.action_conf = X.why or "", X.conf or 0
        summary.move, summary.move_why, summary.move_conf = Pm.advice, Pm.why or "", Pm.conf or 0
        -- The target's observed cooldowns, as words.
        local cds = summary.cooldowns
        for i = #cds, 1, -1 do cds[i] = nil end
        if C.target then
            for name, e in pairs(C.target) do
                if e.state == "down" then
                    cds[#cds + 1] = string.format("%s back in %.0fs (%.1f)", name, e.ready_in or 0, e.conf_now or 0)
                elseif e.state == "ready" then
                    cds[#cds + 1] = string.format("%s likely back (%.1f)", name, e.conf_now or 0)
                else
                    cds[#cds + 1] = name .. ": cooldown unknown"
                end
            end
            table.sort(cds)
        end
        -- What was kept back, and what the client cannot say.
        local sup = summary.suppressed
        for i = #sup, 1, -1 do sup[i] = nil end
        for name, why in pairs(C.reserved or {}) do sup[#sup + 1] = string.format("%s kept: %s", name, why) end
        if C.answer and C.answer.verdict == "preserve" then sup[#sup + 1] = "a second defensive: " .. C.answer.why end
        for i = 1, #(X.avoid or {}) do sup[#sup + 1] = "avoid " .. X.avoid[i] end
        -- The control plan (Stage 6): the control on the target, whose, and
        -- what is held or why nothing is; the pet's recall among what is kept.
        local CC = S.cc
        local h = CC and CC.target and CC.target.held or nil
        if h then
            summary.control = string.format("%s %.1fs (%s)", h.name or "?", h.left or 0,
                h.ours == "yes" and "yours" or h.ours == "unknown" and "yours, caster unread" or "not yours")
            summary.control_why = CC.hold and ("hold: " .. CC.hold.why) or CC.doomed and ("no hold: " .. CC.doomed.why) or ""
        else
            summary.control, summary.control_why = "", ""
        end
        if CC and CC.pet and CC.pet.recall then sup[#sup + 1] = "the pet: " .. CC.pet.why end
        -- What the target tends to do (Stage 7): the surest first, a forming
        -- one marked as forming; never shown as a fact.
        local PR = S.predict
        local preds = summary.predictions
        for i = #preds, 1, -1 do preds[i] = nil end
        if PR and PR.target then
            local list = {}
            for _, e in pairs(PR.target) do list[#list + 1] = e end
            table.sort(list, function(a, b) return (a.p or 0) > (b.p or 0) end)
            for i = 1, math.min(3, #list) do
                local e = list[i]
                local state = e.adapting and ", adapting" or (e.sure and "" or ", forming")
                local tail = e.adapting and tostring(e.adapt_why) or (e.sure and (e.response or "") or e.why)
                preds[#preds + 1] = string.format("%s (p %.2f, reliability %s, n%.1f, %s%s)%s -- %s", e.v, e.p or 0,
                    e.label or "none", e.n or 0, e.basis or "?", e.data ~= "ok" and (", " .. tostring(e.data)) or "", state, tail)
            end
        end
        -- The inputs the predictor has seen this session (Forever: the feeds
        -- unverified until seen).
        local pm = lib.predict_inputs
        summary.inputs = pm and pm() or ""
        -- The bait (Stage 8): the one on the target, and the burst it holds.
        local BT = S.bait
        if BT and BT.target then
            summary.bait = string.format("%s (%.2f)", BT.target.v, BT.target.conf)
            summary.bait_why = BT.target.why or ""
        elseif BT and BT.blocked then
            summary.bait, summary.bait_why = "none", BT.blocked
        else
            summary.bait, summary.bait_why = "", ""
        end
        if BT and BT.hold_burst then sup[#sup + 1] = string.format("%s kept: a defensive bait -- %s", BT.hold_burst, BT.hold_why or "") end
        local unk = summary.unknown
        for i = #unk, 1, -1 do unk[i] = nil end
        for i = 1, #(T.unknown or {}) do unk[#unk + 1] = T.unknown[i] end
        for i = 1, #(CC and CC.unknown or {}) do unk[#unk + 1] = CC.unknown[i] end
        for i = 1, #(S.unavailable or {}) do unk[#unk + 1] = S.unavailable[i] end

        -- Alerts: a new state, or a new move with yards, once.
        if S.active and M.alerts_on() and P.narrate and P.narrate.say and (now - last_said.at) >= SAY_EVERY then
            local said = false
            if X.changed and X.state ~= last_said.state and X.state ~= "NONE" and X.state ~= "IDLE" then
                local sev = X.emergency and "warn" or "info"
                local text = X.why
                if X.actions and X.actions[1] then text = text .. " -- " .. X.actions[1] end
                pcall(P.narrate.say, sev, X.state:gsub("_", " "):lower(), text, "intel_state")
                last_said.state, said = X.state, true
            elseif Pm.advice ~= last_said.move and Pm.advice ~= "hold" and Pm.advice ~= "none" then
                pcall(P.narrate.say, "info", Pm.advice:gsub("_", " ") .. (Pm.direction ~= "" and (" " .. Pm.direction) or ""),
                    Pm.why, "intel_move")
                last_said.move, said = Pm.advice, true
            elseif PR and PR.alerts and PR.alerts[1] then
                -- A pattern just became a prediction (Stage 7): said once per
                -- player and pattern, as a guess with its confidence.
                local a = table.remove(PR.alerts, 1)
                pcall(P.narrate.say, "info", "prediction",
                    string.format("%s: %s (p %.2f, reliability %s, n%.1f)", tostring(a.name), tostring(a.text),
                        a.conf or 0, tostring(a.label or "?"), a.n or 0), "intel_predict")
                said = true
            end
            if said then last_said.at = now end
        end
        if not S.active then last_said.state, last_said.move = nil, nil end
        return summary
    end

    --- The tick's conclusions, for the window (Stage 5) and the tests.
    function M.summary() return summary end

    function M.reset()
        last_said.state, last_said.move, last_said.at = nil, nil, -math.huge
    end

    return M
end

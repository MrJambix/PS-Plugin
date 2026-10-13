-- Jambix AIO / react / intel / killwindow -- Stage 9 of PVP_INTEL_PLAN.md
-- (the brief's Phase 10, kill window analysis): is this player about to
-- die, or about to get away, and is this the moment to commit?
--
-- Until now a "kill window" was a player under 25% with no immunity up, at
-- half confidence (states.lua). This weighs what decides a kill:
--
--   its outs     the escapes and defensives of its class, from the cooldown
--                ledger: seen and back (ready), seen and running (down), or
--                never seen (unknown: counted as available, at a smaller
--                cost -- missing information never makes a kill surer)
--   its health   the fraction, and an effective one when a defensive or a
--                shield is up (data.PROTECTION / COVERS)
--   its heals    an enemy healer within reach of it and free; its own class
--                healing itself
--   our burst    Rapid Fire or Bestial Wrath ready; a damaging shot ready;
--                the mana to use them
--   our risk     the threat read (Stage 2), our health and time to live:
--                committing while we are the one in danger is the abort
--   the others   other players on us (a third party), allies on the target
--
-- One verdict per enemy player, as an inference { v, conf, why } with the
-- reasons and the recommended actions:
--   NO_KILL_OPPORTUNITY          nothing to take now (immune, high health)
--   BUILD_PRESSURE               keep the damage going (a defensive up, mid health)
--   FORCE_DEFENSIVE              make it spend its defensive before the burst
--   PREPARE_BURST                low, its escapes not seen ready: line the burst up
--   HIGH_CONFIDENCE_KILL_WINDOW  low, no out seen ready, our damage ready
--   ABORT_COMMITMENT             we are the one in danger: survive first
--
-- Who reads it: states.lua's KILL_WINDOW (its confidence and words),
-- burst.lua (a window opens on a kill window and waits on an abort or a
-- defensive to draw), the PvP hunter's "finish the low one" (a kill window,
-- not health alone), the conditions (target.kill_verdict, target.kill_conf).
-- Nothing here presses anything.

return function(P, lib, data, K)
    local book = P.spellbook
    local floor, max, min, huge, sqrt = math.floor, math.max, math.min, math.huge, math.sqrt
    local KK, RANK = K.KILL, K.RANK
    local sure = lib.sure

    local M = {}
    M.VERDICTS = { "NO_KILL_OPPORTUNITY", "BUILD_PRESSURE", "FORCE_DEFENSIVE", "PREPARE_BURST", "HIGH_CONFIDENCE_KILL_WINDOW", "ABORT_COMMITMENT" }

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end
    function M.enabled() return opt("intel_kill", true) == true end

    local function ready(name)
        return type(name) == "string" and book ~= nil and book.known(name) and book.ready(name)
    end

    local T = { target = nil, by_guid = {}, best = nil, at = -huge, line = "" }
    M.T = T
    local pool = {}

    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    --- Its outs of one kind (escapes or defensives), by the ledger's word.
    local function outs(S, f, names, into)
        into.ready, into.down, into.unknown = {}, {}, {}
        local cds = lib.cooldowns
        for i = 1, #(names or {}) do
            local name = names[i]
            local e = cds and cds.seen and cds.seen(S, f.guid, name) or nil
            local state = e and e.state or nil
            if state == "down" then into.down[#into.down + 1] = name
            elseif state == "ready" then into.ready[#into.ready + 1] = name
            else into.unknown[#into.unknown + 1] = name end
        end
        return into
    end

    local function dist2(a, b)
        if not (a and b and a.x and b.x) then return huge end
        local dx, dy = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0)
        return sqrt(dx * dx + dy * dy)
    end

    --- An enemy healer within reach of this player, free to cast.
    local function healer_near(S, f)
        for i = 1, #S.foe_list do
            local o = S.foe_list[i]
            if o ~= f and not o.dead then
                local role = o.inferred and sure(o.inferred.role, KK.healer_conf) or nil
                local held = (o.cc and o.cc.held) or o.control
                local dry = o.mana_pct ~= nil and o.mana_pct < KK.healer_dry
                if role == "healer" and not held and not dry and dist2(o, f) <= KK.heal_reach then return o end
            end
        end
        return nil
    end

    local function verdict_of(S, f, v)
        v.guid, v.name, v.class = f.guid, f.name, f.class
        local reasons, actions = v.reasons or {}, v.actions or {}
        for i = #reasons, 1, -1 do reasons[i] = nil end
        for i = #actions, 1, -1 do actions[i] = nil end
        v.reasons, v.actions = reasons, actions
        local hp = f.hp or 1
        v.hp = hp
        local st = f.st or {}
        local function say(kind, conf, act)
            v.v, v.conf = kind, max(0, min(1, conf))
            v.why = table.concat(reasons, "; ")
            for i = 1, #(act or {}) do actions[#actions + 1] = act[i] end
            return v
        end

        -- Nothing to take: dead, gone, immune.
        if f.dead then reasons[1] = f.name .. " is dead" return say("NO_KILL_OPPORTUNITY", 1) end
        if st.immune then
            reasons[1] = string.format("%s is immune (%s)", f.name, tostring(st.immune_name or st.immune))
            return say("NO_KILL_OPPORTUNITY", 0.95, { "shoot another", "keep your burst" })
        end

        -- Our risk first: committing while we are the one dying.
        local me = S.me
        local level = S.threat and S.threat.level or "INFORMATIONAL"
        local my_hp = me.hp or 1
        if RANK[level] >= RANK.CRITICAL or (my_hp <= KK.abort_hp and RANK[level] >= RANK.HIGH)
            or (me.ttl and me.ttl < KK.abort_ttl) then
            reasons[1] = string.format("you are at %d%% with the threat %s%s", pct(my_hp), level,
                me.ttl and me.ttl < huge and string.format(", %.0fs to live", me.ttl) or "")
            return say("ABORT_COMMITMENT", 0.85, { "a defensive", "distance", "Feign Death" })
        end

        -- Its outs.
        v.escapes = outs(S, f, f.class and data.CLASS_ESCAPES[f.class] or nil, v.escapes or {})
        v.defensives = outs(S, f, f.class and data.CLASS_DEFENSIVES[f.class] or nil, v.defensives or {})
        local up = st.avoid_name or (st.avoid and st.avoid ~= "" and tostring(st.avoid)) or nil
        -- Its heals.
        local healer = healer_near(S, f)
        local self_heal = f.class and data.SELF_HEALERS[f.class] == true and not ((f.cc and f.cc.held) or f.control)
        -- Ours.
        local burst = nil
        for name in pairs(data.OUR_BURSTS) do if ready(name) then burst = name break end end
        local shot = nil
        for i = 1, #KK.finishers do if ready(KK.finishers[i]) then shot = KK.finishers[i] break end end
        local mana_ok = not me.power_counted or (me.power_pct or 1) >= KK.min_power
        -- The others.
        local third, allies_on = 0, 0
        for i = 1, #S.foe_list do
            local o = S.foe_list[i]
            if o ~= f and o.targets_me and not o.dead then third = third + 1 end
        end
        for i = 1, #(S.ally_list or {}) do
            local a = S.ally_list[i]
            if a.target_guid == f.guid and not a.dead then allies_on = allies_on + 1 end
        end

        -- Effective health: what is up on it now.
        local cover = 0
        if up then
            local kind = data.PROTECTION[up]
            cover = kind and data.COVERS[kind] and (data.COVERS[kind].physical or 0) or 0.3
        end
        v.eff_hp = cover >= 1 and huge or hp / max(0.05, 1 - cover)

        -- The confidence: what stands against the kill, each a written cost.
        local conf = KK.base
        local unknown_outs = #v.escapes.unknown + #v.defensives.unknown
        conf = conf - KK.escape_ready * #v.escapes.ready - KK.defensive_ready * #v.defensives.ready
        conf = conf - KK.escape_unknown * #v.escapes.unknown - KK.defensive_unknown * #v.defensives.unknown
        -- A class the client did not name: its outs are all unknown, at once.
        if not f.class then conf = conf - KK.class_unknown end
        if healer then conf = conf - KK.healer_near end
        if self_heal then conf = conf - KK.self_heal end
        conf = conf - KK.third_party * third + KK.ally_on * min(allies_on, 2)
        if not (burst or shot) or not mana_ok then conf = conf - KK.no_damage end

        reasons[#reasons + 1] = string.format("%s at %d%%%s", f.name, pct(hp), v.eff_hp ~= hp and string.format(" (%s up: effective %d%%)", up, pct(min(v.eff_hp, 9.99))) or "")
        if #v.escapes.down + #v.defensives.down > 0 then
            local down = {}
            for _, n in ipairs(v.escapes.down) do down[#down + 1] = n end
            for _, n in ipairs(v.defensives.down) do down[#down + 1] = n end
            reasons[#reasons + 1] = table.concat(down, ", ") .. " down"
        end
        if #v.escapes.ready + #v.defensives.ready > 0 then
            local r = {}
            for _, n in ipairs(v.escapes.ready) do r[#r + 1] = n end
            for _, n in ipairs(v.defensives.ready) do r[#r + 1] = n end
            reasons[#reasons + 1] = table.concat(r, ", ") .. " ready"
        end
        if unknown_outs > 0 then reasons[#reasons + 1] = unknown_outs .. " of its outs never seen (counted as available)" end
        if not f.class then reasons[#reasons + 1] = "its class unread: its outs unknown" end
        if healer then reasons[#reasons + 1] = string.format("%s can heal it", healer.name) end
        if self_heal then reasons[#reasons + 1] = "it heals itself" end
        if third > 0 then reasons[#reasons + 1] = third .. " other player(s) on you" end
        if allies_on > 0 then reasons[#reasons + 1] = allies_on .. " ally(s) on it" end
        if not (burst or shot) then reasons[#reasons + 1] = "nothing of yours ready to finish it"
        elseif not mana_ok then reasons[#reasons + 1] = "too little mana to follow through" end

        -- The verdict.
        if up and cover > 0 then
            return say("BUILD_PRESSURE", conf, { "wait out its " .. up .. ": fillers and stings", "keep the burst" })
        end
        if hp <= KK.kill_hp then
            if #v.defensives.ready > 0 and hp > KK.no_time_hp then
                return say("FORCE_DEFENSIVE", conf, { "pressure to draw its " .. v.defensives.ready[1], "the burst after" })
            end
            if #v.escapes.ready == 0 and #v.defensives.ready == 0 and (burst or shot) and mana_ok and conf >= KK.high_conf then
                local act = {}
                if burst then act[#act + 1] = burst end
                if shot then act[#act + 1] = shot end
                act[#act + 1] = "Concussive Shot if it runs"
                return say("HIGH_CONFIDENCE_KILL_WINDOW", conf, act)
            end
            if #v.escapes.ready == 0 and (burst or shot) and mana_ok then
                return say("PREPARE_BURST", conf, { burst or shot, "a slow ready for its run" })
            end
            return say("BUILD_PRESSURE", conf, { "keep it low", "a slow for its escape" })
        end
        if hp <= KK.pressure_hp then
            if #v.defensives.ready > 0 then
                return say("FORCE_DEFENSIVE", conf, { "pressure to draw its " .. v.defensives.ready[1], "the burst after" })
            end
            if #v.escapes.ready == 0 and burst and mana_ok and conf >= KK.prepare_conf then
                return say("PREPARE_BURST", conf, { burst, shot or "Auto Shot", "a slow for its escape" })
            end
            return say("BUILD_PRESSURE", conf, { "keep the damage going" })
        end
        if hp <= KK.build_hp then return say("BUILD_PRESSURE", conf, { "keep the damage going" }) end
        reasons[#reasons + 1] = "not low enough to matter yet"
        return say("NO_KILL_OPPORTUNITY", min(conf, 0.6))
    end

    --- Once a tick (every KK.every seconds): a verdict for each enemy
    --- player in the picture, the target's, and the best other one.
    function M.update(W, S, now)
        if not M.enabled() then return M.reset() end
        if (now - T.at) < KK.every then return T end
        T.at = now
        for k in pairs(T.by_guid) do T.by_guid[k] = nil end
        T.target, T.best = nil, nil
        local tg = S.env and S.env.target and S.env.target.guid or nil
        for i = 1, min(#S.foe_list, KK.max_players) do
            local f = S.foe_list[i]
            local v = pool[i] or {}
            pool[i] = v
            verdict_of(S, f, v)
            T.by_guid[f.guid] = v
            if f.guid == tg then T.target = v
            elseif (v.v == "HIGH_CONFIDENCE_KILL_WINDOW" or v.v == "PREPARE_BURST") and (not T.best or v.conf > T.best.conf) then
                T.best = v
            end
        end
        local t = T.target
        T.line = t and string.format("kill: %s (%.2f) -- %s", t.v, t.conf, t.why) or ""
        S.kill = T
        return T
    end

    --- The verdict for a player by guid (burst.lua, the PvP hunter), or nil.
    function M.for_guid(guid)
        if not (guid and M.enabled()) then return nil end
        return T.by_guid[guid]
    end

    --- A player worth switching to: a kill window that is not the target.
    function M.best() return T.best end

    function M.reset()
        for k in pairs(T.by_guid) do T.by_guid[k] = nil end
        T.target, T.best, T.line, T.at = nil, nil, "", -huge
        return T
    end

    return M
end

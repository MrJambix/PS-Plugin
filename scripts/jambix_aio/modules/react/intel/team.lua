-- Jambix AIO / react / intel / team -- Stage 10 of PVP_INTEL_PLAN.md (the
-- brief's Phase 12, multiplayer): a fight with more than one player on a
-- side, read as a whole.
--
--   focus        whom the enemies are on: you, an ally (how many on each)
--   peel         an enemy on an ally who cannot afford it (the healer, an ally
--                under half health): the first control or slow of yours that
--                reaches it, from what is ready
--   interrupt    the casts worth stopping, in order: a heal on a low enemy, a
--                control at you or an ally, a dangerous cast at you or an
--                ally, the rest; the first that a stopper of yours reaches
--   switch       a better target than yours: a kill window on another player
--                (Stage 9), yours immune or held by an ally's control
--   healer       the enemy healer: free or held, and what pressures it
--   overlap      your control would land on a player an ally already holds
--                (friendly crowd control, off its auras' caster)
--   overextended in a group, your nearest ally far and several enemies near
--   disengage    outnumbered with nobody to fall back on
--   objectives   the battleground's flag carriers (no base data exists)
--
-- Advice and conditions only: nothing here presses anything. Allies'
-- cooldowns cannot be read, so only our own overlap is prevented. Retail
-- arena assumptions are not made; Forever's battleground rules are UNKNOWN.

return function(P, lib, data, K)
    local book = P.spellbook
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KT, RANK = K.TEAM, K.RANK
    local sure = lib.sure

    local M = {}

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end
    function M.enabled() return opt("intel_team", true) == true end

    local function ready(name) return type(name) == "string" and book ~= nil and book.known(name) and book.ready(name) end
    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local T = {
        active = false, at = -huge, focus = nil, peel = nil, interrupt = nil, casts = {}, switch = nil,
        healer = nil, overlap = nil, overextended = nil, disengage = nil, objectives = nil,
        allies_held = 0, line = "",
    }
    M.T = T

    --- The first of our tools (a control, a slow, a stopper) ready and in
    --- reach of the player: past its minimum range, the pet on it for the
    --- pet's. An unknown distance reaches nothing.
    local function tool_for(list, f, S)
        local d = f.dist
        if not d then return nil end
        for i = 1, #list do
            local t = list[i]
            if ready(t.name) then
                if t.pet then
                    if S.pet and S.pet.alive and S.pet.target_guid == f.guid then return t.name end
                elseif d <= t.reach and d >= (t.from or 0) then
                    return t.name
                end
            end
        end
        return nil
    end

    local function kind_of_cast(name)
        if not name or name == "" then return "unknown" end
        if data.HEALS[name] then return "heal" end
        if data.CONTROL_NAMES[name] then return "control" end
        return "damage"
    end

    local function held(f)
        local h = f.cc and f.cc.held or nil
        return h or f.control
    end

    function M.update(W, S, now)
        if not M.enabled() then return M.reset() end
        if (now - T.at) < KT.every then return T end
        T.at = now
        local foes, allies = S.foe_list or {}, S.ally_list or {}
        local in_group = #allies > 0
        T.active = in_group or #foes >= 2
        T.focus, T.peel, T.interrupt, T.switch, T.healer, T.overlap, T.overextended, T.disengage, T.objectives =
            nil, nil, nil, nil, nil, nil, nil, nil, nil
        for i = #T.casts, 1, -1 do T.casts[i] = nil end
        T.allies_held = 0
        if not T.active then T.line = "" return T end

        -- Focus: the friendly unit the most enemies are on.
        local on = { [S.me.guid or "me"] = 0 }
        for i = 1, #foes do
            local f = foes[i]
            if not f.dead then
                local k = f.targets_me and (S.me.guid or "me") or (f.targets_ally and f.target_guid) or nil
                if k then on[k] = (on[k] or 0) + 1 end
            end
        end
        local my_key = S.me.guid or "me"
        local best_k, best_n = my_key, on[my_key]
        for k, n in pairs(on) do if n > best_n then best_k, best_n = k, n end end    -- a tie stays on you
        if best_n >= KT.focus_min then
            local me = best_k == (S.me.guid or "me")
            local a = not me and S.allies[best_k] or nil
            T.focus = { guid = best_k, name = me and "you" or (a and a.name or "an ally"), on_me = me, attackers = best_n,
                        why = string.format("%d enemies on %s", best_n, me and "you" or (a and a.name or "an ally")) }
        end

        -- Peel: an enemy on an ally who cannot afford it.
        for i = 1, #foes do
            local f = foes[i]
            if f.targets_ally and not f.dead then
                local a = S.allies[f.target_guid]
                if a and not a.dead and (a.healer or (a.hp or 1) < KT.ally_low) and not held(f) then
                    local tool = tool_for(KT.peel_tools, f, S)
                    T.peel = { guid = f.guid, name = f.name, ally = a.name, ally_healer = a.healer == true, action = tool,
                               why = string.format("%s on %s (%s)%s", f.name, a.name, a.healer and "the healer" or (pct(a.hp) .. "%"),
                                   tool and (": " .. tool) or ": nothing of yours reaches it") }
                    break
                end
            end
        end

        -- Interrupts: every cast worth stopping, in order; the first a stopper reaches.
        for i = 1, #foes do
            local f = foes[i]
            local c = f.casting
            if c and not f.dead and (c.left or 0) > 0 then
                local kind = kind_of_cast(c.name)
                local target = c.at_me and "you" or (f.targets_ally and S.allies[f.target_guid] and S.allies[f.target_guid].name) or nil
                local score = 0
                if kind == "heal" then
                    -- A heal on a low enemy: the player it targets (its own
                    -- side), or itself; not targeting a foe, the lowest foe
                    -- stands in (an assumption, said in the line).
                    local healed = f.target_guid and S.foes[f.target_guid] or nil
                    local low = healed and (healed.hp or 1) or (f.hp or 1)
                    if not healed and (not f.target_guid or f.target_guid == f.guid) then
                        for j = 1, #foes do if not foes[j].dead then low = min(low, foes[j].hp or 1) end end
                    end
                    target = healed and healed.name or nil
                    score = KT.weight.heal + (1 - low) * KT.weight.heal_low
                elseif kind == "control" and target then score = KT.weight.control
                elseif kind == "damage" and target then score = KT.weight.damage + (c.danger or 0)
                else score = KT.weight.other end
                if c.interruptible == false then score = 0 end
                if score > 0 then
                    T.casts[#T.casts + 1] = { guid = f.guid, name = f.name, spell = c.name, kind = kind, left = c.left, at = target,
                                              score = score, dist = f.dist, tool = tool_for(KT.stoppers, f, S) }
                end
            end
        end
        table.sort(T.casts, function(a, b) return a.score > b.score end)
        for i = 1, #T.casts do
            if T.casts[i].tool then
                local c = T.casts[i]
                T.interrupt = c
                c.why = string.format("%s's %s%s (%s, %.1fs left): %s", c.name, c.spell, c.at and (" at " .. c.at) or "", c.kind, c.left or 0, c.tool)
                break
            end
        end

        -- Friendly crowd control: players an ally holds; our control on one of them would overlap.
        local tg = S.env.target.guid and S.foes[S.env.target.guid] or nil
        for i = 1, #foes do
            local h = foes[i].cc and foes[i].cc.held or nil
            if h and h.ours == "no" then T.allies_held = T.allies_held + 1 end
        end
        if tg then
            local h = tg.cc and tg.cc.held or nil
            if h and h.ours == "no" and h.breaks then
                T.overlap = { guid = tg.guid, name = tg.name, control = h.name,
                              why = string.format("%s on %s is an ally's: no control of yours on it, no damage either", h.name, tg.name) }
            end
        end

        -- Switch: a better target than yours. Another player is offered only
        -- in reach (Stage 14: the switch is pressed now), and over a target
        -- that is not itself a kill window only when its own is high
        -- confidence or it is clearly lower.
        local kw = S.kill
        local best = kw and kw.best or nil
        if best then
            local bf = S.foes[best.guid]
            if not (bf and (bf.dist or huge) <= KT.switch_reach) then best = nil end
        end
        local alt_kw = best
        if alt_kw and tg and alt_kw.v ~= "HIGH_CONFIDENCE_KILL_WINDOW" and not ((alt_kw.hp or 1) + KT.switch_margin < (tg.hp or 1)) then
            alt_kw = nil
        end
        kw = { best = best, target = kw and kw.target or nil }
        if tg and tg.st and tg.st.immune then
            local alt = kw and kw.best or nil
            T.switch = { guid = alt and alt.guid or nil, name = alt and alt.name or "another",
                         why = string.format("%s is immune (%s)%s", tg.name, tostring(tg.st.immune_name or tg.st.immune), alt and (": " .. alt.name .. " is a kill window") or "") }
        elseif T.overlap then
            local alt = kw and kw.best or nil
            T.switch = { guid = alt and alt.guid or nil, name = alt and alt.name or "another", why = T.overlap.why }
        elseif alt_kw and (not kw.target or (kw.target.v ~= "HIGH_CONFIDENCE_KILL_WINDOW" and kw.target.v ~= "PREPARE_BURST")) then
            T.switch = { guid = alt_kw.guid, name = alt_kw.name,
                         why = string.format("%s: %s at %d%%", alt_kw.name, alt_kw.v:lower():gsub("_", " "), pct(alt_kw.hp)) }
        end

        -- The enemy healer.
        for i = 1, #foes do
            local f = foes[i]
            local role = f.inferred and sure(f.inferred.role, KT.healer_conf) or nil
            if role == "healer" and not f.dead then
                local h = held(f)
                local pressure = nil
                if not h then
                    local tool = tool_for(KT.peel_tools, f, S)
                    if ready("Viper Sting") and f.dist and f.dist <= KT.sting_reach and f.dist >= 8 then pressure = "Viper Sting (its mana)"
                    elseif tool and kw and kw.best and kw.best.guid ~= f.guid then pressure = tool .. " on it while " .. kw.best.name .. " dies" end
                end
                T.healer = { guid = f.guid, name = f.name, free = not h, held_by = h and h.name or nil, action = pressure,
                             why = h and string.format("%s held (%s)", f.name, tostring(h.name)) or string.format("%s free to heal%s", f.name, pressure and (": " .. pressure) or "") }
                break
            end
        end

        -- Overextended, and the disengage.
        local enemies_near, on_me = 0, 0
        for i = 1, #foes do
            local f = foes[i]
            if not f.dead and (f.dist or huge) <= KT.near then enemies_near = enemies_near + 1 end
            if f.targets_me and not f.dead then on_me = on_me + 1 end
        end
        local nearest_ally, allies_near = huge, 0
        for i = 1, #allies do
            local a = allies[i]
            if not a.dead then
                nearest_ally = min(nearest_ally, a.dist or huge)
                if (a.dist or huge) <= KT.near then allies_near = allies_near + 1 end
            end
        end
        if in_group and nearest_ally > KT.ally_reach and enemies_near >= KT.overextend_enemies then
            T.overextended = { nearest = nearest_ally, enemies = enemies_near,
                               why = string.format("your nearest ally %s, %d enemies within %d yd: back toward them",
                                   nearest_ally < huge and string.format("%.0f yd away", nearest_ally) or "out of sight", enemies_near, KT.near) }
        end
        -- Outnumbered: more players on you than you and the allies near you.
        if on_me >= KT.disengage_on_me and (allies_near + 1) < on_me then
            T.disengage = { on_me = on_me, allies_near = allies_near,
                            why = string.format("%d on you, %d ally(s) near: break away%s", on_me, allies_near, in_group and " toward your group" or "") }
        end

        -- Objectives (a battleground's flags).
        local carriers = S.env.objectives and S.env.objectives.carriers or {}
        if #carriers > 0 then
            local enemy, ours = nil, nil
            for i = 1, #carriers do if carriers[i].enemy then enemy = carriers[i] else ours = carriers[i] end end
            T.objectives = { enemy_carrier = enemy and enemy.name or nil, our_carrier = ours and ours.name or nil,
                             why = enemy and (enemy.name .. " carries the flag: slow it, stop it") or (ours and (ours.name .. " carries ours: peel for them")) or "" }
        end

        local bits = {}
        if T.focus then bits[#bits + 1] = "focus: " .. T.focus.why end
        if T.peel then bits[#bits + 1] = "peel: " .. T.peel.why end
        if T.interrupt then bits[#bits + 1] = "stop: " .. T.interrupt.why end
        if T.switch then bits[#bits + 1] = "switch: " .. T.switch.why end
        if T.healer then bits[#bits + 1] = "healer: " .. T.healer.why end
        if T.overextended then bits[#bits + 1] = "overextended: " .. T.overextended.why end
        if T.disengage then bits[#bits + 1] = "disengage: " .. T.disengage.why end
        if T.objectives and T.objectives.why ~= "" then bits[#bits + 1] = "flag: " .. T.objectives.why end
        T.line = #bits > 0 and ("team: " .. table.concat(bits, " | ")) or ""
        return T
    end

    function M.line() return T.line ~= "" and T.line or nil end

    function M.reset()
        T.active, T.focus, T.peel, T.interrupt, T.switch, T.healer, T.overlap, T.overextended, T.disengage, T.objectives =
            false, nil, nil, nil, nil, nil, nil, nil, nil, nil
        for i = #T.casts, 1, -1 do T.casts[i] = nil end
        T.allies_held, T.line, T.at = 0, "", -huge
        return T
    end

    return M
end

-- Jambix AIO / react / intel / position -- where a hunter should stand
-- (PvP intelligence, Stage 4 / brief Phase 9).
--
-- A hunter's fight is a distance: inside five yards it trades Raptor
-- Strikes, from five to eight nothing lands at all, from eight to
-- thirty-five it shoots, and a warrior's Intercept reaches it anywhere from
-- eight to twenty-five. This reads the ground off the picture and says one
-- thing: hold, increase, reduce, strafe, break line of sight, regain it,
-- stay near the allies, avoid the reinforcements, or do not pursue -- with
-- the direction in words (away from X, towards Y), the yards, the reason,
-- and how sure. When the ground is not known (no sight ray, no positions),
-- the advice is directional and says so; no path is invented, and nothing
-- here moves the character (kite.lua's step out stays what it was).
--
-- Also the hunter's own: do not move inside Auto Shot's aim window, and
-- which aspect fits the moment (Monkey with a melee player on you, Hawk
-- otherwise), offered through the Aspects window's own gate
-- (rot_hunter_auto_aspect) by rules/intel.lua.

return function(P, lib, data, K)
    local book = P.spellbook
    local M = {}
    local huge, max, min = math.huge, math.max, math.min
    local KP = K.POSITION
    local RANK = K.RANK

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function H() return (P.rotation and P.rotation.helpers) or {} end

    local SLOWS = { "Wing Clip", "Improved Wing Clip", "Concussive Shot", "Frost Trap Aura", "Entrapment", "Counterattack" }
    local function slowed(unit)
        local h = H()
        if not unit or not h.debuff_up then return false end
        for i = 1, #SLOWS do
            if try(h.debuff_up, unit, SLOWS[i]) == true then return true end
        end
        return false
    end

    local function held(unit)
        local ph = P.pvphunter
        if not (ph and ph.held and unit) then return nil end
        local ok, kind = pcall(ph.held, unit)
        return ok and kind or nil
    end

    local T = {
        advice = "none", direction = "", target = nil, yards = nil, why = "no PvP", conf = 0,
        zone = nil, wait_for_shot = false, aspect = nil, aspect_why = nil, current_aspect = nil,
        closer = nil, closer_band = nil, third_parties = 0, los = nil,
    }
    M.T = T

    --- A melee player's gap-closer band, from the client's tables through
    --- the ledger's fact(): the widest [min, range] of the closers its
    --- class has, unless the ledger says that closer is down.
    local function closer_band(f, S)
        local cds = lib.cooldowns
        if not (cds and cds.fact) then return nil end
        local lo, hi, names, down = huge, 0, {}, nil
        local fighting = f.in_combat or f.targets_me or f.targets_pet
        for mob, info in pairs(data.MOBILITY) do
            -- A closer that cannot be used in combat (Charge) is no reach on
            -- a player already fighting.
            if info.closes and not (info.out_of_combat and fighting) then
                -- Only a closer of ITS class: fact() falls back to any class.
                local row, cls = cds.fact(mob, f.class)
                if row and cls == f.class and (row.range or 0) > 0 then
                    local e = f.cds and f.cds[mob] or nil
                    if e and e.state == "down" then
                        down = down or { name = mob, left = e.ready_in or 0 }
                    else
                        lo, hi = min(lo, row.min or 0), max(hi, row.range)
                        names[#names + 1] = mob
                    end
                end
            end
        end
        if hi <= 0 then return nil, down end
        table.sort(names)
        return { lo = lo, hi = hi, name = table.concat(names, "/") }, down
    end

    function M.update(W, S, now)
        local me, env = S.me, S.env
        T.zone = env.target.zone
        T.wait_for_shot = false
        T.aspect, T.aspect_why = nil, nil
        T.closer, T.closer_band, T.los = nil, nil, env.target.los and env.target.los.value or nil
        T.current_aspect = (me.buffs and me.buffs["Aspect of the Monkey"] and "Aspect of the Monkey")
            or (me.buffs and me.buffs["Aspect of the Hawk"] and "Aspect of the Hawk")
            or (me.buffs and me.buffs["Aspect of the Cheetah"] and "Aspect of the Cheetah") or nil

        if not S.active then
            T.advice, T.direction, T.target, T.yards, T.why, T.conf = "none", "", nil, nil, S.why or "no PvP", 0
            return T
        end

        local tg = env.target.guid and S.foes[env.target.guid] or nil
        local melee_range = env.melee_range or 5
        local min_ranged = env.min_ranged
        local max_ranged = env.max_ranged
        local threat = S.threat
        local conf = 0.9

        -- The nearest melee player on you, in melee.
        local melee_on_me = nil
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if f.targets_me and f.dist <= melee_range + 1 and (not melee_on_me or f.dist < melee_on_me.dist) then melee_on_me = f end
        end
        -- Players about that are not on you.
        local third = 0
        for i = 1, #S.foe_list do
            local f = S.foe_list[i]
            if not f.targets_me and not f.targets_pet then third = third + 1 end
        end
        T.third_parties = third
        -- The nearest ally.
        local ally_dist = huge
        for i = 1, #S.ally_list do ally_dist = min(ally_dist, S.ally_list[i].dist or huge) end

        local advice, direction, target, yards, why = "hold", "", tg and tg.name or nil, nil, "nothing to change"

        if me.control and me.control.helpless then
            advice, why = "none", "controlled: " .. tostring(me.control.name or me.control.kind)
        elseif melee_on_me and not slowed(melee_on_me.unit) and not held(melee_on_me.unit) then
            advice, target = "hold", melee_on_me.name
            why = melee_on_me.name .. " in melee and not slowed: running gains nothing, slow it first"
        elseif tg and (T.zone == "melee" or T.zone == "dead_zone") and (slowed(tg.unit) or held(tg.unit)) and min_ranged then
            advice, direction, yards = "increase", "away from " .. tg.name, min_ranged + KP.step_out_margin
            why = string.format("%s %s: step out past %.0f yd to shoot", tg.name, held(tg.unit) and "held" or "slowed", yards)
        elseif tg and T.zone == "far" and RANK[threat.level] < RANK.HIGH and max_ranged then
            advice, direction, yards = "reduce", "towards " .. tg.name, max_ranged
            why = string.format("%s past your bow: close to %.0f yd", tg.name, max_ranged)
        elseif tg and T.los == false then
            if RANK[threat.level] >= RANK.HIGH and tg.inferred.role.v == "caster" then
                advice, why = "hold", tg.name .. " cannot see you: keep it that way while the threat is " .. threat.level
            else
                advice, direction, why = "regain_los", "towards " .. tg.name, tg.name .. " out of your sight: step clear to shoot"
            end
        elseif tg and T.zone == "ranged" and tg.inferred.role.v == "melee" and tg.inferred.role.conf >= 0.6 then
            local band, down = closer_band(tg, S)
            T.closer_band, T.closer = band, down
            if band and tg.dist >= band.lo and tg.dist <= band.hi then
                advice, direction, yards = "increase", "away from " .. tg.name, band.hi + 1
                why = string.format("%s reaches %.0f-%.0f yd on %s: past %.0f or inside %.0f", band.name, band.lo, band.hi, tg.name, band.hi, band.lo)
                conf = min(conf, tg.inferred.role.conf)
            elseif down then
                advice, why = "hold", string.format("%s's %s down for %.0fs: shoot", tg.name, down.name, down.left)
            elseif third >= 2 then
                advice, direction, why = "avoid_reinforcements", "away from the others", string.format("%d other players about", third)
            end
        elseif third >= 2 and RANK[threat.level] >= RANK.MODERATE then
            advice, direction, why = "avoid_reinforcements", "away from the others", string.format("%d other players about", third)
        elseif S.in_group and ally_dist > KP.allies_near and RANK[threat.level] >= RANK.MODERATE then
            advice, direction, why = "stay_near_allies", "towards your group", string.format("nearest ally %.0f yd off, threat %s", ally_dist, threat.level)
        elseif tg and tg.closing < -KP.fleeing_speed and tg.hp < 0.5 and third >= 1 then
            advice, why = "do_not_pursue", string.format("%s getting away at %d%% with %d other(s) about", tg.name, math.floor(tg.hp * 100 + 0.5), third)
        end

        -- Forever's ray sees through trees: a "clear" there is less sure.
        if T.los ~= nil and S.client.forever then conf = min(conf, KP.forever_los_conf) end
        if T.los == nil and tg then conf = min(conf, 0.8) end

        -- Auto Shot's aim window: a move now costs the shot.
        if advice == "increase" or advice == "reduce" or advice == "regain_los" or advice == "strafe" then
            local weave = P.weave
            local nxt = weave and weave.next_shot_in and try(weave.next_shot_in) or nil
            if type(nxt) == "number" and nxt >= 0 and nxt <= KP.aim_window and me.shooting then
                T.wait_for_shot = true
                why = why .. string.format(" (after the shot, %.1fs)", nxt)
            end
        end

        -- The aspect for the moment, offered through the window's own gate.
        if melee_on_me and book.known("Aspect of the Monkey") and T.current_aspect ~= "Aspect of the Monkey" then
            T.aspect, T.aspect_why = "Aspect of the Monkey", melee_on_me.name .. " in melee with you"
        elseif not melee_on_me and T.current_aspect == "Aspect of the Monkey" and book.known("Aspect of the Hawk") and tg then
            T.aspect, T.aspect_why = "Aspect of the Hawk", "nobody in melee: back to shooting"
        end

        T.advice, T.direction, T.target, T.yards, T.why, T.conf = advice, direction, target, yards, why, conf
        return T
    end

    function M.reset()
        T.advice, T.direction, T.target, T.yards, T.why, T.conf = "none", "", nil, nil, "reset", 0
        T.aspect, T.wait_for_shot = nil, false
    end

    --- "move: increase (away from Enemy) past 26 yd: Intercept reaches 8-25 yd... (0.90) | aspect: Monkey (Enemy in melee)"
    function M.line()
        if T.advice == "none" and T.conf == 0 then return nil end
        local parts = {}
        local head = "move: " .. T.advice
        if T.direction ~= "" then head = head .. " (" .. T.direction .. ")" end
        if T.yards then head = head .. string.format(" past %.0f yd", T.yards) end
        parts[#parts + 1] = string.format("%s: %s (%.2f)", head, T.why, T.conf or 0)
        if T.aspect then parts[#parts + 1] = string.format("aspect: %s (%s)", T.aspect:gsub("Aspect of the ", ""), T.aspect_why or "") end
        return table.concat(parts, " | ")
    end

    return M
end

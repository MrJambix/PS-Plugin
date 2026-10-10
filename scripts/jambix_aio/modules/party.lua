-- Jambix AIO / party -- your group's health and its loose mobs, on the ground (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "Group and healing".
--
--   HEALTH      a ring under each party member filling red as their health
--               drops (missing health, amber to red), from the first point
--               lost. You are left out: your own bar is where you look.
--   HEAL THEM   the member lowest on health under "Heal at" (50%): a green
--               curtain round them. A pulse under anyone who drops below a
--               third, once until they are back over 60%.
--   LOOSE MOBS  a mob in a fight on a party member who is not the tank: an
--               orange curtain round it, and a pulse the first time. With no
--               tank known (Era players rarely set a role; "Assist the tank"
--               keeps one) only what is on a healer counts -- and when you
--               are the tank, everything on anyone else.
--
-- Nothing at all out of a group.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local LOW = 0.34             -- a pulse under this
    local RECOVERED = 0.6        -- and again only once back over this
    local LOOSE_MAX = 4

    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local C = {
        band = color(0, 0, 0, 100), hurt = color(240, 180, 60), dying = color(240, 60, 50),
        heal = color(110, 230, 140), heal_top = color(110, 230, 140, 30), low_pulse = color(240, 80, 60, 230),
        loose = color(245, 140, 50), loose_top = color(245, 140, 50, 30), loose_pulse = color(245, 160, 70, 230),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and units.guid(obj)) or ask(obj.get_guid, obj)
    end

    local function guid_set(list)
        local set = {}
        if type(list) == "table" then
            for i = 1, #list do
                local g = guid_of(list[i])
                if g then set[g] = true end
            end
        end
        return set
    end

    local low_seen = {}          -- member guid -> true once pulsed
    local loose_seen = {}        -- mob guid -> true once pulsed
    local stats = { rings = 0, heal = false, loose = 0 }

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.rings, stats.heal, stats.loose = 0, false, 0
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        if not opt("party_on", true) then return end
        local group = ctx.group
        local members = group and ask(group.objects)
        if type(members) ~= "table" or #members <= 1 then return end
        local me = units.player and units.player()
        local my_guid = guid_of(me)
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100

        local tanks = guid_set(ask(group.tanks))
        local assist = P.assist and P.assist.state
        if next(tanks) == nil and assist and assist.tank_guid then tanks[assist.tank_guid] = true end
        local healers = guid_set(ask(group.healers))
        local i_tank = (my_guid and tanks[my_guid]) or ask(group.is_tank, me) == true

        -- HEALTH and HEAL THEM.
        local heal_at = (tonumber(opt("party_heal_at", 50)) or 50) / 100
        local with_self = opt("party_self", false)
        local worst, worst_hp, worst_pos = nil, heal_at, nil
        local in_group = {}
        for i = 1, #members do
            local obj = members[i]
            local g = guid_of(obj)
            if g then in_group[g] = true end
            if g and (g ~= my_guid or with_self) then
                local hp = tonumber(units.health_fraction and units.health_fraction(obj)) or 1
                local pos = hp > 0 and units.position and units.position(obj) or nil
                if pos then
                    if opt("party_rings", true) and hp < 0.98 then
                        draw.ring_3d(pos, 1.2, 1 - hp, C.hurt, { to = C.dying, bg = C.band, inner = 0.8, layer = layer,
                            unit = obj, lane = "party", prio = hp < LOW and "warn" or "info", module = "party" })
                        stats.rings = stats.rings + 1
                    end
                    if hp < worst_hp then worst, worst_hp, worst_pos = obj, hp, pos end
                    if hp < LOW and not low_seen[g] then
                        low_seen[g] = true
                        if draw.pulse then
                            draw.pulse(obj, C.low_pulse, { life = 0.9, from = 0.8, to = 3.2, prio = "warn", module = "party" })
                        end
                    elseif hp > RECOVERED then
                        low_seen[g] = nil
                    end
                end
            end
        end
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        if worst and opt("party_heal_curtain", false) and draw.curtain_3d then
            draw.curtain_3d(worst_pos, 1.3, C.heal, { unit = worst, prio = "warn", module = "party",
                to = C.heal_top, height = 2.2, points = 24, rings = 3,
                fill = 0.3, speed = 1.2, spin = 0.8, layer = layer })
            stats.heal = true
        end

        -- LOOSE MOBS.
        if opt("party_loose", false) and draw.curtain_3d then
            local rows = ask(ctx.enemies and ctx.enemies.all)
            local tank_known = next(tanks) ~= nil
            if type(rows) == "table" then
                for i = 1, #rows do
                    if stats.loose >= LOOSE_MAX then break end
                    local r = rows[i]
                    local victim = r and r.in_combat and not r.dead and r.target_guid
                    if victim and victim ~= my_guid and in_group[victim] and not tanks[victim]
                        and (tank_known or i_tank or healers[victim]) then
                        local pos = units.position and units.position(r.obj)
                        if pos then
                            local reach = tonumber(units.combat_reach and units.combat_reach(r.obj)) or 1.5
                            draw.curtain_3d(pos, max(1, reach + 0.5), C.loose, { unit = r.obj, prio = "warn",
                                module = "party", to = C.loose_top, height = 2.2,
                                points = 24, rings = 3, fill = 0.3, speed = 1.8, spin = 1.2, lod = true, layer = layer })
                            stats.loose = stats.loose + 1
                            if r.guid and not loose_seen[r.guid] then
                                loose_seen[r.guid] = true
                                if draw.pulse then
                                    draw.pulse(r.obj, C.loose_pulse, { life = 0.9, from = 1, to = 4, prio = "warn", module = "party" })
                                end
                            end
                        end
                    elseif r and r.guid and loose_seen[r.guid] then
                        -- Back on the tank, or out of the fight: the next time
                        -- it breaks loose is news again.
                        loose_seen[r.guid] = nil
                    end
                end
            end
        end
    end

    function M.stats() return stats end

    return M
end

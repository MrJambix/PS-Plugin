-- Jambix AIO / groupextras -- the rest of what a group needs on the ground (1.89.0).
--
-- The user, 2026-10-09, choosing the world marks' next step: "Group extras"
-- -- out-of-heal-range rings, a tank threat curtain, healer mana,
-- stack/spread markers. modules/party.lua already rings the hurt, curtains
-- the one to heal and the loose mobs; this adds the rest:
--
--   OUT OF REACH  under each party member further from you than your heal
--                 range, a grey ring (the "reach" lane, just outside their
--                 health ring). Only when you can heal: a priest, paladin,
--                 druid or shaman, in any spec -- a hybrid's heal is still a
--                 heal. The range is your heals' own: the class window's
--                 "Heal range", which automatic tuning works out from your
--                 heal spells; "Heal range" here when the class says nothing.
--   THE TANK'S HOLD  in a fight, a curtain round the group's tank: green
--                 while every mob on the group is on the tank with room to
--                 spare, amber when someone is within a fifth of pulling one
--                 (80% on JCore's threat boards), red when one is on someone
--                 else in the group. Where the client reads no threat
--                 (Forever: every read is 0) a board is only who the mob is
--                 hitting, which still says on the tank or off it -- but
--                 never amber.
--   HEALER MANA   under each healer in the group but you, a blue ring
--                 filling with their mana, red under a fifth. The healers
--                 are the group's roles; where nobody is set as a healer
--                 (Era, mostly), every priest, druid, shaman and paladin who
--                 is not the tank. A member whose mana reads 0 of 0 (Forever's
--                 client so far) gets no ring rather than an empty one.
--   STACK / SPREAD  not drawn: nothing JCore can read says it. BigWigs' and
--                 ExBoss' bars are a label and a countdown -- not who, not
--                 where, not "stack". DBM's "stack up" and "spread out" voice
--                 cues reach JCore only through the telegraph data, which is
--                 not extracted on this install, holds fifteen such cues in
--                 all of Classic's raids, and mostly means "it is on you,
--                 move away", not "everybody spread".
--
-- The tank is the group's role, else "Assist the tank"'s, else you when that
-- says you are it. With none known, no curtain. Nothing at all out of a group.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local ROLES_EVERY = 2.0      -- seconds: whether you heal, and how far
    local HOLD_EVERY = 0.2       -- the tank's hold, five times a second
    local MANA_EVERY = 0.5       -- a healer's mana, twice a second each
    local MAX_EVERY = 5.0        -- the size of their pool (and a retry when it read 0)
    local MANA_READS = 2         -- healers read in one frame, at most
    local CLOSE, CLEAR = 80, 75  -- percent: the runner-up this high turns it amber, and under CLEAR green again
    local OFF_HOLD = 0.6         -- seconds a mob off the tank keeps it red (a mob turning to a caster mid-cast)
    local LOW_MANA = 0.2
    local TANKS_MAX = 2
    local TANK_GAP = 1.6         -- yards outside the tank's model edge: past the mana lane
    local RING_BAND = 0.2        -- yards of ring inside a lane's band
    local SWEEP_EVERY = 30
    -- The world layer's lanes, for a draw without it (an older AIO).
    local BAND, LANE = 0.25, { reach = 0.7, mana = 1.05 }
    -- Paladin, priest, shaman, druid: the classes with a heal.
    local HEAL_CLASS = { [2] = true, [5] = true, [7] = true, [11] = true }

    local SAFE, NEAR, OFF = 1, 2, 3
    local WORD = { [SAFE] = "held", [NEAR] = "close", [OFF] = "off" }

    local function clock() return core.time() end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local C = {
        reach = color(165, 165, 175, 210), reach_band = color(120, 120, 130, 60),
        mana = color(70, 150, 245), mana_low = color(240, 70, 60), mana_band = color(0, 0, 0, 100),
    }
    -- The tank's curtain: its foot, and its top.
    local HOLD_COL = {
        [SAFE] = { color(90, 220, 120), color(90, 220, 120, 25) },
        [NEAR] = { color(245, 190, 60), color(245, 190, 60, 30) },
        [OFF] = { color(240, 70, 60), color(240, 70, 60, 35) },
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and ask(units.guid, obj)) or ask(obj.get_guid, obj)
    end

    local function alive(obj)
        local hp = tonumber(units.health_fraction and ask(units.health_fraction, obj)) or 1
        return hp > 0
    end

    --- The model's edge under a unit, as the ESP and the world layer measure it.
    local function edge(unit)
        local reach = tonumber(units.combat_reach and ask(units.combat_reach, unit)) or 1.2
        return min(4, max(0.9, reach + 0.3))
    end

    --- A lane's outer radius under a unit: the world layer's, else the same sum.
    local function lane_radius(draw, unit, lane)
        if type(draw.lane_radius) == "function" then
            local r = tonumber(ask(draw.lane_radius, unit, lane))
            if r then return r end
        end
        return edge(unit) + (LANE[lane] or 0) + BAND
    end

    -- Options tables, one per mark slot, kept from frame to frame: the world
    -- layer reads them at its flush in the same frame and lets them go.
    local function slot(pool, i)
        local o = pool[i]
        if not o then
            o = {}
            pool[i] = o
        end
        return o
    end
    local reach_opts, mana_opts, tank_opts = {}, {}, {}

    -- --- who you are ------------------------------------------------------------

    local roles = { at = -1e9, healer = false, range = 40 }

    local function refresh_roles(me, group, now)
        if now - roles.at < ROLES_EVERY then return end
        roles.at = now
        local fallback = tonumber(opt("groupx_heal_range", 40)) or 40
        local rot = P.rotation
        local cm = rot and ask(rot.active_class)
        local can
        if type(cm) == "table" then
            can = cm.heal_capable == true
        else
            cm = nil
            local id = tonumber(ctx.player and ask(ctx.player.class_id))
            if not id or id == 0 then id = tonumber(me and ask(me.get_class, me)) end
            can = id ~= nil and HEAL_CLASS[id] == true
        end
        if not can and ask(group.is_healer, me) == true then can = true end
        roles.healer = can
        local range = fallback
        if cm and cm.heal_capable and P.tune_secs then
            range = tonumber(ask(P.tune_secs, "rot_heal_range", fallback)) or fallback
        end
        roles.range = range
    end

    -- --- the group ----------------------------------------------------------------

    local in_group = {}          -- guid -> true, this frame
    local tank_set = {}          -- guid -> true, this frame
    local tanks, healers = {}, {}
    local class_of = {}          -- guid -> class id, or false

    local function clear(t) for k in pairs(t) do t[k] = nil end end
    local function trim(list, n) for i = #list, n + 1, -1 do list[i] = nil end end

    local function find_tanks(group, me)
        clear(tank_set)
        local n = 0
        local list = ask(group.tanks)
        if type(list) == "table" then
            for i = 1, #list do
                if n >= TANKS_MAX then break end
                if list[i] then
                    n = n + 1
                    tanks[n] = list[i]
                end
            end
        end
        if n == 0 then
            -- No role set: "Assist the tank" may have found one (or you).
            local st = P.assist and P.assist.state
            if type(st) == "table" then
                if st.tank_guid then
                    tank_set[st.tank_guid] = true
                    local obj = st.tank or (units.by_guid and ask(units.by_guid, st.tank_guid))
                    if obj then
                        n = 1
                        tanks[1] = obj
                    end
                elseif st.why == "you are the tank" and me then
                    n = 1
                    tanks[1] = me
                end
            end
        end
        trim(tanks, n)
        for i = 1, n do
            local g = guid_of(tanks[i])
            if g then tank_set[g] = true end
        end
        return n
    end

    local function find_healers(group, members, my_guid)
        local n = 0
        local list = ask(group.healers)
        local any = false
        if type(list) == "table" then
            for i = 1, #list do
                local obj = list[i]
                any = true
                if obj and guid_of(obj) ~= my_guid then
                    n = n + 1
                    healers[n] = obj
                end
            end
        end
        if not any then
            -- Nobody is set as a healer: whoever can heal, but not the tank.
            for i = 1, #members do
                local obj = members[i]
                local g = guid_of(obj)
                if g and g ~= my_guid and not tank_set[g] then
                    local id = class_of[g]
                    if id == nil then
                        id = tonumber(ask(obj.get_class, obj)) or false
                        class_of[g] = id
                    end
                    if id and HEAL_CLASS[id] then
                        n = n + 1
                        healers[n] = obj
                    end
                end
            end
        end
        trim(healers, n)
        return n
    end

    -- --- the tank's hold ----------------------------------------------------------

    local hold = { at = -1e9, state = nil, off_until = -1e9, mobs = 0 }
    local seen = {}              -- mob guid -> true: a board said who holds it

    --- SAFE, NEAR, OFF or nil (no mob on the group), five times a second.
    local function read_hold(now)
        if now - hold.at < HOLD_EVERY then return hold.state end
        hold.at = now
        clear(seen)
        local worst, mobs = 0, 0
        local line = hold.state == NEAR and CLEAR or CLOSE
        local th = ctx.threat
        local boards = th and ask(th.boards)
        if type(boards) == "table" then
            for i = 1, #boards do
                local b = boards[i]
                local holder = type(b) == "table" and b.tank or nil
                if type(b) == "table" and b.guid and (holder or b.outside_tank) then seen[b.guid] = true end
                if holder and holder.guid then
                    local s = 0
                    if tank_set[holder.guid] then
                        -- An inferred board (no threat read) has no runner-up.
                        local runner = (not holder.inferred) and tonumber(b.next_percent) or nil
                        s = (runner and runner >= line) and NEAR or SAFE
                    elseif in_group[holder.guid] then
                        s = OFF
                    end
                    if s > 0 then mobs = mobs + 1 end
                    if s > worst then worst = s end
                end
            end
        end
        -- What no board covers: who each mob in a fight is hitting.
        local rows = ctx.enemies and ask(ctx.enemies.all)
        if type(rows) == "table" then
            for i = 1, #rows do
                local r = rows[i]
                local tg = type(r) == "table" and r.in_combat and not r.dead and r.activity ~= "dead" and r.target_guid
                if tg and not (r.guid and seen[r.guid]) then
                    local s = (tank_set[tg] and SAFE) or (in_group[tg] and OFF) or 0
                    if s > 0 then mobs = mobs + 1 end
                    if s > worst then worst = s end
                end
            end
        end
        if worst == OFF then
            hold.off_until = now + OFF_HOLD
        elseif worst > 0 and now < hold.off_until then
            worst = OFF
        end
        hold.state = worst > 0 and worst or nil
        hold.mobs = mobs
        return hold.state
    end

    -- --- healer mana ------------------------------------------------------------

    local mana = {}              -- guid -> { at, max, max_at, frac }
    local reads_left = 0

    --- A member's mana as 0..1, nil when the client reads no pool.
    local function mana_of(obj, g, now)
        local c = mana[g]
        if c and now - c.at < MANA_EVERY then return c.frac end
        if reads_left <= 0 then return c and c.frac end
        reads_left = reads_left - 1
        if not c then
            c = { at = 0, max = 0, max_at = -1e9 }
            mana[g] = c
        end
        c.at = now
        if now - c.max_at >= MAX_EVERY then
            c.max = tonumber(ask(obj.get_max_power, obj, 0)) or 0
            c.max_at = now
        end
        c.frac = nil
        if c.max > 0 then
            local cur = tonumber(ask(obj.get_power, obj, 0))
            if cur then c.frac = min(1, max(0, cur / c.max)) end
        end
        return c.frac
    end

    local swept_at = 0
    local function sweep(now)
        if now - swept_at < SWEEP_EVERY then return end
        swept_at = now
        for g in pairs(mana) do if not in_group[g] then mana[g] = nil end end
        for g in pairs(class_of) do if not in_group[g] then class_of[g] = nil end end
    end

    -- --- drawing --------------------------------------------------------------------

    local stats = { reach = 0, mana = 0, tank = nil, tanks = 0, mobs = 0, healer = false, range = 40 }

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.reach, stats.mana, stats.tank, stats.tanks, stats.mobs = 0, 0, nil, 0, 0
        local jd = P.draw
        if not (jd and jd.ring_3d) then return end
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or jd
        if not draw.ring_3d then return end
        if not opt("groupx_on", true) then return end
        local group = ctx.group
        local members = group and ask(group.objects)
        if type(members) ~= "table" or #members <= 1 then return end
        local me = units.player and units.player()
        local my_guid = guid_of(me)
        local now = clock()
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100

        clear(in_group)
        for i = 1, #members do
            local g = guid_of(members[i])
            if g then in_group[g] = true end
        end
        if my_guid then in_group[my_guid] = true end
        sweep(now)

        -- OUT OF REACH.
        if opt("groupx_range", true) then
            refresh_roles(me, group, now)
            stats.healer, stats.range = roles.healer, roles.range
            if roles.healer then
                local range = roles.range
                for i = 1, #members do
                    local obj = members[i]
                    local g = guid_of(obj)
                    if g and g ~= my_guid then
                        local d = tonumber(units.distance and ask(units.distance, obj))
                        if d and d > range and d < 1e6 and alive(obj) then
                            local pos = units.position and ask(units.position, obj)
                            if pos then
                                local r = lane_radius(draw, obj, "reach")
                                stats.reach = stats.reach + 1
                                local o = slot(reach_opts, stats.reach)
                                o.bg, o.inner, o.outer, o.layer = C.reach_band, max(0.5, 1 - RING_BAND / r), 1.0, layer
                                o.unit, o.lane, o.prio, o.module = obj, "reach", "info", "reach"
                                draw.ring_3d(pos, r, 1, C.reach, o)
                            end
                        end
                    end
                end
            end
        end

        local ntanks = find_tanks(group, me)

        -- THE TANK'S HOLD.
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        if opt("groupx_tank", false) and jd.curtain_3d and draw.curtain_3d and ntanks > 0 then
            local state = read_hold(now)
            stats.tank, stats.mobs = state and WORD[state] or nil, hold.mobs
            if state then
                local col, top = HOLD_COL[state][1], HOLD_COL[state][2]
                for i = 1, ntanks do
                    local t = tanks[i]
                    local pos = alive(t) and units.position and ask(units.position, t)
                    if pos then
                        stats.tanks = stats.tanks + 1
                        local o = slot(tank_opts, stats.tanks)
                        o.to, o.height, o.points, o.rings, o.fill = top, 1.4, 24, 3, 0.2
                        o.speed, o.spin, o.lod, o.layer = 1.0, 0.6, true, layer
                        -- Not under yourself: no lane, and no wall between you and you.
                        o.unit = guid_of(t) ~= my_guid and t or nil
                        o.prio, o.module = state == SAFE and "info" or "warn", "tank"
                        draw.curtain_3d(pos, edge(t) + TANK_GAP, col, o)
                    end
                end
            end
        end

        -- HEALER MANA.
        if opt("groupx_mana", true) then
            local n = find_healers(group, members, my_guid)
            reads_left = MANA_READS
            for i = 1, n do
                local obj = healers[i]
                local g = guid_of(obj)
                if g and alive(obj) then
                    local frac = mana_of(obj, g, now)
                    local pos = frac and units.position and ask(units.position, obj)
                    if pos then
                        local low = frac < LOW_MANA
                        local col = low and C.mana_low or C.mana
                        local r = lane_radius(draw, obj, "mana")
                        stats.mana = stats.mana + 1
                        local o = slot(mana_opts, stats.mana)
                        o.to, o.bg, o.inner, o.outer, o.layer = col, C.mana_band, max(0.5, 1 - RING_BAND / r), 1.0, layer
                        o.unit, o.lane, o.prio, o.module = obj, "mana", low and "warn" or "info", "mana"
                        draw.ring_3d(pos, r, frac, col, o)
                    end
                end
            end
        end
    end

    function M.stats() return stats end

    return M
end

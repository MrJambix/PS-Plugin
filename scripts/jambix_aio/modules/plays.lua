-- Jambix AIO / plays -- your reactions about to fire and the rotation's pick,
-- on the ground (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "Rotations and Reactions".
--
--   ABOUT TO FIRE  a reaction of yours with a condition that must hold for a
--                  while (a condition's "for N s"): a ring under the unit its
--                  action is for, filling toward the moment it fires. Amber
--                  filling to green; full green once it is armed (offered to
--                  the engine), full grey when it would fire but none of its
--                  actions can go. When it fires, a pulse under that unit in
--                  its alert's colour (white when it has no alert).
--   THE PICK       the rotation's global cooldown pressed on a unit that is
--                  not your target -- a heal on a party member, a dot spread
--                  to another mob: a small blue curtain round it for a moment,
--                  and a pulse as it is pressed.
--   YOUR TARGET    off unless switched on: a thin ring under your target in
--                  the rotation's colour while the rotation is running.
--
-- marks.lua already draws the kick lined up, who a reaction acted on and the
-- PvP marks; none of that is drawn again here.
--
-- Your reactions are read five times a second from custom.lua's live state:
-- when each condition began to hold, and what the reaction offered. The unit
-- a ring stands under is worked out again from the first of its actions that
-- is about a unit (an alert, stopping a cast and holding the rotation are
-- not, so the next one is looked at); Lua, an item or nothing at all is you.
-- The rotation's choice is read off its last walk. A walk that has not run
-- for a moment is not the rotation running, and the walk says "pressed" only
-- on the tick it pressed, so a pick stays marked for a second and a half.

return function(P)
    local ctx = P.ctx
    local units = P.units or {}
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge

    local M = {}

    local READ_EVERY = 0.2       -- seconds between reads of your reactions
    local STALE = 0.6            -- seconds: a reaction not asked, or a walk not run, this long is not live
    local MAX_RINGS = 6          -- reactions marked at once, at most
    local RING_GAP = 2.2         -- yards outside the model: outside the timers' four rings
    local STACK = 0.35           -- yards between two reactions' rings under one unit
    local PICK_KEEP = 1.5        -- seconds the rotation's pick stays marked after its press
    local PRESS_GAP = 0.5        -- seconds: the same press seen twice is pulsed once
    local FIRE_NEWS = 1.0        -- seconds: a fire older than this is not pulsed

    local function clock() return core.time() end

    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then
            local ok, c = pcall(P.color, r, g, b, a)
            if ok and c ~= nil then return c end
        end
        return { r = r, g = g, b = b, a = a }
    end

    local C = {
        band       = color(0, 0, 0, 150),
        wait       = color(240, 180, 60),
        go         = color(100, 220, 130),
        blocked    = color(150, 150, 158),
        fired      = color(240, 240, 245, 235),   -- a fire with no alert of its own
        pick       = color(90, 170, 250),
        pick_top   = color(90, 170, 250, 30),
        pick_pulse = color(110, 190, 255, 230),
        rotation   = color(140, 120, 240, 220),   -- JCore's accent: the spell window's "the plugin pressed it"
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function setting(id, default)
        if type(P.opt) ~= "function" then return default end
        local ok, v = pcall(P.opt, id, default)
        if ok and v ~= nil then return v end
        return default
    end

    local function guid_of(obj)
        if obj == nil then return nil end
        local g = ask(units.guid, obj)
        if g ~= nil then return g end
        local ok, fn = pcall(function() return obj.get_guid end)
        if ok then return ask(fn, obj) end
        return nil
    end

    local function same(a, b)
        if a == nil or b == nil then return false end
        if a == b then return true end
        local ga = guid_of(a)
        return ga ~= nil and ga == guid_of(b)
    end

    local function position(obj)
        if obj == nil then return nil end
        return ask(units.position, obj)
    end

    --- The model's edge, as marks.lua and timers.lua measure it.
    local function reach_of(obj)
        local reach = tonumber(ask(units.combat_reach, obj)) or 1.2
        return min(4, max(0.9, reach + 0.3))
    end

    local stats = { rings = 0, armed = 0, fired = 0, pick = false, pressed = 0, target_ring = false, reads = 0 }

    -- --- your reactions ----------------------------------------------------------

    -- Action kinds that are not about a unit: the next action is looked at.
    local NOT_A_UNIT = { alert = true, stop_cast = true, hold = true }
    -- Action kinds aimed at the unit their target row names.
    local AT_UNIT = { spell = true, pet_spell = true, pet_attack = true }

    --- The word custom.resolve_target takes for a reaction's first action on
    --- a unit ("self" when that is you, or not known before it runs).
    local function word_of(r)
        local list = type(r.actions) == "table" and r.actions or {}
        for i = 1, #list do
            local a = list[i]
            if type(a) == "table" then
                if a.mode == "lua" then return "self" end
                local kind = a.kind or "spell"
                if kind == "target" then return a.who or "attacker" end
                if AT_UNIT[kind] then return a.target or "target" end
                if not NOT_A_UNIT[kind] then return "self" end
            end
        end
        return "self"
    end

    local function unit_for(custom, r)
        local word = word_of(r)
        local unit = nil
        if word ~= "self" then
            local W = ask(custom.latest_W)
            if W ~= nil then unit = ask(custom.resolve_target, word, W) end
        end
        if unit == nil then unit = ask(units.player) end
        return unit
    end

    --- Has it a condition that must hold for a while?
    local function holds(r)
        local conds = type(r.conds) == "table" and r.conds or {}
        for i = 1, #conds do
            local c = conds[i]
            if type(c) == "table" and (tonumber(c.for_s) or 0) > 0 then return true end
        end
        return false
    end

    --- The condition a reaction is waiting on: when it began to hold and how
    --- long it must. Nil when the reaction is not about to fire.
    local function waiting_on(r, rt, now)
        local all = r.match ~= "any"
        local last = tonumber(rt.last_fire) or -huge
        local conds = type(r.conds) == "table" and r.conds or {}
        local since = type(rt.since) == "table" and rt.since or {}
        local slots = type(rt.conds) == "table" and rt.conds or {}
        local at, need, p, latest = nil, nil, nil, -huge
        for i = 1, #conds do
            local c = conds[i]
            if type(c) == "table" then
                local hold = tonumber(c.for_s) or 0
                if hold > 0 then
                    local s = since[c.uid]
                    local began = type(s) == "table" and tonumber(s.at) or nil
                    if began and (now - (tonumber(s.seen) or began)) <= STALE then
                        latest = max(latest, began)
                        local q = (now - began) / hold
                        -- All: it fires once the slowest is through. Any: once
                        -- the first is, of those begun since it last fired.
                        if (all and (p == nil or q < p)) or (not all and began > last and (p == nil or q > p)) then
                            at, need, p = began, hold, q
                        end
                    elseif all then
                        return nil
                    end
                elseif all then
                    local slot = slots[c.uid]
                    if not (type(slot) == "table" and slot.ok) then return nil end
                end
            end
        end
        if not at then return nil end
        -- Fired since this hold began: done, until it begins again.
        if all and last >= latest then return nil end
        return at, need
    end

    -- The pulse's colour: the alert's when it has one, as the alert shows.
    local fire_cols = {}
    local function fire_color(custom, r)
        local key = r.notify_color or (r.notify_alert and "yellow") or nil
        if not key then return C.fired end
        local c = fire_cols[key]
        if c == nil then
            local D = type(custom.D) == "table" and custom.D or nil
            local by = D and type(D.ALERT_COLOR_BY_KEY) == "table" and D.ALERT_COLOR_BY_KEY or nil
            local row = by and by[key] or nil
            local rgb = type(row) == "table" and type(row.rgb) == "table" and row.rgb or nil
            c = rgb and color(rgb[1] or 240, rgb[2] or 240, rgb[3] or 245, 235) or C.fired
            fire_cols[key] = c
        end
        return c
    end

    local marks, mark_n = {}, 0  -- what the last read found, one per reaction marked
    local fires = {}             -- reaction id -> its last fire as last read (false: none yet)
    local unit_of = {}           -- reaction id -> the unit its ring last stood under
    local stack_of = {}          -- guid -> rings already under that unit, this read
    local read_at = -huge

    local function read(custom, now, draw, layer)
        stats.reads = stats.reads + 1
        mark_n = 0
        for k in pairs(stack_of) do stack_of[k] = nil end
        local list = ask(custom.list)
        if type(list) ~= "table" or type(custom.runtime) ~= "function" then return end
        local live = custom.master_on == nil or ask(custom.master_on) ~= false
        for i = 1, #list do
            local r = list[i]
            if type(r) == "table" and r.id ~= nil and holds(r) then
                local rt = ask(custom.runtime, r.id)
                if type(rt) == "table" then
                    -- FIRED since the last read: a pulse under its unit.
                    local fired = tonumber(rt.last_fire)
                    local was = fires[r.id]
                    if was ~= nil and fired and fired ~= was and (now - fired) <= FIRE_NEWS and draw.pulse then
                        local unit = unit_of[r.id] or unit_for(custom, r)
                        if unit ~= nil then
                            ask(draw.pulse, unit, fire_color(custom, r), { life = 0.9, from = 1.0, to = 3.6, layer = layer,
                                prio = "info", module = "plays" })
                            stats.fired = stats.fired + 1
                        end
                    end
                    fires[r.id] = fired or false

                    if live and r.on ~= false and mark_n < MAX_RINGS
                        and (now - (tonumber(rt.asked_at) or -huge)) <= STALE then
                        local at, need = waiting_on(r, rt, now)
                        local unit = at and unit_for(custom, r) or nil
                        if unit ~= nil then
                            mark_n = mark_n + 1
                            local m = marks[mark_n] or {}
                            marks[mark_n] = m
                            m.obj, m.at, m.need = unit, at, need
                            if rt.pass == true then
                                m.state = tostring(rt.note or ""):find("^offered") and "armed" or "blocked"
                            else
                                m.state = "wait"
                            end
                            local g = guid_of(unit) or unit
                            local n = stack_of[g] or 0
                            stack_of[g] = n + 1
                            m.radius = reach_of(unit) + RING_GAP + n * STACK
                            m.index = n + 1
                            unit_of[r.id] = unit
                        end
                    end
                end
            end
        end
        for k = mark_n + 1, #marks do marks[k].obj = nil end
    end

    -- --- the rotation's pick -------------------------------------------------------

    local seen_cands, walk_at = nil, -huge
    local pick = nil             -- { obj, guid, name, at } while marked
    local pick_box = {}

    local function rule_name(rule)
        if type(rule) == "table" then return rule[1] or rule.name end
        return rule
    end

    --- A new walk: its global cooldown press, if it made one.
    local function take(cands, now, target, draw, layer)
        for k = 1, #cands do
            local c = cands[k]
            if type(c) == "table" and c.state == "pressed" and not c.fast then
                local obj = c.target
                -- On your target, or on you: the rotation moved on.
                if obj == nil or same(obj, target) or same(obj, ask(units.player)) then
                    pick = nil
                    return
                end
                local g, name = guid_of(obj), rule_name(c.rule)
                local again = pick ~= nil and pick.name == name and (now - pick.at) < PRESS_GAP
                    and (pick.obj == obj or (g ~= nil and pick.guid == g))
                pick = pick_box
                pick.obj, pick.guid, pick.name, pick.at = obj, g, name, now
                if not again and draw.pulse then
                    ask(draw.pulse, obj, C.pick_pulse, { life = 0.8, from = 0.8, to = 3.0, layer = layer,
                        prio = "info", module = "plays" })
                    stats.pressed = stats.pressed + 1
                end
                return
            end
        end
    end

    local function rotation_color(draw)
        local t = draw.theme
        return (type(t) == "table" and t.accent) or C.rotation
    end

    -- --- one frame -----------------------------------------------------------------

    local function frame()
        stats.rings, stats.armed, stats.pick, stats.target_ring = 0, 0, false, false
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if type(draw) ~= "table" then return end
        if not setting("plays_on", true) then
            mark_n, pick, seen_cands = 0, nil, nil
            return
        end
        local now = clock()
        local L = (ctx and ctx.LAYER) or {}
        local layer = L.WORLD or 100

        -- ABOUT TO FIRE.
        local react = type(P.react) == "table" and P.react or nil
        local custom = react and type(react.custom) == "table" and react.custom or nil
        if custom and setting("plays_reactions", true) then
            if now - read_at >= READ_EVERY then
                read_at = now
                read(custom, now, draw, layer)
            end
            if draw.ring_3d then
                for i = 1, mark_n do
                    local m = marks[i]
                    local pos = position(m.obj)
                    if pos then
                        local frac, col, to = 1, C.go, C.go
                        if m.state == "blocked" then
                            col, to = C.blocked, C.blocked
                        elseif m.state == "wait" then
                            frac, col = min(1, max(0, (now - m.at) / m.need)), C.wait
                        end
                        ask(draw.ring_3d, pos, m.radius, frac, col,
                            { to = to, bg = C.band, inner = 0.9, outer = 1.0, layer = layer,
                              unit = m.obj, lane = "reaction", index = m.index, prio = "info", module = "plays" })
                        stats.rings = stats.rings + 1
                        if m.state == "armed" then stats.armed = stats.armed + 1 end
                    end
                end
            end
        else
            mark_n = 0
        end

        -- THE PICK and YOUR TARGET.
        local rot = type(P.rotation) == "table" and P.rotation or nil
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        local rot_on = setting("plays_rotation", false)
        local ring_on = setting("plays_target_ring", false)
        local active = rot ~= nil and (P.rotation_active == nil or ask(P.rotation_active) ~= false)
        local target, running = nil, false
        if active and (rot_on or ring_on) and type(rot.last_candidates) == "function" then
            target = P.combat and ask(P.combat.target) or nil
            local cands = ask(rot.last_candidates)
            if type(cands) == "table" and cands ~= seen_cands then
                -- The first walk seen may be an old one: taken as it stands.
                local first = seen_cands == nil
                seen_cands, walk_at = cands, now
                if not first and rot_on then take(cands, now, target, draw, layer) end
            end
            running = seen_cands ~= nil and (now - walk_at) <= STALE
        else
            seen_cands = nil
        end

        if pick and (not rot_on or not active or (now - pick.at) > PICK_KEEP or same(pick.obj, target)
            or ask(units.is_dead, pick.obj) == true) then
            pick = nil
        end
        if pick and draw.curtain_3d then
            local pos = position(pick.obj)
            if pos then
                local radius = max(0.8, min(3, (tonumber(ask(units.combat_reach, pick.obj)) or 1.2) + 0.2))
                ask(draw.curtain_3d, pos, radius, C.pick, { to = C.pick_top, height = 1.4, points = 22,
                    rings = 3, fill = 0.25, speed = 1.6, spin = 1.2, lod = true, layer = layer,
                    unit = pick.obj, prio = "info", module = "plays" })
                stats.pick = true
            end
        end

        if ring_on and running and target ~= nil and draw.ring_3d then
            local pos = position(target)
            if pos then
                ask(draw.ring_3d, pos, reach_of(target) + 0.25, 1, rotation_color(draw),
                    { bg = C.band, inner = 0.94, outer = 1.0, layer = layer, prio = "decor", module = "plays" })
                stats.target_ring = true
            end
        end
    end

    --- One frame. Called by main.lua's render job.
    function M.render()
        local ok, err = pcall(frame)
        if not ok then stats.err = tostring(err) end
    end

    --- For the Debug page and the tests.
    function M.stats() return stats end

    return M
end

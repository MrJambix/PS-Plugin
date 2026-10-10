-- Jambix AIO / routes -- the guide's next stops, the vendor you need, your corpse (1.89.0).
--
-- The user, 2026-10-09, choosing what the world marks do next: "Route +
-- service beacons: next 2-3 guide waypoints, vendor/repair when bags full or
-- gear damaged, trainer when spells are learnable, your corpse". Pillars of
-- light like beacons.lua's, through the world layer (P.worldmarks):
--
--   ROUTE     the stops of RestedXP's step after the one it points at now
--             (beacons.lua's gold pillar, not drawn again here): up to
--             "routes_steps" fainter, shorter pillars, and a dashed line
--             along the ground from each stop to the next. RestedXP hands
--             over the current step's stops only (get_step_waypoints), so a
--             step with one stop has no route; nothing looks further ahead.
--   SERVICES  your bags down to "routes_bag_free" free slots, or your worst
--             piece of gear down to "routes_durability" %: a pillar on the
--             nearest npc that buys (any merchant) or repairs (the anvil),
--             by its npc flags, from the ESP's town_npcs -- Forever's
--             (esp/forever.lua) or the Classic one's (esp/classify.lua) --
--             with what for and how far over it. Worn gear wants a
--             repairer; full bags take any merchant, the repairer first
--             when it is both. Not while you are dead.
--   TRAINER   not drawn. Nothing in the AIO or JCore knows which spells
--             your class could learn at your level: a trainer's list is
--             readable only with its window open, only the hunter catalogue
--             has learn levels, and on Era no flag says whose class trainer
--             an npc is.
--   CORPSE    while you are dead or a ghost: a tall pillar on your corpse,
--             where the client says it is (game_ui.get_corpse_position),
--             else where you were last alive -- not when that was on another
--             map (a dungeon you were carried out of).
--
-- Nothing within a few yards gets a pillar: you are there.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

    local M = {}

    local HERE = 8               -- yards: a stop this close gets no pillar
    local AT_NPC = 6             -- yards: at the vendor, no pillar
    local AT_CORPSE = 5          -- yards: on your corpse, no pillar
    local SERVICE_RANGE = 150    -- yards: npcs further are not looked at (the sweep's cap is lower)
    local SCAN_EVERY = 1.0       -- seconds between looks for the nearest vendor
    local BAGS_EVERY = 1.0       -- seconds between free-slot reads
    local DURA_EVERY = 5.0       -- seconds between durability reads (19 slots)
    local PATH_EVERY = 2.0       -- seconds a line's ground points are kept
    local MAP_EVERY = 1.0        -- seconds between reads of the map you are on
    local STEPS_MAX = 3

    -- UNIT_NPC_FLAGS (the .api's get_npc_flags): what buys from you, what repairs.
    local VENDOR_BITS = { 0x80, 0x100, 0x200, 0x400, 0x800, 0x1000 }
    local REPAIR = 0x1000

    local function clock() return core.time() end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local C = {
        step = color(245, 200, 70, 150), line = color(245, 200, 70, 110),
        sell = color(90, 205, 235), repair = color(170, 150, 255),
        corpse = color(205, 225, 255), corpse_top = color(205, 225, 255, 40),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    --- A method on a game object, through pcall (a missing one is nil).
    local function call(obj, method)
        if obj == nil then return nil end
        local ok, v = pcall(function() return obj[method](obj) end)
        if ok then return v end
        return nil
    end

    local function vec(x, y, z)
        local geo = ctx and ctx.geometry
        local v = geo and ask(geo.vec, x, y, z)
        return v or { x = x, y = y, z = z }
    end

    --- x, y, z of a position the client handed over, or nil for none (a
    --- zero vector is the client's "none").
    local function xyz(p)
        if p == nil then return nil end
        local ok, x, y, z = pcall(function() return p.x, p.y, p.z end)
        if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
        if x == 0 and y == 0 then return nil end
        return x, y, tonumber(z) or 0
    end

    local function dist2d(a, b)
        local dx, dy = a.x - b.x, a.y - b.y
        return sqrt(dx * dx + dy * dy)
    end

    local function has(flags, bit) return floor(flags / bit) % 2 == 1 end
    local function buys(flags)
        for i = 1, #VENDOR_BITS do
            if has(flags, VENDOR_BITS[i]) then return true end
        end
        return false
    end

    local stats = { route = 0, lines = 0, service = nil, service_d = nil, free = nil, worst = nil, corpse = nil }

    -- --- the route ------------------------------------------------------------------

    -- A plain { x, y, z } from the guide as a vec3, made again only when the
    -- place moves (the guide hands over new tables every second).
    local stop_vec = {}
    for i = 1, STEPS_MAX do stop_vec[i] = {} end
    local function as_vec(slot, w)
        if slot.x ~= w.x or slot.y ~= w.y or slot.z ~= w.z or not slot.v then
            slot.x, slot.y, slot.z = w.x, w.y, w.z
            slot.v = vec(w.x, w.y, w.z or 0)
        end
        return slot.v
    end

    -- A line's points along the ground (quests.lua's ground_path, which keeps
    -- its heights per cell), kept PATH_EVERY seconds while its ends stay.
    local seg = {}
    for i = 1, STEPS_MAX do seg[i] = { opts = { thickness = 1.6 } } end
    local function route_line(k, a, b, now, draw, layer)
        local s = seg[k]
        if s.ax ~= a.x or s.ay ~= a.y or s.az ~= a.z or s.bx ~= b.x or s.by ~= b.y or s.bz ~= b.z
            or not s.pts or now >= s.at then
            s.ax, s.ay, s.az, s.bx, s.by, s.bz = a.x, a.y, a.z, b.x, b.y, b.z
            s.at = now + PATH_EVERY
            local gp = P.quests and P.quests.ground_path
            local pts = gp and ask(gp, a, b) or nil
            if type(pts) ~= "table" or #pts < 2 then pts = { a, b } end
            s.pts = pts
            -- Longer dashes on a longer line: never more than about forty.
            s.dash = max(2.5, dist2d(a, b) / 40)
        end
        local o = s.opts
        o.layer = layer
        if draw.path_3d then
            o.dash, o.gap = s.dash, s.dash * 0.8
            draw.path_3d(s.pts, C.line, o)
        elseif draw.line_3d then
            o.dash, o.gap = nil, nil
            draw.line_3d(a, b, C.line, o)
        else
            return
        end
        stats.lines = stats.lines + 1
    end

    local function is_current(wp, cur)
        local raw = wp.raw
        return cur ~= nil and raw ~= nil and raw.x == cur.x and raw.y == cur.y and raw.map_id == cur.map_id
    end

    local step_opts = {}
    for i = 1, STEPS_MAX do
        step_opts[i] = { radius = 0.35, fill = 0.3, prio = i == 1 and "info" or "decor", module = "route" }
    end

    local function render_route(draw, me, layer, height, now)
        local steps = min(STEPS_MAX, floor(tonumber(opt("routes_steps", 2)) or 2))
        if steps <= 0 then return end
        local rxp = P.quests and P.quests.rxp
        if type(rxp) ~= "table" or rxp.loaded == false then return end
        local list = rxp.step_waypoints
        local n = type(list) == "table" and #list or 0
        if n == 0 then return end
        local cur = rxp.waypoint
        local at = 0
        for i = 1, n do
            if type(list[i]) == "table" and is_current(list[i], cur) then
                at = i
                break
            end
        end
        -- The lines are decoration the layer does not budget (they pass
        -- straight through to JCore): off with the world marks, and on
        -- Minimal, as the layer leaves decoration out.
        local lines = (draw.path_3d or draw.line_3d) and opt("world_on", true) ~= false
            and (tonumber(opt("world_density", 1)) or 1) < 3
        local prev = rxp.world_waypoint
        if type(prev) ~= "table" or not prev.x then prev = nil end
        local drawn = 0
        -- After the current stop, round to the ones before it.
        for k = 1, (at > 0) and (n - 1) or n do
            if drawn >= steps then break end
            local wp = list[((at + k - 1) % n) + 1]
            local w = type(wp) == "table" and wp.world or nil
            if type(w) == "table" and w.x and w.y and not is_current(wp, cur) then
                drawn = drawn + 1
                if prev and lines then route_line(drawn, prev, w, now, draw, layer) end
                if dist2d(w, me) > HERE then
                    local o = step_opts[drawn]
                    o.height, o.layer = height * (drawn == 1 and 0.6 or 0.5), layer
                    draw.beacon_3d(as_vec(stop_vec[drawn], w), C.step, o)
                    stats.route = stats.route + 1
                end
                prev = w
            end
        end
    end

    -- --- services ------------------------------------------------------------------

    local need = { free = nil, worst = nil, bags_at = 0, dura_at = 0, scan_at = 0 }
    local target = nil           -- { obj, guid, repair, sell }
    local service_opts = { radius = 0.45, fill = 0.45, prio = "info", module = "services" }

    local function read_free(now)
        if now < need.bags_at then return need.free end
        need.bags_at = now + BAGS_EVERY
        local inv = ctx and ctx.inventory
        need.free = inv and tonumber(ask(inv.free_slots)) or nil
        return need.free
    end

    --- Your worst piece of gear, 0..1, or nil when nothing answers. Read
    --- here, not through JCore's worst_durability: that one reads a field
    --- called `maximum` the .api's { current, max } does not have, and is
    --- kept until a bag event, which Forever never sends.
    local function read_worst(now)
        if now < need.dura_at then return need.worst end
        need.dura_at = now + DURA_EVERY
        local inv = type(core) == "table" and type(core.inventory) == "table" and core.inventory or nil
        local get = inv and inv.get_item_durability
        local worst = nil
        if type(get) == "function" then
            for slot = 1, 19 do
                local ok, info = pcall(get, slot)
                if ok and type(info) == "table" then
                    local top = tonumber(info.max or info.maximum)
                    local now_at = tonumber(info.current)
                    if top and top > 0 and now_at then
                        local f = now_at / top
                        if not worst or f < worst then worst = f end
                    end
                end
            end
        end
        need.worst = worst
        return worst
    end

    --- The town's npcs from the ESP: Forever's, else the Classic one's.
    local function town()
        local esp = P.esp
        local fe = esp and esp.forever
        local fn = fe and fe.town_npcs
        if not fn then
            local cl = P.esp_classify
            fn = cl and cl.town_npcs
        end
        local list = fn and ask(fn, SERVICE_RANGE)
        return type(list) == "table" and list or nil
    end

    local function scan(gear, bags)
        local list = town()
        local best_repair, best_sell = nil, nil
        if list then
            for i = 1, #list do
                local r = list[i]
                local flags = tonumber(r and r.flags) or 0
                local d = tonumber(r and r.d) or 1e9
                if flags > 0 and r.obj then
                    if has(flags, REPAIR) and (not best_repair or d < best_repair.d) then
                        best_repair = { obj = r.obj, d = d }
                    end
                    if buys(flags) and (not best_sell or d < best_sell.d) then
                        best_sell = { obj = r.obj, d = d, repairs = has(flags, REPAIR) }
                    end
                end
            end
        end
        local pick
        if gear and best_repair then
            pick = { obj = best_repair.obj, repair = true, sell = bags }
        elseif bags and best_sell then
            pick = { obj = best_sell.obj, repair = gear and best_sell.repairs, sell = true }
        end
        target = pick
    end

    -- The label over it, made again only when it says something new.
    local label = { opts = { centered = true } }
    local corpse_label = { opts = { centered = true } }
    local function say(lab, draw, pos, what, d, col, lift, layer)
        if not draw.text_3d then return end
        local yards = floor(d + 0.5)
        if what ~= lab.what or yards ~= lab.yards then
            lab.what, lab.yards = what, yards
            lab.text = string.format("%s  %dy", what, yards)
        end
        local x, y, z = xyz(pos)
        if not x then return end
        if lab.x ~= x or lab.y ~= y or lab.z ~= z or not lab.pos then
            lab.x, lab.y, lab.z = x, y, z
            lab.pos = { x = x, y = y, z = z + lift }
        end
        lab.opts.layer, lab.opts.size = layer, opt("text_size", 13)
        draw.text_3d(lab.pos, lab.text, col, lab.opts)
    end

    local function render_services(draw, me, layer, text_layer, height, now)
        local free = read_free(now)
        local worst = read_worst(now)
        stats.free, stats.worst = free, worst
        local bags = free ~= nil and free <= (tonumber(opt("routes_bag_free", 4)) or 4)
        local gear = worst ~= nil and worst <= (tonumber(opt("routes_durability", 25)) or 25) / 100
        if not (bags or gear) then
            target, need.scan_at = nil, 0
            return
        end
        if now >= need.scan_at then
            need.scan_at = now + SCAN_EVERY
            scan(gear, bags)
        end
        local t = target
        if not t then return end
        -- Gone from the sweep since the last look: nothing until the next.
        local row = units.snapshot and units.snapshot(t.obj)
        if units.snapshot and not row then return end
        local pos = (row and row.pos) or (units.position and units.position(t.obj))
        if not xyz(pos) then return end
        local d = (row and row.dist) or dist2d(pos, me)
        if d <= AT_NPC then return end
        local col = t.repair and C.repair or C.sell
        service_opts.height, service_opts.layer, service_opts.unit = height * 0.8, layer, t.obj
        draw.beacon_3d(pos, col, service_opts)
        stats.service, stats.service_d = t.repair and "repair" or "sell", d
        local what = (t.repair and t.sell) and "Repair, sell" or (t.repair and "Repair") or "Sell"
        -- Over the nameplate, which Forever paints over the overlay.
        say(label, draw, pos, what, d, col, 4.0, text_layer)
    end

    -- --- your corpse ------------------------------------------------------------------

    local last = { x = nil, y = nil, z = nil, map = nil, map_at = 0 }   -- your last place alive
    local fell = nil             -- { v = vec3, x, y, z, map } once you have died
    local was_dead = false
    local corpse_opts = { radius = 0.6, fill = 0.55, prio = "warn", module = "corpse" }

    local function map_now()
        local world = ctx and ctx.world
        return world and ask(world.instance_id) or nil
    end

    local function dead_state()
        local pl = ctx and ctx.player
        local dead = pl and ask(pl.is_dead)
        local ghost = pl and ask(pl.is_ghost)
        if dead == nil and ghost == nil then
            local p = units.player and units.player()
            dead, ghost = call(p, "is_dead"), call(p, "is_ghost")
        end
        return dead == true or ghost == true
    end

    local function render_corpse(draw, me, layer, text_layer, height, now)
        if not dead_state() then
            was_dead, fell = false, nil
            last.x, last.y, last.z = me.x, me.y, me.z
            if now >= last.map_at then
                last.map_at = now + MAP_EVERY
                last.map = map_now()
            end
            return
        end
        if not was_dead then
            was_dead = true
            if last.x then
                fell = { v = vec(last.x, last.y, last.z), x = last.x, y = last.y, z = last.z, map = last.map }
            end
        end
        if not opt("routes_corpse", true) then return end
        -- On another map than where you fell, the client's corpse is too.
        local here = map_now()
        if fell and fell.map ~= nil and here ~= nil and fell.map ~= here then return end
        local world = ctx and ctx.world
        local pos = world and ask(world.corpse_position)
        local from = "client"
        if not xyz(pos) then
            pos, from = fell and fell.v, "fell"
        end
        if not pos then return end
        local d = dist2d(pos, me)
        if d <= AT_CORPSE then return end
        corpse_opts.height, corpse_opts.layer, corpse_opts.to = max(30, height * 2.5), layer, C.corpse_top
        draw.beacon_3d(pos, C.corpse, corpse_opts)
        stats.corpse = from
        say(corpse_label, draw, pos, "Your corpse", d, C.corpse, 3.0, text_layer)
    end

    -- --- the frame ------------------------------------------------------------------

    local complained = {}
    local function complain(part, err)
        stats.errors = (stats.errors or 0) + 1
        if complained[part] then return end
        complained[part] = true
        local log = P.log
        if log and log.fmt then pcall(log.fmt, "error", "routes: %s: %s", part, tostring(err)) end
    end

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.route, stats.lines, stats.service, stats.service_d, stats.corpse = 0, 0, nil, nil, nil
        local draw = P.worldmarks or P.draw
        if not (draw and draw.beacon_3d) then return end
        if not opt("routes_on", true) then return end
        local me = units.player_position and units.player_position()
        if not me then return end
        local now = clock()
        local height = tonumber(opt("beacon_height", 14)) or 14
        local L = (ctx and ctx.LAYER) or {}
        local layer = L.WORLD or 100
        local text_layer = L.OVERLAY or layer

        -- Each part on its own: one that raises costs only itself, and the
        -- modules after this one in main.lua's job still draw.
        local ok, err = pcall(render_route, draw, me, layer, height, now)
        if not ok then complain("route", err) end
        -- The corpse before the services: it finds out whether you are dead.
        ok, err = pcall(render_corpse, draw, me, layer, text_layer, height, now)
        if not ok then complain("corpse", err) end
        if was_dead then
            -- Looked for afresh the moment you are back.
            target, need.scan_at = nil, 0
        elseif opt("routes_services", true) then
            ok, err = pcall(render_services, draw, me, layer, text_layer, height, now)
            if not ok then complain("services", err) end
        end
    end

    function M.stats() return stats end

    return M
end

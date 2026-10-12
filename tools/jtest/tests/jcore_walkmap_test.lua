-- JCore / services/walkmap.lua: the yard-by-yard map round the player.
--
-- A fake world: flat ground at z 10, a cliff down to z 1 from x = 30, a pond
-- (bed 7, surface 9.9) south of the start, a hole with no ground at all, and
-- whatever walls a test builds. A wall can be one the rays hit, or one they
-- do not -- the game objects and models the API says no mask reaches, which
-- only the stuck watch can find. The character walks where it is pointed at
-- 7 yards a second and stops dead against anything solid, like the client.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_true(v, label)
    if not v then error(label, 2) end
end

local TERRAIN = 0x100
local atan2 = math.atan2 or math.atan

--- The world, its natives, and a runtime just big enough for the service.
---@param o? table native = false, trace = true|"inverted", swapped = true,
---  dist_yards = true, no_positions = true, map = id,
---  terrain = true (the hill, the ramp and the stairs below)
local function world(o)
    o = o or {}
    local W = {
        clock = 100.0, x = 0.5, y = 0.5, facing = 0, speed = 7, forward = false,
        pressed = {}, jumps = 0, emitted = {}, handlers = {},
        boxes = {}, objects = {}, leases = {}, native_calls = 0, trace_calls = 0,
        map = o.map or 1, files = o.files or {},
    }

    --- With o.terrain: a building's ramp (0.8 up a yard, part of the WMO, so
    --- wall rays hit it) and its stairs (0.3 risers every half yard, WMO too),
    --- both in the north, and an open hillside (terrain, 1 up a yard) in the
    --- west.
    function W.wmo(x, y)
        if not o.terrain then return nil end
        if x >= 10 and x <= 15 and y >= 50 and y <= 70 then
            if y <= 55 then return 10 + 0.8 * (y - 50) end
            return 14
        end
        if x >= -4 and x <= 0 and y >= 50 and y <= 70 then
            if y <= 55 then return 10 + math.floor((y - 50) / 0.5) * 0.3 end
            return 13
        end
        return nil
    end

    function W.ground(x, y)
        if x >= -12 and x <= -10 and y >= -12 and y <= -10 then return nil end
        if x >= 30 then return 1 end
        local wmo = W.wmo(x, y)
        if wmo then return wmo end
        if o.terrain and x <= -8 and y >= 20 then return 10 + (-8 - x) end
        return 10
    end
    --- bed, surface
    function W.pond(x, y)
        if x >= 0 and x <= 6 and y >= -20 and y <= -14 then return 7, 9.9 end
        return nil
    end
    function W.bed(x, y)
        local bed = W.pond(x, y)
        if bed then return bed end
        return W.ground(x, y)
    end
    --- A solid box from (x0, y0) to (x1, y1), floor to sky. rays = false is
    --- one no ray hits.
    function W.wall(x0, y0, x1, y1, rays)
        W.boxes[#W.boxes + 1] = { x0 = x0, y0 = y0, z0 = -100, x1 = x1, y1 = y1, z1 = 100, rays = rays ~= false }
    end

    --- Furniture: a solid box from the floor up to `top`, with a top to stand
    --- on. Rays hit it; height probes from above land on its top.
    function W.prop(x0, y0, x1, y1, top)
        W.boxes[#W.boxes + 1] = { x0 = x0, y0 = y0, z0 = -100, x1 = x1, y1 = y1, z1 = top, rays = true, prop = true }
    end

    --- The highest surface at (x, y) at or below `start`: ground, or the top
    --- of a prop.
    function W.surface(x, y, start)
        local best = nil
        local bed = W.bed(x, y)
        if bed and bed <= start then best = bed end
        for _, b in ipairs(W.boxes) do
            if b.prop and x >= b.x0 and x <= b.x1 and y >= b.y0 and y <= b.y1
                and b.z1 <= start and (not best or b.z1 > best) then best = b.z1 end
        end
        return best
    end

    -- On a prop's top if standing on one, else the ground.
    function W.z() return W.surface(W.x, W.y, 1000) or 10 end

    --- A game object: in the object list, invisible to rays, and solid or not.
    function W.object(x, y, r, solid)
        local obj = { x = x, y = y, r = r, solid = solid }
        function obj.get_bounding_radius() return r end
        function obj.get_position() return { x = x, y = y, z = 10 } end
        W.objects[#W.objects + 1] = obj
        return obj
    end

    local function lerp(a, b, t)
        return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
    end

    -- Slab test: where along a->b the segment enters the box, or nil.
    local function seg_box(a, b, box)
        local tmin, tmax = 0, 1
        for _, ax in ipairs({ "x", "y", "z" }) do
            local lo, hi = box[ax .. "0"], box[ax .. "1"]
            local d = b[ax] - a[ax]
            if math.abs(d) < 1e-9 then
                if a[ax] < lo or a[ax] > hi then return nil end
            else
                local t1, t2 = (lo - a[ax]) / d, (hi - a[ax]) / d
                if t1 > t2 then t1, t2 = t2, t1 end
                if t1 > tmin then tmin = t1 end
                if t2 < tmax then tmax = t2 end
                if tmin > tmax then return nil end
            end
        end
        return tmin
    end

    -- The ground as a surface: the first place the segment crosses it, from
    -- either side. With only_wmo, just the building's own floors (the ramp
    -- and the stairs), which is what a wall ray's mask sees of the ground;
    -- entering one below its surface is hitting its side.
    local function seg_ground(a, b, only_wmo)
        local surf = only_wmo and W.wmo or W.bed
        local g0 = surf(a.x, a.y)
        local below = nil
        if g0 then below = a.z <= g0 end
        for i = 1, 200 do
            local p = lerp(a, b, i / 200)
            local g = surf(p.x, p.y)
            if g then
                local now_below = p.z <= g
                if below == nil then
                    if now_below then return i / 200 end
                elseif now_below ~= below then
                    return i / 200
                end
                below = now_below
            else
                below = nil
            end
        end
        return nil
    end

    local function solid_at(x, y)
        for _, b in ipairs(W.boxes) do
            -- A prop low enough to step onto from where we stand is not in the way.
            local steppable = b.prop and b.z1 <= W.z() + 0.45
            if not steppable and x >= b.x0 - 0.3 and x <= b.x1 + 0.3 and y >= b.y0 - 0.3 and y <= b.y1 + 0.3 then
                return true
            end
        end
        for _, obj in ipairs(W.objects) do
            if obj.solid and math.sqrt((x - obj.x) ^ 2 + (y - obj.y) ^ 2) < obj.r + 0.3 then return true end
        end
        local g = W.ground(x, y)
        return g == nil or math.abs(g - W.z()) > 1.5
    end

    local graphics = { render_rect_3d_filled_new = function() end }
    if o.native ~= false then
        graphics.native_intersect = function(e, s, dist, mask)
            W.native_calls = W.native_calls + 1
            local a, b = s, e
            if o.swapped then a, b = e, s end
            local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
            local best = nil
            if math.floor(mask / TERRAIN) % 2 == 1 then
                best = seg_ground(a, b)
            elseif o.terrain and math.floor(mask / 0x10) % 2 == 1 then
                best = seg_ground(a, b, true)
            end
            if mask % 0x100 ~= 0 then
                for _, box in ipairs(W.boxes) do
                    if box.rays then
                        local t = seg_box(a, b, box)
                        if t and (not best or t < best) then best = t end
                    end
                end
            end
            if best and o.dist_yards and best * len > dist then best = nil end
            if not best then return false, { x = 0, y = 0, z = 0 }, 0 end
            if o.no_positions then return true, { x = 0, y = 0, z = 0 }, 0 end
            return true, lerp(a, b, best), best * len
        end
    end
    if o.trace then
        graphics.trace_line = function(a, b, mask)
            W.trace_calls = W.trace_calls + 1
            local hit = select(1, (function()
                local best = nil
                if math.floor(mask / TERRAIN) % 2 == 1 then best = seg_ground(a, b) end
                for _, box in ipairs(W.boxes) do
                    if box.rays and seg_box(a, b, box) then best = 0 end
                end
                return best ~= nil
            end)())
            if o.trace == "inverted" then return not hit end
            return hit
        end
    end

    _G.core = {
        time = function() return W.clock end,
        cpu_time = function() return 0 end,
        get_height_for_position = function(pos, opts)
            local start = pos.z + 2
            local best = W.surface(pos.x, pos.y, start)
            if opts and opts.water then
                local _, surface = W.pond(pos.x, pos.y)
                if surface and surface <= start and (not best or surface > best) then best = surface end
            end
            return best or 0
        end,
        graphics = graphics,
    }

    local player = {
        get_rotation = function() return W.facing end,
    }

    local function emit(event, ...)
        W.emitted[#W.emitted + 1] = { event, ... }
        for _, fn in ipairs(W.handlers[event] or {}) do fn(...) end
    end

    local stores = {}
    local rt = {
        util = require("jcore/lib/util"),
        log = { for_tag = function()
            local l = {}
            function l.fmt() end
            function l.once() end
            function l.debug() end
            return l
        end },
        cache = {
            try = function(fn, a, b, c)
                if type(fn) ~= "function" then return nil end
                local ok, v = pcall(fn, a, b, c)
                return ok and v or nil
            end,
        },
        events = {
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            emit = emit,
        },
        units = {
            player = function() return player end,
            player_position = function() return { x = W.x, y = W.y, z = W.z() } end,
            objects = function() return W.objects end,
            snapshot = function() return nil end,
            position = function(obj) return obj.get_position() end,
        },
        player = {
            is_swimming = function() return false end,
            is_flying = function() return false end,
            is_dead = function() return false end,
            is_casting = function() return false end,
            is_channelling = function() return false end,
            loss_of_control = function() return W.loc end,
        },
        world = { map_id = function() return W.map end },
        geometry = { vec = function(x, y, z) return { x = x, y = y, z = z } end },
        input = {
            CHANNEL = { MOVEMENT = "movement", FACING = "facing" },
            PRIORITY = { IDLE = 10, ROTATION = 50, DEFENSIVE = 200 },
            acquire = function(channel, owner, priority)
                local l = W.leases[channel]
                if l and l.owner ~= owner then
                    if priority <= l.priority then return false end
                    if channel == "movement" then W.forward = false end
                end
                W.leases[channel] = { owner = owner, priority = priority }
                return true
            end,
            release = function(channel, owner)
                local l = W.leases[channel]
                if l and (not owner or l.owner == owner) then
                    W.leases[channel] = nil
                    if channel == "movement" then W.forward = false end
                end
            end,
            holder = function(channel) return W.leases[channel] end,
            set_key = function(owner, k, down)
                local l = W.leases.movement
                if not l or l.owner ~= owner then return false end
                if k == "forward" then W.forward = down and true or false end
                return true
            end,
            look_at = function(owner, point)
                local l = W.leases.facing
                if not l or l.owner ~= owner then return false end
                W.facing = atan2(point.y - W.y, point.x - W.x)
                return true
            end,
            jump = function() W.jumps = W.jumps + 1 end,
            is_key_pressed = function(vk) return W.pressed[vk] == true end,
            is_typing = function() return false end,
        },
        storage = {
            store = function(name)
                stores[name] = stores[name] or { data = W.files[name] or {}, touch = function() end }
                W.files[name] = stores[name].data
                return stores[name]
            end,
        },
        draw = {
            LAYER = { BACKGROUND = 0 },
            is_visible = function() return true end,
            submit = function() W.painted = (W.painted or 0) + 1 end,
            line_3d = function() end,
            path_3d = function() end,
        },
    }

    package.loaded["jcore/services/walkmap"] = nil
    W.map_svc = require("jcore/services/walkmap")(rt)
    local M = W.map_svc

    --- One tick: the service runs, then the character moves if forward is
    --- held -- unless what is in front of it is solid.
    function W.tick(dt)
        dt = dt or 0.1
        W.clock = W.clock + dt
        M._poll()
        if W.forward or W.pressed[0x57] then
            local step = W.speed * dt
            local nx, ny = W.x + math.cos(W.facing) * step, W.y + math.sin(W.facing) * step
            if not solid_at(nx, ny) then W.x, W.y = nx, ny end
        end
    end

    --- Ticks until the map round the player stops changing (or n ticks).
    function W.settle(n)
        for _ = 1, n or 200 do W.tick() end
    end

    function W.saw(event)
        for _, e in ipairs(W.emitted) do
            if e[1] == event then return e end
        end
        return nil
    end

    W.p = function(x, y) return { x = x, y = y, z = 10 } end
    return W
end

local T = {}

-- --- calibration --------------------------------------------------------------

T[#T + 1] = { "rays are calibrated under the player before any counts: documented order, hit positions", function()
    local W = world()
    local M = W.map_svc
    M.request("test")
    W.tick()
    local r = M.rays()
    assert_eq(r.state, "ok", "calibrated")
    assert_eq(r.kind, "native", "native_intersect")
    assert_eq(r.swap, false, "the documented (end, start) order")
    assert_eq(r.dist_mode, "unit", "distance 1.0 is the whole segment")
    assert_eq(r.positions, true, "hit positions believed")
    assert_true(W.saw("jcore.walkmap.calibrated"), "the calibration is announced")
end }

T[#T + 1] = { "a client whose distance is in yards: the calibration finds it", function()
    local W = world({ dist_yards = true })
    W.map_svc.request("test")
    W.tick()
    local r = W.map_svc.rays()
    assert_eq(r.state, "ok", "calibrated")
    assert_eq(r.dist_mode, "length", "the segment length is passed")
end }

T[#T + 1] = { "a client that takes (start, end): wall hits come from the far face, the order is flipped", function()
    local W = world({ swapped = true })
    local M = W.map_svc
    W.wall(6, -3, 7, 3)          -- a yard thick, six ahead
    M.request("test")
    W.settle(150)
    local r = M.rays()
    assert_eq(r.flipped, true, "the order was turned round")
    assert_eq(r.swap, true, "now (start, end)")
    assert_eq(r.positions, true, "positions still used after the flip")
    local a = M.ahead(10)
    assert_eq(a.clear, false, "the wall is in front")
    assert_eq(a.reason, "wall", "a wall")
    assert_true(a.distance >= 4.5 and a.distance <= 6.0,
        "placed at its NEAR face, about 5.5 yd from x 0.5 (got " .. a.distance .. ")")
end }

T[#T + 1] = { "no native_intersect, and trace_line with its boolean the other way round: still walls", function()
    local W = world({ native = false, trace = "inverted" })
    local M = W.map_svc
    W.wall(6, -3, 7, 3)
    M.request("test")
    W.settle(150)
    local r = M.rays()
    assert_eq(r.state, "ok", "calibrated on trace_line")
    assert_eq(r.kind, "trace", "trace_line")
    assert_eq(r.hit_value, false, "false means hit on this client")
    local a = M.ahead(10)
    assert_eq(a.reason, "wall", "the wall, placed by halving")
    assert_true(a.distance >= 4 and a.distance <= 6.5, "about 5 yd (got " .. a.distance .. ")")
end }

T[#T + 1] = { "no ray call that works: the map says so, and the ground still maps", function()
    local W = world({ native = false })
    local M = W.map_svc
    W.x = 18.5
    W.wall(24, -3, 25, 3)
    M.request("test")
    W.settle(300)
    assert_eq(M.rays().state, "unavailable", "no ray call on this build")
    assert_eq(M.stats().rays, "unavailable", "stats says so too")
    assert_eq(M.ahead(4).clear, true, "the wall is invisible without rays")
    assert_eq(M.probe(0, 15).reason, "drop", "but the cliff at x 30 is still there")
end }

-- --- what is in front -----------------------------------------------------------

T[#T + 1] = { "a wall ahead: not clear, how far, which side is free", function()
    local W = world()
    local M = W.map_svc
    -- Six yards ahead, from y -6 up to y 1: going round it to the left
    -- (north, +y) is two yards, to the right seven.
    W.wall(6, -6, 7, 1)
    M.request("test")
    W.settle(150)
    local a = M.ahead(10)
    assert_eq(a.clear, false, "blocked")
    assert_eq(a.reason, "wall", "by a wall")
    assert_true(a.distance >= 4.5 and a.distance <= 6.0, "about 5.5 yd free (got " .. a.distance .. ")")
    assert_eq(M.ahead(4).clear, true, "the first four yards are fine")
    local cell = M.cell(W.p(6.5, -2))
    assert_true(cell.wall > 0, "the wall's cells are marked")
    assert_eq(cell.blocked, "wall", "and blocked")
    local side = M.free_side(8)
    assert_eq(side, "left", "left is the short way round")
end }

T[#T + 1] = { "the ground layer: a cliff is a drop, a rise is too steep, a hole is a hole, deep water is water", function()
    local W = world()
    local M = W.map_svc
    M.request("test", 40)
    W.x, W.y = 25.5, 0.5
    W.settle(400)
    local east = M.probe(0, 10)
    assert_eq(east.reason, "drop", "the cliff at x 30 drops nine yards")
    assert_true(east.distance >= 3 and east.distance <= 5, "about 4.5 yd to the edge (got " .. east.distance .. ")")
    assert_eq(M.probe(0, 10, { drops = true }).clear, true, "drops allowed: fine")

    W.x, W.y = 33.5, 0.5   -- at the bottom, looking back up
    W.settle(400)
    assert_eq(M.probe(math.pi, 10).reason, "ledge", "nine yards straight up: a step no one walks up (1.13.1: was 'steep')")

    W.x, W.y = -6.5, -11.5
    W.settle(300)
    local hole = M.probe(math.pi, 10)
    assert_eq(hole.reason, "hole", "no ground at all")

    W.x, W.y = 3.5, -8.5
    W.settle(300)
    local pond = M.probe(-math.pi / 2, 10)
    assert_eq(pond.reason, "water", "2.9 yd of water over the bed")
    assert_eq(M.probe(-math.pi / 2, 10, { water = true }).clear, true, "water allowed: fine")
    local cell = M.cell(W.p(3.5, -17.5))
    assert_true(cell.water and cell.z and cell.water - cell.z > 2, "surface and bed both read")
end }

T[#T + 1] = { "game objects: a cost and a block for a straight line, ignorable, and not when standing at one", function()
    local W = world()
    local M = W.map_svc
    W.object(5.5, 0.5, 1.0, false)
    M.request("test")
    W.settle(60)
    local a = M.ahead(10)
    assert_eq(a.reason, "object", "the object's footprint is in the way")
    assert_eq(M.ahead(10, { objects = false }).clear, true, "unless objects are ignored")
    W.x = 4.8          -- standing right at it (the mailbox case)
    W.settle(10)
    assert_eq(M.probe(math.pi, 6).clear, true, "walking away from the object we stand at is fine")
end }

T[#T + 1] = { "unprobed ground passes by default and stops with unknown = 'stop'", function()
    local W = world()
    local M = W.map_svc
    M.request("test", 10)
    W.settle(100)
    local ok, free, why, _, unknown = M.clear_line(W.p(0.5, 0.5), W.p(8.5, 0.5))
    assert_eq(ok, true, "inside the ten yards: clear")
    assert_eq(unknown, 0, "and all of it known")
    ok, free, why, _, unknown = M.clear_line(W.p(0.5, 0.5), W.p(0.5, 25.5))
    assert_eq(ok, true, "north is unprobed past ten yards, and passes")
    assert_true(unknown > 5, "and says how much of it was unknown (" .. unknown .. ")")
    ok, free, why = M.clear_line(W.p(0.5, 0.5), W.p(0.5, 25.5), { unknown = "stop" })
    assert_eq(ok, false, "unless told to stop at the unknown")
    assert_eq(why, "unknown", "and says why")
    assert_true(free >= 9 and free <= 11.5, "about ten yards were known (" .. free .. ")")
end }

-- --- steering and routes -------------------------------------------------------

T[#T + 1] = { "steer: the goal when the way is clear, round the wall when it is not", function()
    local W = world()
    local M = W.map_svc
    M.request("test")
    W.settle(100)
    local point, info = M.steer(W.p(15.5, 0.5))
    assert_eq(info.offset, 0, "clear: straight at it")
    W.wall(4, -6, 5, 1)
    M.forget()
    W.settle(150)
    point, info = M.steer(W.p(15.5, 0.5))
    assert_true(point ~= nil, "a way")
    assert_true(info.offset ~= 0, "not straight at it")
    assert_eq(info.reason, "wall", "because of the wall")
    assert_true(point.y > 0.5, "round the short (north) end")
end }

T[#T + 1] = { "path: round a wall to the far side, every leg walkable, no leg through the wall", function()
    local W = world()
    local M = W.map_svc
    -- A wall across the way with one gap, at its far north end.
    W.wall(6, -10, 7, 4)
    W.wall(6, 6, 7, 14)
    M.request("test", 25)
    W.settle(400)
    local route, why = M.path(W.p(0.5, 0.5), W.p(14.5, 0.5))
    assert_true(route, "a route (" .. tostring(why) .. ")")
    assert_eq(why, nil, "a whole one, not partial")
    local prev = W.p(0.5, 0.5)
    local through_gap = false
    for i = 1, #route do
        local ok, _, reason = M.clear_line(prev, route[i], { body = 0.2 })
        assert_true(ok, "leg " .. i .. " walkable (" .. tostring(reason) .. ")")
        if route[i].y > 4 and route[i].y < 6 then through_gap = true end
        prev = route[i]
    end
    assert_true(through_gap, "the route goes through the gap at y 4..6")
    local last = route[#route]
    assert_true(math.abs(last.x - 14.5) < 0.01 and math.abs(last.y - 0.5) < 0.01, "ends on the goal")
end }

T[#T + 1] = { "path: walled in all round is 'no way through', and a goal inside a wall ends beside it", function()
    local W = world()
    local M = W.map_svc
    W.wall(-4, -4, -3, 5)
    W.wall(4, -4, 5, 5)
    W.wall(-4, -4, 5, -3)
    W.wall(-4, 4, 5, 5)
    M.request("test")
    W.settle(400)
    local route, why = M.path(W.p(0.5, 0.5), W.p(15.5, 0.5))
    assert_eq(route, nil, "boxed in")
    assert_eq(why, "no way through", "says so")

    local W2 = world()
    W2.wall(6, -2, 9, 3)
    W2.map_svc.request("test")
    W2.settle(300)
    local r2 = W2.map_svc.path(W2.p(0.5, 0.5), W2.p(7.5, 0.5), { arrive = 2 })
    assert_true(r2, "a route to beside it")
    local last = r2[#r2]
    assert_eq(W2.map_svc.cell(last).blocked, nil, "ending on a free cell, not in the wall")
end }

-- --- the walker ------------------------------------------------------------------

T[#T + 1] = { "walk_to: round a wall to the goal, never inside it, arrived", function()
    local W = world()
    local M = W.map_svc
    W.wall(6, -6, 7, 3)
    local done
    local ok = M.walk_to("test", W.p(14.5, 0.5), { on_done = function(a, b) done = { a, b } end })
    assert_eq(ok, true, "started")
    assert_eq(W.leases.movement and W.leases.movement.owner, "test", "holds movement")
    for _ = 1, 200 do
        W.tick()
        assert_true(not (W.x > 5.7 and W.x < 7.3 and W.y > -6.3 and W.y < 3.3), "never in the wall")
        if done then break end
    end
    assert_true(done, "finished")
    assert_eq(done[1], true, "ok")
    assert_eq(done[2], "arrived", "arrived")
    assert_eq(W.forward, false, "forward let go")
    assert_eq(W.leases.movement, nil, "movement handed back")
    assert_eq(W.leases.facing, nil, "facing handed back")
end }

T[#T + 1] = { "the stuck watch: a pillar no ray sees is learned the hard way, routed round, and saved for the map", function()
    local W = world()
    local M = W.map_svc
    W.wall(5, -1, 6, 2, false)       -- invisible to rays, solid to the character
    local done
    M.walk_to("test", W.p(12.5, 0.5), { on_done = function(a, b) done = { a, b } end })
    for _ = 1, 250 do
        W.tick()
        if done then break end
    end
    assert_true(done, "finished")
    assert_eq(done[2], "arrived", "arrived despite the pillar (" .. tostring(done[2]) .. ")")
    local stuck = W.saw("jcore.walkmap.stuck")
    assert_true(stuck, "the pillar was learned by walking into it")
    assert_true(M.stats().stuck >= 1, "and is on the map")
    local saved = W.files.walkmap and W.files.walkmap.learned and W.files.walkmap.learned["1"]
    local n = 0
    for _ in pairs(saved or {}) do n = n + 1 end
    assert_true(n >= 1, "saved under map 1")

    -- Another session on the same map: the pillar is known before anyone
    -- walks into it.
    local W2 = world({ files = W.files })
    W2.map_svc.request("test")
    W2.tick()
    assert_true(W2.map_svc.stats().stuck >= 1, "loaded for map 1")
    local blocked = false
    for _, row in pairs(saved) do
        if W2.map_svc.blocked({ x = row.x, y = row.y, z = 10 }) == "stuck" then blocked = true end
    end
    assert_true(blocked, "and blocks its cell")
end }

T[#T + 1] = { "the player's own walking teaches it too, and a wrong mark is cleared by standing there", function()
    local W = world()
    local M = W.map_svc
    W.wall(3, -2, 4, 3, false)
    W.facing = 0
    W.pressed[0x57] = true       -- holding W into the pillar
    for _ = 1, 12 do W.tick() end
    W.pressed[0x57] = nil
    assert_true(W.saw("jcore.walkmap.stuck"), "learned from the player's own keys")
    assert_eq(M.ahead(4).reason, "stuck", "and it is in front")

    -- Rooted, not walled in: nothing learned.
    local W2 = world()
    W2.loc = { valid = true, type = 1 }
    W2.wall(30, 30, 31, 31)
    W2.speed = 0
    W2.pressed[0x57] = true
    for _ = 1, 20 do W2.tick() end
    assert_eq(W2.saw("jcore.walkmap.stuck"), nil, "a root is not a wall")

    -- A mark that was wrong (the pillar is gone): standing on it clears it.
    W.boxes = {}
    local _, _, _, at = M.clear_line(W.p(W.x, W.y), W.p(W.x + 4, W.y))
    M.mark(at, "blocked")
    W.x, W.y = at.x, at.y
    W.tick()
    assert_eq(M.blocked(at), nil, "cleared by the player standing on it")
end }

T[#T + 1] = { "a higher-priority claim on movement ends the walk as preempted", function()
    local W = world()
    local M = W.map_svc
    local done
    M.walk_to("test", W.p(15.5, 0.5), { on_done = function(a, b) done = { a, b } end })
    W.tick()
    W.tick()
    assert_eq(W.forward, true, "walking")
    W.leases.movement = { owner = "defensive", priority = 200 }
    W.tick()
    assert_true(done, "finished")
    assert_eq(done[1], false, "not ok")
    assert_eq(done[2], "preempted", "preempted")
    assert_eq(M.walking(), nil, "no walk")
    local ok, why = M.walk_to("test", W.p(15.5, 0.5))
    assert_eq(ok, false, "cannot start under the higher claim")
    assert_true(why:find("defensive"), "and says who has it (" .. why .. ")")
end }

-- --- cost -----------------------------------------------------------------------------

T[#T + 1] = { "nothing is cast with nobody asking; a query wakes it for a few seconds; the budget holds per tick", function()
    local W = world()
    local M = W.map_svc
    for _ = 1, 20 do W.tick() end
    local s = M.stats()
    assert_eq(s.rays_total, 0, "no rays with nobody asking")
    assert_eq(s.probes_total, 0, "no height probes either")
    assert_eq(s.active, false, "idle")

    M.ahead(5)
    W.tick()
    s = M.stats()
    assert_true(s.rays_total > 0 and s.probes_total > 0, "a query wakes the scanner")
    assert_true(s.rays_tick <= 16 + 40, "rays per tick near the budget (" .. s.rays_tick .. ")")
    assert_true(s.probes_tick <= 16 + 3, "probes per tick near the budget (" .. s.probes_tick .. ")")

    for _ = 1, 60 do W.tick() end   -- six seconds
    local before = M.stats().rays_total
    W.tick()
    assert_eq(M.stats().rays_total, before, "asleep again after five quiet seconds")
end }

T[#T + 1] = { "a zone change forgets the map and calibrates again", function()
    local W = world()
    local M = W.map_svc
    M.request("test")
    W.settle(50)
    assert_true(M.stats().known > 100, "mapped")
    W.map = 2
    for _, fn in ipairs(W.handlers["jcore.zone.changed"] or {}) do fn(2, 1) end
    assert_eq(M.rays().state, "untested", "calibration reset")
    assert_true(M.stats().cells < 5, "cells dropped")
    W.tick()
    assert_eq(M.rays().state, "ok", "calibrated again")
end }

T[#T + 1] = { "the overlay paints only while on", function()
    local W = world()
    local M = W.map_svc
    W.wall(4, -3, 5, 3)
    M.request("test")
    W.settle(100)
    M._render()
    assert_eq(W.painted, nil, "off: nothing")
    M.set_overlay(true)
    M._render()
    assert_true((W.painted or 0) > 3, "on: the wall's cells")
end }

-- --- furniture, ramps and stairs (1.13.1) ----------------------------------------
--
-- The user, in Lakeshire's inn with the overlay on: "see how its not marking
-- these rails as u cant walk through it yes u can walk ontop of it but not
-- through it". 1.12.0 read a table top a yard up as a climbable slope, rode
-- its rays up onto the furniture, and had no ray low enough for a bench.

--- An inn floor at z 10 round (0.5, 40.5): a table two yards wide and 0.9
--- high to the east, a bench too narrow for any cell centre to land on
--- (0.35 wide, 0.5 high) to the north-east, and a 0.3 threshold to the west
--- that is stepped over.
local function inn(o)
    local W = world(o)
    W.x, W.y = 0.5, 40.5
    W.prop(4, 39, 6, 42, 10.9)            -- the table
    W.prop(3.1, 43, 3.45, 47, 10.5)       -- the bench
    W.prop(-4, 39, -2, 42, 10.3)          -- the threshold
    return W
end

T[#T + 1] = { "the inn: a table is a ledge from the floor, a narrow bench a wall, a low threshold neither", function()
    local W = inn()
    local M = W.map_svc
    M.request("test")
    W.settle(300)

    local east = M.probe(0, 8)
    assert_eq(east.clear, false, "the table is in the way")
    assert_true(east.reason == "ledge" or east.reason == "wall", "as a ledge or a wall (" .. tostring(east.reason) .. ")")
    assert_true(east.distance >= 2.5 and east.distance <= 4.0, "about 3.5 yd out (got " .. east.distance .. ")")
    assert_true(M.cell(W.p(5.5, 40.5)).ledge, "the table top is a ledge: somewhere to stand, not to walk up onto")
    assert_true(M.stats().steps > 0, "and its edges are counted")

    local ok, _, why = M.clear_line(W.p(1.5, 45.0), W.p(6.5, 45.0))
    assert_eq(ok, false, "the bench, which no cell centre lands on, still blocks")
    assert_eq(why, "wall", "found by the shin ray")

    assert_eq(M.probe(math.pi, 4).clear, true, "the 0.3 threshold is stepped over")

    local route = M.path(W.p(0.5, 40.5), W.p(8.5, 40.5))
    assert_true(route, "a way round the table")
    for _, wp in ipairs(route) do
        assert_true(not (wp.x > 3.6 and wp.x < 6.4 and wp.y > 38.6 and wp.y < 42.4), "no waypoint on the table")
    end
end }

T[#T + 1] = { "the inn: on top of the table it can be walked along and stepped off", function()
    local W = inn()
    local M = W.map_svc
    M.request("test")
    W.settle(300)
    W.x, W.y = 4.5, 39.5                  -- jumped up
    W.settle(30)
    assert_eq(W.z(), 10.9, "standing on the top")
    local ok, _, why = M.clear_line(W.p(4.5, 39.5), W.p(5.5, 41.5))
    assert_eq(ok, true, "along the top (" .. tostring(why) .. ")")
    ok, _, why = M.clear_line(W.p(5.5, 40.5), W.p(8.5, 40.5))
    assert_eq(ok, true, "and off the end, a 0.9 drop (" .. tostring(why) .. ")")
end }

T[#T + 1] = { "the walker goes round the table and the bench, never through either", function()
    local W = inn()
    local M = W.map_svc
    M.request("test")
    W.settle(200)
    local done
    M.walk_to("test", W.p(5.5, 49.5), { on_done = function(a, b) done = { a, b } end })
    for _ = 1, 300 do
        W.tick()
        assert_true(not (W.x > 3.85 and W.x < 6.15 and W.y > 38.85 and W.y < 42.15), "never on or in the table")
        assert_true(not (W.x > 2.95 and W.x < 3.6 and W.y > 42.85 and W.y < 47.15), "never through the bench")
        if done then break end
    end
    assert_true(done, "finished")
    assert_eq(done[2], "arrived", "arrived (" .. tostring(done[2]) .. ")")
end }

T[#T + 1] = { "a building's ramp and its stairs are walked up; an open hillside too; none of it is a wall", function()
    local W = world({ terrain = true })
    local M = W.map_svc
    M.request("test", 25)

    W.x, W.y = 12.5, 47.5                 -- below the ramp
    W.settle(400)
    local ok, _, why = M.clear_line(W.p(12.5, 47.5), W.p(12.5, 58.5))
    assert_eq(ok, true, "up the ramp, 0.8 a yard (" .. tostring(why) .. ")")
    for y = 50, 56 do
        local c = M.cell(W.p(12.5, y + 0.5))
        assert_eq(c.blocked, nil, "ramp cell at y " .. y .. " is not blocked")
        assert_eq(c.ledge, false, "nor a ledge")
    end

    W.x, W.y = -2.5, 47.5                 -- below the stairs
    W.settle(400)
    ok, _, why = M.clear_line(W.p(-2.5, 47.5), W.p(-2.5, 58.5))
    assert_eq(ok, true, "up the stairs, 0.3 risers (" .. tostring(why) .. ")")

    W.x, W.y = -5.5, 30.5                 -- below the hill
    W.settle(400)
    ok, _, why = M.clear_line(W.p(-5.5, 30.5), W.p(-11.5, 30.5))
    assert_eq(ok, true, "up the hillside, a yard a yard (" .. tostring(why) .. ")")
end }

-- --- in the real runtime --------------------------------------------------------
-- Last, because it installs the whole mock client over the fake world above.

T[#T + 1] = { "boot: JCore 1.12.0 runs the walk map; a plugin's walk and request are its own and go with it", function()
    local mock = require("mock_core")
    mock.install()
    local pos = { x = 100.5, y = 200.5, z = 50 }
    local me = setmetatable({}, { __index = function(_, k)
        if k == "get_position" then return function() return pos end end
        local answers = { is_valid = true, is_dead = false, get_guid = "Player-1-0001", is_unit = true,
            is_player = true, get_rotation = 0, get_bounding_radius = 0.4 }
        local v = answers[k]
        return function() return v end
    end })
    rawset(mock.core.object_manager, "get_local_player", function() return me end)
    rawset(mock.core, "get_height_for_position", function() return 50 end)

    local ok, err = pcall(require, "jcore/main")
    assert_true(ok, "boot raised: " .. tostring(err))
    local JCore = _G.JCore
    assert_eq(JCore.version, "1.8.1", "version")
    assert_true(JCore.walkmap and JCore.walkmap.ahead, "JCore.walkmap published")
    assert_true(JCore.diagnostics().walkmap, "and in the diagnostics")
    local declared = false
    for _, values in pairs(mock.menu.values or {}) do
        if values.walkmap_overlay ~= nil then declared = true end
    end
    assert_true(declared, "the Core page has the Show walk map switch")
    assert_eq(JCore.walkmap.overlay(), false, "off by default")

    local ctx
    JCore.register({ id = "walker.test", name = "Walker", version = "1.0.0", kind = "plugin",
        on_load = function(c) ctx = c end })
    mock.frame(2)
    assert_true(ctx and ctx.walkmap, "ctx.walkmap")
    assert_eq(ctx.walkmap.ahead(5).clear, true, "reads go to the shared map")

    ctx.walkmap.request(15)
    assert_eq(ctx.walkmap.walk_to({ x = 110.5, y = 200.5, z = 50 }), true, "a walk starts")
    assert_eq(JCore.walkmap.walking().owner, "walker.test", "in the plugin's name")
    assert_eq(JCore.input.holder(JCore.CHANNEL.MOVEMENT).owner, "walker.test", "holding movement as it")
    -- The mock's cpu_time is real, and this VM is many times slower than the
    -- game's Lua, so the 1.5 ms a tick cap lets fewer probes through per frame.
    mock.frame(40)
    assert_eq(#mock.errors, 0, "forty frames without an error: " .. mock.error_text())
    assert_true(JCore.walkmap.stats().known > 50, "the ground round the player is mapped (" .. JCore.walkmap.stats().known .. ")")
    assert_eq(JCore.walkmap.stop("someone.else"), false, "another owner cannot stop it")

    assert_true(JCore.unregister("walker.test"), "unregistered")
    assert_eq(JCore.walkmap.walking(), nil, "its walk went with it")
    assert_eq(JCore.input.holder(JCore.CHANNEL.MOVEMENT), nil, "and its movement lease")
    assert_eq(JCore.walkmap.stats().requests, 0, "and its request")
end }

return T

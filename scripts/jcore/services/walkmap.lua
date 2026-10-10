-- JCore / walkmap -- what is around the player, yard by yard, so that whatever
-- moves the character knows what is in front of it and does not walk into it.
--
-- Depends on: util, log, cache, events, units, player, world, geometry, input,
-- storage, draw.
--
-- THE PROBLEM
-- Every mover in the project walks the same way: face a point, hold forward.
-- Sentinel was meant to path for us, and on Forever it accepts a route and
-- never moves the character. So a walk is a straight line, and a straight line
-- goes into the stove, the fence, the tent pole, off the dock and into the
-- lake. What every mover was missing is a picture of the few yards around it.
--
-- THE PICTURE
-- A grid of one-yard cells, world-aligned, kept for the session (per map) and
-- filled outward from wherever the player is. Twenty yards by default: enough
-- to see round a building corner, small enough to fill in about a second.
-- Each cell knows up to five things, each from a different source, because no
-- one source sees everything:
--
--   ground  get_height_for_position, chained outward cell to cell. A rise
--           between two cells is looked at closely: spread out it is a slope
--           (walked up to about fifty degrees), all at once it is a step --
--           a table, a bench, a counter -- that cannot be walked up, though
--           its top can be stood and walked on. Much lower is a drop, no
--           ground at all is a hole. The ground does not move, so a cell is
--           probed once.
--   water   the same probe with { water = true }, only where the ground falls
--           below the player. Deep enough to swim is not somewhere to walk.
--   walls   rays at shin, knee and chest height, fanned out from the player
--           like a lidar along the line the character would walk, against
--           buildings and doodads only. Terrain is left out of the mask on
--           purpose: a knee-height ray up a hill hits the hill, and the hill is
--           the ground layer's business. Each hit is probed to tell a wall from
--           a raised top from a ramp; a top too narrow for a cell (a rail, a
--           bench) is marked as a wall.
--   objects every game object nearby, as a circle of its bounding radius. The
--           API says outright that rays do not hit game objects (stoves,
--           chairs, benches) although the client collides with them, so they
--           are read from the object list instead. They are a COST, not a wall:
--           a herb or a spell area is a game object too, and we cannot tell.
--   stuck   the one source that is never wrong about collision: the character
--           pushed forward and did not move. That cell is marked, saved per
--           map, and stays marked until the player is seen standing in it.
--           This is what catches the rope bridge and the troll hut wall that
--           no ray hits.
--
-- WHAT IS ASKED OF IT
--   ahead / probe / around / free_side   -- what is in front, which side is free
--   clear_line(from, to)                 -- can I walk this straight line
--   steer(goal)                          -- the point to face right now
--   path(from, to)                       -- a route round what is in the way
--   walk_to(owner, goal)                 -- all of it, driving the character
--
-- THE RAYS ARE CALIBRATED, NOT TRUSTED
-- native_intersect and trace_line had never been called on Forever when this
-- was written, and their documentation leaves open the argument order, what
-- `distance` means and what trace_line's boolean says. So before any wall ray
-- counts, two known answers are asked for under the player: a ray straight
-- down must hit the ground they stand on, and a short ray at their chest must
-- hit nothing. The first call shape that gets both right is the one used for
-- the zone; if none does, walls come only from objects and stuck spots, and
-- stats() says so rather than the map pretending.
--
-- COST
-- Nothing is cast unless something asked: a request (request/walk_to), a
-- query in the last few seconds, or the overlay. Then a fixed number of rays
-- and height probes per tick, nearest cells first, and a CPU-time cap on top.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local events = rt.events
    local units = rt.units
    local player_svc = rt.player
    local world = rt.world
    local geometry = rt.geometry
    local input = rt.input
    local storage = rt.storage
    local draw = rt.draw
    local log = rt.log.for_tag("JCore/walkmap")

    local try = cache.try
    local sqrt, floor, abs, cos, sin, min, max = math.sqrt, math.floor, math.abs, math.cos, math.sin, math.min, math.max
    local pi = math.pi
    local atan2 = math.atan2 or math.atan

    local M = {}

    -- --- tuning -------------------------------------------------------------

    local CELL = 1.0              -- yards per cell
    local DEFAULT_RADIUS = 20
    local MAX_RADIUS = 40

    -- SLOPES AND STEPS ARE DIFFERENT THINGS (1.13.1). A hillside rising a
    -- yard over a yard of run is walked up; a table top a yard above the
    -- floor is not, nor a bench half that -- the user, in Lakeshire's inn:
    -- "u can walk ontop of it but not through it". Sampled a yard apart the
    -- two look the same, so a big enough rise between two cells is looked at
    -- closely (see check_edge): spread out, it is a slope and MAX_CLIMB
    -- applies; all at once, it is a step and STEP_UP does.
    --
    -- Walks slopes up to about fifty degrees: per yard of run, a rise past
    -- this is a wall of earth.
    local MAX_CLIMB = 1.2
    -- The most a character steps straight up without jumping. Stair risers
    -- are under it; a bench, a table, a rail and a counter are over it.
    local STEP_UP = 0.45
    -- Down is different: any slope can be walked down, but a cell three
    -- yards below its neighbour is a ledge. Falling off it can hurt, and on a
    -- hardcore character it can end the run; there is no walking back up.
    local MAX_DROP = 2.5
    -- Water this deep over the bed swims rather than wades.
    local SWIM_DEPTH = 1.4

    -- Ray heights over the ground the character walks on. The shin ray is
    -- for what a knee ray clears: benches, low rails, a step-sized lip. It
    -- sits under STEP_UP, so anything it hits that is not a step is not one.
    local SHIN, KNEE, CHEST = 0.35, 0.7, 1.6
    local SEGMENT = 4.0           -- yards per ray segment along a direction
    local BISECT = 3              -- extra rays to place a hit when the call says only yes/no
    local DIRECTIONS = 96         -- lidar directions round the circle (3.75 degrees)
    local FRONT_HALF = pi / 3     -- the front sector, scanned twice as often

    local RAYS_PER_TICK = 24
    local PROBES_PER_TICK = 16
    local CPU_BUDGET_MS = 1.5     -- per tick, whatever the counts say

    local IDLE_AFTER = 5.0        -- seconds a query keeps the scanner awake
    local OBJECTS_EVERY = 0.5
    local OBJECT_MIN_R, OBJECT_MAX_R, OBJECT_PAD = 0.5, 2.5, 0.35
    local OBJECT_COST = 5         -- extra path cost per object cell
    local UNKNOWN_COST = 0.5      -- extra path cost per unprobed cell
    local WALL_SIDE_COST = 0.3    -- per blocked neighbour: keeps routes off walls
    local BODY = 0.4              -- half the width a straight line must keep clear

    local MAX_CELLS = 30000
    local MAX_LEARNED = 3000      -- stuck spots kept per map

    local STUCK_TIME = 0.6        -- s of pushing forward without moving
    local STUCK_MOVE = 0.35       -- yd that counts as having moved
    local STUCK_AHEAD = 0.9       -- yd ahead of the player where the blocker is
    -- A stuck spot is wrong if the player's centre is ever seen this close to
    -- it. Not "standing in its cell": a wall can cut a cell in half, and the
    -- near half is somewhere the player stands all the time.
    local STUCK_CLEAR = 0.5

    -- Wall evidence is a score, so one bad ray is outvoted by the next.
    local WALL_HIT, WALL_MAX, WALL_MIN = 1, 3, -2

    -- --- cells --------------------------------------------------------------
    --
    -- An integer key per cell rather than a "x:y" string: the planner and the
    -- line walk build thousands of keys a tick, and a string per key is a
    -- string per key. World coordinates sit inside +-17,067 yards, so an
    -- offset of 20,000 and a span of 40,000 cover every cell with a key under
    -- 1.6 billion -- inside a 32-bit integer. Sixteen bits an axis (65,536)
    -- would not be: past 2^31 a 32-bit Lua wraps the key negative and unkey
    -- answers the wrong cell.

    local OFFSET, SPAN = 20000, 40000

    local function cell_of(x, y)
        return floor(x / CELL), floor(y / CELL)
    end

    local function key(cx, cy)
        return (cx + OFFSET) * SPAN + (cy + OFFSET)
    end

    local function unkey(k)
        local cx = floor(k / SPAN)
        return cx - OFFSET, (k - cx * SPAN) - OFFSET
    end

    local function key_at(x, y)
        return key(floor(x / CELL), floor(y / CELL))
    end

    local function centre(cx, cy)
        return (cx + 0.5) * CELL, (cy + 0.5) * CELL
    end

    -- key -> { z = number|false|nil, w = water z|nil, wall = score,
    --          stuck = n|nil, sx, sy = where it was, walked = bool }
    -- z: nil not probed yet, false probed and nothing found (a hole).
    local cells = {}
    local n_cells = 0
    -- key -> true for cells under a game object's footprint; rebuilt, never kept.
    local soft = {}

    local function get_cell(k)
        local c = cells[k]
        if not c then
            c = { wall = 0 }
            cells[k] = c
            n_cells = n_cells + 1
        end
        return c
    end

    -- Cells inside MAX_RADIUS, nearest first. Probing walks this list from the
    -- player's cell outward, so the ground fills in rings without a sort.
    local OFFSETS = {}
    do
        local r = MAX_RADIUS
        for dx = -r, r do
            for dy = -r, r do
                local d2 = dx * dx + dy * dy
                if d2 <= r * r then OFFSETS[#OFFSETS + 1] = { dx, dy, d2 } end
            end
        end
        table.sort(OFFSETS, function(a, b) return a[3] < b[3] end)
    end

    -- --- state --------------------------------------------------------------

    local map_id = nil
    local radius = DEFAULT_RADIUS
    local requests = {}           -- owner -> radius
    local last_query = -math.huge
    local overlay = false
    local rays_per_tick, probes_per_tick = RAYS_PER_TICK, PROBES_PER_TICK

    local rays_left, probes_left = 0, 0
    local totals = { rays = 0, probes = 0, ticks = 0, stuck = 0, cleared = 0 }
    local tick_rays, tick_probes = 0, 0

    local probe_cursor = 1
    local probe_anchor = nil      -- the player cell the cursor is walking out from
    local dir_front, dir_all = 0, 0
    local objects_at = -math.huge

    local water_supported = true

    -- How rays are cast this zone. See THE RAYS ARE CALIBRATED.
    local R = {
        state = "untested",       -- untested | ok | failed | unavailable
        kind = nil,               -- "native" | "trace"
        swap = false,             -- native: pass (start, end) instead of (end, start)
        dist_mode = "unit",       -- native: 1.0 for the whole segment, or its length in yards
        positions = false,        -- native: the hit position can be believed
        verified = 0,             -- native: hits whose position a second ray agreed with
        flipped = false,          -- native: the order was turned round by that check
        hit_value = true,         -- trace: the boolean that means "hit"
        tried_at = -math.huge,
        note = nil,
    }
    local CALIBRATE_RETRY = 10.0

    -- --- masks --------------------------------------------------------------

    local FLAGS = { DoodadCollision = 0x1, WmoCollision = 0x10, Terrain = 0x100 }
    do
        local enums = player_svc and player_svc.enums
        local cf = enums and enums.collision_flags
        if type(cf) == "table" then
            for name in pairs(FLAGS) do
                if type(cf[name]) == "number" then FLAGS[name] = cf[name] end
            end
        end
    end
    -- Buildings and doodads. No terrain (see THE PICTURE), and no entity bits:
    -- the player's own model would be the first thing every ray hit.
    local WALL_MASK = FLAGS.DoodadCollision + FLAGS.WmoCollision
    local GROUND_MASK = WALL_MASK + FLAGS.Terrain

    -- --- small helpers ------------------------------------------------------

    local function now() return core.time() end

    local function vec(x, y, z)
        return geometry.vec(x, y, z)
    end

    local function dist2d(ax, ay, bx, by)
        local dx, dy = ax - bx, ay - by
        return sqrt(dx * dx + dy * dy)
    end

    local function player_pos()
        local p = units.player_position()
        if p and type(p.x) == "number" then return p end
        return nil
    end

    local function facing()
        local pl = units.player()
        if not pl then return 0 end
        local ok, r = pcall(pl.get_rotation, pl)
        if ok and type(r) == "number" then return r end
        return 0
    end

    local function cpu_ms()
        local fn = core.cpu_time
        if type(fn) ~= "function" then return 0 end
        local ok, ns = pcall(fn)
        return ok and type(ns) == "number" and ns / 1e6 or 0
    end

    local function valid_pos(p)
        return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number"
            and type(p.z) == "number" and not (p.x == 0 and p.y == 0 and p.z == 0)
    end

    -- --- the two native reads -----------------------------------------------

    --- Ground under (x, y), from a ray that starts at `start_z` and goes down.
    --- nil on a miss: the native says 0 for that, which no real ground near
    --- the player is going to be exactly.
    local function height(x, y, start_z, water)
        probes_left = probes_left - 1
        tick_probes = tick_probes + 1
        totals.probes = totals.probes + 1
        -- The native starts its ray two yards above the z it is given.
        local pos = vec(x, y, start_z - 2)
        local ok, h
        if water then
            ok, h = pcall(core.get_height_for_position, pos, { water = true })
            if not ok then
                water_supported = false
                log.once("debug", "walkmap_water", "height probe has no water option on this build; water not mapped")
                return nil
            end
        else
            ok, h = pcall(core.get_height_for_position, pos)
        end
        if not ok or type(h) ~= "number" or h == 0 then return nil end
        return h
    end

    --- One native ray call in whichever shape calibration chose (or `shape`
    --- while calibrating). Returns hit (boolean, nil when the call failed)
    --- and the hit position when the call gave one.
    local function raw_ray(from, to, mask, shape)
        shape = shape or R
        rays_left = rays_left - 1
        tick_rays = tick_rays + 1
        totals.rays = totals.rays + 1

        if shape.kind == "trace" then
            local fn = core.graphics and core.graphics.trace_line
            if type(fn) ~= "function" then return nil end
            local ok, v = pcall(fn, vec(from.x, from.y, from.z), vec(to.x, to.y, to.z), mask)
            if not ok or type(v) ~= "boolean" then return nil end
            return v == shape.hit_value, nil
        end

        local fn = core.graphics and core.graphics.native_intersect
        if type(fn) ~= "function" then return nil end
        local a = vec(to.x, to.y, to.z)
        local b = vec(from.x, from.y, from.z)
        if shape.swap then a, b = b, a end
        local dist = 1.0
        if shape.dist_mode == "length" then
            local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
            dist = sqrt(dx * dx + dy * dy + dz * dz)
        end
        local ok, r1, r2 = pcall(fn, a, b, dist, mask)
        if not ok then return nil end
        -- Documented both as three returns and as a { hit, pos, distance }
        -- result; take either.
        if type(r1) == "table" and not valid_pos(r1) then
            local hit = r1[1]
            if hit == nil then hit = r1.hit end
            r1, r2 = hit, r1[2] or r1.position or r1.pos
        end
        if type(r1) ~= "boolean" then return nil end
        return r1, valid_pos(r2) and r2 or nil
    end

    --- How far along from->to (0..1) a point lies.
    local function fraction(from, to, p)
        local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
        local len2 = dx * dx + dy * dy + dz * dz
        if len2 < 1e-9 then return 0 end
        local t = ((p.x - from.x) * dx + (p.y - from.y) * dy + (p.z - from.z) * dz) / len2
        return util.clamp(t, 0, 1)
    end

    local function lerp3(a, b, t)
        return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t }
    end

    -- Hit positions are checked against a second ray for this many hits
    -- before they are simply believed. See ray().
    local VERIFY_HITS = 20

    --- First hit along from->to: hit (nil when rays are unusable), and the
    --- fraction along where it lies. A call that only says yes or no is
    --- narrowed down by halving the segment.
    ---
    --- WHICH END IS THE START. Calibration cannot tell: under the player
    --- there is one surface, the ground, and a ray hits it at the same point
    --- from either end. Along a wall ray there are two -- the near face and
    --- the far one -- and the wrong order reports the far one. So the first
    --- hits are checked: a ray stopping just short of the reported hit must
    --- hit nothing. If it does hit, the order is flipped; if the flipped order
    --- fails the same check, positions are given up for the zone and every
    --- hit is placed by halving instead.
    local function ray(from, to, mask)
        if R.state ~= "ok" then return nil end
        local hit, pos = raw_ray(from, to, mask)
        if hit == nil then return nil end
        if not hit then return false end
        if pos and R.positions then
            local t = fraction(from, to, pos)
            if R.verified >= VERIFY_HITS or t < 0.15 then return true, t end
            local before = raw_ray(from, lerp3(from, to, t - 0.1), mask)
            if before == false then
                R.verified = R.verified + 1
                return true, t
            end
            if not R.flipped then
                R.flipped, R.swap, R.verified = true, not R.swap, 0
                log.fmt("info", "walkmap: ray hits came from the far end; flipping the argument order")
            else
                R.positions = false
                R.note = (R.note or "") .. "; hit positions disagree, yes/no only"
                log.fmt("info", "walkmap: ray hit positions disagree with themselves; placing hits by halving")
            end
        end
        local lo, hi = 0, 1
        for _ = 1, BISECT do
            local mid = (lo + hi) * 0.5
            local h = raw_ray(from, lerp3(from, to, mid), mask)
            if h == nil then break end
            if h then hi = mid else lo = mid end
        end
        return true, hi
    end

    -- --- calibration --------------------------------------------------------

    local SHAPES = {
        { kind = "native", swap = false, dist_mode = "unit" },
        { kind = "native", swap = false, dist_mode = "length" },
        { kind = "native", swap = true,  dist_mode = "unit" },
        { kind = "native", swap = true,  dist_mode = "length" },
        { kind = "trace",  hit_value = true },
        { kind = "trace",  hit_value = false },
    }

    --- Is the player standing on something, so a ray down is sure to hit?
    local function grounded(p)
        if player_svc.is_swimming and player_svc.is_swimming() then return false end
        if player_svc.is_flying and player_svc.is_flying() then return false end
        local h = height(p.x, p.y, p.z + 1.0)
        return h ~= nil and abs(h - p.z) <= 0.6
    end

    local function calibrate(p, t)
        R.tried_at = t
        local has_native = type(core.graphics and core.graphics.native_intersect) == "function"
        local has_trace = type(core.graphics and core.graphics.trace_line) == "function"
        if not has_native and not has_trace then
            R.state, R.note = "unavailable", "no ray call on this build"
            return
        end
        if not grounded(p) then return end   -- try again when standing on something

        local top = { x = p.x, y = p.y, z = p.z + 2.5 }
        local bottom = { x = p.x, y = p.y, z = p.z - 2.5 }
        -- A short ray inside the player's own chest: nothing in the world is
        -- there, or they could not be standing where they are.
        local air_a = { x = p.x, y = p.y, z = p.z + 1.0 }
        local air_b = { x = p.x, y = p.y, z = p.z + 1.3 }

        for i = 1, #SHAPES do
            local s = SHAPES[i]
            local usable = (s.kind == "native" and has_native) or (s.kind == "trace" and has_trace)
            if usable then
                local down, pos = raw_ray(top, bottom, GROUND_MASK, s)
                if down == true then
                    local air = raw_ray(air_a, air_b, WALL_MASK, s)
                    if air == false then
                        R.state = "ok"
                        R.kind, R.swap, R.dist_mode = s.kind, s.swap or false, s.dist_mode or "unit"
                        R.hit_value = s.hit_value
                        if R.hit_value == nil then R.hit_value = true end
                        R.positions = pos ~= nil and abs(pos.z - p.z) <= 0.8
                        R.verified, R.flipped = 0, false
                        R.note = string.format("%s%s%s, %s",
                            s.kind, s.swap and " swapped" or "",
                            s.kind == "native" and (" dist=" .. (s.dist_mode or "unit")) or
                                (" true=" .. tostring(s.hit_value)),
                            R.positions and "hit positions" or "yes/no only")
                        log.fmt("info", "walkmap rays calibrated: %s", R.note)
                        events.emit("jcore.walkmap.calibrated", R.state, R.note)
                        return
                    end
                end
            end
        end
        R.state, R.note = "failed", "no call shape hit the ground and missed the air"
        log.once("warn", "walkmap_rays", "walkmap: ray calls failed calibration; walls come from objects and stuck spots only")
        events.emit("jcore.walkmap.calibrated", R.state, R.note)
    end

    -- --- learned (stuck) spots, saved per map ---------------------------------

    local store = nil
    local function learned_table(create)
        if not store then
            local ok, s = pcall(storage.store, "walkmap")
            if not ok or type(s) ~= "table" then return nil end
            store = s
        end
        local data = store.data
        data.learned = data.learned or {}
        local id = tostring(map_id)
        local t = data.learned[id]
        if not t and create then
            t = {}
            data.learned[id] = t
        end
        return t
    end

    local function load_learned()
        local t = learned_table(false)
        if not t then return 0 end
        local n = 0
        for k, row in pairs(t) do
            local kk = tonumber(k)
            if kk and type(row) == "table" then
                local c = get_cell(kk)
                c.stuck = tonumber(row.n) or 1
                c.sx, c.sy = tonumber(row.x), tonumber(row.y)
                n = n + 1
            end
        end
        return n
    end

    --- Saves a cell's stuck spot, or removes it (c.stuck nil).
    local function save_learned(k, c)
        local t = learned_table(c.stuck ~= nil)
        if not t then return end
        if not c.stuck then
            t[tostring(k)] = nil
        else
            t[tostring(k)] = { n = c.stuck, x = c.sx, y = c.sy }
            -- Over the cap, the spot seen least often goes first.
            local n, weakest, weakest_n = 0, nil, math.huge
            for kk, row in pairs(t) do
                n = n + 1
                local rn = type(row) == "table" and tonumber(row.n) or 0
                if rn < weakest_n then weakest, weakest_n = kk, rn end
            end
            if n > MAX_LEARNED and weakest then t[weakest] = nil end
        end
        pcall(store.touch, store)
    end

    -- --- reset --------------------------------------------------------------

    local walk = nil
    local stuck_win = nil

    local function reset(new_map)
        cells, n_cells, soft = {}, 0, {}
        probe_cursor, probe_anchor = 1, nil
        objects_at = -math.huge
        stuck_win = nil
        R.state, R.kind, R.note, R.tried_at = "untested", nil, nil, -math.huge
        map_id = new_map
        local n = load_learned()
        if n > 0 then log.fmt("debug", "walkmap: %d learned spot(s) for map %s", n, tostring(new_map)) end
    end

    events.on("jcore.zone.changed", function(new_map)
        reset(new_map)
    end, { owner = "jcore", priority = 0 })

    -- --- reading a cell -----------------------------------------------------

    --- Why a cell cannot be stood in, ignoring slope (which needs a neighbour):
    --- "stuck", "wall", "hole", "water", "object", or nil.
    local function cell_block(k, opts)
        local c = cells[k]
        if c then
            if c.stuck then return "stuck" end
            if c.wall > 0 then return "wall" end
            if c.z == false then return "hole" end
            if c.w and c.z and (c.w - c.z) > SWIM_DEPTH and not (opts and opts.water) then return "water" end
        end
        if soft[k] and not (opts and opts.objects == false) then return "object" end
        return nil
    end

    --- The height a step lands on in a cell: the ground, or the water surface
    --- when swimming is allowed (the shore of a lake is not a drop to its bed
    --- for someone who is going to swim it).
    local function floor_of(c, opts)
        if not c or type(c.z) ~= "number" then return nil end
        if c.w and opts and opts.water and c.w > c.z then return c.w end
        return c.z
    end

    -- --- steps --------------------------------------------------------------
    --
    -- A step is a property of the EDGE between two cells, not of either cell:
    -- the top of a table is somewhere to stand once you are up there, and
    -- walking along it or off it is fine. What cannot be done is walking up
    -- onto it. So the flag is kept per edge -- c.ex for the edge between a
    -- cell and the one at +x, c.ey for +y -- and only a move UP across a
    -- flagged edge by more than STEP_UP is refused.

    --- Is the edge from (cx, cy) one cell along (dx, dy) a step?
    local function edge_is_step(cx, cy, dx, dy)
        local c
        if dx == 1 then c = cells[key(cx, cy)]; return c ~= nil and c.ex == true end
        if dx == -1 then c = cells[key(cx - 1, cy)]; return c ~= nil and c.ex == true end
        if dy == 1 then c = cells[key(cx, cy)]; return c ~= nil and c.ey == true end
        if dy == -1 then c = cells[key(cx, cy - 1)]; return c ~= nil and c.ey == true end
        return false
    end

    local function set_edge(cx, cy, dx, dy, step)
        if dx == 1 then get_cell(key(cx, cy)).ex = step
        elseif dx == -1 then get_cell(key(cx - 1, cy)).ex = step
        elseif dy == 1 then get_cell(key(cx, cy)).ey = step
        else get_cell(key(cx, cy - 1)).ey = step end
    end

    --- Can the character move from cell (ax, ay) at height za to the
    --- neighbouring cell (ax + dx, ay + dy) at height zb? nil, or why not:
    --- "ledge" (a step up it cannot take), "steep" (a slope it cannot climb),
    --- "drop" (a fall).
    local function move_block(ax, ay, dx, dy, za, zb, opts)
        if type(za) ~= "number" or type(zb) ~= "number" then return nil end
        local rise = zb - za
        local diagonal = dx ~= 0 and dy ~= 0
        if rise > STEP_UP then
            local step
            if not diagonal then
                step = edge_is_step(ax, ay, dx, dy)
            else
                -- Across a corner, any of the four edges round it will do:
                -- a body does not fit through the point where they meet.
                step = edge_is_step(ax, ay, dx, 0) or edge_is_step(ax, ay, 0, dy)
                    or edge_is_step(ax + dx, ay, 0, dy) or edge_is_step(ax, ay + dy, dx, 0)
            end
            if step then return "ledge" end
        end
        local run = diagonal and 1.4142 or 1
        if rise > MAX_CLIMB * run then return "steep" end
        if -rise > MAX_DROP * run and not (opts and opts.drops) then return "drop" end
        return nil
    end

    --- Is a cell the top of a step -- higher than a neighbour across a
    --- flagged edge? The rims of tables, benches, counters and cliffs.
    local function rim(cx, cy, z)
        if type(z) ~= "number" then return false end
        for j = 1, 4 do
            local dx, dy = (j == 1 and 1) or (j == 2 and -1) or 0, (j == 3 and 1) or (j == 4 and -1) or 0
            if edge_is_step(cx, cy, dx, dy) then
                local n = cells[key(cx + dx, cy + dy)]
                if n and type(n.z) == "number" and z - n.z > STEP_UP then return true end
            end
        end
        return false
    end

    -- --- the ground layer ---------------------------------------------------

    --- A probed neighbour's height, as the reference for a new probe. The
    --- ground chains outward, so a cell is measured against the one beside
    --- it rather than against the player, who may be on the far side of a
    --- hill or under a bridge.
    local function neighbour_z(cx, cy)
        local best, best_d = nil, math.huge
        for dx = -1, 1 do
            for dy = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local c = cells[key(cx + dx, cy + dy)]
                    if c and type(c.z) == "number" then
                        local d = dx * dx + dy * dy
                        if d < best_d then best, best_d = c.z, d end
                    end
                end
            end
        end
        return best
    end

    --- Two probed neighbours differ by more than a step: is it a slope or a
    --- step? Halve the line between their centres, keeping the half with
    --- more of the rise in it, up to three times. A slope leaves an eighth
    --- of its rise in the last piece; a step leaves all of it.
    ---
    --- The first halving settles most slopes: a gentle rise split about
    --- evenly across the two halves is not a step, and a hillside costs one
    --- probe an edge instead of three. A rise past MAX_CLIMB is unwalkable
    --- either way, so it is flagged without probing.
    local function check_edge(cx, cy, dx, dy, za, zb)
        local diff = abs(zb - za)
        if diff <= STEP_UP then return end
        if diff > MAX_CLIMB + 0.1 then
            set_edge(cx, cy, dx, dy, true)
            return
        end
        local ax, ay = centre(cx, cy)
        local bx, by = centre(cx + dx, cy + dy)
        local start = max(za, zb) + 0.4
        local lo, hi, zlo, zhi = 0, 1, za, zb
        for i = 1, 3 do
            local m = (lo + hi) * 0.5
            local zm = height(ax + (bx - ax) * m, ay + (by - ay) * m, start)
            -- Nothing to stand on between them: all at once, whatever it is.
            if not zm then break end
            local first, second = abs(zm - zlo), abs(zhi - zm)
            -- Even, and each half a step at most: a slope. (Even alone is
            -- not enough: floor, bench, table is two steps of half each.)
            if i == 1 and first <= 0.7 * diff and second <= 0.7 * diff
                and first <= STEP_UP and second <= STEP_UP then
                set_edge(cx, cy, dx, dy, false)
                return
            end
            if first >= second then hi, zhi = m, zm else lo, zlo = m, zm end
        end
        set_edge(cx, cy, dx, dy, abs(zhi - zlo) > STEP_UP)
    end

    local SIDES = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

    local function probe_cell(cx, cy, ref_z, player_z)
        local x, y = centre(cx, cy)
        local c = get_cell(key(cx, cy))
        -- First from just over a climbable step above the reference. Starting
        -- higher would land on the bridge deck or tent roof over the cell.
        local h = height(x, y, ref_z + MAX_CLIMB + 0.4)
        -- Nothing: the cell is under a rise we started inside of, or a hole.
        -- From well above, so a hillside reads as high ground (too steep)
        -- rather than as nothing.
        if not h then h = height(x, y, ref_z + 25) end
        if not h or h > ref_z + 30 or h < ref_z - 80 then
            c.z = false
            return
        end
        c.z = h
        -- Water is probed from the shore's height, not the bed's: once the
        -- chain is past the water's edge the reference IS the bed, and a ray
        -- started a yard over the bed starts under the surface it is looking for.
        if water_supported and h < player_z - 0.8 then
            local w = height(x, y, max(ref_z, player_z) + MAX_CLIMB + 0.4, true)
            if w and w > h + 0.3 then c.w = w end
        end
        -- Each edge is looked at once: when the second of its two cells is
        -- probed.
        for i = 1, 4 do
            local dx, dy = SIDES[i][1], SIDES[i][2]
            local n = cells[key(cx + dx, cy + dy)]
            if n and type(n.z) == "number" then check_edge(cx, cy, dx, dy, h, n.z) end
        end
    end

    local function fill_ground(p, deadline)
        local pcx, pcy = cell_of(p.x, p.y)
        local anchor = key(pcx, pcy)
        if anchor ~= probe_anchor then
            probe_anchor, probe_cursor = anchor, 1
        end
        -- The player's own cell is wherever their feet are.
        local own = get_cell(anchor)
        if own.z == nil or own.z == false then own.z = p.z end

        local r2 = radius * radius
        while probes_left > 0 and probe_cursor <= #OFFSETS do
            local o = OFFSETS[probe_cursor]
            if o[3] > r2 then break end
            local cx, cy = pcx + o[1], pcy + o[2]
            local c = cells[key(cx, cy)]
            if not c or c.z == nil then
                probe_cell(cx, cy, neighbour_z(cx, cy) or p.z, p.z)
                if cpu_ms() > deadline then return end
            end
            probe_cursor = probe_cursor + 1
        end
    end

    -- --- the wall layer -----------------------------------------------------

    local function ground_z(x, y, fallback)
        local c = cells[key_at(x, y)]
        if c and type(c.z) == "number" then return c.z end
        return fallback
    end

    local function mark_clear(ox, oy, ux, uy, d0, d1)
        local last = nil
        local d = d0
        while d < d1 do
            local k = key_at(ox + ux * d, oy + uy * d)
            if k ~= last then
                local c = get_cell(k)
                if c.wall > WALL_MIN then c.wall = c.wall - 1 end
                last = k
            end
            d = d + 0.5
        end
    end

    local function mark_wall(x, y)
        local c = get_cell(key_at(x, y))
        c.wall = min(WALL_MAX, max(c.wall, 0) + WALL_HIT)
    end

    --- The height the character would walk at, one yard on from a point at
    --- `prev_z` in cell (pcx, pcy): the next cell's ground if it can be
    --- walked onto from here (a slope, a small step, any drop), and the
    --- height we are already at if it cannot. Rays ride this line, so a ray
    --- at shin height meets the side of a table instead of riding up onto
    --- its top -- which is how 1.12.0 missed every table in an inn.
    local function walk_z(pcx, pcy, prev_z, x, y)
        local cx, cy = cell_of(x, y)
        local c = cells[key(cx, cy)]
        if not c or type(c.z) ~= "number" then return prev_z end
        local dx, dy = cx - pcx, cy - pcy
        if dx == 0 and dy == 0 then return prev_z end
        if abs(dx) > 1 or abs(dy) > 1 then return c.z - prev_z > STEP_UP and prev_z or c.z end
        if move_block(pcx, pcy, dx, dy, prev_z, c.z, nil) == nil or c.z < prev_z then return c.z end
        return prev_z
    end

    --- What did a ray hit at (hx, hy, hz), travelling along (ux, uy)?
    ---   "wall"  something upright: nothing to stand on at the hit's height
    ---   "top"   the side of something lower than a wall with a top more
    ---           than a step above where the ray came from: a bench, a table
    ---   "floor" the ground coming up to meet the ray: a ramp, a stair
    --- One height probe just past the hit says which; a second just before
    --- it tells a raised top from a ramp.
    local function classify_hit(hx, hy, hz, ux, uy)
        local beyond = height(hx + ux * 0.1, hy + uy * 0.1, hz + 0.6)
        -- Upright: the surface under the far side of the hit is well BELOW
        -- the hit -- the floor under a wall -- or there is none. A surface
        -- above the hit (up to the 0.6 the probe starts at) is the top of
        -- the thing that was hit: a table's, a bench's.
        if not beyond or beyond < hz - 0.25 then return "wall", beyond end
        local before = height(hx - ux * 0.15, hy - uy * 0.15, hz + 0.6)
        if not before then return "wall", beyond end
        if beyond - before > STEP_UP then return "top", beyond end
        return "floor", beyond
    end

    local LIFTS = { SHIN, KNEE, CHEST }

    --- One lidar direction: rays at shin, knee and chest height along the
    --- line the character would walk, out to the radius or the first thing
    --- in the way. A segment runs on while the walking height stays level,
    --- up to SEGMENT yards, and breaks where it changes, so a ray is never
    --- asked to cross a step it would cut through the floor of.
    local function scan_direction(p, angle)
        local ux, uy = cos(angle), sin(angle)
        local ox, oy = p.x, p.y
        local pcx, pcy = cell_of(ox, oy)
        local d, z0 = 0.3, p.z
        local wz = p.z
        while d < radius do
            -- Walk the line a yard at a time while the walking height keeps
            -- to the straight line the first yard set (level, or an even
            -- slope). A bend or a step ends the segment BEFORE it; a step in
            -- the first yard is a segment of its own.
            local d1, z1, slope = d, z0, 0
            while d1 < radius and d1 - d < SEGMENT do
                local nd = min(d1 + 1.0, radius)
                local nx, ny = ox + ux * nd, oy + uy * nd
                local nz = walk_z(pcx, pcy, wz, nx, ny)
                local step = abs(nz - wz) > STEP_UP
                if d1 > d and (step or abs(nz - (z0 + slope * (nd - d))) > 0.2) then break end
                if d1 == d then slope = (nz - z0) / (nd - d) end
                pcx, pcy = cell_of(nx, ny)
                wz = nz
                d1, z1 = nd, nz
                if step then break end
            end

            local x0, y0 = ox + ux * d, oy + uy * d
            local x1, y1 = ox + ux * d1, oy + uy * d1
            -- Down a step, the ray stays level: one sloping down from the
            -- top of a step clips the step's own edge and reads it as a wall.
            -- Along a slope, up or down, it follows the slope.
            local end_z = (z0 - z1 > STEP_UP) and z0 or z1
            local best_t, best_h = nil, nil
            for i = 1, #LIFTS do
                local lift = LIFTS[i]
                local from = { x = x0, y = y0, z = z0 + lift }
                local to = { x = x1, y = y1, z = end_z + lift }
                local hit, t = ray(from, to, WALL_MASK)
                if hit == nil then return end
                if hit and (not best_t or t < best_t) then best_t, best_h = t, lift end
            end

            if best_t then
                local hd = d + best_t * (d1 - d)
                local hx, hy = ox + ux * hd, oy + uy * hd
                local hz = z0 + (end_z - z0) * best_t + best_h
                mark_clear(ox, oy, ux, uy, d, hd - 0.6)
                local kind, beyond = classify_hit(hx, hy, hz, ux, uy)
                -- The point the classifying probe looked at, just inside what
                -- was hit. Further in, a ray that clips a corner at an angle
                -- puts its mark on the floor beside the thing.
                local wx, wy = hx + ux * 0.1, hy + uy * 0.1
                if kind == "wall" then
                    mark_wall(wx, wy)
                elseif kind == "top" then
                    -- A top as wide as a cell is the ground layer's: its cell
                    -- reads the top and the edge to it is a step, and the top
                    -- stays somewhere to stand (any wall mark on it is an old
                    -- mistake). Narrower -- a rail, a bench -- and the cell
                    -- reads the floor either side, so only a wall mark keeps
                    -- anyone from walking through it. A cell not measured yet
                    -- is left for a later sweep: guessing "narrow" there put
                    -- wall marks on table tops that nothing took off again.
                    local cell = cells[key_at(wx, wy)]
                    local cz = cell and type(cell.z) == "number" and cell.z or nil
                    if cz and beyond and abs(cz - beyond) < 0.2 then
                        if cell.wall > 0 then cell.wall = 0 end
                    elseif cz then
                        mark_wall(wx, wy)
                    end
                end
                -- Nothing behind it is seen from here, whatever it was.
                return
            end

            mark_clear(ox, oy, ux, uy, d, d1)
            d, z0 = d1, z1
        end
    end

    local function scan_walls(p, deadline)
        if R.state ~= "ok" then return end
        local face = facing()
        local front_count = floor(DIRECTIONS * FRONT_HALF / pi)
        local step = 2 * pi / DIRECTIONS
        local turn = 0
        -- Alternate the front sector and the full circle, so what we walk
        -- towards is seen twice as often as what is behind us.
        while rays_left > 0 do
            local angle
            if turn % 2 == 0 then
                dir_front = (dir_front + 1) % front_count
                angle = face - FRONT_HALF + dir_front * step
            else
                dir_all = (dir_all + 1) % DIRECTIONS
                angle = dir_all * step
            end
            turn = turn + 1
            scan_direction(p, angle)
            if R.state ~= "ok" or cpu_ms() > deadline then return end
        end
    end

    -- --- the object layer ---------------------------------------------------

    local function rebuild_objects(p)
        soft = {}
        local list = units.objects()
        local reach = radius + OBJECT_MAX_R + 1
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot(obj)
            local x, y = row and row.x, row and row.y
            if not x then
                local pos = units.position(obj)
                if pos then x, y = pos.x, pos.y end
            end
            if x and dist2d(x, y, p.x, p.y) <= reach then
                local ok, br = pcall(obj.get_bounding_radius, obj)
                local r = util.clamp((ok and type(br) == "number" and br > 0) and br or 1.0,
                    OBJECT_MIN_R, OBJECT_MAX_R) + OBJECT_PAD
                local cx0, cy0 = cell_of(x - r, y - r)
                local cx1, cy1 = cell_of(x + r, y + r)
                for cx = cx0, cx1 do
                    for cy = cy0, cy1 do
                        local mx, my = centre(cx, cy)
                        if dist2d(mx, my, x, y) <= r then soft[key(cx, cy)] = true end
                    end
                end
            end
        end
    end

    -- --- the stuck layer ----------------------------------------------------

    -- W and the up arrow; the keys that mean something else is going on.
    local KEY_FORWARD = { 0x57, 0x26 }
    local KEY_OTHER = { 0x53, 0x41, 0x44, 0x51, 0x45, 0x25, 0x27, 0x28 }

    --- Is the character being pushed straight forward right now, by us or by
    --- the player's own keys?
    local function pushing_forward()
        if walk and walk.pressing then return true end
        local pressed = input.is_key_pressed
        if type(pressed) ~= "function" then return false end
        if input.is_typing and input.is_typing() then return false end
        for i = 1, #KEY_OTHER do
            if pressed(KEY_OTHER[i]) then return false end
        end
        for i = 1, #KEY_FORWARD do
            if pressed(KEY_FORWARD[i]) then return true end
        end
        return pressed(0x01) and pressed(0x02)
    end

    --- Anything that stops the character moving that is not a wall: a root,
    --- a stun, a cast, swimming, flying, dying.
    local function held_in_place()
        if player_svc.is_dead and player_svc.is_dead() then return true end
        if player_svc.is_swimming and player_svc.is_swimming() then return true end
        if player_svc.is_flying and player_svc.is_flying() then return true end
        if player_svc.is_casting and (player_svc.is_casting() or player_svc.is_channelling()) then return true end
        local loc = player_svc.loss_of_control and player_svc.loss_of_control()
        if type(loc) == "table" and loc.valid then return true end
        return false
    end

    --- Marks the spot in front of the player as blocked: the character pushed
    --- into it and did not move.
    ---@param pos vec3 where the player stood
    ---@param heading number radians, the way they were pushing
    ---@return integer key
    function M.learn_stuck(pos, heading)
        local ux, uy = cos(heading), sin(heading)
        local own = key_at(pos.x, pos.y)
        local sx, sy = pos.x + ux * STUCK_AHEAD, pos.y + uy * STUCK_AHEAD
        local k = key_at(sx, sy)
        if k == own then
            sx, sy = pos.x + ux * (STUCK_AHEAD + 0.6), pos.y + uy * (STUCK_AHEAD + 0.6)
            k = key_at(sx, sy)
        end
        local c = get_cell(k)
        c.stuck = (c.stuck or 0) + 1
        c.sx, c.sy = sx, sy
        totals.stuck = totals.stuck + 1
        save_learned(k, c)
        log.fmt("debug", "walkmap: blocked at %.1f, %.1f (pushed and did not move)", sx, sy)
        events.emit("jcore.walkmap.stuck", vec(sx, sy, pos.z), heading)
        if walk then walk.dirty = true end
        return k
    end

    local function watch_stuck(t, p)
        if not pushing_forward() or held_in_place() then
            stuck_win = nil
            return
        end
        if not stuck_win then
            stuck_win = { t = t, x = p.x, y = p.y, z = p.z }
            return
        end
        -- A fall or a jump is not a wall.
        if abs(p.z - stuck_win.z) > 1.0 or dist2d(p.x, p.y, stuck_win.x, stuck_win.y) > STUCK_MOVE then
            stuck_win = { t = t, x = p.x, y = p.y, z = p.z }
            return
        end
        if t - stuck_win.t >= STUCK_TIME then
            M.learn_stuck(p, facing())
            stuck_win = { t = t, x = p.x, y = p.y, z = p.z }
        end
    end

    --- The player is standing here, so here is walkable, whatever a ray said;
    --- and a stuck spot they are now standing on was never a wall.
    local function stood_in(p)
        local pcx, pcy = cell_of(p.x, p.y)
        local c = get_cell(key(pcx, pcy))
        if c.wall > WALL_MIN then c.wall = WALL_MIN end
        c.walked = true
        for dx = -1, 1 do
            for dy = -1, 1 do
                local k = key(pcx + dx, pcy + dy)
                local n = cells[k]
                if n and n.stuck and (not n.sx or dist2d(n.sx, n.sy, p.x, p.y) <= STUCK_CLEAR)
                    and (n.sx or (dx == 0 and dy == 0)) then
                    n.stuck, n.sx, n.sy = nil, nil, nil
                    totals.cleared = totals.cleared + 1
                    save_learned(k, n)
                    if walk then walk.dirty = true end
                end
            end
        end
    end

    -- --- interest -----------------------------------------------------------

    local function touch() last_query = now() end

    local function active(t)
        if walk or overlay or next(requests) then return true end
        return t - last_query < IDLE_AFTER
    end

    local function effective_radius()
        local r = DEFAULT_RADIUS
        local any = false
        for _, want in pairs(requests) do
            if not any then r, any = want, true else r = max(r, want) end
        end
        if walk then r = max(r, DEFAULT_RADIUS) end
        return util.clamp(r, 5, MAX_RADIUS)
    end

    --- Keeps the map filled out to `r` yards around the player until
    --- released. Without a request the map still answers queries, and fills
    --- for a few seconds after each one.
    ---@param owner string
    ---@param r? number yards, default 20, at most 40
    function M.request(owner, r)
        requests[owner] = util.clamp(r or DEFAULT_RADIUS, 5, MAX_RADIUS)
        return true
    end

    ---@param owner string
    function M.release(owner)
        requests[owner] = nil
    end

    -- --- the line walk ------------------------------------------------------

    --- Can the character walk the straight line from `from` to `to`?
    ---
    --- Walks the line in third-of-a-yard steps, checking the cell under it and
    --- the cells BODY yards to each side (so a gap the line fits through but a
    --- character does not is still a block), and the height change from each
    --- cell to the next.
    ---
    --- opts:
    ---   objects = false   ignore game objects
    ---   water = true      deep water is fine
    ---   drops = true      ledges are fine (going down only)
    ---   unknown = "stop"  treat unprobed cells as blocked (default: pass them)
    ---   body = yards      half-width to keep clear (default 0.4)
    ---@param from vec3
    ---@param to vec3
    ---@param opts? table
    ---@return boolean clear
    ---@return number free yards that are clear before the first block
    ---@return string|nil reason stuck|wall|object|hole|water|ledge|steep|drop|unknown
    ---@return vec3|nil at where the block is
    ---@return integer unknown cells crossed that have not been probed
    function M.clear_line(from, to, opts)
        touch()
        opts = opts or {}
        local body = opts.body or BODY
        local dx, dy = to.x - from.x, to.y - from.y
        local len = sqrt(dx * dx + dy * dy)
        if len < 1e-3 then return true, 0, nil, nil, 0 end
        local ux, uy = dx / len, dy / len
        local px, py = -uy * body, ux * body

        local start = key_at(from.x, from.y)
        local prev = start
        local prev_c = cells[start]
        local prev_z = floor_of(prev_c, opts) or from.z
        local seen = { [start] = true }
        local unknown = 0
        local step = 0.33
        local s = 0
        while s < len do
            s = min(s + step, len)
            local x, y = from.x + ux * s, from.y + uy * s
            local ck = key_at(x, y)
            -- Objects within a yard of the start are the one we are standing
            -- at, not one we are walking into. And the first half yard is
            -- where the character already is: a body-width check there says
            -- only that we are standing next to a wall, which would refuse
            -- every walk along one.
            local near = s < 1.0
            local sides = s >= 0.5 and 3 or 1
            for i = 1, sides do
                local k = i == 1 and ck or key_at(x + (i == 2 and px or -px), y + (i == 2 and py or -py))
                if not seen[k] then
                    seen[k] = true
                    local why = cell_block(k, opts)
                    if why == "object" and near then why = nil end
                    if why then
                        return false, max(0, s - 0.5), why, vec(x, y, prev_z), unknown
                    end
                end
            end
            if ck ~= prev then
                local fz = floor_of(cells[ck], opts)
                if fz then
                    local pcx, pcy = unkey(prev)
                    local ccx, ccy = unkey(ck)
                    local why = move_block(pcx, pcy, ccx - pcx, ccy - pcy, prev_z, fz, opts)
                    if why then return false, max(0, s - 0.5), why, vec(x, y, fz), unknown end
                    prev_z = fz
                else
                    unknown = unknown + 1
                    if opts.unknown == "stop" then
                        return false, max(0, s - 0.5), "unknown", vec(x, y, prev_z), unknown
                    end
                end
                prev = ck
            end
        end
        return true, len, nil, nil, unknown
    end

    --- What is along a heading from the player.
    ---@param heading number radians
    ---@param distance? number yards, default 5
    ---@param opts? table as clear_line
    ---@return { clear: boolean, distance: number, reason: string|nil, at: vec3|nil, heading: number, unknown: integer }
    function M.probe(heading, distance, opts)
        local p = player_pos()
        distance = distance or 5
        if not p then return { clear = false, distance = 0, reason = "no player", heading = heading, unknown = 0 } end
        local to = { x = p.x + cos(heading) * distance, y = p.y + sin(heading) * distance, z = p.z }
        local ok, free, why, at, unknown = M.clear_line(p, to, opts)
        return { clear = ok, distance = free, reason = why, at = at, heading = heading, unknown = unknown }
    end

    --- What is in front of the player, along the way they face.
    ---@param distance? number yards, default 5
    ---@param opts? table as clear_line, plus heading = radians to look along instead
    function M.ahead(distance, opts)
        return M.probe(opts and opts.heading or facing(), distance, opts)
    end

    --- Free distance in `count` directions round the player, starting at the
    --- way they face and going anticlockwise.
    ---@param distance? number yards, default 5
    ---@param count? integer default 16
    ---@param opts? table as clear_line
    ---@return table[] rows of probe results
    function M.around(distance, count, opts)
        count = count or 16
        local face = facing()
        local out = {}
        for i = 0, count - 1 do
            out[#out + 1] = M.probe(face + i * 2 * pi / count, distance, opts)
        end
        return out
    end

    --- Which way round something in front: "left" or "right", by which side
    --- has more free ground at 45 and 90 degrees. nil when neither has any.
    ---@param distance? number yards, default 4
    ---@param opts? table as clear_line
    ---@return string|nil side
    ---@return number heading radians to face for that side
    ---@return number free yards on that side
    function M.free_side(distance, opts)
        distance = distance or 4
        local face = facing()
        local best_side, best_heading, best_free = nil, face, 0
        for _, side in ipairs({ "left", "right" }) do
            local sign = side == "left" and 1 or -1
            local free, heading = 0, face
            for _, deg in ipairs({ 45, 90 }) do
                local h = face + sign * math.rad(deg)
                local r = M.probe(h, distance, opts)
                if r.distance > free then free, heading = r.distance, h end
            end
            if free > best_free + 0.25 then best_side, best_heading, best_free = side, heading, free end
        end
        if best_free < 1.0 then return nil, face, best_free end
        return best_side, best_heading, best_free
    end

    -- --- steering -----------------------------------------------------------

    local OFFSET_DEGREES = { 0, 20, -20, 40, -40, 60, -60, 80, -80, 100, -100, 125, -125, 150, -150, 180 }
    local last_side = 1

    --- The point to face right now to make progress toward `goal` without
    --- walking into anything: the goal itself when the way there is clear,
    --- otherwise the clear heading closest to it. Greedy -- it can be led into
    --- a dead end that path() would not; use it for the next few yards.
    ---@param goal vec3
    ---@param opts? table as clear_line, plus lookahead = yards (default 6)
    ---@return vec3|nil point
    ---@return table info { offset = degrees off the goal bearing, reason = why the direct line is not clear }
    function M.steer(goal, opts)
        opts = opts or {}
        local p = player_pos()
        if not p or not goal then return nil, { reason = "no player" } end
        local distance = dist2d(p.x, p.y, goal.x, goal.y)
        local look = min(opts.lookahead or 6, max(distance, 0.5))
        local bearing = atan2(goal.y - p.y, goal.x - p.x)
        local direct_reason = nil
        for i = 1, #OFFSET_DEGREES do
            -- Keep turning the same way as last time: alternating sides every
            -- tick is a character shuffling in place in front of a wall.
            local deg = OFFSET_DEGREES[i] * last_side
            local h = bearing + math.rad(deg)
            local to = { x = p.x + cos(h) * look, y = p.y + sin(h) * look, z = p.z }
            local ok, _, why = M.clear_line(p, to, opts)
            if deg == 0 and not ok then direct_reason = why end
            if ok then
                if deg ~= 0 then last_side = deg > 0 and 1 or -1 end
                if deg == 0 and distance <= look then return vec(goal.x, goal.y, goal.z), { offset = 0 } end
                return vec(to.x, to.y, ground_z(to.x, to.y, p.z)), { offset = deg, reason = direct_reason }
            end
        end
        return nil, { reason = "boxed in", blocked = direct_reason }
    end

    -- --- the planner --------------------------------------------------------
    --
    -- A* over the cells, eight ways, no cutting a corner past a blocked cell.
    -- Unprobed cells are walkable at a small extra cost: the map fills in as
    -- the character walks and the walker re-plans, so planning only through
    -- what is already known would refuse every walk longer than the radius.

    local function heap_push(h, node, f)
        local n = #h + 1
        h[n] = { f, node }
        while n > 1 do
            local parent = floor(n / 2)
            if h[parent][1] <= h[n][1] then break end
            h[parent], h[n] = h[n], h[parent]
            n = parent
        end
    end

    local function heap_pop(h)
        local n = #h
        if n == 0 then return nil end
        local top = h[1]
        h[1] = h[n]
        h[n] = nil
        n = n - 1
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= n and h[l][1] < h[s][1] then s = l end
            if r <= n and h[r][1] < h[s][1] then s = r end
            if s == i then break end
            h[i], h[s] = h[s], h[i]
            i = s
        end
        return top[2], top[1]
    end

    local NEIGHBOURS = {
        { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
        { 1, 1, 1.4142 }, { 1, -1, 1.4142 }, { -1, 1, 1.4142 }, { -1, -1, 1.4142 },
    }

    local function hard_block(k, opts)
        local why = cell_block(k, opts)
        return why ~= nil and why ~= "object"
    end

    -- How far ahead the smoothing looks for a straight line, in route points.
    -- Unbounded it is a line walk per pair, and a long route is a lot of pairs.
    local SMOOTH_REACH = 24

    --- Smooths a cell route: from each corner, skip to the furthest later
    --- point the straight line reaches.
    local function smooth(points, opts)
        if #points <= 2 then return points end
        local out = { points[1] }
        local i = 1
        local line_opts = { objects = opts.objects, water = opts.water, drops = opts.drops, body = opts.body }
        while i < #points do
            local j = min(#points, i + SMOOTH_REACH)
            while j > i + 1 do
                if M.clear_line(points[i], points[j], line_opts) then break end
                j = j - 1
            end
            out[#out + 1] = points[j]
            i = j
        end
        return out
    end

    --- A route from `from` to `to` round whatever the map knows is in the way.
    ---
    --- opts: as clear_line, plus
    ---   arrive = yards    how close to `to` counts (default 1)
    ---   max_nodes = n     search limit (default 3000)
    ---   margin = yards    how far outside the from-to box to search (default 10)
    ---
    --- Cost: a route across open ground expands a few dozen cells. One with
    --- no way through expands up to max_nodes, a few milliseconds in Lua, so
    --- the walker plans at most once a second.
    ---@param from vec3
    ---@param to vec3
    ---@param opts? table
    ---@return vec3[]|nil waypoints after `from`, ending at or near `to`
    ---@return string|nil reason when nil, or "partial" when the search ran out and this is the best start
    function M.path(from, to, opts)
        touch()
        opts = opts or {}
        if not from or not to then return nil, "no endpoints" end
        local arrive = opts.arrive or 1.0
        local sx, sy = cell_of(from.x, from.y)
        local gx, gy = cell_of(to.x, to.y)
        local margin = floor((opts.margin or 10) / CELL)
        local minx, maxx = min(sx, gx) - margin, max(sx, gx) + margin
        local miny, maxy = min(sy, gy) - margin, max(sy, gy) + margin
        local limit = opts.max_nodes or 3000

        -- A cell is asked about by each of its neighbours; ask the map once.
        local blocked_memo = {}
        local function blocked(k)
            local b = blocked_memo[k]
            if b == nil then
                b = hard_block(k, opts)
                blocked_memo[k] = b
            end
            return b
        end
        local side_memo = {}
        local function side_cost(cx, cy, k)
            local s = side_memo[k]
            if s == nil then
                s = 0
                for j = 1, 4 do
                    local m = NEIGHBOURS[j]
                    if blocked(key(cx + m[1], cy + m[2])) then s = s + WALL_SIDE_COST end
                end
                side_memo[k] = s
            end
            return s
        end

        local function at_goal(cx, cy)
            local mx, my = centre(cx, cy)
            return (cx == gx and cy == gy) or dist2d(mx, my, to.x, to.y) <= max(arrive, 0.75)
        end
        local function h(cx, cy)
            local dx, dy = abs(cx - gx), abs(cy - gy)
            return (dx + dy) + (1.4142 - 2) * min(dx, dy)
        end
        local function z_of(k, fallback)
            return floor_of(cells[k], opts) or fallback
        end

        local start = key(sx, sy)
        local g = { [start] = 0 }
        local came = {}
        local closed = {}
        local open = {}
        heap_push(open, start, h(sx, sy))
        local best, best_h = start, h(sx, sy)
        local expanded = 0
        local found = nil

        while true do
            local k = heap_pop(open)
            if not k then break end
            if not closed[k] then
                closed[k] = true
                local cx, cy = unkey(k)
                if at_goal(cx, cy) then found = k break end
                local hk = h(cx, cy)
                if hk < best_h then best, best_h = k, hk end
                expanded = expanded + 1
                if expanded > limit then break end

                local za = z_of(k, nil)
                for i = 1, 8 do
                    local n = NEIGHBOURS[i]
                    local nx, ny = cx + n[1], cy + n[2]
                    if nx >= minx and nx <= maxx and ny >= miny and ny <= maxy then
                        local nk = key(nx, ny)
                        if not closed[nk] and not blocked(nk)
                            and not (n[3] > 1 and (blocked(key(cx + n[1], cy))
                                or blocked(key(cx, cy + n[2])))) then
                            local zb = z_of(nk, nil)
                            if not move_block(cx, cy, n[1], n[2], za, zb, opts) then
                                local cost = n[3] + side_cost(nx, ny, nk)
                                if zb == nil then cost = cost + UNKNOWN_COST end
                                if soft[nk] and opts.objects ~= false then cost = cost + OBJECT_COST end
                                local ng = g[k] + cost
                                if not g[nk] or ng < g[nk] then
                                    g[nk] = ng
                                    came[nk] = k
                                    heap_push(open, nk, ng + h(nx, ny))
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Every reachable cell in the box was tried and none is the goal:
        -- there is no way, as far as the map knows, and a partial route
        -- would only walk the character into the corner nearest the goal.
        -- A search that hit its node limit instead hands back the best start.
        if not found and expanded <= limit then return nil, "no way through" end
        local tail = found or best
        if tail == start then
            if found then return { vec(to.x, to.y, to.z) }, nil end
            return nil, "no way through"
        end

        local keys = {}
        local k = tail
        while k do
            table.insert(keys, 1, k)
            k = came[k]
        end
        local points = { { x = from.x, y = from.y, z = from.z } }
        for i = 2, #keys do
            local cx, cy = unkey(keys[i])
            local mx, my = centre(cx, cy)
            points[#points + 1] = { x = mx, y = my, z = z_of(keys[i], from.z) }
        end
        -- End on the goal itself, unless it is inside something (an NPC
        -- behind a counter): then on the free cell nearest it.
        if found and not blocked(key(gx, gy)) then points[#points] = { x = to.x, y = to.y, z = to.z } end
        points = smooth(points, opts)

        local out = {}
        for i = 2, #points do out[#out + 1] = vec(points[i].x, points[i].y, points[i].z) end
        return out, (not found) and "partial" or nil
    end

    -- --- the walker ---------------------------------------------------------
    --
    -- Face the next waypoint, hold forward, re-plan when the map changes in
    -- front of us. Same hands as kiting and the mail run (look_at + forward),
    -- which is what is proven to move the character on Forever.

    local REPLAN_EVERY = 1.0
    local WAYPOINT_REACHED = 1.0  -- close enough to cut the corner, if the next leg is clear
    local WAYPOINT_CLOSE = 0.35   -- on it, whatever the next leg says
    local REFACE_ANGLE = math.rad(10)
    local REFACE_EVERY = 0.25
    local NO_PROGRESS = 4.0
    local MAX_UNSTICKS = 4

    local function angle_delta(a, b)
        local d = a - b
        while d > pi do d = d - 2 * pi end
        while d < -pi do d = d + 2 * pi end
        return d
    end

    local function finish(ok, reason)
        local w = walk
        if not w then return end
        walk = nil
        input.set_key(w.owner, "forward", false)
        input.release(input.CHANNEL.MOVEMENT, w.owner)
        input.release(input.CHANNEL.FACING, w.owner)
        log.fmt("debug", "walkmap: walk for %s ended: %s", w.owner, reason)
        events.emit("jcore.walkmap.walk_done", w.owner, ok and true or false, reason)
        if w.on_done then
            local fine, err = pcall(w.on_done, ok and true or false, reason)
            if not fine then log.fmt("error", "walkmap on_done failed: %s", tostring(err)) end
        end
    end

    --- Takes (or renews) movement and facing together. Half a lease is
    --- worse than none: legs with no say over the facing walk wherever
    --- someone else is looking.
    local function lease(w)
        if not input.acquire(input.CHANNEL.MOVEMENT, w.owner, w.priority, w.reason) then return false end
        if input.acquire(input.CHANNEL.FACING, w.owner, w.priority, w.reason) then return true end
        input.release(input.CHANNEL.MOVEMENT, w.owner)
        return false
    end

    local function plan(w, p, t)
        w.last_plan = t
        w.dirty = false
        local route, why = M.path(p, w.goal, w.opts)
        if not route then
            w.path, w.index = nil, 1
            return false, why
        end
        w.path, w.index = route, 1
        return true
    end

    --- Walks the character to `goal`, round whatever the map knows of, and
    --- learning what it did not as it goes. One walk at a time; a second
    --- call replaces the first if the lease allows it.
    ---
    --- opts:
    ---   priority, reason   the movement lease (default PRIORITY.IDLE)
    ---   arrive = yards     how close counts as there (default 1.5)
    ---   timeout = seconds  default 10 + 1 per yard of straight line
    ---   on_done(ok, reason)  "arrived", "preempted", "no way through",
    ---                        "no progress", "timed out", "stopped", "replaced"
    ---   and anything path() takes
    ---@param owner string
    ---@param goal vec3
    ---@param opts? table
    ---@return boolean started
    ---@return string|nil reason when not started
    function M.walk_to(owner, goal, opts)
        opts = opts or {}
        local p = player_pos()
        if not p then return false, "no player" end
        if not goal or type(goal.x) ~= "number" then return false, "no goal" end
        -- The same owner asking again is a new destination.
        if walk and walk.owner == owner then finish(false, "replaced") end

        local t = now()
        local w = {
            owner = owner,
            goal = { x = goal.x, y = goal.y, z = goal.z or p.z },
            opts = opts,
            priority = opts.priority or input.PRIORITY.IDLE,
            reason = opts.reason or "walking",
            arrive = opts.arrive or 1.5,
            on_done = opts.on_done,
            started = t,
            deadline = t + (opts.timeout or (10 + dist2d(p.x, p.y, goal.x, goal.y))),
            best = math.huge,
            progress_at = t,
            unsticks = 0,
            faced_at = -math.huge,
            last_plan = -math.huge,
            pressing = false,
        }
        w.leg_opts = { objects = opts.objects, water = opts.water, drops = opts.drops, body = 0.2 }
        if not lease(w) then
            local holder = input.holder(input.CHANNEL.MOVEMENT)
            return false, "movement held by " .. tostring(holder and holder.owner or "something else")
        end
        -- Someone else's walk, and our lease just outranked it.
        if walk then finish(false, "replaced") end
        walk = w
        local ok, why = plan(w, p, t)
        if not ok then
            finish(false, why)
            return false, why
        end
        events.emit("jcore.walkmap.walk_started", owner, vec(w.goal.x, w.goal.y, w.goal.z))
        return true
    end

    --- Stops the walk if `owner` started it (any walk when owner is nil).
    ---@param owner? string
    function M.stop(owner)
        if not walk then return false end
        if owner and walk.owner ~= owner then return false end
        finish(false, "stopped")
        return true
    end

    --- The walk in progress: owner, goal, path and where along it, or nil.
    function M.walking()
        if not walk then return nil end
        return { owner = walk.owner, goal = walk.goal, path = walk.path, index = walk.index,
            started = walk.started, unsticks = walk.unsticks }
    end

    local function walk_tick(t, p)
        local w = walk
        if not lease(w) then return finish(false, "preempted") end

        local remaining = dist2d(p.x, p.y, w.goal.x, w.goal.y)
        if remaining <= w.arrive then return finish(true, "arrived") end
        if t > w.deadline then return finish(false, "timed out") end

        if remaining < w.best - 0.5 then
            w.best, w.progress_at = remaining, t
        elseif t - w.progress_at > NO_PROGRESS then
            if w.unsticks >= MAX_UNSTICKS then return finish(false, "no progress") end
            -- Whatever is in the way is not on the map. The stuck watch
            -- usually catches it first; this is for a slide along a wall that
            -- never quite stops. A jump clears a lip; the re-plan routes round
            -- whatever the stuck watch marked meanwhile.
            w.unsticks = w.unsticks + 1
            w.progress_at = t
            w.dirty = true
            input.jump()
        end

        -- The leg in front of us is re-checked every tick, narrowly (the
        -- route already keeps off walls; this asks only whether something new
        -- has appeared ON it), and the whole route re-planned once a second
        -- as the map fills in.
        local nxt = w.path and w.path[w.index]
        if not w.path or w.dirty or (t - w.last_plan) >= REPLAN_EVERY
            or (nxt and not M.clear_line(p, nxt, w.leg_opts)) then
            local ok, why = plan(w, p, t)
            if not ok then return finish(false, why or "no way through") end
        end

        -- A waypoint is a corner round something. Cutting it early is fine
        -- only when the leg from here to the one after is clear; otherwise
        -- the cut walks straight back into whatever the corner went round.
        local path = w.path
        while w.index < #path do
            local wp = path[w.index]
            local d = dist2d(p.x, p.y, wp.x, wp.y)
            if d <= WAYPOINT_CLOSE
                or (d <= WAYPOINT_REACHED and M.clear_line(p, path[w.index + 1], w.leg_opts)) then
                w.index = w.index + 1
                w.faced_at = -math.huge
            else
                break
            end
        end
        local target = path[w.index]

        local bearing = atan2(target.y - p.y, target.x - p.x)
        if abs(angle_delta(bearing, facing())) > REFACE_ANGLE or (t - w.faced_at) >= REFACE_EVERY then
            input.look_at(w.owner, target)
            w.faced_at = t
        end
        input.set_key(w.owner, "forward", true)
        w.pressing = true
    end

    -- --- the tick -----------------------------------------------------------

    function M._poll()
        local t = now()
        totals.ticks = totals.ticks + 1
        tick_rays, tick_probes = 0, 0

        local p = player_pos()
        if not p then
            if walk then finish(false, "no player") end
            return
        end
        if map_id == nil then
            local id = world.map_id and world.map_id() or 0
            reset(id)
        end

        stood_in(p)
        watch_stuck(t, p)

        if walk then walk_tick(t, p) end
        if not active(t) then return end

        radius = effective_radius()
        local deadline = cpu_ms() + CPU_BUDGET_MS
        rays_left, probes_left = rays_per_tick, probes_per_tick

        if t - objects_at >= OBJECTS_EVERY then
            objects_at = t
            rebuild_objects(p)
        end

        if R.state == "untested" or (R.state == "failed" and t - R.tried_at >= CALIBRATE_RETRY) then
            calibrate(p, t)
        end

        fill_ground(p, deadline)
        scan_walls(p, deadline)

        -- A long session walks past a lot of ground. Past the cap, keep what
        -- is near and what was learned the hard way.
        if n_cells > MAX_CELLS then
            local keep = (MAX_RADIUS * 2) ^ 2
            local fresh, n = {}, 0
            for k, c in pairs(cells) do
                local cx, cy = unkey(k)
                local mx, my = centre(cx, cy)
                local dx, dy = mx - p.x, my - p.y
                if c.stuck or dx * dx + dy * dy <= keep then
                    fresh[k] = c
                    n = n + 1
                end
            end
            cells, n_cells = fresh, n
        end
    end

    -- --- reading the map ----------------------------------------------------

    --- Everything known about the cell under a point.
    ---@param pos vec3
    ---@return { known: boolean, blocked: string|nil, z: number|nil, water: number|nil, wall: integer, stuck: integer|nil, object: boolean, walked: boolean }
    function M.cell(pos)
        touch()
        local cx, cy = cell_of(pos.x, pos.y)
        local k = key(cx, cy)
        local c = cells[k]
        return {
            known = c ~= nil and c.z ~= nil,
            blocked = cell_block(k),
            -- The top of a step: somewhere to stand, but not to walk up onto.
            ledge = c ~= nil and rim(cx, cy, c.z),
            z = c and type(c.z) == "number" and c.z or nil,
            water = c and c.w or nil,
            wall = c and c.wall or 0,
            stuck = c and c.stuck or nil,
            object = soft[k] == true,
            walked = c and c.walked or false,
        }
    end

    --- Is the cell under a point somewhere the character cannot stand?
    ---@param pos vec3
    ---@param opts? table as clear_line
    ---@return string|nil reason
    function M.blocked(pos, opts)
        touch()
        return cell_block(key_at(pos.x, pos.y), opts)
    end

    --- Marks a spot by hand: "blocked" (saved, like a stuck spot) or "open"
    --- (clears whatever was there). For a consumer that knows better than
    --- the map -- its own stuck detection, or a door it just opened.
    ---@param pos vec3
    ---@param state string "blocked" | "open"
    function M.mark(pos, state)
        local k = key_at(pos.x, pos.y)
        local c = get_cell(k)
        if state == "open" then
            local had = c.stuck
            c.stuck, c.sx, c.sy = nil, nil, nil
            c.wall = WALL_MIN
            if had then save_learned(k, c) end
        else
            c.stuck = (c.stuck or 0) + 1
            c.sx, c.sy = pos.x, pos.y
            save_learned(k, c)
        end
        if walk then walk.dirty = true end
    end

    --- Forgets every cell within `r` yards of `pos` (or everything), so the
    --- next scan measures it again. Learned spots stay; mark(pos, "open")
    --- removes one of those.
    ---@param pos? vec3
    ---@param r? number
    function M.forget(pos, r)
        if not pos then
            local learned = {}
            for k, c in pairs(cells) do
                if c.stuck then learned[k] = { wall = 0, stuck = c.stuck, sx = c.sx, sy = c.sy } end
            end
            cells, n_cells = learned, util.count(learned)
        else
            r = r or DEFAULT_RADIUS
            for k, c in pairs(cells) do
                local cx, cy = unkey(k)
                local mx, my = centre(cx, cy)
                if not c.stuck and dist2d(mx, my, pos.x, pos.y) <= r then
                    cells[k] = nil
                    n_cells = n_cells - 1
                end
            end
        end
        probe_cursor, probe_anchor = 1, nil
    end

    ---@param rays? integer per tick
    ---@param probes? integer per tick
    function M.set_budget(rays, probes)
        if rays then rays_per_tick = util.clamp(floor(rays), 0, 200) end
        if probes then probes_per_tick = util.clamp(floor(probes), 0, 200) end
    end

    --- How rays are being cast this zone, from calibration.
    ---@return { state: string, kind: string|nil, positions: boolean, note: string|nil }
    function M.rays()
        return { state = R.state, kind = R.kind, positions = R.positions, swap = R.swap,
            dist_mode = R.dist_mode, flipped = R.flipped, verified = R.verified,
            hit_value = R.hit_value, note = R.note }
    end

    -- --- the overlay --------------------------------------------------------

    local color_lib
    do
        local ok, mod = pcall(require, "common/color")
        if ok and type(mod) == "table" and type(mod.new) == "function" then color_lib = mod end
    end
    local function make_color(r, g, b, a)
        if color_lib then
            local ok, c = pcall(color_lib.new, r, g, b, a)
            if ok then return c end
        end
        return { r = r, g = g, b = b, a = a }
    end
    local PAINT = {
        stuck  = make_color(220, 70, 220, 170),
        wall   = make_color(235, 70, 70, 150),
        hole   = make_color(240, 140, 40, 170),
        -- The top of a step that cannot be walked up: a table, a bench, a
        -- counter, a cliff. Strong, because it is a block from below.
        ledge  = make_color(245, 105, 35, 175),
        water  = make_color(70, 140, 235, 120),
        object = make_color(235, 210, 70, 120),
        clear  = make_color(90, 210, 120, 220),
        block  = make_color(235, 80, 80, 230),
        route  = make_color(140, 200, 255, 230),
    }
    local OVERLAY_MAX = 400

    ---@param on boolean
    function M.set_overlay(on)
        overlay = on and true or false
    end

    function M.overlay() return overlay end

    local function paint_cell(cx, cy, z, col)
        local x0, y0 = cx * CELL, (cy + 0.5) * CELL
        local mid = vec(x0 + CELL * 0.5, y0, z + 0.08)
        if not draw.is_visible(mid) then return end
        -- A square where the loader has the call, a disc where it does not:
        -- every queued closure is guarded, but a missing call would be an
        -- error logged every frame.
        local g = core.graphics
        if type(g.render_rect_3d_filled_new) == "function" then
            local from = vec(x0 + 0.05, y0, z + 0.08)
            local to = vec(x0 + CELL - 0.05, y0, z + 0.08)
            draw.submit(draw.LAYER.BACKGROUND, function()
                g.render_rect_3d_filled_new(from, to, CELL * 0.9, col)
            end, true)
        elseif type(g.circle_3d_filled) == "function" then
            draw.submit(draw.LAYER.BACKGROUND, function()
                g.circle_3d_filled(mid, CELL * 0.45, col)
            end, true)
        end
    end

    function M._render()
        if not overlay then return end
        local p = player_pos()
        if not p then return end
        local pcx, pcy = cell_of(p.x, p.y)
        local r2 = radius * radius
        local painted = 0
        for i = 1, #OFFSETS do
            local o = OFFSETS[i]
            if o[3] > r2 or painted >= OVERLAY_MAX then break end
            local cx, cy = pcx + o[1], pcy + o[2]
            local k = key(cx, cy)
            local c = cells[k]
            local z = c and type(c.z) == "number" and c.z or p.z
            local col = nil
            if c and c.stuck then col = PAINT.stuck
            elseif c and c.wall > 0 then col = PAINT.wall
            elseif c and c.z == false then col = PAINT.hole
            elseif c and rim(cx, cy, c.z) then col = PAINT.ledge
            elseif c and c.w and type(c.z) == "number" and c.w - c.z > SWIM_DEPTH then col = PAINT.water; z = c.w
            elseif soft[k] then col = PAINT.object
            end
            if col then
                paint_cell(cx, cy, z, col)
                painted = painted + 1
            end
        end

        local a = M.ahead(6)
        local face = facing()
        local tip = a.clear and { x = p.x + cos(face) * 6, y = p.y + sin(face) * 6 } or a.at
        if tip then
            draw.line_3d(vec(p.x, p.y, p.z + 0.2), vec(tip.x, tip.y, p.z + 0.2),
                a.clear and PAINT.clear or PAINT.block, { thickness = 2 })
        end

        if walk and walk.path then
            local pts = { vec(p.x, p.y, p.z + 0.2) }
            for i = walk.index, #walk.path do
                local w = walk.path[i]
                pts[#pts + 1] = vec(w.x, w.y, w.z + 0.2)
            end
            draw.path_3d(pts, PAINT.route, { thickness = 2 })
        end
    end

    -- --- diagnostics --------------------------------------------------------

    -- The counts walk every cell, and the Core page asks every frame it is
    -- open: so at most once a second, or five times a second while the map
    -- is growing.
    local counts, counts_at, counts_cells = nil, -math.huge, -1

    function M.stats()
        local t = now()
        if not counts or t - counts_at >= 1.0 or (n_cells ~= counts_cells and t - counts_at >= 0.2) then
            counts_at, counts_cells = t, n_cells
            counts = { known = 0, walls = 0, stuck = 0, holes = 0, water = 0, steps = 0, objects = util.count(soft) }
            for _, c in pairs(cells) do
                if c.z ~= nil then counts.known = counts.known + 1 end
                if c.ex then counts.steps = counts.steps + 1 end
                if c.ey then counts.steps = counts.steps + 1 end
                if c.stuck then counts.stuck = counts.stuck + 1
                elseif c.wall > 0 then counts.walls = counts.walls + 1 end
                if c.z == false then counts.holes = counts.holes + 1 end
                if c.w and type(c.z) == "number" and c.w - c.z > SWIM_DEPTH then counts.water = counts.water + 1 end
            end
        end
        return {
            active = active(t),
            radius = radius,
            map_id = map_id,
            cells = n_cells,
            known = counts.known,
            walls = counts.walls,
            steps = counts.steps,
            stuck = counts.stuck,
            holes = counts.holes,
            water = counts.water,
            objects = counts.objects,
            rays = R.state,
            ray_note = R.note,
            rays_tick = tick_rays,
            probes_tick = tick_probes,
            rays_total = totals.rays,
            probes_total = totals.probes,
            stuck_learned = totals.stuck,
            stuck_cleared = totals.cleared,
            walking = walk and walk.owner or nil,
            requests = util.count(requests),
            overlay = overlay,
        }
    end

    return M
end

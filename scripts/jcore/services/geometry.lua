-- JCore / geometry -- line of sight, terrain queries and the vector maths
-- that would otherwise be rewritten in every plugin.
--
-- Depends on: util, log, cache, units.
--
-- Two different things live here for one reason: they are both about where
-- things are rather than what they are.
--
-- The expensive half is line of sight. core.graphics.is_line_of_sight is a ray
-- cast through the world, and it is the most costly single call a rotation
-- makes. A priority list that checks LOS on the same target for six different
-- spells casts six identical rays. Here the answer is cached per unit pair per
-- tick, so the sixth check is a table lookup. Terrain height is cached on a
-- coarser grid and a longer timeout, because the ground does not move.
--
-- The cheap half is pure arithmetic on positions -- facing, cones, line
-- shapes, the point a ground-targeted spell should land on. None of it touches
-- the game at all, so none of it is cached; it is here so that every plugin
-- computing "is the target in my cone" agrees on the answer.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local units = rt.units
    local log = rt.log.for_tag("JCore/geometry")

    local try = cache.try
    local sqrt, cos, sin, abs = math.sqrt, math.cos, math.sin, math.abs
    local pi = math.pi
    -- Lua 5.3 removed math.atan2 and folded it into a two-argument math.atan.
    -- This runtime meets both, so bind whichever exists once rather than
    -- branching per call in a hot path.
    local atan2 = math.atan2 or math.atan

    local M = {}

    local los_cache = cache.new("geometry.los", { scope = "tick" })
    local height_cache = cache.new("geometry.height", { scope = "ttl", ttl = 30.0 })

    -- --- line of sight ------------------------------------------------------

    -- NO MODEL RAYS ON FOREVER (1.8.0). Forever crashed four times on
    -- 2026-10-11 with the client's own ASSERT(m_data) in M2HitTest.cpp, each
    -- inside core.graphics.is_line_of_sight from the player to a mob (WoW's
    -- Errors/ reports: the registers hold both ends, eye height at each),
    -- twice in Duskwood as a hunter and twice in Teldrassil as a druid --
    -- every one on build 70338, which the client patched itself to that
    -- night; no report on 70170, 70205 or 70291 has it, through millions of
    -- the same rays. M2HitTest is the client testing a ray against a model
    -- (a tree, a rock, a unit) whose data has not loaded, and a plugin cannot
    -- catch an assert in the client. Fewer rays (draw's half-second keep,
    -- spells' one per target) still crashed at 14:50.
    --
    -- So on Forever the native is never asked. Sight is a trace_line through
    -- buildings and terrain only, with a building's own doodads ignored: no
    -- model on the way, no M2HitTest. A tree or a rock no longer blocks it;
    -- a cast at a mob behind one is refused by the client instead, which the
    -- refusal memory already handles. trace_line's boolean is not documented
    -- either way, so it is calibrated first, as the walk map's rays are: a
    -- ray down from the player's chest must hit the ground and a short one up
    -- must not. Until both agree the answer is nil (unknown) -- never the
    -- native. Every other client keeps is_line_of_sight.
    --
    -- NO RAYS AT ALL ON FOREVER, BY DEFAULT (1.8.1). From 16:50 the same day
    -- Forever died a new way, four times (16:50, 17:08, 21:30, 21:36): the
    -- client's "Fatal Error: Your game crashed" popup and NO report in
    -- Errors/, no Windows crash event, 4.4 GB of commit still free. Never
    -- seen before that day; the first came 1.5 hours after this ray replaced
    -- the native, and since 18:40 the guard has sent every package's sight
    -- ask through it. Until that is cleared, sight on Forever is unknown
    -- without a ray -- the state before calibration, which every caller
    -- already handles (the guard says "in sight", the server judges the
    -- cast). set_forever_rays(true) brings the ray back.
    local forever_rays = false
    local SIGHT_FLAGS = { WmoCollision = 0x10, Terrain = 0x100, IgnoreWmoDoodad = 0x2000 }
    do
        local enums = rt.player and rt.player.enums
        local cf = enums and enums.collision_flags
        if type(cf) == "table" then
            for name in pairs(SIGHT_FLAGS) do
                if type(cf[name]) == "number" then SIGHT_FLAGS[name] = cf[name] end
            end
        end
    end
    local SIGHT_MASK = SIGHT_FLAGS.WmoCollision + SIGHT_FLAGS.Terrain + SIGHT_FLAGS.IgnoreWmoDoodad
    local EYE = 2.0                  -- yards above the feet, each end (the native's own is ~2)
    local CALIBRATE_RETRY = 5.0
    local SIGHT_KEEP = 0.2           -- a frame-rate caller (the ESP's target row) shares one ray

    local sight_cache = cache.new("geometry.sight", { scope = "ttl", ttl = SIGHT_KEEP })
    local forever = nil              -- nil until the world service can say
    local hit_value = nil            -- the boolean trace_line answers for a hit, once calibrated
    local calibrated_at = -math.huge
    local sight_rays = 0

    local function is_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        forever = ok and type(c) == "table" and c.forever == true or false
        return forever
    end

    --- One model-free ray: the boolean trace_line gave, or nil.
    local function sight_ray(ax, ay, az, bx, by, bz)
        local fn = core.graphics and core.graphics.trace_line
        if type(fn) ~= "function" then return nil end
        sight_rays = sight_rays + 1
        local ok, v = pcall(fn, M.vec(ax, ay, az), M.vec(bx, by, bz), SIGHT_MASK)
        if not ok or type(v) ~= "boolean" then return nil end
        return v
    end

    --- Learns which boolean means "hit", once a session. False until then.
    local function calibrate()
        if hit_value ~= nil then return true end
        local now = core.time()
        if now - calibrated_at < CALIBRATE_RETRY then return false end
        calibrated_at = now
        local player = units.player()
        local p = player and units.position(player)
        if not p then return false end
        local chest = p.z + 1.5
        local down = sight_ray(p.x, p.y, chest, p.x, p.y, p.z - 4.0)
        local up = sight_ray(p.x, p.y, chest, p.x, p.y, chest + 1.0)
        if down == nil or up == nil or down == up then
            log.once("warn", "sight_calibrate", string.format(
                "line of sight: trace_line did not tell the ground from the air (down=%s up=%s); sight is unknown until it does",
                tostring(down), tostring(up)))
            return false
        end
        hit_value = down
        log.fmt("info", "line of sight: model-free trace_line, %s means a hit", tostring(hit_value))
        return true
    end

    --- Can `from` see `to`? true, false, or nil when it cannot be told. On
    --- Forever a model-free ray (above), kept SIGHT_KEEP seconds per pair;
    --- elsewhere the client's is_line_of_sight. Nothing on Forever reaches
    --- the native, whoever asks.
    ---@param from game_object
    ---@param to game_object
    ---@return boolean|nil
    function M.sight(from, to)
        if not from or not to then return nil end
        if not is_forever() then
            local ok, v = pcall(core.graphics.is_line_of_sight, from, to)
            if not ok or type(v) ~= "boolean" then return nil end
            return v
        end
        if not forever_rays then return nil end
        local ga, gb = units.guid(from), units.guid(to)
        local key = ga and gb and (ga .. "|" .. gb) or nil
        if key then
            local value, hit = sight_cache:get(key)
            if hit then return value end
        end
        local result = nil
        if calibrate() then
            local a, b = units.position(from), units.position(to)
            if a and b then
                local hit = sight_ray(a.x, a.y, a.z + EYE, b.x, b.y, b.z + EYE)
                if hit ~= nil then result = hit ~= hit_value end
            end
        end
        if key then sight_cache:put(key, result) end
        return result
    end

    --- For the Core page and the tests.
    function M.sight_stats()
        return { forever = is_forever(), forever_rays = forever_rays, hit_value = hit_value,
                 rays = sight_rays, mask = SIGHT_MASK }
    end

    --- Forever only: whether sight casts the model-free ray (off by default
    --- since 1.8.1, see above). Off, sight is unknown and no ray is cast.
    ---@param on boolean
    function M.set_forever_rays(on)
        forever_rays = on == true
        sight_cache:clear()
    end

    --- Forgets the calibration and the kept answers (the tests).
    function M._reset_sight()
        hit_value, calibrated_at = nil, -math.huge
        sight_cache:clear()
    end

    --- Can `from` see `to`?
    ---
    --- Cached per ordered pair per tick. The ray is symmetric in practice, but
    --- keying it that way would mean sorting two guids on every call to build
    --- the key, which costs more than the occasional duplicate ray.
    ---
    --- This is the AUTHORITATIVE check, and the one a decision should use.
    --- draw.unit_los answers the same question for painting and is rationed:
    --- past its per-frame trace budget it answers "visible" rather than spend
    --- another ray, because a mark briefly drawn through a wall costs nothing
    --- and a dropped frame does. Never gate a cast on that one.
    ---@param from game_object
    ---@param to game_object
    ---@return boolean
    function M.line_of_sight(from, to)
        if not from or not to then return false end
        -- Forever: the model-free ray; unknown lets the client judge (1.8.0).
        if is_forever() then return M.sight(from, to) ~= false end

        local a, b = units.guid(from), units.guid(to)
        if not a or not b then
            return try(core.graphics.is_line_of_sight, from, to) and true or false
        end

        local key = a .. "|" .. b
        local value, hit = los_cache:get(key)
        if hit then return value or false end

        local result = try(core.graphics.is_line_of_sight, from, to) and true or false
        return los_cache:put(key, result)
    end

    --- Line of sight from the player.
    ---@param target game_object
    ---@return boolean
    function M.visible(target)
        local player = units.player()
        if not player then return false end
        return M.line_of_sight(player, target)
    end

    --- Raw world ray. Not cached: callers pass arbitrary points, so a key
    --- would almost never hit and building it would cost more than the ray.
    ---@param from vec3
    ---@param to vec3
    ---@param flags? integer collision_flags
    ---@return any
    function M.trace_line(from, to, flags)
        return try(core.graphics.trace_line, from, to, flags)
    end

    ---@param start_pos vec3
    ---@param end_pos vec3
    ---@param distance number
    ---@param hit_mask? integer
    ---@return native_intersect_result|nil
    function M.intersect(end_pos, start_pos, distance, hit_mask)
        local fn = core.graphics.native_intersect
        if type(fn) ~= "function" then return nil end
        local ok, result = pcall(fn, end_pos, start_pos, distance, hit_mask)
        if not ok then return nil end
        return result
    end

    -- --- terrain ------------------------------------------------------------

    --- Ground height under a point, cached on a one-yard grid.
    ---
    --- A pathing consumer asks about thousands of points that differ in the
    --- third decimal, so an exact key would never hit twice. A yard of
    --- granularity is well inside the precision the answer is useful to.
    ---@param pos vec3
    ---@return number|nil
    function M.height_at(pos)
        if not pos then return nil end
        local key = math.floor(pos.x) .. ":" .. math.floor(pos.y)
        local value, hit = height_cache:get(key)
        if hit then return value end
        return height_cache:put(key, try(core.get_height_for_position, pos))
    end

    --- Is a point roughly on the ground, rather than in the air or under it?
    ---@param pos vec3
    ---@param tolerance? number yards, default 2
    ---@return boolean
    function M.is_grounded(pos, tolerance)
        local ground = M.height_at(pos)
        if not ground then return false end
        return abs(pos.z - ground) <= (tolerance or 2.0)
    end

    ---@return vec3|nil
    function M.cursor_world_position()
        return try(core.graphics.get_cursor_world_position)
    end

    -- --- distance -----------------------------------------------------------

    ---@param a vec3
    ---@param b vec3
    ---@return number
    function M.distance(a, b)
        if not a or not b then return math.huge end
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- Squared distance. Use this for comparisons -- a square root that only
    --- feeds a comparison is a square root nobody needed.
    ---@param a vec3
    ---@param b vec3
    ---@return number
    function M.distance_sq(a, b)
        if not a or not b then return math.huge end
        local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
        return dx * dx + dy * dy + dz * dz
    end

    --- Horizontal distance, ignoring height.
    ---
    --- This is the right measure for most range checks: a target on a ledge
    --- three yards up is in range of a ground spell, and including the z
    --- difference says otherwise.
    ---@param a vec3
    ---@param b vec3
    ---@return number
    function M.distance_2d(a, b)
        if not a or not b then return math.huge end
        local dx, dy = a.x - b.x, a.y - b.y
        return sqrt(dx * dx + dy * dy)
    end

    -- --- direction ----------------------------------------------------------

    --- Bearing in radians from `from` to `to`, in the client's convention.
    ---@param from vec3
    ---@param to vec3
    ---@return number
    function M.angle_to(from, to)
        return atan2(to.y - from.y, to.x - from.x)
    end

    --- Shortest signed difference between two angles, in [-pi, pi].
    ---
    --- The wrap is the whole point: without it a bearing of 179 degrees and
    --- one of -179 read as 358 degrees apart instead of two.
    ---@param a number radians
    ---@param b number radians
    ---@return number
    function M.angle_delta(a, b)
        local delta = a - b
        while delta > pi do delta = delta - 2 * pi end
        while delta < -pi do delta = delta + 2 * pi end
        return delta
    end

    --- Is `point` inside a cone of `half_angle` degrees, opening from `origin`
    --- along `facing`?
    ---@param origin vec3
    ---@param facing number radians
    ---@param point vec3
    ---@param half_angle number degrees
    ---@param range? number
    ---@return boolean
    function M.in_cone(origin, facing, point, half_angle, range)
        if range and M.distance_2d(origin, point) > range then return false end
        local bearing = M.angle_to(origin, point)
        return abs(M.angle_delta(bearing, facing)) <= math.rad(half_angle)
    end

    --- Is `point` inside a rectangle running from `origin` along `facing`,
    --- `length` long and `width` wide? The shape most line abilities use.
    ---@param origin vec3
    ---@param facing number radians
    ---@param point vec3
    ---@param length number
    ---@param width number
    ---@return boolean
    function M.in_rect(origin, facing, point, length, width)
        local fx, fy = cos(facing), sin(facing)
        local dx, dy = point.x - origin.x, point.y - origin.y
        local along = dx * fx + dy * fy
        if along < 0 or along > length then return false end
        return abs(dx * -fy + dy * fx) <= width * 0.5
    end

    --- A point `distance` yards from `origin` along `facing`. Where to drop a
    --- ground-targeted spell that should land in front of the caster.
    ---@param origin vec3
    ---@param facing number radians
    ---@param distance number
    ---@return vec3
    function M.project(origin, facing, distance)
        return M.vec(origin.x + cos(facing) * distance,
            origin.y + sin(facing) * distance,
            origin.z)
    end

    --- `distance` yards from `from` toward `to`, keeping the height of `to`.
    --- Clamps to `to` itself rather than overshooting past it.
    ---@param from vec3
    ---@param to vec3
    ---@param distance number
    ---@return vec3
    function M.toward(from, to, distance)
        local total = M.distance_2d(from, to)
        if total <= 0.001 then return M.vec(to.x, to.y, to.z) end
        local t = util.clamp(distance / total, 0, 1)
        return M.vec(from.x + (to.x - from.x) * t,
            from.y + (to.y - from.y) * t,
            from.z + (to.z - from.z) * t)
    end

    --- Builds a vec3 of the runtime's real type where one is available.
    ---
    --- A plain { x, y, z } table has the right fields but is NOT the same type,
    --- and the 3D graphics calls and several natives reject it. Anything this
    --- module hands back goes through here so a caller never has to know.
    ---@param x number
    ---@param y number
    ---@param z number
    ---@return vec3
    local vec3_type
    do
        local ok, mod = pcall(require, "common/geometry/vector_3")
        if ok and mod and type(mod.new) == "function" then
            vec3_type = mod
        else
            log.debug("vec3 constructor unavailable; falling back to plain tables")
        end
    end

    function M.vec(x, y, z)
        if vec3_type then
            local ok, v = pcall(vec3_type.new, x, y, z)
            if ok and v then return v end
        end
        return { x = x, y = y, z = z }
    end

    --- Coerces anything with x, y and z into a real vec3. Cheap and idempotent
    --- for something that already is one.
    ---@param p table
    ---@return vec3
    function M.as_vec(p)
        if not p then return M.vec(0, 0, 0) end
        if vec3_type and getmetatable(p) then return p end
        return M.vec(p.x or 0, p.y or 0, p.z or 0)
    end

    -- --- shapes -------------------------------------------------------------

    --- Centroid of a list of units. The naive answer to "where is the pack",
    --- and wrong whenever the pack has a straggler -- see best_circle for the
    --- version that does not.
    ---@param list game_objects_table
    ---@return vec3|nil
    function M.centroid(list)
        local n = #list
        if n == 0 then return nil end
        local sx, sy, sz = 0, 0, 0
        for i = 1, n do
            local pos = units.position(list[i])
            if pos then
                sx, sy, sz = sx + pos.x, sy + pos.y, sz + pos.z
            end
        end
        return M.vec(sx / n, sy / n, sz / n)
    end

    --- The position of `radius` that covers the most of `list`.
    ---
    --- Candidate centres are the units themselves and the midpoints of pairs.
    --- That is not the true optimum -- the smallest enclosing circle of three
    --- points can be centred where no point is -- but it finds the answer that
    --- matters in practice and stays inside a sane cost for a list of tens.
    ---
    --- Returns the position and how many it covers, so a caller can decide
    --- whether the cast is worth it before making it.
    ---@param list game_objects_table
    ---@param radius number
    ---@return vec3|nil position
    ---@return integer covered
    function M.best_circle(list, radius)
        local n = #list
        if n == 0 then return nil, 0 end

        -- Positions are pulled once up front. Asking units.position inside the
        -- two nested loops would turn an O(n squared) scan into O(n squared)
        -- table lookups through the snapshot, for no gain.
        local xs, ys, zs = {}, {}, {}
        local count = 0
        for i = 1, n do
            local pos = units.position(list[i])
            if pos then
                count = count + 1
                xs[count], ys[count], zs[count] = pos.x, pos.y, pos.z
            end
        end
        if count == 0 then return nil, 0 end

        local limit = radius * radius
        local best_x, best_y, best_z, best_n = xs[1], ys[1], zs[1], 0

        local function score(cx, cy)
            local hits = 0
            for i = 1, count do
                local dx, dy = xs[i] - cx, ys[i] - cy
                if dx * dx + dy * dy <= limit then hits = hits + 1 end
            end
            return hits
        end

        for i = 1, count do
            local hits = score(xs[i], ys[i])
            if hits > best_n then
                best_x, best_y, best_z, best_n = xs[i], ys[i], zs[i], hits
            end
        end

        for i = 1, count - 1 do
            for j = i + 1, count do
                local mx, my = (xs[i] + xs[j]) * 0.5, (ys[i] + ys[j]) * 0.5
                local hits = score(mx, my)
                if hits > best_n then
                    best_x, best_y, best_z, best_n = mx, my, (zs[i] + zs[j]) * 0.5, hits
                end
            end
        end

        return M.vec(best_x, best_y, best_z), best_n
    end

    -- --- screen -------------------------------------------------------------
    --
    -- World-to-screen lives on the draw service, which already caches it per
    -- frame for the units it paints. These forward there rather than keeping a
    -- second cache that would disagree with the first.

    ---@param pos vec3
    ---@return vec2|nil
    function M.to_screen(pos)
        return rt.draw.w2s(pos)
    end

    ---@param pos vec3
    ---@return boolean
    function M.on_screen(pos)
        return rt.draw.is_visible(pos)
    end

    return M
end

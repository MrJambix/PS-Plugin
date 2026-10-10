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

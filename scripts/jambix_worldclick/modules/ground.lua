-- World Click to Move / ground -- the spot on the ground under the cursor.
--
-- The user, 2026-10-11: "should also be a click on the ground". A click
-- that is on nothing walks you to the ground under it.
--
-- WITHOUT A CAMERA READ. The loader has no camera position, only w2s (a
-- world point to the screen). That is enough: the points that w2s puts at
-- the cursor are the cursor's ray. On a flat plane at height h there is one
-- such point, found by Newton's method on w2s (its derivative by finite
-- differences; on a plane the projection is a homography and it converges
-- in a few steps). Two planes, DEPTH apart, give two points of the ray and
-- so its direction. A second ray, ASIDE px to one side, meets the first at
-- the camera, which is where the search along the ray starts; when it does
-- not (a projection without perspective), the search starts BACK_UP yards
-- above your feet, back along the ray.
--
-- THE GROUND ALONG THE RAY. Walking out along the ray, the first surface
-- below each point (core.get_height_for_position: terrain, buildings, docks,
-- doodads) is asked for; the first point the surface is at or above is
-- under the ground, and the crossing is bisected to within a few inches.
-- The steps grow with distance (STEPS), and each probe starts its step's
-- drop above the point, so a slope cannot be stepped through.
--
-- core.graphics.get_cursor_world_position is NOT used: it was never called
-- on Forever (Jambix Debug's API census), it reads the cursor at the press,
-- when the game has already hidden or moved it, and the native rays have
-- crashed this client before (M2HitTest, 2026-10-11). The height probe is
-- the one JCore's walk map and the AIO guide walk already make every frame.
--
-- CHECKED ON SCREEN. The spot found is projected back, and it must land
-- within CHECK_PX of the cursor.

return function(P)
    local units = P.units
    local sqrt, abs, max, min = math.sqrt, math.abs, math.max, math.min
    local vec = P.vec3

    local M = {}

    local DEPTH = 20              -- yd between the two planes the cursor's ray is found on
    local ASIDE = 120             -- px: the second ray, for the camera
    local BACK_UP = 40            -- yd above your feet the search starts, with no camera
    local CAMERA_MAX = 120        -- yd from you: farther is no camera
    local REACH = 400             -- yd along the ray, from the camera
    local CHECK_PX = 40           -- px: the spot projects this near the cursor
    local SOLVE_STEPS = 16
    local SOLVE_PX = 0.5          -- px: a plane point this near the cursor is found
    local SOLVE_JUMP = 250        -- yd: the largest Newton step
    local BISECT = 8
    -- Step length by distance along the ray: (up to yd, step yd).
    local STEPS = { { 60, 1.0 }, { 150, 2.0 }, { math.huge, 3.0 } }

    local stats = { asked = 0, found = 0, missed = 0, probes = 0 }
    local last = nil              -- { how, why, probes }

    local project = P.pick.project
    local in_front = P.pick.in_front

    -- --- the height probe ----------------------------------------------------------

    local options_ok = true       -- false once a core refuses the options table

    --- The first surface below (x, y, z + up): terrain, a roof, a dock. nil
    --- on a miss (the client answers 0 for one).
    local function surface_below(x, y, z, up)
        stats.probes = stats.probes + 1
        local fn = type(core) == "table" and core.get_height_for_position or nil
        if type(fn) ~= "function" then return nil end
        local ok, h
        if options_ok then
            ok, h = pcall(fn, vec(x, y, z), { probe_up = min(1000, max(0, up)) })
            if not ok then options_ok = false end
        end
        if not options_ok then ok, h = pcall(fn, vec(x, y, z + up - 2)) end
        if not ok or type(h) ~= "number" or h ~= h or h == 0 then return nil end
        return h
    end

    --- The ground at (x, y), near `ref_z`: what a map spot is walked to. The
    --- probe nearest `ref_z` of three (just above it, well above it, below
    --- it), as the AIO guide walk does for a waypoint; `ref_z` on a miss.
    function M.height_near(x, y, ref_z)
        local best, best_d
        for _, from in ipairs({ ref_z + 2, ref_z + 30, ref_z - 20, ref_z + 120 }) do
            local h = surface_below(x, y, from, 0)
            if h then
                local d = abs(h - ref_z)
                if not best or d < best_d then best, best_d = h, d end
            end
        end
        return best or ref_z
    end

    -- --- the cursor's ray ------------------------------------------------------------

    --- The point at height `h` that w2s puts at (cx, cy), from a guess.
    local function solve_plane(cx, cy, h, gx, gy)
        local x, y = gx, gy
        for _ = 1, SOLVE_STEPS do
            local sx, sy = project(vec(x, y, h))
            if not sx then return nil end
            local ex, ey = sx - cx, sy - cy
            if ex * ex + ey * ey <= SOLVE_PX * SOLVE_PX then
                if not in_front(vec(x, y, h), sx, sy) then return nil end
                return x, y
            end
            local e = max(0.05, sqrt((x - gx) ^ 2 + (y - gy) ^ 2) * 0.002)
            local ax, ay = project(vec(x + e, y, h))
            local bx, by = project(vec(x, y + e, h))
            if not ax or not bx then return nil end
            local j11, j21 = (ax - sx) / e, (ay - sy) / e
            local j12, j22 = (bx - sx) / e, (by - sy) / e
            local det = j11 * j22 - j12 * j21
            if abs(det) < 1e-12 then return nil end
            local dx = (j22 * ex - j12 * ey) / det
            local dy = (-j21 * ex + j11 * ey) / det
            local len = sqrt(dx * dx + dy * dy)
            if len > SOLVE_JUMP then dx, dy = dx / len * SOLVE_JUMP, dy / len * SOLVE_JUMP end
            x, y = x - dx, y - dy
        end
        return nil
    end

    --- The cursor's ray: a point on it at your feet' height and its unit
    --- direction, away from the camera and down. nil when the cursor is
    --- above the horizon.
    local function ray(cx, cy, feet)
        local ax, ay = solve_plane(cx, cy, feet.z, feet.x, feet.y)
        if not ax then return nil end
        local bx, by = solve_plane(cx, cy, feet.z - DEPTH, ax, ay)
        if not bx then return nil end
        local dx, dy, dz = bx - ax, by - ay, -DEPTH
        local len = sqrt(dx * dx + dy * dy + dz * dz)
        return { x = ax, y = ay, z = feet.z }, { x = dx / len, y = dy / len, z = dz / len }
    end

    --- Where two rays come nearest each other: the camera, or nil.
    local function meet(a, u, b, v, feet)
        local wx, wy, wz = a.x - b.x, a.y - b.y, a.z - b.z
        local uv = u.x * v.x + u.y * v.y + u.z * v.z
        local uw = u.x * wx + u.y * wy + u.z * wz
        local vw = v.x * wx + v.y * wy + v.z * wz
        local den = 1 - uv * uv
        if den < 1e-6 then return nil end      -- parallel: no perspective
        local s = (uv * vw - uw) / den
        local t = (vw - uv * uw) / den
        local p = { x = a.x + u.x * s, y = a.y + u.y * s, z = a.z + u.z * s }
        local q = { x = b.x + v.x * t, y = b.y + v.y * t, z = b.z + v.z * t }
        local gap = sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
        if gap > 2 or s >= 0 then return nil end
        local far = sqrt((p.x - feet.x) ^ 2 + (p.y - feet.y) ^ 2 + (p.z - feet.z) ^ 2)
        if far > CAMERA_MAX then return nil end
        return p, -s
    end

    local function step_at(d)
        for i = 1, #STEPS do
            if d <= STEPS[i][1] then return STEPS[i][2] end
        end
        return STEPS[#STEPS][2]
    end

    --- The spot on the ground under the cursor at (cx, cy): a position, and
    --- how it was found; or nil and why not.
    function M.at(cx, cy)
        stats.asked = stats.asked + 1
        local feet = units.player_position()
        if not feet or not project or not in_front then return nil, "not in the world" end
        local a, u = ray(cx, cy, feet)
        if not a then
            stats.missed = stats.missed + 1
            last = { why = "above the horizon" }
            return nil, "no ground there (above the horizon)"
        end

        -- Where to start: the camera, else BACK_UP yards above your feet.
        local start_back
        local sw = P.draw and P.draw.screen_size and select(1, P.draw.screen_size()) or nil
        local side = (sw and cx + ASIDE > sw) and -ASIDE or ASIDE
        local b, v = ray(cx + side, cy, feet)
        local camera, back = nil, nil
        if b then camera, back = meet(a, u, b, v, feet) end
        if camera then
            start_back = back
        else
            start_back = min(80, BACK_UP / max(0.05, -u.z))
        end
        local function at_t(t)
            return a.x + u.x * (t - start_back), a.y + u.y * (t - start_back), a.z + u.z * (t - start_back)
        end

        local probes0 = stats.probes
        local t, prev_t = 0.5, nil
        local hit_t = nil
        while t <= REACH do
            local step = step_at(t)
            local x, y, z = at_t(t)
            -- A probe from this step's drop above the point: a surface the
            -- ray passed into within the step is still found.
            local up = 2 + step * (1 + abs(u.z))
            local h = surface_below(x, y, z, up)
            if h and h >= z then
                hit_t = t
                break
            end
            prev_t = t
            t = t + step
        end
        if not hit_t then
            stats.missed = stats.missed + 1
            last = { why = "no ground within reach", probes = stats.probes - probes0 }
            return nil, string.format("no ground within %d yd", REACH)
        end

        -- The crossing, between the last point above and the first below.
        local lo, hi = prev_t or max(0, hit_t - 1), hit_t
        for _ = 1, BISECT do
            local mid = (lo + hi) * 0.5
            local x, y, z = at_t(mid)
            local h = surface_below(x, y, z, 2 + (hi - lo))
            if h and h >= z then hi = mid else lo = mid end
        end
        local x, y, z = at_t(hi)
        local h = surface_below(x, y, z, 2 + (hi - lo)) or z
        local spot = vec(x, y, h)

        local sx, sy = project(spot)
        if not sx or (sx - cx) ^ 2 + (sy - cy) ^ 2 > CHECK_PX * CHECK_PX then
            stats.missed = stats.missed + 1
            last = { why = "the spot found is not under the cursor", probes = stats.probes - probes0 }
            return nil, "the ground found is not under the cursor"
        end
        stats.found = stats.found + 1
        last = { how = camera and "from the camera" or "from above you", probes = stats.probes - probes0 }
        return spot, last.how
    end

    function M.stats() return stats end
    function M.last() return last end

    return M
end

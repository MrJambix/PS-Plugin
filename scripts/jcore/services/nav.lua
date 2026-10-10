-- JCore / nav -- pathing, when the Sentinel navigation client is installed.
--
-- Depends on: util, log, cache, events, input, units.
--
-- Sentinel Navigation is a third-party plugin, not part of this API. It may
-- not be installed, it may be installed but not connected to its server, and
-- it may be a version whose client does not have every call below. So nothing
-- here assumes: the client is resolved live, every call is guarded, and
-- M.available() is the gate a consumer checks first.
--
-- The value this adds over calling the client directly is ownership. Movement
-- is a leased channel, and a pathing request is the longest-lived movement
-- claim a plugin can make -- it holds the character for seconds at a time.
-- Routing it through the lease means a defensive that needs to move NOW can
-- preempt a gathering route, and the route stops rather than fighting it.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local events = rt.events
    local input = rt.input
    local units = rt.units
    local log = rt.log.for_tag("JCore/nav")

    local M = {}

    -- The owner currently navigating, and at what priority. Only one, because
    -- there is only one character to move.
    local active = nil

    --- The live client, or nil.
    ---
    --- Resolved on every call rather than cached: the plugin can load after us
    --- and a nil cached at boot would mean navigation is unavailable for the
    --- whole session on a perfectly working setup.
    ---@return sentinel_nav_client|nil
    local function client()
        local global = _G.SentinelNavClient
        if not global then return nil end
        return global.client
    end

    --- Is pathing usable right now?
    ---@return boolean
    function M.available()
        local c = client()
        if not c then return false end
        if type(c.is_server_available) ~= "function" then return true end
        local ok, up = pcall(c.is_server_available, c)
        return ok and up and true or false
    end

    ---@return boolean
    function M.installed()
        return client() ~= nil
    end

    ---@return string|nil
    function M.version()
        local global = _G.SentinelNavClient
        return global and global.VERSION or nil
    end

    --- Calls a client method, tolerating an older client that lacks it.
    local function call(method, ...)
        local c = client()
        if not c then return nil end
        local fn = c[method]
        if type(fn) ~= "function" then
            log.fmt("debug", "nav client has no %s on this version", method)
            return nil
        end
        local ok, result = pcall(fn, c, ...)
        if not ok then
            log.fmt("warn", "nav %s failed: %s", method, tostring(result))
            return nil
        end
        return result
    end

    -- --- movement -----------------------------------------------------------

    --- Wraps a caller's completion callback so the lease is given back however
    --- the route ends -- arrival, failure or cancellation. A route that
    --- finishes without releasing would hold movement until the lease timed
    --- out, which is a second of a plugin not being able to move.
    local function finish(owner, callback)
        return function(success, reason)
            if active and active.owner == owner then
                active = nil
                input.release(input.CHANNEL.MOVEMENT, owner)
            end
            events.emit("jcore.nav.finished", owner, success and true or false, reason)
            if callback then
                local ok, err = pcall(callback, success, reason)
                if not ok then log.fmt("error", "nav callback failed: %s", tostring(err)) end
            end
        end
    end

    --- Paths to a destination and starts walking.
    ---
    --- Takes the movement lease first. A refusal means something with a higher
    --- claim is moving the character, and the correct response is to try again
    --- next tick rather than to force it.
    ---@param owner string
    ---@param target vec3
    ---@param opts? { priority?: number, reason?: string, direct?: boolean, on_done?: fun(ok: boolean, reason?: string) }
    ---@return boolean started
    function M.move_to(owner, target, opts)
        opts = opts or {}
        if not target then return false end
        if not M.available() then
            log.once("warn", "nav_missing", "navigation client unavailable; move_to ignored")
            return false
        end

        local priority = opts.priority or input.PRIORITY.IDLE
        if not input.acquire(input.CHANNEL.MOVEMENT, owner, priority, opts.reason or "navigating") then
            return false
        end

        active = { owner = owner, priority = priority, target = target, started = core.time() }
        local done = finish(owner, opts.on_done)

        local method = opts.direct and "move_direct" or "move_to"
        local result = opts.direct
            and call(method, target, done)
            or call(method, target, done, opts.path_opts)

        if result == nil and not M.is_moving() then
            -- The call did not take. Give the lease back now rather than
            -- holding movement for a route that never started.
            active = nil
            input.release(input.CHANNEL.MOVEMENT, owner)
            return false
        end

        events.emit("jcore.nav.started", owner, target)
        return true
    end

    --- Follows a precomputed list of waypoints.
    ---@param owner string
    ---@param waypoints vec3[]
    ---@param opts? table
    ---@return boolean started
    function M.follow_path(owner, waypoints, opts)
        opts = opts or {}
        if not waypoints or #waypoints == 0 then return false end
        if not M.available() then return false end

        local priority = opts.priority or input.PRIORITY.IDLE
        if not input.acquire(input.CHANNEL.MOVEMENT, owner, priority, opts.reason or "following path") then
            return false
        end

        active = { owner = owner, priority = priority, started = core.time() }
        call("follow_path", waypoints, finish(owner, opts.on_done))
        return true
    end

    --- Plans a route through several nodes without walking it.
    ---@param nodes vec3[]
    ---@param callback fun(ok: boolean, data?: sentinel_nav_route_data)
    ---@param opts? table
    function M.plan_route(nodes, callback, opts)
        return call("plan_route", nodes, callback, opts)
    end

    --- Is a point reachable? A probe, with no movement.
    ---@param target vec3
    ---@param callback fun(reachable: boolean, reason?: string, distance?: number)
    function M.validate(target, callback)
        return call("validate_destination", target, callback)
    end

    --- Stops navigating and gives the lease back.
    ---
    --- `owner` is checked so one plugin cannot cancel another's route by
    --- accident; pass nil to stop whatever is running, which is what the core
    --- itself does on death.
    ---@param owner? string
    function M.stop(owner)
        if owner and active and active.owner ~= owner then return false end
        local holder = active and active.owner
        call("stop")
        active = nil
        if holder then input.release(input.CHANNEL.MOVEMENT, holder) end
        return true
    end

    ---@param reason? string
    function M.replan(reason)
        return call("replan", reason)
    end

    -- --- state --------------------------------------------------------------

    ---@return boolean
    function M.is_moving()
        local result = call("is_moving")
        return result and true or false
    end

    ---@return string
    function M.state()
        return call("get_state") or "idle"
    end

    ---@return string
    function M.full_state()
        return call("get_full_state") or M.state()
    end

    ---@return vec3|nil
    function M.destination()
        return call("get_destination")
    end

    ---@return sentinel_nav_progress|nil
    function M.progress()
        return call("get_progress")
    end

    ---@return vec3[]|nil
    function M.current_path()
        return call("get_current_path")
    end

    --- Who is navigating, at what priority, and for how long.
    ---@return table|nil
    function M.holder()
        return active
    end

    --- Distance still to walk along the planned path, not the straight line to
    --- the destination. The two differ by a lot around a corner, and an
    --- arrival check written against the straight line fires early.
    ---@return number
    function M.remaining_distance()
        local path = M.current_path()
        if not path or #path == 0 then return math.huge end

        local from = units.player_position()
        if not from then return math.huge end

        local index = call("get_path_index") or 1
        local total = 0
        local previous = from

        for i = math.max(1, math.floor(index)), #path do
            local point = path[i]
            if point then
                local dx, dy, dz = point.x - previous.x, point.y - previous.y, point.z - previous.z
                total = total + math.sqrt(dx * dx + dy * dy + dz * dz)
                previous = point
            end
        end
        return total
    end

    -- --- lifecycle ----------------------------------------------------------

    --- Drops a route whose owner has gone away or been preempted. Called once
    --- per tick by the runtime.
    function M._poll()
        if not active then return end

        if not input.holds(input.CHANNEL.MOVEMENT, active.owner) then
            log.fmt("debug", "%s lost movement while navigating; stopping route", active.owner)
            local owner = active.owner
            active = nil
            call("stop")
            events.emit("jcore.nav.finished", owner, false, "preempted")
        end
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            installed = M.installed(),
            available = M.available(),
            version   = M.version(),
            state     = M.state(),
            owner     = active and active.owner or nil,
            remaining = active and M.remaining_distance() or nil,
        }
    end

    return M
end

-- JCore / registry -- who is registered, what they depend on, when they run.
--
-- Depends on: util, log, events, scheduler.
--
-- A plugin registers once, at load, and gets back a context handle. Everything
-- it then does through that handle is tagged with its id, which is what makes
-- unregistering actually complete: events, scheduler jobs, draw submissions,
-- cast claims and menu observers all disappear together.
--
-- Dependencies are declared, not discovered. `requires = { "jambix.units" }`
-- means the registry holds this plugin back until that id has registered, then
-- starts it. A dependency that never arrives leaves the plugin in `waiting`
-- forever rather than half-starting it -- visible on the diagnostics page, and
-- far easier to debug than a nil-index error deep in someone's rotation.

return function(rt)
    local util = rt.util
    local events = rt.events
    local scheduler = rt.scheduler
    local log = rt.log.for_tag("JCore/registry")

    local M = {}

    -- id -> record
    local plugins = {}
    -- registration order, so listings are deterministic
    local order = {}

    local STATE = {
        WAITING = "waiting",   -- registered, dependencies unmet
        READY   = "ready",     -- dependencies met, on_load not yet called
        RUNNING = "running",
        PAUSED  = "paused",    -- user or core disabled it
        FAILED  = "failed",    -- on_load raised
        STOPPED = "stopped",   -- unregistered
    }
    M.STATE = STATE

    ---@class jcore_manifest
    ---@field id string            Reverse-DNS, stable forever. The tag on everything it owns.
    ---@field name? string         Display name. Defaults to id.
    ---@field version? string      "1.0.0"
    ---@field kind? string         "rotation" | "plugin" | "library" | "esp"
    ---@field requires? string[]   Other plugin ids that must be running first.
    ---@field on_load? fun(ctx): nil
    ---@field on_unload? fun(ctx): nil
    ---@field on_enable? fun(ctx): nil
    ---@field on_disable? fun(ctx): nil

    local function dependencies_met(record)
        local requires = record.manifest.requires
        if not requires or #requires == 0 then return true, nil end
        for i = 1, #requires do
            local dep = plugins[requires[i]]
            if not dep or dep.state ~= STATE.RUNNING then
                return false, requires[i]
            end
        end
        return true, nil
    end

    local function start(record)
        local ok, err = true, nil
        local on_load = record.manifest.on_load
        if on_load then
            ok, err = pcall(on_load, record.ctx)
        end

        if ok then
            record.state = STATE.RUNNING
            record.started_at = core.time()
            log.fmt("info", "started %s v%s", record.id, record.manifest.version or "?")
            events.emit("jcore.plugin.started", record.id, record.ctx)
            -- Starting one plugin can unblock others that were waiting on it.
            M.resolve_waiting()
        else
            record.state = STATE.FAILED
            record.error = tostring(err)
            log.fmt("error", "%s failed to load: %s", record.id, record.error)
            -- A plugin that blew up in on_load may have registered half its
            -- hooks already. Tear those down so the wreckage does not keep
            -- running on every frame.
            events.off_owner(record.id)
            scheduler.remove_owner(record.id)
            if rt.units then rt.units.release_range(record.id) end
            if rt.input then rt.input.release_all(record.id) end
            if rt.walkmap then
                rt.walkmap.stop(record.id)
                rt.walkmap.release(record.id)
            end
            events.emit("jcore.plugin.failed", record.id, record.error)
        end
    end

    --- Promotes every `waiting` plugin whose dependencies are now satisfied.
    --- Runs repeatedly until a pass changes nothing, so a chain A -> B -> C
    --- settles in one call regardless of registration order.
    function M.resolve_waiting()
        local changed = true
        local guard = 0
        while changed and guard < 32 do
            changed = false
            guard = guard + 1
            for i = 1, #order do
                local record = plugins[order[i]]
                if record and record.state == STATE.WAITING then
                    local met, missing = dependencies_met(record)
                    if met then
                        record.state = STATE.READY
                        record.missing = nil
                        start(record)
                        changed = true
                    else
                        record.missing = missing
                    end
                end
            end
        end
    end

    --- Registers a plugin and returns its context handle.
    ---
    --- The handle is returned immediately even when dependencies are unmet, so
    --- a caller can always assign it at module scope. What is deferred is
    --- on_load, not the handle.
    ---
    ---@param manifest jcore_manifest
    ---@param ctx_factory fun(record): table
    ---@return table ctx
    function M.register(manifest, ctx_factory)
        assert(type(manifest) == "table", "register expects a manifest table")
        assert(type(manifest.id) == "string" and manifest.id ~= "", "manifest.id is required")

        local id = manifest.id

        if plugins[id] then
            -- A duplicate id almost always means the same package got loaded
            -- twice, or two authors picked the same string. Hand back the
            -- existing handle rather than silently shadowing the first one:
            -- returning a second live context would leave two sets of hooks
            -- both claiming the same owner tag.
            log.fmt("warn", "duplicate registration for '%s'; returning the existing context", id)
            return plugins[id].ctx
        end

        local record = {
            id            = id,
            manifest      = manifest,
            state         = STATE.WAITING,
            registered_at = core.time(),
            started_at    = nil,
            error         = nil,
            missing       = nil,
            enabled       = true,
        }

        plugins[id] = record
        order[#order + 1] = id

        record.ctx = ctx_factory(record)

        log.fmt("debug", "registered %s (%s)", id, manifest.kind or "plugin")
        events.emit("jcore.plugin.registered", id, record.ctx)

        M.resolve_waiting()
        return record.ctx
    end

    --- Tears a plugin down completely and drops every hook it owns.
    ---@param id string
    function M.unregister(id)
        local record = plugins[id]
        if not record then return false end

        if record.state == STATE.RUNNING and record.manifest.on_unload then
            local ok, err = pcall(record.manifest.on_unload, record.ctx)
            if not ok then
                log.fmt("error", "%s on_unload failed: %s", id, tostring(err))
            end
        end

        events.off_owner(id)
        scheduler.remove_owner(id)
        -- Resolved late: services are built after the registry, so rt.units
        -- is nil at factory time but present by the time anything unregisters.
        if rt.units then rt.units.release_range(id) end
        -- A plugin holding the movement channel when it goes away would keep
        -- the character walking with nobody left to stop it, so its leases go
        -- with it and any keys it was holding are released.
        if rt.input then rt.input.release_all(id) end
        if rt.nav then rt.nav.stop(id) end
        -- Its walk too, and its request that the map keep scanning.
        if rt.walkmap then
            rt.walkmap.stop(id)
            rt.walkmap.release(id)
        end
        -- Its overlay windows, retained bodies and widget state go too.
        if rt.ui then rt.ui.remove_owner(id) end
        events.emit("jcore.plugin.unregistered", id)

        record.state = STATE.STOPPED
        plugins[id] = nil
        util.array_remove(order, id)

        -- Anything that depended on this one must stop being RUNNING.
        for i = 1, #order do
            local other = plugins[order[i]]
            if other and other.state == STATE.RUNNING then
                local met, missing = dependencies_met(other)
                if not met then
                    other.state = STATE.WAITING
                    other.missing = missing
                    scheduler.set_owner_enabled(other.id, false)
                    log.fmt("warn", "%s went back to waiting: dependency '%s' is gone",
                        other.id, missing)
                end
            end
        end

        log.fmt("info", "unregistered %s", id)
        return true
    end

    --- Pauses or resumes a plugin. Its registrations survive; its jobs stop.
    ---@param id string
    ---@param enabled boolean
    function M.set_enabled(id, enabled)
        local record = plugins[id]
        if not record then return false end
        if record.enabled == enabled then return true end

        record.enabled = enabled
        scheduler.set_owner_enabled(id, enabled)

        local hook = enabled and record.manifest.on_enable or record.manifest.on_disable
        if hook then
            local ok, err = pcall(hook, record.ctx)
            if not ok then
                log.fmt("error", "%s on_%s failed: %s", id, enabled and "enable" or "disable", tostring(err))
            end
        end

        if record.state == STATE.RUNNING or record.state == STATE.PAUSED then
            record.state = enabled and STATE.RUNNING or STATE.PAUSED
        end

        events.emit(enabled and "jcore.plugin.enabled" or "jcore.plugin.disabled", id)
        return true
    end

    ---@param id string
    function M.is_running(id)
        local record = plugins[id]
        return record ~= nil and record.state == STATE.RUNNING and record.enabled
    end

    ---@param id string
    function M.get(id)
        return plugins[id]
    end

    --- Registration-ordered list of plain summary rows, safe to hand to UI.
    function M.list()
        local rows = {}
        for i = 1, #order do
            local record = plugins[order[i]]
            if record then
                rows[#rows + 1] = {
                    id       = record.id,
                    name     = record.manifest.name or record.id,
                    kind     = record.manifest.kind or "plugin",
                    version  = record.manifest.version or "?",
                    state    = record.state,
                    enabled  = record.enabled,
                    missing  = record.missing,
                    error    = record.error,
                    uptime   = record.started_at and (core.time() - record.started_at) or 0,
                }
            end
        end
        return rows
    end

    function M.count()
        return #order
    end

    return M
end

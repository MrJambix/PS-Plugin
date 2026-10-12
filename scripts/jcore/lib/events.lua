-- JCore / events -- the bus every plugin talks over.
--
-- Depends on: util, log.
--
-- Contract:
--   * A subscriber NEVER raises into the emitter. Every handler is pcall'd.
--   * A handler that raises repeatedly is quarantined rather than left to
--     poison the frame forever. One broken plugin must not take the core down.
--   * Every subscription is tagged with its owning plugin id, so unregistering
--     a plugin removes all of its hooks in one call. Without that tag an
--     unloaded plugin keeps receiving events through a closure the registry can
--     no longer reach, which is the classic leak in this kind of framework.
--   * Emitting from inside a handler is legal. The dispatch list is snapshotted
--     per emit, so subscribing or unsubscribing during dispatch is safe and
--     takes effect on the NEXT emit.

return function(rt)
    local util = rt.util
    local log = rt.log.for_tag("JCore/events")
    -- Handlers run through it: a plain pcall unless Jambix Debug listens
    -- (lib/faults, 1.8.1). A runtime built without it gets the plain pcall.
    local faults = rt.faults or rt.util.no_faults

    local M = {}

    -- event name -> array of subscriptions (sorted by priority ascending)
    local subs = {}
    -- event name -> true while its list needs re-sorting
    local dirty = {}

    local ERROR_QUARANTINE = 5 -- consecutive failures before a handler is cut

    ---@class jcore_subscription
    ---@field event string
    ---@field fn function
    ---@field owner string
    ---@field priority number
    ---@field once boolean
    ---@field errors integer
    ---@field dead boolean

    --- Subscribe to `event`.
    ---
    --- Lower `priority` runs earlier; ties keep registration order. The core's
    --- own internal listeners sit at priority 0, so a plugin that must observe
    --- state before the core reacts uses a negative priority.
    ---
    ---@param event string
    ---@param fn fun(...): any
    ---@param opts? { owner?: string, priority?: number, once?: boolean }
    ---@return jcore_subscription
    function M.on(event, fn, opts)
        assert(type(event) == "string", "event name must be a string")
        assert(type(fn) == "function", "event handler must be a function")
        opts = opts or {}

        local sub = {
            event    = event,
            fn       = fn,
            owner    = opts.owner or "anonymous",
            priority = opts.priority or 100,
            once     = opts.once and true or false,
            errors   = 0,
            dead     = false,
        }

        local list = subs[event]
        if not list then
            list = {}
            subs[event] = list
        end
        list[#list + 1] = sub
        dirty[event] = true

        return sub
    end

    ---@param event string
    ---@param fn fun(...): any
    ---@param opts? { owner?: string, priority?: number }
    function M.once(event, fn, opts)
        opts = opts and util.shallow_copy(opts) or {}
        opts.once = true
        return M.on(event, fn, opts)
    end

    --- Cancels a subscription. Safe to call during dispatch and safe to call
    --- twice. The entry is flagged dead and reaped on the next emit rather than
    --- spliced out immediately, because an in-flight dispatch may be walking
    --- the very list we would be mutating.
    ---@param sub jcore_subscription
    function M.off(sub)
        if type(sub) ~= "table" or sub.dead then return false end
        sub.dead = true
        dirty[sub.event] = true
        return true
    end

    --- Removes every subscription belonging to `owner`, across all events.
    ---@param owner string
    ---@return integer removed
    function M.off_owner(owner)
        local removed = 0
        for event, list in pairs(subs) do
            for i = 1, #list do
                local sub = list[i]
                if not sub.dead and sub.owner == owner then
                    sub.dead = true
                    removed = removed + 1
                    dirty[event] = true
                end
            end
        end
        return removed
    end

    --- Drops dead entries and restores priority order.
    local function compact(event)
        local list = subs[event]
        if not list then return end
        local out, n = {}, 0
        for i = 1, #list do
            local sub = list[i]
            if not sub.dead then
                n = n + 1
                out[n] = sub
            end
        end
        util.stable_sort_by(out, function(s) return s.priority end)
        subs[event] = out
        dirty[event] = nil
    end

    --- Fires `event`. Returns the number of handlers that ran without error.
    ---
    --- Arguments are forwarded as-is. Handlers get no return channel by design:
    --- an event is a notification, not a query. Use a service call when a
    --- plugin needs an answer back.
    ---@param event string
    ---@return integer delivered
    function M.emit(event, ...)
        local list = subs[event]
        if not list or #list == 0 then return 0 end

        if dirty[event] then
            compact(event)
            list = subs[event]
        end

        -- Snapshot: a handler is allowed to subscribe or unsubscribe mid-emit.
        local snapshot, count = {}, #list
        for i = 1, count do snapshot[i] = list[i] end

        local delivered = 0
        for i = 1, count do
            local sub = snapshot[i]
            if not sub.dead then
                local deep = faults.deep
                if deep then faults.enter(sub) end
                local ok, err = faults.call("event", sub, sub.fn, ...)
                if deep then faults.leave(sub) end
                if ok then
                    sub.errors = 0
                    delivered = delivered + 1
                    if sub.once then
                        sub.dead = true
                        dirty[event] = true
                    end
                else
                    sub.errors = sub.errors + 1
                    log.fmt("error", "handler for '%s' (owner %s) failed: %s",
                        event, sub.owner, tostring(err))
                    if sub.errors >= ERROR_QUARANTINE then
                        sub.dead = true
                        dirty[event] = true
                        log.fmt("error",
                            "quarantined handler for '%s' (owner %s) after %d consecutive errors",
                            event, sub.owner, sub.errors)
                    end
                end
            end
        end

        return delivered
    end

    ---@param event string
    ---@return integer
    function M.listener_count(event)
        local list = subs[event]
        if not list then return 0 end
        local n = 0
        for i = 1, #list do
            if not list[i].dead then n = n + 1 end
        end
        return n
    end

    --- Snapshot for the diagnostics page: event name -> live listener count.
    function M.describe()
        local out = {}
        for event in pairs(subs) do
            local n = M.listener_count(event)
            if n > 0 then out[event] = n end
        end
        return out
    end

    return M
end

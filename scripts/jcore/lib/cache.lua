-- JCore / cache -- the memoisation layer every service reads through.
--
-- Depends on: util, log.
--
-- WHY THIS EXISTS
-- Almost nothing in this runtime is slow because of Lua. It is slow because a
-- native round trip costs orders of magnitude more than a table lookup, and a
-- rotation asks the same question many times per frame: how much health does
-- the target have, is that spell off cooldown, how many enemies are in front of
-- me. Answering each of those once per tick and handing out the stored answer
-- is the whole performance story of a core.
--
-- Three lifetimes cover every case in practice:
--
--   tick    -- valid for the current update only. The default, and correct for
--              anything the game can change between frames: health, position,
--              cooldowns, casting state.
--   ttl     -- valid for N seconds. For facts that change rarely but are not
--              pinned to any event we can see: whether an addon is loaded, the
--              contents of a vendor window.
--   manual  -- valid until something invalidates it, either a call or a named
--              game event. For static data: spell names, item info, map names.
--
-- COST OF THE CACHE ITSELF
-- A tick-scoped cache does NOT stamp every entry. It stamps the cache, and
-- drops the whole value table the first time it is touched in a new tick. That
-- makes a hit exactly two table lookups and an integer compare, which is the
-- point -- a cache that costs more than the call it replaces is a pessimisation
-- with extra steps.

return function(rt)
    local util = rt.util
    local log = rt.log.for_tag("JCore/cache")

    local M = {}

    -- Distinguishes "we cached the answer nil" from "we have no answer". A
    -- native that legitimately returns nil (no target, no aura) would otherwise
    -- be re-called every single time, which is exactly the hot path we are
    -- here to remove.
    local NIL = setmetatable({}, { __tostring = function() return "jcore.nil" end })
    M.NIL = NIL

    local tick_id = 0
    local registry = {}        -- name -> cache
    local event_bound = {}     -- game event name -> array of caches

    --- Bumped once per update by the runtime, immediately after the unit
    --- sweep. Everything tick-scoped expires here.
    function M._new_tick()
        tick_id = tick_id + 1
    end

    function M.tick_id() return tick_id end

    --- Routed from the game-event bus by the runtime. A cache declared with
    --- `events = { "BAG_UPDATE" }` clears when that event fires.
    ---@param event_name string
    function M._on_game_event(event_name)
        local bound = event_bound[event_name]
        if not bound then return end
        for i = 1, #bound do bound[i]:clear() end
    end

    -- --- cache object -------------------------------------------------------

    local Cache = {}
    Cache.__index = Cache

    --- Drops the stored table when the tick has moved on. Tick-scoped caches
    --- pay their whole invalidation cost here: one compare on a hit, one table
    --- allocation per tick on the first access of that tick.
    local function fresh_tick(self)
        if self.epoch ~= tick_id then
            self.values = {}
            self.epoch = tick_id
        end
    end

    ---@param key any Use `true` for a cache holding a single value.
    ---@return any value
    ---@return boolean hit
    function Cache:get(key)
        if self.scope == "tick" then fresh_tick(self) end

        local stored = self.values[key]
        if stored == nil then
            self.misses = self.misses + 1
            return nil, false
        end

        if self.scope == "ttl" then
            local at = self.stamps[key]
            if not at or (core.time() - at) > self.ttl then
                self.values[key] = nil
                self.stamps[key] = nil
                self.misses = self.misses + 1
                return nil, false
            end
        end

        self.hits = self.hits + 1
        if stored == NIL then return nil, true end
        return stored, true
    end

    ---@param key any
    ---@param value any A nil value is stored as a real "the answer is nothing".
    ---@return any value
    function Cache:put(key, value)
        if self.scope == "tick" then fresh_tick(self) end
        self.values[key] = (value == nil) and NIL or value
        if self.scope == "ttl" then self.stamps[key] = core.time() end
        return value
    end

    --- Memoised call. `fn(a, b, c)` runs only on a miss.
    ---
    --- Arguments are passed through rather than closed over deliberately: a
    --- closure per call allocates, and this is called from rotation code that
    --- runs tens of times per frame.
    ---@param key any
    ---@param fn function
    ---@return any
    function Cache:fetch(key, fn, a, b, c)
        local value, hit = self:get(key)
        if hit then return value end
        local ok, result = pcall(fn, a, b, c)
        if not ok then
            -- A native that raised is still an answer for this tick. Caching
            -- the failure stops a bad spell id from costing a raise per call
            -- for the rest of the frame.
            self.errors = self.errors + 1
            self:put(key, nil)
            return nil
        end
        return self:put(key, result)
    end

    ---@param key any
    function Cache:invalidate(key)
        self.values[key] = nil
        if self.stamps then self.stamps[key] = nil end
    end

    function Cache:clear()
        self.values = {}
        if self.stamps then self.stamps = {} end
        self.clears = self.clears + 1
    end

    function Cache:stats()
        local total = self.hits + self.misses
        return {
            name    = self.name,
            scope   = self.scope,
            hits    = self.hits,
            misses  = self.misses,
            errors  = self.errors,
            clears  = self.clears,
            size    = util.count(self.values),
            hit_pct = total > 0 and (self.hits / total * 100.0) or 0,
        }
    end

    -- --- construction -------------------------------------------------------

    ---@param name string Shown on the diagnostics page.
    ---@param opts? { scope?: "tick"|"ttl"|"manual", ttl?: number, events?: string[] }
    ---@return table cache
    function M.new(name, opts)
        opts = opts or {}
        local scope = opts.scope or "tick"

        local cache = setmetatable({
            name   = name,
            scope  = scope,
            ttl    = opts.ttl or 1.0,
            values = {},
            stamps = (scope == "ttl") and {} or nil,
            epoch  = -1,
            hits   = 0,
            misses = 0,
            errors = 0,
            clears = 0,
        }, Cache)

        registry[name] = cache

        if opts.events then
            for i = 1, #opts.events do
                local event = opts.events[i]
                local bound = event_bound[event]
                if not bound then
                    bound = {}
                    event_bound[event] = bound
                end
                bound[#bound + 1] = cache
            end
        end

        return cache
    end

    -- --- helpers ------------------------------------------------------------

    --- pcall that answers nil instead of a second return value, for the very
    --- common "read a native, do not care why it failed" case.
    ---@param fn function|nil
    ---@return any
    function M.try(fn, a, b, c)
        if type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, a, b, c)
        if not ok then return nil end
        return value
    end

    --- Same, but for a boolean answer, so a caller never has to write
    --- `x and true or false` around a pcall that may return nil.
    ---@return boolean
    function M.try_bool(fn, a, b, c)
        return M.try(fn, a, b, c) and true or false
    end

    --- Wraps a one-argument native in a cache of its own.
    ---
    --- The returned function has the same shape as what it wraps, so a service
    --- can swap a direct native call for a memoised one without any caller
    --- noticing.
    ---@param name string
    ---@param fn function|nil
    ---@param opts? table Passed to M.new.
    ---@return fun(arg: any): any
    function M.memo1(name, fn, opts)
        local cache = M.new(name, opts)
        if type(fn) ~= "function" then
            return function() return nil end
        end
        return function(arg)
            return cache:fetch(arg == nil and true or arg, fn, arg)
        end
    end

    --- Wraps a zero-argument native.
    ---@param name string
    ---@param fn function|nil
    ---@param opts? table
    ---@return fun(): any
    function M.memo0(name, fn, opts)
        local cache = M.new(name, opts)
        if type(fn) ~= "function" then
            return function() return nil end
        end
        return function()
            return cache:fetch(true, fn)
        end
    end

    -- --- namespace wrapping -------------------------------------------------

    -- Which call names are safe to memoise. A reader may be called ten times a
    -- frame and must be cheap; anything else is assumed to have a side effect
    -- and is passed straight through, because caching an action would silently
    -- swallow the second call.
    local READER_PREFIX = {
        "get_", "is_", "has_", "can_", "num_", "query_", "calculate_", "does_",
    }

    local function looks_like_reader(name)
        for i = 1, #READER_PREFIX do
            if name:sub(1, #READER_PREFIX[i]) == READER_PREFIX[i] then return true end
        end
        return false
    end

    -- Only scalars make a safe cache key. A game_object or a vec3 would have to
    -- be stringified to key on, which allocates, and its identity says nothing
    -- about whether its CONTENTS changed -- so those calls are passed through
    -- rather than cached wrongly.
    local function scalar(v)
        local t = type(v)
        return v == nil or t == "number" or t == "string" or t == "boolean"
    end

    --- Mirrors a native namespace as a table of guarded calls.
    ---
    --- Every function is pcall-wrapped, so a build that does not expose one of
    --- them answers nil rather than taking the caller frame down with it.
    --- Reader calls with scalar arguments are memoised for the tick;
    --- everything else runs every time it is asked.
    ---
    --- This is what makes "all of it is available" true without hand-writing a
    --- wrapper per call for namespaces nobody has needed yet.
    ---@param ns_name string
    ---@param source table|nil
    ---@param opts? { scope?: string, ttl?: number, cache?: boolean, events?: string[] }
    ---@return table
    function M.wrap_namespace(ns_name, source, opts)
        opts = opts or {}
        local out = {}
        if type(source) ~= "table" then
            log.fmt("debug", "namespace %s is not present on this build", ns_name)
            return out
        end

        local memoise = opts.cache ~= false
        local cache = memoise and M.new("ns." .. ns_name, {
            scope  = opts.scope or "tick",
            ttl    = opts.ttl,
            events = opts.events,
        }) or nil

        for key, value in pairs(source) do
            if type(value) == "function" then
                local fn = value
                local cacheable = cache and looks_like_reader(key)

                if cacheable then
                    local prefix = key .. "\1"
                    out[key] = function(a, b, c)
                        if not (scalar(a) and scalar(b) and scalar(c)) then
                            local ok, result = pcall(fn, a, b, c)
                            if not ok then return nil end
                            return result
                        end
                        -- Concatenating nil is an error, so the separators
                        -- double as placeholders for absent arguments.
                        local composite = prefix .. tostring(a) .. "\2" ..
                            tostring(b) .. "\2" .. tostring(c)
                        return cache:fetch(composite, fn, a, b, c)
                    end
                else
                    out[key] = function(a, b, c, d, e)
                        local ok, result = pcall(fn, a, b, c, d, e)
                        if not ok then return nil end
                        return result
                    end
                end
            else
                out[key] = value
            end
        end

        return out
    end

    -- --- diagnostics --------------------------------------------------------

    --- Every cache, busiest first. The right thing to read when a frame-time
    --- problem is suspected to be a cache that is never hitting.
    function M.report()
        local rows = {}
        for _, cache in pairs(registry) do
            rows[#rows + 1] = cache:stats()
        end
        util.stable_sort_by(rows, function(row) return -(row.hits + row.misses) end)
        return rows
    end

    function M.totals()
        local hits, misses, errors = 0, 0, 0
        for _, cache in pairs(registry) do
            hits = hits + cache.hits
            misses = misses + cache.misses
            errors = errors + cache.errors
        end
        local total = hits + misses
        return {
            caches  = util.count(registry),
            hits    = hits,
            misses  = misses,
            errors  = errors,
            hit_pct = total > 0 and (hits / total * 100.0) or 0,
        }
    end

    --- Drops every cached value everywhere. Wired to zone changes, where most
    --- of what we hold is about to be wrong anyway.
    function M.clear_all()
        for _, cache in pairs(registry) do cache:clear() end
    end

    return M
end

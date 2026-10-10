-- JCore / storage -- files under scripts_data, and keyed stores on top of them.
--
-- Depends on: util, log, cache, scheduler, json.
--
-- Two layers, and the second one is the reason this exists.
--
-- The lower layer is thin: read and write a file, with the contents cached so
-- that a plugin reading its config every tick does not hit the disk every
-- tick. Disk reads are not as costly as a native game call but they are not
-- free either, and a read in a render job is felt.
--
-- The upper layer is a STORE: a named table that is loaded once, read as a
-- plain table, and written back automatically a short time after it changes.
-- That debounce is the point. The obvious implementation writes on every set,
-- which for a plugin recording a counter means a file write per kill; the
-- obvious fix is to write on unload, which loses everything if the client
-- exits badly. Writing a moment after the last change gets both.
--
-- Nothing here touches the menu's own persistence. Menu widget values are
-- saved by the menu host against their widget ids; this is for the state a
-- plugin keeps that is not a setting -- routes, counters, caches, histories.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local scheduler = rt.scheduler
    local json = rt.json
    local log = rt.log.for_tag("JCore/storage")

    local try = cache.try

    local M = {}

    -- How long after the last change a dirty store is written. Long enough to
    -- collapse a burst of sets into one write, short enough that a crash loses
    -- almost nothing.
    local FLUSH_DELAY = 2.0

    local contents = cache.new("storage.files", { scope = "manual" })
    local stores = {}
    local flush_scheduled = false

    local stats = { reads = 0, writes = 0, cache_hits = 0, errors = 0 }

    -- --- files --------------------------------------------------------------

    --- Reads a file under scripts_data. Cached until something writes it.
    ---@param filename string
    ---@return string|nil
    function M.read(filename)
        local value, hit = contents:get(filename)
        if hit then
            stats.cache_hits = stats.cache_hits + 1
            return value
        end

        stats.reads = stats.reads + 1
        return contents:put(filename, try(core.read_data_file, filename))
    end

    --- Writes a file under scripts_data, creating it if needed.
    ---@param filename string
    ---@param data string
    ---@return boolean
    function M.write(filename, data)
        if type(data) ~= "string" then
            log.fmt("error", "write(%s) needs a string, got %s", filename, type(data))
            return false
        end

        -- create_data_file on an existing file is harmless, and skipping it
        -- when the file does not exist yet makes the write fail silently.
        try(core.create_data_file, filename)

        local ok = pcall(core.write_data_file, filename, data)
        if not ok then
            stats.errors = stats.errors + 1
            log.fmt("error", "could not write %s", filename)
            return false
        end

        stats.writes = stats.writes + 1
        -- Update rather than invalidate: we know exactly what is in the file
        -- now, so a read straight after a write should not go to disk.
        contents:put(filename, data)
        return true
    end

    ---@param folder string
    function M.create_folder(folder)
        return try(core.create_data_folder, folder)
    end

    ---@param filename string
    ---@return boolean
    function M.exists(filename)
        local size = try(core.get_data_file_size, filename)
        return size ~= nil and size > 0
    end

    ---@param filename string
    function M.delete(filename)
        contents:invalidate(filename)
        return try(core.delete_data_file, filename)
    end

    ---@param directory string
    ---@return string[]
    function M.list(directory)
        return try(core.read_dir, directory) or {}
    end

    -- --- json files ---------------------------------------------------------

    --- Reads and parses a JSON file.
    ---@param filename string
    ---@return any|nil value
    ---@return string|nil error
    function M.read_json(filename)
        local text = M.read(filename)
        if not text or text == "" then return nil, "not found or empty" end
        return json.decode(text)
    end

    ---@param filename string
    ---@param value any
    ---@param pretty? boolean
    ---@return boolean
    function M.write_json(filename, value, pretty)
        local text, err = json.encode(value, { pretty = pretty ~= false })
        if not text then
            log.fmt("error", "could not encode %s: %s", filename, tostring(err))
            return false
        end
        return M.write(filename, text)
    end

    -- --- stores -------------------------------------------------------------

    local Store = {}
    Store.__index = Store

    ---@param key string
    ---@param fallback? any Returned when the key is absent, NOT stored.
    ---@return any
    function Store:get(key, fallback)
        local value = self.data[key]
        if value == nil then return fallback end
        return value
    end

    ---@param key string
    ---@param value any
    function Store:set(key, value)
        if self.data[key] == value then return self end
        self.data[key] = value
        self:touch()
        return self
    end

    --- Merges a table of values in one go, marking dirty once.
    ---@param values table
    function Store:update(values)
        for k, v in pairs(values) do self.data[k] = v end
        self:touch()
        return self
    end

    ---@param key string
    function Store:delete(key)
        if self.data[key] == nil then return self end
        self.data[key] = nil
        self:touch()
        return self
    end

    --- Adds `by` to a numeric key, starting from zero. The shape a counter
    --- wants, without every caller writing the nil check.
    ---@param key string
    ---@param by? number
    ---@return number
    function Store:increment(key, by)
        local value = (tonumber(self.data[key]) or 0) + (by or 1)
        self.data[key] = value
        self:touch()
        return value
    end

    --- The whole table, by reference.
    ---
    --- Writing through it does NOT mark the store dirty, so call touch()
    --- afterwards. The alternative -- handing back a copy -- would make a
    --- store holding a large route table expensive to read.
    ---@return table
    function Store:all()
        return self.data
    end

    --- Marks the store as needing a write. Called for you by every mutator.
    function Store:touch()
        self.dirty = true
        self.changed_at = core.time()
        M._schedule_flush()
        return self
    end

    --- Writes now, whatever the debounce says.
    ---@return boolean
    function Store:save()
        if not self.dirty then return true end
        local ok = M.write_json(self.filename, self.data, true)
        if ok then self.dirty = false end
        return ok
    end

    function Store:clear()
        self.data = {}
        self:touch()
        return self
    end

    --- Opens a named store, loading it from disk on first use.
    ---
    --- The same name always returns the SAME store object. Two plugins sharing
    --- a name share the table, which is occasionally what is wanted and
    --- otherwise is why names should be namespaced by plugin id.
    ---@param name string
    ---@return table store
    function M.store(name)
        local slug = util.slug(name)
        local existing = stores[slug]
        if existing then return existing end

        local filename = "jcore/" .. slug .. ".json"
        local data = {}

        local loaded, err = M.read_json(filename)
        if type(loaded) == "table" then
            data = loaded
        elseif err and err ~= "not found or empty" then
            -- A corrupt file is kept, not overwritten. Renaming it would need
            -- a move call this API does not have, and silently replacing it
            -- destroys whatever a user might still want back.
            log.fmt("warn", "store %s could not be parsed (%s); starting empty", slug, err)
        end

        local store = setmetatable({
            name       = slug,
            filename   = filename,
            data       = data,
            dirty      = false,
            changed_at = 0,
        }, Store)

        stores[slug] = store
        return store
    end

    -- --- flushing -----------------------------------------------------------

    --- Arms the single shared flush timer.
    ---
    --- One timer for every store, not one each: a hundred stores each with
    --- their own repeating timer is a hundred scheduler entries doing nothing
    --- almost all of the time.
    function M._schedule_flush()
        if flush_scheduled then return end
        flush_scheduled = true
        scheduler.after(FLUSH_DELAY, function()
            flush_scheduled = false
            M.flush()
        end, "jcore.storage")
    end

    --- Writes every store that has settled. A store still being written to is
    --- left for the next pass, so a burst of changes produces one write at the
    --- end rather than one per burst.
    ---@param force? boolean Write everything dirty, settled or not.
    ---@return integer written
    function M.flush(force)
        local now = core.time()
        local written = 0

        for _, store in pairs(stores) do
            if store.dirty then
                if force or (now - store.changed_at) >= FLUSH_DELAY * 0.5 then
                    if store:save() then written = written + 1 end
                else
                    -- Still moving. Come back for it.
                    M._schedule_flush()
                end
            end
        end

        if written > 0 then
            log.fmt("debug", "flushed %d store(s)", written)
        end
        return written
    end

    --- Every open store, for diagnostics and for the shutdown flush.
    ---@return table<string, table>
    function M.stores()
        return stores
    end

    -- --- logs ---------------------------------------------------------------
    --
    -- Separate tree from data files, and deliberately uncached: a log is
    -- written far more than it is read, and holding its contents in memory
    -- defeats the point of writing it out.

    ---@param filename string
    ---@param message string
    function M.append_log(filename, message)
        try(core.create_log_file, filename)
        return try(core.write_log_file, filename, message)
    end

    ---@param folder string
    function M.create_log_folder(folder)
        return try(core.create_log_folder, folder)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local dirty = 0
        for _, store in pairs(stores) do
            if store.dirty then dirty = dirty + 1 end
        end
        return {
            stores  = util.count(stores),
            dirty   = dirty,
            reads   = stats.reads,
            writes  = stats.writes,
            hits    = stats.cache_hits,
            errors  = stats.errors,
        }
    end

    return M
end

-- JCore / log -- namespaced logging with rate limiting and an optional file sink.
--
-- Depends on: util.
--
-- Why this exists rather than plain core.log: with a dozen plugins on one core
-- tick, an unguarded core.log_error in a hot path floods the console until the
-- game stutters. Every line here is tagged with its owning plugin and every
-- call site gets its own token bucket, so a spamming plugin degrades to one
-- line plus a suppression count instead of taking the frame down with it.

return function(rt)
    local util = rt.util
    local M = {}

    local LEVELS = { trace = 10, debug = 20, info = 30, warn = 40, error = 50 }
    M.LEVELS = LEVELS

    -- Console verbosity floor. Anything below is dropped before formatting.
    local threshold = LEVELS.info
    local to_file = false
    local file_name = nil

    -- key -> { window_start, count, suppressed }
    local buckets = {}
    local BUCKET_WINDOW = 1.0 -- seconds
    local BUCKET_LIMIT = 4    -- lines per key per window

    function M.set_level(level)
        threshold = LEVELS[level] or LEVELS.info
    end

    function M.get_level()
        for name, v in pairs(LEVELS) do
            if v == threshold then return name end
        end
        return "info"
    end

    --- Mirrors every emitted line into scripts_log/<name>.log as well as the
    --- console. Off by default: file writes are synchronous.
    function M.set_file_sink(enabled, name)
        to_file = enabled and true or false
        file_name = name or "jcore"
        if to_file then
            pcall(core.create_log_file, file_name)
        end
    end

    --- Returns true when this call site may emit now. `key` identifies the call
    --- site, not the message, so a formatted message with a changing number
    --- still shares one bucket.
    local function allow(key)
        local now = core.time()
        local b = buckets[key]
        if not b then
            buckets[key] = { start = now, count = 1, suppressed = 0 }
            return true, 0
        end
        if now - b.start >= BUCKET_WINDOW then
            local was = b.suppressed
            b.start, b.count, b.suppressed = now, 1, 0
            return true, was
        end
        if b.count < BUCKET_LIMIT then
            b.count = b.count + 1
            return true, 0
        end
        b.suppressed = b.suppressed + 1
        return false, 0
    end

    local function emit(level_value, tag, key, message)
        if level_value < threshold then return end

        local ok, suppressed = allow(key)
        if not ok then return end

        local line = "[" .. tag .. "] " .. message
        if suppressed > 0 then
            line = line .. "  (+" .. suppressed .. " suppressed)"
        end

        if level_value >= LEVELS.error then
            core.log_error(line)
        elseif level_value >= LEVELS.warn then
            core.log_warning(line)
        else
            core.log(line)
        end

        if to_file then
            pcall(core.write_log_file, file_name, line)
        end
    end

    --- A logger bound to one namespace. `rate_key` defaults to the message
    --- itself, which is right for constant strings and wrong for formatted
    --- ones; pass an explicit key for those.
    ---@param tag string
    function M.for_tag(tag)
        local logger = {}

        local function make(level_name)
            local level_value = LEVELS[level_name]
            return function(message, rate_key)
                message = tostring(message)
                emit(level_value, tag, tag .. "|" .. (rate_key or message), message)
            end
        end

        logger.trace = make("trace")
        logger.debug = make("debug")
        logger.info  = make("info")
        logger.warn  = make("warn")
        logger.error = make("error")

        --- string.format wrapper. The format string doubles as the rate key, so
        --- a line whose numbers change every frame still collapses correctly.
        function logger.fmt(level_name, format, ...)
            local level_value = LEVELS[level_name] or LEVELS.info
            if level_value < threshold then return end
            local ok, message = pcall(string.format, format, ...)
            if not ok then message = format .. " <bad format args>" end
            emit(level_value, tag, tag .. "|" .. format, message)
        end

        --- Emits without consulting the rate limiter.
        ---
        --- The limiter keys on the call site, which is right for a line in a
        --- hot path and exactly wrong for a bulk dump: a diagnostic that
        --- prints one line per nearby object is ONE call site deliberately
        --- emitting many distinct lines, and the limiter would swallow it
        --- after the fourth -- silently, and only in the case where someone is
        --- already trying to debug something.
        ---
        --- Only for output a human explicitly asked for. Never in a tick.
        ---@param level_name string
        ---@param message string
        function logger.raw(level_name, message)
            local level_value = LEVELS[level_name] or LEVELS.info
            if level_value < threshold then return end

            local line = "[" .. tag .. "] " .. tostring(message)
            if level_value >= LEVELS.error then
                core.log_error(line)
            elseif level_value >= LEVELS.warn then
                core.log_warning(line)
            else
                core.log(line)
            end
            if to_file then
                pcall(core.write_log_file, file_name, line)
            end
        end

        --- string.format wrapper for logger.raw.
        function logger.rawf(level_name, format, ...)
            local ok, message = pcall(string.format, format, ...)
            logger.raw(level_name, ok and message or (format .. " <bad format args>"))
        end

        --- Emits once per session for this key, whatever the call frequency.
        local seen = {}
        function logger.once(level_name, key, message)
            if seen[key] then return end
            seen[key] = true
            emit(LEVELS[level_name] or LEVELS.info, tag, tag .. "|once|" .. key, tostring(message))
        end

        return logger
    end

    M.core = M.for_tag("JCore")

    return M
end

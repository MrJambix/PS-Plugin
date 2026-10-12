-- JCore / faults -- every error the core catches, handed with its traceback
-- to whoever listens, and marks of what is running for a crash's black box.
--
-- Depends on: nothing. Built straight after log and before events and the
-- scheduler, which call it on every job and handler.
--
-- WHY (1.8.1). The user, 2026-10-11, after an evening of crashes that left
-- no report: "add to the Debug All Captures of anything we running thats
-- going Null, or Crashing us for any Error whatso ever and log it on the hit
-- so we can fix it/report it". The core ran every job, timer, event handler
-- and stage in a pcall and wrote one rate-limited console line, without a
-- traceback, and nothing to a file. Now, while a listener is set (Jambix
-- Debug's services/faults), they run under xpcall instead: the traceback and
-- the locals of the frame that raised are kept and handed over with who it
-- was. The log's warn and error lines, what cache.try swallowed, and (from
-- the recorder's watch) a native that raised or went nil are handed over too.
--
-- NO LISTENER, NO CHANGE. Without Jambix Debug every call here is a plain
-- pcall or a nil check, so users' JCore runs exactly as before.
--
-- THE MARKS. The native callbacks in main.lua mark the pass they run
-- (update, render, window...) and, while `M.deep` is set, the scheduler,
-- the event bus and the core stages mark every job and handler. The listener
-- writes them ahead of the work, so when the game dies outright the last
-- mark on disk says what was running.

return function(rt)
    local M = {}

    --- Set by the listener: mark every job, handler and stage, not only the
    --- passes. Read on every job, so it is a plain field.
    M.deep = false

    local listener = nil
    local delivering = false
    local last_error = nil

    local dbg = type(debug) == "table" and debug or nil
    local traceback = dbg and type(dbg.traceback) == "function" and dbg.traceback or nil
    local getinfo = dbg and type(dbg.getinfo) == "function" and dbg.getinfo or nil
    local getlocal = dbg and type(dbg.getlocal) == "function" and dbg.getlocal or nil

    --- One local's value, short. Never tostring on a userdata or a table: a
    --- game object's __tostring is native, and a fault is no time to call one.
    local function show(v)
        local t = type(v)
        if t == "string" then
            if #v > 60 then v = v:sub(1, 60) .. "..." end
            return "\"" .. (v:gsub("[^\32-\126]", "?")) .. "\""
        end
        if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
        if t == "table" then
            local n = 0
            for _ in next, v do
                n = n + 1
                if n >= 100 then break end
            end
            return n >= 100 and "table(100+)" or ("table(" .. n .. ")")
        end
        return t
    end

    local caught = { trace = nil, locals = nil, at = nil }
    local handler

    --- The locals of the Lua frame that raised: the first frame below the
    --- handler that is not native (error() itself is; "[JS]" offline).
    local function frame_locals()
        for level = 2, 20 do
            local info = getinfo(level, "Slf")
            if not info then return nil end
            local src = info.short_src
            if info.what ~= "C" and src ~= "[C]" and src ~= "[JS]"
                and info.func ~= handler and info.func ~= frame_locals then
                local out = {}
                for i = 1, 40 do
                    local name, value = getlocal(level, i)
                    if not name then break end
                    if name:sub(1, 1) ~= "(" then
                        out[#out + 1] = name .. "=" .. show(value)
                        if #out >= 16 then break end
                    end
                end
                return table.concat(out, ", "),
                    tostring(info.short_src or info.source or "?") .. ":" .. tostring(info.currentline or "?")
            end
        end
        return nil
    end

    handler = function(err)
        caught.trace, caught.locals, caught.at = nil, nil, nil
        if traceback then
            -- No message: the listener has it; just the stack.
            local ok, tb = pcall(traceback, "", 2)
            if ok and type(tb) == "string" then caught.trace = (tb:gsub("^%s+", "")) end
        end
        if getinfo and getlocal then
            local ok, locals, at = pcall(frame_locals)
            if ok then caught.locals, caught.at = locals, at end
        end
        return err
    end

    local function deliver(name, ...)
        local l = listener
        if not l or delivering then return end
        local fn = l[name]
        if type(fn) ~= "function" then return end
        delivering = true
        pcall(fn, ...)
        delivering = false
    end

    --- Starts handing faults and marks to `l`, a table of optional functions:
    --- fault(kind, who, err, trace, locals, at), native(key, err, site),
    --- null(key, site, count), enter(label), leave(label). One listener.
    function M.listen(l)
        listener = type(l) == "table" and l or nil
        if not listener then M.deep = false end
        return listener ~= nil
    end

    --- Stops, if `l` is the listener.
    function M.unlisten(l)
        if listener == l then
            listener = nil
            M.deep = false
        end
    end

    function M.listening() return listener ~= nil end

    --- pcall(fn, ...), or under xpcall with the traceback kept while somebody
    --- listens. Returns ok, err as pcall's first two answers (the callers use
    --- no more). `kind` and `who` say what ran: "job" and the job's table,
    --- "event" and the subscription, "timer", "stage" and its name.
    function M.call(kind, who, fn, ...)
        if not listener then return pcall(fn, ...) end
        local ok, err = xpcall(fn, handler, ...)
        if ok then return true end
        last_error = type(err) == "string" and err or tostring(err)
        deliver("fault", kind, who, err, caught.trace, caught.locals, caught.at)
        return false, err
    end

    --- An error caught somewhere else: a log line at warn or error ("log"), or
    --- one cache.try swallowed ("swallowed"). Skipped when it repeats the
    --- error just handed over (a job's failure is logged after it is caught).
    function M.report(kind, who, message, level)
        if not listener or delivering then return end
        local text = type(message) == "string" and message or tostring(message)
        if last_error and (text == last_error or text:find(last_error, 1, true)) then return end
        if kind ~= "log" then last_error = text end
        deliver("fault", kind, who, text, nil, nil, nil, level)
    end

    --- What cache.try swallowed.
    function M.swallowed(who, err)
        if not listener then return end
        M.report("swallowed", who, err)
    end

    --- A native that raised (the recorder's watch), with the call site.
    function M.native(key, err, site)
        if not listener then return end
        last_error = type(err) == "string" and err or tostring(err)
        deliver("native", key, err, site)
    end

    --- A native that answered nil after answering values before.
    function M.null(key, site, count)
        if not listener then return end
        deliver("null", key, site, count)
    end

    --- A pass, a job or a handler begins / ends. Never raises.
    function M.enter(label)
        local l = listener
        if l and l.enter and not delivering then pcall(l.enter, label) end
    end

    function M.leave(label)
        local l = listener
        if l and l.leave and not delivering then pcall(l.leave, label) end
    end

    return M
end

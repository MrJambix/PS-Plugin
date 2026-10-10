-- JCore / net -- HTTP, with caching, deduplication and a concurrency cap.
--
-- Depends on: util, log, cache, scheduler, json.
--
-- The native calls are already asynchronous, so what a core adds is not
-- threading, it is discipline. Three things go wrong when plugins call
-- core.http_get directly:
--
--   1. The same URL is fetched by three plugins in the same second, and by
--      each of them again next minute. Identical requests are collapsed into
--      one in-flight call, and answers are held for a caller-chosen lifetime.
--   2. A loop that fires a request per frame opens hundreds of connections and
--      stalls the client. A concurrency cap plus a queue makes that impossible
--      by construction.
--   3. A plugin's callback runs inside the native completion hook, at an
--      unspecified point in the frame, where a raise goes somewhere nobody is
--      watching. Callbacks here are delivered on the next update instead, in
--      the same phase as everything else, and are pcall'ed.
--
-- Rate limiting is per host rather than global, because being polite to one
-- API should not slow down requests to a different one.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local scheduler = rt.scheduler
    local json = rt.json
    local log = rt.log.for_tag("JCore/net")

    local M = {}

    -- Four at a time is enough to keep a dashboard responsive without the
    -- client noticing. Requests past it queue rather than fail, because a
    -- dropped request is a silent hole in whatever the caller was building.
    local MAX_CONCURRENT = 4
    local DEFAULT_TTL = 60.0
    local QUEUE_CAP = 256

    -- Manual scope, not "ttl", because the lifetime is chosen per REQUEST: a
    -- price feed wants thirty seconds and a static data file wants an hour. A
    -- cache-wide timeout could only serve one of them, so each entry carries
    -- its own expiry and the read path checks it.
    local responses = cache.new("net.responses", { scope = "manual" })

    local in_flight = {}    -- key -> { waiters = { callback, ... } }
    local active = 0
    local queue = {}
    local host_next_allowed = {}

    local stats = { sent = 0, served_from_cache = 0, deduped = 0, failed = 0, queued = 0 }

    -- --- keys ---------------------------------------------------------------

    local function request_key(method, url, body)
        return method .. "\1" .. url .. "\1" .. (body or "")
    end

    local function host_of(url)
        return url:match("^%a+://([^/]+)") or url
    end

    -- --- delivery -----------------------------------------------------------

    --- Hands a result to every waiter, on the next update rather than inside
    --- the native callback.
    local function deliver(key, result)
        local entry = in_flight[key]
        in_flight[key] = nil
        if not entry then return end

        scheduler.after(0, function()
            for i = 1, #entry.waiters do
                local ok, err = pcall(entry.waiters[i], result)
                if not ok then
                    log.fmt("error", "http callback failed for %s: %s", entry.url, tostring(err))
                end
            end
        end, "jcore.net")
    end

    -- --- the pump -----------------------------------------------------------

    local function send(job)
        active = active + 1
        stats.sent = stats.sent + 1

        local host = host_of(job.url)
        host_next_allowed[host] = core.time() + (job.min_interval or 0)

        local function on_complete(http_code, content_type, response_data, response_headers)
            active = active - 1

            local result = {
                ok      = (http_code or 0) >= 200 and (http_code or 0) < 300,
                status  = http_code or 0,
                body    = response_data or "",
                type    = content_type,
                headers = response_headers,
                url     = job.url,
            }

            if not result.ok then
                stats.failed = stats.failed + 1
                log.fmt("debug", "%s %s -> %s", job.method, job.url, tostring(http_code))
            elseif job.ttl and job.ttl > 0 then
                -- Only successes are cached. Caching a 500 for a minute turns
                -- a momentary server hiccup into a minute of nothing working.
                responses:put(job.key, { result = result, expires = core.time() + job.ttl })
            end

            deliver(job.key, result)
            M._pump()
        end

        local ok
        if job.method == "POST" then
            if job.headers then
                ok = pcall(core.http_post, job.url, job.headers, job.body or "", on_complete)
            else
                ok = pcall(core.http_post, job.url, job.body or "", on_complete)
            end
        else
            if job.headers then
                ok = pcall(core.http_get, job.url, job.headers, on_complete)
            else
                ok = pcall(core.http_get, job.url, on_complete)
            end
        end

        if not ok then
            -- The call never reached the transport, so on_complete will never
            -- run and the waiters would hang for ever. Answer them here.
            active = active - 1
            stats.failed = stats.failed + 1
            log.fmt("error", "http transport refused %s %s", job.method, job.url)
            deliver(job.key, { ok = false, status = 0, body = "", url = job.url,
                error = "transport unavailable" })
        end
    end

    --- Starts whatever the cap and the per-host pacing allow. Called after
    --- every completion and once per second by the runtime, so a request held
    --- back by pacing is not stuck until the next completion happens to land.
    function M._pump()
        if #queue == 0 then return end
        local now = core.time()
        local i = 1

        while i <= #queue and active < MAX_CONCURRENT do
            local job = queue[i]
            local allowed = host_next_allowed[host_of(job.url)]
            if not allowed or now >= allowed then
                table.remove(queue, i)
                send(job)
            else
                i = i + 1
            end
        end
    end

    -- --- the public call ----------------------------------------------------

    ---@class jcore_http_result
    ---@field ok boolean         2xx status.
    ---@field status integer     HTTP status, 0 on a transport failure.
    ---@field body string        Raw body, binary safe.
    ---@field type string|nil    Content type.
    ---@field headers string|nil Raw response header dump.
    ---@field url string

    --- Issues a request, or joins one already in flight, or answers from cache.
    ---@param method string "GET" or "POST"
    ---@param url string
    ---@param opts? { body?: string, headers?: table<string,string>, ttl?: number, min_interval?: number, fresh?: boolean }
    ---@param callback fun(result: jcore_http_result)
    local function request(method, url, opts, callback)
        opts = opts or {}
        if type(url) ~= "string" or url == "" then
            log.warn("http request with no url")
            return false
        end
        callback = callback or function() end

        local key = request_key(method, url, opts.body)
        local ttl = opts.ttl or DEFAULT_TTL

        -- Cache first. `fresh` is the escape hatch for a caller that knows the
        -- resource just changed.
        if not opts.fresh and ttl > 0 then
            local entry_cached, hit = responses:get(key)
            if hit and entry_cached then
                if core.time() < entry_cached.expires then
                    stats.served_from_cache = stats.served_from_cache + 1
                    local result = entry_cached.result
                    scheduler.after(0, function() callback(result) end, "jcore.net")
                    return true
                end
                responses:invalidate(key)
            end
        end

        -- Join an identical request that has not come back yet, rather than
        -- opening a second connection for the same bytes.
        local entry = in_flight[key]
        if entry then
            stats.deduped = stats.deduped + 1
            entry.waiters[#entry.waiters + 1] = callback
            return true
        end

        if #queue >= QUEUE_CAP then
            log.once("error", "queue_full",
                "http queue is full; requests are being dropped. A plugin is almost certainly requesting per frame.")
            return false
        end

        in_flight[key] = { url = url, waiters = { callback } }
        queue[#queue + 1] = {
            key = key, method = method, url = url,
            body = opts.body, headers = opts.headers,
            ttl = ttl, min_interval = opts.min_interval,
        }
        stats.queued = stats.queued + 1

        M._pump()
        return true
    end

    ---@param url string
    ---@param opts? table
    ---@param callback fun(result: jcore_http_result)
    function M.get(url, opts, callback)
        -- Two-argument form: get(url, callback).
        if type(opts) == "function" then opts, callback = nil, opts end
        return request("GET", url, opts, callback)
    end

    ---@param url string
    ---@param body string
    ---@param opts? table
    ---@param callback fun(result: jcore_http_result)
    function M.post(url, body, opts, callback)
        if type(opts) == "function" then opts, callback = nil, opts end
        opts = opts and util.shallow_copy(opts) or {}
        opts.body = body
        -- A POST is a write far more often than a read, so it does not get a
        -- cache unless the caller explicitly asks for one.
        opts.ttl = opts.ttl or 0
        return request("POST", url, opts, callback)
    end

    --- GET, decoded as JSON.
    ---
    --- The callback receives `nil` and a message when the request failed OR
    --- the body was not JSON, so a caller has one thing to check rather than
    --- two.
    ---@param url string
    ---@param opts? table
    ---@param callback fun(data: any|nil, err: string|nil, result: jcore_http_result)
    function M.get_json(url, opts, callback)
        if type(opts) == "function" then opts, callback = nil, opts end
        return M.get(url, opts, function(result)
            if not result.ok then
                callback(nil, "http " .. tostring(result.status), result)
                return
            end
            local data, err = json.decode(result.body)
            if not data then
                callback(nil, err or "malformed json", result)
                return
            end
            callback(data, nil, result)
        end)
    end

    --- POST a table as a JSON body, with the content type set.
    ---@param url string
    ---@param payload any
    ---@param opts? table
    ---@param callback fun(data: any|nil, err: string|nil, result: jcore_http_result)
    function M.post_json(url, payload, opts, callback)
        if type(opts) == "function" then opts, callback = nil, opts end
        opts = opts and util.shallow_copy(opts) or {}

        local body, err = json.encode(payload)
        if not body then
            log.fmt("error", "could not encode json body: %s", tostring(err))
            return false
        end

        opts.headers = opts.headers or {}
        opts.headers["Content-Type"] = opts.headers["Content-Type"] or "application/json"

        return M.post(url, body, opts, function(result)
            if not result.ok then
                callback(nil, "http " .. tostring(result.status), result)
                return
            end
            local data, decode_err = json.decode(result.body)
            callback(data, data and nil or (decode_err or "malformed json"), result)
        end)
    end

    -- --- control ------------------------------------------------------------

    --- Drops every cached response. Use after something is known to have
    --- changed server-side.
    function M.clear_cache()
        responses:clear()
    end

    --- Drops expired entries and restarts anything the per-host pacing held
    --- back. Run on a timer by the runtime: without the sweep the response
    --- table only ever grows, since an entry nobody asks for again is never
    --- read and so never noticed to be stale.
    function M._prune()
        local now = core.time()
        for key, entry in pairs(responses.values) do
            if type(entry) == "table" and entry.expires and now >= entry.expires then
                responses:invalidate(key)
            end
        end
        M._pump()
    end

    ---@param n integer
    function M.set_max_concurrent(n)
        MAX_CONCURRENT = util.clamp(math.floor(n or 4), 1, 16)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            sent      = stats.sent,
            cached    = stats.served_from_cache,
            deduped   = stats.deduped,
            failed    = stats.failed,
            active    = active,
            queued    = #queue,
            in_flight = util.count(in_flight),
        }
    end

    return M
end

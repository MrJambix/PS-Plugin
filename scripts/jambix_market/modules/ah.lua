-- Jambix Market / ah -- the auction house, asked one question at a time.
--
-- core.auction_house works on Forever since the 2026-10-06 core, on the
-- retail implementation (C_AuctionHouse). This module is the only caller of
-- it, and adds three things the native calls do not have:
--
--   * Every call is guarded. The first answer of each call is traced (at
--     debug) and the first failure is logged, so a session on a new build
--     says exactly which calls answered.
--   * Calls go straight to core.auction_house, not through ctx.bridge: the
--     bridge memoises readers for two seconds, which is right for a window
--     somebody reads and wrong for a scan waiting on a count to move.
--   * Searches are SINGLE-FLIGHT. The client keeps one result set per item
--     and the server throttles queries, so a second search sent before the
--     first is read can hand back the wrong item's rows. Requests queue, go
--     out when the throttle says ready, and are read once their results
--     have settled.
--
-- Nothing here buys, posts or cancels; that is modules/trader.lua, which
-- takes the lock below while it does, so no search is sent mid-purchase.

return function(M)
    local ctx, U = M.ctx, M.util

    local A = {}

    local MIN_GAP = 0.35          -- seconds between two queries we send
    local SEARCH_TIMEOUT = 6.0    -- a search with no answer by then has none
    local SETTLE = 0.25           -- after a results event, before reading
    local OWNED_TIMEOUT = 3.0
    local LOCK_LIMIT = 20.0       -- a lock nobody released lapses after this

    local stats = { calls = 0, errors = 0, searches = 0, timeouts = 0 }
    local first = {}              -- call name -> first outcome, for the diagnostics
    local missing = {}

    -- --- guarded calls ---------------------------------------------------------

    local function describe(v)
        local k = type(v)
        if k == "table" then
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            return "table(" .. n .. " fields)"
        end
        return k .. " " .. tostring(v)
    end

    --- core.auction_house[name](...), guarded. Nil when it is missing or raised.
    function A.call(name, ...)
        local ns = core.auction_house
        local fn = type(ns) == "table" and ns[name] or nil
        if type(fn) ~= "function" then
            if not missing[name] then
                missing[name] = true
                M.log.fmt("warn", "core.auction_house.%s is missing on this core", name)
            end
            return nil
        end
        stats.calls = stats.calls + 1
        local ok, a, b = pcall(fn, ...)
        if not ok then
            stats.errors = stats.errors + 1
            if first[name] ~= "raised" then
                first[name] = "raised"
                M.log.fmt("warn", "core.auction_house.%s raised: %s", name, tostring(a))
            end
            return nil
        end
        if not first[name] then
            first[name] = describe(a)
            M.debug("ah: first %s -> %s", name, first[name])
        end
        return a, b
    end

    -- --- open / closed ------------------------------------------------------------

    local open = false
    local shown_at, closed_at = nil, nil
    local poll_false = 0

    local function set_open(value)
        if value == open then return end
        open = value
        if value then
            shown_at = core.time()
            poll_false = 0
            M.activity("Auction house opened")
            ctx.emit("jambix.market.ah_open")
        else
            closed_at = core.time()
            M.activity("Auction house closed")
            ctx.emit("jambix.market.ah_closed")
        end
    end

    ctx.on("jcore.game_event.AUCTION_HOUSE_SHOW", function() set_open(true) end)
    ctx.on("jcore.game_event.AUCTION_HOUSE_CLOSED", function() set_open(false) end)
    ctx.on("jcore.game_event.AUCTION_HOUSE_DISABLED", function() set_open(false) end)

    -- The reader as a second witness: a reload with the window already open
    -- sends no SHOW, and a CLOSED can be missed. Two "no"s in a row close it,
    -- never in the second after a SHOW.
    ctx.tick(function()
        local shown = A.call("is_auction_house_shown")
        if shown == true then
            poll_false = 0
            set_open(true)
        elseif shown == false and open then
            poll_false = poll_false + 1
            if poll_false >= 2 and core.time() - (shown_at or 0) > 1.5 then set_open(false) end
        end
    end, { interval = 0.5 })

    function A.is_open() return open end
    function A.open_since() return open and shown_at or nil end

    --- The server's throttle. A build without the reader is treated as ready;
    --- MIN_GAP still spaces our queries.
    function A.ready()
        local r = A.call("is_throttled_message_system_ready")
        return r ~= false
    end

    -- --- the lock -------------------------------------------------------------------

    local lock = nil              -- { tag, at }

    function A.lock(tag)
        if lock and lock.tag ~= tag and core.time() - lock.at < LOCK_LIMIT then return false end
        lock = { tag = tag, at = core.time() }
        return true
    end

    function A.unlock(tag)
        if lock and (tag == nil or lock.tag == tag) then lock = nil end
    end

    function A.locked()
        if lock and core.time() - lock.at >= LOCK_LIMIT then
            M.log.fmt("warn", "the %s lock was never released; letting go of it", tostring(lock.tag))
            lock = nil
        end
        return lock ~= nil
    end

    -- --- the queue ------------------------------------------------------------------

    local queue = {}              -- requests not sent yet
    local active = nil            -- the request in flight
    local last_sent = -math.huge
    local results = {}            -- item id -> the last search's result

    --- What the last search for an item found, and how old it is.
    ---@return table|nil result { item_id, kind, rows, at, t }
    ---@return number age seconds
    function A.last(item_id)
        local r = results[item_id]
        if not r then return nil, math.huge end
        return r, core.time() - r.t
    end

    local function deliver(req, result, why)
        local cbs = req.callbacks
        for i = 1, #cbs do
            local ok, err = pcall(cbs[i], result, why)
            if not ok then M.log.fmt("error", "search callback raised: %s", tostring(err)) end
        end
    end

    --- Queues a search for one item. Asking for an item already queued adds
    --- the callback to that request instead of sending the query twice.
    ---@param item_id integer
    ---@param opts? { level?: integer, front?: boolean, reason?: string }
    ---@param cb? fun(result: table|nil, why: string|nil)
    function A.search(item_id, opts, cb)
        item_id = tonumber(item_id)
        if not item_id or item_id <= 0 then return false end
        opts = opts or {}
        local function attach(req)
            if cb then req.callbacks[#req.callbacks + 1] = cb end
            -- A quick scan's request that something else now waits on is
            -- that caller's too (A.pending_except counts it again).
            if req.reason == "quick" and opts.reason and opts.reason ~= "quick" then req.reason = opts.reason end
            return true
        end
        if active and active.kind == "search" and active.item_id == item_id then return attach(active) end
        for i = 1, #queue do
            local q = queue[i]
            if q.kind == "search" and q.item_id == item_id then
                if opts.front and i > 1 then
                    table.remove(queue, i)
                    table.insert(queue, 1, q)
                end
                return attach(q)
            end
        end
        -- The item key a single item (gear) is searched by needs its ITEM
        -- level. The scan's "level" is the level to use it -- 13 for an item
        -- of level 18 -- and a search by it finds nothing (the user's game,
        -- 2026-10-10: 2,765 of 2,909 single items, so no gear was ever bought).
        -- So: the item level first, then the scan's level, then 0. A
        -- commodity's search ignores the level.
        local levels, seen_level = {}, {}
        local info = M.db and M.db.info(item_id)
        for _, lv in ipairs({ info and tonumber(info.il), tonumber(opts.level), 0 }) do
            if lv and not seen_level[lv] then
                seen_level[lv] = true
                levels[#levels + 1] = lv
            end
        end
        local req = {
            kind = "search", item_id = item_id, level = levels[1], levels = levels, try = 1,
            reason = opts.reason, callbacks = {},
        }
        attach(req)
        if opts.front then table.insert(queue, 1, req) else queue[#queue + 1] = req end
        return true
    end

    --- Queues a read of the player's own auctions. opts.front: ahead of the
    --- queue (Auto's own reads are not to wait behind a quick scan).
    function A.owned(cb, opts)
        opts = opts or {}
        for i = 1, #queue do
            if queue[i].kind == "owned" then
                queue[i].callbacks[#queue[i].callbacks + 1] = cb
                if opts.front and i > 1 then table.insert(queue, 1, table.remove(queue, i)) end
                return true
            end
        end
        if active and active.kind == "owned" then
            active.callbacks[#active.callbacks + 1] = cb
            return true
        end
        local req = { kind = "owned", callbacks = { cb }, reason = "owned" }
        if opts.front then table.insert(queue, 1, req) else queue[#queue + 1] = req end
        return true
    end

    function A.pending() return #queue + (active and 1 or 0) end
    function A.busy_with() return active end

    --- Requests waiting or in flight, leaving out those made for `reason`
    --- (Auto waits for its own searches, not for a quick scan's).
    function A.pending_except(reason)
        local n = 0
        for i = 1, #queue do
            if queue[i].reason ~= reason then n = n + 1 end
        end
        if active and active.reason ~= reason then n = n + 1 end
        return n
    end

    --- Every item's last search result, by item id (read it, do not keep it).
    function A.results() return results end

    --- Drops every queued request whose reason matches (all of them when nil).
    function A.drop(reason)
        local kept = {}
        for i = 1, #queue do
            local q = queue[i]
            if reason and q.reason ~= reason then kept[#kept + 1] = q else deliver(q, nil, "dropped") end
        end
        queue = kept
    end

    -- Any results event while a search is out is taken as its answer: the
    -- item search's event carries the item key as a string ("table: ..."),
    -- which cannot be matched, and only one search is ever out.
    local function on_results()
        if active and active.kind == "search" and not active.event_at then
            active.event_at = core.time()
        end
    end
    -- The commodity events name their item: one for another item (a late
    -- answer to an earlier search) is not this search's answer.
    local function on_commodity_results(args)
        local id = args and tonumber(args[1])
        if id and active and active.kind == "search" and id ~= active.item_id then return end
        on_results()
    end
    ctx.on("jcore.game_event.COMMODITY_SEARCH_RESULTS_UPDATED", on_commodity_results)
    ctx.on("jcore.game_event.COMMODITY_SEARCH_RESULTS_RECEIVED", on_commodity_results)
    ctx.on("jcore.game_event.ITEM_SEARCH_RESULTS_UPDATED", on_results)
    ctx.on("jcore.game_event.AUCTION_HOUSE_NEW_RESULTS_RECEIVED", on_results)
    ctx.on("jcore.game_event.OWNED_AUCTIONS_UPDATED", function()
        if active and active.kind == "owned" then active.event_at = core.time() end
    end)

    local function counts(req)
        local id, lv = req.item_id, req.level or 0
        local nc = tonumber(A.call("get_num_commodity_search_results", id)) or 0
        local ni = tonumber(A.call("get_num_item_search_results", id, lv, 0)) or 0
        return nc, ni
    end

    --- The rows of a finished search, own listings marked `own`.
    local function read_search(req)
        local id, lv = req.item_id, req.level or 0
        local nc, ni = counts(req)
        local rows, kind = {}, "none"
        if nc > 0 then
            kind = "commodity"
            for i = 1, nc do
                local info = A.call("get_commodity_search_result_info", id, i)
                if type(info) == "table" then
                    local qty = tonumber(info.quantity) or 0
                    local unit = tonumber(info.unit_price) or 0
                    local own = tonumber(info.num_owner_items) or 0
                    if info.contains_owner_item and own == 0 then own = qty end
                    own = math.min(own, qty)
                    if qty - own > 0 then
                        rows[#rows + 1] = { unit = unit, qty = qty - own, auction_id = info.auction_id }
                    end
                    if own > 0 then
                        rows[#rows + 1] = { unit = unit, qty = own, auction_id = info.auction_id, own = true }
                    end
                end
            end
        elseif ni > 0 then
            kind = "item"
            for i = 1, ni do
                local info = A.call("get_item_search_result_info", id, lv, 0, i)
                if type(info) == "table" then
                    local qty = math.max(1, tonumber(info.quantity) or 1)
                    local buyout = tonumber(info.buyout_amount) or 0
                    -- Each auction's roll, from its link (nil when it has none):
                    -- gear is bought by roll (gear.lua), never blind.
                    local var, vname = U.link_variant(info.item_link)
                    rows[#rows + 1] = {
                        unit = buyout > 0 and buyout / qty or 0, qty = qty, buyout = buyout,
                        auction_id = info.auction_id, band = tonumber(info.time_left),
                        bid = tonumber(info.bid_amount), min_bid = tonumber(info.min_bid),
                        own = info.contains_owner_item == true, var = var, vname = vname,
                    }
                end
            end
        end
        table.sort(rows, function(a, b) return a.unit < b.unit end)
        return { item_id = id, kind = kind, rows = rows, at = U.now(), t = core.time(), level = lv }
    end

    local function read_owned()
        local n = tonumber(A.call("get_num_owned_auctions")) or 0
        local list = {}
        for i = 1, n do
            local info = A.call("get_owned_auction_info", i)
            if type(info) == "table" and info.auction_id then
                -- The roll of a single item (the link of a commodity is "": no roll).
                local var, vname = U.link_variant(info.item_link)
                list[#list + 1] = {
                    auction_id = info.auction_id, item_id = tonumber(info.item_id),
                    link = info.item_link, status = tonumber(info.status) or 0,
                    qty = tonumber(info.quantity) or 1, band = tonumber(info.time_left),
                    bid = tonumber(info.bid_amount) or 0, buyout = tonumber(info.buyout_amount) or 0,
                    bidder = info.bidder, var = var, vname = vname,
                }
            end
        end
        return list
    end

    local function send(req, t)
        req.sent_at = t
        last_sent = t
        active = req
        if req.kind == "search" then
            stats.searches = stats.searches + 1
            -- separate_owner_items: our own listings come back as their own rows.
            A.call("send_search_query", req.item_id, req.level or 0, 0, true)
        else
            A.call("query_owned_auctions")
        end
    end

    local function finish(result, why)
        local req = active
        active = nil
        if req.kind == "search" and result then
            -- Found nothing at this level: the next one (see A.search).
            if result.kind == "none" and req.levels and (req.try or 1) < #req.levels then
                req.try = (req.try or 1) + 1
                req.level, req.event_at = req.levels[req.try], nil
                table.insert(queue, 1, req)
                return
            end
            results[req.item_id] = result
            ctx.emit("jambix.market.search", result)
        end
        deliver(req, result, why)
    end

    local function poll(t)
        local req = active
        local elapsed = t - req.sent_at
        if req.kind == "owned" then
            if (req.event_at and t - req.event_at >= SETTLE) or elapsed >= OWNED_TIMEOUT then
                finish(read_owned(), req.event_at and nil or "no update event")
            end
            return
        end
        if elapsed < SETTLE then return end
        local settled = req.event_at and t - req.event_at >= SETTLE
        if settled then return finish(read_search(req)) end
        -- No event (yet): results that are complete and older than a moment
        -- are taken too, in case this client's pump never names them.
        if elapsed >= 1.5 then
            local nc, ni = counts(req)
            local full = (nc > 0 and A.call("has_full_commodity_search_results", req.item_id))
                or (ni > 0 and A.call("has_full_item_search_results", req.item_id, req.level or 0, 0))
            if full then return finish(read_search(req)) end
        end
        if elapsed >= SEARCH_TIMEOUT then
            stats.timeouts = stats.timeouts + 1
            -- Whatever arrived by now is an answer; nothing at all is NOT
            -- "nobody is selling" (the server was just slow): the caller hears
            -- "timed out", and nothing is stored or announced from it.
            local result = read_search(req)
            if result.kind == "none" then
                active = nil
                deliver(req, nil, "timed out")
                return
            end
            finish(result, "timed out")
        end
    end

    ctx.tick(function()
        local t = core.time()
        if not open then
            if active then
                local req = active
                active = nil
                deliver(req, nil, "auction house closed")
            end
            if #queue > 0 then
                local q = queue
                queue = {}
                for i = 1, #q do deliver(q[i], nil, "auction house closed") end
            end
            return
        end
        if active then return poll(t) end
        if #queue == 0 or A.locked() then return end
        if t - last_sent < MIN_GAP or not A.ready() then return end
        send(table.remove(queue, 1), t)
    end)

    function A.stats()
        local miss = {}
        for k in pairs(missing) do miss[#miss + 1] = k end
        table.sort(miss)
        return {
            open = open, calls = stats.calls, errors = stats.errors, searches = stats.searches,
            timeouts = stats.timeouts, queued = #queue, active = active and (active.kind .. " "
                .. tostring(active.item_id or "")) or nil, missing = miss, first = first,
        }
    end

    return A
end

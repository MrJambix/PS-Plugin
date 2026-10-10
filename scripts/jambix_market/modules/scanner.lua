-- Jambix Market / scanner -- the whole auction house as often as the server
-- gives it, tried every 3 minutes, and what matters in between.
--
-- The user (2026-10-07): "change full scans to every 3minutes". On retail,
-- Blizzard allows C_AuctionHouse.ReplicateItems -- the one call that reads
-- every auction -- once per 15 minutes, account-wide: "There's a 15 min
-- account-wide throttle between each successful
-- C_AuctionHouse.ReplicateItems() call" (warcraft.wiki.gg). Whether Forever
-- holds to that is not known. So a scan CYCLE runs every 3 minutes
-- (`scan_every`) while the auction house is open, and each cycle does the
-- most the server allows:
--
--   full   tried every cycle once the LEARNED gap since the last full scan
--          has passed: every auction, prices, and the sales estimate (this
--          scan against the last). The gap starts at 3 minutes. A full scan
--          the server refuses (below) marks the period; when one then works,
--          the gap becomes the time it took (never over 15 minutes, the
--          retail limit), so refused tries are not repeated every period.
--          After three clean ones in a row it tries one cycle sooner, in
--          case the server allows more. Kept in the price file's meta.gap.
--   quick  in between, when the server will not give a full scan: a fresh
--          search of what matters, `quick_items` at most
--          (quick_targets: what Auto holds, your auctions, the deals, then the
--          items that turn over the most money). Prices, the usual price and
--          the deals move with it; the sales estimate does not -- it compares
--          full scans only.
--
-- A THROTTLED FULL SCAN IS NOT A SCAN. The limit is account-wide, so another
-- character or another addon may have used it. Asked too soon, the server
-- sends no REPLICATE_ITEM_LIST_UPDATE and the client still holds the last
-- list; folded in again, it would read as "nothing sold in fifteen minutes"
-- and drag every sales estimate down. On Forever the update event proves
-- nothing: the user's recorder (2026-10-07) shows none for the first ten
-- sessions, then tens of thousands, none of them right after the call. So
-- the list itself must say: a list whose count never moves from what the
-- client held before the call, with no event either, is the old one, thrown
-- away unread after WAIT_LIMIT; and any list that is exactly the last full
-- scan's auctions, units and value (db.fingerprint), event or not, is thrown
-- away after reading. Full scans then wait one cycle, and a quick scan runs
-- instead. A list that changes while it is read (a slow one still landing)
-- is read again (signature at both ends).
-- Nothing answering at all backs off (15 minutes per failure in a row, an
-- hour at most); quick scans keep the prices fresh meanwhile.
-- (Comparing scans 3 minutes apart works as it does 15 apart: a listing
-- with under 30 minutes left still might have expired, any other gone is a
-- sale.)
--
-- Reading a full scan:
--   waiting  replicate_items() sent; wait for REPLICATE_ITEM_LIST_UPDATE, or
--            for the row count to stop moving, then read
--   reading  get_replicate_item_info + _time_left, 300 rows a tick and at
--            most 4 ms, into one listing table per item; for a single item
--            (gear and the like) its link too, for its roll (gear.lua)
--   folding  db.apply_scan in a coroutine, 150 items a tick
--   done / failed
--
-- Index base: the .api says 0-based on Forever (the retail side), 1-based
-- on the classic builds. Row 0 is read first; a row 0 with no item id
-- means 1-based. Time-left bands: the retail enum counts from 0, the
-- classic one from 1; any 0 in a scan means the scan counts from 0.

return function(M)
    local ctx, U, A, D, P = M.ctx, M.util, M.ah, M.db, M.pricing

    local S = {}

    -- A single item's link comes back blank about one time in ten (the user's
    -- recorder, 2026-10-10: 112,934 of 1,053,324), mostly an item's first
    -- auctions read: the client fills it in once it has loaded the item. So
    -- the blank ones are asked again after the read, up to three passes a
    -- second or two apart.
    local RELINK_ROUNDS = 3
    local RELINK_WAIT = { 0, 1.0, 2.0 }
    local RELINK_MAX = 40000
    local GAP_START = 3 * 60       -- full scans tried this often until the server says otherwise
    local GAP_MAX = 15 * 60        -- the retail limit: never waits longer than this
    local PROBE_AFTER = 3          -- clean full scans in a row before trying one cycle sooner
    local WAIT_LIMIT = 25.0        -- seconds for the list to arrive
    local STABLE_FOR = 1.5         -- a count unchanged this long is complete
    local ROWS_PER_TICK = 300
    local CPU_BUDGET_NS = 4e6      -- 4 ms
    local OPEN_SETTLE = 2.0        -- after the window opens, before a cycle
    local FRESH_SEARCH = 120       -- a search this recent is not repeated by a quick scan
    local MAX_BACKOFF = 3600

    local state = { phase = "idle" }
    local asked_at = nil           -- core.time() of our last replicate_items
    local list_event_at = nil
    local blocked_until = nil      -- core.time() before which no full scan is tried
    local empty_streak = 0         -- full scans in a row that brought nothing
    local folding = nil            -- the coroutine
    local quick = nil              -- the quick scan running
    local last_quick = nil         -- { total, done, at, took }
    local next_cycle = 0           -- core.time() of the next cycle
    local refused = false          -- the server refused a full scan since the last that worked

    ctx.on("jcore.game_event.REPLICATE_ITEM_LIST_UPDATE", function()
        list_event_at = core.time()
    end)

    local function cycle_seconds()
        return math.max(3, tonumber(M.cfg("scan_every", 3)) or 3) * 60
    end

    --- Seconds the server needs between full scans, as learned (see the top).
    function S.gap()
        local g = tonumber(D.meta().gap) or GAP_START
        return math.max(math.min(GAP_START, cycle_seconds()), math.min(GAP_MAX, g))
    end

    --- A full scan worked `took` seconds after the one before: learn from it.
    local function learn_gap(took)
        local meta = D.meta()
        if not took or took <= 0 then return end
        if refused and took <= GAP_MAX + cycle_seconds() then
            -- Refused before this worked, within the retail limit of the last
            -- one: the server needed about this long. (Refused long after the
            -- last -- another character or addon used the account's scan --
            -- says nothing about the gap.)
            meta.gap, meta.gap_ok = math.min(GAP_MAX, math.max(GAP_START, took)), 0
        else
            meta.gap_ok = (meta.gap_ok or 0) + 1
            if (meta.gap or GAP_START) > GAP_START and meta.gap_ok >= PROBE_AFTER then
                meta.gap, meta.gap_ok = math.max(GAP_START, meta.gap - cycle_seconds()), 0
            end
        end
        refused = false
        D.touch()
    end

    --- Epoch seconds when the next full scan may run.
    function S.next_due()
        local due = 0
        local last = D.meta().last_scan
        if last then due = last + S.gap() end
        if blocked_until then
            local b = U.now() + (blocked_until - core.time())
            if b > due then due = b end
        end
        return due
    end

    --- Seconds until the next scan cycle (full or quick).
    function S.next_cycle_in()
        return math.max(0, next_cycle - core.time())
    end

    function S.can_start()
        if not D.ready() then return false, "the price history is still loading" end
        if not A.is_open() then return false, "the auction house is closed" end
        local p = state.phase
        if p == "waiting" or p == "reading" or p == "folding" then return false, "a scan is running" end
        local gap = S.gap()
        if asked_at and core.time() - asked_at < gap and state.phase == "done" then
            return false, "full scans run every " .. U.ago(gap) .. " (next in "
                .. U.ago(gap - (core.time() - asked_at)) .. ")"
        end
        local last = D.meta().last_scan
        if last and U.now() - last < gap then
            return false, "full scans run every " .. U.ago(gap) .. " (next in "
                .. U.ago(gap - (U.now() - last)) .. ")"
        end
        if blocked_until and core.time() < blocked_until then
            return false, "the server did not send a new list; trying again in "
                .. U.ago(blocked_until - core.time())
        end
        return true
    end

    --- Starts a full scan. Returns false and why when it cannot.
    function S.start(reason)
        local ok, why = S.can_start()
        if not ok then return false, why end
        asked_at = core.time()
        list_event_at = nil
        -- What the client holds before asking: a list that never moves from it
        -- is the old one (the update event cannot be relied on; see the top).
        local held = tonumber(A.call("get_num_replicate_items")) or 0
        A.call("replicate_items")
        state = { phase = "waiting", at = asked_at, count = -1, stable_at = asked_at, reason = reason,
            held = held, changed = false, restarts = 0 }
        M.activity("Full scan started" .. (reason and (" (" .. reason .. ")") or ""))
        return true
    end

    function S.cancel(why)
        if state.phase == "waiting" or state.phase == "reading" then
            state = { phase = "failed", at = core.time(), why = why or "cancelled" }
        end
    end

    -- --- quick scans ------------------------------------------------------------

    --- What a quick scan re-checks, most important first, `cap` at most:
    --- what Auto holds, your auctions, the deals, then the items that turn
    --- over the most money (sales rate's lower bound x usual price). An item
    --- searched in the last two minutes is fresh already and left out.
    function S.quick_targets(cap)
        local out, seen = {}, {}
        local function add(id)
            id = tonumber(id)
            if not id or id <= 0 or seen[id] or #out >= cap then return end
            seen[id] = true
            local _, age = A.last(id)
            if age > FRESH_SEARCH then out[#out + 1] = id end
        end
        if M.ledger then
            for k, h in pairs(M.ledger.holdings()) do
                -- A roll of gear is kept as "id:roll"; its item is searched.
                if (h.qty or 0) > 0 then add(h.id or U.unvkey(k)) end
            end
        end
        if M.trader then
            local owned = M.trader.owned()
            for i = 1, #(owned or {}) do
                if owned[i].status ~= "sold" then add(owned[i].item_id) end
            end
        end
        if M.deals then
            local deals = M.deals.list()
            for i = 1, #deals do add(deals[i].item_id) end
        end
        -- Then where big money can show up: items a resale may be judged on
        -- (mature, not gear, seen selling) that one deal could buy with the
        -- money free (0.6 x their usual price within half of capital), the
        -- most valuable first.
        local ranked = {}
        local half = M.policy and M.policy.capital().capital * 0.5 or math.huge
        for k, rec in pairs(D.items()) do
            local id = tonumber(k)
            if (rec.c or 0) >= 3 and (rec.ev or 0) >= 2.5 and not (M.deals and M.deals.is_gear(id)) then
                local r = D.risk(rec)
                if r and r.mature and (r.per_day_low or 0) > 0 and r.reference and r.reference > 0
                    and 0.6 * r.reference <= half then
                    ranked[#ranked + 1] = { id = id, score = r.reference }
                end
            end
        end
        table.sort(ranked, function(a, b) return a.score > b.score end)
        for i = 1, #ranked do
            if #out >= cap then break end
            add(ranked[i].id)
        end
        -- Any slots left: the items that turn over the most money (as before).
        local turnover = {}
        for k, rec in pairs(D.items()) do
            local low = P.rate_lower(rec.sa, rec.oa, 1.645)
            local ref = D.reference(rec)
            if low > 0 and ref and ref > 0 then turnover[#turnover + 1] = { id = tonumber(k), score = low * ref } end
        end
        table.sort(turnover, function(a, b) return a.score > b.score end)
        for i = 1, #turnover do
            if #out >= cap then break end
            add(turnover[i].id)
        end
        return out
    end

    local function finish_quick(q, why)
        if quick ~= q then return end
        quick = nil
        q.took = core.time() - q.at
        last_quick = q
        local deals = M.deals and #M.deals.list() or 0
        M.activity(string.format("Quick scan: %d of %d item(s) re-checked in %ds; %d deal(s) on the list%s",
            q.answered, q.total, math.floor(q.took), deals, why and (" (" .. why .. ")") or ""))
        ctx.emit("jambix.market.quick_done", q)
    end

    --- Searches what matters now (quick_targets). Returns false and why when
    --- there is nothing to do or it cannot.
    function S.start_quick(reason)
        if quick then return false, "a quick scan is running" end
        if not D.ready() then return false, "the price history is still loading" end
        if not A.is_open() then return false, "the auction house is closed" end
        local ids = S.quick_targets(math.max(1, tonumber(M.cfg("quick_items", 80)) or 80))
        if #ids == 0 then return false, "nothing needs re-checking yet" end
        local q = { total = #ids, done = 0, answered = 0, at = core.time(), reason = reason }
        quick = q
        M.activity(string.format("Quick scan started: re-checking %d item(s)%s", #ids,
            reason and (" (" .. reason .. ")") or ""))
        for i = 1, #ids do
            local rec = D.item(ids[i])
            A.search(ids[i], { level = rec and rec.lv, reason = "quick" }, function(result)
                if quick ~= q then return end
                q.done = q.done + 1
                if result then q.answered = q.answered + 1 end
                if q.done >= q.total then finish_quick(q, not A.is_open() and "the auction house closed" or nil) end
            end)
        end
        return true
    end

    function S.quick_busy() return quick ~= nil end

    -- --- reading a full scan ---------------------------------------------------

    --- A full scan that brought nothing new: thrown away, and the cycle
    --- re-checks what matters instead.
    local function stale(why)
        -- The next try one cycle after this one was asked, not after the read.
        local asked = state.at or core.time()
        refused = true
        state = { phase = "failed", at = core.time(), why = why, stale = true }
        blocked_until = asked + cycle_seconds()
        M.activity("Full scan not used: " .. why)
        if M.cfg("quick_scan", true) then S.start_quick("instead of the full scan") end
    end

    local function fail(why)
        state = { phase = "failed", at = core.time(), why = why }
        M.activity("Full scan failed: " .. why)
    end

    local function valid(info)
        return type(info) == "table" and (tonumber(info.item_id) or 0) > 0
    end

    --- A few rows of the list, to tell whether it changed while it was read:
    --- the count, and item / count / buyout at four fixed places.
    local function signature(base, n)
        local parts = { tostring(n) }
        if n > 0 then
            local at = { base, base + math.floor(n / 3), base + math.floor(2 * n / 3), base + n - 1 }
            for i = 1, #at do
                local info = A.call("get_replicate_item_info", at[i])
                if type(info) == "table" then
                    parts[#parts + 1] = tostring(info.item_id) .. "/" .. tostring(info.count) .. "/"
                        .. tostring(info.buyout_price)
                end
            end
        end
        return table.concat(parts, ";")
    end

    local function begin_reading(n, t)
        local base = 1
        if valid(A.call("get_replicate_item_info", 0)) then base = 0 end
        local was = state
        state = {
            phase = "reading", at = was.at, read_at = t, base = base, i = base, last = base + n - 1, n = n,
            snap = { at = U.now(), items = {}, meta = {}, rows = 0, vnames = {}, singles = 0, linked = 0 },
            missing = 0, zero_band = false, single = {}, relink = {}, relinks = 0,
            evented = list_event_at ~= nil and list_event_at >= was.at, held = was.held, changed = was.changed,
            restarts = was.restarts or 0, sig = signature(base, n),
        }
        M.debug("scan: %d rows, index from %d%s", n, base, state.evented and "" or " (no update event)")
    end

    local function wait_tick(t)
        local n = tonumber(A.call("get_num_replicate_items")) or 0
        if n ~= state.count then state.count, state.stable_at = n, t end
        -- The list moved from what the client held before the call (it emptied,
        -- or a new one is landing): the server is sending a new list.
        if n ~= state.held then state.changed = true end
        local waited = t - state.at
        local evented = list_event_at and list_event_at >= state.at
        local settled = n > 0 and (
            (evented and t - list_event_at >= 1.0 and t - state.stable_at >= 0.5)
            or (state.changed and t - state.stable_at >= STABLE_FOR))
        if settled then return begin_reading(n, t) end
        if waited >= WAIT_LIMIT then
            if n > 0 and (evented or state.changed) then return begin_reading(n, t) end
            if n > 0 then
                -- The same list the client held before asking, all this time:
                -- the server sent none. Not read, not folded.
                empty_streak = 0
                return stale("the server sent no new list (it limits full scans, account-wide); trying "
                    .. "again in " .. U.ago(cycle_seconds()))
            end
            -- Nothing at all: throttled before this session's first list, or
            -- not answering. Either way, back off and let quick scans work.
            empty_streak = empty_streak + 1
            blocked_until = t + math.min(MAX_BACKOFF, GAP_MAX * empty_streak)
            state = { phase = "failed", at = t, why = "the auction house sent no list" }
            M.activity(string.format("Full scan: the auction house sent no list; trying again in %s",
                U.ago(blocked_until - t)))
            if M.cfg("quick_scan", true) then S.start_quick("instead of the full scan") end
        end
    end

    --- Is this auction a single item (gear, a bag, a recipe: one per auction,
    --- posted by hand on Forever), whose roll the link says? By the item's
    --- stack size when the client has said it, else by the auction's count.
    local function wants_link(st, id, count)
        local s = st.single[id]
        if s == nil then
            local info = D.info(id)
            if info and info.s then s = info.s <= 1 else s = "?" end
            st.single[id] = s
        end
        if s == "?" then return count == 1 end
        return s
    end

    local function read_tick()
        local st = state
        local snap = st.snap
        local started = core.cpu_time()
        local done = 0
        while st.i <= st.last and done < ROWS_PER_TICK do
            local i = st.i
            st.i = i + 1
            done = done + 1
            local info = A.call("get_replicate_item_info", i)
            if valid(info) then
                local id = tonumber(info.item_id)
                local count = math.max(1, tonumber(info.count) or 1)
                local buyout = tonumber(info.buyout_price) or 0
                local band = tonumber(A.call("get_replicate_item_time_left", i))
                if band == 0 then st.zero_band = true end
                local list = snap.items[id]
                if not list then
                    list = {}
                    snap.items[id] = list
                end
                -- A bid-only auction has no price to buy at; it still counts
                -- as supply for the sales estimate, priced at 0.
                local entry = {
                    unit = buyout > 0 and (buyout / count) or 0, qty = count,
                    owner = info.owner or "", band = band,
                }
                -- A single item's roll ("of the Monkey"), from its link: gear
                -- is priced by roll (gear.lua). Nil when the link said nothing.
                if wants_link(st, id, count) then
                    snap.singles = snap.singles + 1
                    local var, vname = U.link_variant(A.call("get_replicate_item_link", i))
                    if var then
                        entry.var = var
                        snap.linked = snap.linked + 1
                        if vname and var ~= "" then snap.vnames[U.vkey(id, var)] = vname end
                    elseif #st.relink < RELINK_MAX then
                        st.relink[#st.relink + 1] = { i = i, entry = entry, id = id }
                    end
                end
                list[#list + 1] = entry
                if not snap.meta[id] then
                    snap.meta[id] = {
                        name = info.has_all_info ~= false and info.name or nil,
                        quality = tonumber(info.quality_id), level = tonumber(info.level),
                    }
                end
                snap.rows = snap.rows + 1
            else
                st.missing = st.missing + 1
            end
            if done % 50 == 0 and core.cpu_time() - started > CPU_BUDGET_NS then break end
        end
        -- Links that came back blank, asked again (see RELINK_ROUNDS): a pass
        -- at a time, budgeted like the read, before the list is checked.
        if st.i > st.last and #st.relink > 0 and st.relinks < RELINK_ROUNDS then
            local t = core.time()
            if not st.relink_at then
                st.relink_at, st.relink_pos, st.relink_left = t + (RELINK_WAIT[st.relinks + 1] or 1.0), 1, {}
                st.relink_asked = st.relink_asked or {}
            end
            if t < st.relink_at then return end
            local pos, n = st.relink_pos, 0
            local began = core.cpu_time()
            while pos <= #st.relink and n < ROWS_PER_TICK do
                local r = st.relink[pos]
                pos, n = pos + 1, n + 1
                local var, vname = U.link_variant(A.call("get_replicate_item_link", r.i))
                if var then
                    r.entry.var = var
                    snap.linked = snap.linked + 1
                    if vname and var ~= "" then snap.vnames[U.vkey(r.id, var)] = vname end
                else
                    st.relink_left[#st.relink_left + 1] = r
                    -- Ask the client for the item once, so it loads it for the next pass.
                    if not st.relink_asked[r.id] then
                        st.relink_asked[r.id] = true
                        U.try(core.quests and core.quests.get_item_info, r.id)
                    end
                end
                if n % 50 == 0 and core.cpu_time() - began > CPU_BUDGET_NS then break end
            end
            st.relink_pos = pos
            if pos <= #st.relink then return end
            st.relink, st.relink_left, st.relink_at, st.relink_pos = st.relink_left, nil, nil, nil
            st.relinks = st.relinks + 1
            return
        end
        if st.i > st.last then
            -- The list changed while it was read (a slow list still landing, or
            -- a new one replacing the old): what was read is a mix. Read again.
            local n_now = tonumber(A.call("get_num_replicate_items")) or 0
            if n_now ~= st.n or signature(st.base, n_now) ~= st.sig then
                if (st.restarts or 0) >= 3 then
                    return fail("the auction list kept changing while it was read")
                end
                state = { phase = "waiting", at = st.at, count = n_now, stable_at = core.time(), reason = "re-read",
                    held = st.held, changed = true, restarts = (st.restarts or 0) + 1 }
                M.debug("scan: the list changed while it was read; reading it again")
                return
            end
            -- Bands to 1..4; an unknown band is the shortest, so it never
            -- counts as a sale it might not be.
            local shift = st.zero_band and 1 or 0
            for _, list in pairs(snap.items) do
                for j = 1, #list do
                    local b = list[j].band
                    b = b and (b + shift) or 1
                    if b < 1 then b = 1 elseif b > 4 then b = 4 end
                    list[j].band = b
                end
            end
            if snap.rows == 0 then
                empty_streak = empty_streak + 1
                blocked_until = core.time() + math.min(MAX_BACKOFF, GAP_MAX * empty_streak)
                return fail(string.format("%d rows and none had an item id", st.n))
            end
            -- Exactly the last scan again: the old list, whatever events came
            -- (a live auction house of tens of thousands of auctions does not
            -- match itself to the silver even three minutes on).
            local fp, last = D.fingerprint(snap), D.meta().fp
            if last and fp.rows == last.rows and fp.units == last.units and fp.value == last.value
                and fp.unit == last.unit then
                empty_streak = 0
                return stale("the server sent the last list again (it limits full scans, account-wide); "
                    .. "trying again in " .. U.ago(cycle_seconds()))
            end
            empty_streak = 0
            blocked_until = nil
            state = { phase = "folding", at = st.at, rows = snap.rows, missing = st.missing }
            folding = coroutine.create(function() return D.apply_scan(snap) end)
        end
    end

    local function fold_tick(t)
        local ok, summary = coroutine.resume(folding)
        if not ok then
            folding = nil
            M.log.fmt("error", "folding the scan raised: %s", tostring(summary))
            return fail("could not fold the scan in")
        end
        if coroutine.status(folding) ~= "dead" then return end
        folding = nil
        local s = summary or {}
        learn_gap(s.elapsed)
        D.save(true)
        state = { phase = "done", at = t, rows = state.rows, summary = summary, took = t - state.at }
        if s.compared then
            M.activity(string.format("Full scan: %d items in %d auctions; about %d units sold in the last %s",
                s.items or 0, state.rows or 0, math.floor((s.sold or 0) + 0.5), U.ago(s.elapsed)))
        else
            M.activity(string.format("Full scan: %d items in %d auctions (sales show from the next scan)",
                s.items or 0, state.rows or 0))
        end
        ctx.emit("jambix.market.scan_done", s)
    end

    -- --- the cycle ------------------------------------------------------------------

    ctx.tick(function()
        local t = core.time()
        local p = state.phase
        if (p == "waiting" or p == "reading") and not A.is_open() then
            return fail("the auction house closed mid-scan")
        end
        if p == "waiting" then return wait_tick(t) end
        if p == "reading" then return read_tick() end
        if p == "folding" then return fold_tick(t) end

        -- A scan cycle when one is due and the window has been open a moment:
        -- a full scan when the server allows one, a quick one otherwise.
        local wanted = M.cfg("auto_scan", true) or (M.auto and M.auto.active())
        if not (M.cfg("enabled", true) and wanted and A.is_open()) then return end
        local since = A.open_since()
        if not since or t - since < OPEN_SETTLE or t < next_cycle or quick or not D.ready() then return end
        next_cycle = t + cycle_seconds()
        if S.can_start() then
            S.start("auto")
        else
            if M.cfg("quick_scan", true) then S.start_quick("auto") end
            -- The next cycle no later than the moment a full scan is allowed
            -- again (the review, 1.0.0: on a fixed grid the full-scan gate
            -- opened seconds after a cycle, and full scans ran a cycle late).
            local due_in = S.next_due() - U.now()
            if due_in > 0 and due_in < cycle_seconds() then
                next_cycle = math.min(next_cycle, t + due_in + 1)
            end
        end
    end)

    -- A fresh visit: a cycle as soon as the window has settled.
    ctx.on("jambix.market.ah_open", function() next_cycle = 0 end)

    --- A cycle on the next tick (the AUTO button: start finding at once).
    function S.cycle_now() next_cycle = 0 end

    --- For the window: phase, 0..1 progress, and a line saying what is happening.
    function S.progress()
        local p = state.phase
        if p == "waiting" then
            return p, 0, string.format("Waiting for the auction list (%ds)", math.floor(core.time() - state.at))
        elseif p == "reading" then
            local f = state.n > 0 and ((state.i - state.base) / state.n) or 0
            return p, f, string.format("Reading %d of %d auctions", state.i - state.base, state.n)
        elseif p == "folding" then
            return p, 1, "Working out prices and sales"
        end
        if quick then
            return "quick", quick.total > 0 and (quick.done / quick.total) or 0,
                string.format("Quick scan: re-checked %d of %d item(s)", quick.done, quick.total)
        end
        if p == "failed" then
            return p, 0, "Last full scan: " .. tostring(state.why)
        elseif p == "done" then
            return p, 1, string.format("Scanned %d auctions in %ds", state.rows or 0, math.floor(state.took or 0))
        end
        return p, 0, ""
    end

    --- Is a FULL scan running? (A quick scan is only searches, and Auto may
    --- trade while it runs.)
    function S.busy()
        local p = state.phase
        return p == "waiting" or p == "reading" or p == "folding"
    end

    --- Have full scans failed to answer three times in a row?
    function S.unsupported() return empty_streak >= 3 end

    function S.last_quick() return last_quick end

    function S.stats()
        return { phase = state.phase, why = state.why, empty = empty_streak, next_due = S.next_due(),
            next_cycle_in = S.next_cycle_in(), quick = quick and quick.done .. "/" .. quick.total or nil }
    end

    return S
end

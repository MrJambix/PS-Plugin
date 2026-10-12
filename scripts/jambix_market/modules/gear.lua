-- Jambix Market / gear -- weapons, armor and every other single item: found
-- and bought like the rest, POSTED BY YOU.
--
-- The user (2026-10-09): "lets identify weapon and gear that we can Flip for
-- price like the rest but we will have to post it ourselfs".
--
-- WHY BY HAND. Forever's client never takes core.auction_house.post_item.
-- The user's test plugin (scripts/jambix_postprobe, 2026-10-09) tried it
-- every way -- buyout only, a bid under it, bid equal to it, a bid alone, a
-- nil bid, the commodity call, the game's own C_AuctionHouse.PostItem
-- through execute, the slot either side -- and nothing listed and the game
-- said nothing back. Stackable goods post (post_commodity); a single item --
-- every weapon and armor piece, bags, recipes: one to an auction -- only
-- through the auction house window. So Auto finds and buys gear deals like
-- any other, and you post them: the Gear tab says what, and the buyout to
-- type in. Post for 48 hours; the deposit comes back when it sells.
--
-- BY ROLL, NOT BY ITEM. One item id covers every random suffix: a Bandit
-- Cloak "of the Monkey" and one "of the Owl" sell for very different
-- prices. Forever writes the roll into the item link as a bonus id
-- (util.link_variant), a full scan reads the link of every single item
-- (scanner.lua), and prices, sales and deals here are kept per ROLL: item id
-- + its bonus ids, "9779:12741". An item with no roll is one roll ("9779"),
-- judged on the item's own record in the price file (every sale since it was
-- first seen), as long as no auction of the item has ever shown a roll
-- ("mixed"); an auction of it whose link came back blank is that roll too.
--
-- Kept per roll, in scripts_data/jcore/jambix.market.<realm>.gear.json: the
-- fields of db.lua's records (m n q l h ht c t f sa oa un ev eu eo ei d,
-- seven days of d), and the roll's name as its link shows it (nm). Sales
-- are compared scan to scan exactly as db.lua does, Auto's own purchases
-- taken off, item by item: an item with a listing whose link did not answer
-- (and more than one roll) is left out of that comparison, as such a listing
-- would read as a sale. (1.2.0 asked 90% of a whole scan's links instead; the
-- user's scans read 89%, so no roll ever had a sale and nothing was bought.)
--
-- Deals: pricing.plan_flip and deals.finish, as for everything else -- the
-- same bar, floor, size, order and big money. What differs:
--   * half a day of selling is credited to a 48-hour post, not one: nobody
--     reposts it when it is undercut (Auto cannot, and you may be away)
--   * one item a purchase (lot 1), one item a post: every unit is a 48-hour
--     deposit of 60% of its vendor price, lost if it does not sell
--   * the search before a purchase must say each auction's roll: nothing is
--     bought blind
-- Auto keeps at most GEAR_WAITING bought pieces waiting for you, counted
-- piece by piece: once two wait to be posted (in the bags or the mailbox) it
-- buys no more gear until you post them. What it holds is held apart, roll by
-- roll (util.hkey), never under the item's own key: a vendor flip of the same
-- item never takes a gear piece's place. A piece you keep, equip or sell
-- yourself leaves its books on its own (reconcile, below). Its bids (place_bid) had never been seen on Forever before
-- this: if the game answers none of the first two, gear buying stops until
-- Auto is switched on again, and the deals stay listed for you to buy by hand.

return function(M)
    local ctx, U, P, A, D, L = M.ctx, M.util, M.pricing, M.ah, M.db, M.ledger

    local G = {}

    local PRICE_HALF_LIFE = 3 * 86400
    local SALES_HALF_LIFE = 3 * 86400
    local MAX_COMPARE = 6 * 3600       -- scans further apart than this are not compared
    local MIN_COMPARE = 60
    local HISTORY_DAYS = 7
    local KEEP_DAYS = 10               -- a roll not seen this long is forgotten
    local MAX_DATA_AGE = 1800          -- as deals.lua: older data is not planned on
    local LINK_COVERAGE = 0.9          -- under this share of single items' links read, the scan is said to be short
    local GEAR_DAYS = 0.5              -- selling credited to one 48-hour post (see the top)
    local CANCEL_TRUST = 0.75          -- as deals.lua
    local GEAR_WAITING = 2             -- bought pieces waiting for you, at most
    local BID_TRIES = 2                -- unanswered bids before gear buying stops for the session
    local SAVE_EVERY = 600
    local NEAR_FLOOR = 0.5             -- "cheap, but not sure enough": shown from 50% sure
    local CLASS_QUEST = 12
    local BIND_ON_PICKUP = 1
    local POST_HOURS = 48

    local data = { v = 1, items = {}, mixed = {}, meta = {} }
    local file = nil
    local loaded = false
    local dirty = false
    local saved_at = -math.huge
    local last = nil                   -- the scan last folded in (db.previous() then)
    local folding = nil                -- the fold's coroutine
    local names = nil                  -- lower-case roll name -> { vkey, ... }
    local bid = { worked = 0, failed = 0, stopped = nil }
    local drops = {}                   -- recent drops in gold: { t, copper }
    local created = {}                 -- auction id key -> core.time() it was created
    local bag_cache, bag_at = nil, -math.huge
    local near_cache, near_at = nil, -math.huge
    local remind_at = nil

    -- --- what an item is -------------------------------------------------------

    --- One to an auction (a single item): posted only by hand on Forever.
    function G.is_single(id)
        local info = D.info(id)
        return info ~= nil and info.s ~= nil and info.s <= 1
    end

    local function maybe_yield(n)
        if n % 150 ~= 0 then return end
        local co, main = coroutine.running()
        if co and not main then coroutine.yield() end
    end

    local function cheapest(rows)
        local low = math.huge
        for i = 1, #rows do
            local r = rows[i]
            if not r.own and (r.unit or 0) > 0 and r.unit < low then low = r.unit end
        end
        return low
    end

    -- --- the file ----------------------------------------------------------------

    --- Opens this realm's gear file. Called once the price file is loaded.
    function G.load()
        if loaded then return end
        loaded = true
        local realm = ""
        pcall(function() realm = ctx.world.realm() or "" end)
        local slug = ctx.util.slug(realm ~= "" and realm or "default")
        file = "jcore/jambix.market." .. slug .. ".gear.json"
        local raw = ctx.storage.read_json(file)
        if type(raw) == "table" and type(raw.items) == "table" then
            data = raw
            data.mixed = type(data.mixed) == "table" and data.mixed or {}
            data.meta = type(data.meta) == "table" and data.meta or {}
        end
        -- The last full scan, as saved: the next one's sales are read against it.
        last = D.previous()
        saved_at = core.time()
    end

    function G.save(force)
        if not loaded or not dirty then return end
        if not force and core.time() - saved_at < SAVE_EVERY then return end
        ctx.storage.write_json(file, data, false)
        dirty, saved_at = false, core.time()
    end

    ctx.every(60, function() G.save(false) end)

    -- --- a scan's rolls -------------------------------------------------------------

    --- An item seen with no roll and never with one (a blue's fixed stats, a
    --- bag): it has one roll, so an auction of it whose link said nothing is
    --- that roll too (the user's scans, 2026-10-10: one link in ten came back
    --- blank, mostly an item's first auctions read).
    local function is_plain(id)
        local k = U.key(id)
        return not data.mixed[k] and data.items[k] ~= nil
    end
    G.is_plain = is_plain

    --- A listing's roll: its own, or "" for a plain item's blank link; nil
    --- when not known.
    local function roll_of(id, l, plain)
        if l.var ~= nil then return l.var end
        if plain then return "" end
        return nil
    end

    --- A scan's single-item listings by roll: vkey -> { id, var, rows }.
    --- Kept on the scan itself (it does not change once read).
    local function group(snap)
        if not snap then return {} end
        if snap.gear_groups then return snap.gear_groups end
        local out = {}
        for id, listings in pairs(snap.items) do
            local info = D.info(id)
            -- A stackable item whose stack of one had its link read is not gear.
            if not (info and info.s and info.s > 1) then
                local plain = is_plain(id)
                for i = 1, #listings do
                    local l = listings[i]
                    local var = roll_of(id, l, plain)
                    if var ~= nil then
                        local k = U.vkey(id, var)
                        local g = out[k]
                        if not g then
                            g = { id = id, var = var, rows = {} }
                            out[k] = g
                        end
                        g.rows[#g.rows + 1] = l
                    end
                end
            end
        end
        snap.gear_groups = out
        return out
    end

    --- Of a scan's single items, the share whose link was read (nil: none).
    local function coverage(snap)
        if not snap then return nil end
        if not snap.singles then
            -- Read from a file: counted from what it holds.
            local n, linked = 0, 0
            for id, listings in pairs(snap.items) do
                local info = D.info(id)
                if info and info.s and info.s <= 1 then
                    n = n + #listings
                    for i = 1, #listings do
                        if listings[i].var ~= nil then linked = linked + 1 end
                    end
                end
            end
            snap.singles, snap.linked = n, linked
        end
        if (snap.singles or 0) <= 0 then return nil end
        return (snap.linked or 0) / snap.singles
    end

    --- Items whose every listing in a scan had its link read (an item with a
    --- listing whose link did not answer is not compared: that listing would
    --- read as a sale of its roll -- the review, 1.2.0).
    local function complete(snap)
        if snap.gear_complete then return snap.gear_complete end
        local out = {}
        for id, listings in pairs(snap.items) do
            local all = true
            if not is_plain(id) then
                for i = 1, #listings do
                    if listings[i].var == nil then
                        all = false
                        break
                    end
                end
            end
            out[id] = all
        end
        snap.gear_complete = out
        return out
    end

    --- Auto's own purchases of each roll between two scans: they left the
    --- auction house by its hand, not a buyer's.
    local function own_removed(from, to)
        local own = {}
        local trades = L.trades()
        for i = #trades, 1, -1 do
            local tr = trades[i]
            local t = tonumber(tr.t) or 0
            if t <= from then break end
            if tr.kind == "buy" and tr.id and t <= to and (tr.roll or tr.var) then
                local k = U.vkey(tr.id, tr.roll or tr.var)
                own[k] = (own[k] or 0) + (tr.qty or 0)
            end
        end
        return own
    end

    local function credit(rec, before, after, elapsed, mine)
        local sold, unclear, _, _, sales = P.sales_between(before, after, elapsed)
        sold, sales = P.sales_without(sold, sales, mine)
        local keep = P.decay(elapsed, SALES_HALF_LIFE)
        rec.sa = (rec.sa or 0) * keep + sold
        rec.oa = (rec.oa or 0) * keep + elapsed
        rec.un = (rec.un or 0) * keep + unclear
        rec.ev = (rec.ev or 0) * keep + sales
        rec.eu = (rec.eu or 0) * keep + sold
        rec.eo = (rec.eo or 0) * keep + elapsed
        rec.ei = (rec.ei or 0) * keep + (sales > 0 and 1 or 0)
        return sold
    end

    local function held(vkey)
        local id, var = U.unvkey(vkey)
        local h = L.holding(id, var)
        return h ~= nil and (h.qty or 0) > 0
    end

    --- Folds one full scan's rolls in: prices, and sales against the scan
    --- before. May yield (run in a coroutine).
    local function fold(old, new)
        local now = new.at
        local elapsed = old and (now - old.at) or nil
        local new_cov = coverage(new)
        -- Compared item by item (comparable, below): a link that did not
        -- answer keeps its own item out, never the whole scan (1.2.0 held every
        -- scan back at 89% read against a 90% bar: no roll ever had a sale).
        local compare = elapsed ~= nil and elapsed >= MIN_COMPARE and elapsed <= MAX_COMPARE
        local before = compare and group(old) or {}
        local after = group(new)
        local own = compare and own_removed(old.at, now) or {}
        local whole_old = compare and complete(old) or {}
        local whole_new = complete(new)
        -- Sales of an item's rolls only when every listing of it had its link
        -- read in both scans (an item absent from a scan is whole there).
        local function comparable(id)
            return compare and whole_old[id] ~= false and whole_new[id] ~= false
        end
        local items = data.items
        local n, rolls, sold_total = 0, 0, 0
        for k, g in pairs(after) do
            local rec = items[k]
            if not rec then
                rec = { f = now, c = 0 }
                items[k] = rec
            end
            if g.var ~= "" then data.mixed[U.key(g.id)] = true end
            local market, lowest, qty = P.market_value(g.rows)
            local sold = 0
            if comparable(g.id) then sold = credit(rec, before[k] and before[k].rows or {}, g.rows, elapsed, own[k]) end
            if market then
                rec.h = P.blend(rec.h, market, now - (rec.ht or now), PRICE_HALF_LIFE)
                rec.ht, rec.m = now, market
            end
            rec.n, rec.q, rec.l = lowest, qty, #g.rows
            rec.t, rec.c = now, (rec.c or 0) + 1
            local vn = new.vnames and new.vnames[k]
            if vn then rec.nm = vn end
            D.add_day(rec, now, market, qty, lowest, sold, HISTORY_DAYS)
            sold_total = sold_total + sold
            rolls = rolls + 1
            n = n + 1
            maybe_yield(n)
        end
        -- Listed last time, gone now: sold out, expired or cancelled.
        for k, g in pairs(before) do
            if not after[k] and comparable(g.id) then
                local rec = items[k]
                if rec then
                    local sold = credit(rec, g.rows, {}, elapsed, own[k])
                    rec.q, rec.l, rec.n = 0, 0, nil
                    D.add_day(rec, now, nil, 0, nil, sold, HISTORY_DAYS)
                    sold_total = sold_total + sold
                end
                n = n + 1
                maybe_yield(n)
            end
        end
        -- Rolls gone for KEEP_DAYS are forgotten, unless Auto holds one.
        local kept = 0
        for k, rec in pairs(items) do
            if (rec.t or 0) < now - KEEP_DAYS * 86400 and not held(k) then items[k] = nil else kept = kept + 1 end
        end
        local meta = data.meta
        meta.rolls = kept
        meta.last_scan, meta.scans = now, (meta.scans or 0) + 1
        meta.coverage, meta.singles, meta.compared = new_cov, new.singles, compare and true or false
        names = nil
        dirty = true
        return { rolls = rolls, sold = sold_total, compared = compare, coverage = new_cov, singles = new.singles,
            elapsed = elapsed }
    end

    ctx.on("jambix.market.scan_done", function()
        if not loaded then return end
        local new = D.previous()
        if not new or new == last then return end
        local old = last
        last = new
        folding = coroutine.create(function() return fold(old, new) end)
    end)

    ctx.tick(function()
        if not folding then return end
        local ok, res = coroutine.resume(folding)
        if not ok then
            folding = nil
            M.log.fmt("error", "gear: folding the scan raised: %s", tostring(res))
            return
        end
        if coroutine.status(folding) ~= "dead" then return end
        folding = nil
        res = res or {}
        G.save(false)
        if (res.singles or 0) > 0 and (res.coverage or 0) < LINK_COVERAGE then
            M.debug("gear: the scan read the roll of %d%% of %d single items; an item with a link unread is not "
                .. "compared this time", math.floor((res.coverage or 0) * 100), res.singles)
        else
            M.debug("gear: %d roll(s) priced%s", res.rolls or 0, res.compared and string.format(", about %d sold",
                math.floor((res.sold or 0) + 0.5)) or "")
        end
        ctx.emit("jambix.market.gear_done", res)
    end, { interval = 0.05 })

    -- --- records and names ---------------------------------------------------------

    --- The record a roll is judged on, and which: its own ("roll"), or -- for
    --- an item no auction of which has ever shown a roll -- the item's
    --- ("item"), which holds the same auctions and every sale since.
    function G.record(vkey)
        local id, var = U.unvkey(vkey)
        local rec = data.items[U.vkey(id, var)]
        -- An item that has only one roll: its record in the price file is the
        -- roll's, with every sale since it was first seen (links or not).
        if var == "" and not data.mixed[U.key(id)] then
            local whole = D.item(id)
            if whole then return whole, "item" end
        end
        return rec, "roll"
    end

    function G.records() return data.items end
    function G.meta() return data.meta end

    --- A roll's name, as its link shows it ("Bandit Cloak of the Monkey").
    function G.name(id_or_key, var)
        local id, v
        if var ~= nil then id, v = tonumber(id_or_key), var else id, v = U.unvkey(id_or_key) end
        local vkey = U.vkey(id, v)
        local rec = data.items[vkey]
        if rec and rec.nm then return rec.nm end
        for _, h in pairs(L.holdings()) do
            if h.id == id and (h.var or "") == v and h.name then return h.name end
        end
        local base = D.name(id)
        if v == "" then return base end
        return base .. " (roll " .. v .. ")"
    end

    --- The item id and roll of a roll's full name (a sale mail's subject says
    --- only the name): the one Auto holds first. Nil when no roll has it.
    function G.by_name(name)
        if type(name) ~= "string" or name == "" then return nil end
        local lower = name:lower()
        for _, h in pairs(L.holdings()) do
            if h.name and h.id and (h.qty or 0) > 0 and h.name:lower() == lower then return h.id, h.var or "" end
        end
        if not names then
            names = {}
            for k, rec in pairs(data.items) do
                if rec.nm then
                    local lk = rec.nm:lower()
                    names[lk] = names[lk] or {}
                    local list = names[lk]
                    list[#list + 1] = k
                end
            end
        end
        local list = names[lower]
        if not list or #list == 0 then return nil end
        for i = 1, #list do
            local id, var = U.unvkey(list[i])
            if held(list[i]) then return id, var end
        end
        return U.unvkey(list[1])
    end

    -- --- the freshest auctions of a roll ----------------------------------------------

    --- Search rows of item `id` by roll: var -> rows. Nil when any row does
    --- not say its roll (no link) and the item has more than one: such a
    --- search cannot tell rolls apart.
    local function split_rows(rows, id)
        local out = {}
        local plain = id and is_plain(id)
        for i = 1, #rows do
            local r = rows[i]
            local var = roll_of(id, r, plain)
            if var == nil then return nil end
            local list = out[var]
            if not list then
                list = {}
                out[var] = list
            end
            list[#list + 1] = r
        end
        return out
    end

    --- A search's rows of one roll of item `id`. Nil when the search cannot
    --- tell rolls apart -- then nothing of it is bought.
    function G.filter(rows, var, id)
        local out = {}
        local plain = id and is_plain(id)
        for i = 1, #rows do
            local r = rows[i]
            local v = roll_of(id, r, plain)
            if v == nil then return nil end
            if v == var then out[#out + 1] = r end
        end
        return out
    end

    --- The freshest auctions of a roll and when they were seen: the item's
    --- last search when newer than the full scan, else the scan's (yours
    --- left out). Nil when neither is recent enough or says the roll.
    local function freshest(vkey)
        local id, var = U.unvkey(vkey)
        local now = U.now()
        local snap = D.previous()
        local r = A.results()[id]
        -- A search that found NOTHING of a single item is not believed over
        -- the scan: its item key may not have matched (1.2.1 searched by the
        -- level to use an item, and found no gear at all). The purchase's own
        -- search decides then.
        if r and r.kind == "item" and (not snap or (r.at or 0) > snap.at) then
            if now - (r.at or 0) > MAX_DATA_AGE then return nil end
            local rows = G.filter(r.rows, var, id)
            if not rows then return nil end
            return rows, r.at, "search"
        end
        if snap and now - snap.at <= MAX_DATA_AGE then
            local g = group(snap)[U.vkey(id, var)]
            local own = M.deals.own_signatures()
            return M.deals.without_own(id, g and g.rows or {}, own), snap.at, "scan"
        end
        return nil
    end

    --- As freshest, and nil when Auto bought the roll since: those rows still
    --- show what it bought (deals.affordable plans on these).
    function G.rows_for(vkey)
        local rows, at = freshest(vkey)
        if not rows or M.deals.bought_since(vkey, at) then return nil end
        return rows
    end

    --- The cheapest other seller of a roll, and whether that is known.
    function G.lowest(id, var)
        local rows = freshest(U.vkey(id, var))
        if not rows then return nil, false end
        local low = cheapest(rows)
        if low == math.huge then return nil, true end
        return low, true
    end

    -- --- deals -------------------------------------------------------------------------

    --- The best resale of one roll from `rows`, or nil when none pays: as
    --- deals.plan_for for the rest (see the top for what differs).
    ---@param vkey string|integer
    ---@param rows table[]
    ---@param o? table deals.options(), with budget / size for a purchase
    function G.plan_for(vkey, rows, o)
        local K, Pol = M.deals, M.policy
        o = o or K.options()
        if not o.flip then return nil end
        local id, var = U.unvkey(vkey)
        vkey = U.vkey(id, var)
        local info = D.info(id)
        if not (info and info.ok and info.s and info.s <= 1) then return nil end
        if info.b == BIND_ON_PICKUP or info.c == CLASS_QUEST then return nil end
        local rec = G.record(vkey)
        local risk = rec and D.risk(rec)
        if not (risk and risk.mature and risk.usual and (risk.per_day_low or 0) > 0) then return nil end
        if Pol.cooling(id) then return nil end
        local h = L.holding(id, var)
        local have = h and math.max(0, h.qty or 0) or 0
        local room_units = math.floor((risk.per_day or 0) * (o.stock_days or 3)) - have
        -- A purchase: no more pieces than leaves at most GEAR_WAITING waiting
        -- for you (the review, 1.2.0: a plan of two could take it past).
        if o.size then room_units = math.min(room_units, G.room()) end
        if room_units < 1 then return nil end
        local budget = math.min(o.budget or math.huge, o.max_spend or math.huge)
        local vendor = D.vendor(id) or 0
        local rate = Pol.deposit_rate(POST_HOURS)
        local plan = P.plan_flip(rows, {
            held = have,
            usual = risk.usual, median = risk.median, market = risk.market,
            cut_pct = o.cut_pct, undercut = o.undercut,
            min_margin_pct = o.min_margin_pct, budget = budget, whole = true,
            max_units = room_units,
            cv = risk.cv, trend = risk.trend, sales_per_day = risk.per_day_low * CANCEL_TRUST, lot = 1,
            days = GEAR_DAYS, vendor = vendor,
            deposit_unit = math.max(vendor * (rate or 0.6), Pol.deposit_floor()),
            post_fee = Pol.deposit_floor(), deposit_rate = rate, stack = 1,
            posts = Pol.posts_max(), survive = P.FLOOR_FEES,
            min_confidence = o.min_confidence or 0.99,
        })
        if plan.units <= 0 or plan.profit <= 0 then return nil end
        plan.gear, plan.var, plan.key, plan.name = true, var, vkey, G.name(vkey)
        return K.finish(plan, o, id, rec, risk, function(sized) return G.plan_for(vkey, rows, sized) end)
    end

    --- Every roll's deal over the freshest data (deals.compute puts them on
    --- the list with the rest).
    function G.deals(o)
        local out = {}
        if not loaded or not o or not o.flip then return out end
        local snap = D.previous()
        local now = U.now()
        local snap_at = snap and snap.at or -math.huge
        local need = 1 + (o.min_margin_pct or 0) / 100
        local K = M.deals
        local function consider(vkey, rows, at, checked)
            if now - at > MAX_DATA_AGE or K.bought_since(vkey, at) then return end
            local low = cheapest(rows)
            if low == math.huge then return end
            -- Most rolls fail one comparison of the cheapest auction; only
            -- the rest are planned.
            local rec = G.record(vkey)
            local ref = rec and D.reference(rec)
            if not (ref and P.net(ref, o.cut_pct) > low * need) then return end
            local plan = G.plan_for(vkey, rows, o)
            if plan then
                plan.checked = checked or nil
                out[#out + 1] = plan
            end
        end
        -- Items searched since the scan: their rolls as the search shows them
        -- (a search that cannot tell rolls apart says nothing of any; one that
        -- found nothing is not believed over the scan: see freshest).
        local searched = {}
        for id, r in pairs(A.results()) do
            if r.kind == "item" and (r.at or 0) > snap_at and G.is_single(id) then
                searched[id] = true
                local rolls = split_rows(r.rows, id)
                if rolls then
                    for var, rows in pairs(rolls) do consider(U.vkey(id, var), rows, r.at or 0, true) end
                end
            end
        end
        if snap and now - snap.at <= MAX_DATA_AGE then
            local own = K.own_signatures()
            for vkey, g in pairs(group(snap)) do
                if not searched[g.id] then consider(vkey, K.without_own(g.id, g.rows, own), snap_at) end
            end
        end
        return out
    end

    --- A fresh search of a single item: the deal of every roll it shows (an
    --- empty list when it shows none, or cannot tell rolls apart).
    function G.plans_from_search(result)
        local out = {}
        if not loaded or not result or result.kind ~= "item" then return out end
        local rolls = split_rows(result.rows, result.item_id)
        if not rolls then return out end
        local o = M.deals.options()
        for var, rows in pairs(rolls) do
            local plan = G.plan_for(U.vkey(result.item_id, var), rows, o)
            if plan then out[#out + 1] = plan end
        end
        return out
    end

    --- Cheap rolls that are NOT sure enough for Auto: listed well under their
    --- usual price, but too few buyers (or too new) to be 98% sure. Shown so
    --- you can judge them; Auto never buys them. Best expected first, ten at
    --- most; cached ten seconds.
    function G.near()
        local t = core.time()
        if near_cache and t - near_at < 10 then return near_cache end
        local out = {}
        local K = M.deals
        local o = K.options()
        local bar = o.min_confidence or 0.99
        local listed = {}
        for _, d in ipairs(K.list()) do if d.gear then listed[d.key] = true end end
        local snap = D.previous()
        if loaded and o.flip and snap and U.now() - snap.at <= MAX_DATA_AGE then
            local own = K.own_signatures()
            local need = 1 + (o.min_margin_pct or 0) / 100
            local loose = {}
            for k, v in pairs(o) do loose[k] = v end
            loose.min_confidence = NEAR_FLOOR
            for vkey, g in pairs(group(snap)) do
                if not listed[vkey] then
                    local rows = K.without_own(g.id, g.rows, own)
                    local low = cheapest(rows)
                    local rec = G.record(vkey)
                    local ref = rec and D.reference(rec)
                    if low < math.huge and ref and P.net(ref, o.cut_pct) > low * need then
                        local plan = G.plan_for(vkey, rows, loose)
                        if plan and (plan.confidence or 0) < bar then out[#out + 1] = plan end
                    end
                end
            end
        end
        table.sort(out, function(a, b) return (a.expected or 0) > (b.expected or 0) end)
        while #out > 10 do out[#out] = nil end
        near_cache, near_at = out, t
        return out
    end

    -- --- buying: what holds it back --------------------------------------------------

    --- Units of each roll of Auto's gear you have posted -- its posts that
    --- trader.lua took in, up or sold and not settled -- by holding key. Your
    --- own auctions of the same roll are not Auto's pieces (the review, 1.2.0).
    local function away_by_roll()
        local out = {}
        local T = M.trader
        if not T then return out end
        for _, post in pairs(T.posts()) do
            if post.hand and not post.settled and not post.gone then
                local k = U.hkey(post.id, post.var or "")
                out[k] = (out[k] or 0) + (post.qty or 1)
            end
        end
        return out
    end

    --- Auto's gear not posted yet (in the bags or the mailbox): how many, and
    --- by roll { vkey, id, var, name, qty, cost }.
    function G.waiting()
        local away = away_by_roll()
        local n, list = 0, {}
        for k, h in pairs(L.holdings()) do
            if h.mode == "gear" and (h.qty or 0) > 0 then
                local left = math.floor((h.qty or 0) - (away[k] or 0) + 0.5)
                if left > 0 then
                    n = n + left
                    local id = h.id or U.unvkey(k)
                    list[#list + 1] = { vkey = U.vkey(id, h.var or ""), id = id, var = h.var or "",
                        name = h.name or G.name(id, h.var or ""), qty = left, cost = (h.cost or 0) / math.max(1, h.qty) }
                end
            end
        end
        return n, list
    end

    --- How many more pieces Auto may buy before GEAR_WAITING wait for you.
    function G.room()
        return GEAR_WAITING - (G.waiting())
    end

    --- May Auto buy gear now? False and why when it may not.
    function G.can_buy()
        if bid.stopped then return false, bid.stopped end
        -- (No scan-wide link bar: each purchase's own search must say every
        -- auction's roll -- 1.2.0's bar of 90% read held all gear buying back
        -- at the user's 89%.)
        local waiting = G.waiting()
        if waiting >= GEAR_WAITING then
            return false, string.format("%d piece(s) of gear Auto bought wait for you to post them (Gear tab)", waiting)
        end
        return true
    end

    --- How a bid on gear went: `answered` false when the game said nothing
    --- at all (no gold taken, no refusal).
    function G.note_bid(worked, answered)
        if worked then
            bid.worked, bid.failed = bid.worked + 1, 0
            return
        end
        if answered then return end
        bid.failed = bid.failed + 1
        if bid.worked == 0 and bid.failed >= BID_TRIES and not bid.stopped then
            bid.stopped = "the game answered none of Auto's bids on gear this session (place_bid); the gear deals stay "
                .. "listed for you to buy by hand"
            M.activity("Gear: buying stopped for this session -- " .. bid.stopped)
            M.toast("Gear: Auto's bids got no answer from the game; buy gear deals by hand (Gear tab)", "warning")
        end
    end

    function G.bid_state() return bid end

    --- Auto switched on again: its bids get two more tries.
    function G.reset_bids()
        if bid.stopped then M.activity("Gear: buying gear again (Auto switched on); two more tries at a bid") end
        bid.failed, bid.stopped = 0, nil
    end

    -- --- posting: what to post, at what price ------------------------------------------

    --- What a roll should be posted at: the buyout (undercut the cheapest
    --- other seller of the SAME roll by 1c; never under the vendor price,
    --- nor what Auto paid plus 10% after the cut; never over twice the usual
    --- price, and for Auto's gear never over the cautious price it was
    --- bought on), the 48-hour deposit, and why.
    function G.advise(vkey, cost, auto)
        local id, var = U.unvkey(vkey)
        local vk = U.vkey(id, var)
        local rec = G.record(vk)
        local market = rec and D.reference(rec)
        -- The cheapest other seller of this roll -- never from a look taken
        -- before Auto bought it: that look still shows the auction it bought.
        local rows, at = freshest(vk)
        local lowest = nil
        if rows then
            if not M.deals.bought_since(vk, at) then
                local low = cheapest(rows)
                if low < math.huge then lowest = low end
            end
        elseif rec and rec.n and not M.deals.bought_since(vk, rec.t) then
            lowest = rec.n
        end
        local ceiling = nil
        if auto and rec then
            local risk = D.risk(rec)
            ceiling = risk and P.safe_reference(risk.usual, risk.median, nil) or nil
        end
        local vendor = D.vendor(id) or 0
        -- No floor at what was paid: you post it, and the price the auction
        -- house gives is the price, under what Auto paid or not (below_cost
        -- says). Only a vendor paying more holds it back.
        local price, why = P.post_price({
            market = market, lowest = lowest, vendor = vendor, cost = nil,
            cut_pct = M.policy.cut(), margin_pct = 0,
            undercut = M.money("undercut"), ceiling_pct = M.cfg("post_ceiling", 200), ceiling = ceiling,
            below_floor = "hold",
        })
        local below_cost = (price and cost and P.net(price, M.policy.cut()) < cost) or nil
        return { price = price, why = why, market = market, lowest = lowest, vendor = vendor, below_cost = below_cost,
            deposit = M.policy.post_deposit(id, 1, POST_HOURS), per_day = rec and D.per_day(rec) or nil }
    end

    --- Every single item in the bags, one row per roll: { vkey, id, var,
    --- name, count, auto (how many are Auto's), cost (Auto's, each), advice,
    --- known (the roll was read) }. Auto's first, then the most valuable.
    --- Cached two seconds.
    function G.bag_list()
        local t = core.time()
        if bag_cache and t - bag_at < 2.0 then return bag_cache end
        local rows = U.try(ctx.inventory.bag_rows)
        local link_of = core.inventory and core.inventory.get_container_item_link
        local by, order = {}, {}
        for i = 1, #(type(rows) == "table" and rows or {}) do
            local row = rows[i]
            local id = tonumber(U.method(row.item, "get_item_id"))
            local info = id and D.info(id)
            if info and info.s and info.s <= 1 and info.b ~= BIND_ON_PICKUP and info.c ~= CLASS_QUEST then
                local var, vname = U.link_variant(U.try(link_of, row.bag_id, row.bag_slot))
                local known = var ~= nil
                if not known then
                    -- No link: Auto's roll of this item when it holds just one.
                    local only = nil
                    for _, h in pairs(L.holdings()) do
                        if h.mode == "gear" and h.id == id and (h.qty or 0) > 0 then
                            only = (only == nil) and (h.var or "") or false
                        end
                    end
                    if only then var, known = only, true else var = "" end
                end
                local k = U.vkey(id, var)
                local e = by[k]
                if not e then
                    e = { vkey = k, id = id, var = var, name = vname or G.name(k), count = 0, known = known }
                    by[k] = e
                    order[#order + 1] = e
                end
                e.count = e.count + (tonumber(row.stack_count) or 1)
            end
        end
        for _, e in ipairs(order) do
            local h = L.holding(e.id, e.var)
            local mine = (h and h.mode == "gear") and math.max(0, math.floor((h.qty or 0) + 0.5)) or 0
            local cost_sum = mine > 0 and (h.cost or 0) or 0
            -- A single item Auto bought for a vendor that the auction house pays
            -- more for is yours to post too (bags.lua says "hand"; 1.2.4: a bag
            -- bought for 4g would have gone to a vendor for 50s).
            local hv = L.holding(e.id)
            if hv and hv.mode == "vendor" and (hv.qty or 0) > 0 and M.bags then
                local adv = M.bags.advise(e.id, e.count)
                if adv.action == "hand" then
                    mine = mine + math.floor((hv.qty or 0) + 0.5)
                    cost_sum = cost_sum + (hv.cost or 0)
                end
            end
            e.auto = math.min(e.count, mine)
            e.cost = (mine > 0) and (cost_sum / mine) or nil
            e.advice = G.advise(e.vkey, e.cost, e.auto > 0 and h ~= nil and h.mode == "gear")
            local each = e.advice.price
            e.value = each and P.net(each, M.policy.cut()) * e.count or 0
        end
        table.sort(order, function(a, b)
            if (a.auto > 0) ~= (b.auto > 0) then return a.auto > 0 end
            return a.value > b.value
        end)
        bag_cache, bag_at = order, t
        return order
    end

    --- What the auction house would bring for one item's units in the bags,
    --- roll by roll, after the cut (the Vendor tab). Nil when a roll has no price.
    function G.bag_value(id)
        local total, any = 0, false
        for _, e in ipairs(G.bag_list()) do
            if e.id == id then
                if not e.advice.price then return nil end
                total, any = total + P.net(e.advice.price, M.policy.cut()) * e.count, true
            end
        end
        return any and total or nil
    end

    --- Auto's gear in the bags, to post: { name, price, count, ... } rows
    --- of bag_list with auto > 0.
    function G.to_post()
        local out = {}
        for _, e in ipairs(G.bag_list()) do
            if e.auto > 0 then out[#out + 1] = e end
        end
        return out
    end

    --- The roll of the item in one bag slot (nil when its link cannot be read).
    function G.slot_roll(bag, slot)
        local link_of = core.inventory and core.inventory.get_container_item_link
        return (U.link_variant(U.try(link_of, bag, slot)))
    end

    --- Does Auto hold this item as gear: this roll (`var`), or any roll (nil)?
    function G.holds_gear(id, var)
        for _, h in pairs(L.holdings()) do
            if h.mode == "gear" and h.id == id and (h.qty or 0) > 0 and (var == nil or (h.var or "") == var) then
                return true
            end
        end
        return false
    end

    function G.invalidate() bag_cache, near_cache = nil, nil end
    ctx.on("jambix.market.search", function() bag_cache = nil end)
    ctx.on("jambix.market.trade", function() bag_cache = nil end)

    --- "Bandit Cloak of the Monkey at 4s 99c, Raider's Belt at 6s".
    function G.post_line(list, most)
        local parts = {}
        for i = 1, math.min(#list, most or 4) do
            local e = list[i]
            parts[#parts + 1] = string.format("%s%s at %s", e.name, e.auto > 1 and (" x" .. e.auto) or "",
                e.advice.price and U.money(e.advice.price) or "(no price yet)")
        end
        if #list > (most or 4) then parts[#parts + 1] = string.format("and %d more", #list - (most or 4)) end
        return table.concat(parts, ", ")
    end

    -- --- your posts of Auto's gear --------------------------------------------------------
    --
    -- When you post a piece Auto bought, your auctions show it (trader.lua
    -- reads them every two minutes the auction house is open): it becomes a
    -- post of the lot, with its deposit, so its sale and the lot's profit
    -- count right. The deposit is the drop in gold when the auction was
    -- created, when that was seen; else Forever's 48-hour deposit.

    L.on_gold(function(g, before)
        if before and g < before then
            drops[#drops + 1] = { t = core.time(), copper = before - g }
            if #drops > 12 then table.remove(drops, 1) end
        end
    end)

    ctx.on("jcore.game_event.AUCTION_HOUSE_AUCTION_CREATED", function(args)
        local aid = args and tonumber(args[1])
        if aid then created[U.key(aid)] = { t = core.time(), at = U.now() } end
    end)

    --- When an auction was made (epoch), if this session saw it made.
    function G.created_at(auction_id)
        local c = created[U.key(auction_id)]
        return c and c.at or nil
    end

    --- The deposit a post of yours took: measured, or Forever's 48-hour one.
    function G.deposit_for(auction_id, id)
        local expected = M.policy.post_deposit(id, 1, POST_HOURS)
        local c = created[U.key(auction_id)]
        if c then
            for i = #drops, 1, -1 do
                local d = drops[i]
                if math.abs(d.t - c.t) <= 4 and d.copper >= 1 and d.copper <= expected * 1.2 + 100 then
                    return d.copper, true
                end
            end
        end
        return expected, false
    end

    -- --- pieces that left Auto's books -------------------------------------------------------
    --
    -- A piece of Auto's gear you keep, equip, bank or sell yourself never sells
    -- through the auction house: its lot would never end, it would count as
    -- waiting for you for good, and its cost as stock (the review, 1.2.0). So,
    -- with the auction house open (your auctions read in the last two
    -- minutes) and the mailbox read since Auto last bought the roll and since
    -- your post of it last left the auction house, a piece that is in none of
    -- the bags, your auctions, a sold post of it, or the mailbox's mails of
    -- that name is taken off Auto's stock as yours (ledger.release). An item
    -- whose link a bag slot did not give is left alone. A post of yours that
    -- left the auction house unsold, with no sale mail for it, is closed.

    local RECONCILE_EVERY = 10
    local OWNED_FRESH = 120
    local MAIL_SINCE = 60

    local function reconcile()
        local T = M.trader
        if not (T and A.is_open()) then return end
        local owned_at = T.owned_at()
        if not owned_at or core.time() - owned_at > OWNED_FRESH then return end
        local seen = L.inbox_seen()
        if not seen or not seen.at then return end
        local in_bags, unread = {}, {}
        for _, e in ipairs(G.bag_list()) do
            if e.known then
                local k = U.hkey(e.id, e.var)
                in_bags[k] = (in_bags[k] or 0) + e.count
            else
                unread[e.id] = true
            end
        end
        local listed = {}
        for _, a in ipairs(T.own_listings()) do
            if a.var ~= nil and a.item_id then
                local k = U.hkey(a.item_id, a.var)
                listed[k] = (listed[k] or 0) + (a.qty or 1)
            end
        end
        local named = seen.named or {}
        local sold_mail = {}
        for _, m in ipairs(seen.mails or {}) do
            local lk = tostring(m.name):lower()
            sold_mail[lk] = (sold_mail[lk] or 0) + 1
        end
        local sold_up, gone_at = {}, {}
        local changed = false
        for _, post in pairs(T.posts()) do
            if post.hand and not post.settled then
                local k = U.hkey(post.id, post.var or "")
                if post.gone then
                    gone_at[k] = math.max(gone_at[k] or 0, post.gone)
                    local lk = tostring(G.name(post.id, post.var or "")):lower()
                    if seen.at >= post.gone + MAIL_SINCE and (sold_mail[lk] or 0) == 0 then
                        post.settled, post.closed, changed = true, true, true
                    end
                elseif post.sold then
                    sold_up[k] = (sold_up[k] or 0) + (post.qty or 1)
                end
            end
        end
        if changed then T.save_posts() end
        for k, h in pairs(L.holdings()) do
            if h.mode == "gear" and (h.qty or 0) > 0 and h.id and not unread[h.id] then
                local since = math.max(h.last_buy or (type(h.lot) == "table" and h.lot.t) or 0, gone_at[k] or 0)
                if seen.at >= since + MAIL_SINCE then
                    local lk = tostring(h.name or G.name(h.id, h.var or "")):lower()
                    local here = (in_bags[k] or 0) + (listed[k] or 0) + (sold_up[k] or 0) + (named[lk] or 0)
                        + (sold_mail[lk] or 0)
                    local missing = math.floor((h.qty or 0) - here + 0.5)
                    if missing >= 1 then
                        L.release(h.id, missing, h.var or "", "not in the bags, the auction house or the mailbox")
                        bag_cache = nil
                    end
                end
            end
        end
    end

    ctx.every(RECONCILE_EVERY, function()
        local ok, err = pcall(reconcile)
        if not ok then M.log.fmt("error", "gear: checking Auto's pieces raised: %s", tostring(err)) end
    end)

    -- --- reminders ---------------------------------------------------------------------------

    -- At the auction house with Auto's gear in the bags: say what to post.
    ctx.on("jambix.market.ah_open", function() remind_at = core.time() + 6 end)

    ctx.tick(function()
        if not remind_at or core.time() < remind_at then return end
        remind_at = nil
        if not M.cfg("enabled", false) then return end
        local list = G.to_post()
        if #list == 0 then return end
        local line = "Post these yourself (Gear tab), 48 hours: " .. G.post_line(list)
        M.activity(line)
        M.toast(line, "info")
    end, { interval = 1.0 })

    --- One or two lines for the window: what gear is tracked, and what holds
    --- buying back. Returns lines { { text, tone } }.
    function G.status()
        local out = {}
        local meta = data.meta
        local n = meta.rolls or 0
        if not meta.last_scan then
            out[#out + 1] = { "Gear is priced by roll from the next full scan on (each roll's own sales take about an "
                .. "hour of scans to show).", "text_dim" }
        else
            local cov = meta.coverage
            out[#out + 1] = { string.format("%d roll(s) of gear tracked; the last scan read the roll of %s of %d single "
                .. "item auction(s).", n, cov and (math.floor(cov * 100) .. "%") or "none", meta.singles or 0),
                (cov and cov < LINK_COVERAGE) and "warning" or "text_dim" }
        end
        local ok, why = G.can_buy()
        if not ok then out[#out + 1] = { "Auto buys no more gear for now: " .. why .. ".", "warning" } end
        return out
    end

    function G.stats()
        local n = 0
        for _ in pairs(data.items) do n = n + 1 end
        return { rolls = n, file = file, coverage = data.meta.coverage, scans = data.meta.scans or 0,
            compared = data.meta.compared, bid = bid }
    end

    return G
end

-- Jambix Market / deals -- what is worth buying right now.
--
-- Two kinds, over the listings of the last full scan:
--
--   vendor  listed at least 15% under what a vendor pays. The vendor always
--           buys, so this is the one deal with no price risk -- but the goods
--           wait in the bags until you open a merchant, so: at most a fifth
--           of capital in vendor flips, four bag slots always left free, and
--           a full stack must make 2s (the user's bags, 2026-10-12: 3g 22s of
--           piles bought at 5% under, waiting to make about 40s). A vendor
--           flip that is big money on its own is held to the deal share only.
--   flip    listed well under the item's usual price, on an item that has
--           been seen to sell. Bought and posted again just under the next
--           seller (pricing.plan_flip), no higher than the CAUTIOUS price
--           (db.risk: the lowest of the usual price, recent days' median and
--           this scan's market value). Taken only when pricing.flip_confidence
--           -- the chance the price holds above break-even AND enough units
--           sell before the auction ends -- is at least the confidence set
--           (99% by default). The sales rate it is judged on is the
--           estimate's 95% lower bound (few sales seen, little believed), less
--           a quarter for cancelled listings counted as sales; a falling price
--           trend counts against it; and the item must have been seen in
--           three scans over an hour. When several sellers have gone cheap,
--           the price has moved (pricing.level_shift) and is believed.
--   gear    a flip of a SINGLE item (stack of one: every weapon and armor
--           piece, bags, recipes), planned by gear.lua per ROLL ("of the
--           Monkey" apart from "of the Owl") and on the list with the rest.
--           Forever's client never takes post_item, so Auto cannot post
--           these: it buys them, and you post them (the Gear tab). A single
--           item is never planned here as a flip (it would be bought and
--           then could not be posted).
--
-- Deals are bought in the order of what they earn a day on the gold they tie
-- up (pricing.return_rate); big money is marked (classify, below).
--
-- The scan is minutes old by the time anyone acts on it, so the trader
-- searches the item again and plans the purchase on those rows with the
-- same function (plan_for): a deal that has gone is never bought.

return function(M)
    local U, P, D, A = M.util, M.pricing, M.db, M.ah

    local K = {}

    local VENDOR_MARGIN = 15          -- under the vendor's price (was 5 before 1.2.5)
    local VENDOR_FREE_SLOTS = 4       -- bag slots a vendor flip never fills
    local MAX_DEALS = 150
    local CANCEL_TRUST = 0.75         -- of the sales rate's lower bound: some "sales" were cancels
    local DURATION_DAYS = { 0.5, 1, 2 }
    local CLASS_WEAPON, CLASS_ARMOR = 2, 4

    local list = {}
    local computed_at = nil
    local by_id = {}                  -- deal key (item id, or "id:roll" for gear) -> deal
    local bought_at = {}              -- deal key -> when Auto last bought it
    local classify                    -- big money (below)

    -- Market data older than this is not planned on: after a reload the saved
    -- scan may be hours or days old (the review, 1.0.0: yesterday's deals were
    -- projected and recorded as today's).
    local MAX_DATA_AGE = 1800

    --- The settings every plan is made with, read fresh.
    --- What every plan is made with: fixed rules (main.lua FIXED) and what
    --- policy.lua has worked out from your gold and the plugin's own trades.
    --- The deal list is planned on everything listed (max_spend unlimited),
    --- so it shows every opportunity; a purchase is planned again with
    --- size = true, which holds it to what policy.size allows.
    function K.options()
        local Pol = M.policy
        local cap = Pol.capital()
        return {
            cut_pct = Pol.cut(),
            min_profit = Pol.min_profit(cap),          -- the floor before a deal's own deposits (shown)
            min_spend = M.money("deal_min_spend"),
            max_spend = math.huge,
            min_margin_pct = M.cfg("deal_min_margin", 25),
            min_sold = M.cfg("deal_min_sold", 0),
            stock_days = M.cfg("deal_stock_days", 3),
            vendor = M.cfg("deal_vendor", true),
            flip = M.cfg("deal_flip", true),
            undercut = M.money("undercut"),
            min_confidence = Pol.bar(),
            duration = 2,
            capital = cap,
        }
    end

    --- Gear: one item id, many random suffixes, many prices.
    local function is_gear(item_id)
        local info = D.info(item_id)
        return info and (info.c == CLASS_WEAPON or info.c == CLASS_ARMOR) and (info.s or 1) <= 1
    end
    K.is_gear = is_gear

    --- A single item: one to an auction, so an "item" auction that only the
    --- auction house window can post on Forever (gear.lua). Known once the
    --- client has said the item's stack size.
    local function is_single(item_id)
        local info = D.info(item_id)
        return info ~= nil and info.s ~= nil and info.s <= 1
    end
    K.is_single = is_single

    --- The name a deal is shown by: the roll's, for gear.
    function K.name(d)
        return (d and d.name) or D.name(d and d.item_id)
    end

    --- The best purchase of one item from `rows`, or nil when none pays.
    ---@param item_id integer
    ---@param rows table[] listings (a search's rows, or a scan's)
    ---@param o? table K.options(), with `budget` to cap the spend
    ---@param whole? boolean item auctions (bought whole)
    ---@return table|nil plan
    function K.plan_for(item_id, rows, o, whole)
        o = o or K.options()
        local budget = math.min(o.budget or math.huge, o.max_spend)
        local rec = D.item(item_id)
        local best = nil

        if o.vendor then
            local v = D.vendor(item_id)
            if v and v > 0 then
                local info = D.info(item_id)
                local stack = (info and info.s) or 1
                local vo = { vendor = v, min_margin_pct = VENDOR_MARGIN, whole = whole, stack = stack, budget = budget }
                local plan = P.plan_vendor(rows, vo)
                -- Big money on its own (a certain +10g): held to the deal share
                -- alone, like any big deal. Anything less waits in the bags for
                -- a merchant for pennies: within a fifth of capital for vendor
                -- flips, and the bag room less four slots kept free.
                if plan.units > 0 and plan.profit > 0 and not P.is_big(plan.profit, o.capital.capital, 0) then
                    vo.budget = math.min(budget, M.policy.vendor_room(o.capital))
                    local free = tonumber(U.try(M.ctx.inventory.free_slots))
                    if free then vo.max_units = math.max(0, free - VENDOR_FREE_SLOTS) * stack end
                    plan = P.plan_vendor(rows, vo)
                end
                if plan.units > 0 and plan.profit > 0 then best = plan end
            end
        end

        local risk = rec and D.risk(rec)
        -- An item whose last lot lost money is not resold for a while (policy.cooling).
        -- And not before the client has told the item's vendor price and stack:
        -- Forever's deposit is 60% of the vendor price a unit, so an unknown
        -- one would plan the deposits at the 1s minimum (the review, 1.1.0).
        -- A single item is resold by gear.lua, roll by roll, for you to post:
        -- Auto cannot post it (1.2.0: before, a resale of a bag or a recipe
        -- would have been bought, failed to post, and gone to a vendor).
        local known = D.info(item_id)
        if o.flip and risk and risk.mature and risk.usual and (risk.per_day_low or 0) > 0 and known and known.ok
            and not is_single(item_id) and not M.policy.cooling(item_id) then
            local per_day = risk.per_day
            -- What Auto already holds of it (in the bags or posted) sells to the
            -- same buyers: a new lot is judged with it, not alone (the review,
            -- 1.0.0: lot after lot was each "99% sure" while together they
            -- were sure NOT to sell).
            local holding = M.ledger.holding(item_id)
            local held = holding and math.max(0, holding.qty or 0) or 0
            local room_units = math.floor(per_day * (o.stock_days or 3)) - held
            if per_day >= (o.min_sold or 0) and room_units >= 1 then
                local vendor = D.vendor(item_id) or 0
                local info = D.info(item_id)
                local rate = M.policy.deposit_rate(48)
                local plan = P.plan_flip(rows, {
                    held = held,
                    usual = risk.usual, median = risk.median, market = risk.market,
                    cut_pct = o.cut_pct, undercut = o.undercut,
                    min_margin_pct = o.min_margin_pct, budget = budget, whole = whole,
                    max_units = room_units,
                    cv = risk.cv, trend = risk.trend, sales_per_day = risk.per_day_low * CANCEL_TRUST, lot = risk.lot,
                    days = DURATION_DAYS[o.duration] or 1, vendor = vendor,
                    -- Forever's deposit, post by post: max(1s, rate x vendor x units).
                    deposit_unit = math.max(vendor * rate, M.policy.deposit_floor()),
                    post_fee = M.policy.deposit_floor(), deposit_rate = rate, stack = info and info.s or 1,
                    posts = M.policy.posts_max(), survive = P.FLOOR_FEES,
                    min_confidence = o.min_confidence or 0.99,
                })
                if plan.units > 0 and plan.profit > 0 and (not best or plan.profit > best.profit) then
                    best = plan
                end
            end
        end

        return K.finish(best, o, item_id, rec, risk, function(sized) return K.plan_for(item_id, rows, sized, whole) end)
    end

    --- What every plan ends with -- this file's and gear.lua's alike: the
    --- floor, the size Auto may spend on it, how long its gold is tied up,
    --- its expected profit, what that earns a day, and big money. `replan(o)`
    --- plans the same listings again within a smaller budget. Nil when the
    --- plan does not clear the floor or the policy gives it nothing.
    function K.finish(best, o, item_id, rec, risk, replan)
        if not best then return nil end
        -- Worth buying: its profit after one lost deposit a post clears
        -- max(5s, twice its deposits, 0.1% of capital) (policy.min_profit).
        local deposits = best.mode == "flip" and (best.deposits or best.fees or 0) or 0
        local least = M.policy.min_profit(o.capital, deposits)
        if best.profit < least then return nil end
        if best.cost < (o.min_spend or 0) then return nil end
        -- A purchase: no more than the policy gives a trade this sure, this
        -- rewarding and this risky. Planned again within that.
        if o.size then
            local allowed = M.policy.size(best, o.capital)
            if allowed < best.cost then
                if allowed <= 0 then return nil end
                local sized = {}
                for k, v in pairs(o) do sized[k] = v end
                sized.size, sized.budget = false, allowed
                return replan(sized)
            end
        end
        best.item_id = item_id
        best.key = best.key or item_id
        best.budget = math.min(o.budget or math.huge, o.max_spend or math.huge)
        best.per_day = rec and D.per_day(rec) or nil
        best.reference = best.mode == "flip" and best.cap or (rec and D.reference(rec)) or nil
        best.min_profit = least
        best.deposits = deposits
        -- How long its gold is tied up: a resale until it sells at the
        -- cautious rate, a vendor flip until a merchant (policy.vendor_days).
        local days
        if best.mode == "flip" then
            local rate = risk and risk.per_day_low or 0
            days = rate > 0 and math.max(0.25, best.units / rate) or 7
        else
            days = M.policy.vendor_days()
        end
        best.days = days
        -- Expected profit (with what failing costs), what it earns a day on
        -- the gold it ties up (the order deals are bought in), and big money.
        best.expected = P.expected(best, M.policy.loss_share(best))
        best.rate = P.return_rate(best.expected, best.cost, days)
        best.big = P.is_big(best.expected, o.capital.capital, deposits)
        best.score = best.rate
        return best
    end

    local function cheapest(listings)
        local low = math.huge
        for i = 1, #listings do
            local u = listings[i].unit
            if u and u > 0 and u < low then low = u end
        end
        return low
    end

    --- Rebuilds the list from the freshest look at each item: its last search
    --- when that is newer than the last full scan (quick scans search what
    --- matters every few minutes), else the full scan's listings. Items only
    --- a search has seen since the scan are planned too.
    function K.compute()
        local snap = D.previous()
        local searched = A.results()
        local fresh = {}
        local o = K.options()
        local need = 1 + (o.min_margin_pct or 0) / 100
        local function consider(id, listings, whole, from_search)
            -- Most items fail one comparison of the cheapest listing; only
            -- the rest are planned.
            local low = cheapest(listings)
            if low == math.huge then return end
            local rec = D.item(id)
            local v = o.vendor and D.vendor(id) or nil
            local ref = o.flip and rec and D.reference(rec) or nil
            local maybe = (v and v > low * (1 + VENDOR_MARGIN / 100))
                or (ref and P.net(ref, o.cut_pct) > low * need)
            if maybe then
                local plan = K.plan_for(id, listings, o, whole)
                if plan then
                    plan.checked = from_search or nil
                    fresh[#fresh + 1] = plan
                end
            end
        end
        local now = U.now()
        local snap_at = snap and snap.at or -math.huge
        local snap_fresh = snap and now - snap.at <= MAX_DATA_AGE
        local own = K.own_signatures()
        local function usable(id, at)
            return now - at <= MAX_DATA_AGE and at > (bought_at[id] or -math.huge)
        end
        if snap then
            for id, listings in pairs(snap.items) do
                local r = searched[id]
                -- A single item's search that found nothing is not believed
                -- over the scan (gear.lua's freshest says why).
                if r and r.kind == "none" and is_single(id) then r = nil end
                if r and (r.at or 0) > snap_at then
                    if usable(id, r.at or 0) then consider(id, r.rows, r.kind == "item", true) end
                elseif snap_fresh and usable(id, snap_at) then
                    local rec = D.item(id)
                    consider(id, K.without_own(id, listings, own), rec and rec.k == "item")
                end
            end
        end
        for id, r in pairs(searched) do
            if (r.at or 0) > snap_at and not (snap and snap.items[id]) and usable(id, r.at or 0) then
                consider(id, r.rows, r.kind == "item", true)
            end
        end
        -- Gear, roll by roll (gear.lua), on the same list and the same rules.
        if M.gear then
            local gear = M.gear.deals(o)
            for i = 1, #gear do fresh[#fresh + 1] = gear[i] end
        end
        table.sort(fresh, function(a, b) return a.score > b.score end)
        while #fresh > MAX_DEALS do fresh[#fresh] = nil end
        list = fresh
        local cap = o.capital
        local free_cap = M.policy.capital_free(cap)
        for i = 1, #list do classify(list[i], cap, free_cap) end
        by_id = {}
        for i = 1, #list do by_id[list[i].key or list[i].item_id] = list[i] end
        computed_at = U.now()
        -- What was on offer, for the ledger's "potential" column: the best
        -- any one look at the market showed today.
        if snap_fresh or next(fresh) then
            local total = 0
            for i = 1, #list do total = total + list[i].profit end
            M.ledger.note_potential(total, #list)
        end
        return list
    end

    --- Your own auctions, as item:unit:qty, so a full scan's copy of them is
    --- not planned as something to buy (a scan's rows do not say whose they
    --- are to us; a search's do).
    function K.own_signatures()
        local out = {}
        -- As they are: T.owned looks the cheapest seller up through these.
        local owned = M.trader and M.trader.own_listings()
        for i = 1, #(owned or {}) do
            local a = owned[i]
            if not a.sold and a.item_id then
                out[a.item_id .. ":" .. math.floor((a.unit or 0) + 0.5) .. ":" .. (a.qty or 0)] = true
            end
        end
        return out
    end

    function K.without_own(id, listings, own)
        if not next(own) then return listings end
        local out = {}
        for i = 1, #listings do
            local l = listings[i]
            if not own[id .. ":" .. math.floor((l.unit or 0) + 0.5) .. ":" .. (l.qty or 0)] then out[#out + 1] = l end
        end
        return out
    end

    --- The freshest listings of an item, and whether its auctions are bought
    --- whole: its last search when newer than the full scan, else the scan's
    --- (your own left out). Nil when neither is recent enough.
    function K.rows_for(id)
        local now = U.now()
        local r = A.results()[id]
        local snap = D.previous()
        if r and r.kind == "none" and is_single(id) then r = nil end
        if r and (not snap or (r.at or 0) > snap.at) then
            if now - (r.at or 0) <= MAX_DATA_AGE and (r.at or 0) > (bought_at[id] or -math.huge) then
                return r.rows, r.kind == "item"
            end
            return nil
        end
        if snap and snap.items[id] and now - snap.at <= MAX_DATA_AGE and snap.at > (bought_at[id] or -math.huge) then
            local rec = D.item(id)
            return K.without_own(id, snap.items[id], K.own_signatures()), rec and rec.k == "item"
        end
        return nil
    end

    --- The deal as Auto could actually buy it with `budget` (and its policy
    --- share): planned again within that, since a resale cannot be bought in
    --- part of a listing. Nil when nothing in it pays at that size.
    function K.affordable(d, budget, cap)
        cap = cap or M.policy.capital()
        if d.cost <= budget and d.cost <= M.policy.size(d, cap) + 1e-6 then return d end
        local o = K.options()
        o.capital = cap
        o.budget, o.size = budget, true
        if d.gear then
            local rows = M.gear and M.gear.rows_for(d.key)
            if not rows then return nil end
            return M.gear.plan_for(d.key, rows, o)
        end
        local rows, whole = K.rows_for(d.item_id)
        if not rows then return nil end
        return K.plan_for(d.item_id, rows, o, whole)
    end

    -- --- big money ----------------------------------------------------------------
    --
    -- Big money is judged on the deal as Auto may buy it now: planned again at
    -- what one deal may get (K.affordable at max_deal) and big when its
    -- expected profit clears max(20s, 5% of capital) and 4x its deposits. Big
    -- deals may use all of max_deal (the 70% stock line); any other deal only
    -- max_small (stock up to half of capital), so the last 20% is there when
    -- big money shows up. A deal that would be big with the money free but is
    -- not now carries what it needs (d.need), for the window.

    classify = function(d, cap, free_cap)
        -- Big as listed (everything on offer): only then can it be big with the money free.
        if d.listed_big == nil then d.listed_big = d.big or false end
        local listed_big = d.listed_big
        local now = K.affordable(d, cap.max_deal, cap)
        local now_big = now and now.big or false
        d.need, d.full_expected = nil, nil
        if not now_big and listed_big then
            -- With the money free: the listed deal itself (big as listed) when
            -- it fits, else the plan made for that money (the review, 1.1.0:
            -- read after d.big was overwritten, the listed deal never counted).
            local full = K.affordable(d, free_cap.max_deal, free_cap)
            local full_big = full and ((full == d and listed_big) or (full ~= d and full.big))
            if full_big then d.need, d.full_expected = full.cost, full.expected end
        end
        d.now, d.big = now, now_big
    end

    --- The best deal that would be big money with the money free, or nil.
    function K.big_waiting()
        local best = nil
        for i = 1, #list do
            local d = list[i]
            if d.need and (not best or (d.full_expected or 0) > (best.full_expected or 0)) then best = d end
        end
        return best
    end

    --- Big deals on the list now: how many, and their expected profit.
    function K.big()
        local n, e = 0, 0
        for i = 1, #list do
            local d = list[i]
            if d.big then n, e = n + 1, e + ((d.now and d.now.expected) or d.expected or 0) end
        end
        return n, e
    end

    --- Auto bought this item (or this roll of gear, by its key): its deal
    --- leaves the list, and nothing older than now -- the search or scan that
    --- still shows what was just bought -- is planned for it again.
    function K.bought(key)
        bought_at[key] = U.now()
        local had = by_id[key]
        if had then
            by_id[key] = nil
            for i = #list, 1, -1 do if list[i] == had then table.remove(list, i) end end
        end
    end

    --- Did Auto buy this (item id or gear key) at or after `at`? Data from
    --- before a purchase still shows what was bought.
    function K.bought_since(key, at)
        local b = bought_at[key]
        return b ~= nil and b >= (at or -math.huge)
    end

    --- Total profit the deal list holds right now.
    function K.potential()
        local total = 0
        for i = 1, #list do total = total + list[i].profit end
        return total
    end

    function K.list() return list end
    --- A deal by its key: the item id, or "id:roll" for gear.
    function K.get(key) return by_id[key] end
    function K.age() return computed_at and (U.now() - computed_at) or nil end

    --- A fresh search of an item replaces its deal, or removes it; for a
    --- single item, every roll's deal is replaced by what the search shows.
    function K.refresh_item(result)
        if not result or not result.item_id then return end
        local id = result.item_id
        local had = by_id[id]
        local plan = K.plan_for(id, result.rows, nil, result.kind == "item")
        local cap = M.policy.capital()
        local free_cap = M.policy.capital_free(cap)
        if plan then
            plan.checked = true
            classify(plan, cap, free_cap)
            by_id[id] = plan
            if had then
                for i = 1, #list do if list[i] == had then list[i] = plan end end
            else
                list[#list + 1] = plan
            end
        elseif had then
            by_id[id] = nil
            for i = #list, 1, -1 do if list[i] == had then table.remove(list, i) end end
        end
        -- (A search that found nothing of a single item leaves its gear deals
        -- as the scan showed them: gear.lua's freshest says why.)
        if M.gear and is_single(id) and result.kind == "item" then
            for i = #list, 1, -1 do
                local d = list[i]
                if d.gear and d.item_id == id then
                    by_id[d.key] = nil
                    table.remove(list, i)
                end
            end
            local fresh = M.gear.plans_from_search(result)
            for i = 1, #fresh do
                local g = fresh[i]
                g.checked = true
                classify(g, cap, free_cap)
                by_id[g.key] = g
                list[#list + 1] = g
            end
        end
        table.sort(list, function(a, b) return a.score > b.score end)
    end

    M.ctx.on("jambix.market.scan_done", function() K.compute() end)
    M.ctx.on("jambix.market.quick_done", function() K.compute() end)
    M.ctx.on("jambix.market.gear_done", function() K.compute() end)
    M.ctx.on("jambix.market.search", function(result) K.refresh_item(result) end)

    return K
end

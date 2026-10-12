-- Jambix Market / policy -- what to spend, when, and how sure to be, all
-- decided by the plugin.
--
-- The user (2026-10-07): "fix it so it can automatically Know what to spend
-- when to spend it and not relying on my Limits! at the end of the day this
-- complex equation should be 98% accurate in profit so remove all manual
-- sets make it all auto". So nothing here is a setting. Every number comes
-- from your gold, what Auto holds, and how its own trades have gone:
--
--   capital       your gold + what the stock Auto holds cost
--   reserve       always kept: 10% of capital (deposits, reposts, a cushion)
--   stock cap     at most 70% of capital tied up in unsold stock, so money is
--                 there for the next deal and for the deposits posting takes
--   deal size     quarter Kelly: the share of capital a trade deserves from
--                 how sure it is (p), what it makes if it works (W = profit /
--                 cost) and what it loses if it does not (L = cost less what
--                 a vendor or a market two standard deviations lower would
--                 still pay, over cost) -- f = p/L - (1-p)/W, a quarter of
--                 that, never more than half of capital nor more than is free.
--                 A sure trade with little to lose gets a lot; a thin or risky
--                 one gets little or nothing.
--   when          deals.lua ranks by expected profit per day it takes to sell
--                 (score = profit x sure / days); Auto buys from the top while
--                 money is free and waits when nothing clears the bar
--   least profit  max(50c, 0.05% of capital): a trade must be worth its
--                 searches, its post and its deposit
--   confidence    starts at 99% and tunes itself so that 98% of Auto's
--   bar           purchases make money once all sold, fees included (a lot,
--                 ledger.lua): the measured rate (with a 98% prior worth 50
--                 lots) under 98% raises it half a point (99.9% at most); over
--                 99% after ten or more lowers it a quarter point (95% at least)
--   AH cut        5% until a sale says otherwise, then learned from what an
--                 "Auction successful" mail paid against what the auction was
--                 posted at and the deposit it took
--   duration      48 hours, the longest the auction house allows (the user,
--                 2026-10-07: "post for longer time than whats currently
--                 posting for" -- it had been posting 12 hours for fast
--                 sellers). Deals are still judged on one day of selling, so
--                 the other day is margin for undercuts and reposts.
--   deposit       what one post takes, learned from the gold each post took
--                 (the median of the last twenty), per auction length; the
--                 user's first live posts, 2026-10-07, each took exactly 1s
--                 for 12 hours whatever the item. A length not seen yet is
--                 estimated from one that was, at retail's 1 : 2 : 4 for 12 :
--                 24 : 48 hours, so a longer post is never assumed cheaper. It comes back when the auction
--                 sells and is lost when it is cancelled or expires, so a
--                 resale is planned as losing one per stack it posts.
--
-- Persisted in scripts_data/jcore/jambix.market.policy.json.

return function(M)
    local U, P, D, L = M.util, M.pricing, M.db, M.ledger

    local Pol = {}

    local RESERVE_SHARE = 0.10
    local STOCK_SHARE = 0.70
    local SMALL_STOCK_SHARE = 0.50          -- smaller deals stop here: the rest is kept for big money
    local MAX_DEAL_SHARE = 0.50
    local KELLY_FRACTION = 0.25
    local TARGET = 0.98
    local PRIOR_TRADES = 50
    local BAR_START, BAR_MIN, BAR_MAX = 0.99, 0.95, 0.999
    local BAR_UP, BAR_DOWN = 0.005, 0.0025
    local CUT_DEFAULT = 5
    local CUT_MIN, CUT_MAX = 3, 8          -- a reading outside this matched the wrong post
    local DEPOSIT_DEFAULT = 100
    local DEPOSITS_KEPT = 20
    -- Forever's deposit: max(1s, rate x vendor price x units) a post. The
    -- rate is learned per auction length; 48 hours: 0.60 until a post says
    -- otherwise (Lion Meat 264c, Thick Spider's Silk 9s, Wool Cloth 3s 96c a
    -- 20-stack: all exactly 0.600).
    local DEPOSIT_MIN = 100
    local RATE_PRIOR = { [48] = 0.60 }
    local SHORT_KEPT, SHORT_MIN_N = 20, 5   -- the learned least profit
    local VDAYS_KEPT, VDAYS_MIN_N = 10, 3   -- how long vendor flips wait
    local VDAYS_DEFAULT, VDAYS_LO, VDAYS_HI = 1.0, 0.25, 7
    local COOL_ONE, COOL_TWO = 2 * 86400, 7 * 86400

    local store = M.ctx.store("policy")
    local data = store:all()
    data.bar = tonumber(data.bar) or BAR_START
    data.n = tonumber(data.n) or 0
    data.ok = tonumber(data.ok) or 0
    data.cut = tonumber(data.cut) or CUT_DEFAULT
    data.cuts = tonumber(data.cuts) or 0
    -- 1.1.0: the cut learned before could match a sale to an older post of
    -- the same item and quantity (the user's Lion Meat sale, read against its
    -- expired 12-hour post, gave 0.06% and pulled 4.97% down to 4.30%).
    -- Start again from 5%; the next sale teaches it with the matching fixed.
    if (tonumber(data.cut_v) or 1) < 2 then
        if data.cuts > 0 and math.abs(data.cut - CUT_DEFAULT) > 0.05 then
            M.activity(string.format("Auction house cut back to 5%% (was %.1f%%: a sale had been read against the wrong "
                .. "post); the next sale teaches it again", data.cut))
        end
        data.cut, data.cuts, data.cut_v = CUT_DEFAULT, 0, 2
        store:touch()
    end
    -- Deposits by auction hours. Those kept before the hours were (a flat
    -- list) were all 12-hour posts.
    data.depd = type(data.depd) == "table" and data.depd or {}
    if type(data.deps) == "table" and #data.deps > 0 and not data.depd["12"] then data.depd["12"] = data.deps end
    data.deps = nil
    data.rates = type(data.rates) == "table" and data.rates or {}     -- hours -> deposit / (vendor x qty)
    data.short = type(data.short) == "table" and data.short or {}     -- small lots: planned - made
    data.vdays = type(data.vdays) == "table" and data.vdays or {}     -- vendor lots: days to sell out
    data.cool = type(data.cool) == "table" and data.cool or {}        -- item -> times its lots lost

    --- The auction house's cut, in percent (learned from sales).
    function Pol.cut() return data.cut end

    local POST_HOURS = 48
    local HOURS_SCALE = { [12] = 1, [24] = 2, [48] = 4 }

    local function median(list)
        local n = #list
        if n == 0 then return nil end
        local s = {}
        for i = 1, n do s[i] = list[i] end
        table.sort(s)
        if n % 2 == 1 then return s[(n + 1) / 2] end
        return (s[n / 2] + s[n / 2 + 1]) / 2
    end

    --- What one post's deposit is, in copper, for an auction of `hours`
    --- (48 when not given): learned; see the top.
    function Pol.deposit(hours)
        hours = hours or POST_HOURS
        local seen = median(data.depd[tostring(hours)] or {})
        if seen then return seen end
        -- Not seen at this length: from the most expensive length seen, scaled.
        local best = nil
        for h, list in pairs(data.depd) do
            local m = median(list)
            local scale = HOURS_SCALE[tonumber(h)]
            if m and scale then
                local est = m / scale * (HOURS_SCALE[hours] or 4)
                if not best or est > best then best = est end
            end
        end
        return best or DEPOSIT_DEFAULT * (HOURS_SCALE[hours] or 4)
    end

    --- The deposit rate for a length: what a post took over its vendor value
    --- (the median of the last twenty that took more than the 1s minimum),
    --- 0.60 for 48 hours until one is seen.
    function Pol.deposit_rate(hours)
        hours = hours or POST_HOURS
        return median(data.rates[tostring(hours)] or {}) or RATE_PRIOR[hours]
    end

    --- The least a post takes (1s, seen on every post whose rate x vendor
    --- value was under it).
    function Pol.deposit_floor() return DEPOSIT_MIN end

    --- What posting `qty` of an item at once takes: max(1s, rate x vendor x qty).
    function Pol.post_deposit(item_id, qty, hours)
        local v = D.vendor(item_id) or 0
        local rate = Pol.deposit_rate(hours) or 0
        return math.max(DEPOSIT_MIN, rate * v * (qty or 1))
    end

    --- How sure a resale must be (0..1).
    function Pol.bar() return data.bar end

    --- The success rate measured on completed resales, and how many.
    function Pol.record() return data.ok, data.n end

    --- Your money as the plugin sees it, and what it may spend now.
    -- Vendor flips wait in the bags for a merchant and earn pennies a unit: at
    -- most a fifth of capital in them (the user's bags, 2026-10-12: 3g 22s of
    -- Murloc Eyes, Boar Intestines and oils waiting to make about 40s).
    local VENDOR_SHARE = 0.20

    function Pol.capital()
        local gold = L.gold_now() or 0
        local invested, vendor_invested = 0, 0
        for _, h in pairs(L.holdings()) do
            invested = invested + (h.cost or 0)
            if h.mode == "vendor" then vendor_invested = vendor_invested + (h.cost or 0) end
        end
        local capital = gold + invested
        local reserve = capital * RESERVE_SHARE
        local free = math.max(0, gold - reserve)
        local stock_room = math.max(0, capital * STOCK_SHARE - invested)
        local max_deal = math.max(0, math.min(free, stock_room, capital * MAX_DEAL_SHARE))
        -- A deal that is not big money may only fill stock to half of capital:
        -- the last 20% of the stock room is kept for big money.
        local small_room = math.max(0, capital * SMALL_STOCK_SHARE - invested)
        local max_small = math.max(0, math.min(max_deal, small_room))
        local why = nil
        if max_deal <= 0 then
            if gold <= reserve then why = "your gold is at the 10% it always keeps"
            elseif stock_room <= 0 then why = "70% of your money is already in stock waiting to sell"
            else why = "no money free" end
        end
        return { gold = gold, invested = invested, capital = capital, reserve = reserve, free = free,
            stock_room = stock_room, max_deal = max_deal, small_room = small_room, max_small = max_small, why = why,
            vendor_invested = vendor_invested, vendor_room = math.max(0, capital * VENDOR_SHARE - vendor_invested) }
    end

    --- The most that may go into vendor flips now: a fifth of capital, less
    --- what waits for a merchant already.
    function Pol.vendor_room(cap)
        cap = cap or Pol.capital()
        if cap.vendor_room then return cap.vendor_room end
        return math.max(0, (cap.capital or 0) * VENDOR_SHARE - (cap.vendor_invested or 0))
    end

    --- The same capital with nothing tied up: what one deal could get once
    --- the stock has sold (a big deal waiting for money is judged on it).
    function Pol.capital_free(cap)
        cap = cap or Pol.capital()
        local C = cap.capital
        local max_deal = C * math.min(MAX_DEAL_SHARE, STOCK_SHARE, 1 - RESERVE_SHARE)
        return { gold = C, invested = 0, capital = C, reserve = C * RESERVE_SHARE, free = C * (1 - RESERVE_SHARE),
            stock_room = C * STOCK_SHARE, max_deal = max_deal, small_room = C * SMALL_STOCK_SHARE,
            max_small = math.min(max_deal, C * SMALL_STOCK_SHARE) }
    end

    --- The least-profit floor's fixed part: 5s, raised to the 90th percentile
    --- of how far the last twenty small resale lots fell short of their
    --- plan (once five have), never above half the big-money line.
    function Pol.floor_abs(cap)
        cap = cap or Pol.capital()
        local s = data.short
        if #s < SHORT_MIN_N then return P.FLOOR_ABS end
        local sorted = {}
        for i = 1, #s do sorted[i] = s[i] end
        table.sort(sorted)
        local p90 = sorted[math.ceil(0.9 * #sorted)]
        return math.min(math.max(P.FLOOR_ABS, p90), P.big_line(cap.capital) / 2)
    end

    --- The least profit a deal must plan (after one lost deposit a post):
    --- max(5s or what small lots have missed by, twice its deposits, 0.1% of capital).
    function Pol.min_profit(cap, deposits)
        cap = cap or Pol.capital()
        return P.worth_floor(cap.capital, deposits or 0, Pol.floor_abs(cap))
    end

    --- Expected profit at or above which a deal is big money: max(20s, 5% of capital).
    function Pol.big_line(cap)
        cap = cap or Pol.capital()
        return P.big_line(cap.capital)
    end

    --- How long a vendor flip's money waits for a merchant, in days: the
    --- median of the last ten vendor lots (first purchase to the last unit
    --- sold), 1 until three have sold out, never less than the oldest one
    --- still waiting; 0.25 to 7.
    function Pol.vendor_days()
        local d = #data.vdays >= VDAYS_MIN_N and median(data.vdays) or VDAYS_DEFAULT
        local now = U.now()
        for _, h in pairs(L.holdings()) do
            if h.mode == "vendor" and (h.qty or 0) > 0 and type(h.lot) == "table" and h.lot.t then
                d = math.max(d, (now - h.lot.t) / 86400)
            end
        end
        return U.clamp(d, VDAYS_LO, VDAYS_HI)
    end

    --- Seconds an item is still not bought again after its lots lost money:
    --- 2 days after one, 7 days after two within 7 days. Nil when free.
    function Pol.cooling(item_id)
        local list = data.cool[U.key(item_id)]
        if not list or #list == 0 then return nil end
        local now, last = U.now(), list[#list]
        local hold = COOL_ONE
        if #list >= 2 and last - list[#list - 1] <= COOL_TWO then hold = COOL_TWO end
        local left = last + hold - now
        return left > 0 and left or nil
    end

    --- The share of a plan's cost lost if it fails: what is left after a
    --- vendor, or a market two standard deviations lower, still pays.
    function Pol.loss_share(plan)
        if not plan or (plan.units or 0) <= 0 or (plan.cost or 0) <= 0 then return 1 end
        if plan.mode == "vendor" then return 0 end
        local unit_cost = plan.cost / plan.units
        local risk = plan.risk or {}
        local cv = risk.cv or P.PRIOR_CV
        local salvage = math.max(risk.vendor or 0, P.net(plan.resale or 0, data.cut) * math.exp(-2 * cv))
        return U.clamp(1 - salvage / unit_cost, 0.02, 1)
    end

    --- The most to spend on a plan (quarter Kelly of capital, within what is
    --- free and the stock cap). The confidence is taken two points lower than
    --- the model says before Kelly sees it: an estimated chance carries error,
    --- and a thin edge -- 95% sure of 3%, with 44% to lose -- that is really
    --- 93% sure loses money; at 93% it gets nothing, where a sure trade with
    --- a wide margin still gets its full share.
    local P_SAFETY = 0.02

    function Pol.size(plan, cap)
        cap = cap or Pol.capital()
        if not plan or (plan.units or 0) <= 0 or (plan.cost or 0) <= 0 then return 0 end
        local p = plan.mode == "vendor" and 1 or math.max(0, (plan.confidence or 0) - P_SAFETY)
        local f = P.kelly(p, (plan.profit or 0) / plan.cost, Pol.loss_share(plan))
        local share = math.min(MAX_DEAL_SHARE, KELLY_FRACTION * f)
        return math.max(0, math.min(cap.max_deal, cap.capital * share))
    end

    --- Auction length to post for: 1 = 12 h, 2 = 24 h, 3 = 48 h. Always the
    --- longest (see the top).
    function Pol.duration()
        return 3
    end

    --- The hours a post lasts.
    function Pol.post_hours() return POST_HOURS end

    --- How many 48-hour posts a resale may be judged over: two once ten of
    --- Auto's purchases have sold out and at least 98% of them made money,
    --- one before that and whenever the rate falls under 98%.
    local POSTS_MAX, POSTS_AFTER = 2, 10
    function Pol.posts_max()
        if data.n >= POSTS_AFTER and data.ok / data.n >= TARGET then return POSTS_MAX end
        return 1
    end

    -- --- learning from its own trades -------------------------------------------

    -- A sale mail pays price x qty less the cut, plus the deposit back. Of the
    -- posts of the same item and quantity not read yet, the sale is the one
    -- whose reading is nearest the cut known so far, and only a reading of
    -- 3% to 8% is believed (the user's Lion Meat sale against its expired
    -- 12-hour post read 0.06%).
    local function learn_cut(row)
        if not M.trader or not row.id or (row.qty or 0) <= 0 then return end
        local best, cut = nil, nil
        for _, post in pairs(M.trader.posts()) do
            if post.id == row.id and post.qty == row.qty and not post.cut_seen and post.unit and post.unit > 0 then
                local c = (1 - (row.copper - (post.deposit or 0)) / (post.unit * post.qty)) * 100
                if c >= CUT_MIN and c <= CUT_MAX and (not best or math.abs(c - data.cut) < math.abs(cut - data.cut)) then
                    best, cut = post, c
                end
            end
        end
        if not best then return end
        best.cut_seen = true
        if data.cuts == 0 then data.cut = cut else data.cut = data.cut * 0.7 + cut * 0.3 end
        data.cuts = data.cuts + 1
        M.activity(string.format("Learned the auction house cut: %.1f%% (from %d sale%s)", data.cut, data.cuts,
            data.cuts == 1 and "" or "s"))
    end

    -- One purchase lot finished (ledger.lua: every unit sold, its deposits and
    -- cancels counted): did it make money?
    local function learn_success(lot)
        data.n = data.n + 1
        if lot.ok then data.ok = data.ok + 1 end
        local rate = (data.ok + TARGET * PRIOR_TRADES) / (data.n + PRIOR_TRADES)
        local was = data.bar
        if rate < TARGET then
            data.bar = math.min(BAR_MAX, data.bar + BAR_UP)
        elseif rate > 0.99 and data.n >= 10 then
            data.bar = math.max(BAR_MIN, data.bar - BAR_DOWN)
        end
        if data.bar ~= was then
            M.activity(string.format("Confidence bar %s to %.2f%% (%d of %d purchases made money)",
                data.bar > was and "raised" or "lowered", data.bar * 100, data.ok, data.n))
        end
    end

    local function push(list, v, keep)
        list[#list + 1] = v
        while #list > keep do table.remove(list, 1) end
    end

    M.ctx.on("jambix.market.trade", function(row)
        if type(row) ~= "table" then return end
        -- A deposit only estimated (your post of gear: gear.lua) teaches nothing.
        if row.est then return end
        if row.kind == "fee" and row.note == "deposit" and (row.copper or 0) > 0 then
            local k = tostring(row.hours or 12)
            local list = data.depd[k] or {}
            push(list, row.copper, DEPOSITS_KEPT)
            data.depd[k] = list
            store:touch()
            return
        end
        -- A post above the 1s minimum says what the rate is: deposit / (vendor x qty).
        if row.kind == "post" and (row.deposit or 0) > DEPOSIT_MIN + 1 and (row.qty or 0) > 0 then
            local v = D.vendor(row.id) or 0
            if v > 0 then
                local k = tostring(row.hours or POST_HOURS)
                local list = data.rates[k] or {}
                push(list, row.deposit / (v * row.qty), DEPOSITS_KEPT)
                data.rates[k] = list
                store:touch()
            end
            return
        end
        if row.kind ~= "sell" then return end
        if row.note ~= "vendor" then learn_cut(row) end
        store:touch()
    end)

    M.ctx.on("jambix.market.lot_done", function(lot)
        if type(lot) ~= "table" then return end
        learn_success(lot)
        -- How far a small resale lot fell short of its plan (after deposits);
        -- gear you posted is a resale too.
        if (lot.mode == "flip" or lot.mode == "gear") and not lot.big and type(lot.planned) == "number" then
            push(data.short, math.max(0, lot.planned - (lot.made or 0)), SHORT_KEPT)
        end
        if lot.mode == "vendor" and type(lot.days) == "number" then
            push(data.vdays, lot.days, VDAYS_KEPT)
        end
        if lot.id and (lot.made or 0) <= 0 then
            local k = U.key(lot.id)
            local list = data.cool[k] or {}
            push(list, lot.t or U.now(), 2)
            data.cool[k] = list
        end
        store:touch()
    end)

    function Pol.reset_learning()
        data.bar, data.n, data.ok, data.cut, data.cuts, data.depd = BAR_START, 0, 0, CUT_DEFAULT, 0, {}
        data.rates, data.short, data.vdays, data.cool = {}, {}, {}, {}
        store:touch()
    end

    return Pol
end

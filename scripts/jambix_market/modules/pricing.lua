-- Jambix Market / pricing -- the arithmetic, with nothing in it that touches
-- the game. Every number the window shows comes out of one of these
-- functions, so they are kept pure: tools/jtest/tests/market_test.lua checks
-- them offline.
--
-- Prices are copper throughout. A "listing" here is one auction reduced to
-- what the maths needs: { unit = copper per item, qty = items, owner = name,
-- band = time-left band (1 short .. 4 very long) }.

local P = {}

local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

-- --- market value ----------------------------------------------------------
--
-- The cheapest listing is a bad price to believe: one undercutter, or one
-- mistake, moves it. The average of everything is worse: a handful of
-- absurd buyouts drag it up. What a buyer actually pays is the cheap end
-- of the market, so (TSM's DBMarket recipe, simplified):
--   * walk the units cheapest first;
--   * always take the cheapest 15% of them;
--   * keep going up to 30% while each price is within 20% of the last;
--   * drop anything more than 1.5 standard deviations above that set's mean;
--   * the unit-weighted average of what is left is the market value.

local FLOOR_SHARE = 0.15
local CEIL_SHARE = 0.30
local STEP_LIMIT = 1.20
local SIGMA = 1.5

--- Market value of one item's listings.
---@param listings table[] { unit, qty }; order does not matter, not modified
---@return number|nil market copper per item, nil when nothing has a buyout
---@return number|nil lowest the cheapest unit price
---@return integer qty units with a buyout
function P.market_value(listings)
    local rows, total = {}, 0
    for i = 1, #listings do
        local l = listings[i]
        local unit, qty = tonumber(l.unit), tonumber(l.qty) or 1
        if unit and unit > 0 and qty > 0 then
            rows[#rows + 1] = { unit = unit, qty = qty }
            total = total + qty
        end
    end
    if total == 0 then return nil, nil, 0 end
    table.sort(rows, function(a, b) return a.unit < b.unit end)

    local floor_units = max(1, math.ceil(FLOOR_SHARE * total))
    local ceil_units = max(1, math.ceil(CEIL_SHARE * total))
    local taken, sum_units, last = {}, 0, nil
    for i = 1, #rows do
        local r = rows[i]
        if sum_units >= floor_units then
            if sum_units >= ceil_units then break end
            if last and r.unit > last * STEP_LIMIT then break end
        end
        -- Take only as much of a big stack as the window still has room for,
        -- so one 200-stack does not decide the whole average by itself.
        local q = min(r.qty, max(1, ceil_units - sum_units))
        taken[#taken + 1] = { unit = r.unit, qty = q }
        sum_units = sum_units + q
        last = r.unit
    end

    local mean, n = 0, 0
    for i = 1, #taken do
        mean = mean + taken[i].unit * taken[i].qty
        n = n + taken[i].qty
    end
    mean = mean / n
    local var = 0
    for i = 1, #taken do
        local d = taken[i].unit - mean
        var = var + d * d * taken[i].qty
    end
    local sd = sqrt(var / n)

    local kept, kept_n = 0, 0
    for i = 1, #taken do
        local t = taken[i]
        if sd == 0 or t.unit <= mean + SIGMA * sd then
            kept = kept + t.unit * t.qty
            kept_n = kept_n + t.qty
        end
    end
    local market = kept_n > 0 and (kept / kept_n) or mean
    return floor(market + 0.5), rows[1].unit, total
end

-- --- history -----------------------------------------------------------------

--- An exponential moving average that does not care how irregular the
--- samples are: `half_life` seconds after a sample, it counts half as much.
---@param old number|nil
---@param new number
---@param elapsed number seconds since `old` was last moved
---@param half_life number seconds
---@return number
function P.blend(old, new, elapsed, half_life)
    if not old or old <= 0 then return new end
    if elapsed <= 0 then return old end
    local keep = 0.5 ^ (elapsed / half_life)
    return old * keep + new * (1 - keep)
end

--- How much an accumulator still counts after `elapsed` seconds.
---@param elapsed number
---@param half_life number
---@return number
function P.decay(elapsed, half_life)
    if elapsed <= 0 then return 1 end
    return 0.5 ^ (elapsed / half_life)
end

-- --- sales, from two scans -----------------------------------------------------
--
-- The auction house never says what sold. What it does say, scan to scan,
-- is what is no longer there. An auction leaves for one of three reasons:
-- it was bought, its time ran out, or its seller cancelled it. Time can be
-- ruled out: each listing carries a time-left band, and a listing that had
-- at least two hours left cannot have expired in the twenty minutes since
-- the last scan. Cancellations cannot be told from sales and are counted as
-- sales, which is why every rate the window shows says "estimated".
--
-- Listings are grouped by seller and unit price rather than matched one by
-- one, because a partial buy of a commodity stack changes its quantity
-- while leaving the seller and price alone.
--
-- REPRICING IS NOT A SALE (1.0.0, the formula review). A seller who takes
-- 20 down at 1g and puts 20 up at 95s has sold nothing, but the 1g group
-- left with time to spare. So per seller, what left at one price is netted
-- against what that seller added at another, the provable sales first. A
-- seller the scan does not name ("") is one seller: across anonymous
-- listings that nets new supply against sales too, which can only count
-- fewer sales, never more. (On Forever every other seller is "": the
-- user's scans, 2026-10-07, name only the user's own character.)
--
-- SALES, NOT UNITS. One buyer taking 53 fish is one sale, not 53: counted
-- in units, a single purchase reads as a busy market and the chance of
-- selling looks far surer than it is (the user, 2026-10-07: "did it make
-- sure that these are actually selling?"). So each price group that lost
-- units counts as one sale, and how sure a resale is comes from the number
-- of sales, with the units a sale takes on average (pricing.flip_confidence).

--- The least time (seconds) a listing in each band still had left.
--- Bands 1..4: under 30 min, 30 min - 2 h, 2 h - 12 h (classic: 8 h), over
--- 12 h (classic: 8 h - 24 h). The classic figures are the smaller, so they
--- are the ones used: a wrong guess then counts fewer sales, never more.
P.BAND_MIN_SECONDS = { 0, 1800, 7200, 28800 }

--- Group key for a listing: who sold it and at what unit price.
local function group_key(l)
    return tostring(l.owner or "") .. "\1" .. tostring(floor(tonumber(l.unit) or 0))
end

--- What sold between two scans of one item.
---@param before table[] the listings in the earlier scan
---@param after table[] the listings in the later scan
---@param elapsed number seconds between the two scans
---@return number sold units that left and cannot have expired
---@return number unclear units that left and might have expired
---@return number added units that appeared (repricing not included)
---@return number repriced units a seller moved from one price to another
---@return number sales how many purchases the sold units came from: each
---   price group that lost units with time to spare is one (at most one per
---   unit sold)
function P.sales_between(before, after, elapsed)
    local groups = {}
    local function group(l)
        local k = group_key(l)
        local g = groups[k]
        if not g then
            g = { owner = tostring(l.owner or ""), before = 0, after = 0, expirable = 0 }
            groups[k] = g
        end
        return g
    end
    for i = 1, #before do
        local l = before[i]
        local g = group(l)
        local qty = tonumber(l.qty) or 1
        g.before = g.before + qty
        local band = tonumber(l.band) or 1
        local least = P.BAND_MIN_SECONDS[band] or 0
        if least <= elapsed then g.expirable = g.expirable + qty end
    end
    for i = 1, #after do
        local g = group(after[i])
        g.after = g.after + (tonumber(after[i].qty) or 1)
    end
    local sellers = {}
    for _, g in pairs(groups) do
        local s = sellers[g.owner]
        if not s then
            s = { gone_safe = 0, gone_maybe = 0, added = 0, groups = 0 }
            sellers[g.owner] = s
        end
        local gone = g.before - g.after
        if gone > 0 then
            local safe = max(0, gone - g.expirable)
            s.gone_safe = s.gone_safe + safe
            if safe > 0 then s.groups = s.groups + 1 end
            s.gone_maybe = s.gone_maybe + (gone - safe)
        elseif gone < 0 then
            s.added = s.added - gone
        end
    end
    local sold, unclear, added, repriced, sales = 0, 0, 0, 0, 0
    for _, s in pairs(sellers) do
        local re = min(s.gone_safe + s.gone_maybe, s.added)
        local re_safe = min(re, s.gone_safe)
        local sold_here = s.gone_safe - re_safe
        sold = sold + sold_here
        unclear = unclear + (s.gone_maybe - (re - re_safe))
        added = added + (s.added - re)
        repriced = repriced + re
        if sold_here > 0 then
            -- The groups that sold, in the share of their units that netting left.
            sales = sales + min(sold_here, max(1, floor(s.groups * sold_here / s.gone_safe + 0.5)))
        end
    end
    return sold, unclear, added, repriced, sales
end

--- Of `sold` units from `sales` purchases, the purchases left once `mine`
--- of the units are taken off (the plugin's own buying is not demand).
function P.sales_without(sold, sales, mine)
    if (mine or 0) <= 0 or sold <= 0 then return sold, sales end
    local left = max(0, sold - mine)
    if left <= 0 then return 0, 0 end
    return left, min(left, max(1, floor(sales * left / sold + 0.5)))
end

--- How many purchases `units` take when purchases come `lot` units at a time.
function P.sales_needed(units, lot)
    lot = max(1, lot or 1)
    return math.ceil(units / lot - 1e-9)
end

-- --- what a sale is worth to you -------------------------------------------------

--- Copper in hand after the auction house takes its cut.
---@param price number
---@param cut_pct number e.g. 5
---@return number
function P.net(price, cut_pct)
    return price * (1 - (cut_pct or 5) / 100)
end

--- The price to post at, and why. The same three numbers TSM's Auctioning
--- uses, and the same decision:
---   * floor: never sell below it -- the vendor price after the cut, or what
---     you paid plus the margin you asked for, whichever is higher;
---   * normal: the market value, posted when nobody is selling;
---   * ceiling: never post above it, however thin the market looks.
--- With competition between floor and ceiling, undercut it.
---@param o table { market, lowest, vendor, cost, cut_pct, margin_pct, undercut, ceiling_pct, below_floor }
---@return number|nil price copper per item, nil when it should not be posted
---@return string reason
function P.post_price(o)
    local cut = o.cut_pct or 5
    local market = o.market
    local vendor = o.vendor or 0
    if not market or market <= 0 then
        if o.lowest and o.lowest > 0 then market = o.lowest else
            return nil, "no price data"
        end
    end
    -- What you must get per item for the sale to beat the vendor / your cost.
    local cost_floor = (o.cost or 0) * (1 + (o.margin_pct or 0) / 100)
    local floor_net = max(vendor, cost_floor)
    local vendor_floor = vendor > 0 and vendor >= cost_floor
    local floor_price = floor_net / (1 - cut / 100)
    local ceiling = market * ((o.ceiling_pct or 200) / 100)
    if o.ceiling and o.ceiling > 0 then ceiling = min(ceiling, o.ceiling) end
    local undercut = o.undercut or 1

    local lowest = o.lowest
    local price, why
    if not lowest or lowest <= 0 then
        -- No competition still never posts above the ceiling (stock bought to
        -- resell is capped at the price it was judged at).
        price, why = min(market, ceiling), "no competition: market value"
    elseif lowest > ceiling then
        price, why = ceiling, "cheapest is above the ceiling"
    else
        price, why = lowest - undercut, "undercut the cheapest"
    end
    -- Under the floor, the price is never just raised to it: an item whose
    -- market is far below its vendor price would sit on the auction house
    -- at the floor and never sell.
    if price < floor_price then
        if vendor_floor then
            -- The floor is the vendor's price: the vendor is the better sale.
            return nil, "worth more at a vendor"
        elseif o.below_floor == "floor" then
            price, why = floor_price, "the market is below your floor: posting at the floor"
        else
            return nil, "the market is below your floor"
        end
    end
    return floor(price + 0.5), why
end

-- --- risk: how sure a resale is ----------------------------------------------------
--
-- The user (2026-10-07) asked for profit "at a 99% success rate or as close
-- as possible". A vendor flip is sure by construction: the vendor's price
-- does not move. A resale is not, and fails in exactly two ways:
--
--   the price falls  by the time it is up, the market is below what was paid
--                    (after the cut). Modelled as a lognormal around the
--                    planned price with the item's own volatility, scaled to
--                    the auction's length.
--   it does not sell nobody buys enough of it before the auction ends.
--                    Modelled as Poisson buyers at a deliberately cautious
--                    rate (deals.lua takes 60% of the estimate, because a
--                    cancelled listing counts as a sale).
--
-- The chance of a profit is the product. A vendor that pays more than the
-- units cost plus the deposit is a floor under the trade: no loss either
-- way, so the chance is 1. Deals are taken only above the confidence the
-- user sets (99% by default); trader.lua checks it again at the server's
-- quote, and the ledger measures how often it came true.

--- The standard normal CDF (Abramowitz & Stegun 26.2.17; error under 1e-7).
function P.phi(z)
    local t = 1 / (1 + 0.2316419 * math.abs(z))
    local d = 0.3989422804 * math.exp(-z * z / 2)
    local q = d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937
        + t * (-1.821255978 + t * 1.330274429))))
    if z >= 0 then return 1 - q end
    return q
end

--- P(N >= k) for N ~ Poisson(lambda): the chance at least k units sell when
--- lambda are expected to.
function P.poisson_at_least(k, lambda)
    if k <= 0 then return 1 end
    if not lambda or lambda <= 0 then return 0 end
    if lambda > 60 then
        -- Normal approximation, with the continuity correction.
        return P.phi((lambda - (k - 0.5)) / math.sqrt(lambda))
    end
    local term = math.exp(-lambda)
    local cdf = term
    for i = 1, k - 1 do
        term = term * lambda / i
        cdf = cdf + term
        if term < 1e-15 and i > lambda then break end
    end
    return max(0, min(1, 1 - cdf))
end

P.PRIOR_CV = 0.15        -- an item's price moves this much a day until it shows otherwise
P.MIN_CV = 0.03

--- How much an item's price moves in a day: the coefficient of variation of
--- its daily market values, shrunk toward PRIOR_CV while there are few days
--- (three days' weight), and never less than how far this scan sits from the
--- usual price.
---@param values number[] daily market values
---@param gap? number |market now / usual price - 1|
function P.volatility(values, gap)
    local n = #values
    local cv_seen = 0
    if n >= 2 then
        local mean = 0
        for i = 1, n do mean = mean + values[i] end
        mean = mean / n
        local var = 0
        for i = 1, n do
            local d = values[i] - mean
            var = var + d * d
        end
        if mean > 0 then cv_seen = sqrt(var / (n - 1)) / mean end
    end
    -- Weighted by its degrees of freedom: one day says nothing about how a
    -- price moves (the review, 1.0.0: weighting it by n made one day of
    -- history read as 11.25%, under the 15% assumed without any).
    local w = n >= 2 and (n - 1) or 0
    local cv = (w * cv_seen + 3 * P.PRIOR_CV) / (w + 3)
    if gap and gap > cv then cv = gap end
    return max(P.MIN_CV, cv)
end

--- Which way an item's price has been going: the least-squares slope of the
--- log of its daily market values, per day (0 with fewer than three days).
--- -0.05 is a price falling about 5% a day.
function P.trend(values)
    local n = #values
    if n < 3 then return 0 end
    local sx, sy, sxx, sxy = 0, 0, 0, 0
    for i = 1, n do
        local y = math.log(max(1, values[i]))
        sx, sy, sxx, sxy = sx + i, sy + y, sxx + i * i, sxy + i * y
    end
    local d = n * sxx - sx * sx
    if d == 0 then return 0 end
    return (n * sxy - sx * sy) / d
end

--- A cautious sales rate: the lower bound (z standard errors under) of a
--- Poisson rate seen as `count` units in `seconds`, per day. Two sales seen
--- say almost nothing; two hundred say a lot, and the bound says how much.
function P.rate_lower(count, seconds, z)
    if not count or not seconds or seconds <= 0 or count <= 0 then return 0 end
    local low = count - (z or 1.645) * sqrt(count)
    if low <= 0 then return 0 end
    return low / seconds * 86400
end

--- The price a resale is planned against: the LOWEST of the usual price,
--- the median of recent days and this scan's market value. A falling market
--- is believed at once; a rising one is not believed until it has lasted.
function P.safe_reference(usual, recent_median, market)
    local r = nil
    if usual and usual > 0 then r = usual end
    if recent_median and recent_median > 0 and (not r or recent_median < r) then r = recent_median end
    if market and market > 0 and (not r or market < r) then r = market end
    return r
end

--- The chance a resale of `units` bought for `cost` in all, posted at
--- `resale` each, ends in a profit.
--- `sales_per_day` is in units; `lot` is how many units a purchase takes on
--- average (1 when not known): buyers come in purchases, so N units sell
--- when ceil(N / lot) purchases arrive, at sales_per_day / lot a day.
---@param o table { cut_pct, cv, trend?, sales_per_day, lot?, days, vendor, deposit_unit }
---@return number probability 0..1
function P.flip_confidence(o, units, cost, resale)
    if not units or units <= 0 then return 0 end
    local unit_cost = cost / units
    -- A vendor floor: if the auction house never takes it, the vendor still
    -- pays more than it cost, deposit lost and all.
    if (o.vendor or 0) > unit_cost + (o.deposit_unit or 0) then return 1 end
    -- The deposits it may lose (o.fee_unit, per unit) are part of what it cost.
    local breakeven = (unit_cost + (o.fee_unit or 0)) / (1 - (o.cut_pct or 5) / 100)
    if not resale or resale <= breakeven then return 0 end
    local days = max(0.25, o.days or 1)
    local sigma = max(P.MIN_CV, (o.cv or P.PRIOR_CV) * sqrt(max(1, days)))
    -- A price that has been falling is expected to go on falling for the
    -- auction's length; one that has been rising is given no credit for it.
    local drift = min(0, o.trend or 0) * days
    local p_price = P.phi((math.log(resale / breakeven) + drift) / sigma)
    -- Stock already held of the item (o.held) sells to the same buyers: these
    -- units sell only if those AND these do.
    local lot = max(1, o.lot or 1)
    local p_sell = P.poisson_at_least(P.sales_needed(units + (o.held or 0), lot), (o.sales_per_day or 0) * days / lot)
    return p_price * p_sell
end

--- Deposits a resale of `units` should be planned to lose: one per post,
--- `stack` units a post at most. With `vendor` and `rate`, each post's
--- deposit is what Forever takes for it: max(post_fee, rate x vendor x the
--- units in that post) (48 hours: rate 0.60 -- the user's Lion Meat post,
--- 8 x 55c x 0.6 = 264c, and Thick Spider's Silk, 2 x 7s 50c x 0.6 = 9s,
--- both exact). Without them, a flat `post_fee` a post.
function P.post_fees(units, post_fee, stack, vendor, rate)
    if not units or units <= 0 then return 0 end
    stack = max(1, stack or 1)
    if rate and rate > 0 and (vendor or 0) > 0 then
        local total, left = 0, units
        while left > 0 do
            local q = min(left, stack)
            total = total + max(post_fee or 0, rate * vendor * q)
            left = left - q
        end
        return total
    end
    if not post_fee or post_fee <= 0 then return 0 end
    return post_fee * math.ceil(units / stack)
end

-- --- worth it, and big money ---------------------------------------------------------
--
-- The user (2026-10-08): "At what point should the equation be like I can make
-- alot of money here not just a few copper or silvers". Against capital C
-- (gold + stock at cost), on the deal as Auto may actually buy it:
--   worth buying  profit (after one lost deposit a post) >= max(5s, 2 x its
--                 deposits, 0.1% of C); the 5s is raised by policy.lua when
--                 small lots miss their plan by more
--   big money     expected profit E >= max(20s, 5% of C) and E >= 4 x its deposits
P.FLOOR_ABS = 500
P.FLOOR_FEES = 2
P.FLOOR_SHARE = 0.001
P.BIG_ABS = 2000
P.BIG_SHARE = 0.05
P.BIG_FEES = 4

--- The least profit a deal must plan: max(floor_abs, 2 x fees, 0.1% of capital).
function P.worth_floor(capital, fees, floor_abs)
    return max(floor_abs or P.FLOOR_ABS, P.FLOOR_FEES * (fees or 0), P.FLOOR_SHARE * (capital or 0))
end

--- Expected profit at or above which a deal is big money.
function P.big_line(capital)
    return max(P.BIG_ABS, P.BIG_SHARE * (capital or 0))
end

function P.is_big(expected, capital, fees)
    return (expected or 0) >= P.big_line(capital) and (expected or 0) >= P.BIG_FEES * (fees or 0)
end

--- Expected profit: the profit times how sure it is, less what failing costs
--- times the chance it fails (the units sold at the salvage price -- a share
--- `loss_share` of their cost lost -- and every deposit lost). A vendor flip
--- cannot fail: its profit.
function P.expected(plan, loss_share)
    if not plan or (plan.units or 0) <= 0 then return 0 end
    if plan.mode == "vendor" then return plan.profit or 0 end
    local p = plan.confidence or 0
    return p * (plan.profit or 0) - (1 - p) * ((plan.cost or 0) * (loss_share or 1) + (plan.fees or 0))
end

--- What a deal earns a day on the gold it ties up: E / (cost x days).
function P.return_rate(expected, cost, days)
    if not cost or cost <= 0 then return 0 end
    return (expected or 0) / (cost * max(0.25, days or 1))
end

--- The Kelly fraction for a trade that makes `win` (a share of its cost)
--- with probability p and loses `loss` (a share of its cost) otherwise:
--- f* = p/loss - (1-p)/win, the share of capital that grows it fastest.
--- 0 when the trade does not pay on average; infinite when it cannot lose.
--- (policy.lua stakes a quarter of it.)
function P.kelly(p, win, loss)
    if not p or p <= 0 or not win or win <= 0 then return 0 end
    if not loss or loss <= 0 then return math.huge end
    local f = p / loss - (1 - p) / win
    if f <= 0 then return 0 end
    return f
end

-- --- deals -----------------------------------------------------------------------

-- Both planners below take an item's listings as a search or a scan gives
-- them ({ unit, qty, own?, buyout?, auction_id? }), skip your own and the
-- bid-only ones, and walk the rest cheapest first. Options:
--   cut_pct, min_margin_pct  the cut, and the margin every unit must clear
--   max_units, budget        stop there
--   whole                    an item auction is bought whole or not at all
--                            (a commodity listing can be bought in part)
--   max_rows                 how deep into the listings to look (30)
-- A plan: { mode, units, cost, value, profit, resale, max_unit, rows }, each
-- row { unit, qty, cost, ref = the listing }.

local function buyable(listings, max_rows)
    local rows = {}
    for i = 1, #listings do
        local l = listings[i]
        if not l.own and (tonumber(l.unit) or 0) > 0 and (tonumber(l.qty) or 0) > 0 then rows[#rows + 1] = l end
    end
    table.sort(rows, function(a, b) return a.unit < b.unit end)
    local cap = max_rows or 30
    while #rows > cap do rows[#rows] = nil end
    return rows
end

local function empty_plan(mode)
    return { mode = mode, units = 0, cost = 0, value = 0, profit = 0, resale = 0, max_unit = 0, rows = {} }
end

--- How many of listing `r` the plan can still take, and what they cost.
--- A row of several auctions of one each (`each`, ah.lua) gives one a
--- purchase: a bid buys the row's own auction, at the price of one.
local function take(units, cost, r, o)
    local q = min(r.qty, (o.max_units or math.huge) - units)
    if r.each then q = min(q, 1) end
    local afford = floor(((o.budget or math.huge) - cost) / r.unit)
    q = min(q, afford)
    if q <= 0 then return 0, 0 end
    if o.whole and q < r.qty and not r.each then return 0, 0 end
    local c = (q == r.qty and tonumber(r.buyout) and r.buyout > 0) and r.buyout or q * r.unit
    return q, c
end

--- A vendor flip takes a bag slot a stack until a merchant is seen: a full
--- stack must make at least this (2s). 229 Murloc Eyes bought for 3s 13c
--- under the vendor's price filled twelve slots (the user's bags, 2026-10-12).
P.VENDOR_STACK_FLOOR = 200

--- Does a stack of `stack` bought at `unit` each make the floor at a vendor?
function P.vendor_stack_pays(vendor, unit, stack)
    return ((vendor or 0) - (unit or 0)) * max(1, stack or 1) >= P.VENDOR_STACK_FLOOR
end

--- Buy what a vendor pays more for than the auction house asks. No cut, no
--- waiting, no risk: the vendor always buys. With `stack` (units a bag slot
--- holds), a stack must make P.VENDOR_STACK_FLOOR.
---@param listings table[]
---@param o table { vendor, min_margin_pct, max_units, budget, whole, stack? }
---@return table plan
function P.plan_vendor(listings, o)
    local plan = empty_plan("vendor")
    local vendor = o.vendor or 0
    if vendor <= 0 then return plan end
    local need = 1 + (o.min_margin_pct or 0) / 100
    local rows = buyable(listings, o.max_rows)
    for i = 1, #rows do
        local r = rows[i]
        if vendor < r.unit * need then break end
        if o.stack and not P.vendor_stack_pays(vendor, r.unit, o.stack) then break end
        local q, c = take(plan.units, plan.cost, r, o)
        if q <= 0 then break end
        plan.rows[#plan.rows + 1] = { unit = r.unit, qty = q, cost = c, ref = r }
        plan.units, plan.cost, plan.max_unit = plan.units + q, plan.cost + c, r.unit
        if q < r.qty then break end
    end
    plan.resale = vendor
    plan.value = plan.units * vendor
    plan.profit = plan.value - plan.cost
    -- The vendor's price does not move and the vendor always buys.
    plan.confidence = plan.units > 0 and 1 or 0
    return plan
end

--- When the cheap end is not a mistake but the price. Listings more than 20%
--- under the item's usual price (or, with no history, under the
--- unit-weighted median of everything listed) are "cheap". One or two cheap
--- listings are a seller in a hurry or a mistake: buy them. Three or more --
--- several listings agreeing -- or cheap units making up more than a quarter
--- of everything listed, and the price has moved: the market value with them
--- in is believed. (The backtest, 1.0.0: most losses at 99% were crashes.
--- Measured against the median of what is listed, a crash big enough to BE
--- the median hid itself; the usual price does not move with the crash.)
P.CRASH_SHARE = 0.25
P.CRASH_LISTINGS = 3
P.CHEAP_UNDER = 0.80

---@param all table[] listings, cheapest first
---@param usual? number the item's usual price
---@return boolean shifted
---@return number|nil level where the cheap listings agree the price now is
---   (their unit-weighted median): nothing is resold above it once it moved
function P.level_shift(all, usual)
    local units = 0
    for i = 1, #all do units = units + all[i].qty end
    if units <= 0 then return false, nil end
    local going = usual
    if not going or going <= 0 then
        local half, seen = units / 2, 0
        for i = 1, #all do
            seen = seen + all[i].qty
            if seen >= half then going = all[i].unit break end
        end
    end
    local cheap_n, cheap_units = 0, 0
    for i = 1, #all do
        if all[i].unit < going * P.CHEAP_UNDER then
            cheap_n, cheap_units = cheap_n + 1, cheap_units + all[i].qty
        end
    end
    if not (cheap_n >= P.CRASH_LISTINGS or cheap_units > units * P.CRASH_SHARE) then return false, nil end
    local half, seen, level = cheap_units / 2, 0, nil
    for i = 1, #all do
        if all[i].unit < going * P.CHEAP_UNDER then
            seen = seen + all[i].qty
            if seen >= half then level = all[i].unit break end
        end
    end
    return true, level
end

--- How sure a resale is over the fewest 48-hour posts k (1 .. posts) that
--- make it as sure as o.min_confidence. Each post is credited with o.days
--- of selling (one: the other day of a 48-hour post stays margin) and each
--- post that does not sell loses its deposit, so k posts plan k x fee1
--- deposits. With survive, the lot must also make money after k + survive
--- of them (policy: 2, the same as the least profit's "twice its deposits").
--- Returns the chance, k (nil when no k is sure enough), the deposits
--- planned and the options it was judged with.
function P.judge_posts(o, units, cost, resale, fee1, posts, survive)
    local net = units * P.net(resale, o.cut_pct)
    local best = 0
    for k = 1, max(1, posts or 1) do
        if not survive or net - cost - (k + survive) * fee1 > 0 then
            local r = o
            if k > 1 then
                r = {}
                for key, v in pairs(o) do r[key] = v end
            end
            r.days = k * (o.days or 1)
            r.fee_unit = k * fee1 / units
            local p = P.flip_confidence(r, units, cost, resale)
            if p >= (o.min_confidence or 0) then return p, k, k * fee1, r end
            if p > best then best = p end
        end
    end
    return best, nil, fee1, o
end

--- Buy the cheap end of an item and post it again just under the next
--- seller you did not buy out. Every number of cheapest listings is tried,
--- from one up, and the most profitable count that is sure enough wins, so
--- two cheap stacks under a wall are bought together even when one alone
--- would not pay.
---
--- The price each count is judged against is the CAUTIOUS one: the lowest of
--- the item's usual price, the median of its recent days (`usual`,
--- `median`, or a fixed `reference`), and the market value of what is LEFT
--- once those listings are bought -- what the resale actually competes with.
--- Judging against a market value that still held the cheap listings would
--- let the deal itself drag the price down; but when the cheap end looks
--- like the price moving (level_shift), the market value with it in
--- (`market`) is believed instead.
---
--- Volatility for flip_confidence: `cv` from the item's own history, and no
--- less than how far the market left sits from the usual price.
---@param listings table[]
---@param o table { reference?, usual?, median?, market?, cv?, cut_pct, undercut, min_margin_pct,
---   max_units, budget, whole, min_confidence?, sales_per_day?, lot?, days?, vendor?, deposit_unit?,
---   post_fee?, stack? }
--- `post_fee` is one post's deposit and `stack` the most units one post
--- holds: the plan's profit is AFTER one lost deposit per post (a repost
--- or an expiry forfeits it; a sale returns it).
---@return table plan
function P.plan_flip(listings, o)
    local best = empty_plan("flip")
    local need = 1 + (o.min_margin_pct or 0) / 100
    local undercut = o.undercut or 1
    local all = buyable(listings, math.huge)
    local rows = buyable(listings, o.max_rows)
    local shifted, shifted_to = P.level_shift(all, P.safe_reference(o.usual or o.reference, o.median, nil))

    -- Never more units than are sure enough to sell before the auction ends:
    -- the largest q with P(at least q sell) >= min_confidence. (The price
    -- side can only lower the chance further, so this is an upper bound.)
    if o.min_confidence and o.sales_per_day then
        local lot = max(1, o.lot or 1)
        -- Over every post it may be judged on (o.posts, below).
        local lambda = o.sales_per_day * max(0.25, (o.days or 1) * (o.posts or 1)) / lot
        local held = o.held or 0
        -- Counted in purchases, not units (the review, 1.1.0: one unit at a
        -- time made this the costliest loop of a compute): the most purchases
        -- k sure enough to come, then every unit those take. Same q: needing
        -- at most k purchases is units <= k x lot.
        local k = 0
        while k < 100000 and P.poisson_at_least(k + 1, lambda) >= o.min_confidence do k = k + 1 end
        local q = math.max(0, math.min(100000, math.floor((k + 1e-9) * lot) - held))
        if q == 0 then return best end
        local capped = {}
        for key, v in pairs(o) do capped[key] = v end
        capped.max_units = min(o.max_units or math.huge, q)
        o = capped
    end

    -- No resale is ever above the usual price and the recent median, so once a
    -- row's price cannot clear the margin there either, no dearer row can.
    local top = P.safe_reference(o.reference or o.usual, o.median, nil)
    local units, cost, taken = 0, 0, {}
    for k = 1, #rows do
        local r = rows[k]
        if top and P.net(top, o.cut_pct) < r.unit * need then break end
        local q, c = take(units, cost, r, o)
        if q <= 0 then break end
        units, cost = units + q, cost + c
        taken[#taken + 1] = { unit = r.unit, qty = q, cost = c, ref = r }
        local partial = q < r.qty
        -- What is left to sell against once these are bought.
        local rest = {}
        if partial then rest[1] = { unit = r.unit, qty = r.qty - q } end
        for i = k + 1, #all do rest[#rest + 1] = all[i] end
        local left_market = P.market_value(rest)
        local cap = P.safe_reference(o.reference, o.usual, left_market)
        cap = P.safe_reference(cap, o.median, nil)
        if shifted then
            -- Several sellers agree the price has moved: believe them.
            cap = P.safe_reference(cap, o.market, shifted_to)
        end
        local next_unit = rest[1] and rest[1].unit
        local resale = cap
        if cap and next_unit then resale = min(cap, next_unit - undercut) end
        -- The dearest unit taken (this one: the walk is cheapest first) must
        -- clear the margin; then all the cheaper ones do too. And the whole
        -- lot must be likely enough to end in a profit (flip_confidence):
        -- more units need more buyers, so a bigger lot can fail where a
        -- smaller one passes.
        if resale and resale > 0 then
            local net_resale = P.net(resale, o.cut_pct)
            if net_resale >= r.unit * need then
                -- The options as this count is judged: its own volatility.
                local risk = {}
                for key, v in pairs(o) do risk[key] = v end
                local usual = o.usual or o.reference
                if usual and usual > 0 and left_market then
                    risk.cv = max(o.cv or P.PRIOR_CV, math.abs(left_market / usual - 1))
                end
                -- The deposits of posting it all once (Forever's, post by post).
                local fee1 = P.post_fees(units, o.post_fee, o.stack, o.vendor, o.deposit_rate)
                local confidence, posts_k, fees = 1, 1, fee1
                risk.fee_unit = fee1 / units
                if o.min_confidence then
                    confidence, posts_k, fees, risk = P.judge_posts(risk, units, cost, resale, fee1, o.posts, o.survive)
                end
                local profit = units * net_resale - cost - fees
                if posts_k and confidence >= (o.min_confidence or 0) and profit > best.profit then
                    local rows_copy = {}
                    for i = 1, #taken do rows_copy[i] = taken[i] end
                    best = { mode = "flip", units = units, cost = cost, value = units * net_resale - fees,
                        profit = profit, resale = resale, max_unit = r.unit, rows = rows_copy,
                        confidence = confidence, risk = risk, cap = cap, fees = fees, deposits = fee1,
                        posts = posts_k }
                end
            end
        end
        if partial then break end
    end
    best.confidence = best.confidence or 0
    return best
end

return P

-- Jambix Market: a backtest of the buying rules on a simulated auction house.
--
-- The plugin's own planners (scripts/jambix_market/modules/pricing.lua) are
-- run, with the options deals.lua builds, against thousands of simulated
-- markets. The planner sees only what the plugin would have seen, with the
-- plugin's own errors in it:
--   * buyers who take several units at once (a stackable's purchase is 1 to
--     about 20 units), seen over 2 to 72 hours of watching, inflated by
--     cancellations (up to +80%) -- the purchases, their units and the time,
--     as the price file keeps them
--   * one to seven days of daily prices, which carry the market's own drift
--   * the listings now: a wall of sellers near the going price, and a few
--     cheap ones -- which one time in five are a real crash, the going price
--     itself falling to where the cheap sellers are
-- Each trade is then played out hour by hour against what the market really
-- does: the price drifts (on average DOWN) and jumps with the item's own
-- volatility, competitors list under you, buyers arrive at random and take
-- the cheapest first, nobody pays far over the going price. The plugin's
-- post price rule (pricing.post_price) prices the listing; deposits are paid
-- as Forever takes them -- a flat 1s a post, seen on every live post
-- (2026-10-07) -- returned with a sale and lost on what does not sell; an unsold post is reposted once under the
-- going price if that still pays, an undercut post is reposted under the
-- undercutter up to three times a day when that still pays (as Auto does,
-- each repost losing its deposit), and what is left after two days goes to a
-- vendor or is valued at the going price less the cut.
--
-- A trade succeeds when it ends with more copper than it started. The rate
-- is printed for the original v1 rule and for the risk-judged rule at 90%,
-- 95% and 99% confidence. This is a model of a market, not the Forever
-- auction house: the live rate is measured by the plugin's ledger.

local P = require("jambix_market/modules/pricing")

local floor, exp, sqrt, log, min, max = math.floor, math.exp, math.sqrt, math.log, math.min, math.max

-- --- a deterministic random source (Park-Miller, in floats on every Lua) ----

local seed = 20261007.0
local function rand()
    seed = (seed * 16807.0) % 2147483647.0
    return seed / 2147483647.0
end

local function normal()
    local u1, u2 = rand(), rand()
    if u1 < 1e-12 then u1 = 1e-12 end
    return sqrt(-2 * log(u1)) * math.cos(2 * math.pi * u2)
end

local function poisson(lambda)
    if lambda <= 0 then return 0 end
    if lambda > 30 then return max(0, floor(lambda + sqrt(lambda) * normal() + 0.5)) end
    local limit, k, p = exp(-lambda), 0, 1
    repeat
        k = k + 1
        p = p * rand()
    until p <= limit
    return k - 1
end

local function mean(t)
    local s = 0
    for i = 1, #t do s = s + t[i] end
    return s / #t
end

local function median(t)
    local s = {}
    for i = 1, #t do s[i] = t[i] end
    table.sort(s)
    local n = #s
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) / 2
end

local CUT = 5
local POST_FEE = 100        -- Forever's deposit, per post (the user's live posts)

-- --- one simulated item ---------------------------------------------------------

--- Units one purchase takes: 1 for gear, 1 .. about twice the item's mean
--- for a stackable.
local function purchase_size(m)
    if m.lot <= 1 then return 1 end
    return 1 + floor(rand() * (2 * m.lot - 1))
end

local function make_market()
    local m = {
        usual = 10 ^ (2 + 3 * rand()),            -- 1s .. 10g
        demand = 10 ^ (-0.7 + 2.4 * rand()),      -- 0.2 .. 50 units a day, truly
        sigma = 0.02 + 0.28 * rand(),             -- daily volatility, 2% .. 30%
        drift = -0.08 + 0.10 * rand(),            -- daily drift, -8% .. +2%
        stack = rand() < 0.7 and 20 or 1,
        crash = rand() < 0.2,
    }
    -- Buyers: a stackable is bought 1 to 10 units at a time on average.
    m.lot = m.stack > 1 and (1 + 9 * rand()) or 1
    m.buyers = m.demand / m.lot                 -- purchases a day
    m.vendor = rand() < 0.2 and 0 or m.usual * (0.01 + 0.3 * rand())

    -- What the plugin saw.
    local days = 1 + floor(7 * rand())
    local values = {}
    for i = 1, days do values[i] = m.usual * exp(m.drift * (i - days) + m.sigma * normal()) end
    local level = m.usual * exp(0.5 * m.sigma * normal())
    local cheap_level = level * (0.2 + 0.75 * rand())
    local listings = {}
    for _ = 1, 3 + floor(10 * rand()) do
        listings[#listings + 1] = { unit = level * (1 + 0.2 * rand()),
            qty = m.stack > 1 and (1 + floor(20 * rand())) or 1 }
    end
    local cheap = m.crash and (3 + floor(6 * rand())) or (1 + floor(3 * rand()))
    for _ = 1, cheap do
        listings[#listings + 1] = { unit = cheap_level * (0.9 + 0.2 * rand()),
            qty = m.stack > 1 and (1 + floor(15 * rand())) or 1 }
    end
    local watched = (2 + 70 * rand()) * 3600
    local purchases = poisson(m.buyers * (1 + 0.8 * rand()) * watched / 86400)
    local seen = 0
    for _ = 1, purchases do seen = seen + purchase_size(m) end
    m.obs = {
        values = values, days = days, usual = mean(values), listings = listings,
        sold = seen, purchases = purchases, watched = watched, sold_per_day = seen / watched * 86400,
    }
    -- Where the market really goes from here.
    m.level = m.crash and cheap_level or level
    return m
end

-- --- the rules ---------------------------------------------------------------------

--- The rule this plugin shipped first (1.0.0 before the review): resale
--- capped at the usual price, about three days of estimated sales, no
--- judgement of how sure it is.
local function plan_v1(listings, o)
    local rows = {}
    for i = 1, #listings do rows[i] = listings[i] end
    table.sort(rows, function(a, b) return a.unit < b.unit end)
    local need = 1 + o.min_margin_pct / 100
    local best = { units = 0, profit = 0 }
    local units, cost = 0, 0
    for k = 1, min(#rows, 30) do
        local r = rows[k]
        local q = min(r.qty, o.max_units - units)
        if q <= 0 then break end
        units, cost = units + q, cost + q * r.unit
        local partial = q < r.qty
        local next_unit = partial and r.unit or (rows[k + 1] and rows[k + 1].unit)
        local resale = o.reference
        if next_unit then resale = min(resale, next_unit - 1) end
        local net = P.net(resale, CUT)
        if net >= r.unit * need then
            local profit = units * net - cost
            if profit > best.profit then
                best = { units = units, cost = cost, profit = profit, resale = resale }
            end
        end
        if partial then break end
    end
    return best
end

--- The rule the plugin uses now: deals.plan_for's options, exactly. With
--- `by_units`, the rule as it was before the live fix: every unit sold
--- counted as a buyer, and no three-buyer minimum.
local function plan_now(m, confidence, by_units)
    local obs = m.obs
    local listings = obs.listings
    local rec_median = obs.days >= 2 and median(obs.values) or nil
    local low, lot
    if by_units then
        low, lot = P.rate_lower(obs.sold, obs.watched, 1.645), 1
    else
        if obs.purchases < 3 then return { units = 0, profit = 0 } end
        lot = max(1, obs.sold / obs.purchases)
        low = P.rate_lower(obs.purchases, obs.watched, 1.645) * lot
    end
    if low <= 0 then return { units = 0, profit = 0 } end
    local plan = P.plan_flip(listings, {
        usual = obs.usual, median = rec_median, market = P.market_value(listings),
        cut_pct = CUT, undercut = 1, min_margin_pct = 25,
        max_units = max(1, floor(obs.sold_per_day * 3)), whole = m.stack == 1,
        cv = P.volatility(obs.values), trend = P.trend(obs.values), sales_per_day = low * 0.75, lot = lot,
        days = 1, vendor = m.vendor, deposit_unit = max(m.vendor * 0.30, POST_FEE), min_confidence = confidence,
        post_fee = POST_FEE, stack = m.stack,
    })
    plan.ceiling = P.safe_reference(obs.usual, rec_median, nil)
    return plan
end

-- --- playing a trade out -------------------------------------------------------------

local function play(m, plan)
    local units, cost = plan.units, plan.cost
    local unit_cost = cost / units
    -- What is listed once these are bought: the cheapest other seller.
    local rest = {}
    for i = 1, #m.obs.listings do rest[i] = { unit = m.obs.listings[i].unit, qty = m.obs.listings[i].qty } end
    table.sort(rest, function(a, b) return a.unit < b.unit end)
    local left_to_take = units
    for i = 1, #rest do
        local take = min(rest[i].qty, left_to_take)
        rest[i].qty, left_to_take = rest[i].qty - take, left_to_take - take
    end
    local lowest = nil
    for i = 1, #rest do
        if rest[i].qty > 0 then lowest = rest[i].unit break end
    end
    -- Priced the way the plugin posts.
    local post = P.post_price({ market = m.obs.usual, lowest = lowest, vendor = m.vendor, cost = unit_cost,
        cut_pct = CUT, margin_pct = 10, undercut = 1, ceiling_pct = 200, ceiling = plan.ceiling })

    local level = m.level
    local left, proceeds, fees = units, 0, 0
    -- Each stack posted takes the flat deposit; per unit, for the bookkeeping.
    local deposit = POST_FEE * math.ceil(units / m.stack) / units
    if post then
        fees = deposit * units
        local ahead, ahead_price, reposts = 0, nil, 0
        local floor_unit = max(m.vendor, unit_cost)
        for hour = 1, 48 do
            level = level * exp(m.drift / 24 + m.sigma / sqrt(24) * normal())
            if rand() < 0.3 then
                local theirs = level * (0.9 + 0.15 * rand())
                if theirs < post then
                    ahead = ahead + (m.stack > 1 and (1 + floor(10 * rand())) or 1)
                    ahead_price = min(ahead_price or theirs, theirs)
                end
            end
            -- Undercut: Auto cancels and posts under them when that still
            -- clears the floor by more than the deposit it loses.
            if ahead > 0 and reposts < 3 then
                local again = floor(ahead_price - 1)
                if (again * (1 - CUT / 100) - floor_unit) * left > deposit * left then
                    post, ahead, ahead_price, reposts = again, 0, nil, reposts + 1
                    fees = fees + deposit * left
                end
            end
            local demand = 0
            for _ = 1, poisson(m.buyers / 24) do demand = demand + purchase_size(m) end
            if post > level * 1.15 then demand = 0 end
            local first = min(ahead, demand)
            ahead, demand = ahead - first, demand - first
            local mine = min(left, demand)
            if mine > 0 then
                left = left - mine
                proceeds = proceeds + mine * post * (1 - CUT / 100)
                fees = fees - deposit * mine          -- returned with the sale
            end
            if left == 0 then break end
            if hour == 24 then
                -- Unsold after a day: that deposit is gone. Repost under the
                -- going price if that still clears what it cost, as Auto does.
                local again = min(post, level * 0.98)
                if again * (1 - CUT / 100) > unit_cost then
                    post, ahead = again, 0
                    fees = fees + deposit * left
                else
                    break
                end
            end
        end
    end
    if left > 0 then
        if m.vendor > 0 and m.vendor >= level * (1 - CUT / 100) then
            proceeds = proceeds + left * m.vendor
        else
            proceeds = proceeds + left * level * (1 - CUT / 100)
        end
    end
    return proceeds - cost - fees
end

-- --- the backtest ------------------------------------------------------------------------

local TRIALS = 6000

local function backtest()
    local saved = seed
    local rules = {
        { name = "v1 (before the review)" },
        { name = "units as buyers, 99%", conf = 0.99, by_units = true },
        { name = "risk-judged, 90%", conf = 0.90 },
        { name = "risk-judged, 95%", conf = 0.95 },
        { name = "risk-judged, 99%", conf = 0.99 },
    }
    for _, r in ipairs(rules) do r.trades, r.wins, r.profit, r.loss, r.predicted = 0, 0, 0, 0, 0 end
    local vendor = { trades = 0, wins = 0 }

    for _ = 1, TRIALS do
        local m = make_market()
        local min_profit = max(1, 0.02 * m.usual)
        -- Each rule decides on the same market and is played out from the same
        -- random future, so they are compared on equal terms.
        local future = seed
        for _, r in ipairs(rules) do
            local plan
            if r.conf then
                plan = plan_now(m, r.conf, r.by_units)
            else
                plan = plan_v1(m.obs.listings, { reference = m.obs.usual, min_margin_pct = 25,
                    max_units = max(1, floor(m.obs.sold_per_day * 3)) })
            end
            if plan.units > 0 and plan.profit >= min_profit then
                seed = future
                local made = play(m, plan)
                r.trades = r.trades + 1
                r.predicted = r.predicted + (plan.confidence or 0)
                if made > 0 then
                    r.wins = r.wins + 1
                    r.profit = r.profit + made
                else
                    r.loss = r.loss - made
                end
            end
        end
        seed = future
        -- Vendor flips, on the same listings.
        if m.vendor > 0 then
            local plan = P.plan_vendor(m.obs.listings, { vendor = m.vendor, min_margin_pct = 5 })
            if plan.units > 0 then
                vendor.trades = vendor.trades + 1
                if plan.units * m.vendor - plan.cost > 0 then vendor.wins = vendor.wins + 1 end
            end
        end
    end
    seed = saved
    return rules, vendor
end

local T = {}
local results, vendor_results

T[#T + 1] = { "backtest: the buying rules on a simulated market", function()
    results, vendor_results = backtest()
    print("")
    print(string.format("  Backtest over %d simulated items (one trade each at most):", TRIALS))
    for _, r in ipairs(results) do
        local rate = r.trades > 0 and (r.wins / r.trades * 100) or 0
        print(string.format("    %-24s %5d trades  %6.2f%% made money%s  net %+.0fg (won %.0fg, lost %.0fg)",
            r.name, r.trades, rate,
            r.conf and string.format("  (%.2f%% predicted)", r.predicted / max(1, r.trades) * 100) or "",
            (r.profit - r.loss) / 10000, r.profit / 10000, r.loss / 10000))
    end
    print(string.format("    %-24s %5d trades  %6.2f%% made money", "vendor flips", vendor_results.trades,
        vendor_results.trades > 0 and vendor_results.wins / vendor_results.trades * 100 or 0))
end }

T[#T + 1] = { "the risk-judged rule beats the first one, and holds near what it promises", function()
    local v1, r99 = results[1], results[5]
    local rate_v1 = v1.wins / max(1, v1.trades)
    local rate_99 = r99.wins / max(1, r99.trades)
    assert(r99.trades >= 100, "the 99% rule still trades: " .. r99.trades)
    assert(rate_99 > rate_v1, string.format("99%% rule %.3f vs v1 %.3f", rate_99, rate_v1))
    assert(rate_99 >= 0.98, string.format("the 99%% rule made money %.2f%% of the time", rate_99 * 100))
    assert(vendor_results.wins == vendor_results.trades, "every vendor flip made money")
end }

-- =============================================================================
-- A STREAM of deals under a capital limit, on Forever's 48-hour posts (1.1.0)
-- =============================================================================
--
-- The table above judges one trade per market with all the money in the
-- world. Money is what decides which deals get bought, so this runs Auto's
-- money rules over a stream: markets (make_market, the same generator) turn
-- up at random -- 15 or 60 an hour -- and stay on the list for about two hours
-- (others buy them), with 4g 90s 10c of capital, the user's own on
-- 2026-10-08, held there (profit is taken out as it arrives). Each 15 minutes
-- the visible deals are planned with pricing.lua and bought best first within
-- policy.lua's limits (10% reserve, 70% stock, half of capital a deal,
-- quarter Kelly at p - 2 points). Every lot is played out on 48-hour posts:
-- Forever's deposit max(1s, 0.6 x vendor x units) a post, returned with a
-- sale, lost when undercut and reposted (3 a day at most) or when the post
-- runs out (posted again under the going price while that clears what it
-- cost, four posts at most); vendor flips are paid at the next merchant
-- visit (one a day on average). A sale's money comes back an hour later.
--
--   CURRENT  1.0.x: a flat 2s 64c deposit planned per post, least profit
--            max(50c, 0.05% of capital), best profit x sure / days first
--            (vendor flips a quarter of a day)
--   FINAL    1.1.0: Forever's deposit planned post by post; never under
--            max(5s, 2 x its deposits, 0.1% of capital); expected profit with
--            what failing costs; judged over up to two posts (one deposit
--            each, surviving two more); best return a day on the gold first
--            (vendor flips one day); big money = expected >= max(20s, 5% of
--            capital) and 4 x its deposits; anything else only while stock
--            is under half of capital.

local STEP_H = 0.25
local DEP_MIN, DEP_RATE = 100, 0.6

local function dep_total(m, units)
    local left, t = units, 0
    while left > 0 do
        local q = min(left, m.stack)
        t = t + max(DEP_MIN, DEP_RATE * m.vendor * q)
        left = left - q
    end
    return t
end

local function capital_of(gold, stock)
    local C = gold + stock
    local free = max(0, gold - 0.10 * C)
    local room = max(0, 0.70 * C - stock)
    local max_deal = max(0, min(free, room, 0.50 * C))
    return { capital = C, max_deal = max_deal, max_small = min(max_deal, max(0, 0.50 * C - stock)) }
end

local function loss_share(plan)
    if plan.mode == "vendor" then return 0 end
    local salvage = max(plan.risk.vendor or 0, P.net(plan.resale, CUT) * exp(-2 * (plan.risk.cv or P.PRIOR_CV)))
    return max(0.02, min(1, 1 - salvage / (plan.cost / plan.units)))
end

local function kelly_size(plan, cap)
    local p = plan.mode == "vendor" and 1 or max(0, plan.confidence - 0.02)
    local f = P.kelly(p, plan.profit / plan.cost, loss_share(plan))
    return max(0, min(cap.max_deal, cap.capital * min(0.5, 0.25 * f)))
end

local RULES = {
    { name = "CURRENT (1.0.x)", final = false },
    { name = "FINAL (1.1.0)", final = true },
}

--- deals.plan_for for a simulated market, within `budget`.
local function plan_market(m, rule, budget)
    local obs, best = m.obs, nil
    if m.vendor > 0 then
        local pv = P.plan_vendor(obs.listings, { vendor = m.vendor, min_margin_pct = 5, budget = budget,
            whole = m.stack == 1 })
        if pv.units > 0 and pv.profit > 0 then best = pv end
    end
    if obs.purchases >= 3 then
        local lot = max(1, obs.sold / obs.purchases)
        local low = P.rate_lower(obs.purchases, obs.watched, 1.645) * lot
        if low > 0 then
            local rec_median = obs.days >= 2 and median(obs.values) or nil
            local pf = P.plan_flip(obs.listings, {
                usual = obs.usual, median = rec_median, market = P.market_value(obs.listings),
                cut_pct = CUT, undercut = 1, min_margin_pct = 25, budget = budget,
                max_units = max(1, floor(obs.sold_per_day * 3)), whole = m.stack == 1,
                cv = P.volatility(obs.values), trend = P.trend(obs.values), sales_per_day = low * 0.75, lot = lot,
                days = 1, vendor = m.vendor, min_confidence = 0.99, stack = m.stack,
                post_fee = rule.final and DEP_MIN or 264,
                deposit_rate = rule.final and DEP_RATE or nil,
                deposit_unit = rule.final and max(m.vendor * DEP_RATE, DEP_MIN) or max(m.vendor * 0.6, 264),
                posts = rule.final and 2 or nil, survive = rule.final and 2 or nil,
            })
            if pf.units > 0 and pf.profit > 0 then
                pf.ceiling = P.safe_reference(obs.usual, rec_median, nil)
                pf.per_day_low = low
                if not best or pf.profit > best.profit then best = pf end
            end
        end
    end
    return best
end

local function least(rule, C, plan)
    if not rule.final then return max(50, 0.0005 * C) end
    return P.worth_floor(C, plan.mode == "flip" and plan.deposits or 0, 500)
end

--- K.plan_for with o.size: within `budget`, held to its Kelly share, then the
--- least profit and the money figures.
local function plan_sized(m, rule, cap, budget)
    if budget <= 0 then return nil end
    local plan = plan_market(m, rule, budget)
    if not plan then return nil end
    local allowed = kelly_size(plan, cap)
    if allowed < plan.cost then
        if allowed <= 0 then return nil end
        plan = plan_market(m, rule, min(budget, allowed))
        if not plan then return nil end
    end
    if plan.profit < least(rule, cap.capital, plan) then return nil end
    local days = plan.mode == "vendor" and (rule.final and 1 or 0.25) or max(0.25, plan.units / plan.per_day_low)
    local sure = plan.mode == "vendor" and 1 or plan.confidence
    if rule.final then
        plan.expected = P.expected(plan, loss_share(plan))
        plan.big = P.is_big(plan.expected, cap.capital, plan.mode == "flip" and plan.deposits or 0)
        plan.key = P.return_rate(plan.expected, plan.cost, days)
    else
        plan.expected = plan.profit * sure
        plan.key = plan.profit * sure / days
    end
    return plan
end

--- A lot on Forever's 48-hour posts: what it made and its cash flows.
local function play48(m, plan)
    local units, cost = plan.units, plan.cost
    local unit_cost = cost / units
    local flows = {}
    local rest = {}
    for i = 1, #m.obs.listings do rest[i] = { unit = m.obs.listings[i].unit, qty = m.obs.listings[i].qty } end
    table.sort(rest, function(a, b) return a.unit < b.unit end)
    local left_to_take = units
    for i = 1, #rest do
        local take = min(rest[i].qty, left_to_take)
        rest[i].qty, left_to_take = rest[i].qty - take, left_to_take - take
    end
    local lowest = nil
    for i = 1, #rest do if rest[i].qty > 0 then lowest = rest[i].unit break end end
    local post = P.post_price({ market = m.obs.usual, lowest = lowest, vendor = m.vendor, cost = unit_cost,
        cut_pct = CUT, margin_pct = 10, undercut = 1, ceiling_pct = 200, ceiling = plan.ceiling })
    local level, left, proceeds, fees, last_h = m.level, units, 0, 0, 0
    local deposit = dep_total(m, units) / units
    if post then
        fees = deposit * units
        flows[#flows + 1] = { 0, -deposit * units, 0 }
        local ahead, ahead_price, reposts = 0, nil, 0
        local floor_unit = max(m.vendor, unit_cost)
        for hour = 1, 192 do
            last_h = hour
            if hour % 24 == 1 then reposts = 0 end
            level = level * exp(m.drift / 24 + m.sigma / sqrt(24) * normal())
            if rand() < 0.3 then
                local theirs = level * (0.9 + 0.15 * rand())
                if theirs < post then
                    ahead = ahead + (m.stack > 1 and (1 + floor(10 * rand())) or 1)
                    ahead_price = min(ahead_price or theirs, theirs)
                end
            end
            if ahead > 0 and reposts < 3 then
                local again = floor(ahead_price - 1)
                if (again * (1 - CUT / 100) - floor_unit) * left > deposit * left then
                    post, ahead, ahead_price, reposts = again, 0, nil, reposts + 1
                    fees = fees + deposit * left
                    flows[#flows + 1] = { hour, -deposit * left, 0 }
                end
            end
            local demand = 0
            for _ = 1, poisson(m.buyers / 24) do demand = demand + purchase_size(m) end
            if post > level * 1.15 then demand = 0 end
            local first = min(ahead, demand)
            ahead, demand = ahead - first, demand - first
            local mine = min(left, demand)
            if mine > 0 then
                left = left - mine
                local got = mine * post * (1 - CUT / 100)
                proceeds, fees = proceeds + got, fees - deposit * mine
                flows[#flows + 1] = { hour + 1, got + deposit * mine, -unit_cost * mine }
            end
            if left == 0 then break end
            if hour % 48 == 0 and hour < 192 then
                local again = min(post, level * 0.98)
                if again * (1 - CUT / 100) > unit_cost then
                    post, ahead = again, 0
                    fees = fees + deposit * left
                    flows[#flows + 1] = { hour, -deposit * left, 0 }
                else
                    break
                end
            end
        end
    end
    if left > 0 then
        local got = (m.vendor > 0 and m.vendor >= level * (1 - CUT / 100)) and left * m.vendor
            or left * level * (1 - CUT / 100)
        proceeds = proceeds + got
        flows[#flows + 1] = { last_h + 24, got, -unit_cost * left }
    end
    return proceeds - cost - fees, flows
end

--- One stream: arrivals and merchant visits, from `s`.
local function build_stream(s, rate, days)
    seed = s
    local steps = floor(days * 24 / STEP_H + 0.5)
    local opps, visits = {}, {}
    for st = 0, steps - 1 do
        for _ = 1, poisson(rate * STEP_H) do
            local m = make_market()
            m.future = floor(rand() * 2147483645) + 1
            local life = -log(1 - rand() * 0.999999) * 2
            opps[#opps + 1] = { m = m, at = st, untl = st + max(1, floor(life / STEP_H + 0.5)), id = #opps + 1 }
        end
    end
    local t = 0
    while t < steps + 2000 do
        t = t + max(1, floor(-log(1 - rand() * 0.999999) * 24 / STEP_H + 0.5))
        visits[#visits + 1] = t
    end
    return { opps = opps, visits = visits, steps = steps }
end

local C0 = 49010

local function run_stream(stream, rule)
    local gold, stock, swept = C0, 0, 0
    local pending, lots, open_vendor, visible, bought, cache = {}, {}, {}, {}, {}, {}
    local oi, vi = 1, 1
    for st = 0, stream.steps + 960 do
        for _, f in ipairs(pending[st] or {}) do gold, stock = gold + f[1], stock + f[2] end
        pending[st] = nil
        while vi <= #stream.visits and stream.visits[vi] <= st do
            for i = #open_vendor, 1, -1 do
                gold, stock = gold + open_vendor[i].cost + open_vendor[i].made, stock - open_vendor[i].cost
                open_vendor[i] = nil
            end
            vi = vi + 1
        end
        if gold + stock > C0 then
            local take = min(gold, gold + stock - C0)
            gold, swept = gold - take, swept + take
        end
        if st < stream.steps then
            while oi <= #stream.opps and stream.opps[oi].at <= st do
                visible[#visible + 1] = stream.opps[oi]
                oi = oi + 1
            end
            for i = #visible, 1, -1 do
                if visible[i].untl <= st or bought[visible[i].id] then table.remove(visible, i) end
            end
            local cap = capital_of(gold, stock)
            local list = {}
            for _, o in ipairs(visible) do
                if cache[o.id] == nil then cache[o.id] = plan_market(o.m, rule, math.huge) or false end
                local d = cache[o.id]
                if d and d.profit >= least(rule, cap.capital, d) then
                    local s = plan_sized(o.m, rule, cap, cap.max_deal)
                    if s then list[#list + 1] = { o = o, big = rule.final and s.big, key = s.key } end
                end
            end
            table.sort(list, function(a, b) return a.key > b.key end)
            for _, it in ipairs(list) do
                cap = capital_of(gold, stock)
                local budget = (rule.final and not it.big) and cap.max_small or cap.max_deal
                local plan = plan_sized(it.o.m, rule, cap, budget)
                if plan then
                    bought[it.o.id] = true
                    gold, stock = gold - plan.cost, stock + plan.cost
                    local L = { cost = plan.cost, mode = plan.mode, big = rule.final and plan.big }
                    if plan.mode == "vendor" then
                        L.made = plan.units * it.o.m.vendor - plan.cost
                        open_vendor[#open_vendor + 1] = L
                    else
                        local save = seed
                        seed = it.o.m.future
                        local made, flows = play48(it.o.m, plan)
                        seed = save
                        L.made = made
                        for _, f in ipairs(flows) do
                            if f[1] <= 0 then gold, stock = gold + f[2], stock + f[3] else
                                local at = st + max(1, math.ceil(f[1] / STEP_H))
                                pending[at] = pending[at] or {}
                                pending[at][#pending[at] + 1] = { f[2], f[3] }
                            end
                        end
                    end
                    lots[#lots + 1] = L
                end
            end
        end
    end
    for _, l in pairs(pending) do for _, f in ipairs(l) do gold, stock = gold + f[1], stock + f[2] end end
    for _, L in ipairs(open_vendor) do gold, stock = gold + L.cost + L.made, stock - L.cost end
    local r = { gain = gold + stock + swept - C0, lots = #lots, ok = 0, worst = 0, big = 0, big_made = 0, made = 0 }
    for _, L in ipairs(lots) do
        if L.made > 0 then r.ok = r.ok + 1 end
        r.worst = min(r.worst, L.made)
        r.made = r.made + L.made
        if L.big then r.big, r.big_made = r.big + 1, r.big_made + L.made end
    end
    return r
end

local STREAM_DAYS, STREAM_SEEDS = 7, 2
local STREAM_GAIN = { [15] = 1.20, [60] = 1.30 }  -- measured: 1.39x and 1.54x
local stream_results = {}

T[#T + 1] = { "stream backtest: Auto's money rules on Forever's 48-hour posts, 4g 90s of capital", function()
    local saved = seed
    print("")
    print(string.format("  Stream backtest: %d streams x %d days, 4g 90s 10c held, deals live ~2 h, a merchant a day:",
        STREAM_SEEDS, STREAM_DAYS))
    for _, rate in ipairs({ 15, 60 }) do
        local agg = {}
        for sd = 1, STREAM_SEEDS do
            local stream = build_stream(20261008.0 + sd * 7919.0 + rate, rate, STREAM_DAYS)
            for i, rule in ipairs(RULES) do
                local r = run_stream(stream, rule)
                local a = agg[i] or { gain = 0, lots = 0, ok = 0, worst = 0, big = 0, big_made = 0, made = 0 }
                a.gain, a.lots, a.ok = a.gain + r.gain, a.lots + r.lots, a.ok + r.ok
                a.worst, a.big, a.big_made, a.made = min(a.worst, r.worst), a.big + r.big, a.big_made + r.big_made,
                    a.made + r.made
                agg[i] = a
            end
        end
        stream_results[rate] = agg
        for i, rule in ipairs(RULES) do
            local a = agg[i]
            print(string.format("    %2d markets/h  %-16s %8.2fg a day  %4d lots  %6.2f%% made money  worst %+7.2fg%s",
                rate, rule.name, a.gain / 10000 / (STREAM_SEEDS * STREAM_DAYS), a.lots, a.ok / max(1, a.lots) * 100,
                a.worst / 10000, rule.final and string.format("  big money: %d lots, %.0f%% of what lots made", a.big,
                    a.big_made / max(1, a.made) * 100) or ""))
        end
    end
    seed = saved
end }

T[#T + 1] = { "the 1.1.0 rules make more money in the stream, and keep 98% of lots profitable", function()
    for _, rate in ipairs({ 15, 60 }) do
        local cur, fin = stream_results[rate][1], stream_results[rate][2]
        assert(fin.ok / fin.lots >= 0.98, string.format("%d/h: 1.1.0 lots made money %.2f%%", rate, fin.ok / fin.lots * 100))
        assert(cur.ok / cur.lots >= 0.98, string.format("%d/h: 1.0 lots made money %.2f%%", rate, cur.ok / cur.lots * 100))
        assert(fin.gain >= cur.gain * STREAM_GAIN[rate], string.format("%d/h: 1.1.0 made %.0f, 1.0 %.0f", rate, fin.gain,
            cur.gain))
        assert(fin.worst >= cur.worst - 2000, string.format("%d/h: worst lot %.0f vs %.0f", rate, fin.worst, cur.worst))
        assert(fin.big > 0 and fin.big_made >= 0.5 * fin.made, string.format("%d/h: big money made %.0f of %.0f", rate,
            fin.big_made, fin.made))
    end
end }

return T

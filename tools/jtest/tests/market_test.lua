-- Jambix Market (scripts/jambix_market) on JCore as the Forever client,
-- against a fake auction house that answers the way C_AuctionHouse does
-- there: 0-based replicate rows, 0-based time-left bands, an event for each
-- search, a quote event for a commodity purchase, AUCTION_HOUSE_AUCTION_CREATED
-- for a post. The arithmetic (modules/pricing.lua) is tested on its own first.
--
-- The tests run in ORDER inside one Lua state. Era is market_era_test.lua.

local mock = require("mock_core")
mock.install()
mock.frame_dt = 0.05
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
local bag_helper = { rows = {} }
function bag_helper.get_character_bag_slots(self) return self.rows end
package.loaded["common/utility/inventory_helper"] = bag_helper
package.loaded["common/utility/icons_helper"] = {
    get_spell_icon_name = function() return nil end, draw_spell_icon = function() return false end,
}
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

local P = require("jambix_market/modules/pricing")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_near(got, want, tol, label)
    if type(got) ~= "number" or math.abs(got - want) > tol then
        error(string.format("%s: expected %s (+-%s), got %s", label, tostring(want), tostring(tol), tostring(got)), 2)
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

-- --- the player: gold and one backpack ------------------------------------------

local gold = 5000000             -- 500g
mock.core.inventory.get_gold = function() return gold end

local bag = {}                   -- backpack slot -> { id, guid, stack, at, present }
local in_bag0 = {}

local function item_obj(e)
    local methods = {
        get_item_id = function() return e.id end,
        get_guid = function() return e.guid end,
        get_item_stack_count = function() return e.stack end,
    }
    return setmetatable({}, { __index = function(_, k) return methods[k] end })
end

local function sync_bags()
    local rows, items = {}, {}
    for slot = 1, 16 do
        local e = bag[slot]
        if e then
            if e.present then
                rows[#rows + 1] = { item = item_obj(e), bag_id = 0, bag_slot = slot, stack_count = e.stack }
            end
            items[#items + 1] = { object = item_obj(e), slot_id = e.at }
        end
    end
    bag_helper.rows = rows
    in_bag0 = items
end
mock.core.inventory.get_items_in_bag = function(b) if b == 0 then return in_bag0 end return {} end

local function put_in_bag(slot, id, guid, stack)
    bag[slot] = { id = id, guid = guid, stack = stack, at = 34 + slot, present = true }
    sync_bags()
end

--- An item leaves its place: posted, sold, mailed.
local function take_out(slot)
    local e = bag[slot]
    e.present, e.at = false, 0
    sync_bags()
end

-- --- the fake auction house --------------------------------------------------------------

local LINEN, COPPER, LEATHER, ORE, SWORD = 2589, 2840, 4234, 2772, 9999

local ah = {
    open = false, list = {}, ready = false, commodity = {}, items = {}, owned = {},
    calls = {}, events = {}, quote = nil, next_aid = 777,
    info = {
        [LINEN] = { name = "Linen Cloth", vendor = 13 },
        [COPPER] = { name = "Copper Bar", vendor = 10 },
        [LEATHER] = { name = "Heavy Leather", vendor = 6000 },
        [ORE] = { name = "Iron Ore", vendor = 50 },
        [SWORD] = { name = "Iron Sword", vendor = 8000, stack = 1 },
    },
}

local function log_call(...) ah.calls[#ah.calls + 1] = { ... } end
local function later(name, args) ah.events[#ah.events + 1] = { name, args or {} } end
local function count_calls(name)
    local n = 0
    for _, c in ipairs(ah.calls) do if c[1] == name then n = n + 1 end end
    return n
end
local function last_call(name)
    for i = #ah.calls, 1, -1 do if ah.calls[i][1] == name then return ah.calls[i] end end
    return nil
end

ah.on_post = function(_, s, qty)
    local e = bag[s]
    if e and qty and qty < e.stack then
        e.stack = e.stack - qty
        sync_bags()
    else
        take_out(s)
    end
end
local default_on_post = ah.on_post

mock.core.auction_house = {
    is_auction_house_shown = function() return ah.open end,
    is_throttled_message_system_ready = function() return true end,
    replicate_items = function()
        log_call("replicate_items")
        ah.ready = true
        later("REPLICATE_ITEM_LIST_UPDATE")
    end,
    get_num_replicate_items = function() return ah.ready and #ah.list or 0 end,
    get_replicate_item_info = function(i)
        local r = ah.ready and ah.list[i + 1]
        if not r then return {} end
        return { item_id = r.id, count = r.count, buyout_price = r.unit * r.count, owner = r.owner,
            name = ah.info[r.id] and ah.info[r.id].name, quality_id = 1, level = 0, has_all_info = true }
    end,
    get_replicate_item_time_left = function(i)
        local r = ah.list[i + 1]
        return r and r.band or 0
    end,
    send_search_query = function(id)
        log_call("send_search_query", id)
        later(ah.commodity[id] and "COMMODITY_SEARCH_RESULTS_UPDATED" or "ITEM_SEARCH_RESULTS_UPDATED", { id })
    end,
    get_num_commodity_search_results = function(id) return ah.commodity[id] and #ah.commodity[id] or 0 end,
    get_commodity_search_result_info = function(id, i)
        local r = ah.commodity[id][i]
        return { item_id = id, quantity = r.qty, unit_price = r.unit, auction_id = r.aid,
            num_owner_items = r.own or 0, contains_owner_item = (r.own or 0) > 0 }
    end,
    has_full_commodity_search_results = function() return true end,
    get_num_item_search_results = function(id) return ah.items[id] and #ah.items[id] or 0 end,
    get_item_search_result_info = function(id, _, _, i)
        local r = ah.items[id][i]
        return { item_id = id, auction_id = r.aid, quantity = r.qty, buyout_amount = r.buyout, bid_amount = 0,
            min_bid = r.buyout, time_left = 3, contains_owner_item = r.own or false }
    end,
    has_full_item_search_results = function() return true end,
    start_commodities_purchase = function(id, qty)
        log_call("start_commodities_purchase", id, qty)
        local total, left = 0, qty
        for _, r in ipairs(ah.commodity[id]) do
            if left <= 0 then break end
            local q = math.min(left, r.qty)
            total, left = total + q * r.unit, left - q
        end
        ah.pending_total = ah.quote or total
        later("COMMODITY_PRICE_UPDATED", { math.floor(ah.pending_total / qty), ah.pending_total })
    end,
    confirm_commodities_purchase = function(id, qty)
        log_call("confirm_commodities_purchase", id, qty)
        gold = gold - ah.pending_total
        local left, rows = qty, ah.commodity[id] or {}
        while left > 0 and rows[1] do
            local take = math.min(left, rows[1].qty)
            rows[1].qty, left = rows[1].qty - take, left - take
            if rows[1].qty <= 0 then table.remove(rows, 1) end
        end
        later("COMMODITY_PURCHASE_SUCCEEDED")
    end,
    cancel_commodities_purchase = function() log_call("cancel_commodities_purchase") end,
    place_bid = function(aid, amount)
        log_call("place_bid", aid, amount)
        gold = gold - amount
        for _, rows in pairs(ah.items) do
            for i = #rows, 1, -1 do if rows[i].aid == aid then table.remove(rows, i) end end
        end
    end,
    get_item_commodity_status = function() return 2 end,
    post_commodity = function(b, s, duration, qty, unit)
        log_call("post_commodity", b, s, duration, qty, unit)
        local aid = ah.next_aid
        ah.next_aid = aid + 1
        ah.owned[#ah.owned + 1] = { auction_id = aid, item_id = bag[s] and bag[s].id, quantity = qty,
            buyout_amount = unit, bid_amount = 0, status = 0, time_left = 3 }
        ah.on_post(b, s, qty)
        gold = gold - 60
        later("AUCTION_HOUSE_AUCTION_CREATED", { aid })
        return true
    end,
    post_item = function(b, s, duration, qty, bid, buyout)
        log_call("post_item", b, s, duration, qty, bid, buyout)
        ah.on_post(b, s)
        later("AUCTION_HOUSE_AUCTION_CREATED", { 778 })
        return true
    end,
    query_owned_auctions = function()
        log_call("query_owned_auctions")
        later("OWNED_AUCTIONS_UPDATED")
    end,
    get_num_owned_auctions = function() return #ah.owned end,
    get_owned_auction_info = function(i) return ah.owned[i] end,
    can_cancel_auction = function() return true end,
    cancel_auction = function(aid)
        log_call("cancel_auction", aid)
        gold = gold - 60
        for i = #ah.owned, 1, -1 do
            if ah.owned[i].auction_id == aid then table.remove(ah.owned, i) end
        end
        later("AUCTION_CANCELED", { aid })
    end,
    get_cancel_cost = function() return 60 end,
    get_item_info = function(id)
        local i = ah.info[id]
        if not i then return {} end
        return { name = i.name, sell_price = i.vendor or 0, quality = 1, stack_count = i.stack or 20,
            bind_type = 0, class_id = 7 }
    end,
}

--- Runs `seconds` of frames, delivering the fake server's events between them.
local function run(seconds)
    local n = math.max(1, math.floor(seconds / mock.frame_dt + 0.5))
    for _ = 1, n do
        mock.frame(1)
        if #ah.events > 0 then
            local evs = ah.events
            ah.events = {}
            for _, e in ipairs(evs) do mock.game_event(e[1], e[2]) end
        end
    end
end

local function listing(id, owner, count, unit, band)
    return { id = id, owner = owner, count = count, unit = unit, band = band }
end

-- Scan one: Iron Ore at 100s from four sellers. Bands count from 0 (retail).
local SCAN_ONE = {
    listing(LINEN, "A", 20, 100, 3), listing(LINEN, "B", 20, 110, 3), listing(LINEN, "C", 20, 120, 2),
    listing(LINEN, "D", 20, 500, 3),
    listing(COPPER, "X", 10, 1000, 3), listing(COPPER, "Y", 10, 1100, 3), listing(COPPER, "Z", 5, 1200, 0),
    listing(ORE, "E", 10, 10000, 3), listing(ORE, "F", 10, 10000, 3), listing(ORE, "G", 10, 10200, 2),
    listing(ORE, "H", 10, 10400, 3),
}

-- Scan two, 2000 s later: E's ore sold (very long band: cannot have expired)
-- and 4 of H's -- two buyers -- A sold 15 of 20 linen, Z's copper (under 30
-- min left) went -- unclear, not a sale. Someone listed 5 ore at 40s, and
-- Heavy Leather at 15s a vendor buys for 60s.
local SCAN_TWO = {
    listing(LINEN, "A", 5, 100, 3), listing(LINEN, "B", 20, 110, 3), listing(LINEN, "C", 20, 120, 2),
    listing(LINEN, "D", 20, 500, 3),
    listing(COPPER, "X", 10, 1000, 3), listing(COPPER, "Y", 10, 1100, 3),
    listing(ORE, "Cheap", 5, 4000, 3), listing(ORE, "F", 10, 10000, 3), listing(ORE, "G", 10, 10200, 2),
    listing(ORE, "H", 6, 10400, 3),
    listing(LEATHER, "W", 3, 1500, 3),
}

-- Scan three, 2000 s after scan two: B sold 5 linen, and three more buyers
-- took ore from F, G and H. The cheap ore is still there, and now the ore
-- has been seen in three scans over more than an hour, selling to four
-- buyers in two of them (G's had under two hours left, so its two might
-- have expired: not a sale).
local THIRD_SCAN_SOLD = { [LINEN] = { B = 5 }, [ORE] = { F = 3, G = 2, H = 2 } }
local SCAN_THREE = {}
for i, l in ipairs(SCAN_TWO) do
    local gone = THIRD_SCAN_SOLD[l.id] and THIRD_SCAN_SOLD[l.id][l.owner] or 0
    SCAN_THREE[i] = listing(l.id, l.owner, l.count - gone, l.unit, l.band)
end

local JCore, MK

local T = {}

-- =============================================================================
-- the arithmetic
-- =============================================================================

T[#T + 1] = { "market value: the cheap end, an outlier left out", function()
    local m, low, qty = P.market_value({
        { unit = 100, qty = 20 }, { unit = 110, qty = 20 }, { unit = 120, qty = 20 }, { unit = 500, qty = 20 },
    })
    assert_eq(low, 100, "lowest")
    assert_eq(qty, 80, "units")
    -- 15% of 80 = 12 units, then up to 24 while each step is under 20%:
    -- 20 at 100 and 4 at 110. The 110s sit more than 1.5 standard deviations
    -- above that set's mean (101.7, sd 3.7), so they drop out: 100.
    assert_eq(m, 100, "market")
    local none = P.market_value({ { unit = 0, qty = 5 } })
    assert_eq(none, nil, "bid-only listings have no market value")
    -- A lone absurd buyout above a wall of normal ones is dropped by sigma.
    local rows = {}
    for i = 1, 9 do rows[i] = { unit = 1000, qty = 1 } end
    rows[10] = { unit = 1000000, qty = 1 }
    assert_eq(P.market_value(rows), 1000, "the absurd one does not count")
end }

T[#T + 1] = { "sales between scans: gone with time left is sold, gone near expiry is unclear", function()
    local before = {
        { unit = 100, qty = 20, owner = "A", band = 4 }, { unit = 1200, qty = 5, owner = "Z", band = 1 },
        { unit = 300, qty = 10, owner = "Q", band = 3 },
    }
    local after = { { unit = 100, qty = 5, owner = "A", band = 4 }, { unit = 300, qty = 10, owner = "Q", band = 3 },
        { unit = 90, qty = 7, owner = "N", band = 4 } }
    local sold, unclear, added = P.sales_between(before, after, 1200)
    assert_eq(sold, 15, "A's 15 sold: 12 h+ left cannot expire in 20 min")
    assert_eq(unclear, 5, "Z's 5 had under 30 min: unclear")
    assert_eq(added, 7, "N listed 7")
    -- Over three hours, a 2-12 h band could have run out.
    local s2, u2 = P.sales_between({ { unit = 1, qty = 4, owner = "a", band = 3 } }, {}, 3 * 3600)
    assert_eq(s2, 0, "2-12 h band after 3 h: not provably sold")
    assert_eq(u2, 4, "unclear")
end }

T[#T + 1] = { "post price: undercut, ceiling, floor, vendor", function()
    local p, why = P.post_price({ market = 1000, lowest = 950, vendor = 10, cut_pct = 5, undercut = 1 })
    assert_eq(p, 949, "undercut by 1c: " .. why)
    p = P.post_price({ market = 1000, lowest = 5000, vendor = 10, cut_pct = 5, ceiling_pct = 200 })
    assert_eq(p, 2000, "never above the ceiling")
    p = P.post_price({ market = 1000, vendor = 10, cut_pct = 5 })
    assert_eq(p, 1000, "nobody selling: market value")
    p, why = P.post_price({ market = 1000, lowest = 400, cost = 900, margin_pct = 10, cut_pct = 5 })
    assert_eq(p, nil, "below what you paid plus margin: hold")
    assert(why:find("floor"), why)
    p = P.post_price({ market = 1000, lowest = 400, cost = 900, margin_pct = 10, cut_pct = 5, below_floor = "floor" })
    assert_near(p, 900 * 1.1 / 0.95, 1, "or post at the floor")
    p, why = P.post_price({ market = 100, lowest = 100, vendor = 120, cut_pct = 5 })
    assert_eq(p, nil, "a vendor pays more")
    assert_eq(why, "worth more at a vendor", "why")
end }

T[#T + 1] = { "plan_vendor: buys what a vendor pays more for, skips your own", function()
    local plan = P.plan_vendor({ { unit = 1500, qty = 3 }, { unit = 1000, qty = 2, own = true },
        { unit = 7000, qty = 1 } }, { vendor = 6000, min_margin_pct = 5 })
    assert_eq(plan.units, 3, "units")
    assert_eq(plan.cost, 4500, "cost")
    assert_eq(plan.profit, 3 * 6000 - 4500, "profit")
    local capped = P.plan_vendor({ { unit = 1500, qty = 3, buyout = 4500 } },
        { vendor = 6000, budget = 4000, whole = true })
    assert_eq(capped.units, 0, "an item auction is bought whole or not at all")
end }

T[#T + 1] = { "plan_flip: two cheap stacks under a wall are bought together", function()
    local rows = { { unit = 100, qty = 1 }, { unit = 105, qty = 1 }, { unit = 1000, qty = 10 } }
    local plan = P.plan_flip(rows, { reference = 900, cut_pct = 5, undercut = 1, min_margin_pct = 25 })
    assert_eq(plan.units, 2, "both cheap ones")
    assert_eq(plan.resale, 900, "resold at the usual price (under the 1000 wall)")
    assert_near(plan.profit, 2 * 900 * 0.95 - 205, 0.01, "profit")
    local thin = P.plan_flip({ { unit = 100, qty = 1 }, { unit = 110, qty = 5 } },
        { reference = 900, cut_pct = 5, undercut = 1, min_margin_pct = 25, max_units = 1 })
    assert_eq(thin.units, 0, "one unit before a seller at 110: not worth it")
end }

T[#T + 1] = { "risk maths: normal and Poisson tails", function()
    assert_near(P.phi(0), 0.5, 1e-6, "phi(0)")
    assert_near(P.phi(1.96), 0.975, 1e-3, "phi(1.96)")
    assert_near(P.phi(-2.326), 0.01, 1e-3, "phi(-2.326)")
    assert_near(P.poisson_at_least(1, 5), 1 - math.exp(-5), 1e-9, "P(N>=1), lambda 5")
    assert_near(P.poisson_at_least(2, 1), 1 - 2 * math.exp(-1), 1e-9, "P(N>=2), lambda 1")
    assert_eq(P.poisson_at_least(0, 0), 1, "nothing to sell")
    assert_eq(P.poisson_at_least(1, 0), 0, "nobody buying")
    assert_near(P.poisson_at_least(100, 200), 1, 1e-6, "far under the mean")
    assert_near(P.poisson_at_least(200, 200), 0.5, 0.03, "at the mean")
end }

T[#T + 1] = { "a seller repricing is not a sale", function()
    local sold, unclear, added, repriced = P.sales_between(
        { { unit = 100, qty = 10, owner = "R", band = 4 } },
        { { unit = 90, qty = 10, owner = "R", band = 4 } }, 1200)
    assert_eq(sold, 0, "R moved ten from 1s to 90c")
    assert_eq(repriced, 10, "a reprice")
    assert_eq(added, 0, "nothing new")
    -- Sold five, relisted the rest lower: five sold.
    sold, unclear, added, repriced = P.sales_between(
        { { unit = 100, qty = 10, owner = "R", band = 4 } },
        { { unit = 90, qty = 5, owner = "R", band = 4 } }, 1200)
    assert_eq(sold, 5, "five sold")
    assert_eq(repriced, 5, "five repriced")
end }

T[#T + 1] = { "how sure a resale is: price risk, demand, the vendor floor", function()
    local o = { cut_pct = 5, cv = 0.10, sales_per_day = 20, days = 1 }
    -- Bought at 50s, resold at 1g: far above break-even, plenty of buyers.
    assert(P.flip_confidence(o, 2, 10000, 10000) > 0.999, "sure")
    -- Resold at break-even: a coin toss on the price.
    assert_near(P.flip_confidence(o, 1, 9500, 10000), 0, 1e-9, "at break-even it cannot profit")
    -- A thin margin with a volatile price is not sure.
    o.cv = 0.30
    assert(P.flip_confidence(o, 1, 8000, 10000) < 0.9, "thin and volatile")
    -- Nobody buying: not sure at all.
    o.cv, o.sales_per_day = 0.10, 0
    assert_eq(P.flip_confidence(o, 1, 5000, 10000), 0, "no buyers")
    -- A vendor that pays more than it cost is a floor: sure either way.
    o.vendor, o.deposit_unit = 6000, 100
    assert_eq(P.flip_confidence(o, 1, 5000, 10000), 1, "the vendor floor")
end }

T[#T + 1] = { "several sellers gone cheap is the price moving, not a deal", function()
    local wall = { unit = 100, qty = 60 }
    local one = P.plan_flip({ { unit = 50, qty = 5 }, wall }, { usual = 100, cv = 0.05, cut_pct = 5,
        undercut = 1, min_margin_pct = 25, sales_per_day = 200, days = 1, min_confidence = 0.99 })
    assert_eq(one.units, 5, "one cheap listing: a deal")
    local shifted, level = P.level_shift({ { unit = 48, qty = 5 }, { unit = 50, qty = 5 }, { unit = 52, qty = 5 }, wall }, 100)
    assert(shifted, "three cheap listings agree")
    assert_eq(level, 50, "the price they agree on")
    local three = P.plan_flip({ { unit = 48, qty = 5 }, { unit = 50, qty = 5 }, { unit = 52, qty = 5 }, wall },
        { usual = 100, market = 60, cv = 0.05, cut_pct = 5, undercut = 1, min_margin_pct = 25,
          sales_per_day = 200, days = 1, min_confidence = 0.99 })
    assert_eq(three.units, 0, "not resold above the price three sellers set")
end }

T[#T + 1] = { "one buyer taking many is one sale, and lumpy sales are less sure", function()
    local before = { { unit = 100, qty = 53, owner = "", band = 4 }, { unit = 120, qty = 20, owner = "", band = 4 } }
    local sold, _, _, _, sales = P.sales_between(before, { { unit = 120, qty = 20, owner = "", band = 4 } }, 1200)
    assert_eq(sold, 53, "53 units left")
    assert_eq(sales, 1, "one purchase")
    -- The plugin's own purchase taken off: nothing left of it.
    local left, left_sales = P.sales_without(sold, sales, 53)
    assert_eq(left, 0, "no units")
    assert_eq(left_sales, 0, "no purchases")
    -- The same 20 units a day, as single units or as purchases of 10.
    local o = { cut_pct = 5, cv = 0.05, sales_per_day = 20, days = 1 }
    local single = P.flip_confidence(o, 10, 1000, 200)
    o.lot = 10
    local lumpy = P.flip_confidence(o, 10, 1000, 200)
    assert(single > 0.99, "as twenty buyers: " .. single)
    assert(lumpy < 0.9, "as two buyers of ten: " .. lumpy)
    assert_eq(P.sales_needed(21, 10), 3, "21 units: three purchases of ten")
    assert_eq(P.sales_needed(20, 10), 2, "20 units: two")
end }

T[#T + 1] = { "a resale's profit is after the deposits it may lose", function()
    -- Seven cheap units under a wall at 100c: about 1s 50c before deposits.
    local rows = { { unit = 50, qty = 7 }, { unit = 100, qty = 100 } }
    local o = { usual = 100, cv = 0.05, cut_pct = 5, undercut = 1, min_margin_pct = 25,
        sales_per_day = 200, days = 1, min_confidence = 0.99 }
    local free = P.plan_flip(rows, o)
    assert_eq(free.units, 7, "all seven")
    o.post_fee, o.stack = 100, 20          -- Forever: 1s a post
    local paid = P.plan_flip(rows, o)
    assert_eq(paid.units, 7, "still all seven")
    assert_near(paid.profit, free.profit - 100, 0.01, "one deposit off the profit")
    assert_eq(paid.fees, 100, "kept with the plan")
    o.stack = 1                            -- one unit a post: seven deposits
    assert_eq(P.plan_flip(rows, o).units, 0, "seven posts' deposits eat it: no deal")
    assert_eq(P.post_fees(21, 100, 20), 200, "21 units in stacks of 20: two posts")
end }

T[#T + 1] = { "stock already held counts against what can sell in time", function()
    local rows = { { unit = 50, qty = 5 }, { unit = 100, qty = 100 } }
    local o = { usual = 100, cv = 0.05, cut_pct = 5, undercut = 1, min_margin_pct = 25,
        sales_per_day = 12, days = 1, min_confidence = 0.99 }
    assert_eq(P.plan_flip(rows, o).units, 5, "nothing held: the five")
    o.held = 20                              -- 20 already waiting to sell to the same buyers
    assert_eq(P.plan_flip(rows, o).units, 0, "with 20 held, five more are not sure to sell")
end }

T[#T + 1] = { "plan_flip buys no more than is sure to sell in time", function()
    -- 20 cheap units at 50c under a wall of 100 at 1s; 6 a day are believed to sell.
    local rows = { { unit = 50, qty = 20 }, { unit = 100, qty = 100 } }
    local plan = P.plan_flip(rows, { usual = 100, cv = 0.05, cut_pct = 5, undercut = 1, min_margin_pct = 25,
        sales_per_day = 6, days = 1, min_confidence = 0.99 })
    -- At most 1 unit is 99% sure (P(N>=2 | 6) = 0.983); buying 1 of the 20
    -- leaves 19 at 50c to compete with, so the resale cannot pay: no plan.
    assert_eq(plan.units, 0, "the cheap stack is too big to resell in a day")
    -- With 200 a day believed, all 20 are sure and resold at 99c.
    plan = P.plan_flip(rows, { usual = 100, cv = 0.05, cut_pct = 5, undercut = 1, min_margin_pct = 25,
        sales_per_day = 200, days = 1, min_confidence = 0.99 })
    assert_eq(plan.units, 20, "all twenty")
    assert_eq(plan.resale, 99, "under the wall")
    assert(plan.confidence >= 0.99, "sure: " .. plan.confidence)
end }

T[#T + 1] = { "Forever's deposit: max(1s, 60% of the vendor price x units), post by post", function()
    assert_eq(P.post_fees(8, 100, 20, 55, 0.6), 264, "8 Lion Meat (vendor 55c): the live post took 2s 64c")
    assert_eq(P.post_fees(17, 100, 20, 1, 0.6), 100, "17 Shiny Red Apples: the 1s minimum")
    assert_near(P.post_fees(2, 100, 20, 750, 0.6), 900, 1e-9, "2 Thick Spider's Silk: 9s")
    assert_near(P.post_fees(20, 100, 20, 33, 0.6), 396, 1e-9, "a stack of 20 Wool Cloth: 3s 96c")
    assert_near(P.post_fees(97, 100, 20, 33, 0.6), 4 * 396 + 0.6 * 33 * 17, 1e-9, "97 Wool Cloth: four stacks and 17")
    assert_eq(P.post_fees(53, 100, 20, 6, 0.6), 300, "53 Rockscale Cod: three posts at the minimum")
    assert_near(P.post_fees(10, 100, 10, 303, 0.6), 1818, 1e-9, "a stack of 10 Long Tail Feathers: 18s 18c")
    assert_eq(P.post_fees(53, 100, 20), 300, "without a rate: the flat deposit a post, as before")
    assert_eq(P.post_fees(0, 100, 20, 55, 0.6), 0, "nothing posted")
end }

T[#T + 1] = { "worth buying, and big money", function()
    -- At 4g 90s 10c of capital.
    assert_eq(P.worth_floor(49010, 0, 500), 500, "5s")
    assert_eq(P.worth_floor(49010, 720, 500), 1440, "6 Pearls' 48 h deposit is 7s 20c: twice that")
    assert_eq(P.worth_floor(1000000, 100, 500), 1000, "100g: 0.1% of capital")
    assert_eq(P.worth_floor(49010, 0, 1200), 1200, "the learned part, when small lots miss by more")
    assert_near(P.big_line(49010), 2450.5, 1e-9, "5% of 4g 90s 10c: 24s 50c")
    assert_eq(P.big_line(30000), 2000, "never under 20s")
    assert_eq(P.big_line(2000000), 100000, "200g: 10g")
    assert_eq(P.is_big(2500, 49010, 100), true, "24s 50c and more is big")
    assert_eq(P.is_big(2400, 49010, 100), false, "under it is not")
    assert_eq(P.is_big(12000, 49010, 3001), false, "nor under four times its deposits")
    -- Expected profit: what failing costs is in it.
    local plan = { mode = "flip", units = 2, confidence = 0.99, profit = 10000, cost = 20000, fees = 500 }
    assert_near(P.expected(plan, 0.3), 0.99 * 10000 - 0.01 * (20000 * 0.3 + 500), 1e-9, "p x profit - (1-p) x loss")
    assert_eq(P.expected({ mode = "vendor", units = 9, profit = 900, cost = 3600 }), 900, "a vendor flip: its profit")
    assert_near(P.return_rate(1000, 2000, 2), 0.25, 1e-12, "25% a day")
    assert_near(P.return_rate(1000, 2000, 0.1), 2, 1e-12, "a quarter day at least")
end }

T[#T + 1] = { "a resale may be judged over two posts, with a deposit planned for each", function()
    -- One cheap unit at 10s under a wall at 40s; 2.5 purchases a day believed.
    local rows = { { unit = 1000, qty = 1 }, { unit = 4000, qty = 10 } }
    local o = { usual = 4000, cv = 0.15, cut_pct = 5, undercut = 1, min_margin_pct = 25, sales_per_day = 2.5,
        days = 1, min_confidence = 0.99, post_fee = 100, stack = 20, survive = 2 }
    -- One day: P(a buyer) = 1 - e^-2.5 = 91.8%: not sure enough.
    assert_eq(P.plan_flip(rows, o).units, 0, "one post: no deal")
    o.posts = 2
    local plan = P.plan_flip(rows, o)
    assert_eq(plan.units, 1, "two posts: the one unit")
    assert_eq(plan.posts, 2, "judged over two posts")
    assert_eq(plan.fees, 200, "two deposits planned")
    assert_eq(plan.deposits, 100, "posting it once takes 1s")
    assert_near(plan.profit, 3999 * 0.95 - 1000 - 200, 1e-6, "profit after both")
    assert(plan.confidence >= 0.99 and plan.confidence < 1, "sure: " .. plan.confidence)
    -- A lot that two more lost deposits would turn into a loss is refused:
    -- 1300 x 0.95 - 1000 - 3 x 100 < 0, however sure it is.
    local sure_o = { cut_pct = 5, cv = 0.03, sales_per_day = 50, days = 1, min_confidence = 0.99 }
    assert_eq(select(2, P.judge_posts(sure_o, 1, 1000, 1300, 100, 2)), 1, "without the survive rule: one post")
    assert_eq(select(2, P.judge_posts(sure_o, 1, 1000, 1300, 100, 2, 2)), nil, "with it: refused")
end }

-- =============================================================================
-- the plugin, booted as Forever
-- =============================================================================

T[#T + 1] = { "boots on Forever and registers", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("JCore boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    -- The user's policy file before 1.1.0: a cut of 4.30% learned partly from a sale matched to the wrong post.
    mock.data_fs["jcore/jambix.market.policy.json"] = '{"cut": 4.3034380319801508, "cuts": 8, "bar": 0.99}'
    local ok2, err2 = pcall(require, "jambix_market/main")
    if not ok2 then error("market boot raised: " .. tostring(err2)) end
    run(1.5)
    fail_on_errors("boot")
    MK = _G.JambixMarket
    assert(MK, "_G.JambixMarket published")
    assert(JCore.is_running("jambix.market"), "registered and running")
    assert(MK.db.ready(), "the price file loaded once the realm read")
    assert(MK.window and MK.trader and MK.scanner, "modules built")
    -- No trading settings: the policy decides, from the gold (500g here).
    run(2.5)                                 -- gold is read every two seconds
    local Pol = MK.policy
    assert_eq(Pol.bar(), 0.99, "a 99% confidence bar to start")
    assert_eq(Pol.cut(), 5, "a 5% cut until a sale says otherwise (the old 4.30% is forgotten)")
    assert_near(Pol.min_profit(), 5000000 * 0.001, 0.01, "least profit: 0.1% of capital (50s)")
    assert_near(Pol.big_line(), 5000000 * 0.05, 0.01, "big money: 5% of capital (25g)")
    local cap = Pol.capital()
    assert_near(cap.reserve, 500000, 0.01, "keeps 10%")
    assert_near(cap.max_deal, 2500000, 0.01, "one deal: at most half of capital")
    -- Old setting ids are not read from the menu, whatever was saved.
    MK.menu:set("auto_buy", false)
    MK.menu:set("deal_min_profit_s", 99)
    assert_eq(MK.cfg("auto_buy", false), true, "Auto always buys")
    assert_eq(MK.money("undercut"), 1, "undercut fixed at 1c")
    MK.menu:set("auto_buy", true)
end }

T[#T + 1] = { "the clock: calendar dates to epoch seconds", function()
    local U = MK.util
    assert_eq(U.epoch_of({ year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0 }), 0, "1970")
    assert_eq(U.epoch_of({ year = 2000, month = 3, day = 1 }), 951868800, "2000-03-01")
    assert_eq(U.epoch_of({ year = 2026, month = 10, day = 7 }), 1791331200, "2026-10-07")
    assert_eq(U.money(123456), "12g 34s 56c", "money")
    assert_eq(U.money(1234567890), "123,456g 78s", "big money drops copper")
    assert_eq(U.money(-250), "-2s 50c", "negative")
    assert_eq(U.key(2589.0), "2589", "float ids key like integers")
end }

T[#T + 1] = { "opening the auction house starts a full scan and folds it in", function()
    ah.list = SCAN_ONE
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(6)
    fail_on_errors("scan one")
    assert_eq(count_calls("replicate_items"), 1, "one replicate")
    assert_eq(MK.db.meta().scans, 1, "one scan folded")
    local linen = MK.db.item(LINEN)
    assert(linen and linen.m, "Linen Cloth has a market value")
    assert_eq(linen.q, 80, "80 linen listed")
    assert_eq(linen.n, 100, "lowest 1s")
    assert(MK.window.is_visible(), "the window opened with the auction house")
    -- A second full scan inside 3 minutes is not tried.
    local ok, why = MK.scanner.start("test")
    assert_eq(ok, false, "too soon")
    assert(why:find("full scans run every 3m", 1, true), why)
    -- The info pump has named the items from get_item_info.
    run(1)
    assert_eq(MK.db.name(COPPER), "Copper Bar", "names")
    assert_eq(MK.db.vendor(LEATHER), nil, "Heavy Leather not seen yet")
end }

T[#T + 1] = { "the next scan, 2000 s on, estimates sales", function()
    ah.open = false
    mock.game_event("AUCTION_HOUSE_CLOSED", {})
    run(0.5)
    ah.ready = false
    mock.time = mock.time + 2000
    ah.list = SCAN_TWO
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(6)
    fail_on_errors("scan two")
    assert_eq(count_calls("replicate_items"), 2, "second replicate")
    assert_eq(MK.db.meta().scans, 2, "two scans")
    -- The two scans are 2000 s plus the few seconds the window was shut.
    local elapsed = MK.db.item(ORE).oa
    assert_near(elapsed, 2000, 15, "watched for the time between scans")
    local ore = MK.db.item(ORE)
    assert_near(MK.db.per_day(ore), 14 / elapsed * 86400, 0.5, "E's 10 ore and 4 of H's")
    assert_near(ore.ev, 2, 0.01, "two buyers, not fourteen")
    local linen = MK.db.item(LINEN)
    assert_near(MK.db.per_day(linen), 15 / elapsed * 86400, 0.5, "A's 15 linen")
    local copper = MK.db.item(COPPER)
    assert_eq(MK.db.per_day(copper), 0, "Z's copper might have expired: no sale")
    assert_near(copper.un, 5, 0.01, "counted as unclear")
    -- Heavy Leather's info arrives a tick or two after the scan.
    run(1)
    MK.deals.compute()
    assert(MK.deals.get(LEATHER), "a vendor flip needs no history")
    assert_eq(MK.deals.get(ORE), nil, "a resale needs three scans over an hour first")
end }

T[#T + 1] = { "an item seen selling to one buyer once is not judged at all", function()
    local now = MK.util.now()
    local rec = { c = 5, h = 1000, m = 1000, sa = 50, oa = 7200, ev = 1, eu = 50, eo = 7200, ei = 1,
        d = { { MK.util.day(now), 1000, 50, 900, 50, 5, 5 } } }
    local risk = MK.db.risk(rec)
    assert_eq(risk.mature, false, "one purchase of 50 proves nothing")
    rec.ev, rec.ei = 4, 2
    assert_eq(MK.db.risk(rec).mature, true, "four buyers over two scans do")
end }

T[#T + 1] = { "a third scan matures the data, and the resale is judged on its risk", function()
    ah.open = false
    mock.game_event("AUCTION_HOUSE_CLOSED", {})
    run(0.5)
    ah.ready = false
    mock.time = mock.time + 2000
    ah.list = SCAN_THREE
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(6)
    fail_on_errors("scan three")
    assert_eq(MK.db.meta().scans, 3, "three scans")
    local risk = MK.db.risk(MK.db.item(ORE))
    assert(risk.mature, "mature")
    assert_near(risk.sales, 4, 0.02, "four buyers seen (G's ore had under two hours left: it might have expired)")
    assert_near(risk.lot, 19 / 4, 0.01, "taking 4.75 each")
    assert(risk.usual and risk.usual > 9900, "its usual price, about 1g")
    assert(risk.market < 8000, "this scan's market value, dragged down by the cheap five")
    assert_near(risk.cv, 0.15, 0.001, "one day of history says nothing about how it moves: the 15% prior")
    run(1)
    MK.deals.compute()
    local leather = MK.deals.get(LEATHER)
    assert(leather, "Heavy Leather under vendor price is a deal")
    assert_eq(leather.mode, "vendor", "vendor flip")
    assert_eq(leather.units, 3, "all three")
    local ore_deal = MK.deals.get(ORE)
    assert(ore_deal, "the cheap ore is a resale deal")
    assert_eq(ore_deal.mode, "flip", "resale")
    assert_eq(ore_deal.units, 5, "the five cheap ones")
    assert(ore_deal.confidence >= 0.99, "at least 99% sure: " .. tostring(ore_deal.confidence))
    -- Judged against what is left once the five are bought (about 1g), capped
    -- at the usual price -- not against a market the cheap five drag down.
    assert_near(ore_deal.reference, risk.usual, 1, "planned against the usual price")
    assert_near(ore_deal.resale, risk.usual, 1, "resold at it, under the 1g wall")
    assert_eq(leather.confidence, 1, "a vendor flip is sure")
    assert(MK.deals.list()[1].score >= MK.deals.list()[2].score, "sorted by score")
    -- The same ore, if it sold two a day: not even one unit is 99% sure to
    -- sell within the day's auction, so nothing is bought.
    local rows = MK.db.previous().items[ORE]
    local slow = P.plan_flip(rows, { usual = risk.usual, market = risk.market, cv = risk.cv, cut_pct = 5,
        undercut = 1, min_margin_pct = 25, sales_per_day = 2 * 0.6, days = 1, min_confidence = 0.99 })
    assert_eq(slow.units, 0, "too slow a seller to be sure")
end }

local function activity_has(text)
    for _, a in ipairs(MK.activity_log()) do
        if a.text:find(text, 1, true) then return a.text end
    end
    return nil
end

T[#T + 1] = { "five minutes on, a quick scan re-checks what matters", function()
    -- The server's own listings for what will be searched, as the scan saw them.
    ah.commodity[LEATHER] = { { unit = 1500, qty = 3, aid = 501 } }
    ah.commodity[ORE] = { { unit = 4000, qty = 5, aid = 510 }, { unit = 10000, qty = 10, aid = 511 },
        { unit = 10200, qty = 10, aid = 512 }, { unit = 10400, qty = 10, aid = 513 } }
    ah.commodity[LINEN] = { { unit = 100, qty = 5, aid = 520 }, { unit = 110, qty = 15, aid = 521 },
        { unit = 120, qty = 20, aid = 522 }, { unit = 500, qty = 20, aid = 523 } }
    assert_eq(MK.cfg("scan_every", 3), 3, "a cycle every 3 minutes")
    -- A server that has shown it allows one full scan every 15 minutes.
    MK.db.meta().gap = 15 * 60
    local searches, scans = count_calls("send_search_query"), count_calls("replicate_items")
    mock.time = mock.time + 6 * 60
    run(6)
    fail_on_errors("quick scan")
    assert_eq(count_calls("replicate_items"), scans, "no full scan: the server allows one every 15 minutes")
    local q = MK.scanner.last_quick()
    assert(q, "a quick scan ran")
    assert(q.total >= 3, "the deals and the items that sell: " .. q.total)
    assert_eq(count_calls("send_search_query"), searches + q.total, "one search each")
    assert(activity_has("Quick scan: "), "said so")
    -- What it searched is fresh, so the deals are planned on it.
    local _, age = MK.ah.last(ORE)
    assert(age < 30, "ore searched just now")
    assert(MK.deals.get(ORE) and MK.deals.get(ORE).checked, "the ore deal re-planned on the fresh search")
    assert(MK.deals.get(LEATHER), "the leather deal still there")
end }

T[#T + 1] = { "a throttled full scan is thrown away, not folded in", function()
    -- Another addon used the account's full scan: the server sends no new
    -- list and no REPLICATE_ITEM_LIST_UPDATE; the client still holds the last.
    local real = mock.core.auction_house.replicate_items
    mock.core.auction_house.replicate_items = function() log_call("replicate_items") end
    local scans_before = MK.db.meta().scans
    local ore_watched = MK.db.item(ORE).oa
    local attempts = count_calls("replicate_items")
    mock.time = mock.time + 10 * 60            -- 16 minutes after the last full scan
    run(30)                                  -- the list never moves: thrown away unread at 25 s
    mock.core.auction_house.replicate_items = real
    fail_on_errors("throttled")
    assert_eq(count_calls("replicate_items"), attempts + 1, "it asked")
    assert_eq(MK.db.meta().scans, scans_before, "nothing folded in")
    assert_eq(MK.db.item(ORE).oa, ore_watched, "no sales estimate moved")
    assert(activity_has("Full scan not used"), "said why")
    local ok, why = MK.scanner.can_start()
    assert_eq(ok, false, "not asked again at once")
    assert(why:find("trying again"), why)
    assert(MK.scanner.last_quick().at > mock.time - 30, "a quick scan instead")
end }

T[#T + 1] = { "the old list is thrown away even when the update event fires", function()
    -- Forever fires REPLICATE_ITEM_LIST_UPDATE on its own (the user's
    -- recorder, 2026-10-07): the event does not make the old list a new one.
    local real = mock.core.auction_house.replicate_items
    mock.core.auction_house.replicate_items = function()
        log_call("replicate_items")
        later("REPLICATE_ITEM_LIST_UPDATE")
    end
    local scans_before = MK.db.meta().scans
    local ore_watched = MK.db.item(ORE).oa
    local attempts = count_calls("replicate_items")
    mock.time = mock.time + 6 * 60           -- past the retry after the throttled attempt
    run(30)
    mock.core.auction_house.replicate_items = real
    fail_on_errors("evented stale")
    assert_eq(count_calls("replicate_items"), attempts + 1, "it asked")
    assert_eq(MK.db.meta().scans, scans_before, "nothing folded in")
    assert_eq(MK.db.item(ORE).oa, ore_watched, "no sales estimate moved")
    assert(activity_has("sent the last list again"), "said why")
end }

T[#T + 1] = { "a full-scan list that changes while it is read is read again", function()
    local real = mock.core.auction_house.replicate_items
    local first, second = {}, {}
    for i, l in ipairs(SCAN_THREE) do first[i], second[i] = l, l end
    first[#first + 1] = listing(12345, "Q", 1, 777, 3)            -- 12 auctions...
    second[#second + 1] = listing(12345, "Q", 1, 777, 3)
    second[#second + 1] = listing(12346, "R", 1, 888, 3)          -- ...13 once the rest lands
    mock.core.auction_house.replicate_items = function()
        log_call("replicate_items")
        ah.list = first                      -- no event: Forever sends none
    end
    local scans = MK.db.meta().scans
    mock.time = mock.time + 6 * 60           -- past the retry after the throttled attempt
    for _ = 1, 400 do
        run(0.05)
        if MK.scanner.progress() == "reading" then break end
    end
    assert_eq(MK.scanner.progress(), "reading", "reading the first list")
    ah.list = second                         -- the rest of the list lands mid-read
    run(10)
    mock.core.auction_house.replicate_items = real
    fail_on_errors("re-read")
    assert_eq(MK.db.meta().scans, scans + 1, "one scan folded")
    assert_eq(MK.db.meta().rows, #second, "the whole list, read again: " .. tostring(MK.db.meta().rows))
    ah.list = SCAN_THREE
end }

T[#T + 1] = { "a search nobody answers is not 'nothing listed'", function()
    local real = mock.core.auction_house.send_search_query
    mock.core.auction_house.send_search_query = function(id) log_call("send_search_query", id) end
    local saved = ah.commodity[LINEN]
    ah.commodity[LINEN] = nil                 -- and nothing comes back
    local lowest = MK.db.item(LINEN).n
    local got, why = "unset", nil
    MK.ah.search(LINEN, { front = true }, function(result, w) got, why = result, w end)
    run(8)
    mock.core.auction_house.send_search_query = real
    ah.commodity[LINEN] = saved
    fail_on_errors("timeout")
    assert_eq(got, nil, "no result")
    assert_eq(why, "timed out", "the caller hears why")
    assert_eq(MK.db.item(LINEN).n, lowest, "the cheapest price is not wiped")
end }

T[#T + 1] = { "a quote over what the plan may spend is refused", function()
    local plan = { mode = "vendor", units = 10, cost = 1000, value = 5000, profit = 4000, min_profit = 1,
        budget = 1000, resale = 500, confidence = 1 }
    assert_eq(MK.trader.quote_ok(plan, 1000), true, "at the plan")
    assert_eq(MK.trader.quote_ok(plan, 1100), false, "over its budget")
    plan.budget = 1200
    assert_eq(MK.trader.quote_ok(plan, 1100), true, "within its budget, still paying")
end }

T[#T + 1] = { "buying a commodity: searched again, quote checked, confirmed, recorded", function()
    ah.commodity[LEATHER] = { { unit = 1500, qty = 3, aid = 501 } }
    local before = gold
    local ok, why = MK.trader.buy(LEATHER, { manual = true })
    assert(ok, tostring(why))
    run(3)
    fail_on_errors("buy leather")
    assert_eq(last_call("send_search_query")[2], LEATHER, "searched first")
    local start = last_call("start_commodities_purchase")
    assert(start, "purchase started")
    assert_eq(start[3], 3, "three units")
    assert(last_call("confirm_commodities_purchase"), "confirmed")
    assert_eq(before - gold, 4500, "paid 45s")
    local trades = MK.ledger.trades()
    assert_eq(trades[#trades].kind, "buy", "recorded")
    assert_eq(trades[#trades].copper, 4500, "at what it cost")
    assert_near(MK.ledger.cost_basis(LEATHER), 1500, 0.01, "held at 15s each")
    assert_eq(trades[#trades].expected, 3 * 6000 - 4500, "the profit expected: a vendor pays 60s each")
    -- Bought out: the fake server no longer lists it.
    ah.commodity[LEATHER] = {}
end }

T[#T + 1] = { "a quote above the plan is cancelled, nothing bought", function()
    ah.commodity[ORE] = { { unit = 4000, qty = 5, aid = 510 }, { unit = 10000, qty = 10, aid = 511 },
        { unit = 10200, qty = 10, aid = 512 }, { unit = 10400, qty = 10, aid = 513 } }
    ah.quote = 30000
    local before, confirms = gold, count_calls("confirm_commodities_purchase")
    assert(MK.trader.buy(ORE, { manual = true }), "queued")
    run(3)
    ah.quote = nil
    fail_on_errors("price moved")
    assert_eq(count_calls("cancel_commodities_purchase"), 1, "cancelled")
    assert_eq(count_calls("confirm_commodities_purchase"), confirms, "never confirmed")
    assert_eq(gold, before, "nothing spent")
    assert(MK.trader.state().last.text:find("price moved"), MK.trader.state().last.text)
end }

T[#T + 1] = { "buying item auctions: whole buyouts, each counted by the gold it took", function()
    MK.db.info(SWORD)
    run(0.5)
    ah.items[SWORD] = { { aid = 601, qty = 1, buyout = 2000 }, { aid = 602, qty = 1, buyout = 2500 } }
    local before = gold
    assert(MK.trader.buy(SWORD, { manual = true }), "queued")
    run(4)
    fail_on_errors("buy swords")
    assert_eq(count_calls("place_bid"), 2, "two buyouts")
    assert_eq(before - gold, 4500, "paid both")
    assert_eq(MK.ledger.summary().buys, 3, "three purchases recorded in all")
    ah.items[SWORD] = {}
end }

T[#T + 1] = { "posting: priced under the cheapest other seller, checked by where items sit", function()
    put_in_bag(1, COPPER, "Item-1", 10)
    put_in_bag(2, LINEN, "Item-2", 20)
    put_in_bag(3, LEATHER, "Item-3", 3)
    ah.commodity[COPPER] = { { unit = 1000, qty = 10, aid = 701 }, { unit = 1100, qty = 10, aid = 702 } }
    local before = gold
    local ok, why = MK.trader.post(COPPER, { manual = true })
    assert(ok, tostring(why))
    run(4)
    fail_on_errors("post copper")
    local post = last_call("post_commodity")
    assert(post, "posted")
    assert_eq(post[2], 0, "bag 0")
    assert_eq(post[3], 1, "slot 1")
    assert_eq(post[4], 3, "48 hours, the longest")
    assert_eq(post[5], 10, "the whole stack")
    assert_eq(post[6], 999, "1c under the cheapest")
    assert_eq(before - gold, 60, "deposit taken")
    assert_eq(MK.trader.posts()["777"].unit, 999, "the post is remembered by auction id")
    assert_eq(MK.ledger.summary().fees, 60, "deposit counted as a fee")
    -- The bags advise: leather to the vendor (it pays more than the AH).
    MK.bags.invalidate()
    local advice = {}
    for _, a in ipairs(MK.bags.list()) do advice[a.id] = a end
    assert_eq(advice[LEATHER].action, "vendor", "a vendor pays 60s for leather")
end }

T[#T + 1] = { "your auctions: cheapest, then undercut", function()
    ah.owned = { { auction_id = 777, item_id = COPPER, quantity = 10, buyout_amount = 999, bid_amount = 0,
        status = 0, time_left = 3 } }
    MK.trader.refresh_owned()
    run(1)
    local list = MK.trader.owned()
    assert(list and #list == 1, "one auction")
    assert_eq(list[1].unit, 999, "its price, from the post record")
    assert_eq(list[1].status, "cheapest", "cheapest")
    ah.commodity[COPPER] = { { unit = 990, qty = 5, aid = 704 }, { unit = 999, qty = 10, aid = 777, own = 10 } }
    MK.ah.search(COPPER)
    run(1)
    list = MK.trader.owned()
    assert_eq(list[1].status, "undercut", "someone went under")
    assert_eq(list[1].lowest, 990, "at 9s 90c")
end }


-- =============================================================================
-- automatic trading
-- =============================================================================

T[#T + 1] = { "automatic trading buys the best deal, within the budget", function()
    ah.commodity[ORE] = { { unit = 4000, qty = 5, aid = 510 }, { unit = 10000, qty = 10, aid = 511 },
        { unit = 10200, qty = 10, aid = 512 }, { unit = 10400, qty = 10, aid = 513 } }
    MK.deals.compute()
    assert(MK.deals.get(ORE), "the ore deal is on the list")
    local before = gold
    MK.auto.toggle()                       -- the AUTO button
    assert(MK.auto.active(), "on")
    assert_eq(MK.menu:get("auto_trade"), true, "the menu switch follows the button")
    -- The number, the moment it starts: what it found it can make.
    local proj = MK.auto.projection()
    assert(proj.identified_n >= 1, "deals found")
    assert(proj.projected > 0, "a projected profit from the deals it can afford")
    assert_near(proj.total, proj.projected + proj.stock, 0.01, "deals plus stock held")
    assert(proj.spend > 0 and proj.spend <= MK.trader.limits(true).spend + 1e-6, "within what the gold allows")
    local said = activity_has("projected profit")
    assert(said, "the projection is said as Auto starts")
    assert(said:find(MK.util.signed(proj.total), 1, true), "with its number: " .. said)
    assert(MK.auto.session(), "a session from now")
    run(8)
    fail_on_errors("auto buy")
    local h = MK.ledger.holding(ORE)
    assert(h and h.qty == 5, "bought the five cheap ore")
    assert_eq(before - gold, 20000, "for 2g")
    local buy = nil
    for _, r in ipairs(MK.ledger.trades()) do if r.kind == "buy" and r.id == ORE then buy = r end end
    assert(buy and buy.expected and buy.expected > 0, "with the profit it expected")
    assert_eq(MK.auto.stats().buys >= 1, true, "counted")
    -- What it bought is in the projection now, as stock that should sell.
    assert(MK.auto.projection().stock > 0, "the ore it holds is expected to make money")
    -- Your own copper auction is undercut, but it was not bought here.
    assert_eq(count_calls("cancel_auction"), 0, "your own posts are left alone")
    ah.commodity[ORE] = { { unit = 10000, qty = 10, aid = 511 }, { unit = 10200, qty = 10, aid = 512 },
        { unit = 10400, qty = 10, aid = 513 } }
end }

T[#T + 1] = { "automatic trading posts what it bought, and no more", function()
    put_in_bag(4, ORE, "Item-4", 5)
    put_in_bag(5, ORE, "Item-5", 20)          -- your own ore: not posted
    local posts = count_calls("post_commodity")
    run(8)
    fail_on_errors("auto post")
    assert_eq(count_calls("post_commodity"), posts + 1, "one post")
    local post = last_call("post_commodity")
    assert_eq(post[3], 4, "the bought stack")
    assert_eq(post[5], 5, "five, what was bought")
    local usual = MK.db.item(ORE).h
    assert_eq(post[6], math.floor(usual + 0.5), "at its usual price: never above what it was bought against")
    assert_eq(MK.auto.stats().posts >= 1, true, "counted")
    run(3)
    assert_eq(count_calls("post_commodity"), posts + 1, "the rest is yours: never posted")
end }

T[#T + 1] = { "an undercut auction it bought is cancelled and reposted while that pays", function()
    local ore_auction = ah.owned[#ah.owned].auction_id
    ah.commodity[ORE] = { { unit = 9000, qty = 10, aid = 514 }, { unit = 9967, qty = 5, aid = ore_auction, own = 5 },
        { unit = 10200, qty = 10, aid = 512 }, { unit = 10400, qty = 10, aid = 513 } }
    mock.time = mock.time + 16 * 60         -- past the 15 minutes a post stays up, and the review
    run(8)
    fail_on_errors("auto cancel")
    local c = last_call("cancel_auction")
    assert(c, "cancelled")
    assert_eq(c[2], ore_auction, "the undercut ore")
    -- Ore is ore: the five it holds go up again at once, from your other
    -- stack, under the new cheapest seller -- and only five.
    local post = last_call("post_commodity")
    assert_eq(post[3], 5, "from the ore in the bags")
    assert_eq(post[5], 5, "the five it holds")
    assert_eq(post[6], 8999, "1c under 90s")
    assert_eq(bag[5].stack, 15, "the rest of your stack stays")
    assert_eq(MK.auto.stats().cancels, 1, "one repost")
    -- The cancelled five come back by mail: five are already up, so they stay.
    put_in_bag(4, ORE, "Item-6", 5)
    local posts = count_calls("post_commodity")
    run(8)
    fail_on_errors("auto repost")
    assert_eq(count_calls("post_commodity"), posts, "no more than it holds")
end }

T[#T + 1] = { "a cancel is done only when its own auction is named", function()
    ah.owned[#ah.owned + 1] = { auction_id = 960, item_id = ORE, quantity = 5, buyout_amount = 10500,
        bid_amount = 0, status = 0, time_left = 3 }
    local real = mock.core.auction_house.cancel_auction
    mock.core.auction_house.cancel_auction = function(aid)
        log_call("cancel_auction", aid)
        later("AUCTION_CANCELED", { 123456 })   -- someone else's auction, bought out meanwhile
    end
    assert(MK.trader.cancel(960, { item_id = ORE }), "queued")
    run(2)
    assert(MK.trader.busy(), "not done on another auction's event")
    later("AUCTION_CANCELED", { 960 })
    run(2)
    mock.core.auction_house.cancel_auction = real
    fail_on_errors("cancel id")
    assert(not MK.trader.busy(), "done when its own is named")
    assert(activity_has("Cancelled " .. MK.db.name(ORE)), "said so")
    for i = #ah.owned, 1, -1 do if ah.owned[i].auction_id == 960 then table.remove(ah.owned, i) end end
end }

T[#T + 1] = { "an auction you listed by hand is yours, even when Auto holds the item", function()
    ah.owned[#ah.owned + 1] = { auction_id = 950, item_id = ORE, quantity = 20, buyout_amount = 10500,
        bid_amount = 0, status = 0, time_left = 3 }
    ah.commodity[ORE] = { { unit = 9000, qty = 10, aid = 514 }, { unit = 10200, qty = 10, aid = 512 },
        { unit = 10500, qty = 20, aid = 950, own = 20 } }
    mock.time = mock.time + 16 * 60
    run(10)
    fail_on_errors("own auction")
    for _, c in ipairs(ah.calls) do
        if c[1] == "cancel_auction" then assert(c[2] ~= 950, "your auction was cancelled") end
    end
    for i = #ah.owned, 1, -1 do if ah.owned[i].auction_id == 950 then table.remove(ah.owned, i) end end
end }

T[#T + 1] = { "the deposit is learned from the gold each post took, and a repost forfeits it", function()
    -- Every deposit the fake auction house took, as the trader measured it.
    local seen = {}
    for _, r in ipairs(MK.ledger.trades()) do
        if r.kind == "fee" and r.note == "deposit" then seen[#seen + 1] = r.copper end
    end
    assert(#seen > 0, "posts took deposits")
    table.sort(seen)
    local median = #seen % 2 == 1 and seen[(#seen + 1) / 2] or (seen[#seen / 2] + seen[#seen / 2 + 1]) / 2
    assert_near(MK.policy.deposit(), median, 0.01, "the median of what posts took")
    -- An undercut post whose deposit is worth more than reposting gains is left alone.
    MK.trader.posts()["970"] = { id = ORE, qty = 1, unit = 10500, t = 0, deposit = 1e6 }
    local pays = MK.auto.repost_pays({ auction_id = 970, item_id = ORE, qty = 1, unit = 10500 })
    MK.trader.posts()["970"] = nil
    assert_eq(pays, false, "a repost that would forfeit more than it gains does not pay")
end }

T[#T + 1] = { "the money: read from your gold, and Auto waits when none is free", function()
    local cap = MK.policy.capital()
    assert_eq(cap.gold, gold, "reads your gold")
    assert_near(cap.capital, gold + cap.invested, 0.01, "capital: gold and the stock it holds")
    assert_near(cap.reserve, cap.capital * 0.10, 0.01, "keeps 10% of capital")
    assert(cap.max_deal > 0 and cap.max_deal <= cap.capital * 0.5, "one deal: at most half")
    -- Almost no gold beside the stock it holds: nothing is free.
    local real = gold
    gold = 1000
    run(2.5)
    cap = MK.policy.capital()
    assert_eq(cap.max_deal, 0, "nothing free")
    assert_eq(cap.why, "your gold is at the 10% it always keeps", "and says why")
    ah.commodity[LEATHER] = { { unit = 1500, qty = 3, aid = 540 } }
    MK.deals.compute()
    local buys = count_calls("start_commodities_purchase")
    run(3)
    assert_eq(count_calls("start_commodities_purchase"), buys, "Auto buys nothing")
    assert(MK.auto.status():find("waiting"), MK.auto.status())
    gold = real
    run(2.5)
    ah.commodity[LEATHER] = {}
    MK.deals.compute()
end }

T[#T + 1] = { "each deal gets the share of capital it deserves (quarter Kelly)", function()
    local Pol = MK.policy
    local cap = { capital = 1000000, max_deal = 500000, free = 900000, stock_room = 700000 }
    -- A vendor flip cannot lose: as much as one deal may have.
    local vendor = { mode = "vendor", units = 10, cost = 10000, profit = 5000, confidence = 1 }
    assert_eq(Pol.size(vendor, cap), 500000, "half of capital")
    -- A sure resale with a big margin and little to lose: a large share.
    local sure = { mode = "flip", units = 5, cost = 20000, profit = 25000, confidence = 0.999, resale = 9950,
        risk = { cv = 0.10, vendor = 0 } }
    assert(Pol.size(sure, cap) >= 250000, "a large share: " .. Pol.size(sure, cap))
    -- A thin, volatile resale: little or nothing.
    local thin = { mode = "flip", units = 5, cost = 20000, profit = 600, confidence = 0.95, resale = 4300,
        risk = { cv = 0.30, vendor = 0 } }
    -- Its edge (+0.65% at 95%) is gone if it is really 93% sure: no stake.
    assert_eq(Pol.size(thin, cap), 0, "nothing for a thin edge")
    -- A losing bet gets nothing.
    assert_eq(P.kelly(0.5, 0.05, 0.5), 0, "no edge, no stake")
    assert_near(P.kelly(0.9, 1, 0.5), 0.9 / 0.5 - 0.1 / 1, 1e-9, "f* = p/L - (1-p)/W")
end }

T[#T + 1] = { "a small purse can still trade: the reserve follows the gold", function()
    local real = gold
    gold = 25262                            -- 2g 52s 62c, the user's character on 2026-10-07
    run(2.5)                                -- gold is read every two seconds
    local cap = MK.policy.capital()
    assert_near(cap.reserve, (25262 + cap.invested) * 0.10, 0.01, "keeps 10% of capital")
    assert(cap.max_deal > 0, "something may be spent: " .. cap.max_deal)
    assert_eq(cap.why, nil, "nothing blocks it")
    assert_near(MK.policy.min_profit(cap), math.max(500, cap.capital * 0.001), 0.01, "least profit: 5s")
    assert_near(MK.policy.min_profit(cap, 720), 1440, 0.01, "or twice the deal's deposits")
    assert_near(MK.policy.big_line(cap), math.max(2000, cap.capital * 0.05), 0.01, "big money: 20s, or 5% of capital")
    gold = real
    run(2.5)
end }

T[#T + 1] = { "vendor flips sell themselves at a merchant, against what they cost", function()
    mock.core.input.use_container_item = function(b, s)
        log_call("use_container_item", b, s)
        local e = bag[s]
        if e and e.present then
            gold = gold + 6000 * e.stack
            take_out(s)
        end
    end
    local before = gold
    mock.game_event("MERCHANT_SHOW", {})
    run(4)
    mock.game_event("MERCHANT_CLOSED", {})
    run(0.2)
    fail_on_errors("vendor")
    assert_eq(count_calls("use_container_item"), 1, "only the leather it bought")
    assert_eq(last_call("use_container_item")[3], 3, "from its slot")
    assert_eq(gold - before, 18000, "a vendor paid 1g 80s")
    local s = MK.ledger.summary()
    assert_eq(s.flips, 1, "one sale of bought stock")
    assert_eq(s.flips_expected, 13500, "expected 1g 35s")
    assert_eq(s.flips_actual, 13500, "and made it")
    assert_eq(MK.ledger.holding(LEATHER), nil, "none of it held now")
    -- The leather lot is done: bought, sold, nothing else; it made money.
    assert(s.lots >= 1 and s.lots_ok == s.lots, "lots: " .. s.lots_ok .. "/" .. s.lots)
    local ok, n = MK.policy.record()
    assert_eq(ok, n, "the confidence bar learns from it")
end }

T[#T + 1] = { "Auto OFF stops a purchase in the middle", function()
    MK.db.info(SWORD)
    ah.items[SWORD] = { { aid = 611, qty = 1, buyout = 2000 }, { aid = 612, qty = 1, buyout = 2000 },
        { aid = 613, qty = 1, buyout = 2000 } }
    local bids = count_calls("place_bid")
    assert(MK.trader.buy(SWORD, { auto = true }), "queued")
    for _ = 1, 200 do
        run(0.05)
        if count_calls("place_bid") > bids then break end
    end
    assert_eq(count_calls("place_bid"), bids + 1, "one bid placed")
    MK.menu:set("auto_trade", false)         -- the button, mid-purchase
    run(4)
    fail_on_errors("off mid-buy")
    assert_eq(count_calls("place_bid"), bids + 1, "no bid after OFF")
    ah.items[SWORD] = {}
    MK.menu:set("auto_trade", false)
end }

T[#T + 1] = { "a post that moves another item stops posting for the session", function()
    ah.commodity[LINEN] = { { unit = 100, qty = 20, aid = 720 } }
    ah.on_post = function() take_out(5) end          -- your own ore moves, not the linen
    assert(MK.trader.post(LINEN, { manual = true }), "queued")
    run(4)
    ah.on_post = default_on_post
    fail_on_errors("halt")
    local st = MK.trader.state()
    assert(st.halted, "halted")
    assert(st.halted:find("Iron Ore") and st.halted:find("Linen Cloth"), st.halted)
    local ok, why = MK.trader.post(COPPER)
    assert_eq(ok, false, "no more posting")
    assert(why:find("stopped"), why)
end }

T[#T + 1] = { "the mailbox: a sale's money arriving is a sale", function()
    local mails = {
        { subject = "Auction successful: Copper Bar (10)", money = 9490, item_count = 0 },
        { subject = "Auction won: Heavy Leather", money = 0, item_count = 1 },
    }
    mock.core.mail = {
        get_num_inbox_items = function() return #mails end,
        get_inbox_header_info = function(i) return mails[i] end,
        take_inbox_money = function(i) gold = gold + mails[i].money; table.remove(mails, i) end,
        auto_loot_mail_item = function(i) table.remove(mails, i) end,
    }
    mock.game_event("MAIL_SHOW", {})
    run(1)
    local box = MK.ledger.mailbox()
    assert(box, "the mailbox is read")
    assert_eq(box.sales, 1, "one sale")
    assert_eq(box.money, 9490, "worth 94s 90c")
    assert_eq(box.won, 1, "one purchase")
    -- What is waiting there, known with the mailbox shut too.
    local mw = MK.trader.mail_waiting()
    assert_eq(mw.inbox, 9490, "the sale mail's 94s 90c")
    assert_eq(mw.inbox_n, 1, "one sale mail")
    -- An auction of Auto's that sold since, not in the inbox yet: on its way.
    MK.trader.posts()["980"] = { id = ORE, qty = 2, unit = 10000, t = MK.util.now(), sold = MK.util.now(),
        deposit = 100 }
    mw = MK.trader.mail_waiting()
    assert_near(mw.coming, 20000 * (1 - MK.policy.cut() / 100) + 100, 0.5, "after the cut, deposit back")
    assert_near(mw.total, 9490 + mw.coming, 0.5, "both")
    MK.trader.posts()["980"] = nil
    assert(MK.ledger.collect(), "collecting")
    run(4)
    fail_on_errors("mail")
    assert_eq(#mails, 0, "both taken")
    local s = MK.ledger.summary()
    -- The copper was yours (posted by hand, never bought here): its money is
    -- kept apart from what trading returned.
    assert_eq(s.other_sales, 9490, "your own copper's 94s 90c, kept apart")
    assert_eq(s.sales, 1, "the leather a vendor bought is the one sale of stock")
    local t = MK.ledger.totals()
    assert_eq(t.own_sales, 9490, "all time too")
    assert(t.returned > 0 and t.invested > 0, "invested and returned are on record")
    assert_near(t.profit, t.returned - t.basis - t.fees, 0.01, "profit = returned - cost of what sold - fees")
    mock.game_event("MAIL_CLOSED", {})
    run(0.5)
    assert_eq(MK.trader.mail_waiting().total, 0, "nothing waiting once collected")
end }

T[#T + 1] = { "every tab of the window draws", function()
    local drawn = {}
    local real = mock.core.graphics.text_2d
    -- text_2d(text, position, ...): the text comes first.
    mock.core.graphics.text_2d = function(text, ...)
        drawn[#drawn + 1] = tostring(text)
        return real(text, ...)
    end
    for tab = 1, 8 do
        MK.window.set_tab(tab)
        run(0.3)
        fail_on_errors("tab " .. tab)
    end
    mock.core.graphics.text_2d = real
    for _, t in ipairs(drawn) do
        assert(not t:find("table: ", 1, true), "a cell was drawn as a table: " .. t)
    end
    mock.menu:render_titles()
    assert_eq(#mock.menu.title_errors, 0, "menu title: " .. table.concat(mock.menu.title_errors, "; "))
end }

T[#T + 1] = { "the window follows a drag by its title bar on every tab, and stays where it is let go", function()
    local function win()
        for _, w in ipairs(JCore.ui.windows()) do
            if w.id == "jambix.market:main" then return w end
        end
    end
    for tab = 1, 8 do
        MK.window.set_tab(tab)
        run(0.3)
        local w0 = win()
        assert(w0 and w0.visible and not w0.collapsed, "the window is open")
        local gx, gy = w0.x + 120, w0.y + 10
        mock.move(gx, gy)
        mock.frame(1)
        mock.press(0x01)
        mock.frame(1)
        local trail = {}
        for step = 1, 10 do
            mock.move(gx + step * 7, gy + step * 3)
            mock.frame(1)
            local w = win()
            trail[#trail + 1] = string.format("(%d,%d)", w.x, w.y)
            assert(w.x == w0.x + step * 7 and w.y == w0.y + step * 3,
                "tab " .. tab .. ": the window left the cursor at step " .. step .. ": " .. table.concat(trail, " "))
        end
        mock.release(0x01)
        mock.frame(1)
        mock.move(5, 5)
        run(3)
        local w = win()
        assert(w.x == w0.x + 70 and w.y == w0.y + 30, string.format(
            "tab %d: let go at (%d,%d), now at (%d,%d)", tab, w0.x + 70, w0.y + 30, w.x, w.y))
        fail_on_errors("drag on tab " .. tab)
    end
end }

T[#T + 1] = { "the Vendor tab: what a vendor pays against the auction house and what was paid", function()
    local v = MK.bags.vendor_list()
    assert(#v.rows > 0, "the bags hold something a vendor buys")
    for _, r in ipairs(v.rows) do
        assert(r.vendor > 0, "only what a vendor buys")
        if r.ah then
            assert_eq(r.best, r.vendor >= r.ah and "vendor" or "ah", "the better of the two: " .. tostring(r.name))
        else
            assert_eq(r.best, "vendor", "no auction price: the vendor")
        end
        if r.paid then
            assert_near(r.gain, (r.best == "vendor" and r.vendor or r.ah) - r.paid, 0.01, "against what was paid")
        end
    end
    local sum = 0
    for _, r in ipairs(v.rows) do sum = sum + r.vendor end
    assert_near(v.vendor, sum, 0.01, "the total is the rows")
    for i = 2, #v.rows do
        if v.rows[i - 1].best == v.rows[i].best then
            assert(v.rows[i - 1].vendor >= v.rows[i].vendor, "most money first")
        else
            assert_eq(v.rows[i - 1].best, "vendor", "vendor-better first")
        end
    end
end }

T[#T + 1] = { "the auction house closing stops a job cleanly", function()
    ah.commodity[LEATHER] = { { unit = 1500, qty = 3, aid = 530 } }
    assert(MK.trader.buy(LEATHER, { manual = true }), "queued")
    run(0.1)
    ah.open = false
    mock.game_event("AUCTION_HOUSE_CLOSED", {})
    run(1)
    fail_on_errors("closed")
    assert(not MK.window.is_visible(), "the window it opened closed with it")
    assert_eq(MK.trader.state().job, nil, "no job left running")
end }

T[#T + 1] = { "prices survive a save and a reload of the file", function()
    MK.db.save(true)
    local text = mock.data_fs["jcore/jambix.market.mock.json"]
    assert(text and #text > 0, "price file written")
    local snap = mock.data_fs["jcore/jambix.market.mock.snap.json"]
    assert(snap and snap:find("Cheap"), "the scan baseline is written with its sellers")
    local decoded = JCore.json.decode(text)
    assert(decoded.items[MK.util.key(ORE)].m, "ore's market value is in the file")
    local row = decoded.items[MK.util.key(ORE)].d[1]
    assert_eq(#row, 7, "a day row is a whole array")
end }

T[#T + 1] = { "full scans are tried every 3 minutes, and the server's own limit is learned", function()
    local meta = MK.db.meta()
    meta.gap, meta.gap_ok = nil, 0           -- nothing learned yet
    assert_eq(MK.scanner.gap(), 180, "every 3 minutes to start")
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(3)
    -- Each new list has one more listing of an item nobody trades.
    local extra = 0
    local function fresh_list()
        extra = extra + 1
        local l = {}
        for i, x in ipairs(SCAN_THREE) do l[i] = x end
        for k = 1, extra do l[#l + 1] = listing(20000 + k, "N", 1, 100, 3) end
        return l
    end
    -- A server that gives a full scan every 3 minutes: three in nine.
    local scans = meta.scans
    for _ = 1, 3 do
        ah.list = fresh_list()
        mock.time = mock.time + 3 * 60 + 1
        run(8)
    end
    fail_on_errors("3-minute scans")
    assert_eq(MK.db.meta().scans, scans + 3, "a full scan every 3 minutes")
    assert_eq(MK.scanner.gap(), 180, "still every 3 minutes")

    -- A server that holds to 15 minutes: the old list until then.
    local real = mock.core.auction_house.replicate_items
    local last_ok = mock.time
    mock.core.auction_house.replicate_items = function()
        log_call("replicate_items")
        if mock.time - last_ok >= 15 * 60 then ah.list = fresh_list() end
        ah.ready = true
        later("REPLICATE_ITEM_LIST_UPDATE")
    end
    scans = MK.db.meta().scans
    local asked = count_calls("replicate_items")
    for _ = 1, 8 do
        mock.time = mock.time + 3 * 60 + 1
        run(30)
        if MK.db.meta().scans > scans then break end
    end
    fail_on_errors("15-minute server")
    assert_eq(MK.db.meta().scans, scans + 1, "the one the server gave")
    assert(count_calls("replicate_items") - asked >= 4, "refused tries first: " .. (count_calls("replicate_items") - asked))
    assert_eq(MK.scanner.gap(), 15 * 60, "learned: 15 minutes")
    -- Three minutes on, no doomed try: a quick scan instead.
    asked = count_calls("replicate_items")
    mock.time = mock.time + 3 * 60 + 1
    run(30)
    mock.core.auction_house.replicate_items = real
    fail_on_errors("after learning")
    assert_eq(count_calls("replicate_items"), asked, "not asked again before 15 minutes")
    assert(MK.scanner.last_quick().at > mock.time - 40, "a quick scan instead")
    ah.list = SCAN_THREE
end }

-- =============================================================================
-- big money (1.1.0)
-- =============================================================================

T[#T + 1] = { "the cut: a sale is read against the post it fits, never an older one that reads 0%", function()
    local posts = MK.trader.posts()
    local was = MK.policy.cut()
    posts["9001"] = { id = LINEN, qty = 8, unit = 398, t = 1, deposit = 100 }     -- 12 h, ran out
    posts["9002"] = { id = LINEN, qty = 8, unit = 397, t = 2, deposit = 264 }     -- 48 h, sold
    MK.ledger.sold(LINEN, 8, 3282, "Linen Cloth")
    assert_eq(posts["9002"].cut_seen, true, "the post it fits: 4.97%")
    assert_eq(posts["9001"].cut_seen, nil, "not the older one (0.06%)")
    assert_near(MK.policy.cut(), was * 0.7 + (1 - (3282 - 264) / (397 * 8)) * 100 * 0.3, 1e-6, "learned from 4.97%")
    posts["9001"], posts["9002"] = nil, nil
end }

T[#T + 1] = { "the 48-hour deposit rate is learned from posts above the 1s minimum", function()
    local Pol = MK.policy
    assert_near(Pol.deposit_rate(48), 0.6, 1e-12, "60% of the vendor price until a post says otherwise")
    MK.ledger.posted(LEATHER, 2, 1500, 48, 9000, nil)          -- 9000 / (60s x 2) = 0.75
    assert_near(Pol.deposit_rate(48), 0.75, 1e-12, "learned")
    MK.ledger.posted(LEATHER, 1, 1500, 48, 100, nil)           -- the minimum: says nothing of the rate
    assert_near(Pol.deposit_rate(48), 0.75, 1e-12, "a 1s post teaches nothing")
    MK.ledger.posted(LEATHER, 3, 1500, 48, 10800, nil)         -- 0.60
    assert_near(Pol.deposit_rate(48), 0.675, 1e-12, "the median of what posts took")
    assert_near(Pol.post_deposit(LEATHER, 2), 0.675 * 6000 * 2, 1e-9, "a post of two")
    assert_eq(Pol.post_deposit(LINEN, 1), 100, "never under 1s")
end }

T[#T + 1] = { "big money: judged at what Auto may spend; smaller deals stop at half of capital in stock", function()
    local BIG_GEM, SMALL_GEM = 7001, 7002
    ah.info[BIG_GEM] = { name = "Big Gem", vendor = 3500 }
    ah.info[SMALL_GEM] = { name = "Small Gem", vendor = 1000 }
    MK.db.info(BIG_GEM)
    MK.db.info(SMALL_GEM)
    ah.commodity[LEATHER] = {}
    run(1)
    -- Stock is 60% of capital: 10% of it is left for a deal, none under the half line.
    local inv = MK.policy.capital().invested
    gold = math.floor(inv * 2 / 3) + 1
    run(2.5)
    local cap = MK.policy.capital()
    assert_near(cap.max_deal, cap.capital * 0.1, 2, "one deal may get 10% of capital (the 70% line)")
    assert_eq(cap.max_small, 0, "a smaller deal nothing: stock is over half of capital")
    -- Big Gem: 50 at 20s, a vendor pays 35s. Small Gem: 4 at 6s, a vendor pays 10s.
    ah.commodity[BIG_GEM] = { { unit = 2000, qty = 50, aid = 801 } }
    ah.commodity[SMALL_GEM] = { { unit = 600, qty = 4, aid = 802 } }
    MK.ah.search(BIG_GEM)
    MK.ah.search(SMALL_GEM)
    run(1)
    local big, small_deal = MK.deals.get(BIG_GEM), MK.deals.get(SMALL_GEM)
    assert(big and small_deal, "both on the list")
    assert_eq(big.big, true, "Big Gems for 10% of capital: +15s each, over the big-money line")
    assert_eq(small_deal.big, false, "Small Gem: +16s, not big")
    local function bought(id)
        for _, c in ipairs(ah.calls) do
            if c[1] == "start_commodities_purchase" and c[2] == id then return c[3] end
        end
        return nil
    end
    MK.auto.toggle()
    assert(MK.auto.active(), "on")
    run(8)
    fail_on_errors("big buy")
    local units = bought(BIG_GEM)
    assert(units and units * 2000 <= cap.max_deal + 1, "the big deal bought within one deal's share: " .. tostring(units))
    assert(activity_has("Big money: bought"), "and said as big money")
    assert_eq(bought(SMALL_GEM), nil, "the small one waits: stock is over half of capital")
    MK.auto.toggle()
    ah.commodity[BIG_GEM], ah.commodity[SMALL_GEM] = {}, {}
end }

T[#T + 1] = { "quick scans watch where big money shows up: proven items one deal could buy, dearest first", function()
    local now = MK.util.now()
    local day = MK.util.day(now)
    local function proven(id, value)
        MK.db.remember_info(id, { n = "Dear " .. id, v = 10, s = 20, c = 7, ok = true })
        MK.db.items()[MK.util.key(id)] = { c = 5, h = value, m = value, ev = 4, eu = 4, eo = 7200, ei = 2, sa = 4,
            oa = 7200, d = { { day - 1, value, 10, value, 2, 5, 5 }, { day, value, 10, value, 2, 5, 5 } } }
    end
    proven(7101, 5000)
    proven(7102, 20000)
    proven(7103, 1e9)                                    -- no deal could buy it
    local targets = MK.scanner.quick_targets(80)
    local pos = {}
    for i, id in ipairs(targets) do pos[id] = i end
    assert(pos[7102] and pos[7101] and pos[7102] < pos[7101], "the dearer proven item first")
    assert(not pos[7103] or pos[7103] > pos[7101], "one no deal could buy comes after them")
    for _, id in ipairs({ 7101, 7102, 7103 }) do MK.db.items()[MK.util.key(id)] = nil end
end }

T[#T + 1] = { "learned from finished lots: the least profit, how long vendor flips wait, items that lost", function()
    local Pol, U = MK.policy, MK.util
    local function emit(lot) MK.ctx.emit("jambix.market.lot_done", lot) end
    local real = gold
    gold = 5000000
    run(2.5)
    local cap = Pol.capital()
    -- The least profit's 5s rises to what small resale lots fell short of their plan by.
    for _, miss in ipairs({ 0, 0, 92, 79 }) do
        emit({ id = 1, mode = "flip", planned = 1000, made = 1000 - miss, ok = true, t = U.now() })
    end
    assert_eq(Pol.floor_abs(cap), 500, "fewer than five lots: 5s")
    emit({ id = 1, mode = "flip", planned = 404, made = 6, ok = true, t = U.now() })     -- the Shard: 3s 98c short
    assert_eq(Pol.floor_abs(cap), 500, "five, the worst 3s 98c short: still 5s")
    for _ = 1, 5 do emit({ id = 2, mode = "flip", planned = 1300, made = 100, ok = true, t = U.now() }) end
    assert_eq(Pol.floor_abs(cap), 1200, "the 90th percentile of the misses: 12s")
    emit({ id = 3, mode = "flip", planned = 2500000, made = 1, ok = true, big = true, t = U.now() })
    assert_eq(Pol.floor_abs(cap), 1200, "a big lot's miss does not count")
    for _ = 1, 3 do emit({ id = 4, mode = "flip", planned = 1e7, made = 1, ok = true, t = U.now() }) end
    assert_near(Pol.floor_abs(cap), Pol.big_line(cap) / 2, 1e-6, "never above half the big-money line")
    -- Vendor flips: how long their money waits for a merchant.
    assert_near(Pol.vendor_days(), 1, 1e-9, "1 day until three vendor lots have sold out")
    for _, d in ipairs({ 0.2, 0.3, 0.4 }) do emit({ id = 5, mode = "vendor", days = d, made = 10, ok = true, t = U.now() }) end
    assert_near(Pol.vendor_days(), 0.25, 1e-9, "the median of the last ten (the leather sold in minutes, and these)")
    MK.ledger.bought(7003, 5, 500, "vendor", 120, 1)
    MK.ledger.holding(7003).lot.t = U.now() - 1.8 * 86400
    assert_near(Pol.vendor_days(), 1.8, 1e-3, "never less than the oldest still waiting")
    MK.ledger.holding(7003).lot.t = U.now() - 9 * 86400
    assert_eq(Pol.vendor_days(), 7, "7 days at most")
    MK.ledger.sold(7003, 5, 600, "vendor")
    -- An item whose lot lost money is not resold for two days; seven after two within a week.
    assert_eq(Pol.cooling(7004), nil, "never lost: free")
    emit({ id = 7004, mode = "flip", made = -50, ok = false, t = U.now() })
    local left = Pol.cooling(7004)
    assert(left and math.abs(left - 2 * 86400) < 5, "two days: " .. tostring(left))
    emit({ id = 7004, mode = "flip", made = -10, ok = false, t = U.now() })
    assert(math.abs(Pol.cooling(7004) - 7 * 86400) < 5, "seven days after two within a week")
    emit({ id = 7005, mode = "flip", made = 10, ok = true, t = U.now() })
    assert_eq(Pol.cooling(7005), nil, "a lot that made money does not cool")
    gold = real
    run(2.5)
end }

T[#T + 1] = { "a lot carries what it was planned to make, how long it took, and whether it was big", function()
    local seen = nil
    MK.ctx.on("jambix.market.lot_done", function(lot) if lot.id == 7006 then seen = lot end end)
    MK.ledger.bought(7006, 4, 400, "flip", 150, 0.995, 120, true)
    MK.ledger.bought(7006, 2, 200, "flip", 150, 0.995, 60, nil)
    MK.ledger.sold(7006, 6, 840, "x")
    assert(seen, "lot_done")
    assert_eq(seen.mode, "flip", "mode")
    assert_eq(seen.planned, 180, "planned after deposits, both purchases")
    assert_eq(seen.big, true, "big when any purchase in it was")
    assert(seen.days >= 0 and seen.days < 0.01, "days held: " .. tostring(seen.days))
end }

-- =============================================================================
-- The 1.1.0 review: regressions for what it found (each reproduced first).
-- =============================================================================

local function rv_reset_stock()
    local h = MK.ledger.holdings()
    for k in pairs(h) do h[k] = nil end
end

local function rv_open()
    if not MK.ah.is_open() then
        ah.list = SCAN_THREE
        ah.open = true
        mock.game_event("AUCTION_HOUSE_SHOW", {})
        run(10)
    end
    run(1)
end

--- Capital C with a share of it in stock (one filler holding).
local function rv_capital(C, stock_share, fill_id)
    rv_reset_stock()
    local S = math.floor(stock_share * C)
    if S > 0 then MK.ledger.bought(fill_id, 1, S, "flip", 0, 1) end
    gold = C - S
    run(2.5)
    return MK.policy.capital()
end

local function rv_confirmed(mark, id)
    local n = 0
    for i = mark + 1, #ah.calls do
        local c = ah.calls[i]
        if c[1] == "confirm_commodities_purchase" and c[2] == id then n = n + (c[3] or 0) end
    end
    return n
end

local function rv_stock_share() local c = MK.policy.capital() return c.invested / c.capital end

T[#T + 1] = { "review: a deal still flagged big after the first buy is held to the half line", function()
    -- 100g, 40% in stock: one deal may get 30g, smaller ones 10g; big money from 5g.
    local X_ID, Y_ID, FILL = 7301, 7302, 7399
    ah.info[X_ID] = { name = "Gem X", vendor = 1500 }
    ah.info[Y_ID] = { name = "Gem Y", vendor = 1400 }
    MK.db.info(X_ID); MK.db.info(Y_ID)
    rv_open()
    rv_capital(1000000, 0.40, FILL)
    ah.commodity[X_ID] = { { unit = 1000, qty = 200, aid = 921 } }   -- 20g; a vendor pays 30g: +10g
    ah.commodity[Y_ID] = { { unit = 1000, qty = 150, aid = 922 } }   -- 15g; a vendor pays 21g: +6g
    MK.ah.search(X_ID); MK.ah.search(Y_ID)
    run(1)
    assert(MK.deals.get(X_ID) and MK.deals.get(X_ID).big, "X is big money")
    assert(MK.deals.get(Y_ID) and MK.deals.get(Y_ID).big, "Y is big money as listed")
    local mark = #ah.calls
    MK.auto.toggle()
    run(30)
    MK.auto.toggle()
    run(1)
    fail_on_errors("stale big")
    assert_eq(rv_confirmed(mark, X_ID), 200, "X bought")
    -- After X, stock is 60%: what one deal may get (10g) buys 100 Y for +4g, under the
    -- 5g line, so Y is a smaller deal now, and smaller deals stop at half.
    assert_eq(rv_confirmed(mark, Y_ID), 0, "Y not bought on the big budget once it is not big")
    assert(rv_stock_share() <= 0.601, "stock stays at 60%: " .. rv_stock_share())
    ah.commodity[X_ID], ah.commodity[Y_ID] = {}, {}
end }

T[#T + 1] = { "review: a big deal that shrinks at the buy's own search is not bought on the big budget", function()
    -- 55% in stock: smaller deals may spend nothing; Z is big as listed (15g for +7g 50s).
    local Z_ID, FILL = 7303, 7398
    ah.info[Z_ID] = { name = "Gem Z", vendor = 1500 }
    MK.db.info(Z_ID)
    rv_open()
    rv_capital(1000000, 0.55, FILL)
    ah.commodity[Z_ID] = { { unit = 1000, qty = 150, aid = 931 } }
    MK.ah.search(Z_ID)
    run(1)
    assert(MK.deals.get(Z_ID) and MK.deals.get(Z_ID).big, "Z is big money as listed")
    local api = mock.core.auction_house
    local real = api.send_search_query
    local shrunk = false
    api.send_search_query = function(id, ...)
        local st = MK.trader.state()
        if id == Z_ID and not shrunk and st.job and st.job:find("Gem Z", 1, true) then
            shrunk = true
            ah.commodity[Z_ID] = { { unit = 1000, qty = 60, aid = 931 } }    -- someone took 90 first: +3g left
        end
        return real(id, ...)
    end
    local mark = #ah.calls
    MK.auto.toggle()
    run(20)
    MK.auto.toggle()
    run(1)
    api.send_search_query = real
    fail_on_errors("shrunk")
    assert(shrunk, "the buy searched")
    assert_eq(rv_confirmed(mark, Z_ID), 0, "the 60 left (+3g, not big) are not bought past half")
    assert(rv_stock_share() <= 0.551, "stock stays at 55%: " .. rv_stock_share())
    ah.commodity[Z_ID] = {}
end }

T[#T + 1] = { "review: a quote over the plan: the lot plans, and the message says, what the price paid makes", function()
    local W_ID = 7304
    ah.info[W_ID] = { name = "Gem W", vendor = 1500 }
    MK.db.info(W_ID)
    rv_open()
    rv_capital(1000000, 0.0, 7396)
    ah.commodity[W_ID] = { { unit = 1000, qty = 300, aid = 951 } }   -- 30g; a vendor pays 45g: +15g
    MK.ah.search(W_ID)
    run(1)
    assert(MK.deals.get(W_ID) and MK.deals.get(W_ID).big, "W is big money")
    ah.quote = 360000                                                 -- the server quotes 36g (+20%)
    local mark = #ah.calls
    MK.auto.toggle()
    run(10)
    MK.auto.toggle()
    run(1)
    ah.quote = nil
    fail_on_errors("slipped quote")
    assert_eq(rv_confirmed(mark, W_ID), 300, "bought at the quote (it still pays)")
    local h = MK.ledger.holding(W_ID)
    assert(h and h.lot, "a lot")
    assert_near(h.lot.planned, 450000 - 360000, 1, "planned at the price paid: +9g, not the plan's +15g")
    assert(activity_has("Big money: bought 300x Gem W for 36g, expecting +9g"), "the message too")
    ah.commodity[W_ID] = {}
    rv_reset_stock()
end }

T[#T + 1] = { "review: big money once money is free shows for a deal that fits the money free", function()
    -- 10g, 70% in stock: one deal may get nothing now. Z2 is 10 at 15s, a vendor pays
    -- 30s: +1g 50s, big as listed (the line is 50s), and it fits the money free.
    local Z_ID = 7306
    ah.info[Z_ID] = { name = "Gem Z2", vendor = 3000 }
    MK.db.info(Z_ID)
    rv_open()
    local cap = rv_capital(100000, 0.70, 7395)
    assert(cap.max_deal < 1, "nothing may be spent now")
    ah.commodity[Z_ID] = { { unit = 1500, qty = 10, aid = 961 } }
    MK.ah.search(Z_ID)
    run(1)
    local z = MK.deals.get(Z_ID)
    assert(z, "listed")
    assert_eq(z.big, false, "not big now: nothing to spend")
    assert_eq(z.need, 15000, "needs 1g 50s once money is free")
    local wait = MK.deals.big_waiting()
    assert(wait and wait.item_id == Z_ID, "the header names it")
    ah.commodity[Z_ID] = {}
    rv_reset_stock()
end }

T[#T + 1] = { "review: no resale before the client has told the item's vendor price", function()
    -- A mature item the price file knows from scans only (no info.ok): its deposit
    -- would be planned at the 1s minimum. Not resold until its info is in.
    local id = 7307
    local now = MK.util.now()
    MK.db.items()[MK.util.key(id)] = { c = 6, h = 3000, m = 3000, n = 1800, q = 40, l = 6, t = now, f = now - 7200,
        sa = 30, oa = 9000, ev = 8, eu = 30, eo = 9000, ei = 4,
        d = { { MK.util.day(now) - 1, 3000, 40, 2900, 15, 5, 5 }, { MK.util.day(now), 3000, 40, 1800, 15, 5, 5 } } }
    local rows = { { unit = 1800, qty = 5 }, { unit = 3000, qty = 30 } }
    local o = MK.deals.options()
    o.capital = MK.policy.capital()
    assert_eq(MK.deals.plan_for(id, rows, o, false), nil, "no plan with the vendor price unknown")
    -- (A 1s vendor price: a 10s one would make Forever's 48 h deposit, 30s for five, eat the deal.)
    MK.db.remember_info(id, { n = "Probe Ore", q = 1, v = 100, s = 20, ok = true })
    local plan = MK.deals.plan_for(id, rows, o, false)
    assert(plan and plan.mode == "flip", "planned once the client has told it")
    assert(plan.deposits >= 0.6 * 100 * plan.units - 1, "with Forever's deposit: " .. tostring(plan.deposits))
    MK.db.items()[MK.util.key(id)] = nil
end }

return T

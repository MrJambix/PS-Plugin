-- Jambix Market 1.2.0: gear, by roll, bought by Auto and posted by you.
--
-- A fake Forever auction house whose full scan, searches, owned auctions and
-- bags all carry item links the way the user's client writes them (a roll is
-- a bonus id: "item:9779::::::::18:1485::1:1:12741:1:2"). Edged Bastard
-- Swords "of the Bear" sell at about 10g and "of the Monkey" at about 2g:
-- one item id, two prices. The tests run in ORDER inside one Lua state.

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

-- --- the items --------------------------------------------------------------------

local SWORD, CROWN, POUCH, LINEN = 3196, 13127, 4496, 2589
local BEAR, MONKEY = "12731", "12741"

--- A link as Forever writes it: the viewer's level 18 and spec 1485, a roll
--- as one bonus id.
local function link(id, bonus, name)
    local f = { tostring(id), "", "", "", "", "", "", "", "18", "1485", "", "" }
    if bonus then
        f[#f + 1] = "1"
        f[#f + 1] = tostring(bonus)
    else
        f[#f + 1] = ""
    end
    f[#f + 1] = ""
    f[#f + 1] = ""
    return "|cnIQ2:|Hitem:" .. table.concat(f, ":") .. "|h[" .. name .. "]|h|r"
end

local NAMES = {
    [SWORD] = "Edged Bastard Sword", [CROWN] = "Frostreaver Crown", [POUCH] = "Small Brown Pouch",
    [LINEN] = "Linen Cloth",
}
local ROLL_NAME = { [BEAR] = "Edged Bastard Sword of the Bear", [MONKEY] = "Edged Bastard Sword of the Monkey" }

local function link_of(id, roll)
    if roll then return link(id, roll, ROLL_NAME[roll]) end
    return link(id, nil, NAMES[id])
end

local INFO = {
    -- il: the item level (a search's item key); req: the level to use it, which
    -- is what the scan's "level" says on Forever.
    [SWORD] = { name = NAMES[SWORD], vendor = 1377, stack = 1, class = 2, quality = 2, il = 18, req = 13 },
    [CROWN] = { name = NAMES[CROWN], vendor = 3021, stack = 1, class = 4, quality = 3, il = 30, req = 25 },
    [POUCH] = { name = NAMES[POUCH], vendor = 25, stack = 1, class = 1, quality = 1, il = 10, req = 1 },
    [LINEN] = { name = NAMES[LINEN], vendor = 13, stack = 20, class = 7, quality = 1, il = 5, req = 1 },
}

-- --- the player ----------------------------------------------------------------------

local gold = 5000000             -- 500g
mock.core.inventory.get_gold = function() return gold end

local bag = {}                   -- backpack slot -> { id, guid, stack, roll, present }

local function item_obj(e)
    local methods = {
        get_item_id = function() return e.id end,
        get_guid = function() return e.guid end,
        get_item_stack_count = function() return e.stack end,
    }
    return setmetatable({}, { __index = function(_, k) return methods[k] end })
end

local function sync_bags()
    local rows = {}
    for slot = 1, 16 do
        local e = bag[slot]
        if e and e.present then
            rows[#rows + 1] = { item = item_obj(e), bag_id = 0, bag_slot = slot, stack_count = e.stack }
        end
    end
    bag_helper.rows = rows
end
mock.core.inventory.get_items_in_bag = function() return {} end
mock.core.inventory.get_container_item_link = function(b, s)
    local e = b == 0 and bag[s]
    if not e or not e.present then return nil end
    return link_of(e.id, e.roll)
end

local function put_in_bag(slot, id, guid, roll)
    bag[slot] = { id = id, guid = guid, stack = 1, roll = roll, present = true }
    sync_bags()
end

-- --- the fake auction house ---------------------------------------------------------

local ah = { open = false, list = {}, ready = false, items = {}, owned = {}, calls = {}, events = {},
    links = true, bid_answers = true }

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
            name = r.roll and ROLL_NAME[r.roll] or NAMES[r.id], quality_id = 2, level = INFO[r.id].req, has_all_info = true }
    end,
    get_replicate_item_link = function(i)
        log_call("get_replicate_item_link", i)
        local r = ah.list[i + 1]
        if not r or not ah.links then return "" end
        return link_of(r.id, r.roll)
    end,
    get_replicate_item_time_left = function(i)
        local r = ah.list[i + 1]
        return r and r.band or 0
    end,
    send_search_query = function(id, level)
        log_call("send_search_query", id, level)
        later("ITEM_SEARCH_RESULTS_UPDATED", { id })
    end,
    get_num_commodity_search_results = function() return 0 end,
    -- An item's auctions answer only to its item key: its ITEM level.
    get_num_item_search_results = function(id, level)
        if not ah.items[id] or level ~= INFO[id].il then return 0 end
        return #ah.items[id]
    end,
    get_item_search_result_info = function(id, _, _, i)
        local r = ah.items[id][i]
        return { item_id = id, auction_id = r.aid, quantity = 1, buyout_amount = r.buyout, bid_amount = 0,
            min_bid = r.buyout, time_left = 3, contains_owner_item = r.own or false,
            item_link = ah.links and link_of(id, r.roll) or "" }
    end,
    has_full_item_search_results = function() return true end,
    place_bid = function(aid, amount)
        log_call("place_bid", aid, amount)
        if not ah.bid_answers then return end
        gold = gold - amount
        for _, rows in pairs(ah.items) do
            for i = #rows, 1, -1 do if rows[i].aid == aid then table.remove(rows, i) end end
        end
    end,
    get_item_commodity_status = function() return 1 end,
    post_commodity = function() log_call("post_commodity") return false end,
    post_item = function(...) log_call("post_item", ...) return false end,     -- Forever: never lists
    query_owned_auctions = function()
        log_call("query_owned_auctions")
        later("OWNED_AUCTIONS_UPDATED")
    end,
    get_num_owned_auctions = function() return #ah.owned end,
    get_owned_auction_info = function(i) return ah.owned[i] end,
    can_cancel_auction = function() return true end,
    cancel_auction = function(aid) log_call("cancel_auction", aid) end,
    get_cancel_cost = function() return 0 end,
    get_item_info = function(id)
        local i = INFO[id]
        if not i then return {} end
        return { name = i.name, sell_price = i.vendor, quality = i.quality, stack_count = i.stack, bind_type = 2,
            class_id = i.class, item_level = i.il }
    end,
}

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

--- One replicate row; band 3 = over 12 hours left (retail's 0-based bands).
local function row(id, roll, unit, owner, band)
    return { id = id, roll = roll, count = 1, unit = unit, owner = owner or "", band = band or 3 }
end

-- Scan one: twelve Bears from 10g, three Monkeys at about 2g, four crowns at
-- 5g, twelve pouches from 1g; linen fills the list out. (Enough Bears that
-- one cheap one is a seller in a hurry, not the price moving.)
local function scan_one()
    local list = {}
    for k = 0, 11 do list[#list + 1] = row(SWORD, BEAR, 100000 + 1000 * k) end
    for k = 0, 2 do list[#list + 1] = row(SWORD, MONKEY, 20000 + 1000 * k) end
    for k = 0, 3 do list[#list + 1] = row(CROWN, nil, 50000 + 1000 * k) end
    for k = 0, 11 do list[#list + 1] = row(POUCH, nil, 10000 + 100 * k) end
    list[#list + 1] = { id = LINEN, count = 20, unit = 100, owner = "", band = 3 }
    return list
end

--- The list less the auctions bought: { id, roll, unit } each.
local function without(list, gone)
    local out = {}
    for _, r in ipairs(list) do out[#out + 1] = r end
    for _, g in ipairs(gone) do
        for i = 1, #out do
            local r = out[i]
            if r.id == g[1] and r.roll == g[2] and r.unit == g[3] then
                table.remove(out, i)
                break
            end
        end
    end
    return out
end

local JCore, MK, G
local T = {}

local function activity_has(text)
    for _, a in ipairs(MK.activity_log()) do
        if a.text:find(text, 1, true) then return a.text end
    end
    return nil
end

--- The auction house closes, time passes, it opens on a new list: a full scan.
local function next_scan(list, wait)
    ah.open = false
    mock.game_event("AUCTION_HOUSE_CLOSED", {})
    run(0.5)
    ah.ready = false
    mock.time = mock.time + (wait or 2000)
    ah.list = list
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(6)
end

-- =============================================================================
-- links
-- =============================================================================

T[#T + 1] = { "a roll is read from the link the way Forever writes it", function()
    local U = require("jambix_market/modules/util")
    -- The user's own auctions (2026-10-09), names added.
    local var, name, id = U.link_variant("|cnIQ2:|Hitem:9779::::::::18:1485::1:1:12741:1:2:1|h[Bandit Cloak of the "
        .. "Monkey]|h|r")
    assert_eq(var, "12741", "Bandit Cloak's bonus")
    assert_eq(name, "Bandit Cloak of the Monkey", "its name")
    assert_eq(id, 9779, "its id")
    assert_eq((U.link_variant("|cnIQ2:|Hitem:3196::::::::18:1485:::1:12731:::::|h[x]|h|r")), "12731",
        "no item context: the bonus still found")
    assert_eq((U.link_variant("|cnIQ1:|Hitem:6256::::::::18:1485::14:::::::|h[Fishing Pole]|h|r")), "",
        "no bonus: no roll")
    assert_eq((U.link_variant("item:100::::::::18:1485:::2:500:44:::")), "44.500", "two bonuses, sorted")
    assert_eq((U.link_variant("item:15210::::::-19::60::::::")), "s-19", "a classic suffix field")
    assert_eq(U.link_variant(""), nil, "an empty link says nothing")
    assert_eq(U.link_variant("|Hspell:133|h[Fireball]|h"), nil, "not an item")
    assert_eq(U.vkey(9779, "12741"), "9779:12741", "a roll's key")
    assert_eq(U.vkey(9779, ""), "9779", "no roll: the item's own key")
    local a, b = U.unvkey("9779:12741")
    assert_eq(a, 9779, "id back")
    assert_eq(b, "12741", "roll back")
    a, b = U.unvkey(13127)
    assert_eq(b, "", "a plain id has no roll")
end }

-- =============================================================================
-- boot and scans
-- =============================================================================

T[#T + 1] = { "boots with the gear module", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("JCore boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    local ok2, err2 = pcall(require, "jambix_market/main")
    if not ok2 then error("market boot raised: " .. tostring(err2)) end
    run(3)
    fail_on_errors("boot")
    MK = _G.JambixMarket
    G = MK.gear
    assert(G, "the gear module")
    assert_eq(MK.VERSION, "1.2.2", "version")
end }

T[#T + 1] = { "a full scan reads each single item's roll, and only theirs", function()
    ah.list = scan_one()
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(6)
    fail_on_errors("scan one")
    run(2)                                    -- item info arrives
    local snap = MK.db.previous()
    assert(snap, "scanned")
    local bears = 0
    for _, l in ipairs(snap.items[SWORD]) do if l.var == BEAR then bears = bears + 1 end end
    assert_eq(bears, 12, "twelve Bears read by roll")
    assert_eq(snap.items[CROWN][1].var, "", "the crown has no roll")
    assert_eq(snap.items[LINEN][1].var, nil, "linen is a stack: its link is not read")
    assert_eq(snap.vnames[SWORD .. ":" .. BEAR], ROLL_NAME[BEAR], "the roll's name from its link")
    assert_eq(snap.singles, 31, "31 single items")
    assert_eq(snap.linked, 31, "every link answered")
    run(1)
    local bear = G.records()[SWORD .. ":" .. BEAR]
    assert(bear and bear.m, "the Bear priced on its own")
    assert(bear.m >= 100000, "about 10g: " .. tostring(bear.m))
    local monkey = G.records()[SWORD .. ":" .. MONKEY]
    assert(monkey and monkey.m < 25000, "the Monkey about 2g: " .. tostring(monkey and monkey.m))
    assert_eq(G.records()[tostring(CROWN)].nm, nil, "a roll-less item needs no name of its own")
    assert(G.meta().coverage == 1, "the scan read every link")
end }

T[#T + 1] = { "the scan's rolls survive in the saved scan, and the gear file is written", function()
    MK.db.save(true)
    G.save(true)
    local snap = mock.data_fs["jcore/jambix.market.mock.snap.json"]
    assert(snap and snap:find("," .. BEAR, 1, true), "a Bear's roll in the saved scan")
    local decoded = JCore.json.decode(snap)
    assert(decoded.items[tostring(CROWN)]:find(",0", 1, true), "no roll saved as 0")
    assert(not decoded.items[tostring(LINEN)]:find(",0", 1, true), "a stack has no roll field")
    local gear = mock.data_fs["jcore/jambix.market.mock.gear.json"]
    assert(gear and gear:find("Edged Bastard Sword of the Bear", 1, true), "the gear file has the rolls")
end }

-- Scan two, 2000 s on: three Bears, one Monkey, two crowns and three pouches
-- bought, and one Bear (3g) and one pouch (20s) listed by someone in a hurry.
local SCAN_TWO
T[#T + 1] = { "sales are counted roll by roll", function()
    SCAN_TWO = without(scan_one(), {
        { SWORD, BEAR, 100000 }, { SWORD, BEAR, 101000 }, { SWORD, BEAR, 102000 }, { SWORD, MONKEY, 20000 },
        { CROWN, nil, 50000 }, { CROWN, nil, 51000 }, { POUCH, nil, 10000 }, { POUCH, nil, 10100 },
        { POUCH, nil, 10200 },
    })
    SCAN_TWO[#SCAN_TWO + 1] = row(SWORD, BEAR, 30000)
    SCAN_TWO[#SCAN_TWO + 1] = row(POUCH, nil, 2000)
    next_scan(SCAN_TWO)
    fail_on_errors("scan two")
    run(1)
    local bear = G.records()[SWORD .. ":" .. BEAR]
    -- Three Bears left and one came: the scan does not name its sellers, so
    -- the new one is netted against them -- two buyers, never more.
    assert_near(bear.ev, 2, 0.01, "two Bear buyers")
    assert_near(G.records()[SWORD .. ":" .. MONKEY].ev, 1, 0.01, "one Monkey")
    assert_near(G.records()[tostring(CROWN)].ev, 2, 0.01, "two crowns")
    assert(G.meta().compared, "compared with the scan before")
    assert_eq(MK.deals.get(SWORD .. ":" .. BEAR), nil, "a roll needs three scans before it is judged")
end }

-- Scan three, 2000 s on: three more Bears, one Monkey, one crown and three
-- pouches bought; the cheap Bear and the cheap pouch are still there.
T[#T + 1] = { "a cheap roll is a gear deal, priced against its own roll", function()
    local three = without(SCAN_TWO, {
        { SWORD, BEAR, 103000 }, { SWORD, BEAR, 104000 }, { SWORD, BEAR, 105000 }, { SWORD, MONKEY, 21000 },
        { CROWN, nil, 52000 }, { POUCH, nil, 10300 }, { POUCH, nil, 10400 }, { POUCH, nil, 10500 },
    })
    next_scan(three)
    fail_on_errors("scan three")
    run(2)
    local d = MK.deals.get(SWORD .. ":" .. BEAR)
    assert(d, "the 3g Bear is a deal")
    assert(d.gear, "a gear deal")
    assert_eq(d.var, BEAR, "of the Bear")
    assert_eq(d.name, ROLL_NAME[BEAR], "by the roll's name")
    assert_eq(d.units, 1, "the one cheap Bear")
    assert_eq(d.max_unit, 30000, "bought at 3g")
    assert(d.resale > 90000, "resold near the Bears' price: " .. tostring(d.resale))
    assert(d.confidence >= MK.policy.bar(), "as sure as the bar: " .. tostring(d.confidence))
    assert(d.deposits >= 1377 * 0.6 - 1, "planned after a 48-hour deposit of 60% of the vendor price")
    -- The Monkeys at 2g are cheap next to a Bear but not next to a Monkey: no deal.
    assert_eq(MK.deals.get(SWORD .. ":" .. MONKEY), nil, "a Monkey is priced as a Monkey")
    -- A single item is never resold by the item's own deal (Auto could not
    -- post it): the cheap pouch is a gear deal, posted by you.
    local whole = MK.deals.get(SWORD)
    assert(not whole or whole.mode == "vendor", "no item-level resale of a sword")
    assert_eq(MK.deals.get(POUCH), nil, "no item-level resale of a pouch")
    local pouch = MK.deals.get(tostring(POUCH))
    assert(pouch and pouch.gear and pouch.var == "", "the pouch is a gear deal of its one roll")
    -- On the deal list with the rest, with a key of its own.
    local found = false
    for _, x in ipairs(MK.deals.list()) do if x.key == SWORD .. ":" .. BEAR then found = true end end
    assert(found, "on the deal list")
end }

-- =============================================================================
-- buying
-- =============================================================================

local function search_rows()
    -- What a search of the sword shows now: the cheap Bear, dear Bears, the Monkeys.
    ah.items[SWORD] = {
        { aid = 901, buyout = 30000, roll = BEAR }, { aid = 902, buyout = 103000, roll = BEAR },
        { aid = 903, buyout = 104000, roll = BEAR }, { aid = 904, buyout = 105000, roll = BEAR },
        { aid = 905, buyout = 21000, roll = MONKEY }, { aid = 906, buyout = 22000, roll = MONKEY },
    }
end

T[#T + 1] = { "a search that cannot say each auction's roll buys nothing", function()
    search_rows()
    ah.links = false
    local bids = count_calls("place_bid")
    local searches = count_calls("send_search_query")
    assert(MK.trader.buy(SWORD, { manual = true, var = BEAR }), "queued")
    run(6)
    ah.links = true
    fail_on_errors("blind")
    assert_eq(count_calls("place_bid"), bids, "never bought blind")
    assert(count_calls("send_search_query") >= searches + 2, "looked twice: the client fills links in once it has the item")
    assert(MK.trader.state().last.text:find("never bought blind", 1, true), MK.trader.state().last.text)
end }

T[#T + 1] = { "bids the game never answers stop gear buying for the session", function()
    search_rows()
    ah.bid_answers = false
    for _ = 1, 2 do
        assert(MK.trader.buy(SWORD, { manual = true, var = BEAR }), "queued")
        run(7)
    end
    ah.bid_answers = true
    fail_on_errors("no answer")
    local ok, why = G.can_buy()
    assert_eq(ok, false, "no more gear")
    assert(why:find("place_bid", 1, true), why)
    assert(activity_has("Gear: buying stopped"), "said")
    assert_eq(MK.ledger.holding(SWORD, BEAR), nil, "nothing bought")
end }

T[#T + 1] = { "Auto buys the gear deal -- that roll, at its price -- and says to post it yourself", function()
    search_rows()
    run(1)
    MK.deals.compute()
    local before = gold
    MK.auto.toggle()                                    -- Auto on: gear gets two more tries
    assert(MK.auto.active(), "on")
    assert(G.can_buy(), "gear buying again")
    run(8)
    fail_on_errors("auto gear")
    local bid = last_call("place_bid")
    assert(bid, "a bid")
    assert_eq(bid[2], 901, "on the cheap Bear")
    -- Found by its item key: the item level (18), not the level to use it (13) the scan says.
    local by_level = false
    for _, c in ipairs(ah.calls) do if c[1] == "send_search_query" and c[2] == SWORD and c[3] == 18 then by_level = true end end
    assert(by_level, "searched by the item level")
    assert_eq(bid[3], 30000, "at its buyout")
    assert_eq(before - gold, 30000, "3g paid")
    local h = MK.ledger.holding(SWORD, BEAR)
    assert(h and h.qty == 1, "one Bear held")
    assert_eq(h.mode, "gear", "held as gear: for you to post")
    assert_eq(h.name, ROLL_NAME[BEAR], "by its roll's name")
    assert_eq(MK.ledger.holding(SWORD), nil, "not as the item: the roll is its own holding")
    local buy
    for _, r in ipairs(MK.ledger.trades()) do if r.kind == "buy" and r.id == SWORD then buy = r end end
    assert(buy and buy.var == BEAR and buy.roll == BEAR, "the journal keeps the roll")
    assert(buy.expected and buy.expected > 0, "with the profit it expected")
    local said = activity_has("post it yourself")
    assert(said and said:find(ROLL_NAME[BEAR], 1, true), "said: " .. tostring(said))
    for _, c in ipairs(ah.calls) do
        assert(not (c[1] == "place_bid" and (c[2] == 905 or c[2] == 906)), "never a Monkey")
    end
    local n = G.waiting()
    assert_eq(n, 1, "one piece waiting for you")
end }

T[#T + 1] = { "two pieces waiting for you: Auto buys no more gear", function()
    -- A second piece, as if bought: two wait now.
    MK.ledger.bought(CROWN, 1, 40000, "gear", 52000, 0.99, 8000, false, { var = "", vname = NAMES[CROWN], roll = "" })
    local ok, why = G.can_buy()
    assert_eq(ok, false, "two waiting")
    assert(why:find("2 piece", 1, true), why)
    ah.items[SWORD] = { { aid = 910, buyout = 30000, roll = BEAR }, { aid = 911, buyout = 104000, roll = BEAR } }
    MK.ah.search(SWORD)
    run(1)
    local bids = count_calls("place_bid")
    run(6)
    assert_eq(count_calls("place_bid"), bids, "no more gear bought")
    MK.auto.toggle()                                    -- Auto off for what follows
end }

-- =============================================================================
-- posting it yourself
-- =============================================================================

T[#T + 1] = { "the Gear tab's list: your gear by roll, Auto's first, with the buyout to post at", function()
    put_in_bag(1, SWORD, "Item-B", BEAR)               -- Auto's Bear, out of the mailbox
    put_in_bag(2, SWORD, "Item-M", MONKEY)             -- your own Monkey
    put_in_bag(3, CROWN, "Item-C")                     -- the crown "Auto bought"
    ah.items[SWORD] = { { aid = 920, buyout = 104000, roll = BEAR }, { aid = 921, buyout = 105000, roll = BEAR },
        { aid = 922, buyout = 21000, roll = MONKEY }, { aid = 923, buyout = 22000, roll = MONKEY } }
    MK.ah.search(SWORD)
    run(1)
    G.invalidate()
    local list = G.bag_list()
    assert_eq(#list, 3, "three rolls")
    assert(list[1].auto > 0 and list[2].auto > 0, "Auto's first")
    local bear, monkey
    for _, e in ipairs(list) do
        if e.vkey == SWORD .. ":" .. BEAR then bear = e end
        if e.vkey == SWORD .. ":" .. MONKEY then monkey = e end
    end
    assert(bear and bear.name == ROLL_NAME[BEAR], "the Bear by name")
    -- The cheapest other Bear is 10g 40s: Auto's Bear is posted no higher than
    -- the usual price it was bought against (about 10g 13s).
    local usual = MK.db.risk(G.record(SWORD .. ":" .. BEAR)).usual
    assert(usual < 104000, "the usual price is under the cheapest other: " .. tostring(usual))
    assert_eq(bear.advice.price, math.floor(usual + 0.5), "at the usual price")
    assert(monkey and monkey.auto == 0, "the Monkey is yours")
    assert_eq(monkey.advice.price, 20999, "priced as a Monkey, 1c under the cheapest other Monkey, not as a Bear")
    assert_near(bear.advice.deposit, 1377 * 0.6, 0.5, "48-hour deposit: 60% of the vendor price")
    -- The bags agree: a single item is yours to post, never Auto's.
    MK.bags.invalidate()
    local seen = 0
    for _, a in ipairs(MK.bags.list()) do
        if a.id == SWORD or a.id == CROWN then
            assert_eq(a.action, "hand", MK.db.name(a.id) .. ": you post it")
            seen = seen + 1
        end
    end
    assert_eq(seen, 2, "both listed")
    local line = G.post_line(G.to_post())
    assert(line:find(ROLL_NAME[BEAR] .. " at " .. MK.util.money(bear.advice.price), 1, true), line)
end }

T[#T + 1] = { "Auto never posts gear, nor sells it to a vendor", function()
    MK.auto.toggle()
    assert(MK.auto.active(), "on")
    run(6)
    assert_eq(count_calls("post_item"), 0, "no post_item")
    local sold = 0
    mock.core.input.use_container_item = function() sold = sold + 1 end
    mock.game_event("MERCHANT_SHOW", {})
    run(4)
    mock.game_event("MERCHANT_CLOSED", {})
    run(0.3)
    fail_on_errors("no auto gear")
    assert_eq(sold, 0, "nothing of it to a vendor")
    MK.auto.toggle()
end }

T[#T + 1] = { "your post of Auto's gear joins its lot, deposit and all; Auto never cancels it", function()
    -- You post the Bear: the deposit leaves your gold as the auction is made.
    gold = gold - 826
    mock.time = mock.time + 1
    run(2.5)                                           -- the gold poll sees the drop
    mock.game_event("AUCTION_HOUSE_AUCTION_CREATED", { 950 })
    bag[1].present = false
    sync_bags()
    ah.owned = { { auction_id = 950, item_id = SWORD, item_link = link_of(SWORD, BEAR), quantity = 1,
        buyout_amount = 103999, bid_amount = 0, status = 0, time_left = 0 } }
    MK.trader.refresh_owned()
    run(1)
    fail_on_errors("adopt")
    local post = MK.trader.posts()["950"]
    assert(post and post.hand, "taken in as your post")
    assert_eq(post.var, BEAR, "of the Bear")
    assert_eq(post.deposit, 826, "the deposit as it was taken")
    local fee, posted
    for _, r in ipairs(MK.ledger.trades()) do
        if r.kind == "fee" and r.var == BEAR then fee = r end
        if r.kind == "post" and r.var == BEAR then posted = r end
    end
    assert(fee and fee.copper == 826 and not fee.est, "a deposit fee, seen taken")
    assert(posted and posted.by == "you", "a post row: yours")
    assert_eq(MK.ledger.holding(SWORD, BEAR).lot.fees, 826, "the lot carries it")
    -- Only the crown waits now.
    assert_eq((G.waiting()), 1, "the Bear is up")
    -- Its own roll's cheapest is 10g 40s: the 2g Monkeys do not undercut it.
    local owned = MK.trader.owned()
    assert_eq(owned[1].status, "cheapest", "cheapest of its roll")
    assert_eq(owned[1].name, ROLL_NAME[BEAR], "by its roll's name")
    -- Even undercut, Auto leaves it: it could not post it again.
    ah.items[SWORD] = { { aid = 930, buyout = 90000, roll = BEAR }, { aid = 950, buyout = 103999, roll = BEAR, own = true } }
    MK.ah.search(SWORD)
    run(1)
    assert_eq(MK.trader.owned()[1].status, "undercut", "undercut by another Bear")
    MK.auto.toggle()
    run(12)
    MK.auto.toggle()
    assert_eq(count_calls("cancel_auction"), 0, "never cancelled")
end }

T[#T + 1] = { "the Bear sells: the mail names the roll, and the lot is done", function()
    local mails = { { subject = "Auction successful: " .. ROLL_NAME[BEAR], money = math.floor(103999 * 0.95 + 826 + 0.5),
        item_count = 0 } }
    mock.core.mail = {
        get_num_inbox_items = function() return #mails end,
        get_inbox_header_info = function(i) return mails[i] end,
        take_inbox_money = function(i) gold = gold + mails[i].money; table.remove(mails, i) end,
        auto_loot_mail_item = function(i) table.remove(mails, i) end,
    }
    ah.owned[1].status = 1                              -- sold
    MK.trader.refresh_owned()
    run(1)
    mock.game_event("MAIL_SHOW", {})
    run(1)
    assert(MK.ledger.collect(), "collecting")
    run(4)
    fail_on_errors("sale")
    assert_eq(#mails, 0, "taken")
    assert_eq(MK.ledger.holding(SWORD, BEAR), nil, "the Bear lot is done")
    local sale
    for _, r in ipairs(MK.ledger.trades()) do if r.kind == "sell" and r.id == SWORD then sale = r end end
    assert(sale and sale.var == BEAR and sale.mine == 1, "Auto's Bear sold, by roll")
    assert_near(sale.copper - sale.basis, 103999 * 0.95 + 826 - 30000, 1, "made what the mail paid less what it cost")
    assert(MK.trader.posts()["950"].settled, "the post is settled")
    local said = activity_has("Lot of " .. ROLL_NAME[BEAR] .. " done")
    assert(said, "the lot is done")
    mock.game_event("MAIL_CLOSED", {})
    run(0.5)
end }

T[#T + 1] = { "a cheap roll with too few buyers seen is shown, never bought", function()
    -- Scan four: a crown at 2g among five at 5g and more (crowns go for 5g);
    -- nothing sold. (With only one or two others listed, one cheap crown
    -- would read as the price moving: pricing.level_shift.)
    local four = {}
    for _, r in ipairs(MK.db.previous().items[CROWN]) do four[#four + 1] = row(CROWN, nil, r.unit) end
    for _, r in ipairs(MK.db.previous().items[POUCH]) do four[#four + 1] = row(POUCH, nil, r.unit) end
    for k = 4, 7 do four[#four + 1] = row(CROWN, nil, 50000 + 1000 * k) end
    four[#four + 1] = row(CROWN, nil, 20000)
    four[#four + 1] = { id = LINEN, count = 20, unit = 100, owner = "", band = 3 }
    next_scan(four, 600)
    fail_on_errors("scan four")
    run(2)
    assert_eq(MK.deals.get(tostring(CROWN)), nil, "three crowns bought in two scans: not 99% sure of a buyer")
    -- The crown Auto held sells to the same buyers as a new one: with it
    -- held, two would have to sell (26% sure: not even shown). It sold.
    MK.ledger.sold(CROWN, 1, 50000, NAMES[CROWN], "")
    G.invalidate()
    local near = nil
    for _, d in ipairs(G.near()) do if d.key == tostring(CROWN) then near = d end end
    assert(near, "shown as cheap but not sure enough")
    assert(near.confidence < MK.policy.bar() and near.confidence >= 0.5, "how sure: " .. tostring(near.confidence))
    assert_eq(near.max_unit, 20000, "the 2g crown")
end }

-- =============================================================================
-- the review (1.2.0)
-- =============================================================================

--- A piece of gear Auto holds, as if bought: { id, roll ("" none), cost, aid }.
local function hold(id, roll, cost, aid)
    MK.ledger.bought(id, 1, cost, "gear", cost * 3, 0.99, cost, false,
        { var = roll, vname = roll ~= "" and ROLL_NAME[roll] or NAMES[id], roll = roll, aid = aid })
end

local function clear_bags()
    for slot = 1, 16 do bag[slot] = nil end
    sync_bags()
end

T[#T + 1] = { "review: a vendor flip of the same item never takes Auto's gear piece", function()
    clear_bags()
    -- Auto holds a Bear as gear, and bought a Monkey to sell to a vendor.
    hold(SWORD, BEAR, 30000, 1)
    MK.ledger.bought(SWORD, 1, 500, "vendor", 1377, 1, 877, false, { roll = MONKEY })
    put_in_bag(4, SWORD, "Item-GB", BEAR)
    put_in_bag(5, SWORD, "Item-VM", MONKEY)
    MK.bags.invalidate()
    G.invalidate()
    local sold = {}
    mock.core.input.use_container_item = function(b, s)
        sold[#sold + 1] = s
        gold = gold + 1377
        bag[s].present = false
        sync_bags()
    end
    -- At a merchant (the auction house shut), with Auto on.
    ah.open = false
    mock.game_event("AUCTION_HOUSE_CLOSED", {})
    run(0.5)
    MK.auto.toggle()
    mock.game_event("MERCHANT_SHOW", {})
    run(4)
    mock.game_event("MERCHANT_CLOSED", {})
    run(0.3)
    MK.auto.toggle()
    fail_on_errors("vendor guard")
    assert_eq(table.concat(sold, ","), "5", "only the Monkey bought for a vendor")
    assert(MK.ledger.holding(SWORD, BEAR) and MK.ledger.holding(SWORD, BEAR).qty == 1, "the gear Bear is still Auto's")
    assert_eq(MK.ledger.holding(SWORD), nil, "the vendor flip is done")
    -- Gear with no roll keeps a key of its own: a vendor flip of the same
    -- item never takes its place, nor changes it into a vendor flip.
    hold(CROWN, "", 40000, 2)
    MK.ledger.bought(CROWN, 1, 2000, "vendor", 3021, 1, 1021, false, nil)
    assert_eq(MK.ledger.holding(CROWN, "").mode, "gear", "the crown held as gear")
    assert_eq(MK.ledger.holding(CROWN, "").qty, 1, "one")
    assert_eq(MK.ledger.holding(CROWN).mode, "vendor", "the other crown, for a vendor")
    -- Clean up for what follows: the vendor crown sells, the gear pieces become yours.
    MK.ledger.sold(CROWN, 1, 3021, "vendor")
    MK.ledger.release(CROWN, 1, "", "test")
    MK.ledger.release(SWORD, 1, BEAR, "test")
    clear_bags()
end }

T[#T + 1] = { "review: the cap of two waiting holds piece by piece", function()
    ah.open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(1)
    assert_eq((G.waiting()), 0, "nothing waiting")
    -- Two cheap Bears: worth buying together (each alone would be undercut by the other).
    ah.items[SWORD] = { { aid = 960, buyout = 30000, roll = BEAR }, { aid = 961, buyout = 30500, roll = BEAR } }
    for k = 0, 5 do ah.items[SWORD][#ah.items[SWORD] + 1] = { aid = 962 + k, buyout = 106000 + 1000 * k, roll = BEAR } end
    -- With one piece's room, the plan buys no more than one: here, nothing pays.
    hold(POUCH, "", 2000, 3)
    local o = MK.deals.options()
    o.size, o.budget = true, 5000000
    local rows = {}
    for _, r in ipairs(ah.items[SWORD]) do rows[#rows + 1] = { unit = r.buyout, qty = 1, buyout = r.buyout, var = BEAR } end
    local capped = G.plan_for(SWORD .. ":" .. BEAR, rows, o)
    assert(not capped or capped.units <= 1, "a purchase never plans past the room")
    MK.ledger.release(POUCH, 1, "", "test")
    -- With room for two, both are planned; another piece arriving after the
    -- first bid stops the second.
    local real = mock.core.auction_house.place_bid
    mock.core.auction_house.place_bid = function(aid, amount)
        real(aid, amount)
        if aid == 960 then hold(POUCH, "", 2000, 4) end
    end
    local bids = count_calls("place_bid")
    assert(MK.trader.buy(SWORD, { manual = true, var = BEAR }), "queued")
    run(6)
    mock.core.auction_house.place_bid = real
    fail_on_errors("cap")
    assert_eq(count_calls("place_bid"), bids + 1, "one bid, not two")
    assert_eq(last_call("place_bid")[2], 960, "the first Bear")
    assert_eq((G.waiting()), 2, "two waiting: the cap")
    MK.ledger.release(POUCH, 1, "", "test")
end }

T[#T + 1] = { "review: your post of a piece that leaves unsold is no sale, and your repost is taken in", function()
    put_in_bag(6, SWORD, "Item-B2", BEAR)               -- the Bear just bought
    local function post(aid)
        gold = gold - 826
        mock.time = mock.time + 1
        run(2.5)
        mock.game_event("AUCTION_HOUSE_AUCTION_CREATED", { aid })
        ah.owned = { { auction_id = aid, item_id = SWORD, item_link = link_of(SWORD, BEAR), quantity = 1,
            buyout_amount = 101000, bid_amount = 0, status = 0, time_left = 0 } }
        run(3)                                            -- your auctions are read at once
    end
    post(970)
    fail_on_errors("post 970")
    assert(MK.trader.posts()["970"] and MK.trader.posts()["970"].hand, "taken in")
    assert_eq((G.waiting()), 0, "posted: nothing waiting")
    -- You cancel it: it leaves your auctions without being seen sold.
    ah.owned = {}
    MK.trader.refresh_owned()
    run(1)
    local p = MK.trader.posts()["970"]
    assert(p.gone and not p.sold, "gone, not sold")
    assert_eq(MK.trader.mail_waiting().coming, 0, "no money on its way")
    assert_eq((G.waiting()), 1, "the Bear waits for you again")
    -- You post it again: taken in, with its own deposit.
    post(971)
    fail_on_errors("post 971")
    assert(MK.trader.posts()["971"] and MK.trader.posts()["971"].hand, "the repost is taken in")
    local fees = 0
    for _, r in ipairs(MK.ledger.trades()) do
        if r.kind == "fee" and r.var == BEAR and r.copper == 826 then fees = fees + 1 end
    end
    assert(fees >= 2, "a deposit for each post: " .. fees)
    assert_eq(MK.ledger.holding(SWORD, BEAR).lot.fees, 1652, "the lot carries both")
end }

T[#T + 1] = { "review: your own auction of the roll, made before Auto bought it, is not taken in", function()
    hold(SWORD, MONKEY, 15000, 980)                     -- Auto's Monkey, bought from auction 980
    local list = { { auction_id = 971, item_id = SWORD, item_link = link_of(SWORD, BEAR), quantity = 1,
        buyout_amount = 101000, bid_amount = 0, status = 0, time_left = 0 } }
    -- Your own Monkey, posted before (auction 940, never seen made this
    -- session, and older than the auction Auto bought).
    list[#list + 1] = { auction_id = 940, item_id = SWORD, item_link = link_of(SWORD, MONKEY), quantity = 1,
        buyout_amount = 25000, bid_amount = 0, status = 0, time_left = 0 }
    ah.owned = list
    MK.trader.refresh_owned()
    run(1)
    assert_eq(MK.trader.posts()["940"], nil, "yours: not Auto's piece")
    assert_eq((G.waiting()), 1, "Auto's Monkey still waits")
    -- An auction made after (a higher id) is Auto's piece.
    list[#list + 1] = { auction_id = 990, item_id = SWORD, item_link = link_of(SWORD, MONKEY), quantity = 1,
        buyout_amount = 25000, bid_amount = 0, status = 0, time_left = 0 }
    MK.trader.refresh_owned()
    run(1)
    assert(MK.trader.posts()["990"] and MK.trader.posts()["990"].hand, "taken in")
    assert_eq((G.waiting()), 0, "nothing waiting")
end }

T[#T + 1] = { "review: a piece that is nowhere -- not in the bags, your auctions or the mailbox -- becomes yours", function()
    hold(POUCH, "", 2000, 5)                            -- Auto's pouch: you equipped it, say
    assert_eq((G.waiting()), 1, "waiting")
    mock.time = mock.time + 120
    local mails = {}
    mock.core.mail = {
        get_num_inbox_items = function() return #mails end,
        get_inbox_header_info = function(i) return mails[i] end,
        take_inbox_money = function() end,
        auto_loot_mail_item = function() end,
    }
    mock.game_event("MAIL_SHOW", {})
    run(1)
    mock.game_event("MAIL_CLOSED", {})
    run(0.5)
    MK.trader.refresh_owned()
    run(12)
    fail_on_errors("reconcile")
    assert_eq(MK.ledger.holding(POUCH, ""), nil, "taken off Auto's stock")
    local kept
    for _, r in ipairs(MK.ledger.trades()) do if r.kind == "kept" and r.id == POUCH and r.note ~= "test" then kept = r end end
    assert(kept and kept.basis == 2000, "as yours, at its cost")
    assert_eq((G.waiting()), 0, "nothing waiting: gear buying goes on")
    -- The Bear (in your auctions) and the Monkey (in your auctions) stay Auto's.
    assert(MK.ledger.holding(SWORD, BEAR), "the posted Bear stays")
    assert(MK.ledger.holding(SWORD, MONKEY), "the posted Monkey stays")
    assert(MK.ledger.totals().kept >= 2000, "the all-time totals say so")
end }

T[#T + 1] = { "review: a listing whose link did not answer is not read as a sale", function()
    local list = {}
    for k = 0, 5 do list[#list + 1] = row(SWORD, BEAR, 106000 + 1000 * k) end
    for k = 0, 2 do list[#list + 1] = row(SWORD, MONKEY, 20000 + 1000 * k) end
    for k = 0, 3 do list[#list + 1] = row(CROWN, nil, 50000 + 1000 * k) end
    list[#list + 1] = { id = LINEN, count = 20, unit = 100, owner = "", band = 3 }
    next_scan(list, 600)
    fail_on_errors("scan five")
    run(1)
    local bear = G.records()[SWORD .. ":" .. BEAR]
    local ev = bear.ev
    -- The same list; one Bear's link does not answer this time.
    local same = {}
    for i, r in ipairs(list) do
        same[i] = { id = r.id, roll = r.roll, count = r.count, unit = r.unit, owner = r.owner, band = r.band }
    end
    same[1].nolink = true
    same[12].unit = 54000                                -- a crown repriced: a new list, not the last one again
    local real = mock.core.auction_house.get_replicate_item_link
    mock.core.auction_house.get_replicate_item_link = function(i)
        local r = ah.list[i + 1]
        if r and r.nolink then return "" end
        return real(i)
    end
    local five_at = MK.db.previous().at
    next_scan(same, 600)
    run(4)                                               -- the passes over the blank link
    mock.core.auction_house.get_replicate_item_link = real
    fail_on_errors("scan six")
    run(1)
    local six = MK.db.previous()
    assert(six.at > five_at, "scan six was read and folded")
    assert_eq(six.linked, six.singles - 1, "the one Bear's link never answered")
    assert(G.meta().compared, "the scan was compared")
    assert_eq(G.records()[SWORD .. ":" .. BEAR].ev, ev, "no sale read for the Bears")
end }

T[#T + 1] = { "a link that comes back blank is asked again; a roll-less item's blank link is its one roll", function()
    -- The client answers an auction's first link ask blank, then fills it in
    -- (the user's scans, 2026-10-10: one in ten blank).
    local asked = {}
    local real = mock.core.auction_house.get_replicate_item_link
    mock.core.auction_house.get_replicate_item_link = function(i)
        local r = ah.list[i + 1]
        if r and not asked[i] then
            asked[i] = true
            return ""
        end
        if r and r.blank then return "" end
        return real(i)
    end
    local list = {}
    for k = 0, 5 do list[#list + 1] = row(SWORD, BEAR, 106000 + 1000 * k) end
    for k = 0, 3 do list[#list + 1] = row(CROWN, nil, 50000 + 1000 * k) end
    list[#list + 1] = { id = LINEN, count = 20, unit = 100, owner = "", band = 3 }
    next_scan(list, 600)
    fail_on_errors("relink scan")
    local snap = MK.db.previous()
    assert_eq(snap.linked, snap.singles, "every blank link read on a later pass")
    -- A crown's link that never answers: crowns have one roll, so it is that roll.
    asked = {}
    local again = {}
    for i, r in ipairs(list) do again[i] = { id = r.id, roll = r.roll, count = r.count, unit = r.unit, owner = r.owner,
        band = r.band } end
    again[7].blank = true                                -- a crown
    again[6].unit = 120000                               -- a new list, not the last one again
    next_scan(again, 600)
    run(4)                                               -- the passes over blank links, a second or two apart
    mock.core.auction_house.get_replicate_item_link = real
    fail_on_errors("blank crown")
    run(1)
    snap = MK.db.previous()
    assert_eq(snap.linked, snap.singles - 1, "one link never answered")
    assert(G.is_plain(CROWN), "the crown has one roll")
    assert(G.meta().compared, "compared all the same: no scan-wide bar")
    assert_eq(G.records()[tostring(CROWN)].q, 4, "all four crowns counted as its roll")
    local ok = G.can_buy()
    assert(ok, "gear buying is not held back by links a scan missed")
end }

-- =============================================================================
-- the window
-- =============================================================================

T[#T + 1] = { "the Gear tab draws: what to post, the deals, and what was passed over", function()
    local drawn = {}
    local real = mock.core.graphics.text_2d
    mock.core.graphics.text_2d = function(text, ...)
        drawn[#drawn + 1] = tostring(text)
        return real(text, ...)
    end
    MK.window.show()
    MK.window.set_tab(3)
    run(0.5)
    for tab = 1, 8 do
        MK.window.set_tab(tab)
        run(0.3)
    end
    mock.core.graphics.text_2d = real
    fail_on_errors("gear tab")
    local all = table.concat(drawn, " | ")
    assert(all:find("Post these yourself", 1, true), "the post list")
    assert(all:find("of the Monkey", 1, true), "your Monkey's roll, in its own column")
    assert(all:find("Gear deals", 1, true), "the deals")
    for _, t in ipairs(drawn) do
        assert(not t:find("table: ", 1, true), "a cell was drawn as a table: " .. t)
    end
end }

return T

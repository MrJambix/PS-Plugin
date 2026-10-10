-- Jambix Gear Post Test (scripts/jambix_postprobe) against a fake Forever
-- auction house: it finds the way that lists gear, cancels that auction so
-- the item comes back, and says what the game answered for every way.

local mock = require("mock_core")
mock.install()
mock.frame_dt = 0.1
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
    if got ~= want then error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2) end
end

-- The bags: a sword (gear) in slot 3, ore (a commodity) in slot 5, slots 2 and 4 empty.
local SWORD, ORE = 2000, 2771
local bag = {
    [3] = { id = SWORD, guid = "Item-SWORD", stack = 1 },
    [5] = { id = ORE, guid = "Item-ORE", stack = 20 },
}
local function item_obj(e)
    return setmetatable({}, { __index = function(_, k)
        if k == "get_item_id" then return function() return e.id end end
        if k == "get_guid" then return function() return e.guid end end
        if k == "get_item_stack_count" then return function() return e.stack end end
        return nil
    end })
end
local function sync()
    local rows = {}
    for slot = 1, 16 do
        local e = bag[slot]
        if e then rows[#rows + 1] = { item = item_obj(e), bag_id = 0, bag_slot = slot, stack_count = e.stack } end
    end
    bag_helper.rows = rows
end
sync()
mock.core.quests = mock.core.quests or {}
mock.core.quests.get_item_info = function(id)
    if id == SWORD then return { name = "Test Sword", stack_count = 1, sell_price = 500, quality = 2, bind_type = 2 } end
    if id == ORE then return { name = "Copper Ore", stack_count = 20, sell_price = 5, quality = 1, bind_type = 0 } end
    return {}
end

-- The fake auction house. `accepts(kind, bag, slot, bid, buyout)` decides; a
-- refusal fires the given UI error, or nothing at all.
local S = { open = true, calls = {}, events = {}, auctions = {}, next_aid = 900, accepts = nil, refuse_error = nil,
    exec_runs = false, exec_posts = false }
local function later(name, args) S.events[#S.events + 1] = { name, args or {} } end
local function try_post(kind, b, s, bid, buyout)
    S.calls[#S.calls + 1] = { kind, b, s, bid, buyout }
    local e = bag[s]
    if b == 0 and e and S.accepts and S.accepts(kind, b, s, bid, buyout) then
        S.next_aid = S.next_aid + 1
        S.auctions[S.next_aid] = { item_id = e.id, slot = s, e = e }
        bag[s] = nil
        sync()
        later("AUCTION_HOUSE_AUCTION_CREATED", { S.next_aid })
    elseif S.refuse_error then
        later("UI_ERROR_MESSAGE", { 999, S.refuse_error[2], S.refuse_error[1] })
    end
    return false                                -- Forever answers false either way
end
mock.core.auction_house = {
    is_auction_house_shown = function() return S.open end,
    get_item_commodity_status = function(b, s)
        local e = bag[s]
        if not e then return 0 end
        return e.stack > 1 and 2 or 1
    end,
    post_item = function(b, s, d, q, bid, buyout) return try_post("item", b, s, bid, buyout) end,
    post_commodity = function(b, s, d, q, unit) return try_post("commodity", b, s, nil, unit) end,
    cancel_auction = function(aid)
        S.calls[#S.calls + 1] = { "cancel", aid }
        local a = S.auctions[aid]
        if a then
            bag[a.slot] = a.e
            S.auctions[aid] = nil
            sync()
            later("AUCTION_CANCELED", { aid })
        end
    end,
    query_owned_auctions = function() later("OWNED_AUCTIONS_UPDATED") end,
    get_num_owned_auctions = function() return 0 end,
    get_item_info = function() return {} end,
}
mock.core.execute = function(code)
    S.calls[#S.calls + 1] = { "execute", code }
    if not S.exec_runs then return end
    if code:find("RequestTimePlayed", 1, true) then later("TIME_PLAYED_MSG", { 1000, 100 }) end
    if code:find("C_AuctionHouse.PostItem", 1, true) and S.exec_posts then
        local e = bag[3]
        if e then
            S.next_aid = S.next_aid + 1
            S.auctions[S.next_aid] = { item_id = e.id, slot = 3, e = e }
            bag[3] = nil
            sync()
            later("AUCTION_HOUSE_AUCTION_CREATED", { S.next_aid })
        end
    end
end

local function run(seconds)
    local n = math.max(1, math.floor(seconds / mock.frame_dt + 0.5))
    for _ = 1, n do
        mock.frame(1)
        if #S.events > 0 then
            local evs = S.events
            S.events = {}
            for _, e in ipairs(evs) do mock.game_event(e[1], e[2]) end
        end
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then error(label .. ":\n" .. mock.error_text()) end
end

local PP
local function sword()
    for _, it in ipairs(PP.candidates()) do if it.id == SWORD then return it end end
    return nil
end

local function test_until_done(limit)
    for _ = 1, (limit or 900) do
        run(0.1)
        local st = PP.state()
        if st and st.step == "done" then return st end
    end
    return PP.state()
end

local T = {}

T[#T + 1] = { "boot: only the gear is offered, never the stack", function()
    require("jcore/main")
    require("jambix_postprobe/main")
    PP = _G.JambixPostProbe
    run(2)
    fail_on_errors("boot")
    assert(PP, "the test plugin loaded")
    local c = PP.candidates()
    assert_eq(#c, 1, "one candidate")
    assert_eq(c[1].id, SWORD, "the sword")
    assert_eq(c[1].slot, 3, "in slot 3")
end }

T[#T + 1] = { "the client takes only a buyout-only post: way A is found and the auction cancelled", function()
    S.accepts = function(kind, b, s, bid, buyout) return kind == "item" and s == 3 and bid == 0 and buyout > 0 end
    S.refuse_error = { "ERR_AUCTION_BID_TOO_HIGH", "The bid must be lower than the buyout." }
    PP.begin(sword())
    local st = test_until_done()
    fail_on_errors("way A")
    assert_eq(st.step, "done", "finished")
    assert(st.verdict:find("FOUND: post_item, buyout only", 1, true), st.verdict)
    assert(st.cancelled and st.cancelled:find("cancelled", 1, true), tostring(st.cancelled))
    assert(bag[3] and bag[3].id == SWORD, "the sword is back in its slot")
    local saved = PP.saved()
    assert(saved and saved.verdict == st.verdict, "saved to the file")
    assert_eq(saved.attempts[1].key, "A", "A tried first")
    assert_eq(saved.attempts[1].listed, true, "A listed it")
    assert_eq(#saved.attempts, 1, "stopped at the first that worked")
end }

T[#T + 1] = { "post_item never answers; the game's own PostItem through execute does: way G is found", function()
    S.accepts = function() return false end
    S.refuse_error = nil                        -- the game says nothing back to post_item
    S.exec_runs, S.exec_posts = true, true
    PP.begin(sword())
    local st = test_until_done()
    fail_on_errors("way G")
    assert(st.exec and st.exec.works, "execute seen running game Lua")
    assert_eq(st.exec.signal, "TIME_PLAYED_MSG", "by the /played answer")
    assert(st.verdict:find("FOUND: the game's C_AuctionHouse.PostItem", 1, true), st.verdict)
    assert(bag[3] and bag[3].id == SWORD, "the sword is back")
    -- A to F tried and silent, G listed it; no slot-shift tried after a find.
    local keys = {}
    for _, a in ipairs(st.done) do keys[#keys + 1] = a.key .. (a.listed and "!" or "") end
    assert_eq(table.concat(keys, " "), "A B C D E F G!", "the order")
end }

T[#T + 1] = { "nothing works: every reason the game gave is in the verdict, and the slot-shift ways ran only on empty slots", function()
    S.accepts = function() return false end
    S.refuse_error = { "ERR_AUCTION_REPAIR_ITEM", "You must repair that item before you can auction it." }
    S.exec_runs, S.exec_posts = false, false
    local before = #S.calls
    PP.begin(sword())
    local st = test_until_done()
    fail_on_errors("nothing")
    assert(st.verdict:find("No way listed it", 1, true), st.verdict)
    assert(st.verdict:find("ERR_AUCTION_REPAIR_ITEM", 1, true), "the reason: " .. st.verdict)
    local g = nil
    for _, a in ipairs(st.done) do if a.key == "G" then g = a end end
    assert(g and not g.tried and g.skipped:find("execute", 1, true), "G skipped: execute did not run")
    -- H+ (slot 4) and H- (slot 2) are empty, so both were tried; the ore (slot 5) never posted.
    local shifted = {}
    for i = before + 1, #S.calls do
        local c = S.calls[i]
        if c[1] == "item" and c[3] ~= 3 then shifted[#shifted + 1] = c[3] end
    end
    table.sort(shifted)
    assert_eq(table.concat(shifted, ","), "2,4", "only the empty neighbours")
    assert(bag[5] and bag[5].id == ORE, "the ore untouched")
end }

T[#T + 1] = { "a neighbour that holds an item is never posted at", function()
    bag[4] = { id = ORE, guid = "Item-ORE-2", stack = 20 }
    sync()
    local before = #S.calls
    PP.begin(sword())
    local st = test_until_done()
    fail_on_errors("neighbour")
    for i = before + 1, #S.calls do
        local c = S.calls[i]
        assert(not (c[1] == "item" and c[3] == 4), "slot 4 holds ore: never posted at")
    end
    local hplus = nil
    for _, a in ipairs(st.done) do if a.key == "H+" then hplus = a end end
    assert(hplus and not hplus.tried, "H+ skipped")
    bag[4] = nil
    sync()
end }

T[#T + 1] = { "the window draws idle, mid-test and with a result", function()
    local drawn = {}
    local real = mock.core.graphics.text_2d
    mock.core.graphics.text_2d = function(text, ...) drawn[#drawn + 1] = tostring(text) return real(text, ...) end
    PP.show()
    run(0.5)                                   -- idle: the saved result and the item list
    S.accepts = function(kind, b, s, bid) return kind == "item" and bid == 0 end
    PP.begin(sword())
    run(0.3)                                   -- mid-test
    test_until_done()
    run(0.5)                                   -- the result
    mock.core.graphics.text_2d = real
    fail_on_errors("window")
    local all = table.concat(drawn, " | ")
    assert(all:find("Test with: Test Sword", 1, true) or all:find("Testing Test Sword", 1, true), "the item list")
    assert(all:find("FOUND", 1, true), "the verdict drawn")
end }

return T

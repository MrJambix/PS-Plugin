-- Jambix AIO: the vendor and the quest givers on Forever (modules/forever_npc.lua).
--
-- Pinned here:
--   * junk: at a merchant every grey item with a sell price is sold, one at a
--     time, and nothing else is; each sale is checked by where each carried
--     item sits (by guid), because on Forever a sold item STAYS in the
--     player's item array (buyback): a sale is the item leaving its slot, and
--     any other carried item leaving its slot stops selling for the session;
--     a sale that left its item in place is skipped, three end the visit;
--     an item with no guid, or a helper row older than the bags, is never
--     pressed; Shift held as the window opens, or the switch off, sells nothing;
--     the helper's bag 0 rows past the backpack (Buyback) are neither sold
--     nor watched (1.66.2);
--   * quests: a giver's finished quest is handed in before anything new is
--     taken; grey, repeatable and ignored quests are left; a quest picked
--     twice in a minute is left to the player; the detail window is accepted,
--     the progress window continued, never before the short human delay;
--   * the reward: gear the class can use, of the armour it should wear, not
--     below what is worn, wins; the role picks between weapons and shields;
--     when nothing fits, the choice that sells for the most; a choice whose
--     item data never comes is waited for, then decided without.

-- run.js already searches scripts/, after any JTEST_OVERLAY copy; a prefix
-- here would hide the staged copy, so it is only for running outside it.
if not jtest then package.path = "scripts/?.lua;" .. package.path end

local factory = require("jambix_aio/modules/forever_npc")

local T = {}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_true(v, label)
    if not v then error(label, 2) end
end

local function count_calls(W, name)
    local n = 0
    for i = 1, #W.calls do if W.calls[i][1] == name then n = n + 1 end end
    return n
end

local function last_call(W, name)
    for i = #W.calls, 1, -1 do if W.calls[i][1] == name then return W.calls[i] end end
    return nil
end

local function has_trace(W, pattern)
    for i = 1, #W.traces do if W.traces[i]:find(pattern) then return true end end
    return false
end

local function item(id, guid)
    return {
        get_item_id = function() return id end,
        get_item_stack_count = function(self) return self.n or 1 end,
        get_guid = function() return guid end,
    }
end

--- A bag row's guid, made once from where it was first seen. `false` in
--- W.guidless makes an item answer no guid, as a client might.
local function guid_of_row(W, key, row)
    if W.guidless then return nil end
    row.guid = row.guid or ("Item-" .. key .. "-" .. tostring(row.id))
    return row.guid
end

--- A fresh world and a fresh module.
---@param opts? table
local function setup(opts)
    opts = opts or {}
    local W = {
        clock = 1000.0, settings = {
            npc_sell_junk = true, npc_accept_quests = true, npc_turn_in_quests = true,
        },
        shift = false, master = true,
        calls = {}, traces = {}, handlers = {},
        info = {}, bags = {}, remap = {}, drop_sales = false,
        -- Forever (2026-10-03): a sold item stays in bag 0's array, in the
        -- buyback slots after the backpack, newest first, so older ones move.
        buyback = {}, linger = true, stale = {},
        gossip_active = {}, gossip_available = {}, choices = {},
        greeting_active = {}, greeting_available = {},
        class = "HUNTER", profile = "leveling", level = 12, worn = {},
    }
    for k, v in pairs(opts) do W[k] = v end

    local function rec(name, ...) W.calls[#W.calls + 1] = { name, ... } end

    --- Bag rows as inventory_helper reports them.
    local helper = {}
    function helper.get_character_bag_slots()
        local out = {}
        local rows = {}
        for key, row in pairs(W.bags) do rows[key] = row end
        for key, row in pairs(W.stale) do rows[key] = row end      -- the helper's older picture
        for key, row in pairs(rows) do
            local bag, slot = key:match("^(%d+):(%d+)$")
            local obj = item(row.id, guid_of_row(W, key, row))
            obj.n = row.n
            out[#out + 1] = { item = obj, bag_id = tonumber(bag), bag_slot = tonumber(slot), stack_count = row.n }
        end
        if W.helper_buyback then
            -- The real helper on Forever (2026-10-04): bag 0 comes from the
            -- player's whole item array, and the Buyback list with it, as
            -- bag 0 slots past the backpack.
            for i = 1, #W.buyback do
                local row = W.buyback[i]
                local obj = item(row.id, row.guid)
                obj.n = row.n
                out[#out + 1] = { item = obj, bag_id = 0, bag_slot = 64 + i, stack_count = row.n }
            end
        end
        table.sort(out, function(a, b)
            if a.bag_id ~= b.bag_id then return a.bag_id < b.bag_id end
            return a.bag_slot < b.bag_slot
        end)
        return out
    end
    package.loaded["common/utility/inventory_helper"] = helper

    _G.core = {
        time = function() return W.clock end,
        inventory = {
            -- Bag 0 is the whole player array: the backpack from slot_id 36,
            -- then the buyback list from 100.
            get_items_in_bag = function(bag)
                local out = {}
                for key, row in pairs(W.bags) do
                    local b, slot = key:match("^(%d+):(%d+)$")
                    if tonumber(b) == bag then
                        local obj = item(row.id, guid_of_row(W, key, row))
                        obj.n = row.n
                        out[#out + 1] = { object = obj, slot_id = (bag == 0 and 35 or 0) + tonumber(slot) }
                    end
                end
                if bag == 0 then
                    for i = 1, #W.buyback do
                        local row = W.buyback[i]
                        local obj = item(row.id, row.guid)
                        obj.n = row.n
                        out[#out + 1] = { object = obj, slot_id = 99 + i }
                    end
                end
                return out
            end,
        },
        input = {
            is_key_pressed = function(k) return W.shift and k == 0x10 end,
            use_container_item = function(bag, slot)
                rec("use", bag, slot)
                if W.drop_sales then return true end
                local key = W.remap[tostring(bag) .. ":" .. tostring(slot)] or (tostring(bag) .. ":" .. tostring(slot))
                local row = W.bags[key]
                W.bags[key] = nil
                if row and W.linger then
                    table.insert(W.buyback, 1, row)
                    if #W.buyback > 12 then W.buyback[13] = nil end
                end
                return true
            end,
        },
        quests = {
            get_item_info = function(key)
                local id = type(key) == "number" and key or tonumber(tostring(key):match("item:(%d+)"))
                return (id and W.info[id]) or {}
            end,
            get_gossip_active_quests = function() return W.gossip_active end,
            get_gossip_available_quests = function() return W.gossip_available end,
            select_gossip_active_quest = function(id) rec("select_active", id) end,
            select_gossip_available_quest = function(id) rec("select_available", id) end,
            get_active_title = function(i) return W.greeting_active[i] or "" end,
            get_available_title = function(i) return W.greeting_available[i] or "" end,
            select_active_quest = function(i) rec("greet_active", i) end,
            select_available_quest = function(i) rec("greet_available", i) end,
            accept_quest = function() rec("accept") end,
            complete_quest = function() rec("complete") end,
            get_quest_reward = function(i) rec("reward", i) end,
            get_quest_item_link = function(kind, i)
                if kind ~= "choice" or not W.choices[i] then return "" end
                return string.format("|cffffffff|Hitem:%d::::::::12:::::|h[x]|h|r", W.choices[i])
            end,
        },
    }

    local player = {
        get_level = function() return W.level end,
        get_item_at_inventory_slot = function(_, slot)
            local ilvl = W.worn[slot]
            if not ilvl then return { slot_id = slot } end
            local id = 90000 + slot
            W.info[id] = { name = "worn " .. slot, item_level = ilvl, quality = 1 }
            return { object = item(id), slot_id = slot }
        end,
    }

    local P = {
        ctx = {
            -- JCore's inventory, when a test gives the backpack a size.
            inventory = W.backpack and {
                bag_slots = function(bag) return bag == 1 and W.backpack or 0 end,
            } or nil,
            on = function(event, fn) W.handlers[event] = fn end,
            tick = function(fn, tick_opts) W.tick, W.tick_opts = fn, tick_opts end,
            emit = function(event, text)
                if event == "jcore.recorder.trace" then W.traces[#W.traces + 1] = text end
            end,
        },
        log = {
            fmt = function(level, fmt, ...)
                if level == "warn" then W.warned = string.format(fmt, ...) end
            end,
            once = function() end, info = function() end, debug = function() end,
        },
        units = { player = function() return player end },
        opt = function(id, fallback)
            local v = W.settings[id]
            if v == nil then return fallback end
            return v
        end,
        master_on = function() return W.master end,
        rotation = {
            detect_class = function() return W.class end,
            active_class = function() return {} end,
            active_profile_key = function() return W.profile end,
        },
    }

    W.npc = factory(P)
    W.fire = function(event, args)
        local fn = W.handlers["jcore.game_event." .. event]
        assert_true(fn, "no handler for " .. event)
        fn(args or {})
    end
    W.run = function(seconds)
        local steps = math.floor(seconds / 0.05 + 0.5)
        for _ = 1, steps do
            W.clock = W.clock + 0.05
            W.tick()
        end
    end
    return W
end

local GREY_PELT, GREY_CLAW, WHITE_CLOTH, WHITE_JERKY, GREY_WORTHLESS = 4865, 7074, 2589, 117, 999

local function shop_world(opts)
    local W = setup(opts)
    W.info[GREY_PELT] = { name = "Ruined Pelt", quality = 0, sell_price = 5 }
    W.info[GREY_CLAW] = { name = "Chipped Claw", quality = 0, sell_price = 4 }
    W.info[WHITE_CLOTH] = { name = "Linen Cloth", quality = 1, sell_price = 13 }
    W.info[WHITE_JERKY] = { name = "Tough Jerky", quality = 1, sell_price = 1 }
    W.info[GREY_WORTHLESS] = { name = "Broken Tooth", quality = 0, sell_price = 0 }
    W.bags = {
        ["0:1"] = { id = WHITE_CLOTH, n = 4 },
        ["0:2"] = { id = GREY_PELT, n = 3 },
        ["0:3"] = { id = GREY_CLAW, n = 1 },
        ["0:4"] = { id = WHITE_JERKY, n = 5 },
        ["0:5"] = { id = GREY_WORTHLESS, n = 1 },
    }
    return W
end

-- --- selling ------------------------------------------------------------------

T[#T + 1] = { "every grey item with a price goes, nothing else, one at a time", function()
    local W = shop_world()
    assert_eq(W.tick_opts and W.tick_opts.interval, 0.1, "ticks ten times a second")
    W.fire("MERCHANT_SHOW")
    W.run(0.2)
    assert_eq(count_calls(W, "use"), 0, "nothing sold before the first gap")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 2, "two grey items sold")
    assert_eq(W.calls[1][2] .. ":" .. W.calls[1][3], "0:2", "the pelt first")
    assert_eq(W.calls[2][2] .. ":" .. W.calls[2][3], "0:3", "then the claw")
    assert_true(W.bags["0:1"] and W.bags["0:4"] and W.bags["0:5"], "white items and the priceless grey are kept")
    local s = W.npc.stats()
    assert_eq(s.sold, 2, "two sales counted")
    assert_eq(s.copper, 3 * 5 + 4, "copper from the whole stack")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 2, "nothing more to sell")
    W.fire("MERCHANT_CLOSED")
    W.fire("MERCHANT_CLOSED")
    assert_true(has_trace(W, "sold 2 item%(s%) for 19c"), "one summary line at close")
    local summaries = 0
    for i = 1, #W.traces do if W.traces[i]:find("^sell junk: sold") then summaries = summaries + 1 end end
    assert_eq(summaries, 1, "a doubled MERCHANT_CLOSED does not repeat the summary")
end }

T[#T + 1] = { "a sale that took a different item stops selling for the session", function()
    local W = shop_world()
    W.remap["0:2"] = "0:4"          -- the slot pair points one item over
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 1, "stopped after the first sale")
    local s = W.npc.stats()
    assert_true(s.halted and s.halted:find("Tough Jerky left its bag slot instead of Ruined Pelt"), "names what went: "
        .. tostring(s.halted))
    assert_true(W.warned and W.warned:find("Buyback"), "says how to get it back")
    assert_true(has_trace(W, "sell junk STOPPED"), "and leaves it in the trace")
    W.fire("MERCHANT_CLOSED")
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 1, "a new visit still sells nothing")
    assert_true(W.npc.summary():find("STOPPED"), "the overview line says so")
end }

T[#T + 1] = { "sales that change nothing are skipped; three end the visit", function()
    local W = shop_world()
    W.bags["0:6"] = { id = GREY_CLAW, n = 2 }
    W.bags["0:7"] = { id = GREY_PELT, n = 1 }
    W.drop_sales = true
    W.fire("MERCHANT_SHOW")
    W.run(10.0)
    assert_eq(count_calls(W, "use"), 3, "three tries, each slot once")
    assert_true(has_trace(W, "left their item in place"), "said why it stopped")
    assert_eq(W.npc.stats().halted, nil, "not a wrong-item stop")
end }

T[#T + 1] = { "Shift held as the window opens, or the switch off: nothing sold", function()
    local W = shop_world({ shift = true })
    W.fire("MERCHANT_SHOW")
    W.shift = false
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 0, "Shift at open leaves the visit alone")
    W.fire("MERCHANT_CLOSED")
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 2, "the next visit sells")

    local off = shop_world()
    off.settings.npc_sell_junk = false
    off.fire("MERCHANT_SHOW")
    off.run(3.0)
    assert_eq(count_calls(off, "use"), 0, "switch off sells nothing")

    local master = shop_world({ master = false })
    master.fire("MERCHANT_SHOW")
    master.run(3.0)
    assert_eq(count_calls(master, "use"), 0, "master switch off sells nothing")
end }

T[#T + 1] = { "the 2026-10-03 session: sold items stay in the client's array, sales still count", function()
    local W = shop_world()
    W.bags["0:9"] = { id = GREY_CLAW, n = 1 }
    W.fire("MERCHANT_SHOW")
    W.run(4.0)
    W.fire("MERCHANT_CLOSED")
    assert_eq(count_calls(W, "use"), 3, "three grey items pressed")
    assert_eq(W.npc.stats().sold, 3, "and all three counted sold, though the items are still in bag 0's array")
    assert_eq(#W.buyback, 3, "(they are: in the buyback slots)")
    assert_true(has_trace(W, "left client slot 0:37 for client slot 0:100"), "the trace records where a sale lands")
    assert_true(has_trace(W, "client slot 0:37%)"), "and the client slot the helper's pair named")

    W.bags["0:12"] = { id = GREY_PELT, n = 1 }
    W.fire("MERCHANT_SHOW")      -- a second visit: the buyback list shifts with every sale
    W.run(2.0)
    W.fire("MERCHANT_CLOSED")
    assert_eq(W.npc.stats().halted, nil, "an earlier sale moving in the buyback list is not a wrong sale")
    assert_eq(W.npc.stats().sold, 4, "the fourth sells too")
end }

T[#T + 1] = { "the 2026-10-04 session: Buyback rows the helper puts in bag 0 are never sold or watched", function()
    -- After a reload (which forgets what was sold) the helper offered Broken
    -- Boar Tusk from the Buyback list as "bag 0 slot 39" (client slot 0:73);
    -- three such sales changed nothing and selling gave up for the visit.
    local W = shop_world({ helper_buyback = true })
    W.info[3170] = { name = "Broken Boar Tusk", quality = 0, sell_price = 6 }
    W.buyback = {
        { id = 3170, n = 1, guid = "Item-bb-1" },
        { id = GREY_CLAW, n = 2, guid = "Item-bb-2" },
        { id = GREY_PELT, n = 1, guid = "Item-bb-3" },
    }
    W.fire("MERCHANT_SHOW")
    W.run(4.0)
    W.fire("MERCHANT_CLOSED")
    for i = 1, #W.calls do
        local c = W.calls[i]
        if c[1] == "use" then
            assert_true(c[2] ~= 0 or c[3] <= 16, "pressed a slot past the backpack: " .. c[2] .. ":" .. c[3])
        end
    end
    assert_eq(count_calls(W, "use"), 2, "the two greys in the bags, and only them")
    assert_eq(W.npc.stats().sold, 2, "both counted sold")
    assert_eq(W.npc.stats().halted, nil, "the Buyback list shifting under each sale is no wrong sale")
    assert_true(not has_trace(W, "left their item in place"), "no sale went nowhere")
    assert_true(has_trace(W, "past the 16%-slot backpack"), "the rows left alone are traced")
end }

T[#T + 1] = { "the backpack's size comes from JCore when it can say", function()
    local W = shop_world({ helper_buyback = true, backpack = 20 })
    W.bags["0:18"] = { id = GREY_CLAW, n = 1 }
    W.buyback = { { id = GREY_PELT, n = 1, guid = "Item-bb-1" } }
    W.fire("MERCHANT_SHOW")
    W.run(4.0)
    local pressed = {}
    for i = 1, #W.calls do
        local c = W.calls[i]
        if c[1] == "use" then pressed[c[2] .. ":" .. c[3]] = true end
    end
    assert_true(pressed["0:18"], "slot 18 of a 20-slot backpack is in the bags")
    assert_true(not pressed["0:65"], "the Buyback row is not")
    assert_true(has_trace(W, "past the 20%-slot backpack"), "the size used is in the trace")
end }

T[#T + 1] = { "items with no guid are never pressed: a sale could not be checked", function()
    local W = shop_world({ guidless = true })
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 0, "nothing pressed")
    assert_true(has_trace(W, "answered no guid"), "the trace says why")
end }

T[#T + 1] = { "a helper row older than the bags is skipped, not pressed", function()
    local W = shop_world()
    W.bags["0:2"] = nil                                  -- the pelt is gone already
    W.stale["0:2"] = { id = GREY_PELT, n = 3 }           -- but the helper still lists it
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 1, "only the claw is pressed")
    assert_eq(W.calls[1][2] .. ":" .. W.calls[1][3], "0:3", "the claw's slot")
    assert_eq(W.npc.stats().halted, nil, "no false stop")
end }

T[#T + 1] = { "no item data at all: nothing is guessed, and the trace says why", function()
    local W = shop_world()
    W.info = {}
    W.fire("MERCHANT_SHOW")
    W.run(3.0)
    assert_eq(count_calls(W, "use"), 0, "unreadable items are never sold")
    assert_true(has_trace(W, "get_item_info answered nothing"), "trace names the missing read")
end }

-- --- quest windows --------------------------------------------------------------

T[#T + 1] = { "hand in first, then pick up; grey, repeatable and ignored are left", function()
    local W = setup()
    W.gossip_active = {
        { quest_id = 11, title = "Not done", is_complete = false },
        { quest_id = 10, title = "Done", is_complete = true },
    }
    W.gossip_available = {
        { quest_id = 20, title = "Grey", is_trivial = true },
        { quest_id = 21, title = "Again", is_repeatable = true },
        { quest_id = 23, title = "Ignored", is_ignored = true },
        { quest_id = 22, title = "New" },
    }
    W.fire("GOSSIP_SHOW")
    W.run(0.1)
    assert_eq(#W.calls, 0, "not answered in the same instant")
    W.run(0.5)
    assert_eq(#W.calls, 1, "one answer")
    assert_eq(W.calls[1][1] .. " " .. W.calls[1][2], "select_active 10", "the finished quest first")

    W.gossip_active = { { quest_id = 11, title = "Not done", is_complete = false } }
    W.fire("GOSSIP_SHOW")
    W.run(0.5)
    local c = last_call(W, "select_available")
    assert_true(c and c[2] == 22, "then the new quest")

    for _ = 1, 4 do
        W.fire("GOSSIP_SHOW")
        W.run(0.5)
    end
    assert_eq(count_calls(W, "select_available"), 2, "a quest picked twice in a minute is left alone")
    W.clock = W.clock + 61
    W.fire("GOSSIP_SHOW")
    W.run(0.5)
    assert_eq(count_calls(W, "select_available"), 3, "and tried again after a minute")
end }

T[#T + 1] = { "the gossip answer is dropped when the window closes first", function()
    local W = setup()
    W.gossip_available = { { quest_id = 22, title = "New" } }
    W.fire("GOSSIP_SHOW")
    W.fire("GOSSIP_CLOSED")
    W.run(1.0)
    assert_eq(#W.calls, 0, "closed window, no answer")
end }

T[#T + 1] = { "each switch on its own", function()
    local W = setup()
    W.settings.npc_accept_quests = false
    W.gossip_active = { { quest_id = 10, title = "Done", is_complete = true } }
    W.gossip_available = { { quest_id = 22, title = "New" } }
    W.fire("GOSSIP_SHOW")
    W.run(0.5)
    W.gossip_active = {}
    W.fire("GOSSIP_SHOW")
    W.run(0.5)
    W.fire("QUEST_DETAIL", { 0 })
    W.run(0.5)
    assert_eq(count_calls(W, "select_active"), 1, "turn-in alone still hands in")
    assert_eq(count_calls(W, "select_available"), 0, "but takes nothing new")
    assert_eq(count_calls(W, "accept"), 0, "and accepts nothing")

    local V = setup()
    V.settings.npc_turn_in_quests = false
    V.gossip_active = { { quest_id = 10, title = "Done", is_complete = true } }
    V.gossip_available = { { quest_id = 22, title = "New" } }
    V.fire("GOSSIP_SHOW")
    V.run(0.5)
    V.fire("QUEST_PROGRESS")
    V.fire("QUEST_COMPLETE")
    V.run(3.0)
    assert_eq(count_calls(V, "select_active"), 0, "accept alone hands nothing in")
    assert_eq(count_calls(V, "select_available"), 1, "but picks up")
    assert_eq(count_calls(V, "complete") + count_calls(V, "reward"), 0, "and never completes")
end }

T[#T + 1] = { "detail accepted, progress continued, a reward with no choice taken", function()
    local W = setup()
    W.fire("QUEST_DETAIL", { 0 })
    W.run(0.1)
    assert_eq(count_calls(W, "accept"), 0, "not in the same instant")
    W.run(0.5)
    assert_eq(count_calls(W, "accept"), 1, "accepted")
    W.run(1.0)
    assert_eq(count_calls(W, "accept"), 1, "once")

    W.fire("QUEST_PROGRESS")
    W.run(0.5)
    assert_eq(count_calls(W, "complete"), 1, "continued")

    W.fire("QUEST_COMPLETE")
    W.run(0.45)
    assert_eq(count_calls(W, "reward"), 0, "waits a moment for choices to load")
    W.run(0.5)
    assert_eq(count_calls(W, "reward"), 1, "then takes the reward")
    assert_eq(last_call(W, "reward")[2], 0, "with no choice")

    W.choices = { 4001 }
    W.info[4001] = { name = "Only Thing", equip_loc = "INVTYPE_FEET", class_id = 4, subclass_id = 2, item_level = 5 }
    W.fire("QUEST_COMPLETE")
    W.run(0.5)
    assert_eq(last_call(W, "reward")[2], 1, "a single choice is choice 1")
end }

T[#T + 1] = { "Shift held: the window is the player's", function()
    local W = setup({ shift = true })
    W.fire("QUEST_DETAIL", { 0 })
    W.shift = false
    W.run(1.0)
    assert_eq(count_calls(W, "accept"), 0, "not accepted")
    assert_eq(W.npc.stats().by_hand, 1, "counted as by hand")
end }

T[#T + 1] = { "the older multi-quest window: titles only", function()
    local W = setup()
    W.gossip_active = { { quest_id = 10, title = "Done", is_complete = true } }
    W.settings.npc_turn_in_quests = false
    W.fire("GOSSIP_SHOW")         -- learns that "Done" is complete, hands nothing in
    W.run(0.5)
    W.settings.npc_turn_in_quests = true
    W.greeting_active = { "Unknown", "Done" }
    W.greeting_available = { "Fresh" }
    W.fire("QUEST_GREETING")
    W.run(0.5)
    assert_eq(last_call(W, "greet_active")[2], 2, "hands in only the quest known complete")
    W.fire("QUEST_GREETING")
    W.run(0.5)
    W.fire("QUEST_GREETING")
    W.run(0.5)
    assert_eq(count_calls(W, "greet_available"), 1, "then picks up")
end }

-- --- the reward ----------------------------------------------------------------------

local function reward_world(choices, info, opts)
    local W = setup(opts)
    W.choices = choices
    for id, row in pairs(info) do W.info[id] = row end
    W.fire("QUEST_COMPLETE")
    W.run(2.5)
    local c = last_call(W, "reward")
    assert_true(c, "a reward was taken")
    return c[2], W
end

local ROBE = { name = "Cloth Robe", equip_loc = "INVTYPE_ROBE", class_id = 4, subclass_id = 1, item_level = 10,
    quality = 2, sell_price = 50 }
local BOOTS = { name = "Leather Boots", equip_loc = "INVTYPE_FEET", class_id = 4, subclass_id = 2, item_level = 8,
    quality = 2, sell_price = 30 }
local MAUL = { name = "Big Maul", equip_loc = "INVTYPE_2HWEAPON", class_id = 2, subclass_id = 5, item_level = 12,
    quality = 2, sell_price = 80 }

T[#T + 1] = { "a hunter takes the leather that beats what is worn", function()
    local index, W = reward_world({ 1, 2, 3 }, { [1] = ROBE, [2] = BOOTS, [3] = MAUL }, { worn = { [8] = 5 } })
    assert_eq(index, 2, "leather boots over the robe and the maul")
    assert_true(has_trace(W, "took Leather Boots %(leather feet, item level 8 over 5 worn%) for a hunter ranged"),
        "the trace explains the pick")
end }

T[#T + 1] = { "the boots are worse than what is worn: nothing fits, take the money", function()
    local index, W = reward_world({ 1, 2, 3 }, { [1] = ROBE, [2] = BOOTS, [3] = MAUL }, { worn = { [8] = 10 } })
    assert_eq(index, 3, "the maul sells for the most")
    assert_true(has_trace(W, "nothing fits"), "and says so")
end }

T[#T + 1] = { "from level 40 a hunter wears mail", function()
    local chest_leather = { name = "Leather Chest", equip_loc = "INVTYPE_CHEST", class_id = 4, subclass_id = 2,
        item_level = 40, quality = 2, sell_price = 900 }
    local chest_mail = { name = "Mail Chest", equip_loc = "INVTYPE_CHEST", class_id = 4, subclass_id = 3,
        item_level = 38, quality = 2, sell_price = 700 }
    assert_eq(reward_world({ 1, 2 }, { [1] = chest_leather, [2] = chest_mail }, { level = 40 }), 2, "mail at 40")
    assert_eq(reward_world({ 1, 2 }, { [1] = chest_leather, [2] = chest_mail }, { level = 39 }), 1, "leather at 39")
end }

T[#T + 1] = { "the role picks between weapons", function()
    local bow = { name = "Bow", equip_loc = "INVTYPE_RANGEDRIGHT", class_id = 2, subclass_id = 2, item_level = 10,
        quality = 2, sell_price = 40 }
    local polearm = { name = "Polearm", equip_loc = "INVTYPE_2HWEAPON", class_id = 2, subclass_id = 6,
        item_level = 10, quality = 2, sell_price = 60 }
    assert_eq(reward_world({ 1, 2 }, { [1] = polearm, [2] = bow }), 2, "a hunter takes the bow")

    local shield = { name = "Shield", equip_loc = "INVTYPE_SHIELD", class_id = 4, subclass_id = 6, item_level = 25,
        quality = 2, sell_price = 300 }
    local sword2 = { name = "Greatsword", equip_loc = "INVTYPE_2HWEAPON", class_id = 2, subclass_id = 8,
        item_level = 25, quality = 2, sell_price = 400 }
    assert_eq(reward_world({ 1, 2 }, { [1] = sword2, [2] = shield },
        { class = "WARRIOR", profile = "tank_prot", level = 30 }), 2, "a tank takes the shield")
    assert_eq(reward_world({ 1, 2 }, { [1] = shield, [2] = sword2 },
        { class = "WARRIOR", profile = "dps_arms", level = 30 }), 2, "an arms warrior the greatsword")

    local staff = { name = "Staff", equip_loc = "INVTYPE_2HWEAPON", class_id = 2, subclass_id = 10, item_level = 20,
        quality = 2, sell_price = 100 }
    local dagger = { name = "Dagger", equip_loc = "INVTYPE_WEAPON", class_id = 2, subclass_id = 15, item_level = 20,
        quality = 2, sell_price = 150 }
    assert_eq(reward_world({ 1, 2 }, { [1] = dagger, [2] = staff },
        { class = "MAGE", profile = "frost", level = 20 }), 2, "a mage takes the staff")
    assert_eq(reward_world({ 1, 2 }, { [1] = staff, [2] = dagger },
        { class = "ROGUE", profile = "combat", level = 20 }), 2, "a rogue cannot use the staff")
end }

T[#T + 1] = { "a mage offered plate and a potion takes the money", function()
    local plate = { name = "Plate", equip_loc = "INVTYPE_HAND", class_id = 4, subclass_id = 4, item_level = 30,
        quality = 2, sell_price = 200 }
    local potion = { name = "Potion", equip_loc = "", class_id = 0, subclass_id = 1, item_level = 30,
        quality = 1, sell_price = 250 }
    assert_eq(reward_world({ 1, 2 }, { [1] = plate, [2] = potion }, { class = "MAGE", profile = "fire", level = 30 }),
        2, "plate does not fit a mage; the potion sells for more")
end }

T[#T + 1] = { "armour heavier than the class wears yet is never taken", function()
    local leather = { name = "Leather Belt", equip_loc = "INVTYPE_WAIST", class_id = 4, subclass_id = 2,
        item_level = 20, quality = 2, sell_price = 100 }
    local mail = { name = "Mail Belt", equip_loc = "INVTYPE_WAIST", class_id = 4, subclass_id = 3,
        item_level = 25, quality = 3, sell_price = 300 }
    assert_eq(reward_world({ 1, 2 }, { [1] = mail, [2] = leather }, { level = 20 }), 2,
        "a level-20 hunter cannot wear mail")
end }

T[#T + 1] = { "profession books for a hunter: nothing fits, nothing sells, the first is taken", function()
    local book = function(name) return { name = name, equip_loc = "INVTYPE_NON_EQUIP_IGNORE", class_id = 0,
        subclass_id = 0, item_level = 1, quality = 1, sell_price = 0 } end
    local index, W = reward_world({ 1, 2, 3 }, { [1] = book("Mining for Dummies"), [2] = book("Herbalism"),
        [3] = book("Skinning") })
    assert_eq(index, 1, "the first")
    assert_true(has_trace(W, "none sells, so the first"), "said plainly")
end }

T[#T + 1] = { "rings: the weaker worn ring is what a new one replaces", function()
    local ring = { name = "Ring", equip_loc = "INVTYPE_FINGER", class_id = 4, subclass_id = 0, item_level = 15,
        quality = 2, sell_price = 100 }
    local index = reward_world({ 1, 2 }, { [1] = BOOTS, [2] = ring }, { worn = { [8] = 9, [11] = 20, [12] = 10 } })
    assert_eq(index, 2, "the ring beats the weaker worn ring; the boots are a downgrade")
end }

T[#T + 1] = { "a choice whose data never comes is waited for, then decided without", function()
    local W = setup({ worn = { [8] = 5 } })
    W.choices = { 1, 2 }
    W.info[2] = BOOTS
    W.fire("QUEST_COMPLETE")
    W.run(1.5)
    assert_eq(count_calls(W, "reward"), 0, "waits for the missing item data")
    W.run(1.0)
    assert_eq(last_call(W, "reward")[2], 2, "then takes the boots")
    assert_true(has_trace(W, "without item data"), "and says one choice had none")
end }

T[#T + 1] = { "the role table", function()
    local role = setup().npc.role_of
    assert_eq(role("WARRIOR", "tank_prot"), "tank", "warrior tank")
    assert_eq(role("PALADIN", "holy"), "healer", "paladin holy")
    assert_eq(role("DRUID", "feral_bear"), "tank", "bear")
    assert_eq(role("DRUID", "balance"), "caster", "moonkin")
    assert_eq(role("SHAMAN", "enhancement"), "melee", "enhancement")
    assert_eq(role("PRIEST", "shadow"), "caster", "shadow")
    assert_eq(role("HUNTER", "survival"), "ranged", "hunter")
end }

return T

-- Jambix AIO, the WHOLE plugin on the whole of JCore as the Forever client:
-- the vendor and the quest givers (modules/forever_npc.lua, 1.51.0).
--
-- Pinned here: the module is built on Forever, after the rotation; the
-- Automation page carries its "Vendor and quests" section with the three
-- switches, off until switched on; with them on, the game's own events
-- (forwarded by JCore, everything wrapped by the API recorder) sell the
-- grey item, accept the quest on offer and take a reward, and the overview
-- line reports it. aio_boot_era_npc_test.lua pins that Era gets none of it.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local GREY, WHITE = 4865, 2589
local W = { bags = { ["0:1"] = WHITE, ["0:2"] = GREY }, calls = {} }

local function item(id)
    return { get_item_id = function() return id end, get_item_stack_count = function() return 1 end,
        get_guid = function() return "Item-" .. id end }
end

local function count(name)
    local n = 0
    for i = 1, #W.calls do if W.calls[i][1] == name then n = n + 1 end end
    return n
end

local b
local T = {}

T[#T + 1] = { "Forever: the whole plugin boots clean with the vendor and quest module", function()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        local function rec(name) return function(...) W.calls[#W.calls + 1] = { name, ... } end end
        package.loaded["common/utility/inventory_helper"] = {
            get_current_consumables_list = function() return {} end,
            get_character_bag_slots = function()
                local out = {}
                for key, id in pairs(W.bags) do
                    local bag, slot = key:match("^(%d+):(%d+)$")
                    out[#out + 1] = { item = item(id), bag_id = tonumber(bag), bag_slot = tonumber(slot),
                        stack_count = 1 }
                end
                return out
            end,
        }
        core.inventory.get_items_in_bag = function(bag)
            if bag ~= 0 then return {} end
            local out = {}
            for _, id in pairs(W.bags) do out[#out + 1] = { object = item(id), slot_id = 40 } end
            return out
        end
        core.input.use_container_item = function(bag, slot)
            W.calls[#W.calls + 1] = { "use", bag, slot }
            W.bags[bag .. ":" .. slot] = nil
            return true
        end
        local info = {
            [GREY] = { name = "Ruined Pelt", quality = 0, sell_price = 5 },
            [WHITE] = { name = "Linen Cloth", quality = 1, sell_price = 13 },
            [7001] = { name = "Gloves", equip_loc = "INVTYPE_HAND", class_id = 4, subclass_id = 1,
                item_level = 5, sell_price = 10 },
            [7002] = { name = "Ring", equip_loc = "INVTYPE_FINGER", class_id = 4, subclass_id = 0,
                item_level = 5, sell_price = 40 },
        }
        core.quests.get_item_info = function(key)
            local id = type(key) == "number" and key or tonumber(tostring(key):match("item:(%d+)"))
            return (id and info[id]) or {}
        end
        core.quests.get_quest_item_link = function(kind, i)
            local ids = { 7001, 7002 }
            if kind == "choice" and ids[i] then return "|Hitem:" .. ids[i] .. "::|h[x]|h" end
            return ""
        end
        core.quests.get_gossip_active_quests = function() return {} end
        core.quests.get_gossip_available_quests = function() return {} end
        core.quests.accept_quest = rec("accept")
        core.quests.complete_quest = rec("complete")
        core.quests.get_quest_reward = rec("reward")
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, true, "Forever")
    assert(b.P.forever_npc, "the vendor and quest module is built")
end }

T[#T + 1] = { "Forever: auto-loot and gathering read the Forever ESP's lists (1.54.0)", function()
    local esp = b.P.esp
    assert(esp.forever, "the Forever ESP is loaded")
    assert_eq(esp.corpses, esp.forever.corpses, "corpses from the Forever ESP, not the idle classic collector")
    assert_eq(esp.nodes, esp.forever.nodes, "nodes too")
    assert_eq(type(esp.corpses()), "table", "a list")
end }

T[#T + 1] = { "Forever: the Automation page carries the section, switches off", function()
    local page = b.mock.menu.pages["Jambix AIO/Automation"]
    assert(page, "an Automation page")
    local found = false
    for i = 1, #page.sections do
        if page.sections[i].title == "Vendor and quests" then found = true end
    end
    assert(found, "a Vendor and quests section")
    for _, id in ipairs({ "npc_sell_junk", "npc_accept_quests", "npc_turn_in_quests" }) do
        assert_eq(b.P.opt(id, "undeclared"), false, id .. " declared, off")
    end
end }

T[#T + 1] = { "Forever: switched off, a merchant and a quest window are left alone", function()
    b.mock.game_event("MERCHANT_SHOW", {})
    b.mock.game_event("QUEST_DETAIL", { 0 })
    b.mock.frame(120)
    b.mock.game_event("MERCHANT_CLOSED", {})
    assert_eq(#W.calls, 0, "nothing done")
end }

T[#T + 1] = { "Forever: switched on, the grey item is sold, the quest taken, a reward chosen", function()
    for _, id in ipairs({ "npc_sell_junk", "npc_accept_quests", "npc_turn_in_quests" }) do
        b.mock.menu:set("Jambix AIO/Automation", id, true)
    end
    b.P.opt_invalidate()

    b.mock.game_event("MERCHANT_SHOW", {})
    b.mock.frame(120)
    b.mock.game_event("MERCHANT_CLOSED", {})
    assert_eq(count("use"), 1, "one sale")
    assert_eq(W.calls[1][2] .. ":" .. W.calls[1][3], "0:2", "the grey item's slot")
    assert(W.bags["0:1"], "the white item is kept")

    b.mock.game_event("QUEST_DETAIL", { 0 })
    b.mock.frame(60)
    assert_eq(count("accept"), 1, "accepted")

    b.mock.game_event("QUEST_COMPLETE", {})
    b.mock.frame(180)
    assert_eq(count("reward"), 1, "a reward taken")
    local s = b.P.forever_npc.stats()
    assert_eq(s.sold, 1, "one sale counted")
    assert(s.last_reward, "the reward choice is explained")
    assert(b.P.forever_npc.summary():find("sold 1", 1, true), "the overview line")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

return T

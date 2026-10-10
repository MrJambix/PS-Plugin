-- Jambix AIO, the WHOLE plugin on the whole of JCore as the Vanilla client
-- (Era): the vendor and quest automation is Forever's alone (1.51.0).
--
-- Pinned here: on Era modules/forever_npc.lua is never built, the Automation
-- page has no "Vendor and quests" section and no such switches, and a
-- merchant or quest window is left alone even with a grey item in the bags
-- and the switches' values saved. Forever's half is aio_boot_forever_npc_test.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local calls = {}
local b
local T = {}

T[#T + 1] = { "Era: the whole plugin boots clean without the vendor and quest module", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" }, function()
        local grey = { get_item_id = function() return 4865 end, get_item_stack_count = function() return 1 end }
        package.loaded["common/utility/inventory_helper"] = {
            get_current_consumables_list = function() return {} end,
            get_character_bag_slots = function()
                return { { item = grey, bag_id = 0, bag_slot = 1, stack_count = 1 } }
            end,
        }
        core.inventory.get_items_in_bag = function(bag)
            if bag ~= 0 then return {} end
            return { { object = grey, slot_id = 24 } }
        end
        core.input.use_container_item = function(...) calls[#calls + 1] = { "use", ... } end
        core.quests.get_item_info = function() return { name = "Ruined Pelt", quality = 0, sell_price = 5 } end
        core.quests.accept_quest = function() calls[#calls + 1] = { "accept" } end
        core.quests.get_quest_reward = function() calls[#calls + 1] = { "reward" } end
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, false, "not Forever")
    assert_eq(b.P.forever_npc, nil, "no vendor and quest module")
end }

T[#T + 1] = { "Era: auto-loot and gathering still read the classic collector's lists", function()
    local esp = b.P.esp
    assert_eq(esp.forever, nil, "no Forever ESP")
    assert_eq(esp.corpses, b.P.esp_collect.corpses, "corpses from the classic collector")
    assert_eq(esp.nodes, b.P.esp_collect.nodes, "nodes too")
end }

T[#T + 1] = { "Era: no section, no switches", function()
    local page = b.mock.menu.pages["Jambix AIO/Automation"]
    assert(page, "an Automation page")
    for i = 1, #page.sections do
        assert(page.sections[i].title ~= "Vendor and quests", "no Vendor and quests section on Era")
    end
    for _, id in ipairs({ "npc_sell_junk", "npc_accept_quests", "npc_turn_in_quests" }) do
        assert_eq(b.P.opt(id, "undeclared"), "undeclared", id .. " not declared")
    end
end }

T[#T + 1] = { "Era: a merchant and quest windows are left alone", function()
    b.mock.game_event("MERCHANT_SHOW", {})
    b.mock.game_event("QUEST_DETAIL", { 0 })
    b.mock.game_event("QUEST_COMPLETE", {})
    b.mock.frame(180)
    b.mock.game_event("MERCHANT_CLOSED", {})
    assert_eq(#calls, 0, "nothing sold, accepted or turned in")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

return T

-- JCore booted as the Forever client (Classic+, the retail engine), with a
-- Classic Era client installed beside it under the same root. Forever's
-- product code is deliberately one no table in the code knows ("wow_camelot",
-- its internal codename), so the client folder and the CASC build can only
-- be found the way the install itself describes them.
--
-- Era with the same two clients installed is jcore_era_client_test.lua.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
-- The loader's spell_helper, as a stub that says no to everything (1.5.10):
-- on Forever JCore must not ask it, on Era it still decides.
package.loaded["common/utility/spell_helper"] = {
    asked = 0,
    is_spell_castable = function(self) self.asked = self.asked + 1 return false end,
}
-- The loader's inventory_helper, as a stub a test sets the rows of (1.8.2,
-- 1.8.4): on Forever the free bag slots are counted from its rows.
local bag_helper = { rows = nil }
function bag_helper.get_character_bag_slots(self) return self.rows end
package.loaded["common/utility/inventory_helper"] = bag_helper
-- The loader's icons_helper (1.8.3): it reads www.wowhead.com, which refuses
-- it 403 with an [ERR] line per spell, so JCore must never ask it.
local icon_helper = { asked = 0, drew = 0 }
function icon_helper.get_spell_icon_name(self) self.asked = self.asked + 1 return nil end
function icon_helper.draw_spell_icon(self) self.drew = self.drew + 1 return false end
package.loaded["common/utility/icons_helper"] = icon_helper
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

local fixture = require("casc_fixture")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

-- Both clients have been launched, so both have a config file; Era comes
-- first in every fixed probe order, which is the trap.
mock.wow_fs["_classic_era_/WTF/Config.wtf"] = "x"
mock.wow_fs["_classic_era_/.flavor.info"] = "Product Flavor!STRING:0\r\nwow_classic_era\r\n"
mock.wow_fs["_camelot_/WTF/Config.wtf"] = "x"
mock.wow_fs["_camelot_/.flavor.info"] = "Product Flavor!STRING:0\nwow_camelot\n"

local JCore, ctx

local T = {}

T[#T + 1] = { "boot as Forever", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    JCore = _G.JCore
    assert(JCore, "_G.JCore missing")
    mock.frame(5)
    fail_on_errors("boot")
    ctx = JCore.register({ id = "jtest.forever", name = "Forever test", version = "1.0.0" })
    assert(ctx, "plugin registered")
end }

T[#T + 1] = { "world.client() describes what Forever can and cannot do", function()
    local c = JCore.world.client()
    assert_eq(c.version, "Forever", "version")
    assert_eq(c.exact, "wow_forever_us", "exact")
    assert_eq(c.forever, true, "forever")
    assert_eq(c.trait_talents, true, "trait talents")
    assert_eq(c.classic_quest_log, false, "no classic quest log")
    assert_eq(c.completed_quest_list, false, "no completed quest list")
    assert_eq(c.cancel_buff, false, "cancel_buff does nothing there")
    assert_eq(c.core_20261006, false, "an older core (jcore_forever_core_test is the 2026-10-06 one)")
    assert_eq(c.quest_ids, false, "no quest-ID readers")
    assert_eq(JCore.world.is_forever(), true, "is_forever")
    assert(JCore.world.client() == c, "read once and held")
end }

T[#T + 1] = { "cancel_buff says false instead of silently doing nothing", function()
    local reached = 0
    rawset(mock.core.input, "cancel_buff", function() reached = reached + 1 end)
    local result = ctx.input.cancel_buff({ impl = 1, buff_index = 1 })
    assert_eq(result, false, "answer")
    assert_eq(reached, 0, "the native is not called")
    fail_on_errors("cancel_buff")
end }

T[#T + 1] = { "the client folder is the running product's, found from the install", function()
    -- Neither folder name is guessed: _camelot_ comes from the .build.info
    -- row (wow_camelot -> _camelot_), and the version picks it over Era.
    local fx = fixture.build_store(JCore.casc, mock.wow_fs)
    mock.wow_fs[".build.info"] = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Version!STRING:0|Product!STRING:0\n"
        .. "us|1|" .. string.rep("e", 32) .. "|" .. string.rep("b", 32) .. "|1.15.9.70003|wow_classic_era\n"
        .. "us|1|" .. fixture.BUILD_KEY .. "|" .. string.rep("c", 32) .. "|1.60.1.70100|wow_camelot\n"
    assert(fx, "fixture built")

    JCore.assets.set_flavor("")      -- drop any earlier answer
    assert_eq(JCore.assets.flavor(), "_camelot_", "folder")
    assert_eq(JCore.assets.product(), "wow_camelot", "product from .flavor.info")
    assert_eq(JCore.assets.wow_path("Interface/AddOns/Questie/Questie.toc"),
        "_camelot_/Interface/AddOns/Questie/Questie.toc", "addon paths follow it")
    fail_on_errors("flavor")
end }

T[#T + 1] = { "CASC opens the running product's build, not the first active row", function()
    local ok, why = JCore.casc.available()
    assert(ok, "store readable: " .. tostring(why))
    assert_eq(JCore.casc.build().product, "wow_camelot", "product")
    assert_eq(JCore.casc.build().key, fixture.BUILD_KEY, "build key")
    fail_on_errors("casc")
end }

T[#T + 1] = { "a folder Battle.net names in .product.db is found without a .build.info row", function()
    -- A layout the rule cannot derive: the product says one thing, the
    -- folder another. Only the install record names it.
    mock.wow_fs[".build.info"] = nil
    mock.wow_fs["_camelot_/WTF/Config.wtf"] = nil
    mock.wow_fs["_classic_plus_/WTF/Config.wtf"] = "x"
    mock.wow_fs["_classic_plus_/.flavor.info"] = "Product Flavor!STRING:0\nwow_camelot\n"
    mock.wow_fs[".product.db"] = "\n\vwow_camelot\18\vwow_camelot\26\20\106\15_classic_plus_\"\0"

    JCore.assets.set_flavor("")
    assert_eq(JCore.assets.flavor(), "_classic_plus_", "folder")
    assert_eq(JCore.assets.product(), "wow_camelot", "product")
end }

T[#T + 1] = { "a backpack size no backpack can have is replaced on Forever; the bags are not", function()
    local answers = { [1] = 0, [2] = 14 }
    rawset(mock.core.inventory, "get_num_bag_slots", function(bag_id) return answers[bag_id] or 0 end)
    mock.game_event("BAG_UPDATE", { 0 })    -- drop anything cached
    assert_eq(JCore.inventory.bag_slots(1), 16, "backpack read 0 -> 16")
    assert_eq(JCore.inventory.bag_slots(2), 14, "a bag passes through")
    answers[1] = 20
    mock.game_event("BAG_UPDATE", { 0 })
    assert_eq(JCore.inventory.bag_slots(1), 20, "a plausible backpack passes through")
    fail_on_errors("bags")
end }

T[#T + 1] = { "bags on Forever (1.8.2, 1.8.4): no bag events there, so answers expire; free slots are the helper rows inside the bags", function()
    local traces = {}
    ctx.on("jcore.recorder.trace", function(text) traces[#traces + 1] = text end)
    -- Bag 0 answers the whole item array: 30 rows against 20 + 14 slots.
    local rows = {}
    for i = 1, 30 do rows[i] = { slot_id = i } end
    rawset(mock.core.inventory, "get_items_in_bag", function(bag) return bag == 0 and rows or {} end)
    -- The helper: 15 in the 20-slot backpack, 14 in the 14-slot bag, and the
    -- merchant's Buyback as bag 0 slots past the backpack (39, 40).
    local helper_rows = {}
    local function add(bag, slot) helper_rows[#helper_rows + 1] = { bag_id = bag, bag_slot = slot, item = {} } end
    for s = 1, 15 do add(0, s) end
    for s = 1, 14 do add(1, s) end
    add(0, 39)
    add(0, 40)
    bag_helper.rows = helper_rows
    mock.game_event("BAG_UPDATE", { 0 })    -- start clean (Forever never sends it)

    assert_eq(JCore.inventory.free_slots(), 5, "34 slots - 29 rows in the bags, Buyback left out")
    assert_eq(JCore.inventory.is_full(), false, "not full")
    local inside, outside, cap = JCore.inventory.bag_rows()
    assert_eq(#inside, 29, "bag_rows: the rows in the bags")
    assert_eq(outside, 2, "bag_rows: the two past the backpack")
    assert_eq(cap, 34, "bag_rows: capacity")
    for s = 16, 20 do add(0, s) end
    assert_eq(JCore.inventory.free_slots(), 5, "held within the second")
    mock.time = mock.time + 1.1
    assert_eq(JCore.inventory.free_slots(), 0, "read again a second later, with no bag event")
    assert_eq(JCore.inventory.is_full(), true, "full")
    assert_eq(traces[1], "inventory: 5 of 34 bag slots free (inventory_helper; 2 row(s) past the bags left out)", "traced")
    assert_eq(traces[2], "inventory: 0 of 34 bag slots free (inventory_helper; 2 row(s) past the bags left out)", "and each change")
    assert_eq(#traces, 2, "and only a change")

    -- A sale: the item leaves its slot and turns up in the Buyback list. A
    -- slot is free, whatever the list says.
    table.remove(helper_rows, 1)
    add(0, 41)
    mock.time = mock.time + 1.1
    assert_eq(JCore.inventory.free_slots(), 1, "the sold item frees its slot")

    -- The item walk expires the same way.
    local before = #JCore.inventory.items()
    rows[31] = { slot_id = 31 }
    assert_eq(#JCore.inventory.items(), before, "held within the second")
    mock.time = mock.time + 1.1
    assert_eq(#JCore.inventory.items(), before + 1, "a new item is seen without a bag event")

    -- No rows from the helper: the row count, as before.
    bag_helper.rows = nil
    mock.time = mock.time + 1.1
    assert_eq(JCore.inventory.free_slots(), 3, "fallback: 20 + 14 slots - 31 rows")
    fail_on_errors("forever bags")
end }

T[#T + 1] = { "the override on the UI page still wins", function()
    JCore.assets.set_flavor("_classic_era_")
    assert_eq(JCore.assets.flavor(), "_classic_era_", "folder")
    assert_eq(JCore.assets.product(), "wow_classic_era", "product read from the overridden folder")
    JCore.assets.set_flavor("")
    mock.frame(3)
    fail_on_errors("after")
end }

T[#T + 1] = { "the global cooldown is read off a spell with no cooldown of its own (the native answers 0)", function()
    local base = { [1752] = { cooldown_ms = 0, gcd_ms = 1000 }, [1784] = { cooldown_ms = 10000, gcd_ms = 0 } }
    local cds = { [1752] = 0.816, [1784] = 7 }
    rawset(mock.core.spell_book, "get_global_cooldown", function() return 0 end)
    rawset(mock.core.spell_book, "get_spell_base_cooldown", function(id) return base[id] end)
    rawset(mock.core.spell_book, "is_spell_known", function(id) return base[id] ~= nil end)
    rawset(mock.core.spell_book, "get_spell_cooldown", function(id) return cds[id] or 0 end)
    mock.frame(1)
    assert_eq(ctx.spells.gcd(), 0, "nothing asked about yet: no probe, no guess")
    ctx.spells.cooldown(1784)
    ctx.spells.cooldown(1752)
    mock.frame(1)
    assert_eq(ctx.spells.gcd(), 0.816, "read off Sinister Strike -- not Stealth's own ten seconds")
    assert_eq(ctx.spells.gcd_probe(), 1752, "the probe")
    assert_eq(ctx.player.gcd(), 0.816, "the player service reads the same")
    cds[1752] = 0
    mock.frame(1)
    assert_eq(ctx.spells.gcd(), 0, "and free when it is")
    fail_on_errors("gcd")
end }

T[#T + 1] = { "a channel id no spell can have is unknown, not a spell", function()
    local me = setmetatable({}, { __index = function(_, key)
        local answers = { is_valid = true, is_dead = false, get_guid = "Player-1-0001",
                          is_channelling_spell = true, is_casting_spell = false,
                          get_active_channel_spell_id = 3739147998 }
        if key == "get_position" then return function() return { x = 1, y = 2, z = 3 } end end
        local v = answers[key]
        return function() return v end
    end })
    rawset(mock.core.object_manager, "get_local_player", function() return me end)
    mock.frame(2)
    assert_eq(ctx.player.casting_spell_id(), nil, "3,739,147,998: unknown")
    fail_on_errors("channel id")
end }

-- trace_line as Forever answers it: true is a hit. A ray down through the
-- player's feet hits the ground, one straight up hits nothing (the
-- calibration), and a ray between two units hits while `state.blocked`.
-- The client's is_line_of_sight must never be asked on Forever: on build
-- 70338 it asserts in M2HitTest.cpp (the four crashes of 2026-10-11).
local function forever_rays(state)
    state.rays, state.calls = state.rays or 0, state.calls or 0
    rawset(mock.core.graphics, "is_line_of_sight", function()
        state.native = (state.native or 0) + 1
        return true
    end)
    rawset(mock.core.graphics, "trace_line", function(a, b, mask)
        state.calls = state.calls + 1
        state.mask = mask
        if b.z < a.z - 1 then return true end
        if b.z > a.z and a.x == b.x and a.y == b.y then return false end
        state.rays = state.rays + 1
        return state.blocked == true
    end)
    ctx.geometry._reset_sight()
    ctx.geometry.set_forever_rays(true)     -- off by default since 1.8.1
end

T[#T + 1] = { "a melee spell is castable on Forever: the loader's helper is not asked; reach, sight and usability are", function()
    local me_pos, mob_pos = { x = 0, y = 0, z = 0 }, { x = 3, y = 0, z = 0 }
    local state = {}
    local function unit_of(answers, pos)
        return setmetatable({}, { __index = function(_, key)
            if key == "get_position" then return function() return pos end end
            local v = answers[key]
            return function() return v end
        end })
    end
    local me = unit_of({ is_valid = true, is_dead = false, get_guid = "Player-1-0002", get_combat_reach = 1.5,
                         is_channelling_spell = false, is_casting_spell = false }, me_pos)
    local mob = unit_of({ is_valid = true, is_dead = false, get_guid = "Creature-0-1-0-0-251160-0000406265",
                          get_combat_reach = 1.5 }, mob_pos)
    rawset(mock.core.object_manager, "get_local_player", function() return me end)
    rawset(mock.core.spell_book, "is_spell_known", function() return true end)
    rawset(mock.core.spell_book, "is_usable_spell", function(id) return id ~= 9999 end)
    rawset(mock.core.spell_book, "get_spell_cooldown", function() return 0 end)
    rawset(mock.core.spell_book, "get_spell_max_range", function() return 0 end)
    rawset(mock.core.spell_book, "get_spell_min_range", function() return 0 end)
    rawset(mock.core.spell_book, "is_melee_spell", function(id) return id == 1757 end)
    forever_rays(state)
    mock.frame(2)
    assert_eq(ctx.spells.castable(1757, mob, { skip_facing = true }), true,
        "Sinister Strike at 3 yards: castable (the helper, which says no to everything, was not asked)")
    mob_pos.x = 9
    mock.frame(1)
    assert_eq(ctx.spells.castable(1757, mob, { skip_facing = true }), false, "at 9 yards: out of reach")
    mob_pos.x = 3
    state.blocked = true
    mock.frame(15)                      -- past geometry's fifth of a second
    assert_eq(ctx.spells.castable(1757, mob, { skip_facing = true }), false, "no line of sight")
    state.blocked = false
    mock.frame(15)
    assert_eq(ctx.spells.castable(9999, mob, { skip_facing = true }), false, "not usable: not castable")
    mob_pos.x = 25
    mock.frame(1)
    assert_eq(ctx.spells.castable(2764, mob, { skip_facing = true }), true,
        "a range the client does not give: left to the client")
    fail_on_errors("castable")
end }

T[#T + 1] = { "castable on Forever: one line-of-sight ray per target per tick, whatever spells are asked (1.8.0)", function()
    -- The crashes in Forlorn Rowe (2026-10-11) were the client's own assert
    -- inside one of these rays: every spell of a priority list cast its own.
    local mob_pos = { x = 3, y = 0, z = 0 }
    local state = {}
    local function unit_of(answers, pos)
        return setmetatable({}, { __index = function(_, key)
            if key == "get_position" then return function() return pos end end
            local v = answers[key]
            return function() return v end
        end })
    end
    local me = unit_of({ is_valid = true, is_dead = false, get_guid = "Player-1-0002", get_combat_reach = 1.5,
                         is_channelling_spell = false, is_casting_spell = false }, { x = 0, y = 0, z = 0 })
    local mob = unit_of({ is_valid = true, is_dead = false, get_guid = "Creature-0-1-0-0-251160-0000406266",
                          get_combat_reach = 1.5 }, mob_pos)
    local other = unit_of({ is_valid = true, is_dead = false, get_guid = "Creature-0-1-0-0-251160-0000406267",
                            get_combat_reach = 1.5 }, mob_pos)
    rawset(mock.core.object_manager, "get_local_player", function() return me end)
    rawset(mock.core.spell_book, "is_spell_known", function() return true end)
    rawset(mock.core.spell_book, "is_usable_spell", function() return true end)
    rawset(mock.core.spell_book, "get_spell_cooldown", function() return 0 end)
    rawset(mock.core.spell_book, "get_spell_max_range", function() return 0 end)
    rawset(mock.core.spell_book, "get_spell_min_range", function() return 0 end)
    forever_rays(state)
    mock.frame(1)
    for _, id in ipairs({ 1757, 2764, 1752, 2098, 53 }) do
        assert_eq(ctx.spells.castable(id, mob, { skip_facing = true }), true, "spell " .. id .. " in sight")
    end
    assert_eq(state.rays, 1, "five spells on one mob in one tick: one ray")
    ctx.spells.castable(1757, other, { skip_facing = true })
    assert_eq(state.rays, 2, "another mob: its own ray")
    state.blocked = true
    assert_eq(ctx.spells.castable(1757, mob, { skip_facing = true }), true, "the same tick keeps the answer")
    -- geometry keeps a pair's answer a fifth of a second (the ESP's target
    -- row asks every frame); past that the next tick asks again.
    mock.frame(15)
    assert_eq(ctx.spells.castable(1757, mob, { skip_facing = true }), false, "the next tick asks again: no sight")
    assert_eq(ctx.spells.castable(2764, mob, { skip_facing = true }), false, "and every spell hears it")
    assert_eq(state.rays, 3, "one more ray for the new tick")
    assert_eq(state.native, nil, "the client's is_line_of_sight was never asked")
    -- Buildings and terrain, a building's doodads ignored: no model bit.
    assert_eq(state.mask & 0x1, 0, "no doodad collision in the mask")
    assert_eq(state.mask & 0x100000, 0, "no entity collision in the mask")
    assert(state.mask & 0x10 ~= 0 and state.mask & 0x100 ~= 0, "buildings and terrain")
    assert_eq(ctx.geometry.sight_stats().hit_value, true, "calibrated: true is a hit")
    assert_eq(ctx.spells.in_line_of_sight(1757, mob), false, "in_line_of_sight asks the same ray")
    assert_eq(state.native, nil, "and never the native either")
    fail_on_errors("castable sight")
end }

T[#T + 1] = { "a mark's fade behind a wall asks for sight twice a second, not every frame (1.8.0)", function()
    local function unit_of(answers)
        return setmetatable({}, { __index = function(_, key)
            if key == "get_position" then return function() return { x = 10, y = 0, z = 0 } end end
            local v = answers[key]
            return function() return v end
        end })
    end
    local me = unit_of({ is_valid = true, is_dead = false, get_guid = "Player-1-0002" })
    local mob = unit_of({ is_valid = true, is_dead = false, get_guid = "Creature-0-1-0-0-251160-0000406268" })
    rawset(mock.core.object_manager, "get_local_player", function() return me end)
    local state = {}
    forever_rays(state)
    local draw = JCore.draw
    draw.set_los_budget(8)
    mock.frame(1)
    assert_eq(draw.unit_los(mob), true, "in sight")
    assert_eq(state.rays, 1, "one ray")
    state.blocked = true
    mock.frame(10)                      -- a sixth of a second
    assert_eq(draw.unit_los(mob), true, "still the answer from a moment ago")
    assert_eq(state.rays, 1, "no ray for ten frames")
    mock.frame(30)                      -- past half a second
    assert_eq(draw.unit_los(mob), false, "asked again: behind a wall")
    assert_eq(state.rays, 2, "one more ray")
    assert_eq(state.native, nil, "the fade never asks the client's is_line_of_sight (1.8.0)")
    -- No answer from the ray: the mark is painted, never the native asked.
    rawset(mock.core.graphics, "trace_line", function() return nil end)
    mock.frame(40)
    assert_eq(draw.unit_los(mob), true, "unknown: painted as visible")
    assert_eq(state.native, nil, "still not the native")
    draw.set_los_budget(0)
    assert_eq(draw.unit_los(mob), true, "a budget of 0 still switches the check off")
    draw.set_los_budget(12)
    fail_on_errors("unit_los")
end }

T[#T + 1] = { "in a party, roles and members come from the party rows (get_group_role answers -1 here)", function()
    local function member(guid)
        return setmetatable({}, { __index = function(_, key)
            if key == "get_position" then return function() return { x = 5, y = 0, z = 0 } end end
            local answers = { is_valid = true, is_dead = false, get_guid = guid, get_group_role = -1 }
            local v = answers[key]
            return function() return v end
        end })
    end
    local tank, healer = member("Player-1-0010"), member("Player-1-0011")
    rawset(mock.core.object_manager, "get_party_members", function()
        return { { name = "Tanky", role = "TANK", object = tank, index = 1 },
                 { name = "Heals", role = "HEALER", object = healer, index = 2 } }
    end)
    mock.frame(1)
    local found = 0
    for _, o in ipairs(ctx.group.objects()) do
        if o == tank or o == healer then found = found + 1 end
    end
    assert_eq(found, 2, "both members, from the rows' own objects")
    assert_eq(ctx.group.is_tank(tank), true, "the row says TANK")
    assert_eq(ctx.group.is_healer(healer), true, "the row says HEALER")
    assert_eq(#ctx.group.tanks(), 1, "one tank")
    rawset(mock.core.object_manager, "get_party_members", function() return {} end)
    mock.frame(1)
    fail_on_errors("group")
end }

T[#T + 1] = { "spell icons come from Wowhead's Forever data first, never from the loader's icons_helper (1.8.3)", function()
    -- Bait and Tackle is Forever's own: only dataEnv 16 knows it.
    local TT = "https://nether.wowhead.com/tooltip/spell/%d?dataEnv=%d&locale=0"
    mock.http_responses[string.format(TT, 1278067, 16)] = { code = 200, type = "application/json",
        body = '{"name":"Bait and Tackle","icon":"inv_misc_enggizmos_39"}' }
    local from = #mock.http_log
    JCore.assets.request("spell:1278067")
    JCore.assets.request("spell:999999901")      -- no environment knows it
    mock.frame(30)
    local asked, got_jpg = {}, false
    for i = from + 1, #mock.http_log do
        local url = mock.http_log[i]
        local id, env = url:match("tooltip/spell/(%d+)%?dataEnv=(%d+)")
        if id then
            asked[id] = asked[id] or {}
            asked[id][#asked[id] + 1] = tonumber(env)
        end
        if url:find("icons/large/inv_misc_enggizmos_39.jpg", 1, true) then got_jpg = true end
    end
    assert(asked["1278067"], "Bait and Tackle was looked up")
    assert_eq(asked["1278067"][1], 16, "in the Forever data first")
    assert_eq(#asked["1278067"], 1, "and found there")
    assert(got_jpg, "then its picture fetched by the name found")
    assert_eq(table.concat(asked["999999901"] or {}, ","), "16,4,1", "an unknown id: every environment, Forever's first")
    local e = JCore.assets.get("spell:999999901")
    assert(e and e.dead, "then it is given up on for the session")
    for i = 1, #mock.warnings do
        assert(not tostring(mock.warnings[i]):find("no icon name", 1, true), "no warning for it: " .. mock.warnings[i])
    end
    assert_eq(icon_helper.asked, 0, "icons_helper never asked for a name")

    JCore.draw.spell_icon(1278067, { x = 10, y = 10 }, 16)
    mock.frame(2)
    assert_eq(icon_helper.drew, 0, "nor asked to draw: draw.spell_icon goes through the assets")
    fail_on_errors("icons")
end }

return T

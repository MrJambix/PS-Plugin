-- JCore booted as Classic Era with a Forever client installed beside it: the
-- Forever support is ADDED, so on Era every path it touches must behave
-- exactly as it did before it existed. The client folder comes from the fixed
-- probe without reading the install files the Forever discovery uses,
-- cancel_buff reaches the native, and the backpack read is passed through raw.
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
mock.game_version = "Vanilla"
mock.exact_game_version = "wow_vanilla_us"

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

mock.wow_fs["_classic_era_/WTF/Config.wtf"] = "x"
mock.wow_fs["_classic_era_/.flavor.info"] = "Product Flavor!STRING:0\nwow_classic_era\n"
mock.wow_fs["_camelot_/WTF/Config.wtf"] = "x"
mock.wow_fs["_camelot_/.flavor.info"] = "Product Flavor!STRING:0\nwow_camelot\n"
mock.wow_fs[".build.info"] = "Branch!STRING:0|Active!DEC:1|Build Key!HEX:16|CDN Key!HEX:16|Version!STRING:0|Product!STRING:0\n"
    .. "us|1|" .. string.rep("e", 32) .. "|" .. string.rep("b", 32) .. "|1.15.9.70003|wow_classic_era\n"
    .. "us|1|" .. string.rep("f", 32) .. "|" .. string.rep("c", 32) .. "|1.60.1.70100|wow_camelot\n"
mock.wow_fs[".product.db"] = "\n\vwow_camelot\18\vwow_camelot\26\15\106\13_camelot_\"\0"

-- Every whole-file read, by path.
local reads = {}
local real_read = mock.core.read_file
mock.core.read_file = function(path)
    reads[#reads + 1] = path
    return real_read(path)
end

local JCore, ctx

local T = {}

T[#T + 1] = { "boot as Classic Era", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    JCore = _G.JCore
    mock.frame(5)
    fail_on_errors("boot")
    ctx = JCore.register({ id = "jtest.era", name = "Era test", version = "1.0.0" })
    assert(ctx, "plugin registered")
end }

T[#T + 1] = { "world.client() reports a classic client", function()
    local c = JCore.world.client()
    assert_eq(c.version, "Vanilla", "version")
    assert_eq(c.forever, false, "not Forever")
    assert_eq(c.trait_talents, false, "talent trees")
    assert_eq(c.classic_quest_log, true, "quest log")
    assert_eq(c.completed_quest_list, true, "completed list")
    assert_eq(c.cancel_buff, true, "cancel_buff works")
end }

T[#T + 1] = { "the client folder is the fixed probe's, and no install file is read for it", function()
    reads = {}
    JCore.assets.set_flavor("")
    assert_eq(JCore.assets.flavor(), "_classic_era_", "folder")
    for i = 1, #reads do
        local p = reads[i]
        assert(not p:find(".build.info", 1, true) and not p:find(".product.db", 1, true)
            and not p:find(".flavor.info", 1, true), "Era detection read " .. p)
    end
end }

T[#T + 1] = { "cancel_buff reaches the native on Era", function()
    local reached = 0
    rawset(mock.core.input, "cancel_buff", function() reached = reached + 1 end)
    ctx.input.cancel_buff({ impl = 1, buff_index = 1 })
    assert_eq(reached, 1, "native called")
end }

T[#T + 1] = { "the backpack read is passed through raw on Era", function()
    rawset(mock.core.inventory, "get_num_bag_slots", function(bag_id) return bag_id == 1 and 0 or 16 end)
    mock.game_event("BAG_UPDATE", { 0 })
    assert_eq(JCore.inventory.bag_slots(1), 0, "no Forever substitution on Era")
    fail_on_errors("after")
end }

T[#T + 1] = { "on Era the bags are read again only on a bag event, and free slots are the count (JCore 1.8.2)", function()
    local asked = 0
    package.loaded["common/utility/inventory_helper"] = {
        get_total_free_slots = function() asked = asked + 1 return 99 end,
        get_total_bag_capacity = function() asked = asked + 1 return 99 end,
        get_character_bag_slots = function() asked = asked + 1 return {} end,
    }
    local rows = { { slot_id = 1 }, { slot_id = 2 } }
    rawset(mock.core.inventory, "get_items_in_bag", function(bag) return bag == 0 and rows or {} end)
    rawset(mock.core.inventory, "get_num_bag_slots", function(bag_id) return bag_id == 1 and 16 or 0 end)
    mock.game_event("BAG_UPDATE", { 0 })
    assert_eq(JCore.inventory.free_slots(), 14, "16 slots - 2 rows: the count")
    rows[3] = { slot_id = 3 }
    mock.time = mock.time + 5
    assert_eq(JCore.inventory.free_slots(), 14, "no bag event: no new read, however long")
    mock.game_event("BAG_UPDATE", { 0 })
    assert_eq(JCore.inventory.free_slots(), 13, "the event reads again")
    assert_eq(asked, 0, "the helper is never asked on Era")
    package.loaded["common/utility/inventory_helper"] = nil
    fail_on_errors("era bags")
end }

T[#T + 1] = { "the global cooldown is the native's answer on Era; no probe is looked for", function()
    local base_reads = 0
    rawset(mock.core.spell_book, "get_global_cooldown", function() return 1.2 end)
    rawset(mock.core.spell_book, "get_spell_base_cooldown", function()
        base_reads = base_reads + 1
        return { cooldown_ms = 0, gcd_ms = 1500 }
    end)
    rawset(mock.core.spell_book, "get_spell_cooldown", function() return 0.5 end)
    ctx.spells.cooldown(1752)
    mock.frame(1)
    assert_eq(ctx.spells.gcd(), 1.2, "the native")
    assert_eq(ctx.player.gcd(), 1.2, "the player service too")
    assert_eq(base_reads, 0, "no base-cooldown reads on Era")
    assert_eq(ctx.spells.gcd_probe(), nil, "no probe")
end }

T[#T + 1] = { "on Era the loader's helper still decides what is castable", function()
    local helper = package.loaded["common/utility/spell_helper"]
    assert(helper and helper.asked ~= nil, "the stub helper is installed")
    local target = setmetatable({}, { __index = function(_, key)
        if key == "get_position" then return function() return { x = 0, y = 0, z = 0 } end end
        local answers = { is_valid = true, is_dead = false, get_guid = "Player-1-0003" }
        local v = answers[key]
        return function() return v end
    end })
    rawset(mock.core.object_manager, "get_local_player", function() return target end)
    mock.frame(2)
    helper.asked = 0
    assert_eq(ctx.spells.castable(1757, target, { skip_facing = true }), false, "the helper said no")
    assert_eq(helper.asked, 1, "and it was asked")
end }

T[#T + 1] = { "on Era a member's role is its own answer, and a row without a guid is not taken on trust", function()
    local member = setmetatable({}, { __index = function(_, key)
        if key == "get_position" then return function() return { x = 5, y = 0, z = 0 } end end
        local answers = { is_valid = true, is_dead = false, get_guid = "Player-1-0020", get_group_role = 2 }
        local v = answers[key]
        return function() return v end
    end })
    rawset(mock.core.object_manager, "get_party_members", function()
        return { { name = "Tanky", role = "TANK", object = member, index = 1 } }
    end)
    mock.frame(1)
    assert_eq(ctx.group.is_tank(member), false, "the row's word is not read on Era")
    assert_eq(ctx.group.is_healer(member), true, "the unit's own answer (2, healer) is")
    for _, o in ipairs(ctx.group.objects()) do
        assert(o ~= member, "a row with no guid adds no object on Era")
    end
    rawset(mock.core.object_manager, "get_party_members", function() return {} end)
    mock.frame(1)
end }

T[#T + 1] = { "on Era the creature cache is never read (JCore 1.5.15)", function()
    mock.wow_fs["_classic_era_/Cache/WDB/enUS/creaturecache.wdb"] = "BOMW" .. string.rep(" ", 40)
    local reads = 0
    local real = mock.core.read_file
    rawset(mock.core, "read_file", function(path, ...)
        if tostring(path):find("Cache/WDB", 1, true) then reads = reads + 1 end
        return real(path, ...)
    end)
    assert_eq(ctx.creatures.info(705), nil, "nothing known")
    assert_eq(ctx.creatures.load(true), 0, "a forced load reads nothing")
    assert_eq(ctx.creatures.stats().error, "not Forever", "and says why")
    assert_eq(reads, 0, "no cache file was opened")
    rawset(mock.core, "read_file", real)
end }

T[#T + 1] = { "on Era beast() reads the cache when asked -- tameable and family; info() still answers nil (JCore 1.8.6)", function()
    local era = assert(jtest.read_file("tools/jtest/mock/fixtures/era_creaturecache_70003.wdb"), "the Era fixture")
    mock.wow_fs["_classic_era_/Cache/WDB/enUS/creaturecache.wdb"] = era
    local b = ctx.creatures.beast(3566)
    assert(b, "Flatland Prowler is in the cache: " .. tostring(ctx.creatures.stats().error))
    assert_eq(b.tameable, true, "a hunter can tame it")
    assert_eq(b.family, 2, "a cat")
    assert_eq(b.type, 1, "a beast")
    assert_eq(ctx.creatures.beast(4310).tameable, false, "Cor Grimtotem is not")
    assert_eq(ctx.creatures.stats().layout, "Era 70003", "read in Era's layout")
    assert_eq(ctx.creatures.info(3566), nil, "info() still nil on Era: no Era name or rank changes")
    assert_eq(ctx.creatures.name(3566), nil, "nor a name")
    assert_eq(ctx.creatures.beast(99999999), nil, "an id the cache does not know")
    mock.wow_fs["_classic_era_/Cache/WDB/enUS/creaturecache.wdb"] = nil
end }

T[#T + 1] = { "on Era the game's Lua is never touched (JCore 1.5.16)", function()
    local executed, read = 0, 0
    rawset(mock.core, "execute", function() executed = executed + 1 end)
    for _, name in ipairs({ "read_lua_string", "read_lua_integer", "read_lua_table_string", "read_lua_table_integer" }) do
        rawset(mock.core, name, function() read = read + 1 end)
    end
    mock.frame(400)
    local state, why = ctx.gamelua.state()
    assert_eq(state, "off", "the bridge is off")
    -- JCore 1.8.1: off on every client, the calls not being in .api.
    assert(tostring(why):find(".api", 1, true), "and says why: " .. tostring(why))
    assert_eq(ctx.gamelua.run("x", "out(1)", function() end), false, "a run is refused")
    assert_eq(executed, 0, "nothing executed")
    assert_eq(read, 0, "nothing read")
end }

return T

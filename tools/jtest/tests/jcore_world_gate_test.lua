-- JCore 1.8.1: the world gate.
--
-- 2026-10-12 13:26 the game died 0.2 s after the loader started the plugins
-- at the character select screen: ASSERT(IsLoaded()) in WowClientDB2.cpp,
-- a native reading a table the game loads only for the world. The black box
-- ended on JCore's first pre_tick; next came the plugins' own start-ups
-- (they load before JCore and poll for it) and the black box's context line
-- (the map and zone names). Now JCore runs no pass and forwards no game
-- event until a character is in the world, the plugins wait on
-- JCore.in_world() to start, and the context line asks nothing there.
--
-- Booted as Forever with Jambix Debug, World Click loaded first as the
-- loader does (alphabetical: jambix_* before jcore). The tests run in ORDER
-- inside one Lua state.

local mock = require("mock_core")
mock.install()
_G.JCORE_NO_WORLD_GATE = nil -- this file tests the gate itself
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"
mock.frame_dt = 0.05
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }

-- The data files as the real core's: write APPENDS, create EMPTIES.
local function norm(p)
    return (tostring(p or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/"):gsub("/$", ""))
end
rawset(mock.core, "write_data_file", function(path, data)
    path = norm(path)
    if mock.data_fs[path] == nil then return end
    mock.data_fs[path] = mock.data_fs[path] .. tostring(data)
end)
rawset(mock.core, "create_data_file", function(path)
    mock.data_fs[norm(path)] = ""
    return true
end)

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(text, needle, label)
    if not tostring(text):find(needle, 1, true) then
        error(string.format("%s: %q not found in:\n%s", label, needle, tostring(text)), 2)
    end
end

-- The natives that read the game's tables, counted: the character screen
-- must never see one.
local asked = {}
local function watch(ns, name)
    local original = ns[name]
    rawset(ns, name, function(...)
        asked[name] = (asked[name] or 0) + 1
        return original(...)
    end)
end
watch(mock.core, "get_map_name")
watch(mock.core, "get_instance_name")
watch(mock.core.spell_book, "get_spell_name")
watch(mock.core.spell_book, "get_spell_description")

local function table_reads()
    local n = 0
    for _, v in pairs(asked) do n = n + v end
    return n
end

-- The player: nil at the character screen.
local player = nil
local player_asks = 0
rawset(mock.core.object_manager, "get_local_player", function()
    player_asks = player_asks + 1
    return player
end)

local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = false,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_unit_ranged_damage = { speed = 2.8 },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6,
    }
    local obj = {}
    for k, v in pairs(p) do
        obj[k] = function() return v end
    end
    obj.get_position = function() return { x = 100, y = 100, z = 0 } end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local BOX1 = "jcore/jambix.debug.blackbox.1.txt"
local BOX2 = "jcore/jambix.debug.blackbox.2.txt"
local function box_text() return (mock.data_fs[BOX1] or "") .. (mock.data_fs[BOX2] or "") end

local JCore
local runs = { tick = 0, pre_tick = 0, render = 0, menu = 0, event = 0, opened = 0 }

local T = {}

T[#T + 1] = { "loaded at the character screen: no pass, no game event, no table read, World Click waits", function()
    require("jambix_worldclick/main")
    assert_eq(_G.JambixWorldClick, nil, "World Click polls for JCore")
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    assert_eq(JCore.in_world(), false, "not in the world")
    has(box_text(), "G waiting for the world (the character screen)", "the black box says JCore waits")

    JCore.register({
        id = "gate.test", name = "Gate", version = "1.0.0", kind = "plugin",
        on_load = function(ctx)
            ctx.tick(function() runs.tick = runs.tick + 1 end)
            ctx.pre_tick(function() runs.pre_tick = runs.pre_tick + 1 end)
            ctx.render(function() runs.render = runs.render + 1 end)
            ctx.render_menu(function() runs.menu = runs.menu + 1 end)
            ctx.on("jcore.game_event.SPELLS_CHANGED", function() runs.event = runs.event + 1 end)
            ctx.on("jcore.world.open", function() runs.opened = runs.opened + 1 end)
        end,
    })

    local reads_at_boot = table_reads()
    player_asks = 0
    for _ = 1, 20 do
        mock.frame(1)
        for i = 1, #mock.callbacks.render_menu do mock.callbacks.render_menu[i]() end
        mock.game_event("SPELLS_CHANGED", {})
    end
    assert_eq(runs.tick + runs.pre_tick + runs.render + runs.menu, 0, "no job ran")
    assert_eq(runs.event, 0, "no game event was forwarded")
    assert_eq(table_reads(), reads_at_boot, "no spell, map or zone name was asked")
    -- World Click's poller (1 a frame) and JCore's update pass (1 a frame).
    assert(player_asks <= 40, "the player asked at most twice a frame: " .. player_asks)
    assert_eq(_G.JambixWorldClick, nil, "World Click has not started")
    assert_eq(JCore.in_world(), false, "still not in the world")
    assert(not box_text():find("> update", 1, true), "no pass marked in the black box")
end }

T[#T + 1] = { "a character in the world: the gate opens once, the passes start, World Click starts", function()
    player = hunter()
    mock.frame(1)
    assert_eq(JCore.in_world(), true, "in the world")
    assert_eq(runs.opened, 1, "jcore.world.open once")
    assert(runs.tick > 0 and runs.pre_tick == 0 and runs.render > 0, "this frame's update and render ran")
    has(box_text(), "G in the world: the passes start", "the black box marks the gate")
    has(box_text(), "> update", "the passes are marked again")
    mock.frame(1)
    assert(_G.JambixWorldClick ~= nil, "World Click started on the next frame at the latest")
    assert(runs.pre_tick > 0, "pre_tick runs")
    mock.game_event("SPELLS_CHANGED", {})
    assert_eq(runs.event, 1, "game events are forwarded")
end }

T[#T + 1] = { "a loading screen later does not close it", function()
    player = nil
    local tick = runs.tick
    mock.frame(3)
    assert_eq(JCore.in_world(), true, "still open")
    assert_eq(runs.tick, tick + 3, "the passes go on with no player, as before the gate")
    assert_eq(runs.opened, 1, "never opened twice")
end }

return T

-- Jambix AIO, the WHOLE plugin on the whole of JCore as the Forever client,
-- with a hunter logged in and the rotation on: every core call and every
-- game_object method goes through JCore's API recorder (services/recorder.lua,
-- built by main.lua straight after the cache), so this proves the plugin
-- runs clean with everything wrapped, and that what it called ends up in the
-- recording the report tool reads.

local boot = require("mock/aio_boot")

local FILE = "jcore/jcore.recorder.json"
local PAGE = "Jambix Debug/API recorder"

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A hunter whose methods come from one shared lookup, the way a native
--- usertype serves them; anything it does not know answers nil.
local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = true, is_enemy_with = true,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_unit_ranged_damage = { speed = 2.8 },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6,
    }
    local methods = {}
    for k, v in pairs(p) do methods[k] = function() return v end end
    methods.get_position = function() return { x = 100, y = 100, z = 0 } end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end })
end

--- A hostile mob ten yards from the hunter, served the same way.
local function mob()
    local p = {
        is_valid = true, is_dead = false, is_visible = true, get_guid = "Creature-0-1-0-0-3124-0000ABCDEF",
        get_name = "", get_level = 3, get_health = 50, get_max_health = 60,
        is_unit = true, is_player = false, can_attack = true, is_enemy_with = true,
        get_type = 5, get_creature_type = 4, get_npc_id = 3124, get_height = 2,
    }
    local methods = {}
    for k, v in pairs(p) do methods[k] = function() return v end end
    methods.get_position = function() return { x = 110, y = 100, z = 0 } end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end })
end

local function save_button(b)
    local page = b.mock.menu.pages[PAGE]
    assert(page, "the recorder page is declared")
    for _, section in ipairs(page.sections) do
        if section.buttons and section.buttons.save then return section.buttons.save end
    end
    error("no Save now button")
end

local T = {}
local b, me, real_player, wind

T[#T + 1] = { "Forever: the whole plugin boots clean with the recorder wrapping core", function()
    me = hunter()
    wind = mob()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        -- Before JCore loads, so the recorder wraps the one the game would have.
        real_player = function() return me end
        rawset(mock.core.object_manager, "get_local_player", real_player)
        rawset(mock.core.object_manager, "get_visible_objects", function() return { me, wind } end)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert(core.object_manager.get_local_player ~= real_player, "the player lookup is wrapped")
    assert(core.menu.window ~= nil, "core.menu is left alone")
    b.mock.menu:set("Jambix AIO/Rotation", "rot_enabled", true)
    b.mock.menu:set("Jambix AIO/Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    b.P.opt_invalidate()
    assert_eq(b.P.rotation_active(), true, "the rotation's gate is open on Forever")
end }

T[#T + 1] = { "Forever: five seconds of frames through the rotation, no errors", function()
    b.mock.frame(300)
    assert_eq(b.errors(), "", "core.log_error while running")
    assert_eq(core.object_manager.get_local_player(), me, "the wrapped lookup answers the player")
    b.mock.game_event("UNIT_AURA", { "player" })
    assert_eq(b.errors(), "", "core.log_error after an event")
end }

T[#T + 1] = { "Forever: the recording holds the plugin's calls, its object methods and the events", function()
    b.mock.data_fs[FILE] = nil
    save_button(b).on_click()
    local text = b.mock.data_fs[FILE]
    assert(text and #text > 0, "Save now wrote the file")
    local data = require("jcore/lib/json").decode(text)
    assert_eq(data.client.version, "Forever", "client")
    assert_eq(data.client.jcore, "1.8.1", "jcore version")
    assert_eq(data.format, 2, "one entry per function")
    local get_player = data.functions["object_manager.get_local_player"]
    assert(get_player and get_player.calls > 0, "the player lookup is recorded")
    local in_update = false
    for trigger in pairs(get_player.triggers or {}) do
        if trigger:find("^update jcore/") then in_update = true end
    end
    assert(in_update, "main.lua's update callback is the phase, a JCore service the site")
    local health = data.methods["get_health"]
    assert(health and health.calls > 0, "game_object methods are recorded")
    assert_eq(data.surface.object_index, "function", "found through the shared lookup")
    assert(data.events["UNIT_AURA"], "the event reached the recorder through main.lua's hook")
    for i = 1, #data.surface.unwritable do
        error("could not wrap " .. tostring(data.surface.unwritable[i]))
    end

    b.mock.menu.title_errors = {}
    b.mock.menu:render_titles()
    assert_eq(#b.mock.menu.title_errors, 0, "live lines: " .. table.concat(b.mock.menu.title_errors, "; "))
end }

T[#T + 1] = { "Forever: the trace follows the mob through the sweep", function()
    -- The mob arrived in the first sweep; the save in the test above wrote it.
    b.mock.frame(30)
    save_button(b).on_click()
    local text = b.mock.data_fs["jcore/jcore.trace.txt"]
    assert(text and #text > 0, "the trace is written beside the recording")
    assert(text:find("sweep + 0000ABCDEF", 1, true), "the sweep's arrival of the mob: " .. text:sub(1, 300))
    assert_eq(b.errors(), "", "core.log_error while tracing")
    if jtest and jtest.write_file then jtest.write_file("recorder/boot.trace.txt", text) end
end }

T[#T + 1] = { "Forever: the classic ESP stays off; the Forever ESP marks the mob, by its type", function()
    assert_eq(b.P.esp.off, true, "the classic ESP is off on Forever")
    assert(b.P.esp.forever, "the Forever ESP is loaded")
    b.mock.menu:set("Jambix AIO/Forever ESP", "toggle_key", { vk = 0x5A, active = true, toggled = true })
    b.P.opt_invalidate()
    rawset(core.graphics, "w2s", function(pos)
        return { x = 960 + (pos.x - 100) * 10, y = 540 - (pos.z or 0) * 10 }
    end)
    b.mock.frame(30)
    assert_eq(b.P.esp.count(), 0, "the classic ESP collected nothing")
    assert_eq(#b.P.esp.corpses(), 0, "no classic corpse list")
    local s = b.P.esp.forever.stats()
    assert_eq(s.drawn, 1, "the mob is marked")
    local name, source = b.P.esp.forever.name_for(wind)
    assert_eq(name, "Elemental", "no name from the client: its creature type")
    assert_eq(source, "type", "source")
    b.P.esp.alert_check()
    b.P.esp.draw_threat_panel()
    b.P.esp.draw_threat_arrows()
    assert_eq(b.errors(), "", "core.log_error with the Forever ESP")
end }

T[#T + 1] = { "Forever: casting at the mob teaches its name, kept by npc id", function()
    rawset(me, "get_target", function() return wind end)
    b.mock.game_event("UNIT_SPELLCAST_SENT", { "player", "Roiling Wind", "Cast-3-1-1-1-1752-0001", 1752 })
    local name, source = b.P.esp.forever.name_for(wind)
    assert_eq(name, "Roiling Wind", "learned from the cast")
    assert_eq(source, "known", "source")
    assert_eq(b.P.esp.forever.stats().learned, 1, "one name learned")
    b.mock.data_fs["jcore/jcore.trace.txt"] = nil
    b.mock.frame(40)
    save_button(b).on_click()
    local text = b.mock.data_fs["jcore/jcore.trace.txt"] or ""
    assert(text:find("fesp 0000ABCDEF Roiling Wind", 1, true), "the Forever ESP traces its mark: " .. text:sub(-800))
    assert(text:find("fesp frame units=", 1, true), "and its frame summary")
    assert_eq(b.errors(), "", "core.log_error after learning a name")
    if jtest and jtest.write_file then jtest.write_file("recorder/fesp.trace.txt", text) end
end }

T[#T + 1] = { "Forever: switching the recorder off puts the originals back and the plugin runs on", function()
    b.mock.menu:set(PAGE, "record", false)
    -- Jambix Debug 1.1.0: the Faults page's native watch keeps the wrappers
    -- in with recording off; switching the watch off too puts them back.
    assert(core.object_manager.get_local_player ~= real_player, "the watch keeps the wrapper")
    b.mock.frame(5)
    b.mock.menu:set("Jambix Debug/Faults", "watch", false)
    assert_eq(core.object_manager.get_local_player, real_player, "original restored")
    b.mock.frame(60)
    assert_eq(b.errors(), "", "core.log_error after the recorder stopped")
end }

return T

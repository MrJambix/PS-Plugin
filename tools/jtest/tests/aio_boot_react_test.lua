-- Jambix AIO, the WHOLE plugin with the rotation ON: main.lua on top of the
-- whole JCore under mock_core, as the Era client, with a hunter logged in, the
-- rotation switched on with its key, and the reaction panel open. The other
-- boot tests run with the rotation at its default (off), where the reaction
-- engine never ticks; this one makes every frame go through it.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A hunter, answering what the runtime asks of a player; anything else nil.
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

local function set(b, page, id, value)
    b.mock.menu:set("Jambix AIO/" .. page, id, value)
    b.P.opt_invalidate()
end

local T = {}
local b

T[#T + 1] = { "whole plugin, rotation on: boots clean as Era with a hunter logged in", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    local me = hunter()
    core.object_manager.get_local_player = function() return me end
    assert_eq(b.errors(), "", "core.log_error during boot")
    set(b, "Rotation", "rot_enabled", true)
    set(b, "Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    set(b, "Reactions", "react_overlay", true)
    assert_eq(b.P.rotation_active(), true, "the rotation's gate is open")
end }

T[#T + 1] = { "whole plugin, rotation on: two seconds of frames through the reaction engine, no errors", function()
    b.mock.frame(120)
    assert_eq(b.errors(), "", "core.log_error while running")
    local R = b.P.react
    assert(R, "the reaction engine is on the bundle")
    local W = R.world.W
    assert(W and W.player and W.player.unit ~= nil, "the engine built its world from the live player")
    assert_eq(R.stats().mode, "NORMAL", "out of combat, nothing pressing")
    local panel = table.concat(R.overlay_lines(), " / ")
    assert(not panel:find("nothing to press", 1, true), "the panel does not say 'nothing to press': " .. panel)
    assert(panel:find("Rotation: ", 1, true) or panel:find("NORMAL", 1, true), "the panel reads sensibly: " .. panel)
    -- The class resolved, and the hunter's own reactions loaded with it.
    assert(R.engine.rule("Stop the cast with crowd control"), "hunter reactions loaded for the class")
end }

T[#T + 1] = { "whole plugin, rotation on: the panel says when the rotation is switched off", function()
    set(b, "Rotation", "rot_enabled", false)
    b.mock.frame(120)
    assert_eq(b.errors(), "", "core.log_error while running")
    local panel = table.concat(b.P.react.overlay_lines(), " / ")
    assert(panel:find("OFF", 1, true), "it says OFF: " .. panel)
end }

T[#T + 1] = { "whole plugin: the 1.39.0 switches are retired -- the menu is never read for them", function()
    for _, id in ipairs({ "rot_taunt", "rest_health", "rest_mana", "rest_health_to", "rest_mana_to",
                          "rot_use_cooldowns", "rot_use_trinkets" }) do
        assert_eq(b.P.RETIRED[id], true, id .. " is retired")
        assert_eq(b.P.opt(id, "the default"), "the default", id .. " answers its default, never a saved value")
    end
end }

-- 1.74.0: the live log (Forever, a five-man) pressed Hunter's Mark at every
-- mob the group killed -- no health, auras gone, the dead flag not yet set.
T[#T + 1] = { "whole plugin: a target at no health is no target, whatever the dead flag says (1.74.0)", function()
    local me = hunter()
    local mob_hp = 0
    local mob = setmetatable({
        is_valid = function() return true end, is_dead = function() return false end,
        get_guid = function() return "Creature-0-1-2-3-3566-0009" end,
        get_health = function() return mob_hp end, get_max_health = function() return 1000 end,
        is_in_combat = function() return true end, get_auras = function() return {} end,
    }, { __index = function() return function() return nil end end })
    me.get_target = function() return mob end
    me.can_attack = function(_, other) return other == mob end
    core.object_manager.get_local_player = function() return me end
    b.mock.frame(1)                            -- the runtime takes the new player
    local rot = b.P.rotation
    local cm = rot.active_class()
    local s = rot.build_situation(cm, cm.profiles.leveling)
    assert_eq(s and s.target, nil, "no health, not flagged dead: no target")
    mob_hp = 400
    b.mock.frame(1)
    s = rot.build_situation(cm, cm.profiles.leveling)
    assert_eq(s and s.target, mob, "with health it is the target")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "whole plugin on Era: none of the Forever paths exist", function()
    assert(not b.P.forever, "not Forever")
    assert_eq(b.P.forever_power, nil, "no counted resources")
    assert_eq(b.P.power_counted("ENERGY"), false, "JCore counts nothing on Era")
    assert_eq(b.P.power_unread("MANA"), nil, "and every bar is read")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

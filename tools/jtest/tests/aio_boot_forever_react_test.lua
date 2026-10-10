-- Jambix AIO, the WHOLE plugin on the whole of JCore as the Forever client,
-- with a ROGUE logged in whose every power read answers 0 -- what the JCore
-- API recorder saw on the Forever beta (164,586 of 164,586 get_power calls) --
-- and the rotation and the reaction readout on. The Forever paths of the
-- reactions and the rotation (1.45.0) are built, count the combo points from
-- the client's own cast events, and say what they work around; nothing
-- errors while they run.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A rogue whose methods come from one shared lookup, the way a native
--- usertype serves them; anything it does not know answers nil.
local function rogue()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-4619-01411DD5",
        get_name = "", get_class = 4, get_race_id = 0, get_level = 4,
        get_health = 70, get_max_health = 79, get_power = 0, get_max_power = 0,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = true, is_enemy_with = true,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.0,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6,
    }
    local methods = {}
    for k, v in pairs(p) do methods[k] = function() return v end end
    methods.get_position = function() return { x = 100, y = 100, z = 0 } end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end })
end

local function set(b, page, id, value)
    b.mock.menu:set("Jambix AIO/" .. page, id, value)
    b.P.opt_invalidate()
end

local T = {}
local b

T[#T + 1] = { "Forever, a rogue whose power reads 0: the plugin boots clean with its Forever paths built", function()
    local me = rogue()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        rawset(mock.core.object_manager, "get_local_player", function() return me end)
        rawset(mock.core.spell_book, "get_global_cooldown", function() return 0 end)
        rawset(mock.core.spell_book, "get_spell_costs", function(id)
            if id == 1752 then return { { cost = 45, min_cost = 45, cost_type = 3 } } end
            return {}
        end)
        rawset(mock.core.spell_book, "get_spell_description", function(id)
            if id == 1752 then return "An instant strike. Awards 1 combo point." end
            if id == 2098 then return "Finishing move that causes damage per combo point." end
            return ""
        end)
        rawset(mock.core.spell_book, "get_base_power_regen", function() return 10 end)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, true, "the plugin knows it is on Forever")
    assert(b.P.ctx.power, "JCore counts the resources (services/power.lua, 1.6.0)")
    assert_eq(b.P.forever_power, nil, "the plugin no longer counts them itself")
    set(b, "Rotation", "rot_enabled", true)
    set(b, "Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    set(b, "Rotation", "react_overlay", true)
    assert_eq(b.P.rotation_active(), true, "the rotation's gate is open")
end }

T[#T + 1] = { "Forever: combo points are counted from the client's cast events though every read is 0", function()
    assert_eq(b.P.power("COMBOPOINTS"), 0, "nothing yet")
    for _ = 1, 3 do
        b.mock.game_event("UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-2-0", 1752 })
    end
    assert_eq(b.P.power("COMBOPOINTS"), 3, "three Sinister Strikes, three points")
    assert_eq(b.P.power_max("COMBOPOINTS"), 5, "out of five")
    local energy = b.P.power("ENERGY")
    assert(type(energy) == "number" and energy >= 0 and energy <= 100, "energy is counted, 0 to 100: " .. tostring(energy))
    assert_eq(b.P.power_max("ENERGY"), 100, "out of a hundred, though the client reads 0")
    b.mock.game_event("UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-2-1", 2098 })
    assert_eq(b.P.power("COMBOPOINTS"), 0, "Eviscerate spent them")
    assert_eq(b.errors(), "", "core.log_error after the events")
end }

T[#T + 1] = { "Forever: two seconds of frames through the reactions; the readout says what it works around", function()
    b.P.react.debug_lines()
    b.mock.frame(120)
    assert_eq(b.errors(), "", "core.log_error while running")
    local lines = table.concat(b.P.react.debug_lines(), " / ")
    assert(lines:find("Forever: GCD", 1, true), "the Forever line: " .. lines:sub(1, 400))
end }

return T

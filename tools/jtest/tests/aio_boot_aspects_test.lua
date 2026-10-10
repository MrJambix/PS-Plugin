-- Jambix AIO, the WHOLE plugin with a hunter who knows three aspects: main.lua
-- on the whole JCore under mock_core, as the Era client. The Aspects window
-- is drawn by JCore's real overlay UI, and its switches are clicked with the
-- mock's mouse: a click slides an aspect on (one cast), a second click slides
-- it off (core.input.cancel_buff with the row get_buffs handed out). The
-- hunter's active profile has no aspect rule.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local IDS = { ["Aspect of the Hawk"] = 13165, ["Aspect of the Monkey"] = 13163, ["Aspect of the Cheetah"] = 5118 }
local NAMES = {}
for name, id in pairs(IDS) do NAMES[id] = name end

local auras = {}          -- spell id -> true, on the player
local buff_rows = nil     -- what get_buffs handed out last

--- A hunter, answering what the runtime asks of a player; anything else nil.
local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = false,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_debuffs = {},
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
    local function rows()
        local out = {}
        for id in pairs(auras) do
            out[#out + 1] = { buff_id = id, buff_name = NAMES[id], impl = id * 10, buff_index = #out + 1,
                              expire_time = 0, duration = 0, count = 0, type = 0 }
        end
        return out
    end
    obj.get_auras = function() return rows() end
    obj.get_buffs = function() buff_rows = rows(); return buff_rows end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local T = {}
local b
local casts, cancels = {}, {}

--- Clicks the window's nth switch: hover, press, release, a frame each.
local function click_row(n)
    local win
    for _, w in ipairs(b.JCore.ui.windows()) do
        if w.id == "jambix.aio:class_window" then win = w end
    end
    assert(win, "the Hunter window exists (1.62.0: the class window holds the aspects)")
    local t = b.JCore.ui._T
    local y = win.y + t.title_h + t.pad + (n - 1) * (t.widget_h + t.gap) + t.widget_h / 2
    b.mock.move(win.x + win.w / 2, y)
    b.mock.frame(2)
    b.mock.press(0x01)
    b.mock.frame(1)
    b.mock.release(0x01)
    b.mock.frame(2)
end

T[#T + 1] = { "whole plugin: a hunter who knows three aspects gets the Aspects window", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    local me = hunter()
    core.object_manager.get_local_player = function() return me end
    core.spell_book.get_spells = function() return { 13165, 13163, 5118 } end
    core.spell_book.get_spell_name = function(id) return NAMES[id] end
    core.spell_book.is_spell_known = function(id) return NAMES[id] ~= nil end
    core.spell_book.is_usable_spell = function(id) return NAMES[id] ~= nil end
    core.spell_book.get_spell_cooldown = function() return 0 end
    b.P.spellbook.refresh()
    -- Recorders, swapped in after boot: both are looked up at call time.
    b.ctx.cast = function(request) casts[#casts + 1] = request; return true end
    core.input.cancel_buff = function(row) cancels[#cancels + 1] = row; auras[row.buff_id] = nil end

    b.mock.frame(30)
    assert_eq(b.errors(), "", "core.log_error during boot and frames")
    local st = b.P.aspects.stats()
    assert_eq(table.concat(st.trained, ","), "Hawk,Monkey,Cheetah", "a switch per trained aspect")
    assert_eq(st.shown, true, "the window is drawn")
    assert_eq(st.status, "No aspect. Slide one on.", "nothing chosen")
    assert_eq(#casts, 0, "and nothing cast")
end }

T[#T + 1] = { "whole plugin: the hunter's profile has no aspect rule", function()
    assert_eq(b.P.rotation.has_rule("Aspect of the Hawk"), false, "no Aspect of the Hawk rule")
end }

T[#T + 1] = { "whole plugin: clicking Monkey's switch slides it on and casts it once", function()
    click_row(2)
    assert_eq(b.P.aspects.stats().wanted, "Aspect of the Monkey", "Monkey chosen")
    b.mock.frame(30)
    local n = 0
    for i = 1, #casts do
        if casts[i].spell_id == IDS["Aspect of the Monkey"] then n = n + 1 end
        assert(casts[i].spell_id ~= IDS["Aspect of the Hawk"], "never Hawk")
    end
    assert(n >= 1, "Monkey requested; status: " .. tostring(b.P.aspects.stats().status))
    auras[IDS["Aspect of the Monkey"]] = true
    b.mock.frame(30)
    assert_eq(b.P.aspects.stats().status, "Monkey is up.", "up")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "whole plugin: clicking it again slides it off and cancels the aura", function()
    click_row(2)
    assert_eq(b.P.aspects.stats().wanted, nil, "switched off")
    assert_eq(#cancels, 1, "one cancel")
    assert_eq(cancels[1].buff_id, IDS["Aspect of the Monkey"], "Monkey's aura")
    assert(cancels[1] == buff_rows[1], "the row get_buffs handed out")
    local before = #casts
    b.mock.frame(60)
    assert_eq(#casts, before, "not put back")
    assert_eq(b.P.aspects.stats().status, "No aspect. Slide one on.", "and the window says so")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "whole plugin: the window's option hides it", function()
    b.mock.menu:set("Jambix AIO/Rotation", "class_window", false)
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.P.classwin.stats().shown, false, "hidden")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

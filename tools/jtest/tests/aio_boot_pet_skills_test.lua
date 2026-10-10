-- Jambix AIO, the WHOLE plugin: a hunter in combat with a wolf beside its mob.
-- The user, 2026-10-04: "I dont see any [pet skills] being used when its off
-- auto". The engine takes them off autocast; this proves the whole path from
-- the client's pet book to core.input.pet_cast_target_spell actually presses.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A game object answering `fields` (a value, or a function for one that
--- takes arguments); anything else answers nil.
local function object(fields)
    local obj = {}
    for k, v in pairs(fields) do
        if type(v) == "function" then obj[k] = v else obj[k] = function() return v end end
    end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

--- A vec3 with the methods the runtime asks of positions.
local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, V) end
function V.dist_to(a, b) local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z return math.sqrt(dx * dx + dy * dy + dz * dz) end
function V.squared_dist_to(a, b) local d = V.dist_to(a, b) return d * d end
function V.dist_to_ignore_z(a, b) local dx, dy = a.x - b.x, a.y - b.y return math.sqrt(dx * dx + dy * dy) end
function V.squared_dist_to_ignore_z(a, b) local d = V.dist_to_ignore_z(a, b) return d * d end
function V.clone(a) return vec3(a.x, a.y, a.z) end
function V.length(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
function V.normalize(a) local l = V.length(a) if l == 0 then return vec3(0, 0, 0) end return vec3(a.x / l, a.y / l, a.z / l) end
V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, k) if type(k) == "number" then return vec3(a.x * k, a.y * k, a.z * k) end return vec3(a.x * k.x, a.y * k.y, a.z * k.z) end

local T = {}
local b, me, pet, mob
local W = { casts = {}, off = {}, on = {}, focus = 100 }

-- The pet's book: id -> name, as get_pet_spells / get_pet_action_info answer.
local BOOK = { [2649] = "Growl", [16827] = "Claw", [24604] = "Furious Howl", [17253] = "Bite" }
-- Spell names the client knows beyond the pet book (another rank's id).
local NAMES = {}

T[#T + 1] = { "boot as Era with a hunter, its wolf and a mob the wolf is fighting", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    mob = object({
        is_valid = true, is_dead = false, get_guid = "Creature-0-1-2-3-3566-0001", get_name = "Flatland Prowler",
        get_level = 30, get_health = 800, get_max_health = 1000, get_classification = 0, get_creature_type = 1,
        get_npc_id = 3566, is_player = false, is_unit = true, get_type = 5, is_in_combat = true,
        get_combat_reach = 1.5, get_position = vec3(102, 110, 0),
        is_casting_spell = false, is_channelling_spell = false, get_auras = {}, get_buffs = {}, get_debuffs = {},
    })
    pet = object({
        is_valid = true, is_dead = false, get_guid = "Pet-0-1-2-3-1-0001", get_name = "Wolf",
        get_level = 30, get_health = 900, get_max_health = 1000, is_player = false, is_unit = true, get_type = 5,
        is_in_combat = true, get_combat_reach = 1.5, get_position = vec3(100, 110, 0),
        get_power = function() return W.focus end, get_max_power = 100,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
    })
    mob.get_target = function() return pet end
    pet.get_target = function() return mob end
    me = object({
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = true, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_unit_ranged_damage = { speed = 2.8 },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6, get_position = vec3(100, 100, 0),
        get_combat_reach = 1.5,
        get_pet = function() return pet end,
        get_target = function() return mob end,
        can_attack = function(_, other) return other == mob end,
    })
    core.object_manager.get_local_player = function() return me end
    core.object_manager.get_visible_objects = function() return { me, pet, mob } end
    core.spell_book.get_pet_spells = function()
        local ids = {}
        for id in pairs(BOOK) do ids[#ids + 1] = id end
        return ids
    end
    core.spell_book.get_pet_action_info = function(id)
        if not BOOK[id] then return nil end
        return { name = BOOK[id], spell_id = id, auto_cast_allowed = true, auto_cast_enabled = W.on[id] ~= false }
    end
    core.spell_book.get_spell_name = function(id) return BOOK[id] or NAMES[id] or "" end
    core.input.pet_cast_target_spell = function(id, target) W.casts[#W.casts + 1] = { id = id, target = target } end
    core.input.disable_pet_autocast = function(id) W.off[id] = (W.off[id] or 0) + 1; W.on[id] = false end
    core.input.enable_pet_autocast = function(id) W.on[id] = true end
    b.mock.menu:set("Jambix AIO/Rotation", "rot_enabled", true)
    b.mock.menu:set("Jambix AIO/Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    b.mock.menu:set("Jambix AIO/Rotation", "react_overlay", true)
    b.P.opt_invalidate()
    b.P.ctx.emit("jambix.aio.spells_changed")
    assert_eq(b.errors(), "", "core.log_error during boot")
end }

T[#T + 1] = { "two seconds of combat: Growl and Furious Howl are off autocast, and Growl is PRESSED at the wolf's mob", function()
    b.mock.frame(120)
    assert_eq(b.errors(), "", "core.log_error while running")
    local R = b.P.react
    local lines = table.concat(R.debug_lines(), "\n")
    b.mock.frame(30)
    lines = table.concat(R.debug_lines(), "\n")
    assert((W.off[2649] or 0) >= 1, "Growl was taken off autocast")
    assert((W.off[24604] or 0) >= 1, "Furious Howl was taken off autocast (solo at range: never pressed)")
    local growls = 0
    for _, c in ipairs(W.casts) do if c.id == 2649 then growls = growls + 1 end end
    local S = R.petthreat and R.petthreat.state or {}
    local pick = S.pick
    assert(growls >= 1, string.format(
        "Growl never pressed. planner: live=%s name=%s ready_in=%s short=%s pick=%s pet_pos=%s n=%d\nreadout:\n%s",
        tostring(S.live), tostring(S.name), tostring(S.ready_in), tostring(S.short),
        pick and (pick.kind .. " reach=" .. tostring(pick.reach)) or "nil",
        S.pet_pos and string.format("%.0f,%.0f", S.pet_pos.x, S.pet_pos.y) or "nil", #(S.list or {}), lines))
    assert_eq(W.casts[1].target, mob, "at the wolf's own mob")
end }


T[#T + 1] = { "the client does not say the pet's target, and its cast events carry another rank's id: Growl is still pressed every cooldown (1.73.1)", function()
    -- What the pet is attacking: nothing the client says. The mob is on the pet.
    pet.get_target = function() return nil end
    -- Every press the pet carries out reports Growl rank 4 (14918), the book says 2649.
    NAMES[14918] = "Growl"
    local before = #W.casts
    for _ = 1, 14 do
        local n = #W.casts
        b.mock.frame(60)
        for i = n + 1, #W.casts do
            if W.casts[i].id == 2649 then b.mock.game_event("UNIT_SPELLCAST_SUCCEEDED", { "pet", "cast-guid", 14918 }) end
        end
    end
    assert_eq(b.errors(), "", "core.log_error while running")
    local growls = 0
    for i = before + 1, #W.casts do if W.casts[i].id == 2649 then growls = growls + 1 end end
    local R = b.P.react
    local fails = R.memory.failures("Growl")
    assert(growls >= 2, string.format("Growl pressed %d time(s) in 14 s; failures %d; log:\n%s", growls, fails,
        table.concat(R.log_lines(20), "\n")))
    assert_eq(fails, 0, "no press read as unconfirmed")
    assert_eq(R.world.W.pet.target_guid, "Creature-0-1-2-3-3566-0001", "every pet rule sees the mob the pet was sent at")
    assert_eq(R.world.W.pet.target_inferred, true, "and knows it was inferred")
end }

T[#T + 1] = { "the log says, every 20 s of a fight, when each held pet skill was pressed or why it waits (1.73.1)", function()
    b.mock.frame(60 * 21)
    local log = table.concat(b.P.react.log_lines(40), "\n")
    assert(log:find("pet skills:", 1, true), "the line is written:\n" .. log)
    assert(log:find("Growl pressed", 1, true), "Growl pressed recently:\n" .. log)
    assert(log:find("Furious Howl waits: 1 of your group within 15 yd of the wolf", 1, true), "Furious Howl says why:\n" .. log)
end }
return T

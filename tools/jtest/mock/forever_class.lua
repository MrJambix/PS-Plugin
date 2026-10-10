-- Boots the whole plugin as the Forever client with a player of ONE class,
-- a level-20 spellbook and a hostile mob on top of them, turns the rotation
-- on, fights for a while and records every cast. One class per test file
-- (aio_forever_class_<key>_test.lua): the harness gives each file a fresh
-- Lua state, and the plugin boots once per state.
--
-- THE CLIENT IS FOREVER AS THE JCORE API RECORDER SAW IT:
--   * get_power / get_max_power answer 0 for every power type, always;
--   * get_pet answers nil, get_global_cooldown 0, get_name "" for units;
--   * get_spell_max_range answers 0 (no range data);
--   * get_shapeshift_form answers 0 (never seen answering there: the worst
--     case is assumed, so a druid or warrior must cope without it).
-- What DOES answer there answers truthfully here: is_usable_spell (from a
-- hidden resource pool: rage from swings, energy and mana regenerating, combo
-- points from the tooltips), get_spell_cooldown with the global cooldown in
-- it, get_spell_costs, the tooltips, auras with their expiry, and the cast
-- events (UNIT_SPELLCAST_SENT / _SUCCEEDED, "Not enough rage").
--
--   local sim = require("mock/forever_class")
--   local r = sim.run("warrior", 20)   -- seconds of fight
--   r.casts, r.count(name), r.distinct(), r.errors, r.forms

local boot = require("mock/aio_boot")
local Vec3 = require("mock/common/geometry/vector_3")

local M = {}

local MANA, RAGE, ENERGY = 0, 1, 3
local TYPE_OF = { MANA = MANA, RAGE = RAGE, ENERGY = ENERGY }

-- name, then: cost + type, cd (s), melee, self (cast on the player), buff /
-- debuff (seconds the aura lasts; 0 = until removed), form (a stance or a
-- shapeshift; toggle = casting it again leaves it), off (off the global
-- cooldown), usable = false (the client never calls it usable here: needs a
-- dodge, a shield, stealth, a low target...), desc (the tooltip), id.
local CLASSES = {
    warrior = { id = 1, power = "RAGE", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Battle Stance", form = true, off = true, self = true },
        { "Defensive Stance", form = true, off = true, self = true },
        { "Battle Shout", cost = 10, type = "RAGE", self = true, buff = 120 },
        { "Heroic Strike", cost = 15, type = "RAGE", melee = true, off = true },
        { "Rend", cost = 10, type = "RAGE", melee = true, debuff = 15 },
        { "Charge", cd = 15, off = true, usable = false },
        { "Thunder Clap", cost = 20, type = "RAGE", cd = 4, self = true, debuff = 10 },
        { "Hamstring", cost = 10, type = "RAGE", melee = true, debuff = 15 },
        { "Bloodrage", cd = 60, off = true, self = true, buff = 10, gives = 10 },
        { "Overpower", cost = 5, type = "RAGE", melee = true, cd = 5, usable = false },
        { "Demoralizing Shout", cost = 10, type = "RAGE", self = true, debuff = 30 },
        { "Sunder Armor", cost = 15, type = "RAGE", melee = true, debuff = 30, stacks = 5 },
        { "Taunt", cd = 10 },
        { "Execute", cost = 15, type = "RAGE", melee = true, usable = false },
        { "Cleave", cost = 20, type = "RAGE", melee = true, off = true },
        { "Shield Block", cost = 10, type = "RAGE", usable = false },
        { "Revenge", cost = 5, type = "RAGE", usable = false },
    } },
    rogue = { id = 4, power = "ENERGY", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Sinister Strike", id = 1752, cost = 45, type = "ENERGY", melee = true,
          desc = "An instant strike that causes damage. Awards 1 combo point." },
        { "Eviscerate", id = 2098, cost = 35, type = "ENERGY", melee = true, finisher = true,
          desc = "Finishing move that causes damage per combo point." },
        { "Slice and Dice", cost = 25, type = "ENERGY", self = true, finisher = true, buff = 15,
          desc = "Finishing move that increases melee attack speed by 20%." },
        { "Backstab", cost = 60, type = "ENERGY", melee = true, usable = false },
        { "Gouge", id = 1776, cost = 45, type = "ENERGY", melee = true, cd = 10, debuff = 4,
          desc = "Causes damage and incapacitates the opponent. Awards 1 combo point." },
        { "Stealth", id = 1784, cd = 10, self = true, usable = false },
        { "Evasion", cd = 300, self = true, buff = 15, off = true },
        { "Sprint", cd = 300, self = true, buff = 15, off = true },
        { "Kick", cost = 25, type = "ENERGY", melee = true, cd = 10, off = true },
        { "Rupture", cost = 25, type = "ENERGY", melee = true, finisher = true, debuff = 16,
          desc = "Finishing move that causes damage over time." },
    } },
    hunter = { id = 3, power = "MANA", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Auto Shot", id = 75, off = true },
        { "Raptor Strike", id = 2973, cost = 25, type = "MANA", melee = true, cd = 6, off = true },
        { "Arcane Shot", cost = 25, type = "MANA", cd = 6 },
        { "Serpent Sting", cost = 15, type = "MANA", debuff = 15 },
        { "Hunter's Mark", cost = 15, type = "MANA", debuff = 120 },
        { "Concussive Shot", cost = 20, type = "MANA", cd = 12, debuff = 4 },
        { "Aspect of the Monkey", self = true, buff = 0 },
        { "Aspect of the Hawk", cost = 20, type = "MANA", self = true, buff = 0 },
        { "Wing Clip", cost = 20, type = "MANA", melee = true, debuff = 10 },
        { "Mongoose Bite", cost = 30, type = "MANA", melee = true, usable = false },
        { "Mend Pet", cost = 40, type = "MANA", usable = false },
        { "Call Pet", self = true, usable = false },
        { "Revive Pet", cost = 100, type = "MANA", usable = false },
        { "Multi-Shot", cost = 60, type = "MANA", cd = 10 },
    } },
    mage = { id = 8, power = "MANA", spells = {
        { "Shoot", id = 5019, off = true },
        { "Fireball", cost = 65, type = "MANA", debuff = 8 },
        { "Frostbolt", cost = 50, type = "MANA", debuff = 7 },
        { "Fire Blast", cost = 75, type = "MANA", cd = 8 },
        { "Arcane Missiles", cost = 85, type = "MANA" },
        { "Frost Nova", cost = 55, type = "MANA", cd = 25, self = true, debuff = 8 },
        { "Arcane Explosion", cost = 75, type = "MANA", self = true },
        { "Polymorph", cost = 60, type = "MANA" },
        { "Counterspell", cost = 100, type = "MANA", cd = 30, off = true },
        { "Frost Armor", cost = 60, type = "MANA", self = true, buff = 1800 },
        { "Arcane Intellect", cost = 100, type = "MANA", self = true, buff = 1800 },
        { "Evocation", cd = 480, self = true },
    } },
    priest = { id = 5, power = "MANA", spells = {
        { "Shoot", id = 5019, off = true },
        { "Smite", cost = 60, type = "MANA" },
        { "Shadow Word: Pain", cost = 50, type = "MANA", debuff = 18 },
        { "Mind Blast", cost = 70, type = "MANA", cd = 8 },
        { "Power Word: Shield", cost = 80, type = "MANA", self = true, buff = 30 },
        { "Renew", cost = 60, type = "MANA", self = true, buff = 15 },
        { "Lesser Heal", cost = 45, type = "MANA", self = true },
        { "Heal", cost = 155, type = "MANA", self = true },
        { "Power Word: Fortitude", cost = 100, type = "MANA", self = true, buff = 1800 },
        { "Inner Fire", cost = 40, type = "MANA", self = true, buff = 600 },
        { "Fade", cd = 30, self = true, off = true },
        { "Psychic Scream", cost = 100, type = "MANA", cd = 30, self = true },
        { "Holy Fire", cost = 85, type = "MANA", debuff = 10 },
    } },
    paladin = { id = 2, power = "MANA", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Seal of Righteousness", cost = 40, type = "MANA", self = true, buff = 30 },
        { "Seal of the Crusader", cost = 40, type = "MANA", self = true, buff = 30 },
        { "Judgement", cost = 30, type = "MANA", cd = 10 },
        { "Holy Light", cost = 110, type = "MANA", self = true },
        { "Flash of Light", cost = 35, type = "MANA", self = true },
        { "Devotion Aura", self = true, buff = 0 },
        { "Retribution Aura", self = true, buff = 0 },
        { "Blessing of Might", cost = 45, type = "MANA", self = true, buff = 300 },
        { "Divine Protection", cost = 50, type = "MANA", cd = 300, self = true, buff = 8 },
        { "Hammer of Justice", cost = 50, type = "MANA", cd = 60, debuff = 4 },
        { "Lay on Hands", cd = 3600, self = true },
        { "Purify", cost = 50, type = "MANA", self = true },
    } },
    -- A level 9 paladin (1.76.1, the live report): no Flash of Light, no Lay
    -- on Hands. Forever's Holy Strike comes at 6 (1.77.1).
    paladin_level9 = { id = 2, power = "MANA", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Holy Strike", cost = 35, type = "MANA", melee = true, cd = 10 },
        { "Seal of Righteousness", cost = 40, type = "MANA", self = true, buff = 30 },
        { "Seal of the Crusader", cost = 40, type = "MANA", self = true, buff = 30 },
        { "Judgement", cost = 30, type = "MANA", cd = 10 },
        { "Holy Light", cost = 110, type = "MANA", self = true },
        { "Devotion Aura", self = true, buff = 0 },
        { "Blessing of Might", cost = 45, type = "MANA", self = true, buff = 300 },
        { "Divine Protection", cost = 50, type = "MANA", cd = 300, self = true, buff = 8 },
        { "Hammer of Justice", cost = 50, type = "MANA", cd = 60, debuff = 4 },
        { "Purify", cost = 50, type = "MANA", self = true },
    } },
    shaman = { id = 7, power = "MANA", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Lightning Bolt", cost = 50, type = "MANA" },
        { "Earth Shock", cost = 70, type = "MANA", cd = 6 },
        { "Flame Shock", cost = 75, type = "MANA", cd = 6, debuff = 12 },
        { "Lightning Shield", cost = 45, type = "MANA", self = true, buff = 600 },
        { "Rockbiter Weapon", cost = 40, type = "MANA", self = true },
        { "Searing Totem", cost = 50, type = "MANA", self = true },
        { "Stoneskin Totem", cost = 30, type = "MANA", self = true },
        { "Strength of Earth Totem", cost = 50, type = "MANA", self = true },
        { "Healing Wave", cost = 80, type = "MANA", self = true },
        { "Ghost Wolf", self = true, usable = false },
        { "Purge", cost = 60, type = "MANA" },
    } },
    warlock = { id = 9, power = "MANA", spells = {
        { "Shoot", id = 5019, off = true },
        { "Shadow Bolt", cost = 70, type = "MANA" },
        { "Immolate", cost = 70, type = "MANA", debuff = 15 },
        { "Corruption", cost = 55, type = "MANA", debuff = 18 },
        -- Forever's name for Curse of Agony (the same ids): a Bane, no curse (AIO 1.80.0).
        { "Bane of Agony", cost = 50, type = "MANA", debuff = 24 },
        { "Curse of Weakness", cost = 40, type = "MANA", debuff = 120 },
        { "Life Tap", self = true, off = false },
        { "Drain Life", cost = 85, type = "MANA" },
        { "Drain Soul", cost = 55, type = "MANA" },
        { "Fear", cost = 40, type = "MANA" },
        { "Demon Skin", cost = 50, type = "MANA", self = true, buff = 1800 },
        { "Summon Imp", cost = 60, type = "MANA", self = true },
        { "Health Funnel", cost = 50, type = "MANA", usable = false },
    } },
    druid = { id = 11, power = "MANA", spells = {
        { "Attack", id = 6603, melee = true, off = true },
        { "Wrath", cost = 45, type = "MANA" },
        { "Moonfire", cost = 60, type = "MANA", debuff = 12 },
        { "Healing Touch", cost = 110, type = "MANA", self = true },
        { "Rejuvenation", cost = 60, type = "MANA", self = true, buff = 12 },
        { "Regrowth", cost = 120, type = "MANA", self = true, buff = 21 },
        { "Mark of the Wild", cost = 80, type = "MANA", self = true, buff = 1800 },
        { "Thorns", cost = 50, type = "MANA", self = true, buff = 600 },
        { "Entangling Roots", cost = 50, type = "MANA", debuff = 12 },
        { "Bear Form", cost = 100, type = "MANA", form = true, toggle = true, self = true, pool = "RAGE" },
        { "Cat Form", cost = 100, type = "MANA", form = true, toggle = true, self = true, pool = "ENERGY" },
        { "Travel Form", cost = 50, type = "MANA", form = true, toggle = true, self = true },
        { "Demoralizing Roar", cost = 10, type = "RAGE", self = true, debuff = 30, needs = "Bear Form" },
        { "Growl", cd = 10, needs = "Bear Form" },
        { "Maul", cost = 15, type = "RAGE", melee = true, off = true, needs = "Bear Form" },
        { "Enrage", cd = 60, self = true, gives = 20, needs = "Bear Form" },
        { "Bash", cost = 10, type = "RAGE", melee = true, cd = 60, needs = "Bear Form" },
        { "Claw", cost = 45, type = "ENERGY", melee = true, needs = "Cat Form",
          desc = "Claw the enemy, causing damage. Awards 1 combo point." },
        { "Rake", cost = 40, type = "ENERGY", melee = true, debuff = 9, needs = "Cat Form",
          desc = "Rake the target for damage over time. Awards 1 combo point." },
    } },
}
M.CLASSES = CLASSES

local function methods_of(fields)
    local methods = {}
    for k, v in pairs(fields) do
        if type(v) == "function" then methods[k] = v else methods[k] = function() return v end end
    end
    local none = function() return nil end
    return setmetatable({}, { __index = function(_, k) return methods[k] or none end }), methods
end

--- Boots, fights for `seconds` and answers what happened.
---@param key string a CLASSES key
---@param seconds number
---@param setup? fun(sim) extra setup after boot, before the fight
---@param distance? number yards from the player to the mob (3: melee)
---@param with_pet? boolean a pet beside the player that get_pet does NOT name
--- (as on Forever): only is_pet and get_owner say whose it is
function M.run(key, seconds, setup, distance, with_pet)
    local class = assert(CLASSES[key], "no class " .. tostring(key))
    local mock_ref
    local t0 = nil
    local function game_ms() return math.floor((mock_ref.time) * 1000) end

    -- The spellbook.
    local by_id, by_name, ids = {}, {}, {}
    local next_id = 900000
    for i = 1, #class.spells do
        local s = class.spells[i]
        local id = s.id
        if not id then
            next_id = next_id + 1
            id = next_id
        end
        s.id = id
        s.name = s[1]
        by_id[id] = s
        by_name[s.name] = s
        ids[#ids + 1] = id
    end

    -- The hidden truth the client's usable answers come from.
    local pools = { MANA = 1000, RAGE = 0, ENERGY = 100, COMBO = 0 }
    local POOL_MAX = { MANA = 1000, RAGE = 100, ENERGY = 100, COMBO = 5 }
    local form = nil                        -- the form spell in effect, or nil
    local cd_until, gcd_until = {}, 0
    local player_auras, mob_auras = {}, {}  -- buff_id -> aura row
    local casts, refused, queued = {}, {}, {}
    local forms_cast = 0
    local swing_at, regen_at = 0, nil
    -- The melee swing. By default it runs from the pull, as if the player had
    -- attacked; sim.swing_off() leaves it off until a START (6603) arrives,
    -- and only a running swing hits.
    local swing_manual, swinging = false, false

    local me, mob
    local mob_hp = 1000

    local function aura(list, spell, seconds_, caster)
        local before = list[spell.id]
        local count = 1
        if spell.stacks and before then count = math.min(spell.stacks, (before.count or 1) + 1) end
        list[spell.id] = {
            buff_id = spell.id, buff_name = spell.name, count = count, stacks = count,
            expire_time = (seconds_ and seconds_ > 0) and (game_ms() + seconds_ * 1000) or 0,
            caster = caster,
        }
    end

    local function sweep_auras(list)
        local now = game_ms()
        for id, a in pairs(list) do
            if a.expire_time > 0 and a.expire_time <= now then list[id] = nil end
        end
    end

    local function aura_rows(list)
        sweep_auras(list)
        local out = {}
        for _, a in pairs(list) do out[#out + 1] = a end
        return out
    end

    local function pool_for(spell)
        return spell.type
    end

    local function usable(spell)
        if not spell or spell.usable == false then return false end
        if spell.needs and (not form or form.name ~= spell.needs) then return false end
        if spell.finisher and pools.COMBO < 1 then return false end
        local cost_type = pool_for(spell)
        if cost_type and (spell.cost or 0) > (pools[cost_type] or 0) then return false end
        return true
    end

    local function cooldown_of(spell)
        local now = mock_ref.time
        local left = math.max(0, (cd_until[spell.id] or 0) - now)
        if not spell.off then left = math.max(left, gcd_until - now) end
        return left
    end

    local function queue(name, args) queued[#queued + 1] = { name, args } end

    local function cast(id, target)
        local spell = by_id[id]
        local now = mock_ref.time
        if not spell then return false end
        if cooldown_of(spell) > 0 then return false end
        if not usable(spell) then
            refused[#refused + 1] = spell.name
            local cost_type = pool_for(spell)
            if cost_type and (spell.cost or 0) > (pools[cost_type] or 0) then
                queue("UI_ERROR_MESSAGE", { 52, "Not enough " .. cost_type:lower(), "ERR_OUT_OF_" .. cost_type })
            end
            return false
        end
        casts[#casts + 1] = { t = now - (t0 or now), name = spell.name, id = id }
        local cost_type = pool_for(spell)
        if cost_type then pools[cost_type] = pools[cost_type] - (spell.cost or 0) end
        if spell.gives then pools.RAGE = math.min(POOL_MAX.RAGE, pools.RAGE + spell.gives) end
        if spell.cd then cd_until[id] = now + spell.cd end
        if not spell.off then gcd_until = now + 1.5 end
        if spell.desc then
            local n = spell.desc:lower():match("awards (%d+) combo point")
            if n then pools.COMBO = math.min(POOL_MAX.COMBO, pools.COMBO + tonumber(n)) end
        end
        if spell.finisher then pools.COMBO = 0 end
        if spell.form then
            forms_cast = forms_cast + 1
            if form == spell and spell.toggle then
                player_auras[spell.id] = nil
                form = nil
            elseif form ~= spell then
                if form then player_auras[form.id] = nil end
                form = spell
                aura(player_auras, spell, 0, me)
                if spell.pool == "RAGE" then pools.RAGE = 0 end
                if spell.pool == "ENERGY" then pools.ENERGY = 0 end
            end
        end
        if spell.buff then aura(player_auras, spell, spell.buff, me) end
        if spell.debuff then aura(mob_auras, spell, spell.debuff, me) end
        mob_hp = math.max(1, mob_hp - 8)
        local on = (spell.self or target == me) and "" or "Mob"
        queue("UNIT_SPELLCAST_SENT", { "player", on, "Cast-3-0-0-0-" .. id .. "-0001", id })
        queue("UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-3-0-0-0-" .. id .. "-0001", id })
        return true
    end

    local player_fields = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-4619-0AAAAAAA",
        get_name = "", get_class = class.id, get_race_id = 0, get_level = 20,
        get_health = 900, get_max_health = 1000, get_power = 0, get_max_power = 0,
        is_moving = false, is_mounted = false, is_casting_spell = false,
        is_channelling_spell = false, can_attack = true, is_enemy_with = false,
        get_rotation = 0, get_direction = { x = 1, y = 0, z = 0 }, get_classification = 0,
        get_attack_speed = 2.0, get_loss_of_control_info = { valid = false },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6, get_combat_reach = 1.5,
        get_bounding_radius = 0.5, get_height = 2, is_party_member = false,
        get_position = function() return Vec3.new(100, 100, 0) end,
        get_auras = function() return aura_rows(player_auras) end,
        get_buffs = function() return aura_rows(player_auras) end,
        get_debuffs = function() return {} end,
        is_in_combat = function() return t0 ~= nil end,
        is_auto_attacking = function()
            if swing_manual then return swinging end
            return t0 ~= nil
        end,
        get_target = function() return mob end,
        get_pet = function() return nil end,
    }
    me = methods_of(player_fields)

    local mob_fields = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Creature-0-4619-2991-1-250873-0000ABCDEF",
        get_name = "", get_class = 1, get_level = 20, get_npc_id = 250873, get_creature_type = 1,
        get_max_health = 1000, get_power = 0, get_max_power = 0,
        is_moving = false, is_mounted = false, is_casting_spell = false, is_channelling_spell = false,
        can_attack = true, is_enemy_with = true, get_classification = 0, get_rotation = math.pi,
        get_loss_of_control_info = { valid = false }, is_player = false, is_unit = true, get_type = 5,
        get_combat_reach = 1.5, get_bounding_radius = 0.6, get_height = 1.5, is_party_member = false,
        is_pet = false, is_minion = false, is_tap_denied = false, get_threat_situation = 3,
        get_position = function() return Vec3.new(100 + (distance or 3), 100, 0) end,
        get_health = function() return mob_hp end,
        get_auras = function() return aura_rows(mob_auras) end,
        get_buffs = function() return {} end,
        get_debuffs = function() return aura_rows(mob_auras) end,
        is_in_combat = function() return t0 ~= nil end,
        get_target = function() return me end,
        get_attack_speed = 2.0,
    }
    mob = methods_of(mob_fields)

    local pet = nil
    local pet_orders = 0
    if with_pet then
        pet = methods_of({
            is_valid = true, is_dead = false, get_guid = "Pet-0-4619-2991-1-416-0000PETPET",
            get_name = "", get_level = 20, get_npc_id = 416, get_creature_type = 1,
            get_health = 500, get_max_health = 500, get_power = 0, get_max_power = 0,
            is_moving = false, can_attack = false, is_enemy_with = false, is_player = false,
            is_unit = true, get_type = 5, get_combat_reach = 1, get_bounding_radius = 0.5,
            get_height = 1, is_pet = true, is_minion = true, get_classification = 0,
            get_loss_of_control_info = { valid = false },
            get_position = function() return Vec3.new(101, 101, 0) end,
            get_auras = function() return {} end, get_buffs = function() return {} end,
            get_debuffs = function() return {} end,
            is_in_combat = function() return t0 ~= nil end,
            get_target = function() return t0 and mob or nil end,
            get_owner = function() return me end,
        })
    end

    local b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        mock_ref = mock
        -- The loader's queue and auto-attack helper, which JCore's cast
        -- gateway sends through: here a request goes straight to the client.
        package.loaded["common/modules/spell_queue"] = {
            queue_spell_target = function(_, id, target) return cast(id, target) end,
            queue_spell_target_fast = function(_, id, target) return cast(id, target) end,
            queue_spell_position = function(_, id) return cast(id, mob) end,
            queue_spell_position_fast = function(_, id) return cast(id, mob) end,
            queue_item_target = function() return true end,
            queue_item_target_fast = function() return true end,
            queue_item_position = function() return true end,
            purge_by_spell = function() end,
        }
        package.loaded["common/utility/auto_attack_helper"] = {
            is_spell_auto_attack = function(_, id) return id == 6603 or id == 75 or id == 5019 end,
            start_attack = function(_, _, id)
                if id == 6603 and swing_manual then
                    -- A START on a running swing does nothing, as the client's.
                    if swinging then return true end
                    swinging = true
                end
                return cast(id, mob)
            end,
        }
        local c = mock.core
        rawset(c.object_manager, "get_local_player", function() return me end)
        local everyone = pet and { me, mob, pet } or { me, mob }
        rawset(c.object_manager, "get_visible_objects", function() return everyone end)
        rawset(c.object_manager, "get_all_objects", function() return everyone end)
        rawset(c.object_manager, "get_object_from_guid", function(guid)
            if guid == me:get_guid() then return me end
            if guid == mob:get_guid() then return mob end
            if pet and guid == pet:get_guid() then return pet end
            return nil
        end)
        local sb = c.spell_book
        rawset(sb, "get_spells", function() return ids end)
        rawset(sb, "get_spell_name", function(id) return by_id[id] and by_id[id].name or "" end)
        rawset(sb, "is_spell_known", function(id) return by_id[id] ~= nil end)
        rawset(sb, "has_spell", function(id) return by_id[id] ~= nil end)
        rawset(sb, "is_usable_spell", function(id) return usable(by_id[id]) end)
        rawset(sb, "get_spell_cooldown", function(id)
            local s = by_id[id]
            return s and cooldown_of(s) or 0
        end)
        rawset(sb, "get_spell_base_cooldown", function(id)
            local s = by_id[id]
            if not s then return nil end
            return { cooldown_ms = (s.cd or 0) * 1000, gcd_ms = s.off and 0 or 1500 }
        end)
        rawset(sb, "get_global_cooldown", function() return 0 end)
        rawset(sb, "get_spell_costs", function(id)
            local s = by_id[id]
            if not s or not s.cost then return {} end
            return { { cost = s.cost, min_cost = s.cost, cost_type = TYPE_OF[s.type], cost_percent = 0 } }
        end)
        rawset(sb, "get_spell_description", function(id) return by_id[id] and by_id[id].desc or "" end)
        rawset(sb, "get_spell_max_range", function() return 0 end)
        rawset(sb, "get_spell_min_range", function() return 0 end)
        rawset(sb, "is_melee_spell", function(id) return by_id[id] and by_id[id].melee == true or false end)
        rawset(sb, "get_spell_cast_time", function() return 0 end)
        rawset(sb, "get_base_power_regen", function() return 10 end)
        rawset(sb, "get_shapeshift_form", function() return 0 end)
        rawset(sb, "get_shapeshift_form_id", function() return 0 end)
        rawset(sb, "get_spell_charge", function() return 0 end)
        rawset(sb, "get_spell_charge_max", function() return 0 end)
        rawset(c.graphics, "is_line_of_sight", function() return true end)
        rawset(c.input, "cast_target_spell", function(id, target) return cast(id, target) end)
        rawset(c.input, "cast_position_spell", function(id) return cast(id, mob) end)
        rawset(c.input, "pet_attack", function() pet_orders = pet_orders + 1 return true end)
    end)

    local function set(page, id, value)
        b.mock.menu:set("Jambix AIO/" .. page, id, value)
        b.P.opt_invalidate()
    end
    set("Rotation", "rot_enabled", true)
    set("Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })

    local sim = { b = b, me = me, mob = mob, pools = pools, set = set, spells = by_name }
    function sim.swing_off() swing_manual = true end
    --- Starts in a form, as if the player had shifted before the pull (1.7.5).
    function sim.enter_form(name)
        local spell = assert(by_name[name], "no form " .. tostring(name))
        if form then player_auras[form.id] = nil end
        form = spell
        aura(player_auras, spell, 0, me)
    end
    if setup then setup(sim) end

    -- A few quiet frames to settle, then the pull.
    b.mock.frame(30)
    t0 = b.mock.time
    swing_at = t0
    regen_at = t0
    local frames = math.floor(seconds / b.mock.frame_dt)
    for _ = 1, frames do
        local now = b.mock.time
        -- The hidden pools move as the real client's would.
        local dt = now - regen_at
        regen_at = now
        pools.ENERGY = math.min(POOL_MAX.ENERGY, pools.ENERGY + 10 * dt)
        pools.MANA = math.min(POOL_MAX.MANA, pools.MANA + 4 * dt)
        if now - swing_at >= 2.0 then
            swing_at = now
            if swinging or not swing_manual then
                pools.RAGE = math.min(POOL_MAX.RAGE, pools.RAGE + 9)
                mob_hp = math.max(1, mob_hp - 10)
            end
        end
        b.mock.frame(1)
        local events = queued
        queued = {}
        for i = 1, #events do b.mock.game_event(events[i][1], events[i][2]) end
    end

    local result = { casts = casts, refused = refused, forms = forms_cast, b = b, form = form and form.name,
        swinging = swinging, mob_hp = mob_hp,
        pet_orders = pet_orders, pet_seen = pet ~= nil and b.P.pet ~= nil and b.P.pet.alive() }
    function result.count(name)
        local n = 0
        for i = 1, #casts do if casts[i].name == name then n = n + 1 end end
        return n
    end
    --- Distinct spells pressed, leaving out the auto attacks.
    function result.distinct()
        local seen, list = {}, {}
        for i = 1, #casts do
            local n = casts[i].name
            if not seen[n] and n ~= "Attack" and n ~= "Auto Shot" and n ~= "Shoot" then
                seen[n] = true
                list[#list + 1] = n
            end
        end
        table.sort(list)
        return list
    end
    function result.summary()
        local counts = {}
        for i = 1, #casts do counts[casts[i].name] = (counts[casts[i].name] or 0) + 1 end
        local parts = {}
        for name, n in pairs(counts) do parts[#parts + 1] = name .. " x" .. n end
        table.sort(parts)
        return table.concat(parts, ", ")
    end
    result.errors = b.errors()
    return result
end

--- The shared test: fights, prints what was cast, and fails on an error, on
--- fewer distinct abilities than `min`, on a form flipped back and forth,
--- or on one of `must` never pressed.
---@param key string
---@param opts? { seconds?: number, min?: number, must?: string[], max_forms?: number, setup?: function, distance?: number, pet?: boolean }
function M.check(key, opts)
    opts = opts or {}
    local r = M.run(key, opts.seconds or 24, opts.setup, opts.distance, opts.pet)
    local distinct = r.distinct()
    print(string.format("    %s: %d casts, %d distinct [%s]; forms cast %d; refused %d", key, #r.casts, #distinct,
        r.summary(), r.forms, #r.refused))
    if r.errors ~= "" then error(key .. ": core.log_error while fighting: " .. r.errors, 2) end
    if #distinct < (opts.min or 3) then
        error(string.format("%s: only %d distinct abilities pressed: %s", key, #distinct, table.concat(distinct, ", ")), 2)
    end
    for _, name in ipairs(opts.must or {}) do
        if r.count(name) == 0 then error(key .. ": never pressed " .. name .. " (" .. r.summary() .. ")", 2) end
    end
    if opts.pet then
        print(string.format("    %s: pet seen %s, sent %d time(s)", key, tostring(r.pet_seen), r.pet_orders))
        if not r.pet_seen then error(key .. ": the pet get_pet does not name was not found", 2) end
        if r.pet_orders < 1 then error(key .. ": the pet was never sent at the target", 2) end
    end
    if r.forms > (opts.max_forms or 2) then
        error(string.format("%s: a form was cast %d times in one fight (flipping in and out)", key, r.forms), 2)
    end
    return r
end

return M

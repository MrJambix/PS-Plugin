-- Jambix AIO / rewards -- which quest reward to take (1.7.4).
--
-- Moved here from modules/forever_npc.lua, unchanged, so the quest givers on
-- Forever (forever_npc.lua) and the guide walk on every client
-- (guidewalk.lua) choose the same way: gear the class can use, of the armour
-- it should wear, not below what is worn, wins; else the choice that sells for
-- the most. Pure: nothing here reads the game except through `who`.

-- --- the classes' kit (classic rules) ----------------------------------------

local WEAPON, ARMOR = 2, 4

-- Armour subclasses. 1 to 4 are in order of weight, which the fit test uses.
local CLOTH, LEATHER, MAIL, PLATE, SHIELD = 1, 2, 3, 4, 6
local ARMOR_NAMES = { Cloth = CLOTH, Leather = LEATHER, Mail = MAIL, Plate = PLATE, Shields = SHIELD }
local KIND_NAME = { [CLOTH] = "cloth", [LEATHER] = "leather", [MAIL] = "mail", [PLATE] = "plate" }

-- Weapon subclasses.
local AXE1, AXE2, BOW, GUN, MACE1, MACE2, POLEARM, SWORD1, SWORD2 = 0, 1, 2, 3, 4, 5, 6, 7, 8
local STAFF, FIST, DAGGER, THROWN, CROSSBOW, WAND = 10, 13, 15, 16, 18, 19

local TWO_HANDED = { [AXE2] = true, [MACE2] = true, [POLEARM] = true, [SWORD2] = true, [STAFF] = true }
local SHOOTER = { [BOW] = true, [GUN] = true, [CROSSBOW] = true }

-- Relics: libram, idol, totem.
local RELIC_CLASS = { [7] = "PALADIN", [8] = "DRUID", [9] = "SHAMAN" }

local function set(list)
    local out = {}
    for i = 1, #list do out[list[i]] = true end
    return out
end

-- What each class may use, and the armour it should be wearing: `light`
-- before level 40, `heavy` from 40 (mail for hunters and shamans, plate for
-- warriors and paladins).
local KIT = {
    WARRIOR = { light = MAIL, heavy = PLATE, shield = true,
        weapons = set({ AXE1, AXE2, BOW, GUN, MACE1, MACE2, POLEARM, SWORD1, SWORD2, STAFF, FIST, DAGGER,
            THROWN, CROSSBOW }) },
    PALADIN = { light = MAIL, heavy = PLATE, shield = true,
        weapons = set({ AXE1, AXE2, MACE1, MACE2, POLEARM, SWORD1, SWORD2 }) },
    HUNTER = { light = LEATHER, heavy = MAIL,
        weapons = set({ AXE1, AXE2, BOW, GUN, POLEARM, SWORD1, SWORD2, STAFF, FIST, DAGGER, THROWN, CROSSBOW }) },
    ROGUE = { light = LEATHER, heavy = LEATHER,
        weapons = set({ BOW, GUN, MACE1, SWORD1, FIST, DAGGER, THROWN, CROSSBOW }) },
    PRIEST = { light = CLOTH, heavy = CLOTH, weapons = set({ MACE1, STAFF, DAGGER, WAND }) },
    SHAMAN = { light = LEATHER, heavy = MAIL, shield = true,
        weapons = set({ AXE1, AXE2, MACE1, MACE2, STAFF, FIST, DAGGER }) },
    MAGE = { light = CLOTH, heavy = CLOTH, weapons = set({ SWORD1, STAFF, DAGGER, WAND }) },
    WARLOCK = { light = CLOTH, heavy = CLOTH, weapons = set({ SWORD1, STAFF, DAGGER, WAND }) },
    DRUID = { light = LEATHER, heavy = LEATHER, weapons = set({ MACE1, MACE2, STAFF, FIST, DAGGER }) },
}

-- equip_loc -> the worn slots it would replace (INVSLOT ids).
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local SLOT_NAME = {
    INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulders", INVTYPE_CHEST = "chest",
    INVTYPE_ROBE = "chest", INVTYPE_WAIST = "waist", INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet",
    INVTYPE_WRIST = "wrists", INVTYPE_HAND = "hands", INVTYPE_FINGER = "ring", INVTYPE_TRINKET = "trinket",
    INVTYPE_CLOAK = "back", INVTYPE_WEAPON = "one-hand", INVTYPE_2HWEAPON = "two-hand",
    INVTYPE_WEAPONMAINHAND = "main hand", INVTYPE_WEAPONOFFHAND = "off hand", INVTYPE_SHIELD = "shield",
    INVTYPE_HOLDABLE = "held in off hand", INVTYPE_RANGED = "ranged", INVTYPE_RANGEDRIGHT = "ranged",
    INVTYPE_THROWN = "thrown", INVTYPE_RELIC = "relic",
}

--- Who the character is, as far as gear goes: tank, healer, caster, ranged
--- or melee, from the class and the profile its talents chose.
local function role_of(class, profile)
    profile = profile or ""
    if profile:find("tank", 1, true) or profile == "protection" or profile == "feral_bear" then return "tank" end
    if profile == "holy" or profile == "discipline" or profile == "restoration" then return "healer" end
    if class == "MAGE" or class == "WARLOCK" or class == "PRIEST" then return "caster" end
    if profile == "balance" or profile == "elemental" then return "caster" end
    if class == "HUNTER" then return "ranged" end
    return "melee"
end

--- A small push between weapons the class can use: tanks want one hand and a
--- shield, casters a staff, a hunter a bow or gun, melee a two-hander.
local function weapon_bias(role, class, loc, sub)
    if sub == WAND then return (role == "caster" or role == "healer") and 40 or 0 end
    if SHOOTER[sub] or sub == THROWN then
        if class == "HUNTER" then return SHOOTER[sub] and 120 or 0 end
        return -20
    end
    local two = TWO_HANDED[sub] or loc == "INVTYPE_2HWEAPON"
    if role == "tank" then return two and -80 or 40 end
    if role == "caster" or role == "healer" then
        if sub == STAFF then return 40 end
        return two and -40 or 0
    end
    if role == "ranged" then return two and 30 or 0 end
    if class == "ROGUE" then return (sub == DAGGER or sub == SWORD1) and 30 or 0 end
    return two and 60 or 0
end

--- How an item fits this character, or nil and why not.
---
--- Fits: gear the class can use, of the armour it should be wearing, that is
--- not below what is worn in that slot. The item's stats are not readable
--- from a quest window (no core call answers stats for a link), so beyond
--- that the score goes on item level over the worn piece, an empty slot,
--- quality, and the role's weapon.
---@param info table core.quests.get_item_info's answer
---@param who { class: string, level: number, role: string, worn?: fun(slot: integer): number|nil }
---@return number|nil score
---@return string note
local function fit(info, who)
    if type(info) ~= "table" then return nil, "no item data" end
    local loc = info.equip_loc
    local slots = SLOTS[loc]
    if not slots then return nil, "not gear" end
    local kit = KIT[who.class or ""]
    if not kit then return nil, "class unknown" end

    local cls, sub = tonumber(info.class_id), tonumber(info.subclass_id)
    if cls == nil and ARMOR_NAMES[info.item_sub_type or ""] then
        cls, sub = ARMOR, ARMOR_NAMES[info.item_sub_type]
    end

    local score = 1000
    local what = SLOT_NAME[loc] or "gear"
    local role = who.role
    if loc == "INVTYPE_HOLDABLE" then
        if role ~= "caster" and role ~= "healer" then return nil, "an off-hand for casters" end
        score = score + 30
    elseif loc == "INVTYPE_RELIC" then
        if RELIC_CLASS[sub] ~= who.class then return nil, "another class's relic" end
    elseif cls == WEAPON then
        if sub and not kit.weapons[sub] then return nil, "a weapon this class cannot use" end
        score = score + weapon_bias(role, who.class, loc, sub)
    elseif cls == ARMOR then
        if sub == SHIELD or loc == "INVTYPE_SHIELD" then
            if not kit.shield then return nil, "a shield" end
            score = score + ((role == "tank" and 80) or (role == "healer" and 40) or (role == "caster" and 20) or -60)
        elseif sub and sub >= CLOTH and sub <= PLATE and loc ~= "INVTYPE_CLOAK" then
            local best = (tonumber(who.level) or 0) >= 40 and kit.heavy or kit.light
            if sub > best then return nil, KIND_NAME[sub] .. ", too heavy to wear" end
            if sub < best then return nil, KIND_NAME[sub] .. ", lighter than " .. KIND_NAME[best] end
            what = KIND_NAME[sub] .. " " .. what
        end
    end

    -- Against what is worn there: the weaker of two rings or trinkets.
    local ilvl = tonumber(info.item_level) or 0
    local worn, empty, unknown = nil, false, false
    if who.worn then
        for i = 1, #slots do
            local level = who.worn(slots[i])
            if level == nil then
                unknown = true
            elseif level <= 0 then
                empty = true
            elseif not worn or level < worn then
                worn = level
            end
        end
    else
        unknown = true
    end

    local note
    if empty then
        score = score + 100
        note = string.format("%s, item level %d, slot empty", what, ilvl)
    elseif worn then
        local delta = ilvl - worn
        if delta < 0 then
            return nil, string.format("%s, item level %d below the %d worn", what, ilvl, worn)
        end
        score = score + math.min(240, delta * 12)
        note = string.format("%s, item level %d over %d worn", what, ilvl, worn)
    else
        note = string.format("%s, item level %d%s", what, ilvl, unknown and " (worn unread)" or "")
    end

    score = score + (tonumber(info.quality) or 1) * 10
    if (tonumber(info.min_level) or 0) > (tonumber(who.level) or 0) then score = score - 80 end
    return score, note
end

--- The reward to take, from the choices a quest offers.
---
--- Gear that fits (see fit) wins, the best score first. When nothing fits,
--- the choice that sells for the most. Item data that never came is treated
--- as nothing: such a choice can only win when every choice lacks it, and
--- then the first is taken.
---@param choices { index: integer, link: string, info: table|nil }[]
---@param who table see fit
---@return integer index
---@return string why
local function pick_reward(choices, who)
    local best, best_score, best_note = nil, nil, nil
    for i = 1, #choices do
        local c = choices[i]
        local score, note = fit(c.info, who)
        c.score, c.note = score, note
        if score then
            local price = tonumber(c.info.sell_price) or 0
            local best_price = best and (tonumber(best.info.sell_price) or 0) or -1
            if not best or score > best_score or (score == best_score and price > best_price) then
                best, best_score, best_note = c, score, note
            end
        end
    end
    local function name(c) return (c.info and c.info.name) or ("choice " .. c.index) end
    if best then
        return best.index, string.format("took %s (%s) for a %s %s, out of %d",
            name(best), best_note, string.lower(who.class or "?"), who.role or "?", #choices)
    end

    local richest, richest_price = choices[1], -1
    for i = 1, #choices do
        local price = choices[i].info and tonumber(choices[i].info.sell_price) or 0
        if price > richest_price then richest, richest_price = choices[i], price end
    end
    if richest_price <= 0 then
        return richest.index, string.format("took %s: nothing fits a %s %s and none sells, so the first, out of %d",
            name(richest), string.lower(who.class or "?"), who.role or "?", #choices)
    end
    return richest.index, string.format("took %s: nothing fits a %s %s, it sells for the most (%dc), out of %d",
        name(richest), string.lower(who.class or "?"), who.role or "?", richest_price, #choices)
end

--- Who the character is, for pick_reward: class, level, the profile its
--- talents chose, the role that makes, and the item level worn in a slot.
---@param P table the AIO's bundle (units, rotation)
---@param item_info fun(key: integer|string): table|nil core.quests.get_item_info, cached by the caller
---@return { class: string|nil, level: number, profile: string, role: string, worn: fun(slot: integer): number|nil }
local function who(P, item_info)
    local units = P.units
    local player = units and units.player and units.player() or nil
    local level = 0
    if player then
        local ok, l = pcall(player.get_level, player)
        if ok and type(l) == "number" then level = l end
    end
    local rot = P.rotation
    local class, profile = nil, ""
    if rot and rot.detect_class then
        local ok, c = pcall(rot.detect_class)
        if ok then class = c end
    end
    if rot and rot.active_class and rot.active_profile_key then
        local ok, key = pcall(function()
            local module = rot.active_class()
            return module and rot.active_profile_key(module) or nil
        end)
        if ok and key then profile = tostring(key) end
    end

    --- The item level worn in a slot: 0 for an empty slot, nil when it
    --- cannot be read.
    local function worn(slot)
        if not player then return nil end
        local ok, row = pcall(player.get_item_at_inventory_slot, player, slot)
        if not ok or type(row) ~= "table" then return nil end
        local obj = row.object
        if not obj then return 0 end
        local ok_id, id = pcall(obj.get_item_id, obj)
        if not ok_id or type(id) ~= "number" or id <= 0 then return nil end
        local info = item_info(id)
        return info and tonumber(info.item_level) or nil
    end

    return { class = class, level = level, profile = profile, role = role_of(class, profile), worn = worn }
end

return { fit = fit, pick_reward = pick_reward, role_of = role_of, who = who }

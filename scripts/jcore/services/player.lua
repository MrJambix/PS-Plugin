-- JCore / player -- everything about the local player, asked once per tick.
--
-- Depends on: util, log, cache, units.
--
-- The local player is the single most interrogated object in any rotation. A
-- priority list checks health, then power, then whether it is moving, then
-- whether it is already casting, and it does that for every entry it walks.
-- Each of those is a native round trip on a fresh call.
--
-- Every reader here is memoised for the tick. The first caller in a frame pays
-- the native cost; every caller after it reads a number out of a table. A
-- rotation with forty checks against the player drops to at most one call per
-- distinct fact per frame.
--
-- Nothing here has a side effect. Actions live in services/input.lua, so a
-- priority list can be evaluated end to end with no risk of moving the
-- character halfway down it.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local units = rt.units
    local log = rt.log.for_tag("JCore/player")

    local try = cache.try
    local try_bool = cache.try_bool

    local M = {}

    local tick = cache.new("player.tick", { scope = "tick" })
    -- Class, race and realm do not change while the character is logged in.
    -- Specialisation does, so it is NOT in here -- see M.spec_id.
    local session = cache.new("player.session", { scope = "manual" })

    -- --- power types --------------------------------------------------------

    -- Read from the shipped enums when present. The fallback is the client's
    -- own numbering, which these constants have used unchanged for years; a
    -- build without common/enums should still be able to ask for mana rather
    -- than having to know that mana is nought.
    local POWER = {
        HEALTH = -2, NONE = -1, MANA = 0, RAGE = 1, FOCUS = 2, ENERGY = 3,
        COMBOPOINTS = 4, RUNES = 5, RUNICPOWER = 6, SOULSHARDS = 7,
        LUNARPOWER = 8, HOLYPOWER = 9, ALTERNATE = 10, MAELSTROM = 11,
        CHI = 12, INSANITY = 13, ARCANECHARGES = 16, FURY = 17, PAIN = 18,
        ESSENCE = 19,
    }

    do
        local ok, enums = pcall(require, "common/enums")
        if ok and enums and type(enums.power_type) == "table" then
            for name, value in pairs(enums.power_type) do
                if type(value) == "number" then POWER[name] = value end
            end
            M.enums = enums
        else
            log.debug("common/enums unavailable; using built-in power constants")
        end
    end

    M.POWER = POWER

    -- --- identity -----------------------------------------------------------

    ---@return game_object|nil
    function M.object() return units.player() end

    --- True when there is a player to ask about at all. False through a
    --- loading screen, at character select and during a world transition --
    --- which is when every other reader below answers its zero value.
    ---@return boolean
    function M.exists()
        local p = units.player()
        return p ~= nil and p:is_valid()
    end

    --- Memoised read of a player method, by field name.
    local function ask(field, getter, fallback)
        local value, hit = tick:get(field)
        if hit then
            if value == nil then return fallback end
            return value
        end

        local p = units.player()
        if not p then
            tick:put(field, nil)
            return fallback
        end

        local result = try(getter, p)
        tick:put(field, result)
        if result == nil then return fallback end
        return result
    end

    ---@return string
    function M.name()
        local p = units.player()
        if not p then return "" end
        return units.name(p)
    end

    ---@return string|nil
    function M.guid()
        local p = units.player()
        if not p then return nil end
        return units.guid(p)
    end

    ---@return vec3|nil
    function M.position()
        return units.player_position()
    end

    ---@return integer
    function M.class_id()
        local value, hit = session:get("class")
        if hit then return value or 0 end
        local p = units.player()
        if not p then return 0 end
        return session:put("class", try(p.get_class, p) or 0)
    end

    ---@return integer
    function M.race_id()
        local value, hit = session:get("race")
        if hit then return value or 0 end
        local p = units.player()
        if not p then return 0 end
        return session:put("race", try(p.get_race_id, p) or 0)
    end

    --- Current specialisation. Deliberately tick-scoped rather than session-
    --- scoped: a spec change mid-session is ordinary, and a rotation that
    --- cached it at login would keep running the wrong priority list.
    ---@return integer
    function M.spec_id()
        return ask("spec", function(p) return p:get_specialization_id() end, 0)
    end

    ---@return integer
    function M.level()
        return ask("level", function(p) return p:get_level() end, 0)
    end

    ---@return number
    function M.rotation()
        return ask("rotation", function(p) return p:get_rotation() end, 0)
    end

    --- Clears the facts held for the whole session. Wired to the events that
    --- can actually change them.
    function M._invalidate_session()
        session:clear()
    end

    -- --- vitals -------------------------------------------------------------

    ---@return number
    function M.health()
        local p = units.player()
        if not p then return 0 end
        return units.health(p)
    end

    ---@return number
    function M.max_health()
        local p = units.player()
        if not p then return 0 end
        return units.max_health(p)
    end

    --- Health as 0..1.
    ---@return number
    function M.health_pct()
        local p = units.player()
        if not p then return 0 end
        return units.health_fraction(p)
    end

    ---@return number
    function M.health_deficit()
        local p = units.player()
        if not p then return 0 end
        return units.health_deficit(p)
    end

    --- Absorb shield currently on the player.
    ---@return number
    function M.shield()
        return ask("shield", function(p) return p:get_total_shield() end, 0)
    end

    --- Heals already in the air toward the player. Checking this before
    --- committing an emergency defensive is the difference between reacting to
    --- damage and reacting to damage twice.
    ---@return number
    function M.incoming_heals()
        return ask("incoming_heals", function(p) return p:get_incoming_heals() end, 0)
    end

    ---@return number
    function M.heal_absorb()
        return ask("heal_absorb", function(p) return p:get_total_heal_absorbs() end, 0)
    end

    --- Effective health: what is actually between the player and the floor.
    ---@return number
    function M.effective_health()
        return M.health() + M.shield()
    end

    ---@return boolean
    function M.is_dead()
        local p = units.player()
        if not p then return false end
        return units.is_dead(p)
    end

    ---@return boolean
    function M.is_ghost()
        return ask("ghost", function(p) return p:is_ghost() end, false)
    end

    -- --- power --------------------------------------------------------------

    --- Current amount of a resource. With no argument it answers the class
    --- primary, which is what a rotation almost always means.
    ---@param power_type? integer
    ---@return number
    function M.power(power_type)
        power_type = power_type or POWER.MANA
        local key = "power." .. power_type
        local value, hit = tick:get(key)
        if hit then return value or 0 end

        local p = units.player()
        if not p then return tick:put(key, 0) end
        return tick:put(key, try(p.get_power, p, power_type) or 0)
    end

    ---@param power_type? integer
    ---@return number
    function M.max_power(power_type)
        power_type = power_type or POWER.MANA
        local key = "maxpower." .. power_type
        local value, hit = tick:get(key)
        if hit then return value or 0 end

        local p = units.player()
        if not p then return tick:put(key, 0) end
        return tick:put(key, try(p.get_max_power, p, power_type) or 0)
    end

    --- Resource as 0..1.
    ---@param power_type? integer
    ---@return number
    function M.power_pct(power_type)
        local max = M.max_power(power_type)
        if max <= 0 then return 0 end
        return util.clamp(M.power(power_type) / max, 0, 1)
    end

    --- How much of a resource is missing. The figure a "do I need to spend"
    --- check wants, since a builder that overcaps is wasted.
    ---@param power_type? integer
    ---@return number
    function M.power_deficit(power_type)
        return M.max_power(power_type) - M.power(power_type)
    end

    ---@return number
    function M.combo_points()
        return M.power(POWER.COMBOPOINTS)
    end

    ---@return number
    function M.max_combo_points()
        return M.max_power(POWER.COMBOPOINTS)
    end

    -- --- runes (death knight) -----------------------------------------------

    --- Runes ready to spend right now.
    ---@return integer
    function M.runes_ready()
        local value, hit = tick:get("runes_ready")
        if hit then return value or 0 end

        local n = 0
        for slot = 1, 6 do
            if try_bool(core.spell_book.is_rune_slot_active, slot) then n = n + 1 end
        end
        return tick:put("runes_ready", n)
    end

    --- Full rune rows, slot 1..6, as the client reports them.
    ---@return table[]
    function M.runes()
        local value, hit = tick:get("runes")
        if hit then return value or {} end

        local out = {}
        for slot = 1, 6 do
            out[slot] = {
                slot   = slot,
                active = try_bool(core.spell_book.is_rune_slot_active, slot),
                type   = try(core.spell_book.get_rune_type, slot),
                info   = try(core.spell_book.get_rune_info, slot),
            }
        end
        return tick:put("runes", out)
    end

    -- --- casting ------------------------------------------------------------

    ---@return boolean
    function M.is_casting()
        return ask("casting", function(p) return p:is_casting_spell() end, false)
    end

    ---@return boolean
    function M.is_channelling()
        return ask("channelling", function(p) return p:is_channelling_spell() end, false)
    end

    --- Casting or channelling. The check before starting anything new.
    ---@return boolean
    function M.is_busy()
        return M.is_casting() or M.is_channelling()
    end

    -- On Forever the active channel's id is sometimes garbage (3,739,147,998
    -- in the API recorder); real ids there run past a million, never past
    -- five. An id like that is "unknown", not a spell. Decided once.
    local forever = nil
    local function is_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        forever = ok and type(c) == "table" and c.forever == true or false
        return forever
    end
    local MAX_SPELL_ID = 5000000

    ---@return integer|nil
    function M.casting_spell_id()
        local id = nil
        if M.is_channelling() then
            id = ask("channel_id", function(p) return p:get_active_channel_spell_id() end, nil)
        elseif M.is_casting() then
            id = ask("cast_id", function(p) return p:get_active_spell_id() end, nil)
        end
        if id and is_forever() and (type(id) ~= "number" or id > MAX_SPELL_ID or id <= 0) then return nil end
        return id
    end

    --- Seconds left on whatever the player is currently doing, 0 when idle.
    ---@return number
    function M.cast_remaining()
        local p = units.player()
        if not p then return 0 end

        local end_time
        if M.is_channelling() then
            end_time = ask("channel_end", function(u) return u:get_active_channel_cast_end_time() end, nil)
        elseif M.is_casting() then
            end_time = ask("cast_end", function(u) return u:get_active_spell_cast_end_time() end, nil)
        end
        if not end_time or end_time <= 0 then return 0 end

        -- Cast end times are engine milliseconds, the same base as
        -- core.game_time(). Subtract first, then convert.
        return math.max(0, (end_time - core.game_time()) / 1000.0)
    end

    --- The target of the spell being cast, which is not always the player's
    --- current target.
    ---@return game_object|nil
    function M.cast_target()
        return ask("cast_target", function(p) return p:get_active_spell_target() end, nil)
    end

    ---@return number
    function M.gcd()
        local value, hit = tick:get("gcd")
        if hit then return value or 0 end
        -- Forever: the native answers 0 always; the spells service reads the
        -- GCD off a probe spell instead (spells.lua).
        if is_forever() and rt.spells and rt.spells.gcd then
            return tick:put("gcd", try(rt.spells.gcd) or 0)
        end
        return tick:put("gcd", try(core.spell_book.get_global_cooldown) or 0)
    end

    --- Spell haste as a multiplier, where 1.0 is no haste.
    ---@return number
    function M.haste()
        return ask("haste", function(p) return p:get_spell_haste() end, 1.0)
    end

    -- Empowered (Evoker) casts report which stage they have reached.

    ---@return integer
    function M.empower_stage()
        return ask("empower_stage", function(p) return p:get_empower_current_stage() end, 0)
    end

    ---@return integer
    function M.empower_max_stage()
        return ask("empower_max", function(p) return p:get_empower_max_stage() end, 0)
    end

    -- --- movement and state -------------------------------------------------

    ---@return boolean
    function M.is_moving()
        return ask("moving", function(p) return p:is_moving() end, false)
    end

    ---@return boolean
    function M.is_mounted()
        return ask("mounted", function(p) return p:is_mounted() end, false)
    end

    ---@return boolean
    function M.is_flying()
        return ask("flying", function(p) return p:is_flying() end, false)
    end

    ---@return boolean
    function M.is_dashing()
        return ask("dashing", function(p) return p:is_dashing() end, false)
    end

    ---@return boolean
    function M.is_indoors()
        return ask("indoors", function(p) return p:is_indoors() end, false)
    end

    ---@return boolean
    function M.is_outdoors()
        return ask("outdoors", function(p) return p:is_outdoors() end, false)
    end

    ---@return boolean
    function M.in_combat()
        return ask("in_combat", function(p) return p:is_in_combat() end, false)
    end

    ---@return boolean
    function M.is_auto_attacking()
        return ask("auto_attack", function(p) return p:is_auto_attacking() end, false)
    end

    ---@return number
    function M.movement_speed()
        return ask("speed", function(p) return p:get_movement_speed() end, 0)
    end

    ---@return number
    function M.movement_speed_max()
        return ask("speed_max", function(p) return p:get_movement_speed_max() end, 0)
    end

    ---@return number
    function M.attack_speed()
        return ask("attack_speed", function(p) return p:get_attack_speed() end, 0)
    end

    ---@return boolean
    function M.is_swimming()
        local value, hit = tick:get("swimming")
        if hit then return value or false end
        return tick:put("swimming", try_bool(core.character.is_swimming))
    end

    ---@return boolean
    function M.is_resting()
        local value, hit = tick:get("resting")
        if hit then return value or false end
        return tick:put("resting", try_bool(core.character.is_resting))
    end

    --- Breath bar while underwater, or nil when not drowning.
    ---@return table|nil
    function M.breath()
        local value, hit = tick:get("breath")
        if hit then return value end
        return tick:put("breath", try(core.character.get_breath))
    end

    --- Current shapeshift / stance form id. 0 means no form.
    ---@return integer
    function M.form()
        local value, hit = tick:get("form")
        if hit then return value or 0 end
        return tick:put("form", try(core.spell_book.get_shapeshift_form_id) or 0)
    end

    --- Raw movement / state bit field, for the flags this runtime does not
    --- name individually.
    ---@return integer
    function M.state_flags()
        return ask("state_flags", function(p) return p:get_state_flags() end, 0)
    end

    --- Crowd control currently on the player, or nil when free.
    ---@return loss_of_control_info|nil
    function M.loss_of_control()
        return ask("loc", function(p) return p:get_loss_of_control_info() end, nil)
    end

    -- --- relationships ------------------------------------------------------

    ---@return game_object|nil
    function M.target()
        return ask("target", function(p) return p:get_target() end, nil)
    end

    ---@return game_object|nil
    function M.focus()
        local value, hit = tick:get("focus")
        if hit then return value end
        return tick:put("focus", try(core.input.get_focus))
    end

    ---@return game_object|nil
    function M.pet()
        -- units.player_pet: get_pet, and on Forever the search for a pet
        -- get_pet does not name (see units.lua).
        return units.player_pet()
    end

    ---@return game_object|nil
    function M.mouseover()
        local value, hit = tick:get("mouseover")
        if hit then return value end
        return tick:put("mouseover", try(core.object_manager.get_mouse_over_object))
    end

    --- The unit the player's combo points are banked on, which on a modern
    --- client is not necessarily the current target.
    ---@return game_object|nil
    function M.combo_point_target()
        return ask("cp_target", function(p) return p:get_combo_points_target() end, nil)
    end

    -- --- gear ---------------------------------------------------------------

    ---@return table[]
    function M.equipped_items()
        local value, hit = tick:get("equipped")
        if hit then return value or {} end
        local p = units.player()
        if not p then return tick:put("equipped", {}) end
        return tick:put("equipped", try(p.get_equipped_items, p) or {})
    end

    ---@param slot integer
    ---@return table|nil
    function M.item_at_slot(slot)
        local key = "slot." .. tostring(slot)
        local value, hit = tick:get(key)
        if hit then return value end
        local p = units.player()
        if not p then return nil end
        return tick:put(key, try(p.get_item_at_inventory_slot, p, slot))
    end

    ---@return number
    function M.gold()
        local value, hit = tick:get("gold")
        if hit then return value or 0 end
        return tick:put("gold", try(core.inventory.get_gold) or 0)
    end

    -- --- talents and professions --------------------------------------------

    --- Active talent rows. Session-scoped and dropped on a talent change,
    --- because walking the full tree is not something to do per frame.
    ---@return table[]
    function M.talents()
        local value, hit = session:get("talents")
        if hit then return value or {} end
        return session:put("talents", try(core.game_ui.get_active_talents) or {})
    end

    ---@return table|nil
    function M.professions()
        local value, hit = session:get("professions")
        if hit then return value end
        return session:put("professions", try(core.spell_book.get_professions))
    end

    -- --- a profession's skill (1.8.5) -----------------------------------------
    --
    -- Three sources, the first that answers:
    --   "profession"  get_professions + get_profession_info (GetProfessions;
    --                 the modern clients, possibly Forever: never recorded
    --                 there yet)
    --   "skill"       the Skill window's lines (GetSkillLineInfo; Era, TBC,
    --                 and Forever from the 2026-10-06 core, which calls its
    --                 C_SkillInfo names. Before that core nothing there; on
    --                 Forever the extra sub-skill rows are skipped because
    --                 only the profession's own name is matched)
    --   "rank"        no read answered: the highest rank in the spellbook, and
    --                 the skill is at most that rank's cap. An upper bound,
    --                 not the skill.
    -- Gear and buffs count (Finkle's Skinner). Kept five seconds: a skill
    -- goes up by using it.
    local SKILLS = {
        skinning = { line = 393, name = "Skinning",
            ranks = { { 10768, 300 }, { 8618, 225 }, { 8617, 150 }, { 8613, 75 } } },
        herbalism = { line = 182, name = "Herbalism",
            ranks = { { 11993, 300 }, { 3570, 225 }, { 2368, 150 }, { 2366, 75 } } },
        mining = { line = 186, name = "Mining",
            ranks = { { 10248, 300 }, { 3564, 225 }, { 2576, 150 }, { 2575, 75 } } },
        fishing = { line = 356, name = "Fishing",
            ranks = { { 18248, 300 }, { 7732, 225 }, { 7731, 150 }, { 7620, 75 } } },
    }
    local skill_cache = cache.new("player.skill", { scope = "ttl", ttl = 5.0 })

    local function skill_from_professions(def)
        local slots = try(core.spell_book.get_professions)
        if type(slots) ~= "table" then return nil end
        for _, index in pairs(slots) do
            local info = type(index) == "number" and try(core.spell_book.get_profession_info, index) or nil
            if type(info) == "table" and (info.skill_line == def.line
                or info.skill_line_name == def.name or info.name == def.name) then
                local level = tonumber(info.skill_level)
                if level then return level + (tonumber(info.skill_modifier) or 0), tonumber(info.max_skill_level) end
            end
        end
        return nil
    end

    local function skill_from_window(def)
        local window = core.skill
        if type(window) ~= "table" then return nil end
        local n = tonumber(try(window.get_num_skill_lines)) or 0
        for i = 1, n do
            local info = try(window.get_skill_line_info, i)
            if type(info) == "table" and not info.is_header and info.name == def.name then
                local level = tonumber(info.skill_rank)
                if level then
                    return level + (tonumber(info.num_temp_points) or 0) + (tonumber(info.skill_modifier) or 0),
                        tonumber(info.skill_max_rank)
                end
            end
        end
        return nil
    end

    local function skill_from_rank(def)
        local spells = rt.spells
        for i = 1, #def.ranks do
            local id, cap = def.ranks[i][1], def.ranks[i][2]
            local learned = spells and spells.learned and spells.learned(id)
            if learned == nil then learned = try_bool(core.spell_book.is_spell_known, id) end
            if learned then return cap, cap end
        end
        return nil
    end

    --- A profession's skill: level, how it was read ("profession", "skill"
    --- or "rank" -- see above), and the most it can be now. nil, nil when
    --- the player does not have the profession.
    ---@param key string "skinning", "herbalism", "mining" or "fishing"
    ---@return integer|nil level
    ---@return string|nil how
    ---@return integer|nil max
    function M.skill(key)
        local def = SKILLS[key]
        if not def then return nil, nil, nil end
        local row, hit = skill_cache:get(key)
        if not hit then
            row = {}
            local level, max = skill_from_professions(def)
            if level then
                row.level, row.how, row.max = level, "profession", max
            else
                level, max = skill_from_window(def)
                if level then
                    row.level, row.how, row.max = level, "skill", max
                else
                    level, max = skill_from_rank(def)
                    if level then row.level, row.how, row.max = level, "rank", max end
                end
            end
            skill_cache:put(key, row)
        end
        return row.level, row.how, row.max
    end

    --- The Skinning a corpse of this level asks for, by the game's rule:
    --- anyone up to level 10, then ten points a level to 100 at level 20,
    --- then five a level (300 at 60).
    ---@param level integer
    ---@return integer
    function M.skin_required(level)
        if level <= 10 then return 1 end
        if level <= 20 then return (level - 10) * 10 end
        return level * 5
    end

    --- Can the player skin a corpse of this level? Also says what it asks
    --- for, the skill it was weighed against and how that was read. A level
    --- that did not read (nil or 0) is never a no. Read by rank only, the
    --- skill is its cap: only what is beyond the rank is a no.
    ---@param level integer|nil
    ---@return boolean ok
    ---@return integer|nil required
    ---@return integer|nil skill
    ---@return string|nil how
    function M.can_skin(level)
        if type(level) ~= "number" or level <= 0 then return true, nil, nil, "level unread" end
        local required = M.skin_required(level)
        local skill, how = M.skill("skinning")
        if not skill then return false, required, nil, nil end
        return skill >= required, required, skill, how
    end

    -- --- auras on the player ------------------------------------------------
    --
    -- Thin forwards to the shared aura index, so a plugin does not have to
    -- fetch the player object just to ask whether a buff is up.

    ---@param spell_id integer|integer[]
    ---@return boolean
    function M.has_buff(spell_id)
        local p = units.player()
        return p ~= nil and units.has_aura(p, spell_id)
    end

    ---@param spell_id integer|integer[]
    ---@return number
    function M.buff_remaining(spell_id)
        local p = units.player()
        if not p then return 0 end
        return units.aura_remaining(p, spell_id)
    end

    ---@param spell_id integer|integer[]
    ---@return integer
    function M.buff_stacks(spell_id)
        local p = units.player()
        if not p then return 0 end
        return units.aura_stacks(p, spell_id)
    end

    ---@param spell_id integer|integer[]
    ---@return buff|nil
    function M.buff(spell_id)
        local p = units.player()
        if not p then return nil end
        return units.aura(p, spell_id)
    end

    -- --- what Forever cannot read (1.6.0) --------------------------------------
    --
    -- Asked the same way on every client. Era: the client's read, exactly as
    -- before. Forever: power through services/power.lua (counted while the
    -- read says 0), a shapeshift index that says "unknown" until the read has
    -- named a form, and no channel id that no spell can have.

    local era_power, era_max_power = M.power, M.max_power

    ---@param power_type? integer
    ---@return number
    function M.power(power_type)
        local raw = era_power(power_type)
        if not is_forever() then return raw end
        local power = rt.power
        if not (power and power.read) then return raw end
        return power.read(power_type or POWER.MANA, raw)
    end

    ---@param power_type? integer
    ---@return number
    function M.max_power(power_type)
        local raw = era_max_power(power_type)
        if not is_forever() then return raw end
        local power = rt.power
        if not (power and power.max) then return raw end
        return power.max(power_type or POWER.MANA, raw)
    end

    --- For a resource the client cannot read and nobody counts (mana on
    --- Forever): 1 while nothing says otherwise, low for a moment after the
    --- client said there was not enough. nil wherever the read works.
    ---@param power_type? integer
    ---@return number|nil
    function M.power_unread(power_type)
        if not is_forever() then return nil end
        local power = rt.power
        return power and power.unread and power.unread(power_type or POWER.MANA) or nil
    end

    --- Is this resource counted from our casts rather than read?
    ---@param power_type? integer
    ---@return boolean
    function M.power_counted(power_type)
        if not is_forever() then return false end
        local power = rt.power
        return power ~= nil and power.counted ~= nil and power.counted(power_type or POWER.MANA) == true
    end

    --- One line saying what is read and what is counted.
    ---@return string
    function M.power_summary()
        local power = rt.power
        if not is_forever() or not (power and power.summary) then return "read by the client" end
        return power.summary()
    end

    -- The shapeshift bar's index. Forever answered 0 for it in every recording,
    -- and a druid's form spell is a toggle, so "0 = no form" cast the form
    -- again and left it, every time. There a 0 is believed only once the read
    -- has named a form; until then this answers nil, "unknown".
    local form_named = false

    ---@return integer|nil index 0 = no form; nil = the client cannot say
    function M.shapeshift_index()
        local ok, index = pcall(core.spell_book.get_shapeshift_form, false)
        index = ok and tonumber(index) or nil
        if not is_forever() then return index or 0 end
        if index and index > 0 then
            form_named = true
            return index
        end
        if form_named then return 0 end
        return nil
    end

    --- The spell id of the player's channel, or nil. Forever sometimes reads
    --- an id no spell can have (3,739,147,998): nil there.
    ---@return integer|nil
    function M.channel_spell_id()
        local p = units.player()
        if not p then return nil end
        local id = try(p.get_active_channel_spell_id, p)
        if is_forever() and (type(id) ~= "number" or id > MAX_SPELL_ID or id <= 0) then return nil end
        return id
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            exists  = M.exists(),
            name    = M.name(),
            level   = M.level(),
            class   = M.class_id(),
            spec    = M.spec_id(),
            health  = M.health_pct(),
            combat  = M.in_combat(),
            busy    = M.is_busy(),
            moving  = M.is_moving(),
            cached  = tick:stats(),
        }
    end

    return M
end

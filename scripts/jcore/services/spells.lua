-- JCore / spells -- spell metadata, cached per tick.
--
-- Depends on: util, log, units.
--
-- Split of responsibility with services/cast.lua: this module ANSWERS
-- questions ("is it off cooldown", "does it reach", "what is its range"), it
-- never acts. cast.lua decides what to actually send. Keeping the read side
-- pure means a rotation can evaluate a whole priority list without any risk of
-- a side effect halfway down it.
--
-- What is cached and why: the static facts about a spell (name, range, school,
-- whether it is melee) never change within a session and are resolved once.
-- The volatile facts (cooldown, usability) are cached for the current tick
-- only, because a rotation typically asks about the same spell several times
-- while walking its priority list and each of those is a native call.

return function(rt)
    local util = rt.util
    local units = rt.units
    local log = rt.log.for_tag("JCore/spells")

    local spell_helper
    do
        local ok, mod = pcall(require, "common/utility/spell_helper")
        if ok then spell_helper = mod end
    end

    local M = {}

    -- spell_id -> static info, resolved once and kept.
    local static_cache = {}
    -- spell_id -> { tick, cooldown, usable, known }
    local tick_cache = {}
    local tick_id = 0
    -- Forever only: the spell the global cooldown is read off (see M.gcd).
    local probe = nil
    local probe_checked = {}         -- spell_id -> true once asked

    --- Invalidates the per-tick half of the cache. Called from the runtime once
    --- per update, immediately after the unit sweep.
    function M._new_tick()
        tick_id = tick_id + 1
    end

    --- SPELLS_CHANGED, a talent swap or a level-up can change a spell's range
    --- or even its id. The runtime wires this to the game event, so the static
    --- cache is not a lie for the rest of the session.
    function M._invalidate_static()
        static_cache = {}
        -- A new spellbook: the GCD probe may be gone (Forever only sets it).
        probe, probe_checked = nil, {}
        log.debug("static spell cache cleared")
    end

    ---@class jcore_spell_info
    ---@field id integer
    ---@field name string
    ---@field min_range number
    ---@field max_range number
    ---@field is_melee boolean
    ---@field is_position_cast boolean
    ---@field cast_time number  -- seconds, 0 for instants
    ---@field school integer

    --- Static facts about a spell. Cheap after the first call.
    ---@param spell_id integer
    ---@return jcore_spell_info
    function M.info(spell_id)
        local info = static_cache[spell_id]
        if info then return info end

        info = {
            id               = spell_id,
            name             = "",
            min_range        = 0,
            max_range        = 0,
            is_melee         = false,
            is_position_cast = false,
            cast_time        = 0,
            school           = 0,
        }

        -- Every one of these is pcall'd individually rather than as a block:
        -- a client that does not expose one of them should still give us the
        -- others, and on an unknown spell id several of them raise.
        local ok, value

        ok, value = pcall(core.spell_book.get_spell_name, spell_id)
        if ok and value then info.name = value end

        ok, value = pcall(core.spell_book.get_spell_min_range, spell_id)
        if ok and value then info.min_range = value end

        ok, value = pcall(core.spell_book.get_spell_max_range, spell_id)
        if ok and value then info.max_range = value end

        ok, value = pcall(core.spell_book.is_melee_spell, spell_id)
        if ok then info.is_melee = value and true or false end

        ok, value = pcall(core.spell_book.is_spell_position_cast, spell_id)
        if ok then info.is_position_cast = value and true or false end

        ok, value = pcall(core.spell_book.get_spell_school, spell_id)
        if ok and value then info.school = value end

        ok, value = pcall(core.spell_book.get_spell_cast_time, spell_id)
        -- get_spell_cast_time answers milliseconds; everything else in this
        -- runtime speaks seconds, so normalise here rather than at each caller.
        if ok and value then info.cast_time = value / 1000.0 end

        static_cache[spell_id] = info
        return info
    end

    ---@param spell_id integer
    ---@return string
    function M.name(spell_id)
        return M.info(spell_id).name
    end

    local function tick_row(spell_id)
        local row = tick_cache[spell_id]
        if row and row.tick == tick_id then return row end
        row = row or {}
        row.tick = tick_id
        row.cooldown = nil
        row.usable = nil
        row.known = nil
        tick_cache[spell_id] = row
        return row
    end

    --- Seconds of cooldown left. 0 means ready now.
    ---@param spell_id integer
    ---@return number
    function M.cooldown(spell_id)
        local row = tick_row(spell_id)
        if row.cooldown ~= nil then return row.cooldown end
        local ok, value = pcall(core.spell_book.get_spell_cooldown, spell_id)
        row.cooldown = (ok and value) or 0
        return row.cooldown
    end

    -- THE GLOBAL COOLDOWN ON FOREVER (1.5.7). get_global_cooldown answers 0
    -- every time there (the API recorder: 363,398 of 363,398 calls) while
    -- casts plainly ran on it. get_spell_cooldown works, and a spell with no
    -- cooldown of its own that is on the global cooldown reports the GCD as
    -- its cooldown -- Sinister Strike read 0.816 mid-GCD. So on Forever the
    -- GCD is read off one such spell, picked from the spells already asked
    -- about this session by get_spell_base_cooldown (cooldown_ms 0, gcd_ms
    -- above 0). Decided once per session from world.client(), which is
    -- already cached on every client: Era makes the same single native call
    -- it always did.
    local forever = nil              -- nil until the world service can say
    local PROBE_TRIES = 8            -- base-cooldown reads per call while none is found

    local function is_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        forever = ok and type(c) == "table" and c.forever == true or false
        return forever
    end

    local function find_probe()
        local tries = 0
        -- Every spell asked about this session: for its cooldown, its
        -- usability or its static facts.
        local seen = {}
        for spell_id in pairs(tick_cache) do seen[#seen + 1] = spell_id end
        for spell_id in pairs(static_cache) do seen[#seen + 1] = spell_id end
        for i = 1, #seen do
            local spell_id = seen[i]
            if type(spell_id) == "number" and not probe_checked[spell_id] then
                probe_checked[spell_id] = true
                tries = tries + 1
                local ok, base = pcall(core.spell_book.get_spell_base_cooldown, spell_id)
                if ok and type(base) == "table" and (tonumber(base.cooldown_ms) or 1) == 0
                    and (tonumber(base.gcd_ms) or 0) > 0 and M.known(spell_id) then
                    probe = spell_id
                    log.info(string.format("Forever: the global cooldown is read off spell %d", spell_id))
                    return probe
                end
                if tries >= PROBE_TRIES then return nil end
            end
        end
        return nil
    end

    --- Seconds left on the global cooldown. 0 means the GCD is free.
    ---@return number
    function M.gcd()
        if is_forever() then
            local id = probe or find_probe()
            if not id then return 0 end
            return M.cooldown(id)
        end
        local ok, value = pcall(core.spell_book.get_global_cooldown)
        return (ok and value) or 0
    end

    --- The spell the GCD is read off on Forever, or nil (and always nil elsewhere).
    ---@return integer|nil
    function M.gcd_probe() return probe end

    ---@param spell_id integer
    ---@return boolean
    function M.known(spell_id)
        local row = tick_row(spell_id)
        if row.known ~= nil then return row.known end
        local ok, value = pcall(core.spell_book.is_spell_known, spell_id)
        if not ok then
            ok, value = pcall(core.spell_book.has_spell, spell_id)
        end
        row.known = (ok and value) and true or false
        return row.known
    end

    --- Has the player learned this spell, and how was that decided (1.6.0)?
    --- "known": is_spell_known said yes. "has_spell": it said no (or raised)
    --- and has_spell said yes, for builds where is_spell_known is not
    --- implemented for some ids. "refused": it said no and that is final,
    --- which is so on Forever (the recorder has it answering every id there,
    --- true or false, never raising). Not cached: a spellbook walk asks once.
    ---@param spell_id integer
    ---@return boolean learned
    ---@return string|nil how
    function M.learned(spell_id)
        local ok, known = pcall(core.spell_book.is_spell_known, spell_id)
        if ok and known then return true, "known" end
        if ok and is_forever() then return false, "refused" end
        local ok_has, has = pcall(core.spell_book.has_spell, spell_id)
        if ok_has and has then return true, "has_spell" end
        return false, nil
    end

    --- The client's own "can I press this right now" answer: resources, form,
    --- required aura, and the rest of the conditions the core folds in.
    ---@param spell_id integer
    ---@return boolean
    function M.usable(spell_id)
        local row = tick_row(spell_id)
        if row.usable ~= nil then return row.usable end
        local fn = core.spell_book.is_usable_spell
        if not fn then
            row.usable = true
            return true
        end
        local ok, value = pcall(fn, spell_id)
        row.usable = (ok and value) and true or false
        return row.usable
    end

    ---@param spell_id integer
    ---@return integer current
    ---@return integer max
    function M.charges(spell_id)
        local ok_current, current = pcall(core.spell_book.get_spell_charge, spell_id)
        local ok_max, max = pcall(core.spell_book.get_spell_charge_max, spell_id)
        return (ok_current and current) or 0, (ok_max and max) or 0
    end

    --- Ready = known, off cooldown (or holding a charge), and usable.
    --- This is the check a rotation wants nine times out of ten.
    ---@param spell_id integer
    ---@return boolean
    function M.ready(spell_id)
        if not M.known(spell_id) then return false end
        if not M.usable(spell_id) then return false end
        if M.cooldown(spell_id) > 0 then
            -- A charge-based spell reports a cooldown while it is recharging
            -- even though a banked charge is available right now.
            local current = M.charges(spell_id)
            if current < 1 then return false end
        end
        return true
    end

    ---@param spell_id integer
    ---@param target game_object
    ---@return boolean
    function M.in_range(spell_id, target)
        if not target or not target:is_valid() then return false end
        local ok, value = pcall(core.spell_book.is_spell_in_range, spell_id, target, units.player())
        if ok then return value and true or false end

        -- Fall back to the geometric check when the native one is unavailable
        -- for this spell. combat_reach matters here: a melee ability reaches
        -- from hitbox to hitbox, not from centre to centre, and ignoring that
        -- makes every large mob look out of range.
        local info = M.info(spell_id)
        local player = units.player()
        if not player then return false end
        local reach = (player:get_combat_reach() or 0) + (target:get_combat_reach() or 0)
        local dist = units.distance(target) - reach
        local max_range = info.is_melee and 5.0 or info.max_range
        if max_range <= 0 then return true end
        return dist <= max_range and dist >= info.min_range
    end

    ---@param spell_id integer
    ---@param target game_object
    ---@return boolean
    function M.in_line_of_sight(spell_id, target)
        if not spell_helper then
            local ok, value = pcall(core.graphics.is_line_of_sight, units.player(), target)
            return ok and value and true or false
        end
        local ok, value = pcall(spell_helper.is_spell_in_line_of_sight, spell_helper,
            spell_id, units.player(), target)
        return ok and value and true or false
    end

    --- Full gate: ready, in range, facing, in line of sight. `opts` maps onto
    --- the shipped spell_helper skip flags for the cases where a caller has
    --- already established one of those itself.
    ---@param spell_id integer
    ---@param target game_object
    ---@param opts? { skip_facing?: boolean, skip_range?: boolean, skip_usable?: boolean, skip_learned?: boolean }
    ---@return boolean
    -- CASTABLE ON FOREVER (1.5.10). The loader's spell_helper does not know
    -- this client: it asks input.get_control_object, which answered nil on
    -- all 481,552 calls in the API recorder, and the client's range data,
    -- where get_spell_max_range read 0 on 43,505 of 43,544 calls -- so it
    -- called every spell uncastable and a rogue stood still in fights it
    -- then lost ("Sinister Strike: not usable", "Gouge: not castable on
    -- target"). On Forever the gate is JCore's own, from what the recorder
    -- showed working there: known, usable, cooldown, line of sight, and
    -- melee reach from the two positions and combat reaches. A range the
    -- client does not give is left to the client to refuse.
    local MELEE_FLOOR, MELEE_EXTRA, SLACK = 5.0, 4 / 3, 0.5

    local function forever_in_range(spell_id, target, player)
        if target == player then return true end
        local info = M.info(spell_id)
        local dist = units.distance(target)
        if type(dist) ~= "number" then return true end
        local ok_a, ra = pcall(player.get_combat_reach, player)
        local ok_b, rb = pcall(target.get_combat_reach, target)
        local reach = (ok_a and tonumber(ra) or 1.5) + (ok_b and tonumber(rb) or 1.5)
        if info.is_melee then
            return dist <= math.max(MELEE_FLOOR, reach + MELEE_EXTRA) + SLACK
        end
        local max_range = tonumber(info.max_range) or 0
        if max_range <= 0 then return true end
        local edge = dist - reach
        return edge <= max_range + SLACK and edge >= (tonumber(info.min_range) or 0) - SLACK
    end

    local function forever_castable(spell_id, target, opts, player)
        if not opts.skip_learned and not M.known(spell_id) then return false end
        if not opts.skip_usable and not M.usable(spell_id) then return false end
        if M.cooldown(spell_id) > 0 and M.charges(spell_id) < 1 then return false end
        if not opts.skip_range and not forever_in_range(spell_id, target, player) then return false end
        if target ~= player then
            local ok, sight = pcall(core.graphics.is_line_of_sight, player, target)
            if ok and sight == false then return false end
        end
        return true
    end

    function M.castable(spell_id, target, opts)
        opts = opts or {}
        local player = units.player()
        if not player or not target or not target:is_valid() then return false end

        if is_forever() then return forever_castable(spell_id, target, opts, player) end

        if spell_helper then
            local ok, value = pcall(spell_helper.is_spell_castable, spell_helper,
                spell_id, player, target,
                opts.skip_facing and true or false,
                opts.skip_range and true or false,
                opts.skip_usable and true or false,
                false,
                opts.skip_learned and true or false)
            if ok then return value and true or false end
        end

        if not opts.skip_learned and not M.known(spell_id) then return false end
        if not opts.skip_usable and not M.usable(spell_id) then return false end
        if M.cooldown(spell_id) > 0 and M.charges(spell_id) < 1 then return false end
        if not opts.skip_range and not M.in_range(spell_id, target) then return false end
        return true
    end

    return M
end

-- JCore / group -- the party, the raid, the arena, and who does what in them.
--
-- Depends on: util, log, cache, units.
--
-- Group composition is asked about constantly by anything that heals, dispels
-- or assigns. It is also almost entirely stable: the tank is the tank for the
-- whole pull. Everything here is therefore resolved once per tick and read
-- from a table afterwards, and the role lists are built in a single pass over
-- the roster rather than one pass per question.
--
-- Party members vs allies: units.allies() is a PROXIMITY list, every friendly
-- unit in cache range including other people's pets and passing strangers.
-- This module answers about the actual group. A raid heal wants the former; a
-- dispel assignment or a "is everyone here" check wants the latter.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local units = rt.units
    local log = rt.log.for_tag("JCore/group")

    local try = cache.try

    local M = {}

    local tick = cache.new("group.tick", { scope = "tick" })

    -- Role numbering from common/enums where it is available, with the
    -- client's own values as a fallback so this works on a build without it.
    local ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 }
    do
        local ok, enums = pcall(require, "common/enums")
        if ok and enums and type(enums.group_role) == "table" then
            for name, value in pairs(enums.group_role) do
                if type(value) == "number" then ROLE[name] = value end
            end
        end
    end
    M.ROLE = ROLE

    -- FOREVER (1.5.12). The API recorder, in a party on the Forever beta:
    -- game_object:get_group_role answered -1 and is_party_member false for
    -- everyone, while get_party_members' rows carried the truth -- role =
    -- "DAMAGER" (or "TANK", "HEALER", "NONE") and object = the member. So on
    -- Forever a member's role and object come from its row, and no tank or
    -- healer was ever found before. Decided once from world.client(), which is
    -- built after this service and so is asked on first use; Era makes the
    -- same calls it always did.
    -- The 2026-10-06 core: get_group_role answers the assigned role on every
    -- client (Era, TBC, Forever and the private servers were always -1
    -- before), and -1 is still right solo or when nobody picked roles. The
    -- row is asked first on Forever all the same: it was the truth before
    -- that core, and it cannot be wrong after it.
    local forever = nil
    local function is_forever()
        if forever ~= nil then return forever end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        forever = ok and type(c) == "table" and c.forever == true or false
        return forever
    end

    local function tick_get(key, fn, a)
        local value, hit = tick:get(key)
        if hit then return value end
        return tick:put(key, try(fn, a))
    end

    -- --- roster -------------------------------------------------------------

    --- Party member rows as the client reports them: name, guid, role and the
    --- rest of the frame data, whether or not that member is in cache range.
    ---@return party_member[]
    function M.members()
        return tick_get("members", core.object_manager.get_party_members) or {}
    end

    --- Party frames, which is the list a healing plugin usually wants: it
    --- follows the raid frame order the user actually sees.
    ---@return table[]
    function M.party_frames()
        return tick_get("party_frames", core.object_manager.get_party_frames) or {}
    end

    ---@return table[]
    function M.arena_frames()
        return tick_get("arena_frames", core.object_manager.get_arena_frames) or {}
    end

    ---@return table[]
    function M.boss_frames()
        return tick_get("boss_frames", core.object_manager.get_boss_frames) or {}
    end

    ---@return integer
    function M.size()
        return #M.members()
    end

    ---@return boolean
    function M.in_group()
        return M.size() > 0
    end

    ---@return boolean
    function M.in_raid()
        return M.size() > 5
    end

    -- --- group members as objects -------------------------------------------

    --- Every group member resolvable to a live object, plus the player.
    ---
    --- A member out of cache range will not resolve, which is correct: nothing
    --- can be cast on them anyway, and a list holding entries that cannot be
    --- acted on turns every consumer into a nil check.
    ---@return game_objects_table
    function M.objects()
        local value, hit = tick:get("objects")
        if hit then return value or {} end

        local out = {}
        local n = 0

        local player = units.player()
        if player then
            n = n + 1
            out[n] = player
        end

        local rows = M.members()
        for i = 1, #rows do
            local row = rows[i]
            local guid = row and (row.guid or row.unit_guid)
            local obj = guid and units.by_guid(guid) or nil
            -- Forever: the row hands the member over itself.
            if not obj and type(row) == "table" and row.object and is_forever() then
                local o = row.object
                local ok, valid = pcall(o.is_valid, o)
                if ok and valid then obj = o end
            end
            if obj and obj ~= player then
                n = n + 1
                out[n] = obj
            end
        end

        -- Some builds hand back objects on the frame rows rather than guids.
        -- Fall back to those before concluding the group is empty, or a
        -- healing plugin on such a build sees a party of one.
        if n <= 1 then
            local frames = M.party_frames()
            for i = 1, #frames do
                local frame = frames[i]
                local obj = frame and (frame.object or frame.unit)
                if obj and obj ~= player and obj.is_valid and obj:is_valid() then
                    n = n + 1
                    out[n] = obj
                end
            end
        end

        return tick:put("objects", out)
    end

    --- Role of a unit: one of M.ROLE.
    ---@param unit game_object
    ---@return integer
    function M.role(unit)
        if not unit then return ROLE.NONE end
        local row = units.snapshot(unit)
        if row and row.role ~= nil then return row.role end
        local role = nil
        if is_forever() then
            -- The party row's word: the unit's own answer is -1 there.
            local guid = units.guid(unit)
            local rows = M.members()
            for i = 1, #rows do
                local r = rows[i]
                if type(r) == "table" and (r.object == unit or (guid and (r.guid == guid
                    or (r.object and units.guid(r.object) == guid)))) then
                    local word = type(r.role) == "string" and r.role:upper() or nil
                    if word and type(ROLE[word]) == "number" then role = ROLE[word] end
                    break
                end
            end
            if role == nil then
                local own = try(unit.get_group_role, unit)
                role = (type(own) == "number" and own >= 0) and own or ROLE.NONE
            end
        else
            role = try(unit.get_group_role, unit) or ROLE.NONE
        end
        if row then row.role = role end
        return role
    end

    ---@param unit game_object
    ---@return boolean
    function M.is_tank(unit) return M.role(unit) == ROLE.TANK end

    ---@param unit game_object
    ---@return boolean
    function M.is_healer(unit) return M.role(unit) == ROLE.HEALER end

    ---@param unit game_object
    ---@return boolean
    function M.is_damager(unit) return M.role(unit) == ROLE.DAMAGER end

    --- Splits the group by role in ONE pass and caches all three lists.
    --- Asking for tanks and then healers costs the same as asking for either.
    local function split_roles()
        local value, hit = tick:get("roles")
        if hit then return value end

        local tanks, healers, damagers = {}, {}, {}
        local members = M.objects()
        for i = 1, #members do
            local unit = members[i]
            local role = M.role(unit)
            if role == ROLE.TANK then
                tanks[#tanks + 1] = unit
            elseif role == ROLE.HEALER then
                healers[#healers + 1] = unit
            else
                damagers[#damagers + 1] = unit
            end
        end

        return tick:put("roles", { tanks = tanks, healers = healers, damagers = damagers })
    end

    ---@return game_objects_table
    function M.tanks() return split_roles().tanks end

    ---@return game_objects_table
    function M.healers() return split_roles().healers end

    ---@return game_objects_table
    function M.damagers() return split_roles().damagers end

    --- Is this unit actually in the player's group, as opposed to merely
    --- friendly and nearby?
    ---@param unit game_object
    ---@return boolean
    function M.contains(unit)
        if not unit then return false end
        local members = M.objects()
        for i = 1, #members do
            if members[i] == unit then return true end
        end
        return false
    end

    -- --- group health -------------------------------------------------------

    --- The group member in the worst shape, optionally within `range`.
    ---@param range? number
    ---@return game_object|nil
    function M.lowest_health(range)
        local members = M.objects()
        local best, best_hp = nil, math.huge
        for i = 1, #members do
            local unit = members[i]
            if not range or units.distance(unit) <= range then
                local hp = units.health_fraction(unit)
                if hp > 0 and hp < best_hp then
                    best, best_hp = unit, hp
                end
            end
        end
        return best
    end

    --- How many group members are below `threshold` (0..1) health.
    --- The check behind every "is a raid cooldown worth it" decision.
    ---@param threshold number
    ---@param range? number
    ---@return integer
    function M.count_below(threshold, range)
        local members = M.objects()
        local n = 0
        for i = 1, #members do
            local unit = members[i]
            if not range or units.distance(unit) <= range then
                local hp = units.health_fraction(unit)
                if hp > 0 and hp < threshold then n = n + 1 end
            end
        end
        return n
    end

    --- Mean health fraction across the group, ignoring the dead. Returns 1
    --- for an empty group so that "is the group hurt" reads false rather than
    --- reading as a wipe.
    ---@param range? number
    ---@return number
    function M.average_health(range)
        local members = M.objects()
        local sum, n = 0, 0
        for i = 1, #members do
            local unit = members[i]
            if not range or units.distance(unit) <= range then
                local hp = units.health_fraction(unit)
                if hp > 0 then
                    sum = sum + hp
                    n = n + 1
                end
            end
        end
        if n == 0 then return 1 end
        return sum / n
    end

    --- Group members carrying any of `spell_ids`. The shape a dispel or a
    --- raid-wide debuff check wants.
    ---@param spell_ids integer|integer[]
    ---@return game_objects_table
    function M.with_aura(spell_ids)
        local out = {}
        local members = M.objects()
        local n = 0
        for i = 1, #members do
            if units.has_aura(members[i], spell_ids) then
                n = n + 1
                out[n] = members[i]
            end
        end
        return out
    end

    -- --- arena --------------------------------------------------------------

    ---@param index integer 1..3
    ---@return game_object|nil
    function M.arena_target(index)
        return tick_get("arena." .. tostring(index),
            core.object_manager.get_arena_target, index)
    end

    ---@param index integer
    ---@return integer|nil
    function M.arena_opponent_spec(index)
        return tick_get("arena_spec." .. tostring(index),
            core.object_manager.get_arena_opponent_spec, index)
    end

    --- Every resolvable arena opponent, in frame order.
    ---@return game_objects_table
    function M.arena_opponents()
        local value, hit = tick:get("arena_opponents")
        if hit then return value or {} end

        local out = {}
        local n = 0
        for index = 1, 3 do
            local unit = M.arena_target(index)
            if unit and unit.is_valid and unit:is_valid() then
                n = n + 1
                out[n] = unit
            end
        end
        return tick:put("arena_opponents", out)
    end

    -- --- keystones ----------------------------------------------------------

    --- Asks the group for their keystones. This is a network round trip, not
    --- a read -- call it once when a group forms, never per frame.
    function M.request_party_keystones()
        return try(core.game_ui.request_party_keystones)
    end

    function M.register_keystone_prefix()
        return try(core.game_ui.register_keystone_prefix)
    end

    -- --- invites ------------------------------------------------------------

    ---@return boolean
    function M.can_invite()
        return tick_get("can_invite", core.party.can_invite) and true or false
    end

    ---@param name string
    function M.invite(name)
        return try(core.party.invite_unit, name)
    end

    function M.leave()
        return try(core.input.leave_party)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            size     = M.size(),
            in_raid  = M.in_raid(),
            resolved = #M.objects(),
            tanks    = #M.tanks(),
            healers  = #M.healers(),
            avg_hp   = M.average_health(),
        }
    end

    return M
end

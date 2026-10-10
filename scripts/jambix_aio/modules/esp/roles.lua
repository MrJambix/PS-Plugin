-- Jambix AIO / esp/roles -- what a player DOES: tank, healer or damage.
--
-- The client only knows a role for two kinds of player: one in your own
-- group, whose assigned role it reports outright, and -- on the clients that
-- have specialisations -- one whose spec id it can read. Every other player
-- on screen, which is every hostile one and every stranger, has no role the
-- game will admit to. So the answer here comes in three tiers, and the
-- caller is told which:
--
--   1. the group role the client reports          certain
--   2. the specialisation id, mapped by the enums  certain
--   3. what the player is visibly doing            a guess, of two grades:
--        a form or stance that only one role uses  -- Defensive Stance, Bear
--        Form, Shadowform, Righteous Fury -- is as good as a spec; a class
--        with one job (hunter, rogue, mage, warlock) is likewise; and a
--        hybrid in no telling form gets the role its class usually plays in
--        a group, marked as the guess it is.
--
-- The aura read in tier 3 is one native call per player, and this module is
-- asked from the classifier, which remembers its answer for a couple of
-- seconds -- so a screen full of players costs a handful of aura reads a
-- second, not one per player per frame.

return function(P)
    local cfg = P.cfg
    local units = P.units
    local enums = P.enums

    local M = {}

    M.TANK, M.HEALER, M.DPS = "tank", "healer", "dps"

    -- --- the client's own numbering --------------------------------------------
    --
    -- Taken from the group service, which already reconciled the enums with
    -- the native, rather than from the literal in the contract: the two
    -- disagree about whether NONE is -1 or 0, and the group service is the
    -- one place that has to be right about it for anything else to work.

    local ROLE = (P.ctx and P.ctx.ROLE) or { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 }

    local BY_NUMBER = {}
    local function map_roles()
        BY_NUMBER = {}
        if type(ROLE.TANK) == "number" then BY_NUMBER[ROLE.TANK] = M.TANK end
        if type(ROLE.HEALER) == "number" then BY_NUMBER[ROLE.HEALER] = M.HEALER end
        if type(ROLE.DAMAGER) == "number" then BY_NUMBER[ROLE.DAMAGER] = M.DPS end
    end
    map_roles()

    -- --- class names ------------------------------------------------------------

    -- class id -> "WARRIOR", through the same resolver the class colours and
    -- the rotation use -- the enums where they answer, WoW's own numbering
    -- otherwise -- so none of them can disagree about which id is which
    -- class, and none of them is empty when the enums module is absent.
    local CLASS_NAME = {}
    for name in pairs(cfg.CLASS_RGB) do
        local id = cfg.class_id_for(enums, name)
        if type(id) == "number" then CLASS_NAME[id] = name end
    end
    M.CLASS_NAME = CLASS_NAME

    ---@param class_id integer|nil
    ---@return string|nil
    function M.class_name(class_id)
        return class_id and CLASS_NAME[class_id] or nil
    end

    -- --- tier 3: what the player is doing --------------------------------------

    -- Built from config so the ids sit next to the other static data. Each
    -- row is { spell ids, role }; the first hit wins, so a row that means
    -- "certainly a tank" goes before one that means "probably not".
    local TELLS = cfg.ROLE_TELLS
    local DEFAULT = cfg.ROLE_DEFAULT

    --- The role a visible form or stance gives away, or nil, and the spec it
    --- implies where it implies one.
    ---@param unit game_object
    ---@param class_name string
    ---@return string|nil role
    ---@return integer|nil spec
    local function role_from_auras(unit, class_name)
        local rows = TELLS[class_name]
        if not rows then return nil end
        local index = units.aura_index(unit)
        if not index then return nil end
        for i = 1, #rows do
            local row = rows[i]
            local ids = row[1]
            for j = 1, #ids do
                if index[ids[j]] then return row[2], row[3] end
            end
        end
        return nil
    end

    --- The spec a class plays a role as, when nothing more specific is known.
    ---@param class_name string|nil
    ---@param role string|nil
    ---@return integer|nil
    local function spec_for(class_name, role)
        local by_role = class_name and cfg.ROLE_SPEC[class_name]
        return by_role and role and by_role[role] or nil
    end

    -- --- the answer -------------------------------------------------------------

    --- Tank, healer or damage, whether that is known or guessed, and the
    --- specialisation: the client's own id where it has one, else the spec
    --- the class plays that role as.
    ---
    --- `info` is the classifier's row for the unit, read for class_id so the
    --- native is not asked twice. Answers nil, false for a unit that is not a
    --- player or whose class is unknown -- there is nothing to guess from.
    ---@param unit game_object
    ---@param info table
    ---@return string|nil role One of M.TANK, M.HEALER, M.DPS.
    ---@return boolean certain
    ---@return integer|nil spec A specialisation id, as SPEC_CELLS keys them.
    function M.role(unit, info)
        if not unit or not info or not info.is_player then return nil, false, nil end

        local ok, value

        local class_id = info.class_id
        local class_name = class_id and CLASS_NAME[class_id] or nil

        -- The client's spec id, on the clients that have one. The tree
        -- clients answer 0 for everyone. Read first because it refines
        -- every tier's answer, and it is one native call.
        local spec = nil
        ok, value = pcall(unit.get_specialization_id, unit)
        if ok and type(value) == "number" and value > 0 then spec = value end

        -- 1. The client's own answer, for a group member. Through the group
        -- service when there is one, because it caches the party rows.
        local group = P.ctx and P.ctx.group
        if group and group.role then
            ok, value = pcall(group.role, unit)
        else
            ok, value = pcall(unit.get_group_role, unit)
        end
        if ok and type(value) == "number" then
            local role = BY_NUMBER[value]
            if role then return role, true, spec or spec_for(class_name, role) end
        end

        -- 2. The spec, mapped to a role by the enums.
        if spec and class_id and enums and type(enums.class_spec_to_role) == "table" then
            local backup = enums.class_spec_to_role.get_group_role_backup
            if type(backup) == "function" then
                local ok_role, role_number = pcall(backup, class_id, spec)
                local role = ok_role and BY_NUMBER[role_number] or nil
                if role then return role, true, spec end
            end
        end

        if not class_name then return nil, false, spec end

        -- 3. Forms, stances and single-job classes.
        local told, told_spec = role_from_auras(unit, class_name)
        if told then return told, true, spec or told_spec or spec_for(class_name, told) end

        local fallback = DEFAULT[class_name]
        if not fallback then return nil, false, spec end
        return fallback[1], fallback[2] == true, spec or spec_for(class_name, fallback[1])
    end

    return M
end

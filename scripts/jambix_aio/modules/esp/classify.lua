-- Jambix AIO / esp/classify -- what a thing IS, answered once and remembered.
--
-- Both halves of the overlay ask the same question in different words: the
-- unit pass wants a category for a creature, the world pass wants a kind for
-- an object. They were answered in two files with two caches and two
-- invalidation rules, which is one rule too many -- a zone change has to clear
-- both, and only one of them remembered to.
--
-- Cached by guid, because neither answer changes for a given handle: a boar
-- does not become an elite and a herb node does not become an ore vein. What
-- DOES change is whether the quest log currently wants a unit, and that is
-- deliberately not cached here -- see collect.lua, which asks per frame.

return function(P)
    local ctx, cfg = P.ctx, P.cfg

    local M = {}

    local unit_cache = {}
    local object_cache = {}
    local npc_flags = {}     -- guid -> UNIT_NPC_FLAGS, read once (town_npcs, 1.89.0)

    -- A cached unit answer is re-read after this long, because two of its
    -- facts do move: a neutral mob turns hostile when it is attacked, a player
    -- flags for PvP, a pet levels. The refresh is per unit and JITTERED, so
    -- the re-reads spread across frames. The alternative -- dropping the
    -- whole cache on a timer -- re-read every unit in range in one frame,
    -- eleven native calls apiece, and that was a periodic hitch.
    local UNIT_TTL = 2.0

    ctx.on("jcore.unit.removed", function(guid)
        unit_cache[guid] = nil
        object_cache[guid] = nil
        npc_flags[guid] = nil
    end)

    ctx.on("jcore.zone.changed", function()
        unit_cache = {}
        object_cache = {}
        npc_flags = {}
    end)

    --- Drops the unit answers. Objects are left alone: a node's identity does
    --- not go stale, and re-reading every name in the zone is the expensive
    --- half.
    function M.invalidate()
        unit_cache = {}
    end

    -- --- units --------------------------------------------------------------

    ---@param unit game_object
    ---@param guid string
    ---@param player game_object
    ---@return table info
    ---@param now? number The caller's clock for this frame; read here when absent.
    function M.unit(unit, guid, player, now)
        now = now or core.time()
        local cached = unit_cache[guid]
        if cached and now < cached.expires then return cached end

        local info = { name = "", level = 0, classification = cfg.CLASS_UNKNOWN }
        info.expires = now + UNIT_TTL * (0.75 + 0.5 * math.random())

        local ok, value
        ok, value = pcall(unit.get_name, unit);           if ok and value then info.name = value end
        ok, value = pcall(unit.get_level, unit);          if ok and value then info.level = value end
        ok, value = pcall(unit.get_classification, unit); if ok and value then info.classification = value end
        ok, value = pcall(unit.get_creature_type, unit);  if ok then info.creature_type = value end
        ok, value = pcall(unit.get_class, unit);          if ok then info.class_id = value end
        ok, value = pcall(unit.get_npc_id, unit);         if ok then info.npc_id = value end
        ok, value = pcall(unit.get_race_id, unit);        if ok then info.race_id = value end

        info.is_player = unit:is_player()

        -- REACTION, AND WHY IT TAKES THREE CALLS
        --
        -- "Can I attack it" is not "is it hostile". A neutral mob is
        -- attackable and will not attack you first, and those are the two
        -- facts a levelling character most wants to tell apart -- the yellow
        -- name you can walk past against the red one that is already coming.
        -- The game answers them with separate questions and so does this:
        -- enemy is red, friend is green, and attackable-but-neither is the
        -- yellow in between.
        local can_attack = select(2, pcall(player.can_attack, player, unit)) == true
        local is_enemy = select(2, pcall(player.is_enemy_with, player, unit)) == true
        local is_friend = select(2, pcall(player.is_friend_with, player, unit)) == true

        info.can_attack = can_attack
        if is_enemy then
            info.reaction = "hostile"
        elseif is_friend then
            info.reaction = "friendly"
        else
            info.reaction = "neutral"
        end

        info.hostile = info.is_player and can_attack or false

        -- SLOW FACTS, ON THE SLOW CLOCK. Whether somebody else has tagged it,
        -- which raid icon it carries and whether a player is mounted each
        -- change once in a fight, not every frame, so they ride this jittered
        -- refresh instead of the per-frame detail read -- a couple of seconds
        -- late, at a fraction of the cost. Each is read only while a mark
        -- that shows it is switched on.
        if not info.is_player and (P.opt("grey_tapped", true) or P.opt("show_status", true)) then
            ok, value = pcall(unit.is_tap_denied, unit)
            -- The contract types this as a number: a zero is "no", and only
            -- a truthy non-zero answer is somebody else's tag.
            info.tapped = ok and value ~= nil and value ~= false and value ~= 0 or false
        end
        if P.opt("show_raid_marker", true) then
            ok, value = pcall(unit.get_target_marker_index, unit)
            info.marker = (ok and type(value) == "number" and value >= 1 and value <= 8)
                and value or nil
        end
        if info.is_player and P.opt("show_status", true) then
            ok, value = pcall(unit.is_mounted, unit)
            info.mounted = ok and value == true
        end

        -- What the portrait badge says. Read here, on the same jittered
        -- clock as the rest of the row, because the mark that shows it is
        -- drawn every frame and the answer costs a native call.
        if info.is_player then
            if P.esp_roles then
                info.role, info.role_certain, info.spec = P.esp_roles.role(unit, info)
            end
        else
            -- Caster or melee: does it have a mana pool at all.
            local mana = P.enums and P.enums.power_type and P.enums.power_type.MANA or 0
            ok, value = pcall(unit.get_max_power, unit, mana)
            if ok and type(value) == "number" then
                info.caster = value > 0
            else
                info.caster = nil
            end
        end

        -- Whose side it is on, beyond friend or foe: a player in your group,
        -- or a pet or minion -- anybody's. Each is its own category, with
        -- its own switch, because a town or a group full of them is the
        -- crowd that makes the rest of the overlay unreadable.
        if info.is_player then
            ok, value = pcall(unit.is_party_member, unit)
            info.party = ok and value == true
        else
            ok, value = pcall(unit.is_pet, unit)
            local pet = ok and value == true
            if not pet then
                ok, value = pcall(unit.is_minion, unit)
                pet = ok and value == true
            end
            info.pet = pet
        end

        local category
        if info.is_player then
            if info.party then
                category = "party"
            else
                category = info.hostile and "hostile_player" or "friendly_player"
            end
        elseif info.pet then
            category = "pet"
        elseif not can_attack and info.reaction ~= "hostile" then
            -- Guards, vendors, trainers, flight masters: nothing you can
            -- fight. A friendly elite guard used to be an "elite", marked
            -- in a town alongside every vendor as a "normal" NPC.
            category = "friendly_npc"
        elseif info.classification == cfg.CLASS_WORLD_BOSS then
            category = "boss"
        elseif info.classification == cfg.CLASS_RARE
            or info.classification == cfg.CLASS_RARE_ELITE then
            category = "rare"
        elseif info.classification == cfg.CLASS_ELITE then
            category = "elite"
        elseif info.creature_type == cfg.CREATURE_CRITTER
            or info.classification == cfg.CLASS_TRIVIAL
            or info.classification == cfg.CLASS_MINUS then
            category = "critter"
        else
            category = "normal"
        end

        info.category = category
        info.tag = cfg.CLASSIFICATION_TAG[info.classification]

        -- How it fights: melee, ranged or caster, and how sure. On this slow
        -- clock because the answer only moves when a cast is seen, and a
        -- couple of seconds late is soon enough for the first one.
        local fight = P.esp_fight
        if fight then info.fight, info.fight_sure = fight.role(info) end

        unit_cache[guid] = info
        return info
    end

    --- The cached row for a guid, without reading anything: nil when the
    --- unit has not been classified (or has expired). What the fight
    --- observer uses to name the creature a cast came from.
    ---@param guid string|nil
    ---@return table|nil
    function M.cached(guid)
        return guid and unit_cache[guid] or nil
    end

    -- --- objects ------------------------------------------------------------

    --- Which category a world object belongs to, or nil for noise.
    ---
    --- Doors, chairs, campfires and signposts all answer true to can_be_used,
    --- so "usable" alone is not a filter. The name-shape rules in config are
    --- what actually separate a node from scenery.
    ---@param obj game_object
    ---@param guid string
    ---@return string|nil kind
    ---@return string name
    ---@return integer|nil entry_id The object's entry id, read once here so
    --- the quest index can be asked every frame without a native call.
    -- The "extra object names" setting the object answers were made with.
    -- They are cached by guid for as long as the object is around, so a name
    -- typed in did nothing for anything already in range until it left.
    local include_seen = nil

    --- Once per collection pass, before any object is asked about.
    function M.begin_pass()
        local include = P.opt("objects_include", "")
        if include ~= include_seen then
            if include_seen ~= nil then object_cache = {} end
            include_seen = include
        end
    end

    function M.object(obj, guid)
        local cached = object_cache[guid]
        if cached then return cached.kind, cached.name, cached.id end

        local ok, name = pcall(obj.get_name, obj)
        name = (ok and name) or ""

        local ok_id, entry_id = pcall(obj.get_npc_id, obj)
        if not ok_id or type(entry_id) ~= "number" or entry_id <= 0 then entry_id = nil end

        local kind
        if name ~= "" then
            if cfg.is_herb(name) then
                kind = "herb"
            elseif cfg.is_ore(name) then
                kind = "ore"
            elseif cfg.is_container(name) then
                kind = "container"
            else
                -- Anything left is only interesting if it actually holds
                -- something, or if the user named it explicitly.
                local extra = cfg.split_terms(P.opt("objects_include", ""))
                if cfg.matches_any(name, extra) then
                    kind = "object"
                else
                    local has_loot = select(2, pcall(obj.has_loot, obj)) == true
                    if has_loot then kind = "object" end
                end
            end
        end

        object_cache[guid] = { kind = kind, name = name, id = entry_id }
        return kind, name, entry_id
    end

    -- --- the town's npcs, for the routes (1.89.0) -----------------------------
    --
    -- Read-only: the living npcs near you that are not your enemies, with
    -- their npc flags (the client's UNIT_NPC_FLAGS: 0x80 vendor, 0x1000
    -- repair, ...) and where they stand, for modules/routes.lua's vendor and
    -- repair beacon. The flags are read once per guid -- the services an npc
    -- offers do not change -- and only when this is asked, so the ESP's own
    -- pass pays nothing. No title on these clients (the Forever ESP has the
    -- creature cache's); the npc id when the unit has been classified.

    local town, town_n = {}, 0
    ---@param range number yards
    ---@return table[] rows { obj, guid, d, pos, flags, npc }, the same table each call
    function M.town_npcs(range)
        town_n = 0
        range = tonumber(range) or 100
        local units = P.units
        local list = units and units.units and units.units() or {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot(obj)
            local guid = row and row.guid
            if guid and not row.is_self and not row.is_player and not row.is_enemy and not row.dead
                and (row.dist or math.huge) <= range then
                local flags = npc_flags[guid]
                if flags == nil then
                    local ok, value = pcall(function() return obj:get_npc_flags() end)
                    flags = ok and tonumber(value) or 0
                    npc_flags[guid] = flags
                end
                if flags > 0 then
                    town_n = town_n + 1
                    local r = town[town_n] or {}
                    town[town_n] = r
                    local info = unit_cache[guid]
                    r.obj, r.guid, r.d, r.pos, r.flags = obj, guid, row.dist, row.pos, flags
                    r.npc = info and info.npc_id or nil
                end
            end
        end
        for i = town_n + 1, #town do town[i] = nil end
        return town
    end

    -- --- diagnostics --------------------------------------------------------

    --- Class ids seen on players, with a count each. For the debug page: a
    --- portrait with nothing in it is either an id nothing here can name or
    --- art that did not load, and this tells the two apart.
    ---@return table<integer, integer>
    function M.player_classes()
        local out = {}
        for _, info in pairs(unit_cache) do
            if info.is_player then
                local id = info.class_id or 0
                out[id] = (out[id] or 0) + 1
            end
        end
        return out
    end

    function M.stats()
        local units, objects = 0, 0
        for _ in pairs(unit_cache) do units = units + 1 end
        for _ in pairs(object_cache) do objects = objects + 1 end
        return { units = units, objects = objects, cached = units + objects }
    end

    return M
end

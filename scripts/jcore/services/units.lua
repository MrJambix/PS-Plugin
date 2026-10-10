-- JCore / units -- one object-manager sweep per tick, shared by everyone.
--
-- Depends on: util, log, events, cache.
--
-- This is the single biggest reason to run a core at all. core.object_manager
-- .get_visible_objects() returns every object the client holds, and the usual
-- pattern is that each plugin calls it and walks the whole list itself. With a
-- rotation, an ESP plugin and a danger-drawing plugin loaded, that is three
-- full sweeps plus three sets of is_valid / can_attack / get_position calls on
-- every single object, every frame. Those are native round trips, not Lua
-- table reads, and they are what actually shows up in a frame-time profile.
--
-- Here the sweep happens once, first in the update phase, before any plugin
-- job runs. Consumers read the classified result. Nothing else calls
-- get_visible_objects.
--
-- THE SNAPSHOT
-- The sweep does not just classify, it RECORDS. Every object that survives the
-- range cut gets a snapshot row holding what the sweep already had to ask for
-- -- guid, position as three raw numbers, distance from the player -- plus
-- lazily filled fields for the things only some callers want (health, combat
-- reach, name). Every query below then reads those numbers instead of asking
-- the game again.
--
-- The difference is not small. `count_enemies_within(8)` used to call
-- get_position() on every enemy, every call; a rotation asking it four times
-- while walking a priority list paid 4N native calls per frame. It is now a
-- loop over three float arrays and costs nothing worth measuring.
--
-- A note for pre_tick consumers: the pre_tick phase fires BEFORE the update
-- phase, so a pre_tick job reads the PREVIOUS frame's sweep. That is almost
-- never what you want -- decision logic belongs in a tick job.
--
-- STALENESS CONTRACT
-- The arrays this hands out are rebuilt in place every sweep. Read them inside
-- your tick; never hold one across frames. If you need a unit to survive a
-- frame boundary, store its guid and call units.by_guid(guid) next tick --
-- game_object userdata is only trustworthy for the tick that produced it.

return function(rt)
    local util = rt.util
    local events = rt.events
    local cache = rt.cache
    local log = rt.log.for_tag("JCore/units")

    local try = cache.try
    local sqrt = math.sqrt
    local huge = math.huge

    -- Optional: the shipped helper knows the blacklists (critters, training
    -- dummies, event props) that a raw can_attack check does not. Guarded,
    -- because a core build without it must not take the whole runtime down.
    local unit_helper
    do
        local ok, mod = pcall(require, "common/utility/unit_helper")
        if ok then unit_helper = mod end
    end

    local M = {}

    -- core.cpu_time() answers nanoseconds; sweep cost is reported in ms.
    local NS_TO_MS = 1e-6

    -- --- live state ---------------------------------------------------------

    local player = nil
    local player_pos = nil
    local px, py, pz = 0, 0, 0

    local all = {}       -- every visible object
    local units = {}     -- objects that are units (players and npcs)
    local enemies = {}   -- attackable, alive, not blacklisted
    local allies = {}    -- friendly units, alive
    local players = {}   -- player objects, both factions
    local objects = {}   -- non-unit game objects (nodes, chests, herbs)

    -- Parallel coordinate arrays for the two lists that get scanned hardest.
    -- Held as three number arrays rather than one array of vec3 so a range
    -- test is float arithmetic on values already in cache lines, with no
    -- method dispatch and no vec3 allocation.
    local ex, ey, ez, edist = {}, {}, {}, {}
    local ax, ay, az, adist = {}, {}, {}, {}

    -- game_object -> snapshot row. Keyed on the object itself, NOT on its
    -- guid: every guid lookup is another native call, and we hand out the same
    -- object references we stored, so identity is reliable within a sweep.
    local snap = {}

    local by_guid = {}   -- guid -> game_object, this sweep only
    local aura_cache = {} -- guid -> { spell_id -> buff }, built lazily

    local seen_last = {}  -- guid -> true, previous sweep (for add/remove events)
    local seen_now = {}

    local sweep_id = 0
    local last_sweep_time = 0
    local last_sweep_ms = 0

    -- Objects beyond this distance are dropped from the classified lists
    -- entirely. Nothing gameplay-relevant happens past it and the cost of
    -- keeping them is paid by every consumer that iterates.
    --
    -- Two inputs decide it. `configured_range` is the user's setting on the
    -- Core page. `range_requests` is what plugins ask for: an ESP drawing
    -- gathering nodes at 150 yards needs the cache to reach that far, and a
    -- plugin that simply overwrote the setting would silently undo the user's
    -- choice and fight any other plugin doing the same. The effective range is
    -- the largest of them, so raising it is additive and releasing a request
    -- gives the range back.
    local RANGE_FLOOR, RANGE_CEILING = 5.0, 250.0
    local configured_range = 100.0
    local range_requests = {}
    local max_range = configured_range

    local function recompute_range()
        local effective = configured_range
        for _, requested in pairs(range_requests) do
            if requested > effective then effective = requested end
        end
        max_range = util.clamp(effective, RANGE_FLOOR, RANGE_CEILING)
    end

    --- The user-facing setting. Acts as a floor, not an override.
    function M.set_max_range(range)
        configured_range = util.clamp(range or 100.0, RANGE_FLOOR, RANGE_CEILING)
        recompute_range()
    end

    --- A plugin asking the cache to reach at least this far. One request per
    --- owner; calling again replaces that owner's previous figure.
    ---@param owner string
    ---@param range number
    function M.request_range(owner, range)
        range_requests[owner] = util.clamp(range or 0, 0, RANGE_CEILING)
        recompute_range()
    end

    ---@param owner string
    function M.release_range(owner)
        if range_requests[owner] == nil then return end
        range_requests[owner] = nil
        recompute_range()
    end

    function M.get_max_range()
        return max_range
    end

    --- The configured floor and each outstanding request, for diagnostics.
    function M.range_breakdown()
        return configured_range, range_requests, max_range
    end

    -- --- classification -----------------------------------------------------

    -- Both take the sweep's one is_dead answer rather than asking again: the
    -- two used to ask it once each, and units.is_dead a third time, for every
    -- unit that was not an enemy.
    local function is_attackable(obj, local_player, dead)
        if dead then return false end
        if not local_player:can_attack(obj) then return false end
        if unit_helper then
            -- is_valid_enemy folds in the npc blacklist and the on-air /
            -- untargetable states that can_attack still answers true for.
            local ok, valid = pcall(unit_helper.is_valid_enemy, unit_helper, obj)
            if ok then return valid end
        end
        return true
    end

    local function is_friendly(obj, local_player, dead)
        if dead then return false end
        return local_player:is_friend_with(obj)
    end

    local function clear(t)
        for i = #t, 1, -1 do t[i] = nil end
    end

    local function reset_lists()
        clear(all); clear(units); clear(enemies)
        clear(allies); clear(players); clear(objects)
        clear(ex); clear(ey); clear(ez); clear(edist)
        clear(ax); clear(ay); clear(az); clear(adist)
    end

    local function sweep()
        local t0 = core.cpu_time()

        player = core.object_manager.get_local_player()
        if not player or not player:is_valid() then
            -- Loading screen, character select, or a world transition. Empty
            -- everything so a consumer that forgets to nil-check the player
            -- iterates nothing instead of stale objects from the last zone.
            player, player_pos = nil, nil
            px, py, pz = 0, 0, 0
            reset_lists()
            snap, by_guid, aura_cache = {}, {}, {}
            if next(seen_last) then
                for guid in pairs(seen_last) do
                    events.emit("jcore.unit.removed", guid)
                end
                seen_last = {}
            end
            return
        end

        player_pos = player:get_position()
        px, py, pz = player_pos.x, player_pos.y, player_pos.z
        sweep_id = sweep_id + 1
        last_sweep_time = core.time()

        reset_lists()
        snap = {}
        by_guid = {}
        aura_cache = {}
        seen_now = {}

        local visible = core.object_manager.get_visible_objects()
        local player_guid = player:get_guid()
        local range_limit = max_range
        local n_all, n_units, n_enemies, n_allies, n_players, n_objects = 0, 0, 0, 0, 0, 0

        for i = 1, #visible do
            local obj = visible[i]
            -- is_valid is cheap and every later call is undefined without it.
            if obj and obj:is_valid() then
                local pos = obj:get_position()
                if pos then
                    -- Squared comparison first: the square root is only worth
                    -- paying for objects we are actually going to keep, and on
                    -- a busy pull most of the list is out of range.
                    local dx, dy, dz = pos.x - px, pos.y - py, pos.z - pz
                    local sq = dx * dx + dy * dy + dz * dz

                    if sq <= range_limit * range_limit then
                        local dist = sqrt(sq)
                        local guid = obj:get_guid()
                        local is_unit = obj:is_unit()

                        local row = {
                            guid    = guid,
                            pos     = pos,
                            x       = pos.x,
                            y       = pos.y,
                            z       = pos.z,
                            dist    = dist,
                            is_unit = is_unit,
                            obj     = obj,
                        }
                        snap[obj] = row

                        n_all = n_all + 1
                        all[n_all] = obj

                        if guid then
                            by_guid[guid] = obj
                            seen_now[guid] = true
                        end

                        if is_unit then
                            n_units = n_units + 1
                            units[n_units] = obj

                            if obj:is_player() then
                                n_players = n_players + 1
                                players[n_players] = obj
                                row.is_player = true
                            else
                                row.is_player = false
                            end

                            -- The local player is neither an enemy nor an ally
                            -- of itself for query purposes; consumers ask for
                            -- it by name. Leaving it in allies silently skews
                            -- every "allies around me" count by one.
                            if guid ~= player_guid then
                                local dead = obj:is_dead() and true or false
                                row.dead = dead
                                if is_attackable(obj, player, dead) then
                                    row.is_enemy = true
                                    n_enemies = n_enemies + 1
                                    enemies[n_enemies] = obj
                                    ex[n_enemies] = pos.x
                                    ey[n_enemies] = pos.y
                                    ez[n_enemies] = pos.z
                                    edist[n_enemies] = dist
                                elseif is_friendly(obj, player, dead) then
                                    row.is_ally = true
                                    n_allies = n_allies + 1
                                    allies[n_allies] = obj
                                    ax[n_allies] = pos.x
                                    ay[n_allies] = pos.y
                                    az[n_allies] = pos.z
                                    adist[n_allies] = dist
                                end
                            else
                                row.is_self = true
                            end
                        else
                            n_objects = n_objects + 1
                            objects[n_objects] = obj
                        end
                    end
                end
            end
        end

        -- Add / remove events, so plugins can react to a spawn without polling.
        for guid in pairs(seen_now) do
            if not seen_last[guid] then
                events.emit("jcore.unit.added", guid, by_guid[guid])
            end
        end
        for guid in pairs(seen_last) do
            if not seen_now[guid] then
                events.emit("jcore.unit.removed", guid)
            end
        end
        seen_last, seen_now = seen_now, seen_last

        last_sweep_ms = (core.cpu_time() - t0) * NS_TO_MS
    end

    M._sweep = sweep

    -- --- accessors ----------------------------------------------------------

    --- The local player, or nil during a loading screen. Every other accessor
    --- returns an empty list when this is nil, so a consumer may either guard
    --- on it or just iterate.
    ---@return game_object|nil
    function M.player() return player end

    ---@return vec3|nil
    function M.player_position() return player_pos end

    ---@return game_objects_table
    function M.all() return all end

    ---@return game_objects_table
    function M.units() return units end

    ---@return game_objects_table
    function M.enemies() return enemies end

    ---@return game_objects_table
    function M.allies() return allies end

    ---@return game_objects_table
    function M.players() return players end

    ---@return game_objects_table
    function M.objects() return objects end

    --- The sweep's record for a unit, or nil when it was not in this sweep.
    ---
    --- Reading `.x`, `.y`, `.z` and `.dist` off this row is the cheapest way
    --- to ask anything positional, and is what every query below does.
    ---@param unit game_object
    ---@return table|nil
    function M.snapshot(unit)
        return unit and snap[unit] or nil
    end

    --- Was this unit part of the current sweep? A unit that has left the
    --- cache is not necessarily gone -- it may simply be out of range.
    ---@param unit game_object
    ---@return boolean
    function M.is_cached(unit)
        return unit ~= nil and snap[unit] ~= nil
    end

    --- Re-resolves a guid against this sweep, then falls back to the object
    --- manager for anything outside our range cap.
    ---@param guid string
    ---@return game_object|nil
    function M.by_guid(guid)
        if not guid then return nil end
        local obj = by_guid[guid]
        if obj then return obj end
        local resolved = try(core.object_manager.get_object_from_guid, guid)
        if resolved and resolved:is_valid() then return resolved end
        return nil
    end

    --- The guid of a unit, free for anything in this sweep.
    ---@param unit game_object
    ---@return string|nil
    function M.guid(unit)
        if not unit then return nil end
        local row = snap[unit]
        if row then return row.guid end
        return try(unit.get_guid, unit)
    end

    --- The position of a unit, free for anything in this sweep.
    ---@param unit game_object
    ---@return vec3|nil
    function M.position(unit)
        if not unit then return nil end
        local row = snap[unit]
        if row then return row.pos end
        return try(unit.get_position, unit)
    end

    --- Distance from the local player, free when the unit was in this sweep.
    ---@param unit game_object
    ---@return number
    function M.distance(unit)
        if not unit then return huge end
        local row = snap[unit]
        if row then return row.dist end
        if not player_pos then return huge end
        local pos = try(unit.get_position, unit)
        if not pos then return huge end
        local dx, dy, dz = pos.x - px, pos.y - py, pos.z - pz
        return sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- Distance between two units, ignoring the player entirely.
    ---@param a game_object
    ---@param b game_object
    ---@return number
    function M.distance_between(a, b)
        local pa, pb = M.position(a), M.position(b)
        if not pa or not pb then return huge end
        local dx, dy, dz = pa.x - pb.x, pa.y - pb.y, pa.z - pb.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- Hitbox-to-hitbox distance: centre distance less both combat reaches.
    --- This is the figure a melee range check actually wants, and ignoring it
    --- is why large mobs read as out of range when they are not.
    ---@param unit game_object
    ---@return number
    function M.melee_distance(unit)
        if not unit or not player then return huge end
        local gap = M.distance(unit) - M.combat_reach(unit) - M.combat_reach(player)
        return gap > 0 and gap or 0
    end

    -- --- lazily filled snapshot fields --------------------------------------
    --
    -- These are NOT read during the sweep. Health costs two native calls and a
    -- name costs one, per object; paying that for sixty objects so that three
    -- of them can be asked about is the wrong trade. Instead the first caller
    -- pays, and everyone else in the tick reads the stored value.

    local function lazy(unit, field, getter)
        if not unit then return nil end
        local row = snap[unit]
        if not row then return try(getter, unit) end
        local value = row[field]
        if value ~= nil then return value end
        value = try(getter, unit)
        row[field] = (value == nil) and false or value
        return value
    end

    ---@param unit game_object
    ---@return number
    function M.health(unit)
        return lazy(unit, "health", unit and unit.get_health) or 0
    end

    ---@param unit game_object
    ---@return number
    function M.max_health(unit)
        return lazy(unit, "max_health", unit and unit.get_max_health) or 0
    end

    ---@param unit game_object
    ---@return string
    function M.name(unit)
        return lazy(unit, "name", unit and unit.get_name) or ""
    end

    ---@param unit game_object
    ---@return number
    function M.combat_reach(unit)
        return lazy(unit, "reach", unit and unit.get_combat_reach) or 0
    end

    ---@param unit game_object
    ---@return boolean
    function M.is_dead(unit)
        if not unit then return true end
        local row = snap[unit]
        if row and row.dead ~= nil then return row.dead end
        local dead = cache.try_bool(unit.is_dead, unit)
        if row then row.dead = dead end
        return dead
    end

    --- Health as a 0..1 fraction. Returns 0 for a dead or invalid unit so that
    --- "lowest health" comparisons do not accidentally pick a corpse.
    ---@param unit game_object
    ---@return number
    function M.health_fraction(unit)
        if not unit then return 0 end
        local row = snap[unit]
        if row then
            local cached = row.hp
            if cached ~= nil then return cached end
        end

        local value = 0
        if unit:is_valid() and not M.is_dead(unit) then
            local max_hp = M.max_health(unit)
            if max_hp and max_hp > 0 then
                value = util.clamp(M.health(unit) / max_hp, 0, 1)
            end
        end
        if row then row.hp = value end
        return value
    end

    --- Missing health as an absolute figure. What a heal decision wants, since
    --- a 20% deficit on a tank and on a critter are not the same problem.
    ---@param unit game_object
    ---@return number
    function M.health_deficit(unit)
        local max_hp = M.max_health(unit)
        if max_hp <= 0 then return 0 end
        return max_hp - M.health(unit)
    end

    -- --- aura index ---------------------------------------------------------

    --- Builds (once per sweep, per unit) a spell_id -> buff index. A rotation
    --- that checks eight auras on the target would otherwise walk the unit's
    --- full aura array eight times.
    local function auras_for(unit)
        local guid = M.guid(unit)
        if not guid then return nil end
        local index = aura_cache[guid]
        if index then return index end

        index = {}
        local auras = try(unit.get_auras, unit)
        if auras then
            for i = 1, #auras do
                local aura = auras[i]
                if aura and aura.buff_id then
                    -- Keep the longest remaining instance when the same spell
                    -- id appears more than once (multiple casters on a debuff).
                    local existing = index[aura.buff_id]
                    if not existing or (aura.expire_time or 0) > (existing.expire_time or 0) then
                        index[aura.buff_id] = aura
                    end
                end
            end
        end
        aura_cache[guid] = index
        return index
    end

    --- Does this aura belong to `caster_guid`?
    ---
    --- FAIL OPEN, and for the usual reason. The buff row documents a `caster`
    --- field, but whether a given build populates it for every aura is not
    --- something the stub promises. If the field is missing, or reading it
    --- throws, or the caster object will not give up a guid, the answer is
    --- YES -- because the alternative is a rotation that believes none of its
    --- own damage-over-time spells ever landed, and re-applies all of them for
    --- ever.
    ---@param aura buff
    ---@param caster_guid string|nil
    ---@return boolean
    local function aura_is_mine(aura, caster_guid)
        if not caster_guid then return true end

        local caster = aura.caster
        if not caster then return true end

        local ok, guid = pcall(function() return caster:get_guid() end)
        if not ok or not guid then return true end

        return guid == caster_guid
    end

    --- The aura row for `spell_id` on `unit`, or nil.
    ---
    --- `caster_guid` narrows it to auras applied by that unit. A damage-over-
    --- time spell is worth only what its caster put into it -- in Classic it
    --- snapshots spell power on application -- so a second warlock's
    --- Corruption on the same target is not ours, and counting it as ours
    --- means never applying our own.
    ---@param unit game_object
    ---@param spell_id integer|integer[]
    ---@param caster_guid? string
    ---@return buff|nil
    function M.aura(unit, spell_id, caster_guid)
        if not unit or not unit:is_valid() then return nil end
        local index = auras_for(unit)
        if not index then return nil end

        if type(spell_id) == "table" then
            for i = 1, #spell_id do
                local hit = index[spell_id[i]]
                if hit and aura_is_mine(hit, caster_guid) then return hit end
            end
            return nil
        end

        local hit = index[spell_id]
        if hit and aura_is_mine(hit, caster_guid) then return hit end
        return nil
    end

    ---@param unit game_object
    ---@param spell_id integer|integer[]
    ---@return boolean
    function M.has_aura(unit, spell_id, caster_guid)
        return M.aura(unit, spell_id, caster_guid) ~= nil
    end

    --- Every aura on a unit, as the spell_id -> buff index the core built.
    --- Read it, do not keep it: it is dropped at the next sweep.
    ---@param unit game_object
    ---@return table<integer, buff>
    function M.aura_index(unit)
        return auras_for(unit) or {}
    end

    --- Seconds left on an aura, 0 when absent. An aura with no expiry (a
    --- permanent buff or a stance) answers math.huge, so `remaining > 3` reads
    --- correctly for both cases.
    ---@param unit game_object
    ---@param spell_id integer|integer[]
    ---@return number
    function M.aura_remaining(unit, spell_id, caster_guid)
        local aura = M.aura(unit, spell_id, caster_guid)
        if not aura then return 0 end
        -- buff.expire_time is ENGINE TIME IN MILLISECONDS, the same base as
        -- core.game_time(). Subtract first, then convert: converting game_time
        -- to seconds before the subtraction compares a millisecond timestamp
        -- against a second one, which makes every aura read as expired.
        local expires = aura.expire_time
        if not expires or expires <= 0 then return huge end
        return math.max(0, (expires - core.game_time()) / 1000.0)
    end

    ---@param unit game_object
    ---@param spell_id integer|integer[]
    ---@return integer
    function M.aura_stacks(unit, spell_id, caster_guid)
        local aura = M.aura(unit, spell_id, caster_guid)
        if not aura then return 0 end
        return math.max(1, aura.count or 1)
    end

    --- Is any aura from `spell_ids` present? The list form of has_aura, for a
    --- "is this target crowd controlled at all" style check.
    ---@param unit game_object
    ---@param spell_ids integer[]
    ---@return boolean
    function M.has_any_aura(unit, spell_ids)
        return M.aura(unit, spell_ids) ~= nil
    end

    -- --- queries ------------------------------------------------------------

    --- Filtered copy of a list. `origin` defaults to the player position.
    ---
    --- Allocates a table per call, so prefer `count_*` or `for_each_*` in a
    --- hot path where the list itself is not needed.
    ---@param list game_objects_table
    ---@param range number
    ---@param origin? vec3
    ---@param predicate? fun(unit: game_object, distance: number): boolean
    ---@return game_objects_table
    function M.within(list, range, origin, predicate)
        local out = {}
        origin = origin or player_pos
        if not origin then return out end

        local ox, oy, oz = origin.x, origin.y, origin.z
        local limit = range * range
        local n = 0

        for i = 1, #list do
            local unit = list[i]
            local row = snap[unit]
            local ux, uy, uz
            if row then
                ux, uy, uz = row.x, row.y, row.z
            else
                local pos = try(unit.get_position, unit)
                if pos then ux, uy, uz = pos.x, pos.y, pos.z end
            end

            if ux then
                local dx, dy, dz = ux - ox, uy - oy, uz - oz
                local sq = dx * dx + dy * dy + dz * dz
                if sq <= limit then
                    if not predicate or predicate(unit, sqrt(sq)) then
                        n = n + 1
                        out[n] = unit
                    end
                end
            end
        end
        return out
    end

    ---@param range number
    ---@param origin? vec3
    ---@return game_objects_table
    function M.enemies_within(range, origin)
        return M.within(enemies, range, origin)
    end

    ---@param range number
    ---@param origin? vec3
    ---@return game_objects_table
    function M.allies_within(range, origin)
        return M.within(allies, range, origin)
    end

    ---@param range number
    ---@param origin? vec3
    ---@return game_objects_table
    function M.units_within(range, origin)
        return M.within(units, range, origin)
    end

    ---@param range number
    ---@param origin? vec3
    ---@return game_objects_table
    function M.objects_within(range, origin)
        return M.within(objects, range, origin)
    end

    --- Counts against the precomputed coordinate arrays. No allocation and no
    --- native call -- with no origin it is a compare against a stored distance,
    --- which is as cheap as this question gets.
    ---@param range number
    ---@param origin? vec3
    ---@return integer
    function M.count_enemies_within(range, origin)
        local n = 0
        if not origin then
            if not player_pos then return 0 end
            for i = 1, #enemies do
                if edist[i] <= range then n = n + 1 end
            end
            return n
        end

        local ox, oy, oz = origin.x, origin.y, origin.z
        local limit = range * range
        for i = 1, #enemies do
            local dx, dy, dz = ex[i] - ox, ey[i] - oy, ez[i] - oz
            if dx * dx + dy * dy + dz * dz <= limit then n = n + 1 end
        end
        return n
    end

    ---@param range number
    ---@param origin? vec3
    ---@return integer
    function M.count_allies_within(range, origin)
        local n = 0
        if not origin then
            if not player_pos then return 0 end
            for i = 1, #allies do
                if adist[i] <= range then n = n + 1 end
            end
            return n
        end

        local ox, oy, oz = origin.x, origin.y, origin.z
        local limit = range * range
        for i = 1, #allies do
            local dx, dy, dz = ax[i] - ox, ay[i] - oy, az[i] - oz
            if dx * dx + dy * dy + dz * dz <= limit then n = n + 1 end
        end
        return n
    end

    --- Visits every enemy in range without building a list. Use this where a
    --- `within` result would be iterated once and thrown away, which is most
    --- of the time.
    ---@param range number
    ---@param fn fun(unit: game_object, distance: number)
    ---@param origin? vec3
    function M.for_each_enemy_within(range, fn, origin)
        if not origin then
            for i = 1, #enemies do
                local d = edist[i]
                if d <= range then fn(enemies[i], d) end
            end
            return
        end

        local ox, oy, oz = origin.x, origin.y, origin.z
        local limit = range * range
        for i = 1, #enemies do
            local dx, dy, dz = ex[i] - ox, ey[i] - oy, ez[i] - oz
            local sq = dx * dx + dy * dy + dz * dz
            if sq <= limit then fn(enemies[i], sqrt(sq)) end
        end
    end

    ---@param range number
    ---@param fn fun(unit: game_object, distance: number)
    ---@param origin? vec3
    function M.for_each_ally_within(range, fn, origin)
        if not origin then
            for i = 1, #allies do
                local d = adist[i]
                if d <= range then fn(allies[i], d) end
            end
            return
        end

        local ox, oy, oz = origin.x, origin.y, origin.z
        local limit = range * range
        for i = 1, #allies do
            local dx, dy, dz = ax[i] - ox, ay[i] - oy, az[i] - oz
            local sq = dx * dx + dy * dy + dz * dz
            if sq <= limit then fn(allies[i], sqrt(sq)) end
        end
    end

    --- Best unit in `list` by `score_fn`, highest score wins. A nil score
    --- excludes the unit, which is how a caller expresses a hard filter and a
    --- ranking in one pass.
    ---@param list game_objects_table
    ---@param score_fn fun(unit: game_object, distance: number): number|nil
    ---@return game_object|nil best
    ---@return number best_score
    function M.best(list, score_fn)
        local best, best_score = nil, -huge
        for i = 1, #list do
            local unit = list[i]
            local score = score_fn(unit, M.distance(unit))
            if score and score > best_score then
                best, best_score = unit, score
            end
        end
        return best, best_score
    end

    -- The four pickers below return exactly ONE value, deliberately.
    --
    -- Every one of them is written straight into a call: cast_spell(id,
    -- units.nearest_enemy()). Lua splices a multiple return into the argument
    -- list, so handing back a second value would quietly become that call's
    -- next argument -- a distance arriving where a priority was expected, with
    -- no error anywhere. Distance is free from units.distance(unit) afterwards.

    ---@param range? number
    ---@return game_object|nil
    function M.nearest_enemy(range)
        range = range or max_range
        local best, best_dist = nil, huge
        for i = 1, #enemies do
            local d = edist[i]
            if d <= range and d < best_dist then
                best, best_dist = enemies[i], d
            end
        end
        return best
    end

    ---@param range? number
    ---@return game_object|nil
    function M.nearest_ally(range)
        range = range or max_range
        local best, best_dist = nil, huge
        for i = 1, #allies do
            local d = adist[i]
            if d <= range and d < best_dist then
                best, best_dist = allies[i], d
            end
        end
        return best
    end

    ---@param range? number
    ---@return game_object|nil
    function M.lowest_health_ally(range)
        range = range or 40
        local best, best_hp = nil, huge
        for i = 1, #allies do
            if adist[i] <= range then
                local unit = allies[i]
                local hp = M.health_fraction(unit)
                if hp > 0 and hp < best_hp then
                    best, best_hp = unit, hp
                end
            end
        end
        return best
    end

    ---@param range? number
    ---@return game_object|nil
    function M.lowest_health_enemy(range)
        range = range or max_range
        local best, best_hp = nil, huge
        for i = 1, #enemies do
            if edist[i] <= range then
                local unit = enemies[i]
                local hp = M.health_fraction(unit)
                if hp > 0 and hp < best_hp then
                    best, best_hp = unit, hp
                end
            end
        end
        return best
    end

    --- Highest maximum health in range. The usual stand-in for "which of these
    --- is the boss" when no encounter data is available.
    ---@param range? number
    ---@return game_object|nil
    function M.biggest_enemy(range)
        range = range or max_range
        local best, best_hp = nil, -1
        for i = 1, #enemies do
            if edist[i] <= range then
                local unit = enemies[i]
                local hp = M.max_health(unit)
                if hp > best_hp then best, best_hp = unit, hp end
            end
        end
        return best
    end

    --- Number of enemies that would be caught by a circle of `radius` centred
    --- on `unit`. The usual "where do I drop the AoE" question.
    ---@param unit game_object
    ---@param radius number
    ---@return integer
    function M.cluster_size(unit, radius)
        local origin = M.position(unit)
        if not origin then return 0 end
        return M.count_enemies_within(radius, origin)
    end

    --- The enemy whose position catches the most others inside `radius`.
    ---
    --- O(n squared) over enemies in range, which is fine for the tens of units
    --- a sweep holds and is why the range argument exists. Returns the unit,
    --- its position and the count, so a caller can cast at either the unit or
    --- the ground under it.
    ---@param radius number
    ---@param range? number How far out to consider centres.
    ---@return game_object|nil best
    ---@return vec3|nil position
    ---@return integer count
    function M.best_cluster(radius, range)
        range = range or max_range
        local limit = radius * radius
        local best, best_count = nil, 0

        for i = 1, #enemies do
            if edist[i] <= range then
                local cx, cy, cz = ex[i], ey[i], ez[i]
                local count = 0
                for j = 1, #enemies do
                    local dx, dy, dz = ex[j] - cx, ey[j] - cy, ez[j] - cz
                    if dx * dx + dy * dy + dz * dz <= limit then count = count + 1 end
                end
                if count > best_count then
                    best, best_count = enemies[i], count
                end
            end
        end

        if not best then return nil, nil, 0 end
        return best, M.position(best), best_count
    end

    --- Is `target` inside a cone of `half_angle` degrees centred on the way
    --- `unit` is facing? The check behind every frontal-cone ability.
    ---@param unit game_object
    ---@param target game_object
    ---@param half_angle number degrees
    ---@return boolean
    function M.is_facing(unit, target, half_angle)
        local origin = M.position(unit)
        local dest = M.position(target)
        if not origin or not dest then return false end

        local rotation = try(unit.get_rotation, unit)
        if not rotation then return false end

        local dx, dy = dest.x - origin.x, dest.y - origin.y
        if dx == 0 and dy == 0 then return true end

        local bearing = math.atan2 and math.atan2(dy, dx) or math.atan(dy, dx)
        local delta = bearing - rotation
        -- Wrap into [-pi, pi] so the comparison is on the shorter arc; without
        -- this a target at 179 degrees reads as 359 degrees off.
        while delta > math.pi do delta = delta - 2 * math.pi end
        while delta < -math.pi do delta = delta + 2 * math.pi end

        return math.abs(delta) <= math.rad(half_angle or 45)
    end

    --- Enemies inside a frontal cone from the player.
    ---@param range number
    ---@param half_angle number degrees
    ---@return game_objects_table
    function M.enemies_in_cone(range, half_angle)
        local out = {}
        if not player then return out end
        local n = 0
        for i = 1, #enemies do
            if edist[i] <= range and M.is_facing(player, enemies[i], half_angle) then
                n = n + 1
                out[n] = enemies[i]
            end
        end
        return out
    end

    --- Enemies in a rectangle from the player out to `range`, `width` wide.
    --- The shape most line abilities actually use.
    ---@param range number
    ---@param width number
    ---@return game_objects_table
    function M.enemies_in_line(range, width)
        local out = {}
        if not player or not player_pos then return out end

        local rotation = try(player.get_rotation, player)
        if not rotation then return out end

        local fx, fy = math.cos(rotation), math.sin(rotation)
        local half = width * 0.5
        local n = 0

        for i = 1, #enemies do
            local dx, dy = ex[i] - px, ey[i] - py
            -- Along-axis distance, then perpendicular offset from that axis.
            local along = dx * fx + dy * fy
            if along >= 0 and along <= range then
                local across = math.abs(dx * -fy + dy * fx)
                if across <= half then
                    n = n + 1
                    out[n] = enemies[i]
                end
            end
        end
        return out
    end

    --- Enemies sorted nearest first. Built once per tick and handed out by
    --- reference, so ten callers cost one sort.
    local sorted_cache = cache.new("units.sorted_enemies", { scope = "tick" })

    ---@return game_objects_table
    function M.enemies_by_distance()
        local hit = sorted_cache:get(true)
        if hit then return hit end

        local out = {}
        for i = 1, #enemies do out[i] = enemies[i] end
        util.stable_sort_by(out, function(unit) return M.distance(unit) end)
        return sorted_cache:put(true, out)
    end

    -- --- the player's pet -----------------------------------------------------
    --
    -- THE PET ON FOREVER (1.5.14). get_pet answered nil on all 746,898 calls
    -- the JCore API recorder caught on Forever, a hunter's among them, so
    -- every pet feature there was blind: the AIO never sent or mended a pet,
    -- and a mob hitting it never read as "on your pet". On Forever only, when
    -- get_pet has nothing, the pet is looked for: first in the player's
    -- minion list (get_all_minions), then among the swept units, for one that
    -- says it is a pet (is_pet answers there) and names the player as its
    -- owner (get_owner). Neither get_all_minions nor get_owner had been called
    -- on Forever when this was written; the recorder will show what they
    -- answer. A pet once found is kept while it lives; a search that finds
    -- nothing waits PET_SEARCH_EVERY seconds before the next, so a class with
    -- no pet pays a few calls every two seconds. Every other client asks
    -- get_pet exactly as before.
    local pet_cache = cache.new("units.player_pet", { scope = "tick" })
    local PET_SEARCH_EVERY = 2.0
    local forever_client = nil
    local found_pet, pet_searched_at = nil, -math.huge

    local function on_forever()
        if forever_client ~= nil then return forever_client end
        local world = rt.world
        if not (world and world.client) then return false end
        local ok, c = pcall(world.client)
        if not ok or type(c) ~= "table" then return false end
        forever_client = c.forever == true
        return forever_client
    end

    local function lives(u)
        return u ~= nil and try(u.is_valid, u) == true and try(u.is_dead, u) ~= true
    end

    local function search_pet(p, my_guid)
        local minions = try(p.get_all_minions, p)
        if type(minions) == "table" then
            for i = 1, #minions do
                local m = minions[i]
                if lives(m) and try(m.is_pet, m) == true then return m end
            end
        end
        for i = 1, #units do
            local u = units[i]
            if u ~= p and try(u.is_pet, u) == true then
                local owner = try(u.get_owner, u)
                if owner ~= nil and (owner == p or M.guid(owner) == my_guid) and lives(u) then return u end
            end
        end
        return nil
    end

    --- The player's pet, or nil. get_pet, and on Forever the search above.
    ---@return game_object|nil
    function M.player_pet()
        local p = player
        if not p then return nil end
        local value, hit = pet_cache:get(true)
        if hit then return value end
        local pet = try(p.get_pet, p)
        if pet == nil and on_forever() then
            if found_pet and lives(found_pet) then
                pet = found_pet
            else
                found_pet = nil
                local t = core.time()
                if t - pet_searched_at >= PET_SEARCH_EVERY then
                    pet_searched_at = t
                    found_pet = search_pet(p, M.guid(p))
                    pet = found_pet
                end
            end
        end
        return pet_cache:put(true, pet)
    end

    -- --- names and rank, on every client (1.6.0) ------------------------------
    --
    -- A plugin asks these the same way on every client and JCore answers per
    -- client. Era: get_name and get_classification, exactly as before. Forever:
    -- get_name is "" and get_classification 0 for every unit there, so the
    -- name comes from services/names.lua (the client when it answers, names
    -- learned from our casts and kept by npc id, the creature cache) and the
    -- rank from the client's creature cache (services/creatures.lua).

    local era_name = M.name

    ---@param unit game_object
    ---@return string
    function M.name(unit)
        if not on_forever() then return era_name(unit) end
        if not unit then return "" end
        local row = snap[unit]
        if row and row.name ~= nil then return row.name or "" end
        local names = rt.names
        local n = names and names.of and names.of(unit) or nil
        if row then row.name = n or false end
        return n or ""
    end

    --- WoW's classification id: 0 normal, 1 elite, 2 rare elite, 3 boss,
    --- 4 rare, 5 trivial, 6 minus.
    ---@param unit game_object
    ---@return integer
    function M.classification(unit)
        if not unit then return 0 end
        local creatures = rt.creatures
        if on_forever() and creatures and creatures.classification_of then
            return lazy(unit, "classification", creatures.classification_of) or 0
        end
        return lazy(unit, "classification", unit.get_classification) or 0
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            sweep_id   = sweep_id,
            sweep_ms   = last_sweep_ms,
            age        = core.time() - last_sweep_time,
            all        = #all,
            units      = #units,
            enemies    = #enemies,
            allies     = #allies,
            players    = #players,
            objects    = #objects,
            max_range  = max_range,
        }
    end

    return M
end

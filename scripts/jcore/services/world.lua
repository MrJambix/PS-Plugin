-- JCore / world -- where we are, what kind of content it is, and what is on it.
--
-- Depends on: util, log, cache, events.
--
-- Zone facts split cleanly by how often they can change, and the cache scopes
-- here follow that split rather than a blanket timeout:
--
--   per tick  -- map id, difficulty, keystone level. Cheap, and read by
--                anything that branches on content type.
--   per zone  -- map and instance names, encounter tables, challenge info.
--                Dropped wholesale on jcore.zone.changed, because after a
--                zone change every one of them is about a place we have left.
--   per TTL   -- things with no event to hang off, such as the completed quest
--                list, which is large and changes rarely.
--
-- The zone-change wiring is the point of the module. Without it every consumer
-- ends up writing its own "has the map id changed since last frame" poll, and
-- they all disagree about when the new zone started.

return function(rt)
    local cache = rt.cache
    local events = rt.events
    local log = rt.log.for_tag("JCore/world")

    local try = cache.try
    local try_bool = cache.try_bool

    local M = {}

    local tick = cache.new("world.tick", { scope = "tick" })
    local zone = cache.new("world.zone", { scope = "manual" })
    local slow = cache.new("world.slow", { scope = "ttl", ttl = 10.0 })

    -- The zone cache holds answers about a place. Once we are somewhere else,
    -- all of them are wrong at the same instant.
    events.on("jcore.zone.changed", function()
        zone:clear()
        slow:clear()
        log.debug("zone caches dropped")
    end, { owner = "jcore", priority = 0 })

    local function tick_get(key, fn, a)
        local value, hit = tick:get(key)
        if hit then return value end
        return tick:put(key, try(fn, a))
    end

    local function zone_get(key, fn, a)
        local value, hit = zone:get(key)
        if hit then return value end
        return zone:put(key, try(fn, a))
    end

    -- --- where --------------------------------------------------------------

    ---@return integer|nil
    function M.map_id()
        return tick_get("map_id", core.get_map_id)
    end

    ---@return string
    function M.map_name()
        return zone_get("map_name", core.get_map_name) or ""
    end

    ---@return integer|nil
    function M.instance_id()
        return tick_get("instance_id", core.get_instance_id)
    end

    ---@return string
    function M.instance_name()
        return zone_get("instance_name", core.get_instance_name) or ""
    end

    --- "party", "raid", "pvp", "arena", "scenario" or "none", as the client
    --- names it.
    ---@return string
    function M.instance_type()
        return zone_get("instance_type", core.get_instance_type) or "none"
    end

    ---@return integer|nil
    function M.difficulty_id()
        return tick_get("difficulty", core.get_difficulty_id)
    end

    ---@return string
    function M.difficulty_name()
        return zone_get("difficulty_name", core.get_difficulty_name) or ""
    end

    ---@return boolean
    function M.in_instance()
        local kind = M.instance_type()
        return kind ~= "none" and kind ~= "" and kind ~= nil
    end

    ---@return boolean
    function M.in_raid_instance()
        return M.instance_type() == "raid"
    end

    ---@return boolean
    function M.in_dungeon()
        return M.instance_type() == "party"
    end

    ---@return boolean
    function M.in_arena()
        return M.instance_type() == "arena"
    end

    ---@return boolean
    function M.in_battleground()
        return M.instance_type() == "pvp"
    end

    ---@return boolean
    function M.in_pvp()
        local kind = M.instance_type()
        return kind == "arena" or kind == "pvp"
    end

    -- --- mythic plus --------------------------------------------------------

    ---@return integer
    function M.keystone_level()
        return tick_get("keystone", core.get_keystone_level) or 0
    end

    ---@return integer|nil
    function M.keystone_map_id()
        return tick_get("keystone_map", core.get_keystone_map_id)
    end

    --- True while a Mythic+ run is actually in progress, which is not the same
    --- as standing in a dungeon that has a keystone level.
    ---@return boolean
    function M.in_keystone_run()
        return (M.active_challenge_map_id() or 0) > 0
    end

    ---@return integer|nil
    function M.active_challenge_map_id()
        return tick_get("challenge_map", core.world.get_active_challenge_map_id)
    end

    ---@return active_keystone_info|nil
    function M.keystone_info()
        return tick_get("keystone_info", core.world.get_active_keystone_info)
    end

    ---@return challenge_completion_info|nil
    function M.challenge_completion()
        return tick_get("challenge_done", core.world.get_challenge_completion_info)
    end

    -- --- encounters ---------------------------------------------------------

    --- The boss list for a map. Static per zone, so it is resolved once and
    --- kept until we leave.
    ---@param ui_map_id? integer Defaults to the current map.
    ---@return encounter_info[]
    function M.encounters(ui_map_id)
        ui_map_id = ui_map_id or M.map_id()
        if not ui_map_id then return {} end
        local key = "encounters." .. tostring(ui_map_id)
        local value, hit = zone:get(key)
        if hit then return value or {} end
        return zone:put(key, try(core.world.get_encounters_on_map, ui_map_id) or {})
    end

    ---@return table[]
    function M.boss_frames()
        return tick_get("boss_frames", core.object_manager.get_boss_frames) or {}
    end

    ---@return integer
    function M.boss_count()
        return tick_get("boss_count", core.object_manager.get_boss_count) or 0
    end

    --- Is an encounter running? The boss frame count is the reading that
    --- actually tracks a pull, rather than any zone-level flag.
    ---@return boolean
    function M.in_encounter()
        return M.boss_count() > 0
    end

    -- --- delves -------------------------------------------------------------

    ---@return boolean
    function M.in_delve()
        return tick_get("in_delve", core.delves and core.delves.is_in_delve) and true or false
    end

    ---@return boolean
    function M.delve_complete()
        return tick_get("delve_done", core.delves and core.delves.is_delve_complete) and true or false
    end

    -- --- terrain ------------------------------------------------------------

    ---@return boolean
    function M.is_flyable()
        local value, hit = zone:get("flyable")
        if hit then return value or false end
        return zone:put("flyable", try_bool(core.world.is_flyable_area))
    end

    ---@return boolean
    function M.is_advanced_flyable()
        local value, hit = zone:get("adv_flyable")
        if hit then return value or false end
        return zone:put("adv_flyable", try_bool(core.world.is_advanced_flyable_area))
    end

    --- Ground height under a position.
    ---
    --- Keyed on the position rounded to a yard: a pathing consumer asks about
    --- thousands of points that differ in the third decimal place, and an
    --- exact key would never hit. A yard of granularity is well inside what
    --- the answer is useful to.
    ---@param pos vec3
    ---@return number|nil
    local height_cache = cache.new("world.height", { scope = "ttl", ttl = 30.0 })
    function M.height_at(pos)
        if not pos then return nil end
        -- floor() before formatting: "%d" against a float is a truncation on
        -- LuaJIT but a hard error on 5.3+, and this runs on both.
        local key = math.floor(pos.x) .. ":" .. math.floor(pos.y)
        local value, hit = height_cache:get(key)
        if hit then return value end
        return height_cache:put(key, try(core.get_height_for_position, pos))
    end

    -- --- raid markers -------------------------------------------------------

    ---@param index integer 1..8
    ---@return boolean
    function M.is_raid_marker_active(index)
        return tick_get("marker." .. tostring(index),
            core.world.is_raid_marker_active, index) and true or false
    end

    ---@param index integer 1..8
    ---@param position vec3
    function M.place_raid_marker(index, position)
        return try(core.world.place_raid_marker, index, position)
    end

    ---@param index integer
    function M.clear_raid_marker(index)
        return try(core.world.clear_raid_marker, index)
    end

    -- --- client -------------------------------------------------------------
    --
    -- Build facts. These cannot change without a restart, so they are resolved
    -- once and held for the session.

    local client = cache.new("world.client", { scope = "manual" })

    local function client_get(key, fn)
        local value, hit = client:get(key)
        if hit then return value end
        return client:put(key, try(fn))
    end

    --- Does the loader have core.<ns>.<name> (core.<name> when ns is nil)?
    --- Looked up, never called; a missing namespace is a no.
    local function has_native(ns, name)
        local ok, fn = pcall(function()
            local t = core
            if ns then t = type(t) == "table" and t[ns] or nil end
            return type(t) == "table" and t[name] or nil
        end)
        return ok and type(fn) == "function"
    end

    ---@return string
    function M.game_version()
        return client_get("version", core.get_game_version) or ""
    end

    ---@return string
    function M.exact_game_version()
        return client_get("exact_version", core.get_exact_game_version) or ""
    end

    --- What the running client can do, by product. get_game_version answers
    --- one word per product ("Vanilla", "Tbc", "Mop", "Titan", "Midnight",
    --- "Forever"), and the private servers answer like their Blizzard
    --- counterpart.
    ---
    --- Forever (Classic+, 2026) is the one that breaks assumptions: a level-60
    --- classic world on the retail engine. Its client has retail's API and not
    --- the classic globals the core calls on every other classic build, so:
    ---   trait_talents        talents are trait trees (get_active_talents,
    ---                        get_talent_tree_ids); get_talent_info is {}
    ---   classic_quest_log    false: JCore does not walk the classic quest log
    ---                        there. Before the 2026-10-06 core it read empty
    ---                        (get_num_quest_log_entries 0, get_quest_log_title
    ---                        empty); that core answers it, but its objective
    ---                        rows (the leader boards) are not documented for
    ---                        Forever, so the quests come from the quest-ID
    ---                        readers (quest_ids) where the core has them, and
    ---                        from is_on_quest per id where it does not
    ---   completed_quest_list false before the 2026-10-06 core:
    ---                        get_all_completed_quest_ids was always {} (Retail
    ---                        too). True from that core on
    ---   cancel_buff          false before the 2026-10-06 core:
    ---                        core.input.cancel_buff silently did nothing (it
    ---                        looked the aura up through UnitBuff only). True
    ---                        from that core on
    --- The core itself (1.9.0). The 2026-10-06 core (branch lua_requests_06_10)
    --- fixed most of the above. Nothing reports a core's date, so it is known by
    --- the functions it added:
    ---   core_20261006        true: core.get_server_time,
    ---                        core.quests.get_quest_log_quest_ids or
    ---                        core.character.get_xp is there
    ---   quest_ids            true: the quest-ID readers are there
    ---                        (core.quests.get_quest_log_quest_ids,
    ---                        get_quest_objectives, is_quest_complete): your
    ---                        quests, their objectives and whether each is ready
    ---                        to hand in, from the game, on every client
    --- And what the API recorder found there (1.6.0), so a plugin asks about
    --- the behaviour rather than the client's name:
    ---   combat_log           false: COMBAT_LOG_EVENT_UNFILTERED arrives with no
    ---                        arguments (13,696 of 13,696 recorded)
    ---   auto_repeat_once     true: Auto Shot fires one shot per press, so each
    ---                        shot wants the next press (a hunter, 2026-10-03)
    ---   auto_start_melee     true: the auto-attack helper takes a START at
    ---                        range as "already running" while melee Attack is
    ---                        on (it reads the player's one attack flag), so
    ---                        the melee attack must be stopped first
    ---   unit_names           false: get_name is not to be relied on. It
    ---                        answered "" for every unit until patch
    ---                        1.60.1.70205; since then about half the reads
    ---                        are real names and the rest "" (the recorder,
    ---                        38 sessions). services/names.lua takes a real
    ---                        answer first and fills in the rest.
    ---   recording            true: the API recorder runs (Forever, and only with
    ---                        the Jambix Debug plugin there, 1.7.0)
    --- Read once; a client cannot change without a restart.
    ---@return { version: string, exact: string, forever: boolean, retail: boolean, trait_talents: boolean, classic_quest_log: boolean, completed_quest_list: boolean, cancel_buff: boolean, core_20261006: boolean, quest_ids: boolean, combat_log: boolean, auto_repeat_once: boolean, auto_start_melee: boolean, unit_names: boolean, recording: boolean }
    function M.client()
        local value, hit = client:get("profile")
        if hit and value then return value end
        local version = tostring(M.game_version() or "")
        local forever = version == "Forever"
        local retail = version == "Midnight"
        local quest_ids = has_native("quests", "get_quest_log_quest_ids")
            and has_native("quests", "get_quest_objectives")
            and has_native("quests", "is_quest_complete")
        local fixed = has_native(nil, "get_server_time")
            or has_native("quests", "get_quest_log_quest_ids")
            or has_native("character", "get_xp")
        return client:put("profile", {
            version = version,
            exact = tostring(M.exact_game_version() or ""),
            forever = forever,
            retail = retail,
            trait_talents = forever or retail,
            classic_quest_log = not forever,
            completed_quest_list = fixed or not (forever or retail),
            cancel_buff = fixed or not forever,
            core_20261006 = fixed,
            quest_ids = quest_ids,
            combat_log = not forever,
            auto_repeat_once = forever,
            auto_start_melee = forever,
            unit_names = not forever,
            -- The recorder is Jambix Debug's (1.7.0): without that plugin there
            -- is nothing to trace to, and the AIO does not build its lines.
            recording = forever and rt.recorder ~= nil and rt.recorder.available == true,
        })
    end

    ---@return boolean
    function M.is_forever()
        return M.client().forever
    end

    ---@return string
    function M.region()
        return client_get("region", core.get_game_region) or ""
    end

    ---@return string
    function M.realm()
        return client_get("realm", core.character.get_realm_name) or ""
    end

    --- Round-trip latency in milliseconds. Worth reading before any decision
    --- about when to start a cast that has to land before something else.
    ---@return number
    function M.ping()
        return tick_get("ping", core.get_ping) or 0
    end

    ---@return table|nil
    function M.local_time()
        return tick_get("local_time", core.get_local_time)
    end

    ---@return boolean
    function M.main_menu_open()
        return tick_get("main_menu", core.is_main_menu_open) and true or false
    end

    -- --- corpse and death ---------------------------------------------------

    ---@return vec3|nil
    function M.corpse_position()
        return tick_get("corpse", core.game_ui.get_corpse_position)
    end

    ---@return number
    function M.resurrect_delay()
        return tick_get("res_delay", core.game_ui.get_resurrect_corpse_delay) or 0
    end

    -- --- quests -------------------------------------------------------------

    --- Every completed quest id. A large table and expensive to build, so it
    --- is held on a long timeout rather than rebuilt per frame.
    ---
    --- On a core before 2026-10-06, always {} on Forever and Retail, whose
    --- clients have no GetQuestsCompleted (client().completed_quest_list is
    --- false there); that core reads C_QuestLog.GetAllCompletedQuestIDs on
    --- them, and lifted a limit that answered {} past about 8000 quests.
    --- is_quest_complete answers one id on every client.
    ---@return integer[]
    function M.completed_quest_ids()
        local value, hit = slow:get("completed_quests")
        if hit then return value or {} end
        return slow:put("completed_quests", try(core.game_ui.get_all_completed_quest_ids) or {})
    end

    ---@param quest_id integer
    ---@return boolean
    function M.is_quest_complete(quest_id)
        return try_bool(core.quests.is_quest_flagged_completed, quest_id)
    end

    ---@param quest_id integer
    ---@return boolean
    function M.is_on_quest(quest_id)
        return try_bool(core.quests.is_on_quest, quest_id)
    end

    -- --- battleground / arena score -----------------------------------------

    ---@return string|nil
    function M.battlefield_state()
        return tick_get("bf_state", core.game_ui.get_battlefield_state)
    end

    ---@return number
    function M.battlefield_run_time()
        return tick_get("bf_time", core.game_ui.get_battlefield_run_time) or 0
    end

    ---@return any
    function M.match_state()
        return tick_get("match_state", core.game_ui.get_active_match_state)
    end

    ---@return any
    function M.match_winner()
        return tick_get("match_winner", core.game_ui.get_active_match_winner)
    end

    ---@return pvp_personal_rated_info|nil
    function M.personal_rated_info()
        return tick_get("rated_info", core.game_ui.get_active_match_personal_rated_info)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            map_id     = M.map_id(),
            map_name   = M.map_name(),
            instance   = M.instance_type(),
            difficulty = M.difficulty_name(),
            keystone   = M.keystone_level(),
            bosses     = M.boss_count(),
            ping       = M.ping(),
        }
    end

    return M
end

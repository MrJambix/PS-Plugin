-- JCore / bridge -- every remaining core namespace, guarded and memoised.
--
-- Depends on: util, log, cache.
--
-- The hand-written services cover what rotations and ESP plugins actually use.
-- This module covers the rest of the platform: the auction house, the mailbox,
-- trade skills, pet battles, the group finder, taxi nodes, quests, professions.
-- None of those is hot, none of them wants a bespoke abstraction, and all of
-- them are things somebody will eventually need.
--
-- WHAT THE MIRROR CHANGES
-- Each namespace is passed through cache.wrap_namespace, which gives every
-- call the same three properties:
--
--   * It cannot raise. A build without that namespace, or a call that throws
--     because a window is closed, answers nil instead of taking the caller's
--     frame down with it. Half of this API only works while a particular UI
--     frame is open, and finding that out via a raise is the usual way a
--     plugin dies.
--   * Readers are memoised. get_/is_/has_/can_/num_ calls with plain
--     arguments are cached; a loop asking about sixty auction rows asks once.
--   * Writers are not. Anything that is not obviously a reader passes straight
--     through every time, because caching an action would swallow the second
--     call and that failure is silent.
--
-- WHAT IT DOES NOT CHANGE
-- Shapes and argument order are exactly the native ones, so the API stubs in
-- scripts/.api are the documentation for everything here. This is a safety and
-- speed layer, not a redesign.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local log = rt.log.for_tag("JCore/bridge")

    local M = {}

    -- Cache lifetime per namespace.
    --
    -- "tick" is right for anything that tracks the world. A UI-driven
    -- namespace is different: the auction results behind an open window do not
    -- change between frames, but a plugin walking two hundred rows would
    -- otherwise re-ask for every one of them on the frame after it started. A
    -- short timeout holds those across frames without ever being stale enough
    -- to matter.
    local NAMESPACES = {
        { name = "game_ui",       source = core.game_ui,                          scope = "tick" },
        { name = "character",     source = core.character,                        scope = "tick" },
        { name = "world",         source = core.world,                            scope = "tick" },
        { name = "object_manager", source = core.object_manager,                  scope = "tick" },
        { name = "spell_book",    source = core.spell_book,                       scope = "tick" },
        { name = "inventory",     source = core.inventory,                        scope = "tick" },
        { name = "graphics",      source = core.graphics,                         cache = false },
        { name = "input",         source = core.input,                            cache = false },
        { name = "party",         source = core.party,                            scope = "tick" },
        { name = "taxi",          source = core.taxi,                             scope = "ttl", ttl = 2.0 },
        { name = "quests",        source = core.quests,                           scope = "ttl", ttl = 1.0 },
        { name = "delves",        source = core.delves,                           scope = "tick" },
        { name = "lfg_list",      source = core.lfg_list,                         scope = "ttl", ttl = 2.0 },
        { name = "mail",          source = core.mail,                             scope = "ttl", ttl = 2.0 },
        { name = "auction_house", source = core.auction_house,                    scope = "ttl", ttl = 2.0 },
        { name = "trade_skill",   source = core.trade_skill,                      scope = "ttl", ttl = 2.0 },
        { name = "profession",    source = core.profession,                       scope = "ttl", ttl = 5.0 },
        { name = "pet_battle",    source = core.pet_battle,                       scope = "tick" },
        { name = "damage_meter",  source = core.damage_meter,                     scope = "ttl", ttl = 1.0 },
    }

    local present = {}

    for i = 1, #NAMESPACES do
        local entry = NAMESPACES[i]
        M[entry.name] = cache.wrap_namespace(entry.name, entry.source, {
            scope = entry.scope,
            ttl   = entry.ttl,
            cache = entry.cache,
        })
        if type(entry.source) == "table" then
            present[#present + 1] = entry.name
        end
    end

    -- Graphics and input are mirrored with caching OFF, and that is not an
    -- oversight. Both are almost entirely side effects -- drawing a line,
    -- pressing a key -- and the few readers they do have (is_line_of_sight,
    -- is_key_pressed) are cached properly by services/geometry and
    -- services/input, which know what the right key is. A blanket memo here
    -- would only be able to cache them wrongly.

    -- --- top-level calls ----------------------------------------------------
    --
    -- The functions that live directly on `core` rather than in a namespace.
    -- Mirrored by name because `core` also holds the namespaces themselves and
    -- a blanket sweep would wrap those as well.
    local TOP_LEVEL = {
        "get_ping", "time", "game_time", "delta_time", "cpu_time", "cpu_ticks",
        "cpu_ticks_per_second", "get_cursor_position", "get_map_id",
        "get_instance_id", "get_difficulty_id", "get_keystone_level",
        "get_keystone_map_id", "get_instance_name", "get_difficulty_name",
        "get_instance_type", "get_map_name", "get_height_for_position",
        "is_main_menu_open", "get_game_version", "get_exact_game_version",
        "get_game_region", "get_local_time", "get_owning_plugin_name",
        "is_textbox_focused", "get_mouse_wheel_delta", "play_sound_by_id",
        "stop_sound_by_handle", "set_window_foremost", "read_asset_file",
        "read_file", "get_file_size", "read_dir",
    }

    do
        local source = {}
        for i = 1, #TOP_LEVEL do
            local name = TOP_LEVEL[i]
            if type(core[name]) == "function" then source[name] = core[name] end
        end
        -- Cached per tick, except that the clocks are excluded below: a memoised
        -- core.time() would hand the same instant to everyone for a whole frame,
        -- which is right for a game fact and wrong for a clock being used to
        -- measure how long something took.
        M.client = cache.wrap_namespace("core", source, { scope = "tick" })

        for _, clock in ipairs({ "time", "game_time", "delta_time", "cpu_time",
            "cpu_ticks", "cpu_ticks_per_second" }) do
            if type(core[clock]) == "function" then
                M.client[clock] = core[clock]
            end
        end
    end

    -- --- escape hatch -------------------------------------------------------

    --- Calls anything on `core` by dotted path, guarded.
    ---
    --- For a namespace this module does not mirror, on a build that has it:
    --- `bridge.call("some_new_namespace.get_thing", 1)`. Never cached, because
    --- nothing here knows whether the call is a reader.
    ---
    --- Prefer a mirrored namespace where one exists. This is the door for the
    --- call that does not have one yet.
    ---@param path string Dotted, relative to `core`.
    ---@return any
    function M.call(path, a, b, c, d)
        local target = core
        local fn_name = nil

        for part in tostring(path):gmatch("[^%.]+") do
            if fn_name then
                target = target and target[fn_name]
            end
            fn_name = part
        end

        if type(target) ~= "table" then return nil end
        local fn = target[fn_name]
        if type(fn) ~= "function" then
            log.fmt("debug", "core.%s is not available on this build", path)
            return nil
        end

        local ok, result = pcall(fn, a, b, c, d)
        if not ok then
            log.fmt("debug", "core.%s raised: %s", path, tostring(result))
            return nil
        end
        return result
    end

    --- Does a dotted path exist on this build? The check to write before
    --- relying on anything newer than the core version a plugin targets.
    ---@param path string
    ---@return boolean
    function M.has(path)
        local target = core
        for part in tostring(path):gmatch("[^%.]+") do
            if type(target) ~= "table" then return false end
            target = target[part]
        end
        return target ~= nil
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        table.sort(present)
        return { namespaces = present, count = #present }
    end

    log.fmt("debug", "bridged %d namespace(s)", #present)

    return M
end

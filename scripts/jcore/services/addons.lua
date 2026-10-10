-- JCore / addons -- every supported in-game addon, guarded and cached.
--
-- Depends on: util, log, cache.
--
-- Each addon namespace is mirrored through cache.wrap_namespace, which gives
-- three things at once: a call that cannot raise into a plugin frame when the
-- addon is missing, a nil answer instead of an error when a build does not
-- expose that namespace at all, and per-tick memoisation of every reader. A
-- plugin asking "is BigWigs loaded" in a tick job costs one native call per
-- frame however many times it asks, rather than one per ask.
--
-- On top of the mirrors sit the abstractions that are the actual point of this
-- module. BigWigs and ExBoss both answer "what is the boss about to do", in
-- two namespaces, with two incompatible meanings for the `key` field. A plugin
-- that wants boss timers should not have to know either of those things, so
-- M.boss_timers() merges them into one shape and M.next_ability() answers the
-- question a cooldown-holding rotation actually has.

return function(rt)
    local util = rt.util
    local cache = rt.cache
    local log = rt.log.for_tag("JCore/addons")

    local M = {}

    local source = core.addons or {}

    -- Whether an addon is loaded changes at most once per session in practice,
    -- but a plugin can be loaded before the addon finishes initialising -- so
    -- these are cached on a short timeout rather than for the session.
    local loaded_cache = cache.new("addons.loaded", { scope = "ttl", ttl = 5.0 })
    local tick = cache.new("addons.tick", { scope = "tick" })

    -- --- mirrored namespaces ------------------------------------------------
    --
    -- Listed explicitly rather than mirrored by iteration, so this file names
    -- what it supports and a namespace that appears on a later build is an
    -- obvious one-line addition rather than a silent absence.
    local NAMESPACES = {
        "bigwigs", "exboss", "details", "questie", "zygor", "rested_xp",
        "conroc", "maxdps", "swing_timer", "arena_core", "mdt", "tsm",
        "timeline_reminders",
    }

    for i = 1, #NAMESPACES do
        local name = NAMESPACES[i]
        M[name] = cache.wrap_namespace("addons." .. name, source[name], { scope = "tick" })
    end

    --- Calls a mirrored namespace function, tolerating its absence.
    ---
    --- wrap_namespace only mirrors keys the build actually has, so a call that
    --- exists in the documentation but not in this client is simply nil -- and
    --- indexing through to call it would raise. Everything below goes through
    --- here rather than assuming.
    ---@param ns table
    ---@param fn_name string
    ---@return any
    local function call(ns, fn_name, a)
        local fn = ns and ns[fn_name]
        if type(fn) ~= "function" then return nil end
        return fn(a)
    end

    --- Is an addon present and initialised?
    ---@param name string One of the mirrored namespace names.
    ---@return boolean
    function M.is_loaded(name)
        local value, hit = loaded_cache:get(name)
        if hit then return value or false end

        local ns = source[name]
        if type(ns) ~= "table" or type(ns.is_loaded) ~= "function" then
            return loaded_cache:put(name, false)
        end
        local ok, result = pcall(ns.is_loaded)
        return loaded_cache:put(name, ok and result and true or false)
    end

    --- Every addon this runtime knows about, and whether it is there. The
    --- first thing to look at when an integration is silently doing nothing.
    ---@return table<string, boolean>
    function M.available()
        local out = {}
        for i = 1, #NAMESPACES do
            out[NAMESPACES[i]] = M.is_loaded(NAMESPACES[i])
        end
        return out
    end

    -- --- boss timers --------------------------------------------------------

    ---@class jcore_boss_timer
    ---@field source string        "bigwigs" or "exboss"
    ---@field text string          Ability name as the addon labels it.
    ---@field remaining number     Seconds until it fires.
    ---@field duration number      Full bar length in seconds.
    ---@field emphasized boolean   The addon considers this one important.
    ---@field spell_id integer|nil Only ExBoss records one; nil from BigWigs.

    --- Boss ability timers from every timer addon present, merged and sorted
    --- soonest first.
    ---
    --- `remaining` is used rather than `expire_time` deliberately: BigWigs
    --- reports expiry against engine time and ExBoss against the addon clock,
    --- so the two absolute figures are not comparable and merging on them
    --- would interleave the lists wrongly. Seconds remaining means the same
    --- thing in both.
    ---@return jcore_boss_timer[]
    function M.boss_timers()
        local value, hit = tick:get("boss_timers")
        if hit then return value or {} end

        local out = {}
        local n = 0

        if M.is_loaded("bigwigs") and call(M.bigwigs, "has_active_bars") then
            local bars = call(M.bigwigs, "get_bars")
            if bars then
                for i = 1, #bars do
                    local bar = bars[i]
                    n = n + 1
                    out[n] = {
                        source     = "bigwigs",
                        text       = bar.text or "",
                        remaining  = bar.remaining or 0,
                        duration   = bar.duration or 0,
                        emphasized = bar.is_emphasized and true or false,
                        -- BigWigs keys bars with an opaque handle, NOT a spell
                        -- id. Surfacing it as spell_id would be a lie that a
                        -- consumer would then look up and get nothing for.
                        spell_id   = nil,
                    }
                end
            end
        end

        if M.is_loaded("exboss") and call(M.exboss, "has_active_bars") then
            local bars = call(M.exboss, "get_bars")
            if bars then
                for i = 1, #bars do
                    local bar = bars[i]
                    n = n + 1
                    out[n] = {
                        source     = "exboss",
                        text       = bar.text or "",
                        remaining  = bar.remaining or 0,
                        duration   = bar.duration or 0,
                        emphasized = bar.is_emphasized and true or false,
                        -- ExBoss does record a spell id here, using 0 for
                        -- "none", which is not a spell and should not be
                        -- handed on as one.
                        spell_id   = (bar.key and bar.key > 0) and bar.key or nil,
                    }
                end
            end
        end

        util.stable_sort_by(out, function(row) return row.remaining end)
        return tick:put("boss_timers", out)
    end

    --- The next boss ability due, or nil when nothing is timed.
    ---@param only_emphasized? boolean Consider only bars the addon flagged.
    ---@return jcore_boss_timer|nil
    function M.next_ability(only_emphasized)
        local timers = M.boss_timers()
        for i = 1, #timers do
            if not only_emphasized or timers[i].emphasized then return timers[i] end
        end
        return nil
    end

    --- Is a named ability due within `seconds`?
    ---
    --- Matches on a case-insensitive substring of the bar text, because the
    --- label an addon shows is not stable enough to compare exactly and a
    --- consumer knows the ability by name rather than by bar.
    ---@param name_fragment string
    ---@param seconds number
    ---@return boolean
    function M.ability_within(name_fragment, seconds)
        local needle = tostring(name_fragment):lower()
        local timers = M.boss_timers()
        for i = 1, #timers do
            local row = timers[i]
            if row.remaining <= seconds and row.text:lower():find(needle, 1, true) then
                return true
            end
        end
        return false
    end

    -- --- swing timers -------------------------------------------------------

    --- Seconds until the next main-hand swing, or math.huge when unknown.
    ---
    --- Returning huge rather than zero matters: a caller asking "can I fit a
    --- cast before my next swing" must not be told yes by a missing addon.
    ---@return number
    function M.swing_remaining()
        if not M.is_loaded("swing_timer") then return math.huge end
        local info = call(M.swing_timer, "get_player_mainhand_info")
        if not info or not info.expiration_time then return math.huge end
        local remaining = info.expiration_time - core.time()
        return remaining > 0 and remaining or 0
    end

    ---@return number
    function M.offhand_swing_remaining()
        if not M.is_loaded("swing_timer") then return math.huge end
        local info = call(M.swing_timer, "get_player_offhand_info")
        if not info or not info.expiration_time then return math.huge end
        local remaining = info.expiration_time - core.time()
        return remaining > 0 and remaining or 0
    end

    -- --- rotation suggestions -----------------------------------------------

    --- What another rotation addon would press next, when one is installed.
    --- Useful as a fallback or as a cross-check, never as a replacement for a
    --- plugin's own priority list.
    ---@return integer|nil spell_id
    ---@return string|nil from
    function M.suggested_spell()
        if M.is_loaded("maxdps") then
            local id = call(M.maxdps, "get_next_spell")
            if id and id > 0 then return id, "maxdps" end
        end
        if M.is_loaded("conroc") then
            local spells = call(M.conroc, "get_suggested_spells")
            if spells and spells[1] then
                local first = spells[1]
                local id = type(first) == "table" and (first.spell_id or first.id) or first
                if id then return id, "conroc" end
            end
        end
        return nil, nil
    end

    -- --- damage meter -------------------------------------------------------
    --
    -- The built-in meter is not an addon namespace, but a consumer looking for
    -- damage numbers looks here, so it is mirrored alongside them.

    M.damage_meter = cache.wrap_namespace("damage_meter", core.damage_meter, { scope = "tick" })

    ---@return boolean
    function M.damage_meter_available()
        local value, hit = loaded_cache:get("damage_meter")
        if hit then return value or false end
        local fn = core.damage_meter and core.damage_meter.is_available
        if type(fn) ~= "function" then return loaded_cache:put("damage_meter", false) end
        local ok, result = pcall(fn)
        return loaded_cache:put("damage_meter", ok and result and true or false)
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local present = {}
        for name, is_there in pairs(M.available()) do
            if is_there then present[#present + 1] = name end
        end
        table.sort(present)
        return {
            loaded  = present,
            count   = #present,
            timers  = #M.boss_timers(),
        }
    end

    return M
end

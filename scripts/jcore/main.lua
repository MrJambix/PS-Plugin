-- JCore / main -- boot the runtime, own the native callbacks, publish the API.
--
-- This file is the only place that touches core.register_*. Everything else
-- schedules through services rather than registering its own native hook, so
-- ordering across plugins is decided here instead of by load order.
--
-- MODULE WIRING
-- Modules are factories: each file returns `function(rt) ... return M end` and
-- receives the runtime table. That gives explicit, acyclic dependencies with no
-- circular requires and no module needing to know its own path on disk. The
-- order of the build_* calls below IS the dependency graph; do not reorder them
-- without reading what each one pulls off `rt`.

---@diagnostic disable: lowercase-global

local VERSION = "1.8.1"

-- --- require shim -----------------------------------------------------------
--
-- Loader builds differ on whether a package-local require resolves relative to
-- the package folder or to the scripts root. Rather than pick one and break on
-- the other, try both and cache what worked.

local PACKAGE = "jcore"
local resolved_prefix = nil

-- Declared before the loaders so build_module closes over it as an upvalue. A
-- local declared further down would be a different binding, and build_module
-- would silently read a nil global instead.
local rt = {
    VERSION    = VERSION,
    started_at = core.time(),
    ready      = false,
}

--- Requires a package-local module, trying each path convention once and then
--- reusing whichever one worked.
---
--- Accepts a factory (`function(rt)`) or a plain table. Almost every module
--- here is a factory; lib/util is a leaf with no dependencies and is a plain
--- table, so both shapes have to be legal or the loader rejects it.
---@param relative_path string
---@return function|table
local function load_module(relative_path)
    local candidates
    if resolved_prefix then
        candidates = { resolved_prefix .. relative_path }
    else
        candidates = { relative_path, PACKAGE .. "/" .. relative_path, "./" .. relative_path }
    end

    local errors = {}
    for i = 1, #candidates do
        local ok, result = pcall(require, candidates[i])
        local kind = type(result)
        if ok and (kind == "function" or kind == "table") then
            if not resolved_prefix then
                resolved_prefix = candidates[i]:sub(1, #candidates[i] - #relative_path)
            end
            return result
        end
        errors[#errors + 1] = ok
            and ("returned " .. kind .. " from " .. candidates[i])
            or tostring(result)
    end

    error("JCore: could not load module '" .. relative_path .. "': " .. table.concat(errors, " | "))
end

--- load_module for a factory module: loads it and applies it to the runtime.
---@param relative_path string
---@return table
local function build_module(relative_path)
    local factory = load_module(relative_path)
    if type(factory) ~= "function" then
        error("JCore: module '" .. relative_path .. "' is not a factory")
    end
    return factory(rt)
end

-- --- runtime ----------------------------------------------------------------
--
-- This order IS the dependency graph. Each module reads the ones above it off
-- `rt`; none reads one below it.

rt.util = load_module("lib/util")          -- leaf: a plain table, not a factory
rt.json = load_module("lib/json")          -- leaf, same shape as util
rt.image = load_module("lib/image")        -- leaf: BLP/TGA decoders, PNG encoder
rt.inflate = load_module("lib/inflate")    -- leaf: zlib/DEFLATE decoder, for the game's archives
rt.log = build_module("lib/log")
-- Every error the core catches, for Jambix Debug's fault log when it listens
-- (1.8.1). Before events and the scheduler: every handler and job runs
-- through it. A plain pcall while nobody listens.
rt.faults = build_module("lib/faults")
rt.events = build_module("lib/events")
rt.scheduler = build_module("lib/scheduler")
rt.registry = build_module("lib/registry")
rt.menu_ns = build_module("lib/menu_ns")

-- The memoisation layer the services read through. It sits between the leaf
-- libraries and the services because units asks it for everything and nothing
-- below it asks units for anything. Missing this line stopped the whole core
-- booting: units takes cache.try at build time, so a nil there is not a
-- degraded cache, it is a runtime that never starts.
rt.cache = build_module("lib/cache")

-- FOREVER'S LINE OF SIGHT (1.8.0). On Forever core.graphics.is_line_of_sight
-- is replaced in place, for every package, with geometry's model-free ray
-- (read at call time): the client asserts inside its own ray there, and the
-- loader's packed Lua asks it too. Built before the recorder, so the recorder
-- wraps the guard rather than the native, and before spells and cast, which
-- load the loader's libraries. See services/sightguard.
rt.sightguard = build_module("services/sightguard")

-- THE DEBUG PLUGIN (1.7.0). The Forever API recorder, the loot study and the
-- Dump page live in scripts/jambix_debug, which users do not get. When that
-- folder is there they are built here with this runtime -- the recorder at
-- this point, because it wraps every core.* function in place and must come
-- before any service that keeps a native it was handed at build time --
-- bridge's cache.wrap_namespace does -- or those calls go around it
-- unrecorded. Without it rt.recorder, rt.lootstudy and rt.dump are nil and
-- world.client().recording is false. Load order is not guaranteed and a
-- require across package roots does not work on every loader build, so the
-- global comes first, then the require; a plugin that runs after JCore calls
-- JCore.attach_debug (at the bottom), which builds them late.
local debug_plugin = nil
do
    local D = _G.JambixDebug
    if type(D) ~= "table" then
        for _, path in ipairs({ "jambix_debug/main", "../jambix_debug/main" }) do
            local ok, result = pcall(require, path)
            if ok and type(result) == "table" then
                D = result
                break
            end
        end
    end
    if type(D) == "table" then debug_plugin = D end
end

--- Builds one of the debug plugin's factories with this runtime. nil when the
--- plugin is absent, or when the factory raises: a broken debug tool must not
--- stop the core booting (the error is logged once the log is up).
local debug_errors = {}
local function build_debug(name)
    local factory = debug_plugin and debug_plugin[name]
    if type(factory) ~= "function" then return nil end
    local ok, m = pcall(factory, rt)
    if ok and type(m) == "table" then return m end
    debug_errors[#debug_errors + 1] = name .. ": " .. tostring(m)
    return nil
end

-- The fault log first (1.8.1): it listens on rt.faults from here on, and it
-- keeps the natives it writes with before the recorder wraps them.
rt.faultlog = build_debug("faults")
rt.recorder = build_debug("recorder")

rt.units = build_module("services/units")
rt.spells = build_module("services/spells")
rt.combat = build_module("services/combat")
-- Reads units and combat (time-to-die) at factory time; nothing above reads
-- it. What every hostile is doing, with a memory, for everyone.
rt.enemies = build_module("services/enemies")
rt.cast = build_module("services/cast")
rt.draw = build_module("services/draw")

-- The second tier of services. Every one of them reads the five above and
-- none reads another below it, with four exceptions that each take their
-- dependency as an upvalue at FACTORY time and would capture nil if moved:
--   geometry -> draw      (forwards world-to-screen to the draw cache)
--   missiles -> geometry  (distance and time-to-impact maths)
--   input    -> cast      (shares the priority bands)
--   nav      -> input     (movement is a leased channel)
rt.player = build_module("services/player")
rt.world = build_module("services/world")
rt.group = build_module("services/group")
-- Reads enemies (which mobs are in the fight) and group (who can hold
-- threat) at factory time, so it sits below both.
rt.threat = build_module("services/threat")
rt.inventory = build_module("services/inventory")
rt.geometry = build_module("services/geometry")
rt.missiles = build_module("services/missiles")
rt.addons = build_module("services/addons")
rt.input = build_module("services/input")
rt.nav = build_module("services/nav")
rt.net = build_module("services/net")
rt.storage = build_module("services/storage")
-- The yard-by-yard map round the player (1.12.0). Takes units, player, world,
-- geometry, input, storage and draw as upvalues at factory time, so it sits
-- below storage, the last of them.
rt.walkmap = build_module("services/walkmap")
rt.bridge = build_module("services/bridge")
-- The game's own archives. Reads storage (its file index) and the inflate
-- library; the asset registry below resolves "game:" references through it.
rt.casc = build_module("services/casc")

-- The overlay UI and the asset registry sit on top of everything above:
-- assets reads net, storage, draw and image; ui reads draw, input, storage
-- and assets. ui_widgets and ui_compat extend rt.ui in place and return it,
-- so the order of those three is a dependency too.
rt.assets = build_module("services/assets")
rt.ui = build_module("services/ui")
build_module("services/ui_widgets")
build_module("services/ui_compat")
-- Forever only (inert elsewhere): the client's own creature cache, read on
-- first use. Reads world and assets then, not at factory time.
rt.creatures = build_module("services/creatures")
-- 1.6.0: what a unit is called and whose mob it is, answered per client. Both
-- read world, storage, group, combat and enemies at call time, not here.
rt.names = build_module("services/names")
rt.loot = build_module("services/loot")
-- What Forever reads as 0 (energy, rage, combo points), counted from our casts.
rt.power = build_module("services/power")
-- The debug plugin's other two (1.7.0; see THE DEBUG PLUGIN above): the
-- loot study, then the Dump page that holds its switch. Both read loot, world
-- and storage at call time. nil without the plugin.
rt.lootstudy = build_debug("lootstudy")
rt.dump = build_debug("dump")
-- Our own quest database (scripts_data/jcore/questdb), read on first use.
rt.questdb = build_module("services/questdb")
-- Where an enemy's spell is about to land (1.8.0): scripts_data/jcore/telegraphs,
-- read on first use. Reads units, enemies, missiles and geometry each tick, and
-- storage and world at call time.
rt.telegraphs = build_module("services/telegraphs")
-- Forever only (inert elsewhere): the game's own Lua through the loader's
-- execute and read_lua_*, probed before it is used. Reads world, storage,
-- events and the scheduler.
rt.gamelua = build_module("services/gamelua")
-- The reaction framework (1.8.0): rules as data, scored per lane, with a
-- memory and a journal. One engine per plugin, built on the plugin's own
-- handle when it first asks for ctx.react; reads nothing at factory time.
rt.react = build_module("services/react")

local api = build_module("api")

local log = rt.log.core
for i = 1, #debug_errors do log.fmt("warn", "Jambix Debug: %s", debug_errors[i]) end
debug_errors = {}

-- --- internal scheduling ----------------------------------------------------
--
-- Priorities here are deliberately far outside the range a plugin would pick,
-- so no plugin can accidentally wedge itself between two core stages. A plugin
-- runs at 100 by default and everything it needs is already built by then.

local CORE_FIRST = -1000000
local CORE_EARLY = -999000
local CORE_LAST  = 1000000

-- EACH CORE STAGE FAILS ON ITS OWN. Until 1.5.3 the stages below shared two
-- scheduler jobs, so one that threw skipped every stage after it for the tick
-- -- lease expiry among them, which is what lets go of a held movement key --
-- and five throws in a row paused the whole job for up to 30 seconds. The
-- first job also turns the cache epoch over, so that pause froze every
-- tick-scoped answer the rotations read: health, cooldowns, the target. Now a
-- stage that throws is logged (the first time, then every 600th) and skipped
-- for that tick, and the jobs themselves never fail.
local stage_failures = {}
local stage_marks = {}
local function stage(name, fn)
    -- Through rt.faults (1.8.1): a plain pcall unless Jambix Debug listens.
    local faults = rt.faults
    local deep = faults.deep
    local mark = deep and stage_marks[name]
    if deep and not mark then
        mark = "stage " .. name
        stage_marks[name] = mark
    end
    if deep then faults.enter(mark) end
    local ok, err = faults.call("stage", name, fn)
    if deep then faults.leave(mark) end
    if ok then
        if stage_failures[name] then stage_failures[name] = nil end
        return
    end
    local n = (stage_failures[name] or 0) + 1
    stage_failures[name] = n
    if n == 1 or n % 600 == 0 then
        log.fmt("error", "core stage %s failed (%d in a row): %s", name, n, tostring(err))
    end
end
rt.core_stage_failures = stage_failures

rt.scheduler.add("update", function()
    -- The cache epoch turns over BEFORE the sweep, not after. Everything
    -- memoised for a tick has to expire before the first thing that could read
    -- it runs, and the sweep is that first thing. An integer bump: it cannot
    -- throw, and it must never be skipped.
    rt.cache._new_tick()

    -- The unit sweep is the first thing that happens each tick. Every other
    -- stage, core or plugin, reads what it produces.
    stage("units", rt.units._sweep)
    stage("spells", rt.spells._new_tick)
end, { owner = "jcore", priority = CORE_FIRST })

rt.scheduler.add("update", function()
    stage("combat", rt.combat._poll)
    -- After combat, because a row's time-to-die comes from it.
    stage("enemies", rt.enemies._poll)
    -- After enemies, because the boards are built from this tick's rows.
    stage("threat", rt.threat._poll)
    -- After enemies: who fought what, and whose mob it is (Forever; a no-op elsewhere).
    stage("loot", rt.loot._poll)
    -- After loot: the corpse study reads its attempt (Jambix Debug only).
    if rt.lootstudy then stage("lootstudy", rt.lootstudy._poll) end
    -- Leases expire here rather than lazily on access, so a channel nobody is
    -- asking about is still handed back when its holder goes quiet.
    stage("input", rt.input._poll)
    stage("missiles", rt.missiles._poll)
    -- After enemies (their casts) and missiles (what is in the air).
    stage("telegraphs", rt.telegraphs._poll)
    stage("nav", rt.nav._poll)
    -- After input (its walker renews the movement lease) and after the sweep
    -- (the player's position and the objects it maps).
    stage("walkmap", rt.walkmap._poll)
end, { owner = "jcore", priority = CORE_EARLY })

rt.scheduler.add("update", function()
    -- Last, after every plugin has had its say this tick.
    rt.cast._arbitrate()
end, { owner = "jcore", priority = CORE_LAST })

rt.scheduler.add("render", function()
    rt.draw._begin_frame()
end, { owner = "jcore", priority = CORE_FIRST })

-- The UI frame opens right after the draw queue and closes right before it
-- flushes, so every plugin render job sits between the two and the popup,
-- tooltip and toasts paint above every window.
rt.scheduler.add("render", function()
    rt.ui._begin_frame()
end, { owner = "jcore", priority = CORE_FIRST + 1 })

rt.scheduler.add("render", function()
    rt.ui._end_frame()
end, { owner = "jcore", priority = CORE_LAST - 1 })

-- The walk map's overlay (Core > World > Show walk map). Nothing while off.
rt.scheduler.add("render", function()
    stage("walkmap overlay", rt.walkmap._render)
end, { owner = "jcore", priority = 0 })

-- Asset loads and addon scans run on their own per-frame budget, and are
-- the first thing dropped on a heavy frame.
rt.scheduler.add("update", function()
    rt.assets._pump()
end, { owner = "jcore", priority = CORE_LAST - 1, deferrable = true })

rt.scheduler.add("render", function()
    rt.draw._flush()
end, { owner = "jcore", priority = CORE_LAST })

-- --- native callbacks -------------------------------------------------------
--
-- Each pass is marked on rt.faults as it begins and ends (1.8.1): nothing
-- while nobody listens; with Jambix Debug, its crash black box writes the
-- mark ahead of the work, so a game that dies outright says in which pass.

local faults = rt.faults

-- THE WORLD GATE (1.8.1). Nothing below runs until a character is in the
-- world. The loader can start the plugins at the character select screen,
-- where the game has not loaded its world tables yet, and a native that
-- reads one there (a spell, map or zone name) is the client's
-- ASSERT(IsLoaded()) in WowClientDB2.cpp, which no pcall survives: the game
-- died 0.2 s after the plugins loaded there (2026-10-12 13:26). Only the
-- update pass asks for the player, so the character screen costs one
-- native a frame; once open the gate stays open, so a loading screen or a
-- logout later runs as it always has. The offline harness has no player
-- unless a test makes one, so it sets JCORE_NO_WORLD_GATE.
local world_open = rawget(_G, "JCORE_NO_WORLD_GATE") == true

local function probe_world()
    if world_open then return true end
    local ok, p = pcall(core.object_manager.get_local_player)
    if not ok or p == nil then return false end
    local ok_valid, valid = pcall(p.is_valid, p)
    if not ok_valid or not valid then return false end
    world_open = true
    log.info("in the world: the plugins' passes start")
    rt.events.emit("jcore.world.open")
    return true
end

--- True once a character has been in the world since JCore loaded.
---@return boolean
function rt.in_world() return world_open end

core.register_on_update_callback(function()
    if not world_open and not probe_world() then return end
    faults.enter("update")
    rt.scheduler.on_update()
    faults.leave("update")
end)

core.register_on_pre_tick_callback(function()
    if not world_open then return end
    faults.enter("pre_tick")
    rt.scheduler.on_pre_tick()
    faults.leave("pre_tick")
end)

core.register_on_render_callback(function()
    if not world_open then return end
    faults.enter("render")
    rt.scheduler.on_render()
    faults.leave("render")
end)

-- The window pass is painted over the game's own frames, the render pass
-- under them. The screen UI the render pass queued is painted here, so no
-- JCore window sits behind the bags or the map (1.8.1). A loader without
-- the pass keeps painting everything in the render pass.
if type(core.register_on_render_window_callback) == "function" then
    core.register_on_render_window_callback(function()
        if not world_open then return end
        faults.enter("window")
        stage("ui over game", rt.draw._flush_window)
        faults.leave("window")
    end)
end

core.register_on_render_menu_callback(function()
    if not world_open then return end
    faults.enter("menu")
    rt.scheduler.on_render_menu()
    faults.leave("menu")
end)

core.register_on_render_control_panel_callback(function()
    if not world_open then return end
    faults.enter("control_panel")
    rt.scheduler.on_render_control_panel()
    faults.leave("control_panel")
end)

-- Re-broadcast the native spell-cast hook onto the bus, so a plugin that wants
-- it does not have to register a second native callback and does not get
-- dropped when it raises.
core.register_on_spell_cast_callback(function(data)
    if not world_open then return end
    faults.enter("spell_cast")
    rt.events.emit("jcore.spell.cast", data)
    faults.leave("spell_cast")
end)

-- THE LEGIT-CAST CALLBACK IS NOT REGISTERED AT BOOT (1.8.1). The loader
-- reports "legit" casts (the player's own presses: 1678 of 5400 recorded
-- calls followed no call of ours) by hooking the game's input functions. On
-- 2026-10-12 Forever died in Shadowfang Keep on key presses in combat:
-- TurnOrActionStop and the strafes call a native hook that converts the
-- target's name to a string, and in an instance fight that name is a secret
-- value, so the client raises a fatal script error. The black box had every
-- pass of ours closed. Nothing of ours used this callback (only Jambix
-- Debug's recorder listened), so it is no longer asked for, in case asking
-- is what puts those hooks in. JCore.enable_legit_casts() registers it on
-- demand.
local legit_registered = false
function rt.enable_legit_casts()
    if legit_registered then return true end
    if type(core.register_on_legit_spell_cast_callback) ~= "function" then return false end
    legit_registered = true
    core.register_on_legit_spell_cast_callback(function(...)
        if not world_open then return end
        faults.enter("legit_spell_cast")
        rt.events.emit("jcore.spell.cast.legit", ...)
        faults.leave("legit_spell_cast")
    end)
    return true
end

-- Game events come by the hundred in a fight: marked one by one only in the
-- deep mode, which marks every handler anyway.
core.register_on_game_event_callback(function(event_name, args)
    -- Behind the world gate too: a handler re-reading spell tooltips on a
    -- login event would ask the same tables.
    if not world_open then return end
    -- Caches bound to this event name are dropped BEFORE any subscriber runs.
    -- A handler for BAG_UPDATE that reads the bag index must see the new
    -- contents, and it would not if invalidation were just another subscriber
    -- competing on priority.
    rt.cache._on_game_event(event_name)

    -- Forwarded verbatim. Note the documented hole behaviour: a nil argument
    -- leaves a GAP in `args` rather than an entry, so subscribers must index
    -- positionally and must not use ipairs or the length operator on it.
    rt.events.emit("jcore.game_event", event_name, args)
    -- And as a per-event topic, which is what almost everyone actually wants.
    rt.events.emit("jcore.game_event." .. event_name, args)
end)

-- A talent swap, a level-up or a spellbook change invalidates cached spell
-- ranges and cast times.
rt.events.on("jcore.game_event.SPELLS_CHANGED", function()
    rt.spells._invalidate_static()
    rt.player._invalidate_session()
end, { owner = "jcore", priority = 0 })

-- A spec or talent change rewrites which spells exist and which of them the
-- player has. Both are held for the session, so both have to be dropped here
-- or a rotation keeps running the build the character no longer has.
for _, event in ipairs({
    "PLAYER_SPECIALIZATION_CHANGED",
    "ACTIVE_TALENT_GROUP_CHANGED",
    "TRAIT_CONFIG_UPDATED",
    "PLAYER_TALENT_UPDATE",
    "PLAYER_LEVEL_UP",
}) do
    rt.events.on("jcore.game_event." .. event, function()
        rt.spells._invalidate_static()
        rt.player._invalidate_session()
    end, { owner = "jcore", priority = 0 })
end

-- Casting is gated off while the player is not in a state where a cast could
-- possibly land. Doing it here means no plugin has to check for it.
rt.events.on("jcore.player.died", function()
    rt.cast.set_enabled(false)
    -- A corpse holding movement keys down is the one failure mode here that
    -- the user cannot do anything about, so control is dropped with casting.
    rt.nav.stop()
    rt.walkmap.stop()
    rt.input.stop_all()
end, { owner = "jcore", priority = 0 })

rt.events.on("jcore.player.revived", function()
    rt.cast.set_enabled(true)
end, { owner = "jcore", priority = 0 })

-- Housekeeping that has no event to hang off. One timer, not one per service:
-- the work is trivial and a second repeating scheduler entry costs more than
-- the calls it would make.
rt.scheduler.every(5.0, function()
    rt.net._prune()
    rt.storage.flush()
end, "jcore")

-- --- diagnostics page -------------------------------------------------------

-- Row caps for the live readouts. Menu content is retained mode, so these are
-- fixed at declaration; a run with more plugins than PLUGIN_ROWS simply shows
-- the first PLUGIN_ROWS of them.
local PLUGIN_ROWS = 12
local COST_ROWS = 20

-- Rows the cost readout reserves at the bottom for its summary lines: units,
-- draw, cache, http, and up to four control leases. The per-owner list is
-- given whatever is left, so adding a summary line means raising this too or
-- the last one silently falls off the end of the page.
local COST_FOOTER_ROWS = 13

local function build_diagnostics_page()
    local page = rt.menu_ns.for_plugin("jcore", "Core", { icon = "settings" })
    if not page.available then return page end

    page:title(function()
        return string.format("JCore %s   up %.0fs   %d plugin(s)",
            VERSION, core.time() - rt.started_at, rt.registry.count())
    end, { size = "subtitle", align = "left" })

    local general = page:section("Runtime", "settings", { column = "left" })
    general:dropdown("log_level", "Log level",
        { "trace", "debug", "info", "warn", "error" }, 3)
    general:slider("update_budget", "Update budget", 2, 32, 8, "ms")
    general:slider("unit_range", "Unit cache range", 20, 200, 100, "yd")
    general:toggle("log_to_file", "Mirror log to file", false)

    -- The update phase against its own budget, so an overrun is visible as a
    -- full bar rather than as a number nobody is reading.
    general:progress("budget_meter", "Update load", {
        source = function()
            local stats = rt.scheduler.phase_stats().update
            if not stats then return 0 end
            return rt.util.clamp(stats.avg_ms / rt.scheduler.get_update_budget(), 0, 1)
        end,
    })

    page:on_change("log_level", function(index)
        local names = { "trace", "debug", "info", "warn", "error" }
        rt.log.set_level(names[index] or "info")
    end)
    page:on_change("update_budget", function(value)
        rt.scheduler.set_update_budget(value)
    end)
    page:on_change("unit_range", function(value)
        rt.units.set_max_range(value)
    end)
    page:on_change("log_to_file", function(value)
        rt.log.set_file_sink(value, "jcore")
    end)

    local world = page:section("World", "globe", { column = "right" })
    world:label("Live unit-cache and draw counters below.")
    -- Paints what the walk map knows round the player: walls red, the tops
    -- of steps (tables, benches, cliffs) deep orange, learned (stuck) spots
    -- magenta, holes light orange, deep water blue, objects yellow,
    -- and the line ahead green or red. Mapping costs nothing until a plugin
    -- asks; this switch asks.
    world:toggle("walkmap_overlay", "Show walk map", false)
    page:on_change("walkmap_overlay", function(value)
        rt.walkmap.set_overlay(value == true)
    end)
    rt.walkmap.set_overlay(page:get_or("walkmap_overlay", false) == true)

    page:title("Plugins", { size = "body", align = "left" })
    page:live_lines(PLUGIN_ROWS, function()
        local rows = rt.registry.list()
        if #rows == 0 then return { "Nothing registered." } end

        local out = {}
        for i = 1, math.min(#rows, PLUGIN_ROWS) do
            local row = rows[i]
            local note = ""
            if row.missing then
                note = "  waiting on " .. row.missing
            elseif row.error then
                note = "  ERROR: " .. row.error
            end
            out[#out + 1] = string.format("%s  %-28s v%-8s %-9s%s",
                row.enabled and "[on] " or "[off]",
                row.name, row.version, row.state, note)
        end
        return out
    end)

    page:title("Frame cost", { size = "body", align = "left" })
    page:live_lines(COST_ROWS, function()
        local out = {}
        local phases = rt.scheduler.phase_stats()

        for _, phase in ipairs({ "pre_tick", "update", "render", "menu" }) do
            local s = phases[phase]
            if s then
                out[#out + 1] = string.format("%-10s avg %5.2fms   peak %5.2fms",
                    phase, s.avg_ms, s.max_ms)
            end
        end

        local owners = rt.scheduler.owner_stats()
        local room = COST_ROWS - #out - COST_FOOTER_ROWS
        for i = 1, math.min(#owners, room) do
            local row = owners[i]
            out[#out + 1] = string.format("  %-26s avg %5.2fms   peak %5.2fms   (%d jobs)",
                row.owner, row.avg_ms, row.max_ms, row.jobs)
        end

        local u = rt.units.stats()
        out[#out + 1] = string.format("units: %d enemies, %d allies, %d objects (sweep %.2fms)",
            u.enemies, u.allies, u.objects, u.sweep_ms)

        local e = rt.enemies.stats()
        out[#out + 1] = string.format(
            "enemies: %d tracked, %d read this tick -- %d attacking, %d inbound, %d casting, %d fleeing",
            e.rows, e.detailed, e.attacking, e.approaching, e.casting, e.fleeing)

        local tg = rt.telegraphs.stats()
        if tg.available then
            out[#out + 1] = string.format("telegraphs: %d live (%d on you) -- %d casts, %d missiles, %d on the ground, %d hazards; %d buckets read",
                tg.active, tg.on_me, tg.casts, tg.missiles, tg.lingering, tg.hazards, tg.buckets_read)
        end

        local th = rt.threat.stats()
        out[#out + 1] = string.format("threat: %d mob(s) ranked across %d in the group (%d raid), %d read this tick",
            th.boards, th.roster, th.raid, th.reads)

        local rx = rt.react.stats()
        if rx.engines > 0 then
            out[#out + 1] = string.format("reactions: %d engine(s), %d rule(s) (%d on), %d decision(s), %d sent",
                rx.engines, rx.rules, rx.enabled, rx.decided, rx.fired)
        end

        local wm = rt.walkmap.stats()
        out[#out + 1] = string.format("walk map: %s, %d yd -- %d cells known, %d wall, %d step edges, %d stuck, %d hole, %d water; rays %s; %d rays %d probes this tick%s",
            wm.active and "mapping" or "idle", wm.radius, wm.known, wm.walls, wm.steps, wm.stuck, wm.holes, wm.water,
            wm.rays, wm.rays_tick, wm.probes_tick, wm.walking and ("; walking for " .. wm.walking) or "")

        local d = rt.draw.stats()
        out[#out + 1] = string.format("draw: %d painted, %d culled, %d cached projections; UI %s",
            d.painted, d.culled, d.cached_w2s,
            d.ui_pass == "window" and "over the game's frames"
                or (d.over_game and d.window_calls == 0 and "under the game's frames (no window pass)")
                or "under the game's frames")

        -- The one line that says whether the memoisation is actually working.
        -- A hit rate that falls off a cliff means something is asking a
        -- different question every frame -- a key built from a float, usually.
        local c = rt.cache.totals()
        out[#out + 1] = string.format("cache: %.0f%% hit over %d caches (%d miss, %d err)",
            c.hit_pct, c.caches, c.misses, c.errors)

        local u2 = rt.ui.stats()
        local a = rt.assets.stats()
        out[#out + 1] = string.format("ui: %d window(s), %d live, %d paint cmds   assets: %d ready, %d queued, %d failed",
            u2.windows, u2.live, u2.cmds, a.ready, a.queued, a.failed)

        local n = rt.net.stats()
        if n.sent > 0 or n.queued > 0 then
            out[#out + 1] = string.format("http: %d sent, %d cached, %d deduped, %d active, %d queued",
                n.sent, n.cached, n.deduped, n.active, n.queued)
        end

        local leases = rt.input.stats().leases
        for i = 1, #leases do
            local lease = leases[i]
            out[#out + 1] = string.format("control: %s held by %s (p%d%s)",
                lease.channel, lease.owner, lease.priority,
                lease.reason and (", " .. lease.reason) or "")
        end

        return out
    end)

    return page
end

-- The menu host may not be installed at the instant this file runs. Try now,
-- and if the host is missing, try again shortly rather than losing the page for
-- the whole session.
local diagnostics = build_diagnostics_page()

-- The toolkit's own windows and its settings page. After the diagnostics
-- page so the JCore sidebar node lists Core first.
rt.ui_builtin = build_module("services/ui_builtin")
if not diagnostics.available then
    rt.scheduler.after(2.0, function()
        build_diagnostics_page()
    end, "jcore")
end

-- --- publish ----------------------------------------------------------------

local public = api.build_public()

--- Registers the loader's legit-cast callback, which JCore no longer asks for
--- at boot (see THE LEGIT-CAST CALLBACK above); then "jcore.spell.cast.legit"
--- fires again. True once registered.
public.enable_legit_casts = rt.enable_legit_casts

--- The debug plugin, when it runs after JCore (1.7.0): builds the recorder,
--- the loot study and the Dump page if boot did not. A recorder built now
--- sees only calls made through core.* from here on, not the natives JCore's
--- services captured at their own build. A second call does nothing.
---@param D table _G.JambixDebug
---@return boolean attached
function public.attach_debug(D)
    if type(D) ~= "table" then return false end
    if rt.faultlog or rt.recorder or rt.lootstudy or rt.dump then return false end
    debug_plugin = D
    rt.faultlog = build_debug("faults")
    rt.recorder = build_debug("recorder")
    rt.lootstudy = build_debug("lootstudy")
    rt.dump = build_debug("dump")
    public.dump = rt.dump
    public.faultlog = rt.faultlog
    local world = rt.world
    local ok, c = pcall(function() return world and world.client and world.client() end)
    if ok and type(c) == "table" then
        c.recording = c.forever == true and rt.recorder ~= nil and rt.recorder.available == true
    end
    for i = 1, #debug_errors do log.fmt("warn", "Jambix Debug: %s", debug_errors[i]) end
    debug_errors = {}
    log.fmt("info", "Jambix Debug attached after boot: fault log %s, recorder %s, loot study %s, dump %s",
        tostring(rt.faultlog ~= nil), tostring(rt.recorder ~= nil), tostring(rt.lootstudy ~= nil), tostring(rt.dump ~= nil))
    return true
end

-- Loaded in the world, as usual: the gate opens now, so the plugins waiting
-- on JCore.in_world() start on the first frame, as before the gate.
if not probe_world() then
    log.info("loaded at the character screen: waiting for the world")
    rt.events.emit("jcore.world.waiting")
end

-- Two doors to the same runtime, per the contract other plugins are written
-- against: the global for plugins in other packages (which cannot require
-- across package roots on every loader build), the module return for anything
-- that can.
_G.JCore = public

rt.ready = true
log.fmt("info", "JCore %s ready (%.0fms boot)", VERSION, (core.time() - rt.started_at) * 1000)
rt.events.emit("jcore.ready", public)

return public

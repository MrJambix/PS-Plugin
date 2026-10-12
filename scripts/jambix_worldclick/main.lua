-- World Click to Move -- click something in the world, and Sentinel
-- Navigation walks you to it. Built on JCore.
--
-- The user, 2026-10-11: "There's a Click to move concept that allows u to
-- click on the map and it moves u there but i'd like to creatre a World Click
-- to Move Plugin which basically uses Sentinels navigation When you Click on
-- a Mob, an item, a Corpser a resource ndoe it basically auto walks you to
-- it".
--
-- The loader's own Click to Move walks you to a place you click on the MAP.
-- This walks you to a THING you click in the WORLD -- a mob, a corpse, a herb
-- or a vein, a chest or a quest object, any npc -- and does there what the
-- game's right-click would have done had you been in reach: loots, gathers,
-- talks, targets. Right-click by default, as the game's own "interact" click.
--
-- 1.1.0, the user: "world click to move should be as far as I want...should
-- allow me to click the minimap and also do that Should be any NPC should
-- also be a click on the ground". So: no distance limit unless one is
-- switched on; any npc near the cursor on screen counts, named by the
-- mouseover or not; a click on nothing walks you to the ground under the
-- cursor; and a click on the minimap, once it has been found, walks you to
-- the spot it shows.
--
-- Module by module (each a factory taking the bundle P, built in this order):
--   pick     what a click is on: the game's mouseover, checked on screen, else
--            the nearest node, corpse or npc to the cursor
--   ground   the spot on the ground under the cursor
--   minimap  where the minimap is (found by two clicks), and its spots
--   walk     the walk with Sentinel (or straight at it), and what is done there
--   mouse    a click, told from a camera turn, a window and a chat box
--   show     the ring, the route and the pulses
--
-- Works on every client JCore runs on. Needs Sentinel Navigation for walks
-- farther than 40 yards; without it a nearer target is walked straight at.

---@diagnostic disable: lowercase-global

local MINIMUM_CORE = "1.7.9"      -- loot.open / loot.opening, draw.pulse, ui.is_cursor_over_ui
local UNLIMITED_CACHE = 120       -- yd of unit cache asked for with no limit (the mouseover names farther)
local PACKAGE = "jambix_worldclick"
local VERSION = "1.1.0"
local NAME = "World Click to Move"

-- =============================================================================
-- MODULE LOADING -- loader builds differ on whether a package-local require
-- resolves from the package folder or the scripts root; try both.
-- =============================================================================

local resolved_prefix = nil

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
        errors[#errors + 1] = ok and ("returned " .. kind .. " from " .. candidates[i]) or tostring(result)
    end
    error(NAME .. ": could not load '" .. relative_path .. "': " .. table.concat(errors, " | "))
end

-- =============================================================================
-- START
-- =============================================================================

local function start(JCore)
    if not JCore.require_version(MINIMUM_CORE) then
        core.log_error(("[%s] needs JCore %s or newer, found %s"):format(NAME, MINIMUM_CORE, tostring(JCore.version)))
        return
    end

    local P = { JCore = JCore, VERSION = VERSION }

    local ctx = JCore.register({
        id      = "jambix.worldclick",
        name    = NAME,
        version = VERSION,
        kind    = "plugin",
        on_load = function(self) self.log.info(NAME .. " " .. VERSION .. " online") end,
        on_unload = function() if P.walk then pcall(P.walk.cancel, "unloaded") end end,
        on_disable = function() if P.walk then pcall(P.walk.cancel, "plugin paused") end end,
    })
    if not ctx then return end
    P.ctx, P.log = ctx, ctx.log
    P.units, P.draw, P.LAYER = ctx.units, ctx.draw, ctx.LAYER

    -- --- helpers every module shares ------------------------------------------------

    function P.try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    --- A method on a game object, through pcall (a missing one is nil).
    function P.call(obj, method, ...)
        if obj == nil then return nil end
        local ok_f, fn = pcall(function() return obj[method] end)
        if not ok_f or type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, obj, ...)
        if ok then return v end
        return nil
    end

    local vec3_lib
    do
        local ok, mod = pcall(require, "common/geometry/vector_3")
        if ok and type(mod) == "table" and mod.new then vec3_lib = mod end
    end

    --- A real vec3 when the loader has one (Sentinel and w2s take it), else a table.
    function P.vec3(x, y, z)
        if vec3_lib then
            local ok, v = pcall(vec3_lib.new, x, y, z)
            if ok and v then return v end
        end
        return { x = x, y = y, z = z }
    end

    --- One line to the log and the recorder's trace (scripts_data/jcore/
    --- jcore.trace.txt), as "world click: ...": what in-game testing reads.
    function P.note(fmt, ...)
        local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        ctx.log.fmt("info", "world click: %s", text)
        pcall(ctx.emit, "jcore.recorder.trace", "world click: " .. text)
    end

    -- ==========================================================================
    -- SETTINGS -- ids are the persistence key: never rename one.
    -- ==========================================================================

    local menu = ctx.menu({ icon = "map", root = true })
    P.menu = menu

    function P.opt(id, fallback) return menu:get_or(id, fallback) end
    function P.enabled() return P.opt("enabled", true) == true end

    -- Modules (mouse's and minimap's names are wanted by the page).
    P.pick = load_module("modules/pick")(P)
    P.ground = load_module("modules/ground")(P)
    P.minimap = load_module("modules/minimap")(P)
    P.walk = load_module("modules/walk")(P)
    P.mouse = load_module("modules/mouse")(P)
    P.show = load_module("modules/show")(P)

    -- ==========================================================================
    -- THE PAGE'S LIVE LINES -- at the top: what it is doing, Sentinel, the last click
    -- ==========================================================================

    local function sentinel_line()
        local public = JCore.nav
        if type(public) ~= "table" then return "Sentinel Navigation: JCore has no nav" end
        local version = P.try(public.version)
        local name = "Sentinel Navigation" .. (version and (" " .. tostring(version)) or "")
        if not P.try(public.installed) then return "Sentinel Navigation: not installed (walks up to 40 yd, straight)" end
        if not P.try(public.available) then return name .. ": installed, not connected" end
        return name .. ": connected (" .. tostring(P.try(public.state) or "?") .. ")"
    end

    local function status_lines()
        local lines = {}
        if not P.enabled() then
            lines[1] = NAME .. ": off"
        else
            lines[1] = NAME .. ": " .. tostring((P.walk.status()))
        end
        lines[2] = sentinel_line()
        local last, click = P.walk.last(), P.last_click
        if click and (not last or click.at > last.at) then
            lines[3] = "Last click: " .. click.text
        elseif last then
            lines[3] = "Last walk: " .. tostring(last.name or "?") .. ": " .. last.text
        else
            local why = P.mouse.last_why()
            lines[3] = why and ("Last press: " .. why) or "No click yet"
        end
        local s = P.walk.stats()
        lines[4] = string.format("Walks %d (Sentinel %d, straight %d), arrived %d, stopped %d, failed %d",
            s.walks, s.by_nav, s.by_line, s.arrived, s.cancelled, s.failed)
        lines[5] = P.minimap.status_line()
        return lines
    end
    menu:live_lines(5, status_lines)

    local main = menu:section(NAME, "map")
    main:toggle("enabled", "Enable", true)
    main:label("Click a mob, a corpse, a herb or vein, a chest, any npc, the ground or")
    main:label("the minimap, and Sentinel Navigation walks you there, however far.")
    main:label("W, A, S, D, Space or Esc stops it.")
    main:dropdown("button", "Walk when you", P.mouse.BUTTON_NAMES, 1)
    main:label("Right-click is the game's own \"interact\" click: in reach, the game")
    main:label("does it and nothing walks; out of reach, this walks you there.")
    main:dropdown("modifier", "While holding", P.mouse.MODIFIER_NAMES, 1)
    main:toggle("limit_range", "Only walk to what is within the distance below", false)
    main:slider("max_range", "Farthest it walks you (with the switch above on)", 20, 500, 100, "yd")
    main:toggle("in_combat", "Also in combat", false)
    main:toggle("straight", "Walk straight at it when Sentinel can't (up to 40 yd)", true)
    main:toggle("show_route", "Show the route and where you're going", true)

    local what = menu:section("What a click walks you to", "target")
    what:toggle("walk_mobs", "Mobs and npcs", true)
    what:toggle("walk_corpses", "Corpses", true)
    what:toggle("walk_objects", "Herbs, veins, chests and other objects", true)
    what:toggle("walk_players", "Players", false)
    what:toggle("walk_ground", "The ground (a click on nothing walks you to that spot)", true)
    what:toggle("ground_guard", "Ground: only when the game takes the click (not on bars, bags, frames)", true)
    what:label("Over the world the game hides the cursor while the button is down; over its")
    what:label("own bars and bags it does not. Turn this off if ground clicks never walk you.")
    what:dropdown("enemy_reach", "Stop at a hostile mob",
        { "By your class (casters and hunters at 28 yd)", "In melee range", "At 28 yd" }, 1)

    local mini = menu:section("Minimap", "map")
    mini:toggle("mm_on", "Walk where you click on the minimap", true)
    mini:label("The game does not say where your minimap is, so show it once:")
    mini:label("press Find my minimap, click its middle (your arrow), then its edge.")
    mini:button("mm_find", "Find my minimap", { on_click = function() P.minimap.start_calibration() end })
    mini:button("mm_forget", "Forget my minimap", { on_click = function() P.minimap.forget() end })
    mini:dropdown("mm_zoom", "Minimap zoom (as set in the game)", P.minimap.ZOOM_NAMES, 1)
    mini:toggle("mm_wheel", "Follow the mouse wheel over the minimap", true)
    mini:toggle("mm_rotate", "My minimap turns with me (Rotate Minimap)", false)
    mini:slider("mm_x", "Minimap centre, across", 0, 7680, 0, "px")
    mini:slider("mm_y", "Minimap centre, down", 0, 4320, 0, "px")
    mini:slider("mm_r", "Minimap radius", 0, 600, 0, "px")

    local there = menu:section("When you get there", "activity")
    there:toggle("act_loot", "Loot corpses", true)
    there:toggle("act_skin", "Skin corpses with nothing left to loot", true)
    there:toggle("act_use", "Gather or open objects", true)
    there:toggle("act_talk", "Talk to npcs", true)
    there:toggle("act_attack", "Attack hostile mobs (off: only target them)", false)

    -- ==========================================================================
    -- WIRING
    -- ==========================================================================

    local WANTS = { enemy = "walk_mobs", npc = "walk_mobs", corpse = "walk_corpses", object = "walk_objects",
        player = "walk_players" }

    --- A click on `thing` (mouse.lua, at the release): a thing in the world,
    --- or a spot (kind "spot": the ground or the minimap, a place only).
    function P.on_click(thing, opts)
        local t = core.time()
        if thing.kind ~= "spot" then
            -- The press's object is a tick old: again by guid, and what it is now.
            local obj = P.pick.refresh(thing)
            if not obj then
                P.last_click = { text = tostring(thing.name) .. " is gone", at = t }
                return
            end
            thing.kind = P.pick.kind_of(obj)
            local switch = WANTS[thing.kind]
            if switch and not P.opt(switch, thing.kind ~= "player") then
                P.last_click = { text = tostring(thing.name) .. ": " .. thing.kind .. "s are switched off", at = t }
                return
            end
        end
        local ok, text, quiet = P.walk.start(thing, opts)
        -- Left to the game's own click is no refusal: no warning pulse.
        if quiet ~= "game" then P.show.pulse(thing.pos, ok) end
        if ok then
            P.last_click = nil
        else
            P.last_click = { text = tostring(thing.name) .. ": " .. tostring(text), at = t }
            P.note("click on %s (%s) not walked: %s", tostring(thing.name), thing.kind, tostring(text))
        end
    end

    -- The click is read every frame: a quick one is down for a few frames only.
    ctx.tick(function() P.mouse.tick() end, { priority = 40 })
    ctx.tick(function()
        if not P.enabled() then
            if P.walk.active() then P.walk.cancel("switched off") end
            return
        end
        P.walk.tick()
    end, { interval = 0.1, priority = 45 })
    ctx.render(function() P.show.render() end, { deferrable = true })

    -- Clicks reach as far as the slider, or (no limit) as far as the unit
    -- cache is asked to: the mouseover and the guid lookup reach past it.
    local function reach()
        local range = P.opt("limit_range", false) and P.opt("max_range", 100) + 10 or UNLIMITED_CACHE
        if ctx.request_unit_range then pcall(ctx.request_unit_range, range) end
    end
    reach()
    menu:on_change("max_range", reach)
    menu:on_change("limit_range", reach)
    menu:on_change("enabled", function(on)
        if not on and P.walk.active() then P.walk.cancel("switched off") end
    end)

    _G.JambixWorldClick = P
end

-- Poll until the core publishes itself, then hand off -- and not before a
-- character is in the world: at the character select screen the game has
-- not loaded its world tables, and a native reading one kills the client.
local function jcore_in_world(J)
    return type(J.in_world) ~= "function" or J.in_world()
end

if _G.JCore and jcore_in_world(_G.JCore) then
    start(_G.JCore)
else
    local deadline = core.time() + 15.0
    local started = false
    core.register_on_update_callback(function()
        if started then return end
        local J = _G.JCore
        if J then
            if jcore_in_world(J) then
                started = true
                start(J)
            end
        elseif core.time() > deadline then
            started = true
            core.log_error("[" .. NAME .. "] JCore never loaded; plugin inactive")
        end
    end)
end

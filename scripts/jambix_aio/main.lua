-- Jambix AIO -- world overlay and gathering automation for Classic Era / HC / TBC.
--
-- Built on JCore. What that buys, and what this plugin therefore does NOT do:
--
--   * It never calls core.object_manager.*. Every unit and object it draws
--     comes from the core's one shared sweep. Running this next to a rotation
--     costs ONE sweep between them, not two.
--
--   * It never calls core.graphics.* directly. Every mark is submitted to the
--     core's draw queue with an explicit layer, so it cannot be painted over
--     another plugin's HUD by an accident of load order.
--
--   * It never widens the unit cache by writing the user's Core setting. It
--     declares the range it needs with ctx.request_unit_range, which is
--     additive across plugins and released on unload.
--
-- EVERY automated interaction goes through modules/actions.lua, which owns the
-- safety gate and the retry/blacklist bookkeeping. Nothing else calls
-- core.input.

---@diagnostic disable: lowercase-global

local MINIMUM_CORE = "1.8.0"   -- ctx.react, the reaction framework
local PACKAGE = "jambix_aio"

-- =============================================================================
-- MODULE LOADING
--
-- Loader builds differ on whether a package-local require resolves relative to
-- the package folder or to the scripts root. Try both, cache what worked, and
-- fail with a message that names every path attempted.
-- =============================================================================

local resolved_prefix = nil

local function load_module(relative_path)
    local candidates
    if resolved_prefix then
        candidates = { resolved_prefix .. relative_path }
    else
        candidates = {
            relative_path,
            PACKAGE .. "/" .. relative_path,
            "./" .. relative_path,
        }
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

    error("Jambix AIO: could not load '" .. relative_path .. "': "
        .. table.concat(errors, " | "))
end

-- =============================================================================
-- START
-- =============================================================================

local function start(JCore)
    if not JCore.require_version(MINIMUM_CORE) then
        core.log_error(("[Jambix AIO] needs JCore %s or newer, found %s")
            :format(MINIMUM_CORE, tostring(JCore.version)))
        return
    end

    -- What the plugin hands back when it is paused or unloaded: the pet's
    -- taunt goes back on autocast (modules/pet.lua, 1.68.0). Filled in below,
    -- once the modules exist.
    local on_stop = {}
    local function hand_back()
        for i = 1, #on_stop do pcall(on_stop[i]) end
    end

    local ctx = JCore.register({
        id      = "jambix.aio",
        name    = "Jambix AIO",
        version = "1.7.8",
        kind    = "esp",
        on_load = function(self) self.log.info("Jambix AIO online") end,
        on_unload = hand_back,
        on_disable = hand_back,
    })
    if not ctx then return end

    -- ==========================================================================
    -- ESP ONLY, OFF THE VANILLA CLIENT
    --
    -- The rotations, the automation and everything else that presses a key
    -- are built and tested against the Vanilla client -- Classic Era,
    -- Hardcore and Season of Discovery all run it -- and Forever, whose
    -- support was built deliberately. On TBC, Wrath, Mists and Retail the
    -- spells, talents and items are different, and a rotation pressing Era
    -- abilities there is worse than none. So on those clients the plugin is
    -- an overlay and nothing else: every ESP mark, quest path, panel and
    -- alert works, and nothing acts.
    --
    -- Three locks, because acting paths do not all go one way: the rotation's
    -- gate (which the pet, the reactions, the kiting and the weave all ride),
    -- the master switch of every other acting feature (see opt), and this
    -- plugin's own cast and input leases, refused outright.
    -- ==========================================================================
    local ESP_ONLY_VERSIONS = { Tbc = "TBC", Titan = "Wrath", Mop = "Mists of Pandaria", Midnight = "Retail" }
    local client_version = ""
    do
        local world = ctx.world
        local ok, client = pcall(function() return world and world.client and world.client() end)
        if ok and type(client) == "table" then client_version = tostring(client.version or "") end
    end
    local esp_only = ESP_ONLY_VERSIONS[client_version] ~= nil
    local client_label = ESP_ONLY_VERSIONS[client_version] or client_version

    if esp_only then
        ctx.cast = function() return false, "esp only on this client" end
        if type(ctx.input) == "table" then
            ctx.input.acquire = function() return false end
        end
        ctx.log.fmt("info", "%s client: running the ESP only -- the rotation and every automation are off",
            client_label)
    end

    -- The bundle every module receives. Built incrementally: a module may use
    -- anything already on P, which makes the assignment order below the
    -- dependency graph.
    local P = {
        JCore  = JCore,
        ctx    = ctx,
        log    = ctx.log,
        draw   = ctx.draw,
        units  = ctx.units,
        combat = ctx.combat,
        -- A module that is itself a package -- modules/esp is the first --
        -- loads its own parts with the same resolver this file used, rather
        -- than each package re-deriving the prefix.
        load   = load_module,
    }

    -- FOREVER (1.45.0): decided once. Every Forever-only path in the
    -- rotation and the reactions asks this; Era never builds or reads any of it.
    P.forever = client_version == "Forever"

    -- The bundle on the plugin's own context: a handle for diagnostics and
    -- for the headless boot test (tools/jtest/tests/aio_boot_*), which reads
    -- the real opt() and rotation_active() through it. Nothing else uses it.
    ctx.aio = P

    -- Readable by any module that has to decide whether it may act.
    P.esp_only = esp_only
    P.client_version = client_version
    P.client_label = client_label

    P.cfg = load_module("modules/config")
    local cfg = P.cfg

    -- ==========================================================================
    -- MENU
    --
    -- Split across sub-pages: one page cannot hold this many settings and stay
    -- usable. Widget ids are the persistence key and are permanent; labels are
    -- not. Category ids come from cfg.CATEGORIES keys, which is why those keys
    -- must never be renamed.
    -- ==========================================================================

    -- The root node is an overview. Every feature area is a peer page beneath
    -- it, so nothing has the privileged position of living on the root while
    -- its siblings are nested one level down.
    local overview = ctx.menu({ icon = "widgets", root = true })
    -- CLASSIC AND FOREVER KEEP THEIR OWN ESP SETTINGS (1.47.0). The menu
    -- saves widgets per page path, so on Forever the page is "Forever ESP"
    -- and its values are its own: a switch moved there no longer moves the
    -- Classic one, nor the other way. Every other client keeps "ESP" and
    -- the values already saved under it.
    local esp = ctx.menu({ sub = P.forever and "Forever ESP" or "ESP", root = true, icon = "eye" })
    local rotation = ctx.menu({ sub = "Rotation", root = true, icon = "swords" })
    -- The Reactions tab (1.76.0): the switch, and the window's button.
    local reactions_page = ctx.menu({ sub = "Reactions", root = true, icon = "activity" })
    local hardcore = ctx.menu({ sub = "Hardcore", root = true, icon = "shield" })
    local automation = ctx.menu({ sub = "Automation", root = true, icon = "settings" })
    local fishing_page = ctx.menu({ sub = "Fishing", root = true, icon = "target" })
    local guides = ctx.menu({ sub = "Quests", root = true, icon = "list" })
    -- World marks (1.89.0): the look, the budget and the calibration of every
    -- mark the AIO draws in the world (modules/worldlayer.lua).
    local world_page = ctx.menu({ sub = "World marks", root = true, icon = "eye" })
    -- The Debug page is Jambix Debug's since 1.60.0 (see THE DEBUG PAGE below).

    P.menu = esp
    -- Every page by name, for a window that writes a setting where the menu
    -- keeps it (the class window, 1.63.0).
    P.pages = { overview = overview, esp = esp, rotation = rotation, hardcore = hardcore,
        automation = automation, fishing = fishing_page, quests = guides, reactions = reactions_page,
        world = world_page }

    --- Reads a widget from whichever page declared it.
    ---
    --- The pages are separate persistence namespaces, so a single get has to
    --- try each. Ids are unique across all four by construction, and the first
    --- non-nil wins. Falling through to `fallback` covers both an undeclared
    --- id and a missing menu host -- a nil leaking into a comparison downstream
    --- would be a silent behaviour change rather than a visible failure.
    local PAGES = { overview, esp, rotation, hardcore, automation, fishing_page, guides, reactions_page, world_page }

    -- MEMOISED PER FRAME. The overlay asks for the same fifteen or so settings
    -- for every entity it draws, and every ask walked the pages above -- a
    -- guarded host call per page, eight for a miss -- so sixty marks cost
    -- thousands of menu reads a frame for values that change only when a
    -- slider moves. The frame key is a counter bumped by the first tick job
    -- of the frame rather than core.time(), because the clock is itself a
    -- native call and this runs thousands of times a frame. A value the menu
    -- writes is seen on the NEXT frame, which is the earliest anything would
    -- have drawn with it; the one reader that needs it sooner (a colour
    -- picker's on_change) calls opt_invalidate.
    local NONE = {}
    local opt_cache, opt_epoch, opt_seen = {}, 0, 0

    ctx.tick(function() opt_epoch = opt_epoch + 1 end, { priority = -1000 })

    -- RETIRED SETTINGS. The reaction engine took these over (1.32.0: the
    -- reactions; 1.33.0: the rotation itself). Their widgets are gone, and
    -- this answers their built-in default WITHOUT READING THE MENU, so a value
    -- saved before they were removed cannot keep steering anything from a
    -- settings file nobody can see -- whichever module still asks.
    local RETIRED = {
        -- 1.32.0: the reactions
        rot_interrupt = true, rot_use_defensives = true, rot_defensive_hp = true,
        rot_use_racials = true, rot_dispel = true, rot_escape_when_losing = true,
        rot_flee_runway = true, react_enabled = true,
        pet_manage_growl = true, pet_interrupt = true, pet_heal = true, pet_heal_hp = true,
        pet_heal_only_tanking = true,
        hc_bail_out = true, hc_bail_hp = true, hc_use_consumables = true, hc_potion_hp = true,
        hc_escape_abilities = true, hc_hearth_hp = true,
        -- 1.33.0: the rotation changes with the fight
        auto_tune = true, rot_aoe_radius = true, rot_rend_min_ttd = true,
        res_critical_hp = true, res_conserve_hp = true, res_critical_power = true,
        res_conserve_power = true, res_trade_floor_hp = true, rot_aoe_min_targets = true,
        rot_wand_below_mana = true, rot_wand_recheck = true, rot_burst_freely = true,
        rot_prefer_tank = true,
        rot_hunter_pull_selected = true, rot_hunter_mana_fine = true,
        rot_hunter_aimed_opener = true, rot_hunter_multishot_filler = true,
        rot_hunter_intimidation = true, rot_hunter_bestial_wrath = true,
        rot_hunter_hamstring_runners = true,
        -- 1.39.0: switches that did nothing, and the burst's two opt-ins.
        -- Taunts follow "Reclaim enemies nobody is holding"; rest sits down
        -- under what the next pull needs and stands up there (rest.lua); the
        -- burst window decides cooldowns and trinkets from the fight.
        rot_taunt = true, rest_health = true, rest_mana = true,
        rest_health_to = true, rest_mana_to = true,
        rot_use_cooldowns = true, rot_use_trinkets = true,
    }
    P.RETIRED = RETIRED

    local function retired(id)
        if RETIRED[id] then return true end
        -- The per-class profile selectors: the profile follows the talents.
        return type(id) == "string" and id:sub(1, 12) == "rot_profile_"
    end

    -- On an ESP-only client (see the top of start): the master switch of
    -- every feature that acts reads OFF, whatever the menu says. The rotation
    -- has its own lock in rotation_active; these are the rest.
    local ESP_ONLY_OFF = {
        autoloot_on = true, autoloot_skin = true, autoloot_confirm_bop = true,
        autoloot_force_close = true, rest_enabled = true,
        gather_herbs = true, gather_ore = true, gather_containers = true,
        fish_enabled = true, hc_enabled = true, hc_block_pulls = true, hc_hearth = true,
        rot_hud_enabled = true, rot_auto_target = true, rot_use_wand = true,
        rot_hold_aggro = true, rot_assist_tank = true,
        -- 1.7.4: the guide walk. JCore's nav takes its own movement lease,
        -- round the lock on ctx.input.acquire above.
        rxp_follow = true,
        -- 1.8.1: the RestedXP ESP acting as you walk up (talks to quest
        -- givers, hands the step's mobs to the rotation).
        rxp_act = true,
    }

    -- RESTEDXP ONLY (1.61.0). Players: "wish u could turn off all ESP but
    -- keep the RXP esp only with 1 setting without having to go through
    -- shit load of options". One switch: the overlay draws the guide's marks,
    -- its panel and its waypoint line, and nothing else. While it is on, the
    -- guide's own switches and the overlay's master read ON whatever they are
    -- set to -- the point is not having to visit them.
    local RXP_ONLY_ON = { enabled = true, rxp_on = true, guide_on = true }

    local function opt(id, fallback)
        if esp_only and ESP_ONLY_OFF[id] then return false end
        if retired(id) then return fallback end
        if RXP_ONLY_ON[id] and opt("rxp_only", false) == true then return true end
        if opt_epoch ~= opt_seen then
            opt_cache = {}
            opt_seen = opt_epoch
        end

        local hit = opt_cache[id]
        if hit ~= nil then
            if hit == NONE then return fallback end
            return hit
        end

        for i = 1, #PAGES do
            local value = PAGES[i]:get(id)
            if value ~= nil then
                opt_cache[id] = value
                return value
            end
        end
        opt_cache[id] = NONE
        return fallback
    end
    P.opt = opt

    -- SIMPLE OR ADVANCED (1.64.0). The user, 2026-10-04: reorganize the menus,
    -- "both" -- fewer clearer pages AND a simple/advanced split. One switch on
    -- the Overview page shows the fine tuning: performance budgets, placement
    -- and colours, timings, debug switches, and the class settings that now
    -- live in each class's window. Hidden is not off: every value still reads
    -- as set. Nothing moved page, because a widget's saved value is keyed by
    -- its page (the menu host's own warning), so moving one resets it.
    local function advanced() return opt("show_advanced", false) == true end
    local ADV = { visible = advanced }
    P.advanced = advanced

    --- Drops this frame's memo. For a handler that writes a setting and
    --- reads it back in the same frame.
    local function opt_invalidate()
        opt_cache = {}
    end
    P.opt_invalidate = opt_invalidate

    --- A percentage slider read as a 0..1 fraction.
    ---
    --- Health and rage thresholds are shown as percentages because that is how
    --- people think about them, and compared against health FRACTIONS because
    --- that is what the core answers. Converting in one place stops the two
    --- conventions meeting somewhere they both look plausible.
    local function optpct(id, fallback_pct)
        local value = opt(id, fallback_pct)
        if type(value) ~= "number" then value = fallback_pct end
        return value / 100
    end
    P.optpct = optpct

    --- A percentage threshold that the plugin normally chooses for itself.
    ---
    --- WHY THIS IS NOT JUST A SLIDER READ
    --- A slider asks the player to know a number that depends on their level,
    --- their gear, and what is hitting them right now. modules/auto.lua works
    --- that number out from what the client reports -- real spell costs, real
    --- cast times, real regeneration, and the measured rate the health bar is
    --- moving -- and this is where the two meet.
    ---
    --- Automatic is the default and the intended way to run. The sliders stay
    --- because a derivation can come back nil (spell data loads late, and a
    --- character that has not been hit yet has no damage history to read), and
    --- something has to answer in the meantime.
    ---@param id string the widget id, which is also the derivation key
    ---@param fallback_pct number
    ---@return number 0..1
    local function tuned(id, fallback_pct)
        if opt("auto_tune", true) and P.auto then
            local value = P.auto.value(id)
            if type(value) == "number" then return value end
        end
        return optpct(id, fallback_pct)
    end
    P.tune = tuned

    --- The same, for a value already in seconds rather than a percentage.
    ---@param id string
    ---@param fallback number
    ---@return number
    local function tuned_secs(id, fallback)
        if opt("auto_tune", true) and P.auto then
            local value = P.auto.value(id)
            if type(value) == "number" then return value end
        end
        local value = opt(id, fallback)
        if type(value) ~= "number" then return fallback end
        return value
    end
    P.tune_secs = tuned_secs

    --- A threshold that is NO LONGER A SETTING: the reaction engine took it
    --- over (1.32.0). What the plugin works out from live data, else the
    --- built-in default. It never reads the menu -- a value saved by a slider
    --- that has since been removed must not keep steering anything from a
    --- settings file nobody can see.
    ---@param id string the derivation key (modules/auto.lua)
    ---@param fallback_pct number
    ---@return number 0..1
    local function derived(id, fallback_pct)
        if P.auto then
            local value = P.auto.value(id)
            if type(value) == "number" then return value end
        end
        return fallback_pct / 100
    end
    P.derived = derived

    ---@param id string
    ---@param fallback number seconds
    ---@return number
    local function derived_secs(id, fallback)
        if P.auto then
            local value = P.auto.value(id)
            if type(value) == "number" then return value end
        end
        return fallback
    end
    P.derived_secs = derived_secs

    --- The one switch on the Overview page. Everything else is AND-ed with it,
    --- so there is a single place to stop the whole plugin without hunting
    --- through five pages of toggles.
    local function master_on()
        return opt("aio_enabled", true) and true or false
    end
    P.master_on = master_on

    local function toggle_active()
        if not master_on() then return false end
        if type(esp:get("toggle_key")) ~= "table" then return true end
        return esp:is_keybind_active("toggle_key")
    end
    P.toggle_active = toggle_active

    --- The rotation has its own keybind, separate from the ESP's. Hiding the
    --- overlay must not start or stop the rotation, and vice versa.
    local function rotation_active()
        if esp_only then return false end
        if not master_on() then return false end
        if type(rotation:get("rot_key")) ~= "table" then return true end
        return rotation:is_keybind_active("rot_key")
    end

    --- May damage-over-time spells go on things other than the target?
    ---
    --- Two switches, and the keybind is the one that matters. Spreading is
    --- right most of the time and wrong at a few specific moments -- a
    --- sheeped add, a mob somebody else is about to crowd control, a pull
    --- being held together on one target -- and those moments last seconds.
    --- A settings page is the wrong place to answer something that changes
    --- that fast, so there is a key for it.
    ---
    --- The plain toggle stays for people who never want it at all, and the
    --- keybind ships INACTIVE like the others: an unbound key must not be the
    --- reason spreading silently stopped working.
    --- Is the key for this ability being held, or its toggle switched on?
    ---
    --- THIS ONE FAILS CLOSED, and that is deliberate -- it is the only gate in
    --- the plugin that does. Everywhere else an unreadable signal must not be
    --- able to silence the rotation, because the cost of a gate stuck shut is
    --- a character standing still. Crowd control is the other way round: the
    --- cost of a fear that did not fire is an opportunity missed, and the cost
    --- of one that fired unasked is a broken sheep, a second pack pulled, or a
    --- group wiped. So an unbound key means never, not always.
    ---@param id string the keybind widget id
    ---@return boolean
    local function key_armed(id)
        local value = rotation:get(id)
        if type(value) ~= "table" then return false end
        return rotation:is_keybind_active(id)
    end
    P.key_armed = key_armed

    local function spread_allowed()
        if not opt("rot_spread", true) then return false end
        if type(rotation:get("rot_spread_key")) ~= "table" then return true end
        return rotation:is_keybind_active("rot_spread_key")
    end
    P.spread_allowed = spread_allowed
    P.rotation_active = rotation_active

    -- WoW's own power-type ids. The enums table is asked first so a client
    -- that renumbers them still resolves; these are the fallback.
    local POWER_IDS = {
        MANA = 0, RAGE = 1, FOCUS = 2, ENERGY = 3, COMBOPOINTS = 4,
        RUNES = 5, RUNICPOWER = 6, HAPPINESS = 4,
    }

    ---@param name string
    ---@return integer
    local function power_id(name)
        local enums = P.enums
        if enums and enums.power_type and type(enums.power_type[name]) == "number" then
            return enums.power_type[name]
        end
        return POWER_IDS[name] or 0
    end

    -- The player's resources are JCore's (1.55.0, JCore 1.6.0): ctx.player
    -- answers per client. Era: the client's read. Forever, where get_power
    -- reads 0 (164,586 of 164,586 recorded calls): counted from our casts
    -- (JCore's services/power.lua; this plugin's forever_power.lua until now)
    -- until a read says otherwise.
    local player_service = ctx.player

    --- Current value of a named resource, 0 when it cannot be read.
    ---@param name string "RAGE", "MANA", "ENERGY", "COMBOPOINTS", ...
    ---@return number
    function P.power(name)
        if player_service and player_service.power then
            local ok, value = pcall(player_service.power, power_id(name))
            return (ok and value) or 0
        end
        local player = P.units.player()
        if not player then return 0 end
        local ok, value = pcall(player.get_power, player, power_id(name))
        return (ok and value) or 0
    end

    ---@param name string
    ---@return number
    function P.power_max(name)
        if player_service and player_service.max_power then
            local ok, value = pcall(player_service.max_power, power_id(name))
            return (ok and value) or 0
        end
        local player = P.units.player()
        if not player then return 0 end
        local ok, value = pcall(player.get_max_power, player, power_id(name))
        return (ok and value) or 0
    end

    --- For a bar the client cannot read and nobody counts (mana on Forever):
    --- 1 while nothing says otherwise, low for a moment after the client said
    --- there was not enough. nil wherever the read works.
    ---@param name string
    ---@return number|nil
    function P.power_unread(name)
        if not (player_service and player_service.power_unread) then return nil end
        local ok, value = pcall(player_service.power_unread, power_id(name))
        return ok and value or nil
    end

    --- Is this resource counted from our casts rather than read?
    ---@param name string
    ---@return boolean
    function P.power_counted(name)
        if not (player_service and player_service.power_counted) then return false end
        local ok, value = pcall(player_service.power_counted, power_id(name))
        return ok and value == true
    end

    --- One line: what is read and what is counted.
    ---@return string
    function P.power_summary()
        if not (player_service and player_service.power_summary) then return "read by the client" end
        local ok, text = pcall(player_service.power_summary)
        return ok and type(text) == "string" and text or "read by the client"
    end

    --- Kept for the warrior-specific stance cost maths.
    ---@return number
    function P.rage()
        return P.power("RAGE")
    end

    --- True only for classes whose form change burns rage. Used by the form
    --- manager so a druid is not charged a warrior's stance cost.
    function P.class_uses_rage()
        local class_module = P.rotation and P.rotation.active_class()
        return class_module ~= nil and class_module.power == "RAGE"
    end

    -- --- overview page ------------------------------------------------------
    --
    -- The root node. One master switch and a live summary; every setting lives
    -- on the feature page it belongs to.

    local master_section = overview:section("Jambix AIO", "widgets", { column = "full" })
    master_section:toggle("aio_enabled", "Enable everything", true)
    master_section:label("Turning this off stops the overlay, the rotation and all automation.")
    master_section:toggle("show_advanced", "Show advanced settings", false)
    master_section:label("Off: only the settings most players change. On: every fine-tuning")
    master_section:label("slider, colour and debug switch, and the class settings that also")
    master_section:label("live in your class's window.")

    --- A notice at the top of a page whose features are switched off here.
    local function esp_only_notice(page, what)
        if not esp_only then return end
        local notice = page:section("Not on " .. client_label, "alert", { column = "full" })
        notice:label(client_label .. " client: Jambix AIO runs the ESP only here. " .. what)
        notice:label("is built for Classic Era -- and Hardcore and Season of Discovery,")
        notice:label("which run the same client -- and stays off on this one, whatever")
        notice:label("the switches below say. The ESP, quest paths and alerts all work.")
    end
    P.esp_only_notice = esp_only_notice

    if esp_only then
        master_section:label(client_label .. " client: the ESP runs; the rotation and every")
        master_section:label("automation are off here. They are built for Classic Era.")
    end
    esp_only_notice(rotation, "The rotation")
    esp_only_notice(hardcore, "The survival automation")
    esp_only_notice(automation, "Looting, resting and gathering")
    esp_only_notice(fishing_page, "Fishing")
    esp_only_notice(reactions_page, "The reaction engine")

    -- --- ESP page -----------------------------------------------------------

    -- THE FOREVER ESP'S PAGE (1.69.0): a Style and a grid of what to show,
    -- every piece and a detail level per category with advanced settings on
    -- (modules/esp/page_forever.lua). Same page and ids, so nothing saved is
    -- lost. The Classic ESP keeps the sections below until it moves to the
    -- icon card too.
    if P.forever then
        load_module("modules/esp/page_forever")(P, esp, { advanced = advanced, quests = guides })
    end

    if not P.forever then
        -- Which of the two ESPs this page drives, at the top of it (1.47.0).
        local which_esp = esp:section(P.forever and "Classic Forever ESP" or "Classic ESP", "eye",
            { column = "full" })
        if P.forever then
            which_esp:label("The Classic Forever ESP, with settings of its own: nothing set here")
            which_esp:label("changes the Classic ESP, and nothing set there changes this one.")
        else
            which_esp:label("The Classic ESP. Classic Forever has its own ESP and its own settings:")
            which_esp:label("nothing set here changes it, and nothing set there changes this one.")
        end

        local general = esp:section("General", "settings", { column = "left" })
        general:toggle("enabled", "Enable ESP", true)
        general:label("Quest marks and RestedXP are the Quests page's: they show with")
        general:label("the ESP off too. The toggle key hides everything.")
        general:toggle("rxp_only", "RestedXP guide only", false)
        general:label("One switch: only the guide's marks, its panel and its waypoint line.")
        general:label("Every other mark, the threat panel and the quest paths are hidden.")
        general:keybind("toggle_key", "Toggle key", 0x5A, {
            mode = "toggle", modes = { "toggle", "hold" }, default_active = true,
        })
        general:slider("max_range", "Range", 20, 200, 150, "yd")
        general:slider("text_size", "Text size", 9, 22, 13, "px")

        -- ONE number instead of fifteen. Fourteen per-category ranges are the
        -- right tool for "rares at 150 but boars at 40" and the wrong default for
        -- someone who has just loaded the plugin and wants to see what is around
        -- them -- which is how a working overlay ended up looking broken.
        general:toggle("auto_ranges", "Set each category's range automatically", true)
        general:label("On: everything switched on below is drawn out to the range above,")
        general:label("and the mark limit keeps the list sane in a crowd -- what it keeps")
        general:label("is what matters, so a rare at ninety yards outranks a boar at ten.")
        general:label("Off: each category uses its own range, set under Categories.")

        general:button("esp_mark_everything", "Show every category but critters", {
            on_click = function()
                -- Critters are left as they are (1.47.1): off, unless switched
                -- on by hand under Categories.
                for i = 1, #cfg.CATEGORIES do
                    local key = cfg.CATEGORIES[i].key
                    if key ~= "critter" then esp:set(key .. "_on", true) end
                end
                ctx.log.info("ESP: every category but critters switched on")
            end,
        })
        general:label("Including the ones that are off on purpose: friendly players and")
        general:label("loose world objects. Critters only switch on under Categories.")

        -- The marks themselves come from cfg.ELEMENTS, so a mark cannot be added
        -- without a toggle appearing here and a toggle cannot be left here with
        -- nothing behind it. The rows below it are not marks: they are what the
        -- name label CONTAINS, and two global modifiers.
        local elements = esp:section("Elements", "widgets", { column = "right" })
        -- Shown with advanced settings only (1.64.0).
        local ADVANCED_ELEMENTS = {
            show_raid_marker = true, show_class_icon = true, show_creature_icon = true, show_power = true,
            show_details = true, show_status = true, show_threat = true, node_ring = true,
            show_reach = true, show_target_line = true,
        }
        for i = 1, #cfg.ELEMENTS do
            local el = cfg.ELEMENTS[i]
            elements:toggle(el.key, el.label, el.default, ADVANCED_ELEMENTS[el.key] and ADV or nil)
        end
        elements:toggle("show_distance", "Distance", true)
        -- 1.88.0: from how far off a rare, boss, quest target or loot gets its pillar of light.
        elements:slider("esp_beacon_from", "Pillars of light from", 10, 150, 40, "yd", ADV)
        -- The rest of the look: a section of its own, with advanced settings on.
        -- Same page, so every saved value stays where it was.
        elements = esp:section("Look and placement", "widgets", { column = "right", visible = advanced })
        elements:separator("What the second line says")
        elements:toggle("show_name", "Name", true)
        elements:toggle("show_level", "Level and rank", true)
        elements:toggle("show_health_text", "Health, once something is hurt", true)
        elements:toggle("show_health_exact", "Health as numbers, not a percentage", false)
        elements:toggle("show_mana_text", "Mana, once some of it is gone", true)
        elements:toggle("show_fight_role", "Melee, ranged or caster", true)
        elements:label("Learned from what each kind of mob is seen casting, and kept: a")
        elements:label("? means it has not been seen yet and this is a guess.")
        elements:toggle("show_reaction_tag", "Hostile / neutral / friendly, in words", false)
        elements:label("The colour already says this. The words are for when it has to")
        elements:label("be unambiguous.")

        elements:separator("Placement")
        elements:toggle("label_above_head", "Hang marks above the model's head", true)
        elements:label("Off: a fixed lift above wherever the unit's feet project to,")
        elements:label("which drifts through tall models and floats above small ones.")
        elements:slider("label_lift", "Clearance above the head", 0, 40, 10, "px")
        elements:toggle("esp_rows_below", "Cast bar, target range, status and details under the feet", true)
        elements:label("A nameplate addon draws above the head and covers whatever the")
        elements:label("overlay puts there. Under the feet nothing does. The name, portrait")
        elements:label("and raid icon stay on top. Off: everything stacks above the head.")
        elements:toggle("esp_declutter", "Keep marks from overlapping in a crowd", true)
        elements:label("A block that would land on another moves down; if it would have to")
        elements:label("move far, only its cast, range and status rows are kept; if even")
        elements:label("those do not fit, it waits. Your target and rares are placed first.")
        elements:dropdown("esp_plate_mode", "When a nameplate covers the mark",
            cfg.PLATE_MODES, cfg.PLATE_BELOW)
        elements:label("A nameplate addon draws its plate, and its auras above it, exactly")
        elements:label("where the mark hangs. Under the feet: the whole mark moves below the")
        elements:label("unit while its plate is up, where nothing covers it. On top: above")
        elements:label("the plate's bar, which its auras can still cover.")
        elements:toggle("esp_plate_defer", "Leave the name and health to the nameplate", true)
        elements:slider("plate_clearance", "Clearance above a nameplate", 0, 40, 4, "px")
        elements:label("For \"on top\": raise it if the plate shows auras above its bar.")
        elements:slider("bar_width", "Health and cast bar width", 24, 120, 54, "px")
        elements:slider("bar_height", "Health and cast bar height", 2, 10, 4, "px")
        elements:toggle("bar_always", "Health and mana bars even when full", false)
        elements:dropdown("box_style", "Bounding box style", cfg.BOX_STYLES, cfg.BOX_DEFAULT)

        elements:separator("Colour")
        -- A dropdown rather than a toggle: "what colour means" has three useful
        -- answers and no natural on/off. Reaction is the default because a yellow
        -- name you can walk past and a red one that is already coming are the two
        -- things worth telling apart at a glance.
        elements:dropdown("unit_color_mode", "Colour plain NPCs by",
            cfg.COLOR_MODES, cfg.COLOR_MODE_REACTION)
        elements:label("Bosses, rares, quest and guide targets keep their own colour:")
        elements:label("that colour already says something the reaction would replace.")
        elements:toggle("class_colors", "Class colours for players", true)
        elements:toggle("grey_tapped", "Grey out mobs someone else has tagged", true)
        elements:label("No kill credit and no loot, so it outranks every other colour --")
        elements:label("the way the game greys the nameplate.")
        elements:toggle("dim_by_distance", "Fade with distance", true)

        elements:separator("Portraits")
        elements:label("A round icon above the name. Players: the class, framed in the")
        elements:label("class colour, badged T tank, H healer, D damage -- dimmer when")
        elements:label("the role is a guess. NPCs: the creature type, framed in the")
        elements:label("mark's colour, badged C caster (has mana) or M melee.")
        elements:slider("class_icon_size", "Icon size", 14, 40, 22, "px")
        elements:toggle("role_badge", "Role badge", true)

        elements:separator("Tags")
        elements:toggle("show_tags", "Why it is marked, as a chip before the name", true)
        elements:label("Quest yellow: PICK UP, TURN IN, KILL, COLLECT (it drops the item),")
        elements:label("USE (an object), with Questie's own icon for each. GUIDE in blue,")
        elements:label("with RestedXP's logo: the guide's line under it says what for.")
        elements:label("LOOT in green and SKIN in brown on corpses. Players never get one.")
        elements:toggle("show_tame", "Hunters: TAME on beasts you can tame", true)
        elements:label("TAME in violet on a beast the game says can be tamed, at or under your")
        elements:label("level. Its details line has the family and the skills a beast of its")
        elements:label("level teaches: sure when Petopia lists that kind or you have seen it")
        elements:label("use the skill, '?' when only its family says so, 'new' when your pet's")
        elements:label("rank is lower. From the client's creature cache: a beast first met")
        elements:label("this session shows from the next one on.")

        elements:separator("Cards and bars")
        elements:toggle("esp_shader_look", "Pills as soft cards, bars shading on a rounded rail", true)
        elements:label("JCore's shader drawing (1.88.0): each pill a plate with a soft shadow,")
        elements:label("each bar a gradient. Off: the flat pills, and the bars set below.")
        elements:separator("The game's own art")
        elements:toggle("show_badges", "Badge before the name", true)
        elements:label("Out of the game's own UI: the target frame's skull for a boss, a ??")
        elements:label("or anything ten levels above you; the nameplate's gold dragon for")
        elements:label("an elite; a hostile player's faction emblem; the herbalism, mining")
        elements:label("or treasure icon over a node.")
        elements:toggle("game_bars", "Bars in the game's own texture", true)
        elements:label("Health, mana and cast bars painted with the gradient the game paints")
        elements:label("its own bars with. Off: flat bars.")

        local cats = esp:section("Categories", "list",
            { column = "full", searchable = true })
        cats:label("The ranges here are ignored while automatic ranges is on.")
        for i = 1, #cfg.CATEGORIES do
            local c = cfg.CATEGORIES[i]
            cats:toggle(c.key .. "_on", c.label, c.on)
            cats:slider(c.key .. "_range", c.label .. " range", 5, 200, c.range, "yd", {
                visible = function() return advanced() and not opt("auto_ranges", true) end,
            })
            cats:color_picker(c.key .. "_color", c.label .. " colour",
                { r = c.rgb[1], g = c.rgb[2], b = c.rgb[3], a = 255 }, ADV)
        end
    end


    -- CRITTERS OFF (1.47.1, user: "have them off on default"). They shipped
    -- off, but a value saved on -- by hand, or by "Show every category" --
    -- kept them on. Switched off ONCE per ESP page, a second after load so
    -- the menu has its saved values; after that the switch is the user's
    -- again. That it was done is kept in the `migrations` store.
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = "critters_off:" .. (P.forever and "Forever ESP" or "ESP")
        if fixes and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function switch_off()
                tries = tries + 1
                esp:set("critter_on", false)
                if esp:get("critter_on") == false then
                    fixes.data[key] = true
                    fixes:touch()
                    P.opt_invalidate()
                    ctx.log.info("ESP: critters switched off -- they are off by default now")
                elseif tries < 5 then
                    ctx.after(2, switch_off)
                end
            end
            ctx.after(1, switch_off)
        end
    end

    -- HUNTER KITING OFF (1.64.1, the user: "set to default off hunter option
    -- Run and shoot before there is a pet"). It shipped on, and the menu saves
    -- a default as the player's value, so a new default alone changes nothing
    -- for anyone who has played. Switched off ONCE, as the critters were; after
    -- that the switch is the player's again.
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = "hunter_kite_off"
        if fixes and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function switch_off()
                tries = tries + 1
                rotation:set("rot_hunter_kite", false)
                if rotation:get("rot_hunter_kite") == false then
                    fixes.data[key] = true
                    fixes:touch()
                    P.opt_invalidate()
                    ctx.log.info("Hunter: Run and shoot before there is a pet switched off -- off by default now")
                elseif tries < 5 then
                    ctx.after(2, switch_off)
                end
            end
            ctx.after(1, switch_off)
        end
    end

    if not P.forever then
        local alerts_section = esp:section("Hardcore alerts", "alert", { column = "full" })
        alerts_section:toggle("alerts_on", "Enable alerts", true)
        alerts_section:toggle("alert_players", "Hostile players", true)
        alerts_section:slider("alert_player_range", "Player alert range", 10, 200, 60, "yd")
        alerts_section:toggle("alert_elites", "Elites above my level", true)
        alerts_section:slider("alert_elite_range", "Elite alert range", 10, 100, 35, "yd")
        alerts_section:slider("alert_level_delta", "Minimum level advantage", 0, 15, 2, "lv", ADV)
        alerts_section:toggle("alert_panel", "Show threat panel", true)
        alerts_section:toggle("alert_arrows", "Arrows for threats off screen", false)
        alerts_section:label("An arrow at the edge of the screen for anything on the threat")
        alerts_section:label("list you cannot currently see, pointing the way you would turn.")
        alerts_section:toggle("alert_sound", "Play a sound", true)
        alerts_section:toggle("alert_toast", "Show a notification", false)
        alerts_section:slider("alert_cooldown", "Re-alert cooldown", 2, 60, 15, "s", ADV)

        -- --- Telegraphs (1.65.0) -------------------------------------------------
        --
        -- The ground an enemy spell is about to hit, worked out by JCore 1.8.0 from
        -- the game's own spell tables and DBM's boss mods (modules/telegraphs.lua
        -- paints it). Its own switch; the overlay's switch and toggle key hide it
        -- like every other mark.

        local tele = esp:section("Telegraphs", "alert", { column = "full" })
        tele:toggle("tele_on", "Show telegraphs", true)
        tele:label("The ground an enemy spell is about to hit: a circle around the caster,")
        tele:label("a circle where it aims, a cone in front of it. The size is the game's own,")
        tele:label("what to do about it is DBM's. See-through, with a line sweeping out to the")
        tele:label("edge as the cast runs; red while you are standing in it, and a heavier edge")
        tele:label("for a boss's mechanics.")
        tele:dropdown("tele_who", "Show telegraphs for", cfg.TELE_WHO, 1)
        tele:dropdown("tele_where", "Show telegraphs in", cfg.TELE_WHERE, 1)
        tele:toggle("tele_players", "Hostile players' spells too", true)
        tele:slider("tele_range", "Range", 20, 100, 60, "yd")
        tele:toggle("tele_labels", "Name, what to do and time left", true)
        tele:toggle("tele_alerts", "Alerts at the top of the screen", true)
        tele:toggle("tele_wall", "A wall rising round its edge as it lands", false)
        tele:label("For what has no ground to show: a spell as big as the room, one on")
        tele:label("you, and whatever you are standing in right now.")
        tele:slider("tele_fill", "Fill strength", 0, 50, 15, "%")
        tele:label("How solid the danger ground is. Low enough to see mobs, and yourself,")
        tele:label("standing in it; 0 leaves only the edge and the sweep.")
        tele:toggle("tele_missiles", "Where missiles land", true, ADV)
        tele:toggle("tele_linger", "Ground that stays bad (Flamestrike, Consecration)", true, ADV)
    end


    -- SEE-THROUGH TELEGRAPHS (1.65.1, the user: "it shouldnt be Full one color
    -- cant see other mobs or myself in it"). 1.65.0 shipped the fill at 25%
    -- under a second fill that grew as the cast ran; the default is 15% now and
    -- the second fill is gone. The menu saved 25 as the player's value, so a
    -- value still at the old default is moved ONCE per ESP page; one set by
    -- hand to anything else is left alone.
    do
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = "tele_fill_15:" .. (P.forever and "Forever ESP" or "ESP")
        if fixes and fixes.data[key] ~= true and ctx.after then
            local tries = 0
            local function lighten()
                tries = tries + 1
                local now = esp:get("tele_fill")
                if now == nil and tries < 5 then
                    ctx.after(2, lighten)
                    return
                end
                if now == 25 then esp:set("tele_fill", 15) end
                if now ~= 25 or esp:get("tele_fill") == 15 then
                    fixes.data[key] = true
                    fixes:touch()
                    P.opt_invalidate()
                    if now == 25 then ctx.log.info("Telegraphs: fill strength 25% -> 15%, see-through by default now") end
                elseif tries < 5 then
                    ctx.after(2, lighten)
                end
            end
            ctx.after(1, lighten)
        end
    end

    if not P.forever then
        -- --- ESP performance ----------------------------------------------------
        --
        -- Every setting here trades marks for frame time, and all of them ship at
        -- the setting that changes nothing you would notice. They exist so that a
        -- forty-unit pull in a city degrades in a way you chose rather than in the
        -- way the frame happens to run out.

        local perf = esp:section("Performance", "activity", { column = "full", visible = advanced })
        perf:toggle("lod_on", "Reduce detail with distance", true)
        perf:label("Health bars and tracers stop past the reduced-detail range. Boxes")
        perf:label("and names carry on to the edge of each category's own range.")
        perf:slider("lod_full_range", "Full detail out to", 10, 120, 45, "yd")
        perf:slider("lod_mid_range", "Reduced detail out to", 20, 200, 90, "yd")
        perf:separator()
        perf:slider("esp_max_marks", "Maximum things marked", 0, 300, 60, "")
        perf:label("0 means no limit. What is kept is what matters: bosses, rares,")
        perf:label("quest and guide targets first, then the nearest of the rest.")
        perf:slider("esp_draw_budget", "Draw calls per frame", 0, 3000, 0, "")
        perf:label("0 means no limit. Only the reduced-detail marks are ever dropped.")
        perf:slider("esp_detail_reads", "Unit detail reads per frame", 0, 32, 8, "")
        perf:label("Casts and targets of hostiles come free from JCore's enemy tracker.")
        perf:label("This budget is for the few it does not track, refreshed this many a")
        perf:label("frame; the rest reuse the answer from a fraction of a second ago.")
        perf:slider("esp_los_budget", "Line-of-sight checks per frame", 0, 32, 0, "")
        perf:label("0 disables the checks entirely. Tracing world geometry is the most")
        perf:label("expensive question the overlay can ask, so it is rationed hard.")
        perf:separator("Diagnosis")
        perf:toggle("esp_explain", "Explain what is NOT being marked", false)
        perf:label("Adds a line below naming the nearest thing the overlay skipped and")
        perf:label("the setting that skipped it. Costs a position read per skipped")
        perf:label("unit, which is the work skipping them saved -- so leave it off")
        perf:label("once it has answered.")
    end

    -- --- the aurora around you (1.86.0) -----------------------------------------
    -- Both ESPs' page. Lemons' Aurora Systems plugin, made to read the fight
    -- (modules/aurora.lua).
    local aurora = esp:section("Aurora around you", "activity", { column = "full" })
    aurora:toggle("aurora_on", "Show an aurora around you", false)
    aurora:label("Calm out of combat, rising in a fight. Warmer as your health drops,")
    aurora:label("red and breathing under a quarter. Each enemy on you adds a fold.")
    aurora:dropdown("aurora_colors", "Colours", cfg.AURORA_COLORS, 1)
    aurora:toggle("aurora_fill", "A glowing sheet between its lines", true)
    aurora:toggle("aurora_combat_only", "Only in a fight", false)
    aurora:slider("aurora_radius", "Size", 1.0, 5.0, 2.0, "yd")
    aurora:slider("aurora_height", "Height", 0.5, 3.0, 1.2, "yd")
    aurora:slider("aurora_speed", "Speed", 0.25, 3.0, 1.0, "x")
    aurora:slider("aurora_detail", "Detail", 16, 72, 36, "")
    aurora:label("Lemons' Aurora Systems plugin is not needed for this: with both on")
    aurora:label("you get two curtains. Needs JCore 1.11.")

    -- --- fight timers (1.87.0) -------------------------------------------------
    -- Your spells' clocks under your target, and the next kill
    -- (modules/timers.lua).
    local timers = esp:section("Fight timers", "activity", { column = "full" })
    timers:toggle("timers_on", "Your damage and healing over time as rings under your target", true)
    timers:toggle("timers_warn", "Red with 3 s left, and a pulse when one runs out", true)
    timers:toggle("killnext_on", "A curtain on the mob to kill next (the reactions' plan)", false)
    timers:label("The plan picks a kill in a fight of two or more when you are not the")
    timers:label("tank or the healer.")

    -- --- group and healing (1.87.0) ----------------------------------------------
    -- Your group's health and its loose mobs (modules/party.lua).
    local party = esp:section("Group and healing", "activity", { column = "full" })
    party:toggle("party_on", "Show your group on the ground", true)
    party:toggle("party_rings", "A ring under each hurt member, filling red", true)
    party:toggle("party_heal_curtain", "A green curtain on the one who most needs a heal", false)
    party:slider("party_heal_at", "Heal at", 20, 90, 50, "%")
    party:toggle("party_loose", "An orange curtain on a mob loose on someone not the tank", false)
    party:toggle("party_self", "Count yourself too", false, ADV)
    party:label("With no tank known (Era players rarely set a role), only a mob on a")
    party:label("healer counts as loose; when you are the tank, one on anyone else.")

    -- --- group extras (1.89.0) ----------------------------------------------------
    -- Out of your heal range, the tank's hold, the healers' mana
    -- (modules/groupextras.lua).
    local groupx = esp:section("Group extras", "activity", { column = "full" })
    groupx:toggle("groupx_on", "Show group extras on the ground", true)
    groupx:toggle("groupx_range", "A grey ring under anyone out of your heal range", true)
    groupx:slider("groupx_heal_range", "Heal range when your class does not say", 20, 45, 40, "yd", ADV)
    groupx:toggle("groupx_tank", "A curtain round the tank: green holding, amber close, red a mob off them", false)
    groupx:toggle("groupx_mana", "A ring under each healer filling with their mana, red under 20%", true)
    groupx:label("Range rings only for a priest, paladin, druid or shaman, at the class window's")
    groupx:label("Heal range. The tank is the group's role, or Assist the tank's when it is on.")
    groupx:label("Stack and spread are not drawn: no boss mod JCore can read says them.")


    -- Live counters, so the sliders above are set against what is actually
    -- happening rather than against a guess.
    esp:live_lines(6, function()
        if not P.esp or not P.draw then return {} end
        local ok, s = pcall(P.esp.stats)
        if not ok or not s then return {} end
        local d = P.draw.stats()

        local lines = {}

        -- The first thing to rule out, and the one nothing else would show:
        -- the overlay is working and the toggle key has it hidden.
        if not master_on() then
            lines[#lines + 1] = "Everything is switched off on the Jambix AIO page."
        elseif not opt("enabled", true) then
            lines[#lines + 1] = "ESP is switched off above. Quest marks and RestedXP follow the Quests page."
        elseif not toggle_active() then
            lines[#lines + 1] = "Hidden right now by the toggle key -- press it to show the overlay."
        end

        local body = {
            string.format("Marked %d  (near %d / mid %d / far %d)   threats %d   nodes %d",
                s.entities or 0,
                (s.by_lod and s.by_lod.full) or 0,
                (s.by_lod and s.by_lod.mid) or 0,
                (s.by_lod and s.by_lod.far) or 0,
                s.threats or 0, s.nodes or 0),
            string.format("Draw calls %d submitted / %d painted / %d culled / %d dropped",
                d.submitted or 0, d.painted or 0, d.culled or 0, d.dropped or 0),
        }
        for i = 1, #body do lines[#lines + 1] = body[i] end

        -- Whether nameplates are being seen, by either route: if a plate
        -- covers marks in the game and this says 0 / 0, the client is not
        -- answering, and the log has the one raw answer it did give.
        local diag = (not P.forever) and P.esp_elements and P.esp_elements.plate_diag
        if diag and opt("esp_plate_mode", cfg.PLATE_BELOW) ~= cfg.PLATE_IGNORE then
            lines[#lines + 1] = string.format(
                "Nameplates: %d unit(s) wearing a plate token   client answers %d asked / %d shown / %d placed",
                diag.tokens or 0, diag.asked or 0, diag.shown or 0, diag.accepted or 0)
        end

        -- The Forever ESP's icons (1.69.0): whether the shipped art pack
        -- made it to the screen, and if not, why every mark is in words.
        local art = P.forever and P.esp_art
        if art and art.stats then
            local ok_a, a = pcall(art.stats)
            if ok_a and a then
                lines[#lines + 1] = a.available
                    and string.format("Game icons: %d, pack %s", a.cells or 0, tostring(a.version))
                    or ("Game icons unavailable (" .. tostring(a.why) .. "): marks use words")
            end
        end

        local ok_why, why = false, nil
        if not P.forever then ok_why, why = pcall(P.esp.explain) end
        if ok_why and why then
            lines[#lines + 1] = string.format(
                "Not marked: %d  (%d category off, %d out of range)   sweep %dy",
                why.total, why.category_off, why.out_of_range, why.sweep_range or 0)
            if why.nearest then
                lines[#lines + 1] = string.format("Nearest skipped: %s at %.0fy -- %s",
                    why.nearest.name ~= "" and why.nearest.name or "?",
                    why.nearest.distance, why.nearest.reason or "")
            end
        end

        return lines
    end)

    -- --- rotation page ------------------------------------------------------

    -- Declared here so it sits at the top of the page; the dropdowns inside it
    -- are added by the class registration loop further down.
    local rot_profile_section = rotation:section("Profile", "list", { column = "full" })
    rot_profile_section:label("Chosen from your talents, and from your role when the group gives you")
    rot_profile_section:label("one (a tank in a dungeon gets the tank profile). There is no selector:")
    rot_profile_section:label("the profile is only which spells you have -- what to press with them is")
    rot_profile_section:label("decided by the fight. The live readout below names the one in use.")

    --- A section only this class sees.
    ---
    --- Everything below is split between what is TRUE OF EVERY CLASS and what
    --- is not. A warlock has no Shield Block, no stance, no rage and no Taunt,
    --- and showing those rows to one is not merely untidy -- it suggests the
    --- rotation does something it cannot.
    ---
    --- The gate is a per-frame function on the section, so it resolves as soon
    --- as the class does and costs one comparison.
    ---@param title string
    ---@param icon string
    ---@param class_name string  enum name, e.g. "WARLOCK"
    ---@param opts? table
    local function class_section(title, icon, class_name, opts)
        opts = opts or { column = "full" }
        -- In the class's window since 1.63.0; here with advanced settings on.
        opts.visible = function()
            return advanced() and P.rotation and P.rotation.detect_class() == class_name
        end
        return rotation:section(title, icon, opts)
    end

    --- A section shown only when the class can actually do the thing.
    ---@param title string
    ---@param icon string
    ---@param capability string  field on the class module
    ---@param opts? table
    local function capability_section(title, icon, capability, opts)
        opts = opts or { column = "full" }
        -- In the class's window since 1.63.0; here with advanced settings on.
        opts.visible = function()
            if not advanced() then return false end
            local class_module = P.rotation and P.rotation.active_class()
            return class_module ~= nil and class_module[capability] == true
        end
        return rotation:section(title, icon, opts)
    end

    local rot_general = rotation:section("Rotation", "swords", { column = "left" })
    rot_general:toggle("rot_enabled", "Enable rotation", false)
    rot_general:keybind("rot_key", "Rotation key", 0x58, {
        mode = "toggle", modes = { "toggle", "hold" }, default_active = false,
    })
    -- The profile selector is NOT declared here. A widget's options are fixed
    -- when it is declared and the class is not known until the player object
    -- exists, so one shared dropdown could only offer meaningless generic
    -- labels. Instead there is one dropdown PER CLASS, declared in the class
    -- registration loop with that class's real profile names and gated on the
    -- detected class -- see rot_profile_section below.
    --
    -- Per-class widget ids also fix a real collision: settings persist per
    -- plugin, not per character, so a single `rot_profile` index would be
    -- shared between a warrior and a mage on the same account, where "3" means
    -- two different profiles.
    rot_general:toggle("rot_open_combat", "Start fights on the selected target", false)
    rot_general:label("Off: a selected target is only attacked once it engages you or your pet,")
    rot_general:label("once you attack it yourself, or while the engage key is held. Selecting")
    rot_general:label("is not attacking. The pet follows the same rule.")
    rot_general:keybind("rot_engage_key", "Engage key (open on the target while held)", 0x47, {
        mode = "hold", modes = { "hold", "toggle" }, default_active = false,
    })
    -- Interrupts, defensives, racials and dispels are not switches any more:
    -- the reaction engine decides them from the fight (see Reactions below).
    -- Nor are offensive cooldowns and trinkets (1.39.0): the burst window
    -- spends them when the fight is long enough and spending changes it.
    rot_general:toggle("rot_respect_cast", "Never interrupt my own cast", true, ADV)
    rot_general:slider("rot_cast_slack", "Resume this long before a cast ends", 0, 100, 25, "cs", ADV)
    rot_general:toggle("rot_group_buff", "Keep group buffs up out of combat", true)
    rot_general:toggle("rot_buff_party", "Buff party members too", true)

    -- Generic tuning: every class has an AoE radius and DoTs worth a duration
    -- check. Nothing here names a class ability.
    local rot_tuning = rotation:section("Tuning", "settings", { column = "right", visible = advanced })
    rot_tuning:label("Every threshold is worked out from live data: the real mana cost of")
    rot_tuning:label("your spells, their real cast times, your regeneration, and the rate")
    rot_tuning:label("your health is dropping. There are no sliders to set.")
    rot_tuning:toggle("rot_own_dots_only", "Only count damage-over-time spells you cast", true)
    rot_tuning:label("A DoT snapshots the caster who applied it, so somebody else's")
    rot_tuning:label("Corruption on your target is worth nothing to you. Turn this off")
    rot_tuning:label("only if your own DoTs are reported as never landing.")

    local rot_burst = rotation:section("Cooldowns", "flame", { column = "right", visible = advanced })
    rot_burst:label("A burst window opens when spending changes an outcome: the fight")
    rot_burst:label("is long enough for the buff to pay back, and either we are losing")
    rot_burst:label("the race, or there are enough enemies that clearing sooner means")
    rot_burst:label("less damage taken. Trinkets and the offensive racial are pulled")
    rot_burst:label("into the same window so they multiply each other.")

    -- The spell window (modules/timeline.lua). Its place on the screen is
    -- not a setting: the window is dragged by its title bar and JCore's
    -- overlay UI remembers where it was left.
    local rot_hud = rotation:section("Spell window", "list", { column = "right" })
    rot_hud:toggle("rot_hud_enabled", "Show the spell window", true)
    rot_hud:label("Spells used on the left, the cast in progress, then the next")
    rot_hud:label("press (large) and the ones after it. Drag it by its title bar;")
    rot_hud:label("double-click the title to fold it away.")
    rot_hud:slider("rot_hud_size", "Icon size", 20, 64, 40, "px", ADV)
    rot_hud:slider("rot_hud_history", "Spells used shown", 0, 12, 6, "", ADV)
    rot_hud:slider("rot_hud_next", "Spells coming shown", 1, 6, 3, "", ADV)
    rot_hud:toggle("rot_hud_suggest", "Suggest the next spells while the rotation is off", true, ADV)
    rot_hud:toggle("rot_hud_autos", "Include Auto Shot, wand and melee swings", false, ADV)
    rot_hud:toggle("rot_hud_combat_only", "Only in combat or with a target", false, ADV)

    -- THE CLASS WINDOW (1.62.0; modules/classwin.lua): every class's own
    -- window, as the hunter's Aspects window was. Its place on the screen is
    -- JCore's to remember, like the spell window's.
    local rot_classwin = rotation:section("Class window", "leaf", { column = "right" })
    rot_classwin:toggle("class_window", "Show your class's window", true)
    rot_classwin:label("Aspects, auras, seals, blessings, armors, shields, stances, forms")
    rot_classwin:label("and the buffs to keep up, for your class. Auto lets the rotation")
    rot_classwin:label("decide, as before. Anything picked there is kept up by the window,")
    rot_classwin:label("and the rotation leaves it alone. Your class's settings (threat,")
    rot_classwin:label("healing, pet, stealth, kiting...) are in that window too, and here")
    rot_classwin:label("with Show advanced settings on (Overview page).")
    -- 1.7.5: what the window keeps up with the rotation paused or off. In
    -- the class window too (classwin_data.lua, OPTIONS.common).
    rot_classwin:dropdown("classwin_paused", "While the rotation is paused, keep up",
        { "Out-of-combat buffs", "Everything picked here", "Nothing" }, 1)
    rot_classwin:label("Out-of-combat buffs: armors, auras, blessings, Fortitude and the like,")
    rot_classwin:label("out of combat only; never a seal, a stance or a form. Everything:")
    rot_classwin:label("as before 1.7.5, but a stance or form you take yourself is left alone.")

    local rot_field = rotation:section("Reading the fight", "eye", { column = "left" })
    rot_field:label("The rotation measures the race it is in: how long until everything")
    rot_field:label("on you is dead against how long until you are. Both sides are read")
    rot_field:label("from what is actually happening, not from a health percentage --")
    rot_field:label("so a second mob arriving changes the answer immediately, several")
    rot_field:label("seconds before the health bar would have shown it.")
    rot_field:label("When the race is lost, the reaction engine breaks contact on its own,")
    rot_field:label("with enough life left to get away: the time your quickest escape takes.")
    rot_field:toggle("rot_spread", "Put damage-over-time spells on everything fighting you", true)
    rot_field:keybind("rot_spread_key", "Spreading on/off", 0x43, {
        mode = "toggle", modes = { "toggle", "hold" }, default_active = true,
    })
    rot_field:keybind("rot_fear_key", "Crowd control (hold or toggle)", 0x56, {
        mode = "hold", modes = { "hold", "toggle" }, default_active = false,
    })
    rot_field:label("Fear and the like NEVER fire on their own. They wait for this key,")
    rot_field:label("and an unbound key means never -- a fear nobody asked for breaks a")
    rot_field:label("sheep, pulls a second pack, or wipes a group.")
    rot_field:separator()
    rot_field:label("Three mobs each carrying a Corruption is three times the damage for")
    rot_field:label("the same three global cooldowns. Turn it off for a pull being held")
    rot_field:label("together on one target, or next to something somebody has sheeped.")

    -- The reactions are APART from the rotation (1.8.0): their switches,
    -- their marks and their readout are all on the Reactions page now. A
    -- setting moved to another page loses what you saved, so the decision
    -- log, the on-screen panel, the world marks and the two curtains start
    -- from their defaults there.

    -- --- reactions page (1.76.0) ----------------------------------------------
    --
    -- The user, 2026-10-05: Reactions get a tab of their own -- first the
    -- switch that has them act in the rotation, then a button that opens the
    -- Reactions window (modules/reactwin.lua): the built-in reactions switched
    -- and placed one by one, and your own made in the GUI or in Lua.
    local react_main = reactions_page:section("Reactions in the rotation", "activity", { column = "full" })
    -- No switch. The user, 2026-10-11: "reactions should automatically
    -- activate in PvP when PvP is detected", not an option. The engine is the
    -- path again (1.32.0): R.active() and custom.master_on() always say yes,
    -- and a react_active a player saved before changes nothing. PvP is
    -- detected by the intelligence layer (intel/state.lua, W.intel.active and
    -- its signs) and, under it, by the picture's env.pvp.
    react_main:label("Reactions run on their own; nothing here switches them. Each one says when the")
    react_main:label("rotation should give way -- an interrupt, a defensive, a potion, an escape, crowd")
    react_main:label("control, the pet, threat -- in a pass of their own just before the rotation's, on")
    react_main:label("the same picture of the fight, and the most important one wins. The PvP reactions")
    react_main:label("and the intelligence below wake the moment PvP is detected: a player targeted or on")
    react_main:label("you, an enemy player within 40 yd, a player's control on you, a battleground, an")
    react_main:label("arena, a duel. The first line under this page says what is detected now.")
    -- The *Open Reactions UI* button left this page on 2026-10-11 (the user:
    -- "should be removed from being accessed by the player but leave it in
    -- the code for future"). The window (modules/reactwin.lua, P.reactwin,
    -- P.reactwin.open(tab)) is loaded and rendered as before and nothing a
    -- player can reach opens it; the built-in and custom reactions it edits
    -- still run from their saved state.

    -- Reading a decision (1.8.0: here, not on the Rotation page). The
    -- readout at the bottom of this page says why the last decision was
    -- made; the Debug page keeps the recent history.
    local react_read = reactions_page:section("Decisions", "activity", { column = "full" })
    react_read:toggle("react_overlay", "Show the decision on screen", false)
    react_read:toggle("react_explain_log", "Log every decision and every refusal", false)
    react_read:label("The readout at the bottom of this page says why the last decision was made:")
    react_read:label("the mode, the danger, the winning reaction with every point of its score, the")
    react_read:label("runners-up and what was refused. The Debug page keeps the recent history.")

    -- The user, 2026-10-11: "remove all other reactions from the menu that
    -- don't have to do with these phases ... we want to drop/delete old stuff
    -- and not get it confused". The old *PvP* (the trinket's line), *PvP
    -- marks*, *PvP extras* and *In the world* sections left this page that
    -- day with their modules (pvpmarks, pvpx, plays, react/marks), deleted,
    -- not hidden. The page is the engine's switches, the decision readout and
    -- the PvP intelligence layer (PVP_INTEL_PLAN.md §3.11).

    -- PvP intelligence (PVP_INTEL_PLAN.md; modules/react/intel): the picture of
    -- a fight with players, the threat, the cooldown ledger, the tactical
    -- state and the move. Each module its own switch; the first is the
    -- emergency switch for the whole layer. Modules not built yet say so.
    local intel = reactions_page:section("Advanced PvP Intelligence", "swords", { column = "full" })
    intel:toggle("intel_enabled", "PvP intelligence: the picture, read once a tick (off: nothing of this layer runs)", true)
    intel:toggle("intel_alerts", "Say each new tactical state and move on screen (the narration banners)", true)
    intel:toggle("intel_threat", "Threat evaluation: how much danger is coming, from whom, how sure", true)
    intel:toggle("intel_cooldowns", "Cooldown management: their ledger, your cover; holds a second defensive while covered", true)
    intel:toggle("intel_tactics", "Hunter PvP tactics: the tactical state, the aspect for the moment", true)
    intel:toggle("intel_position", "Positioning awareness: the move advice (hold, increase, reduce, line of sight...)", true)
    intel:toggle("intel_kill", "Kill window detection: its escapes, defensives and heals against your burst and your risk", true)
    intel:toggle("intel_team", "Teamfight awareness: who is focused, peels, which cast to stop, target switches, the enemy healer, overextending", true)
    intel:toggle("intel_cc", "Crowd control planning: each control on a player, whose, what breaks it, its diminishing returns, what it is worth; holds your damage off one worth keeping", true)
    intel:toggle("intel_predict", "Opponent prediction: what each player tends to do this session (closes when slowed, a defensive at N%, interrupts, escapes control, stacks bursts, goes for the pet, the same opener, backs off, saves cooldowns), never from one sighting", true)
    intel:toggle("intel_bait", "Cooldown baiting: a Concussive Shot to draw a predicted charge into your ready counter or a trinket before the real trap; the burst held for an unseen defensive; a cast to show an interrupter (advice). Never while the threat is HIGH", true)
    intel:toggle("intel_learn", "Opponent pattern learning: keep counting what players do (off: the counts freeze, the predictions stand as they are)", true, ADV)
    -- The fight debriefs and the central database (2026-10-12).
    intel:toggle("intel_debrief", "Fight debriefs: each fight with a player recorded -- what they used, what you used, what stayed ready, how it ended -- with its lessons (the log: scripts_data/jambix.aio.fights.json)", true)
    intel:toggle("intel_debrief_say", "Say each fight's outcome and first lesson on screen", true)
    intel:toggle("intel_memory", "Opponent memory: the players you fought and their habits, kept across sessions, and what your own fights say of each class -- where a prediction starts, never past the evidence (the file: scripts_data/jambix.aio.opponents.json)", true)
    intel:toggle("intel_history", "History ledger: each fight's predictions scored, major cooldowns spent for nothing, overlapping controls and defensives, how often the advice changed, advice you could not follow (the log: scripts_data/jambix.aio.history.json; no win rate)", true)
    intel:toggle("intel_episodes", "Decision episodes: a window round each tactical moment (a charge, a burst, a root, the dead zone, a kill window...) with the state before and after, what was predicted and advised, what you did, and a measured result", true)
    intel:label("Nothing here presses a key but the aspect for the moment, through the Aspects window's")
    intel:label("own switch. The rest is advice: three rows in this page's readout, the banners, the")
    intel:label("conditions your own reactions can read (PvP threat level, tactical state, move advice,")
    intel:label("the target's cooldowns...), and the Reactions window's Live view. An inference is")
    intel:label("never shown as a fact: it carries its confidence, and what the client cannot say is listed.")

    -- The last fight's debrief (react/intel/debrief.lua) and the central
    -- database's word (react/intel/central.lua): the lessons of each fight.
    local debrief_section = reactions_page:section("Fight debriefs and the shared network", "book", { column = "full" })
    debrief_section:label("After each fight with a player: how it ended, what each side used, your lows, and the")
    debrief_section:label("lessons -- what stayed ready that could have turned it, what beat you, what held. The")
    debrief_section:label("last 50 are kept in scripts_data/jambix.aio.fights.json (your own file, names kept).")
    -- The shared network (CENTRAL_NETWORK.md): consent, off until turned on.
    debrief_section:toggle("net_contribute", "Contribute my fights to the shared network (off until you turn it on)", false)
    debrief_section:toggle("net_diagnostics", "...and include extra detail: the fight's moments and states, names stripped", false)
    debrief_section:toggle("net_download", "Download the network's learning: priors for new opponents and matchup advice (off until you turn it on)", false)
    debrief_section:button("net_delete_queue", "Delete queued local submissions", {
        on_click = function()
            local I = P.react and P.react.intel
            if I and I.central then I.central.delete_queue() end
        end,
    })
    debrief_section:button("net_delete_remote", "Request deletion of my uploaded records and start a new identifier", {
        on_click = function()
            local I = P.react and P.react.intel
            if I and I.central then I.central.request_delete() end
        end,
    })
    debrief_section:label("What goes up, only with the first switch on and only after a fight: a random identifier of")
    debrief_section:label("this install (a pseudonym; the button above replaces it), this plugin's version, the game")
    debrief_section:label("and build, your class and level, the opponents' classes and roles, the encounter type and")
    debrief_section:label("length, each forecast as it stood before its outcome with the outcome and what it rested")
    debrief_section:label("on, the ability names each side used, the lessons' codes. Never names, account, chat or realm.")
    debrief_section:label("It is queued on this machine and sent between frames; the service keeps it until you ask for")
    debrief_section:label("deletion (the second button) or its retention runs out. Combat never waits on the network:")
    debrief_section:label("offline, with the service down or a model withdrawn, everything here runs as it did.")
    -- The page's live lines (a page's, not a section's): the last fight.
    reactions_page:live_lines(14, function()
        local I = P.react and P.react.intel
        local d = I and I.debrief
        if not d then return { "The PvP intelligence layer did not load." } end
        local ok, lines = pcall(d.lines)
        if not ok then return { "debrief readout failed: " .. tostring(lines) } end
        return lines
    end)
    -- The history ledger (react/intel/history.lua): this fight and every fight kept.
    reactions_page:live_lines(5, function()
        local I = P.react and P.react.intel
        local h = I and I.history
        if not h then return {} end
        local ok, lines = pcall(h.lines)
        if not ok then return { "history readout failed: " .. tostring(lines) } end
        return lines
    end)

    reactions_page:live_lines(4, function()
        local custom = P.react and P.react.custom
        if not custom then return { "The reaction engine did not load." } end
        local here, total = 0, 0
        for _, d in ipairs(custom.defaults()) do
            total = total + 1
            if d.here then here = here + 1 end
        end
        local mine, mine_on = 0, 0
        for _, r in ipairs(custom.list()) do
            mine = mine + 1
            if r.on ~= false then mine_on = mine_on + 1 end
        end
        local last, last_def = nil, nil
        for _, def in ipairs(P.react.rules()) do
            if def.fired_at and (not last or def.fired_at > last) then last, last_def = def.fired_at, def end
        end
        -- PvP detected? The intelligence layer's answer with its signs; under
        -- it (switched off), the picture's env.pvp.
        local pvp
        local W = custom.latest_W and custom.latest_W()
        local S = W and W.intel
        if S and not S.off then
            pvp = S.active and ("PvP detected: " .. tostring(S.why)) or ("no PvP sign: " .. tostring(S.why))
        elseif W and W.env and W.env.pvp then
            pvp = "PvP detected: " .. (W.env.context == "pvp" and "a PvP instance" or "your target is a player")
        else
            pvp = "no PvP sign"
        end
        return {
            string.format("Reactions: automatic  |  %s  |  %d built-in (%d act here)  |  %d of your own (%d on)",
                pvp, total, here, mine, mine_on),
            "Where you are: " .. custom.where_text(),
            last_def and string.format("Last sent: %s -> %s, %.0fs ago", last_def.name, tostring(last_def.fired_name or "?"),
                core.time() - last) or "Last sent: nothing yet this session",
            custom.lua_available() and "" or "This loader cannot run Lua code: Lua rows are kept but never run.",
        }
    end)

    -- Why the reactions did what they did: the mode, the danger, the winning
    -- action with every point of its score, the runners-up and what was
    -- refused. Built only while this page is open. One more row for the PvP
    -- line (1.81.0), one for "OFF" (1.8.0), and three for the intel picture
    -- while it is on (PvP intelligence, Phase 2; the state and the move, Stage 4).
    reactions_page:live_lines(P.forever and 41 or 40, function()
        if not P.react then return {} end
        local ok, lines = pcall(P.react.debug_lines)
        if not ok then return { "reaction readout failed: " .. tostring(lines) } end
        return lines
    end)

    local rot_target = rotation:section("Targeting", "target", { column = "full" })
    rot_target:toggle("rot_auto_target", "Pick targets automatically", true)
    rot_target:label("Prefers what is nearly dead, then what is hitting you, then quest targets.")
    rot_target:label("Out of a fight, what is closing on you or already looking at you is")
    rot_target:label("opened on first: it is the fight whether you pick it or not.")
    rot_target:slider("rot_target_range", "Target search range", 10, 50, 30, "yd")
    rot_target:slider("rot_switch_margin", "Switch only if clearly better", 0, 100, 25, "pts", ADV)
    -- "Assist the tank" (1.70.0, modules/assist.lua). Also in every class's
    -- window, under Group.
    rot_target:toggle("rot_assist_tank", "Assist the tank in a group", false)
    rot_target:label("Playing damage in a group: your target is the tank's, and changes when")
    rot_target:label("the tank's does. The tank pulls: a mob is not opened on until it is in")
    rot_target:label("combat. The tank is the group's role, else whoever the mobs are on or")
    rot_target:label("is in a tank's stance or form. Not for the tank or the healer.")

    -- Threat only exists for a class that can tank. A mage has no Taunt and no
    -- reason to be offered one.
    local rot_threat = capability_section("Threat and aggro", "shield", "tank_capable")
    rot_threat:toggle("rot_hold_aggro", "Reclaim enemies nobody is holding", true)
    rot_threat:slider("rot_challenging_shout_count", "Mass taunt at", 2, 8, 3, "loose")
    -- A dropdown, not a toggle: "solo only" and "solo and party" are genuinely
    -- different answers, and a tank levelling with one friend wants the second.
    rot_threat:dropdown("rot_aggro_scope", "Reclaim aggro in", {
        "Solo only",
        "Solo and open-world groups",
        "Everywhere except raids",
        "Everywhere",
    }, 2)

    local rot_forms = capability_section("Forms and stances", "flame", "uses_forms")
    rot_forms:label("Changing form is not free, so the default is to pick one and stay.")
    rot_forms:toggle("rot_allow_dance", "Allow switching mid-fight", false)

    local rot_wand = capability_section("Wand", "bolt", "wand_capable")
    rot_wand:label("Wanding is free damage. Levelling a caster is a mana game.")
    rot_wand:toggle("rot_use_wand", "Use the wand", true)
    rot_wand:label("It carries the damage once the mana will not last the fight -- worked")
    rot_wand:label("out from your real spell costs and regeneration, not set here.")

    local rot_heal = capability_section("Healing", "heart", "heal_capable")
    rot_heal:label("Used by healing profiles. Targets the lowest-health ally in range.")
    rot_heal:slider("rot_heal_range", "Heal range", 20, 40, 40, "yd")
    rot_heal:slider("rot_heal_renew_hp", "Heal-over-time below", 50, 100, 85, "%")
    rot_heal:slider("rot_heal_flash_hp", "Fast heal below", 20, 90, 50, "%")
    rot_heal:slider("rot_heal_big_hp", "Big heal below", 10, 80, 40, "%")
    rot_heal:slider("rot_heal_shield_hp", "Shield below", 20, 100, 70, "%")
    rot_heal:toggle("rot_heal_dps", "Contribute damage when nobody is hurt", true)

    -- --- pet section --------------------------------------------------------

    local pet_section = capability_section("Pet", "paw", "pet_capable")
    pet_section:label("A pet has one job at a time; the mode says which.")
    pet_section:dropdown("pet_mode", "Pet mode", {
        "Off (leave the pet alone)",
        "Assist -- attack my target (Growl on when solo, off in a group)",
        "Tank -- grab whatever nobody is holding (Growl on)",
        "Focus -- stay on one designated unit",
    }, 2)
    pet_section:label("Growl follows the mode, the pet interrupts, and Mend Pet or Health")
    pet_section:label("Funnel go out when the pet is losing -- earlier solo, where the pet is")
    pet_section:label("your tank -- all decided by the reaction engine.")
    pet_section:button("pet_focus_target", "Focus my current target", {
        on_click = function()
            if not P.pet then return end
            P.pet.set_focus(P.combat.target())
        end,
    })
    pet_section:button("pet_focus_clear", "Clear pet focus", {
        on_click = function()
            if P.pet then P.pet.set_focus(nil) end
        end,
    })

    -- --- hardcore page ------------------------------------------------------

    local hc_survival = hardcore:section("Survival", "shield", { column = "left" })
    hc_survival:toggle("hc_enabled", "Enable hardcore utilities", true)
    hc_survival:label("On: below 20% health the rotation stops attacking until you are back")
    hc_survival:label("over 35% -- potions, escapes and defensives still go out.")
    hc_survival:toggle("hc_block_pulls", "Never start a fight when hurt", true)
    hc_survival:slider("hc_pull_hp", "Only pull above", 20, 100, 70, "%")

    local hc_items = hardcore:section("Emergency items", "flask", { column = "right" })
    hc_items:label("A healthstone, then a healing potion, go out when health is under")
    hc_items:label("35% or on course for it; a mana gem or potion when the fight will")
    hc_items:label("outlast your mana. Escapes break contact when the fight is lost.")
    hc_items:toggle("hc_hearth", "Hearthstone as a last resort", false)
    hc_items:label("Under 15%, bailing out, and nothing hitting you to stop the cast.")
    hc_items:label("Nothing here moves your character. Fleeing stays your call.")

    local sense_section = hardcore:section("Awareness", "eye", { column = "full" })
    sense_section:label("Stealth is read from the aura TYPE, so it covers players and mobs alike.")
    sense_section:toggle("sense_stealth_watch", "Watch for stealth", true)
    sense_section:slider("sense_vanish_range", "Treat a vanish as a threat within", 5, 60, 25, "yd", ADV)
    sense_section:slider("sense_vanish_memory", "Stay suspicious for", 3, 60, 12, "s", ADV)

    -- Pull safety (1.87.0): how close you can walk before something comes
    -- (modules/pull.lua).
    local pull_section = hardcore:section("Pull safety", "shield", { column = "full" })
    pull_section:label("A ring under each hostile mob not yet fighting, at the range it notices")
    pull_section:label("you from. It fills and turns red as you walk toward its edge. Never under")
    pull_section:label("a player or a player's pet: they notice nobody from a distance.")
    pull_section:toggle("pull_on", "Show how close you can walk", true)
    pull_section:toggle("pull_rings", "Aggro rings", true, ADV)
    pull_section:slider("pull_margin", "Show a ring from this far outside it", 4, 30, 12, "yd")
    pull_section:slider("pull_base", "Aggro range at your own level", 10, 30, 20, "yd", ADV)
    pull_section:slider("pull_max", "Most rings at once", 1, 20, 8, "", ADV)
    pull_section:toggle("pull_curtains", "A curtain on elites, rares and bosses heading your way", false)
    pull_section:toggle("pull_rare_pulse", "A pulse when a rare comes into view", true)

    local narrate_section = hardcore:section("Narration", "message", { column = "full" })
    narrate_section:label("There is no text-to-speech in this API. These are on-screen cues.")
    narrate_section:toggle("narrate_enabled", "Explain what the plugin is doing", true)
    narrate_section:toggle("narrate_sound", "Play a sound with danger and warnings", true)
    narrate_section:toggle("narrate_warnings", "Warnings", true, ADV)
    narrate_section:toggle("narrate_actions", "Every action (verbose)", false, ADV)
    narrate_section:toggle("narrate_info", "Routine information", false, ADV)

    local hc_warn = hardcore:section("Warnings", "alert", { column = "full" })
    hc_warn:toggle("hc_banner", "Full-width low-health banner", true)
    hc_warn:slider("hc_banner_hp", "Banner below", 10, 70, 35, "%", ADV)
    hc_warn:toggle("hc_warn_adds", "Warn when enemies join the fight", true)
    hc_warn:slider("hc_add_threshold", "Warn at", 2, 6, 2, "enemies", ADV)
    hc_warn:toggle("hc_warn_breath", "Warn while drowning", true)
    hc_warn:slider("hc_breath_warn", "Breath warning below", 10, 80, 40, "%", ADV)
    hc_warn:toggle("hc_warn_durability", "Warn on low durability", true)
    hc_warn:slider("hc_durability_warn", "Durability below", 5, 60, 25, "%", ADV)
    hc_warn:toggle("hc_sound", "Play a sound with warnings", true)

    -- --- world marks page (1.89.0) --------------------------------------------
    --
    -- The user, 2026-10-09: "Calibration window, Performance budget, Ring
    -- layout + World marks page, Line-of-sight fade". The look of every
    -- world mark is here; each mark's own switches stay where they were
    -- (moving a widget to another page would lose what you saved).
    local world_look = world_page:section("Look", "eye", { column = "left" })
    world_look:toggle("world_on", "Draw the AIO's world marks", true)
    world_look:slider("world_brightness", "Brightness", 25, 150, 100, "%")
    world_look:dropdown("world_density", "Detail", { "Full", "Reduced", "Minimal" }, 1)
    world_look:label("Reduced: fewer lines and a fainter sheet on curtains and beacons.")
    world_look:label("Minimal: also leaves the decoration out (the aurora, node pillars).")
    world_look:dropdown("world_colorblind", "Colour-blind colours", {
        "Off", "Protanopia (red-weak)", "Deuteranopia (green-weak)", "Tritanopia (blue-weak)" }, 1)
    world_look:label("Shifts every mark's colours so what tells them apart is a difference you see.")

    local world_perf = world_page:section("Performance", "activity", { column = "right" })
    world_perf:slider("world_budget", "Most world shapes a frame", 0, 600, 200, "")
    world_perf:label("0: no cap. Past it decoration goes first, then information;")
    world_perf:label("a warning (inside a mob's aggro range, a loose mob, a kick) never.")
    world_perf:toggle("world_los", "Fade marks under units behind walls", true)
    world_perf:slider("world_los_checks", "Line-of-sight checks a frame", 1, 32, 8, "", ADV)

    -- --- curtains (1.7.6) ----------------------------------------------------------
    --
    -- The user, 2026-10-09: "the Aura curtains are over power the entire
    -- game! We need to Work them yes but have them off by Default", then "any
    -- and all should have an option to turn on and off". Every curtain the
    -- AIO draws has a switch of its own, beside the rest of its mark, and all
    -- of them are off by default. This section says where each one is and
    -- switches them all at once. Each entry: the page, the switch, the value
    -- that draws the curtain (the ESP's box style is a dropdown), and where;
    -- a fifth, 2, for the ones the second switch-off below covers.
    --
    -- The user, 2026-10-10: "enemies should not have Curtain up by default
    -- should be off". JCore draws a beacon as a narrow curtain, ten yards and
    -- more tall, and the ESP stood one on every far rare, boss and quest mob,
    -- and the battleground marks one on each flag carrier: curtains too, now.
    local CURTAINS = {
        { esp, "aurora_on", true, "The aurora around you: ESP, Aurora around you" },
        { hardcore, "pull_curtains", true, "Elites, rares and bosses heading your way: Hardcore, Pull safety" },
        { esp, "killnext_on", true, "The mob to kill next: ESP, Fight timers" },
        { esp, "party_heal_curtain", true, "Who most needs a heal: ESP, Group and healing" },
        { esp, "party_loose", true, "A mob loose on someone not the tank: ESP, Group and healing" },
        { esp, "groupx_tank", true, "Round the tank: ESP, Group extras" },
        { world_page, "cr_execute_curtain", true, "Your target in execute range: here, Combat rings" },
        -- The Reactions page's six (the rotation's pick, the lowest player,
        -- the healers, the vanish and burst curtains, the flag carriers'
        -- beacon) left with their modules on 2026-10-11.
        { esp, "tele_wall", true, "A wall round a telegraph as it lands: ESP, Telegraphs" },
        { esp, "box_style", cfg.BOX_CURTAIN, "Boxes round mobs, when shown: ESP, Box style Curtain (advanced)" },
        P.forever and { esp, "esp_beacons", true, "Beacons over far rares, bosses and quest mobs: ESP, Look (advanced)", 2 }
            or { esp, "show_beacon", true, "Pillars over far rares, bosses and quest targets: ESP, Elements", 2 },
    }
    P.CURTAINS = CURTAINS

    local function curtain_on(c)
        local v = c[1]:get(c[2])
        if c[2] == "box_style" then return tonumber(v) == c[3] end
        return v == true
    end

    local function set_curtains(on)
        for i = 1, #CURTAINS do
            local c = CURTAINS[i]
            if on then
                pcall(c[1].set, c[1], c[2], c[3])
            elseif curtain_on(c) then
                pcall(c[1].set, c[1], c[2], c[2] == "box_style" and cfg.BOX_CORNERS or false)
            end
        end
        if P.opt_invalidate then P.opt_invalidate() end
        ctx.log.info(on and "World marks: every curtain switched on" or "World marks: every curtain switched off")
    end

    local curtains = world_page:section("Curtains", "eye", { column = "full" })
    curtains:label("A curtain stands round its unit, and many at once cover the game, so every one")
    curtains:label("is off by default. Each has its own switch beside the rest of its mark:")
    for i = 1, #CURTAINS do curtains:label("  " .. CURTAINS[i][4]) end
    curtains:button("curtains_all_on", "Switch every curtain on", { on_click = function() set_curtains(true) end })
    curtains:button("curtains_all_off", "Switch every curtain off", { on_click = function() set_curtains(false) end })

    -- CURTAINS OFF, ONCE (1.7.6). They shipped on, and the menu saved each
    -- default as the player's value, so a new default alone changes nothing
    -- for anyone who has played. Each is switched off once, as the critters
    -- were (1.47.1); after that every switch is the player's again. A switch
    -- the menu has not answered for yet is tried again, five times at most
    -- (one this client does not show never answers). The second pass is the
    -- beacons' (2026-10-10), the first having run already for most: it
    -- touches those alone, so a curtain switched back on by hand stays on.
    local function curtains_off_once(name, pass)
        local fixes = ctx.store and ctx.store("migrations") or nil
        local key = name .. ":" .. (P.forever and "Forever ESP" or "ESP")
        if fixes and fixes.data[key] ~= true and ctx.after then
            local tries, moved = 0, 0
            local function switch_off()
                tries = tries + 1
                local waiting = false
                for i = 1, #CURTAINS do
                    local c = CURTAINS[i]
                    if pass == 2 and c[5] ~= 2 then
                        -- not this pass's
                    elseif c[1]:get(c[2]) == nil then
                        waiting = true
                    elseif curtain_on(c) then
                        c[1]:set(c[2], c[2] == "box_style" and cfg.BOX_CORNERS or false)
                        moved = moved + 1
                    end
                end
                if waiting and tries < 5 then
                    ctx.after(2, switch_off)
                    return
                end
                fixes.data[key] = true
                fixes:touch()
                if P.opt_invalidate then P.opt_invalidate() end
                if moved > 0 then
                    ctx.log.fmt("info", "World marks: %d curtains switched off -- off by default now, each with its own switch", moved)
                end
            end
            ctx.after(1, switch_off)
        end
    end
    curtains_off_once("curtains_off_1", 1)
    curtains_off_once("curtains_off_2", 2)

    -- --- combat rings (1.89.0) --------------------------------------------------
    -- Your swing and GCD at your feet; your target's health, time to die and
    -- execute range under it (modules/combatrings.lua).
    local crings = world_page:section("Combat rings", "activity", { column = "full" })
    crings:toggle("combatrings_on", "Your swing, your GCD and your target's end, on the ground", true)
    crings:toggle("cr_swing", "Your swing: a ring at your feet filling to the next auto attack", true)
    crings:toggle("cr_gcd", "Your global cooldown: a thin ring inside it, emptying", true)
    crings:toggle("cr_ttd", "Your target: a ring as full as its health, and its time to die", true)
    crings:toggle("cr_execute", "Execute range: the ring red and a pulse", true)
    crings:toggle("cr_execute_curtain", "Execute range: a red curtain round your target too", false)
    crings:label("Execute, Hammer of Wrath, Kill Shot, Shadow Word: Death under 20%, Drain Soul")
    crings:label("under 25% -- whichever is in your spellbook. The swing ring dims when it is a guess.")

    -- Tracks (1.89.0): missiles in flight, which way mobs face, where they
    -- walk (modules/tracks.lua).
    local tracks_section = world_page:section("Missiles, facing and patrols", "eye", { column = "full" })
    tracks_section:label("A line from each missile in flight at you or your group to where it lands,")
    tracks_section:label("and a ring there filling as it flies. A faint wedge the way each mob not")
    tracks_section:label("yet fighting faces, as long as the range it notices you from; the route")
    tracks_section:label("a walking mob took, with an arrow the way it goes.")
    tracks_section:toggle("tracks_on", "Show missiles, facing and patrols", true)
    tracks_section:toggle("tracks_missiles", "Missiles in flight", true)
    tracks_section:toggle("tracks_facing", "Which way mobs face", true)
    tracks_section:toggle("tracks_patrols", "Patrol routes", true)
    tracks_section:slider("tracks_range", "Look this far", 10, 60, 40, "yd", ADV)

    -- Node memory and the bobber (1.89.0, modules/nodememory.lua).
    local nodemem_section = world_page:section("Node memory", "leaf", { column = "full" })
    nodemem_section:label("A herb, vein or chest that goes while you are near: a ring where it stood,")
    nodemem_section:label("filling back up over the respawn, with its name and the time left.")
    nodemem_section:toggle("nodemem_on", "Remember gathered herbs, veins and chests", true)
    nodemem_section:slider("nodemem_respawn", "Expected respawn", 60, 1800, 300, "s")
    nodemem_section:toggle("nodemem_fishing", "A ring on your bobber, a pulse when a fish bites", true)

    local world_cal = world_page:section("Calibration", "target", { column = "full" })
    world_cal:button("world_calibrate", "Show the test pattern (12 s)", {
        on_click = function() if P.calibration then P.calibration.start() end end,
    })
    world_cal:label("Turn the camera to read the letters, take one screenshot and say:")
    world_cal:label("A where the quarter ring starts (+x, -x, +y, -y) and which way it runs,")
    world_cal:label("B whether the plain ring is a quarter, E whether the shadow lies on the")
    world_cal:label("icon, F whether the bar is half full. C, D and the pulse: do they show?")

    world_page:live_lines(5, function()
        local w = P.worldmarks and P.worldmarks.stats and P.worldmarks.stats()
        if not w then return { "The world layer did not load." } end
        local parts = {}
        for name, count in pairs(w.by) do parts[#parts + 1] = name .. " " .. count end
        table.sort(parts)
        return {
            string.format("This frame: %d drawn, %d dropped, %d of %s spent, %d faded behind walls",
                w.kept, w.dropped, w.weight, (w.budget or 0) > 0 and tostring(w.budget) or "no cap", w.faded),
            #parts > 0 and ("By mark: " .. table.concat(parts, ", ")) or "By mark: nothing drawn",
            "Switches: Combat rings, Missiles, facing and patrols, Node memory (here), Pull safety (Hardcore),",
            "Fight timers, Group and healing, Group extras, Aurora (ESP), Beacons and Route (Quests).",
        }
    end)

    -- --- automation page ----------------------------------------------------

    local safety = automation:section("Safety checks", "shield", { column = "left", visible = advanced })
    safety:label("Interactions are skipped entirely while any checked state holds.")
    safety:toggle("safe_moving", "Never while moving", true)
    safety:toggle("safe_mounted", "Never while mounted", true)
    safety:toggle("safe_casting", "Never while casting or channelling", true)
    safety:toggle("safe_combat", "Never while in combat", true)
    safety:slider("interact_range", "Interact range", 2, 10, 4.5, "yd")
    safety:slider("action_interval", "Minimum gap between actions", 0.1, 2.0, 0.35, "s")
    safety:slider("retry_delay", "Retry delay per target", 0.3, 10.0, 1.0, "s")

    local loot_section = automation:section("Automatic looting", "coins", { column = "right" })
    loot_section:toggle("autoloot_on", "Loot corpses automatically", false)
    loot_section:toggle("autoloot_skin", "Skin skinnable corpses", false)
    loot_section:toggle("autoloot_confirm_bop", "Confirm bind-on-pickup prompts", true, ADV)
    loot_section:toggle("autoloot_force_close", "Close a stuck loot window", true, ADV)
    loot_section:slider("autoloot_window_timeout", "Stuck window timeout", 1.0, 10.0, 3.0, "s", ADV)

    local rest_section = automation:section("Rest", "flask", { column = "full" })
    rest_section:label("Eats and drinks between pulls. Cancelled by moving or combat.")
    rest_section:label("Sits down under what the next pull needs, and stands up once it has it.")
    rest_section:toggle("rest_enabled", "Eat and drink automatically", false)

    local gather = automation:section("Gathering", "leaf", { column = "full" })
    gather:label("Showing a node and gathering it are separate settings.")
    gather:toggle("gather_herbs", "Gather herbs", false)
    gather:toggle("gather_ore", "Mine ore veins", false)
    gather:toggle("gather_containers", "Open chests and containers", false)
    -- Forever declares it on its ESP page (esp/page_forever.lua), found first.
    if not P.forever then
        gather:toggle("gather_skill_only", "Only herbs and veins your skill can gather", true)
        gather:label("Without Herbalism or Mining they are neither shown nor gathered; short")
        gather:label("of what a node asks for, it is shown dimmed: \"(Requires Skill N)\".")
    end
    gather:text_input("objects_include",
        "Extra object names to show (comma separated)", "", ADV)

    -- FOREVER (1.51.0): the vendor and the quest givers, asked for on
    -- Forever and built only there (modules/forever_npc.lua). Every other
    -- client's Automation page is unchanged.
    if P.forever then
        local npc = automation:section("Vendor and quests", "coins", { column = "full" })
        npc:label("Classic Forever only. Hold Shift as a window opens to do it yourself.")
        npc:toggle("npc_sell_junk", "Sell grey items at any vendor", false)
        npc:label("One sale at a time, each checked: if anything but the grey item leaves")
        npc:label("the bags, selling stops and the log names it (buy it back under Buyback).")
        npc:toggle("npc_accept_quests", "Accept quests", false)
        npc:label("Grey (low-level) and repeatable quests are left for you.")
        npc:toggle("npc_turn_in_quests", "Turn in finished quests", false)
        npc:label("A reward choice takes gear your class wears that beats what you have on:")
        npc:label("your armour type, your spec's weapon. Else the one that sells for most.")
    end

    -- --- fishing page -------------------------------------------------------
    --
    -- Its own page rather than a section of Automation: it is a standing-still
    -- activity with its own loop, not something that happens between pulls.

    local fish_main = fishing_page:section("Fishing", "target", { column = "left" })
    fish_main:label("Stand facing water with a pole equipped, then switch this on.")
    fish_main:toggle("fish_enabled", "Fish automatically", false)
    fish_main:slider("fish_reaction", "Reaction to a bite", 0.2, 2.0, 0.6, "s", ADV)
    fish_main:slider("fish_recast_delay", "Pause between casts", 0.3, 5.0, 1.2, "s", ADV)
    fish_main:toggle("fish_stop_full", "Stop when bags are full", true)
    fish_main:toggle("fish_stay_active", "Stay active so you are not marked Away (anti-AFK)", true)
    fish_main:label("Jambix Market's anti-AFK: a short turn each way every 2 min between")
    fish_main:label("casts. A sidestep, then a jump, if the game marks you Away anyway.")
    fish_main:label("Both delays vary by about 30% each time. Moving, mounting or")
    fish_main:label("combat pauses fishing; it picks up again once they clear.")

    local fish_loot = fishing_page:section("Loot", "coins", { column = "right" })
    fish_loot:dropdown("fish_loot_mode", "Take", {
        "Everything",
        "Gold only",
        "Only the item ids below",
        "Everything except the item ids below",
    }, 1)
    fish_loot:text_input("fish_item_ids", "Item ids (comma separated)", "", ADV)
    fish_loot:toggle("fish_close_loot", "Close the loot window afterwards", true, ADV)
    fish_loot:label("Filtering uses item ids, not names, so it works in any language.")

    fishing_page:on_change("fish_enabled", function()
        if P.fishing then P.fishing.on_toggle() end
    end)

    local fish_session = fishing_page:section("Session", "activity", { column = "full" })
    fish_session:button("fish_reset", "Reset session counters", {
        on_click = function()
            if P.fishing then P.fishing.reset_session() end
        end,
    })

    -- --- quests page --------------------------------------------------------

    local questie_section = guides:section("Quest targets", "help", { column = "left" })
    questie_section:label("Marks what your quests want, names the quest on each mark,")
    questie_section:label("and shows the objective's progress next to it.")
    questie_section:toggle("questie_on", "Enable quest ESP", true)
    questie_section:label("Its own switch: shown with the ESP page's Enable ESP off too.")
    questie_section:toggle("quest_show_progress", "Show objective progress (3/8)", true)
    questie_section:label("The quest log supplies the names and the progress and needs no")
    questie_section:label("addon. Questie adds what it cannot: which mobs drop a quest item,")
    questie_section:label("and which npc hands the quest out or takes it back.")

    local quest_lines_section = guides:section("Quest paths", "map", { column = "left" })
    quest_lines_section:toggle("quest_lines", "Draw a path to quest targets", true)
    quest_lines_section:label("One path per quest, in that quest's colour -- the same colour")
    quest_lines_section:label("its name is written in above the mob it leads to.")
    quest_lines_section:toggle("quest_paths_prefer_live", "A live target beats a map marker", true, ADV)
    quest_lines_section:label("While anything the quest wants is actually on screen, the guide's")
    quest_lines_section:label("waypoint path is not drawn. A path that follows the mob is worth")
    quest_lines_section:label("more than one pointing at the spot it is supposed to stand in.")
    quest_lines_section:toggle("quest_lines_all", "One per target instead of one per quest", false, ADV)
    quest_lines_section:slider("quest_max_lines", "At most this many paths", 1, 12, 3, "", ADV)
    quest_lines_section:slider("quest_line_range", "Only for targets within", 20, 200, 120, "yd")
    quest_lines_section:toggle("quest_line_dashed", "Dashed", true, ADV)
    quest_lines_section:toggle("quest_lines_in_dungeons", "Draw paths in dungeons and raids", false, ADV)
    quest_lines_section:label("Off: inside a dungeon or raid no quest, spawn or guide path is")
    quest_lines_section:label("drawn -- in there they run through walls and packs. The marks on")
    quest_lines_section:label("the mobs still say what a quest wants.")

    quest_lines_section:separator("Targets not in range")
    quest_lines_section:toggle("quest_spawn_paths", "Point to the nearest known spawn", true)
    quest_lines_section:label("When nothing a quest wants is in range, its path leads to where")
    quest_lines_section:label("Questie says the nearest target spawns, and the label carries the")
    quest_lines_section:label("distance. A complete quest points at its turn-in npc instead, and")
    quest_lines_section:label("a quest the guide is sending you to pick up points at its giver.")
    quest_lines_section:label("Needs Questie. Uses what is left of the path limit above.")
    quest_lines_section:slider("quest_spawn_range", "Only for spawns within", 100, 5000, 2000, "yd", ADV)
    quest_lines_section:slider("quest_spawn_line_length", "Line length", 20, 150, 60, "yd", ADV)

    -- Beacons (1.87.0): pillars of light on where to go (modules/beacons.lua).
    local beacon_section = guides:section("Beacons", "map", { column = "full" })
    beacon_section:toggle("beacons_on", "Pillars of light on where to go", true)
    beacon_section:toggle("beacon_waypoint", "RestedXP's next waypoint (gold)", true)
    beacon_section:toggle("beacon_quests", "Quest areas: yellow to do, green to turn in (Forever's quest map)", true)
    beacon_section:toggle("beacon_nodes", "Herbs, veins and chests the ESP marks", true)
    beacon_section:slider("beacon_node_range", "Nodes out to", 20, 200, 90, "yd")
    beacon_section:slider("beacon_max_nodes", "Most node beacons", 1, 12, 5, "")
    beacon_section:slider("beacon_height", "Height", 6, 30, 14, "yd", ADV)

    -- Routes (1.89.0): the guide's next stops, the vendor you need, your
    -- corpse (modules/routes.lua).
    local route_section = guides:section("Route and services", "map", { column = "full" })
    route_section:toggle("routes_on", "Route, vendor and corpse pillars", true)
    route_section:slider("routes_steps", "Guide stops after the next one", 0, 3, 2, "")
    route_section:label("Fainter, shorter pillars on the step's other stops, a dashed line")
    route_section:label("from each to the next. RestedXP gives the current step's stops only.")
    route_section:toggle("routes_services", "A vendor when your bags are full or gear worn", true)
    route_section:slider("routes_bag_free", "Bags: free slots at or under", 0, 16, 4, "")
    route_section:slider("routes_durability", "Gear: durability at or under", 5, 60, 25, "%")
    route_section:toggle("routes_corpse", "Your corpse while you are dead", true)

    local rxp_section = guides:section("RestedXP", "list", { column = "right" })
    rxp_section:toggle("rxp_on", "Enable RestedXP ESP", true)
    rxp_section:label("Its own switch: shown with the ESP page's Enable ESP off too.")
    rxp_section:toggle("guide_on", "Mark what the guide wants", true)
    rxp_section:toggle("rxp_panel", "Show guide panel", true)
    rxp_section:label("Drag the panel by its title bar, resize it from its bottom-right")
    rxp_section:label("corner; double-click the title to fold it away. It stays put.")
    rxp_section:toggle("rxp_line", "Draw line to waypoint", true)
    rxp_section:toggle("rxp_all_waypoints", "Draw the other stops in the step too", false, ADV)
    rxp_section:label("Off by default: a step with eight stops is eight dashed lines", ADV)
    rxp_section:label("running off to nowhere. The current one is drawn solid either way.", ADV)
    rxp_section:slider("rxp_max_waypoints", "At most this many extra stops", 1, 8, 3, "", {
        visible = function() return advanced() and opt("rxp_all_waypoints", false) end,
    })
    rxp_section:toggle("rxp_waypoint_label", "Label the waypoint", true, ADV)
    rxp_section:slider("rxp_line_length", "Line length", 20, 150, 60, "yd", ADV)

    -- The RestedXP ESP acts as you walk up (1.8.1, modules/guidewalk.lua):
    -- you move, it does the step's quests and hands its mobs to the
    -- rotation. The user: "let's make RestedExp ESP - Allow Quest Grab,
    -- allow the Combat System to work with it and Turn in quests".
    rxp_section:separator("Do the step as you walk up")
    if esp_only then
        rxp_section:label("Not on " .. client_label .. ": nothing walks or acts for you here.")
    end
    rxp_section:toggle("rxp_act", "Act on the guide's marks as you walk up to them", false)
    rxp_section:label("You move, by the marks and the line; nothing walks you. Stand by the")
    rxp_section:label("step's quest giver and it talks, answering for the step's quests only.")
    rxp_section:label("The step's mobs in range are the rotation's to open on (Rotation page).")
    rxp_section:toggle("rxp_act_accept", "Pick up the step's quests", true)
    rxp_section:toggle("rxp_act_turnin", "Hand in the step's quests", true)
    rxp_section:toggle("rxp_act_fight", "Let the rotation fight what the step wants killed", true)

    -- The guide walk (1.7.4, modules/guidewalk.lua): RestedXP's steps,
    -- walked with Sentinel Navigation and done.
    rxp_section:separator("Follow the guide")
    rxp_section:toggle("rxp_follow", "Follow the guide with Sentinel Navigation", false)
    rxp_section:label("Walks to each step and does it: hands in and picks up its quests,")
    rxp_section:label("pulls what it wants killed, uses its quest objects, loots your kills.")
    rxp_section:label("Needs Sentinel Navigation running. Fights are the rotation's: switch")
    rxp_section:label("it on (Rotation page). Steer (W A S D, Space) and it waits for you.")
    rxp_section:toggle("rxp_follow_talk", "Hand in and pick up the step's quests", true)
    rxp_section:toggle("rxp_follow_fight", "Pull what the step wants killed", true)
    rxp_section:toggle("rxp_follow_use", "Use the step's quest objects", true)
    rxp_section:toggle("rxp_follow_loot", "Walk to your kills and loot them", true)
    rxp_section:slider("rxp_follow_range", "Look for them within", 20, 100, 60, "yd", ADV)
    -- 2026-10-10: the route it walks, on the ground (quests.lua's draw_walk_route).
    rxp_section:toggle("rxp_follow_route", "Draw the route it walks", true)
    rxp_section:label("A solid line along Sentinel's path to what it is walking to, in the")
    rxp_section:label("guide line's place. A stop on another continent is not walked.")

    -- ==========================================================================
    -- COLOURS
    -- ==========================================================================

    local color_lib
    do
        local ok, mod = pcall(require, "common/color")
        if ok then color_lib = mod end
    end

    local function make_color(r, g, b, a)
        if color_lib then
            local ok, c = pcall(color_lib.new, r, g, b, a or 255)
            if ok then return c end
        end
        return { r = r, g = g, b = b, a = a or 255 }
    end
    P.color = make_color

    local enums
    do
        local ok, mod = pcall(require, "common/enums")
        if ok then enums = mod end
    end

    P.enums = enums

    -- Loss-of-control type ids, used to tell a fear from a stun. Nil when the
    -- enums module is unavailable, and every caller treats that as "cannot
    -- tell" rather than guessing at literals.
    P.loc_types = enums and enums.loss_of_control_type or nil

    -- Through cfg.class_id_for, not the enums alone: without the enums
    -- module this table was empty and class colours silently never applied.
    P.class_color = {}
    for name, rgb in pairs(cfg.CLASS_RGB) do
        local id = cfg.class_id_for(enums, name)
        if type(id) == "number" then
            P.class_color[id] = make_color(rgb[1], rgb[2], rgb[3])
        end
    end

    -- Rebuilt only when a picker moves. Allocating a colour per object per
    -- frame is the kind of cost that is invisible with one plugin loaded and
    -- is not with five.
    P.category_color = {}

    local function rebuild_colors()
        -- Fired by on_change in the same frame the picker moved, so the
        -- per-frame memo may still hold the colour it just replaced.
        opt_invalidate()
        for i = 1, #cfg.CATEGORIES do
            local c = cfg.CATEGORIES[i]
            local v = opt(c.key .. "_color", nil)
            if type(v) == "table" and v.r then
                P.category_color[c.key] = make_color(v.r, v.g, v.b, v.a or 255)
            else
                P.category_color[c.key] = make_color(c.rgb[1], c.rgb[2], c.rgb[3])
            end
        end
    end

    rebuild_colors()
    for i = 1, #cfg.CATEGORIES do
        esp:on_change(cfg.CATEGORIES[i].key .. "_color", rebuild_colors)
    end

    --- Alpha falls off over the outer third of a category's range, so distant
    --- marks recede instead of competing with close ones.
    function P.faded(col, distance, range)
        if not opt("dim_by_distance", true) then return col end
        local start = range * 0.66
        if distance <= start then return col end
        local t = 1.0 - ((distance - start) / math.max(1, range - start))
        return make_color(col.r or 255, col.g or 255, col.b or 255,
            math.floor(math.max(0.25, t) * 255))
    end

    -- ==========================================================================
    -- MODULES
    -- ==========================================================================

    P.actions   = load_module("modules/actions")(P)
    P.quests    = load_module("modules/quests")(P)

    -- The overlay is a package of its own: classify, collect, elements,
    -- panels. It loads before world.lua because world.lua's automation reads
    -- the lists the collector publishes.
    P.esp       = load_module("modules/esp/init")(P)
    -- What the overlay used to be called. Kept so the debug page and any
    -- external reader that learned the old name keeps working.
    P.esp_units = P.esp

    P.world     = load_module("modules/world")(P)
    P.fishing   = load_module("modules/fishing")(P)

    -- Rotation stack, in dependency order: the spellbook resolves names to
    -- ids, talents decide the profile, stance needs both, and the rotation
    -- needs all three.
    -- SPELLS_CHANGED, COALESCED. The client fires it in bursts -- on login,
    -- on a talent change, and every time a warlock summons or dismisses a pet
    -- -- and four modules each did a full rescan inside the handler: the
    -- spellbook walks every spell id with several native calls apiece, the
    -- talent scan reads every talent in three trees. A burst of five was five
    -- of each in a single frame, which is a freeze you can feel.
    --
    -- Now the raw event only marks the book dirty, and one re-broadcast goes
    -- out on a later tick, at most twice a second. Every listener still hears
    -- about every change; it just hears once per burst instead of once per
    -- event.
    do
        local dirty, last_fire = false, 0
        local COALESCE = 0.5
        ctx.on("jcore.game_event.SPELLS_CHANGED", function() dirty = true end)
        ctx.tick(function()
            if not dirty then return end
            local now = core.time()
            if (now - last_fire) < COALESCE then return end
            dirty, last_fire = false, now
            ctx.emit("jambix.aio.spells_changed")
        end, { priority = 5 })
    end

    P.spellbook = load_module("modules/spellbook")(P)
    P.talents   = load_module("modules/talents")(P)
    -- What each ability IS. Reads the spellbook and the talents; answers
    -- through the rotation's class detection at call time, so it loads here
    -- and resolves later.
    P.catalog   = load_module("modules/catalog/init")(P)
    P.forms     = load_module("modules/forms")(P)
    P.targeting = load_module("modules/targeting")(P)
    P.hardcore  = load_module("modules/hardcore")(P)
    P.pet       = load_module("modules/pet")(P)
    on_stop[#on_stop + 1] = function() P.pet.release_taunt(true) end
    -- Which beasts a hunter can tame, and what they teach (1.72.0).
    P.tame      = load_module("modules/tame")(P)
    P.rest      = load_module("modules/rest")(P)
    P.resources = load_module("modules/resources")(P)
    P.auto      = load_module("modules/auto")(P)
    P.sense     = load_module("modules/sense")(P)
    P.narrate   = load_module("modules/narrate")(P)
    P.field     = load_module("modules/field")(P)
    P.burst     = load_module("modules/burst")(P)
    P.rotation  = load_module("modules/rotation")(P)
    -- The reaction engine: interrupts, defensives, the pet, threat, escapes
    -- and the hardcore bail-out, decided by score with a memory, ahead of the
    -- priority walk. After the rotation, whose helpers and checks it reuses;
    -- the rotation calls into it at run time.
    P.react     = load_module("modules/react/init")(P)
    -- "Assist the tank" (1.70.0): the tank's target, followed, for a damage
    -- dealer in a group. targeting.better_target and may_engage_unit ask it
    -- at run time; it reads the reaction engine's crowd-control answer.
    P.assist    = load_module("modules/assist")(P)
    -- The shot between the steps: stands for the aim when a ranged auto
    -- attack is due while moving. After the rotation, because it reads the
    -- active class and the cast gate from it.
    P.weave     = load_module("modules/weave")(P)
    -- The hunter's legs: run-and-shoot before there is a pet, and the step
    -- back out of the dead zone once there is one. After the rotation and
    -- the pet, both of which it reads.
    P.kite      = load_module("modules/kite")(P)
    -- The PvP hunter (1.7.6, ALPHA/TEST): PvP mode, our own control on a
    -- player, the walk away from a trapped one. Read at run time by the
    -- hunter's profile and reactions, the pet and the kite.
    P.pvphunter = load_module("modules/pvphunter")(P)
    -- The spell window: what was cast and what the rotation presses next.
    -- After the rotation, whose projection it shows.
    P.timeline  = load_module("modules/timeline")(P)
    -- The hunter's aspects, switched by hand in their own window. After the
    -- spellbook, which says which aspects are trained.
    P.aspects   = load_module("modules/aspects")(P)
    -- Every class's own window (1.62.0): its buffs, stances and forms; the
    -- hunter's holds the aspects above. After the aspects and the spellbook.
    P.classwin  = load_module("modules/classwin")(P, load_module("modules/classwin_data"))
    -- The Reactions window (1.76.0): after the reaction engine, whose
    -- react/custom.lua holds what it shows and edits.
    P.reactwin  = load_module("modules/reactwin")(P)
    -- Telegraphs (1.65.0): paints what JCore's telegraph service works out.
    -- Reads nothing itself; inert on a JCore older than 1.8.0.
    P.telegraphs = load_module("modules/telegraphs")(P)
    -- The world layer every world mark goes through, and the calibration (1.89.0).
    P.worldmarks = load_module("modules/worldlayer")(P)
    P.calibration = load_module("modules/calibration")(P)
    P.aurora = load_module("modules/aurora")(P)
    P.pull = load_module("modules/pull")(P)
    P.timers = load_module("modules/timers")(P)
    P.combatrings = load_module("modules/combatrings")(P)
    P.tracks = load_module("modules/tracks")(P)
    P.party = load_module("modules/party")(P)
    P.groupextras = load_module("modules/groupextras")(P)
    P.beacons = load_module("modules/beacons")(P)
    P.routes = load_module("modules/routes")(P)
    P.nodememory = load_module("modules/nodememory")(P)
    -- FOREVER (1.51.0): the vendor and the quest givers. After the rotation,
    -- whose class and profile choose a quest reward; never loaded on any
    -- other client.
    if P.forever then
        P.forever_npc = load_module("modules/forever_npc")(P)
    end
    -- The guide walk (1.7.4): RestedXP's steps with Sentinel Navigation.
    -- After everything it asks at run time: the quests, the ESP's corpses,
    -- the actions gate, the rotation, targeting, rest, hardcore and Forever's
    -- quest givers (which answer their own windows when switched on).
    P.guidewalk = load_module("modules/guidewalk")(P)
    -- The experience bars (1.7.6): Forever's, switched on its ESP page.
    -- After the quests, whose index they sum.
    if P.forever then
        P.xpbar = load_module("modules/xpbar")(P)
    end

    -- Class rule sets. Every one is loaded, and detection decides which runs;
    -- they are pure data, so the cost of holding them all is trivial next to
    -- the cost of getting the load order wrong when a class is missing.
    for _, class_file in ipairs({
        "warrior", "paladin", "hunter", "rogue", "priest",
        "shaman", "mage", "warlock", "druid",
    }) do
        local ok, factory = pcall(load_module, "modules/classes/" .. class_file)
        if ok and type(factory) == "function" then
            -- Class-specific widget ids are namespaced with the class key.
            -- Two classes want a "slow the runner" toggle and two want a
            -- "spend combo points at" slider; they share a page, and a widget
            -- id has to be unique on it. Namespacing also keeps a warrior's
            -- and a hunter's answer to the same question separate, which is
            -- correct -- settings persist per plugin, not per character.
            local prefix = "rot_" .. class_file .. "_"
            local CS = {
                prefix = prefix,
                opt = function(id, default) return P.opt(prefix .. id, default) end,
                pct = function(id, default) return P.optpct(prefix .. id, default) end,
                -- The tuned pair is what a class file should normally use:
                -- automatic when the plugin can work the number out, and the
                -- slider only as the fallback. See P.tune in this file.
                tune = function(id, default) return P.tune(prefix .. id, default) end,
                tune_secs = function(id, default) return P.tune_secs(prefix .. id, default) end,
            }

            local built_ok, definition = pcall(factory, P, P.rotation.helpers, CS)
            if built_ok and type(definition) == "table" and definition.class_name then
                P.rotation.classes[definition.class_name] = definition

                -- No profile selector (1.33.0): the profile follows the
                -- talents and the group role, see rotation.active_profile_key.
                local class_name = definition.class_name

                -- The class's OWN settings, in its own gated section. Anything
                -- that names a class ability -- Shield Block, Life Tap, Frost
                -- Nova -- belongs here rather than in a shared list, so it is
                -- never shown to a class that cannot do it.
                if definition.settings then
                    local section = class_section(
                        (definition.label or definition.key) .. " options",
                        definition.icon or "swords", class_name)

                    -- Same namespacing on the way in, so a class file writes
                    -- the short id once and never has to repeat its own name.
                    local wrapped = setmetatable({}, {
                        __index = function(_, method)
                            local fn = section[method]
                            if type(fn) ~= "function" then return nil end
                            -- label/separator/spacer take no id.
                            if method == "label" or method == "separator"
                                or method == "spacer" then
                                return function(_, ...) return fn(section, ...) end
                            end
                            return function(_, id, ...)
                                return fn(section, prefix .. id, ...)
                            end
                        end,
                    })

                    local ok_settings, err = pcall(definition.settings, wrapped, P, CS)
                    if not ok_settings then
                        ctx.log.fmt("error", "%s settings failed: %s",
                            class_file, tostring(err))
                    end
                end
            else
                ctx.log.fmt("error", "class module %s failed to build: %s",
                    class_file, tostring(definition))
            end
        else
            ctx.log.fmt("error", "could not load class module %s: %s",
                class_file, tostring(factory))
        end
    end

    -- Hand the active class's form order to the form manager, once the class
    -- is known. Stances only exist for two classes, so this is usually a no-op.
    local function sync_class_forms()
        local class_module = P.rotation.active_class()
        P.forms.set_order(class_module and class_module.forms or nil)
        if class_module then P.talents.set_tree_names(class_module.trees) end
    end

    local function on_class_known()
        sync_class_forms()

        -- A class with no pet should not be running pet logic; a hunter's
        -- default is not a mage's.
        local class_module = P.rotation.active_class()
        if class_module and class_module.default_pet_mode
            and rotation:get("pet_mode") == nil then
            rotation:set("pet_mode", class_module.default_pet_mode)
        end
    end

    ctx.on("jambix.aio.class_detected", on_class_known)
    ctx.every(5.0, on_class_known)
    on_class_known()

    -- THE DEBUG PAGE (1.60.0) is Jambix Debug's (scripts/jambix_debug,
    -- aio/debug.lua): the object inspector, the automation status, narration
    -- and the reaction history, built with this bundle when that plugin is
    -- there, which users do not get. Load order is not guaranteed, so a
    -- plugin that is not up yet is waited for, a while, once a second.
    local function attach_debug()
        if P.debug ~= nil then return true end
        local D = _G.JambixDebug
        if type(D) ~= "table" or type(D.aio_debug) ~= "function" then return false end
        local ok, m = pcall(D.aio_debug, P)
        if ok and type(m) == "table" then
            P.debug = m
        else
            P.debug = false
            ctx.log.fmt("warn", "Jambix Debug: the AIO page failed: %s", tostring(m))
        end
        return true
    end
    if not attach_debug() then
        local give_up_at = core.time() + 30
        local waiting = true
        ctx.every(1.0, function()
            if not waiting then return end
            if attach_debug() or core.time() > give_up_at then waiting = false end
        end)
    end

    -- One line per feature area, so the root page answers "what is actually
    -- running right now" without opening five pages.
    overview:live_lines(15, function()
        local function state(on, detail)
            if not master_on() then return "off (master)" end
            if not on then return "off" end
            return detail or "on"
        end

        local out = {}
        out[#out + 1] = "ESP:        " .. state(
            opt("enabled", true) and toggle_active(),
            string.format("on, %.0fy", opt("max_range", 100)))

        local w = P.rotation.stats()
        out[#out + 1] = "Rotation:   " .. state(
            opt("rot_enabled", false) and rotation_active(),
            string.format("%s (%s)", w.label or w.profile or "-", w.class))
        if P.react then
            out[#out + 1] = "Reactions:  " .. P.react.summary()
        end

        local gathering = opt("gather_herbs", false) or opt("gather_ore", false)
            or opt("gather_containers", false)
        out[#out + 1] = "Automation: " .. state(
            opt("autoloot_on", false) or gathering,
            (opt("autoloot_on", false) and "loot " or "")
            .. (gathering and "gather" or ""))

        if P.forever_npc then
            out[#out + 1] = "Vendor/quests: " .. state(opt("npc_sell_junk", false)
                or opt("npc_accept_quests", false) or opt("npc_turn_in_quests", false),
                P.forever_npc.summary())
        end

        local fs = P.fishing.stats()
        out[#out + 1] = "Fishing:    " .. state(opt("fish_enabled", false),
            fs.stopped and ("stopped, " .. fs.stopped)
            or string.format("%s, %d caught", fs.state, fs.catches))

        local q = P.quests.stats()
        out[#out + 1] = string.format("Quests:    Questie %s, RestedXP %s",
            q.questie_ready and "ready" or "absent",
            q.rxp_loaded and ("step " .. tostring(q.rxp_step)) or "absent")
        out[#out + 1] = "Guide walk: " .. state(opt("rxp_follow", false) or opt("rxp_act", false),
            P.guidewalk.status())

        local t = P.targeting.stats()
        out[#out + 1] = string.format("Context:    %s, %d engaged, %d loose%s",
            t.context, t.engaged, t.loose,
            t.may_pull and "" or "  (aggro control off here)")

        local hc = P.hardcore.stats()
        out[#out + 1] = "Hardcore:   " .. (opt("hc_enabled", true)
            and string.format("on  %s", hc.items) or "off")

        local r = P.rest.stats()
        out[#out + 1] = string.format("Rest:       %s%s",
            opt("rest_enabled", false) and "on" or "off",
            r.food and ("   food: " .. r.food) or "   (no food found)")

        local sn = P.sense.stats()
        out[#out + 1] = string.format("Sense:      %s%s%s",
            sn.pvp and "PvP nearby" or "no hostile players",
            sn.visible_stealthed > 0
                and string.format("   %d stealthed visible", sn.visible_stealthed) or "",
            sn.suspected and ("   SUSPECT: " .. tostring(sn.suspect_name)) or "")

        local blocked = P.actions.blocked_reason()
        out[#out + 1] = "Interact:   " .. (blocked and ("blocked, " .. blocked) or "allowed")

        return out
    end)

    -- Live rotation readout, declared after warrior so it can name the
    -- abilities the profiles reference.
    rotation:live_lines(34, function()
        local out = {}
        local w = P.rotation.stats()

        out[#out + 1] = string.format("Class: %s%s",
            w.class, w.supported and "" or "   -- NO ROTATION FOR THIS CLASS")

        local t = P.talents.stats()
        out[#out + 1] = string.format("Talents %s %d  /  %s %d  /  %s %d   -> %s%s",
            t.tree1, t.arms, t.tree2, t.fury, t.tree3, t.prot, t.spec,
            t.ok and "" or "  (not readable yet)")

        out[#out + 1] = string.format("Profile: %s%s",
            w.label or w.profile or "-",
            w.form and ("   form: " .. w.form) or "")
        out[#out + 1] = string.format("Last cast: %s%s",
            w.last_gcd or "-",
            w.last_fast and ("   off-GCD: " .. w.last_fast) or "")
        out[#out + 1] = string.format("Gates: cast-detect %s%s   wand-detect %s",
            w.cast_gate and "trusted" or "DISTRUSTED (ignored)",
            w.casting and "   [casting now]" or "",
            w.wand_detect and "working" or "unconfirmed")

        local b = P.burst.stats()
        if b.open then
            out[#out + 1] = string.format("Burst: OPEN %.0fs -- %s%s",
                b.remaining, b.reason,
                #b.fired > 0 and ("   fired: " .. table.concat(b.fired, ", ")) or "")
        else
            out[#out + 1] = "Burst: holding -- " .. (b.reason ~= "" and b.reason or "no reason yet")
        end

        local resting, resting_why = P.rest.recovering()
        if resting then
            out[#out + 1] = "Recovering: " .. resting_why .. " (holding the pull)"
        end

        -- What the plugin thinks is happening, and the race it is measuring.
        -- This is the line that explains a rotation which has stopped
        -- attacking: SURVIVE and FLEE are decisions, not failures.
        local f = P.field.stats()
        out[#out + 1] = string.format("Field: %s -- %s", f.plan, f.reason)
        out[#out + 1] = string.format(
            "  %s   %d engaged%s%s%s%s   clear in %s vs %s to live",
            f.shape, f.count,
            f.inbound > 0 and string.format(", %d closing", f.inbound) or "",
            f.elites > 0 and string.format(", %d elite", f.elites) or "",
            f.casters > 0 and string.format(", %d casting", f.casters) or "",
            f.runners > 0 and string.format(", %d running", f.runners) or "",
            f.clear, f.live)

        -- What it SEES: the core's picture of every hostile, folded into the
        -- rotation's snapshot. A rotation that is waiting can say what for.
        local see = w.sees
        if see then
            out[#out + 1] = string.format(
                "Sees: %d hostile(s) -- %d on me, %d attacking, %d closing, %d casting%s",
                see.enemies, see.on_me, see.attacking, see.inbound, see.casting,
                (see.arriving and see.arrives_in < math.huge)
                    and string.format("   next arrival: %s in %.1fs", see.arriving, see.arrives_in) or "")
            local tg = see.target
            if tg then
                local motion = ""
                if tg.closing > 1 then
                    motion = string.format("  closing %.1fy/s%s", tg.closing,
                        tg.arrives < math.huge and string.format(" (here in %.1fs)", tg.arrives) or "")
                elseif tg.closing < -1 then
                    motion = string.format("  fleeing %.1fy/s", -tg.closing)
                end
                out[#out + 1] = string.format("  Target: %s  %.0fy  %s  %.0f%% hp%s%s%s",
                    tg.name, tg.dist, tg.activity, tg.hp * 100, motion,
                    tg.casting and string.format("  CASTING %s%.1fs left",
                        tg.interruptible and "(interruptible) " or "", tg.remaining) or "",
                    tg.controlled and "  controlled" or "")
            else
                out[#out + 1] = "  Target: none" .. (see.moving and "   (moving)" or "")
            end
            if see.caster then
                out[#out + 1] = string.format("  Interruptible cast: %s, %.1fs left",
                    see.caster, see.caster_remaining)
            end
            out[#out + 1] = "  Can: " .. see.can
        end

        out[#out + 1] = "Crowd control: " .. (P.key_armed("rot_fear_key")
            and "ARMED -- fear may fire" or "held (press the key to allow it)")

        out[#out + 1] = "Spreading: " .. (P.spread_allowed()
            and "on -- dots go on everything fighting you"
            or "OFF -- dots stay on the target only")

        -- Damage-over-time coverage, and whether it is actually landing. A
        -- resist or an immunity shows up here rather than as a rotation that
        -- looks busy and does nothing.
        local misses = P.rotation.landing_report()
        if #misses > 0 then
            local parts = {}
            for i = 1, math.min(#misses, 3) do
                parts[#parts + 1] = string.format("%s %d/%d missed",
                    misses[i].name, misses[i].missed,
                    misses[i].missed + misses[i].applied)
            end
            out[#out + 1] = "Not landing: " .. table.concat(parts, "   ")
        end

        -- Resource posture and the numbers the plugin chose for itself. This
        -- is the answer to "why did it not cast anything": a rotation holding
        -- back to recover looks identical to a broken one until it says so.
        local r = P.resources.stats()
        out[#out + 1] = string.format(
            "Resources: %s   health %.0f%% (%+.1f%%/s, empty in %s)%s",
            r.posture, r.hp * 100, r.hp_rate * 100, r.hp_empty,
            r.has_power and string.format(
                "   mana %.0f%% (%+.1f%%/s, empty in %s)",
                r.power * 100, r.power_rate * 100, r.power_empty) or "")

        local a = P.auto.stats()
        if not opt("auto_tune", true) then
            out[#out + 1] = "Tuning: manual -- the sliders on this page are being used as written."
        else
            out[#out + 1] = string.format(
                "Tuning: automatic   filler %s%s%s   incoming %.0f%%/s   regen %.0f/s",
                a.filler or "(none resolved)",
                a.filler_cost and string.format(" costs %.0f%% mana", a.filler_cost * 100) or "",
                a.filler_cast and string.format(", %.1fs cast", a.filler_cast) or "",
                (a.incoming or 0) * 100, a.regen or 0)

            -- What it actually decided, so a surprising choice is visible
            -- rather than buried. Only the thresholds that have been asked for
            -- appear, which keeps this to the ones in play.
            local chosen, names = a.chosen or {}, {}
            for id in pairs(chosen) do names[#names + 1] = id end
            table.sort(names)

            local shown = {}
            for i = 1, #names do
                local id = names[i]
                shown[#shown + 1] = string.format("%s %.0f%%",
                    (id:gsub("^res_", ""):gsub("^rot_%a+_", "")), chosen[id] * 100)
            end
            if #shown > 0 then
                out[#out + 1] = "Chose: " .. table.concat(shown, "   ")
            end
        end

        local pet = P.pet.stats()
        out[#out + 1] = string.format("Pet: %s%s", pet.mode,
            pet.alive and string.format("   %.0f%% hp   on %s (%s)",
                pet.health * 100, pet.on or "-", pet.reason or "-")
            or "   (no pet)")

        local sb = P.spellbook.stats()
        out[#out + 1] = string.format("Spellbook: %d ability name(s) resolved", sb.names)

        local stuck = P.rotation.stuck_abilities()
        if #stuck > 0 then
            out[#out + 1] = "BACKED OFF (castable but never fired): " .. table.concat(stuck, ", ")
        end

        local missing = P.spellbook.missing(P.rotation.all_ability_names())
        if #missing == 0 then
            out[#out + 1] = "All profile abilities resolved."
        else
            out[#out + 1] = string.format("Not trained or not resolved (%d):", #missing)
            -- Wrapped by hand: these are fixed-height rows, not a text box.
            local line, rows = "", 0
            for i = 1, #missing do
                local next_line = (line == "") and missing[i] or (line .. ", " .. missing[i])
                if #next_line > 58 then
                    out[#out + 1] = "  " .. line
                    rows = rows + 1
                    line = missing[i]
                    if rows >= 5 then break end
                else
                    line = next_line
                end
            end
            if line ~= "" and rows < 6 then out[#out + 1] = "  " .. line end
        end

        return out
    end)

    -- The reaction readout is the Reactions page's (1.8.0).

    -- There is no periodic wholesale invalidation of the unit classification
    -- any more. There used to be one every two seconds, from when guide
    -- membership was folded into the cached answer; it is asked per frame
    -- now, and the timer had become a pure cost -- every unit in range
    -- re-read with eleven native calls apiece, all in the same frame, every
    -- two seconds. The things that CAN go stale (reaction, level) are
    -- refreshed one unit at a time inside the classifier instead.

    -- Live status rows. Declared at a fixed height because menu content is
    -- retained mode. (The Debug page's are Jambix Debug's, 1.60.0.)
    fishing_page:live_lines(4, function() return P.fishing.status_lines() end)
    -- The guide walk (1.7.4): what it is doing, Sentinel, and the counts.
    guides:live_lines(3, function() return P.guidewalk.status_lines() end)

    -- ==========================================================================
    -- RANGE
    -- ==========================================================================

    local last_requested_range = -1

    --- The furthest any enabled category actually reaches. Each is capped by
    --- the master range first, so this is never larger than the master and is
    --- usually smaller -- requesting the master outright would make the core
    --- sweep 200 yards to draw herbs at 40.
    local function sync_range()
        local master = opt("max_range", 150)
        local auto = opt("auto_ranges", true)
        local wanted = 0
        for i = 1, #cfg.CATEGORIES do
            local c = cfg.CATEGORIES[i]
            if opt(c.key .. "_on", c.on) then
                local effective = auto and master
                    or math.min(opt(c.key .. "_range", c.range), master)
                if effective > wanted then wanted = effective end
            end
        end
        -- The bobber lands up to ~20 yards out and has to be in the sweep to
        -- be found, even with every overlay category switched off.
        if opt("fish_enabled", false) and wanted < 40 then wanted = 40 end
        if wanted ~= last_requested_range then
            last_requested_range = wanted
            ctx.request_unit_range(wanted)
        end
    end

    ctx.every(1.0, sync_range)
    sync_range()

    -- ==========================================================================
    -- RENDER PIPELINE
    --
    -- Four render jobs in priority order, all in the same frame:
    --
    --   100  overlay        -- one walk of units and objects, then every mark;
    --                          fills the threat, corpse and node lists
    --   120  telegraphs     -- the ground enemy spells are about to hit
    --   150  alerts         -- reads threats (throttled to 5 Hz)
    --   180  automation     -- reads corpses and nodes (in world.lua)
    --   200  HUD            -- threat panel, off-screen arrows, guide panel
    --   205  spell window   -- used / casting / next (in timeline.lua)
    --   206  aspects        -- the hunter's aspect switches (in aspects.lua)
    --   210  inspector      -- debug overlay (in debug.lua)
    --
    -- Co-locating them in one phase is what keeps the game_object handles the
    -- later jobs act on valid: they were collected this frame, not last.
    --
    -- Units and objects used to be two jobs with two walks. They are one now,
    -- which is also what makes a single distance-sorted list possible -- and
    -- that ordering is what the detail budget and the draw budget both spend
    -- against.
    -- ==========================================================================

    -- THE QUESTS PAGE IS ITS OWN (1.73.0). The user: "quests ESP and Forever
    -- ESP have them be separate so if i dont want ESP but I want RestedXP I
    -- can have that". "Enable ESP" switches off the ESP page's marks only:
    -- the quest marks, the quest paths and the guide keep the Quests page's
    -- own switches. The toggle key still hides everything.
    local function quests_shown()
        return opt("questie_on", true) == true
            or (opt("rxp_on", true) == true and opt("guide_on", true) == true)
    end

    ctx.render(function()
        local shown = toggle_active()
        local visuals = shown and opt("enabled", true) == true
        local master = opt("max_range", 100)
        P.esp.render(visuals, master, shown and quests_shown())
    end, { priority = 100 })

    -- The calibration pattern (1.89.0), straight through JCore's draw, and the
    -- end of the world layer's frame: its marks go to JCore's draw after every
    -- AIO render job that keeps one (all below 190).
    ctx.render(function()
        if P.calibration then P.calibration.render() end
    end, { priority = 189 })
    ctx.render(function()
        if P.worldmarks then P.worldmarks.flush() end
    end, { priority = 190 })

    -- The aurora around you (1.86.0): the master switch and the toggle key,
    -- like every mark, but not the ESP's own switch.
    ctx.render(function()
        if not master_on() or not toggle_active() then return end
        if P.aurora then P.aurora.render() end
    end, { priority = 110 })

    -- Pull safety and the fight timers (1.87.0): the master switch and the
    -- toggle key.
    ctx.render(function()
        if not master_on() or not toggle_active() then return end
        if P.pull then P.pull.render() end
        if P.timers then P.timers.render() end
        if P.combatrings then P.combatrings.render() end
        if P.tracks then P.tracks.render() end
        if P.party then P.party.render() end
        if P.groupextras then P.groupextras.render() end
    end, { priority = 111 })

    -- Beacons (1.87.0): after the ESP's job (100), whose node lists they read.
    ctx.render(function()
        if not master_on() or not toggle_active() then return end
        if P.beacons then P.beacons.render() end
        if P.routes then P.routes.render() end
    end, { priority = 113 })

    -- Node memory and the bobber (1.89.0): after the ESP's job (100), whose
    -- node lists it reads.
    ctx.render(function()
        if not master_on() or not toggle_active() then return end
        if P.nodememory then P.nodememory.render() end
    end, { priority = 114 })

    -- Telegraphs: the overlay's switch and toggle key, and not in "RestedXP
    -- guide only", like every other mark.
    ctx.render(function()
        if not opt("enabled", true) or not toggle_active() or opt("rxp_only", false) then return end
        P.telegraphs.render()
    end, { priority = 120 })

    -- Not deferrable: a proximity warning on a hardcore character is the last
    -- thing that should be dropped on a heavy frame.
    ctx.render(function()
        if not master_on() then return end
        P.esp.alert_check()
    end, { interval = 0.2, priority = 150 })

    -- The threat panel and arrows are the ESP's; the guide panel, its
    -- waypoint line and the quest paths are the Quests page's (1.73.0).
    ctx.render(function()
        if not toggle_active() then return end
        if opt("enabled", true) and not opt("rxp_only", false) then
            P.esp.draw_threat_panel()
            P.esp.draw_threat_arrows()
        end
        P.quests.render_hud()
    end, { priority = 200 })

    -- Its own job, not the HUD's: the ESP toggle hides the overlay, and the
    -- spell window belongs to the rotation, not to the overlay.
    ctx.render(function()
        P.timeline.render()
    end, { priority = 205 })

    -- Your reactions' alerts (1.79.0): their own job, whatever the overlay's
    -- switches say. An alert you set up is not decoration.
    ctx.render(function()
        local custom = P.react and P.react.custom
        if custom and custom.render_alerts then custom.render_alerts() end
    end, { priority = 207 })

    -- The class window (the hunter's holds the aspect switches): the
    -- rotation's page, not the overlay's toggle.
    ctx.render(function()
        P.classwin.render()
    end, { priority = 206 })

    -- The Reactions window: shut, and since 2026-10-11 nothing a player can
    -- reach opens it (P.reactwin.open is kept for the future).
    ctx.render(function()
        P.reactwin.render()
    end, { priority = 207 })

    -- The experience bars (1.7.6): drawn by the ESP, so under its switch and
    -- toggle key and not in "RestedXP guide only", like every mark. Your
    -- experience is read on the bars' own timer, so the rate keeps counting.
    if P.xpbar then
        ctx.render(function()
            P.xpbar.render(opt("enabled", true) and toggle_active() and not opt("rxp_only", false))
        end, { priority = 208 })
    end

    ctx.log.info("ESP ready")
end

-- =============================================================================
-- Poll until JCore publishes itself, then hand off. Package load order is not
-- guaranteed and header.lua gives no way to influence it. And not before a
-- character is in the world (1.8.1): loaded at the character select screen,
-- start() would read spell names from tables the game has not loaded yet,
-- which kills the client (ASSERT(IsLoaded()), 2026-10-12).
-- =============================================================================

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
            core.log_error("[Jambix AIO] JCore never loaded; ESP inactive")
        end
    end)
end

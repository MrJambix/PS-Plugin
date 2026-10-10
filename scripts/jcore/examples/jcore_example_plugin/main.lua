-- A worked consumer. Copy the bootstrap block verbatim into a real plugin;
-- everything below it is illustration.
--
-- What this demonstrates, in order:
--   * the load-order-proof bootstrap
--   * a version guard
--   * registration and the context handle
--   * a declarative menu slice
--   * subscribing to core events
--   * a tick that requests casts through arbitration
--   * a render job that submits into the shared draw layer
--   * an overlay HUD window built from the shared UI toolkit

---@diagnostic disable: lowercase-global

-- =============================================================================
-- BOOTSTRAP -- copy this block into any plugin that consumes JCore.
--
-- Why it is not just `local JCore = _G.JCore`: package load order is not
-- guaranteed and header.lua gives no way to influence it, so the core may not
-- have published itself yet when this file runs. Poll briefly instead and
-- start when it appears. That costs one callback for a few seconds on a cold
-- start and nothing afterwards.
-- =============================================================================

local MINIMUM_CORE = "1.0.0"

local function start(JCore)
    if not JCore.require_version(MINIMUM_CORE) then
        core.log_error(("[JCore Example] needs JCore %s or newer, found %s")
            :format(MINIMUM_CORE, JCore.version))
        return
    end

    -- ==========================================================================
    -- REGISTRATION
    -- ==========================================================================

    local ctx
    ctx = JCore.register({
        id      = "jambix.example",       -- stable forever; it tags everything
        name    = "JCore Example",
        version = "1.0.0",
        kind    = "plugin",

        -- requires = { "jambix.some_other_plugin" },
        -- With this set, on_load is held until that id is running. Leave it out
        -- when the dependency is optional and use ctx.depends_on_running().

        on_load = function(self)
            self.log.info("loaded")
        end,

        on_unload = function(self)
            -- Only for state the core does not own. Events, jobs, timers and
            -- draw submissions are all torn down automatically.
            self.log.info("unloaded")
        end,
    })

    -- ==========================================================================
    -- MENU
    --
    -- ids are the persistence key. Renaming one orphans the saved value and
    -- silently resets the widget to its default, so treat them as permanent.
    -- ==========================================================================

    local menu = ctx.menu({ icon = "widgets" })
    local settings = menu:section("General", "settings")
    settings:toggle("enabled", "Enable", true)
    settings:slider("range", "Engage range", 5, 40, 30, "yd")
    settings:toggle("draw_enemies", "Highlight enemies", true)
    settings:keybind("burst", "Burst window", 0x54, { mode = "hold" })

    -- ==========================================================================
    -- EVENTS
    -- ==========================================================================

    ctx.on("jcore.combat.enter", function()
        ctx.log.info("pull started")
    end)

    ctx.on("jcore.combat.leave", function(duration)
        ctx.log.fmt("info", "fight lasted %.1fs", duration)
    end)

    ctx.on("jcore.target.changed", function(target)
        if target then
            ctx.log.fmt("debug", "target: %s", target:get_name())
        end
    end)

    -- Another plugin's event. Namespacing yours the same way lets others hook
    -- your plugin without either of you importing the other.
    ctx.on("jambix.example.burst_started", function(reason)
        ctx.log.fmt("debug", "burst: %s", reason)
    end)

    -- ==========================================================================
    -- TICK -- decisions only. Never paint from here.
    -- ==========================================================================

    ctx.tick(function()
        if not menu:get_or("enabled", true) then return end

        local player = ctx.units.player()
        if not player or player:is_dead() then return end
        if not ctx.combat.in_combat() then return end

        local target = ctx.combat.target()
        if not target then return end

        local range = menu:get_or("range", 30)
        if ctx.units.distance(target) > range then return end

        -- A cast REQUEST, not a cast. Highest priority across every plugin
        -- wins the tick; losing is normal and needs no handling.
        local HEROIC_STRIKE = 78
        if ctx.spells.ready(HEROIC_STRIKE) and ctx.spells.castable(HEROIC_STRIKE, target) then
            ctx.cast({
                spell_id = HEROIC_STRIKE,
                target   = target,
                priority = ctx.PRIORITY.ROTATION,
                reason   = "filler",
            })
        end

        -- Emergency band outranks everything, including another plugin holding
        -- the cast gate shut. Reserve it for exactly this kind of check.
        if ctx.units.health_fraction(player) < 0.25 then
            local LAST_STAND = 12975
            if ctx.spells.ready(LAST_STAND) then
                ctx.cast({
                    spell_id = LAST_STAND,
                    target   = player,
                    priority = ctx.PRIORITY.EMERGENCY,
                    reason   = "health below 25%",
                    fast     = true,   -- off-GCD: its own lane, no competition
                })
            end
        end
    end, { priority = 100 })

    -- A heavier check that does not need to run at frame rate. `interval`
    -- throttles it; `deferrable` lets the core drop it on an overloaded frame.
    ctx.tick(function()
        local count = ctx.units.count_enemies_within(8)
        if count >= 3 then
            ctx.emit("jambix.example.aoe_opportunity", count)
        end
    end, { interval = 0.25, deferrable = true })

    -- ==========================================================================
    -- RENDER -- submit primitives, do not paint. The core paints in layer
    -- order once every plugin has submitted, which is what keeps an ESP box
    -- from landing on top of someone else's HUD panel.
    -- ==========================================================================

    ctx.render(function()
        if not menu:get_or("draw_enemies", true) then return end

        local enemies = ctx.units.enemies_within(40)
        for i = 1, #enemies do
            local enemy = enemies[i]

            ctx.draw.unit_bar(enemy, ctx.units.health_fraction(enemy),
                ctx.draw.theme.enemy, { offset = 24, width = 56 })

            local ttd = ctx.combat.time_to_die(enemy)
            if ttd < 30 then
                ctx.draw.unit_label(enemy, string.format("%.0fs", ttd),
                    ctx.draw.theme.text_dim, { offset = 36, size = 12 })
            end
        end

        local target = ctx.combat.target()
        if target then
            ctx.draw.circle_3d(target:get_position(), 2.0, ctx.draw.theme.accent,
                { layer = ctx.LAYER.OVERLAY, thickness = 2 })
        end
    end)

    -- ==========================================================================
    -- OVERLAY WINDOW -- the same widget set every plugin shares, on a window
    -- that drags, collapses, remembers its place and stacks correctly with
    -- every other plugin's windows. The toolkit calls the body each frame
    -- the window is visible; widgets return their values.
    -- ==========================================================================

    local hud = ctx.ui:window("hud", {
        title = "Example HUD", anchor = "top-right", x = 20, y = 240, w = 240,
        collapsible = true, closable = true,
    }, function(ui)
        ui:player_frame({ level = true })

        local target = ctx.combat.target()
        if target then
            ui:unit_frame(target, { level = true })
            ui:key_value("time to die", string.format("%.0fs", ctx.combat.time_to_die(target)))
        else
            ui:text("no target", { color = "text_dim", size = "small", align = "center" })
        end

        -- Settings mirrored from the menu page: one value, two places to edit it.
        ui:menu_toggle(menu, "enabled", "Enabled")
        ui:menu_slider(menu, "range", "Engage range", 5, 40)
        ui:menu_keybind(menu, "burst", "Burst window")

        -- Spell art comes from the asset registry: Wowhead for game icons,
        -- the addon folder for addon art, scripts_data for your own.
        ui:spell_row({ 78, 12975, 100 }, 28, { highlight = 78 })

        ui:row(2)
        if ui:button("pull", "Pull", { style = "primary" }) then
            ctx.emit("jambix.example.burst_started", "hud button")
        end
        if ui:button("panic", "Panic", { style = "danger", tooltip = "Cast Last Stand now" }) then
            ctx.cast_spell(12975, ctx.units.player(), ctx.PRIORITY.EMERGENCY, "hud panic")
        end
        ui:end_row()
    end)

    -- Any keybind on the settings page can toggle a window.
    settings:keybind("hud_key", "Toggle HUD", 0, { mode = "toggle", modes = { "toggle", "hold" } })
    local hud_key_was = false
    ctx.tick(function()
        local active = menu:is_keybind_active("hud_key")
        if active and not hud_key_was then hud.toggle() end
        hud_key_was = active
    end, { interval = 0.05 })
end

-- Poll until the core publishes itself, then hand off. The callback removes
-- itself by going inert; a scheduler job would be neater but the whole point of
-- this block is that it cannot assume the core exists yet.
if _G.JCore then
    start(_G.JCore)
else
    local deadline = core.time() + 15.0
    local started = false
    core.register_on_update_callback(function()
        if started then return end
        if _G.JCore then
            started = true
            start(_G.JCore)
        elseif core.time() > deadline then
            started = true
            core.log_error("[JCore Example] JCore never loaded; plugin inactive")
        end
    end)
end

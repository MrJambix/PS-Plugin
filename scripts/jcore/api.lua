-- JCore / api -- the handle a plugin actually holds.
--
-- Depends on: everything. This module is the seam between the runtime and the
-- plugins, and the only surface a consumer is expected to learn.
--
-- The whole point of the handle is the owner tag. Every hook a plugin creates
-- through its context carries the plugin's id, which is what lets the registry
-- pause it, unload it, and bill it for frame time. A plugin that reaches past
-- the handle to the raw services still works, but it opts out of all three --
-- so the handle is deliberately complete enough that reaching past it is never
-- necessary.
--
-- Method style: the context uses DOT calls (ctx.tick(...)), not colon calls.
-- The shipped common/ modules use colon calls, which is a long-standing source
-- of confusion; the handle closes over its own record instead of needing self,
-- so ctx.tick and ctx:tick both work and neither can be wrong.

return function(rt)
    local util = rt.util
    local events = rt.events
    local scheduler = rt.scheduler
    local menu_ns = rt.menu_ns
    local cast = rt.cast

    local M = {}

    --- Builds the context handed back from JCore.register.
    ---@param record table The registry record for this plugin.
    ---@return table ctx
    function M.build_context(record)
        local id = record.id
        local manifest = record.manifest
        local name = manifest.name or id

        local ctx = {
            id      = id,
            name    = name,
            version = manifest.version or "0.0.0",
            kind    = manifest.kind or "plugin",

            -- Shared services, by reference. Read-only from a plugin's side.
            units   = rt.units,
            spells  = rt.spells,
            combat  = rt.combat,
            enemies = rt.enemies,
            threat  = rt.threat,
            draw    = rt.draw,

            -- The rest of the platform, same rules. These are stateless reads
            -- and shared caches, so handing them over by reference is correct;
            -- the two services that DO need to know who is calling (input and
            -- nav) are wrapped below instead.
            player    = rt.player,
            world     = rt.world,
            group     = rt.group,
            inventory = rt.inventory,
            geometry  = rt.geometry,
            missiles  = rt.missiles,
            addons    = rt.addons,
            net       = rt.net,
            bridge    = rt.bridge,
            assets    = rt.assets,
            casc      = rt.casc,
            image     = rt.image,
            creatures = rt.creatures,
            names     = rt.names,
            loot      = rt.loot,
            power     = rt.power,
            dump      = rt.dump,
            questdb   = rt.questdb,
            gamelua   = rt.gamelua,
            telegraphs = rt.telegraphs,

            -- Convenience re-exports so a consumer needs one require, not five.
            util    = util,
            json    = rt.json,
            enums   = rt.player.enums,
            PRIORITY = cast.PRIORITY,
            LAYER    = rt.draw.LAYER,
            CHANNEL  = rt.input.CHANNEL,
            POWER    = rt.player.POWER,
            ROLE     = rt.group.ROLE,
        }

        ctx.log = rt.log.for_tag(name)

        -- --- events ---------------------------------------------------------

        ---@param event string
        ---@param fn function
        ---@param opts? { priority?: number, once?: boolean }
        function ctx.on(event, fn, opts)
            opts = opts and util.shallow_copy(opts) or {}
            opts.owner = id
            return events.on(event, fn, opts)
        end

        ---@param event string
        ---@param fn function
        ---@param opts? { priority?: number }
        function ctx.once(event, fn, opts)
            opts = opts and util.shallow_copy(opts) or {}
            opts.owner = id
            return events.once(event, fn, opts)
        end

        ctx.off = events.off

        --- Fires an event other plugins can subscribe to. Namespace it with
        --- your own id, the way the core namespaces its own with "jcore.".
        ---@param event string
        function ctx.emit(event, ...)
            return events.emit(event, ...)
        end

        -- --- scheduling -----------------------------------------------------

        local function job(phase)
            return function(fn, opts)
                opts = opts and util.shallow_copy(opts) or {}
                opts.owner = id
                return scheduler.add(phase, fn, opts)
            end
        end

        --- Runs every update. This is where rotation and decision logic goes.
        ---@param fn function
        ---@param opts? { priority?: number, interval?: number, deferrable?: boolean }
        ctx.tick = job("update")

        --- Runs before the update phase, before the unit sweep is consumed by
        --- anyone. Use it only for work that must observe raw pre-tick state.
        ctx.pre_tick = job("pre_tick")

        --- Runs during rendering. Submit draw primitives here, do not paint
        --- directly -- see services/draw.lua for why.
        ctx.render = job("render")

        --- Runs during menu rendering, for immediate-mode menu content. Plugins
        --- on the declarative menu do not need this.
        ctx.render_menu = job("menu")

        ctx.render_control_panel = job("control_panel")

        ctx.remove_job = scheduler.remove

        ---@param delay number seconds
        ---@param fn function
        ---@return integer timer_id
        function ctx.after(delay, fn)
            return scheduler.after(delay, fn, id)
        end

        ---@param interval number seconds
        ---@param fn function
        ---@return integer timer_id
        function ctx.every(interval, fn)
            return scheduler.every(interval, fn, id)
        end

        ctx.cancel = scheduler.cancel

        --- Asks the shared unit cache to reach at least `range` yards while
        --- this plugin is loaded. Additive across plugins and released
        --- automatically on unregister, so it raises the range without
        --- overwriting the user's Core setting or fighting another plugin.
        ---@param range number yards
        function ctx.request_unit_range(range)
            rt.units.request_range(id, range)
        end

        -- --- casting --------------------------------------------------------

        --- Ask to cast this tick. The owner tag is filled in for you, which is
        --- what makes the arbitration log readable when two plugins compete.
        ---@param request jcore_cast_request
        ---@return boolean accepted
        function ctx.cast(request)
            request.owner = id
            return cast.request(request)
        end

        --- Sugar for the overwhelmingly common case.
        ---@param spell_id integer
        ---@param target? game_object
        ---@param priority? number
        ---@param reason? string
        function ctx.cast_spell(spell_id, target, priority, reason)
            return cast.request({
                spell_id = spell_id,
                target = target,
                priority = priority or cast.PRIORITY.ROTATION,
                reason = reason,
                owner = id,
            })
        end

        --- Sugar for using an item on the global cooldown.
        ---
        --- Goes through the SAME arbiter as a spell, which is the point: a
        --- potion and a defensive spell compete for one global cooldown, and a
        --- plugin that uses core.input.use_item directly wins that contest by
        --- ignoring it.
        ---@param item_id integer
        ---@param target? game_object
        ---@param priority? number
        ---@param reason? string
        function ctx.use_item(item_id, target, priority, reason)
            return cast.request({
                item_id = item_id,
                target = target,
                priority = priority or cast.PRIORITY.UTILITY,
                reason = reason,
                owner = id,
            })
        end

        --- Holds the cast gate for `duration` seconds. EMERGENCY-band requests
        --- still get through; see services/cast.lua.
        ---@param duration number seconds
        ---@param reason? string
        function ctx.suppress_casting(duration, reason)
            cast.suppress(id, duration, reason)
        end

        function ctx.release_casting()
            cast.release(id)
        end

        -- --- control --------------------------------------------------------
        --
        -- Movement, facing and targeting are leased rather than shared, so
        -- every call has to say who is asking. Rather than make each plugin
        -- pass its own id back to the core -- which it would eventually get
        -- wrong, and which would let it pass someone else's -- the handle
        -- closes over it, exactly as it does for casting.

        local input = rt.input

        ctx.input = {
            CHANNEL  = input.CHANNEL,
            PRIORITY = input.PRIORITY,

            --- Takes or renews a control channel. Call it every tick you want
            --- the channel; it lapses on its own when you stop.
            ---@param channel string
            ---@param priority? number
            ---@param reason? string
            ---@return boolean granted
            acquire = function(channel, priority, reason)
                return input.acquire(channel, id, priority, reason)
            end,

            ---@param channel string
            release = function(channel)
                return input.release(channel, id)
            end,

            ---@param channel string
            ---@return boolean
            holds = function(channel)
                return input.holds(channel, id)
            end,

            ---@param channel string
            ---@return table|nil
            holder = function(channel)
                return input.holder(channel)
            end,

            ---@param key string forward|backward|left|right|turn_left|turn_right|up|down|descend
            ---@param down boolean
            set_key = function(key, down) return input.set_key(id, key, down) end,

            stop_moving = function() return input.stop_moving(id) end,

            --- Holds the character still against its own keys (true) or lets
            --- it go (false). Needs the movement lease; lifts with it.
            ---@param on boolean
            hold = function(on) return input.hold(id, on) end,

            ---@param point vec3
            look_at = function(point) return input.look_at(id, point) end,

            ---@param unit game_object
            face = function(unit) return input.face(id, unit) end,

            ---@param unit game_object
            set_target = function(unit) return input.set_target(id, unit) end,

            ---@param unit game_object
            set_focus = function(unit) return input.set_focus(id, unit) end,

            -- Everything that needs no lease is forwarded unchanged.
            loot            = input.loot,
            skin            = input.skin,
            use_object      = input.use_object,
            interact        = input.interact,
            jump            = input.jump,
            dismount        = input.dismount,
            mount           = input.mount,
            stop_attack     = input.stop_attack,
            cancel_spells   = input.cancel_spells,
            cancel_buff     = input.cancel_buff,
            clear_afk       = input.clear_afk,
            release_spirit  = input.release_spirit,
            resurrect       = input.resurrect,
            is_key_pressed  = input.is_key_pressed,
            is_typing       = input.is_typing,
            cursor_position = input.cursor_position,
            mouse_wheel_delta = input.mouse_wheel_delta,
            pet             = input.pet,
        }

        -- --- navigation -----------------------------------------------------

        local nav = rt.nav

        ctx.nav = {
            ---@param target vec3
            ---@param opts? table
            ---@return boolean started
            move_to = function(target, opts) return nav.move_to(id, target, opts) end,

            ---@param waypoints vec3[]
            ---@param opts? table
            follow_path = function(waypoints, opts) return nav.follow_path(id, waypoints, opts) end,

            --- Stops only YOUR route. A route started by another plugin is
            --- left alone, so a stop in a teardown path cannot cancel someone
            --- else's travel.
            stop = function() return nav.stop(id) end,

            available   = nav.available,
            installed   = nav.installed,
            is_moving   = nav.is_moving,
            state       = nav.state,
            progress    = nav.progress,
            destination = nav.destination,
            remaining_distance = nav.remaining_distance,
            plan_route  = nav.plan_route,
            validate    = nav.validate,
            replan      = nav.replan,
        }

        -- --- the walk map ---------------------------------------------------
        --
        -- Every read (ahead, clear_line, path, ...) is the shared service.
        -- The four calls that belong to someone are bound to this plugin, the
        -- same way nav's are: a walk holds the movement lease in our name, and
        -- a stop in a teardown path cannot cancel another plugin's walk.

        local walkmap = rt.walkmap
        ctx.walkmap = setmetatable({
            ---@param goal vec3
            ---@param opts? table
            ---@return boolean started, string|nil reason
            walk_to = function(goal, opts) return walkmap.walk_to(id, goal, opts) end,
            stop    = function() return walkmap.stop(id) end,
            ---@param radius? number yards, default 20
            request = function(radius) return walkmap.request(id, radius) end,
            release = function() return walkmap.release(id) end,
        }, { __index = walkmap })

        -- --- reactions ------------------------------------------------------
        --
        -- The reaction framework (1.8.0, services/react.lua): rules as data,
        -- scored and selected per lane, with a memory of what was just done
        -- and a journal of why. One engine per plugin, bound to this handle:
        -- it casts, subscribes and logs as this plugin, and its rules go
        -- with the plugin on unregister. Built on first access, so a plugin
        -- that never reacts pays nothing.

        local react_engine = nil
        setmetatable(ctx, { __index = function(_, key)
            if key ~= "react" then return nil end
            if not react_engine then
                react_engine = rt.react.for_owner(id, ctx)
                rawset(ctx, "react", react_engine)
            end
            return react_engine
        end })

        -- --- persistence ----------------------------------------------------

        --- A named table that loads itself and saves itself.
        ---
        --- Namespaced under the plugin id, so two plugins asking for "state"
        --- get two different files. Pass no name for the plugin's default
        --- store, which is what most plugins want.
        ---@param name? string
        ---@return table store
        function ctx.store(name)
            return rt.storage.store(id .. (name and ("." .. name) or ""))
        end

        ctx.storage = rt.storage

        -- --- menu -----------------------------------------------------------

        -- Created on first access rather than at registration, so a plugin
        -- that declares no menu never causes a page to appear. Memoized per
        -- sub-page name: calling ctx.menu() twice must return the SAME
        -- namespace, or the second call re-declares every widget on it.
        local menu_slices = {}

        --- This plugin's menu namespace.
        ---
        --- `opts.sub` returns a namespace for a further page nested under the
        --- plugin's own sidebar node, for when one page cannot hold the
        --- settings comfortably. Options other than `sub` are read from the
        --- first call for a given page and ignored afterwards.
        ---@param opts? { icon?: string, root?: boolean, sub?: string, path?: string[] }
        ---@return jcore_menu_ns
        function ctx.menu(opts)
            opts = opts or {}
            local key = opts.sub or "\1root"
            local slice = menu_slices[key]
            if slice then return slice end

            local resolved = util.shallow_copy(opts)
            resolved.icon = resolved.icon or manifest.icon
            slice = menu_ns.for_plugin(id, name, resolved)
            menu_slices[key] = slice
            return slice
        end

        -- --- overlay ui -----------------------------------------------------

        -- Bound to the plugin id: every window it opens is namespaced and
        -- billed to it, and goes away with it on unregister. See
        -- services/ui.lua for the widget set and ui_compat.lua for the
        -- declarative, legacy and menu-mirroring fronts.
        ctx.ui = rt.ui.for_owner(id)

        -- --- lifecycle ------------------------------------------------------

        ---@return boolean
        function ctx.is_enabled()
            return record.enabled and record.state == rt.registry.STATE.RUNNING
        end

        ---@param state boolean
        function ctx.set_enabled(state)
            return rt.registry.set_enabled(id, state)
        end

        --- Tears this plugin down and drops every hook it owns.
        function ctx.unregister()
            return rt.registry.unregister(id)
        end

        --- Is another plugin present and running? Use it for optional
        --- integrations, where `requires` would be too strong.
        ---@param other_id string
        ---@return boolean
        function ctx.depends_on_running(other_id)
            return rt.registry.is_running(other_id)
        end

        return ctx
    end

    --- The public surface published as _G.JCore and returned from require.
    function M.build_public()
        local public = {
            version     = rt.VERSION,
            version_num = util.parse_version(rt.VERSION),
        }

        --- Guard for consumers: returns false when the loaded core is older
        --- than the plugin needs. Always call it; a plugin built against a
        --- later core will otherwise fail on a nil service somewhere in its
        --- first tick, far from the real cause.
        ---@param minimum string e.g. "1.0.0"
        ---@return boolean
        function public.require_version(minimum)
            local needed = util.parse_version(minimum)
            if not needed then return false end
            return public.version_num >= needed
        end

        --- Registers a plugin and returns its context.
        ---@param manifest jcore_manifest
        ---@return table ctx
        function public.register(manifest)
            return rt.registry.register(manifest, M.build_context)
        end

        ---@param id string
        function public.unregister(id)
            return rt.registry.unregister(id)
        end

        ---@param id string
        ---@return boolean
        function public.is_running(id)
            return rt.registry.is_running(id)
        end

        --- Summary rows for every registered plugin.
        function public.list_plugins()
            return rt.registry.list()
        end

        --- Fires `fn` once the core has finished booting. Registering before
        --- that point is legal, so most plugins never need this -- it is for
        --- work that must observe a fully built runtime, such as reading
        --- another plugin's published state.
        ---@param fn function
        function public.on_ready(fn)
            if rt.ready then
                local ok, err = pcall(fn)
                if not ok then rt.log.core.error("on_ready handler failed: " .. tostring(err)) end
                return
            end
            events.once("jcore.ready", fn, { owner = "jcore.on_ready" })
        end

        --- False until a character has been in the world since JCore loaded
        --- (1.8.1). Loaded at the character select screen, JCore runs no
        --- pass until then, and a plugin should not start either: the game
        --- has not loaded the tables a spell, map or zone name is read from,
        --- and asking one there kills the client. jcore.world.open fires as
        --- it turns true; it never turns false again.
        ---@return boolean
        function public.in_world()
            return rt.in_world == nil or rt.in_world()
        end

        -- Raw services, for the rare consumer that wants them without a
        -- context. Using them means no owner tagging and no lifecycle, so
        -- prefer register().
        public.units     = rt.units
        public.spells    = rt.spells
        public.combat    = rt.combat
        public.enemies   = rt.enemies
        public.threat    = rt.threat
        public.draw      = rt.draw
        public.cast      = rt.cast
        public.player    = rt.player
        public.world     = rt.world
        public.group     = rt.group
        public.inventory = rt.inventory
        public.geometry  = rt.geometry
        public.sightguard = rt.sightguard
        public.missiles  = rt.missiles
        public.addons    = rt.addons
        public.input     = rt.input
        public.nav       = rt.nav
        public.walkmap   = rt.walkmap
        public.net       = rt.net
        public.storage   = rt.storage
        public.bridge    = rt.bridge
        public.assets    = rt.assets
        public.casc      = rt.casc
        public.creatures = rt.creatures
        public.names     = rt.names
        public.loot      = rt.loot
        public.power     = rt.power
        public.dump      = rt.dump
        public.faults    = rt.faults
        public.faultlog  = rt.faultlog
        public.questdb   = rt.questdb
        public.telegraphs = rt.telegraphs
        public.gamelua   = rt.gamelua
        public.react     = rt.react
        public.ui        = rt.ui
        public.image     = rt.image
        public.events    = events
        public.scheduler = scheduler
        public.cache     = rt.cache
        public.util      = util
        public.json      = rt.json
        public.log       = rt.log

        public.PRIORITY = cast.PRIORITY
        public.LAYER    = rt.draw.LAYER
        public.CHANNEL  = rt.input.CHANNEL
        public.POWER    = rt.player.POWER
        public.ROLE     = rt.group.ROLE
        public.enums    = rt.player.enums

        --- Everything the diagnostics page shows, in one table. Also the right
        --- thing to dump into a log when someone reports a frame-time problem.
        function public.diagnostics()
            return {
                version   = rt.VERSION,
                uptime    = core.time() - rt.started_at,
                plugins   = rt.registry.list(),
                phases    = scheduler.phase_stats(),
                owners    = scheduler.owner_stats(),
                units     = rt.units.stats(),
                draw      = rt.draw.stats(),
                cast      = rt.cast.stats(),
                combat    = rt.combat.stats(),
                enemies   = rt.enemies.stats(),
                threat    = rt.threat.stats(),
                player    = rt.player.stats(),
                world     = rt.world.stats(),
                group     = rt.group.stats(),
                inventory = rt.inventory.stats(),
                missiles  = rt.missiles.stats(),
                sightguard = rt.sightguard and rt.sightguard.stats() or nil,
                telegraphs = rt.telegraphs and rt.telegraphs.stats() or nil,
                react     = rt.react and rt.react.stats() or nil,
                addons    = rt.addons.stats(),
                input     = rt.input.stats(),
                nav       = rt.nav.stats(),
                walkmap   = rt.walkmap.stats(),
                net       = rt.net.stats(),
                storage   = rt.storage.stats(),
                bridge    = rt.bridge.stats(),
                assets    = rt.assets.stats(),
                casc      = rt.casc.stats(),
                creatures = rt.creatures and rt.creatures.stats() or nil,
                names     = rt.names and rt.names.stats() or nil,
                loot      = rt.loot and rt.loot.stats() or nil,
                gamelua   = rt.gamelua and rt.gamelua.stats() or nil,
                ui        = rt.ui.stats(),
                caches    = rt.cache.totals(),
                cache_rows = rt.cache.report(),
                listeners = events.describe(),
            }
        end

        return public
    end

    return M
end

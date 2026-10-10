-- Jambix Debug / aio/debug -- Jambix AIO's Debug page: what is on screen, and
-- why nothing is happening.
--
-- JAMBIX DEBUG (1.0.0): moved here from Jambix AIO's modules/debug.lua with
-- AIO 1.60.0, together with the page the AIO's main.lua used to build for it,
-- so users do not get it. Jambix AIO calls this factory with its bundle (P)
-- when this plugin is there. The page sits under "Jambix Debug" in the
-- sidebar, and its own settings (the inspector, its range, the portrait
-- self-test) are read from that page, not through the AIO's opt.
--
--
-- Two jobs, and the second is the one that actually earns its keep.
--
-- 1. INSPECT. Show the raw identity of things -- guid, npc id, object type,
--    classification, creature type, the exact name string. A node that will
--    not gather is almost always a name that does not match the rules in
--    config.lua, and you cannot see that without the exact string.
--
-- 2. EXPLAIN. Automation that quietly does nothing is the hardest thing to
--    debug in a plugin like this, because every layer has a legitimate reason
--    to decline. The status readout names the layer that said no: the safety
--    gate, the retry timer, the blacklist, range, or a feature toggle.

return function(P)
    local ctx, cfg = P.ctx, P.cfg
    local units, draw = P.units, P.draw

    local M = {}

    -- This page, and its own settings read from it.
    local page = ctx.menu({ sub = "jambix_debug", path = { "Jambix Debug", "Jambix AIO" }, icon = "activity" })
    local function setting(id, default)
        local value = page and page.get and page:get(id)
        if value == nil then return default end
        return value
    end

    local last_dump = 0

    -- --- inspector ----------------------------------------------------------

    local function describe(obj, guid)
        local parts = {}

        local ok, value

        ok, value = pcall(obj.get_object_type_string, obj)
        parts[#parts + 1] = "type=" .. tostring(ok and value or "?")

        ok, value = pcall(obj.get_npc_id, obj)
        if ok and value and value ~= 0 then parts[#parts + 1] = "npc=" .. tostring(value) end

        ok, value = pcall(obj.get_classification, obj)
        if ok and value then parts[#parts + 1] = "class=" .. tostring(value) end

        ok, value = pcall(obj.get_creature_type, obj)
        if ok and value and value ~= 0 then parts[#parts + 1] = "creature=" .. tostring(value) end

        if not obj:is_unit() then
            ok, value = pcall(obj.has_loot, obj)
            parts[#parts + 1] = "loot=" .. tostring(ok and value or false)
            ok, value = pcall(obj.can_be_used, obj)
            parts[#parts + 1] = "usable=" .. tostring(ok and value or false)
        end

        parts[#parts + 1] = "guid=" .. tostring(guid)
        return table.concat(parts, " ")
    end

    --- Overlay: a second line under everything in range showing its identity.
    local function render_inspector()
        if not setting("debug_inspect", false) then return end

        local range = setting("debug_range", 40)
        local size = math.max(9, P.opt("text_size", 13) - 2)
        local col = draw.theme.text_dim

        local function pass(list, offset)
            for i = 1, #list do
                local obj = list[i]
                local guid = obj:get_guid()
                if guid then
                    local distance = units.distance(obj)
                    if distance <= range then
                        draw.unit_label(obj, describe(obj, guid), col,
                            { layer = ctx.LAYER.OVERLAY, offset = offset, size = size })
                    end
                end
            end
        end

        pass(units.units(), -6)
        -- Objects are labelled at their own position by the world pass, so the
        -- debug line sits below rather than on top of it.
        pass(units.objects(), -14)
    end

    -- --- portrait self-test -------------------------------------------------
    --
    -- Paints the portrait art at a FIXED screen position, framed, with its
    -- registry state written beside it. Everything the portraits draw with
    -- shapes has been seen working in the game; the textures have not. This
    -- separates "the texture call paints nothing" from every other reason an
    -- icon could be missing, without a unit in range and without the ESP on.
    local function render_selftest()
        if not setting("portrait_selftest", false) then return end
        local elements = P.esp_elements
        local assets = P.JCore and P.JCore.assets
        if not elements or not assets then return end

        local x, y, cell = 220, 220, 96
        local layer = ctx.LAYER.HUD
        local frame = draw.theme.text_dim

        local samples = {
            { "game: class sheet", elements.sheets.game_classes and ("atlas:jambix_game_classes/WARRIOR") or nil },
            { "game: role circle", elements.sheets.game_roles and ("atlas:jambix_game_roles/tank") or nil },
            { "game: icon", cfg.game_icon("classicon_warrior") },
            { "addon: class sheet", elements.sheets.classes and ("atlas:jambix_classes/WARRIOR") or nil },
            { "addon: spec sheet", elements.sheets.specs and ("atlas:jambix_specs/73") or nil },
            { "CDN icon", "icon:classicon_warrior" },
        }

        for i = 1, #samples do
            local label, ref = samples[i][1], samples[i][2]
            local at = { x = x + (i - 1) * (cell + 16), y = y }
            draw.rect_2d(at, cell, cell, frame, { layer = layer, thickness = 1 })

            local state = "no source"
            if ref then
                local ready, entry = assets.request(ref)
                local base = entry and entry.atlas and assets.get(entry.atlas.ref) or entry
                if ready then
                    state = "ready" .. (base and base.tex and (" tex " .. tostring(base.tex)) or "")
                        .. (base and base.w and (string.format(" %dx%d", base.w, base.h or 0)) or "")
                    draw.image(ref, at, cell, cell, assets.WHITE, { layer = layer })
                    if base and base.draw_err then state = "draw FAILED: " .. base.draw_err end
                elseif base and (base.state == "failed" or base.dead) then
                    state = "FAILED: " .. tostring(base.err)
                else
                    state = tostring(base and base.state or "?")
                end
            end

            draw.text_2d({ x = at.x, y = at.y + cell + 4 }, label, draw.theme.text,
                { layer = layer, size = 12, shadow = true })
            draw.text_2d({ x = at.x, y = at.y + cell + 18 }, state, frame,
                { layer = layer, size = 11, shadow = true })
        end

        draw.text_2d({ x = x, y = y - 18 },
            "Portrait self-test: a texture should fill each frame. Empty frames with 'ready' = the texture call paints nothing.",
            draw.theme.text, { layer = layer, size = 12, shadow = true })
    end

    --- Writes every object in range to the log once. The overlay is unreadable
    --- in a crowd; a dump is greppable and can be pasted into a bug report.
    local function dump()
        local now = core.time()
        if (now - last_dump) < 2 then return end
        last_dump = now

        local range = setting("debug_range", 40)
        P.log.rawf("info", "--- object dump, %.0f yards ---", range)

        local function pass(list, tag)
            for i = 1, #list do
                local obj = list[i]
                local guid = obj:get_guid()
                if guid then
                    local distance = units.distance(obj)
                    if distance <= range then
                        local ok, name = pcall(obj.get_name, obj)
                        name = (ok and name) or "?"

                        local extra = ""
                        if tag == "object" then
                            local kind = P.world.classify_object(obj, guid)
                            extra = "  -> " .. (kind or "ignored")
                            if not kind then
                                -- The single most useful line in this dump:
                                -- the exact string the name rules were tested
                                -- against, quoted so trailing spaces show.
                                extra = extra .. string.format(" (name %q)", name)
                            end
                        end

                        P.log.rawf("info", "[%s] %-32s %5.1fy  %s%s",
                            tag, name:sub(1, 32), distance, describe(obj, guid), extra)
                    end
                end
            end
        end

        pass(units.units(), "unit")
        pass(units.objects(), "object")
        P.log.raw("info", "--- end dump ---")
    end

    M.dump = dump

    -- --- status readout -----------------------------------------------------

    --- The lines the debug page shows. Each one answers a question someone
    --- would otherwise have to ask.
    ---@return string[]
    function M.status_lines()
        local out = {}

        local blocked = P.actions.blocked_reason()
        out[#out + 1] = "Interaction: " .. (blocked and ("BLOCKED - " .. blocked) or "allowed")

        local a = P.actions.stats()
        out[#out + 1] = string.format("Targets tracked %d, blacklisted %d, last action %s",
            a.tracked, a.blacklisted,
            a.last_action >= 0 and string.format("%.1fs ago", a.last_action) or "never")

        local w = P.world.stats()
        local kinds = {}
        for kind, n in pairs(w.by_kind) do kinds[#kinds + 1] = kind .. "=" .. n end
        table.sort(kinds)
        out[#out + 1] = string.format("Nodes in range %d (%s), corpses %d",
            w.nodes, #kinds > 0 and table.concat(kinds, " ") or "none", w.corpses)

        local u = P.esp_units.stats()
        out[#out + 1] = string.format("Threats %d, classification cache %d",
            u.threats, u.cached)

        -- THREAT. The three reasons the ESP's threat row can be missing:
        -- no service (an older JCore), a client that never answers the
        -- threat question, or a target that is not in a fight with us.
        local threat = P.ctx and P.ctx.threat
        if not threat or type(threat.stats) ~= "function" then
            out[#out + 1] = "Threat: no service (JCore older than 1.5.0)"
        else
            local ts = threat.stats()
            -- Which way round get_threat_situation is asked: settled by the
            -- client's own answers, both ways until then.
            local order, hv, mv = nil, 0, 0
            local enemies = P.ctx.enemies
            if enemies and type(enemies.threat_order) == "function" then
                order, hv, mv = enemies.threat_order()
            end
            local line = string.format("Threat: %d mob(s) ranked, %d in roster (%d player(s)%s), client answered %d/%d, %s",
                ts.boards or 0, ts.roster or 0, ts.players or 0, ts.pet and ", pet" or "",
                ts.answered or 0, ts.asked or 0,
                order == "holder" and "asked holder-first"
                    or order == "mob" and "asked mob-first"
                    or string.format("asking both ways (votes %d-%d)", hv or 0, mv or 0))
            local target = nil
            if P.combat and type(P.combat.target) == "function" then
                local ok, value = pcall(P.combat.target)
                if ok then target = value end
            end
            local board = target and threat.get(target) or nil
            if board and board.me then
                line = line .. string.format("; target: you %.0f%% #%d of %d%s",
                    board.me.percent, board.me.rank, board.count,
                    board.me.inferred and " (from its target)" or "")
            elseif board then
                line = line .. string.format("; target: %d ranked, none of it yours", board.count)
            elseif target then
                line = line .. "; target: not in a fight with us"
            end
            out[#out + 1] = line
        end

        -- Forever only: which client, and which readers that chose. Forever
        -- (Classic+) has trait talents and no classic quest log, so both read
        -- differently there; on the classic clients this page is unchanged.
        local world_service = P.ctx and P.ctx.world
        local client = world_service and type(world_service.client) == "function"
            and select(2, pcall(world_service.client)) or nil
        local forever = type(client) == "table" and client.forever == true
        if forever then
            local ts = P.talents and P.talents.stats() or {}
            out[#out + 1] = string.format("Client: Forever%s, talents from %s",
                client.exact ~= "" and (" (" .. client.exact .. ")") or "",
                ts.source or "?")
        end

        local q = P.quests.stats()
        out[#out + 1] = string.format(
            "Quest index: %d quest(s), %d npc id(s), %d name(s)",
            q.quests or 0, q.quest_npc_ids or 0, q.quest_names or 0)
        local ql = q.questlog
        if forever and type(ql) == "table" and ql.mode == "tracked" then
            out[#out + 1] = string.format("Quest log: tracked (no classic log on Forever), %d held, %s, %d check(s)",
                ql.held or 0,
                ql.sweeping and string.format("sweeping %d/%d", ql.sweep_pos, ql.sweep_total)
                    or (ql.swept and "swept" or "not swept (needs Questie)"),
                ql.checks or 0)
        end
        out[#out + 1] = "Questie: " .. (q.questie_ready
            and (q.questie_ids .. " target id(s)") or "not loaded")
        out[#out + 1] = string.format(
            "Quest spawns: %d zone(s) verified, %d target(s), %d point(s), %d unresolved",
            q.spawn_areas or 0, q.spawn_targets or 0, q.spawn_points or 0,
            q.spawn_unresolved or 0)
        out[#out + 1] = "RestedXP: " .. (q.rxp_loaded
            and string.format("step %s, %d target(s), %d objective(s)",
                tostring(q.rxp_step), q.rxp_targets, q.rxp_objectives)
            or "not loaded")
        if q.rxp_loaded then
            out[#out + 1] = "  waypoint: " .. (q.rxp_waypoint or "none")
                .. (q.rxp_world_waypoint and " (resolved)" or " (not resolvable)")
        end

        local cache = units.stats()
        out[#out + 1] = string.format("Core cache: %d units, %d objects, reach %.0fy",
            cache.units, cache.objects, cache.max_range)

        -- PORTRAITS. An empty ring has two causes that look identical on
        -- screen: a class id nothing here can name, or art that never
        -- loaded. The first line shows the ids seen on players and whether
        -- each has a name; the second shows every icon the registry has
        -- been asked for and what became of it.
        if P.esp_classify and P.esp_elements and P.esp_roles then
            local seen = P.esp_classify.player_classes()
            local parts = {}
            for id, n in pairs(seen) do
                parts[#parts + 1] = string.format("%s=%d(x%d)",
                    P.esp_roles.class_name(id) or "UNNAMED", id, n)
            end
            table.sort(parts)
            out[#out + 1] = "Player classes seen: "
                .. (#parts > 0 and table.concat(parts, " ") or "none yet")

            local assets = P.JCore and P.JCore.assets
            if assets and assets.get then
                local sheets = P.esp_elements.sheets or {}
                local function sheet_line(label, ref, absent)
                    if not ref then return label .. ": " .. absent end
                    local entry = assets.get(ref)
                    if not entry or entry.state == "idle" then return label .. ": " .. ref .. " (not requested yet)" end
                    if entry.state == "failed" then
                        return string.format("%s: %s FAILED (%s)", label, ref, tostring(entry.err))
                    end
                    return string.format("%s: %s %s", label, ref, entry.state)
                end
                local casc = P.JCore and P.JCore.casc
                if casc then
                    local cs = casc.stats()
                    out[#out + 1] = cs.available
                        and string.format("Game archives: %s %s, %d file(s) indexed, %d missing, %d scan(s), %d read(s)",
                            tostring(cs.product), tostring(cs.build), cs.known, cs.missing, cs.scans, cs.reads)
                        or ("Game archives: not readable (" .. tostring(cs.error) .. ")")
                end
                out[#out + 1] = sheet_line("Game class sheet", sheets.game_classes, "no registry")
                out[#out + 1] = sheet_line("Game role circles", sheets.game_roles, "no registry")
                out[#out + 1] = sheet_line("Addon class sheet", sheets.classes, "Details not installed")
                out[#out + 1] = sheet_line("Addon spec sheet", sheets.specs, "Details/Plater not installed")

                local states = {}
                local function report(lists)
                    for _, list in pairs(lists) do
                        for i = 1, #list do
                            local ref = list[i][1]
                            local entry = assets.get(ref)
                            if entry and entry.state ~= "idle" and not entry.atlas then
                                local label = ref:gsub("^icon:", "")
                                if entry.state == "failed" then
                                    states[#states + 1] = string.format("%s FAILED (%s)", label, tostring(entry.err))
                                elseif entry.draw_err then
                                    states[#states + 1] = string.format("%s draw FAILED (%s)", label, entry.draw_err)
                                else
                                    states[#states + 1] = string.format("%s %s", label, entry.state)
                                end
                            end
                        end
                    end
                end
                report(P.esp_elements.class_art)
                report(P.esp_elements.creature_art)
                table.sort(states)
                out[#out + 1] = "CDN icons: "
                    .. (#states > 0 and table.concat(states, ", ") or "none requested yet")
            end
        end

        if P.catalog then
            local ok_c, line = pcall(P.catalog.status_line)
            out[#out + 1] = ok_c and line or "Catalogue: unavailable"
        end

        -- The two settings most likely to be silently responsible for "nothing
        -- is drawn" are reported explicitly rather than left to be discovered.
        if not P.opt("enabled", true) then
            out[#out + 1] = "NOTE: the master Enable toggle is OFF"
        elseif not P.toggle_active() then
            out[#out + 1] = "NOTE: the toggle keybind is currently OFF"
        end

        return out
    end

    ctx.render(render_inspector, { priority = 210 })
    ctx.render(render_selftest, { priority = 211 })

    -- --- the page (was in the AIO's main.lua) ----------------------------

    local inspector = page:section("Object inspector", "search", { column = "left" })
    inspector:toggle("debug_inspect", "Label everything with its identity", false)
    inspector:slider("debug_range", "Inspector range", 5, 100, 40, "yd")
    -- A button holds NO persisted value, so on_change never fires for one;
    -- the click arrives through opts.on_click instead.
    inspector:button("debug_dump", "Dump objects in range to the log", {
        on_click = function() M.dump() end,
    })
    inspector:button("debug_reset", "Clear retry and blacklist state", {
        style = "danger",
        on_click = function()
            if not P.actions then return end
            P.actions.reset()
            if P.esp_units and P.esp_units.invalidate then P.esp_units.invalidate() end
            ctx.log.info("retry and blacklist state cleared")
        end,
    })

    local status = page:section("Status", "activity", { column = "right" })
    status:toggle("portrait_selftest", "Portrait self-test", false)
    status:label("Paints the class crest, a spec icon and a CDN icon in frames at a")
    status:label("fixed spot on screen, with each one's load state. An empty frame")
    status:label("marked 'ready' means the texture call itself paints nothing.")
    status:label("Live state, refreshed each frame.")
    -- Declared at a fixed height because menu content is retained mode.
    page:live_lines(14, function() return M.status_lines() end)

    local narrate_log = page:section("Recent narration", "message", { column = "full" })
    narrate_log:label("The last few decisions, with the reason each was made.")
    page:live_lines(7, function()
        if not (P.narrate and P.narrate.recent) then return {} end
        return P.narrate.recent(6)
    end)

    local react_log = page:section("Reaction history", "activity", { column = "full" })
    react_log:label("State changes, reactions sent, refusals and why, bail-out start and")
    react_log:label("end, retries held back. Newest first.")
    react_log:button("react_reset", "Forget the reaction memory", {
        on_click = function()
            if P.react then P.react.reset() end
            ctx.log.info("reaction memory cleared")
        end,
    })
    page:live_lines(12, function()
        if not P.react then return {} end
        return P.react.log_lines(12)
    end)

    return M
end

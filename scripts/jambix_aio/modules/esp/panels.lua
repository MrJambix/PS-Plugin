-- Jambix AIO / esp/panels -- proximity alerts and the threat panel.
--
-- Both read the threat list the collector rebuilt this frame, which is what
-- keeps the unit handles in it valid. Neither draws a mark on a unit: these
-- are the answers to "is something about to kill me", and on a hardcore
-- character they are the last thing that should be competing for attention
-- with a herb node.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, draw = P.units, P.draw
    local collect = P.esp_collect

    local M = {}

    local atan2 = math.atan2 or math.atan

    --- The player's level, or 0. A failed read used to leave pcall's error
    --- MESSAGE in the level, and the first sum with it threw -- the panel and
    --- the quest lines that share its render job went with it.
    local function level_of(player)
        local ok, level = pcall(player.get_level, player)
        return (ok and type(level) == "number") and level or 0
    end

    -- --- bearing ------------------------------------------------------------

    --- Which way to turn to face a position, as an eight-point arrow.
    ---@param player game_object
    ---@param target_pos vec3
    ---@return string
    local ARROWS = { "^", "<^", "<", "<v", "v", "v>", ">", "^>" }

    -- Where you stand and which way you face, read once per frame for every
    -- row that asks: a panel of eight rows asked the client sixteen times.
    local pose = { at = -1, pos = nil, facing = nil }
    local function player_pose(player)
        local now = collect.now
        if not now or now <= 0 or now ~= pose.at then
            pose.at = now or -1
            pose.pos = units.position and units.position(player) or player:get_position()
            local ok, facing = pcall(player.get_rotation, player)
            pose.facing = ok and facing or nil
        end
        return pose.pos, pose.facing
    end

    local function bearing_arrow(player, target_pos)
        local ppos, facing = player_pose(player)
        if not ppos then return "" end
        if not facing then return "" end

        local angle = atan2(target_pos.y - ppos.y, target_pos.x - ppos.x)
        -- Wrapped with a modulo rather than a subtract-until loop: a loop
        -- never ends on a rotation the client answers as inf, and a hung
        -- render job is the whole game hung.
        local rel = (angle - facing + math.pi) % (2 * math.pi) - math.pi
        if rel ~= rel then return "" end

        local octant = math.floor((rel + math.pi / 8) / (math.pi / 4)) % 8
        return ARROWS[octant + 1] or ""
    end

    M.bearing_arrow = bearing_arrow

    -- --- alerts -------------------------------------------------------------

    local alerted_at = {}

    function M.alert_check()
        if not P.opt("alerts_on", true) then return end

        local player = units.player()
        if not player then return end

        local threats = collect.threats
        local now = core.time()
        local cooldown = P.opt("alert_cooldown", 15)
        local my_level = level_of(player)
        local delta = P.opt("alert_level_delta", 2)

        for i = 1, #threats do
            local entry = threats[i]
            local info, distance, guid = entry.info, entry.distance, entry.guid

            local should, reason
            if info.category == "hostile_player"
                and P.opt("alert_players", true)
                and distance <= P.opt("alert_player_range", 60) then
                should, reason = true, "Hostile player"
            elseif (info.category == "elite" or info.category == "rare"
                    or info.category == "boss")
                and P.opt("alert_elites", true)
                and distance <= P.opt("alert_elite_range", 35)
                and info.level >= (my_level + delta) then
                should, reason = true, (info.tag or "Elite")
            end

            if should and (not alerted_at[guid] or (now - alerted_at[guid]) > cooldown) then
                alerted_at[guid] = now
                log.fmt("warn", "%s: %s (%d) at %.0f yards",
                    reason, info.name, info.level, distance)

                if P.opt("alert_sound", true) then
                    pcall(core.play_sound_by_id, 8959)
                end

                if P.opt("alert_toast", false) then
                    draw.notify("jambix.aio.threat." .. tostring(guid), reason,
                        string.format("%s (%.0f) -- %.0f yards",
                            info.name, info.level, distance),
                        4, draw.theme.danger, cooldown)
                end

                ctx.emit("jambix.aio.threat", {
                    guid = guid, name = info.name, level = info.level,
                    category = info.category, distance = distance, reason = reason,
                })
            end
        end

        for guid, at in pairs(alerted_at) do
            if (now - at) > (cooldown * 4) then alerted_at[guid] = nil end
        end
    end

    -- --- threat panel -------------------------------------------------------

    -- Whether a threat has you targeted comes from JCore's enemies service,
    -- which reads it for every hostile in range already. No native call.
    local enemies = ctx.enemies

    local function on_me(guid)
        local row = enemies and enemies.get and enemies.get(guid) or nil
        return row ~= nil and row.targeting_me == true
    end

    --- What is already on you outranks what is merely near you; within each,
    --- nearest first.
    local function by_urgency(a, b)
        if a.on_me ~= b.on_me then return a.on_me end
        return a.distance < b.distance
    end

    function M.draw_threat_panel()
        if not P.opt("alerts_on", true) or not P.opt("alert_panel", true) then return end

        local player = units.player()
        if not player then return end

        local threats = collect.threats
        local my_level = level_of(player)
        local delta = P.opt("alert_level_delta", 2)
        local player_range = P.opt("alert_player_range", 60)
        local elite_range = P.opt("alert_elite_range", 35)

        local rows = {}
        for i = 1, #threats do
            local entry = threats[i]
            local info = entry.info
            local include =
                (info.category == "hostile_player" and entry.distance <= player_range)
                or ((info.category == "elite" or info.category == "rare"
                        or info.category == "boss")
                    and entry.distance <= elite_range
                    and info.level >= (my_level + delta))
            if include then
                -- The threat entry is this frame's own table, so the flag
                -- rides on it rather than in a second list.
                entry.on_me = on_me(entry.guid)
                rows[#rows + 1] = entry
            end
        end

        if #rows == 0 then return end
        table.sort(rows, by_urgency)

        local size = P.opt("text_size", 13)
        local line_h = size + 6
        -- Room for a "you" tag after the distance column.
        local width = 255
        local shown = math.min(#rows, 8)
        local height = line_h * (shown + 1) + 8

        local _, screen_h = draw.screen_size()
        local x = 24
        local y = screen_h * 0.5 - height * 0.5

        local content_y = draw.panel({ x = x, y = y }, width, height, {
            layer = ctx.LAYER.HUD,
            title = string.format("THREATS  (%d)", #rows),
            title_color = draw.theme.warning,
            size = size,
        })

        for i = 1, shown do
            local entry = rows[i]
            local info = entry.info
            local col = P.category_color[info.category] or draw.theme.danger
            if info.is_player and P.opt("class_colors", true) and info.class_id then
                col = P.class_color[info.class_id] or col
            end

            local pos = units.position and units.position(entry.unit) or entry.unit:get_position()
            local arrow = pos and bearing_arrow(player, pos) or ""

            local row_y = content_y + line_h * (i - 1)
            draw.text_2d({ x = x + 10, y = row_y },
                string.format("%-2s %-18s %3.0fy", arrow,
                    info.name:sub(1, 18), entry.distance),
                col, { layer = ctx.LAYER.HUD, size = size })
            if entry.on_me then
                local tag_w = draw.measure and draw.measure("you", size) or size * 1.6
                draw.text_2d({ x = x + width - 10 - tag_w, y = row_y }, "you",
                    draw.theme.danger, { layer = ctx.LAYER.HUD, size = size })
            end
        end
    end

    -- --- off-screen threat arrows -------------------------------------------

    --- Arrows at the edge of the screen for threats behind you.
    ---
    --- The panel tells you something is there; this tells you WHERE without
    --- reading a row of text, which is the difference between reacting and
    --- noticing. Only threats that are actually off-screen get one -- an arrow
    --- pointing at something you can already see is clutter.
    function M.draw_threat_arrows()
        if not P.opt("alerts_on", true) or not P.opt("alert_arrows", false) then return end

        local threats = collect.threats
        local range = P.opt("alert_player_range", 60)

        for i = 1, #threats do
            local entry = threats[i]
            local info = entry.info
            if entry.distance <= range
                and (info.category == "hostile_player" or info.category == "boss"
                    or info.category == "rare" or info.category == "elite") then
                if not draw.unit_w2s(entry.unit) then
                    local pos = entry.unit:get_position()
                    if pos then
                        local col = P.category_color[info.category] or draw.theme.danger
                        draw.edge_indicator(pos, col, {
                            layer = ctx.LAYER.HUD,
                            size = 10,
                            label = string.format("%.0fy", entry.distance),
                        })
                    end
                end
            end
        end
    end

    return M
end

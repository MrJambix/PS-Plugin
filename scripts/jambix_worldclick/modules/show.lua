-- World Click to Move / show -- where you are being walked, on the world.
--
-- While a walk is under way ("Show the route", on by default): a ring under
-- what you clicked, its name above it, and Sentinel's route as a line from
-- you along the waypoints still ahead (from the client's path index). Walking
-- straight at it, the line is straight and dimmer. A click that starts a
-- walk sends a pulse out from what was clicked; one that is refused (too far,
-- Sentinel not connected) pulses in the warning colour. While the minimap
-- is being found, a dot on the middle clicked; once found, its outline for
-- a few seconds (minimap.lua). Everything goes through JCore's draw queue,
-- never core.graphics.

return function(P)
    local draw, units = P.draw, P.units

    local M = {}

    local RING = 1.2              -- yd
    local LABEL_UP = 2.6          -- yd above its feet

    local function path_index()
        local global = _G.SentinelNavClient
        local client = global and global.client
        local fn = client and client.get_path_index
        if type(fn) ~= "function" then return 1 end
        local ok, i = pcall(fn, client)
        i = ok and tonumber(i) or 1
        return math.max(1, math.floor(i))
    end

    --- A pulse at what a click was on: accepted or refused.
    function M.pulse(pos, accepted)
        if not pos or not draw or not draw.pulse then return end
        if not P.opt("show_route", true) then return end
        local col = accepted and draw.theme.accent or draw.theme.warning
        pcall(draw.pulse, P.vec3(pos.x, pos.y, pos.z or 0), col, { life = 0.6, from = 0.4, to = 2.0 })
    end

    function M.render()
        if not P.enabled() then return end
        -- The minimap's outline while it is being found, and a moment after.
        if P.minimap then P.minimap.render() end
        if not P.opt("show_route", true) then return end
        local r = P.walk.route()
        if not r or not r.goal then return end
        local theme = draw.theme
        local col = theme.accent
        local goal = P.vec3(r.goal.x, r.goal.y, r.goal.z or 0)
        local layer = P.LAYER and P.LAYER.OVERLAY or nil

        draw.circle_3d(goal, RING, col, { layer = layer, thickness = 2 })
        if draw.text_3d then
            draw.text_3d(P.vec3(goal.x, goal.y, goal.z + LABEL_UP), tostring(r.name), theme.text,
                { layer = layer, size = 13 })
        end

        local from = units.player_position()
        if not from then return end
        local path = r.path
        if path and #path > 0 then
            local i = math.min(path_index(), #path)
            local prev = from
            for k = i, #path do
                local p = path[k]
                if p and p.x then
                    local point = P.vec3(p.x, p.y, p.z or 0)
                    draw.line_3d(prev, point, col, { layer = layer, thickness = 2 })
                    prev = point
                end
            end
        else
            draw.line_3d(from, goal, r.mode == "line" and theme.text_dim or col,
                { layer = layer, thickness = 1.5 })
        end
    end

    return M
end

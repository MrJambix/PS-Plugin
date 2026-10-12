-- World Click to Move / minimap -- a click on the minimap walks you to the
-- spot it shows.
--
-- The user, 2026-10-11: "should allow me to click the minimap and also do
-- that".
--
-- WHERE THE MINIMAP IS. The loader reads no game frame, and the game Lua
-- bridge does not answer on Forever (JCore's gamelua: "the string set by
-- execute never read back"). Forever places the minimap with Edit Mode, so
-- it can be anywhere and any size. So you show it once: "Find my minimap"
-- on the page, then a click on its middle (your arrow) and one on its edge.
-- The centre and the radius, in screen pixels, are kept as the page's
-- mm_x, mm_y and mm_r (sliders too, to nudge by hand).
--
-- HOW FAR A PIXEL IS. The minimap shows a fixed number of yards across at
-- each zoom level, whatever its size on screen: YARDS (HereBeDragons-Pins'
-- table, the one every pin addon uses), outdoors and indoors (the player's
-- is_indoors). The zoom is not readable either (no CVar read), so it is the
-- page's "Minimap zoom", and the mouse wheel over the minimap moves it a
-- level per notch, as it moves the game's ("Follow the mouse wheel").
--
-- WHICH WAY IS UP. North, unless "My minimap turns with me" (the game's
-- Rotate Minimap): then up is the way you face.
--
-- THE RIM. Nearer the edge than INSIDE of the radius is left alone: the
-- zoom buttons, the tracking and the mail icons sit there.

return function(P)
    local units, draw = P.units, P.draw
    local input = P.ctx.input
    local try = P.try
    local sqrt, floor, cos, sin = math.sqrt, math.floor, math.cos, math.sin

    local M = {}

    -- Yards across the whole minimap at zoom levels 0 (out) to 5 (in).
    local YARDS = {
        outdoor = { 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
        indoor = { 300, 240, 180, 120, 80, 50 },
    }
    M.ZOOM_NAMES = { "All the way out", "In 1", "In 2", "In 3", "In 4", "All the way in" }

    local INSIDE = 0.94           -- of the radius: nearer the rim is the rim's buttons
    local MIN_RADIUS = 15         -- px: a smaller "minimap" is a slipped click
    local CALIBRATE_FOR = 30      -- s to give the two clicks
    local SHOW_FOR = 6            -- s the outline stays up after it is set

    local cal = nil               -- { step = "centre" | "edge", at, x, y }
    local shown_until = -1
    local note = nil              -- the last thing calibrating said, for the page

    local function now() return core.time() end

    --- The minimap's centre and radius on screen, or nil when not set.
    function M.circle()
        local x, y, r = tonumber(P.opt("mm_x", 0)), tonumber(P.opt("mm_y", 0)), tonumber(P.opt("mm_r", 0))
        if not x or not y or not r or r < MIN_RADIUS then return nil end
        return x, y, r
    end

    function M.set_up() return M.circle() ~= nil end

    --- The zoom level, 0 (out) to 5 (in).
    function M.zoom()
        local z = tonumber(P.opt("mm_zoom", 1)) or 1
        if z < 1 then z = 1 elseif z > 6 then z = 6 end
        return floor(z) - 1
    end

    local function indoors()
        local me = units.player()
        return me ~= nil and P.call(me, "is_indoors") == true
    end

    --- Yards across the whole minimap now.
    function M.yards_across()
        local t = indoors() and YARDS.indoor or YARDS.outdoor
        return t[M.zoom() + 1]
    end

    local function inside(x, y)
        local cx, cy, r = M.circle()
        if not cx then return nil end
        local dx, dy = x - cx, y - cy
        return sqrt(dx * dx + dy * dy) <= r, dx, dy, r
    end

    -- --- finding it ------------------------------------------------------------------

    function M.start_calibration()
        cal = { step = "centre", at = now() }
        note = nil
        P.note("finding the minimap: click its middle, then its edge")
    end

    function M.cancel_calibration(why)
        if not cal then return end
        cal = nil
        note = why
    end

    --- True while the two clicks are awaited (and not timed out).
    function M.calibrating()
        if cal and now() - cal.at > CALIBRATE_FOR then
            M.cancel_calibration("took too long; press Find my minimap again")
        end
        return cal ~= nil
    end

    --- One of the two clicks, at screen (x, y).
    function M.calibrate_point(x, y)
        if not cal then return end
        if cal.step == "centre" then
            cal.step, cal.x, cal.y, cal.at = "edge", x, y, now()
            return
        end
        local dx, dy = x - cal.x, y - cal.y
        local r = sqrt(dx * dx + dy * dy)
        if r < MIN_RADIUS then
            note = "that edge was on the middle; click the minimap's edge"
            return
        end
        P.menu:set("mm_x", floor(cal.x + 0.5))
        P.menu:set("mm_y", floor(cal.y + 0.5))
        P.menu:set("mm_r", floor(r + 0.5))
        P.note("minimap set: centre %d, %d, radius %d px", floor(cal.x + 0.5), floor(cal.y + 0.5), floor(r + 0.5))
        cal = nil
        note = nil
        shown_until = now() + SHOW_FOR
    end

    function M.forget()
        cal = nil
        P.menu:set("mm_r", 0)
        note = "forgotten"
    end

    -- --- the zoom, by the wheel ----------------------------------------------------------

    local wheel_frame = nil

    --- The mouse wheel over the minimap zooms the game's minimap a level a
    --- notch: the page's zoom follows (once a frame).
    function M.wheel(x, y)
        if not P.opt("mm_wheel", true) or not M.set_up() or not x then return end
        local t = now()
        if wheel_frame == t then return end
        wheel_frame = t
        local delta = tonumber(try(input.mouse_wheel_delta)) or 0
        if delta == 0 then return end
        if not inside(x, y) then return end
        local notches = math.abs(delta) >= 120 and floor(math.abs(delta) / 120) or 1
        local level = M.zoom() + (delta > 0 and notches or -notches)
        if level < 0 then level = 0 elseif level > 5 then level = 5 end
        if level ~= M.zoom() then
            P.menu:set("mm_zoom", level + 1)
            P.note("minimap zoom %d (the mouse wheel)", level)
        end
    end

    -- --- a click on it ---------------------------------------------------------------------

    --- What a click at (x, y) on the minimap walks you to: a spot; or nil,
    --- why not, and true when (x, y) is on the minimap all the same (so it
    --- is no click on the world behind it). nil alone: not on the minimap.
    function M.spot_at(x, y)
        local on, dx, dy, r = inside(x, y)
        if not on then return nil end
        if not P.opt("mm_on", true) then return nil, "minimap clicks are switched off", true end
        if sqrt(dx * dx + dy * dy) > r * INSIDE then return nil, "on the minimap's rim (its buttons)", true end
        local pos = units.player_position()
        if not pos then return nil, "not in the world", true end
        local per_px = M.yards_across() / (2 * r)
        local up, right = -dy * per_px, dx * per_px
        local wx, wy
        if P.opt("mm_rotate", false) then
            local me = units.player()
            local th = me and tonumber(P.call(me, "get_rotation")) or 0
            wx = pos.x + up * cos(th) + right * sin(th)
            wy = pos.y + up * sin(th) - right * cos(th)
        else
            -- World x is north and y is west.
            wx, wy = pos.x + up, pos.y - right
        end
        local wz = P.ground.height_near(wx, wy, pos.z or 0)
        local yd = floor(sqrt(up * up + right * right) + 0.5)
        return { kind = "spot", how = "minimap", name = string.format("the minimap spot (%d yd)", yd),
            pos = P.vec3(wx, wy, wz) }
    end

    -- --- the page and the outline ----------------------------------------------------------

    function M.status_line()
        if M.calibrating() then
            if cal.step == "centre" then return "Minimap: click the MIDDLE of your minimap (your arrow)" end
            return "Minimap: now click the EDGE of your minimap" .. (note and (" (" .. note .. ")") or "")
        end
        if not P.opt("mm_on", true) then return "Minimap: off" end
        local cx, cy, r = M.circle()
        if not cx then
            return "Minimap: not found yet; press Find my minimap" .. (note and (" (" .. note .. ")") or "")
        end
        return string.format("Minimap: at %d, %d, %d px across; zoom %d (%d yd across%s)", cx, cy, r * 2,
            M.zoom(), floor(M.yards_across() + 0.5), indoors() and ", indoors" or "")
    end

    --- The outline while it is being found, and for a moment once set.
    function M.render()
        if not draw or not draw.circle_2d then return end
        local theme = draw.theme
        if cal then
            if cal.step == "edge" then
                draw.circle_2d({ x = cal.x, y = cal.y }, 4, theme.accent, { filled = true })
            end
            return
        end
        if now() > shown_until then return end
        local cx, cy, r = M.circle()
        if not cx then return end
        draw.circle_2d({ x = cx, y = cy }, r, theme.accent, { thickness = 2 })
        draw.circle_2d({ x = cx, y = cy }, r * INSIDE, theme.text_dim, { thickness = 1 })
    end

    function M.show_outline(seconds) shown_until = now() + (seconds or SHOW_FOR) end

    return M
end

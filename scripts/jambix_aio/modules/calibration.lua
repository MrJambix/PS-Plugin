-- Jambix AIO / calibration -- one screenshot to settle what was built blind (1.89.0).
--
-- The user, 2026-10-09: "Calibration window". Several of JCore's shader
-- shapes were written from the API's descriptions and never seen in the
-- game. The World marks page's button draws each one round you for twelve
-- seconds, lettered, straight through JCore's draw (not the world layer, so
-- nothing is shaded or dropped):
--
--   A  a shader ring a quarter full, with +x, -x, +y and -y written round
--      it: where does the fill start, and which way does it run?
--   B  the plain ring (circle_3d_percentage) asked for a quarter: is it?
--   C  a curtain with its sheet        D  a beacon        a pulse every 2 s
--   E  a card plate with its shadow, an icon at its left: does the shadow
--      lie on the icon (textures paint under shapes)?
--   F  a bar asked for half: half, shading left to right?
--
-- E and F need JCore 1.15 (plate_2d, bar_2d); without it they say so.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local floor = math.floor

    local M = {}

    local LENGTH = 12            -- seconds the pattern stays
    local until_t = 0
    local pulse_at = 0

    local function color(r, g, b, a)
        if P.color then return P.color(r, g, b, a or 255) end
        return { r = r, g = g, b = b, a = a or 255 }
    end
    local C = {
        ring = color(240, 180, 60), ring_to = color(240, 70, 60), band = color(0, 0, 0, 140),
        plain = color(120, 200, 255), curtain = color(100, 220, 130), curtain_top = color(100, 220, 130, 30),
        beacon = color(245, 200, 70), pulse = color(170, 120, 250, 230), text = color(245, 245, 250),
        label = color(240, 220, 120), plate = color(12, 12, 16, 215), bar = color(90, 190, 110),
        bar_to = color(170, 240, 180), bar_bg = color(22, 22, 26, 235),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function vec(x, y, z)
        local geo = ctx.geometry
        return (geo and ask(geo.vec, x, y, z)) or { x = x, y = y, z = z }
    end

    --- Starts the pattern for LENGTH seconds (the page's button).
    function M.start()
        until_t = core.time() + LENGTH
        pulse_at = 0
    end

    function M.active() return core.time() < until_t end

    --- One frame. Called by main.lua's render job.
    function M.render()
        local now = core.time()
        if now >= until_t then return end
        local draw = P.draw
        local me = units.player_position and units.player_position()
        if not (draw and me) then return end
        local L = ctx.LAYER or {}
        local world, hud = L.WORLD or 100, L.HUD or 500
        local text = draw.text_3d
        local function label(x, y, z, s, col)
            if text then text(vec(x, y, z), s, col or C.label, { size = 14, layer = hud }) end
        end

        -- A: the shader ring, a quarter, with the axes round it.
        local ax, ay = me.x + 5, me.y
        if draw.ring_3d then
            draw.ring_3d(vec(ax, ay, me.z), 1.5, 0.25, C.ring, { to = C.ring_to, bg = C.band, layer = world })
        end
        label(ax, ay, me.z + 2.2, "A: where does the quarter start?")
        label(ax + 2.2, ay, me.z + 0.2, "+x", C.text); label(ax - 2.2, ay, me.z + 0.2, "-x", C.text)
        label(ax, ay + 2.2, me.z + 0.2, "+y", C.text); label(ax, ay - 2.2, me.z + 0.2, "-y", C.text)

        -- B: the plain ring, asked for a quarter.
        local bx, by = me.x, me.y + 5
        if draw.arc_3d then draw.arc_3d(vec(bx, by, me.z), 1.5, 0.25, C.plain, { layer = world, thickness = 3 }) end
        label(bx, by, me.z + 2.2, "B: a quarter of a ring?")

        -- C, D and the pulse.
        local cx, cy = me.x - 5, me.y
        if draw.curtain_3d then
            draw.curtain_3d(vec(cx, cy, me.z), 1.5, C.curtain, { to = C.curtain_top, fill = 0.4, layer = world })
        end
        label(cx, cy, me.z + 2.4, "C: curtain with a sheet")
        local dx, dy = me.x, me.y - 5
        if draw.beacon_3d then draw.beacon_3d(vec(dx, dy, me.z), C.beacon, { height = 8, layer = world }) end
        label(dx, dy, me.z + 1.5, "D: beacon")
        if draw.pulse and now - pulse_at >= 2 then
            pulse_at = now
            draw.pulse(vec(me.x, me.y, me.z), C.pulse, { life = 1.2, from = 1, to = 4 })
        end

        -- E and F: a card's plate beside an icon, and a bar asked for half.
        local sw, sh = 1920, 1080
        if draw.screen_size then
            local w, h = draw.screen_size()
            if w and h then sw, sh = w, h end
        end
        local x, y = floor(sw / 2 - 90), floor(sh * 0.72)
        local t2 = draw.text_2d
        if draw.image then draw.image("spell:133", { x = x - 26, y = y - 2 }, 24, 24, nil, { layer = hud }) end
        if draw.plate_2d and draw.bar_2d then
            draw.plate_2d({ x = x, y = y }, 180, 20, C.plate, { layer = hud })
            if t2 then t2({ x = x + 6, y = y + 3 }, "E: shadow on the icon?", C.text, { size = 13, layer = hud }) end
            draw.bar_2d({ x = x, y = y + 30 }, 180, 8, 0.5, C.bar, { to = C.bar_to, bg = C.bar_bg, layer = hud })
            if t2 then t2({ x = x, y = y + 42 }, "F: half full, shading left to right?", C.label, { size = 13, layer = hud }) end
        elseif t2 then
            t2({ x = x, y = y + 3 }, "E and F need JCore 1.15 (plate_2d, bar_2d)", C.label, { size = 13, layer = hud })
        end
        if t2 then
            t2({ x = x - 26, y = y - 40 }, string.format("Calibration: %d s", math.max(0, math.ceil(until_t - now))),
                C.text, { size = 15, layer = hud })
        end
    end

    return M
end

-- JCore 1.11.0: draw.ring_3d and draw.curtain_3d. 1.13.0: the filled sheet,
-- distance detail, beacon_3d and pulse.
--
-- ring_3d is one render_circle_percentage_3d where the loader has it and
-- the "Shader drawing" switch is on, and two outlines otherwise or once
-- the call has raised. curtain_3d is the Aurora Systems wave as one
-- submission of line_3d calls. The mock's w2s answers nil (everything
-- culled), so a camera that puts every point on screen is installed here.

local mock = require("mock_core")
mock.install()

local g = core.graphics
local ring_calls, raise_ring = {}, false
rawset(g, "render_circle_percentage_3d", function(...)
    if raise_ring then error("ring broke") end
    ring_calls[#ring_calls + 1] = { ... }
end)
local on_screen = true
rawset(g, "w2s", function() if on_screen then return { x = 600, y = 400 } end return nil end)
local lines = {}
local count_line = g.line_3d
rawset(g, "line_3d", function(a, b, col, thickness, fade)
    lines[#lines + 1] = { a, b, col, thickness, fade }
    return count_line(a, b, col, thickness, fade)
end)

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local JCore, draw
local job = nil -- what the test plugin's render job draws this frame

local function frame_with(fn, label)
    job = fn
    ring_calls, lines = {}, {}
    mock.frame(1)
    job = nil
    fail_on_errors(label or "frame")
end

local CENTER = { x = 10, y = 20, z = 5 }
local AMBER = { r = 240, g = 180, b = 60, a = 255 }
local RED = { r = 235, g = 87, b = 87, a = 255 }

local T = {}

T[#T + 1] = { "boot: JCore 1.11.0 publishes ring_3d and curtain_3d", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    fail_on_errors("boot")
    JCore = _G.JCore
    draw = JCore.draw
    assert_eq(JCore.version, "1.8.1", "version")
    assert(type(draw.ring_3d) == "function", "draw.ring_3d")
    assert(type(draw.curtain_3d) == "function", "draw.curtain_3d")
    assert_eq(draw.shaders, true, "draw.shaders on by default")
    JCore.register({
        id = "world.test", name = "World", version = "1.0.0", kind = "plugin",
        on_load = function(ctx)
            ctx.render(function() if job then job(ctx.draw) end end)
        end,
    })
    mock.frame(2)
    fail_on_errors("registered")
end }

T[#T + 1] = { "ring_3d: one shader call with the band, both fill colours, the fraction and the defaults", function()
    frame_with(function(d) d.ring_3d(CENTER, 1.5, 0.4, AMBER, { to = RED }) end, "ring")
    assert_eq(#ring_calls, 1, "one shader ring")
    local a = ring_calls[1]
    assert_eq(a[1], CENTER, "center"); assert_eq(a[2], 1.5, "radius")
    assert_eq(a[3], draw.theme.backdrop, "band defaults to the backdrop")
    assert_eq(a[4], AMBER, "fill start"); assert_eq(a[5], RED, "fill end")
    assert_eq(a[6], 0.4, "progress")
    assert(math.abs(a[7] + math.pi / 2) < 1e-9, "start -pi/2")
    assert_eq(a[8], 1, "clockwise"); assert_eq(a[9], 0.70, "inner"); assert_eq(a[10], 0.98, "outer"); assert_eq(a[11], 1.0, "softness")
    assert_eq(mock.frame_counts.circle_3d_percentage or 0, 0, "no outline")
end }

T[#T + 1] = { "ring_3d: a fraction outside 0..1 is clamped, and an off-screen centre is culled", function()
    frame_with(function(d) d.ring_3d(CENTER, 1, 1.7, AMBER) end, "clamp")
    assert_eq(ring_calls[1][6], 1, "clamped to 1")
    on_screen = false
    frame_with(function(d) d.ring_3d(CENTER, 1, 0.5, AMBER) end, "culled")
    on_screen = true
    assert_eq(#ring_calls, 0, "nothing for an off-screen ring")
end }

T[#T + 1] = { "ring_3d with the switch off: the band and the fill as outlines, the fill in the colour it has reached", function()
    local fills = {}
    local count_pct = g.circle_3d_percentage
    rawset(g, "circle_3d_percentage", function(c, r, col, pct, th)
        fills[#fills + 1] = { c, r, col, pct, th }
        return count_pct(c, r, col, pct, th)
    end)
    mock.menu:set("JCore/UI", "shaders", false)
    assert_eq(draw.shaders, false, "draw follows the switch")
    frame_with(function(d) d.ring_3d(CENTER, 2, 0.5, AMBER, { to = RED }) end, "outlines")
    assert_eq(#ring_calls, 0, "no shader ring")
    assert_eq(mock.frame_counts.circle_3d or 0, 1, "the band")
    assert_eq(#fills, 1, "the fill")
    assert_eq(fills[1][4], 50, "the fill's percentage")
    assert(math.abs(fills[1][2] - 2 * (0.70 + 0.98) / 2) < 1e-9, "outlines at the band's middle")
    local c = fills[1][3]
    assert(c.r > RED.r and c.r < AMBER.r and c.g > RED.g and c.g < AMBER.g, "halfway between amber and red")
    mock.menu:set("JCore/UI", "shaders", true)
    rawset(g, "circle_3d_percentage", count_pct)
    frame_with(function(d) d.ring_3d(CENTER, 2, 0.5, AMBER) end, "back on")
    assert_eq(#ring_calls, 1, "shader ring back")
end }

-- --- 1.13.0: the filled sheet, distance detail, beacons and pulses -------------

local tris = {}
rawset(g, "triangle_3d_filled", function(a, b, c, col) tris[#tris + 1] = { a, b, c, col } end)

local function frame_tris(fn, label)
    tris = {}
    frame_with(fn, label)
end

T[#T + 1] = { "curtain_3d fill: a sheet of triangles between the rings, fading upward; lines = false is the sheet alone", function()
    frame_tris(function(d) d.curtain_3d(CENTER, 2, AMBER, { to = RED, fill = 0.6, time = 1 }) end, "filled")
    assert_eq(#tris, 3 * 36 * 2, "two triangles a cell, three bands of 36")
    assert_eq(#lines, 180, "the lines as well")
    assert_eq(tris[1][4].a, math.floor(255 * 0.6 + 0.5), "the bottom band at the fill's strength")
    local top = tris[#tris][4]
    assert(top.a < tris[1][4].a, "fading toward the top")
    assert(top.r < AMBER.r, "and shading toward the top colour")
    frame_tris(function(d) d.curtain_3d(CENTER, 2, AMBER, { fill = 0.6, lines = false, time = 1 }) end, "sheet only")
    assert_eq(#lines, 0, "no lines"); assert_eq(#tris, 216, "the sheet")
    rawset(g, "triangle_3d_filled", nil)
    frame_tris(function(d) d.curtain_3d(CENTER, 2, AMBER, { fill = 0.6, time = 1 }) end, "no native")
    assert_eq(#tris, 0, "a client without triangle_3d_filled: no sheet")
    assert_eq(#lines, 180, "the lines still")
    rawset(g, "triangle_3d_filled", function(a, b, c, col) tris[#tris + 1] = { a, b, c, col } end)
end }

T[#T + 1] = { "curtain_3d lod: full detail near you, fewer points far away, never under 10", function()
    local U = JCore.units
    local had = U.player_position
    U.player_position = function() return { x = 0, y = 0, z = 0 } end
    local function count_at(x)
        frame_with(function(d) d.curtain_3d({ x = x, y = 0, z = 0 }, 2, AMBER, { lod = true, time = 1 }) end, "lod " .. x)
        return #lines
    end
    assert_eq(count_at(10), 180, "10 yd: all 36 points")
    assert_eq(count_at(60), 4 * 12 + 4 * 3, "60 yd: 12 points")
    assert_eq(count_at(500), 4 * 10 + 4 * 3, "500 yd: the floor of 10")
    U.player_position = had
end }

T[#T + 1] = { "beacon_3d: a tall filled pillar, drawn while only its top is on screen, with a glow at its foot", function()
    local foot = { x = 0, y = 0, z = 0 }
    rawset(g, "w2s", function(p) if p.z > 5 then return { x = 600, y = 200 } end return nil end)
    frame_tris(function(d) d.beacon_3d(foot, AMBER) end, "top only")
    assert(#lines > 0 and #tris > 0, "the pillar, lines and sheet")
    assert_eq(#ring_calls, 0, "its foot is off screen: no glow")
    local tallest = 0
    for i = 1, #lines do tallest = math.max(tallest, lines[i][2].z) end
    assert(tallest > 10, "about 12 yd tall, got " .. tallest)
    rawset(g, "w2s", function() if on_screen then return { x = 600, y = 400 } end return nil end)
    frame_tris(function(d) d.beacon_3d(foot, AMBER) end, "all on screen")
    assert_eq(#ring_calls, 1, "the glow at its foot")
    assert(math.abs(ring_calls[1][2] - 1.8) < 1e-9, "four times its radius")
end }

T[#T + 1] = { "pulse: fire and forget -- it opens out and fades over its life, and follows a unit when given one", function()
    local d = JCore.draw
    d.pulse(CENTER, AMBER)
    assert_eq(d.pulse_count(), 1, "one playing")
    frame_with(nil, "first")
    assert_eq(#ring_calls, 1, "drawn on the next frame")
    local r0, a0 = ring_calls[1][2], ring_calls[1][4].a
    mock.time = mock.time + 0.35
    frame_with(nil, "halfway")
    assert(ring_calls[1][2] > r0 + 0.5, "opening out")
    assert(ring_calls[1][4].a < a0, "fading")
    mock.time = mock.time + 0.5
    frame_with(nil, "over")
    assert_eq(#ring_calls, 0, "gone after its life")
    assert_eq(d.pulse_count(), 0, "and forgotten")
    local mob = { get_position = function() return { x = 7, y = 8, z = 0 } end }
    d.pulse(mob, RED, { life = 1, from = 1, to = 3 })
    frame_with(nil, "on a unit")
    assert_eq(ring_calls[1][1].x, 7, "under the unit")
    mock.time = mock.time + 2
    frame_with(nil, "done")
end }

T[#T + 1] = { "ring_3d: a shader call that raises is warned about once, then the outlines from that frame on", function()
    local before = #mock.warnings
    raise_ring = true
    frame_with(function(d) d.ring_3d(CENTER, 1, 0.3, AMBER) end, "raising")
    raise_ring = false
    assert_eq(mock.frame_counts.circle_3d or 0, 1, "outline stood in that frame")
    frame_with(function(d) d.ring_3d(CENTER, 1, 0.3, AMBER) end, "after")
    assert_eq(#ring_calls, 0, "not tried again")
    assert_eq(mock.frame_counts.circle_3d or 0, 1, "outlines")
    local n = 0
    for i = before + 1, #mock.warnings do
        if mock.warnings[i]:find("render_circle_percentage_3d raised", 1, true) then n = n + 1 end
    end
    assert_eq(n, 1, "one warning")
end }

T[#T + 1] = { "curtain_3d: 4 rings of 36 points and a vertical every third point is 180 lines in one submission", function()
    local before = draw.stats().submitted
    frame_with(function(d) d.curtain_3d(CENTER, 2, AMBER, { to = RED, time = 3 }) end, "curtain")
    assert_eq(#lines, 4 * 36 + 12 * 3, "line count")
    local base_z, top_ok = true, false
    for i = 1, 36 do
        if math.abs(lines[i][1].z - CENTER.z) > 1e-9 then base_z = false end
    end
    assert(base_z, "the bottom ring stays on the ground")
    for i = 3 * 36 + 1, 4 * 36 do
        if lines[i][1].z > CENTER.z + 0.5 then top_ok = true end
    end
    assert(top_ok, "the top ring stands about a yard up")
    assert_eq(lines[1][3], AMBER, "bottom ring in the base colour")
    assert_eq(lines[3 * 36 + 1][3], RED, "top ring in the top colour")
    assert_eq(lines[1][4], 1.5, "thickness")
end }

T[#T + 1] = { "curtain_3d: options shape it, and an off-screen one costs nothing", function()
    frame_with(function(d)
        d.curtain_3d(CENTER, 3, AMBER, { points = 20, rings = 2, verticals = 0, height = 2, time = 1 })
    end, "small curtain")
    assert_eq(#lines, 2 * 20, "two rings, no verticals")
    on_screen = false
    frame_with(function(d) d.curtain_3d(CENTER, 3, AMBER) end, "off screen")
    on_screen = true
    assert_eq(#lines, 0, "culled")
end }

T[#T + 1] = { "draw.blend: carries a colour part of the way to another", function()
    local mid = draw.blend(AMBER, RED, 0.5)
    assert(math.abs(mid.r - (240 + 235) / 2) <= 1 and math.abs(mid.g - (180 + 87) / 2) <= 1, "halfway")
    assert_eq(draw.blend(AMBER, RED, 0), AMBER, "0 is the first")
    assert_eq(draw.blend(AMBER, RED, 1), RED, "1 is the second")
end }

return T

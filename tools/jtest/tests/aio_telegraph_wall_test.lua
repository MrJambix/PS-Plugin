-- Jambix AIO 1.85.0: the telegraph countdown wall (modules/telegraphs.lua).
--
-- A circle still to land gets JCore 1.11's ring_3d round its edge, filling
-- as the cast runs, and a curtain standing on that edge rising toward
-- impact. Without ring_3d, or with "tele_wall" off, the old sweep circle.
-- Built against a fake telegraph service, so it runs without the extracted
-- spell tables aio_telegraphs_test needs.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

_G.core = { time = function() return 1000 end, game_time = function() return 1000000 end }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, label)
    if type(got) ~= "number" or math.abs(got - want) > 1e-6 then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function bundle(list, opts)
    opts = opts or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = opts.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not opts.curtains_default then
        for _, id in ipairs({ "tele_wall" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local draw = {
        LAYER = { DANGER = 200, HUD = 500 },
        circle_3d = rec("circle_3d"), polygon_3d = rec("polygon_3d"), path_3d = rec("path_3d"),
        text_3d = rec("text_3d"), text_bg = rec("text_bg"),
        screen_size = function() return 1920, 1080 end,
    }
    if not opts.old_jcore then
        draw.ring_3d = rec("ring_3d")
        draw.curtain_3d = rec("curtain_3d")
    end
    local P = {
        ctx = {
            telegraphs = { active = function() return list end },
            world = { in_raid_instance = function() return false end, in_dungeon = function() return false end },
            units = { classification = function() return 0 end },
        },
        draw = draw,
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
    }
    package.loaded["jambix_aio/modules/telegraphs"] = nil
    return require("jambix_aio/modules/telegraphs")(P), calls
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function circle(o)
    local t = { shape = "circle", placed = true, phase = "cast", level = 1, radius = 5, dist = 10,
        x = 3, y = 4, z = 0, name = "Flamestrike", remaining = 1.2 }
    for k, v in pairs(o or {}) do t[k] = v end
    t.pos = t.pos or { x = t.x, y = t.y, z = t.z }
    return t
end

local T = {}

T[#T + 1] = { "a circle still to land: a ring round its edge filling as it runs, and a wall rising toward impact", function()
    local t = circle({ progress = 0.4 })
    local M, calls = bundle({ t })
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "one edge ring")
    assert_eq(rings[1][1], t.pos, "on the circle"); assert_eq(rings[1][2], 5, "at its edge")
    near(rings[1][3], 0.4, "as far round as the cast has run")
    assert_eq(rings[1][5].inner, 0.9, "a thin band at the rim")
    assert_eq(rings[1][5].layer, 200, "on the danger layer")
    local walls = all(calls, "curtain_3d")
    assert_eq(#walls, 1, "one wall")
    near(walls[1][4].height, 0.15 + 1.4 * 0.4, "risen two fifths of the way")
    assert_eq(walls[1][2], 5, "standing on the edge")
    local sweeps = 0
    for _, c in ipairs(all(calls, "circle_3d")) do if c[2] < 5 then sweeps = sweeps + 1 end end
    assert_eq(sweeps, 0, "no old sweep circle as well")
end }

T[#T + 1] = { "the wall only while it is coming: none once landed, none on a lingering patch or a cone", function()
    local M, calls = bundle({ circle({ progress = 1 }), circle({ progress = 0.5, phase = "linger" }),
        { shape = "cone", placed = true, phase = "cast", level = 1, radius = 8, degrees = 60, facing = 0,
          progress = 0.5, x = 0, y = 0, z = 0, pos = { x = 0, y = 0, z = 0 }, dist = 5 } })
    M.render()
    assert_eq(#all(calls, "ring_3d"), 0, "no edge ring")
    assert_eq(#all(calls, "curtain_3d"), 0, "no wall")
end }

T[#T + 1] = { "tele_wall off, or a JCore without ring_3d: the old sweep circle", function()
    local M, calls = bundle({ circle({ progress = 0.5 }) }, { settings = { tele_wall = false } })
    M.render()
    assert_eq(#all(calls, "ring_3d") + #all(calls, "curtain_3d"), 0, "switched off")
    local sweep
    for _, c in ipairs(all(calls, "circle_3d")) do if c[2] < 5 then sweep = c end end
    assert(sweep, "the sweep circle")
    near(sweep[2], 2.5, "half the radius")
    local M2, calls2 = bundle({ circle({ progress = 0.5 }) }, { old_jcore = true })
    M2.render()
    local found = false
    for _, c in ipairs(all(calls2, "circle_3d")) do if c[2] < 5 then found = true end end
    assert(found, "older JCore: the sweep circle")
end }

T[#T + 1] = { "standing in it: the wall is never the first thing dropped on a heavy frame", function()
    local M, calls = bundle({ circle({ progress = 0.3, inside = true }), circle({ progress = 0.3, x = 30 }) })
    M.render()
    local walls = all(calls, "curtain_3d")
    assert_eq(#walls, 2, "two walls")
    local inside, outside
    for _, w in ipairs(walls) do if w[1].x == 3 then inside = w else outside = w end end
    assert_eq(inside[4].droppable, false, "the one you stand in is kept")
    assert_eq(outside[4].droppable, true, "another may go")
end }

return T

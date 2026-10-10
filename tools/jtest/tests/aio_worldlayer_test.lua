-- Jambix AIO 1.89.0: the world layer (modules/worldlayer.lua) every world
-- mark goes through: lanes, the budget, brightness, colour-blind correction,
-- density and the wall fade, then JCore's draw as asked.

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
local function near(got, want, label, eps)
    if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-6) then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function assert_true(v, label)
    if not v then error(label, 2) end
end

local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    local los = o.los or {}
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {},
        units = { combat_reach = function(u) return u and u.reach or 1.5 end },
        draw = {
            ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), beacon_3d = rec("beacon_3d"), pulse = rec("pulse"),
            unit_los = function(u) if los[u] == nil then return true end return los[u] end,
            set_los_budget = function(nb) calls[#calls + 1] = { name = "los_budget", nb } end,
            with_alpha = function() return "passed through" end,
        },
    }
    package.loaded["jambix_aio/modules/worldlayer"] = nil
    local W = require("jambix_aio/modules/worldlayer")(P)
    return W, calls, settings, los, P
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local RED = { r = 240, g = 70, b = 60, a = 200 }
local GREEN = { r = 100, g = 220, b = 130, a = 255 }
local POS = { x = 1, y = 2, z = 3 }

local T = {}

T[#T + 1] = { "nothing is drawn as it is called; the flush draws it, with the extra options gone", function()
    local W, calls = bundle()
    W.ring_3d(POS, 2, 0.5, RED, { to = GREEN, prio = "warn", module = "test", inner = 0.9 })
    assert_eq(#calls, 0, "kept, not drawn")
    W.flush()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "drawn at the flush")
    assert_eq(r[1][1], POS, "where"); assert_eq(r[1][2], 2, "radius"); assert_eq(r[1][3], 0.5, "fraction")
    assert_eq(r[1][4].r, 240, "colour"); assert_eq(r[1][4].a, 200, "alpha at 100%")
    assert_eq(r[1][5].inner, 0.9, "its own options kept")
    assert_eq(r[1][5].prio, nil, "prio gone"); assert_eq(r[1][5].module, nil, "module gone")
    assert_eq(r[1][5].to.g, 220, "the end colour shaded too")
    W.flush()
    assert_eq(#all(calls, "ring_3d"), 1, "a flush draws a mark once")
    assert_eq(W.stats().by.test, nil, "and the next frame's stats start empty")
end }

T[#T + 1] = { "lanes: a ring under a unit with a lane gets the lane's radius, an index steps outward", function()
    local W, calls = bundle()
    local mob = { reach = 1.5 }
    W.ring_3d(POS, 99, 1, RED, { unit = mob, lane = "kick" })
    W.ring_3d(POS, 99, 1, RED, { unit = mob, lane = "timers", index = 1 })
    W.ring_3d(POS, 99, 1, RED, { unit = mob, lane = "timers", index = 3 })
    W.ring_3d(POS, 7, 1, RED, {})
    W.flush()
    local r = all(calls, "ring_3d")
    local edge = 1.5 + 0.3
    near(r[1][2], edge + 0.7 + 0.25, "kick")
    near(r[2][2], edge + 1.4 + 0.25, "the first timer: under a mob, where the trinket would be")
    near(r[3][2], edge + 1.4 + 0.7 + 0.25, "the third, two steps out")
    assert_eq(r[4][2], 7, "no lane: the radius asked for")
    local big = { reach = 9 }
    near(W.lane_radius(big, "kick"), 4 + 0.7 + 0.25, "the edge is capped at 4 yd, as the ESP's")
end }

T[#T + 1] = { "lanes: under a player the trinket, CC and diminishing returns come first; nothing overlaps", function()
    local W = bundle()
    local foe = { reach = 1.5, is_player = function() return true end }
    local mob = { reach = 1.5, is_player = function() return false end }
    local edge = 1.5 + 0.3
    near(W.lane_radius(foe, "dr", 1), edge + 2.8 + 0.25, "diminishing returns after the CC")
    near(W.lane_radius(foe, "timers", 1), edge + 3.85 + 0.25, "a player's timers outside them")
    near(W.lane_radius(foe, "reaction", 1), edge + 5.25 + 0.25, "and the reactions outside those")
    near(W.lane_radius(mob, "timers", 1), edge + 1.4 + 0.25, "a mob's timers move in")
    near(W.lane_radius(mob, "reaction", 1), edge + 2.8 + 0.25, "and its reactions")
    -- Each lane's last slot ends before the next lane starts.
    local function last(lane, slots) return W.lane_radius(foe, lane, slots) end
    assert_true(last("cc", 3) < W.lane_radius(foe, "dr", 1), "CC (3) clear of diminishing returns")
    assert_true(last("dr", 3) < W.lane_radius(foe, "timers", 1), "diminishing returns (3) clear of the timers")
    assert_true(last("timers", 4) < W.lane_radius(foe, "reaction", 1), "timers (4) clear of the reactions")
    assert_true(W.lane_radius(mob, "timers", 4) < W.lane_radius(mob, "reaction", 1), "and under a mob")
    assert_true(W.lane_radius(mob, "ttd", 1) < W.lane_radius(mob, "timers", 1), "time to die inside a mob's timers")
end }

T[#T + 1] = { "the budget: decoration goes first, then information; a warning is never dropped", function()
    local W, calls = bundle({ settings = { world_budget = 4 } })
    W.beacon_3d(POS, GREEN, { prio = "decor", module = "beacons" })
    W.ring_3d(POS, 1, 1, RED, { prio = "info", module = "timers" })
    W.ring_3d(POS, 1, 1, RED, { prio = "info", module = "timers" })
    for _ = 1, 6 do W.ring_3d(POS, 1, 1, RED, { prio = "warn", module = "pull" }) end
    W.flush()
    local s = W.stats()
    assert_eq(#all(calls, "ring_3d"), 6, "the six warnings, over the budget")
    assert_eq(#all(calls, "beacon_3d"), 0, "the beacon dropped")
    assert_eq(s.dropped, 3, "the beacon and both timers")
    assert_eq(s.by.pull, 6, "counted by module")
    local W2, calls2 = bundle({ settings = { world_budget = 0 } })
    for _ = 1, 50 do W2.ring_3d(POS, 1, 1, RED, { prio = "decor" }) end
    W2.flush()
    assert_eq(#all(calls2, "ring_3d"), 50, "0: no budget")
end }

T[#T + 1] = { "a curtain costs by its lines and its sheet", function()
    local W = bundle({ settings = { world_budget = 0 } })
    W.curtain_3d(POS, 2, RED, { points = 36, rings = 4, fill = 0.3 })
    W.flush()
    assert_eq(W.stats().weight, 4 + 1, "36 x 4 / 40 rounded up, and one for the sheet")
end }

T[#T + 1] = { "brightness and the colour-blind correction shade every colour", function()
    local W, calls = bundle({ settings = { world_brightness = 50, world_colorblind = 3 } })
    W.ring_3d(POS, 1, 1, RED, { prio = "warn" })
    W.flush()
    local c = all(calls, "ring_3d")[1][4]
    assert_eq(c.a, 100, "half the alpha")
    assert(c.g ~= 70 or c.b ~= 60, "red shifted for deuteranopia: " .. c.r .. "," .. c.g .. "," .. c.b)
    local r, g, b = W.daltonize(128, 128, 128, 3)
    near(r, 128, "grey stays grey", 0.5); near(g, 128, "grey", 0.5); near(b, 128, "grey", 0.5)
    local r1, g1, b1 = W.daltonize(240, 70, 60, 1)
    assert_eq(r1 + g1 + b1, 370, "off: as given")
end }

T[#T + 1] = { "density: fewer points and a fainter sheet; Minimal leaves decoration out", function()
    local W, calls = bundle({ settings = { world_density = 2 } })
    W.curtain_3d(POS, 2, RED, { points = 30, fill = 0.5, prio = "info" })
    W.beacon_3d(POS, GREEN, { prio = "info" })
    W.flush()
    local c = all(calls, "curtain_3d")[1][4]
    assert_eq(c.points, 20, "two thirds of the points"); near(c.fill, 0.3, "a fainter sheet")
    local b = all(calls, "beacon_3d")[1][3]
    assert_eq(b.points, 9, "a beacon's default 14, scaled"); near(b.fill, 0.3, "its default sheet, scaled")
    local W3, calls3 = bundle({ settings = { world_density = 3 } })
    W3.beacon_3d(POS, GREEN, { prio = "decor" })
    W3.ring_3d(POS, 1, 1, RED, { prio = "warn" })
    W3.flush()
    assert_eq(#all(calls3, "beacon_3d"), 0, "decoration left out")
    assert_eq(#all(calls3, "ring_3d"), 1, "the warning kept")
end }

T[#T + 1] = { "behind a wall: a mark under a unit is drawn at a third; one with no unit is not checked", function()
    local mob, seen = { reach = 1.5 }, { reach = 1.5 }
    local W, calls, _, los = bundle()
    los[mob] = false
    W.ring_3d(POS, 1, 1, RED, { unit = mob })
    W.ring_3d(POS, 1, 1, RED, { unit = seen })
    W.ring_3d(POS, 1, 1, RED, {})
    W.flush()
    local r = all(calls, "ring_3d")
    assert_eq(r[1][4].a, math.floor(200 * 0.35 + 0.5), "behind the wall: a third")
    assert_eq(r[2][4].a, 200, "in sight: full")
    assert_eq(r[3][4].a, 200, "no unit: full")
    assert_eq(W.stats().faded, 1, "one faded")
    assert_eq(all(calls, "los_budget")[1][1], 8, "its own line-of-sight budget, 8 by default")
    local W2, calls2, settings2, los2 = bundle({ settings = { world_los = false } })
    los2[mob] = false
    W2.ring_3d(POS, 1, 1, RED, { unit = mob })
    W2.flush()
    assert_eq(all(calls2, "ring_3d")[1][4].a, 200, "the fade off")
end }

T[#T + 1] = { "the master switch off draws nothing; anything else asked of it is JCore's draw", function()
    local W, calls = bundle({ settings = { world_on = false } })
    W.ring_3d(POS, 1, 1, RED, { prio = "warn" })
    W.pulse(POS, RED, {})
    W.flush()
    assert_eq(#all(calls, "ring_3d") + #all(calls, "pulse"), 0, "nothing")
    assert_eq(W.with_alpha(RED, 0.5), "passed through", "draw's own helpers pass through")
end }

T[#T + 1] = { "through the layer: the fight timers module's rings land in the timers lane", function()
    local W, calls = bundle()
    local me = { guid = "me" }
    local mob = { guid = "mob", reach = 1.5, pos = { x = 9, y = 0, z = 0 } }
    mob.get_auras = function() return {
        { buff_id = 1, expire_time = 1000000 + 8000, caster = me },
        { buff_id = 2, expire_time = 1000000 + 12000, caster = me },
    } end
    local P = {
        opt = function(_, d) return d end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 } },
        combat = { target = function() return mob end },
        units = { player = function() return me end, guid = function(u) return u and u.guid end,
            position = function(u) return u and u.pos end, combat_reach = function(u) return u.reach end },
        draw = { ring_3d = function() error("the module drew past the layer") end },
        worldmarks = W,
    }
    package.loaded["jambix_aio/modules/timers"] = nil
    local M = require("jambix_aio/modules/timers")(P)
    M.render()
    W.flush()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 2, "two timers")
    near(r[1][2], W.lane_radius(mob, "timers", 1), "the first in the lane")
    near(r[2][2], W.lane_radius(mob, "timers", 2), "the second a step out")
    assert_eq(W.stats().by.timers, 2, "counted as the timers'")
end }

T[#T + 1] = { "calibration: the lettered pattern for twelve seconds, straight through JCore's draw", function()
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local now = 1000
    _G.core.time = function() return now end
    local P = {
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100, HUD = 500 } },
        units = { player_position = function() return { x = 0, y = 0, z = 0 } end },
        draw = { ring_3d = rec("ring_3d"), arc_3d = rec("arc_3d"), curtain_3d = rec("curtain_3d"),
            beacon_3d = rec("beacon_3d"), pulse = rec("pulse"), text_3d = rec("text_3d"), text_2d = rec("text_2d"),
            image = rec("image"), plate_2d = rec("plate_2d"), bar_2d = rec("bar_2d"),
            screen_size = function() return 1920, 1080 end },
    }
    package.loaded["jambix_aio/modules/calibration"] = nil
    local M = require("jambix_aio/modules/calibration")(P)
    M.render()
    assert_eq(#calls, 0, "nothing before the button")
    M.start()
    M.render()
    assert_eq(#all(calls, "ring_3d"), 1, "A"); assert_eq(all(calls, "ring_3d")[1][3], 0.25, "a quarter")
    assert_eq(#all(calls, "arc_3d"), 1, "B"); assert_eq(all(calls, "arc_3d")[1][3], 0.25, "a quarter asked for")
    assert_eq(#all(calls, "curtain_3d"), 1, "C"); assert_eq(#all(calls, "beacon_3d"), 1, "D")
    assert_eq(#all(calls, "pulse"), 1, "a pulse"); assert_eq(#all(calls, "plate_2d"), 1, "E")
    assert_eq(#all(calls, "bar_2d"), 1, "F"); assert_eq(all(calls, "bar_2d")[1][4], 0.5, "half asked for")
    assert(#all(calls, "text_3d") >= 6, "lettered, with the axes")
    now = now + 13
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#calls, 0, "gone after twelve seconds")
    _G.core.time = function() return 1000 end
end }


T[#T + 1] = { "a pulse's from and to are yards, not colours: passed as they are", function()
    local W, calls = bundle()
    W.pulse(POS, RED, { life = 0.9, from = 1, to = 4, prio = "warn", module = "party" })
    W.flush()
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "the pulse")
    assert_eq(p[1][3].to, 4, "to: 4 yd"); assert_eq(p[1][3].from, 1, "from: 1 yd")
    assert_eq(p[1][2].r, 240, "its colour shaded")
end }

T[#T + 1] = { "a mark whose draw raises is counted and skipped; the queue clears and the next frame draws", function()
    local W, calls, _, _, P = bundle()
    local good = P.draw.curtain_3d
    P.draw.curtain_3d = function() error("boom") end
    W.ring_3d(POS, 1, 1, RED, { prio = "warn", module = "a" })
    W.curtain_3d(POS, 1, RED, { prio = "warn", module = "b" })
    W.flush()
    assert_eq(#all(calls, "ring_3d"), 1, "the ring still drawn")
    assert_eq(W.stats().errors, 1, "the raising curtain counted")
    assert(W.stats().last_error:find("boom", 1, true), "and its error kept")
    P.draw.curtain_3d = good
    W.flush()
    assert_eq(#all(calls, "ring_3d"), 1, "the queue cleared: nothing drawn twice")
    W.curtain_3d(POS, 1, RED, { prio = "warn", module = "b" })
    W.flush()
    assert_eq(#all(calls, "curtain_3d"), 1, "the next frame draws")
end }

return T

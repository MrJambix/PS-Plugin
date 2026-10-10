-- Jambix AIO 1.7.6 (2026-10-10): RestedXP's waypoint placed in the world, and
-- the guide walk's route drawn, in modules/quests.lua.
--
-- In game on Forever the guide walk set off on Sentinel from Stormwind with
-- "guide walk: walking to  (15210 yd, Sentinel)". The recorder had the
-- answers: RestedXP's waypoint was map 1439 (Darkshore) at 0.3721, 0.4422,
-- and get_world_pos_from_map_pos answered x 6402, y 504.4 on continent 1
-- -- Kalimdor, while you stood in the Eastern Kingdoms (instance 0). Pinned:
--   * a waypoint on another continent is not placed (no line, no beacon, no
--     walk) and says where it is, once in the trace;
--   * a {0, 0} answer and a distance RestedXP disagrees with are not places;
--   * the zero-valued waypoint is no waypoint (the panel's "-> 0y" row);
--   * the guide walk's route is drawn along Sentinel's path, solid, in the
--     guide line's place; without a path, straight at its goal;
--   * Era and Forever seed quest spawns from their own map ids.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local cfg = require("jambix_aio/modules/config")
local make_quests = require("jambix_aio/modules/quests")

local T = {}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_true(v, label)
    if not v then error(label, 2) end
end

local noop = function() end
local quiet = setmetatable({}, { __index = function() return noop end })

-- The recorder's answers (Forever, 2026-10-10).
local DARKSHORE = { map_id = 1439, x = 0.3721, y = 0.4422, title = "", type = "goto", goal_num = 1, dist = 0,
    is_manual = false, wrong_continent = false }
local IN_STORMWIND = { x = -8800, y = 640, z = 94 }

--- The client's map call: Darkshore as the recorder answered it, Elwynn
--- beside you, and a retail id it cannot place.
local function to_world(map_id, p)
    if map_id == 1439 then return { x = 6402, y = 504.4 }, 1 end
    if map_id == 1429 then return { x = -8800 + p.x * 100, y = 640 + p.y * 100 }, 0 end
    return { x = 0, y = 0 }, 0
end

local function build(o)
    o = o or {}
    local R = { paths = {}, texts = {}, rings = 0, traced = {}, timers = {} }
    _G.core = {
        time = function() return 1000 end,
        game_time = function() return 1000000 end,
        get_height_for_position = function() return 90 end,
        game_ui = { get_world_pos_from_map_pos = o.to_world or to_world },
        addons = { rested_xp = {
            is_loaded = function() return true end,
            get_current_step = function()
                return o.step or { num = 4, active = true, goals = { { action = "goto", text = "" } } }
            end,
            get_current_stickies = function() return {} end,
            get_current_waypoint = function() return o.waypoint end,
            get_step_waypoints = function() return o.stops or {} end,
            get_objectives = function() return {} end,
        } },
    }
    local here = o.here or 0
    local draw = {
        theme = { accent = "accent", warning = "warning", text = "text", text_dim = "dim", good = "good",
            backdrop = "backdrop" },
        path_3d = function(points, col, opts) R.paths[#R.paths + 1] = { points = points, col = col, opts = opts or {} } end,
        ring_3d = function() R.rings = R.rings + 1 end,
        circle_3d = function() R.rings = R.rings + 1 end,
        text_3d = function(_, text) R.texts[#R.texts + 1] = text end,
        text_2d = noop, rect_2d = noop,
        screen_size = function() return 1920, 1080 end,
    }
    local settings = o.settings or {}
    local P = {
        cfg = cfg,
        ctx = {
            on = noop, tick = noop, LAYER = { WORLD = 100, OVERLAY = 300, HUD = 500 },
            every = function(_, fn) R.timers[#R.timers + 1] = fn end,
            emit = function(name, text) if name == "jcore.recorder.trace" then R.traced[#R.traced + 1] = text end end,
            world = { instance_type = function() return "none" end, instance_id = function() return here end },
        },
        log = quiet,
        units = { player_position = function() return o.me or IN_STORMWIND end },
        draw = draw,
        questlog = { read = function() return {}, "classic" end, consider = noop },
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
        category_color = { guide = "gold" },
        load = function(path) error("unexpected load of " .. path) end,
        esp = { entities = function() return {} end, count = function() return 0 end },
        client_version = o.client_version,
        forever = o.client_version == "Forever",
        guidewalk = o.guidewalk,
    }
    package.loaded["jambix_aio/modules/quests"] = nil
    R.Q = make_quests(P)
    R.P = P
    function R.refresh() for i = 1, #R.timers do R.timers[i]() end end
    function R.traced_has(needle)
        for i = 1, #R.traced do if R.traced[i]:find(needle, 1, true) then return true end end
        return false
    end
    return R
end

-- --- placing the waypoint ----------------------------------------------------------------

T[#T + 1] = { "Darkshore read in Stormwind is not placed, and says where it is (in game: 15210 yd)", function()
    -- What the walk was sent at: x 6402, y 504.4, about 15,200 yd from Stormwind.
    local dx, dy = 6402 - IN_STORMWIND.x, 504.4 - IN_STORMWIND.y
    assert_true(math.sqrt(dx * dx + dy * dy) > 15000, "the conversion is that far")

    local R = build({ waypoint = DARKSHORE, here = 0 })
    local rxp = R.Q.rxp
    assert_true(rxp.waypoint, "RestedXP's waypoint is kept")
    assert_eq(rxp.world_waypoint, nil, "not placed: no line, no beacon, no walk")
    assert_true(rxp.waypoint_away, "said to be away")
    assert_eq(rxp.waypoint_away.why, "continent", "on another continent")
    assert_eq(rxp.waypoint_away.text, "Darkshore, on Kalimdor", "by the map's name")
    assert_eq(rxp.waypoint_away.here, "the Eastern Kingdoms", "and where you are")
    assert_true(R.traced_has("Darkshore, on Kalimdor"), "said in the trace")
    local n = #R.traced
    R.refresh()
    assert_eq(#R.traced, n, "once per waypoint, not every second")
end }

T[#T + 1] = { "the same waypoint read in Darkshore is placed", function()
    local R = build({ waypoint = DARKSHORE, here = 1, me = { x = 6300, y = 450, z = 20 } })
    local wp = R.Q.rxp.world_waypoint
    assert_true(wp, "placed")
    assert_eq(wp.x, 6402, "x")
    assert_eq(wp.y, 504.4, "y")
    assert_eq(R.Q.rxp.waypoint_away, nil, "not away")
end }

T[#T + 1] = { "a waypoint that says wrong_continent is not placed", function()
    local wp = {}
    for k, v in pairs(DARKSHORE) do wp[k] = v end
    wp.wrong_continent = true
    local R = build({ waypoint = wp, here = 1, me = { x = 6300, y = 450, z = 20 } })
    assert_eq(R.Q.rxp.world_waypoint, nil, "not placed")
    assert_eq(R.Q.rxp.waypoint_away.why, "continent", "away")
end }

T[#T + 1] = { "a map the client cannot place ({0, 0}) is not a place", function()
    local R = build({ waypoint = { map_id = 52, x = 0.42, y = 0.82, title = "Sentinel Hill", dist = 0 } })
    assert_eq(R.Q.rxp.world_waypoint, nil, "not placed at 0, 0")
    assert_eq(R.Q.rxp.waypoint_away, nil, "and not called away: it did not convert")
end }

T[#T + 1] = { "RestedXP's own distance far from ours: not placed; close to it: placed", function()
    local far = function(map_id) return { x = -8800 + 3000, y = 640 }, map_id == 1429 and 0 or 0 end
    local R = build({ to_world = far, waypoint = { map_id = 1429, x = 0.5, y = 0.5, title = "Goldshire", dist = 100 } })
    assert_eq(R.Q.rxp.world_waypoint, nil, "3000 yd where RestedXP says 100")
    assert_eq(R.Q.rxp.waypoint_away.why, "distance", "said why")

    local near = build({ waypoint = { map_id = 1429, x = 0.5, y = 0.5, title = "Goldshire", dist = 70 } })
    assert_true(near.Q.rxp.world_waypoint, "about 70 yd either way: placed")
end }

T[#T + 1] = { "RestedXP's zero-valued waypoint is no waypoint", function()
    local R = build({ waypoint = { map_id = 0, x = 0, y = 0, title = "", dist = 0, wrong_continent = false } })
    assert_eq(R.Q.rxp.waypoint, nil, "no waypoint (the panel's \"-> 0y\" row)")
    assert_eq(R.Q.rxp.world_waypoint, nil, "nothing placed")
end }

T[#T + 1] = { "a step's stops on another continent are dropped, the rest kept", function()
    local stop = { map_id = 1429, x = 0.3, y = 0.3, title = "Goldshire", dist = 0 }
    local wrong = {}
    for k, v in pairs(DARKSHORE) do wrong[k] = v end
    local R = build({ waypoint = stop, stops = { wrong, stop } })
    assert_eq(#R.Q.rxp.step_waypoints, 1, "one stop")
    assert_eq(R.Q.rxp.step_waypoints[1].raw.title, "Goldshire", "the one on this continent")
end }

-- --- the guide walk's route --------------------------------------------------------------

local ME = { x = 0, y = 0, z = 0 }
local HERE_WP = { map_id = 1429, x = 0.5, y = 0.5, title = "Goldshire", dist = 0 }

local function walking(path)
    return { route = function()
        return { goal = { x = 100, y = 0, z = 0 }, label = "Marshal McBride", mode = path and "nav" or "line",
            path = path }
    end }
end

T[#T + 1] = { "the walk's route is drawn along Sentinel's path, solid, in the guide line's place", function()
    -- The first point is behind you; the route then turns twice.
    local path = { { x = -5, y = 0, z = 0 }, { x = 20, y = 0, z = 1 }, { x = 20, y = 30, z = 1 }, { x = 100, y = 0, z = 0 } }
    local R = build({ waypoint = HERE_WP, me = ME, guidewalk = walking(path) })
    R.Q.render_hud()
    assert_eq(#R.paths, 1, "one line: the route, not the guide's too")
    local line = R.paths[1]
    assert_eq(line.opts.dash, nil, "solid")
    assert_eq(line.col, "gold", "in the guide's colour")
    assert_eq(line.points[1], ME, "from you")
    assert_eq(line.points[2].x, 20, "on to the next turn, not back to the point behind you")
    assert_eq(line.points[3].y, 30, "round the corner")
    assert_eq(#line.points, 4, "cut at the line's length (60 yd)")
    assert_eq(R.rings, 0, "cut short: no ring where nothing is")
    -- 20 + 30 + 85.4 along the route.
    assert_true(R.texts[1] and R.texts[1]:find("Marshal McBride  (135y)", 1, true), tostring(R.texts[1]))
end }

T[#T + 1] = { "a short route ends in a ring", function()
    local path = { { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, { x = 10, y = 10, z = 0 } }
    local R = build({ me = ME, guidewalk = walking(path) })
    R.Q.render_hud()
    assert_eq(#R.paths[1].points, 3, "all of it")
    assert_eq(R.rings, 1, "the ring at its end")
end }

T[#T + 1] = { "without a path of Sentinel's, the route is the ground line straight at the goal", function()
    local R = build({ waypoint = HERE_WP, me = ME, guidewalk = walking(nil) })
    R.Q.render_hud()
    assert_eq(#R.paths, 1, "one line")
    local line = R.paths[1]
    assert_eq(line.opts.dash, nil, "solid")
    local last = line.points[#line.points]
    assert_true(last.x > 50 and math.abs(last.y) < 0.01, "towards the goal, cut at the line's length")
end }

T[#T + 1] = { "the walk not walking, or the switch off: the guide's dashed line, as before", function()
    local idle = { route = function() return nil end }
    local R = build({ waypoint = HERE_WP, me = { x = -8800, y = 640, z = 94 }, guidewalk = idle })
    R.Q.render_hud()
    assert_eq(#R.paths, 1, "the guide's line")
    assert_true(R.paths[1].opts.dash ~= nil, "dashed")

    local path = { { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 } }
    local off = build({ waypoint = HERE_WP, me = { x = -8800, y = 640, z = 94 }, guidewalk = walking(path),
        settings = { rxp_follow_route = false } })
    off.Q.render_hud()
    assert_eq(#off.paths, 1, "one line")
    assert_true(off.paths[1].opts.dash ~= nil, "the guide's, dashed")
end }

T[#T + 1] = { "a route that raises draws the guide's line instead", function()
    local broken = { route = function() error("boom") end }
    local R = build({ waypoint = HERE_WP, me = { x = -8800, y = 640, z = 94 }, guidewalk = broken })
    R.Q.render_hud()
    assert_eq(#R.paths, 1, "the guide's line")
end }

-- --- quest spawns' seeds -----------------------------------------------------------------

T[#T + 1] = { "Era and Forever seed quest spawns from their own map ids; others keep the retail ones", function()
    for _, version in ipairs({ "Forever", "Vanilla" }) do
        local R = build({ client_version = version })
        assert_eq(R.Q.map_for_area(12), 1429, version .. ": Elwynn Forest")
        assert_eq(R.Q.map_for_area(40), 1436, version .. ": Westfall")
        assert_eq(R.Q.map_for_area(148), 1439, version .. ": Darkshore")
        assert_eq(R.Q.map_for_area(1519), 1453, version .. ": Stormwind City")
    end
    local M = build({ client_version = "Mop" })
    assert_eq(M.Q.map_for_area(12), 37, "Mists: the retail id")
end }

return T

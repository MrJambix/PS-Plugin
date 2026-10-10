-- Jambix AIO 1.89.0: routes (modules/routes.lua) -- the guide's next stops as
-- fainter pillars with a dashed line from each to the next, a pillar on the
-- nearest vendor or repairer when your bags are full or your gear worn, and a
-- tall one on your corpse while you are dead. Drawn through a recording draw
-- service, and through the real world layer over one; the ESP's town_npcs
-- accessors (esp/forever.lua, esp/classify.lua) against fake units.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
local durability = {}            -- equipment slot -> { current, max }
local function reset_core()
    _G.core = {
        time = function() return clock.s end,
        game_time = function() return math.floor(clock.s * 1000 + 0.5) end,
        inventory = { get_item_durability = function(slot) return durability[slot] or { current = 0, max = 0 } end },
    }
end
reset_core()

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function at(p, x, y, label)
    if not p or p.x ~= x or p.y ~= y then
        error(string.format("%s: expected (%s, %s), got %s", label, tostring(x), tostring(y),
            p and string.format("(%s, %s)", tostring(p.x), tostring(p.y)) or "nil"), 2)
    end
end

--- A RestedXP step's stop: the raw waypoint and its world place.
local function stop(x, y)
    return { raw = { map_id = 1429, x = x / 1000, y = y / 1000, title = "stop " .. x }, world = { x = x, y = y, z = 0 } }
end

--- A town npc as a sweep row and its object.
local function npc(guid, x, flags, o)
    o = o or {}
    local obj = { guid = guid, flags = flags, reads = 0 }
    obj.get_npc_flags = function(self)
        self.reads = self.reads + 1
        return self.flags
    end
    local row = { guid = guid, pos = { x = x, y = 0, z = 0 }, dist = o.dist or x, is_player = o.is_player or false,
        is_enemy = o.is_enemy or false, dead = o.dead or false }
    return obj, row
end

local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    local state = {
        me = { x = 0, y = 0, z = 0 }, rxp = o.rxp, free = o.free, dead = false, ghost = false,
        corpse = o.corpse, map = o.map or 0, town = o.town or {}, rows = {}, scans = 0, ground = 0,
    }
    local draw = {
        beacon_3d = rec("beacon_3d"), path_3d = rec("path_3d"), line_3d = rec("line_3d"),
        text_3d = rec("text_3d"), ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse"),
        unit_los = function(u) return not (o.behind_wall and o.behind_wall[u]) end,
        set_los_budget = function() end,
    }
    for _, k in ipairs(o.without or {}) do draw[k] = nil end
    local units = {
        player_position = function() return state.me end,
        snapshot = function(obj) return state.rows[obj] end,
        position = function(obj) local r = state.rows[obj] return r and r.pos end,
        units = function()
            local out = {}
            for i = 1, #state.town do out[i] = state.town[i].obj end
            return out
        end,
        combat_reach = function() return 1.5 end,
    }
    for i = 1, #state.town do state.rows[state.town[i].obj] = state.town[i].row end
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {
            LAYER = { WORLD = 100, OVERLAY = 300 },
            inventory = o.no_services and nil or { free_slots = function() return state.free end },
            world = not o.no_services and {
                corpse_position = function() return state.corpse end,
                instance_id = function() return state.map end,
            } or nil,
            player = not o.no_services and {
                is_dead = function() return state.dead end,
                is_ghost = function() return state.ghost end,
            } or nil,
        },
        units = units,
        draw = draw,
        -- routes.lua logs a part that raised (once) and carries on; here
        -- that fails the frame.
        log = { fmt = function(level, fmt, ...) state.logged = level .. ": " .. string.format(fmt, ...) end },
    }
    if not o.no_quests then
        P.quests = { rxp = state.rxp }
        if o.ground then
            P.quests.ground_path = function(a, b)
                state.ground = state.ground + 1
                return { a, { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = 7 }, b }
            end
        end
    end
    if o.esp ~= false then
        local function town_npcs(range)
            state.scans = state.scans + 1
            local out = {}
            for i = 1, #state.town do
                local t = state.town[i]
                if t.row.dist <= range then
                    out[#out + 1] = { obj = t.obj, guid = t.row.guid, d = t.row.dist, pos = t.row.pos, flags = t.obj.flags }
                end
            end
            return out
        end
        if o.esp == "classic" then
            P.esp = {}
            P.esp_classify = { town_npcs = town_npcs }
        else
            P.esp = { forever = { town_npcs = town_npcs } }
        end
    end
    local W
    if o.layer then
        package.loaded["jambix_aio/modules/worldlayer"] = nil
        W = require("jambix_aio/modules/worldlayer")(P)
        P.worldmarks = W
    end
    package.loaded["jambix_aio/modules/routes"] = nil
    local M = require("jambix_aio/modules/routes")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.1)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
        if W then W.flush() end
        if not o.allow_errors and (state.logged or M.stats().errors) then
            error("routes raised inside a frame: " .. tostring(state.logged), 2)
        end
    end
    return M, calls, state, frame, settings, P, W
end

--- The guide on its first stop of four, A (the gold pillar beacons.lua draws).
local function guide()
    local s = { stop(100, 0), stop(200, 0), stop(300, 0), stop(400, 0) }
    return { loaded = true, waypoint = s[1].raw, world_waypoint = s[1].world, step_waypoints = s }, s
end

local T = {}

-- --- the route ----------------------------------------------------------------------

T[#T + 1] = { "route: the next two stops as shorter pillars, the current one left to beacons.lua, a dashed line each", function()
    clock.s = 1000.0
    durability = {}
    local rxp, s = guide()
    local M, calls, _, frame = bundle({ rxp = rxp })
    frame(0)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 2, "two stops")
    at(b[1][1], 200, 0, "the stop after the current one")
    at(b[2][1], 300, 0, "and the one after that")
    assert_eq(b[1][3].module, "route", "module")
    assert_eq(b[1][3].prio, "info", "the next stop is information")
    assert_eq(b[2][3].prio, "decor", "the one after is decoration")
    assert(b[1][3].height < 18 and b[2][3].height <= b[1][3].height, "shorter than the guide's pillar (18), and shorter on")
    assert(b[1][2].a < 255, "fainter")
    local p = all(calls, "path_3d")
    assert_eq(#p, 2, "a line from each to the next")
    assert_eq(p[1][1][1], s[1].world, "the first from the current stop")
    assert_eq(p[1][1][#p[1][1]], s[2].world, "to the next")
    assert_eq(p[2][1][1], s[2].world, "then on")
    assert_eq(p[2][1][#p[2][1]], s[3].world, "to the one after")
    assert(p[1][3].dash and p[1][3].dash > 0 and p[1][3].gap > 0, "dashed")
    assert_eq(M.stats().route, 2, "stats")
    assert_eq(M.stats().lines, 2, "stats lines")
end }

T[#T + 1] = { "route: up to three stops, none at 0; round past the end of the step; no current stop, no first line", function()
    clock.s = 1000.0
    local rxp, s = guide()
    local _, calls, _, frame, settings = bundle({ rxp = rxp, settings = { routes_steps = 3 } })
    frame(0)
    assert_eq(#all(calls, "beacon_3d"), 3, "three")
    assert_eq(#all(calls, "path_3d"), 3, "three lines")
    settings.routes_steps = 0
    frame()
    assert_eq(#all(calls, "beacon_3d"), 0, "none at 0")
    assert_eq(#all(calls, "path_3d"), 0, "and no line")
    -- On the third stop: the fourth, then round to the first.
    settings.routes_steps = 2
    rxp.waypoint, rxp.world_waypoint = s[3].raw, s[3].world
    frame()
    local b = all(calls, "beacon_3d")
    at(b[1][1], 400, 0, "the fourth")
    at(b[2][1], 100, 0, "then round to the first")
    -- RestedXP pointing nowhere: the step's stops from the first, no line into the first.
    rxp.waypoint, rxp.world_waypoint = nil, nil
    frame()
    b = all(calls, "beacon_3d")
    at(b[1][1], 100, 0, "the first stop")
    at(b[2][1], 200, 0, "the second")
    assert_eq(#all(calls, "path_3d"), 1, "only the line between them")
end }

T[#T + 1] = { "route: a stop where you stand has no pillar, its line stays; a one-stop step has no route", function()
    clock.s = 1000.0
    local rxp = guide()
    local _, calls, state, frame = bundle({ rxp = rxp })
    state.me = { x = 203, y = 0, z = 0 }
    frame(0)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "only the far stop")
    at(b[1][1], 300, 0, "the far stop")
    assert_eq(#all(calls, "path_3d"), 2, "both lines")
    rxp.step_waypoints = { rxp.step_waypoints[1] }
    frame()
    assert_eq(#all(calls, "beacon_3d") + #all(calls, "path_3d"), 0, "nothing past the current stop")
end }

T[#T + 1] = { "route: the lines follow quests.lua's ground path, kept while their ends stay", function()
    clock.s = 1000.0
    local rxp, s = guide()
    local _, calls, state, frame = bundle({ rxp = rxp, ground = true })
    frame(0)
    local p = all(calls, "path_3d")
    assert_eq(#p[1][1], 3, "the ground path's points")
    assert_eq(p[1][1][2].z, 7, "following the ground")
    assert_eq(state.ground, 2, "one ground path a line")
    for _ = 1, 10 do frame(0.1) end
    assert_eq(state.ground, 2, "kept, not walked again every frame")
    -- RestedXP hands over new tables each second: same places, same points.
    for i = 1, #s do s[i].world = { x = s[i].world.x, y = s[i].world.y, z = 0 } end
    rxp.world_waypoint = s[1].world
    frame(0.1)
    assert_eq(state.ground, 2, "a new table at the same place is the same line")
    s[2].world = { x = 250, y = 0, z = 0 }
    frame(0.1)
    assert_eq(state.ground, 4, "a stop that moved: both its lines again")
    frame(2.1)
    assert_eq(state.ground, 6, "and again after a while, as the ground fills in")
end }

T[#T + 1] = { "route: switches, the guide not loaded, Minimal density and an older JCore", function()
    clock.s = 1000.0
    local rxp = guide()
    local _, calls, _, frame, settings = bundle({ rxp = rxp, settings = { routes_on = false } })
    frame(0)
    assert_eq(#calls, 0, "routes off: nothing")
    settings.routes_on = true
    rxp.loaded = false
    frame()
    assert_eq(#calls, 0, "RestedXP not loaded: its last stops are stale")
    rxp.loaded = true
    settings.world_density = 3
    frame()
    assert_eq(#all(calls, "beacon_3d"), 2, "Minimal: the pillars")
    assert_eq(#all(calls, "path_3d"), 0, "but not the decoration the layer cannot budget")
    settings.world_density, settings.world_on = 1, false
    frame()
    assert_eq(#all(calls, "path_3d"), 0, "world marks off: no line either")

    -- A JCore with no path_3d draws a plain line; with neither, pillars only;
    -- with no beacon_3d, nothing at all.
    local _, c2, _, f2 = bundle({ rxp = guide(), without = { "path_3d" } })
    f2(0)
    assert_eq(#all(c2, "line_3d"), 2, "plain lines")
    local _, c3, _, f3 = bundle({ rxp = guide(), without = { "path_3d", "line_3d" } })
    f3(0)
    assert_eq(#all(c3, "beacon_3d"), 2, "pillars without lines")
    local _, c4, _, f4 = bundle({ rxp = guide(), without = { "beacon_3d", "text_3d" }, free = 0, corpse = { x = 50, y = 0, z = 0 } })
    f4(0)
    assert_eq(#c4, 0, "no beacon_3d: nothing")
end }

-- --- services ---------------------------------------------------------------------------

local function town_of(list)
    local out = {}
    for i = 1, #list do
        local obj, row = list[i][1], list[i][2]
        out[i] = { obj = obj, row = row }
    end
    return out
end

T[#T + 1] = { "services: bags nearly full, the nearest merchant, labelled; enough room, nothing", function()
    clock.s = 1000.0
    durability = {}
    local vendor, vrow = npc("v", 30, 0x80)
    local smith, srow = npc("s", 50, 0x1080)
    local guard, grow = npc("g", 10, 0x1)
    local _, calls, state, frame, settings = bundle({ free = 3, town = town_of({ { vendor, vrow }, { smith, srow }, { guard, grow } }) })
    frame(0)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "one pillar")
    assert_eq(b[1][1], vrow.pos, "on the nearest merchant, not the guard")
    assert_eq(b[1][3].module, "services", "module")
    assert_eq(b[1][3].prio, "info", "information")
    assert_eq(b[1][3].unit, vendor, "under the npc, for the wall fade")
    local t = all(calls, "text_3d")
    assert_eq(#t, 1, "a label")
    assert_eq(t[1][2], "Sell  30y", "what for and how far")
    assert(t[1][1].z > vrow.pos.z, "over it")
    state.free = 5
    frame(1.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "five free: nothing")
    settings.routes_bag_free = 6
    frame(1.1)
    assert_eq(#all(calls, "beacon_3d"), 1, "the threshold is a setting")
    settings.routes_services = false
    frame(1.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "services off")
end }

T[#T + 1] = { "services: worn gear, the nearest repairer over a nearer merchant; both, the repairer says so", function()
    clock.s = 1000.0
    durability = { [5] = { current = 10, max = 100 }, [4] = { current = 0, max = 0 } }
    local vendor, vrow = npc("v", 30, 0x80)
    local smith, srow = npc("s", 50, 0x1080)
    local _, calls, state, frame, settings = bundle({ free = 10, town = town_of({ { vendor, vrow }, { smith, srow } }) })
    frame(0)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "one pillar")
    assert_eq(b[1][1], srow.pos, "on the repairer")
    assert_eq(all(calls, "text_3d")[1][2], "Repair  50y", "labelled")
    state.free = 2
    frame(1.1)
    assert_eq(all(calls, "text_3d")[1][2], "Repair, sell  50y", "both")
    -- 30%: over the default 25.
    state.free = 10
    durability[5] = { current = 30, max = 100 }
    frame(5.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "30% is fine at 25%")
    settings.routes_durability = 35
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 1, "the threshold is a setting")
    -- No repairer near: worn gear alone has nothing to point at.
    state.town = { state.town[1] }
    frame(1.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "a merchant does not repair")
end }

T[#T + 1] = { "services: none at the npc, none once it left, the ESP asked once a second; the Classic ESP's list", function()
    clock.s = 1000.0
    durability = {}
    local vendor, vrow = npc("v", 30, 0x80)
    local _, calls, state, frame = bundle({ free = 0, town = town_of({ { vendor, vrow } }) })
    frame(0)
    assert_eq(state.scans, 1, "looked")
    for _ = 1, 5 do frame(0.1) end
    assert_eq(state.scans, 1, "not every frame")
    frame(0.6)
    assert_eq(state.scans, 2, "again a second later")
    vrow.dist = 4
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "at the vendor: no pillar")
    vrow.dist = 30
    state.rows[vendor] = nil
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "out of the sweep: no pillar")

    local _, c2, s2, f2 = bundle({ free = 0, esp = "classic", town = town_of({ { vendor, vrow } }) })
    s2.rows[vendor] = vrow
    f2(0)
    assert_eq(#all(c2, "beacon_3d"), 1, "the Classic ESP's town")
    assert_eq(s2.scans, 1, "asked")
end }

-- --- your corpse --------------------------------------------------------------------------

T[#T + 1] = { "corpse: a tall warning pillar where the client says, no vendor while dead; alive again, gone", function()
    clock.s = 1000.0
    durability = {}
    local vendor, vrow = npc("v", 30, 0x80)
    local _, calls, state, frame = bundle({ free = 0, town = town_of({ { vendor, vrow } }) })
    frame(0)
    assert_eq(#all(calls, "beacon_3d"), 1, "alive: the vendor")
    state.ghost = true
    state.me = { x = 400, y = 0, z = 0 }
    state.corpse = { x = 100, y = 0, z = 5 }
    frame(0.1)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "one pillar")
    assert_eq(b[1][1], state.corpse, "on the corpse")
    assert_eq(b[1][3].prio, "warn", "a warning")
    assert_eq(b[1][3].module, "corpse", "module")
    assert(b[1][3].height >= 30, "tall")
    assert_eq(all(calls, "text_3d")[1][2], "Your corpse  300y", "labelled")
    state.me = { x = 102, y = 0, z = 5 }
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "on it: no pillar")
    state.ghost = false
    state.corpse = nil
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 1, "alive: the vendor again")
    assert_eq(all(calls, "beacon_3d")[1][3].module, "services", "and only it")
end }

T[#T + 1] = { "corpse: no answer from the client, where you were last alive; not on another map; switch", function()
    clock.s = 1000.0
    local _, calls, state, frame, settings = bundle({ map = 0 })
    state.me = { x = 60, y = 40, z = 3 }
    frame(0)
    assert_eq(#calls, 0, "alive: nothing")
    state.dead = true
    frame(0.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "dead where you fell: you are on it")
    state.dead, state.ghost = false, true
    state.me = { x = 300, y = 40, z = 3 }
    state.corpse = { x = 0, y = 0, z = 0 }
    frame(0.1)
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "the client's zero is no answer")
    at(b[1][1], 60, 40, "where you were last alive")
    state.map = 1
    frame(0.1)
    assert_eq(#calls, 0, "on another map: nothing")
    state.map = 0
    settings.routes_corpse = false
    frame(0.1)
    assert_eq(#calls, 0, "switch off")
end }

-- --- through the world layer ----------------------------------------------------------------

T[#T + 1] = { "the world layer: the corpse kept past the budget, the route's decoration first to go, the vendor fades behind a wall", function()
    clock.s = 1000.0
    durability = {}
    local rxp = guide()
    local _, calls, state, frame, settings, _, W = bundle({ rxp = rxp, layer = true, settings = { world_budget = 3 } })
    state.me = { x = 0, y = 50, z = 0 }
    frame(0)
    state.ghost, state.corpse = true, { x = 0, y = 500, z = 0 }
    frame(0.1)
    local st = W.stats()
    assert_eq(st.by.corpse, 1, "the corpse: a warning, never dropped")
    assert_eq(st.by.route, nil, "the route over the budget")
    assert_eq(st.dropped, 2, "both stops dropped")
    settings.world_budget = 6
    frame(0.1)
    st = W.stats()
    assert_eq(st.by.route, 1, "room for the next stop")
    assert_eq(st.dropped, 1, "the decoration goes first")
    assert_eq(#all(calls, "path_3d"), 2, "the lines pass straight through")

    local vendor, vrow = npc("v", 30, 0x80)
    local _, c2, _, f2 = bundle({ free = 0, layer = true, town = town_of({ { vendor, vrow } }), behind_wall = { [vendor] = true } })
    f2(0)
    local b = all(c2, "beacon_3d")
    assert_eq(#b, 1, "drawn at the flush")
    assert(b[1][2].a < 255 * 0.5, "behind a wall: faded")
    assert_eq(b[1][3].prio, nil, "the layer's options gone")
end }

T[#T + 1] = { "nothing to read: no guide, no ESP, no services -- nothing drawn, nothing raised", function()
    clock.s = 1000.0
    local M, calls, _, frame = bundle({ no_quests = true, esp = false, no_services = true })
    frame(0)
    frame(6)
    assert_eq(#calls, 0, "nothing")
    local _, c2, s2, f2 = bundle({ rxp = { loaded = true, step_waypoints = "junk" }, free = 0, esp = false })
    s2.corpse = "junk"
    f2(0)
    assert_eq(#c2, 0, "junk read as nothing")
    _G.core.inventory = nil
    local _, c3, _, f3 = bundle({ free = 10 })
    f3(10)
    assert_eq(#c3, 0, "no durability read: nothing")
    reset_core()
end }

T[#T + 1] = { "a part that raises is logged once and costs only itself", function()
    clock.s = 1000.0
    durability = {}
    local vendor, vrow = npc("v", 30, 0x80)
    local rxp = setmetatable({}, { __index = function() error("a guide that raises") end })
    local M, calls, state, frame = bundle({ rxp = rxp, free = 0, town = town_of({ { vendor, vrow } }), allow_errors = true })
    frame(0)
    assert(state.logged and state.logged:find("route", 1, true), "logged: " .. tostring(state.logged))
    assert_eq(#all(calls, "beacon_3d"), 1, "the vendor still drawn")
    state.logged = nil
    frame(0.1)
    assert_eq(state.logged, nil, "once")
    assert_eq(M.stats().errors, 2, "but counted")
end }

-- --- the ESP's town_npcs ----------------------------------------------------------------------

T[#T + 1] = { "esp/classify town_npcs: friendly living npcs in range with flags, each npc's flags read once", function()
    local handlers = {}
    local list, rows = {}, {}
    local function add(obj, row) list[#list + 1] = obj; rows[obj] = row end
    local v, vr = npc("v", 30, 0x1080); add(v, vr)
    local g, gr = npc("g", 20, 0); add(g, gr)
    local e, er = npc("e", 25, 0x80, { is_enemy = true }); add(e, er)
    local p, pr = npc("p", 15, 0x80, { is_player = true }); add(p, pr)
    local d, dr = npc("d", 12, 0x80, { dead = true }); add(d, dr)
    local f, fr = npc("f", 400, 0x80); add(f, fr)
    local P = {
        ctx = { on = function(name, fn) handlers[name] = fn end },
        cfg = require("jambix_aio/modules/config"),
        opt = function(_, fallback) return fallback end,
        units = { units = function() return list end, snapshot = function(o) return rows[o] end },
    }
    package.loaded["jambix_aio/modules/esp/classify"] = nil
    local K = require("jambix_aio/modules/esp/classify")(P)
    local out = K.town_npcs(150)
    assert_eq(#out, 1, "the vendor alone")
    assert_eq(out[1].obj, v, "it")
    assert_eq(out[1].flags, 0x1080, "its flags")
    assert_eq(out[1].pos, vr.pos, "where it stands")
    assert_eq(out[1].d, 30, "how far")
    K.town_npcs(150)
    assert_eq(v.reads, 1, "flags read once")
    assert_eq(g.reads, 1, "a guard's nothing read once too")
    assert_eq(e.reads + p.reads + d.reads + f.reads, 0, "enemies, players, the dead and the far never read")
    handlers["jcore.unit.removed"]("v")
    K.town_npcs(150)
    assert_eq(v.reads, 2, "read again once it left")
end }

T[#T + 1] = { "esp/forever town_npcs: the service and the creature cache's title, off the ESP's own facts", function()
    clock.s = 1000.0
    local list, rows = {}, {}
    local function add(obj, row) list[#list + 1] = obj; rows[obj] = row end
    local function unit(obj, npc_id)
        obj.get_npc_id = function() return npc_id end
        obj.get_level = function() return 30 end
        obj.get_max_health = function() return 100 end
        obj.get_bounding_radius = function() return 1 end
        obj.get_creature_type = function() return 7 end
        obj.is_pet = function() return false end
        return obj
    end
    local smith, sr = npc("s", 40, 0x1080); add(unit(smith, 11), sr)
    local guard, gr = npc("g", 20, 0x1); add(unit(guard, 12), gr)
    local mob, mr = npc("m", 10, 0x80, { is_enemy = true }); add(unit(mob, 13), mr)
    local me = { guid = "me", is_enemy_with = function() return false end }
    local P = {
        cfg = require("jambix_aio/modules/config"),
        log = { fmt = function() end },
        ctx = {
            on = function() end, emit = function() end,
            creatures = { info = function(id) return id == 11 and { title = "Armorer" } or nil end },
            LAYER = { WORLD = 100, OVERLAY = 300 },
        },
        units = {
            units = function() return list end, snapshot = function(o) return rows[o] end,
            player = function() return me end, guid = function(o) return o and o.guid end,
            objects = function() return {} end, player_position = function() return { x = 0, y = 0, z = 0 } end,
        },
        draw = {},
        opt = function(_, fallback) return fallback end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
    }
    package.loaded["jambix_aio/modules/esp/forever"] = nil
    local F = require("jambix_aio/modules/esp/forever")(P)
    local out = F.town_npcs(150)
    assert_eq(#out, 2, "the smith and the guard (flags), not the mob")
    local s = out[1].obj == smith and out[1] or out[2]
    assert_eq(s.obj, smith, "the smith")
    assert_eq(s.service, "service.repair", "its service")
    assert_eq(s.title, "Armorer", "its title")
    assert_eq(s.flags, 0x1080, "its flags")
    assert_eq(s.pos, sr.pos, "where it stands")
    assert_eq(#F.town_npcs(30), 1, "the range")
    assert_eq(smith.reads, 1, "flags kept with the ESP's facts")
end }

return T

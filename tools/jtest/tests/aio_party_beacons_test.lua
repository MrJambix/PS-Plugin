-- Jambix AIO 1.87.0: the group on the ground (modules/party.lua) and the
-- beacons (modules/beacons.lua), through recording draw services.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end, game_time = function() return math.floor(clock.s * 1000) end }

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

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function unit(guid, x, hp)
    return { guid = guid, pos = { x = x or 0, y = 0, z = 0 }, hp = hp or 1 }
end

-- --- party ---------------------------------------------------------------------------

local function party(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not o.curtains_default then
        for _, id in ipairs({ "party_heal_curtain", "party_loose" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local state = { members = o.members, tanks = o.tanks or {}, healers = o.healers or {}, rows = o.rows or {} }
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {
            LAYER = { WORLD = 100 },
            group = {
                objects = function() return state.members end,
                tanks = function() return state.tanks end,
                healers = function() return state.healers end,
                is_tank = function(u) for _, t in ipairs(state.tanks) do if t == u then return true end end return false end,
            },
            enemies = { all = function() return state.rows end },
        },
        units = {
            player = function() return state.members[1] end,
            guid = function(u) return u and u.guid end,
            health_fraction = function(u) return u.hp end,
            position = function(u) return u and u.pos end,
            combat_reach = function() return 1.5 end,
        },
        draw = { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") },
        assist = o.assist,
    }
    package.loaded["jambix_aio/modules/party"] = nil
    local M = require("jambix_aio/modules/party")(P)
    local function frame()
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
    end
    return M, calls, state, frame, settings
end

local T = {}

T[#T + 1] = { "party: a ring under each hurt member filling red, not you; the one under half gets a curtain; a pulse under a third, once", function()
    local me, a, b, c = unit("me", 0, 0.4), unit("a", 5, 0.8), unit("b", 10, 0.45), unit("c", 15, 1)
    local M, calls, _, frame = party({ members = { me, a, b, c } })
    frame()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "a and b, not you and not the healthy one")
    local by = {}
    for _, r in ipairs(rings) do by[r[1].x] = r end
    near(by[5][3], 0.2, "a: a fifth missing"); near(by[10][3], 0.55, "b: over half missing")
    assert_eq(by[5][5].to.r, 240, "turning red")
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "one curtain")
    assert_eq(cs[1][1], b.pos, "on b, the one under half")
    assert_eq(#all(calls, "pulse"), 0, "nobody under a third yet")
    b.hp = 0.2
    frame()
    assert_eq(#all(calls, "pulse"), 1, "b dropped under a third")
    frame()
    assert_eq(#all(calls, "pulse"), 0, "once")
    b.hp = 0.9
    frame()
    b.hp = 0.2
    frame()
    assert_eq(#all(calls, "pulse"), 1, "again after recovering")
end }

T[#T + 1] = { "party: nothing solo, and the switches", function()
    local me = unit("me", 0, 0.3)
    local M, calls, state, frame, settings = party({ members = { me } })
    frame()
    assert_eq(#calls, 0, "solo: nothing")
    state.members = { me, unit("a", 5, 0.3) }
    settings.party_rings = false
    frame()
    assert_eq(#all(calls, "ring_3d"), 0, "rings off"); assert_eq(#all(calls, "curtain_3d"), 1, "the curtain")
    settings.party_heal_curtain = false
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "curtain off")
    settings.party_on = false
    frame()
    assert_eq(#calls, 0, "all off")
end }

T[#T + 1] = { "loose mobs: on a member who is not the tank, an orange curtain and a pulse the first time", function()
    local me, tank, dps = unit("me", 0), unit("tank", 5), unit("dps", 10)
    local mob1, mob2 = unit("m1", 12), unit("m2", 6)
    local rows = {
        { guid = "m1", obj = mob1, in_combat = true, target_guid = "dps" },
        { guid = "m2", obj = mob2, in_combat = true, target_guid = "tank" },
    }
    local M, calls, _, frame = party({ members = { me, tank, dps }, tanks = { tank }, rows = rows })
    frame()
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "only the mob on the dps")
    assert_eq(cs[1][1], mob1.pos, "on m1")
    assert_eq(cs[1][3].g, 140, "orange")
    assert_eq(#all(calls, "pulse"), 1, "a pulse the first time")
    frame()
    assert_eq(#all(calls, "pulse"), 0, "not every frame")
    rows[1].target_guid = "tank"
    frame()
    rows[1].target_guid = "dps"
    frame()
    assert_eq(#all(calls, "pulse"), 1, "loose again: news again")
end }

T[#T + 1] = { "loose mobs with no tank known: only what is on a healer -- unless you are the tank", function()
    local me, heal, dps = unit("me", 0), unit("heal", 5), unit("dps", 10)
    local rows = {
        { guid = "m1", obj = unit("m1", 12), in_combat = true, target_guid = "dps" },
        { guid = "m2", obj = unit("m2", 14), in_combat = true, target_guid = "heal" },
    }
    local M, calls, _, frame = party({ members = { me, heal, dps }, healers = { heal }, rows = rows })
    frame()
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "only the one on the healer")
    assert_eq(cs[1][1].x, 14, "m2")
    local M2, calls2, _, frame2 = party({ members = { me, heal, dps }, tanks = { me }, rows = rows })
    frame2()
    assert_eq(#all(calls2, "curtain_3d"), 2, "you are the tank: everything on anyone else")
    local M3, calls3, _, frame3 = party({ members = { me, heal, dps }, rows = rows, assist = { state = { tank_guid = "heal" } } })
    frame3()
    assert_eq(#all(calls3, "curtain_3d"), 1, "Assist the tank's pick counts as the tank: the mob on the dps")
end }

-- --- beacons ---------------------------------------------------------------------------

local function beacons(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 }, geometry = { vec = function(x, y, z) return { x = x, y = y, z = z, v = true } end } },
        units = {
            player_position = function() return { x = 0, y = 0, z = 0 } end,
            position = function(u) return u and u.pos end,
        },
        draw = o.old_jcore and { ring_3d = rec("ring_3d") } or { beacon_3d = rec("beacon_3d") },
        quests = o.quests,
        esp = o.esp,
    }
    package.loaded["jambix_aio/modules/beacons"] = nil
    local M = require("jambix_aio/modules/beacons")(P)
    local function frame()
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
    end
    return M, calls, frame, settings
end

T[#T + 1] = { "beacons: the guide's waypoint in gold, not when you are there", function()
    local rxp = { world_waypoint = { x = 120, y = 40, z = 12 } }
    local M, calls, frame = beacons({ quests = { rxp = rxp } })
    frame()
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "one beacon")
    assert_eq(b[1][1].x, 120, "at the waypoint"); assert(b[1][1].v, "a real vec3 from geometry")
    assert_eq(b[1][2].r, 245, "gold")
    rxp.world_waypoint = { x = 3, y = 2, z = 0 }
    frame()
    assert_eq(#all(calls, "beacon_3d"), 0, "you are there")
end }

T[#T + 1] = { "beacons: the nearest three quest areas, green to turn in, on the ground's height", function()
    local list = {}
    for i = 1, 5 do
        list[i] = { x = 20 * i, y = 0, z = 50, quest = { complete = i == 2 }, poi = { ground = 7 } }
    end
    list[6] = { x = 900, y = 0, z = 0, quest = {} }
    local esp = { forever = { quests = { locations = function() return list end } } }
    local M, calls, frame = beacons({ esp = esp })
    frame()
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 3, "the nearest three")
    assert_eq(b[1][1].x, 20, "nearest first")
    assert_eq(b[2][2].g, 220, "the complete one green"); assert_eq(b[2][2].r, 110, "green")
    assert_eq(b[1][1].z, 7, "on the ground the map gave")
end }

T[#T + 1] = { "beacons: Forever's node marks or the Classic ESP's nodes, by kind, the nearest few in range", function()
    local marks = {
        { obj = unit("h", 30), cat = "herb", d = 30, pos = { x = 30, y = 0, z = 0 } },
        { obj = unit("o", 40), cat = "ore", d = 40, pos = { x = 40, y = 0, z = 0 } },
        { obj = unit("x", 50), cat = "object", d = 50, pos = { x = 50, y = 0, z = 0 } },
        { obj = unit("far", 150), cat = "herb", d = 150, pos = { x = 150, y = 0, z = 0 } },
    }
    local M, calls, frame, settings = beacons({ esp = { forever = { node_marks = function() return marks end } } })
    frame()
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 2, "a herb and an ore; not a plain object, not out of range")
    assert_eq(b[1][2].g, 210, "herb green"); assert_eq(b[2][2].g, 150, "ore orange")
    local classic = { nodes = function() return { { obj = unit("c", 20), kind = "container", distance = 20 } } end }
    local M2, calls2, frame2 = beacons({ esp = classic })
    frame2()
    assert_eq(#all(calls2, "beacon_3d"), 1, "the Classic ESP's chest")
    settings.beacon_nodes = false
    frame()
    assert_eq(#all(calls, "beacon_3d"), 0, "nodes off")
end }

T[#T + 1] = { "beacons: no pillar on a node your skill is short of -- Forever's marks and the Classic nodes (1.88.0)", function()
    local marks = {
        { obj = unit("h", 30), cat = "herb", d = 30, pos = { x = 30, y = 0, z = 0 }, name = "Peacebloom" },
        { obj = unit("o", 40), cat = "ore", d = 40, pos = { x = 40, y = 0, z = 0 }, name = "Mithril Deposit", requires = 175 },
    }
    local M, calls, frame = beacons({ esp = { forever = { node_marks = function() return marks end } } })
    frame()
    local b = all(calls, "beacon_3d")
    assert_eq(#b, 1, "the herb only")
    assert_eq(b[1][1].x, 30, "at the herb")
    assert_eq(M.stats().nodes, 1, "one node beacon counted")

    local classic = { nodes = function()
        return {
            { obj = unit("c", 20), kind = "ore", name = "Copper Vein", distance = 20 },
            { obj = unit("m", 25), kind = "ore", name = "Mithril Deposit", distance = 25, requires = 175 },
        }
    end }
    local M2, calls2, frame2 = beacons({ esp = classic })
    frame2()
    local b2 = all(calls2, "beacon_3d")
    assert_eq(#b2, 1, "the Classic ESP's copper only")
    assert_eq(b2[1][1].x, 20, "at the copper vein")
end }

T[#T + 1] = { "beacons: off, and an older JCore without beacon_3d draws nothing", function()
    local M, calls, frame = beacons({ quests = { rxp = { world_waypoint = { x = 100, y = 0, z = 0 } } }, settings = { beacons_on = false } })
    frame()
    assert_eq(#calls, 0, "off")
    local M2, calls2, frame2 = beacons({ quests = { rxp = { world_waypoint = { x = 100, y = 0, z = 0 } } }, old_jcore = true })
    frame2()
    assert_eq(#calls2, 0, "older JCore")
end }

return T

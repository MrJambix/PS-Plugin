-- Jambix AIO 1.89.0: tracks (modules/tracks.lua).
--
-- Missiles in flight at you, your group or from a hostile near you: a line to
-- where each lands and a ring there filling as it flies (none where a
-- telegraph already paints it); a faint wedge the way each hostile mob not yet
-- fighting faces, as long as its aggro radius; the route a walking mob took,
-- with an arrow the way it goes. Drawn through a recording draw service, and
-- once through the real world layer.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end, game_time = function() return math.floor(clock.s * 1000 + 0.5) end }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, label, eps)
    if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-3) then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function V(x, y, z) return { x = x, y = y, z = z or 0 } end

local function unit(guid, x, y, o)
    o = o or {}
    local u = { guid = guid, pos = V(x or 0, y or 0, 0), level = o.level or 20, hostile = o.hostile ~= false,
        dir = o.dir, rot = o.rot, reach = o.reach, rank = o.rank, reads = { dir = 0, rot = 0 } }
    u.get_level = function(self) return self.level end
    u.get_guid = function(self) return self.guid end
    u.get_direction = function(self) self.reads.dir = self.reads.dir + 1 return self.dir end
    u.get_rotation = function(self) self.reads.rot = self.reads.rot + 1 return self.rot end
    u.is_enemy_with = function(_, other) return other.hostile == true end
    return u
end

--- A fresh world: you at the origin, and whatever the test puts in it.
local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    local me = unit("me", 0, 0)
    me.hostile = false
    local world = {
        me = me, rows = {}, missiles = {}, teles = {}, group = { me }, snaps = {},
    }
    local draw = o.draw
    if draw == nil then
        draw = { ring_3d = rec("ring_3d"), line_3d = rec("line_3d"), polygon_3d = rec("polygon_3d"),
            path_3d = rec("path_3d"), cone_3d = rec("cone_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") }
    end
    local ctx = { LAYER = { WORLD = 100 }, player = { level = function() return o.my_level or 20 end } }
    if o.services ~= false then
        ctx.enemies = { all = function() return world.rows end }
        ctx.missiles = { all = function() return world.missiles end }
        ctx.telegraphs = { active = function() return world.teles end }
        ctx.group = { objects = function() return world.group end }
    end
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = ctx,
        units = {
            player = function() return me end,
            position = function(u) return u.pos end,
            guid = function(u) return u.guid end,
            snapshot = function(u) return world.snaps[u] end,
            combat_reach = function(u) return u.reach or 1.5 end,
            classification = function(u) return u.rank or 0 end,
        },
        draw = draw,
        pull = o.pull,
    }
    if o.telegraphs ~= false then P.telegraphs = {} end
    if o.layer then
        package.loaded["jambix_aio/modules/worldlayer"] = nil
        P.worldmarks = require("jambix_aio/modules/worldlayer")(P)
    end
    package.loaded["jambix_aio/modules/tracks"] = nil
    local M = require("jambix_aio/modules/tracks")(P)
    return M, calls, world, settings, P
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end
local function clear(calls) for i = #calls, 1, -1 do calls[i] = nil end end

--- A hostile mob that can fire, in the sweep.
local function caster(world, guid, x, y)
    local c = unit(guid, x, y)
    world.snaps[c] = { guid = guid, is_enemy = true }
    return c
end

--- An enemies-service row for a unit.
local function row(u, o)
    o = o or {}
    local d = math.sqrt(u.pos.x ^ 2 + u.pos.y ^ 2)
    return { guid = u.guid, obj = u, dist = d, x = u.pos.x, y = u.pos.y, z = u.pos.z, in_combat = o.in_combat,
        engaged = o.engaged, moving = o.moving, trail_t = {}, trail_x = {}, trail_y = {}, trail_d = {},
        trail_n = 0, trail_head = 0 }
end

local function dist3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end

local T = {}

-- --- missiles -----------------------------------------------------------------------

T[#T + 1] = { "a hostile missile at you: a line to you, a warn ring under you filling as it flies", function()
    local M, calls, world = bundle()
    local a = caster(world, "A", 20, 0)
    local m = { caster = a, target = world.me, spell_id = 133, speed = 20,
        source_position = V(20, 0, 2), current_position = V(10, 0, 2), impact_position = V(0.3, 0, 0) }
    world.missiles = { m }
    M.render()
    local lines = all(calls, "line_3d")
    assert_eq(#lines, 1, "one line")
    assert_eq(lines[1][1], m.current_position, "from where it is")
    assert_eq(lines[1][2], world.me.pos, "to you, followed")
    assert_eq(lines[1][4].thickness, 2.0, "heavier when it is yours")
    assert_eq(lines[1][4].droppable, false, "and never dropped")
    assert_eq(lines[1][3].r, 255, "red-orange")
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "one ring")
    assert_eq(rings[1][1], world.me.pos, "under you")
    near(rings[1][2], 1.8 + 1.4 + 0.25, "outside your own rings (edge + 1.4 + the band)")
    local done, left = dist3(m.source_position, m.current_position), dist3(m.current_position, world.me.pos)
    near(rings[1][3], done / (done + left), "the flight behind it")
    local o = rings[1][5]
    assert_eq(o.prio, "warn", "a warning"); assert_eq(o.module, "missiles", "named")
    assert_eq(o.unit, nil, "never under yourself")
    assert_eq(rings[1][4].r, 255, "warn colour"); assert_eq(o.to.g, 45, "turning red")
    assert_eq(M.stats().missiles, 1, "counted"); assert_eq(M.stats().rings, 1, "ring counted")
end }

T[#T + 1] = { "at a party member: an info ring under them, the second stepped outward; on the ground at your feet: warn first", function()
    local M, calls, world = bundle()
    local mate = unit("mate", 5, 5)
    mate.reach = 1.0
    world.group = { world.me, mate }
    local a, b = caster(world, "A", 25, 5), caster(world, "B", 25, 10)
    world.missiles = {
        { caster = a, target = mate, spell_id = 1, speed = 20, source_position = V(25, 5, 0),
            current_position = V(15, 5, 0), impact_position = V(5, 5, 0) },
        { caster = b, target = mate, spell_id = 2, speed = 20, source_position = V(25, 10, 0),
            current_position = V(20, 10, 0), impact_position = V(5, 5, 0) },
        { caster = a, spell_id = 3, speed = 10, source_position = V(25, 5, 0),
            current_position = V(10, 2, 0), impact_position = V(1, 1, 0) },
    }
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 3, "three rings")
    assert_eq(rings[1][5].prio, "warn", "the one at your feet first")
    assert_eq(rings[1][1], world.missiles[3].impact_position, "on the ground where it lands")
    near(rings[1][2], 2.0, "a 2 yd ring")
    assert_eq(rings[1][5].unit, nil, "no unit on the ground")
    assert_eq(rings[2][5].prio, "info", "a party member's is information")
    assert_eq(rings[2][1], mate.pos, "under the member")
    assert_eq(rings[2][5].unit, mate, "the unit, for the wall fade")
    near(rings[2][2], 1.3 + 1.4 + 0.25, "outside their rings")
    near(rings[3][2], 1.3 + 1.4 + 0.35 + 0.25, "the second steps out")
    assert_eq(rings[2][4].g, 205, "amber")
    assert_eq(#all(calls, "line_3d"), 3, "a line each")
end }

T[#T + 1] = { "which missiles: not yours, not a friend's, not a far hostile's, an unknown caster's only on your group", function()
    local M, calls, world, settings = bundle()
    local mate = unit("mate", 5, 5)
    world.group = { world.me, mate }
    local friend = unit("friend", 3, 3)
    world.snaps[friend] = { guid = "friend", is_ally = true }
    local far = caster(world, "far", 70, 0)
    local nearby = caster(world, "nearby", 32, 0)
    local npc = unit("npc", 36, 0)
    local stranger = unit("stranger", 50, 50)  -- not in the sweep
    world.missiles = {
        { caster = world.me, target = far, spell_id = 10, current_position = V(30, 0, 0), impact_position = V(70, 0, 0) },
        { caster = friend, target = world.me, spell_id = 11, current_position = V(2, 2, 0), impact_position = V(0, 0, 0) },
        { caster = far, target = npc, spell_id = 12, current_position = V(60, 0, 0), impact_position = V(55, 0, 0) },
        { caster = nearby, target = npc, spell_id = 13, current_position = V(33, 0, 0), impact_position = V(36, 0, 0) },
        { caster = stranger, spell_id = 14, current_position = V(10, 10, 0), impact_position = V(5.5, 5.5, 0) },
        { caster = stranger, spell_id = 15, current_position = V(30, 10, 0), impact_position = V(25, 0, 0) },
    }
    M.render()
    local lines = all(calls, "line_3d")
    assert_eq(#lines, 2, "the near hostile's and the unknown one on the group")
    local spells = {}
    for _, r in ipairs(all(calls, "ring_3d")) do spells[#spells + 1] = r end
    assert_eq(#spells, 2, "two rings")
    local under_npc = spells[1][1] == npc.pos and spells[1] or spells[2]
    assert_eq(under_npc[5].unit, npc, "a hostile's at someone near: under them")
    assert_eq(under_npc[5].prio, "info", "information")
    settings.tracks_range = 20
    clear(calls)
    M.render()
    assert_eq(#all(calls, "line_3d"), 1, "range 20: only the one on the group")
end }

T[#T + 1] = { "a missile a telegraph paints keeps its line and gets no ring; where the telegraphs would not draw it, the ring", function()
    local M, calls, world, settings = bundle()
    local a = caster(world, "A", 20, 0)
    local m = { caster = a, spell_id = 999, source_position = V(20, 0, 0), current_position = V(10, 0, 0),
        impact_position = V(0, 0, 0) }
    world.missiles = { m }
    world.teles = { { phase = "missile", spell_id = 999, source_guid = "A", x = 0.5, y = 0, radius = 5, placed = true,
        dist = 0.5, level = 1 } }
    M.render()
    assert_eq(#all(calls, "line_3d"), 1, "the line")
    assert_eq(#all(calls, "ring_3d"), 0, "no ring: the telegraph has it")
    assert_eq(M.stats().covered, 1, "counted as covered")

    local function rings_with(change)
        change()
        clear(calls)
        M.render()
        return #all(calls, "ring_3d")
    end
    assert_eq(rings_with(function() m.spell_id = 1000 end), 1, "another spell: ring")
    assert_eq(rings_with(function() m.spell_id = 999; world.teles[1].source_guid = "B" end), 1, "another caster: ring")
    assert_eq(rings_with(function() world.teles[1].source_guid = nil end), 0, "a telegraph with no caster known still covers")
    assert_eq(rings_with(function() world.teles[1].x = 9 end), 1, "landing outside its circle: ring")
    assert_eq(rings_with(function() world.teles[1].x = 0.5; world.teles[1].phase = "cast" end), 1, "not a missile row: ring")
    assert_eq(rings_with(function() world.teles[1].phase = "missile"; settings.tele_missiles = false end), 1,
        "telegraphs' missiles off: ring")
    assert_eq(rings_with(function() settings.tele_missiles = nil; settings.tele_on = false end), 1, "telegraphs off: ring")
    assert_eq(rings_with(function() settings.tele_on = nil; settings.enabled = false end), 1, "the ESP off: ring")
    assert_eq(rings_with(function() settings.enabled = nil; settings.tele_who = 3 end), 1,
        "boss-mod spells only, and this is not one: ring")
    assert_eq(rings_with(function() world.teles[1].level = 2 end), 0, "a boss-mod spell: covered")
    assert_eq(rings_with(function() settings.tele_who = 2; world.teles[1].level = 1; a.rank = 1 end), 1,
        "elites shown, no source to ask its rank: the telegraphs leave it out, ring")
    assert_eq(rings_with(function() world.teles[1].source = a end), 0, "an elite's, its rank read off the source: covered")
    assert_eq(rings_with(function() a.rank = 0 end), 1, "elites shown, a normal mob's: ring")
    local M2, calls2, world2 = bundle({ telegraphs = false })
    local a2 = caster(world2, "A", 20, 0)
    world2.missiles = { { caster = a2, spell_id = 999, source_position = V(20, 0, 0), current_position = V(10, 0, 0),
        impact_position = V(0, 0, 0) } }
    world2.teles = world.teles
    M2.render()
    assert_eq(#all(calls2, "ring_3d"), 1, "no telegraphs module: ring")
end }

T[#T + 1] = { "progress with no source_position: from how far it had to go when first seen", function()
    local M, calls, world = bundle()
    local a = caster(world, "A", 20, 0)
    local m = { caster = a, spell_id = 7, current_position = V(10, 0, 0), impact_position = V(0, 0, 0) }
    world.missiles = { m }
    M.render()
    near(all(calls, "ring_3d")[1][3], 0, "just seen: empty")
    m.current_position = V(5, 0, 0)
    clear(calls)
    M.render()
    near(all(calls, "ring_3d")[1][3], 0.5, "half way")
    m.current_position = V(0, 0, 0)
    clear(calls)
    M.render()
    near(all(calls, "ring_3d")[1][3], 1, "landed: full")
end }

T[#T + 1] = { "at most twelve missiles, what lands on you never left out", function()
    local M, calls, world = bundle()
    local a = caster(world, "A", 30, 0)
    for i = 1, 14 do
        world.missiles[i] = { caster = a, spell_id = i, source_position = V(30, 0, 0), current_position = V(20, i, 0),
            impact_position = V(15, i, 0) }
    end
    world.missiles[15] = { caster = a, target = world.me, spell_id = 99, source_position = V(30, 0, 0),
        current_position = V(20, 0, 0), impact_position = V(0, 0, 0) }
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 12, "twelve")
    assert_eq(rings[1][5].prio, "warn", "the one on you first")
end }

-- --- facing ---------------------------------------------------------------------------

T[#T + 1] = { "the nearest eight hostile mobs not yet fighting: a wedge the way each faces, as long as its aggro radius", function()
    local M, calls, world, settings = bundle({ settings = { tracks_patrols = false } })
    local rows = {}
    local busy = unit("busy", 3, 0, { dir = V(0, 1, 0) })
    local engaged = unit("engaged", 3.5, 0, { dir = V(0, 1, 0) })
    local neutral = unit("neutral", 4, 0, { dir = V(0, 1, 0), hostile = false })
    rows[1] = row(busy, { in_combat = true })
    rows[2] = row(engaged, { engaged = true })
    rows[3] = row(neutral)
    for i = 1, 10 do
        rows[#rows + 1] = row(unit("m" .. i, 4 + i, 0, { dir = V(0, 1, 0), level = 22 }))
    end
    world.rows = rows
    M.render()
    local fans = all(calls, "polygon_3d")
    assert_eq(#fans, 8, "eight wedges")
    assert_eq(#all(calls, "path_3d"), 8, "and their edges")
    local fan = fans[1][1]
    assert_eq(fans[1][3].filled, true, "filled")
    assert_eq(fans[1][2].a, 24, "faint")
    near(fan[1].x, 5, "from the nearest the others leave: m1"); near(fan[1].z, 0.1, "just off the ground")
    assert_eq(#fan, 10, "apex and nine along the arc")
    near(fan[6].x, 5, "its middle straight ahead (north)"); near(fan[6].y, 22, "22 yd: two levels over yours")
    near(fan[2].x, 5 + 22 * math.cos(math.pi / 4), "45 degrees either side")
    near(fan[2].y, 22 * math.sin(math.pi / 4), "from the right edge round")
    assert_eq(M.stats().facing, 8, "counted")
    settings.tracks_range = 8
    clear(calls)
    M.render()
    assert_eq(#all(calls, "polygon_3d"), 4, "range 8: m1 to m4")
end }

T[#T + 1] = { "the wedge's length is Pull safety's own rule when it is loaded", function()
    local asked
    local pull = { aggro_radius = function(level, mine, base)
        asked = { level, mine, base }
        return 17
    end }
    local M, calls, world = bundle({ pull = pull, settings = { tracks_patrols = false, pull_base = 18 } })
    world.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0), level = 25 })) }
    M.render()
    assert_eq(asked[1], 25, "its level"); assert_eq(asked[2], 20, "yours"); assert_eq(asked[3], 18, "the base setting")
    near(all(calls, "polygon_3d")[1][1][6].x, 6 + 17, "17 yd east")
end }

T[#T + 1] = { "facing: get_direction, else get_rotation, else a walker's heading; five reads a second; no rebuild while it stands", function()
    local M, calls, world = bundle({ settings = { tracks_patrols = false } })
    local a = unit("a", 5, 0, { dir = V(0, 1, 0) })
    local b = unit("b", 6, 0, { rot = math.pi })
    local c = unit("c", 7, 0, { dir = V(0, 0, 0), rot = 0 })
    world.rows = { row(a), row(b), row(c) }
    M.render()
    local fans = all(calls, "polygon_3d")
    assert_eq(#fans, 2, "a and b; c answered nothing")
    near(fans[2][1][6].x, 6 - 20, "b faces west, off get_rotation")
    assert_eq(M.stats().unread, 1, "c unread")
    assert_eq(a.reads.rot, 0, "rotation not asked when the direction answered")
    local first = fans[1][1]
    for _ = 1, 5 do M.render() end
    assert_eq(a.reads.dir, 1, "the same instant: read once")
    clock.s = clock.s + 0.2
    clear(calls)
    M.render()
    assert_eq(a.reads.dir, 2, "a fifth of a second later: again")
    assert_eq(all(calls, "polygon_3d")[1][1], first, "standing still, facing the same: the same wedge")
    a.dir = V(1, 0, 0)
    clock.s = clock.s + 0.2
    clear(calls)
    M.render()
    assert(all(calls, "polygon_3d")[1][1] ~= first, "turned: worked out again")
    -- c walks: it faces the way it goes.
    local rc = world.rows[3]
    rc.moving = true
    rc.trail_n, rc.trail_head = 2, 2
    rc.trail_x, rc.trail_y = { 7, 7 }, { -2, 0 }
    clock.s = clock.s + 0.2
    clear(calls)
    M.render()
    local fans3 = all(calls, "polygon_3d")
    assert_eq(#fans3, 3, "c now too")
    near(fans3[3][1][6].y, 20, "north, the way it walks")
end }

-- --- patrols --------------------------------------------------------------------------

--- Walks a row east a yard a frame, a quarter second apart.
local function walk(M, r, steps)
    for _ = 1, steps do
        clock.s = clock.s + 0.25
        r.obj.pos = V(r.obj.pos.x + 1, r.obj.pos.y, 0)
        r.x, r.y = r.obj.pos.x, r.obj.pos.y
        r.dist = math.sqrt(r.x ^ 2 + r.y ^ 2)
        M.render()
    end
end

T[#T + 1] = { "a walking mob: its route, older half faint, and an arrow ahead the way it goes", function()
    local M, calls, world = bundle({ settings = { tracks_facing = false } })
    local mob = unit("walker", 10, 5)
    local r = row(mob, { moving = true })
    world.rows = { r }
    M.render()
    walk(M, r, 2)
    assert_eq(#all(calls, "path_3d"), 0, "two yards: not yet a route")
    walk(M, r, 6)
    clear(calls)
    M.render()
    local paths = all(calls, "path_3d")
    assert_eq(#paths, 3, "older half, newer half, arrow")
    assert_eq(paths[1][2].a, 45, "the older half faint")
    assert_eq(paths[2][2].a, 115, "the newer brighter")
    near(paths[1][1][1].x, 10, "from where it started")
    assert_eq(paths[2][1][#paths[2][1]], mob.pos, "to where it stands now")
    local arrow = paths[3][1]
    assert_eq(#arrow, 3, "a chevron")
    near(arrow[2].x, mob.pos.x + 1.8 + 1.2, "its tip ahead of the mob, east"); near(arrow[2].y, 5, "straight ahead")
    assert(arrow[1].x < arrow[2].x and arrow[3].x < arrow[2].x, "pointing east")
    assert_eq(M.stats().patrols, 1, "counted")
    -- It stops: the route stays a while, then goes.
    clock.s = clock.s + 5
    clear(calls)
    M.render()
    assert(#all(calls, "path_3d") >= 2, "paused 5 s: still there")
    clock.s = clock.s + 2
    clear(calls)
    M.render()
    assert_eq(#all(calls, "path_3d"), 0, "7 s: gone")
end }

T[#T + 1] = { "a fight is not a patrol: the route is dropped and starts again after", function()
    local M, calls, world = bundle({ settings = { tracks_facing = false } })
    local mob = unit("walker", 10, 5)
    local r = row(mob, { moving = true })
    world.rows = { r }
    M.render()
    walk(M, r, 8)
    assert_eq(M.stats().patrols, 1, "a route")
    r.in_combat = true
    clear(calls)
    M.render()
    assert_eq(#all(calls, "path_3d"), 0, "in combat: none")
    r.in_combat = false
    walk(M, r, 2)
    assert_eq(M.stats().patrols, 0, "two yards since: none yet")
    walk(M, r, 4)
    assert_eq(M.stats().patrols, 1, "walked on: again")
end }

T[#T + 1] = { "a route starts from the enemies' own trail: a ring, the oldest just after the head", function()
    local M, calls, world = bundle({ settings = { tracks_facing = false } })
    local mob = unit("walker", 10.5, 0)
    local r = row(mob, { moving = true })
    -- head at 3 of 8: oldest at 4, then 5..8, 1, 2, 3
    local xs = { [4] = 0, [5] = 1.5, [6] = 3, [7] = 4.5, [8] = 6, [1] = 7.5, [2] = 9, [3] = 10.5 }
    local ts = { [4] = -1.05, [5] = -0.9, [6] = -0.75, [7] = -0.6, [8] = -0.45, [1] = -0.3, [2] = -0.15, [3] = 0 }
    for i = 1, 8 do
        r.trail_x[i], r.trail_y[i], r.trail_t[i] = xs[i], 0, clock.s + ts[i]
    end
    r.trail_n, r.trail_head = 8, 3
    world.rows = { r }
    M.render()
    local paths = all(calls, "path_3d")
    assert_eq(#paths, 3, "drawn at first sight")
    near(paths[1][1][1].x, 0, "starting at the oldest")
    near(paths[1][1][2].x, 1.5, "in order")
    near(paths[3][1][2].x, 10.5 + 3.0, "the arrow east")
end }

T[#T + 1] = { "the nearest four routes", function()
    local M, calls, world = bundle({ settings = { tracks_facing = false } })
    local rows = {}
    for i = 1, 6 do rows[i] = row(unit("w" .. i, 2 + i, 2 * i), { moving = true }) end
    world.rows = rows
    M.render()
    for _ = 1, 6 do
        clock.s = clock.s + 0.25
        for i = 1, 6 do
            local r = rows[i]
            r.obj.pos = V(r.obj.pos.x + 1, r.obj.pos.y, 0)
            r.x = r.obj.pos.x
        end
        M.render()
    end
    assert_eq(M.stats().patrols, 4, "four")
end }

-- --- switches, the world page, older JCores, the real layer ----------------------------

T[#T + 1] = { "switches: all off, each part off, Show world marks off, Minimal leaves routes out", function()
    local function scene(settings)
        local M, calls, world = bundle({ settings = settings })
        local a = caster(world, "A", 20, 0)
        world.missiles = { { caster = a, target = world.me, spell_id = 1, source_position = V(20, 0, 0),
            current_position = V(10, 0, 0), impact_position = V(0, 0, 0) } }
        local mob = unit("walker", 10, 5, { dir = V(1, 0, 0) })
        local r = row(mob, { moving = true })
        world.rows = { r }
        M.render()
        walk(M, r, 8)
        clear(calls)
        M.render()
        return #all(calls, "line_3d"), #all(calls, "ring_3d"), #all(calls, "polygon_3d"), M.stats().patrols
    end
    local l, g, f, p = scene({})
    assert_eq(l, 1, "a line"); assert_eq(g, 1, "a ring"); assert_eq(f, 1, "a wedge"); assert_eq(p, 1, "a route")
    l, g, f, p = scene({ tracks_on = false })
    assert_eq(l + g + f + p, 0, "all off")
    l, g, f, p = scene({ world_on = false })
    assert_eq(l + g + f + p, 0, "Show world marks off")
    l, g, f, p = scene({ tracks_missiles = false })
    assert_eq(l + g, 0, "no missiles"); assert_eq(f, 1, "wedge kept"); assert_eq(p, 1, "route kept")
    l, g, f, p = scene({ tracks_facing = false })
    assert_eq(f, 0, "no wedge"); assert_eq(l, 1, "missile kept"); assert_eq(p, 1, "route kept")
    l, g, f, p = scene({ tracks_patrols = false })
    assert_eq(p, 0, "no route"); assert_eq(f, 1, "wedge kept")
    l, g, f, p = scene({ world_density = 3 })
    assert_eq(p, 0, "Minimal: no route"); assert_eq(f, 1, "the wedge is information"); assert_eq(g, 1, "the ring too")
end }

T[#T + 1] = { "brightness and colour-blind correction reach what passes straight through", function()
    local M, calls, world = bundle({ settings = { world_brightness = 50, tracks_patrols = false } })
    world.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0) })) }
    M.render()
    assert_eq(all(calls, "polygon_3d")[1][2].a, 12, "half as bright")
    local M2, calls2, world2, _, P2 = bundle({ settings = { world_colorblind = 2, tracks_patrols = false } })
    P2.worldmarks = { daltonize = function(r, g, b) return r, 0, b end }
    setmetatable(P2.worldmarks, { __index = P2.draw })
    world2.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0) })) }
    M2.render()
    assert_eq(all(calls2, "polygon_3d")[1][2].g, 0, "corrected through the layer's daltonize")
end }

T[#T + 1] = { "an older JCore: no draw calls or no services, nothing and no error; no polygon_3d, the native cone", function()
    local M, _, world = bundle({ draw = {} })
    local a = caster(world, "A", 20, 0)
    world.missiles = { { caster = a, target = world.me, spell_id = 1, current_position = V(10, 0, 0),
        impact_position = V(0, 0, 0) } }
    world.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0) }), { moving = true }) }
    M.render()
    assert_eq(M.stats().missiles, 1, "looked at, nothing to draw with")
    assert_eq(M.stats().rings + M.stats().facing + M.stats().patrols, 0, "nothing drawn")
    local M2, calls2 = bundle({ services = false })
    M2.render()
    assert_eq(#calls2, 0, "no services: nothing")
    local calls3 = {}
    local M3, _, world3 = bundle({ draw = { cone_3d = function(...) calls3[#calls3 + 1] = { ... } end } })
    world3.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0) })) }
    M3.render()
    assert_eq(#calls3, 1, "the native cone")
    near(calls3[1][2].x, 6 + 20, "towards the way it faces"); assert_eq(calls3[1][3], 20, "its radius")
    assert_eq(calls3[1][4], 90, "90 degrees")
    local M4, calls4 = bundle({ draw = false })
    M4.render()
    assert_eq(#calls4, 0, "no draw at all")
end }

T[#T + 1] = { "through the real world layer: the ring is kept to the flush; lines and wedges pass straight through", function()
    local M, calls, world, _, P = bundle({ layer = true, settings = { tracks_patrols = false } })
    local a = caster(world, "A", 20, 0)
    world.missiles = { { caster = a, target = world.me, spell_id = 1, source_position = V(20, 0, 0),
        current_position = V(10, 0, 0), impact_position = V(0, 0, 0) } }
    world.rows = { row(unit("m", 6, 0, { dir = V(1, 0, 0) })) }
    M.render()
    assert_eq(#all(calls, "line_3d"), 1, "the line at once")
    assert_eq(#all(calls, "polygon_3d"), 1, "the wedge at once")
    assert_eq(#all(calls, "ring_3d"), 0, "the ring kept")
    P.worldmarks.flush()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "drawn at the flush")
    near(rings[1][2], 1.8 + 1.4 + 0.25, "its radius untouched (no lane passed)")
    assert_eq(rings[1][5].prio, nil, "the layer's options gone")
    assert_eq(P.worldmarks.stats().by.missiles, 1, "the layer counts it as missiles")
    -- A "missile" lane, once the layer has one, is where the ring goes.
    P.worldmarks.LANES.missile = 1.6
    clear(calls)
    M.render()
    P.worldmarks.flush()
    near(all(calls, "ring_3d")[1][2], 1.8 + 1.6 + 0.25, "the layer's lane")
end }

return T

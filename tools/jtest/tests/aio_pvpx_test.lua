-- Jambix AIO 1.89.0: PvP extras (modules/pvpx.lua).
--
-- Diminishing returns: each enemy player's crowd control from anyone, by
-- Classic Era's categories, as small rings filling over the 18 s after the
-- last one ends, amber / red / grey by what the next one would get, and
-- M.dr for other modules. Flag carriers in a battleground: a red or blue
-- beacon. Your stealth: a ring under each enemy player at the distance it
-- would notice you, red and a warning once you are inside. Drawn through a
-- recording draw service, and through the real world layer for the lanes.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000 + 0.5) end,
    spell_book = { get_spell_name = function() return nil end },
}

local SPELLS = { [12826] = "Polymorph", [10308] = "Hammer of Justice" }

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

local ME = { guid = "me", player = true, pos = { x = 0, y = 0, z = 0 }, index = {}, level = 60, reads = 0 }
ME.get_level = function(self) return self.level end
local OTHER = { guid = "someone" }

--- A player (an enemy unless `enemy = false`), standing `dist` yd along +x.
local function unit(guid, o)
    o = o or {}
    local d = o.dist or 10
    local u = { guid = guid, player = o.player ~= false, enemy = o.enemy ~= false, dist = d,
        pos = { x = d, y = 0, z = 0 }, dead = false, index = {}, reads = 0, level = o.level or 60,
        rot = o.rot, rot_reads = 0 }
    u.get_level = function(self) return self.level end
    u.get_rotation = function(self)
        self.rot_reads = self.rot_reads + 1
        return self.rot
    end
    u.is_player = function(self) return self.player end
    return u
end

--- An aura that ends `left` seconds from now.
local function aura(id, name, left, caster)
    return { buff_id = id, buff_name = name, expire_time = math.floor((clock.s + left) * 1000 + 0.5),
        caster = caster or OTHER }
end
--- Its auras, as the units service's index.
local function wear(u, ...)
    u.index = {}
    for i, a in ipairs({ ... }) do u.index[a.buff_id or ("n" .. i)] = a end
end

local function fresh(name)
    package.loaded[name] = nil
    return require(name)
end

local function bundle(list, opts)
    opts = opts or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = opts.settings or {}
    local function rows()
        local out = {}
        for i = 1, #list do
            local u = list[i]
            if u.enemy then out[#out + 1] = { guid = u.guid, obj = u, dist = u.dist } end
        end
        return out
    end
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 }, enemies = { all = rows },
            spells = { name = function(id) return SPELLS[id] end }, world = opts.world },
        units = {
            player = function() return ME end,
            guid = function(o) return o and o.guid end,
            position = function(o) return o and o.pos end,
            combat_reach = function() return 1.5 end,
            snapshot = function(o)
                return o and { is_player = o.player, dead = o.dead, guid = o.guid, is_self = o == ME,
                    is_enemy = o ~= ME and o.enemy, is_ally = o ~= ME and not o.enemy }
            end,
            is_dead = function(o) return o.dead end,
            aura_index = function(o)
                o.reads = (o.reads or 0) + 1
                return o.index
            end,
            players = opts.players and function() return opts.players end or nil,
        },
        draw = opts.draw or { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"),
            beacon_3d = rec("beacon_3d"), pulse = rec("pulse") },
    }
    if opts.no_enemies then P.ctx.enemies = nil end
    if opts.layer then
        P.worldmarks = fresh("jambix_aio/modules/worldlayer")(P)
    end
    local M = fresh("jambix_aio/modules/pvpx")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
        if P.worldmarks then P.worldmarks.flush() end
    end
    return M, calls, frame, settings, P
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end
local function rings(calls, module)
    local out = {}
    for _, c in ipairs(all(calls, "ring_3d")) do
        if not module or (c[5] and c[5].module == module) then out[#out + 1] = c end
    end
    return out
end
local AMBER, RED, GREY = 245, 235, 150

local T = {}

T[#T + 1] = { "DR: anyone's Polymorph, an amber ring in the cc lane from index 4, empty while it is on, filling over the 18 s after", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    wear(e, aura(118, "Polymorph", 8, OTHER))
    local M, calls, frame = bundle({ e }, { settings = { pvpx_stealth = false } })
    frame(0)
    local r = rings(calls, "dr")
    assert_eq(#r, 1, "one ring")
    assert_eq(r[1][1], e.pos, "under it")
    near(r[1][3], 0, "on: the window has not started")
    assert_eq(r[1][4].r, AMBER, "amber: the next is half")
    assert_eq(r[1][5].lane, "cc", "the cc lane")
    assert_eq(r[1][5].index, 4, "after pvpmarks' three")
    assert_eq(r[1][5].unit, e, "under the unit")
    assert_eq(r[1][5].prio, "info", "information")
    near(r[1][2], 2.4 + 4 * 0.45, "its own radius without the world layer")
    local mult, level, left = M.dr("e", "incapacitate")
    assert_eq(mult, 0.5, "half")
    assert_eq(level, "half", "by name")
    near(left, 8 + 18, "8 s left on it, then 18")
    assert_eq(select(2, M.dr("e", "Sap")), "half", "Sap shares it")
    assert_eq(select(2, M.dr("e", "Fear")), "full", "a fear does not")
    assert_eq(M.dr("e", "Blind"), 1, "Blind has none in Era")
    frame(4)
    near(rings(calls, "dr")[1][3], 0, "still on")
    e.index = {}
    frame(0.25)
    near(rings(calls, "dr")[1][3], 0, "broken: the window starts now")
    frame(9)
    near(rings(calls, "dr")[1][3], 0.5, "9 of 18 s")
    near(select(3, M.dr("e", "Polymorph")), 9, "9 s to go")
    frame(9.1)
    assert_eq(#rings(calls, "dr"), 0, "reset: gone")
    assert_eq(M.dr("e", "Polymorph"), 1, "full again")
    assert_eq(M.dr("e"), nil, "nothing running")
end }

T[#T + 1] = { "DR chain: Polymorph, Sap, Gouge in the window: half, a quarter, immune; one landing where it said immune starts again", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    local M, calls, frame = bundle({ e }, { settings = { pvpx_stealth = false } })
    wear(e, aura(118, "Polymorph", 1))
    frame(0)
    e.index = {}
    frame(1)
    wear(e, aura(6770, "Sap", 4))
    frame(0.25)
    assert_eq(rings(calls, "dr")[1][4].r, RED, "red: the next is a quarter")
    assert_eq(select(2, M.dr("e", "Polymorph")), "quarter", "a quarter")
    e.index = {}
    frame(1)
    wear(e, aura(1776, "Gouge", 4))
    frame(0.25)
    local r = rings(calls, "dr")
    assert_eq(r[1][4].r, GREY, "grey: immune")
    local mult, level = M.dr("e", "Repentance")
    assert_eq(mult, 0, "immune")
    assert_eq(level, "immune", "by name")
    e.index = {}
    frame(0.25)
    near(rings(calls, "dr")[1][3], 0, "broken: the window starts again at its end")
    frame(9)
    near(rings(calls, "dr")[1][3], 0.5, "9 of 18 s")
    wear(e, aura(118, "Polymorph", 4))
    frame(0.25)
    assert_eq(rings(calls, "dr")[1][4].r, AMBER, "it landed: the server had reset, a new chain")
    assert_eq(M.dr("e").incapacitate.count, 1, "one")
end }

T[#T + 1] = { "categories: Kidney Shot apart from the other stuns, Seduction a fear, nothing for Blind, Death Coil or a silence; by id or by name", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    local f = unit("f", { dist = 12 })
    wear(e, aura(1833, "Cheap Shot", 4), aura(408, "Kidney Shot", 6), aura(6358, "Seduction", 10),
        aura(2094, "Blind", 10), aura(6789, "Death Coil", 3), aura(18469, "Counterspell - Silenced", 4))
    wear(f, { buff_id = 12826, expire_time = (clock.s + 8) * 1000 },          -- no name: Polymorph by id
        { buff_id = 999999, buff_name = "Hammer of Justice", expire_time = (clock.s + 6) * 1000 })
    local M, calls, frame = bundle({ e, f }, { settings = { pvpx_stealth = false } })
    frame(0)
    local d = M.dr("e")
    assert(d.stun and d.kidney_shot and d.fear, "stun, Kidney Shot and fear")
    local n = 0
    for _ in pairs(d) do n = n + 1 end
    assert_eq(n, 3, "and nothing else")
    assert_eq(d.stun.on, true, "on")
    assert_eq(#rings(calls, "dr"), 5, "three under e, two under f")
    local g = M.dr("f")
    assert(g.incapacitate and g.stun, "f: by id, and by name")
    assert_eq(M.category("Scatter Shot"), "incapacitate", "Scatter Shot shares Polymorph's")
    assert_eq(M.category("Scare Beast"), "fear", "Scare Beast is a fear")
    assert_eq(M.category("Mace Stun Effect"), "random_stun", "a proc stun")
    assert_eq(M.category("Frostbite"), nil, "Frostbite has none")
    assert_eq(M.category(8643), "kidney_shot", "by id")
    assert_eq(M.category("stun"), "stun", "a category is itself")
end }

T[#T + 1] = { "the same one seen again does not count, put on again does; at most three rings, the worst first; death clears", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    local M, calls, frame = bundle({ e }, { settings = { pvpx_stealth = false } })
    wear(e, aura(5782, "Fear", 8))
    frame(0)
    frame(0.25)
    frame(0.25)
    assert_eq(M.dr("e").fear.count, 1, "one, however often it is read")
    local again = aura(5782, "Fear", 4)
    wear(e, again)
    frame(0.25)
    assert_eq(M.dr("e").fear.count, 2, "its end moved: put on again")
    assert_eq(rings(calls, "dr")[1][4].r, RED, "red")
    wear(e, again, aura(1833, "Cheap Shot", 4), aura(339, "Entangling Roots", 10), aura(8056, "Frost Shock", 8))
    frame(0.25)
    local r = rings(calls, "dr")
    assert_eq(#r, 3, "three of four")
    assert_eq(r[1][4].r, RED, "the fear, twice landed, first")
    assert_eq(r[1][5].index, 4, "at index 4")
    assert_eq(r[3][5].index, 6, "the last at 6")
    e.dead = true
    frame(0.25)
    assert_eq(#rings(calls, "dr"), 0, "dead: nothing")
    assert_eq(M.dr("e"), nil, "and forgotten")
end }

T[#T + 1] = { "lanes through the world layer: cc 4..6 now, the layer's own dr lane once it has one", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    wear(e, aura(5782, "Fear", 8), aura(1833, "Cheap Shot", 4))
    local M, calls, frame, _, P = bundle({ e }, { layer = true, settings = { pvpx_stealth = false } })
    frame(0)
    local r = rings(calls)
    assert_eq(#r, 2, "two, drawn at the flush")
    local edge = 1.5 + 0.3
    near(r[1][2], edge + 1.75 + 3 * 0.35 + 0.25, "cc index 4")
    near(r[2][2], edge + 1.75 + 4 * 0.35 + 0.25, "cc index 5")
    assert_eq(P.worldmarks.stats().by.dr, 2, "counted as dr")
    P.worldmarks.LANES.dr = 2.8
    frame(0.25)
    r = rings(calls)
    near(r[1][2], edge + 2.8 + 0.25, "dr index 1")
    near(r[2][2], edge + 2.8 + 0.35 + 0.25, "dr index 2")
end }

T[#T + 1] = { "the nearest ten are read five times a second, the nearest six get rings", function()
    clock.s = 1000.0
    local list = {}
    for i = 1, 12 do
        local u = unit("p" .. i, { dist = 3 + i * 2 })
        wear(u, aura(118, "Polymorph", 50))
        list[i] = u
    end
    local M, calls, frame = bundle(list, { settings = { pvpx_stealth = false } })
    frame(0)
    assert_eq(M.stats().looked, 10, "ten read")
    assert_eq(#rings(calls, "dr"), 6, "six rings")
    assert_eq(list[11].reads + list[12].reads, 0, "the furthest two not read")
    frame(0.1)
    assert_eq(M.stats().looked, 0, "not again within 0.2 s")
    frame(0.15)
    assert_eq(M.stats().looked, 10, "again")
end }

T[#T + 1] = { "M.dr reads by itself with the marks off, takes a unit, says nil for nobody; mobs are never tracked", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 10 })
    local mob = unit("mob", { dist = 8, player = false })
    wear(e, aura(118, "Polymorph", 8))
    wear(mob, aura(118, "Polymorph", 8))
    local M, calls, frame = bundle({ e, mob }, { settings = { pvpx_on = false } })
    frame(0)
    assert_eq(#calls, 0, "nothing drawn")
    local d = M.dr(e)
    assert(d and d.incapacitate, "read when asked, by the unit")
    assert_eq(d.incapacitate.level, "half", "half")
    assert_eq(M.dr("nobody"), nil, "nobody")
    assert_eq(M.dr(mob), nil, "a mob")
    assert_eq(mob.reads, 0, "its auras not read")
end }

T[#T + 1] = { "flag carriers: only in a battleground; red on theirs, blue on yours, never on you; by id or by name", function()
    clock.s = 1000.0
    local bg = false
    local a = unit("a", { dist = 30 })
    local b = unit("b", { dist = 50, enemy = false })
    local c = unit("c", { dist = 20 })
    wear(a, aura(23333, "Warsong Flag", 0))
    b.index = { x = { buff_name = "Silverwing Flag" } }
    ME.index = { [23335] = aura(23335, "Silverwing Flag", 0) }
    local world = { in_battleground = function() return bg end }
    local M, calls, frame = bundle({ a, b, c }, { players = { ME, a, b, c }, world = world,
        settings = { pvpx_dr = false, pvpx_stealth = false, pvpx_bg = true } })
    frame(0)
    assert_eq(#all(calls, "beacon_3d"), 0, "not in a battleground")
    bg = true
    frame(0.5)
    assert_eq(#all(calls, "beacon_3d"), 0, "asked once a second")
    frame(0.6)
    local bc = all(calls, "beacon_3d")
    assert_eq(#bc, 2, "two carriers")
    assert_eq(bc[1][1], a.pos, "theirs")
    assert_eq(bc[1][2].r, 240, "red")
    assert_eq(bc[1][3].prio, "warn", "a warning")
    assert_eq(bc[1][3].module, "bg", "bg")
    assert_eq(bc[1][3].unit, a, "under it")
    assert(bc[1][3].height >= 20, "tall")
    assert_eq(bc[2][1], b.pos, "yours, 50 yd off")
    assert_eq(bc[2][2].r, 70, "blue")
    assert_eq(M.stats().carriers, 2, "counted")
    a.index = {}
    frame(0.25)
    assert_eq(#all(calls, "beacon_3d"), 2, "read again only after half a second")
    frame(0.3)
    assert_eq(#all(calls, "beacon_3d"), 1, "dropped")
    bg = false
    frame(1.1)
    assert_eq(#all(calls, "beacon_3d"), 0, "left the battleground")
    ME.index = {}
end }

T[#T + 1] = { "a battleground by the instance type, its name or its map id; flags read eight a frame", function()
    clock.s = 1000.0
    local list = {}
    for i = 1, 20 do list[i] = unit("p" .. i, { dist = i * 3 }) end
    wear(list[20], aura(23335, "Silverwing Flag", 0))
    local function try(world)
        for i = 1, 20 do list[i].reads = 0 end
        local M, calls, frame = bundle(list, { players = list, world = world,
            settings = { pvpx_dr = false, pvpx_stealth = false, pvpx_bg = true } })
        frame(0)
        return M, calls, frame
    end
    local M, calls, frame = try({ instance_type = function() return "PvP" end })
    local total = 0
    for i = 1, 20 do total = total + list[i].reads end
    assert_eq(total, 8, "eight reads")
    assert_eq(M.stats().bg, true, "a battleground by its type")
    frame(0.01)
    frame(0.01)
    assert_eq(#all(calls, "beacon_3d"), 1, "all twenty read in three frames")
    M = try({ instance_type = function() return "none" end, instance_name = function() return "Warsong Gulch" end })
    assert_eq(M.stats().bg, true, "by its name")
    M = try({ instance_type = function() return "none" end, instance_id = function() return 489 end })
    assert_eq(M.stats().bg, true, "by its map id")
    M = try({ instance_type = function() return "none" end, instance_name = function() return "Kalimdor" end,
        instance_id = function() return 1 end })
    assert_eq(M.stats().bg, false, "the open world")
end }

T[#T + 1] = { "stealth: nothing unless you are; 9 yd facing you, a yard a level, a third behind; red and a warning inside", function()
    clock.s = 1000.0
    -- Facing you: it stands on +x looking back along -x (pi).
    local face = unit("face", { dist = 15, rot = math.pi })
    local high = unit("high", { dist = 20, rot = math.pi, level = 63 })
    local back = unit("back", { dist = 25, rot = 0.1 })
    local close = unit("close", { dist = 8, rot = math.pi })
    local far = unit("far", { dist = 35, rot = math.pi })
    local mob = unit("mob", { dist = 6, rot = math.pi, player = false })
    local M, calls, frame, settings = bundle({ face, high, back, close, far, mob }, { settings = { pvpx_dr = false } })
    ME.index = {}
    frame(0)
    assert_eq(#rings(calls, "stealth"), 0, "not stealthed")
    ME.index = { [1787] = aura(1787, "Stealth", 0) }
    frame(0.25)
    local r = rings(calls, "stealth")
    assert_eq(#r, 4, "four players within 30 yd")
    local by = {}
    for _, c in ipairs(r) do by[c[5].unit.guid] = c end
    near(by.face[2], 9, "9 yd")
    assert_eq(by.face[5].prio, "info", "outside: information")
    near(by.high[2], 12, "three levels over you: 12")
    near(by.back[2], 3, "its back to you: a third")
    near(by.close[2], 9, "9 yd")
    assert_eq(by.close[5].prio, "warn", "inside: a warning")
    assert_eq(by.close[4].r, 240, "red")
    assert_eq(M.stats().inside, 1, "counted")
    assert_eq(M.stats().stealthed, true, "stealthed")
    settings.pvpx_stealth_base = 7
    settings.pvpx_stealth_mobs = true
    frame(0.25)
    r = rings(calls, "stealth")
    assert_eq(#r, 5, "and the mob")
    by = {}
    for _, c in ipairs(r) do by[c[5].unit.guid] = c end
    near(by.face[2], 7, "the setting")
    near(by.close[2], 7, "7 yd: outside now")
    assert_eq(by.close[5].prio, "info", "information")
    ME.index = { x = { buff_name = "Prowl" } }
    frame(0.25)
    assert_eq(#rings(calls, "stealth"), 5, "Prowl by name")
    ME.index = {}
    frame(0.25)
    assert_eq(#rings(calls, "stealth"), 0, "out of stealth")
end }

T[#T + 1] = { "stealth: get_direction answers first (Forever); a rotation of exactly 0 is no answer", function()
    clock.s = 1000.0
    -- Both stand on +x. One's direction points away from you (+x); the
    -- other's rotation is exactly 0, which the client gives when it does
    -- not know: taken as facing you, the full distance.
    local away = unit("away", { dist = 15, rot = math.pi })
    away.get_direction = function() return { x = 1, y = 0, z = 0 } end
    local zero = unit("zero", { dist = 20, rot = 0 })
    local M, calls, frame = bundle({ away, zero }, { settings = { pvpx_dr = false } })
    ME.index = { [1787] = aura(1787, "Stealth", 0) }
    frame(0.25)
    local by = {}
    for _, c in ipairs(rings(calls, "stealth")) do by[c[5].unit.guid] = c end
    near(by.away[2], 3, "the direction says its back is to you, whatever the rotation")
    near(by.zero[2], 9, "rotation 0: not known, so the full 9 yd")
end }

T[#T + 1] = { "stealth: facing read five times a second per enemy", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 15, rot = math.pi })
    local M, calls, frame = bundle({ e }, { settings = { pvpx_dr = false } })
    ME.index = { [1787] = aura(1787, "Stealth", 0) }
    frame(0)
    frame(0.05)
    frame(0.05)
    assert_eq(e.rot_reads, 1, "once in 0.1 s")
    frame(0.15)
    assert_eq(e.rot_reads, 2, "again after 0.2 s")
    ME.index = {}
end }

T[#T + 1] = { "switches: all off, then each mark on its own; the beacon off by default (1.7.6, a curtain)", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 8, rot = math.pi })
    wear(e, aura(23333, "Warsong Flag", 0), aura(118, "Polymorph", 8))
    ME.index = { [1787] = aura(1787, "Stealth", 0) }
    local world = { in_battleground = function() return true end }
    local M, calls, frame, settings = bundle({ e }, { players = { ME, e }, world = world,
        settings = { pvpx_on = false, pvpx_bg = true } })
    frame(0)
    assert_eq(#calls, 0, "all off")
    settings.pvpx_on = nil
    frame(0.25)
    assert_eq(#rings(calls, "dr"), 1, "DR")
    assert_eq(#all(calls, "beacon_3d"), 1, "the carrier")
    assert_eq(#rings(calls, "stealth"), 1, "stealth")
    settings.pvpx_dr = false
    frame(0.25)
    assert_eq(#rings(calls, "dr"), 0, "DR off")
    settings.pvpx_bg = false
    frame(0.25)
    assert_eq(#all(calls, "beacon_3d"), 0, "beacons off")
    settings.pvpx_bg = nil
    frame(0.25)
    assert_eq(#all(calls, "beacon_3d"), 0, "and off by default: an enemy carries no curtain")
    settings.pvpx_stealth = false
    frame(0.25)
    assert_eq(#calls, 0, "stealth off")
    ME.index = {}
end }

T[#T + 1] = { "an older JCore without ring_3d or beacon_3d, no draw, no enemies: nothing drawn, nothing raised", function()
    clock.s = 1000.0
    local e = unit("e", { dist = 8, rot = math.pi })
    wear(e, aura(23333, "Warsong Flag", 0), aura(118, "Polymorph", 8))
    ME.index = { [1787] = aura(1787, "Stealth", 0) }
    local world = { in_battleground = function() return true end }
    local drawn = 0
    local old = { circle_3d = function() drawn = drawn + 1 end, line_3d = function() drawn = drawn + 1 end }
    local M, _, frame, _, P = bundle({ e }, { players = { ME, e }, world = world, draw = old })
    frame(0)
    frame(0.25)
    assert_eq(drawn, 0, "nothing")
    assert_eq(M.stats().dr, 0, "no DR ring counted")
    P.draw = nil
    frame(0.25)
    local M2, calls2, frame2 = bundle({ e }, { no_enemies = true, players = { ME, e }, world = world,
        settings = { pvpx_bg = true } })
    frame2(0)
    assert_eq(#rings(calls2, "dr") + #rings(calls2, "stealth"), 0, "no enemies service: no rings")
    assert_eq(#all(calls2, "beacon_3d"), 1, "the carrier from the player list")
    assert_eq(M2.dr("e"), nil, "M.dr: nil")
    ME.index = {}
end }

return T

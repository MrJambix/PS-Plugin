-- Jambix AIO 1.87.0: pull safety (modules/pull.lua).
--
-- Aggro rings under hostile mobs not yet fighting, at Classic's radius for
-- the level difference, filling and reddening as you walk toward the edge;
-- a curtain round an elite, rare or boss heading your way; a pulse the first
-- time a rare is seen. Drawn through a recording draw service.

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

local function mob(o)
    local m = { guid = o.guid, level = o.level or 20, hostile = o.hostile ~= false, rank = o.rank or 0,
        pos = { x = o.dist or 10, y = 0, z = 0 } }
    m.get_level = function(self) return self.level end
    return m
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
        for _, id in ipairs({ "pull_curtains" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local rows = {}
    for i = 1, #list do
        local m = list[i]
        rows[i] = { guid = m.guid, obj = m, dist = m.pos.x, in_combat = m.in_combat, engaged = m.engaged,
            closing = m.closing or 0 }
    end
    local me = { is_enemy_with = function(_, other) return other.hostile end, get_level = function() return 20 end }
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 }, enemies = { all = function() return rows end },
            player = { level = function() return opts.my_level or 20 end } },
        units = {
            player = function() return me end,
            position = function(o) return o.pos end,
            classification = function(o) return o.rank end,
            combat_reach = function() return 1.5 end,
        },
        draw = { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") },
    }
    package.loaded["jambix_aio/modules/pull"] = nil
    local M = require("jambix_aio/modules/pull")(P)
    return M, calls, rows, settings, P
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local T = {}

T[#T + 1] = { "the aggro radius: 20 yd at your level, a yard per level between, 5 to 45", function()
    local M = bundle({})
    assert_eq(M.aggro_radius(20, 20), 20, "same level")
    assert_eq(M.aggro_radius(15, 20), 15, "five below you")
    assert_eq(M.aggro_radius(23, 20), 23, "three above you")
    assert_eq(M.aggro_radius(1, 60), 5, "never under 5")
    assert_eq(M.aggro_radius(63, 20), 45, "never over 45")
    assert_eq(M.aggro_radius(20, 20, 18), 18, "the base is a setting")
end }

T[#T + 1] = { "a ring at the mob's radius, filling and reddening as you walk toward its edge; full inside it", function()
    local M, calls, rows = bundle({ mob({ guid = "a", dist = 26 }) })
    M.render()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "one ring")
    near(r[1][2], 20, "its radius")
    near(r[1][3], 1 - 6 / 12, "6 yd outside: half full")
    assert_eq(r[1][4].r, 240, "amber"); assert_eq(r[1][5].to.g, 70, "turning red")
    assert_eq(r[1][5].droppable, true, "outside it, droppable")
    rows[1].dist = 18
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    r = all(calls, "ring_3d")
    near(r[1][3], 1, "inside: full")
    assert_eq(r[1][5].droppable, false, "inside it, never dropped")
    rows[1].dist = 40
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#all(calls, "ring_3d"), 0, "20 yd outside: nothing")
end }

T[#T + 1] = { "only hostile mobs not yet fighting, the nearest few", function()
    local list = {
        mob({ guid = "neutral", dist = 10, hostile = false }),
        mob({ guid = "busy", dist = 10 }),
        mob({ guid = "dead", dist = 10 }),
    }
    list[2].in_combat = true
    for i = 1, 10 do list[#list + 1] = mob({ guid = "m" .. i, dist = 10 + i }) end
    local M, calls, rows = bundle(list)
    rows[3].dead = true
    M.render()
    assert_eq(#all(calls, "ring_3d"), 8, "the nearest 8 (the default)")
    for _, c in ipairs(all(calls, "ring_3d")) do assert(c[1].x >= 11, "neither the neutral, the busy nor the dead one") end
end }

T[#T + 1] = { "1.8.1: never a player, nor a player's pet or minion; a mob's own pet and an owner that does not answer keep theirs", function()
    local function owned_by(m, kind, owner)
        m[kind] = function() return true end
        m.get_owner = function() return owner end
        return m
    end
    local horde = mob({ guid = "player", dist = 6, level = 30 })
    horde.is_player = function() return true end
    local npc_owner = mob({ guid = "npc_owner", dist = 50 })
    npc_owner.is_player = function() return false end
    local list = {
        horde,
        owned_by(mob({ guid = "imp", dist = 7 }), "is_minion", horde),
        owned_by(mob({ guid = "wolf", dist = 8 }), "is_pet", horde),
        owned_by(mob({ guid = "mob_pet", dist = 9 }), "is_pet", npc_owner),
        owned_by(mob({ guid = "unknown_owner", dist = 10 }), "is_pet", nil),
        mob({ guid = "boar", dist = 11 }),
    }
    local M, calls = bundle(list)
    M.render()
    local at = {}
    for _, c in ipairs(all(calls, "ring_3d")) do at[c[1].x] = true end
    assert_eq(at[6], nil, "no ring under the player")
    assert_eq(at[7], nil, "nor its minion")
    assert_eq(at[8], nil, "nor its pet")
    assert_eq(at[9], true, "a mob's pet keeps its ring")
    assert_eq(at[10], true, "an owner that does not answer: the ring stays")
    assert_eq(at[11], true, "the boar")
end }

T[#T + 1] = { "1.8.1: a player the sweep marks as one gets no ring, curtain or pulse; the sweep's word comes first", function()
    local rare = mob({ guid = "rare_player", dist = 20, rank = 4 })
    rare.closing = 2
    local boar = mob({ guid = "boar", dist = 15 })
    local asked = 0
    boar.is_player = function() asked = asked + 1 return false end
    local M, calls, _, _, P = bundle({ rare, boar })
    P.units.snapshot = function(o) return { is_player = o == rare } end
    M.render()
    assert_eq(#all(calls, "curtain_3d") + #all(calls, "pulse"), 0, "no curtain or pulse")
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "the boar's ring only")
    assert_eq(r[1][1].x, 15, "under the boar")
    assert_eq(asked, 0, "the sweep had said: the unit not asked")
end }

T[#T + 1] = { "an elite, rare or boss heading your way gets a curtain in its colour; a rare a pulse the first time", function()
    local list = {
        mob({ guid = "elite", dist = 30, rank = 1 }), mob({ guid = "rare", dist = 35, rank = 4 }),
        mob({ guid = "boss", dist = 40, rank = 3 }), mob({ guid = "idle_elite", dist = 32, rank = 1 }),
    }
    list[1].closing, list[2].closing, list[3].closing = 2, 1, 3
    local M, calls = bundle(list)
    M.render()
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 3, "the three walking at you, not the one standing")
    local by = {}
    for _, c in ipairs(cs) do by[c[1].x] = c end
    assert_eq(by[30][3].g, 190, "gold elite"); assert_eq(by[35][3].b, 235, "silver rare"); assert_eq(by[40][3].g, 70, "red boss")
    assert(by[30][4].fill > 0, "filled")
    local pulses = all(calls, "pulse")
    assert_eq(#pulses, 1, "the rare's pulse")
    assert_eq(pulses[1][1], list[2], "under the rare")
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#all(calls, "pulse"), 0, "once only")
end }

T[#T + 1] = { "switches: off, rings off, curtains off, the rare's pulse off", function()
    local list = { mob({ guid = "rare", dist = 25, rank = 4 }) }
    list[1].closing = 2
    local M, calls, _, settings = bundle(list, { settings = { pull_rings = false } })
    M.render()
    assert_eq(#all(calls, "ring_3d"), 0, "no rings"); assert_eq(#all(calls, "curtain_3d"), 1, "the curtain")
    settings.pull_curtains, settings.pull_rings = false, true
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#all(calls, "curtain_3d"), 0, "no curtain"); assert_eq(#all(calls, "ring_3d"), 1, "the ring")
    local M2, calls2 = bundle({ mob({ guid = "r", dist = 25, rank = 4 }) }, { settings = { pull_rare_pulse = false } })
    M2.render()
    assert_eq(#all(calls2, "pulse"), 0, "no pulse")
    local M3, calls3 = bundle({ mob({ guid = "a", dist = 25 }) }, { settings = { pull_on = false } })
    M3.render()
    assert_eq(#calls3, 0, "all off")
end }

T[#T + 1] = { "1.7.6: the curtain is off by default; the rings and the rare's pulse are not", function()
    local list = { mob({ guid = "elite", dist = 30, rank = 1 }), mob({ guid = "rare", dist = 35, rank = 4 }) }
    list[1].closing, list[2].closing = 2, 1
    local M, calls = bundle(list, { curtains_default = true })
    M.render()
    assert_eq(#all(calls, "curtain_3d"), 0, "no curtain by default")
    assert(#all(calls, "ring_3d") >= 1, "the aggro rings still")
    assert_eq(#all(calls, "pulse"), 1, "and the rare's pulse")
end }

return T

-- Jambix AIO 1.87.0: PvP marks (modules/pvpmarks.lua).
--
-- The kill target (the enemy player in reach lowest on health) in a red
-- curtain with a pulse when the pick changes; a green curtain round each
-- enemy player seen healing in the last 20 s; your crowd control on them as
-- purple rings emptying; their PvP trinket as a grey ring filling back up,
-- gold once it is back. The reactions' real pvp.lua and detect.lua answer
-- what is crowd control, what is a heal and where each trinket stands.
-- Drawn through a recording draw service.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
local BOOK = { [19968] = "Holy Light" }   -- only the spell book knows this one
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000 + 0.5) end,
    spell_book = { get_spell_name = function(id) return BOOK[id] end },
}

local SPELLS = { [2060] = "Greater Heal", [11730] = "Create Healthstone", [133] = "Fireball", [8936] = "Regrowth" }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, label)
    if type(got) ~= "number" or math.abs(got - want) > 1e-3 then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local ME = { guid = "me" }
local PET = { guid = "pet" }
local OTHER = { guid = "someone" }

--- An enemy unit: a player unless `player = false`.
local function enemy(guid, o)
    o = o or {}
    local u = { guid = guid, player = o.player ~= false, pos = { x = o.dist or 10, y = 0, z = 0 },
        hp = o.hp or 1, dead = false, auras = {}, index = {}, reads = 0 }
    u.get_auras = function(self)
        self.reads = self.reads + 1
        return self.auras
    end
    u.is_player = function(self) return self.player end
    return u
end

--- An aura that ends `left` seconds from now.
local function aura(id, name, left, caster)
    return { buff_id = id, buff_name = name, expire_time = math.floor((clock.s + left) * 1000 + 0.5),
        caster = caster or ME }
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
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not opts.curtains_default then
        for _, id in ipairs({ "pvp_kill_target", "pvp_healers" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local function rows()
        local out = {}
        for i = 1, #list do
            local u = list[i]
            out[i] = { guid = u.guid, obj = u, dist = u.pos.x, hp = u.hp, casting = u.casting }
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
            spells = { name = function(id) return SPELLS[id] end } },
        units = {
            player = function() return ME end,
            player_pet = function() return opts.pet end,
            guid = function(o) return o and o.guid end,
            position = function(o) return o and o.pos end,
            combat_reach = function() return 1.5 end,
            snapshot = function(o) return o and { is_player = o.player, dead = o.dead } end,
            health_fraction = function(o) return o.hp end,
            is_dead = function(o) return o.dead end,
            aura_index = function(o) return o.index end,
        },
        draw = opts.draw or { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") },
    }
    if not opts.no_react then
        local latch = fresh("jambix_aio/modules/react/latch")()
        P.react = {
            pvp = fresh("jambix_aio/modules/react/pvp")(P, nil),
            detect = fresh("jambix_aio/modules/react/detect")(P, latch),
        }
    end
    local M = fresh("jambix_aio/modules/pvpmarks")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
    end
    return M, calls, frame, settings, P
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end
local function red(c) return c.r == 240 and c.g == 70 end
local function green(c) return c.r == 100 and c.g == 220 end
local function curtains(calls, which)
    local out = {}
    for _, c in ipairs(all(calls, "curtain_3d")) do if which(c[3]) then out[#out + 1] = c end end
    return out
end

local T = {}

T[#T + 1] = { "kill target: the enemy player in reach lowest on health, never an NPC, the far, the dead or the bubbled", function()
    clock.s = 1000.0
    local a = enemy("a", { dist = 10, hp = 0.8 })
    local b = enemy("b", { dist = 20, hp = 0.5 })
    local npc = enemy("npc", { dist = 5, hp = 0.1, player = false })
    local far = enemy("far", { dist = 45, hp = 0.05 })
    local dead = enemy("dead", { dist = 8, hp = 0.02 })
    dead.dead = true
    local bubble = enemy("bubble", { dist = 12, hp = 0.2 })
    bubble.index = { [642] = { buff_id = 642, buff_name = "Divine Shield" } }
    local M, calls, frame = bundle({ a, b, npc, far, dead, bubble })
    frame(0)
    local k = curtains(calls, red)
    assert_eq(#k, 1, "one kill target")
    assert_eq(k[1][1], b.pos, "the lowest player in reach")
    assert(k[1][4].fill > 0, "filled")
    assert_eq(k[1][4].layer, 100, "the world layer")
    assert_eq(#all(calls, "pulse"), 0, "no pulse for the first pick")
    assert_eq(M.stats().kill, true, "counted")
    assert_eq(M.stats().players, 3, "three players within 40 yd, alive")
end }

T[#T + 1] = { "kill target: holds until another is 5% lower, then a pulse under the new one; the range is a setting", function()
    clock.s = 1000.0
    local a = enemy("a", { dist = 10, hp = 0.8 })
    local b = enemy("b", { dist = 20, hp = 0.5 })
    local M, calls, frame, settings = bundle({ a, b })
    frame(0)
    a.hp = 0.47
    frame()
    assert_eq(curtains(calls, red)[1][1], b.pos, "3% lower: the pick holds")
    assert_eq(#all(calls, "pulse"), 0, "and no pulse")
    a.hp = 0.3
    frame()
    assert_eq(curtains(calls, red)[1][1], a.pos, "20% lower: the pick changes")
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "a pulse")
    assert_eq(p[1][1], a, "under the new pick")
    a.hp, b.hp = 0.9, 0.1
    settings.pvp_kill_range = 15
    frame()
    assert_eq(curtains(calls, red)[1][1], a.pos, "b is out of a 15 yd reach")
    settings.pvp_kill_range = 5
    frame()
    assert_eq(#curtains(calls, red), 0, "nobody within 5 yd")
end }

T[#T + 1] = { "enemy healer: a green curtain once a heal is seen, cast or left as a heal over time; gone after 20 s", function()
    clock.s = 1000.0
    local priest = enemy("priest", { dist = 15 })
    local lock = enemy("lock", { dist = 18 })
    local pally = enemy("pally", { dist = 22 })
    local druid = enemy("druid", { dist = 25 })
    local mage = enemy("mage", { dist = 28 })
    priest.casting = { spell_id = 2060 }        -- Greater Heal
    lock.casting = { spell_id = 11730 }         -- Create Healthstone: detect.lua says "heal", it is not
    mage.casting = { spell_id = 133 }           -- Fireball
    local M, calls, frame = bundle({ priest, lock, pally, druid, mage }, { settings = { pvp_kill_target = false } })
    frame(0)
    local h = curtains(calls, green)
    assert_eq(#h, 1, "only the priest")
    assert_eq(h[1][1], priest.pos, "round the priest")
    priest.casting = nil
    pally.casting = { spell_id = 19968 }        -- Holy Light, named by the spell book
    lock.auras = { aura(774, "Rejuvenation", 12, druid) }
    frame(10)
    assert_eq(#curtains(calls, green), 3, "the priest still, the paladin, and the druid by its Rejuvenation")
    assert_eq(M.stats().healers, 3, "counted")
    pally.casting, lock.auras = nil, {}
    frame(10.5)
    h = curtains(calls, green)
    assert_eq(#h, 2, "the priest's heal is 20.5 s old")
    for _, c in ipairs(h) do assert(c[1] ~= priest.pos, "not the priest") end
    frame(10)
    assert_eq(#curtains(calls, green), 0, "all gone after 20 s")
end }

T[#T + 1] = { "your crowd control: a purple ring emptying from what was left when seen; someone else's and a snare are not", function()
    clock.s = 1000.0
    local e = enemy("e", { dist = 10 })
    e.auras = { aura(118, "Polymorph", 8), aura(2094, "Blind", 10, OTHER), aura(1715, "Hamstring", 12) }
    local M, calls, frame = bundle({ e }, { settings = { pvp_kill_target = false, pvp_trinkets = false } })
    frame(0)
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "your Polymorph only")
    assert_eq(r[1][1], e.pos, "under it")
    near(r[1][3], 1, "just seen: full")
    assert_eq(r[1][5].direction, -1, "emptying")
    assert_eq(r[1][4].r, 170, "purple")
    frame(4)
    near(all(calls, "ring_3d")[1][3], 0.5, "4 of 8 s left")
    e.auras = { aura(118, "Polymorph", 10) }
    frame(0.25)
    near(all(calls, "ring_3d")[1][3], 1, "put on again: full")
    e.auras = {}
    frame(0.25)
    assert_eq(#all(calls, "ring_3d"), 0, "broken: gone")
    assert_eq(M.stats().cc, 0, "counted")
end }

T[#T + 1] = { "your pet's Seduction counts; a Freezing Trap by its aura's name", function()
    clock.s = 1000.0
    local e, f = enemy("e", { dist = 10 }), enemy("f", { dist = 14 })
    e.auras = { aura(6358, "Seduction", 15, PET) }
    f.auras = { aura(14309, "Freezing Trap Effect", 20) }
    local M, calls, frame = bundle({ e, f }, { pet = PET, settings = { pvp_kill_target = false, pvp_trinkets = false } })
    frame(0)
    assert_eq(#all(calls, "ring_3d"), 2, "both")
end }

T[#T + 1] = { "trinket: a thin gold ring while it is up, grey filling back up once used, by pvp.lua's state", function()
    clock.s = 1000.0
    local e = enemy("e", { dist = 10 })
    local f = enemy("f", { dist = 14 })
    local M, calls, frame = bundle({ e, f }, { settings = { pvp_kill_target = false, pvp_cc_timers = false } })
    frame(0)
    local r = all(calls, "ring_3d")
    assert_eq(#r, 2, "a ring each")
    near(r[1][3], 1, "full")
    assert_eq(r[1][4].r, 245, "gold: ready")
    assert(r[1][5].inner >= 0.9, "thin")
    -- An Insignia (Immune Fear/Polymorph/Stun, 300 s) and the PvP Trinket (120 s).
    e.index = { [23276] = { buff_id = 23276, buff_name = "Immune Fear/Polymorph/Stun" } }
    f.index = { [474386] = { buff_id = 474386, buff_name = "PvP Trinket" } }
    frame(0.25)
    r = all(calls, "ring_3d")
    assert_eq(r[1][4].r, 150, "grey: down")
    near(r[1][3], 0, "just used: empty")
    near(r[2][3], 0, "just used: empty")
    e.index, f.index = {}, {}
    frame(60)
    r = all(calls, "ring_3d")
    near(r[1][3], 60 / 300, "the Insignia: 60 of 300 s")
    near(r[2][3], 60 / 120, "the PvP Trinket: 60 of 120 s")
    frame(61)
    r = all(calls, "ring_3d")
    assert_eq(r[2][4].r, 245, "the PvP Trinket is back")
    assert_eq(r[1][4].r, 150, "the Insignia is not")
    frame(180)
    assert_eq(all(calls, "ring_3d")[1][4].r, 245, "the Insignia is back")
end }

T[#T + 1] = { "auras read five times a second, off the nearest six", function()
    clock.s = 1000.0
    local list = {}
    for i = 1, 8 do
        local u = enemy("p" .. i, { dist = 5 + i * 2 })
        u.auras = { aura(118, "Polymorph", 50) }
        list[i] = u
    end
    local M, calls, frame = bundle(list, { settings = { pvp_kill_target = false, pvp_trinkets = false } })
    frame(0)
    assert_eq(M.stats().looked, 6, "six read")
    assert_eq(#all(calls, "ring_3d"), 6, "six rings")
    assert_eq(list[7].reads + list[8].reads, 0, "the furthest two not read")
    frame(0.15)
    assert_eq(M.stats().looked, 0, "not again within 0.2 s")
    frame(0.15)
    assert_eq(M.stats().looked, 6, "again")
end }

T[#T + 1] = { "nothing in PvE: mobs, however low, healing or controlled by you, get nothing", function()
    clock.s = 1000.0
    local mob = enemy("mob", { dist = 8, hp = 0.1, player = false })
    mob.casting = { spell_id = 2060 }
    mob.auras = { aura(118, "Polymorph", 8) }
    local M, calls, frame = bundle({ mob, enemy("mob2", { dist = 12, player = false }) })
    frame(0)
    frame(0.25)
    assert_eq(#calls, 0, "nothing drawn")
    assert_eq(M.stats().players, 0, "no players")
    assert_eq(mob.reads, 0, "its auras not read")
end }

T[#T + 1] = { "switches: all off, then each mark on its own", function()
    clock.s = 1000.0
    local e = enemy("e", { dist = 10, hp = 0.5 })
    e.casting = { spell_id = 2060 }
    e.auras = { aura(118, "Polymorph", 8) }
    local M, calls, frame, settings = bundle({ e }, { settings = { pvpmarks_on = false } })
    frame(0)
    assert_eq(#calls, 0, "all off")
    settings.pvpmarks_on = nil
    frame()
    assert_eq(#curtains(calls, red), 1, "kill target")
    assert_eq(#curtains(calls, green), 1, "healer")
    assert_eq(#all(calls, "ring_3d"), 2, "trinket and crowd control")
    settings.pvp_kill_target = false
    frame()
    assert_eq(#curtains(calls, red), 0, "kill target off")
    settings.pvp_healers = false
    frame()
    assert_eq(#curtains(calls, green), 0, "healer off")
    settings.pvp_cc_timers = false
    frame()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "crowd control off")
    assert_eq(r[1][4].r, 245, "the trinket's left")
    settings.pvp_trinkets = false
    frame()
    assert_eq(#calls, 0, "trinket off")
end }

T[#T + 1] = { "an older JCore without ring_3d: nothing drawn, nothing raised; without the reactions, the local lists", function()
    clock.s = 1000.0
    local e = enemy("e", { dist = 10, hp = 0.5 })
    e.casting = { spell_id = 2060 }
    e.auras = { aura(118, "Polymorph", 8) }
    local drawn = 0
    local old = { circle_3d = function() drawn = drawn + 1 end, line_3d = function() drawn = drawn + 1 end }
    local M, calls, frame = bundle({ e }, { draw = old })
    frame(0)
    frame(0.25)
    assert_eq(drawn, 0, "nothing")
    assert_eq(M.stats().kill, false, "no kill target counted")

    local M2, calls2, frame2 = bundle({ e }, { no_react = true })
    frame2(0)
    assert_eq(#curtains(calls2, red), 1, "kill target, no immunity check")
    assert_eq(#curtains(calls2, green), 1, "Greater Heal from the local list")
    local r = all(calls2, "ring_3d")
    assert_eq(#r, 1, "no trinket ring without pvp.lua; the Polymorph from the local list")
    assert_eq(r[1][4].r, 170, "purple")

    local M3, calls3, frame3, _, P3 = bundle({ e }, { draw = { ring_3d = function() end } })
    frame3(0)
    assert_eq(M3.stats().kill, false, "rings only: no curtain, nothing raised")
    P3.draw = nil
    frame3(0.25)
end }

return T

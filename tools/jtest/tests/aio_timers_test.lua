-- Jambix AIO 1.87.0: fight timers (modules/timers.lua).
--
-- Your damage and healing over time spells on your target as rings that
-- empty, red with 3 s left, a pulse when one runs out on a target still
-- standing; the reactions' next kill as a curtain when it is not your
-- target. Drawn through a recording draw service.

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
local function near(got, want, label)
    if type(got) ~= "number" or math.abs(got - want) > 1e-3 then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local ME = { guid = "me" }
local OTHER = { guid = "someone" }

local function unit(guid, x)
    local u = { guid = guid, pos = { x = x or 10, y = 0, z = 0 }, auras = {}, dead = false }
    u.get_auras = function(self) return self.auras end
    return u
end

--- An aura that ends `left` seconds from now.
local function aura(id, left, caster)
    return { buff_id = id, expire_time = math.floor((clock.s + left) * 1000 + 0.5), caster = caster or ME }
end

local function bundle(opts)
    opts = opts or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = opts.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not opts.curtains_default then
        for _, id in ipairs({ "killnext_on" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local state = { target = opts.target, focus = opts.focus }
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 } },
        combat = { target = function() return state.target end },
        react = { focus = function() return state.focus end },
        units = {
            player = function() return ME end,
            guid = function(o) return o and o.guid end,
            position = function(o) return o and o.pos end,
            combat_reach = function() return 1.5 end,
            is_dead = function(o) return o.dead end,
        },
        draw = { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") },
    }
    package.loaded["jambix_aio/modules/timers"] = nil
    local M = require("jambix_aio/modules/timers")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
    end
    return M, calls, state, frame, settings
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local T = {}

T[#T + 1] = { "your timers on your target: a ring each, emptying, soonest innermost; someone else's are not yours", function()
    clock.s = 1000.0
    local mob = unit("mob")
    mob.auras = { aura(589, 18), aura(14914, 10), aura(589, 12, OTHER) }
    local M, calls, _, frame = bundle({ target = mob })
    frame(0)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "two of yours")
    near(rings[1][3], 1, "just seen: full")
    assert(rings[1][2] < rings[2][2], "the sooner one inside")
    assert_eq(rings[1][5].direction, -1, "emptying")
    frame(5)
    rings = all(calls, "ring_3d")
    near(rings[1][3], 5 / 10, "half of the 10 s one left")
    near(rings[2][3], 13 / 18, "13 of 18 s")
end }

T[#T + 1] = { "red with 3 s left; refreshed, its ring is full again; run out on a standing target, a pulse", function()
    clock.s = 1000.0
    local mob = unit("mob")
    mob.auras = { aura(589, 10) }
    local M, calls, _, frame = bundle({ target = mob })
    frame(0)
    local col = all(calls, "ring_3d")[1][4]
    frame(7.5)
    local warn = all(calls, "ring_3d")[1][4]
    assert(warn.r == 240 and warn.g == 70, "red with 2.5 s left")
    assert(col.r ~= 240 or col.g ~= 70, "not red before")
    mob.auras = { aura(589, 18) }
    frame(0.25)
    near(all(calls, "ring_3d")[1][3], 1, "refreshed: full")
    mob.auras = {}
    frame(0.25)
    assert_eq(#all(calls, "pulse"), 1, "ran out: a pulse")
    assert_eq(all(calls, "pulse")[1][1], mob, "under the target")
    assert_eq(#all(calls, "ring_3d"), 0, "and no ring")
    mob.auras = { aura(589, 10) }
    frame(0.25)
    mob.dead, mob.auras = true, {}
    frame(0.25)
    assert_eq(#all(calls, "pulse"), 0, "a dead target gets no pulse")
end }

T[#T + 1] = { "a new target starts afresh, and at most four rings", function()
    clock.s = 1000.0
    local a, b = unit("a"), unit("b", 20)
    a.auras = { aura(1, 10) }
    b.auras = { aura(1, 8), aura(2, 9), aura(3, 10), aura(4, 11), aura(5, 12) }
    local M, calls, state, frame = bundle({ target = a })
    frame(0)
    state.target = b
    frame(0.25)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 4, "four at most")
    assert_eq(rings[1][1], b.pos, "under the new target")
    assert_eq(#all(calls, "pulse"), 0, "switching target is not a timer running out")
end }

T[#T + 1] = { "kill next: a curtain on the plan's focus when it is not your target, a pulse when the plan changes", function()
    clock.s = 1000.0
    local mine, add, other = unit("mine"), unit("add", 15), unit("other", 18)
    local M, calls, state, frame = bundle({ target = mine, focus = add })
    frame(0)
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "a curtain")
    assert_eq(cs[1][1], add.pos, "on the add")
    assert_eq(#all(calls, "pulse"), 0, "no pulse for the first pick")
    state.focus = other
    frame()
    assert_eq(#all(calls, "pulse"), 1, "the plan changed its mind")
    state.focus = mine
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "your own target: no curtain")
end }

T[#T + 1] = { "switches", function()
    clock.s = 1000.0
    local mob = unit("mob")
    mob.auras = { aura(589, 10) }
    local M, calls, _, frame, settings = bundle({ target = mob, focus = unit("add", 15), settings = { timers_on = false } })
    frame(0)
    assert_eq(#all(calls, "ring_3d"), 0, "timers off")
    assert_eq(#all(calls, "curtain_3d"), 1, "kill next still on")
    settings.timers_on, settings.killnext_on = true, false
    frame()
    assert_eq(#all(calls, "ring_3d"), 1, "timers on")
    assert_eq(#all(calls, "curtain_3d"), 0, "kill next off")
end }

return T

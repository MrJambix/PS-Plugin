-- Jambix AIO 1.85.0: the reactions' marks in the world (modules/react/marks.lua).
--
-- A decision is handed over as R.tick hands it (capture), and the render
-- job draws it through a recording draw service: the kick lined up on a
-- caster, the ring under whoever a reaction acted on, and PvP's vanish spot,
-- the control on you and the player bursting on you.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000 + 0.5) end,
}

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

local ME = { guid = "me", pos = { x = 0, y = 0, z = 0 } }

local function bundle(opts)
    opts = opts or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = opts.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not opts.curtains_default then
        for _, id in ipairs({ "react_curtain_vanish", "react_curtain_burst" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 } },
        units = {
            player = function() return ME end,
            position = function(o) return o and o.pos end,
            combat_reach = function() return 1.5 end,
        },
        draw = opts.no_ring and {} or {
            ring_3d = rec("ring_3d"),
            curtain_3d = rec("curtain_3d"),
            blend = function(a, b, t)
                local function l(x, y) return math.floor(x + (y - x) * t + 0.5) end
                return { r = l(a.r, b.r), g = l(a.g, b.g), b = l(a.b, b.b), a = l(a.a, b.a) }
            end,
        },
    }
    package.loaded["jambix_aio/modules/react/marks"] = nil
    local M = require("jambix_aio/modules/react/marks")(P)
    return M, calls
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function mob(guid, x) return { guid = guid, pos = { x = x or 10, y = 0, z = 0 } } end

--- A cast as world.lua fills one: started in ms, total in seconds.
local function cast(guid, started_ago, total, extra)
    local c = { guid = guid, started = math.floor((clock.s - started_ago) * 1000 + 0.5), total = total,
        remaining = total - started_ago, interruptible = true, channel = false }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function cand(target, c, state, extra)
    local o = { target = target, cast = c, state = state, rule = { category = "interrupt" } }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function W(extra)
    local w = { now = clock.s, player = { unit = ME } }
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end

local T = {}

T[#T + 1] = { "a harmless cast the kick waits on: a ring filling toward the kick point, amber turning green", function()
    clock.s = 1000.0
    local M, calls = bundle()
    local m = mob("a")
    -- 4 s cast, 1 s in: 3 s left; the kick goes with 2 s left, so halfway there.
    M.capture(W(), { cands = { cand(m, cast("a", 1, 4), "waiting") } }, {})
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "one ring")
    local r = rings[1]
    assert_eq(r[1], m.pos, "under the caster")
    near(r[2], 1.5 + 0.3 + 0.9, "outside the ESP's rings")
    near(r[3], 0.5, "halfway to the kick")
    assert_eq(r[4].r, 240, "amber"); assert_eq(r[5].to.g, 220, "turning green")
    assert_eq(r[5].layer, 100, "world layer")
    clock.s = clock.s + 0.5
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    near(all(calls, "ring_3d")[1][3], 0.75, "moves between ticks, from the cast's own clock")
end }

T[#T + 1] = { "chosen: full and green; refused: grey on the cast's own progress; one ring per caster, the most decided", function()
    clock.s = 1000.0
    local M, calls = bundle()
    local a, b = mob("a", 10), mob("b", 20)
    M.capture(W(), { cands = {
        cand(a, cast("a", 1, 4), "waiting", { pet = true }),
        cand(a, cast("a", 1, 4), "selected"),
        cand(b, cast("b", 1, 4), "rejected"),
    } }, {})
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "one per caster")
    local by = {}
    for i = 1, #rings do by[rings[i][1].x] = rings[i] end
    near(by[10][3], 1, "chosen: full"); assert_eq(by[10][4].g, 220, "green")
    near(by[20][3], 0.25, "refused: the cast's progress"); assert_eq(by[20][4].r, 150, "grey")
end }

T[#T + 1] = { "a reaction that acted: a ring opening out under its target, in its kind's colour, gone in under a second", function()
    clock.s = 1000.0
    local M, calls = bundle()
    local m = mob("a")
    local d = { cands = {}, gcd = { target = m, rule = { category = "cc" } }, fast = { rule = { category = "defensive" } } }
    M.capture(W(), d, { gcd = true, fast = true })
    M.render()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "the add, and you")
    local by = {}
    for i = 1, #rings do by[rings[i][1]] = rings[i] end
    assert(by[m.pos], "under the target"); assert(by[ME.pos], "the defensive, under you (no target)")
    assert_eq(by[m.pos][4].r, 170, "crowd control: purple")
    assert_eq(by[ME.pos][4].g, 220, "a defensive: green")
    local first = by[m.pos][2]
    clock.s = clock.s + 0.4
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    local later = all(calls, "ring_3d")[1]
    assert(later[2] > first, "opening out")
    assert(later[4].a < 220, "fading")
    clock.s = clock.s + 0.4
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#all(calls, "ring_3d"), 0, "gone")
end }

T[#T + 1] = { "PvP: the vanish spot, the control on you emptying purple to green, the burster's curtain", function()
    clock.s = 1000.0
    local M, calls = bundle()
    local rogue = mob("rogue", 6)
    local spot = { x = 5, y = 5, z = 0 }
    M.capture(W({ pvp = {
        vanished = { guid = "rogue", at = clock.s, pos = spot },
        control = { name = "Cheap Shot", remaining = 4 },
        burster = { unit = rogue, guid = "rogue" },
    } }), { cands = {} }, {})
    M.render()
    local curtains = all(calls, "curtain_3d")
    assert_eq(#curtains, 2, "the vanish spot and the burster")
    local rings = all(calls, "ring_3d")
    local at = {}
    for i = 1, #rings do at[rings[i][1]] = rings[i] end
    near(at[spot][3], 1, "a fresh vanish: full")
    near(at[ME.pos][3], 1, "the control just landed: full")
    assert_eq(at[ME.pos][4].r, 170, "purple while it holds")
    -- Two seconds on, the same control read again with 2 s left.
    clock.s = clock.s + 2
    M.capture(W({ pvp = { vanished = { guid = "rogue", at = 1000.0, pos = spot },
        control = { name = "Cheap Shot", remaining = 2 } } }), { cands = {} }, {})
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    rings = all(calls, "ring_3d")
    at = {}
    for i = 1, #rings do at[rings[i][1]] = rings[i] end
    near(at[ME.pos][3], 0.5, "half the control left")
    assert(at[ME.pos][4].g > 120, "turning green")
    near(at[spot][3], 1 / 3, "the vanish going stale")
    assert_eq(#all(calls, "curtain_3d"), 1, "no burster now: the vanish spot only")
    clock.s = clock.s + 1.5
    M.capture(W({ pvp = {} }), { cands = {} }, {})
    for i = #calls, 1, -1 do calls[i] = nil end
    M.render()
    assert_eq(#all(calls, "curtain_3d"), 0, "the vanish is old news")
    assert_eq(#all(calls, "ring_3d"), 0, "and the control is over")
end }

T[#T + 1] = { "a mark not refreshed goes; the switch off and a JCore without ring_3d draw nothing", function()
    clock.s = 1000.0
    local M, calls = bundle()
    M.capture(W(), { cands = { cand(mob("a"), cast("a", 1, 4), "waiting") } }, {})
    clock.s = clock.s + 1
    M.render()
    assert_eq(#calls, 0, "a kick not seen for a second is gone")
    local M2, calls2 = bundle({ settings = { react_world = false } })
    M2.capture(W(), { cands = { cand(mob("a"), cast("a", 0, 4), "waiting") } }, {})
    M2.render()
    assert_eq(#calls2, 0, "switched off")
    local M3, calls3 = bundle({ no_ring = true })
    M3.capture(W(), { cands = { cand(mob("a"), cast("a", 0, 4), "waiting") } }, {})
    M3.render()
    assert_eq(#calls3, 0, "an older JCore: nothing, and no error")
end }

T[#T + 1] = { "1.7.6: the vanish and burst curtains are off by default; the vanish ring and the control are not", function()
    clock.s = 1000.0
    local M, calls = bundle({ curtains_default = true })
    local rogue = mob("rogue", 6)
    local spot = { x = 5, y = 5, z = 0 }
    M.capture(W({ pvp = {
        vanished = { guid = "rogue", at = clock.s, pos = spot },
        control = { name = "Cheap Shot", remaining = 4 },
        burster = { unit = rogue, guid = "rogue" },
    } }), { cands = {} }, {})
    M.render()
    assert_eq(#all(calls, "curtain_3d"), 0, "no curtain by default")
    local at = {}
    for _, r in ipairs(all(calls, "ring_3d")) do at[r[1]] = r end
    assert(at[spot], "the vanish spot's ring still")
    assert(at[ME.pos], "and the control on you")
    assert_eq(M.stats().burst, 0, "the burst mark is its curtain: none")
end }

return T

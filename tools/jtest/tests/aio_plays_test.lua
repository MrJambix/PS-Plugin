-- Jambix AIO 1.87.0: rotations and reactions on the ground (modules/plays.lua).
--
-- Your reactions with a condition that must hold for a while, as a ring
-- filling toward the moment they fire, green when armed, a pulse when they
-- fire; the rotation's global cooldown pressed on a unit that is not your
-- target, as a blue curtain and a pulse; your target's ring while the
-- rotation runs. Drawn through a recording draw service, with a fake
-- custom-reactions module that keeps its live state the way custom.lua does.

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

local function unit(guid, x)
    return { guid = guid, pos = { x = x or 10, y = 0, z = 0 }, dead = false }
end

local ME = unit("me", 0)

--- What custom.lua's conditions_pass and propose leave in a reaction's live
--- state on one tick. `holding` is uid -> true for the conditions reading
--- true; `offered` false is "nothing could go".
local function engine_tick(r, rt, holding, offered)
    rt.asked_at = clock.s
    local all = r.match ~= "any"
    local pass = all
    for _, c in ipairs(r.conds) do
        local ok = holding[c.uid] == true
        local need = c.for_s or 0
        local waiting = nil
        if need > 0 and ok then
            local s = rt.since[c.uid]
            if not s or (clock.s - s.seen) > 0.5 then s = { at = clock.s }; rt.since[c.uid] = s end
            s.seen = clock.s
            local held = clock.s - s.at
            if held < need then ok, waiting = false, need - held end
        elseif rt.since[c.uid] then
            rt.since[c.uid] = nil
        end
        rt.conds[c.uid] = { ok = ok, waiting = waiting, at = clock.s }
        if all and not ok then pass = false end
        if not all and ok then pass = true end
    end
    rt.pass = pass
    if not pass then rt.note = nil
    elseif offered == false then rt.note = "nothing could go: Kick is not ready"
    else rt.note = "offered Kick" end
end

local function reaction(id, opts)
    opts = opts or {}
    return {
        id = id, name = opts.name or ("Reaction " .. id), on = opts.on ~= false, match = opts.match or "all",
        notify_alert = opts.notify_alert, notify_color = opts.notify_color,
        conds = opts.conds or { { uid = 1, for_s = 2 } },
        actions = opts.actions or { { uid = 9, kind = "spell", spell = "Kick", target = "caster" } },
    }
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
        for _, id in ipairs({ "plays_rotation" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local state = {
        target = opts.target, reactions = opts.reactions or {}, rt = {}, holding = {}, offered = {},
        who = opts.who or {}, cands = {}, walk = nil, asking = true, list_calls = 0, active = true,
        W = { player = { unit = ME } },
    }
    for _, r in ipairs(state.reactions) do
        state.rt[r.id] = { conds = {}, actions = {}, since = {}, instants = {}, history = {} }
        state.holding[r.id] = {}
    end
    local custom = {
        D = { ALERT_COLOR_BY_KEY = { yellow = { rgb = { 255, 225, 90 } }, red = { rgb = { 255, 90, 90 } } } },
        list = function()
            state.list_calls = state.list_calls + 1
            return state.reactions
        end,
        runtime = function(id) return state.rt[id] end,
        latest_W = function() return state.W end,
        master_on = function() return true end,
        resolve_target = function(word, W)
            if word == "self" then return W.player.unit end
            if word == "target" then return state.target end
            return state.who[word]
        end,
    }
    local draw = opts.draw or { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") }
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = { LAYER = { WORLD = 100 } },
        combat = { target = function() return state.target end },
        react = { custom = custom },
        rotation = { last_candidates = function() return state.cands end },
        rotation_active = function() return state.active end,
        units = {
            player = function() return ME end,
            guid = function(o) return o and o.guid end,
            position = function(o) return o and o.pos end,
            combat_reach = function() return 1.5 end,
            is_dead = function(o) return o.dead end,
        },
        draw = draw,
    }
    if opts.color == false then P.color = nil end
    if opts.react == false then P.react = nil end
    if opts.rotation == false then P.rotation, P.rotation_active = nil, nil end
    if opts.patch then opts.patch(P, custom) end
    package.loaded["jambix_aio/modules/plays"] = nil
    local M = require("jambix_aio/modules/plays")(P)
    --- One frame: the engine's tick (your reactions asked, the rotation's
    --- walk), then the render job.
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        if state.asking then
            for _, r in ipairs(state.reactions) do
                engine_tick(r, state.rt[r.id], state.holding[r.id], state.offered[r.id])
            end
        end
        if state.walk then state.cands = state.walk() end
        M.render()
    end
    return M, calls, state, frame, settings
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function frames(frame, n, dt)
    for _ = 1, n do frame(dt) end
end

local T = {}

T[#T + 1] = { "a reaction holding: a ring under its target filling amber to green, full green armed, a pulse as it fires", function()
    clock.s = 1000.0
    local caster = unit("caster", 20)
    local r = reaction(1, { actions = {
        { uid = 8, kind = "alert", text = "Kick it" },          -- not about a unit: the next one is looked at
        { uid = 9, kind = "spell", spell = "Kick", target = "caster" },
    } })
    local M, calls, state, frame = bundle({ reactions = { r }, who = { caster = caster } })
    state.holding[1] = { [1] = true }
    frame(0)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "a ring")
    assert_eq(rings[1][1], caster.pos, "under the caster its kick is for")
    near(rings[1][3], 0, "just began to hold")
    local wait, opts = rings[1][4], rings[1][5]
    assert(wait.r == 240 and wait.g == 180, "amber")
    assert(opts.to.r == 100 and opts.to.g == 220, "filling to green")
    assert_eq(opts.layer, 100, "on the world layer")
    frames(frame, 4)
    near(all(calls, "ring_3d")[1][3], 0.5, "1 of its 2 s")
    frames(frame, 4)
    rings = all(calls, "ring_3d")
    near(rings[1][3], 1, "held long enough")
    assert(rings[1][4].r == 100 and rings[1][4].g == 220, "armed: green")
    assert_eq(M.stats().armed, 1, "counted armed")
    assert_eq(#all(calls, "pulse"), 0, "no pulse before it fires")
    state.rt[1].last_fire = clock.s
    frame()
    local pulses = all(calls, "pulse")
    assert_eq(#pulses, 1, "fired: a pulse")
    assert_eq(pulses[1][1], caster, "under the caster")
    assert(pulses[1][2].r == 240 and pulses[1][2].g == 240, "white: it has no alert of its own")
    assert_eq(#all(calls, "ring_3d"), 0, "fired: its ring is done")
    frame()
    assert_eq(#all(calls, "pulse"), 0, "one pulse a fire")
    assert_eq(#all(calls, "ring_3d"), 0, "still holding, already fired: nothing")
    -- The condition stops and begins again: a new ring.
    state.holding[1] = {}
    frame()
    state.holding[1] = { [1] = true }
    frame()
    near(all(calls, "ring_3d")[1][3], 0, "a new hold fills from empty")
end }

T[#T + 1] = { "its alert's colour on the pulse; grey when nothing of it can go; an item or Lua is under you", function()
    clock.s = 1000.0
    local r1 = reaction(1, { notify_alert = true, conds = { { uid = 1, for_s = 1 } },
        actions = { { uid = 9, kind = "item", item = "healthstone" } } })
    local r2 = reaction(2, { conds = { { uid = 1, for_s = 1 } }, actions = { { uid = 9, mode = "lua", code = "return 'Kick'" } } })
    local M, calls, state, frame = bundle({ reactions = { r1, r2 } })
    state.holding[1], state.holding[2] = { [1] = true }, { [1] = true }
    state.offered[1] = false
    frame(0)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "two rings")
    assert_eq(rings[1][1], ME.pos, "the item: under you")
    assert_eq(rings[2][1], ME.pos, "Lua: under you")
    assert(rings[2][2] > rings[1][2], "the second one outside the first")
    frames(frame, 4)
    rings = all(calls, "ring_3d")
    near(rings[1][3], 1, "would fire")
    assert(rings[1][4].r == 150 and rings[1][4].g == 150, "but nothing can go: grey")
    assert(rings[2][4].r == 100 and rings[2][4].g == 220, "the other armed: green")
    state.rt[1].last_fire = clock.s
    frame()
    local pulses = all(calls, "pulse")
    assert_eq(#pulses, 1, "fired")
    assert_eq(pulses[1][1], ME, "under you")
    assert(pulses[1][2].r == 255 and pulses[1][2].g == 225 and pulses[1][2].b == 90, "its alert's yellow")
end }

T[#T + 1] = { "not about to fire: another condition failing, any-match, switched off, no longer asked", function()
    clock.s = 1000.0
    local mob = unit("mob", 15)
    local r1 = reaction(1, { conds = { { uid = 1, for_s = 2 }, { uid = 2 } },
        actions = { { uid = 9, kind = "spell", spell = "Kick" } } })
    local r2 = reaction(2, { match = "any", conds = { { uid = 1, for_s = 2 }, { uid = 2, for_s = 4 } },
        actions = { { uid = 9, kind = "spell", spell = "Kick" } } })
    local M, calls, state, frame = bundle({ reactions = { r1, r2 }, target = mob })
    state.holding[1] = { [1] = true }
    frame(0)
    assert_eq(#all(calls, "ring_3d"), 0, "all: the other condition fails, it is not about to fire")
    state.holding[1] = { [1] = true, [2] = true }
    frames(frame, 4)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "both hold: a ring")
    assert_eq(rings[1][1], mob.pos, "a spell with no target row: your target")
    near(rings[1][3], 0.5, "the hold counted from when it began")
    state.holding[2] = { [2] = true }
    frames(frame, 4)
    state.holding[2] = { [1] = true, [2] = true }
    frame()
    rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "any: a ring as well")
    near(rings[2][3], 1.0 / 4, "the condition furthest along")
    r1.on = false
    frame()
    assert_eq(#all(calls, "ring_3d"), 1, "switched off: no ring")
    state.asking = false
    frames(frame, 3)
    assert_eq(#all(calls, "ring_3d"), 0, "the engine stopped asking: nothing")
end }

T[#T + 1] = { "your reactions are read at most five times a second", function()
    clock.s = 1000.0
    local r = reaction(1, { actions = { { uid = 9, kind = "item" } } })
    local M, calls, state, frame = bundle({ reactions = { r } })
    state.holding[1] = { [1] = true }
    frame(0)
    local before = state.list_calls
    local drawn = 0
    for _ = 1, 20 do
        frame(0.05)
        drawn = drawn + #all(calls, "ring_3d")
    end
    assert(state.list_calls - before <= 5, "five reads in a second, not " .. (state.list_calls - before))
    assert_eq(drawn, 20, "the ring drawn every frame")
end }

T[#T + 1] = { "the rotation's pick on another unit: a blue curtain and a pulse as pressed; nothing on your target", function()
    clock.s = 1000.0
    local mob, friend, add = unit("mob", 15), unit("friend", 5), unit("add", 25)
    local M, calls, state, frame = bundle({ target = mob })
    local pressed = nil
    state.walk = function()
        local out = { { rule = { "Smite" }, target = mob, state = "outscored", fast = false, score = 49 } }
        if pressed then table.insert(out, 1, pressed); pressed = nil end
        return out
    end
    frame(0)
    pressed = { rule = { "Renew" }, target = friend, state = "pressed", fast = false, score = 50 }
    frame()
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "a curtain")
    assert_eq(cs[1][1], friend.pos, "round the friend it heals")
    assert(cs[1][3].b == 250 and cs[1][3].r == 90, "blue")
    local pulses = all(calls, "pulse")
    assert_eq(#pulses, 1, "a pulse as it is pressed")
    assert_eq(pulses[1][1], friend, "under the friend")
    frames(frame, 4)
    assert_eq(#all(calls, "curtain_3d"), 1, "held after the press")
    assert_eq(#all(calls, "pulse"), 0, "one pulse")
    frames(frame, 3)
    assert_eq(#all(calls, "curtain_3d"), 0, "gone a moment later")
    pressed = { rule = { name = "Corruption" }, target = add, state = "pressed", fast = false }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 1, "a dot spread to another mob")
    assert_eq(M.stats().pressed, 2, "two presses pulsed")
    pressed = { rule = { "Shadow Bolt" }, target = mob, state = "pressed", fast = false }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "on your target: the rotation moved on, nothing")
    assert_eq(#all(calls, "pulse"), 0, "and no pulse")
    pressed = { rule = { "Shield Bash" }, target = add, state = "pressed", fast = true }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "off the global cooldown: not the pick")
    pressed = { rule = { "Demon Armor" }, target = ME, state = "pressed", fast = false }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "on you: nothing")
    pressed = { rule = { "Renew" }, target = friend, state = "pressed", fast = false }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 1, "the friend again")
    state.target = friend
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "you targeted it: nothing")
end }

T[#T + 1] = { "your target's ring while the rotation runs: off by default", function()
    clock.s = 1000.0
    local mob = unit("mob", 15)
    local M, calls, state, frame, settings = bundle({ target = mob })
    state.walk = function() return {} end
    frames(frame, 2)
    assert_eq(#all(calls, "ring_3d"), 0, "off by default")
    settings.plays_target_ring = true
    frame()
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "switched on: a ring")
    assert_eq(rings[1][1], mob.pos, "under your target")
    near(rings[1][3], 1, "whole")
    assert(rings[1][5].inner >= 0.9, "thin")
    state.walk = nil
    frames(frame, 3)
    assert_eq(#all(calls, "ring_3d"), 0, "the walk stopped: not running")
    state.walk = function() return {} end
    frame()
    assert_eq(#all(calls, "ring_3d"), 1, "running again")
    state.active = false
    frame()
    assert_eq(#all(calls, "ring_3d"), 0, "the rotation's key off: nothing")
end }

T[#T + 1] = { "switches", function()
    clock.s = 1000.0
    local mob, friend = unit("mob", 15), unit("friend", 5)
    local r = reaction(1, { actions = { { uid = 9, kind = "item" } } })
    local M, calls, state, frame, settings = bundle({ reactions = { r }, target = mob, settings = { plays_on = false } })
    state.holding[1] = { [1] = true }
    local pressing = true
    state.walk = function()
        if pressing then return { { rule = { "Renew" }, target = friend, state = "pressed", fast = false } } end
        return {}
    end
    frames(frame, 3)
    assert_eq(#calls, 0, "all off: nothing")
    settings.plays_on = nil
    frames(frame, 2)
    assert_eq(#all(calls, "ring_3d"), 1, "on: the reaction's ring")
    assert_eq(#all(calls, "curtain_3d"), 1, "on: the pick")
    settings.plays_reactions = false
    frame()
    assert_eq(#all(calls, "ring_3d"), 0, "reactions off")
    assert_eq(#all(calls, "curtain_3d"), 1, "the pick still on")
    settings.plays_reactions, settings.plays_rotation = nil, false
    frame()
    assert_eq(#all(calls, "ring_3d"), 1, "the reaction back")
    assert_eq(#all(calls, "curtain_3d"), 0, "rotation off")
    assert_eq(#all(calls, "pulse"), 0, "and no pulse for its presses")
end }

T[#T + 1] = { "no reactions, no rotation, an older JCore, a module that raises: nothing drawn, nothing raised", function()
    clock.s = 1000.0
    local friend = unit("friend", 5)
    local press = function() return { { rule = { "Renew" }, target = friend, state = "pressed", fast = false } } end

    local M, calls, state, frame = bundle({ react = false, rotation = false, settings = { plays_target_ring = true } })
    frames(frame, 3)
    assert_eq(#calls, 0, "neither module: nothing")
    assert_eq(M.stats().err, nil, "and no error")

    local r = reaction(1, { actions = { { uid = 9, kind = "item" } } })
    M, calls, state, frame = bundle({ reactions = { r }, draw = {}, settings = { plays_target_ring = true } })
    state.holding[1], state.walk = { [1] = true }, press
    frames(frame, 10)
    state.rt[1].last_fire = clock.s
    frames(frame, 2)
    assert_eq(M.stats().err, nil, "a JCore without ring_3d, curtain_3d or pulse: no error")
    assert_eq(M.stats().rings + M.stats().fired + M.stats().pressed, 0, "and nothing drawn")

    local rec = {}
    M, calls, state, frame = bundle({ reactions = { r }, color = false,
        draw = { ring_3d = function(...) rec[#rec + 1] = { ... } end } })
    state.holding[1], state.walk = { [1] = true }, press
    frames(frame, 3)
    assert(#rec > 0, "rings only: the rings still drawn")
    assert(rec[1][4].r == 240 and rec[1][4].g == 180, "plain colours without P.color")
    assert_eq(M.stats().err, nil, "no pulse or curtain asked for")

    local boom = function() error("boom") end
    M, calls, state, frame = bundle({ reactions = { r }, target = unit("mob"), settings = { plays_target_ring = true },
        patch = function(P, custom)
            custom.list, custom.runtime, custom.resolve_target = boom, boom, boom
            P.rotation.last_candidates, P.combat.target, P.units.position = boom, boom, boom
        end })
    state.holding[1] = { [1] = true }
    frames(frame, 3)
    assert_eq(#calls, 0, "everything raising: nothing drawn")
    assert_eq(M.stats().err, nil, "and nothing raised")

    -- A kick on a caster: resolve_target and latest_W are what would find it.
    M, calls, state, frame = bundle({ reactions = { reaction(1) }, who = { caster = unit("caster", 20) },
        patch = function(P, custom)
            custom.latest_W, custom.resolve_target, custom.D, custom.master_on = nil, nil, nil, nil
        end })
    state.holding[1] = { [1] = true }
    frame(0)
    assert_eq(all(calls, "ring_3d")[1][1], ME.pos, "an older custom.lua: under you")
end }

return T

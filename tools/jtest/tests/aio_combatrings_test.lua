-- Jambix AIO 1.89.0: combat rings (modules/combatrings.lua).
--
-- Your swing and your global cooldown as rings at your feet; your target's
-- health as a ring with its time to die beside it; your execute in range as
-- a red ring, a red curtain and a pulse. Drawn through a recording draw
-- service, and through the real world layer over one.

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

local ME = { guid = "me", reach = 1.5 }
ME.get_unit_ranged_damage = function() return { speed = 0 } end   -- Forever: zeros

local function mob(guid, x)
    return { guid = guid, pos = { x = x or 10, y = 0, z = 0 }, reach = 1.5 }
end

--- A fake bundle. `o.world` puts the real world layer over the recording draw.
local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not o.curtains_default then
        for _, id in ipairs({ "cr_execute_curtain" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local handlers = {}
    local state = {
        fight = o.fight ~= false, attacking = o.attacking ~= false, speed = o.speed or 2.0, gcd = 0,
        target = o.target, hp = {}, dead = {}, snap = {}, rows = {}, known = o.known or {},
    }
    local draw = o.draw
    if draw == nil then
        draw = { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse"), text_3d = rec("text_3d") }
    end
    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {
            LAYER = { WORLD = 100, OVERLAY = 400 },
            on = function(name, fn) handlers[name] = fn end,
            player = {
                gcd = function() return state.gcd end,
                is_auto_attacking = function() return state.attacking end,
                attack_speed = function() return state.speed end,
            },
            enemies = { get = function(u) return state.rows[u] end },
            spells = { name = function() return "" end },
        },
        combat = {
            in_combat = function() return state.fight end,
            target = function() return state.target end,
        },
        units = {
            player = function() return ME end,
            player_position = function() return { x = 0, y = 0, z = 0 } end,
            guid = function(u) return u and u.guid end,
            position = function(u) return u and u.pos end,
            combat_reach = function(u) return u and u.reach or 1.5 end,
            is_dead = function(u) return state.dead[u] == true end,
            health_fraction = function(u) return state.hp[u] or 1 end,
            snapshot = function(u) return state.snap[u] end,
        },
        spellbook = { known = function(name) return state.known[name] == true end },
        draw = draw,
    }
    if o.no_ctx then P.ctx = {} end
    if o.world then
        package.loaded["jambix_aio/modules/worldlayer"] = nil
        P.worldmarks = require("jambix_aio/modules/worldlayer")(P)
    end
    package.loaded["jambix_aio/modules/combatrings"] = nil
    local M = require("jambix_aio/modules/combatrings")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
        if P.worldmarks then P.worldmarks.flush() end
    end
    local function fire(name, arg)
        local fn = handlers[name]
        if fn then fn(arg) end
    end
    return M, calls, state, frame, fire, settings, P
end

local function all(calls, name, module)
    local out = {}
    for i = 1, #calls do
        local c = calls[i]
        if c.name == name and (not module or (c[5] and c[5].module == module) or (c[4] and c[4].module == module)) then
            out[#out + 1] = c
        end
    end
    return out
end

local function swing_cast(fire) fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-2-0-0-0-6603-01", 6603 }) end

local T = {}

-- --- your swing -----------------------------------------------------------------------

T[#T + 1] = { "your swing: empty as it goes out, full when the next is due; at your feet, in the swing lane, no unit", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire = bundle()
    swing_cast(fire)
    frame(0)
    local r = all(calls, "ring_3d", "swing")
    assert_eq(#r, 1, "a ring")
    near(r[1][3], 0, "just swung: empty")
    assert_eq(r[1][1].x, 0, "at your feet")
    near(r[1][2], 1.8 + 1.0 + 0.25, "the swing lane under you")
    assert_eq(r[1][5].unit, nil, "no unit under yourself")
    assert_eq(r[1][5].lane, "swing", "lane")
    assert_eq(r[1][5].prio, "info", "prio")
    assert_eq(M.stats().swing_source, "cast", "from the cast report")
    assert_eq(M.stats().swing_guess, false, "not a guess")
    frame(1.0)
    near(all(calls, "ring_3d", "swing")[1][3], 0.5, "half way round a 2.0 s weapon")
    frame(1.0)
    near(all(calls, "ring_3d", "swing")[1][3], 1, "due: full")
    frame(0.2)
    near(all(calls, "ring_3d", "swing")[1][3], 1, "a little late: still full, not yet a guess")
    swing_cast(fire)
    frame(0)
    near(all(calls, "ring_3d", "swing")[1][3], 0, "the next swing: empty again")
    swing_cast(fire)
    frame(0.1)
    near(all(calls, "ring_3d", "swing")[1][3], 0.05, "one swing told twice is one")
end }

T[#T + 1] = { "past the due time while attacking: guessed and dimmer, for three swings; the attack off, nothing", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire = bundle()
    swing_cast(fire)
    frame(0)
    local real_col = all(calls, "ring_3d", "swing")[1][4]
    frame(2.5)
    local r = all(calls, "ring_3d", "swing")
    assert_eq(#r, 1, "still a ring")
    near(r[1][3], 0.25, "the guess goes round again")
    assert(r[1][4].a < real_col.a, "dimmer")
    assert_eq(M.stats().swing_guess, true, "a guess")
    frame(5.0)
    assert_eq(#all(calls, "ring_3d", "swing"), 1, "7.5 s: inside three guessed swings")
    frame(0.75)
    assert_eq(#all(calls, "ring_3d", "swing"), 0, "8.25 s: past them, nothing")
    swing_cast(fire)
    frame(0)
    state.attacking = false
    frame(2.5)
    assert_eq(#all(calls, "ring_3d", "swing"), 0, "attack off and late: nothing")
end }

T[#T + 1] = { "no swing ever reported: the attack going on is the clock, a guess for as long as it is on", function()
    clock.s = 1000.0
    local M, calls, state, frame = bundle()
    frame(0)
    local r = all(calls, "ring_3d", "swing")
    assert_eq(#r, 1, "a ring from the start")
    near(r[1][3], 0, "empty")
    assert_eq(M.stats().swing_source, "start", "the start")
    assert_eq(M.stats().swing_guess, true, "a guess")
    frame(1.0)
    near(all(calls, "ring_3d", "swing")[1][3], 0.5, "round with the weapon")
    frame(19.0)
    assert_eq(#all(calls, "ring_3d", "swing"), 1, "twenty seconds on, still going round")
    state.attacking = false
    frame(1.25)
    assert_eq(#all(calls, "ring_3d", "swing"), 0, "attack off: gone")
end }

T[#T + 1] = { "a real swing just after the start confirms it", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire = bundle()
    frame(0)
    assert_eq(M.stats().swing_source, "start", "the start")
    clock.s = clock.s + 0.1
    swing_cast(fire)
    frame(0)
    assert_eq(M.stats().swing_source, "cast", "the swing")
    assert_eq(M.stats().swing_guess, false, "no longer a guess")
    assert_eq(M.stats().swings, 1, "one real swing counted")
end }

T[#T + 1] = { "out of a fight, switched off, or no unit: no swing ring", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire, settings, P = bundle({ fight = false })
    swing_cast(fire)
    frame(0)
    assert_eq(#all(calls, "ring_3d", "swing"), 0, "not in a fight")
    state.fight = true
    settings.cr_swing = false
    swing_cast(fire)
    frame(0)
    assert_eq(#all(calls, "ring_3d", "swing"), 0, "switched off")
    settings.cr_swing = nil
    settings.combatrings_on = false
    frame(0)
    assert_eq(#calls, 0, "all switched off: nothing at all")
    settings.combatrings_on = nil
    state.gcd = 1.5
    P.units.player = function() return nil end
    frame(0)
    assert_eq(#calls, 0, "a loading screen (no player): nothing")
end }

T[#T + 1] = { "Era's combat log: your main-hand swings, hit or missed; the off hand and anyone else's are not", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire = bundle()
    local function log(sub, src, off)
        local a = { 1, sub, false, src, "x", 0, 0, "mob", "Mob", 0, 0 }
        if sub == "SWING_DAMAGE" then a[12] = 50; a[21] = off else a[12] = "PARRY"; a[13] = off end
        fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", a)
    end
    log("SWING_DAMAGE", "me", false)
    frame(0)
    assert_eq(M.stats().swing_source, "log", "the log's swing")
    near(all(calls, "ring_3d", "swing")[1][3], 0, "empty")
    clock.s = clock.s + 1.0
    log("SWING_DAMAGE", "me", true)
    log("SWING_DAMAGE", "someone", false)
    fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {})   -- Forever: no arguments
    frame(0)
    near(all(calls, "ring_3d", "swing")[1][3], 0.5, "the off hand and someone else's left it alone")
    log("SWING_MISSED", "me", nil)
    frame(0)
    near(all(calls, "ring_3d", "swing")[1][3], 0, "a parried swing is a swing")
end }

T[#T + 1] = { "the loader's cast callback: yours by caster; a shot's gap is its length when the bow will not say", function()
    clock.s = 1000.0
    local M, calls, state, frame, fire = bundle()
    local them = mob("them")
    fire("jcore.spell.cast", { spell_id = 75, caster = ME })
    frame(0)
    clock.s = clock.s + 2.3
    fire("jcore.spell.cast", { spell_id = 75, caster = ME })
    frame(0)
    near(all(calls, "ring_3d", "swing")[1][3], 0, "the second shot")
    frame(1.15)
    near(all(calls, "ring_3d", "swing")[1][3], 0.5, "half of the 2.3 s seen between shots")
    fire("jcore.spell.cast", { spell_id = 75, caster = them })
    fire("jcore.spell.cast", { spell_id = 6603 })
    fire("jcore.spell.cast", { spell_id = 133, caster = ME })
    frame(0)
    near(all(calls, "ring_3d", "swing")[1][3], 0.5, "someone else's, one with no caster, and a Fireball: none of them")
end }

T[#T + 1] = { "the Swing Timer addon, when it is loaded: its last swing and when the next is due", function()
    clock.s = 1000.0
    core.addons = { swing_timer = {
        is_loaded = function() return true end,
        get_player_mainhand_info = function() return { last_swing = 1000.0, expiration_time = 1002.6 } end,
        get_player_ranged_info = function() return {} end,
    } }
    local ok, err = pcall(function()
        local M, calls, state, frame = bundle()
        frame(1.3)
        near(all(calls, "ring_3d", "swing")[1][3], 0.5, "1.3 of the addon's 2.6 s")
        assert_eq(M.stats().swing_source, "addon", "the addon")
    end)
    core.addons = nil
    assert(ok, err)
end }

T[#T + 1] = { "the loader's auto-attack helper: its last attack and its next", function()
    clock.s = 1000.0
    package.loaded["common/utility/auto_attack_helper"] = {
        get_last_attack_core_time = function(self, u) return 1000.0 end,
        get_next_attack_core_time = function(self, u) return 1001.8 end,
    }
    local ok, err = pcall(function()
        local M, calls, state, frame = bundle()
        frame(0.9)
        near(all(calls, "ring_3d", "swing")[1][3], 0.5, "0.9 of the helper's 1.8 s")
        assert_eq(M.stats().swing_source, "helper", "the helper")
    end)
    package.loaded["common/utility/auto_attack_helper"] = nil
    assert(ok, err)
end }

-- --- your global cooldown ----------------------------------------------------------------

T[#T + 1] = { "your GCD: a thin ring emptying from what was first seen; nothing while it is free", function()
    clock.s = 1000.0
    local M, calls, state, frame = bundle({ fight = false })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "gcd"), 0, "free: nothing")
    state.gcd = 1.5
    frame(0)
    local r = all(calls, "ring_3d", "gcd")
    assert_eq(#r, 1, "running: a ring, in a fight or not")
    near(r[1][3], 1, "full")
    near(r[1][2], 1.8 + 0.65 + 0.25, "the gcd lane under you")
    assert_eq(r[1][5].direction, -1, "emptying")
    assert(r[1][5].inner > 1 - 0.25 / r[1][2], "thinner than a lane")
    assert_eq(r[1][5].unit, nil, "no unit")
    state.gcd = 0.75
    frame(0.75)
    near(all(calls, "ring_3d", "gcd")[1][3], 0.5, "half left")
    state.gcd = 0
    frame(0.75)
    assert_eq(#all(calls, "ring_3d", "gcd"), 0, "over")
    state.gcd = 1.0
    frame(0)
    near(all(calls, "ring_3d", "gcd")[1][3], 1, "the next one is its own length")
    state.gcd = 0.4
    frame(0.6)
    state.gcd = 0.95
    frame(0)
    near(all(calls, "ring_3d", "gcd")[1][3], 1, "went up again: a new one")
    assert_eq(M.stats().gcd, true, "counted")
end }

-- --- time to die ---------------------------------------------------------------------------

T[#T + 1] = { "time to die: a ring as full as its health under a hostile target, and the seconds at its feet", function()
    clock.s = 1000.0
    local m = mob("m")
    local M, calls, state, frame = bundle({ target = m })
    state.snap[m] = { is_enemy = true }
    state.hp[m] = 0.6
    state.rows[m] = { ttd = 12.4 }
    frame(0)
    local r = all(calls, "ring_3d", "ttd")
    assert_eq(#r, 1, "a ring")
    near(r[1][3], 0.6, "its health")
    assert_eq(r[1][1], m.pos, "under it")
    assert_eq(r[1][5].unit, m, "the unit, for the lane and the wall")
    assert_eq(r[1][5].lane, "ttd", "the ttd lane")
    assert_eq(r[1][5].prio, "info", "information")
    assert(r[1][4].r ~= 240 or r[1][4].g ~= 60, "not red")
    local t = all(calls, "text_3d")
    assert_eq(#t, 1, "the seconds")
    assert_eq(t[1][2], "12 s", "rounded")
    near(t[1][1].x, 10 - r[1][2], "on the ring's edge toward you")
    state.rows[m] = { ttd = 7.25 }
    frame(0)
    assert_eq(all(calls, "text_3d")[1][2], "7.3 s", "a tenth under ten")
    state.rows[m] = { ttd = math.huge }
    frame(0)
    assert_eq(#all(calls, "text_3d"), 0, "no estimate yet: no number")
    assert_eq(#all(calls, "ring_3d", "ttd"), 1, "but the ring")
    state.rows[m] = nil
    frame(0)
    assert_eq(#all(calls, "ring_3d", "ttd"), 1, "an enemy in the sweep with no tracker row still has its ring")
end }

T[#T + 1] = { "not under a friend, yourself, the dead or the unknown; out of a fight only once it is hurt", function()
    clock.s = 1000.0
    local m = mob("m")
    local M, calls, state, frame, _, settings = bundle({ target = m, attacking = false })
    state.snap[m] = { is_ally = true }
    state.hp[m] = 0.5
    frame(0)
    assert_eq(#calls, 0, "a friend: nothing")
    state.snap[m] = { is_self = true }
    frame(0)
    assert_eq(#calls, 0, "yourself: nothing")
    state.snap[m] = nil
    frame(0)
    assert_eq(#calls, 0, "unknown: nothing")
    state.rows[m] = { ttd = 5 }
    frame(0)
    assert_eq(#all(calls, "ring_3d", "ttd"), 1, "not swept, but tracked as an enemy: shown")
    state.dead[m] = true
    frame(0)
    assert_eq(#calls, 0, "dead: nothing")
    state.dead[m] = nil
    state.fight = false
    state.hp[m] = 1
    frame(0)
    assert_eq(#all(calls, "ring_3d", "ttd"), 0, "out of a fight at full health: nothing")
    state.hp[m] = 0.7
    frame(0)
    assert_eq(#all(calls, "ring_3d", "ttd"), 1, "hurt: shown")
    settings.cr_ttd = false
    frame(0)
    assert_eq(#calls, 0, "switched off")
    settings.cr_ttd = nil
    settings.world_on = false
    frame(0)
    assert_eq(#all(calls, "text_3d"), 0, "world marks off: no number either")
end }

-- --- execute ---------------------------------------------------------------------------------

T[#T + 1] = { "execute: in range the ring turns red, a red curtain stands round it, a pulse the moment it crosses", function()
    clock.s = 1000.0
    local m = mob("m")
    local M, calls, state, frame = bundle({ target = m, known = { ["Execute"] = true } })
    state.snap[m] = { is_enemy = true }
    state.rows[m] = { ttd = 4 }
    state.hp[m] = 0.25
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 0, "25%: not yet")
    state.hp[m] = 0.18
    frame(0)
    local r = all(calls, "ring_3d", "ttd")
    assert_eq(r[1][4].r, 240, "red ring"); assert_eq(r[1][4].g, 60, "red ring")
    local c = all(calls, "curtain_3d")
    assert_eq(#c, 1, "a curtain")
    assert_eq(c[1][1], m.pos, "round the target")
    assert_eq(c[1][4].prio, "warn", "a warning")
    assert_eq(c[1][4].module, "execute", "module")
    assert_eq(c[1][4].unit, m, "under the unit")
    assert(c[1][4].fill > 0, "filled")
    assert(c[1][2] > r[1][2], "standing on the ring")
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "a pulse")
    assert_eq(p[1][1], m, "under the target")
    assert_eq(p[1][3].prio, "warn", "a warning")
    assert_eq(M.stats().execute_spell, "Execute", "which")
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 1, "the curtain stays")
    assert_eq(#all(calls, "pulse"), 0, "the pulse is once")
    state.hp[m] = 0.3
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 0, "healed out of range")
    state.hp[m] = 0.15
    frame(0)
    assert_eq(#all(calls, "pulse"), 1, "back in: a pulse again")
    local n = mob("n", 20)
    state.snap[n], state.hp[n], state.target = { is_enemy = true }, 0.1, n
    frame(0)
    assert_eq(#all(calls, "pulse"), 1, "a new target already in range: a pulse")
end }

T[#T + 1] = { "each class's line: Drain Soul at 25%; a rogue has none; the switch", function()
    clock.s = 1000.0
    local m = mob("m")
    local M, calls, state, frame = bundle({ target = m, known = { ["Drain Soul"] = true } })
    state.snap[m] = { is_enemy = true }
    state.hp[m] = 0.26
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 0, "26%: not yet")
    state.hp[m] = 0.24
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 1, "24%: the shard")
    local M2, calls2, state2, frame2 = bundle({ target = m, known = { ["Sinister Strike"] = true } })
    state2.snap[m], state2.hp[m] = { is_enemy = true }, 0.05
    frame2(0)
    assert_eq(#all(calls2, "curtain_3d"), 0, "a rogue: none")
    assert(all(calls2, "ring_3d", "ttd")[1][4].r ~= 240, "and the ring is not red")
    local M3, calls3, state3, frame3, _, settings3 = bundle({ target = m, known = { ["Hammer of Wrath"] = true } })
    state3.snap[m], state3.hp[m] = { is_enemy = true }, 0.1
    settings3.cr_execute = false
    frame3(0)
    assert_eq(#all(calls3, "curtain_3d"), 0, "execute off: no curtain")
    assert(all(calls3, "ring_3d", "ttd")[1][4].r ~= 240, "nor a red ring")
    local M4, calls4, state4, frame4, _, settings4 = bundle({ target = m, known = { ["Hammer of Wrath"] = true } })
    state4.snap[m], state4.hp[m] = { is_enemy = true }, 0.1
    settings4.cr_ttd = false
    frame4(0)
    assert_eq(#all(calls4, "ring_3d", "ttd"), 0, "time to die off: no ring")
    assert_eq(#all(calls4, "curtain_3d"), 1, "but the execute curtain")
    assert_eq(#all(calls4, "pulse"), 1, "and its pulse")
end }

-- --- through the world layer, and an older JCore --------------------------------------------------

T[#T + 1] = { "through the world layer: lanes, the extra options gone, and the curtain kept over the budget", function()
    clock.s = 1000.0
    local m = mob("m")
    m.reach = 2.0
    -- 1.7.6: the execute curtain has its own switch, off by default.
    local M, calls, state, frame, fire, settings = bundle({ target = m, world = true, known = { ["Execute"] = true },
        settings = { cr_execute_curtain = true } })
    state.snap[m], state.hp[m], state.gcd = { is_enemy = true }, 0.1, 1.5
    swing_cast(fire)
    frame(0)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 3, "gcd, swing and ttd")
    local by_r = {}
    for i = 1, #rings do by_r[#by_r + 1] = rings[i][2] end
    table.sort(by_r)
    near(by_r[1], 1.8 + 0.65 + 0.25, "your gcd")
    near(by_r[2], 1.8 + 1.0 + 0.25, "your swing")
    near(by_r[3], 2.3 + 1.05 + 0.25, "its ttd lane, from its own reach")
    for i = 1, #rings do
        local o = rings[i][5]
        assert(o.prio == nil and o.module == nil and o.unit == nil and o.lane == nil, "the layer's options gone")
    end
    assert_eq(#all(calls, "curtain_3d"), 1, "the curtain")
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "the pulse, through the layer")
    assert_eq(p[1][3].to, nil, "no yards in `to` for the layer to take for a colour")
    settings.world_budget = 1
    state.hp[m] = 0.12
    frame(0)
    assert_eq(#all(calls, "ring_3d"), 0, "every ring dropped at a budget of one")
    assert_eq(#all(calls, "curtain_3d"), 1, "a warning is never dropped")
end }

T[#T + 1] = { "an older JCore: missing draw calls draw nothing and raise nothing", function()
    clock.s = 1000.0
    local m = mob("m")
    -- No ring_3d at all, under the world layer.
    local M, calls, state, frame, fire = bundle({ target = m, world = true, draw = {}, known = { ["Execute"] = true } })
    state.snap[m], state.hp[m], state.gcd, state.rows[m] = { is_enemy = true }, 0.1, 1.5, { ttd = 3 }
    swing_cast(fire)
    frame(0)
    assert_eq(#calls, 0, "nothing")
    -- No draw service and no layer.
    local M2, calls2, state2, frame2 = bundle({ target = m, draw = false })
    frame2(0)
    assert_eq(#calls2, 0, "nothing")
    -- Rings only: no curtain, pulse or text.
    local rec = {}
    local M3, calls3, state3, frame3 = bundle({ target = m, known = { ["Execute"] = true }, attacking = false,
        draw = { ring_3d = function(...) rec[#rec + 1] = { ... } end } })
    state3.snap[m], state3.hp[m], state3.rows[m] = { is_enemy = true }, 0.1, { ttd = 3 }
    frame3(0)
    assert_eq(#rec, 1, "the ring alone")
    assert_eq(M3.stats().execute, true, "execute still known")
    -- No JCore services at all.
    local M4, calls4, state4, frame4 = bundle({ target = m, no_ctx = true })
    state4.snap[m], state4.hp[m] = { is_enemy = true }, 0.5
    frame4(0)
    assert_eq(#all(calls4, "ring_3d", "ttd"), 1, "the ttd ring from the units alone")
    assert_eq(#all(calls4, "text_3d"), 0, "no tracker: no number")
end }

T[#T + 1] = { "1.7.6: execute's curtain is off by default; the red ring and the pulse are not", function()
    clock.s = 1000.0
    local m = mob("m")
    local _, calls, state, frame = bundle({ target = m, known = { ["Execute"] = true }, curtains_default = true })
    state.snap[m] = { is_enemy = true }
    state.rows[m] = { ttd = 4 }
    state.hp[m] = 0.18
    frame(0)
    local r = all(calls, "ring_3d", "ttd")
    assert_eq(r[1][4].r, 240, "the ring red")
    assert_eq(#all(calls, "pulse"), 1, "the pulse")
    assert_eq(#all(calls, "curtain_3d"), 0, "no curtain by default")
end }

return T

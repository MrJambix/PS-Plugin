-- Jambix AIO: the priority walk's press guards (modules/rotation.lua) and the
-- burst window's open/close bookkeeping (modules/burst.lua), each driven
-- through a hand-built bundle with a scripted clock.
--
-- Both come from one live log: Raptor Strike dispatched eleven times in one
-- second, Arcane Shot twenty times in three, and a burst window reopening
-- every six seconds -- the first of them on an "infs fight".

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_rotation = require("jambix_aio/modules/rotation")
local make_burst = require("jambix_aio/modules/burst")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A log that records every line, by level.
local function recording_log(W)
    W.lines = {}
    local function put(level, text) W.lines[#W.lines + 1] = { level = level, text = text } end
    return {
        fmt = function(level, fmt, ...) put(level, string.format(fmt, ...)) end,
        once = function(level, _, text) put(level, text) end,
        info = function(text) put("info", text) end,
        debug = function(text) put("debug", text) end,
        warn = function(text) put("warn", text) end,
        error = function(text) put("error", text) end,
    }
end

local function count_lines(W, needle)
    local n = 0
    for i = 1, #W.lines do
        if W.lines[i].text:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- --- the priority walk ----------------------------------------------------------

local IDS = {
    ["Raptor Strike"] = 14260, ["Arcane Shot"] = 14281,
    ["Wing Clip"] = 2974, ["Heroic Strike"] = 285,
    ["Feign Death"] = 5384, ["Fear"] = 5782, ["Frost Nova"] = 122,
    ["Auto Shot"] = 75, ["Attack"] = 6603, ["Blessing of Kings"] = 20217, ["Repentance"] = 20066,
}

-- What the hunter catalogue says about the three hunter abilities used here.
-- Heroic Strike is deliberately absent: a class without a catalogue row has
-- to be caught by name.
local ROWS = {
    ["raptor strike"] = { name = "Raptor Strike", range = "melee", cooldown = 6, on_next_swing = true },
    ["arcane shot"] = { name = "Arcane Shot", range = "ranged", cooldown = 6 },
    ["wing clip"] = { name = "Wing Clip", range = "melee" },
    ["feign death"] = { name = "Feign Death", range = "self" },
}

local function rotation_bundle()
    local W = {
        clock = 1000.0,
        distance = 4,
        attack_speed = 2.0,
        current = {},             -- spell id -> true while the client reports it queued
        current_unsupported = false,
        refused = {},             -- name -> true: the client calls it not castable
        want = {},                -- name -> true: the rule's predicate says yes
        casts = {},
        handlers = {},
    }

    _G.core = {
        time = function() return W.clock end,
        spell_book = {
            is_current_spell = function(id)
                if W.current_unsupported then error("not on this build") end
                return W.current[id] == true
            end,
        },
    }

    local player = {
        get_guid = function() return "player" end,
        get_class = function() return 3 end,
        get_attack_speed = function() return W.attack_speed end,
        is_moving = function() return false end,
    }
    local target = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "mob" end,
    }
    W.player, W.target = player, target

    local P = {
        log = recording_log(W),
        ctx = {
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            tick = function() end,
            emit = function() end,
            cast = function(request)
                W.casts[#W.casts + 1] = request
                -- The cast service sending it on, when the test says it won.
                if W.dispatch then W.fire("jcore.cast.sent", request) end
            end,
            PRIORITY = { ROTATION = 50, COOLDOWN = 80, EMERGENCY = 100 },
        },
        units = {
            player = function() return player end,
            distance = function() return W.distance end,
            has_aura = function() return false end,
        },
        combat = { cast_remaining = function() return 0 end },
        spellbook = {
            id = function(name) return IDS[name] end,
            ids = function(name) return IDS[name] and { IDS[name] } or nil end,
            known = function(name) return IDS[name] ~= nil end,
            ready = function(name) return IDS[name] ~= nil and not W.refused[name] end,
            castable = function(name) return IDS[name] ~= nil and not W.refused[name] end,
            names = function() return {} end,
        },
        talents = { rank = function() return 0 end },
        targeting = {},
        catalog = {
            ability = function(name) return ROWS[name:lower()] end,
            current = function() return { ranges = { ranged = { min = 8, max = 35 } } } end,
            with_role = function() return {} end,
        },
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    }

    W.rotation = make_rotation(P)
    W.P = P

    --- Fires a game or core event at whatever the module registered.
    function W.fire(event, data)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(data) end
    end

    local function rule(name, extra)
        local r = { name, function() return W.want[name] == true end }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end

    W.profile = {
        label = "Test",
        rules = {
            rule("Wing Clip", { upkeep = 3 }),
            rule("Arcane Shot"),
            rule("Heroic Strike", { fast = true }),
            rule("Raptor Strike"),
        },
    }
    W.rotation.classes.HUNTER = { key = "hunter", profiles = { test = W.profile }, profile_order = { "test" } }

    --- One walk of the priority list, as the tick would run it.
    function W.walk()
        W.rotation.run_rules(W.profile, {
            player = player, target = target, in_combat = true,
            distance = W.distance, hold_fire = false, ttd = 20,
        })
    end

    --- Walks every tenth of a second for `seconds`.
    function W.run(seconds)
        local steps = math.floor(seconds * 10 + 0.5)
        for _ = 1, steps do
            W.clock = W.clock + 0.1
            W.walk()
        end
    end

    function W.pressed(name)
        local n, last = 0, nil
        for i = 1, #W.casts do
            if W.casts[i].reason == name then n, last = n + 1, W.casts[i] end
        end
        return n, last
    end

    function W.explain(name)
        return W.rotation.explain(name, W.profile, {
            player = player, target = target, in_combat = true,
            distance = W.distance, hold_fire = false, ttd = 20,
        })
    end

    return W
end

local T = {}

T[#T + 1] = { "Raptor Strike rides the next swing: one press, held while queued, off the GCD lane", function()
    local W = rotation_bundle()
    W.want["Raptor Strike"], W.want["Wing Clip"] = true, true

    W.walk()
    local n, request = W.pressed("Raptor Strike")
    assert_eq(n, 1, "pressed once")
    assert_eq(request.fast, true, "in the off-GCD lane")
    assert_eq(W.pressed("Wing Clip"), 1, "and the GCD lane is still free for the clip")

    -- Queued on the swing: the client says so, and the press is not repeated.
    W.current[IDS["Raptor Strike"]] = true
    W.run(1.5)
    assert_eq(W.pressed("Raptor Strike"), 1, "not re-pressed while queued (was eleven a second)")
    assert(W.explain("Raptor Strike"):find("queued on the next swing", 1, true), "the watch line says why")

    -- The swing lands: confirmed, and the cooldown starts.
    W.current[IDS["Raptor Strike"]] = nil
    W.fire("jcore.spell.cast", { spell_id = IDS["Raptor Strike"] })
    W.refused["Raptor Strike"] = true
    W.run(1.0)
    assert_eq(W.pressed("Raptor Strike"), 1, "on cooldown: nothing")

    -- Cooldown over, still stuck in melee: the next one goes.
    W.refused["Raptor Strike"] = nil
    W.walk()
    assert_eq(W.pressed("Raptor Strike"), 2, "pressed again once it is ready")
end }

T[#T + 1] = { "a build that does not say what is queued: once per swing, never the breaker", function()
    local W = rotation_bundle()
    W.current_unsupported = true
    W.want["Raptor Strike"] = true

    W.walk()
    assert_eq(W.pressed("Raptor Strike"), 1, "first press")
    W.run(1.9)
    assert_eq(W.pressed("Raptor Strike"), 1, "held for the two-second swing")
    W.run(0.3)
    assert_eq(W.pressed("Raptor Strike"), 2, "pressed again after a swing")

    -- A weapon speed reported in milliseconds is read as seconds. The last
    -- press was at +2.0 or +2.1; the clock is at +2.2.
    W.attack_speed = 3000
    W.run(2.7)
    assert_eq(W.pressed("Raptor Strike"), 2, "held for a three-second swing")
    W.run(0.5)
    assert_eq(W.pressed("Raptor Strike"), 3, "and pressed after it")

    -- Other casts are being confirmed, so the breaker is calibrated -- and
    -- it still never judges an on-next-swing press.
    W.fire("jcore.spell.cast", { spell_id = IDS["Arcane Shot"] })
    W.run(12)
    assert_eq(count_lines(W, "Raptor Strike reported castable but never fired"), 0, "no back-off")
end }

T[#T + 1] = { "Heroic Strike has no catalogue row and is still held while queued", function()
    local W = rotation_bundle()
    W.want["Heroic Strike"] = true
    W.walk()
    assert_eq(W.pressed("Heroic Strike"), 1, "pressed")
    W.current[IDS["Heroic Strike"]] = true
    W.run(2)
    assert_eq(W.pressed("Heroic Strike"), 1, "held while queued")
    W.current[IDS["Heroic Strike"]] = nil
    W.fire("jcore.spell.cast", { spell_id = IDS["Heroic Strike"] })
    W.walk()
    assert_eq(W.pressed("Heroic Strike"), 2, "the next swing's")
end }

T[#T + 1] = { "a press the client refused is retried once a second, not every frame", function()
    local W = rotation_bundle()
    W.distance = 20
    W.want["Arcane Shot"] = true

    -- Every press is sent; the client takes none of them (too close, not
    -- facing): no cooldown, no confirmation, still "ready".
    W.dispatch = true
    W.walk()
    assert_eq(W.pressed("Arcane Shot"), 1, "first press")
    W.run(0.9)
    assert_eq(W.pressed("Arcane Shot"), 1, "not re-pressed inside a second (was twenty in three)")
    assert(W.explain("Arcane Shot"):find("not confirmed yet", 1, true), "the watch line says why")
    W.run(0.3)
    assert_eq(W.pressed("Arcane Shot"), 2, "retried after a second")

    -- Requests that lose arbitration are never sent: nothing to wait for.
    W.dispatch = false
    W.run(1.1)
    local before = W.pressed("Arcane Shot")
    W.run(0.2)
    assert_eq(W.pressed("Arcane Shot"), before + 2, "a request that never went out is not held")

    -- Sent and confirmed: the hold is only for presses that left no trace.
    W.dispatch = true
    W.walk()
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "cast-guid", IDS["Arcane Shot"] })
    W.walk()
    assert_eq(W.pressed("Arcane Shot"), before + 4, "a confirmed cast is not held")
end }

local HELPER = "common/utility/auto_attack_helper"

--- Installs (or removes) a stand-in for the client's auto-attack helper,
--- which is what makes an Auto Shot press a START.
local function start_helper(present)
    package.loaded[HELPER] = nil
    package.preload[HELPER] = present and function()
        return { is_spell_auto_attack = function(_, id) return id == 75 end }
    end or nil
end

T[#T + 1] = { "Auto Shot kept on: a new target gets a START at once, whatever the old target's shots say", function()
    start_helper(true)
    local W = rotation_bundle()
    local R = W.rotation.helpers.auto_repeat("Auto Shot", { auto_attack = true, keep_on = true, period = 3.5 })

    -- Shooting the first mob.
    R.forget()
    assert_eq(R.press_wanted(6, false), true, "first target: pressed")
    W.clock = W.clock + 2
    R.observe(75)
    W.clock = W.clock + 0.5
    assert_eq(R.press_wanted(6, false), false, "shooting it: left alone")

    -- It dies; the next mob is selected half a second after the last shot.
    R.forget()
    assert_eq(R.is_fresh(), true, "a new target is fresh")
    assert_eq(R.press_wanted(6, false), true, "the old target's shot is not proof: pressed at once")
    assert_eq(R.press_wanted(6, false), false, "and not twice")

    -- No shot at this one yet: another START a second and a half later.
    W.clock = W.clock + 1.6
    assert_eq(R.press_wanted(6, false), true, "still no shot: started again")

    -- Shooting the new mob: nothing to do for a swing.
    R.observe(75)
    W.clock = W.clock + 3
    assert_eq(R.press_wanted(6, false), false, "a shot at this target within the swing")
    W.clock = W.clock + 1
    assert_eq(R.press_wanted(6, false), true, "a swing with no shot: stopped (a melee swing, a right-click)")
    start_helper(false)
end }

T[#T + 1] = { "Forever: one shot per press -- every shot is followed by the next START", function()
    start_helper(true)
    local W = rotation_bundle()
    local R = W.rotation.helpers.auto_repeat("Auto Shot",
        { auto_attack = true, keep_on = true, period = 3.5, rearm = true })

    R.forget()
    assert_eq(R.press_wanted(6, false), true, "a new target: pressed at once")
    -- The client reports the shot the moment it goes out.
    W.clock = W.clock + 0.05
    R.observe(75)
    assert_eq(R.shots, 1, "the shot is counted")
    assert_eq(R.press_wanted(6, false), false, "not on the shot's own frame")
    W.clock = W.clock + 0.3
    assert_eq(R.press_wanted(6, false), false, "nor a third of a second after the last press")
    W.clock = W.clock + 0.5
    assert_eq(R.press_wanted(6, false), true,
        "the shot went out and nothing keeps it going there: the next swing is pressed for")
    assert_eq(R.press_wanted(6, false), false, "once")

    -- Waiting on the swing timer: no shot after this press yet.
    W.clock = W.clock + 1.0
    assert_eq(R.press_wanted(6, false), false, "a press with no shot yet is given its swing")
    W.clock = W.clock + 0.6
    assert_eq(R.press_wanted(6, false), true, "and tried again after a second and a half")

    -- The shot comes: the press after it follows a quarter of a second on.
    W.clock = W.clock + 0.9
    R.observe(75)
    W.clock = W.clock + 0.3
    assert_eq(R.press_wanted(6, false), true, "a shot, then the next press")

    -- A new target is pressed at once, whatever the last one's shot.
    R.forget()
    assert_eq(R.press_wanted(6, false), true, "the switch")
    start_helper(false)
end }

T[#T + 1] = { "Era: Auto Shot kept on, no re-arm -- a shot means running, left alone for a swing", function()
    start_helper(true)
    local W = rotation_bundle()
    local R = W.rotation.helpers.auto_repeat("Auto Shot", { auto_attack = true, keep_on = true, period = 3.5 })
    R.forget()
    assert_eq(R.press_wanted(6, false), true, "a new target: pressed at once")
    W.clock = W.clock + 0.05
    R.observe(75)
    W.clock = W.clock + 0.8
    assert_eq(R.press_wanted(6, false), false, "Era: the shot means it is running")
    W.clock = W.clock + 2.0
    assert_eq(R.press_wanted(6, false), false, "and stays so within the swing")
    W.clock = W.clock + 0.8
    assert_eq(R.press_wanted(6, false), true, "a swing with no shot: started again (unchanged)")
    start_helper(false)
end }

T[#T + 1] = { "the watch line for a toggle asks the class what it would do, never the rule", function()
    local W = rotation_bundle()
    local asked = 0
    local profile = { label = "Toggle", rules = {
        { "Auto Shot", function() asked = asked + 1; return true end, direct = true },
    } }
    local state = {}
    W.rotation.classes.HUNTER = {
        key = "hunter", profiles = { test = profile }, profile_order = { "test" },
        toggle_status = { ["Auto Shot"] = function() return state.held, state.running end },
    }
    local s = { player = W.player, target = W.target, in_combat = true, distance = 20, hold_fire = false, ttd = 20 }

    state.running = "firing at this target"
    assert_eq(W.rotation.explain("Auto Shot", profile, s), "Auto Shot: firing at this target", "firing ends the line")
    state.running, state.held = nil, "started, waiting for its first shot"
    assert_eq(W.rotation.explain("Auto Shot", profile, s),
        "Auto Shot held: started, waiting for its first shot", "a hold is one of the reasons")
    state.held = nil
    assert_eq(W.rotation.explain("Auto Shot", profile, s), "Auto Shot: would fire now", "nothing holds it")
    assert_eq(asked, 0, "the rule, which would press, was never asked")
end }

T[#T + 1] = { "Auto Shot without the START helper keeps the cautious toggle logic", function()
    start_helper(false)
    local W = rotation_bundle()
    local R = W.rotation.helpers.auto_repeat("Auto Shot", { auto_attack = true, keep_on = true, period = 3.5 })
    R.observe(75)
    W.clock = W.clock + 0.5
    R.forget()
    assert_eq(R.press_wanted(6, false), false, "a press could be the off switch: the recent shot holds it")
end }

T[#T + 1] = { "escapes: the ones cast on the enemy go on the enemy, and only when it is in reach", function()
    local W = rotation_bundle()
    local H = W.rotation.helpers
    local s = { player = W.player, target = W.target }

    assert_eq(H.escape_target("Feign Death", s), W.player, "catalogue says self: Feign Death is ours")
    assert_eq(H.escape_target("Wing Clip", s), W.target, "catalogue says melee: Wing Clip goes on the mob")
    assert_eq(H.escape_target("Fear", s), W.target, "no catalogue row: Fear by name")
    assert_eq(H.escape_target("Frost Nova", s), W.player, "no row, not on the list: self-centred")

    W.refused["Wing Clip"] = true   -- out of reach, or out of sight
    assert_eq(H.escape_target("Wing Clip", s), nil, "not castable on the mob: skip to the next escape")
    assert_eq(H.escape_target("Fear", { player = W.player }), nil, "no target: skip")
end }

T[#T + 1] = { "has_rule: another module defers to a spell the active profile owns", function()
    local W = rotation_bundle()
    assert_eq(W.rotation.has_rule("Wing Clip"), true, "in the profile")
    assert_eq(W.rotation.has_rule("Mend Pet"), false, "not in the profile")
end }

T[#T + 1] = { "hardcore: the bail-out says when it starts and stops, and an escape goes on the enemy", function()
    local make_hardcore = require("jambix_aio/modules/hardcore")
    local W = { clock = 1000.0, casts = {}, ready = { ["Wing Clip"] = true } }
    _G.core = { time = function() return W.clock end }
    local player, mob = { get_guid = function() return "player" end }, { get_guid = function() return "mob" end }
    local hunter = { escapes = { "Feign Death", "Wing Clip" } }
    local P = {
        log = recording_log(W),
        ctx = {
            every = function() end, on = function() end, tick = function() end,
            render = function() end, emit = function() end,
            cast = function(request) W.casts[#W.casts + 1] = request end,
            PRIORITY = { EMERGENCY = 100 },
        },
        units = { player = function() return player end },
        combat = {}, draw = {},
        spellbook = {
            ready = function(name) return W.ready[name] == true end,
            id = function() return 2974 end,
        },
        rotation = {
            active_class = function() return hunter end,
            helpers = {
                key_allows = function() return true end,
                escape_target = function(name, s) return name == "Wing Clip" and s.target or s.player end,
            },
        },
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    }
    local hc = make_hardcore(P)

    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.5 }), false, "half health: fight on")
    assert_eq(count_lines(W, "bail-out"), 0, "nothing to say")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.15 }), true, "under the line: stop")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.14 }), true, "still under")
    assert_eq(count_lines(W, "under the bail-out line"), 1, "said once, when it started")
    assert_eq(hc.should_stop_fighting({ in_combat = false, hp = 0.14 }), false, "combat over")
    assert_eq(count_lines(W, "bail-out over (combat ended)"), 1, "and said when it ended")

    hc.emergency({ in_combat = true, hp = 0.15, player = player, target = mob })
    assert_eq(#W.casts, 1, "an escape went out")
    assert_eq(W.casts[1].target, mob, "Wing Clip on the mob, not on us")
end }

-- --- the burst window -------------------------------------------------------------

local function burst_bundle()
    local W = {
        clock = 1000.0,
        ready = {},           -- name -> true
        settings = {},
        casts = {},
        ttd = 20,
    }
    _G.core = { time = function() return W.clock end }

    local P = {
        log = recording_log(W),
        ctx = {
            on = function() end,
            emit = function() end,
            cast = function(request) W.casts[#W.casts + 1] = request end,
            PRIORITY = { COOLDOWN = 80 },
        },
        units = {},
        combat = {},
        spellbook = {
            ready = function(name) return W.ready[name] == true end,
            id = function() return 1 end,
        },
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        tune = function(_, default) return default / 100 end,
    }
    W.burst = make_burst(P)
    W.class = { power = "MANA", burst = { { spell = "Rapid Fire", duration = 15 } } }

    function W.tick()
        return W.burst.tick(W.class, {
            in_combat = true, target = {}, player = {},
            ttd = W.ttd, power = 80, power_max = 100,
        })
    end

    function W.opened()
        return count_lines(W, "burst: ")
    end

    return W
end

T[#T + 1] = { "burst: a druid's window reads its form's bar, not the class's mana (1.80.0)", function()
    local W = burst_bundle()
    W.class = { power = "MANA", burst = { { spell = "Berserk", duration = 15 } } }
    W.ready["Berserk"] = true
    local function tick(profile_power, power)
        return W.burst.tick(W.class, {
            in_combat = true, target = {}, player = {}, ttd = 30,
            power = power, power_max = 100, profile_power = profile_power,
        })
    end
    tick("ENERGY", 20)
    assert_eq(W.burst.open(), true, "a cat at 20 energy: Berserk's window opens (MANA held it under 35%)")
    W.clock = W.clock + 0.1
    tick("ENERGY", 5)
    assert_eq(W.burst.open(), true, "and 5 energy does not close it (MANA closed it under 10%)")

    local M = burst_bundle()
    M.class = { power = "MANA", burst = { { spell = "Berserk", duration = 15 } } }
    M.ready["Berserk"] = true
    M.burst.tick(M.class, { in_combat = true, target = {}, player = {}, ttd = 30,
        power = 20, power_max = 100, profile_power = "MANA" })
    assert_eq(M.burst.open(), false, "a caster at 20% mana still waits")
end }

T[#T + 1] = { "burst: an unmeasured fight is not a long one", function()
    local W = burst_bundle()
    W.ready["Rapid Fire"] = true
    W.ttd = math.huge
    W.tick()
    assert_eq(W.burst.open(), false, "no window on the first second of a pull")
    assert_eq(W.burst.stats().reason, "the fight's length is not measured yet", "and it says so")
    assert_eq(count_lines(W, "infs"), 0, "never logged as an infs fight")

    W.ttd = 20
    W.clock = W.clock + 1.1
    W.tick()
    assert_eq(W.burst.open(), true, "opens once the fight is measured")
    assert_eq(count_lines(W, "burst: 20s fight"), 1, "with the measured length")
end }

T[#T + 1] = { "burst: no switch since 1.39.0 -- the fight decides, and an old saved off changes nothing", function()
    local W = burst_bundle()
    W.settings.rot_use_cooldowns, W.settings.rot_use_trinkets = false, false
    W.ready["Rapid Fire"] = true
    W.tick()
    assert_eq(W.burst.open(), true, "a 20s fight with Rapid Fire up: the window opens")

    local S = burst_bundle()
    S.ready["Rapid Fire"] = true
    S.ttd = 4
    S.tick()
    assert_eq(S.burst.open(), false, "a 4s fight: not worth it")
    assert(tostring(S.burst.stats().reason):find("fight is 4s", 1, true), "and it says why: " .. tostring(S.burst.stats().reason))
end }

T[#T + 1] = { "burst: a window that ran out does not reopen inside the guard", function()
    local W = burst_bundle()
    -- Only the racial is up, and the client never takes it: it stays ready,
    -- which is what made every reopen in the log look worth it.
    W.ready["Blood Fury"] = true
    W.tick()
    assert_eq(W.opened(), 1, "opened")
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(#W.casts, 1, "the racial went into the window")

    -- The six-second floor runs out on its own.
    for _ = 1, 200 do
        W.clock = W.clock + 0.1
        W.tick()
    end
    assert_eq(W.opened(), 1, "no reopen twenty seconds after (was every six)")
    assert_eq(#W.casts, 1, "and no second racial press")

    -- Past the guard it may open again.
    for _ = 1, 70 do
        W.clock = W.clock + 0.1
        W.tick()
    end
    assert_eq(W.opened(), 2, "reopens once the guard has passed")
end }

T[#T + 1] = { "burst: the offensive racial counts on the terms it is pressed (no switch of its own since 1.32.0)", function()
    local W = burst_bundle()
    W.settings.rot_use_racials = false   -- a removed switch: changes nothing either way
    W.tick()
    assert_eq(W.burst.open(), false, "nothing ready: no window")
    assert_eq(W.burst.stats().reason, "nothing to burst with", "and it says so")
    W.ready["Blood Fury"] = true
    W.clock = W.clock + 1.1
    W.tick()
    assert_eq(W.burst.open(), true, "the racial alone is something to burst with")
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(#W.casts, 1, "and the window presses it")
end }

T[#T + 1] = { "the melee swing: started in reach while off, as a START, never while holding fire (1.76.1)", function()
    local W = rotation_bundle()
    local attacking = false
    W.player.is_auto_attacking = function() return attacking end
    -- The paladin's rule, as classes/paladin.lua writes it.
    local profile = { label = "Test", rules = {
        { "Attack", W.rotation.helpers.melee_start_wanted, direct = true, fast = true, upkeep = 1 },
    } }
    local function walk(hold)
        W.clock = W.clock + 1.5
        W.rotation.run_rules(profile, { player = W.player, target = W.target, in_combat = not hold,
            distance = W.distance, hold_fire = hold, ttd = 20 })
    end

    -- Nothing pulls by itself (1.75.0): a mob nobody engaged is not swung at.
    walk(true)
    assert_eq(W.pressed("Attack"), 0, "holding fire")

    -- Out of reach: the swing would only wait for the mob.
    W.distance = 12
    walk(false)
    assert_eq(W.pressed("Attack"), 0, "out of melee reach")

    W.distance = 4
    walk(false)
    local n, request = W.pressed("Attack")
    assert_eq(n, 1, "started in reach")
    assert_eq(request.direct, true, "sent as the client's START, never the toggle")
    assert_eq(request.fast, true, "off the global cooldown")
    assert_eq(request.spell_id, 6603, "the melee swing")

    -- Running: never pressed again, whatever the time.
    attacking = true
    walk(false); walk(false)
    assert_eq(W.pressed("Attack"), 1, "not re-pressed while the swing runs")

    -- The swing stopped (the mob died, a new one is on us): started again.
    attacking = false
    walk(false)
    assert_eq(W.pressed("Attack"), 2, "started again once it stops")
end }

T[#T + 1] = { "group buffs: party members only, never a stranger; a class may leave you to its profile (1.77.1)", function()
    local W = rotation_bundle()
    local function person(guid)
        return { get_guid = function() return guid end, is_player = function() return true end,
                 is_valid = function() return true end }
    end
    W.player.is_player = function() return true end
    local member, stranger = person("member"), person("stranger")
    local buffed = {}                       -- guid -> true once blessed
    W.P.units.guid = function(u) return u and u.get_guid and u:get_guid() or nil end
    W.P.units.allies_within = function() return { stranger, member } end
    W.P.units.has_aura = function(u) return buffed[u:get_guid()] == true end
    W.P.ctx.group = { objects = function() return { W.player, member } end }
    W.P.tune_secs = function(_, default) return default end
    local function pass(class_module)
        W.clock = W.clock + 3
        local before = #W.casts
        W.rotation.group_buffs(class_module, { player = W.player, in_combat = false })
        local request = W.casts[#W.casts]
        if #W.casts == before then return nil end
        buffed[request.target:get_guid()] = true
        return request.target:get_guid()
    end

    local everyone = { buffs = { { spell = "Blessing of Kings" } } }
    assert_eq(pass(everyone), "player", "you first")
    assert_eq(pass(everyone), "member", "then your party")
    assert_eq(pass(everyone), nil, "and never the stranger beside you")

    buffed = {}
    local paladin = { buffs = { { spell = "Blessing of Kings" } }, buff_others_only = true }
    assert_eq(pass(paladin), "member", "your own blessing is your profile's: the party only")
    assert_eq(pass(paladin), nil, "nobody else")
end }

T[#T + 1] = { "creature types: a spell the class says a mob cannot take is refused on it (1.77.4)", function()
    local W = rotation_bundle()
    W.rotation.classes.HUNTER.creature_types = { Repentance = { 7 } }
    local function mob(kind)
        return { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return "mob" end, get_creature_type = function() return kind end }
    end
    local s = { player = W.player, target = W.target, in_combat = true, distance = 4 }
    assert_eq(W.rotation.press_blocked("Repentance", s, mob(1)), "does not work on this creature type", "a beast")
    assert_eq(W.rotation.press_blocked("Repentance", s, mob(7)), nil, "a humanoid")
    assert_eq(W.rotation.press_blocked("Repentance", s, mob(nil)), nil, "a type the client does not say")
    assert_eq(W.rotation.press_blocked("Heroic Strike", s, mob(1)), nil, "a spell with no list: as before")
end }

T[#T + 1] = { "a rule for a spell you have not learned is not a candidate (1.54.1)", function()
    local W = rotation_bundle()
    W.profile.rules[#W.profile.rules + 1] = { "Serpent Sting", function() return true end }
    W.want["Arcane Shot"] = true
    W.distance = 20
    W.walk()
    local names = {}
    for _, c in ipairs(W.rotation.last_candidates()) do names[#names + 1] = c.rule[1] end
    local joined = table.concat(names, ",")
    assert(not joined:find("Serpent Sting", 1, true), "not learned, so not listed: " .. joined)
    assert(joined:find("Arcane Shot", 1, true), "a learned one is: " .. joined)
    assert_eq(W.pressed("Serpent Sting"), 0, "and never pressed")
end }

-- 1.74.0: the live log (Forever, a five-man) had Serpent Sting on one Lesser
-- Stone Golem every two to four seconds -- casts the client confirmed, and
-- the sting never on the mob. Forever gives no combat log to say "immune".
local function sting_bundle(shows)
    local W = rotation_bundle()
    local function mob(guid, name)
        return { guid = guid, name = name, get_guid = function() return guid end,
            is_valid = function() return true end, is_dead = function() return false end }
    end
    W.mobs = {}
    for _, m in ipairs({ mob("L", "Dark Iron Looter"), mob("G1", "Lesser Stone Golem"),
        mob("G2", "Lesser Stone Golem"), mob("G3", "Lesser Stone Golem") }) do W.mobs[m.guid] = m end
    W.stung = {}                                   -- guid -> true: the client shows the sting on it
    local u = W.P.units
    u.guid = function(x) return x and x.guid end
    u.name = function(x) return x and x.name end
    u.by_guid = function(g) return W.mobs[g] end
    u.has_aura = function(x) return x ~= nil and W.stung[x.guid] == true end
    u.aura_remaining = function(x) return (x and W.stung[x.guid]) and 10 or 0 end
    -- The client confirms every press a frame later; the sting shows only
    -- on the mobs `shows` names.
    local confirm = {}
    W.P.ctx.cast = function(request)
        W.casts[#W.casts + 1] = request
        confirm[#confirm + 1] = request
    end
    local H = W.rotation.helpers
    local profile = { label = "Stings", rules = {
        { "Serpent Sting", function(s) return H.dot_worth_it(s, "Serpent Sting", 0) end, dot = true, upkeep = 2 },
    } }
    W.on = W.mobs.L
    function W.walk()
        for i = 1, #confirm do
            local r = confirm[i]
            W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "cast-guid", r.spell_id })
            if shows[r.target.name] then W.stung[r.target.guid] = true end
        end
        confirm = {}
        W.rotation.run_rules(profile, { player = W.player, target = W.on, in_combat = true,
            distance = 20, hold_fire = false, ttd = 20 })
    end
    function W.on_mob(guid)
        local n = 0
        for i = 1, #W.casts do if W.casts[i].target == W.mobs[guid] then n = n + 1 end end
        return n
    end
    return W
end

local function with_sting(fn)
    IDS["Serpent Sting"] = 13549
    local ok, err = pcall(fn)
    IDS["Serpent Sting"] = nil
    if not ok then error(err, 0) end
end

T[#T + 1] = { "a DoT the client confirms but never shows: held for its duration, then that mob, then that name, left off (1.74.0)", function()
    with_sting(function()
        local W = sting_bundle({ ["Dark Iron Looter"] = true })
        W.walk()
        W.run(3)
        assert_eq(W.on_mob("L"), 1, "the Looter takes it: once")

        W.on = W.mobs.G1
        W.walk()
        W.run(11)
        assert_eq(W.on_mob("G1"), 1, "a golem: confirmed, not shown -- taken as ticking, not re-cast every 2 s")
        W.run(2)
        assert_eq(W.on_mob("G1"), 2, "past its duration: tried again")
        W.run(20)
        assert_eq(W.on_mob("G1"), 2, "twice confirmed, never shown, while it shows on others: left off that golem")
        assert_eq(count_lines(W, "Serpent Sting does not show on Lesser Stone Golem after 2 confirmed casts: left off it"), 1,
            "said once")

        W.on = W.mobs.G2
        W.walk()
        W.run(20)
        assert_eq(W.on_mob("G2"), 1, "a second golem: one try")
        assert_eq(count_lines(W, "Serpent Sting never shows on Lesser Stone Golem (2 of them"), 1, "the name is learned, out loud")

        W.on = W.mobs.G3
        W.run(20)
        assert_eq(W.on_mob("G3"), 0, "a third golem: left off from the first look")

        W.on = W.mobs.L
        W.stung.L = nil
        W.run(1)
        assert_eq(W.on_mob("L"), 2, "the Looter still gets it")
    end)
end }

T[#T + 1] = { "a DoT that shows on no mob is never left off: re-cast on its duration; a refused press holds nothing (1.74.0)", function()
    with_sting(function()
        local W = sting_bundle({})
        W.on = W.mobs.G1
        W.walk()
        W.run(40)
        local n = W.on_mob("G1")
        assert(n >= 3 and n <= 4, "every twelve seconds or so, not every two: " .. n)
        assert_eq(count_lines(W, "left off"), 0, "nothing left off")

        local R = sting_bundle({})
        R.P.ctx.cast = function(request) R.casts[#R.casts + 1] = request end   -- the client takes none
        R.on = R.mobs.G1
        R.walk()
        R.run(6)
        assert(R.on_mob("G1") >= 3, "a refused press says nothing about the mob: " .. R.on_mob("G1"))
    end)
end }

T[#T + 1] = { "a melee weave's swing stopped Auto Shot: the next press goes at once, and once (1.7.6)", function()
    start_helper(true)
    local W = rotation_bundle()
    local R = W.rotation.helpers.auto_repeat("Auto Shot", { auto_attack = true, keep_on = true, period = 3.5 })

    R.forget()
    assert_eq(R.press_wanted(6, false), true, "first target: pressed")
    W.clock = W.clock + 0.5
    R.observe(75)
    -- The weave runs in, swings, and is back at range a second and a half on.
    W.clock = W.clock + 1.5
    assert_eq(R.press_wanted(6, false), false, "a shot within the swing reads as running")
    R.restart()
    assert_eq(R.press_wanted(6, false), true, "back from the swing: pressed at once")
    assert_eq(R.press_wanted(6, false), false, "and once")
    start_helper(false)
end }

return T

-- Jambix AIO: the swing readout (modules/weave.lua) and the kite's guards
-- (modules/kite.lua), driven through a hand-built bundle with a scripted
-- clock. The weave's contract is that it NEVER touches the character: no
-- movement lease, no lock, no turn. The readout itself is timed from real
-- shots only.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_weave = require("jambix_aio/modules/weave")
local make_kite = require("jambix_aio/modules/kite")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A bundle whose every knob is a field on the returned table. Every input
--- call that could move, hold or turn the character is counted.
local function bundle()
    local W = {
        clock = 1000.0,
        moving = true,
        settings = { rot_enabled = true },
        input_calls = 0,
        handlers = {},
        ticks = {},
    }

    _G.core = {
        time = function() return W.clock end,
        addons = {},
    }

    local player = {
        is_moving = function() return W.moving end,
        can_attack = function() return true end,
        get_guid = function() return 1 end,
        get_unit_ranged_damage = function() return { speed = 2.5 } end,
        get_pet = function() return nil end,
    }
    local target = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return 2 end,
        is_moving = function() return true end,
    }
    W.player, W.target = player, target

    local function counted()
        return function() W.input_calls = W.input_calls + 1; return true end
    end
    local input = {
        CHANNEL = { MOVEMENT = "movement", FACING = "facing" },
        PRIORITY = { ROTATION = 50 },
        acquire = counted(), release = counted(), hold = counted(),
        face = counted(), look_at = counted(), set_key = counted(),
        is_key_pressed = function(vk) return W.keys and W.keys[vk] == true end,
    }

    local known = { ["Auto Shot"] = true }
    W.known = known
    local P = {
        log = { fmt = function(level, fmt, ...)
            if level == "error" then error(string.format(fmt, ...)) end
        end },
        ctx = {
            input = input,
            on = function(name, fn) W.handlers[name] = fn end,
            tick = function(fn) W.ticks[#W.ticks + 1] = fn end,
        },
        units = {
            player = function() return player end,
            player_position = function() return { x = 0, y = 0, z = 0 } end,
            position = function() return { x = 25, y = 0, z = 0 } end,
            distance = function() return 25 end,
            is_facing = function() return true end,
            name = function() return "Boar" end,
        },
        combat = {
            in_combat = function() return true end,
            target = function() return target end,
        },
        spellbook = {
            known = function(name) return known[name] == true end,
            id = function(name) return known[name] and 75 or nil end,
            ids = function(name) return known[name] and { 75 } or nil end,
        },
        rotation = {
            active_class = function() return { key = "hunter" } end,
            cast_gate_busy = function() return false end,
            helpers = {},
        },
        pet = { alive = function() return false end },
        kite = { active = function() return false end },
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        master_on = function() return true end,
        rotation_active = function() return true end,
    }
    W.P = P

    W.weave = make_weave(P)
    W.tick_fn = W.ticks[#W.ticks]
    function W.tick() W.tick_fn() end
    function W.advance(seconds, step)
        step = step or 0.05
        local stop = W.clock + seconds
        while W.clock < stop - 1e-9 do
            W.clock = math.min(stop, W.clock + step)
            W.tick()
        end
    end
    function W.shot()
        W.handlers["jcore.spell.cast"]({ spell_id = 75, caster = player })
    end
    W.tick()
    return W
end

local T = {}

T[#T + 1] = { "the weave never touches the character: no lease, no hold, no turn", function()
    local W = bundle()
    W.advance(10)
    W.shot()
    W.advance(10)
    W.moving = false
    W.advance(10)
    assert_eq(W.input_calls, 0, "input calls")
    assert_eq(W.weave.holding(), false, "holding")
end }

T[#T + 1] = { "a real shot starts the readout; the next is due one period later", function()
    local W = bundle()
    assert_eq(W.weave.next_shot_in(), math.huge, "unknown before any shot")
    W.shot()
    assert(math.abs(W.weave.next_shot_in() - 2.5) < 0.01, "due one period after the shot")
    assert_eq(W.weave.stats().shots, 1, "counted")
    W.advance(1)
    assert(math.abs(W.weave.next_shot_in() - 1.5) < 0.01, "counts down")
    W.handlers["jcore.combat.leave"]()
    assert_eq(W.weave.next_shot_in(), math.huge, "forgotten when the fight ends")
end }

T[#T + 1] = { "another hunter's Auto Shot is not ours", function()
    local W = bundle()
    W.handlers["jcore.spell.cast"]({ spell_id = 75, caster = { get_guid = function() return 9 end } })
    assert_eq(W.weave.stats().shots, 0, "not counted")
end }

T[#T + 1] = { "the swing timer addon's last swing counts as a real shot", function()
    local W = bundle()
    local info = { last_swing = W.clock - 0.5, expiration_time = W.clock + 2.0, auto_shot_cast_time = 0.5 }
    _G.core.addons.swing_timer = {
        is_loaded = function() return true end,
        get_player_ranged_info = function() return info end,
    }
    W.advance(0.3)
    assert_eq(W.weave.stats().timed, false, "first read is a baseline, not a shot")
    info.last_swing = W.clock
    info.expiration_time = W.clock + 2.5
    W.advance(0.3)
    assert(W.weave.stats().timed, "a new last swing starts the readout")
    assert_eq(W.weave.stats().shots, 1, "counted as a shot")
    assert_eq(W.input_calls, 0, "still no input calls")
end }

T[#T + 1] = { "kite: never once Tame Beast is trained, and stands aside while the player drives", function()
    local W = bundle()
    W.P.ctx.input.holds = function() return true end
    W.known["Tame Beast"] = true
    local kite = make_kite(W.P)
    local kite_tick = W.ticks[#W.ticks]
    kite_tick()
    assert_eq(kite.active(), false, "not kiting with Tame Beast known")
    -- The pet levels: the only job left is the step out, and at 25 yards
    -- there is nothing to step out of.
    assert_eq(kite.stats().reason, "target shootable", "reason")

    W.known["Tame Beast"] = nil
    W.keys = { [0x57] = true }
    kite_tick()
    assert_eq(kite.active(), false, "not kiting while the player holds a key")
    assert_eq(kite.stats().reason, "you are driving", "reason")
end }

return T

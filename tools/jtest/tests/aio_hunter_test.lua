-- Jambix AIO: the hunter's pull (modules/classes/hunter.lua), the pet's
-- Growl decision (modules/pet.lua) and the step out of the dead zone
-- (modules/kite.lua), each driven through a hand-built bundle.
--
-- The point of these is the ORDER of a pull and the CHOICE of opener: the
-- pet goes in first when solo, a three-second cast is only started when it
-- lands before the mob does, a charging mob is dazed, a mob that reached us
-- is clipped and walked away from.

local root = (jtest and jtest.scripts) or "scripts"
-- Only when the harness has not already put scripts/ on the path: run.js
-- does, after a JTEST_OVERLAY staging folder, which this would hide.
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local make_hunter = require("jambix_aio/modules/classes/hunter")
local make_pet = require("jambix_aio/modules/pet")
local make_kite = require("jambix_aio/modules/kite")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- --- the class file -----------------------------------------------------------

--- A bundle for the class file. Every reading the rules take is a field on
--- the returned table, so a test states the fight and asks the rule.
---@param opts? { forever?: boolean }
local function hunter_bundle(opts)
    opts = opts or {}
    local W = {
        clock = 1000.0,
        in_combat = false,
        distance = 30,
        moving = false,
        context = "solo",
        pet_alive = true,
        pet_mode = 2,
        pet_sent = nil,          -- seconds since the pet was sent at the target, or nil
        pet_on_target = false,
        pet_pos = { x = 30, y = 0, z = 0 },
        target_pos = { x = 30, y = 0, z = 0 },
        debuffs = {},            -- name -> true, on the target
        debuffs_on = {},         -- unit -> { name -> true }, on any other unit
        health = {},             -- unit -> fraction, for units other than the target
        engaged = nil,           -- s.engaged_units
        row = nil,               -- the awareness row for the target
        power = 0.8,
        known = { ["Aimed Shot"] = true, ["Hunter's Mark"] = true, ["Auto Shot"] = true },
        last_cast = {},          -- name -> seconds ago
        kite_active = false,
        settings = {},
    }

    _G.core = { time = function() return W.clock end }

    local player = {
        is_moving = function() return W.moving end,
        get_guid = function() return "player" end,
        get_unit_ranged_damage = function() return { speed = 2.5 } end,
    }
    local target = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "mob" end,
        is_moving = function() return W.row and W.row.moving or false end,
        get_target = function() return nil end,
        is_boss = function() return W.boss == true end,
    }
    local pet = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "pet" end,
    }
    W.player, W.target, W.pet_unit = player, target, pet

    local units = {
        distance = function() return W.distance end,
        health_fraction = function(u) return W.health[u] or 1 end,
        guid = function(u) return u and u.get_guid and u:get_guid() or nil end,
        classification = function(u) return (u == target and W.rank) or 0 end,
        position = function(u)
            if u == pet then return W.pet_pos end
            if u == target then return W.target_pos end
            return { x = 0, y = 0, z = 0 }
        end,
    }
    local book = { known = function(name) return W.known[name] == true end }

    local H = {
        book = book, units = units,
        power_fraction = function() return W.power end,
        debuff_up = function(unit, name)
            if W.debuffs_on[unit] then return W.debuffs_on[unit][name] == true end
            if unit ~= target then return false end
            return W.debuffs[name] == true
        end,
        buff_up = function() return true end,
        auto_repeat = function(_, repeat_opts)
            -- A stand-in for the toggle guard: records what the class file
            -- tells it, presses whenever asked.
            W.repeat_opts = repeat_opts
            W.repeater = {
                period = 3.5, last_shot = 0, forgotten = 0,
                set_period = function(p) W.repeater.period = p end,
                since_shot = function()
                    if W.repeater.last_shot == 0 then return math.huge end
                    return W.clock - W.repeater.last_shot
                end,
                shots_seen = function() return W.repeater.last_shot > 0 end,
                forget = function() W.repeater.forgotten = W.repeater.forgotten + 1 end,
                press_wanted = function(_, stale)
                    W.repeater.stale = stale
                    W.repeater.fresh = false
                    return true
                end,
                is_fresh = function() return W.repeater.fresh == true end,
            }
            return W.repeater
        end,
        bursting = function() return false end,
        spread = function() return W.spread == true end,
        dot_worth_it = function(s, _, min_ttd) return s.ttd > (min_ttd or 10) end,
        since_cast = function(name) return W.last_cast[name] or math.huge end,
        debuff_remaining = function(unit, name)
            local on = W.debuffs_on[unit] or (unit == target and W.debuffs) or {}
            return on[name] and 10 or 0
        end,
    }
    local CS = {
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        tune = function(_, default) return default / 100 end,
        pct = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
    }
    W.traced = {}
    W.handlers = {}
    local P = {
        forever = opts.forever == true or nil,
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
        targeting = {
            SOLO = "solo",
            context = function() return W.context end,
            may_control_pull = function() return W.may_pull ~= false end,
        },
        ctx = {
            enemies = { get = function() return W.row end },
            -- JCore's client flags, as Forever or Era answer them (1.6.0).
            world = { client = function()
                local f = opts.forever == true
                return { forever = f, recording = f, auto_repeat_once = f, auto_start_melee = f }
            end },
            on = function(event, fn) W.handlers[event] = fn end,
            emit = function(event, text)
                if event == "jcore.recorder.trace" then W.traced[#W.traced + 1] = text end
            end,
        },
        pet = {
            OFF = 1, ASSIST = 2, TANK = 3, FOCUS = 4,
            alive = function() return W.pet_alive end,
            mode = function() return W.pet_mode end,
            pet = function() return W.pet_alive and pet or nil end,
            pet_target = function() return W.pet_on_target and target or nil end,
            sent_for = function() return W.pet_sent end,
            health = function() return 1 end,
        },
        kite = {
            active = function() return W.kite_active end,
            wants_slow = function() return false end,
        },
    }

    W.P = P
    W.H = H
    W.class = make_hunter(P, H, CS)
    local settings_seen = {}
    W.class.settings({
        slider = function(_, id) settings_seen[#settings_seen + 1] = id end,
        label = function() end,
        toggle = function(_, id) settings_seen[#settings_seen + 1] = id end,
        dropdown = function(_, id) settings_seen[#settings_seen + 1] = id end,
    }, P)
    W.settings_seen = settings_seen

    --- The situation as the rotation would build it.
    function W.situation()
        return {
            player = player, target = target,
            in_combat = W.in_combat, distance = W.distance,
            target_row = W.row, ttd = W.ttd or 20, melee = 0,
            posture = W.posture or "HEALTHY", engaged_units = W.engaged,
            res = { power_empty = W.power_empty or math.huge }, fight_left = W.fight_left or 20,
            spreading = W.spreading,
        }
    end

    --- Asks the nth rule named `name` in a profile.
    function W.rule(profile_key, name, nth)
        local rules = W.class.profiles[profile_key].rules
        local seen = 0
        for i = 1, #rules do
            if rules[i][1] == name then
                seen = seen + 1
                if seen == (nth or 1) then return rules[i][2](W.situation()) end
            end
        end
        error("no rule " .. name .. " #" .. tostring(nth or 1) .. " in " .. profile_key)
    end

    return W
end

local T = {}

T[#T + 1] = { "solo pull: the mark goes first, the damage waits until the mob is on the pet", function()
    local W = hunter_bundle()
    -- Fresh target, pet sent and running in: the mark goes, nothing else.
    W.pet_sent, W.pet_on_target = 0.5, true
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "mark first, always")
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "opener waits for the pet to have the mob")
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "and the sting")
    assert_eq(W.rule("leveling", "Auto Shot"), true, "Auto Shot does not wait: a fraction of one Growl")

    -- The mob turned on the pet: the damage starts.
    W.in_combat = true
    W.row = { targeting_pet = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "opener once the mob is on the pet")
    assert_eq(W.rule("leveling", "Auto Shot"), true, "auto shot once the mob is on the pet")

    -- Charging us instead, mid-fight, pet still running in: the daze goes,
    -- the damage does not.
    W.distance, W.row = 20, { targeting_me = true, closing = 7, time_to_reach = 2.1, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "daze the charging mob")
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "no big threat on us yet")

    -- Without the awareness reader the mob's own target is read.
    W.row = nil
    W.target.get_target = function() return W.pet_unit end
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "mob on the pet, read from the mob")
end }

T[#T + 1] = { "the wait for the pet is bounded: not sent, not arriving, on us already, or not solo", function()
    local W = hunter_bundle()
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    -- Not sent at all: a moment for the pet module, then go anyway.
    W.pet_sent = nil
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "a moment for the pet module")
    W.clock = W.clock + 2.5
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "then the shots go")

    -- Sent long ago and the mob still not on it: it is not getting there.
    W.pet_sent, W.pet_on_target = 7, true
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "patience runs out")

    -- The mob is already on us in melee: waiting gains nothing.
    W.pet_sent, W.in_combat = 0.5, true
    W.distance, W.row = 4, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Wing Clip"), true, "clip it")
    assert_eq(W.rule("leveling", "Raptor Strike"), true, "and fight")

    -- In a group there is a real tank; nothing waits.
    W.distance, W.row, W.context = 30, { targeting_me = false, closing = 0 }, "party"
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "no wait in a group")

    -- No pet out: nothing to wait for.
    W.context, W.pet_alive = "solo", false
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "no wait without a pet")
end }

T[#T + 1] = { "the opener is a question of time: no three-second cast on a mob two seconds away", function()
    local W = hunter_bundle()
    W.in_combat = true
    W.pet_alive = false   -- the pet-first wait is tested above; this is about time

    -- Charging us, two seconds out: instants, not Aimed Shot.
    W.distance, W.row = 18, { targeting_me = true, closing = 7, time_to_reach = 1.9, engaged = true }
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "no opener two seconds out")
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "no filler two seconds out")
    assert_eq(W.rule("leveling", "Arcane Shot"), true, "Arcane Shot instead")

    -- Charging us from far enough: the cast lands first.
    W.distance, W.row = 34, { targeting_me = true, closing = 7, time_to_reach = 4.2, engaged = true }
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "opener with four seconds in hand")
    -- Comfortable, but the bar will not last this fight: no standing filler.
    -- (A fixed 70% line until 1.33.0; now the measured mana race.)
    W.power, W.power_empty, W.fight_left = 0.6, 12, 20
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "Aimed Shot has the job")
    W.power, W.power_empty = 0.8, nil

    -- On the pet: all the time in the world.
    W.distance, W.row = 12, { targeting_pet = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "opener on a mob the pet holds")

    -- Already opened this fight: the first slot stays quiet, the filler takes over.
    W.last_cast["Aimed Shot"] = 4
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "opened already")
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "filler while mana is fine")
    W.power = 0.2
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "no filler when not fine on mana")
end }

T[#T + 1] = { "without the awareness reader an unengaged mob is assumed to run at us", function()
    local W = hunter_bundle()
    W.pet_alive = false
    -- Fifteen yards, no pet, not engaged: ten yards at seven a second is
    -- under two seconds. Not enough for Aimed Shot.
    W.distance, W.row = 15, nil
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "too close for the cast")
    W.distance = 35
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "far enough")
end }

T[#T + 1] = { "Concussive Shot: a mob charging us, or fleeing; never one on the pet, in melee, or already dazed", function()
    local W = hunter_bundle()
    W.in_combat = true
    W.pet_sent = 7
    W.distance, W.row = 20, { targeting_me = true, closing = 7, time_to_reach = 2.1, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "dazes a charging mob")

    W.row = { targeting_pet = true, closing = 7, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), false, "not a mob running at the pet")

    W.row = { targeting_pet = true, closing = -7, activity = "fleeing", engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "a runner is slowed")

    W.distance, W.row = 4, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), false, "inside minimum range it is Wing Clip's job")

    W.distance, W.row = 20, { targeting_me = true, closing = 7, engaged = true }
    W.debuffs["Concussive Shot"] = true
    assert_eq(W.rule("leveling", "Concussive Shot"), false, "already dazed")
end }

T[#T + 1] = { "a mob that reached us is clipped, then the step out replaces the melee swings", function()
    local W = hunter_bundle()
    W.in_combat = true
    W.pet_sent = 7
    W.distance, W.row = 4, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Wing Clip"), true, "clip the mob that is on us")
    assert_eq(W.rule("leveling", "Raptor Strike"), true, "melee while stuck")

    W.debuffs["Wing Clip"] = true
    assert_eq(W.rule("leveling", "Wing Clip"), false, "already clipped")
    W.kite_active = true
    assert_eq(W.rule("leveling", "Raptor Strike"), false, "no swing while stepping out")
    assert_eq(W.rule("leveling", "Mongoose Bite"), false, "no bite while stepping out")

    W.debuffs["Wing Clip"], W.kite_active = nil, false
    W.row = { targeting_pet = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Wing Clip"), false, "a mob on the pet will not follow; no clip")
end }

T[#T + 1] = { "Auto Shot: standing in range for over a swing with no shot is evidence it stopped", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 25, { targeting_me = true, closing = 0, engaged = true }

    assert_eq(W.rule("leveling", "Auto Shot"), true, "pressed when wanted")
    assert_eq(W.repeater.forgotten, 1, "a fresh target resets what the guard believed")
    assert_eq(W.repeater.stale, false, "just became eligible: no evidence yet")

    -- Shots have been seen this session, the last one a while ago, and we
    -- have stood in range for more than a swing since the press.
    W.repeater.last_shot = W.clock - 10
    W.clock = W.clock + 5
    W.rule("leveling", "Auto Shot")
    assert_eq(W.repeater.stale, true, "no shot for over a swing while able: it is not running")

    -- A recent shot means it is running, whatever else is true.
    W.clock = W.clock + 5
    W.repeater.last_shot = W.clock - 1
    W.rule("leveling", "Auto Shot")
    assert_eq(W.repeater.stale, false, "a shot within a swing: running")

    -- Moving breaks the eligibility clock: standing again starts it over.
    W.moving = true
    assert_eq(W.rule("leveling", "Auto Shot"), false, "not while moving")
    W.moving = false
    W.repeater.last_shot = W.clock - 20
    W.rule("leveling", "Auto Shot")
    assert_eq(W.repeater.stale, false, "just stopped moving: the shot is allowed its aim first")

    -- Out of range is not evidence either; the client's range check gates the press.
    W.distance = 60
    assert_eq(W.rule("leveling", "Auto Shot"), false, "not beyond ranged reach")

    -- A new target resets again.
    W.distance = 25
    W.target.get_guid = function() return "mob2" end
    W.rule("leveling", "Auto Shot")
    assert_eq(W.repeater.forgotten, 2, "reset on the new target")
end }

T[#T + 1] = { "opening: a selected mob in shot range is ours to pull; not a player, not someone else's fight, not in PvP", function()
    local W = hunter_bundle()
    -- A creature carries a class id like a player does; only the client's
    -- own is_player answer counts, and a nil answer is not a player.
    W.target.get_class = function() return 1 end
    W.target.is_player = function() return nil end
    W.distance = 30
    assert_eq(W.class.may_open(W.target), true, "a mob at thirty yards: open")
    W.target.is_player = function() return false end
    assert_eq(W.class.may_open(W.target), true, "a definite no is a mob too")

    W.distance = 6
    assert_eq(W.class.may_open(W.target), false, "inside minimum range: nothing ranged works")
    W.distance = 40
    assert_eq(W.class.may_open(W.target), false, "beyond shot range: walk closer first")
    W.distance = 30

    W.row = { in_combat = true, targeting_me = false, targeting_pet = false }
    assert_eq(W.class.may_open(W.target), false, "already fighting someone else")
    W.row = { in_combat = true, targeting_me = true }
    assert_eq(W.class.may_open(W.target), true, "fighting us: certainly")
    W.row = nil

    W.target.is_player = function() return true end
    local yes, why = W.class.may_open(W.target)
    assert_eq(yes, false, "a player is never pulled by accident")
    assert_eq(why, "target is a player", "and it says so")
    W.target.is_player = function() return false end

    W.may_pull = false
    assert_eq(W.class.may_open(W.target), false, "not where pulls are not ours to start")
    W.may_pull = true

    W.settings.pull_selected = false
    assert_eq(W.class.may_open(W.target), true, "a removed switch changes nothing (1.33.0)")
end }

T[#T + 1] = { "mana: specials are bought in tiers; a low bar keeps the opener and the sting, an empty one keeps nothing", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 30, { targeting_pet = true, engaged = true }   -- all the time in the world
    W.last_cast["Aimed Shot"] = 4                                       -- the opener is done; these are the fillers

    -- Plentiful: everything.
    W.power = 0.9
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "second Aimed Shot")
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "Multi-Shot filler")
    assert_eq(W.rule("leveling", "Arcane Shot"), true, "Arcane Shot filler")
    W.ttd = 9
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "sting on a nine-second mob")

    -- Comfortable, but the bar will not last this fight: the fillers stop,
    -- the second Aimed Shot stays. (It was a fixed 70% line until 1.33.0.)
    W.power, W.ttd = 0.6, 20
    W.power_empty, W.fight_left = 12, 20
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "second Aimed Shot still")
    assert_eq(W.rule("leveling", "Multi-Shot"), false, "no Multi-Shot filler")
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "no Arcane Shot filler")
    W.moving = true
    assert_eq(W.rule("leveling", "Arcane Shot"), true, "Arcane Shot on the move: nothing else casts")
    W.moving = false

    -- Low: the essentials only, and the sting only on a mob that takes every tick.
    W.power_empty = nil
    W.power = 0.3
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "no second Aimed Shot")
    W.last_cast["Aimed Shot"] = nil
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "the opener is still bought")
    W.ttd = 10
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "not on a ten-second mob")
    W.ttd = 15
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "on a fifteen-second mob")
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "the mark")

    -- The bar will not last the fight: nothing that costs mana but safety.
    W.posture = "RECOVER"
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "no opener")
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "no sting")
    W.ttd = 10
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "no mark on a short fight")
    W.ttd = 20
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "the mark pays for itself on a long one")
    W.distance, W.row = 20, { targeting_me = true, closing = 7, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "safety is never rationed")

    -- A pack: Multi-Shot is bought at any tier above empty.
    W.posture, W.power = "HEALTHY", 0.3
    W.distance, W.row = 30, { targeting_pet = true, engaged = true }
    W.spread = true
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "Multi-Shot on a pack when low")
    W.power = 0.1
    assert_eq(W.rule("leveling", "Multi-Shot"), false, "but not on an empty bar")
end }

T[#T + 1] = { "Auto Shot never waits for the pet: on at once for the pull and for every switch", function()
    local W = hunter_bundle()
    local said = {}
    W.P.log = { fmt = function(_, fmt, ...) said[#said + 1] = string.format(fmt, ...) end }
    W.target.get_name = function() return "Savannah Huntress" end

    -- The pull: pet sent half a second ago, the mob charging us. The sting
    -- waits for the pet; Auto Shot does not (was two to four seconds idle).
    W.pet_sent = 0.5
    W.row = { targeting_me = true, closing = 7, time_to_reach = 3, engaged = true }
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "the sting waits for the pet")
    W.repeater.fresh = true          -- what forget() does on the real guard
    assert_eq(W.rule("leveling", "Auto Shot"), true, "Auto Shot on the pull at once")
    assert_eq(said[#said], "Auto Shot: on for Savannah Huntress (new target)", "and the log says so")

    -- That mob dies; the next one of the fight is selected, charging us the same way.
    W.in_combat = true
    W.target.get_guid = function() return "mob2" end
    W.repeater.fresh = true
    assert_eq(W.rule("leveling", "Auto Shot"), true, "a switch mid-fight: at once too")
end }

T[#T + 1] = { "Forever: the guard is asked to re-arm after every shot, and each mob gets a trace line; Era is not", function()
    local era = hunter_bundle()
    assert_eq(era.repeat_opts.keep_on, true, "kept on everywhere")
    assert_eq(era.repeat_opts.rearm, false, "Era: no re-arm, the path it always ran")

    local W = hunter_bundle({ forever = true })
    assert_eq(W.repeat_opts.rearm, true, "Forever: one shot per press, so every shot gets the next press")

    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 25, { targeting_me = true, closing = 0, engaged = true }
    W.repeater.fresh = true
    W.repeater.shots = 0
    assert_eq(W.rule("leveling", "Auto Shot"), true, "the new target's press")
    W.repeater.shots = 1
    W.repeater.pressed_at, W.repeater.last_fired = W.clock, W.clock + 0.05
    W.clock = W.clock + 1
    assert_eq(W.rule("leveling", "Auto Shot"), true, "the next swing's press, after its shot")
    W.repeater.shots = 2
    W.repeater.pressed_at = W.clock
    W.clock = W.clock + 1.6
    assert_eq(W.rule("leveling", "Auto Shot"), true, "no shot yet: tried again")
    assert_eq(#W.traced, 0, "nothing said while the mob is still the target")
    -- What the client said about that press (1.52.0).
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 50, "Target needs to be in front of you.", "ERR_BADATTACKFACING" })
    W.handlers["jcore.game_event.UNIT_SPELLCAST_FAILED_QUIET"]({ "player", "Cast-3-1", 75 })
    W.handlers["jcore.game_event.UNIT_SPELLCAST_FAILED"]({ "player", "Cast-3-2", 2973 })
    W.clock = W.clock + 3
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 62, "Ability is not ready yet.", "ERR_ABILITY_COOLDOWN" })

    -- The next mob: the last one's line goes to the trace.
    W.target.get_guid = function() return "Creature-0-0-0-0-3-0000410C5D" end
    W.repeater.fresh = true
    W.rule("leveling", "Auto Shot")
    assert_eq(#W.traced, 1, "one line for the mob just left")
    assert(W.traced[1]:find("hunter Auto Shot at mob: 3 presses (1 new target, 1 after a shot, 1 retries), 2 shots", 1, true),
        "it says what the presses were and what they shot: " .. W.traced[1])
    assert(W.traced[1]:find("refused 1 (quietly 1)", 1, true), "Auto Shot's refusal, not Raptor Strike's: " .. W.traced[1])
    assert(W.traced[1]:find("errors: Target needs to be in front of you. x1", 1, true),
        "the red text next to a press: " .. W.traced[1])
    assert(not W.traced[1]:find("not ready", 1, true), "not red text long after it")
    assert(W.traced[1]:find("; ready %d+%.%ds, moving %d+%.%ds, too close"), "where the time went: " .. W.traced[1])

    -- Where the time went, on half-second ticks: gaps of a second or more
    -- are not counted (the rotation was not asking).
    local R = hunter_bundle({ forever = true })
    R.in_combat, R.pet_alive = true, false
    R.distance, R.row = 25, { targeting_me = true, closing = 0, engaged = true }
    R.repeater.fresh, R.repeater.shots = true, 0
    R.rule("leveling", "Auto Shot")
    R.repeater.press_wanted = function() return false end
    for _ = 1, 4 do
        R.clock = R.clock + 0.5
        R.rule("leveling", "Auto Shot")
    end
    R.clock = R.clock + 5
    R.rule("leveling", "Auto Shot")
    R.target.get_guid = function() return "mob3" end
    R.rule("leveling", "Auto Shot")
    assert(R.traced[1] and R.traced[1]:find("ready 2.0s", 1, true),
        "two seconds standing in range: " .. tostring(R.traced[1]))

    -- Melee attack left on (1.52.0): a press with no shot after it, the
    -- attack flag still on at range -- melee is stopped, once per such press.
    local M = hunter_bundle({ forever = true })
    local stops = 0
    _G.core.input = { stop_attack = function() stops = stops + 1 end }
    M.player.is_auto_attacking = function() return true end
    M.in_combat, M.pet_alive = true, false
    M.distance, M.row = 25, { targeting_me = true, closing = 0, engaged = true }
    M.repeater.fresh, M.repeater.shots = true, 0
    M.rule("leveling", "Auto Shot")
    assert_eq(stops, 0, "not on a new target's press")
    M.repeater.shots = 1
    M.repeater.pressed_at, M.repeater.last_fired = M.clock, M.clock + 0.05
    M.clock = M.clock + 1
    M.rule("leveling", "Auto Shot")
    assert_eq(stops, 0, "not after a shot: Auto Shot is running")
    M.repeater.pressed_at = M.clock
    M.clock = M.clock + 1.6
    M.rule("leveling", "Auto Shot")
    assert_eq(stops, 1, "no shot after the last press, flag on: melee is stopped")
    M.target.get_guid = function() return "mob4" end
    M.repeater.fresh = true
    M.rule("leveling", "Auto Shot")
    assert(M.traced[1]:find("; melee attack stopped 1", 1, true), "said in the trace: " .. M.traced[1])

    local quiet = hunter_bundle()
    quiet.in_combat, quiet.distance = true, 25
    quiet.rule("leveling", "Auto Shot")
    quiet.target.get_guid = function() return "mob2" end
    quiet.rule("leveling", "Auto Shot")
    assert_eq(#quiet.traced, 0, "Era: no trace lines")
end }

T[#T + 1] = { "the mark stays on a live mob of the fight instead of following every target switch", function()
    local W = hunter_bundle()
    W.in_combat = true
    local other = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "mob2" end,
    }
    W.engaged = { W.target, other }
    W.debuffs_on[other] = { ["Hunter's Mark"] = true }   -- ours, on the other mob

    W.health[other] = 0.7
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "not moved off a mob with 70% left")
    W.health[other] = 0.1
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "moved once that mob is nearly dead")
    W.health[other] = 0.7
    W.debuffs_on[other] = nil
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "not ours anywhere: mark the target")

    -- The pull itself is never held back by this.
    W.in_combat = false
    W.debuffs_on[other] = { ["Hunter's Mark"] = true }
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "a fresh pull is marked")
end }

-- 1.74.0: the live log (a five-man on Forever) pressed the mark at every mob
-- the group killed, each refused "Your target is dead".
T[#T + 1] = { "no mark on a mob about to die (1.74.0)", function()
    local W = hunter_bundle()
    W.in_combat = true
    W.ttd = 2
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "dies in 2 s: no mark")
    W.ttd = 0
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "at no health (time to die 0): no mark")
    W.ttd = math.huge
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "not measured yet: marked")
    W.ttd = 8
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "eight seconds left: marked")
    W.in_combat, W.ttd = false, 2
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "out of a fight the mark is the pull")
end }

T[#T + 1] = { "every profile shares the pull: mark, slow and clip rules are in all four", function()
    local W = hunter_bundle()
    for _, key in ipairs(W.class.profile_order) do
        local names = {}
        for _, rule in ipairs(W.class.profiles[key].rules) do names[rule[1]] = true end
        for _, want in ipairs({ "Hunter's Mark", "Concussive Shot", "Wing Clip", "Auto Shot", "Mend Pet" }) do
            assert(names[want], key .. " lacks " .. want)
        end
    end
    local seen = table.concat(W.settings_seen, ",")
    assert(seen:find("step_out", 1, true) and seen:find("kite", 1, true), "legs have their toggles")
end }

-- --- the pet's Growl ------------------------------------------------------------

local function pet_bundle()
    local W = { clock = 1000.0, context = "solo", mode = 2, autocast = nil, enabled = 0, disabled = 0 }
    -- The pet's book: id 1 is Growl, whose autocast the older tests read as
    -- W.autocast; any other id keeps its own in W.ac (1.71.0).
    W.book, W.ac, W.on_n, W.off_n = { [1] = { name = "Growl" } }, {}, {}, {}
    local pet = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return W.pet_guid or "pet" end,
        get_target = function() return W.pet_holds end,
        is_in_combat = function() return W.pet_fighting == true end,
    }
    local player = {
        get_pet = function() return pet end,
        can_attack = function(_, u) return not (W.friends and W.friends[u]) end,
    }
    -- Your target: a live mob, as in a fight (1.87.1: with nothing selected
    -- the pet stays with you). A test of nothing selected sets it nil.
    W.target = { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return "picked" end, get_name = function() return "Picked" end }
    _G.core = {
        time = function() return W.clock end,
        spell_book = {
            get_pet_spells = function()
                local ids = {}
                for id in pairs(W.book) do ids[#ids + 1] = id end
                return ids
            end,
            get_pet_action_info = function(id)
                local b = W.book[id]
                if not b then return nil end
                local on = W.ac[id]
                if id == 1 then on = W.autocast end
                return { name = b.name, auto_cast_enabled = on, auto_cast_allowed = b.allowed, in_range = W.in_range,
                         is_token = b.token == true, is_active = b.active == true }
            end,
        },
        input = {
            enable_pet_autocast = function(id)
                if id == 1 or id == nil then W.enabled = W.enabled + 1; W.autocast = true return end
                W.on_n[id] = (W.on_n[id] or 0) + 1; W.ac[id] = true
            end,
            disable_pet_autocast = function(id)
                if id == 1 or id == nil then W.disabled = W.disabled + 1; W.autocast = false return end
                W.off_n[id] = (W.off_n[id] or 0) + 1; W.ac[id] = false
            end,
            pet_attack = function() end,
            pet_cast_target_spell = function(id, target) W.pet_sent[#W.pet_sent + 1] = { id = id, target = target } end,
            -- The client's stance switch: the bar's active stance button moves.
            set_pet_passive = function()
                W.passive_n = (W.passive_n or 0) + 1
                for _, b in pairs(W.book) do
                    if b.token then b.active = b.name == "PET_MODE_PASSIVE" end
                end
            end,
            set_pet_defensive = function()
                W.defensive_n = (W.defensive_n or 0) + 1
                for _, b in pairs(W.book) do
                    if b.token then b.active = b.name == "PET_MODE_DEFENSIVE" end
                end
            end,
        },
    }
    W.pet_sent, W.handlers = {}, {}
    function W.fire(event, args)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(args) end
    end
    W.casts, W.ready, W.owned = {}, {}, {}
    local P = {
        log = { fmt = function() end, info = function() end, once = function() end },
        ctx = {
            on = function(event, fn)
                W.handlers[event] = W.handlers[event] or {}
                table.insert(W.handlers[event], fn)
            end,
            spells = { name = function(id) return W.book[id] and W.book[id].name or "" end },
            enemies = { get = function(u) return W.rows and W.rows[u] or nil end },
            every = function() end,
            tick = function(fn) W.tick = fn end,
            emit = function() end,
            cast = function(request) W.casts[#W.casts + 1] = request end,
            PRIORITY = { UTILITY = 30 },
        },
        units = {
            player = function() return player end,
            health_fraction = function(u) return u == pet and W.pet_hp or 1 end,
            by_guid = function(guid) return W.by_guid and W.by_guid[guid] or nil end,
            distance = function(u) return u == pet and (W.pet_dist or 2) or 10 end,
        },
        combat = {
            target = function() return W.target end,
            in_combat = function() return W.in_combat == true end,
        },
        spellbook = {
            ready = function(name) return W.ready[name] == true end,
            id = function() return 136 end,
        },
        targeting = {
            SOLO = "solo",
            context = function() return W.context end,
            reclaim_target = function() return nil end,
        },
        rotation = {
            has_rule = function(name) return W.owned[name] == true end,
            helpers = {},
            may_engage_unit = function() return W.may_engage ~= false end,
        },
        opt = function(id, default)
            if id == "pet_mode" then return W.mode end
            if id == "pet_heal" then return W.pet_heal == true end
            if id == "pet_heal_only_tanking" then return false end
            if id == "rot_enabled" then return not W.rot_off end
            return default
        end,
        tune = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
        master_on = function() return true end,
        rotation_active = function() return true end,
    }
    W.pet = make_pet(P)
    W.P = P
    return W
end

T[#T + 1] = { "Growl follows context in Assist: on when solo, off in a group, on in Tank", function()
    local W = pet_bundle()
    assert_eq(W.pet.growl_wanted(), true, "assist, solo")
    W.tick()
    assert_eq(W.enabled, 1, "turned on")

    W.context = "party"
    assert_eq(W.pet.growl_wanted(), false, "assist, party")
    W.tick()
    assert_eq(W.disabled, 1, "turned off on joining a group")

    W.mode = 3
    assert_eq(W.pet.growl_wanted(), true, "tank, party")
    W.tick()
    assert_eq(W.enabled, 2, "back on in tank mode")
    assert_eq(W.pet.stats().growl, true, "readout says so")
end }

T[#T + 1] = { "Mend Pet has one owner: the pet module stands aside for the class rule", function()
    local W = pet_bundle()
    W.pet_heal, W.in_combat, W.pet_hp = true, true, 0.1
    -- Holding a mob: a pet holding nothing is not about to be hit again.
    W.pet_holds = { is_valid = function() return true end }
    W.ready["Mend Pet"] = true

    -- No rule for it in the active profile: the healing pass casts it, on the pet.
    W.tick()
    assert_eq(#W.casts, 1, "the pet module heals")
    assert_eq(W.casts[1].reason, "Mend Pet", "with Mend Pet")

    -- The hunter's profile has the rule: the pass stands aside, every time.
    W.owned["Mend Pet"] = true
    W.clock = W.clock + 10
    W.tick()
    W.clock = W.clock + 10
    W.tick()
    assert_eq(#W.casts, 1, "no second Mend Pet from the pet module")
end }

T[#T + 1] = { "the pet called back is kept off that mob: the assist pass does not send it straight back", function()
    local W = pet_bundle()
    W.follows = 0
    _G.core.input.set_pet_follow = function() W.follows = W.follows + 1 end
    local attacks = 0
    _G.core.input.pet_attack = function() attacks = attacks + 1 end
    local mob = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return "mob" end,
        get_name = function() return "Savannah Prowler" end,
    }
    assert_eq(W.pet.recall("evading", "mob", 8), true, "the call went out")
    assert_eq(W.follows, 1, "follow pressed")
    W.clock = W.clock + 1
    assert_eq(W.pet.send(mob, "assist", true), false, "kept off it, even forced")
    assert_eq(attacks, 0, "no attack order")
    W.clock = W.clock + 8
    assert_eq(W.pet.send(mob, "assist"), true, "and free again after")
end }

T[#T + 1] = { "the aimed taunt: Growl is off autocast while the engine aims it, back on when it lets go (1.68.0)", function()
    local W = pet_bundle()
    W.tick()
    assert_eq(W.autocast, true, "solo assist: on, as before")

    assert_eq(W.pet.aim_taunt(), "Growl", "the engine aims Growl")
    assert_eq(W.autocast, false, "off at once, not on the next pet tick")
    assert_eq(W.pet.taunt_aimed(), true, "and says so")
    W.clock = W.clock + 0.3
    W.pet.aim_taunt()
    W.tick()
    assert_eq(W.autocast, false, "still off while the engine keeps asking")

    -- The engine stops asking (the rotation off, mounted): back after the lease.
    W.clock = W.clock + 2
    W.tick()
    assert_eq(W.autocast, true, "the engine let go: autocast back on")
    assert_eq(W.pet.taunt_aimed(), false, "not aimed any more")

    -- The rotation switched off: the pet tick's gates would stop sync_growl,
    -- the release runs before them.
    W.pet.aim_taunt()
    assert_eq(W.autocast, false, "aimed again")
    local P = W.pet
    W.clock = W.clock + 2
    W.rot_off = true
    local before = W.enabled
    W.tick()
    assert_eq(W.autocast, true, "put back even with the rotation off")
    assert_eq(W.enabled, before + 1, "one call")

    -- Paused or unloaded: at once, no lease.
    P.aim_taunt()
    P.release_taunt(true)
    assert_eq(W.autocast, true, "the plugin stopping puts it back at once")

    -- Off and Focus modes are never aimed.
    W.mode = 1
    assert_eq(P.aim_taunt(), nil, "pet mode Off: not aimed")
    W.mode = 4
    assert_eq(P.aim_taunt(), nil, "pet mode Focus: not aimed")
end }

T[#T + 1] = { "the aimed taunt: a fresh pet's autocast is read again, not taken from the last pet (1.68.0)", function()
    local W = pet_bundle()
    W.pet.aim_taunt()
    assert_eq(W.autocast, false, "off for the engine")
    -- The pet dies; a new one comes out with Growl on autocast, as new pets do.
    W.pet_guid, W.autocast = "pet-2", true
    W.clock = W.clock + 0.3
    W.pet.aim_taunt()
    W.tick()
    assert_eq(W.autocast, false, "the new pet's Growl is taken off autocast too")
end }

T[#T + 1] = { "the aimed taunt: its clock, from our press and the pet's own casts; a refused press was never used (1.68.0)", function()
    local W = pet_bundle()
    local mob = { is_valid = function() return true end, get_guid = function() return "mob" end }
    assert_eq(W.pet.ready_in("Growl"), 0, "never used: ready")
    assert_eq(W.pet.cast("Growl", mob), true, "pressed")
    assert(math.abs(W.pet.ready_in("Growl") - 5) < 0.01, "five seconds, Growl's cooldown")
    W.fire("jcore.game_event.UNIT_SPELLCAST_FAILED", { "pet", "guid", 1 })
    assert_eq(W.pet.ready_in("Growl"), 0, "the client turned it down: still ready")

    -- The autocast fired it (before the engine took it): the pet's own event.
    W.clock = W.clock + 1
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "guid", 1 })
    assert(math.abs(W.pet.ready_in("Growl") - 5) < 0.01, "seen: five seconds from now")
    W.clock = W.clock + 5
    assert_eq(W.pet.ready_in("Growl"), 0, "and ready again after")
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "guid", 1 })
    assert_eq(W.pet.ready_in("Growl"), 0, "our own casts are not the pet's")
end }

T[#T + 1] = { "the aimed taunt: aimed at another mob, the client's range answer (about the pet's own target) is not asked (1.68.0)", function()
    local W = pet_bundle()
    local function mob(guid)
        return { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return guid end }
    end
    local own, add = mob("own"), mob("add")
    W.pet_holds = own
    W.in_range = false
    assert_eq(W.pet.cast("Growl", own), false, "its own target out of range: refused, as before")
    assert_eq(W.pet.cast("Growl", add), true, "another mob, measured by the caller: sent")
    assert_eq(W.pet_sent[#W.pet_sent].target, add, "at that mob")
end }

T[#T + 1] = { "the aimed taunt: switched off even when the client's flag already reads off (1.68.1)", function()
    -- The first in-game log: the pet kept Growling by itself while the engine
    -- aimed it. The switch-off had been skipped because the flag read "off".
    local W = pet_bundle()
    W.autocast = false
    W.pet.aim_taunt()
    assert_eq(W.disabled, 1, "switched off without asking the flag")
    W.clock = W.clock + 0.3
    W.pet.aim_taunt()
    W.tick()
    assert_eq(W.disabled, 1, "once per pet, not every tick")
    -- Let go: back on, again without asking the flag.
    W.autocast = true
    W.clock = W.clock + 2
    W.tick()
    assert_eq(W.enabled, 1, "switched back on although the flag already read on")
end }

T[#T + 1] = { "the aimed taunt: a Growl the pet uses by itself -- switched off again, then left on autocast (1.68.1)", function()
    local W = pet_bundle()
    local function hold(seconds)
        local steps = math.floor(seconds / 0.5 + 0.5)
        for _ = 1, steps do
            W.clock = W.clock + 0.5
            W.pet.aim_taunt()
        end
    end
    W.pet.aim_taunt()
    assert_eq(W.disabled, 1, "taken")
    -- One already on its way as it was switched off proves nothing.
    W.clock = W.clock + 0.3
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g1", 1 })
    assert_eq(W.disabled, 1, "in flight: ignored")

    hold(2)
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g2", 1 })
    assert_eq(W.disabled, 2, "the pet Growled by itself: switched off again")
    assert_eq(W.pet.taunt_stuck(), nil, "not given up yet")
    assert(W.pet.ready_in("Growl") > 4.9, "and the clock knows it was used")

    hold(2)
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g3", 1 })
    local why = W.pet.taunt_stuck()
    assert(why and why:find("by itself", 1, true), "again: it will not stay off here -- " .. tostring(why))
    assert_eq(W.autocast, true, "left on autocast, as the mode wants")
    assert_eq(W.pet.aim_taunt(), nil, "and the engine stops aiming it")
    assert_eq(W.pet.taunt_aimed(), false, "not aimed")

    -- Our own press, confirmed, is never "by itself".
    local O = pet_bundle()
    local mob = { is_valid = function() return true end, get_guid = function() return "mob" end }
    O.pet.aim_taunt()
    O.clock = O.clock + 2
    O.pet.aim_taunt()
    O.pet.cast("Growl", mob)
    O.clock = O.clock + 0.2
    O.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g4", 1 })
    assert_eq(O.disabled, 1, "ours: nothing switched")
end }

T[#T + 1] = { "the aimed taunt: a refused press is not five seconds lost; refused again, unconfirmed -- left on autocast (1.68.1)", function()
    local W = pet_bundle()
    local mob = { is_valid = function() return true end, get_guid = function() return "mob" end }
    local NOT_READY = { 0, "Spell is not ready yet.", "SPELL_FAILED_NOT_READY" }
    W.pet.aim_taunt()
    W.clock = W.clock + 2
    W.pet.aim_taunt()
    W.pet.cast("Growl", mob)
    W.clock = W.clock + 0.1
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", NOT_READY)
    local left = W.pet.ready_in("Growl")
    assert(left > 0.8 and left < 1.01, "asked again in a second, not five: " .. left)
    assert_eq(W.pet.taunt_stuck(), nil, "one refusal: still aimed")

    -- An error that is not about readiness changes nothing.
    W.clock = W.clock + 1.2
    W.pet.aim_taunt()
    W.pet.cast("Growl", mob)
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Out of range.", "SPELL_FAILED_OUT_OF_RANGE" })
    assert(W.pet.ready_in("Growl") > 4.9, "not a refusal for readiness")

    W.clock = W.clock + 5.1
    W.pet.aim_taunt()
    W.pet.cast("Growl", mob)
    W.clock = W.clock + 0.1
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", NOT_READY)
    local why = W.pet.taunt_stuck()
    assert(why and why:find("refused", 1, true), "refused twice, never confirmed: left on autocast -- " .. tostring(why))
    assert_eq(W.autocast, true, "back on")

    -- Somebody else's error, laid on our press: the pet's own event says it went out.
    local C = pet_bundle()
    C.pet.aim_taunt()
    C.clock = C.clock + 2
    for _ = 1, 3 do
        C.pet.aim_taunt()
        C.pet.cast("Growl", mob)
        C.clock = C.clock + 0.1
        C.fire("jcore.game_event.UI_ERROR_MESSAGE", NOT_READY)
        C.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g", 1 })
        C.clock = C.clock + 5.2
    end
    assert_eq(C.pet.taunt_stuck(), nil, "every press confirmed by the pet: the errors were not ours")
end }

T[#T + 1] = { "pet mode Focus: the pinned unit is M.focus, the pet's power M.focus_power -- one name each (1.68.2)", function()
    local W = pet_bundle()
    local attacks = {}
    _G.core.input.pet_attack = function(u) attacks[#attacks + 1] = u end
    local mob = { is_valid = function() return true end, is_dead = function() return false end,
                  get_guid = function() return "mob" end, get_name = function() return "Plainstrider" end }
    W.P.units.by_guid = function(guid) return guid == "mob" and mob or nil end
    W.pet.set_focus(mob)
    W.mode = 4
    W.tick()
    assert_eq(W.pet.focus(), mob, "M.focus is the pinned unit")
    assert_eq(attacks[1], mob, "Focus mode sends the pet at it")
    assert_eq(W.pet.focus_power(), nil, "and the power read has its own name (no power in this harness)")
end }

T[#T + 1] = { "pet skills: one the engine presses is off autocast, back as it was after the lease; one with no autocast is only pressed (1.71.0)", function()
    local W = pet_bundle()
    W.book[2] = { name = "Furious Howl" }
    W.book[3] = { name = "Sacrifice", allowed = false }
    W.book[4] = { name = "Cower" }
    W.fire("jambix.aio.spells_changed")
    W.tick()

    assert_eq(W.pet.aim("Furious Howl"), true, "held")
    assert_eq(W.ac[2], false, "off autocast")
    assert_eq(W.pet.aimed("Furious Howl"), true, "and says so")
    W.clock = W.clock + 0.5
    W.pet.aim("Furious Howl")
    assert_eq(W.off_n[2], 1, "once per pet, not every pass")
    assert_eq(W.pet.aim("Sacrifice"), true, "a skill with no autocast is held too")
    assert_eq(W.off_n[3], nil, "but its autocast is never touched")
    W.pet.aim("Cower", false)
    assert_eq(W.ac[4], false, "Cower off")

    W.clock = W.clock + 2
    W.tick()
    assert_eq(W.ac[2], true, "the engine let go: Furious Howl back on autocast")
    assert_eq(W.ac[4], false, "Cower goes back off: it was held to go back off")
    assert_eq(W.pet.aimed("Furious Howl"), false, "not held")
    assert(W.pet.skill("Furious Howl") and W.pet.skill("Furious Howl").cost == 60, "the spell tables' numbers: 60 focus")
end }

T[#T + 1] = { "pet skills: each client's own spell tables -- Furious Howl waits 30 s on Forever, 10 on Era (1.78.2)", function()
    local E = pet_bundle()
    assert_eq(E.pet.skill("Furious Howl").cd, 10, "Era: a 10 s cooldown")
    assert_eq(E.pet.skill("Dismember"), nil, "Era has no Dismember")

    local F = pet_bundle()
    F.P.forever = true
    F.pet = make_pet(F.P)
    assert_eq(F.pet.skill("Furious Howl").cd, 30, "Forever: a 30 s cooldown")
    assert_eq(F.pet.skill("Furious Howl").cost, 60, "and the same 60 focus")
    assert(F.pet.skill("Dismember"), "Forever's own skills are known there")
    assert_eq(F.pet.skill("Growl").cd, 5, "Growl is 5 s on both")

    -- The clock follows the tables: pressed now, ready in 30 s, not 10.
    F.book[2] = { name = "Furious Howl" }
    F.fire("jambix.aio.spells_changed")
    F.tick()
    assert_eq(F.pet.cast("Furious Howl", F.pet.pet()), true, "pressed")
    local left = F.pet.ready_in("Furious Howl")
    assert(left > 29.9 and left <= 30, "its Forever cooldown: " .. left)
end }

T[#T + 1] = { "pet skills: inside the pet's global cooldown a refusal proves nothing; Growl is off that cooldown (1.71.0)", function()
    local W = pet_bundle()
    W.book[2] = { name = "Dash" }
    W.book[5] = { name = "Claw" }
    W.fire("jambix.aio.spells_changed")
    local NOT_READY = { 0, "Spell is not ready yet.", "SPELL_FAILED_NOT_READY" }
    W.pet.aim("Dash")
    W.clock = W.clock + 2
    for _ = 1, 3 do
        W.pet.aim("Dash")
        W.pet.cast("Dash", W.pet.pet())
        assert(W.pet.ready_in("Dash") > 29, "sent: its 30 s cooldown")
        W.clock = W.clock + 0.1
        W.fire("jcore.game_event.UI_ERROR_MESSAGE", NOT_READY)
        local left = W.pet.ready_in("Dash")
        assert(left > 1.3 and left <= 1.5, "refused: asked again after the pet's global cooldown -- " .. left)
        W.clock = W.clock + 1.6
    end
    assert_eq(W.pet.stuck("Dash"), nil, "three refusals inside the global cooldown: never given up")

    -- The pet's own Claw starts that cooldown; Growl is not on it.
    W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "pet", "g", 5 })
    assert(W.pet.ready_in("Dash") > 1.4, "after its Claw, Dash waits the global cooldown")
    assert_eq(W.pet.ready_in("Growl"), 0, "Growl does not")
end }

T[#T + 1] = { "the stance: always Passive -- Aggressive and Defensive switched, the rotation off too, an unreadable one per pet and after each fight (1.75.2)", function()
    local function bar(V, active)
        V.book[100] = { name = "PET_MODE_AGGRESSIVE", token = true, active = active == "AGGRESSIVE" }
        V.book[101] = { name = "PET_MODE_DEFENSIVE", token = true, active = active == "DEFENSIVE" }
        V.book[102] = { name = "PET_MODE_PASSIVE", token = true, active = active == "PASSIVE" }
        V.fire("jambix.aio.spells_changed")
    end
    local W = pet_bundle()
    bar(W, "AGGRESSIVE")
    assert_eq(W.pet.stance(), "PET_MODE_AGGRESSIVE", "read off the bar")
    W.tick()
    assert_eq(W.passive_n, 1, "Aggressive: switched to Passive")
    W.fire("jambix.aio.spells_changed")
    W.clock = W.clock + 10
    W.tick()
    assert_eq(W.passive_n, 1, "Passive now: left as it is")
    assert_eq(W.defensive_n, nil, "never Defensive")

    local D = pet_bundle()
    bar(D, "DEFENSIVE")
    D.tick()
    assert_eq(D.passive_n, 1, "Defensive too (1.75.1 kept it Defensive)")

    local R = pet_bundle()
    R.rot_off = true
    bar(R, "AGGRESSIVE")
    R.tick()
    assert_eq(R.passive_n, 1, "the rotation switched off: still Passive")

    local E = pet_bundle()
    E.P.esp_only = true
    bar(E, "AGGRESSIVE")
    E.tick()
    assert_eq(E.passive_n, nil, "an ESP-only client: left alone")

    local U = pet_bundle()
    U.tick()
    assert_eq(U.passive_n, 1, "nothing on the bar says the stance: set")
    U.clock = U.clock + 10
    U.tick()
    assert_eq(U.passive_n, 1, "once per pet")
    U.fire("jcore.combat.leave")
    U.clock = U.clock + 10
    U.tick()
    assert_eq(U.passive_n, 2, "and again after a fight")
    U.pet_guid = "pet-2"
    U.clock = U.clock + 10
    U.tick()
    assert_eq(U.passive_n, 3, "a new pet: once more")
end }

T[#T + 1] = { "Passive: in a fight a pet with nothing to do is sent at a mob on it, else the nearest on you (1.75.2)", function()
    -- A mob is selected, one not in the fight, so the pet does not follow it
    -- there (1.74.1); with nothing selected it stays home (1.87.1).
    local W = pet_bundle()
    local attacks = {}
    _G.core.input.pet_attack = function(u) attacks[#attacks + 1] = u end
    local function mob(guid)
        local m = { dead = false }
        m.is_valid = function() return true end
        m.is_dead = function() return m.dead end
        m.get_guid = function() return guid end
        m.get_name = function() return guid end
        return m
    end
    local far_me, near_me, on_pet = mob("far_me"), mob("near_me"), mob("on_pet")
    W.list = {
        { obj = far_me, targeting_me = true, dist = 9 },
        { obj = near_me, targeting_me = true, dist = 4 },
        { obj = on_pet, targeting_pet = true, dist = 12 },
    }
    W.P.ctx.enemies.where = function(pred)
        local out = {}
        for _, r in ipairs(W.list) do if pred(r) then out[#out + 1] = r end end
        return out
    end
    W.in_combat = true
    W.tick()
    assert_eq(attacks[1], on_pet, "the mob on the pet first")
    W.pet_holds = on_pet
    W.clock = W.clock + 3
    W.tick()
    assert_eq(#attacks, 1, "busy with it: left there")
    on_pet.dead, W.pet_holds = true, nil
    W.list[3] = nil
    W.clock = W.clock + 3
    W.tick()
    assert_eq(attacks[2], near_me, "then the nearest one on you")

    local O = pet_bundle()
    local none = {}
    _G.core.input.pet_attack = function(u) none[#none + 1] = u end
    O.list = { { obj = mob("idle"), targeting_me = true, dist = 4 } }
    O.P.ctx.enemies.where = function(pred)
        local out = {}
        for _, r in ipairs(O.list) do if pred(r) then out[#out + 1] = r end end
        return out
    end
    O.in_combat, O.may_engage = false, false
    O.tick()
    assert_eq(#none, 0, "out of a fight: nothing (the pull is yours)")
end }

T[#T + 1] = { "nothing selected: the pet is called back, and sent at nothing until a mob is (1.87.1)", function()
    local W = pet_bundle()
    W.follows = 0
    _G.core.input.set_pet_follow = function() W.follows = W.follows + 1 end
    local attacks = {}
    _G.core.input.pet_attack = function(u) attacks[#attacks + 1] = u end
    local mob = { dead = false }
    mob.is_valid = function() return true end
    mob.is_dead = function() return mob.dead end
    mob.get_guid = function() return "mob" end
    mob.get_name = function() return "Carrion Bird" end
    W.target, W.in_combat, W.rows = mob, true, { [mob] = { engaged = true } }
    W.tick()
    assert_eq(attacks[1], mob, "selected and in the fight: the pet goes")
    assert_eq(W.pet.home(), false, "a mob selected: not home")
    W.pet_holds = mob

    W.target = nil
    assert_eq(W.pet.home(), true, "cleared: home")
    W.clock = W.clock + 0.3
    W.tick()
    assert_eq(W.follows, 0, "not at once: the auto-target may pick the next mob")
    W.clock = W.clock + 1
    W.tick()
    assert_eq(W.follows, 1, "a second with nothing selected: called back")
    assert_eq(W.pet.stats().reason, "home: nothing selected", "the readout says so")
    W.clock = W.clock + 1
    W.tick()
    assert_eq(W.follows, 1, "not every tick")
    W.clock = W.clock + 3
    W.tick()
    assert_eq(W.follows, 2, "still on it three seconds later: called again")
    W.pet_holds = nil
    W.clock = W.clock + 5
    W.tick()
    assert_eq(W.follows, 2, "with you: nothing to do")

    -- Nothing sends it while nothing is selected: not the rotation, not the
    -- defence, not a reaction, not a skill at a mob.
    W.P.ctx.enemies.where = function(pred)
        local r = { obj = mob, targeting_pet = true, dist = 3 }
        return pred(r) and { r } or {}
    end
    W.clock = W.clock + 1
    W.tick()
    assert_eq(#attacks, 1, "a mob hitting the pet: the defence waits")
    assert_eq(W.pet.send(mob, "react", true), false, "a send is refused")
    assert_eq(W.pet.cast("Growl", mob), false, "a skill at a mob is refused")
    assert_eq(#W.pet_sent, 0, "nothing pressed")

    -- A dead target or a friend selected is nothing selected.
    local corpse = { is_valid = function() return true end, is_dead = function() return true end,
                     get_guid = function() return "corpse" end }
    W.target = corpse
    assert_eq(W.pet.home(), true, "a dead mob selected: home")
    local friend = { is_valid = function() return true end, is_dead = function() return false end,
                     get_guid = function() return "friend" end }
    W.friends = { [friend] = true }
    W.target = friend
    assert_eq(W.pet.home(), true, "a friend selected: home")

    -- A mob selected again: the pet goes at once, no wait.
    W.target = mob
    W.clock = W.clock + 1
    W.tick()
    assert_eq(attacks[2], mob, "selected again: sent")
    assert_eq(W.pet.cast("Growl", mob), true, "and its skills go")
end }

T[#T + 1] = { "nothing selected: a pet sent earlier or fighting away is called back, the rotation off too; Focus and an ESP-only client are left alone (1.87.1)", function()
    local mob = { is_valid = function() return true end, is_dead = function() return false end,
                  get_guid = function() return "mob" end, get_name = function() return "Plainstrider" end }
    local function counting(V)
        V.follows = 0
        _G.core.input.set_pet_follow = function() V.follows = V.follows + 1 end
    end

    -- The client does not say what the pet is on (Forever): the mob it was sent at.
    local S = pet_bundle()
    counting(S)
    S.by_guid = { mob = mob }
    S.target, S.in_combat, S.rows = mob, true, { [mob] = { engaged = true } }
    S.tick()
    S.target = nil
    S.tick()
    S.clock = S.clock + 1.1
    S.tick()
    assert_eq(S.follows, 1, "sent at a mob still alive: called back")

    -- Nothing on it to read, but fighting 25 yd off.
    local F = pet_bundle()
    counting(F)
    F.target, F.pet_fighting, F.pet_dist = nil, true, 25
    F.tick()
    F.clock = F.clock + 1.1
    F.tick()
    assert_eq(F.follows, 1, "fighting away from you: called back")
    local N = pet_bundle()
    counting(N)
    N.target, N.pet_fighting, N.pet_dist = nil, true, 3
    N.tick()
    N.clock = N.clock + 1.1
    N.tick()
    assert_eq(N.follows, 0, "fighting beside you: it is with you")

    -- The rotation off: called back all the same (as Passive is kept).
    local R = pet_bundle()
    counting(R)
    R.rot_off, R.target, R.pet_holds = true, nil, mob
    R.tick()
    R.clock = R.clock + 1.1
    R.tick()
    assert_eq(R.follows, 1, "the rotation off: called back")

    -- Pet mode Focus with its unit alive: that pin is yours.
    local C = pet_bundle()
    counting(C)
    C.mode, C.by_guid = 4, { mob = mob }
    C.pet.set_focus(mob)
    C.target, C.pet_holds = nil, mob
    assert_eq(C.pet.home(), false, "Focus on a live unit: not home")
    C.tick()
    C.clock = C.clock + 1.1
    C.tick()
    assert_eq(C.follows, 0, "left on it")

    local E = pet_bundle()
    counting(E)
    E.P.esp_only = true
    E.target, E.pet_holds = nil, mob
    E.tick()
    E.clock = E.clock + 1.1
    E.tick()
    assert_eq(E.follows, 0, "an ESP-only client: left alone")
end }

T[#T + 1] = { "in a fight the pet follows your target only when that mob is in the fight (1.74.1)", function()
    local W = pet_bundle()
    local attacks = {}
    _G.core.input.pet_attack = function(u) attacks[#attacks + 1] = u end
    local mob = { is_valid = function() return true end, is_dead = function() return false end,
                  get_guid = function() return "mob" end, get_name = function() return "Plainstrider" end }
    W.target, W.in_combat, W.rows = mob, true, {}
    W.tick()
    assert_eq(#attacks, 0, "a mob clicked mid-fight that is not in it: the pet stays")
    W.rows[mob] = { engaged = true }
    W.clock = W.clock + 1
    W.tick()
    assert_eq(attacks[1], mob, "once it is in the fight: the pet goes")

    local O = pet_bundle()
    local sent = {}
    _G.core.input.pet_attack = function(u) sent[#sent + 1] = u end
    O.target, O.in_combat = mob, false
    O.may_engage = false
    O.tick()
    assert_eq(#sent, 0, "out of combat, a target the rotation may not open on: nothing")
    O.may_engage = true
    O.clock = O.clock + 1
    O.tick()
    assert_eq(sent[1], mob, "one it may: the pull, pet first, as before")
end }

-- --- the step out ---------------------------------------------------------------

local function kite_bundle()
    local W = {
        clock = 1000.0, distance = 4, moving = false,
        forward = nil, looks = 0, acquired = 0, released = 0,
        row = nil, debuffs = {}, known = { ["Auto Shot"] = true, ["Tame Beast"] = true },
        -- Ground height behind us. The terrain query answers 0 for "nothing
        -- there", so level ground is any small non-zero number.
        settings = { rot_enabled = true }, height = 0.5,
    }
    _G.core = {
        time = function() return W.clock end,
        addons = {},
        get_height_for_position = function() return W.height end,
    }
    local player = {
        is_moving = function() return W.moving end,
        can_attack = function() return true end,
        get_guid = function() return 1 end,
        get_unit_ranged_damage = function() return { speed = 2.5 } end,
    }
    local target = {
        is_valid = function() return true end,
        is_dead = function() return false end,
        get_guid = function() return 2 end,
    }
    local input = {
        CHANNEL = { MOVEMENT = "movement", FACING = "facing" },
        PRIORITY = { ROTATION = 50 },
        acquire = function() W.acquired = W.acquired + 1; return true end,
        release = function() W.released = W.released + 1; return true end,
        face = function() return true end,
        look_at = function() W.looks = W.looks + 1; return true end,
        set_key = function(_, down) W.forward = down; return true end,
        is_key_pressed = function() return false end,
    }
    local P = {
        log = { fmt = function() end },
        ctx = {
            input = input,
            on = function() end,
            tick = function(fn) W.tick = fn end,
            enemies = { get = function() return W.row end },
        },
        units = {
            player = function() return player end,
            player_position = function() return { x = 0, y = 0, z = 0 } end,
            position = function() return { x = W.distance, y = 0, z = 0 } end,
            distance = function() return W.distance end,
            is_facing = function() return true end,
            name = function() return "Boar" end,
        },
        combat = {
            in_combat = function() return true end,
            target = function() return target end,
        },
        spellbook = {
            known = function(name) return W.known[name] == true end,
            ids = function(name) return W.known[name] and { 75 } or nil end,
        },
        rotation = {
            active_class = function() return { key = "hunter" } end,
            cast_gate_busy = function() return false end,
            helpers = { debuff_up = function(_, name) return W.debuffs[name] == true end },
        },
        pet = { alive = function() return true end },
        opt = function(id, default)
            local v = W.settings[id]
            if v == nil then return default end
            return v
        end,
        master_on = function() return true end,
        rotation_active = function() return true end,
    }
    W.kite = make_kite(P)
    W.P = P
    return W
end

T[#T + 1] = { "step out: an unslowed mob on us is not run from; a clipped one is, until it is shootable", function()
    local W = kite_bundle()
    W.row = { targeting_me = true }
    W.tick()
    assert_eq(W.kite.active(), false, "not running from a mob that keeps pace")
    assert_eq(W.kite.stats().reason, "target in melee and not slowed", "reason")

    W.debuffs["Wing Clip"] = true
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "clipped: stepping out")
    assert_eq(W.forward, true, "running")
    assert(W.looks >= 1, "faced away")

    W.distance = 12
    W.tick()
    assert_eq(W.kite.active(), false, "clear of the dead zone")
    assert_eq(W.forward, false, "stopped running")
    assert(W.released >= 1, "movement released")
end }

T[#T + 1] = { "step out: a mob on the pet is walked away from without a clip, and a failed attempt waits", function()
    local W = kite_bundle()
    W.row = { targeting_pet = true }
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "on the pet: it will not follow")

    -- Four seconds and still inside: give up, and do not thrash.
    W.clock = W.clock + 4.1
    W.tick()
    assert_eq(W.kite.active(), false, "gave up")
    W.tick()
    assert_eq(W.kite.stats().reason, "last step out failed; waiting", "waits before retrying")
    W.clock = W.clock + 3.1
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "tries again later")
end }


T[#T + 1] = { "step out: a clipped add in melee that is not the target is walked away from, the target kept in range (1.58.0)", function()
    local W = kite_bundle()
    W.distance = 25                                    -- the target: shootable
    local add = { get_guid = function() return 3 end, guid = 3 }
    local add_row = { obj = add, guid = 3, dist = 3, targeting_me = true }
    W.P.ctx.enemies.all = function() return { add_row } end
    W.P.units.position = function(u)
        if u == add then return { x = -add_row.dist, y = 0, z = 0 } end
        return { x = W.distance, y = 0, z = 0 }
    end
    W.P.units.distance = function(u)
        if u == add then return add_row.dist end
        return W.distance
    end
    W.P.rotation.helpers.debuff_up = function(u, name) return u == add and W.clipped == true and name == "Wing Clip" end

    W.tick()
    assert_eq(W.kite.active(), false, "not clipped yet: it would follow")

    W.clipped = true
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "clipped: stepping clear of it")
    assert_eq(W.forward, true, "running")

    add_row.dist = 12
    W.tick()
    assert_eq(W.kite.active(), false, "clear of the add")
    assert_eq(W.kite.stats().reason, "clear of the add", "and says so")

    -- Stepping further would lose the target.
    add_row.dist = 3
    W.distance = 34
    W.clock = W.clock + 5
    W.tick()
    assert_eq(W.kite.active(), false, "the target would go out of range")
    assert_eq(W.kite.stats().reason, "stepping further would put the target out of range", "reason")
end }


T[#T + 1] = { "range is hitbox to hitbox (1.58.1): no Auto Shot ten yards from a mob's centre; Raptor Strike on a big mob at 6.5", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_alive = true, false
    W.row = { targeting_me = true, closing = 0, engaged = true }
    W.reach = 1.5
    -- The rotation's geometry (rotation.lua H.gap, H.in_melee), the player's reach 1.5.
    W.H.gap = function(_, d) return (d or W.distance) - 1.5 - W.reach end
    W.H.melee_range = function() return math.max(5, 1.5 + W.reach + 4 / 3) end
    W.H.in_melee = function(_, d) return (d or W.distance) <= W.H.melee_range() end

    W.distance = 10
    assert_eq(W.rule("leveling", "Auto Shot"), false, "seven yards from its edge: the client says too close")
    W.distance = 12
    assert_eq(W.rule("leveling", "Auto Shot"), true, "nine from its edge: shoot")

    W.reach, W.distance = 4, 6.5
    assert_eq(W.rule("leveling", "Raptor Strike"), true, "a big mob 6.5 yards off is in melee: strike it")
    assert_eq(W.rule("leveling", "Auto Shot"), false, "and no Auto Shot there")
end }

T[#T + 1] = { "step out (1.58.1): runs until the mob's EDGE is past the dead zone, not its centre", function()
    local W = kite_bundle()
    W.row = { targeting_pet = true }
    W.P.rotation.helpers.gap = function(_, d) return d - 3 end      -- both reaches 1.5
    W.distance = 4
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "inside the dead zone: stepping")
    W.distance = 11
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "eleven from the centre is eight from the edge: keep going")
    W.distance = 12.5
    W.tick()
    assert_eq(W.kite.active(), false, "nine and a half from the edge: shootable")
    assert_eq(W.kite.stats().reason, "target shootable", "and says so")
end }

T[#T + 1] = { "step out: no ground behind us means no step", function()
    local W = kite_bundle()
    W.row = { targeting_pet = true }
    W.height = 50   -- a cliff
    W.tick()
    assert_eq(W.kite.active(), false, "no step off a cliff")
    assert_eq(W.kite.stats().reason, "nowhere safe to step back to", "reason")
end }


T[#T + 1] = { "the spell window's forecast reads the wait for the pet and never starts it", function()
    local W = hunter_bundle()
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    W.pet_sent = nil

    -- A mob selected, nobody engaging: the window forecasts for a while.
    -- Its forecast ignores holding fire, so it asks about this mob long
    -- before the walk would.
    W.H.forecasting = function() return true end
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "the forecast waits as the walk would")
    W.clock = W.clock + 5
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "and its asking did not start the clock")

    -- The engage: the walk asks, and the pet module gets its full moment.
    W.H.forecasting = function() return false end
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "a moment for the pet module, from the engage")
    W.clock = W.clock + 2.5
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "then the shots go")

    -- The clock the walk started is the one the forecast reads.
    W.H.forecasting = function() return true end
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "the forecast reads the running clock")
end }

-- --- 1.84.0: which mobs get the mark; the sting on more than one ---------------------

T[#T + 1] = { "the mark on: every target, elites and bosses, bosses only, never (1.84.0)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat = true
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "every target (the default): a normal mob is marked")

    W.settings.mark_on = 3
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "bosses only: not a normal mob")
    W.rank = 1
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "bosses only: not an elite either")
    W.boss = true
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "bosses only: the client's boss flag")
    W.boss, W.rank = false, 3
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "bosses only: classification 3")
    W.debuffs["Hunter's Mark"] = true
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "a boss already marked: not again")
    W.debuffs["Hunter's Mark"] = nil

    W.settings.mark_on, W.rank = 2, 0
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "elites and bosses: not a normal mob")
    W.rank = 1
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "elites and bosses: an elite")
    W.rank = 2
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "elites and bosses: a rare elite")

    W.settings.mark_on, W.rank, W.boss = 4, 3, true
    assert_eq(W.rule("leveling", "Hunter's Mark"), false, "never: not even a boss")
    for _, profile in ipairs(W.class.profile_order) do
        assert_eq(W.rule(profile, "Hunter's Mark"), false, profile .. ": the setting holds in every profile")
    end
    local seen = table.concat(W.settings_seen, ",")
    assert(seen:find("mark_on", 1, true) and seen:find("sting_spread", 1, true), "both are class options")
end }

T[#T + 1] = { "the sting spreads to every mob in the fight by default, or up to the cap picked, each worth it on its own (1.84.0, 1.8.1)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_alive = true, false        -- no pet: no wait for it
    local function mob(guid)
        return { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return guid end }
    end
    local a, b, c = mob("a"), mob("b"), mob("c")
    W.engaged = { W.target, a, b, c }
    W.debuffs["Serpent Sting"] = true                -- the target has its sting

    -- What the engine does with `spread`: the rule asked about another mob.
    W.spreading = true
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "one stung: a second mob gets one")
    W.debuffs_on[a] = { ["Serpent Sting"] = true }
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "two stung: a third")
    W.debuffs_on[b] = { ["Serpent Sting"] = true }
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "three stung: a fourth (every mob, the default since 1.8.1)")
    W.settings.sting_spread = 3
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "up to 3: no fourth")

    -- Never a mob held by crowd control that damage breaks (1.8.1).
    W.settings.sting_spread = nil
    W.P.react = { out_of_fight = function() return true end }
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "a sheep is not stung awake")
    W.P.react = nil
    -- Nor one in the dead zone: the next mob is asked (1.8.1).
    W.distance = 6
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "an add in melee with you: not stung")
    W.distance = 30

    W.settings.sting_spread = 2
    W.debuffs_on[b] = nil
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "up to 2: two stung, done")
    W.settings.sting_spread = 1
    W.debuffs_on[a] = nil
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "my target only: never another mob")

    W.settings.sting_spread = 3
    W.ttd = 5
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "a mob about to die is not worth a sting")
    W.ttd = 20
    W.spreading = nil
    W.debuffs["Serpent Sting"] = nil
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "the target itself: as before, whatever the cap")

    for _, profile in ipairs(W.class.profile_order) do
        local found
        for _, rule in ipairs(W.class.profiles[profile].rules) do
            if rule[1] == "Serpent Sting" then found = rule end
        end
        assert(found and found.spread == true and found.dot == true, profile .. ": the sting rule spreads")
    end
end }

-- 1.8.1: the user, "the Rotation doesn't automatically Look for All targets
-- in combat with us and drop a Sting on them how come?" The pet's wait was
-- asked about every add the sting spread to, with one clock for all of them:
-- each add restarted it for the next, and with two it never ran out.
T[#T + 1] = { "the sting spreads without the pet's wait: every add of the fight, at once, however many (1.8.1)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat = true
    -- The pull still waiting: the pet sent a second ago, ten yards short.
    W.pet_sent, W.pet_on_target = 1.0, true
    W.pet_pos = { x = 20, y = 0, z = 0 }
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    local function mob(guid)
        return { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return guid end }
    end
    local a, b = mob("a"), mob("b")
    W.engaged = { W.target, a, b }
    --- The sting rule as the engine's spread asks it, about another mob.
    local function on(profile, unit)
        for _, rule in ipairs(W.class.profiles[profile].rules) do
            if rule[1] == "Serpent Sting" then
                local s = W.situation()
                s.target, s.spreading = unit, true
                return rule[2](s)
            end
        end
    end
    for _, profile in ipairs({ "leveling", "beast_mastery" }) do
        assert_eq(W.rule(profile, "Serpent Sting"), false, profile .. ": the pull's own target still waits for the pet")
        for round = 1, 3 do
            assert_eq(on(profile, a), true, profile .. ": the first add, round " .. round)
            assert_eq(on(profile, b), true, profile .. ": the second add, round " .. round)
        end
    end
end }

-- 1.8.1: the user, "ensure to have better Pet management when things like CC
-- kick off on a mob we dont want our pet to attack it".
T[#T + 1] = { "pet.fighting: the client's target, else the mob it was sent at while it lives, for 30 s (1.8.1)", function()
    local W = pet_bundle()
    local mob = { dead = false }
    mob.is_valid = function() return true end
    mob.is_dead = function() return mob.dead end
    mob.get_guid = function() return "mob" end
    mob.get_name = function() return "Boar" end
    W.by_guid = { mob = mob }
    assert_eq(W.pet.fighting(), nil, "sent nowhere, on nothing: nothing")
    W.pet_holds = mob
    assert_eq(W.pet.fighting(), mob, "the client's answer")
    W.pet_holds = nil
    assert_eq(W.pet.send(mob, "assist", true), true, "sent")
    assert_eq(W.pet.fighting(), mob, "the client says nothing: the mob it was sent at")
    W.clock = W.clock + 31
    assert_eq(W.pet.fighting(), nil, "not after 30 s")
    W.pet.send(mob, "assist", true)
    mob.dead = true
    assert_eq(W.pet.fighting(), nil, "nor once it is dead")
end }

T[#T + 1] = { "crowd control: never sent at a held mob nor a skill aimed there; on one, to your target, else what hits it, else home (1.8.1)", function()
    local function mob(guid)
        return { is_valid = function() return true end, is_dead = function() return false end,
                 get_guid = function() return guid end, get_name = function() return guid end }
    end
    local function bundle()
        local W = pet_bundle()
        W.attacks, W.follows, W.held = {}, 0, {}
        _G.core.input.pet_attack = function(u) W.attacks[#W.attacks + 1] = u end
        _G.core.input.set_pet_follow = function() W.follows = W.follows + 1 end
        W.P.react = { out_of_fight = function(u) return W.held[u] == true end }
        W.P.ctx.enemies.where = function(pred)
            local out = {}
            for _, r in ipairs(W.list or {}) do if pred(r) then out[#out + 1] = r end end
            return out
        end
        W.in_combat = true
        return W
    end
    local sheep, free, biter = mob("sheep"), mob("free"), mob("biter")

    -- Nothing sends it there, and no skill goes there.
    local W = bundle()
    W.held[sheep] = true
    W.target = free
    assert_eq(W.pet.send(sheep, "react", true), false, "a send at a sheep is refused")
    assert_eq(W.pet.assign(sheep, "react", 5), false, "and an assignment")
    assert_eq(W.pet.cast("Growl", sheep), false, "a skill at a sheep is refused")
    assert_eq(W.pet.cast("Growl", free), true, "at a free mob it goes")

    -- On a mob sheeped under it, not your target: to your target, once.
    local A = bundle()
    A.target, A.rows = free, { [free] = { engaged = true } }
    A.pet_holds = sheep
    A.held[sheep] = true
    A.tick()
    assert_eq(A.attacks[#A.attacks], free, "moved to your target")
    assert_eq(A.follows, 0, "not called home")
    A.clock = A.clock + 0.3
    local before = #A.attacks
    A.tick()
    assert_eq(#A.attacks, before, "not sent again while it turns round")

    -- Your target is the sheep: what is hitting the pet or you.
    local B = bundle()
    B.target, B.pet_holds = sheep, sheep
    B.held[sheep] = true
    B.list = { { obj = biter, targeting_pet = true, dist = 3 } }
    B.tick()
    assert_eq(B.attacks[#B.attacks], biter, "moved to what is hitting it")

    -- Nothing else in the fight: called home, once.
    local C = bundle()
    C.target, C.pet_holds = sheep, sheep
    C.held[sheep] = true
    C.tick()
    assert_eq(C.follows, 1, "called home")
    assert_eq(#C.attacks, 0, "sent nowhere")
    C.clock = C.clock + 0.3
    C.tick()
    assert_eq(C.follows, 1, "once while it turns round")

    -- A reaction's assignment on a mob sheeped afterwards: the pin ends and
    -- the pet comes off it.
    local D = bundle()
    D.target, D.rows, D.by_guid = free, { [free] = { engaged = true } }, { biter = biter }
    assert_eq(D.pet.assign(biter, "Pet: pick up the add", 5), true, "assigned")
    D.held[biter] = true
    assert_eq(D.pet.assigned(), nil, "the pin ends once it is held")
    D.pet_holds = biter
    D.clock = D.clock + 1
    D.tick()
    assert_eq(D.attacks[#D.attacks], free, "and the pet goes back to your target")

    -- Pet mode Focus on a mob that is sheeped: called home, not left biting.
    local F = bundle()
    F.mode, F.by_guid = 4, { biter = biter }
    F.pet.set_focus(biter)
    F.target, F.pet_holds = nil, biter
    F.held[biter] = true
    F.tick()
    assert_eq(F.follows, 1, "Focus: called home off the held mob")
end }

-- 1.7.4: the user, "hunter rotaiton burns through alot of mana doest let
-- the spirit recharge up". The live log went from 606 mana to 30 in three
-- minutes of seven-second fights, a mana press every two seconds of each.
T[#T + 1] = { "the refill: under half a bar only the essentials, until spirit has it back to 80% (1.7.4)", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 30, { targeting_pet = true, engaged = true }
    W.last_cast["Aimed Shot"] = 4                     -- opened: the second slot is the filler

    W.power = 0.9
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "a nearly full bar: the filler")
    W.power = 0.7
    assert_eq(W.rule("leveling", "Multi-Shot"), false, "under 80%: no filler, whatever the fight affords")
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "nor Arcane Shot")
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "the second Aimed Shot still")

    W.power = 0.49
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "under half: the refill starts")
    W.power = 0.7
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "back over half is not enough: spirit is still at it")
    W.last_cast["Aimed Shot"] = nil
    assert_eq(W.rule("leveling", "Aimed Shot", 1), true, "the opener is an essential")
    assert_eq(W.rule("leveling", "Hunter's Mark"), true, "and the mark")
    W.ttd = 10
    assert_eq(W.rule("leveling", "Serpent Sting"), false, "the sting only on a mob that takes every tick")
    W.ttd = 20
    assert_eq(W.rule("leveling", "Serpent Sting"), true, "which this one does")
    W.last_cast["Aimed Shot"] = 4
    W.power = 0.8
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "80%: the refill is over")
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "and the fillers are back")

    -- Spend freely: the rule as it was.
    W.settings.mana_use = 1
    W.power = 0.6
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "spend freely: the filler while the fight affords it")
    W.power = 0.46
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "and no refill")

    -- Save for regen: from 70% to 95%.
    W.settings.mana_use = 3
    W.power = 0.69
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "under 70%: the refill")
    W.power = 0.94
    assert_eq(W.rule("leveling", "Aimed Shot", 2), false, "until 95%")
    W.power = 0.95
    assert_eq(W.rule("leveling", "Aimed Shot", 2), true, "there")
    assert_eq(W.rule("leveling", "Multi-Shot"), true, "the fillers from 95%")

    assert(table.concat(W.settings_seen, ","):find("mana_use", 1, true), "a class option")
end }

T[#T + 1] = { "the hawks while the bar refills: one, and only on a mob that lives as long as a sting needs (1.7.4)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_alive = true, false
    W.known["Summon Hawk"] = true
    W.power, W.ttd = 0.9, 8
    assert_eq(W.rule("leveling", "Summon Hawk"), true, "a full bar: the first hawk")
    W.last_cast["Summon Hawk"] = 1
    assert_eq(W.rule("leveling", "Summon Hawk"), true, "and the second")
    W.power, W.ttd = 0.3, 20
    assert_eq(W.rule("leveling", "Summon Hawk"), false, "refilling: one is out, one is enough")

    local V = hunter_bundle({ forever = true })
    V.in_combat, V.pet_alive = true, false
    V.known["Summon Hawk"] = true
    V.power, V.ttd = 0.3, 8
    assert_eq(V.rule("leveling", "Summon Hawk"), false, "refilling: not on an eight-second mob")
    V.ttd = 20
    assert_eq(V.rule("leveling", "Summon Hawk"), true, "on a twenty-second one")
end }

T[#T + 1] = { "no Arcane Shot once Summon Hawk is trained, both hawks out or not: the cooldown is theirs (1.7.5)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 30, { targeting_pet = true, engaged = true }
    W.last_cast["Aimed Shot"] = 4
    W.power, W.ttd = 0.9, 20
    assert_eq(W.rule("leveling", "Arcane Shot"), true, "before the hawks: the filler on a full bar")

    W.known["Summon Hawk"] = true
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "trained: no Arcane Shot")
    W.last_cast["Summon Hawk"] = 1
    assert_eq(W.rule("leveling", "Summon Hawk"), true, "one hawk out: the second")
    W.clock = W.clock + 6
    W.last_cast["Summon Hawk"] = 0.5
    assert_eq(W.rule("leveling", "Summon Hawk"), false, "two out")
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "both out: still none (it was the gap's filler before 1.7.5)")
    W.moving = true
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "nor on the move")
    W.moving = false
    for _, profile in ipairs({ "beast_mastery", "marksmanship", "survival" }) do
        assert_eq(W.rule(profile, "Arcane Shot"), false, profile .. ": none either")
    end
end }

T[#T + 1] = { "nothing on a mob about to die, on us or not; a runner still slowed with a second left (1.7.4)", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_sent = true, 7
    W.ttd = 2

    W.distance, W.row = 4, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Wing Clip"), false, "no clip: it dies in two seconds")
    assert_eq(W.rule("leveling", "Raptor Strike"), false, "no swing")

    W.distance, W.row = 20, { targeting_me = true, closing = 7, time_to_reach = 2.1, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), false, "no daze on its way in")
    assert_eq(W.rule("leveling", "Arcane Shot"), false, "no Arcane Shot")

    W.distance, W.row = 30, { targeting_pet = true, engaged = true }
    W.spread = true
    assert_eq(W.rule("leveling", "Multi-Shot"), false, "no Multi-Shot, pack or not")
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "in any profile")
    W.spread = nil

    W.row = { targeting_pet = true, closing = -7, activity = "fleeing", engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "a runner with two seconds: slowed")
    W.ttd = 0.6
    assert_eq(W.rule("leveling", "Concussive Shot"), false, "a runner with half a second: let it go")

    W.ttd = math.huge
    W.distance, W.row = 4, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("leveling", "Wing Clip"), true, "unmeasured is not dying: clip")
    W.ttd = 2
    W.in_combat = false
    assert_eq(W.rule("leveling", "Wing Clip"), true, "out of a fight the estimate is stale: clip")
end }

T[#T + 1] = { "the talent profiles' unrationed shots stop on an empty bar (1.7.4)", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_alive = true, false
    W.distance, W.row = 30, { targeting_pet = true, engaged = true }
    W.spread = true
    W.known["Steady Shot"] = true
    for _, key in ipairs({ "beast_mastery", "marksmanship", "survival" }) do
        W.posture = "HEALTHY"
        assert_eq(W.rule(key, "Multi-Shot"), true, key .. ": Multi-Shot on a pack")
        assert_eq(W.rule(key, "Steady Shot"), true, key .. ": Steady Shot")
        W.posture = "RECOVER"
        assert_eq(W.rule(key, "Multi-Shot"), false, key .. ": not when the bar will not last")
        assert_eq(W.rule(key, "Steady Shot"), false, key .. ": nor Steady Shot")
    end
    W.posture = "HEALTHY"
    assert_eq(W.rule("survival", "Explosive Trap"), true, "the trap on a pack")
    assert_eq(W.rule("beast_mastery", "Kill Command"), true, "Kill Command")
    W.posture = "RECOVER"
    assert_eq(W.rule("survival", "Explosive Trap"), false, "not on an empty bar")
    assert_eq(W.rule("beast_mastery", "Kill Command"), false, "nor Kill Command")
end }

-- --- Beast Mastery (1.7.6) -------------------------------------------------------
-- The user, 2026-10-10: "let's work on a beast master build (do the research)
-- make it ALpha too", then "make it the new Rotation for beast master ... then
-- Remvoe the option". Built from the Forever guides (Icy Veins, wowtbc.gg,
-- Mobalytics): the pet hits first, then Auto Shot, the sting, two hawks,
-- Aimed Shot on its cooldown, Multi-Shot on a pack, melee on a mob that
-- reaches you.

--- The talents the class module's `suggest` reads.
local function points(bm, mm, sv)
    return { points = function() return bm, mm, sv end }
end

T[#T + 1] = { "Beast Mastery: the guides' build, for a hunter led by Beast Mastery from the first point; no switch (1.7.6)", function()
    local W = hunter_bundle()
    local suggest = W.class.suggest
    assert_eq(suggest(points(0, 0, 0)), "beast_mastery", "no points yet: Beast Mastery")
    assert_eq(suggest(points(12, 5, 0)), "beast_mastery", "under 20, led by Beast Mastery")
    assert_eq(suggest(points(21, 0, 0)), "beast_mastery", "20 and over, led by Beast Mastery")
    assert_eq(suggest(points(3, 10, 0)), "leveling", "under 20, led by Marksmanship: Levelling")
    assert_eq(suggest(points(0, 0, 8)), "leveling", "or by Survival")
    assert_eq(suggest(points(5, 21, 0)), "marksmanship", "Marksmanship keeps its own")
    assert_eq(suggest(points(5, 0, 21)), "survival", "and Survival")

    -- The ALPHA's switch is gone: a value it saved changes nothing.
    W.settings.bm_alpha = true
    assert_eq(suggest(points(3, 10, 0)), "leveling", "the old switch does nothing")
    assert_eq(W.class.profiles.bm_alpha, nil, "no separate ALPHA profile")
    assert(not table.concat(W.settings_seen, ","):find("bm_alpha", 1, true), "no switch")
    assert_eq(W.class.bm_status, nil, "nor a line under one")
    for _, key in ipairs(W.class.profile_order) do assert(key ~= "bm_alpha", "not in the profile order") end

    local profile = W.class.profiles.beast_mastery
    assert_eq(profile.label, "Beast Mastery", "no ALPHA tag")
    for _, rule in ipairs(profile.rules) do assert(rule[1] ~= "Disengage", "no Disengage") end
end }

T[#T + 1] = { "Beast Mastery: the pet hits first, Auto Shot too; the wait ends at its first hit (1.7.6)", function()
    local W = hunter_bundle({ forever = true })
    W.known["Summon Hawk"] = true
    -- Sent, still running in: ten yards short of the mob.
    W.pet_sent, W.pet_on_target = 0.8, true
    W.pet_pos = { x = 20, y = 0, z = 0 }
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    assert_eq(W.rule("beast_mastery", "Hunter's Mark"), true, "the mark is the pull")
    for _, name in ipairs({ "Auto Shot", "Serpent Sting", "Summon Hawk", "Aimed Shot", "Multi-Shot" }) do
        assert_eq(W.rule("beast_mastery", name), false, name .. " waits for the pet")
    end
    assert_eq(W.rule("leveling", "Auto Shot"), true, "(Levelling's Auto Shot never waits)")

    -- In reach of it, the mob still unhurt: a beat for the first swing.
    W.pet_pos = { x = 31, y = 0, z = 0 }
    assert_eq(W.rule("beast_mastery", "Auto Shot"), false, "in reach, no hit yet")
    W.clock = W.clock + 1.1
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "a beat in reach: its swing has landed")

    -- A fresh pull: the mob losing health with the pet on it is the hit.
    local V = hunter_bundle({ forever = true })
    V.pet_sent, V.pet_on_target = 1.5, true
    V.pet_pos = { x = 31, y = 0, z = 0 }
    V.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    assert_eq(V.rule("beast_mastery", "Auto Shot"), false, "in reach, unhurt")
    V.health[V.target] = 0.96
    assert_eq(V.rule("beast_mastery", "Auto Shot"), true, "hurt: the pet has hit")
    assert_eq(V.rule("beast_mastery", "Serpent Sting"), true, "and the sting")

    -- The mob turned on the pet, wherever the pet is: the hit landed.
    V.health[V.target] = nil
    V.pet_pos = { x = 0, y = 0, z = 0 }
    V.in_combat, V.row = true, { targeting_pet = true, engaged = true, closing = 0 }
    assert_eq(V.rule("beast_mastery", "Aimed Shot"), true, "on the pet: Aimed Shot")

    -- The spell window's forecast reads the beat's clock and never moves it.
    local F = hunter_bundle({ forever = true })
    F.pet_sent, F.pet_on_target = 1.5, true
    F.pet_pos = { x = 31, y = 0, z = 0 }
    F.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    local forecasting = true
    F.H.forecasting = function() return forecasting end
    assert_eq(F.rule("beast_mastery", "Auto Shot"), false, "forecast: in reach, unhurt")
    F.clock = F.clock + 1.1
    assert_eq(F.rule("beast_mastery", "Auto Shot"), false, "the forecast started no clock")
    forecasting = false
    assert_eq(F.rule("beast_mastery", "Auto Shot"), false, "the walk starts it")
    forecasting, F.pet_pos = true, { x = 0, y = 0, z = 0 }
    assert_eq(F.rule("beast_mastery", "Auto Shot"), false, "forecast: the pet out of reach")
    forecasting, F.pet_pos = false, { x = 31, y = 0, z = 0 }
    F.clock = F.clock + 1.1
    assert_eq(F.rule("beast_mastery", "Auto Shot"), true, "and stopped none: the beat passed")

    -- A client that does not say what the pet attacks: the mob it was sent at.
    local U = hunter_bundle({ forever = true })
    U.pet_sent, U.pet_on_target = 1.5, false
    U.pet_pos = { x = 31, y = 0, z = 0 }
    U.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    U.health[U.target] = 0.9
    assert_eq(U.rule("beast_mastery", "Auto Shot"), true, "sent at it, in reach, hurt: the pet's hit")
end }

T[#T + 1] = { "Beast Mastery: the wait is bounded, and only solo with an assisting pet (1.7.6)", function()
    local W = hunter_bundle()
    W.pet_pos = { x = 0, y = 0, z = 0 }
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    -- Never sent: a moment for the pet module, then go.
    W.pet_sent = nil
    assert_eq(W.rule("beast_mastery", "Auto Shot"), false, "a moment for the pet module")
    W.clock = W.clock + 2.5
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "then the shots go")

    -- Sent long ago, not there: it is not getting there.
    W.pet_sent = 6
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "not getting there")
    W.pet_sent = 3
    assert_eq(W.rule("beast_mastery", "Auto Shot"), false, "still on its way")

    -- The mob turned on us: waiting only lets it.
    W.row = { targeting_me = true, closing = 7, time_to_reach = 3, engaged = true }
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "on us")

    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    W.context = "party"
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "a group: the tank pulls")
    W.context, W.pet_mode = "solo", 4
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "the pet held on a focus")
    W.pet_mode, W.pet_alive = 2, false
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "no pet out")
end }

T[#T + 1] = { "Beast Mastery: Aimed Shot on its cooldown at Forever's two seconds, Multi-Shot on a pack (1.7.6)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_alive = true, false
    -- Charging, 2.9 s out: Forever's two-second aim lands, Era's three would not.
    W.distance, W.row = 30, { targeting_me = true, closing = 7, time_to_reach = 2.9, engaged = true }
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), true, "two seconds land in 2.9")
    assert_eq(W.rule("leveling", "Aimed Shot", 1), false, "(Levelling still counts three)")
    local E = hunter_bundle()
    E.in_combat, E.pet_alive = true, false
    E.distance, E.row = 30, { targeting_me = true, closing = 7, time_to_reach = 2.9, engaged = true }
    assert_eq(E.rule("beast_mastery", "Aimed Shot"), false, "Era: three seconds do not")

    -- One cooldown for both: with two or more where it lands it is Multi-Shot's.
    W.spread = true
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "not on a pack")
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), true, "Multi-Shot instead")
    W.spread = false

    -- Too close for the aim: since the weave is Beast Mastery's (1.8.1), no
    -- Multi-Shot on one mob -- it was the cooldown's quick shot before.
    W.row = { targeting_me = true, closing = 7, time_to_reach = 1.5, engaged = true }
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "the aim would not land")
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "no Multi-Shot on one mob (1.8.1)")
    -- A held mob: Aimed Shot, and Multi-Shot stays out of its way.
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "one mob, the aim lands: not Multi-Shot")

    -- Refilling the bar: one Aimed Shot a fight.
    W.power = 0.3
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), true, "the first of the fight")
    W.last_cast["Aimed Shot"] = 4
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "not a second while refilling")
    W.power = 0.9
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), true, "a full bar: on its cooldown")
    W.ttd = 2
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "not on a mob about to die")
end }

T[#T + 1] = { "Beast Mastery: a mob that reaches you is meleed, not dazed or clipped, while the pet is out (1.7.6)", function()
    local W = hunter_bundle()
    W.in_combat, W.pet_sent = true, 7
    W.H.melee_start_wanted = function() return true end
    -- Charging us: Levelling dazes it, the build leaves it to the pet.
    W.distance, W.row = 20, { targeting_me = true, closing = 7, time_to_reach = 2.1, engaged = true }
    assert_eq(W.rule("leveling", "Concussive Shot"), true, "(Levelling dazes it)")
    assert_eq(W.rule("beast_mastery", "Concussive Shot"), false, "no daze on a mob charging us")
    -- A runner is still dazed.
    W.row = { activity = "fleeing", engaged = true, closing = -3 }
    assert_eq(W.rule("beast_mastery", "Concussive Shot"), true, "a runner is")

    -- In our face: melee it.
    W.distance, W.row = 3, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("beast_mastery", "Wing Clip"), false, "no clip with the pet out")
    assert_eq(W.rule("beast_mastery", "Raptor Strike"), true, "Raptor Strike")
    assert_eq(W.rule("beast_mastery", "Mongoose Bite"), true, "Mongoose Bite")
    assert_eq(W.rule("beast_mastery", "Attack"), true, "and the swing")
    W.ttd = 2
    assert_eq(W.rule("beast_mastery", "Raptor Strike"), false, "no mana on a mob about to die")
    assert_eq(W.rule("beast_mastery", "Attack"), true, "the free swing finishes it")
    W.ttd = nil
    W.kite_active = true
    assert_eq(W.rule("beast_mastery", "Attack"), false, "not while the kite steps us out")
    W.kite_active = false
    -- Next to us but on the pet: since the weave is Beast Mastery's (1.8.1),
    -- you walked up to it, and the swing is yours.
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    assert_eq(W.rule("beast_mastery", "Attack"), true, "a mob on the pet is swung at (the weave)")

    -- No pet out: Levelling's slow and clip come back.
    W.pet_alive = false
    W.distance, W.row = 20, { targeting_me = true, closing = 7, time_to_reach = 2.1, engaged = true }
    assert_eq(W.rule("beast_mastery", "Concussive Shot"), true, "no pet: daze the charge")
    W.distance, W.row = 3, { targeting_me = true, closing = 0, engaged = true }
    assert_eq(W.rule("beast_mastery", "Wing Clip"), true, "no pet: clip it")
end }

T[#T + 1] = { "Beast Mastery: two hawks, the sting, no Arcane Shot once the hawks are trained (1.7.6)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_alive = true, false
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    W.power = 0.7                                     -- under the fillers' 80%
    assert_eq(W.rule("beast_mastery", "Arcane Shot"), false, "standing, Aimed Shot lands: no Arcane Shot")
    W.moving = true
    assert_eq(W.rule("beast_mastery", "Arcane Shot"), true, "before the hawks: Arcane Shot on the move")
    W.known["Summon Hawk"] = true
    assert_eq(W.rule("beast_mastery", "Arcane Shot"), false, "the hawks have its cooldown")
    W.moving = false
    assert_eq(W.rule("beast_mastery", "Summon Hawk"), true, "the first hawk")
    W.last_cast["Summon Hawk"] = 1
    assert_eq(W.rule("beast_mastery", "Summon Hawk"), true, "and the second")
    W.clock = W.clock + 6
    W.last_cast["Summon Hawk"] = 0.5
    assert_eq(W.rule("beast_mastery", "Summon Hawk"), false, "two out")
    assert_eq(W.rule("beast_mastery", "Serpent Sting"), true, "the sting")
end }

-- --- Beast Mastery's melee weave (1.8.1; the AOE melee weave, 1.7.6) ------------
-- The user, 2026-10-10: in melee, the hawks, Immolation Trap and the melee
-- strikes, with Rapid Fire on both sides; "We manually Move out and when we
-- move out we use Multi-shot", the stings renewed on every mob in the fight;
-- two hawks at all times. Then, 2026-10-11: "add AOE melee weave into our
-- Normal Beast master rotation no longer alpha/test".

--- A mob of the fight, for engaged_units.
local function fight_mob(guid)
    return { is_valid = function() return true end, is_dead = function() return false end,
             get_guid = function() return guid end }
end

--- A Forever hunter running Beast Mastery in a fight: the pet sent long ago
--- and the mob on it, so nothing waits for its first hit.
local function bm_bundle()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pet_sent = true, 7
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    W.H.melee_start_wanted = function() return W.swing_off ~= false end
    W.class.suggest(points(21, 0, 0))
    return W
end

T[#T + 1] = { "Beast Mastery: the melee weave is part of it -- no switch, no profile of its own (1.8.1)", function()
    local W = hunter_bundle()
    -- A value the old switch saved changes nothing.
    W.settings.aoe_weave = true
    assert_eq(W.class.suggest(points(21, 0, 0)), "beast_mastery", "Beast Mastery's talents: Beast Mastery")
    assert_eq(W.class.weave_running(), true, "and its weave is running")
    assert_eq(W.class.suggest(points(0, 21, 0)), "marksmanship", "Marksmanship keeps its own")
    assert_eq(W.class.weave_running(), false, "with no weave")
    assert_eq(W.class.suggest(points(3, 10, 0)), "leveling", "Levelling too")
    assert_eq(W.class.weave_running(), false, "with no weave")
    W.P.pvphunter = { mode = function() return true end }
    assert_eq(W.class.suggest(points(21, 0, 0)), "pvp", "a fight with a player: PvP first")
    assert_eq(W.class.weave_running(), false, "and the weave is not running then")

    assert_eq(W.class.profiles.aoe_weave, nil, "no profile of its own")
    for _, key in ipairs(W.class.profile_order) do assert(key ~= "aoe_weave", "not in the profile order") end
    local seen = table.concat(W.settings_seen, ",")
    assert(not seen:find("aoe_weave", 1, true), "no switch")
    assert(seen:find("disengage", 1, true), "the Disengage switch is a class option")
    assert_eq(W.class.aoe_running, nil, "the old names are gone")
    assert_eq(W.class.aoe_status, nil, "the old line too")
    assert_eq(W.class.profiles.beast_mastery.label, "Beast Mastery", "no ALPHA tag")
    -- Melee is Beast Mastery's alone: the other profiles have no swing of their own.
    for _, key in ipairs({ "leveling", "marksmanship", "survival" }) do
        for _, rule in ipairs(W.class.profiles[key].rules) do
            assert(rule[1] ~= "Attack", key .. " has no swing rule")
        end
    end
end }

T[#T + 1] = { "Beast Mastery weave: in melee, the burst -- fire trap, strikes, Lacerate, the swing; no shot (1.8.1)", function()
    local W = bm_bundle()
    W.distance = 3
    for _, name in ipairs({ "Immolation Trap", "Raptor Strike", "Mongoose Bite", "Strider Kick", "Counterattack",
                            "Lacerate", "Attack" }) do
        assert_eq(W.rule("beast_mastery", name), true, name .. " in melee")
    end
    for _, name in ipairs({ "Auto Shot", "Multi-Shot", "Serpent Sting", "Aimed Shot" }) do
        assert_eq(W.rule("beast_mastery", name), false, name .. ": not in melee")
    end
    assert_eq(W.rule("beast_mastery", "Explosive Trap"), false, "one mob: not the pack's trap")
    W.spread = true
    assert_eq(W.rule("beast_mastery", "Explosive Trap"), true, "two or more round you: Explosive Trap")
    W.spread = nil
    assert_eq(W.rule("beast_mastery", "Wing Clip"), false, "no clip with the pet out")
    -- The mob is on the pet and you walked up to it: the swing is yours (1.8.1).
    assert_eq(W.rule("beast_mastery", "Attack"), true, "a mob on the pet is swung at")

    W.debuffs["Lacerate"] = true
    assert_eq(W.rule("beast_mastery", "Lacerate"), false, "the bleed is up")
    W.debuffs["Lacerate"] = nil
    W.ttd = 8
    assert_eq(W.rule("beast_mastery", "Lacerate"), false, "not on a mob dead before it bleeds out")
    assert_eq(W.rule("beast_mastery", "Immolation Trap"), true, "the trap still")
    W.ttd = 2
    assert_eq(W.rule("beast_mastery", "Immolation Trap"), false, "nothing on a mob about to die")
    assert_eq(W.rule("beast_mastery", "Raptor Strike"), false, "no strike")
    assert_eq(W.rule("beast_mastery", "Attack"), true, "the free swing finishes it")
    W.ttd = nil
    W.swing_off = false
    assert_eq(W.rule("beast_mastery", "Attack"), false, "not while the swing runs")
    W.swing_off = nil
    W.kite_active = true
    assert_eq(W.rule("beast_mastery", "Raptor Strike"), false, "not while the run-and-shoot has the legs")
    assert_eq(W.rule("beast_mastery", "Attack"), false, "nor the swing")
    W.kite_active = false

    W.distance = 20
    for _, name in ipairs({ "Immolation Trap", "Raptor Strike", "Lacerate", "Attack" }) do
        assert_eq(W.rule("beast_mastery", name), false, name .. ": not out of melee")
    end
end }

-- The user: "if its 2+ mobs it should be priority to multishot", then
-- "remember Neither PvP or AoE meele wave should Multishot if its not 2+
-- enemy mobs" -- Beast Mastery's rule since the weave is its own (1.8.1).
T[#T + 1] = { "Beast Mastery weave: out, Multi-Shot first with two or more where it lands, never on one (1.8.1)", function()
    local W = bm_bundle()
    W.distance = 20
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "one mob: never")
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), true, "Aimed Shot has the cooldown")
    -- Charging, too close for the aim: still no Multi-Shot on one mob.
    W.row = { targeting_me = true, closing = 7, time_to_reach = 1.5, engaged = true }
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "the aim would not land")
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "nor the quick shot on one mob")
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    W.spread = true
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), true, "two or more where it lands")
    assert_eq(W.rule("beast_mastery", "Aimed Shot"), false, "and Aimed Shot gives it the shared cooldown")
    W.moving = true
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "not on the move")
    W.moving = false
    W.distance = 3
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "not in melee")
    W.distance = 20
    W.posture = "RECOVER"
    assert_eq(W.rule("beast_mastery", "Multi-Shot"), false, "an empty bar: no Multi-Shot")
    W.posture = nil

    -- One Multi-Shot rule, ahead of every damage rule.
    local at, multi = {}, {}
    for i, rule in ipairs(W.class.profiles.beast_mastery.rules) do
        if rule[1] == "Multi-Shot" then multi[#multi + 1] = i else at[rule[1]] = at[rule[1]] or i end
    end
    assert_eq(#multi, 1, "one Multi-Shot rule")
    for _, name in ipairs({ "Rapid Fire", "Summon Hawk", "Serpent Sting", "Aimed Shot", "Raptor Strike",
                            "Immolation Trap" }) do
        assert(multi[1] < at[name], "Multi-Shot before " .. name)
    end
    local sting
    for _, rule in ipairs(W.class.profiles.beast_mastery.rules) do
        if rule[1] == "Serpent Sting" then sting = rule end
    end
    assert(sting.spread == true and sting.dot == true, "the sting spreads")
end }

T[#T + 1] = { "Beast Mastery weave: two hawks at all times; Rapid Fire in a burst window, in melee and out (1.8.1)", function()
    for _, d in ipairs({ 3, 20 }) do
        local W = bm_bundle()
        local bursting = false
        W.H.bursting = function() return bursting end
        W.known["Summon Hawk"] = true
        W.distance = d
        local where = d < 5 and "in melee" or "out"
        W.power = 0.3                                 -- refilling: Levelling keeps to one hawk
        assert_eq(W.rule("beast_mastery", "Summon Hawk"), true, where .. ": the first hawk")
        W.last_cast["Summon Hawk"] = 1
        assert_eq(W.rule("leveling", "Summon Hawk"), false, where .. ": (Levelling, refilling: one is enough)")
        assert_eq(W.rule("beast_mastery", "Summon Hawk"), true, where .. ": Beast Mastery keeps two")
        W.clock = W.clock + 6
        W.last_cast["Summon Hawk"] = 0.5
        assert_eq(W.rule("beast_mastery", "Summon Hawk"), false, where .. ": two out")

        W.power = 0.9
        -- One rule for the five-minute cooldown, the burst window's (1.8.1).
        W.engaged = { W.target, fight_mob("b") }
        assert_eq(W.rule("beast_mastery", "Rapid Fire"), false, where .. ": two mobs, no burst window: kept")
        bursting = true
        assert_eq(W.rule("beast_mastery", "Rapid Fire"), true, where .. ": a burst window: Rapid Fire")
        W.ttd = 2
        assert_eq(W.rule("beast_mastery", "Rapid Fire"), false, where .. ": not into a mob about to die")
        W.ttd = nil
        W.posture = "RECOVER"
        assert_eq(W.rule("beast_mastery", "Rapid Fire"), false, where .. ": not on an empty bar")
    end
    -- The pull: Rapid Fire and the hawks wait for the pet's first hit too.
    local V = hunter_bundle({ forever = true })
    V.H.bursting = function() return true end
    V.known["Summon Hawk"] = true
    V.in_combat, V.pet_sent, V.pet_on_target = true, 0.8, true
    V.pet_pos = { x = 20, y = 0, z = 0 }
    V.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    assert_eq(V.rule("beast_mastery", "Rapid Fire"), false, "Rapid Fire waits for the pet")
    assert_eq(V.rule("beast_mastery", "Summon Hawk"), false, "and the hawks")
end }

T[#T + 1] = { "Beast Mastery weave: Auto Shot pressed again straight back out of melee, once a trip (1.8.1)", function()
    local W = bm_bundle()
    local restarted = 0
    W.repeater.restart = function() restarted = restarted + 1 end
    W.distance = 20
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "out: Auto Shot")
    assert_eq(restarted, 0, "no trip yet")
    W.distance = 3
    W.rule("beast_mastery", "Raptor Strike")
    W.clock = W.clock + 1
    W.distance = 20
    assert_eq(W.rule("beast_mastery", "Auto Shot"), true, "back out: pressed")
    assert_eq(restarted, 1, "restarted")
    W.clock = W.clock + 1
    W.rule("beast_mastery", "Auto Shot")
    assert_eq(restarted, 1, "once a trip")

    -- The next trip.
    W.distance = 3
    W.rule("beast_mastery", "Attack")
    W.clock = W.clock + 1
    W.distance = 20
    W.rule("beast_mastery", "Auto Shot")
    assert_eq(restarted, 2, "the next trip, again")

    -- Levelling's melee restarts nothing.
    W.distance = 3
    W.rule("leveling", "Raptor Strike")
    W.clock = W.clock + 1
    W.distance = 20
    W.rule("leveling", "Auto Shot")
    assert_eq(restarted, 2, "Levelling: no restart")
end }

T[#T + 1] = { "Beast Mastery weave: the class window's line says which side you are on (1.8.1)", function()
    local W = bm_bundle()
    W.class.suggest(points(0, 21, 0))
    assert(W.class.weave_status():find("not running", 1, true), "Marksmanship: " .. W.class.weave_status())
    W.class.suggest(points(21, 0, 0))
    assert(W.class.weave_status():find("waiting for a fight", 1, true), "no fight: " .. W.class.weave_status())
    W.P.combat = { target = function() return W.target end, in_combat = function() return true end }
    W.distance = 3
    local line = W.class.weave_status()
    assert(line:find("in melee", 1, true) and line:find("Beast Mastery", 1, true), "in melee: " .. line)
    assert(not line:find("ALPHA", 1, true), "no ALPHA tag: " .. line)
    W.distance = 20
    local other = fight_mob("b")
    W.P.field = { by_weakest = function() return { W.target, other } end }
    W.debuffs["Serpent Sting"] = true
    line = W.class.weave_status()
    assert(line:find("out: Multi-Shot; Serpent Sting on 1 of 2", 1, true), "out: " .. line)
    W.P.field = { by_weakest = function() return { W.target } end }
    line = W.class.weave_status()
    assert(line:find("one mob, Aimed Shot", 1, true), "out, one mob: " .. line)
    W.P.pvphunter = { mode = function() return true end }
    assert(W.class.weave_status():find("PvP", 1, true), "a player fight: " .. W.class.weave_status())
end }

T[#T + 1] = { "Beast Mastery: nothing moves you once the pet levels have begun; the run-and-shoot before them is kept (1.8.1)", function()
    local W = kite_bundle()
    W.row = { targeting_pet = true }
    local running = true
    W.P.rotation.active_class = function()
        return { key = "hunter", weave_running = function() return running end }
    end
    W.tick()
    assert_eq(W.kite.active(), false, "no step out: you walk")
    assert_eq(W.kite.stats().reason, "Beast Mastery: you move in and out", "and why")
    running = false
    W.tick()
    assert_eq(W.kite.stepping_out(), true, "the step out again in another profile")

    -- Before Tame Beast: Beast Mastery (a hunter with no points reads as one)
    -- leaves the legs to the run-and-shoot's own switch.
    local V = kite_bundle()
    V.known["Tame Beast"] = nil
    V.P.pet.alive = function() return false end
    V.P.rotation.active_class = function()
        return { key = "hunter", weave_running = function() return true end }
    end
    V.tick()
    assert(V.kite.stats().reason ~= "Beast Mastery: you move in and out", "the pre-pet kite is not stood aside: "
        .. tostring(V.kite.stats().reason))
end }

-- --- Disengage when hit: the switch (1.8.1) ----------------------------------------
-- The user: "add a button Turn it on if being attacked to disengage". The
-- reaction is react/rules/hunter.lua's (aio_hunter_pvp_test); the gate every
-- other path asks is the class's key_gated (rotation.lua, H.key_allows).

-- 1.8.1: the user, "what about intimidation? I learned it recently from my
-- talents but i dont see it being used". Forever does not say what the pet
-- is attacking (1.73.1), and these asked the client alone. Then: "it stunts
-- target and next sucess full attack gains 100% critical chance and Generate
-- high threat so it should be used ina Burst, Interrupt (stunt) or when I
-- really need a mob off me and Disengage is not available".
T[#T + 1] = { "Intimidation: kept for a burst -- pressed only in a burst window, the pet on our mob; in the burst sequence after Bestial Wrath (1.8.1)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat = true
    W.pet_on_target = false                          -- the client says nothing (Forever)
    local fighting, bursting = nil, false
    W.P.pet.fighting = function() return fighting end
    W.H.bursting = function() return bursting end
    fighting = W.target                              -- the pet module: sent at our mob
    for _, profile in ipairs({ "leveling", "beast_mastery" }) do
        assert_eq(W.rule(profile, "Intimidation"), false, profile .. ": no burst window: Intimidation is kept")
        assert_eq(W.rule(profile, "Bestial Wrath"), false, profile .. ": and Bestial Wrath (the burst window's too)")
    end
    bursting = true
    for _, profile in ipairs({ "leveling", "beast_mastery" }) do
        assert_eq(W.rule(profile, "Intimidation"), true, profile .. ": a burst window: Intimidation")
        assert_eq(W.rule(profile, "Bestial Wrath"), true, profile .. ": and Bestial Wrath")
    end
    fighting = nil
    assert_eq(W.rule("beast_mastery", "Intimidation"), false, "the pet on nothing: it would stun nothing")
    fighting = W.target
    W.ttd = 2
    assert_eq(W.rule("beast_mastery", "Intimidation"), false, "not on a mob about to die")
    W.ttd = nil
    W.P.react = { out_of_fight = function() return true end }
    assert_eq(W.rule("beast_mastery", "Intimidation"), false, "not into crowd control")
    W.P.react = nil
    W.in_combat = false
    assert_eq(W.rule("beast_mastery", "Intimidation"), false, "not before the fight")
    W.in_combat = true

    -- The burst sequence: after Bestial Wrath, vetoed while the pet is on nothing.
    local at = {}
    for i, entry in ipairs(W.class.burst) do at[entry.spell] = { i = i, entry = entry } end
    assert(at["Intimidation"] and at["Bestial Wrath"], "both in the burst sequence")
    assert(at["Intimidation"].i > at["Bestial Wrath"].i, "Intimidation after Bestial Wrath")
    local when = at["Intimidation"].entry.when
    assert_eq(when(W.situation()), true, "the pet on our mob: it goes")
    fighting = nil
    assert_eq(when(W.situation()), false, "the pet on nothing: skipped")

    -- A client that answers: as before.
    local E = hunter_bundle()
    E.in_combat, E.pet_on_target = true, true
    E.H.bursting = function() return true end
    assert_eq(E.rule("beast_mastery", "Intimidation"), true, "the client says the pet is on it")
end }

-- 1.8.1: the user asked when to burst in PvE; no Forever guide says, and
-- they chose Mobalytics' rule: solo, Rapid Fire "on harder encounters ... it
-- might pull enemies off your pet"; with a tank, freely.
T[#T + 1] = { "the burst window solo: a harder fight only, once the pet holds the mob; with a tank, freely (1.8.1)", function()
    local W = hunter_bundle({ forever = true })
    W.in_combat = true
    local veto = W.class.burst_veto
    assert(type(veto) == "function", "the class holds the window back through burst_veto")
    W.row = { targeting_pet = true, engaged = true, closing = 0 }
    local why = veto(W.situation(), "freely", 12)
    assert(type(why) == "string" and why:find("harder fight", 1, true), "solo, a 12 s mob: kept: " .. tostring(why))
    assert_eq(veto(W.situation(), "freely", 25), nil, "a mob living 25 s: it opens")
    for _, kind in ipairs({ "elite", "pack", "losing" }) do
        assert_eq(veto(W.situation(), kind, 10), nil, kind .. ": it opens")
    end
    -- The pet not holding the mob yet: Rapid Fire's threat would pull it.
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    why = veto(W.situation(), "elite", 30)
    assert(type(why) == "string" and why:find("pet to hold", 1, true), "the pet not on it yet: wait: " .. tostring(why))
    W.row = { targeting_me = true, closing = 0, engaged = true }
    assert_eq(veto(W.situation(), "elite", 30), nil, "on you already: nothing left to pull")
    W.row = { targeting_me = false, targeting_pet = false, closing = 0 }
    W.pet_alive = false
    assert_eq(veto(W.situation(), "elite", 30), nil, "no pet out: nothing to wait for")
    W.pet_alive = true
    W.context = "party"
    assert_eq(veto(W.situation(), "freely", 12), nil, "a group with its tank: freely, as before")
end }

T[#T + 1] = { "Disengage: one class switch, off by default, and the gate every path asks (1.8.1)", function()
    local W = hunter_bundle()
    local gate = W.class.key_gated and W.class.key_gated["Disengage"]
    assert(type(gate) == "function", "Disengage is gated on a switch")
    assert_eq(gate(), false, "off by default: nothing presses it")
    W.settings.disengage = true
    assert_eq(gate(), true, "on: allowed")
    assert(table.concat(W.settings_seen, ","):find("disengage", 1, true), "a class option")
    for _, key in ipairs(W.class.profile_order) do
        for _, rule in ipairs(W.class.profiles[key].rules) do
            assert(rule[1] ~= "Disengage", key .. ": no Disengage rule; the reaction presses it")
        end
    end
end }

-- --- the PvP hunter (1.7.6, ALPHA/TEST) ------------------------------------------

--- The class file with PvP mode, the foe read and our control stood in for:
--- W.pvp (mode), W.foe (react/pvp.lua's read of the target), W.held
--- ({ kind, left }: our control on it), W.ready / W.cooldown (the spellbook).
local function pvp_bundle()
    local W = hunter_bundle({ forever = true })
    W.in_combat, W.pvp, W.distance = true, true, 25
    W.row = { targeting_me = true, closing = 0, activity = "attacking", engaged = true }
    W.ready, W.cooldown = {}, {}
    W.P.pvphunter = {
        mode = function() return W.pvp == true, "a test" end,
        held = function(unit)
            if unit == W.target and W.held then return W.held[1], W.held[2] end
            return nil, 0
        end,
    }
    W.P.react = {
        pvp = {
            foe = function(unit) return unit == W.target and W.foe or nil end,
            state = function() return W.foe_state or { mech = {} } end,
        },
        out_of_fight = function() return false end,
    }
    W.H.book.ready = function(name) return W.known[name] == true and W.ready[name] ~= false end
    W.H.book.cooldown = function(name) return W.cooldown[name] or 0 end
    local base = W.situation
    W.situation = function()
        local s = base()
        s.enemies = W.rows or {}
        return s
    end
    return W
end

local MELEE = { class = "ROGUE", role = "melee", melee = true, stealth = true }
local CASTER = { class = "MAGE", role = "caster", caster = true, mana = true }

T[#T + 1] = { "PvP (ALPHA): runs while pvphunter says PvP, whatever the talents; one class option, no more (1.7.6)", function()
    local W = pvp_bundle()
    local function talents(bm, mm, sv) return { points = function() return bm, mm, sv end } end
    W.pvp = false
    assert_eq(W.class.suggest(talents(0, 0, 0)), "beast_mastery", "no PvP: the talents' profile")
    W.pvp = true
    assert_eq(W.class.suggest(talents(0, 0, 0)), "pvp", "PvP: the PvP profile")
    assert_eq(W.class.suggest(talents(0, 21, 0)), "pvp", "over Marksmanship too")
    assert_eq(W.class.profiles.pvp.label, "PvP (ALPHA/TEST)", "labelled ALPHA/TEST")
    local seen = table.concat(W.settings_seen, ",")
    assert(seen:find("pvp_alpha", 1, true), "its switch is a class option")
    -- "Remove all the PVP hunter Options off the UI and just into one option".
    for _, id in ipairs({ "pvp_trap_first", "pvp_reset", "pvp_turn", "pvp_finish" }) do
        assert(not seen:find(id, 1, true), id .. " is gone")
    end
    assert(type(W.class.pvp_status) == "function", "the class window's line")
end }

T[#T + 1] = { "PvP (ALPHA): nothing into our own trap; the opener once walked away, Rapid Fire with it (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = MELEE
    W.held = { "trap", 8 }
    W.distance = 10
    for _, name in ipairs({ "Auto Shot", "Serpent Sting", "Summon Hawk", "Multi-Shot", "Concussive Shot",
                            "Arcane Shot" }) do
        assert_eq(W.rule("pvp", name), false, name .. ": not into the trap")
    end
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "10 yd off: walk away first")
    assert_eq(W.rule("pvp", "Rapid Fire"), false, "and no Rapid Fire yet")
    W.distance = 25
    assert_eq(W.rule("pvp", "Aimed Shot"), true, "25 yd off: the opener")
    assert_eq(W.rule("pvp", "Rapid Fire"), true, "Rapid Fire with it")
    W.kite_active = true
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "not while the kite still walks")
    W.kite_active, W.distance = false, 10
    W.held = { "trap", 2.2 }
    assert_eq(W.rule("pvp", "Aimed Shot"), true, "the trap about to end: the opener wherever we stand")
    W.held = { "trap", 8 }
    W.distance, W.pet_on_target = 25, true
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "the pet on it: no opener")
    W.pet_on_target = false
    W.held = { "scatter", 3 }
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "a Scatter Shot is not the trap: nothing into it")
end }

T[#T + 1] = { "PvP (ALPHA): the trap first -- no sting or hawk on a melee player while Freezing Trap is ready (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = MELEE
    W.known["Freezing Trap"] = true
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "the trap is ready: no sting")
    assert_eq(W.rule("pvp", "Summon Hawk"), false, "nor a hawk")
    assert_eq(W.rule("pvp", "Auto Shot"), true, "Auto Shot goes")
    W.ready["Freezing Trap"], W.cooldown["Freezing Trap"] = false, 3
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "ready in 3 s: still held")
    W.cooldown["Freezing Trap"] = 20
    assert_eq(W.rule("pvp", "Serpent Sting"), true, "spent: the sting")
    assert_eq(W.rule("pvp", "Summon Hawk"), true, "and the hawks")
    W.ready["Freezing Trap"], W.cooldown["Freezing Trap"] = nil, 0
    W.settings.pvp_trap_first = false                 -- saved by the option that went
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "ready again: the trap first, whatever was saved")
    W.settings.pvp_trap_first = nil
    W.foe = CASTER
    W.known["Viper Sting"] = nil
    assert_eq(W.rule("pvp", "Serpent Sting"), true, "a caster is not to be trapped first")
end }

T[#T + 1] = { "PvP (ALPHA): the stings by class -- Viper on a caster, Serpent on the rest (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = CASTER
    W.known["Viper Sting"] = true
    assert_eq(W.rule("pvp", "Viper Sting"), true, "a mage: Viper Sting")
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "not Serpent")
    W.debuffs["Viper Sting"] = true
    assert_eq(W.rule("pvp", "Viper Sting"), false, "already drained")
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "one sting at a time")
    W.debuffs["Viper Sting"] = nil
    W.known["Viper Sting"] = nil
    assert_eq(W.rule("pvp", "Serpent Sting"), true, "under 36: Serpent")
    W.foe = { class = "WARRIOR", role = "melee", melee = true }
    W.known["Viper Sting"] = true
    assert_eq(W.rule("pvp", "Viper Sting"), false, "a warrior has no mana")
    assert_eq(W.rule("pvp", "Serpent Sting"), true, "Serpent for it (no trap known)")
    W.settings.mark_on = 4
    assert_eq(W.rule("pvp", "Hunter's Mark"), false, "Hunter's Mark on Never: never")
    W.settings.mark_on = 3
    assert_eq(W.rule("pvp", "Hunter's Mark"), true, "Bosses only is about mobs: a player is marked")
end }

T[#T + 1] = { "PvP (ALPHA): the melee kept off -- Concussive, Wing Clip, Strider Kick (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = MELEE
    W.distance = 20
    W.row = { targeting_me = true, closing = 7, activity = "approaching", engaged = true }
    assert_eq(W.rule("pvp", "Concussive Shot"), true, "a rogue coming at you: dazed")
    W.debuffs["Concussive Shot"] = true
    assert_eq(W.rule("pvp", "Concussive Shot"), false, "already dazed")
    W.debuffs["Concussive Shot"] = nil
    W.foe = CASTER
    W.row = { targeting_me = true, closing = 0, activity = "attacking", engaged = true }
    assert_eq(W.rule("pvp", "Concussive Shot"), false, "a mage standing: no daze")
    W.row.activity = "fleeing"
    assert_eq(W.rule("pvp", "Concussive Shot"), true, "running off: dazed")
    W.foe = MELEE
    W.distance = 3
    W.row = { targeting_me = true, closing = 0, activity = "attacking", engaged = true }
    assert_eq(W.rule("pvp", "Wing Clip"), true, "in melee: clipped")
    assert_eq(W.rule("pvp", "Strider Kick"), false, "not yet slowed: no kick")
    W.debuffs["Wing Clip"] = true
    assert_eq(W.rule("pvp", "Wing Clip"), false, "clipped already")
    assert_eq(W.rule("pvp", "Strider Kick"), true, "clipped and on you: the kick's run speed")
end }

T[#T + 1] = { "PvP (ALPHA): Aimed Shot where it lands -- a caster standing, a stun, never with melee on you (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = CASTER
    W.distance = 30
    assert_eq(W.rule("pvp", "Aimed Shot"), true, "a mage standing at 30 yd")
    W.foe = MELEE
    W.distance = 12
    W.row = { targeting_me = true, closing = 7, time_to_reach = 1, activity = "approaching", engaged = true }
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "a rogue a second away: no two-second cast")
    W.row.control = { breaks = false, remaining = 2.5 }
    assert_eq(W.rule("pvp", "Aimed Shot"), true, "stunned for 2.5 s: the cast lands first")
    W.row.control = nil
    W.foe, W.distance = CASTER, 30
    W.row = { targeting_me = true, closing = 0, activity = "attacking", engaged = true }
    W.rows = { { obj = { is_player = function() return true end }, targeting_me = true, dist = 3 } }
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "another player in melee with you: nothing cast")
    W.rows = nil
    W.foe_state = { mech = {}, avoid = "physical" }
    assert_eq(W.rule("pvp", "Aimed Shot"), false, "in Deterrence: not the big shot")
    assert_eq(W.rule("pvp", "Rapid Fire"), false, "nor the burst")
end }


T[#T + 1] = { "PvP (ALPHA): Multi-Shot only with two or more enemies where it lands (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = CASTER
    W.distance = 30
    assert_eq(W.rule("pvp", "Multi-Shot"), false, "one player: never")
    W.spread = true
    assert_eq(W.rule("pvp", "Multi-Shot"), true, "two or more where it lands")
    W.moving = true
    assert_eq(W.rule("pvp", "Multi-Shot"), false, "not on the move")
end }

-- The user, 2026-10-10: "in pvp we should also use Scorpid Sting cause it
-- reduces targest chance to hit with attacks for 20 seconds".
T[#T + 1] = { "PvP (ALPHA): Scorpid Sting on a player who fights with attacks, in Serpent Sting's place (1.7.6)", function()
    local W = pvp_bundle()
    W.foe = { class = "WARRIOR", role = "melee", melee = true }
    W.known["Scorpid Sting"] = true
    assert_eq(W.rule("pvp", "Scorpid Sting"), true, "a warrior: Scorpid Sting")
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "not Serpent: one sting at a time")
    W.debuffs["Scorpid Sting"] = true
    assert_eq(W.rule("pvp", "Scorpid Sting"), false, "up, with time left")
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "and not Serpent over it")
    W.debuffs["Scorpid Sting"] = nil

    W.foe = { class = "HUNTER", role = "ranged", ranged = true, mana = true }
    assert_eq(W.rule("pvp", "Scorpid Sting"), true, "a hunter's bow is attacks too")
    W.foe = MELEE
    assert_eq(W.rule("pvp", "Scorpid Sting"), true, "a rogue: Scorpid Sting")
    W.known["Freezing Trap"] = true
    assert_eq(W.rule("pvp", "Scorpid Sting"), true, "no damage: it goes before the trap")
    assert_eq(W.rule("pvp", "Serpent Sting"), false, "(the dot waits for the trap)")
    W.held = { "trap", 8 }
    assert_eq(W.rule("pvp", "Scorpid Sting"), false, "never into our own trap")
    W.held, W.known["Freezing Trap"] = nil, nil

    W.foe = CASTER
    assert_eq(W.rule("pvp", "Scorpid Sting"), false, "a mage: no")
    W.foe = { class = "WARRIOR", role = "melee", melee = true }
    W.debuffs["Serpent Sting"] = true
    assert_eq(W.rule("pvp", "Scorpid Sting"), false, "not over a sting of ours already there")
    W.debuffs["Serpent Sting"] = nil
    W.known["Scorpid Sting"] = nil
    assert_eq(W.rule("pvp", "Scorpid Sting"), true, "(the rule asks; the spellbook says untrained)")
    assert_eq(W.rule("pvp", "Serpent Sting"), true, "before 22: Serpent Sting")

    local found = false
    for _, rule in ipairs(W.class.profiles.pvp.rules) do found = found or rule[1] == "Scorpid Sting" end
    assert(found, "in the PvP list")
end }

return T

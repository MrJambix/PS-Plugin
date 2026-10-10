-- Jambix AIO 1.73.2: the warlock's shard limit stops Drain Soul making more.
-- A player on Forever: "it keeps casting drain soul and my backpack is always
-- full ... i even set the slider to max 5 shards". The limit only governed
-- what happened to shards once made; now Drain Soul asks it first.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function build(state)
    _G.core = { time = function() return 1000 end }
    local P = {
        cfg = require("jambix_aio/modules/config"),
        combat = { time_to_die = function(u) return u.ttd or 99 end },
        hardcore = {
            count = function(kind) return kind == "soulshard" and state.shards or 0 end,
            item = function() return nil end,
            destroy_one = function(kind, reason)
                state.destroyed = (state.destroyed or 0) + 1
                state.reason = reason
                return true
            end,
        },
        derived = function(_, default) return default / 100 end,
        derived_secs = function(_, default) return default end,
        tune = function(_, default) return default / 100 end,
        opt = function(id, default)
            local v = state.opts[id]
            if v == nil then return default end
            return v
        end,
    }
    local H = setmetatable({
        talent = function(name)
            if name == "Improved Drain Soul" then return state.talent end
            if name == "Soul Harvest" then return state.harvest or 0 end
            return 0
        end,
        has_talent = function() return false end,
        execute_phase = function() return true end,
        power_fraction = function() return state.mana end,
        channel_active = function() return false end,
        book = setmetatable({}, { __index = function() return function() return false end end }),
    }, { __index = function() return function() return false end end })
    local CS = {
        prefix = "rot_warlock_",
        opt = function(id, default) return P.opt("rot_warlock_" .. id, default) end,
        pct = function(_, default) return default / 100 end,
        tune = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
    }
    package.loaded["jambix_aio/modules/classes/warlock"] = nil
    local class = require("jambix_aio/modules/classes/warlock")(P, H, CS)
    for _, rule in ipairs(class.profiles.leveling.rules) do
        if rule[1] == "Drain Soul" then return rule[2], rule, class end
    end
    error("no Drain Soul rule")
end

local function mob(level, ttd, kind)
    return { ttd = ttd, get_level = function() return level end, get_creature_type = function() return kind or 1 end }
end

local function snapshot()
    return { target = mob(30, 3), ttd = 3, in_combat = true,
             player = { is_moving = function() return false end, get_level = function() return 30 end } }
end

local function wants(fields)
    local state = { shards = 0, talent = 0, mana = 0.8,
                    opts = { rot_warlock_shard_dump = true, rot_warlock_shard_cap = 5 } }
    for k, v in pairs(fields) do
        if k == "opts" then for id, val in pairs(v) do state.opts[id] = val end else state[k] = v end
    end
    return build(state)(snapshot())
end

local T = {}

T[#T + 1] = { "at the limit Drain Soul is not cast for a shard; under it, as before", function()
    assert_eq(wants({ shards = 3 }), true, "3 of 5: a dying mob gets its Drain Soul")
    assert_eq(wants({ shards = 5 }), false, "5 of 5: no more shards")
    assert_eq(wants({ shards = 9 }), false, "over it: none")
end }

T[#T + 1] = { "Improved Drain Soul: at the limit only for the mana refund, while mana is short", function()
    assert_eq(wants({ shards = 5, talent = 2, mana = 0.8 }), false, "mana is fine: the refund is not needed")
    assert_eq(wants({ shards = 5, talent = 2, mana = 0.2 }), true, "mana at 20%: the refund is worth a shard")
end }

T[#T + 1] = { "the limit switched off: Drain Soul whatever the shards", function()
    assert_eq(wants({ shards = 20, opts = { rot_warlock_shard_dump = false } }), true, "no limit")
end }

--- The Drain Soul rule asked with a snapshot built by `edit`: it answers
--- whether it fires, and the unit it would be cast on (its retarget).
local function harvest(fields, edit)
    local state = { shards = 0, talent = 0, mana = 0.8, harvest = 1,
                    opts = { rot_warlock_shard_dump = true, rot_warlock_shard_cap = 5 } }
    for k, v in pairs(fields or {}) do state[k] = v end
    local wanted, rule = build(state)
    local s = snapshot()
    if edit then edit(s) end
    local fires = wanted(s)
    return fires, s[rule.retarget], s, rule
end

T[#T + 1] = { "Soul Harvest (Forever): the dying target is drained, whatever the shard limit says (1.73.3)", function()
    local fires, unit, s, rule = harvest({ shards = 9 })
    assert_eq(rule.retarget, "drain_soul_target", "the rule casts on the unit it picks")
    assert_eq(fires, true, "the target dies inside a channel: drain it")
    assert_eq(unit, s.target, "the target")
end }

T[#T + 1] = { "Soul Harvest: another mob that dies sooner is drained instead (1.73.3)", function()
    local add = mob(30, 1.5)
    local fires, unit = harvest({}, function(s)
        s.target, s.ttd = mob(30, 30), 30
        s.enemies, s.enemy_count = { { obj = add, engaged = true, hp = 0.1 } }, 1
    end)
    assert_eq(fires, true, "the add at 10% dies in 1.5 s")
    assert_eq(unit, add, "drained, not the target with 30 s left")

    -- Barely sooner than the target: stay on the target.
    local near = mob(30, 2.5)
    local _, unit2, s2 = harvest({}, function(s)
        s.enemies, s.enemy_count = { { obj = near, engaged = true, hp = 0.1 } }, 1
    end)
    assert_eq(unit2, s2.target, "half a second sooner is not worth a switch")
end }

T[#T + 1] = { "Soul Harvest: never on a kill that does not count, nor on a mob we crowd-controlled (1.73.3)", function()
    local fires = harvest({}, function(s) s.target = mob(10, 3) end)
    assert_eq(fires, false, "a grey mob (level 10 at your 30) is trivial: no harvest")
    fires = harvest({}, function(s) s.target = mob(30, 3, 8) end)
    assert_eq(fires, false, "a critter")
    local sheep = mob(30, 1)
    local _, unit = harvest({}, function(s)
        s.enemies, s.enemy_count = { { obj = sheep, engaged = true, hp = 0.1, control = { type = 1 } } }, 1
    end)
    assert(unit ~= sheep, "the feared add is left alone")
    fires = harvest({}, function(s) s.ttd, s.target = 30, mob(30, 30) end)
    assert_eq(fires, false, "nothing dies inside one channel: no drain yet")
end }

T[#T + 1] = { "without Soul Harvest the 1.73.2 limit still holds", function()
    assert_eq((harvest({ harvest = 0, shards = 9 })), false, "at the limit, untalented: no Drain Soul")
end }

T[#T + 1] = { "in a fight a shard over the limit is dumped at once; at or under it, nothing (1.73.4)", function()
    local function upkeep(fields)
        local state = { shards = 0, talent = 0, mana = 0.8, harvest = 1,
                        opts = { rot_warlock_shard_dump = true, rot_warlock_shard_cap = 5 } }
        for k, v in pairs(fields) do
            if k == "opts" then for id, val in pairs(v) do state.opts[id] = val end else state[k] = v end
        end
        local _, _, class = build(state)
        class.combat_upkeep(snapshot())
        return state.destroyed or 0, state.reason
    end
    local n, why = upkeep({ shards = 6 })
    assert_eq(n, 1, "6 of 5: one destroyed")
    assert(why and why:find("6 shards, over the 5 we keep", 1, true), "and says why: " .. tostring(why))
    assert_eq((upkeep({ shards = 5 })), 0, "at the limit: kept")
    assert_eq((upkeep({ shards = 9, opts = { rot_warlock_shard_dump = false } })), 0, "the limit off: nothing destroyed")
end }

return T

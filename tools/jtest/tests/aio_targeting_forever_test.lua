-- Jambix AIO: target selection (modules/targeting.lua) asks JCore, per client
-- (1.55.0). Out of combat the rotation opens on the best mob in range, and the
-- score loves a nearly dead one; on a busy Forever realm that is usually
-- somebody else's kill. JCore's loot.tapped says so there (the client's
-- is_tap_denied since patch 1.60.1.70205, or a stranger's fight) and is false
-- on Era with no read, so Era picks exactly as it always did. The rank is
-- JCore's units.classification (the creature cache's on Forever).

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local cfg = require("jambix_aio/modules/config")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

_G.core = {
    time = function() return 100 end,
    get_instance_type = function() return "none" end,
    object_manager = { get_party_members = function() return {} end },
}

local function obj(guid)
    return { get_guid = function() return guid end, is_valid = function() return true end }
end

--- A mob as targeting reads one.
local function mob(guid, o)
    local m = { guid = guid, dist = o.dist or 20, hp = o.hp or 1, theirs = o.theirs == true, rank = o.rank or 0 }
    m.is_valid = function() return true end
    m.is_dead = function() return false end
    m.get_guid = function() return guid end
    m.get_name = function() return guid end
    m.is_in_combat = function() return m.theirs end
    m.get_target = function() return nil end
    m.get_threat_situation = function() return nil end
    m.get_classification = function() return 0 end
    return m
end

--- `jcore` stands in for JCore's answers on the client being tested.
local function targeting(list, jcore, extra)
    local me = obj("Player-1-ME")
    me.can_attack = function() return true end
    local asked = { tapped = 0 }
    local P = {
        cfg = cfg,
        log = { fmt = function() end, once = function() end },
        opt = function(_, default) return default end,
        tune_secs = function(_, default) return default end,
        ctx = {
            loot = { tapped = function(u)
                asked.tapped = asked.tapped + 1
                return jcore.tapped(u)
            end },
            emit = function() end,
        },
        units = {
            player = function() return me end,
            distance = function(u) return u.dist end,
            health_fraction = function(u) return u.hp end,
            enemies = function() return list end,
            enemies_within = function() return list end,
            classification = function(u) return jcore.rank(u) end,
        },
        combat = { target = function() return nil end, in_combat = function() return false end },
    }
    if extra then extra(P) end
    package.loaded["jambix_aio/modules/targeting"] = nil
    local M = require("jambix_aio/modules/targeting")(P)
    return M, asked
end

local FOREVER = {
    tapped = function(u) return u.theirs end,
    rank = function(u) return u.rank end,
}
local ERA = {
    tapped = function() return false end,
    rank = function() return 0 end,
}

local T = {}

T[#T + 1] = { "somebody else's nearly dead mob is never picked where JCore says so; Era picks it as before", function()
    local function world()
        return { mob("stolen", { hp = 0.1, dist = 15, theirs = true }), mob("fresh", { hp = 1.0, dist = 20 }) }
    end
    assert_eq(targeting(world(), ERA).better_target().guid, "stolen", "Era: the lowest health wins, as it always did")
    assert_eq(targeting(world(), FOREVER).better_target().guid, "fresh", "Forever: not somebody else's kill")
end }

T[#T + 1] = { "others_mob is JCore's word, nothing else", function()
    local list = { mob("tagged", { hp = 0.5, dist = 10, theirs = true }), mob("free", { hp = 1.0, dist = 25 }) }
    local f = targeting(list, FOREVER)
    assert_eq(f.others_mob(list[1]), true, "tagged")
    assert_eq(f.others_mob(list[2]), false, "free")
    assert_eq(targeting(list, ERA).others_mob(list[1]), false, "Era: JCore says no")
end }

T[#T + 1] = { "an elite by JCore's rank is pushed down; Era's own read said normal", function()
    local function world()
        return { mob("elite", { dist = 10, rank = 1 }), mob("normal", { dist = 20 }) }
    end
    assert_eq(targeting(world(), FOREVER).better_target().guid, "normal", "the elite is avoided")
    assert_eq(targeting(world(), ERA).better_target().guid, "elite", "Era: normal, so the nearer one")
end }

T[#T + 1] = { "in combat, solo: the reaction engine's kill order picks the target; a sheep is never picked (1.56.0)", function()
    local function world()
        return { mob("healthy", { hp = 0.9, dist = 5 }), mob("weak", { hp = 0.2, dist = 25 }) }
    end
    local list = world()
    local focus = list[1]
    local M = targeting(list, ERA, function(P)
        P.combat.in_combat = function() return true end
        P.combat.target = function() return list[2] end
        for i = 1, #list do list[i].theirs = true end     -- engaged with us (is_in_combat)
        P.react = { focus = function() return focus, true end }
    end)
    assert_eq(M.better_target().guid, "healthy", "the plan's focus, though the old score loves the weak one")

    local stay = targeting(list, ERA, function(P)
        P.combat.in_combat = function() return true end
        P.combat.target = function() return list[1] end
        P.react = { focus = function() return focus, true end }
    end)
    assert_eq(stay.better_target(), nil, "already on the plan's focus: no switch")

    -- No plan (one mob, a group): the score decides, and never a controlled mob.
    local sheep = { mob("sheep", { hp = 0.1, dist = 10 }), mob("other", { hp = 0.9, dist = 20 }) }
    local S = targeting(sheep, ERA, function(P)
        P.react = { focus = function() return nil, false end,
                    out_of_fight = function(u) return u.guid == "sheep" end }
    end)
    assert_eq(S.better_target().guid, "other", "the nearly dead sheep would score best, but it is asleep")
end }

T[#T + 1] = { "who holds a mob is status 2-3 or the scaled 100%, not is_tanking (1.82.0)", function()
    local said = {
        -- Era on a core before 2026-10-06: is_tanking read a wrong offset, status was always 0.
        bogus = { is_tanking = true, status = 0, threat_percent = 40 },
        held_old = { is_tanking = false, status = 0, threat_percent = 100 },
        -- The 2026-10-06 core: all three agree.
        held_new = { is_tanking = true, status = 3, threat_percent = 100 },
        pulling = { is_tanking = false, status = 1, threat_percent = 90 },
    }
    local list = {}
    for _, guid in ipairs({ "bogus", "held_old", "held_new", "pulling" }) do
        local m = mob(guid, { dist = 10, theirs = true })
        m.get_threat_situation = function() return said[guid] end
        list[#list + 1] = m
    end
    local M = targeting(list, ERA)
    local loose = {}
    for _, m in ipairs(M.loose(30)) do loose[m.guid] = true end
    assert_eq(loose.bogus, true, "a bogus is_tanking at 40% is somebody else's")
    assert_eq(loose.held_old, nil, "100% with status 0 is ours")
    assert_eq(loose.held_new, nil, "status 3 is ours")
    assert_eq(loose.pulling, true, "status 1 is about to be ours, not yet")
    assert_eq(M.tanking(list[1]), false, "tanking: bogus")
    assert_eq(M.tanking(list[2]), true, "tanking: the old core's 100%")
    assert_eq(M.tanking(list[3]), true, "tanking: the new core's status")
end }

return T

-- JCore enemies (1.6.4): what Forever's client does not say, answered from
-- what it does -- and on Era, nothing new read at all.
--
--   damage on us    no combat log there: each drop in our own and the pet's
--                   health is shared among the mobs attacking each
--   crowd control   loss of control reads "not valid" for every mob there:
--                   the mob's debuffs say it, with whether damage breaks it
--   threat          get_threat_situation answers zeros there: a mob hitting
--                   us that we "hold nothing on" proves it, and threat is
--                   then unread rather than a fake 0%
--
-- The service runs against a hand-made runtime: a scripted clock, a player,
-- a pet, and mobs whose every read is counted.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local make_enemies = require("jcore/services/enemies")

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return clock.s * 1000 end,
}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function zeros() return { is_tanking = false, status = 0, threat_percent = 0 } end

--- A world: the player, the pet, mobs. `client` is "Forever" or "Vanilla".
local function world(client)
    local W = { reads = { health = 0, debuffs = 0, loc = 0, threat = 0 }, mobs = {}, trace = {}, hp = {} }
    local function obj(guid)
        local o = { guid = guid }
        o.is_valid = function() return true end
        o.get_guid = function() return guid end
        o.get_threat_situation = function()
            W.reads.threat = W.reads.threat + 1
            return W.threat_answer and W.threat_answer() or zeros()
        end
        return o
    end
    W.me, W.pet = obj("me"), obj("pet")
    W.hp.me, W.hp.pet = 1000, 500

    function W.mob(guid, o)
        local m = obj(guid)
        m.dist, m.target, m.debuffs = o.dist or 10, o.target, o.debuffs
        m.is_in_combat = function() return true end
        m.is_casting_spell = function() return false end
        m.is_channelling_spell = function() return false end
        m.get_target = function() return m.target end
        m.is_dead = function() return false end
        m.get_loss_of_control_info = function()
            W.reads.loc = W.reads.loc + 1
            return { valid = false, type = 0, spell_id = 0, end_time = 0 }
        end
        m.get_debuffs = function()
            W.reads.debuffs = W.reads.debuffs + 1
            return m.debuffs or {}
        end
        W.mobs[#W.mobs + 1] = m
        return m
    end

    local rt = {
        util = {},
        events = { on = function() end,
                   emit = function(name, text) if name == "jcore.recorder.trace" then W.trace[#W.trace + 1] = text end end },
        cache = { try = function(fn, a, b, c)
            if type(fn) ~= "function" then return nil end
            local ok, v = pcall(fn, a, b, c)
            if ok then return v end
            return nil
        end },
        log = { for_tag = function() return { fmt = function() end, info = function() end } end },
        units = {
            player = function() return W.me end,
            player_pet = function() return W.pet_out ~= false and W.pet or nil end,
            guid = function(u) return u and u.guid end,
            name = function(u) return u and u.guid or "" end,
            by_guid = function() return nil end,
            enemies = function() return W.mobs end,
            snapshot = function(u) return { guid = u.guid, x = u.dist, y = 0, z = 0, dist = u.dist } end,
            health_fraction = function() return 1 end,
            health = function(u)
                W.reads.health = W.reads.health + 1
                return W.hp[u.guid]
            end,
        },
        combat = { time_to_die = function() return math.huge end, in_combat = function() return W.in_combat == true end },
        world = { client = function()
            local f = client == "Forever"
            return { version = client, forever = f, combat_log = not f }
        end },
    }
    W.E = make_enemies(rt)
    function W.poll(seconds)
        clock.s = clock.s + (seconds or 0.1)
        W.E._poll()
    end
    return W
end

local T = {}

T[#T + 1] = { "Forever: each drop in our health is shared among the mobs attacking us; the pet's among its own", function()
    local W = world("Forever")
    local a = W.mob("a", { target = W.me, dist = 4 })
    W.poll()
    W.hp.me = 970                         -- a hits for 30
    W.poll()
    local ra = W.E.damage_rate("a")
    assert(ra and ra > 0, "a has a rate")
    assert_eq(math.floor(ra + 0.5), 15, "30 over the time since its first hit (none yet), plus a swing")

    -- b joins on us: the next 40 is shared, b as much as a has been doing.
    local b = W.mob("b", { target = W.me, dist = 5 })
    W.poll(0.5)
    W.hp.me = 930
    W.poll()
    local rb = W.E.damage_rate("b")
    assert(rb and rb > 0, "b has a rate from its share")
    assert(W.E.damage_rate("a") > 0, "a keeps its own")

    -- A heal is not damage, and a mob on the pet takes the pet's drops.
    W.hp.me = 1000
    W.poll()
    local c = W.mob("c", { target = W.pet, dist = 12 })
    W.poll()
    W.hp.pet = 450
    W.poll()
    assert(W.E.damage_rate("c") and W.E.damage_rate("c") > 0, "c, on the pet, has the pet's 50")
    assert_eq(W.E.damage_rate("nobody"), nil, "a mob that never hit has no rate")
    local _ = b and c
end }

T[#T + 1] = { "Era: no damage rate, and the poll reads no health for it", function()
    local W = world("Vanilla")
    W.mob("a", { target = W.me, dist = 4 })
    W.poll()
    W.hp.me = 900
    W.poll()
    assert_eq(W.E.damage_rate("a"), nil, "the combat log says it there; JCore does not guess")
    assert_eq(W.reads.health, 0, "no health read by the enemies poll on Era")
end }

T[#T + 1] = { "Forever: a polymorph in the mob's debuffs is control that damage breaks; a stun is control it does not", function()
    local W = world("Forever")
    local sheep = W.mob("sheep", { target = nil, dist = 10, debuffs = {
        { buff_id = 118, buff_name = "Polymorph", expire_time = (clock.s + 30) * 1000 } } })
    local stunned = W.mob("stunned", { target = W.me, dist = 4, debuffs = {
        { buff_id = 853, buff_name = "Hammer of Justice", expire_time = (clock.s + 5) * 1000 } } })
    local plain = W.mob("plain", { target = W.me, dist = 6, debuffs = {
        { buff_id = 1, buff_name = "Serpent Sting", expire_time = (clock.s + 9) * 1000 } } })
    W.poll()
    local rs, rt, rp = W.E.get("sheep"), W.E.get("stunned"), W.E.get("plain")
    assert(rs.control, "the sheep is controlled")
    assert_eq(rs.control.breaks, true, "and damage breaks it")
    assert_eq(rs.control.kind, "incapacitate", "an incapacitate")
    assert_eq(rs.activity, "controlled", "its activity says so")
    assert(rs.control.remaining > 25, "with its time left from the debuff")
    assert_eq(rt.control and rt.control.breaks, false, "a stun: controlled, damage does not end it")
    assert_eq(rp.control, nil, "a DoT is not control")
    local _ = sheep and stunned and plain
end }

T[#T + 1] = { "Era: the mob's debuffs are never read for control", function()
    local W = world("Vanilla")
    W.mob("sheep", { dist = 10, debuffs = { { buff_id = 118, buff_name = "Polymorph" } } })
    W.poll()
    assert_eq(W.reads.debuffs, 0, "loss of control is the client's own answer there")
    assert_eq(W.E.get("sheep").control, nil, "and it said none")
end }

T[#T + 1] = { "Forever: zeros from a mob hitting us prove threat dead -- unread from then, never asked again", function()
    local W = world("Forever")
    W.mob("a", { target = W.me, dist = 4 })
    for _ = 1, 8 do W.poll(0.5) end
    assert_eq(W.E.threat_readable(), false, "proven: the client answers nothing")
    local said = 0
    for i = 1, #W.trace do if W.trace[i]:find("threat is unread", 1, true) then said = said + 1 end end
    assert_eq(said, 1, "said once, in the trace")
    local s, cost = W.E.situation(W.mobs[1], W.me, true)
    assert_eq(s, nil, "unread, not a 0% that reads as safe")
    assert_eq(cost, 0, "and costs nothing")
    local before = W.reads.threat
    W.poll(0.5)
    assert_eq(W.reads.threat, before, "never asked again")
    assert_eq(W.E.get("a").threat, nil, "the row carries no threat")
    assert_eq(W.E.stats().threat_readable, false, "the stats say so")
end }

T[#T + 1] = { "Forever: one read that says something makes threat live for good; Era never judges", function()
    local W = world("Forever")
    local said = false
    W.threat_answer = function()
        if not said then said = true return { is_tanking = true, status = 3, threat_percent = 100 } end
        return zeros()
    end
    W.mob("a", { target = W.me, dist = 4 })
    for _ = 1, 10 do W.poll(0.5) end
    assert_eq(W.E.threat_readable(), true, "live after one real answer, whatever the zeros after")

    local E = world("Vanilla")
    E.mob("a", { target = E.me, dist = 4 })
    for _ = 1, 10 do E.poll(0.5) end
    assert_eq(E.E.threat_readable(), nil, "Era: not judged at all")
    assert(E.E.get("a").threat ~= nil, "the client's answer, as always")
end }

T[#T + 1] = { "Forever: Blizzard's damage meter is asked once, then in combat; what it answered is said (1.6.6)", function()
    local W = world("Forever")
    local asked = { avail = 0, session = 0 }
    _G.core.damage_meter = {
        is_available = function() asked.avail = asked.avail + 1 return true, "" end,
        get_session_from_type = function(session, t)
            asked.session = asked.session + 1
            assert_eq(session, 1, "the current session")
            if t == 7 then return { sources = { { name = "Me", total_amount = 120, per_second = 12 } } } end
            if t == 9 then error("no such meter") end
            return { sources = {} }
        end,
    }
    W.in_combat = false
    W.poll()
    assert_eq(asked.avail, 1, "asked once")
    assert_eq(asked.session, 0, "not read out of combat")
    W.in_combat = true
    W.poll(2.1)
    assert_eq(W.E.meter_summary(), "damage meter answers in combat", "a number in combat")
    local said = table.concat(W.trace, "\n")
    assert(said:find("damage meter: available=true", 1, true), "availability traced")
    assert(said:find("type 7 in combat: answers, 1 source", 1, true), "the answer traced")
    W.poll(0.5)
    assert_eq(asked.avail, 1, "availability not asked again")
    _G.core.damage_meter = nil

    local H = world("Forever")
    _G.core.damage_meter = {
        is_available = function() return true, "" end,
        get_session_from_type = function() return { sources = { { name = "Me", total_amount = nil } } } end,
    }
    H.in_combat = true
    H.poll(2.1)
    assert_eq(H.E.meter_summary(), "damage meter nothing usable in combat", "hidden amounts are not used")
    _G.core.damage_meter = nil

    local E = world("Vanilla")
    local touched = 0
    _G.core.damage_meter = { is_available = function() touched = touched + 1 return true end }
    E.in_combat = true
    E.poll(2.1)
    assert_eq(touched, 0, "Era: never asked")
    assert_eq(E.E.meter_summary(), nil, "and nothing to say")
    _G.core.damage_meter = nil
end }

return T

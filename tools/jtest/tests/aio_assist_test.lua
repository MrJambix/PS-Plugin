-- Jambix AIO 1.70.0: "Assist the tank" (modules/assist.lua), on a hand-built
-- bundle with the real targeting.lua and a scripted clock. Switched on, a
-- damage dealer in a group is on the tank's target and follows it (after the
-- tank has kept it 0.3 s, at once with no target of our own). Friends, sheep,
-- far mobs and -- mid-fight -- mobs not pulled yet are not followed: the
-- targeting is what it was. The pull is the tank's: an idle mob waits, the
-- group's fight is joined. The tank is the group role, else the member the
-- mobs are on or in a tank stance, kept between pulls. Off by default; off
-- for the tank, the healer, solo, and with the tank dead.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local cfg = require("jambix_aio/modules/config")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function guid(u) return u and u.guid or nil end

local function logged(W, text)
    for i = 1, #W.logs do
        if W.logs[i]:find(text, 1, true) then return true end
    end
    return false
end

local function world(o)
    o = o or {}
    local W = { clock = 100, settings = { rot_assist_tank = true }, in_combat = false, logs = {},
        in_group = true, rotation_on = true }
    _G.core = {
        time = function() return W.clock end,
        get_instance_type = function() return "none" end,
        object_manager = { get_party_members = function() return {} end },
    }

    local function unit(id, f)
        f = f or {}
        local u = { guid = id, name = f.name or id, dead = false, target = nil, combat = f.combat == true,
            hostile = f.hostile == true, dist = f.dist or 10, hp = f.hp or 1, auras = {} }
        u.is_valid = function() return true end
        u.is_dead = function() return u.dead end
        u.get_guid = function() return u.guid end
        u.get_name = function() return u.name end
        u.get_target = function() return u.target end
        u.is_in_combat = function() return u.combat end
        u.get_threat_situation = function() return nil end
        u.get_classification = function() return 0 end
        u.can_attack = function(_, other) return other ~= nil and other.hostile == true end
        return u
    end
    W.unit = unit
    W.me = unit("Player-ME", { name = "Me" })
    W.tank = unit("Player-TANK", { name = "Tanky" })
    W.healer = unit("Player-HEAL", { name = "Healy" })
    W.dps = unit("Player-DPS", { name = "Stabby" })
    W.members = { W.me, W.tank, W.healer, W.dps }
    W.roles = o.no_roles and {} or { ["Player-TANK"] = "tank", ["Player-HEAL"] = "healer" }
    W.mobs = {}
    W.profile = { label = "Levelling" }

    function W.mob(id, f)
        f = f or {}
        f.hostile = true
        local m = unit(id, f)
        W.mobs[#W.mobs + 1] = m
        return m
    end

    local function row(m)
        return { obj = m, guid = m.guid, in_combat = m.combat, target_guid = guid(m.target),
            activity = m.dead and "dead" or "idle", dist = m.dist,
            engaged = m.combat and m.target == W.me, targeting_me = m.target == W.me, targeting_pet = false }
    end
    local enemies = {
        all = function()
            local out = {}
            for i = 1, #W.mobs do out[i] = row(W.mobs[i]) end
            return out
        end,
        count = function() return #W.mobs end,
        get = function(u)
            for i = 1, #W.mobs do if W.mobs[i] == u then return row(u) end end
            return nil
        end,
        where = function(pred)
            local out = {}
            for i = 1, #W.mobs do
                local r = row(W.mobs[i])
                if pred(r) then out[#out + 1] = r end
            end
            return out
        end,
    }
    local group = {
        in_group = function() return W.in_group end,
        objects = function() return W.members end,
        tanks = function()
            local out = {}
            for _, m in ipairs(W.members) do if W.roles[m.guid] == "tank" then out[#out + 1] = m end end
            return out
        end,
        is_tank = function(u) return W.roles[u.guid] == "tank" end,
        is_healer = function(u) return W.roles[u.guid] == "healer" end,
    }

    local P = {
        cfg = cfg,
        ctx = { group = group, enemies = enemies, emit = function() end,
            loot = { tapped = function() return false end } },
        log = {
            fmt = function(_, f, ...) W.logs[#W.logs + 1] = string.format(f, ...) end,
            once = function() end,
        },
        opt = function(id, d)
            local v = W.settings[id]
            if v == nil then return d end
            return v
        end,
        tune_secs = function(_, d) return d end,
        units = {
            player = function() return W.me end,
            guid = guid,
            name = function(u) return u and u.name end,
            distance = function(u) return u.dist end,
            health_fraction = function(u) return u.hp end,
            enemies = function() return W.mobs end,
            enemies_within = function() return W.mobs end,
            classification = function() return 0 end,
            has_aura = function(u, ids)
                for _, id in ipairs(ids) do if u.auras[id] then return true end end
                return false
            end,
        },
        combat = { target = function() return W.target end, in_combat = function() return W.in_combat end },
        rotation = {
            active_class = function() return { profiles = { p = W.profile } } end,
            active_profile_key = function() return "p" end,
        },
        rotation_active = function() return W.rotation_on end,
    }
    W.P = P
    package.loaded["jambix_aio/modules/targeting"] = nil
    package.loaded["jambix_aio/modules/assist"] = nil
    P.targeting = require("jambix_aio/modules/targeting")(P)
    P.assist = require("jambix_aio/modules/assist")(P)
    W.A, W.T = P.assist, P.targeting

    --- What the rotation does each tick: ask, and switch.
    function W.tick()
        local better = W.T.better_target()
        if better then W.target = better end
        return better
    end
    function W.wait(s) W.clock = W.clock + s end
    return W
end

local T = {}

T[#T + 1] = { "on the tank's target, and following it when the tank switches (after 0.3 s, out of a fight)", function()
    local W = world()
    local a = W.mob("Kobold-A", { name = "Kobold Miner" })
    local b = W.mob("Kobold-B", { name = "Kobold Tunneler", hp = 0.2 })
    W.tank.target = a
    assert_eq(guid(W.tick()), "Kobold-A", "no target of ours: the tank's at once")
    assert_eq(W.tick(), nil, "on it: no switch")
    assert(W.A.status():find("Assisting Tanky (group role): on Kobold Miner", 1, true), W.A.status())

    -- The tank changes target. The nearly dead one would score better, but
    -- the tank's is the one.
    W.tank.target = b
    W.wait(0.15)
    assert_eq(W.tick(), nil, "the tank has had it 0 s: wait")
    W.wait(0.2)
    assert_eq(W.tick(), nil, "0.2 s: still waiting")
    W.wait(0.15)
    assert_eq(guid(W.tick()), "Kobold-B", "kept 0.35 s: followed")

    -- And back: the score loves b (20%), the tank went to a.
    W.tank.target = a
    W.wait(0.5)
    assert_eq(W.tick(), nil, "the tank has just gone back: wait")
    W.wait(0.5)
    W.tick()
    assert_eq(guid(W.target), "Kobold-A", "followed back, whatever the score says")
end }

-- 1.74.0: the live log (Forever, a five-man) had a warrior tabbing through
-- three mobs for Sunders and the hunter following every tab -- a new target
-- every one to three seconds, a Hunter's Mark with each.
T[#T + 1] = { "in a fight the kill is kept: Sunder tabs are not followed; a real switch, a mark, a dead mob are", function()
    local W = world()
    local a = W.mob("Kobold-A", { combat = true, name = "Kobold Miner" })
    local b = W.mob("Kobold-B", { combat = true, name = "Kobold Tunneler" })
    local c = W.mob("Kobold-C", { combat = true, name = "Kobold Geomancer" })
    a.target, b.target, c.target = W.tank, W.tank, W.tank
    W.in_combat = true
    W.tank.target = a
    assert_eq(guid(W.tick()), "Kobold-A", "the tank's at the start")

    -- The tank tabs: a Sunder on b, one on c, back to a.
    W.tank.target = b
    W.wait(0.15) W.tick()
    W.wait(1.5)
    assert_eq(W.tick(), nil, "a Sunder on b: we stay on a")
    assert(W.A.status():find("staying on Kobold Miner until it dies (the tank is on Kobold Tunneler", 1, true), W.A.status())
    W.tank.target = c
    W.wait(0.15) W.tick()
    W.wait(1.5)
    assert_eq(W.tick(), nil, "and one on c: still a")
    W.tank.target = a
    W.wait(0.15)
    assert_eq(W.tick(), nil, "back on a")

    -- A real switch: the tank keeps b four seconds.
    W.tank.target = b
    W.wait(0.15) W.tick()
    W.wait(2)
    assert_eq(W.tick(), nil, "2 s on b: still a")
    W.wait(2.1)
    assert_eq(guid(W.tick()), "Kobold-B", "4 s on b: the tank's kill now")
    assert(logged(W, "the tank has been on Kobold Tunneler 4s: leaving Kobold Miner for it"), table.concat(W.logs, " | "))

    -- Ours nearly dead: finished first, however long the tank is elsewhere.
    b.hp = 0.3
    W.tank.target = c
    W.wait(0.15) W.tick()
    W.wait(5)
    assert_eq(W.tick(), nil, "b at 30%: finished first")
    assert(W.A.status():find("finishing Kobold Tunneler (30%) before Kobold Geomancer", 1, true), W.A.status())

    -- Ours dies: the tank's target at once.
    b.dead = true
    assert_eq(guid(W.tick()), "Kobold-C", "b dead: the tank's at once")

    -- A skull on the tank's target is the group's kill: followed after 0.3 s.
    local d = W.mob("Kobold-D", { combat = true, name = "Kobold Taskmaster" })
    d.target = W.tank
    d.get_target_marker_index = function() return 8 end
    W.tank.target = d
    W.wait(0.15)
    assert_eq(W.tick(), nil, "0.15 s on the skull: wait")
    W.wait(0.35)
    assert_eq(guid(W.tick()), "Kobold-D", "skull: followed")
    assert(logged(W, "Kobold Taskmaster is marked skull: leaving Kobold Geomancer for it"), table.concat(W.logs, " | "))
end }

T[#T + 1] = { "not followed: a friend, a sheep, a far mob, a pack not pulled yet mid-fight", function()
    local W = world()
    local a = W.mob("Kobold-A", { combat = true })
    a.target = W.me
    W.in_combat = true
    W.target = a

    W.tank.target = W.healer
    assert_eq(W.tick(), nil, "the tank on the healer: we stay")
    assert_eq(W.A.stats().note, "the tank is targeting a friend", "said")

    local sheep = W.mob("Kobold-S", { combat = true, name = "Sheep" })
    W.P.react = { out_of_fight = function(u) return u == sheep end }
    W.tank.target = sheep
    W.wait(1)
    W.tick()
    W.wait(1)
    assert_eq(guid(W.tick() or W.target), "Kobold-A", "never onto a sheep")
    assert(W.A.stats().note:find("crowd-controlled", 1, true), W.A.stats().note)

    local far = W.mob("Kobold-F", { combat = true, dist = 75 })
    W.tank.target = far
    W.wait(1)
    W.tick()
    assert(W.A.stats().note:find("75 yd away", 1, true), W.A.stats().note)

    local idle = W.mob("Kobold-I", { name = "Next pack" })
    W.tank.target = idle
    W.wait(1)
    W.tick()
    W.wait(1)
    assert_eq(guid(W.tick() or W.target), "Kobold-A", "mid-fight, the tank looking at the next pack is not a pull")
    assert_eq(W.A.stats().note, "Next pack is not pulled yet", "said")
end }

T[#T + 1] = { "the pull is the tank's: an idle mob waits, the group's fight is joined", function()
    local W = world()
    local idle = W.mob("Kobold-I", { name = "Kobold Miner" })
    W.tank.target = idle
    assert_eq(guid(W.tick()), "Kobold-I", "out of a fight: the tank's target is selected")
    assert_eq(W.A.engage(idle), false, "but not opened on")
    assert(W.A.status():find("waiting for Tanky to pull Kobold Miner", 1, true), W.A.status())

    idle.combat, idle.target = true, W.tank
    assert_eq(W.A.engage(idle), true, "pulled: we join in, though we are not in combat")

    local healer_mob = W.mob("Kobold-H", { combat = true })
    healer_mob.target = W.healer
    assert_eq(W.A.engage(healer_mob), true, "on the healer: the group's fight")

    local stranger = W.unit("Player-X", {})
    local theirs = W.mob("Kobold-X", { combat = true })
    theirs.target = stranger
    assert_eq(W.A.engage(theirs), nil, "fighting a stranger: no say, the old rules decide")

    W.settings.rot_assist_tank = false
    assert_eq(W.A.engage(W.mob("Kobold-Z")), nil, "switched off: no say")
end }

T[#T + 1] = { "who the tank is without roles: the mobs on them, a tank stance, kept between pulls", function()
    local W = world({ no_roles = true })
    assert(W.A.status():find("no tank found yet", 1, true), W.A.status())

    W.tank.auras[71] = true                       -- Defensive Stance
    W.wait(1.1)
    assert_eq(W.A.status(), "Assisting Tanky (tank stance or form).", "the stance says it")

    W.tank.auras[71] = nil
    W.wait(1.1)
    assert_eq(W.A.status(), "Assisting Tanky (found earlier).", "kept between pulls")

    local m = W.mob("Kobold-A", { combat = true })
    m.target = W.dps
    W.wait(1.1)
    assert(W.A.status():find("Assisting Tanky", 1, true), "one mob on a damage dealer for a moment: " .. W.A.status())

    local W2 = world({ no_roles = true })
    for i = 1, 2 do W2.mob("Kobold-" .. i, { combat = true }).target = W2.dps end
    assert_eq(W2.A.status(), "Assisting Stabby (2 mobs are on them).", "the one the mobs are on")
end }

T[#T + 1] = { "off by default; not for the tank, the healer, solo, or with the tank dead", function()
    local W = world()
    W.settings.rot_assist_tank = nil
    local a = W.mob("Kobold-A", { combat = true })
    W.tank.target = a
    local _, holding = W.A.pick(nil)
    assert_eq(holding, false, "off by default")
    assert_eq(W.A.status(), "", "and says nothing")

    local function says(setup, want)
        local V = world()
        setup(V)
        local s = V.A.status()
        assert(s:find(want, 1, true), want .. ": " .. s)
        local _, h = V.A.pick(nil)
        assert_eq(h, false, want .. ": targeting as before")
    end
    says(function(V) V.roles["Player-ME"] = "tank" end, "you are the tank")
    says(function(V) V.profile.label = "Protection (tank)" end, "you are the tank")
    says(function(V) V.profile.label = "Feral (Bear tank)" end, "you are the tank")
    says(function(V) V.roles["Player-ME"] = "healer" end, "you are the healer")
    says(function(V) V.profile.label = "Restoration" end, "you are the healer")
    says(function(V) V.in_group = false end, "not in a group")
    says(function(V) V.tank.dead = true end, "the tank is dead")
end }

T[#T + 1] = { "Pick targets automatically off: assisting still picks; both off, nothing", function()
    local W = world()
    W.settings.rot_auto_target = false
    local a = W.mob("Kobold-A", { combat = true })
    a.target = W.tank
    W.tank.target = a
    W.in_combat = true
    assert_eq(guid(W.tick()), "Kobold-A", "the tank's target")
    W.target = nil
    W.tank.target = W.healer
    W.wait(1)
    assert_eq(W.tick(), nil, "the tank on a friend, automatic picking off: nothing")
    W.settings.rot_assist_tank = false
    W.tank.target = a
    W.wait(1)
    assert_eq(W.tick(), nil, "both off: nothing")
end }

return T

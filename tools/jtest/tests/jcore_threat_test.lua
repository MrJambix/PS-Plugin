-- JCore threat service: the group's threat on every mob, ranked the way
-- Details!' Tiny Threat ranks it, and what it costs to find out.
--
-- The service is built against a hand-made runtime: a scripted clock, a party
-- of objects, mobs whose get_threat_situation answers from a table, and an
-- enemies service holding the rows. Every native the service makes is a call
-- on one of those objects, so the counts below are the real cost.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_threat = require("jcore/services/threat")
local make_enemies = require("jcore/services/enemies")

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- --- the world -----------------------------------------------------------------

local ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 }

local function actor(guid, name, pet)
    return {
        guid = guid, name = name,
        is_valid = function() return true end,
        get_pet = function() return pet end,
        get_target = function(self) return self.target end,
    }
end

--- A mob answering get_threat_situation from `table[actor guid]`, counting
--- every ask.
local function mob(guid, answers)
    local m = { guid = guid, asked = 0, answers = answers or {},
        is_valid = function() return true end }
    m.get_threat_situation = function(self, who)
        self.asked = self.asked + 1
        return self.answers[who.guid]
    end
    return m
end

local function t(status, percent, is_tanking)
    return { status = status, threat_percent = percent, is_tanking = is_tanking or false }
end

--- A runtime around the given world. `w` holds:
---   me          the player object
---   members     party rows { name, role, class_file, object }
---   raid        token -> object
---   rows        the enemies rows
local function runtime(w)
    local emitted = {}
    local resolved = {}
    local rt = {
        util = {},
        log = { for_tag = function() return { fmt = function() end } end },
        cache = {
            try = function(fn, a, b, c)
                if type(fn) ~= "function" then return nil end
                local ok, v = pcall(fn, a, b, c)
                if ok then return v end
                return nil
            end,
        },
        events = {
            on = function() end,
            emit = function(name, ...) emitted[#emitted + 1] = { name = name, ... } end,
        },
        units = {
            player = function() return w.me end,
            guid = function(u) return u and u.guid end,
            name = function(u) return u and u.name or "" end,
            by_guid = function(token)
                resolved[token] = (resolved[token] or 0) + 1
                return w.raid and w.raid[token] or nil
            end,
        },
        enemies = { all = function() return w.rows or {} end },
        group = {
            ROLE = ROLE,
            role = function(u) return u == w.me and (w.my_role or ROLE.NONE) or ROLE.NONE end,
            members = function() return w.members or {} end,
            party_frames = function() return {} end,
        },
    }
    return make_threat(rt), emitted, resolved
end

local function row(m, o)
    o = o or {}
    return {
        guid = m.guid, obj = m, dist = o.dist or 10,
        in_combat = o.in_combat ~= false,
        target_guid = o.target_guid,
        threat = o.threat, threat_at = o.threat_at or -1e9,
    }
end

--- A five-man: you are the mage; a warrior tanks; a priest, a rogue and a
--- hunter with a pet.
local function dungeon()
    local w = {}
    w.pet = actor("hpet", "Wolf")
    w.me = actor("me", "Jambix")
    w.tank = actor("tank", "Brick")
    w.healer = actor("heal", "Mend")
    w.rogue = actor("rogue", "Stab")
    w.hunter = actor("hunter", "Shoot", w.pet)
    w.members = {
        { name = "Brick", role = "TANK", class_file = "WARRIOR", object = w.tank },
        { name = "Mend", role = "HEALER", class_file = "PRIEST", object = w.healer },
        { name = "Stab", role = "DAMAGER", class_file = "ROGUE", object = w.rogue },
        { name = "Shoot", role = "DAMAGER", class_file = "HUNTER", object = w.hunter },
    }
    return w
end

local function names(board)
    local out = {}
    for i = 1, board.n do out[i] = board.entries[i].name end
    return table.concat(out, ",")
end

local T = {}

-- --- ranking ---------------------------------------------------------------------

T[#T + 1] = { "a dungeon pull: the tank holds it, you are #2 at 85% of six", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", {
        tank = t(3, 100), me = t(0, 85), rogue = t(0, 60), heal = t(0, 30),
        hunter = t(0, 50), hpet = t(0, 10),
    })
    w.rows = { row(boss, { target_guid = "tank" }) }
    local threat = runtime(w)
    threat._poll()

    local board = threat.get("boss")
    assert(board, "a board for the boss")
    assert_eq(names(board), "Brick,Jambix,Stab,Shoot,Mend,Wolf", "ranked by percent, holder first")
    assert_eq(board.count, 6, "six ranked")
    assert_eq(board.tank.name, "Brick", "the warrior holds it")
    assert_eq(board.next_percent, 85, "and you are the one chasing")
    local pct, rank, count, tanking = threat.mine("boss")
    assert_eq(pct, 85, "your percent")
    assert_eq(rank, 2, "your rank")
    assert_eq(count, 6, "of six")
    assert_eq(tanking, false, "not yours")
    assert_eq(board.entries[1].role, "TANK", "roles ride along from the party rows")
    assert_eq(board.entries[1].class, "WARRIOR", "and classes")
    assert_eq(board.entries[6].is_pet, true, "the hunter's pet is ranked")
    assert_eq(board.pet, nil, "and it is not your pet")
end }

T[#T + 1] = { "status says who holds it, not is_tanking -- which Era gets wrong", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { tank = t(3, 100, false), me = t(0, 40, true) })
    w.rows = { row(boss, { target_guid = "tank" }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boss")
    assert_eq(board.tank.name, "Brick", "status 3 holds it")
    assert_eq(board.my_rank, 2, "your bogus is_tanking changed nothing")
end }

T[#T + 1] = { "the holder reads 100 whatever percent the client hands back for it", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { tank = t(2, 64), me = t(1, 92) })
    w.rows = { row(boss, { target_guid = "tank" }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boss")
    assert_eq(board.entries[1].name, "Brick", "insecure, still the holder")
    assert_eq(board.entries[1].percent, 100, "at 100")
    assert_eq(board.my_percent, 92, "you, eight points from pulling")
end }

T[#T + 1] = { "a mob on someone outside the group: they hold #1 and your rank says so", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { me = t(0, 70), rogue = t(0, 40) })
    -- The enemies service's own read is what makes it our fight.
    w.rows = { row(boss, { target_guid = "escort", threat = { status = 0, percent = 70 } }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boss")
    assert(board, "still a fight of ours: you have threat on it")
    assert_eq(board.outside_tank, true, "an outsider holds it")
    assert_eq(board.tank, nil, "nobody in the group does")
    assert_eq(board.my_rank, 2, "so you are second")
    assert_eq(board.count, 3, "of three")
end }

T[#T + 1] = { "nobody reports holding it but the mob is on one of us: that one is the tank", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { tank = t(1, 90), me = t(1, 95) })
    w.rows = { row(boss, { target_guid = "tank" }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boss")
    assert_eq(board.tank.name, "Brick", "its target holds it")
    assert_eq(board.my_rank, 2, "you second, despite the higher figure")
    assert_eq(board.outside_tank, false, "no outsider")
end }

T[#T + 1] = { "your pet holding it: the board names it, you are behind it", function()
    clock.s = 1000.0
    local pet = actor("mypet", "Cat")
    local w = { me = actor("me", "Jambix", pet) }
    local boar = mob("boar", { mypet = t(3, 100), me = t(0, 55) })
    w.rows = { row(boar, { target_guid = "mypet" }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boar")
    assert_eq(board.pet.name, "Cat", "your pet's entry")
    assert_eq(board.tank, board.pet, "and it holds the boar")
    assert_eq(board.my_rank, 2, "you behind it")
end }

T[#T + 1] = { "the client says nothing, but the mob is on you: you hold it, marked inferred", function()
    clock.s = 1000.0
    local w = { me = actor("me", "Jambix") }
    local boar = mob("boar", {})      -- no answer for anyone
    w.rows = { row(boar, { target_guid = "me" }) }
    local threat = runtime(w)
    threat._poll()
    local board = threat.get("boar")
    assert(board, "a board all the same")
    assert_eq(board.my_rank, 1, "you first")
    assert_eq(board.my_percent, 100, "at 100")
    assert_eq(board.me.inferred, true, "and it says where that came from")
    local s = threat.stats()
    assert_eq(s.asked, 1, "the client was asked")
    assert_eq(s.answered, 0, "and never answered")
    assert_eq(s.inferred, 1, "one inferred holder")
end }

T[#T + 1] = { "company: other players and your pet, for what holding it means", function()
    clock.s = 1000.0
    local w = dungeon()
    local threat = runtime(w)
    threat._poll()
    local c = threat.company()
    assert_eq(c.players, 4, "four party members")
    assert_eq(c.pet, false, "the hunter's pet is not yours")

    local solo = { me = actor("me", "Jambix", actor("mypet", "Cat")) }
    local threat2 = runtime(solo)
    threat2._poll()
    assert_eq(threat2.company().players, 0, "nobody else")
    assert_eq(threat2.company().pet, true, "your pet")
end }

-- --- which mobs ------------------------------------------------------------------

T[#T + 1] = { "only the group's fights get a board, and one goes the tick its fight ends", function()
    clock.s = 1000.0
    local w = dungeon()
    local ours = mob("ours", { tank = t(3, 100), me = t(0, 20) })
    local idle = mob("idle", { me = t(0, 0) })
    local theirs = mob("theirs", {})
    local far = mob("far", { tank = t(3, 100) })
    w.rows = {
        row(ours, { target_guid = "tank" }),
        row(idle, { in_combat = false }),
        row(theirs, { target_guid = "stranger" }),
        row(far, { target_guid = "tank", dist = 80 }),
    }
    local threat = runtime(w)
    threat._poll()
    assert(threat.get("ours"), "on the tank: ours")
    assert_eq(threat.get("idle"), nil, "out of combat: no board")
    assert_eq(threat.get("theirs"), nil, "a stranger's fight with none of our threat: no board")
    assert_eq(threat.get("far"), nil, "past sixty yards: no board")
    assert_eq(idle.asked + theirs.asked + far.asked, 0, "and none of them was asked anything")

    clock.s = clock.s + 0.1
    w.rows = { row(ours, { in_combat = false }) }
    threat._poll()
    assert_eq(threat.get("ours"), nil, "the fight ended: gone on the same tick")
    assert_eq(threat.count(), 0, "no boards")
end }

T[#T + 1] = { "the target goes first, and the ten-board cap never cuts it", function()
    clock.s = 1000.0
    local w = dungeon()
    local rows = {}
    for i = 1, 12 do
        rows[i] = row(mob("m" .. i, { tank = t(3, 100) }), { target_guid = "tank", dist = i })
    end
    w.rows = rows
    w.me.target = rows[12].obj
    local threat = runtime(w)
    threat._poll()
    assert_eq(threat.count(), 4, "four boards' worth of budget on the first tick")
    threat._poll()
    threat._poll()
    local list = threat.boards()
    assert_eq(threat.count(), 10, "capped at ten")
    assert_eq(list[1].guid, "m12", "the target first, though it is the farthest")
    assert_eq(list[1].is_target, true, "and flagged")
    assert_eq(list[2].guid, "m1", "then nearest")
    assert_eq(threat.get("m11"), nil, "the eleventh nearest is cut")
end }

-- --- cost ------------------------------------------------------------------------

T[#T + 1] = { "solo with no pet: your answer is the enemies row's, no native at all", function()
    clock.s = 1000.0
    local w = { me = actor("me", "Jambix") }
    local boar = mob("boar", {})
    w.rows = { row(boar, { target_guid = "me", threat = { status = 3, percent = 100 }, threat_at = 999.9 }) }
    local threat = runtime(w)
    threat._poll()
    assert_eq(boar.asked, 0, "not asked")
    local pct, rank, count, tanking = threat.mine("boar")
    assert_eq(pct, 100, "holding it")
    assert_eq(rank, 1, "first")
    assert_eq(count, 1, "of one")
    assert_eq(tanking, true, "yours")
    assert_eq(threat.stats().reads, 0, "zero reads this tick")
end }

T[#T + 1] = { "cadence: the target twice a second, everything else once", function()
    clock.s = 1000.0
    local w = dungeon()
    local target = mob("target", { tank = t(3, 100) })
    local other = mob("other", { tank = t(3, 100) })
    w.rows = { row(target, { target_guid = "tank" }), row(other, { target_guid = "tank", dist = 20 }) }
    w.me.target = target
    local threat = runtime(w)
    threat._poll()
    local roster = #threat.roster()
    assert_eq(roster, 6, "you, four members, one pet")
    assert_eq(target.asked, roster, "one ask per member")
    assert_eq(other.asked, roster, "both read on the first tick")

    clock.s = 1000.6
    threat._poll()
    assert_eq(target.asked, roster * 2, "the target again after half a second")
    assert_eq(other.asked, roster, "the other not yet")

    clock.s = 1001.1
    threat._poll()
    assert_eq(other.asked, roster * 2, "the other after a second")
end }

T[#T + 1] = { "a raid-sized roster reads one board a tick, never starving", function()
    clock.s = 1000.0
    local w = dungeon()
    w.raid = {}
    for i = 1, 30 do w.raid["raid" .. i] = actor("r" .. i, "Raider" .. i) end
    local threat = runtime(w)
    -- Five ticks to probe the forty tokens, then the roster takes them in.
    for _ = 1, 6 do
        threat._poll()
        clock.s = clock.s + 0.02
    end
    local roster = #threat.roster()
    assert_eq(roster, 36, "six from the party, thirty from the raid tokens")

    local a = mob("a", { tank = t(3, 100) })
    local b = mob("b", { tank = t(3, 100) })
    w.rows = { row(a, { target_guid = "tank" }), row(b, { target_guid = "tank", dist = 20 }) }
    threat._poll()
    assert_eq(a.asked, roster, "one whole board this tick, over the 24-native budget")
    assert_eq(b.asked, 0, "the next waits")
    clock.s = clock.s + 0.02
    threat._poll()
    assert_eq(b.asked, roster, "and is read on the next tick")
end }

T[#T + 1] = { "raid tokens: eight a tick, and none at all outside a party", function()
    clock.s = 1000.0
    local solo = { me = actor("me", "Jambix") }
    local threat, _, resolved = runtime(solo)
    for _ = 1, 10 do
        threat._poll()
        clock.s = clock.s + 0.02
    end
    assert_eq(next(resolved), nil, "solo: no token probed")

    local w = dungeon()
    local threat2, _, resolved2 = runtime(w)
    threat2._poll()                       -- builds the roster: in a party now
    threat2._poll()
    local probed = 0
    for _, n in pairs(resolved2) do probed = probed + n end
    assert_eq(probed, 8, "eight tokens on the first probing tick")
    for _ = 1, 4 do threat2._poll() end
    probed = 0
    for _, n in pairs(resolved2) do probed = probed + n end
    assert_eq(probed, 40, "the forty over five ticks")
    threat2._poll()
    assert_eq(resolved2.raid1, 1, "then quiet until the next sweep")
end }

-- --- events and helpers ----------------------------------------------------------

T[#T + 1] = { "you rip aggro: gained once, lost once the tank takes it back", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { tank = t(3, 100), me = t(1, 98) })
    w.rows = { row(boss, { target_guid = "tank" }) }
    w.me.target = boss
    local threat, emitted = runtime(w)
    threat._poll()
    assert_eq(#emitted, 0, "nothing while the tank holds it")

    boss.answers = { tank = t(0, 91), me = t(3, 100) }
    w.rows = { row(boss, { target_guid = "me" }) }
    clock.s = 1000.6
    threat._poll()
    assert_eq(#emitted, 1, "one event")
    assert_eq(emitted[1].name, "jcore.threat.gained", "gained")
    assert_eq(emitted[1][1].guid, "boss", "carrying the board")
    assert_eq(threat.holding(), 1, "you hold one mob")

    clock.s = 1001.2
    threat._poll()
    assert_eq(#emitted, 1, "not again while it stays yours")

    boss.answers = { tank = t(3, 100), me = t(0, 70) }
    w.rows = { row(boss, { target_guid = "tank" }) }
    clock.s = 1001.8
    threat._poll()
    assert_eq(emitted[2].name, "jcore.threat.lost", "lost")
    assert_eq(threat.holding(), 0, "none now")
end }

T[#T + 1] = { "closest_to_pulling: the mob you are nearest to taking, not one you hold", function()
    clock.s = 1000.0
    local w = dungeon()
    local a = mob("a", { tank = t(3, 100), me = t(0, 60) })
    local b = mob("b", { tank = t(3, 100), me = t(1, 94) })
    local c = mob("c", { me = t(3, 100), tank = t(0, 50) })
    w.rows = {
        row(a, { target_guid = "tank" }),
        row(b, { target_guid = "tank", dist = 12 }),
        row(c, { target_guid = "me", dist = 14 }),
    }
    local threat = runtime(w)
    threat._poll()
    local board, pct = threat.closest_to_pulling()
    assert_eq(board and board.guid, "b", "b, at 94")
    assert_eq(pct, 94, "94")
end }

T[#T + 1] = { "switched off, or no player: no boards and no asks", function()
    clock.s = 1000.0
    local w = dungeon()
    local boss = mob("boss", { tank = t(3, 100) })
    w.rows = { row(boss, { target_guid = "tank" }) }
    local threat = runtime(w)
    threat.set_enabled(false)
    threat._poll()
    assert_eq(threat.count(), 0, "off: nothing")
    assert_eq(boss.asked, 0, "off: not asked")
    threat.set_enabled(true)
    threat._poll()
    assert(threat.get("boss"), "back on")
    w.me = nil
    threat._poll()
    assert_eq(threat.get("boss"), nil, "no player: cleared")
end }

-- --- which way round ----------------------------------------------------------

--- The real enemies service, for its threat reader. Nothing is polled: only
--- situation() and threat_order() are exercised, and all() is replaced.
local function real_enemies()
    local try = function(fn, a, b, c)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, a, b, c)
        if ok then return v end
        return nil
    end
    return make_enemies({
        util = {},
        events = { emit = function() end, on = function() end },
        cache = { try = try },
        units = {},
        combat = {},
        log = { for_tag = function() return { fmt = function() end, info = function() end } end },
    })
end

--- A client that answers holder:get_threat_situation(mob) -- the contract's
--- reading -- and only zeros the other way round.
local function holder_first(answers)
    local asked = { holder = 0, mob = 0 }
    local function holder(guid)
        return {
            guid = guid, name = guid,
            is_valid = function() return true end,
            get_threat_situation = function(self, m)
                asked.holder = asked.holder + 1
                return (answers[m.guid] or {})[self.guid] or t(0, 0)
            end,
        }
    end
    local function foe(guid)
        return {
            guid = guid, is_valid = function() return true end,
            get_threat_situation = function()
                asked.mob = asked.mob + 1
                return t(0, 0)
            end,
        }
    end
    return holder, foe, asked
end

T[#T + 1] = { "a holder-first client: both ways until three reads agree, then one", function()
    local enemies = real_enemies()
    local holder, foe, asked = holder_first({ boss = { me = t(3, 100) } })
    local me, boss = holder("me"), foe("boss")

    local s, cost = enemies.situation(boss, me, true)
    assert_eq(s.status, 3, "the answer that says more is used before it settles")
    assert_eq(cost, 2, "two natives while unsettled")
    enemies.situation(boss, me, false)
    assert_eq(enemies.threat_order(), nil, "a read where it is not on you is no test")
    enemies.situation(boss, me, true)
    enemies.situation(boss, me, true)
    assert_eq(enemies.threat_order(), "holder", "three votes settle it")

    local before = asked.mob
    local s2, cost2 = enemies.situation(boss, me, true)
    assert_eq(s2.status, 3, "still the right answer")
    assert_eq(cost2, 1, "one native now")
    assert_eq(asked.mob, before, "the wrong way round is no longer asked")
end }

T[#T + 1] = { "a mob-first client settles the other way", function()
    local enemies = real_enemies()
    local boss = mob("boss", { me = t(3, 100) })
    local me = actor("me", "Jambix")
    me.get_threat_situation = function() return t(0, 0) end
    for _ = 1, 3 do enemies.situation(boss, me, true) end
    assert_eq(enemies.threat_order(), "mob", "settled mob-first")
    local s, cost = enemies.situation(boss, me, false)
    assert_eq(s.status, 3, "answered")
    assert_eq(cost, 1, "one native")
end }

T[#T + 1] = { "answers that disagree never settle: both ways for good, never a wrong lock", function()
    local enemies = real_enemies()
    local holder, foe = holder_first({ a = { me = t(3, 100) } })
    local me = holder("me")
    local a = foe("a")
    local b = mob("b", { me = t(3, 100) })
    me.get_threat_situation = function(self, m)
        if m.guid == "a" then return t(3, 100) end
        return t(0, 0)
    end
    enemies.situation(a, me, true)
    enemies.situation(b, me, true)
    enemies.situation(a, me, true)
    enemies.situation(b, me, true)
    assert_eq(enemies.threat_order(), nil, "votes on both sides: not settled")
    local _, cost = enemies.situation(a, me, true)
    assert_eq(cost, 2, "still asking both")
end }

T[#T + 1] = { "the threat service ranks a holder-first client once its answers come in", function()
    clock.s = 1000.0
    local enemies = real_enemies()
    local holder, foe = holder_first({ boss = { tank = t(3, 100), me = t(0, 72), rogue = t(0, 40) } })
    local w = {
        me = holder("me"),
        members = {},
    }
    w.me.name = "Jambix"
    w.me.get_pet = function() return nil end
    local tank, rogue = holder("tank"), holder("rogue")
    w.members = {
        { name = "Brick", role = "TANK", class_file = "WARRIOR", object = tank },
        { name = "Stab", role = "DAMAGER", class_file = "ROGUE", object = rogue },
    }
    local boss = foe("boss")
    enemies.all = function() return { row(boss, { target_guid = "tank" }) } end

    local threat = make_threat({
        util = {},
        log = { for_tag = function() return { fmt = function() end } end },
        cache = { try = function(fn, a, b, c)
            if type(fn) ~= "function" then return nil end
            local ok, v = pcall(fn, a, b, c)
            if ok then return v end
            return nil
        end },
        events = { on = function() end, emit = function() end },
        units = {
            player = function() return w.me end,
            guid = function(u) return u and u.guid end,
            name = function(u) return u and u.name or "" end,
            by_guid = function() return nil end,
        },
        enemies = enemies,
        group = {
            ROLE = ROLE,
            role = function() return ROLE.NONE end,
            members = function() return w.members end,
            party_frames = function() return {} end,
        },
    })
    threat._poll()
    local pct, rank, count = threat.mine("boss")
    assert_eq(pct, 72, "your figure, from the holder-first answer")
    assert_eq(rank, 2, "second")
    assert_eq(count, 3, "of three")
    assert_eq(threat.get("boss").tank.name, "Brick", "the tank holds it")
end }

return T

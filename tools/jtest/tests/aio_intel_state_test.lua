-- Jambix AIO: the PvP intelligence state model (PVP_INTEL_PLAN.md, Phase 2)
-- -- modules/react/intel/state.lua and init.lua, built inside the reaction
-- engine's tick on a scripted clock. The bundle is tools/jtest/mock/
-- intel_bundle.lua (aio_hunter_pvp_test's, with the reads the state model
-- adds).
--
-- What these hold it to: nothing is read and the table says why with no
-- enemy player about; every observed field comes from the rows and every
-- inferred one carries a confidence a rule has to clear; the client's gaps
-- are listed, never read as safety; line of sight is geometry.sight, asked
-- at most twice a second, and nil is unknown; another unit's casts, auras
-- and (Era) combat-log lines are kept per player, bounded; a battleground
-- is observed, a duel is inferred; a zone change forgets everyone.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, bundle, rogue, hunter_ranges = B.unit, B.bundle, B.rogue, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

local T = {}

T[#T + 1] = { "off the field: no enemy player about, the picture says why and carries nobody", function()
    local G = bundle()
    G.rows, G.row, G.target_present = {}, nil, false
    G.tick()
    local S = G.React.world.W.intel
    assert_eq(S, G.S, "W.intel is the one reused table")
    assert_eq(S.active, false, "not active")
    has(S.why, "no enemy player within 40 yd", "why")
    assert_eq(S.foes_n, 0, "nobody carried")
    assert_eq(S.mode.kind, "world", "the world, no PvP")
    has(G.I.lines()[1], "Intel: off", "the readout says off")
end }

T[#T + 1] = { "an enemy rogue in melee on you: observed fields flat, the inferred ones with a confidence", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local S = G.S
    assert_eq(S.active, true, "active")
    assert_eq(S.players, 1, "one player in reach")
    assert_eq(S.attackers, 1, "on you")
    assert_eq(S.melee_attackers, 1, "in melee")
    assert_eq(S.mode.kind, "world_pvp", "world PvP")
    assert_eq(S.mode.source, "observed", "observed")
    assert_eq(S.mode.group, "solo", "solo")
    local f = S.foes[G.target.guid]
    assert(f ~= nil, "the rogue is carried")
    assert_eq(S.foe_list[1], f, "nearest first")
    assert_eq(f.dist, 3, "its distance, observed")
    assert_eq(f.targets_me, true, "on you, observed")
    assert_eq(f.class, "ROGUE", "its class, observed")
    assert_eq(f.class_source, "get_class", "from get_class")
    assert_eq(f.seen, "rows", "seen through the rows")
    -- Inferred: a value only above the threshold.
    local role, conf = G.I.sure(f.inferred.role, 0.6)
    assert_eq(role, "melee", "a rogue fights in melee")
    assert_near(conf, 0.9, 0.01, "at 0.9")
    local none, c2 = G.I.sure(f.inferred.role, 0.95)
    assert_eq(none, nil, "not at 0.95")
    assert_near(c2, 0.9, 0.01, "the confidence still comes back")
    assert_eq(f.inferred.spec.conf, 0, "a spec is unknown")
    has(f.inferred.spec.why, "not visible", "and says so")
    assert_eq(f.inferred.cooldowns.conf, 0, "cooldowns are unknown until Stage 3")
    assert_eq(f.inferred.stealth.v, true, "a rogue can stealth")
    assert_eq(f.inferred.mana.v, false, "a rogue has no mana")
end }

T[#T + 1] = { "a player whose class the client does not name: role unknown at confidence 0, never a guess", function()
    local G = bundle()
    G.row.dist = 10
    G.tick()
    local f = G.S.foes[G.target.guid]
    assert_eq(f.class, nil, "no class")
    assert_eq(f.class_source, "unknown", "said so")
    assert_eq(G.I.sure(f.inferred.role, 0.1), nil, "nothing clears even 0.1")
    assert_eq(f.inferred.role.conf, 0, "confidence 0")
end }

T[#T + 1] = { "a priest seen healing is a healer at 0.9; one not seen healing is 0.6 either way", function()
    local G = bundle()
    G.target.get_class = function() return PRIEST end
    G.row.dist = 25
    G.tick()
    local f = G.S.foes[G.target.guid]
    assert_eq(G.I.sure(f.inferred.role, 0.6), "caster", "a priest, no heal seen: caster at 0.6")
    assert_eq(G.I.sure(f.inferred.role, 0.7), nil, "not at 0.7")
    G.clock = G.clock + 0.1            -- pvp.lua's read of a player is once per clock tick
    G.row.casting = G.casting("Flash Heal", 1.0, 1.5)
    G.tick()
    f = G.S.foes[G.target.guid]
    assert_eq(G.I.sure(f.inferred.role, 0.85), "healer", "seen healing: a healer at 0.9")
    assert_eq(f.casting.name, "Flash Heal", "the cast on its bar, observed")
    assert_near(f.casting.left, 1.0, 0.05, "with its time left")
end }

T[#T + 1] = { "the target's band from the catalogue's ranges: melee, the dead zone, ranged, far", function()
    local G = bundle()
    rogue(G)
    hunter_ranges(G)
    G.tick()
    local env = G.S.env
    assert_eq(env.min_ranged, 8, "the minimum ranged distance")
    assert_eq(env.max_ranged, 35, "the maximum")
    assert_eq(env.ranges_source, "catalogue", "from the catalogue")
    assert_eq(env.target.zone, "melee", "3 yd is melee")
    G.distance, G.row.dist = 6.5, 6.5
    G.tick()
    assert_eq(G.S.env.target.zone, "dead_zone", "6.5 yd is the dead zone")
    G.distance, G.row.dist = 20, 20
    G.tick()
    assert_eq(G.S.env.target.zone, "ranged", "20 yd is ranged")
    G.distance, G.row.dist = 38, 38
    G.tick()
    assert_eq(G.S.env.target.zone, "far", "38 yd is past the bow")
end }

T[#T + 1] = { "without a catalogue the ranges say so, and only melee is assumed", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local env = G.S.env
    assert_eq(env.min_ranged, nil, "no minimum known")
    has(env.ranges_source, "no catalogue", "said so")
    assert_eq(env.target.zone, "melee", "3 yd is still melee")
    G.distance, G.row.dist = 20, 20
    G.tick()
    assert_eq(G.S.env.target.zone, "ranged", "and anything else is ranged, with no far edge")
end }

T[#T + 1] = { "line of sight: geometry.sight at most twice a second; nil is unknown, never false", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local los = G.S.env.target.los
    assert_eq(los.value, nil, "no geometry service: unknown")
    assert_eq(los.source, "no geometry service", "said so")
    G.with_sight(nil)
    G.run(1.0)
    assert_eq(G.S.env.target.los.value, nil, "nil from the ray: still unknown")
    has(G.S.env.target.los.source, "not calibrated", "and why")
    assert(G.sight_calls >= 2 and G.sight_calls <= 3, "two rays in a second, got " .. G.sight_calls)
    G.sight = false
    G.run(0.6)
    assert_eq(G.S.env.target.los.value, false, "a false ray is false")
    assert_eq(G.S.env.target.los.source, "geometry.sight", "from the ray")
    has(G.I.lines()[1], "LOS no", "the readout says no")
    G.sight = true
    G.run(0.6)
    assert_eq(G.S.env.target.los.value, true, "a true ray is true")
    -- A new target starts over: unknown until its own ray.
    G.target_present = false
    G.tick()
    assert_eq(G.S.env.target.los.source, "no target", "no target, no ray")
end }

T[#T + 1] = { "facing: a player turned to you, one turned away, and a rotation of 0 is not known", function()
    local G = bundle()
    rogue(G)
    G.me_pos = { x = 0, y = 0, z = 0 }
    G.row.x, G.row.y = 10, 0                      -- east of us
    G.target.get_rotation = function() return math.pi end   -- looking west, at us
    G.tick()
    local f = G.S.foes[G.target.guid]
    assert_eq(f.facing_me, true, "looking at us")
    G.target.get_rotation = function() return math.pi / 2 end   -- looking north
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(G.S.foes[G.target.guid].facing_me, false, "looking away")
    G.target.get_rotation = function() return 0 end
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(G.S.foes[G.target.guid].facing_me, nil, "0 is not known")
    -- Forever answers a direction instead.
    G.target.get_direction = function() return { x = -1, y = 0, z = 0 } end
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(G.S.foes[G.target.guid].facing_me, true, "a direction vector works")
    -- Read every 0.25 s, not every tick.
    local before = G.S.foes[G.target.guid].facing_at
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.foes[G.target.guid].facing_at, before, "not re-read inside 0.25 s")
end }

T[#T + 1] = { "casts by unit token: a nameplate resolving to the rogue is kept, an ally's token is not, an unknown one is counted", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    local sprint = G.id_of("Sprint")
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate3", "Cast-3-0-0-0-2983-00", sprint })
    local f = G.S.foes[G.target.guid]
    assert_eq(#f.recent, 1, "one recent ability")
    assert_eq(f.recent[1].name, "Sprint", "named")
    assert_eq(f.recent[1].kind, "cast", "a cast")
    assert_eq(f.recent[1].source, "UNIT_SPELLCAST_SUCCEEDED", "from the event")
    assert_eq(G.S.events.casts, 1, "counted")
    -- A channel event: the cast guid is a hole, the spell id stays at 3.
    G.fire("jcore.game_event.UNIT_SPELLCAST_CHANNEL_START", { "nameplate3", nil, G.id_of("Blizzard") })
    assert_eq(#f.recent, 2, "the channel kept")
    assert_eq(f.recent[2].kind, "channel", "as a channel")
    -- The group's and our own are not ours to keep.
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "party1", "Cast-x", sprint })
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-x", sprint })
    assert_eq(G.S.events.casts, 2, "nothing more counted")
    -- A token the object manager cannot resolve is counted, not kept.
    G.fire("jcore.game_event.UNIT_SPELLCAST_START", { "nameplate9", "Cast-x", sprint })
    assert_eq(G.S.events.unresolved, 1, "unresolved counted")
    assert_eq(G.S.events.casts, 2, "and not kept")
    has(G.I.lines()[2], "2 cast(s)", "the readout counts them")
    has(G.I.lines()[2], "last channel Blizzard", "and names the last")
end }

T[#T + 1] = { "a cast event from a player not yet in the rows makes a minimal entry, seen through the event", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local other = unit(G, "Player-1-00000002", { name = "Far", player = true })
    other.get_class = function() return WARRIOR end
    G.by_guid["nameplate5"] = other
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate5", "Cast-x", G.id_of("Charge") })
    local f = G.S.foes[other.guid]
    assert(f ~= nil, "the warrior is carried")
    assert_eq(f.seen, "event", "seen through an event")
    assert_eq(f.recent[1].name, "Charge", "with its cast")
    assert_eq(G.S.foes_n, 1, "but not in the nearest list: no row for it")
    -- A friendly unit's token never makes an entry.
    local friend = unit(G, "Player-1-00000003", { name = "Friend", player = true, hostile = false })
    G.by_guid["nameplate6"] = friend
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate6", "Cast-x", G.id_of("Charge") })
    assert_eq(G.S.foes[friend.guid], nil, "a friend is not a foe")
end }

T[#T + 1] = { "an aura appearing on an enemy is kept as a buff or a debuff; removals are not", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate3", 3, G.id_of("Evasion"), "Evasion", 0, 15, 0, nil, true, false })
    local f = G.S.foes[G.target.guid]
    assert_eq(#f.recent, 1, "kept")
    assert_eq(f.recent[1].kind, "buff", "a helpful aura")
    assert_eq(f.recent[1].name, "Evasion", "named from the record")
    assert_eq(f.recent[1].source, "UNIT_AURA", "from the aura record")
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate3", 4, G.id_of("Hamstring"), "Hamstring", 0, 15, 0, nil, false, true })
    assert_eq(f.recent[2].kind, "debuff", "a harmful one")
    G.fire("jcore.game_event.UNIT_AURA", { "removed", "nameplate3", 3 })
    G.fire("jcore.game_event.UNIT_AURA", { "full", "nameplate3" })
    assert_eq(#f.recent, 2, "removals and resends are not abilities")
    assert_eq(G.S.events.auras, 2, "counted")
end }

T[#T + 1] = { "Era: the combat log names a hostile player's instant cast by guid; a non-player's or a friend's is not kept", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local HOSTILE_PLAYER = 0x400 + 0x40 + 0x100   -- type player, reaction hostile, control player
    local kick = G.id_of("Kick")
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SPELL_CAST_SUCCESS", false, G.target.guid, "Enemy", HOSTILE_PLAYER, 0, "player", "Me", 0, 0, kick, "Kick", 1 })
    local f = G.S.foes[G.target.guid]
    assert_eq(#f.recent, 1, "kept")
    assert_eq(f.recent[1].source, "SPELL_CAST_SUCCESS", "from the log")
    assert_eq(f.recent[1].name, "Kick", "named")
    assert_eq(G.S.events.combat_log, 1, "counted")
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SPELL_CAST_SUCCESS", false, G.target.guid, "Enemy", 0x40 + 0x800, 0, "player", "Me", 0, 0, kick, "Kick", 1 })
    assert_eq(#f.recent, 1, "a hostile creature's flags are not a player's")
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SPELL_DAMAGE", false, G.target.guid, "Enemy", HOSTILE_PLAYER, 0, "player", "Me", 0, 0, kick, "Kick", 1, 50 })
    assert_eq(#f.recent, 1, "damage lines are not casts")
end }

T[#T + 1] = { "Forever: the combat log is not listened to, and the picture lists what the client leaves out", function()
    local G = bundle({ client = { forever = true, combat_log = false } })
    rogue(G)
    G.tick()
    local kick = G.id_of("Kick")
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SPELL_CAST_SUCCESS", false, G.target.guid, "Enemy", 0x440, 0, "player", "Me", 0, 0, kick, "Kick", 1 })
    assert_eq(G.S.events.combat_log, 0, "nothing from an empty event")
    local S = G.S
    assert_eq(S.client.forever, true, "Forever")
    assert_eq(S.client.combat_log, false, "no combat log")
    has(S.unavailable[1], "combat log", "listed")
    has(S.unavailable[2], "threat", "threat listed")
    has(G.I.lines()[2], "not on Forever: combat log by source, threat", "and in the readout")
    assert(#S.unknown >= 3, "what no client says is listed too")
end }

T[#T + 1] = { "the recent ring is bounded at 12, oldest out", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    for i = 1, 15 do
        G.clock = G.clock + 0.1
        G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate3", "Cast-x", G.id_of("Spell " .. i) })
    end
    local f = G.S.foes[G.target.guid]
    assert_eq(#f.recent, 12, "twelve kept")
    assert_eq(f.recent[1].name, "Spell 4", "the oldest three gone")
    assert_eq(f.recent[12].name, "Spell 15", "the newest last")
end }

T[#T + 1] = { "what controls you: by an aura with its caster, or by the client's own word", function()
    local G = bundle()
    rogue(G)
    G.aura("player", "Kidney Shot", 4.0, { caster = G.target })
    G.tick()
    local me = G.S.me
    assert(me.control ~= nil, "controlled")
    assert_eq(me.control.kind, "stun", "a stun")
    assert_eq(me.control.name, "Kidney Shot", "named")
    assert_eq(me.control.from_player, true, "a player's")
    assert_eq(me.control.helpless, true, "helpless")
    assert_eq(me.control.source, "aura", "from the aura")
    assert_near(me.control.left, 4.0, 0.05, "with its time left")
    has(G.I.lines()[1], "you: stun 4.0s (Kidney Shot, a player's)", "the readout says so")
    -- The client's loss-of-control read, with no debuff named.
    G.auras["player"] = nil
    G.loc = { valid = true, type = 6, spell_id = 0, end_time = (G.clock + 2) * 1000 }
    G.tick()
    me = G.S.me
    assert(me.control ~= nil, "still controlled")
    assert_eq(me.control.kind, "stun", "a stun, from the type")
    assert_eq(me.control.source, "client", "from the client")
    assert_eq(me.control.from_player, nil, "whose it is: not known")
    G.loc = nil
    G.aura("player", "Wing Clip", 6.0, { caster = G.target })
    G.tick()
    me = G.S.me
    assert_eq(me.control, nil, "a snare is not a control")
    assert_eq(me.snare.kind, "snare", "it is the snare")
end }

T[#T + 1] = { "our abilities by what they are for: known, ready, and what is on cooldown", function()
    local G = bundle()
    rogue(G)
    G.roles = {
        defensive = { { name = "Feign Death" }, { name = "Deterrence" } },
        escape = { { name = "Feign Death" }, { name = "Wing Clip" }, { name = "Disengage" } },
        cc = { { name = "Freezing Trap" } }, disorient = { { name = "Scatter Shot" } },
        slow = { { name = "Concussive Shot" }, { name = "Wing Clip" } },
    }
    G.known["Wing Clip"], G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true, true
    G.unready["Freezing Trap"] = true
    G.tick()
    local me = G.S.me
    assert_eq(me.defensives_known, 0, "no defensive in the book at 26")
    assert_eq(me.escapes_known, 1, "one escape known")
    assert_eq(me.escapes_ready, 1, "and ready")
    assert_eq(me.controls_known, 1, "one control known")
    assert_eq(me.controls_ready, 0, "on cooldown")
    assert_eq(me.slows_known, 2, "two slows")
    local trap = nil
    for _, row in ipairs(me.abilities.controls) do if row.name == "Freezing Trap" then trap = row end end
    assert(trap and trap.known and not trap.ready and trap.cooldown == 12, "the trap's row: known, not ready, 12 s")
    has(G.I.lines()[1], "ready: 0/0 defensives, 1/1 escapes, 0/1 controls", "the readout counts them")
    -- The class module's own list fills in where the catalogue has no row.
    G.class.defensives = { "Feign Death", "Deterrence", "Stoneform" }
    G.known["Stoneform"] = true
    G.class.key = "hunter2"              -- a changed class rebuilds the lists
    G.tick()
    assert_eq(G.S.me.defensives_known, 1, "Stoneform from the class list")
end }

T[#T + 1] = { "the mode: a battleground is observed, a duel is inferred from DUEL_REQUESTED and one player on you, and ends", function()
    local G = bundle()
    rogue(G)
    G.instance = "pvp"
    G.tick()
    assert_eq(G.S.mode.kind, "bg", "a battleground")
    assert_eq(G.S.mode.source, "observed", "observed")
    G.instance = "none"
    G.clock = G.clock + 1.1
    G.tick()
    assert_eq(G.S.mode.kind, "world_pvp", "back in the world")
    G.fire("jcore.game_event.DUEL_REQUESTED", {})
    G.tick()
    assert_eq(G.S.mode.kind, "duel", "a duel")
    assert_eq(G.S.mode.source, "inferred", "inferred")
    has(G.S.mode.why, "DUEL_REQUESTED", "from the request")
    has(G.I.lines()[1], "Intel: duel? (solo)", "the readout marks the guess")
    -- Two players on you is not a duel.
    local second = unit(G, "Player-1-00000002", { name = "Second", player = true })
    G.rows = { G.row, G.row_for(second, { dist = 10 }) }
    G.tick()
    assert_eq(G.S.mode.kind, "world_pvp", "two on you: not a duel")
    G.rows = { G.row }
    G.fire("jcore.game_event.DUEL_FINISHED", {})
    G.tick()
    assert_eq(G.S.mode.kind, "world_pvp", "finished")
    assert_eq(G.S.mode.source, "observed", "and observed again")
end }

T[#T + 1] = { "allies: the group's members with role, health and distance, nearest first, re-read twice a second", function()
    local G = bundle()
    rogue(G)
    local tank = unit(G, "Player-1-00000010", { name = "Tanky", player = true, hostile = false })
    local healer = unit(G, "Player-1-00000011", { name = "Heals", player = true, hostile = false })
    G.group.in_group = true
    G.members = { tank, healer }
    G.tank, G.healer = tank, healer
    G.health[tank.guid] = 0.4
    G.dist = { [tank.guid] = 12, [healer.guid] = 6, [G.target.guid] = 3 }
    G.tick()
    local S = G.S
    assert_eq(S.allies_n, 2, "two allies")
    assert_eq(S.ally_list[1].name, "Heals", "nearest first")
    assert_eq(S.ally_list[1].role, "healer", "the healer")
    assert_eq(S.ally_list[2].role, "tank", "the tank")
    assert_near(S.ally_list[2].hp, 0.4, 0.01, "at 40%")
    assert_eq(S.mode.group, "party", "a party")
    -- The rogue turns on the healer: observed on its row.
    G.row.targeting_me, G.row.target_guid = false, healer.guid
    G.tick()
    assert_eq(G.S.foes[G.target.guid].targets_ally, true, "on an ally")
    assert_eq(G.S.attackers, 0, "not on you")
end }

T[#T + 1] = { "the pet: on a player held by a control that damage breaks", function()
    local G = bundle()
    rogue(G)
    G.pet_alive, G.pet_on = true, G.target
    G.row.control = { kind = "incapacitate", breaks = true, name = "Freezing Trap Effect", remaining = 10, from = "debuff" }
    G.tick()
    local S = G.S
    assert_eq(S.pet.alive, true, "a pet")
    assert_eq(S.pet.target_guid, G.target.guid, "on the rogue")
    assert_eq(S.pet.on_player, true, "a player")
    assert_eq(S.pet.on_controlled, true, "under a control damage breaks")
    local f = S.foes[G.target.guid]
    assert_eq(f.control.kind, "incapacitate", "the control, observed")
    assert_eq(f.control.breaks, true, "breaks on damage")
    assert_eq(f.control.source, "debuff", "from its debuffs (Forever's read)")
    has(G.I.lines()[1], "incapacitate 10.0s", "the readout says so")
    -- Era's read says the type and the time, not whether damage breaks it.
    G.row.control = { spell_id = G.id_of("Polymorph"), type = 9, remaining = 5 }
    G.tick()
    f = G.S.foes[G.target.guid]
    assert_eq(f.control.breaks, nil, "not known from the client's read")
    assert_eq(f.control.name, "Polymorph", "named from the id")
    assert_eq(G.S.pet.on_controlled, false, "so the pet is not said to be on a breakable one")
end }

T[#T + 1] = { "flag carriers in a battleground, from the flag auras: theirs and yours", function()
    local G = bundle()
    rogue(G)
    G.instance = "pvp"
    G.aura(G.target.guid, "Warsong Flag", nil)
    G.tick()
    local S = G.S
    assert_eq(S.mode.kind, "bg", "a battleground")
    assert_eq(S.foes[G.target.guid].flag, true, "it carries a flag")
    assert_eq(#S.env.objectives.carriers, 1, "one carrier")
    assert_eq(S.env.objectives.carriers[1].enemy, true, "an enemy")
    G.aura("player", "Silverwing Flag", nil)
    G.tick()
    assert_eq(G.S.me.flag, true, "you carry one")
    assert_eq(#G.S.env.objectives.carriers, 2, "two carriers")
    assert_eq(G.S.env.objectives.source, "flag auras", "from the auras")
    G.instance = "none"
    G.clock = G.clock + 1.1
    G.tick()
    assert_eq(#G.S.env.objectives.carriers, 0, "nothing outside a battleground")
end }

T[#T + 1] = { "a zone change forgets every player; a player gone 30 s is swept", function()
    local G = bundle()
    rogue(G)
    G.tick()
    assert_eq(G.S.foes_n, 1, "carried")
    G.fire("jcore.zone.changed", 1, 0)
    assert_eq(G.S.foes[G.target.guid], nil, "forgotten")
    assert_eq(G.S.active, false, "off until the next tick")
    G.tick()
    assert_eq(G.S.foes_n, 1, "seen again")
    G.rows, G.row, G.target_present = {}, nil, false
    G.run(2.0)
    assert(G.S.foes[G.target.guid] ~= nil, "kept a while once gone")
    G.run(35.0)
    assert_eq(G.S.foes[G.target.guid], nil, "swept after 30 s")
end }

T[#T + 1] = { "switched off: nothing is read and the table says off; the picture is reused between ticks", function()
    local G = bundle()
    rogue(G)
    G.with_sight(true)
    G.tick()
    local first = G.React.world.W.intel
    G.run(0.5)
    assert_eq(G.React.world.W.intel, first, "the same table")
    assert_eq(first.ticks, 6, "six builds")
    local calls = G.sight_calls
    G.settings.intel_enabled = false
    G.run(1.0)
    assert_eq(G.S.off, true, "off")
    assert_eq(G.S.active, false, "not active")
    assert_eq(G.sight_calls, calls, "no ray cast while off")
    assert_eq(G.I.lines()[1], "Intel: off", "the readout says off")
    assert_eq(G.S.ticks, 6, "no builds while off")
end }

T[#T + 1] = { "our own velocity is inferred from a position trail, and says so", function()
    local G = bundle()
    rogue(G)
    G.tick()
    assert_eq(G.S.me.velocity.conf, 0, "no trail yet")
    has(G.S.me.velocity.why, "0.4 s", "and why")
    for i = 1, 8 do
        G.clock = G.clock + 0.1
        G.me_pos = { x = i * 0.7, y = 0, z = 0 }
        G.tick()
    end
    local v, conf = G.I.sure(G.S.me.velocity, 0.7)
    assert(v ~= nil, "a velocity, at " .. tostring(conf))
    assert_near(v.speed, 7, 0.5, "seven yards a second")
    assert(v.vx > 0 and math.abs(v.vy) < 0.1, "heading east")
end }

T[#T + 1] = { "the readout's first line names the picture", function()
    local G = bundle()
    rogue(G)
    hunter_ranges(G)
    G.with_sight(true)
    G.tick()
    local line = G.I.lines()[1]
    has(line, "Intel: world_pvp (solo)", "the mode")
    has(line, "1 player(s) in 40 yd, 1 on you", "the count")
    has(line, "target ROGUE melee (0.90)", "the target with its confidence")
    has(line, "3 yd melee", "the band")
    has(line, "LOS yes", "the sight")
end }

T[#T + 1] = { "the reactions still decide with the picture present: the engine's tick returns its verdict", function()
    local G = bundle()
    rogue(G)
    G.known["Wing Clip"] = true
    G.tick()
    assert(type(G.verdict) == "table", "a verdict")
    assert(G.React.world.W.intel.active, "with the picture on")
    assert_eq(G.sent("Wing Clip"), 1, "the PvP hunter's clip still goes out")
end }

return T

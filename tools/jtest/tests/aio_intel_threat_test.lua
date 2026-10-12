-- Jambix AIO: the PvP threat read (PVP_INTEL_PLAN.md, Stage 2 / brief
-- Phase 4) -- modules/react/intel/threat.lua on the picture state.lua
-- builds, with score.lua's weights, inside the reaction engine's tick on a
-- scripted clock. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: nothing with nobody about; every indicator the
-- brief names turns on from the observations that mean it, with words and
-- points; a burst already covered by a defensive of ours scores a fraction;
-- missing combat information widens the band and is said, never read as
-- safety; the level steps up at once and down only after a dwell; the
-- Reactions window's conditions read it.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

--- The bundle's hunter with an escape in its book (Wing Clip, ready), as a
--- level-26 hunter has: otherwise "no escape, a melee player on you" and the
--- no-answers scaling join every scenario.
local function bundle(opts)
    local G = B.bundle(opts)
    G.class.escapes = { "Wing Clip", "Feign Death" }
    G.known["Wing Clip"] = true
    return G
end

local rogue = B.rogue

local function threat(G) return G.S.threat end

local function indicator(G, name)
    local T = threat(G)
    for i = 1, #T.list do
        if T.list[i].name == name then return T.list[i] end
    end
    return nil
end

--- An enemy warrior on you, at `dist`.
local function warrior(G, dist)
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = dist or 3, dist or 3
end

local T = {}

T[#T + 1] = { "nobody about: INFORMATIONAL, no points, no reasons", function()
    local G = bundle()
    G.rows, G.row, G.target_present = {}, nil, false
    G.tick()
    local X = threat(G)
    assert_eq(X.level, "INFORMATIONAL", "calm")
    assert_eq(X.score, 0, "no points")
    assert_eq(#X.reasons, 0, "no reasons")
    assert_eq(X.high, 0, "no band either")
end }

T[#T + 1] = { "a rogue in melee on you at full health: inside Kidney Shot's reach, LOW, and the words say so", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local X = threat(G)
    local row = indicator(G, "in_control_reach")
    assert(row ~= nil, "in a control's reach")
    has(row.why, "Kidney Shot reach", "named")
    assert_eq(X.level, "LOW", "low at full health")
    assert(X.score > 8 and X.score < 25, "between LOW and MODERATE: " .. X.score)
    assert_eq(X.highest, row, "the top indicator")
    assert_near(X.by_foe[G.target.guid], row.points, 0.01, "the reach's points are that player's")
    assert_near(X.by_foe[G.target.guid], X.score, 0.01, "and all of it")
end }

T[#T + 1] = { "a burst on you: MODERATE at full health, HIGH at 40%, and the points carry their reasons", function()
    local G = bundle()
    warrior(G, 3)
    G.aura(G.target.guid, "Recklessness", 10)
    G.tick()
    local X = threat(G)
    local row = indicator(G, "burst_on_me")
    assert(row ~= nil, "the burst is seen")
    has(row.why, "bursting on you (Recklessness)", "named")
    assert_eq(X.level, "MODERATE", "moderate at full health: " .. X.score)
    G.hp = 0.4
    G.tick()
    X = threat(G)
    assert_eq(X.level, "HIGH", "high at 40%: " .. X.score)
    assert(X.hp_factor > 1.1, "health scaled it up: " .. X.hp_factor)
    has(G.I.lines()[1], "threat HIGH", "the readout says so")
    has(G.I.lines()[1], "bursting on you (Recklessness) +", "with the reason")
end }

T[#T + 1] = { "a burst already covered: Deterrence up cuts a physical burst to a fraction and says so", function()
    local G = bundle()
    warrior(G, 3)
    G.aura(G.target.guid, "Recklessness", 10)
    G.hp = 0.4
    G.tick()
    local before = indicator(G, "burst_on_me").points
    G.aura("player", "Deterrence", 8)
    G.tick()
    local X = threat(G)
    local row = indicator(G, "burst_on_me")
    assert(row ~= nil and row.points < before * 0.25, "a fraction of before: " .. tostring(row and row.points) .. " of " .. before)
    has(row.why, "85% covered by Deterrence", "the cover is said")
    assert_eq(X.protection.names[1], "Deterrence", "the protection is listed")
    assert_near(X.protection.physical, 0.85, 0.01, "physical covered")
    assert_eq(X.protection.spell, 0, "spells not")
    assert(X.score < 50, "the score is under HIGH's line: " .. X.score)
    G.run(0.7)                           -- the level steps down after its dwell
    assert(threat(G).level ~= "HIGH", "no longer HIGH: " .. threat(G).level)
    has(G.I.lines()[1], "covered: Deterrence", "the readout lists it")
    -- A spell burst is not covered by Deterrence (pvp.lua reads a player
    -- once per clock tick: the clock moves between aura changes).
    G.auras[G.target.guid] = nil
    G.aura(G.target.guid, "Arcane Power", 10)
    G.clock = G.clock + 0.1
    G.tick()
    row = indicator(G, "burst_on_me")
    assert(row ~= nil and row.points > before * 0.9, "a spell burst is whole again: " .. tostring(row and row.points) .. " vs " .. before)
    -- Ice Block covers everything.
    G.aura("player", "Ice Block", 8)
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(indicator(G, "burst_on_me"), nil, "nothing lands through Ice Block")
end }

T[#T + 1] = { "a dangerous cast at you: MODERATE, urgent as it nears, and the incoming-cast flag", function()
    local G = bundle()
    G.target.get_class = function() return PRIEST end
    G.row.dist, G.distance = 25, 25
    G.row.casting = G.casting("Mind Control", 2.5, 3.0)
    G.tick()
    local X = threat(G)
    local row = indicator(G, "cast_at_me")
    assert(row ~= nil, "the cast is seen")
    has(row.why, "casting Mind Control at you (2.5s)", "named with its time")
    assert_eq(X.incoming_cast, true, "the flag")
    local far = row.points
    G.clock = G.clock + 0.1
    G.row.casting = G.casting("Mind Control", 0.4, 3.0)
    G.tick()
    row = indicator(G, "cast_at_me")
    assert(row.points > far, "worth more as it nears: " .. row.points .. " > " .. far)
    assert_eq(threat(G).level, "MODERATE", "moderate: " .. threat(G).score)
    -- A heal cast at itself is not a cast at you.
    G.row.casting = G.casting("Flash Heal", 1.0, 1.5)
    G.row.targeting_me = false
    G.tick()
    assert_eq(indicator(G, "cast_at_me"), nil, "not at you")
    assert_eq(threat(G).incoming_cast, false, "no flag")
end }

T[#T + 1] = { "a cast or a turn at the healer: the ally indicators, heavier for the healer", function()
    local G = bundle()
    G.target.get_class = function() return WARRIOR end
    local healer = unit(G, "Player-1-00000011", { name = "Heals", player = true, hostile = false })
    local other = unit(G, "Player-1-00000012", { name = "Dps", player = true, hostile = false })
    G.group.in_group = true
    G.members, G.healer = { healer, other }, healer
    G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = false, other.guid, 20, 20
    G.tick()
    local plain = indicator(G, "ally_targeted")
    assert(plain ~= nil, "an ally targeted")
    has(plain.why, "on Dps", "named")
    local plain_points = plain.points          -- the rows are pooled: keep the number
    G.row.target_guid = healer.guid
    G.tick()
    local heal = indicator(G, "ally_targeted")
    assert(heal.points > plain_points, "the healer weighs more: " .. heal.points .. " > " .. plain_points)
    has(heal.why, "(the healer)", "and says so")
    G.row.casting = G.casting("Mortal Strike", 0.5, 1.0)   -- no danger weight for a name detect.lua does not know
    G.tick()
    assert_eq(indicator(G, "cast_at_ally"), nil, "a cast detect.lua does not call dangerous is not one")
    G.target.get_class = function() return PRIEST end
    G.row.casting = G.casting("Mind Control", 1.0, 3.0)
    G.clock = G.clock + 0.1
    G.tick()
    local cast = indicator(G, "cast_at_ally")
    assert(cast ~= nil, "a dangerous cast at the healer")
    has(cast.why, "casting Mind Control at Heals (the healer)", "named")
end }

T[#T + 1] = { "a melee player closing: time to reach from the trail, and Intercept's reach from 8 to 25 yd", function()
    local G = bundle()
    warrior(G, 12)
    G.row.time_to_reach, G.row.closing = 0.4, 7
    G.tick()
    local closing = indicator(G, "melee_closing")
    assert(closing ~= nil, "closing")
    has(closing.why, "closing, 0.4s to reach you", "with the seconds")
    assert_near(closing.rel, 0.9, 0.01, "as sure as its role: a warrior at 0.9")
    local reach = indicator(G, "in_control_reach")
    assert(reach ~= nil, "in Intercept's reach")
    has(reach.why, "Intercept reach (12 of 25 yd)", "named")
    assert_eq(threat(G).level, "MODERATE", "moderate: " .. threat(G).score)
    -- At 5 yd it is inside Intercept's minimum: Concussion Blow instead.
    G.row.dist, G.distance, G.row.time_to_reach = 5, 5, 0
    G.tick()
    reach = indicator(G, "in_control_reach")
    has(reach.why, "Concussion Blow reach", "the closer control")
    assert_eq(indicator(G, "melee_closing"), nil, "already here: not closing")
    -- A caster class 12 yd away is not "closing" (a new player: a class,
    -- once read, is kept for the GUID, as it should be).
    local priest = unit(G, "Player-1-00000005", { name = "Priestly", player = true })
    priest.get_class = function() return PRIEST end
    G.rows = { G.row_for(priest, { dist = 12, time_to_reach = 0.4, closing = 7 }) }
    G.row, G.target = G.rows[1], priest
    G.distance = 12
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(indicator(G, "melee_closing"), nil, "a priest walking up is not a melee closing")
end }

T[#T + 1] = { "a gap closer just used: seen from the cast event, worth points for three seconds, then not", function()
    local G = bundle()
    warrior(G, 20)
    G.tick()
    G.by_guid["nameplate2"] = G.target
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate2", "Cast-x", G.id_of("Charge") })
    G.tick()
    local row = indicator(G, "mobility_used")
    assert(row ~= nil, "mobility used")
    has(row.why, "used Charge 0.0s ago", "named")
    G.run(2.5)
    assert(indicator(G, "mobility_used") ~= nil, "still counted inside 3 s")
    G.run(0.7)
    assert_eq(indicator(G, "mobility_used"), nil, "gone after 3 s")
    -- The buff it leaves counts the same way (an aura record).
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate2", 7, G.id_of("Sprint"), "Sprint", 0, 15, 0, nil, true, false })
    G.tick()
    assert(indicator(G, "mobility_used") ~= nil, "Sprint's buff counts")
end }

T[#T + 1] = { "several attackers: ten a head past the first, to thirty, and HIGH with three rogues on you", function()
    local G = bundle()
    rogue(G)
    local second = unit(G, "Player-1-00000002", { name = "Second", player = true })
    local third = unit(G, "Player-1-00000003", { name = "Third", player = true })
    second.get_class = function() return ROGUE end
    third.get_class = function() return ROGUE end
    G.rows = { G.row, G.row_for(second, { dist = 4 }), G.row_for(third, { dist = 4 }) }
    G.tick()
    local X = threat(G)
    local row = indicator(G, "extra_attackers")
    assert(row ~= nil, "extra attackers")
    has(row.why, "3 players on you", "counted")
    assert_eq(X.level, "HIGH", "high: " .. X.score)
    assert(X.by_foe[second.guid] > 0 and X.by_foe[third.guid] > 0, "each player has its share")
end }

T[#T + 1] = { "rooted with a melee player on you, and no escape ready: both said", function()
    local G = bundle()
    warrior(G, 3)
    G.roles = { escape = { { name = "Feign Death" }, { name = "Wing Clip" } } }
    G.known["Wing Clip"] = true
    G.unready["Wing Clip"] = true
    G.aura("player", "Hamstring", 10, { caster = G.target })
    G.tick()
    local rooted = indicator(G, "rooted_threatened")
    assert(rooted ~= nil, "rooted and threatened")
    has(rooted.why, "snare (Hamstring) with a melee player on you", "named")
    local gone = indicator(G, "escapes_gone")
    assert(gone ~= nil, "no escape ready")
    has(gone.why, "no escape ready", "said")
    G.unready["Wing Clip"] = nil
    G.tick()
    assert_eq(indicator(G, "escapes_gone"), nil, "an escape ready: not said")
    -- A root with nobody near is not a threat by itself.
    G.rows, G.row, G.target_present = {}, nil, false
    G.tick()
    assert_eq(indicator(G, "rooted_threatened"), nil, "nobody near")
end }

T[#T + 1] = { "dying: the field's race says 3 s to live at 25%: HIGH on Era, and on Forever the band says the read is weaker", function()
    local G = bundle()
    rogue(G)
    G.hp = 0.25
    G.P.field.state = setmetatable({}, { __index = function(_, k)
        local map = { plan = "SURVIVE", shape = "SINGLE", reason = "", count = 1, inbound = 0, elites = 0,
                      escalating = false, time_to_live = 3.0, time_to_clear = 10 }
        return map[k]
    end })
    G.tick()
    local X = threat(G)
    local lethal = indicator(G, "lethal")
    assert(lethal ~= nil, "lethal")
    has(lethal.why, "3s to live at this rate", "named")
    assert_eq(lethal.rel, 1, "measured on Era")
    assert(indicator(G, "low_and_hit") ~= nil, "low and being hit")
    assert_eq(X.level, "HIGH", "high: " .. X.score)
    assert_eq(#X.unknown, 0, "nothing unknown on Era")

    local F = bundle({ client = { forever = true, combat_log = false } })
    rogue(F)
    F.hp = 0.25
    F.P.field.state = G.P.field.state
    F.tick()
    local Y = threat(F)
    local lf = indicator(F, "lethal")
    assert_near(lf.rel, 0.7, 0.01, "read from your health on Forever")
    has(lf.why, "(read from your health)", "and said")
    assert(Y.score < X.score, "the point estimate is lower: " .. Y.score .. " < " .. X.score)
    assert(Y.high > Y.score + 5, "the band is wider: " .. Y.low .. "-" .. Y.high)
    has(Y.unknown[1], "Forever sends the combat log empty", "the unknown is named")
    has(F.I.lines()[1], "up to", "the readout says how high it could be")
end }

T[#T + 1] = { "a player vanished beside you: points for an opener you cannot see, and the unknown is named", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.rows, G.row = {}, nil
    G.target_present = false
    G.clock = G.clock + 0.3
    G.tick()
    local row = indicator(G, "vanished")
    assert(row ~= nil, "vanished")
    has(threat(G).unknown[1], "where the vanished player is", "unknown named")
    assert(threat(G).active ~= false, "still active on the vanish")
end }

T[#T + 1] = { "the level steps up at once and down only after a dwell", function()
    local G = bundle()
    warrior(G, 3)
    G.hp = 0.4
    G.tick()
    assert_eq(threat(G).level, "LOW", "a warrior in reach at 40%: low: " .. threat(G).score)
    G.aura(G.target.guid, "Recklessness", 10)
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(threat(G).level, "HIGH", "up at once: " .. threat(G).score)
    assert_eq(threat(G).changed, true, "changed this tick")
    G.auras[G.target.guid] = nil
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(threat(G).level, "HIGH", "held while the score is below the line")
    assert(threat(G).score < 40, "the score is down: " .. threat(G).score)
    G.run(0.4)
    assert_eq(threat(G).level, "HIGH", "still held inside the dwell")
    G.run(0.3)
    assert_eq(threat(G).level, "LOW", "down after 0.6 s")
end }

T[#T + 1] = { "nothing to answer with scales every threat up a little", function()
    local G = bundle()
    warrior(G, 20)                      -- at range: "no escape with a melee player on you" stays out of it
    G.aura(G.target.guid, "Recklessness", 10)
    G.roles = { escape = { { name = "Wing Clip" } }, defensive = { { name = "Deterrence" } } }
    G.known["Wing Clip"], G.known["Deterrence"] = true, true
    G.tick()
    local with = threat(G).score
    G.unready["Wing Clip"], G.unready["Deterrence"] = true, true
    G.tick()
    local without = threat(G).score
    assert_near(without / with, 1.15, 0.02, "fifteen percent more with nothing ready")
end }

T[#T + 1] = { "the Reactions window's conditions read it: the level, the score, the cast, the target's mobility and defensive", function()
    local G = bundle()
    warrior(G, 3)
    G.known["Wing Clip"] = true
    G.aura(G.target.guid, "Recklessness", 10)
    G.hp = 0.4
    G.tick()
    local C = G.React.custom
    assert(C ~= nil, "your reactions are loaded in the bundle")
    assert_eq(C.cond_code({ mode = "gui", key = "f_threat", op = "is", value = "HIGH" }), 'fight.threat == "HIGH"', "the level row")
    assert_eq(C.cond_code({ mode = "gui", key = "f_threat_score", op = ">=", value = 50 }), "fight.threat_score >= 50", "the score row")
    assert_eq(C.cond_code({ mode = "gui", key = "f_incoming_cast", op = "is" }), "fight.incoming_cast", "the cast row")
    assert_eq(C.cond_code({ mode = "gui", key = "t_mobility", op = "is" }), "target.mobility", "the mobility row")
    assert_eq(C.cond_code({ mode = "gui", key = "t_defensive", op = "is" }), "target.defensive", "the defensive row")
    local labels = C.choices("threats")
    assert_eq(labels[1], "CRITICAL", "the levels are offered")
    -- Live: a reaction on "threat is HIGH" shoots when it is (a spell no
    -- built-in presses here, so the count is the reaction's own).
    G.known["Arcane Shot"] = true
    local id = C.save({ name = "Threatened", importance = "defensive",
        conds = { { mode = "gui", key = "f_threat", op = "is", value = "HIGH" },
                  { mode = "lua", code = "fight.threat_score >= 40" } },
        actions = { { mode = "gui", kind = "spell", spell = "Arcane Shot", target = "target" } } })
    assert(id ~= nil, "saved into the hunter's bucket")
    G.run(0.4)                           -- a tick or two behind the PvP hunter's own Wing Clip
    assert_eq(threat(G).level, "HIGH", "high")
    assert(G.sent("Arcane Shot") >= 1, "the reaction went out on the level: " .. tostring(C.why(C.get(id))))
    -- The target's mobility and defensive, through the picture.
    G.by_guid["nameplate2"] = G.target
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate2", "Cast-x", G.id_of("Charge") })
    G.aura(G.target.guid, "Evasion", 10)
    G.clock = G.clock + 0.1
    G.tick()
    G.known["Concussive Shot"] = true
    local lua = C.save({ name = "Reads", importance = "defensive",
        conds = { { mode = "lua", code = "target.mobility and target.defensive and fight.incoming_cast == false" } },
        actions = { { mode = "gui", kind = "spell", spell = "Concussive Shot", target = "target" } } })
    G.run(0.4)
    assert(lua ~= nil, "the second reaction saved (ids: " .. tostring(lua) .. ", " .. #C.list() .. " in the list)")
    local rt = C.runtime(lua)
    assert(rt ~= nil, "the reaction ran: " .. tostring(C.why(C.get(lua))))
    assert(rt.conds[1].ok == true, "mobility and defensive read true, no cast incoming: " .. tostring(rt.conds[1].shown))
    assert(G.sent("Concussive Shot") >= 1, "and it went out")
end }

return T

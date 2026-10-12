-- Jambix AIO: opponent prediction (PVP_INTEL_PLAN.md, Stage 7 / brief
-- Phase 6, reworked on the 2026-10-12 review) -- modules/react/intel/predict.lua
-- inside the reaction engine's tick on a scripted clock. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: every pattern is a chance with a hit, a miss and
-- an attribution; a chance the player could not answer (its ability seen
-- down, its class without it) is skipped and said; a miss whose input was
-- never seen this session is unverified, not a miss; the rate and the
-- evidence are two numbers and two chances are LOW however high the rate;
-- the recent encounter and the session tendency are two clocks and a
-- player that changed is said to be adapting; every forecast is scored
-- when made, weak ones too, and never rewritten; the readout, the banner
-- and the window carry rate, reliability and inputs; the switches read calm.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR
local MAGE = 8

local function bundle(opts)
    local G = B.bundle(opts)
    G.class.escapes = { "Wing Clip", "Feign Death" }
    G.known["Wing Clip"] = true
    G.roles = {
        defensive = { { name = "Feign Death" }, { name = "Deterrence" } },
        cc = { { name = "Freezing Trap" } }, disorient = { { name = "Scatter Shot" } },
        slow = { { name = "Concussive Shot" }, { name = "Wing Clip" } },
    }
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    return G
end

local function fighting(G, age)
    G.in_combat, G.fight_age = true, age or 4
    G.row.in_combat, G.row.targeting_me = true, true
end

local function melee(G, class)
    G.target.get_class = function() return class or ROGUE end
    G.row.dist, G.distance = 3, 3
end

local function at_range(G, class)
    G.target.get_class = function() return class or MAGE end
    G.row.dist, G.distance = 20, 20
end

local function held_by(G, name, left, caster, kind)
    G.row.control = { spell_id = 1, kind = kind or "incapacitate", breaks = true, name = name, from = "debuff", remaining = left }
    G.aura(G.target.guid, name, left, { caster = caster })
end

local function our_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of(name) })
end
local function our_interrupted(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", { "player", 0, G.id_of(name) })
end
local function their_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) })
end
local function their_buff(G, name)
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate1", 0, G.id_of(name), name, 1, 10, 0, nil, true, false })
end
local function step(G, dt)
    G.clock = G.clock + (dt or 0.3)
    G.tick()
end
local function pred(G, key)
    local f = G.S.foes[G.target.guid]
    return f and f.predict and f.predict[key] or nil
end
local function cat(G, key)
    return G.S.foes[G.target.guid].pat.cats[key]
end
local function said_predictions(G)
    local n, last = 0, nil
    for _, s in ipairs(G.said) do
        if s.key == "intel_predict" then n, last = n + 1, s end
    end
    return n, last
end
--- A clip, then a gap closer after `after` seconds (nil: nothing).
local function chance(G, after)
    our_cast(G, "Wing Clip")
    if after then
        step(G, after); their_cast(G, "Intercept"); step(G, 0.3)
    else
        step(G, 2.5)
    end
end
--- A new fight with the same player.
local function new_encounter(G)
    G.in_combat, G.row.in_combat = false, false
    step(G, 1)
    G.in_combat, G.row.in_combat = true, true
    step(G, 0.3)
end

local T = {}

T[#T + 1] = { "switched off: nothing predicted, nothing counted; learning off: the counts freeze", function()
    local G = bundle()
    G.settings.intel_predict = false
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, 0.5)
    assert_eq(G.S.predict.target, nil, "nothing predicted")
    assert_eq(G.S.foes[G.target.guid].pat, nil, "nothing counted")
    G.settings.intel_predict = true
    G.settings.intel_learn = false
    chance(G, 0.5)
    assert_eq(pred(G, "mobility_when_slowed"), nil, "learning off: the chance is not counted")
end }

T[#T + 1] = { "the rate and the evidence are two numbers: one hit 0.67 never a prediction; two 0.75 and LOW; four moderate; the banner says both", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, 0.5)
    local e = pred(G, "mobility_when_slowed")
    assert(e, "counted")
    assert_eq(e.hits, 1, "one hit")
    assert_near(e.p, 0.667, 0.01, "the rate: (1 + 2 x 0.5) / (1 + 2)")
    assert_near(e.reliability, 0.333, 0.01, "the evidence: 1 / (1 + 2)")
    assert_eq(e.label, "low", "low")
    assert_eq(e.sure, false, "a single sighting is never a prediction")
    has(G.I.lines()[3], "predict: forming (mobility_when_slowed p 0.67)", "the readout says forming")
    G.clock = G.clock + 3
    chance(G, 1.0)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.sure, true, "two sightings: a prediction")
    assert(e.p > 0.7, "the rate about 0.75: " .. e.p)
    assert_near(e.reliability, 0.5, 0.02, "the evidence: 2 / (2 + 2)")
    assert_eq(e.label, "low", "and still LOW, however high the rate")
    assert_eq(G.S.predict.top.category, "mobility_when_slowed", "the target's surest")
    has(G.I.lines()[3], "predict: it closes the gap the moment it is slowed (p 0.7", "the readout")
    has(G.I.lines()[3], "reliability low, n1.", "with the evidence (two chances, a little faded)")
    G.run(4)
    local n, last = said_predictions(G)
    assert_eq(n, 1, "one banner")
    has(last.why, "reliability low", "which says the evidence too")
    G.clock = G.clock + 3
    chance(G, 0.8); G.clock = G.clock + 3
    chance(G, 0.8)
    e = pred(G, "mobility_when_slowed")
    assert(e.n > 3.5, "four chances: " .. e.n)
    assert_eq(e.label, "moderate", "moderate")
    assert_eq(G.React.custom.situation_now().t_pattern_rel >= 60, true, "the window's evidence reader")
end }

T[#T + 1] = { "a chance the player could not answer is skipped and said: a priest has no gap closer; a warrior with Charge and Intercept seen down", function()
    local G = bundle()
    at_range(G, PRIEST); fighting(G)
    step(G)
    chance(G, nil)
    local e = pred(G, "mobility_when_slowed")
    assert(e, "the pattern knows of the chance")
    assert_eq(e.total, 0, "not counted")
    assert_eq(e.skipped, 1, "skipped")
    has(e.skip_why, "its class has none", "why")
    has(e.why, "1 skipped: its class has none", "in the basis")
    G = bundle()
    at_range(G, WARRIOR); fighting(G)
    step(G)
    their_cast(G, "Charge"); step(G, 0.2); their_cast(G, "Intercept"); step(G)
    assert_eq(G.I.predict.availability(G.S, G.S.foes[G.target.guid], "Intercept"), "down", "Intercept seen: down")
    assert_eq(G.I.predict.availability(G.S, G.S.foes[G.target.guid], "Charge"), "down", "Charge seen: down")
    chance(G, nil)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.skipped, 1, "both down: no chance")
    has(e.skip_why, "back in", "why")
    assert_eq(G.S.predict.skipped, 1, "counted for the session")
end }

T[#T + 1] = { "a miss rests on its input: no enemy event ever seen, a quiet clip is unverified, not a miss; once one is seen, it is", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, nil)
    local e = pred(G, "mobility_when_slowed")
    assert(e, "the chance is known")
    assert_eq(e.total, 0, "not a miss")
    assert_eq(e.unverified, 1, "unverified")
    has(e.unverified_why, "no enemy cast or aura event seen this session", "why")
    has(e.data, "unverified", "the entry's data note")
    assert_eq(G.S.predict.inputs.enemy_casts, 0, "no cast seen")
    has(G.I.predict.inputs_text(), "casts 0 (unverified)", "the inputs line")
    has(G.I.summary().inputs, "interrupted 0 (unverified)", "in the Live view")
    their_cast(G, "Hamstring"); step(G)
    assert_eq(G.S.predict.inputs.enemy_casts, 1, "one cast seen")
    chance(G, nil)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.total, 1, "now a miss")
    assert_eq(e.hits, 0, "a miss")
    assert_eq(e.data, "ok", "the input is live")
end }

T[#T + 1] = { "two clocks: 200 s on, the recent chances have gone and the session tendency carries the prediction; 2000 s on it fades; a zone change forgets the player", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, 0.5); G.clock = G.clock + 3; chance(G, 0.5)
    local e = pred(G, "mobility_when_slowed")
    assert_eq(e.basis, "recent", "this encounter's chances")
    assert_eq(e.sure, true, "sure")
    G.clock = G.clock + 200; step(G)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.basis, "session", "the recent window passed: the session's tendency")
    assert(e.recent_n < 0.5, "recent evidence gone: " .. e.recent_n)
    assert(e.session_n > 1.5, "the session's still there: " .. e.session_n)
    assert_eq(e.sure, true, "the tendency still predicts")
    G.clock = G.clock + 2000; step(G)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.sure, false, "faded")
    assert(e.n < 1.5, "weighted samples " .. e.n)
    G.fire("jcore.zone.changed", {}); step(G)
    assert_eq(pred(G, "mobility_when_slowed"), nil, "forgotten with the player")
end }

T[#T + 1] = { "adaptation: three chances taken, then a new fight where two are not: the player is adapting, the prediction is withdrawn, the bait stands down", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    step(G)
    for _ = 1, 3 do chance(G, 0.5); G.clock = G.clock + 3 end
    local e = pred(G, "mobility_when_slowed")
    assert_eq(e.sure, true, "sure")
    step(G)
    assert(G.S.bait.target and G.S.bait.target.kind == "mobility", "a bait on it")
    new_encounter(G)
    chance(G, nil); chance(G, nil)
    e = pred(G, "mobility_when_slowed")
    assert_eq(e.adapting, true, "it changed")
    has(e.adapt_why, "it changed", "why")
    assert(e.recent_p < 0.4 and e.session_p > 0.5, string.format("recent %.2f against session %.2f", e.recent_p, e.session_p))
    assert_eq(G.S.predict.top, nil, "no prediction stands")
    assert_eq(G.React.custom.situation_now().t_pattern, "none", "the window's pattern reader")
    has(G.I.lines()[3], "predict: adapting", "the readout")
    assert_eq(G.S.bait.target, nil, "no bait")
    has(G.S.bait.blocked, "it is adapting", "why")
end }

T[#T + 1] = { "forecasts scored when made: the first chance at the prior, the weak second, the sure third; a miss later does not rewrite them; the sure one moves the prior", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, 0.5)
    local L = G.S.predict.ledger.mobility_when_slowed
    assert(L, "a ledger")
    assert_eq(L.forecasts, 1, "one forecast scored")
    assert_near(L.brier, 0.25, 0.001, "(0.5 - 1)^2: the prior forecast")
    assert_eq(L.bands.mid.n, 1, "the prior is a mid forecast")
    G.clock = G.clock + 3
    chance(G, 0.5)
    assert_eq(L.forecasts, 2, "two")
    assert_eq(L.bands.high.n, 1, "0.67 forecast: high band, though not sure")
    assert_near(L.brier, 0.25 + (1 - 0.667) ^ 2, 0.01, "scored at the rate it stood")
    assert_eq(G.S.predict.calibration.mobility_when_slowed, nil, "no sure forecast yet")
    G.clock = G.clock + 3
    local before = L.brier
    chance(G, nil)
    assert_eq(L.forecasts, 3, "three")
    assert(L.brier > before + 0.5, "a sure forecast (about 0.75) that missed: a heavy term")
    local cal = G.S.predict.calibration.mobility_when_slowed
    assert_eq(cal.predicted, 1, "one sure forecast tested")
    assert_eq(cal.right, 0, "and it failed")
    assert_near(pred(G, "mobility_when_slowed").prior, 0.4, 0.001, "the prior down a step")
    assert_eq(L.right, 2, "two forecasts on the right side of 0.5")
end }

T[#T + 1] = { "the defensive episode: under 60% with Evasion usable, a watch; Evasion at 30% is the hit and the measure; falling under 15% without one is the miss", function()
    local G = bundle()
    melee(G); fighting(G)
    G.health[G.target.guid], G.row.hp = 0.3, 0.3
    step(G)
    assert_eq(G.S.foes[G.target.guid].pat.watching_defensive, true, "watching")
    their_buff(G, "Evasion"); step(G)
    local e = pred(G, "defensive_threshold")
    assert(e and e.hits == 1, "the hit")
    has(e.v, "a defensive at about 30% health", "the threshold")
    assert_eq(pred(G, "saving_cooldowns_until_low").hits, 1, "saved until low")
    assert_eq(G.S.predict.ledger.defensive_threshold.forecasts, 1, "the episode's forecast scored")
    -- A second episode, after Evasion is back: it falls through without one.
    G.clock = G.clock + 400
    G.health[G.target.guid], G.row.hp = 0.9, 0.9
    step(G)
    G.health[G.target.guid], G.row.hp = 0.5, 0.5
    step(G)
    assert_eq(G.S.foes[G.target.guid].pat.watching_defensive, true, "watching again")
    G.health[G.target.guid], G.row.hp = 0.1, 0.1
    step(G)
    e = pred(G, "defensive_threshold")
    assert_eq(e.total, 2, "two episodes")
    assert_eq(e.hits, 1, "one without")
    has(cat(G, "defensive_threshold").events[2].why, "under the floor without one", "why")
    -- A shaman under the line has no defensive to watch for: skipped.
    G = bundle()
    melee(G, 7); fighting(G)
    G.health[G.target.guid], G.row.hp = 0.3, 0.3
    step(G)
    local sk = pred(G, "defensive_threshold")
    assert(sk and sk.skipped == 1, "skipped: " .. tostring(sk and sk.skip_why))
    has(sk.skip_why, "its class has none", "why")
end }

T[#T + 1] = { "interrupts: a Kick seen is observed at full weight; none seen, the player on you in reach is inferred at half; Aimed Shot going through a kicker in reach is the miss", function()
    local G = bundle()
    melee(G); fighting(G)
    step(G)
    their_cast(G, "Kick"); step(G, 0.2)
    our_interrupted(G, "Aimed Shot"); step(G)
    local e = pred(G, "interrupts_casts")
    assert(e and e.hits == 1, "a hit")
    local ev = cat(G, "interrupts_casts").events
    assert_eq(ev[1].w, 1, "observed: full weight")
    has(ev[1].why, "Kick on Aimed Shot", "the basis")
    G.clock = G.clock + 15                   -- Kick back
    step(G)
    local avail = G.I.predict.availability(G.S, G.S.foes[G.target.guid], "Kick")
    assert(avail ~= "down", "Kick is usable again: " .. tostring(avail))
    our_interrupted(G, "Aimed Shot"); step(G)
    ev = cat(G, "interrupts_casts").events
    assert(ev[2], "the inferred observation was recorded")
    assert_near(ev[2].w, 0.5, 0.001, "inferred: half weight")
    has(ev[2].why, "no kick seen: the player on you, inferred", "and says so")
    G.clock = G.clock + 15
    our_cast(G, "Aimed Shot"); step(G)
    e = pred(G, "interrupts_casts")
    assert_eq(e.total, 3, "a cast went through: a chance")
    assert_eq(e.hits, 2, "a miss")
    has(cat(G, "interrupts_casts").events[3].why, "Aimed Shot went through", "why")
    -- Out of Kick's reach: no chance.
    at_range(G, ROGUE); step(G)
    our_cast(G, "Aimed Shot"); step(G)
    assert_eq(pred(G, "interrupts_casts").total, 3, "out of reach: not a chance")
end }

T[#T + 1] = { "escapes control: Berserker Rage right after our trap is a hit; a Scatter Shot that runs its course is a miss (the trinket path is polled, always live)", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    held_by(G, "Freezing Trap Effect", 8, G.player); step(G)
    their_cast(G, "Berserker Rage"); step(G, 0.3)
    local e = pred(G, "escape_after_control")
    assert(e and e.hits == 1, "a hit")
    has(cat(G, "escape_after_control").events[1].why, "a breaker after Freezing Trap Effect", "why")
    G.clock = G.clock + 10
    held_by(G, "Scatter Shot", 4, G.player); step(G)
    G.run(2)
    e = pred(G, "escape_after_control")
    assert_eq(e.total, 2, "a second chance")
    assert_eq(e.hits, 1, "and a miss")
end }

T[#T + 1] = { "stacks bursts: Recklessness, then Death Wish; the window passing quietly after a burst is the miss", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.aura(G.target.guid, "Recklessness", 15); step(G)
    assert_eq(pred(G, "over_committing"), nil, "the first burst opens the chance, nothing scored yet")
    G.auras[G.target.guid] = {}
    G.clock = G.clock + 3; step(G)
    G.aura(G.target.guid, "Death Wish", 30); G.clock = G.clock + 2; step(G)
    local e = pred(G, "over_committing")
    assert(e and e.hits == 1, "stacked")
    has(cat(G, "over_committing").events[1].why, "Death Wish", "why")
    G.auras[G.target.guid] = {}
    G.clock = G.clock + 11; step(G)
    e = pred(G, "over_committing")
    assert_eq(e.total, 2, "the window after Death Wish passed quietly")
    assert_eq(e.hits, 1, "a miss")
end }

T[#T + 1] = { "goes for your pet: four seconds on it against one on you", function()
    local G = bundle()
    melee(G); fighting(G)
    G.pet_alive = true
    G.row.targeting_pet, G.row.targeting_me = true, false
    G.run(4.2)
    local e = pred(G, "targeting_pet")
    assert(e and e.hits >= 4, "four samples on the pet")
    assert_eq(e.sure, true, "a prediction")
    G.row.targeting_pet, G.row.targeting_me = false, true
    G.run(1.2)
    e = pred(G, "targeting_pet")
    assert(e.total > e.hits, "a sample on you: a miss")
end }

T[#T + 1] = { "the same opener: Charge, Charge; Hamstring breaks it; a fight with no cast seen in 6 s is no answer", function()
    local G = bundle()
    at_range(G, WARRIOR)
    G.in_combat, G.row.in_combat = false, false
    step(G)
    local function fight_with(opener)
        G.in_combat, G.row.in_combat = true, true
        step(G)
        if opener then their_cast(G, opener); step(G) end
        G.clock = G.clock + 8
        step(G)
        G.in_combat, G.row.in_combat = false, false
        step(G, 1)
    end
    fight_with("Charge")
    assert_eq(pred(G, "same_opener"), nil, "the first fight only records")
    fight_with("Charge")
    local e = pred(G, "same_opener")
    assert(e and e.hits == 1, "the same opener: a hit")
    has(e.v, "it opens with Charge", "named")
    fight_with("Hamstring")
    e = pred(G, "same_opener")
    assert_eq(e.total, 2, "two comparisons"); assert_eq(e.hits, 1, "one held")
    fight_with(nil)
    e = pred(G, "same_opener")
    assert_eq(e.total, 2, "no cast seen: no answer")
    assert_eq(e.unverified, 1, "unverified")
end }

T[#T + 1] = { "backs off under pressure: with its movement read, Rapid Fire then the distance opens is a hit, standing through is a miss; movement never read, the chance is unverified", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.row.moving = true
    step(G)
    our_cast(G, "Rapid Fire"); step(G)
    G.row.closing = -3; step(G)
    local e = pred(G, "retreating_when_pressured")
    assert(e and e.hits == 1, "a hit")
    G.row.closing = 0
    G.clock = G.clock + 10
    our_cast(G, "Rapid Fire"); G.run(5.5)
    e = pred(G, "retreating_when_pressured")
    assert_eq(e.total, 2, "two"); assert_eq(e.hits, 1, "one miss")
    G = bundle()
    at_range(G, WARRIOR); fighting(G)
    step(G)
    our_cast(G, "Rapid Fire"); G.run(5.5)
    e = pred(G, "retreating_when_pressured")
    assert_eq(e.total, 0, "nothing scored")
    assert_eq(e.unverified, 1, "unverified: no movement read")
end }

T[#T + 1] = { "the window reads it: pattern, rate, evidence; the Live view lists it with the response and the inputs", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    chance(G, 0.5); G.clock = G.clock + 3; chance(G, 0.5)
    step(G)
    local now = G.React.custom.situation_now()
    assert(now, "a picture")
    assert_eq(now.t_pattern, "mobility_when_slowed", "target.pattern")
    assert(now.t_pattern_conf >= 70, "the rate " .. tostring(now.t_pattern_conf))
    assert_near(now.t_pattern_rel, 50, 2, "the evidence")
    local sm = G.I.summary()
    assert(sm.predictions[1], "a prediction line")
    has(sm.predictions[1], "it closes the gap the moment it is slowed (p 0.7", "the words")
    has(sm.predictions[1], "reliability low", "with the evidence")
    has(sm.predictions[1], "slow it with the trap or Scatter Shot ready", "with the response")
    has(sm.inputs, "casts 2", "the inputs")
    assert_eq(G.S.predict.not_built.chasing_bad_terrain ~= nil, true, "the pattern not built says why")
end }

return T

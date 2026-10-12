-- Jambix AIO: the decision episodes (the brief "PvP Combat Experience &
-- Lessons Learned Collector", 2026-10-12) -- modules/react/intel/episodes.lua
-- inside the reaction engine's tick on a scripted clock. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: every type the brief lists opens a bounded window
-- on its observable trigger with the state before, the prediction and the
-- recommendation as they stood, and closes with what you did, the
-- prediction's outcome, the recommendation's outcome and a result that
-- follows a written rule; a duplicate trigger opens nothing; a window cut
-- by the player leaving or the fight ending is censored and its result
-- unknown; an inferred trigger makes the prediction invalid; the lesson
-- candidate's confidence grows only with comparable episodes; under the
-- harness every episode is test data and the network client refuses it.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR
local MAGE = 8

local function fake_storage(G)
    local files = {}
    G.P.ctx.storage = { files = files, read_json = function(n) return files[n] end, write_json = function(n, v) files[n] = v return true end }
    return files
end
local function fake_net(G)
    local net = { posts = {}, gets = {} }
    net.post_json = function(url, payload, opts, cb) net.posts[#net.posts + 1] = { url = url, payload = payload, cb = cb } return true end
    net.get_json = function(url, opts, cb) net.gets[#net.gets + 1] = { url = url, cb = cb } return true end
    G.P.ctx.net = net
    return net
end

local function bundle(opts)
    opts = opts or {}
    opts.client = opts.client or { forever = false, combat_log = true, version = "Vanilla", exact = "1.15.9.70003" }
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
    G.files = fake_storage(G)
    G.P.ctx.version = "1.7.8"
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
local function at_range(G, class, dist)
    G.target.get_class = function() return class or MAGE end
    G.row.dist, G.distance = dist or 20, dist or 20
end
local function held_by(G, name, left, caster, kind)
    G.row.control = { spell_id = 1, kind = kind or "incapacitate", breaks = true, name = name, from = "debuff", remaining = left }
    G.aura(G.target.guid, name, left, { caster = caster })
end
local function our_cast(G, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of(name) }) end
local function their_cast(G, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) }) end
local function their_buff(G, name) G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate1", 0, G.id_of(name), name, 1, 10, 0, nil, true, false }) end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function kill_target(G) G.target.dead, G.row.dead, G.health[G.target.guid], G.row.hp = true, true, 0, 0 end
local function E(G) return G.I.episodes end
local function last(G) return G.I.episodes.T.last end
local function open_n(G) return #G.I.episodes.T.open end
local function has_result(e, cat)
    for i = 1, #e.result.all do if e.result.all[i] == cat then return true end end
    return false
end
local function chance(G, after)
    our_cast(G, "Wing Clip")
    step(G, after); their_cast(G, "Intercept"); step(G, 0.3)
end

local T = {}

T[#T + 1] = { "a melee player closes the gap: the window opens on its Intercept with the state before; it reaches you and your health falls: the prediction HIT, the result worsened; test data flagged", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    step(G)
    -- Two chances teach the pattern; each Intercept opens and closes a window of its own.
    chance(G, 0.5); G.clock = G.clock + 6; chance(G, 0.5); G.clock = G.clock + 6
    step(G)
    their_cast(G, "Intercept"); step(G)
    assert_eq(open_n(G), 1, "one window open")
    local e = E(G).T.open[1]
    assert_eq(e.type, "gap_close_attempt", "the type")
    assert_eq(e.enemy_class, "WARRIOR", "its class")
    has(e.trigger.text, "Enemy Intercept at 20 yd", "the trigger")
    assert_eq(e.trigger.observed, true, "observed")
    assert_eq(e.before.zone, "ranged", "the state before: at range")
    assert_near(e.before.hp, 1.0, 0.001, "your health before")
    assert_eq(e.prediction.pattern, "mobility_when_slowed", "the tied pattern")
    assert_eq(e.prediction.sure, true, "a prediction stood")
    assert(e.recommendation.state ~= "NONE", "a tactical state stood: " .. e.recommendation.state)
    assert_eq(e.quality.test_data, true, "under the harness: test data")
    -- It reaches melee; you lose health.
    melee(G, WARRIOR)
    G.hp = 0.7
    G.run(5.2)
    e = last(G)
    assert(e and e.closed, "closed at its horizon")
    assert_eq(e.prediction.outcome, "HIT", "the prediction: it reached melee")
    has(e.prediction.outcome_why, "it reached melee", "why")
    assert_eq(e.result.primary, "SITUATION_WORSENED", "the result")
    has(e.result.why, "health -30%", "with the measure")
    has(e.result.why, "it reached melee", "and the zone")
    assert(e.lesson.candidate, "a lesson candidate")
    has(e.lesson.situation, "HUNTER vs WARRIOR", "the situation")
    assert_eq(e.after.zone, "melee", "the state after")
end }

T[#T + 1] = { "a rogue opens on you: the window opens as it enters combat on you; its first cast is noted; nothing measurable moved", function()
    local G = bundle()
    melee(G, ROGUE)
    G.in_combat, G.row.in_combat, G.row.targeting_me = false, false, false
    step(G)
    G.in_combat, G.row.in_combat, G.row.targeting_me = true, true, true
    step(G)
    assert_eq(open_n(G), 1, "one window")
    assert_eq(E(G).T.open[1].type, "rogue_opener", "the type")
    their_cast(G, "Cheap Shot"); step(G)
    G.run(6.2)
    local e = last(G)
    assert_eq(e.flags.opener_name, "Cheap Shot", "its opener noted")
    assert_eq(e.prediction.outcome, "NONE", "no opener prediction stood: none")
    -- Before: nobody on you (the previous tick); after: a rogue in melee on you. The rule reads that as it is.
    assert_eq(e.result.primary, "SITUATION_WORSENED", "a rogue opened on you")
    has(e.result.why, "the threat rose", "the measure")
end }

T[#T + 1] = { "a mage blinks: a short window; the recommendation's outcome has a reason even when it is unknown", function()
    local G = bundle()
    at_range(G, MAGE); fighting(G)
    step(G)
    their_cast(G, "Blink"); step(G)
    assert_eq(E(G).T.open[1].type, "blink", "the type")
    G.run(4.2)
    local e = last(G)
    assert_eq(e.result.primary, "NO_MEASURABLE_CHANGE", "nothing moved")
    assert(e.recommendation.outcome == "FOLLOWED" or e.recommendation.outcome == "NOT_FOLLOWED" or e.recommendation.outcome == "UNKNOWN", "an outcome")
    assert(type(e.recommendation.outcome_why) == "string" and #e.recommendation.outcome_why > 0, "with its reason")
end }

T[#T + 1] = { "an enemy's burst: you Feign Death; it leaves you: survival improved; the cooldown you spent is noted", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    G.known["Feign Death"] = true
    step(G)
    G.aura(G.target.guid, "Recklessness", 15); step(G)
    assert_eq(E(G).T.open[1].type, "enemy_burst", "the type")
    our_cast(G, "Feign Death"); step(G)
    G.auras[G.target.guid] = {}
    G.row.targeting_me = false
    G.run(10.2)
    local e = last(G)
    assert_eq(e.actions[1].name, "Feign Death", "what you did")
    assert_eq(e.flags.we_spent, "Feign Death", "a cooldown spent")
    assert(has_result(e, "SURVIVAL_IMPROVED"), "survival improved: " .. e.result.why)
    has(e.result.why, "SURVIVAL_IMPROVED: health held", "the measure")
    assert_eq(e.lesson.action, "Feign Death", "the lesson's action")
end }

T[#T + 1] = { "rooted with a player on you: the root ends and you get the range back: position improved", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.aura("player", "Frost Nova", 6, { caster = G.target }); step(G)
    assert_eq(open_n(G), 1, "one window")
    assert_eq(E(G).T.open[1].type, "rooted_under_pressure", "the type")
    assert_eq(E(G).T.open[1].before.rooted, true, "rooted before")
    G.auras["player"] = {}
    at_range(G, WARRIOR, 20)
    G.moving = true
    G.run(6.2)
    local e = last(G)
    assert(has_result(e, "POSITION_IMPROVED"), "position improved: " .. e.result.why)
    has(e.result.why, "melee -> ranged", "the zones")
end }

T[#T + 1] = { "the target enters your dead zone: a step out past it is position improved and the move followed", function()
    local G = bundle()
    at_range(G, WARRIOR, 20); fighting(G)
    step(G)
    at_range(G, WARRIOR, 6); step(G)
    assert_eq(E(G).T.open[1].type, "dead_zone_entry", "the type")
    assert_eq(E(G).T.open[1].before.zone, "dead_zone", "before")
    at_range(G, WARRIOR, 20)
    G.moving = true
    G.run(5.2)
    local e = last(G)
    assert(has_result(e, "POSITION_IMPROVED"), "position improved: " .. e.result.why)
end }

T[#T + 1] = { "your pet threatens a control: called off, the control holds: control successful", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    G.pet_alive, G.pet_on = true, G.target
    held_by(G, "Freezing Trap Effect", 8, G.player); step(G)
    assert_eq(E(G).T.open[1].type, "pet_breaks_cc", "the type")
    G.pet_on = nil
    G.run(4.2)
    local e = last(G)
    assert(has_result(e, "CONTROL_SUCCESSFUL"), "control successful: " .. e.result.why)
end }

T[#T + 1] = { "a kill window opens at 20%: it dies: objective progress and a damage opportunity; the window closes on the death", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.health[G.target.guid], G.row.hp = 0.2, 0.2
    step(G)
    assert_eq(E(G).T.open[1].type, "kill_opportunity", "the type")
    local w = E(G).T.open[1]
    kill_target(G); step(G)
    local e = last(G)
    assert(e and e.closed, string.format("closed on the death (open %d, last %s, unit %s, is_dead %s, closed %d, fight open %s)",
        #E(G).T.open, tostring(e), tostring(w.unit), tostring(w.unit and G.P.units.is_dead(w.unit)), #E(G).T.closed, tostring(G.I.debrief.T.open)))
    assert(has_result(e, "OBJECTIVE_PROGRESS"), "it died: " .. e.result.why)
    assert(has_result(e, "DAMAGE_OPPORTUNITY_CREATED"), "it lost its health: " .. e.result.why)
end }

T[#T + 1] = { "the opponent changes its defence: Evasion up, then gone: a damage opportunity", function()
    local G = bundle()
    melee(G, ROGUE); fighting(G)
    step(G)
    G.aura(G.target.guid, "Evasion", 10); step(G)
    assert_eq(E(G).T.open[1].type, "defensive_change", "the type")
    has(E(G).T.open[1].trigger.text, "Evasion at 100%", "the trigger")
    G.auras[G.target.guid] = {}
    G.run(6.2)
    local e = last(G)
    assert(has_result(e, "DAMAGE_OPPORTUNITY_CREATED"), "its defensive ended: " .. e.result.why)
end }

T[#T + 1] = { "several players on you: one leaves: survival improved", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    local second = unit(G, "Player-1-00000002", { name = "Second", player = true })
    second.get_class = function() return ROGUE end
    G.rows[2] = G.row_for(second, { dist = 4, targeting_me = true, in_combat = true })
    step(G)
    assert_eq(E(G).T.open[1].type, "outnumbered", "the type")
    assert_eq(E(G).T.open[1].before.attackers, 2, "two on you before")
    G.rows[2] = nil
    G.run(8.2)
    local e = last(G)
    assert(has_result(e, "SURVIVAL_IMPROVED"), "fewer on you: " .. e.result.why)
end }

T[#T + 1] = { "edge cases: a duplicate trigger opens nothing; the player leaving cuts the window (censored, unknown); an inferred trigger makes the prediction invalid", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    step(G)
    their_cast(G, "Intercept"); step(G)
    their_cast(G, "Intercept"); step(G)
    assert_eq(open_n(G), 1, "one window for two casts within the dedupe window")
    assert_eq(E(G).T.dropped_dup, 1, "the duplicate counted")
    G.rows = {}
    G.target_present = false
    G.run(2.5)
    local e = last(G)
    assert(e and e.closed, "closed")
    assert_eq(e.censored, "the player left the picture", "censored")
    assert_eq(e.result.primary, "UNKNOWN", "no result from a cut window")
    assert_eq(e.quality.incomplete, true, "flagged incomplete")
    assert_eq(e.prediction.outcome, "NONE", "no prediction stood (the first sighting is never one)")
    -- An inferred trigger: the predictor says the player is adapting.
    G = bundle()
    at_range(G, WARRIOR); fighting(G)
    step(G)
    for _ = 1, 3 do chance(G, 0.5); G.clock = G.clock + 6 end
    G.in_combat, G.row.in_combat = false, false
    step(G, 1)
    G.in_combat, G.row.in_combat = true, true
    step(G)
    for _ = 1, 2 do our_cast(G, "Wing Clip"); step(G, 2.5) end
    local found = nil
    for i = 1, #E(G).T.open do if E(G).T.open[i].trigger.observed == false then found = E(G).T.open[i] end end
    if not found then for i = 1, #E(G).T.closed do if E(G).T.closed[i].trigger.observed == false then found = E(G).T.closed[i] end end end
    assert(found, "the adapting window opened")
    has(found.trigger.text, "adapting on mobility_when_slowed", "the trigger")
    assert_eq(found.quality.unattributed, true, "flagged unattributed")
    G.run(6.2)
    local closed = nil
    for i = 1, #E(G).T.closed do if E(G).T.closed[i] == found then closed = found end end
    assert(closed and closed.closed, string.format("closed (found.closed %s, censored %s, open %d, closed %d, count %d, fight open %s)",
        tostring(found.closed), tostring(found.censored), #E(G).T.open, #E(G).T.closed, E(G).T.count, tostring(G.I.debrief.T.open)))
    assert_eq(closed.prediction.outcome, "INVALID", "an inferred trigger: the prediction is invalid")
    has(closed.prediction.outcome_why, "the trigger was inferred", "why")
end }

T[#T + 1] = { "the fight's summary, the page's lines, the lesson's confidence from comparable episodes, and the network's refusal of test data", function()
    local G = bundle()
    G.files["jambix.aio.central.json"] = { url = "https://db.example/jambix/", key = "k1" }
    local net = fake_net(G)
    G.settings.net_contribute = true
    at_range(G, MAGE); fighting(G)
    step(G)
    for i = 1, 3 do
        their_cast(G, "Blink"); step(G)
        G.run(4.5)
    end
    local e = last(G)
    assert_eq(e.lesson.confidence, "low", "three comparable episodes with the same result: low (never a rule from one)")
    assert_eq(E(G).T.comparable["blink|MAGE"].n, 3, "counted")
    their_cast(G, "Hamstring"); step(G)
    kill_target(G); step(G)
    local f = G.I.debrief.T.last
    assert(f and f.episodes_summary, "the fight carries its episodes' summary")
    local s = f.episodes_summary
    assert(s.episodes >= 3, "the episodes: " .. s.episodes)
    assert(s.by_type.blink == 3, "by type")
    assert(s.results.NO_MEASURABLE_CHANGE and s.results.NO_MEASURABLE_CHANGE >= 3, "the results")
    assert(#s.lessons >= 1, "a candidate lesson")
    has(table.concat(G.I.debrief.lines(), " || "), "Episodes: ", "on the page")
    has(table.concat(G.I.debrief.lines(), " || "), "Candidate (low):", "with the candidate")
    assert(#f.episodes >= 3 and f.episodes[1].id, "the compact episodes")
    assert_eq(f.episodes[1].quality.test_data, true, "test data")
    assert_eq(#G.I.central.queue(), 0, "the network client queued nothing")
    assert_eq(G.I.central.T.last_status, "test data is never uploaded", "and said why")
    assert_eq(E(G).T.count, 0, "the slate wiped for the next fight")
end }

T[#T + 1] = { "allowed by the context, a fight's episodes travel in the batch, compact and without names", function()
    local G = bundle()
    G.P.ctx.allow_test_upload = true
    G.files["jambix.aio.central.json"] = { url = "https://db.example/jambix/", key = "k1" }
    local net = fake_net(G)
    G.settings.net_contribute = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.aura(G.target.guid, "Recklessness", 15); step(G)
    G.run(10.5)
    their_cast(G, "Hamstring"); step(G)
    kill_target(G); step(G)
    local q = G.I.central.queue()
    assert_eq(q[1].kind, "batch", "a batch, for the episodes alone")
    local eps = q[1].body.episodes
    assert(eps and #eps >= 1, "episodes in it")
    assert_eq(eps[1].type, "enemy_burst", "the type")
    assert_eq(eps[1].quality.test_data, false, "allowed test data is not flagged")
    has(eps[1].trigger.text, "the player Recklessness", "the name replaced")
    assert(eps[1].before and eps[1].result and eps[1].recommendation and eps[1].prediction, "the compact form")
    assert_eq(q[1].body.episodes_summary.uploaded, #eps, "the summary says how many travelled")
end }

return T

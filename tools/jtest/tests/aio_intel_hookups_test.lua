-- Jambix AIO: the PvP intelligence's deferred hook-ups (PVP_INTEL_PLAN.md
-- Stage 13) -- the burst kept by the defensive bait, a racial breaker in the
-- held advice, the target's sure predictions in the state's advice, and the
-- recorded fights replayed on the test bench. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: the burst waits while the bait holds it, but
-- never over a high-confidence kill window, never for another player,
-- never under the no-time line, never with the bait switched off; held by
-- a fear, Will of the Forsaken is named when it is yours and ready, never
-- under a Polymorph it does not break; a sure prediction adds its response
-- after the state's own actions, labelled, and never changes the state; the
-- recorded moments become bench situations with what they recorded and
-- nothing invented, and a reaction replayed over them says where it would
-- have acted.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local hunter_ranges = B.hunter_ranges
local ROGUE, WARRIOR = B.ROGUE, B.WARRIOR

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.known["Arcane Shot"] = true
    G.by_guid["nameplate1"] = G.target
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function settle(G) step(G) step(G, 1.0) step(G) end
local function list_has(list, piece)
    for _, a in ipairs(list or {}) do if tostring(a):find(piece, 1, true) then return true, a end end
    return false
end

local T = {}

-- --- the burst kept by the bait ------------------------------------------------------------

T[#T + 1] = { "burst.lua: the defensive bait's hold keeps the window shut over a burst to line up, never over a high-confidence kill window, another player, the no-time line or the bait switched off", function()
    _G.core = _G.core or {}
    local verdict, bait_on = nil, true
    local bait = { T = { hold_burst = "Rapid Fire", hold_guid = "Player-1", hold_why = "Evasion unseen this session", hold_hp = 0.3 } }
    local P = {
        log = { fmt = function() end, info = function() end },
        ctx = { on = function() end, emit = function() end, cast = function() end, PRIORITY = { COOLDOWN = 80 } },
        units = { guid = function(u) return u.guid end }, combat = {},
        spellbook = { ready = function() return true end, id = function() return 1 end },
        opt = function(_, d) return d end, tune = function(_, d) return d / 100 end,
        react = { intel = { kill = { for_guid = function() return verdict end }, bait = bait,
                            module_on = function(name) return name ~= "bait" or bait_on end,
                            weights = { KILL = { no_time_hp = 0.12 } } } },
    }
    local burst = require("jambix_aio/modules/burst")(P)
    local class = { power = "MANA", burst = { { spell = "Rapid Fire", duration = 15 } } }
    local player = { guid = "Player-1", is_player = function() return true end }
    local s = { in_combat = true, target = player, player = {}, ttd = math.huge, power = 80, power_max = 100 }
    verdict = { v = "PREPARE_BURST", why = "a rogue at 30%, its outs unseen", conf = 0.5 }
    local ok, why = burst.should_open(s, class)
    assert_eq(ok, false, "held for the bait")
    has(why, "bait: hold Rapid Fire -- Evasion unseen this session", "says why")
    verdict = { v = "HIGH_CONFIDENCE_KILL_WINDOW", why = "every out down", conf = 0.9 }
    assert_eq((burst.should_open(s, class)), true, "a high-confidence kill window opens over the bait")
    verdict = { v = "PREPARE_BURST", why = "x", conf = 0.5 }
    bait.T.hold_hp = 0.1
    ok, why = burst.should_open(s, class)
    assert_eq(ok, true, "under the no-time line the burst goes: " .. tostring(why))
    bait.T.hold_hp, bait.T.hold_guid = 0.3, "Player-2"
    assert_eq((burst.should_open(s, class)), true, "another player's hold is not this one's")
    bait.T.hold_guid, bait_on = "Player-1", false
    assert_eq((burst.should_open(s, class)), true, "the bait switched off holds nothing")
end }

-- --- the held advice names a racial breaker ---------------------------------------------------

T[#T + 1] = { "held by a player's fear: Will of the Forsaken named when it is yours and ready; under a Polymorph it does not break, not named", function()
    local G = bundle()
    G.known["Will of the Forsaken"] = true
    G.target.get_class = function() return 9 end                 -- a warlock
    G.row.dist, G.distance = 15, 15
    G.in_combat, G.fight_age = true, 6
    G.row.in_combat, G.row.targeting_me = true, true
    G.aura("player", "Fear", 6.0, { caster = G.target })
    settle(G)
    assert_eq(G.S.tactic.state, "DEFENSIVE", "held")
    has(G.S.tactic.actions[1], "Will of the Forsaken (it breaks the fear)", "named first")
    -- On its cooldown: not named.
    G.unready["Will of the Forsaken"] = true
    step(G)
    assert(not list_has(G.S.tactic.actions, "Will of the Forsaken"), "not ready: not named")
    -- A Polymorph: Will of the Forsaken does not break it.
    G.unready["Will of the Forsaken"] = nil
    G.auras["player"] = nil
    G.aura("player", "Polymorph", 8.0, { caster = G.target })
    step(G)
    assert(not list_has(G.S.tactic.actions, "Will of the Forsaken"), "a polymorph: not named")
    has(G.S.tactic.actions[1], "the trinket", "the trinket line first")
end }

-- --- the target's sure predictions in the advice ---------------------------------------------

T[#T + 1] = { "a sure prediction adds its response after the state's own actions, labelled; it never changes the state; a forming one adds nothing", function()
    local G = bundle()
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = 20, 20
    G.in_combat, G.row.in_combat = false, false
    step(G)
    local function fight_with(opener)
        G.in_combat, G.row.in_combat, G.fight_age = true, true, 1
        step(G)
        if opener then G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(opener) }) end
        step(G)
        G.clock = G.clock + 8
        step(G)
        G.in_combat, G.row.in_combat = false, false
        step(G, 1)
    end
    fight_with("Charge"); fight_with("Charge")
    local e = G.S.foes[G.target.guid].predict.same_opener
    -- Forming (one hit): nothing added to the advice.
    G.in_combat, G.row.in_combat, G.fight_age = true, true, 1
    step(G)
    assert_eq(e.sure, false, "one hit is forming, never sure")
    assert(not list_has(G.S.tactic.actions, "predicted:"), "forming: nothing predicted in the advice")
    G.in_combat, G.row.in_combat = false, false
    step(G, 1)
    fight_with("Charge"); fight_with("Charge")
    e = G.S.foes[G.target.guid].predict.same_opener
    assert(e and e.sure, string.format("sure now: p %.2f, n %s", e and e.p or 0, tostring(e and e.n)))
    -- The next fight's opening at range.
    G.in_combat, G.row.in_combat, G.fight_age = true, true, 1
    step(G); step(G)
    local X = G.S.tactic
    assert_eq(X.state, "OPENING", "the state is the observed one")
    local found, line = list_has(X.actions, "predicted: it opens with Charge")
    assert(found, "the prediction in the advice: {" .. table.concat(X.actions, "; ") .. "}")
    has(line, "answer the opener before it lands", "its response")
    assert(not X.actions[1]:find("predicted", 1, true), "after the state's own actions")
    assert_eq(#X.predicted, 1, "listed")
end }

-- --- the recorded fights on the bench -------------------------------------------------------

local LOG = { version = 1, fights = {
    { outcome = "lost", mode = "world", episodes = {
        { id = "e1", type = "rogue_opener", enemy_class = "ROGUE", t = 1.6,
          before = { hp = 0.82, zone = "melee", gap = 2.1, threat = "HIGH", attackers = 1, controlled = true, defensives_ready = 1,
                     foe_hp = 0.95, foe_on_me = true },
          recommendation = { action = "Feign Death", move = "increase" }, actions = { "Feign Death" } },
        { id = "e2", type = "outnumbered", enemy_class = "ROGUE", t = 14, before = { hp = 0.25, zone = "melee", gap = -0.4,
          threat = "CRITICAL", attackers = 3, controlled = false, defensives_ready = 0, foe_hp = 0.6, foe_on_me = true },
          recommendation = { action = "Feign Death" }, actions = { "Healing Potion" } },
    } },
    { outcome = "won", mode = "world", episodes = {
        { id = "e3", type = "kill_opportunity", enemy_class = "PRIEST", t = 22, before = { hp = 0.7, zone = "ranged", gap = 24,
          threat = "LOW", attackers = 1, controlled = false, defensives_ready = 2, foe_hp = 0.18, foe_on_me = false },
          recommendation = { action = "Arcane Shot" }, actions = { "Arcane Shot" } },
        { id = "e4", type = "kill_opportunity", enemy_class = "PRIEST", t = 23, before = { hp = 0.7 },
          quality = { test_data = true } },
    } },
} }

T[#T + 1] = { "the recorded fights: each moment a bench situation, newest fight first, with what it recorded and nothing invented; test data left out", function()
    local G = bundle()
    G.files = { ["jambix.aio.fights.json"] = LOG }
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    local list = G.I.replay.situations()
    assert_eq(#list, 3, "three moments, the test one left out")
    has(list[1].label, "Replay: won vs priest, a kill window opens, 22 s in", "newest fight first")
    local s = list[1].s
    assert_eq(s.t_hp, 18, "the target's health")
    assert_eq(s.t_distance, 24, "its distance")
    assert_eq(s.pvp_threat, "LOW", "the threat")
    assert_eq(s.t_name, "a priest", "its class")
    local opener = list[2].s
    assert_eq(opener.controlled, true, "controlled, as recorded")
    assert_eq(opener.melee_on_me, 1, "in melee on you")
    assert_eq(list[3].s.t_distance, 0, "a negative gap is no distance")
    has(list[1].unrecorded, "your mana", "what it does not carry is said")
    -- On the bench's list, after the ready-made ones.
    local C = G.P.react.custom
    local all = C.presets()
    local D = require("jambix_aio/modules/react/custom_data")
    assert_eq(#all, #D.BENCH_PRESETS + 3, "the ready-made ones, then the recorded")
    assert_eq(all[#D.BENCH_PRESETS + 1].key, "replay_e3", "the newest moment first")
end }

T[#T + 1] = { "a reaction replayed over the recorded fights: where it would have acted, where its conditions did not hold", function()
    local G = bundle()
    G.files = { ["jambix.aio.fights.json"] = LOG }
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    G.known["Feign Death"] = true
    local r = { name = "Feign when critical", importance = "defensive", combat_only = true,
        conds = { { mode = "gui", key = "f_threat", op = "is", value = "CRITICAL", uid = 1 } },
        actions = { { mode = "gui", kind = "spell", spell = "Feign Death", target = "player", uid = 1 } } }
    local res = G.P.react.custom.replay(r)
    assert_eq(res.moments, 3, "three moments")
    assert_eq(res.acted, 1, "acted at the critical one: " .. res.line)
    assert_eq(res.held, 2, "its condition did not hold at the other two")
    has(res.line, "would have acted at 1 of 3 moments", "said")
    local acted = nil
    for _, m in ipairs(res.list) do if m.tone == "ok" then acted = m end end
    has(acted.label, "lost vs rogue, several players on you, 14 s in", "the moment")
    assert_eq(acted.did, "Healing Potion", "what you did then")
    -- No log: said so.
    local H = bundle()
    H.P.ctx.storage = { read_json = function() return nil end, write_json = function() return true end }
    has(H.P.react.custom.replay(r).line, "No recorded fight with a player yet", "nothing recorded")
end }

return T

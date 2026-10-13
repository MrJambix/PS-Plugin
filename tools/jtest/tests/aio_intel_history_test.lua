-- Jambix AIO: the history ledger (PVP_INTEL_PLAN.md Stage 11-b, the brief's
-- Phase 16 analytics) -- modules/react/intel/history.lua inside the
-- reaction engine's tick on a scripted clock, with a fake storage. The
-- bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: it records nothing switched off; it opens and
-- closes with the debrief's fight; each change of the advice is an entry
-- with what was predicted and why; advice naming an ability you have not
-- trained is counted invalid; a defensive spent while another covers is
-- spent for nothing and an overlap; a control on a player already held is
-- an overlap; forecasts scored this fight are its accuracy, none scored
-- reads "no forecast", never 0%; the log is written and the totals read it;
-- on Forever the recorder's trace gets the figures.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local hunter_ranges = B.hunter_ranges
local ROGUE, WARRIOR = B.ROGUE, B.WARRIOR

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    G.files = {}
    G.P.ctx.storage = {
        read_json = function(name) return G.files[name] end,
        write_json = function(name, v) G.files[name] = v return true end,
    }
    G.traces = {}
    G.P.ctx.emit = function(event, text) if event == "jcore.recorder.trace" then G.traces[#G.traces + 1] = text end end
    return G
end
local function fighting(G, class, dist)
    G.target.get_class = function() return class end
    G.row.dist, G.distance = dist or 3, dist or 3
    G.in_combat, G.fight_age = true, 4
    G.row.in_combat, G.row.targeting_me = true, true
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function our_cast(G, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of(name) }) end
local function kill_target(G)
    G.target.dead, G.row.dead, G.health[G.target.guid] = true, true, 0
    G.row.hp = 0
end
local function H(G) return G.I.history end

local T = {}

T[#T + 1] = { "switched off: nothing recorded, nothing written", function()
    local G = bundle()
    G.settings.intel_history = false
    fighting(G, WARRIOR)
    step(G); step(G)
    assert_eq(H(G).T.open, false, "no fight")
    kill_target(G); step(G)
    assert_eq(H(G).T.last, nil, "nothing kept")
    assert_eq(G.files["jambix.aio.history.json"], nil, "nothing written")
end }

T[#T + 1] = { "a fight: it opens with the debrief's; each change of advice is an entry; advice naming an untrained ability is invalid; it closes, writes and totals", function()
    local G = bundle()
    G.known["Arcane Shot"] = true                          -- Wing Clip NOT trained
    fighting(G, ROGUE)
    step(G)
    assert_eq(H(G).T.open, true, "open with the debrief's fight")
    G.run(2.0)
    local e = H(G).entries()
    assert(#e >= 1, "an entry")
    assert_eq(e[1].kind, "recommendation", "the advice")
    assert_eq(e[1].state, "CONTROL_DISTANCE", "a rogue in melee: " .. tostring(e[1].state))
    assert_eq(e[1].action, "Wing Clip", "the clip first")
    has(e[1].why, "in melee", "and why")
    local f = H(G).T.fight
    assert_eq(f.invalid, 1, "Wing Clip said, not trained")
    has(f.invalid_why[1], "Wing Clip said while not trained", "said")
    kill_target(G); step(G)
    assert_eq(H(G).T.open, false, "closed with it")
    local s = H(G).T.last.summary
    assert_eq(s.outcome, "won", "the debrief's outcome")
    assert_eq(s.invalid, 1, "kept")
    local log = G.files["jambix.aio.history.json"]
    assert(log and log.fights and #log.fights == 1, "written")
    local lines = H(G).lines()
    has(lines[1], "History (last fight): predictions no forecast scored, majors none spent, overlap 0", "the last fight; no forecast is not 0%")
    has(lines[2], "invalid: Wing Clip said while not trained", "the reason under it")
    has(lines[#lines], "History (1 fights kept)", "the totals")
    assert_eq(#G.traces, 0, "not Forever: no recorder trace")
end }

T[#T + 1] = { "a defensive spent while another covers is spent for nothing and an overlap; a control on a player already held is an overlap", function()
    local G = bundle()
    G.known["Deterrence"], G.known["Scatter Shot"] = true, true
    fighting(G, WARRIOR, 12)
    step(G)
    G.aura("player", "Deterrence", 8); step(G)
    our_cast(G, "Deterrence")
    local f = H(G).T.fight
    assert_eq(f.majors, 1, "a major")
    assert_eq(f.wasted, 1, "spent while Deterrence covered")
    has(f.wasted_why[1], "Deterrence while Deterrence covers", "why")
    assert_eq(f.overlap, 1, "and an overlap")
    -- An ally's Polymorph on the target, then our Scatter Shot on it.
    G.row.control = { spell_id = 1, kind = "polymorph", breaks = true, name = "Polymorph", from = "debuff", remaining = 6 }
    step(G); step(G)
    our_cast(G, "Scatter Shot")
    assert_eq(f.majors, 2, "Scatter Shot is a major")
    assert_eq(f.overlap, 2, "held already")
    has(f.overlap_why[2], "Scatter Shot on Enemy already held by Polymorph", "why")
end }

T[#T + 1] = { "forecasts scored this fight are its accuracy (confirmed and contradicted entries); on Forever the recorder's trace gets the figures", function()
    local G = bundle({ client = { forever = true, combat_log = false } })
    fighting(G, WARRIOR)
    step(G); step(G)
    local L = G.S.predict.ledger
    L.test_pattern = { forecasts = 0, right = 0, brier = 0,
                       bands = { low = { n = 0, hits = 0 }, mid = { n = 0, hits = 0 }, high = { n = 0, hits = 0 } } }
    step(G, 0.6)
    L.test_pattern.forecasts, L.test_pattern.right, L.test_pattern.brier = 3, 2, 0.5
    step(G, 0.6)
    local found = nil
    for _, e in ipairs(H(G).entries()) do if e.kind == "forecast" then found = e end end
    assert(found, "a forecast entry")
    assert_eq(found.confirmed, 2, "two confirmed")
    assert_eq(found.contradicted, 1, "one contradicted")
    kill_target(G); step(G)
    has(H(G).lines()[1], "predictions 67% of 3", "the accuracy")
    assert_eq(#G.traces, 1, "one trace line")
    has(G.traces[1], "intel history: predictions 67% of 3", "the figures")
    L.test_pattern = nil
end }

return T

-- Jambix AIO: the kill window (PVP_INTEL_PLAN.md Stage 9, the brief's Phase
-- 10) -- modules/react/intel/killwindow.lua inside the reaction engine's
-- tick on a scripted clock, and the three that read it: the KILL_WINDOW
-- state, the burst window (modules/burst.lua) and the PvP hunter's "finish
-- the low one". The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: an immune player is no kill; we, in danger, abort;
-- a low player whose escapes and defensives are all seen down, with a shot
-- of ours ready, is a high-confidence kill; the same player never seen is a
-- burst to line up, never "high" (missing information never makes a kill
-- surer); a defensive seen ready is drawn first; one up is waited out; a
-- healer near it costs confidence and says so; the switch off reads none.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local hunter_ranges = B.hunter_ranges
local ROGUE, WARRIOR = B.ROGUE, B.WARRIOR
local PRIEST = B.PRIEST

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    G.known["Arcane Shot"] = true
    return G
end
local function fighting(G)
    G.in_combat, G.fight_age = true, 6
    G.row.in_combat, G.row.targeting_me = true, true
end
local function at(G, class, hp, dist)
    G.target.get_class = function() return class end
    G.row.dist, G.distance = dist or 20, dist or 20
    G.health[G.target.guid], G.row.hp = hp, hp
end
local function their_cast(G, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) }) end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function kill(G) return G.S.kill and G.S.kill.target or nil end

local T = {}

T[#T + 1] = { "a rogue at 20% whose Vanish, Sprint and Evasion were all seen used, a shot of ours ready: a high-confidence kill window, the state says it with its words", function()
    local G = bundle()
    at(G, ROGUE, 0.8); fighting(G)
    step(G)
    their_cast(G, "Vanish"); their_cast(G, "Sprint"); their_cast(G, "Evasion")
    step(G)
    at(G, ROGUE, 0.2); step(G)
    local k = kill(G)
    assert(k, "a verdict on the target")
    assert_eq(k.v, "HIGH_CONFIDENCE_KILL_WINDOW", "every out seen down: " .. tostring(k.why))
    assert_near(k.conf, 0.95, 0.01, "nothing stands against it")
    has(k.why, "Vanish, Sprint, Evasion down", "the reasons name the outs")
    assert_eq(k.actions[1], "Arcane Shot", "the finisher ready")
    step(G, 1.0)                                          -- past the state in force's dwell
    assert_eq(G.S.tactic.state, "KILL_WINDOW", "the state")
    has(G.S.tactic.why, "high confidence kill window", "in the verdict's words")
end }

T[#T + 1] = { "the same rogue never seen using anything: a burst to line up, never a high-confidence kill -- missing information never makes a kill surer", function()
    local G = bundle()
    at(G, ROGUE, 0.2); fighting(G)
    step(G); step(G)
    local k = kill(G)
    assert_eq(k.v, "PREPARE_BURST", "a burst to line up: " .. k.why)
    assert_near(k.conf, 0.95 - 2 * 0.18 - 0.06, 0.01, "two escapes and a defensive never seen, each at its cost")
    has(k.why, "3 of its outs never seen (counted as available)", "said")
end }

T[#T + 1] = { "a defensive seen and back is drawn first; one up is waited out; an immunity is no kill at all", function()
    local G = bundle()
    at(G, ROGUE, 0.8); fighting(G)
    step(G)
    their_cast(G, "Evasion"); step(G)
    G.clock = G.clock + 400                               -- its cooldown long run out: seen, back
    at(G, ROGUE, 0.2); step(G)
    local k = kill(G)
    assert_eq(k.v, "FORCE_DEFENSIVE", "draw its Evasion before the burst: " .. k.why)
    has(k.actions[1], "draw its Evasion", "the action")
    -- Evasion up now: wait it out.
    G.aura(G.target.guid, "Evasion", 15); step(G)
    k = kill(G)
    assert_eq(k.v, "BUILD_PRESSURE", "an avoidance up")
    has(k.actions[1], "wait out its", "the action")
    -- A paladin bubbled: nothing to take.
    local H = bundle()
    at(H, 2, 0.15); fighting(H)
    step(H)
    H.aura(H.target.guid, "Divine Shield", 8); step(H)
    k = kill(H)
    assert_eq(k.v, "NO_KILL_OPPORTUNITY", "immune")
    has(k.why, "immune", "said")
end }

T[#T + 1] = { "we are the one in danger: abort the commitment, whatever the target's health", function()
    local G = bundle()
    at(G, WARRIOR, 0.15); fighting(G)
    step(G)
    G.S.threat.level = "CRITICAL"
    G.I.kill.reset()
    G.I.kill.update(nil, G.S, G.clock + 1)
    local k = kill(G)
    assert_eq(k.v, "ABORT_COMMITMENT", "abort")
    has(k.why, "the threat CRITICAL", "why")
    assert_eq(k.actions[1], "a defensive", "survive first")
end }

T[#T + 1] = { "high health is no kill; the switch off reads none, and the state falls back to the old read", function()
    local G = bundle()
    at(G, WARRIOR, 0.9); fighting(G)
    step(G); step(G)
    assert_eq(kill(G).v, "NO_KILL_OPPORTUNITY", "at 90%")
    G.settings.intel_kill = false
    step(G); step(G)
    assert_eq(G.S.kill.target, nil, "off: no verdict")
end }

T[#T + 1] = { "the conditions read the verdict (target.kill_verdict, target.kill_conf); the bench carries them", function()
    local G = bundle()
    at(G, ROGUE, 0.8); fighting(G)
    step(G)
    their_cast(G, "Vanish"); their_cast(G, "Sprint"); their_cast(G, "Evasion")
    at(G, ROGUE, 0.2); step(G); step(G)
    local C = G.P.react.custom
    if C and C.situation_now then
        local s = C.situation_now()
        assert_eq(s.t_kill_verdict, "HIGH_CONFIDENCE_KILL_WINDOW", "copied from the fight")
        assert_eq(s.t_kill_conf, 95, "its confidence in %")
    end
end }

-- --- the burst window asks it ---------------------------------------------------------------------

T[#T + 1] = { "burst.lua: a player in a kill window opens the window at once; a defensive to draw or an abort keeps it shut; a mob is not asked", function()
    local W = { clock = 1000.0 }
    _G.core = _G.core or {}
    local verdicts = {}
    local P = {
        log = { fmt = function() end, info = function() end },
        ctx = { on = function() end, emit = function() end, cast = function() end, PRIORITY = { COOLDOWN = 80 } },
        units = { guid = function(u) return u.guid end }, combat = {},
        spellbook = { ready = function() return true end, id = function() return 1 end },
        opt = function(_, d) return d end, tune = function(_, d) return d / 100 end,
        react = { intel = { kill = { for_guid = function(g) return verdicts[g] end } } },
    }
    local burst = require("jambix_aio/modules/burst")(P)
    local class = { power = "MANA", burst = { { spell = "Rapid Fire", duration = 15 } } }
    local player = { guid = "Player-1", is_player = function() return true end }
    local s = { in_combat = true, target = player, player = {}, ttd = math.huge, power = 80, power_max = 100 }
    verdicts["Player-1"] = { v = "HIGH_CONFIDENCE_KILL_WINDOW", why = "a rogue at 20%, every out down", conf = 0.9 }
    local ok, why = burst.should_open(s, class)
    assert_eq(ok, true, "opened on the kill window, however long the fight reads")
    has(why, "kill window: a rogue at 20%", "says why")
    verdicts["Player-1"] = { v = "FORCE_DEFENSIVE", why = "Evasion ready", conf = 0.6 }
    ok, why = burst.should_open(s, class)
    assert_eq(ok, false, "kept: draw its defensive first")
    has(why, "force defensive", "says why")
    verdicts["Player-1"] = { v = "ABORT_COMMITMENT", why = "you at 20%", conf = 0.8 }
    assert_eq((burst.should_open(s, class)), false, "kept: survive first")
    local mob = { guid = "Creature-1", is_player = function() return false end }
    verdicts["Creature-1"] = { v = "HIGH_CONFIDENCE_KILL_WINDOW", why = "x", conf = 1 }
    s.target = mob
    ok, why = burst.should_open(s, class)
    assert(not tostring(why):find("kill window", 1, true), "a mob: the usual rules (" .. tostring(why) .. ")")
end }

return T

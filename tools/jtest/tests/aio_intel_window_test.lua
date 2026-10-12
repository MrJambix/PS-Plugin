-- Jambix AIO: the PvP intelligence layer on the Reactions page and in the
-- window (PVP_INTEL_PLAN.md, Stage 5 / brief Phase 13) -- the module
-- switches (intel_*), the Try-it bench's made-up picture (custom.lua's
-- bench_world), the live situation copied into the bench (situation_now),
-- and the conditions that read the picture there. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: every module has its own switch and reads calm
-- with it off; the master switch stops the layer; the bench fills a picture
-- from the situation's own fields so every intel condition can be tried
-- without a fight; "From the fight now" copies the live picture.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

local function bundle(opts)
    local G = B.bundle(opts)
    G.class.escapes = { "Wing Clip", "Feign Death" }
    G.known["Wing Clip"] = true
    G.roles = {
        defensive = { { name = "Feign Death" }, { name = "Deterrence" } },
        cc = { { name = "Freezing Trap" } }, slow = { { name = "Concussive Shot" }, { name = "Wing Clip" } },
    }
    hunter_ranges(G)
    return G
end

local function warrior(G, dist)
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = dist or 3, dist or 3
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me = true, true
end

local T = {}

T[#T + 1] = { "the module switches: each reads calm with it off; the master switch stops the layer", function()
    local G = bundle()
    warrior(G, 3)
    G.known["Aspect of the Monkey"], G.known["Deterrence"] = true, true
    G.aura(G.target.guid, "Recklessness", 10)
    G.settings.rot_hunter_auto_aspect = true
    G.hp = 0.4
    G.tick()
    assert_eq(G.S.threat.level, "HIGH", "threat on: HIGH at 40% with a burst and a stun in reach: " .. G.S.threat.score)
    assert_eq(G.S.tactic.state, "ANTI_BURST", "tactics on")
    assert_eq(G.S.pos.advice, "hold", "position on")
    assert(G.S.cds.answer ~= nil, "cooldowns on")
    assert_eq(G.I.module_on("threat"), true, "the switch reads on by default")

    G.settings.intel_threat = false
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.threat.level, "INFORMATIONAL", "threat off: calm")
    assert_eq(G.S.threat.score, 0, "no score")
    assert(G.S.tactic.state ~= "DEFENSIVE", "and the state does not read a threat that is off")

    G.settings.intel_tactics = false
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.tactic.state, "NONE", "tactics off: no state")
    assert_eq(#G.aspect_switch, 0, "no aspect switched (the rule is off)")

    G.settings.intel_position = false
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.pos.advice, "none", "position off: no advice")

    G.settings.intel_cooldowns = false
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.cds.answer, nil, "cooldowns off: no answer")
    assert_eq(G.I.cooldowns.enabled(), false, "and the rules' hooks stand down")
    assert_eq(G.I.cooldowns.hold_answer(G.React.world.W, { target_kind = "self", b = { st = { burst = "physical" } } }), nil, "no hold")

    G.settings.intel_enabled = false
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.S.off, true, "the master switch: off")
    assert_eq(#G.I.lines(), 1, "one row: off")
end }

T[#T + 1] = { "the kill and team switches gate their states", function()
    local G = bundle()
    G.target.get_class = function() return 2 end
    G.row.dist, G.distance = 20, 20
    G.in_combat, G.fight_age = true, 10
    G.row.in_combat, G.row.targeting_me = true, true
    G.health[G.target.guid], G.row.hp = 0.2, 0.2
    G.tick()
    assert_eq(G.S.tactic.state, "KILL_WINDOW", "a kill window")
    G.settings.intel_kill = false
    G.clock = G.clock + 1
    G.tick()
    assert(G.S.tactic.state ~= "KILL_WINDOW", "not with the switch off: " .. G.S.tactic.state)
    -- The healer targeted, team awareness off: pressure, not protection.
    local healer = unit(G, "Player-1-00000011", { name = "Heals", player = true, hostile = false })
    G.group.in_group, G.members, G.healer = true, { healer }, healer
    G.row.targeting_me, G.row.target_guid = false, healer.guid
    G.health[G.target.guid], G.row.hp = 0.8, 0.8
    G.clock = G.clock + 1
    G.tick()
    assert_eq(G.S.tactic.state, "PROTECT_ALLY", "protect the healer with team awareness on")
    G.settings.intel_team = false
    G.clock = G.clock + 1
    G.tick()
    assert(G.S.tactic.state ~= "PROTECT_ALLY" and G.S.tactic.state ~= "PEEL_ENEMY", "off: " .. G.S.tactic.state)
end }

T[#T + 1] = { "the bench: the preset's made-up picture answers every intel condition without a fight", function()
    local G = bundle()
    warrior(G, 3)
    G.known["Arcane Shot"] = true
    G.tick()
    local C = G.React.custom
    local preset = nil
    for _, p in ipairs(C.D.BENCH_PRESETS) do if p.key == "pvp_intel" then preset = p end end
    assert(preset ~= nil, "the preset exists")
    local s = {}
    for k, v in pairs(preset.s) do s[k] = v end
    local r = { name = "Bench", importance = "defensive", combat_only = false,
        conds = {
            { mode = "gui", key = "f_threat", op = "is", value = "HIGH" },
            { mode = "gui", key = "f_threat_score", op = ">=", value = 50 },
            { mode = "gui", key = "f_tactic", op = "is", value = "ANTI_BURST" },
            { mode = "gui", key = "f_advice", op = "is", value = "hold" },
            { mode = "gui", key = "t_mobility", op = "is" },
            { mode = "gui", key = "t_defensive", op = "not" },
            { mode = "gui", key = "t_cd_seen", op = "is", value = "Recklessness" },
            { mode = "gui", key = "t_cd_ready_in", op = ">=", value = "Recklessness", num = 1000 },
            { mode = "gui", key = "me_protected", op = "not" },
            { mode = "gui", key = "me_dead_zone", op = "is" },
            { mode = "gui", key = "me_safe_escape", op = "not" },
            { mode = "gui", key = "pet_breaks_cc", op = "not" },
            { mode = "gui", key = "f_kill_window", op = "not" },
            { mode = "gui", key = "f_incoming_cast", op = "not" },
            -- Stage 6: the control plan's three.
            { mode = "gui", key = "t_cc_value", op = "is", value = "none" },
            { mode = "gui", key = "t_dr_next", op = "is", value = "full" },
            { mode = "gui", key = "t_cc_ours", op = "not" },
            -- Stage 7: the predictor's two, and its function.
            { mode = "gui", key = "t_pattern", op = "is", value = "none" },
            { mode = "gui", key = "t_pattern_conf", op = "<", value = 60 },
            { mode = "gui", key = "t_pattern_rel", op = "<", value = 60 },
            -- Stage 8: the bait.
            { mode = "gui", key = "f_bait", op = "is", value = "none" },
            { mode = "lua", code = 'enemy_cd_seen("Intercept") and not enemy_cd_seen("Sprint") and enemy_cd_ready_in("Sprint") == 999 and prediction_confidence("mobility_when_slowed") == 0' },
        },
        actions = { { mode = "gui", kind = "spell", spell = "Arcane Shot", target = "target" } } }
    -- A saved reaction's rows carry uids (normalise); a draft built here gets them by hand.
    for i, c in ipairs(r.conds) do c.uid = i end
    r.actions[1].uid = 1
    local res = C.bench(r, s)
    for i, cond in ipairs(res.conds) do
        assert(cond.ok == true, string.format("condition %d holds on the bench: %s (%s)", i, tostring(cond.note or cond.shown), tostring(cond.err)))
    end
    assert_eq(res.pass, true, "every condition holds")
    -- Flip a few fields: the picture follows.
    s.pvp_threat, s.me_protected, s.t_cd_seen, s.pet_breaks_cc = "LOW", true, "", true
    res = C.bench(r, s)
    assert_eq(res.conds[1].ok, false, "threat LOW is not HIGH")
    assert_eq(res.conds[9].ok, false, "protected now")
    assert_eq(res.conds[7].ok, false, "Recklessness not seen")
    assert_eq(res.conds[12].ok, false, "the pet breaks the control")
    assert_eq(res.pass, false, "and the reaction would not go")
end }

T[#T + 1] = { "'From the fight now' copies the live picture into the bench", function()
    local G = bundle()
    warrior(G, 3)
    G.known["Freezing Trap"] = true
    G.aura(G.target.guid, "Recklessness", 10)
    G.by_guid["nameplate2"] = G.target
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate2", "Cast-x", G.id_of("Charge") })
    G.tick()
    local C = G.React.custom
    local now = C.situation_now()
    assert(now ~= nil, "a live situation")
    assert_eq(now.pvp_threat, G.S.threat.level, "the threat level copied: " .. tostring(now.pvp_threat))
    assert_eq(now.pvp_tactic, "ANTI_BURST", "the state copied")
    assert_eq(now.pvp_advice, G.S.pos.advice, "the move copied")
    assert_eq(now.t_mobility, true, "Charge seen: mobility")
    has(now.t_cd_seen, "Charge", "the ledger's names")
    assert_eq(now.me_dead_zone, true, "in melee: the dead zone")
    assert_eq(now.me_safe_escape, false, "unslowed in melee: no safe escape")
    -- And the bench reads that copy the same way the conditions read the fight.
    local r = { name = "Copied", importance = "defensive", combat_only = false,
        conds = { { mode = "gui", key = "f_tactic", op = "is", value = "ANTI_BURST", uid = 1 },
                  { mode = "gui", key = "t_mobility", op = "is", uid = 2 } },
        actions = { { mode = "gui", kind = "spell", spell = "Wing Clip", target = "target", uid = 1 } } }
    local res = C.bench(r, now)
    assert_eq(res.pass, true, "the copied picture passes the same conditions")
end }

T[#T + 1] = { "the new conditions compile and read live: a kill window, the control's time left, the pet on a held player", function()
    local G = bundle()
    warrior(G, 3)
    G.tick()
    local C = G.React.custom
    assert_eq(C.cond_code({ mode = "gui", key = "f_kill_window", op = "is" }), "fight.kill_window", "the kill row")
    assert_eq(C.cond_code({ mode = "gui", key = "t_cc_left", op = "<=", value = 2 }), "target.cc_left <= 2", "the control row")
    assert_eq(C.cond_code({ mode = "gui", key = "pet_breaks_cc", op = "is" }), "pet.breaks_cc", "the pet row")
    G.pet_alive, G.pet_on = true, G.target
    G.row.control = { kind = "incapacitate", breaks = true, name = "Freezing Trap Effect", remaining = 1.5, from = "debuff" }
    G.tick()
    local id = C.save({ name = "Breaking", importance = "defensive",
        conds = { { mode = "lua", code = "pet.breaks_cc and target.cc_left <= 2 and target.cc_left > 0" } },
        actions = { { mode = "gui", kind = "spell", spell = "Wing Clip", target = "target" } } })
    assert(id ~= nil, "saved")
    G.run(0.3)
    local rt = C.runtime(id)
    assert(rt and rt.conds[1].ok == true, "the pet on a held player with 1.5 s left: " .. tostring(rt and rt.conds[1].shown))
end }

return T

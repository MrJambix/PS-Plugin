-- Jambix AIO: the PvP tactical states, the move advice and the words
-- (PVP_INTEL_PLAN.md, Stage 4 / brief Phases 3, 9, 11, 15) --
-- modules/react/intel/states.lua, position.lua, explain.lua and the first
-- intel reaction (rules/intel.lua), inside the reaction engine's tick on a
-- scripted clock. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: every state the brief names turns on from the
-- observations that mean it, with its actions, what to avoid and what to
-- keep; an emergency takes over at once, anything else waits for the dwell;
-- the move advice is directional and says why, holds while a melee player
-- is unslowed, steps out once it is, keeps out of a warrior's Intercept band
-- unless the ledger says Intercept is down, and never moves the character;
-- the aspect goes only through the Aspects window's own switch; the alerts
-- say the state once; the window's conditions read it all.

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
        cc = { { name = "Freezing Trap" } }, disorient = { { name = "Scatter Shot" } },
        slow = { { name = "Concussive Shot" }, { name = "Wing Clip" } },
    }
    hunter_ranges(G)
    return G
end

local rogue = B.rogue

local function warrior(G, dist)
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = dist or 3, dist or 3
end

local function fighting(G, age)
    G.in_combat, G.fight_age = true, age or 2
    G.row.in_combat, G.row.targeting_me = true, true
end

local function tactic(G) return G.S.tactic end
local function pos(G) return G.S.pos end
local function has_action(G, piece)
    for _, a in ipairs(tactic(G).actions) do if a:find(piece, 1, true) then return true end end
    return false
end
local function has_avoid(G, piece)
    for _, a in ipairs(tactic(G).avoid) do if a:find(piece, 1, true) then return true end end
    return false
end

local T = {}

T[#T + 1] = { "no PvP: no state, no move, two readout rows", function()
    local G = bundle()
    G.rows, G.row, G.target_present = {}, nil, false
    G.tick()
    assert_eq(tactic(G).state, "NONE", "no state")
    assert_eq(pos(G).advice, "none", "no move")
    assert_eq(#G.I.lines(), 1, "the off line only")
end }

T[#T + 1] = { "PREPARATION: a player near, none on you, out of combat", function()
    local G = bundle()
    rogue(G)
    G.in_combat = false
    G.row.targeting_me, G.row.in_combat, G.row.dist, G.distance = false, false, 25, 25
    G.tick()
    assert_eq(tactic(G).state, "PREPARATION", "preparation")
    has(tactic(G).why, "1 enemy player(s) near, none on you", "why")
    assert(has_action(G, "Hunter's Mark"), "the mark")
    has(G.I.lines()[3], "state PREPARATION", "the third row")
end }

T[#T + 1] = { "OPENING for the first six seconds at range, then SUSTAINED_PRESSURE at once", function()
    local G = bundle()
    rogue(G)
    G.row.dist, G.distance = 20, 20
    fighting(G, 2)
    G.tick()
    assert_eq(tactic(G).state, "OPENING", "the opening")
    assert(has_action(G, "Aimed Shot"), "the opener")
    assert_near(tactic(G).conf, 0.9, 0.01, "sure")
    G.fight_age = 8
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(tactic(G).state, "SUSTAINED_PRESSURE", "the opening is over: no dwell when the state no longer holds")
    assert(has_avoid(G, "Multi-Shot on one"), "the user's rule, as advice")
    assert_eq(pos(G).advice, "hold", "nothing to change at 20 yd from a rogue")
end }

T[#T + 1] = { "CONTROL_DISTANCE: a warrior in melee, unslowed: clip first, hold your ground; slowed: step out past the dead zone", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 5)
    G.tick()
    assert_eq(tactic(G).state, "CONTROL_DISTANCE", "control the distance")
    has(tactic(G).why, "Enemy in melee, not slowed", "why")
    assert_eq(tactic(G).actions[1], "Wing Clip", "clip first")
    assert(has_avoid(G, "Aimed Shot in melee"), "no standing cast in melee")
    local P_ = pos(G)
    assert_eq(P_.advice, "hold", "running gains nothing")
    has(P_.why, "not slowed: running gains nothing, slow it first", "and says so")
    assert_eq(P_.zone, "melee", "the band")
    -- Slowed: step out.
    G.aura(G.target.guid, "Wing Clip", 8, { caster = G.player })
    G.clock = G.clock + 0.1
    G.tick()
    P_ = pos(G)
    assert_eq(P_.advice, "increase", "step out")
    assert_eq(P_.direction, "away from Enemy", "the direction in words")
    assert_eq(P_.yards, 9, "past the dead zone")
    has(P_.why, "slowed: step out past 9 yd", "why")
    has(G.I.lines()[3], "move: increase (away from Enemy) past 9 yd", "the readout")
    -- Inside Auto Shot's aim window the move waits for the shot.
    G.P.weave = { next_shot_in = function() return 0.3 end }
    G.React.memory.on_sent(G.id_of("Auto Shot"), G.target.guid, "test")
    G.React.memory.on_success(G.id_of("Auto Shot"))
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(pos(G).wait_for_shot, true, "after the shot")
    has(pos(G).why, "(after the shot, 0.3s)", "said")
end }

T[#T + 1] = { "the aspect for the moment goes only through the Aspects window's switch", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 5)
    G.known["Aspect of the Monkey"], G.known["Aspect of the Hawk"] = true, true
    G.aura("player", "Aspect of the Hawk", nil)
    G.run(0.5)
    assert_eq(pos(G).aspect, "Aspect of the Monkey", "Monkey is the aspect for a melee player on you")
    assert_eq(#G.aspect_switch, 0, "nothing switched with Auto swap aspects off")
    G.settings.rot_hunter_auto_aspect = true
    G.run(0.5)
    assert(#G.aspect_switch >= 1 and G.aspect_switch[1] == "Aspect of the Monkey", "switched with it on: " .. tostring(G.aspect_switch[1]))
    -- Nobody in melee: back to Hawk.
    G.auras["player"] = nil
    G.aura("player", "Aspect of the Monkey", nil)
    G.row.dist, G.distance = 20, 20
    G.clock = G.clock + 3
    G.run(0.5)
    assert_eq(pos(G).aspect, "Aspect of the Hawk", "back to shooting")
end }

T[#T + 1] = { "a warrior at range: keep out of Intercept's 8-25 yd band; once Intercept is seen down, hold and shoot", function()
    local G = bundle()
    warrior(G, 15)
    fighting(G, 8)
    G.tick()
    local P_ = pos(G)
    assert_eq(P_.advice, "increase", "out of the band")
    assert_eq(P_.yards, 26, "past 25")
    has(P_.why, "Intercept reaches 8-25 yd on Enemy", "why, from the client's own table (Charge cannot be used in combat)")
    assert_near(P_.conf, 0.8, 0.01, "its role at 0.9, capped at 0.8 with no sight ray read")
    assert_eq(tactic(G).state, "SUSTAINED_PRESSURE", "and the state is pressure")
    -- At 30 yd: outside the band, nothing to change.
    G.row.dist, G.distance = 30, 30
    G.tick()
    assert_eq(pos(G).advice, "hold", "outside the band")
    -- Intercept used: the ledger says down, the advice says shoot.
    G.row.dist, G.distance = 15, 15
    G.by_guid["nameplate2"] = G.target
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate2", "Cast-x", G.id_of("Intercept") })
    G.clock = G.clock + 0.1
    G.tick()
    P_ = pos(G)
    assert_eq(P_.advice, "hold", "Intercept down: hold")
    has(P_.why, "Intercept down for 30s: shoot", "why")
end }

T[#T + 1] = { "ANTI_BURST takes over at once and names the economy's answer; DEFENSIVE at HIGH; DISENGAGE with nothing left", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 8)
    G.known["Freezing Trap"], G.known["Deterrence"] = true, true
    G.tick()
    assert_eq(tactic(G).state, "CONTROL_DISTANCE", "before the burst")
    G.aura(G.target.guid, "Recklessness", 10)
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(tactic(G).state, "ANTI_BURST", "at once, no dwell for an emergency")
    assert_eq(tactic(G).emergency, true, "an emergency")
    assert_eq(tactic(G).actions[1], "Freezing Trap", "the cheapest answer")
    G.aura("player", "Deterrence", 8)
    G.clock = G.clock + 0.1
    G.tick()
    has(tactic(G).actions[1], "keep your defensives", "covered: preserve")
    -- Three rogues on you at 40%, with a defensive in the book: DEFENSIVE.
    local H = bundle()
    rogue(H)
    fighting(H, 8)
    H.known["Freezing Trap"], H.known["Deterrence"] = true, true
    local second = unit(H, "Player-1-00000002", { name = "Second", player = true })
    local third = unit(H, "Player-1-00000003", { name = "Third", player = true })
    second.get_class = function() return ROGUE end
    third.get_class = function() return ROGUE end
    H.rows = { H.row, H.row_for(second, { dist = 4 }), H.row_for(third, { dist = 4 }) }
    H.hp = 0.4
    H.tick()
    assert_eq(tactic(H).state, "DEFENSIVE", "defensive: " .. H.S.threat.level)
    assert(has_action(H, "Freezing Trap"), "the cheapest answer")
    -- Nothing left at 20%: DISENGAGE.
    H.known["Freezing Trap"], H.known["Deterrence"] = nil, nil
    H.hp = 0.2
    H.clock = H.clock + 0.1
    H.tick()
    assert_eq(H.S.threat.level, "CRITICAL", "critical")
    assert_eq(tactic(H).state, "DISENGAGE", "disengage")
    has(tactic(H).why, "CRITICAL threat with no defensive ready", "why")
end }

T[#T + 1] = { "RESET_FIGHT with a player in your trap, CROWD_CONTROL_SETUP with one in your Scatter: no damage on it", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 8)
    G.aura(G.target.guid, "Freezing Trap Effect", 10)
    G.tick()
    assert_eq(tactic(G).state, "RESET_FIGHT", "a reset")
    has(tactic(G).why, "frozen for 10.0s: walk to the opener's distance", "why")
    assert(has_action(G, "walk to 25 yd"), "the walk")
    assert(has_avoid(G, "any damage"), "nothing on it")
    G.auras[G.target.guid] = nil
    G.aura(G.target.guid, "Scatter Shot", 3)
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(tactic(G).state, "CROWD_CONTROL_SETUP", "a setup")
    assert(has_avoid(G, "Serpent Sting"), "no sting on it")
    assert_eq(pos(G).advice, "increase", "and step out while it is held")
end }

T[#T + 1] = { "PROTECT_ALLY when the healer is targeted, PEEL_ENEMY for a melee on anyone else; OBJECTIVE_CONTROL with the flag", function()
    local G = bundle()
    warrior(G, 20)
    fighting(G, 8)
    local healer = unit(G, "Player-1-00000011", { name = "Heals", player = true, hostile = false })
    local dps = unit(G, "Player-1-00000012", { name = "Dps", player = true, hostile = false })
    G.group.in_group = true
    G.members, G.healer = { healer, dps }, healer
    G.row.targeting_me, G.row.target_guid = false, healer.guid
    G.tick()
    assert_eq(tactic(G).state, "PROTECT_ALLY", "protect the healer")
    has(tactic(G).why, "Enemy on Heals (the healer)", "why")
    assert(has_action(G, "Concussive Shot"), "slow it")
    G.row.target_guid = dps.guid
    G.clock = G.clock + 1
    G.tick()
    assert_eq(tactic(G).state, "PEEL_ENEMY", "peel the melee off the dps")
    -- The flag.
    G.instance = "pvp"
    G.aura("player", "Warsong Flag", nil)
    G.clock = G.clock + 1.1
    G.tick()
    assert_eq(tactic(G).state, "OBJECTIVE_CONTROL", "the objective")
    has(tactic(G).actions[1], "run with it", "run")
end }

T[#T + 1] = { "KILL_WINDOW at 20% without an immunity, as sure as the kill window's verdict (a paladin's outs never seen: a burst to line up); not with Divine Shield up; COUNTER_ATTACK once a burst has ended", function()
    local G = bundle()
    G.target.get_class = function() return 2 end        -- a paladin
    G.known["Arcane Shot"] = true                       -- something of ours to finish it with
    G.row.dist, G.distance = 20, 20
    fighting(G, 10)
    G.health[G.target.guid] = 0.2
    G.row.hp = 0.2
    G.tick()
    assert_eq(tactic(G).state, "KILL_WINDOW", "a kill window")
    assert_near(tactic(G).conf, 0.33, 0.01, "its five outs never seen and its own heals cost the confidence")
    has(tactic(G).why, "prepare burst", "the verdict's words")
    has(tactic(G).why, "never seen (counted as available)", "and what it rests on")
    G.aura(G.target.guid, "Divine Shield", 8)
    G.clock = G.clock + 1
    G.tick()
    assert(tactic(G).state ~= "KILL_WINDOW", "not through a bubble: " .. tactic(G).state)
    -- A warrior whose Recklessness ended: counter-attack.
    local H = bundle()
    warrior(H, 20)
    fighting(H, 20)
    H.tick()
    H.by_guid["nameplate2"] = H.target
    H.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate2", "Cast-x", H.id_of("Recklessness") })
    H.clock = H.clock + 18                               -- Recklessness lasts 15 s on Era
    H.tick()
    assert_eq(tactic(H).state, "COUNTER_ATTACK", "its burst is spent: press")
    has(tactic(H).why, "Recklessness ended", "why")
end }

T[#T + 1] = { "the dwell: a higher state waits 0.8 s while the current one still holds; an emergency does not", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 8)
    G.known["Scatter Shot"] = true
    G.tick()
    assert_eq(tactic(G).state, "CONTROL_DISTANCE", "control")
    -- A priest casts Mind Blast at you (a bolt, not a sheep: the threat
    -- stays MODERATE): INTERRUPT_OPPORTUNITY (85) over CONTROL_DISTANCE (80).
    local priest = unit(G, "Player-1-00000005", { name = "Priestly", player = true })
    priest.get_class = function() return PRIEST end
    G.rows[#G.rows + 1] = G.row_for(priest, { dist = 25, casting = G.casting("Mind Blast", 1.5, 1.5) })
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(G.S.threat.incoming_cast, true, "the cast is coming")
    assert(G.S.threat.level ~= "HIGH" and G.S.threat.level ~= "CRITICAL", "not an emergency: " .. G.S.threat.level)
    assert_eq(tactic(G).state, "CONTROL_DISTANCE", "held inside the dwell")
    assert_eq(tactic(G).candidates[1].name, "INTERRUPT_OPPORTUNITY", "but it is the top candidate")
    G.rows[2].casting = G.casting("Mind Blast", 1.0, 1.5)
    G.clock = G.clock + 0.6
    G.tick()
    assert_eq(tactic(G).state, "INTERRUPT_OPPORTUNITY", "after the dwell")
    assert_eq(tactic(G).actions[1], "Scatter Shot", "the stopper")
end }

T[#T + 1] = { "RESOURCE_RECOVERY out of combat, low; the explain summary and the alerts", function()
    local G = bundle()
    rogue(G)
    G.in_combat = false
    G.row.targeting_me, G.row.in_combat, G.row.dist, G.distance = false, false, 30, 30
    G.power = 30
    G.tick()
    assert_eq(tactic(G).state, "RESOURCE_RECOVERY", "recover")
    local sum = G.I.summary()
    assert_eq(sum.state, "RESOURCE_RECOVERY", "the summary's state")
    assert_eq(sum.threat, "INFORMATIONAL", "the threat")
    has(sum.action, "drink", "the action")
    assert_eq(sum.move, "hold", "the move")
    assert(#sum.unknown == 0, "nothing unknown on Era")
    -- One alert for the state, keyed, and none with the switch off.
    assert(#G.said >= 1, "an alert")
    assert_eq(G.said[1].key, "intel_state", "keyed")
    assert_eq(G.said[1].title, "resource recovery", "the state in words")
    local n = #G.said
    G.run(1.0)
    assert_eq(#G.said, n, "said once")
    local H = bundle()
    H.settings.intel_alerts = false
    rogue(H)
    fighting(H, 8)
    H.run(0.5)
    assert_eq(#H.said, 0, "nothing said with alerts off")
end }

T[#T + 1] = { "the window's conditions: the state, the move, the dead zone, a safe escape", function()
    local G = bundle()
    warrior(G, 3)
    fighting(G, 8)
    G.known["Arcane Shot"] = true
    G.tick()
    local Cm = G.React.custom
    assert_eq(Cm.cond_code({ mode = "gui", key = "f_tactic", op = "is", value = "CONTROL_DISTANCE" }), 'fight.tactic == "CONTROL_DISTANCE"', "the state row")
    assert_eq(Cm.cond_code({ mode = "gui", key = "f_advice", op = "is", value = "increase" }), 'fight.advice == "increase"', "the move row")
    assert_eq(Cm.cond_code({ mode = "gui", key = "me_dead_zone", op = "is" }), "me.dead_zone", "the dead zone row")
    assert_eq(Cm.cond_code({ mode = "gui", key = "me_safe_escape", op = "not" }), "not me.safe_escape", "the escape row")
    assert_eq(Cm.choices("tactics")[1], "DISENGAGE", "the states offered")
    local id = Cm.save({ name = "Stuck", importance = "defensive",
        conds = { { mode = "lua", code = 'fight.tactic == "CONTROL_DISTANCE" and me.dead_zone and not me.safe_escape' } },
        actions = { { mode = "gui", kind = "spell", spell = "Arcane Shot", target = "target" } } })
    assert(id ~= nil, "saved")
    G.run(0.5)
    local rt = Cm.runtime(id)
    assert(rt and rt.conds[1].ok == true, "in melee, unslowed: stuck reads true: " .. tostring(rt and rt.conds[1].shown))
    -- Slowed: a safe escape, and the move says increase.
    G.aura(G.target.guid, "Wing Clip", 8, { caster = G.player })
    G.run(0.3)
    rt = Cm.runtime(id)
    assert(rt.conds[1].ok == false, "slowed: no longer stuck")
    assert_eq(Cm.cond_code({ mode = "gui", key = "me_safe_escape", op = "is" }), "me.safe_escape", "the escape row reads")
end }

return T

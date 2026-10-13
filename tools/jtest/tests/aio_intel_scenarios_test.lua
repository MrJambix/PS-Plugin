-- Jambix AIO: the PvP intelligence layer against the brief's scenarios
-- (PVP_INTEL_PLAN.md Stage 11-b, the brief's Phase 16 test bench) -- one
-- scenario per item the brief lists, each inside the reaction engine's tick
-- on a scripted clock (tools/jtest/mock/intel_bundle.lua).
--
-- Each scenario says, in its own table: the initial state (setup), what
-- happens (events), the state it expects, the recommendations it expects
-- and the ones it forbids, the words of the explanation, and the fallback
-- -- what the layer does when the data the read rests on is missing. The
-- per-module suites test each piece in depth; this one holds the whole
-- layer to the brief's list, so a change that breaks a scenario's outcome
-- is seen here whichever module it came from.
--
-- The same scenarios are the in-game bench's presets
-- (custom_data.BENCH_PRESETS, keys "scn_..."): the last test checks each
-- preset is there and its situation reads as the scenario says.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR
local MAGE, WARLOCK, PALADIN = 8, 9, 2

local function bundle(opts)
    local G = B.bundle(opts)
    G.class.escapes = { "Wing Clip", "Feign Death" }
    G.known["Wing Clip"], G.known["Arcane Shot"] = true, true
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
local function as(G, class, dist, hp)
    G.target.get_class = function() return class end
    G.row.dist, G.distance = dist or 3, dist or 3
    if hp then G.row.hp, G.health[G.target.guid] = hp, hp end
end
local function fighting(G, age)
    G.in_combat, G.fight_age = true, age or 8
    G.row.in_combat, G.row.targeting_me = true, true
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function settle(G) step(G) step(G, 1.0) step(G) end      -- past the state in force's dwell
local function their_cast(G, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) }) end
local function another(G, n, class, fields)
    local u = unit(G, string.format("Player-1-0000030%d", n), { name = fields.name or ("Foe" .. n), player = true })
    u.get_class = function() return class end
    local r = G.row_for(u, fields.row or {})
    G.rows[#G.rows + 1] = r
    G.health[u.guid] = r.hp
    return u, r
end

local function list_has(list, piece)
    for _, a in ipairs(list or {}) do if tostring(a):find(piece, 1, true) then return true end end
    return false
end

--- The scenario's expectations against the picture as it stands.
local function expect(G, e, label)
    local X = G.S.tactic
    local where = label .. ": state " .. tostring(X.state) .. " (" .. tostring(X.why) .. "), actions {" .. table.concat(X.actions or {}, "; ") .. "}"
    if e.state then
        local ok = false
        for _, s in ipairs(type(e.state) == "table" and e.state or { e.state }) do if X.state == s then ok = true end end
        assert(ok, where .. " -- expected " .. (type(e.state) == "table" and table.concat(e.state, " or ") or e.state))
    end
    if e.not_state then
        for _, s in ipairs(e.not_state) do assert(X.state ~= s, where .. " -- never " .. s) end
    end
    for _, a in ipairs(e.actions or {}) do assert(list_has(X.actions, a), where .. " -- expected the action " .. a) end
    for _, a in ipairs(e.forbid or {}) do assert(not list_has(X.actions, a), where .. " -- forbidden: " .. a) end
    for _, a in ipairs(e.avoid or {}) do assert(list_has(X.avoid, a), where .. " -- expected to avoid " .. a) end
    if e.why then has(X.why or "", e.why, where .. " -- the explanation") end
end

local T = {}
local function scenario(name, s) T[#T + 1] = { "scenario: " .. name, s } end

-- 1 ----------------------------------------------------------------------------------------
scenario("a warrior's gap closer: Intercept seen, then the warrior in melee, unslowed: the clip first, never Aimed Shot in melee; fallback without the clip trained: still step out", function()
    local G = bundle()
    as(G, WARRIOR, 15); fighting(G)
    step(G)
    their_cast(G, "Intercept")
    as(G, WARRIOR, 3); settle(G)
    expect(G, { state = "CONTROL_DISTANCE", actions = { "Wing Clip", "step out past the dead zone" }, avoid = { "Aimed Shot in melee" },
                why = "in melee, not slowed" }, "in melee")
    local cd = G.I.cooldowns.seen(G.S, G.target.guid, "Intercept")
    assert_eq(cd and cd.state, "down", "the gap closer on the ledger")
    -- Fallback: the clip not trained.
    G.known["Wing Clip"] = nil
    step(G)
    expect(G, { state = "CONTROL_DISTANCE", actions = { "step out past the dead zone" } }, "no clip")
end)

-- 2 ----------------------------------------------------------------------------------------
scenario("a warrior with mobility still available: at 15 yd, Intercept never seen: keep out of its band; once seen down: hold and shoot", function()
    local G = bundle()
    as(G, WARRIOR, 15); fighting(G)
    settle(G)
    assert_eq(G.S.pos.advice, "increase", "out of the band")
    has(G.S.pos.why, "Intercept reaches 8-25 yd", "why")
    expect(G, { state = "SUSTAINED_PRESSURE", forbid = { "Multi-Shot on one" } }, "at range")
    their_cast(G, "Intercept")
    step(G)
    assert_eq(G.S.pos.advice, "hold", "Intercept down")
    has(G.S.pos.why, "Intercept down", "why")
end)

-- 3 ----------------------------------------------------------------------------------------
scenario("a rogue's opener: Cheap Shot on you, the rogue in melee: held by a player, said; DEFENSIVE asks for no cast (no clip, no Aimed Shot)", function()
    local G = bundle()
    as(G, ROGUE, 3); fighting(G, 1)
    G.aura("player", "Cheap Shot", 4.0, { caster = G.target })
    their_cast(G, "Cheap Shot")
    settle(G)
    local me = G.S.me
    assert(me.control, "controlled")
    assert_eq(me.control.from_player, true, "by a player")
    has(G.I.lines()[1], "you: stun", "said")
    expect(G, { state = "DEFENSIVE", why = "you are held: stun", actions = { "the break-control reaction decides" }, forbid = { "Aimed Shot", "Wing Clip" } }, "stunned by a rogue")
end)

-- 4 ----------------------------------------------------------------------------------------
scenario("a rogue's reset: it vanishes beside you: an opener you cannot see is counted and the unknown named; no kill window on nobody", function()
    local G = bundle()
    as(G, ROGUE, 3); fighting(G)
    settle(G)
    G.rows, G.row = {}, nil
    G.target_present = false
    step(G)
    has(G.S.why or "", "a player vanished beside you", "still a PvP fight")
    has(table.concat(G.S.threat.unknown or {}, " / "), "where the vanished player is", "the unknown named")
    expect(G, { not_state = { "KILL_WINDOW", "SUSTAINED_PRESSURE" } }, "vanished")
end)

-- 5 ----------------------------------------------------------------------------------------
scenario("a mage's Blink: seen, it goes on the ledger as down; the target's mobility condition reads it; its escape counts as spent in the kill window", function()
    local G = bundle()
    as(G, MAGE, 20); fighting(G)
    step(G)
    their_cast(G, "Blink")
    step(G)
    local cd = G.I.cooldowns.seen(G.S, G.target.guid, "Blink")
    assert_eq(cd and cd.state, "down", "Blink down")
    assert_eq(G.P.react.custom.situation_now().t_mobility, true, "target.mobility")
    as(G, MAGE, 20, 0.2); step(G); step(G)
    local k = G.S.kill.target
    has(k.why, "Blink", "the kill window names it")
end)

-- 6 ----------------------------------------------------------------------------------------
scenario("a mage controlling the hunter: Polymorph on you: held, by a player, said; DEFENSIVE never asks for a cast you cannot make", function()
    local G = bundle()
    as(G, MAGE, 20); fighting(G)
    step(G)
    G.aura("player", "Polymorph", 8.0, { caster = G.target })
    settle(G)
    local me = G.S.me
    assert(me.control, "controlled")
    has(G.I.lines()[1], "Polymorph", "said with its name")
    expect(G, { state = "DEFENSIVE", why = "Polymorph", forbid = { "Aimed Shot" } }, "polymorphed")
end)

-- 7 ----------------------------------------------------------------------------------------
scenario("a warlock's dangerous cast: Fear at you, Scatter Shot in reach: stop it; fallback with no stopper ready: no interrupt state", function()
    local G = bundle()
    G.known["Scatter Shot"] = true
    as(G, WARLOCK, 12); fighting(G)
    G.row.casting = G.casting("Fear", 1.4, 1.5)
    step(G)
    assert_eq(G.S.threat.incoming_cast, true, "the cast at you")
    G.row.casting = G.casting("Fear", 1.4, 1.5)
    step(G)
    expect(G, { state = "INTERRUPT_OPPORTUNITY", actions = { "Scatter Shot" }, why = "a dangerous cast at you and Scatter Shot ready" }, "Fear")
    -- Fallback: nothing ready to stop it.
    local H = bundle()
    as(H, WARLOCK, 12); fighting(H)
    H.row.casting = H.casting("Fear", 1.4, 1.5)
    step(H)
    H.row.casting = H.casting("Fear", 1.4, 1.5)
    step(H)
    expect(H, { not_state = { "INTERRUPT_OPPORTUNITY" } }, "no stopper")
end)

-- 8 ----------------------------------------------------------------------------------------
scenario("a healer under pressure: a warrior on our healer: protect it, with the tool of ours that reaches; the explanation names both", function()
    local G = bundle()
    G.known["Concussive Shot"] = true
    as(G, WARRIOR, 20); fighting(G)
    local healer = unit(G, "Player-1-00000041", { name = "Heals", player = true, hostile = false })
    G.group.in_group = true
    G.members, G.healer = { healer }, healer
    G.row.targeting_me, G.row.target_guid = false, healer.guid
    settle(G)
    expect(G, { state = "PROTECT_ALLY", actions = { "Concussive Shot on Enemy" }, why = "Enemy on Heals (the healer): Concussive Shot" }, "the healer")
end)

-- 9 ----------------------------------------------------------------------------------------
scenario("the dead zone: a warrior at 6 yd: inside the minimum range, said; the move is out; no Aimed Shot", function()
    local G = bundle()
    as(G, WARRIOR, 6); fighting(G)
    settle(G)
    assert_eq(G.S.env.target.zone, "dead_zone", "the band")
    assert_eq(G.P.react.custom.situation_now().me_dead_zone, true, "me.dead_zone")
    expect(G, { forbid = { "Aimed Shot" } }, "dead zone")
end)

-- 10 ---------------------------------------------------------------------------------------
scenario("the pet about to break control: our trap on the player, the pet on it: recall the pet, reset the fight, no damage on it", function()
    local G = bundle()
    as(G, WARRIOR, 3); fighting(G)
    G.pet_alive, G.pet_on = true, G.target
    G.row.control = { spell_id = 1, kind = "incapacitate", breaks = true, name = "Freezing Trap Effect", from = "debuff", remaining = 8 }
    G.aura(G.target.guid, "Freezing Trap Effect", 8, { caster = G.player })
    settle(G)
    assert_eq(G.S.cc.pet.recall, true, "the pet called back")
    expect(G, { state = "RESET_FIGHT", avoid = { "any damage on it" }, forbid = { "Arcane Shot", "Serpent Sting" } }, "trapped")
end)

-- 11 ---------------------------------------------------------------------------------------
scenario("several enemies at once: three rogues on you at 40%: defend, cheapest first; you are the focus; outnumbered: disengage advised", function()
    local G = bundle()
    G.known["Freezing Trap"], G.known["Deterrence"] = true, true
    as(G, ROGUE, 3); fighting(G)
    another(G, 2, ROGUE, { row = { dist = 4 } })
    another(G, 3, ROGUE, { row = { dist = 4 } })
    G.hp = 0.4
    settle(G)
    expect(G, { state = { "DEFENSIVE", "ANTI_BURST", "DISENGAGE" }, forbid = { "Aimed Shot" } }, "three on you")
    assert_eq(G.S.team.focus and G.S.team.focus.on_me, true, "the focus is you")
    assert_eq(G.S.team.focus.attackers, 3, "three")
    has(G.S.team.disengage.why, "3 on you", "disengage")
end)

-- 12 ---------------------------------------------------------------------------------------
scenario("an immunity: a paladin at 15% under Divine Shield: no kill opportunity, no kill window; it lands when the bubble drops", function()
    local G = bundle()
    as(G, PALADIN, 20, 0.15); fighting(G)
    step(G)
    G.aura(G.target.guid, "Divine Shield", 8)
    settle(G)
    assert_eq(G.S.kill.target.v, "NO_KILL_OPPORTUNITY", "immune")
    expect(G, { not_state = { "KILL_WINDOW" } }, "bubbled")
    G.auras[G.target.guid] = nil
    settle(G)
    expect(G, { state = "KILL_WINDOW" }, "bubble gone")
end)

-- 13 ---------------------------------------------------------------------------------------
scenario("no defensives left: three rogues on you at 20%, nothing in the book: disengage, Feign Death and line of sight first; no damage", function()
    local G = bundle()
    as(G, ROGUE, 3); fighting(G)
    another(G, 2, ROGUE, { row = { dist = 4 } })
    another(G, 3, ROGUE, { row = { dist = 4 } })
    G.hp = 0.2
    settle(G)
    expect(G, { state = "DISENGAGE", actions = { "Feign Death", "break line of sight" }, avoid = { "Aimed Shot" } }, "nothing left")
end)

-- 14 ---------------------------------------------------------------------------------------
scenario("a low enemy with dangerous cooldowns: a rogue at 20%, Vanish, Sprint and Evasion never seen: a burst to line up, never high confidence; the reasons say it rests on the unseen", function()
    local G = bundle()
    as(G, ROGUE, 20, 0.2); fighting(G)
    settle(G)
    local k = G.S.kill.target
    assert_eq(k.v, "PREPARE_BURST", "line it up")
    has(k.why, "never seen (counted as available)", "on the unseen")
    expect(G, { state = "KILL_WINDOW", why = "prepare burst" }, "low rogue")
    assert(G.S.tactic.conf < 0.6, "not high: " .. G.S.tactic.conf)
end)

-- 15 ---------------------------------------------------------------------------------------
scenario("incomplete data: a player the client gives no class: role unknown at 0, its outs unknown, never a high-confidence kill", function()
    local G = bundle()
    G.target.get_class = function() return nil end
    G.row.dist, G.distance = 20, 20
    G.row.hp, G.health[G.target.guid] = 0.15, 0.15
    fighting(G)
    settle(G)
    local f = G.S.foes[G.target.guid]
    local _, conf = G.I.sure(f.inferred.role, 0)
    assert_eq(conf, 0, "no guess")
    local k = G.S.kill.target
    assert(k.v ~= "HIGH_CONFIDENCE_KILL_WINDOW", "never high on nothing: " .. k.v)
    has(k.why, "its class unread", "said")
end)

-- 16 ---------------------------------------------------------------------------------------
scenario("a wrong prediction: the same opener twice, then a different one: the miss is counted against it, the rate falls", function()
    local G = bundle()
    as(G, WARRIOR, 20)
    G.in_combat, G.row.in_combat = false, false
    step(G)
    local function fight_with(opener)
        G.in_combat, G.row.in_combat = true, true
        step(G)
        their_cast(G, opener); step(G)
        G.clock = G.clock + 8
        step(G)
        G.in_combat, G.row.in_combat = false, false
        step(G, 1)
    end
    fight_with("Charge"); fight_with("Charge")
    local e = G.S.foes[G.target.guid].predict.same_opener
    assert(e and e.hits == 1 and e.total == 1, "held once")
    local before = e.p
    fight_with("Hamstring")
    e = G.S.foes[G.target.guid].predict.same_opener
    assert_eq(e.total, 2, "two chances")
    assert_eq(e.hits, 1, "one held, one contradicted")
    assert(e.p < before, string.format("the rate falls: %.2f < %.2f", e.p, before))
end)

-- 17 ---------------------------------------------------------------------------------------
scenario("PvP turning into PvE: the player dies, mobs stay on you: the PvP state stands down, the fight's record closes", function()
    local G = bundle()
    as(G, WARRIOR, 3); fighting(G)
    settle(G)
    assert(G.I.debrief.T.open, "a PvP fight open")
    local mob = unit(G, "Creature-0-1-0-0-500-0001", { name = "Wolf" })
    G.target.dead, G.row.dead, G.health[G.target.guid], G.row.hp = true, true, 0, 0
    step(G)
    G.rows = { G.row_for(mob, { dist = 3 }) }
    G.target, G.row = mob, G.rows[1]
    G.health[mob.guid] = 0.8
    settle(G)
    assert_eq(G.I.debrief.T.open, false, "closed")
    assert_eq(G.I.debrief.T.last.outcome, "won", "won")
    expect(G, { not_state = { "KILL_WINDOW", "CONTROL_DISTANCE", "SUSTAINED_PRESSURE", "OPENING" } }, "mobs only")
end)

-- 18 ---------------------------------------------------------------------------------------
scenario("a missing client ability: Forever, no combat log, no sight ray: the picture lists what it cannot read, line of sight unknown, never false", function()
    local G = bundle({ client = { forever = true, combat_log = false } })
    as(G, WARRIOR, 20); fighting(G)
    settle(G)
    assert_eq(G.S.env.target.los.value, nil, "unknown")
    has(G.I.lines()[1], "LOS unknown", "said")
    has(table.concat(G.S.unavailable or {}, " / "), "combat log", "listed")
    expect(G, { state = { "SUSTAINED_PRESSURE", "RANGED_PRESSURE", "OPENING" } }, "still a read")
end)

-- the bench --------------------------------------------------------------------------------
T[#T + 1] = { "the bench: each scenario is a preset, and its situation reads as the scenario says", function()
    local D = require("jambix_aio/modules/react/custom_data")
    local by = {}
    for _, p in ipairs(D.BENCH_PRESETS) do by[p.key] = p end
    local want = { "scn_gap_closer", "scn_mobility_left", "scn_rogue_opener", "scn_rogue_reset", "scn_blink", "scn_mage_cc",
                   "scn_warlock_cast", "scn_healer_pressure", "scn_dead_zone", "scn_pet_breaks_cc", "scn_outnumbered",
                   "scn_immunity", "scn_no_defensives", "scn_low_dangerous", "scn_incomplete", "scn_wrong_prediction",
                   "scn_pvp_to_pve", "scn_missing_ability" }
    for _, k in ipairs(want) do
        local p = by[k]
        assert(p, "preset " .. k)
        assert(p.label and p.label:find("Scenario", 1, true), k .. " labelled as a scenario")
        assert(type(p.s) == "table", k .. " has a situation")
    end
    assert_eq(by.scn_warlock_cast.s.pvp_incoming_cast, true, "Fear at you")
    assert_eq(by.scn_warlock_cast.s.pvp_tactic, "INTERRUPT_OPPORTUNITY", "the state")
    assert_eq(by.scn_pet_breaks_cc.s.pet_breaks_cc, true, "the pet")
    assert_eq(by.scn_immunity.s.t_kill_verdict, "NO_KILL_OPPORTUNITY", "immune")
    assert_eq(by.scn_low_dangerous.s.t_kill_verdict, "PREPARE_BURST", "line it up")
    assert_eq(by.scn_outnumbered.s.pvp_focus_me, true, "focused")
    assert_eq(by.scn_healer_pressure.s.pvp_peel, true, "the peel")
end }

return T

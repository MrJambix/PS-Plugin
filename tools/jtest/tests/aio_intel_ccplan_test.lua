-- Jambix AIO: the control plan (PVP_INTEL_PLAN.md, Stage 6 / brief Phase
-- 8) -- modules/react/intel/ccplan.lua, the hold reaction in rules/intel.lua
-- and pvphunter.held's caster check, inside the reaction engine's tick on a
-- scripted clock. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: a breakable control on the target with a reason to
-- keep it halts the rotation's presses and says why, whose and how long;
-- our own tick on it means no hold (the control is as good as gone); the
-- pet on a held player is a recall the plan asks for and the window reads;
-- another hunter's trap is not ours; diminishing returns on Era follow
-- DRList's rule on the controls counted, start over after the window, and
-- hold the trap back only at immune; on Forever the category comes from the
-- client's own table and the multiplier stays UNKNOWN; the module's switch
-- reads calm.

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
    -- The PvP hunter's own trap rules stay out of the lanes: the plan's hold is what is watched.
    G.settings.rot_hunter_pvp_alpha = false
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

--- A control on the target as JCore's row and the client's aura list give it.
local function held_by(G, name, left, caster, kind)
    G.row.control = { spell_id = 1, kind = kind or "incapacitate", breaks = true, name = name, from = "debuff", remaining = left }
    G.aura(G.target.guid, name, left, { caster = caster })
end

local function cc(G) return G.S.cc end
local function plan(G) local f = G.S.foes[G.target.guid] return f and f.cc end
local function row2(G) return G.I.lines()[2] or "" end

local T = {}

T[#T + 1] = { "switched off: no plan, no hold, nothing in the readout", function()
    local G = bundle()
    G.settings.intel_cc = false
    melee(G); fighting(G)
    held_by(G, "Freezing Trap Effect", 8, G.player)
    G.tick()
    assert_eq(cc(G).hold, nil, "no hold")
    assert_eq(cc(G).held_n, 0, "nothing counted")
    assert_eq(G.verdict.halt, false, "the rotation runs")
    assert(not row2(G):find("CC ", 1, true), "no CC piece: " .. row2(G))
end }

T[#T + 1] = { "our trap on a melee player: held, yours, breaks; the hold halts the rotation and says why; the window reads it", function()
    local G = bundle()
    melee(G); fighting(G)
    held_by(G, "Freezing Trap Effect", 8, G.player)
    G.tick()
    local c = plan(G)
    assert(c and c.held, "a held row")
    assert_eq(c.held.ours, "yes", "the caster is us")
    assert_eq(c.held.ours_conf, 1.0, "sure of it")
    assert_eq(c.held.breaks, true, "damage breaks it")
    assert_eq(c.held.category, "incapacitate", "DRList's category")
    assert_eq(c.value.kind, "distance", "a melee player held: the range is ours")
    local h = cc(G).hold
    assert(h, "the hold")
    has(h.why, "Freezing Trap Effect on Enemy, 8.0s left (yours)", "the hold's words")
    has(h.why, "the range is yours to take", "and its reason")
    assert_eq(G.verdict.halt, true, "the rotation's presses stop")
    has(row2(G), "CC hold: Freezing Trap Effect", "the readout's piece")
    has(row2(G), "DR incapacitate x1 -> half", "with the diminishing returns")
    local sm = G.I.summary()
    has(sm.control, "Freezing Trap Effect 8.0s (yours)", "the window's control line")
    has(sm.control_why, "hold:", "and why")
    local now = G.React.custom.situation_now()
    assert_eq(now.t_cc_value, "distance", "target.cc_value")
    assert_eq(now.t_cc_ours, true, "target.cc_ours")
    assert_eq(now.t_cc_left, 8, "target.cc_left")
    assert_eq(now.t_dr_next, "half", "target.dr_next")
end }

T[#T + 1] = { "the caster unread: yours at a lower confidence; another hunter's trap: not yours, held() says nothing of it, the hold stands all the same", function()
    local G = bundle()
    melee(G); fighting(G)
    held_by(G, "Freezing Trap Effect", 8, nil)
    G.tick()
    local c = plan(G)
    assert_eq(c.held.ours, "unknown", "no caster to read")
    assert_near(c.held.ours_conf, 0.6, 0.001, "CC.unknown_caster_conf")
    has(cc(G).hold.why, "(yours, caster unread)", "said so")
    assert_near(cc(G).hold.conf, 0.6, 0.001, "the hold is only that sure")
    local other = unit(G, "Player-1-00000009", { name = "Other hunter", player = true })
    G.clock = G.clock + 0.3
    held_by(G, "Freezing Trap Effect", 8, other)
    G.tick()
    c = plan(G)
    assert_eq(c.held.ours, "no", "a caster that is not us")
    assert_eq(G.P.pvphunter.held(G.target), nil, "pvphunter.held: not ours")
    assert(cc(G).hold, "a control worth keeping is anyone's: the hold stands")
    has(cc(G).hold.why, "(not yours)", "and says whose")
    assert_eq(G.verdict.halt, true, "the rotation's presses stop")
end }

T[#T + 1] = { "the pet on the trapped player: the plan asks for its recall, the window's condition reads it, the Live view lists it among what is kept", function()
    local G = bundle()
    melee(G); fighting(G)
    G.pet_alive, G.pet_on = true, G.target
    held_by(G, "Freezing Trap Effect", 6, G.player)
    G.tick()
    local p = cc(G).pet
    assert_eq(p.recall, true, "call it back")
    assert_eq(p.guid, G.target.guid, "off the target")
    has(p.why, "its next bite breaks it", "why")
    has(row2(G), "pet: off Enemy", "the readout")
    assert_eq(G.React.custom.situation_now().pet_breaks_cc, true, "pet.breaks_cc")
    has(table.concat(G.I.summary().suppressed, " / "), "the pet: the pet is on Enemy", "among what is kept back")
    G.pet_on = nil
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(cc(G).pet.recall, false, "the pet is elsewhere")
end }

T[#T + 1] = { "a Serpent Sting of yours ticking on it: no hold, the control is as good as gone, and the readout says so", function()
    local G = bundle()
    melee(G); fighting(G)
    G.aura(G.target.guid, "Serpent Sting", 15, { caster = G.player })
    held_by(G, "Scatter Shot", 4, G.player)
    G.tick()
    assert_eq(cc(G).hold, nil, "no hold")
    local d = cc(G).doomed
    assert(d, "doomed")
    has(d.why, "Serpent Sting of yours ticks on it", "why")
    assert_eq(G.verdict.halt, false, "the rotation runs on")
    has(row2(G), "CC no hold: Serpent Sting", "the readout")
    assert_eq(plan(G).dots[1], "Serpent Sting", "the tick listed")
end }

T[#T + 1] = { "nothing to gain and no trap to follow: no hold, the scattered player is shot; the trap ready: the chain, and the hold for it", function()
    local G = bundle()
    at_range(G, MAGE); fighting(G)
    G.row.targeting_me = false
    held_by(G, "Scatter Shot", 4, G.player)
    G.tick()
    assert_eq(plan(G).value.kind, "none", "nothing to gain")
    assert_eq(cc(G).hold, nil, "no hold")
    assert_eq(G.verdict.halt, false, "shoot it")
    G.known["Freezing Trap"] = true
    G.clock = G.clock + 0.3
    G.tick()
    local ch = plan(G).chain
    assert(ch and ch.ok, "the chain")
    assert_eq(ch.name, "Freezing Trap", "the trap")
    has(ch.why, "lay it under the scattered player (half)", "after this scatter the trap is half")
    assert(cc(G).hold, "the hold for the chain")
    has(cc(G).hold.why, "lay it under the scattered player", "its reason")
    assert_eq(G.verdict.halt, true, "the rotation's presses stop")
end }

T[#T + 1] = { "a control with under a global cooldown left is not held for; one that damage does not break is not either", function()
    local G = bundle()
    melee(G); fighting(G)
    held_by(G, "Freezing Trap Effect", 0.8, G.player)
    G.tick()
    assert_eq(cc(G).hold, nil, "0.8 s: shoot")
    G.clock = G.clock + 0.3
    G.row.control = { spell_id = 1, kind = "stun", breaks = false, name = "Intimidation", from = "debuff", remaining = 3 }
    G.auras[G.target.guid] = {}
    G.tick()
    assert_eq(plan(G).held.breaks, false, "a stun: damage does not break it")
    assert_eq(cc(G).hold, nil, "no hold")
    assert_eq(cc(G).held_n, 0, "not counted among the breakable")
    assert_eq(G.verdict.halt, false, "the rotation runs")
end }

T[#T + 1] = { "diminishing returns on Era: the controls counted by their aura events, DRList's rule, immune at the fourth, a new chain after the window", function()
    local G = bundle()
    melee(G); fighting(G)
    G.by_guid["nameplate1"] = G.target
    G.tick()
    local guid = G.target.guid
    local function landed(name)
        G.clock = G.clock + 0.2
        G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate1", 0, G.id_of(name), name, 1, 4, 0, nil, false, true })
        G.tick()
    end
    local mult, level, count = G.I.cc.next(G.S, guid, "incapacitate")
    assert_eq(level, "full", "nothing counted yet")
    landed("Scatter Shot")
    mult, level, count = G.I.cc.next(G.S, guid, "incapacitate")
    assert_eq(count, 1, "one counted")
    assert_eq(level, "half", "the next is half")
    assert_eq(mult, 0.5, "x0.5")
    G.clock = G.clock + 5
    landed("Freezing Trap Effect")
    mult, level, count = G.I.cc.next(G.S, guid, "incapacitate")
    assert_eq(count, 2, "two")
    assert_eq(level, "quarter", "the next is a quarter")
    G.clock = G.clock + 5
    landed("Wyvern Sting")
    mult, level = G.I.cc.next(G.S, guid, "incapacitate")
    assert_eq(level, "immune", "the next would not hold")
    assert_eq(mult, 0, "x0")
    local d = G.S.foes[guid].cc.dr.incapacitate
    assert_eq(d.count, 3, "the chain")
    has(d.source, "DRList", "where the category came from")
    landed("Psychic Scream")
    assert_eq(select(2, G.I.cc.next(G.S, guid, "fear")), "half", "a fear counted apart")
    assert_eq(select(2, G.I.cc.next(G.S, guid, "incapacitate")), "immune", "the incapacitates untouched")
    -- The window runs from the END of the last one (Wyvern Sting's 12 s by
    -- the tables): 18 s after it ran out, a new chain.
    G.clock = G.clock + 31
    G.tick()
    mult, level, count = G.I.cc.next(G.S, guid, "incapacitate")
    assert_eq(level, "full", "a new chain")
    assert_eq(count, 0, "nothing in the window")
end }

T[#T + 1] = { "on Forever: the category from the client's own table, an effect aura from Era's list at half the confidence, the multiplier UNKNOWN", function()
    local G = bundle({ client = { forever = true, combat_log = false, name = "Forever" } })
    melee(G); fighting(G)
    local cat, conf, source = G.I.cc.category("Scatter Shot")
    assert_eq(cat, "incapacitate", "DiminishType 16")
    assert_near(conf, 0.9, 0.001, "the client's table")
    has(source, "the client's table", "source")
    cat, conf, source = G.I.cc.category("Freezing Trap Effect")
    assert_eq(cat, "incapacitate", "Era's list stands in for the effect aura")
    assert_near(conf, 0.5, 0.001, "at the fallback confidence")
    has(source, "unverified on Forever", "and says so")
    assert_eq(G.I.cc.category("Concussive Shot"), nil, "a snare: no category anywhere")
    held_by(G, "Scatter Shot", 4, G.player)
    G.tick()
    local mult, level, count = G.I.cc.next(G.S, G.target.guid, "incapacitate")
    assert_eq(count, 1, "counted")
    assert_eq(mult, nil, "the multiplier is not claimed")
    assert_eq(level, "unknown", "unknown")
    assert_eq(plan(G).next_level, "unknown", "the window's dr_next")
    has(cc(G).dr_rule, "unknown on Forever", "the rule's own word")
    has(row2(G), "DR incapacitate x1 -> unknown", "the readout")
end }

T[#T + 1] = { "what keeping it is worth: you low under it, survive; it heals, stop_heal; another nearly dead, kill", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    G.hp = 0.3
    held_by(G, "Freezing Trap Effect", 8, G.player)
    G.tick()
    assert_eq(plan(G).value.kind, "survive", "it was on you at 30%")
    has(cc(G).hold.why, "it was on you at 30% health", "why")

    G = bundle()
    at_range(G, PRIEST); fighting(G)
    G.row.targeting_me = false
    G.row.casting = G.casting("Flash Heal", 1.0, 1.5)
    G.tick()
    G.clock = G.clock + 1.2
    G.row.casting = nil
    held_by(G, "Scatter Shot", 4, G.player)
    G.tick()
    assert_eq(plan(G).value.kind, "stop_heal", "it heals")
    has(cc(G).hold.why, "it heals", "why")

    G = bundle()
    at_range(G, MAGE); fighting(G)
    G.row.targeting_me = false
    local low = unit(G, "Player-1-00000002", { name = "Low one", player = true })
    G.health[low.guid] = 0.2
    G.rows[2] = G.row_for(low, { dist = 15, hp = 0.2, targeting_me = false })
    held_by(G, "Scatter Shot", 4, G.player)
    G.tick()
    assert_eq(plan(G).value.kind, "kill", "finish the other")
    has(plan(G).value.why, "Low one is at 20%", "named")
end }

return T

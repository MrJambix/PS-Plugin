-- Jambix AIO: bait opportunity detection (PVP_INTEL_PLAN.md, Stage 8 /
-- brief Phase 7) -- modules/react/intel/bait.lua and the reaction "Intel:
-- the bait" (rules/intel.lua), inside the reaction engine's tick on a
-- scripted clock. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: a bait needs a prediction that passed the
-- evidence line AND the counter ready AND the threat under the line; a
-- mobility bait and a trinket bait press one Concussive Shot and not again
-- for a while; the defensive bait is a hold on our burst and the interrupt
-- bait is advice, neither presses; a control being kept, our own control
-- loss and the target's defensive up block every bait; the surer bait
-- wins; the readout, the Live view and the window's condition carry it;
-- the switch reads calm.

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
    G.P.power_counted = function() return true end      -- mana is read (the fillers can keep the pressure)
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

local function at_range(G, class, dist)
    G.target.get_class = function() return class or MAGE end
    G.row.dist, G.distance = dist or 20, dist or 20
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

--- Two sightings: it closes the gap when slowed.
local function teach_mobility(G)
    step(G)      -- the picture must know the target before our cast is attributed to it
    for _ = 1, 2 do
        our_cast(G, "Wing Clip"); step(G, 0.5); their_cast(G, "Intercept"); step(G, 0.5)
        G.clock = G.clock + 3
    end
end
--- Two sightings: it breaks a control at once.
local function teach_escape(G)
    for i = 1, 2 do
        held_by(G, i == 1 and "Freezing Trap Effect" or "Scatter Shot", 6, G.player); step(G)
        their_cast(G, "Berserker Rage"); step(G, 0.3)
        G.row.control = nil
        G.auras[G.target.guid] = {}
        G.clock = G.clock + 3
        step(G)
    end
end
--- Two sightings: it interrupts our casts, with `kick` seen each time.
local function teach_interrupt(G, kick)
    for _ = 1, 2 do
        their_cast(G, kick); step(G, 0.2); our_interrupted(G, "Aimed Shot"); step(G)
        G.clock = G.clock + 3
    end
end

local function bait(G) return G.S.bait end

local T = {}

T[#T + 1] = { "switched off: no bait, nothing pressed", function()
    local G = bundle()
    G.settings.intel_bait = false
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    teach_mobility(G)
    step(G)
    assert_eq(bait(G).target, nil, "no bait")
    assert_eq(G.sent("Concussive Shot"), 0, "nothing pressed")
end }

T[#T + 1] = { "mobility bait: a warrior at range that closes when slowed, the trap ready: Concussive Shot once, the trap named; the clip a weaker counter; no counter, no bait; in melee, no bait", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    teach_mobility(G)
    step(G)
    local b = bait(G).target
    assert(b, "a bait")
    assert_eq(b.kind, "mobility", "the charge")
    assert_eq(b.press, "Concussive Shot", "the cheap slow")
    assert_eq(b.counter, "Freezing Trap", "the best counter")
    -- The rate (about 0.75) scaled by the evidence (two chances: 0.5), the trap at full.
    assert_near(b.conf, 0.37, 0.03, "rate x evidence x the counter: " .. b.conf)
    has(b.why, "it closes the gap the moment it is slowed", "why")
    has(b.why, "Freezing Trap ready, 20 yd between you", "the counter and the room")
    assert_eq(G.sent("Concussive Shot"), 1, "pressed once")
    G.run(3)
    assert_eq(G.sent("Concussive Shot"), 1, "and not again for a while")
    has(G.I.lines()[3], "bait: bait its charge: Concussive Shot with Freezing Trap ready", "the readout")
    -- The trap down, Scatter Shot unknown: the clip is the counter, at 0.6.
    G.unready["Freezing Trap"] = true
    step(G)
    b = bait(G).target
    assert_eq(b.counter, "Wing Clip", "the clip")
    assert(b.conf < 0.3, "a weaker counter: " .. b.conf)
    -- No counter at all: no bait.
    G.unready["Wing Clip"] = true
    step(G)
    assert_eq(bait(G).target, nil, "no counter: no bait")
    -- The trap back, the warrior already in melee: nothing to bait.
    G.unready["Freezing Trap"], G.unready["Wing Clip"] = nil, nil
    melee(G, WARRIOR)
    step(G)
    assert_eq(bait(G).target, nil, "in melee: no bait")
end }

T[#T + 1] = { "defensive bait: a rogue whose Evasion is unseen, Rapid Fire ready: hold it (advice, nothing pressed); Evasion seen: no bait; a known threshold: the hold only near it", function()
    local G = bundle()
    at_range(G, ROGUE); fighting(G)
    G.known["Rapid Fire"] = true
    step(G)
    -- No enemy spell has reached us yet this session: "unseen" says nothing
    -- (live 2026-10-12: three fights with no enemy event kept), so no bait on it.
    assert_eq(bait(G).target, nil, "silence is not evidence: no bait")
    -- Its first cast seen: enemy events reach us, and "unseen" means something.
    their_cast(G, "Sinister Strike"); step(G)
    local b = bait(G).target
    assert(b, "a bait")
    assert_eq(b.kind, "defensive", "the defensive")
    assert_eq(b.hold, "Rapid Fire", "the burst held")
    assert_eq(bait(G).hold_burst, "Rapid Fire", "said for the burst's gate")
    has(b.why, "Evasion unseen this session", "why")
    assert_eq(G.sent("Rapid Fire") + G.sent("Concussive Shot"), 0, "nothing pressed")
    has(table.concat(G.I.summary().suppressed, " / "), "Rapid Fire kept: a defensive bait", "the Live view's kept line")
    -- Evasion seen once: the ledger has it, no threshold yet: no bait.
    G.health[G.target.guid], G.row.hp = 0.3, 0.3
    their_buff(G, "Evasion"); step(G)
    assert_eq(bait(G).target, nil, "seen: nothing unseen, no threshold yet")
    -- A second sighting at 30%: the threshold is known; at 90% the burst lands first.
    G.clock = G.clock + 20
    G.health[G.target.guid], G.row.hp = 0.9, 0.9
    step(G)
    their_buff(G, "Evasion"); G.health[G.target.guid], G.row.hp = 0.3, 0.3; step(G)
    G.clock = G.clock + 5
    G.health[G.target.guid], G.row.hp = 0.9, 0.9
    step(G)
    assert_eq(bait(G).target, nil, "far above its threshold: no hold")
    G.health[G.target.guid], G.row.hp = 0.4, 0.4
    step(G)
    b = bait(G).target
    assert(b and b.kind == "defensive", "near the threshold: hold the burst")
    has(b.why, "it is at 40%", "why")
end }

T[#T + 1] = { "interrupt bait: a rogue in Kick's reach that interrupts, Aimed Shot ready: advice, nothing pressed; out of its reach, none; a mage at 20 yd with Counterspell, yes", function()
    local G = bundle()
    melee(G, ROGUE); fighting(G)
    G.known["Aimed Shot"] = true
    teach_interrupt(G, "Kick")
    step(G)
    local b = bait(G).target
    assert(b, "a bait")
    assert_eq(b.kind, "interrupt", "the interrupt")
    has(b.v, "draw its Kick: start Aimed Shot, stop it, then the real cast", "the advice")
    assert_eq(b.press, nil, "nothing to press")
    assert_eq(#G.casts, 0, "nothing pressed")
    at_range(G, ROGUE, 20)
    step(G)
    assert_eq(bait(G).target, nil, "out of Kick's reach")
    G = bundle()
    at_range(G, MAGE, 20); fighting(G)
    G.known["Aimed Shot"] = true
    teach_interrupt(G, "Counterspell")
    step(G)
    b = bait(G).target
    assert(b and b.kind == "interrupt", "Counterspell reaches 30")
    has(b.why, "Counterspell reaches 30 yd", "why")
end }

T[#T + 1] = { "trinket bait: it breaks a control at once, the trap and Concussive Shot ready: Concussive Shot pressed, the trap named; a burst up on it: none", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    teach_escape(G)
    step(G)
    local b = bait(G).target
    assert(b, "a bait")
    assert_eq(b.kind, "cc", "the trinket")
    assert_eq(b.press, "Concussive Shot", "the cheap control")
    assert_eq(b.counter, "Freezing Trap", "then the trap")
    assert_eq(G.sent("Concussive Shot"), 1, "pressed once")
    G.aura(G.target.guid, "Recklessness", 10)
    step(G)
    local t = bait(G).target
    assert(t == nil or t.kind ~= "cc", "a burst up on it: no trinket bait")
end }

T[#T + 1] = { "the gates: a control being kept on it, you controlled, its defensive up; the Live view and the window's condition", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    teach_mobility(G)
    step(G)
    assert(bait(G).target, "a bait to start from")
    step(G)
    assert_eq(G.React.custom.situation_now().pvp_bait, "mobility", "fight.bait")
    has(G.I.summary().bait, "bait its charge", "the Live view")
    -- Our trap on it, worth keeping: the control plan holds, the bait waits.
    melee(G, WARRIOR)
    held_by(G, "Freezing Trap Effect", 8, G.player)
    step(G)
    assert_eq(bait(G).target, nil, "no bait")
    assert_eq(bait(G).blocked, "a control on it is being kept", "why")
    G.row.control, G.auras[G.target.guid] = nil, {}
    at_range(G, WARRIOR)
    -- Its defensive up.
    G.aura(G.target.guid, "Evasion", 10)
    step(G)
    has(bait(G).blocked or "", "its defensive is up", "blocked by the defensive")
    G.auras[G.target.guid] = {}
    -- You controlled.
    G.aura("player", "Kidney Shot", 5, { caster = G.target })
    step(G)
    assert_eq(bait(G).blocked, "you are controlled", "blocked while controlled")
end }

T[#T + 1] = { "precedence: a mobility bait and a trinket bait on the same player: the surer one is the bait, the list keeps both", function()
    local G = bundle()
    at_range(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"], G.known["Concussive Shot"] = true, true
    teach_mobility(G)
    teach_escape(G)
    step(G)
    local Bt = bait(G)
    assert_eq(#Bt.list, 2, "two baits")
    assert(Bt.list[1].conf >= Bt.list[2].conf, "the surer first")
    assert_eq(Bt.target, Bt.list[1], "and it is the bait")
    local kinds = { [Bt.list[1].kind] = true, [Bt.list[2].kind] = true }
    assert(kinds.mobility and kinds.cc, "the charge and the trinket")
end }

return T

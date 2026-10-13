-- Jambix AIO: the PvP intelligence's blind spots, narrowed (PVP_INTEL_PLAN.md
-- Stage 14) -- line of sight from the client's own word, diminishing
-- returns from your measured controls, an enemy's mana where the client
-- answers, an ally's control from the party's spell events. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: with no sight ray, "not in line of sight" on a
-- cast of yours is false for a moment and a shot of yours going out is
-- true -- then unknown again, never guessed; a first control is full, the
-- next one what three of each measured say, nothing measured unknown; a
-- mana reading is taken only when both numbers are above zero, a dry
-- healer gets no Viper Sting and does not count against a kill; an ally's
-- Polymorph cast at your target counts before its aura does, for a moment.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local WARRIOR, PRIEST = B.WARRIOR, B.PRIEST

local FOREVER = { client = { forever = true, combat_log = false } }

local function bundle(opts, files)
    local G = B.bundle(opts or FOREVER)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    G.files = files or {}
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    G.target.get_class = function() return WARRIOR end
    G.in_combat, G.fight_age = true, 8
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 20, 20
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function los(G) return G.S.env.target.los end

local T = {}

T[#T + 1] = { "line of sight with no ray: the client's \"not in line of sight\" is false for a moment, a shot going out is true, then unknown again", function()
    local G = bundle()
    G.known["Arcane Shot"] = true
    step(G)
    assert_eq(los(G).value, nil, "no ray: unknown")
    G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 50, "Target not in line of sight", "SPELL_FAILED_LINE_OF_SIGHT" })
    step(G)
    assert_eq(los(G).value, false, "the client said so")
    has(los(G).source, "the client: Target not in line of sight", "and says where from")
    step(G, 2.5)
    assert_eq(los(G).value, nil, "a moment later: unknown again")
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of("Arcane Shot") })
    step(G)
    assert_eq(los(G).value, true, "a shot of yours went out")
    has(los(G).source, "your Arcane Shot went out", "said")
    -- Another error is not line of sight.
    step(G, 2.5)
    G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 282, "You are facing the wrong way!", "ERR_BADATTACKFACING" })
    step(G)
    assert_eq(los(G).value, nil, "facing is not sight")
end }

T[#T + 1] = { "diminishing returns on Forever: a first control full; the next what three of each measured say; nothing measured, unknown", function()
    local files = { ["jambix.aio.fieldchecks.json"] = { checks = {}, dr = {
        ["Scatter Shot"] = { ["1"] = { sum = 12, n = 3, min = 4, max = 4 }, ["2"] = { sum = 6, n = 3, min = 2, max = 2 } },
    } } }
    local G = bundle(nil, files)
    step(G)
    local C = G.I.cc
    local m0, l0 = C.next_of(0)
    assert_eq(m0, 1, "a first control is full")
    assert_eq(l0, "full", "said")
    local m1, l1 = C.next_of(1)
    assert_eq(m1, 0.5, "the second: half, as measured")
    has(l1, "half (measured, 3)", "said, with what it rests on")
    local m2, l2 = C.next_of(2)
    assert_eq(m2, nil, "the third: nothing measured")
    assert_eq(l2, "unknown", "unknown")
    -- Two of the second only: not enough.
    local H = bundle(nil, { ["jambix.aio.fieldchecks.json"] = { checks = {}, dr = {
        ["Scatter Shot"] = { ["1"] = { sum = 12, n = 3 }, ["2"] = { sum = 4, n = 2 } } } } })
    step(H)
    assert_eq((H.I.cc.next_of(1)), nil, "two measured are not enough")
end }

T[#T + 1] = { "an enemy's mana: taken when both numbers are above zero; a zero is unknown; a dry healer gets no Viper Sting", function()
    local G = bundle({})                                   -- Era: the same read
    G.known["Viper Sting"] = true
    G.group.in_group = true
    local mate = unit(G, "Player-1-00000951", { name = "Mate", player = true, hostile = false })
    G.dist = { [mate.guid] = 10 }
    G.members = { mate }
    local priest = unit(G, "Player-1-00000952", { name = "Priesty", player = true })
    priest.get_class = function() return PRIEST end
    local mana = { cur = 300, max = 1000 }
    priest.get_power = function() return mana.cur end
    priest.get_max_power = function() return mana.max end
    local r = G.row_for(priest, { dist = 20, targeting_me = false, engaged = false })
    G.rows[#G.rows + 1] = r
    r.casting = G.casting("Flash Heal", 1.4, 1.5)
    step(G)
    r.casting = nil
    step(G, 1.1)
    local f = G.S.foes[priest.guid]
    assert_eq(f.mana_pct, 0.3, "read")
    has(G.S.team.healer.why, "30% mana", "said")
    has(G.S.team.healer.action or "", "Viper Sting", "a sting for its mana")
    mana.cur = 0
    step(G, 1.1)
    assert_eq(f.mana_pct, 0.3, "a zero is not taken: the last reading stands")
    mana.cur = 50
    step(G, 1.1)
    assert_eq(f.mana_pct, 0.05, "5%")
    assert_eq(G.S.team.healer.action, nil, "dry: no Viper Sting")
end }

T[#T + 1] = { "an ally's Polymorph cast at your target counts as its control before the aura is read -- for a moment", function()
    local G = bundle({})
    G.group.in_group = true
    local mage = unit(G, "Player-1-00000961", { name = "Magey", player = true, hostile = false })
    mage.get_target = function() return G.target end
    G.dist = { [mage.guid] = 15 }
    G.members = { mage }
    G.by_guid["party1"] = mage
    step(G); step(G, 0.6)
    assert_eq(G.S.team.overlap, nil, "nothing yet")
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "party1", 0, G.id_of("Polymorph") })
    step(G)
    local o = G.S.team.overlap
    assert(o, "the ally's control, from its cast")
    has(o.why, "Magey's Polymorph on Enemy just now", "said")
    step(G, 2.0)
    assert_eq(G.S.team.overlap, nil, "no aura came: a moment only")
end }

return T

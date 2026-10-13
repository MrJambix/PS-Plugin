-- Jambix AIO: teamfights (PVP_INTEL_PLAN.md Stage 10, the brief's Phase
-- 12) -- modules/react/intel/team.lua inside the reaction engine's tick on a
-- scripted clock, and the states that read it (PROTECT_ALLY,
-- INTERRUPT_OPPORTUNITY). The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: a one-on-one is no teamfight; the focus is whom
-- most enemies are on (a tie stays on you); a peel names the enemy, the
-- ally and the first tool of ours that reaches it -- never one in its dead
-- zone, never a player an ally already holds; the cast to stop first is a
-- heal on a low enemy, then a control at one of us; a switch is said when
-- the target is immune or held by an ally's control (no control or damage
-- of ours on it); the enemy healer free is said with what pressures it;
-- overextended and disengage from the distances; the conditions read it all.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR
local MAGE = 8

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.known["Arcane Shot"] = true
    return G
end
local function fighting(G)
    G.in_combat, G.fight_age = true, 6
    G.row.in_combat = true
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
--- One more enemy player, its row in the fight.
local function foe(G, n, class, fields)
    local u = unit(G, string.format("Player-1-0000010%d", n), { name = fields.name, player = true })
    u.get_class = function() return class end
    local r = G.row_for(u, fields.row or {})
    G.rows[#G.rows + 1] = r
    G.health[u.guid] = r.hp
    return u, r
end
--- The group: allies by name, each at a distance and a health.
local function group(G, list)
    G.group.in_group = true
    G.dist = G.dist or {}
    local out = {}
    for i, a in ipairs(list) do
        local u = unit(G, string.format("Player-1-0000020%d", i), { name = a.name, player = true, hostile = false })
        G.dist[u.guid], G.health[u.guid] = a.dist or 10, a.hp or 1
        out[i] = u
        if a.healer then G.healer = u end
    end
    G.members = out
    return out
end
local function team(G) return G.S.team end

local T = {}

T[#T + 1] = { "a one-on-one is no teamfight: nothing read, no fourth readout row", function()
    local G = bundle()
    G.target.get_class = function() return WARRIOR end
    fighting(G)
    step(G); step(G)
    assert_eq(team(G).active, false, "one player, no group")
    assert_eq(team(G).line, "", "no line")
    local lines = G.I.lines()
    for i = 1, #lines do assert(not lines[i]:find("team:", 1, true), "no team row: " .. lines[i]) end
end }

T[#T + 1] = { "the focus: two players on you is you focused; one on you and two on an ally is the ally (a tie stays on you)", function()
    local G = bundle()
    G.target.get_class = function() return WARRIOR end
    fighting(G)
    local allies = group(G, { { name = "Mate", dist = 8 } })
    foe(G, 1, ROGUE, { name = "Stabby", row = { targeting_me = true, dist = 4 } })
    step(G); step(G)
    assert_eq(team(G).focus.on_me, true, "two on you")
    assert_eq(team(G).focus.attackers, 2, "how many")
    has(team(G).focus.why, "2 enemies on you", "said")
    -- Both move to the ally; a third stays on you.
    G.row.targeting_me, G.row.target_guid = false, allies[1].guid
    G.rows[2].targeting_me, G.rows[2].target_guid = false, allies[1].guid
    foe(G, 2, MAGE, { name = "Frosty", row = { targeting_me = true, dist = 25 } })
    step(G); step(G)
    assert_eq(team(G).focus.on_me, false, "the ally")
    has(team(G).focus.why, "2 enemies on Mate", "named")
    has(G.I.lines()[4] or "", "team: focus: 2 enemies on Mate", "its own readout row")
end }

T[#T + 1] = { "a peel: an enemy on our healer, the first tool of ours that reaches it -- Scatter Shot at 12 yd, Wing Clip in melee, nothing from the dead zone; never a player an ally already holds", function()
    local G = bundle()
    G.known["Scatter Shot"], G.known["Wing Clip"] = true, true
    G.target.get_class = function() return WARRIOR end
    fighting(G)
    local allies = group(G, { { name = "Heals", dist = 14, healer = true }, { name = "Dps", dist = 10 } })
    G.row.targeting_me, G.row.target_guid, G.row.dist, G.distance = false, allies[1].guid, 12, 12
    step(G); step(G)
    local p = team(G).peel
    assert(p, "a peel")
    assert_eq(p.action, "Scatter Shot", "in its 15 yd")
    has(p.why, "Enemy on Heals (the healer): Scatter Shot", "said")
    step(G, 1.0)
    assert_eq(G.S.tactic.state, "PROTECT_ALLY", "the state")
    has(G.S.tactic.why, "Scatter Shot", "with the tool")
    assert_eq(G.S.tactic.actions[1], "Scatter Shot on Enemy", "the tool first")
    -- The dead zone (5 to 8 yd): too close for Scatter Shot, too far for the clip.
    G.row.dist, G.distance = 6, 6
    step(G)
    assert_eq(team(G).peel.action, nil, "6 yd -- " .. team(G).peel.why)
    has(team(G).peel.why, "nothing of yours reaches it", "said")
    G.row.dist, G.distance = 3, 3
    G.unready["Scatter Shot"] = true
    step(G)
    assert_eq(team(G).peel.action, "Wing Clip", "melee")
    -- An ally's Polymorph on it: leave it be.
    G.row.control = { kind = "polymorph", name = "Polymorph", remaining = 8, breaks = true }
    step(G); step(G)
    assert_eq(team(G).peel, nil, "an ally holds it")
end }

T[#T + 1] = { "the cast to stop: a heal on a low enemy before a Polymorph at an ally, by the first stopper in reach; the state says it", function()
    local G = bundle()
    G.known["Scatter Shot"] = true
    G.target.get_class = function() return WARRIOR end
    fighting(G)
    G.row.hp, G.health[G.target.guid] = 0.2, 0.2
    G.row.targeting_me = false
    local allies = group(G, { { name = "Mate", dist = 10 } })
    local priest = foe(G, 1, PRIEST, { name = "Priesty", row = { targeting_me = false, dist = 12, target_guid = G.target.guid } })
    foe(G, 2, MAGE, { name = "Frosty", row = { targeting_me = false, dist = 30, target_guid = allies[1].guid } })
    -- Long bars, so both are still on them when the state is asked.
    G.rows[2].casting = G.casting("Flash Heal", 2.5, 3.0)
    G.rows[3].casting = G.casting("Polymorph", 2.5, 3.0)
    step(G); step(G)
    local casts = team(G).casts
    assert_eq(#casts, 2, "both read")
    assert_eq(casts[1].spell, "Flash Heal", "the heal first: " .. casts[1].spell)
    assert_eq(casts[1].at, "Enemy", "on the low one")
    assert_eq(casts[2].kind, "control", "the Polymorph second")
    assert_eq(casts[2].at, "Mate", "at the ally")
    local c = team(G).interrupt
    assert_eq(c.name, "Priesty", "the priest")
    assert_eq(c.tool, "Scatter Shot", "12 yd: in reach")
    has(c.why, "Priesty's Flash Heal at Enemy (heal", "said")
    step(G, 1.0)
    assert_eq(G.S.tactic.state, "INTERRUPT_OPPORTUNITY", "the state")
    assert_eq(G.S.tactic.actions[1], "Scatter Shot on Priesty", "the tool on the caster")
    -- The mage at 30 yd is out of Scatter Shot's reach: with the priest out of
    -- reach too, nothing is ours to stop.
    G.rows[2].dist = 30
    step(G)
    assert_eq(team(G).interrupt, nil, "nothing reaches either")
    assert_eq(#team(G).casts, 2, "still read")
    -- The enemy healer, seen healing, is said.
    assert_eq(team(G).healer and team(G).healer.name, "Priesty", "the healer")
    assert_eq(team(G).healer.free, true, "free")
    _ = priest
end }

T[#T + 1] = { "a switch: your target immune, or held by an ally's control (no control or damage of yours on it)", function()
    local G = bundle()
    G.target.get_class = function() return 2 end           -- a paladin
    fighting(G)
    G.row.dist, G.distance = 20, 20
    foe(G, 1, WARRIOR, { name = "Smashy", row = { targeting_me = true, dist = 20, hp = 0.15 } })
    step(G)
    G.aura(G.target.guid, "Divine Shield", 8)
    step(G); step(G)
    local s = team(G).switch
    assert(s, "a switch")
    has(s.why, "Enemy is immune (Divine Shield)", "why")
    assert_eq(s.name, "Smashy", "the kill window elsewhere")
    -- The bubble gone; an ally's Polymorph on it instead.
    G.auras[G.target.guid] = nil
    G.row.control = { kind = "polymorph", name = "Polymorph", remaining = 8, breaks = true }
    step(G); step(G)
    assert(team(G).overlap, "an ally's control on the target")
    has(team(G).switch.why, "Polymorph on Enemy is an ally's", "said")
end }

T[#T + 1] = { "overextended: in a group, the nearest ally far with two enemies near; disengage: two on you, no ally near", function()
    local G = bundle()
    G.target.get_class = function() return ROGUE end
    fighting(G)
    G.row.targeting_me = true
    group(G, { { name = "Mate", dist = 60 } })
    foe(G, 1, WARRIOR, { name = "Smashy", row = { targeting_me = true, dist = 6 } })
    step(G); step(G)
    has(team(G).overextended.why, "your nearest ally 60 yd away, 2 enemies within 30 yd", "overextended")
    has(team(G).disengage.why, "2 on you, 0 ally(s) near: break away toward your group", "disengage")
    -- The ally comes to you: neither.
    G.dist[G.members[1].guid] = 10
    G.clock = G.clock + 2
    step(G); step(G)
    assert_eq(team(G).overextended, nil, "back with the group")
    assert_eq(team(G).disengage, nil, "two on you, you and an ally: not outnumbered")
end }

T[#T + 1] = { "the switch off reads nothing; the conditions read the fight (fight.team_*); the bench carries them", function()
    local G = bundle()
    G.target.get_class = function() return WARRIOR end
    fighting(G)
    group(G, { { name = "Mate", dist = 8 } })
    foe(G, 1, ROGUE, { name = "Stabby", row = { targeting_me = true, dist = 4 } })
    step(G); step(G)
    local C = G.P.react.custom
    if C and C.situation_now then
        local s = C.situation_now()
        assert_eq(s.pvp_focus_me, true, "copied")
        assert_eq(s.pvp_peel, false, "no peel")
    end
    G.settings.intel_team = false
    step(G); step(G)
    assert_eq(team(G).active, false, "off")
    assert_eq(team(G).focus, nil, "nothing")
end }

return T

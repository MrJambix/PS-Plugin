-- Jambix AIO: two more feeds of enemy spells (PVP_INTEL_PLAN.md Stage 14) --
-- modules/react/intel/state.lua on a scripted clock
-- (tools/jtest/mock/intel_bundle.lua).
--
-- Why: in seventeen fights on Forever the picture heard 42 enemy casts
-- against 343 auras, 13 fights with none; the API recorder shows the
-- client sends a player's spell events only for your target and soft
-- target. So: a debuff an enemy puts on you names its caster -- that is
-- its cast, observed; and every enemy row carries its cast bar -- a bar
-- run to its end with no interrupt seen is a finished cast.
--
-- What these hold it to: the debuff on you lands on the caster's ledger
-- as down; a buff on you, a caster that resolves to nobody, a debuff from
-- a friend: nothing; the same spell twice within a moment counted once; a
-- bar run out is a cast, a bar cut short or interrupted is not, a channel
-- counts when it starts; the fight's record counts both feeds.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST = B.ROGUE, B.PRIEST

local function bundle(opts)
    local G = B.bundle(opts or { client = { forever = true, combat_log = false } })
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    G.target.get_class = function() return ROGUE end
    G.in_combat, G.fight_age = true, 6
    G.row.in_combat, G.row.targeting_me, G.row.dist, G.distance = true, true, 4, 4
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function aura_on_me(G, name, caster, helpful)
    G.fire("jcore.game_event.UNIT_AURA", { "added", "player", 1, G.id_of(name), name, 0, 4, (G.clock + 4) * 1000,
                                           caster, helpful == true, helpful ~= true })
end
local function recent_of(f, name)
    for i = #f.recent, 1, -1 do if f.recent[i].name == name then return f.recent[i] end end
    return nil
end

local T = {}

T[#T + 1] = { "a debuff a player puts on you is its cast: Kidney Shot from the rogue lands on its ledger as down; counted once", function()
    local G = bundle()
    step(G)
    aura_on_me(G, "Kidney Shot", "nameplate1")
    step(G)
    local f = G.S.foes[G.target.guid]
    local r = recent_of(f, "Kidney Shot")
    assert(r, "in its recent ring")
    assert_eq(r.kind, "cast", "a cast")
    has(r.source, "UNIT_AURA on player", "from the debuff on you")
    local e = G.I.cooldowns.seen(G.S, G.target.guid, "Kidney Shot")
    assert_eq(e and e.state, "down", "its cooldown running")
    assert_eq(G.S.events.on_me, 1, "counted")
    aura_on_me(G, "Kidney Shot", "nameplate1")                 -- the same, a moment later
    assert_eq(G.S.events.on_me, 1, "once")
end }

T[#T + 1] = { "not a cast of theirs: a buff on you, a caster that resolves to nobody, a debuff with no caster", function()
    local G = bundle()
    step(G)
    aura_on_me(G, "Power Word: Fortitude", "nameplate1", true)
    aura_on_me(G, "Hamstring", "nameplate9")
    aura_on_me(G, "Hamstring", nil)
    step(G)
    assert_eq(G.S.events.on_me, 0, "none of them")
    assert_eq(recent_of(G.S.foes[G.target.guid], "Hamstring"), nil, "nothing on the rogue")
end }

T[#T + 1] = { "a cast bar run to its end is a finished cast -- for a player you have not targeted; cut short or interrupted, not; a channel counts when it starts", function()
    local G = bundle()
    local priest = unit(G, "Player-1-00000901", { name = "Priesty", player = true })
    priest.get_class = function() return PRIEST end
    local r = G.row_for(priest, { dist = 20, targeting_me = false })
    G.rows[#G.rows + 1] = r
    step(G)
    -- Greater Heal: 2.5 s, run out.
    r.casting = G.casting("Greater Heal", 0.6, 2.5)
    step(G, 0.3)
    r.casting = nil
    step(G, 0.4)
    local f = G.S.foes[priest.guid]
    local g = recent_of(f, "Greater Heal")
    assert(g, "a finished cast")
    assert_eq(g.source, "cast bar", "from the bar")
    assert_eq(G.S.events.bars, 1, "counted")
    -- Flash Heal cut short (the bar gone with a second left): not a cast.
    r.casting = G.casting("Flash Heal", 1.4, 1.5)
    step(G, 0.1)
    r.casting = nil
    step(G, 0.1)
    assert_eq(recent_of(f, "Flash Heal"), nil, "cut short: no cast")
    -- Interrupted by an event: not a cast either.
    G.by_guid["nameplate2"] = priest
    r.casting = G.casting("Heal", 0.5, 3.0)
    step(G, 0.1)
    G.fire("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", { "nameplate2", 0, G.id_of("Heal") })
    r.casting = nil
    step(G, 0.6)
    local h = recent_of(f, "Heal")
    assert(h == nil or h.kind == "interrupted", "interrupted: no cast")
    -- A channel: counted at its start.
    local c = G.casting("Mind Flay", 3.0, 3.0)
    c.channel = true
    r.casting = c
    step(G, 0.1)
    local m = recent_of(f, "Mind Flay")
    assert(m and m.kind == "channel", "the channel counted when it starts")
    assert_eq(G.S.events.bars, 2, "two from the bars")
end }

T[#T + 1] = { "the fight's record counts both feeds", function()
    local G = bundle()
    G.files = {}
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    step(G)
    aura_on_me(G, "Kidney Shot", "nameplate1")
    step(G)
    G.target.dead, G.row.dead, G.health[G.target.guid], G.row.hp = true, true, 0, 0
    step(G)
    local f = G.I.debrief.T.last
    assert(f and f.feeds, "the fight closed with its feeds")
    assert_eq(f.feeds.on_me, 1, "the debuff on you")
    local lines = table.concat(G.I.debrief.lines(), " / ")
    has(lines, "1 debuff(s) of theirs on you", "on the page")
end }

return T

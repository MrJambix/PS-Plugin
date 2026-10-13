-- Jambix AIO: the field checks (modules/react/intel/fieldcheck.lua) -- the
-- game's own answers to what the hunter work assumed and never saw (the
-- user's relook of 2026-10-12, item 6). Each check opens on our cast, is
-- answered by what the game shows next or times out, is counted across
-- sessions on disk, and shows on the Reactions page.

local B = require("mock/intel_bundle")
local assert_eq, has = B.assert_eq, B.has
local hunter_ranges = B.hunter_ranges
local ROGUE, WARRIOR = B.ROGUE, B.WARRIOR

local FILE = "jambix.aio.fieldchecks.json"

local function bundle(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    local files = {}
    G.P.ctx.storage = { read_json = function(n) return files[n] end, write_json = function(n, v) files[n] = v return true end }
    G.files = files
    return G
end
local function fighting(G)
    G.in_combat, G.fight_age = true, 4
    G.row.in_combat, G.row.targeting_me = true, true
end
local function near(G, class, dist)
    G.target.get_class = function() return class or WARRIOR end
    G.row.dist, G.distance = dist or 3, dist or 3
end
local function our_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of(name) })
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function fc(G) return G.I.fieldcheck end

local T = {}

T[#T + 1] = { "a trap laid in melee: its effect on a mob in reach is a yes; none within 5 s is a no; counted and kept on disk", function()
    local G = bundle()
    near(G, WARRIOR, 3); fighting(G)
    step(G)
    our_cast(G, "Immolation Trap"); step(G)
    G.aura(G.target.guid, "Immolation Trap Effect", 15); step(G)
    has(fc(G).verdict("trap_in_melee"), "yes (1 of 1)", "sprang")
    -- Laid again while the first one's effect is still on it: no clean answer, not counted.
    our_cast(G, "Immolation Trap"); G.run(6)
    has(fc(G).verdict("trap_in_melee"), "yes (1 of 1)", "an effect already there: not counted")
    G.auras[G.target.guid] = {}
    our_cast(G, "Immolation Trap"); step(G)
    G.run(6)
    has(fc(G).verdict("trap_in_melee"), "mixed (1 of 2)", "the next did not spring")
    fc(G).flush(G.clock)
    assert_eq(G.files[FILE].checks.trap_in_melee.yes, 1, "kept")
    assert_eq(G.files[FILE].checks.trap_in_melee.no, 1, "kept")
    -- A trap laid with nobody in reach is not a melee check.
    local G2 = bundle()
    near(G2, WARRIOR, 20); fighting(G2)
    step(G2)
    our_cast(G2, "Immolation Trap"); G2.run(6)
    has(fc(G2).verdict("trap_in_melee"), "not seen yet", "no check")
end }

T[#T + 1] = { "Disengage with a mob on you in melee: turning off you within 3 s is a yes; still on you is a no", function()
    local G = bundle()
    near(G, WARRIOR, 3); fighting(G)
    step(G)
    our_cast(G, "Disengage"); step(G)
    G.row.targeting_me, G.row.targeting_pet = false, true
    step(G)
    has(fc(G).verdict("disengage"), "yes (1 of 1)", "handed back")
    G.row.targeting_me, G.row.targeting_pet = true, false
    our_cast(G, "Disengage"); G.run(3.5)
    has(fc(G).verdict("disengage"), "mixed (1 of 2)", "the second stayed on you")
end }

T[#T + 1] = { "Serpent Sting sent at a mob that is not your target: its success is a yes; the rotation backing off it is a no; a sting at your target is no check", function()
    local G = bundle()
    near(G, WARRIOR, 20); fighting(G)
    step(G)
    local add = B.unit(G, "add1", { name = "Add" })
    G.fire("jcore.cast.sent", { spell_id = G.id_of("Serpent Sting"), target = add })
    our_cast(G, "Serpent Sting"); step(G)
    has(fc(G).verdict("sting_add"), "yes (1 of 1)", "it went out")
    G.fire("jcore.cast.sent", { spell_id = G.id_of("Serpent Sting"), target = add })
    G.fire("jambix.aio.rotation_stuck", "Serpent Sting"); step(G)
    has(fc(G).verdict("sting_add"), "mixed (1 of 2)", "the rotation gave up on one")
    G.fire("jcore.cast.sent", { spell_id = G.id_of("Serpent Sting"), target = G.target })
    our_cast(G, "Serpent Sting"); step(G)
    has(fc(G).verdict("sting_add"), "mixed (1 of 2)", "at your own target: not counted")
end }

T[#T + 1] = { "Feign Death against a player's cast at you: its interrupted event is a yes, its success a no; nothing heard is no answer", function()
    local G = bundle()
    near(G, WARRIOR, 20); fighting(G)
    G.player.get_target = function() return G.target end
    G.row.casting = { spell_id = G.id_of("Frostbolt"), remaining = 1.5, interruptible = true }
    step(G)
    local f = G.S.foes[G.target.guid]
    assert(f and f.casting and f.casting.at_me, "the cast at you is on its bar")
    our_cast(G, "Feign Death"); step(G)
    G.fire("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", { "target", 0, G.id_of("Frostbolt") })
    step(G)
    has(fc(G).verdict("feign_cast"), "yes (1 of 1)", "it failed")
end }

T[#T + 1] = { "Forever: our control's duration on a player, by its place in the chain -- the diminishing returns measured; the page says the checks and the durations", function()
    local G = bundle({ client = { forever = true, combat_log = false, version = "Forever", exact = "x" } })
    near(G, ROGUE, 10); fighting(G)
    G.player.get_target = function() return G.target end
    step(G)
    G.fire("jcore.game_event.UNIT_AURA", { "added", "target", 1, 3355, "Freezing Trap Effect", 0, 10, 0, "player", false, true })
    G.clock = G.clock + 12; step(G)
    G.fire("jcore.game_event.UNIT_AURA", { "added", "target", 2, 3355, "Freezing Trap Effect", 0, 5, 0, "player", false, true })
    step(G)
    local dr = G.I.fieldcheck.lines()
    has(table.concat(dr, " | "), "Freezing Trap Effect #1 10.0s (1), #2 5.0s (1)", "first and second in the chain")
    -- Another player's trap is not ours to measure.
    G.fire("jcore.game_event.UNIT_AURA", { "added", "target", 3, 3355, "Freezing Trap Effect", 0, 20, 0, "Hunter-2", false, true })
    step(G)
    has(table.concat(G.I.fieldcheck.lines(), " | "), "#2 5.0s (1)", "unchanged")
    -- The debrief's page carries the checks.
    has(table.concat(G.I.debrief.lines(), " | "), "Field checks -- a trap laid in melee springs under the mob: not seen yet", "on the page")
end }

return T

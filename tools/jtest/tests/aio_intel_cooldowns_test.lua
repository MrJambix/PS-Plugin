-- Jambix AIO: the PvP cooldown ledger and economy (PVP_INTEL_PLAN.md, Stage
-- 3 / brief Phase 5) -- modules/react/intel/cooldowns.lua on the picture,
-- with pvp_data.lua (the Era half: the bundle's client is Vanilla), inside
-- the reaction engine's tick on a scripted clock. The bundle is
-- tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: nothing seen is unknown, never "ready"; a cast
-- event starts the clock from the client's own table, an aura is a weaker
-- proxy, a started cast that was interrupted went on no cooldown; a shared
-- category keeps its sisters down; the estimate fades once the cooldown
-- has run out; a protection already up makes a second defensive pointless
-- and the existing rules hold it -- never under critical health; the last
-- control is kept for a melee player closing; the window reads the ledger.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR, HUNTER = B.ROGUE, B.PRIEST, B.WARRIOR, 3

--- The bundle's hunter with an escape and a control in its book.
local function bundle(opts)
    local G = B.bundle(opts)
    G.class.escapes = { "Wing Clip", "Feign Death" }
    G.known["Wing Clip"] = true
    G.roles = {
        defensive = { { name = "Feign Death" }, { name = "Deterrence" } },
        cc = { { name = "Freezing Trap" } }, disorient = { { name = "Scatter Shot" } },
        slow = { { name = "Concussive Shot" }, { name = "Wing Clip" } },
    }
    return G
end

local rogue = B.rogue

local function warrior(G, dist)
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = dist or 3, dist or 3
end

local function C(G) return G.I.cooldowns end
local function ledger(G, guid) local f = G.S.foes[guid or G.target.guid] return f and f.cds or {} end
local function cast(G, token, name) G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { token, "Cast-x", G.id_of(name) }) end

local T = {}

T[#T + 1] = { "the tables are loaded for the client, and a name never seen is unknown, never ready", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local K = C(G)
    assert_eq(K.has_data, true, "pvp_data for the Vanilla client")
    assert_eq(K.client, "vanilla", "the Era half")
    assert(K.build and K.build:find("^1%.15"), "the Era build: " .. tostring(K.build))
    local sprint = K.fact("Sprint", "ROGUE")
    assert(sprint and sprint.cd == 300, "Sprint's cooldown from the table: " .. tostring(sprint and sprint.cd))
    assert_eq(K.seen(G.S, G.target.guid, "Sprint"), nil, "never seen")
    assert_eq(K.ready_in(G.S, G.target.guid, "Sprint"), nil, "so not known to be ready")
    assert_eq(G.S.cds.tracked, 0, "nothing tracked")
end }

T[#T + 1] = { "a cast event starts the clock from the client's table, at full confidence, and the readout says so", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Sprint")
    G.tick()
    local e = ledger(G)["Sprint"]
    assert(e ~= nil, "in the ledger")
    assert_eq(e.state, "down", "down")
    assert_near(e.ready_in, 300, 0.2, "back in 300 s")
    assert_eq(e.conf, 1.0, "a cast event")
    assert_eq(e.source, "UNIT_SPELLCAST_SUCCEEDED", "from the event")
    assert_eq(C(G).ready_in(G.S, G.target.guid, "Sprint") > 299, true, "the question answers the seconds")
    has(G.I.lines()[2], "Sprint back 300s (cast 1.0)", "the readout")
    G.run(10)
    assert_near(ledger(G)["Sprint"].ready_in, 290, 0.3, "ten seconds later")
    assert_eq(G.S.cds.down, 1, "one down")
end }

T[#T + 1] = { "an aura appearing is the proxy, at 0.7; a cast that started and was interrupted went on no cooldown", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate3", 3, G.id_of("Evasion"), "Evasion", 0, 15, 0, nil, true, false })
    G.tick()
    local e = ledger(G)["Evasion"]
    assert(e ~= nil and e.state == "down", "Evasion down from its buff")
    assert_near(e.conf, 0.7, 0.01, "a proxy")
    has(G.I.lines()[2], "Evasion back", "the readout")
    has(G.I.lines()[2], "(aura 0.7)", "names the proxy")
    -- A priest starts a Mind Control and is kicked.
    local priest = unit(G, "Player-1-00000005", { name = "Priestly", player = true })
    priest.get_class = function() return PRIEST end
    G.by_guid["nameplate5"] = priest
    G.rows[#G.rows + 1] = G.row_for(priest, { dist = 20 })
    G.fire("jcore.game_event.UNIT_SPELLCAST_START", { "nameplate5", "Cast-y", G.id_of("Mind Control") })
    G.tick()
    local mc = ledger(G, priest.guid)["Mind Control"]
    assert(mc ~= nil, "the start is kept")
    assert_near(mc.conf, 0.5, 0.01, "a started cast may still be stopped")
    G.clock = G.clock + 0.5
    G.fire("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", { "nameplate5", "Cast-y", G.id_of("Mind Control") })
    G.tick()
    mc = ledger(G, priest.guid)["Mind Control"]
    assert_eq(mc.state, "interrupted", "interrupted: no cooldown spent")
    assert_eq(C(G).ready_in(G.S, priest.guid, "Mind Control"), nil, "not known to be back")
end }

T[#T + 1] = { "a shared category: the hunter's Frost Trap keeps its Freezing Trap down (Era: 15 s, category 411)", function()
    local G = bundle()
    G.target.get_class = function() return HUNTER end
    G.row.dist, G.distance = 20, 20
    G.tick()
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Freezing Trap")
    G.run(0.5)
    cast(G, "nameplate3", "Frost Trap")
    G.tick()
    local freezing, frost = ledger(G)["Freezing Trap"], ledger(G)["Frost Trap"]
    assert(freezing and frost, "both in the ledger")
    assert_eq(freezing.category, frost.category, "one category")
    assert_near(freezing.ready_in, frost.ready_in, 0.01, "the trap laid first is held by the second's category cooldown")
    assert_near(frost.ready_in, 15, 0.2, "fifteen seconds")
end }

T[#T + 1] = { "a name the tables do not carry: seen, but its cooldown unknown and never 'ready'", function()
    local G = bundle()
    rogue(G)
    G.tick()
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Mysterious Zap")
    G.tick()
    local e = ledger(G)["Mysterious Zap"]
    assert(e ~= nil, "kept")
    assert_eq(e.state, "unknown", "unknown")
    assert_eq(C(G).ready_in(G.S, G.target.guid, "Mysterious Zap"), nil, "not ready, not down: unknown")
    has(G.I.lines()[2], "Mysterious Zap cooldown unknown", "the readout says so")
    assert_eq(G.S.cds.unknown, 1, "counted")
end }

T[#T + 1] = { "once the cooldown has run out the estimate fades: it may have gone again unseen", function()
    local G = bundle()
    G.target.get_class = function() return 8 end          -- a mage
    G.row.dist, G.distance = 25, 25
    G.tick()
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Blink")
    G.tick()
    assert_near(ledger(G)["Blink"].ready_in, 15, 0.2, "Blink: 15 s on Era")
    G.clock = G.clock + 16
    G.tick()
    local e = ledger(G)["Blink"]
    assert_eq(e.state, "ready", "run out")
    assert_eq(C(G).ready_in(G.S, G.target.guid, "Blink"), 0, "back")
    assert(e.conf_now > 0.9 and e.conf_now < 1, "still nearly sure: " .. e.conf_now)
    has(G.I.lines()[2], "Blink ready?", "the readout's question mark")
    G.clock = G.clock + 30
    G.tick()
    assert_eq(ledger(G)["Blink"].conf_now, 0, "faded to nothing after 30 s")
end }

T[#T + 1] = { "the answer to a burst: cheapest first; with Deterrence up, preserve; and the burst rule holds a self-defensive", function()
    local G = bundle()
    -- The PvP hunter's own clip would take the lane every tick; the rule
    -- under test is the every-class "answer the burst".
    G.settings.rot_hunter_pvp_alpha = false
    warrior(G, 3)
    G.known["Deterrence"], G.known["Freezing Trap"] = true, true
    G.aura(G.target.guid, "Recklessness", 10)
    G.tick()
    local K = C(G)
    local ok, why = K.sufficient("physical")
    assert_eq(ok, false, "nothing up")
    has(why, "nothing up against physical", "said")
    local list = K.cheapest("physical", G.S)
    assert_eq(list[1].name, "Freezing Trap", "the trap is the cheapest answer (15 s against Deterrence's 300)")
    assert_eq(G.S.cds.answer.verdict, "cheapest", "the verdict")
    has(G.I.lines()[2], "Recklessness: cheapest Freezing Trap", "the readout")
    -- With nothing covering, the burst rule did press Deterrence: that is
    -- the count to hold from now on.
    local pressed = G.sent("Deterrence")
    assert(pressed >= 1, "Deterrence went out with nothing up")
    -- Deterrence up: preserve.
    G.aura("player", "Deterrence", 20)
    G.clock = G.clock + 0.1
    G.tick()
    ok, why = K.sufficient("physical")
    assert_eq(ok, true, "covered")
    has(why, "Deterrence covers 85% of physical for 19.9s", "said with the time")
    assert_eq(G.S.cds.answer.verdict, "preserve", "preserve")
    assert_near(G.S.cds.protection.left, 19.9, 0.2, "with the seconds left")
    -- The burst rule's Deterrence is held, with the reason in the journal
    -- (past the engine's 4 s "burst answered" memory and the journal's 3 s
    -- throttle on a repeated refusal).
    G.unready["Deterrence"] = nil                     -- ready again, as the test's client never cools it
    G.run(8.2)
    assert_eq(G.sent("Deterrence"), pressed, "Deterrence not pressed again")
    local lines = table.concat(G.React.log_lines(40), "\n")
    has(lines, "already covered: Deterrence covers 85% of physical", "the hold is in the journal")
    -- And me.protected reads it.
    local Cm = G.React.custom
    local id = Cm.save({ name = "Covered", importance = "defensive",
        conds = { { mode = "gui", key = "me_protected", op = "is" } },
        actions = { { mode = "gui", kind = "spell", spell = "Wing Clip", target = "target" } } })
    assert(id ~= nil, "saved")
    G.run(0.3)
    local rt = Cm.runtime(id)
    assert(rt and rt.conds[1].ok == true, "me.protected is true")
    -- Under 1.5 s left, no longer sufficient.
    G.clock = G.clock + 11
    G.tick()
    ok = K.sufficient("physical")
    assert_eq(ok, false, "under a second and a half left is not enough: " .. tostring(G.S.cds.protection.left))
end }

T[#T + 1] = { "the core defensive is held the same way, and never under critical health", function()
    local G = bundle()
    rogue(G)
    G.known["Deterrence"] = true
    G.class.defensives = { "Feign Death", "Deterrence" }
    G.aura("player", "Deterrence", 9)
    G.hp = 0.30                                      -- under the defensive line, not critical
    G.tick()
    G.run(0.5)
    assert_eq(G.sent("Deterrence"), 0, "held: Deterrence is already up")
    has(table.concat(G.React.log_lines(40), "\n"), "already covered", "and the journal says why")
    -- Critical: nothing is held.
    G.auras["player"] = nil
    G.aura("player", "Evasion", 9)                   -- a cover of another kind, to keep sufficient() true for melee
    G.hp = 0.15
    G.clock = G.clock + 7
    G.run(0.5)
    assert(G.sent("Deterrence") >= 1, "critical health: the defensive goes")
end }

T[#T + 1] = { "reserve: the last ready control is kept for a melee player closing, and sorts last among the answers", function()
    local G = bundle()
    warrior(G, 12)
    G.known["Freezing Trap"], G.known["Deterrence"] = true, true
    G.row.time_to_reach, G.row.closing = 3.0, 4
    G.tick()
    local R = G.S.cds.reserved
    assert(R["Freezing Trap"] ~= nil, "the trap is reserved")
    has(R["Freezing Trap"], "Enemy closing (3.0s): the last control ready", "with the reason")
    has(G.I.lines()[2], "keep Freezing Trap", "the readout")
    local list = C(G).cheapest("physical", G.S)
    assert_eq(list[#list].name, "Freezing Trap", "the reserved one sorts last")
    assert_eq(list[1].name, "Deterrence", "Deterrence first now")
    -- Once it is here, nothing is reserved for its arrival.
    G.row.dist, G.distance, G.row.time_to_reach = 3, 3, 0
    G.tick()
    assert_eq(G.S.cds.reserved_n, 0, "nothing reserved with the warrior in melee")
end }

T[#T + 1] = { "reserve: the last ready defensive is kept for a burst the ledger says is back soon", function()
    local G = bundle()
    warrior(G, 3)
    G.known["Deterrence"] = true
    G.tick()
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Recklessness")
    G.tick()
    assert_eq(G.S.cds.reserved_n, 0, "nothing reserved while the burst is 30 minutes away")
    G.clock = G.clock + 1792
    G.tick()
    assert_near(ledger(G)["Recklessness"].ready_in, 8, 0.2, "back in 8 s")
    assert(G.S.cds.reserved["Deterrence"] ~= nil, "Deterrence reserved")
    has(G.S.cds.reserved["Deterrence"], "Recklessness back in 8s", "with the reason")
end }

T[#T + 1] = { "the window's conditions and functions read the ledger", function()
    local G = bundle()
    rogue(G)
    G.known["Arcane Shot"] = true
    G.tick()
    local Cm = G.React.custom
    assert_eq(Cm.cond_code({ mode = "gui", key = "t_cd_seen", op = "is", value = "Sprint" }), 'enemy_cd_seen("Sprint")', "the seen row")
    assert_eq(Cm.cond_code({ mode = "gui", key = "t_cd_ready_in", op = "<=", value = "Sprint", num = 5 }), 'enemy_cd_ready_in("Sprint") <= 5', "the ready row")
    local id = Cm.save({ name = "Sprinted", importance = "defensive",
        conds = { { mode = "lua", code = 'enemy_cd_seen("Sprint") and enemy_cd_ready_in("Sprint") > 100' } },
        actions = { { mode = "gui", kind = "spell", spell = "Arcane Shot", target = "target" } } })
    assert(id ~= nil, "saved")
    G.run(0.3)
    assert_eq(G.sent("Arcane Shot"), 0, "not before Sprint is seen")
    local rt = Cm.runtime(id)
    assert(rt and rt.conds[1].ok == false, "the condition reads false: " .. tostring(rt and rt.conds[1].shown))
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Sprint")
    G.run(0.4)
    assert(G.sent("Arcane Shot") >= 1, "fires once Sprint is seen and down")
end }

T[#T + 1] = { "without pvp_data every cooldown is unknown, and the readout says the file is missing", function()
    -- require() takes a false entry as "not loaded": an empty table stands in.
    local saved = package.loaded["jambix_aio/modules/pvp_data"]
    package.loaded["jambix_aio/modules/pvp_data"] = {}
    local G = bundle()
    package.loaded["jambix_aio/modules/pvp_data"] = saved
    rogue(G)
    G.tick()
    assert_eq(C(G).has_data, false, "no data")
    G.by_guid["nameplate3"] = G.target
    cast(G, "nameplate3", "Sprint")
    G.tick()
    assert_eq(ledger(G)["Sprint"].state, "unknown", "seen, cooldown unknown")
    has(G.I.lines()[2], "no pvp_data for vanilla: cooldowns unknown", "said")
end }

return T

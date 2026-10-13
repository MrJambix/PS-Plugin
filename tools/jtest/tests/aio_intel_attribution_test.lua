-- Jambix AIO: whose an enemy's row is, and the fight's clock (the second
-- live batch, 2026-10-13: seventeen fights with players read back from the
-- network's issues) -- modules/react/intel/state.lua (M.own), cooldowns,
-- predict, debrief, episodes and central inside the reaction engine's tick
-- on a scripted clock. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: a priest's Power Word: Shield on a rogue is on the
-- rogue (it is still seen) but is not the rogue's -- no cooldown of its, no
-- habit, not what it used; the rogue's own Evasion is all three; a spell of
-- another class put on a player by a token read late (an Aimed Shot on a
-- paladin) is set aside the same way, while a paladin's Divine Protection
-- with no caster known still counts; the fight's Brier score is a mean;
-- an episode is timed from the fight it is sent with and one from before
-- it is dropped; the duration sent is whole seconds rounded up, and the
-- record says its revision (2: checked and timed).

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST = B.ROGUE, B.PRIEST
local PALADIN = 2

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
    G.by_guid["nameplate1"] = G.target
    local files = {}
    G.P.ctx.storage = {
        read_json = function(name) return files[name] end,
        write_json = function(name, v) files[name] = v return true end,
    }
    G.files = files
    return G
end

local function fighting(G, class)
    G.target.get_class = function() return class end
    G.row.dist, G.distance = 3, 3
    G.in_combat, G.fight_age = true, 4
    G.row.in_combat, G.row.targeting_me = true, true
end

local function step(G, dt)
    G.clock = G.clock + (dt or 0.3)
    G.tick()
end

local function kill_target(G)
    G.target.dead, G.row.dead, G.health[G.target.guid] = true, true, 0
    G.row.hp = 0
end

--- An aura landing on the target: source is the caster's token (nil: unknown).
local function aura_on_target(G, name, source)
    G.fire("jcore.game_event.UNIT_AURA", { "added", "nameplate1", 0, G.id_of(name), name, 1, 10, 0, source, true, false })
end

local function their_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) })
end

local function row_named(f, name)
    for i = #f.recent, 1, -1 do if f.recent[i].name == name then return f.recent[i] end end
    return nil
end

local function a_priest(G, fields)
    local priest = unit(G, "Player-1-00000005", { name = "Priestly", player = true })
    priest.get_class = function() return PRIEST end
    G.by_guid["nameplate5"] = priest
    G.rows[#G.rows + 1] = G.row_for(priest, fields or { dist = 20 })
    return priest
end

--- Every row but the target's gone from the picture.
local function others_leave(G)
    for i = #G.rows, 1, -1 do if G.rows[i] ~= G.row then table.remove(G.rows, i) end end
end

--- Steps until the debrief closes the fight (at most a minute).
local function until_closed(G)
    for _ = 1, 200 do
        if not G.I.debrief.T.open then return end
        step(G)
    end
end

local function own(G, f, row) return G.I.state.own(f, row) end
local function last_fight(G) return G.I.debrief.T.last end

local T = {}

T[#T + 1] = { "a priest's Power Word: Shield on a rogue is on the rogue but not its own: no cooldown, no habit, not what it used", function()
    local G = bundle()
    fighting(G, ROGUE)
    a_priest(G)
    step(G)
    G.row.hp = 0.3
    aura_on_target(G, "Power Word: Shield", "nameplate5")
    step(G)
    local f = G.S.foes[G.target.guid]
    local row = row_named(f, "Power Word: Shield")
    assert(row ~= nil, "the shield is seen on the rogue")
    assert_eq(row.by, "other", "cast by another unit")
    assert_eq(own(G, f, row), false, "not the rogue's doing")
    assert_eq(G.S.events.not_own, 1, "counted as not its own")
    assert_eq(f.cds["Power Word: Shield"], nil, "no cooldown of the rogue's")
    local cats = f.pat and f.pat.cats or {}
    local dt = cats.defensive_threshold
    assert_eq(dt and dt.hits or 0, 0, "no defensive habit hit for the rogue")
    -- Its own Evasion, put up by itself.
    aura_on_target(G, "Evasion", "nameplate1")
    step(G)
    row = row_named(f, "Evasion")
    assert_eq(row.by, "self", "its own")
    assert_eq(own(G, f, row), true, "the rogue's doing")
    assert(f.cds["Evasion"] ~= nil, "Evasion's cooldown is the rogue's")
    assert_eq((f.pat.cats.defensive_threshold or {}).hits or 0, 1, "and its defensive habit")
    kill_target(G); others_leave(G); step(G)
    until_closed(G)
    local fight = last_fight(G)
    assert(fight ~= nil, "the fight closed")
    local used = fight.foes[G.target.guid].used
    assert_eq(used["Evasion"], 1, "it used Evasion")
    assert_eq(used["Power Word: Shield"], nil, "not the priest's shield")
    assert_eq(fight.feeds.not_own, 1, "the fight's feeds say one row was not its own")
    local moments = {}
    for i = 1, #fight.moments do moments[#moments + 1] = fight.moments[i].text end
    has(table.concat(moments, " | "), "gets Power Word: Shield from another", "the moment says whose")
    has(table.concat(G.I.debrief.lines(), " || "), "1 not the player's own", "the page's feeds line")
end }

T[#T + 1] = { "a token read late: an Aimed Shot on a paladin is set aside; its own Divine Protection with no caster known counts", function()
    local G = bundle()
    fighting(G, PALADIN)
    step(G)
    their_cast(G, "Aimed Shot")
    step(G)
    local f = G.S.foes[G.target.guid]
    assert_eq(f.class, "PALADIN", "a paladin")
    local row = row_named(f, "Aimed Shot")
    assert(row ~= nil, "the row is kept (what is on it, for the rest)")
    assert_eq(G.I.state.owner_of("Aimed Shot"), "HUNTER", "a hunter's spell in the client's tables")
    assert_eq(own(G, f, row), false, "not the paladin's")
    assert_eq(f.cds["Aimed Shot"], nil, "no hunter cooldown on a paladin")
    aura_on_target(G, "Divine Protection", nil)
    step(G)
    row = row_named(f, "Divine Protection")
    assert_eq(row.by, nil, "the caster unknown")
    assert_eq(own(G, f, row), nil, "nothing says it is another's")
    assert(f.cds["Divine Protection"] ~= nil, "so it is the paladin's cooldown")
    assert_eq(G.I.state.owner_of("Shoot"), nil, "a name several classes have names no owner")
    kill_target(G); step(G)
    local used = last_fight(G).foes[G.target.guid].used
    assert_eq(used["Divine Protection"], 1, "it used Divine Protection")
    assert_eq(used["Aimed Shot"], nil, "not an Aimed Shot")
end }

T[#T + 1] = { "the fight's Brier score is the mean over its forecasts, the sum kept beside it", function()
    local G = bundle()
    fighting(G, ROGUE)
    step(G)
    -- Four forecasts scored during the fight: two right, squared errors 1.0 in all.
    G.S.predict.ledger["test|ROGUE|defensive_threshold"] = { forecasts = 4, right = 2, brier = 1.0,
        bands = { low = { n = 0, hits = 0 }, mid = { n = 0, hits = 0 }, high = { n = 0, hits = 0 } } }
    step(G)
    kill_target(G); step(G)
    local pr = last_fight(G).predictions
    assert_eq(pr.forecasts, 4, "four forecasts")
    assert_near(pr.brier_sum, 1.0, 1e-9, "the sum")
    assert_near(pr.brier, 0.25, 1e-9, "the mean: a coin's")
    local found = false
    for _, l in ipairs(last_fight(G).lessons) do
        if l.code == "forecasts" then found = true; has(l.text, "(Brier 0.25)", "the lesson's line") end
    end
    assert(found, "the forecasts lesson")
end }

local function fake_episode(t_open, horizon)
    return {
        id = "abcdef0123456789abcdef01", type = "kill_opportunity", enemy_class = "ROGUE", t_open = t_open, t = 99, horizon = horizon,
        trigger = { text = "the player at 16%", observed = true, source = "row" },
        before = { hp = 1, attackers = 1, controlled = false }, after = { hp = 1, attackers = 1, controlled = false },
        prediction = { outcome = "NONE", reliability = 0, sure = false },
        recommendation = { action = "", move = "none", outcome = "UNKNOWN" },
        actions = {}, moved = false, flags = {},
        result = { primary = "NO_MEASURABLE_CHANGE", all = { "NO_MEASURABLE_CHANGE" } },
        quality = {},
    }
end

T[#T + 1] = { "an episode is timed from the fight it is sent with; one whose window closed before the fight began is dropped", function()
    local G = bundle()
    fighting(G, PALADIN)
    step(G)
    local E = G.I.episodes
    -- (on the fight's first tick the episodes run before the debrief opens
    -- it: no start then, and close_fight times them from the real one)
    assert_eq(E.T.fight_start, nil, "the first tick: none yet, never a stale one")
    step(G)
    local first = G.I.debrief.T.fight
    assert(first ~= nil and E.T.fight_start == first.started_at, "timed from the fight running")
    -- The fight ends; a player stays in sight, PvP still on, no fight running.
    -- A priest standing by, on no one.
    a_priest(G, { dist = 25, engaged = false, targeting_me = false, activity = "idle", in_combat = false })
    kill_target(G); step(G)
    G.in_combat = false
    until_closed(G)
    assert_eq(G.I.debrief.T.open, false, "the fight closed")
    step(G)
    if G.S.active then
        local running = G.I.debrief.T.open and G.I.debrief.T.fight or nil
        assert_eq(E.T.fight_start, running and running.started_at or nil, "the running fight's start or none")
        assert(E.T.fight_start ~= first.started_at, "never the last fight's start")
    end
    local start = 500
    E.T.closed[#E.T.closed + 1] = fake_episode(start - 40, 8)     -- between fights, long before
    E.T.closed[#E.T.closed + 1] = fake_episode(start - 3, 8)      -- just before, its window into the fight
    E.T.closed[#E.T.closed + 1] = fake_episode(start + 6.4, 8)    -- in the fight
    local list, summary = E.close_fight(G.S, start + 10, start)
    assert_eq(#list, 2, "the one from before the fight is no part of it")
    assert_eq(list[1].t, 0, "the one just before starts the fight at 0")
    assert_eq(list[2].t, 6, "the one in the fight, from the fight's start")
    assert_eq(summary.dropped_outside, 1, "the dropped one counted")
    assert_eq(#E.T.closed, 0, "the slate wiped")
end }

T[#T + 1] = { "the record sent: the duration in whole seconds rounded up, and its attribution checked", function()
    local G = bundle()
    G.files["jambix.aio.central.json"] = { url = "https://db.example/jambix/", key = "k1" }
    G.P.ctx.net = { post_json = function() return true end, get_json = function() return true end }
    G.settings.net_contribute = true
    G.P.ctx.allow_test_upload = true
    fighting(G, ROGUE)
    step(G)
    kill_target(G); step(G, 0.3)
    local fight = last_fight(G)
    assert(fight.duration > 0 and fight.duration < 0.5, "a fight under half a second: " .. tostring(fight.duration))
    local q = G.I.central.queue()
    assert(#q >= 1, "queued")
    local body = q[#q].body
    local lesson = body.lesson or body
    assert_eq(lesson.encounter.duration, 1, "never 0 s for a fight that happened")
    assert_eq(lesson.client.rev, 2, "revision 2: the service knows the record is checked and timed")
end }

return T

-- Jambix AIO: the opponent memory (PVP_INTEL_PLAN.md Stage 14) --
-- modules/react/intel/memory.lua with the predictor, across two "sessions"
-- (two bundles sharing one fake disk) on a scripted clock
-- (tools/jtest/mock/intel_bundle.lua).
--
-- What these hold it to: a fight's players and their habits are written
-- when it closes; met again in a new session, a player's habit starts from
-- what was remembered of it, said as your own past fights -- and is still
-- not sure until it is seen again; a player never met starts from its
-- class in your own fights once enough of them say so; an old count fades;
-- a session never counts its own chances twice; the switch off forgets.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local WARRIOR, ROGUE = B.WARRIOR, B.ROGUE

local DAY = 86400

local function bundle(disk, wall)
    local G = B.bundle()
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.by_guid["nameplate1"] = G.target
    G.P.ctx.storage = { read_json = function(n) return disk[n] end, write_json = function(n, v) disk[n] = v return true end }
    G.wall = wall or 1700000000
    _G.core.get_server_time = function() return G.wall end
    return G
end
local function step(G, dt) G.clock = G.clock + (dt or 0.3) G.tick() end
local function opener_fights(G, n, opener)
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance = 20, 20
    G.in_combat, G.row.in_combat = false, false
    step(G)
    for _ = 1, n do
        G.in_combat, G.row.in_combat = true, true
        step(G)
        G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(opener) })
        step(G)
        G.clock = G.clock + 8
        step(G)
        G.in_combat, G.row.in_combat = false, false
        step(G, 1)
    end
end

local T = {}

T[#T + 1] = { "remembered: the players of a fight and their habits go to disk", function()
    local disk = {}
    local G = bundle(disk)
    opener_fights(G, 3, "Charge")
    local n = G.I.memory.remember(G.S)
    assert_eq(n, 1, "one player")
    local e = disk["jambix.aio.opponents.json"].players[G.target.guid]
    assert(e, "under its guid")
    assert_eq(e.class, "WARRIOR", "its class")
    assert_eq(e.cats.same_opener.hits, 2, "two openers kept")
    assert_eq(e.cats.same_opener.total, 2, "of two chances")
    -- Written again the same session: replaced, never added twice.
    G.I.memory.remember(G.S)
    assert_eq(disk["jambix.aio.opponents.json"].players[G.target.guid].cats.same_opener.total, 2, "not counted twice")
end }

T[#T + 1] = { "met again in a new session: its habit starts from what you remember, said so -- and is not sure until seen again", function()
    local disk = {}
    local G = bundle(disk)
    opener_fights(G, 5, "Charge")
    G.I.memory.remember(G.S)
    -- Tomorrow.
    local H = bundle(disk, G.wall + DAY)
    local p, n, src = H.I.memory.prior_for(G.target.guid, "WARRIOR", "same_opener")
    assert_eq(src, "this player", "its own memory")
    assert(p > 0.75, "a high rate: " .. tostring(p))
    assert(n > 3, "behind it: " .. tostring(n))
    -- In the fight: the habit starts there, not sure without a fresh chance.
    H.target.get_class = function() return WARRIOR end
    H.row.dist, H.distance = 20, 20
    H.in_combat, H.row.in_combat = true, true
    step(H)
    H.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, H.id_of("Charge") })
    step(H)
    local e = H.S.foes[H.target.guid].predict
    e = e and e.same_opener or nil
    if e then
        assert(not e.sure, "one fresh sighting with a memory: not sure yet")
        has(e.why, "your own past fights with this player", "said where the start came from")
    end
end }

T[#T + 1] = { "a player never met starts from its class in your own fights, once enough of them say so", function()
    local disk = { ["jambix.aio.opponents.json"] = { players = {
        ["Player-1-AAAA"] = { name = "A", class = "ROGUE", at = 1700000000, cats = { targeting_pet = { hits = 4, total = 4 } } },
        ["Player-1-BBBB"] = { name = "B", class = "ROGUE", at = 1700000000, cats = { targeting_pet = { hits = 3, total = 3 } } },
        ["Player-1-CCCC"] = { name = "C", class = "MAGE", at = 1700000000, cats = { targeting_pet = { hits = 5, total = 5 } } },
    } } }
    local G = bundle(disk, 1700000000)
    local p, n, src = G.I.memory.prior_for("Player-1-NEW", "ROGUE", "targeting_pet")
    assert_eq(src, "its class", "the class's")
    assert_near(n, 7, 0.01, "seven chances over two rogues")
    assert_near(p, (7 + 2 * 0.5) / (7 + 2), 0.001, "the rate with the prior's weight")
    -- One mage is not enough for a class.
    local q = G.I.memory.prior_for("Player-1-NEW2", "MAGE", "targeting_pet")
    assert_eq(q, nil, "one player says nothing of its class")
end }

T[#T + 1] = { "an old count fades: two weeks on, a quarter of it", function()
    local disk = { ["jambix.aio.opponents.json"] = { players = {
        ["Player-1-OLD"] = { name = "Old", class = "WARRIOR", at = 1700000000, cats = { same_opener = { hits = 8, total = 8 } } },
    } } }
    local G = bundle(disk, 1700000000 + 14 * DAY)
    local _, n = G.I.memory.prior_for("Player-1-OLD", "WARRIOR", "same_opener")
    assert_near(n, 2, 0.01, "8 chances at a quarter")
end }

T[#T + 1] = { "the switch off: nothing remembered, nothing recalled", function()
    local disk = { ["jambix.aio.opponents.json"] = { players = {
        ["Player-1-X"] = { name = "X", class = "WARRIOR", at = 1700000000, cats = { same_opener = { hits = 5, total = 5 } } },
    } } }
    local G = bundle(disk)
    G.settings.intel_memory = false
    assert_eq((G.I.memory.prior_for("Player-1-X", "WARRIOR", "same_opener")), nil, "nothing recalled")
    assert_eq(G.I.memory.remember(G.S), 0, "nothing written")
end }

T[#T + 1] = { "a fight closing writes its players, the dead among them (the picture drops a dead player at once); logging out writes too", function()
    local disk = {}
    local G = bundle(disk)
    opener_fights(G, 3, "Charge")                         -- habits counted
    G.in_combat, G.row.in_combat, G.row.targeting_me = true, true, true
    step(G); step(G, 1.2)
    G.target.dead, G.row.dead, G.health[G.target.guid], G.row.hp = true, true, 0, 0
    step(G); step(G)
    assert_eq(G.I.debrief.T.open, false, "the fight closed")
    local book = disk["jambix.aio.opponents.json"]
    assert(book and book.players[G.target.guid], "the dead player written when the fight closed")
    -- Logging out.
    local disk2 = {}
    local H = bundle(disk2)
    opener_fights(H, 3, "Charge")
    H.fire("jcore.game_event.PLAYER_LOGOUT", {})
    assert(disk2["jambix.aio.opponents.json"] and disk2["jambix.aio.opponents.json"].players[H.target.guid], "written at logout")
end }

return T

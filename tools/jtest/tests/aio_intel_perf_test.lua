-- Jambix AIO: what the PvP intelligence layer costs (PVP_INTEL_PLAN.md
-- Stage 12, the brief's Phase 17) -- the reaction engine's tick at sixty
-- frames a second for two seconds, with ten enemy players and four allies,
-- the layer on against the layer off, every call into a game object and
-- every sight ray counted (tools/jtest/mock/intel_bundle.lua).
--
-- What these hold it to: the layer's own calls into the game stay under a
-- ceiling a frame; each module reads at its own pace (the kill window five
-- times a second, the team four, the history twice), never every frame; at
-- most ten players are carried; line of sight goes through geometry.sight
-- only, at most twice a second, and the client's is_line_of_sight is never
-- called (it crashes Forever); the stale state goes on the events that make
-- it stale.
--
-- JTEST_PERF=1 prints the breakdown by call.

local B = require("mock/intel_bundle")
local assert_eq = B.assert_eq
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR
local MAGE = 8

local FPS, SECONDS = 60, 2

local function fight(opts)
    local G = B.bundle(opts)
    hunter_ranges(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.known["Arcane Shot"], G.known["Scatter Shot"], G.known["Wing Clip"] = true, true, true
    G.in_combat, G.fight_age = true, 10
    G.target.get_class = function() return WARRIOR end
    G.row.dist, G.distance, G.row.hp = 12, 12, 0.6
    G.health[G.target.guid] = 0.6
    -- Eleven more enemy players (one past the cap of ten), at 6 to 36 yd.
    local classes = { ROGUE, PRIEST, MAGE, WARRIOR, ROGUE, PRIEST, MAGE, WARRIOR, ROGUE, MAGE, PRIEST }
    for i = 1, #classes do
        local u = unit(G, string.format("Player-1-0000050%02d", i), { name = "Foe" .. i, player = true })
        local cls = classes[i]
        u.get_class = function() return cls end
        local r = G.row_for(u, { dist = 6 + i * 3, targeting_me = i % 3 == 0, hp = 0.3 + (i % 5) * 0.1 })
        G.rows[#G.rows + 1] = r
        G.health[u.guid] = r.hp
    end
    G.rows[3].casting = G.casting("Flash Heal", 30, 30)
    -- Four allies.
    G.group.in_group = true
    G.dist = G.dist or {}
    local members = {}
    for i = 1, 4 do
        local a = unit(G, string.format("Player-1-0000060%02d", i), { name = "Ally" .. i, player = true, hostile = false })
        G.dist[a.guid], G.health[a.guid] = 8 + i * 4, 0.9
        members[i] = a
    end
    G.members, G.healer = members, members[1]
    G.with_sight(true)
    return G
end

-- --- the counter ------------------------------------------------------------------

local function counter(G)
    local C = { n = 0, by = {}, los = 0 }
    local function tally(name)
        C.n = C.n + 1
        C.by[name] = (C.by[name] or 0) + 1
    end
    -- Every method of every game object.
    for _, u in pairs(G.by_guid) do
        if type(u) == "table" then
            local names = {}
            for k, v in pairs(u) do if type(v) == "function" then names[#names + 1] = k end end
            for i = 1, #names do
                local k = names[i]
                local fn = u[k]
                u[k] = function(...) tally("obj:" .. k) return fn(...) end
            end
        end
    end
    -- The client's own line of sight: never to be called.
    _G.core.is_line_of_sight = function() C.los = C.los + 1 return true end
    return C
end

local function play(G, C)
    local runs = { kill = 0, team = 0, history = 0 }
    local last = { kill = G.I.kill.T.at, team = G.I.team.T.at, history = G.I.history.T.at }
    local start_n, start_sight = C.n, G.sight_calls
    for _ = 1, FPS * SECONDS do
        G.clock = G.clock + 1 / FPS
        G.tick()
        for k, mod in pairs({ kill = G.I.kill, team = G.I.team, history = G.I.history }) do
            if mod.T.at ~= last[k] then runs[k] = runs[k] + 1 last[k] = mod.T.at end
        end
    end
    return (C.n - start_n) / (FPS * SECONDS), (G.sight_calls - start_sight), runs
end

local T = {}

T[#T + 1] = { "ten enemy players and four allies at 60 fps: the layer's own calls into the game stay under a ceiling a frame; each module at its own pace", function()
    -- The layer off: the engine's own cost.
    local Off = fight()
    Off.settings.intel_enabled = false
    local Coff = counter(Off)
    Off.tick()
    local off_per_frame = play(Off, Coff)
    -- The layer on.
    local On = fight()
    local Con = counter(On)
    On.tick()
    local on_per_frame, sight, runs = play(On, Con)
    local own = on_per_frame - off_per_frame
    if os and os.getenv and os.getenv("JTEST_PERF") == "1" then
        print(string.format("  off %.1f / frame, on %.1f / frame, the layer's own %.1f; sight %d in %d s; runs kill %d team %d history %d",
            off_per_frame, on_per_frame, own, sight, SECONDS, runs.kill, runs.team, runs.history))
        local list = {}
        for k, v in pairs(Con.by) do list[#list + 1] = { k, v } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        for i = 1, math.min(12, #list) do print(string.format("    %-28s %6d", list[i][1], list[i][2])) end
    end
    -- Measured 1.4 (2026-10-12): the debrief's death check was 22 a frame before
    -- lib.unit_dead kept its answer a quarter second.
    assert(own <= 3, string.format("the layer's own calls a frame: %.1f (ceiling 3)", own))
    -- Each module at its pace (two seconds; one more for the first read).
    assert(runs.kill <= 2 / 0.2 + 1, "the kill window five times a second: " .. runs.kill)
    assert(runs.team <= 2 / 0.25 + 1, "the team four times a second: " .. runs.team)
    assert(runs.history <= 2 / 0.5 + 1, "the history twice a second: " .. runs.history)
    assert(runs.kill >= 1 and runs.team >= 1, "both read")
    -- Line of sight: geometry.sight only, at most twice a second; the client's never.
    assert(sight <= 2 * SECONDS + 1, "sight rays: " .. sight)
    assert_eq(Con.los, 0, "the client's is_line_of_sight never called")
    -- At most ten players carried.
    assert(On.S.foes_n <= 10, "the cap: " .. On.S.foes_n)
end }

T[#T + 1] = { "on Forever: the same, and still no is_line_of_sight", function()
    local G = fight({ client = { forever = true, combat_log = false } })
    local C = counter(G)
    G.tick()
    local _, sight = play(G, C)
    assert_eq(C.los, 0, "never on Forever")
    assert(sight <= 2 * SECONDS + 1, "sight rays: " .. sight)
end }

T[#T + 1] = { "the stale state goes: a new target reads the kill window and the team again at once; a new pet drops the recall; logging out closes the history and forgets every player", function()
    local G = fight()
    G.files = {}
    G.P.ctx.storage = { read_json = function(n) return G.files[n] end, write_json = function(n, v) G.files[n] = v return true end }
    G.row.targeting_me = true
    G.tick()
    for _ = 1, 6 do G.clock = G.clock + 0.3 G.tick() end
    -- A new target: the next tick reads, whatever the pace.
    G.fire("jcore.target.changed", {})
    assert_eq(G.I.kill.T.at, -math.huge, "the kill window reads at once")
    assert_eq(G.I.team.T.at, -math.huge, "the team too")
    -- A new pet: the recall asked of the old one stands down.
    G.S.cc.pet.recall, G.S.cc.pet.guid = true, "old"
    G.fire("jcore.game_event.UNIT_PET", { "player" })
    assert_eq(G.S.cc.pet.recall, false, "the recall dropped")
    G.fire("jcore.game_event.UNIT_PET", { "party1" })        -- someone else's: nothing
    -- Logging out mid-fight.
    assert_eq(G.I.history.T.open, true, "a fight open")
    G.fire("jcore.game_event.PLAYER_LOGOUT", {})
    assert_eq(G.I.history.T.open, false, "closed")
    assert_eq(G.I.history.T.last.summary.outcome, "logged out", "as it stood")
    assert(G.files["jambix.aio.history.json"], "written")
    assert_eq(G.S.foes_n, 0, "every player forgotten")
end }

return T

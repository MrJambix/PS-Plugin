-- Jambix AIO: the fight debrief and the central database (PVP_INTEL_PLAN.md,
-- Stage 11-a; asked for 2026-10-12) -- modules/react/intel/debrief.lua and
-- central.lua inside the reaction engine's tick on a scripted clock, with a
-- fake storage and a fake network. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: a fight with a player is recorded from its first
-- tick to its end -- won, lost, fled, reset -- with what each side used,
-- your lows and the moments; the lessons rest on seconds of a window and
-- name what stayed ready; the log is written and kept; the banner says the
-- outcome and the first lesson once; the fight goes to the central database
-- with every name stripped, the aggregate comes down and seeds a new
-- player's prior and says so; the switches read calm.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

local function fake_storage(G)
    local files = {}
    G.P.ctx.storage = {
        files = files,
        read_json = function(name) return files[name] end,
        write_json = function(name, v) files[name] = v return true end,
    }
    return files
end

local function fake_net(G)
    local net = { posts = {}, gets = {} }
    net.post_json = function(url, payload, opts, cb)
        net.posts[#net.posts + 1] = { url = url, payload = payload, opts = opts, cb = cb }
        return true
    end
    net.get_json = function(url, opts, cb)
        net.gets[#net.gets + 1] = { url = url, opts = opts, cb = cb }
        return true
    end
    G.P.ctx.net = net
    return net
end

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
    G.files = fake_storage(G)
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

local function held_by(G, name, left, caster, kind)
    G.row.control = { spell_id = 1, kind = kind or "incapacitate", breaks = true, name = name, from = "debuff", remaining = left }
    G.aura(G.target.guid, name, left, { caster = caster })
end

local function our_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", 0, G.id_of(name) })
end
local function their_cast(G, name)
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "nameplate1", 0, G.id_of(name) })
end
local function step(G, dt)
    G.clock = G.clock + (dt or 0.3)
    G.tick()
end
local function kill_target(G)
    G.target.dead, G.row.dead, G.health[G.target.guid] = true, true, 0
    G.row.hp = 0
end
local function debrief(G) return G.I.debrief end
local function last(G) return G.I.debrief.T.last end
local function lesson_codes(f)
    local out = {}
    for i = 1, #f.lessons do out[f.lessons[i].code] = f.lessons[i].text end
    return out
end
local function said_debriefs(G)
    local n, last_said = 0, nil
    for _, s in ipairs(G.said) do
        if s.key == "intel_debrief" then n, last_said = n + 1, s end
    end
    return n, last_said
end

local T = {}

T[#T + 1] = { "switched off: no fight recorded", function()
    local G = bundle()
    G.settings.intel_debrief = false
    melee(G, WARRIOR); fighting(G)
    step(G); their_cast(G, "Charge"); step(G)
    kill_target(G); step(G)
    assert_eq(last(G), nil, "nothing recorded")
    assert_eq(debrief(G).T.open, false, "no fight open")
end }

T[#T + 1] = { "a fight won: the record, what they used, what you used, the log written, the banner once, the page's lines", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    assert_eq(debrief(G).T.open, true, "a fight opens with a player on you")
    their_cast(G, "Charge"); step(G)
    their_cast(G, "Hamstring"); step(G)
    their_cast(G, "Hamstring"); step(G)
    G.aura(G.target.guid, "Recklessness", 10); step(G)
    our_cast(G, "Wing Clip"); step(G)
    for _ = 1, 3 do our_cast(G, "Arcane Shot"); step(G) end
    G.hp = 0.55; step(G)
    kill_target(G); step(G)
    local f = last(G)
    assert(f, "the fight closed")
    assert_eq(f.outcome, "won", "won")
    has(f.outcome_why, "Enemy died", "why")
    local r = f.foes[G.target.guid]
    assert_eq(r.class, "WARRIOR", "its class")
    assert_eq(r.used["Hamstring"], 2, "Hamstring twice")
    assert_eq(r.used["Charge"], 1, "Charge once")
    assert_eq(r.used["Recklessness"], 1, "its burst counted")
    assert_eq(r.bursts, 1, "one burst")
    assert_eq(r.died, true, "it died")
    assert_eq(f.me.used["Arcane Shot"], 3, "your shots")
    assert_eq(f.me.used["Wing Clip"], 1, "your clip")
    assert_near(f.me.hp_min, 0.55, 0.001, "your low")
    assert(f.threat_peak.score > 0, "the threat's peak")
    -- The log on disk.
    local log = G.files["jambix.aio.fights.json"]
    assert(log and #log.fights == 1, "one fight in the log")
    assert_eq(log.fights[1].outcome, "won", "as recorded")
    assert_eq(log.fights[1].foes[1].name, "Enemy", "your own log keeps the name")
    -- The banner, once.
    local n, s = said_debriefs(G)
    assert_eq(n, 1, "one banner")
    has(s.title, "fight won vs Enemy (warrior)", "the title")
    -- The page's lines.
    local lines = table.concat(debrief(G).lines(), " || ")
    has(lines, "Last fight: WON vs Enemy (warrior)", "the header")
    has(lines, "Enemy used: Hamstring 2, Charge 1, Recklessness 1", "what it used, most first")
    has(lines, "You used: Arcane Shot 3, Wing Clip 1", "what you used")
    has(lines, "You: low 55%", "your low")
    has(lines, "Central: off", "the central database's word")
end }

T[#T + 1] = { "a fight lost: you die; the lessons name the defensive that stayed ready through danger and the slow never cast", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    G.known["Feign Death"], G.known["Deterrence"] = true, true
    step(G)
    their_cast(G, "Hamstring"); step(G)
    G.hp = 0.3
    G.run(4.5)
    G.fire("jcore.player.died", {})
    local f = last(G)
    assert(f, "the fight closed on your death")
    assert_eq(f.outcome, "lost", "lost")
    assert_eq(f.me.died, true, "you died")
    local codes = lesson_codes(f)
    assert(codes.defensive_unused, "the defensive lesson: " .. table.concat((function() local t = {} for k in pairs(codes) do t[#t + 1] = k end return t end)(), ","))
    has(codes.defensive_unused, "Deterrence / Feign Death stayed ready through", "names them")
    assert(codes.slow_unused, "the slow lesson")
    has(codes.slow_unused, "with a slow ready and none cast", "says it")
    local n, s = said_debriefs(G)
    assert_eq(n, 1, "one banner")
    assert_eq(s.severity, "warn", "a loss is a warning")
    assert_eq(G.S.foes[G.target.guid], nil, "the picture forgot everyone after (the handler order)")
end }

T[#T + 1] = { "the trap never laid and a kill window that got away; they left: fled", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    G.known["Freezing Trap"] = true
    step(G)
    their_cast(G, "Hamstring"); step(G)
    G.run(6)
    G.health[G.target.guid], G.row.hp = 0.2, 0.2
    G.run(3)
    G.rows = {}
    G.target_present = false
    -- The picture keeps a player 5 s after its last row, the debrief 10 s more.
    G.run(17)
    local f = last(G)
    assert(f, "the fight closed after they left")
    assert_eq(f.outcome, "fled", "fled")
    local codes = lesson_codes(f)
    assert(codes.trap_unused, "the trap lesson")
    has(codes.trap_unused, "Freezing Trap was never laid", "says it")
    assert(codes.kill_missed, "the kill window lesson")
    has(codes.kill_missed, "Enemy was at 20% for", "names it")
end }

T[#T + 1] = { "your own hit broke your trap: a lesson with the count", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    their_cast(G, "Hamstring"); step(G)
    held_by(G, "Freezing Trap Effect", 6, G.player); step(G)
    our_cast(G, "Arcane Shot")
    G.row.control, G.auras[G.target.guid] = nil, {}
    step(G, 0.2)
    kill_target(G); step(G)
    local f = last(G)
    assert(f, "closed")
    local codes = lesson_codes(f)
    assert(codes.own_cc_broken, "the lesson")
    has(codes.own_cc_broken, "you broke your own control 1 time(s)", "the count")
    local moments = table.concat(f.moments and (function() local t = {} for i = 1, #f.moments do t[i] = f.moments[i].text end return t end)() or {}, " || ")
    has(moments, "your hit broke your Freezing Trap Effect on Enemy", "the moment")
end }

T[#T + 1] = { "the game's sandbox: with no os table and no _G (live on Forever 2026-10-12, the debrief died on your death and took the intel build with it), a fight lost closes, the log is written, the lesson is queued under a fresh id, the layer runs on", function()
    local saved_os, saved_G = os, _G
    local G = bundle()          -- the harness's own setup needs _G; the plugin's code after it must not
    G.files["jambix.aio.central.json"] = { url = "https://db.example/jambix/", key = "k1" }
    fake_net(G)
    G.settings.net_contribute = true
    G.P.ctx.allow_test_upload = true
    os, _G = nil, nil
    local ok, err = pcall(function()
        melee(G, WARRIOR); fighting(G)
        step(G)
        their_cast(G, "Hamstring"); step(G)
        G.hp = 0.3
        G.run(3)
        G.fire("jcore.player.died", {})
        local f = last(G)
        assert(f, "the fight closed on your death")
        assert_eq(f.outcome, "lost", "lost")
        assert_eq(debrief(G).T.errors, nil, "no step of the close failed: " .. tostring(debrief(G).T.last_error))
        local log = G.files["jambix.aio.fights.json"]
        assert(log and log.fights and #log.fights == 1, "the local log written")
        assert_eq(log.fights[1].at, 0, "no wall clock in the test: 0, not an error")
        local q = G.I.central.queue()
        assert_eq(#q, 1, "the lesson queued")
        local id = G.files["jambix.aio.central.json"].contributor
        assert(type(id) == "string" and #id == 24 and id:match("^%x+$"), "a contributor id of 24 hex: " .. tostring(id))
        assert(q[1].body.id ~= id and #q[1].body.id == 24, "a record id of its own")
        -- The layer runs on: the next fight opens and the build does not fail.
        G.hp = 1
        step(G, 3); melee(G, WARRIOR); fighting(G); step(G); step(G)
        assert(debrief(G).T.open == true, "a new fight opened: the layer still runs")
        assert(G.S and G.S.active == true, "the intel picture is still built")
    end)
    os, _G = saved_os, saved_G
    assert(ok, tostring(err))
end }

T[#T + 1] = { "the debrief and the network: with contribution on, the fight's lesson is queued under the contributor id with no name anywhere; the page's line says the network's word", function()
    local G = bundle()
    G.files["jambix.aio.central.json"] = { url = "https://db.example/jambix/", key = "k1" }
    local net = fake_net(G)
    G.settings.net_contribute = true
    G.P.ctx.allow_test_upload = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    their_cast(G, "Hamstring"); step(G)
    kill_target(G); step(G)
    local q = G.I.central.queue()
    assert_eq(#q, 1, "no forecast was made: the lesson alone")
    assert_eq(q[1].route, "/v1/lessons", "the lessons route")
    local payload = q[1].body
    assert_eq(payload.encounter.outcome, "won", "the outcome")
    assert_eq(payload.enemies[1].class, "WARRIOR", "its class")
    assert_eq(payload.me.class, "HUNTER", "your class")
    local function no_names(v, path)
        if type(v) ~= "table" then return end
        for k, x in pairs(v) do
            assert(k ~= "name" and k ~= "realm", "a name travelled: " .. path .. "." .. tostring(k))
            no_names(x, path .. "." .. tostring(k))
        end
    end
    no_names(payload, "payload")
    assert_eq(payload.contributor, G.files["jambix.aio.central.json"].contributor, "under the contributor id")
    has(table.concat(debrief(G).lines(), " || "), "Central: contributing to db.example", "on the page")
end }

T[#T + 1] = { "no central address, no network: the status says so and nothing is asked for", function()
    local G = bundle()
    melee(G, WARRIOR); fighting(G)
    step(G)
    has(G.I.central.status(), "off: no network service in this loader", "no net service")
    G = bundle()
    local net = fake_net(G)
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    has(G.I.central.status(), "off: no central address", "no address")
    assert_eq(#net.gets, 0, "nothing asked for")
end }

return T

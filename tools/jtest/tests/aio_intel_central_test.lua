-- Jambix AIO: the client of the shared PvP intelligence network
-- (CENTRAL_NETWORK.md; modules/react/intel/central.lua) inside the reaction
-- engine's tick on a scripted clock, with a fake storage and a fake
-- network. The bundle is tools/jtest/mock/intel_bundle.lua.
--
-- What these hold it to: nothing leaves this machine until the player
-- turns contribution on; a fight then queues its batch of forecasts as
-- they stood and its lesson, sent one at a time with the key and the
-- contributor id, with no name anywhere; a failure is retried with backoff
-- and the queue persists on disk, a refusal for good drops the item, the
-- queue is bounded, and combat never waited; the queued submissions can be
-- deleted and a deletion of the uploaded records requested (the id is
-- replaced); with downloads on, the newest compatible active model is
-- fetched, cached and seeds the predictor, an incompatible or older-plugin
-- version is skipped, a withdrawn one is dropped.

local B = require("mock/intel_bundle")
local assert_eq, assert_near, has = B.assert_eq, B.assert_near, B.has
local unit, hunter_ranges = B.unit, B.hunter_ranges
local ROGUE, PRIEST, WARRIOR = B.ROGUE, B.PRIEST, B.WARRIOR

local QUEUE, CONFIG, MODEL = "jambix.aio.central_queue.json", "jambix.aio.central.json", "jambix.aio.central_model.json"

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
    local net = { posts = {}, gets = {}, refuse = false }
    net.post_json = function(url, payload, opts, cb)
        if net.refuse then return false end
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
    opts = opts or {}
    opts.client = opts.client or { forever = false, combat_log = true, version = "Vanilla", exact = "1.15.9.70003" }
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
    G.files[CONFIG] = { url = "https://db.example/jambix/", key = "k1" }
    G.net = fake_net(G)
    G.P.ctx.version = "1.7.8"          -- JCore's context carries the plugin's manifest version
    G.P.ctx.allow_test_upload = true   -- these tests exercise the transport on purpose
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
local function central(G) return G.I.central end
--- A whole fight: two chances taken, then the warrior dies.
local function fight(G)
    melee(G, WARRIOR); fighting(G)
    step(G)
    for _ = 1, 2 do
        our_cast(G, "Wing Clip"); step(G, 0.5); their_cast(G, "Intercept"); step(G, 0.5)
        G.clock = G.clock + 3
    end
    their_cast(G, "Hamstring"); step(G)
    kill_target(G); step(G)
end
local function no_names(v, path)
    if type(v) ~= "table" then return end
    for k, x in pairs(v) do
        assert(k ~= "name" and k ~= "realm" and k ~= "account", "a name travelled: " .. path .. "." .. tostring(k))
        no_names(x, path .. "." .. tostring(k))
    end
end

local T = {}

T[#T + 1] = { "off by default: a fight ends and nothing is queued, nothing asked for; the status says so; combat ran", function()
    local G = bundle()
    fight(G)
    assert(G.I.debrief.T.last, "the fight was recorded locally")
    assert_eq(#central(G).queue(), 0, "nothing queued")
    assert_eq(#G.net.posts, 0, "nothing sent")
    assert_eq(#G.net.gets, 0, "nothing asked for")
    has(central(G).status(), "not contributing (off); 0 queued locally; downloads off", "the status")
    assert(G.files[CONFIG].contributor and #G.files[CONFIG].contributor == 24, "a contributor id was made and kept")
end }

T[#T + 1] = { "contribute on: the fight's batch of forecasts and its lesson are queued and sent one at a time, with the key and the id, no name anywhere", function()
    local G = bundle()
    G.settings.net_contribute = true
    fight(G)
    local q = central(G).queue()
    assert_eq(#q, 2, "a batch and a lesson queued")
    assert_eq(q[1].kind, "batch", "the batch first")
    assert_eq(G.files[QUEUE].items[1].kind, "batch", "the queue is on disk")
    step(G)
    assert_eq(#G.net.posts, 1, "one in flight at a time")
    local post = G.net.posts[1]
    assert_eq(post.url, "https://db.example/jambix/v1/combat/batches", "the batches route")
    assert_eq(post.opts.headers["X-Jambix-Key"], "k1", "the key")
    assert_eq(post.opts.headers["X-Jambix-Contributor"], G.files[CONFIG].contributor, "the id")
    local b = post.payload
    assert_eq(b.schema, 1, "the schema")
    assert_eq(b.me.class, "HUNTER", "your class")
    assert_eq(b.encounter.outcome, "won", "the outcome")
    assert_eq(b.client.game, "Vanilla", "the game variant")
    assert(#b.observations >= 2, "the forecasts as they stood: " .. #b.observations)
    local o = b.observations[1]
    assert_eq(o.pattern, "mobility_when_slowed", "the pattern")
    assert_eq(o.enemy_class, "WARRIOR", "its class")
    assert_near(o.p, 0.5, 0.001, "the first forecast was the prior")
    assert_eq(o.hit, true, "and it hit")
    assert_eq(o.inputs_ok, true, "the inputs were live")
    assert(o.t and o.t >= 0, "relative time")
    no_names(b, "batch")
    step(G)
    assert_eq(#G.net.posts, 1, "still waiting for the answer")
    post.cb({ ok = true }, nil, { status = 200 })
    step(G)
    assert_eq(#G.net.posts, 2, "the lesson follows")
    assert_eq(G.net.posts[2].url, "https://db.example/jambix/v1/lessons", "the lessons route")
    local l = G.net.posts[2].payload
    assert_eq(l.enemies[1].class, "WARRIOR", "the opponent's class")
    assert_eq(l.enemies[1].used["Hamstring"], 1, "what it used")
    no_names(l, "lesson")
    G.net.posts[2].cb({ ok = true }, nil, { status = 200 })
    step(G)
    assert_eq(#central(G).queue(), 0, "the queue drained")
    assert_eq(central(G).T.uploaded, 2, "two uploaded")
    has(central(G).status(), "contributing to db.example: 0 queued, 2 uploaded, 0 dropped", "the status")
end }

T[#T + 1] = { "offline: the net refuses, then the server fails; the item waits with backoff and the queue persists; a refusal for good drops it; combat ran on", function()
    local G = bundle()
    G.settings.net_contribute = true
    G.net.refuse = true
    fight(G)
    step(G)
    assert_eq(#G.net.posts, 0, "nothing could be sent")
    assert_eq(#central(G).queue(), 2, "both wait")
    has(central(G).status(), "the net service refused the request", "the status")
    G.net.refuse = false
    step(G)
    assert_eq(#G.net.posts, 0, "not before the backoff")
    G.clock = G.clock + 31; step(G)
    assert_eq(#G.net.posts, 1, "sent after the backoff")
    G.net.posts[1].cb(nil, "http 500", { status = 500 })
    step(G)
    local item = central(G).queue()[1]
    assert_eq(item.tries, 2, "two tries")
    assert(item.next_at > G.clock + 50, "the second wait is longer")
    assert_eq(G.files[QUEUE].items[1].tries, 2, "persisted")
    G.clock = G.clock + 61; step(G)
    assert_eq(#G.net.posts, 2, "tried again")
    G.net.posts[2].cb(nil, "http 400", { status = 400 })
    step(G)
    local q = central(G).queue()
    assert_eq(#q, 1, string.format("refused for good: off the queue (kinds %s/%s; status %s; dropped %d; posts %d)",
        tostring(q[1] and q[1].kind), tostring(q[2] and q[2].kind), tostring(central(G).T.last_status), central(G).T.dropped, #G.net.posts))
    assert_eq(central(G).T.dropped, 1, "dropped")
    has(central(G).status(), "batch refused (http 400)", "said")
    G.clock = G.clock + 1; step(G)
    assert_eq(#G.net.posts, 3, "the lesson goes next")
    G.net.posts[3].cb(nil, "http 429", { status = 429 })
    step(G)
    assert_eq(#central(G).queue(), 1, "a 429 is retried, not dropped")
    assert(G.I.debrief.T.last ~= nil and G.S.foes ~= nil, "combat went on all along")
end }

T[#T + 1] = { "the queue is bounded: the oldest leave; delete queued submissions empties it; a deletion request goes first and replaces the id, even with contribution off", function()
    local G = bundle()
    G.settings.net_contribute = true
    G.net.refuse = true
    local f = { me = { class = "HUNTER", level = 26 }, mode = "world_pvp", duration = 10, outcome = "won", foe_order = {}, foes = {},
                lessons = {}, moments = {}, states = {}, threat_peak = { level = "LOW", score = 5 }, predictions = {}, baits = {}, holds = 0 }
    for i = 1, 70 do central(G).share(f) end
    assert_eq(#central(G).queue(), 60, "capped")
    assert(central(G).T.dropped >= 10, "the oldest left: " .. central(G).T.dropped)
    assert_eq(central(G).delete_queue(), 60, "deleted")
    assert_eq(#central(G).queue(), 0, "empty")
    assert_eq(#G.files[QUEUE].items, 0, "on disk too")
    G.settings.net_contribute = false
    local old = central(G).contributor()
    assert_eq(central(G).request_delete(), true, "requested")
    local q = central(G).queue()
    assert_eq(q[1].route, "/v1/privacy/delete", "the deletion first")
    assert_eq(q[1].body.contributor, old, "under the old id")
    assert(central(G).contributor() ~= old, "a new id")
    assert_eq(G.files[CONFIG].contributor, central(G).contributor(), "kept on disk")
    G.net.refuse = false
    step(G)
    assert_eq(#G.net.posts, 1, "sent although contribution is off")
    assert_eq(G.net.posts[1].url, "https://db.example/jambix/v1/privacy/delete", "the privacy route")
end }

T[#T + 1] = { "download on: the manifest is asked for; the newest compatible active version is fetched, cached and seeds the predictor; an incompatible schema and a newer plugin's version are skipped; a withdrawn cached model is dropped", function()
    local G = bundle()
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    assert_eq(#G.net.gets, 2, "the manifest and the status")
    has(G.net.gets[1].url, "/v1/models/manifest", "the manifest route")
    has(G.net.gets[2].url, "/v1/client/status?plugin=", "the status route")
    G.net.gets[1].cb({ schema = 1, versions = {
        { version = "1", schema = 1, status = "active", min_plugin = "1.0.0" },
        { version = "2", schema = 2, status = "active" },
        { version = "3", schema = 1, status = "active", min_plugin = "99.0.0" },
        { version = "4", schema = 1, status = "withdrawn" },
    } }, nil)
    assert_eq(#G.net.gets, 3, "one model fetched")
    has(G.net.gets[3].url, "/v1/models/1", "version 1: the only compatible active one")
    -- The model as the learning engine publishes it: per game, the class
    -- table and the learning groups (here the class level only).
    G.net.gets[3].cb({ schema = 1, version = "1", fights = 120, games = { Vanilla = {
        by_class = { WARRIOR = { outcomes = { won = 70, lost = 40 }, advice = { { text = "the trap was never laid", won = 0.2, lost = 0.6 } } } },
        groups = { ["g:Vanilla|e:WARRIOR"] = { level = "class", patterns = {
            mobility_when_slowed = { p = 0.9, n = 30, unreliable = false }, same_opener = { p = 0.7, n = 30, unreliable = true, why = "forecast quality 0.4" },
            targeting_pet = { p = 0.7, n = 3 } } } } } } }, nil)
    assert_eq(central(G).T.model_version, "1", "adopted")
    assert_eq(G.files[MODEL].version, "1", "cached on disk")
    local p, n, level = central(G).prior_for("WARRIOR", "mobility_when_slowed")
    assert_near(p, 0.78, 0.001, "the network's 0.9 drawn toward even odds by the class level's certainty (0.7)")
    assert_eq(n, 30, "backed by 30 fights")
    assert_eq(level, "class", "found at the class level")
    assert_eq(central(G).prior_for("WARRIOR", "same_opener"), nil, "unreliable: no prior")
    assert_eq(central(G).prior_for("WARRIOR", "targeting_pet"), nil, "too few fights: no prior")
    has(central(G).advice_for("WARRIOR")[1], "vs warrior: 110 fight(s) in the network, won 70, lost 40", "the matchup")
    our_cast(G, "Wing Clip"); step(G, 2.5)
    local e = G.S.foes[G.target.guid].predict.mobility_when_slowed
    assert_near(e.prior, 0.78, 0.001, "a new warrior's pattern starts at the network's rate")
    has(e.why, "the database's over 30 fights at the class level", "and says so, with the level")
    has(central(G).status(), "model v1 from 120 fight(s)", "the status")
    -- The manifest later lists version 1 withdrawn: dropped, the local prior stands.
    G.clock = G.clock + 1801; step(G)
    G.net.gets[#G.net.gets - 1].cb({ schema = 1, versions = { { version = "1", schema = 1, status = "withdrawn" } } }, nil)
    assert_eq(central(G).T.model_version, nil, "dropped")
    assert_eq(central(G).prior_for("WARRIOR", "mobility_when_slowed"), nil, "no prior from it")
    has(central(G).status(), "model 1 withdrawn or incompatible: dropped", "said")
    has(central(G).status(), "no model yet: no compatible active model in the manifest", "and why none replaces it")
end }

T[#T + 1] = { "GitHub as the service: the uploads become issues on the repository with the token, the record fenced in the body, no name anywhere; the manifest and the model are read off the data branch", function()
    local G = bundle()
    G.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", branch = "jambix-data", token = "github_pat_x" } }
    G.settings.net_contribute, G.settings.net_download = true, true
    fight(G)
    step(G)
    assert_eq(#G.net.posts, 1, "one issue in flight")
    local post = G.net.posts[1]
    assert_eq(post.url, "https://api.github.com/repos/MrJambix/PS-Plugin/issues", "the issues route")
    assert_eq(post.opts.headers["Authorization"], "Bearer github_pat_x", "the token")
    assert_eq(post.opts.headers["X-GitHub-Api-Version"], "2022-11-28", "the API version GitHub asks for")
    has(post.opts.headers["User-Agent"], "jambix-aio/1.7.8", "a user agent")
    has(post.payload.title, "jambix-fight ", "one issue for the fight: the kind and the id in the title")
    assert_eq(post.payload.labels[1], "jambix", "labelled")
    has(post.payload.body, "```json\n{", "the record fenced")
    has(post.payload.body, '"pattern":"mobility_when_slowed"', "with the forecasts (its batch)")
    has(post.payload.body, '"lesson":{', "and its lesson, in the same issue")
    assert(not post.payload.body:find('"name"', 1, true), "no name in the body")
    post.cb({ number = 12 }, nil, { status = 201 })
    step(G); step(G)
    assert_eq(#G.net.posts, 1, "one issue per fight, not two")
    assert_eq(#central(G).queue(), 0, "nothing left")
    -- The manifest, off the data branch through the contents API, asked for raw.
    local manifest = nil
    for _, g in ipairs(G.net.gets) do if g.url:find("manifest", 1, true) then manifest = g end end
    assert(manifest, "the manifest asked for")
    assert_eq(manifest.url, "https://api.github.com/repos/MrJambix/PS-Plugin/contents/data/models/manifest.json?ref=jambix-data", "the contents route")
    assert_eq(manifest.opts.headers["Accept"], "application/vnd.github.raw+json", "raw")
    local before = #G.net.gets
    manifest.cb({ schema = 1, versions = { { version = "2", schema = 1, status = "active", min_plugin = "1.7.8" } } }, nil)
    assert_eq(#G.net.gets, before + 1, "the model fetched")
    assert_eq(G.net.gets[#G.net.gets].url, "https://api.github.com/repos/MrJambix/PS-Plugin/contents/data/models/v2.json?ref=jambix-data", "its file")
    G.net.gets[#G.net.gets].cb({ schema = 1, version = "2", fights = 9, by_class = {} }, nil)
    assert_eq(central(G).T.model_version, "2", "adopted")
    has(central(G).status(), "contributing to github.com/MrJambix/PS-Plugin", "the status names the repository")
    -- A 403 from GitHub (a rate limit) is retried; a 422 (a bad record) is dropped.
    -- (A deletion request is the next item through: the fight went in one issue.)
    central(G).request_delete()
    step(G)
    has(G.net.posts[2].payload.title, "jambix-delete ", "the deletion's issue")
    G.net.posts[2].cb(nil, "http 403", { status = 403 })
    step(G)
    assert_eq(#central(G).queue(), 1, "kept for a retry")
    G.clock = G.clock + 31; step(G)
    G.net.posts[3].cb(nil, "http 422", { status = 422 })
    step(G)
    assert_eq(#central(G).queue(), 0, "dropped for good")
end }

T[#T + 1] = { "the issue body is kept under GitHub's limit: a batch too large loses observations from the end and says so", function()
    local G = bundle()
    G.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", token = "t" } }
    G.settings.net_contribute = true
    -- Every observation carries a long basis to push the body past the limit
    -- (the buffer keeps 120; at some 700 characters each the body is far over).
    for i = 1, 120 do
        central(G).observe({ pattern = "mobility_when_slowed", enemy_class = "WARRIOR", p = 0.5, reliability = 0.1, sure = false,
                             basis = string.rep("x", 600), evidence = i, inputs_ok = true, hit = true, t = i,
                             context = { mode = "world_pvp", threat = "LOW", me_hp = 1, controlled = false } })
    end
    local f = { me = { class = "HUNTER", level = 26 }, mode = "world_pvp", duration = 10, outcome = "won", foe_order = {}, foes = {},
                lessons = {}, moments = {}, states = {}, threat_peak = { level = "LOW", score = 5 }, predictions = {}, baits = {}, holds = 0 }
    central(G).share(f)
    step(G)
    local post = G.net.posts[1]
    assert(post, "the issue")
    assert(#post.payload.body <= 60100, "under the limit: " .. #post.payload.body)
    has(post.payload.body, "issue size:", "and says what was dropped")
end }

T[#T + 1] = { "a cached model loads from disk at start and serves offline; a malformed model is refused", function()
    local G = bundle()
    G.files[MODEL] = { schema = 1, version = "7", fights = 50, by_class = { ROGUE = { patterns = { interrupts_casts = { p = 0.7, n = 12 } } } } }
    G.P.ctx.net = nil
    melee(G, ROGUE); fighting(G)
    step(G)
    assert_near(central(G).prior_for("ROGUE", "interrupts_casts"), 0.64, 0.001, "from the cache, no network (an older class-only model: the class level's certainty)")
    has(central(G).status(), "off: no network service", "the status")
    G = bundle()
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.net.gets[1].cb({ schema = 1, versions = { { version = "1", schema = 1, status = "active" } } }, nil)
    G.net.gets[3].cb({ schema = 1, version = "1" }, nil)
    assert_eq(central(G).T.model_version, nil, "not adopted")
    assert_eq(central(G).T.model_err, "malformed model", "why")
end }

-- --- the global learning engine's side (tools/fightlog_server/learn.js, release.js) ----------------

--- A model as the learning engine publishes it: per game, the class table,
--- the learning groups (keys from central.key_at) and the tactics.
local function grouped_model(G, version, entries, extra)
    local groups = {}
    for _, e in ipairs(entries) do
        local key = central(G).key_at(e.ctx or central(G).context("WARRIOR"), e.level)
        groups[key] = groups[key] or { level = e.level, patterns = {} }
        groups[key].patterns[e.pattern] = { p = e.p, n = e.n or 30, unreliable = e.unreliable == true }
    end
    local game = { by_class = { WARRIOR = { outcomes = { won = 6, lost = 4 }, advice = {} } }, groups = groups, tactics = (extra and extra.tactics) or {} }
    return { schema = 1, version = version, fights = 200, games = { [(extra and extra.game) or "Vanilla"] = game } }
end

T[#T + 1] = { "the learning groups: a prior comes from the narrowest level of this game holding a reliable entry -- exact before matchup before class before general -- and says which; an unreliable narrow entry falls back; another game's groups are never read", function()
    local G = bundle()
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    local ctx = central(G).context("WARRIOR")
    assert_eq(ctx.game, "Vanilla", "the game"); assert_eq(ctx.me_class, "HUNTER", "your class"); assert_eq(ctx.enemy_class, "WARRIOR", "theirs")
    assert_eq(ctx.bracket, "60", "your level's bracket")
    has(central(G).key_at(ctx, "exact"), "g:Vanilla|me:HUNTER|e:WARRIOR|lv:60|enc:", "the exact key, as groups.js writes it")
    G.net.gets[1].cb({ schema = 1, versions = { { version = "5", schema = 1, status = "active", stage = "full", rollout = 100 } } }, nil)
    G.net.gets[3].cb(grouped_model(G, "5", {
        { level = "exact", pattern = "mobility_when_slowed", p = 0.75 },
        { level = "class", pattern = "mobility_when_slowed", p = 0.6 },
        { level = "exact", pattern = "same_opener", p = 0.7, unreliable = true },
        { level = "matchup", pattern = "same_opener", p = 0.65 },
        { level = "general", pattern = "targeting_pet", p = 0.3 },
    }), nil)
    assert_eq(central(G).T.model_version, "5", "adopted")
    local p, n, level = central(G).prior_for("WARRIOR", "mobility_when_slowed")
    assert_near(p, 0.75, 0.001, "the exact level's rate"); assert_eq(level, "exact", "and the level")
    p, n, level = central(G).prior_for("WARRIOR", "same_opener")
    assert_near(p, 0.6275, 0.001, "the exact entry unreliable: the matchup's 0.65, drawn toward even odds (0.85)"); assert_eq(level, "matchup", "backed off one level")
    p, n, level = central(G).prior_for("WARRIOR", "targeting_pet")
    assert_near(p, 0.4, 0.001, "only the general baseline: 0.3 at half certainty"); assert_eq(level, "general", "the broadest level")
    assert_eq(central(G).prior_for("WARRIOR", "interrupts_casts"), nil, "nothing at any level: no prior")
    -- The same rates filed under Forever only: a Vanilla client reads none of them.
    local G2 = bundle()
    G2.settings.net_download = true
    melee(G2, WARRIOR); fighting(G2)
    step(G2)
    G2.net.gets[1].cb({ schema = 1, versions = { { version = "6", schema = 1, status = "active" } } }, nil)
    local m = grouped_model(G2, "6", { { level = "class", pattern = "mobility_when_slowed", p = 0.9,
        ctx = { game = "Forever", me_class = "HUNTER", enemy_class = "WARRIOR", bracket = "60", encounter = "none", combat = "1v1" } } }, { game = "Forever" })
    G2.net.gets[3].cb(m, nil)
    assert_eq(central(G2).T.model_version, "6", "adopted")
    assert_eq(central(G2).prior_for("WARRIOR", "mobility_when_slowed"), nil, "another game's knowledge is never used")
end }

T[#T + 1] = { "the staged rollout: a canary reaches only its share of clients, by the contributor id, and the rest keep the full version; at 100% it is everyone's; a client stays on its side", function()
    local G = bundle()
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.net.gets[1].cb({ schema = 1, versions = {
        { version = "1", schema = 1, status = "active", stage = "full", rollout = 100 },
        { version = "2", schema = 1, status = "active", stage = "canary", rollout = 0 },
    } }, nil)
    has(G.net.gets[3].url, "/v1/models/1", "a canary for 0% of clients: the full version")
    local G2 = bundle()
    G2.settings.net_download = true
    melee(G2, WARRIOR); fighting(G2)
    step(G2)
    G2.net.gets[1].cb({ schema = 1, versions = {
        { version = "1", schema = 1, status = "active", stage = "full", rollout = 100 },
        { version = "2", schema = 1, status = "active", stage = "canary", rollout = 100 },
    } }, nil)
    has(G2.net.gets[3].url, "/v1/models/2", "a canary at 100%: taken")
    -- The same client lands on the same side of a share every time it asks.
    local G3 = bundle()
    G3.settings.net_download = true
    melee(G3, WARRIOR); fighting(G3)
    step(G3)
    local manifest = { schema = 1, versions = {
        { version = "1", schema = 1, status = "active", stage = "full" },
        { version = "2", schema = 1, status = "active", stage = "canary", rollout = 50 },
    } }
    G3.net.gets[1].cb(manifest, nil)
    local first = G3.net.gets[#G3.net.gets].url:match("/v1/models/(%d+)$")
    assert(first == "1" or first == "2", "one of them fetched")
    G3.P.ctx.storage.files[MODEL] = nil
    central(G3).T.model_version = nil
    G3.clock = G3.clock + 1801; step(G3)
    local ask
    for i = #G3.net.gets, 1, -1 do if G3.net.gets[i].url:find("manifest", 1, true) then ask = G3.net.gets[i] break end end
    ask.cb(manifest, nil)
    assert_eq(G3.net.gets[#G3.net.gets].url:match("/v1/models/(%d+)$"), first, "the same side both times")
end }

T[#T + 1] = { "the rollout's monitoring: each batch says which model version this client ran under, and how many players it faced", function()
    local G = bundle()
    G.settings.net_contribute, G.settings.net_download = true, true
    melee(G, WARRIOR); fighting(G)
    step(G)
    G.net.gets[1].cb({ schema = 1, versions = { { version = "3", schema = 1, status = "active" } } }, nil)
    G.net.gets[3].cb(grouped_model(G, "3", {}), nil)
    assert_eq(central(G).T.model_version, "3", "adopted")
    for _ = 1, 2 do
        our_cast(G, "Wing Clip"); step(G, 0.5); their_cast(G, "Intercept"); step(G, 0.5)
        G.clock = G.clock + 3
    end
    kill_target(G); step(G)
    local q = central(G).queue()
    assert(#q >= 1 and q[1].kind == "batch", "the batch queued")
    assert_eq(q[1].body.client.model, "3", "the model version it ran under")
    assert_eq(q[1].body.encounter.enemies, 1, "one player faced")
end }

T[#T + 1] = { "nothing from a model becomes a rule: adopting one with validated tactics adds no reaction and changes no rule; its validated tactics reach the page as words, called associations", function()
    local G = bundle()
    G.settings.net_download = true
    melee(G, WARRIOR); fighting(G)
    step(G)
    local E = G.P.ctx.react
    local before = {}
    for i, r in ipairs(E.rules()) do before[i] = r.name end
    G.net.gets[1].cb({ schema = 1, versions = { { version = "4", schema = 1, status = "active" } } }, nil)
    G.net.gets[3].cb(grouped_model(G, "4", {}, { tactics = {
        { strategy = "controlling_distance", level = "matchup", me_class = "HUNTER", enemy_class = "WARRIOR", validated = true, strength = "strong",
          evidence = "association", causal = false, text = "hunter against a warrior on Vanilla: controlling the distance -- followed ended well in 80% of 30 episode(s)" },
        { strategy = "preserve_escape", level = "matchup", me_class = "HUNTER", enemy_class = "WARRIOR", validated = false, text = "not validated" },
    } }), nil)
    assert_eq(central(G).T.model_version, "4", "adopted")
    step(G); step(G)
    local after = E.rules()
    assert_eq(#after, #before, "the same number of rules")
    for i, r in ipairs(after) do assert_eq(r.name, before[i], "rule " .. i .. " unchanged") end
    local lines = central(G).advice_for("WARRIOR")
    local found, unvalidated = false, false
    for _, l in ipairs(lines) do
        if l:find("association: hunter against a warrior", 1, true) then found = true end
        if l:find("not validated", 1, true) then unvalidated = true end
    end
    assert(found, "the validated tactic is shown, as an association: " .. table.concat(lines, " | "))
    assert(not unvalidated, "an unvalidated one is not")
end }

T[#T + 1] = { "live 2026-10-12: a fight filed five times -- a 201 whose answer is unread is delivered, an unclear failure looks for its issue before trying again, and a queue saved mid-retry is due at once and looked for first", function()
    local G = bundle()
    G.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", branch = "jambix-data", token = "github_pat_x" } }
    G.settings.net_contribute = true
    fight(G)
    step(G)
    assert_eq(#G.net.posts, 1, "the fight's issue in flight")
    -- GitHub created it (201) but the client could not read the answer.
    G.net.posts[1].cb(nil, "malformed json", { ok = true, status = 201 })
    step(G); step(G)
    assert_eq(#central(G).queue(), 0, "the fight is off the queue")
    assert_eq(central(G).T.uploaded, 1, "counted delivered")
    has(central(G).status(), "accepted (its answer unread: malformed json)", "and says so")
    local saved = G.files[QUEUE].problems
    assert(saved and saved[#saved].status == 201 and saved[#saved].error == "malformed json", "the problem kept with the queue on disk")
    assert_eq(#G.net.posts, 1, "sent once, not five times")

    -- A try that ends with no status at all: unclear; GitHub is asked first.
    local G1 = bundle()
    G1.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", branch = "jambix-data", token = "github_pat_x" } }
    G1.settings.net_contribute = true
    fight(G1)
    step(G1)
    local title = G1.net.posts[1].payload.title
    G1.net.posts[1].cb(nil, "http 0", { ok = false, status = 0 })
    step(G1)
    local item = central(G1).queue()[1]
    assert_eq(item.check_first, true, "an unclear failure: looked for before the next try")
    G1.clock = G1.clock + 31; step(G1)
    assert_eq(#G1.net.posts, 1, "not posted again yet")
    local ask = G1.net.gets[#G1.net.gets]
    has(ask.url, "/repos/MrJambix/PS-Plugin/issues?state=all&labels=jambix", "GitHub asked for the network's issues")
    assert_eq(ask.opts.headers["Authorization"], "Bearer github_pat_x", "with the token")
    assert_eq(central(G1).issue_title(item), title, "the same title every try")
    ask.cb({ { number = 7, title = title }, { number = 2, title = "jambix-fight something else" } }, nil, { ok = true, status = 200 })
    step(G1)
    assert_eq(#central(G1).queue(), 0, "found filed: done, never sent twice")
    has(central(G1).status(), "fight already filed (#7): not sent again", "said")
    assert_eq(#G1.net.posts, 1, "one post in all")

    -- Not found: it is sent.
    local G2 = bundle()
    G2.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", branch = "jambix-data", token = "github_pat_x" } }
    G2.settings.net_contribute = true
    fight(G2)
    step(G2)
    G2.net.posts[1].cb(nil, "http 502", { ok = false, status = 502 })
    G2.clock = G2.clock + 31; step(G2)
    G2.net.gets[#G2.net.gets].cb({}, nil, { ok = true, status = 200 })
    step(G2)
    assert_eq(#G2.net.posts, 2, "not filed: posted again")
    assert_eq(G2.net.posts[2].payload.title, G2.net.posts[1].payload.title, "the same issue title")

    -- A queue the old client saved mid-retry (the live one: tries 5, a wait on the last session's clock).
    local G3 = bundle()
    G3.files[CONFIG] = { github = { repo = "MrJambix/PS-Plugin", branch = "jambix-data", token = "github_pat_x" }, contributor = string.rep("8", 24) }
    G3.files[QUEUE] = { schema = 1, items = {
        { kind = "batch", route = "/v1/combat/batches", tries = 5, next_at = 1145.7, id = string.rep("a", 24),
          body = { schema = 1, id = string.rep("a", 24), contributor = string.rep("8", 24), observations = {} } },
        { kind = "lesson", route = "/v1/lessons", tries = 0, next_at = 0, id = string.rep("b", 24),
          body = { schema = 1, id = string.rep("b", 24), contributor = string.rep("8", 24) } },
    } }
    G3.settings.net_contribute = true
    step(G3)
    local q = central(G3).queue()
    assert_eq(q[1].next_at, 0, "due now: the old session's clock is not this one's")
    assert_eq(q[2].check_first, nil, "never tried: sent as it is")
    assert_eq(#G3.net.posts, 0, "the batch is looked for, not posted")
    has(G3.net.gets[#G3.net.gets].url, "/issues?state=all&labels=jambix", "tried before: looked for first, on the first pass")
    G3.net.gets[#G3.net.gets].cb({ { number = 2, title = "jambix-batch " .. string.rep("a", 24) } }, nil, { ok = true, status = 200 })
    step(G3); step(G3)
    assert_eq(#G3.net.posts, 1, "then the lesson goes")
    has(G3.net.posts[1].payload.title, "jambix-lesson ", "the lesson")
end }

return T

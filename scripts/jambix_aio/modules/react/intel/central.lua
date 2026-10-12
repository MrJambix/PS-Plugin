-- Jambix AIO / react / intel / central -- the Jambix client of the shared
-- PvP intelligence network (the brief of 2026-10-12, "Central PvP
-- Intelligence Network"; CENTRAL_NETWORK.md).
--
-- WHAT THIS IS: the client adapter. It collects what the predictor and the
-- debrief already produce (forecast observations as they are scored, one
-- lesson per fight), keeps them in a bounded queue on disk, uploads them
-- when -- and only when -- the player turned contribution on, and downloads
-- the network's published model when the player turned that on. Nothing
-- here is read by a combat decision in the same tick it arrives: the
-- predictor reads the cached model from disk (loaded at start), the
-- uploads go out between frames, and every call to the net service is
-- asynchronous. With the internet gone, the server down, consent off, the
-- model incompatible or withdrawn, combat runs exactly as before.
--
-- CONSENT, OFF BY DEFAULT: *Contribute my fights* (net_contribute),
-- *include extra detail* (net_diagnostics), *Download the network's
-- learning* (net_download) -- three switches on the Reactions page -- and
-- two buttons: delete the queued local submissions; ask the service to
-- delete every record under this contributor id and start a new one.
--
-- WHAT TRAVELS UP (observations, one batch per fight; a lesson per fight):
-- a random contributor id (rotatable; it is a pseudonym, not anonymity),
-- the plugin version, the game variant and build, your class and level,
-- the opponents' classes and roles, the encounter type and its relative
-- timing, each forecast as it stood before the outcome with the outcome,
-- the input reliability and the evidence behind it, the lesson codes, the
-- ability names each side used. Never: names, account, chat, realm, the
-- opponents' histories. With *extra detail* on, the fight's moments and
-- states as well (names stripped).
--
-- WHAT COMES DOWN: a model version (a manifest names which are active and
-- which were withdrawn, each with its schema and plugin range); only a
-- compatible, active one is kept; a withdrawn one is dropped. Its rates
-- seed a new player's prior in the predictor when the model calls them
-- reliable and enough fights back them; its matchup advice shows in the
-- debrief. Priors, never facts.

return function(P, lib, data, K)
    local floor, max, min, huge = math.floor, math.max, math.min, math.huge
    local KC = K.CENTRAL

    local M = {}
    M.SCHEMA = 1

    local function opt(id, default)
        if not P.opt then return default end
        local v = P.opt(id, default)
        if v == nil then return default end
        return v
    end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function clock() return core.time() end
    local function net() local ctx = P.ctx return ctx and ctx.net or nil end
    local function storage() local ctx = P.ctx return ctx and ctx.storage or nil end

    local function plugin_version()
        local ctx = P.ctx
        local m = ctx and ctx.manifest or nil
        return (m and m.version) or (ctx and ctx.version) or P.version or "unknown"
    end

    local function vnum(s)
        local a, b, c = tostring(s or ""):match("(%d+)%.?(%d*)%.?(%d*)")
        return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
    end

    -- The ids come from the layer's seeded generator (intel/init.lua
    -- lib.random_hex): an unseeded one would give every player the same.
    local function random_hex(n)
        if lib.random_hex then return lib.random_hex(n) end
        local t = {}
        for i = 1, n do t[i] = string.format("%x", math.random(0, 15)) end
        return table.concat(t)
    end

    -- --- consent -------------------------------------------------------------------------

    function M.contributing() return opt("net_contribute", false) == true end
    function M.diagnostics() return opt("net_diagnostics", false) == true end
    function M.downloading() return opt("net_download", false) == true end

    -- --- the files ------------------------------------------------------------------------

    local CONFIG, QUEUE, MODEL = "jambix.aio.central.json", "jambix.aio.central_queue.json", "jambix.aio.central_model.json"
    local loaded = false
    -- Two backends: a central service at `url` (tools/fightlog_server), or
    -- the GitHub repository itself (`github` { repo, branch, token }): the
    -- uploads become issues the repository's Action files away, the model
    -- is read off the data branch (CENTRAL_NETWORK.md §9).
    local cfg = { url = nil, key = nil, github = nil, contributor = nil, source = "none" }

    -- A JSON encoder for the issue bodies: JCore's where the context has
    -- one, a small one of our own otherwise (strings, numbers, booleans,
    -- lists and maps; nothing else travels).
    local function encode_json(v)
        local ctx = P.ctx
        local lib_json = ctx and ctx.json or lib.json
        if lib_json and lib_json.encode then
            local ok, s = pcall(lib_json.encode, v)
            if ok and type(s) == "string" then return s end
        end
        local t = type(v)
        if t == "nil" then return "null" end
        if t == "boolean" then return v and "true" or "false" end
        if t == "number" then
            if v ~= v or v == huge or v == -huge then return "null" end
            if v == floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
            return string.format("%.6g", v)
        end
        if t == "string" then
            local s = v:gsub('[%c"\\]', function(ch)
                if ch == '"' then return '\\"' elseif ch == "\\" then return "\\\\" elseif ch == "\n" then return "\\n"
                elseif ch == "\r" then return "\\r" elseif ch == "\t" then return "\\t" end
                return string.format("\\u%04x", ch:byte())
            end)
            return '"' .. s .. '"'
        end
        if t == "table" then
            local n = #v
            local is_list = n > 0
            if not is_list then
                for k in pairs(v) do if type(k) ~= "string" then is_list = true break end end
            end
            local out = {}
            if is_list then
                for i = 1, n do out[i] = encode_json(v[i]) end
                return "[" .. table.concat(out, ",") .. "]"
            end
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            for i = 1, #keys do out[i] = encode_json(keys[i]) .. ":" .. encode_json(v[keys[i]]) end
            return "{" .. table.concat(out, ",") .. "}"
        end
        return "null"
    end
    M.encode_json = encode_json
    local queue = {}
    local model = nil

    local T = {
        queued = 0, uploaded = 0, failed = 0, dropped = 0, in_flight = false, last_status = nil, last_at = -huge,
        observations = 0, censored = 0,
        model_version = nil, model_fights = 0, model_err = nil, manifest_at = -huge, manifest_err = nil,
        server = nil, server_err = nil, server_at = -huge,
        deletions_requested = 0, id_rotations = 0,
    }
    M.T = T

    local function save(name, value)
        local st = storage()
        if not (st and st.write_json) then return false end
        return try(st.write_json, name, value) == true
    end

    local function save_config()
        return save(CONFIG, { url = cfg.local_url, key = cfg.local_key, github = cfg.local_github, contributor = cfg.contributor })
    end

    local function save_queue()
        T.queued = #queue
        return save(QUEUE, { schema = M.SCHEMA, items = queue })
    end

    local function load_all()
        if loaded then return end
        loaded = true
        local load = P.load or function(path) return require("jambix_aio/" .. path) end
        local function github_of(t)
            local g = type(t) == "table" and t.github or nil
            if type(g) ~= "table" or type(g.repo) ~= "string" or not g.repo:find("/", 1, true) then return nil end
            return { repo = g.repo, branch = type(g.branch) == "string" and g.branch or "jambix-data", token = g.token }
        end
        local ok, shipped = pcall(load, "modules/central_config")
        if ok and type(shipped) == "table" then
            cfg.url, cfg.key, cfg.source = shipped.url, shipped.key, "central_config.lua"
            cfg.github = github_of(shipped)
        end
        local st = storage()
        local mine = st and st.read_json and try(st.read_json, CONFIG) or nil
        if type(mine) == "table" then
            -- The machine's own file decides the backend when it names one:
            -- its `github` wins; its `url` alone means the HTTP service,
            -- whatever the shipped file says.
            if type(mine.url) == "string" and mine.url ~= "" then cfg.url, cfg.local_url, cfg.source = mine.url, mine.url, CONFIG end
            if type(mine.key) == "string" then cfg.key, cfg.local_key = mine.key, mine.key end
            local g = github_of(mine)
            if g then cfg.github, cfg.local_github, cfg.source = g, mine.github, CONFIG
            elseif cfg.local_url then cfg.github = nil end
            if type(mine.contributor) == "string" and #mine.contributor >= 16 then cfg.contributor = mine.contributor end
        end
        if cfg.url then cfg.url = cfg.url:gsub("/+$", "") end
        cfg.backend = cfg.github and "github" or (cfg.url and "http") or nil
        if not cfg.contributor then
            cfg.contributor = random_hex(24)
            save_config()
        end
        local q = st and st.read_json and try(st.read_json, QUEUE) or nil
        if type(q) == "table" and type(q.items) == "table" and q.schema == M.SCHEMA then
            queue = q.items
            while #queue > KC.queue_max do table.remove(queue, 1) end
            -- The wait was on the last session's clock (core.time restarts
            -- with the game): every item is due now. One tried before may
            -- already have been filed: looked for first.
            for i = 1, #queue do
                local it = queue[i]
                it.next_at = 0
                if (tonumber(it.tries) or 0) > 0 then it.check_first = true end
            end
        end
        T.queued = #queue
        local m = st and st.read_json and try(st.read_json, MODEL) or nil
        if type(m) == "table" and m.schema == M.SCHEMA and type(m.by_class) == "table" then
            model = m
            T.model_version, T.model_fights = tostring(m.version), tonumber(m.fights) or 0
        end
    end

    function M.config() load_all() return cfg end
    function M.contributor() load_all() return cfg.contributor end
    function M.queue() load_all() return queue end
    function M.model() load_all() return model end

    --- A new contributor id: what went up before is no longer linked to
    --- what goes up next (a pseudonym, not anonymity: the service may still
    --- hold the old records until deletion is asked for).
    function M.rotate_id()
        load_all()
        cfg.contributor = random_hex(24)
        T.id_rotations = T.id_rotations + 1
        save_config()
        return cfg.contributor
    end

    --- The queued local submissions, gone.
    function M.delete_queue()
        load_all()
        local n = #queue
        for i = n, 1, -1 do queue[i] = nil end
        save_queue()
        return n
    end

    -- --- the observations of a fight -----------------------------------------------------

    local obs = {}                  -- this fight's forecast observations
    local obs_dropped = 0

    local function hp_band(hp)
        hp = tonumber(hp) or 1
        if hp <= 0.2 then return 0 elseif hp <= 0.4 then return 1 elseif hp <= 0.6 then return 2 elseif hp <= 0.8 then return 3 end
        return 4
    end

    --- One forecast scored (predict.lua): kept for the fight's batch.
    --- `rec`: pattern, enemy_class, p, reliability, sure, basis, evidence,
    --- inputs_ok, hit, context { mode, threat, me_hp, controlled }, t.
    function M.observe(rec)
        if type(rec) ~= "table" then return end
        if #obs >= KC.observations_max then
            obs_dropped = obs_dropped + 1
            T.censored = T.censored + 1
            return
        end
        local p = tonumber(rec.p) or 0
        obs[#obs + 1] = {
            pattern = tostring(rec.pattern or "?"), enemy_class = tostring(rec.enemy_class or "?"),
            p = floor(p * 1000 + 0.5) / 1000, reliability = floor((tonumber(rec.reliability) or 0) * 1000 + 0.5) / 1000,
            sure = rec.sure == true, basis = tostring(rec.basis or "?"), evidence = floor((tonumber(rec.evidence) or 0) * 10 + 0.5) / 10,
            inputs_ok = rec.inputs_ok == true, hit = rec.hit == true, correct = ((p >= 0.5) == (rec.hit == true)),
            t = rec.t and floor(rec.t * 10 + 0.5) / 10 or nil,
            context = { mode = rec.context and rec.context.mode or nil, threat = rec.context and rec.context.threat or nil,
                        me_hp = hp_band(rec.context and rec.context.me_hp), controlled = rec.context and rec.context.controlled == true or false },
        }
        T.observations = T.observations + 1
    end

    local function game_name()
        local c = lib.client or {}
        return tostring(c.version or c.name or "?")
    end

    local function client_block()
        local c = lib.client or {}
        -- `model`: the version this client ran under, so the service can read
        -- what the rollout did in play (learn.js monitoring).
        return { plugin = tostring(plugin_version()), game = game_name(), build = tostring(c.exact or "?"),
                 schema = M.SCHEMA, model = T.model_version }
    end

    local function enqueue(kind, route, body)
        load_all()
        if #queue >= KC.queue_max then
            table.remove(queue, 1)
            T.dropped = T.dropped + 1
        end
        queue[#queue + 1] = { kind = kind, route = route, body = body, tries = 0, next_at = 0, id = body.id }
        save_queue()
    end

    --- The fight ended (debrief.lua): its batch of observations and its
    --- lesson go to the queue -- with consent, and stripped of names.
    function M.share(f)
        load_all()
        local batch_obs, n = obs, #obs
        obs, obs_dropped = {}, 0
        if not M.contributing() then return false end
        if not cfg.backend then return false end
        -- Test data never leaves the machine as live combat.
        if lib.episodes and lib.episodes.test_data and lib.episodes.test_data() then
            T.last_status = "test data is never uploaded"
            T.censored = T.censored + 1
            return false
        end
        local client = client_block()
        local me = { class = tostring(f.me.class or "?"), level = f.me.level }
        local encounter = { type = tostring(f.mode or "?"), duration = floor((f.duration or 0) + 0.5), outcome = tostring(f.outcome or "?"),
                            enemies = #f.foe_order }
        local enemies = {}
        for _, guid in ipairs(f.foe_order) do
            local r = f.foes[guid]
            enemies[#enemies + 1] = { class = r.class, role = r.role, level = r.level, used = r.used,
                                      controls_on_me = r.controls_on_me, bursts = r.bursts, trinket = r.trinket == true,
                                      hp_min = r.hp_min, died = r.died == true, fled = r.fled == true,
                                      time_on_me = floor((r.time_on_me or 0) + 0.5), patterns = r.patterns }
        end
        local codes = {}
        for i = 1, #(f.lessons or {}) do codes[i] = f.lessons[i].code end
        local diagnostics = nil
        if M.diagnostics() then
            local moments = {}
            for i = 1, #(f.moments or {}) do moments[i] = { t = floor((f.moments[i].t or 0) + 0.5), text = f.moments[i].text } end
            for i = 1, #moments do
                for _, guid in ipairs(f.foe_order) do
                    local name = f.foes[guid].name
                    if name and name ~= "" then moments[i].text = moments[i].text:gsub(name, "an enemy") end
                end
            end
            diagnostics = { moments = moments, states = f.states, threat_peak = f.threat_peak }
        end
        local fight_id = random_hex(24)        -- the batch and the lesson of one fight share it
        -- The fight's decision episodes (the collector), already compact and
        -- without names; at most this many, the rest counted.
        local episodes, summary = nil, nil
        if type(f.episodes) == "table" and #f.episodes > 0 then
            episodes = {}
            for i = 1, min(#f.episodes, KC.episodes_max) do episodes[i] = f.episodes[i] end
            summary = f.episodes_summary
            if summary then summary.uploaded = #episodes end
        end
        local batch = { schema = M.SCHEMA, id = random_hex(24), fight = fight_id, contributor = cfg.contributor, client = client, me = me,
                        encounter = encounter, observations = batch_obs, censored = obs_dropped > 0 and ("buffer full: " .. obs_dropped .. " dropped") or nil,
                        diagnostics = diagnostics, episodes = episodes, episodes_summary = summary }
        local lesson = { schema = M.SCHEMA, id = random_hex(24), fight = fight_id, contributor = cfg.contributor, client = client, me = me,
                         encounter = encounter, enemies = enemies, lessons = codes, predictions = f.predictions, baits = f.baits,
                         holds = f.holds, threat_peak = { level = f.threat_peak.level, score = f.threat_peak.score } }
        if n > 0 or episodes then enqueue("batch", "/v1/combat/batches", batch) end
        enqueue("lesson", "/v1/lessons", lesson)
        return true
    end

    --- Ask the service to forget every record under this id, then take a new id.
    function M.request_delete()
        load_all()
        if not cfg.backend then return false end
        local old = cfg.contributor
        table.insert(queue, 1, { kind = "delete", route = "/v1/privacy/delete", tries = 0, next_at = 0,
                                 body = { schema = M.SCHEMA, id = random_hex(24), contributor = old } })
        while #queue > KC.queue_max do table.remove(queue) end
        save_queue()
        T.deletions_requested = T.deletions_requested + 1
        M.rotate_id()
        return true
    end

    -- --- the uploads: one at a time, retried with backoff, never blocking -----------

    local function headers()
        return { ["X-Jambix-Key"] = cfg.key or "", ["X-Jambix-Contributor"] = cfg.contributor or "",
                 ["X-Jambix-Plugin"] = tostring(plugin_version()) }
    end

    -- GitHub as the service: the REST API (docs.github.com/rest), the
    -- version header it asks for, a bearer token scoped to issues (write)
    -- and contents (read) of the one repository, a User-Agent it requires.
    local GITHUB_API = "https://api.github.com"
    local GITHUB_BODY_MAX = 60000          -- an issue body holds 65536 characters

    local function github_headers(accept)
        local g = cfg.github
        return { ["Authorization"] = "Bearer " .. tostring(g and g.token or ""), ["Accept"] = accept or "application/vnd.github+json",
                 ["X-GitHub-Api-Version"] = "2022-11-28", ["User-Agent"] = "jambix-aio/" .. tostring(plugin_version()) }
    end

    --- An item's issue title: the kind and the record's id (a deletion: the
    --- contributor's), the same on every try.
    local function issue_title(item)
        local body = item.body or {}
        local who = item.kind == "delete" and tostring(body.contributor) or tostring(body.id)
        return string.format("jambix-%s %s", item.kind, who)
    end
    M.issue_title = issue_title

    --- The upload as a GitHub issue: the kind and the id in the title, the
    --- record as a fenced JSON block, trimmed to the body limit (the batch
    --- loses observations from the end and says so).
    local function github_issue(item)
        local body = item.body
        local text = encode_json(body)
        if #text > GITHUB_BODY_MAX and item.kind == "batch" and type(body.observations) == "table" then
            local dropped = 0
            while #text > GITHUB_BODY_MAX and #body.observations > 0 do
                table.remove(body.observations)
                dropped = dropped + 1
                body.censored = string.format("issue size: %d observation(s) dropped", dropped)
                text = encode_json(body)
            end
        end
        return { title = issue_title(item), body = "```json\n" .. text .. "\n```",
                 labels = { "jambix", "jambix-" .. item.kind } }
    end

    --- A refusal the service will repeat: the record is wrong, not the moment.
    local function refused_for_good(status)
        return status == 400 or status == 401 or status == 404 or status == 410 or status == 413 or status == 422
    end

    -- An outcome that cannot be read: the request may have reached the
    -- service (no status, or the server's own error). Live on 2026-10-12 one
    -- fight's batch was filed five times (issues #2-#6) while the client
    -- counted each try a failure, and the rest of the queue waited behind it.
    local function ambiguous(status) return status == 0 or status >= 500 end

    local function remove_item(item)
        for i = 1, #queue do
            if queue[i] == item then table.remove(queue, i) return true end
        end
        return false
    end

    local function warn(fmt, ...)
        if P.log and P.log.fmt then pcall(P.log.fmt, "warn", "central: " .. fmt, ...) end
    end

    --- Before trying again an item whose last try ended unclear, GitHub is
    --- asked whether its issue is already there (the last hundred of the
    --- network's issues, by title); found, it is done and never sent twice.
    local function check_filed(n, item)
        item.check_first = nil
        T.in_flight = true
        local title = issue_title(item)
        local url = string.format("%s/repos/%s/issues?state=all&labels=jambix&per_page=100", GITHUB_API, cfg.github.repo)
        local asked = try(n.get_json, url, { headers = github_headers(), ttl = 0, fresh = true }, function(list)
            T.in_flight = false
            if type(list) == "table" then
                for i = 1, #list do
                    local issue = list[i]
                    if type(issue) == "table" and issue.title == title then
                        remove_item(item)
                        T.uploaded, T.already = T.uploaded + 1, (T.already or 0) + 1
                        T.last_status = string.format("%s already filed (#%s): not sent again", item.kind, tostring(issue.number))
                        save_queue()
                        return
                    end
                end
            end
            save_queue()                    -- not found (or not asked): the next pass sends it
        end)
        if asked == false or asked == nil then T.in_flight = false end
    end

    local function pump_uploads(now)
        local item = queue[1]
        if not item or T.in_flight then return end
        if item.kind ~= "delete" and not M.contributing() then return end
        local n = net()
        if not (n and cfg.backend) then return end
        if now < (item.next_at or 0) then return end
        if item.check_first and cfg.backend == "github" then return check_filed(n, item) end
        local url, payload, opts
        if cfg.backend == "github" then
            url = string.format("%s/repos/%s/issues", GITHUB_API, cfg.github.repo)
            payload = github_issue(item)
            opts = { headers = github_headers(), ttl = 0, fresh = true }
        else
            url, payload, opts = cfg.url .. item.route, item.body, { headers = headers(), ttl = 0, fresh = true }
        end
        T.in_flight = true
        local sent = try(n.post_json, url, payload, opts,
            function(data_in, err, result)
                T.in_flight = false
                T.last_at = clock()
                local status = tonumber(result and result.status) or 0
                -- A 2xx is delivered whatever its answer says: the answer
                -- (GitHub's issue, the service's word) is not needed, and a
                -- reply the client could not read must not send it again.
                local delivered = not err or (result ~= nil and result.ok == true) or (status >= 200 and status < 300)
                if delivered or refused_for_good(status) then
                    -- Accepted, or refused for good (a bad record, a bad key): off the queue either way.
                    remove_item(item)
                    if delivered then
                        T.uploaded = T.uploaded + 1
                        T.last_status = string.format("%s accepted%s%s", item.kind, data_in and data_in.duplicate and " (duplicate)" or "",
                            err and (" (its answer unread: " .. tostring(err) .. ")") or "")
                        if err then warn("%s delivered (status %d) but its answer was unread: %s", item.kind, status, tostring(err)) end
                    else
                        warn("%s refused for good (status %d): %s", item.kind, status, tostring(err))
                        T.dropped = T.dropped + 1
                        T.last_status = string.format("%s refused (%s)", item.kind, tostring(err))
                    end
                else
                    item.tries = (item.tries or 0) + 1
                    T.failed = T.failed + 1
                    if cfg.backend == "github" and ambiguous(status) then item.check_first = true end
                    warn("%s try %d failed (status %d): %s", item.kind, item.tries, status, tostring(err))
                    if item.tries >= KC.max_tries then
                        remove_item(item)
                        T.dropped = T.dropped + 1
                        T.last_status = string.format("%s dropped after %d tries (%s)", item.kind, item.tries, tostring(err))
                    else
                        item.next_at = clock() + min(KC.backoff_base * 2 ^ (item.tries - 1), KC.backoff_max)
                        T.last_status = string.format("%s failed (%s), retry in %.0fs", item.kind, tostring(err), item.next_at - clock())
                    end
                end
                save_queue()
            end)
        if sent == false or sent == nil then
            T.in_flight = false
            item.tries = (item.tries or 0) + 1
            item.next_at = now + KC.backoff_base
            T.last_status = "the net service refused the request; retry later"
        end
    end

    -- --- the model: manifest, compatibility, download, cache -------------------------

    --- The staged rollout: a canary version reaches the share of clients its
    --- `rollout` names, chosen by the contributor id (the same client stays
    --- on the same side until the version is promoted to everyone).
    local function in_rollout(entry)
        if entry.stage ~= "canary" then return true end
        local share = tonumber(entry.rollout) or 100
        if share >= 100 then return true end
        local id = tostring(cfg.contributor or "")
        local sum = 0
        for i = 1, #id do sum = (sum + id:byte(i) * i) % 1000 end
        return (sum % 100) < share
    end

    local function compatible(entry)
        if type(entry) ~= "table" then return false, "not an entry" end
        if entry.status ~= "active" then return false, "not active" end
        if tonumber(entry.schema) ~= M.SCHEMA then return false, "schema " .. tostring(entry.schema) end
        local ours = vnum(plugin_version())
        if entry.min_plugin and ours < vnum(entry.min_plugin) then return false, "needs plugin " .. tostring(entry.min_plugin) end
        if entry.max_plugin and ours > vnum(entry.max_plugin) then return false, "for plugins up to " .. tostring(entry.max_plugin) end
        if not in_rollout(entry) then return false, "a canary for other clients (" .. tostring(entry.rollout) .. "%)" end
        return true
    end

    local function adopt_model(m)
        if type(m) ~= "table" or m.schema ~= M.SCHEMA or (type(m.games) ~= "table" and type(m.by_class) ~= "table") then
            T.model_err = "malformed model"
            return false
        end
        model = m
        T.model_version, T.model_fights, T.model_err = tostring(m.version), tonumber(m.fights) or 0, nil
        T.model_stage = m.release and m.release.gates and m.release.gates.decision or nil
        save(MODEL, m)
        return true
    end

    --- Where a file of the model lives: the service's route, or the data
    --- branch's file through GitHub's contents API, asked for raw.
    local function model_request(path_service, path_github)
        if cfg.backend == "github" then
            local g = cfg.github
            return string.format("%s/repos/%s/contents/%s?ref=%s", GITHUB_API, g.repo, path_github, g.branch),
                   { headers = github_headers("application/vnd.github.raw+json"), ttl = 0, fresh = true }
        end
        return cfg.url .. path_service, { headers = headers(), ttl = 0, fresh = true }
    end

    local function fetch_model(entry)
        local n = net()
        local url, opts = model_request("/v1/models/" .. tostring(entry.version), "data/models/v" .. tostring(entry.version) .. ".json")
        try(n.get_json, url, opts, function(data_in, err)
            if err then T.model_err = "model " .. tostring(entry.version) .. ": " .. tostring(err) return end
            adopt_model(data_in)
        end)
    end

    local function on_manifest(mf)
        if type(mf) ~= "table" or type(mf.versions) ~= "table" then
            T.manifest_err = "malformed manifest"
            return
        end
        T.manifest_err = nil
        local best, best_v, cached_ok = nil, -1, false
        for i = 1, #mf.versions do
            local e = mf.versions[i]
            local ok = compatible(e)
            if ok then
                local v = vnum(e.version)
                if v > best_v then best, best_v = e, v end
            end
            if model and tostring(e.version) == tostring(model.version) and ok then cached_ok = true end
        end
        if model and not cached_ok then
            -- Withdrawn, or no longer compatible: dropped; the local priors stand.
            T.last_status = "model " .. tostring(model.version) .. " withdrawn or incompatible: dropped"
            model, T.model_version, T.model_fights = nil, nil, 0
            save(MODEL, { schema = M.SCHEMA, version = nil, by_class = {}, fights = 0, dropped = true })
            model = nil
        end
        if best and (not model or tostring(model.version) ~= tostring(best.version)) then fetch_model(best) end
        if not best then T.model_err = "no compatible active model in the manifest" end
    end

    local function pump_downloads(now)
        if not M.downloading() then return end
        local n = net()
        if not (n and cfg.backend) then return end
        if (now - T.manifest_at) < KC.refresh_every then return end
        T.manifest_at = now
        local url, opts = model_request("/v1/models/manifest", "data/models/manifest.json")
        try(n.get_json, url, opts, function(data_in, err)
            if err then T.manifest_err = tostring(err) return end
            on_manifest(data_in)
        end)
        -- The service's status route; the repository has none (the manifest is its word).
        if cfg.backend == "http" and (now - T.server_at) >= KC.refresh_every then
            T.server_at = now
            try(n.get_json, cfg.url .. "/v1/client/status?plugin=" .. tostring(plugin_version()) .. "&schema=" .. M.SCHEMA,
                { headers = headers(), ttl = 0, fresh = true }, function(data_in, err)
                    if err then T.server_err = tostring(err) return end
                    T.server, T.server_err = data_in, nil
                end)
        end
    end

    local last_S = nil            -- the state as the last tick read it (the context of a prior)

    --- Once a tick, between frames: the uploads and the downloads, both
    --- asynchronous; nothing here waits.
    function M.update(W, S, now)
        load_all()
        last_S = S
        pump_uploads(now)
        pump_downloads(now)
        return T
    end

    -- --- what the model says -------------------------------------------------------------

    -- The learning groups (tools/fightlog_server/groups.js): the keys a
    -- model files its rates under, narrowest first, every one carrying the
    -- game. The client walks them the same way (the backoff) and never
    -- reads across the game.
    local LEVELS = { "exact", "matchup", "class", "general" }

    local function bracket(level)
        level = tonumber(level)
        if not level or level < 1 then return "?" end
        if level >= 60 then return "60" end
        local lo = floor(level / 10) * 10
        return string.format("%d-%d", lo, lo + 9)
    end

    --- The context a prior is asked in: this game, your class and level,
    --- the opponent's class, the encounter, alone or outnumbered.
    function M.context(class)
        local S = last_S
        local me_class = lib.my_class and lib.my_class() or nil
        local attackers = S and tonumber(S.attackers) or nil
        return {
            game = game_name(), me_class = tostring(me_class or "?"), enemy_class = tostring(class or "?"),
            bracket = bracket(S and S.me and S.me.level), encounter = tostring(S and S.mode and S.mode.kind or "?"),
            combat = attackers == nil and "?" or (attackers >= 2 and "outnumbered" or "1v1"),
        }
    end

    local function key_at(ctx, level)
        if level == "general" then return "g:" .. ctx.game end
        if level == "class" then return string.format("g:%s|e:%s", ctx.game, ctx.enemy_class) end
        if level == "matchup" then return string.format("g:%s|me:%s|e:%s", ctx.game, ctx.me_class, ctx.enemy_class) end
        return string.format("g:%s|me:%s|e:%s|lv:%s|enc:%s|%s", ctx.game, ctx.me_class, ctx.enemy_class, ctx.bracket, ctx.encounter, ctx.combat)
    end
    M.key_at = key_at

    -- Broader evidence, less certainty (the brief: "use broader compatible
    -- evidence with reduced certainty"): a level's rate is drawn toward even
    -- odds by these, the same as tools/fightlog_server/groups.js CERTAINTY.
    local CERTAINTY = { exact = 1.0, matchup = 0.85, class = 0.7, general = 0.5 }
    M.CERTAINTY = CERTAINTY

    local function usable(e, level)
        if type(e) ~= "table" then return nil end
        local n = tonumber(e.n) or 0
        if e.unreliable or n < KC.min_fights then return nil, n end
        local p = tonumber(e.p)
        if not p then return nil, n end
        p = 0.5 + (p - 0.5) * (CERTAINTY[level] or CERTAINTY.class)
        return max(K.PREDICT.prior_min, min(K.PREDICT.prior_max, p)), n
    end

    --- The network's rate for a pattern against this class: the narrowest
    --- learning group of this game that holds a reliable entry with enough
    --- fights behind it (exact, matchup, class, general), drawn toward even
    --- odds by that level's certainty, with the fights and the level it
    --- came from; nil when none does. An older model without groups answers
    --- from its class table, as the class level.
    function M.prior_for(class, key)
        load_all()
        if not (model and class) then return nil, 0 end
        if type(model.games) == "table" then
            local ctx = M.context(class)
            local G = model.games[ctx.game]
            local groups = G and G.groups or nil
            if type(groups) ~= "table" then return nil, 0 end
            for i = 1, #LEVELS do
                local g = groups[key_at(ctx, LEVELS[i])]
                local e = g and g.patterns and g.patterns[key] or nil
                if e then
                    local p, n = usable(e, LEVELS[i])
                    if p then return p, n, LEVELS[i] end
                end
            end
            return nil, 0
        end
        local by = model.by_class and model.by_class[class] or nil
        local e = by and by.patterns and by.patterns[key] or nil
        if not e then return nil, 0 end
        local p, n = usable(e, "class")
        if not p then return nil, n end
        return p, n, "class"
    end

    local function class_table(class)
        if not (model and class) then return nil end
        if type(model.games) == "table" then
            local G = model.games[game_name()]
            return G and G.by_class and G.by_class[class] or nil, G
        end
        return model.by_class and model.by_class[class] or nil, nil
    end

    --- What the network says about this opponent class, in words: the
    --- matchup's outcomes, the lesson codes that told won from lost, and the
    --- validated tactical associations (never a rule: words and numbers).
    function M.advice_for(class)
        load_all()
        local by, G = class_table(class)
        if not by then return {} end
        local out = {}
        local o = by.outcomes or {}
        local total = 0
        for _, v in pairs(o) do total = total + (tonumber(v) or 0) end
        if total > 0 then
            out[#out + 1] = string.format("vs %s: %d fight(s) in the network, won %d, lost %d", string.lower(class), total, o.won or 0, o.lost or 0)
        end
        for i = 1, min(3, #(by.advice or {})) do
            local a = by.advice[i]
            out[#out + 1] = string.format("%s (won %d%%, lost %d%%)", tostring(a.text), floor((a.won or 0) * 100 + 0.5), floor((a.lost or 0) * 100 + 0.5))
        end
        if G and type(G.tactics) == "table" then
            local me_class = lib.my_class and lib.my_class() or nil
            local n = 0
            for i = 1, #G.tactics do
                local t = G.tactics[i]
                if t.validated and t.enemy_class == class and (t.me_class == nil or t.me_class == me_class) and n < 2 then
                    out[#out + 1] = "association: " .. tostring(t.text)
                    n = n + 1
                end
            end
        end
        return out
    end

    function M.status()
        load_all()
        if not net() then return "off: no network service in this loader" end
        if not cfg.backend then return "off: no central address (modules/central_config.lua or scripts_data/" .. CONFIG .. ")" end
        local host = cfg.backend == "github" and ("github.com/" .. cfg.github.repo) or (cfg.url:match("^%a+://([^/]+)") or cfg.url)
        local bits = {}
        bits[#bits + 1] = M.contributing() and string.format("contributing to %s: %d queued, %d uploaded, %d dropped", host, #queue, T.uploaded, T.dropped)
            or string.format("not contributing (off); %d queued locally", #queue)
        if T.last_status then bits[#bits + 1] = T.last_status end
        if M.downloading() then
            bits[#bits + 1] = model and string.format("model v%s from %d fight(s)", tostring(model.version), T.model_fights) or ("no model yet" .. (T.model_err and (": " .. T.model_err) or ""))
        else
            bits[#bits + 1] = model and ("downloads off; cached model v" .. tostring(model.version)) or "downloads off"
        end
        if T.server and T.server.message then bits[#bits + 1] = tostring(T.server.message) end
        return table.concat(bits, "; ")
    end

    function M.reset()
        T.in_flight = false
        obs, obs_dropped = {}, 0
    end

    return M
end

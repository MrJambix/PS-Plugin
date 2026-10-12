-- Jambix AIO / guidewalk -- follow the RestedXP guide with Sentinel Navigation (1.7.4).
--
-- The user, 2026-10-09: "add sentinel to the Rested EXP as an option so it
-- now follows quests from rested exp automaticlaly and does it for it too".
--
-- ONE SWITCH, OFF BY DEFAULT: "Follow the guide with Sentinel Navigation"
-- (Quests page, RestedXP). On, it does what RestedXP's current step says:
--
--   TURN IN / ACCEPT  walks to the npc who takes the quest back or hands it
--             out -- by the quest database's givers and enders, the quest
--             marks, or the step's own .target names -- talks to it, and
--             answers its windows for THE GUIDE'S QUESTS ONLY: the turn-in
--             first, then the pick-up; the reward the guide names, else the
--             one modules/rewards.lua chooses (Forever's quest givers'
--             choice). A quest that starts or ends at something in the world
--             (a wanted poster) is used instead.
--   COMPLETE  the step's mobs (the quest marks for its quests, its .mob
--             names) are walked to and pulled: the target is set and the
--             rotation opens on it (rotation.may_engage_unit asks pulling());
--             with the rotation off, an attack is started. The fight is the
--             rotation's. The step's quest objects are walked to and used.
--             Stickies' mobs are pulled when within NEAR yards.
--   LOOT      a corpse of yours within LOOT_RANGE is walked to and looted
--             (by auto-loot when that is on, else by this).
--   GOTO      the guide's waypoint is walked to; RestedXP ticks the step off.
--   ANYTHING ELSE  (a hearthstone, a flight, a trainer, an item to use...)
--             the waypoint is walked to and the walk waits, saying what the
--             step wants, until the step changes.
--
-- A SECOND SWITCH, OFF BY DEFAULT (1.8.1): "Act on the guide's marks as you
-- walk up to them" (rxp_act). The user, 2026-10-11: "let's make RestedExp
-- ESP - Allow Quest Grab, allow the Combat System to work with it and Turn
-- in quests". You move, by the ESP's marks, its panel and its line; nothing
-- walks you and nothing holds a key. Within ACT_REACH of the npc (or the
-- object) the step's quest goes back to or comes from, it talks and answers
-- the windows as the walk does, for the step's quests only (two switches:
-- pick up, hand in). A mob the step wants killed, within pull range, is the
-- rotation's to open on -- pulling() and pull_target(), as for the walk --
-- and is never selected, faced or hit by this. No quest object is used,
-- nothing is looted (auto-loot does that) and no mount is got off. Both
-- switches on: the walk wins; it does all of this and moves you too.
--
-- HOW IT WALKS. Sentinel Navigation through JCore's ctx.nav, as the Market's
-- mail run does (its log on 2026-10-09: "Sentinel is moving you (state
-- navigating)"). Watched like the mail run: not moved within NAV_PROVE s, no
-- yard gained in STALL s (planned again REPLANS times), or a route Sentinel
-- gives up -- then a target within LINE_MAX yards is walked straight at
-- (facing it, holding forward, a jump and a sidestep when stuck), and a
-- farther one pauses the walk for FAIL_PAUSE s and says why. A moving target
-- is planned again when it has gone REPLAN_MOVE yards.
--
-- IT WAITS (lets go of every key, says why) while: you are dead; in combat
-- (the rotation fights); resting (rest.recovering) or under PULL_HP health
-- before a pull; you steer (W, A, S, D, Q, E, Space or an arrow key; for
-- STEER_PAUSE s after); hardcore says no pull (hardcore.may_pull); a loot or
-- quest window is open; or Sentinel is not connected. Never on an ESP-only
-- client (main.lua's ESP_ONLY_OFF): JCore's nav takes its own lease and
-- would get round the AIO's input lock there.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local opt = P.opt
    local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

    local M = {}

    local SCAN_EVERY = 0.5        -- s between looks at the step and the world
    local ARRIVE = 4.0            -- yd from a waypoint: there
    local TALK_REACH = 4.0        -- yd: close enough to talk or use (the client's ~5)
    local ACT_REACH = 5.0         -- yd: you stood by the quest giver yourself (the ESP acting)
    local LOOT_REACH = 3.5
    local MELEE_PULL = 4.0        -- yd from a mob before a melee class opens
    local RANGED_PULL = 26        -- yd for a caster or a hunter
    local NEAR = 30               -- yd: a sticky's mob or a corpse this close is worth it
    local LOOT_RANGE = 30
    local LOOT_WAIT = 5           -- s at a corpse before it is left
    local PULL_HP = 0.6           -- health a pull wants, without the rest module
    local PULL_WAIT = 5           -- s in pull range with no fight before walking closer
    local PULL_CLOSER = 2         -- times; then the mob is left for a while
    local TALK_WAIT = 4           -- s for a window to open after a talk
    local TALK_TRIES = 3
    local WINDOW_OURS = 10        -- s after a talk that a quest window is ours to answer
    local REACT_MIN, REACT_SPAN = 0.2, 0.3   -- a window is answered this long after it opens
    local INFO_WAIT = 2.0         -- s a reward choice waits for its item data
    local SKIP_FOR = 60           -- s a target that came to nothing is left alone
    local REPLAN_MOVE = 5         -- yd a target moves before its route is planned again
    local REPLAN_GAP = 2.0
    local NAV_PROVE = 6           -- s for Sentinel to have moved you
    local STALL = 10              -- s without a yard gained, on Sentinel
    local REPLANS = 2
    local LINE_MAX = 40           -- yd: walked straight at when Sentinel cannot
    local UNSTICK_AFTER = 1.5     -- s without progress walking straight
    local UNSTICKS = 4
    local SIDESTEP = 0.6
    local FAIL_PAUSE = 20         -- s after a walk gives up
    local NAV_STRIKES = 3         -- walks in a row Sentinel never moved: it is not working
    local STEER_PAUSE = 3         -- s after your own key
    local PRIORITY = 30           -- over idle; a rotation, a kite or a defensive comes first
    local QUESTGIVER = 0x2        -- UNIT_NPC_FLAG_QUESTGIVER
    local MAX_CHOICES = 10
    local MAX_GREETING = 10
    local SHIFT = 0x10

    -- W A S D Q E, Space, the arrows: you are steering.
    local STEER_KEYS = { 0x57, 0x41, 0x53, 0x44, 0x51, 0x45, 0x20, 0x25, 0x26, 0x27, 0x28 }
    local RANGED_CLASS = { HUNTER = true, MAGE = true, WARLOCK = true, PRIEST = true }

    local load = P.load or function(path) return require("jambix_aio/" .. path) end
    local rewards = load("modules/rewards")

    local function now() return core.time() end

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    --- A method on a game object, through pcall (a missing one is nil).
    local function call(obj, method, ...)
        if obj == nil then return nil end
        local fn = obj[method]
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, obj, ...)
        if ok then return v end
        return nil
    end

    --- `core.<namespace>.<field>(...)`, read at call time.
    local function native(namespace, field, ...)
        local group = type(core) == "table" and core[namespace] or nil
        local fn = type(group) == "table" and group[field] or nil
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function copy(p)
        if not p then return nil end
        return { x = p.x, y = p.y, z = p.z or 0 }
    end

    local function flat(a, b)
        if not a or not b then return math.huge end
        local dx, dy = a.x - b.x, a.y - b.y
        return sqrt(dx * dx + dy * dy)
    end

    local function me() return units.player_position() end

    local nav = ctx.nav
    local input = ctx.input
    local CHANNEL = input and input.CHANNEL or {}

    -- --- what happened, for the page and the trace ----------------------------------

    local state = { text = "off", tone = "text_dim", job = nil, step = nil }
    local recent = {}             -- the last few lines, newest last
    local stats = { talks = 0, accepted = 0, turned_in = 0, pulls = 0, uses = 0, loots = 0, walks = 0, line_walks = 0,
        nav_drops = 0 }

    local function note(fmt, ...)
        local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        log.fmt("info", "guide walk: %s", text)
        if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", "guide walk: " .. text) end
        recent[#recent + 1] = { t = now(), text = text }
        while #recent > 12 do table.remove(recent, 1) end
    end

    local function say(text, tone)
        state.text, state.tone = text, tone or "text"
    end

    -- --- the switch ---------------------------------------------------------------

    --- "walk" (Follow the guide with Sentinel Navigation), "act" (the ESP
    --- acts as you walk up, 1.8.1) or nil. Both on: the walk, which does
    --- everything the other does and moves you too.
    local function mode()
        if P.esp_only then return nil end
        if P.master_on and not P.master_on() then return nil end
        if opt("rxp_follow", false) == true then return "walk" end
        if opt("rxp_act", false) == true then return "act" end
        return nil
    end

    local function switched_on() return mode() ~= nil end
    local function acting() return mode() == "act" end

    --- What this mode looks for and answers: the walk's four switches, or
    --- the ESP's three (no objects and no loot there).
    local function wants_of()
        local range = opt("rxp_follow_range", 60)
        if acting() then
            local accept, turnin = opt("rxp_act_accept", true) == true, opt("rxp_act_turnin", true) == true
            return { talk = accept or turnin, accept = accept, turnin = turnin,
                fight = opt("rxp_act_fight", true) == true, use = false, loot = false, range = range }
        end
        local talk = opt("rxp_follow_talk", true) == true
        return { talk = talk, accept = talk, turnin = talk, fight = opt("rxp_follow_fight", true) == true,
            use = opt("rxp_follow_use", true) == true, loot = opt("rxp_follow_loot", true) == true, range = range }
    end

    -- --- holding and letting go -----------------------------------------------------

    local held = false            -- keys or a route of ours may be live

    local function let_go()
        if not held then return end
        held = false
        if input then
            for _, key in ipairs({ "forward", "left", "right" }) do try(input.set_key, key, false) end
            try(input.release, CHANNEL.MOVEMENT)
            try(input.release, CHANNEL.FACING)
        end
        if nav then try(nav.stop) end
    end

    local function hold()
        if not input then return false end
        held = true
        local ok = input.acquire(CHANNEL.MOVEMENT, PRIORITY, "guide walk") and true or false
        ok = (input.acquire(CHANNEL.FACING, PRIORITY, "guide walk") and ok) and true or false
        return ok
    end

    -- --- walking --------------------------------------------------------------------

    local leg = nil               -- the walk under way
    local leg_seq = 0
    local nav_strikes = 0         -- walks in a row Sentinel did not move you on
    local paused_until = 0
    local pause_why = nil

    local function nav_up()
        return nav ~= nil and try(nav.available) == true
    end

    --- Starts a walk to `goal` (a position), unless one to the same place is
    --- under way. `key` names what is walked to, so a moving target keeps its
    --- walk and only plans again when it has gone REPLAN_MOVE yards.
    local function walk_to(t, key, goal, reach, label)
        if leg and leg.key == key then
            if flat(leg.goal, goal) > REPLAN_MOVE and t - (leg.retarget_at or 0) >= REPLAN_GAP then
                leg.goal, leg.retarget_at = copy(goal), t
                if leg.mode == "nav" and leg.started then leg.started, leg.restart = false, true end
            end
            leg.reach, leg.label = reach, label
            return
        end
        if leg then let_go() end
        local pos = me()
        local d = flat(pos, goal)
        local mode = nav_up() and "nav" or (d <= LINE_MAX and "line" or nil)
        if not mode then
            leg = nil
            say("Sentinel Navigation is not connected, and " .. label .. " is " .. floor(d) .. " yd away", "warning")
            return
        end
        leg = { key = key, goal = copy(goal), reach = reach, label = label, mode = mode, at = t,
            limit = max(60, d / 3 + 30), best = -math.huge, best_at = t, replans = 0, unsticks = 0,
            started = false, proved = false }
        stats.walks = stats.walks + 1
        if mode == "line" then stats.line_walks = stats.line_walks + 1 end
        note("walking to %s (%.0f yd, %s)", label, d, mode == "nav" and "Sentinel" or "straight at it")
    end

    local function stop_walk()
        leg = nil
        let_go()
    end

    local function leg_failed(t, why)
        note("gave up walking to %s: %s", leg and leg.label or "?", why)
        stop_walk()
        paused_until, pause_why = t + FAIL_PAUSE, why
    end

    --- Sentinel is given up on for this walk: straight at it when it is
    --- near enough, else the walk stops.
    local function drop_nav(t, pos, why)
        stats.nav_drops = stats.nav_drops + 1
        try(nav.stop)
        if flat(pos, leg.goal) > LINE_MAX then
            return leg_failed(t, "Sentinel " .. why .. ", and " .. leg.label .. " is too far to walk straight at")
        end
        note("Sentinel %s; walking straight at %s", why, leg.label)
        leg.mode, leg.best, leg.best_at, leg.unsticks = "line", -math.huge, t, 0
        stats.line_walks = stats.line_walks + 1
    end

    local function step_nav(t, pos)
        if not hold() then
            -- Something with a higher claim is moving you (JCore stops our
            -- route): start again when it lets go.
            leg.started, leg.best_at = false, t
            return
        end
        if not leg.started then
            leg.started, leg.started_at = true, t
            if not leg.restart then leg.start_pos = copy(pos) end
            leg_seq = leg_seq + 1
            local id = leg_seq
            leg.id, leg.done = id, nil
            local ok = nav.move_to(leg.goal, { priority = PRIORITY, reason = "guide walk",
                on_done = function(done_ok, why)
                    if leg and leg.id == id then leg.done, leg.done_ok, leg.why = true, done_ok, why end
                end })
            if not ok then return drop_nav(t, pos, "would not start a route") end
            return
        end
        if not leg.proved then
            if flat(pos, leg.start_pos) >= 1.0 then
                leg.proved = true
                leg.best, leg.best_at = -flat(pos, leg.goal), t
                nav_strikes = 0
            elseif t - leg.started_at >= NAV_PROVE then
                nav_strikes = nav_strikes + 1
                return drop_nav(t, pos, string.format("did not move you in %ds (%s%s)", NAV_PROVE,
                    tostring(try(nav.state) or "?"), leg.why and (", " .. tostring(leg.why)) or ""))
            end
            return
        end
        local d = flat(pos, leg.goal)
        if -d > leg.best + 1 then leg.best, leg.best_at = -d, t end
        if leg.done and not leg.done_ok then
            return drop_nav(t, pos, "gave up the route" .. (leg.why and (" (" .. tostring(leg.why) .. ")") or ""))
        end
        if not nav.is_moving() then
            -- Sentinel thinks it is there and it is not: plan again, then straight at it.
            if leg.replans < REPLANS then
                leg.replans, leg.started, leg.restart = leg.replans + 1, false, true
                return
            end
            return drop_nav(t, pos, "stopped short")
        end
        if t - leg.best_at > STALL then
            if leg.replans >= REPLANS then return drop_nav(t, pos, "made no progress") end
            leg.replans, leg.best_at = leg.replans + 1, t
            note("no progress to %s on Sentinel: planning again (%d)", leg.label, leg.replans)
            try(nav.replan, "no progress")
        end
    end

    local function step_line(t, pos)
        local d = flat(pos, leg.goal)
        if -d > leg.best + 0.5 then leg.best, leg.best_at = -d, t end
        if not hold() then
            for _, key in ipairs({ "forward", "left", "right" }) do try(input.set_key, key, false) end
            leg.side, leg.best_at = nil, t
            return
        end
        if leg.side and t >= leg.side.until_t then
            input.set_key(leg.side.key, false)
            leg.side, leg.best_at = nil, t
        end
        input.look_at(leg.goal)
        input.set_key("forward", true)
        if not leg.side and t - leg.best_at > UNSTICK_AFTER then
            if leg.unsticks >= UNSTICKS then return leg_failed(t, "stuck walking to " .. leg.label) end
            leg.unsticks = leg.unsticks + 1
            local key = leg.unsticks % 2 == 1 and "left" or "right"
            try(input.jump)
            input.set_key(key, true)
            leg.side = { key = key, until_t = t + SIDESTEP }
        end
    end

    --- One tick of the walk under way: true once within its reach.
    local function walk_tick(t, pos)
        if not leg then return false end
        if flat(pos, leg.goal) <= leg.reach then
            -- Said, so the trace shows Sentinel's walks arriving, not only starting.
            note("got to %s (%s, %.0fs)", leg.label, leg.mode == "nav" and "Sentinel" or "straight", t - leg.at)
            let_go()
            leg = nil
            return true
        end
        if t - leg.at > leg.limit then
            leg_failed(t, string.format("took over %ds to reach %s", floor(leg.limit), leg.label))
            return false
        end
        if leg.mode == "nav" then step_nav(t, pos) else step_line(t, pos) end
        return false
    end

    -- --- reading the step -------------------------------------------------------------

    local skip = {}               -- guid -> until when it is left alone
    local function skipped(guid, t) return guid and skip[guid] and skip[guid] > t end

    local function key_of(text) return P.quests.guide_key(text) end

    --- Does a unit's name stand for one in a list of names (or npc ids)?
    local function in_names(list, name, npc_id)
        if #list == 0 then return false end
        local k = name and name ~= "" and key_of(name) or nil
        for i = 1, #list do
            local want = list[i]
            if type(want) == "number" then
                if npc_id == want then return true end
            elseif k and want.key == k then
                return true
            end
        end
        return false
    end

    --- What the current step wants that is not done, or nil and why not.
    local function read_step()
        local quests = P.quests
        local rxp = quests and quests.rxp
        if type(rxp) ~= "table" or not rxp.loaded then return nil, "RestedXP is not loaded" end
        local step = rxp.step
        if type(step) ~= "table" or (tonumber(step.num) or 0) == 0 then
            return nil, "RestedXP has no step: pick a guide in RestedXP"
        end
        if step.active == false then
            local why = (type(step.requires) == "string" and step.requires ~= "") and (" (needs " .. step.requires .. ")")
                or ((tonumber(step.level) or 0) > 0 and string.format(" (needs level %d)", step.level) or "")
            return nil, string.format("step %d is not active yet%s", step.num, why)
        end
        -- A goto step's waypoint often has no title ("" -- in game it said
        -- "walking to  (15210 yd, Sentinel)"): its goal's words, else the step.
        local title = rxp.waypoint and rxp.waypoint.title
        if type(title) ~= "string" or title == "" then
            title = nil
            for i = 1, #(step.goals or {}) do
                local g = step.goals[i]
                if type(g) == "table" and g.action == "goto" and type(g.text) == "string" and g.text ~= "" then
                    title = g.text
                    break
                end
            end
        end
        local w = { num = step.num, accept = {}, turnin = {}, complete = {}, near = {}, talk_names = {}, mob_names = {},
            any_accept = false, any_turnin = false, any_complete = false, other = nil, waypoint = rxp.world_waypoint,
            waypoint_title = title or string.format("step %d's waypoint", step.num), stops = rxp.step_waypoints or {},
            away = rxp.waypoint_away }

        local function names(goal, into)
            if type(goal.units) ~= "table" then return end
            for i = 1, #goal.units do
                local u = goal.units[i]
                if type(u) == "number" then
                    into[#into + 1] = u
                elseif type(u) == "string" and u ~= "" then
                    local id = tonumber(u)
                    if id then into[#into + 1] = id else into[#into + 1] = { key = key_of(u), text = u } end
                end
            end
        end

        local function absorb(s, sticky)
            if type(s) ~= "table" or type(s.goals) ~= "table" then return end
            for i = 1, #s.goals do
                local g = s.goals[i]
                if type(g) == "table" and not g.is_complete and not g.text_only then
                    local action = type(g.action) == "string" and g.action or ""
                    local qid = tonumber(g.quest_id) or 0
                    if sticky then
                        if (action == "complete" or action == "collect") and qid > 0 then w.near[qid] = g end
                        if action == "mob" or action == "unitscan" then names(g, w.mob_names) end
                    elseif action == "accept" and qid > 0 then
                        w.accept[qid], w.any_accept = g, true
                    elseif action == "turnin" and qid > 0 then
                        w.turnin[qid], w.any_turnin = g, true
                    elseif (action == "complete" or action == "collect") and qid > 0 then
                        w.complete[qid], w.any_complete = g, true
                    elseif action == "mob" or action == "unitscan" then
                        names(g, w.mob_names)
                        w.any_complete = true
                    elseif action == "target" then
                        names(g, w.talk_names)
                    elseif action == "goto" or action == "" then
                        -- the waypoint is the goal
                    elseif not w.other then
                        w.other = g
                    end
                end
            end
        end
        absorb(step, false)
        for i = 1, #(rxp.stickies or {}) do absorb(rxp.stickies[i], true) end
        return w, nil
    end

    -- --- finding what the step wants in the world -------------------------------------------

    local function quest_entries(obj, name, npc_id, is_object)
        local q = P.quests
        if not (q and q.quest_entries) then return nil end
        local ok, list = pcall(q.quest_entries, obj, name, npc_id or false, is_object)
        if ok and type(list) == "table" then return list end
        return nil
    end

    local function entry_for(list, ids, tags)
        if not list then return nil end
        for i = 1, #list do
            local e = list[i]
            if e.quest and ids[e.quest.id] and (tags == nil or tags[e.tag or ""]) then return e end
        end
        return nil
    end

    local TALK_TAGS = { pick_up = true, turn_in = true }
    local KILL_TAGS = { kill = true, collect = true }
    local USE_TAGS = { use = true, collect = true }

    --- Is this unit one the step wants to talk to, for a kind `wants` has
    --- on (turnin, accept)? The quest it is for and the kind, or nil.
    local function talk_quest(w, u, name, npc_id, wants)
        if wants.turnin then
            for qid in pairs(w.turnin) do
                local people = P.quests.quest_people and P.quests.quest_people(qid)
                if people and npc_id and people.enders[npc_id] then return qid, "turnin" end
            end
        end
        if wants.accept then
            for qid in pairs(w.accept) do
                local people = P.quests.quest_people and P.quests.quest_people(qid)
                if people and npc_id and people.givers[npc_id] then return qid, "accept" end
            end
        end
        local ids = {}
        if wants.turnin then for qid in pairs(w.turnin) do ids[qid] = true end end
        if wants.accept then for qid in pairs(w.accept) do ids[qid] = true end end
        local e = entry_for(quest_entries(u, name, npc_id, false), ids, TALK_TAGS)
        if e then return e.quest.id, e.turn_in and "turnin" or "accept" end
        if in_names(w.talk_names, name, npc_id) then
            local how = w.any_turnin and "turnin" or "accept"
            if wants[how] then return 0, how end
        end
        return nil
    end

    local function hostile(player, u)
        if call(u, "is_dead") then return false end
        if call(u, "is_player") or call(u, "is_pet") then return false end
        if call(player, "can_attack", u) ~= true then return false end
        local targeting = P.targeting
        if targeting and targeting.others_mob and targeting.others_mob(u) then return false end
        return true
    end

    --- The nearest thing the step wants, of each kind: { obj, guid, pos, d, name, qid, kind }.
    local function scan(w, t)
        local player = units.player()
        local pos = me()
        if not player or not pos then return {} end
        local wants = wants_of()
        local range = wants.range
        local want_ids, near_ids = {}, {}
        for qid in pairs(w.complete) do want_ids[qid] = true end
        for qid in pairs(w.near) do near_ids[qid] = true end
        local found = {}

        local function consider(kind, obj, name, d, qid, extra)
            local best = found[kind]
            if best and best.d <= d then return end
            local guid = units.guid and units.guid(obj) or call(obj, "get_guid")
            if not guid or skipped(guid, t) then return end
            found[kind] = { obj = obj, guid = guid, pos = copy(units.position(obj)), d = d, name = name, qid = qid,
                why = extra }
        end

        local talk_on, fight_on = wants.talk, wants.fight
        local list = units.units() or {}
        for i = 1, #list do
            local u = list[i]
            local d = units.distance(u)
            if d <= range then
                local name = units.name and units.name(u) or call(u, "get_name")
                local npc_id = tonumber(call(u, "get_npc_id"))
                if npc_id and npc_id <= 0 then npc_id = nil end
                if talk_on and (w.any_turnin or w.any_accept or #w.talk_names > 0) and not call(u, "is_dead")
                    and not call(u, "is_player") and call(player, "can_attack", u) ~= true then
                    local qid, how = talk_quest(w, u, name, npc_id, wants)
                    if qid then consider("talk", u, name, d, qid, how) end
                end
                if fight_on and hostile(player, u) then
                    local e = entry_for(quest_entries(u, name, npc_id, false), want_ids, KILL_TAGS)
                    local near_e = (not e and d <= NEAR) and entry_for(quest_entries(u, name, npc_id, false), near_ids,
                        KILL_TAGS) or nil
                    if e or near_e then
                        consider("fight", u, name, d, (e or near_e).quest.id)
                    elseif in_names(w.mob_names, name, npc_id) then
                        consider("fight", u, name, d, 0)
                    elseif w.any_complete and P.quests.guide_goal then
                        local ok, goal = P.quests.guide_goal(name or "")
                        if ok and goal and (goal.action == "complete" or goal.action == "mob") then
                            consider("fight", u, name, d, 0)
                        end
                    end
                end
            end
        end

        local objects = units.objects() or {}
        local talk_ids = {}
        if wants.turnin then for qid in pairs(w.turnin) do talk_ids[qid] = "turnin" end end
        if wants.accept then for qid in pairs(w.accept) do talk_ids[qid] = talk_ids[qid] or "accept" end end
        for i = 1, #objects do
            local o = objects[i]
            local d = units.distance(o)
            if d <= range then
                local name = call(o, "get_name")
                local id = tonumber(call(o, "get_npc_id"))
                if id and id <= 0 then id = nil end
                if talk_on and next(talk_ids) then
                    for qid, how in pairs(talk_ids) do
                        local people = P.quests.quest_people and P.quests.quest_people(qid)
                        local set = people and (how == "turnin" and people.ender_objects or people.giver_objects)
                        if set and id and set[id] then consider("talk", o, name, d, qid, how) end
                    end
                end
                if wants.use and next(want_ids) then
                    local e = entry_for(quest_entries(o, name, id, true), want_ids, USE_TAGS)
                    if e then consider("use", o, name, d, e.quest.id) end
                end
            end
        end

        if wants.loot and P.esp and P.esp.corpses then
            local corpses = P.esp.corpses() or {}
            local actions = P.actions
            for i = 1, #corpses do
                local c = corpses[i]
                if not c.skinnable and c.distance <= LOOT_RANGE and not skipped(c.guid, t)
                    and not (actions and actions.is_blacklisted and actions.is_blacklisted(c.guid)) then
                    if not found.loot or c.distance < found.loot.d then
                        found.loot = { obj = c.obj, guid = c.guid, pos = copy(units.position(c.obj)), d = c.distance,
                            name = "your kill" }
                    end
                end
            end
        end

        -- Last: a quest giver standing on the guide's waypoint, when the
        -- step wants a talk and nothing above named one.
        local how = w.any_turnin and "turnin" or "accept"
        if talk_on and wants[how] and not found.talk and (w.any_turnin or w.any_accept) and w.waypoint
            and flat(pos, w.waypoint) <= 12 then
            for i = 1, #list do
                local u = list[i]
                local flags = tonumber(call(u, "get_npc_flags")) or 0
                local up = units.position(u)
                if floor(flags / QUESTGIVER) % 2 == 1 and up and flat(up, w.waypoint) <= 8
                    and not call(u, "is_player") then
                    consider("talk", u, units.name and units.name(u) or call(u, "get_name"), units.distance(u), 0, how)
                end
            end
        end
        return found
    end

    -- --- the quest windows ------------------------------------------------------------------

    local talk = nil              -- { guid, at, tries, kind, qid, w }: the npc being talked to
    local ours_until = 0          -- quest windows opening before this are ours to answer
    local window = nil            -- { kind, at, due }
    local current = nil           -- the step read last (for the window answers)

    local function forever_answers(kind)
        if not P.forever_npc then return false end
        if kind == "accept" then return opt("npc_accept_quests", false) == true end
        if kind == "progress" or kind == "complete" then return opt("npc_turn_in_quests", false) == true end
        return opt("npc_accept_quests", false) == true or opt("npc_turn_in_quests", false) == true
    end

    local function open_window(kind)
        if not switched_on() then return end
        if now() > ours_until then return end
        if forever_answers(kind) then return end
        if native("input", "is_key_pressed", SHIFT) == true then return end
        local t = now()
        window = { kind = kind, at = t, due = t + REACT_MIN + math.random() * REACT_SPAN }
    end

    local NONE = {}
    local function wanted_ids(kind)
        local w = current
        if not w then return NONE end
        -- The ESP acting (1.8.1): a kind its switch has off is not answered.
        if acting() and opt(kind == "turnin" and "rxp_act_turnin" or "rxp_act_accept", true) ~= true then return NONE end
        return kind == "turnin" and w.turnin or w.accept
    end

    --- A quest's name for a greeting window's title.
    local function names_of(ids)
        local out = {}
        for qid, goal in pairs(ids) do
            local n = P.quests.quest_name and P.quests.quest_name(qid)
            if n then out[#out + 1] = { key = n:lower(), qid = qid } end
            if type(goal.text) == "string" then
                local stripped = goal.text:gsub("^%s*[Aa]ccept%s+", ""):gsub("^%s*[Tt]urn%s+in%s+", "")
                out[#out + 1] = { key = stripped:lower(), qid = qid }
            end
        end
        return out
    end

    local function title_wanted(title, list)
        if type(title) ~= "string" or title == "" then return false end
        local k = title:lower()
        for i = 1, #list do
            if list[i].key == k or list[i].key:find(k, 1, true) then return true end
        end
        return false
    end

    local function done_talking(why)
        native("quests", "close_gossip")
        native("quests", "close_quest")
        if talk then
            note("nothing for the guide at %s: %s", talk.name or "?", why)
            skip[talk.guid] = now() + SKIP_FOR
        end
        talk = nil
    end

    local function gossip_step()
        local active = native("quests", "get_gossip_active_quests")
        local available = native("quests", "get_gossip_available_quests")
        local turnin, accept = wanted_ids("turnin"), wanted_ids("accept")
        if type(active) == "table" then
            for i = 1, #active do
                local r = active[i]
                local id = type(r) == "table" and tonumber(r.quest_id) or nil
                if id and turnin[id] and r.is_complete ~= false then
                    native("quests", "select_gossip_active_quest", id)
                    note("handing in %s (%d)", tostring(r.title or "?"), id)
                    return
                end
            end
        end
        if type(available) == "table" then
            for i = 1, #available do
                local r = available[i]
                local id = type(r) == "table" and tonumber(r.quest_id) or nil
                if id and accept[id] then
                    native("quests", "select_gossip_available_quest", id)
                    note("picking up %s (%d)", tostring(r.title or "?"), id)
                    return
                end
            end
        end
        done_talking("none of its quests is the step's")
    end

    local function greeting_step()
        local turnin, accept = names_of(wanted_ids("turnin")), names_of(wanted_ids("accept"))
        for i = 1, MAX_GREETING do
            local title = native("quests", "get_active_title", i)
            if type(title) ~= "string" or title == "" then break end
            if title_wanted(title, turnin) then
                native("quests", "select_active_quest", i)
                note("handing in %s", title)
                return
            end
        end
        for i = 1, MAX_GREETING do
            local title = native("quests", "get_available_title", i)
            if type(title) ~= "string" or title == "" then break end
            if title_wanted(title, accept) then
                native("quests", "select_available_quest", i)
                note("picking up %s", title)
                return
            end
        end
        done_talking("none of its quests is the step's")
    end

    --- The quest the open panel shows, when the client says.
    local function open_quest()
        local info = native("quests", "get_open_quest_info")
        if type(info) == "table" and tonumber(info.quest_id) and info.quest_id > 0 then return info.quest_id, info.title end
        return nil, type(info) == "table" and info.title or nil
    end

    local info_cache, info_asked = {}, {}
    local function item_info(key)
        if key == nil then return nil end
        local hit = info_cache[key]
        if hit then return hit end
        local t = now()
        if info_asked[key] and t - info_asked[key] < INFO_WAIT then return nil end
        local info = native("quests", "get_item_info", key)
        if type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            info_cache[key] = info
            return info
        end
        info_asked[key] = t
        return nil
    end

    --- The reward window. False while the choices or their item data are still coming.
    local function reward_step(w, t)
        local links = {}
        for i = 1, MAX_CHOICES do
            local link = native("quests", "get_quest_item_link", "choice", i)
            if type(link) ~= "string" or link == "" then break end
            links[#links + 1] = link
        end
        if #links == 0 and t - w.at < 0.6 then return false end
        local qid = open_quest()
        local goal = qid and current and current.turnin[qid] or nil
        local pick = goal and tonumber(goal.reward) or 0
        if pick > 0 and pick <= #links then
            native("quests", "get_quest_reward", pick)
            note("turned in, taking reward %d (the guide's choice)", pick)
            return true
        end
        if #links <= 1 then
            native("quests", "get_quest_reward", #links)
            note("turned in (%s)", #links == 1 and "one reward" or "no reward choice")
            return true
        end
        local choices, missing = {}, 0
        for i = 1, #links do
            local link = links[i]
            local info = item_info(link)
            if not info then
                local id = tonumber(link:match("item:(%d+)"))
                info = id and item_info(id) or nil
            end
            if not info then missing = missing + 1 end
            choices[i] = { index = i, link = link, info = info }
        end
        if missing > 0 and t - w.at < INFO_WAIT then return false end
        local index, why = rewards.pick_reward(choices, rewards.who(P, item_info))
        native("quests", "get_quest_reward", index)
        note("reward: %s", why)
        return true
    end

    local function window_tick(t)
        local w = window
        if not w then return end
        if t - w.at > WINDOW_OURS or not switched_on() then
            window = nil
            return
        end
        if t < w.due then return end
        local done = true
        if w.kind == "gossip" then
            gossip_step()
        elseif w.kind == "greeting" then
            greeting_step()
        elseif w.kind == "accept" then
            local qid = open_quest()
            if qid == nil or wanted_ids("accept")[qid] then
                native("quests", "accept_quest")
                note("accepted %s", qid and ("quest " .. qid) or "the quest on offer")
            else
                native("quests", "decline_quest")
                done_talking("it offered quest " .. qid .. ", not the step's")
            end
        elseif w.kind == "progress" then
            local qid = open_quest()
            if qid == nil or wanted_ids("turnin")[qid] then
                native("quests", "complete_quest")
            else
                native("quests", "close_quest")
                done_talking("quest " .. qid .. " is not the step's to hand in")
            end
        elseif w.kind == "complete" then
            done = reward_step(w, t)
        end
        if done and window == w then window = nil end
    end

    if ctx.on then
        local function hear(event, fn)
            ctx.on("jcore.game_event." .. event, function(args)
                local ok, err = pcall(fn, args)
                if not ok then log.once("warn", "guidewalk_" .. event, "guide walk " .. event .. ": " .. tostring(err)) end
            end)
        end
        hear("GOSSIP_SHOW", function() open_window("gossip") end)
        hear("QUEST_GREETING", function() open_window("greeting") end)
        hear("QUEST_DETAIL", function() open_window("accept") end)
        hear("QUEST_PROGRESS", function() open_window("progress") end)
        hear("QUEST_COMPLETE", function() open_window("complete") end)
        hear("GOSSIP_CLOSED", function() if window and window.kind == "gossip" then window = nil end end)
        -- A quest taken or handed in: the same npc is talked to again (the
        -- next quest of the step) only after TALK_WAIT, by when RestedXP has
        -- ticked the goal off. Talked to at once, its window would still be
        -- read against the old goals and the npc left alone for nothing.
        local function settled()
            if talk then talk.at, talk.tries = now(), 0 end
        end
        hear("QUEST_ACCEPTED", function()
            if now() <= ours_until then stats.accepted = stats.accepted + 1 end
            settled()
        end)
        hear("QUEST_TURNED_IN", function()
            if now() <= ours_until then stats.turned_in = stats.turned_in + 1 end
            settled()
        end)
    end

    -- --- the pull ------------------------------------------------------------------------------

    local pull = nil              -- { guid, obj, at, closer, name }: the mob being pulled

    local function rotation_runs()
        return opt("rot_enabled", false) == true and P.rotation_active ~= nil and P.rotation_active() == true
    end

    local function pull_range()
        local rot = P.rotation
        local class = rot and rot.detect_class and try(rot.detect_class) or nil
        local profile = ""
        if rot and rot.active_class and rot.active_profile_key then
            local ok, key = pcall(function()
                local module = rot.active_class()
                return module and rot.active_profile_key(module) or nil
            end)
            if ok and key then profile = tostring(key) end
        end
        local role = rewards.role_of(class, profile)
        if RANGED_CLASS[class or ""] or role == "caster" or role == "ranged" or role == "healer" then
            return RANGED_PULL
        end
        return MELEE_PULL
    end

    --- Is this the mob the guide walk is pulling? rotation.may_engage_unit asks.
    --- Only once it stands in pull range: nothing opens while Sentinel walks.
    ---@param target game_object|nil
    ---@return boolean
    function M.pulling(target)
        if not pull or not pull.at or not target or not switched_on() then return false end
        local guid = call(target, "get_guid")
        return guid ~= nil and guid == pull.guid
    end

    --- The mob the guide walk is pulling, out of combat, for targeting.better_target.
    ---@return game_object|nil
    function M.pull_target()
        if not pull or not pull.at or not switched_on() then return nil end
        local obj = pull.obj
        if not obj or call(obj, "is_valid") == false or call(obj, "is_dead") then return nil end
        return obj
    end

    -- --- the tick --------------------------------------------------------------------------------

    local found = {}
    local idle_why = nil          -- why the step cannot be followed, from the last look
    local next_scan = 0
    local steer_until = 0
    local was_on = false
    local job = nil               -- { kind, guid, label }
    local loot_at = nil           -- { guid, since }
    local patrol = nil            -- { step, idx }: the step's stops, walked while nothing shows

    local function steering()
        if not input or try(input.is_typing) then return false end
        for i = 1, #STEER_KEYS do
            if try(input.is_key_pressed, STEER_KEYS[i]) == true then return true end
        end
        return false
    end

    local function wait(text, tone)
        if leg then stop_walk() else let_go() end
        say(text, tone or "text_dim")
    end

    local function begin(kind, thing, label)
        local key = kind .. ":" .. tostring(thing.guid or "")
        if not job or job.key ~= key then
            job = { key = key, kind = kind, label = label }
            if kind ~= "talk" then talk = nil end
            if kind ~= "fight" then pull = nil end
        end
    end

    --- Walks to `thing` until within `reach`; true once there and standing.
    local function go(t, pos, thing, reach, label)
        if flat(pos, thing.pos) <= reach and not leg then return true end
        walk_to(t, thing.guid or label, thing.pos, reach, label)
        if not leg then return false end
        if walk_tick(t, pos) then return true end
        say(string.format("walking to %s (%.0f yd)", label, flat(pos, thing.pos)), "text")
        return false
    end

    local function mounted()
        local player = units.player()
        return player and call(player, "is_mounted") == true
    end

    --- Standing by `thing`: talks to it, and its windows are ours to answer.
    local function talk_here(t, thing, how)
        if not talk or talk.guid ~= thing.guid then
            talk = { guid = thing.guid, name = thing.name, at = 0, tries = 0, kind = how, qid = thing.qid }
        end
        if window then return say("answering " .. tostring(thing.name), "text") end
        if t - talk.at < TALK_WAIT then return say("talking to " .. tostring(thing.name), "text") end
        if talk.tries >= TALK_TRIES then
            skip[thing.guid] = t + SKIP_FOR
            note("%s never answered", tostring(thing.name))
            talk = nil
            return
        end
        local actions = P.actions
        local blocked = actions and actions.blocked_reason and actions.blocked_reason()
        if blocked then return say("waiting to talk: " .. blocked, "text_dim") end
        local kind = call(thing.obj, "is_unit") == false and "use" or "interact"
        local _, attempted = actions.perform(thing.obj, kind, thing.name)
        if attempted then
            talk.tries, talk.at = talk.tries + 1, t
            ours_until = t + WINDOW_OURS
            stats.talks = stats.talks + 1
            note("talking to %s to %s", tostring(thing.name), how == "turnin" and "hand in" or "pick up")
        end
        say("talking to " .. tostring(thing.name), "text")
    end

    local function do_talk(t, pos, w, thing)
        local how = thing.why or "accept"
        local label = (how == "turnin" and "hand in to " or "pick up from ") .. tostring(thing.name or "the quest giver")
        begin("talk", thing, label)
        if not go(t, pos, thing, TALK_REACH, thing.name or "the quest giver") then return end
        if mounted() then try(input.dismount) return say("getting off to talk", "text") end
        talk_here(t, thing, how)
    end

    --- The ESP acting (1.8.1): the step's quest giver is talked to once you
    --- stand within ACT_REACH of it; farther, the line says to walk up. It
    --- never gets you off your mount.
    local function act_talk(t, thing)
        local how = thing.why or "accept"
        local name = tostring(thing.name or "the quest giver")
        local verb = how == "turnin" and "hand in" or "pick up"
        begin("talk", thing, verb .. " at " .. name)
        local d = units.distance(thing.obj)
        if d > ACT_REACH then
            talk = nil
            return say(string.format("walk up to %s to %s (%.0f yd)", name, verb, d), "text")
        end
        if mounted() then return say("get off your mount to " .. verb .. " at " .. name, "warning") end
        talk_here(t, thing, how)
    end

    local function do_use(t, pos, thing)
        begin("use", thing, "use " .. tostring(thing.name))
        if not go(t, pos, thing, TALK_REACH, tostring(thing.name)) then return end
        if mounted() then try(input.dismount) return end
        local actions = P.actions
        local blocked = actions.blocked_reason()
        if blocked then return say("waiting to use " .. tostring(thing.name) .. ": " .. blocked, "text_dim") end
        if not actions.is_ready(thing.guid) then return say("using " .. tostring(thing.name), "text") end
        local _, attempted = actions.perform(thing.obj, "use", thing.name)
        if attempted then
            stats.uses = stats.uses + 1
            note("using %s", tostring(thing.name))
        end
        say("using " .. tostring(thing.name), "text")
    end

    local function do_loot(t, pos, thing)
        begin("loot", thing, "loot")
        if not go(t, pos, thing, LOOT_REACH, "your kill") then return end
        if not loot_at or loot_at.guid ~= thing.guid then loot_at = { guid = thing.guid, since = t } end
        if t - loot_at.since > LOOT_WAIT then
            skip[thing.guid] = t + 300
            loot_at = nil
            return
        end
        -- Auto-loot takes it when it is on; else this does.
        if not opt("autoloot_on", false) then
            local actions = P.actions
            if mounted() then try(input.dismount) return end
            if actions.blocked_reason() == nil and actions.is_ready(thing.guid) then
                local _, attempted = actions.perform(thing.obj, "loot", "corpse")
                if attempted then stats.loots = stats.loots + 1 end
            end
        end
        say("looting", "text")
    end

    --- Why no pull now -- resting, hardcore, health -- or nil.
    local function pull_gate()
        local player = units.player()
        local health = player and units.health_fraction and units.health_fraction(player) or 1
        if P.rest and P.rest.recovering then
            local resting, why = P.rest.recovering()
            if resting then return "resting before the next pull: " .. tostring(why) end
        end
        if P.hardcore and P.hardcore.may_pull and opt("hc_enabled", true) and not P.hardcore.may_pull() then
            return "hardcore: no pull at this health"
        end
        if health < PULL_HP then return string.format("health %.0f%%: waiting for it to come back", health * 100) end
        return nil
    end

    --- The ESP acting (1.8.1): a mob the step wants, within pull range of
    --- where you stand, is the rotation's to open on (pulling, pull_target).
    --- Nothing here selects, faces or hits it.
    local function act_fight(t, thing)
        local name = tostring(thing.name)
        begin("fight", thing, "kill " .. name)
        local held_by = pull_gate()
        if held_by then
            pull = nil
            return say(held_by, "text_dim")
        end
        local reach = pull_range()
        local d = units.distance(thing.obj)
        if d > reach + 0.5 then
            pull = nil
            return say(string.format("%s is %.0f yd away: the rotation opens on it within %.0f", name, d, reach), "text")
        end
        if not pull or pull.guid ~= thing.guid then
            pull = { guid = thing.guid, obj = thing.obj, at = t, closer = 0, name = thing.name }
            stats.pulls = stats.pulls + 1
            note("%s in range (%.0f yd): the rotation may open on it", name, d)
        end
        pull.obj = thing.obj
        if not rotation_runs() then
            return say(name .. " in range: switch the rotation on (Rotation page) to fight it, or fight it yourself",
                "warning")
        end
        say(name .. " in range: the rotation's to open on", "text")
    end

    local function do_fight(t, pos, thing)
        begin("fight", thing, "kill " .. tostring(thing.name))
        local held_by = pull_gate()
        if held_by then return wait(held_by) end

        if not pull or pull.guid ~= thing.guid then
            pull = { guid = thing.guid, obj = thing.obj, at = nil, closer = 0, name = thing.name }
        end
        pull.obj = thing.obj
        local reach = pull_range() / (2 ^ pull.closer)
        if reach < MELEE_PULL then reach = MELEE_PULL end
        if units.distance(thing.obj) > reach + 0.5 then
            pull.at = nil
            walk_to(t, thing.guid, thing.pos, reach, tostring(thing.name))
            if not leg then return end
            if not walk_tick(t, pos) then
                return say(string.format("walking to %s (%.0f yd)", tostring(thing.name), units.distance(thing.obj)),
                    "text")
            end
        end
        if leg then stop_walk() end
        if not pull.at then
            pull.at = t
            stats.pulls = stats.pulls + 1
            note("pulling %s (%.0f yd)", tostring(thing.name), units.distance(thing.obj))
        end
        -- Selected when it is not yet, faced once a second: the rotation
        -- turns you as it needs from there.
        local selected = combat.target and try(combat.target) or nil
        if not selected or call(selected, "get_guid") ~= thing.guid then
            if input and input.acquire(CHANNEL.TARGET, PRIORITY, "guide walk") then try(input.set_target, thing.obj) end
        end
        if not pull.faced or t - pull.faced >= 1.0 then
            pull.faced = t
            if input and input.acquire(CHANNEL.FACING, PRIORITY, "guide walk") then
                held = true
                try(input.face, thing.obj)
            end
        end
        if not rotation_runs() then
            -- No rotation to open: start the attack (the rotation's own
            -- rule counts that as you starting it).
            local actions = P.actions
            if actions.blocked_reason() == nil and actions.is_ready(thing.guid) then
                actions.perform(thing.obj, "interact", thing.name)
            end
        end
        if t - pull.at > PULL_WAIT then
            pull.closer, pull.at = pull.closer + 1, nil
            if pull.closer > PULL_CLOSER then
                skip[thing.guid] = t + SKIP_FOR
                note("could not start a fight with %s", tostring(thing.name))
                pull = nil
                return
            end
            note("no fight with %s yet: closer", tostring(thing.name))
        end
        say("pulling " .. tostring(thing.name), "text")
    end

    --- One tick of the ESP acting (1.8.1): what the step wants that you
    --- stand by is done; nothing moves you.
    local function act_tick(t, pos)
        if combat.in_combat() then
            if rotation_runs() then return say("fighting (the rotation)", "text") end
            return say("in combat: the fight is yours (the rotation is off)", "text")
        end
        local loot_count = native("game_ui", "get_loot_item_count")
        if type(loot_count) == "number" and loot_count > 0 then return wait("loot window open") end
        if window then return wait("answering a quest window", "text") end

        if t >= next_scan then
            next_scan = t + SCAN_EVERY
            local w, why = read_step()
            current, idle_why = w, why
            state.step = w and w.num or nil
            if not w then
                found = {}
                return wait(why)
            end
            found = scan(w, t)
        end
        local w = current
        if not w then return wait(idle_why or "waiting for the guide") end
        for _, kind in ipairs({ "fight", "talk" }) do
            local th = found[kind]
            if th and (skipped(th.guid, t) or call(th.obj, "is_valid") == false or call(th.obj, "is_dead") == true) then
                found[kind], next_scan = nil, 0
            end
        end
        if found.talk then return act_talk(t, found.talk) end
        if found.fight then return act_fight(t, found.fight) end
        pull, talk, job = nil, nil, nil

        -- Nothing of the step's in sight: where the guide points, for the line.
        local goal = w.waypoint
        if goal and flat(pos, goal) > ARRIVE then
            return say(string.format("follow the line to %s (%.0f yd)", w.waypoint_title or ("step " .. tostring(w.num)),
                flat(pos, goal)), "text_dim")
        end
        if not goal and w.away then
            return say("the guide's next stop is in " .. tostring(w.away.text) .. ": get there yourself", "warning")
        end
        if w.other then
            return say("the step wants: " .. tostring(w.other.text or w.other.action) .. " -- do it yourself", "warning")
        end
        if w.any_complete then return say("at the step: watching for what it wants killed", "text_dim") end
        if w.any_turnin or w.any_accept then return say("at the step: no quest giver for it in sight", "text_dim") end
        say("at the step: waiting for RestedXP to move on", "text_dim")
    end

    local was_mode = nil

    local function tick()
        local t = now()
        local m = mode()
        if not m then
            if was_on then
                was_on, was_mode = false, nil
                stop_walk()
                pull, talk, window, job, current = nil, nil, nil, nil, nil
                note("switched off")
            end
            say(P.esp_only and ("not on " .. tostring(P.client_label or "this client")) or "off", "text_dim")
            return
        end
        if not was_on or was_mode ~= m then
            -- The walk became the ESP's acting, or the other way: no route
            -- or key of the walk's is left live, no pull or talk either.
            if was_on then stop_walk() end
            was_on, was_mode = true, m
            paused_until, nav_strikes, patrol = 0, 0, nil
            pull, talk, job = nil, nil, nil
            note("switched on: %s", m == "walk" and "following the guide with Sentinel" or "acting as you walk up")
        end

        window_tick(t)

        local player = units.player()
        local pos = me()
        if not player or not pos then return wait("loading") end
        if call(player, "is_dead") or call(player, "is_ghost") then
            pull = nil
            return wait("dead: waiting until you are alive", "warning")
        end
        if m == "act" then return act_tick(t, pos) end
        if steering() then steer_until = t + STEER_PAUSE end
        if t < steer_until then
            pull = nil
            return wait("you are steering; it walks on when you let go")
        end
        if combat.in_combat() then
            if leg then stop_walk() end
            if rotation_runs() then return say("fighting (the rotation)", "text") end
            return say("in combat: switch the rotation on (Rotation page) or fight yourself", "warning")
        end
        local loot_count = native("game_ui", "get_loot_item_count")
        if type(loot_count) == "number" and loot_count > 0 then return wait("loot window open") end
        if window then return wait("answering a quest window", "text") end
        if t < paused_until then
            return wait(string.format("paused %ds: %s", floor(paused_until - t + 0.5), tostring(pause_why)), "warning")
        end
        if nav_strikes >= NAV_STRIKES then
            paused_until, pause_why = t + FAIL_PAUSE * 3,
                "Sentinel Navigation did not move you " .. NAV_STRIKES .. " times in a row (is it running?)"
            nav_strikes = 0
            return
        end

        if t >= next_scan then
            next_scan = t + SCAN_EVERY
            local w, why = read_step()
            current, idle_why = w, why
            state.step = w and w.num or nil
            if not w then
                found = {}
                return wait(why)
            end
            found = scan(w, t)
        end
        local w = current
        if not w then return wait(idle_why or "waiting for the guide") end

        -- What the last look found may have died, gone, or been left alone
        -- since (it looks twice a second): dropped now, and looked again at once.
        for _, kind in ipairs({ "fight", "talk", "use", "loot" }) do
            local th = found[kind]
            if th and (skipped(th.guid, t) or call(th.obj, "is_valid") == false
                or (kind ~= "loot" and call(th.obj, "is_dead") == true)) then
                found[kind], next_scan = nil, 0
            end
        end

        -- Corpses first (loot despawns), then the step's own business.
        if found.loot then return do_loot(t, pos, found.loot) end
        if found.talk then return do_talk(t, pos, w, found.talk) end
        local fight, use = found.fight, found.use
        if fight and use then
            if use.d < fight.d then fight = nil else use = nil end
        end
        if use then return do_use(t, pos, use) end
        if fight then return do_fight(t, pos, fight) end
        pull, talk = nil, nil

        -- Nothing in sight: the waypoint; once there, with mobs or objects
        -- still wanted, the step's stops in turn, round and round, until
        -- something shows or the step changes.
        local goal, label = w.waypoint, w.waypoint_title or ("step " .. tostring(w.num))
        if patrol and patrol.step ~= w.num then patrol = nil end
        if (w.any_complete or next(w.near)) and #w.stops > 1 then
            if not patrol and goal and flat(pos, goal) <= ARRIVE then patrol = { step = w.num, idx = 1 } end
            if patrol then
                local s = w.stops[patrol.idx]
                if not (s and s.world) or flat(pos, s.world) <= ARRIVE then
                    patrol.idx = (patrol.idx % #w.stops) + 1
                    s = w.stops[patrol.idx]
                end
                if s and s.world then
                    goal = s.world
                    local title = s.raw and s.raw.title
                    label = (type(title) == "string" and title ~= "") and title
                        or string.format("stop %d of step %d", patrol.idx, w.num)
                end
            end
        end
        if goal and flat(pos, goal) > ARRIVE then
            job = { key = "goto", kind = "goto", label = label }
            walk_to(t, "goto:" .. floor(goal.x) .. ":" .. floor(goal.y), goal, ARRIVE, label)
            if leg and not walk_tick(t, pos) then
                return say(string.format("walking to %s (%.0f yd)", label, flat(pos, goal)), "text")
            end
            return
        end
        if leg then
            -- There: said as there (walk_tick); a walk to anything else stops.
            if not (goal and flat(pos, leg.goal) <= leg.reach and walk_tick(t, pos)) then stop_walk() end
        end
        -- The waypoint is on another continent (quests.lua will not place
        -- it): nothing here walks there. Said, and the step waits for you.
        if not goal and w.away then
            local away = w.away
            if away.why == "continent" then
                return wait(string.format("the guide's next stop is in %s%s: get there yourself (boat, flight or "
                    .. "hearth); it walks on once you are there", away.text,
                    away.here and (" (you are in " .. away.here .. ")") or ""), "warning")
            end
            return wait("the guide's waypoint did not place (" .. away.text .. "): not walked", "warning")
        end
        if w.other then
            return wait("the step wants: " .. tostring(w.other.text or w.other.action) .. " -- do it yourself", "warning")
        end
        if w.any_complete then return wait("at the step: waiting for what it wants to show up") end
        if w.any_turnin or w.any_accept then return wait("at the step: no quest giver for it in sight") end
        wait("at the step: waiting for RestedXP to move on")
    end

    ctx.tick(function()
        local ok, err = pcall(tick)
        if not ok then
            log.once("error", "guidewalk_tick", "guide walk: " .. tostring(err))
            stop_walk()
        end
    end, { interval = 0.1 })

    -- --- the route, for the ESP --------------------------------------------------------------------

    local ROUTE_END = 10          -- yd: Sentinel's path ending this near the walk's goal is the walk's

    --- Sentinel's path, when it is this walk's: its last point within
    --- ROUTE_END of the walk's goal (a path of another plugin's, or one
    --- left from the walk before, is not). ctx.nav does not hand the path
    --- out; JCore's own nav does (JCore.nav.current_path).
    local function sentinel_path(goal)
        local get = nav and nav.current_path
        if type(get) ~= "function" then
            local public = P.JCore and P.JCore.nav
            get = type(public) == "table" and public.current_path or nil
        end
        local path = try(get)
        if type(path) ~= "table" or #path == 0 then return nil end
        local ok, d = pcall(flat, path[#path], goal)
        if not ok or d > ROUTE_END then return nil end
        return path
    end

    --- Where the walk is taking you, for the ESP's line (quests.lua's
    --- draw_walk_route): { goal, label, mode, path } while it walks, else
    --- nil. `path` is Sentinel's own route while Sentinel walks this walk.
    ---@return table|nil
    function M.route()
        if not leg or not switched_on() then return nil end
        local path = (leg.mode == "nav" and leg.started) and sentinel_path(leg.goal) or nil
        return { goal = leg.goal, label = leg.label, mode = leg.mode, path = path }
    end

    -- --- the page ----------------------------------------------------------------------------------

    --- What it is doing, in a word or two, and the colour to say it in.
    function M.status() return state.text, state.tone end

    --- Is either switch on here (the walk, or the ESP acting)? The guide
    --- panel's first row (quests.lua) says what it is doing while one is.
    ---@return boolean
    function M.active() return mode() ~= nil end

    --- Three lines for the Quests page.
    function M.status_lines()
        local lines = {}
        lines[1] = (acting() and "Guide ESP: " or "Guide walk: ") .. state.text
        local public = P.JCore and P.JCore.nav
        local version = type(public) == "table" and try(public.version) or nil
        local name = "Sentinel Navigation" .. (version and (" " .. tostring(version)) or "")
        if not nav or not try(nav.installed) then
            lines[2] = "Sentinel Navigation: not installed"
        elseif not nav_up() then
            lines[2] = name .. ": installed, not connected"
        else
            lines[2] = name .. ": connected (" .. tostring(try(nav.state) or "?") .. ")"
        end
        lines[3] = string.format("Talked %d, accepted %d, handed in %d, pulled %d, used %d, walks %d (%d straight)",
            stats.talks, stats.accepted, stats.turned_in, stats.pulls, stats.uses, stats.walks, stats.line_walks)
        return lines
    end

    function M.stats()
        return {
            on = switched_on(), switch = mode(), state = state.text, step = state.step, job = job and job.kind or nil,
            walking = leg and leg.label or nil, mode = leg and leg.mode or nil, pulling = pull and pull.name or nil,
            talking = talk and talk.name or nil, window = window and window.kind or nil,
            talks = stats.talks, accepted = stats.accepted, turned_in = stats.turned_in, pulls = stats.pulls,
            uses = stats.uses, loots = stats.loots, walks = stats.walks, line_walks = stats.line_walks,
            nav_drops = stats.nav_drops, recent = recent,
            away = current and current.away and current.away.text or nil,
        }
    end

    return M
end

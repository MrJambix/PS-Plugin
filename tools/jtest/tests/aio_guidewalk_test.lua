-- Jambix AIO 1.7.4: the guide walk (modules/guidewalk.lua) -- RestedXP's
-- steps walked with Sentinel Navigation and done.
--
-- Pinned here, against a fake world, Sentinel and RestedXP:
--   * off by default, and never on an ESP-only client: nothing walks;
--   * a step's waypoint is walked to by Sentinel (the movement lease at the
--     walk's priority); without Sentinel, straight at it when near, and a
--     far one says Sentinel is not connected; Sentinel that never moves you
--     is dropped for a straight walk; arrival lets go of every key;
--   * a turn-in: walked to the npc the quest database names, talked to, its
--     gossip answered for the step's quest only, the guide's reward taken;
--     a detail window for another quest is declined, one nobody opened is
--     not answered, Forever's quest givers answer their own when switched on;
--     an npc with nothing for the step is closed and left alone;
--   * a kill step: walked to the quest's mob, pulled in range (pulling() and
--     pull_target() only then), an attack started with the rotation off;
--   * it waits, letting go, while resting, at low health, in combat, while
--     you steer, while dead, and on a step it cannot do itself;
--   * the step's stops are walked in turn while nothing shows; your kills are
--     walked to and looted.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local factory = require("jambix_aio/modules/guidewalk")

local T = {}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_true(v, label)
    if not v then error(label, 2) end
end

local function count(W, name)
    local n = 0
    for i = 1, #W.calls do if W.calls[i][1] == name then n = n + 1 end end
    return n
end

local function last(W, name)
    for i = #W.calls, 1, -1 do if W.calls[i][1] == name then return W.calls[i] end end
    return nil
end

--- A unit or object in the fake world.
local function thing(o)
    local u = { guid = o.guid, name = o.name, npc_id = o.npc_id, pos = o.pos, hostile = o.hostile or false,
        dead = o.dead or false, unit = o.unit ~= false, flags = o.flags or 0 }
    u.get_guid = function(self) return self.guid end
    u.get_name = function(self) return self.name end
    u.get_npc_id = function(self) return self.npc_id end
    u.is_dead = function(self) return self.dead end
    u.is_player = function() return false end
    u.is_pet = function() return false end
    u.is_unit = function(self) return self.unit end
    u.is_valid = function() return true end
    u.get_npc_flags = function(self) return self.flags end
    u.get_position = function(self) return self.pos end
    return u
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- On the map, as the walk measures arrival (a waypoint's height is a guess).
local function flat(a, b)
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
end

local function pressed(W)
    local n = 0
    for i = 1, #W.calls do if W.calls[i][1] == "key" and W.calls[i][3] == true then n = n + 1 end end
    return n
end

--- The module over a fake world. `o.step` is RestedXP's current step.
local function world(o)
    o = o or {}
    local W = {
        t = 1000.0, calls = {}, handlers = {}, errors = {}, traced = {}, settings = o.settings or { rxp_follow = true },
        me = o.me or { x = 0, y = 0, z = 0 }, units = o.units or {}, objects = o.objects or {},
        corpses = o.corpses or {}, in_combat = false, dead = false, health = 1.0, mounted = false,
        nav_up = o.nav_up ~= false, nav_moving = false, nav_moves = o.nav_moves ~= false, keys = {},
        blocked = nil, rotation = o.rotation or false, resting = false, master = true,
    }
    local function rec(name) return function(...) W.calls[#W.calls + 1] = { name, ... } end end

    _G.core = {
        time = function() return W.t end,
        quests = {
            get_gossip_active_quests = function() return W.gossip_active or {} end,
            get_gossip_available_quests = function() return W.gossip_available or {} end,
            select_gossip_active_quest = rec("select_active"),
            select_gossip_available_quest = rec("select_available"),
            accept_quest = rec("accept"), decline_quest = rec("decline"), complete_quest = rec("complete"),
            close_quest = rec("close_quest"), close_gossip = rec("close_gossip"),
            get_quest_reward = rec("reward"),
            get_open_quest_info = function() return W.open_quest end,
            get_quest_item_link = function(_, i) return W.links and W.links[i] or "" end,
            get_item_info = function(key) return W.item_info and W.item_info[key] or nil end,
            get_active_title = function(i) return W.active_titles and W.active_titles[i] or "" end,
            get_available_title = function(i) return W.available_titles and W.available_titles[i] or "" end,
            select_active_quest = rec("select_active_title"),
            select_available_quest = rec("select_available_title"),
        },
        input = { is_key_pressed = function(vk) return W.keys[vk] == true end },
        game_ui = { get_loot_item_count = function() return 0 end },
    }

    local player = {
        get_level = function() return 10 end,
        can_attack = function(_, u) return u.hostile == true end,
        is_dead = function() return W.dead end,
        is_ghost = function() return false end,
        is_mounted = function() return W.mounted end,
        get_guid = function() return "player" end,
    }

    local all = function()
        local out = {}
        for i = 1, #W.units do out[#out + 1] = W.units[i] end
        return out
    end

    local P = {
        esp_only = o.esp_only or false,
        client_label = "TBC",
        load = function(path) return require("jambix_aio/" .. path) end,
        opt = function(id, fallback)
            local v = W.settings[id]
            if v == nil then return fallback end
            return v
        end,
        master_on = function() return W.master end,
        rotation_active = function() return W.rotation end,
        log = {
            fmt = function() end,
            once = function(level, _, text) if level == "error" or level == "warn" then W.errors[#W.errors + 1] = text end end,
        },
        units = {
            player = function() return player end,
            player_position = function() return W.me end,
            units = all,
            objects = function() return W.objects end,
            distance = function(u) return dist(W.me, u.pos) end,
            position = function(u) return u.pos end,
            name = function(u) return u.name end,
            guid = function(u) return u.guid end,
            health_fraction = function() return W.health end,
        },
        combat = { in_combat = function() return W.in_combat end },
        quests = {
            rxp = { loaded = o.loaded ~= false, step = o.step, stickies = o.stickies or {},
                world_waypoint = o.waypoint, waypoint = (o.waypoint or o.away) and { title = o.waypoint_title or "the spot" }
                    or nil,
                step_waypoints = o.stops or {}, waypoint_away = o.away },
            guide_key = function(text) return text:lower() end,
            guide_goal = function() return false, nil end,
            quest_entries = function(obj) return obj.entries end,
            quest_people = function(qid) return o.people and o.people[qid] or nil end,
            quest_name = function(qid) return o.names and o.names[qid] or nil end,
        },
        actions = {
            blocked_reason = function() return W.blocked end,
            is_ready = function() return true end,
            is_blacklisted = function() return false end,
            perform = function(obj, kind, label)
                W.calls[#W.calls + 1] = { "perform", obj, kind, label }
                return true, true
            end,
        },
        rotation = { detect_class = function() return o.class or "WARRIOR" end },
        rest = { recovering = function() if W.resting then return true, "mana at 20%" end return false, "" end },
        esp = { corpses = function() return W.corpses end },
        -- JCore's own nav hands out Sentinel's path (ctx.nav does not).
        JCore = { nav = {
            current_path = function() return W.nav_path end,
            version = function() return "0.0.5" end,
        } },
        ctx = {
            tick = function(fn) W.tick = fn end,
            on = function(event, fn) W.handlers[event] = fn end,
            emit = function(name, text) if name == "jcore.recorder.trace" then W.traced[#W.traced + 1] = text end end,
            nav = {
                available = function() return W.nav_up end,
                installed = function() return true end,
                move_to = function(goal, opts)
                    W.calls[#W.calls + 1] = { "move_to", goal, opts }
                    W.nav_moving = true
                    W.nav_goal = goal
                    W.nav_done = opts and opts.on_done
                    return true
                end,
                stop = function() W.calls[#W.calls + 1] = { "nav_stop" }; W.nav_moving = false end,
                is_moving = function() return W.nav_moving end,
                state = function() return W.nav_moving and "navigating" or "idle" end,
                replan = rec("replan"),
            },
            input = {
                CHANNEL = { MOVEMENT = "movement", FACING = "facing", TARGET = "target" },
                PRIORITY = { IDLE = 10 },
                acquire = function(channel, priority)
                    W.calls[#W.calls + 1] = { "acquire", channel, priority }
                    return true
                end,
                release = rec("release"),
                set_key = function(key, down) W.calls[#W.calls + 1] = { "key", key, down } end,
                look_at = rec("look_at"),
                face = rec("face"),
                set_target = rec("set_target"),
                jump = rec("jump"),
                dismount = rec("dismount"),
                is_key_pressed = function(vk) return W.keys[vk] == true end,
                is_typing = function() return false end,
            },
        },
    }
    if o.forever_npc then P.forever_npc = {} end
    W.P = P
    W.M = factory(P)

    --- Runs the tick for `seconds`, Sentinel walking you `speed` yards a
    --- second toward its goal while it navigates.
    function W.run(seconds, speed)
        local steps = math.floor(seconds / 0.1 + 0.5)
        for _ = 1, steps do
            W.t = W.t + 0.1
            if W.nav_moving and W.nav_moves and W.nav_goal then
                local d = dist(W.me, W.nav_goal)
                local step = (speed or 7) * 0.1
                if d <= step then
                    W.me = { x = W.nav_goal.x, y = W.nav_goal.y, z = W.nav_goal.z }
                    W.nav_moving = false
                else
                    local k = step / d
                    W.me = { x = W.me.x + (W.nav_goal.x - W.me.x) * k, y = W.me.y + (W.nav_goal.y - W.me.y) * k,
                        z = W.me.z }
                end
            end
            W.tick()
        end
        if #W.errors > 0 then error("the walk raised: " .. W.errors[1], 2) end
    end

    --- Fires a game event at the module.
    function W.event(name, args)
        local fn = W.handlers["jcore.game_event." .. name]
        assert(fn, "no handler for " .. name)
        fn(args or {})
    end

    function W.status() return (W.M.status()) end
    return W
end

local function goto_step(num) return { num = num or 5, active = true, goals = { { action = "goto", text = "Go there" } } } end

-- --- off and on ----------------------------------------------------------------------

T[#T + 1] = { "off by default: nothing walks", function()
    local W = world({ settings = {}, step = goto_step(), waypoint = { x = 100, y = 0, z = 0 } })
    W.run(1)
    assert_eq(count(W, "move_to"), 0, "no route")
    assert_eq(pressed(W), 0, "no key")
    assert_eq(W.status(), "off", "says off")
end }

T[#T + 1] = { "never on an ESP-only client, whatever the switch says", function()
    local W = world({ esp_only = true, step = goto_step(), waypoint = { x = 100, y = 0, z = 0 } })
    W.run(1)
    assert_eq(count(W, "move_to"), 0, "no route")
    assert_true(W.status():find("not on TBC", 1, true), "says so: " .. W.status())
end }

T[#T + 1] = { "the master switch stops it", function()
    local W = world({ step = goto_step(), waypoint = { x = 100, y = 0, z = 0 } })
    W.master = false
    W.run(1)
    assert_eq(count(W, "move_to"), 0, "no route")
end }

-- --- walking -------------------------------------------------------------------------

T[#T + 1] = { "the step's waypoint is walked to by Sentinel, holding movement at the walk's priority", function()
    local W = world({ step = goto_step(), waypoint = { x = 100, y = 0, z = 3 } })
    W.run(0.5)
    local call = last(W, "move_to")
    assert_true(call, "a route")
    assert_eq(call[2].x, 100, "to the waypoint")
    assert_eq(call[3].priority, 30, "at the walk's priority")
    local acquired = last(W, "acquire")
    assert_eq(acquired[3], 30, "the lease at the same priority")
    assert_true(W.status():find("walking to the spot", 1, true), W.status())
    W.run(20)
    assert_true(flat(W.me, { x = 100, y = 0, z = 3 }) <= 4, "got there")
    assert_true(count(W, "nav_stop") >= 1, "let go on arrival")
    assert_eq(count(W, "move_to"), 1, "one route for one waypoint")
    assert_true(W.status():find("waiting for RestedXP", 1, true), W.status())
end }

T[#T + 1] = { "no Sentinel: a near waypoint is walked straight at, a far one says why", function()
    local W = world({ nav_up = false, step = goto_step(), waypoint = { x = 30, y = 0, z = 0 } })
    W.run(0.3)
    assert_eq(count(W, "move_to"), 0, "no route")
    local key = last(W, "key")
    assert_eq(key[2], "forward", "forward held")
    assert_eq(key[3], true, "down")
    assert_true(last(W, "look_at"), "facing it")

    local F = world({ nav_up = false, step = goto_step(), waypoint = { x = 300, y = 0, z = 0 } })
    F.run(0.3)
    assert_eq(pressed(F), 0, "no key for a far one")
    assert_true(F.status():find("not connected", 1, true), F.status())
end }

T[#T + 1] = { "Sentinel that never moves you is dropped for a straight walk when near", function()
    local W = world({ nav_moves = false, step = goto_step(), waypoint = { x = 35, y = 0, z = 0 } })
    W.run(7)
    assert_eq(count(W, "move_to"), 1, "asked once")
    assert_true(count(W, "nav_stop") >= 1, "the route stopped")
    local key = last(W, "key")
    assert_eq(key[2], "forward", "walking straight at it")
end }

T[#T + 1] = { "Sentinel that never moves you on a far walk pauses the walk and says why", function()
    local W = world({ nav_moves = false, step = goto_step(), waypoint = { x = 300, y = 0, z = 0 } })
    W.run(7)
    assert_eq(pressed(W), 0, "no straight walk that far")
    assert_true(W.status():find("paused", 1, true), W.status())
end }

-- --- talking -------------------------------------------------------------------------

local function turnin_world(extra)
    local npc = thing({ guid = "npc-1", name = "Marshal McBride", npc_id = 197, pos = { x = 20, y = 0, z = 0 } })
    local o = {
        step = { num = 7, active = true, goals = {
            { action = "turnin", quest_id = 783, text = "Turn in A Threat Within", reward = 2 },
            { action = "accept", quest_id = 7, text = "Accept Kobold Camp Cleanup" },
        } },
        waypoint = { x = 21, y = 0, z = 0 },
        units = { npc },
        people = { [783] = { enders = { [197] = true }, givers = {}, giver_objects = {}, ender_objects = {} },
            [7] = { givers = { [197] = true }, enders = {}, giver_objects = {}, ender_objects = {} } },
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    local W = world(o)
    return W, npc
end

T[#T + 1] = { "a turn-in: the npc is walked to and talked to", function()
    local W, npc = turnin_world()
    W.run(6)
    local p = last(W, "perform")
    assert_true(p, "talked")
    assert_eq(p[2], npc, "to the quest's ender")
    assert_eq(p[3], "interact", "by interacting")
    assert_true(dist(W.me, npc.pos) <= 4.5, "within reach")
end }

T[#T + 1] = { "its gossip is answered for the step's quests only: the hand-in first", function()
    local W = turnin_world()
    W.run(6)
    W.gossip_active = { { quest_id = 99, title = "Not the guide's", is_complete = true },
        { quest_id = 783, title = "A Threat Within", is_complete = true } }
    W.gossip_available = { { quest_id = 7, title = "Kobold Camp Cleanup" } }
    W.event("GOSSIP_SHOW")
    W.run(0.1)
    assert_eq(count(W, "select_active"), 0, "not at once (the human delay)")
    W.run(0.6)
    assert_eq(count(W, "select_active"), 1, "handed in")
    assert_eq(last(W, "select_active")[2], 783, "the step's quest, not 99")
    assert_eq(count(W, "select_available"), 0, "the pick-up waits")
end }

T[#T + 1] = { "the reward the guide names is taken", function()
    local W = turnin_world()
    W.run(6)
    W.open_quest = { quest_id = 783, title = "A Threat Within" }
    W.links = { "|Hitem:1|h", "|Hitem:2|h", "|Hitem:3|h" }
    W.event("QUEST_COMPLETE")
    W.run(1)
    assert_eq(last(W, "reward")[2], 2, "reward 2, the guide's")
end }

T[#T + 1] = { "a detail window for another quest is declined; the step's is accepted", function()
    local W = turnin_world()
    W.run(6)
    W.open_quest = { quest_id = 55, title = "Something else" }
    W.event("QUEST_DETAIL")
    W.run(1)
    assert_eq(count(W, "accept"), 0, "not accepted")
    assert_eq(count(W, "decline"), 1, "declined")

    local A = turnin_world()
    A.run(6)
    A.open_quest = { quest_id = 7, title = "Kobold Camp Cleanup" }
    A.event("QUEST_DETAIL")
    A.run(1)
    assert_eq(count(A, "accept"), 1, "the step's quest accepted")
end }

T[#T + 1] = { "a window nobody opened is not answered", function()
    local W = world({ step = goto_step(), waypoint = { x = 0, y = 0, z = 0 } })
    W.run(1)
    W.open_quest = { quest_id = 7 }
    W.event("QUEST_DETAIL")
    W.run(1)
    assert_eq(count(W, "accept"), 0, "left to the player")
    assert_eq(count(W, "decline"), 0, "and not declined")
end }

T[#T + 1] = { "Forever's quest givers answer their own windows when switched on", function()
    local W = turnin_world({ forever_npc = true })
    W.settings.npc_accept_quests = true
    W.settings.npc_turn_in_quests = true
    W.run(6)
    W.open_quest = { quest_id = 7 }
    W.event("QUEST_DETAIL")
    W.run(1)
    assert_eq(count(W, "accept"), 0, "forever_npc's to answer")
end }

T[#T + 1] = { "an npc with nothing for the step is closed and left alone", function()
    local W, npc = turnin_world()
    W.run(6)
    W.gossip_active = { { quest_id = 99, title = "Other", is_complete = true } }
    W.gossip_available = {}
    local talks = count(W, "perform")
    W.event("GOSSIP_SHOW")
    W.run(0.6)
    assert_eq(count(W, "close_gossip"), 1, "closed")
    W.run(6)
    assert_eq(count(W, "perform"), talks, "not talked to again")
    assert_true(npc, "npc")
end }

T[#T + 1] = { "an npc that never answers is tried three times, then left alone", function()
    local W = turnin_world()
    W.run(20)
    assert_eq(count(W, "perform"), 3, "three tries, no window: no fourth")
    W.run(10)
    assert_eq(count(W, "perform"), 3, "still left alone")
end }

T[#T + 1] = { "a greeting window is answered by title", function()
    local W = turnin_world({ names = { [783] = "A Threat Within" } })
    W.run(6)
    W.active_titles = { "Other quest", "A Threat Within" }
    W.event("QUEST_GREETING")
    W.run(1)
    assert_eq(last(W, "select_active_title")[2], 2, "the step's quest, by its title")
end }

-- --- fighting ------------------------------------------------------------------------

local function kill_world(extra)
    local mob = thing({ guid = "mob-1", name = "Kobold Vermin", npc_id = 6, pos = { x = 40, y = 0, z = 0 },
        hostile = true })
    mob.entries = { { quest = { id = 7 }, tag = "kill" } }
    local o = {
        step = { num = 8, active = true, goals = { { action = "complete", quest_id = 7, text = "Kill Kobold Vermin" } } },
        waypoint = { x = 50, y = 0, z = 0 },
        units = { mob },
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return world(o), mob
end

T[#T + 1] = { "a kill step: walked to the quest's mob, pulled in melee range", function()
    local W, mob = kill_world()
    W.run(0.5)
    assert_eq(last(W, "move_to")[2].x, 40, "to the mob")
    assert_eq(W.M.pulling(mob), false, "nothing opens while walking")
    assert_eq(W.M.pull_target(), nil, "no target while walking")
    W.run(8)
    assert_true(dist(W.me, mob.pos) <= 4.6, "in melee range")
    assert_eq(W.M.pulling(mob), true, "the rotation may open on it")
    assert_eq(W.M.pull_target(), mob, "and targets it")
    assert_eq(last(W, "set_target")[2], mob, "selected")
    local p = last(W, "perform")
    assert_eq(p and p[3], "interact", "the rotation off: an attack started")
end }

T[#T + 1] = { "a caster pulls from range, and with the rotation on starts nothing itself", function()
    local W, mob = kill_world({ class = "MAGE", rotation = true })
    W.settings.rot_enabled = true
    W.run(4)
    assert_true(dist(W.me, mob.pos) > 20, "stopped at range")
    assert_eq(W.M.pulling(mob), true, "the rotation's to open")
    assert_eq(count(W, "perform"), 0, "no attack of its own")
end }

T[#T + 1] = { "no pull while resting, at low health, or for someone else's mob", function()
    local W, mob = kill_world()
    W.resting = true
    W.run(8)
    assert_eq(count(W, "move_to"), 0, "no walk to it while resting")
    assert_true(W.status():find("resting", 1, true), W.status())
    W.resting = false
    W.health = 0.3
    W.run(1)
    assert_true(W.status():find("health", 1, true), W.status())
    assert_eq(W.M.pulling(mob), false, "not pulled")

    local O, other = kill_world()
    O.P.targeting = { others_mob = function() return true end }
    O.run(1)
    assert_eq(O.M.pulling(other), false, "someone else's mob is left")
end }

T[#T + 1] = { "in combat the walk stops and the rotation fights", function()
    local W = kill_world()
    W.run(0.5)
    W.in_combat = true
    W.run(0.2)
    assert_true(count(W, "nav_stop") >= 1, "the route stopped")
    assert_true(W.status():find("in combat", 1, true), W.status())
end }

-- --- waiting -------------------------------------------------------------------------

T[#T + 1] = { "you steer: it lets go and waits, then walks on", function()
    local W = world({ step = goto_step(), waypoint = { x = 200, y = 0, z = 0 } })
    W.run(0.5)
    W.keys[0x57] = true
    W.run(0.2)
    assert_true(count(W, "nav_stop") >= 1, "the route stopped")
    assert_true(W.status():find("steering", 1, true), W.status())
    W.keys[0x57] = nil
    W.run(1)
    assert_true(W.status():find("steering", 1, true), "still waiting just after")
    W.run(3)
    assert_eq(count(W, "move_to"), 2, "walking again")
end }

T[#T + 1] = { "dead: nothing walks", function()
    local W = world({ step = goto_step(), waypoint = { x = 200, y = 0, z = 0 } })
    W.dead = true
    W.run(1)
    assert_eq(count(W, "move_to"), 0, "no route")
    assert_true(W.status():find("dead", 1, true), W.status())
end }

T[#T + 1] = { "a step it cannot do: at the waypoint it says what the step wants", function()
    local W = world({ step = { num = 9, active = true, goals = { { action = "hs", text = "Hearth to Goldshire" } } },
        waypoint = { x = 0, y = 0, z = 0 } })
    W.run(1)
    assert_true(W.status():find("Hearth to Goldshire", 1, true), W.status())
end }

T[#T + 1] = { "an inactive step and no guide are said", function()
    local W = world({ step = { num = 3, active = false, requires = "Fargodeep", goals = {} } })
    W.run(1)
    assert_true(W.status():find("not active yet", 1, true), W.status())
    local N = world({ step = { num = 0, goals = {} } })
    N.run(1)
    assert_true(N.status():find("pick a guide", 1, true), N.status())
end }

-- --- stops and loot ------------------------------------------------------------------

T[#T + 1] = { "nothing shows at the waypoint: the step's stops are walked in turn", function()
    local stops = {
        { raw = { title = "first" }, world = { x = 0, y = 0, z = 0 } },
        { raw = { title = "second" }, world = { x = 50, y = 0, z = 0 } },
    }
    local W = world({ step = { num = 8, active = true, goals = { { action = "complete", quest_id = 7, text = "Kill" } } },
        waypoint = { x = 0, y = 0, z = 0 }, stops = stops })
    W.run(1)
    assert_eq(last(W, "move_to")[2].x, 50, "on to the second stop")
    local furthest = 0
    for _ = 1, 100 do
        W.run(0.1)
        if W.me.x > furthest then furthest = W.me.x end
    end
    assert_true(furthest >= 46, "got there: " .. furthest)
    assert_eq(last(W, "move_to")[2].x, 0, "and back to the first")
end }

T[#T + 1] = { "your kill is walked to and looted", function()
    local corpse = thing({ guid = "corpse-1", name = "Kobold Vermin", pos = { x = 15, y = 0, z = 0 }, dead = true })
    local W = world({ step = goto_step(), waypoint = { x = 0, y = 0, z = 0 } })
    W.corpses = { { obj = corpse, guid = "corpse-1", distance = 15, skinnable = false } }
    W.run(4)
    local p = last(W, "perform")
    assert_true(p, "looted")
    assert_eq(p[3], "loot", "by looting")
    assert_eq(p[2], corpse, "that corpse")
end }

T[#T + 1] = { "with auto-loot on, the walk only takes you there", function()
    local corpse = thing({ guid = "corpse-1", name = "Kobold Vermin", pos = { x = 15, y = 0, z = 0 }, dead = true })
    local W = world({ step = goto_step(), waypoint = { x = 0, y = 0, z = 0 } })
    W.settings.autoloot_on = true
    W.corpses = { { obj = corpse, guid = "corpse-1", distance = 15, skinnable = false } }
    W.run(4)
    assert_true(dist(W.me, corpse.pos) <= 4, "taken there")
    assert_eq(count(W, "perform"), 0, "auto-loot's to press")
end }

-- --- automatic targeting (targeting.better_target) ------------------------------------

T[#T + 1] = { "automatic targeting takes the walk's mob out of combat over a better scoring one", function()
    local clock, in_combat, target = 100, false, nil
    _G.core = { time = function() return clock end, get_instance_type = function() return "none" end,
        object_manager = { get_party_members = function() return {} end } }
    local function unit(id, f)
        f = f or {}
        local u = { guid = id, name = id, hostile = f.hostile == true, dist = f.dist or 10, hp = f.hp or 1 }
        u.is_valid = function() return true end
        u.is_dead = function() return false end
        u.get_guid = function() return u.guid end
        u.get_name = function() return u.name end
        u.get_target = function() return nil end
        u.is_in_combat = function() return false end
        u.get_threat_situation = function() return nil end
        u.get_classification = function() return 0 end
        u.can_attack = function(_, other) return other ~= nil and other.hostile == true end
        return u
    end
    local me = unit("Player-ME")
    local near = unit("Mob-NEAR", { hostile = true, dist = 5, hp = 0.1 })
    local wanted = unit("Mob-WANTED", { hostile = true, dist = 25 })
    local mobs = { near, wanted }
    local P = {
        cfg = require("jambix_aio/modules/config"),
        ctx = {
            group = { in_group = function() return false end, objects = function() return { me } end,
                tanks = function() return {} end, is_tank = function() return false end,
                is_healer = function() return false end },
            enemies = { all = function() return {} end, count = function() return 0 end, get = function() return nil end,
                where = function() return {} end },
            emit = function() end, loot = { tapped = function() return false end },
        },
        log = { fmt = function() end, once = function() end },
        opt = function(_, d) return d end,
        tune_secs = function(_, d) return d end,
        units = { player = function() return me end, guid = function(u) return u and u.guid end,
            name = function(u) return u and u.name end, distance = function(u) return u.dist end,
            health_fraction = function(u) return u.hp end, enemies = function() return mobs end,
            enemies_within = function() return mobs end, classification = function() return 0 end,
            has_aura = function() return false end },
        combat = { target = function() return target end, in_combat = function() return in_combat end },
        rotation = { active_class = function() return nil end, active_profile_key = function() return nil end },
        rotation_active = function() return true end,
        guidewalk = { pull_target = function() return wanted end },
    }
    package.loaded["jambix_aio/modules/targeting"] = nil
    local targeting = require("jambix_aio/modules/targeting")(P)
    assert_eq(targeting.better_target(), wanted, "the walk's mob, not the nearly dead one beside you")
    target = wanted
    assert_eq(targeting.better_target(), nil, "on it already: no switch")
    target, in_combat = nil, true
    assert_true(targeting.better_target() ~= wanted, "in combat the fight picks, not the walk")
end }

T[#T + 1] = { "the page's lines", function()
    local W = world({ step = goto_step(), waypoint = { x = 100, y = 0, z = 0 } })
    W.run(0.5)
    local lines = W.M.status_lines()
    assert_eq(#lines, 3, "three lines")
    assert_true(lines[1]:find("Guide walk: walking", 1, true), lines[1])
    assert_true(lines[2]:find("Sentinel Navigation 0.0.5: connected", 1, true), "with its version: " .. lines[2])
    assert_eq(type(lines[3]), "string", "counts")
end }

-- --- 2026-10-10: in game on Forever -----------------------------------------------------

local AWAY = { why = "continent", text = "Darkshore, on Kalimdor", here = "the Eastern Kingdoms", zone = "Darkshore" }

T[#T + 1] = { "a waypoint on another continent is not walked, and it says where (in game: 15210 yd)", function()
    local W = world({ step = goto_step(), away = AWAY })
    W.run(1)
    assert_eq(count(W, "move_to"), 0, "no route to another continent")
    assert_eq(pressed(W), 0, "no key")
    local s = W.status()
    assert_true(s:find("Darkshore, on Kalimdor", 1, true), s)
    assert_true(s:find("you are in the Eastern Kingdoms", 1, true), s)
    assert_eq(W.M.stats().away, "Darkshore, on Kalimdor", "in the stats")
end }

T[#T + 1] = { "a walk under way stops when its waypoint turns out to be on another continent", function()
    local W = world({ step = goto_step(), waypoint = { x = 200, y = 0, z = 0 } })
    W.run(0.5)
    assert_eq(count(W, "move_to"), 1, "walking")
    W.P.quests.rxp.world_waypoint, W.P.quests.rxp.waypoint_away = nil, AWAY
    W.run(1)
    assert_true(count(W, "nav_stop") >= 1, "the route stopped")
    assert_eq(W.M.route(), nil, "no route to draw")
    assert_true(W.status():find("Kalimdor", 1, true), W.status())
end }

T[#T + 1] = { "a waypoint with no title is named by its goal's words, else by its step", function()
    local W = world({ step = goto_step(), waypoint = { x = 100, y = 0, z = 0 }, waypoint_title = "" })
    W.run(0.5)
    assert_true(W.status():find("walking to Go there", 1, true), W.status())
    assert_true(W.traced[1] and W.traced[#W.traced]:find("walking to Go there (", 1, true), tostring(W.traced[#W.traced]))

    local N = world({ step = { num = 12, active = true, goals = { { action = "goto", text = "" } } },
        waypoint = { x = 100, y = 0, z = 0 }, waypoint_title = "" })
    N.run(0.5)
    assert_true(N.status():find("walking to step 12's waypoint", 1, true), N.status())
end }

T[#T + 1] = { "the route for the ESP: Sentinel's path while it walks this walk, and no other's", function()
    local W = world({ step = goto_step(), waypoint = { x = 100, y = 0, z = 3 } })
    assert_eq(W.M.route(), nil, "nothing before it walks")
    W.nav_path = { { x = 0, y = 0, z = 0 }, { x = 50, y = 20, z = 1 }, { x = 100, y = 0, z = 3 } }
    W.run(0.5)
    local r = W.M.route()
    assert_true(r, "a route while it walks")
    assert_eq(r.goal.x, 100, "to the walk's goal")
    assert_eq(r.label, "the spot", "named")
    assert_eq(r.mode, "nav", "on Sentinel")
    assert_eq(r.path, W.nav_path, "along Sentinel's path")

    W.nav_path = { { x = 0, y = 0, z = 0 }, { x = 400, y = 0, z = 0 } }
    assert_eq(W.M.route().path, nil, "a path to somewhere else is not this walk's")
    W.nav_path = nil
    assert_eq(W.M.route().path, nil, "no path yet: straight at it")

    local L = world({ nav_up = false, step = goto_step(), waypoint = { x = 30, y = 0, z = 0 } })
    L.nav_path = { { x = 0, y = 0, z = 0 }, { x = 30, y = 0, z = 0 } }
    L.run(0.3)
    assert_eq(L.M.route().mode, "line", "walking straight at it")
    assert_eq(L.M.route().path, nil, "Sentinel's path is not drawn for a straight walk")

    W.run(20)
    assert_eq(W.M.route(), nil, "there: nothing to draw")
end }

T[#T + 1] = { "arriving is said in the trace, by Sentinel", function()
    local W = world({ step = goto_step(), waypoint = { x = 50, y = 0, z = 0 } })
    W.run(12)
    local found = nil
    for i = 1, #W.traced do
        if W.traced[i]:find("got to the spot (Sentinel", 1, true) then found = W.traced[i] end
    end
    assert_true(found, "the arrival line: " .. table.concat(W.traced, " | "))
end }

return T

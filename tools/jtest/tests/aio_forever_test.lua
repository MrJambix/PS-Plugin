-- Jambix AIO on the Forever client (Classic+, the retail engine): the talent
-- reader (modules/talents.lua) on trait trees, and the quest log
-- (modules/questlog.lua) without the classic quest log calls. Each runs
-- against a hand-built bundle and a scripted `core`, and the classic paths
-- are checked alongside so the Forever branches cannot have broken them.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_talents = require("jambix_aio/modules/talents")
local make_questlog = require("jambix_aio/modules/questlog")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A bundle and a world. `client` is what ctx.world.client() answers.
local function bundle(client)
    local W = {
        clock = 1000.0, handlers = {}, ticks = {}, afters = {}, emitted = {}, logs = {},
    }
    local function record(level, text) W.logs[#W.logs + 1] = level .. ": " .. tostring(text) end
    local P = {
        log = {
            fmt = function(level, fmt, ...) record(level, string.format(fmt, ...)) end,
            once = function(level, _, message) record(level, message) end,
            debug = function(message) record("debug", message) end,
        },
        opt = function(_, default) return default end,
        ctx = {
            on = function(name, fn)
                local list = W.handlers[name] or {}
                list[#list + 1] = fn
                W.handlers[name] = list
            end,
            emit = function(name, payload) W.emitted[#W.emitted + 1] = { name, payload } end,
            tick = function(fn) W.ticks[#W.ticks + 1] = fn end,
            every = function() end,
            after = function(_, fn) W.afters[#W.afters + 1] = fn end,
            world = { client = function() return client end },
        },
    }
    function W.fire(name, args)
        for _, fn in ipairs(W.handlers[name] or {}) do fn(args) end
    end
    function W.frames(n)
        for _ = 1, n do
            W.clock = W.clock + 1 / 60
            for i = 1, #W.ticks do W.ticks[i]() end
        end
    end
    function W.run_afters()
        local list = W.afters
        W.afters = {}
        for i = 1, #list do list[i]() end
    end
    return P, W
end

local FOREVER = {
    version = "Forever", exact = "wow_forever_us", forever = true, retail = false,
    trait_talents = true, classic_quest_log = false, completed_quest_list = false, cancel_buff = false,
}
local ERA = {
    version = "Vanilla", exact = "wow_vanilla_us", forever = false, retail = false,
    trait_talents = false, classic_quest_log = true, completed_quest_list = true, cancel_buff = true,
}

local T = {}

-- --- talents --------------------------------------------------------------------

--- A Forever game_ui: `active` rows, `trees` tree id -> node ids, and an
--- optional specialization index. Calls are counted per name.
local function trait_ui(active, trees, spec)
    local calls = {}
    local function count(name) calls[name] = (calls[name] or 0) + 1 end
    local tree_ids = {}
    for i = 1, #trees do tree_ids[i] = trees[i].id end
    local ui = {
        get_talent_info = function() count("get_talent_info"); return {} end,
        get_active_talents = function() count("get_active_talents"); return active end,
        get_talent_tree_ids = function() count("get_talent_tree_ids"); return tree_ids end,
        get_talent_tree_nodes = function(tree_id)
            count("get_talent_tree_nodes")
            for i = 1, #trees do
                if trees[i].id == tree_id then return trees[i].nodes end
            end
            return {}
        end,
        get_specialization = function() count("get_specialization"); return spec end,
    }
    return ui, calls
end

local WARRIOR_ACTIVE = {
    { node_id = 11, spell_id = 12290, name = "Improved Overpower", rank = 2, max_rank = 2 },
    { node_id = 12, spell_id = 12296, name = "Tactical Mastery", rank = 5, max_rank = 5 },
    { node_id = 21, spell_id = 12319, name = "Flurry", rank = 3, max_rank = 5 },
    { node_id = 31, spell_id = 12298, name = "Shield Specialization", rank = 1, max_rank = 5 },
}

T[#T + 1] = { "talents: Forever with three trait trees splits points by tree", function()
    local P, W = bundle(FOREVER)
    local ui, calls = trait_ui(WARRIOR_ACTIVE, {
        { id = 701, nodes = { 11, 12, 13 } },
        { id = 702, nodes = { 21, 22 } },
        { id = 703, nodes = { 31 } },
    })
    _G.core = { time = function() return W.clock end, game_ui = ui }

    local talents = make_talents(P)
    local a, f, p = talents.points()
    assert_eq(a, 7, "tree 1 points")
    assert_eq(f, 3, "tree 2 points")
    assert_eq(p, 1, "tree 3 points")
    assert_eq(talents.dominant(), 1, "dominant tab")
    assert_eq(talents.rank("Tactical Mastery"), 5, "rank by name")
    assert_eq(talents.rank("tactical mastery"), 5, "names are case-insensitive")
    assert(talents.has("Flurry"), "has Flurry")
    assert(not talents.has("Mortal Strike"), "an untaken talent")
    assert_eq(talents.stats().source, "traits", "read from the trait API")
    assert_eq(calls.get_talent_info, nil, "the classic walk is not tried when traits answer")

    talents.scan()
    assert_eq(calls.get_talent_tree_nodes, 3, "each tree's node list is read once per session")
end }

T[#T + 1] = { "talents: one trait tree uses the specialization as the tab", function()
    local P, W = bundle(FOREVER)
    local ui = trait_ui(WARRIOR_ACTIVE, { { id = 700, nodes = { 11, 12, 21, 31 } } }, 2)
    _G.core = { time = function() return W.clock end, game_ui = ui }

    local talents = make_talents(P)
    local a, f, p = talents.points()
    assert_eq(a, 0, "tab 1")
    assert_eq(f, 11, "every point lands on the spec's tab")
    assert_eq(p, 0, "tab 3")
    assert_eq(talents.dominant(), 2, "dominant is the spec")
end }

T[#T + 1] = { "talents: trees that cannot be told apart keep names and ranks, no guessed spec", function()
    local P, W = bundle(FOREVER)
    local ui = trait_ui(WARRIOR_ACTIVE, { { id = 700, nodes = {} }, { id = 800, nodes = {} } }, nil)
    _G.core = { time = function() return W.clock end, game_ui = ui }

    local talents = make_talents(P)
    assert_eq(talents.rank("Improved Overpower"), 2, "rank still read")
    assert_eq(talents.dominant(), 0, "no dominant tab")
    assert_eq(select(1, talents.points()) + select(2, talents.points()) + select(3, talents.points()), 0,
        "no points attributed")
    assert_eq(talents.spec_name(), "Traits (no tree split)", "spec name says why")
    assert(talents.stats().ok, "the scan still counts as readable")
end }

T[#T + 1] = { "talents: the classic walk is unchanged on Era", function()
    local P, W = bundle(ERA)
    local tabs = {
        { { name = "Improved Heroic Strike", rank = 3, max_rank = 3 }, { name = "Tactical Mastery", rank = 5, max_rank = 5 } },
        { { name = "Cruelty", rank = 5, max_rank = 5 } },
        {},
    }
    local active_calls = 0
    _G.core = {
        time = function() return W.clock end,
        game_ui = {
            get_talent_info = function(tab, index) return tabs[tab][index] or {} end,
            get_active_talents = function() active_calls = active_calls + 1; return {} end,
        },
    }
    local talents = make_talents(P)
    local a, f, p = talents.points()
    assert_eq(a, 8, "tab 1")
    assert_eq(f, 5, "tab 2")
    assert_eq(p, 0, "tab 3")
    assert_eq(talents.rank("Tactical Mastery"), 5, "rank")
    assert_eq(talents.stats().source, "trees", "classic source")
    assert_eq(active_calls, 0, "the trait API is not asked when the trees answer")
end }

T[#T + 1] = { "talents: Era never asks the trait API, even when its trees read empty", function()
    local P, W = bundle(ERA)
    local ui, calls = trait_ui(WARRIOR_ACTIVE, {
        { id = 1, nodes = { 11, 12 } }, { id = 2, nodes = { 21 } }, { id = 3, nodes = { 31 } },
    })
    _G.core = { time = function() return W.clock end, game_ui = ui }
    local talents = make_talents(P)
    assert_eq(talents.stats().ok, false, "nothing readable, as before")
    assert_eq(calls.get_active_talents, nil, "no trait call on Era")
    assert_eq(calls.get_talent_tree_ids, nil, "no tree call on Era")
    assert_eq(W.handlers["jcore.game_event.TRAIT_CONFIG_UPDATED"], nil, "no trait event hook on Era")
    assert_eq(W.handlers["jcore.game_event.PLAYER_TALENT_UPDATE"], nil, "no talent event hook on Era")
end }

T[#T + 1] = { "talents: Forever falls back to the classic walk when its traits are empty", function()
    local P, W = bundle(FOREVER)
    _G.core = {
        time = function() return W.clock end,
        game_ui = {
            get_active_talents = function() return {} end,
            get_talent_info = function(tab, index)
                if tab == 1 and index == 1 then return { name = "Deflection", rank = 2, max_rank = 5 } end
                return {}
            end,
        },
    }
    local talents = make_talents(P)
    assert_eq(talents.stats().source, "trees", "classic walk answered")
    assert_eq(talents.rank("Deflection"), 2, "rank")
end }

T[#T + 1] = { "talents: a burst of talent events asks for one scan", function()
    local P, W = bundle(FOREVER)
    local ui, calls = trait_ui(WARRIOR_ACTIVE, { { id = 1, nodes = { 11, 12, 21, 31 } } }, 1)
    _G.core = { time = function() return W.clock end, game_ui = ui }
    make_talents(P)
    local before = calls.get_active_talents
    for _ = 1, 12 do W.fire("jcore.game_event.TRAIT_CONFIG_UPDATED", {}) end
    W.fire("jcore.game_event.PLAYER_TALENT_UPDATE", {})
    assert_eq(#W.afters, 1, "one delayed scan scheduled")
    assert_eq(calls.get_active_talents, before, "no scan inside the handlers")
    W.run_afters()
    assert_eq(calls.get_active_talents, before + 1, "one scan when it fires")
    W.fire("jcore.game_event.TRAIT_CONFIG_UPDATED", {})
    assert_eq(#W.afters, 1, "a later burst schedules again")
end }

-- --- quest log ------------------------------------------------------------------

T[#T + 1] = { "questlog: Era parses objectives exactly as before", function()
    local P = bundle(ERA)
    _G.core = { time = function() return 0 end }
    local ql = make_questlog(P)
    local name, have, need = ql.parse_objective("Bristleback Quilboar slain: 3/8")
    assert_eq(name, "Bristleback Quilboar", "classic name")
    assert_eq(have, 3, "classic have"); assert_eq(need, 8, "classic need")
    name, have, need = ql.parse_objective("3/8 Bristleback Quilboar slain")
    assert_eq(name, "3/8 Bristleback Quilboar slain", "the retail form is not read on Era")
    assert_eq(have + need, 0, "no counts")
end }

T[#T + 1] = { "questlog: Forever parses both objective formats", function()
    local P = bundle(FOREVER)
    _G.core = { time = function() return 0 end, quests = { is_on_quest = function() return false end } }
    local ql = make_questlog(P)
    local name, have, need = ql.parse_objective("Bristleback Quilboar slain: 3/8")
    assert_eq(name, "Bristleback Quilboar", "classic name")
    assert_eq(have, 3, "classic have"); assert_eq(need, 8, "classic need")
    name, have, need = ql.parse_objective("3/8 Bristleback Quilboar slain")
    assert_eq(name, "Bristleback Quilboar", "retail-engine name")
    assert_eq(have, 3, "retail-engine have"); assert_eq(need, 8, "retail-engine need")
    name, have, need = ql.parse_objective("Speak with Gazrog")
    assert_eq(name, "Speak with Gazrog", "no counter")
    assert_eq(have + need, 0, "no counts")
end }

T[#T + 1] = { "questlog: classic clients read the quest log as before", function()
    local P = bundle(ERA)
    _G.core = {
        time = function() return 0 end,
        quests = {
            get_num_quest_log_entries = function() return 3 end,
            get_quest_log_title = function(i)
                if i == 1 then return { title = "Durotar", is_header = true } end
                if i == 2 then return { title = "Sarkoth", level = 5, quest_id = 790, is_complete = 0 } end
                return { title = "Vile Familiars", level = 6, quest_id = 792, is_complete = 1 }
            end,
            get_num_quest_leader_boards = function(i) return i == 2 and 1 or 0 end,
            get_quest_log_leader_board = function() return { description = "Sarkoth's Mangled Claw: 0/1", is_completed = false } end,
            is_on_quest = function() error("the classic path must not poll is_on_quest") end,
        },
    }
    local ql = make_questlog(P)
    local rows, mode = ql.read()
    assert_eq(mode, "classic", "mode")
    assert_eq(#rows, 2, "headers skipped")
    assert_eq(rows[1].id, 790, "first quest")
    assert_eq(rows[1].log_index, 2, "log index kept")
    assert_eq(rows[1].objectives[1].name, "Sarkoth's Mangled Claw", "objective name")
    assert_eq(rows[2].complete, true, "complete flag")
end }

--- A Forever core: no classic log calls, is_on_quest over `on`, Questie with
--- `db_ids` and per-quest names, RestedXP objectives.
local function forever_core(W, on, db_ids, opts)
    opts = opts or {}
    local calls = { is_on = 0 }
    local questie = not opts.no_questie and {
        is_ready = function() return true end,
        is_loaded = function() return true end,
        get_quest_ids = function() return db_ids end,
        query_quest_single = function(id, key)
            if key == "name" then return "Quest Name " .. id end
            if key == "questLevel" then return 10 + id % 5 end
            return nil
        end,
        is_quest_complete = function(id) return (opts.complete or {})[id] or 0 end,
    } or nil
    local rested = opts.rxp and {
        is_loaded = function() return true end,
        get_objectives = function(id) return opts.rxp[id] or {} end,
    } or nil
    _G.core = {
        time = function() return W.clock end,
        quests = {
            -- The real Forever core has these too; they just answer 0 / {}.
            get_num_quest_log_entries = function() return 0 end,
            get_quest_log_title = function() return {} end,
            is_on_quest = function(id) calls.is_on = calls.is_on + 1; return on[id] == true end,
        },
        addons = { questie = questie, rested_xp = rested },
    }
    return calls
end

T[#T + 1] = { "questlog: Forever finds the quests already in the log with one sliced Questie sweep", function()
    local P, W = bundle(FOREVER)
    local db = {}
    for i = 1, 150 do db[i] = i * 10 end
    local on = { [70] = true, [1200] = true }
    local calls = forever_core(W, on, db, {
        rxp = { [70] = { { text = "3/8 Bristleback Quilboar slain", num_fulfilled = 3, num_required = 8, finished = false, type = "monster" } } },
        complete = { [1200] = 1 },
    })
    local ql = make_questlog(P)

    local rows, mode = ql.read()
    assert_eq(mode, "tracked", "Forever is tracked")
    assert_eq(#rows, 0, "nothing known before the sweep")
    assert(ql.stats().sweeping, "the sweep started")

    W.frames(1)
    assert_eq(calls.is_on, 60, "one slice per frame")
    W.frames(2)
    assert(not ql.stats().sweeping, "150 ids take three frames")
    assert(ql.stats().swept, "swept")

    rows = ql.read()
    assert_eq(#rows, 2, "both quests found")
    assert_eq(rows[1].id, 70, "sweep order")
    assert_eq(rows[1].name, "Quest Name 70", "name from Questie")
    assert_eq(rows[1].level, 10, "level from Questie")
    assert_eq(rows[1].objectives[1].name, "Bristleback Quilboar", "RestedXP objective parsed")
    assert_eq(rows[1].objectives[1].have, 3, "have"); assert_eq(rows[1].objectives[1].need, 8, "need")
    assert_eq(rows[1].complete, false, "not complete")
    assert_eq(rows[2].complete, true, "Questie says complete")

    local changes = 0
    for i = 1, #W.emitted do
        if W.emitted[i][1] == "jambix.aio.questlog_changed" then changes = changes + 1 end
    end
    assert(changes >= 2, "the index is told the log changed")
end }

T[#T + 1] = { "questlog: accept adds in either event shape, turn-in removes", function()
    local P, W = bundle(FOREVER)
    local on = {}
    forever_core(W, on, {})
    local ql = make_questlog(P)

    on[783] = true
    W.fire("jcore.game_event.QUEST_ACCEPTED", { 783 })               -- retail engine: (quest_id)
    on[790] = true
    W.fire("jcore.game_event.QUEST_ACCEPTED", { 3, 790 })            -- classic: (log_index, quest_id)
    local rows = ql.read()
    assert_eq(#rows, 2, "both accepted quests held")
    assert_eq(rows[1].id, 783, "first"); assert_eq(rows[2].id, 790, "second, not the log index")

    W.fire("jcore.game_event.QUEST_TURNED_IN", { 783, 450, 0 })
    on[783] = nil
    rows = ql.read()
    assert_eq(#rows, 1, "turned in")
    assert_eq(rows[1].id, 790, "the other remains")
end }

T[#T + 1] = { "questlog: an abandon is dropped on the second read, a loading-screen blip is not", function()
    local P, W = bundle(FOREVER)
    local on = { [5] = true }
    forever_core(W, on, {})
    local ql = make_questlog(P)
    ql.consider(5)

    on[5] = nil
    assert_eq(#ql.read(), 1, "one 'not on it' answer keeps the quest")
    on[5] = true
    assert_eq(#ql.read(), 1, "it answered again: still held")
    on[5] = nil
    ql.read()
    assert_eq(#ql.read(), 0, "two in a row drop it")
end }

T[#T + 1] = { "questlog: a guide quest you do not hold is re-asked only after a while; an accept is not throttled", function()
    local P, W = bundle(FOREVER)
    local on = {}
    local calls = forever_core(W, on, {}, { no_questie = true })
    local ql = make_questlog(P)

    assert_eq(ql.consider(900), false, "not on it")
    assert_eq(ql.consider(900), false, "asked again at once")
    assert_eq(calls.is_on, 1, "the second ask is throttled")

    on[900] = true
    W.fire("jcore.game_event.QUEST_ACCEPTED", { 900 })
    assert_eq(#ql.read(), 1, "the accept went through the throttle")
    assert(not ql.stats().swept and not ql.stats().sweeping, "no Questie, no sweep")
end }

T[#T + 1] = { "questlog: classic clients ignore consider and register nothing", function()
    local P, W = bundle(ERA)
    local asked = 0
    _G.core = {
        time = function() return 0 end,
        quests = {
            get_num_quest_log_entries = function() return 0 end,
            get_quest_log_title = function() return {} end,
            is_on_quest = function() asked = asked + 1; return true end,
        },
    }
    local ql = make_questlog(P)
    assert_eq(ql.consider(5), false, "consider is a no-op")
    assert_eq(asked, 0, "is_on_quest never asked")
    assert_eq(ql.stats().mode, "classic", "classic mode")
    assert_eq(W.handlers["jcore.game_event.QUEST_ACCEPTED"], nil, "no accept hook")
    assert_eq(W.handlers["jcore.game_event.QUEST_TURNED_IN"], nil, "no turn-in hook")
    assert_eq(#W.ticks, 0, "no per-frame job")
end }

T[#T + 1] = { "questlog: a classic build without the log calls stays empty, as before", function()
    local P = bundle(ERA)
    _G.core = { time = function() return 0 end, quests = { is_on_quest = function() return true end } }
    local ql = make_questlog(P)
    local rows, mode = ql.read()
    assert_eq(rows, nil, "no rows: the index warns and stays empty")
    assert_eq(mode, "classic", "never switches to tracking on a classic client")
end }

-- --- the 2026-10-06 core (1.82.0) ---------------------------------------------------

--- A Forever core with the quest-ID readers: `S.list` is what
--- get_quest_log_quest_ids answers, `S.log` the quest log's rows (headers
--- too), `S.objectives` and `S.ready` per quest id, `S.on` is_on_quest's.
--- Questie is there with a database of `S.db` so a sweep could start.
local function new_core(W, S)
    local calls = { is_on = 0, objectives = 0 }
    _G.core = {
        time = function() return W.clock end,
        quests = {
            get_quest_log_quest_ids = function() return S.list end,
            get_num_quest_log_entries = function() return #(S.log or {}) end,
            get_quest_log_title = function(i) return (S.log or {})[i] or {} end,
            get_quest_objectives = function(id) calls.objectives = calls.objectives + 1; return (S.objectives or {})[id] or {} end,
            is_quest_complete = function(id) return (S.ready or {})[id] == true end,
            is_on_quest = function(id) calls.is_on = calls.is_on + 1; return (S.on or {})[id] == true end,
        },
        addons = { questie = {
            is_ready = function() return true end,
            is_loaded = function() return true end,
            get_quest_ids = function() return S.db or { 10, 20, 30 } end,
            query_quest_single = function(id, key)
                if key == "name" then return "Questie Name " .. id end
                if key == "questLevel" then return 1 end
                return nil
            end,
            is_quest_complete = function() return 0 end,
        } },
    }
    return calls
end

T[#T + 1] = { "questlog: Forever on the 2026-10-06 core takes the quests, names, objectives and completion from the game", function()
    local P, W = bundle(FOREVER)
    local S = {
        list = { 92469, 790 },
        log = {
            { title = "Zephras Isle", is_header = true },
            { title = "Wolves at the Door", level = 8, quest_id = 92469, is_complete = 0 },
            { title = "Sarkoth", level = 5, quest_id = 790, is_complete = 1 },
        },
        objectives = {
            [92469] = { { text = "2/8 Ragged Young Wolf slain", type = "monster", finished = false, fulfilled = 2, required = 8 } },
            [790] = { { text = "Sarkoth's Mangled Claw: 1/1", type = "item", finished = true, fulfilled = 1, required = 1 } },
        },
        ready = { [790] = true },
    }
    local calls = new_core(W, S)
    local ql = make_questlog(P)

    local rows, mode = ql.read()
    assert_eq(mode, "tracked", "still the tracked reader")
    assert_eq(#rows, 2, "both quests, at once")
    assert_eq(rows[1].id, 92469, "the game's order")
    assert_eq(rows[1].name, "Wolves at the Door", "the log's own title, not Questie's")
    assert_eq(rows[1].level, 8, "the log's level")
    assert_eq(rows[1].objectives[1].name, "Ragged Young Wolf", "the game's objective, numbers first")
    assert_eq(rows[1].objectives[1].have, 2, "have"); assert_eq(rows[1].objectives[1].need, 8, "need")
    assert_eq(rows[1].objectives[1].kind, "monster", "kind")
    assert_eq(rows[1].complete, false, "not ready")
    assert_eq(rows[2].complete, true, "ready, by the game's word (Questie says 0)")
    assert_eq(rows[2].objectives[1].name, "Sarkoth's Mangled Claw", "the classic order too")
    assert_eq(calls.is_on, 0, "what the game lists needs no is_on_quest")
    assert(not ql.stats().sweeping and not ql.stats().swept, "no Questie sweep")
    assert_eq(ql.stats().listed, 2, "the stats say the game listed two")
    assert_eq(ql.game_listed(), true, "game_listed")
end }

T[#T + 1] = { "questlog: a quest under a collapsed header stays while is_on_quest says so; an abandon is dropped", function()
    local P, W = bundle(FOREVER)
    local S = { list = { 5, 6 }, on = { [5] = true, [6] = true } }
    new_core(W, S)
    local ql = make_questlog(P)
    assert_eq(#ql.read(), 2, "both listed")

    S.list = { 5 }                    -- 6's header collapsed
    local rows = ql.read()
    assert_eq(#rows, 2, "6 is still held")
    assert_eq(rows[2].id, 6, "after what the game lists")
    assert_eq(rows[2].name, "Questie Name 6", "named from Questie when the log does not show it")

    S.on[6] = nil                     -- abandoned
    ql.read()
    assert_eq(#ql.read(), 1, "two reads not on it drop it")
end }

T[#T + 1] = { "questlog: completion on an older Forever core -- Questie's 1, JCore's database's true, every objective finished", function()
    local P, W = bundle(FOREVER)
    local on = { [10] = true, [20] = true, [30] = true, [40] = true }
    forever_core(W, on, {}, {
        complete = { [10] = true, [30] = -1, [40] = 1 },
        rxp = { [20] = { { text = "Gold Dust: 10/10", num_fulfilled = 10, num_required = 10, finished = true, type = "item" } } },
    })
    local ql = make_questlog(P)
    for _, id in ipairs({ 10, 20, 30, 40 }) do ql.consider(id) end
    local rows = ql.read()
    assert_eq(#rows, 4, "four held")
    assert_eq(rows[1].complete, true, "true, as JCore's quest database answered before 1.9.0")
    assert_eq(rows[2].complete, true, "Questie said 0, but every objective is finished")
    assert_eq(rows[3].complete, false, "failed is not complete")
    assert_eq(rows[3].failed, true, "failed")
    assert_eq(rows[4].complete, true, "Questie's own 1")
    assert_eq(ql.stats().listed, nil, "no game list on this core")
    assert_eq(ql.game_listed(), false, "game_listed")
end }

return T

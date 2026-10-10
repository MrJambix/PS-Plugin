-- Jambix AIO: the quest index's tags and the guide match, in modules/quests.lua.
--
-- What the ESP's chips are built from: every index entry says what to DO with
-- its target (kill, collect, use, turn in, pick up), and the guide match is by
-- whole word and never by id. Questie and RestedXP are stubbed through
-- core.addons, the quest log through P.questlog.

local root = (jtest and jtest.scripts) or "scripts"
-- Only when the harness has not already put scripts/ on the path: run.js
-- does, after a JTEST_OVERLAY staging folder, which this would hide.
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local cfg = require("jambix_aio/modules/config")
local make_quests = require("jambix_aio/modules/quests")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local noop = function() end
local quiet = setmetatable({}, { __index = function() return noop end })

--- Questie's database, as query_quest_single / query_item_single answer it.
local DB = {
    quests = {
        [100] = {
            -- 1 creatures (kill), 2 objects (use), 3 items (collect)
            objectives = {
                [1] = { { 3100, "Bristleback Quilboar" } },
                [2] = { { 7000, "Mysterious Crate" } },
                [3] = { { 5000, "Bristleback Tusk" } },
            },
            startedBy = { { 4100 } },
            finishedBy = { { 4000 } },
        },
        [200] = {
            objectives = { [1] = { { 3300 } } },
            startedBy = { { 4200 } },
            -- Handed in at an npc AND at a world object (Questie lists the
            -- npcs first, then the objects).
            finishedBy = { { 4300 }, { 8000 } },
        },
    },
    items = {
        [5000] = { npcDrops = { 3200, 3100 }, objectDrops = { 7100 } },
    },
    objects = {
        [7000] = { name = "Mysterious Crate" },
        [8000] = { name = "Bloodstained Journal" },
        [8100] = { name = "Wanted Poster" },
    },
}

local questie = {
    is_loaded = function() return true end,
    is_ready = function() return true end,
    get_quest_npc_ids = function() return {} end,
    query_quest_single = function(id, field) return DB.quests[id] and DB.quests[id][field] end,
    query_item_single = function(id, field) return DB.items[id] and DB.items[id][field] end,
    query_object_single = function(id, field) return DB.objects[id] and DB.objects[id][field] end,
}

local function rested_with(goals)
    return {
        is_loaded = function() return true end,
        get_current_step = function() return { num = 3, goals = goals } end,
        get_current_stickies = function() return {} end,
        get_current_waypoint = function() return nil end,
        get_step_waypoints = function() return {} end,
        get_objectives = function() return {} end,
    }
end

local ROWS = {
    {
        id = 100, name = "Quilboar Trouble", complete = false,
        objectives = {
            { name = "Bristleback Quilboar", kind = "monster", finished = false, have = 1, need = 8 },
            { name = "Bristleback Tusk", kind = "item", finished = false, have = 0, need = 5 },
            { name = "Thunder Bluff reputation", kind = "reputation", finished = false, have = 0, need = 1 },
        },
    },
    { id = 200, name = "All Done", complete = true, objectives = {} },
}

local function build(o)
    o = o or {}
    _G.core = {
        time = function() return 1000 end,
        game_time = function() return 1000000 end,
        addons = { questie = o.questie_addon or questie, rested_xp = o.rested },
    }
    local P = {
        cfg = cfg,
        ctx = { on = noop, tick = noop, LAYER = { WORLD = 100, HUD = 500 },
            every = function(_, fn) if o.timers then o.timers[#o.timers + 1] = fn end end,
            world = o.world, questdb = o.questdb, ui = o.ui },
        log = quiet,
        units = o.units or {},
        draw = o.draw or {},
        questlog = {
            read = function() return o.rows or ROWS, "classic" end,
            consider = noop,
        },
        opt = function(id, fallback)
            local v = o.settings and o.settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end,
        load = function(path) error("unexpected load of " .. path) end,
        esp = o.esp,
    }
    return make_quests(P)
end

local blank = {}

local function tag_of(Q, name, npc_id)
    local entries = Q.quest_entries(blank, name, npc_id)
    assert(entries, "no entries for " .. tostring(name or npc_id))
    return entries[1].tag
end

--- The same, for a world object (collect.lua's object pass).
local function object_tag_of(Q, name, id)
    local entries = Q.quest_entries(blank, name, id, true)
    assert(entries, "no entries for object " .. tostring(name or id))
    return entries[1].tag
end

local T = {}

T[#T + 1] = { "no quest or guide paths in a dungeon or raid, unless switched on (1.47.3)", function()
    local kind = "none"
    local asked = 0
    local esp = { entities = function() asked = asked + 1 return {} end, count = function() return 0 end }
    local world = { instance_type = function() return kind end }
    local settings = {}
    local Q = build({ world = world, esp = esp, settings = settings })

    Q.render_hud()
    assert_eq(asked, 1, "outdoors: the paths are worked out")
    for _, k in ipairs({ "party", "raid" }) do
        kind, asked = k, 0
        Q.render_hud()
        assert_eq(asked, 0, k .. ": no paths")
    end
    settings.quest_lines_in_dungeons = true
    kind, asked = "party", 0
    Q.render_hud()
    assert_eq(asked, 1, "a dungeon with the switch on: paths")
    settings.quest_lines_in_dungeons = nil
    kind, asked = "pvp", 0
    Q.render_hud()
    assert_eq(asked, 1, "a battleground is not a dungeon")
end }

T[#T + 1] = { "Questie ids: a kill objective's mob is KILL, the mob that drops the item is COLLECT", function()
    local Q = build()
    assert_eq(tag_of(Q, "x", 3100), "kill", "a direct kill objective")
    assert_eq(tag_of(Q, "x", 3200), "collect", "drops the tusk only")
    assert_eq(object_tag_of(Q, "x", 7000), "use", "the crate to use")
    assert_eq(object_tag_of(Q, "x", 7100), "collect", "an object the item drops from")
end }

T[#T + 1] = { "Questie's answers come from JCore's own quest database, not the addon (1.55.0)", function()
    local function trap() error("the Questie addon was asked") end
    local addon = setmetatable({}, { __index = function() return trap end })
    local db = { available = function() return true end, questie = function() return questie end }
    local Q = build({ questdb = db, questie_addon = addon })
    assert_eq(tag_of(Q, "x", 3100), "kill", "a direct kill objective, from JCore's database")
    assert_eq(tag_of(Q, "x", 3200), "collect", "and the mob that drops the item")
    assert_eq(object_tag_of(Q, "x", 7000), "use", "the crate to use")
    -- No database (not extracted yet): the addon's bridge, as before.
    local none = { available = function() return false end, questie = function() error("asked") end }
    local Q2 = build({ questdb = none })
    assert_eq(tag_of(Q2, "x", 3100), "kill", "the addon answers")
end }

T[#T + 1] = { "quest objects: a turn-in object is TURN IN once the quest is complete (1.47.5)", function()
    local Q = build()
    assert_eq(object_tag_of(Q, "x", 8000), "turn_in", "by the object's id")
    assert_eq(object_tag_of(Q, "Bloodstained Journal", false), "turn_in",
        "by Questie's name for it, when the client answers no id")
    local line = Q.quest_entries(blank, "Bloodstained Journal", false, true)[1]
    assert_eq(line.quest.name, "All Done", "and it says which quest")
    -- Quest 100 is not complete: its objects say what to do, not TURN IN.
    assert_eq(object_tag_of(Q, "Mysterious Crate", false), "use", "an objective object by name")
end }

T[#T + 1] = { "quest objects and npcs never answer for each other's ids (1.47.5)", function()
    local Q = build()
    assert_eq(Q.quest_entries(blank, "x", 7000), nil, "an npc with the crate's id is not USE")
    assert_eq(Q.quest_entries(blank, "x", 8000), nil, "an npc with the journal's id is not TURN IN")
    assert_eq(Q.quest_entries(blank, "x", 4300, true), nil, "an object with the turn-in npc's id is not TURN IN")
    assert_eq(Q.quest_entries(blank, "x", 3100, true), nil, "an object with a kill mob's id is not KILL")
    assert_eq(tag_of(Q, "x", 4300), "turn_in", "the npc ender still is")
end }

T[#T + 1] = { "the guide's quest picked up from an object is PICK UP on that object (1.47.5)", function()
    local Q = build()
    DB.quests[410] = { objectives = {}, startedBy = { {}, { 8100 } }, name = "Wanted: Plunder" }
    Q.index_guide_givers({ [410] = true })
    assert_eq(object_tag_of(Q, "x", 8100), "pick_up", "by id")
    assert_eq(object_tag_of(Q, "Wanted Poster", false), "pick_up", "by name")
    assert_eq(Q.quest_entries(blank, "x", 8100), nil, "not an npc")
    DB.quests[410] = nil
end }

T[#T + 1] = { "a mob that is both a kill objective and drops the item stays KILL", function()
    local Q = build()
    -- 3100 is in objectives[1] and in the tusk's npcDrops
    assert_eq(tag_of(Q, "x", 3100), "kill", "kill wins")
end }

T[#T + 1] = { "a completed quest marks its turn-in npc TURN IN", function()
    local Q = build()
    assert_eq(tag_of(Q, "x", 4300), "turn_in", "the ender")
    assert_eq(Q.quest_entries(blank, "x", 3300), nil, "a done quest's mobs are not wanted")
end }

T[#T + 1] = { "name matches carry the client's objective type", function()
    local Q = build()
    assert_eq(tag_of(Q, "Bristleback Quilboar"), "kill", "monster objective")
    assert_eq(tag_of(Q, "Bristleback Tusk"), "collect", "item objective")
    local rep = Q.quest_entries(blank, "Thunder Bluff reputation")
    assert(rep, "a reputation objective still matches")
    assert_eq(rep[1].tag, nil, "with no tag, so the mark says plain QUEST")
end }

T[#T + 1] = { "the guide's quest givers are PICK UP", function()
    local Q = build()
    Q.index_guide_givers({ [100] = true })   -- in the log: not a giver
    Q.index_guide_givers({ [300] = true })   -- unknown to Questie: nothing
    DB.quests[400] = { objectives = {}, startedBy = { { 4400 } }, name = "Ride to Orgrimmar" }
    Q.index_guide_givers({ [400] = true })
    assert_eq(tag_of(Q, "x", 4400), "pick_up", "the giver")
    DB.quests[400] = nil
end }

T[#T + 1] = { "config: every tag the index can give has a chip", function()
    local Q = build()
    for _, tag in pairs(Q.OBJECTIVE_TAG) do assert(cfg.TAGS[tag], "no chip for " .. tag) end
    for _, tag in ipairs({ "kill", "collect", "use", "turn_in", "pick_up", "quest", "guide", "loot", "skin" }) do
        assert(cfg.TAGS[tag], "no chip for " .. tag)
        assert(cfg.TAG_RGB[cfg.TAGS[tag].family], tag .. " has no family colour")
    end
end }

T[#T + 1] = { "quest names match as whole words: no pet called Boar on a Quilboar quest", function()
    local Q = build()
    assert_eq(Q.quest_entries(blank, "Boar"), nil, "'boar' inside 'quilboar' is not a match")
    local group = Q.quest_entries(blank, "Bristleback Quilboar Geomancer")
    assert(group, "the objective names a group the unit belongs to")
    assert_eq(group[1].tag, "kill", "and it is a kill")
    assert(Q.quest_entries(blank, "Bristleback Quilboars"), "a plural meets the singular")
end }

-- --- the guide match ----------------------------------------------------------------

local GOALS = {
    { text = "Kill 8 Mangy Wolves", action = "complete", quest_id = 0, ids = { 3615 } },
    { text = "Talk to Devrak", action = "goto" },
}

T[#T + 1] = { "guide: a name inside a goal, as a word, answers with the goal", function()
    local Q = build({ rested = rested_with(GOALS) })
    local hit, goal = Q.is_guide_target(blank, "Mangy Wolf")
    assert(hit, "Mangy Wolf in 'Kill 8 Mangy Wolves'")
    assert_eq(goal.text, "Kill 8 Mangy Wolves", "the goal")
    assert_eq(goal.action, "complete", "and its action")
    local hit2, goal2 = Q.is_guide_target(blank, "Devrak")
    assert(hit2, "Devrak")
    assert_eq(goal2.text, "Talk to Devrak", "Devrak's goal")
end }

T[#T + 1] = { "guide: a name hiding inside a longer word is not the guide naming it", function()
    local Q = build({ rested = rested_with(GOALS) })
    assert(not Q.is_guide_target(blank, "angy"), "'angy' inside 'mangy'")
    assert(not Q.is_guide_target(blank, "rak"), "'rak' inside 'devrak'")
    assert(not Q.is_guide_target(blank, "Ox"), "a two-letter name never matches")
end }

T[#T + 1] = { "guide: never by id -- a goal's ids are quest ids", function()
    local Q = build({ rested = rested_with(GOALS) })
    -- 3615 is in the goal's ids; a unit whose npc id is 3615 is not the target
    local unit = { get_npc_id = function() return 3615 end }
    assert(not Q.is_guide_target(unit, "Kodo Calf", 3615), "id collision ignored")
end }

T[#T + 1] = { "guide: plurals meet singulars, both ways", function()
    local Q = build({ rested = rested_with({ { text = "Collect 6 feathers from Witchwing Harpies", action = "collect" } }) })
    assert(Q.is_guide_target(blank, "Witchwing Harpy"), "harpies -> harpy")
    assert_eq(Q.guide_key("Kill 8 Mangy Wolves"), "kill 8 mangy wolf", "the key form")
    assert_eq(Q.guide_key("Kobolds"), Q.guide_key("Kobold"), "kobolds -> kobold")
end }

T[#T + 1] = { "guide: answers are remembered per name, and forgotten when the step moves on", function()
    local goals = { { text = "Talk to Devrak", action = "goto" } }
    local timers = {}
    local Q = build({ rested = rested_with(goals), timers = timers })
    assert(Q.is_guide_target(blank, "Devrak"), "first step")
    assert(Q.rxp.memo.Devrak, "remembered")
    goals[1] = { text = "Speak with Zargh", action = "goto" }
    for i = 1, #timers do timers[i]() end
    assert(not Q.is_guide_target(blank, "Devrak"), "the next step forgot Devrak")
    assert(Q.is_guide_target(blank, "Zargh"), "and knows Zargh")
end }

T[#T + 1] = { "guide: nothing without RestedXP", function()
    local Q = build()
    assert(not Q.is_guide_target(blank, "Devrak"), "no guide, no match")
end }


T[#T + 1] = { "an id the caller found none for is not asked again (false), only an unknown one (nil)", function()
    local Q = build()
    local asked = 0
    local obj = { get_npc_id = function() asked = asked + 1 return 0 end }
    Q.quest_entries(obj, "Spell Effect", false)
    Q.quest_entries(obj, "Spell Effect", 0)
    assert_eq(asked, 0, "false and 0 both mean: there is none")
    Q.quest_entries(obj, "Spell Effect")
    assert_eq(asked, 1, "nil: not asked yet, so ask")
    assert_eq(tag_of(Q, "x", 3100), "kill", "a real id still answers")
end }

-- --- only what is still wanted (1.64.1) ----------------------------------------------

DB.quests[300] = {
    objectives = { [3] = { { 5100 }, { 5200 } } },
    finishedBy = { { 4500 } },
}
DB.quests[310] = {
    objectives = { [1] = { { 3600 } }, [3] = { { 5300 } } },
    finishedBy = { { 4600 } },
}
DB.items[5100] = { name = "Gold Dust", npcDrops = { 3400 } }
DB.items[5200] = { name = "Copper Ore", npcDrops = { 3500 } }
DB.items[5300] = { name = "Candle", npcDrops = { 3700 } }

local function dust_and_ore(dust_done, ore_done)
    return { {
        id = 300, name = "Dust and Ore", complete = false,
        objectives = {
            { name = "Gold Dust", kind = "item", finished = dust_done, have = dust_done and 10 or 3, need = 10 },
            { name = "Copper Ore", kind = "item", finished = ore_done, have = ore_done and 8 or 2, need = 8 },
        },
    } }
end

T[#T + 1] = { "an objective done: its drop mob is no longer marked while the quest waits on another", function()
    local Q = build({ rows = dust_and_ore(true, false) })
    assert_eq(Q.quest_entries(blank, "x", 3400), nil, "the Gold Dust mob: collected already")
    assert_eq(tag_of(Q, "x", 3500), "collect", "the Copper Ore mob: still wanted")
    assert_eq(Q.quest_entries(blank, "x", 4500), nil, "not complete: no turn-in yet")
end }

T[#T + 1] = { "every objective done: the quest counts as complete and its turn-in is marked", function()
    local Q = build({ rows = dust_and_ore(true, true) })
    assert_eq(Q.quest_entries(blank, "x", 3500), nil, "no drop mob any more")
    assert_eq(tag_of(Q, "x", 4500), "turn_in", "the turn-in npc")
end }

T[#T + 1] = { "a kill objective Questie gives no name for: the mob's own name says it is done", function()
    local rows = { {
        id = 310, name = "Candles", complete = false,
        objectives = {
            { name = "Kobold Miner", kind = "monster", finished = true, have = 8, need = 8 },
            { name = "Candle", kind = "item", finished = false, have = 1, need = 6 },
        },
    } }
    local Q = build({ rows = rows })
    assert_eq(Q.quest_entries(blank, "Kobold Miner", 3600), nil, "its kills are done")
    assert_eq(tag_of(Q, "x", 3700), "collect", "the candle mob still is")
end }

T[#T + 1] = { "Forever: no quest log objectives, the progress messages say what is done", function()
    local progress = { ["gold dust"] = { have = 10, need = 10 }, ["copper ore"] = { have = 2, need = 8 } }
    local esp = { forever = { quests = { progress = function(name) return progress[name:lower()] end } } }
    local rows = { { id = 300, name = "Dust and Ore", complete = false, objectives = {} } }
    local Q = build({ rows = rows, esp = esp })
    assert_eq(Q.quest_entries(blank, "x", 3400), nil, "Gold Dust: 10/10")
    assert_eq(tag_of(Q, "x", 3500), "collect", "Copper Ore: 2/8")
end }

-- --- the guide panel (1.83.0): a JCore window, moved and resized ------------

--- The draw calls the panel makes when it paints itself.
local function panel_draw(calls)
    return {
        theme = { accent = "accent", good = "good", text = "text", text_dim = "dim",
            warning = "warning", backdrop = "backdrop" },
        screen_size = function() return 1920, 1080 end,
        rect_2d = function(p, w, h) calls[#calls + 1] = { "rect", p.x, p.y, w, h } end,
        text_2d = function(p, s, col) calls[#calls + 1] = { "text", p.x, p.y, s, col } end,
    }
end

--- JCore's overlay UI, answering begin_window with `open`, `win`.
local function panel_ui(open, win)
    local ui = { texts = {}, begun = 0, ended = 0 }
    function ui.begin_window(self, id, opts)
        self.begun, self.id, self.opts = self.begun + 1, id, opts
        return open, win
    end
    function ui.end_window(self) self.ended = self.ended + 1 end
    function ui.text(self, s, opts) self.texts[#self.texts + 1] = { s = s, color = opts and opts.color } end
    return ui
end

--- A guide on step 12, in a dungeon so only the panel is painted.
local function guide_panel(ui, calls)
    local Q = build({ ui = ui, draw = panel_draw(calls),
        world = { instance_type = function() return "party" end } })
    local rxp = Q.rxp
    rxp.loaded = true
    rxp.step = { num = 12, goals = {
        { text = "Kill 8 Mangy Wolves", is_complete = false },
        { text = "Talk to Marshal McBride", is_complete = true },
    } }
    rxp.objectives = { { text = "Mangy Wolf slain", have = 3, need = 8, finished = false } }
    rxp.waypoint = { title = "Northshire Abbey", dist = 142 }
    Q.render_hud()
    return Q
end

T[#T + 1] = { "guide panel: a JCore window, moved by its title and resized from its corner", function()
    local calls = {}
    local ui = panel_ui(true, { x = 40, y = 50, w = 260, h = 180, visible = true })
    guide_panel(ui, calls)
    assert_eq(ui.begun, 1, "one window")
    assert_eq(ui.ended, 1, "begin and end paired")
    assert_eq(ui.id, "rxp_guide", "its id, which JCore keeps the place and size under")
    assert_eq(ui.opts.resizable, true, "resizable")
    assert(ui.opts.movable ~= false, "movable")
    assert(ui.opts.title:find("Step 12", 1, true), "the step in the title: " .. tostring(ui.opts.title))
    assert_eq(#ui.texts, 4, "two goals, one objective, the waypoint")
    assert_eq(ui.texts[1].s, "- Kill 8 Mangy Wolves", "a goal, whole")
    assert_eq(ui.texts[2].color, "good", "a done goal in the good colour")
    assert_eq(ui.texts[3].s, "Mangy Wolf slain  3/8", "an objective and its count")
    assert_eq(ui.texts[4].s, "-> Northshire Abbey  142y", "the waypoint and its distance")
    assert_eq(#calls, 0, "nothing painted beside the window")
end }

T[#T + 1] = { "guide panel: the overlay UI switched off, drawn where the window was left", function()
    local calls = {}
    local ui = panel_ui(false, { x = 40, y = 50, w = 260, h = 180, visible = true, collapsed = false })
    guide_panel(ui, calls)
    assert_eq(ui.ended, 1, "begin and end paired")
    assert_eq(calls[1][1], "rect", "a backdrop first")
    assert_eq(calls[1][2], 40, "at the window's x")
    assert_eq(calls[1][3], 50, "at the window's y")
    assert_eq(calls[1][4], 260, "the window's width")
    assert(calls[2][4]:find("Step 12", 1, true), "the title in the accent colour")
    assert_eq(calls[2][5], "accent", "accent")
    assert_eq(#calls, 6, "backdrop, title and four rows")
    assert(calls[5][4]:find("3/8$"), "the count kept whole: " .. calls[5][4])
end }

T[#T + 1] = { "guide panel: folded away or hidden, nothing is drawn", function()
    for _, win in ipairs({ { x = 0, y = 0, w = 300, collapsed = true }, { x = 0, y = 0, w = 300, visible = false } }) do
        local calls = {}
        local ui = panel_ui(false, win)
        guide_panel(ui, calls)
        assert_eq(ui.ended, 1, "begin and end paired")
        assert_eq(#calls, 0, "nothing painted")
    end
end }

T[#T + 1] = { "guide panel: no overlay UI, the old spot at the right of the screen", function()
    local calls = {}
    guide_panel(nil, calls)
    assert_eq(calls[1][1], "rect", "a backdrop")
    assert_eq(calls[1][2], 1920 - 300 - 24, "right of the screen")
    assert_eq(calls[1][3], 120, "below the minimap")
end }

-- --- the path's end ring (1.88.0): JCore's ring_3d ---------------------------

--- A quest module drawing paths into `calls`, with or without ring_3d.
local function path_quests(calls, old_jcore)
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local draw = { path_3d = rec("path_3d"), circle_3d = rec("circle_3d"), text_3d = rec("text_3d") }
    if not old_jcore then draw.ring_3d = rec("ring_3d") end
    return build({ draw = draw, units = { player_position = function() return { x = 0, y = 0, z = 0 } end } })
end

local function named(calls, name)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c end end
    return out
end

T[#T + 1] = { "a path's end ring is JCore's shader ring: a thin band, full, in the path's colour", function()
    local calls = {}
    local Q = path_quests(calls)
    assert_eq(Q.draw_path_to({ x = 20, y = 0, z = 0 }, "gold", nil, { ring = 1.2 }), true, "drawn")
    local rings = named(calls, "ring_3d")
    assert_eq(#rings, 1, "one ring")
    assert_eq(#named(calls, "circle_3d"), 0, "no outline circle")
    local r = rings[1]
    assert_eq(r[1].x, 20, "at the end of the path")
    assert_eq(r[2], 1.2, "the size asked for")
    assert_eq(r[3], 1, "full all the way round")
    assert_eq(r[4], "gold", "in the path's colour")
    assert(r[5].inner >= 0.8 and r[5].outer == 1.0, "a thin band")
    assert_eq(r[5].layer, 100, "in the world band")

    local calls2 = {}
    path_quests(calls2).draw_path_to({ x = 20, y = 0, z = 0 }, "gold")
    assert_eq(named(calls2, "ring_3d")[1][2], 1.5, "1.5 yd by default")
end }

T[#T + 1] = { "a path's end ring: none when asked for none or cut short; an older JCore draws the outline", function()
    local calls = {}
    local Q = path_quests(calls)
    Q.draw_path_to({ x = 20, y = 0, z = 0 }, "gold", nil, { ring = false })
    assert_eq(#named(calls, "ring_3d"), 0, "ring = false: none")
    Q.draw_path_to({ x = 200, y = 0, z = 0 }, "gold", nil, { max_length = 50 })
    assert_eq(#named(calls, "ring_3d"), 0, "a path that stopped short arrived nowhere: no ring")

    local old = {}
    path_quests(old, true).draw_path_to({ x = 20, y = 0, z = 0 }, "gold")
    local c = named(old, "circle_3d")[1]
    assert(c, "the outline circle")
    assert_eq(c[2], 1.5, "its size")
    assert_eq(c[4].thickness, 2, "as before")
end }

return T

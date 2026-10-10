-- Jambix AIO 1.53.0: esp/forever_quests reading the GAME's own quest log on
-- Forever, through JCore's gamelua bridge (services/gamelua).
--
-- The bridge and the game behind it are the fake in mock/gamelua_fake.lua:
-- the quest module's own game-side bodies run against a scripted C_QuestLog,
-- C_Map, nameplates, tooltips and item names, so what is tested is the whole
-- way round -- the body the game would run, the pieces read back, and what
-- the ESP is then told: the quests and their objectives, a mob's KILL / LOOT
-- chip with its quest, the game's name for a unit, and each quest's area as
-- a world position (with the map-to-world conversion checked on the player
-- first, both ways round, and refused when it does not land on them).

local fake = require("mock/gamelua_fake")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local WOLF = "Creature-0-6783-2521-1-705-0000410C5D"
local SQUIRREL = "Creature-0-6783-2521-1-1412-0000AAAA01"
local MANGY = "Creature-0-6783-2521-1-706-0000BBBB02"

--- The game's side: two quests under a header, a wolf on a nameplate whose
--- tooltip names the first quest, a squirrel that is nothing, and Wolf Pelt
--- as the item a Mangy Wolf drops.
local function globals(opts)
    opts = opts or {}
    local QL = {
        GetNumQuestLogEntries = function() return 3 end,
        GetInfo = function(i)
            return ({
                { title = "Zephras Isle", isHeader = true },
                { questID = 92469, title = "Wolves at the Door" },
                { questID = 92470, title = "Pelts for the Tanner" },
            })[i]
        end,
        IsComplete = function() return false end,
        GetQuestObjectives = function(id)
            if id == 92469 then
                return { { text = "2/8 Ragged Young Wolf slain", type = "monster", finished = false,
                    numFulfilled = 2, numRequired = 8 } }
            end
            return { { text = "Wolf Pelt: 1/6", type = "item", finished = false, numFulfilled = 1, numRequired = 6 } }
        end,
        GetQuestsOnMap = function() return { { questID = 92469, x = opts.poi_x or 0.5, y = opts.poi_y or 0.5 } } end,
        UnitIsRelatedToActiveQuest = function(token) return token == "nameplate1" end,
    }
    local plates = { nameplate1 = WOLF, nameplate2 = SQUIRREL }
    return {
        C_QuestLog = QL,
        C_Map = {
            GetBestMapForUnit = function()
                if opts.map_raises then error("no map here") end
                return 2521
            end,
            GetPlayerMapPosition = function() return { x = opts.me_x or 0.25, y = opts.me_y or 0.25 } end,
        },
        C_NamePlate = { GetNamePlates = function()
            return { { namePlateUnitToken = "nameplate1" }, { namePlateUnitToken = "nameplate2" } }
        end },
        C_TooltipInfo = {
            GetUnit = function(token)
                if token == "nameplate1" then
                    return { lines = { { leftText = "Ragged Young Wolf" }, { type = 17, leftText = "Wolves at the Door" },
                        { type = 8, leftText = " - 2/8 Ragged Young Wolf slain" } } }
                end
                return { lines = { { leftText = "Grey Squirrel" } } }
            end,
            GetHyperlink = function(link)
                if link == "unit:" .. MANGY then return { lines = { { leftText = "Mangy Wolf" } } } end
                return nil
            end,
        },
        UnitExists = function(t) return plates[t] ~= nil end,
        UnitGUID = function(t) return plates[t] end,
        UnitName = function(t) return ({ nameplate1 = "Ragged Young Wolf", nameplate2 = "Grey Squirrel" })[t] end,
        C_Item = { GetItemNameByID = function(id) return id == 750 and "Wolf Pelt" or nil end },
    }
end

--- The module over a working bridge. `conv` is "direct", "swapped" or "far".
local function setup(opts)
    opts = opts or {}
    local W = fake.game({ mode = "deferred", globals = globals(opts) })
    W.core.game_ui = { get_world_pos_from_map_pos = function(_, p)
        if opts.conv == "swapped" then return { x = p.y * 1000, y = p.x * 1000 } end
        return { x = p.x * 1000, y = p.y * 1000 }
    end }
    local R = fake.build(W, opts.forever ~= false)
    local me = opts.me or { x = 250, y = 250, z = 10 }
    local function obj(guid, dist) return { guid = guid, row = { dist = dist, is_player = false, dead = false } } end
    local list = { obj(WOLF, 20), obj(SQUIRREL, 15), obj(MANGY, 30) }
    local traced = {}
    local P = {
        ctx = {
            emit = function(name, text) if name == "jcore.recorder.trace" then traced[#traced + 1] = text end end,
            gamelua = R.M,
            creatures = { info = function(id)
                if id == 706 then return { name = "Mangy Wolf", quest_items = { 750 } } end
                return { name = "?" }
            end },
        },
        units = {
            units = function() return list end,
            snapshot = function(o) return o.row end,
            guid = function(o) return o.guid end,
            player_position = function() return me end,
        },
    }
    package.loaded["jambix_aio/modules/esp/forever_quests"] = nil
    local Q = require("jambix_aio/modules/esp/forever_quests")(P)
    R.each_step = function() Q.refresh() end
    local S = { W = W, R = R, Q = Q, traced = traced }
    function S.traced_has(needle)
        for i = 1, #traced do if traced[i]:find(needle, 1, true) then return true end end
        return false
    end
    return S
end

local T = {}

T[#T + 1] = { "the quest log comes from the game: quests, objectives, and the store the readers use", function()
    local S = setup()
    S.R.run(5.5)
    assert_eq(S.R.M.state(), "ready", "the bridge is up")
    S.R.run(1.0)
    local live = S.Q.live
    assert_eq(live.ok, true, "the log answered")
    assert_eq(#live.order, 2, "two quests; the zone header is not one")
    assert_eq(live.how, "C_QuestLog", "read through C_QuestLog")
    assert_eq(live.quests[92469].title, "Wolves at the Door", "title")
    local kill = S.Q.objective("Ragged Young Wolf")
    assert(kill, "the kill objective is known by name")
    assert_eq(kill.kind, "kill", "a kill")
    assert_eq(kill.have, 2, "2")
    assert_eq(kill.need, 8, "of 8 (the retail order, numbers first, is read)")
    local item = S.Q.objective("Wolf Pelt")
    assert_eq(item and item.kind, "item", "the item objective, the classic order")
    assert_eq(item and item.have, 1, "1 of 6")
    assert_eq(S.Q.data.quests["92469"].on_quest, true, "on the quest")
    assert(S.traced_has("fquests: log: 2 quests via C_QuestLog, map 2521, conversion direct"), "the trace says what was read")
end }

T[#T + 1] = { "a mob the game ties to a quest gets its objective, its quest and its name; a squirrel gets nothing", function()
    local S = setup()
    S.R.run(7.0)
    local u = S.Q.unit(WOLF, 705)
    assert(u, "the wolf is a quest target")
    assert_eq(u.text, "KILL 2/8", "with the objective's progress")
    assert_eq(u.title, "Wolves at the Door", "and the quest")
    assert_eq(S.Q.unit_name(WOLF), "Ragged Young Wolf", "the game's own name for it")
    assert_eq(S.Q.unit(SQUIRREL, 1412), nil, "a squirrel is not")
    assert_eq(S.Q.unit_name(SQUIRREL), "Grey Squirrel", "but it is named")
    assert_eq(S.Q.stats().live_related, 1, "one unit on a quest")
end }

T[#T + 1] = { "what a mob drops for quests: the creature cache's quest items, named by the game, against the item objectives", function()
    local S = setup()
    S.R.run(7.0)
    assert_eq(S.Q.unit(MANGY, 706), nil, "the item's name is not known yet: asked for")
    S.R.run(1.0)
    local u = S.Q.unit(MANGY, 706)
    assert(u, "now it is")
    assert_eq(u.text, "LOOT 1/6", "it drops what the item objective wants")
    assert_eq(u.title, "Pelts for the Tanner", "and the quest it is for")
    assert_eq(S.Q.unit_name(MANGY), "Mangy Wolf", "named from its tooltip by guid")
end }

T[#T + 1] = { "quest areas: placed on the world once the conversion lands on you -- either axis order", function()
    local S = setup()
    S.R.run(7.0)
    local locs = S.Q.locations()
    assert_eq(#locs, 1, "one quest has an area on this map")
    assert_eq(locs[1].quest.id, 92469, "the kill quest")
    assert_eq(locs[1].x, 500, "x")
    assert_eq(locs[1].y, 500, "y")
    assert_eq(S.Q.live.conv, "direct", "the conversion is direct")

    local S2 = setup({ conv = "swapped", me_x = 0.25, me_y = 0.30, me = { x = 250, y = 300, z = 10 },
        poi_x = 0.5, poi_y = 0.6 })
    S2.R.run(7.0)
    assert_eq(S2.Q.live.conv, "swapped", "the axes come back the other way round")
    local l2 = S2.Q.locations()
    assert_eq(#l2, 1, "still placed")
    assert_eq(l2[1].x, 500, "x after the swap")
    assert_eq(l2[1].y, 600, "y after the swap")
end }

T[#T + 1] = { "a conversion that does not land on you places nothing", function()
    local S = setup({ me = { x = 9000, y = 9000, z = 0 } })
    S.R.run(7.0)
    assert_eq(S.Q.live.conv, "bad", "refused")
    assert_eq(#S.Q.locations(), 0, "no areas")
    assert_eq(#S.Q.live.order, 2, "the quests are still read")
end }

T[#T + 1] = { "one part of the game's answer failing costs that part only", function()
    local S = setup({ map_raises = true })
    S.R.run(7.0)
    assert_eq(#S.Q.live.order, 2, "the quests are read")
    assert_eq(S.Q.live.map, nil, "no map")
    assert(S.Q.live.errors[1] and S.Q.live.errors[1]:find("map:", 1, true), "the map's error is kept")
    assert(S.traced_has("errors: map:"), "and traced")
end }

T[#T + 1] = { "without the bridge nothing changes: no runs, no chips from the game", function()
    local S = setup({ forever = false })
    S.R.run(7.0)
    assert_eq(S.W.executed, 0, "nothing sent to the game")
    assert_eq(S.Q.live.ok, false, "no log")
    assert_eq(S.Q.unit(WOLF, 705), nil, "no chip")
    assert_eq(#S.Q.locations(), 0, "no areas")
end }

T[#T + 1] = { "the 2026-10-06 core: with no bridge the log comes from core.quests, and the readers follow it (1.82.0)", function()
    local S = setup({ forever = false })
    S.W.core.quests = {
        get_quest_log_quest_ids = function() return { 92469, 92470 } end,
        get_num_quest_log_entries = function() return 3 end,
        get_quest_log_title = function(i)
            return ({ { title = "Zephras Isle", is_header = true },
                { title = "Wolves at the Door", quest_id = 92469 },
                { title = "Pelts for the Tanner", quest_id = 92470 } })[i]
        end,
        get_quest_objectives = function(id)
            if id == 92469 then
                return { { text = "2/8 Ragged Young Wolf slain", type = "monster", finished = false, fulfilled = 2, required = 8 } }
            end
            return { { text = "Wolf Pelt: 6/6", type = "item", finished = true, fulfilled = 6, required = 6 } }
        end,
        is_quest_complete = function(id) return id == 92470 end,
    }
    S.R.run(3.0)
    assert_eq(S.W.executed, 0, "nothing sent to the game")
    local live = S.Q.live
    assert_eq(live.ok, true, "the log answered")
    assert_eq(live.how, "core", "from the core")
    assert_eq(#live.order, 2, "two quests; the header is not one")
    assert_eq(live.quests[92469].title, "Wolves at the Door", "the log's own title")
    assert_eq(live.quests[92470].complete, true, "ready, by the game's word")
    assert_eq(live.quests[92469].complete, false, "not ready")
    local kill = S.Q.objective("Ragged Young Wolf")
    assert(kill, "the kill objective is known by name")
    assert_eq(kill.kind, "kill", "a kill")
    assert_eq(kill.have, 2, "2"); assert_eq(kill.need, 8, "of 8")
    assert_eq(S.Q.data.quests["92469"].on_quest, true, "on the quest")
    assert_eq(#S.Q.locations(), 0, "no areas: those are the bridge's")
    assert(S.traced_has("fquests: log: 2 quests via core"), "the trace says where the log came from")
end }

return T

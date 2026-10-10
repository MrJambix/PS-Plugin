-- JCore 1.6.0 / services/questdb.lua: our own quest database, read from the
-- files tools/jcheck/questdb_extract.js wrote from QuestieDB (the real ones,
-- scripts_data/jcore/questdb/forever), with JCore booted as Forever. Names,
-- starters and finishers, objectives with their item droppers, spawns by zone,
-- the quests you are on from Forever's quest events, "could I take it", and
-- the Questie bridge's calls answered from it.

local mock = require("mock_core")
mock.install()
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"
mock.wow_fs["WTF/Config.wtf"] = 'SET textLocale "enUS"\n'

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- The real database files, laid into the mock's scripts_data.
local DIR = "scripts_data/jcore/questdb/forever"
local function lay(rel)
    local bytes = jtest.read_file(DIR .. "/" .. rel)
    assert(bytes, "the extracted database is missing: run tools/jcheck/questdb_extract.js (" .. rel .. ")")
    mock.data_fs["jcore/questdb/forever/" .. rel] = bytes
end
for _, rel in ipairs({ "index.json", "quest/0.json", "npc/0.json", "item/0.json" }) do lay(rel) end

local JCore, db

local T = {}

T[#T + 1] = { "boot as Forever", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    mock.frame(3)
    db = JCore.questdb
    assert(db, "JCore.questdb")
end }

T[#T + 1] = { "the database answers: quests, npcs, items, by QuestieDB's field names", function()
    assert_eq(db.available(), true, "available")
    assert_eq(db.get("quest", 179, "name"), "Dwarven Outfitters", "quest 179")
    assert_eq(db.get("quest", 179, "startedBy")[1][1], 658, "started by Sten Stoutarm")
    assert_eq(db.get("npc", 658, "name"), "Sten Stoutarm", "npc 658")
    local spawns = db.get("npc", 658, "spawns")
    assert(type(spawns[1]) == "table" and type(spawns[1][1][1]) == "number", "spawns by zone id, number keys")
    assert_eq(db.get("item", 750, "name"), "Tough Wolf Meat", "item 750")
    assert(#db.quest_ids() > 4000, "every quest id")
    assert_eq(db.get("quest", 92463, "name"), nil, "a Forever-only quest is not in the classic data")
end }

T[#T + 1] = { "a quest's objectives: the npcs that drop its items", function()
    local npcs = db.objective_ids(179)
    assert_eq(npcs[705], true, "Ragged Young Wolf drops Tough Wolf Meat")
    assert_eq(npcs[704], true, "and Ragged Timber Wolf")
end }

T[#T + 1] = { "Forever: the quests you are on, from its quest events", function()
    mock.game_event("QUEST_ACCEPTED", { 179 })
    local active = db.active()
    local found = false
    for _, id in ipairs(active) do if id == 179 then found = true end end
    assert(found, "accepted: on it")
    local q = db.questie()
    local ids = q.get_quest_npc_ids()
    local wolf = false
    for _, id in ipairs(ids) do if id == 705 then wolf = true end end
    assert(wolf, "the bridge's get_quest_npc_ids names the wolves")
    mock.game_event("QUEST_TURNED_IN", { 179, 80, 0 })
    for _, id in ipairs(db.active()) do assert(id ~= 179, "turned in: off the list") end
end }

T[#T + 1] = { "could I take it: not before its prerequisite is done", function()
    rawset(mock.core.quests, "is_quest_flagged_completed", function() return false end)
    rawset(mock.core.quests, "is_on_quest", function() return false end)
    assert_eq(db.is_doable(233), false, "233 needs 179 first")
    rawset(mock.core.quests, "is_quest_flagged_completed", function(id) return id == 179 end)
    assert_eq(db.is_doable(233), true, "179 done: 233 can be taken")
    assert_eq(db.questie().is_quest_doable(233), true, "the same through the bridge's call")
    assert_eq(db.questie().query_quest_single(233, "name"), "Coldridge Valley Mail Delivery", "query_quest_single")
    assert_eq(#mock.errors, 0, "no core.log_error")
end }

return T

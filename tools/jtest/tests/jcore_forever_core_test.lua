-- JCore 1.9.0 booted as Forever on the 2026-10-06 core (branch
-- lua_requests_06_10), which is told apart by the functions it added. What
-- that core fixed is used: cancel_buff reaches the native, the completed
-- quest list is believed, and the quests you are on, and whether each is
-- ready to hand in, come from the game's quest-ID readers.
-- jcore_forever_test.lua is the same client on an older core.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

-- What the 2026-10-06 core added. Set before the boot: world.client() reads
-- it once.
local game = { list = { 92469, 790 }, ready = { [790] = true }, on = {}, cancels = 0 }
rawset(mock.core, "get_server_time", function() return 1791400000 end)
rawset(mock.core.quests, "get_quest_log_quest_ids", function() return game.list end)
rawset(mock.core.quests, "get_quest_objectives", function() return {} end)
rawset(mock.core.quests, "is_quest_complete", function(id) return game.ready[id] == true end)
rawset(mock.core.quests, "is_on_quest", function(id) return game.on[id] == true end)
rawset(mock.core.input, "cancel_buff", function() game.cancels = game.cancels + 1 end)

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

local JCore, ctx, db

local T = {}

T[#T + 1] = { "boot as Forever on the 2026-10-06 core", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    assert(JCore, "_G.JCore missing")
    mock.frame(3)
    fail_on_errors("boot")
    ctx = JCore.register({ id = "jtest.forever_core", name = "Forever core test", version = "1.0.0" })
    db = JCore.questdb
    assert(ctx and db, "registered, and the quest database is there")
end }

T[#T + 1] = { "world.client() knows the core, and what it fixed on Forever", function()
    local c = JCore.world.client()
    assert_eq(c.forever, true, "forever")
    assert_eq(c.core_20261006, true, "the 2026-10-06 core")
    assert_eq(c.quest_ids, true, "the quest-ID readers")
    assert_eq(c.cancel_buff, true, "cancel_buff works")
    assert_eq(c.completed_quest_list, true, "the completed quest list is believed")
    assert_eq(c.classic_quest_log, false, "the classic log is still not walked there")
    assert_eq(c.combat_log, false, "what the core did not fix stays")
end }

T[#T + 1] = { "cancel_buff reaches the native, with no warning", function()
    ctx.input.cancel_buff({ impl = 1, buff_index = 1 })
    assert_eq(game.cancels, 1, "the native was called")
    for _, w in ipairs(mock.warnings) do
        assert(not w:find("cancel_buff does nothing", 1, true), "no 'does nothing' warning: " .. w)
    end
    fail_on_errors("cancel_buff")
end }

T[#T + 1] = { "questdb: the quests you are on are the game's list; a collapsed header's stays while you are on it", function()
    local active = db.active()
    assert_eq(#active, 2, "both listed")
    assert_eq(active[1], 790, "sorted"); assert_eq(active[2], 92469, "sorted")

    game.list = { 790 }               -- 92469's header collapsed
    game.on[92469] = true
    assert_eq(#db.active(), 2, "still on it")

    game.on[92469] = nil              -- abandoned
    active = db.active()
    assert_eq(#active, 1, "dropped")
    assert_eq(active[1], 790, "the other remains")
end }

T[#T + 1] = { "questdb: ready to hand in is the game's word; the Questie call answers Questie's 1 / 0", function()
    assert_eq(db.is_complete(790), true, "790 is ready")
    assert_eq(db.is_complete(92469), false, "92469 is not")
    local q = db.questie()
    assert_eq(q.is_quest_complete(790), 1, "Questie's 1, not true")
    assert_eq(q.is_quest_complete(92469), 0, "Questie's 0, not false")
    fail_on_errors("questdb")
end }

return T

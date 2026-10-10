-- JCore's API recorder (services/recorder.lua), built against a hand-made
-- runtime on the mock core. On Era it must be nothing at all; on Forever it
-- wraps every core function in place, answers exactly what the natives
-- answer (several returns, no return, a raise), records game_object methods
-- through the object's metatable, the game events per layout, and writes a
-- file the next session adds to.
--
-- The file (format 2) is one entry per function: its kind, what triggered
-- each call (phase and call site), what it answered, and for an action the
-- events that followed it. Repeats add no rows. A format 1 file converts.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()

local make_recorder = require("jambix_debug/services/recorder")

local FILE = "jcore/jcore.recorder.json"
local PAGE = "Jambix Debug/API recorder"

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

local function build_rt()
    local rt = { VERSION = "test" }
    rt.util = require("jcore/lib/util")
    rt.json = require("jcore/lib/json")
    rt.log = require("jcore/lib/log")(rt)
    rt.events = require("jcore/lib/events")(rt)
    rt.scheduler = require("jcore/lib/scheduler")(rt)
    rt.menu_ns = require("jcore/lib/menu_ns")(rt)
    return rt
end

--- Every function reachable from core (two namespace levels), by path.
local function snapshot()
    local out = {}
    local function walk(t, path, depth)
        for k, v in pairs(t) do
            local key = path == "" and k or (path .. "." .. k)
            if type(v) == "function" then
                out[key] = v
            elseif type(v) == "table" and depth < 2 then
                walk(v, key, depth + 1)
            end
        end
    end
    walk(mock.core, "", 0)
    return out
end

local function contains(list, value)
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

--- The first key of a map that matches a Lua pattern.
local function key_matching(map, pattern)
    for k in pairs(map or {}) do
        if tostring(k):find(pattern) then return k end
    end
    return nil
end

-- --- the natives this test answers with ---------------------------------------

local methods = {
    get_health = function(self) return self.hp end,
    get_position = function() return { x = 1, y = 2, z = 3 } end,
    get_name = function(self) return self.name end,
    get_buffs = function() return {} end,
}
-- One metatable shared by every object, with a lookup FUNCTION for __index:
-- the shape a native usertype has.
local obj_mt = { __index = function(_, key) return methods[key] end }
local original_index = obj_mt.__index
local me = setmetatable({ hp = 100, name = "Me" }, obj_mt)

rawset(mock.core.spell_book, "get_spell_cooldown", function() return 0 end)
rawset(mock.core.spell_book, "get_spell_charge", function() return 1, nil, 3, nil end)
rawset(mock.core.spell_book, "get_test_a", function() return 1 end)
rawset(mock.core.spell_book, "get_test_b", function() return 2 end)
rawset(mock.core.spell_book, "get_test_c", function() return 3 end)
rawset(mock.core.input, "jump", function() end)
rawset(mock.core.input, "cast_target_spell", function() return true end)
rawset(mock.core.input, "cancel_buff", function()
    error("attempt to call a nil value (global 'UnitBuff')")
end)
rawset(mock.core.object_manager, "get_local_player", function() return me end)
rawset(mock.core, "get_owning_plugin_name", function() return "JCore" end)
rawset(mock.core, "set_console_key", function() end)
mock.core.addons.questie = { get_quest_title = function() return nil end }

local before = snapshot()
local R, rt
local original_update, original_emit

local T = {}

T[#T + 1] = { "Era: nothing is wrapped, read, subscribed, paged or written", function()
    mock.game_version = "Vanilla"
    local data_reads = 0
    local real_read = mock.core.read_data_file
    rawset(mock.core, "read_data_file", function(p)
        data_reads = data_reads + 1
        return real_read(p)
    end)

    local era_rt = build_rt()
    local era_update, era_emit = era_rt.scheduler.on_update, era_rt.events.emit
    local era = make_recorder(era_rt)
    rawset(mock.core, "read_data_file", real_read)

    assert_eq(era.available, false, "available")
    assert_eq(era.active(), false, "active")
    assert_eq(data_reads, 0, "data files read")
    local now = snapshot()
    for key, fn in pairs(before) do
        assert(now[key] == fn, "Era changed core." .. key)
    end
    assert(era_rt.scheduler.on_update == era_update and era_rt.events.emit == era_emit, "no phase hooks on Era")
    assert_eq(era_rt.events.listener_count("jcore.game_event"), 0, "game event listeners")
    assert_eq(era_rt.events.listener_count("jcore.ready"), 0, "ready listeners")
    era_rt.events.emit("jcore.ready", {})
    assert(mock.menu.pages[PAGE] == nil, "no page on Era")
    assert(mock.data_fs[FILE] == nil, "no file on Era")
    fail_on_errors("era")
end }

T[#T + 1] = { "Forever: every core function is wrapped in place, except the stack-sensitive ones", function()
    mock.game_version = "Forever"
    mock.exact_game_version = "wow_forever_us"
    rt = build_rt()
    original_update, original_emit = rt.scheduler.on_update, rt.events.emit
    R = make_recorder(rt)
    assert_eq(R.available, true, "available")
    assert_eq(R.active(), true, "active")

    assert(mock.core.spell_book.get_spell_cooldown ~= before["spell_book.get_spell_cooldown"], "namespace call wrapped")
    assert(mock.core.addons.questie.get_quest_title ~= before["addons.questie.get_quest_title"], "sub-namespace wrapped")
    assert(mock.core.get_map_id ~= before["get_map_id"], "top-level call wrapped")
    assert(mock.core.time ~= before["time"], "clock counted")

    assert(mock.core.menu.window == before["menu.window"], "core.menu is never wrapped")
    assert(mock.core.get_owning_plugin_name == before["get_owning_plugin_name"], "owning plugin is never wrapped")
    assert(mock.core.register_on_update_callback == before["register_on_update_callback"], "register_* never wrapped")
    assert(mock.core.log_error == before["log_error"], "log never wrapped")
    assert(rt.scheduler.on_update ~= original_update, "the update phase is hooked")
    assert(rt.events.emit ~= original_emit, "the event bus is hooked")
    assert_eq(R.stats().unwritable, 0, "unwritable")
    fail_on_errors("install")
end }

T[#T + 1] = { "a wrapped call answers exactly what the native answers", function()
    local c = mock.core
    assert_eq(c.spell_book.get_spell_cooldown(133), 0, "plain answer")
    assert_eq(c.time(), mock.time, "clock")

    assert_eq(select("#", c.spell_book.get_spell_charge(1)), 4, "four answers, trailing nil kept")
    local a, b, d, e = c.spell_book.get_spell_charge(1)
    assert(a == 1 and b == nil and d == 3 and e == nil, "values")
    assert_eq(select("#", c.input.jump()), 0, "no answer stays no answer")

    local ok1, err1 = pcall(before["input.cancel_buff"], {})
    local ok2, err2 = pcall(c.input.cancel_buff, {})
    assert(not ok1 and not ok2, "both raise")
    assert_eq(err2, err1, "the same message")

    -- Past the inspected first calls, onto the sampled path.
    for i = 1, 300 do
        assert_eq(c.spell_book.get_spell_cooldown(i), 0, "sampled answer " .. i)
        local _, _, three = c.spell_book.get_spell_charge(i)
        assert_eq(three, 3, "sampled third answer " .. i)
    end
    local ok3 = pcall(c.input.cancel_buff, {})
    assert(not ok3, "still raises when not inspected")
    -- Through the hooked scheduler and bus, answers and order are untouched.
    local order = {}
    rt.scheduler.add("update", function() order[#order + 1] = "job" end, { owner = "test" })
    rt.events.on("test.topic", function(x) order[#order + 1] = "handler " .. tostring(x) end, { owner = "test" })
    rt.scheduler.on_update()
    rt.events.emit("test.topic", 7)
    assert_eq(table.concat(order, ","), "job,handler 7", "jobs and handlers still run")
    rt.scheduler.remove_owner("test")
    rt.events.off_owner("test")
end }

T[#T + 1] = { "game_object methods are recorded through the object's metatable", function()
    local p = mock.core.object_manager.get_local_player()
    assert(p == me, "the same object")
    assert(obj_mt.__index ~= original_index, "the lookup is proxied")
    assert_eq(me:get_health(), 100, "method answer")
    assert_eq(me.name, "Me", "a plain field is untouched")
    assert_eq(me.not_a_method, nil, "a missing key is still nil")
    assert_eq(me:get_name(), "Me", "second method")

    local r = R.report()
    local rec = r.methods["get_health"]
    assert(rec, "get_health recorded under methods")
    assert(r.functions["game_object:get_health"] == nil, "not mixed into the functions")
    assert_eq(rec.calls, 1, "calls")
    assert_eq(rec.kind, "read", "a method is a read")
    assert_eq(rec.examples[1].call, "()", "self is not an argument")
    assert_eq(rec.examples[1].answer, "100", "answer")
    assert_eq(rec.returns[1], "num", "answer kind")
    assert_eq(rec.origin, "Lua", "a script-defined method is told from the client's own")
    assert_eq(r.surface.object_index, "function", "object index kind")
    assert(contains(r.surface.object_methods, "get_name"), "method surface")
end }

T[#T + 1] = { "events are recorded per argument layout, the combat log per sub-event", function()
    rt.events.emit("jcore.game_event", "UNIT_AURA", { "player", { isFullUpdate = true } })
    rt.events.emit("jcore.game_event", "UNIT_AURA", { "player", { isFullUpdate = true } })
    rt.events.emit("jcore.game_event", "COMBAT_LOG_EVENT_UNFILTERED",
        { 1.5, "SPELL_DAMAGE", false, "Player-1", "Me", [13] = "Fireball", [15] = 120 })
    rt.events.emit("jcore.game_event", "COMBAT_LOG_EVENT_UNFILTERED", { 1.6, "SWING_DAMAGE", false, "Player-1" })
    rt.events.emit("jcore.spell.cast", { spell_id = 133 })

    local ev = R.report().events
    assert_eq(ev["UNIT_AURA"].count, 2, "aura count")
    assert_eq(#ev["UNIT_AURA"].layouts, 1, "one layout, one example")
    assert_eq(ev["UNIT_AURA"].layouts[1].kinds, "str,tbl", "the layout's kinds")
    local dmg = ev["COMBAT_LOG_EVENT_UNFILTERED:SPELL_DAMAGE"]
    assert(dmg, "combat log keyed by sub-event")
    assert_eq(dmg.layouts[1].size, 15, "positions up to the last one present")
    assert(dmg.layouts[1].example:find("\"Fireball\"", 1, true), "example shows the spell name")
    assert(ev["COMBAT_LOG_EVENT_UNFILTERED:SWING_DAMAGE"], "second sub-event")
    assert(ev["callback:spell_cast"], "spell cast callback")
end }

T[#T + 1] = { "the report says what each function is, what was always empty, what raised, and the surface", function()
    for _ = 1, 3 do mock.core.graphics.rect_2d_filled() end
    mock.core.set_console_key(46)
    local r = R.report()
    assert_eq(r.format, 2, "format")
    assert_eq(r.client.version, "Forever", "version")
    assert_eq(r.client.exact, "wow_forever_us", "exact")
    assert(type(r._about) == "table" and r._about.triggers, "the file explains itself")

    local cd = r.functions["spell_book.get_spell_cooldown"]
    assert(cd.calls >= 301, "every call counted")
    assert_eq(cd.empty, cd.tallied, "always empty")
    assert(cd.inspected < cd.tallied, "sampled, not all inspected")
    assert_eq(cd.status, "always empty", "status")
    assert_eq(cd.kind, "read", "a getter is a read")
    assert_eq(cd.args[1], "num", "argument kind")
    local empty = R.empty_only()
    assert(contains(empty, "spell_book.get_spell_cooldown"), "listed as always empty")
    assert(not contains(empty, "spell_book.get_spell_charge"), "charge answered")
    assert_eq(r.functions["spell_book.get_spell_charge"].returns[2], "nil", "a nil answer position")

    assert(not contains(empty, "input.jump"), "a call that answers nothing at all is an action, not empty")
    assert_eq(r.functions["input.jump"].kind, "action", "input.jump is an action")
    assert_eq(r.functions["input.jump"].status, "returns nothing", "and says so")
    assert_eq(r.functions["set_console_key"].kind, "loader", "the loader's own settings")

    local cb = r.functions["input.cancel_buff"]
    assert(cb.errors >= 1, "raise counted")
    assert_eq(cb.inspected, cb.errors, "a raise is an inspected call")
    assert(cb.raised[1].error:find("UnitBuff", 1, true), "message kept")
    assert_eq(#cb.raised, 1, "one distinct message")
    assert_eq(cb.status, "raises", "status")

    local rect = r.functions["graphics.rect_2d_filled"]
    assert_eq(rect.kind, "paint", "paint calls are counted only")
    assert_eq(rect.calls, 3, "paint count")
    assert_eq(rect.inspected, nil, "paint never inspected")
    assert_eq(r.functions["time"].kind, "clock", "the clock")

    assert(contains(r.surface.core, "get_map_id"), "top-level surface")
    assert(contains(r.surface.namespaces["spell_book"], "get_spell_cooldown"), "namespace surface")
    assert(contains(r.surface.namespaces["addons.questie"], "get_quest_title"), "sub-namespace surface")
    assert(contains(r.surface.skipped, "menu.*"), "menu skipped")
    assert(contains(r.surface.skipped, "get_owning_plugin_name"), "owning plugin skipped")
    assert(contains(r.surface.skipped, "register_on_update_callback"), "register skipped")
    local cov = r.coverage["input"]
    assert(cov and cov.exposed >= 3 and cov.called >= 2, "coverage per namespace")
    assert(r.coverage["game_object"] and r.coverage["game_object"].called >= 2, "coverage of the methods")
    fail_on_errors("report")
end }

T[#T + 1] = { "what triggered it: the phase and the call site", function()
    rt.scheduler.add("update", function() mock.core.spell_book.get_test_a() end, { owner = "test" })
    rt.scheduler.on_update()
    rt.scheduler.remove_owner("test")
    rt.events.on("jcore.game_event.PLAYER_REGEN_DISABLED", function() mock.core.spell_book.get_test_b() end,
        { owner = "test" })
    rt.events.emit("jcore.game_event", "PLAYER_REGEN_DISABLED", {})
    rt.events.emit("jcore.game_event.PLAYER_REGEN_DISABLED", {})
    rt.events.off_owner("test")
    mock.core.spell_book.get_test_c()

    local r = R.report()
    assert(r.triggers_from:find("call stack", 1, true), "the harness has debug.getinfo: " .. r.triggers_from)
    local a = r.functions["spell_book.get_test_a"]
    local in_update = key_matching(a.triggers, "^update .*jcore_recorder_test:%d+$")
    assert(in_update, "an update job, with its line: " .. tostring(next(a.triggers)))
    assert_eq(a.examples[1].by, in_update, "the example says what triggered it")
    local b = r.functions["spell_book.get_test_b"]
    assert(key_matching(b.triggers, "^event PLAYER_REGEN_DISABLED .*jcore_recorder_test:%d+$"),
        "an event handler: " .. tostring(next(b.triggers)))
    local c = r.functions["spell_book.get_test_c"]
    assert(key_matching(c.triggers, "^outside JCore .*jcore_recorder_test:%d+$"),
        "a call from outside JCore's dispatch: " .. tostring(next(c.triggers)))

    -- The recorder's own reads (the catalog) are filed as the recorder's.
    mock.time = mock.time + 2.5
    rt.scheduler.on_update()
    local map = R.report().functions["get_map_id"]
    assert(map and map.triggers["recorder"], "the catalog's read is the recorder's doing")
    fail_on_errors("triggers")
end }

T[#T + 1] = { "what an action does: the events that followed it, and what set an event off", function()
    mock.time = mock.time + 10      -- every earlier window closed
    local ev = function(name, args) rt.events.emit("jcore.game_event", name, args) end
    assert_eq(mock.core.input.cast_target_spell(1752, me), true, "the action's answer")
    ev("UNIT_SPELLCAST_SENT", { "player", "Mob", "Cast-3-1-1-1-1752-0001", 1752 })
    ev("UNIT_SPELLCAST_SENT", { "player", "Mob", "Cast-3-1-1-1-1752-0002", 1752 })
    ev("UI_ERROR_MESSAGE", { 62, "Ability is not ready yet.", "ERR_ABILITY_COOLDOWN" })
    ev("UNIT_AURA", { "added", "nameplate2", 3, 133, "Fireball", 0, 4, 548000, nil, false, true })
    mock.time = mock.time + 5
    ev("PLAYER_REGEN_ENABLED", {})

    local r = R.report()
    local cast = r.functions["input.cast_target_spell"]
    assert_eq(cast.kind, "action", "kind")
    assert_eq(cast.effects.windows, 1, "one call watched")
    assert_eq(cast.effects["UNIT_SPELLCAST_SENT(player)"], 1, "followed by the cast event, once per call")
    assert_eq(cast.effects["UI_ERROR_MESSAGE:ERR_ABILITY_COOLDOWN"], 1, "an error, by its tag")
    assert_eq(cast.effects["UNIT_AURA(nameplate)"], 1, "an aura, by the kind of unit")
    assert_eq(cast.effects["PLAYER_REGEN_ENABLED"], nil, "nothing after the window closed")
    local ex = cast.examples[1]
    assert_eq(ex.call, "(1752, obj)", "the call")
    assert_eq(ex.answer, "true", "its answer")
    assert_eq(table.concat(ex["then"], ", "),
        "UNIT_SPELLCAST_SENT(player), UI_ERROR_MESSAGE:ERR_ABILITY_COOLDOWN, UNIT_AURA(nameplate)", "then")
    assert_eq(r.events["UNIT_SPELLCAST_SENT"].after["input.cast_target_spell"], 1, "the event's cause")
    assert_eq(r.events["PLAYER_REGEN_ENABLED"].unprompted, 1, "nothing was watching: the game did it")

    -- The next call of the same action closes the window it had open.
    mock.core.input.cast_target_spell(1752, me)
    mock.core.input.cast_target_spell(1752, me)
    ev("UNIT_SPELLCAST_SENT", { "player", "Mob", "Cast-3-1-1-1-1752-0003", 1752 })
    cast = R.report().functions["input.cast_target_spell"]
    assert_eq(cast.effects.windows, 3, "three calls watched")
    assert_eq(cast.effects["UNIT_SPELLCAST_SENT(player)"], 2, "the event counted against the newest call only")
    assert_eq(#cast.examples, 1, "the same call again adds no example")
    fail_on_errors("effects")
end }

T[#T + 1] = { "a call made over and over adds no rows: examples and triggers stay a few", function()
    local function rows(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n
    end
    local learned = R.stats().learned.examples
    local had = rows(R.report().functions["spell_book.get_spell_cooldown"].triggers)
    for i = 1, 2000 do mock.core.spell_book.get_spell_cooldown(i % 5) end
    local cd = R.report().functions["spell_book.get_spell_cooldown"]
    assert_eq(#cd.examples, 8, "capped: eight distinct calls of one answer shape")
    assert_eq(rows(cd.triggers), had + 1, "2000 calls from one line: one trigger row")
    assert_eq(R.stats().learned.examples, learned, "nothing new learned")
end }

T[#T + 1] = { "the trace writes a line once, not every frame", function()
    local start = #R.trace_lines()
    R.trace("fesp 0000ABCDEF Mob d= 12.3 drawn@100,200")
    R.trace("fesp 0000ABCDEF Mob d= 12.9 drawn@104,201")
    assert_eq(#R.trace_lines(), start + 1, "the same mark a few yards on is skipped")
    R.trace("fesp 0000ABCDEF Mob d= 12.9 offscreen")
    assert_eq(#R.trace_lines(), start + 2, "a change of state is written")
    R.trace("fesp 0000ABCDEE Mob d= 12.9 offscreen")
    assert_eq(#R.trace_lines(), start + 3, "another unit is its own line")
    mock.time = mock.time + 61
    R.trace("fesp 0000ABCDEF Mob d= 13.0 drawn@1,2")
    local lines = R.trace_lines()
    assert_eq(#lines, start + 4, "after a minute, written again")
    assert(lines[#lines]:find("(x1 since)", 1, true), "with how often it was skipped: " .. lines[#lines])
    assert(R.stats().trace_skipped >= 1, "skips counted")
end }

T[#T + 1] = { "the page appears once the runtime is ready, and its switch stops and restarts recording", function()
    assert(mock.menu.pages[PAGE] == nil, "no page before jcore.ready")
    rt.events.emit("jcore.ready", {})
    assert(mock.menu.pages[PAGE], "page declared")
    mock.menu.title_errors = {}
    mock.menu:render_titles()
    assert_eq(#mock.menu.title_errors, 0, "live lines: " .. table.concat(mock.menu.title_errors, "; "))

    mock.data_fs[FILE] = nil
    mock.menu:set(PAGE, "record", false)
    assert_eq(R.active(), false, "stopped")
    local now = snapshot()
    for key, fn in pairs(before) do
        assert(now[key] == fn, "stop did not restore core." .. key)
    end
    assert(obj_mt.__index == original_index, "object lookup restored")
    assert(rt.scheduler.on_update == original_update, "update phase hook removed")
    assert(rt.events.emit == original_emit, "event bus hook removed")
    assert_eq(rt.events.listener_count("jcore.game_event"), 0, "unsubscribed")
    assert(mock.data_fs[FILE] and #mock.data_fs[FILE] > 0, "stop saved")

    mock.menu:set(PAGE, "record", true)
    assert_eq(R.active(), true, "restarted")
    assert(mock.core.spell_book.get_spell_cooldown ~= before["spell_book.get_spell_cooldown"], "wrapped again")
    mock.core.object_manager.get_local_player()
    assert(obj_mt.__index ~= original_index, "object proxied again")
    fail_on_errors("page")
end }

T[#T + 1] = { "the file is written on schedule, decodes, and the next session adds to it", function()
    mock.data_fs[FILE] = nil
    mock.core.spell_book.get_spell_cooldown(7)
    -- The .api says this is always {} on Forever; answering here gives the
    -- report tool a "note to fix" to find in the file kept below.
    rawset(mock.core.game_ui, "get_all_completed_quest_ids", function() return { 101, 102 } end)
    R.stop()
    R.start()
    mock.core.game_ui.get_all_completed_quest_ids()
    for _ = 1, 12 do
        mock.time = mock.time + 5
        rt.scheduler.on_update()
    end
    local text = mock.data_fs[FILE]
    assert(text and #text > 0, "written by the timer")
    local data = rt.json.decode(text)
    assert(type(data) == "table" and type(data.functions) == "table", "decodes")
    local first = data.functions["spell_book.get_spell_cooldown"].calls
    assert_eq(data.sessions.count, 1, "first session")
    local log1 = data.sessions.log[#data.sessions.log]
    assert(log1.n == 1 and log1.learned.functions > 0, "the session log says what it learned")
    -- Kept for tools/jcheck/recorder_report.js to be tried on.
    if jtest and jtest.write_file then jtest.write_file("recorder/jcore.recorder.json", text) end

    R.stop()
    local rt2 = build_rt()
    local R2 = make_recorder(rt2)
    assert_eq(R2.stats().sessions, 2, "second session")
    mock.core.spell_book.get_spell_cooldown(8)
    local r2 = R2.report()
    local again = r2.functions["spell_book.get_spell_cooldown"]
    assert_eq(again.calls, first + 1, "counts carried over")
    assert_eq(again.first_session, 1, "first seen in session 1")
    assert_eq(#again.examples, 8, "examples carried over, not doubled")
    assert(r2.events["UNIT_AURA"], "events carried over")
    assert_eq(R2.stats().learned.functions, 0, "a known function is not new")
    assert_eq(#r2.sessions.log, 2, "both sessions in the log")

    -- A file from another client is not merged.
    R2.stop()
    mock.data_fs[FILE] = mock.data_fs[FILE]:gsub("\"Forever\"", "\"Midnight\"")
    local R3 = make_recorder(build_rt())
    assert_eq(R3.stats().sessions, 1, "other client's file ignored")
    R3.stop()
    fail_on_errors("sessions")
end }

T[#T + 1] = { "a format 1 recording is converted, nothing lost", function()
    local v1 = {
        format = 1,
        client = { version = "Forever", exact = "wow_forever_us", jcore = "1.5.11" },
        sessions = 24,
        calls = {
            ["input.set_target"] = { mode = "full", calls = 36721, tallied = 616, empty = 0, inspected = 616,
                errors = 0, shapes = { ["true"] = 616 }, samples = { { args = "obj", ret = "true", shape = "true" } },
                error_samples = {} },
            ["game_object:get_power"] = { mode = "full", method = true, calls = 10, tallied = 10, empty = 10,
                inspected = 10, errors = 0, shapes = { ["0"] = 10 }, samples = { { args = "3", ret = "0", shape = "0" } },
                error_samples = {} },
            ["graphics.rect_2d"] = { mode = "count", calls = 99, tallied = 0, empty = 0, inspected = 0, errors = 0,
                shapes = {}, samples = {}, error_samples = {} },
            ["input.cancel_buff"] = { mode = "full", calls = 2, tallied = 0, empty = 0, inspected = 2, errors = 2,
                shapes = {}, samples = {}, error_samples = { { error = "boom", args = "1" } } },
        },
        events = { UNIT_AURA = { count = 5, signatures = { "str,str" },
            samples = { { size = 2, args = "\"player\", \"x\"" } } } },
        surface = { object_methods = { "get_power" } },
    }
    mock.data_fs[FILE] = rt.json.encode(v1)
    local Rv = make_recorder(build_rt())
    local r = Rv.report()
    assert_eq(r.format, 2, "written as format 2")
    assert_eq(r.sessions.count, 25, "sessions carried on")
    local st = r.functions["input.set_target"]
    assert_eq(st.kind, "action", "kind worked out")
    assert_eq(st.calls, 36721, "calls kept")
    assert_eq(st.examples[1].call, "(obj)", "sample became an example")
    assert_eq(st.examples[1].answer, "true", "with its answer")
    assert_eq(st.returns[1], "true", "answer kinds from the shapes")
    assert_eq(st.last_session, 24, "known before this session")
    assert_eq(r.methods["get_power"].status, "always empty", "a method, split out")
    assert_eq(r.methods["get_power"].examples[1].call, "(3)", "its example")
    assert_eq(r.functions["graphics.rect_2d"].kind, "paint", "counted calls stay counted")
    assert_eq(r.functions["input.cancel_buff"].raised[1].error, "boom", "errors kept")
    assert_eq(r.events["UNIT_AURA"].count, 5, "event counts kept")
    assert_eq(r.events["UNIT_AURA"].layouts[1].example, "\"player\", \"x\"", "event samples kept")
    assert_eq(Rv.stats().learned.functions, 0, "nothing in it counts as new")
    assert(Rv.save(), "saved")
    local data = rt.json.decode(mock.data_fs[FILE])
    assert(data.format == 2 and data.functions["input.set_target"] and data.calls == nil, "the file is format 2 now")
    Rv.stop()
    mock.data_fs[FILE] = nil
    fail_on_errors("convert")
end }

T[#T + 1] = { "the catalog: every spell, aura, npc, quest, objective, talent and gossip answer, from the events Forever sends", function()
    -- The client, answering the getters the catalog asks.
    local c = mock.core
    local reward_taken = false
    rawset(c.spell_book, "get_spell_name", function(id)
        return ({ [1752] = "Sinister Strike", [6603] = "Auto Attack", [1248802] = "Corrupted Wind" })[id] or ""
    end)
    rawset(c.spell_book, "get_spells", function() return { 1752, 6603 } end)
    rawset(c.spell_book, "get_spell_description", function(id) return id == 1752 and "An instant strike." or "" end)
    rawset(c.quests, "is_on_quest", function(id) return id == 92469 end)
    rawset(c.quests, "get_num_quest_log_entries", function() return 0 end)
    rawset(c.quests, "get_gossip_available_quests", function() return { { title = "Into the Winds", level = 4 } } end)
    rawset(c.quests, "get_quest_reward", function() reward_taken = true end)
    rawset(c.game_ui, "get_talent_tree_ids", function() return { 790 } end)
    rawset(c.game_ui, "get_talent_tree_nodes", function() return { 101, 102 } end)
    rawset(c.game_ui, "get_talent_node_info", function(node) return { node_id = node, active_rank = 0, max_ranks = 1 } end)

    mock.game_version = "Forever"
    mock.data_fs["jcore/jcore.catalog.json"] = nil
    local rt4 = build_rt()
    local R4 = make_recorder(rt4)

    -- A mob in the sweep, and your target.
    local mob = setmetatable({}, { __index = {
        get_npc_id = function() return 251143 end, get_creature_type = function() return 4 end,
        get_level = function() return 3 end, get_max_health = function() return 79 end,
    } })
    rt4.units = {
        units = function() return { mob } end,
        snapshot = function(o) return o == mob and { guid = "Creature-0-1-0-0-251143-0000ABCDEF", is_enemy = true } or nil end,
        guid = function(o) return o == mob and "Creature-0-1-0-0-251143-0000ABCDEF" or nil end,
    }
    rt4.combat = { target = function() return mob end }

    local ev = function(name, args) rt4.events.emit("jcore.game_event", name, args) end
    ev("UNIT_SPELLCAST_SENT", { "player", "Roiling Winds", "Cast-3-1-1-1-1752-0001", 1752 })
    ev("UNIT_SPELLCAST_START", { "nameplate1", "Cast-3-1-1-1-1248802-0002", 1248802, "CastBar-1" })
    ev("UNIT_AURA", { "added", "nameplate2", 3, 133, "Fireball", 0, 4, 548000, nil, false, true })
    ev("QUEST_ACCEPTED", { 92469 })
    ev("QUEST_TURNED_IN", { 92465, 250, 50 })
    ev("UI_INFO_MESSAGE", { 316, "Roiling Winds destroyed: 4/6", "ERR_QUEST_ADD_FOUND_SII" })
    ev("GOSSIP_SHOW", {})
    ev("GOSSIP_SHOW", {})
    rt4.events.emit("jcore.enemy.casting", { guid = "Creature-0-1-0-0-251143-0000ABCDEF", obj = mob },
        { spell_id = 1248802 })
    for _ = 1, 15 do
        mock.time = mock.time + 2.1
        rt4.scheduler.on_update()
    end

    local cat = R4.catalog()
    local ss = cat.spells["1752"]
    assert(ss and ss.name == "Sinister Strike", "your spell, named by the client")
    assert(ss.from.cast_player and ss.from.spellbook, "cast and in the spellbook")
    assert_eq(ss.description, "An instant strike.", "its description")
    assert(cat.spells["6603"] and cat.spells["6603"].from.spellbook, "the whole spellbook")
    local wind = cat.spells["1248802"]
    assert(wind and wind.from.cast_npc and wind.from.cast_other, "a mob's cast")
    assert_eq(wind.npcs["251143"], 1, "tied to its npc")
    assert_eq(cat.spells["133"].name, "Fireball", "an aura, named by its record")
    local npc = cat.npcs["251143"]
    assert(npc and npc.names["Roiling Winds"], "the npc named by what you cast at")
    assert_eq(npc.creature_type, 4, "its type")
    assert_eq(npc.level_min, 3, "its level")
    assert(cat.quests["92469"].accepted_at, "accepted")
    assert_eq(cat.quests["92469"].on_quest, true, "is_on_quest probed")
    assert_eq(cat.quests["92465"].xp, 250, "turned in, with its reward")
    local o = cat.objectives["Roiling Winds destroyed"]
    assert(o and o.have == 4 and o.need == 6, "objective progress")
    assert(cat.gossip[1] and cat.gossip[1].available[1].title == "Into the Winds", "the gossip window's quests")
    assert_eq(#cat.gossip, 1, "the same window twice is one row")
    assert_eq(cat.gossip[1].seen, 2, "counted twice")
    assert_eq(cat.talents.tree_ids[1], 790, "trait trees")
    assert(cat.talents.nodes["101"] and cat.talents.nodes["102"], "every node read")
    assert_eq(reward_taken, false, "get_quest_reward -- an action -- is never called")
    local names = R4.report().functions["spell_book.get_spell_name"]
    assert(names and names.triggers["recorder"], "the catalog's reads are filed as the recorder's")

    assert(R4.save(), "saved")
    local text = mock.data_fs["jcore/jcore.catalog.json"]
    assert(text and #text > 0, "the catalog file")
    local data = rt4.json.decode(text)
    assert(data.spells["1752"] and data.quests["92469"], "decodes")
    if jtest and jtest.write_file then jtest.write_file("recorder/jcore.catalog.json", text) end

    -- The next session adds to it.
    R4.stop()
    local rt5 = build_rt()
    local R5 = make_recorder(rt5)
    assert(R5.catalog().spells["1752"], "carried into the next session")
    R5.stop()
    fail_on_errors("catalog")
end }

T[#T + 1] = { "the missing Forever features: candidate reads, and the ground truth beside them", function()
    local c = mock.core
    rawset(c.spell_book, "get_spell_name", function(id)
        return ({ [2366] = "Herb Gathering", [1752] = "Sinister Strike" })[id] or ""
    end)
    rawset(c.game_ui, "get_loot_item_count", function() return 2 end)
    rawset(c.game_ui, "get_loot_item_id", function(i) return i == 1 and 2589 or 0 end)
    rawset(c.game_ui, "get_loot_item_name", function(i) return i == 1 and "Linen Cloth" or "Copper" end)
    rawset(c.game_ui, "get_loot_is_gold", function(i) return i == 2 end)

    mock.game_version = "Forever"
    mock.data_fs["jcore/jcore.catalog.json"] = nil
    local rt6 = build_rt()
    local R6 = make_recorder(rt6)

    local function thing(methods) return setmetatable({}, { __index = methods }) end
    local marker = 16
    local mob = thing({
        get_npc_id = function() return 251143 end, get_level = function() return 3 end,
        get_creature_type = function() return 4 end, get_max_health = function() return 79 end,
        is_quest_unit = function() return true end, get_npc_flags = function() return 2 end,
        get_classification = function() return 0 end, is_boss = function() return false end,
        get_target_marker_index = function() return marker end, is_tap_denied = function() return false end,
        get_state_flags = function() return 0 end,
    })
    local corpse = thing({
        get_npc_id = function() return 251144 end, get_level = function() return 3 end,
        has_loot = function() return false end, can_be_looted = function() return false end,
        get_state_flags = function() return 4 end, can_be_skinned = function() return false end,
    })
    local herb = thing({
        get_name = function() return "Peacebloom" end, get_type = function() return 8 end,
        get_npc_id = function() return 1617 end, can_be_used = function() return true end,
    })
    local rows = {
        [mob] = { guid = "Creature-0-1-0-0-251143-0000AAAAAA", is_enemy = true, dist = 20, obj = mob },
        [corpse] = { guid = "Creature-0-1-0-0-251144-0000BBBBBB", dead = true, dist = 3, obj = corpse },
        [herb] = { guid = "GameObject-0-1-0-0-1617-0000CCCCCC", dist = 4, obj = herb },
    }
    rt6.units = {
        units = function() return { mob, corpse } end,
        objects = function() return { herb } end,
        snapshot = function(o) return rows[o] end,
        guid = function(o) return rows[o] and rows[o].guid end,
    }
    rt6.enemies = { get = function(guid)
        if guid == rows[mob].guid then return { in_combat = true, target_guid = "Player-1-9999" } end
    end }

    local function ticks(n)
        for _ = 1, n do
            mock.time = mock.time + 2.1
            rt6.scheduler.on_update()
        end
    end
    ticks(4)
    marker = 1                          -- you mark it with a star
    ticks(4)
    local ev = function(name, args) rt6.events.emit("jcore.game_event", name, args) end
    ev("LOOT_OPENED", { true, false })
    ev("LOOT_CLOSED", {})
    ev("UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-3-1-1-1-2366-0003", 2366 })

    local f = R6.catalog().features
    local opened = f.loot.opened[1]
    assert(opened, "the loot window is recorded")
    assert_eq(opened.items, 2, "two items")
    assert_eq(opened.contents[1].name, "Linen Cloth", "what was in it")
    assert_eq(opened.contents[2].gold, true, "and the money")
    assert_eq(opened.reads_before.get_state_flags, 4, "the corpse's reads from before it was looted")
    assert_eq(opened.npc, "251144", "which kind of mob it was")
    assert(opened.reads_after, "and after the window closed")
    assert(f.loot.reads.has_loot and f.loot.reads.has_loot["false"],
        "has_loot's answers, counted: " .. require("jcore/lib/json").encode(f.loot.reads))

    assert(f.quest.reads.is_quest_unit["true"], "is_quest_unit's answers")
    assert_eq(R6.catalog().npcs["251143"].quest_unit, true, "kept on the npc")
    assert(f.rank.reads.get_classification["0"], "classification's answers")

    local change = f.markers.changes and f.markers.changes[1]
    assert(change and change.from == 16 and change.to == 1, "the marker change is the ground truth")

    assert(f.tapped.fighting_others and f.tapped.fighting_others[1], "a mob fighting someone else")
    assert_eq(f.tapped.fighting_others[1].is_tap_denied, false, "with what is_tap_denied said")

    assert(f.nodes.objects["Peacebloom"], "a game object, by name")
    local gathered = f.nodes.gathered and f.nodes.gathered[1]
    assert(gathered and gathered.spell_name == "Herb Gathering", "a gathering cast")
    assert_eq(gathered.reads.get_name, "Peacebloom", "and the object it was on")

    assert(R6.save(), "saved")
    local data = rt6.json.decode(mock.data_fs["jcore/jcore.catalog.json"])
    assert(data.features and data.features.loot, "features in the file")
    if jtest and jtest.write_file then
        jtest.write_file("recorder/jcore.catalog.json", mock.data_fs["jcore/jcore.catalog.json"])
    end
    R6.stop()
    fail_on_errors("features")
end }

return T

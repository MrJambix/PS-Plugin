-- JCore 1.8.1 / Jambix Debug 1.1.0: every fault written on the hit, and the
-- crash black box. The user, 2026-10-11: "add to the Debug All Captures of
-- anything we running thats going Null, or Crashing us for any Error whatso
-- ever and log it on the hit so we can fix it/report it".
--
-- Booted as Forever with Jambix Debug. The data files behave as the real
-- core's do (write APPENDS, create EMPTIES); the mock's replace and keep.
-- A previous session's black box is on disk before boot: a game that died
-- in the render pass, inside the ESP's render job.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
mock.wow_fs["WTF/Config.wtf"] = 'SET textLocale "enUS"\n'

local function norm(p)
    return (tostring(p or ""):gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/"):gsub("/$", ""))
end
-- While `captured` is a table, every black box write is also put there: the
-- box files take turns, so a test reads what was written, not a file.
local captured = nil
rawset(mock.core, "write_data_file", function(path, data)
    path = norm(path)
    if mock.data_fs[path] == nil then return end
    mock.data_fs[path] = mock.data_fs[path] .. tostring(data)
    if captured and path:find("blackbox", 1, true) then captured[#captured + 1] = tostring(data) end
end)
local function capture(fn)
    captured = {}
    fn()
    local text = table.concat(captured)
    captured = nil
    return text
end
-- The CPU clock the box times its writes with: `step` ns a read, so a test
-- sets what each write costs.
local cpu = { ns = 0, step = 1000 }
rawset(mock.core, "cpu_time", function()
    cpu.ns = cpu.ns + cpu.step
    return cpu.ns
end)
-- The party roster as Forever's get_party_members hands it over.
local party = { rows = {} }
rawset(mock.core.object_manager, "get_party_members", function() return party.rows end)
rawset(mock.core, "create_data_file", function(path)
    mock.data_fs[norm(path)] = ""
    return true
end)

local LOG = "jcore/jambix.debug.faults.log"
local BOX1 = "jcore/jambix.debug.blackbox.1.txt"
local BOX2 = "jcore/jambix.debug.blackbox.2.txt"

-- The last session: loaded at 5000 s after its injection, died 247 s later
-- inside the ESP's render job. This game's clock is at 1000 s: a new game.
mock.data_fs[BOX1] = table.concat({
    "1 5000.000 S 2026-10-11 21:47:59 start=5000.000 jcore=1.8.1 game=wow_forever_us",
    "2 5001.000 C Wetlands, at 1.0, 2.0, 3.0, in combat",
    "3 5247.100 > update",
    "4 5247.110 < update",
    "5 5247.120 > render",
    "6 5247.130 > render job of jambix_aio (priority 100) at jambix_aio/modules/esp/init:120",
}, "\n") .. "\n"

-- A native the watch sees: it raises, answers, or goes nil on demand.
local probe = { raise = false, none = false }
rawset(mock.core.spell_book, "get_spell_description", function()
    if probe.raise then error("bad spell id") end
    if probe.none then return nil end
    return "A strike."
end)

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(text, needle, label)
    if not tostring(text):find(needle, 1, true) then
        error(string.format("%s: %q not found in:\n%s", label, needle, tostring(text)), 2)
    end
end

local function count(text, needle)
    local n, from = 0, 1
    while true do
        local i = tostring(text):find(needle, from, true)
        if not i then return n end
        n = n + 1
        from = i + #needle
    end
end

local function log_text() return mock.data_fs[LOG] or "" end

local JCore, ctx, F
local T = {}

T[#T + 1] = { "boot: the fault log listens, and the last session's death is written from the black box", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    F = JCore.faultlog
    assert(F and F.available, "Jambix Debug's fault log is built")
    assert_eq(JCore.faults.listening(), true, "listening on rt.faults")
    local text = log_text()
    has(text, "SESSION", "a session header")
    has(text, "CRASH  the last session ended without logging out", "the crash entry")
    has(text, "at about 21:52:06", "when it died: the load time plus the last mark")
    has(text, "Running at the end: render > render job of jambix_aio (priority 100) at jambix_aio/modules/esp/init:120",
        "what was running: the passes still open")
    has(text, "Last context: Wetlands", "the last context line")
    local p = F.previous()
    assert_eq(p.died, true, "judged dead")
    -- The new session starts in the other file, with its header.
    has(mock.data_fs[BOX2] or "", " S ", "the new box file starts with this session's header")
    assert_eq(mock.data_fs[BOX1]:find("render job of jambix_aio", 1, true) ~= nil, true, "the old file is left alone")
    ctx = JCore.register({ id = "jtest.faults", name = "Faults test", version = "1.0.0" })
end }

T[#T + 1] = { "a job that indexes a nil: one full entry on the hit, with the traceback and the locals; repeats counted", function()
    local job = ctx.tick(function()
        local row = nil
        return row.pos
    end)
    mock.frame(3)
    local text = log_text()
    assert_eq(count(text, "s] ERROR #"), 1, "one full entry for one fault")
    has(text, "update job of jtest.faults", "who: the plugin's update job")
    has(text, "jcore_faults_test:", "and where the job is defined")
    has(text, "attempt to index", "the message")
    has(text, "row=nil", "the locals of the frame that raised")
    has(text, "stack traceback", "the traceback")
    has(text, "running: update", "what was running")
    has(text, "again, x2: ERROR", "the second hit written as a repeat")
    local found = nil
    for _, row in pairs(F.rows()) do
        if row.kind == "job" then found = row end
    end
    assert(found and found.count >= 3, "counted")
    JCore.scheduler.remove(job)
end }

T[#T + 1] = { "an event handler that raises, and a warn line of a plugin's log", function()
    ctx.on("jtest.faults.boom", function(n) error("boom " .. tostring(n)) end)
    ctx.emit("jtest.faults.boom", 7)
    ctx.emit("jtest.faults.boom", 8)
    local text = log_text()
    has(text, "handler of jtest.faults.boom by jtest.faults", "who: the subscription")
    has(text, "boom 7", "the message")
    assert_eq(count(text, "boom 8"), 1, "a repeat differing only in a number is the same fault: written as again x2")
    ctx.log.warn("the vendor list is missing")
    has(log_text(), "LOG #", "a log line")
    has(log_text(), "log [Faults test] warn", "with its tag and level")
    has(log_text(), "the vendor list is missing", "and its text")
end }

T[#T + 1] = { "the native watch: a raise swallowed by the caller's pcall, and a value gone nil, once per call site", function()
    probe.raise = true
    local ok = pcall(core.spell_book.get_spell_description, 1757)
    assert_eq(ok, false, "the caller still sees the raise")
    probe.raise = false
    has(log_text(), "NATIVE #", "the raise is logged though it was swallowed")
    has(log_text(), "spell_book.get_spell_description called by", "with the function and the site")
    has(log_text(), "bad spell id", "and the message")
    assert_eq(core.spell_book.get_spell_description(1757), "A strike.", "it answers")
    probe.none = true
    for _ = 1, 5 do assert_eq(core.spell_book.get_spell_description(1757), nil, "now nil") end
    probe.none = false
    assert_eq(count(log_text(), "NULL #"), 1, "nil after a value: one entry for one call site")
    has(log_text(), "answered nil after answering values before", "said so")
    local st = F.stats()
    assert(st.native_raised >= 1 and st.native_nulls >= 5, "the watch counts every raise and nil")
end }

T[#T + 1] = { "what cache.try swallows", function()
    assert_eq(JCore.cache.try(function() error("lua boom in a try") end), nil, "still swallowed")
    has(log_text(), "SWALLOWED #", "and logged")
    has(log_text(), "lua boom in a try", "with its message")
end }

T[#T + 1] = { "the black box: each pass written ahead, a context line a second; every job at the deep level", function()
    mock.frame(70)
    local box = mock.data_fs[BOX2] or ""
    has(box, " > update", "the update pass begins")
    has(box, " < update", "and ends")
    has(box, " > render", "the render pass")
    has(box, " C ", "a context line")
    assert_eq(JCore.faults.deep, false, "jobs are not marked at 'every pass'")
    F.set_level(4)
    assert_eq(JCore.faults.deep, true, "the deep level marks every job")
    mock.frame(1)
    has(mock.data_fs[BOX2], "job of jcore", "a core job's mark")
    has(mock.data_fs[BOX2], "stage units", "a core stage's mark")
    F.set_level(3)
    assert_eq(JCore.faults.deep, false, "back to every pass")
end }

T[#T + 1] = { "judging the last session: logged out, reloaded in the same game, died with nested passes", function()
    local function L(seq, t, text) return { seq = seq, t = t, text = text } end
    local head = L(1, 100, "S 2026-10-11 10:00:00 start=100.000 jcore=1.8.1 game=x")
    local out = F._judge_previous({ head, L(2, 150, "> update"), L(3, 150.1, "< update"), L(4, 151, "X logged out") }, 10)
    assert_eq(out.logged_out, true, "logged out")
    assert_eq(out.died, false, "not a death")
    out = F._judge_previous({ head, L(2, 150, "> update"), L(3, 150.1, "< update") }, 400)
    assert_eq(out.reloaded, true, "the clock went on: the same game, scripts reloaded")
    assert_eq(out.died, false, "not a death")
    out = F._judge_previous({ head, L(2, 150, "> update"), L(3, 150.1, "< update"), L(4, 150.2, "> render"),
        L(5, 150.3, "> spell_cast"), L(6, 150.4, "< spell_cast") }, 10)
    assert_eq(out.died, true, "the clock went back: a new game")
    assert_eq(table.concat(out.open, " > "), "render", "the spell-cast callback ended; render had not")
    assert_eq(out.died_at, "10:00:50", "the time of death")
    out = F._judge_previous({ head, L(2, 150, "> render"), L(3, 150.1, "> render job"), L(4, 151, "> update") }, 10)
    assert_eq(table.concat(out.open, " > "), "update", "a new update closes what was left open")
    assert_eq(F._judge_previous({}, 10), nil, "no box, nothing to say")
end }

T[#T + 1] = { "catching off: nothing new is written; on again: written", function()
    F.set_catch(false)
    local before = log_text()
    ctx.emit("jtest.faults.boom", 9)
    JCore.cache.try(function() error("quiet boom") end)
    assert_eq(log_text(), before, "nothing written while off")
    F.set_catch(true)
    JCore.cache.try(function() error("loud boom") end)
    has(log_text(), "loud boom", "written once on again")
end }

T[#T + 1] = { "the summary file lists every fault by count", function()
    assert_eq(F.write_summary(true), true, "written")
    local s = mock.data_fs["jcore/jambix.debug.faults.summary.txt"] or ""
    has(s, "Jambix Debug fault summary", "a title")
    has(s, "ERROR", "the job's fault")
    has(s, "The native watch", "the watch's totals")
    local st = F.stats()
    assert(st.faults > 0 and st.distinct > 0, "stats count them")
    assert_eq(st.level, "pass", "the box level")
end }

T[#T + 1] = { "a pass with no job in it (pre_tick) is not marked; with a job it is", function()
    local text = capture(function() mock.frame(2) end)
    has(text, " > update", "update is marked")
    has(text, " < window", "and the window pass")
    assert_eq(text:find("pre_tick", 1, true), nil, "pre_tick, with no job, is not")
    local job = ctx.pre_tick(function() end)
    text = capture(function() mock.frame(1) end)
    has(text, " > pre_tick", "with a job it is marked")
    has(text, " < pre_tick", "and closed")
    JCore.scheduler.remove(job)
    text = capture(function() mock.frame(1) end)
    assert_eq(text:find("pre_tick", 1, true), nil, "the job gone, no mark again")
end }

T[#T + 1] = { "alone over budget it steps down; in a group it goes back up and holds on the doubled budget", function()
    -- A write costs 0.25 ms: six marks a frame at 60 frames a second is 90 ms
    -- a second, over the 60 allowed alone, under the 120 in a group.
    cpu.step = 250000
    mock.frame(60 * 6)
    assert_eq(select(2, F.level()), "second", "alone: stepped down")
    has(log_text(), "now second", "and said so")
    party.rows = { { name = "Bhen", guid = "Player-4619-0000001", role = "DAMAGER", class_file = "PRIEST" } }
    local text = capture(function() mock.frame(60 * 2) end)
    assert_eq(select(2, F.level()), "pass", "in a group: back to the page's level")
    has(log_text(), "black box: in a group; back to pass", "and said so")
    has(text, "in a group", "the context line says so")
    text = capture(function() mock.frame(60 * 6) end)
    assert_eq(select(2, F.level()), "pass", "held at 90 ms a second")
    has(text, " > update", "and still marking the passes")
    assert_eq(F.stats().box_company, true, "in company")
    -- Over the doubled budget too: down, and not straight back up again.
    cpu.step = 500000
    mock.frame(60 * 6)
    assert_eq(select(2, F.level()), "second", "over 120 a second: down, even in a group")
    party.rows = {}
    cpu.step = 1000
    F.set_level(3)
    mock.frame(60 * 2)
    assert_eq(select(2, F.level()), "pass", "the page's level again")
    assert_eq(F.stats().box_company, false, "alone")
end }

T[#T + 1] = { "the page at 'job': on the way into a group the box goes back up to 'pass', no higher", function()
    F.set_level(4)
    cpu.step = 250000
    mock.frame(60 * 10)
    assert_eq(select(2, F.level()), "second", "alone, over budget: down from job, then from pass")
    party.rows = { { name = "Bhen", guid = "Player-4619-0000001", role = "DAMAGER", class_file = "PRIEST" } }
    mock.frame(60 * 2)
    assert_eq(select(2, F.level()), "pass", "back to pass, not job")
    has(log_text(), "black box: in a group; back to pass", "and said so")
    party.rows = {}
    cpu.step = 1000
    F.set_level(3)
    mock.frame(60 * 2)
end }

T[#T + 1] = { "a death after the box stepped down says the pass is not known, not 'between passes'", function()
    local function L(seq, t, text) return { seq = seq, t = t, text = text } end
    local head = L(1, 100, "S 2026-10-12 14:00:00 start=100.000 jcore=1.8.1 game=x")
    local out = F._judge_previous({ head, L(2, 150, "> update"), L(3, 150.1, "> render"), L(4, 151, "L second"),
        L(5, 152, "C Shadowfang Keep, dungeon, in a group") }, 10)
    assert_eq(out.died, true, "a new game")
    assert_eq(out.box_level, "second", "the box's level at the end")
    assert_eq(#out.open, 0, "nothing left open past the step down")
    has(F._running_at_end(out), "not known -- the black box was at 'second'", "said so")
    out = F._judge_previous({ head, L(2, 150, "L second"), L(3, 151, "L pass"), L(4, 152, "> update"),
        L(5, 152.1, "< update") }, 10)
    assert_eq(out.box_level, "pass", "back at 'pass'")
    has(F._running_at_end(out), "between passes", "so between passes it is")
    out = F._judge_previous({ head, L(2, 150, "> update"), L(3, 150.1, "< update") }, 10)
    assert_eq(out.box_level, "pass", "no 'L' line: the default")
end }

return T

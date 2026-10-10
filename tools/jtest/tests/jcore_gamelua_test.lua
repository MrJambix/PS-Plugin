-- JCore 1.5.16: services/gamelua -- the bridge to the game's own Lua through
-- the loader's undocumented core.execute and core.read_lua_*.
--
-- Nothing about those calls is known, so the service probes them before it
-- uses them. These tests stand a fake "game Lua state" behind the five calls
-- and drive the probe and the runs through every shape the real loader might
-- turn out to have: execute applied at once or a frame later, reads that only
-- know strings, reads that cut a string short, an execute that runs in the
-- loader's own Lua, one that raises, and one whose effect never shows. Era
-- builds nothing at all.
--
-- The service is built on its own (tools/jtest/mock/gamelua_fake.lua), with
-- stand-ins for the parts of the runtime it uses.

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local fake = require("mock/gamelua_fake")
local game, build = fake.game, fake.build

local T = {}

T[#T + 1] = { "Era: inert -- no job, no execute, run refuses", function()
    local W = game()
    local R = build(W, false)
    assert_eq(#R.jobs, 0, "no scheduler job")
    assert_eq(R.M.state(), "off", "off")
    assert_eq(R.M.run("x", "out(1)", function() end), false, "run refuses")
    R.run(10)
    assert_eq(W.executed, 0, "nothing executed")
end }

T[#T + 1] = { "Forever: the probe finds a working bridge, then the census is taken and saved", function()
    local W = game({ mode = "deferred",
        globals = { C_QuestLog = { GetQuestObjectives = function() return {} end } } })
    local R = build(W, true)
    assert_eq(#R.jobs, 1, "one job")
    R.run(4)
    assert_eq(W.executed, 0, "nothing before the world has had five seconds")
    R.run(1.5)
    assert_eq(R.M.state(), "ready", "ready: " .. tostring(select(2, R.M.state())))
    local st = R.M.stats()
    assert_eq(st.int_reads, true, "integer reads work")
    assert_eq(st.chunk, 3800, "a 4,000-character read came back whole")
    assert(st.latency and st.latency > 0 and st.latency < 0.5, "the answer took a frame: " .. tostring(st.latency))
    local a = R.M.report().attempts[1]
    assert(a.before.globalstring:find("slain", 1, true), "reads reach game globals: " .. a.before.globalstring)
    assert_eq(a.ran_in_loader, false, "not the loader's Lua")
    assert(a.table_str_key:find("tbl", 1, true), "table reads by key: " .. a.table_str_key)
    R.run(0.3)
    local census = R.M.report().census
    assert(census, "census taken")
    assert_eq(census["C_QuestLog"], "table", "C_QuestLog seen")
    assert_eq(census["C_QuestLog.GetQuestObjectives"], "function", "a function seen")
    assert_eq(census["C_QuestLog.GetInfo"], "nil", "a missing one said so")
    assert_eq(census.build, "1.60.1 70205 16001", "the build")
    assert(R.files["jcore/jcore.gamelua.json"], "the report is written")
    assert(R.traced_has("gamelua: ready"), "the trace says ready")
    assert(R.traced_has("missing: C_QuestLog.GetNumQuestLogEntries"), "and what is missing")
end }

T[#T + 1] = { "runs: an answer comes back whole, in pieces, an error as an error, one at a time per slot", function()
    local W = game({ mode = "deferred", max_read = 300 })
    local R = build(W, true)
    R.run(5.5)
    assert_eq(R.M.state(), "ready", "ready")
    assert_eq(R.M.stats().chunk, 284, "pieces as long as one read returns, less a margin")

    local got, why = nil, nil
    assert_eq(R.M.run("q", "out('a') out('b')", function(t, w) got, why = t, w end), true, "sent")
    assert_eq(R.M.run("q", "out('c')", function() end), false, "the slot is busy")
    R.run(0.2)
    assert_eq(got, "a\nb", "the lines")

    got = nil
    R.M.run("q", "for i = 1, 100 do out(string.rep(string.char(64 + i % 26), 9)) end", function(t) got = t end)
    R.run(0.2)
    assert(got, "a long answer")
    assert_eq(#got, 100 * 9 + 99, "reassembled from pieces")
    assert_eq(got:sub(1, 9), "AAAAAAAAA", "in order")

    got, why = "x", nil
    R.M.run("q", "error('no such quest')", function(t, w) got, why = t, w end)
    R.run(0.2)
    assert_eq(got, nil, "no text")
    assert(why and why:find("no such quest", 1, true), "the game's error: " .. tostring(why))
end }

T[#T + 1] = { "a loader whose read_lua_integer does not work: numbers are read as strings", function()
    local W = game({ int_reads = false })
    local R = build(W, true)
    R.run(5.5)
    assert_eq(R.M.state(), "ready", "ready")
    assert_eq(R.M.stats().int_reads, false, "integer reads off")
    local got = nil
    R.M.run("s", "out('ok')", function(t) got = t end)
    R.run(0.1)
    assert_eq(got, "ok", "the run still completes")
end }

T[#T + 1] = { "execute in the loader's own Lua is no bridge: refused, and said so", function()
    local W = game({ mode = "loader" })
    local R = build(W, true)
    R.run(5.5)
    local state, reason = R.M.state()
    assert_eq(state, "retry", "tried again later")
    assert(reason:find("loader's own Lua", 1, true), "why: " .. tostring(reason))
    rawset(_G, "JCORE_GL_PING", nil)
    rawset(_G, "JCORE_GL_PINGI", nil)
    rawset(_G, "JCORE_GL_PINGT", nil)
    rawset(_G, "JCORE_GL_LONG", nil)
end }

T[#T + 1] = { "an execute whose effect never shows: three tries, twenty seconds apart, then off", function()
    local W = game({ mode = "void" })
    local R = build(W, true)
    R.run(5.5)
    R.run(3.2)
    assert_eq(R.M.state(), "retry", "first failure")
    R.run(20.2)
    R.run(3.2)
    assert_eq(R.M.state(), "retry", "second failure")
    R.run(20.2)
    R.run(3.2)
    local state, reason = R.M.state()
    assert_eq(state, "failed", "off for the session")
    assert(reason:find("never read back", 1, true), "why: " .. tostring(reason))
    assert_eq(#R.M.report().attempts, 3, "three attempts recorded")
    assert_eq(R.M.run("q", "out(1)", function() end), false, "runs refused")
    assert(R.traced_has("off for this session"), "the trace says so")
end }

-- 1.8.3: every Forever session since 2026-10-03 printed three failed probes.
local LAST_FAILED = { ["jcore/jcore.gamelua.json"] = {
    client = "Forever", state = "failed", reason = "the string set by execute never read back (\"\")",
} }

local function console_lines(R, needle)
    local n = 0
    for i = 1, #R.logs do
        local line = R.logs[i]
        if (line:sub(1, 6) == "info: " or line:sub(1, 6) == "warn: ") and line:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

T[#T + 1] = { "failed last session too: one probe, kept out of the console, still in the trace", function()
    local W = game({ mode = "void" })
    local R = build(W, true, LAST_FAILED)
    R.run(5.5)
    R.run(3.2)
    local state, reason = R.M.state()
    assert_eq(state, "failed", "off after one try")
    assert(reason:find("never read back", 1, true), "why: " .. tostring(reason))
    R.run(25)
    assert_eq(#R.M.report().attempts, 1, "no second attempt")
    assert_eq(console_lines(R, "probe"), 0, "no probe lines at info")
    assert_eq(console_lines(R, "off for this session"), 0, "no 'off' line at info")
    assert(R.traced_has("off for this session, as last session"), "the trace still says so")
    assert_eq(R.files["jcore/jcore.gamelua.json"].state, "failed", "and the file still says failed")
end }

T[#T + 1] = { "failed last session, but the loader answers now: announced as ever", function()
    local W = game({ mode = "deferred" })
    local R = build(W, true, LAST_FAILED)
    R.run(5.5)
    assert_eq(R.M.state(), "ready", "ready")
    assert_eq(console_lines(R, "ready: execute reaches"), 1, "said at info")
end }

T[#T + 1] = { "failed last session: the debug page's probe again is the full three, aloud", function()
    local W = game({ mode = "void" })
    local R = build(W, true, LAST_FAILED)
    R.run(9)
    assert_eq(R.M.state(), "failed", "the quiet try failed")
    R.M.probe_now()
    R.run(3.4)
    assert_eq(R.M.state(), "retry", "a second try is coming")
    assert_eq(console_lines(R, "probe 1 of 3 failed"), 1, "said at info, out of three")
end }

T[#T + 1] = { "an execute that raises: refused with the error, never a raise of ours", function()
    local W = game({ mode = "raise" })
    local R = build(W, true)
    R.run(5.5)
    local _, reason = R.M.state()
    assert(reason and reason:find("not allowed", 1, true), "why: " .. tostring(reason))
end }

return T

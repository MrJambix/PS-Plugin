-- JCore / gamelua -- OFF on every client since 1.8.1: nothing is sent to the
-- game's Lua.
--
-- WHAT IT WAS (JCore 1.5.16 to 1.8.0). A bridge to the game's own Lua through
-- the loader's undocumented core.execute and core.read_lua_string /
-- read_lua_integer / read_lua_table_*. Each Forever session it probed the
-- bridge: one chunk sent into the game's Lua state, setting JCORE_GL_*
-- globals, then read back every 0.05 s for three seconds. On success it also
-- ran Jambix AIO's quest-log bodies (esp/forever_quests). It never answered
-- on Forever: every session's probe failed, from 2026-10-03 on
-- (scripts_data/jcore/jcore.gamelua.json, "the string set by execute never
-- read back"). The implementation is in git history, before 1.8.1.
--
-- WHY IT IS OFF (2026-10-12). The user: "if its not in the .api remove it
-- from game calls". None of those five calls is in scripts/.api, and the
-- API check (tools/jcheck/api_usage.js) found them the only undocumented
-- natives the rotation, the ESP or JCore still called in game. The bridge
-- was also the only code of ours that ran anything inside the game's Lua.
--
-- WHAT STAYS. The interface, so a caller keeps working: state() is "off"
-- with the reason, ready() is false, run() sends nothing and answers false,
-- probe_now() does nothing. esp/forever_quests already reads the quest log
-- from core.quests when the bridge is down (AIO 1.82.0). No job, no file,
-- no native.

local REASON = "off: core.execute and core.read_lua_* are not in scripts/.api (JCore 1.8.1)"

return function(rt)
    local M = {}

    function M.state() return "off", REASON end
    function M.ready() return false end
    function M.report() return { state = "off", reason = REASON } end
    function M.stats()
        return {
            state = "off", reason = REASON, chunk = 0, int_reads = false, latency = nil,
            runs = 0, answers = 0, errors = 0, timeouts = 0, busy = 0, pieces = 0,
        }
    end
    function M.run() return false end
    function M.probe_now() return false end

    return M
end

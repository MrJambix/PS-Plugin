-- JCore 1.8.1: services/gamelua is OFF on every client. Its bridge to the
-- game's own Lua went through the loader's core.execute and core.read_lua_*,
-- none of which is in scripts/.api. The user, 2026-10-12: "if its not in the
-- .api remove it from game calls". (Before 1.8.1 these tests drove the probe
-- through every shape the loader might have; that code is in git history.)
--
-- The service is built on its own against the fake game in
-- tools/jtest/mock/gamelua_fake.lua -- a bridge that WOULD answer -- and
-- every one of the five calls is counted: none may be made.

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local fake = require("mock/gamelua_fake")
local game, build = fake.game, fake.build

--- The fake game, with every bridge call counted.
local function counted_game()
    local W = game()
    W.calls = 0
    for _, name in ipairs({ "execute", "read_lua_string", "read_lua_integer",
        "read_lua_table_string", "read_lua_table_integer" }) do
        local real = W.core[name]
        W.core[name] = function(...)
            W.calls = W.calls + 1
            return real(...)
        end
    end
    return W
end

local T = {}

for _, forever in ipairs({ false, true }) do
    local client = forever and "Forever" or "Era"
    T[#T + 1] = { client .. ": off -- no job, no file, not one call to execute or read_lua_*", function()
        local W = counted_game()
        local R = build(W, forever)
        assert_eq(#R.jobs, 0, "no scheduler job")
        local state, why = R.M.state()
        assert_eq(state, "off", "off")
        assert(tostring(why):find(".api", 1, true), "and why: " .. tostring(why))
        assert_eq(R.M.ready(), false, "never ready")
        local answered = false
        assert_eq(R.M.run("aio_ql", "out(1)", function() answered = true end), false, "run sends nothing")
        assert_eq(R.M.probe_now(), false, "probe_now does nothing")
        R.run(30)
        assert_eq(W.calls, 0, "no execute, no read_lua_*")
        assert_eq(W.executed, 0, "nothing executed in the game")
        assert_eq(answered, false, "no answer ever comes")
        assert_eq(next(R.files), nil, "no file written")
        assert_eq(R.M.stats().state, "off", "the stats say off")
    end }
end

return T

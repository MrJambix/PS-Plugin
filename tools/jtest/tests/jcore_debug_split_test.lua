-- JCore 1.7.0 / Jambix Debug 1.0.0: the debug tools are their own plugin.
-- JCore booted as Forever WITHOUT scripts/jambix_debug: no recorder, no loot
-- study, no Dump page, world.client().recording false. Then the plugin runs
-- after JCore and attaches itself: the recorder, the study and the Dump page
-- are built late, the recording flag turns on, and a second attach does
-- nothing.
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

-- Not installed: neither the global nor either require path finds it.
_G.JambixDebug = nil
local function absent(name) error("module '" .. tostring(name) .. "' not found") end
package.preload["jambix_debug/main"] = absent
package.preload["../jambix_debug/main"] = absent

local JCore, ctx
local T = {}

T[#T + 1] = { "without Jambix Debug: no recorder, no loot study, no Dump page, recording false", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    mock.frame(3)
    ctx = JCore.register({ id = "jtest.split", name = "Split test", version = "1.0.0" })
    assert_eq(JCore.dump, nil, "no Dump service")
    assert_eq(ctx.dump, nil, "none handed to plugins")
    assert_eq(ctx.world.client().forever, true, "on Forever")
    assert_eq(ctx.world.client().recording, false, "nothing records, so the AIO builds no trace lines")
    assert_eq(#mock.errors, 0, "no core.log_error")
end }

T[#T + 1] = { "Jambix Debug running after JCore attaches: recorder, study and Dump built late", function()
    package.preload["jambix_debug/main"] = nil
    package.preload["../jambix_debug/main"] = nil
    package.loaded["jambix_debug/main"] = nil
    local D = require("jambix_debug/main")
    assert(type(D) == "table" and _G.JambixDebug == D, "the plugin publishes itself")
    assert(JCore.dump and JCore.dump.dump, "the Dump service, built late")
    assert_eq(ctx.world.client().recording, true, "the recorder runs, and the flag on the same table says so")
    assert_eq(JCore.attach_debug(D), false, "a second attach does nothing")
    mock.frame(2)
    assert_eq(#mock.errors, 0, "no core.log_error")
end }

return T

-- JCore's sight guard elsewhere (1.8.0): only Forever's client asserts inside
-- its own line-of-sight ray, so every other client keeps the native as it is.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
mock.game_version = "Classic"
mock.exact_game_version = "wow_classic_era"

local native = { calls = 0 }
local function native_los()
    native.calls = native.calls + 1
    return true
end
rawset(mock.core.graphics, "is_line_of_sight", native_los)

local helper = {}
local function helper_los() return true end
helper.is_spell_in_line_of_sight = helper_los
package.loaded["common/utility/spell_helper"] = helper

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}

T[#T + 1] = { "boot as Era: the native and spell_helper are left alone", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    local JCore = _G.JCore
    assert(JCore and JCore.sightguard, "JCore.sightguard")
    mock.frame(5)
    assert_eq(JCore.sightguard.stats().installed, false, "not installed")
    assert(mock.core.graphics.is_line_of_sight == native_los, "the native is still the native")
    assert(helper.is_spell_in_line_of_sight == helper_los, "spell_helper untouched")
    assert_eq(core.graphics.is_line_of_sight({}, {}), true, "and it answers")
    assert_eq(native.calls, 1, "the client's own ray")
    if #mock.errors > 0 then error("core.log_error was called:\n" .. mock.error_text()) end
end }

return T

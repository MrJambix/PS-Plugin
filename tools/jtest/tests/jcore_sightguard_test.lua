-- JCore's sight guard on Forever (1.8.0): core.graphics.is_line_of_sight is
-- replaced in place for every package, so a library JCore does not own -- the
-- loader's spell queue, asked during a key press at 18:15 on 2026-10-11 --
-- gets the model-free ray instead of the client's, which asserts in
-- M2HitTest.cpp on build 70338. This file plays that library: it calls the
-- shared function and the loader's spell_helper directly.
--
-- The tests run in ORDER inside one Lua state.

local mock = require("mock_core")
mock.install()
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

-- The client's own ray, counted: nothing may reach it once JCore is up.
local native = { calls = 0 }
rawset(mock.core.graphics, "is_line_of_sight", function()
    native.calls = native.calls + 1
    return true
end)

-- The loader's spell_helper, with its own line-of-sight check (which would
-- ask the native) and the castable check JCore's Forever path never asks.
local helper = { native = 0 }
function helper.is_spell_in_line_of_sight(self)
    self.native = self.native + 1
    return true
end
function helper.is_spell_castable() return false end
package.loaded["common/utility/spell_helper"] = helper

-- trace_line as Forever answers it: true is a hit. Down through the feet
-- hits the ground, straight up hits nothing (the calibration), and a ray
-- between two units hits while `rays.blocked`.
local rays = { count = 0 }
rawset(mock.core.graphics, "trace_line", function(a, b)
    if b.z < a.z - 1 then return true end
    if b.z > a.z and a.x == b.x and a.y == b.y then return false end
    rays.count = rays.count + 1
    return rays.blocked == true
end)

local function unit_of(answers, pos)
    return setmetatable({}, { __index = function(_, key)
        if key == "get_position" then return function() return pos end end
        local v = answers[key]
        return function() return v end
    end })
end
local me = unit_of({ is_valid = true, is_dead = false, get_guid = "Player-1-0002", get_combat_reach = 1.5,
                     is_channelling_spell = false, is_casting_spell = false }, { x = 0, y = 0, z = 0 })
local mob = unit_of({ is_valid = true, is_dead = false, get_guid = "Creature-0-1-0-0-1054-00004BD9C3",
                      get_combat_reach = 1.5 }, { x = 12, y = 0, z = 0 })
rawset(mock.core.object_manager, "get_local_player", function() return me end)

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

local JCore

local T = {}

T[#T + 1] = { "boot as Forever: is_line_of_sight is replaced for everyone, spell_helper's too", function()
    local ok, err = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(err)) end
    JCore = _G.JCore
    assert(JCore and JCore.sightguard, "JCore.sightguard")
    mock.frame(5)
    local s = JCore.sightguard.stats()
    assert_eq(s.installed, true, "installed")
    assert_eq(s.helper, true, "spell_helper's is_spell_in_line_of_sight replaced too")
    assert(mock.core.graphics.is_line_of_sight ~= JCore.sightguard.native, "the shared function is not the native")
    assert_eq(native.calls, 0, "booting asked nothing")
    fail_on_errors("boot")
end }

T[#T + 1] = { "by default (1.8.1) Forever casts no ray at all: unknown, so in sight, and trace_line is never called", function()
    -- The four report-less crashes of 2026-10-11 began after this ray came in.
    assert_eq(JCore.geometry.sight_stats().forever_rays, false, "off by default")
    mock.frame(15)
    assert_eq(JCore.geometry.sight(me, mob), nil, "geometry.sight: unknown")
    assert_eq(core.graphics.is_line_of_sight(me, mob), true, "the shared function: in sight, the server judges")
    assert_eq(helper:is_spell_in_line_of_sight(3044, me, mob), true, "spell_helper too")
    assert_eq(JCore.geometry.line_of_sight(me, mob), true, "geometry.line_of_sight lets the client judge")
    assert_eq(rays.count, 0, "trace_line was never called")
    assert_eq(JCore.geometry.sight_stats().rays, 0, "no ray counted, not even the calibration")
    assert_eq(native.calls, 0, "nor the client's ray")
    JCore.geometry.set_forever_rays(true)   -- the tests below are about the ray
    fail_on_errors("no rays")
end }

T[#T + 1] = { "a library asking the shared function gets the model-free ray, never the client's", function()
    -- What the loader's packed Lua did inside UseAction: it looks the
    -- function up on `core` when it asks.
    local before = JCore.sightguard.stats().calls
    local los = core.graphics.is_line_of_sight
    assert_eq(los(me, mob), true, "clear: in sight")
    assert_eq(rays.count, 1, "one model-free ray")
    rays.blocked = true
    assert_eq(los(me, mob), true, "the same fifth of a second keeps the answer")
    mock.frame(15)
    assert_eq(los(me, mob), false, "behind a wall: not in sight")
    assert_eq(rays.count, 2, "one more ray")
    rays.blocked = false
    assert_eq(native.calls, 0, "the client's is_line_of_sight was never asked")
    local s = JCore.sightguard.stats()
    assert_eq(s.calls - before, 3, "three asks counted")
    local found, seen = nil, {}
    for where, n in pairs(s.callers) do
        seen[#seen + 1] = where .. "=" .. n
        if where:find("sightguard_test", 1, true) then found = where end
    end
    assert(found, "the asker's file:line is kept; kept: " .. table.concat(seen, ", "))
    fail_on_errors("shared function")
end }

T[#T + 1] = { "spell_helper:is_spell_in_line_of_sight answers by the same ray", function()
    mock.frame(15)
    assert_eq(helper:is_spell_in_line_of_sight(3044, me, mob), true, "clear")
    rays.blocked = true
    mock.frame(15)
    assert_eq(helper:is_spell_in_line_of_sight(3044, me, mob), false, "blocked")
    rays.blocked = false
    assert_eq(helper.native, 0, "the helper's own check was not run")
    assert_eq(native.calls, 0, "nor the client's ray")
    fail_on_errors("spell_helper")
end }

T[#T + 1] = { "no answer from the ray, or nothing to ask about: in sight, still never the native", function()
    rawset(mock.core.graphics, "trace_line", function() return nil end)
    mock.frame(15)
    assert_eq(core.graphics.is_line_of_sight(me, mob), true, "unknown: the server judges the cast")
    assert_eq(core.graphics.is_line_of_sight(nil, mob), true, "no caster")
    assert_eq(core.graphics.is_line_of_sight(me, nil), true, "no target")
    assert_eq(native.calls, 0, "never the native")
    fail_on_errors("unknown")
end }

T[#T + 1] = { "JCore's own Forever checks still use geometry, and the diagnostics list the guard", function()
    rawset(mock.core.graphics, "trace_line", function(a, b)
        if b.z < a.z - 1 then return true end
        if b.z > a.z and a.x == b.x and a.y == b.y then return false end
        rays.count = rays.count + 1
        return rays.blocked == true
    end)
    JCore.geometry._reset_sight()
    mock.frame(15)
    assert_eq(JCore.geometry.line_of_sight(me, mob), true, "geometry.line_of_sight")
    assert_eq(native.calls, 0, "never the native")
    local d = JCore.diagnostics()
    assert(d.sightguard and d.sightguard.installed == true, "the guard on the diagnostics page")
    fail_on_errors("geometry")
end }

return T

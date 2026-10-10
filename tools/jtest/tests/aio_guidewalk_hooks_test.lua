-- Jambix AIO 1.7.4: where the guide walk (modules/guidewalk.lua) meets the
-- rest of the plugin, on the whole plugin booted as Era:
--   * the rotation may open on the mob the walk is pulling, and only on it
--     (rotation.may_engage_unit asks guidewalk.pulling); targeting's side is
--     aio_guidewalk_test's, on a hand-built bundle (this mock has no player);
--   * the walk is loaded, its switch is on the Quests page, off, and frames
--     run clean with it on.

local boot = require("mock/aio_boot")

local T = {}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local b

local function mob(guid)
    local m = { guid = guid }
    m.is_valid = function() return true end
    m.is_dead = function() return false end
    m.get_guid = function(self) return self.guid end
    return m
end

T[#T + 1] = { "the plugin boots with the guide walk loaded and its switch off", function()
    b = boot.run("Classic", "wow_classic_era_us")
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert(b.P.guidewalk and b.P.guidewalk.pulling and b.P.guidewalk.pull_target, "the walk is on the bundle")
    assert_eq(b.P.opt("rxp_follow", nil), false, "off by default")
    local values = b.mock.menu.values["Jambix AIO/Quests"]
    assert(values and values.rxp_follow ~= nil, "declared on the Quests page")
    assert_eq(b.P.guidewalk.status(), "off", "says off")
end }

T[#T + 1] = { "the rotation may open on the mob the walk is pulling, and only on it", function()
    local wanted, other = mob("Creature-WANTED"), mob("Creature-OTHER")
    local real = b.P.guidewalk
    b.P.guidewalk = {
        pulling = function(target) return target == wanted end,
        pull_target = function() return nil end,
    }
    local ok_w, yes_w = pcall(b.P.rotation.may_engage_unit, wanted)
    local ok_o, yes_o = pcall(b.P.rotation.may_engage_unit, other)
    b.P.guidewalk = real
    assert(ok_w, tostring(yes_w))
    assert(ok_o, tostring(yes_o))
    assert_eq(yes_w, true, "the walk's mob")
    assert_eq(yes_o, false, "any other mob: selecting is not attacking")
end }

T[#T + 1] = { "the Quests page's lines, and frames run clean with the walk on", function()
    local lines = b.P.guidewalk.status_lines()
    assert_eq(#lines, 3, "three lines")
    assert(lines[2]:find("Sentinel Navigation", 1, true), lines[2])
    b.mock.menu:set("Jambix AIO/Quests", "rxp_follow", true)
    b.P.opt_invalidate()
    b.mock.frame(30)
    assert_eq(b.errors(), "", "core.log_error while running with the walk on")
    -- Switched on it runs; this mock has no player, so it waits and moves nothing.
    assert_eq(b.P.guidewalk.status(), "loading", "running, waiting for a player")
end }

return T

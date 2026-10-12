-- Jambix AIO 1.64.0: "Show advanced settings", the menu's Simple/Advanced
-- split. The whole plugin booted as Era. Off by default: the fine tuning is
-- hidden (a Performance section, an alert's cooldown slider, the look and
-- placement rows, the class sections that live in the class window), the
-- basics are not. On: all of it shows. Hidden is not off: a hidden setting
-- still reads as set.
local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}
local b

local function section(page, title)
    local p = b.mock.menu.pages["Jambix AIO/" .. page]
    assert(p, "page " .. page)
    for _, s in ipairs(p.sections) do
        if s.title == title then return s end
    end
    error("no section " .. title .. " on " .. page)
end

local function section_shown(page, title)
    local s = section(page, title)
    local v = s.opts and s.opts.visible
    if v == nil then return true end
    if type(v) == "function" then return v() == true end
    return v == true
end

local function set(page, id, value)
    b.mock.menu:set("Jambix AIO/" .. page, id, value)
    b.P.opt_invalidate()
end

T[#T + 1] = { "boots clean as Era, with advanced settings off", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.opt("show_advanced", nil), false, "declared on the Overview page, off")
    assert_eq(b.P.advanced(), false, "P.advanced")
end }

T[#T + 1] = { "simple: the fine tuning is hidden, the basics are not, and every value still reads", function()
    assert_eq(section_shown("ESP", "Performance"), false, "the Performance section")
    assert_eq(section_shown("ESP", "Look and placement"), false, "the look and placement rows")
    assert_eq(section_shown("ESP", "Elements"), true, "the elements most players change")
    assert_eq(section_shown("Automation", "Safety checks"), false, "the safety checks")
    -- 1.8.0: the reactions' switches are the Reactions page's, shown plainly.
    assert_eq(b.mock.menu:visible("Jambix AIO/Reactions", "react_overlay"), true, "the reactions' decision switches")
    assert_eq(b.mock.menu:visible("Jambix AIO/ESP", "alert_cooldown"), false, "an alert's cooldown slider")
    assert_eq(b.mock.menu:visible("Jambix AIO/ESP", "show_raid_marker"), false, "an advanced element")
    assert_eq(b.mock.menu:visible("Jambix AIO/ESP", "show_distance"), true, "distance stays")
    assert_eq(b.mock.menu:visible("Jambix AIO/ESP", "alerts_on"), true, "the alerts switch stays")
    assert_eq(b.mock.menu:visible("Jambix AIO/Fishing", "fish_reaction"), false, "fishing timing")
    assert_eq(b.mock.menu:visible("Jambix AIO/Fishing", "fish_enabled"), true, "fishing itself")
    assert_eq(b.P.opt("alert_cooldown", nil), 15, "hidden, still read as set")
end }

T[#T + 1] = { "advanced: all of it shows", function()
    -- The Overview page has no sub path.
    b.mock.menu:set("Jambix AIO", "show_advanced", true)
    b.P.opt_invalidate()
    assert_eq(b.P.advanced(), true, "on")
    assert_eq(section_shown("ESP", "Performance"), true, "Performance")
    assert_eq(section_shown("ESP", "Look and placement"), true, "look and placement")
    assert_eq(b.mock.menu:visible("Jambix AIO/ESP", "alert_cooldown"), true, "the cooldown slider")
    assert_eq(b.mock.menu:visible("Jambix AIO/Fishing", "fish_reaction"), true, "fishing timing")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

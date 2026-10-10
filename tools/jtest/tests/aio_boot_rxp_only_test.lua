-- Jambix AIO 1.61.0: "RestedXP guide only", the one switch players asked for.
-- The whole plugin booted as Era. While it is on, the overlay's master and
-- the guide's own switches read ON whatever they are set to, so the guide
-- shows without visiting them; off, every setting reads as set. Frames run
-- clean with it on.
local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}
local b

local function set(id, value)
    b.mock.menu:set("Jambix AIO/ESP", id, value)
    b.P.opt_invalidate()
end

T[#T + 1] = { "boots clean as Era", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.opt("rxp_only", nil), false, "declared, off by default")
end }

T[#T + 1] = { "RestedXP guide only: the overlay and the guide read on, whatever they are set to", function()
    set("enabled", false)
    b.mock.menu:set("Jambix AIO/Quests", "rxp_on", false)
    b.mock.menu:set("Jambix AIO/Quests", "guide_on", false)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("enabled", true), false, "off: the ESP as set")
    assert_eq(b.P.opt("rxp_on", true), false, "off: RestedXP as set")
    set("rxp_only", true)
    assert_eq(b.P.opt("enabled", true), true, "on: the overlay runs")
    assert_eq(b.P.opt("rxp_on", true), true, "on: the RestedXP ESP runs")
    assert_eq(b.P.opt("guide_on", true), true, "on: the guide's marks run")
    assert_eq(b.P.opt("max_range", 150), b.P.opt("max_range", 150), "other settings untouched")
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean with it on")
    set("rxp_only", false)
    assert_eq(b.P.opt("enabled", true), false, "off again: as set")
end }

T[#T + 1] = { "quests apart (1.73.0): ESP off, quests on -- the overlay is asked for the quest marks only", function()
    local asked = {}
    local render = b.P.esp.render
    b.P.esp.render = function(visuals, master, quest_visuals)
        asked[#asked + 1] = { visuals = visuals, quests = quest_visuals }
        return render(visuals, master, quest_visuals)
    end
    -- The mock declares keybinds inactive; the game starts this one active.
    set("toggle_key", { vk = 0x5A, active = true, toggled = true })
    set("enabled", false)
    b.mock.menu:set("Jambix AIO/Quests", "rxp_on", true)
    b.mock.menu:set("Jambix AIO/Quests", "guide_on", true)
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean through the quest-only path")
    local last = asked[#asked] or {}
    assert_eq(last.visuals, false, "the ESP is off")
    assert_eq(last.quests, true, "the quest and guide marks are asked for")
    b.P.esp.render = render
end }

return T

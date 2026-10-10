-- Jambix AIO 1.73.0: the quest side apart from the ESP. The user: "quests
-- ESP and Forever ESP have them be separate so if i dont want ESP but I want
-- RestedXP I can have that". The whole plugin booted as Forever: with the ESP
-- page's "Enable ESP" off, the overlay is still asked for the quest marks and
-- the HUD for the guide and the quest paths, but the threat panel is not;
-- with the Quests page's switches off too, the overlay draws nothing; the
-- toggle key hides everything. The Forever ESP page has no quest row any
-- more, and a "Quest targets" switched off there is carried to the Quests
-- page once.
local boot = require("mock/aio_boot")

local ESP, QUESTS = "Jambix AIO/Forever ESP", "Jambix AIO/Quests"

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}
local b
local seen = {}

local function reset()
    seen.render, seen.hud, seen.panel = {}, 0, 0
end

--- Records what the render jobs ask for, then lets them through.
local function watch()
    reset()
    local esp, quests = b.P.esp, b.P.quests
    local render, panel, hud = esp.render, esp.draw_threat_panel, quests.render_hud
    esp.render = function(visuals, master, quest_visuals)
        seen.render[#seen.render + 1] = { visuals = visuals, quests = quest_visuals }
        return render(visuals, master, quest_visuals)
    end
    esp.draw_threat_panel = function(...)
        seen.panel = seen.panel + 1
        return panel(...)
    end
    quests.render_hud = function(...)
        seen.hud = seen.hud + 1
        return hud(...)
    end
end

local function set(page, id, value)
    b.mock.menu:set(page, id, value)
    b.P.opt_invalidate()
end

local function last_render()
    return seen.render[#seen.render] or {}
end

T[#T + 1] = { "Forever: boots clean; a quest row saved off on the ESP page is carried to the Quests page once", function()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        -- Saved by an earlier version, when the row was on this page.
        mock.menu:set(ESP, "quest_on", false)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.mock.menu:get(QUESTS, "questie_on"), true, "the Quests page's switch, on by default")
    b.mock.frame(400)
    assert_eq(b.errors(), "", "frames run clean")
    assert_eq(b.mock.menu:get(QUESTS, "questie_on"), false, "carried over once")
    -- Once only: switched back on, it stays on.
    set(QUESTS, "questie_on", true)
    b.mock.frame(400)
    assert_eq(b.mock.menu:get(QUESTS, "questie_on"), true, "not carried again")
end }

T[#T + 1] = { "Forever: ESP off, quests on -- the quest side is still drawn, the threat panel is not", function()
    watch()
    -- The mock declares keybinds inactive; the game starts this one active.
    set(ESP, "toggle_key", { vk = 0x5A, active = true, toggled = true })
    set(ESP, "enabled", false)
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean with the ESP off")
    assert_eq(last_render().visuals, false, "the ESP is off")
    assert_eq(last_render().quests, true, "the quest marks are asked for")
    assert(seen.hud >= 5, "the guide and the quest paths are drawn every frame: " .. seen.hud)
    assert_eq(seen.panel, 0, "no threat panel")
end }

T[#T + 1] = { "Forever: ESP off, quest marks and RestedXP off -- nothing from the quest side either", function()
    reset()
    set(QUESTS, "questie_on", false)
    set(QUESTS, "rxp_on", false)
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean")
    assert_eq(last_render().visuals, false, "the ESP is off")
    assert_eq(last_render().quests, false, "no quest marks asked for")
end }

T[#T + 1] = { "Forever: ESP on, quests off -- the ESP and its threat panel as before", function()
    reset()
    set(ESP, "enabled", true)
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean")
    assert_eq(last_render().visuals, true, "the ESP is on")
    assert(seen.panel >= 5, "the threat panel is drawn: " .. seen.panel)
end }

T[#T + 1] = { "Forever: the toggle key hides everything, quests included", function()
    set(QUESTS, "questie_on", true)
    set(QUESTS, "rxp_on", true)
    set(ESP, "enabled", false)
    set(ESP, "toggle_key", { vk = 0x5A, active = false, toggled = false })
    reset()
    b.mock.frame(5)
    assert_eq(b.errors(), "", "frames run clean")
    assert_eq(last_render().visuals, false, "hidden: no ESP")
    assert_eq(last_render().quests, false, "hidden: no quest marks")
    assert_eq(seen.hud, 0, "hidden: no guide panel or quest paths")
end }

return T

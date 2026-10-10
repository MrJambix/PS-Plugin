-- Jambix AIO 1.47.0: the Classic half of aio_esp_split_forever_test. On Era
-- the ESP page keeps its path ("ESP") and the values saved under it, says at
-- its top that it is the Classic ESP, and the fight data stays in
-- jambix.aio.fight.json, read and written exactly as before. No Forever
-- page and no Forever file appear.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local SHARED = '{"npcs":{"3461":{"c":0,"r":3},"251143":{"c":191,"r":0}}}'
local SHARED_FILE = "jcore/jambix.aio.fight.json"
local FOREVER_FILE = "jcore/jambix.aio.forever_fight.json"

local b
local T = {}

T[#T + 1] = { "Era: the whole plugin boots clean", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" }, function(mock)
        mock.data_fs[SHARED_FILE] = SHARED
        -- Critters saved on, as "Show every category" used to leave them.
        mock.menu:set("Jambix AIO/ESP", "critter_on", true)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, false, "not Forever")
    assert_eq(b.P.esp.off, false, "the Classic ESP runs")
    assert_eq(b.P.esp.forever, nil, "the Forever ESP is never loaded")
end }

T[#T + 1] = { "Era: the ESP page keeps its path and says it is the Classic ESP", function()
    local pages = b.mock.menu.pages
    local page = pages["Jambix AIO/ESP"]
    assert(page, "the ESP page")
    assert_eq(pages["Jambix AIO/Forever ESP"], nil, "no Forever ESP page")
    assert_eq(page.sections[1] and page.sections[1].title, "Classic ESP", "the first section")
    assert_eq(page.sections[2] and page.sections[2].title, "General", "then the page as before")
    b.mock.menu:set("Jambix AIO/ESP", "text_size", 17)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("text_size", 13), 17, "values saved under ESP are read as always")
end }

T[#T + 1] = { "Era: the fight data is the same file, read and written as before", function()
    local fight = b.P.esp_fight
    assert_eq(fight.seen(3461), "ranged", "Oasis Snapjaw, from the file")
    rawset(core.spell_book, "get_spell_school", function() return 4 end)
    rawset(core.spell_book, "get_spell_max_range", function() return 30 end)
    fight.observe(3300, 990002)
    b.ctx.storage.flush(true)
    local text = b.mock.data_fs[SHARED_FILE]
    assert(text and text:find("3300", 1, true), "learned into the Classic file: " .. tostring(text))
    assert(text:find("3461", 1, true), "keeping what it held")
    assert_eq(b.mock.data_fs[FOREVER_FILE], nil, "no Forever file on Era")
    b.mock.frame(30)
    assert_eq(b.errors(), "", "core.log_error while running")
end }

local function button(id)
    local page = b.mock.menu.pages["Jambix AIO/ESP"]
    for _, section in ipairs(page.sections) do
        if section.buttons and section.buttons[id] then return section.buttons[id] end
    end
    error("no button " .. id)
end

T[#T + 1] = { "Era: critters saved on are switched off once, a second after load (1.47.1)", function()
    b.mock.frame(90)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("critter_on", true), false, "switched off")
    b.ctx.storage.flush(true)
    local text = b.mock.data_fs["jcore/jambix.aio.migrations.json"]
    assert(text and text:find("critters_off:ESP", 1, true), "and noted: " .. tostring(text))
end }

T[#T + 1] = { "Era: after that the Critters switch is the user's", function()
    b.mock.menu:set("Jambix AIO/ESP", "critter_on", true)
    b.mock.frame(400)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("critter_on", false), true, "switched on by hand, it stays on")
    b.mock.menu:set("Jambix AIO/ESP", "critter_on", false)
    b.P.opt_invalidate()
end }

T[#T + 1] = { "Era: Show every category leaves critters off", function()
    b.mock.menu:set("Jambix AIO/ESP", "normal_on", false)
    button("esp_mark_everything").on_click()
    b.P.opt_invalidate()
    assert_eq(b.P.opt("normal_on", false), true, "a category switched on")
    assert_eq(b.P.opt("critter_on", true), false, "critters left off")
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

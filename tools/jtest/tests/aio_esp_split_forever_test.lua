-- Jambix AIO 1.47.0: the Classic ESP and the Classic Forever ESP are kept
-- apart. On Forever the ESP page is "Forever ESP", with settings of its own,
-- and what mobs are seen doing is learned into its own store
-- (jambix.aio.forever_fight.json). The Classic ESP's settings and its file
-- are left as they were. aio_esp_split_era_test is the Classic half.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- The file both clients wrote before 1.47.0: a classic creature (Oasis
-- Snapjaw) and one only Forever has.
local SHARED = '{"npcs":{"3461":{"c":0,"r":3},"251143":{"c":191,"r":0}}}'
local SHARED_FILE = "jcore/jambix.aio.fight.json"
local FOREVER_FILE = "jcore/jambix.aio.forever_fight.json"

local b
local T = {}

T[#T + 1] = { "Forever: the whole plugin boots clean beside the shared fight file", function()
    b = boot.run("Forever", "wow_forever_us", { "_classic_era_" }, function(mock)
        mock.data_fs[SHARED_FILE] = SHARED
        -- Saved before 1.69.0: the health number at its old default, and
        -- one piece switched off by hand. And before 1.7.6 the curtains at
        -- their old default, on, and the box style as 1.88.0 left it, the
        -- curtain.
        mock.menu.values["Jambix AIO/Forever ESP"] = { show_health_text = true, show_level = false, box_style = 4,
            aurora_on = true, killnext_on = true, party_heal_curtain = true, party_loose = true, groupx_tank = true,
            tele_wall = true, esp_beacons = true }
        mock.menu.values["Jambix AIO/Hardcore"] = { pull_curtains = true }
        mock.menu.values["Jambix AIO/Reactions"] = { pvp_kill_target = true, pvp_healers = true, plays_rotation = true,
            pvpx_bg = true }
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert_eq(b.P.forever, true, "Forever")
    assert(b.P.esp.forever, "the Forever ESP is loaded")
end }

T[#T + 1] = { "Forever: the icon card's one-time move (1.69.0): the old health number goes, the Style reads the pieces", function()
    local PATH = "Jambix AIO/Forever ESP"
    b.mock.frame(90)
    assert_eq(b.mock.menu:get(PATH, "show_health_text"), false, "the health number at its old default: off")
    assert_eq(b.mock.menu:get(PATH, "show_level"), false, "a piece set by hand: kept")
    assert_eq(b.mock.menu:get(PATH, "esp_style"), 4, "so the Style is Custom")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

T[#T + 1] = { "Forever: the new look (1.88.0): its switches on by default; the box is the corners again and the beacons off (1.7.6)", function()
    local PATH = "Jambix AIO/Forever ESP"
    local m = b.mock.menu
    local cfg = b.P.cfg
    assert_eq(m:get(PATH, "esp_shader_look"), true, "Soft cards and bars")
    assert_eq(m:get(PATH, "esp_beacons"), false, "the beacons: a curtain, saved on, switched off (1.7.6)")
    assert_eq(m:get(PATH, "esp_beacon_from"), 40, "from 40 yards")
    assert_eq(m:get(PATH, "gather_skill_only"), true, "herbs and ore by your skill")
    assert_eq(cfg.BOX_DEFAULT, cfg.BOX_CORNERS, "1.7.6: the corners are the default")
    assert_eq(m:get(PATH, "box_style"), cfg.BOX_CORNERS, "the saved curtain moved back to the corners once")
    -- The game's bar texture is only drawn with the soft look off, and only
    -- offered then (advanced settings on).
    m:set("Jambix AIO", "show_advanced", true)
    b.P.opt_invalidate()
    assert_eq(m:visible(PATH, "game_bars"), false, "hidden while the soft look is on")
    m:set(PATH, "esp_shader_look", false)
    b.P.opt_invalidate()
    assert_eq(m:visible(PATH, "game_bars"), true, "offered with it off")
    m:set(PATH, "esp_shader_look", true)
    m:set("Jambix AIO", "show_advanced", false)
    b.P.opt_invalidate()
    -- Picked again by hand, the corners stay: the move is made once.
    m:set(PATH, "box_style", cfg.BOX_CORNERS)
    b.mock.frame(30)
    assert_eq(m:get(PATH, "box_style"), cfg.BOX_CORNERS, "kept")
    b.P.opt_invalidate()
    assert_eq(b.P.opt("box_style", nil), cfg.BOX_CORNERS, "the overlay reads it")
    m:set(PATH, "box_style", cfg.BOX_DEFAULT)
    b.P.opt_invalidate()
    assert_eq(b.errors(), "", "core.log_error while running")
end }

T[#T + 1] = { "1.7.6 curtains: every one saved on is switched off once, each keeps its own switch, the World marks page switches them all", function()
    local ESP, HC, RE = "Jambix AIO/Forever ESP", "Jambix AIO/Hardcore", "Jambix AIO/Reactions"
    local m = b.mock.menu
    for _, id in ipairs({ "aurora_on", "killnext_on", "party_heal_curtain", "party_loose", "groupx_tank", "tele_wall",
        "esp_beacons" }) do
        assert_eq(m:get(ESP, id), false, id .. ", saved on, switched off")
    end
    assert_eq(m:get(HC, "pull_curtains"), false, "pull safety's curtain")
    for _, id in ipairs({ "pvp_kill_target", "pvp_healers", "plays_rotation", "pvpx_bg" }) do
        assert_eq(m:get(RE, id), false, id)
    end
    -- What was not a curtain stays as it was.
    assert_eq(m:get(ESP, "party_rings"), true, "the party's rings")
    assert_eq(m:get(HC, "pull_on"), true, "pull safety itself")
    assert_eq(m:get("Jambix AIO/World marks", "cr_execute"), true, "the execute ring")
    -- The new curtain switches start off.
    assert_eq(m:get("Jambix AIO/World marks", "cr_execute_curtain"), false, "execute's curtain")
    assert_eq(m:get("Jambix AIO/Rotation", "react_curtain_vanish"), false, "the vanish curtain")
    assert_eq(m:get("Jambix AIO/Rotation", "react_curtain_burst"), false, "the burst curtain")

    -- Switched back on by hand: kept, the move is made once.
    m:set(ESP, "aurora_on", true)
    b.mock.frame(30)
    assert_eq(m:get(ESP, "aurora_on"), true, "the aurora on again, kept")
    b.P.opt_invalidate()
    assert_eq(b.P.opt("aurora_on", false), true, "and the overlay reads it")

    -- Every curtain at once, both ways.
    local list = b.P.CURTAINS
    assert(type(list) == "table" and #list >= 16, "the World marks page's list")
    local page = m.pages["Jambix AIO/World marks"]
    assert(page, "a World marks page")
    local function press(id)
        for _, section in ipairs(page.sections or {}) do
            local o = section.buttons and section.buttons[id]
            if o and o.on_click then o.on_click() return true end
        end
        return false
    end
    assert(press("curtains_all_off"), "a button to switch every curtain off")
    assert_eq(m:get(ESP, "aurora_on"), false, "all off: the aurora")
    assert_eq(m:get(ESP, "box_style"), b.P.cfg.BOX_CORNERS, "all off: the box")
    assert(press("curtains_all_on"), "and one to switch them all on")
    assert_eq(m:get(HC, "pull_curtains"), true, "all on: pull safety's curtain")
    assert_eq(m:get("Jambix AIO/Rotation", "react_curtain_burst"), true, "all on: the burst curtain")
    assert_eq(m:get(ESP, "box_style"), b.P.cfg.BOX_CURTAIN, "all on: the curtain box")
    assert_eq(m:get(ESP, "esp_beacons"), true, "all on: the beacons")
    assert_eq(m:get(RE, "pvpx_bg"), true, "all on: the flag carriers' beacon")
    press("curtains_all_off")
    assert_eq(m:get(RE, "pvp_healers"), false, "off again")
    assert_eq(b.errors(), "", "core.log_error while running")
end }

T[#T + 1] = { "Forever: the ESP page is the Forever ESP's own: a Style, a grid of what to show, advanced pieces", function()
    local pages = b.mock.menu.pages
    local page = pages["Jambix AIO/Forever ESP"]
    assert(page, "a Forever ESP page")
    assert_eq(pages["Jambix AIO/ESP"], nil, "no Classic ESP page on Forever")
    local titles = {}
    for i, s in ipairs(page.sections) do titles[i] = s.title end
    local said = table.concat(titles, ", ")
    assert_eq(titles[1], "ESP", "the first section: " .. said)
    assert_eq(titles[2], "In a fight", "then the fight: " .. said)
    local get = function(id) return b.mock.menu:get("Jambix AIO/Forever ESP", id) end
    assert_eq(get("show_icon"), true, "a piece, at Clean")
    assert_eq(get("critter_detail"), 3, "critters: the icon alone by default")
    assert_eq(get("normal_detail"), 1, "normal mobs: everything")
    assert_eq(get("guide_detail"), nil, "no guide targets on Forever")
    assert_eq(get("herb_on"), true, "the grid's switches are the categories'")
    for _, s in ipairs(page.sections) do
        local vis = s.opts and s.opts.visible
        if s.title == "What a mark shows" or s.title == "Each category" or s.title == "Look" then
            assert(type(vis) == "function" and vis() == false, s.title .. ": hidden in simple mode")
        elseif s.title == "ESP" or s.title == "Enemies" or s.title == "World" then
            assert(vis == nil, s.title .. ": always shown")
        end
    end
end }

T[#T + 1] = { "Forever: the Style writes every piece; a piece changed by hand makes it Custom", function()
    local PATH = "Jambix AIO/Forever ESP"
    local m = b.mock.menu
    m:set(PATH, "esp_style", 1)
    assert_eq(m:get(PATH, "show_level"), false, "Minimal: no level")
    assert_eq(m:get(PATH, "show_distance"), false, "Minimal: no distance")
    assert_eq(m:get(PATH, "esp_style"), 1, "still Minimal after writing its pieces")
    m:set(PATH, "esp_style", 3)
    assert_eq(m:get(PATH, "show_box"), true, "Detailed: boxes")
    assert_eq(m:get(PATH, "show_health_text"), true, "Detailed: health numbers")
    assert_eq(m:get(PATH, "esp_style"), 3, "still Detailed")
    m:set(PATH, "show_box", false)
    assert_eq(m:get(PATH, "esp_style"), 4, "a piece by hand: Custom")
    m:set(PATH, "esp_style", 4)
    assert_eq(m:get(PATH, "show_box"), false, "Custom writes nothing")
    m:set(PATH, "esp_style", 2)
    assert_eq(m:get(PATH, "show_level"), true, "back to Clean")
    assert_eq(m:get(PATH, "show_health_text"), false, "Clean: the bar says the health")
    b.P.opt_invalidate()
    assert_eq(b.P.opt("show_box", true), false, "the overlay reads what the Style wrote")
end }

T[#T + 1] = { "Forever: the shipped art pack is written into scripts_data, decodes, and is registered", function()
    local art = b.P.esp_art
    assert(art, "built")
    local st = art.stats()
    assert_eq(st.available, true, "available: " .. tostring(st.why))
    local bytes = b.mock.data_fs[st.file]
    assert(bytes and bytes:sub(2, 4) == "PNG", "a PNG at " .. tostring(st.file))
    local pack = require("jambix_aio/modules/esp/art_pack")
    local w, h = jtest.png_decode(bytes)
    assert_eq(w, pack.w, "its width")
    assert_eq(h, pack.h, "its height")
    assert(art.ref("kill"), "a cell by name")
    assert_eq(art.ref("no such cell"), nil, "an unknown cell is nil")
    for key, uv in pairs(pack.cells) do
        assert(uv[1] >= 0 and uv[3] <= 1 and uv[2] >= 0 and uv[4] <= 1 and uv[1] < uv[3] and uv[2] < uv[4],
            "cell inside the atlas: " .. key)
    end
    for _, key in ipairs({ "kill", "loot", "skin", "use", "quest_pickup", "quest_turnin", "elite", "rare",
        "rare_elite", "boss", "shield", "combat", "statusbar", "node.herb", "node.ore", "service.repair",
        "fight.melee", "fight.ranged", "fight.caster", "creature.1", "class.3" }) do
        assert(pack.cells[key], "the pack has " .. key)
    end
end }

T[#T + 1] = { "Forever: its settings are its own; a Classic value does not reach it", function()
    b.mock.menu:set("Jambix AIO/Forever ESP", "text_size", 17)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("text_size", 13), 17, "the Forever page's value")
    -- What the Classic page has saved (the same widget id, its own path).
    b.mock.menu:set("Jambix AIO/ESP", "text_size", 11)
    b.mock.menu:set("Jambix AIO/ESP", "normal_on", false)
    b.P.opt_invalidate()
    assert_eq(b.P.opt("text_size", 13), 17, "still the Forever value")
    assert_eq(b.P.opt("normal_on", true), true, "a Classic switch off does not switch Forever's off")
end }

T[#T + 1] = { "Forever: the fight data starts from the Forever creatures only", function()
    local fight = b.P.esp_fight
    assert_eq(fight.seen(251143), "caster", "a Forever creature learned before 1.47.0 is kept")
    assert_eq(fight.seen(3461), nil, "a classic creature from the shared file is not taken")
    b.ctx.storage.flush(true)
    local text = b.mock.data_fs[FOREVER_FILE]
    assert(text and text:find("251143", 1, true), "Forever's own file is written: " .. tostring(text))
    assert(not text:find("3461", 1, true), "without the classic creature")
    assert_eq(b.mock.data_fs[SHARED_FILE], SHARED, "the shared file is untouched")
end }

T[#T + 1] = { "Forever: what it learns goes to its own file, never the Classic one", function()
    rawset(core.spell_book, "get_spell_school", function() return 4 end)       -- fire
    rawset(core.spell_book, "get_spell_max_range", function() return 30 end)
    b.P.esp_fight.observe(260001, 990001)
    assert_eq(b.P.esp_fight.seen(260001), "caster", "learned")
    b.ctx.storage.flush(true)
    assert(b.mock.data_fs[FOREVER_FILE]:find("260001", 1, true), "in the Forever file")
    assert_eq(b.mock.data_fs[SHARED_FILE], SHARED, "the Classic file is untouched")
    b.mock.frame(30)
    assert_eq(b.errors(), "", "core.log_error while running")
end }

return T

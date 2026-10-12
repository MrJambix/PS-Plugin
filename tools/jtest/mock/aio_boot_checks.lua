-- The assertions the per-client boot tests share. Each boots the whole
-- plugin once, as one client (see mock/aio_boot.lua), then asks:
--
--   esp_only_suite   TBC, Wrath, Mists, Retail: the plugin is an overlay and
--                    NOTHING acts -- whatever the menu says
--   full_suite       the Vanilla client (Era, Hardcore, SoD) and Forever:
--                    everything as it was, the gate never in the way

local boot = require("mock/aio_boot")

local M = {}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- The menu page a setting was declared on.
local function page_of(mock, id)
    for path, values in pairs(mock.menu.values) do
        if values[id] ~= nil then return path end
    end
    error("no page declares " .. id)
end

--- Sets a widget, on the page given or the first that declares it. Give the
--- page for an id more than one page declares ("enabled" is JCore's too).
local function set(b, id, value, page)
    b.mock.menu:set(page and ("Jambix AIO/" .. page) or page_of(b.mock, id), id, value)
    b.P.opt_invalidate()
end

--- Switches the rotation's key on, so its gate is open unless something
--- else holds it shut.
local function rotation_key_on(b)
    set(b, "rot_key", { vk = 0x52, active = true, toggled = true }, "Rotation")
end

local function first_section(mock, page)
    local p = mock.menu.pages["Jambix AIO/" .. page]
    assert(p, "no page " .. page)
    return p.sections[1] and p.sections[1].title
end

local function logged(mock, needle)
    for i = 1, #mock.logs do
        if tostring(mock.logs[i]):find(needle, 1, true) then return true end
    end
    return false
end

-- Every switch that would make the plugin act, and a page it lives on.
local ACTING = {
    "autoloot_on", "autoloot_skin", "rest_enabled", "gather_herbs", "gather_ore",
    "gather_containers", "fish_enabled", "hc_enabled", "hc_block_pulls", "hc_hearth",
    "rot_hud_enabled", "rot_auto_target",
    -- 1.7.4: the guide walk (RestedXP with Sentinel Navigation).
    "rxp_follow",
    -- 1.8.1: the RestedXP ESP acting as you walk up.
    "rxp_act",
}

local PAGES = { "Rotation", "Hardcore", "Automation", "Fishing" }

-- Every client of the install, Era first, as on a PC with several: the
-- folder each client gets must be its own, not the first one found.
local INSTALLED = { "_classic_era_", "_anniversary_", "_retail_" }

function M.esp_only_suite(version, exact, label, own_folder)
    local b
    local T = {}

    T[#T + 1] = { label .. ": the whole plugin boots clean, as an overlay", function()
        b = boot.run(version, exact, INSTALLED)
        assert_eq(b.errors(), "", "core.log_error during boot")
        assert(b.P, "the plugin's bundle")
        assert_eq(b.P.esp_only, true, "ESP only")
        assert_eq(b.P.client_label, label, "client named")
        assert(logged(b.mock, label .. " client: running the ESP only"), "the log says so")
    end }

    T[#T + 1] = { label .. ": nothing acts -- even with every switch turned on", function()
        for i = 1, #ACTING do set(b, ACTING[i], true) end
        for i = 1, #ACTING do
            assert_eq(b.P.opt(ACTING[i], true), false, ACTING[i])
        end
        rotation_key_on(b)
        assert_eq(b.P.rotation_active(), false, "the rotation's gate, with its key on")
        local ok, why = b.ctx.cast({ spell_id = 1 })
        assert_eq(ok, false, "a cast is refused")
        assert(tostring(why):find("esp only", 1, true), "and says why")
        assert_eq(b.ctx.input.acquire("movement"), false, "no input lease")
    end }

    T[#T + 1] = { label .. ": the ESP answers to its own switches", function()
        set(b, "text_size", 17)
        assert_eq(b.P.opt("text_size", 13), 17, "an ESP setting reads through")
        set(b, "enabled", false, "ESP")
        assert_eq(b.P.opt("enabled", true), false, "the ESP's own switch reads through")
        set(b, "enabled", true, "ESP")
        assert(b.P.esp and b.P.esp.render, "the overlay is loaded")
    end }

    T[#T + 1] = { label .. ": every page that would act says why it does not, first", function()
        for i = 1, #PAGES do
            assert_eq(first_section(b.mock, PAGES[i]), "Not on " .. label, PAGES[i])
        end
    end }

    T[#T + 1] = { label .. ": the ESP page is the Classic ESP's, and says so", function()
        assert_eq(first_section(b.mock, "ESP"), "Classic ESP", "the ESP page's first section")
        assert_eq(b.mock.menu.pages["Jambix AIO/Forever ESP"], nil, "no Forever ESP page")
    end }

    T[#T + 1] = { label .. ": a second of frames runs clean", function()
        b.mock.frame(60)
        assert_eq(b.errors(), "", "core.log_error while running")
    end }


    T[#T + 1] = { label .. ": with several clients installed, JCore uses this client's folder", function()
        assert_eq(b.JCore.assets.flavor(), own_folder, "client folder")
    end }
    return T
end

function M.full_suite(version, exact, label, own_folder)
    local b
    local T = {}

    T[#T + 1] = { label .. ": the whole plugin boots clean, everything on", function()
        b = boot.run(version, exact, INSTALLED)
        assert_eq(b.errors(), "", "core.log_error during boot")
        assert_eq(b.P.esp_only, false, "not ESP only")
        assert(not logged(b.mock, "running the ESP only"), "nothing in the log about it")
    end }

    T[#T + 1] = { label .. ": the switches read through and the leases are JCore's own", function()
        for i = 1, #ACTING do set(b, ACTING[i], true) end
        for i = 1, #ACTING do
            assert_eq(b.P.opt(ACTING[i], false), true, ACTING[i])
        end
        local _, why = b.ctx.cast({ spell_id = 1 })
        assert(not tostring(why):find("esp only", 1, true), "cast not refused by the gate")
        rotation_key_on(b)
        assert_eq(b.P.rotation_active(), true, "the rotation's gate opens with its key")
    end }

    T[#T + 1] = { label .. ": no page carries the notice", function()
        for i = 1, #PAGES do
            local first = first_section(b.mock, PAGES[i])
            assert(not tostring(first):find("^Not on "), PAGES[i] .. " starts with " .. tostring(first))
        end
    end }

    T[#T + 1] = { label .. ": a second of frames runs clean", function()
        b.mock.frame(60)
        assert_eq(b.errors(), "", "core.log_error while running")
    end }


    T[#T + 1] = { label .. ": with several clients installed, JCore uses this client's folder", function()
        assert_eq(b.JCore.assets.flavor(), own_folder, "client folder")
    end }
    return T
end

return M

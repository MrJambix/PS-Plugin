-- Jambix AIO: the class-and-role icon drawer in modules/esp/elements.lua,
-- driven through a recording draw service. The point is the render path: a
-- drawer that throws dies sixty times a second in the game, and nothing but
-- the log says so.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")
local make_roles = require("jambix_aio/modules/esp/roles")
local make_elements = require("jambix_aio/modules/esp/elements")

local CLASS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, MAGE = 8, DRUID = 11 }
local ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 }

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A bundle with a draw service that records every call by name.
local function bundle(opts)
    opts = opts or {}
    local calls = {}
    local function record(name)
        return function(...)
            calls[#calls + 1] = { name = name, ... }
        end
    end

    local settings = opts.settings or {}
    local draw = {
        theme = { shadow = "shadow", text_dim = "dim", accent = "accent", neutral = "neutral" },
        unit_box_corners = record("unit_box_corners"),
        unit_label = record("unit_label"),
        unit_bar = record("unit_bar"),
        text_2d = record("text_2d"),
        line_2d = record("line_2d"),
        rect_2d = record("rect_2d"),
        circle_2d = record("circle_2d"),
        circle_3d = record("circle_3d"),
        unit_anchor = function() return { x = 400, y = 300 } end,
        unit_w2s = function() return { x = 400, y = 320 } end,
        screen_size = function() return 1920, 1080 end,
        image = function(ref, ...)
            calls[#calls + 1] = { name = "image", ref, ... }
            return opts.image_ready ~= false
        end,
    }

    -- The asset registry: enough of it for the portrait's art picking.
    local entries, atlases, recorded = {}, {}, {}
    local function entry_for(ref)
        local e = entries[ref]
        if not e then
            e = { key = ref, state = "idle" }
            local atlas_name = ref:match("^atlas:([^/]+)/")
            if atlas_name then e.atlas = { ref = atlases[atlas_name] } end
            entries[ref] = e
        end
        return e
    end
    local assets = {
        recorded = recorded,
        addon_installed = function(name)
            return (opts.installed and opts.installed[name]) and true or false
        end,
        atlas = function(name, ref, cells)
            atlases[name] = ref
            recorded[name] = { ref = ref, cells = cells }
        end,
        get = function(ref) return entry_for(ref) end,
        request = function(ref)
            local e = entry_for(ref)
            local base = e.atlas and entry_for(e.atlas.ref) or e
            -- The game's archives are unreadable unless the test says
            -- otherwise: that is a machine without a CASC client, and the
            -- older tests below are the fallback path it takes.
            if not opts.game and base.key:find("^game:") then
                base.state, base.dead, base.err = "failed", true, "archives not readable"
                return false, e
            end
            if opts.failed and opts.failed[base.key] then
                base.state, base.dead, base.err = "failed", true, "not found in the game folder"
                return false, e
            end
            if opts.image_ready == false then
                base.state = "loading"
                return false, e
            end
            base.state, e.state = "ready", "ready"
            return true, e
        end,
    }

    local P = {
        cfg = cfg,
        JCore = { assets = assets },
        log = { fmt = function(level, ...) if level == "error" then error(string.format(...)) end end },
        ctx = {
            LAYER = { WORLD = 100, UNITS = 200, OVERLAY = 300 },
            on = function() end,
            ROLE = ROLE,
        },
        enums = { class_id = CLASS, group_role = ROLE },
        units = {
            aura_index = function(u) return u._auras or {} end,
            health_fraction = function() return 1.0 end,
            player = function() return nil end,
        },
        draw = draw,
        quests = { quest_color = function() return "quest" end },
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        faded = function(col) return col end,
        class_color = { [CLASS.WARRIOR] = "warrior-colour", [CLASS.MAGE] = "mage-colour" },
        category_color = { hostile_player = "hostile", friendly_player = "friendly", normal = "normal" },
    }
    P.esp_roles = make_roles(P)
    P.esp_elements = make_elements(P)
    return P, calls, assets
end

local function entity(opts)
    return {
        obj = { get_position = function() return nil end },
        guid = "g1",
        kind = "unit",
        info = {
            name = opts.name or "Grimtusk",
            level = 60,
            is_player = opts.is_player ~= false,
            class_id = opts.class_id,
            role = opts.role,
            role_certain = opts.certain,
            creature_type = opts.creature_type,
            caster = opts.caster,
            spec = opts.spec,
            reaction = "hostile",
        },
        name = opts.name or "Grimtusk",
        category = opts.category or "hostile_player",
        distance = 30,
        range = 100,
        dead = opts.dead or false,
        lod = opts.lod or "full",
        prio = 80,
    }
end

local function count(calls, name)
    local n = 0
    for i = 1, #calls do if calls[i].name == name then n = n + 1 end end
    return n
end

local function first(calls, name)
    for i = 1, #calls do if calls[i].name == name then return calls[i] end end
    return nil
end

local T = {}

T[#T + 1] = { "the element resolved to a drawer", function()
    local P = bundle()
    local found = false
    for _, el in ipairs(P.esp_elements.active()) do
        if el.key == "show_class_icon" then found = true end
    end
    assert(found, "show_class_icon has no drawer")
end }

T[#T + 1] = { "a player gets the class art, a mask ring, a rim and a badge -- and no disc under the art", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))

    local img = first(calls, "image")
    assert(img, "class art was submitted")
    assert_eq(img[1], "icon:classicon_warrior", "asset reference")
    assert_eq(img[3], img[4], "square icon")

    -- mask ring, rim, badge backing, badge fill. NO filled disc before the
    -- art: textures paint beneath every shape, so a disc would hide the icon.
    assert_eq(count(calls, "circle_2d"), 4, "circles")
    assert(not first(calls, "circle_2d")[4].filled, "first circle is the mask ring, not a disc")
    local i_img, i_mask
    for i = 1, #calls do
        if calls[i].name == "image" and not i_img then i_img = i end
        if calls[i].name == "circle_2d" and not i_mask then i_mask = i end
    end
    assert(i_img < i_mask, "the art is submitted before the mask ring")
    -- the badge letter only: the art is on screen, so no class initial
    assert_eq(count(calls, "text_2d"), 1, "text_2d calls")
    assert_eq(first(calls, "text_2d")[2], "T", "badge letter")

    -- the name label sits BELOW the icon
    local label = first(calls, "unit_label")
    assert(label, "name label drawn")
    local ring = first(calls, "circle_2d")
    assert(label[4].at.y > ring[1].y, "name below the portrait")
end }

T[#T + 1] = { "before the art loads the disc carries the class initial", function()
    local P, calls = bundle({ image_ready = false })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.MAGE, role = "dps", certain = true }))

    -- disc, rim, badge backing, badge fill: no mask ring without the art
    assert_eq(count(calls, "circle_2d"), 4, "circles")
    assert(first(calls, "circle_2d")[4].filled, "the fallback disc is drawn first")
    local texts = {}
    for i = 1, #calls do if calls[i].name == "text_2d" then texts[#texts + 1] = calls[i][2] end end
    assert_eq(#texts, 2, "initial and badge letter")
    assert_eq(texts[1], "M", "class initial")
    assert_eq(texts[2], "D", "badge letter")
end }

T[#T + 1] = { "a guessed role is drawn with the translucent badge", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.PALADIN, role = "healer", certain = false }))
    local fills = {}
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" and c[4] and c[4].filled then fills[#fills + 1] = c[3] end
    end
    -- badge backing, badge fill
    assert_eq(#fills, 2, "filled circles")
    assert_eq(fills[2].a, 165, "guess alpha")
    assert_eq(fills[2].g, cfg.ROLE_RGB.healer[2], "healer green")
end }

T[#T + 1] = { "no role, no badge", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = nil }))
    assert_eq(count(calls, "circle_2d"), 2, "mask, rim only")
    assert_eq(count(calls, "text_2d"), 0, "no letters")
end }

T[#T + 1] = { "the badge toggle removes only the badge", function()
    local P, calls = bundle({ settings = { role_badge = false } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))
    assert_eq(count(calls, "circle_2d"), 2, "mask, rim")
    assert_eq(count(calls, "image"), 1, "art still drawn")
end }

T[#T + 1] = { "the element toggle removes the whole portrait", function()
    local P, calls = bundle({ settings = { show_class_icon = false } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))
    assert_eq(count(calls, "circle_2d"), 0, "no circles")
    assert_eq(count(calls, "image"), 0, "no art")
    assert(first(calls, "unit_label"), "name still drawn")
end }

T[#T + 1] = { "a far player gets no portrait", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true, lod = "far" }))
    assert_eq(count(calls, "image"), 0, "far art")
    assert_eq(count(calls, "circle_2d"), 0, "far circles")
end }

T[#T + 1] = { "a creature gets its type's art in the mark colour, badged caster", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = 7, caster = true }))
    local img = first(calls, "image")
    assert(img, "creature art submitted")
    assert_eq(img[1], "icon:inv_misc_head_human_01", "humanoid icon")
    -- mask, rim, badge backing, badge fill
    assert_eq(count(calls, "circle_2d"), 4, "circles")
    local rim
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" and c[4] and c[4].thickness == 2.0 then rim = c end
    end
    assert(rim, "rim drawn")
    assert_eq(rim[3], P.esp_elements.reaction_color.hostile, "rim is the mark colour (hostile reaction)")
    assert_eq(first(calls, "text_2d")[2], "C", "caster badge")
    local label = first(calls, "unit_label")
    assert(label[4].at.y > first(calls, "circle_2d")[1].y, "name below the portrait")
end }

T[#T + 1] = { "a melee creature without art shows its initial and an M", function()
    local P, calls = bundle({ image_ready = false })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = 1, caster = false }))
    local texts = {}
    for i = 1, #calls do if calls[i].name == "text_2d" then texts[#texts + 1] = calls[i][2] end end
    assert_eq(texts[1], "B", "beast initial")
    assert_eq(texts[2], "M", "melee badge")
end }

T[#T + 1] = { "an unknown mana read means no creature badge; an unknown type gets the question mark", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = nil, caster = nil }))
    assert_eq(first(calls, "image")[1], "icon:inv_misc_questionmark", "unknown type icon")
    assert_eq(count(calls, "circle_2d"), 2, "mask and rim only")
    assert_eq(count(calls, "text_2d"), 0, "no badge")
end }

T[#T + 1] = { "corpses and switched-off creature icons draw nothing", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "corpse", creature_type = 7, caster = true, dead = true }))
    -- No PORTRAIT: the only image a corpse gets is its LOOT / SKIN chip's icon.
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "image" then
            assert(c[1] ~= "icon:inv_misc_head_human_01", "a corpse got the creature portrait")
        end
    end
    assert(count(calls, "circle_2d") == 0, "no portrait ring on a corpse")

    local P2, calls2 = bundle({ settings = { show_creature_icon = false } })
    P2.esp_elements.begin_frame()
    P2.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = 7, caster = true }))
    assert_eq(count(calls2, "image"), 0, "toggled off")
    assert(first(calls2, "unit_label"), "name still drawn")
end }

T[#T + 1] = { "the player toggle does not touch creatures and vice versa", function()
    local P, calls = bundle({ settings = { show_class_icon = false } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = 6, caster = false }))
    assert_eq(first(calls, "image")[1], "icon:spell_shadow_raisedead", "undead still drawn")
end }

T[#T + 1] = { "a player with no class id is skipped, not a crash", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = nil, role = "dps", certain = true }))
    assert_eq(count(calls, "image"), 0, "no art")
    assert(first(calls, "unit_label"), "name drawn")
end }

T[#T + 1] = { "the icon size slider scales the disc", function()
    local P, calls = bundle({ settings = { class_icon_size = 40 } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))
    local rim
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" and c[3] == "warrior-colour" then rim = c end
    end
    assert(rim, "rim drawn in the class colour")
    assert_eq(rim[2], 20.5, "rim radius = size/2 + 0.5")
    local img = first(calls, "image")
    assert(math.abs(img[3] - 40 * 0.70710678) < 0.01, "icon side = size / sqrt 2")
end }

T[#T + 1] = { "every failed source is named in the log once", function()
    local P, calls = bundle({ failed = { ["icon:classicon_warrior"] = true } })
    local warned = {}
    P.log = { fmt = function(level, fmt, ...) warned[#warned + 1] = level .. ": " .. string.format(fmt, ...) end }
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))
    local after_first = #warned
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true }))
    assert_eq(#warned, after_first, "nothing logged twice")
    -- the archive class sheet, the archive icon, the CDN icon
    assert_eq(after_first, #P.esp_elements.class_art[CLASS.WARRIOR], "one line per source")
    local cdn
    for i = 1, #warned do
        if warned[i]:find("icon:classicon_warrior", 1, true) then cdn = warned[i] end
    end
    assert(cdn and cdn:find("not found", 1, true), "the CDN failure names its reason")
    -- and the portrait fell back to the disc and initial
    assert(first(calls, "circle_2d")[4].filled, "fallback disc")
end }

-- --- the game's own sheets ---------------------------------------------------

local CLASS_SHEET = "addon:Details/images/classes_small_alpha.tga"

T[#T + 1] = { "with Details installed the crest comes from the sheet, round, with the spec badge", function()
    local P, calls, assets = bundle({ installed = { Details = true } })
    assert_eq(P.esp_elements.sheets.classes, CLASS_SHEET, "class sheet chosen")
    assert_eq(P.esp_elements.sheets.specs, "addon:Details/images/spec_icons_normal_alpha.tga", "spec sheet chosen")

    -- the atlas was registered with the addon's left/right/top/bottom turned into u0/v0/u1/v1
    local reg = assets.recorded.jambix_classes
    assert(reg and reg.ref == CLASS_SHEET, "class atlas registered on the sheet")
    local w = reg.cells.WARRIOR
    assert_eq(w[1], 0, "u0"); assert_eq(w[2], 0, "v0"); assert_eq(w[3], 0.125, "u1"); assert_eq(w[4], 0.125, "v1")
    local specs = assets.recorded.jambix_specs
    assert(specs and specs.cells[73], "spec atlas has protection warrior")

    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true, spec = 73 }))

    local imgs = {}
    for i = 1, #calls do if calls[i].name == "image" then imgs[#imgs + 1] = calls[i] end end
    assert_eq(#imgs, 2, "crest and spec icon")
    assert_eq(imgs[1][1], "atlas:jambix_classes/WARRIOR", "crest from the sheet")
    assert_eq(imgs[1][3], 22, "crest drawn to the rim, not the inscribed square")
    assert_eq(imgs[2][1], "atlas:jambix_specs/73", "spec icon from the sheet")

    -- rim, badge mask ring, badge ring: no mask on the crest, no filled disc, no letters
    assert_eq(count(calls, "circle_2d"), 3, "circles")
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" then assert(not (c[4] and c[4].filled), "no filled circle") end
    end
    assert_eq(count(calls, "text_2d"), 0, "no letters")
end }

T[#T + 1] = { "a failed sheet falls back to the CDN icon and the letter badge", function()
    local P, calls = bundle({ installed = { Details = true }, failed = { [CLASS_SHEET] = true,
        ["addon:Details/images/spec_icons_normal_alpha.tga"] = true } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.MAGE, role = "dps", certain = true, spec = 64 }))
    local img = first(calls, "image")
    assert_eq(img[1], "icon:classicon_mage", "CDN icon")
    assert(math.abs(img[3] - 22 * 0.70710678) < 0.01, "inscribed square")
    assert_eq(first(calls, "text_2d")[2], "D", "letter badge")
end }

T[#T + 1] = { "while the sheet loads the portrait waits with the initial rather than flashing CDN art", function()
    local P, calls = bundle({ installed = { Details = true }, image_ready = false })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.DRUID, role = "healer", certain = false, spec = 105 }))
    assert_eq(count(calls, "image"), 0, "nothing painted yet")
    assert(first(calls, "circle_2d")[4].filled, "disc")
    assert_eq(first(calls, "text_2d")[2], "D", "druid initial")
end }

T[#T + 1] = { "Plater supplies the spec sheet when Details is absent", function()
    local P = bundle({ installed = { Plater = true } })
    assert_eq(P.esp_elements.sheets.classes, nil, "no class sheet")
    assert_eq(P.esp_elements.sheets.specs, "addon:Plater/images/spec_icons_normal_alpha.tga", "Plater spec sheet")
    local list = P.esp_elements.class_art[CLASS.WARRIOR]
    for i = 1, #list do
        assert(not list[i][1]:find("jambix_classes/", 1, true), "no addon crest without Details")
    end
    assert_eq(list[#list][1], "icon:classicon_warrior", "the CDN is the last resort")
end }

T[#T + 1] = { "no addon at all: only the game's own sheets are registered", function()
    local P, _, assets = bundle()
    assert_eq(P.esp_elements.sheets.classes, nil, "no class sheet")
    assert_eq(P.esp_elements.sheets.specs, nil, "no spec sheet")
    local names = {}
    for name in pairs(assets.recorded) do names[#names + 1] = name end
    table.sort(names)
    -- Every sheet registered is the game's own: the class and role sheets,
    -- and the UI sheets (state icons, elite dragon, PvP emblems). None of an
    -- addon's.
    for i = 1, #names do
        assert(names[i]:find("^jambix_game_") or names[i]:find("^jambix_ui_"), "an addon sheet: " .. names[i])
        assert(assets.recorded[names[i]].ref:find("^game:"), names[i] .. " is not from the archives")
    end
    assert(assets.recorded.jambix_game_classes and assets.recorded.jambix_game_roles, "class and role sheets")
    -- spec art is the game's talent icons only
    for id, list in pairs(P.esp_elements.spec_art) do
        assert_eq(#list, 1, "one source for spec " .. id)
        assert(list[1][1]:find("^game:Interface/Icons/"), "game icon for spec " .. id)
    end
end }

-- --- the game's own archives -----------------------------------------------

T[#T + 1] = { "the archive sheets are registered with the client's own coordinates", function()
    local P, _, assets = bundle({ game = true })
    local classes = assets.recorded.jambix_game_classes
    assert_eq(classes.ref, cfg.GAME_CLASS_SHEET.ref, "class sheet ref")
    local w = classes.cells.WARRIOR
    assert_eq(w[1], 0, "u0"); assert_eq(w[2], 0, "v0"); assert_eq(w[3], 0.25, "u1"); assert_eq(w[4], 0.25, "v1")
    local p = classes.cells.PALADIN
    assert_eq(p[2], 0.5, "paladin on the third row")
    local roles = assets.recorded.jambix_game_roles
    assert_eq(roles.ref, cfg.GAME_ROLE_SHEET.ref, "role sheet ref")
    local t = roles.cells.tank
    assert_eq(t[1], 0, "tank u0"); assert_eq(t[2], 22 / 64, "tank v0")
    assert_eq(t[3], 19 / 64, "tank u1"); assert_eq(t[4], 41 / 64, "tank v1")
    assert_eq(P.esp_elements.sheets.game_classes, cfg.GAME_CLASS_SHEET.ref, "reported for the debug page")
end }

T[#T + 1] = { "with the archives readable: the game's class icon, masked, and its role circle", function()
    local P, calls = bundle({ game = true, installed = { Details = true } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.WARRIOR, role = "tank", certain = true, spec = 73 }))

    local imgs = {}
    for i = 1, #calls do if calls[i].name == "image" then imgs[#imgs + 1] = calls[i] end end
    assert_eq(#imgs, 2, "class icon and role circle")
    assert_eq(imgs[1][1], "atlas:jambix_game_classes/WARRIOR", "the archive sheet wins over Details")
    assert(math.abs(imgs[1][3] - 22 * 0.70710678) < 0.01, "square icon inside the mask")
    assert_eq(imgs[2][1], "atlas:jambix_game_roles/tank", "the client's own tank circle")

    -- mask ring, rim, and the role ring: the circle is round, so no badge mask
    assert_eq(count(calls, "circle_2d"), 3, "circles")
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" then assert(not (c[4] and c[4].filled), "no filled circle") end
    end
    assert_eq(count(calls, "text_2d"), 0, "no letters")
end }

T[#T + 1] = { "a guessed role keeps the game circle, ringed at the guess alpha", function()
    local P, calls = bundle({ game = true })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.PALADIN, role = "healer", certain = false, spec = 65 }))
    assert_eq(first(calls, "image")[1], "atlas:jambix_game_classes/PALADIN", "paladin icon")
    local ring
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "circle_2d" and c[4] and c[4].thickness == 1.5 then ring = c end
    end
    assert(ring, "role ring drawn")
    assert_eq(ring[3].a, 165, "guess alpha")
    assert_eq(ring[3].g, cfg.ROLE_RGB.healer[2], "healer green")
end }

T[#T + 1] = { "a sheet missing from the archives falls to the game's own icon", function()
    local P, calls = bundle({ game = true, failed = { [cfg.GAME_CLASS_SHEET.ref] = true,
        [cfg.GAME_ROLE_SHEET.ref] = true } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ class_id = CLASS.MAGE, role = "dps", certain = true, spec = 64 }))
    local imgs = {}
    for i = 1, #calls do if calls[i].name == "image" then imgs[#imgs + 1] = calls[i] end end
    assert_eq(imgs[1][1], "game:Interface/Icons/classicon_mage.blp", "class icon from the archives")
    assert_eq(imgs[2][1], "game:Interface/Icons/" .. cfg.SPEC_ICON[64] .. ".blp", "frost talent icon as the badge")
    assert_eq(count(calls, "text_2d"), 0, "no letters")
end }

T[#T + 1] = { "creatures take their type icon from the archives", function()
    local P, calls = bundle({ game = true })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ is_player = false, category = "normal", creature_type = 6, caster = false }))
    assert_eq(first(calls, "image")[1], "game:Interface/Icons/spell_shadow_raisedead.blp", "undead icon")
end }

T[#T + 1] = { "config: every spec the resolver can answer has a talent icon", function()
    for name, by_role in pairs(cfg.ROLE_SPEC) do
        for role, spec in pairs(by_role) do
            assert(type(cfg.SPEC_ICON[spec]) == "string", name .. " " .. role .. " spec " .. spec .. " has no icon")
        end
    end
    for _, rows in pairs(cfg.ROLE_TELLS) do
        for i = 1, #rows do
            local spec = rows[i][3]
            assert(spec == nil or cfg.SPEC_ICON[spec], "tell spec " .. tostring(spec) .. " has no icon")
        end
    end
    for role in pairs(cfg.ROLE_RGB) do
        assert(cfg.GAME_ROLE_SHEET.cells[role], "no game role circle for " .. role)
    end
    for name in pairs(cfg.CLASS_RGB) do
        assert(cfg.GAME_CLASS_SHEET.cells[name], "no game class cell for " .. name)
    end
end }

return T

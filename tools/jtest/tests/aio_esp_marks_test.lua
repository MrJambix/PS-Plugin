-- Jambix AIO: the fight marks -- cast bar, status line, aggro ring, incoming
-- lines, raid marker, tapped grey, box styles -- and the two places their
-- data comes from: JCore's enemies service (free) and the overlay's own
-- rationed read (the fallback). Plus the threat panel's "you" tag. And the
-- new look (1.88.0): shader rings, the curtain box, pillars on far things,
-- plates and shader bars, and herbs and veins by your gathering skill.
--
-- Driven through a recording draw service, like aio_elements_test. The game
-- clock is scripted through _G.core so cast bars can be checked mid-cast.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")
local make_roles = require("jambix_aio/modules/esp/roles")
local make_elements = require("jambix_aio/modules/esp/elements")
local make_collect = require("jambix_aio/modules/esp/collect")
local make_classify = require("jambix_aio/modules/esp/classify")
local make_panels = require("jambix_aio/modules/esp/panels")

-- --- the client ---------------------------------------------------------------

local clock = { s = 1000.0 }
local spell_name_calls = 0
local SPELLS = { [116] = "Frostbolt", [689] = "Drain Life", [118] = "Polymorph" }

_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
    spell_book = {
        get_spell_name = function(id)
            spell_name_calls = spell_name_calls + 1
            return SPELLS[id] or ""
        end,
    },
    play_sound_by_id = function() end,
    graphics = {
        is_line_of_sight = function() return clock.los ~= false end,
    },
}

local function ms(seconds) return math.floor(seconds * 1000) end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function near(got, want, label)
    if type(got) ~= "number" or math.abs(got - want) > 1e-3 then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- --- the bundle ---------------------------------------------------------------

local PLAYER_GUID, PET_GUID, FRIEND_GUID = "me", "pet", "friend"

local function bundle(opts)
    opts = opts or {}
    local calls = {}
    local function record(name)
        return function(...)
            calls[#calls + 1] = { name = name, ... }
            return true
        end
    end

    local settings = opts.settings or {}
    -- Flat bars unless a test asks for the game's texture: with the shader
    -- look off (1.88.0) the bar tests read unit_bar calls, and the textured
    -- bars have tests of their own.
    if settings.game_bars == nil then settings.game_bars = false end
    local measured = {}
    local draw = {
        theme = { shadow = "shadow", text_dim = "dim", accent = "accent", neutral = "neutral", danger = "danger", warning = "warning" },
        unit_box_corners = record("unit_box_corners"),
        unit_box = record("unit_box"),
        unit_box_3d = record("unit_box_3d"),
        unit_label = record("unit_label"),
        unit_bar = record("unit_bar"),
        text_2d = record("text_2d"),
        line_2d = record("line_2d"),
        rect_2d = record("rect_2d"),
        line_3d = record("line_3d"),
        circle_2d = record("circle_2d"),
        circle_3d = record("circle_3d"),
        ring_3d = record("ring_3d"),
        arc_3d = record("arc_3d"),
        -- JCore 1.13 / 1.15 (1.88.0): curtains, pillars, plates and bars.
        curtain_3d = record("curtain_3d"),
        beacon_3d = record("beacon_3d"),
        plate_2d = record("plate_2d"),
        bar_2d = record("bar_2d"),
        with_alpha = function(c, mul)
            local t = type(c) == "table" and c or {}
            return { r = t.r, g = t.g, b = t.b, a = math.floor((t.a or 255) * mul + 0.5), from = c, mul = mul }
        end,
        blend = function(a, b, t) return { blend = true, from = a, to = b, t = t } end,
        panel = function(origin, w, h, o)
            calls[#calls + 1] = { name = "panel", origin, w, h, o }
            return origin.y + 20
        end,
        measure = function(text, size)
            measured[#measured + 1] = text
            return #text * size * 0.5
        end,
        spell_icon = function(id, pos, size, tint, o)
            calls[#calls + 1] = { name = "spell_icon", id, pos, size, tint, o }
            return opts.spell_icons ~= false
        end,
        unit_anchor = function()
            if opts.anchor == false then return nil end
            return opts.anchor or { x = 400, y = 300 }
        end,
        unit_w2s = function()
            if opts.feet == false then return nil end
            return opts.feet or { x = 400, y = 320 }
        end,
        screen_size = function() return 1920, 1080 end,
        image = function(ref, ...)
            calls[#calls + 1] = { name = "image", ref, ... }
            return true
        end,
    }
    -- A JCore from before the shader calls: everything as it was drawn.
    if opts.old_jcore then
        for _, name in ipairs({ "ring_3d", "curtain_3d", "beacon_3d", "plate_2d", "bar_2d", "with_alpha", "blend" }) do
            draw[name] = nil
        end
    end

    local assets = {
        atlas = function() end,
        addon_installed = function(name)
            return opts.installed == nil or opts.installed[name] == true
        end,
        get = function(ref) return { key = ref, state = opts.art_loading and "loading" or "ready" } end,
        request = function(ref)
            -- As in the game on 2026-10-01: nothing out of the archives (and
            -- so no atlas cut from an archive sheet) ever loads.
            if opts.dead_game and (ref:find("^game:") or ref:find("^atlas:")) then
                return false, { key = ref, state = "failed", dead = true }
            end
            local e = { key = ref, state = opts.art_loading and "loading" or "ready" }
            return not opts.art_loading, e
        end,
    }

    -- Positions by guid: the world the lines are drawn in.
    local positions = opts.positions or {}
    local objects = {}
    local function object(guid)
        local o = objects[guid]
        if not o then
            o = { guid = guid, get_position = function() return positions[guid] end }
            objects[guid] = o
        end
        return o
    end

    local units = {
        health_fraction = function() return 1.0 end,
        aura_index = function() return {} end,
        player = function() return opts.player end,
        player_position = function() return positions[PLAYER_GUID] end,
        position = function(u) return u and positions[u.guid] or nil end,
        by_guid = function(guid) return positions[guid] and object(guid) or nil end,
        guid = function(u) return u and u.guid end,
        combat_reach = function() return opts.reach or 1.5 end,
        distance = function(u) return u and u.distance or 30 end,
        is_dead = function(u) return u ~= nil and u.dead == true end,
        units = function() return opts.unit_list or {} end,
        objects = function() return opts.object_list or {} end,
    }

    local P = {
        cfg = cfg,
        JCore = { assets = assets },
        log = {
            fmt = function(level, ...) if level == "error" then error(string.format(...)) end end,
        },
        ctx = {
            LAYER = { WORLD = 100, UNITS = 200, OVERLAY = 300, HUD = 500 },
            on = function() end,
            emit = function() end,
            ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 },
            enemies = opts.enemies,
            group = opts.group,
            threat = opts.threat,
            player = opts.jplayer,   -- JCore's player service: can_skin (1.67.0)
            geometry = { vec = function(x, y, z) return { x = x, y = y, z = z, vec = true } end },
        },
        units = units,
        draw = draw,
        quests = {
            quest_color = function() return "quest" end,
            quest_entries = (opts.quests and opts.quests.quest_entries) or function() return nil end,
            is_guide_target = (opts.quests and opts.quests.is_guide_target) or function() return false end,
            is_questie_id = (opts.quests and opts.quests.is_questie_id) or function() return false end,
        },
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        master_on = function() return true end,
        combat = opts.target and { target = function() return opts.target end } or nil,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        faded = function(col) return col end,
        class_color = {},
        category_color = { hostile_player = "hostile", normal = "normal", rare = "gold", elite = "orange" },
    }
    P.esp_roles = make_roles(P)
    P.esp_classify = make_classify(P)
    P.esp_collect = make_collect(P)
    P.esp_elements = make_elements(P)
    P.esp_panels = make_panels(P)
    P.esp_collect.player_guid = PLAYER_GUID
    P.measured = measured
    return P, calls, object
end

--- An enemies-service row: the shape JCore's enemies.lua writes.
local function enemy_row(o)
    o = o or {}
    return {
        detailed_at = o.detailed_at or clock.s,
        casting = o.casting,
        target_guid = o.target_guid,
        targeting_me = o.target_guid == PLAYER_GUID,
        targeting_pet = o.target_guid == PET_GUID,
        in_combat = o.in_combat or false,
        control = o.control,
    }
end

--- An enemies service holding the given rows by guid.
local function enemies_with(rows)
    return { get = function(guid) return rows[guid] end }
end

local function entity(opts)
    opts = opts or {}
    local guid = opts.guid or "mob"
    local kind = opts.kind or "unit"
    local obj = opts.obj or {}
    obj.guid = obj.guid or guid
    obj.get_position = obj.get_position or function() return nil end
    return {
        obj = obj,
        guid = guid,
        kind = kind,
        info = kind == "object" and nil or {
            name = opts.name or "Kobold Geomancer",
            level = opts.level or 10,
            classification = opts.classification,
            race_id = opts.race_id,
            hostile = opts.hostile,
            fight = opts.fight,
            fight_sure = opts.fight_sure,
            is_player = opts.is_player == true,
            can_attack = opts.can_attack ~= false,
            reaction = opts.reaction or "hostile",
            tapped = opts.tapped,
            marker = opts.marker,
            mounted = opts.mounted,
            creature_type = 7,
            caster = opts.caster ~= false,
        },
        name = opts.name or "Kobold Geomancer",
        category = opts.category or "normal",
        distance = 30,
        range = 100,
        dead = opts.dead or false,
        lod = opts.lod or "full",
        prio = 30,
        quest_entries = opts.quest_entries,
        guide_goal = opts.guide_goal,
        lootable = opts.lootable,
        skinnable = opts.skinnable,
        badge = opts.badge,
    }
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function first(calls, name)
    for i = 1, #calls do if calls[i].name == name then return calls[i] end end
    return nil
end

--- Every string drawn, in order, through text_2d and unit_label.
local function texts(calls)
    local out = {}
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "text_2d" then out[#out + 1] = c[2]
        elseif c.name == "unit_label" then out[#out + 1] = c[2] end
    end
    return out
end

local function has_text(calls, s)
    local list = texts(calls)
    for i = 1, #list do if list[i] == s then return true end end
    return false
end

--- Any drawn string containing `s`, plainly.
local function has_text_like(calls, s)
    local list = texts(calls)
    for i = 1, #list do if list[i]:find(s, 1, true) then return true end end
    return false
end

--- A pill's backdrop: a soft plate (1.88.0), or the flat filled rectangle
--- of the shader look off or an older JCore. Both take (at, w, h, colour, opts).
local function is_back(r)
    return r.name == "plate_2d" or (r.name == "rect_2d" and r[5] ~= nil and r[5].filled == true)
end

--- The unit_label call drawing exactly `s`, or nil. A pill whose level is
--- drawn in its own colour (1.67.0) is two calls, the level then the rest:
--- that pair answers for `s` as one call centred on its pill's backdrop, in
--- the rest's colour, with the level's own call as `.lead`.
local function label(calls, s)
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "unit_label" then
            if c[2] == s then return c end
            local n = calls[i + 1]
            if n and n.name == "unit_label" and #c[2] < #s and s:sub(1, #c[2]) == c[2]
                and n[2] == s:sub(#c[2] + 1) and n[4].at.y == c[4].at.y then
                local back
                for j = i - 1, 1, -1 do
                    local r = calls[j]
                    if is_back(r) then back = r; break end
                end
                local opts = {}
                for k, v in pairs(n[4]) do opts[k] = v end
                opts.at = { x = back and (back[1].x + back[2] * 0.5) or c[4].at.x, y = c[4].at.y }
                return { name = "unit_label", c[1], s, n[3], opts, lead = c }
            end
        end
    end
    return nil
end

--- The name label's y: everything above it is the stack growing up.
local function name_y(calls, name)
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "unit_label" and c[2] == (name or "Kobold Geomancer") then return c[4].at.y end
    end
    return nil
end

local function draw_one(P, e)
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(e)
end

local T = {}

-- --- the cast bar ---------------------------------------------------------------

local function casting(spell, start_s, end_s, interruptible, channel)
    return { spell_id = spell, channel = channel or false, start_at = ms(start_s),
        end_at = ms(end_s), interruptible = interruptible }
end

T[#T + 1] = { "an interruptible cast: white name, a filling bar, seconds left", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())

    assert(has_text(calls, "Frostbolt  2.0"), "spell named, two seconds left")
    local white = P.esp_elements.cast_color.interruptible
    -- A shader bar (1.88.0): bar_2d(at, w, h, fraction, colour, opts).
    local bars = all(calls, "bar_2d")
    assert_eq(#bars, 1, "one bar: the cast (full health draws no health bar)")
    near(bars[1][4], 1 / 3, "a third of the way through")
    assert_eq(bars[1][5], white, "white bar")
    assert_eq(#all(calls, "unit_bar"), 0, "no flat bar")
    local icon
    for _, im in ipairs(all(calls, "image")) do if im[1] == "spell:116" then icon = im end end
    assert(icon, "the spell's own icon, through the asset registry")
    icon = { 116, icon[2], icon[3] }
    -- the icon sits LEFT of the pill's plate, never on it -- and the plate
    -- casts no shadow over it
    local back
    for _, c in ipairs(all(calls, "plate_2d")) do
        if label(calls, "Frostbolt  2.0") then back = back or c end
    end
    assert(back, "the pill has a backdrop")
    assert(icon[2].x + icon[3] <= back[1].x, "icon clear of the backdrop")
    assert_eq(back[5].shadow, false, "no shadow over the icon beside it")
end }

T[#T + 1] = { "an uninterruptible cast is red", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, false) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())
    assert_eq(first(calls, "bar_2d")[5], P.esp_elements.cast_color.locked, "red bar")
end }

T[#T + 1] = { "a channel drains rather than fills", function()
    clock.s = 1001.0
    local rows = { mob = enemy_row({ casting = casting(689, 1000.0, 1005.0, true, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())
    near(first(calls, "bar_2d")[4], 0.8, "four fifths left")
    assert(has_text(calls, "Drain Life  4.0"), "channel named, four seconds left")
end }

T[#T + 1] = { "a cast whose end has passed is over, whatever the last read said", function()
    clock.s = 1003.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())
    assert(not has_text_like(calls, "Frostbolt"), "no stale cast")
    assert_eq(#all(calls, "bar_2d"), 0, "no bar")
end }

T[#T + 1] = { "a nonsense clock still names the cast, full and without a countdown", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1999.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())
    assert(has_text(calls, "Frostbolt"), "named, and nothing after the name")
    near(first(calls, "bar_2d")[4], 1, "full")
end }

T[#T + 1] = { "a spell the client cannot name is 'Casting'; names are asked once per spell", function()
    clock.s = 1000.0
    spell_name_calls = 0
    local rows = { mob = enemy_row({ casting = casting(99999, 999.5, 1001.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity())
    draw_one(P, entity())
    assert(has_text_like(calls, "Casting"), "fallback name")
    assert_eq(spell_name_calls, 1, "one native call for the session")
end }

T[#T + 1] = { "by default the cast goes under the feet, and the name above does not move", function()
    clock.s = 1000.0
    local P1, quiet = bundle({ enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P1, entity())
    local P2, busy = bundle({ enemies = enemies_with({ mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }) })
    draw_one(P2, entity())
    assert_eq(name_y(busy), name_y(quiet), "name where it was")
    local pill = label(busy, "Frostbolt  2.0")
    assert(pill[4].at.y > 320, "cast pill below the feet (y 320)")
    local bar = first(busy, "bar_2d")
    assert(bar[1].y > pill[4].at.y, "bar under its pill")
end }

T[#T + 1] = { "rows above the head: the stack grows upward while casting", function()
    clock.s = 1000.0
    local above = { esp_rows_below = false }
    local P1, quiet = bundle({ settings = above, enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P1, entity())
    local P2, busy = bundle({ settings = above,
        enemies = enemies_with({ mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }) })
    draw_one(P2, entity())
    local y1, y2 = name_y(quiet), name_y(busy)
    assert(y1 and y2, "name drawn both times")
    assert(y2 < y1, "name higher while casting")
    -- and the cast rows sit below the name, above the head anchor (y = 300)
    local bar = first(busy, "bar_2d")
    assert(bar[1].y > y2 and bar[1].y < 300, "cast bar between the name and the head")
end }

T[#T + 1] = { "a far mark gets no cast bar, and the toggle removes it", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    draw_one(P, entity({ lod = "far" }))
    assert(not has_text_like(calls, "Frostbolt"), "far: no cast")
    local P2, calls2 = bundle({ enemies = enemies_with(rows), settings = { show_cast = false } })
    draw_one(P2, entity())
    assert(not has_text_like(calls2, "Frostbolt"), "off: no cast")
end }

-- --- under the feet ----------------------------------------------------------------

local ME = { get_level = function() return 10 end }

T[#T + 1] = { "details are a bright pill on a dark backdrop, under the feet", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P, entity())
    local details = label(calls, "10  \194\183  30y")
    assert(details, "level and distance drawn")
    assert(details[4].at.y > 320, "under the feet")
    assert(details[4].at.y < name_y(calls) + 100 and details[4].at.y > name_y(calls), "below the name")
    assert_eq(details[3].r, 240, "bright text, not the dim grey")
    assert_eq(details[4].size, 13, "full text size")
    local back
    for _, c in ipairs(all(calls, "plate_2d")) do
        if c[1].y <= details[4].at.y and c[1].y + c[3] >= details[4].at.y then back = c end
    end
    assert(back, "a plate behind it (1.88.0)")
    assert(back[4].a >= 200, "an opaque one")
    assert_eq(back[5].rounding, 3, "rounded as the pill was")
    assert(back[5].shadow ~= false, "with its soft shadow: no icon beside it")
end }

T[#T + 1] = { "the target: line of sight and range as two pills, each in its own colour", function()
    clock.los = true
    local e = entity()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row() }), target = e.obj, player = ME })
    draw_one(P, e)
    local los, range = label(calls, "LoS"), label(calls, "Out of Range")
    assert(los and range, "both pills")
    assert_eq(los[4].at.y, range[4].at.y, "one row")
    assert(los[4].at.x < range[4].at.x, "sight first")
    assert_eq(los[3].g, 200, "green sight")
    assert_eq(range[3].r, 230, "amber range")
    assert(los[4].at.y > 320, "under the feet")

    clock.los = false
    local P2, calls2 = bundle({ enemies = enemies_with({ mob = enemy_row() }), target = e.obj, player = ME })
    draw_one(P2, e)
    assert(label(calls2, "No LoS"), "no sight says so")
    clock.los = nil
end }

T[#T + 1] = { "under the feet the order is cast, target, status, details", function()
    clock.s = 1000.0
    local e = entity()
    local P, calls = bundle({ target = e.obj, player = ME, enemies = enemies_with({ mob = enemy_row({
        casting = casting(116, 999.0, 1002.0, true), target_guid = PLAYER_GUID }) }) })
    draw_one(P, e)
    local cast = label(calls, "Frostbolt  2.0")[4].at.y
    local reach = label(calls, "Out of Range")[4].at.y
    local status = label(calls, "on you")[4].at.y
    local details = label(calls, "10  \194\183  30y")[4].at.y
    assert(cast < reach and reach < status and status < details, string.format(
        "cast %d, reach %d, status %d, details %d", cast, reach, status, details))
end }

T[#T + 1] = { "feet at the bottom edge: the block is lifted to stay on screen", function()
    local P, calls = bundle({ feet = { x = 400, y = 1075 }, enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P, entity())
    local details = label(calls, "10  \194\183  30y")
    assert(details and details[4].at.y + 13 <= 1080 - 8, "the last row is on screen")

    local P2, calls2 = bundle({ feet = false, enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P2, entity())
    local d2 = label(calls2, "10  \194\183  30y")
    assert(d2, "feet off screen: still drawn")
    assert_eq(d2[4].at.x, 400, "under the head instead")
    assert(d2[4].at.y < 1080, "at the bottom of the screen")
end }

T[#T + 1] = { "rows above the head when the option is off", function()
    local P, calls = bundle({ settings = { esp_rows_below = false }, enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P, entity())
    local details = label(calls, "10  \194\183  30y")
    assert(details[4].at.y < 300 and details[4].at.y > name_y(calls), "between the name and the head")
end }

T[#T + 1] = { "text is measured a glyph at a time, once per glyph for the session", function()
    local P = bundle()
    local w1 = P.esp_elements.text_width("30y", 13)
    local n1 = #P.measured
    local w2 = P.esp_elements.text_width("31y", 13)
    assert_eq(#P.measured - n1, 1, "only the new glyph was measured")
    assert_eq(w1, w2, "same width for the same glyph count here")
    P.esp_elements.text_width("10  \194\183  31y", 13)
    for _, t in ipairs(P.measured) do
        assert(#t <= 2, "a glyph, not a string: " .. t)
    end
end }

-- --- the status line -------------------------------------------------------------

T[#T + 1] = { "status: on you, in red", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID, in_combat = true }) }) })
    draw_one(P, entity())
    local label
    for _, c in ipairs(all(calls, "unit_label")) do if c[2] == "on you" then label = c end end
    assert(label, "on you")
    assert_eq(label[3], P.esp_elements.status_color.me, "red")
end }

T[#T + 1] = { "status: crowd control outranks 'on you' and names the spell", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({
        target_guid = PLAYER_GUID, control = { spell_id = 118, remaining = 7.6 } }) }) })
    draw_one(P, entity())
    assert(has_text(calls, "Polymorph 8s"), "the sheep and its clock")
    assert(not has_text(calls, "on you"), "one line, the most urgent")
end }

T[#T + 1] = { "status: on your pet, and on a party member by name", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({ target_guid = PET_GUID }) }) })
    draw_one(P, entity())
    assert(has_text(calls, "on your pet"), "pet")

    local group = { members = function() return { { name = "Thrall", object = { guid = FRIEND_GUID } } } end }
    local P2, calls2 = bundle({ group = group,
        enemies = enemies_with({ mob = enemy_row({ target_guid = FRIEND_GUID }) }) })
    draw_one(P2, entity())
    assert(has_text(calls2, "on Thrall"), "party member by name")
end }

T[#T + 1] = { "status: tapped, in combat, mounted -- and nothing when there is nothing", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({ in_combat = true }) }) })
    draw_one(P, entity({ tapped = true }))
    assert(has_text(calls, "tapped"), "tapped beats in combat")

    local P2, calls2 = bundle({ enemies = enemies_with({ mob = enemy_row({ in_combat = true }) }) })
    draw_one(P2, entity())
    assert(has_text(calls2, "in combat"), "in combat")

    local P3, calls3 = bundle()
    draw_one(P3, entity({ is_player = true, can_attack = false, mounted = true, category = "friendly_player" }))
    assert(has_text(calls3, "mounted"), "a mounted friend, with no detail read at all")

    local P4, calls4 = bundle({ enemies = enemies_with({ mob = enemy_row() }) })
    draw_one(P4, entity())
    for _, t in ipairs(texts(calls4)) do
        assert(t ~= "in combat" and t ~= "tapped" and t ~= "on you", "no status row, saw " .. t)
    end
end }

-- --- on the ground ----------------------------------------------------------------

T[#T + 1] = { "a ring under anything on you, sized to its reach, never droppable", function()
    local positions = { mob = { x = 10, y = 0, z = 0 }, [PLAYER_GUID] = { x = 0, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions, reach = 2.0,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P, entity({ lod = "far" }))
    -- JCore's shader ring (1.88.0): ring_3d(centre, radius, fraction, colour, opts)
    local ring = first(calls, "ring_3d")
    assert(ring, "ring drawn even at the far tier")
    assert_eq(#all(calls, "circle_3d"), 0, "no outline circle")
    near(ring[2], 2.3, "reach plus a little")
    assert_eq(ring[3], 1, "full all the way round")
    assert_eq(ring[4].r, 240, "red")
    assert_eq(ring[4].g, 80, "red")
    assert_eq(ring[4].a, 200, "see-through, alone")
    assert(ring[5].inner >= 0.8 and ring[5].outer == 1.0, "a thin band at the outer edge")
    assert(not ring[5].droppable, "a warning is never dropped")
end }

T[#T + 1] = { "the ring is see-through: a thin band, and a pile of them is fainter", function()
    local positions = { mob = { x = 3, y = 0, z = 0 }, [PLAYER_GUID] = { x = 0, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    local E = P.esp_elements
    E.begin_frame()
    for _ = 1, 6 do E.draw_entity(entity()) end
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 6, "a ring each")
    assert_eq(rings[1][4].a, 200, "the first knows of no pile yet")
    assert_eq(rings[4][4].a, 120, "the fourth: down to 60% of one alone")
    for i = 1, #rings do
        assert(rings[i][5].inner >= 0.8, "a thin band, never a disc")
        assert_eq(rings[i][5].bg.a, 0, "nothing drawn under the fill")
    end
    for i = #calls, 1, -1 do calls[i] = nil end
    E.begin_frame()
    E.draw_entity(entity())
    assert_eq(first(calls, "ring_3d")[4].a, 120, "next frame, six on you: 60% of one alone")
end }

T[#T + 1] = { "an older JCore without ring_3d: the outline circle with its fast fade, as before (1.88.0)", function()
    local positions = { mob = { x = 3, y = 0, z = 0 }, [PLAYER_GUID] = { x = 0, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions, reach = 2.0, old_jcore = true,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P, entity())
    local ring = first(calls, "circle_3d")
    assert(ring, "the outline")
    near(ring[2], 2.3, "reach plus a little")
    assert_eq(ring[3].a, 200, "see-through, alone")
    assert(ring[4].fade >= 5, "a fast fade, not JCore's 1.0 that fills the disc")
    assert(not ring[4].filled, "never filled")
end }

T[#T + 1] = { "a line from an attacker on its way to you, lifted off the ground", function()
    local positions = { mob = { x = 20, y = 0, z = 5 }, [PLAYER_GUID] = { x = 0, y = 0, z = 5 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P, entity())
    local line = first(calls, "line_3d")
    assert(line, "line drawn")
    assert_eq(line[1].x, 20, "from the attacker")
    assert_eq(line[2].x, 0, "to me")
    assert_eq(line[1].z, 6, "lifted a yard")
    assert(line[1].vec, "a real vec3 from the geometry service")
    assert_eq(line[3], P.esp_elements.status_color.me, "red for me")
end }

T[#T + 1] = { "once it has arrived the line goes", function()
    local positions = { mob = { x = 3, y = 0, z = 0 }, [PLAYER_GUID] = { x = 0, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P, entity())
    assert_eq(#all(calls, "line_3d"), 0, "no line in melee")
    assert(first(calls, "ring_3d"), "the ring stays")
end }

T[#T + 1] = { "amber lines to the pet, found by guid; no ring when it is not on you", function()
    local positions = { mob = { x = 30, y = 0, z = 0 }, [PET_GUID] = { x = 0, y = 10, z = 0 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PET_GUID }) }) })
    draw_one(P, entity())
    local line = first(calls, "line_3d")
    assert(line, "line to the pet")
    assert_eq(line[2].y, 10, "ends at the pet")
    assert_eq(line[3], P.esp_elements.status_color.group, "amber")
    assert_eq(#all(calls, "ring_3d") + #all(calls, "circle_3d"), 0, "no aggro ring")
end }

T[#T + 1] = { "nothing it targets is ours: no line, no ring", function()
    local positions = { mob = { x = 30, y = 0, z = 0 }, stranger = { x = 0, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = "stranger" }) }) })
    draw_one(P, entity())
    assert_eq(#all(calls, "line_3d"), 0, "no line")
    assert_eq(#all(calls, "ring_3d") + #all(calls, "circle_3d"), 0, "no ring")
end }

T[#T + 1] = { "quests apart (1.73.0): a quest mark drawn with the ESP off has no ring and no line; back with it on", function()
    local positions = { mob = { x = 20, y = 0, z = 5 }, [PLAYER_GUID] = { x = 0, y = 0, z = 5 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    local E = P.esp_elements
    E.begin_frame(true)
    E.draw_entity(entity({ category = "quest" }))
    assert_eq(#all(calls, "line_3d"), 0, "no line")
    assert_eq(#all(calls, "ring_3d"), 0, "no ring")
    assert(#all(calls, "text_2d") > 0, "the mark itself is drawn")
    E.begin_frame()
    E.draw_entity(entity({ category = "quest" }))
    assert(first(calls, "line_3d") and first(calls, "ring_3d"), "ESP on: the ring and the line")
end }

-- --- what it costs ---------------------------------------------------------------

T[#T + 1] = { "a friendly unit is never read, and five toggles off means no read at all", function()
    local asked = 0
    local enemies = { get = function() asked = asked + 1 return nil end }
    local P = bundle({ enemies = enemies })
    draw_one(P, entity({ can_attack = false, reaction = "friendly" }))
    assert_eq(asked, 0, "friendly: no detail")

    local P2 = bundle({ enemies = enemies, settings = {
        show_cast = false, show_status = false, show_aggro = false, show_target_line = false,
        show_cast_ring = false } })
    draw_one(P2, entity())
    assert_eq(asked, 0, "all off: no detail")

    local P3 = bundle({ enemies = enemies })
    draw_one(P3, entity())
    assert(asked > 0, "on by default, and asked")
end }

-- --- colour, marker, box -----------------------------------------------------------

T[#T + 1] = { "a tapped mob is grey -- even a rare -- unless the toggle is off", function()
    local P, calls = bundle()
    draw_one(P, entity({ tapped = true, category = "rare" }))
    assert_eq(name_y(calls) and first(calls, "unit_label")[3], P.esp_elements.tapped_color, "grey name")

    local P2, calls2 = bundle({ settings = { grey_tapped = false } })
    draw_one(P2, entity({ tapped = true, category = "rare" }))
    assert_eq(first(calls2, "unit_label")[3], "gold", "the rare's own colour")
end }

T[#T + 1] = { "the raid icon tops the stack, from the client's own art", function()
    local P, calls = bundle()
    draw_one(P, entity({ marker = 8, lod = "far" }))
    local img
    for _, c in ipairs(all(calls, "image")) do
        if c[1] == cfg.raid_marker_ref(8) then img = c end
    end
    assert(img, "skull art")
    assert(img[2].y < name_y(calls), "above the name")
end }

T[#T + 1] = { "while the art loads the marker is its name, in its colour", function()
    local P, calls = bundle({ art_loading = true })
    draw_one(P, entity({ marker = 1 }))
    local word
    for _, c in ipairs(all(calls, "text_2d")) do if c[2] == "star" then word = c end end
    assert(word, "the word")
    assert_eq(word[3].g, cfg.RAID_MARKERS[1].rgb[2], "star yellow")
end }

T[#T + 1] = { "box styles: corners by default (again, 1.7.6), a curtain when picked, a full box, a 3D box in the world band", function()
    local positions = { mob = { x = 10, y = 0, z = 0 } }
    local P0, calls0 = bundle({ positions = positions, reach = 1.5, settings = { show_box = true } })
    draw_one(P0, entity())
    assert(first(calls0, "unit_box_corners"), "the brackets by default")
    assert_eq(#all(calls0, "curtain_3d"), 0, "and no curtain")

    local Pc, calls_c = bundle({ positions = positions, reach = 1.5, settings = { show_box = true, box_style = cfg.BOX_CURTAIN } })
    draw_one(Pc, entity())
    assert(first(calls_c, "curtain_3d"), "a curtain when picked")
    assert_eq(#all(calls_c, "unit_box_corners"), 0, "and no brackets")

    local P, calls = bundle({ settings = { show_box = true, box_style = cfg.BOX_CORNERS } })
    draw_one(P, entity())
    assert(first(calls, "unit_box_corners"), "corners")

    local P2, calls2 = bundle({ settings = { show_box = true, box_style = cfg.BOX_FULL } })
    draw_one(P2, entity())
    assert(first(calls2, "unit_box"), "full box")

    local P3, calls3 = bundle({ settings = { show_box = true, box_style = cfg.BOX_3D } })
    draw_one(P3, entity())
    local box = first(calls3, "unit_box_3d")
    assert(box, "3D box")
    assert_eq(box[3].layer, 100, "world band")
end }

T[#T + 1] = { "the curtain box (1.88.0): round the unit in its colour, sized to its reach, short, light", function()
    local positions = { mob = { x = 10, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions, reach = 1.5,
        settings = { show_box = true, box_style = cfg.BOX_CURTAIN } })
    draw_one(P, entity({ category = "rare" }))
    local c = first(calls, "curtain_3d")
    assert(c, "a curtain")
    assert_eq(c[1].x, 10, "at the unit's feet")
    near(c[2], 1.7, "its reach and a little")
    assert_eq(c[3], "gold", "in the mark's colour")
    local o = c[4]
    assert_eq(o.to.from, "gold", "fading from its colour")
    near(o.to.mul, 0.15, "to nearly clear at the top")
    assert_eq(o.height, 2, "short")
    assert_eq(o.points, 16, "16 points"); assert_eq(o.rings, 2, "two rings"); assert_eq(o.verticals, 4, "a line every fourth")
    near(o.fill, 0.18, "a faint sheet")
    assert_eq(o.lod, true, "fewer points far off")
    assert_eq(o.layer, 100, "in the world band")
    assert_eq(o.droppable, true, "the first thing to go on a heavy frame")

    -- A small model: never thinner than 0.8 yd.
    local P2, calls2 = bundle({ positions = positions, reach = 0.2, settings = { show_box = true, box_style = cfg.BOX_CURTAIN } })
    draw_one(P2, entity())
    near(first(calls2, "curtain_3d")[2], 0.8, "at least 0.8")

    -- An older JCore without curtain_3d: the corner brackets.
    local P3, calls3 = bundle({ positions = positions, old_jcore = true, settings = { show_box = true } })
    draw_one(P3, entity())
    assert(first(calls3, "unit_box_corners"), "brackets")
    assert_eq(cfg.BOX_DEFAULT, cfg.BOX_CORNERS, "1.7.6: the corners are the default again")
    assert_eq(cfg.BOX_STYLES[cfg.BOX_CURTAIN], "Curtain", "the curtain named so in the dropdown")
end }

-- --- where the detail comes from -------------------------------------------------

T[#T + 1] = { "detail: a hostile's answer is the enemies row, with no native call", function()
    clock.s = 1000.0
    local touched = 0
    local unit = setmetatable({}, { __index = function() touched = touched + 1 return function() end end })
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, false), target_guid = PLAYER_GUID,
        in_combat = true, control = { spell_id = 118, remaining = 3 } }) }
    local P = bundle({ enemies = enemies_with(rows) })
    local d = P.esp_collect.detail({ kind = "unit", guid = "mob", obj = unit })
    assert_eq(touched, 0, "the unit was not asked anything")
    assert(d.casting and d.spell_id == 116 and d.interruptible == false, "cast copied")
    assert_eq(d.cast_end, ms(1002.0), "end time copied")
    assert(d.targeting_me and d.in_combat, "target and combat")
    assert_eq(d.control.spell_id, 118, "control")
end }

local function native_unit(o)
    local n = { calls = 0 }
    local function f(v) return function() n.calls = n.calls + 1 return v end end
    n.is_casting_spell = f(o.cast or false)
    n.is_channelling_spell = f(o.channel or false)
    n.get_active_channel_spell_id = f(689)
    n.get_active_channel_cast_start_time = f(ms(999))
    n.get_active_channel_cast_end_time = f(ms(1004))
    n.get_target = f(o.target and { get_guid = function() return o.target end } or nil)
    n.is_in_combat = f(o.combat or false)
    return n
end

T[#T + 1] = { "detail: our own read for what the service does not track -- channels are kickable", function()
    clock.s = 1000.0
    local unit = native_unit({ channel = true, target = PLAYER_GUID, combat = true })
    local P = bundle({ enemies = enemies_with({}) })
    P.esp_collect.run(false, 100)   -- sets the per-frame read budget
    P.esp_collect.player_guid = PLAYER_GUID
    local d = P.esp_collect.detail({ kind = "unit", guid = "odd", obj = unit })
    assert(d and d.casting and d.channel, "channel read")
    assert_eq(d.interruptible, true, "a channel is interruptible")
    assert(d.targeting_me, "targeting me")
    assert_eq(d.source, "own", "own read")
end }

T[#T + 1] = { "detail: the own read is rationed and cached", function()
    clock.s = 1000.0
    local P = bundle({ enemies = enemies_with({}), settings = { esp_detail_reads = 1 } })
    P.esp_collect.run(false, 100)
    local a = native_unit({})
    local b = native_unit({})
    P.esp_collect.detail({ kind = "unit", guid = "a", obj = a })
    local db = P.esp_collect.detail({ kind = "unit", guid = "b", obj = b })
    assert(a.calls > 0, "first reader read")
    assert_eq(b.calls, 0, "second reader is over budget")
    assert_eq(db, nil, "and has nothing yet")
    local before = a.calls
    P.esp_collect.detail({ kind = "unit", guid = "a", obj = a })
    assert_eq(a.calls, before, "within the TTL the cached answer is reused")
end }

-- --- classification: the slow facts -------------------------------------------------

local function classify_unit(o)
    local n = { reads = {} }
    local function f(key, v) return function() n.reads[key] = (n.reads[key] or 0) + 1 return v end end
    n.get_name = f("name", "Kobold")
    n.get_level = f("level", 8)
    n.get_classification = f("classification", 0)
    n.get_creature_type = f("type", 7)
    n.get_class = f("class", 1)
    n.get_npc_id = f("npc", 123)
    n.get_race_id = f("race", 0)
    n.is_player = function() return o.player == true end
    n.get_max_power = f("power", 0)
    n.is_tap_denied = f("tap", o.tap)
    n.get_target_marker_index = f("marker", o.marker)
    n.is_mounted = f("mounted", o.mounted)
    return n
end

local player_obj = {
    can_attack = function() return true end,
    is_enemy_with = function() return true end,
    is_friend_with = function() return false end,
}

T[#T + 1] = { "classify: tapped is a non-zero number, marker 0 is none", function()
    local P = bundle()
    local info = P.esp_classify.unit(classify_unit({ tap = 1, marker = 0 }), "t1", player_obj)
    assert_eq(info.tapped, true, "1 is a tag")
    assert_eq(info.marker, nil, "0 is no marker")
    local info2 = P.esp_classify.unit(classify_unit({ tap = 0, marker = 8 }), "t2", player_obj)
    assert_eq(info2.tapped, false, "0 is not a tag")
    assert_eq(info2.marker, 8, "skull")
end }

T[#T + 1] = { "classify: the slow facts are not read while nothing shows them", function()
    local P = bundle({ settings = { grey_tapped = false, show_status = false, show_raid_marker = false } })
    local mob = classify_unit({ tap = 1, marker = 8 })
    P.esp_classify.unit(mob, "t3", player_obj)
    assert_eq(mob.reads.tap, nil, "no tap read")
    assert_eq(mob.reads.marker, nil, "no marker read")
    local rider = classify_unit({ player = true, mounted = true })
    P.esp_classify.unit(rider, "t4", player_obj)
    assert_eq(rider.reads.mounted, nil, "no mount read")

    local P2 = bundle()
    local rider2 = classify_unit({ player = true, mounted = true })
    local info = P2.esp_classify.unit(rider2, "t5", player_obj)
    assert_eq(info.mounted, true, "read while the status line is on")
    assert_eq(rider2.reads.tap, nil, "a player is never asked about a tag")
end }

-- --- the threat panel ------------------------------------------------------------

T[#T + 1] = { "threat panel: what is on you comes first, tagged 'you'", function()
    local rows = { near = enemy_row(), far = enemy_row({ target_guid = PLAYER_GUID }) }
    local player = {
        get_level = function() return 10 end,
        get_position = function() return { x = 0, y = 0, z = 0 } end,
        get_rotation = function() return 0 end,
    }
    local P, calls = bundle({ enemies = enemies_with(rows), player = player })
    local function threat(guid, name, distance)
        return { guid = guid, distance = distance,
            unit = { get_position = function() return { x = distance, y = 0, z = 0 } end },
            info = { name = name, level = 20, category = "elite", tag = "Elite" } }
    end
    local list = P.esp_collect.threats
    list[1] = threat("near", "Near Ogre", 10)
    list[2] = threat("far", "Far Ogre", 30)
    P.esp_panels.draw_threat_panel()

    local lines = {}
    for _, c in ipairs(all(calls, "text_2d")) do lines[#lines + 1] = c end
    assert(lines[1][2]:find("Far Ogre", 1, true), "the one on me is the first row")
    assert_eq(lines[2][2], "you", "tagged")
    assert_eq(lines[2][3], "danger", "in the danger colour")
    assert(lines[3][2]:find("Near Ogre", 1, true), "then the nearest")
    assert_eq(#lines, 3, "one tag only")
end }

T[#T + 1] = { "config: every new mark has a drawer and every marker an art path", function()
    local P = bundle()
    local keys = {}
    for _, el in ipairs(P.esp_elements.active()) do keys[el.key] = true end
    for _, key in ipairs({ "show_cast", "show_status", "show_aggro", "show_target_line", "show_raid_marker",
        "show_cast_ring", "show_beacon" }) do
        assert(keys[key], key .. " has no drawer")
    end
    for i = 1, 8 do
        assert(cfg.RAID_MARKERS[i], "marker " .. i)
        assert(cfg.raid_marker_ref(i):find("UI%-RaidTargetingIcon_" .. i .. "%.blp$"), "art path " .. i)
    end
    assert_eq(#cfg.BOX_STYLES, 4, "four box styles: the curtain added (1.88.0)")
    local beacon = cfg.ELEMENT_BY_KEY.show_beacon
    assert(beacon and beacon.default == false and beacon.kind == "unit" and beacon.lod == "far",
        "the pillars: off by default (1.7.6, a curtain), for units, at every distance")
end }


-- --- tags: why a thing is marked ----------------------------------------------

local function quest_entry(tag, name)
    return { quest = { id = 1, name = name or "Kobold Camp Cleanup" }, tag = tag,
        objective = { have = 2, need = 8 } }
end

--- The chip label calls, in order: unit_label calls whose text is a tag word.
local function chips(calls)
    local words = {}
    for _, t in pairs(cfg.TAGS) do words[t.word] = true end
    local out = {}
    for _, c in ipairs(all(calls, "unit_label")) do
        if words[c[2]] then out[#out + 1] = c end
    end
    return out
end

T[#T + 1] = { "a quest kill target: a yellow KILL chip with Questie's slay icon, then the bare name", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "quest", quest_entries = { quest_entry("kill") } }))
    local c = chips(calls)
    assert_eq(#c, 1, "one chip")
    assert_eq(c[1][2], "KILL", "the word")
    assert_eq(c[1][3], P.esp_elements.tag_color.quest, "quest yellow")

    local name = label(calls, "Kobold Geomancer")
    assert(name, "the name alone, no 'quest' glued to it")
    assert(not has_text_like(calls, "quest Kobold"), "no old prefix")
    assert(c[1][4].at.x < name[4].at.x, "chip before the name")

    local icon
    for _, im in ipairs(all(calls, "image")) do
        if im[1] == "addon:Questie/Icons/slay.blp" then icon = im end
    end
    assert(icon, "Questie's slay icon")
    local back
    for _, r in ipairs(all(calls, "plate_2d")) do
        if r[1].y <= c[1][4].at.y and r[1].x < c[1][4].at.x then back = back or r end
    end
    assert(back, "the chip has a plate (1.88.0)")
    assert(icon[2].x + icon[3] <= back[1].x, "the icon is beside the chip, never on it")
    assert_eq(back[5].border, P.esp_elements.tag_color.quest, "outlined in quest yellow")
    assert_eq(back[5].shadow, false, "and no shadow over the icon beside it")
end }

T[#T + 1] = { "each quest action has its own word and icon", function()
    local want = {
        -- The game's own "!" and "?" first; Questie's are the fallback.
        pick_up = { "PICK UP", "game:Interface/GossipFrame/AvailableQuestIcon.blp" },
        turn_in = { "TURN IN", "game:Interface/GossipFrame/ActiveQuestIcon.blp" },
        collect = { "COLLECT", "addon:Questie/Icons/loot.blp" },
        use     = { "USE",     "addon:Questie/Icons/object.blp" },
    }
    for tag, w in pairs(want) do
        local P, calls = bundle()
        draw_one(P, entity({ category = "quest", quest_entries = { quest_entry(tag) } }))
        assert_eq(chips(calls)[1][2], w[1], tag .. " word")
        local found = false
        for _, im in ipairs(all(calls, "image")) do if im[1] == w[2] then found = true end end
        assert(found, tag .. " icon")
    end
end }

T[#T + 1] = { "a mark serving two quests shows the most pressing: TURN IN over KILL", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "quest",
        quest_entries = { quest_entry("kill", "A"), quest_entry("turn_in", "B") } }))
    local c = chips(calls)
    assert_eq(#c, 1, "one quest chip")
    assert_eq(c[1][2], "TURN IN", "turn-in wins")
end }

T[#T + 1] = { "a world object a quest is handed in at: a TURN IN chip by its name (1.47.5)", function()
    local P, calls = bundle()
    draw_one(P, entity({ kind = "object", category = "quest", name = "Bloodstained Journal",
        quest_entries = { quest_entry("turn_in", "All Done") } }))
    local c = chips(calls)
    assert(c[1], "a chip on the object")
    assert_eq(c[1][2], "TURN IN", "it says TURN IN")
    assert(label(calls, "Bloodstained Journal"), "and its name")
end }

T[#T + 1] = { "Questie's flat id set alone: a plain QUEST chip", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "quest" }))
    assert_eq(chips(calls)[1][2], "QUEST", "plain quest")
end }

T[#T + 1] = { "a corpse: LOOT in green and SKIN in brown, side by side", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "corpse", dead = true, lootable = true, skinnable = true }))
    local c = chips(calls)
    assert_eq(#c, 2, "two chips")
    assert_eq(c[1][2], "LOOT", "loot first")
    assert_eq(c[2][2], "SKIN", "then skin")
    assert_eq(c[1][3], P.esp_elements.tag_color.loot, "green")
    assert_eq(c[2][3], P.esp_elements.tag_color.skin, "brown")
    assert(c[1][3] ~= c[2][3], "two colours")

    local P2, calls2 = bundle()
    draw_one(P2, entity({ category = "corpse", dead = true, badge = "[skin]" }))
    local c2 = chips(calls2)
    assert_eq(#c2, 1, "badge-only corpse: one chip")
    assert_eq(c2[1][2], "SKIN", "from the badge")
end }

T[#T + 1] = { "a guide target: a blue GUIDE chip, the quest's chip, and the guide's own line under the feet", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "guide", guide_goal = { text = "Talk to Devrak", action = "goto" },
        quest_entries = { quest_entry("pick_up", "Ride to Orgrimmar") } }))
    local c = chips(calls)
    assert_eq(#c, 2, "two chips")
    assert_eq(c[1][2], "GUIDE", "guide first")
    assert_eq(c[1][3], P.esp_elements.tag_color.guide, "guide blue")
    assert_eq(c[2][2], "PICK UP", "then what the quest wants")
    local rxp
    for _, im in ipairs(all(calls, "image")) do
        if im[1] == "addon:RXPGuides/Textures/rxp_logo-64.blp" then rxp = im end
    end
    assert(rxp, "RestedXP's logo")

    local line = label(calls, "Talk to Devrak")
    assert(line, "the guide's line")
    assert_eq(line[3], P.esp_elements.tag_color.guide, "in guide blue")
    assert(line[4].at.y > 320, "under the feet")
end }

T[#T + 1] = { "four families, four different colours", function()
    local P = bundle()
    local seen = {}
    for family, col in pairs(P.esp_elements.tag_color) do
        local key = col.r .. "," .. col.g .. "," .. col.b
        assert(not seen[key], family .. " shares a colour with " .. tostring(seen[key]))
        seen[key] = family
    end
end }

T[#T + 1] = { "without Questie the chip still says what it is, with no icon", function()
    local P, calls = bundle({ installed = {} })
    draw_one(P, entity({ category = "quest", quest_entries = { quest_entry("kill") } }))
    assert_eq(chips(calls)[1][2], "KILL", "the word")
    for _, im in ipairs(all(calls, "image")) do
        assert(not im[1]:find("Questie", 1, true), "no Questie icon without Questie")
    end
end }

T[#T + 1] = { "tags switched off: the name alone, as before", function()
    local P, calls = bundle({ settings = { show_tags = false } })
    draw_one(P, entity({ category = "quest", quest_entries = { quest_entry("kill") } }))
    assert_eq(#chips(calls), 0, "no chips")
    assert(label(calls, "Kobold Geomancer"), "name drawn")
end }

T[#T + 1] = { "the chip row is taller than a name, and the stack makes room for it", function()
    local P1, plain = bundle()
    draw_one(P1, entity({ category = "normal" }))
    local P2, tagged = bundle()
    draw_one(P2, entity({ category = "quest", quest_entries = { quest_entry("kill") } }))
    -- the portrait (first circle) sits higher when the name row is a chip row
    local y1 = first(plain, "circle_2d")[1].y
    local y2 = first(tagged, "circle_2d")[1].y
    assert(y2 < y1, "stack lifted by the taller row")
end }

-- --- the collector: never a player -----------------------------------------------

local function world_unit(guid, name, is_player)
    local function v(x) return function() return x end end
    return {
        guid = guid, distance = 20,
        get_name = v(name), get_level = v(22), get_classification = v(0),
        get_creature_type = v(7), get_class = v(1), get_npc_id = v(3615),
        get_race_id = v(2), is_player = v(is_player), get_max_power = v(0),
        is_tap_denied = v(0), get_target_marker_index = v(0), is_mounted = v(false),
    }
end

T[#T + 1] = { "a player is never a quest or guide target, however its name or id matches", function()
    local me = {
        get_guid = function() return PLAYER_GUID end,
        get_level = function() return 22 end,
        can_attack = function() return true end,
        is_enemy_with = function() return true end,
        is_friend_with = function() return false end,
    }
    local everything = {
        quest_entries = function() return { quest_entry("kill") } end,
        is_guide_target = function() return true, { text = "Talk to Devrak" } end,
        is_questie_id = function() return true end,
    }
    local P = bundle({ player = me, quests = everything,
        unit_list = { world_unit("p1", "Kawahmwhaz", true), world_unit("n1", "Devrak", false) } })
    P.esp_collect.run(true, 100)

    local by = {}
    local list = P.esp_collect.entities()
    for i = 1, P.esp_collect.count() do by[list[i].guid] = list[i] end
    assert(by.p1, "the player is marked")
    assert_eq(by.p1.category, "hostile_player", "as a player")
    assert_eq(by.p1.quest_entries, nil, "no quest entries")
    assert_eq(by.p1.guide_goal, nil, "no guide goal")
    assert(by.n1, "the npc is marked")
    assert_eq(by.n1.category, "guide", "the npc still can be")
    assert_eq(by.n1.guide_goal.text, "Talk to Devrak", "with the goal")
end }


T[#T + 1] = { "corpses: SKIN only when your Skinning reaches it; else not marked, not handed on (1.67.0)", function()
    local me = {
        get_guid = function() return PLAYER_GUID end,
        get_level = function() return 22 end,
        can_attack = function() return true end,
        is_enemy_with = function() return true end,
        is_friend_with = function() return false end,
    }
    local function corpse(guid, level)
        local u = world_unit(guid, "Plainstrider", false)
        u.get_level = function() return level end
        u.dead, u.distance = true, 8
        u.can_be_skinned = function() return true end
        u.has_skin = function() return true end
        u.can_be_looted = function() return false end
        u.has_loot = function() return false end
        return u
    end
    -- Skinning 60: level 16 asks 60, level 17 asks 70.
    local jplayer = { can_skin = function(level) return level <= 16 end }
    local P = bundle({ player = me, jplayer = jplayer, unit_list = { corpse("ok", 16), corpse("high", 17) } })
    P.esp_collect.run(true, 100)
    local by = {}
    local list = P.esp_collect.entities()
    for i = 1, P.esp_collect.count() do by[list[i].guid] = list[i] end
    assert(by.ok and by.ok.skinnable, "level 16: marked, SKIN")
    assert(not by.high, "level 17: not marked at all")
    local corpses = P.esp_collect.corpses()
    assert_eq(#corpses, 1, "the automation is handed only the one")
    assert_eq(corpses[1].guid, "ok", "the level 16")

    local P2 = bundle({ player = me, unit_list = { corpse("high", 17) } })
    P2.esp_collect.run(true, 100)
    assert_eq(P2.esp_collect.count(), 1, "an older JCore, no can_skin: as before")
end }

T[#T + 1] = { "the level in its target frame's colour, on what you can attack; plain on what you cannot (1.67.0)", function()
    local bands = { [2] = "trivial", [6] = "easy", [12] = "even", [13] = "hard", [15] = "impossible" }
    for level, band in pairs(bands) do
        local P, calls = bundle({ player = ME })
        draw_one(P, entity({ level = level }))
        local details = label(calls, level .. "  \194\183  30y")
        assert(details and details.lead, "level " .. level .. ": drawn on its own")
        local rgb = cfg.LEVEL_RGB[band]
        assert_eq(details.lead[3].r, rgb[1], "level " .. level .. " is " .. band)
        assert_eq(details.lead[3].g, rgb[2], "level " .. level .. " is " .. band)
        assert_eq(details[3].r, 240, "the rest in the pill's own bright text")
    end
    local P, calls = bundle({ player = ME })
    draw_one(P, entity({ can_attack = false, reaction = "friendly" }))
    local plain = label(calls, "10  \194\183  30y")
    assert(plain and not plain.lead, "a friendly level: one plain string, as the frame paints it")
end }

-- --- reaction colours ---------------------------------------------------------------

T[#T + 1] = { "the reaction word is its own pill: green friendly, orange neutral, red hostile", function()
    assert_eq(cfg.REACTION_RGB.neutral[1], 245, "neutral is orange (red channel)")
    assert_eq(cfg.REACTION_RGB.neutral[2], 150, "neutral is orange (green channel)")
    for _, reaction in ipairs({ "friendly", "neutral", "hostile" }) do
        local P, calls = bundle({ settings = { show_reaction_tag = true } })
        draw_one(P, entity({ reaction = reaction }))
        local word = label(calls, reaction)
        assert(word, reaction .. " drawn")
        assert_eq(word[3], P.esp_elements.reaction_color[reaction], reaction .. " in its colour")
        local details = label(calls, "10  \194\183  30y")
        assert(details, "the facts, without the word")
        assert_eq(details[4].at.y, word[4].at.y, "one row")
        assert(details[4].at.x < word[4].at.x, "word after the facts")
    end
end }

-- --- mana ---------------------------------------------------------------------------

local function caster_obj(cur, max)
    local o = { reads = 0 }
    o.get_power = function() o.reads = o.reads + 1 return cur end
    o.get_max_power = function() return max end
    return o
end

T[#T + 1] = { "a caster's mana: a blue bar under the health bar, and the percentage once some is gone", function()
    local obj = caster_obj(30, 100)
    local P, calls = bundle()
    draw_one(P, entity({ obj = obj }))
    local bar
    for _, b in ipairs(all(calls, "bar_2d")) do
        if b[4] > 0.29 and b[4] < 0.31 then bar = b end
    end
    assert(bar, "a mana bar at 30%")
    assert_eq(bar[5].b, 240, "blue")
    assert(label(calls, "10  \194\183  30y  \194\183  30% mana"), "mana on the details")
end }

T[#T + 1] = { "full mana: no bar unless bars are always on; no mana pool: never asked", function()
    local P, calls = bundle()
    draw_one(P, entity({ obj = caster_obj(100, 100) }))
    assert_eq(#all(calls, "bar_2d"), 0, "a full pool says nothing")

    local P2, calls2 = bundle({ settings = { bar_always = true } })
    draw_one(P2, entity({ obj = caster_obj(100, 100) }))
    assert_eq(#all(calls2, "bar_2d"), 2, "health and mana, both full")

    local melee = caster_obj(0, 0)
    local P3 = bundle()
    draw_one(P3, entity({ obj = melee, caster = false }))
    assert_eq(melee.reads, 0, "a mob without a mana pool is not asked")
end }

T[#T + 1] = { "mana is read once and kept a moment, not every frame", function()
    clock.s = 2000.0
    local obj = caster_obj(30, 100)
    local P = bundle()
    draw_one(P, entity({ obj = obj }))
    draw_one(P, entity({ obj = obj }))
    assert_eq(obj.reads, 1, "cached")
    clock.s = 2001.0
    draw_one(P, entity({ obj = obj }))
    assert_eq(obj.reads, 2, "re-read once stale")
end }

-- --- nameplates ----------------------------------------------------------------------

-- The bundle's head anchor is (400, 300) and its screen is 1920 x 1080. A
-- plate centred on x = 400 whose top edge is at overlay y = 290: in pixels,
-- bottom-left origin, 60 wide and 12 tall.
local function plate_obj(plate)
    return { get_nameplate = function() return plate end }
end
local PLATE_PX = { is_shown = true, left = 370, bottom = 778, width = 60, height = 12 }

local ABOVE = { esp_plate_mode = cfg.PLATE_ABOVE }
local QUEST_KILL = { { quest = { id = 1, name = "Q" }, tag = "kill" } }

T[#T + 1] = { "by default, with a plate up, the whole mark moves under the feet and the plate keeps the name", function()
    local P, calls = bundle()
    draw_one(P, entity({ obj = plate_obj(PLATE_PX), category = "quest", quest_entries = QUEST_KILL }))
    local ring = first(calls, "circle_2d")
    assert(ring, "portrait drawn")
    assert(ring[1].y > 320, "portrait under the feet (y 320)")
    local chip = label(calls, "KILL")
    assert(chip and chip[4].at.y > ring[1].y, "the tag chip under the portrait")
    assert(not label(calls, "Kobold Geomancer"), "the plate has the name")
    local details = label(calls, "10  \194\183  30y")
    assert(details and details[4].at.y > chip[4].at.y, "then the information rows")
end }

T[#T + 1] = { "a plate seen only through its nameplate token still moves the mark", function()
    _G.core.object_manager = {
        get_object_from_guid = function(token)
            if token == "nameplate3" then return { guid = "mob" } end
            return nil
        end,
    }
    local P, calls = bundle()
    P.esp_elements.begin_frame()     -- scans nameplate1..5
    P.esp_elements.draw_entity(entity())
    _G.core.object_manager = nil
    local ring = first(calls, "circle_2d")
    assert(ring and ring[1].y > 320, "portrait under the feet")
    assert(not label(calls, "Kobold Geomancer"), "deferred to the plate")

    -- and a unit wearing no token stays above the head
    local P2, calls2 = bundle()
    P2.esp_elements.begin_frame()
    P2.esp_elements.draw_entity(entity({ guid = "other" }))
    assert(first(calls2, "circle_2d")[1].y < 300, "no plate: above the head")
end }

T[#T + 1] = { "on top of the plate: above its top edge, the plate keeps the name", function()
    local P, calls = bundle({ settings = ABOVE })
    draw_one(P, entity({ obj = plate_obj(PLATE_PX), category = "quest", quest_entries = QUEST_KILL }))
    local ring = first(calls, "circle_2d")
    assert(ring[1].y < 290 - 4, "portrait above the plate's top edge")
    assert(not label(calls, "Kobold Geomancer"), "the plate has the name")
    local chip = label(calls, "KILL")
    assert(chip and chip[4].at.y < 290, "chip above the plate")
end }

T[#T + 1] = { "on top: a rectangle in UI units is recognised by the UI scale", function()
    _G.core.game_ui = { get_effective_scale = function() return 0.5 end }
    local plate = { is_shown = true, left = 740, bottom = 1556, width = 120, height = 24 }
    local P, calls = bundle({ settings = ABOVE })
    draw_one(P, entity({ obj = plate_obj(plate) }))
    _G.core.game_ui = nil
    local ring = first(calls, "circle_2d")
    assert(ring[1].y < 290 - 4, "portrait above the plate, scale applied")
    assert(not label(calls, "Kobold Geomancer"), "deferred to the plate")
end }

T[#T + 1] = { "on top, but the rectangle makes no sense: under the feet instead", function()
    local far = { is_shown = true, left = 1500, bottom = 778, width = 60, height = 12 }
    local P, calls = bundle({ settings = ABOVE })
    draw_one(P, entity({ obj = plate_obj(far) }))
    assert(first(calls, "circle_2d")[1].y > 320, "the plate is up, its rectangle unusable: below")
end }

T[#T + 1] = { "no plate or a hidden one: the stack as before", function()
    local P0, base = bundle()
    draw_one(P0, entity())
    local y0 = name_y(base)
    local hidden = { is_shown = false, left = 370, bottom = 778, width = 60, height = 12 }
    for _, settings in ipairs({ {}, ABOVE }) do
        local P, calls = bundle({ settings = settings })
        draw_one(P, entity({ obj = plate_obj(hidden) }))
        assert_eq(name_y(calls), y0, "name where it was")
    end
end }

T[#T + 1] = { "plate options: left above the head, or keeping the name", function()
    local P, calls = bundle({ settings = { esp_plate_mode = cfg.PLATE_IGNORE } })
    draw_one(P, entity({ obj = plate_obj(PLATE_PX) }))
    local name = label(calls, "Kobold Geomancer")
    assert(name and name[4].at.y < 300, "ignored: the stack as before")

    local P2, calls2 = bundle({ settings = { esp_plate_defer = false } })
    draw_one(P2, entity({ obj = plate_obj(PLATE_PX) }))
    local kept = label(calls2, "Kobold Geomancer")
    assert(kept and kept[4].at.y > 320, "kept, and under the feet with the rest")
end }

-- --- dead ------------------------------------------------------------------------------

T[#T + 1] = { "a dead unit's pill says dead, in grey, whatever the reaction setting", function()
    local P, calls = bundle()
    draw_one(P, entity({ category = "corpse", dead = true, lootable = true, reaction = "neutral" }))
    local dead = label(calls, "dead")
    assert(dead, "dead drawn")
    assert_eq(dead[3], P.esp_elements.reaction_color.dead, "grey")
    assert(not label(calls, "neutral"), "not its reaction")
    local details = label(calls, "30y")
    assert(details and details[4].at.y == dead[4].at.y, "on the details row")
    assert(not label(calls, "10  \194\183  30y") and not label(calls, "10"), "no level on a corpse (1.67.0)")

    local P2, calls2 = bundle({ settings = { show_reaction_tag = true } })
    draw_one(P2, entity({ category = "corpse", dead = true, lootable = true, reaction = "hostile" }))
    assert(label(calls2, "dead"), "dead with the words on too")
    assert(not label(calls2, "hostile"), "and not hostile")
end }

-- --- declutter ---------------------------------------------------------------------

local DETAILS = "10  \194\183  30y"

--- Every details pill drawn, whole or as its level and the rest (1.67.0).
local function details_rows(calls)
    local out = {}
    local labels = all(calls, "unit_label")
    for i, c in ipairs(labels) do
        if c[2] == DETAILS then
            out[#out + 1] = c
        elseif c[2] == "10" and labels[i + 1] and "10" .. labels[i + 1][2] == DETAILS then
            out[#out + 1] = labels[i + 1]
        end
    end
    return out
end

T[#T + 1] = { "two marks on one spot: the second block moves clear of the first", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ guid = "a" }))
    P.esp_elements.draw_entity(entity({ guid = "b" }))
    local rows = details_rows(calls)
    assert_eq(#rows, 2, "both drawn")
    assert(rows[2][4].at.y >= rows[1][4].at.y + 13 + 4, "the second is a full row lower")

    local P2, calls2 = bundle({ settings = { esp_declutter = false } })
    P2.esp_elements.begin_frame()
    P2.esp_elements.draw_entity(entity({ guid = "a" }))
    P2.esp_elements.draw_entity(entity({ guid = "b" }))
    local rows2 = details_rows(calls2)
    assert_eq(rows2[1][4].at.y, rows2[2][4].at.y, "declutter off: on top of each other")
end }

T[#T + 1] = { "no room for the whole block: only its urgent rows, a little further down", function()
    local quests = {}
    for i = 1, 3 do quests[i] = { quest = { id = i, name = "Quest " .. i }, tag = "kill" } end
    local rows = { b = enemy_row({ target_guid = PLAYER_GUID }) }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    P.esp_elements.begin_frame()
    -- a tall block first: details and three quest lines
    P.esp_elements.draw_entity(entity({ guid = "a", category = "quest", quest_entries = quests }))
    -- then one with "on you" and details on the same spot
    P.esp_elements.draw_entity(entity({ guid = "b" }))
    assert(label(calls, "on you"), "the urgent row made it")
    assert_eq(#details_rows(calls), 1, "its details did not")
end }

T[#T + 1] = { "no room at all: the block waits rather than printing over another", function()
    local rows = { b = enemy_row({ target_guid = PLAYER_GUID }) }
    local P, calls = bundle({ feet = { x = 400, y = 1060 }, enemies = enemies_with(rows) })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ guid = "a" }))
    P.esp_elements.draw_entity(entity({ guid = "b" }))
    assert_eq(#details_rows(calls), 1, "only the first block")
    assert(not label(calls, "on you"), "the second waited")
end }

T[#T + 1] = { "the selected target is laid out first, ahead of every category", function()
    local me = {
        get_guid = function() return PLAYER_GUID end,
        get_level = function() return 22 end,
        can_attack = function() return true end,
        is_enemy_with = function() return true end,
        is_friend_with = function() return false end,
    }
    local boar = world_unit("boar", "Plainstrider", false)
    local P = bundle({ player = me, target = boar,
        quests = { quest_entries = function(_, name)
            if name == "Quest Mob" then return { { quest = { id = 1, name = "Q" }, tag = "kill" } } end
        end },
        unit_list = { world_unit("q", "Quest Mob", false), boar } })
    P.esp_collect.run(true, 100)
    assert_eq(P.esp_collect.entities()[1].guid, "boar", "the target first, ahead of a quest mob")
end }

-- --- categories ------------------------------------------------------------------------

local function side_unit(o)
    local u = classify_unit({ player = o.player })
    u.is_party_member = function() return o.party == true end
    u.is_pet = function() return o.pet == true end
    u.is_minion = function() return o.minion == true end
    u.attackable = o.attackable
    u.friend = o.friend
    return u
end

local judge = {
    can_attack = function(_, u) return u.attackable == true end,
    is_enemy_with = function(_, u) return u.attackable == true and not u.friend end,
    is_friend_with = function(_, u) return u.friend == true end,
}

T[#T + 1] = { "classify: party members, pets and minions, and NPCs you cannot attack each have a category", function()
    local P = bundle()
    local function cat(guid, o) return P.esp_classify.unit(side_unit(o), guid, judge).category end
    assert_eq(cat("c1", { player = true, party = true, friend = true }), "party", "a party member")
    assert_eq(cat("c2", { player = true, friend = true }), "friendly_player", "a stranger")
    assert_eq(cat("c3", { pet = true, friend = true }), "pet", "a pet")
    assert_eq(cat("c4", { minion = true, attackable = true }), "pet", "an enemy minion is a pet too")
    assert_eq(cat("c5", { friend = true }), "friendly_npc", "a guard")
    assert_eq(cat("c6", {}), "friendly_npc", "a neutral you cannot attack")
    assert_eq(cat("c7", { attackable = true }), "normal", "an attackable mob")
    for _, key in ipairs({ "party", "pet", "friendly_npc" }) do
        local c = cfg.CATEGORY_BY_KEY[key]
        assert(c, key .. " is a category")
        assert_eq(c.on, false, key .. " ships off")
    end
end }

T[#T + 1] = { "a pet is never a quest target either", function()
    local me = {
        get_guid = function() return PLAYER_GUID end,
        get_level = function() return 22 end,
        can_attack = function() return false end,
        is_enemy_with = function() return false end,
        is_friend_with = function() return true end,
    }
    local pet = world_unit("p", "Boar", false)
    pet.is_pet = function() return true end
    local P = bundle({ player = me, settings = { pet_on = true },
        quests = { quest_entries = function() return { { quest = { id = 1, name = "Q" }, tag = "kill" } } end,
            is_guide_target = function() return true, { text = "x" } end,
            is_questie_id = function() return true end },
        unit_list = { pet } })
    P.esp_collect.run(true, 100)
    local e = P.esp_collect.entities()[1]
    assert(e, "the pet is marked, its category switched on")
    assert_eq(e.category, "pet", "as a pet")
    assert_eq(e.quest_entries, nil, "no quest")
end }


-- --- the game's own art ----------------------------------------------------------

local ME10 = { get_level = function() return 10 end }

--- The left edge of a centred label, by the bundle's measure (half the size
--- per glyph): the name starts here, so nothing may end past it.
local function left_edge(c)
    return c[4].at.x - (#c[2] * c[4].size * 0.5) / 2
end

--- The image drawn with `ref`, or nil.
local function image_of(calls, ref)
    for _, c in ipairs(all(calls, "image")) do if c[1] == ref then return c end end
    return nil
end

T[#T + 1] = { "badges: the skull for a boss, the gold dragon for an elite, before the name", function()
    local P, calls = bundle({ player = ME10 })
    draw_one(P, entity({ classification = cfg.CLASS_WORLD_BOSS }))
    local skull = image_of(calls, cfg.GAME_UI.skull)
    assert(skull, "the target frame's skull")
    local name = label(calls, "Kobold Geomancer")
    assert(skull[2].x + skull[3] <= left_edge(name), "before the name, not on it")

    local P2, calls2 = bundle({ player = ME10 })
    draw_one(P2, entity({ classification = cfg.CLASS_ELITE }))
    assert(image_of(calls2, "atlas:jambix_ui_elite/dragon"), "the nameplate's elite dragon")

    local P3, calls3 = bundle({ player = ME10 })
    draw_one(P3, entity({ classification = cfg.CLASS_RARE_ELITE }))
    assert(image_of(calls3, "atlas:jambix_ui_elite/dragon"), "a rare elite too")
end }

T[#T + 1] = { "badges: danger first -- an elite ten levels up gets the skull, a ?? too", function()
    local P, calls = bundle({ player = ME10 })
    draw_one(P, entity({ classification = cfg.CLASS_ELITE, level = 20 }))
    assert(image_of(calls, cfg.GAME_UI.skull), "skull")
    assert(not image_of(calls, "atlas:jambix_ui_elite/dragon"), "not the dragon")

    local P2, calls2 = bundle({ player = ME10 })
    draw_one(P2, entity({ level = -1 }))
    assert(image_of(calls2, cfg.GAME_UI.skull), "?? is a skull")

    local P3, calls3 = bundle({ player = ME10 })
    draw_one(P3, entity({ level = 19 }))
    assert(not image_of(calls3, cfg.GAME_UI.skull), "nine levels up is not")
end }

T[#T + 1] = { "badges: a hostile player's faction emblem; none on a friendly one", function()
    local P, calls = bundle({ player = ME10 })
    draw_one(P, entity({ is_player = true, hostile = true, race_id = 2, category = "hostile_player" }))
    assert(image_of(calls, "atlas:jambix_ui_horde/emblem"), "an orc: Horde")

    local P2, calls2 = bundle({ player = ME10 })
    draw_one(P2, entity({ is_player = true, hostile = true, race_id = 4, category = "hostile_player" }))
    assert(image_of(calls2, "atlas:jambix_ui_alliance/emblem"), "a night elf: Alliance")

    local P3, calls3 = bundle({ player = ME10 })
    draw_one(P3, entity({ is_player = true, hostile = false, race_id = 2, can_attack = false,
        category = "friendly_player" }))
    assert(not image_of(calls3, "atlas:jambix_ui_horde/emblem"), "a friend: no emblem")
end }

T[#T + 1] = { "badges: a gathering node carries its profession's icon", function()
    local want = { herb = "trade_herbalism", ore = "trade_mining", container = "inv_box_02" }
    for kind, slug in pairs(want) do
        local P, calls = bundle()
        draw_one(P, entity({ kind = "object", category = kind, name = "Peacebloom" }))
        local icon = image_of(calls, "game:Interface/Icons/" .. slug .. ".blp")
        assert(icon, kind .. ": the archive icon")
        local name = label(calls, "Peacebloom")
        assert(name and icon[2].x + icon[3] <= left_edge(name), kind .. ": before the name, not on it")
    end
end }

T[#T + 1] = { "badges: switched off, or still loading: the name alone", function()
    local P, calls = bundle({ player = ME10, settings = { show_badges = false } })
    draw_one(P, entity({ classification = cfg.CLASS_WORLD_BOSS }))
    assert(not image_of(calls, cfg.GAME_UI.skull), "off")

    local P2, calls2 = bundle({ player = ME10, art_loading = true })
    draw_one(P2, entity({ classification = cfg.CLASS_WORLD_BOSS }))
    assert(not image_of(calls2, cfg.GAME_UI.skull), "loading")
    assert(label(calls2, "Kobold Geomancer"), "the name still drawn")
end }

T[#T + 1] = { "the combat swords and the crowd control's own icon sit beside their pills", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({ in_combat = true }) }) })
    draw_one(P, entity())
    local swords = image_of(calls, "atlas:jambix_ui_state/combat")
    assert(swords, "the game's combat swords")
    local pill = label(calls, "in combat")
    local back
    for _, r in ipairs(all(calls, "plate_2d")) do
        if r[1].y <= pill[4].at.y and r[1].y + r[3] >= pill[4].at.y then back = r end
    end
    assert(back and swords[2].x + swords[3] <= back[1].x, "beside the pill, never on it")
    assert_eq(back[5].shadow, false, "the plate's shadow does not reach over it")

    local P2, calls2 = bundle({ enemies = enemies_with({ mob = enemy_row({
        control = { spell_id = 118, remaining = 5 } }) }) })
    draw_one(P2, entity())
    assert(image_of(calls2, "spell:118"), "Polymorph's own icon, through the asset registry")
end }

T[#T + 1] = { "bars in the game's texture, with the shader look off: a dark backing, the fill cut to the fraction, an outline", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }
    local P, calls = bundle({ enemies = enemies_with(rows), settings = { game_bars = true, esp_shader_look = false } })
    draw_one(P, entity())
    assert_eq(#all(calls, "unit_bar"), 0, "no flat bar")
    assert_eq(#all(calls, "bar_2d"), 0, "no shader bar")
    local bars = {}
    for _, c in ipairs(all(calls, "image")) do
        if c[1] == cfg.GAME_UI.status_bar then bars[#bars + 1] = c end
    end
    assert_eq(#bars, 2, "backing and fill")
    local backing, fill = bars[1], bars[2]
    assert_eq(backing[2].x, fill[2].x, "one left edge")
    near(fill[3], backing[3] / 3, "a third of the width")
    local uv = fill[6].uv
    assert(uv and uv[1] == 0 and uv[2] == 0 and math.abs(uv[3] - 1 / 3) < 1e-3 and uv[4] == 1,
        "the texture cut, not squeezed")
    assert_eq(fill[5], P.esp_elements.cast_color.interruptible, "tinted white")

    local P2, calls2 = bundle({ enemies = enemies_with(rows), settings = { game_bars = true, esp_shader_look = false },
        art_loading = true })
    draw_one(P2, entity())
    assert_eq(#all(calls2, "unit_bar"), 1, "the flat bar until the texture has loaded")

    -- The shader look on (1.88.0): the textured bar is a shader bar too.
    local P3, calls3 = bundle({ enemies = enemies_with(rows), settings = { game_bars = true } })
    draw_one(P3, entity())
    assert_eq(#all(calls3, "bar_2d"), 1, "one shader bar")
    for _, c in ipairs(all(calls3, "image")) do
        assert(c[1] ~= cfg.GAME_UI.status_bar, "no texture under it")
    end
end }

T[#T + 1] = { "the swords are on 'on you' too, when it is fighting -- and not when it is not", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row({
        target_guid = PLAYER_GUID, in_combat = true }) }) })
    draw_one(P, entity())
    assert(label(calls, "on you"), "on you")
    assert(image_of(calls, "atlas:jambix_ui_state/combat"), "with the swords")

    local P2, calls2 = bundle({ enemies = enemies_with({ mob = enemy_row({ target_guid = PLAYER_GUID }) }) })
    draw_one(P2, entity())
    assert(not image_of(calls2, "atlas:jambix_ui_state/combat"), "targeting, not fighting: no swords")
end }

T[#T + 1] = { "archives unreadable, as in the game: every picture has a stand-in that loads", function()
    -- The shader look off, for the bar texture's stand-in at the end.
    local o = { player = ME10, dead_game = true, settings = { game_bars = true, esp_shader_look = false } }

    local P, calls = bundle(o)
    draw_one(P, entity({ classification = cfg.CLASS_WORLD_BOSS }))
    local skull = image_of(calls, "addon:Plater/media/skullbones_64.tga")
    assert(skull, "Plater's skull")
    assert_eq(skull[5].r, 230, "tinted pale")

    local P2, calls2 = bundle(o)
    draw_one(P2, entity({ is_player = true, hostile = true, race_id = 2, category = "hostile_player" }))
    assert(image_of(calls2, "addon:Questie/Icons/icon_horde.tga"), "Questie's Horde emblem")

    local P3, calls3 = bundle(o)
    draw_one(P3, entity({ classification = cfg.CLASS_ELITE }))
    assert(image_of(calls3, "icon:inv_misc_head_dragon_01"), "a dragon from the web icons")

    local P4, calls4 = bundle({ dead_game = true, enemies = enemies_with({ mob = enemy_row({ in_combat = true }) }) })
    draw_one(P4, entity())
    assert(image_of(calls4, "icon:ability_dualwield"), "crossed swords from the web icons")

    local P5, calls5 = bundle({ dead_game = true })
    draw_one(P5, entity({ marker = 4 }))
    local tri = image_of(calls5, "addon:Plater/media/triangle_64.tga")
    assert(tri, "Plater's triangle")
    assert_eq(tri[5].g, cfg.RAID_MARKERS[4].rgb[2], "in the triangle's green")
    local uv = tri[6].uv
    assert(uv and uv[2] == 1 and uv[4] == 0, "turned the right way up")
    assert(not has_text(calls5, "triangle"), "a picture, not the word")

    local P6, calls6 = bundle(o)
    clock.s = 1000.0
    draw_one(P6, entity({ obj = caster_obj(30, 100) }))
    assert(image_of(calls6, "addon:WeakAuras/Media/Textures/Statusbar_Clean.blp"), "WeakAuras' bar texture")
end }

T[#T + 1] = { "archives unreadable and no Questie: the emblem comes from the web icons", function()
    local P, calls = bundle({ player = ME10, dead_game = true, installed = {} })
    draw_one(P, entity({ is_player = true, hostile = true, race_id = 4, category = "hostile_player" }))
    assert(image_of(calls, "icon:inv_bannerpvp_02"), "the Alliance banner icon")
    for _, im in ipairs(all(calls, "image")) do
        assert(not im[1]:find("^addon:"), "no addon file without the addon: " .. im[1])
    end
end }

-- --- how it fights ------------------------------------------------------------------

T[#T + 1] = { "how it fights leads the details row, in its colour", function()
    local P, calls = bundle()
    draw_one(P, entity({ fight = "ranged", fight_sure = "seen" }))
    local pill = label(calls, "RANGED")
    assert(pill, "RANGED")
    assert_eq(pill[3], P.esp_elements.fight_color.ranged, "in green")
    local details = label(calls, "10  \194\183  30y")
    assert(details and details[4].at.y == pill[4].at.y, "on the details row")
    assert(pill[4].at.x < details[4].at.x, "first")
    local border
    for _, r in ipairs(all(calls, "plate_2d")) do
        if r[5].border == P.esp_elements.fight_color.ranged then border = r end
    end
    assert(border, "outlined in its colour")
end }

T[#T + 1] = { "a guess says so: a question mark, at reduced alpha", function()
    local P, calls = bundle()
    draw_one(P, entity({ fight = "melee", fight_sure = "guess" }))
    local pill = label(calls, "MELEE?")
    assert(pill, "MELEE?")
    assert_eq(pill[3].a, 165, "faded")

    local P2, calls2 = bundle()
    draw_one(P2, entity({ fight = "caster", fight_sure = "likely" }))
    assert(label(calls2, "CASTER"), "likely: no question mark")
end }

T[#T + 1] = { "the portrait's badge says it too; the toggle takes the pill away", function()
    local P, calls = bundle({ art_loading = true })
    draw_one(P, entity({ fight = "ranged", fight_sure = "seen" }))
    assert(has_text(calls, "R"), "R on the portrait rim")

    local P2, calls2 = bundle({ settings = { show_fight_role = false } })
    draw_one(P2, entity({ fight = "ranged", fight_sure = "seen" }))
    assert(not label(calls2, "RANGED"), "off")
end }


-- --- 1.40: frame cost and crowds ---------------------------------------------------

--- The highest point drawn by calls[from..to]: labels and pictures.
local function top_of(calls, from, to)
    local top = math.huge
    for i = from, to do
        local c = calls[i]
        if c.name == "unit_label" and c[4] and c[4].at then top = math.min(top, c[4].at.y)
        elseif c.name == "image" and type(c[2]) == "table" and c[2].y then top = math.min(top, c[2].y) end
    end
    return top
end

T[#T + 1] = { "off screen: only the line from an attacker to you -- and no read is spent on it", function()
    local rows = { mob = enemy_row({ target_guid = PLAYER_GUID }) }
    local P, calls = bundle({
        anchor = false, feet = false, enemies = enemies_with(rows),
        positions = { mob = { x = 0, y = 0, z = 0 }, [PLAYER_GUID] = { x = 20, y = 0, z = 0 } },
    })
    local asked = {}
    local detail = P.esp_collect.detail
    P.esp_collect.detail = function(e, free_only)
        asked[#asked + 1] = free_only == true
        return detail(e, free_only)
    end
    draw_one(P, entity({ guid = "mob" }))
    assert_eq(#all(calls, "line_3d"), 1, "the line to you")
    assert_eq(#all(calls, "unit_label"), 0, "no label")
    assert_eq(#all(calls, "image"), 0, "no picture")
    assert_eq(#all(calls, "rect_2d") + #all(calls, "plate_2d"), 0, "no pill")
    assert_eq(#asked, 1, "one detail")
    assert_eq(asked[1], true, "from what costs nothing")
    assert_eq(P.esp_elements.layout().offscreen, 1, "counted off screen")

    -- Not after anyone: nothing at all, and not even a free read past the gate.
    local P2, calls2 = bundle({ anchor = false, feet = false, settings = { show_target_line = false } })
    draw_one(P2, entity({ guid = "mob" }))
    assert_eq(#calls2, 0, "nothing drawn")
end }

T[#T + 1] = { "paint order: the more relevant mark is painted over the less; your target over every band", function()
    local P, calls = bundle({ settings = { esp_declutter = false } })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ guid = "a", name = "First" }), 1)
    P.esp_elements.draw_entity(entity({ guid = "b", name = "Second" }), 2)
    local first_layer = label(calls, "First")[4].layer
    local second_layer = label(calls, "Second")[4].layer
    assert(first_layer > second_layer, "rank 1 paints after rank 2: " .. first_layer .. " vs " .. second_layer)
    assert(math.floor(first_layer) == math.floor(second_layer), "within one band")

    local P2, calls2 = bundle({ settings = { esp_declutter = false } })
    P2.esp_elements.begin_frame()
    local far_target = entity({ guid = "t", name = "Target", lod = "far" })
    far_target.prio = 1030
    P2.esp_elements.draw_entity(far_target, 1)
    P2.esp_elements.draw_entity(entity({ guid = "n", name = "Near" }), 2)
    P2.esp_elements.draw_entity(entity({ guid = "f", name = "Far", lod = "far" }), 3)
    local target_layer = label(calls2, "Target")[4].layer
    assert(target_layer > label(calls2, "Near")[4].layer, "a far target paints over a near mark")
    assert(label(calls2, "Far")[4].layer < label(calls2, "Near")[4].layer, "any other far mark under it")
end }

T[#T + 1] = { "two heads in one spot: the second stack moves clear of the first, or is cut to its name", function()
    local P, calls = bundle()
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ guid = "a", name = "First" }), 1)
    local a_end = #calls
    P.esp_elements.draw_entity(entity({ guid = "b", name = "Second" }), 2)
    local a_top = top_of(calls, 1, a_end)
    local second = label(calls, "Second")
    assert(second, "the second still has its name")
    assert(second[4].at.y + 13 <= a_top + 1,
        "and it sits clear above the first stack: " .. second[4].at.y .. " vs " .. a_top)

    -- Six in one spot: the rest are cut to their names, each clear of the
    -- others, until there is no room left within reach -- and those print
    -- nothing above the head rather than a name over another.
    local names = { "Third", "Fourth", "Fifth", "Sixth" }
    for i = 1, #names do
        P.esp_elements.draw_entity(entity({ guid = "g" .. i, name = names[i] }), i + 2)
    end
    local l = P.esp_elements.layout()
    assert_eq(l.full, 1, "one whole stack")
    assert_eq(l.name + l.hidden, 5, "the others cut")
    assert(l.hidden >= 1, "some have nothing above the head")
    local ys = {}
    for _, n in ipairs({ "First", "Second", "Third", "Fourth", "Fifth", "Sixth" }) do
        local c = label(calls, n)
        if c then ys[#ys + 1] = c[4].at.y end
    end
    assert_eq(#ys, 6 - l.hidden, "a name for every mark with room")
    for i = 1, #ys do
        for j = i + 1, #ys do
            assert(math.abs(ys[i] - ys[j]) >= 13, "two names overlap: " .. ys[i] .. " and " .. ys[j])
        end
    end

    -- Off: as before, on top of each other.
    local P2, calls2 = bundle({ settings = { esp_declutter = false } })
    P2.esp_elements.begin_frame()
    P2.esp_elements.draw_entity(entity({ guid = "a", name = "First" }), 1)
    P2.esp_elements.draw_entity(entity({ guid = "b", name = "Second" }), 2)
    assert_eq(label(calls2, "First")[4].at.y, label(calls2, "Second")[4].at.y, "declutter off: same spot")
end }

T[#T + 1] = { "a crowded block keeps what is urgent by what it says: 'in combat' goes, 'on you' stays", function()
    local quests = {}
    for i = 1, 3 do quests[i] = { quest = { id = i, name = "Quest " .. i }, tag = "kill" } end
    local rows = {
        b = enemy_row({ in_combat = true }),
        c = enemy_row({ target_guid = PLAYER_GUID, in_combat = true }),
    }
    local P, calls = bundle({ enemies = enemies_with(rows) })
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(entity({ guid = "a", category = "quest", quest_entries = quests }), 1)
    P.esp_elements.draw_entity(entity({ guid = "b" }), 2)
    assert(not label(calls, "in combat"), "'in combat' is not worth a cut block")
    P.esp_elements.draw_entity(entity({ guid = "c" }), 3)
    assert(label(calls, "on you"), "'on you' is")
end }

T[#T + 1] = { "solo: 'on you' says it -- no 'aggro, #1 of 1' under it; with a pet, the rank stays", function()
    local rows = { mob = enemy_row({ target_guid = PLAYER_GUID }) }
    local function service(count)
        return {
            get = function()
                return { me = { tanking = true, rank = 1, percent = 100 }, count = count }
            end,
            company = function() return { players = 0, pet = count > 1 } end,
        }
    end
    local P, calls = bundle({ enemies = enemies_with(rows), threat = service(1) })
    draw_one(P, entity({ guid = "mob" }))
    assert(label(calls, "on you"), "on you")
    assert(not has_text_like(calls, "aggro"), "no aggro row solo")

    local P2, calls2 = bundle({ enemies = enemies_with(rows), threat = service(2) })
    draw_one(P2, entity({ guid = "mob" }))
    assert(has_text_like(calls2, "#1 of 2"), "with a pet, the rank says something")
end }

T[#T + 1] = { "'Name' switched off: no gap is kept above the head for it", function()
    local P, calls = bundle()
    draw_one(P, entity({ guid = "a" }))
    local with_name = top_of(calls, 1, #calls)
    local P2, calls2 = bundle({ settings = { show_name = false } })
    draw_one(P2, entity({ guid = "a" }))
    local without = top_of(calls2, 1, #calls2)
    assert(without > with_name + 8, "the stack is lower without its name: " .. without .. " vs " .. with_name)
end }

T[#T + 1] = { "extra object names: a name typed in applies to objects already in range", function()
    local settings = {}
    local P = bundle({ settings = settings })
    local reads = 0
    local stone = {
        get_name = function() reads = reads + 1 return "Strange Stone" end,
        get_npc_id = function() return 0 end,
        has_loot = function() return false end,
    }
    P.esp_classify.begin_pass()
    assert_eq(P.esp_classify.object(stone, "stone-1"), nil, "nothing, unnamed")
    P.esp_classify.begin_pass()
    P.esp_classify.object(stone, "stone-1")
    assert_eq(reads, 1, "cached while nothing changes")
    settings.objects_include = "strange stone"
    P.esp_classify.begin_pass()
    assert_eq(P.esp_classify.object(stone, "stone-1"), "object", "named: marked")
end }

T[#T + 1] = { "threat panel: a level read that fails does not take the panel down", function()
    local player = {
        get_level = function() error("not in world") end,
        get_position = function() return { x = 0, y = 0, z = 0 } end,
        get_rotation = function() return 0 end,
    }
    local P, calls = bundle({ player = player })
    P.esp_collect.threats[1] = { guid = "x", distance = 12,
        unit = { get_position = function() return { x = 12, y = 0, z = 0 } end },
        info = { name = "Ogre", level = 20, category = "elite", tag = "Elite" } }
    P.esp_panels.draw_threat_panel()
    assert(has_text_like(calls, "Ogre"), "the row drew")
    P.esp_panels.alert_check()
end }


T[#T + 1] = { "a hunter's TAME chip and what the beast teaches, from modules/tame.lua (1.72.0)", function()
    local P, calls = bundle({ enemies = enemies_with({ mob = enemy_row() }) })
    local now = { family_name = "Cat", can_now = true, text = "Cat: Claw 4? new, Prowl 1" }
    P.tame = { info = function(e) return e.guid == "mob" and now or nil end }
    draw_one(P, entity({ name = "Flatland Prowler" }))
    assert(label(calls, "TAME"), "the TAME chip before the name")
    assert(has_text_like(calls, "Cat: Claw 4? new, Prowl 1"), "the details line says what it teaches")

    -- Above your level: what it teaches, but no chip yet.
    local P2, calls2 = bundle({ enemies = enemies_with({ mob = enemy_row() }) })
    P2.tame = { info = function() return { family_name = "Cat", can_now = false, text = "Cat, tame at 32: Claw 5?" } end }
    draw_one(P2, entity({ name = "Flatland Prowler" }))
    assert(not label(calls2, "TAME"), "no chip above your level")
    assert(has_text_like(calls2, "Cat, tame at 32"), "the line says when")

    -- Switched off on the ESP page.
    local P3, calls3 = bundle({ settings = { show_tame = false }, enemies = enemies_with({ mob = enemy_row() }) })
    P3.tame = { info = function() return now end }
    draw_one(P3, entity({ name = "Flatland Prowler" }))
    assert(not label(calls3, "TAME") and not has_text_like(calls3, "Cat: Claw"), "nothing with the switch off")
end }

-- --- the cast ring (1.85.0) ----------------------------------------------------

T[#T + 1] = { "a caster gets a ring on the ground filling as its cast runs, even at the far tier: white to red to kick", function()
    clock.s = 1000.0
    local positions = { mob = { x = 10, y = 0, z = 0 } }
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }
    local P, calls = bundle({ positions = positions, reach = 2.0, enemies = enemies_with(rows) })
    draw_one(P, entity({ lod = "far" }))
    local ring = first(calls, "ring_3d")
    assert(ring, "a ring at the far tier")
    near(ring[3], 1 / 3, "a third of the way through")
    near(ring[2], 2.65, "just outside the aggro ring: reach, a little, and the gap")
    assert_eq(ring[4], P.esp_elements.cast_color.interruptible, "the cast bar's white: you can kick it")
    assert_eq(ring[5].to.r, 240, "turning red"); assert_eq(ring[5].to.g, 80, "turning red")
    assert(not ring[5].droppable, "a warning is never dropped")
end }

T[#T + 1] = { "the cast ring: red from the start when it cannot be kicked, a channel empties, and the switch turns it off", function()
    clock.s = 1000.0
    local positions = { mob = { x = 10, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ casting = casting(116, 999.0, 1002.0, false) }) }) })
    draw_one(P, entity())
    assert_eq(first(calls, "ring_3d")[4], P.esp_elements.cast_color.locked, "locked: red")
    local P2, calls2 = bundle({ positions = positions,
        enemies = enemies_with({ mob = enemy_row({ casting = casting(116, 999.0, 1003.0, true, true) }) }) })
    draw_one(P2, entity())
    near(first(calls2, "ring_3d")[3], 0.75, "a channel a quarter through has three quarters left")
    local P3, calls3 = bundle({ positions = positions, settings = { show_cast_ring = false },
        enemies = enemies_with({ mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true) }) }) })
    draw_one(P3, entity())
    assert(not first(calls3, "ring_3d"), "switched off")
    local P4, calls4 = bundle({ positions = positions, enemies = enemies_with({ mob = enemy_row({}) }) })
    draw_one(P4, entity())
    assert(not first(calls4, "ring_3d"), "nothing without a cast")
end }

-- --- the new look (1.88.0) -------------------------------------------------------
--
-- The user, 2026-10-08: "Take all ESPs and convert it to this!" -- ground
-- rings, boxes to curtains, far things as beacons, cards and bars, and only
-- the gatherables your skill can gather.

T[#T + 1] = { "ground rings: a node's ring is JCore's ring_3d, full, in the node's colour", function()
    local positions = { herb1 = { x = 12, y = 0, z = 0 } }
    local P, calls = bundle({ positions = positions })
    draw_one(P, entity({ kind = "object", guid = "herb1", category = "herb", name = "Peacebloom" }))
    local ring = first(calls, "ring_3d")
    assert(ring, "a shader ring")
    assert_eq(ring[1].x, 12, "under the node")
    near(ring[2], 0.7, "the node ring's size")
    assert_eq(ring[3], 1, "full")
    assert_eq(ring[4], "accent", "in the node's colour")
    assert_eq(ring[5].outer, 1.0, "to its outer edge")
    assert_eq(#all(calls, "circle_3d"), 0, "no outline")

    local P2, calls2 = bundle({ positions = positions, old_jcore = true })
    draw_one(P2, entity({ kind = "object", guid = "herb1", category = "herb", name = "Peacebloom" }))
    assert(first(calls2, "circle_3d"), "an older JCore: the outline, as before")
end }

--- A unit entity this far off, with its feet at that distance.
local function far(o)
    local e = entity(o)
    e.distance = o.distance or 80
    return e
end

--- A bundle with the pillars switched on (1.7.6: a pillar is a curtain, off
--- by default) unless the settings say otherwise.
local function pillars(opts)
    opts.settings = opts.settings or {}
    if opts.settings.show_beacon == nil then opts.settings.show_beacon = true end
    return bundle(opts)
end

T[#T + 1] = { "far things as pillars: a far rare, boss, quest target or guide target gets a beacon in its colour", function()
    local positions = { mob = { x = 80, y = 0, z = 3 } }
    for _, cat in ipairs({ "rare", "boss", "quest", "guide" }) do
        local P, calls = pillars({ positions = positions })
        P.category_color[cat] = P.category_color[cat] or cat
        draw_one(P, far({ category = cat, lod = "far" }))
        local b = first(calls, "beacon_3d")
        assert(b, cat .. ": a pillar")
        assert_eq(b[1].x, 80, cat .. ": at its feet")
        assert_eq(b[2], P.category_color[cat], cat .. ": in the mark's colour")
        assert(b[3].height >= 8 and b[3].height <= 12, cat .. ": about ten yards tall")
        assert(b[3].layer >= 98 and b[3].layer < 101, cat .. ": in the world band, biased for the far tier")
        assert_eq(b[3].droppable, true, cat .. ": a far mark, the first to go on a heavy frame")
    end
end }

T[#T + 1] = { "far things as pillars: a corpse with loot on it, never one only to skin", function()
    local positions = { mob = { x = 80, y = 0, z = 0 } }
    local P, calls = pillars({ positions = positions })
    draw_one(P, far({ category = "corpse", dead = true, lootable = true }))
    assert(first(calls, "beacon_3d"), "loot: a pillar")

    local P2, calls2 = pillars({ positions = positions })
    draw_one(P2, far({ category = "corpse", dead = true, lootable = false, skinnable = true }))
    assert_eq(#all(calls2, "beacon_3d"), 0, "skin only: none")
end }

T[#T + 1] = { "far things as pillars: not near, not a plain mob, never a node; the distance is a setting", function()
    local positions = { mob = { x = 30, y = 0, z = 0 }, node = { x = 90, y = 0, z = 0 } }
    local P, calls = pillars({ positions = positions })
    draw_one(P, far({ category = "rare", distance = 30 }))
    assert_eq(#all(calls, "beacon_3d"), 0, "a rare 30 yd off: no pillar (from 40 yd)")

    local P2, calls2 = pillars({ positions = positions })
    draw_one(P2, far({ category = "normal" }))
    draw_one(P2, far({ category = "elite" }))
    assert_eq(#all(calls2, "beacon_3d"), 0, "a plain mob or an elite: none")

    local P3, calls3 = pillars({ positions = positions })
    local node = entity({ kind = "object", guid = "node", category = "herb", name = "Peacebloom" })
    node.distance = 90
    draw_one(P3, node)
    local q = entity({ kind = "object", guid = "node", category = "quest", name = "Bloodstained Journal" })
    q.distance = 90
    draw_one(P3, q)
    assert_eq(#all(calls3, "beacon_3d"), 0, "never a node or an object: modules/beacons.lua has those")

    local P4, calls4 = pillars({ positions = positions, settings = { esp_beacon_from = 20 } })
    draw_one(P4, far({ category = "rare", distance = 30 }))
    assert(first(calls4, "beacon_3d"), "from 20 yd: the rare at 30 has one")
end }

T[#T + 1] = { "far things as pillars: off screen still, not in a crowd's cut, not with the quest marks alone, the switch off or by default", function()
    local positions = { mob = { x = 80, y = 0, z = 0 } }
    -- Its feet off screen: the pillar is drawn (JCore draws it while its
    -- top shows), and nothing else is.
    local P, calls = pillars({ positions = positions, anchor = false, feet = false })
    draw_one(P, far({ category = "rare" }))
    assert_eq(#all(calls, "beacon_3d"), 1, "off screen: the pillar")
    assert_eq(first(calls, "beacon_3d")[2], "gold", "in its colour")
    assert_eq(#all(calls, "unit_label"), 0, "and no label")

    -- A stack cut to nothing by the declutter keeps its pillar: it takes no
    -- room on screen.
    local P2, calls2 = pillars({ positions = positions })
    P2.esp_elements.begin_frame()
    for i = 1, 8 do P2.esp_elements.draw_entity(far({ category = "rare", name = "Rare " .. i }), i) end
    assert(P2.esp_elements.layout().hidden >= 1, "some stacks cut to nothing")
    assert_eq(#all(calls2, "beacon_3d"), 8, "every one keeps its pillar")

    local P3, calls3 = pillars({ positions = positions })
    P3.esp_elements.begin_frame(true)
    P3.esp_elements.draw_entity(far({ category = "quest" }))
    assert_eq(#all(calls3, "beacon_3d"), 0, "the quest marks alone, with the ESP off: no pillar")

    local P4, calls4 = pillars({ positions = positions, settings = { show_beacon = false } })
    draw_one(P4, far({ category = "rare" }))
    assert_eq(#all(calls4, "beacon_3d"), 0, "switched off")
    local P6, calls6 = bundle({ positions = positions })
    draw_one(P6, far({ category = "rare" }))
    assert_eq(#all(calls6, "beacon_3d"), 0, "1.7.6: off by default -- enemies carry no curtain")

    local P5, calls5 = pillars({ positions = positions, old_jcore = true })
    draw_one(P5, far({ category = "rare" }))
    assert_eq(#calls5 > 0, true, "an older JCore still draws the mark")
end }

T[#T + 1] = { "cards and bars: plates and shader bars with the shader look on, the gradient to near white", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true), target_guid = PLAYER_GUID }) }
    local P, calls = bundle({ enemies = enemies_with(rows), settings = { bar_always = true } })
    draw_one(P, entity())
    assert(#all(calls, "plate_2d") >= 3, "the pills are plates")
    assert_eq(#all(calls, "rect_2d"), 0, "no flat rectangle")
    local bars = all(calls, "bar_2d")
    assert(#bars >= 2, "health and cast are shader bars")
    assert_eq(#all(calls, "unit_bar"), 0, "no flat bar")
    for _, b in ipairs(bars) do
        local o = b[6]
        assert(o.to.blend and o.to.from == b[5], "shading from its own colour")
        assert_eq(o.to.to.r, 255, "towards white"); near(o.to.t, 0.25, "a quarter of the way")
        assert_eq(o.bg.r, 22, "on the bar backing's dark rail"); assert_eq(o.bg.a, 235, "as opaque")
        assert_eq(o.layer, 200, "in the units band")
    end
    -- the health bar, centred on the anchor like the bar it replaces
    local health = bars[1]
    assert_eq(health[1].x + health[2] * 0.5, 400, "centred")
end }

T[#T + 1] = { "cards and bars: the shader look off, or an older JCore: the flat pills and bars, exactly as before", function()
    clock.s = 1000.0
    local rows = { mob = enemy_row({ casting = casting(116, 999.0, 1002.0, true), target_guid = PLAYER_GUID }) }
    for _, o in ipairs({ { settings = { esp_shader_look = false } }, { old_jcore = true } }) do
        o.enemies = enemies_with(rows)
        local P, calls = bundle(o)
        draw_one(P, entity())
        assert_eq(#all(calls, "plate_2d") + #all(calls, "bar_2d"), 0, "no plate, no shader bar")
        local filled, outlined = 0, 0
        for _, r in ipairs(all(calls, "rect_2d")) do
            if r[5].filled then filled = filled + 1 else outlined = outlined + 1 end
        end
        assert(filled >= 3, "a flat backdrop per pill")
        assert(outlined >= 2, "and an outline where the colour is the answer")
        local bar = first(calls, "unit_bar")
        assert(bar, "the flat cast bar")
        near(bar[2], 1 / 3, "a third through")
        local back = label(calls, "Frostbolt  2.0")
        assert(back, "the cast pill")
    end
end }

-- --- gathering by your skill ------------------------------------------------------

local function world_object(guid, name, distance)
    return {
        guid = guid, distance = distance or 20,
        get_name = function() return name end,
        get_npc_id = function() return 0 end,
        has_loot = function() return false end,
    }
end

local GATHERER = {
    get_guid = function() return PLAYER_GUID end,
    get_level = function() return 30 end,
    can_attack = function() return false end,
    is_enemy_with = function() return false end,
    is_friend_with = function() return true end,
}

--- The collector over three nodes, with JCore's player.skill answering `skills`.
local function gather(skills, settings, jplayer)
    jplayer = jplayer or { skill = function(prof) return skills[prof] end }
    local P = bundle({ player = GATHERER, jplayer = jplayer, settings = settings, object_list = {
        world_object("h", "Peacebloom"),
        world_object("m", "Mithril Deposit"),
        world_object("c", "Battered Chest"),
    } })
    P.esp_collect.run(true, 100)
    local marks, nodes = {}, {}
    for _, e in ipairs(P.esp_collect.entities()) do marks[e.guid] = e end
    for _, n in ipairs(P.esp_collect.nodes()) do nodes[n.guid] = n end
    return P, marks, nodes
end

T[#T + 1] = { "gathering by skill: without the profession, not marked and not handed to the gatherer", function()
    local P, marks, nodes = gather({ mining = 300 })
    assert(not marks.h, "no Herbalism: the herb is not marked")
    assert(not nodes.h, "and not in the nodes list")
    assert(marks.m and nodes.m, "the vein is: Mining 300")
    assert(marks.c and nodes.c, "a chest asks for no skill")
    assert_eq(P.esp_collect.stats().gather_hidden, 1, "counted for the debug page")
end }

T[#T + 1] = { "gathering by skill: short of it, marked with (Requires Skill N) in a dimmed colour, and requires = N", function()
    local P, marks, nodes = gather({ mining = 100, herbalism = 1 })
    assert(marks.m, "Mining 100 against Mithril's 175: still marked")
    assert_eq(marks.m.requires, 175, "with what it asks for")
    assert_eq(nodes.m.requires, 175, "and the gatherer is told")
    assert_eq(marks.h.requires, nil, "Peacebloom asks for 1: plain")
    assert_eq(nodes.h.requires, nil, "plain for the gatherer too")

    local positions = { m = { x = 20, y = 0, z = 0 } }
    local P2, calls = bundle({ positions = positions })
    local e = entity({ kind = "object", guid = "m", category = "ore", name = "Mithril Deposit" })
    e.requires = 175
    draw_one(P2, e)
    local text = label(calls, "Mithril Deposit (Requires Skill 175)")
    assert(text, "the label says so")
    assert_eq(text[3].from, "accent", "in the node's colour")
    near(text[3].mul, 0.55, "dimmed")
    assert_eq(first(calls, "ring_3d")[4], text[3], "its ring dimmed the same")
end }

T[#T + 1] = { "gathering by skill: enough is plain; switched off, or an older JCore, every node as before", function()
    local _, marks, nodes = gather({ mining = 200, herbalism = 50 })
    assert(marks.m and marks.m.requires == nil and nodes.m.requires == nil, "Mining 200: plain")
    assert(marks.h and nodes.h, "Herbalism 50: Peacebloom")

    local _, marks2, nodes2 = gather({}, { gather_skill_only = false })
    assert(marks2.h and marks2.m and nodes2.h and nodes2.m, "off: every node")
    assert(marks2.m.requires == nil and nodes2.m.requires == nil, "and nothing it asks for")

    local _, marks3, nodes3 = gather(nil, nil, {})
    assert(marks3.h and marks3.m and nodes3.h and nodes3.m, "no player.skill: every node")

    local _, marks4 = gather(nil, nil, { skill = function() error("not in world") end })
    assert(marks4.h and marks4.m and marks4.m.requires == nil, "a read that raised hides nothing")

    local plain = entity({ kind = "object", guid = "m", category = "ore", name = "Mithril Deposit" })
    local P5, calls5 = bundle()
    draw_one(P5, plain)
    assert(label(calls5, "Mithril Deposit"), "a plain node's label is its name")
end }

T[#T + 1] = { "gathering by skill: asked once a pass per profession", function()
    local asked = 0
    local jplayer = { skill = function(prof) asked = asked + 1 return prof == "mining" and 100 or nil end }
    local P = bundle({ player = GATHERER, jplayer = jplayer, object_list = {
        world_object("m1", "Mithril Deposit"), world_object("m2", "Copper Vein"),
        world_object("m3", "Tin Vein"), world_object("h1", "Peacebloom"), world_object("h2", "Silverleaf"),
    } })
    P.esp_collect.run(true, 100)
    assert_eq(asked, 2, "mining once, herbalism once")
    P.esp_collect.run(true, 100)
    assert_eq(asked, 4, "and again the next pass")
end }

return T

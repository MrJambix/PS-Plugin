-- Jambix AIO: the lists Forever's automation acts on (1.54.0).
--
-- world.lua's auto-loot, skinning and gathering read P.esp.corpses() and
-- P.esp.nodes(). Those came from the classic collector, which never runs on
-- Forever, so until 1.54.0 loot_object, skin_object and use_object were never
-- called there (the API recorder, 29 sessions). The Forever ESP now fills the
-- same two lists. Pinned here:
--   * a corpse that fought you, within reach, is listed for looting; one
--     that did not, but can be skinned, is listed as skinnable; neither is
--     listed past reach, once a loot window opened beside it, or when the
--     client calls it somebody else's (is_tap_denied);
--   * herbs, veins and chests within reach are listed by their names, with
--     their gathering kind; scenery is not;
--   * every display switch off, the overlay hidden, the mark limit at one:
--     the lists are the same (hiding a mark must not turn looting off);
--   * with the automation's switches off, or the plugin off, nothing is
--     built; and esp/init.lua hands the Forever lists out on Forever.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local make_forever = require("jambix_aio/modules/esp/forever")
local cfg = require("jambix_aio/modules/config")

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
    spell_book = { get_spell_name = function() return "" end },
    play_sound_by_id = function() end,
}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A unit the way Forever serves one.
local function unit(o)
    local u = { guid = o.guid, skin = o.skin, tap = o.tap == true, pos = o.pos or { x = 3, y = 0, z = 0 } }
    u.get_level = function() return 4 end
    u.get_npc_id = function() return 251143 end
    u.get_creature_type = function() return 1 end
    u.get_max_health = function() return 200 end
    u.get_bounding_radius = function() return 1 end
    u.get_npc_flags = function() return 0 end
    u.get_name = function() return "" end
    u.is_enemy_with = function() return true end
    u.can_be_skinned = function(self) return self.skin == true end
    u.is_pet = function() return false end
    u.is_tap_denied = function(self) return self.tap end
    return u
end

local function gobject(o)
    return { guid = o.guid, pos = o.pos or { x = 3, y = 0, z = 0 },
        get_name = function() return o.name end, can_be_used = function() return true end }
end

--- Every display switch off, unless `display` is given.
local DISPLAY_OFF = {
    corpse_on = false, herb_on = false, ore_on = false, container_on = false, object_on = false,
    normal_on = false, elite_on = false, rare_on = false, friendly_npc_on = false, critter_on = false,
    quest_marks = false, show_nodes = false, esp_max_marks = 1,
}

local function world(opts)
    opts = opts or {}
    local list, objects, rows, handlers = {}, {}, {}, {}
    local enemies = opts.enemies or {}
    local settings = {}
    for k, v in pairs(opts.display or DISPLAY_OFF) do settings[k] = v end
    for k, v in pairs(opts.settings or {}) do settings[k] = v end
    local me = { guid = "me", pos = { x = 0, y = 0, z = 0 }, get_level = function() return 4 end,
        is_enemy_with = function() return false end, get_direction = function() return { x = 1, y = 0, z = 0 } end }
    local W = { settings = settings, enemies = enemies, handlers = handlers, master = true }
    function W.add(u, row)
        list[#list + 1] = u
        row.guid, row.dist, row.pos = u.guid, row.dist or 3, u.pos
        rows[u] = row
        return row
    end
    function W.add_object(o, dist)
        objects[#objects + 1] = o
        rows[o] = { guid = o.guid, dist = dist or 3, pos = o.pos }
    end
    local units = {
        player = function() return me end,
        guid = function(o) return o and o.guid end,
        snapshot = function(o) return rows[o] end,
        units = function() return list end,
        objects = function() return objects end,
        health_fraction = function() return 1 end,
        position = function(o) return o and o.pos end,
        player_position = function() return me.pos end,
    }
    local combat = { target = function() return nil end }
    -- JCore 1.6.0's names and loot (the real services) on this world.
    local facts = require("mock/jcore_unit_facts").build({
        units = units, list = list, enemies = enemies, combat = combat, handlers = handlers,
    })
    W.facts = facts
    local P = {
        cfg = cfg,
        log = { fmt = function() end },
        ctx = {
            on = facts.on,
            names = facts.names,
            loot = facts.loot,
            emit = function() end,
            enemies = { get = function(guid) return enemies[guid] end },
            LAYER = { WORLD = 100, UNITS = 200, OVERLAY = 300, HUD = 500 },
        },
        units = units,
        draw = {
            unit_w2s = function() return nil end, measure = function(t, s) return #t * s * 0.5 end,
            screen_size = function() return 1920, 1080 end,
            rect_2d = function() end, text_2d = function() end, panel = function(at) return at.y end,
            circle_3d = function() end, line_3d = function() end, arrow_2d = function() end,
            unit_box_corners = function() end, notify = function() end, image = function() return true end,
        },
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        master_on = function() return W.master end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        combat = combat,
        esp_roles = { class_name = function() return nil end },
    }
    W.F = make_forever(P)
    function W.frame(visuals)
        clock.s = clock.s + 0.1
        facts.poll()
        W.F.render(visuals == true, 100)
    end
    return W
end

local function kinds(list)
    local out = {}
    for i = 1, #list do out[#out + 1] = list[i].kind .. ":" .. list[i].name end
    table.sort(out)
    return table.concat(out, ",")
end

local T = {}

T[#T + 1] = { "corpses: yours to loot, or skinnable; not past reach, not someone else's; every mark off", function()
    local W = world({ settings = { autoloot_on = true }, enemies = {
        mine = { targeting_me = true, in_combat = true }, far = { targeting_me = true, in_combat = true },
        taken = { targeting_me = true, in_combat = true },
    } })
    local mine = W.add(unit({ guid = "mine" }), { is_enemy = true, dist = 3 })
    local far = W.add(unit({ guid = "far" }), { is_enemy = true, dist = 30 })
    local taken = W.add(unit({ guid = "taken", tap = true }), { is_enemy = true, dist = 4 })
    W.add(unit({ guid = "hide", skin = true }), { is_enemy = true, dist = 5, dead = true })
    W.add(unit({ guid = "nobody" }), { is_enemy = true, dist = 5, dead = true })
    W.frame(false)
    mine.dead, far.dead, taken.dead = true, true, true
    W.enemies.mine, W.enemies.far, W.enemies.taken = nil, nil, nil
    W.frame(false)

    local by = {}
    for _, c in ipairs(W.F.corpses()) do by[c.guid] = c end
    assert(by.mine, "the kill that fought you is listed")
    assert_eq(by.mine.skinnable, false, "for looting")
    assert_eq(by.mine.distance, 3, "with its distance")
    assert(by.mine.obj and by.mine.obj.guid == "mine", "and its object")
    assert(by.hide and by.hide.skinnable == true, "a skinnable corpse nobody fought, as skinnable")
    assert_eq(by.far, nil, "past reach: not listed")
    assert_eq(by.taken, nil, "the client says it is someone else's: not listed")
    assert_eq(by.nobody, nil, "nothing to do with it: not listed")
    assert_eq(W.F.stats().loot, 0, "and no mark was drawn for any of it")

    W.handlers["jcore.game_event.LOOT_OPENED"]({ true, false })
    W.frame(false)
    by = {}
    for _, c in ipairs(W.F.corpses()) do by[c.guid] = c end
    assert_eq(by.mine, nil, "looted: gone from the list")
    assert(by.hide, "the skinnable one stays")
end }

T[#T + 1] = { "nodes: herbs, veins and chests by name within reach; scenery and far ones not; every mark off", function()
    local W = world({ settings = { gather_herbs = true } })
    W.add_object(gobject({ guid = "h", name = "Peacebloom" }), 4)
    W.add_object(gobject({ guid = "o", name = "Copper Vein" }), 6)
    W.add_object(gobject({ guid = "c", name = "Battered Chest" }), 7)
    W.add_object(gobject({ guid = "x", name = "Wooden Chair" }), 2)
    W.add_object(gobject({ guid = "f", name = "Silverleaf" }), 40)
    W.frame(false)
    assert_eq(kinds(W.F.nodes()), "container:Battered Chest,herb:Peacebloom,ore:Copper Vein",
        "the gathering kinds; world.lua picks which it wants")
    assert_eq(W.F.nodes()[1].distance ~= nil, true, "with distances")
end }

T[#T + 1] = { "the display switches and the overlay do not change the lists", function()
    local on = { autoloot_on = true, gather_ore = true }
    local display_on = { corpse_on = true, ore_on = true, esp_max_marks = 30 }
    local results = {}
    for _, display in ipairs({ DISPLAY_OFF, display_on }) do
        for _, visuals in ipairs({ false, true }) do
            local W = world({ settings = on, display = display,
                enemies = { k = { targeting_me = true, in_combat = true } } })
            local k = W.add(unit({ guid = "k" }), { is_enemy = true, dist = 3 })
            W.add_object(gobject({ guid = "o", name = "Copper Vein" }), 4)
            W.frame(visuals)
            k.dead, W.enemies.k = true, nil
            W.frame(visuals)
            results[#results + 1] = #W.F.corpses() .. "/" .. kinds(W.F.nodes())
        end
    end
    for i = 2, #results do assert_eq(results[i], results[1], "case " .. i) end
    assert_eq(results[1], "1/ore:Copper Vein", "a corpse and a vein")
end }

T[#T + 1] = { "the automation's switches off, or the plugin off: nothing built", function()
    local W = world({ enemies = { k = { targeting_me = true, in_combat = true } } })
    local k = W.add(unit({ guid = "k" }), { is_enemy = true, dist = 3 })
    W.add_object(gobject({ guid = "h", name = "Peacebloom" }), 4)
    W.frame(false)
    k.dead, W.enemies.k = true, nil
    W.frame(false)
    assert_eq(#W.F.corpses(), 0, "auto-loot off: no corpses")
    assert_eq(#W.F.nodes(), 0, "gathering off: no nodes")

    W.settings.autoloot_on, W.settings.gather_herbs = true, true
    W.master = false
    W.frame(false)
    assert_eq(#W.F.corpses() + #W.F.nodes(), 0, "plugin off: nothing")
    W.master = true
    W.frame(false)
    assert_eq(#W.F.corpses(), 1, "on again: the corpse")
    assert_eq(#W.F.nodes(), 1, "and the herb")
end }

return T

-- Jambix AIO: the Forever ESP (modules/esp/forever.lua), against a hand-built
-- bundle that answers the way the Forever client was recorded answering:
-- get_name "" for units, everything it marks read from JCore's sweep rows,
-- the enemies and threat services, and a few cached per-unit reads. Drawn
-- through a recording draw service.

local root = (jtest and jtest.scripts) or "scripts"
-- Only when the harness has not already put scripts/ on the path: run.js does,
-- after a JTEST_OVERLAY staging folder, and prepending it again here would
-- hide the staged copy of forever.lua.
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local make_forever = require("jambix_aio/modules/esp/forever")
local cfg = require("jambix_aio/modules/config")

local clock = { s = 1000.0 }
local SPELLS = { [1248802] = "Corrupted Wind", [116] = "Frostbolt", [118] = "Polymorph" }
local sounds = {}
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
    spell_book = { get_spell_name = function(id) return SPELLS[id] or "" end },
    play_sound_by_id = function(id) sounds[#sounds + 1] = id end,
}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- --- the world ---------------------------------------------------------------

--- A unit the way Forever serves one: methods on the object, a blank name.
local function unit(o)
    local u = {
        guid = o.guid, screen = o.screen, hp = o.hp or 1,
        level = o.level or 4, npc = o.npc or 251143, ctype = o.ctype or 4,
        class = o.class, hostile = o.hostile ~= false, skin = o.skin,
        pos = o.pos or { x = 10, y = 0, z = 0 },
    }
    u.get_level = function(self) return self.level end
    u.get_npc_id = function(self) return self.npc end
    u.get_creature_type = function(self) return self.ctype end
    u.get_class = function(self) return self.class end
    u.get_max_health = function() return 200 end
    u.get_bounding_radius = function() return 1.2 end
    u.flags = o.flags or 0
    u.name = o.name or ""
    u.get_npc_flags = function(self) return self.flags end
    u.get_name = function(self) return self.name end
    u.is_enemy_with = function(self) return self.hostile end
    u.can_be_skinned = function(self) return self.skin == true end
    u.pet = o.pet == true
    u.is_pet = function(self) return self.pet end
    -- false for everything until client patch 1.60.1.70205
    u.tap = o.tap == true
    u.is_tap_denied = function(self) return self.tap end
    return u
end

local function bundle(opts)
    opts = opts or {}
    local calls, traces, handlers, emitted, logs = {}, {}, {}, {}, {}
    local list, rows, objects = {}, {}, {}
    local me = {
        guid = "me", pos = { x = 0, y = 0, z = 0 },
        is_enemy_with = function() return false end,
        get_level = function() return opts.my_level or 4 end,
        -- Facing +x: get_direction is what answers on Forever.
        get_direction = function() return { x = 1, y = 0, z = 0 } end,
    }
    local function add(u, row)
        list[#list + 1] = u
        row.guid = u.guid
        row.dist = row.dist or 20
        row.pos = u.pos
        rows[u] = row
    end
    local function add_object(o, row)
        objects[#objects + 1] = o
        row.guid = o.guid
        row.dist = row.dist or 20
        row.pos = o.pos or { x = 10, y = 0, z = 0 }
        rows[o] = row
    end
    local function rec(name)
        return function(...) calls[#calls + 1] = { name = name, ... } end
    end
    local draw = {
        unit_w2s = function(obj) return obj.screen end,
        measure = function(text, size) return #text * size * 0.5 end,
        screen_size = function() return 1920, 1080 end,
        rect_2d = function(at, w, h, c, o)
            calls[#calls + 1] = { name = "rect", at = at, w = w, h = h, c = c, o = o }
        end,
        text_2d = function(at, text, c, o)
            calls[#calls + 1] = { name = "text", at = at, text = text, c = c, o = o }
        end,
        panel = function(at, w, h, o)
            calls[#calls + 1] = { name = "panel", at = at, w = w, h = h, o = o }
            return at.y + 20
        end,
        circle_3d = rec("circle_3d"),
        ring_3d = rec("ring_3d"),
        line_3d = rec("line_3d"),
        arrow_2d = rec("arrow_2d"),
        unit_box_corners = rec("box"),
        notify = rec("notify"),
        w2s = opts.w2s,
        image = function(ref, at, w, h, tint, o)
            calls[#calls + 1] = { name = "image", ref = ref, at = at, w = w, h = h, tint = tint, o = o }
            return true
        end,
        -- JCore's new look (1.88.0): the curtain, the beacon, the soft plate
        -- and bar, and the colour helpers, as the staged draw service has them.
        curtain_3d = rec("curtain_3d"),
        beacon_3d = rec("beacon_3d"),
        plate_2d = function(at, w, h, c, o)
            calls[#calls + 1] = { name = "plate", at = at, w = w, h = h, c = c, o = o }
        end,
        bar_2d = function(at, w, h, fraction, c, o)
            calls[#calls + 1] = { name = "bar", at = at, w = w, h = h, fraction = fraction, c = c, o = o }
        end,
        blend = function(a, b, t)
            local function mix(x, y) return math.floor(x + (y - x) * t + 0.5) end
            return { r = mix(a.r, b.r), g = mix(a.g, b.g), b = mix(a.b, b.b), a = mix(a.a or 255, b.a or 255) }
        end,
        with_alpha = function(c, mul)
            return { r = c.r, g = c.g, b = c.b, a = math.floor((c.a or 255) * mul + 0.5) }
        end,
    }
    -- A JCore from before the new look: none of it.
    if opts.old_draw then
        for _, k in ipairs({ "ring_3d", "curtain_3d", "beacon_3d", "plate_2d", "bar_2d", "blend", "with_alpha" }) do
            draw[k] = nil
        end
    end
    local units = {
        player = function() return me end,
        guid = function(o) return o and o.guid end,
        snapshot = function(o) return rows[o] end,
        units = function() return list end,
        health_fraction = function(o) return o.hp end,
        position = function(o) return o and o.pos end,
        objects = function() return objects end,
        player_position = function() return me.pos end,
        -- JCore's, as it answers on Forever: the creature cache's rank.
        classification = function(o)
            local c = opts.creatures and opts.creatures.info and opts.creatures.info(o and o.npc)
            return c and c.classification or 0
        end,
    }
    local erows = opts.enemies or {}
    local settings = opts.settings or {}

    -- One event bus for the module's ctx.on and for JCore's services:
    -- handlers[name](args) fires every subscriber, as the real bus does.
    local subs = {}
    local function subscribe(name, fn)
        if not subs[name] then
            subs[name] = {}
            handlers[name] = function(...) for _, f in ipairs(subs[name]) do f(...) end end
        end
        table.insert(subs[name], fn)
    end

    -- JCore 1.6.0's names and loot services, the real ones, on this world.
    local combat = { target = function() return opts.target end }
    local stores = {}
    local rt = {
        log = { for_tag = function() return { fmt = function() end } end },
        events = { on = function(name, fn) subscribe(name, fn) end, emit = function() end },
        world = { client = function() return { forever = true } end },
        storage = { store = function(name)
            stores[name] = stores[name] or { data = {}, touch = function() end }
            return stores[name]
        end },
        units = units,
        combat = combat,
        creatures = opts.creatures,
        group = { objects = function()
            local out = {}
            local members = opts.group and opts.group.members and opts.group.members() or {}
            for i = 1, #members do out[i] = { guid = members[i].guid } end
            return out
        end },
        enemies = { all = function()
            local out = {}
            for guid, row in pairs(erows) do
                row.guid = guid
                for i = 1, #list do if list[i].guid == guid then row.obj = list[i] end end
                out[#out + 1] = row
            end
            return out
        end },
    }
    package.loaded["jcore/services/names"] = nil
    package.loaded["jcore/services/loot"] = nil
    rt.names = require("jcore/services/names")(rt)
    rt.loot = require("jcore/services/loot")(rt)

    local P = {
        cfg = cfg,
        log = { fmt = function(level, fmt, ...) logs[#logs + 1] = level .. ": " .. string.format(fmt, ...) end },
        ctx = {
            on = subscribe,
            names = rt.names,
            loot = rt.loot,
            emit = function(name, payload)
                if name == "jcore.recorder.trace" then traces[#traces + 1] = payload
                else emitted[#emitted + 1] = { name, payload } end
            end,
            enemies = { get = function(guid) return erows[guid] end },
            threat = opts.threat,
            group = opts.group,
            storage = opts.storage,
            creatures = opts.creatures,
            gamelua = opts.gamelua,
            questdb = opts.questdb,
            player = opts.player,
            LAYER = { WORLD = 100, UNITS = 200, OVERLAY = 300, HUD = 500 },
        },
        units = units,
        draw = draw,
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        combat = combat,
        esp_roles = { class_name = function(id) return ({ [1] = "Warrior", [4] = "Rogue" })[id] end },
        esp_fight = opts.fight,
        quests = opts.quests,
        targeting = opts.targeting,
        tame = opts.tame,
    }
    -- The art pack (1.69.0), faked: every cell "art:<key>", always loaded.
    -- Without it the module builds the real esp/art.lua, which finds no
    -- asset registry here, and every mark falls back to its words.
    if opts.art then
        P.JCore = { assets = { request = function() return true end } }
        P.esp_art = { available = true, cells = { statusbar = { 0, 0.9, 0.25, 1 } },
            ref = function(key) return "art:" .. key end }
    end
    local F = make_forever(P)
    -- JCore polls its loot service once a tick, before any plugin draws.
    local render = F.render
    F.render = function(...)
        rt.loot._poll()
        return render(...)
    end
    return F, calls, add, handlers, traces, emitted, logs, add_object
end

--- A game object, named the way Forever names one.
local function gobject(o)
    return { guid = o.guid, screen = o.screen, pos = o.pos, get_name = function() return o.name end,
        can_be_used = function() return o.used == true end }
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

local function texts(calls)
    local out = {}
    for i = 1, #calls do if calls[i].name == "text" then out[#out + 1] = calls[i].text end end
    return out
end

local function find_text(calls, s)
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "text" and c.text:find(s, 1, true) then return c end
    end
    return nil
end

--- The text segments drawn exactly as `s`.
local function exact(calls, s)
    local out = {}
    for i = 1, #calls do
        if calls[i].name == "text" and calls[i].text == s then out[#out + 1] = calls[i] end
    end
    return out
end

--- The full rings on the ground (1.88.0: ring_3d at fraction 1 -- under what
--- is on you or yours, under a node, on a quest area), not a cast's ring.
--- Each is { pos, radius, fraction, colour, opts }.
local function ground_rings(calls)
    local out = {}
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "ring_3d" and c[3] == 1 then out[#out + 1] = c end
    end
    return out
end

local T = {}

-- --- the mark ------------------------------------------------------------------

T[#T + 1] = { "a hostile mob with no art: its type for a name, a health bar, then level and distance", function()
    local F, calls, add = bundle({ settings = { show_box = true } })
    add(unit({ guid = "a", screen = { x = 500, y = 400 }, hp = 0.5 }), { is_enemy = true, dist = 28 })
    F.render(true, 100)
    local name = find_text(calls, "Elemental")
    assert(name, "named by its creature type: " .. table.concat(texts(calls), " | "))
    assert(name.at.y > 400, "under the feet")
    assert_eq(name.c.r, 235, "hostile red")
    local dist = find_text(calls, "28y")
    assert(dist, "distance: " .. table.concat(texts(calls), " | "))
    assert(not find_text(calls, "50%"), "no health number by default: the bar says it")
    local level
    for i = 1, #calls do
        if calls[i].name == "text" and calls[i].text == "4" then level = calls[i] end
    end
    assert(level, "the level drawn on its own")
    assert_eq(level.c.g, 209, "in the target frame's yellow: my level")
    assert_eq(level.at.y, dist.at.y, "on the same row")
    assert(level.at.x < dist.at.x, "before the distance")
    local bar = false
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "bar" and c.h == 4 and c.w == 54 and c.fraction == 0.5 then bar = true end
    end
    assert(bar, "a health bar half full (1.88.0: JCore's soft bar)")
    assert_eq(F.stats().drawn, 1, "drawn")
    -- 1.7.6: curtains are off by default; the corners are the default again.
    assert_eq(#all(calls, "box"), 1, "the box, switched on, within full detail range: the corners by default")
    assert_eq(#all(calls, "curtain_3d"), 0, "not a curtain")

    local F2, calls2, add2 = bundle({ settings = { show_health_text = true } })
    add2(unit({ guid = "a", screen = { x = 500, y = 400 }, hp = 0.5 }), { is_enemy = true, dist = 28 })
    F2.render(true, 100)
    assert(find_text(calls2, "50%"), "the number when asked for: " .. table.concat(texts(calls2), " | "))
    assert_eq(#all(calls2, "box") + #all(calls2, "curtain_3d"), 0, "no box by default")
end }

T[#T + 1] = { "quest paths: the marks a quest wants are listed for them, the rest not (1.55.4)", function()
    local asked = {}
    local quests = { quest_entries = function(obj, name, npc, is_object)
        asked[#asked + 1] = npc
        if npc == 1124 then return { { quest = { id = 7 } } } end
        return nil
    end }
    local F, _, add = bundle({ quests = quests })
    add(unit({ guid = "wolf", npc = 1124, screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 28 })
    add(unit({ guid = "boar", npc = 1125, screen = { x = 700, y = 400 } }), { is_enemy = true, dist = 18 })
    F.render(true, 100)
    assert_eq(F.count(), 1, "one quest target")
    local e = F.entities()[1]
    assert_eq(e.guid, "wolf", "the wolf")
    assert_eq(e.distance, 28, "with its distance")
    assert_eq(e.quest_entries[1].quest.id, 7, "and its quest")
    assert_eq(#asked, 2, "asked by npc id, once a mark")

    local F2, _, add2 = bundle({ quests = quests, settings = { quest_lines = false } })
    add2(unit({ guid = "wolf", npc = 1124, screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 28 })
    F2.render(true, 100)
    assert_eq(F2.count(), 0, "quest paths off: nothing listed")
end }

T[#T + 1] = { "the switches: no name, exact health, no distance, no box", function()
    local F, calls, add = bundle({ settings = {
        show_name = false, show_health_text = true, show_health_exact = true, show_distance = false, show_box = false,
    } })
    add(unit({ guid = "a", screen = { x = 500, y = 400 }, hp = 0.5 }), { is_enemy = true, dist = 28 })
    F.render(true, 100)
    assert(not find_text(calls, "Elemental"), "no name")
    assert(find_text(calls, "100/200"), "health as numbers: " .. table.concat(texts(calls), " | "))
    assert(not find_text(calls, "28y"), "no distance")
    assert_eq(#all(calls, "box") + #all(calls, "curtain_3d"), 0, "no box")
end }

T[#T + 1] = { "the art pack: the icon says what it is, so a name it does not know is not said again", function()
    local F, calls, add = bundle({ art = true })
    add(unit({ guid = "e", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "p", screen = { x = 900, y = 300 }, class = 4 }), { is_enemy = true, is_player = true, dist = 11 })
    add(unit({ guid = "s", screen = { x = 1500, y = 300 }, skin = true }), { dead = true, dist = 12 })
    F.render(true, 100)
    local refs = {}
    for _, c in ipairs(all(calls, "image")) do refs[c.ref] = refs[c.ref] or c end
    assert(refs["art:creature.4"], "the elemental's type icon")
    assert(refs["art:class.4"], "the rogue's class crest")
    assert(refs["art:skin"], "the pelt on the corpse")
    assert(not find_text(calls, "Elemental"), "no type word beside the type icon: " .. table.concat(texts(calls), " | "))
    assert(not find_text(calls, "Rogue"), "no class word beside the crest")
    assert(not find_text(calls, "SKIN"), "no SKIN beside the pelt")
    -- Icons beside text, never under a backdrop: every icon left of the
    -- first text of its card.
    local skin = refs["art:skin"]
    local dist = find_text(calls, "12y")
    assert(skin.at.x + skin.w <= dist.at.x - dist.text:len() * 6.5 * 0.5 + 0.01, "the pelt left of the distance")

    -- A real name stays beside the icon.
    local F2, calls2, add2 = bundle({ art = true })
    add2(unit({ guid = "n", name = "Kobold Vermin", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    F2.render(true, 100)
    local name = find_text(calls2, "Kobold Vermin")
    assert(name, "the name: " .. table.concat(texts(calls2), " | "))
    local icon = all(calls2, "image")[1]
    assert(icon and icon.ref == "art:creature.4", "its type icon")
    assert(icon.at.x + icon.w <= name.at.x - (#"Kobold Vermin" * 6.5) * 0.5 + 1, "left of the name")

    -- Without the art pack: the words, and the name back in the middle.
    local F3, calls3, add3 = bundle()
    add3(unit({ guid = "e", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    F3.render(true, 100)
    assert_eq(#all(calls3, "image"), 0, "no icon without the art pack")
    assert_eq(find_text(calls3, "Elemental").at.x, 300, "the name centred on the feet")
end }

T[#T + 1] = { "neutral is yellow, a hostile player red with its class", function()
    local F, calls, add = bundle()
    add(unit({ guid = "n", screen = { x = 300, y = 300 }, hostile = false }), { is_enemy = true })
    add(unit({ guid = "p", screen = { x = 900, y = 300 }, class = 4 }), { is_enemy = true, is_player = true })
    F.render(true, 100)
    assert_eq(find_text(calls, "Elemental").c.g, 190, "neutral yellow")
    local rogue = find_text(calls, "Rogue")
    assert(rogue, "a player is named by class")
    assert_eq(rogue.c.r, 235, "hostile player red")
end }

T[#T + 1] = { "critters: not marked unless the Critters switch is on (1.47.1)", function()
    local critter = { guid = "c", screen = { x = 300, y = 300 }, ctype = 8, level = 1, hostile = false }
    local F, calls, add = bundle()
    add(unit(critter), { is_enemy = true, dist = 10 })
    add(unit({ guid = "m", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    assert(not find_text(calls, "Critter"), "no critter mark: " .. table.concat(texts(calls), " | "))
    assert(find_text(calls, "Elemental"), "the mob beside it is marked")
    assert_eq(F.stats().drawn, 1, "one mark")

    local F2, calls2, add2 = bundle({ settings = { critter_on = true } })
    add2(unit(critter), { is_enemy = true, dist = 10 })
    F2.render(true, 100)
    assert(find_text(calls2, "Critter"), "marked with the switch on")
end }

T[#T + 1] = { "a critter a quest wants killed is marked with critters off", function()
    _G.core.quests = {}
    local rat = unit({ guid = "r", screen = { x = 300, y = 300 }, ctype = 8, level = 1, hostile = false, npc = 4075 })
    local F, calls, add, handlers = bundle({ target = rat })
    add(rat, { is_enemy = true, dist = 10 })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Rat", "Cast-1", 1752 })
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 316, "Rat slain: 2/8", "ERR_QUEST_ADD_KILL_SII" })
    F.render(true, 100)
    assert(find_text(calls, "KILL") and find_text(calls, "2/8"), "the quest's critter: " .. table.concat(texts(calls), " | "))
end }

T[#T + 1] = { "ten mobs on one spot: every one is drawn, none vanishes", function()
    local F, calls, add = bundle()
    for i = 1, 10 do
        add(unit({ guid = "m" .. i, screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 + i })
    end
    F.render(true, 100)
    local s = F.stats()
    assert_eq(s.drawn, 10, "all ten marked")
    assert(s.crowded > 0, "the crowd printed where it stood rather than vanish")
    local names = 0
    for _, t in ipairs(texts(calls)) do if t == "Elemental" then names = names + 1 end end
    assert_eq(names, 10, "ten names drawn")
end }

T[#T + 1] = { "two mobs on one spot: the second moves down clear of the first", function()
    local F, calls, add = bundle()
    add(unit({ guid = "a", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    add(unit({ guid = "b", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 21 })
    F.render(true, 100)
    local ys = {}
    for i = 1, #calls do
        if calls[i].name == "text" and calls[i].text == "Elemental" then ys[#ys + 1] = calls[i].at.y end
    end
    assert_eq(#ys, 2, "both named")
    assert(ys[2] > ys[1] + 20, "the second below the first's block")
    assert_eq(F.stats().crowded, 0, "no overprint needed")
end }

T[#T + 1] = { "corpses: a skinnable one says SKIN; one with nothing to do is not marked", function()
    local F, calls, add = bundle()
    add(unit({ guid = "s", screen = { x = 300, y = 300 }, skin = true }), { dead = true, dist = 15 })
    add(unit({ guid = "x", screen = { x = 700, y = 300 }, skin = false }), { dead = true, dist = 16 })
    F.render(true, 100)
    assert(find_text(calls, "SKIN"), "skin pill")
    assert_eq(F.stats().drawn, 1, "only the skinnable corpse")
end }

T[#T + 1] = { "corpses: SKIN only when your Skinning reaches it, else not marked or tried; no level (1.67.0)", function()
    -- Skinning 60: up to level 16 (60), not 17 (70). JCore's rule, faked here.
    local asked = {}
    local me = { can_skin = function(level)
        asked[#asked + 1] = level
        local required = level <= 10 and 1 or (level <= 20 and (level - 10) * 10 or level * 5)
        return 60 >= required, required, 60, "profession"
    end }
    local F, calls, add, _, traces = bundle({ player = me, settings = { autoloot_on = true } })
    add(unit({ guid = "ok", level = 16, screen = { x = 300, y = 300 }, skin = true }), { dead = true, dist = 8 })
    add(unit({ guid = "high", level = 17, screen = { x = 700, y = 300 }, skin = true }), { dead = true, dist = 9 })
    F.render(true, 100)
    assert_eq(F.stats().drawn, 1, "only the one you can skin: " .. table.concat(texts(calls), " | "))
    assert(find_text(calls, "SKIN"), "SKIN on it")
    assert(find_text(calls, "8y"), "its distance")
    assert(not find_text(calls, "16"), "no level on a corpse")
    local corpses = F.corpses()
    assert_eq(#corpses, 1, "the automation is handed only that one")
    assert_eq(corpses[1].guid, "ok", "the level 16")
    local said = false
    for i = 1, #traces do
        if tostring(traces[i]):find("fesp skinning: skill 60 (profession)", 1, true) then said = true end
    end
    assert(said, "the skill and where it came from, in the trace")

    -- No JCore answer (older than 1.8.5): nothing is hidden.
    local F2, calls2, add2 = bundle()
    add2(unit({ guid = "high", level = 17, screen = { x = 700, y = 300 }, skin = true }), { dead = true, dist = 9 })
    F2.render(true, 100)
    assert(find_text(calls2, "SKIN"), "an older JCore: as before")
end }

T[#T + 1] = { "a mob's level in its target frame's colour: grey, green, yellow, orange, red", function()
    local want = { [13] = { 128, 128, 128 }, [16] = { 64, 191, 64 }, [22] = { 255, 209, 0 },
        [23] = { 255, 128, 64 }, [25] = { 255, 26, 26 } }
    local F, calls, add = bundle({ my_level = 20 })
    local x = 100
    for level in pairs(want) do
        add(unit({ guid = "m" .. level, level = level, screen = { x = x, y = 300 } }), { is_enemy = true, dist = 20 })
        x = x + 350
    end
    F.render(true, 100)
    for level, rgb in pairs(want) do
        local text
        for i = 1, #calls do
            if calls[i].name == "text" and calls[i].text == tostring(level) then text = calls[i] end
        end
        assert(text, "level " .. level .. " drawn on its own: " .. table.concat(texts(calls), " | "))
        assert_eq(text.c.r, rgb[1], "level " .. level .. " red")
        assert_eq(text.c.g, rgb[2], "level " .. level .. " green")
        assert_eq(text.c.b, rgb[3], "level " .. level .. " blue")
    end
end }

-- --- what it is doing ------------------------------------------------------------

T[#T + 1] = { "a cast: name, time left and a bar; purple when it can be kicked; on you in red", function()
    local now = math.floor(clock.s * 1000)
    local F, calls, add = bundle({ enemies = {
        c = { targeting_me = true, in_combat = true,
            casting = { spell_id = 1248802, start_at = now - 500, end_at = now + 1500, interruptible = true } },
    } })
    add(unit({ guid = "c", screen = { x = 500, y = 400 } }), { is_enemy = true })
    F.render(true, 100)
    assert(find_text(calls, "Corrupted Wind 1.5s"), "cast name and time: " .. table.concat(texts(calls), " | "))
    assert(not find_text(calls, "on you"), "on you is the ring under it, not a row")
    local purple, bar = false, false
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "plate" and c.o and c.o.border and c.o.border.r == 170 then purple = true end
        if c.name == "bar" and c.h == 3 and c.c.r == 170 and math.abs(c.fraction - 0.25) < 1e-6 then bar = true end
    end
    assert(purple, "an interruptible cast is outlined purple (the plate's border)")
    assert(bar, "with a progress bar under it")
end }

T[#T + 1] = { "a channel read as nonsense (3739147998, seen on Forever) is not a cast", function()
    local F, calls, add = bundle({ enemies = {
        c = { casting = { spell_id = 3739147998, channel = true, start_at = 1, end_at = 2 } },
    } })
    add(unit({ guid = "c", screen = { x = 500, y = 400 } }), { is_enemy = true })
    F.render(true, 100)
    assert(not find_text(calls, "Casting"), "no cast pill: " .. table.concat(texts(calls), " | "))
end }

T[#T + 1] = { "status: crowd control first, then on your pet, then in combat", function()
    local F, calls, add = bundle({ enemies = {
        a = { targeting_me = true, control = { spell_id = 118, remaining = 4.2 } },
        b = { targeting_pet = true, in_combat = true },
        c = { in_combat = true },
    } })
    add(unit({ guid = "a", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "b", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 11 })
    add(unit({ guid = "c", screen = { x = 1500, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    assert(find_text(calls, "Polymorph 4s"), "the crowd control, ahead of on you")
    assert(not find_text(calls, "on your pet"), "on your pet is the amber ring, not a row")
    assert(not find_text(calls, "in combat"), "in combat is never words")

    -- With the ring off, who it is on is a row again.
    local F2, calls2, add2 = bundle({ settings = { show_aggro = false }, enemies = {
        b = { targeting_pet = true, in_combat = true }, m = { targeting_me = true },
    } })
    add2(unit({ guid = "b", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 11 })
    add2(unit({ guid = "m", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 12 })
    F2.render(true, 100)
    assert(find_text(calls2, "on your pet"), "on your pet: " .. table.concat(texts(calls2), " | "))
    assert(find_text(calls2, "on you"), "on you")
    assert_eq(#all(calls2, "ring_3d") + #all(calls2, "circle_3d"), 0, "no ring")
end }

T[#T + 1] = { "threat from the threat service; the fight role from what it was seen to cast", function()
    local boards = { a = { count = 3, me = { percent = 72, rank = 2 } } }
    local F, calls, add = bundle({
        enemies = { a = { in_combat = true } },
        threat = { get = function(guid) return boards[guid] end },
        fight = { role = function(info) return info.npc_id == 251143 and "caster" or nil end },
    })
    add(unit({ guid = "a", screen = { x = 500, y = 400 } }), { is_enemy = true })
    F.render(true, 100)
    assert(find_text(calls, "threat 72% \194\183 #2 of 3"), "threat: " .. table.concat(texts(calls), " | "))
    assert(find_text(calls, "CASTER"), "fight role")
end }

T[#T + 1] = { "on you: a red ring under it and a line from it to you; within six yards, no line", function()
    local F, calls, add = bundle({ enemies = {
        far = { targeting_me = true }, near = { targeting_me = true },
    } })
    add(unit({ guid = "far", screen = { x = 500, y = 400 }, pos = { x = 20, y = 0, z = 0 } }), { is_enemy = true, dist = 20 })
    add(unit({ guid = "near", screen = { x = 900, y = 400 }, pos = { x = 3, y = 0, z = 0 } }), { is_enemy = true, dist = 3 })
    F.render(true, 100)
    assert_eq(#ground_rings(calls), 2, "a ring under each")
    assert_eq(ground_rings(calls)[1][4].r, 240, "red")
    assert_eq(#all(calls, "line_3d"), 1, "a line only from the one still on its way")
end }

T[#T + 1] = { "the rings are see-through: a thin band at the rim, and a pile of them is fainter", function()
    local enemies, n = { mine = { targeting_me = true } }, 6
    for i = 1, n do enemies["pet" .. i] = { targeting_pet = true } end
    local F, calls, add = bundle({ enemies = enemies })
    for i = 1, n do
        add(unit({ guid = "pet" .. i, screen = { x = 150 * i, y = 400 }, pos = { x = 4 + i * 0.3, y = 0, z = 0 } }),
            { is_enemy = true, dist = 5 })
    end
    add(unit({ guid = "mine", screen = { x = 900, y = 700 }, pos = { x = 3, y = 0, z = 0 } }), { is_enemy = true, dist = 3 })
    F.render(true, 100)
    assert_eq(#ground_rings(calls), n + 1, "a ring under each")
    for i = #calls, 1, -1 do calls[i] = nil end
    F.render(true, 100)
    local rings = ground_rings(calls)
    assert_eq(#rings, n + 1, "a ring under each, next frame")
    local on_you, on_pet = 0, 0
    for i = 1, #rings do
        local c, o = rings[i][4], rings[i][5]
        assert_eq(o.inner, 0.86, "a thin band (1.88.0)")
        assert_eq(o.outer, 1.0, "out to its reach")
        assert_eq(o.bg.a, 0, "nothing painted inside the band")
        assert_eq(rings[i][2], 1.2, "at the mob's reach")
        if c.g == 80 then
            on_you = on_you + 1
            assert_eq(c.a, 120, "on you, seven down: 60% of one alone")
        else
            on_pet = on_pet + 1
            assert_eq(c.g, 170, "amber")
            assert_eq(c.a, 68, "on the pet, seven down: 45% of one alone")
            assert_eq(o.thickness, 1.5, "thinner than on you")
        end
    end
    assert_eq(on_you, 1, "one red")
    assert_eq(on_pet, n, "the rest amber")
end }

T[#T + 1] = { "one mob on the pet alone: an amber ring at its full, still see-through, strength", function()
    local F, calls, add = bundle({ enemies = { a = { targeting_pet = true } } })
    add(unit({ guid = "a", screen = { x = 500, y = 400 }, pos = { x = 5, y = 0, z = 0 } }), { is_enemy = true, dist = 5 })
    F.render(true, 100)
    F.render(true, 100)
    local rings = ground_rings(calls)
    assert_eq(#rings, 2, "a ring each frame")
    assert_eq(rings[2][4].a, 150, "alone")
end }

T[#T + 1] = { "a JCore without ring_3d (before 1.88.0's look): the outline circle, its fast fade on the rim", function()
    local enemies, n = { mine = { targeting_me = true } }, 6
    for i = 1, n do enemies["pet" .. i] = { targeting_pet = true } end
    local F, calls, add, _, _, _, _, add_object = bundle({ enemies = enemies, old_draw = true })
    for i = 1, n do
        add(unit({ guid = "pet" .. i, screen = { x = 150 * i, y = 400 }, pos = { x = 4 + i * 0.3, y = 0, z = 0 } }),
            { is_enemy = true, dist = 5 })
    end
    add(unit({ guid = "mine", screen = { x = 900, y = 700 }, pos = { x = 3, y = 0, z = 0 } }), { is_enemy = true, dist = 3 })
    add_object(gobject({ guid = "h", name = "Peacebloom", screen = { x = 300, y = 900 } }), { dist = 12 })
    F.render(true, 100)
    for i = #calls, 1, -1 do calls[i] = nil end
    F.render(true, 100)
    local rings = all(calls, "circle_3d")
    assert_eq(#rings, n + 2, "a circle under each mob and the herb")
    local faded = 0
    for i = 1, #rings do
        local o = rings[i][4]
        assert(not o.filled, "never filled")
        if rings[i][2] == 1.2 then
            assert(o.fade >= 5, "a fast fade, not JCore's 1.0 that fills the disc")
            faded = faded + 1
            if rings[i][3].g == 80 then assert_eq(rings[i][3].a, 120, "still fainter in a pile") end
        else
            assert_eq(rings[i][2], 0.9, "the node's")
        end
    end
    assert_eq(faded, n + 1, "the aggro rings")
    assert_eq(#all(calls, "ring_3d"), 0, "no shader ring")
    assert(#all(calls, "rect") > 0 and #all(calls, "plate") + #all(calls, "bar") == 0, "the flat card shapes")
end }

-- --- off the marks: the panel, arrows and alerts --------------------------------------

T[#T + 1] = { "threat panel: what is on you first, a hostile player near; a quiet mob is not listed", function()
    local F, calls, add = bundle({ enemies = { onme = { targeting_me = true } } })
    add(unit({ guid = "quiet", screen = { x = 100, y = 100 } }), { is_enemy = true, dist = 5 })
    add(unit({ guid = "pvp", screen = { x = 200, y = 100 }, class = 1 }), { is_enemy = true, is_player = true, dist = 30 })
    add(unit({ guid = "onme", screen = { x = 300, y = 100 } }), { is_enemy = true, dist = 40 })
    F.render(true, 100)
    F.draw_threat_panel()
    local panel = all(calls, "panel")[1]
    assert(panel, "a panel")
    assert_eq(panel.o.title, "THREATS  (2)", "two threats")
    local list = F.threats()
    assert_eq(list[1].guid, "onme", "on you first, though farther")
    assert_eq(list[2].guid, "pvp", "then the player")
end }

T[#T + 1] = { "arrows: a threat off screen gets one at the edge, pointing its way", function()
    local F, calls, add = bundle({ settings = { alert_arrows = true }, enemies = { behind = { targeting_me = true } } })
    -- Facing +x; the mob is straight behind, at -x.
    add(unit({ guid = "behind", screen = nil, pos = { x = -20, y = 0, z = 0 } }), { is_enemy = true, dist = 20 })
    F.render(true, 100)
    F.draw_threat_arrows()
    local arrow = all(calls, "arrow_2d")[1]
    assert(arrow, "an arrow")
    assert(arrow[1].y > 540 + 300, "at the bottom edge: behind you")
end }

T[#T + 1] = { "alerts: a hostile player once per cooldown; a mob two levels up coming at you", function()
    local F, _, add, _, _, emitted = bundle({ my_level = 4, enemies = { big = { activity = "approaching" } } })
    add(unit({ guid = "pvp", screen = { x = 200, y = 100 }, class = 1 }), { is_enemy = true, is_player = true, dist = 30 })
    add(unit({ guid = "big", screen = { x = 300, y = 100 }, level = 7 }), { is_enemy = true, dist = 25 })
    add(unit({ guid = "small", screen = { x = 400, y = 100 }, level = 4 }), { is_enemy = true, dist = 25 })
    sounds = {}
    F.render(true, 100)
    F.alert_check()
    F.alert_check()
    assert_eq(#sounds, 2, "one sound each for the player and the big mob, once")
    local reasons = {}
    for i = 1, #emitted do reasons[emitted[i][2].reason] = true end
    assert(reasons["Hostile player"] and reasons["Dangerous mob"], "both announced")
end }

-- --- names, range, the trace ---------------------------------------------------------

T[#T + 1] = { "off screen: not drawn, counted, traced", function()
    clock.s = clock.s + 5
    local F, calls, add, _, traces = bundle()
    add(unit({ guid = "far", screen = nil }), { is_enemy = true, dist = 40 })
    F.render(true, 100)
    assert_eq(#texts(calls), 0, "nothing drawn")
    assert_eq(F.stats().offscreen, 1, "counted")
    local seen = false
    for i = 1, #traces do if traces[i]:find("offscreen", 1, true) then seen = true end end
    assert(seen, "the trace says why")
end }

T[#T + 1] = { "a name learned from casting at the target names every mob of that kind", function()
    local wolf1 = unit({ guid = "w1", screen = { x = 300, y = 300 }, npc = 777 })
    local wolf2 = unit({ guid = "w2", screen = { x = 700, y = 300 }, npc = 777 })
    local F, calls, add, handlers = bundle({ target = wolf1 })
    add(wolf1, { is_enemy = true })
    add(wolf2, { is_enemy = true })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Mangy Wolf", "Cast-1", 1752 })
    F.render(true, 100)
    local n = 0
    for _, t in ipairs(texts(calls)) do if t == "Mangy Wolf" then n = n + 1 end end
    assert_eq(n, 2, "both wolves named")
    local _, source = F.name_for(wolf2)
    assert_eq(source, "learned", "the second by its npc id")
end }

-- --- quests ----------------------------------------------------------------------------

local function pills_text(calls)
    return table.concat(texts(calls), " | ")
end

T[#T + 1] = { "a quest giver never talked to: a dim QUEST, even with friendly npcs off", function()
    _G.core.quests = {}
    local F, calls, add = bundle()
    add(unit({ guid = "g", screen = { x = 500, y = 400 }, flags = 3, ctype = 7 }), { is_enemy = false, dist = 10 })
    add(unit({ guid = "v", screen = { x = 900, y = 400 }, flags = 4224, ctype = 7 }), { is_enemy = false, dist = 11 })
    F.render(true, 100)
    assert(find_text(calls, "QUEST"), "the giver: " .. pills_text(calls))
    assert_eq(F.stats().drawn, 1, "the vendor is not marked")
end }

T[#T + 1] = { "a Spirit Healer has the quest giver bit and no quest: never QUEST (1.78.2)", function()
    -- 16387 = gossip, quest giver, spirit healer: what Forever's graveyard
    -- Spirit Healer answered, marked QUEST for whole sessions before this.
    _G.core.quests = {}
    local F, calls, add = bundle()
    add(unit({ guid = "s", screen = { x = 500, y = 400 }, flags = 16387, ctype = 7, npc = 6491 }),
        { is_enemy = false, dist = 18 })
    F.render(true, 100)
    assert(not find_text(calls, "QUEST"), "no quest mark: " .. pills_text(calls))
    assert_eq(F.quests.is_giver_flags(16387), false, "a spirit healer is no giver")
    assert_eq(F.quests.is_giver_flags(0x8000 + 3), false, "nor a spirit guide")
    assert_eq(F.quests.is_giver_flags(3), true, "a plain giver still is")
end }

T[#T + 1] = { "PICK UP from the giver's window, gone once taken, TURN IN where it goes back, gone once handed in", function()
    local giver = unit({ guid = "g", screen = { x = 500, y = 400 }, flags = 3, ctype = 7, npc = 257554 })
    local available, active = {}, {}
    local on = {}
    _G.core.quests = {
        get_gossip_available_quests = function() return available end,
        get_gossip_active_quests = function() return active end,
        is_on_quest = function(id) return on[id] == true end,
        is_quest_flagged_completed = function() return false end,
    }
    local F, calls, add, handlers = bundle({ target = giver })
    add(giver, { is_enemy = false, dist = 5 })

    available = { { quest_id = 94414, title = "The Anchors of Zephras", quest_level = 2 } }
    handlers["jcore.game_event.GOSSIP_SHOW"]({})
    F.render(true, 100)
    assert(find_text(calls, "PICK UP"), "offered: " .. pills_text(calls))

    on[94414] = true
    handlers["jcore.game_event.QUEST_ACCEPTED"]({ 94414 })
    available = {}
    active = { { quest_id = 94414, title = "The Anchors of Zephras", quest_level = 2, is_complete = false } }
    handlers["jcore.game_event.GOSSIP_SHOW"]({})
    local n = #calls
    F.render(true, 100)
    local after = {}
    for i = n + 1, #calls do after[#after + 1] = calls[i] end
    assert(find_text(after, "QUEST") and not find_text(after, "PICK UP"), "taken, not done: " .. pills_text(after))

    active[1].is_complete = true
    handlers["jcore.game_event.GOSSIP_SHOW"]({})
    n = #calls
    F.render(true, 100)
    after = {}
    for i = n + 1, #calls do after[#after + 1] = calls[i] end
    assert(find_text(after, "TURN IN"), "done: " .. pills_text(after))

    on[94414] = false
    handlers["jcore.game_event.QUEST_TURNED_IN"]({ 94414, 550, 100 })
    n = #calls
    F.render(true, 100)
    after = {}
    for i = n + 1, #calls do after[#after + 1] = calls[i] end
    assert(not find_text(after, "TURN IN") and not find_text(after, "PICK UP"), "handed in: " .. pills_text(after))
end }

T[#T + 1] = { "KILL 4/6 on the mobs an objective names, by their learned name; none once it is 6/6", function()
    _G.core.quests = {}
    local wind = unit({ guid = "w", screen = { x = 500, y = 400 }, npc = 251143 })
    local other = unit({ guid = "o", screen = { x = 900, y = 400 }, npc = 250873 })
    local F, calls, add, handlers = bundle({ target = wind })
    add(wind, { is_enemy = true, dist = 10 })
    add(other, { is_enemy = true, dist = 11 })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Roiling Winds", "Cast-1", 1752 })
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 316, "Roiling Winds destroyed: 4/6", "ERR_QUEST_ADD_FOUND_SII" })
    F.render(true, 100)
    local kill, count = find_text(calls, "KILL"), find_text(calls, "4/6")
    assert(kill and count, "the objective's mob, a kill even though the game says destroyed: " .. pills_text(calls))
    assert(count.at.x < 700, "on the Roiling Winds, not the other mob")

    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 316, "Roiling Winds destroyed: 6/6", "ERR_QUEST_ADD_FOUND_SII" })
    local n = #calls
    F.render(true, 100)
    local after = {}
    for i = n + 1, #calls do after[#after + 1] = calls[i] end
    assert(not find_text(after, "KILL"), "done: " .. pills_text(after))

    -- A message that is not progress is not an objective.
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "You must choose a reward.", "ERR_QUEST_MUST_CHOOSE" })
    assert_eq(F.quests.stats().objectives, 1, "only the progress message counted")
end }

T[#T + 1] = { "quest objects: USE on what the client tags (Quest), without the tag; a vein is an ore node, not a quest object", function()
    _G.core.quests = {}
    local F, calls, _, _, _, _, _, add_object = bundle()
    add_object(gobject({ guid = "t", name = "Ley Line Trap (Quest)", screen = { x = 500, y = 400 } }), { dist = 12 })
    add_object(gobject({ guid = "c", name = "Copper Vein", screen = { x = 900, y = 400 } }), { dist = 13 })
    F.render(true, 100)
    local use = find_text(calls, "USE")
    assert(use and use.at.x < 700, "the quest object: " .. pills_text(calls))
    local name = find_text(calls, "Ley Line Trap")
    assert(name and not name.text:find("Quest"), "named without the tag")
    local vein = find_text(calls, "Copper Vein")
    assert(vein, "the vein is marked as ore: " .. pills_text(calls))
    assert_eq(#all(calls, "box"), 0, "no box on an object")
end }

-- --- quest objects from the quest database (1.59.0) -------------------------------------

--- JCore's questdb as it answers from the extracted QuestieDB rows: get(kind,
--- id, key), with the rows given as { quest = { [id] = row }, ... }.
local function since(calls, from)
    local out = {}
    for i = from + 1, #calls do out[#out + 1] = calls[i] end
    return out
end

local function fake_questdb(rows)
    return { get = function(kind, id, key)
        local by_kind = rows[kind]
        local row = by_kind and by_kind[id]
        return row and row[key] or nil
    end }
end

--- quests.lua's index as it answers for objects: entries by the object's
--- name (the id is not proven on Forever, so it is never asked).
local function fake_index(by_name)
    return { quest_entries = function(obj, name, npc, is_object)
        if not is_object or npc ~= false then return nil end
        return by_name[name]
    end }
end

-- The Bundle of Wood, as the extracted data has it (quest 5545, item 13872,
-- object 176793), and the quest for it as the index files it.
local BUNDLE_DB = {
    quest = { [5545] = { name = "A Bundle of Trouble", objectives = { [3] = { { 13872, nil, 0 } } } } },
    item = { [13872] = { name = "Bundle of Wood", objectDrops = { 176793 } } },
    object = { [176793] = { name = "Bundle of Wood" } },
}
local BUNDLE_INDEX = {
    ["Bundle of Wood"] = { { quest = { id = 5545, name = "A Bundle of Trouble" }, tag = "collect" } },
}

T[#T + 1] = { "quest objects from the quest database: COLLECT before the first pickup, the count after, gone at 8/8", function()
    _G.core.quests = {}
    local F, calls, _, handlers, traces, _, _, add_object = bundle({
        quests = fake_index(BUNDLE_INDEX), questdb = fake_questdb(BUNDLE_DB) })
    add_object(gobject({ guid = "b", name = "Bundle of Wood", screen = { x = 500, y = 400 } }), { dist = 12 })
    add_object(gobject({ guid = "x", name = "Bundle of Hay", screen = { x = 900, y = 400 } }), { dist = 13 })

    F.render(true, 100)
    local chip = find_text(calls, "COLLECT")
    assert(chip, "marked before anything is picked up: " .. pills_text(calls))
    assert_eq(chip.text, "COLLECT", "no count heard yet")
    assert(chip.at.x < 700, "on the bundle")
    assert(find_text(calls, "A Bundle of Trouble"), "the quest's title under it")
    assert(not find_text(calls, "Bundle of Hay"), "an object no quest wants is not marked")
    local said = false
    for i = 1, #traces do
        if traces[i]:find("db: Bundle of Wood is wanted by A Bundle of Trouble (5545): COLLECT", 1, true) then said = true end
    end
    assert(said, "traced once: " .. table.concat(traces, " || "))
    assert_eq(F.quests.stats().db_objects, 1, "one object marked from the database")

    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "Bundle of Wood: 1/8", "ERR_QUEST_ADD_ITEM_SII" })
    local n = #calls
    F.render(true, 100)
    local after = since(calls, n)
    assert(find_text(after, "COLLECT") and find_text(after, "1/8"), "the count once the game reports one: " .. pills_text(after))

    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "Bundle of Wood: 8/8", "ERR_QUEST_ADD_ITEM_SII" })
    n = #calls
    F.render(true, 100)
    after = since(calls, n)
    assert(not find_text(after, "COLLECT"), "done: " .. pills_text(after))
    assert(not find_text(after, "Bundle of Wood"), "and no longer marked")
end }

T[#T + 1] = { "quest objects from the quest database: a basket counts the item inside it, and goes with it", function()
    _G.core.quests = {}
    local db = fake_questdb({
        quest = { [315] = { name = "The Perfect Stout", objectives = { [3] = { { 2676, nil, 0 } } } } },
        item = { [2676] = { name = "Shimmerweed", objectDrops = { 142181 } } },
        object = { [142181] = { name = "Shimmerweed Basket" } },
    })
    local index = fake_index({
        ["Shimmerweed Basket"] = { { quest = { id = 315, name = "The Perfect Stout" }, tag = "collect" } },
    })
    local F, calls, _, handlers, _, _, _, add_object = bundle({ quests = index, questdb = db })
    add_object(gobject({ guid = "s", name = "Shimmerweed Basket", screen = { x = 500, y = 400 } }), { dist = 12 })
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "Shimmerweed: 2/6", "ERR_QUEST_ADD_ITEM_SII" })
    F.render(true, 100)
    assert(find_text(calls, "COLLECT") and find_text(calls, "2/6"), "the item's count on the basket: " .. pills_text(calls))

    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "Shimmerweed: 6/6", "ERR_QUEST_ADD_ITEM_SII" })
    local n = #calls
    F.render(true, 100)
    local after = since(calls, n)
    assert(not find_text(after, "COLLECT") and not find_text(after, "Shimmerweed Basket"), "done: " .. pills_text(after))
end }

T[#T + 1] = { "quest objects from the quest database: USE on an object objective, gone by its own objective text", function()
    _G.core.quests = {}
    local db = fake_questdb({
        quest = { [633] = { name = "The Thandol Span", objectives = { [2] = { { 2704, "Cache of Explosives Destroyed", 0 } } } } },
        object = { [2704] = { name = "Cache of Explosives" } },
    })
    local index = fake_index({
        ["Cache of Explosives"] = { { quest = { id = 633, name = "The Thandol Span" }, tag = "use" } },
    })
    local F, calls, _, handlers, _, _, _, add_object = bundle({ quests = index, questdb = db })
    add_object(gobject({ guid = "c", name = "Cache of Explosives", screen = { x = 500, y = 400 } }), { dist = 12 })
    F.render(true, 100)
    local chip = find_text(calls, "USE")
    assert(chip and chip.text == "USE", "USE, no count yet: " .. pills_text(calls))

    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 0, "Cache of Explosives Destroyed: 1/1", "ERR_QUEST_ADD_FOUND_SII" })
    local n = #calls
    F.render(true, 100)
    local after = since(calls, n)
    -- Still a container by the name rules ("Cache"), but no longer a quest object.
    assert(not find_text(after, "USE"), "done: " .. pills_text(after))
end }

T[#T + 1] = { "quest objects from the quest database: a quest turned in wants nothing; quest marks off, nothing", function()
    _G.core.quests = {}
    local F, calls, _, handlers, _, _, _, add_object = bundle({
        quests = fake_index(BUNDLE_INDEX), questdb = fake_questdb(BUNDLE_DB) })
    add_object(gobject({ guid = "b", name = "Bundle of Wood", screen = { x = 500, y = 400 } }), { dist = 12 })
    handlers["jcore.game_event.QUEST_TURNED_IN"]({ 5545, 450, 0 })
    F.render(true, 100)
    assert(not find_text(calls, "COLLECT"), "turned in: " .. pills_text(calls))

    local F2, calls2, _, _, _, _, _, add_object2 = bundle({ settings = { questie_on = false },
        quests = fake_index(BUNDLE_INDEX), questdb = fake_questdb(BUNDLE_DB) })
    add_object2(gobject({ guid = "b", name = "Bundle of Wood", screen = { x = 500, y = 400 } }), { dist = 12 })
    F2.render(true, 100)
    assert(not find_text(calls2, "COLLECT"), "quest marks off: " .. pills_text(calls2))
end }

T[#T + 1] = { "\"Unknown\" is not a name: never learned, never shown", function()
    _G.core.quests = {}
    local F, calls, add = bundle()
    local u = unit({ guid = "u", screen = { x = 500, y = 400 }, name = "Unknown", ctype = 7 })
    add(u, { is_enemy = true, dist = 10 })
    F.render(true, 100)
    assert(not find_text(calls, "Unknown"), "not shown: " .. pills_text(calls))
    assert(find_text(calls, "Humanoid"), "its type instead")
    local _, source = F.name_for(u)
    assert_eq(source, "type", "not learned")
end }

T[#T + 1] = { "quest marks off: no PICK UP, no KILL, no objects", function()
    _G.core.quests = {
        get_gossip_available_quests = function() return { { quest_id = 1, title = "A" } } end,
        get_gossip_active_quests = function() return {} end,
    }
    local giver = unit({ guid = "g", screen = { x = 500, y = 400 }, flags = 2, npc = 9 })
    local F, calls, add, handlers, _, _, _, add_object = bundle({ target = giver, settings = { questie_on = false } })
    add(giver, { is_enemy = false, dist = 5 })
    add_object(gobject({ guid = "t", name = "Ley Line Trap (Quest)", screen = { x = 900, y = 400 } }), { dist = 12 })
    handlers["jcore.game_event.GOSSIP_SHOW"]({})
    F.render(true, 100)
    assert(not find_text(calls, "PICK UP") and not find_text(calls, "USE"), "nothing: " .. pills_text(calls))
end }

-- --- the icon card (1.69.0) ---------------------------------------------------------

--- How many times each image reference was drawn.
local function image_counts(calls)
    local n = {}
    for _, c in ipairs(all(calls, "image")) do n[c.ref] = (n[c.ref] or 0) + 1 end
    return n
end

T[#T + 1] = { "each fact once: on you is the ring, solo threat nothing, elite the dragon ring and its word, fighting somebody else the swords", function()
    local boards = { a = { count = 1, me = { tanking = true, rank = 1 } } }
    local F, calls, add = bundle({ art = true,
        enemies = { a = { targeting_me = true, in_combat = true }, b = { in_combat = true, target_guid = "stranger" } },
        threat = { get = function(guid) return boards[guid] end },
        creatures = { info = function(npc) if npc == 7 then return { classification = 1 } end end },
    })
    add(unit({ guid = "a", npc = 7, screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "b", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    assert(not find_text(calls, "on you"), "no on-you row beside the ring: " .. said)
    assert(not find_text(calls, "aggro"), "solo: no threat row")
    assert_eq(#exact(calls, "ELITE"), 1, "ELITE once, on the name row (1.7.5): " .. said)
    assert(not find_text(calls, "in combat"), "no in-combat words")
    local n = image_counts(calls)
    assert_eq(n["art:elite"], 1, "the elite's dragon ring")
    assert_eq(n["art:combat"], 1, "the swords on the one fighting somebody else only")
    assert_eq(#ground_rings(calls), 1, "the ring under the one on you")
end }

T[#T + 1] = { "in a group the threat row is back; no art at all: ELITE and how it fights in words", function()
    local boards = { a = { count = 3, me = { percent = 72, rank = 2 } } }
    local F, calls, add = bundle({
        enemies = { a = { in_combat = true } },
        threat = { get = function(guid) return boards[guid] end },
        fight = { role = function() return "ranged", "seen" end },
        creatures = { info = function(npc) if npc == 7 then return { classification = 1 } end end },
    })
    add(unit({ guid = "a", npc = 7, screen = { x = 500, y = 400 } }), { is_enemy = true })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    assert(find_text(calls, "threat 72% \194\183 #2 of 3"), "threat in a group: " .. said)
    assert(find_text(calls, "ELITE"), "the rank's word with no art: " .. said)
    assert(find_text(calls, "RANGED"), "how it fights in words with no art")
end }

T[#T + 1] = { "quest marks are the game's cursors: the sword and a count on a kill, the ! on a giver", function()
    _G.core.quests = {}
    local rat = unit({ guid = "r", screen = { x = 300, y = 300 }, ctype = 8, level = 1, hostile = false, npc = 4075 })
    local giver = unit({ guid = "g", screen = { x = 900, y = 300 }, flags = 3, ctype = 7 })
    local F, calls, add, handlers = bundle({ art = true, target = rat })
    add(rat, { is_enemy = true, dist = 10 })
    add(giver, { is_enemy = false, dist = 11 })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Rat", "Cast-1", 1752 })
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 316, "Rat slain: 2/8", "ERR_QUEST_ADD_KILL_SII" })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    local n = image_counts(calls)
    assert_eq(n["art:kill"], 1, "the attack cursor on the rat: " .. said)
    assert(find_text(calls, "2/8"), "its count")
    assert(not find_text(calls, "KILL"), "no KILL word beside the sword")
    assert_eq(n["art:quest_none"], 1, "a giver with nothing for you yet: the grey !")
    assert(not find_text(calls, "QUEST"), "no QUEST word")
end }

T[#T + 1] = { "a town npc: the minimap's icon for its service and its title, no level", function()
    local creatures = { info = function(npc) if npc == 55 then return { title = "Armorer" } end end }
    local F, calls, add = bundle({ art = true, creatures = creatures, settings = { friendly_npc_on = true } })
    add(unit({ guid = "v", npc = 55, name = "Brakus", flags = 4224, ctype = 7, screen = { x = 300, y = 300 } }),
        { is_enemy = false, dist = 8 })
    F.render(true, 100)
    local n = image_counts(calls)
    assert_eq(n["art:service.repair"], 1, "the anvil: it repairs (4224 = vendor + repair)")
    assert(find_text(calls, "Brakus"), "its name")
    assert(find_text(calls, "<Armorer>"), "its title: " .. table.concat(texts(calls), " | "))
    for _, t in ipairs(texts(calls)) do assert(t ~= "4", "no level on a town npc") end
    assert_eq(F.service_of(0x2000 + 0x80), "service.flight", "a flight master that sells is the flight master")
    assert_eq(F.service_of(0), nil, "no flags, no service")
end }

T[#T + 1] = { "a cast that cannot be interrupted carries the shield; one that can, does not", function()
    local now = math.floor(clock.s * 1000)
    local F, calls, add = bundle({ art = true, enemies = {
        a = { casting = { spell_id = 116, start_at = now - 500, end_at = now + 1500, interruptible = false } },
        b = { casting = { spell_id = 118, start_at = now - 500, end_at = now + 1500, interruptible = true } },
    } })
    add(unit({ guid = "a", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "b", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local n = image_counts(calls)
    assert(find_text(calls, "Frostbolt 1.5s"), "the cast")
    assert_eq(n["spell:116"], 1, "its spell icon")
    assert_eq(n["spell:118"], 1, "the other's")
    assert_eq(n["art:shield"], 1, "one shield: the cast that cannot be kicked")
end }

T[#T + 1] = { "detail per category: critters the icon alone; a category on name, health and casts has no facts row", function()
    local F, calls, add = bundle({ art = true, settings = { critter_on = true, normal_detail = 2 } })
    add(unit({ guid = "c", ctype = 8, level = 1, hostile = false, name = "Rat", screen = { x = 300, y = 300 } }),
        { is_enemy = true, dist = 10 })
    add(unit({ guid = "m", name = "Kobold", hp = 0.5, screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    local n = image_counts(calls)
    assert_eq(n["art:creature.8"], 1, "the critter's icon")
    assert(not find_text(calls, "Rat"), "and nothing else: " .. said)
    assert(find_text(calls, "Kobold"), "the normal mob's name")
    assert(not find_text(calls, "12y"), "no facts on name, health and casts")
    assert_eq(#all(calls, "bar"), 1, "its health bar (1.88.0: the soft bar)")
end }

T[#T + 1] = { "the bars in the game's own texture, with the soft look off: the fill cut, not squeezed", function()
    local F, calls, add = bundle({ art = true, settings = { esp_shader_look = false } })
    add(unit({ guid = "m", name = "Kobold", hp = 0.5, screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local bars = {}
    for _, c in ipairs(all(calls, "image")) do if c.ref == "art:statusbar" then bars[#bars + 1] = c end end
    assert_eq(#bars, 2, "backing and fill")
    assert_eq(bars[2].w, 27, "half the width")
    assert_eq(bars[2].o.uv[3], 0.125, "half the texture")
    assert_eq(#all(calls, "bar") + #all(calls, "plate"), 0, "none of the soft shapes")

    local F2, calls2, add2 = bundle({ art = true, settings = { game_bars = false, esp_shader_look = false } })
    add2(unit({ guid = "m", name = "Kobold", hp = 0.5, screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F2.render(true, 100)
    assert_eq(image_counts(calls2)["art:statusbar"], nil, "flat bars when switched off")
end }

T[#T + 1] = { "soft cards and bars (1.88.0): plates for the pills, JCore's bar for health and casts, the texture bar too", function()
    local now = math.floor(clock.s * 1000)
    local enemies = { c = { casting = { spell_id = 118, start_at = now - 500, end_at = now + 1500, interruptible = true } } }
    local function world(settings, old)
        local F, calls, add = bundle({ art = true, settings = settings, enemies = enemies, old_draw = old })
        add(unit({ guid = "m", name = "Kobold", hp = 0.5, screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
        add(unit({ guid = "c", name = "Caster", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 14 })
        F.render(true, 100)
        return calls
    end
    local calls = world({})
    local health
    for _, b in ipairs(all(calls, "bar")) do if b.h == 4 then health = b end end
    assert(health, "the health bar is JCore's bar, though the game's texture is switched on")
    assert_eq(health.w, 54, "its width")
    assert_eq(health.fraction, 0.5, "half full")
    assert_eq(health.o.bg.a, 185, "on the dark rail (the card's bar backing)")
    assert(health.o.to.r > health.c.r and health.o.to.g > health.c.g, "shading lighter to its end")
    assert_eq(health.o.to.g, math.floor(health.c.g + (255 - health.c.g) * 0.25 + 0.5), "a quarter of the way to white")
    assert_eq(image_counts(calls)["art:statusbar"], nil, "no texture bar")
    local plates, bordered = all(calls, "plate"), nil
    assert(#plates >= 2, "a plate for each pill: " .. #plates)
    for _, p in ipairs(plates) do
        assert_eq(p.c.a, 215, "the card's backdrop colour")
        assert_eq(p.o.rounding, 3, "the same rounding")
        assert_eq(p.o.shadow, false, "no shadow over the icons beside it")
        if p.o.border then bordered = p end
    end
    assert(bordered and bordered.o.border.r == 170, "the cast's pill outlined purple, as the plate's border")
    local under
    for _, b in ipairs(all(calls, "bar")) do if b.h == 3 then under = b end end
    assert(under and math.abs(under.fraction - 0.25) < 1e-6 and under.c.r == 170, "the cast's bar under its pill")
    for _, r in ipairs(all(calls, "rect")) do
        assert(not (r.o and r.o.filled), "no flat filled shapes left")
    end

    -- The switch off, or a JCore without the calls: everything as before.
    for _, case in ipairs({ { { esp_shader_look = false }, false }, { {}, true } }) do
        local flat = world(case[1], case[2])
        assert_eq(#all(flat, "plate") + #all(flat, "bar"), 0, "no soft shapes")
        assert_eq(image_counts(flat)["art:statusbar"], 2, "the game's texture bar: backing and fill")
        local pills = 0
        for _, r in ipairs(all(flat, "rect")) do if r.o and r.o.filled and r.o.rounding then pills = pills + 1 end end
        assert(pills >= 2, "the flat pills")
    end
end }

T[#T + 1] = { "a herb: its icon, name and distance on one line", function()
    local F, calls, _, _, _, _, _, add_object = bundle({ art = true })
    add_object(gobject({ guid = "h", name = "Peacebloom", screen = { x = 300, y = 300 } }), { dist = 31 })
    F.render(true, 100)
    local n = image_counts(calls)
    assert_eq(n["art:node.herb"], 1, "the herb icon: " .. table.concat(texts(calls), " | "))
    local name, dist = find_text(calls, "Peacebloom"), find_text(calls, "31y")
    assert(name and dist, "name and distance")
    assert_eq(name.at.y, dist.at.y, "one line")
end }

T[#T + 1] = { "past the master range, or with the overlay hidden, nothing drawn; threats still listed", function()
    local F, calls, add = bundle({ enemies = { b = { targeting_me = true } } })
    add(unit({ guid = "a", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 120 })
    F.render(true, 100)
    assert_eq(F.stats().drawn, 0, "beyond range")
    add(unit({ guid = "b", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    local before = #calls
    F.render(false, 100)
    assert_eq(#calls, before, "hidden: nothing drawn")
    assert_eq(F.stats().threats, 1, "the threat list is kept for the panel")
end }

-- --- what the recorded API made possible (1.48.0) ---------------------------------------

local function after_mark(calls, from)
    local out = {}
    for i = from + 1, #calls do out[#out + 1] = calls[i] end
    return out
end

T[#T + 1] = { "nodes: a herb, a vein and a chest by their names, in their category's colour, with distance and a ring", function()
    _G.core.quests = {}
    local F, calls, _, _, _, _, _, add_object = bundle()
    add_object(gobject({ guid = "h", name = "Peacebloom", screen = { x = 300, y = 400 }, used = true }), { dist = 12 })
    add_object(gobject({ guid = "o", name = "Copper Vein", screen = { x = 900, y = 400 }, used = true }), { dist = 30 })
    add_object(gobject({ guid = "c", name = "Battered Chest", screen = { x = 1500, y = 400 }, used = true }), { dist = 44 })
    F.render(true, 100)
    local herb = find_text(calls, "Peacebloom")
    assert(herb, "the herb: " .. pills_text(calls))
    local rgb = cfg.CATEGORY_BY_KEY.herb.rgb
    assert_eq(herb.c.g, rgb[2], "herb green")
    assert_eq(find_text(calls, "Copper Vein").c.r, cfg.CATEGORY_BY_KEY.ore.rgb[1], "ore colour")
    assert(find_text(calls, "Battered Chest"), "the chest")
    assert(find_text(calls, "30y"), "the vein's distance")
    local rings = ground_rings(calls)
    assert_eq(#rings, 3, "a ring under each (1.88.0: the shader ring)")
    assert_eq(rings[1][2], 0.9, "the node ring's size")
    assert_eq(rings[1][5].inner, 0.72, "a band, not a disc")
    assert_eq(rings[1][5].layer, 100, "on the world layer")
    assert_eq(F.stats().nodes, 3, "counted as nodes")
end }

T[#T + 1] = { "nodes: the page's colour picker, each switch, and node names off", function()
    _G.core.quests = {}
    local F, calls, _, _, _, _, _, add_object = bundle({ settings = { ore_on = false, node_ring = false } })
    add_object(gobject({ guid = "h", name = "Silverleaf", screen = { x = 300, y = 400 } }), { dist = 12 })
    add_object(gobject({ guid = "o", name = "Copper Vein", screen = { x = 900, y = 400 } }), { dist = 13 })
    F.render(true, 100)
    assert(find_text(calls, "Silverleaf"), "herbs still on")
    assert(not find_text(calls, "Copper Vein"), "ore off")
    assert_eq(#all(calls, "ring_3d") + #all(calls, "circle_3d"), 0, "rings off")

    local F2, calls2, _, _, _, _, _, add2 = bundle({ settings = { node_label = false } })
    add2(gobject({ guid = "h", name = "Silverleaf", screen = { x = 300, y = 400 } }), { dist = 12 })
    F2.render(true, 100)
    assert(not find_text(calls2, "Silverleaf"), "no name with node names off")
    assert(find_text(calls2, "12y"), "the distance still says where it is")
end }

T[#T + 1] = { "other objects: off by default; on, only what can be used or is named under extra names", function()
    _G.core.quests = {}
    local function world(settings)
        local F, calls, _, _, _, _, _, add_object = bundle({ settings = settings })
        add_object(gobject({ guid = "w", name = "Raw Windstone", screen = { x = 300, y = 400 }, used = true }), { dist = 12 })
        add_object(gobject({ guid = "l", name = "Ley Line", screen = { x = 900, y = 400 }, used = false }), { dist = 13 })
        add_object(gobject({ guid = "p", name = "Construct Parts", screen = { x = 1500, y = 400 }, used = false }), { dist = 14 })
        F.render(true, 100)
        return calls
    end
    local off = world({})
    assert(not find_text(off, "Raw Windstone"), "off by default: " .. pills_text(off))
    local on = world({ object_on = true })
    assert(find_text(on, "Raw Windstone"), "usable: " .. pills_text(on))
    assert(not find_text(on, "Ley Line"), "scenery that cannot be used")
    local named = world({ object_on = true, objects_include = "construct" })
    assert(find_text(named, "Construct Parts"), "named under extra object names")
end }

T[#T + 1] = { "ranges: each category's own when automatic ranges are off; the master range always", function()
    _G.core.quests = {}
    local F, calls, add, _, _, _, _, add_object = bundle({ settings = { auto_ranges = false, herb_range = 20 } })
    add_object(gobject({ guid = "h", name = "Peacebloom", screen = { x = 300, y = 400 } }), { dist = 30 })
    add(unit({ guid = "a", screen = { x = 900, y = 400 } }), { is_enemy = true, dist = 90 })
    F.render(true, 100)
    assert(not find_text(calls, "Peacebloom"), "the herb past the herb range")
    assert(find_text(calls, "Elemental"), "the mob inside the normal range")
    F.render(true, 50)
    assert_eq(F.stats().drawn, 0, "nothing past the master range")
end }

T[#T + 1] = { "LOOT: a mob that fought you dies; the loot window beside it takes the LOOT away", function()
    local enemies = { k = { targeting_me = true, in_combat = true } }
    local F, calls, add, handlers = bundle({ enemies = enemies })
    local kill = unit({ guid = "k", screen = { x = 500, y = 400 }, pos = { x = 3, y = 0, z = 0 } })
    local row = { is_enemy = true, dist = 3 }
    add(kill, row)
    F.render(true, 100)
    row.dead, enemies.k = true, nil
    local n = #calls
    F.render(true, 100)
    assert(find_text(after_mark(calls, n), "LOOT"), "its corpse: " .. pills_text(after_mark(calls, n)))
    assert_eq(F.stats().loot, 1, "counted")

    -- A bag item's loot window is not the corpse's.
    handlers["jcore.game_event.LOOT_OPENED"]({ false, true })
    n = #calls
    F.render(true, 100)
    assert(find_text(after_mark(calls, n), "LOOT"), "still lootable after a bag item")

    handlers["jcore.game_event.LOOT_OPENED"]({ true, false })
    n = #calls
    F.render(true, 100)
    assert(not find_text(after_mark(calls, n), "LOOT"), "looted: " .. pills_text(after_mark(calls, n)))
    assert_eq(F.stats().drawn, 0, "nothing left to do with it")
end }

T[#T + 1] = { "LOOT: never on a corpse that did not fight you; SKIN still says so", function()
    local F, calls, add = bundle()
    add(unit({ guid = "s", screen = { x = 300, y = 300 }, skin = true }), { dead = true, dist = 15 })
    F.render(true, 100)
    assert(find_text(calls, "SKIN"), "skin pill")
    assert(not find_text(calls, "LOOT"), "not ours: " .. pills_text(calls))
end }

T[#T + 1] = { "LOOT: casting at your target counts as fighting it", function()
    local target = unit({ guid = "t", screen = { x = 500, y = 400 } })
    local F, calls, add, handlers = bundle({ target = target })
    local row = { is_enemy = true, dist = 20 }
    add(target, row)
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "", "Cast-1", 1752 })
    row.dead = true
    F.render(true, 100)
    assert(find_text(calls, "LOOT"), "cast at, then dead: " .. pills_text(calls))
end }

T[#T + 1] = { "tapped: fighting a player outside your group with none of your threat: grey, 'tapped', no LOOT", function()
    local enemies = { x = { in_combat = true, target_guid = "Player-4619-0BADF00D" } }
    local F, calls, add = bundle({ enemies = enemies })
    local row = { is_enemy = true, dist = 20 }
    add(unit({ guid = "x", screen = { x = 500, y = 400 } }), row)
    F.render(true, 100)
    local name = find_text(calls, "Elemental")
    assert_eq(name.c.r, 150, "greyed")
    assert(not find_text(calls, "tapped"), "the grey says it, no word: " .. pills_text(calls))
    assert_eq(F.stats().tapped, 1, "counted")

    -- You join in: still theirs, so no LOOT when it dies.
    enemies.x = { in_combat = true, engaged = true, target_guid = "Player-4619-0BADF00D" }
    F.render(true, 100)
    row.dead, enemies.x = true, nil
    local n = #calls
    F.render(true, 100)
    assert(not find_text(after_mark(calls, n), "LOOT"), "their kill: " .. pills_text(after_mark(calls, n)))
end }

T[#T + 1] = { "tapped: not when the player is in your group, nor with the grey switched off", function()
    local enemies = { x = { in_combat = true, target_guid = "Player-1-FRIEND" } }
    local group = { members = function() return { { guid = "Player-1-FRIEND" } } end }
    local F, calls, add = bundle({ enemies = enemies, group = group })
    add(unit({ guid = "x", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    F.render(true, 100)
    assert(not find_text(calls, "tapped"), "your group's: " .. pills_text(calls))
    local rings = ground_rings(calls)
    assert(#rings == 1 and rings[1][4].g == 170, "on your group: the amber ring")

    local F2, calls2, add2 = bundle({ settings = { grey_tapped = false },
        enemies = { y = { in_combat = true, target_guid = "Pet-0-1234" } } })
    add2(unit({ guid = "y", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    F2.render(true, 100)
    assert_eq(find_text(calls2, "Elemental").c.r, 235, "not greyed")
    assert(find_text(calls2, "tapped"), "still says so")
end }

T[#T + 1] = { "categories: pets, party members and normal mobs follow their own switches", function()
    local group = { members = function() return { { guid = "mate" } } end }
    local function world(settings)
        local F, calls, add = bundle({ settings = settings, group = group })
        add(unit({ guid = "pet", screen = { x = 300, y = 300 }, pet = true, ctype = 1 }), { is_enemy = true, dist = 10 })
        add(unit({ guid = "mate", screen = { x = 900, y = 300 }, class = 1 }), { is_player = true, dist = 11 })
        add(unit({ guid = "mob", screen = { x = 1500, y = 300 } }), { is_enemy = true, dist = 12 })
        F.render(true, 100)
        return calls
    end
    local default = world({ friendly_player_on = true })
    assert(not find_text(default, "Beast"), "pets off by default: " .. pills_text(default))
    assert(not find_text(default, "Warrior"), "party off by default, friendly players on or not")
    assert(find_text(default, "Elemental"), "the mob")
    local on = world({ pet_on = true, party_on = true, normal_on = false })
    assert(find_text(on, "Beast") and find_text(on, "Warrior"), "both on: " .. pills_text(on))
    assert(not find_text(on, "Elemental"), "normal mobs off")
end }

T[#T + 1] = { "order and limit: your target first though farther, then nearest; the mark limit cuts the rest", function()
    local target = unit({ guid = "far", screen = { x = 900, y = 400 } })
    local F, calls, add = bundle({ target = target, settings = { esp_max_marks = 2, show_level = false,
        show_health_text = false } })
    add(unit({ guid = "near", screen = { x = 300, y = 400 } }), { is_enemy = true, dist = 5 })
    add(unit({ guid = "mid", screen = { x = 600, y = 400 } }), { is_enemy = true, dist = 15 })
    add(target, { is_enemy = true, dist = 40 })
    F.render(true, 100)
    assert_eq(F.stats().marks, 2, "two kept")
    assert_eq(F.stats().drawn, 2, "both drawn")
    assert(find_text(calls, "40y") and find_text(calls, "5y"), "target and nearest: " .. pills_text(calls))
    assert(not find_text(calls, "15y"), "the third cut")
end }

T[#T + 1] = { "the icon, the name and the facts follow their pieces", function()
    local F, calls, add = bundle({ art = true, settings = { show_icon = false, game_bars = false } })
    add(unit({ guid = "a", screen = { x = 500, y = 400 }, hp = 0.5 }), { is_enemy = true, dist = 28 })
    F.render(true, 100)
    assert(find_text(calls, "Elemental"), "named, with no icon to say it")
    assert_eq(#all(calls, "image"), 0, "no creature icon")

    local F2, calls2, add2 = bundle({ settings = { show_name = false, show_level = false, show_distance = false } })
    add2(unit({ guid = "a", screen = { x = 500, y = 400 }, hp = 0.5 }), { is_enemy = true, dist = 28 })
    F2.render(true, 100)
    assert(not find_text(calls2, "Elemental"), "no name")
    assert(not find_text(calls2, "28y"), "no details row")
end }

-- --- the client's creature cache (1.52.0) --------------------------------------

--- JCore's creatures service as a plugin sees it: info by npc id.
local function cache_of(rows)
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    return {
        info = function(id) return rows[id] end,
        name = function(id) return rows[id] and rows[id].name end,
        stats = function() return { count = n } end,
    }
end

T[#T + 1] = { "the creature cache names a mob never cast at, and its rank makes it an elite (1.52.0)", function()
    clock.s = clock.s + 5
    local creatures = cache_of({
        [251143] = { name = "Roiling Winds", type = 4, classification = 1 },
        [705] = { name = "Ragged Young Wolf", type = 1, classification = 0 },
        [1105] = { name = "Old Murk-Eye", type = 7, classification = 3 },
        [1106] = { name = "Mother Fang", type = 1, classification = 4 },
    })
    local F, calls, add, _, traces = bundle({ creatures = creatures })
    add(unit({ guid = "e", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "w", screen = { x = 700, y = 300 }, npc = 705, ctype = 1 }), { is_enemy = true, dist = 11 })
    add(unit({ guid = "b", screen = { x = 1100, y = 300 }, npc = 1105, ctype = 7 }), { is_enemy = true, dist = 12 })
    add(unit({ guid = "r", screen = { x = 1500, y = 300 }, npc = 1106, ctype = 1 }), { is_enemy = true, dist = 13 })
    F.render(true, 100)
    assert(find_text(calls, "Roiling Winds"), "named from the cache: " .. pills_text(calls))
    assert(find_text(calls, "ELITE"), "an ELITE pill")
    assert(find_text(calls, "BOSS") and find_text(calls, "RARE"), "a boss and a rare")
    assert(find_text(calls, "Ragged Young Wolf"), "a normal mob named too")
    local seen = false
    for i = 1, #traces do
        if traces[i]:find("(cache) elite", 1, true) and traces[i]:find("rank=1", 1, true) then seen = true end
    end
    assert(seen, "the trace says where the name and the rank came from")
    local framed = false
    for i = 1, #traces do if traces[i]:find("creatures=4", 1, true) then framed = true end end
    assert(framed, "the frame line counts the cache")

    -- The Elites row's switch now decides it, as on the Classic ESP.
    local F2, calls2, add2 = bundle({ creatures = creatures, settings = { elite_on = false } })
    add2(unit({ guid = "e", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    F2.render(true, 100)
    assert(not find_text(calls2, "Roiling Winds"), "elites off: " .. pills_text(calls2))
end }

T[#T + 1] = { "a learned name still wins over the cache's; a friendly npc shows its title", function()
    local creatures = cache_of({
        [777] = { name = "Cached Wolf", type = 1, classification = 0 },
        [5595] = { name = "Ironforge Guard", title = "Guard Captain", type = 7, classification = 0 },
    })
    local wolf = unit({ guid = "w", screen = { x = 300, y = 300 }, npc = 777 })
    local F, calls, add, handlers = bundle({ creatures = creatures, target = wolf,
        settings = { friendly_npc_on = true } })
    add(wolf, { is_enemy = true, dist = 10 })
    add(unit({ guid = "g", screen = { x = 900, y = 300 }, npc = 5595, ctype = 7, hostile = false }),
        { is_ally = true, dist = 12 })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Mangy Wolf", "Cast-1", 1752 })
    F.render(true, 100)
    assert(find_text(calls, "Mangy Wolf"), "the cast's name: " .. pills_text(calls))
    assert(not find_text(calls, "Cached Wolf"), "not the cache's")
    assert(find_text(calls, "Ironforge Guard"), "the guard by the cache")
    assert(find_text(calls, "<Guard Captain>"), "with its title")
end }

T[#T + 1] = { "an elite coming at you is a threat and an alert, whatever its level", function()
    local creatures = cache_of({ [251143] = { name = "Roiling Winds", type = 4, classification = 1 } })
    local F, _, add, _, _, emitted = bundle({ creatures = creatures, my_level = 10,
        enemies = { e = { activity = "approaching" } } })
    add(unit({ guid = "e", screen = { x = 300, y = 100 }, level = 9 }), { is_enemy = true, dist = 25 })
    sounds = {}
    F.render(true, 100)
    assert_eq(F.stats().threats, 1, "listed")
    F.alert_check()
    assert_eq(#sounds, 1, "one sound")
    assert_eq(emitted[#emitted][2].reason, "Elite", "announced as an elite")
end }

-- 1.74.0: the live log (a five-man) warned, with a sound, of every Dark Iron
-- Looter in the place every fifteen seconds.
T[#T + 1] = { "in a dungeon an elite alone is no alert; a boss and a mob above your level still are (1.74.0)", function()
    local creatures = cache_of({
        [3001] = { name = "Dark Iron Looter", type = 7, classification = 1 },
        [3002] = { name = "Durgen Dirgehammer", type = 7, classification = 3 },
        [3003] = { name = "Dark Iron Summoner", type = 7, classification = 1 },
    })
    local targeting = { DUNGEON = "dungeon", RAID = "raid", here = "dungeon" }
    targeting.context = function() return targeting.here end
    local F, _, add, _, _, emitted = bundle({ creatures = creatures, my_level = 15, targeting = targeting,
        enemies = { l = { activity = "approaching" }, d = { activity = "approaching" }, s = { activity = "approaching" } } })
    add(unit({ guid = "l", npc = 3001, screen = { x = 300, y = 100 }, level = 15 }), { is_enemy = true, dist = 25 })
    add(unit({ guid = "d", npc = 3002, screen = { x = 350, y = 100 }, level = 16 }), { is_enemy = true, dist = 25 })
    add(unit({ guid = "s", npc = 3003, screen = { x = 400, y = 100 }, level = 17 }), { is_enemy = true, dist = 25 })
    sounds = {}
    F.render(true, 100)
    F.alert_check()
    local reasons = {}
    for i = 1, #emitted do
        local e = emitted[i][2]
        if type(e) == "table" and e.reason then reasons[e.name] = e.reason end
    end
    assert_eq(reasons["Dark Iron Looter"], nil, "an elite of your level in a dungeon: quiet")
    assert_eq(reasons["Durgen Dirgehammer"], "Boss", "a boss still is")
    assert_eq(reasons["Dark Iron Summoner"], "Dangerous mob", "two levels up still is")
    assert_eq(#sounds, 2, "two sounds, not three")

    -- Out in the world the same elite is announced.
    targeting.here = "party"
    clock.s = clock.s + 100
    F.render(true, 100)
    F.alert_check()
    local last = {}
    for i = 1, #emitted do
        local e = emitted[i][2]
        if type(e) == "table" and e.name == "Dark Iron Looter" then last = e end
    end
    assert_eq(last.reason, "Elite", "outside an instance: an elite is an alert")
end }

T[#T + 1] = { "tapped: the client's is_tap_denied, true since patch 1.60.1.70205, counts; its corpse is not ours", function()
    clock.s = clock.s + 5
    -- Out of combat by the enemies row's reckoning, but the client says it is somebody else's.
    local enemies = { x = { in_combat = false } }
    local F, calls, add, _, traces = bundle({ enemies = enemies })
    local mob = unit({ guid = "x", screen = { x = 500, y = 400 }, tap = true })
    local row = { is_enemy = true, dist = 20 }
    add(mob, row)
    F.render(true, 100)
    assert_eq(find_text(calls, "Elemental").c.r, 150, "greyed: tapped by the read")
    assert_eq(F.stats().tap_read, 1, "counted as the client's word")
    local seen = false
    for i = 1, #traces do if traces[i]:find("tap_read=true", 1, true) then seen = true end end
    assert(seen, "traced")

    -- A corpse that fought you but that the client calls somebody else's: no LOOT.
    local enemies2 = { k = { targeting_me = true, in_combat = true } }
    local F2, calls2, add2 = bundle({ enemies = enemies2 })
    local kill = unit({ guid = "k", screen = { x = 500, y = 400 } })
    local krow = { is_enemy = true, dist = 3 }
    add2(kill, krow)
    F2.render(true, 100)
    krow.dead, enemies2.k, kill.tap = true, nil, true
    local n = #calls2
    F2.render(true, 100)
    assert(not find_text(after_mark(calls2, n), "LOOT"), "not ours: " .. pills_text(after_mark(calls2, n)))

    -- A false read proves nothing: the strangers' fight still marks it.
    local F3, calls3, add3 = bundle({ enemies = { y = { in_combat = true, target_guid = "Player-1-STRANGER" } } })
    add3(unit({ guid = "y", screen = { x = 500, y = 400 }, tap = false }), { is_enemy = true, dist = 20 })
    F3.render(true, 100)
    assert_eq(find_text(calls3, "Elemental").c.r, 150, "inferred as before: greyed")
end }

-- --- the game's own quest log (1.53.0) ---------------------------------------------

--- JCore's gamelua as esp/forever_quests uses it, answering at once with
--- what the game would: the quest log (two quests, one complete, and where
--- each one's area is) and the units (a wolf whose tooltip names the first).
local function quest_bridge(units_text)
    local LOG = table.concat({
        "N\t2\tC_QuestLog",
        "Q\t92469\t0\tWolves at the Door",
        "O\t92469\t1\tmonster\t0\t2\t8\t2/8 Ragged Young Wolf slain",
        "Q\t92470\t1\tTurn It In",
        "M\t2521\t0.25\t0.25",
        "P\t92469\t0.5\t0.5\t2521\tonmap",
        "P\t92470\t0.1\t-0.2\t2521\tonmap",
    }, "\n")
    return {
        ready = function() return true end,
        state = function() return "ready" end,
        run = function(slot, _, cb)
            if slot == "aio_ql" then cb(LOG) else cb(units_text or "") end
            return true
        end,
    }
end

--- Map to world for that log: you stand at (0.25, 0.25), which is (0, 0).
local function quest_world()
    core.game_ui = { get_world_pos_from_map_pos = function(_, p)
        return { x = (p.x - 0.25) * 400, y = (p.y - 0.25) * 400 }
    end }
end

T[#T + 1] = { "the game's quest log: a mob it ties to a quest is a quest mark with its name, objective and quest", function()
    quest_world()
    local wolf = "Creature-0-1-2521-1-705-0000410C5D"
    local F, calls, add = bundle({
        gamelua = quest_bridge("U\t" .. wolf .. "\t1\tRagged Young Wolf\tplate\t17:Wolves at the Door\0318: - 2/8 Ragged Young Wolf slain"),
        w2s = function(pos) return { x = 900 + pos.y, y = 500 } end,
    })
    add(unit({ guid = wolf, npc = 705, ctype = 1, screen = { x = 500, y = 400 }, pos = { x = 100, y = 100, z = 0 } }),
        { is_enemy = true, dist = 40 })
    F.render(true, 100)
    assert(find_text(calls, "Ragged Young Wolf"), "the game's own name: " .. table.concat(texts(calls), " | "))
    assert(find_text(calls, "KILL") and find_text(calls, "2/8"), "the objective and its count")
    assert(find_text(calls, "Wolves at the Door"), "and its quest")
    assert(not find_text(calls, "Wolves at the Door \194\183"), "its area is not drawn: the mob on screen is the better mark")
    local q = F.stats().quests
    assert_eq(q.live, true, "the live log is read")
    assert_eq(q.live_related, 1, "one unit on a quest")
end }

T[#T + 1] = { "the game's quest log: each quest's area gets a ring, a line towards it and its title with the distance", function()
    quest_world()
    local F, calls = bundle({
        gamelua = quest_bridge(""),
        w2s = function(pos) return { x = 900 + pos.y, y = 500 } end,
    })
    F.render(true, 100)
    local label = find_text(calls, "Wolves at the Door \194\183 141y")
    assert(label, "the area's title and distance: " .. table.concat(texts(calls), " | "))
    local area = ground_rings(calls)
    assert_eq(#area >= 1, true, "a ring on the area (1.88.0: the shader ring)")
    assert_eq(area[1][2], 6.0, "the area's size")
    assert_eq(area[1][5].inner, 0.92, "a thin band round it")
    assert_eq(#all(calls, "line_3d") >= 1, true, "a line towards it")
    assert(not find_text(calls, "TURN IN: Turn It In"), "the complete quest's area is behind you: no label")
    assert_eq(F.stats().places, 2, "both areas are within range and the path limit")

    local F2, calls2 = bundle({
        gamelua = quest_bridge(""),
        w2s = function(pos) return { x = 900 + pos.y, y = 500 } end,
        settings = { quest_spawn_paths = false, quest_max_lines = 1 },
    })
    F2.render(true, 100)
    assert_eq(#all(calls2, "line_3d"), 0, "no line with the switch off")
    assert(find_text(calls2, "Wolves at the Door \194\183 141y"), "the area itself still shows")
    assert_eq(F2.stats().places, 1, "one, by the path limit")
    core.game_ui = nil
end }

-- --- quests apart from the ESP (1.73.0) ------------------------------------------------

--- A quest mob on you, a mob no quest wants on you too, a quest object and a
--- vein: the world the three tests below look at.
local function apart_world(settings)
    _G.core.quests = {}
    local wind = unit({ guid = "w", screen = { x = 500, y = 400 }, npc = 251143 })
    local other = unit({ guid = "o", screen = { x = 900, y = 400 }, npc = 250873 })
    local F, calls, add, handlers, _, _, _, add_object = bundle({ target = wind, settings = settings,
        quests = fake_index(BUNDLE_INDEX), questdb = fake_questdb(BUNDLE_DB),
        enemies = { w = { targeting_me = true, in_combat = true }, o = { targeting_me = true, in_combat = true } } })
    add(wind, { is_enemy = true, dist = 10 })
    add(other, { is_enemy = true, dist = 11 })
    add_object(gobject({ guid = "b", name = "Bundle of Wood", screen = { x = 500, y = 700 } }), { dist = 12 })
    add_object(gobject({ guid = "c", name = "Copper Vein", screen = { x = 900, y = 700 } }), { dist = 13 })
    handlers["jcore.game_event.UNIT_SPELLCAST_SENT"]({ "player", "Roiling Winds", "Cast-1", 1752 })
    handlers["jcore.game_event.UI_INFO_MESSAGE"]({ 316, "Roiling Winds destroyed: 4/6", "ERR_QUEST_ADD_FOUND_SII" })
    return F, calls
end

T[#T + 1] = { "quests apart (1.73.0): ESP off, quest marks on -- the quest marks only, without the ring or the line", function()
    local F, calls = apart_world()
    F.render(true, 100)
    assert(find_text(calls, "Elemental") and find_text(calls, "Copper Vein"), "ESP on: everything: " .. pills_text(calls))
    assert(#ground_rings(calls) >= 2 and #all(calls, "line_3d") >= 2, "ESP on: rings and lines under both")

    local n = #calls
    F.render(false, 100, true)
    local after = since(calls, n)
    assert(find_text(after, "KILL") and find_text(after, "4/6"), "the quest mob: " .. pills_text(after))
    assert(find_text(after, "COLLECT"), "the quest object: " .. pills_text(after))
    assert(not find_text(after, "Elemental"), "no mob a quest does not want: " .. pills_text(after))
    assert(not find_text(after, "Copper Vein"), "no vein: " .. pills_text(after))
    assert_eq(#all(after, "line_3d"), 0, "no line from the quest mob on you")
    for _, c in ipairs(all(after, "ring_3d")) do
        assert(c[2] ~= 1.2, "no aggro ring (the mob's 1.2 yd radius) under the quest mob")
    end
    assert_eq(#F.threats(), 2, "the threat list is kept for the alerts all the same")
end }

T[#T + 1] = { "quests apart (1.73.0): ESP off and quest marks off, nothing drawn", function()
    local F, calls = apart_world()
    F.render(false, 100, false)
    assert_eq(#all(calls, "text"), 0, "no words: " .. pills_text(calls))
    assert_eq(#all(calls, "circle_3d") + #all(calls, "ring_3d") + #all(calls, "line_3d") + #all(calls, "image")
        + #all(calls, "beacon_3d") + #all(calls, "plate"), 0, "nothing at all")
    assert_eq(#F.threats(), 2, "the threat list is kept")
end }

T[#T + 1] = { "quests apart (1.73.0): the Quests page's switch alone -- the old quest row off hides nothing, questie_on off hides them", function()
    local F, calls = apart_world({ quest_on = false })
    F.render(true, 100)
    assert(find_text(calls, "KILL") and find_text(calls, "COLLECT"), "quest_on is no longer read: " .. pills_text(calls))

    local F2, calls2 = apart_world({ questie_on = false })
    F2.render(false, 100, true)
    assert(not find_text(calls2, "KILL") and not find_text(calls2, "COLLECT"), "quest ESP off: " .. pills_text(calls2))
    assert_eq(#all(calls2, "text"), 0, "and nothing else with the ESP off")
end }


-- --- the cast ring (1.85.0) ----------------------------------------------------

T[#T + 1] = { "a caster gets a ring on the ground filling as its cast runs: purple to red to kick, amber when you cannot", function()
    local now = math.floor(clock.s * 1000)
    local F, calls, add = bundle({ enemies = {
        a = { casting = { spell_id = 116, start_at = now - 500, end_at = now + 1500, interruptible = false } },
        b = { casting = { spell_id = 118, start_at = now - 1500, end_at = now + 500, interruptible = true } },
    } })
    add(unit({ guid = "a", screen = { x = 300, y = 300 }, pos = { x = 10, y = 0, z = 0 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "b", screen = { x = 900, y = 300 }, pos = { x = 12, y = 0, z = 0 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 2, "a ring under each caster")
    local by = {}
    for i = 1, #rings do by[rings[i][1].x] = rings[i] end
    local a, b = by[10], by[12]
    assert(a and b, "one at each caster")
    assert(math.abs(a[3] - 0.25) < 1e-6, "a quarter of the way through, got " .. tostring(a[3]))
    assert(math.abs(b[3] - 0.75) < 1e-6, "three quarters")
    assert_eq(a[4].r, 240, "amber: Frostbolt cannot be kicked"); assert_eq(a[4].g, 180, "amber")
    assert_eq(b[4].r, 170, "purple: Polymorph can"); assert_eq(b[4].b, 250, "purple")
    assert_eq(b[5].to.g, 80, "turning red as it closes")
    assert_eq(b[5].layer, 100, "on the world layer")
    assert(b[2] > 1.5, "just outside the aggro ring")
end }

T[#T + 1] = { "the cast ring: a channel empties, nothing without a cast, and its switch turns it off", function()
    local now = math.floor(clock.s * 1000)
    local enemies = {
        ch = { casting = { spell_id = 116, channel = true, start_at = now - 1000, end_at = now + 3000, interruptible = true } },
        idle = { targeting_me = false },
    }
    local F, calls, add = bundle({ enemies = enemies })
    add(unit({ guid = "ch", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "idle", screen = { x = 900, y = 300 } }), { is_enemy = true, dist = 12 })
    F.render(true, 100)
    local rings = all(calls, "ring_3d")
    assert_eq(#rings, 1, "only the caster")
    assert(math.abs(rings[1][3] - 0.75) < 1e-6, "a channel a quarter through has three quarters left")
    local F2, calls2, add2 = bundle({ enemies = enemies, settings = { show_cast_ring = false } })
    add2(unit({ guid = "ch", screen = { x = 300, y = 300 } }), { is_enemy = true, dist = 10 })
    F2.render(true, 100)
    assert_eq(#all(calls2, "ring_3d"), 0, "switched off")
    assert(find_text(calls2, "Frostbolt"), "the cast bar stays")
end }

-- --- the new look (1.88.0) ----------------------------------------------------------
--
-- The user, 2026-10-08: "Take all ESPs and convert it to this!" -- ground
-- rings, boxes to curtains, far things as beacons, cards and bars, and only
-- the gatherables your skill can gather.

T[#T + 1] = { "1.88.0 boxes: a curtain when picked (corners by default since 1.7.6), round the unit just outside its reach, nearly clear at the top", function()
    assert_eq(cfg.BOX_DEFAULT, cfg.BOX_CORNERS, "1.7.6: the corners are the default again")
    local F, calls, add = bundle({ settings = { show_box = true, box_style = cfg.BOX_CURTAIN } })
    local big = unit({ guid = "a", screen = { x = 500, y = 400 }, pos = { x = 20, y = 0, z = 0 } })
    local small = unit({ guid = "s", screen = { x = 900, y = 400 }, pos = { x = 25, y = 0, z = 0 } })
    small.get_bounding_radius = function() return 0.3 end
    add(big, { is_enemy = true, dist = 20 })
    add(small, { is_enemy = true, dist = 25 })
    add(unit({ guid = "far", screen = { x = 1300, y = 400 } }), { is_enemy = true, dist = 50 })
    F.render(true, 100)
    local curtains = all(calls, "curtain_3d")
    assert_eq(#curtains, 2, "one round each within the full-detail range (45 yd), none past it")
    local by = {}
    for _, c in ipairs(curtains) do by[c[1].x] = c end
    local a, s = by[20], by[25]
    assert(a and s, "at each unit")
    assert(math.abs(a[2] - 1.4) < 1e-9, "its reach (1.2) and a little: " .. tostring(a[2]))
    assert_eq(s[2], 0.8, "never under 0.8 yd")
    assert_eq(a[3].r, 235, "in the mark's colour")
    local o = a[4]
    assert_eq(o.to.a, 38, "nearly clear at the top")
    assert_eq(o.to.r, 235, "the same colour")
    assert_eq(o.height, 2.0, "about a model's height")
    assert_eq(o.points, 16, "points"); assert_eq(o.rings, 2, "rings"); assert_eq(o.verticals, 4, "verticals")
    assert_eq(o.fill, 0.18, "a faint sheet")
    assert_eq(o.lod, true, "fewer points far off")
    assert_eq(o.layer, 100, "on the world layer")
    assert_eq(o.droppable, true, "dropped before a frame is")
    assert_eq(#all(calls, "box"), 0, "no corners")

    -- The default (1.7.6): the corners; a JCore without curtain_3d draws the corners.
    local F2, calls2, add2 = bundle({ settings = { show_box = true } })
    add2(unit({ guid = "a", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    F2.render(true, 100)
    assert_eq(#all(calls2, "box"), 1, "the corners by default")
    assert_eq(#all(calls2, "curtain_3d"), 0, "and no curtain")
    local F3, calls3, add3 = bundle({ settings = { show_box = true, box_style = cfg.BOX_CURTAIN }, old_draw = true })
    add3(unit({ guid = "a", screen = { x = 500, y = 400 } }), { is_enemy = true, dist = 20 })
    F3.render(true, 100)
    assert_eq(#all(calls3, "box"), 1, "an older JCore: the corners")
end }

T[#T + 1] = { "1.88.0 beacons: a far rare, boss or quest mark gets a pillar of light; a near one, a node, a normal mob not; off by default (1.7.6)", function()
    _G.core.quests = {}
    local creatures = { info = function(npc)
        if npc == 4 then return { classification = 4 } end
        if npc == 3 then return { classification = 3 } end
    end }
    -- Switched on (1.7.6: a beacon is a curtain, off by default) unless said.
    local function world(settings, visuals, quest_visuals)
        if settings.esp_beacons == nil then settings.esp_beacons = true end
        local F, calls, add, _, _, _, _, add_object = bundle({ settings = settings, creatures = creatures,
            quests = fake_index(BUNDLE_INDEX), questdb = fake_questdb(BUNDLE_DB) })
        add(unit({ guid = "rare", npc = 4, screen = { x = 100, y = 300 }, pos = { x = 60, y = 0, z = 0 } }),
            { is_enemy = true, dist = 60 })
        add(unit({ guid = "rare2", npc = 4, screen = { x = 300, y = 300 }, pos = { x = 20, y = 0, z = 0 } }),
            { is_enemy = true, dist = 20 })
        add(unit({ guid = "boss", npc = 3, screen = { x = 500, y = 300 }, pos = { x = 90, y = 0, z = 0 } }),
            { is_enemy = true, dist = 90 })
        add(unit({ guid = "norm", screen = { x = 700, y = 300 }, pos = { x = 70, y = 0, z = 0 } }),
            { is_enemy = true, dist = 70 })
        add_object(gobject({ guid = "b", name = "Bundle of Wood", screen = { x = 900, y = 300 },
            pos = { x = 0, y = 70, z = 0 } }), { dist = 70 })
        add_object(gobject({ guid = "h", name = "Peacebloom", screen = { x = 1100, y = 300 },
            pos = { x = 0, y = 80, z = 0 } }), { dist = 80 })
        if visuals == nil then visuals = true end
        F.render(visuals, 100, quest_visuals)
        return F, calls
    end
    local F, calls = world({})
    local beacons = all(calls, "beacon_3d")
    assert_eq(#beacons, 3, "the far rare, the boss and the quest object")
    assert_eq(F.stats().beacons, 3, "counted")
    local at = {}
    for _, b in ipairs(beacons) do at[b[1].x .. "," .. b[1].y] = b end
    local rare, boss, bundle_of = at["60,0"], at["90,0"], at["0,70"]
    assert(rare and boss and bundle_of, "over each of them")
    assert_eq(rare[2].r, 235, "the rare in its mark's colour")
    assert_eq(bundle_of[2].g, 210, "the quest object in the quest colour")
    assert_eq(rare[3].height, 10, "about ten yards tall")
    assert_eq(rare[3].layer, 100, "on the world layer")
    assert_eq(at["20,0"], nil, "not the rare that is near")
    assert_eq(at["70,0"], nil, "not a normal mob")
    assert_eq(at["0,80"], nil, "never a node: the Quests page's beacons have those")

    local _, from = world({ esp_beacon_from = 80 })
    assert_eq(#all(from, "beacon_3d"), 1, "past 80 yards: the boss alone")
    local _, off = world({ esp_beacons = false })
    assert_eq(#all(off, "beacon_3d"), 0, "switched off")
    -- 1.7.6: off by default -- a beacon is a curtain, and enemies carry none.
    local F0, calls0, add0 = bundle({ creatures = creatures })
    add0(unit({ guid = "boss", npc = 3, screen = { x = 500, y = 300 }, pos = { x = 90, y = 0, z = 0 } }),
        { is_enemy = true, dist = 90 })
    F0.render(true, 100)
    assert_eq(#all(calls0, "beacon_3d"), 0, "off by default: no pillar on the far boss")
    local _, quests_only = world({}, false, true)
    assert(find_text(quests_only, "COLLECT"), "ESP off: the quest object is still marked")
    assert_eq(#all(quests_only, "beacon_3d"), 0, "but the beacons are the ESP page's")
end }

T[#T + 1] = { "1.88.0 beacons: a far corpse to loot in the loot colour; one only to skin, or near, none; six at most", function()
    local enemies = { k = { targeting_me = true, in_combat = true }, n = { targeting_me = true, in_combat = true } }
    local F, calls, add = bundle({ enemies = enemies, settings = { esp_beacons = true } })
    local far_row, near_row = { is_enemy = true, dist = 50 }, { is_enemy = true, dist = 4 }
    add(unit({ guid = "k", screen = { x = 500, y = 400 }, pos = { x = 50, y = 0, z = 0 } }), far_row)
    add(unit({ guid = "n", screen = { x = 900, y = 400 }, pos = { x = 4, y = 0, z = 0 } }), near_row)
    add(unit({ guid = "s", screen = { x = 1300, y = 400 }, skin = true, pos = { x = 0, y = 55, z = 0 } }),
        { dead = true, dist = 55 })
    F.render(true, 100)
    far_row.dead, near_row.dead, enemies.k, enemies.n = true, true, nil, nil
    local n = #calls
    F.render(true, 100)
    local after = since(calls, n)
    assert_eq(F.stats().loot, 2, "both corpses ours to loot")
    local beacons = all(after, "beacon_3d")
    assert_eq(#beacons, 1, "the far one only, not the skin-only corpse: " .. pills_text(after))
    assert_eq(beacons[1][1].x, 50, "over the far corpse")
    assert_eq(beacons[1][2].g, 210, "in the loot colour"); assert_eq(beacons[1][2].r, 110, "the loot green")

    local creatures = { info = function() return { classification = 4 } end }
    local F2, calls2, add2 = bundle({ creatures = creatures, settings = { esp_beacons = true } })
    for i = 1, 8 do
        add2(unit({ guid = "r" .. i, screen = { x = 100 * i, y = 300 }, pos = { x = 50 + i, y = 0, z = 0 } }),
            { is_enemy = true, dist = 50 + i })
    end
    F2.render(true, 100)
    assert_eq(#all(calls2, "beacon_3d"), 6, "six a frame at most")
    assert_eq(all(calls2, "beacon_3d")[1][1].x, 51, "the nearest first")
end }

T[#T + 1] = { "1.88.0 gathering by skill: no profession hides a herb; too low says (Requires Skill N), dimmed; enough is plain", function()
    _G.core.quests = {}
    local skills, asked = {}, 0
    local player = { skill = function(prof)
        asked = asked + 1
        if skills == "raise" then error("no skill lines") end
        return skills[prof]
    end }
    local function world(settings, who)
        asked = 0
        local F, calls, _, _, traces, _, _, add_object = bundle({ art = true, settings = settings, player = who or player })
        add_object(gobject({ guid = "h", name = "Purple Lotus", screen = { x = 300, y = 400 }, pos = { x = 20, y = 0, z = 0 } }),
            { dist = 20 })
        add_object(gobject({ guid = "o", name = "Mithril Deposit", screen = { x = 900, y = 400 }, pos = { x = 25, y = 0, z = 0 } }),
            { dist = 25 })
        add_object(gobject({ guid = "c", name = "Battered Chest", screen = { x = 1500, y = 400 }, pos = { x = 30, y = 0, z = 0 } }),
            { dist = 30 })
        F.render(true, 100)
        return F, calls, traces
    end
    local herb_rgb = cfg.CATEGORY_BY_KEY.herb.rgb

    -- No Herbalism, no Mining: neither is marked; the chest asks for nothing.
    local F, calls, traces = world({})
    assert(not find_text(calls, "Purple Lotus"), "no herb without Herbalism: " .. pills_text(calls))
    assert(not find_text(calls, "Mithril"), "no vein without Mining")
    assert(find_text(calls, "Battered Chest"), "the chest")
    assert_eq(#ground_rings(calls), 1, "a ring under the chest alone")
    assert_eq(F.stats().gather_hidden, 2, "two hidden")
    local marks = F.node_marks()
    assert_eq(#marks, 1, "a hidden node is not a mark")
    assert_eq(marks[1].name, "Battered Chest", "the chest, by name")
    assert_eq(marks[1].requires, nil, "asking for nothing")
    assert_eq(asked, 2, "each profession read once a frame")
    local said = table.concat(traces, " || ")
    assert(said:find("fesp gathering: herbalism none", 1, true), "traced: " .. said)

    -- Too low: marked, dimmed, with what it asks for.
    skills = { herbalism = 100, mining = 150 }
    F, calls = world({})
    local lotus = find_text(calls, "Purple Lotus (Requires Skill 210)")
    assert(lotus, "the lotus says what it needs: " .. pills_text(calls))
    assert(find_text(calls, "Mithril Deposit (Requires Skill 175)"), "the vein too")
    assert(lotus.c.g ~= herb_rgb[2] or lotus.c.r ~= herb_rgb[1], "not the herb green")
    assert_eq(lotus.c.r, math.floor(herb_rgb[1] + (170 - herb_rgb[1]) * 0.55 + 0.5), "greyed toward the dim colour")
    local tinted = false
    for _, c in ipairs(all(calls, "image")) do
        if c.ref == "art:node.herb" and c.tint and c.tint.a == 140 then tinted = true end
    end
    assert(tinted, "its icon faded")
    local rings = ground_rings(calls)
    assert_eq(#rings, 3, "a ring under each")
    local lotus_ring
    for _, r in ipairs(rings) do if r[1].x == 20 then lotus_ring = r end end
    assert_eq(lotus_ring[4].r, lotus.c.r, "the ring in the dimmed colour too")
    marks = F.node_marks()
    local by = {}
    for _, m in ipairs(marks) do by[m.name] = m end
    assert_eq(by["Purple Lotus"].requires, 210, "node_marks: the skill it asks for")
    assert_eq(by["Mithril Deposit"].requires, 175, "the vein's")
    assert_eq(by["Battered Chest"].requires, nil, "the chest's: nothing")

    -- With node names off, it still says what it needs.
    local _, unnamed = world({ node_label = false })
    assert(find_text(unnamed, "(Requires Skill 210)"), "the need alone: " .. pills_text(unnamed))
    assert(not find_text(unnamed, "Purple Lotus"), "no name")

    -- Enough: plain, as before.
    skills = { herbalism = 300, mining = 300 }
    F, calls = world({})
    lotus = find_text(calls, "Purple Lotus")
    assert(lotus and lotus.text == "Purple Lotus", "plain: " .. pills_text(calls))
    assert_eq(lotus.c.g, herb_rgb[2], "herb green")
    assert(not find_text(calls, "Requires"), "no note")
    assert_eq(F.node_marks()[1].requires, nil, "requires nothing")

    -- The switch off: every herb and vein, no note, whatever the skill.
    skills = {}
    F, calls = world({ gather_skill_only = false })
    assert(find_text(calls, "Purple Lotus") and find_text(calls, "Mithril Deposit"), "all shown: " .. pills_text(calls))
    assert(not find_text(calls, "Requires"), "no note")
    assert_eq(asked, 0, "the skill not even read")

    -- A read that raises, or a JCore without player.skill, hides nothing.
    skills = "raise"
    F, calls = world({})
    assert(find_text(calls, "Purple Lotus") and not find_text(calls, "Requires"), "a raising read: " .. pills_text(calls))
    F, calls = world({}, {})
    assert(find_text(calls, "Purple Lotus") and find_text(calls, "Mithril Deposit"), "no player.skill: " .. pills_text(calls))
end }

-- --- rares from the list (1.7.5) ------------------------------------------------------

T[#T + 1] = { "1.7.5 rares from the list: a rare the cache never saw is RARE by its npc id; a rank the game gives wins", function()
    clock.s = clock.s + 5
    local creatures = cache_of({ [639] = { name = "Edwin VanCleef", type = 7, classification = 1 } })
    local F, calls, add, _, traces = bundle({ art = true, creatures = creatures })
    -- Forever's own (Matriarch Bristlefur), and a Forever rare elite (Slydris).
    add(unit({ guid = "bristle", npc = 276189, ctype = 1, screen = { x = 200, y = 300 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "slydris", npc = 255887, ctype = 1, screen = { x = 600, y = 300 } }), { is_enemy = true, dist = 11 })
    -- The list says rare elite, the cache elite (Forever's dungeon bosses).
    add(unit({ guid = "vancleef", npc = 639, ctype = 7, screen = { x = 1000, y = 300 } }), { is_enemy = true, dist = 12 })
    -- On no list, but the game answers rare.
    local odd = unit({ guid = "odd", npc = 299999, ctype = 1, screen = { x = 1400, y = 300 } })
    odd.get_classification = function() return 4 end
    add(odd, { is_enemy = true, dist = 13 })
    -- On no list, nothing said: a normal mob.
    add(unit({ guid = "wolf", npc = 705, ctype = 1, screen = { x = 1800, y = 300 } }), { is_enemy = true, dist = 14 })
    F.render(true, 100)
    local said = pills_text(calls)
    assert_eq(#exact(calls, "RARE"), 2, "Matriarch Bristlefur and the game's rare: " .. said)
    assert_eq(#exact(calls, "RARE ELITE"), 1, "Slydris")
    local tag = exact(calls, "RARE")[1]
    assert_eq(tag.c.r, 255, "in the Rares colour"); assert_eq(tag.c.g, 205, "the Rares gold")
    local n = image_counts(calls)
    assert_eq(n["art:rare"], 2, "the silver dragon stays beside the word")
    assert_eq(n["art:rare_elite"], 1, "and the rare elite's")
    assert_eq(n["art:elite"], 1, "VanCleef is the elite the cache says, not a rare elite")
    local from = {}
    for i = 1, #traces do
        local guid, src = traces[i]:match("^fesp (%S+).- rank=%d+/(%S+)")
        if guid then from[guid] = src end
    end
    assert_eq(from["bristle"], "list", "the trace says the list: " .. table.concat(traces, "\n"))
    assert_eq(from["vancleef"], "cache", "the cache")
    assert_eq(from["odd"], "game", "the game")
    assert_eq(from["wolf"], "-", "nothing")

    -- Rares are their own category: the Rares row's switch hides them.
    local F2, calls2, add2 = bundle({ art = true, settings = { rare_on = false } })
    add2(unit({ guid = "bristle", npc = 276189, ctype = 1, screen = { x = 200, y = 300 } }), { is_enemy = true, dist = 10 })
    F2.render(true, 100)
    assert_eq(#exact(calls2, "RARE"), 0, "rares off: " .. pills_text(calls2))
end }

T[#T + 1] = { "1.7.5 the RARE tag: after a known name, at every detail, art or not, once; off with the rank switch", function()
    clock.s = clock.s + 5
    -- The cache knows Morgaine the Sly's name but gives her no rank.
    local creatures = cache_of({ [99] = { name = "Morgaine the Sly", type = 7, classification = 0 } })
    local function world(settings, art)
        local F, calls, add = bundle({ art = art, creatures = creatures, settings = settings })
        add(unit({ guid = "m", npc = 99, ctype = 7, level = 10, screen = { x = 500, y = 300 } }), { is_enemy = true, dist = 10 })
        F.render(true, 100)
        return calls, texts(calls)
    end

    local calls, said = world({}, true)
    local at = nil
    for i = 1, #said do if said[i] == "Morgaine the Sly" then at = i end end
    assert(at, "named: " .. table.concat(said, " | "))
    assert_eq(said[at + 1], " \194\183 ", "a dot after the name")
    assert_eq(said[at + 2], "RARE", "then the tag")

    -- The icon alone: the tag is still there, the name is not.
    calls = world({ rare_detail = 3 }, true)
    assert_eq(#exact(calls, "RARE"), 1, "icon detail keeps the tag: " .. pills_text(calls))
    assert(not find_text(calls, "Morgaine"), "no name at icon detail")

    -- No art pack: the word once, on the name row, not again in the facts.
    calls = world({}, false)
    assert_eq(#exact(calls, "RARE"), 1, "once with no art: " .. pills_text(calls))

    -- The rank switch takes the word with the dragon.
    calls = world({ show_badges = false }, true)
    assert_eq(#exact(calls, "RARE"), 0, "badges off: " .. pills_text(calls))
    assert_eq(image_counts(calls)["art:rare"], nil, "and no dragon")
end }

T[#T + 1] = { "1.7.5 the rank in words: ELITE after the name beside the dragon; an elite the client calls a boss is a BOSS", function()
    clock.s = clock.s + 5
    local creatures = cache_of({
        [3001] = { name = "Deviate Ravager", type = 1, classification = 1 },
        [3653] = { name = "Kresh", type = 1, classification = 1 },
        [599] = { name = "Marisa du'Paige", type = 7, classification = 2 },
    })
    local function world(art, settings)
        local F, calls, add, _, traces = bundle({ art = art, creatures = creatures, settings = settings })
        add(unit({ guid = "ravager", npc = 3001, ctype = 1, level = 18, screen = { x = 300, y = 300 } }),
            { is_enemy = true, dist = 10 })
        local kresh = unit({ guid = "kresh", npc = 3653, ctype = 1, level = 20, screen = { x = 900, y = 300 } })
        kresh.is_boss = function() return true end
        add(kresh, { is_enemy = true, dist = 11 })
        local marisa = unit({ guid = "marisa", npc = 599, ctype = 7, level = 19, screen = { x = 1500, y = 300 } })
        marisa.is_boss = function() return true end
        add(marisa, { is_enemy = true, dist = 12 })
        F.render(true, 100)
        return calls, texts(calls), traces
    end

    local calls, said, traces = world(true)
    local at = nil
    for i = 1, #said do if said[i] == "Deviate Ravager" then at = i end end
    assert(at, "named: " .. table.concat(said, " | "))
    assert_eq(said[at + 2], "ELITE", "ELITE after the name")
    local elite = exact(calls, "ELITE")
    assert_eq(#elite, 1, "the plain elite only: " .. table.concat(said, " | "))
    assert_eq(elite[1].c.r, 245, "in the Elites colour"); assert_eq(elite[1].c.g, 150, "the Elites orange")
    local boss = exact(calls, "BOSS")
    assert_eq(#boss, 1, "Kresh, an elite the client calls a boss")
    assert_eq(boss[1].c.r, 200, "in the Bosses colour")
    assert_eq(#exact(calls, "RARE ELITE"), 1, "Marisa stays a rare elite")
    local n = image_counts(calls)
    assert_eq(n["art:elite"], 1, "the gold dragon stays")
    assert_eq(n["art:boss"], 1, "the skull on Kresh")
    assert_eq(n["art:rare_elite"], 1, "Marisa's dragon")
    local kresh_rank = nil
    for i = 1, #traces do
        local src = traces[i]:match("^fesp %S*kresh .- rank=3/(%S+)")
        if src then kresh_rank = src end
    end
    assert_eq(kresh_rank, "cache+boss", "the trace says why: " .. table.concat(traces, "\n"))

    -- No art pack: each word once, on the name row.
    calls = world(false)
    assert_eq(#exact(calls, "ELITE"), 1, "ELITE once with no art: " .. pills_text(calls))
    assert_eq(#exact(calls, "BOSS"), 1, "BOSS once with no art")

    -- The rank switch takes the words with the art.
    calls = world(true, { show_badges = false })
    assert_eq(#exact(calls, "ELITE") + #exact(calls, "BOSS") + #exact(calls, "RARE ELITE"), 0,
        "badges off: " .. pills_text(calls))
end }

-- --- 1.7.6: what a tameable beast teaches a hunter ------------------------------------

--- modules/tame.lua as the ESP sees it: beast() answers `answer` and keeps
--- what it was asked.
local function fake_tame(answer)
    local asked = {}
    return {
        asked = asked,
        hunter = function() return true end,
        beast = function(npc, level, guid, now)
            asked[#asked + 1] = { npc = npc, level = level, guid = guid, now = now }
            return answer
        end,
    }
end

local CROC = { family_name = "Crocolisk", level = 22, can_now = true, skills = {
    { name = "Bite", rank = 3, how = "petopia", sure = true, new = true,
      icon = 132278, spell = 17256 },
    { name = "Dismember", rank = 1, how = "guess", sure = false, new = true,
      icon = 132187, spell = 1264758 },
} }

local function croc_unit(o)
    o = o or {}
    -- A Loch Crocolisk: 2476, the Large one, is a rare, marked under Rares.
    return unit({ guid = o.guid or "croc", npc = o.npc or 1693, level = o.level or 22, ctype = o.ctype or 1,
        screen = o.screen or { x = 500, y = 400 }, pet = o.pet })
end

--- The plate a text sits on: the last plate painted before it.
local function plate_of(calls, text_call)
    local plate = nil
    for i = 1, #calls do
        if calls[i] == text_call then return plate end
        if calls[i].name == "plate" then plate = calls[i] end
    end
    return nil
end

local function image_of(calls, ref)
    for _, c in ipairs(all(calls, "image")) do if c.ref == ref then return c end end
    return nil
end

T[#T + 1] = { "a beast a hunter can tame: one pill per skill, its icon, name and rank; sure in violet, a guess dimmed with '?'", function()
    local tame = fake_tame(CROC)
    local F, calls, add = bundle({ art = true, tame = tame })
    add(croc_unit(), { is_enemy = true, dist = 15 })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    assert_eq(#tame.asked, 1, "asked once for the one beast")
    local q = tame.asked[1]
    assert_eq(q.npc, 1693, "by npc id"); assert_eq(q.level, 22, "and level"); assert_eq(q.guid, "croc", "and guid")
    assert_eq(q.now, clock.s, "with the frame's time")

    local bite = exact(calls, "Bite 3")[1]
    assert(bite, "Bite 3: " .. said)
    assert_eq(bite.c.r, 240, "a sure skill in the text colour")
    local dis = exact(calls, "Dismember 1?")[1]
    assert(dis, "Dismember 1? with its '?': " .. said)
    assert_eq(dis.c.r, 170, "a guess dimmed")
    assert(dis.at.y > bite.at.y, "one row each, the sure one first")
    assert_eq(#exact(calls, " \194\183 new"), 2, "both above the pet's rank: 'new'")

    local bite_img = image_of(calls, "art:pet.132278")
    assert(bite_img, "Bite's icon from the art pack")
    assert_eq(bite_img.tint, nil, "untinted")
    local dis_img = image_of(calls, "art:pet.132187")
    assert(dis_img, "Dismember's icon")
    assert_eq(dis_img.tint and dis_img.tint.a, 140, "a guess's icon faded")
    assert(math.abs(bite_img.at.y - bite.at.y) < 20 and bite_img.at.x < bite.at.x, "the icon left of its name")

    local border = plate_of(calls, bite).o.border
    assert(border and border.r == 185 and border.g == 140 and border.b == 255, "a sure skill's pill outlined in TAME violet")
    assert_eq(plate_of(calls, dis).o.border, nil, "a guess's pill plain")
end }

T[#T + 1] = { "the Hunters switches: all of it off, or the guesses alone off", function()
    local tame = fake_tame(CROC)
    local F, calls, add = bundle({ art = true, tame = tame, settings = { show_pet_skills = false } })
    add(croc_unit(), { is_enemy = true, dist = 15 })
    F.render(true, 100)
    assert_eq(#exact(calls, "Bite 3") + #exact(calls, "Dismember 1?"), 0, "off: no rows")
    assert_eq(#tame.asked, 0, "and tame.lua is not even asked")
    assert(find_text(calls, "22"), "the rest of the card as ever")

    local F2, calls2, add2 = bundle({ art = true, tame = fake_tame(CROC), settings = { pet_skill_guesses = false } })
    add2(croc_unit(), { is_enemy = true, dist = 15 })
    F2.render(true, 100)
    assert_eq(#exact(calls2, "Bite 3"), 1, "the sure one stays")
    assert_eq(#exact(calls2, "Dismember 1?"), 0, "the guess goes")
    assert_eq(image_of(calls2, "art:pet.132187"), nil, "with its icon")
end }

T[#T + 1] = { "never asked for a player, a pet, something not a beast or a corpse; nothing when tame.lua says nothing", function()
    local tame = fake_tame(CROC)
    local F, calls, add = bundle({ art = true, tame = tame })
    add(croc_unit({ guid = "pet", pet = true, screen = { x = 100, y = 100 } }), { is_enemy = false, dist = 5 })
    add(croc_unit({ guid = "kobold", ctype = 7, screen = { x = 300, y = 100 } }), { is_enemy = true, dist = 10 })
    add(unit({ guid = "rogue", class = 4, screen = { x = 500, y = 100 } }), { is_enemy = true, is_player = true, dist = 12 })
    add(croc_unit({ guid = "dead", screen = { x = 700, y = 100 } }), { is_enemy = true, dead = true, dist = 8 })
    F.render(true, 100)
    assert_eq(#tame.asked, 0, "asked for none of them")

    local F2, calls2, add2 = bundle({ art = true, tame = fake_tame(nil) })
    add2(croc_unit(), { is_enemy = true, dist = 15 })
    F2.render(true, 100)
    assert_eq(#all(calls2, "plate") > 0, true, "the card itself is drawn")
    assert(not find_text(calls2, "Bite"), "but no skill rows")
end }

T[#T + 1] = { "above your level: every row dimmed, the first says when it can be tamed, no 'new'", function()
    local later = { family_name = "Crocolisk", level = 34, can_now = false, skills = CROC.skills }
    local F, calls, add = bundle({ art = true, tame = fake_tame(later) })
    add(croc_unit({ level = 34 }), { is_enemy = true, dist = 15 })
    F.render(true, 100)
    local bite = exact(calls, "Bite 3")[1]
    assert(bite, "still listed")
    assert_eq(bite.c.r, 170, "dimmed")
    assert_eq(#exact(calls, " \194\183 tame at 34"), 1, "once, on the first row")
    assert_eq(#exact(calls, " \194\183 new"), 0, "no 'new' until it can be tamed")
    assert_eq(plate_of(calls, bite).o.border, nil, "no violet")
    assert_eq(image_of(calls, "art:pet.132278").tint.a, 140, "its icon faded too")
end }

T[#T + 1] = { "a skill the art pack has no icon for: the rank's spell icon instead; detail 'icon only' shows no rows", function()
    local odd = { family_name = "Bat", level = 30, can_now = true, skills = {
        { name = "Sonic Blast", rank = 2, how = "guess", sure = false, new = false, icon = nil, spell = 1264758 },
    } }
    local F, calls, add = bundle({ art = true, tame = fake_tame(odd) })
    add(croc_unit(), { is_enemy = true, dist = 15 })
    F.render(true, 100)
    assert(exact(calls, "Sonic Blast 2?")[1], "the row: " .. table.concat(texts(calls), " | "))
    assert(image_of(calls, "spell:1264758"), "the spell's own icon")

    local F2, calls2, add2 = bundle({ art = true, tame = fake_tame(CROC), settings = { normal_detail = cfg.DETAIL_ICON or 3 } })
    add2(croc_unit(), { is_enemy = true, dist = 15 })
    F2.render(true, 100)
    assert(not find_text(calls2, "Bite"), "the icon alone: no rows: " .. table.concat(texts(calls2), " | "))

    local F3, calls3, add3 = bundle({ art = true, tame = fake_tame(CROC), settings = { normal_detail = 2 } })
    add3(croc_unit(), { is_enemy = true, dist = 15 })
    F3.render(true, 100)
    assert(exact(calls3, "Bite 3")[1], "icon, name, health and casts: the rows still")
end }

T[#T + 1] = { "the real tame.lua and Petopia's file on Forever: a level 22 Large Loch Crocolisk teaches Bite 3, maybe Dismember 1", function()
    package.loaded["jambix_aio/modules/tame"] = nil
    local hunter = { get_class = function() return 3 end, get_level = function() return 30 end }
    local tame = require("jambix_aio/modules/tame")({
        ctx = { creatures = { beast = function(npc)
            if npc == 2476 then return { tameable = true, family = 6, type = 1 } end
        end } },
        units = { player = function() return hunter end },
        forever = true,
    })
    local F, calls, add = bundle({ art = true, tame = tame })
    add(croc_unit({ npc = 2476 }), { is_enemy = true, dist = 15 })
    add(croc_unit({ guid = "cat", npc = 3566, level = 30, screen = { x = 900, y = 400 } }), { is_enemy = true, dist = 18 })
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    assert(exact(calls, "Bite 3")[1], "Petopia lists it for Bite 3: " .. said)
    assert(exact(calls, "Dismember 1?")[1], "Dismember 1, which nobody can confirm yet")
    assert(image_of(calls, "art:pet.132278"), "Bite's icon")
    assert(image_of(calls, "art:pet.132187"), "Dismember's icon")
    assert(not find_text(calls, "Prowl") and not find_text(calls, "Claw"),
        "the cat the cache does not know, and Petopia does not list: nothing")
end }

-- --- 1.7.6: what skinning a corpse gives ------------------------------------------------

local SKIN_DATA = require("jambix_aio/modules/skinning_data")

local function skin_corpse(add, npc, o)
    o = o or {}
    add(unit({ guid = o.guid or ("c" .. npc), npc = npc, level = o.level or 5, ctype = 1, skin = true,
        screen = o.screen or { x = 500, y = 400 } }), { dead = true, dist = o.dist or 10 })
end

T[#T + 1] = { "a skinnable corpse: what skinning gives, most likely first: icon, name, count, chance", function()
    local F, calls, add = bundle({ art = true })
    skin_corpse(add, 2476)   -- Large Loch Crocolisk
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    assert(find_text(calls, "SKIN") or image_of(calls, "art:skin"), "the pelt as ever")
    local med = exact(calls, "Medium Leather")[1]
    local light = exact(calls, "Light Leather")[1]
    local hide = exact(calls, "Medium Hide")[1]
    assert(med and light and hide, "its three items: " .. said)
    assert(med.at.y < light.at.y and light.at.y < hide.at.y, "most likely first: 55%, 41%, 3.4%")
    assert_eq(med.c.r, 240, "a common item in white")
    assert_eq(#exact(calls, " \194\183 55%"), 1, "Medium Leather 55%: " .. said)
    assert_eq(#exact(calls, " \194\183 41%"), 1, "Light Leather 41%")
    assert_eq(#exact(calls, " \194\183 3.4%"), 1, "Medium Hide 3.4%: one decimal under ten")
    local count = exact(calls, " x1-2")[1]
    assert(count and math.abs(count.at.y - light.at.y) < 1, "Light Leather can be two: x1-2 on its row")
    for _, id in ipairs({ 2319, 2318, 4232 }) do
        local img = image_of(calls, "art:item." .. id)
        assert(img, "item " .. id .. ": its own icon from the art pack")
    end
    local img = image_of(calls, "art:item.2319")
    assert(math.abs(img.at.y - med.at.y) < 20 and img.at.x < med.at.x, "the icon left of its name")
end }

T[#T + 1] = { "The Beast: x4-6, and an epic in purple; a kind sharing another's table uses it", function()
    local F, calls, add = bundle({ art = true })
    skin_corpse(add, 10430, { level = 62 })
    F.render(true, 100)
    local epic = exact(calls, "Pristine Hide of the Beast")[1]
    assert(epic, "the rare hide: " .. table.concat(texts(calls), " | "))
    assert(epic.c.r == 163 and epic.c.g == 53 and epic.c.b == 238, "in the game's epic purple")
    assert(exact(calls, " x4-6")[1], "Rugged Leather four to six")
    assert(exact(calls, " \194\183 1.9%")[1], "the hide's 1.9%")

    local F2, calls2, add2 = bundle({ art = true })
    skin_corpse(add2, 119)   -- Longsnout: Princess's table
    F2.render(true, 100)
    local first = SKIN_DATA.loot[330][1]
    assert(exact(calls2, SKIN_DATA.items[first[1]].name)[1], "Princess's first item on Longsnout")
end }

T[#T + 1] = { "skinning rows: the switch off, a kind Classic never had, the icon alone, a corpse you cannot skin", function()
    local F, calls, add = bundle({ art = true, settings = { show_skin_loot = false } })
    skin_corpse(add, 2476)
    F.render(true, 100)
    assert(not find_text(calls, "Leather"), "off: none")
    assert(image_of(calls, "art:skin"), "the pelt still")

    local F2, calls2, add2 = bundle({ art = true })
    skin_corpse(add2, 276111)   -- Ghostfang, Forever's own
    F2.render(true, 100)
    assert_eq(#all(calls2, "plate"), 0, "Forever's own kind: no rows, the pelt alone")
    assert(image_of(calls2, "art:skin"), "the pelt")

    local F3, calls3, add3 = bundle({ art = true, settings = { corpse_detail = cfg.DETAIL_ICON or 3 } })
    skin_corpse(add3, 2476)
    F3.render(true, 100)
    assert(not find_text(calls3, "Leather"), "the icon alone: no rows")

    local me = { can_skin = function(level) return level <= 10, level * 5, 50, "profession" end }
    local F4, calls4, add4 = bundle({ art = true, player = me })
    skin_corpse(add4, 2476, { level = 22 })
    F4.render(true, 100)
    assert(not find_text(calls4, "Leather"), "your Skinning cannot take it: not marked, nothing listed")
end }

T[#T + 1] = { "skinning rows without the art pack: the names and chances still", function()
    local F, calls, add = bundle({})
    skin_corpse(add, 1131)   -- Winter Wolf
    F.render(true, 100)
    assert(exact(calls, "Ruined Leather Scraps")[1], "the names: " .. table.concat(texts(calls), " | "))
    assert(exact(calls, " \194\183 60%")[1], "60%")
end }

-- --- 1.7.6: the creatures a skin can give Pristine from (PRISTINE) ----------------------

--- A skinner: Skinning `skill`, and can_skin by JCore's rule for that skill.
local function skinner(skill)
    return {
        skill = function(prof) if prof == "skinning" then return skill end end,
        can_skin = function(level)
            local required = level <= 10 and 1 or level <= 20 and (level - 10) * 10 or level * 5
            if not skill then return false, required, nil, nil end
            return skill >= required, required, skill, "profession"
        end,
    }
end

local function living(add, npc, o)
    o = o or {}
    add(unit({ guid = o.guid or ("m" .. npc), npc = npc, level = o.level or 14, ctype = 1,
        screen = o.screen or { x = 500, y = 400 } }), { is_enemy = true, dist = o.dist or 15 })
end

T[#T + 1] = { "pristine under a skinnable corpse: after the Classic rows, green, 'rare'; Forever's own kind gets it alone", function()
    local F, calls, add = bundle({ art = true })
    skin_corpse(add, 157)   -- Goretusk: QuestieDB lists it
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    local p = exact(calls, "Pristine Leather")[1]
    local light = exact(calls, "Light Leather")[1]
    assert(p and light, "the Classic rows and the Pristine one: " .. said)
    assert(p.at.y > light.at.y, "the Pristine last")
    assert(p.c.r == 30 and p.c.g == 255 and p.c.b == 0, "in the game's green")
    assert_eq(#exact(calls, " \194\183 rare"), 1, "'rare': nobody knows its chance: " .. said)
    local img = image_of(calls, "art:item.249427")
    assert(img, "its own icon from the art pack")
    assert(math.abs(img.at.y - p.at.y) < 20 and img.at.x < p.at.x and img.tint == nil, "left of its name, not faded")

    local F2, calls2, add2 = bundle({ art = true })
    skin_corpse(add2, 277645)   -- Gray Fox, Forever's own: from the player's own skins
    F2.render(true, 100)
    assert(exact(calls2, "Pristine Leather")[1], "Forever's own kind: " .. table.concat(texts(calls2), " | "))
    assert(not find_text(calls2, "Light Leather"), "no Classic table: the Pristine alone")

    local F3, calls3, add3 = bundle({ art = true })
    skin_corpse(add3, 2476)   -- Large Loch Crocolisk: never seen giving one
    F3.render(true, 100)
    assert(not find_text(calls3, "Pristine"), "not listed: none")
end }

T[#T + 1] = { "pristine under the living mob, for a skinner: green when your Skinning reaches it, dimmed with the skill it asks for", function()
    local F, calls, add = bundle({ art = true, player = skinner(75) })
    living(add, 157, { level = 15 })   -- Goretusk, asks 50
    F.render(true, 100)
    local said = table.concat(texts(calls), " | ")
    local p = exact(calls, "Pristine Leather")[1]
    assert(p, "the row under the living Goretusk: " .. said)
    assert(p.c.g == 255, "green")
    assert_eq(#exact(calls, " \194\183 rare"), 1, "rare")
    assert(image_of(calls, "art:item.249427"), "its icon")

    local F2, calls2, add2 = bundle({ art = true, player = skinner(75) })
    living(add2, 3238, { level = 23 })   -- Stormhide, asks 115
    F2.render(true, 100)
    local high = exact(calls2, "Pristine Leather")[1]
    assert(high, "still listed: " .. table.concat(texts(calls2), " | "))
    assert_eq(high.c.r, 170, "dimmed")
    assert_eq(#exact(calls2, " \194\183 (Requires Skill 115)"), 1, "with what it asks for")
    assert_eq(image_of(calls2, "art:item.249427").tint.a, 140, "its icon faded too")
end }

T[#T + 1] = { "pristine rows: none without Skinning, for a kind never seen, at the icon alone, or with the switch off", function()
    local F, calls, add = bundle({ art = true, player = skinner(nil) })
    living(add, 157)
    F.render(true, 100)
    assert(not find_text(calls, "Pristine"), "no Skinning: none: " .. table.concat(texts(calls), " | "))

    local F2, calls2, add2 = bundle({ art = true })
    living(add2, 1131)   -- Winter Wolf
    F2.render(true, 100)
    assert(not find_text(calls2, "Pristine"), "never seen giving one: none")

    local F3, calls3, add3 = bundle({ art = true, settings = { normal_detail = cfg.DETAIL_ICON or 3 } })
    living(add3, 157)
    F3.render(true, 100)
    assert(not find_text(calls3, "Pristine"), "the icon alone: no rows")

    local F4, calls4, add4 = bundle({ art = true, settings = { show_pristine = false } })
    living(add4, 157)
    skin_corpse(add4, 3244, { screen = { x = 900, y = 400 } })
    F4.render(true, 100)
    assert(not find_text(calls4, "Pristine"), "off: none, living or dead: " .. table.concat(texts(calls4), " | "))
    assert(exact(calls4, "Light Leather")[1], "the Classic rows stay")

    local F5, calls5, add5 = bundle({ art = true, settings = { show_skin_loot = false } })
    skin_corpse(add5, 157)
    F5.render(true, 100)
    assert(not find_text(calls5, "Light Leather"), "the Classic rows off")
    assert(exact(calls5, "Pristine Leather")[1], "the Pristine its own switch")
end }

return T

-- Jambix AIO: the threat row -- your percent and rank on a mob's threat
-- table, from JCore's threat service, the way Details!' Tiny Threat ranks it.
--
-- Driven through a recording draw service like aio_esp_marks_test, with a
-- threat service holding hand-written boards. Kept in its own file so the
-- stack-layout tests and this one can change independently.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")
local make_roles = require("jambix_aio/modules/esp/roles")
local make_elements = require("jambix_aio/modules/esp/elements")
local make_collect = require("jambix_aio/modules/esp/collect")
local make_classify = require("jambix_aio/modules/esp/classify")

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
    spell_book = { get_spell_name = function() return "" end },
}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local DOT = "\194\183"

-- --- the bundle -------------------------------------------------------------------

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
    local draw = {
        theme = { shadow = "shadow", text_dim = "dim", accent = "accent", neutral = "neutral",
            danger = "danger", warning = "warning" },
        unit_box_corners = record("unit_box_corners"),
        unit_label = record("unit_label"),
        unit_bar = record("unit_bar"),
        text_2d = record("text_2d"),
        line_3d = record("line_3d"),
        circle_2d = record("circle_2d"),
        circle_3d = record("circle_3d"),
        rect_2d = record("rect_2d"),
        -- JCore 1.15's plates and shader bars (1.88.0): the pills are plates.
        plate_2d = record("plate_2d"),
        bar_2d = record("bar_2d"),
        measure = function(text, size) return #text * size * 0.5 end,
        spell_icon = function() return true end,
        unit_anchor = function() return { x = 400, y = 300 } end,
        unit_w2s = function() return { x = 400, y = 320 } end,
        screen_size = function() return 1920, 1080 end,
        image = function() return true end,
    }

    local asked = { boards = 0 }
    local threat = opts.boards and {
        get = function(guid)
            asked.boards = asked.boards + 1
            return opts.boards[guid]
        end,
        company = function() return opts.company or { players = 4, pet = false } end,
    } or nil

    local units = {
        health_fraction = function() return 1.0 end,
        aura_index = function() return opts.auras or {} end,
        player = function() return opts.player end,
        player_position = function() return nil end,
        position = function() return nil end,
        by_guid = function() return nil end,
        guid = function(u) return u and u.guid end,
        combat_reach = function() return 1.5 end,
        distance = function() return 30 end,
        is_dead = function() return false end,
        units = function() return {} end,
        objects = function() return {} end,
    }

    local P = {
        cfg = cfg,
        JCore = { assets = {
            get = function(ref) return { key = ref, state = "ready" } end,
            request = function(ref) return true, { key = ref, state = "ready" } end,
        } },
        log = { fmt = function(level, ...) if level == "error" then error(string.format(...)) end end },
        ctx = {
            LAYER = { WORLD = 100, UNITS = 200, OVERLAY = 300, HUD = 500 },
            on = function() end,
            emit = function() end,
            ROLE = { NONE = 0, TANK = 1, HEALER = 2, DAMAGER = 3 },
            enemies = { get = function() return nil end },
            group = opts.group,
            threat = threat,
            geometry = { vec = function(x, y, z) return { x = x, y = y, z = z } end },
        },
        units = units,
        draw = draw,
        quests = {
            quest_color = function() return "quest" end,
            quest_entries = function() return nil end,
            is_guide_target = function() return false end,
            is_questie_id = function() return false end,
        },
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        master_on = function() return true end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        faded = function(col) return col end,
        class_color = {},
        category_color = { normal = "normal" },
    }
    P.esp_roles = make_roles(P)
    P.esp_classify = make_classify(P)
    P.esp_collect = make_collect(P)
    P.esp_elements = make_elements(P)
    return P, calls, asked
end

local function entity(o)
    o = o or {}
    return {
        obj = { guid = o.guid or "mob", get_position = function() return nil end },
        guid = o.guid or "mob",
        kind = "unit",
        info = {
            name = "Defias Pillager", level = 18, is_player = false,
            can_attack = o.can_attack ~= false, reaction = "hostile",
            creature_type = 7, caster = true,
        },
        name = "Defias Pillager",
        category = "normal",
        distance = 20, range = 100, dead = false,
        lod = o.lod or "full", prio = 30,
    }
end

--- A board in the shape JCore's threat service writes.
local function board(o)
    local me = o.me and {
        percent = o.me.percent, rank = o.me.rank, tanking = o.me.tanking == true,
        is_me = true,
    } or nil
    return {
        at = clock.s, n = o.count, count = o.count,
        me = me, my_rank = me and me.rank, my_percent = me and me.percent,
        next_percent = o.next_percent,
    }
end

local function draw_one(P, e)
    P.esp_elements.begin_frame()
    P.esp_elements.draw_entity(e)
end

local function label(calls, pattern)
    for i = 1, #calls do
        local c = calls[i]
        if c.name == "unit_label" and type(c[2]) == "string" and c[2]:find(pattern, 1, true) then
            return c
        end
    end
    return nil
end

local function name_y(calls)
    local c = label(calls, "Defias Pillager")
    return c and c[4].at.y
end

local T = {}

T[#T + 1] = { "chasing the tank: your percent and your rank, green while comfortable", function()
    local P, calls = bundle({ boards = { mob = board({ count = 5, me = { percent = 42, rank = 3 } }) } })
    draw_one(P, entity())
    local row = label(calls, "threat 42%")
    assert(row, "the threat row")
    assert_eq(row[2], "threat 42%  " .. DOT .. "  #3 of 5", "percent and rank, Tiny Threat's numbers")
    assert_eq(row[3], P.esp_elements.threat_color.safe, "green")
end }

T[#T + 1] = { "amber from 70, red from 90: the colour is how close you are to pulling", function()
    local P, calls = bundle({ boards = { mob = board({ count = 5, me = { percent = 75, rank = 2 } }) } })
    draw_one(P, entity())
    assert_eq(label(calls, "threat 75%")[3], P.esp_elements.threat_color.close, "amber at 75")

    local P2, calls2 = bundle({ boards = { mob = board({ count = 5, me = { percent = 96, rank = 2 } }) } })
    draw_one(P2, entity())
    assert_eq(label(calls2, "threat 96%")[3], P2.esp_elements.threat_color.pulling, "red at 96")
end }

T[#T + 1] = { "a mage holding the boss: 'aggro' in red, with the runner-up's percent", function()
    local P, calls = bundle({ player = { guid = "me", get_class = function() return 8 end },
        boards = { mob = board({ count = 4, me = { percent = 100, rank = 1, tanking = true }, next_percent = 40 }) } })
    draw_one(P, entity())
    local row = label(calls, "aggro")
    assert(row, "the aggro row")
    assert_eq(row[2], "aggro  " .. DOT .. "  #1 of 4  " .. DOT .. "  next 40%", "rank and runner-up")
    assert_eq(row[3], P.esp_elements.threat_color.pulling, "red: a mage should not hold it")
end }

T[#T + 1] = { "a tank holding it: coloured by how close the runner-up is", function()
    -- A warrior in Defensive Stance is a tank without any setting saying so.
    local defensive = cfg.ROLE_TELLS and cfg.ROLE_TELLS.WARRIOR and cfg.ROLE_TELLS.WARRIOR[1]
    assert(defensive and defensive[2] == "tank", "config names a warrior tank tell")
    local auras = { [defensive[1][1]] = true }
    local warrior = { guid = "me", get_class = function() return 1 end }

    local P, calls = bundle({ player = warrior, auras = auras,
        boards = { mob = board({ count = 5, me = { percent = 100, rank = 1, tanking = true }, next_percent = 55 }) } })
    draw_one(P, entity())
    assert_eq(label(calls, "aggro")[3], P.esp_elements.threat_color.safe, "green: a wide margin")

    clock.s = clock.s + 5
    local P2, calls2 = bundle({ player = warrior, auras = auras,
        boards = { mob = board({ count = 5, me = { percent = 100, rank = 1, tanking = true }, next_percent = 93 }) } })
    draw_one(P2, entity())
    assert_eq(label(calls2, "aggro")[3], P2.esp_elements.threat_color.pulling, "red: about to lose it")
end }

T[#T + 1] = { "solo with no pet: 'aggro #1 of 1' in green -- nobody else could hold it", function()
    local P, calls = bundle({ player = { guid = "me", get_class = function() return 8 end },
        company = { players = 0, pet = false },
        boards = { mob = board({ count = 1, me = { percent = 100, rank = 1, tanking = true } }) } })
    draw_one(P, entity())
    local row = label(calls, "aggro")
    assert(row, "solo shows the row")
    assert_eq(row[2], "aggro  " .. DOT .. "  #1 of 1", "rank of one")
    assert_eq(row[3], P.esp_elements.threat_color.safe, "green: holding it is the only possibility")
end }

T[#T + 1] = { "solo with a pet: behind it is green, holding it yourself is red", function()
    local hunter = { guid = "me", get_class = function() return 3 end }
    local P, calls = bundle({ player = hunter, company = { players = 0, pet = true },
        boards = { mob = board({ count = 2, me = { percent = 55, rank = 2 } }) } })
    draw_one(P, entity())
    local row = label(calls, "threat 55%")
    assert_eq(row and row[2], "threat 55%  " .. DOT .. "  #2 of 2", "your place behind the pet")
    assert_eq(row[3], P.esp_elements.threat_color.safe, "green")

    local P2, calls2 = bundle({ player = hunter, company = { players = 0, pet = true },
        boards = { mob = board({ count = 2, me = { percent = 100, rank = 1, tanking = true }, next_percent = 60 }) } })
    draw_one(P2, entity())
    assert_eq(label(calls2, "aggro")[3], P2.esp_elements.threat_color.pulling, "red: the pet should have it")
end }

T[#T + 1] = { "in the group's fight with none of it yours: 'threat 0%' and who holds it", function()
    local b = board({ count = 2 })
    b.tank = { name = "Gweedzug", tanking = true }
    local P, calls = bundle({ boards = { mob = b } })
    draw_one(P, entity())
    local row = label(calls, "threat 0%")
    assert(row, "said, not left blank")
    assert_eq(row[2], "threat 0%  " .. DOT .. "  tank Gweedzug", "and who holds it")
    assert_eq(row[3], P.esp_elements.threat_color.safe, "green: safe")
end }

T[#T + 1] = { "nothing to show: no board at all", function()
    local P, calls = bundle({ boards = {} })
    draw_one(P, entity())
    assert(not label(calls, "threat") and not label(calls, "aggro"), "no board: no row")

    local P3, calls3 = bundle({ boards = { mob = board({ count = 3 }) } })
    draw_one(P3, entity())
    assert(label(calls3, "threat 0%"), "a board with none of it yours: 'threat 0%'")

    local P4, calls4 = bundle()
    draw_one(P4, entity())
    assert(not label(calls4, "threat"), "an older JCore with no threat service: no row, no error")
end }

T[#T + 1] = { "by default the row goes under the feet, with the status rows, and the name stays", function()
    local P1, quiet = bundle({ boards = {} })
    draw_one(P1, entity())
    local P2, ranked = bundle({ boards = { mob = board({ count = 5, me = { percent = 42, rank = 3 } }) } })
    draw_one(P2, entity())
    assert_eq(name_y(ranked), name_y(quiet), "the name above does not move")
    local row = label(ranked, "threat 42%")
    assert(row, "the pill")
    assert(row[4].at.y > 320, "under the feet (the mock projects them to y = 320)")
    local backdrop = false
    for _, c in ipairs(ranked) do
        if c.name == "plate_2d" and c[5].border == P2.esp_elements.threat_color.safe then backdrop = true end
    end
    assert(backdrop, "a plate bordered in its own colour")
end }

T[#T + 1] = { "rows above the head: the row takes room in the stack and the name moves up", function()
    local settings = { esp_rows_below = false }
    local P1, quiet = bundle({ boards = {}, settings = settings })
    draw_one(P1, entity())
    local P2, ranked = bundle({ boards = { mob = board({ count = 5, me = { percent = 42, rank = 3 } }) },
        settings = settings })
    draw_one(P2, entity())
    local y1, y2 = name_y(quiet), name_y(ranked)
    assert(y1 and y2, "name drawn both times")
    assert(y2 < y1, "name higher with a threat row under it")
    local row = label(ranked, "threat 42%")
    assert(row[4].at.y > y2 and row[4].at.y < 300, "the row sits between the name and the head")
end }

T[#T + 1] = { "off by toggle, at the far tier, and on a friend: no row and no lookup", function()
    local boards = { mob = board({ count = 5, me = { percent = 42, rank = 3 } }) }
    local P, calls, asked = bundle({ boards = boards, settings = { show_threat = false } })
    draw_one(P, entity())
    assert(not label(calls, "threat"), "toggled off")
    assert_eq(asked.boards, 0, "and not asked")

    local P2, calls2, asked2 = bundle({ boards = boards })
    draw_one(P2, entity({ lod = "far" }))
    assert(not label(calls2, "threat"), "far tier")
    assert_eq(asked2.boards, 0, "not asked at the far tier")

    local P3, calls3, asked3 = bundle({ boards = boards })
    draw_one(P3, entity({ can_attack = false }))
    assert_eq(asked3.boards, 0, "a friend is never looked up")
end }

T[#T + 1] = { "config: the threat row has a toggle and a drawer", function()
    local P = bundle()
    local found = false
    for _, el in ipairs(P.esp_elements.active()) do
        if el.key == "show_threat" then found = true end
    end
    assert(found, "show_threat has a drawer")
    assert(cfg.ELEMENT_BY_KEY.show_threat, "and a toggle row")
    assert(cfg.THREAT_CLOSE < cfg.THREAT_PULLING, "amber before red")
end }

return T

-- Jambix AIO: the Reactions window, recorded for a look (opt-in).
--
--   JTEST_SNAPSHOT=1 node tools/jtest/run.js aio_reactwin_snapshot
--
-- Boots the whole plugin as an Era hunter, opens the Reactions window on a
-- 1920x1080 screen, and writes one frame of every view's draw calls to
-- tools/jtest/out/reactwin/<name>.txt: tab<N> for the five views, step<N>
-- for the editor's five steps, plus the built-in list folded, scrolled by
-- the wheel and by dragging its bar (1.77.0), and at text sizes 100% and 160%
-- (*_zoom100, *_zoom160; the rest are at the default 125%, 1.78.1). One call per line, with the
-- window's rectangle on the first. Any 2D rasteriser can paint them; the
-- point is to see the layout -- overlaps, clipping, what reads as what --
-- without the game.

local boot = require("mock/aio_boot")

local T = {}

if not (jtest and jtest.env and jtest.env("JTEST_SNAPSHOT") == "1") then
    T[#T + 1] = { "snapshot (skipped: set JTEST_SNAPSHOT=1 to record the Reactions window)", function() end }
    return T
end

local NAMES = { [5384] = "Feign Death", [1978] = "Serpent Sting", [2973] = "Raptor Strike",
    [19263] = "Deterrence", [1499] = "Freezing Trap", [5116] = "Concussive Shot" }

local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 60,
        get_health = 380, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        is_moving = false, is_mounted = false, is_in_combat = false, is_casting_spell = false,
        is_channelling_spell = false, is_auto_attacking = false, can_attack = false,
        get_rotation = 0, get_classification = 0, get_attack_speed = 2.8,
        get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
        get_unit_ranged_damage = { speed = 2.8 },
        get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
        is_player = true, is_unit = true, get_type = 6,
    }
    local obj = {}
    for k, v in pairs(p) do obj[k] = function() return v end end
    obj.get_position = function() return { x = 100, y = 100, z = 0 } end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local function col(c)
    if type(c) ~= "table" then return "255,255,255,255" end
    return string.format("%d,%d,%d,%d", c.r or 255, c.g or 255, c.b or 255, c.a or 255)
end

local function num(v) return string.format("%.1f", tonumber(v) or 0) end

T[#T + 1] = { "snapshot: every tab of the Reactions window, one frame each", function()
    local b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    local me = hunter()
    core.object_manager.get_local_player = function() return me end
    local ids = {}
    for id in pairs(NAMES) do ids[#ids + 1] = id end
    core.spell_book.get_spells = function() return ids end
    core.spell_book.get_spell_name = function(id) return NAMES[id] end
    core.spell_book.is_spell_known = function(id) return NAMES[id] ~= nil end
    core.spell_book.is_usable_spell = function(id) return NAMES[id] ~= nil end
    core.spell_book.get_spell_cooldown = function() return 0 end
    b.P.spellbook.refresh()
    b.P.spellbook.castable = function(name) return b.P.spellbook.known(name) end
    b.mock.menu:set("Jambix AIO/Rotation", "rot_enabled", true)
    b.mock.menu:set("Jambix AIO/Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    b.P.opt_invalidate()
    local vec2 = b.JCore.ui._vec2
    core.graphics.get_screen_size = function() return vec2(1920, 1080) end
    b.mock.frame(10)

    local C = b.P.react.custom
    C.set_library(C.D.LIBRARY_EXAMPLE .. "\nfunction trap_the_add()\n    return cast(\"Freezing Trap\", \"attacker\")\nend\n")
    local env = C.fresh_env()
    env.raid_pick = "Molten Core"
    env.arena = false
    C.save({ name = "Panic button", importance = "survival", combat_only = false,
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 40 },
                  { mode = "lua", code = "fight.on_me >= 1 or me.falling > 5" } },
        actions = { { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" },
                    { mode = "lua", code = 'cast("Deterrence", "self")' } }, env = env })
    C.save({ name = "Trap the add", importance = "cc",
        conds = { { mode = "gui", key = "me_attackers", op = ">=", value = 2 } },
        actions = { { mode = "gui", kind = "lua_fn", fn = "trap_the_add" } } })
    C.save({ name = "Slow the runner", importance = "cc", on = false,
        conds = { { mode = "gui", key = "t_runs", op = "is" }, { mode = "gui", key = "t_hp", op = "<", value = 25 } },
        actions = { { mode = "gui", kind = "spell", spell = "Concussive Shot", target = "target" } } })
    C.set_default_on("Dispel", false)
    b.mock.frame(30)

    b.P.reactwin.open()
    b.mock.frame(3)
    local st = b.P.reactwin.state

    local log
    local function wrap(name, fmt)
        local orig = core.graphics[name]
        core.graphics[name] = function(...)
            if log then log[#log + 1] = fmt(...) end
            if orig then return orig(...) end
        end
    end
    wrap("rect_2d_filled", function(p, w, h, c, r) return table.concat({ "RF", num(p.x), num(p.y), num(w), num(h), col(c), num(r) }, "|") end)
    wrap("rect_2d", function(p, w, h, c, t, r) return table.concat({ "R", num(p.x), num(p.y), num(w), num(h), col(c), num(t), num(r) }, "|") end)
    wrap("line_2d", function(a, z, c, t) return table.concat({ "L", num(a.x), num(a.y), num(z.x), num(z.y), col(c), num(t) }, "|") end)
    wrap("text_2d", function(s, p, size, c, centered) return table.concat({ "T", num(p.x), num(p.y), num(size), col(c), centered and "1" or "0", (tostring(s):gsub("[|\n]", " ")) }, "|") end)
    wrap("circle_2d_filled", function(p, r, c) return table.concat({ "CF", num(p.x), num(p.y), num(r), col(c) }, "|") end)
    wrap("circle_2d", function(p, r, c, t) return table.concat({ "C", num(p.x), num(p.y), num(r), col(c), num(t) }, "|") end)
    wrap("triangle_2d_filled", function(a, z, q, c) return table.concat({ "TF", num(a.x), num(a.y), num(z.x), num(z.y), num(q.x), num(q.y), col(c) }, "|") end)
    wrap("scissor_push", function(x, y, w, h) return table.concat({ "S", num(x), num(y), num(w), num(h) }, "|") end)
    wrap("scissor_pop", function() return "SP" end)
    wrap("draw_texture", function(_, p, w, h) return table.concat({ "IMG", num(p.x), num(p.y), num(w), num(h) }, "|") end)

    local function window()
        for _, w in ipairs(b.JCore.ui.windows()) do
            if w.id == "jambix.aio:" .. b.P.reactwin.WINDOW_ID then return w end
        end
    end

    local function shot(name)
        b.mock.frame(2)
        log = {}
        b.mock.frame(1)
        local rec = log
        log = nil
        local win = window()
        assert(win, "the window is listed")
        table.insert(rec, 1, string.format("WIN|%s|%s|%s|%s", num(win.x), num(win.y), num(win.w), num(win.h)))
        jtest.write_file("reactwin/" .. name .. ".txt", table.concat(rec, "\n"))
        assert(st.err == nil, name .. ": the body raised: " .. tostring(st.err))
    end

    for tab = 1, 5 do
        st.tab = tab
        if tab == 3 then b.P.reactwin._open_draft(C.get(1)) end
        shot("tab" .. tab)
    end
    st.tab = 3
    for step = 1, 5 do
        st.section = step
        shot("step" .. step)
    end
    st.expanded = "Interrupt"
    st.tab = 1
    shot("tab1_where")
    st.expanded = nil
    for _, cat in ipairs({ "survival", "bailout", "interrupt", "escape", "cc", "defensive" }) do st.cat_closed[cat] = true end
    shot("tab1_folded")
    st.cat_closed = {}

    -- The Import view (1.77.2): empty, then a repository read, then imported.
    st.tab = 6
    shot("tab6_empty")
    local json = b.JCore.json
    local R = b.mock.http_responses
    R["https://api.github.com/repos/alice/packs/git/trees/HEAD?recursive=1"] = { code = 200, body = json.encode({ tree = {
        { path = "Reaction", type = "tree" }, { path = "Reaction/panic.json", type = "blob" },
        { path = "Reaction/kit.json", type = "blob" }, { path = "Reaction/Mage", type = "tree" },
        { path = "Reaction/Mage/nova.json", type = "blob" }, { path = "Reaction/bad.json", type = "blob" },
        { path = "Reaction/library.lua", type = "blob" } } }) }
    local base = "https://raw.githubusercontent.com/alice/packs/HEAD/Reaction/"
    R[base .. "panic.json"] = { code = 200, body = '{ "format": "jambix-reaction", "name": "Panic button", "importance": "survival",'
        .. ' "conds": [ { "mode": "gui", "key": "me_hp", "op": "<", "value": 30 }, { "mode": "lua", "code": "return fight.on_me >= 2" } ],'
        .. ' "actions": [ { "mode": "gui", "kind": "spell", "spell": "Feign Death", "target": "self" } ] }' }
    R[base .. "kit.json"] = { code = 200, body = '{ "class": "HUNTER", "reactions": ['
        .. ' { "name": "Deter the melee", "importance": "defensive", "conds": [ { "mode": "gui", "key": "me_attackers", "op": ">=", "value": 2 } ],'
        .. ' "actions": [ { "mode": "gui", "kind": "spell", "spell": "Deterrence", "target": "self" } ] },'
        .. ' { "name": "Trap the add", "importance": "cc", "actions": [ { "mode": "gui", "kind": "lua_fn", "fn": "trap_it" } ] } ] }' }
    R[base .. "Mage/nova.json"] = { code = 200, body = '{ "name": "Nova when surrounded", "importance": "cc",'
        .. ' "actions": [ { "mode": "gui", "kind": "spell", "spell": "Frost Nova", "target": "self" } ] }' }
    R[base .. "bad.json"] = { code = 200, body = "{ nope" }
    R[base .. "library.lua"] = { code = 200, body = "function trap_it()\n    return cast(\"Freezing Trap\", \"attacker\")\nend\n" }
    st.import_url = "https://github.com/alice/packs"
    C.share.fetch(st.import_url)
    for _ = 1, 30 do b.mock.frame(1) if not C.share.job.busy then break end end
    shot("tab6_found")
    C.share.import({})
    shot("tab6_imported")

    -- Dungeons and the open world (1.78.0): the pet's taunt switched on for
    -- dungeons and its Where open; then both starter packs, one added.
    C.set_default_place("Pet: taunt", "dungeon", true)
    st.tab = 1
    st.search = "taunt"
    st.expanded = "Pet: taunt"
    shot("tab1_places")
    st.search = ""
    st.expanded = nil
    st.tab = 2
    st.packs_open = { dungeon = true, world = true }
    C.packs.add("dungeon", "hunter_wipe_fd")
    shot("tab2_packs")

    -- 1.79.0: why on the cards, every new kind of row, a fire in the
    -- history, and the Try it bench.
    st.packs_open = { dungeon = false, world = false }
    local id179 = C.save({ name = "Wipe guard", importance = "survival", per_fight = 1, notify_alert = true,
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 40, for_s = 1 },
                  { mode = "gui", key = "me_buff_left", op = "<", value = "Ice Barrier", num = 3 },
                  { mode = "gui", key = "key_held", op = "is", value = 0x46 } },
        actions = { { mode = "gui", kind = "alert", text = "WIPE - FEIGN", color = "red" },
                    { mode = "gui", kind = "target", who = "lowest" },
                    { mode = "gui", kind = "named_item", name = "Hearthstone" },
                    { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" } } })
    local rt179 = C.runtime_of(id179)
    rt179.total_n, rt179.fight_n = 3, 1
    rt179.history = { { at = core.time() - 12, what = "Feign Death", on = "you", hp = 18, where = "Dungeon: The Deadmines",
        reads = "1: 18%, 2: 0s, 3: yes" }, { at = core.time() - 95, what = "Alert: WIPE - FEIGN", hp = 35, where = "Open world" } }
    st.tab = 2
    shot("v179_cards")
    b.P.reactwin._open_draft(C.get(id179))
    st.section = 1
    shot("v179_step1")
    st.section = 2
    shot("v179_step2")
    st.section = 3
    shot("v179_step3")
    st.section = 6
    st.bench, st.bench_preset = nil, 2
    shot("v179_step6")
    st.draft = nil
    st.tab = 1

    -- The list scrolled: the wheel over the body, then the bar dragged to
    -- the bottom of its track.
    local win = window()
    local bar_x = win.x + win.w - 12
    b.mock.move(win.x + win.w - 200, win.y + 300)
    b.mock.frame(1)
    for _ = 1, 6 do b.mock.wheel = -1; b.mock.frame(1) end
    b.mock.wheel = 0
    shot("tab1_wheel")
    b.mock.move(bar_x, win.y + 160)
    b.mock.frame(1)
    b.mock.press(0x01)
    b.mock.frame(1)
    b.mock.move(bar_x, win.y + win.h + 200)
    b.mock.frame(2)
    shot("tab1_dragged")
    b.mock.release(0x01)
    b.mock.move(5, 5)
    b.mock.frame(2)

    -- Text size (1.78.1): the window at 100% and 160%, its boxes growing
    -- with the text in them. The default is 125%, the shots above.
    for _, zm in ipairs({ 1.0, 1.6 }) do
        b.P.reactwin.set_zoom(zm)
        local tag = math.floor(zm * 100 + 0.5)
        st.tab = 2
        shot("tab2_zoom" .. tag)
        st.tab, st.section = 3, 2
        shot("step2_zoom" .. tag)
        st.tab = 6
        shot("tab6_zoom" .. tag)
    end
    b.P.reactwin.set_zoom(1.25)
    b.mock.frame(2)
    assert(b.errors() == "", "core.log_error: " .. b.errors())
end }

return T

-- Jambix AIO, the WHOLE plugin: the Reactions tab and its window (1.76.0).
--
-- main.lua on top of the whole JCore under mock_core, as the Era client, with
-- a hunter logged in and the rotation on. The Reactions page has, since
-- 2026-10-11, neither a switch (the user: reactions are automatic, waking in
-- PvP when it is detected, not an option) nor an "Open Reactions UI" button
-- (out of the player's reach, the code kept); the window still opens from
-- code; every tab draws through JCore's real toolkit with no error; a
-- reaction saved for the class goes into the engine and fires; a saved
-- "off" changes nothing.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local NAMES = { [5384] = "Feign Death", [1978] = "Serpent Sting", [2973] = "Raptor Strike" }

local HP = { now = 900 }

local function hunter()
    local p = {
        is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001",
        get_name = "Hunter", get_class = 3, get_race_id = 1, get_level = 30,
        get_max_health = 1000, get_power = 800, get_max_power = 1000,
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
    for k, v in pairs(p) do
        obj[k] = function() return v end
    end
    obj.get_health = function() return HP.now end
    obj.get_position = function() return { x = 100, y = 100, z = 0 } end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local T = {}
local b
local casts = {}

local function set(page, id, value)
    b.mock.menu:set("Jambix AIO/" .. page, id, value)
    b.P.opt_invalidate()
end

local function find_button(page_path, id)
    local page = b.mock.menu.pages[page_path]
    if not page then return nil end
    for _, s in ipairs(page.sections) do
        if s.buttons and s.buttons[id] then return s.buttons[id] end
    end
    return page.buttons[id]
end

local function mine(reason_part)
    local n = 0
    for _, c in ipairs(casts) do
        if tostring(c.reason):find(reason_part, 1, true) then n = n + 1 end
    end
    return n
end

T[#T + 1] = { "the Reactions tab: reactions automatic (no switch), no Open Reactions UI button, the window opens from code", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" })
    local me = hunter()
    core.object_manager.get_local_player = function() return me end
    core.spell_book.get_spells = function() return { 5384, 1978, 2973 } end
    core.spell_book.get_spell_name = function(id) return NAMES[id] end
    core.spell_book.is_spell_known = function(id) return NAMES[id] ~= nil end
    core.spell_book.is_usable_spell = function(id) return NAMES[id] ~= nil end
    core.spell_book.get_spell_cooldown = function() return 0 end
    b.P.spellbook.refresh()
    -- The fake client has no range answer; the real one says yes to a self-cast.
    b.P.spellbook.castable = function(name) return b.P.spellbook.known(name) end
    b.ctx.cast = function(request) casts[#casts + 1] = request; return true end
    set("Rotation", "rot_enabled", true)
    set("Rotation", "rot_key", { vk = 0x58, active = true, toggled = true })
    assert_eq(b.errors(), "", "core.log_error during boot")
    assert(b.mock.menu.pages["Jambix AIO/Reactions"], "the Reactions page is declared")
    assert_eq(b.P.opt("react_active", "unset"), "unset", "no 'Use reactions in the rotation' switch on the page (2026-10-11)")
    assert_eq(b.P.react.active(), true, "reactions are automatic: always on")
    local button = find_button("Jambix AIO/Reactions", "react_open_ui")
    assert(button == nil, "no Open Reactions UI button: the window is out of the player's reach (2026-10-11)")
    b.mock.frame(30)
    assert_eq(b.P.reactwin.state.shown, false, "the window is shut")
    assert(type(b.P.reactwin.open) == "function", "the window's code stays: P.reactwin.open")
    b.P.reactwin.open()
    b.mock.frame(5)
    assert_eq(b.P.reactwin.state.shown, true, "opened from code, it draws")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "the Reactions window: every tab draws through the real toolkit, the built-in reactions listed", function()
    local st = b.P.reactwin.state
    local C = b.P.react.custom
    assert_eq(C.class(), "HUNTER", "the class is known")
    local defaults = C.defaults()
    assert(#defaults >= 20, "the built-in reactions are listed: " .. #defaults)
    for tab = 1, 5 do
        st.tab = tab
        b.mock.frame(4)
        assert_eq(b.errors(), "", "core.log_error on tab " .. tab)
        assert_eq(st.err, nil, "the window body raised on tab " .. tab)
    end
    -- A built-in one opened for its places, and the editor on a template.
    st.tab = 1
    st.expanded = "Interrupt"
    b.mock.frame(3)
    b.P.reactwin._open_draft(C.from_template(8))     -- the Lua template
    b.mock.frame(4)
    assert_eq(st.tab, 3, "a draft opens the editor")
    assert_eq(st.err, nil, "the editor draws a Lua draft")
    b.P.reactwin._open_draft(C.from_template(2))     -- the panic button: GUI rows
    b.mock.frame(4)
    assert_eq(st.err, nil, "the editor draws a GUI draft")
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "the window: the built-in list by place and the starter packs draw through the real toolkit (1.78.0)", function()
    local st = b.P.reactwin.state
    local C = b.P.react.custom
    local taunt
    for _, d in ipairs(C.defaults()) do if d.name == "Pet: taunt" then taunt = d end end
    assert(taunt and taunt.world == true and taunt.dungeon == false, "the pet's taunt: the open world, not dungeons")
    C.set_default_place("Pet: taunt", "dungeon", true)
    st.tab = 1
    st.expanded = "Pet: taunt"
    b.mock.frame(3)
    assert_eq(st.err, nil, "the built-in list draws with a changed row open")
    st.expanded = nil
    st.search = "pet"
    b.mock.frame(3)
    assert_eq(st.err, nil, "and searched")
    st.search = ""
    C.reset_defaults()
    st.tab = 2
    st.packs_open = { dungeon = true, world = true }
    b.mock.frame(3)
    assert_eq(st.err, nil, "My reactions draws with both packs open")
    local id = C.packs.add("dungeon", "hunter_wipe_fd")
    assert(id, "Wipe coming: Feign Death added (Feign Death is in the spellbook)")
    b.mock.frame(3)
    assert_eq(st.err, nil, "and with one of them added")
    b.P.reactwin._open_draft(C.get(id))
    b.mock.frame(3)
    assert_eq(st.err, nil, "the editor opens a pack reaction")
    C.delete(id)
    st.draft = nil
    st.tab = 1
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "the window, 1.79.0: why on the cards, search and filter, every new row, the Try it bench at every situation, Live", function()
    local st = b.P.reactwin.state
    local W = b.P.reactwin
    local C = b.P.react.custom
    local id = C.save({ name = "Everything", importance = "survival", per_fight = 2, notify_alert = true,
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 40, for_s = 1 },
                  { mode = "gui", key = "me_buff_left", op = "<", value = "Ice Barrier", num = 3 },
                  { mode = "gui", key = "key_held", op = "is", value = 0x46 },
                  { mode = "gui", key = "me_has_item", op = "is", value = "Hearthstone" },
                  { mode = "gui", key = "t_name", op = "is", value = "Hogger" },
                  { mode = "gui", key = "t_on_tank", op = "is" } },
        actions = { { mode = "gui", kind = "alert", text = "GO", color = "green", sound = false },
                    { mode = "gui", kind = "target", who = "lowest" },
                    { mode = "gui", kind = "stop_cast" },
                    { mode = "gui", kind = "named_item", name = "Hearthstone" },
                    { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" } } })
    assert(id, "saved")
    st.tab = 2
    b.mock.frame(3)
    assert_eq(st.err, nil, "My reactions draws its cards with why")
    st.mine_q = "every"
    assert_eq(#W._listed(C), 1, "the search finds it")
    b.mock.frame(2)
    st.mine_q = ""
    st.mine_filter = 7
    assert_eq(#W._listed(C), 0, "no Lua in it: the Lua filter leaves it out")
    b.mock.frame(2)
    assert_eq(st.err, nil, "an empty filter draws")
    st.mine_filter = 1
    W._paste(C)
    b.mock.frame(2)
    assert_eq(st.err, nil, "Paste with nothing to paste only says so")
    W._open_draft(C.get(id))
    for _, cnd in ipairs(st.draft.conds) do st.timer_open[cnd.uid] = true end
    for section = 1, 6 do
        st.section = section
        b.mock.frame(3)
        assert_eq(st.err, nil, "the editor's step " .. section)
    end
    st.section = 6
    st.bench_open = { you = true, mobs = true, target = true, pet = true, group = true, where = true }
    for i = 1, #C.D.BENCH_PRESETS do
        st.bench, st.bench_preset = nil, i
        b.mock.frame(2)
        assert_eq(st.err, nil, "Try it: " .. C.D.BENCH_PRESETS[i].label)
    end
    st.tab = 5
    b.mock.frame(3)
    assert_eq(st.err, nil, "Live draws why for each")
    C.delete(id)
    st.draft = nil
    st.tab = 1
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "a reaction saved for the class goes into the engine and fires; the Reactions switch stops it", function()
    local C = b.P.react.custom
    local id = C.save({
        name = "Test panic", importance = "survival", combat_only = false,
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 30 } },
        actions = { { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" } },
    })
    assert(id, "saved")
    b.mock.frame(30)
    assert_eq(mine("My: Test panic"), 0, "health 90%: it waits")
    HP.now = 200
    b.mock.frame(30)
    assert(mine("My: Test panic") >= 1, "health 20%: Feign Death went out from it" .. (function()
        local r = {}
        for _, c in ipairs(casts) do r[#r + 1] = tostring(c.reason) end
        local rt = C.runtime(id) or {}
        local c1 = rt.conds and rt.conds[1] or {}
        return string.format("\ncasts: %s\nreaction: asked=%s pass=%s note=%s cond=%s/%s/%s\njournal:\n%s",
            table.concat(r, " | "), tostring(rt.asked_at), tostring(rt.pass), tostring(rt.note),
            tostring(c1.ok), tostring(c1.shown), tostring(c1.err),
            table.concat(b.P.react.log_lines(15), "\n"))
    end)())
    local rt = C.runtime(id)
    assert(rt and rt.pass == true, "its conditions hold, for the window's light")
    b.P.reactwin.state.tab = 2
    b.mock.frame(3)
    b.P.reactwin.state.tab = 5
    b.mock.frame(3)
    assert_eq(b.P.reactwin.state.err, nil, "cards and the live tab draw with it")
    -- The switch is gone (2026-10-11): a value a player saved before changes nothing.
    set("Reactions", "react_active", false)
    b.P.opt_invalidate()
    b.mock.frame(5)
    assert_eq(b.P.react.active(), true, "a saved 'off' changes nothing: reactions are automatic")
    assert_eq(b.P.react.custom.master_on(), true, "the custom layer agrees")
    set("Reactions", "react_active", true)
    HP.now = 900
    assert_eq(b.errors(), "", "core.log_error")
end }

T[#T + 1] = { "the page's live lines say what is on, where you are and what went out last", function()
    b.mock.frame(2)
    b.mock.menu:render_titles()
    assert_eq(#b.mock.menu.title_errors, 0, "no title provider failed: " .. table.concat(b.mock.menu.title_errors, "\n"))
    local found = false
    for _, t in ipairs(b.mock.menu.titles) do
        if t.path == "Jambix AIO/Reactions" then
            local ok, s = pcall(t.fn)
            if ok and type(s) == "string" and s:find("of your own", 1, true) then found = true end
        end
    end
    assert(found, "the summary line names your own reactions")
end }

T[#T + 1] = { "text size: the window draws at its own scale, grows with it, every view at every size (1.78.1)", function()
    local rw = b.P.reactwin
    local st = rw.state
    rw.open(1)
    rw.set_zoom(1.0)
    b.mock.frame(4)
    local win = b.JCore.ui._windows["jambix.aio:" .. rw.WINDOW_ID]
    assert(win, "the window record")
    assert(math.abs((win.scale or 0) - 1.0) < 0.001, "drawn at 100%: " .. tostring(win.scale))
    local w100 = win.w
    rw.set_zoom(1.6)
    b.mock.frame(4)
    assert(math.abs((win.scale or 0) - 1.6) < 0.001, "drawn at 160%: " .. tostring(win.scale))
    assert(math.abs(win.w - w100 * 1.6) <= 2, string.format("the window grew with the text: %d -> %d", w100, win.w))
    assert_eq(rw.zoom(), 1.6, "the text size is kept")
    for _, zm in ipairs({ 0.9, 1.6, 2.0 }) do
        rw.set_zoom(zm)
        for tab = 1, 6 do
            st.tab = tab
            if tab == 3 then st.section = 2 end
            b.mock.frame(2)
            assert_eq(st.err, nil, string.format("view %d at %d%%", tab, zm * 100))
        end
    end
    rw.set_zoom(1.25)
    b.mock.frame(3)
    assert_eq(b.errors(), "", "core.log_error")
end }

return T

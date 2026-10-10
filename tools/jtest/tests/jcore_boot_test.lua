-- Headless smoke test: boots the whole JCore runtime (scripts/jcore/main.lua
-- and everything it wires) against tools/jtest/mock_core.lua, drives frames,
-- exercises the overlay UI toolkit and the asset registry, and fails on any
-- runtime error the core would have logged.
--
-- The tests in this file run in ORDER inside one Lua state: each one builds
-- on the state the previous one left behind.

local mock = require("mock_core")
mock.install()

local image = require("jcore/lib/image")

local char, rep, concat = string.char, string.rep, table.concat

-- --- fixtures -----------------------------------------------------------------

local function u16le(n) return char(n % 256, math.floor(n / 256) % 256) end
local function u32le(n)
    return char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

--- BLP2 header + palette, as in image_test.lua.
local function blp2(opts)
    local parts = {
        "BLP2",
        u32le(opts.type or 1),
        char(opts.encoding, opts.alpha_depth or 0, opts.alpha_encoding or 0, opts.has_mips or 0),
        u32le(opts.width), u32le(opts.height),
    }
    for i = 0, 15 do
        local m = opts.mips[i + 1]
        parts[#parts + 1] = u32le(m and m.offset or 0)
    end
    for i = 0, 15 do
        local m = opts.mips[i + 1]
        parts[#parts + 1] = u32le(m and m.size or 0)
    end
    local pal = {}
    for i = 0, 255 do
        local e = opts.palette and opts.palette[i]
        pal[i + 1] = e and char(e[1], e[2], e[3], e[4] or 0) or "\0\0\0\0"
    end
    parts[#parts + 1] = concat(pal)
    local header = concat(parts)
    assert(#header == 1172, "BLP2 header should be 1172 bytes, got " .. #header)
    return header .. (opts.data or "")
end

--- 4x2 palette BLP with 8-bit alpha, one mip.
local function palette_blp()
    local indices = char(0, 5, 0, 5, 5, 0, 5, 0)
    local alphas = char(10, 20, 30, 40, 50, 60, 70, 80)
    return blp2({
        encoding = 1, alpha_depth = 8, alpha_encoding = 0, has_mips = 0,
        width = 4, height = 2,
        mips = { { offset = 1172, size = 4 * 2 * 2 } },
        palette = { [0] = { 1, 2, 3, 0 }, [5] = { 40, 50, 60, 0 } },
        data = indices .. alphas,
    })
end

--- 2x2 uncompressed 32-bit TGA.
local function small_tga()
    local header = char(0, 0, 2) .. u16le(0) .. u16le(0) .. char(0)
        .. u16le(0) .. u16le(0) .. u16le(2) .. u16le(2) .. char(32, 8)
    return header .. rep(char(10, 20, 30, 255), 4)
end

local QUESTION_URL = "https://wow.zamimg.com/images/wow/icons/large/inv_misc_questionmark.jpg"
local QUESTION_PNG = image.solid_png(8, 8, 200, 100, 50, 255)

-- WoW folder: client config so the flavor probe lands, and a fake addon.
mock.wow_fs["_classic_era_/WTF/Config.wtf"] = "x"
mock.wow_fs["_classic_era_/Interface/AddOns/FakeAddon/FakeAddon.toc"] = table.concat({
    "## Interface: 11500",
    "## Title: Fake Addon",
    "## Version: 1.2.3",
    "## IconTexture: Interface\\AddOns\\FakeAddon\\icon.tga",
    "",
    "core.lua",
}, "\r\n")
mock.wow_fs["_classic_era_/Interface/AddOns/FakeAddon/core.lua"] = table.concat({
    'local BAR = "Interface\\\\AddOns\\\\FakeAddon\\\\Textures\\\\bar"',
    'local ICON = "Interface\\\\Icons\\\\Spell_Holy_FlashHeal"',
    'local MISSING = "Interface\\\\AddOns\\\\FakeAddon\\\\Textures\\\\nope"',
}, "\n")
mock.wow_fs["_classic_era_/Interface/AddOns/FakeAddon/Textures/bar.blp"] = palette_blp()
mock.wow_fs["_classic_era_/Interface/AddOns/FakeAddon/icon.tga"] = small_tga()

-- scripts_data: one image for scan_data.
mock.data_folders["icons"] = true
mock.data_fs["icons/a.png"] = image.solid_png(2, 2, 1, 2, 3, 255)
mock.data_fs["icons/notes.txt"] = "not an image"

-- The one canned download.
mock.http_responses[QUESTION_URL] = { code = 200, type = "image/png", body = QUESTION_PNG }

-- --- helpers ----------------------------------------------------------------

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
    if #mock.menu.title_errors > 0 then
        error(label .. ": menu title provider failed:\n" .. table.concat(mock.menu.title_errors, "\n"), 2)
    end
end

--- Runs frames, evaluating the menu's live titles too, then checks logs.
local function frames(n, label)
    for _ = 1, n do
        mock.frame(1)
        mock.menu:render_titles()
    end
    fail_on_errors(label or ("after " .. n .. " frame(s)"))
end

local function frames_until(limit, pred, label)
    for i = 1, limit do
        frames(1, label)
        if pred() then return i end
    end
    error(label .. ": condition not met within " .. limit .. " frames", 2)
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

--- Moves the mouse to a point, then presses and releases the left button
--- over three frames, with a settle frame before and after.
local function click_at(x, y, label)
    mock.move(x, y)
    frames(1, label)                -- hover pass sees the new position
    mock.press(0x01)
    frames(1, label)                -- press edge
    mock.release(0x01)
    frames(1, label)                -- release edge: the click lands here
    frames(1, label)
end

local function has_window(id)
    local list = _G.JCore.ui.windows()
    for i = 1, #list do
        if list[i].id == id then return list[i] end
    end
    return nil
end

local function print_warnings(label)
    if #mock.warnings > 0 then
        print("  [" .. label .. "] " .. #mock.warnings .. " warning(s):")
        for i = 1, #mock.warnings do print("    " .. mock.warnings[i]) end
    end
end

-- --- shared state ---------------------------------------------------------

local JCore
local plugin = {
    clicks = 0,
    rects = {},          -- widget id -> { x, y, w, h } from the last body run
    frames = 0,
    ctx = nil,
    legacy = nil,
    declared = nil,
    native_state = false,
    dd_bound = nil,      -- when set, "dd" is set from it before every draw
    dd_changes = {},     -- every value "dd" reported as changed
}
local WIN = "test.plugin:hud"

local T = {}

-- --- 1. boot ------------------------------------------------------------------

T[#T + 1] = { "boot: require jcore/main publishes JCore 1.8.1", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    fail_on_errors("boot")
    JCore = _G.JCore
    assert(JCore, "_G.JCore missing")
    assert(JCore == public, "require should return the published table")
    assert_eq(JCore.version, "1.7.9", "version")
    assert(JCore.ui, "JCore.ui"); assert(JCore.assets, "JCore.assets"); assert(JCore.image, "JCore.image")
    assert(#mock.callbacks.update == 1, "one native update callback")
    assert(#mock.callbacks.render == 1, "one native render callback")
    assert(#mock.callbacks.pre_tick == 1, "one native pre_tick callback")
    -- The menu host saw the diagnostics page and the UI settings page.
    assert(mock.menu.pages["JCore/Core"], "diagnostics page declared")
    assert(mock.menu.pages["JCore/UI"], "ui settings page declared")
    print_warnings("boot")
end }

-- --- 2. idle frames -------------------------------------------------------

T[#T + 1] = { "10 idle frames run clean", function()
    frames(10, "idle frames")
    local s = JCore.ui.stats()
    assert_eq(s.live, 1, "only the launcher is live while the other built-in windows are hidden")
    -- Game events route through the cache and the bus.
    mock.game_event("SPELLS_CHANGED", {})
    mock.game_event("BAG_UPDATE", { 0 })
    frames(2, "after game events")
end }

-- --- 3. plugin with every widget ------------------------------------------

local function hud_body(ui)
    plugin.frames = plugin.frames + 1
    local rects = plugin.rects
    local function rec(id)
        local x, y, w, h = ui:last_rect()
        if x then rects[id] = { x, y, w, h } end
    end

    -- Clickable widgets first, so their rects sit inside the visible body
    -- whatever the rest of the content grows to.
    if ui:button("btn", "Click me", { tooltip = "tip" }) then plugin.clicks = plugin.clicks + 1 end
    rec("btn")
    ui:tooltip("tooltip on the button")
    ui:toggle("the_toggle_id", "Toggle", false)
    rec("the_toggle_id")
    ui:checkbox("cb", "Checkbox", true)
    rec("cb")
    ui:text_input("name", "Name", "", { placeholder = "type here" })
    rec("name")
    -- Bound to a value kept outside the window while dd_bound is set, as a
    -- window mirroring a setting does: set from it before every draw, and
    -- written back only when the dropdown says changed.
    if plugin.dd_bound ~= nil then ui:set(WIN, "dd", plugin.dd_bound) end
    local dv, dchanged = ui:dropdown("dd", "Pick", { "One", "Two", "Three" }, 2)
    if dchanged then
        plugin.dd_changes[#plugin.dd_changes + 1] = dv
        if plugin.dd_bound ~= nil then plugin.dd_bound = dv end
    end
    rec("dd")
    ui:slider("sl", "Slider", 0, 100, 40, { suffix = "%" })
    rec("sl")
    ui:keybind("kb", "Keybind", 0x54)
    rec("kb")
    ui:color("col", "Colour", { 140, 120, 240, 255 })
    rec("col")
    ui:menu_toggle(plugin.ctx.menu(), "some_id", "Mirrored toggle")
    rec("menu_toggle")
    ui:native(plugin.native_checkbox, "Native")
    rec("native")
    ui:tabs("tabs", { "A", "B", "C" }, 1)
    rec("tabs")
    if ui:tree("tree", "Tree", true, { badge = "2" }) then
        ui:text("child")
        if ui:tree("tree2", "Nested", false) then ui:text("deep"); ui:end_tree() end
        ui:end_tree()
    end
    rec("tree")

    ui:heading("Heading")
    ui:text("Some body text that is long enough to wrap onto a second line inside a 300 pixel window.")
    ui:text("dim", { size = "small", color = "text_dim" })
    ui:separator("section")
    ui:spacer(4)
    ui:key_value("frame", tostring(plugin.frames))
    ui:slider("slf", "Float", 0, 1, 0.25, { step = 0.05 })
    ui:progress(0.5, { text = "50%" })
    ui:bar("Bar", 0.66, { color = "success", text = "66%" })
    ui:row(3)
    ui:badge("info", "info"); ui:badge("ok", "success"); ui:badge("dim", "dim")
    ui:end_row()
    ui:icon_button("ib", "icon:inv_misc_questionmark", { size = 24, label = "icon" })
    rec("ib")
    ui:row({ 0.5, 0.5 })
    ui:image("icon:inv_misc_questionmark", 32, 32, { align = "center", tooltip = "question" })
    ui:spell_icon(2061, 32)
    ui:end_row()
    ui:image("icon:inv_misc_questionmark", 24, 24, { fit = true })
    ui:list("list", { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }, { h = 60 })
    rec("list")
    ui:context_menu("cm", { "Copy", "Delete" })
    ui:table("tbl", { { label = "name", w = 0 }, { label = "n", w = 40, align = "right" } },
        { { "one", 1 }, { "two", 2 }, { { icon = "icon:inv_misc_questionmark", text = "three" }, 3 } },
        { h = 80, sort = true })
    if ui:group("grp", "Group", { default_open = true }) then
        ui:text("inside group")
        ui:toggle("grp_toggle", "Group toggle", true)
    end
    ui:end_group()
    ui:scroll("scr", 50)
    for i = 1, 6 do ui:text("scrolled line " .. i) end
    ui:end_scroll()
    ui:custom("cv", 30, function(c)
        c:fill(0, 0, c.w, c.h, { 30, 32, 40, 255 }, 4)
        c:rect(0, 0, c.w, c.h, "border")
        c:line(0, 0, c.w, c.h, "accent")
        c:circle(10, 10, 4, "accent")
        c:circle(20, 10, 4, "border", false)
        c:image("icon:inv_misc_questionmark", 30, 2, 20, 20)
        local mx, my = c:mouse()
        c:text(("%dx%d %s"):format(c.w, c.h, tostring(c:hovered())), 8, 6, "text_dim", "small")
        c:text_width("abc")
    end)
    ui:raw(20, function(x, y, w, h)
        core.graphics.rect_2d(JCore.ui._vec2(x, y), w, h, JCore.ui.theme.warning, 1, 3)
        core.graphics.text_2d("raw", JCore.ui._vec2(x + 4, y + 4), 12, JCore.ui.theme.text)
    end)
    ui:unit_frame(nil)
    ui:player_frame()
    ui:spell_row({ 2061, 2050 }, 24, { highlight = 2061, cooldowns = { [2050] = 0.5 } })
    ui:live(function() return "live " .. plugin.frames end)
    ui:menu_slider(plugin.ctx.menu(), "some_range", "Mirrored range", 0, 100)
    ui:menu_dropdown(plugin.ctx.menu(), "some_mode", "Mode", { "x", "y" })
    ui:menu_keybind(plugin.ctx.menu(), "some_key", "Mirrored key")
    ui:menu_text(plugin.ctx.menu(), "some_text", "Mirrored text")
    ui:menu_mirror(plugin.ctx.menu(), { "some_id", { id = "some_range", lo = 0, hi = 100 }, "some_text", "some_key", "nothing" })
    ui:native(plugin.native_slider, "Native slider", { lo = 0, hi = 10 })
    ui:native(plugin.native_combo, "Native combo")
    ui:native(plugin.native_button, "Native button")
    ui:native({}, "Unknown element")
    ui:indent(); ui:text("indented"); ui:unindent()
    ui:columns(2); ui:text("a"); ui:skip(); ui:end_row()
    ui:hovered(); ui:right_clicked(); ui:mouse()
end

T[#T + 1] = { "register a plugin that opens a window with every widget", function()
    plugin.native_checkbox = {
        state = false,
        get_state = function(self) return self.state end,
        set = function(self, v) self.state = v end,
    }
    plugin.native_slider = {
        value = 3,
        get = function(self) return self.value end,
        get_default = function() return 3 end,
        set = function(self, v) self.value = v end,
    }
    plugin.native_combo = {
        value = 1,
        get = function(self) return self.value end,
        get_items = function() return { "p", "q" } end,
        set = function(self, v) self.value = v end,
    }
    plugin.native_button = { is_clicked = function() return false end }

    local loaded = false
    plugin.ctx = JCore.register({
        id = "test.plugin", name = "Test", version = "1.0.0", kind = "plugin",
        on_load = function(ctx)
            loaded = true
            local settings = ctx.menu():section("General")
            settings:toggle("some_id", "Label", true)
            settings:slider("some_range", "Range", 0, 100, 25)
            settings:dropdown("some_mode", "Mode", { "x", "y" }, 2)
            settings:keybind("some_key", "Key", 0x42)
            settings:text_input("some_text", "Text", "hello")

            -- scroll = false: the body overflows the screen, and the wheel test
            -- below must move the slider, not the window under it.
            plugin.handle = ctx.ui:window("hud", { title = "HUD", x = 100, y = 100, w = 300, scroll = false }, hud_body)

            plugin.declared = ctx.ui:declare({
                id = "declared", title = "Declared", x = 500, y = 100, w = 260, h = 120,
                content = {
                    { kind = "heading", label = "Declared window" },
                    { kind = "text", label = "plain text" },
                    { kind = "live", fn = function() return "live" end },
                    { kind = "separator" },
                    { kind = "spacer", h = 4 },
                    { kind = "key_value", label = "k", value = function() return "v" end },
                    { kind = "badge", label = "b", tone = "warning" },
                    { kind = "button", id = "b1", label = "Button", on_click = function() end },
                    { kind = "icon_button", id = "ib1", icon = "icon:inv_misc_questionmark" },
                    { kind = "toggle", id = "t1", label = "Toggle", default = true },
                    { kind = "checkbox", id = "c1", label = "Check", default = false },
                    { kind = "slider", id = "s1", label = "Slider", min = 0, max = 10, default = 5 },
                    { kind = "dropdown", id = "d1", label = "Drop", options = { "a", "b" }, default = 1 },
                    { kind = "tabs", id = "tabs1", options = { "x", "y" }, pages = { { { kind = "text", label = "x page" } }, {} } },
                    { kind = "text_input", id = "ti1", label = "Text" },
                    { kind = "keybind", id = "k1", label = "Key", default = 0x41 },
                    { kind = "color", id = "col1", label = "Colour", default = { 1, 2, 3, 255 } },
                    { kind = "progress", label = "p", source = function() return 0.3 end },
                    { kind = "bar", label = "bar", value = 0.6 },
                    { kind = "image", ref = "icon:inv_misc_questionmark", w = 24, h = 24 },
                    { kind = "spell_icon", spell_id = 2061, size = 24 },
                    { kind = "unit_frame", unit = function() return nil end },
                    { kind = "player_frame" },
                    { kind = "group", id = "g1", label = "Group", children = { { kind = "text", label = "in group" } } },
                    { kind = "row", children = { { kind = "text", label = "l" }, { kind = "text", label = "r" } } },
                    { kind = "list", id = "l1", items = { "one", "two" }, opts = { h = 40 } },
                    { kind = "table", id = "tb1", columns = { { label = "c" } }, rows = function() return { { "r" } } end, opts = { h = 40 } },
                    { kind = "custom", id = "cv1", h = 20, paint = function(c) c:fill(0, 0, c.w, c.h, "accent") end },
                    { kind = "raw", h = 10, fn = function() end },
                    { kind = "bind", ns = ctx.menu(), widget = "some_id", label = "Bound" },
                    { kind = "native", element = plugin.native_checkbox, label = "Native" },
                    { kind = "tree", id = "tr1", label = "Tree", default = true, children = { { kind = "text", label = "leaf" } } },
                    { kind = "text", label = "hidden", visible = false },
                    { kind = "text", label = "visible fn", visible = function() return true end },
                    { kind = "bogus" },
                },
            })

            local legacy = ctx.ui:legacy_menu("Legacy", 300, 400, "legacy_test")
            plugin.legacy = legacy
            legacy.handle.set({ x = 900, y = 600 })
            legacy:add_label("A label", 0, 0)
            legacy:add_header("Header", 0, 0)
            legacy:add_separator(0, 0)
            plugin.legacy_cb = legacy:add_checkbox("Check", 0, 0, true, function() end)
            legacy:add_slider("Slide", 0, 0, 0, 10, 4, function() end)
            legacy:add_slider("Float", 0, 0, 0, 1, 0.5, nil, { slider_type = "float" })
            legacy:add_button("Press", 0, 0, 100, 20, function() plugin.legacy_clicked = true end)
            legacy:add_combobox("Combo", 0, 0, { "a", "b", "c" }, 2, function() end)
            legacy:add_keybind("Key", 0, 0, 0x41, function() end)
            legacy:add_colorpicker("Colour", 0, 0, { r = 1, g = 2, b = 3, a = 255 }, function() end)
            local node = legacy:add_treenode("Node", 0, 0, true, function() end)
            node:add_child(legacy:add_label("Child", 0, 0))
            legacy:add_listbox("List", 0, 0, { "x", "y" }, 1, function() end)
            legacy:add_textinput("Input", 0, 0, "abc", function() end)
            legacy:add_progressbar("Progress", 0, 0, 30, 100)
            legacy:update(); legacy:render()
        end,
        on_unload = function() plugin.unloaded = true end,
    })
    assert(loaded, "on_load ran synchronously")
    fail_on_errors("register")
    assert(JCore.is_running("test.plugin"), "plugin running")
    assert_eq(plugin.ctx.menu():get("some_id"), true, "menu default readable through the slice")
end }

-- --- 4. frames with the window ------------------------------------------

T[#T + 1] = { "30 frames with the window paint and stay clean", function()
    frames(30, "window frames")
    assert(plugin.frames >= 30, "body ran every frame, got " .. plugin.frames)
    assert((mock.frame_counts.rect_2d_filled or 0) > 0, "rect_2d_filled painted this frame")
    assert((mock.frame_counts.text_2d or 0) > 0, "text_2d painted this frame")
    assert((mock.frame_counts.scissor_push or 0) > 0, "scissor_push used")
    assert_eq(mock.frame_counts.scissor_push, mock.frame_counts.scissor_pop, "scissor push/pop balanced")
    local win = has_window(WIN)
    assert(win, "hud window listed")
    assert_eq(win.x, 100, "window x"); assert_eq(win.y, 100, "window y"); assert_eq(win.w, 300, "window w")
    assert(win.live, "window live")
    assert(has_window("test.plugin:declared"), "declared window listed")
    assert(has_window("test.plugin:legacy:legacy_test"), "legacy window listed")
    assert(plugin.legacy:is_mouse_over() == false, "legacy is_mouse_over")
    assert_eq(plugin.legacy_cb:get_value(), true, "legacy checkbox value")
    assert_eq(JCore.ui.stats().live, 4, "three plugin windows plus the launcher")
    print_warnings("window frames")
end }

-- --- 5. interaction ----------------------------------------------------------

T[#T + 1] = { "drag the window by its title bar", function()
    mock.move(200, 110)
    frames(1, "drag hover")
    mock.press(0x01)
    frames(1, "drag press")
    mock.move(230, 125)
    frames(1, "drag move 1")
    mock.move(250, 140)
    frames(1, "drag move 2")
    mock.release(0x01)
    frames(2, "drag release")
    local win = has_window(WIN)
    assert_eq(win.x, 150, "window x after drag")
    assert_eq(win.y, 130, "window y after drag")
    assert(mock.mouse_captured == true, "mouse captured while over the window")
    mock.move(5, 5)
    frames(2, "leave window")
    assert(mock.mouse_captured == false, "capture released once the cursor leaves")
end }

T[#T + 1] = { "a cursor the client cannot report (-FLT_MAX) leaves a dragged window where it is", function()
    -- The client answers {x=-3.403e+38, y=-3.403e+38} on a frame it has no
    -- cursor for (seen in the recorder). Taken as a position, the window
    -- being dragged was thrown to the top-left corner for that frame and
    -- jumped back under the cursor on the next.
    frames(30, "double-click guard")      -- the last test's press was on this title bar
    mock.move(250, 140)
    frames(1, "hover the title")
    mock.press(0x01)
    frames(1, "press")
    mock.move(270, 150)
    frames(1, "move")
    local win = has_window(WIN)
    assert_eq(win.x, 170, "x while dragging"); assert_eq(win.y, 140, "y while dragging")
    mock.move(-3.4028234663852886e38, -3.4028234663852886e38)
    frames(2, "no cursor")
    win = has_window(WIN)
    assert_eq(win.x, 170, "x on a frame with no cursor"); assert_eq(win.y, 140, "y on a frame with no cursor")
    assert(mock.mouse_captured == true, "still captured on a frame with no cursor")
    -- Something else let the mouse go mid-drag: taken back on the next frame.
    mock.mouse_captured = false
    frames(1, "capture lost")
    assert(mock.mouse_captured == true, "capture taken back while dragging")
    mock.move(250, 140)
    frames(1, "cursor back")
    mock.release(0x01)
    frames(2, "release")
    win = has_window(WIN)
    assert_eq(win.x, 150, "x after the drag"); assert_eq(win.y, 130, "y after the drag")
    mock.move(5, 5)
    frames(2, "leave window")
end }

T[#T + 1] = { "\"Capture the mouse over windows\" off: the title bar and a drag still take the mouse, the body does not", function()
    -- In the game the setting was off, so every drag reached the client: it
    -- turned the camera, hid the cursor and re-centred it, and the window
    -- snapped back with it (1.12.0).
    local settings = JCore.ui.settings
    settings.capture_mouse = false
    frames(30, "double-click guard")
    mock.move(250, 300)
    frames(2, "over the body")
    assert(mock.mouse_captured == false, "the body lets clicks through with the setting off")
    mock.move(250, 140)
    frames(2, "over the title bar")
    assert(mock.mouse_captured == true, "the title bar takes the mouse whatever the setting")
    mock.press(0x01)
    frames(1, "press")
    mock.move(270, 300)                    -- the cursor runs ahead of the bar, onto the body
    frames(1, "drag")
    assert(mock.mouse_captured == true, "captured through the drag")
    local win = has_window(WIN)
    assert_eq(win.x, 170, "x while dragging"); assert_eq(win.y, 290, "y while dragging")
    mock.move(250, 140)
    frames(1, "drag back")
    mock.release(0x01)
    frames(2, "release")
    win = has_window(WIN)
    assert_eq(win.x, 150, "x after the drag"); assert_eq(win.y, 130, "y after the drag")
    mock.move(5, 5)
    frames(2, "leave window")
    assert(mock.mouse_captured == false, "released once the cursor leaves")
    settings.capture_mouse = true
end }

T[#T + 1] = { "click the toggle flips its value", function()
    frames(30, "double-click guard")      -- outlast the double-click window
    local r = plugin.rects.the_toggle_id
    assert(r, "toggle rect recorded")
    assert_eq(JCore.ui.get_value(WIN, "the_toggle_id"), false, "toggle starts off")
    click_at(r[1] + r[3] / 2, r[2] + r[4] / 2, "toggle click")
    assert_eq(JCore.ui.get_value(WIN, "the_toggle_id"), true, "toggle flipped on")
    click_at(r[1] + 20, r[2] + 4, "toggle second click")
    assert_eq(JCore.ui.get_value(WIN, "the_toggle_id"), false, "toggle flipped back")
    assert_eq(plugin.handle.get("the_toggle_id"), false, "handle.get reads the same value")
end }

T[#T + 1] = { "click the button counts a click", function()
    frames(30, "double-click guard")
    local r = plugin.rects.btn
    local before = plugin.clicks
    click_at(r[1] + 10, r[2] + r[4] / 2, "button click")
    assert_eq(plugin.clicks, before + 1, "button clicked once")
end }

T[#T + 1] = { "typing into the text input", function()
    frames(30, "double-click guard")
    local r = plugin.rects.name
    click_at(r[1] + 10, r[2] + r[4] / 2, "focus text input")
    assert(JCore.ui.stats().focus, "a field has focus")
    assert(mock.keyboard_captured == true, "keyboard captured while typing")
    mock.press(0x41)
    frames(1, "type a")
    mock.release(0x41)
    frames(1, "after typing")
    local v = JCore.ui.get_value(WIN, "name")
    assert(type(v) == "string" and v:find("a", 1, true), "text input holds 'a', got " .. tostring(v))
    mock.press(0x10); mock.press(0x42)
    frames(1, "type B")
    mock.release(0x10); mock.release(0x42)
    frames(1)
    assert_eq(JCore.ui.get_value(WIN, "name"), "aB", "shifted letter")
    mock.press(0x08)
    frames(1, "backspace")
    mock.release(0x08)
    frames(1)
    assert_eq(JCore.ui.get_value(WIN, "name"), "a", "backspace removed a character")
    mock.press(0x0D)
    frames(1, "enter")
    mock.release(0x0D)
    frames(1)
    assert(JCore.ui.stats().focus == nil, "enter drops focus")
    assert(mock.keyboard_captured == false, "keyboard released")
end }

T[#T + 1] = { "code box: click places the caret, Enter keeps the indent, the arrows walk lines, Backspace joins them (1.8.7)", function()
    frames(30, "double-click guard")
    local seen = { changed = 0 }
    plugin.code_handle = plugin.ctx.ui:window("code", { title = "Code", x = 700, y = 300, w = 320, scroll = false },
        function(ui)
            local text, changed, focused = ui:code("src", "  local a = 1", { rows = 5, words = { me = true },
                error_line = seen.error_line, error = seen.error })
            seen.text, seen.focused = text, focused
            if changed then seen.changed = seen.changed + 1 end
            local x, y, w, h = ui:last_rect()
            seen.rect = { x, y, w, h }
        end)
    frames(3, "code window")
    local r = seen.rect
    assert(r and r[3] > 100 and r[4] > 40, "the box has a size")
    local WID = "test.plugin:code"
    local function key(vk, label)
        mock.press(vk)
        frames(1, label)
        mock.release(vk)
        frames(1, label)
    end
    -- Far right of the first line: the caret goes to its end.
    click_at(r[1] + r[3] - 12, r[2] + 8, "focus the code box")
    assert(seen.focused == true, "the box has the keyboard")
    assert(mock.keyboard_captured == true, "keyboard captured")
    key(0x0D, "enter")
    assert_eq(JCore.ui.get_value(WID, "src"), "  local a = 1\n  ", "Enter breaks the line and keeps the indent")
    key(0x42, "type b")
    assert_eq(JCore.ui.get_value(WID, "src"), "  local a = 1\n  b", "typed on the new line")
    key(0x26, "up")
    key(0x43, "type c")
    assert_eq(JCore.ui.get_value(WID, "src"), "  lcocal a = 1\n  b", "Up keeps the column (3) on the line above")
    key(0x28, "down")
    key(0x24, "home")
    key(0x08, "backspace at the start of a line")
    assert_eq(JCore.ui.get_value(WID, "src"), "  lcocal a = 1  b", "Backspace at column 0 joins the line above")
    key(0x09, "tab")
    assert(JCore.ui.get_value(WID, "src"):find("1      b", 1, true), "Tab puts in four spaces")
    assert(seen.changed >= 5, "every edit says changed")
    seen.error_line, seen.error = 1, "boom"
    frames(2, "error line painted")
    key(0x1B, "escape")
    assert(seen.focused == false, "Escape gives the keyboard back")
    assert(mock.keyboard_captured == false, "keyboard released")
    plugin.code_handle.remove()
    frames(2, "code window removed")
end }

T[#T + 1] = { "scroll region: fills the window by ui:avail, the wheel goes to a code box inside first, the bar drags (1.8.9)", function()
    frames(30, "double-click guard")
    local seen = {}
    local h = plugin.ctx.ui:window("scrolly", { title = "Scrolly", x = 300, y = 200, w = 300, h = 260, resizable = true,
        min_w = 200, min_h = 150, scroll = false }, function(ui)
        local x, y, w, left = ui:avail()
        seen.avail = { x, y, w, left }
        seen.gap = ui:metrics().gap
        ui:scroll("body", left)
        ui:code("src", ("line\n"):rep(30), { rows = 3 })
        local cx, cy, cw, ch = ui:last_rect()
        seen.code = { cx, cy, cw, ch }
        for i = 1, 40 do ui:text("row " .. i) end
        ui:end_scroll()
    end)
    frames(3, "scrolly window")
    local win = JCore.ui._windows["test.plugin:scrolly"]
    local S = JCore.ui._S
    local region = S["test.plugin:scrolly/body"]
    local code = S["test.plugin:scrolly/body/src"]
    local a = seen.avail
    assert(math.abs(a[2] + a[4] - (win.body[2] + win.body[4] - win.pad)) < 0.01, "avail reaches the body's bottom")
    assert((region.content_h or 0) > a[4], "the region overflows")
    assert_eq(win.content_h <= win.body[4], true, "the window itself does not overflow")

    -- The wheel over the code box scrolls the box, not the region.
    local c = seen.code
    mock.move(c[1] + c[3] / 2, c[2] + c[4] / 2)
    frames(1)
    mock.wheel = -1
    frames(1, "wheel over the code box")
    mock.wheel = 0
    frames(1)
    assert((code.sy or 0) > 0, "the code box scrolled")
    assert_eq(region.scroll, 0, "the region did not")

    -- Over plain text the region scrolls.
    mock.move(a[1] + 40, a[2] + a[4] - 20)
    frames(1)
    mock.wheel = -1
    frames(1, "wheel over the rows")
    mock.wheel = 0
    frames(1)
    assert(region.scroll > 0, "the region scrolled")

    -- Drag the bar past the bottom: the end of the content.
    local bar_x = a[1] + a[3] - 3
    mock.move(bar_x, a[2] + 4)
    frames(1)
    mock.press(0x01)
    frames(1, "press on the bar")
    mock.move(bar_x, a[2] + a[4] + 300)
    frames(2, "drag the bar")
    mock.release(0x01)
    frames(2)
    local max_scroll = region.content_h - a[4]
    assert(math.abs(region.scroll - max_scroll) < 0.5, "dragged to the end: " .. region.scroll .. " of " .. max_scroll)
    -- A press high on the track jumps back up.
    click_at(bar_x, a[2] + 6, "press on the track")
    assert(region.scroll < max_scroll * 0.25, "the track press jumped up: " .. region.scroll)

    -- A size bigger than the screen comes back inside it.
    win.w, win.h = 5000, 5000
    frames(2, "oversized")
    local sw, sh = JCore.ui.frame.sw, JCore.ui.frame.sh
    assert(win.w <= sw and win.h <= sh, "kept within the screen: " .. win.w .. "x" .. win.h)
    h.remove()
    mock.move(5, 5)
    frames(2, "scrolly window removed")
end }

T[#T + 1] = { "a window's own scale: its widgets, its dropdown list and its tooltip, and the global scale after it (1.8.10)", function()
    frames(30, "double-click guard")
    local seen = {}
    local function body(key)
        return function(ui)
            seen[key .. "_metrics"] = ui:metrics()
            ui:button("b", "Button", { tooltip = "tip" })
            local x, y, w, h = ui:last_rect()
            seen[key .. "_button"] = { x, y, w, h }
            ui:dropdown("dd", nil, { "one", "two", "three" }, 1)
            local dx, dy, dw, dh = ui:last_rect()
            seen[key .. "_dd"] = { dx, dy, dw, dh }
        end
    end
    local big = plugin.ctx.ui:window("big", { title = "Big", x = 300, y = 300, w = 260, scale = 1.5 }, body("big"))
    local plain = plugin.ctx.ui:window("plain", { title = "Plain", x = 700, y = 300, w = 260 }, body("plain"))
    frames(3, "scaled windows")
    local T0 = JCore.ui:metrics()
    assert_eq(seen.big_metrics.scale, 1.5, "the scale inside the window")
    assert_eq(seen.plain_metrics.scale, 1, "a window without one keeps the global scale")
    assert_eq(T0.scale, 1, "the global scale is back after the windows")
    assert_eq(seen.big_button[4], math.floor(seen.plain_button[4] * 1.5 + 0.5), "a widget 1.5 times as tall")
    assert_eq(seen.big_metrics.font_body, math.floor(seen.plain_metrics.font_body * 1.5 + 0.5), "its text 1.5 times as big")
    -- The tooltip of a widget in the big window is painted at its scale.
    local b = seen.big_button
    mock.move(b[1] + 10, b[2] + b[4] / 2)
    frames(2, "hover the big button")
    local P = JCore.ui._P
    assert(P.tooltip and P.tooltip.scale == 1.5, "the tooltip carries the window's scale")
    -- Its dropdown list opens at its scale too.
    local d = seen.big_dd
    click_at(d[1] + 10, d[2] + d[4] / 2, "open the big dropdown")
    assert(P.popup and P.popup.scale == 1.5, "the list carries the window's scale")
    click_at(5, 5, "close the list")
    assert_eq(JCore.ui:metrics().scale, 1, "the global scale after the popup")
    big.remove()
    plain.remove()
    frames(2, "scaled windows removed")
end }

T[#T + 1] = { "dropdown opens a popup and closes on an outside click", function()
    frames(30, "double-click guard")
    local r = plugin.rects.dd
    local uid = WIN .. "/dd"
    click_at(r[1] + 10, r[2] + r[4] / 2, "open dropdown")
    assert(JCore.ui.is_popup_open(uid), "popup open after click")
    assert(JCore.ui.stats().popups == 1, "popup painted")
    -- Pick the third item: the popup starts 2px under the field, items are
    -- widget_h tall from 4px in.
    local item_h = JCore.ui._T.widget_h
    local px, py = r[1] + 10, r[2] + r[4] + 2 + 4 + item_h * 2 + item_h / 2
    click_at(px, py, "pick item")
    assert(not JCore.ui.is_popup_open(uid), "popup closed after picking")
    assert_eq(JCore.ui.get_value(WIN, "dd"), 3, "third item selected")
    click_at(r[1] + 10, r[2] + r[4] / 2, "reopen dropdown")
    assert(JCore.ui.is_popup_open(uid), "popup open again")
    click_at(5, 5, "click outside")
    assert(not JCore.ui.is_popup_open(uid), "popup closed by an outside click")
end }

T[#T + 1] = { "dropdown: a pick from the list is reported changed, even when the caller sets the value every frame (1.8.1)", function()
    frames(30, "double-click guard")
    local r = plugin.rects.dd
    local item_h = JCore.ui._T.widget_h
    -- The test before picked the third row on its own.
    assert_eq(plugin.dd_changes[#plugin.dd_changes], 3, "a plain pick is reported as changed")
    plugin.dd_bound, plugin.dd_changes = 1, {}
    frames(2, "bound")
    assert_eq(JCore.ui.get_value(WIN, "dd"), 1, "the window shows the bound value")
    click_at(r[1] + 10, r[2] + r[4] / 2, "open bound dropdown")
    click_at(r[1] + 10, r[2] + r[4] + 2 + 4 + item_h * 1 + item_h / 2, "pick the second row")
    frames(3, "after the pick")
    assert_eq(plugin.dd_changes[1], 2, "the pick came back as changed")
    assert_eq(plugin.dd_bound, 2, "so the caller wrote it")
    assert_eq(JCore.ui.get_value(WIN, "dd"), 2, "and it stuck")
    assert_eq(#plugin.dd_changes, 1, "reported once")
    plugin.dd_bound = nil
end }

T[#T + 1] = { "slider drag, wheel and right-click reset", function()
    frames(30, "double-click guard")
    local r = plugin.rects.sl
    assert_eq(JCore.ui.get_value(WIN, "sl"), 40, "slider default")
    mock.move(r[1] + r[3] / 2, r[2] + r[4] / 2)
    frames(1)
    mock.press(0x01)
    frames(1, "slider press")
    mock.move(r[1] + r[3], r[2] + r[4] / 2)
    frames(1, "slider drag")
    mock.release(0x01)
    frames(1)
    assert_eq(JCore.ui.get_value(WIN, "sl"), 100, "dragged to the end")
    mock.move(r[1] + r[3] / 2, r[2] + r[4] / 2)
    frames(1)
    mock.wheel = -1
    frames(1, "wheel")
    assert_eq(JCore.ui.get_value(WIN, "sl"), 99, "wheel stepped down")
    mock.press(0x02)
    frames(1, "right click")
    mock.release(0x02)
    frames(1)
    assert_eq(JCore.ui.get_value(WIN, "sl"), 40, "right click resets to the default")

    -- The declared window overflows its 120px: the wheel scrolls its body.
    local dw = JCore.ui._windows["test.plugin:declared"]
    assert(dw and dw.max_scroll > 0, "declared window overflows")
    mock.move(dw.x + 100, dw.y + 60)
    frames(1)
    mock.wheel = -1
    frames(1, "window wheel")
    assert(dw.scroll_y > 0, "window scrolled")
    mock.move(5, 5)
    frames(1)
end }

T[#T + 1] = { "colour picker popup and keybind capture", function()
    frames(30, "double-click guard")
    local r = plugin.rects.col
    click_at(r[1] + r[3] / 2, r[2] + r[4] / 2, "open colour picker")
    assert(JCore.ui.is_popup_open(WIN .. "/col"), "colour popup open")
    frames(3, "colour popup frames")
    click_at(5, 5, "close colour popup")
    assert(not JCore.ui.is_popup_open(WIN .. "/col"), "colour popup closed")

    local k = plugin.rects.kb
    click_at(k[1] + k[3] / 2, k[2] + k[4] / 2, "start listening")
    assert(JCore.ui.stats().captured ~= nil, "stats readable")
    mock.time = mock.time + 0.5          -- past the 0.15s guard
    mock.press(0x47)                     -- 'G'
    frames(2, "capture key")
    mock.release(0x47)
    frames(1)
    assert_eq(JCore.ui.get_value(WIN, "kb"), 0x47, "keybind captured G")
end }

T[#T + 1] = { "menu mirror and native element write back", function()
    frames(30, "double-click guard")
    local r = plugin.rects.menu_toggle
    assert_eq(plugin.ctx.menu():get("some_id"), true, "menu value before")
    click_at(r[1] + 10, r[2] + r[4] / 2, "mirrored toggle click")
    assert_eq(plugin.ctx.menu():get("some_id"), false, "menu value written through the mirror")
    mock.menu:set("JCore/Test", "some_id", true)
    frames(2, "menu changed underneath")
    click_at(r[1] + 10, r[2] + r[4] / 2, "mirrored toggle click 2")
    assert_eq(plugin.ctx.menu():get("some_id"), false, "second write through")

    frames(30, "double-click guard")
    local n = plugin.rects.native
    click_at(n[1] + 10, n[2] + n[4] / 2, "native toggle click")
    assert_eq(plugin.native_checkbox.state, true, "native element set")
end }

T[#T + 1] = { "tabs, tree, list, context menu and table header clicks", function()
    frames(30, "double-click guard")
    -- tabs: last_rect is the whole strip; three equal tabs, so tab 2 is
    -- the middle third.
    local t = plugin.rects.tabs
    click_at(t[1] + t[3] / 2, t[2] + t[4] / 2, "tab 2")
    assert_eq(JCore.ui.get_value(WIN, "tabs"), 2, "second tab selected")

    -- tree: the rect recorded after end_tree is the nested node's header.
    local n = plugin.rects.tree
    assert_eq(JCore.ui.get_value(WIN, "tree2"), false, "nested node closed")
    click_at(n[1] + 30, n[2] + n[4] / 2, "open nested tree")
    assert_eq(JCore.ui.get_value(WIN, "tree2"), true, "nested node opened")
    frames(30, "double-click guard")
    click_at(n[1] + 30, n[2] + n[4] / 2, "close nested tree")
    assert_eq(JCore.ui.get_value(WIN, "tree2"), false, "nested node closed again")

    -- Everything below the fold is unreachable in the HUD (scroll = false),
    -- so the list, context menu and table run on a small window of their own.
    local picked, sel_row, header_clicks = nil, nil, 0
    local lrects = {}
    local h = plugin.ctx.ui:window("lists", { title = "Lists", x = 900, y = 100, w = 260 }, function(ui)
        local _, clicked = ui:list("l", { "alpha", "beta", "gamma" }, { h = 80 })
        if clicked then sel_row = clicked end
        local x, y, w, hh = ui:last_rect()
        lrects.list = { x, y, w, hh }
        local c = ui:context_menu("cm", { "Copy", "Delete" })
        if c then picked = c end
        ui:table("tb", { { label = "a", w = 0 }, { label = "b", w = 60 } }, { { "z", 2 }, { "y", 1 } }, { h = 70, sort = true })
        x, y, w, hh = ui:last_rect()
        lrects.table = { x, y, w, hh }
    end)
    frames(3, "lists window")
    local L = lrects.list
    click_at(L[1] + 20, L[2] + 2 + 22 + 11, "click row 2")
    assert_eq(sel_row, 2, "second row clicked")
    assert_eq(JCore.ui.get_value("test.plugin:lists", "l"), 2, "list selection stored")

    -- Right-click on the list opens its context menu; pick "Delete".
    mock.move(L[1] + 20, L[2] + 10)
    frames(1)
    mock.press(0x02)
    frames(1, "right press")
    mock.release(0x02)
    frames(1, "right release")
    assert(JCore.ui.is_popup_open("test.plugin:lists/cm"), "context menu open")
    local pr = JCore.ui._P.popup_rect
    click_at(pr[1] + 20, pr[2] + 4 + 22 + 11, "pick delete")
    assert_eq(picked, 2, "context item chosen")
    assert(not JCore.ui.is_popup_open("test.plugin:lists/cm"), "context menu closed")

    -- Sortable header: click column b twice (ascending then descending).
    frames(30, "double-click guard")
    local Tb = lrects.table
    click_at(Tb[1] + Tb[3] - 30, Tb[2] + 12, "sort by b")
    local st = JCore.ui._S["test.plugin:lists/tb"]
    assert(st and st.sort_col == 2 and st.sort_desc == false, "sorted ascending by column 2")
    frames(30, "double-click guard")
    click_at(Tb[1] + Tb[3] - 30, Tb[2] + 12, "sort by b again")
    assert(st.sort_desc == true, "sorted descending")
    h.remove()
    frames(3, "lists window removed")     -- windows stay "live" for two frames after their last description
    assert(has_window("test.plugin:lists") == nil or not has_window("test.plugin:lists").live, "lists window no longer live")

    -- A button in a second retained window, created after the first, clicks
    -- too (z-order picks the right hover owner).
    frames(30, "double-click guard")
    local probe_rects = {}
    local probe = plugin.ctx.ui:window("probe", { title = "Probe", x = 900, y = 100, w = 200 }, function(ui)
        if ui:button("pb", "Probe") then probe_rects.clicked = true end
        local x, y, w, hh = ui:last_rect()
        probe_rects.btn = { x, y, w, hh }
    end)
    frames(3)
    local pb = probe_rects.btn
    click_at(pb[1] + 10, pb[2] + pb[4] / 2, "probe button")
    assert(probe_rects.clicked, "button inside a second retained window clicks")
    probe.remove()
    frames(2)

    -- The legacy window's checkbox component reflects a value set from code.
    plugin.legacy_cb:set_value(false)
    frames(2, "legacy set_value")
    assert_eq(JCore.ui.get_value("test.plugin:legacy:legacy_test", plugin.legacy_cb.id), false, "legacy set_value reached the widget")
    assert_eq(plugin.legacy_cb:is_checked(), false, "legacy is_checked")
end }

T[#T + 1] = { "window handle show/hide/collapse and reset_layout", function()
    plugin.handle.hide()
    frames(3, "hidden")
    assert(not plugin.handle.is_visible(), "hidden")
    assert_eq(has_window(WIN).visible, false, "listed as hidden")
    plugin.handle.show()
    frames(3, "shown")
    assert(plugin.handle.is_visible(), "shown again")
    plugin.handle.toggle(); frames(1); plugin.handle.toggle(); frames(1)
    JCore.ui:set_collapsed(WIN, true)
    frames(3, "collapsed")
    assert_eq(has_window(WIN).collapsed, true, "collapsed")
    JCore.ui:set_collapsed(WIN, false)
    frames(3, "expanded")
    JCore.ui:set_position(WIN, 120, 90)
    frames(1)
    assert_eq(has_window(WIN).x, 120, "set_position")
    JCore.ui.reset_layout()
    frames(3, "reset layout")
    assert_eq(has_window(WIN).x, 100, "reset to the anchored x")
    JCore.ui.set_scale(1.25); frames(3, "scaled")
    JCore.ui.set_scale(1.0); JCore.ui.set_opacity(0.8); frames(3, "opacity")
    JCore.ui.set_opacity(1.0)
    plugin.legacy:collapse(); frames(2); plugin.legacy:expand(); frames(2)
    plugin.legacy:hide(); frames(2); plugin.legacy:show(); frames(2, "legacy show")
    plugin.declared.set_content({ { kind = "text", label = "swapped" } })
    frames(2, "swapped content")
end }

-- --- 6. assets --------------------------------------------------------------

T[#T + 1] = { "assets: icon downloads through http and becomes ready", function()
    local ready, e = JCore.assets.request("icon:inv_misc_questionmark")
    if not ready then
        frames_until(10, function() return JCore.assets.is_ready("icon:inv_misc_questionmark") end, "icon load")
    end
    e = JCore.assets.get("icon:inv_misc_questionmark")
    assert_eq(e.state, "ready", "icon state")
    assert_eq(e.w, 8, "icon width from the png header")
    local found = false
    for i = 1, #mock.http_log do
        if mock.http_log[i] == QUESTION_URL then found = true end
    end
    assert(found, "icon url requested")
    local cached = false
    for path in pairs(mock.data_fs) do
        if path:match("^jcore/assets/.*%.jpg$") then cached = true end
    end
    assert(cached, "download cached under scripts_data/jcore/assets")
    -- The spell icon had no resolver and no tooltip endpoint: failed for good.
    local spell = JCore.assets.get("spell:2061")
    assert(spell and spell.state == "failed" and spell.dead, "spell icon failed permanently without a resolver")
    assert((mock.counts.draw_texture or 0) > 0, "textures drawn")
    print_warnings("assets")
end }

T[#T + 1] = { "assets: scan_addon finds the fake addon's textures and icons", function()
    local result, err
    local ok = JCore.assets.scan_addon("FakeAddon", { force = true }, function(r, e) result, err = r, e end)
    assert(ok, "scan accepted")
    frames_until(200, function() return result ~= nil or err ~= nil end, "addon scan")
    assert(result, "scan result: " .. tostring(err))
    local refs = {}
    for i = 1, #result.entries do refs[result.entries[i].ref] = true end
    assert(refs["addon:FakeAddon/Textures/bar.blp"], "bar.blp found")
    assert(refs["icon:spell_holy_flashheal"], "game icon found")
    assert(refs["addon:FakeAddon/icon.tga"], "icon.tga found")
    assert(not refs["addon:FakeAddon/Textures/nope.blp"], "missing texture not listed")
    assert_eq(result.icon, "addon:FakeAddon/icon.tga", "addon icon")
    assert_eq(result.title, "Fake Addon", "toc title")
    assert_eq(result.files, 1, "one source file scanned")
    assert(JCore.assets.addon_catalog("FakeAddon"), "catalog stored")
    local cat = JCore.assets.catalog({ source = "FakeAddon" })
    assert_eq(#cat, 3, "catalog entries for the addon")
    assert(#JCore.assets.catalog({ text = "flashheal" }) == 1, "text filter")
    assert(JCore.assets.sources()[1], "sources listed")

    local missing_cb
    assert(JCore.assets.scan_addon("NotInstalled", {}, function(_, e) missing_cb = e end) == false, "uninstalled refused")
    assert(missing_cb and missing_cb:find("not installed"), "callback told why")
end }

T[#T + 1] = { "assets: a BLP is converted to PNG before upload", function()
    local before = #mock.textures
    JCore.assets.request("addon:FakeAddon/Textures/bar.blp")
    frames_until(20, function() return JCore.assets.is_ready("addon:FakeAddon/Textures/bar.blp") end, "blp load")
    local e = JCore.assets.get("addon:FakeAddon/Textures/bar.blp")
    assert_eq(e.w, 4, "blp width"); assert_eq(e.h, 2, "blp height")
    assert(#mock.textures == before + 1, "one texture uploaded")
    assert_eq(mock.last_texture.kind, "png", "uploaded bytes are png")
    local w, h = jtest.png_decode(mock.last_texture.bytes)
    assert_eq(w, 4, "decoded width"); assert_eq(h, 2, "decoded height")
    assert(JCore.assets.stats().converted >= 1, "conversion counted")

    -- The addon's TGA icon goes up as-is (the loader reads TGA natively).
    JCore.assets.request("addon:FakeAddon/icon.tga")
    frames_until(20, function() return JCore.assets.is_ready("addon:FakeAddon/icon.tga") end, "tga load")
    assert_eq(mock.last_texture.kind, "tga", "tga passed through")

    -- Addon path spelled the way addons spell it, without an extension.
    JCore.assets.request("Interface\\AddOns\\FakeAddon\\Textures\\bar")
    frames_until(20, function() return JCore.assets.is_ready("addon:FakeAddon/Textures/bar") end, "extensionless load")
    local e2 = JCore.assets.get("addon:FakeAddon/Textures/bar")
    assert_eq(e2.resolved_path, "_classic_era_/Interface/AddOns/FakeAddon/Textures/bar.blp", "probed .blp")

    -- A reference to nothing fails permanently and is reported.
    JCore.assets.request("addon:FakeAddon/nothing.png")
    frames(5, "missing asset")
    local m = JCore.assets.get("addon:FakeAddon/nothing.png")
    assert(m.state == "failed" and m.dead, "missing addon file fails for good")
end }

T[#T + 1] = { "assets: scan_data lists images under scripts_data", function()
    local result
    JCore.assets.scan_data("icons", { force = true }, function(r) result = r end)
    frames_until(50, function() return result ~= nil end, "data scan")
    assert_eq(#result.entries, 1, "one image found")
    assert_eq(result.entries[1].ref, "data:icons/a.png", "data ref")
    JCore.assets.request("data:icons/a.png")
    frames_until(20, function() return JCore.assets.is_ready("data:icons/a.png") end, "data load")
    assert_eq(JCore.assets.get("data:icons/a.png").w, 2, "data image width")

    -- Registered refs, atlases and plugin textures.
    assert(JCore.assets.register("icon:inv_misc_questionmark", { label = "Question" }), "register")
    assert(JCore.assets.register_texture("mine", 999, 16, 16), "register_texture")
    assert(JCore.assets.is_ready("tex:mine"), "tex ready")
    JCore.assets.atlas("sheet", "icon:inv_misc_questionmark", { cols = 2, rows = 2 })
    local ok, cell = JCore.assets.request("atlas:sheet/3")
    assert(ok and cell.uv and cell.uv[1] == 0 and cell.uv[2] == 0.5, "atlas cell uv")
    assert(JCore.assets.submit("atlas:sheet/3", { x = 1, y = 1 }, 8, 8), "atlas submit")
    frames(2, "atlas draw")
    assert((mock.counts.draw_texture_rect or 0) > 0, "atlas drawn with uvs")
    assert(JCore.assets.parse("spell:0") == nil, "spell:0 rejected")
    assert_eq(JCore.assets.parse("Interface/Icons/INV_Misc_QuestionMark.blp").key, "icon:inv_misc_questionmark", "icon path parse")
    assert_eq(JCore.assets.parse("bare_token").key, "icon:bare_token", "bare token parse")
    JCore.assets.forget("data:icons/a.png")
    assert(JCore.assets.get("data:icons/a.png").state == "idle", "forgotten entry recreated idle")
    local s = JCore.assets.stats()
    assert(s.scans >= 2 and s.ready >= 4, "stats sane")
    assert(#JCore.assets.entries() >= 5, "entries listed")
    print_warnings("scan_data")
end }

-- --- 7. unregister ----------------------------------------------------------

T[#T + 1] = { "assets: a game: reference is pulled out of the client's archives", function()
    -- A synthetic CASC store beside the fake addon: .build.info, config,
    -- indices, archives, encoding and root, with one PNG inside.
    local fixture = require("casc_fixture")
    fixture.build_store(JCore.casc, mock.wow_fs)
    assert(JCore.casc.available(), "the store is readable: " .. tostring(select(2, JCore.casc.available())))

    local ref = "game:" .. fixture.TARGET
    assert(not JCore.assets.request(ref), "not ready on the first ask")
    frames_until(400, function() return JCore.assets.is_ready(ref) end, "game asset loads")
    local e = JCore.assets.get(ref)
    assert(e.tex, "texture uploaded")
    assert_eq(e.w, 8, "width from the PNG")
    assert_eq(mock.last_texture.bytes, fixture.TARGET_BYTES, "the bytes that reached the loader are the file's")

    local s = JCore.casc.stats()
    assert_eq(s.scans, 1, "one root scan")
    assert_eq(s.reads, 1, "one archive read")
    assert(s.build, "build version known")

    local cached = 0
    for path in pairs(mock.data_fs) do
        if path:lower():find("jcore/game/", 1, true) then cached = cached + 1 end
    end
    assert_eq(cached, 1, "extracted bytes kept under scripts_data")

    -- Asked again in a fresh registry entry: served from scripts_data, no
    -- archive read.
    JCore.assets.forget(ref)
    assert(not JCore.assets.is_ready(ref), "forgotten")
    assert(not JCore.assets.request(ref), "queued again")
    frames_until(400, function() return JCore.assets.is_ready(ref) end, "game asset reloads")
    assert_eq(JCore.casc.stats().reads, 1, "no second archive read")

    -- A path the client does not have fails for good, with a reason.
    local bad = "game:" .. fixture.ABSENT
    JCore.assets.request(bad)
    frames_until(400, function() return JCore.assets.get(bad).state == "failed" end, "absent path fails")
    local b = JCore.assets.get(bad)
    assert(b.dead, "permanent")
    assert(b.err and b.err:find("archives", 1, true), tostring(b.err))
    print_warnings("game asset")
end }

T[#T + 1] = { "unregister removes the plugin's windows", function()
    assert(JCore.unregister("test.plugin"), "unregistered")
    assert(plugin.unloaded, "on_unload ran")
    frames(5, "after unregister")
    assert(has_window(WIN) == nil, "hud window gone")
    assert(has_window("test.plugin:declared") == nil, "declared window gone")
    assert(has_window("test.plugin:legacy:legacy_test") == nil, "legacy window gone")
    local before = plugin.frames
    frames(2)
    assert_eq(plugin.frames, before, "body no longer runs")
    assert(JCore.ui.get_value(WIN, "the_toggle_id") == nil, "widget state dropped")
    assert_eq(JCore.ui.stats().live, 1, "only the launcher remains")
end }

-- --- 8. toast and confirm ---------------------------------------------------

T[#T + 1] = { "toast paints and confirm modal accepts a click", function()
    JCore.ui.toast("hi")
    JCore.ui.toast("titled", { title = "Title", kind = "success", icon = "icon:inv_misc_questionmark", anchor = "bottom-left" })
    frames(2, "toasts")
    assert_eq(JCore.ui.stats().toasts, 2, "two toasts alive")

    local confirmed, cancelled = false, false
    JCore.ui.confirm({ title = "t", body = "b", on_confirm = function() confirmed = true end, on_cancel = function() cancelled = true end })
    frames(1, "modal frame")
    local rect = JCore.ui._P.modal_rect
    assert(rect, "modal rect known")
    local widget_h = JCore.ui._T.widget_h
    local bx = rect[1] + rect[3] - 110 - 12
    local by = rect[2] + rect[4] - widget_h - 12
    -- A window under the modal must not see the click.
    click_at(bx + 55, by + widget_h / 2, "confirm click")
    assert(confirmed, "on_confirm fired")
    assert(not cancelled, "on_cancel not fired")
    assert(JCore.ui._P.modal == nil, "modal closed")

    cancelled = false
    JCore.ui.confirm({ title = "t2", body = { "line one", "line two" }, tone = "danger", on_cancel = function() cancelled = true end })
    frames(1)
    rect = JCore.ui._P.modal_rect
    local cx = rect[1] + rect[3] - 110 - 12 - 110 - 8
    click_at(cx + 55, by + widget_h / 2, "cancel click")
    assert(cancelled, "on_cancel fired")

    -- Escape cancels too, without any text field holding focus.
    cancelled = false
    JCore.ui.confirm({ title = "t3", body = "esc", on_cancel = function() cancelled = true end })
    frames(1)
    mock.press(0x1B)
    frames(1, "escape")
    mock.release(0x1B)
    frames(1)
    assert(cancelled, "escape cancelled the dialog")
    assert(JCore.ui._P.modal == nil, "modal closed by escape")

    -- Let the toasts expire.
    mock.time = mock.time + 10
    frames(2, "toasts expired")
    assert_eq(JCore.ui.stats().toasts, 0, "toasts gone")
end }

-- --- built-in windows ---------------------------------------------------------

T[#T + 1] = { "built-in browser, inspector and gallery windows run", function()
    JCore.ui:show("jcore:icons"); JCore.ui:show("jcore:assets"); JCore.ui:show("jcore:gallery")
    frames(5, "built-in windows")
    assert_eq(JCore.ui.stats().live, 4, "three built-in windows plus the launcher live")
    -- Walk the gallery's tabs so every tab body runs at least once.
    for tab = 1, 4 do
        JCore.ui.set_value("jcore:gallery", "tab", tab)
        frames(3, "gallery tab " .. tab)
    end
    JCore.ui:hide("jcore:icons"); JCore.ui:hide("jcore:assets"); JCore.ui:hide("jcore:gallery")
    frames(2)
    assert_eq(JCore.ui.stats().live, 1, "hidden again; only the launcher stays")
    print_warnings("built-in")
end }

T[#T + 1] = { "diagnostics and storage flush stay clean over a long idle", function()
    local d = JCore.diagnostics()
    assert(d.ui and d.assets and d.plugins, "diagnostics table")
    mock.time = mock.time + 3
    frames(60, "long idle")
    assert(mock.data_fs["jcore/jcore.ui.json"], "ui store flushed to disk")
    assert(mock.data_fs["jcore/jcore.assets.json"], "assets store flushed to disk")
    local n = 0
    for name in pairs(mock.missing) do
        n = n + 1
        if n <= 40 then print("  missing native read: " .. name) end
    end
end }

return T

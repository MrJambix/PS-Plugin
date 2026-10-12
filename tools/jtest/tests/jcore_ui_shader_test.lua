-- JCore 1.10.0: toolkit windows drawn with the loader's shader calls.
--
-- The mock's core.graphics has no render_* calls, so every other test runs
-- the plain shapes (the path a client without them takes). Here they are
-- installed before JCore boots and record what they were asked for: the
-- window's drop shadow, the title and separator gradients, the switch's
-- fill, the hover pill, the slider track and the dropdown field. Then the
-- "Shader-drawn windows" switch, and a call that raises.

local mock = require("mock_core")
mock.install()

local SHADERS = {
    "render_drop_shadow", "render_linear_gradient", "render_hover_pill",
    "render_slider_track", "render_dropdown_field",
}

local calls = {}  -- name -> { {args...}, ... } since the last clear
local raise = {}  -- name -> true: the call raises

local function clear() calls = {} end
local function count(name) return calls[name] and #calls[name] or 0 end

do
    local g = core.graphics
    for _, name in ipairs(SHADERS) do
        rawset(g, name, function(...)
            if raise[name] then error(name .. " broke") end
            local list = calls[name]
            if not list then list = {}; calls[name] = list end
            list[#list + 1] = { ... }
        end)
    end
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

local function frames(n, label)
    for _ = 1, n do mock.frame(1) end
    fail_on_errors(label or ("after " .. n .. " frame(s)"))
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function near(a, b) return math.abs(a - b) < 1e-6 end

local JCore
local rects = {}
local X, Y, W = 100, 100, 260

local function body(ui)
    local function rec(id)
        local x, y, w, h = ui:last_rect()
        if x then rects[id] = { x, y, w, h } end
    end
    ui:separator("Keep up")
    ui:toggle("fort", "Fortitude", true)
    rec("fort")
    ui:toggle("sprot", "Shadow Protection", false)
    rec("sprot")
    ui:dropdown("form", "Shadowform", { "Auto", "None", "On" }, 1)
    rec("form")
    ui:slider("range", "Heal range (yd)", 0, 100, 25)
    rec("range")
end

local T = {}

T[#T + 1] = { "boot with the shader calls present: the switch on by default", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    fail_on_errors("boot")
    JCore = _G.JCore
    assert_eq(JCore.version, "1.8.1", "version")
    assert_eq(JCore.ui.settings.shaders, true, "settings.shaders")
    local page = mock.menu.values["JCore/UI"]
    assert(page, "JCore/UI page declared")
    assert_eq(page.shaders, true, "Shader-drawn windows declared on, defaulting on")
    JCore.register({
        id = "shade.test", name = "Shade", version = "1.0.0", kind = "plugin",
        on_load = function(ctx)
            ctx.ui:window("shade", { title = "Priest", x = X, y = Y, w = W, scroll = false }, body)
        end,
    })
    frames(3, "first frames")
    assert(rects.fort and rects.range and rects.form, "widget rects recorded")
end }

T[#T + 1] = { "the window's shadow is one render_drop_shadow reaching past it by blur and offset", function()
    mock.move(5, 5)
    frames(2, "settle")
    clear()
    frames(1, "shadow frame")
    local mine
    for _, a in ipairs(calls.render_drop_shadow or {}) do
        if a[6] == W then mine = a end
    end
    assert(mine, "a drop shadow with the window's width as element_w")
    local p_min, p_max, ox, oy, soft, spread = mine[1], mine[2], mine[4], mine[5], mine[9], mine[10]
    assert_eq(ox, 0, "offset_x"); assert_eq(oy, 4, "offset_y"); assert_eq(soft, 10, "softness"); assert_eq(spread, 0, "spread")
    assert_eq(p_min.x, X - 14, "quad left"); assert_eq(p_min.y, Y - 14, "quad top")
    assert_eq(p_max.x, X + W + 14, "quad right")
    assert_eq(mine[8], 4, "rounding")
end }

T[#T + 1] = { "title, separator plate and underline, and the switch that is on paint as gradients", function()
    clear()
    frames(1, "gradient frame")
    local title, plate, under, switch = 0, 0, 0, 0
    local fort = rects.fort
    for _, a in ipairs(calls.render_linear_gradient or {}) do
        local x0, y0, x1, y1 = a[1].x, a[1].y, a[2].x, a[2].y
        if x0 == X and y0 == Y and x1 == X + W then title = title + 1 end
        if y1 - y0 == 1 then under = under + 1 end
        if x0 > X and y1 - y0 > 1 and y0 < fort[2] and x1 - x0 > W / 2 then plate = plate + 1 end
        if y0 > fort[2] and y1 < fort[2] + fort[4] then switch = switch + 1 end
    end
    assert_eq(title, 1, "title bar gradient")
    assert(plate >= 1, "separator plate")
    assert(under >= 1, "separator underline")
    assert_eq(switch, 1, "the on switch's track (the off one is a plain fill)")
end }

T[#T + 1] = { "the slider track and dropdown field are shader calls; no hover pill while nothing is hovered", function()
    clear()
    frames(1, "track frame")
    assert_eq(count("render_slider_track"), 1, "one slider track")
    local s = calls.render_slider_track[1]
    assert(near(s[6], 0.25), "fill_t is the slider's fraction, got " .. tostring(s[6]))
    assert_eq(s[7], 3, "rounding is half the 6 px track")
    assert_eq(s[8], 0, "hover amount at rest")
    assert(type(s[9]) == "number" and s[9] > 0, "time passed")
    assert_eq(count("render_dropdown_field"), 1, "one dropdown field")
    assert_eq(calls.render_dropdown_field[1][8], 0, "dropdown open amount")
    assert_eq(count("render_hover_pill"), 0, "no pill")
end }

T[#T + 1] = { "hovering a switch eases its hover pill in, and out again after the cursor leaves", function()
    local r = rects.sprot
    mock.move(r[1] + r[3] / 2, r[2] + r[4] / 2)
    frames(20, "hover in")
    clear()
    frames(1, "hovered frame")
    assert_eq(count("render_hover_pill"), 1, "the hovered row's pill")
    local p = calls.render_hover_pill[1]
    assert_eq(p[1].y, r[2], "pill on the row"); assert_eq(p[2].y - p[1].y, r[4], "pill height")
    mock.move(5, 5)
    frames(30, "hover out")
    clear()
    frames(1, "after hover")
    assert_eq(count("render_hover_pill"), 0, "pill gone")
end }

T[#T + 1] = { "the Shader-drawn windows switch off paints the plain shapes, and on again brings them back", function()
    mock.menu:set("JCore/UI", "shaders", false)
    assert_eq(JCore.ui.settings.shaders, false, "settings follow the page")
    clear()
    frames(1, "plain frame")
    for _, name in ipairs(SHADERS) do assert_eq(count(name), 0, name .. " with the switch off") end
    assert((mock.frame_counts.rect_2d_filled or 0) > 0, "plain fills painted")
    mock.menu:set("JCore/UI", "shaders", true)
    clear()
    frames(1, "shader frame")
    assert_eq(count("render_slider_track"), 1, "slider track back")
end }

T[#T + 1] = { "a shader call that raises is warned about once and not tried again; the rest keep going", function()
    local warnings = #mock.warnings
    raise.render_slider_track = true
    clear()
    frames(1, "raising frame")
    local function warned()
        local n = 0
        for i = warnings + 1, #mock.warnings do
            if mock.warnings[i]:find("render_slider_track raised", 1, true) then n = n + 1 end
        end
        return n
    end
    assert_eq(warned(), 1, "one warning")
    raise.render_slider_track = nil
    clear()
    frames(3, "after the raise")
    assert_eq(count("render_slider_track"), 0, "not tried again")
    assert(count("render_dropdown_field") >= 1, "the other calls still used")
    assert_eq(warned(), 1, "still one warning")
end }

return T

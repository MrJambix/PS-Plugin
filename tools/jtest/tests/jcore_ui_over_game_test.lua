-- JCore 1.8.1: the screen UI paints over the game's own frames.
--
-- The render pass is painted under the client's UI (the bags, the map, a
-- quest log), the native window pass over it. Everything from the HUD band
-- up -- windows, panels, popups, tooltips, toasts -- is handed to the window
-- pass at each flush; the world bands stay in the render pass. A loader
-- without the pass, or the Core > UI switch off, paints it all in the
-- render pass as before.

local mock = require("mock_core")
mock.install()

local g = core.graphics
local pass = nil -- "render" or "window" while that native callback runs

-- Every 2D primitive, with the pass it was painted in.
local prims = {}
for _, name in ipairs({ "rect_2d_filled", "rect_2d", "text_2d", "line_2d" }) do
    local original = g[name]
    rawset(g, name, function(...)
        prims[#prims + 1] = { pass = pass, name = name }
        return original(...)
    end)
end

local function fail_on_errors(label)
    if #mock.errors > 0 then
        error(label .. ": core.log_error was called:\n" .. mock.error_text(), 2)
    end
end

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local JCore, draw, ctx_ref
local job = nil -- what the test plugin's render job submits this frame
local marks = {} -- { pass, tag } per submitted closure that ran

local function mark(layer, tag)
    draw.submit(layer, function() marks[#marks + 1] = { pass = pass, tag = tag } end)
end

local function clear()
    marks, prims = {}, {}
end

local function frame(label)
    mock.frame(1)
    fail_on_errors(label or "frame")
end

--- "tag@pass tag@pass ..." in paint order, for one assertion per sequence.
local function seq()
    local out = {}
    for i = 1, #marks do out[i] = marks[i].tag .. "@" .. tostring(marks[i].pass) end
    return table.concat(out, " ")
end

local function count(where, tag)
    local n = 0
    for i = 1, #marks do
        if marks[i].pass == where and (tag == nil or marks[i].tag == tag) then n = n + 1 end
    end
    return n
end

local function prims_in(where)
    local n = 0
    for i = 1, #prims do if prims[i].pass == where then n = n + 1 end end
    return n
end

--- Wraps each registered native callback of a phase so `pass` names it.
local function name_pass(list, name)
    for i = 1, #list do
        local fn = list[i]
        list[i] = function(...)
            pass = name
            fn(...)
            pass = nil
        end
    end
end

--- The window callbacks alone, as a loader whose render pass has stopped.
local function window_only(n)
    for _ = 1, n do
        for i = 1, #mock.callbacks.render_window do mock.callbacks.render_window[i]() end
    end
    fail_on_errors("window pass alone")
end

local T = {}

T[#T + 1] = { "boot: one window-pass callback, the switch declared and on", function()
    local ok, public = pcall(require, "jcore/main")
    if not ok then error("boot raised: " .. tostring(public)) end
    fail_on_errors("boot")
    JCore = _G.JCore
    draw = JCore.draw
    assert_eq(JCore.version, "1.8.1", "version")
    assert_eq(#mock.callbacks.render, 1, "one native render callback")
    assert_eq(#mock.callbacks.render_window, 1, "one native window-pass callback")
    name_pass(mock.callbacks.render, "render")
    name_pass(mock.callbacks.render_window, "window")
    assert_eq(draw.over_game, true, "draw.over_game on by default")
    local page = mock.menu.values["JCore/UI"]
    assert(page, "JCore/UI page declared")
    assert_eq(page.over_game, true, "Draw over the game's windows declared on")
    JCore.register({
        id = "over.test", name = "Over", version = "1.0.0", kind = "plugin",
        on_load = function(ctx)
            ctx_ref = ctx
            ctx.render(function() if job then job() end end)
        end,
    })
    mock.frame(2)
    fail_on_errors("registered")
end }

T[#T + 1] = { "the world bands paint in the render pass, the HUD band and up in the window pass, each in layer order", function()
    local L = draw.LAYER
    job = function()
        mark(L.TOOLTIP + 4, "tip")
        mark(L.WORLD, "world")
        mark(L.HUD + 7, "front")
        mark(L.OVERLAY, "overlay")
        mark(L.HUD, "hud")
        mark(L.UNITS, "units")
        mark(L.DANGER, "danger")
    end
    clear()
    frame("bands")
    job = nil
    assert_eq(seq(), "world@render danger@render units@render overlay@render hud@window front@window tip@window",
        "paint order and pass")
    assert_eq(draw.stats().ui_pass, "window", "stats name the window pass")
end }

T[#T + 1] = { "a JCore window paints only in the window pass", function()
    local h = ctx_ref.ui:window("over", { title = "Over", x = 300, y = 300, w = 240, scroll = false }, function(ui)
        ui:text("over the bags")
        ui:toggle("t", "A toggle", true)
    end)
    frame("open")
    clear()
    frame("window frame")
    assert(prims_in("window") > 0, "the window painted in the window pass")
    assert_eq(prims_in("render"), 0, "nothing 2D painted in the render pass")
    assert_eq(prims_in(nil), 0, "nothing painted outside a pass")
    h.remove()
    frame("closed")
end }

T[#T + 1] = { "a frame with no UI leaves none from the last one painted", function()
    job = function() mark(draw.LAYER.HUD, "hud") end
    frame("with")
    job = nil
    clear()
    frame("without")
    assert_eq(count("window"), 0, "nothing repainted")
end }

T[#T + 1] = { "the render pass stopping does not leave the UI frozen on screen", function()
    job = function() mark(draw.LAYER.HUD, "hud") end
    clear()
    frame("handed over")
    job = nil
    assert_eq(count("window", "hud"), 1, "painted by the frame's window pass")
    window_only(4)
    assert_eq(count("window", "hud"), 2, "one more window pass repaints it, no further")
    clear()
    job = function() mark(draw.LAYER.HUD, "hud") end
    frame("render pass back")
    job = nil
    assert_eq(seq(), "hud@window", "painted again once the render pass runs")
end }

T[#T + 1] = { "a loader that stops calling the window pass: the UI is back in the render pass within three frames, never twice", function()
    mock.window_pass = false
    job = function()
        mark(draw.LAYER.WORLD, "world")
        mark(draw.LAYER.HUD, "hud")
    end
    local per_frame = {}
    for i = 1, 6 do
        clear()
        frame("no window pass " .. i)
        per_frame[i] = seq()
    end
    for i = 1, 3 do assert_eq(per_frame[i], "world@render", "frame " .. i .. ": the UI waits for a pass that does not come") end
    for i = 4, 6 do assert_eq(per_frame[i], "world@render hud@render", "frame " .. i .. ": the UI in the render pass") end
    assert_eq(draw.stats().ui_pass, "render", "stats name the render pass")

    mock.window_pass = true
    clear()
    frame("pass back")
    assert_eq(seq(), "world@render hud@render", "first frame back: still the render pass, not painted twice")
    clear()
    frame("pass back 2")
    assert_eq(seq(), "world@render hud@window", "from the next frame, the window pass")
    job = nil
end }

T[#T + 1] = { "the switch off paints the UI in the render pass; on again, straight back over the game", function()
    job = function() mark(draw.LAYER.HUD, "hud") end
    mock.menu:set("JCore/UI", "over_game", false)
    assert_eq(draw.over_game, false, "draw follows the switch")
    clear()
    frame("off")
    assert_eq(seq(), "hud@render", "under the game's frames")
    assert_eq(draw.stats().ui_pass, "render", "stats")
    mock.menu:set("JCore/UI", "over_game", true)
    clear()
    frame("on")
    assert_eq(seq(), "hud@window", "over them again")
    job = nil
end }

T[#T + 1] = { "a UI closure that raises costs only itself", function()
    job = function()
        draw.submit(draw.LAYER.HUD, function() error("panel broke") end)
        mark(draw.LAYER.HUD, "after")
    end
    clear()
    mock.frame(1)
    job = nil
    assert_eq(seq(), "after@window", "the next closure still painted")
    local logged = false
    for i = 1, #mock.errors do
        if tostring(mock.errors[i]):find("panel broke", 1, true) then logged = true end
    end
    assert(logged, "the failure logged")
    for i = #mock.errors, 1, -1 do mock.errors[i] = nil end
end }

return T

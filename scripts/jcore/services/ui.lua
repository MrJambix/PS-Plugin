-- JCore / ui -- windows and widgets painted on the overlay, for every plugin.
--
-- Depends on: util, log, draw, input, storage, scheduler, events, assets.
--
-- WHAT THIS IS
-- The declarative `_G.menu` is the right home for SETTINGS: it persists, it
-- searches, it has profiles. It is the wrong home for anything that lives on
-- the screen while the menu is closed -- a threat panel, a rotation HUD, a
-- fishing session readout, a boss-timer strip. Plugins build those out of
-- raw rect and text calls, each with its own drag code, its own colours and
-- its own idea of where the mouse is. This module is the shared answer:
-- windows that drag, collapse, resize, remember their place and stack in a
-- sane z-order, filled with widgets that look alike and read their values
-- the same way whichever plugin declared them.
--
-- IMMEDIATE MODE, RETAINED STATE
-- A plugin describes its window every frame from a render job:
--
--     if ui:begin_window("hud", { title = "My HUD", x = 80, y = 120 }) then
--         ui:text("Target: " .. name)
--         if ui:button("pull", "Pull") then pull() end
--         local on = ui:toggle("auto", "Auto mode", true)
--     end
--     ui:end_window()
--
-- Every call paints its widget at the layout cursor, handles its own
-- hover/click/drag against this frame's mouse, and returns the value. State
-- that must survive the frame (a toggle's value, a slider's drag, a text
-- field's caret, a window's position) lives in tables keyed by the widget's
-- id, so the plugin holds nothing. That is what lets the same widget set
-- host content from every kind of plugin code -- see ui_compat.lua for the
-- declarative, legacy and menu-mirroring fronts built on these calls.
--
-- WHERE IT PAINTS
-- Nothing here calls core.graphics directly during a job. Each window records
-- a command list and submits ONE closure to the draw queue at its own layer
-- (HUD plus its z-order slot), so windows interleave correctly with every
-- other mark JCore paints and always sit above world drawings. Popups,
-- tooltips, toasts and the modal go on the TOOLTIP band above all windows.
--
-- INPUT
-- Hover is decided once per frame, before any window runs: the topmost
-- window under the cursor from LAST frame's rectangles owns the mouse. A
-- widget in any other window sees no hover, which is the whole z-order
-- problem solved in one place. The mouse is hard-captured from the game
-- only while the cursor is over one of these windows, and released as soon
-- as it leaves, so a stuck capture cannot happen.

return function(rt)
    local util = rt.util
    local draw = rt.draw
    local input = rt.input
    local storage = rt.storage
    local scheduler = rt.scheduler
    local events = rt.events
    local assets = rt.assets
    local log = rt.log.for_tag("JCore/ui")

    local M = {}
    M.VERSION = "1.0.0"

    local floor, max, min, abs = math.floor, math.max, math.min, math.abs

    -- --- native helpers -----------------------------------------------------

    local color_lib
    do
        local ok, mod = pcall(require, "common/color")
        if ok then color_lib = mod end
    end

    local vec2_lib
    do
        local ok, mod = pcall(require, "common/geometry/vector_2")
        if ok then vec2_lib = mod end
    end

    local function vec2(x, y)
        if vec2_lib then
            local ok, v = pcall(vec2_lib.new, x, y)
            if ok then return v end
        end
        return { x = x, y = y }
    end

    local function rgba(r, g, b, a)
        if color_lib then
            local ok, c = pcall(color_lib.new, r, g, b, a or 255)
            if ok then return c end
        end
        return { r = r, g = g, b = b, a = a or 255 }
    end
    M.rgba = rgba

    --- Channels of a colour, whichever shape it has.
    local function channels(c)
        if type(c) == "table" and c.r then return c.r, c.g, c.b, c.a or 255 end
        if c and c.get then
            local ok, r, g, b, a = pcall(c.get, c)
            if ok and r then return r, g, b, a or 255 end
        end
        return 255, 255, 255, 255
    end
    M.channels = channels

    -- Alpha-scaled variants are cached per colour and per 4% step, because
    -- a window at 80% opacity would otherwise allocate a colour per
    -- primitive per frame.
    local fade_cache = setmetatable({}, { __mode = "k" })
    local function fade(c, alpha)
        if alpha >= 0.999 then return c end
        local key = floor(alpha * 25)
        local bucket = fade_cache[c]
        if not bucket then
            bucket = {}
            fade_cache[c] = bucket
        end
        local hit = bucket[key]
        if hit then return hit end
        local r, g, b, a = channels(c)
        hit = rgba(r, g, b, floor(a * (key / 25)))
        bucket[key] = hit
        return hit
    end
    M.fade = fade

    --- A colour from {r,g,b,a}, an array, a colour object, or a theme key.
    local function to_color(v, fallback)
        if v == nil then return fallback end
        if type(v) == "string" then return M.theme[v] or fallback end
        if type(v) == "table" then
            if v.r and not v.get then return rgba(v.r, v.g, v.b, v.a or 255) end
            if v[1] then return rgba(v[1], v[2], v[3], v[4] or 255) end
        end
        return v
    end
    M.to_color = to_color

    -- --- theme --------------------------------------------------------------

    M.theme = {
        bg            = rgba(19, 20, 25, 236),
        bg_title      = rgba(27, 29, 37, 248),
        bg_elevated   = rgba(36, 38, 48, 255),
        bg_hover      = rgba(48, 51, 64, 255),
        bg_active     = rgba(58, 61, 78, 255),
        bg_input      = rgba(14, 15, 19, 255),
        border        = rgba(62, 65, 80, 255),
        border_focus  = rgba(140, 120, 240, 255),
        accent        = rgba(140, 120, 240, 255),
        accent_dim    = rgba(140, 120, 240, 110),
        accent_text   = rgba(245, 243, 255, 255),
        track         = rgba(44, 46, 58, 255),
        text          = rgba(235, 235, 240, 255),
        text_dim      = rgba(160, 163, 176, 255),
        text_disabled = rgba(105, 108, 120, 255),
        success       = rgba(100, 200, 140, 255),
        warning       = rgba(240, 180, 60, 255),
        danger        = rgba(235, 87, 87, 255),
        info          = rgba(90, 160, 235, 255),
        health        = rgba(90, 190, 110, 255),
        mana          = rgba(70, 120, 230, 255),
        shadow        = rgba(0, 0, 0, 110),
        backdrop      = rgba(0, 0, 0, 140),
        zebra         = rgba(255, 255, 255, 8),
        -- Shader-drawn shapes (1.10.0). Derived from the colours above by
        -- hand, so a theme that changes `accent` should set these as well.
        shadow_soft   = rgba(0, 0, 0, 150),       -- window and popup drop shadow
        title_glow    = rgba(47, 45, 74, 248),    -- title bar's left end, fading to bg_title
        accent_lo     = rgba(92, 80, 154, 255),   -- switch and slider fill, low end
        accent_hi     = rgba(169, 154, 244, 255), -- and high end
        pill          = rgba(255, 255, 255, 12),  -- hovered row
        streak        = rgba(140, 120, 240, 60),  -- its moving streaks
        header        = rgba(140, 120, 240, 60),  -- labelled separator plate, left end
        clear         = rgba(140, 120, 240, 0),   -- what plates and underlines fade to
        font = { title = 14, body = 13, small = 11, micro = 10 },
        pad = 8, gap = 4, row = 22, rounding = 4, title_h = 24, scrollbar = 6,
        opacity = 1.0, scale = 1.0,
    }

    -- Effective metrics after scale, rebuilt when the scale changes. A
    -- window with its own `scale` (1.8.10) rebuilds them for its body, its
    -- popups and its tooltips, and the global scale is put back after it.
    local T = {}
    local applied_scale = nil
    local function apply_scale(scale)
        local s = scale or M.theme.scale or 1.0
        if applied_scale == s then return end
        applied_scale = s
        T.pad = floor(M.theme.pad * s + 0.5)
        T.gap = floor(M.theme.gap * s + 0.5)
        T.row = floor(M.theme.row * s + 0.5)
        T.rounding = M.theme.rounding * s
        T.title_h = floor(M.theme.title_h * s + 0.5)
        T.scrollbar = max(4, floor(M.theme.scrollbar * s + 0.5))
        T.font_title = floor(M.theme.font.title * s + 0.5)
        T.font_body = floor(M.theme.font.body * s + 0.5)
        T.font_small = floor(M.theme.font.small * s + 0.5)
        T.font_micro = floor(M.theme.font.micro * s + 0.5)
        T.widget_h = T.row
    end
    apply_scale()

    ---@param overrides table
    function M.set_theme(overrides)
        util.deep_merge(M.theme, overrides or {})
        applied_scale = nil
        apply_scale()
    end

    ---@param s number 0.6 .. 2.0
    function M.set_scale(s)
        M.theme.scale = util.clamp(s or 1, 0.6, 2.0)
        applied_scale = nil
        apply_scale()
    end

    ---@param o number 0.2 .. 1.0
    function M.set_opacity(o)
        M.theme.opacity = util.clamp(o or 1, 0.2, 1.0)
    end

    -- --- persistent state ---------------------------------------------------

    local store = storage.store("jcore.ui")
    local data = store.data
    data.windows = data.windows or {}
    data.values = data.values or {}

    local settings = {
        enabled = true,
        capture_mouse = true,
        lock_windows = false,
        snap = 10,
        shaders = true,
    }
    M.settings = settings

    -- --- runtime state ------------------------------------------------------
    --
    -- F holds this frame's input, rebuilt in _begin_frame. P holds state that
    -- crosses frames: what is pressed, what has focus, what popup is open.

    local F = {
        mx = 0, my = 0, lmb = false, rmb = false, mmb = false,
        lmb_down = false, lmb_up = false, rmb_down = false, rmb_up = false,
        mmb_down = false, dbl = false, wheel = 0, t = 0, dt = 0, frame = 0,
        hover_win = nil, sw = 0, sh = 0, typed = nil, keys = nil,
        hot = nil, last_rect = nil, last_uid = nil, last_hot = false, blocked = false,
    }
    M.frame = F

    local P = {
        active = nil,        -- uid holding the mouse button
        active_win = nil,
        focus = nil,         -- uid of the text field with the caret
        listening = nil,     -- uid of the keybind waiting for a key
        popup = nil,         -- { uid, x, y, w, h, fn, opener }
        popup_next = nil,
        tooltip = nil,
        modal = nil,
        toasts = {},
        drag = nil,          -- { win, dx, dy } or { win, resize = true }
        captured_mouse = false,
        captured_kbd = false,
        last_lmb = false, last_rmb = false, last_mmb = false,
        last_click_t = 0, last_click_x = 0, last_click_y = 0,
        key_repeat = {},
        hover_rects = {},    -- window id -> rect, for next frame's hover pass
        popup_rect = nil,
        modal_rect = nil,
        frames_active_missing = 0,
    }

    local S = {}             -- uid -> widget state
    local OBS = {}           -- uid -> observers
    local windows = {}       -- id -> window record
    local z_order = {}       -- ids, back to front
    local retained = {}      -- id -> handle for windows registered via :window()

    local stats = { windows = 0, widgets = 0, cmds = 0, popups = 0, text_cache = 0 }

    local function state_for(uid)
        local st = S[uid]
        if not st then
            st = { init = false }
            S[uid] = st
        end
        return st
    end

    --- Reads a widget's stored value, initialising it from persistence or
    --- the declared default on first sight. Booleans are handled with an
    --- explicit init flag: `st.v or default` would turn every OFF into ON.
    local function value_of(uid, default, persist)
        local st = state_for(uid)
        if not st.init then
            st.init = true
            st.persist = persist and true or false
            local saved = persist and data.values[uid] or nil
            if saved ~= nil then
                st.v = saved
            else
                st.v = default
            end
            st.default = default
        end
        return st, st.v
    end

    local function set_value(uid, v)
        local st = state_for(uid)
        local old = st.v
        if old == v then return false end
        st.v = v
        st.init = true
        if st.persist then
            data.values[uid] = v
            store:touch()
        end
        local list = OBS[uid]
        if list then
            for i = 1, #list do
                local ok, err = pcall(list[i], v, old)
                if not ok then log.fmt("error", "on_change for %s failed: %s", uid, tostring(err)) end
            end
        end
        return true
    end
    M._set_value = set_value
    M._state_for = state_for
    M._value_of = value_of

    -- --- text measurement ---------------------------------------------------

    local function text_w(s, size)
        return draw.measure(s, size) or (#s * size * 0.55)
    end
    M.text_width = text_w

    local trunc_cache = {}
    local trunc_count = 0

    --- Cuts text to fit `w` pixels with an ellipsis. Cached, because a list
    --- truncates the same forty labels every frame.
    local function truncate(s, size, w)
        if w <= 0 then return "" end
        if text_w(s, size) <= w then return s end
        local key = s .. "\1" .. size .. "\1" .. floor(w)
        local hit = trunc_cache[key]
        if hit then return hit end

        local lo, hi = 0, #s
        local out = ""
        while lo < hi do
            local mid = floor((lo + hi + 1) / 2)
            local candidate = s:sub(1, mid) .. ".."
            if text_w(candidate, size) <= w then
                out = candidate
                lo = mid
            else
                hi = mid - 1
            end
        end
        if trunc_count > 4000 then
            trunc_cache = {}
            trunc_count = 0
        end
        trunc_cache[key] = out
        trunc_count = trunc_count + 1
        return out
    end
    M.truncate = truncate

    --- Splits text into lines that fit `w` pixels, on spaces.
    local function wrap(s, size, w)
        local lines = {}
        for paragraph in (s .. "\n"):gmatch("(.-)\n") do
            local line = ""
            for word in paragraph:gmatch("%S+") do
                local candidate = line == "" and word or (line .. " " .. word)
                if text_w(candidate, size) <= w or line == "" then
                    line = candidate
                else
                    lines[#lines + 1] = line
                    line = word
                end
            end
            lines[#lines + 1] = line
        end
        return lines
    end
    M.wrap = wrap

    -- --- paint command list -------------------------------------------------
    --
    -- Every window collects commands; at end_window ONE closure replays them
    -- at the window's layer. Op codes are small integers so the replay is a
    -- chain of comparisons rather than a table lookup per command.

    local OP_RECT_F, OP_RECT, OP_LINE, OP_TEXT, OP_CIRC_F, OP_CIRC = 1, 2, 3, 4, 5, 6
    local OP_TRI, OP_CLIP, OP_UNCLIP, OP_IMAGE, OP_TEX, OP_FN, OP_GIF = 7, 8, 9, 10, 11, 12, 13
    local OP_SHADOW, OP_GRAD, OP_PILL, OP_SLIDER, OP_FIELD = 14, 15, 16, 17, 18

    local cur -- the window (or pseudo window) being described

    -- --- shader-drawn shapes (1.10.0) -----------------------------------------
    --
    -- The loader's core.graphics.render_* calls draw one shape with one SDF
    -- pixel shader: a soft shadow, a gradient, and the animated hover, slider
    -- and dropdown plates. A widget asks shader(name) while it is described
    -- and, on false, emits the plain shapes it always did, so a client
    -- without the call or the "Shader drawing" switch turned off paints
    -- exactly what 1.9 did. A call that raises is logged once and not tried
    -- again this session; the frame it raised on paints a plain stand-in.

    local shader_ok = {} -- render_* name -> boolean, settled on first ask

    ---@param name string
    ---@return boolean
    local function shader(name)
        if not settings.shaders then return false end
        local ok = shader_ok[name]
        if ok == nil then
            local g = core.graphics
            ok = g ~= nil and type(g[name]) == "function"
            shader_ok[name] = ok
        end
        return ok
    end
    M.shader = shader

    local function shader_call(name, ...)
        local ok, err = pcall(core.graphics[name], ...)
        if not ok then
            shader_ok[name] = false
            log.fmt("warn", "%s raised, windows draw plain shapes instead: %s", name, tostring(err))
        end
        return ok
    end

    local function replay(cmds, n)
        local g = core.graphics
        for i = 1, n do
            local c = cmds[i]
            local op = c[1]
            if op == OP_RECT_F then
                g.rect_2d_filled(vec2(c[2], c[3]), c[4], c[5], c[6], c[7] or 0)
            elseif op == OP_TEXT then
                g.text_2d(c[2], vec2(c[3], c[4]), c[5], c[6], c[7] or false, c[8] or 0)
            elseif op == OP_RECT then
                g.rect_2d(vec2(c[2], c[3]), c[4], c[5], c[6], c[7] or 1, c[8] or 0)
            elseif op == OP_LINE then
                g.line_2d(vec2(c[2], c[3]), vec2(c[4], c[5]), c[6], c[7] or 1)
            elseif op == OP_CLIP then
                g.scissor_push(c[2], c[3], c[4], c[5])
            elseif op == OP_UNCLIP then
                g.scissor_pop()
            elseif op == OP_IMAGE then
                assets.draw(c[2], vec2(c[3], c[4]), c[5], c[6], c[7], c[8])
            elseif op == OP_CIRC_F then
                g.circle_2d_filled(vec2(c[2], c[3]), c[4], c[5])
            elseif op == OP_CIRC then
                g.circle_2d(vec2(c[2], c[3]), c[4], c[5], c[6] or 1)
            elseif op == OP_TRI then
                g.triangle_2d_filled(vec2(c[2], c[3]), vec2(c[4], c[5]), vec2(c[6], c[7]), c[8])
            elseif op == OP_TEX then
                g.draw_texture(c[2], vec2(c[3], c[4]), c[5], c[6], c[7], false)
            elseif op == OP_GIF then
                g.draw_gif(c[2], vec2(c[3], c[4]), c[5], c[6], c[7], false, c[8] or 1)
            elseif op == OP_FN then
                local ok, err = pcall(c[2], c[3], c[4], c[5], c[6])
                if not ok then log.fmt("error", "custom painter failed: %s", tostring(err)) end
            elseif op == OP_SHADOW then
                -- { x, y, w, h, col, rounding, softness, offset_y }. The quad
                -- reaches past the element by the blur and the offset, so the
                -- shadow is not cut off at the element's own edges.
                local x, y, w, h, soft, oy = c[2], c[3], c[4], c[5], c[8], c[9]
                local reach = soft + abs(oy)
                shader_call("render_drop_shadow", vec2(x - reach, y - reach), vec2(x + w + reach, y + h + reach),
                    c[6], 0, oy, w, h, c[7], soft, 0)
            elseif op == OP_GRAD then
                -- { x, y, w, h, from, to, angle, rounding }
                local r = c[9] or 0
                if not shader_call("render_linear_gradient", vec2(c[2], c[3]), vec2(c[2] + c[4], c[3] + c[5]),
                    c[6], c[7], c[8] or 0, r, r > 0 and 1 or 0) then
                    g.rect_2d_filled(vec2(c[2], c[3]), c[4], c[5], c[6], r)
                end
            elseif op == OP_PILL then
                -- { x, y, w, h, base, streak, rounding, time }
                if not shader_call("render_hover_pill", vec2(c[2], c[3]), vec2(c[2] + c[4], c[3] + c[5]),
                    c[6], c[7], c[8], 1, 1, c[9], 1) then
                    g.rect_2d_filled(vec2(c[2], c[3]), c[4], c[5], c[6], c[8])
                end
            elseif op == OP_SLIDER then
                -- { x, y, w, h, fill_lo, fill_hi, rail, fraction, hover, time }
                if not shader_call("render_slider_track", vec2(c[2], c[3]), vec2(c[2] + c[4], c[3] + c[5]),
                    c[6], c[7], c[8], c[9], c[5] / 2, c[10], c[11], 1) then
                    g.rect_2d_filled(vec2(c[2], c[3]), c[4], c[5], c[8], c[5] / 2)
                    g.rect_2d_filled(vec2(c[2], c[3]), max(c[5], c[4] * c[9]), c[5], c[7], c[5] / 2)
                end
            elseif op == OP_FIELD then
                -- { x, y, w, h, base, elevated, accent, rounding, hover, open, time }
                if not shader_call("render_dropdown_field", vec2(c[2], c[3]), vec2(c[2] + c[4], c[3] + c[5]),
                    c[6], c[7], c[8], c[9], c[10], c[11], c[12], 1) then
                    g.rect_2d_filled(vec2(c[2], c[3]), c[4], c[5], c[7], c[9])
                end
            end
        end
    end

    local function emit(c)
        local cmds = cur.cmds
        local n = cur.n + 1
        cur.n = n
        cmds[n] = c
    end

    -- Primitive emitters. Colours pass through the window's opacity.
    local function fill(x, y, w, h, col, rounding)
        emit({ OP_RECT_F, x, y, w, h, fade(col, cur.alpha), rounding })
    end
    local function stroke(x, y, w, h, col, thickness, rounding)
        emit({ OP_RECT, x, y, w, h, fade(col, cur.alpha), thickness, rounding })
    end
    local function line(x1, y1, x2, y2, col, thickness)
        emit({ OP_LINE, x1, y1, x2, y2, fade(col, cur.alpha), thickness })
    end
    local function text(s, x, y, size, col, centered, font)
        emit({ OP_TEXT, s, x, y, size, fade(col, cur.alpha), centered, font })
    end
    local function circle_fill(cx, cy, r, col)
        emit({ OP_CIRC_F, cx, cy, r, fade(col, cur.alpha) })
    end
    local function circle(cx, cy, r, col, thickness)
        emit({ OP_CIRC, cx, cy, r, fade(col, cur.alpha), thickness })
    end
    local function tri(x1, y1, x2, y2, x3, y3, col)
        emit({ OP_TRI, x1, y1, x2, y2, x3, y3, fade(col, cur.alpha) })
    end

    -- Shader-drawn emitters (1.10.0). Use one only after shader() answered
    -- true for its render_* call; `amount` arguments are eased 0..1 states.
    local function shadow(x, y, w, h, rounding)
        local s = applied_scale or 1
        emit({ OP_SHADOW, x, y, w, h, fade(M.theme.shadow_soft, cur.alpha), rounding, 10 * s, 4 * s })
    end
    local function gradient(x, y, w, h, from, to, rounding, angle)
        emit({ OP_GRAD, x, y, w, h, fade(from, cur.alpha), fade(to, cur.alpha), angle or 0, rounding or 0 })
    end
    local function pill(x, y, w, h, amount, rounding)
        emit({ OP_PILL, x, y, w, h, fade(fade(M.theme.pill, amount), cur.alpha),
            fade(fade(M.theme.streak, amount), cur.alpha), rounding, F.t })
    end
    local function slider_track(x, y, w, h, fraction, hover_amount)
        emit({ OP_SLIDER, x, y, w, h, fade(M.theme.accent_lo, cur.alpha), fade(M.theme.accent_hi, cur.alpha),
            fade(M.theme.track, cur.alpha), fraction, hover_amount, F.t })
    end
    local function field(x, y, w, h, hover_amount, open_amount)
        emit({ OP_FIELD, x, y, w, h, fade(M.theme.bg_input, cur.alpha), fade(M.theme.bg_elevated, cur.alpha),
            fade(M.theme.accent, cur.alpha), T.rounding, hover_amount, open_amount, F.t })
    end

    --- A widget state's hover, eased toward `on`, for the shader plates.
    ---@return number 0..1
    local function ease_hover(st, on)
        local target = on and 1 or 0
        local v = st.hov or 0
        v = v + (target - v) * min(1, F.dt * 12)
        if abs(v - target) < 0.02 then v = target end
        st.hov = v
        return v
    end
    local function clip_push(x, y, w, h)
        -- Intersect with the enclosing clip so a scroll region inside a
        -- window body cannot paint outside the body.
        local top = cur.clips[#cur.clips]
        if top then
            local x2, y2 = min(x + w, top[1] + top[3]), min(y + h, top[2] + top[4])
            x, y = max(x, top[1]), max(y, top[2])
            w, h = max(0, x2 - x), max(0, y2 - y)
        end
        cur.clips[#cur.clips + 1] = { x, y, w, h }
        emit({ OP_CLIP, x, y, w, h })
    end
    local function clip_pop()
        if #cur.clips == 0 then return end
        cur.clips[#cur.clips] = nil
        emit({ OP_UNCLIP })
    end
    local function image(ref, x, y, w, h, tint, opts)
        emit({ OP_IMAGE, ref, x, y, w, h, tint and fade(tint, cur.alpha) or nil, opts })
    end

    --- Text vertically centred in a row of height h.
    local function text_row(s, x, y, h, size, col, align, w)
        local ty = y + (h - size) / 2 - 1
        if align == "center" and w then
            text(s, x + w / 2, ty, size, col, true)
        elseif align == "right" and w then
            text(s, x + w - text_w(s, size), ty, size, col, false)
        else
            text(s, x, ty, size, col, false)
        end
    end

    M.paint = {
        fill = fill, stroke = stroke, line = line, text = text, circle_fill = circle_fill,
        circle = circle, tri = tri, clip_push = clip_push, clip_pop = clip_pop, image = image,
        text_row = text_row, emit = emit,
        shadow = shadow, gradient = gradient, pill = pill, slider_track = slider_track, field = field,
        ease_hover = ease_hover,
    }

    -- --- geometry -----------------------------------------------------------

    local function inside(x, y, w, h, px, py)
        return px >= x and py >= y and px < x + w and py < y + h
    end

    --- Whether the mouse is over a rect in the CURRENT window, respecting the
    --- clip stack and the frame's hover owner.
    local function hover(x, y, w, h)
        if F.blocked then return false end
        if F.hover_win ~= cur.id then return false end
        if not inside(x, y, w, h, F.mx, F.my) then return false end
        local top = cur.clips[#cur.clips]
        if top and not inside(top[1], top[2], top[3], top[4], F.mx, F.my) then return false end
        return true
    end
    M.hover = hover

    --- The standard press/release contract every clickable widget uses.
    ---@return boolean hovered
    ---@return boolean held
    ---@return boolean clicked
    local function button_behaviour(uid, x, y, w, h, disabled)
        local hovered = (not disabled) and hover(x, y, w, h)
        if hovered then F.hot = uid end
        local clicked = false
        if hovered and F.lmb_down and P.active == nil then
            P.active = uid
            P.active_win = cur.id
            if P.focus and P.focus ~= uid then P.focus = nil end
        end
        local held = P.active == uid
        if held and F.lmb_up then
            if hovered then clicked = true end
            P.active = nil
        end
        F.last_rect = { x, y, w, h }
        F.last_uid = uid
        F.last_hot = hovered
        return hovered, held, clicked
    end
    M.button_behaviour = button_behaviour

    -- --- layout -------------------------------------------------------------
    --
    -- A stack of layout scopes. The base scope is the window body; groups,
    -- scroll regions and rows push their own. `place` hands out the next
    -- rect and advances the cursor.

    local L = nil

    local function push_layout(x, y, w, prefix)
        local parent = L
        L = {
            x = x, y = y, w = w, start_y = y, parent = parent,
            prefix = prefix or (parent and parent.prefix) or "",
            indent = 0, row = nil, max_y = y,
        }
        return L
    end

    local function pop_layout()
        local done = L
        if done then
            L = done.parent
            if L then
                -- Propagate the child's extent so a group knows its height.
                L.child_end = max(done.max_y, done.y)
            end
        end
        return done
    end

    --- Next widget rect. Inside a row, columns are consumed left to right.
    local function place(h)
        local row = L.row
        if row then
            local col = row.cols[min(row.i, #row.cols)]
            row.i = row.i + 1
            row.max_h = max(row.max_h, h)
            return col.x, row.y, col.w, h
        end
        local x = L.x + L.indent
        local y = L.y
        local w = L.w - L.indent
        L.y = y + h + T.gap
        L.max_y = max(L.max_y, L.y)
        return x, y, w, h
    end
    M._place = place

    local function uid_for(id)
        return L.prefix .. tostring(id)
    end
    M._uid = uid_for

    -- --- input polling ------------------------------------------------------

    local VK = {
        LBUTTON = 0x01, RBUTTON = 0x02, MBUTTON = 0x04, BACK = 0x08, TAB = 0x09, RETURN = 0x0D,
        SHIFT = 0x10, CONTROL = 0x11, MENU = 0x12, ESCAPE = 0x1B, SPACE = 0x20, END = 0x23,
        HOME = 0x24, LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, DELETE = 0x2E,
    }
    M.VK = VK

    -- Virtual key -> { unshifted, shifted } for the text field.
    local CHARS = {}
    for i = 0, 9 do
        CHARS[0x30 + i] = { tostring(i), (")!@#$%^&*("):sub(i + 1, i + 1) }
        CHARS[0x60 + i] = { tostring(i), tostring(i) }
    end
    for i = 0, 25 do
        local lower = string.char(97 + i)
        CHARS[0x41 + i] = { lower, lower:upper() }
    end
    CHARS[0x20] = { " ", " " }
    CHARS[0x6A] = { "*", "*" }; CHARS[0x6B] = { "+", "+" }; CHARS[0x6D] = { "-", "-" }
    CHARS[0x6E] = { ".", "." }; CHARS[0x6F] = { "/", "/" }
    CHARS[0xBA] = { ";", ":" }; CHARS[0xBB] = { "=", "+" }; CHARS[0xBC] = { ",", "<" }
    CHARS[0xBD] = { "-", "_" }; CHARS[0xBE] = { ".", ">" }; CHARS[0xBF] = { "/", "?" }
    CHARS[0xC0] = { "`", "~" }; CHARS[0xDB] = { "[", "{" }; CHARS[0xDC] = { "\\", "|" }
    CHARS[0xDD] = { "]", "}" }; CHARS[0xDE] = { "'", "\"" }

    local CHAR_KEYS = {}
    for vk in pairs(CHARS) do CHAR_KEYS[#CHAR_KEYS + 1] = vk end
    table.sort(CHAR_KEYS)

    -- Up and Down walk the lines of a code box (ui:code, 1.8.7).
    local EDIT_KEYS = { VK.BACK, VK.DELETE, VK.RETURN, VK.ESCAPE, VK.LEFT, VK.RIGHT, VK.HOME, VK.END, VK.TAB,
        VK.UP, VK.DOWN }

    local REPEAT_DELAY, REPEAT_RATE = 0.4, 1 / 30

    --- Edge-with-repeat detection for one key, used only while a field has
    --- focus so the polling cost is paid only when typing.
    local function key_fired(vk, now)
        local down = input.is_key_pressed(vk)
        local rec = P.key_repeat[vk]
        if not down then
            P.key_repeat[vk] = nil
            return false
        end
        if not rec then
            P.key_repeat[vk] = { next_at = now + REPEAT_DELAY }
            return true
        end
        if now >= rec.next_at then
            rec.next_at = now + REPEAT_RATE
            return true
        end
        return false
    end

    local function poll_keyboard(now)
        local typed, keys = {}, {}
        local shift = input.is_key_pressed(VK.SHIFT)
        local ctrl = input.is_key_pressed(VK.CONTROL)
        for i = 1, #CHAR_KEYS do
            local vk = CHAR_KEYS[i]
            if key_fired(vk, now) then
                if ctrl then
                    keys["ctrl_" .. CHARS[vk][1]] = true
                else
                    typed[#typed + 1] = CHARS[vk][shift and 2 or 1]
                end
            end
        end
        for i = 1, #EDIT_KEYS do
            local vk = EDIT_KEYS[i]
            if key_fired(vk, now) then keys[vk] = true end
        end
        keys.shift, keys.ctrl = shift, ctrl
        F.typed = typed
        F.keys = keys
    end

    --- Any key newly pressed this frame, for keybind capture. Scans the
    --- whole virtual-key range, so it is only called while listening.
    local function first_new_key(allow_mouse)
        for vk = allow_mouse and 1 or 8, 0xDE do
            if vk ~= VK.SHIFT and vk ~= VK.CONTROL and vk ~= VK.MENU then
                if input.is_key_pressed(vk) then
                    if not P.key_repeat[vk] then
                        P.key_repeat[vk] = { next_at = math.huge }
                        return vk
                    end
                else
                    P.key_repeat[vk] = nil
                end
            end
        end
        return nil
    end
    M._first_new_key = first_new_key

    -- --- windows ------------------------------------------------------------

    local function screen()
        local w, h = draw.screen_size()
        if not w or w == 0 then w, h = 1920, 1080 end
        return w, h
    end

    local function bring_to_front(id)
        local n = #z_order
        if z_order[n] == id then return end
        util.array_remove(z_order, id)
        z_order[#z_order + 1] = id
    end

    local function anchored_position(opts, w, h)
        local sw, sh = F.sw, F.sh
        local ax = opts.x or 60
        local ay = opts.y or 60
        local anchor = opts.anchor
        if anchor == "top-right" then return sw - w - ax, ay end
        if anchor == "bottom-left" then return ax, sh - h - ay end
        if anchor == "bottom-right" then return sw - w - ax, sh - h - ay end
        if anchor == "center" then return (sw - w) / 2 + ax - 60, (sh - h) / 2 + ay - 60 end
        if anchor == "top-center" then return (sw - w) / 2 + ax - 60, ay end
        if anchor == "bottom-center" then return (sw - w) / 2 + ax - 60, sh - h - ay end
        return ax, ay
    end

    local function persist_window(win)
        if not win.persist then return end
        data.windows[win.id] = {
            x = floor(win.x), y = floor(win.y), w = floor(win.w), h = floor(win.h),
            collapsed = win.collapsed, visible = win.visible, sw = F.sw, sh = F.sh,
        }
        store:touch()
    end

    local function window_record(id, opts, owner)
        local win = windows[id]
        if win then return win end

        local w = opts.w or 260
        local h = opts.h or 160
        local x, y = anchored_position(opts, w, h)

        win = {
            id = id, owner = owner, x = x, y = y, w = w, h = h,
            collapsed = false, visible = opts.visible ~= false,
            persist = opts.persist ~= false, content_h = 0, scroll_y = 0,
            cmds = {}, n = 0, clips = {}, alpha = 1, layer = draw.LAYER.HUD,
            seen_frame = 0, created_at = core.time(), auto_h = opts.h == nil and not opts.resizable,
        }

        local saved = win.persist and data.windows[id] or nil
        if saved then
            win.x, win.y = saved.x or x, saved.y or y
            if opts.resizable then
                win.w, win.h = saved.w or w, saved.h or h
            end
            win.collapsed = saved.collapsed or false
            if saved.visible ~= nil and opts.remember_visibility ~= false then
                win.visible = saved.visible
            end
            -- Positions were saved against a screen size; keep the same
            -- fraction of the screen when the resolution changed.
            if saved.sw and saved.sw > 0 and saved.sh and saved.sh > 0 and (saved.sw ~= F.sw or saved.sh ~= F.sh) then
                win.x = win.x * (F.sw / saved.sw)
                win.y = win.y * (F.sh / saved.sh)
            end
        end

        windows[id] = win
        z_order[#z_order + 1] = id
        return win
    end

    --- Keeps a window reachable: at least a title bar's worth stays on the
    --- screen whatever happened to the resolution or the saved position.
    local function clamp_to_screen(win)
        local sw, sh = F.sw, F.sh
        local visible_h = win.collapsed and T.title_h or win.h
        win.x = util.clamp(win.x, -win.w + 60, sw - 60)
        win.y = util.clamp(win.y, 0, max(0, sh - min(visible_h, T.title_h)))
    end

    local function snap_edges(win)
        local s = settings.snap
        if not s or s <= 0 then return end
        local sw, sh = F.sw, F.sh
        if abs(win.x) < s then win.x = 0 end
        if abs(win.y) < s then win.y = 0 end
        if abs(win.x + win.w - sw) < s then win.x = sw - win.w end
        local h = win.collapsed and T.title_h or win.h
        -- Not when the height is pinned to the screen: an auto-height
        -- window whose content overflows always ends inside the snap band,
        -- and snapping it would drag it away from the cursor every frame.
        if not win.h_capped and abs(win.y + h - sh) < s then win.y = sh - h end
    end

    local win_stack = {}

    ---@class jcore_ui_window_opts
    ---@field title? string|false  Title text; false hides the title bar
    ---@field x? number
    ---@field y? number
    ---@field w? number
    ---@field h? number  Omit for a window that grows to fit its content
    ---@field anchor? "top-left"|"top-right"|"bottom-left"|"bottom-right"|"center"|"top-center"|"bottom-center"
    ---@field movable? boolean   default true
    ---@field resizable? boolean default false
    ---@field collapsible? boolean default true
    ---@field closable? boolean  default false
    ---@field persist? boolean   default true; remember position, size, collapsed and hidden state
    ---@field remember_visibility? boolean default true
    ---@field scroll? boolean    default true; wheel-scroll the body when content overflows
    ---@field opacity? number    0.2..1, multiplied with the global opacity
    ---@field bg? any            Background colour override
    ---@field padding? number
    ---@field min_w? number
    ---@field min_h? number
    ---@field max_h? number      Cap for auto-height windows (default: screen height minus y)
    ---@field capture_mouse? boolean default true; false for a passive display that should not eat clicks
    ---@field always_on_top? boolean
    ---@field on_close? fun()
    ---@field visible? boolean   Initial visibility

    --- Starts a window. Returns true when its body should be described;
    --- ALWAYS pair with end_window, whatever it returned.
    ---@param id string
    ---@param opts? jcore_ui_window_opts
    ---@return boolean open
    ---@return table win
    function M._begin_window(facade, id, opts)
        opts = opts or {}
        local full_id = (facade._prefix or "") .. id
        local win = window_record(full_id, opts, facade.owner)
        win.opts = opts
        win.seen_frame = F.frame
        win.short_id = id
        win.facade = facade
        stats.windows = stats.windows + 1

        -- The window's own scale (1.8.10): everything in it, its popups and
        -- its tooltips at the global scale times this. end_window puts the
        -- global scale back.
        win.scale = (M.theme.scale or 1) * util.clamp(tonumber(opts.scale) or 1, 0.5, 3)
        apply_scale(win.scale)

        -- Title, geometry.
        local title = opts.title
        if title == nil then title = id end
        win.title = title
        local has_title = title ~= false
        win.has_title = has_title
        local pad = opts.padding or T.pad
        win.pad = pad
        if not opts.resizable then
            if opts.w then win.w = opts.w end
            if opts.h then win.h = opts.h; win.auto_h = false else win.auto_h = true end
        end
        win.w = max(win.w, opts.min_w or 100)

        if not win.visible or not settings.enabled then
            win.rect = nil
            P.hover_rects[full_id] = nil
            win_stack[#win_stack + 1] = { win = win, open = false }
            return false, win
        end

        clamp_to_screen(win)

        local title_h = has_title and T.title_h or 0
        local body_h = win.collapsed and 0 or (win.h - title_h)
        local total_h = win.collapsed and title_h or win.h

        -- Z-order: focus on press anywhere inside.
        local over = F.hover_win == full_id
        if over and (F.lmb_down or F.rmb_down) then
            bring_to_front(full_id)
        end
        if opts.always_on_top then bring_to_front(full_id) end

        local z = 1
        for i = 1, #z_order do
            if z_order[i] == full_id then z = i break end
        end
        win.layer = draw.LAYER.HUD + min(z, 90)

        -- Reset the paint list.
        win.cmds = {}
        win.n = 0
        win.clips = {}
        win.alpha = (opts.opacity or 1) * (M.theme.opacity or 1)
        cur = win
        win_stack[#win_stack + 1] = { win = win, open = true, prev_L = L }

        -- Title-bar interactions.
        local x, y, w = win.x, win.y, win.w
        local btn = T.title_h - 8
        local close_x = x + w - btn - 4
        local collapse_x = opts.closable and (close_x - btn - 2) or (x + w - btn - 4)
        local drag_w = w
        if has_title then
            local dragging = P.drag and P.drag.win == win and not P.drag.resize
            local uid = full_id .. "\1title"
            -- Close and collapse buttons come first so a click on them is
            -- not also a drag start.
            local wants_close, wants_collapse = false, false
            if opts.closable then
                local _, _, clicked = button_behaviour(uid .. "close", close_x, y + 4, btn, btn)
                if clicked then wants_close = true end
                drag_w = drag_w - btn - 4
            end
            if opts.collapsible ~= false then
                local _, _, clicked = button_behaviour(uid .. "collapse", collapse_x, y + 4, btn, btn)
                if clicked then wants_collapse = true end
                drag_w = drag_w - btn - 4
            end
            if wants_close then
                win.visible = false
                persist_window(win)
                if opts.on_close then pcall(opts.on_close) end
                events.emit("jcore.ui.window.closed", full_id)
            end
            if wants_collapse then
                win.collapsed = not win.collapsed
                persist_window(win)
            end

            local title_hover = hover(x, y, drag_w, title_h)
            if title_hover then F.hot = uid end
            if title_hover and opts.movable ~= false and not settings.lock_windows and not opts.lock then
                F.on_handle = true
            end
            if title_hover and F.dbl and opts.collapsible ~= false then
                win.collapsed = not win.collapsed
                persist_window(win)
            elseif title_hover and F.lmb_down and P.active == nil and opts.movable ~= false
                and not settings.lock_windows and not opts.lock then
                P.active = uid
                P.drag = { win = win, dx = F.mx - x, dy = F.my - y }
                dragging = true
            end
            if dragging then
                if F.lmb then
                    win.x = F.mx - P.drag.dx
                    win.y = F.my - P.drag.dy
                    snap_edges(win)
                    clamp_to_screen(win)
                else
                    P.drag = nil
                    P.active = nil
                    persist_window(win)
                end
            end
        end
        x, y = win.x, win.y

        -- Resize grip.
        if opts.resizable and not win.collapsed and not settings.lock_windows then
            local gs = 14
            local gx, gy = x + w - gs, y + total_h - gs
            local uid = full_id .. "\1resize"
            local resizing = P.drag and P.drag.win == win and P.drag.resize
            local grip_hover = hover(gx, gy, gs, gs)
            if grip_hover then F.on_handle = true end
            if grip_hover and F.lmb_down and P.active == nil then
                P.active = uid
                P.drag = { win = win, resize = true, ox = F.mx - win.w, oy = F.my - win.h }
                resizing = true
            end
            if resizing then
                if F.lmb then
                    win.w = max(opts.min_w or 120, F.mx - P.drag.ox)
                    win.h = max(opts.min_h or 60, F.my - P.drag.oy)
                else
                    P.drag = nil
                    P.active = nil
                    persist_window(win)
                end
            end
            w = win.w
        end
        if opts.resizable then
            -- Never bigger than the screen, nor smaller than asked: a size
            -- saved on another screen, or dragged past the edge (1.8.9).
            win.w = max(min(win.w, F.sw), opts.min_w or 120)
            win.h = max(min(win.h, F.sh), opts.min_h or 60)
            w = win.w
        end

        -- Auto height from last frame's content.
        if win.auto_h and not win.collapsed then
            local wanted = title_h + win.content_h + pad * 2
            local cap = opts.max_h or max(120, F.sh - win.y - 8)
            win.h = util.clamp(wanted, opts.min_h or (title_h + pad * 2 + 4), cap)
            win.h_capped = wanted > cap
        end
        body_h = win.collapsed and 0 or (win.h - title_h)
        total_h = win.collapsed and title_h or win.h
        win.rect = { x, y, w, total_h }
        P.hover_rects[full_id] = win.rect

        -- Chrome.
        local rounding = T.rounding
        local bg = to_color(opts.bg, M.theme.bg)
        if shader("render_drop_shadow") then
            shadow(x, y, w, total_h, rounding)
        else
            fill(x + 2, y + 3, w, total_h, M.theme.shadow, rounding)
        end
        fill(x, y, w, total_h, bg, rounding)
        if has_title then
            local glow = shader("render_linear_gradient")
            if glow then
                gradient(x, y, w, title_h, M.theme.title_glow, M.theme.bg_title, rounding)
            else
                fill(x, y, w, title_h, M.theme.bg_title, rounding)
            end
            if not win.collapsed then
                -- Square off the title bar's bottom corners.
                if glow then
                    gradient(x, y + title_h - rounding, w, rounding, M.theme.title_glow, M.theme.bg_title, 0)
                else
                    fill(x, y + title_h - rounding, w, rounding, M.theme.bg_title, 0)
                end
                line(x, y + title_h, x + w, y + title_h, M.theme.border, 1)
            end
            local focused = z_order[#z_order] == full_id
            fill(x, y, 3, title_h, focused and M.theme.accent or M.theme.accent_dim, 0)
            local label = truncate(tostring(title), T.font_title, drag_w - 16)
            text_row(label, x + 10, y, title_h, T.font_title, M.theme.text)

            if opts.collapsible ~= false then
                local cx, cy = collapse_x + btn / 2, y + 4 + btn / 2
                local hot = F.hot == full_id .. "\1titlecollapse"
                local col = hot and M.theme.text or M.theme.text_dim
                if win.collapsed then
                    tri(cx - 3, cy - 4, cx - 3, cy + 4, cx + 4, cy, col)
                else
                    tri(cx - 4, cy - 3, cx + 4, cy - 3, cx, cy + 4, col)
                end
            end
            if opts.closable then
                local cx, cy = close_x + btn / 2, y + 4 + btn / 2
                local hot = F.hot == full_id .. "\1titleclose"
                local col = hot and M.theme.danger or M.theme.text_dim
                line(cx - 4, cy - 4, cx + 4, cy + 4, col, 1.5)
                line(cx - 4, cy + 4, cx + 4, cy - 4, col, 1.5)
            end
        end
        stroke(x, y, w, total_h, z_order[#z_order] == full_id and M.theme.border_focus or M.theme.border, 1, rounding)

        if win.collapsed then
            return false, win
        end

        -- Body: clip, scroll, layout.
        local by = y + title_h
        clip_push(x, by, w, body_h)
        win.body = { x, by, w, body_h }

        local content_w = w - pad * 2
        local overflow = win.content_h + pad * 2 > body_h
        if overflow and opts.scroll ~= false then
            content_w = content_w - T.scrollbar - 2
            local max_scroll = max(0, win.content_h + pad * 2 - body_h)
            -- The wheel is applied in end_window, so a slider or list under
            -- the cursor gets first claim on it and the body only scrolls
            -- when nothing inside took the event.
            win.scroll_y = util.clamp(win.scroll_y, 0, max_scroll)
            win.max_scroll = max_scroll
        else
            win.scroll_y = 0
            win.max_scroll = 0
        end

        push_layout(x + pad, by + pad - win.scroll_y, content_w, full_id .. "/")
        L.win = win
        L.base = true
        return true, win
    end

    function M._end_window()
        local top = win_stack[#win_stack]
        if not top then return end
        win_stack[#win_stack] = nil
        local win = top.win

        if not top.open then
            cur = nil
            apply_scale()
            return
        end

        if not win.collapsed and cur == win then
            -- Unwind anything a body left open, then measure the content.
            while L and not L.base do pop_layout() end
            if L and L.base then
                local bottom = max(L.max_y, L.y, L.child_end or 0)
                win.content_h = max(0, bottom - (L.start_y) - T.gap)
                pop_layout()
            end
            while #cur.clips > 1 do clip_pop() end

            if win.max_scroll and win.max_scroll > 0 and F.hover_win == win.id
                and F.wheel ~= 0 and not P.popup and not F.wheel_claimed then
                win.scroll_y = util.clamp(win.scroll_y - F.wheel * 40, 0, win.max_scroll)
            end

            -- Scrollbar.
            if win.max_scroll and win.max_scroll > 0 and win.body then
                local bx, by, bw, bh = win.body[1], win.body[2], win.body[3], win.body[4]
                local track_h = bh - 4
                local total = win.content_h + win.pad * 2
                local thumb_h = max(16, track_h * (bh / total))
                local t = win.scroll_y / win.max_scroll
                local ty = by + 2 + (track_h - thumb_h) * t
                local tx = bx + bw - T.scrollbar - 2
                fill(tx, by + 2, T.scrollbar, track_h, M.theme.track, T.scrollbar / 2)
                fill(tx, ty, T.scrollbar, thumb_h, M.theme.text_dim, T.scrollbar / 2)
            end
            clip_pop()

            -- Resize grip glyph.
            if win.opts.resizable then
                local x, y = win.x + win.w, win.y + win.h
                local col = M.theme.text_dim
                line(x - 10, y - 3, x - 3, y - 10, col, 1)
                line(x - 6, y - 3, x - 3, y - 6, col, 1)
            end
        end

        stats.widgets = stats.widgets + 0
        stats.cmds = stats.cmds + win.n

        local cmds, n = win.cmds, win.n
        draw.submit(win.layer, function() replay(cmds, n) end)

        -- A tooltip asked for in this window is painted at its scale.
        if P.tooltip and not P.tooltip.scale then P.tooltip.scale = win.scale end
        apply_scale()

        L = top.prev_L
        cur = nil
        if #win_stack > 0 then cur = win_stack[#win_stack].win end
    end

    -- --- pseudo windows for popups and overlays -----------------------------

    local function begin_overlay(id, x, y, w, h, layer, alpha)
        local pseudo = {
            id = id, cmds = {}, n = 0, clips = {}, alpha = alpha or (M.theme.opacity or 1),
            x = x, y = y, w = w, h = h, layer = layer, pseudo = true, pad = T.pad,
        }
        cur = pseudo
        win_stack[#win_stack + 1] = { win = pseudo, open = true, prev_L = L }
        return pseudo
    end

    local function end_overlay()
        local top = win_stack[#win_stack]
        win_stack[#win_stack] = nil
        local pseudo = top.win
        while #pseudo.clips > 0 do clip_pop() end
        local cmds, n = pseudo.cmds, pseudo.n
        draw.submit(pseudo.layer, function() replay(cmds, n) end)
        L = top.prev_L
        cur = (#win_stack > 0) and win_stack[#win_stack].win or nil
    end
    M._begin_overlay = begin_overlay
    M._end_overlay = end_overlay

    -- --- popups -------------------------------------------------------------

    --- Opens a popup anchored at a screen rect. `fn(popup)` is called at
    --- the end of every frame it stays open, with the layout set to the
    --- popup's interior, and may use any widget.
    ---@param uid string
    ---@param x number
    ---@param y number
    ---@param w number
    ---@param h number
    ---@param fn fun(popup: table)
    ---@param opener? table rect of the widget that opened it
    function M.open_popup(uid, x, y, w, h, fn, opener)
        -- Keep it on the screen: flip above the opener when it would run
        -- off the bottom.
        if y + h > F.sh and opener then y = opener[2] - h end
        if x + w > F.sw then x = F.sw - w end
        if y < 0 then y = 0 end
        if x < 0 then x = 0 end
        P.popup = { uid = uid, x = x, y = y, w = w, h = h, fn = fn, opener = opener, opened = F.frame, scroll = 0,
            scale = cur and cur.scale or nil }
        P.popup_rect = { x, y, w, h }
    end

    function M.close_popup()
        P.popup = nil
        P.popup_rect = nil
    end

    ---@param uid string
    ---@return boolean
    function M.is_popup_open(uid)
        return P.popup ~= nil and P.popup.uid == uid
    end

    -- --- frame lifecycle ----------------------------------------------------

    ---@param handle boolean the cursor is on a title bar or resize grip, or a drag is on
    local function set_capture(mouse, kbd, handle)
        -- "Capture the mouse over windows" off lets clicks on a window's
        -- content reach the game. Never on its title bar or grip, nor during a
        -- drag (1.12.0): the game took the held button for a camera turn, hid
        -- the cursor and re-centred it as it neared the screen's side, and the
        -- window went back with it. The trace showed every drag uncaptured,
        -- the cursor leaping from x 2580 to 1160.
        if not settings.capture_mouse and not handle then mouse = false end
        -- Held every frame of a drag, not only on the change (1.11.0): the
        -- game must not see the button while a window follows the cursor,
        -- or it turns the camera, hides the cursor and pins it where the
        -- press was, and the window snaps back there.
        if mouse ~= P.captured_mouse or (mouse and P.drag) then
            P.captured_mouse = mouse
            pcall(core.graphics.set_mouse_capture_state, mouse)
        end
        if kbd ~= P.captured_kbd then
            P.captured_kbd = kbd
            pcall(core.graphics.set_keyboard_capture_state, kbd)
        end
    end

    local function menu_owns_cursor()
        local m = _G.menu
        if not m or not m.is_cursor_over_ui then return false end
        local ok, over = pcall(m.is_cursor_over_ui, m)
        return ok and over and true or false
    end

    --- Registered first in the render phase, right after the draw queue
    --- opens. Reads the mouse once and decides who owns it.
    function M._begin_frame()
        apply_scale()
        local now = core.time()
        F.dt = (F.t and F.t > 0) and (now - F.t) or 0
        F.t = now
        F.frame = F.frame + 1
        F.sw, F.sh = screen()
        F.hot = nil
        F.last_uid = nil
        F.last_rect = nil
        F.last_hot = false
        F.typed = nil
        F.keys = nil
        F.on_handle = false

        -- A frame the client has no cursor for answers -FLT_MAX on both
        -- axes. Taken as a position, it threw a window being dragged to the
        -- top-left corner (clamp_to_screen) and the next frame put it back
        -- under the cursor, so every drag snapped about (1.11.0). Such a
        -- frame keeps the last position: a drag holds still for it.
        local pos = input.cursor_position()
        local px, py = pos and tonumber(pos.x), pos and tonumber(pos.y)
        if px and py and abs(px) < 1e6 and abs(py) < 1e6 then F.mx, F.my = px, py end

        local lmb = input.is_key_pressed(VK.LBUTTON)
        local rmb = input.is_key_pressed(VK.RBUTTON)
        local mmb = input.is_key_pressed(VK.MBUTTON)
        F.lmb, F.rmb, F.mmb = lmb, rmb, mmb
        F.lmb_down = lmb and not P.last_lmb
        F.lmb_up = (not lmb) and P.last_lmb
        F.rmb_down = rmb and not P.last_rmb
        F.rmb_up = (not rmb) and P.last_rmb
        F.mmb_down = mmb and not P.last_mmb
        P.last_lmb, P.last_rmb, P.last_mmb = lmb, rmb, mmb
        F.wheel = input.mouse_wheel_delta() or 0
        F.wheel_claimed = false

        F.dbl = false
        if F.lmb_down then
            if now - P.last_click_t < 0.35 and abs(F.mx - P.last_click_x) < 6 and abs(F.my - P.last_click_y) < 6 then
                F.dbl = true
                P.last_click_t = 0
            else
                P.last_click_t = now
            end
            P.last_click_x, P.last_click_y = F.mx, F.my
        end

        -- Who owns the mouse this frame. The game's own menu wins outright;
        -- then the modal, then an open popup, then the topmost window under
        -- the cursor by last frame's rectangles.
        F.blocked = false
        F.hover_win = nil
        if not settings.enabled then
            F.blocked = true
        elseif menu_owns_cursor() then
            F.blocked = true
        elseif P.modal then
            local r = P.modal_rect
            if r and inside(r[1], r[2], r[3], r[4], F.mx, F.my) then
                F.hover_win = "\1modal"
            else
                F.blocked = true
            end
        elseif P.popup_rect and inside(P.popup_rect[1], P.popup_rect[2], P.popup_rect[3], P.popup_rect[4], F.mx, F.my) then
            F.hover_win = "\1popup"
        elseif P.drag then
            F.hover_win = P.drag.win.id
        else
            for i = #z_order, 1, -1 do
                local id = z_order[i]
                local r = P.hover_rects[id]
                if r and inside(r[1], r[2], r[3], r[4], F.mx, F.my) then
                    local win = windows[id]
                    if win and win.visible and win.seen_frame >= F.frame - 2 then
                        F.hover_win = id
                        break
                    end
                end
            end
        end

        -- A press that lands nowhere clears the focus and closes the popup.
        if F.lmb_down or F.rmb_down then
            if F.hover_win ~= "\1popup" and P.popup then
                local o = P.popup.opener
                if not (o and inside(o[1], o[2], o[3], o[4], F.mx, F.my)) then
                    M.close_popup()
                end
            end
            if F.hover_win == nil and not F.blocked then
                P.focus = nil
                P.listening = nil
            end
        end

        -- The button holder vanished (its window closed mid-press). Not on
        -- the release edge itself: the widget that took the press sees
        -- `held and F.lmb_up` later this frame, and that is its click.
        if P.active and not F.lmb and not F.lmb_up then
            P.active = nil
        end

        if P.focus or P.listening then
            if input.is_typing() then
                -- The game's own chat box has the keyboard; do not fight it.
                P.focus = nil
                P.listening = nil
            elseif P.focus then
                -- Only a text field wants typed characters. A keybind that
                -- is listening scans for itself (first_new_key), and polling
                -- here first would mark every letter as already down before
                -- that scan saw it, so no letter could ever be bound.
                poll_keyboard(now)
            end
        end

        -- Windows that stopped being described (their plugin unloaded or
        -- hid them without a call) drop out of the hover pass.
        for id, win in pairs(windows) do
            if win.seen_frame < F.frame - 120 then
                P.hover_rects[id] = nil
            end
        end

        stats.windows, stats.widgets, stats.cmds, stats.popups = 0, 0, 0, 0
        P.tooltip = nil
    end

    local end_frame_hooks = {}

    --- Lets ui_widgets and friends paint frame-level overlays (toasts, the
    --- modal) without this file knowing them.
    function M._on_end_frame(fn)
        end_frame_hooks[#end_frame_hooks + 1] = fn
    end

    --- Registered last in the render phase, just before the draw queue
    --- flushes. Paints the popup, tooltip and overlays, then settles input
    --- capture.
    function M._end_frame()
        -- Unbalanced begin/end pairs from a plugin that raised mid-body.
        while #win_stack > 0 do
            local top = win_stack[#win_stack]
            if top.win.pseudo then end_overlay() else M._end_window() end
        end

        local popup = P.popup
        if popup then
            stats.popups = stats.popups + 1
            local layer = draw.LAYER.TOOLTIP + 2
            apply_scale(popup.scale)
            begin_overlay("\1popup", popup.x, popup.y, popup.w, popup.h, layer)
            if shader("render_drop_shadow") then
                shadow(popup.x, popup.y, popup.w, popup.h, T.rounding)
            else
                fill(popup.x + 2, popup.y + 3, popup.w, popup.h, M.theme.shadow, T.rounding)
            end
            fill(popup.x, popup.y, popup.w, popup.h, M.theme.bg_elevated, T.rounding)
            stroke(popup.x, popup.y, popup.w, popup.h, M.theme.border, 1, T.rounding)
            clip_push(popup.x, popup.y, popup.w, popup.h)
            push_layout(popup.x + 4, popup.y + 4 - (popup.scroll or 0), popup.w - 8, popup.uid .. "\1p/")
            local ok, err = pcall(popup.fn, popup)
            if not ok then
                log.fmt("error", "popup %s failed: %s", popup.uid, tostring(err))
                M.close_popup()
            end
            while L and L.prefix ~= popup.uid .. "\1p/" do pop_layout() end
            pop_layout()
            clip_pop()
            end_overlay()
            if P.popup == popup then
                P.popup_rect = { popup.x, popup.y, popup.w, popup.h }
            end
            if P.tooltip and not P.tooltip.scale then P.tooltip.scale = popup.scale end
            apply_scale()
        end

        for i = 1, #end_frame_hooks do
            local ok, err = pcall(end_frame_hooks[i])
            if not ok then log.fmt("error", "ui overlay hook failed: %s", tostring(err)) end
        end

        local tip = P.tooltip
        if tip then
            apply_scale(tip.scale)
            local size = T.font_small
            local lines = wrap(tip.text, size, floor(260 * (applied_scale or 1)))
            local tw = 0
            for i = 1, #lines do tw = max(tw, text_w(lines[i], size)) end
            local w, h = tw + 16, #lines * (size + 4) + 10
            local x, y = F.mx + 14, F.my + 18
            if x + w > F.sw then x = F.mx - w - 6 end
            if y + h > F.sh then y = F.my - h - 6 end
            begin_overlay("\1tip", x, y, w, h, draw.LAYER.TOOLTIP + 4)
            fill(x, y, w, h, M.theme.bg_elevated, T.rounding)
            stroke(x, y, w, h, M.theme.border, 1, T.rounding)
            for i = 1, #lines do
                text(lines[i], x + 8, y + 5 + (i - 1) * (size + 4), size, M.theme.text)
            end
            end_overlay()
            apply_scale()
        end

        -- Capture: mouse while over any of our surfaces, keyboard while a
        -- field or a key capture has focus. Released the moment neither holds.
        local over = (F.hover_win ~= nil) or (P.drag ~= nil)
        if over and F.hover_win and F.hover_win ~= "\1popup" and F.hover_win ~= "\1modal" then
            local win = windows[F.hover_win]
            if win and win.opts and win.opts.capture_mouse == false then over = false end
        end
        set_capture(over, (P.focus ~= nil) or (P.listening ~= nil), P.drag ~= nil or F.on_handle == true)
    end

    -- --- facade -------------------------------------------------------------
    --
    -- Every widget is a method on the facade so `ctx.ui:button(...)` reads
    -- naturally and the owner travels with the handle. The module itself is
    -- a facade with no owner, for code that reaches it through _G.JCore.ui.

    local Facade = {}
    Facade.__index = Facade
    M.Facade = Facade

    ---@param owner? string plugin id; windows and state are namespaced by it
    ---@return table
    function M.for_owner(owner)
        return setmetatable({ owner = owner, _prefix = owner and (owner .. ":") or "" }, Facade)
    end

    ---@param id string
    ---@param opts? jcore_ui_window_opts
    ---@return boolean open
    function Facade:begin_window(id, opts)
        return M._begin_window(self, id, opts)
    end

    function Facade:end_window()
        return M._end_window()
    end

    --- Declares a window once; the toolkit calls `body(ui, handle)` every
    --- frame the window is visible. The plugin never registers a render job.
    ---@param id string
    ---@param opts? jcore_ui_window_opts
    ---@param body fun(ui: table, handle: table)
    ---@return table handle show/hide/toggle/is_visible/remove/set
    function Facade:window(id, opts, body)
        opts = opts or {}
        local full_id = self._prefix .. id
        local existing = retained[full_id]
        if existing then existing.remove() end

        local handle = { id = full_id, short_id = id, opts = opts }
        local facade = self
        handle.job = scheduler.add("render", function()
            local open = M._begin_window(facade, id, handle.opts)
            if open then
                local ok, err = pcall(body, facade, handle)
                if not ok then log.fmt("error", "window %s body failed: %s", full_id, tostring(err)) end
            end
            M._end_window()
        end, { owner = self.owner or "jcore.ui", priority = opts.priority or 400 })

        function handle.show()
            local win = windows[full_id]
            if win then win.visible = true; persist_window(win); bring_to_front(full_id)
            else handle.opts.visible = true end
        end
        function handle.hide()
            local win = windows[full_id]
            if win then win.visible = false; persist_window(win) else handle.opts.visible = false end
        end
        function handle.toggle()
            local win = windows[full_id]
            if win and win.visible then handle.hide() else handle.show() end
        end
        function handle.is_visible()
            local win = windows[full_id]
            return win and win.visible or false
        end
        function handle.remove()
            scheduler.remove(handle.job)
            retained[full_id] = nil
            P.hover_rects[full_id] = nil
        end
        function handle.set(new_opts)
            util.deep_merge(handle.opts, new_opts or {})
        end
        function handle.get(widget_id) return M.get_value(full_id, widget_id) end
        function handle.set_value(widget_id, v) return M.set_value(full_id, widget_id, v) end
        function handle.on_change(widget_id, fn) return M.on_change(full_id, widget_id, fn) end
        retained[full_id] = handle
        return handle
    end

    -- Window control by id, from anywhere.

    local function resolve_window_id(facade, id)
        if windows[id] then return id end
        local full = (facade and facade._prefix or "") .. id
        if windows[full] then return full end
        return full
    end

    function Facade:show(id)
        local wid = resolve_window_id(self, id)
        local win = windows[wid]
        if win then win.visible = true; persist_window(win); bring_to_front(wid); return true end
        local h = retained[wid]
        if h then h.show() return true end
        return false
    end

    function Facade:hide(id)
        local wid = resolve_window_id(self, id)
        local win = windows[wid]
        if win then win.visible = false; persist_window(win); return true end
        local h = retained[wid]
        if h then h.hide() return true end
        return false
    end

    function Facade:toggle(id)
        local wid = resolve_window_id(self, id)
        local win = windows[wid]
        if win and win.visible then return self:hide(id) end
        return self:show(id)
    end

    function Facade:is_visible(id)
        local win = windows[resolve_window_id(self, id)]
        return win and win.visible or false
    end

    function Facade:set_position(id, x, y)
        local win = windows[resolve_window_id(self, id)]
        if not win then return false end
        win.x, win.y = x, y
        persist_window(win)
        return true
    end

    --- Sets a window's size and remembers it (1.8.10). A resizable window
    --- takes it as if dragged to it, still within the screen and its least
    --- size; any other gets its options' size back on the next frame.
    function Facade:set_size(id, w, h)
        local win = windows[resolve_window_id(self, id)]
        if not win then return false end
        if tonumber(w) then win.w = tonumber(w) end
        if tonumber(h) then win.h = tonumber(h) end
        persist_window(win)
        return true
    end

    function Facade:set_collapsed(id, collapsed)
        local win = windows[resolve_window_id(self, id)]
        if not win then return false end
        win.collapsed = collapsed and true or false
        persist_window(win)
        return true
    end

    --- Forgets every saved position and size. Windows re-anchor next frame.
    function M.reset_layout()
        data.windows = {}
        store:touch()
        for id, win in pairs(windows) do
            local opts = win.opts or {}
            win.w = opts.w or win.w
            win.h = opts.h or win.h
            win.x, win.y = anchored_position(opts, win.w, win.h)
            win.collapsed = false
            win.scroll_y = 0
        end
    end

    --- Every window the toolkit knows, for diagnostics and a window list.
    function M.windows()
        local out = {}
        for i = 1, #z_order do
            local win = windows[z_order[i]]
            if win then
                out[#out + 1] = {
                    id = win.id, title = win.title, owner = win.owner, visible = win.visible,
                    collapsed = win.collapsed, x = win.x, y = win.y, w = win.w, h = win.h,
                    live = win.seen_frame >= F.frame - 2,
                }
            end
        end
        return out
    end

    --- Drops every window, retained job and stored value that belongs to a
    --- plugin. Called by the registry when the plugin unregisters.
    ---@param owner string
    function M.remove_owner(owner)
        if not owner then return end
        local prefix = owner .. ":"
        for id, win in pairs(windows) do
            if win.owner == owner or id:sub(1, #prefix) == prefix then
                windows[id] = nil
                util.array_remove(z_order, id)
                P.hover_rects[id] = nil
            end
        end
        for id, handle in pairs(retained) do
            if id:sub(1, #prefix) == prefix then
                scheduler.remove(handle.job)
                retained[id] = nil
            end
        end
        for uid in pairs(S) do
            if uid:sub(1, #prefix) == prefix then S[uid] = nil end
        end
    end

    -- --- value access -------------------------------------------------------

    local function full_uid(window_id, widget_id)
        return window_id .. "/" .. tostring(widget_id)
    end

    ---@param window_id string full window id (owner:id)
    ---@param widget_id string
    function M.get_value(window_id, widget_id)
        local uid = full_uid(window_id, widget_id)
        local st = S[uid]
        if st and st.init then return st.v end
        return data.values[uid]
    end

    ---@param window_id string
    ---@param widget_id string
    ---@param v any
    function M.set_value(window_id, widget_id, v)
        return set_value(full_uid(window_id, widget_id), v)
    end

    ---@param window_id string
    ---@param widget_id string
    ---@param fn fun(new_value: any, old_value: any)
    function M.on_change(window_id, widget_id, fn)
        local uid = full_uid(window_id, widget_id)
        OBS[uid] = OBS[uid] or {}
        OBS[uid][#OBS[uid] + 1] = fn
        return true
    end

    --- Window-scoped reads for a facade: `ui:get("hud", "auto")`.
    function Facade:get(window_id, widget_id)
        return M.get_value(resolve_window_id(self, window_id), widget_id)
    end

    function Facade:set(window_id, widget_id, v)
        return M.set_value(resolve_window_id(self, window_id), widget_id, v)
    end

    function Facade:on_change(window_id, widget_id, fn)
        return M.on_change(resolve_window_id(self, window_id), widget_id, fn)
    end

    -- --- layout widgets -----------------------------------------------------

    --- Starts a horizontal row. `widths` lists a share per column: a number
    --- in (0, 1] is a fraction of the width, above 1 is pixels, and 0 takes
    --- an equal share of what is left. Widgets that follow fill the columns
    --- in order; end the row with end_row().
    ---@param widths? number[]|integer  Column shares, or a count of equal columns
    ---@param opts? { gap?: number }
    function Facade:row(widths, opts)
        if type(widths) == "number" then
            local n = widths
            widths = {}
            for i = 1, n do widths[i] = 0 end
        end
        widths = widths or { 0, 0 }
        local gap = opts and opts.gap or T.gap
        local x = L.x + L.indent
        local w = L.w - L.indent
        local fixed, autos = 0, 0
        for i = 1, #widths do
            local s = widths[i]
            if s > 1 then fixed = fixed + s
            elseif s > 0 then fixed = fixed + s * w
            else autos = autos + 1 end
        end
        local avail = w - gap * (#widths - 1)
        local auto_w = autos > 0 and max(10, (avail - fixed) / autos) or 0
        local cols = {}
        local cx = x
        for i = 1, #widths do
            local s = widths[i]
            local cw = s > 1 and s or (s > 0 and s * w or auto_w)
            cols[i] = { x = cx, w = cw }
            cx = cx + cw + gap
        end
        L.row = { cols = cols, i = 1, y = L.y, max_h = 0 }
        return self
    end

    function Facade:end_row()
        local row = L.row
        if not row then return self end
        L.row = nil
        L.y = row.y + row.max_h + T.gap
        L.max_y = max(L.max_y, L.y)
        return self
    end

    --- Row of `n` equal columns.
    function Facade:columns(n)
        return self:row(n)
    end

    --- Skips the current column in a row.
    function Facade:skip()
        if L.row then L.row.i = L.row.i + 1 end
        return self
    end

    ---@param px? number
    function Facade:indent(px)
        L.indent = L.indent + (px or 16)
        return self
    end

    function Facade:unindent(px)
        L.indent = max(0, L.indent - (px or 16))
        return self
    end

    ---@param h? number
    function Facade:spacer(h)
        place(h or T.gap)
        return self
    end

    ---@param label? string
    function Facade:separator(label)
        local x, y, w, h = place(label and (T.font_small + 6) or 7)
        local ly = y + h / 2
        if label and shader("render_linear_gradient") then
            -- A plate fading out to the right, with an accent underline.
            gradient(x, y + 1, w, h - 2, M.theme.header, M.theme.clear, T.rounding)
            gradient(x, y + h - 2, floor(w * 0.6), 1, M.theme.accent, M.theme.clear, 0)
            text_row(label, x + 6, y, h, T.font_small, M.theme.text)
        elseif label then
            local lw = text_w(label, T.font_small)
            text_row(label, x, y, h, T.font_small, M.theme.text_dim)
            line(x + lw + 8, ly, x + w, ly, M.theme.border, 1)
        else
            line(x, ly, x + w, ly, M.theme.border, 1)
        end
        return self
    end

    --- A collapsible group with a header. Returns whether its body is open;
    --- ALWAYS call end_group after, open or not.
    ---@param id string
    ---@param title? string
    ---@param opts? { collapsible?: boolean, default_open?: boolean, border?: boolean, persist?: boolean }
    ---@return boolean open
    function Facade:group(id, title, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, open = value_of(uid .. "\1open", opts.default_open ~= false, opts.persist ~= false)
        local collapsible = opts.collapsible ~= false and title ~= nil
        local head_h = title and T.row or 0
        local x, y, w = L.x + L.indent, L.y, L.w - L.indent

        if title then
            local hovered, _, clicked = button_behaviour(uid .. "\1head", x, y, w, head_h, not collapsible)
            if clicked then
                open = not open
                set_value(uid .. "\1open", open)
            end
            fill(x, y, w, head_h, hovered and M.theme.bg_hover or M.theme.bg_elevated, T.rounding)
            if collapsible then
                local cx, cy = x + 10, y + head_h / 2
                if open then
                    tri(cx - 4, cy - 2, cx + 4, cy - 2, cx, cy + 3, M.theme.text_dim)
                else
                    tri(cx - 2, cy - 4, cx - 2, cy + 4, cx + 3, cy, M.theme.text_dim)
                end
            end
            text_row(truncate(title, T.font_body, w - 28), x + (collapsible and 20 or 8), y, head_h, T.font_body, M.theme.text)
        end

        -- The group scope: indented body; its extent is measured at end_group.
        local inner = push_layout(x, y + head_h + (title and T.gap or 0), w, uid .. "/")
        inner.group = { x = x, y = y, w = w, head_h = head_h, border = opts.border, open = open, has_title = title ~= nil }
        inner.x = x + (title and 8 or 0)
        inner.w = w - (title and 16 or 0)
        if not open then
            -- Closed: nothing inside paints; the scope only exists so
            -- end_group pops symmetrically.
            inner.closed = true
        end
        return open
    end

    function Facade:end_group()
        local inner = L
        if not inner or not inner.group then return self end
        local g = inner.group
        local bottom = inner.closed and (g.y + g.head_h) or max(inner.max_y, inner.y, inner.child_end or 0)
        pop_layout()
        if not inner.closed then
            local h = bottom - g.y
            if g.border ~= false and g.has_title then
                stroke(g.x, g.y, g.w, h - T.gap + 4, M.theme.border, 1, T.rounding)
            end
            L.y = bottom + 4
        else
            L.y = g.y + g.head_h + T.gap
        end
        L.child_end = nil
        L.max_y = max(L.max_y, L.y)
        return self
    end

    --- The scrollbar of a region: track and thumb, in screen pixels.
    local function scroll_bar_geometry(x, y, w, h, content_h, scroll, max_scroll)
        local track_h = h - 4
        local thumb_h = min(track_h, max(14, track_h * (h / max(1, content_h))))
        local t = max_scroll > 0 and (scroll / max_scroll) or 0
        return x + w - T.scrollbar - 1, y + 2, track_h, thumb_h, y + 2 + (track_h - thumb_h) * t
    end

    --- A fixed-height region whose content scrolls with the wheel. Pair
    --- with end_scroll.
    ---
    --- Since 1.8.9 its scrollbar can be dragged, a press on the track jumps
    --- there, and the wheel goes to the widget under the cursor first (a
    --- code box, a list, a nested region): the region scrolls only when
    --- nothing inside took it, as a window body always did.
    ---@param id string
    ---@param h number
    function Facade:scroll(id, h)
        local uid = uid_for(id)
        local x, y, w = place(h)
        local st = state_for(uid)
        local content_h = st.content_h or 0
        local max_scroll = content_h - h
        -- A region sized to fit its content exactly can come out a hair
        -- over in floating point; that is not worth a scrollbar.
        if max_scroll < 1 then max_scroll = 0 end
        st.scroll = util.clamp(st.scroll or 0, 0, max_scroll)
        st.bar_hot = false
        if max_scroll > 0 then
            -- The bar is claimed before the content is described, so a press
            -- on it is never also a press on a widget under it.
            local tx, ty, track_h, thumb_h, thumb_y = scroll_bar_geometry(x, y, w, h, content_h, st.scroll, max_scroll)
            local hovered, held = button_behaviour(uid .. "\1bar", tx - 3, y, T.scrollbar + 4, h)
            if held and F.lmb then
                if not st.grab then
                    -- On the thumb: hold it where it was taken. On the
                    -- track: centre the thumb on the cursor.
                    local on_thumb = F.my >= thumb_y and F.my <= thumb_y + thumb_h
                    st.grab = on_thumb and (F.my - thumb_y) or (thumb_h / 2)
                end
                local room = max(1, track_h - thumb_h)
                st.scroll = util.clamp((F.my - st.grab - ty) / room, 0, 1) * max_scroll
            else
                st.grab = nil
            end
            st.bar_hot = hovered or held
        else
            st.grab = nil
        end
        local inner_w = w
        if max_scroll > 0 then inner_w = w - T.scrollbar - 2 end
        clip_push(x, y, w, h)
        local inner = push_layout(x, y - st.scroll, inner_w, uid .. "/")
        inner.scroll = { st = st, x = x, y = y, w = w, h = h, max_scroll = max_scroll }
        return self
    end

    function Facade:end_scroll()
        local inner = L
        if not inner or not inner.scroll then return self end
        local s = inner.scroll
        local bottom = max(inner.max_y, inner.y, inner.child_end or 0)
        s.st.content_h = bottom - inner.start_y - T.gap
        pop_layout()
        -- The region reserved its height with place(); its inner extent
        -- must not inflate the enclosing window's content height.
        L.child_end = nil
        -- The wheel, after the content: whatever inside is under the cursor
        -- and scrolls has claimed it by now.
        if s.max_scroll > 0 and F.wheel ~= 0 and not P.popup and not F.wheel_claimed
            and hover(s.x, s.y, s.w, s.h) then
            s.st.scroll = util.clamp(s.st.scroll - F.wheel * 40, 0, s.max_scroll)
            F.wheel_claimed = true
        end
        if s.max_scroll > 0 then
            local tx, ty, track_h, thumb_h, thumb_y = scroll_bar_geometry(s.x, s.y, s.w, s.h, s.st.content_h,
                s.st.scroll, s.max_scroll)
            fill(tx, ty, T.scrollbar, track_h, M.theme.track, T.scrollbar / 2)
            fill(tx, thumb_y, T.scrollbar, thumb_h, s.st.bar_hot and M.theme.text or M.theme.text_dim, T.scrollbar / 2)
        end
        clip_pop()
        return self
    end

    --- Where the next widget goes in the current scope, and the room left
    --- below it down to the bottom of the enclosing scroll region or window
    --- body: a pane that fills the rest of a resizable window asks for
    --- `select(4, ui:avail())` as its height (1.8.9).
    ---@return number x
    ---@return number y
    ---@return number w
    ---@return number h_left
    function Facade:avail()
        local x, y, w = L.x + L.indent, L.y, L.w - L.indent
        if L.row then
            local col = L.row.cols[min(L.row.i, #L.row.cols)]
            x, y, w = col.x, L.row.y, col.w
        end
        local s = L
        while s do
            if s.scroll then
                return x, y, w, max(0, s.scroll.y + s.scroll.h - y)
            end
            if s.base and s.win and s.win.body then
                local b = s.win.body
                return x, y, w, max(0, b[2] + b[4] - (s.win.pad or T.pad) - y)
            end
            s = s.parent
        end
        return x, y, w, 0
    end

    --- The toolkit's metrics at the current scale, for a layout that adds
    --- heights up itself (1.8.9). `scale` is the one in force: the global
    --- scale, times the window's own inside a window that has one (1.8.10).
    ---@return { pad: number, gap: number, row: number, title_h: number, scrollbar: number, font_small: number, font_body: number, scale: number }
    function Facade:metrics()
        return {
            pad = T.pad, gap = T.gap, row = T.row, title_h = T.title_h, scrollbar = T.scrollbar,
            font_small = T.font_small, font_body = T.font_body, scale = applied_scale or 1,
        }
    end

    -- --- text widgets -------------------------------------------------------

    ---@class jcore_ui_text_opts
    ---@field color? any   theme key, {r,g,b,a} or colour object
    ---@field size? number|"title"|"body"|"small"|"micro"
    ---@field align? "left"|"center"|"right"
    ---@field wrap? boolean  default true
    ---@field bold? boolean  (drawn with a one-pixel shadow for weight)

    local function font_size(v)
        if type(v) == "number" then return floor(v * (applied_scale or M.theme.scale or 1) + 0.5) end
        if v == "title" then return T.font_title end
        if v == "small" then return T.font_small end
        if v == "micro" then return T.font_micro end
        return T.font_body
    end
    M.font_size = font_size

    ---@param s string
    ---@param opts? jcore_ui_text_opts
    function Facade:text(s, opts)
        opts = opts or {}
        s = tostring(s == nil and "" or s)
        local size = font_size(opts.size)
        local col = to_color(opts.color, M.theme.text)
        local w = L.row and L.row.cols[min(L.row.i, #L.row.cols)].w or (L.w - L.indent)
        local lines = (opts.wrap ~= false and (s:find("\n", 1, true) or text_w(s, size) > w)) and wrap(s, size, w) or { s }
        local line_h = size + 5
        local x, y, ww = place(#lines * line_h)
        for i = 1, #lines do
            local ly = y + (i - 1) * line_h
            local ls = opts.wrap == false and truncate(lines[i], size, ww) or lines[i]
            if opts.bold then
                text_row(ls, x + 1, ly + 1, line_h, size, M.theme.shadow, opts.align, ww)
            end
            text_row(ls, x, ly, line_h, size, col, opts.align, ww)
        end
        return self
    end

    Facade.label = Facade.text

    ---@param s string
    ---@param opts? jcore_ui_text_opts
    function Facade:heading(s, opts)
        opts = opts or {}
        opts.size = opts.size or "title"
        opts.bold = opts.bold ~= false
        return self:text(s, opts)
    end

    --- Text from a provider, evaluated every frame. Sugar; text(fn()) is the
    --- same thing, but this keeps the declarative front honest.
    ---@param fn fun(): string
    ---@param opts? jcore_ui_text_opts
    function Facade:live(fn, opts)
        local ok, s = pcall(fn)
        return self:text(ok and s or ("<" .. tostring(s) .. ">"), opts)
    end

    --- Two-column "key   value" row.
    ---@param k string
    ---@param v any
    ---@param opts? { color?: any, key_color?: any, size?: any }
    function Facade:key_value(k, v, opts)
        opts = opts or {}
        local size = font_size(opts.size)
        local x, y, w, h = place(size + 6)
        text_row(tostring(k), x, y, h, size, to_color(opts.key_color, M.theme.text_dim))
        text_row(truncate(tostring(v), size, w * 0.6), x, y, h, size, to_color(opts.color, M.theme.text), "right", w)
        return self
    end

    -- --- buttons ------------------------------------------------------------

    ---@class jcore_ui_button_opts
    ---@field style? "default"|"primary"|"danger"|"ghost"|"success"
    ---@field w? number   width; default fills the column
    ---@field h? number
    ---@field disabled? boolean
    ---@field tooltip? string
    ---@field icon? string   asset reference drawn before the label
    ---@field align? "left"|"center"
    ---@field size? any

    ---@param id string
    ---@param label string
    ---@param opts? jcore_ui_button_opts
    ---@return boolean clicked
    function Facade:button(id, label, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local h = opts.h or T.widget_h
        local x, y, w = place(h)
        if opts.w then w = min(w, opts.w) end
        local hovered, held, clicked = button_behaviour(uid, x, y, w, h, opts.disabled)

        local style = opts.style or "default"
        local bg, fg, border
        if style == "primary" then
            bg, fg = M.theme.accent, M.theme.accent_text
        elseif style == "danger" then
            bg, fg = M.theme.danger, M.theme.accent_text
        elseif style == "success" then
            bg, fg = M.theme.success, M.theme.accent_text
        elseif style == "ghost" then
            bg, fg, border = nil, M.theme.text, M.theme.border
        else
            bg, fg = M.theme.bg_elevated, M.theme.text
        end
        if opts.disabled then
            fg = M.theme.text_disabled
        elseif held then
            bg = bg and M.theme.bg_active or M.theme.bg_active
        elseif hovered then
            bg = (style == "default" or style == "ghost") and M.theme.bg_hover or bg
        end
        if bg then fill(x, y, w, h, bg, T.rounding) end
        if border then stroke(x, y, w, h, border, 1, T.rounding) end
        if hovered and style ~= "ghost" then stroke(x, y, w, h, M.theme.border_focus, 1, T.rounding) end

        local size = font_size(opts.size)
        local tx = x
        local avail = w - 12
        if opts.icon then
            local isz = h - 6
            image(opts.icon, x + 6, y + 3, isz, isz, nil)
            tx = tx + isz + 4
            avail = avail - isz - 4
        end
        local s = truncate(tostring(label), size, avail)
        if opts.align == "left" then
            text_row(s, tx + 8, y, h, size, fg)
        else
            text_row(s, tx, y, h, size, fg, "center", w - (tx - x))
        end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        if clicked and opts.on_click then pcall(opts.on_click) end
        return clicked
    end

    --- Square button showing an asset, with an optional caption below.
    ---@param id string
    ---@param ref string asset reference
    ---@param opts? { size?: number, label?: string, tooltip?: string, disabled?: boolean, selected?: boolean, tint?: any }
    ---@return boolean clicked
    function Facade:icon_button(id, ref, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local size = opts.size or 32
        local cap_h = opts.label and (T.font_small + 4) or 0
        local x, y, w = place(size + 8 + cap_h)
        local bx = x + max(0, (w - size - 8) / 2)
        local hovered, held, clicked = button_behaviour(uid, bx, y, size + 8, size + 8 + cap_h, opts.disabled)
        local bg = held and M.theme.bg_active or (hovered and M.theme.bg_hover) or (opts.selected and M.theme.accent_dim) or M.theme.bg_elevated
        fill(bx, y, size + 8, size + 8, bg, T.rounding)
        if opts.selected or hovered then stroke(bx, y, size + 8, size + 8, M.theme.border_focus, 1, T.rounding) end
        local ready = assets.request(ref)
        if ready then
            image(ref, bx + 4, y + 4, size, size, to_color(opts.tint, nil))
        else
            local e = assets.get(ref)
            local col = (e and e.state == "failed") and M.theme.danger or M.theme.text_dim
            stroke(bx + 4, y + 4, size, size, col, 1, 2)
            text_row(e and e.state == "failed" and "!" or "..", bx + 4, y + 4, size, T.font_small, col, "center", size)
        end
        if opts.label then
            text_row(truncate(opts.label, T.font_small, w), x, y + size + 8, cap_h, T.font_small, M.theme.text_dim, "center", w)
        end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return clicked
    end

    -- --- toggles ------------------------------------------------------------

    local function toggle_common(self, id, label, default, opts, checkbox)
        opts = opts or {}
        local uid = uid_for(id)
        local st, v = value_of(uid, default and true or false, opts.persist)
        local h = T.widget_h
        local x, y, w = place(h)
        local hovered, held, clicked = button_behaviour(uid, x, y, w, h, opts.disabled)
        if clicked then
            v = not v
            set_value(uid, v)
        end
        if F.rmb_down and hovered then
            v = st.default
            set_value(uid, v)
        end
        -- Eased knob position.
        st.anim = st.anim or (v and 1 or 0)
        local target = v and 1 or 0
        st.anim = st.anim + (target - st.anim) * min(1, F.dt * 14)
        if abs(st.anim - target) < 0.01 then st.anim = target end

        local fg = opts.disabled and M.theme.text_disabled or M.theme.text
        if shader("render_hover_pill") then
            local amount = ease_hover(st, hovered)
            if amount > 0 then pill(x, y, w, h, amount, T.rounding) end
        elseif hovered then
            fill(x, y, w, h, M.theme.zebra, T.rounding)
        end
        text_row(truncate(tostring(label), T.font_body, w - 46), x + 4, y, h, T.font_body, fg)

        if checkbox then
            local bs = h - 8
            local bx, by = x + w - bs - 4, y + 4
            fill(bx, by, bs, bs, v and M.theme.accent or M.theme.bg_input, 3)
            stroke(bx, by, bs, bs, hovered and M.theme.border_focus or M.theme.border, 1, 3)
            if st.anim > 0.3 then
                local cx, cy = bx + bs / 2, by + bs / 2
                line(cx - 4, cy, cx - 1, cy + 3, M.theme.accent_text, 2)
                line(cx - 1, cy + 3, cx + 4, cy - 3, M.theme.accent_text, 2)
            end
        else
            local tw, th = 30, h - 8
            local tx, ty = x + w - tw - 4, y + 4
            local on_col = opts.disabled and M.theme.text_disabled or M.theme.accent
            if v and not opts.disabled and shader("render_linear_gradient") then
                gradient(tx, ty, tw, th, M.theme.accent_lo, M.theme.accent_hi, th / 2)
            else
                fill(tx, ty, tw, th, v and on_col or M.theme.track, th / 2)
            end
            local kx = tx + 2 + (tw - th) * st.anim
            circle_fill(kx + (th - 4) / 2, ty + th / 2, (th - 4) / 2, M.theme.accent_text)
        end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return v, clicked
    end

    ---@class jcore_ui_value_opts
    ---@field persist? boolean  remember the value across sessions
    ---@field disabled? boolean
    ---@field tooltip? string

    --- A switch. Returns the value; second result is true on the frame it changed.
    ---@param id string
    ---@param label string
    ---@param default? boolean
    ---@param opts? jcore_ui_value_opts
    ---@return boolean value
    ---@return boolean changed
    function Facade:toggle(id, label, default, opts)
        return toggle_common(self, id, label, default, opts, false)
    end

    ---@param id string
    ---@param label string
    ---@param default? boolean
    ---@param opts? jcore_ui_value_opts
    ---@return boolean value
    ---@return boolean changed
    function Facade:checkbox(id, label, default, opts)
        return toggle_common(self, id, label, default, opts, true)
    end

    -- --- slider -------------------------------------------------------------

    ---@class jcore_ui_slider_opts: jcore_ui_value_opts
    ---@field step? number
    ---@field integer? boolean
    ---@field suffix? string
    ---@field format? string  string.format pattern for the readout

    ---@param id string
    ---@param label string
    ---@param lo number
    ---@param hi number
    ---@param default number
    ---@param opts? jcore_ui_slider_opts
    ---@return number value
    ---@return boolean changed
    function Facade:slider(id, label, lo, hi, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local integer = opts.integer
        if integer == nil then integer = (opts.step == nil) and ((hi - lo) >= 2) end
        local step = opts.step or (integer and 1 or 0)
        local st, v = value_of(uid, default or lo, opts.persist)
        v = util.clamp(tonumber(v) or lo, lo, hi)

        local h = T.widget_h + T.font_small + 4
        local x, y, w = place(h)
        local track_y = y + T.font_small + 8
        local track_h = 6
        local hovered = not opts.disabled and hover(x, y, w, h)
        if hovered then F.hot = uid end

        local changed = false
        local dragging = P.active == uid
        if hovered and F.lmb_down and P.active == nil then
            P.active = uid
            dragging = true
        end
        if dragging then
            if F.lmb then
                local t = util.clamp((F.mx - x) / max(1, w), 0, 1)
                local nv = lo + (hi - lo) * t
                if step > 0 then nv = lo + floor((nv - lo) / step + 0.5) * step end
                if integer then nv = floor(nv + 0.5) end
                nv = util.clamp(nv, lo, hi)
                if nv ~= v then
                    v = nv
                    changed = set_value(uid, v)
                end
            else
                P.active = nil
            end
        end
        if hovered and F.rmb_down then
            v = st.default
            changed = set_value(uid, v)
        end
        if hovered and F.wheel ~= 0 and not P.popup and not opts.no_wheel then
            F.wheel_claimed = true
            local inc = step > 0 and step or (hi - lo) / 100
            v = util.clamp(v + F.wheel * inc, lo, hi)
            if integer then v = floor(v + 0.5) end
            changed = set_value(uid, v)
        end
        F.last_rect = { x, y, w, h }
        F.last_uid = uid
        F.last_hot = hovered

        local fg = opts.disabled and M.theme.text_disabled or M.theme.text
        local readout
        if opts.format then
            readout = string.format(opts.format, v)
        elseif integer then
            readout = tostring(floor(v + 0.5))
        else
            readout = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
        end
        readout = readout .. (opts.suffix or "")
        text_row(truncate(tostring(label), T.font_small, w - text_w(readout, T.font_small) - 8), x + 4, y, T.font_small + 6, T.font_small, M.theme.text_dim)
        text_row(readout, x, y, T.font_small + 6, T.font_small, fg, "right", w - 4)

        local t = (hi > lo) and (v - lo) / (hi - lo) or 0
        if not opts.disabled and shader("render_slider_track") then
            slider_track(x, track_y, w, track_h, t, ease_hover(st, hovered or dragging))
        else
            fill(x, track_y, w, track_h, M.theme.track, track_h / 2)
            fill(x, track_y, max(track_h, w * t), track_h, opts.disabled and M.theme.text_disabled or M.theme.accent, track_h / 2)
        end
        local kx = x + w * t
        circle_fill(kx, track_y + track_h / 2, (hovered or dragging) and 7 or 6, M.theme.accent_text)
        if hovered or dragging then circle(kx, track_y + track_h / 2, 7, M.theme.accent, 1) end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return v, changed
    end

    -- --- progress -----------------------------------------------------------

    ---@param fraction number 0..1
    ---@param opts? { label?: string, text?: string, color?: any, h?: number, bg?: any }
    function Facade:progress(fraction, opts)
        opts = opts or {}
        local h = opts.h or (T.widget_h - 6)
        local x, y, w = place(h)
        fraction = util.clamp(tonumber(fraction) or 0, 0, 1)
        fill(x, y, w, h, to_color(opts.bg, M.theme.track), h / 2)
        if fraction > 0 then
            fill(x, y, max(h, w * fraction), h, to_color(opts.color, M.theme.accent), h / 2)
        end
        local s = opts.text or opts.label
        if s then
            text_row(truncate(s, T.font_small, w - 8), x, y, h, T.font_small, M.theme.text, "center", w)
        end
        return self
    end

    -- --- images -------------------------------------------------------------

    ---@param ref string asset reference
    ---@param w? number   default: column width
    ---@param h? number   default: w (square)
    ---@param opts? { tint?: any, align?: "left"|"center"|"right", uv?: number[], tooltip?: string, fit?: boolean }
    ---@return boolean drawn
    function Facade:image(ref, w, h, opts)
        opts = opts or {}
        local col_w = L.row and L.row.cols[min(L.row.i, #L.row.cols)].w or (L.w - L.indent)
        w = w or col_w
        h = h or w
        local x, y, ww = place(h)
        if opts.align == "center" then x = x + (ww - w) / 2 elseif opts.align == "right" then x = x + ww - w end
        local ready, e = assets.request(ref)
        if ready then
            if opts.fit and e and e.w and e.h and e.w > 0 and e.h > 0 then
                local ar = e.w / e.h
                local fw, fh = w, h
                if fw / fh > ar then fw = fh * ar else fh = fw / ar end
                x = x + (w - fw) / 2
                y = y + (h - fh) / 2
                w, h = fw, fh
            end
            image(ref, x, y, w, h, to_color(opts.tint, nil), opts.uv and { uv = opts.uv } or nil)
        else
            local failed = e and e.state == "failed"
            stroke(x, y, w, h, failed and M.theme.danger or M.theme.border, 1, 2)
            text_row(failed and "!" or "..", x, y, h, T.font_small, M.theme.text_dim, "center", w)
        end
        if opts.tooltip and hover(x, y, w, h) then P.tooltip = { text = opts.tooltip } end
        return ready
    end

    --- A spell's icon at `size` px, via the asset registry.
    ---@param spell_id integer
    ---@param size? number
    ---@param opts? table
    function Facade:spell_icon(spell_id, size, opts)
        return self:image("spell:" .. tostring(spell_id), size or 32, size or 32, opts)
    end

    --- Icon at `size` px. Any asset reference.
    function Facade:icon(ref, size, opts)
        return self:image(ref, size or 24, size or 24, opts)
    end

    -- --- escape hatches -----------------------------------------------------

    ---@class jcore_ui_canvas
    ---@field x number
    ---@field y number
    ---@field w number
    ---@field h number

    local Canvas = {}
    Canvas.__index = Canvas
    function Canvas:fill(x, y, w, h, col, r) fill(self.x + x, self.y + y, w, h, to_color(col, M.theme.text), r or 0) end
    function Canvas:rect(x, y, w, h, col, t, r) stroke(self.x + x, self.y + y, w, h, to_color(col, M.theme.text), t or 1, r or 0) end
    function Canvas:line(x1, y1, x2, y2, col, t) line(self.x + x1, self.y + y1, self.x + x2, self.y + y2, to_color(col, M.theme.text), t or 1) end
    function Canvas:text(s, x, y, col, size, centered) text(tostring(s), self.x + x, self.y + y, font_size(size), to_color(col, M.theme.text), centered) end
    function Canvas:circle(x, y, r, col, filled, t)
        if filled ~= false then circle_fill(self.x + x, self.y + y, r, to_color(col, M.theme.text))
        else circle(self.x + x, self.y + y, r, to_color(col, M.theme.text), t or 1) end
    end
    function Canvas:image(ref, x, y, w, h, tint) image(ref, self.x + x, self.y + y, w, h, to_color(tint, nil)) end
    function Canvas:text_width(s, size) return text_w(tostring(s), font_size(size)) end
    function Canvas:hovered() return hover(self.x, self.y, self.w, self.h) end
    function Canvas:mouse() return F.mx - self.x, F.my - self.y end

    --- A rectangle you paint yourself, with a canvas whose coordinates are
    --- relative to it. Interaction comes back through the return values.
    ---@param id string
    ---@param h number
    ---@param painter fun(c: jcore_ui_canvas)
    ---@return boolean hovered
    ---@return boolean clicked
    function Facade:custom(id, h, painter)
        local uid = uid_for(id)
        local x, y, w = place(h)
        local hovered, _, clicked = button_behaviour(uid, x, y, w, h)
        local c = setmetatable({ x = x, y = y, w = w, h = h }, Canvas)
        local ok, err = pcall(painter, c)
        if not ok then log.fmt("error", "custom widget %s failed: %s", uid, tostring(err)) end
        return hovered, clicked
    end

    --- Reserves `h` pixels and calls `fn(x, y, w, h)` AT PAINT TIME, when
    --- core.graphics is live. This is how code written against the raw
    --- graphics API lands inside a window without being rewritten; it paints
    --- in the window's layer and clip.
    ---@param h number
    ---@param fn fun(x: number, y: number, w: number, h: number)
    function Facade:raw(h, fn)
        local x, y, w = place(h)
        emit({ OP_FN, fn, x, y, w, h })
        return self
    end

    --- The rect the last widget occupied, for anything that positions
    --- against it.
    function Facade:last_rect()
        local r = F.last_rect
        if not r then return nil end
        return r[1], r[2], r[3], r[4]
    end

    --- Attaches a tooltip to the last widget.
    ---@param s string
    function Facade:tooltip(s)
        if F.last_hot and s then P.tooltip = { text = tostring(s) } end
        return self
    end

    --- Whether the last widget is hovered.
    function Facade:hovered()
        return F.last_hot
    end

    --- Whether the last widget was right-clicked this frame.
    function Facade:right_clicked()
        return F.last_hot and F.rmb_down or false
    end

    --- Mouse position and this frame's button edges, for custom logic.
    function Facade:mouse()
        return F.mx, F.my, F.lmb_down, F.rmb_down, F.lmb
    end

    --- Whether the cursor is over any toolkit surface this frame.
    function M.is_cursor_over_ui()
        return F.hover_win ~= nil
    end

    -- --- expose internals for the widget extensions -------------------------

    M._F, M._P, M._S, M._T = F, P, S, T
    M._L = function() return L end
    M._cur = function() return cur end
    M._windows = windows
    M._push_layout = push_layout
    M._pop_layout = pop_layout
    M._inside = inside
    M._vec2 = vec2
    M._text_row = text_row
    M._persist_window = persist_window
    M._resolve_window_id = resolve_window_id

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local live = 0
        for _, win in pairs(windows) do
            if win.visible and win.seen_frame >= F.frame - 2 then live = live + 1 end
        end
        return {
            windows   = util.count(windows),
            live      = live,
            cmds      = stats.cmds,
            popups    = stats.popups,
            hover     = F.hover_win,
            active    = P.active,
            focus     = P.focus,
            captured  = P.captured_mouse,
            states    = util.count(S),
            toasts    = #P.toasts,
        }
    end

    setmetatable(M, Facade)
    M.owner = nil
    M._prefix = ""

    return M
end

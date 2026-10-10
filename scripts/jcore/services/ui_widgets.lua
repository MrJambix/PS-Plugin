-- JCore / ui_widgets -- the rest of the widget set, on the ui core.
--
-- Depends on: util, log, ui, input, assets, units, player, draw.
--
-- Everything here is built from the same three primitives the core exposes:
-- place() for a rect, button_behaviour() for the press contract, and the
-- paint emitters. Widgets that need a surface outside their window (the
-- dropdown list, the colour picker, a context menu) open a popup, which the
-- core paints at the end of the frame above every window and routes hover
-- to. Toasts and the confirm modal hang off the core's end-of-frame hook.

return function(rt)
    local util = rt.util
    local ui = rt.ui
    local input = rt.input
    local assets = rt.assets
    local units = rt.units
    local player = rt.player
    local draw = rt.draw
    local log = rt.log.for_tag("JCore/ui")

    local F, P, S, T = ui._F, ui._P, ui._S, ui._T
    local paint = ui.paint
    local fill, stroke, line, text, tri = paint.fill, paint.stroke, paint.line, paint.text, paint.tri
    local circle_fill, clip_push, clip_pop, image = paint.circle_fill, paint.clip_push, paint.clip_pop, paint.image
    local shader, field, ease_hover = ui.shader, paint.field, paint.ease_hover
    local text_row = ui._text_row
    local place, uid_for = ui._place, ui._uid
    local value_of, set_value, state_for = ui._value_of, ui._set_value, ui._state_for
    local button_behaviour, hover, inside = ui.button_behaviour, ui.hover, ui._inside
    local truncate, text_w, to_color, font_size = ui.truncate, ui.text_width, ui.to_color, ui.font_size
    local theme = ui.theme
    local Facade = ui.Facade
    local VK = ui.VK
    local floor, max, min, abs = math.floor, math.max, math.min, math.abs
    local L = ui._L

    local function key_name(vk)
        if not vk or vk == 0 or vk == 999 then return "none" end
        local ok, name = pcall(core.graphics.translate_vkey_to_string, vk)
        if ok and type(name) == "string" and name ~= "" then return name end
        return "key " .. tostring(vk)
    end
    ui.key_name = key_name

    local function col_w()
        local l = L()
        if l.row then return l.row.cols[min(l.row.i, #l.row.cols)].w end
        return l.w - l.indent
    end

    -- --- dropdown -----------------------------------------------------------

    ---@param id string
    ---@param label string|nil  nil for a bare field
    ---@param options string[]
    ---@param default? integer
    ---@param opts? jcore_ui_value_opts|{ max_visible?: integer }
    ---@return integer index
    ---@return boolean changed
    function Facade:dropdown(id, label, options, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, v = value_of(uid, default or 1, opts.persist)
        -- A ROW PICKED FROM THE LIST (1.8.1). The list is a popup, run at the
        -- end of the frame, after this call has returned; so its pick is
        -- reported here, on the next call: as changed, and over whatever the
        -- caller set in between. A window that mirrors a setting sets the
        -- widget from it before every draw (Jambix AIO's class window), and
        -- until 1.8.1 that put the old value straight back over the pick:
        -- nothing picked from a list ever stuck there, or in the menu mirrors
        -- below (menu_dropdown, combobox), which only write on changed.
        local changed = false
        local picked = st.picked
        if picked ~= nil then
            st.picked = nil
            set_value(uid, picked)
            v, changed = picked, true
        end
        v = util.clamp(floor(tonumber(v) or 1), 1, max(1, #options))
        local h = T.widget_h
        local x, y, w = place(label and (h + T.font_small + 4) or h)
        local fy = y
        if label then
            text_row(truncate(label, T.font_small, w), x + 4, y, T.font_small + 4, T.font_small, theme.text_dim)
            fy = y + T.font_small + 4
        end
        local hovered, _, clicked = button_behaviour(uid, x, fy, w, h, opts.disabled)
        local open = ui.is_popup_open(uid)

        if clicked then
            if open then
                ui.close_popup()
            else
                local item_h = T.widget_h
                local visible = min(#options, opts.max_visible or 8)
                local ph = visible * item_h + 8
                local opener = { x, fy, w, h }
                ui.open_popup(uid, x, fy + h + 2, w, ph, function(popup)
                    local st2 = state_for(uid)
                    local max_scroll = max(0, #options * item_h + 8 - ph)
                    if F.wheel ~= 0 and F.hover_win == "\1popup" then
                        popup.scroll = util.clamp((popup.scroll or 0) - F.wheel * item_h, 0, max_scroll)
                    end
                    for i = 1, #options do
                        local ix, iy, iw = place(item_h)
                        local ih, _, iclicked = button_behaviour(uid .. "\1item" .. i, ix, iy, iw, item_h)
                        local selected = st2.v == i
                        if ih then fill(ix, iy, iw, item_h, theme.bg_hover, 3)
                        elseif selected then fill(ix, iy, iw, item_h, theme.accent_dim, 3) end
                        text_row(truncate(tostring(options[i]), T.font_body, iw - 12), ix + 6, iy, item_h, T.font_body,
                            selected and theme.accent_text or theme.text)
                        if iclicked then
                            if set_value(uid, i) then st2.picked = i end
                            ui.close_popup()
                        end
                    end
                end, opener)
            end
        end
        if hovered and F.wheel ~= 0 and not open and not opts.no_wheel then
            F.wheel_claimed = true
            local nv = util.clamp(v - (F.wheel > 0 and 1 or -1), 1, #options)
            if nv ~= v then changed = set_value(uid, nv) or changed; v = nv end
        end
        if hovered and F.rmb_down then
            changed = set_value(uid, st.default) or changed; v = st.default
        end

        local fg = opts.disabled and theme.text_disabled or theme.text
        if not opts.disabled and shader("render_dropdown_field") then
            field(x, fy, w, h, ease_hover(st, hovered or open), open and 1 or 0)
        else
            fill(x, fy, w, h, (hovered or open) and theme.bg_hover or theme.bg_elevated, T.rounding)
        end
        stroke(x, fy, w, h, open and theme.border_focus or theme.border, 1, T.rounding)
        text_row(truncate(tostring(options[v] or "?"), T.font_body, w - 28), x + 8, fy, h, T.font_body, fg)
        local cx, cy = x + w - 12, fy + h / 2
        if open then tri(cx - 4, cy + 2, cx + 4, cy + 2, cx, cy - 3, theme.text_dim)
        else tri(cx - 4, cy - 2, cx + 4, cy - 2, cx, cy + 3, theme.text_dim) end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return v, changed
    end

    -- --- tabs ---------------------------------------------------------------

    ---@param id string
    ---@param options string[]
    ---@param default? integer
    ---@param opts? jcore_ui_value_opts
    ---@return integer index
    function Facade:tabs(id, options, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, v = value_of(uid, default or 1, opts.persist ~= false)
        v = util.clamp(floor(tonumber(v) or 1), 1, max(1, #options))
        local h = T.widget_h
        local x, y, w = place(h + 2)
        fill(x, y, w, h, theme.bg_input, T.rounding)
        local n = #options
        local tw = w / max(1, n)
        for i = 1, n do
            local tx = x + (i - 1) * tw
            local hovered, _, clicked = button_behaviour(uid .. "\1" .. i, tx, y, tw, h, opts.disabled)
            if clicked and v ~= i then
                v = i
                set_value(uid, i)
            end
            local active = v == i
            if active then
                fill(tx + 1, y + 1, tw - 2, h - 2, theme.accent, T.rounding)
            elseif hovered then
                fill(tx + 1, y + 1, tw - 2, h - 2, theme.bg_hover, T.rounding)
            end
            text_row(truncate(tostring(options[i]), T.font_small, tw - 8), tx, y, h, T.font_small,
                active and theme.accent_text or theme.text_dim, "center", tw)
        end
        F.last_rect = { x, y, w, h }
        F.last_uid = uid
        F.last_hot = hover(x, y, w, h)
        return v
    end

    -- --- text input ---------------------------------------------------------

    ---@class jcore_ui_text_input_opts: jcore_ui_value_opts
    ---@field placeholder? string
    ---@field max_len? integer
    ---@field password? boolean
    ---@field numeric? boolean
    ---@field on_submit? fun(value: string)

    ---@param id string
    ---@param label string|nil
    ---@param default? string
    ---@param opts? jcore_ui_text_input_opts
    ---@return string value
    ---@return boolean submitted  true on the frame Enter was pressed
    function Facade:text_input(id, label, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, v = value_of(uid, default or "", opts.persist)
        v = tostring(v == nil and "" or v)
        local h = T.widget_h
        local x, y, w = place(label and (h + T.font_small + 4) or h)
        local fy = y
        if label then
            text_row(truncate(label, T.font_small, w), x + 4, y, T.font_small + 4, T.font_small, theme.text_dim)
            fy = y + T.font_small + 4
        end
        local hovered, _, clicked = button_behaviour(uid, x, fy, w, h, opts.disabled)
        local focused = P.focus == uid
        if clicked then
            P.focus = uid
            P.listening = nil
            st.caret = #v
            focused = true
            st.select_all = false
        end

        local submitted = false
        if focused and F.keys then
            local keys, typed = F.keys, F.typed
            st.caret = util.clamp(st.caret or #v, 0, #v)
            local changed = false
            if keys.ctrl_a then st.select_all = true end
            if keys.ctrl_v then
                local pasted = ui.clipboard_get and ui.clipboard_get() or nil
                if pasted and pasted ~= "" then
                    if st.select_all then v = ""; st.caret = 0; st.select_all = false end
                    v = v:sub(1, st.caret) .. pasted .. v:sub(st.caret + 1)
                    st.caret = st.caret + #pasted
                    changed = true
                end
            end
            if keys.ctrl_c and ui.clipboard_set then ui.clipboard_set(v) end
            for i = 1, #typed do
                local ch = typed[i]
                if not opts.numeric or ch:match("[%d%.%-]") then
                    if st.select_all then v = ""; st.caret = 0; st.select_all = false end
                    if not opts.max_len or #v < opts.max_len then
                        v = v:sub(1, st.caret) .. ch .. v:sub(st.caret + 1)
                        st.caret = st.caret + 1
                        changed = true
                    end
                end
            end
            if keys[VK.BACK] then
                if st.select_all then v = ""; st.caret = 0; st.select_all = false; changed = true
                elseif st.caret > 0 then
                    v = v:sub(1, st.caret - 1) .. v:sub(st.caret + 1)
                    st.caret = st.caret - 1
                    changed = true
                end
            end
            if keys[VK.DELETE] then
                if st.select_all then v = ""; st.caret = 0; st.select_all = false; changed = true
                elseif st.caret < #v then
                    v = v:sub(1, st.caret) .. v:sub(st.caret + 2)
                    changed = true
                end
            end
            if keys[VK.LEFT] then st.caret = max(0, st.caret - 1); st.select_all = false end
            if keys[VK.RIGHT] then st.caret = min(#v, st.caret + 1); st.select_all = false end
            if keys[VK.HOME] then st.caret = 0; st.select_all = false end
            if keys[VK.END] then st.caret = #v; st.select_all = false end
            if keys[VK.RETURN] or keys[VK.TAB] then
                submitted = true
                P.focus = nil
                focused = false
            end
            if keys[VK.ESCAPE] then
                P.focus = nil
                focused = false
            end
            if changed then set_value(uid, v) end
        end

        fill(x, fy, w, h, theme.bg_input, T.rounding)
        stroke(x, fy, w, h, focused and theme.border_focus or (hovered and theme.border_focus or theme.border), 1, T.rounding)
        local shown = v
        if opts.password then shown = string.rep("*", #v) end
        local size = T.font_body
        clip_push(x + 2, fy, w - 4, h)
        if shown == "" and not focused and opts.placeholder then
            text_row(truncate(opts.placeholder, size, w - 12), x + 6, fy, h, size, theme.text_disabled)
        else
            -- Keep the caret in view by scrolling the text left when needed.
            local caret = focused and util.clamp(st.caret or #shown, 0, #shown) or #shown
            local caret_px = text_w(shown:sub(1, caret), size)
            local offset = 0
            if caret_px > w - 14 then offset = caret_px - (w - 14) end
            if st.select_all and focused then
                fill(x + 6 - offset, fy + 3, text_w(shown, size), h - 6, theme.accent_dim, 2)
            end
            text_row(shown, x + 6 - offset, fy, h, size, opts.disabled and theme.text_disabled or theme.text)
            if focused and (F.t % 1.0) < 0.6 then
                local cx = x + 6 - offset + caret_px
                line(cx, fy + 4, cx, fy + h - 4, theme.text, 1)
            end
        end
        clip_pop()
        if submitted and opts.on_submit then pcall(opts.on_submit, v) end
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return v, submitted
    end

    -- --- keybind ------------------------------------------------------------

    ---@class jcore_ui_keybind_opts: jcore_ui_value_opts
    ---@field mode? "hold"|"toggle"  default "hold"
    ---@field allow_mouse? boolean   let mouse buttons 4/5 etc. be bound
    ---@field on_press? fun()        fires on the key-down edge
    ---@field ctrl? boolean  required modifiers
    ---@field shift? boolean
    ---@field alt? boolean

    --- A key pill. Click it and press a key to rebind; Escape cancels and
    --- Backspace unbinds. Returns the live state: true while held (hold
    --- mode) or while latched (toggle mode).
    ---@param id string
    ---@param label string
    ---@param default_vk? integer
    ---@param opts? jcore_ui_keybind_opts
    ---@return boolean active
    ---@return integer vk
    function Facade:keybind(id, label, default_vk, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, vk = value_of(uid, default_vk or 0, opts.persist ~= false)
        vk = tonumber(vk) or 0
        local h = T.widget_h
        local x, y, w = place(h)
        local pill_w = max(56, text_w(key_name(vk), T.font_small) + 18)
        local px = x + w - pill_w - 4
        local hovered, _, clicked = button_behaviour(uid, px, y + 2, pill_w, h - 4, opts.disabled)
        local listening = P.listening == uid

        if clicked then
            if listening then
                P.listening = nil
            else
                P.listening = uid
                P.focus = nil
                st.listen_started = F.t
            end
            listening = P.listening == uid
        end
        if hovered and F.rmb_down then
            vk = st.default
            set_value(uid, vk)
        end

        if listening then
            -- Give the click that opened capture a frame to release, else
            -- the left button binds itself.
            if F.t - (st.listen_started or 0) > 0.15 then
                local new = ui._first_new_key(opts.allow_mouse)
                if new == VK.ESCAPE then
                    P.listening = nil
                elseif new == VK.BACK then
                    vk = 0
                    set_value(uid, 0)
                    P.listening = nil
                elseif new and new ~= VK.LBUTTON and new ~= VK.RBUTTON then
                    vk = new
                    set_value(uid, new)
                    P.listening = nil
                end
            end
        end

        -- Live state, unless the game's chat box has the keyboard.
        local down = false
        if vk > 0 and not input.is_typing() and P.listening == nil then
            down = input.is_key_pressed(vk)
            if down and opts.ctrl and not input.is_key_pressed(VK.CONTROL) then down = false end
            if down and opts.shift and not input.is_key_pressed(VK.SHIFT) then down = false end
            if down and opts.alt and not input.is_key_pressed(VK.MENU) then down = false end
        end
        local edge = down and not st.was_down
        st.was_down = down
        if edge and opts.on_press then pcall(opts.on_press) end
        local active
        if opts.mode == "toggle" then
            if edge then st.latched = not st.latched end
            active = st.latched or false
        else
            active = down
        end

        local fg = opts.disabled and theme.text_disabled or theme.text
        text_row(truncate(tostring(label), T.font_body, w - pill_w - 12), x + 4, y, h, T.font_body, fg)
        local bg = listening and theme.accent or (active and theme.accent_dim) or (hovered and theme.bg_hover) or theme.bg_elevated
        fill(px, y + 2, pill_w, h - 4, bg, (h - 4) / 2)
        stroke(px, y + 2, pill_w, h - 4, (listening or active) and theme.border_focus or theme.border, 1, (h - 4) / 2)
        local caption = listening and "press.." or key_name(vk)
        text_row(caption, px, y + 2, h - 4, T.font_small, listening and theme.accent_text or fg, "center", pill_w)
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return active, vk
    end

    -- --- colour picker ------------------------------------------------------

    local function hsv_to_rgb(h, s, v)
        local i = floor(h * 6)
        local f = h * 6 - i
        local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
        i = i % 6
        if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
        elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
    end

    local function rgb_to_hsv(r, g, b)
        r, g, b = r / 255, g / 255, b / 255
        local mx, mn = max(r, g, b), min(r, g, b)
        local d = mx - mn
        local h = 0
        if d > 0 then
            if mx == r then h = ((g - b) / d) % 6
            elseif mx == g then h = (b - r) / d + 2
            else h = (r - g) / d + 4 end
            h = h / 6
        end
        local s = mx > 0 and d / mx or 0
        return h, s, mx
    end

    -- Colour objects for the picker's swatches are cached by quantised
    -- value so the open picker does not allocate a few hundred per frame.
    local swatch_cache = {}
    local function swatch(r, g, b, a)
        local key = floor(r) * 16777216 + floor(g) * 65536 + floor(b) * 256 + floor(a or 255)
        local c = swatch_cache[key]
        if not c then
            c = ui.rgba(floor(r), floor(g), floor(b), floor(a or 255))
            swatch_cache[key] = c
        end
        return c
    end

    ---@class jcore_ui_color_opts: jcore_ui_value_opts
    ---@field alpha? boolean  show the alpha bar (default true)

    --- Colour swatch that opens a picker. Value: { r, g, b, a } table with
    --- 0..255 channels. Second result is a colour object for drawing.
    ---@param id string
    ---@param label string
    ---@param default? table {r,g,b,a} or {r=,g=,b=,a=}
    ---@param opts? jcore_ui_color_opts
    ---@return table rgba
    ---@return any color
    function Facade:color(id, label, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local d = default or { 255, 255, 255, 255 }
        local dv = { r = d.r or d[1] or 255, g = d.g or d[2] or 255, b = d.b or d[3] or 255, a = d.a or d[4] or 255 }
        local st, v = value_of(uid, dv, opts.persist)
        if type(v) ~= "table" then v = dv end
        local h = T.widget_h
        local x, y, w = place(h)
        local sw = 34
        local sx = x + w - sw - 4
        local hovered, _, clicked = button_behaviour(uid, sx, y + 2, sw, h - 4, opts.disabled)
        local open = ui.is_popup_open(uid)

        if hovered and F.rmb_down then
            v = util.shallow_copy(st.default)
            set_value(uid, v)
        end

        if clicked then
            if open then
                ui.close_popup()
            else
                local pw, ph = 196, opts.alpha == false and 168 or 190
                st.hsv = { rgb_to_hsv(v.r, v.g, v.b) }
                ui.open_popup(uid, sx + sw - pw, y + h + 2, pw, ph, function(popup)
                    local st2 = state_for(uid)
                    local cur_v = st2.v
                    local hs = st2.hsv
                    local px, py = popup.x + 8, popup.y + 8
                    local grid = 12
                    local cell = 12
                    local size = grid * cell

                    -- Saturation/value square as a grid of swatches.
                    local sq_hover = hover(px, py, size, size)
                    local sq_uid = uid .. "\1sv"
                    if sq_hover and F.lmb_down and P.active == nil then P.active = sq_uid end
                    if P.active == sq_uid then
                        if F.lmb then
                            hs[2] = util.clamp((F.mx - px) / size, 0, 1)
                            hs[3] = util.clamp(1 - (F.my - py) / size, 0, 1)
                        else
                            P.active = nil
                        end
                    end
                    for gy = 0, grid - 1 do
                        for gx = 0, grid - 1 do
                            local r, g, b = hsv_to_rgb(hs[1], (gx + 0.5) / grid, 1 - (gy + 0.5) / grid)
                            fill(px + gx * cell, py + gy * cell, cell, cell, swatch(r * 255, g * 255, b * 255), 0)
                        end
                    end
                    local mx, my = px + hs[2] * size, py + (1 - hs[3]) * size
                    paint.circle(mx, my, 4, theme.text, 1.5)

                    -- Hue strip.
                    local hx, hy, hw, hh = px + size + 8, py, 16, size
                    local hue_uid = uid .. "\1hue"
                    if hover(hx, hy, hw, hh) and F.lmb_down and P.active == nil then P.active = hue_uid end
                    if P.active == hue_uid then
                        if F.lmb then hs[1] = util.clamp((F.my - hy) / hh, 0, 0.999) else P.active = nil end
                    end
                    local segs = 24
                    for i = 0, segs - 1 do
                        local r, g, b = hsv_to_rgb((i + 0.5) / segs, 1, 1)
                        fill(hx, hy + i * (hh / segs), hw, hh / segs + 1, swatch(r * 255, g * 255, b * 255), 0)
                    end
                    line(hx - 2, hy + hs[1] * hh, hx + hw + 2, hy + hs[1] * hh, theme.text, 2)

                    -- Alpha strip.
                    local a = cur_v.a or 255
                    if opts.alpha ~= false then
                        local ax, ay, aw, ah = px, py + size + 8, size, 12
                        local a_uid = uid .. "\1alpha"
                        if hover(ax, ay, aw, ah) and F.lmb_down and P.active == nil then P.active = a_uid end
                        if P.active == a_uid then
                            if F.lmb then a = floor(util.clamp((F.mx - ax) / aw, 0, 1) * 255 + 0.5) else P.active = nil end
                        end
                        local r, g, b = hsv_to_rgb(hs[1], hs[2], hs[3])
                        for i = 0, 15 do
                            fill(ax + i * (aw / 16), ay, aw / 16 + 1, ah, swatch(r * 255, g * 255, b * 255, (i + 0.5) / 16 * 255), 0)
                        end
                        stroke(ax, ay, aw, ah, theme.border, 1, 0)
                        line(ax + (a / 255) * aw, ay - 2, ax + (a / 255) * aw, ay + ah + 2, theme.text, 2)
                    end

                    local r, g, b = hsv_to_rgb(hs[1], hs[2], hs[3])
                    local nv = { r = floor(r * 255 + 0.5), g = floor(g * 255 + 0.5), b = floor(b * 255 + 0.5), a = a }
                    if nv.r ~= cur_v.r or nv.g ~= cur_v.g or nv.b ~= cur_v.b or nv.a ~= cur_v.a then
                        set_value(uid, nv)
                    end
                    local hex = string.format("#%02X%02X%02X", nv.r, nv.g, nv.b)
                    text_row(hex, hx - 20, py + size + (opts.alpha == false and 6 or 26), 16, T.font_small, theme.text_dim, "right", hw + 20)
                end, { sx, y, sw, h })
            end
        end

        local fg = opts.disabled and theme.text_disabled or theme.text
        text_row(truncate(tostring(label), T.font_body, w - sw - 12), x + 4, y, h, T.font_body, fg)
        local c = swatch(v.r, v.g, v.b, v.a)
        fill(sx, y + 2, sw, h - 4, c, 3)
        stroke(sx, y + 2, sw, h - 4, (hovered or open) and theme.border_focus or theme.border, 1, 3)
        if opts.tooltip and hovered then P.tooltip = { text = opts.tooltip } end
        return v, c
    end

    -- --- list ---------------------------------------------------------------

    ---@class jcore_ui_list_opts
    ---@field h? number         region height (default 6 rows)
    ---@field item_h? number
    ---@field selected? integer  externally controlled selection
    ---@field icons? string[]    asset reference per item
    ---@field colors? any[]      text colour per item
    ---@field persist? boolean
    ---@field empty? string      text when there are no items

    --- Scrollable selectable list of strings. Returns the selected index
    --- (0 for none), the index clicked this frame, and the index
    --- double-clicked this frame.
    ---@param id string
    ---@param items string[]
    ---@param opts? jcore_ui_list_opts
    ---@return integer selected
    ---@return integer|nil clicked
    ---@return integer|nil double_clicked
    function Facade:list(id, items, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local item_h = opts.item_h or T.widget_h
        local h = opts.h or item_h * 6 + 4
        local st, sel = value_of(uid, opts.selected or 0, opts.persist)
        if opts.selected then sel = opts.selected end
        local clicked, dbl = nil, nil

        local x, y, w = place(h)
        fill(x, y, w, h, theme.bg_input, T.rounding)
        stroke(x, y, w, h, theme.border, 1, T.rounding)
        local content_h = #items * item_h
        local max_scroll = max(0, content_h - h + 4)
        st.scroll = util.clamp(st.scroll or 0, 0, max_scroll)
        if hover(x, y, w, h) and F.wheel ~= 0 and not P.popup and max_scroll > 0 then
            st.scroll = util.clamp(st.scroll - F.wheel * item_h, 0, max_scroll)
            F.wheel_claimed = true
        end
        local inner_w = w - (max_scroll > 0 and (T.scrollbar + 4) or 0)
        clip_push(x + 1, y + 1, w - 2, h - 2)
        local first = max(1, floor(st.scroll / item_h))
        local last = min(#items, first + floor(h / item_h) + 1)
        for i = first, last do
            local iy = y + 2 + (i - 1) * item_h - st.scroll
            local hovered, _, iclicked = button_behaviour(uid .. "\1" .. i, x + 2, iy, inner_w - 4, item_h)
            if i % 2 == 0 then fill(x + 2, iy, inner_w - 4, item_h, theme.zebra, 0) end
            if sel == i then fill(x + 2, iy, inner_w - 4, item_h, theme.accent_dim, 3)
            elseif hovered then fill(x + 2, iy, inner_w - 4, item_h, theme.bg_hover, 3) end
            local tx = x + 8
            if opts.icons and opts.icons[i] then
                image(opts.icons[i], tx, iy + 2, item_h - 4, item_h - 4, nil)
                tx = tx + item_h
            end
            local col = opts.colors and to_color(opts.colors[i], theme.text) or theme.text
            text_row(truncate(tostring(items[i]), T.font_body, inner_w - (tx - x) - 8), tx, iy, item_h, T.font_body, col)
            if iclicked then
                clicked = i
                if F.dbl then dbl = i end
                if sel ~= i then
                    sel = i
                    set_value(uid, i)
                end
            end
        end
        if #items == 0 and opts.empty then
            text_row(opts.empty, x, y, h, T.font_small, theme.text_disabled, "center", w)
        end
        clip_pop()
        if max_scroll > 0 then
            local track_h = h - 6
            local thumb_h = max(14, track_h * (h / content_h))
            local t = st.scroll / max_scroll
            local tx = x + w - T.scrollbar - 3
            fill(tx, y + 3, T.scrollbar, track_h, theme.track, T.scrollbar / 2)
            fill(tx, y + 3 + (track_h - thumb_h) * t, T.scrollbar, thumb_h, theme.text_dim, T.scrollbar / 2)
        end
        -- The "last widget" is the whole list, not the last row painted:
        -- tooltip, hovered and context_menu after this call mean the list.
        F.last_rect = { x, y, w, h }
        F.last_uid = uid
        F.last_hot = hover(x, y, w, h)
        return sel, clicked, dbl
    end

    -- --- table --------------------------------------------------------------

    ---@class jcore_ui_column
    ---@field label string
    ---@field w? number   share: fraction (<=1), px (>1) or 0 for auto
    ---@field align? "left"|"right"|"center"
    ---@field color? any

    ---@class jcore_ui_table_opts
    ---@field h? number
    ---@field row_h? number
    ---@field selected? integer
    ---@field persist? boolean
    ---@field header? boolean  default true
    ---@field row_colors? any[]  colour per row (applies to every cell)
    ---@field sort? boolean  click a header to sort by that column (client side, string compare)

    --- Grid with a header. `rows` is an array of arrays of cell values.
    --- Returns the selected row index and the row clicked this frame.
    ---@param id string
    ---@param columns jcore_ui_column[]
    ---@param rows any[][]
    ---@param opts? jcore_ui_table_opts
    ---@return integer selected
    ---@return integer|nil clicked
    function Facade:table(id, columns, rows, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local row_h = opts.row_h or (T.widget_h - 2)
        local head_h = opts.header ~= false and T.widget_h or 0
        local h = opts.h or (head_h + row_h * 8 + 4)
        local st, sel = value_of(uid, opts.selected or 0, opts.persist)
        if opts.selected then sel = opts.selected end
        local clicked = nil

        local x, y, w = place(h)
        fill(x, y, w, h, theme.bg_input, T.rounding)
        stroke(x, y, w, h, theme.border, 1, T.rounding)

        -- Column widths.
        local body_h = h - head_h - 4
        local content_h = #rows * row_h
        local max_scroll = max(0, content_h - body_h)
        local inner_w = w - 4 - (max_scroll > 0 and (T.scrollbar + 4) or 0)
        local fixed, autos = 0, 0
        for i = 1, #columns do
            local s = columns[i].w or 0
            if s > 1 then fixed = fixed + s elseif s > 0 then fixed = fixed + s * inner_w else autos = autos + 1 end
        end
        local auto_w = autos > 0 and max(20, (inner_w - fixed) / autos) or 0
        local col_x, col_w_list = {}, {}
        local cx = x + 2
        for i = 1, #columns do
            local s = columns[i].w or 0
            local cw = s > 1 and s or (s > 0 and s * inner_w or auto_w)
            col_x[i], col_w_list[i] = cx, cw
            cx = cx + cw
        end

        -- Header, optionally sortable.
        if head_h > 0 then
            fill(x + 2, y + 2, inner_w, head_h - 2, theme.bg_elevated, 3)
            for i = 1, #columns do
                local c = columns[i]
                local hovered, _, hclicked = button_behaviour(uid .. "\1h" .. i, col_x[i], y + 2, col_w_list[i], head_h - 2, not opts.sort)
                if hclicked then
                    if st.sort_col == i then st.sort_desc = not st.sort_desc else st.sort_col, st.sort_desc = i, false end
                end
                local label = tostring(c.label or "")
                if st.sort_col == i then label = label .. (st.sort_desc and " v" or " ^") end
                text_row(truncate(label, T.font_small, col_w_list[i] - 8), col_x[i] + 4, y + 2, head_h - 2, T.font_small,
                    hovered and theme.text or theme.text_dim, c.align, col_w_list[i] - 8)
            end
        end

        -- Sorted view.
        local order = rows
        if opts.sort and st.sort_col then
            local sc, desc = st.sort_col, st.sort_desc
            order = {}
            for i = 1, #rows do order[i] = rows[i] end
            table.sort(order, function(a, b)
                local av, bv = a[sc], b[sc]
                if type(av) == "number" and type(bv) == "number" then
                    if desc then return av > bv end
                    return av < bv
                end
                av, bv = tostring(av), tostring(bv)
                if desc then return av > bv end
                return av < bv
            end)
        end

        st.scroll = util.clamp(st.scroll or 0, 0, max_scroll)
        local by = y + head_h + 2
        if hover(x, by, w, body_h) and F.wheel ~= 0 and not P.popup and max_scroll > 0 then
            st.scroll = util.clamp(st.scroll - F.wheel * row_h, 0, max_scroll)
            F.wheel_claimed = true
        end
        clip_push(x + 1, by, w - 2, body_h)
        local first = max(1, floor(st.scroll / row_h))
        local last = min(#order, first + floor(body_h / row_h) + 1)
        for i = first, last do
            local row = order[i]
            local ry = by + (i - 1) * row_h - st.scroll
            local hovered, _, rclicked = button_behaviour(uid .. "\1r" .. i, x + 2, ry, inner_w, row_h)
            if i % 2 == 0 then fill(x + 2, ry, inner_w, row_h, theme.zebra, 0) end
            if sel == i then fill(x + 2, ry, inner_w, row_h, theme.accent_dim, 0)
            elseif hovered then fill(x + 2, ry, inner_w, row_h, theme.bg_hover, 0) end
            local row_col = opts.row_colors and to_color(opts.row_colors[i], nil) or nil
            for c = 1, #columns do
                local cell = row[c]
                local col = row_col or to_color(columns[c].color, theme.text)
                if type(cell) == "table" and cell.icon then
                    image(cell.icon, col_x[c] + 3, ry + 2, row_h - 4, row_h - 4, nil)
                    if cell.text then
                        text_row(truncate(tostring(cell.text), T.font_small, col_w_list[c] - row_h - 6),
                            col_x[c] + row_h + 2, ry, row_h, T.font_small, col)
                    end
                else
                    if type(cell) == "table" and cell.color then col = to_color(cell.color, col); cell = cell.text end
                    text_row(truncate(tostring(cell == nil and "" or cell), T.font_small, col_w_list[c] - 8),
                        col_x[c] + 4, ry, row_h, T.font_small, col, columns[c].align, col_w_list[c] - 8)
                end
            end
            if rclicked then
                clicked = i
                if sel ~= i then sel = i; set_value(uid, i) end
            end
        end
        clip_pop()
        if max_scroll > 0 then
            local track_h = body_h - 4
            local thumb_h = max(14, track_h * (body_h / content_h))
            local t = st.scroll / max_scroll
            local tx = x + w - T.scrollbar - 3
            fill(tx, by + 2, T.scrollbar, track_h, theme.track, T.scrollbar / 2)
            fill(tx, by + 2 + (track_h - thumb_h) * t, T.scrollbar, thumb_h, theme.text_dim, T.scrollbar / 2)
        end
        -- As for list: the last widget is the whole table.
        F.last_rect = { x, y, w, h }
        F.last_uid = uid
        F.last_hot = hover(x, y, w, h)
        return sel, clicked
    end

    -- --- tree ---------------------------------------------------------------

    --- A collapsible tree node header. Returns whether it is open; when it
    --- is, the caller indents, describes children, and unindents. The
    --- convenience pairs with `end_tree` which does the unindent for you.
    ---@param id string
    ---@param label string
    ---@param default_open? boolean
    ---@param opts? { icon?: string, persist?: boolean, badge?: string }
    ---@return boolean open
    function Facade:tree(id, label, default_open, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, open = value_of(uid, default_open or false, opts.persist ~= false)
        local h = T.widget_h
        local x, y, w = place(h)
        local hovered, _, clicked = button_behaviour(uid, x, y, w, h)
        if clicked then
            open = not open
            set_value(uid, open)
        end
        if hovered then fill(x, y, w, h, theme.zebra, T.rounding) end
        local cx, cy = x + 8, y + h / 2
        if open then tri(cx - 4, cy - 2, cx + 4, cy - 2, cx, cy + 3, theme.text_dim)
        else tri(cx - 2, cy - 4, cx - 2, cy + 4, cx + 3, cy, theme.text_dim) end
        local tx = x + 18
        if opts.icon then
            image(opts.icon, tx, y + 3, h - 6, h - 6, nil)
            tx = tx + h - 2
        end
        local badge_w = 0
        if opts.badge then
            local bs = tostring(opts.badge)
            badge_w = text_w(bs, T.font_micro) + 10
            fill(x + w - badge_w - 4, y + 4, badge_w, h - 8, theme.bg_elevated, (h - 8) / 2)
            text_row(bs, x + w - badge_w - 4, y + 4, h - 8, T.font_micro, theme.text_dim, "center", badge_w)
        end
        text_row(truncate(tostring(label), T.font_body, w - (tx - x) - badge_w - 8), tx, y, h, T.font_body, theme.text)
        if open then self:indent(14) end
        st.open_indent = open
        return open
    end

    function Facade:end_tree()
        self:unindent(14)
        return self
    end

    -- --- context menu -------------------------------------------------------

    --- Right-click menu on the last widget. Returns the chosen item's index
    --- on the frame it is picked.
    ---@param id string
    ---@param items string[]
    ---@return integer|nil chosen
    function Facade:context_menu(id, items)
        local uid = uid_for(id)
        local st = state_for(uid)
        local chosen = nil
        if F.last_hot and F.rmb_down then
            local item_h = T.widget_h
            local w = 120
            for i = 1, #items do w = max(w, text_w(tostring(items[i]), T.font_body) + 24) end
            st.chosen = nil
            ui.open_popup(uid, F.mx, F.my, w, #items * item_h + 8, function()
                for i = 1, #items do
                    local ix, iy, iw = place(item_h)
                    local hovered, _, clicked = button_behaviour(uid .. "\1c" .. i, ix, iy, iw, item_h)
                    if hovered then fill(ix, iy, iw, item_h, theme.bg_hover, 3) end
                    text_row(tostring(items[i]), ix + 8, iy, item_h, T.font_body, theme.text)
                    if clicked then
                        st.chosen = i
                        ui.close_popup()
                    end
                end
            end)
        end
        if st.chosen then
            chosen = st.chosen
            st.chosen = nil
        end
        return chosen
    end

    -- --- unit frame ---------------------------------------------------------

    ---@class jcore_ui_unit_frame_opts
    ---@field h? number
    ---@field power? boolean   show the power bar (default true)
    ---@field power_type? integer
    ---@field name? boolean    default true
    ---@field level? boolean
    ---@field color? any       health colour override

    --- Name, health and power for a unit, JCore-cached readers. Draws an
    --- "empty" frame when the unit is nil.
    ---@param unit game_object|nil
    ---@param opts? jcore_ui_unit_frame_opts
    function Facade:unit_frame(unit, opts)
        opts = opts or {}
        local h = opts.h or (T.widget_h + 10)
        local x, y, w = place(h)
        fill(x, y, w, h, theme.bg_elevated, T.rounding)
        if not unit then
            text_row("no unit", x, y, h, T.font_small, theme.text_disabled, "center", w)
            return self
        end
        local name = units.name(unit) or "?"
        local frac = units.health_fraction(unit) or 0
        local hp, hpmax = units.health(unit) or 0, units.max_health(unit) or 0
        local bar_h = opts.power ~= false and (h - 8) * 0.62 or (h - 8)
        local bx, by, bw = x + 4, y + 4, w - 8
        local col = to_color(opts.color, nil) or draw.unit_color(unit) or theme.health
        fill(bx, by, bw, bar_h, theme.track, 2)
        fill(bx, by, max(2, bw * util.clamp(frac, 0, 1)), bar_h, col, 2)
        local label = name
        if opts.level then
            local ok, lvl = pcall(unit.get_level, unit)
            if ok and lvl then label = "[" .. tostring(lvl) .. "] " .. label end
        end
        if opts.name ~= false then
            text_row(truncate(label, T.font_small, bw * 0.6), bx + 4, by, bar_h, T.font_small, theme.text)
        end
        local hp_text = hpmax > 0 and string.format("%d%%", floor(frac * 100 + 0.5)) or ""
        if hpmax > 0 and hpmax < 1000000 then hp_text = string.format("%d / %d", hp, hpmax) end
        text_row(hp_text, bx, by, bar_h, T.font_micro, theme.text, "right", bw - 4)
        if opts.power ~= false then
            local py = by + bar_h + 2
            local ph = h - 8 - bar_h - 2
            local ok, pw = pcall(unit.get_power, unit, opts.power_type or 0)
            local ok2, pmax = pcall(unit.get_max_power, unit, opts.power_type or 0)
            local pf = (ok and ok2 and pmax and pmax > 0) and util.clamp((pw or 0) / pmax, 0, 1) or 0
            fill(bx, py, bw, ph, theme.track, 2)
            if pf > 0 then fill(bx, py, max(2, bw * pf), ph, theme.mana, 2) end
        end
        return self
    end

    --- The player's own frame.
    function Facade:player_frame(opts)
        return self:unit_frame(units.player(), opts)
    end

    -- --- badges and status --------------------------------------------------

    --- A small pill with text, for states. `tone` picks the colour.
    ---@param s string
    ---@param tone? "info"|"success"|"warning"|"danger"|"accent"|"dim"
    function Facade:badge(s, tone)
        local size = T.font_small
        local h = size + 8
        local col = theme[tone or "accent"] or theme.accent
        if tone == "dim" then col = theme.bg_elevated end
        local x, y, w = place(h)
        local tw = min(w, text_w(tostring(s), size) + 14)
        fill(x, y, tw, h, col, h / 2)
        text_row(tostring(s), x, y, h, size, tone == "dim" and theme.text_dim or theme.accent_text, "center", tw)
        return self
    end

    --- A labelled horizontal bar, for resources and cooldowns.
    ---@param label string
    ---@param fraction number
    ---@param opts? { color?: any, h?: number, text?: string }
    function Facade:bar(label, fraction, opts)
        opts = opts or {}
        local h = opts.h or T.widget_h
        local x, y, w = place(h)
        fill(x, y, w, h, theme.track, T.rounding)
        fill(x, y, max(T.rounding, w * util.clamp(fraction or 0, 0, 1)), h, to_color(opts.color, theme.accent), T.rounding)
        text_row(truncate(tostring(label), T.font_small, w * 0.6), x + 6, y, h, T.font_small, theme.text)
        if opts.text then text_row(tostring(opts.text), x, y, h, T.font_small, theme.text, "right", w - 6) end
        return self
    end

    --- A row of spell icons with cooldown sweep, for a rotation preview.
    ---@param spell_ids integer[]
    ---@param size? number
    ---@param opts? { highlight?: integer, cooldowns?: table<integer, number> fraction remaining }
    function Facade:spell_row(spell_ids, size, opts)
        opts = opts or {}
        size = size or 32
        local x, y, w = place(size)
        local n = #spell_ids
        local step = size + 4
        local total = n * step - 4
        local sx = x + max(0, (w - total) / 2)
        for i = 1, n do
            local ix = sx + (i - 1) * step
            local ref = "spell:" .. tostring(spell_ids[i])
            if assets.request(ref) then
                image(ref, ix, y, size, size, nil)
            else
                fill(ix, y, size, size, theme.bg_elevated, 3)
            end
            local cd = opts.cooldowns and opts.cooldowns[spell_ids[i]]
            if cd and cd > 0 then
                fill(ix, y + size * (1 - cd), size, size * cd, theme.backdrop, 0)
            end
            if opts.highlight == spell_ids[i] then stroke(ix - 1, y - 1, size + 2, size + 2, theme.accent, 2, 3) end
        end
        return self
    end

    -- --- toasts -------------------------------------------------------------

    ---@class jcore_ui_toast_opts
    ---@field kind? "info"|"success"|"warning"|"danger"
    ---@field duration? number seconds (default 4)
    ---@field title? string
    ---@field icon? string  asset reference
    ---@field anchor? "top-right"|"top-left"|"bottom-right"|"bottom-left"|"top-center"

    --- A transient card at the screen corner. Distinct from draw.notify,
    --- which drives the client's own notification system.
    ---@param message string
    ---@param opts? jcore_ui_toast_opts
    function ui.toast(message, opts)
        opts = opts or {}
        local toasts = P.toasts
        if #toasts >= 6 then table.remove(toasts, 1) end
        toasts[#toasts + 1] = {
            message = tostring(message), title = opts.title, kind = opts.kind or "info",
            icon = opts.icon, t0 = core.time(), duration = opts.duration or 4,
            anchor = opts.anchor or ui.settings.toast_anchor or "top-right",
        }
    end
    Facade.toast = function(_, message, opts) return ui.toast(message, opts) end

    local function paint_toasts()
        local toasts = P.toasts
        if #toasts == 0 then return end
        local now = core.time()
        local w, gap = 280, 8
        local by_anchor = {}
        for i = #toasts, 1, -1 do
            local t = toasts[i]
            if now - t.t0 > t.duration then
                table.remove(toasts, i)
            else
                by_anchor[t.anchor] = by_anchor[t.anchor] or {}
                table.insert(by_anchor[t.anchor], 1, t)
            end
        end
        for anchor, list in pairs(by_anchor) do
            local y_cursor = anchor:find("bottom", 1, true) and (F.sh - 80) or 60
            for i = 1, #list do
                local t = list[i]
                local age = now - t.t0
                local remain = t.duration - age
                local alpha = min(1, age * 5, remain * 3)
                local size = T.font_small
                local lines = ui.wrap(t.message, size, w - 24 - (t.icon and 30 or 0))
                local h = (t.title and (T.font_body + 6) or 0) + #lines * (size + 4) + 14
                local x
                if anchor:find("left", 1, true) then x = 20
                elseif anchor:find("center", 1, true) then x = (F.sw - w) / 2
                else x = F.sw - w - 20 end
                local y = anchor:find("bottom", 1, true) and (y_cursor - h) or y_cursor
                local slide = (1 - alpha) * 20
                x = x + (anchor:find("left", 1, true) and -slide or slide)

                ui._begin_overlay("\1toast" .. i, x, y, w, h, draw.LAYER.TOOLTIP + 3, alpha * (theme.opacity or 1))
                fill(x + 2, y + 3, w, h, theme.shadow, T.rounding)
                fill(x, y, w, h, theme.bg_elevated, T.rounding)
                local accent = theme[t.kind] or theme.info
                fill(x, y, 3, h, accent, 0)
                stroke(x, y, w, h, theme.border, 1, T.rounding)
                local tx = x + 12
                if t.icon then
                    image(t.icon, tx, y + 8, 24, 24, nil)
                    tx = tx + 30
                end
                local ty = y + 6
                if t.title then
                    text_row(truncate(t.title, T.font_body, w - (tx - x) - 8), tx, ty, T.font_body + 6, T.font_body, theme.text)
                    ty = ty + T.font_body + 6
                end
                for j = 1, #lines do
                    text(lines[j], tx, ty + (j - 1) * (size + 4) + 2, size, theme.text_dim)
                end
                local frac = util.clamp(remain / t.duration, 0, 1)
                fill(x + 3, y + h - 2, (w - 3) * frac, 2, accent, 0)
                ui._end_overlay()

                if anchor:find("bottom", 1, true) then y_cursor = y_cursor - h - gap
                else y_cursor = y_cursor + h + gap end
            end
        end
    end

    -- --- modal --------------------------------------------------------------

    ---@class jcore_ui_confirm
    ---@field title string
    ---@field body string|string[]
    ---@field tone? "info"|"warning"|"danger"
    ---@field confirm_label? string
    ---@field cancel_label? string
    ---@field hide_cancel? boolean
    ---@field on_confirm? fun()
    ---@field on_cancel? fun()
    ---@field w? number

    --- A blocking dialog over everything. One at a time; a second request
    --- while one is open replaces it.
    ---@param req jcore_ui_confirm
    function ui.confirm(req)
        req = req or {}
        P.modal = {
            title = req.title or "Confirm", body = req.body or "", tone = req.tone or "info",
            confirm_label = req.confirm_label or "OK", cancel_label = req.cancel_label or "Cancel",
            hide_cancel = req.hide_cancel, on_confirm = req.on_confirm, on_cancel = req.on_cancel,
            w = req.w or 340, opened = core.time(),
            -- Seeded so a key already held when the dialog opens does not
            -- cancel it on its first frame.
            esc_down = input.is_key_pressed(VK.ESCAPE),
        }
    end
    Facade.confirm = function(_, req) return ui.confirm(req) end

    function ui.close_modal()
        P.modal = nil
        P.modal_rect = nil
    end

    local function paint_modal()
        local m = P.modal
        if not m then return end
        local size = T.font_body
        local lines = {}
        if type(m.body) == "table" then
            for i = 1, #m.body do
                local sub = ui.wrap(tostring(m.body[i]), size, m.w - 32)
                for j = 1, #sub do lines[#lines + 1] = sub[j] end
            end
        else
            lines = ui.wrap(tostring(m.body), size, m.w - 32)
        end
        local w = m.w
        local h = T.title_h + 16 + #lines * (size + 5) + 16 + T.widget_h + 12
        local x, y = (F.sw - w) / 2, (F.sh - h) / 2
        P.modal_rect = { x, y, w, h }

        ui._begin_overlay("\1modal", x, y, w, h, draw.LAYER.TOOLTIP + 6)
        fill(0, 0, F.sw, F.sh, theme.backdrop, 0)
        fill(x + 2, y + 4, w, h, theme.shadow, T.rounding)
        fill(x, y, w, h, theme.bg, T.rounding)
        local accent = theme[m.tone] or theme.accent
        fill(x, y, w, T.title_h, theme.bg_title, T.rounding)
        fill(x, y, 3, T.title_h, accent, 0)
        text_row(m.title, x + 12, y, T.title_h, T.font_title, theme.text)
        stroke(x, y, w, h, accent, 1, T.rounding)
        for i = 1, #lines do
            text(lines[i], x + 16, y + T.title_h + 12 + (i - 1) * (size + 5), size, theme.text)
        end

        local by = y + h - T.widget_h - 12
        local bw = 110
        local uid = "\1modal"
        local confirm_x = x + w - bw - 12
        local cancel_x = confirm_x - bw - 8
        local function paint_button(bx, label, primary, tone)
            local hovered, held, clicked = button_behaviour(uid .. label, bx, by, bw, T.widget_h)
            local bg = primary and (tone == "danger" and theme.danger or theme.accent) or theme.bg_elevated
            if held then bg = theme.bg_active elseif hovered and not primary then bg = theme.bg_hover end
            fill(bx, by, bw, T.widget_h, bg, T.rounding)
            if hovered then stroke(bx, by, bw, T.widget_h, theme.border_focus, 1, T.rounding) end
            text_row(label, bx, by, T.widget_h, T.font_body, primary and theme.accent_text or theme.text, "center", bw)
            return clicked
        end
        if paint_button(confirm_x, m.confirm_label, true, m.tone) then
            ui.close_modal()
            if m.on_confirm then pcall(m.on_confirm) end
        elseif not m.hide_cancel and paint_button(cancel_x, m.cancel_label, false) then
            ui.close_modal()
            if m.on_cancel then pcall(m.on_cancel) end
        end
        -- Escape cancels. Polled directly: F.keys is only filled while a
        -- text field has focus, and a modal has none.
        local esc = input.is_key_pressed(VK.ESCAPE)
        if esc and not m.esc_down then
            ui.close_modal()
            if m.on_cancel then pcall(m.on_cancel) end
        end
        m.esc_down = esc
        ui._end_overlay()
    end

    ui._on_end_frame(function()
        paint_toasts()
        paint_modal()
    end)

    -- --- code editor (1.8.7) ------------------------------------------------
    --
    -- A multi-line text box for code: Jambix AIO's reactions take their
    -- conditions and actions as Lua typed straight into a window. One string
    -- in, one string out, like text_input; the lines are split only when the
    -- text changes. Enter breaks the line and keeps its indent, Tab puts in
    -- four spaces, the arrows walk the lines, Ctrl+A / C / X / V select all,
    -- copy, cut and paste. Lua is coloured (keywords, strings, numbers,
    -- comments, and any words the caller names), and the caller can mark one
    -- line as wrong (a compile error) with a message under the box.

    local line_fn = line
    local LUA_WORDS = {}
    for w in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while")
        :gmatch("%a+") do
        LUA_WORDS[w] = true
    end

    local function split_lines(s)
        local out = {}
        s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
        local start = 1
        while true do
            local nl = s:find("\n", start, true)
            if not nl then
                out[#out + 1] = s:sub(start)
                break
            end
            out[#out + 1] = s:sub(start, nl - 1)
            start = nl + 1
        end
        return out
    end

    --- One line as coloured runs: { text, colour } in order. Strings and
    --- comments end with the line (a long string or block comment is
    --- coloured line by line, which is right for the short code it is for).
    local function lua_runs(s, extra)
        local runs = {}
        local i, n = 1, #s
        local function put(text, col)
            if text ~= "" then runs[#runs + 1] = { text, col } end
        end
        while i <= n do
            local c = s:sub(i, i)
            if c == "-" and s:sub(i + 1, i + 1) == "-" then
                put(s:sub(i), theme.text_disabled)
                break
            elseif c == "\"" or c == "'" then
                local j = i + 1
                while j <= n do
                    local d = s:sub(j, j)
                    if d == "\\" then j = j + 1
                    elseif d == c then break end
                    j = j + 1
                end
                put(s:sub(i, j), theme.success)
                i = j + 1
            elseif c:match("%d") then
                local j = i
                while j <= n and s:sub(j, j):match("[%w%.]") do j = j + 1 end
                put(s:sub(i, j - 1), theme.warning)
                i = j
            elseif c:match("[%a_]") then
                local j = i
                while j <= n and s:sub(j, j):match("[%w_]") do j = j + 1 end
                local word = s:sub(i, j - 1)
                local col = theme.text
                if LUA_WORDS[word] then col = theme.accent
                elseif extra and extra[word] then col = theme.info end
                put(word, col)
                i = j
            else
                local j = i
                while j <= n and not s:sub(j, j):match("[%w_\"'%-]") do j = j + 1 end
                if j == i then j = i + 1 end
                put(s:sub(i, j - 1), theme.text_dim)
                i = j
            end
        end
        return runs
    end

    ---@class jcore_ui_code_opts: jcore_ui_value_opts
    ---@field label? string
    ---@field rows? integer         visible lines (default 8)
    ---@field h? number             height in pixels, over rows
    ---@field line_numbers? boolean default true
    ---@field syntax? "lua"|false   default "lua"
    ---@field words? table<string, boolean>  extra names to colour (an API the code calls)
    ---@field error_line? integer   a line to mark as wrong
    ---@field error? string         the message under the box
    ---@field placeholder? string
    ---@field max_len? integer
    ---@field tab? string           what Tab puts in (four spaces)

    --- A multi-line code box. Returns the text, whether it was edited this
    --- frame, and whether it has the keyboard.
    ---@param id string
    ---@param default? string
    ---@param opts? jcore_ui_code_opts
    ---@return string text
    ---@return boolean changed
    ---@return boolean focused
    function Facade:code(id, default, opts)
        opts = opts or {}
        local uid = uid_for(id)
        local st, v = value_of(uid, default or "", opts.persist)
        v = tostring(v == nil and "" or v)
        if st.src ~= v or not st.lines then
            st.lines = split_lines(v)
            st.src = v
        end
        local lines = st.lines

        local size = T.font_small + 1
        local line_h = size + 5
        local rows = opts.rows or 8
        local box_h = opts.h or (rows * line_h + 8)
        local label = opts.label
        local err_h = opts.error and (T.font_small + 6) or 0
        local x, y, w = place((label and (T.font_small + 4) or 0) + box_h + err_h)
        local fy = y
        if label then
            text_row(truncate(label, T.font_small, w), x + 4, y, T.font_small + 4, T.font_small, theme.text_dim)
            fy = y + T.font_small + 4
        end
        local hovered, _, clicked = button_behaviour(uid, x, fy, w, box_h, opts.disabled)
        local focused = P.focus == uid
        local numbers = opts.line_numbers ~= false
        local gutter = numbers and (text_w(tostring(math.max(#lines, 10)), T.font_micro) + 14) or 6
        local tx0 = x + gutter + 4
        local view_h = box_h - 8
        st.sy = st.sy or 0
        st.sx = st.sx or 0
        st.row = util.clamp(st.row or #lines, 1, #lines)
        st.col = util.clamp(st.col or #lines[st.row], 0, #lines[st.row])

        if clicked then
            P.focus = uid
            P.listening = nil
            focused = true
            st.select_all = false
            st.follow = true
            local r = util.clamp(floor((F.my - fy - 4 + st.sy) / line_h) + 1, 1, #lines)
            local line = lines[r]
            local want = F.mx - tx0 + st.sx
            local c = #line
            for i = 1, #line do
                local edge = (text_w(line:sub(1, i - 1), size) + text_w(line:sub(1, i), size)) / 2
                if edge > want then c = i - 1 break end
            end
            st.row, st.col = r, c
        end

        local changed = false
        if focused and F.keys then
            local keys, typed = F.keys, F.typed
            local function total() local n = 0 for i = 1, #lines do n = n + #lines[i] + 1 end return n end
            local function clear()
                lines = { "" }
                st.row, st.col = 1, 0
                st.select_all = false
                changed = true
            end
            local function insert(text)
                if st.select_all then clear() end
                if opts.max_len and total() + #text > opts.max_len then return end
                local parts = split_lines(text)
                local line = lines[st.row]
                local before, after = line:sub(1, st.col), line:sub(st.col + 1)
                local fresh = {}
                for i = 1, st.row - 1 do fresh[#fresh + 1] = lines[i] end
                if #parts == 1 then
                    fresh[#fresh + 1] = before .. parts[1] .. after
                    st.col = st.col + #parts[1]
                else
                    fresh[#fresh + 1] = before .. parts[1]
                    for i = 2, #parts - 1 do fresh[#fresh + 1] = parts[i] end
                    fresh[#fresh + 1] = parts[#parts] .. after
                    st.col = #parts[#parts]
                end
                local caret_row = #fresh
                for i = st.row + 1, #lines do fresh[#fresh + 1] = lines[i] end
                lines, st.row = fresh, caret_row
                changed = true
            end
            local moved = false
            if keys.ctrl_a then st.select_all = true end
            if keys.ctrl_c and ui.clipboard_set then ui.clipboard_set(table.concat(lines, "\n")) end
            if keys.ctrl_x and st.select_all then
                if ui.clipboard_set then ui.clipboard_set(table.concat(lines, "\n")) end
                clear()
            end
            if keys.ctrl_v then
                local pasted = ui.clipboard_get and ui.clipboard_get() or nil
                if pasted and pasted ~= "" then insert((pasted:gsub("\t", opts.tab or "    "))) end
            end
            for i = 1, #typed do insert(typed[i]) end
            if keys[VK.RETURN] then
                local indent = lines[st.row]:match("^[ \t]*") or ""
                if #indent > st.col then indent = indent:sub(1, st.col) end
                insert("\n" .. indent)
            end
            if keys[VK.TAB] then insert(opts.tab or "    ") end
            if keys[VK.BACK] then
                if st.select_all then clear()
                elseif st.col > 0 then
                    local line = lines[st.row]
                    lines[st.row] = line:sub(1, st.col - 1) .. line:sub(st.col + 1)
                    st.col = st.col - 1
                    changed = true
                elseif st.row > 1 then
                    local prev = lines[st.row - 1]
                    lines[st.row - 1] = prev .. lines[st.row]
                    table.remove(lines, st.row)
                    st.row, st.col = st.row - 1, #prev
                    changed = true
                end
            end
            if keys[VK.DELETE] then
                if st.select_all then clear()
                else
                    local line = lines[st.row]
                    if st.col < #line then
                        lines[st.row] = line:sub(1, st.col) .. line:sub(st.col + 2)
                        changed = true
                    elseif st.row < #lines then
                        lines[st.row] = line .. lines[st.row + 1]
                        table.remove(lines, st.row + 1)
                        changed = true
                    end
                end
            end
            if keys[VK.LEFT] then
                if st.col > 0 then st.col = st.col - 1
                elseif st.row > 1 then st.row = st.row - 1; st.col = #lines[st.row] end
                moved = true
            end
            if keys[VK.RIGHT] then
                if st.col < #lines[st.row] then st.col = st.col + 1
                elseif st.row < #lines then st.row = st.row + 1; st.col = 0 end
                moved = true
            end
            if keys[VK.UP] and st.row > 1 then
                st.row = st.row - 1
                st.col = min(st.col, #lines[st.row])
                moved = true
            end
            if keys[VK.DOWN] and st.row < #lines then
                st.row = st.row + 1
                st.col = min(st.col, #lines[st.row])
                moved = true
            end
            if keys[VK.HOME] then st.col = 0; moved = true end
            if keys[VK.END] then st.col = #lines[st.row]; moved = true end
            if moved then st.select_all = false end
            if keys[VK.ESCAPE] then
                P.focus = nil
                focused = false
            end
            if changed or moved then st.follow = true end
            if changed then
                v = table.concat(lines, "\n")
                st.lines, st.src = lines, v
                set_value(uid, v)
            end
        end

        -- Scrolling: the wheel over the box, else the caret kept in view.
        local content_h = #lines * line_h
        local max_sy = max(0, content_h - view_h)
        if hovered and F.wheel ~= 0 and not P.popup and max_sy > 0 then
            st.sy = util.clamp(st.sy - F.wheel * line_h * 3, 0, max_sy)
            F.wheel_claimed = true
            st.follow = false
        end
        if focused and st.follow then
            local cy = (st.row - 1) * line_h
            if cy < st.sy then st.sy = cy end
            if cy + line_h > st.sy + view_h then st.sy = cy + line_h - view_h end
            local cx = text_w(lines[st.row]:sub(1, st.col), size)
            local avail = w - gutter - 16
            if cx - st.sx > avail then st.sx = cx - avail end
            if cx < st.sx then st.sx = max(0, cx - 24) end
        end
        st.sy = util.clamp(st.sy, 0, max_sy)

        -- Paint.
        fill(x, fy, w, box_h, theme.bg_input, T.rounding)
        clip_push(x + 1, fy + 1, w - 2, box_h - 2)
        if numbers then fill(x + 1, fy + 1, gutter, box_h - 2, theme.bg_elevated, 0) end
        local first = max(1, floor(st.sy / line_h) + 1)
        local last = min(#lines, first + floor(view_h / line_h) + 1)
        local err_col = to_color({ 235, 87, 87, 55 }, theme.danger)
        for r = first, last do
            local ly = fy + 4 + (r - 1) * line_h - st.sy
            if opts.error_line == r then
                fill(x + 1, ly, w - 2, line_h, err_col, 0)
            elseif focused and r == st.row then
                fill(x + gutter + 1, ly, w - gutter - 2, line_h, theme.zebra, 0)
            end
            if numbers then
                text_row(tostring(r), x + 1, ly, line_h, T.font_micro,
                    opts.error_line == r and theme.danger or theme.text_disabled, "right", gutter - 6)
            end
        end
        clip_push(x + gutter + 2, fy + 1, w - gutter - 4, box_h - 2)
        if v == "" and not focused and opts.placeholder then
            text_row(truncate(opts.placeholder, size, w - gutter - 12), tx0, fy + 4, line_h, size, theme.text_disabled)
        end
        for r = first, last do
            local ly = fy + 4 + (r - 1) * line_h - st.sy
            local line = lines[r]
            if st.select_all and focused and line ~= "" then
                fill(tx0 - st.sx, ly + 1, text_w(line, size), line_h - 2, theme.accent_dim, 2)
            end
            if line ~= "" then
                if opts.syntax == false then
                    text_row(line, tx0 - st.sx, ly, line_h, size, opts.disabled and theme.text_disabled or theme.text)
                else
                    local px = tx0 - st.sx
                    local runs = lua_runs(line, opts.words)
                    for k = 1, #runs do
                        local run = runs[k]
                        local rw = text_w(run[1], size)
                        if px + rw >= x and px <= x + w then
                            text_row(run[1], px, ly, line_h, size, run[2])
                        end
                        px = px + rw
                    end
                end
            end
            if focused and r == st.row and (F.t % 1.0) < 0.6 then
                local cx = tx0 - st.sx + text_w(line:sub(1, st.col), size)
                line_fn(cx, ly + 2, cx, ly + line_h - 2, theme.text, 1)
            end
        end
        clip_pop()
        clip_pop()
        stroke(x, fy, w, box_h, opts.error_line and theme.danger
            or ((focused or hovered) and theme.border_focus or theme.border), 1, T.rounding)
        if max_sy > 0 then
            local track_h = box_h - 6
            local thumb_h = max(14, track_h * (view_h / content_h))
            local t = st.sy / max_sy
            local sx = x + w - T.scrollbar - 3
            fill(sx, fy + 3, T.scrollbar, track_h, theme.track, T.scrollbar / 2)
            fill(sx, fy + 3 + (track_h - thumb_h) * t, T.scrollbar, thumb_h, theme.text_dim, T.scrollbar / 2)
        end
        if opts.error then
            text_row(truncate(opts.error, T.font_small, w - 8), x + 4, fy + box_h + 2, err_h, T.font_small, theme.danger)
        end
        F.last_rect = { x, fy, w, box_h }
        F.last_uid = uid
        F.last_hot = hovered
        if opts.tooltip and hovered and not focused then P.tooltip = { text = opts.tooltip } end
        return v, changed, focused
    end

    -- --- clipboard ----------------------------------------------------------
    --
    -- The only clipboard access on this platform hangs off a native menu
    -- window object. One is created lazily and never begun; the copy and
    -- paste methods work without a frame. If this build refuses, both
    -- functions answer nil and the widgets simply have no clipboard.

    local clip_win = nil
    local clip_tried = false
    local function clip_window()
        if clip_tried then return clip_win end
        clip_tried = true
        local ok, w = pcall(core.menu.window, "jcore_ui_clipboard")
        if ok and w then clip_win = w end
        return clip_win
    end

    ---@param s string
    ---@return boolean
    function ui.clipboard_set(s)
        local w = clip_window()
        if not w or not w.copy_to_clipboard then return false end
        return pcall(w.copy_to_clipboard, w, tostring(s)) and true or false
    end

    ---@return string|nil
    function ui.clipboard_get()
        local w = clip_window()
        if not w or not w.get_clipboard_text then return nil end
        local ok, s = pcall(w.get_clipboard_text, w)
        if ok and type(s) == "string" then return s end
        return nil
    end

    return ui
end

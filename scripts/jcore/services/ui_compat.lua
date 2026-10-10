-- JCore / ui_compat -- every other way plugin code describes a UI, hosted
-- on the same windows.
--
-- Depends on: util, log, ui, scheduler, menu_ns.
--
-- Four fronts over the immediate-mode core, so "bring your Lua as it is"
-- holds for the code that exists on this platform:
--
-- 1. DECLARATIVE. A window as a table of widget specs, built once, values
--    read back by id. The shape `_G.menu` users already write, on the
--    overlay: `ui:declare({ id = "hud", title = "HUD", content = {...} })`.
--
-- 2. LEGACY MENUS. The `simple_ui` component model (menu:new, add_checkbox,
--    add_slider, component:get_value) reimplemented on these windows, so a
--    plugin written against that library moves over by changing its require.
--
-- 3. MENU MIRRORS. A widget bound to a `_G.menu` setting through a JCore
--    menu slice: read through ns:get, written through ns:set, so the HUD
--    shows and edits the same value the settings page does, with no second
--    copy of it anywhere.
--
-- 4. NATIVE ELEMENTS. An object from `core.menu.*` (checkbox, slider,
--    combobox, keybind, text input, colour picker, button) rendered as the
--    matching overlay widget and written back through its own setter, for
--    the imperative plugins that still build their menus that way.

return function(rt)
    local util = rt.util
    local ui = rt.ui
    local scheduler = rt.scheduler
    local log = rt.log.for_tag("JCore/ui")

    local Facade = ui.Facade
    local theme = ui.theme

    -- ==========================================================================
    -- 3. MENU MIRRORS
    -- ==========================================================================

    --- A toggle bound to a `_G.menu` boolean through a menu namespace.
    ---@param ns jcore_menu_ns
    ---@param id string widget id on that page
    ---@param label string
    ---@param opts? table
    ---@return boolean value
    function Facade:menu_toggle(ns, id, label, opts)
        local current = ns:get(id)
        if current == nil then current = false end
        local v, changed = self:toggle("\2menu:" .. ns.page_path .. "/" .. id, label, current, opts)
        if changed then
            ns:set(id, v)
            return v
        end
        -- The menu is the source of truth: reflect its value into ours when
        -- it moved underneath (a keybind, a profile load).
        if v ~= current then ui._set_value(ui._uid("\2menu:" .. ns.page_path .. "/" .. id), current) end
        return current
    end

    Facade.menu_checkbox = function(self, ns, id, label, opts)
        local current = ns:get(id)
        if current == nil then current = false end
        local v, changed = self:checkbox("\2menu:" .. ns.page_path .. "/" .. id, label, current, opts)
        if changed then ns:set(id, v) return v end
        if v ~= current then ui._set_value(ui._uid("\2menu:" .. ns.page_path .. "/" .. id), current) end
        return current
    end

    --- A slider bound to a `_G.menu` number.
    ---@param ns jcore_menu_ns
    ---@param id string
    ---@param label string
    ---@param lo number
    ---@param hi number
    ---@param opts? table
    ---@return number value
    function Facade:menu_slider(ns, id, label, lo, hi, opts)
        local current = tonumber(ns:get(id)) or lo
        local uid = "\2menu:" .. ns.page_path .. "/" .. id
        local v, changed = self:slider(uid, label, lo, hi, current, opts)
        if changed then ns:set(id, v) return v end
        if v ~= current then ui._set_value(ui._uid(uid), current) end
        return current
    end

    --- A dropdown bound to a `_G.menu` index. `options` must match the
    --- page's declaration.
    ---@param ns jcore_menu_ns
    ---@param id string
    ---@param label string|nil
    ---@param options string[]
    ---@param opts? table
    ---@return integer index
    function Facade:menu_dropdown(ns, id, label, options, opts)
        local current = tonumber(ns:get(id)) or 1
        local uid = "\2menu:" .. ns.page_path .. "/" .. id
        local v, changed = self:dropdown(uid, label, options, current, opts)
        if changed then ns:set(id, v) return v end
        if v ~= current then ui._set_value(ui._uid(uid), current) end
        return current
    end

    --- A `_G.menu` keybind shown as a read-only pill with its live state.
    --- Rebinding stays on the settings page, where the modifier chords are.
    ---@param ns jcore_menu_ns
    ---@param id string
    ---@param label string
    ---@return boolean active
    function Facade:menu_keybind(ns, id, label)
        local value = ns:get(id)
        local active = ns:is_keybind_active(id)
        local vk = type(value) == "table" and value.vk or 0
        local h = ui._T.widget_h
        local x, y, w = ui._place(h)
        local name = ui.key_name(vk)
        if type(value) == "table" and value.mods then
            local m = value.mods
            name = (m.ctrl and "Ctrl+" or "") .. (m.shift and "Shift+" or "") .. (m.alt and "Alt+" or "") .. name
        end
        local pill_w = math.max(56, ui.text_width(name, ui._T.font_small) + 18)
        local px = x + w - pill_w - 4
        ui._text_row(ui.truncate(label, ui._T.font_body, w - pill_w - 12), x + 4, y, h, ui._T.font_body, theme.text)
        ui.paint.fill(px, y + 2, pill_w, h - 4, active and theme.accent_dim or theme.bg_elevated, (h - 4) / 2)
        ui.paint.stroke(px, y + 2, pill_w, h - 4, active and theme.border_focus or theme.border, 1, (h - 4) / 2)
        ui._text_row(name, px, y + 2, h - 4, ui._T.font_small, theme.text, "center", pill_w)
        return active
    end

    --- A text field bound to a `_G.menu` string.
    function Facade:menu_text(ns, id, label, opts)
        local current = ns:get(id)
        if type(current) ~= "string" then current = "" end
        local uid = "\2menu:" .. ns.page_path .. "/" .. id
        local v, submitted = self:text_input(uid, label, current, opts)
        if submitted and v ~= current then ns:set(id, v) return v end
        return submitted and v or current
    end

    --- Mirrors a list of a page's widgets in one call, choosing the widget
    --- by the value's type. Numbers need a range: pass
    --- { id = "range", lo = 0, hi = 100 } entries for those.
    ---@param ns jcore_menu_ns
    ---@param specs (string|{ id: string, label?: string, lo?: number, hi?: number, options?: string[] })[]
    function Facade:menu_mirror(ns, specs)
        for i = 1, #specs do
            local spec = specs[i]
            if type(spec) == "string" then spec = { id = spec } end
            local id = spec.id
            local label = spec.label or id
            local value = ns:get(id)
            local kind = type(value)
            if kind == "boolean" then
                self:menu_toggle(ns, id, label)
            elseif kind == "number" then
                if spec.options then
                    self:menu_dropdown(ns, id, label, spec.options)
                else
                    self:menu_slider(ns, id, label, spec.lo or 0, spec.hi or 100)
                end
            elseif kind == "string" then
                self:menu_text(ns, id, label)
            elseif kind == "table" and value.vk ~= nil then
                self:menu_keybind(ns, id, label)
            else
                self:key_value(label, value == nil and "-" or tostring(value))
            end
        end
        return self
    end

    -- ==========================================================================
    -- 4. NATIVE ELEMENTS
    -- ==========================================================================

    local function call(obj, name, ...)
        local fn = obj and obj[name]
        if type(fn) ~= "function" then return nil end
        local ok, a, b = pcall(fn, obj, ...)
        if not ok then return nil end
        return a, b
    end

    --- What a `core.menu` object is, by the methods it answers to. The
    --- `get_type` integer is not documented, so duck typing is the
    --- portable answer.
    ---@param el any
    ---@return string|nil kind
    function ui.native_kind(el)
        if type(el) ~= "table" and type(el) ~= "userdata" then return nil end
        local function has_method(name)
            local ok2, present = pcall(function() return el[name] ~= nil end)
            return ok2 and present
        end
        if has_method("get_key_code") and has_method("get_main_checkbox_state") then return "key_checkbox" end
        if has_method("get_key_code") then return "keybind" end
        if has_method("get_state") then return "checkbox" end
        if has_method("get_items") or has_method("set_items") then return "combobox" end
        if has_method("get_text") then return "text_input" end
        if has_method("is_clicked") then return "button" end
        if has_method("get_default") and has_method("get") then
            local ok3, v = pcall(function() return el:get() end)
            if ok3 and type(v) == "table" and v.r then return "color_picker" end
            if ok3 and (type(v) == "table" and (v.r or v.get)) then return "color_picker" end
            return "slider"
        end
        return nil
    end

    ---@class jcore_ui_native_opts
    ---@field lo? number   slider range when the element does not expose one
    ---@field hi? number
    ---@field options? string[] combobox items when the element cannot list its own
    ---@field integer? boolean

    --- Renders a native menu element as an overlay widget and writes edits
    --- back through the element's own setter. Returns the element's value.
    ---@param el any core.menu element
    ---@param label string
    ---@param opts? jcore_ui_native_opts
    ---@return any value
    function Facade:native(el, label, opts)
        opts = opts or {}
        local kind = opts.kind or ui.native_kind(el)
        local key = "\3native:" .. tostring(el)
        if kind == "checkbox" then
            local current = call(el, "get_state") and true or false
            local v, changed = self:toggle(key, label, current)
            if changed then call(el, "set", v) return v end
            if v ~= current then ui._set_value(ui._uid(key), current) end
            return current
        elseif kind == "slider" then
            local current = tonumber(call(el, "get")) or 0
            local lo, hi = opts.lo or 0, opts.hi or math.max(100, current)
            local v, changed = self:slider(key, label, lo, hi, current, { integer = opts.integer })
            if changed then call(el, "set", v) return v end
            if v ~= current then ui._set_value(ui._uid(key), current) end
            return current
        elseif kind == "combobox" then
            local items = opts.options or call(el, "get_items") or {}
            local current = tonumber(call(el, "get")) or 1
            local v, changed = self:dropdown(key, label, items, current)
            if changed then call(el, "set", v) return v end
            if v ~= current then ui._set_value(ui._uid(key), current) end
            return current
        elseif kind == "keybind" or kind == "key_checkbox" then
            local vk = tonumber(call(el, "get_key_code")) or 0
            local state = kind == "keybind" and call(el, "get_toggle_state") or call(el, "get_keybind_state")
            local active, new_vk = self:keybind(key, label, vk, { mode = "hold" })
            if new_vk ~= vk then call(el, "set_key", new_vk) end
            return state or active
        elseif kind == "text_input" then
            local current = call(el, "get_text") or ""
            local v, submitted = self:text_input(key, label, current)
            if submitted then
                if not call(el, "set_buffer", v) then call(el, "set", v) end
                return v
            end
            return current
        elseif kind == "color_picker" then
            local current = call(el, "get")
            local r, g, b, a = ui.channels(current)
            local v = self:color(key, label, { r = r, g = g, b = b, a = a })
            if v.r ~= r or v.g ~= g or v.b ~= b or v.a ~= a then
                call(el, "set", ui.rgba(v.r, v.g, v.b, v.a))
            end
            return v
        elseif kind == "button" then
            return self:button(key, label)
        end
        self:key_value(label, "unsupported element")
        return nil
    end

    -- ==========================================================================
    -- 1. DECLARATIVE
    -- ==========================================================================

    ---@class jcore_ui_spec_item
    ---@field kind string   text|heading|separator|spacer|button|icon_button|toggle|checkbox|slider|dropdown|tabs|text_input|keybind|color|progress|image|spell_icon|group|row|list|table|custom|raw|bind|native|live|key_value|badge|bar|unit_frame|player_frame
    ---@field id? string
    ---@field label? string
    ---@field default? any
    ---@field opts? table
    ---@field children? jcore_ui_spec_item[]   for group and row
    ---@field visible? boolean|fun(): boolean
    ---@field on_change? fun(new: any, old: any)
    ---@field on_click? fun()

    --- Renders one spec item with the immediate-mode calls.
    local function render_item(ui_facade, handle, item, index)
        local kind = item.kind or item[1]
        if item.visible ~= nil then
            local vis = item.visible
            if type(vis) == "function" then
                local ok, v = pcall(vis)
                vis = ok and v
            end
            if not vis then return end
        end
        local id = item.id or item[2]
        local label = item.label or item[3]
        local default = item.default
        if default == nil then default = item[4] end
        local opts = item.opts or {}
        if id == nil then id = "\4" .. tostring(index) end

        if kind == "text" or kind == "label" then
            ui_facade:text(label or item.text or "", opts)
        elseif kind == "heading" then
            ui_facade:heading(label or item.text or "", opts)
        elseif kind == "live" then
            ui_facade:live(item.fn or item[2], opts)
        elseif kind == "separator" then
            ui_facade:separator(label)
        elseif kind == "spacer" then
            ui_facade:spacer(item.h or item[2])
        elseif kind == "key_value" then
            local v = item.value or item[3]
            if type(v) == "function" then local ok, r = pcall(v); v = ok and r or "?" end
            ui_facade:key_value(label or item[2], v, opts)
        elseif kind == "badge" then
            ui_facade:badge(label or item.text, item.tone or item[3])
        elseif kind == "button" then
            if ui_facade:button(id, label or id, opts) then
                local fn = item.on_click or opts.on_click
                if fn then pcall(fn, handle) end
            end
        elseif kind == "icon_button" then
            if ui_facade:icon_button(id, item.icon or item[3], opts) then
                if item.on_click then pcall(item.on_click, handle) end
            end
        elseif kind == "toggle" or kind == "checkbox" then
            local fn = kind == "toggle" and ui_facade.toggle or ui_facade.checkbox
            local v, changed = fn(ui_facade, id, label or id, default, opts)
            if changed and item.on_change then pcall(item.on_change, v) end
        elseif kind == "slider" then
            local lo, hi = item.min or item.lo or 0, item.max or item.hi or 100
            local v, changed = ui_facade:slider(id, label or id, lo, hi, default or lo, opts)
            if changed and item.on_change then pcall(item.on_change, v) end
        elseif kind == "dropdown" then
            local options = item.options or {}
            local v, changed = ui_facade:dropdown(id, label, options, default or 1, opts)
            if changed and item.on_change then pcall(item.on_change, v, options[v]) end
        elseif kind == "tabs" then
            local v = ui_facade:tabs(id, item.options or {}, default or 1, opts)
            if item.pages and item.pages[v] then
                local page = item.pages[v]
                for i = 1, #page do render_item(ui_facade, handle, page[i], i) end
            end
        elseif kind == "text_input" then
            local v, submitted = ui_facade:text_input(id, label, default or "", opts)
            if submitted and item.on_submit then pcall(item.on_submit, v) end
        elseif kind == "keybind" then
            local active = ui_facade:keybind(id, label or id, default or 0, opts)
            if active and item.on_active then pcall(item.on_active) end
        elseif kind == "color" then
            ui_facade:color(id, label or id, default, opts)
        elseif kind == "progress" then
            local frac = item.source or item.value or 0
            if type(frac) == "function" then local ok, r = pcall(frac); frac = ok and r or 0 end
            ui_facade:progress(frac, { label = label, color = item.color, h = item.h })
        elseif kind == "bar" then
            local frac = item.source or item.value or 0
            if type(frac) == "function" then local ok, r = pcall(frac); frac = ok and r or 0 end
            ui_facade:bar(label or "", frac, { color = item.color, h = item.h, text = item.text })
        elseif kind == "image" then
            ui_facade:image(item.ref or item[2], item.w or item[3], item.h or item[4], opts)
        elseif kind == "spell_icon" then
            ui_facade:spell_icon(item.spell_id or item[2], item.size or item[3], opts)
        elseif kind == "unit_frame" then
            local unit = item.unit
            if type(unit) == "function" then local ok, u = pcall(unit); unit = ok and u or nil end
            ui_facade:unit_frame(unit, opts)
        elseif kind == "player_frame" then
            ui_facade:player_frame(opts)
        elseif kind == "group" then
            local open = ui_facade:group(id, label, opts)
            if open and item.children then
                for i = 1, #item.children do render_item(ui_facade, handle, item.children[i], i) end
            end
            ui_facade:end_group()
        elseif kind == "row" then
            ui_facade:row(item.widths or item[2] or #(item.children or {}), opts)
            if item.children then
                for i = 1, #item.children do render_item(ui_facade, handle, item.children[i], i) end
            end
            ui_facade:end_row()
        elseif kind == "list" then
            local items = item.items or {}
            if type(items) == "function" then local ok, r = pcall(items); items = ok and r or {} end
            local sel, clicked = ui_facade:list(id, items, opts)
            if clicked and item.on_select then pcall(item.on_select, clicked, items[clicked]) end
        elseif kind == "table" then
            local rows = item.rows or {}
            if type(rows) == "function" then local ok, r = pcall(rows); rows = ok and r or {} end
            local sel, clicked = ui_facade:table(id, item.columns or {}, rows, opts)
            if clicked and item.on_select then pcall(item.on_select, clicked, rows[clicked]) end
        elseif kind == "custom" then
            ui_facade:custom(id, item.h or item[3] or 40, item.paint or item[2])
        elseif kind == "raw" then
            ui_facade:raw(item.h or item[3] or 40, item.fn or item[2])
        elseif kind == "bind" then
            -- { "bind", ns, "widget_id", "Label", lo=, hi=, options= }
            local ns = item.ns or item[2]
            local wid = item.widget or item[3]
            ui_facade:menu_mirror(ns, { { id = wid, label = item.label or item[4], lo = item.lo, hi = item.hi, options = item.options } })
        elseif kind == "native" then
            ui_facade:native(item.element or item[2], label or item[3] or "", opts)
        elseif kind == "tree" then
            local open = ui_facade:tree(id, label or id, default, opts)
            if open and item.children then
                for i = 1, #item.children do render_item(ui_facade, handle, item.children[i], i) end
            end
            if open then ui_facade:end_tree() end
        else
            ui_facade:text("unknown widget kind: " .. tostring(kind), { color = "danger" })
        end
    end
    ui._render_spec_item = render_item

    ---@class jcore_ui_spec: jcore_ui_window_opts
    ---@field id string
    ---@field content jcore_ui_spec_item[]

    --- Declares a window from a spec table. Returns the retained handle,
    --- extended with `get(id)`, `set(id, v)`, `on_change(id, fn)` and
    --- `set_content(items)` for a live swap.
    ---@param spec jcore_ui_spec
    ---@return table handle
    function Facade:declare(spec)
        local content = spec.content or {}
        local opts = util.shallow_copy(spec)
        opts.content = nil
        opts.id = nil
        local handle
        handle = self:window(spec.id, opts, function(ui_facade, h)
            for i = 1, #content do
                render_item(ui_facade, h, content[i], i)
            end
        end)
        function handle.set_content(items)
            content = items or {}
        end
        function handle.content()
            return content
        end
        return handle
    end

    -- ==========================================================================
    -- 2. LEGACY MENUS (simple_ui shape)
    -- ==========================================================================
    --
    -- The old library is a class-per-component model with explicit x/y and
    -- explicit update()/render() calls per frame. Here the components are
    -- records that a retained window renders in declaration order; x/y are
    -- accepted and ignored (the layout flows), update() is a no-op, and
    -- render() marks the menu wanted this frame, which is what is_open is
    -- for. Everything a plugin reads back -- get_value, is_checked, check(),
    -- callbacks -- behaves as before.

    local Legacy = {}
    Legacy.__index = Legacy

    local Component = {}
    Component.__index = Component

    function Component:get_value() return self.value end
    function Component:set_value(v)
        self.value = v
        if self.menu and self.menu.handle then self.menu.handle.set_value(self.id, v) end
    end
    function Component:set_visible(v) self.visible = v ~= false end
    function Component:set_enabled(v) self.enabled = v ~= false end
    function Component:set_text(t) self.text = t end
    function Component:set_position() end
    function Component:set_size() end
    function Component:is_active() return self.visible and self.enabled end
    function Component:is_checked() return self.value and true or false end
    function Component:toggle() self:set_value(not self.value) end
    function Component:click() if self.on_click then pcall(self.on_click, self) end end
    function Component:get_percentage()
        if self.type == "slider" then
            return (self.value - self.min_value) / math.max(1e-9, self.max_value - self.min_value)
        end
        return (self.value or 0) / math.max(1e-9, self.max_value or 1)
    end
    function Component:set_percentage(p)
        self:set_value(self.min_value + (self.max_value - self.min_value) * util.clamp(p, 0, 1))
    end
    function Component:set_range(lo, hi)
        self.min_value, self.max_value = lo, hi
        self:set_value(util.clamp(self.value or lo, lo, hi))
    end
    function Component:set_max(m) self.max_value = m end
    function Component:get_selected_text() return self.items and self.items[self.value] or "" end
    function Component:set_selected(i) self:set_value(i) end
    function Component:set_items(items) self.items = items end
    function Component:add_item(item) self.items[#self.items + 1] = item end
    function Component:remove_item(i) table.remove(self.items, i) end
    function Component:get_key_name() return ui.key_name(self.value) end
    function Component:is_pressed() return self.value and self.value > 0 and rt.input.is_key_pressed(self.value) or false end
    function Component:check() return self.active or false end
    function Component:get_color() return ui.rgba(self.value.r, self.value.g, self.value.b, self.value.a) end
    function Component:set_color(r, g, b, a) self:set_value({ r = r, g = g, b = b, a = a or 255 }) end
    function Component:append(t) self:set_value((self.value or "") .. t) end
    function Component:clear() self:set_value("") end
    function Component:expand() self:set_value(true) end
    function Component:collapse() self:set_value(false) end
    function Component:add_child(child) self.children[#self.children + 1] = child; child.parent = self; return child end
    function Component:remove_child(i) table.remove(self.children, i) end
    function Component:is_item_selected(i) return self.value == i end
    function Component:select_item(i) self:set_value(i) end
    function Component:get_bounds() return { x = 0, y = 0, width = 0, height = 0 } end
    function Component:contains_point() return false end
    function Component:save_value() end
    function Component:load_value() return false end

    local function new_component(menu, type_name, text, fields)
        local c = setmetatable({
            type = type_name, id = menu:generate_id(type_name), text = text or "",
            visible = true, enabled = true, menu = menu, data = {}, children = {},
        }, Component)
        for k, v in pairs(fields or {}) do c[k] = v end
        menu.components[c.id] = c
        menu.component_order[#menu.component_order + 1] = c.id
        return c
    end

    local function render_legacy_component(ui_facade, menu, c)
        if not c.visible then return end
        local disabled = not c.enabled
        local t = c.type
        if t == "label" then
            ui_facade:text(c.text, { size = c.font_size, align = c.centered and "center" or nil })
        elseif t == "header" then
            ui_facade:heading(c.text)
            if c.show_line ~= false then ui_facade:separator() end
        elseif t == "separator" then
            ui_facade:separator()
        elseif t == "checkbox" then
            local v, changed = ui_facade:checkbox(c.id, c.text, c.value, { disabled = disabled })
            if changed then
                c.value = v
                if c.on_change then pcall(c.on_change, c, v) end
            elseif v ~= c.value then
                ui._set_value(ui._uid(c.id), c.value)
            end
        elseif t == "slider" then
            local v, changed = ui_facade:slider(c.id, c.text, c.min_value, c.max_value, c.value,
                { disabled = disabled, integer = c.slider_type == "int" })
            if changed then
                c.value = v
                if c.on_change then pcall(c.on_change, c, v) end
            elseif v ~= c.value then
                ui._set_value(ui._uid(c.id), c.value)
            end
        elseif t == "button" then
            if ui_facade:button(c.id, c.text, { disabled = disabled, style = c.style }) then
                if c.on_click then pcall(c.on_click, c) end
            end
        elseif t == "progressbar" then
            local frac = (c.value or 0) / math.max(1e-9, c.max_value or 1)
            ui_facade:progress(frac, { label = c.show_text ~= false and c.text or nil, color = c.fill_color })
        elseif t == "textinput" then
            local v, submitted = ui_facade:text_input(c.id, c.text, c.value, { placeholder = c.placeholder, max_len = c.max_length, disabled = disabled })
            if v ~= c.value then
                c.value = v
                if c.on_change then pcall(c.on_change, c, v) end
            end
        elseif t == "combobox" then
            local v, changed = ui_facade:dropdown(c.id, c.text, c.items or {}, c.value, { disabled = disabled })
            if changed then
                c.value = v
                if c.on_change then pcall(c.on_change, c, v, c.items[v]) end
            elseif v ~= c.value then
                ui._set_value(ui._uid(c.id), c.value)
            end
        elseif t == "keybind" then
            local active, vk = ui_facade:keybind(c.id, c.text, c.value, { mode = c.is_toggle and "toggle" or "hold", disabled = disabled })
            c.active = active
            if vk ~= c.value then
                c.value = vk
                if c.on_change then pcall(c.on_change, c, vk) end
            end
        elseif t == "colorpicker" then
            local v = ui_facade:color(c.id, c.text, c.value, { disabled = disabled })
            if v ~= c.value and (v.r ~= c.value.r or v.g ~= c.value.g or v.b ~= c.value.b or v.a ~= c.value.a) then
                c.value = v
                if c.on_change then pcall(c.on_change, c, c:get_color()) end
            end
        elseif t == "treenode" then
            local open = ui_facade:tree(c.id, c.text, c.value)
            if open ~= c.value then
                c.value = open
                if c.on_change then pcall(c.on_change, c, open) end
            end
            if open then
                for i = 1, #c.children do render_legacy_component(ui_facade, menu, c.children[i]) end
                ui_facade:end_tree()
            end
        elseif t == "listbox" then
            local sel, clicked = ui_facade:list(c.id, c.items or {}, { h = (c.item_height or 22) * (c.visible_rows or 6) })
            if clicked then
                c.value = clicked
                if c.on_change then pcall(c.on_change, c, clicked, c.items[clicked]) end
            end
        end
    end

    --- Creates a legacy-shaped menu on an overlay window.
    ---@param title string
    ---@param width? number
    ---@param height? number
    ---@param save_key? string
    ---@return table menu
    function Legacy:new(title, width, height, save_key)
        local menu = setmetatable({
            title = title or "Menu", width = width or 300, height = height or 400,
            save_key = save_key or util.slug(title or "menu"), is_open = true, is_collapsed = false,
            components = {}, component_order = {}, next_y = 0, saved_data = {}, id_counter = 0,
        }, Legacy)
        local facade = self.facade or ui
        menu.handle = facade:window("legacy:" .. menu.save_key, {
            title = menu.title, w = menu.width, min_h = 40, closable = true, resizable = true, h = menu.height,
            visible = true,
            on_close = function() menu.is_open = false end,
        }, function(ui_facade)
            for i = 1, #menu.component_order do
                local c = menu.components[menu.component_order[i]]
                if c and not c.parent then render_legacy_component(ui_facade, menu, c) end
            end
        end)
        return menu
    end

    function Legacy:generate_id(prefix)
        self.id_counter = self.id_counter + 1
        return (prefix or "c") .. "_" .. self.id_counter
    end
    function Legacy:update() end
    function Legacy:render() end
    function Legacy:show() self.is_open = true; self.handle.show() end
    function Legacy:hide() self.is_open = false; self.handle.hide() end
    function Legacy:toggle() if self.is_open then self:hide() else self:show() end end
    function Legacy:collapse() self.is_collapsed = true; ui:set_collapsed(self.handle.id, true) end
    function Legacy:expand() self.is_collapsed = false; ui:set_collapsed(self.handle.id, false) end
    function Legacy:toggle_collapse() if self.is_collapsed then self:expand() else self:collapse() end end
    function Legacy:get_display_height() return self.height end
    function Legacy:get_next_y() return 0 end
    function Legacy:advance_y() end
    function Legacy:update_height() end
    function Legacy:add_component(c) self.components[c.id] = c; self.component_order[#self.component_order + 1] = c.id; return c end
    function Legacy:get_component(id) return self.components[id] end
    function Legacy:remove_component(id)
        self.components[id] = nil
        util.array_remove(self.component_order, id)
    end
    function Legacy:clear_components() self.components = {}; self.component_order = {} end
    function Legacy:save_component() end
    function Legacy:load_component() return nil end
    function Legacy:save_all() end
    function Legacy:load_all() end
    function Legacy:is_mouse_over()
        return ui._F.hover_win == self.handle.id
    end

    function Legacy:add_label(text, _, _, options)
        return new_component(self, "label", text, options)
    end
    function Legacy:add_separator(_, _, options) return new_component(self, "separator", "", options) end
    function Legacy:add_header(text, _, _, options) return new_component(self, "header", text, options) end
    function Legacy:add_checkbox(text, _, _, default, callback, options)
        return new_component(self, "checkbox", text, util.deep_merge({ value = default and true or false, on_change = callback }, options or {}))
    end
    function Legacy:add_slider(text, _, _, lo, hi, default, callback, options)
        options = options or {}
        return new_component(self, "slider", text, util.deep_merge({
            min_value = lo, max_value = hi, value = default or lo, on_change = callback,
            slider_type = options.slider_type or ((hi - lo) >= 2 and "int" or "float"),
        }, options))
    end
    function Legacy:add_button(text, _, _, _, _, callback, options)
        return new_component(self, "button", text, util.deep_merge({ on_click = callback }, options or {}))
    end
    function Legacy:add_progressbar(text, _, _, value, max_value, options)
        return new_component(self, "progressbar", text, util.deep_merge({ value = value or 0, max_value = max_value or 100 }, options or {}))
    end
    function Legacy:add_textinput(text, _, _, default, callback, options)
        return new_component(self, "textinput", text, util.deep_merge({ value = default or "", on_change = callback }, options or {}))
    end
    function Legacy:add_combobox(text, _, _, items, default, callback, options)
        return new_component(self, "combobox", text, util.deep_merge({ items = items or {}, value = default or 1, on_change = callback }, options or {}))
    end
    function Legacy:add_keybind(text, _, _, default, callback, options)
        return new_component(self, "keybind", text, util.deep_merge({ value = default or 0, on_change = callback }, options or {}))
    end
    function Legacy:add_colorpicker(text, _, _, default, callback, options)
        default = default or { r = 255, g = 255, b = 255, a = 255 }
        return new_component(self, "colorpicker", text, util.deep_merge({ value = default, on_change = callback }, options or {}))
    end
    function Legacy:add_treenode(text, _, _, default, callback, options)
        return new_component(self, "treenode", text, util.deep_merge({ value = default and true or false, on_change = callback }, options or {}))
    end
    function Legacy:add_listbox(text, _, _, items, default, callback, options)
        return new_component(self, "listbox", text, util.deep_merge({ items = items or {}, value = default or 0, on_change = callback }, options or {}))
    end

    --- The legacy front. `ui.legacy.menu:new(...)` mirrors simple_ui's
    --- `simple_ui.menu:new(...)`; `for_owner` binds the windows to a plugin.
    ui.legacy = {
        menu = Legacy,
        VERSION = "compat-1",
        for_owner = function(facade)
            return { menu = setmetatable({ facade = facade }, Legacy) }
        end,
    }

    --- Legacy front bound to this facade's owner.
    function Facade:legacy_menu(title, width, height, save_key)
        local bound = setmetatable({ facade = self }, Legacy)
        return bound:new(title, width, height, save_key)
    end

    return ui
end

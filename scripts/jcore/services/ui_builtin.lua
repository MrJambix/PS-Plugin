-- JCore / ui_builtin -- the toolkit's own windows and its settings page.
--
-- Depends on: util, log, ui, assets, menu_ns, scheduler, registry, events.
--
-- Three windows ship with the core, all built from the public widget calls
-- so they double as the reference for what the toolkit can do:
--
--   Icon browser   everything the asset catalog knows, searchable, with a
--                  click-to-copy of the reference string a plugin would use
--   Asset inspector  every loaded texture with its state, size and source
--   Widget gallery every widget once, for checking a build in-game
--
-- And a settings page under the JCore sidebar node for the things a user
-- rather than a plugin decides: opacity, scale, window locking, mouse
-- capture, the client folder for addon imports, and the import actions.

return function(rt)
    local util = rt.util
    local ui = rt.ui
    local assets = rt.assets
    local menu_ns = rt.menu_ns
    local scheduler = rt.scheduler
    local log = rt.log.for_tag("JCore/ui")

    local M = {}

    local facade = ui.for_owner("jcore")

    -- --- icon browser -------------------------------------------------------

    local browser = {
        source_index = 1, sources = {}, filtered = {}, filter_key = nil,
        page = 1, per_page = 60, last_catalog_gen = 0, catalog_gen = 0,
    }

    rt.events.on("jcore.assets.scanned", function()
        browser.catalog_gen = browser.catalog_gen + 1
    end, { owner = "jcore.ui" })

    local function browser_refresh(search)
        local sources = assets.sources()
        local names = { "All" }
        for i = 1, #sources do
            names[#names + 1] = sources[i].name .. " (" .. sources[i].count .. ")"
        end
        browser.sources = sources
        browser.source_names = names
        local idx = util.clamp(browser.source_index, 1, #names)
        local source = idx > 1 and sources[idx - 1] and sources[idx - 1].name or nil
        local key = tostring(source) .. "\1" .. tostring(search) .. "\1" .. browser.catalog_gen
        if key ~= browser.filter_key then
            browser.filter_key = key
            browser.filtered = assets.catalog({ source = source, text = search ~= "" and search or nil })
            browser.page = 1
        end
    end

    M.browser = facade:window("icons", {
        title = "Icon browser", w = 520, h = 460, resizable = true, closable = true,
        min_w = 320, min_h = 240, visible = false, anchor = "center",
    }, function(u)
        local search = u:text_input("search", nil, "", { placeholder = "search icons.. (Enter to apply)" })
        browser_refresh(search)
        u:row({ 0, 110, 110 })
        local si = u:dropdown("source", nil, browser.source_names, browser.source_index)
        browser.source_index = si
        if u:button("scan_installed", "Scan addons", { tooltip = "Probe the known addon list and import every texture the installed ones reference" }) then
            ui.toast("Scanning installed addons..", { kind = "info" })
            assets.scan_installed(function(names)
                ui.toast(("Scanned %d addon(s)"):format(#names), { kind = "success" })
            end)
        end
        if u:button("scan_data", "Scan data", { tooltip = "Import every image under scripts_data" }) then
            assets.scan_data("", { force = true }, function(result)
                ui.toast(("Found %d image(s) under scripts_data"):format(#result.entries), { kind = "success" })
            end)
        end
        u:end_row()

        local list = browser.filtered
        local total = #list
        local pages = math.max(1, math.ceil(total / browser.per_page))
        browser.page = util.clamp(browser.page, 1, pages)
        u:row({ 80, 0, 80 })
        if u:button("prev", "<", { disabled = browser.page <= 1 }) then browser.page = browser.page - 1 end
        u:text(("%d icons   page %d / %d"):format(total, browser.page, pages), { align = "center", size = "small", color = "text_dim" })
        if u:button("next", ">", { disabled = browser.page >= pages }) then browser.page = browser.page + 1 end
        u:end_row()

        -- Grid of icon buttons, as many per row as the width allows.
        local cell = 56
        local l = ui._L()
        local per_row = math.max(1, math.floor((l.w - l.indent) / (cell + 6)))
        local first = (browser.page - 1) * browser.per_page + 1
        local last = math.min(total, first + browser.per_page - 1)
        u:scroll("grid", math.max(80, u._grid_h or 240))
        local i = first
        while i <= last do
            u:row(per_row, { gap = 6 })
            for _ = 1, per_row do
                if i <= last then
                    local entry = list[i]
                    if u:icon_button("i" .. i, entry.ref, { size = cell - 16, label = entry.label, tooltip = entry.ref .. "\nfrom " .. tostring(entry.source) }) then
                        if ui.clipboard_set(entry.ref) then
                            ui.toast("Copied " .. entry.ref, { kind = "success", duration = 2 })
                        else
                            ui.toast(entry.ref, { kind = "info", duration = 4, title = "Reference (no clipboard on this build)" })
                        end
                        browser.selected = entry
                    end
                    i = i + 1
                else
                    u:skip()
                end
            end
            u:end_row()
        end
        if total == 0 then
            u:text("Nothing in the catalog yet. Scan addons or scripts_data, or register references from a plugin.",
                { color = "text_dim", size = "small" })
        end
        u:end_scroll()
        -- The grid takes whatever is left of the window body.
        local win = ui._windows[u._prefix .. "icons"]
        if win and win.body then
            local used = (ui._L().y - win.body[2]) - (u._grid_h or 240)
            u._grid_h = math.max(80, win.body[4] - used - ui._T.pad)
        end
        if browser.selected then
            u:separator()
            local e = browser.selected
            local a = assets.get(e.ref)
            u:row({ 48, 0 })
            u:image(e.ref, 40, 40)
            u:key_value(e.label, e.ref)
            u:end_row()
            if a then
                u:text(("%s   %s   %sx%s"):format(a.state, a.kind, tostring(a.w or "?"), tostring(a.h or "?"))
                    .. (a.err and ("   " .. a.err) or ""), { size = "small", color = a.err and "danger" or "text_dim" })
            end
        end
    end)

    -- --- asset inspector ----------------------------------------------------

    M.inspector = facade:window("assets", {
        title = "Asset inspector", w = 560, h = 380, resizable = true, closable = true, visible = false,
        anchor = "center", min_w = 360,
    }, function(u)
        local s = assets.stats()
        u:text(("%d entries, %d ready, %d queued, %d failed   pump %.2fms   client folder %s")
            :format(s.entries, s.ready, s.queued, s.failed, s.pump_ms, s.flavor), { size = "small", color = "text_dim" })
        local rows = {}
        local list = assets.entries()
        for i = 1, #list do
            local e = list[i]
            rows[i] = {
                (e.state == "ready") and { icon = e.key, text = e.key } or e.key,
                e.state, (e.w and e.h) and (e.w .. "x" .. e.h) or "",
                e.err or "",
            }
        end
        local win = ui._windows[u._prefix .. "assets"]
        local h = win and win.body and (win.body[4] - (ui._L().y - win.body[2]) - ui._T.pad) or 260
        local _, clicked = u:table("entries", {
            { label = "reference", w = 0.42 }, { label = "state", w = 70 }, { label = "size", w = 70 }, { label = "error", w = 0 },
        }, rows, { h = math.max(80, h), sort = true })
        if clicked and list[clicked] then
            local e = list[clicked]
            if e.state == "failed" and not e.dead then
                e.next_try = 0
                assets.request(e.key)
                ui.toast("Retrying " .. e.key, { kind = "info", duration = 2 })
            end
        end
    end)

    -- --- widget gallery -----------------------------------------------------

    local gallery_state = { log = {}, counter = 0 }
    local function glog(s)
        local l = gallery_state.log
        table.insert(l, 1, s)
        if #l > 6 then l[#l] = nil end
    end

    M.gallery = facade:window("gallery", {
        title = "Widget gallery", w = 380, resizable = true, h = 520, closable = true, visible = false,
        anchor = "center", min_w = 280, min_h = 200,
    }, function(u)
        local tab = u:tabs("tab", { "Basics", "Inputs", "Data", "Mixed" }, 1)
        if tab == 1 then
            u:heading("Text and buttons")
            u:text("Body text wraps to the window width when it gets long enough to need it, like this sentence.")
            u:text("Dim small text", { size = "small", color = "text_dim" })
            u:key_value("Frame", tostring(ui._F.frame))
            u:row(3)
            if u:button("b1", "Default") then glog("default clicked") end
            if u:button("b2", "Primary", { style = "primary" }) then glog("primary clicked") end
            if u:button("b3", "Danger", { style = "danger" }) then glog("danger clicked") end
            u:end_row()
            u:button("b4", "Ghost, full width, with a tooltip", { style = "ghost", tooltip = "Tooltips follow the cursor" })
            u:separator("Toggles")
            local t1 = u:toggle("t1", "A switch", true)
            u:checkbox("c1", "A checkbox", false)
            u:progress((ui._F.t % 5) / 5, { text = "progress " .. math.floor(((ui._F.t % 5) / 5) * 100) .. "%" })
            u:bar("A labelled bar", 0.66, { color = "success", text = "66%" })
            u:row(4)
            u:badge("info", "info"); u:badge("ok", "success"); u:badge("warn", "warning"); u:badge("bad", "danger")
            u:end_row()
            if not t1 then u:text("Switch is off", { color = "warning" }) end
        elseif tab == 2 then
            u:heading("Inputs")
            local v = u:slider("s1", "Integer slider", 0, 100, 40, { suffix = "%" })
            u:slider("s2", "Float slider", 0, 1, 0.25, { step = 0.05 })
            u:dropdown("d1", "Dropdown", { "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa" }, 2)
            local txt, submitted = u:text_input("in1", "Text input", "", { placeholder = "type and press Enter" })
            if submitted then glog("submitted: " .. txt) end
            u:text_input("in2", nil, "", { placeholder = "numeric only", numeric = true })
            local active = u:keybind("k1", "Hold keybind", 0x54)
            local latched = u:keybind("k2", "Toggle keybind", 0x59, { mode = "toggle" })
            u:key_value("hold / toggle", tostring(active) .. " / " .. tostring(latched))
            u:color("col1", "Colour picker", { 140, 120, 240, 255 })
            u:text(("slider value %d"):format(v), { size = "small", color = "text_dim" })
        elseif tab == 3 then
            u:heading("Data")
            local items = {}
            for i = 1, 25 do items[i] = "Item " .. i end
            local sel, clicked, dbl = u:list("l1", items, { h = 120 })
            if clicked then glog("list click " .. clicked .. (dbl and " (double)" or "")) end
            u:context_menu("cm1", { "Copy", "Rename", "Delete" })
            local rows = {}
            for i = 1, 30 do rows[i] = { "Row " .. i, i * 7 % 13, (i % 3 == 0) and "yes" or "no" } end
            u:table("tb1", { { label = "name", w = 0 }, { label = "value", w = 70, align = "right" }, { label = "flag", w = 60 } }, rows,
                { h = 150, sort = true })
            if u:tree("tr1", "A tree node", true, { badge = "3" }) then
                u:text("child one"); u:text("child two")
                if u:tree("tr2", "nested", false) then u:text("deep"); u:end_tree() end
                u:end_tree()
            end
            u:text("selected " .. tostring(sel), { size = "small", color = "text_dim" })
        else
            u:heading("Mixed")
            u:player_frame({ level = true })
            u:unit_frame(rt.player.target(), { level = true })
            if u:group("g1", "A collapsible group", { default_open = true }) then
                u:text("Inside the group")
                u:row({ 0.5, 0.5 })
                u:image("icon:inv_misc_questionmark", 40, 40, { align = "center" })
                u:spell_icon(2061, 40, { align = "center" })
                u:end_row()
            end
            u:end_group()
            u:spell_row({ 2061, 2050, 585, 139 }, 28, { highlight = 585, cooldowns = { [2050] = (ui._F.t % 8) / 8 } })
            u:custom("cv", 60, function(c)
                c:fill(0, 0, c.w, c.h, { 30, 32, 40, 255 }, 4)
                local mx, my = c:mouse()
                c:text(("canvas %dx%d  mouse %d,%d"):format(c.w, c.h, mx, my), 8, 6, "text_dim", "small")
                c:circle(c.w - 20, c.h / 2, 10, c:hovered() and "accent" or "border")
            end)
            u:raw(30, function(x, y, w, h)
                -- Raw graphics code, exactly as legacy plugins write it.
                core.graphics.rect_2d(ui._vec2(x, y), w, h, ui.theme.warning, 1, 3)
                core.graphics.text_2d("raw core.graphics call", ui._vec2(x + 8, y + 8), 12, ui.theme.text)
            end)
            if u:button("toast", "Toast") then
                gallery_state.counter = gallery_state.counter + 1
                ui.toast("Toast number " .. gallery_state.counter, { kind = ({ "info", "success", "warning", "danger" })[gallery_state.counter % 4 + 1], title = "Hello" })
            end
            if u:button("modal", "Confirm dialog", { style = "danger" }) then
                ui.confirm({
                    title = "Reset everything?", body = "This is a demo. Nothing happens either way.", tone = "danger",
                    confirm_label = "Reset", on_confirm = function() glog("confirmed") end, on_cancel = function() glog("cancelled") end,
                })
            end
        end
        if #gallery_state.log > 0 then
            u:separator("events")
            for i = 1, #gallery_state.log do
                u:text(gallery_state.log[i], { size = "small", color = "text_dim" })
            end
        end
    end)

    -- --- launcher -----------------------------------------------------------
    --
    -- The one window that starts VISIBLE. Everything else the toolkit ships
    -- is opened from here or from the settings page, so a fresh install
    -- shows something on screen and the user learns where the rest lives.
    -- Closing it is remembered; the JCore > UI page reopens it.

    M.launcher = facade:window("launcher", {
        title = "JCore", anchor = "top-right", x = 20, y = 120, w = 190,
        closable = true, collapsible = true, visible = true,
    }, function(u)
        local s = ui.stats()
        local phases = scheduler.phase_stats()
        local render = phases.render and phases.render.avg_ms or 0
        u:key_value("version", rt.VERSION)
        u:key_value("plugins", tostring(rt.registry.count()))
        u:key_value("windows", ("%d live"):format(s.live))
        u:key_value("render", ("%.2f ms"):format(render))
        u:separator()
        if u:button("gallery", "Widget gallery", { icon = nil }) then M.gallery.toggle() end
        if u:button("icons", "Icon browser") then M.browser.toggle() end
        if u:button("assets", "Asset inspector") then M.inspector.toggle() end
        u:text("Settings: menu > JCore > UI", { size = "micro", color = "text_dim", align = "center" })
    end)

    -- A toast a moment after boot: it says where things are, and if it
    -- shows at all, the whole paint path is known to work on this build.
    scheduler.after(2.0, function()
        ui.toast("Overlay ready. Open the launcher window (top right) or menu > JCore > UI.",
            { title = "JCore UI " .. ui.VERSION, kind = "success", duration = 8 })
    end, "jcore.ui")

    -- --- settings page ------------------------------------------------------

    local function build_page()
        local page = menu_ns.for_plugin("jcore", "UI", { icon = "widgets" })
        if not page.available then return page end

        page:title(function()
            local s = ui.stats()
            local a = assets.stats()
            return ("JCore UI   %d window(s), %d live   %d asset(s) ready, %d queued"):format(s.windows, s.live, a.ready, a.queued)
        end, { size = "subtitle", align = "left" })

        local general = page:section("Overlay", "widgets", { column = "left" })
        general:toggle("enabled", "Enable overlay windows", true)
        general:slider("opacity", "Window opacity", 20, 100, 100, "%")
        general:slider("scale", "UI scale", 60, 200, 100, "%")
        general:toggle("lock", "Lock window positions", false)
        general:toggle("capture", "Capture the mouse over windows", true, {
            description = "Off: clicks on a window also reach the game. On: the game ignores them.",
        })
        general:toggle("over_game", "Draw over the game's windows", true, {
            description = "On: JCore windows, panels and tooltips paint over the bags, the map and every other game frame. Off: under them, as before 1.8.1.",
        })
        general:toggle("snap", "Snap to screen edges", true)
        general:toggle("shaders", "Shader drawing", true, {
            description = "Windows: soft shadows, gradients, animated sliders and hover rows. World: smooth filling rings. Drawn with the loader's shader calls; off, the plain shapes from before 1.10.0.",
        })
        general:dropdown("toast_anchor", "Toast corner", { "top-right", "top-left", "bottom-right", "bottom-left", "top-center" }, 1)
        general:button("reset_layout", "Reset window layout", {
            style = "danger",
            on_click = function()
                ui.reset_layout()
                ui.toast("Window layout reset", { kind = "warning" })
            end,
        })

        local windows_section = page:section("Windows", "list", { column = "left" })
        windows_section:keybind("browser_key", "Icon browser", 0, { mode = "toggle", modes = { "toggle", "hold" } })
        windows_section:button("open_browser", "Open icon browser", { on_click = function() M.browser.toggle() end })
        windows_section:button("open_inspector", "Open asset inspector", { on_click = function() M.inspector.toggle() end })
        windows_section:button("open_gallery", "Open widget gallery", { on_click = function() M.gallery.toggle() end })
        windows_section:button("open_launcher", "Show the launcher window", { on_click = function() M.launcher.show() end })

        local import = page:section("Icon import", "globe", { column = "right" })
        import:label("Textures inside installed addons are read from the game folder.")
        import:text_input("flavor", "Client folder", "", {
            placeholder = "auto (e.g. _classic_era_)",
            description = "Folder under the WoW install that holds Interface/AddOns. Leave empty to detect.",
        })
        import:slider("max_dim", "Max texture size", 64, 2048, 512, "px", {
            description = "Larger BLPs are read at the mip level that fits. Lower is cheaper.",
        })
        import:text_input("addon", "Addon folder name", "", { placeholder = "Questie" })
        import:button("scan_addon", "Import this addon's icons", {
            on_click = function()
                local name = page:get("addon")
                if type(name) ~= "string" or name == "" then
                    ui.toast("Type an addon folder name first", { kind = "warning" })
                    return
                end
                local ok = assets.scan_addon(name, { force = true }, function(result, err)
                    if result then
                        ui.toast(("%s: %d addon textures, %d game icons"):format(name, result.addon_textures, result.game_icons), { kind = "success" })
                        M.browser.show()
                    else
                        ui.toast(tostring(err), { kind = "danger" })
                    end
                end)
                if ok then ui.toast("Scanning " .. name .. "..", { kind = "info" }) end
            end,
        })
        import:button("scan_all", "Import from every installed addon", {
            on_click = function()
                ui.toast("Probing for installed addons..", { kind = "info" })
                assets.scan_installed(function(names)
                    ui.toast(("Found %d installed addon(s); importing"):format(#names), { kind = "success" })
                    M.browser.show()
                end)
            end,
        })
        import:button("scan_data_btn", "Import images under scripts_data", {
            on_click = function()
                assets.scan_data("", { force = true }, function(result)
                    ui.toast(("%d image(s) under scripts_data"):format(#result.entries), { kind = "success" })
                    M.browser.show()
                end)
            end,
        })
        import:button("clear_catalog", "Clear the catalog", {
            style = "danger",
            on_click = function()
                assets.clear_catalog()
                browser.catalog_gen = browser.catalog_gen + 1
                ui.toast("Catalog cleared", { kind = "warning" })
            end,
        })

        page:live_lines(4, function()
            local a = assets.stats()
            return {
                ("assets: %d entries, %d ready, %d failed, %d converted from BLP, %d downloaded (%d from cache)")
                    :format(a.entries, a.ready, a.failed, a.converted, a.downloads, a.cache_hits),
                ("catalog: %d source(s), %d scan(s) this session, client folder %s"):format(a.catalogs, a.scans, a.flavor),
                a.active and ("loading: " .. a.active) or "",
                "",
            }
        end)

        -- Settings take effect immediately.
        page:on_change("enabled", function(v) ui.settings.enabled = v and true or false end)
        page:on_change("opacity", function(v) ui.set_opacity((tonumber(v) or 100) / 100) end)
        page:on_change("scale", function(v) ui.set_scale((tonumber(v) or 100) / 100) end)
        page:on_change("lock", function(v) ui.settings.lock_windows = v and true or false end)
        page:on_change("capture", function(v) ui.settings.capture_mouse = v and true or false end)
        page:on_change("over_game", function(v) rt.draw.over_game = v and true or false end)
        page:on_change("snap", function(v) ui.settings.snap = v and 10 or 0 end)
        page:on_change("shaders", function(v)
            ui.settings.shaders = v and true or false
            rt.draw.shaders = ui.settings.shaders
        end)
        page:on_change("toast_anchor", function(i)
            ui.settings.toast_anchor = ({ "top-right", "top-left", "bottom-right", "bottom-left", "top-center" })[i] or "top-right"
        end)
        page:on_change("flavor", function(v) assets.set_flavor(v) end)
        page:on_change("max_dim", function(v) assets.set_max_dim(v) end)

        -- Apply persisted values once the host has restored them.
        scheduler.after(0.5, function()
            ui.settings.enabled = page:get_or("enabled", true)
            ui.set_opacity(page:get_or("opacity", 100) / 100)
            ui.set_scale(page:get_or("scale", 100) / 100)
            ui.settings.lock_windows = page:get_or("lock", false)
            ui.settings.capture_mouse = page:get_or("capture", true)
            rt.draw.over_game = page:get_or("over_game", true) and true or false
            ui.settings.snap = page:get_or("snap", true) and 10 or 0
            ui.settings.shaders = page:get_or("shaders", true) and true or false
            rt.draw.shaders = ui.settings.shaders
            local flavor = page:get("flavor")
            if type(flavor) == "string" and flavor ~= "" then assets.set_flavor(flavor) end
        end, "jcore.ui")

        -- The browser keybind, polled from the page.
        local was_active = false
        scheduler.add("update", function()
            local active = page:is_keybind_active("browser_key")
            if active and not was_active then M.browser.toggle() end
            was_active = active
        end, { owner = "jcore.ui", priority = 50, interval = 0.05 })

        return page
    end

    local page = build_page()
    if not page.available then
        scheduler.after(2.5, function() build_page() end, "jcore.ui")
    end

    return M
end

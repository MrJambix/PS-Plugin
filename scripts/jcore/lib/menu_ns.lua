-- JCore / menu_ns -- a per-plugin slice of the declarative menu.
--
-- Depends on: util, log.
--
-- The shipped `_G.menu` already salts widget persistence with the page path,
-- so ids only collide when two plugins declare the same path. What this adds
-- is a nesting convention, a reader bound to the plugin's own page so nothing
-- has to repeat its path string, and a guard for the case that actually bites:
-- the menu host not being installed yet when a plugin registers.
--
-- That last one is worth spelling out. `_G.menu` is installed by core_lua's
-- menu host at boot. A plugin that resolves it at module scope and caches it
-- can end up holding nil for the whole session. So it is resolved lazily, on
-- every call, and a plugin that declares widgets before the host exists gets a
-- no-op stub with a clear warning rather than an error inside its on_load.

return function(rt)
    local util = rt.util
    local log = rt.log.for_tag("JCore/menu")

    local M = {}

    -- Root sidebar category everything registered through the core nests under.
    local ROOT = "JCore"
    local root_declared = false

    local function host()
        return _G.menu
    end

    --- Stand-in returned when the menu host is unavailable. Every method is
    --- chainable and does nothing, so a plugin's declaration block runs to
    --- completion instead of blowing up on the first call.
    local function stub(name)
        local s = {}
        local mt = {
            __index = function()
                return function(...)
                    local first = select(1, ...)
                    -- Chainable builders return self; readers return nil.
                    return first == s and s or nil
                end
            end,
        }
        log.once("warn", "no_host_" .. name,
            "menu host not installed; menu declarations from '" .. name .. "' are inert this session")
        return setmetatable(s, mt)
    end

    ---@class jcore_menu_ns
    ---@field page_path string
    ---@field page table

    --- Creates (or fetches) the page for a plugin and returns a namespace
    --- bound to it.
    ---
    ---@param owner string        Plugin id, used for logging.
    ---@param display_name string Sidebar label.
    ---@param opts? { icon?: string, path?: string[], root?: boolean, sub?: string }
    ---@return jcore_menu_ns
    function M.for_plugin(owner, display_name, opts)
        opts = opts or {}
        local m = host()

        -- `root = true` puts the page at the sidebar top level instead of
        -- under the JCore node. A rotation usually wants that; a core-adjacent
        -- utility usually does not.
        --
        -- `sub` nests a further page beneath the plugin's own node, which is
        -- how a plugin with more settings than one page can hold splits them
        -- without spilling into the top-level sidebar.
        local path = opts.path
        if not path then
            path = opts.root and { display_name } or { ROOT, display_name }
            if opts.sub then path[#path + 1] = opts.sub end
        end

        local ns = {
            owner     = owner,
            path      = path,
            page_path = table.concat(path, "/"),
        }

        if not m then
            ns.page = stub(owner)
            ns.available = false
        else
            if not opts.root and not root_declared then
                pcall(function()
                    m:category({ ROOT }, { icon = "widgets", expanded = true })
                end)
                root_declared = true
            end

            local ok, page = pcall(function()
                return m:page(path, { icon = opts.icon })
            end)

            if ok and page then
                ns.page = page
                ns.available = true
            else
                log.fmt("error", "could not create menu page for %s: %s", owner, tostring(page))
                ns.page = stub(owner)
                ns.available = false
            end
        end

        --- Section card on this plugin's page.
        ---@param title string
        ---@param icon? string
        ---@param section_opts? table
        function ns:section(title, icon, section_opts)
            return self.page:section(title, icon, section_opts)
        end

        --- Text band in the page flow, outside any card.
        ---
        --- This is the ONLY menu element that accepts a live provider:
        --- Section:label takes a plain string and is fixed at declaration
        --- time, so anything that has to update every frame -- a stat readout,
        --- a status line -- belongs here rather than in a label.
        ---@param text string|fun(): string
        ---@param title_opts? table
        function ns:title(text, title_opts)
            return self.page:title(text, title_opts)
        end

        --- Declares `count` consecutive live text rows fed by one provider.
        ---
        --- Menu content is retained mode: the row COUNT is fixed at
        --- declaration and only the text can change per frame. So a
        --- variable-length readout is declared at its maximum length and short
        --- frames return empty strings for the unused rows.
        ---
        --- `provider` is called at most once per frame however many rows read
        --- from it, which matters because these providers tend to walk every
        --- registered plugin.
        ---@param count integer Maximum rows.
        ---@param provider fun(): string[]
        ---@param title_opts? table
        function ns:live_lines(count, provider, title_opts)
            local opts = title_opts or { size = "small", align = "left", pad_y = 0 }
            local cached, cached_frame = {}, -1

            local function lines()
                -- core.time() advances per frame, so it doubles as a frame key.
                local now = core.time()
                if now ~= cached_frame then
                    local ok, result = pcall(provider)
                    cached = (ok and type(result) == "table") and result or {}
                    cached_frame = now
                end
                return cached
            end

            for i = 1, count do
                self.page:title(function()
                    return lines()[i] or ""
                end, opts)
            end
            return self
        end

        --- Reads one of this plugin's widgets. No page path needed.
        ---@param id string
        ---@return any
        function ns:get(id)
            local menu_host = host()
            if not menu_host then return nil end
            local ok, value = pcall(menu_host.get, menu_host, self.page_path, id)
            -- NOT `return ok and value or nil`. A toggle that the user has
            -- switched OFF holds the boolean false, and that idiom collapses
            -- false to nil, so get_or then hands back the default -- every
            -- checkbox in every plugin silently refuses to stay off.
            if not ok then return nil end
            return value
        end

        --- Reads a widget, substituting `fallback` when the menu is absent or
        --- the widget has not been declared. Use this for anything the plugin
        --- must keep working without -- a nil comparison in a hot path is a
        --- silent behaviour change, not an obvious failure.
        ---@param id string
        ---@param fallback any
        ---@return any
        function ns:get_or(id, fallback)
            local value = self:get(id)
            if value == nil then return fallback end
            return value
        end

        ---@param id string
        ---@param value any
        function ns:set(id, value)
            local menu_host = host()
            if not menu_host then return false end
            return pcall(menu_host.set, menu_host, self.page_path, id, value)
        end

        --- Observes a widget. `fn(new_value, old_value)` fires on real changes
        --- only. Register at load, never per frame.
        ---@param id string
        ---@param fn fun(new_value: any, old_value: any)
        function ns:on_change(id, fn)
            local menu_host = host()
            if not menu_host then return false end
            return pcall(menu_host.on_change, menu_host, self.page_path, id, fn)
        end

        --- True when a keybind widget is currently active, whatever its mode.
        --- A keybind value is a table, so a plain truthiness test on it is
        --- always true and is the usual mistake here.
        ---@param id string
        ---@return boolean
        function ns:is_keybind_active(id)
            local value = self:get(id)
            if type(value) ~= "table" then return false end
            if value.active ~= nil then return value.active and true or false end
            if value.toggled ~= nil then return value.toggled and true or false end
            return false
        end

        return ns
    end

    --- The core's own diagnostics page, created once.
    function M.core_page(icon)
        return M.for_plugin("jcore", "Core", { icon = icon or "settings" })
    end

    return M
end

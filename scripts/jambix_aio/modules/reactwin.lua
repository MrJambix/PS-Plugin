-- Jambix AIO / reactwin -- the Reactions window (1.76.0; laid out anew in 1.77.0).
--
-- Opened from the Reactions page ("Open Reactions UI"). A window you move by
-- its title bar and size by its corner; it remembers both. On the left a
-- sidebar that stays put: the master switch, where you are, and the five
-- views. On the right the view: its title bar and tools stay put, the rest
-- scrolls (the wheel, or drag the bar).
--
--   Built-in       the plugin's own, by category (each folds away): a switch
--                  each for the open world and for dungeons (1.78.0), where
--                  else it may act, what it does, how often it went out
--   My reactions   your class's own as cards, from a template or blank; above
--                  them the Dungeon and Open world starter packs (1.78.0).
--                  Each card says why it waits (1.79.0); a search, a filter,
--                  all on/off, Share to the clipboard and Paste
--   Editor         one reaction in six steps -- Basics (with Right now and its
--                  latest fires), When (conditions, each can Hold for a
--                  while), Do this (actions: the first that can go, alerts and
--                  target switches at once), Where, the whole reaction as Lua,
--                  and Try it (a test bench, 1.79.0) -- with Save and Close
--                  always in view. Every row is GUI or Lua; a GUI row shows its
--                  Lua and turns into it with one click; each condition has a
--                  live light
--   Library        the class's shared code: its functions are callable from
--                  every reaction's code and pickable in the GUI
--   Live           where you are, the fight's mode, what each of your
--                  reactions says right now, what went out last
--   Import         someone's reactions from a GitHub link with a folder called
--                  Reaction, picked from a preview; and yours out to files
--                  (1.77.2; react/share.lua does the work)
--
-- The reactions themselves are react/custom.lua's; this only draws them and
-- edits a working copy (the draft) until Save.

local WINDOW_ID = "reactions"
local NAV_W = 190
local DEFAULT_W, DEFAULT_H = 980, 700
local MIN_W, MIN_H = 720, 460
local TOP_H, FOOT_H = 46, 26

local VIEW_TITLE = { "Built-in reactions", "My reactions", "Editor", "Library (Lua)", "Live", "Import and share" }
local VIEW_SUB = {
    "Worked out from the fight. Each has a switch for the open world and for dungeons, for your class.",
    nil,
    nil,
    "Lua shared by every reaction of your class: callable from any Lua row, and pickable in the GUI.",
    "What the engine sees right now, and what went out last.",
    "Someone's reactions from a GitHub repository with a folder called Reaction, and yours out to files.",
}
-- Import is view 6 (1.77.2); the sidebar lists it under My reactions.
local VIEWS = #VIEW_TITLE
local STEP_HINT = {
    "What it is called, how it ranks against everything else happening, and what it is doing right now.",
    "Conditions: GUI rows, or Lua that returns true. The light is what each says right now. \"Hold for\" makes one wait.",
    "Actions in order: the first spell, item or pet order that can go is sent. Alerts, target switches and Stop my cast go at once.",
    "Where this reaction may act.",
    "The whole reaction in Lua: what the rows in the other steps mean.",
    "Try it: set a situation, and see what it would do. Nothing is cast; spells and items are your real ones.",
}
local STEPS = #STEP_HINT

-- How a "why" or a test reads (react/custom.lua's tones), as a colour.
local TONE = { ok = "success", wait = "warning", off = { 150, 154, 168, 255 }, err = "danger",
    idle = { 198, 201, 214, 255 } }

-- What My reactions can show (1.79.0).
local FILTERS = { "All", "Switched on", "Switched off", "Acting here", "From the packs", "Imported", "Written in Lua" }

local CAT_ORDER = { "survival", "bailout", "interrupt", "escape", "cc", "defensive", "resource", "pet",
    "threat", "utility", "buff", "low" }
local CAT_LABEL = { survival = "Survival", bailout = "Hardcore", interrupt = "Interrupts", escape = "Escapes",
    cc = "Crowd control", defensive = "Defensives", resource = "Mana and resources", pet = "Pet",
    threat = "Threat", utility = "Utility", buff = "Buffs", low = "When the rotation is idle" }
local KIND_WORD = { dungeon = "dungeon", raid = "raid", bg = "battleground", arena = "arena" }
local CLASS_COLOR = {
    WARRIOR = { 199, 156, 110 }, PALADIN = { 245, 140, 186 }, HUNTER = { 171, 212, 115 },
    ROGUE = { 255, 245, 105 }, PRIEST = { 240, 240, 240 }, SHAMAN = { 0, 112, 222 },
    MAGE = { 105, 204, 240 }, WARLOCK = { 148, 130, 201 }, DRUID = { 255, 125, 10 },
}
local API_COLOR = { 90, 160, 235 }
local PACK_COLOR = { dungeon = { 235, 150, 80 }, world = { 110, 190, 120 } }

-- Readable on a 1440p screen (1.78.1). The theme's text_dim and
-- text_disabled are too faint for whole sentences on this dark a window,
-- so secondary text is one step brighter, and nothing here is micro-sized.
local DIM = { 198, 201, 214, 255 }      -- secondary text: descriptions, sub-lines
local FAINT = { 150, 154, 168, 255 }    -- what is switched off, file paths, hints
local BG = { 16, 17, 22, 255 }          -- solid, so the game behind does not show through

-- Text size: the window's own scale over JCore's UI scale (JCore 1.8.10).
local ZOOMS = { 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8, 2.0 }
local DEFAULT_ZOOM = 1.25

return function(P)
    local ctx, log = P.ctx, P.log
    local book = P.spellbook

    local M = {}

    local state = {
        tab = 1, section = 1, draft = nil, serial = 0, dirty = false, draft_class = nil,
        expanded = nil, search = "", template = 1, spell_q = {}, cat_closed = {}, api_open = false,
        lib_text = nil, lib_dirty = false, shown = false, err = nil,
        import_url = "", imp_on = false, imp_lib = true, export_result = nil, fmt_open = false,
        packs_open = nil,
        -- 1.79.0
        mine_q = "", mine_filter = 1, timer_open = {}, item_q = {},
        bench = nil, bench_preset = 1, bench_open = { you = true, mobs = true, target = true },
    }
    M.state = state

    local function C() return P.react and P.react.custom or nil end

    local function clock() return core.time() end

    local function ago(t)
        if not t then return "never" end
        local s = clock() - t
        if s < 1 then return "just now" end
        if s < 90 then return string.format("%ds ago", math.floor(s)) end
        if s < 5400 then return string.format("%dm ago", math.floor(s / 60)) end
        return string.format("%dh ago", math.floor(s / 3600))
    end

    local function slug(s) return (tostring(s):gsub("[^%w]", "_")) end

    local function cat_color(cat, alpha)
        local c = (C() and C().D.COLORS[cat]) or { 160, 163, 176 }
        return { c[1], c[2], c[3], alpha or 255 }
    end

    local function class_label(cls)
        if not cls then return "?" end
        return cls:sub(1, 1) .. cls:sub(2):lower()
    end

    --- "Dungeon pack", for a pack reaction's source.
    local function pack_label(c, key)
        return (c.packs and c.packs.label_of(key)) or tostring(key)
    end

    local function toast(text, kind)
        local ui = ctx.ui
        if ui and ui.toast then pcall(ui.toast, ui, text, { kind = kind or "info", title = "Reactions", duration = 3 }) end
    end

    -- The clipboard is JCore's UI service's (public as JCore.ui), not the
    -- per-plugin facade's.
    local function ui_service()
        local J = rawget(_G, "JCore")
        return type(J) == "table" and J.ui or nil
    end
    local function clip_set(s)
        local u = ui_service()
        return u and u.clipboard_set and u.clipboard_set(s) == true or false
    end
    local function clip_get()
        local u = ui_service()
        return u and u.clipboard_get and u.clipboard_get() or nil
    end
    M._clip = { set = clip_set, get = clip_get }

    -- --- scale (1.78.1) ---------------------------------------------------------------
    --
    -- Everything below is laid out in units: pixels at a scale of 1. The window
    -- is drawn at JCore's UI scale times its own text size, so its text is that
    -- much bigger; `units(ui, Z)` hands the code a ui whose custom painters,
    -- row widths, spacers, indents and button and box sizes are multiplied by Z
    -- on the way through. Boxes grow with the text in them, at any size.

    local Z = 1

    local ZC = {}
    ZC.__index = ZC
    function ZC:fill(x, y, w, h, col, r) self.cv:fill(x * Z, y * Z, w * Z, h * Z, col, r and r * Z) end
    function ZC:rect(x, y, w, h, col, t, r) self.cv:rect(x * Z, y * Z, w * Z, h * Z, col, t and t * Z, r and r * Z) end
    function ZC:line(x1, y1, x2, y2, col, t) self.cv:line(x1 * Z, y1 * Z, x2 * Z, y2 * Z, col, (t or 1) * Z) end
    function ZC:text(s, x, y, col, size, centered) self.cv:text(s, x * Z, y * Z, col, size, centered) end
    function ZC:circle(x, y, r, col, filled, t) self.cv:circle(x * Z, y * Z, r * Z, col, filled, t and t * Z) end
    function ZC:image(ref, x, y, w, h, tint) self.cv:image(ref, x * Z, y * Z, w * Z, h * Z, tint) end
    function ZC:text_width(s, size) return self.cv:text_width(s, size) / Z end
    function ZC:hovered() return self.cv:hovered() end
    function ZC:mouse()
        local mx, my = self.cv:mouse()
        return mx / Z, my / Z
    end

    local function z(n) return n and math.floor(n * Z + 0.5) or n end

    local function z_opts(opts, keys)
        if not opts or Z == 1 then return opts end
        local out = {}
        for k, v in pairs(opts) do out[k] = v end
        for _, k in ipairs(keys) do if type(out[k]) == "number" then out[k] = z(out[k]) end end
        return out
    end

    --- ui, in units. Calls not listed go straight through.
    local function units(ui)
        local U = setmetatable({}, { __index = function(t, k)
            local v = ui[k]
            if type(v) ~= "function" then return v end
            local f = function(_, ...) return v(ui, ...) end
            rawset(t, k, f)
            return f
        end })
        function U:custom(id, h, painter)
            return ui:custom(id, z(h), function(cv)
                return painter(setmetatable({ cv = cv, w = cv.w / Z, h = cv.h / Z }, ZC))
            end)
        end
        function U:row(widths, opts)
            if type(widths) == "table" then
                local out = {}
                for i, v in ipairs(widths) do out[i] = v > 1 and z(v) or v end
                widths = out
            end
            return ui:row(widths, z_opts(opts, { "gap" }))
        end
        function U:spacer(h) return ui:spacer(z(h or 4)) end
        function U:indent(px) return ui:indent(z(px or 16)) end
        function U:unindent(px) return ui:unindent(z(px or 16)) end
        function U:scroll(id, h) return ui:scroll(id, z(h)) end
        function U:button(id, label, opts) return ui:button(id, label, z_opts(opts, { "w", "h" })) end
        function U:code(id, text, opts) return ui:code(id, text, z_opts(opts, { "h" })) end
        function U:spell_icon(sid, size, opts) return ui:spell_icon(sid, z(size or 32), opts) end
        function U:avail()
            local x, y, w, h = ui:avail()
            return x, y, w / Z, h / Z
        end
        function U:metrics()
            local m = ui:metrics()
            return { pad = m.pad / Z, gap = m.gap / Z, row = m.row / Z, title_h = m.title_h / Z,
                scrollbar = m.scrollbar / Z, font_small = m.font_small, font_body = m.font_body, scale = m.scale }
        end
        return U
    end

    -- The text size, kept for the next session.
    local zstore = ctx and ctx.store and ctx.store("reactions_window") or nil
    local zdata = zstore and zstore.data or {}
    local function zoom()
        local v = tonumber(zdata.zoom) or DEFAULT_ZOOM
        return math.max(ZOOMS[1], math.min(ZOOMS[#ZOOMS], v))
    end
    local function set_zoom(v)
        zdata.zoom = v
        if zstore and zstore.touch then pcall(zstore.touch, zstore) end
    end
    local function zoom_step(dir)
        local cur = zoom()
        local at = 1
        for i, v in ipairs(ZOOMS) do if math.abs(v - cur) < 0.01 then at = i end end
        local i = math.max(1, math.min(#ZOOMS, at + dir))
        set_zoom(ZOOMS[i])
    end
    M.zoom, M.set_zoom = zoom, set_zoom

    --- Fits text into w pixels on a canvas, with a cache (the cards repaint
    --- the same lines every frame).
    local fit_cache, fit_n = {}, 0
    local function fit(cv, s, w, size)
        local key = s .. "\1" .. math.floor(w) .. "\1" .. tostring(size) .. "\1" .. Z
        local hit = fit_cache[key]
        if hit then return hit end
        local out = s
        if cv:text_width(s, size) > w then
            local lo, hi = 0, #s
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if cv:text_width(s:sub(1, mid) .. "..", size) <= w then lo = mid else hi = mid - 1 end
            end
            out = s:sub(1, lo) .. ".."
        end
        fit_n = fit_n + 1
        if fit_n > 400 then fit_cache, fit_n = {}, 0 end
        fit_cache[key] = out
        return out
    end

    -- --- panes ---------------------------------------------------------------------
    --
    -- The sidebar, the view and the view's scrolling body are JCore scroll
    -- regions, and a widget inside one is stored under the region's path
    -- ("main/v1/def_search"). Every widget here is set from the model before
    -- it is drawn, so `put` adds the path of the region being described.

    local scope = ""

    local function put(ui, id, v) ui:set(WINDOW_ID, scope .. id, v) end

    local function region(ui, id, h, fn)
        local outer = scope
        ui:scroll(id, h)
        scope = outer .. id .. "/"
        local ok, err = pcall(fn)
        ui:end_scroll()
        scope = outer
        if not ok then error(err, 0) end
    end

    -- --- small pieces ------------------------------------------------------------

    --- A status light: "ok" green, "no" dim red, "err" red, nil grey.
    local function light(ui, id, status, tip)
        ui:custom(id, 22, function(cv)
            local col = status == "ok" and "success" or status == "err" and "danger"
                or status == "no" and { 235, 87, 87, 120 } or FAINT
            cv:circle(8, cv.h / 2, 5, col, true)
            if status == "ok" then cv:circle(8, cv.h / 2, 8, { 100, 200, 140, 80 }, false, 2) end
        end)
        if tip and ui:hovered() then ui:tooltip(tip) end
    end

    local function status_of(slot)
        if not slot then return nil end
        if slot.err then return "err" end
        return slot.ok and "ok" or "no"
    end

    --- A coloured strip that folds what is under it away. Returns true on
    --- the frame it was clicked (only when it can fold).
    local function fold_header(ui, id, label, right, col, open, foldable)
        local _, clicked = ui:custom(id, 24, function(cv)
            local over = foldable and cv:hovered()
            local solid = { col[1], col[2], col[3], 255 }
            cv:fill(0, 0, cv.w, cv.h, { col[1], col[2], col[3], over and 70 or 40 }, 4)
            cv:fill(0, 0, 4, cv.h, solid, 2)
            local tx = 12
            if foldable then
                local cx, cy = 17, cv.h / 2
                if open then
                    cv:line(cx - 4, cy - 2, cx, cy + 2, solid, 2)
                    cv:line(cx, cy + 2, cx + 4, cy - 2, solid, 2)
                else
                    cv:line(cx - 2, cy - 4, cx + 2, cy, solid, 2)
                    cv:line(cx + 2, cy, cx - 2, cy + 4, solid, 2)
                end
                tx = 30
            end
            cv:text(label, tx, 5, solid, "small")
            if right then cv:text(right, cv.w - cv:text_width(right, "small") - 8, 6, DIM, "small") end
        end)
        return foldable and clicked or false
    end

    --- A row of labelled numbers, side by side.
    local function tiles(ui, id, list)
        ui:custom(id, 50, function(cv)
            local n, gap = #list, 8
            local tw = (cv.w - gap * (n - 1)) / n
            for i, t in ipairs(list) do
                local x = (i - 1) * (tw + gap)
                cv:fill(x, 0, tw, cv.h, "bg_elevated", 6)
                cv:text(fit(cv, t[1], tw - 18, "small"), x + 10, 8, DIM, "small")
                cv:text(fit(cv, t[2], tw - 18, "body"), x + 10, 25, t[3] or "text", "body")
            end
        end)
    end

    local function master_toggle()
        local page = P.pages and P.pages.reactions
        local c = C()
        if page and page.set and c then
            pcall(page.set, page, "react_active", not c.master_on())
            if P.opt_invalidate then P.opt_invalidate() end
        end
    end

    -- --- where (shared by the built-in reactions and the editor) ---------------------

    local function draw_env(ui, c, prefix, env)
        local D = c.D
        local changed = false
        for i = 1, #D.ENV, 2 do
            ui:row({ 0, 0 })
            for j = i, math.min(i + 1, #D.ENV) do
                local e = D.ENV[j]
                local id = prefix .. e.key
                put(ui, id, env[e.key] ~= false)
                local v, ch = ui:toggle(id, e.label, env[e.key] ~= false)
                if ch then env[e.key] = v and true or false; changed = true end
            end
            ui:end_row()
        end
        for _, kind in ipairs({ "dungeon", "raid", "bg", "arena" }) do
            local places = c.places(kind)
            if env[kind] ~= false and #places > 1 then
                local pk = c.PICK_OF[kind]
                local labels, index = {}, 1
                for i, n in ipairs(places) do
                    local info = c.place_info(kind, n)
                    if i == 1 then
                        labels[i] = "Any " .. KIND_WORD[kind]
                    else
                        labels[i] = n .. (info and info.level and (" (" .. info.level .. ")") or "")
                            .. (info and info.note and (" - " .. info.note) or "")
                    end
                    if n == env[pk] then index = i end
                end
                local id = prefix .. pk
                put(ui, id, index)
                local v, ch = ui:dropdown(id, "Which " .. KIND_WORD[kind], labels, index,
                    { no_wheel = true, max_visible = 12 })
                if ch and places[v] then env[pk] = places[v]; changed = true end
            end
        end
        ui:row(4)
        local quick = {
            { "q_all", "Everywhere", { world = true, world_pvp = true, bg = true, arena = true, dungeon = true, raid = true } },
            { "q_world", "Open world", { world = true, world_pvp = true } },
            { "q_inst", "Dungeons + raids", { dungeon = true, raid = true } },
            { "q_pvp", "PvP only", { world_pvp = true, bg = true, arena = true } },
        }
        for _, q in ipairs(quick) do
            if ui:button(prefix .. q[1], q[2], { style = "ghost" }) then
                for _, e in ipairs(D.ENV) do env[e.key] = q[3][e.key] == true end
                for _, pk in pairs(c.PICK_OF) do env[pk] = "Any" end
                changed = true
            end
        end
        ui:end_row()
        local here = c.env_ok(env)
        ui:text(string.format("You are in: %s -- %s", c.where_text(), here and "it may act here" or "it stays off here"),
            { size = "small", color = here and "success" or "warning" })
        return changed
    end

    -- --- drafts ------------------------------------------------------------------------

    local function open_draft(r, section)
        local c = C()
        state.draft = c.copy(r)
        state.serial = state.serial + 1
        state.dirty = r.id == nil
        state.draft_class = c.class()
        state.section = section or 1
        state.tab = 3
    end

    local function try_open(r, section)
        if state.draft and state.dirty and state.draft.id ~= r.id and ctx.ui and ctx.ui.confirm then
            pcall(ctx.ui.confirm, ctx.ui, {
                title = "Unsaved changes", tone = "warning", confirm_label = "Discard them",
                body = "The reaction in the editor (" .. tostring(state.draft.name) .. ") has changes that are not saved.",
                on_confirm = function() open_draft(r, section) end,
            })
            return
        end
        open_draft(r, section)
    end

    local function did(id) return "d" .. state.serial .. "_" .. id end
    local function dirty() state.dirty = true end

    local function first_spell(r)
        for _, a in ipairs(r.actions or {}) do
            if a.mode ~= "lua" and (a.kind == "spell" or a.kind == nil) and (a.spell or "") ~= "" then return a.spell end
        end
        return nil
    end

    local function summary(c, r)
        local parts = {}
        for i, cond in ipairs(r.conds or {}) do
            if i > 2 then parts[#parts + 1] = string.format("+%d more", #r.conds - 2) break end
            parts[#parts + 1] = cond.mode == "lua" and "(Lua)" or c.cond_code(cond)
        end
        local when = #parts > 0 and table.concat(parts, r.match == "any" and " or " or " and ") or "always"
        local a = (r.actions or {})[1]
        local what = "nothing"
        if a then
            if a.mode == "lua" then what = "Lua action"
            elseif a.kind == "spell" then what = (a.spell ~= "" and a.spell or "?") .. (a.target and a.target ~= "target" and (" on " .. a.target) or "")
            elseif a.kind == "item" then what = "use " .. tostring(a.item)
            elseif a.kind == "pet_spell" then what = "pet: " .. tostring(a.spell)
            elseif a.kind == "pet_attack" then what = "send the pet"
            elseif a.kind == "lua_fn" then what = tostring(a.fn) .. "()"
            elseif a.kind == "hold" then what = "hold the rotation"
            elseif a.kind == "alert" then what = "alert \"" .. tostring(a.text or "") .. "\""
            elseif a.kind == "target" then what = "target the " .. tostring(a.who or "attacker"):gsub("_", " ")
            elseif a.kind == "stop_cast" then what = "stop casting"
            elseif a.kind == "named_item" then what = "use " .. tostring(a.name or "?") end
            if #r.actions > 1 then what = what .. string.format(" (+%d)", #r.actions - 1) end
        end
        return "When " .. when .. "  ->  " .. what
    end

    -- --- the sidebar ------------------------------------------------------------------

    local function nav_status(ui, c)
        local master = c.master_on()
        local cls = c.class()
        local live = c.latest_W() ~= nil
        local over_pill = false
        local _, clicked = ui:custom("status", 100, function(cv)
            cv:fill(6, 0, cv.w - 12, cv.h, "bg_elevated", 6)
            local cc = CLASS_COLOR[cls or ""] or { 235, 235, 240 }
            local label = class_label(cls)
            cv:fill(14, 9, cv:text_width(label, "small") + 16, 18, { cc[1], cc[2], cc[3], 50 }, 9)
            cv:text(label, 22, 11, { cc[1], cc[2], cc[3], 255 }, "small")
            local px, py, pw, ph = 14, 35, cv.w - 28, 26
            local mx, my = cv:mouse()
            over_pill = cv:hovered() and mx >= px and mx <= px + pw and my >= py and my <= py + ph
            cv:fill(px, py, pw, ph, master and { 100, 200, 140, over_pill and 110 or 60 }
                or { 235, 87, 87, over_pill and 110 or 60 }, 13)
            cv:circle(px + 14, py + ph / 2, 4, master and "success" or "danger", true)
            cv:text(master and "ON in the rotation" or "OFF", px + 26, py + 7, "text", "small")
            cv:text(fit(cv, "Where: " .. c.where_text(), cv.w - 28, "small"), 14, 67, DIM, "small")
            local note = live and "fight picture live" or "lights wait for the rotation"
            cv:text(fit(cv, note, cv.w - 28, "small"), 14, 83, live and "success" or FAINT, "small")
        end)
        if ui:hovered() and over_pill then ui:tooltip("Click to switch every reaction on or off (the Reactions page's switch)") end
        if clicked and over_pill then master_toggle() end
    end

    local function nav_item(ui, i, label, sub, sub_col, dot)
        local sel = state.tab == i
        local _, clicked = ui:custom("nav" .. i, 40, function(cv)
            if sel then
                cv:fill(6, 0, cv.w - 12, cv.h, { 140, 120, 240, 55 }, 6)
                cv:fill(6, 8, 3, cv.h - 16, "accent", 2)
            elseif cv:hovered() then
                cv:fill(6, 0, cv.w - 12, cv.h, "bg_hover", 6)
            end
            cv:text(label, 18, 5, sel and "text" or { 215, 216, 224, 255 }, "body")
            cv:text(fit(cv, sub, cv.w - (dot and 44 or 30), "small"), 18, 22, sub_col or FAINT, "small")
            if dot then cv:circle(cv.w - 20, cv.h / 2, 4, dot, true) end
        end)
        if clicked then state.tab = i end
    end

    local function draw_nav(ui, c, f, h)
        local _, _, w = ui:avail()
        ui:custom("panel", 0, function(cv) cv:fill(0, 0, cv.w, math.max(h, 1200), { 25, 26, 34, 255 }, 6) end)
        ui:spacer(2)
        nav_status(ui, c)
        ui:spacer(6)
        local on = 0
        for _, d in ipairs(f.defaults) do if d.here then on = on + 1 end end
        nav_item(ui, 1, "Built-in", string.format("%d of %d act here", on, #f.defaults))
        local mine, mine_on = 0, 0
        for _, r in ipairs(c.list()) do mine = mine + 1; if r.on ~= false then mine_on = mine_on + 1 end end
        nav_item(ui, 2, "My reactions", mine == 0 and "none yet" or string.format("%d, %d on", mine, mine_on))
        local job = c.share and c.share.job
        if not job then
            nav_item(ui, 6, "Import", "from a GitHub link")
        elseif job.busy then
            nav_item(ui, 6, "Import", "reading GitHub...", "info", "info")
        elseif job.err then
            nav_item(ui, 6, "Import", "could not import", "danger", "danger")
        else
            nav_item(ui, 6, "Import", string.format("%d found", job.found or 0), "success")
        end
        local d = state.draft
        nav_item(ui, 3, "Editor", d and (tostring(d.name) .. (state.dirty and " (unsaved)" or "")) or "nothing open",
            d and state.dirty and "warning" or nil, d and state.dirty and "warning" or nil)
        local lib = c.library_state()
        local fns = lib.fns or {}
        nav_item(ui, 4, "Library", lib.err and "has an error" or (#fns == 1 and "1 function" or (#fns .. " functions")),
            lib.err and "danger" or nil, lib.err and "danger" or nil)
        local live = c.latest_W() ~= nil
        nav_item(ui, 5, "Live", live and "fight picture live" or "waits for the rotation", live and "success" or nil,
            live and "success" or nil)
        ui:spacer(8)
        ui:indent(8)
        if ui:button("new", "+ New reaction", { style = "primary", w = w - 16,
            tooltip = "A new reaction for your class, from the template picked under My reactions" }) then
            try_open(c.from_template(state.template))
        end
        ui:spacer(10)
        -- Text size: this window only; the window grows and shrinks with it.
        -- The fourth column is the right margin the New reaction button has.
        ui:row({ 36, 0, 36, 4 })
        if ui:button("zoom_out", "A-", { style = "ghost", disabled = zoom() <= ZOOMS[1] + 0.001,
            tooltip = "Smaller text in this window" }) then zoom_step(-1) end
        ui:custom("zoom_lbl", 22, function(cv)
            local s = string.format("Text %d%%", math.floor(zoom() * 100 + 0.5))
            cv:text(s, cv.w / 2, 5, DIM, "small", true)
        end)
        if ui:hovered() then ui:tooltip("The size of everything in this window (JCore's UI scale moves every window)") end
        if ui:button("zoom_in", "A+", { style = "ghost", disabled = zoom() >= ZOOMS[#ZOOMS] - 0.001,
            tooltip = "Bigger text in this window" }) then zoom_step(1) end
        ui:end_row()
        ui:spacer(6)
        ui:text("Drag the title bar to move the window, its bottom-right corner to resize it.",
            { size = "small", color = FAINT })
        ui:unindent(8)
    end

    -- --- the view's title bar ---------------------------------------------------------

    local function top_bar(ui, c, f)
        local tab = state.tab
        local title, sub = VIEW_TITLE[tab], VIEW_SUB[tab]
        local right, right_col, stripe = nil, DIM, "accent"
        if tab == 1 then
            local on = 0
            for _, d in ipairs(f.defaults) do if d.here then on = on + 1 end end
            right = string.format("%d of %d act here", on, #f.defaults)
        elseif tab == 2 then
            sub = string.format("Your own for every %s, weighed with the built-in ones: the most important thing "
                .. "happening wins.", class_label(c.class()))
            right = #c.list() .. " of your own"
        elseif tab == 3 then
            local r = state.draft
            if r then
                local imp = c.D.IMPORTANCE_BY_KEY[r.importance] or c.D.IMPORTANCE_BY_KEY.defensive
                stripe = cat_color(imp.category)
                title = (r.id and "Editing: " or "New: ") .. tostring(r.name)
                sub = summary(c, r)
                local pv = f.preview
                right = pv and (pv.pass and "conditions hold now" or "conditions do not hold now") or "no live picture"
                right_col = pv and pv.pass and "success" or DIM
            else
                sub = "Nothing open: open one under My reactions, or create one."
            end
        elseif tab == 5 then
            local live = c.latest_W() ~= nil
            right = live and "fight picture live" or "waits for the rotation"
            right_col = live and "success" or FAINT
        elseif tab == 6 then
            right = "for every " .. class_label(c.class())
        end
        ui:custom("top", TOP_H, function(cv)
            cv:fill(0, 0, cv.w, cv.h, "bg_elevated", 6)
            cv:fill(0, 0, 4, cv.h, stripe, 2)
            local rw = right and cv:text_width(right, "small") or 0
            cv:text(fit(cv, title, cv.w - rw - 44, 16), 14, 6, "text", 16)
            if sub then cv:text(fit(cv, sub, cv.w - 28, "small"), 14, 28, DIM, "small") end
            if right then cv:text(right, cv.w - rw - 12, 9, right_col, "small") end
        end)
        if sub and ui:hovered() then ui:tooltip(sub) end
    end

    -- --- view 1: the built-in reactions -------------------------------------------------

    local function count_of(list, field)
        local n = 0
        for _, d in ipairs(list) do if d[field] then n = n + 1 end end
        return n
    end

    --- Puts a column (or every place, key nil) back to the plugin's own
    --- choice, after asking.
    local function reset_places(c, key, label)
        local function go()
            local n = c.reset_defaults(key)
            toast(n == 0 and (label .. ": already as they come") or
                string.format("%s: %d back to how they come", label, n), "success")
        end
        if ctx.ui and ctx.ui.confirm then
            pcall(ctx.ui.confirm, ctx.ui, {
                title = "Reset " .. label:lower() .. "?", tone = "warning", confirm_label = "Reset",
                body = key and string.format("Every built-in reaction goes back to how it comes in %s. "
                    .. "Where else each acts stays as you set it.", label:lower())
                    or "Every built-in reaction goes back to how it comes, everywhere.",
                on_confirm = go,
            })
        else
            go()
        end
    end

    --- The search, then the two places side by side (how many act in each,
    --- and which one you are in), then the resets.
    local function defaults_tools(ui, c, f)
        ui:row({ 0, 120 })
        put(ui, "def_search", state.search)
        state.search = ui:text_input("def_search", nil, state.search, { placeholder = "Search the built-in reactions..." })
        local any_open = false
        for _, d in ipairs(f.defaults) do
            if not state.cat_closed[d.category or "utility"] then any_open = true break end
        end
        if ui:button("fold", any_open and "Collapse all" or "Expand all", { style = "ghost", disabled = state.search ~= "",
            tooltip = "Fold every category away, or open them all" }) then
            for _, d in ipairs(f.defaults) do state.cat_closed[d.category or "utility"] = any_open or nil end
        end
        ui:end_row()

        local cols = c.D.PLACE_COLUMNS
        local kind = c.where()
        local total = #f.defaults
        ui:custom("places", 40, function(cv)
            local gap = 8
            local cw = math.floor((cv.w - gap * #cols) * 0.3)
            for i, col in ipairs(cols) do
                local x = (i - 1) * (cw + gap)
                local here = kind == col.key
                cv:fill(x, 0, cw, cv.h, here and { 100, 200, 140, 45 } or "bg_elevated", 6)
                if here then cv:fill(x, 0, 4, cv.h, "success", 2) end
                cv:text(col.label, x + 12, 5, "text", "small")
                local line = string.format("%d of %d on", count_of(f.defaults, col.key), total)
                cv:text(line, x + 12, 22, DIM, "small")
                if here then
                    local pill = "you are here"
                    local pw = cv:text_width(pill, "small") + 14
                    cv:fill(x + cw - pw - 8, 11, pw, 18, { 100, 200, 140, 70 }, 9)
                    cv:text(pill, x + cw - pw - 1, 14, "success", "small")
                end
            end
            local x = #cols * (cw + gap)
            local w = cv.w - x
            cv:text(fit(cv, "You are in: " .. c.where_text(), w, "small"), x, 5, DIM, "small")
            local note = (kind == "world" or kind == "dungeon")
                and string.format("%d of %d act here.", count_of(f.defaults, "here"), total)
                or "Here, each row's Where decides."
            cv:text(fit(cv, note, w, "small"), x, 22, FAINT, "small")
        end)
        if ui:hovered() then
            ui:tooltip("Each built-in reaction has a switch for the open world and one for dungeons. "
                .. "Raids, battlegrounds, arenas and open world PvP are under Where on each row.")
        end

        ui:row({ 0, 0, 0, 0 })
        for _, col in ipairs(cols) do
            if ui:button("reset_" .. col.key, "Reset " .. col.label:lower(), { style = "ghost", size = "small",
                tooltip = "Every built-in reaction back to how it comes in " .. col.label:lower() }) then
                reset_places(c, col.key, col.label)
            end
        end
        if ui:button("reset_all", "Reset everything", { style = "ghost", size = "small",
            tooltip = "Every built-in reaction back to how it comes, everywhere" }) then
            reset_places(c, nil, "Every place")
        end
        if ui:button("to_packs", "Starter packs", { style = "ghost", size = "small",
            tooltip = "Ready-made reactions of your own for dungeons and the open world (under My reactions)" }) then
            state.tab = 2
            state.packs_open = state.packs_open or {}
            state.packs_open.dungeon, state.packs_open.world = true, true
        end
        ui:end_row()
    end

    local function default_row(ui, c, d)
        local key = slug(d.name)
        local open = state.expanded == d.name
        ui:row({ 0, 104, 118, 176 })
        ui:custom("defn_" .. key, ui:metrics().row, function(cv)
            local dot = d.here and "success" or (d.on and { 160, 163, 176, 160 }) or FAINT
            cv:circle(7, cv.h / 2, 4, dot, true)
            local tag = d.mine and "changed" or nil
            local tw = tag and (cv:text_width(tag, "small") + 12) or 0
            local name = fit(cv, d.name, cv.w - 24 - tw, "body")
            local ty = math.floor((cv.h - 15) / 2)
            cv:text(name, 18, ty, d.on and "text" or FAINT, "body")
            if tag then
                local px = 18 + cv:text_width(name, "body") + 6
                cv:fill(px, 4, tw, cv.h - 8, { 140, 120, 240, 50 }, 7)
                cv:text(tag, px + 6, ty + 1, "accent", "small")
            end
        end)
        if ui:hovered() then
            ui:tooltip((d.info or d.name) .. (d.here and "  It acts where you are now." or "  It does not act where you are now."))
        end
        for _, col in ipairs(c.D.PLACE_COLUMNS) do
            local id = "defp_" .. col.key .. "_" .. key
            put(ui, id, d[col.key])
            local v, ch = ui:toggle(id, col.short, d[col.key], {
                tooltip = d.name .. " in " .. col.label:lower() .. ": " .. (d[col.key] and "on" or "off") })
            if ch then c.set_default_place(d.name, col.key, v) end
        end
        if ui:button("defw_" .. key, "Where: " .. c.env_text(d.env), { style = open and "primary" or "ghost",
            size = "small", tooltip = "Every place " .. d.name .. " may act: raids, battlegrounds, arenas, which dungeon" }) then
            state.expanded = (not open) and d.name or nil
        end
        ui:end_row()
        local meta = d.info or ("A " .. (CAT_LABEL[d.category] or d.category or "") .. " reaction.")
        if d.shipped_why then meta = meta .. "  Off in dungeons and raids as it comes: " .. d.shipped_why end
        if d.fired_n > 0 then meta = meta .. string.format("  Sent %d time%s, last %s.", d.fired_n,
            d.fired_n == 1 and "" or "s", ago(d.fired_at)) end
        if d.own then meta = meta .. "  Also follows its " .. d.own .. " switch." end
        ui:indent(18)
        ui:text(meta, { size = "small", color = d.on and DIM or FAINT })
        ui:unindent(18)
        if open then
            ui:indent(18)
            local env = c.copy(d.env or c.fresh_env())
            if draw_env(ui, c, "dx_" .. key .. "_", env) then c.set_default_env(d.name, env) end
            if d.mine then
                if ui:button("defr_" .. key, "Back to how it comes (" .. c.env_text(d.shipped_env) .. ")",
                    { style = "ghost", size = "small" }) then
                    c.set_default_env(d.name, nil)
                end
            end
            ui:unindent(18)
            ui:spacer(6)
        end
    end

    local function draw_defaults(ui, c, f)
        local want = state.search:lower()
        local searching = want ~= ""
        local by_cat, extra = {}, {}
        for _, d in ipairs(f.defaults) do
            if not searching or d.name:lower():find(want, 1, true) or (d.info or ""):lower():find(want, 1, true) then
                local cat = d.category or "utility"
                if not by_cat[cat] then
                    by_cat[cat] = {}
                    if not CAT_LABEL[cat] then extra[#extra + 1] = cat end
                end
                table.insert(by_cat[cat], d)
            end
        end
        local order = {}
        for _, cat in ipairs(CAT_ORDER) do order[#order + 1] = cat end
        for _, cat in ipairs(extra) do order[#order + 1] = cat end
        local shown = 0
        for _, cat in ipairs(order) do
            local list = by_cat[cat]
            if list then
                local counts = {}
                for _, col in ipairs(c.D.PLACE_COLUMNS) do
                    counts[#counts + 1] = string.format("%s %d/%d", col.short, count_of(list, col.key), #list)
                end
                -- A search opens every category it finds something in.
                local open = searching or not state.cat_closed[cat]
                if fold_header(ui, "cat_" .. cat, (CAT_LABEL[cat] or cat):upper(), table.concat(counts, "   "),
                    cat_color(cat), open, not searching) then
                    state.cat_closed[cat] = (not state.cat_closed[cat]) or nil
                end
                if open then
                    for _, d in ipairs(list) do default_row(ui, c, d) end
                    ui:spacer(4)
                end
                shown = shown + #list
            end
        end
        if shown == 0 then ui:text("Nothing matches the search.", { color = DIM }) end
    end

    -- --- view 2: my reactions -------------------------------------------------------------

    local function mine_tools(ui, c)
        ui:row({ 0, 180, 150 })
        local labels = {}
        for i, t in ipairs(c.D.TEMPLATES) do labels[i] = "Start from: " .. t.label end
        put(ui, "tpl", state.template)
        local v, ch = ui:dropdown("tpl", nil, labels, state.template, { no_wheel = true, max_visible = 10 })
        if ch then state.template = v end
        if ui:button("create", "+ Create new reaction", { style = "primary" }) then
            try_open(c.from_template(state.template))
        end
        if ui:button("to_import", "Import from GitHub", { style = "ghost",
            tooltip = "Someone's reactions, from a GitHub repository with a folder called Reaction" }) then
            state.tab = 6
        end
        ui:end_row()
        -- 1.79.0: find one among many; switch what is listed; paste one.
        if #c.list() == 0 then return end
        ui:row({ 0, 150, 70, 70, 70 })
        put(ui, "mine_q", state.mine_q)
        state.mine_q = ui:text_input("mine_q", nil, state.mine_q, { placeholder = "Search your reactions..." })
        put(ui, "mine_f", state.mine_filter)
        local fv, fch = ui:dropdown("mine_f", nil, FILTERS, state.mine_filter, { no_wheel = true })
        if fch then state.mine_filter = fv end
        local listed = M._listed(c)
        if ui:button("all_on", "All on", { style = "ghost", tooltip = "Switch on every reaction listed" }) then
            for _, r in ipairs(listed) do c.set_on(r.id, true) end
        end
        if ui:button("all_off", "All off", { style = "ghost", tooltip = "Switch off every reaction listed" }) then
            for _, r in ipairs(listed) do c.set_on(r.id, false) end
        end
        if ui:button("paste", "Paste", { style = "ghost",
            tooltip = "A reaction someone shared as text (their Share button): it opens in the editor to look over and save" }) then
            M._paste(c)
        end
        ui:end_row()
    end

    local function draw_card(ui, c, r, i, n)
        local imp = c.D.IMPORTANCE_BY_KEY[r.importance] or c.D.IMPORTANCE_BY_KEY.defensive
        local rt = c.runtime(r.id)
        local def = c.rule_of(r.id)
        local spell = first_spell(r)
        local sid = spell and book.id(spell) or nil
        -- What it is doing, or what stops it, in words (1.79.0).
        local why, tone = c.why(r)
        local why_col = TONE[tone] or DIM
        local _, clicked = ui:custom("card_" .. r.id, 80, function(cv)
            local dim = r.on == false
            local over = cv:hovered()
            cv:fill(0, 0, cv.w, cv.h, dim and { 30, 31, 38, 255 } or (over and "bg_hover" or "bg_elevated"), 6)
            cv:fill(0, 0, 5, cv.h, cat_color(imp.category, dim and 90 or 255), 3)
            if sid then
                cv:image("spell:" .. sid, 14, 13, 36, 36)
            else
                cv:fill(14, 13, 36, 36, { 48, 51, 64, 255 }, 6)
                local has_lua = false
                for _, list in ipairs({ r.conds or {}, r.actions or {} }) do
                    for _, row in ipairs(list) do if row.mode == "lua" then has_lua = true end end
                end
                cv:text(has_lua and "Lua" or "?", 32, 24, "accent", "small", true)
            end
            local right = string.format("%s  |  %d", imp.label, r.priority or imp.priority)
            local rw = cv:text_width(right, "small")
            cv:text(fit(cv, r.name or "?", cv.w - 70 - rw - 20, "body"), 60, 6, dim and FAINT or "text", "body")
            cv:text(right, cv.w - rw - 10, 8, cat_color(imp.category), "small")
            cv:text(fit(cv, summary(c, r), cv.w - 72, "small"), 60, 25, DIM, "small")
            local meta = c.env_text(r.env)
            if def and (def.fired_n or 0) > 0 then
                meta = meta .. string.format("  |  sent %d (%d this fight), last %s", def.fired_n,
                    rt and rt.fight_n or 0, ago(def.fired_at))
            end
            if r.wait and r.wait > 0 then meta = meta .. string.format("  |  waits %gs", r.wait) end
            if (r.per_fight or 0) > 0 then meta = meta .. string.format("  |  %d a fight", r.per_fight) end
            if type(r.source) == "table" and r.source.repo then
                meta = meta .. "  |  from " .. (tostring(r.source.repo):gsub("^github%.com/", ""))
            elseif type(r.source) == "table" and r.source.pack then
                meta = meta .. "  |  from the " .. pack_label(c, r.source.pack)
            end
            cv:text(fit(cv, meta, cv.w - 72, "small"), 60, 43, FAINT, "small")
            local dot = (tone == "ok" and "success") or (tone == "err" and "danger") or (tone == "wait" and "warning") or FAINT
            cv:circle(66, 69, 4, dot, true)
            cv:text(fit(cv, why, cv.w - 90, "small"), 76, 61, why_col, "small")
        end)
        if clicked then try_open(r) end
        if ui:hovered() then ui:tooltip(why .. "\nClick to edit. " .. summary(c, r)) end
        ui:row({ 76, 0, 0, 50, 58, 0, 0, 0 })
        local tid = "on_" .. r.id
        put(ui, tid, r.on ~= false)
        local on, flipped = ui:toggle(tid, "On", r.on ~= false)
        if flipped then c.set_on(r.id, on) end
        if ui:button("edit_" .. r.id, "Edit", { style = "primary" }) then try_open(r) end
        if ui:button("code_" .. r.id, "As Lua", { style = "ghost", tooltip = "Open it in the editor on its code" }) then
            try_open(r, 5)
        end
        if ui:button("up_" .. r.id, "Up", { style = "ghost", disabled = i == 1, tooltip = "Earlier in the list wins a tie" }) then c.move(r.id, -1) end
        if ui:button("down_" .. r.id, "Down", { style = "ghost", disabled = i == n }) then c.move(r.id, 1) end
        if ui:button("dup_" .. r.id, "Copy", { style = "ghost", tooltip = "A second one like it, to change" }) then
            local id = c.duplicate(r.id)
            if id then toast("Copied: " .. tostring((c.get(id) or {}).name), "success") end
        end
        if ui:button("clip_" .. r.id, "Share", { style = "ghost",
            tooltip = "To the clipboard as text: paste it in Discord, and a friend presses Paste under My reactions" }) then
            local text = c.share and c.share.encode(r, c.class()) or nil
            if text and clip_set(text) then toast(tostring(r.name) .. ": on the clipboard", "success")
            else toast("This loader gives no clipboard: use Export my reactions (Import and share)", "warning") end
        end
        if ui:button("del_" .. r.id, "Delete", { style = "danger" }) then
            local function gone()
                c.delete(r.id)
                if state.draft and state.draft.id == r.id then state.draft = nil end
                toast("Deleted " .. tostring(r.name), "info")
            end
            if ctx.ui.confirm then
                pcall(ctx.ui.confirm, ctx.ui, { title = "Delete this reaction?", tone = "danger",
                    body = tostring(r.name) .. " will be gone for every " .. class_label(c.class()) .. ".",
                    confirm_label = "Delete", on_confirm = gone })
            else
                gone()
            end
        end
        ui:end_row()
        ui:spacer(8)
    end

    -- --- the starter packs (1.78.0; react/packs.lua) ----------------------------------------

    local function pack_item(ui, c, p, it)
        local imp = c.D.IMPORTANCE_BY_KEY[it.importance] or c.D.IMPORTANCE_BY_KEY.defensive
        local key = p.key .. "_" .. it.key
        local waits = not it.usable and not it.id
        ui:row({ 0, 112 })
        ui:custom("pki_" .. key, 44, function(cv)
            cv:fill(0, 0, cv.w, cv.h, it.id and { 100, 200, 140, 24 } or "bg_elevated", 6)
            cv:fill(0, 0, 4, cv.h, cat_color(imp.category, waits and 90 or 255), 2)
            local right = it.where
            local rw = math.min(cv:text_width(right, "small"), math.floor(cv.w * 0.4))
            cv:text(fit(cv, it.name, cv.w - rw - 34, "body"), 12, 4, waits and FAINT or "text", "body")
            cv:text(fit(cv, right, rw, "small"), cv.w - rw - 10, 6, FAINT, "small")
            local line, col = it.what, DIM
            if waits then line, col = "Needs " .. table.concat(it.missing, " or ") .. ": " .. it.what, FAINT end
            cv:text(fit(cv, line, cv.w - 22, "small"), 12, 24, col, "small")
        end)
        if ui:hovered() then
            local tip = it.what .. "  Where: " .. it.where .. ".  " .. imp.label .. "."
            if #it.missing > 0 then tip = tip .. "  Not in your spellbook: " .. table.concat(it.missing, ", ") .. "." end
            ui:tooltip(tip)
        end
        if it.id then
            if ui:button("pko_" .. key, "Added: open", { style = "ghost",
                tooltip = "It is in My reactions: open it in the editor" }) then
                local r = c.get(it.id)
                if r then try_open(r) end
            end
        elseif it.usable then
            if ui:button("pka_" .. key, "Add", { style = "primary", tooltip = "Add it to My reactions, switched on" }) then
                local id, err = c.packs.add(p.key, it.key)
                if id then toast("Added " .. it.name, "success") else toast(tostring(err), "warning") end
            end
        else
            ui:button("pkn_" .. key, "Needs a spell", { style = "ghost", disabled = true,
                tooltip = "Not in your spellbook yet: " .. table.concat(it.missing, ", ") })
        end
        ui:end_row()
    end

    --- The Dungeon and Open world packs, each folding away. Open at first
    --- while you have no reactions of your own.
    local function draw_packs(ui, c)
        local packs = c.packs and c.packs.list() or nil
        if not packs then return end
        if state.packs_open == nil then
            local none = #c.list() == 0
            state.packs_open = { dungeon = none, world = none }
        end
        for _, p in ipairs(packs) do
            local open = state.packs_open[p.key] == true
            local col = PACK_COLOR[p.key] or { 160, 163, 176 }
            if fold_header(ui, "pack_" .. p.key, "STARTER: " .. p.label:upper(),
                string.format("%d of %d added", p.added, #p.items), col, open, true) then
                state.packs_open[p.key] = not open
            end
            if open then
                local can = 0
                for _, it in ipairs(p.items) do if it.usable and not it.id then can = can + 1 end end
                ui:indent(6)
                ui:row({ 0, 170 })
                ui:text(p.sub, { size = "small", color = DIM })
                if ui:button("pack_all_" .. p.key, can > 0 and string.format("Add the pack (%d)", can) or "Nothing to add",
                    { style = "primary", disabled = can == 0,
                      tooltip = "Every one you can use now and do not have yet, switched on" }) then
                    local done = c.packs.add_all(p.key)
                    local msg = string.format("Added %d from the %s", done.added, p.label)
                    if #done.waiting > 0 then msg = msg .. string.format(" (%d wait for a spell)", #done.waiting) end
                    toast(msg, "success")
                end
                ui:end_row()
                for _, it in ipairs(p.items) do pack_item(ui, c, p, it) end
                ui:unindent(6)
                ui:spacer(4)
            end
        end
        ui:spacer(6)
    end

    local function uses_lua(r)
        for _, list in ipairs({ r.conds or {}, r.actions or {} }) do
            for _, row in ipairs(list) do if row.mode == "lua" then return true end end
        end
        return false
    end

    --- Your reactions as the search and the filter leave them (1.79.0).
    function M._listed(c)
        local want = (state.mine_q or ""):lower()
        local f = state.mine_filter or 1
        local out = {}
        for _, r in ipairs(c.list()) do
            local src = type(r.source) == "table" and r.source or {}
            local keep = (f == 1) or (f == 2 and r.on ~= false) or (f == 3 and r.on == false)
                or (f == 4 and r.on ~= false and c.env_ok(r.env)) or (f == 5 and src.pack ~= nil)
                or (f == 6 and src.repo ~= nil) or (f == 7 and uses_lua(r))
            if keep and want ~= "" then
                keep = (r.name or ""):lower():find(want, 1, true) ~= nil or summary(c, r):lower():find(want, 1, true) ~= nil
            end
            if keep then out[#out + 1] = r end
        end
        return out
    end

    --- A reaction from the clipboard, opened in the editor (not saved).
    function M._paste(c)
        local text = clip_get()
        if not text or not text:find("%S") then toast("The clipboard is empty (or this loader gives none)", "warning") return end
        if not c.share then toast("Sharing did not load", "error") return end
        local items, err = c.share.decode(text, c.class())
        local it = nil
        for _, x in ipairs(items or {}) do if x.r then it = x break end end
        if not it then toast("That is not a reaction: " .. tostring(err or "nothing in it could be read"), "warning") return end
        local r = c.copy(it.r)
        r.id, r.on = nil, true
        c.normalise(r, 0)
        r.id = nil
        try_open(r)
        local more = #(items or {}) > 1 and string.format(" (the first of %d)", #items) or ""
        toast("Pasted " .. tostring(r.name) .. more .. ": look it over, then Save", "success")
    end

    local function draw_mine(ui, c)
        draw_packs(ui, c)
        local all = c.list()
        local list = M._listed(c)
        if c.packs and #all > 0 then
            ui:separator(#list == #all and "Your reactions" or string.format("Your reactions: %d of %d shown", #list, #all))
        end
        if #all > 0 and #list == 0 then ui:text("Nothing matches the search or the filter.", { color = DIM }) return end
        if #list == 0 then
            ui:custom("empty", 70, function(cv)
                cv:fill(0, 0, cv.w, cv.h, { 36, 38, 48, 140 }, 6)
                cv:text("No reactions of your own yet.", cv.w / 2, 16, "text", "body", true)
                cv:text("Add a starter pack above, or pick a starting point and press Create.",
                    cv.w / 2, 40, DIM, "small", true)
            end)
            return
        end
        for i, r in ipairs(list) do draw_card(ui, c, r, i, #list) end
    end

    -- --- view 3: the editor ----------------------------------------------------------------

    --- Your spells: a search box and a list of what matches. Typing a name
    --- that is not a spell and pressing Enter takes it as typed (a buff
    --- somebody else casts on you, a cast of the mob's).
    local function spell_picker(ui, c, key, current, on_pick, pet)
        current = current or ""
        local q = state.spell_q[key] or ""
        ui:row({ 26, 0.38, 0 })
        local sid = (not pet) and current ~= "" and book.id(current) or nil
        if sid then ui:spell_icon(sid, 22) else ui:custom(key .. "_ic", 22, function(cv)
            cv:fill(0, 0, 22, 22, { 48, 51, 64, 255 }, 4)
            cv:text("?", 11, 4, FAINT, "small", true)
        end) end
        put(ui, key .. "_q", q)
        local typed, submitted = ui:text_input(key .. "_q", nil, q, { placeholder = pet and "Search pet abilities"
            or "Search, or type a name + Enter" })
        state.spell_q[key] = typed
        if submitted and typed:find("%S") then on_pick((typed:gsub("^%s+", ""):gsub("%s+$", ""))) end
        local names = pet and c.pet_spells() or c.spells(typed)
        if pet and typed ~= "" then
            local f = {}
            for _, n in ipairs(names) do if n:lower():find(typed:lower(), 1, true) then f[#f + 1] = n end end
            names = f
        end
        local list = {}
        list[1] = current ~= "" and current or (pet and "(pick a pet ability)" or "(pick a spell)")
        for _, n in ipairs(names) do if n ~= current then list[#list + 1] = n end end
        if #list == 1 and current == "" then list[1] = (#typed > 0) and "(nothing matches)" or list[1] end
        put(ui, key .. "_dd", 1)
        local v, ch = ui:dropdown(key .. "_dd", nil, list, 1, { no_wheel = true, max_visible = 14 })
        if ch and v > 1 and list[v] then on_pick(list[v]) end
        ui:end_row()
    end

    --- An item you carry or wear (1.79.0): a search, and a list of what you
    --- have. Typing a name and pressing Enter takes it as typed (one that is
    --- in the bank today).
    local function item_picker(ui, c, key, current, on_pick)
        current = current or ""
        local q = state.item_q[key] or ""
        ui:row({ 0.45, 0 })
        put(ui, key .. "_q", q)
        local typed, submitted = ui:text_input(key .. "_q", nil, q, { placeholder = "Search your bags, or type a name + Enter" })
        state.item_q[key] = typed
        if submitted and typed:find("%S") then on_pick((typed:gsub("^%s+", ""):gsub("%s+$", ""))) end
        local list = { current ~= "" and current or "(pick an item you carry)" }
        local want = typed:lower()
        for _, n in ipairs(c.carried()) do
            if n ~= current and (want == "" or n:lower():find(want, 1, true)) then list[#list + 1] = n end
        end
        if #list == 1 and current == "" and want ~= "" then list[1] = "(nothing you carry matches)" end
        put(ui, key .. "_dd", 1)
        local v, ch = ui:dropdown(key .. "_dd", nil, list, 1, { no_wheel = true, max_visible = 14 })
        if ch and v > 1 and list[v] then on_pick(list[v]) end
        ui:end_row()
    end

    local function cond_labels(c)
        local labels, keys = {}, {}
        for i, d in ipairs(c.D.CONDITIONS) do
            labels[i] = d.group .. ": " .. d.label
            keys[i] = d.key
        end
        return labels, keys
    end

    local function reset_cond(c, cond, key)
        local d = c.D.CONDITION_BY_KEY[key]
        cond.key = key
        cond.num = nil
        if d.type == "number" then
            cond.op, cond.value = d.op or "<", d.default
        elseif d.type == "text_number" then
            cond.op, cond.value, cond.num = d.op or "<", d.default or "", d.default_num
        elseif d.type == "key" then
            cond.op, cond.value = "is", 0
        elseif d.type == "choice" then
            cond.op = "is"
            local _, values = c.choices(d.choices)
            cond.value = d.default ~= "" and d.default or values[1]
        else
            cond.op, cond.value = "is", d.default
        end
    end

    local function remove_row(list, uid)
        for i = #list, 1, -1 do if list[i].uid == uid then table.remove(list, i) end end
    end

    local function row_file_label(row) return row.file and "In a file" or "Edit in a file" end

    local function file_row(ui, c, r, row)
        if row.file then
            ui:row({ 0, 70 })
            ui:text("In a file: " .. c.full_path(row.file) .. "  -- open it in VS Code or Notepad++; save it and it "
                .. "loads here within 2 s.", { size = "small", color = "info" })
            if ui:button(did("unlink_" .. row.uid), "Unlink", { style = "ghost" }) then
                row.file = nil
                c.unlink_row(r.id, row.uid)
            end
            ui:end_row()
            local at = c.reloaded[row.file]
            if at and (clock() - at) < 6 then ui:text("Reloaded from the file " .. ago(at) .. ".", { size = "small", color = "success" }) end
        end
    end

    local function code_box(ui, c, id, row, what, slot, label)
        local _, err, line = c.compiled(row.code or "", what, label)
        local n = 1
        for _ in (row.code or ""):gmatch("\n") do n = n + 1 end
        put(ui, id, row.code or "")
        local text, changed = ui:code(id, row.code or "", {
            rows = math.max(3, math.min(12, n + 1)), words = c.D.API_WORDS, error_line = line,
            error = err or (slot and slot.err and ("When it ran: " .. slot.err)) or nil,
            placeholder = what == "cond" and "me.hp < 40 and fight.on_me >= 2" or 'cast("Frost Nova")',
        })
        if changed then row.code = text; dirty() end
    end

    local function draw_cond(ui, c, r, cond, i, preview, saved)
        local D = c.D
        local slot = (preview and preview.conds[cond.uid]) or (saved and saved.conds[cond.uid])
        local key = "c" .. cond.uid
        if cond.mode == "lua" then
            ui:row({ 22, 0, 128, 30 })
            light(ui, did(key .. "_l"), status_of(slot), slot and slot.err)
            ui:text("Condition " .. i .. ": Lua (true = it holds)", { color = "info" })
            if ui:button(did(key .. "_f"), row_file_label(cond), { style = "ghost", disabled = r.id == nil or cond.file ~= nil,
                tooltip = r.id == nil and "Save the reaction first" or "Write this code to a file you can open in any editor" }) then
                local path = c.link_row(r.id, cond.uid)
                if path then cond.file = path; toast("Written to " .. c.full_path(path), "success")
                else toast("Could not write the file on this loader", "error") end
            end
            if ui:button(did(key .. "_x"), "x", { style = "danger", tooltip = "Remove this condition" }) then
                remove_row(r.conds, cond.uid); dirty(); ui:end_row(); return
            end
            ui:end_row()
            code_box(ui, c, did(key .. "_code"), cond, "cond", slot, (r.name or "?") .. " / condition " .. i)
            file_row(ui, c, r, cond)
        else
            local d = D.CONDITION_BY_KEY[cond.key or ""] or D.CONDITIONS[1]
            if not D.CONDITION_BY_KEY[cond.key or ""] then reset_cond(c, cond, d.key) end
            ui:row({ 22, 0, 92, 80, 56, 30 })
            light(ui, did(key .. "_l"), status_of(slot), slot and slot.err)
            local labels, keys = cond_labels(c)
            local index = 1
            for j, k in ipairs(keys) do if k == cond.key then index = j end end
            put(ui, did(key .. "_k"), index)
            local v, ch = ui:dropdown(did(key .. "_k"), nil, labels, index, { no_wheel = true, max_visible = 16 })
            if ch and keys[v] and keys[v] ~= cond.key then reset_cond(c, cond, keys[v]); dirty() end
            d = D.CONDITION_BY_KEY[cond.key]
            local ops = D.OPS[d.type] or D.OPS.bool
            local olabels, oi = {}, 1
            for j, o in ipairs(ops) do olabels[j] = o.label; if o.key == cond.op then oi = j end end
            put(ui, did(key .. "_o"), oi)
            local ov, och = ui:dropdown(did(key .. "_o"), nil, olabels, oi, { no_wheel = true })
            if och and ops[ov] then cond.op = ops[ov].key; dirty() end
            local held = (tonumber(cond.for_s) or 0) > 0
            if ui:button(did(key .. "_hold"), held and string.format("%gs", cond.for_s) or "Hold for", {
                style = (held or state.timer_open[cond.uid]) and "primary" or "ghost",
                tooltip = "Make it count only once it has held for a while (moving for 2 s, low for 1 s...)" }) then
                state.timer_open[cond.uid] = not state.timer_open[cond.uid]
            end
            if ui:button(did(key .. "_lua"), "To Lua", { style = "ghost", tooltip = "Turn this row into the Lua it stands for" }) then
                cond.code = c.cond_code(cond)
                cond.mode = "lua"
                dirty()
            end
            if ui:button(did(key .. "_x"), "x", { style = "danger", tooltip = "Remove this condition" }) then
                remove_row(r.conds, cond.uid); dirty(); ui:end_row(); return
            end
            ui:end_row()
            ui:indent(26)
            if d.type == "number" then
                local val = tonumber(cond.value) or d.default
                put(ui, did(key .. "_v"), val)
                local nv, nch = ui:slider(did(key .. "_v"), d.label, d.min, d.max, val,
                    { step = d.step, suffix = d.suffix, no_wheel = true })
                if nch then cond.value = nv; dirty() end
            elseif d.type == "text_number" then
                if d.pick == "item" then
                    item_picker(ui, c, did(key .. "_s"), cond.value, function(name) cond.value = name; dirty() end)
                else
                    spell_picker(ui, c, did(key .. "_s"), cond.value, function(name) cond.value = name; dirty() end)
                end
                local val = tonumber(cond.num) or d.default_num
                put(ui, did(key .. "_n"), val)
                local nv, nch = ui:slider(did(key .. "_n"), "Compared with", d.min, d.max, val,
                    { step = d.step, suffix = d.suffix, no_wheel = true })
                if nch then cond.num = nv; dirty() end
            elseif d.type == "key" then
                put(ui, did(key .. "_key"), tonumber(cond.value) or 0)
                local _, vk = ui:keybind(did(key .. "_key"), "The key (click, then press it; Backspace clears)",
                    tonumber(cond.value) or 0, { persist = false })
                vk = tonumber(vk) or 0
                if vk ~= (tonumber(cond.value) or 0) then cond.value = vk; dirty() end
            elseif d.type == "text" then
                if d.pick == "spell" then
                    spell_picker(ui, c, did(key .. "_s"), cond.value, function(name) cond.value = name; dirty() end)
                elseif d.pick == "item" then
                    item_picker(ui, c, did(key .. "_s"), cond.value, function(name) cond.value = name; dirty() end)
                elseif d.pick == "name" then
                    put(ui, did(key .. "_t"), cond.value or "")
                    local tv = ui:text_input(did(key .. "_t"), nil, cond.value or "",
                        { placeholder = "The name, as the game shows it (Ragnaros, Defias Pillager...)" })
                    if tv ~= (cond.value or "") then cond.value = tv; dirty() end
                elseif d.pick == "place" then
                    local all = { "(pick an instance)" }
                    for _, kind in ipairs({ "dungeon", "raid", "bg", "arena" }) do
                        local places = c.places(kind)
                        for j = 2, #places do all[#all + 1] = places[j] end
                    end
                    local pi = 1
                    for j, n in ipairs(all) do if n == cond.value then pi = j end end
                    put(ui, did(key .. "_p"), pi)
                    local pv, pch = ui:dropdown(did(key .. "_p"), nil, all, pi, { no_wheel = true, max_visible = 14 })
                    if pch and pv > 1 then cond.value = all[pv]; dirty() end
                else
                    put(ui, did(key .. "_t"), cond.value or "")
                    local tv = ui:text_input(did(key .. "_t"), nil, cond.value or "", { placeholder = "The spell's name, as the game shows it" })
                    if tv ~= (cond.value or "") then cond.value = tv; dirty() end
                end
            elseif d.type == "choice" then
                local clabels, cvalues = c.choices(d.choices)
                if #clabels == 0 then
                    ui:text(d.choices == "library" and "Your Library has no functions yet (Library)." or "Nothing to pick.",
                        { size = "small", color = "warning" })
                else
                    local ci = 1
                    for j, val in ipairs(cvalues) do if val == cond.value then ci = j end end
                    put(ui, did(key .. "_c"), ci)
                    local cv2, cch = ui:dropdown(did(key .. "_c"), nil, clabels, ci, { no_wheel = true, max_visible = 14 })
                    if cch and cvalues[cv2] then cond.value = cvalues[cv2]; dirty() end
                    if cond.value == nil or cond.value == "" then cond.value = cvalues[ci] end
                end
            end
            if (tonumber(cond.for_s) or 0) > 0 or state.timer_open[cond.uid] then
                put(ui, did(key .. "_for"), tonumber(cond.for_s) or 0)
                local fv, fch = ui:slider(did(key .. "_for"), "Must hold for (0: at once)", 0, 10, tonumber(cond.for_s) or 0,
                    { step = 0.5, suffix = "s", no_wheel = true })
                if fch then cond.for_s = fv > 0 and fv or nil; dirty() end
            end
            local now = slot and (slot.err and ("cannot read: " .. slot.err)
                or string.format("now %s, %s", tostring(slot.shown or "?"), slot.ok and "holds" or "does not hold")) or "now: -"
            ui:text("Lua: " .. c.cond_code(cond) .. "     " .. now, { size = "small",
                color = slot and (slot.err and "danger" or slot.ok and "success") or DIM })
            ui:unindent(26)
        end
        ui:spacer(6)
    end

    local function target_dropdown(ui, c, id, a)
        local labels, keys, index = {}, {}, 1
        for j, t in ipairs(c.D.TARGETS) do
            labels[j], keys[j] = "On: " .. t.label, t.key
            if t.key == (a.target or "target") then index = j end
        end
        put(ui, id, index)
        local v, ch = ui:dropdown(id, nil, labels, index, { no_wheel = true, max_visible = 10 })
        if ch and keys[v] then a.target = keys[v]; dirty() end
    end

    local function move_row(list, i, delta)
        local j = i + delta
        if j < 1 or j > #list then return end
        list[i], list[j] = list[j], list[i]
    end

    local function draw_action(ui, c, r, a, i, saved)
        local D = c.D
        local slot = saved and saved.actions[a.uid]
        local key = "a" .. a.uid
        local st = slot and (slot.err and "err"
            or (slot.note and (slot.note:find("^would send") or slot.note:find("^goes at once"))) and "ok" or "no") or nil
        if a.mode == "lua" then
            ui:row({ 22, 0, 44, 128, 30 })
            light(ui, did(key .. "_l"), st, slot and slot.note)
            ui:text("Action " .. i .. ": Lua (cast(), use(), pet_cast(), hold()...)", { color = "info" })
            if ui:button(did(key .. "_up"), "Up", { style = "ghost", disabled = i == 1 }) then move_row(r.actions, i, -1); dirty() end
            if ui:button(did(key .. "_f"), row_file_label(a), { style = "ghost", disabled = r.id == nil or a.file ~= nil,
                tooltip = r.id == nil and "Save the reaction first" or "Write this code to a file you can open in any editor" }) then
                local path = c.link_row(r.id, a.uid)
                if path then a.file = path; toast("Written to " .. c.full_path(path), "success")
                else toast("Could not write the file on this loader", "error") end
            end
            if ui:button(did(key .. "_x"), "x", { style = "danger" }) then remove_row(r.actions, a.uid); dirty(); ui:end_row(); return end
            ui:end_row()
            code_box(ui, c, did(key .. "_code"), a, "act", slot, (r.name or "?") .. " / action " .. i)
            file_row(ui, c, r, a)
        else
            local kinds, ki = {}, 1
            for j, k in ipairs(D.ACTION_KINDS) do kinds[j] = k.label; if k.key == (a.kind or "spell") then ki = j end end
            local targeted = a.kind == nil or a.kind == "spell" or a.kind == "pet_spell" or a.kind == "pet_attack"
            ui:row({ 22, 0.36, 0, 44, 56, 30 })
            light(ui, did(key .. "_l"), st, slot and slot.note)
            put(ui, did(key .. "_k"), ki)
            local kv, kch = ui:dropdown(did(key .. "_k"), nil, kinds, ki, { no_wheel = true })
            if kch and D.ACTION_KINDS[kv] then a.kind = D.ACTION_KINDS[kv].key; dirty() end
            if targeted then target_dropdown(ui, c, did(key .. "_t"), a) else ui:skip() end
            if ui:button(did(key .. "_up"), "Up", { style = "ghost", disabled = i == 1,
                tooltip = "The first action that can go is sent" }) then move_row(r.actions, i, -1); dirty() end
            if ui:button(did(key .. "_lua"), "To Lua", { style = "ghost", tooltip = "Turn this row into the Lua it stands for" }) then
                a.code = c.action_code(a)
                a.mode = "lua"
                dirty()
            end
            if ui:button(did(key .. "_x"), "x", { style = "danger" }) then remove_row(r.actions, a.uid); dirty(); ui:end_row(); return end
            ui:end_row()
            ui:indent(26)
            local kind = a.kind or "spell"
            if kind == "spell" then
                spell_picker(ui, c, did(key .. "_s"), a.spell, function(name)
                    a.spell = name
                    local says = c.spell_target(name)
                    if says then a.target = says end
                    dirty()
                end)
            elseif kind == "pet_spell" then
                spell_picker(ui, c, did(key .. "_s"), a.spell, function(name) a.spell = name; dirty() end, true)
            elseif kind == "item" then
                local labels, keys, ii = {}, {}, 1
                for j, it in ipairs(D.ITEMS) do labels[j], keys[j] = it.label, it.key; if it.key == a.item then ii = j end end
                if not a.item then a.item = keys[1] end
                put(ui, did(key .. "_i"), ii)
                local iv, ich = ui:dropdown(did(key .. "_i"), nil, labels, ii, { no_wheel = true })
                if ich and keys[iv] then a.item = keys[iv]; dirty() end
            elseif kind == "lua_fn" then
                local fns = c.choices("library")
                if #fns == 0 then
                    ui:text("Your Library has no functions yet (Library).", { size = "small", color = "warning" })
                else
                    local fi = 1
                    for j, f in ipairs(fns) do if f == a.fn then fi = j end end
                    if not a.fn then a.fn = fns[1] end
                    put(ui, did(key .. "_fn"), fi)
                    local fv, fch = ui:dropdown(did(key .. "_fn"), nil, fns, fi, { no_wheel = true })
                    if fch and fns[fv] then a.fn = fns[fv]; dirty() end
                end
            elseif kind == "hold" then
                ui:text("While the conditions hold, nothing offensive goes out: the rotation and every attacking reaction wait.",
                    { size = "small", color = DIM })
            elseif kind == "named_item" then
                item_picker(ui, c, did(key .. "_ni"), a.name, function(name) a.name = name; dirty() end)
                ui:text("A trinket you wear, or anything in your bags with a use. Tick Off the global cooldown "
                    .. "(Basics) for a trinket or a potion.", { size = "small", color = DIM })
            elseif kind == "alert" then
                ui:row({ 0, 120, 130 })
                put(ui, did(key .. "_txt"), a.text or "")
                local tv = ui:text_input(did(key .. "_txt"), nil, a.text or "",
                    { placeholder = "What to show: HEALER DOWN, Kick now...", max_len = 60 })
                if tv ~= (a.text or "") then a.text = tv; dirty() end
                local clabels, ci = {}, 1
                for j, col in ipairs(D.ALERT_COLORS) do clabels[j] = col.label; if col.key == (a.color or "red") then ci = j end end
                put(ui, did(key .. "_col"), ci)
                local cv2, cch = ui:dropdown(did(key .. "_col"), nil, clabels, ci, { no_wheel = true })
                if cch and D.ALERT_COLORS[cv2] then a.color = D.ALERT_COLORS[cv2].key; dirty() end
                put(ui, did(key .. "_snd"), a.sound ~= false)
                local sv, sch = ui:toggle(did(key .. "_snd"), "Sound", a.sound ~= false)
                if sch then a.sound = sv; dirty() end
                ui:end_row()
                ui:text("At the top of the screen for a few seconds; again every 6 s (or its wait) while it holds.",
                    { size = "small", color = DIM })
                if ui:button(did(key .. "_try"), "Show it now", { style = "ghost", size = "small", w = 140 }) then
                    c.push_alert((a.text and a.text ~= "") and a.text or "Alert", a.color, a.sound ~= false)
                end
            elseif kind == "target" then
                local tlabels, tkeys, ti = {}, {}, 1
                for j, t in ipairs(D.SWITCH_TARGETS) do
                    tlabels[j], tkeys[j] = "To: " .. t.label, t.key
                    if t.key == (a.who or "attacker") then ti = j end
                end
                if not a.who then a.who = tkeys[1] end
                put(ui, did(key .. "_who"), ti)
                local wv, wch = ui:dropdown(did(key .. "_who"), nil, tlabels, ti, { no_wheel = true })
                if wch and tkeys[wv] then a.who = tkeys[wv]; dirty() end
                ui:text("Goes at once, then the next action can work on the new target. Not again for 1.5 s (or its wait).",
                    { size = "small", color = DIM })
            elseif kind == "stop_cast" then
                ui:text("Stops the cast or channel you are in, at once (to move, or to cast something more urgent).",
                    { size = "small", color = DIM })
            end
            ui:text("Lua: " .. c.action_code(a) .. (slot and slot.note and ("     now: " .. slot.note) or ""),
                { size = "small", color = st == "ok" and "success" or st == "err" and "danger" or DIM })
            ui:unindent(26)
        end
        ui:spacer(6)
    end

    local function new_row(c, r, list, row)
        row.uid = c.new_uid(r)
        list[#list + 1] = row
        dirty()
    end

    local function save_draft(c, close)
        local id = c.save(state.draft)
        if not id then toast("Could not save: the class is not known yet", "error") return end
        local saved = c.get(id)
        toast("Saved " .. tostring(saved and saved.name), "success")
        if close then
            state.draft = nil
            state.tab = 2
        else
            state.draft = c.copy(saved)
            state.dirty = false
        end
    end

    local function close_editor(r)
        if state.dirty and ctx.ui.confirm then
            pcall(ctx.ui.confirm, ctx.ui, { title = "Close without saving?", tone = "warning", confirm_label = "Close",
                body = "The changes to " .. tostring(r.name) .. " are not saved.",
                on_confirm = function() state.draft = nil; state.tab = 2 end })
        else
            state.draft = nil
            state.tab = 2
        end
    end

    --- The six steps, as tabs over the editor's body.
    local function editor_tools(ui, r)
        local labels = { "1  Basics", string.format("2  When (%d)", #r.conds), string.format("3  Do this (%d)", #r.actions),
            "4  Where", "5  As code", "6  Try it" }
        local id = did("step")
        put(ui, id, state.section)
        state.section = ui:tabs(id, labels, state.section, { persist = false })
    end

    --- Save and Close, under the body, always in view.
    local function editor_footer(ui, c, r)
        local problems = c.problems(r)
        ui:row({ 0, 84, 124, 84, 84 })
        ui:custom("foot_state", FOOT_H, function(cv)
            local s, col
            if #problems > 0 then
                s = string.format("! %d to look at: %s", #problems, problems[1])
                col = "warning"
            elseif state.dirty then
                s, col = "Unsaved changes", "warning"
            else
                s, col = "Saved", DIM
            end
            cv:text(fit(cv, s, cv.w - 8, "small"), 2, math.floor((cv.h - 12) / 2), col, "small")
        end)
        if #problems > 0 and ui:hovered() then ui:tooltip(table.concat(problems, "\n")) end
        if ui:button(did("save"), "Save", { style = "primary", h = FOOT_H, disabled = not state.dirty and r.id ~= nil }) then
            save_draft(c, false)
        end
        if ui:button(did("saveclose"), "Save and close", { style = "success", h = FOOT_H }) then save_draft(c, true) end
        if ui:button(did("revert"), r.id and "Revert" or "Discard", { style = "ghost", h = FOOT_H }) then
            if r.id and c.get(r.id) then state.draft = c.copy(c.get(r.id)); state.dirty = false
            else state.draft = nil; state.tab = 2 end
        end
        if ui:button(did("close"), "Close", { style = "ghost", h = FOOT_H }) then close_editor(r) end
        ui:end_row()
    end

    local function step_basics(ui, c, r)
        local D = c.D
        local imp = D.IMPORTANCE_BY_KEY[r.importance] or D.IMPORTANCE_BY_KEY.defensive
        ui:row({ 0.55, 0 })
        put(ui, did("name"), r.name or "")
        local name = ui:text_input(did("name"), "Name", r.name or "", { max_len = 40 })
        if name ~= r.name then r.name = name; dirty() end
        local ilabels, ii = {}, 1
        for j, x in ipairs(D.IMPORTANCE) do
            ilabels[j] = string.format("%s (%d)", x.label, x.priority)
            if x.key == r.importance then ii = j end
        end
        put(ui, did("imp"), ii)
        local iv, ich = ui:dropdown(did("imp"), "Importance", ilabels, ii, { no_wheel = true, max_visible = 12 })
        if ich and D.IMPORTANCE[iv] then
            r.importance = D.IMPORTANCE[iv].key
            r.priority = D.IMPORTANCE[iv].priority
            dirty()
        end
        ui:end_row()
        ui:spacer(4)
        ui:row({ 0, 0 })
        put(ui, did("prio"), r.priority or imp.priority)
        local pv, pch = ui:slider(did("prio"), "Priority", 1, 120, r.priority or imp.priority, { no_wheel = true,
            tooltip = "40 is the rotation: above it this takes the global cooldown from the rotation; below it, it goes out only when the rotation has nothing to press" })
        if pch then r.priority = pv; dirty() end
        put(ui, did("wait"), r.wait or 0)
        local wv, wch = ui:slider(did("wait"), "Wait between uses", 0, 30, r.wait or 0, { step = 0.5, suffix = "s", no_wheel = true })
        if wch then r.wait = wv; dirty() end
        ui:end_row()
        ui:spacer(4)
        ui:row({ 0, 0 })
        put(ui, did("combat"), r.combat_only ~= false)
        local cb, cbch = ui:toggle(did("combat"), "Only in combat", r.combat_only ~= false)
        if cbch then r.combat_only = cb; dirty() end
        put(ui, did("ogcd"), r.off_gcd == true)
        local og, ogch = ui:toggle(did("ogcd"), "Off the global cooldown", r.off_gcd == true,
            { tooltip = "For a spell or item that does not trigger the global cooldown (a trinket, a racial, a potion)" })
        if ogch then r.off_gcd = og; dirty() end
        ui:end_row()
        -- 1.79.0: a limit, and word when it goes.
        ui:spacer(4)
        ui:row({ 0, 0, 0 })
        put(ui, did("perfight"), r.per_fight or 0)
        local fv, fch = ui:slider(did("perfight"), "At most per fight (0: no limit)", 0, 10, r.per_fight or 0,
            { step = 1, no_wheel = true, tooltip = "Once it went out this many times, it waits for the next fight" })
        if fch then r.per_fight = math.floor(fv + 0.5); dirty() end
        put(ui, did("nalert"), r.notify_alert == true)
        local na, nach = ui:toggle(did("nalert"), "Alert on screen when it goes", r.notify_alert == true,
            { tooltip = "A line at the top of the screen: its name and what it sent" })
        if nach then r.notify_alert = na; dirty() end
        put(ui, did("nsound"), r.notify_sound == true)
        local ns, nsch = ui:toggle(did("nsound"), "A sound when it goes", r.notify_sound == true,
            { tooltip = "The raid warning sound" })
        if nsch then r.notify_sound = ns; dirty() end
        ui:end_row()
        ui:spacer(10)
        ui:separator("At a glance")
        ui:text(summary(c, r), { size = "small", color = DIM })
        ui:text("Where: " .. c.env_text(r.env), { size = "small", color = DIM })
        if type(r.source) == "table" and r.source.repo then
            ui:text(string.format("Imported from %s (%s)", tostring(r.source.repo), tostring(r.source.file or "?")),
                { size = "small", color = "info" })
        elseif type(r.source) == "table" and r.source.pack then
            ui:text("From the " .. pack_label(c, r.source.pack) .. ": yours now, to change as you like.",
                { size = "small", color = "info" })
        end
        -- Right now, and what it did (1.79.0).
        if r.id then
            local saved = c.get(r.id)
            ui:spacer(6)
            ui:separator("Right now")
            local text, tone = c.why(saved or r)
            ui:text(text .. (state.dirty and "  (as saved; your changes count once you save)" or ""),
                { size = "small", color = TONE[tone] or DIM })
            local rt = c.runtime(r.id)
            local hist = c.history(r.id)
            ui:separator(string.format("Latest fires: %d this session, %d this fight", rt and rt.total_n or 0,
                rt and rt.fight_n or 0))
            if #hist == 0 then ui:text("None yet this session.", { size = "small", color = DIM }) end
            for k = 1, math.min(8, #hist) do
                local h = hist[k]
                ui:text(string.format("%s:  %s%s, at %d%% health, %s%s", ago(h.at), h.what, h.on and (" on " .. h.on) or "",
                    h.hp or 0, h.where or "?", (h.reads or "") ~= "" and ("  (read " .. h.reads .. ")") or ""),
                    { size = "small", color = k == 1 and "text" or DIM })
            end
        end
        ui:spacer(4)
        ui:row({ 0, 0, 0 })
        if ui:button(did("go2"), "Next: When  >", { style = "ghost" }) then state.section = 2 end
        if ui:button(did("go6"), "Try it  >", { style = "ghost", tooltip = "Set a situation and see what it would do" }) then
            state.section = 6
        end
        ui:skip()
        ui:end_row()
    end

    local function step_when(ui, c, r, preview, saved)
        put(ui, did("match"), r.match == "any" and 2 or 1)
        local mv, mch = ui:dropdown(did("match"), nil, { "All of these must hold", "Any one of these is enough" },
            r.match == "any" and 2 or 1, { no_wheel = true })
        if mch then r.match = mv == 2 and "any" or "all"; dirty() end
        if #r.conds == 0 then
            ui:text("No conditions: it acts whenever its action can go" .. (r.combat_only ~= false and " in combat." or "."),
                { size = "small", color = DIM })
        end
        ui:spacer(4)
        local conds = {}
        for j, cond in ipairs(r.conds) do conds[j] = cond end
        for j, cond in ipairs(conds) do draw_cond(ui, c, r, cond, j, preview, saved) end
        ui:row({ 0, 0 })
        if ui:button(did("addc"), "+ Add condition") then new_row(c, r, r.conds, { mode = "gui", key = "me_hp", op = "<", value = 40 }) end
        if ui:button(did("addcl"), "+ Add Lua condition", { style = "ghost" }) then
            new_row(c, r, r.conds, { mode = "lua", code = "return me.hp < 40" })
        end
        ui:end_row()
    end

    local function step_do(ui, c, r, saved)
        local acts = {}
        for j, a in ipairs(r.actions) do acts[j] = a end
        for j, a in ipairs(acts) do draw_action(ui, c, r, a, j, saved) end
        ui:row({ 0, 0 })
        if ui:button(did("adda"), "+ Add action") then new_row(c, r, r.actions, { mode = "gui", kind = "spell", spell = "", target = "target" }) end
        if ui:button(did("addal"), "+ Add Lua action", { style = "ghost" }) then
            new_row(c, r, r.actions, { mode = "lua", code = 'cast("Spell name")' })
        end
        ui:end_row()
    end

    -- --- step 6: try it (1.79.0) ----------------------------------------------------------
    --
    -- The test bench: react/custom.lua's bench() runs the draft against a
    -- made-up picture of a fight. The situation lives in state.bench, from a
    -- ready-made one (custom_data's BENCH_PRESETS), or the fight as it is now.

    local function bench_preset(c, i)
        local p = c.D.BENCH_PRESETS[i] or c.D.BENCH_PRESETS[1]
        state.bench = c.copy(p.s)
        state.bench_preset = i
    end

    local function b_slider(ui, id, label, field, lo, hi, step, suffix, default)
        local s = state.bench
        local v = math.max(lo, math.min(hi, tonumber(s[field]) or default or 0))
        put(ui, "b_" .. id, v)
        local nv, ch = ui:slider("b_" .. id, label, lo, hi, v, { step = step or 1, suffix = suffix, no_wheel = true })
        if ch then s[field] = nv end
    end

    local function b_toggle(ui, id, label, field, default)
        local s = state.bench
        local cur = s[field]
        if cur == nil then cur = default == true end
        put(ui, "b_" .. id, cur == true)
        local v, ch = ui:toggle("b_" .. id, label, cur == true)
        if ch then s[field] = v end
    end

    local function b_text(ui, id, field, placeholder)
        local s = state.bench
        put(ui, "b_" .. id, s[field] or "")
        local v = ui:text_input("b_" .. id, nil, s[field] or "", { placeholder = placeholder })
        if v ~= (s[field] or "") then s[field] = v end
    end

    local function bench_group(ui, key, label, fn)
        local open = state.bench_open[key] == true
        if fold_header(ui, "bg_" .. key, label, nil, { 120, 140, 200 }, open, true) then
            state.bench_open[key] = not open
        end
        if open then
            ui:indent(8)
            fn()
            ui:unindent(8)
            ui:spacer(4)
        end
    end

    local function step_try(ui, c, r)
        local D = c.D
        if not state.bench then bench_preset(c, state.bench_preset or 1) end
        local s = state.bench
        ui:row({ 0, 170, 90 })
        local plabels = {}
        for i, p in ipairs(D.BENCH_PRESETS) do plabels[i] = "Situation: " .. p.label end
        put(ui, "b_preset", state.bench_preset or 1)
        local pv, pch = ui:dropdown("b_preset", nil, plabels, state.bench_preset or 1, { no_wheel = true, max_visible = 12 })
        if pch and D.BENCH_PRESETS[pv] then bench_preset(c, pv) end
        local live = c.latest_W() ~= nil
        if ui:button("b_live", "From the fight now", { style = "ghost", disabled = not live,
            tooltip = live and "The fight as it is this moment, to change from there" or "Needs the rotation running" }) then
            local now = c.situation_now()
            if now then state.bench = now; s = now end
        end
        if ui:button("b_reset", "Reset", { style = "ghost" }) then bench_preset(c, state.bench_preset or 1); s = state.bench end
        ui:end_row()

        -- What it would do.
        local res = c.bench(r, s)
        local tone_col = TONE[res.tone] or DIM
        ui:custom("b_verdict", 40, function(cv)
            local col = type(tone_col) == "table" and tone_col or ({ success = { 100, 200, 140 }, warning = { 240, 180, 60 },
                danger = { 235, 87, 87 } })[tone_col] or { 198, 201, 214 }
            cv:fill(0, 0, cv.w, cv.h, { col[1], col[2], col[3], 40 }, 6)
            cv:fill(0, 0, 4, cv.h, { col[1], col[2], col[3], 255 }, 2)
            cv:text(fit(cv, res.verdict, cv.w - 24, "body"), 14, 11, tone_col, "body")
        end)
        if ui:hovered() then ui:tooltip(res.verdict) end
        for i, cond in ipairs(r.conds or {}) do
            local slot = res.conds[cond.uid]
            ui:row({ 22, 0 })
            light(ui, "b_cl" .. cond.uid, status_of(slot), slot and slot.err)
            ui:text(string.format("When %d: %s  -- reads %s", i, c.cond_text(cond),
                slot and (slot.err and ("an error: " .. slot.err) or tostring(slot.shown or "?")) or "-"),
                { size = "small", color = slot and slot.ok and "success" or DIM })
            ui:end_row()
        end
        for i, a in ipairs(r.actions or {}) do
            local slot = res.actions[a.uid]
            ui:row({ 22, 0 })
            light(ui, "b_al" .. a.uid, slot and (slot.err and "err" or slot.ok and "ok" or "no") or nil)
            ui:text(string.format("Do %d: %s", i, slot and slot.note or "-"),
                { size = "small", color = slot and slot.ok and "success" or DIM })
            ui:end_row()
        end
        if #(r.conds or {}) == 0 then ui:text("No conditions: only Where and combat decide.", { size = "small", color = DIM }) end
        ui:spacer(6)
        ui:separator("The situation")

        bench_group(ui, "you", "YOU", function()
            ui:row({ 0, 0 })
            b_slider(ui, "hp", "My health", "hp", 1, 100, 1, "%")
            b_slider(ui, "power", "My mana / rage / energy", "power", 0, 100, 1, "%")
            ui:end_row()
            ui:row({ 0, 0 })
            b_slider(ui, "falling", "Health falling", "falling", 0, 50, 1, "%/s")
            b_slider(ui, "ctime", "Seconds in combat", "combat_time", 0, 300, 1, "s")
            ui:end_row()
            ui:row({ 0, 0, 0, 0 })
            b_toggle(ui, "combat", "In combat", "in_combat")
            b_toggle(ui, "moving", "Moving", "moving")
            b_toggle(ui, "casting", "Casting", "casting")
            b_toggle(ui, "key", "The key is held", "key")
            ui:end_row()
            ui:row({ 0, 0, 0 })
            b_toggle(ui, "hs", "Healthstone ready", "healthstone")
            b_toggle(ui, "pot", "Healing potion ready", "potion")
            b_toggle(ui, "mpot", "Mana potion ready", "mana_potion")
            ui:end_row()
            ui:row({ 0.5, 0, 0 })
            b_text(ui, "buffs", "buffs", "My buffs, by name, with commas (Ice Barrier, Frost Armor)")
            b_slider(ui, "bleft", "Their seconds left", "buff_left", 0, 60, 0.5, "s", 30)
            b_slider(ui, "bstk", "Their stacks", "buff_stacks", 1, 20, 1, nil, 1)
            ui:end_row()
            b_text(ui, "items", "items", "Items I carry, by name, with commas (Free Action Potion, Earthstrike)")
        end)
        bench_group(ui, "mobs", "MOBS", function()
            ui:row({ 0, 0 })
            b_slider(ui, "onme", "Mobs on me", "on_me", 0, 10)
            b_slider(ui, "melee", "In melee with me", "melee_on_me", 0, 10)
            ui:end_row()
            ui:row({ 0, 0 })
            b_slider(ui, "eng", "In the fight", "engaged", 0, 15)
            b_slider(ui, "cast", "Casting near me", "casters", 0, 8)
            ui:end_row()
            ui:row({ 0, 0 })
            b_slider(ui, "w8", "Within 8 yards", "within8", 0, 15)
            b_slider(ui, "w30", "Within 30 yards", "within30", 0, 30)
            ui:end_row()
            ui:row({ 0, 0 })
            b_slider(ui, "elites", "Elites in the fight", "elites", 0, 10)
            b_slider(ui, "players", "Enemy players near", "players", 0, 20)
            ui:end_row()
            ui:row({ 0, 0 })
            b_toggle(ui, "boss", "A boss fight", "boss")
            b_toggle(ui, "pvp", "Fighting players", "pvp")
            ui:end_row()
        end)
        bench_group(ui, "target", "MY TARGET", function()
            b_toggle(ui, "target", "I have a target", "target")
            if not s.target then return end
            ui:row({ 0, 0 })
            b_slider(ui, "thp", "Its health", "t_hp", 1, 100, 1, "%")
            b_slider(ui, "tdist", "Its distance", "t_distance", 0, 60, 1, "yd")
            ui:end_row()
            ui:row({ 0, 0, 0 })
            b_toggle(ui, "tcast", "Casting", "t_casting")
            b_toggle(ui, "tint", "Interruptible", "t_interruptible", true)
            b_slider(ui, "tleft", "Cast ends in", "t_cast_left", 0, 5, 0.1, "s")
            ui:end_row()
            ui:row({ 0, 0, 0, 0 })
            b_toggle(ui, "tme", "On me", "t_on_me")
            b_toggle(ui, "tpet", "On my pet", "t_on_pet")
            b_toggle(ui, "ttank", "On the tank", "t_on_tank")
            b_toggle(ui, "theal", "On the healer", "t_on_healer")
            ui:end_row()
            ui:row({ 0, 0, 0, 0 })
            b_toggle(ui, "telite", "Elite", "t_elite")
            b_toggle(ui, "tboss", "Boss", "t_boss")
            b_toggle(ui, "tplayer", "A player", "t_player")
            b_toggle(ui, "tflee", "Running away", "t_fleeing")
            ui:end_row()
            ui:row({ 0, 0 })
            b_text(ui, "tname", "t_name", "Its name")
            b_text(ui, "tcname", "t_cast_name", "The spell it casts")
            ui:end_row()
            ui:row({ 0.5, 0, 0 })
            b_text(ui, "debuffs", "debuffs", "Debuffs on it, by name (yours), with commas")
            b_slider(ui, "dleft", "Their seconds left", "debuff_left", 0, 60, 0.5, "s", 10)
            b_slider(ui, "dstk", "Their stacks", "debuff_stacks", 1, 20, 1, nil, 1)
            ui:end_row()
        end)
        bench_group(ui, "pet", "MY PET", function()
            ui:row({ 0, 0, 0 })
            b_toggle(ui, "pet", "My pet is out", "pet")
            b_slider(ui, "pethp", "Its health", "pet_hp", 1, 100, 1, "%")
            b_slider(ui, "petatk", "Mobs on it", "pet_attackers", 0, 10)
            ui:end_row()
        end)
        bench_group(ui, "group", "MY GROUP", function()
            ui:row({ 0, 0, 0, 0 })
            b_toggle(ui, "grp", "In a group", "in_group")
            b_toggle(ui, "raid", "In a raid", "in_raid")
            b_toggle(ui, "tank", "The tank is alive", "tank_alive", true)
            b_toggle(ui, "healer", "The healer is alive", "healer_alive", true)
            ui:end_row()
            ui:row({ 0, 0, 0 })
            b_slider(ui, "dead", "Members dead", "dead", 0, 39)
            b_slider(ui, "lowest", "Lowest member's health", "lowest", 1, 100, 1, "%")
            b_slider(ui, "hurt", "Members under 50%", "hurt", 0, 40)
            ui:end_row()
            b_toggle(ui, "hatk", "A mob is on the healer", "healer_attacked")
        end)
        bench_group(ui, "where", "WHERE", function()
            local labels, keys, wi = {}, {}, 1
            for j, w in ipairs(D.WHERE) do labels[j], keys[j] = w.label, w.key; if w.key == (s.where or "world") then wi = j end end
            put(ui, "b_where", wi)
            local wv, wch = ui:dropdown("b_where", nil, labels, wi, { no_wheel = true })
            if wch and keys[wv] then s.where = keys[wv] end
            b_text(ui, "wname", "where_name", "The instance's name, for a reaction held to one (Molten Core)")
        end)
    end

    local function step_code(ui, c, r, body_h)
        local code = c.reaction_code(r)
        put(ui, did("as_code"), code)
        ui:code(did("as_code"), code, { h = math.max(120, body_h - 40), disabled = true, words = c.D.API_WORDS })
    end

    local function draw_editor(ui, c, f, body_h)
        local r = state.draft
        if not r then
            ui:custom("ed_empty", 70, function(cv)
                cv:fill(0, 0, cv.w, cv.h, { 36, 38, 48, 140 }, 6)
                cv:text("Nothing open in the editor.", cv.w / 2, 16, "text", "body", true)
                cv:text("Open one under My reactions, or create one.", cv.w / 2, 40, DIM, "small", true)
            end)
            ui:row({ 0, 0, 0 })
            if ui:button("ed_new", "+ Create new reaction", { style = "primary" }) then try_open(c.from_template(state.template)) end
            if ui:button("ed_mine", "My reactions", { style = "ghost" }) then state.tab = 2 end
            ui:skip()
            ui:end_row()
            return
        end
        local saved = r.id and c.runtime(r.id) or nil
        local step = state.section
        ui:text(STEP_HINT[step], { size = "small", color = DIM })
        ui:spacer(2)
        if step == 1 then step_basics(ui, c, r)
        elseif step == 2 then step_when(ui, c, r, f.preview, saved)
        elseif step == 3 then step_do(ui, c, r, saved)
        elseif step == 4 then
            if draw_env(ui, c, did("env_"), r.env) then dirty() end
        elseif step == 6 then step_try(ui, c, r)
        else step_code(ui, c, r, body_h) end
    end

    -- --- view 4: the Library -------------------------------------------------------------

    local function library_tools(ui, c)
        ui:row({ 120, 84, 0 })
        if ui:button("lib_save", "Save Library", { style = "primary", disabled = not state.lib_dirty }) then
            local err = c.set_library(state.lib_text)
            state.lib_dirty = false
            if err then toast("Saved, but it has an error: " .. tostring(err), "warning")
            else toast("Library saved", "success") end
        end
        if ui:button("lib_revert", "Revert", { style = "ghost", disabled = not state.lib_dirty }) then
            state.lib_text = c.library()
            state.lib_dirty = false
        end
        if c.library_file() then
            if ui:button("lib_unlink", "Stop reading the file", { style = "ghost" }) then c.unlink_library() end
        else
            if ui:button("lib_link", "Edit in a file (VS Code, Notepad++)", { style = "ghost" }) then
                if state.lib_dirty then
                    c.set_library(state.lib_text)
                    state.lib_dirty = false
                end
                local p = c.link_library()
                if p then toast("Written to " .. c.full_path(p), "success") else toast("Could not write the file on this loader", "error") end
            end
        end
        ui:end_row()
    end

    local function draw_library(ui, c, body_h)
        local D = c.D
        if not c.lua_available() then
            ui:text("This loader cannot run Lua code: Lua rows and the Library are kept, but never run.", { color = "warning" })
        end
        local st = c.library_state()
        put(ui, "lib_code", state.lib_text)
        local text, changed = ui:code("lib_code", state.lib_text, { h = math.max(160, math.floor(body_h * 0.62)),
            words = D.API_WORDS,
            error_line = (not state.lib_dirty) and st.line or nil,
            error = (not state.lib_dirty) and st.err or nil })
        if changed then state.lib_text = text; state.lib_dirty = true end
        local path = c.library_file()
        if path then
            ui:text("In a file: " .. c.full_path(path) .. "  -- save it in your editor and it loads here within 2 s.",
                { size = "small", color = "info" })
            local at = c.reloaded[path]
            if at and (clock() - at) < 6 then ui:text("Reloaded from the file " .. ago(at) .. ".", { size = "small", color = "success" }) end
        end
        local fns = st.fns or {}
        ui:text("Functions it makes: " .. (#fns > 0 and (table.concat(fns, "(), ") .. "()") or "none yet")
            .. ". Call them from any Lua row, or pick them as \"My Lua function\" (When) or \"Run my Lua function\" (Do this).",
            { size = "small", color = #fns > 0 and "success" or DIM })
        ui:spacer(4)
        if fold_header(ui, "api", "WHAT YOUR CODE CAN READ AND CALL", #D.API .. " names", API_COLOR, state.api_open, true) then
            state.api_open = not state.api_open
        end
        if state.api_open then
            for _, api in ipairs(D.API) do
                ui:row({ 90, 0 })
                ui:text(api.name, { color = "info" })
                ui:text(api.text, { size = "small", color = DIM })
                ui:end_row()
            end
            ui:text("Condition keys for check(): " .. (function()
                local keys = {}
                for _, d in ipairs(D.CONDITIONS) do keys[#keys + 1] = d.key end
                return table.concat(keys, ", ")
            end)(), { size = "small", color = FAINT })
        end
    end

    -- --- view 5: live -------------------------------------------------------------------------

    local function draw_live(ui, c)
        local W = c.latest_W()
        tiles(ui, "tiles", {
            { "WHERE YOU ARE", c.where_text() },
            { "FIGHT MODE", W and tostring(W.mode or "NORMAL") or "-" },
            { "DANGER", W and string.format("%d", math.floor((W.env.danger or 0) + 0.5)) or "-" },
            { "MOBS IN THE FIGHT / ON YOU", W and string.format("%d / %d", W.enemies.engaged or 0, W.enemies.on_me or 0) or "-" },
        })
        if not W then
            ui:text("The rotation is not running, so there is no picture of a fight: the lights wait for it.",
                { size = "small", color = DIM })
        end
        ui:spacer(4)
        ui:separator("Your reactions right now")
        local list = c.list()
        if #list == 0 then ui:text("None yet (My reactions).", { size = "small", color = DIM }) end
        for _, r in ipairs(list) do
            -- In words, what it does or what stops it (1.79.0).
            local why, tone = c.why(r)
            local st = (tone == "ok" and "ok") or (tone == "err" and "err") or (tone == "wait" and "no") or nil
            ui:row({ 22, 0.32, 0 })
            light(ui, "lv_" .. r.id, st)
            ui:text(r.name or "?", { color = r.on == false and FAINT or "text" })
            ui:text(why, { size = "small", color = TONE[tone] or DIM })
            ui:end_row()
        end
        -- Every fire of yours this session, newest first (1.79.0).
        local feed = {}
        for _, r in ipairs(list) do
            for _, h in ipairs(c.history(r.id)) do feed[#feed + 1] = { r = r, h = h } end
        end
        table.sort(feed, function(a, b) return a.h.at > b.h.at end)
        if #feed > 0 then
            ui:spacer(4)
            ui:separator("Your reactions' fires")
            for k = 1, math.min(12, #feed) do
                local e = feed[k]
                ui:row({ 0.3, 0 })
                ui:text(e.r.name or "?", { size = "small", color = "info" })
                ui:text(string.format("%s: %s%s, at %d%% health, %s", ago(e.h.at), e.h.what, e.h.on and (" on " .. e.h.on) or "",
                    e.h.hp or 0, e.h.where or "?"), { size = "small", color = DIM })
                ui:end_row()
            end
        end
        ui:spacer(4)
        ui:separator("Sent most recently")
        local fired = {}
        local rules = P.react and P.react.rules and P.react.rules() or {}
        for _, def in ipairs(rules) do if def.fired_at then fired[#fired + 1] = def end end
        table.sort(fired, function(a, b) return a.fired_at > b.fired_at end)
        if #fired == 0 then ui:text("Nothing yet this session.", { size = "small", color = DIM }) end
        for k = 1, math.min(10, #fired) do
            local def = fired[k]
            ui:row({ 0.45, 0.35, 0 })
            ui:text(def.name, { size = "small", color = def.custom and "info" or "text" })
            ui:text(tostring(def.fired_name or ""), { size = "small" })
            ui:text(string.format("%s (%dx)", ago(def.fired_at), def.fired_n or 0), { size = "small", color = DIM })
            ui:end_row()
        end
        ui:spacer(4)
        ui:separator("The engine's journal")
        local lines = P.react and P.react.log_lines and P.react.log_lines(12) or {}
        for _, l in ipairs(lines) do ui:text(l, { size = "small", color = DIM, wrap = false }) end
    end

    -- --- view 6: import and share (1.77.2) ------------------------------------------------------

    local function import_tools(ui, c)
        local S = c.share
        local busy = S and S.job and S.job.busy
        ui:row({ 0, 96 })
        put(ui, "imp_url", state.import_url)
        local url, submitted = ui:text_input("imp_url", nil, state.import_url,
            { placeholder = "https://github.com/someone/their-reactions", max_len = 300 })
        state.import_url = url
        local go = ui:button("imp_fetch", busy and "Reading..." or "Fetch", { style = "primary",
            disabled = busy or not S or not url:find("%S"), tooltip = "Read the Reaction folder at that link" })
        ui:end_row()
        if S and not busy and url:find("%S") and (go or submitted) then S.fetch(url) end
    end

    local function check_mark(cv, x, y)
        cv:line(x, y, x + 3, y + 3, "accent_text", 2)
        cv:line(x + 3, y + 3, x + 8, y - 3, "accent_text", 2)
    end

    --- One reaction found at the link: click to pick it.
    local function import_row(ui, c, it, i)
        local mine = c.class()
        local usable = it.r ~= nil and not it.imported
        local imp = it.r and (c.D.IMPORTANCE_BY_KEY[it.r.importance] or c.D.IMPORTANCE_BY_KEY.defensive) or nil
        local other = it.r and it.class and it.class ~= mine
        local notes = it.notes or {}
        local line3, col3 = nil, FAINT
        if it.imported then
            line3, col3 = "Imported" .. (it.imported_on and "" or ", switched off")
                .. (other and (": waits for your " .. class_label(it.class)) or ": see My reactions"), "success"
        elseif it.err then
            line3, col3 = tostring(it.file or ""), FAINT
        else
            local parts = {}
            if other then parts[#parts + 1] = "goes to your " .. class_label(it.class) .. "'s list" end
            for _, n in ipairs(notes) do parts[#parts + 1] = n end
            if #parts > 0 then line3, col3 = table.concat(parts, "; "), "warning"
            else line3 = c.env_text(it.r.env) .. "  |  " .. tostring(it.file or "") end
        end
        local _, clicked = ui:custom("imp_" .. i, 54, function(cv)
            local over = usable and cv:hovered()
            cv:fill(0, 0, cv.w, cv.h, over and "bg_hover" or "bg_elevated", 6)
            cv:fill(0, 0, 5, cv.h, it.err and "danger" or cat_color(imp.category, it.imported and 90 or 255), 3)
            if it.imported then
                cv:circle(22, 18, 8, "success", true)
                check_mark(cv, 18, 18)
            elseif usable then
                cv:fill(14, 10, 16, 16, it.pick and "accent" or "bg_input", 3)
                cv:rect(14, 10, 16, 16, over and "border_focus" or "border", 1, 3)
                if it.pick then check_mark(cv, 18, 18) end
            else
                cv:circle(22, 18, 8, { 235, 87, 87, 60 }, true)
                cv:text("!", 22, 11, "danger", "small", true)
            end
            -- Right: the class, a Lua mark, the importance.
            local rx = cv.w - 10
            if imp then
                local s = string.format("%s  |  %d", imp.label, it.r.priority or imp.priority)
                rx = rx - cv:text_width(s, "small")
                cv:text(s, rx, 8, cat_color(imp.category), "small")
                rx = rx - 10
            end
            if it.lua then
                local lw = cv:text_width("Lua", "small") + 12
                rx = rx - lw
                cv:fill(rx, 6, lw, 15, { 90, 160, 235, 60 }, 7)
                cv:text("Lua", rx + 6, 8, "info", "small")
                rx = rx - 6
            end
            if it.r then
                local label = it.class and class_label(it.class) or "Any class"
                local cc = CLASS_COLOR[it.class or ""] or { 200, 200, 210 }
                local pw = cv:text_width(label, "small") + 14
                rx = rx - pw
                cv:fill(rx, 6, pw, 15, { cc[1], cc[2], cc[3], 50 }, 7)
                cv:text(label, rx + 7, 8, { cc[1], cc[2], cc[3], 255 }, "small")
            end
            cv:text(fit(cv, tostring(it.name or "?"), rx - 52, "body"), 42, 5,
                (it.imported or it.err) and FAINT or "text", "body")
            if it.err then
                cv:text(fit(cv, "Cannot import: " .. tostring(it.err), cv.w - 52, "small"), 42, 23, "danger", "small")
            else
                cv:text(fit(cv, summary(c, it.r), cv.w - 52, "small"), 42, 23, DIM, "small")
            end
            cv:text(fit(cv, line3, cv.w - 52, "small"), 42, 39, col3, "small")
        end)
        if ui:hovered() then
            local tip = {}
            if it.description then tip[#tip + 1] = it.description end
            if it.author then tip[#tip + 1] = "By " .. it.author end
            if it.lua then tip[#tip + 1] = "It has Lua code: it runs in the reactions' sandbox. Look it over in the editor (As code) before you switch it on." end
            for _, n in ipairs(notes) do tip[#tip + 1] = "- " .. n end
            tip[#tip + 1] = tostring(it.file or "")
            ui:tooltip(table.concat(tip, "\n"))
        end
        if clicked and usable then it.pick = not it.pick end
    end

    local function import_now(c, S)
        local done, err = S.import({ switch_on = state.imp_on, add_library = state.imp_lib })
        if not done then toast(err or "Nothing imported", "error") return end
        local parts = {}
        if done.mine > 0 then parts[#parts + 1] = string.format("%d to your %s list", done.mine, class_label(c.class())) end
        for cls, n in pairs(done.other) do parts[#parts + 1] = string.format("%d to your %s's", n, class_label(cls)) end
        if done.libraries > 0 then parts[#parts + 1] = "their Library into yours" end
        if #parts == 0 then toast("Nothing new to import.", "info") return end
        local off = done.total > 0 and not state.imp_on
        toast("Imported " .. table.concat(parts, ", ") .. (off and ": switched off, to look over first." or "."), "success")
    end

    local function draw_import(ui, c)
        local S = c.share
        if not S then
            ui:text("Importing is not available: its module did not load (the log says why).", { color = "warning" })
            return
        end
        local job = S.job
        if not job then
            ui:text("Paste a link above and press Fetch (or Enter). It can be:", { size = "small", color = DIM })
            ui:indent(10)
            ui:text("- a repository: github.com/someone/their-reactions. It needs a folder called Reaction with .json files in it.",
                { size = "small", color = DIM })
            ui:text("- that folder: github.com/someone/their-reactions/tree/main/Reaction", { size = "small", color = DIM })
            ui:text("- one file: github.com/someone/their-reactions/blob/main/Reaction/panic.json", { size = "small", color = DIM })
            ui:unindent(10)
            ui:text("The repository must be public. You see what is in it before anything is saved, and what you import "
                .. "arrives switched off unless you say otherwise.", { size = "small", color = DIM })
        elseif job.busy then
            ui:text(job.status or "Reading...", { color = "info" })
        elseif job.err then
            ui:text(job.err, { color = "danger" })
        else
            ui:text(job.status or "", { color = "success" })
            for _, n in ipairs(job.notes) do ui:text(n, { size = "small", color = "warning" }) end
        end

        if job and not job.busy and #job.items > 0 then
            local picked, usable = 0, 0
            for _, it in ipairs(job.items) do
                if it.r and not it.imported then
                    usable = usable + 1
                    if it.pick then picked = picked + 1 end
                end
            end
            ui:spacer(2)
            ui:row({ 70, 70, 0 })
            if ui:button("imp_all", "All", { style = "ghost", disabled = usable == 0 or picked == usable }) then
                for _, it in ipairs(job.items) do if it.r and not it.imported then it.pick = true end end
            end
            if ui:button("imp_none", "None", { style = "ghost", disabled = picked == 0 }) then
                for _, it in ipairs(job.items) do it.pick = false end
            end
            ui:text(string.format("%d of %d picked. Click a reaction to pick it; hover it for its notes.", picked, usable),
                { size = "small", color = DIM })
            ui:end_row()
            for i, it in ipairs(job.items) do import_row(ui, c, it, i) end
            ui:spacer(4)
            local lib_lines, libs = 0, 0
            for _, l in ipairs(job.libraries) do
                if l.text and not l.added then
                    libs = libs + 1
                    lib_lines = lib_lines + select(2, l.text:gsub("\n", "")) + 1
                end
            end
            ui:row({ 0, 0 })
            put(ui, "imp_on", state.imp_on)
            local on, on_ch = ui:toggle("imp_on", "Switch them on now", state.imp_on,
                { tooltip = "Off: they arrive switched off, to look over under My reactions first" })
            if on_ch then state.imp_on = on end
            if libs > 0 then
                put(ui, "imp_lib", state.imp_lib)
                local lv, lch = ui:toggle("imp_lib", string.format("Add their Library to mine (%d lines)", lib_lines), state.imp_lib,
                    { tooltip = "The author's shared Lua (library.lua): appended to your Library, under a line saying where it came from" })
                if lch then state.imp_lib = lv end
            else
                ui:skip()
            end
            ui:end_row()
            -- Their Library can still be added after every reaction is in.
            local lib_only = picked == 0 and libs > 0 and state.imp_lib
            local label = picked > 0 and string.format("Import %d reaction%s", picked, picked == 1 and "" or "s")
                or (lib_only and "Add their Library to mine") or "Pick something to import"
            ui:row({ 0.45, 0 })
            if ui:button("imp_go", label, { style = "primary", disabled = picked == 0 and not lib_only }) then
                import_now(c, S)
            end
            ui:skip()
            ui:end_row()
        end

        ui:spacer(10)
        ui:separator("Share yours")
        ui:text(string.format("Export writes your %s reactions as files, one each, into scripts_data/%s (and your Library, "
            .. "when you have written one). Put that Reaction folder in a public GitHub repository: anyone can then import "
            .. "them with the repository's link.", class_label(c.class()), S.FOLDER), { size = "small", color = DIM })
        ui:row({ 0.45, 0 })
        if ui:button("exp_go", "Export my " .. class_label(c.class()) .. " reactions", { disabled = #c.list() == 0,
            tooltip = #c.list() == 0 and "You have no reactions of your own yet" or nil }) then
            local done, err = S.export_all()
            state.export_ok = done ~= nil
            state.export_result = done and string.format("Wrote %d file%s%s to %s.", done.count, done.count == 1 and "" or "s",
                done.library and " and your Library" or "", done.folder) or err
            toast(state.export_result, done and "success" or "error")
        end
        ui:skip()
        ui:end_row()
        if state.export_result then
            ui:text(state.export_result, { size = "small", color = state.export_ok and "success" or "warning" })
        end
        ui:spacer(4)
        if fold_header(ui, "fmt", "THE FILE FORMAT", "one reaction per .json file", API_COLOR, state.fmt_open, true) then
            state.fmt_open = not state.fmt_open
        end
        if state.fmt_open then
            ui:text("What Export writes, and Import reads: the fields the editor makes. \"class\" may be left out (it goes to "
                .. "the class of whoever imports it). A file may also hold several, as \"reactions\": [ ... ]. A subfolder "
                .. "named after a class (Reaction/Mage) gives its files that class; library.lua is the author's Library.",
                { size = "small", color = DIM })
            local sample = c.list()[1] or c.from_template(2)
            local text = S.encode(sample, c.class()) or ""
            local n = 1
            for _ in text:gmatch("\n") do n = n + 1 end
            put(ui, "fmt_code", text)
            ui:code("fmt_code", text, { rows = math.min(18, n), disabled = true })
        end
    end

    -- --- the window ----------------------------------------------------------------------------

    --- The view: its title bar and tools, the body that scrolls, and the
    --- editor's Save and Close under it.
    local function draw_main(ui, c, f)
        local tab = state.tab
        local r = tab == 3 and state.draft or nil
        top_bar(ui, c, f)
        if tab == 1 then defaults_tools(ui, c, f)
        elseif tab == 2 then mine_tools(ui, c)
        elseif tab == 3 and r then editor_tools(ui, r)
        elseif tab == 4 then library_tools(ui, c)
        elseif tab == 6 then import_tools(ui, c) end
        local _, _, _, left = ui:avail()
        local reserve = r and (FOOT_H + ui:metrics().gap) or 0
        local body_h = math.max(80, math.floor(left - reserve))
        -- Each view keeps its own place in the scroll; a step of the editor
        -- starts at the top for every reaction opened.
        local id = r and did("step" .. state.section) or ("v" .. tab)
        region(ui, id, body_h, function()
            if tab == 1 then draw_defaults(ui, c, f)
            elseif tab == 2 then draw_mine(ui, c)
            elseif tab == 3 then draw_editor(ui, c, f, body_h)
            elseif tab == 4 then draw_library(ui, c, body_h)
            elseif tab == 6 then draw_import(ui, c)
            else draw_live(ui, c) end
        end)
        if r then editor_footer(ui, c, r) end
    end

    local function body(ui, c)
        scope = ""
        if not c.class() then
            ui:text("Your class is not known yet: log in with a character, and this fills in.", { color = DIM })
            return
        end
        state.tab = math.max(1, math.min(VIEWS, math.floor(tonumber(state.tab) or 1)))
        state.section = math.max(1, math.min(STEPS, math.floor(tonumber(state.section) or 1)))
        if state.draft and state.draft_class ~= c.class() then state.draft = nil end
        if state.tab == 4 and state.lib_text == nil then state.lib_text = c.library() end
        -- What more than one pane reads, worked out once a frame.
        local f = { defaults = c.defaults() }
        if state.tab == 3 and state.draft then f.preview = c.preview(state.draft) end
        local _, _, _, left = ui:avail()
        local h = math.max(200, math.floor(left))
        ui:row({ NAV_W, 0 }, { gap = 10 })
        region(ui, "nav", h, function() draw_nav(ui, c, f, h) end)
        region(ui, "main", h, function() draw_main(ui, c, f) end)
        ui:end_row()
    end

    --- Keeps the window's size in step with the text size: once per change,
    --- it grows or shrinks by the same factor. A window saved before there was
    --- a text size was laid out at 100%; one that just opened at its default
    --- size already fits.
    local function fit_window(ui, win, zm, default_w)
        local was = tonumber(zdata.size_zoom)
        if not was then was = (math.abs((win.w or 0) - default_w) <= 2) and zm or 1.0 end
        if math.abs(was - zm) > 0.001 and ui.set_size and win.w and win.h then
            local k = zm / was
            ui:set_size(WINDOW_ID, math.floor(win.w * k + 0.5), math.floor(win.h * k + 0.5))
        end
        if zdata.size_zoom ~= zm then
            zdata.size_zoom = zm
            if zstore and zstore.touch then pcall(zstore.touch, zstore) end
        end
    end

    function M.render()
        state.shown = false
        if P.esp_only then return end
        local ui = ctx.ui
        -- ui:code is JCore 1.8.7 and ui:avail 1.8.9: on an older JCore the
        -- window stays shut.
        if not (ui and ui.begin_window and ui.code and ui.avail) then return end
        local c = C()
        if c then pcall(c.sync) end
        local sw, sh = 1920, 1080
        if P.draw and P.draw.screen_size then
            local w, h = P.draw.screen_size()
            if w and w > 0 and h and h > 0 then sw, sh = w, h end
        end
        -- The window's scale: JCore's UI scale times the text size. Its default
        -- and least sizes follow, so the layout has the room it was made for.
        local zm = zoom()
        local m0 = ui.metrics and ui:metrics() or nil
        local zw = ((m0 and m0.scale) or 1) * zm
        local w = math.min(math.floor(DEFAULT_W * zw + 0.5), sw - 40)
        local h = math.min(math.floor(DEFAULT_H * zw + 0.5), sh - 80)
        -- The least size follows the size the window was made for: on the
        -- frame the text size changes, fit_window scales it from what it was,
        -- not from what a new least size had already pushed it to.
        local zmin = ((m0 and m0.scale) or 1) * (tonumber(zdata.size_zoom) or zm)
        local title = "Reactions"
        local cls = c and c.class()
        if cls then title = "Reactions - " .. class_label(cls) end
        local ok, open, win = pcall(ui.begin_window, ui, WINDOW_ID, {
            title = title, x = math.floor((sw - w) / 2), y = math.max(30, math.floor((sh - h) / 2) - 30), w = w, h = h,
            min_w = math.min(math.floor(MIN_W * zmin), sw), min_h = math.min(math.floor(MIN_H * zmin), sh),
            resizable = true, movable = true, scroll = false, closable = true, collapsible = true, visible = false,
            scale = zm, bg = BG,
        })
        if ok and type(win) == "table" then fit_window(ui, win, zm, w) end
        if ok and open then
            state.shown = true
            if not c then
                ui:text("The reaction engine did not load, so there is nothing to show.", { color = "warning" })
            else
                Z = (ui.metrics and ui:metrics().scale) or 1
                local ok_body, err = pcall(body, units(ui), c)
                scope = ""
                if not ok_body then
                    state.err = tostring(err)
                    log.once("error", "reactions_window", "Reactions window failed: " .. tostring(err))
                end
            end
        end
        pcall(ui.end_window, ui)
    end

    --- Opens the window (the Reactions page's button).
    function M.open(tab)
        local ui = ctx.ui
        if tab then state.tab = tab end
        if ui and ui.show then pcall(ui.show, ui, WINDOW_ID) end
    end

    function M.close()
        local ui = ctx.ui
        if ui and ui.hide then pcall(ui.hide, ui, WINDOW_ID) end
    end

    function M.is_open()
        local ui = ctx.ui
        return ui and ui.is_visible and ui:is_visible(WINDOW_ID) or false
    end

    -- A file saved in an editor updates what the window holds: the
    -- Library's text, and the open draft's linked rows.
    do
        local c = C()
        if c then
            c.on_reload = function()
                if not state.lib_dirty then state.lib_text = nil end
                local d = state.draft
                local saved = d and d.id and c.get(d.id)
                if saved then
                    for _, pair in ipairs({ { d.conds, saved.conds }, { d.actions, saved.actions } }) do
                        for _, row in ipairs(pair[1]) do
                            for _, s in ipairs(pair[2]) do
                                if s.uid == row.uid and s.file then row.code = s.code end
                            end
                        end
                    end
                end
            end
        end
    end

    -- For the tests.
    M._open_draft = open_draft
    M.WINDOW_ID = WINDOW_ID

    return M
end

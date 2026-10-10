-- Jambix AIO / timeline -- the spell window: what was cast, what comes next.
--
-- A small window, beside the action bars by default, that reads left to
-- right as time: the spells used, the one being cast now with its progress,
-- then the next press the rotation will make (the large icon) and the few
-- after it. Every slot is the spell's own icon.
--
-- WHERE THE ANSWERS COME FROM
--   used  -- UNIT_SPELLCAST_SUCCEEDED for the player, or the core's spell
--            cast hook on a build that never delivers that event. Every cast
--            counts, by hand or by the plugin; a thin bar under each icon
--            says which (accent: the plugin pressed it).
--   now   -- the player's cast or channel, with its progress.
--   next  -- the rotation's projection (rotation.lua, "forecast"): every
--            rule asked against the tick's own snapshot and played forward.
--            With the rotation off or paused it is a suggestion, and the
--            title says so.
--
-- WHY THE BACKDROP HAS HOLES IN IT
-- The loader paints every texture into its background list, beneath every
-- shape, whatever order they were submitted in (README, "Textures paint
-- beneath every 2D shape"). A panel drawn behind the icons would be drawn
-- OVER them. So the backdrop is cut around each icon slot: the body is
-- filled band by band and every slot is left empty for its texture. What
-- sits on an icon on purpose -- its frame, the cooldown dim, the countdown
-- -- is meant to be on top.
--
-- WHY THE TITLE BAR IS A JCORE WINDOW
-- Dragging needs the mouse taken from the game while the cursor is over the
-- handle, or the drag also swings the camera. JCore's overlay UI does that
-- and remembers where a window was left, but a window's body is a solid fill
-- that would hide the icons for the reason above. So the JCore window is
-- ONLY the title bar -- drag it, double-click it to fold the window away --
-- and the body is painted here, directly under it, through the draw queue.
-- Where the overlay UI is missing or switched off the bar is drawn here as
-- well and the window stays where it last was.

return function(P)
    local ctx = P.ctx
    local draw = P.draw

    local M = {}

    local floor, max, min = math.floor, math.max, math.min

    local function clamp(v, lo, hi)
        v = tonumber(v) or lo
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    -- --- what was cast -------------------------------------------------------

    local HISTORY_MAX = 16
    local DUPLICATE_WINDOW = 0.3   -- one cast reported twice
    local PRESS_WINDOW = 2.0       -- sent this recently, plus the cast time: ours

    -- Auto attacks and auto-repeat shots report a cast on every swing. They
    -- are a running state rather than a decision, and they would push every
    -- real press out of the row inside a minute.
    local AUTO_IDS = {
        [75] = true,     -- Auto Shot
        [5019] = true,   -- Shoot (wand)
        [6603] = true,   -- Attack
        [2480] = true,   -- Shoot Bow
        [7918] = true,   -- Shoot Gun
        [7919] = true,   -- Shoot Crossbow
        [2764] = true,   -- Throw
        [3018] = true,   -- Shoot
    }
    local AUTO_NAMES = {
        ["auto shot"] = true, ["shoot"] = true, ["attack"] = true, ["auto attack"] = true,
        ["shoot bow"] = true, ["shoot gun"] = true, ["shoot crossbow"] = true, ["throw"] = true,
    }

    local history = {}          -- oldest first: { id, name, at, ours }
    local sent = {}             -- spell id -> when this plugin last sent it
    local succeeded_seen = false
    local last_id, last_at = nil, -math.huge

    local function spell_name(id)
        local spells = ctx.spells
        if not spells or not spells.name then return "" end
        local ok, name = pcall(spells.name, id)
        return (ok and type(name) == "string") and name or ""
    end

    local function cast_time(id)
        local spells = ctx.spells
        if not spells or not spells.info then return 0 end
        local ok, info = pcall(spells.info, id)
        return (ok and type(info) == "table" and tonumber(info.cast_time)) or 0
    end

    local function is_auto(id, name)
        return AUTO_IDS[id] == true or AUTO_NAMES[name:lower()] == true
    end

    --- Records one cast by the player.
    ---@param spell_id integer
    function M.record(spell_id)
        if type(spell_id) ~= "number" or spell_id <= 0 then return end
        local now = core.time()
        if spell_id == last_id and (now - last_at) < DUPLICATE_WINDOW then return end

        local name = spell_name(spell_id)
        if name == "" then return end
        if is_auto(spell_id, name) and not P.opt("rot_hud_autos", false) then return end

        local at = sent[spell_id]
        local ours = at ~= nil and (now - at) <= PRESS_WINDOW + cast_time(spell_id)
        -- A weapon proc or an item's effect reports a cast as well. Only what
        -- this character has in its spellbook, or what the plugin pressed.
        local book = P.spellbook
        if not ours and book and book.known and not book.known(name) then return end

        last_id, last_at = spell_id, now
        history[#history + 1] = { id = spell_id, name = name, at = now, ours = ours }
        if #history > HISTORY_MAX then table.remove(history, 1) end
    end

    --- Recorded casts, oldest first.
    function M.history()
        return history
    end

    ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
        if type(args) ~= "table" or args[1] ~= "player" then return end
        local id = args[3]
        if type(id) ~= "number" then return end
        succeeded_seen = true
        M.record(id)
    end)

    -- The fallback, for a build whose event never carries the id where the
    -- rotation expects it (its argument order is on the unverified list).
    -- Dropped for good once the event has answered once, so the two sources
    -- never both record the same cast.
    ctx.on("jcore.spell.cast", function(data)
        if succeeded_seen or type(data) ~= "table" or type(data.spell_id) ~= "number" then return end
        local player = P.units.player()
        local caster = data.caster
        if not player or type(caster) ~= "table" and type(caster) ~= "userdata" then return end
        local ok, guid = pcall(caster.get_guid, caster)
        if not ok or guid == nil or guid ~= player:get_guid() then return end
        M.record(data.spell_id)
    end)

    ctx.on("jcore.cast.sent", function(request)
        if type(request) ~= "table" or type(request.spell_id) ~= "number" then return end
        if ctx.id and request.owner ~= ctx.id then return end
        sent[request.spell_id] = core.time()
    end)

    -- --- what is being cast ------------------------------------------------

    local cast_track = nil
    local wait_track = nil       -- the next spell's wait when it first came up (1.89.0)

    --- The player's cast or channel in flight: id, progress 0..1, seconds left.
    local function in_flight()
        local player = ctx.player
        if not player or not player.casting_spell_id then return nil end
        local ok, id = pcall(player.casting_spell_id)
        if not ok or type(id) ~= "number" or id <= 0 then
            cast_track = nil
            return nil
        end
        local ok_left, left = pcall(player.cast_remaining)
        left = (ok_left and type(left) == "number") and left or 0
        -- Past any real cast is a broken read, the same bound the cast gate uses.
        if left <= 0 or left > 30 then
            cast_track = nil
            return nil
        end
        if not cast_track or cast_track.id ~= id or left > cast_track.total + 0.05 then
            -- A channel reports no cast time; the first reading is its length.
            cast_track = { id = id, total = max(left, cast_time(id), 0.1) }
        end
        return id, clamp(1 - left / cast_track.total, 0, 1), left
    end

    -- --- painting -------------------------------------------------------------

    --- Fills a rectangle except where the holes are. Every hole edge cuts the
    --- rectangle into horizontal bands, and each band is filled between the
    --- holes crossing it. Edges are whole pixels, so neighbouring pieces
    --- neither overlap (a darker seam) nor leave a gap (a lighter one).
    ---@param holes { x: number, y: number, w: number, h: number }[]
    ---@return integer pieces
    local function fill_around(x, y, w, h, holes, col, layer)
        local edges = { y, y + h }
        for i = 1, #holes do
            local r = holes[i]
            edges[#edges + 1] = max(y, min(y + h, r.y))
            edges[#edges + 1] = max(y, min(y + h, r.y + r.h))
        end
        table.sort(edges)

        local pieces = 0
        local function piece(px, py, pw, ph)
            draw.rect_2d({ x = px, y = py }, pw, ph, col, { filled = true, layer = layer })
            pieces = pieces + 1
        end

        for e = 1, #edges - 1 do
            local y1, y2 = edges[e], edges[e + 1]
            if y2 > y1 then
                local spans = {}
                for i = 1, #holes do
                    local r = holes[i]
                    if r.y < y2 and r.y + r.h > y1 then spans[#spans + 1] = r end
                end
                table.sort(spans, function(a, b) return a.x < b.x end)
                local cx = x
                for i = 1, #spans do
                    local r = spans[i]
                    local hx = max(x, r.x)
                    if hx > cx then piece(cx, y1, hx - cx, y2 - y1) end
                    cx = max(cx, min(x + w, r.x + r.w))
                end
                if x + w > cx then piece(cx, y1, x + w - cx, y2 - y1) end
            end
        end
        return pieces
    end
    M._fill_around = fill_around

    --- Two letters for a spell with no art yet: "Arcane Shot" -> "AS".
    local function initials(name)
        local out = {}
        for word in name:gmatch("%a+") do
            out[#out + 1] = word:sub(1, 1):upper()
            if #out == 2 then break end
        end
        return table.concat(out)
    end

    --- Cut to fit, with an ellipsis.
    local function fit(text, size, width)
        local measure = draw.measure
        if not measure then return text end
        if measure(text, size) <= width then return text end
        for n = #text - 1, 1, -1 do
            local cut = text:sub(1, n) .. ".."
            if measure(cut, size) <= width then return cut end
        end
        return ""
    end

    -- Colours. The overlay UI's palette when it is there, so the window
    -- looks like the rest of JCore's; the draw theme otherwise. Read again
    -- every few seconds, so a theme change is followed.
    local pal, pal_at = nil, -math.huge
    local tints = {}

    local function palette(now)
        if pal and (now - pal_at) < 5 then return pal end
        pal_at = now
        local UI = P.JCore and P.JCore.ui
        local t = (UI and UI.theme) or {}
        local d = draw.theme or {}
        local color = P.color
        pal = {
            bg       = t.bg or d.backdrop,
            title    = t.bg_title or d.backdrop,
            border   = t.border or d.outline,
            text     = t.text or d.text,
            text_dim = t.text_dim or d.text_dim,
            accent   = t.accent or d.accent,
            warning  = t.warning or d.warning,
            track    = t.track or d.outline,
            hand     = t.text_disabled or d.text_dim,
            tile     = t.bg_elevated or d.backdrop,
            empty    = color and color(12, 13, 16, 236) or d.backdrop,
            dim      = color and color(0, 0, 0, 150) or d.outline,
        }
        return pal
    end

    --- An opaque grey tint, cached per step so a fading row allocates
    --- nothing. Darker, not more transparent: an icon slot has no backdrop
    --- behind it, so a translucent icon would show the ground through it.
    local function shade(level)
        level = floor(level / 8) * 8
        local hit = tints[level]
        if not hit and P.color then
            hit = P.color(level, level, level, 255)
            tints[level] = hit
        end
        return hit
    end

    --- One icon slot. Returns true when the spell's own art painted.
    ---@param level integer 255 for full brightness, lower for an older spell
    local function slot(r, spell_id, name, level, colors, layer)
        local painted = false
        if spell_id then
            painted = draw.image("spell:" .. spell_id, { x = r.x, y = r.y }, r.w, r.h,
                level < 255 and shade(level) or nil, { layer = layer }) == true
        end
        if not painted then
            -- No art yet, or none to show: the hole is filled so the window
            -- never shows a gap, and the spell is named by its initials.
            draw.rect_2d({ x = r.x, y = r.y }, r.w, r.h, spell_id and colors.tile or colors.empty,
                { filled = true, layer = layer })
            if spell_id and name then
                local size = max(9, floor(r.h * 0.38))
                draw.text_2d({ x = r.x + r.w / 2, y = r.y + r.h / 2 - size / 2 - 1 },
                    initials(name), colors.text_dim, { layer = layer, size = size, centered = true })
            end
        end
        return painted
    end

    local function frame(r, col, thickness, layer)
        draw.rect_2d({ x = r.x, y = r.y }, r.w, r.h, col,
            { filled = false, thickness = thickness or 1, layer = layer })
    end

    -- --- the window -----------------------------------------------------------

    local WINDOW_ID = "spell_timeline"
    local FALLBACK_BAR = 22
    local STALE_AFTER = 1.0        -- a projection older than this is not shown

    -- Decided by the last paint: the projection is only worked out while
    -- there is a window to show it in.
    local shown = false
    local shown_next = 0

    --- How many upcoming spells the rotation should project, 0 for none.
    ---@return integer
    function M.wants_forecast()
        return shown and shown_next or 0
    end

    local function rotation_status()
        if not P.opt("rot_enabled", false) then return "off" end
        if P.rotation_active and not P.rotation_active() then return "paused" end
        return nil
    end

    --- The title bar. A JCore window when the overlay UI is there, so it
    --- drags and is remembered; drawn here otherwise. Returns the window's
    --- top-left and the bar's height, or nil when the window is folded away.
    local function title_bar(title, width, x, y, colors, layer)
        local UI = P.JCore and P.JCore.ui
        local ui = ctx.ui
        if ui and ui.begin_window and UI and type(UI.theme) == "table" then
            local theme = UI.theme
            local bar = floor((theme.title_h or 24) * (theme.scale or 1) + 0.5)
            local ok, open, win = pcall(ui.begin_window, ui, WINDOW_ID, {
                title = title, x = x, y = y, w = width, h = bar, min_w = width,
                collapsible = true, closable = false, scroll = false, padding = 0,
            })
            -- ALWAYS paired, whatever begin answered.
            pcall(ui.end_window, ui)
            if ok and type(win) == "table" then
                if win.collapsed or win.visible == false then return nil end
                if open then return win.x, win.y, bar end
                -- The overlay UI is switched off: where it was, our own bar.
                x, y = win.x or x, win.y or y
            end
        end
        draw.rect_2d({ x = x, y = y }, width, FALLBACK_BAR, colors.title, { filled = true, layer = layer })
        draw.text_2d({ x = x + 10, y = y + 4 }, fit(title, 13, width - 20), colors.text,
            { layer = layer, size = 13 })
        return x, y, FALLBACK_BAR
    end

    function M.render()
        shown = false
        if not P.opt("rot_hud_enabled", true) then return end
        if P.master_on and not P.master_on() then return end
        if not P.units.player() then return end

        local now = core.time()
        if P.opt("rot_hud_combat_only", false) then
            local combat = P.combat
            local busy = (combat and combat.in_combat and combat.in_combat())
                or (combat and combat.target and combat.target() ~= nil)
                or (#history > 0 and (now - history[#history].at) < 8)
            if not busy then return end
        end

        local sw, sh = draw.screen_size()
        if not sw or sw <= 0 or not sh or sh <= 0 then return end

        local layer = ctx.LAYER and ctx.LAYER.HUD or 500
        local colors = palette(now)

        -- --- geometry ---------------------------------------------------------
        local size = floor(clamp(P.opt("rot_hud_size", 40), 20, 64))
        local big = floor(size * 1.3 + 0.5)
        local n_hist = floor(clamp(P.opt("rot_hud_history", 6), 0, 12))
        local n_next = floor(clamp(P.opt("rot_hud_next", 3), 1, 6))
        local gap, pad = 4, 8
        local label_size = max(10, floor(size * 0.3))
        local foot_size = max(9, floor(size * 0.27))
        local label_h = label_size + 6
        local foot_h = foot_size + 6

        local hist_w = n_hist > 0 and (n_hist * (size + gap) - gap) or 0
        local sep_w = n_hist > 0 and 18 or 0
        local next_w = big + (n_next - 1) * (size + gap)
        local width = max(pad + hist_w + sep_w + next_w + pad, 170)
        local body_h = 5 + label_h + big + 4 + foot_h

        -- Default spot: right of centre, just above the action bars.
        local default_x = floor(sw * 0.715 - width / 2)
        local default_y = floor(sh * 0.735 - (body_h + 24) / 2)

        -- --- what to show ------------------------------------------------------
        local status = rotation_status()
        local suggesting = status ~= nil and P.opt("rot_hud_suggest", true)
        local proj = P.rotation and P.rotation.projection and P.rotation.projection() or nil
        local rows = (proj and (now - proj.at) <= STALE_AFTER) and proj.rows or {}
        if status and not suggesting then rows = {} end

        local title = "Rotation"
        if proj and proj.label then title = title .. "  -  " .. proj.label end
        if status then title = title .. "  (" .. status .. (suggesting and ", suggesting" or "") .. ")" end

        local x, y, bar = title_bar(title, width, default_x, default_y, colors, layer)
        if not x then return end
        x, y = floor(x), floor(y)
        shown, shown_next = true, n_next

        local y0 = y + bar
        local row_y = y0 + 5 + label_h
        local sy = row_y + floor((big - size) / 2)

        -- Slots, left to right.
        local hist_slots = {}
        for i = 1, n_hist do
            hist_slots[i] = { x = x + pad + (i - 1) * (size + gap), y = sy, w = size, h = size }
        end
        local next_x = x + pad + hist_w + sep_w
        local next_slots = { { x = next_x, y = row_y, w = big, h = big } }
        for j = 2, n_next do
            next_slots[j] = { x = next_x + big + gap + (j - 2) * (size + gap), y = sy, w = size, h = size }
        end

        local holes = {}
        for i = 1, #hist_slots do holes[#holes + 1] = hist_slots[i] end
        for j = 1, #next_slots do holes[#holes + 1] = next_slots[j] end

        -- --- backdrop, cut around every slot --------------------------------
        fill_around(x, y0, width, body_h, holes, colors.bg, layer)
        draw.rect_2d({ x = x, y = y0 }, width, body_h, colors.border,
            { filled = false, thickness = 1, layer = layer })

        -- --- used, and in flight ---------------------------------------------
        if n_hist > 0 then
            draw.text_2d({ x = x + pad, y = y0 + 5 }, "USED", colors.text_dim,
                { layer = layer, size = label_size })

            local cast_id, progress = in_flight()
            if cast_id and is_auto(cast_id, spell_name(cast_id)) and not P.opt("rot_hud_autos", false) then
                cast_id = nil
            end

            -- The newest sits next to the separator; the row fills leftwards.
            local filled = cast_id and (n_hist - 1) or n_hist
            for i = 1, n_hist do
                local r = hist_slots[i]
                local k = #history - filled + i
                local entry = (i <= filled) and k >= 1 and history[k] or nil
                if i <= filled then
                    -- Older is darker.
                    local level = floor(110 + 145 * (i / max(1, filled)))
                    slot(r, entry and entry.id, entry and entry.name, level, colors, layer)
                    frame(r, colors.border, 1, layer)
                    if entry then
                        draw.rect_2d({ x = r.x + 2, y = r.y + r.h + 2 }, r.w - 4, 2,
                            entry.ours and colors.accent or colors.hand, { filled = true, layer = layer })
                    end
                else
                    -- The cast in flight, with its progress under it.
                    slot(r, cast_id, spell_name(cast_id), 255, colors, layer)
                    frame(r, colors.warning, 1, layer)
                    if draw.bar_2d then
                        -- JCore 1.15's bar (1.89.0): a rounded rail, the fill shaded.
                        draw.bar_2d({ x = r.x, y = r.y + r.h + 2 }, r.w, 3, clamp(progress, 0, 1), colors.warning,
                            { bg = colors.track, layer = layer })
                    else
                        draw.rect_2d({ x = r.x, y = r.y + r.h + 2 }, r.w, 3, colors.track,
                            { filled = true, layer = layer })
                        draw.rect_2d({ x = r.x, y = r.y + r.h + 2 }, max(1, floor(r.w * progress)), 3,
                            colors.warning, { filled = true, layer = layer })
                    end
                end
            end

            -- Separator: a rule and a chevron pointing at what comes next.
            local sx = x + pad + hist_w + floor(sep_w / 2)
            draw.line_2d({ x = sx, y = row_y + 2 }, { x = sx, y = row_y + big - 2 }, colors.border,
                { layer = layer, thickness = 1 })
            draw.arrow_2d({ x = sx, y = row_y + big / 2 }, math.pi / 2, 5, colors.text_dim, { layer = layer })
        end

        -- --- next ------------------------------------------------------------
        local first_row = rows[1]
        local label_x = next_x
        draw.text_2d({ x = label_x, y = y0 + 5 }, "NEXT", colors.text_dim,
            { layer = layer, size = label_size })
        if first_row then
            local lw = draw.measure and draw.measure("NEXT", label_size) or label_size * 2.4
            draw.text_2d({ x = label_x + lw + 6, y = y0 + 5 },
                fit(first_row.name, label_size, x + width - pad - (label_x + lw + 6)),
                colors.text, { layer = layer, size = label_size })
        end

        local elapsed = proj and (now - proj.at) or 0
        local ring_2d = draw.ring_2d
        for j = 1, n_next do
            local r = next_slots[j]
            local row = rows[j]
            slot(r, row and row.id, row and row.name, 255, colors, layer)

            local wait = row and (row.at - elapsed) or 0
            if row and wait > 0.15 then
                local text = string.format(wait >= 10 and "%.0f" or "%.1f", wait)
                if j == 1 then
                    -- Dimmed with the seconds on it: this is not pressable yet.
                    draw.rect_2d({ x = r.x, y = r.y }, r.w, r.h, colors.dim, { filled = true, layer = layer })
                    -- A sweep round it filling as the wait runs down (1.89.0, JCore
                    -- 1.15's ring_2d): its length is the wait when this spell first
                    -- came up next.
                    if ring_2d then
                        if not wait_track or wait_track.id ~= row.id or wait > wait_track.total + 0.2 then
                            wait_track = { id = row.id, total = wait }
                        end
                        local done = wait_track.total > 0 and clamp(1 - wait / wait_track.total, 0, 1) or 0
                        ring_2d({ x = r.x + r.w / 2, y = r.y + r.h / 2 }, r.w * 0.46, done, colors.accent,
                            { bg = colors.dim, inner = 0.84, outer = 0.98, layer = layer })
                    end
                    local ts = max(11, floor(r.h * 0.36))
                    draw.text_2d({ x = r.x + r.w / 2, y = r.y + r.h / 2 - ts / 2 - 1 }, text,
                        colors.text, { layer = layer, size = ts, centered = true, shadow = true })
                else
                    draw.text_2d({ x = r.x + r.w / 2, y = row_y + big + 3 }, "+" .. text,
                        colors.text_dim, { layer = layer, size = foot_size, centered = true })
                end
            end

            -- The frame last, so the dim above never darkens it.
            local edge = (j == 1) and colors.accent or colors.border
            if row and row.fast then edge = colors.warning end   -- off the global cooldown
            frame(r, edge, j == 1 and 2 or 1, layer)
        end
    end

    --- For the Rotation page and the tests.
    function M.stats()
        local proj = P.rotation and P.rotation.projection and P.rotation.projection() or nil
        local names = {}
        for i = 1, #((proj and proj.rows) or {}) do names[#names + 1] = proj.rows[i].name end
        return {
            shown = shown,
            used = #history,
            last = history[#history] and history[#history].name or nil,
            next = names,
            source = succeeded_seen and "succeeded" or "cast hook",
        }
    end

    return M
end

-- Jambix AIO / esp/card -- the icon card: one painter for every ESP mark.
--
-- A mark is a small stack of ROWS, built top down and then laid out as one
-- block:
--
--     [wolf] Dark Iron Looter          head: icons, then the name (no pill)
--            ▬▬▬▬▬▬▬░░░                 bar: health, only when hurt
--     [dragon][sword] ( 15 · 42y )     pill: icons beside ONE pill of text
--     [kill] ( 2/8 · Kill the Looters )
--     [frostbolt] ( Frostbolt 1.2 )    a pill with a thin bar under it
--
-- EACH ROW IS ICONS, THEN TEXT. An icon never sits on a pill: the loader
-- paints every texture beneath every shape, so an icon on a backdrop would
-- vanish under it. Icons go to the left of the row's pill, and the pill holds
-- only text, in as many coloured segments as the row needs (a level in its
-- band's colour, then the rest).
--
-- WHO DECIDES WHAT. The caller says what a row holds; the card measures,
-- finds room (a block that would land on one already placed this frame moves
-- down a little, and when there is no room it prints anyway -- a mark that
-- vanished was the bug the Forever ESP was built to fix), and paints. It
-- reads nothing from the game.
--
-- An icon that has not loaded is left out of the layout rather than leaving
-- a gap (ready(ref)); the caller decides whether a word stands in for it.
--
-- Scratch tables throughout: a card per mark per frame must not be a table
-- per mark per frame.
--
-- SOFT CARDS AND BARS (1.88.0). The user, 2026-10-08: "Take all ESPs and
-- convert it to this!", choosing "Cards and bars". With the ESP page's "Soft
-- cards and bars" on (esp_shader_look, the default; the caller passes it to
-- begin_frame) and JCore's plate_2d and bar_2d there, a pill's backdrop is a
-- plate with soft edges, its outline the plate's border, and every bar -- the
-- health bar, the game's bar texture included, and a cast's under its pill --
-- a rounded rail whose fill shades a quarter of the way to white at its end.
-- The plates have no shadow: a shadow reaches past its plate, onto the icons
-- beside and below it, and a texture paints under a shape. Off, or on a JCore
-- without those calls, everything is drawn as before.

return function(P)
    local draw = P.draw
    local assets = P.JCore and P.JCore.assets

    local M = {}

    -- --- look ------------------------------------------------------------------

    local PAD_X, PAD_Y = 5, 2
    local ROW_GAP = 2
    local ICON_GAP = 3
    local ROUND = 3
    local SHIFT_ROWS = 4         -- how far a block moves down to find room
    local UNDER_FEET = 6         -- px between the feet and the first row
    local UNDER_BAR = 3          -- the bar under a pill (a cast's progress)

    local col = {
        back = P.color(12, 12, 16, 215),
        bar_back = P.color(0, 0, 0, 185),
        bar_backing = P.color(22, 22, 26, 235),
        outline = P.color(0, 0, 0, 210),
    }
    M.col = col

    -- The soft look this frame (begin_frame), and each bar colour's lighter
    -- end, made once per colour.
    local soft = true
    local WHITE = P.color(255, 255, 255, 255)
    local lighter_of = setmetatable({}, { __mode = "k" })

    --- A bar colour a quarter of the way to white: where its fill ends.
    local function lighter(c)
        if c == nil or not draw.blend then return nil end
        local l = lighter_of[c]
        if not l then
            l = draw.blend(c, WHITE, 0.25)
            lighter_of[c] = l
        end
        return l
    end

    -- --- text width ----------------------------------------------------------
    --
    -- Each glyph measured once per size for the session; a string is the sum
    -- of its glyphs. No native call per string per frame.

    local glyph_w = {}
    local GLYPH = "[\1-\127\194-\244][\128-\191]*"

    local function text_width(text, size)
        local cache = glyph_w[size]
        if not cache then
            cache = {}
            glyph_w[size] = cache
        end
        local width = 0
        for ch in text:gmatch(GLYPH) do
            local g = cache[ch]
            if not g then
                g = (draw.measure and draw.measure(ch, size)) or size * 0.5
                cache[ch] = g
            end
            width = width + g
        end
        return width
    end
    M.text_width = text_width

    --- Can this asset paint now? Queues it the first time.
    local function ready(ref)
        if not ref or not assets or not assets.request then return false end
        local ok, yes = pcall(assets.request, ref)
        return ok and yes == true
    end
    M.ready = ready

    -- --- the card being built -----------------------------------------------------

    local card = { size = 13, icon = 18, layer = 300, droppable = false }
    local rows, row_n = {}, 0
    local cur = nil

    local function new_row(kind)
        row_n = row_n + 1
        local r = rows[row_n]
        if not r then
            r = { icons = {}, tints = {}, uvs = {}, texts = {}, cols = {} }
            rows[row_n] = r
        end
        r.kind = kind
        r.n_icons, r.n_texts = 0, 0
        r.border, r.fraction, r.bar_col, r.under_col = nil, nil, nil, nil
        r.bar_w, r.bar_h, r.bar_ref, r.bar_uv = nil, nil, nil, nil
        r.w, r.h, r.text_w = 0, 0, 0
        cur = r
        return r
    end

    --- Begins a card.
    ---@param size number text size
    ---@param layer number
    ---@param opts? { icon?: number, droppable?: boolean }
    function M.start(size, layer, opts)
        card.size = size
        card.icon = (opts and opts.icon) or (size + 5)
        card.layer = layer
        card.droppable = opts and opts.droppable or false
        row_n = 0
        cur = nil
    end

    --- The name row: icons, then plain text (no pill).
    function M.head() new_row("head") end

    --- An information row: icons, then one pill of text.
    ---@param border? table outline colour, when the colour is the answer
    function M.pill(border)
        new_row("pill").border = border
    end

    --- An icon on the current row, when it can paint now.
    ---@param ref string|nil
    ---@param tint? table
    ---@param uv? number[]
    ---@return boolean added
    function M.icon(ref, tint, uv)
        if not cur or not ready(ref) then return false end
        local n = cur.n_icons + 1
        cur.n_icons = n
        cur.icons[n], cur.tints[n], cur.uvs[n] = ref, tint or false, uv or false
        return true
    end

    --- A text segment on the current row.
    ---@param text string|nil
    ---@param color table
    function M.text(text, color)
        if not cur or not text or text == "" then return end
        local n = cur.n_texts + 1
        cur.n_texts = n
        cur.texts[n], cur.cols[n] = text, color
    end

    --- A bar of its own: health under the name.
    ---@param fraction number 0..1
    ---@param color table
    ---@param width number
    ---@param height number
    ---@param ref? string the status-bar texture (an atlas cell), when it paints
    ---@param uv? number[] that cell's u0, v0, u1, v1
    function M.bar(fraction, color, width, height, ref, uv)
        local r = new_row("bar")
        r.fraction = math.max(0, math.min(1, fraction or 0))
        r.bar_col, r.bar_w, r.bar_h = color, width, height
        if ref and uv and ready(ref) then r.bar_ref, r.bar_uv = ref, uv end
        cur = nil
    end

    --- A thin bar under the current pill, as wide as it: a cast's progress.
    function M.under(fraction, color)
        if not cur or cur.kind ~= "pill" or not fraction then return end
        cur.fraction = math.max(0, math.min(1, fraction))
        cur.under_col = color
    end

    -- --- layout ------------------------------------------------------------------

    local function pill_h() return card.size + PAD_Y * 2 end

    local function measure(r)
        local size, icon = card.size, card.icon
        if r.kind == "bar" then
            r.w, r.h = r.bar_w, r.bar_h
            return
        end
        local tw = 0
        for i = 1, r.n_texts do tw = tw + text_width(r.texts[i], size) end
        r.text_w = tw
        local w = r.n_icons * (icon + ICON_GAP)
        local h
        if r.kind == "pill" then
            if r.n_texts > 0 then w = w + tw + PAD_X * 2 else w = w - ICON_GAP end
            h = math.max(r.n_texts > 0 and pill_h() or 0, r.n_icons > 0 and icon or 0)
            if r.fraction and r.n_texts > 0 then h = h + UNDER_BAR + 1 end
        else
            if r.n_texts > 0 then w = w + tw else w = w - ICON_GAP end
            h = math.max(r.n_texts > 0 and size or 0, r.n_icons > 0 and icon or 0)
        end
        r.w, r.h = math.max(0, w), h
    end

    --- Is there anything to draw?
    function M.empty()
        for i = 1, row_n do
            local r = rows[i]
            if r.kind == "bar" or r.n_icons > 0 or r.n_texts > 0 then return false end
        end
        return true
    end

    -- Rectangles claimed this frame, for "does this block land on another".
    local px0, py0, px1, py1 = {}, {}, {}, {}
    local placed_n = 0

    local function overlaps(x0, y0, x1, y1)
        local lowest = nil
        for i = 1, placed_n do
            if x0 < px1[i] and x1 > px0[i] and y0 < py1[i] and y1 > py0[i] then
                if not lowest or py1[i] > lowest then lowest = py1[i] end
            end
        end
        return lowest
    end

    local function claim(x0, y0, x1, y1)
        placed_n = placed_n + 1
        px0[placed_n], py0[placed_n], px1[placed_n], py1[placed_n] = x0, y0, x1, y1
    end

    local stats = { cards = 0, crowded = 0, rows = 0 }

    --- A new frame. `soft = false` paints this frame's cards flat (1.88.0).
    ---@param opts? { soft?: boolean }
    function M.begin_frame(opts)
        placed_n = 0
        stats.cards, stats.crowded, stats.rows = 0, 0, 0
        soft = not (opts and opts.soft == false)
    end

    function M.stats() return stats end

    -- --- painting ---------------------------------------------------------------

    local function paint_icons(r, x, top)
        local icon, layer = card.icon, card.layer
        local y = top + (r.h - icon) * 0.5
        if r.kind == "pill" and r.fraction and r.n_texts > 0 then
            y = top + (pill_h() - icon) * 0.5
        end
        for i = 1, r.n_icons do
            local uv = r.uvs[i]
            draw.image(r.icons[i], { x = x, y = y }, icon, icon, r.tints[i] or nil,
                { layer = layer, droppable = card.droppable, uv = uv or nil })
            x = x + icon + ICON_GAP
        end
        return x
    end

    local function paint_texts(r, x, y)
        local size, layer = card.size, card.layer
        for i = 1, r.n_texts do
            local text = r.texts[i]
            local w = text_width(text, size)
            draw.text_2d({ x = x + w * 0.5, y = y }, text, r.cols[i],
                { size = size, centered = true, shadow = true, layer = layer, droppable = card.droppable })
            x = x + w
        end
    end

    local function paint_bar(r, cx, top)
        local w, h, layer = r.bar_w, r.bar_h, card.layer
        local x = cx - w * 0.5
        if soft and draw.bar_2d then
            -- 1.88.0: a rounded rail, the fill shading lighter to its end.
            draw.bar_2d({ x = x, y = top }, w, h, r.fraction, r.bar_col,
                { to = lighter(r.bar_col), bg = col.bar_back, layer = layer, droppable = card.droppable })
            return
        end
        if r.bar_ref then
            -- The game's own bar texture: a dark backing, then the fill CUT
            -- (not squeezed) the way the game's bars empty, then an outline.
            -- The backing is a texture too: a filled rectangle would paint
            -- over the fill.
            local uv = r.bar_uv
            draw.image(r.bar_ref, { x = x, y = top }, w, h, col.bar_backing,
                { layer = layer, droppable = card.droppable, uv = uv })
            if r.fraction > 0 then
                draw.image(r.bar_ref, { x = x, y = top }, w * r.fraction, h, r.bar_col,
                    { layer = layer, droppable = card.droppable,
                      uv = { uv[1], uv[2], uv[1] + (uv[3] - uv[1]) * r.fraction, uv[4] } })
            end
            draw.rect_2d({ x = x, y = top }, w, h, col.outline, { thickness = 1.0, layer = layer, droppable = card.droppable })
            return
        end
        draw.rect_2d({ x = x, y = top }, w, h, col.bar_back, { filled = true, layer = layer, droppable = card.droppable })
        if r.fraction > 0 then
            draw.rect_2d({ x = x, y = top }, w * r.fraction, h, r.bar_col,
                { filled = true, layer = layer, droppable = card.droppable })
        end
    end

    local function paint_row(r, cx, top)
        if r.kind == "bar" then return paint_bar(r, cx, top) end
        local size, layer = card.size, card.layer
        local x = cx - r.w * 0.5
        if r.kind == "head" then
            x = paint_icons(r, x, top)
            paint_texts(r, x, top + (r.h - size) * 0.5)
            return
        end
        x = paint_icons(r, x, top)
        if r.n_texts == 0 then return end
        local ph = pill_h()
        local pw = r.text_w + PAD_X * 2
        local py = top
        if not r.fraction then py = top + (r.h - ph) * 0.5 end
        if soft and draw.plate_2d then
            -- 1.88.0: a soft-edged plate, its outline the plate's border; no
            -- shadow (see SOFT CARDS AND BARS).
            draw.plate_2d({ x = x, y = py }, pw, ph, col.back,
                { rounding = ROUND, border = r.border, shadow = false, layer = layer, droppable = card.droppable })
        else
            draw.rect_2d({ x = x, y = py }, pw, ph, col.back,
                { filled = true, rounding = ROUND, layer = layer, droppable = card.droppable })
            if r.border then
                draw.rect_2d({ x = x, y = py }, pw, ph, r.border,
                    { thickness = 1.2, rounding = ROUND, layer = layer, droppable = card.droppable })
            end
        end
        paint_texts(r, x + PAD_X, py + PAD_Y)
        if r.fraction then
            local by = py + ph + 1
            local fill = r.under_col or r.border or col.back
            if soft and draw.bar_2d then
                draw.bar_2d({ x = x, y = by }, pw, UNDER_BAR, r.fraction, fill,
                    { to = lighter(fill), bg = col.bar_back, layer = layer, droppable = card.droppable })
                return
            end
            draw.rect_2d({ x = x, y = by }, pw, UNDER_BAR, col.bar_back,
                { filled = true, layer = layer, droppable = card.droppable })
            if r.fraction > 0 then
                draw.rect_2d({ x = x, y = by }, pw * r.fraction, UNDER_BAR, fill,
                    { filled = true, layer = layer, droppable = card.droppable })
            end
        end
    end

    --- Lays the card out at a screen point and paints it.
    ---
    --- Under the point by default (a unit's feet); `above` hangs it over the
    --- point instead (a place on the ground). `claim = false` paints it
    --- without taking part in the room-finding (a panel row, a label that
    --- must stay exactly where it is).
    ---@param x number
    ---@param y number
    ---@param how? { above?: boolean, claim?: boolean, left?: boolean }
    ---@return boolean drawn
    ---@return boolean crowded
    ---@return number height
    function M.place(x, y, how)
        local width, height, used = 0, 0, 0
        for i = 1, row_n do
            local r = rows[i]
            measure(r)
            if r.h > 0 and r.w > 0 then
                used = used + 1
                if r.w > width then width = r.w end
                height = height + r.h + ROW_GAP
            end
        end
        if used == 0 then return false, false, 0 end
        height = height - ROW_GAP

        local cx = x
        if how and how.left then cx = x + width * 0.5 end
        local x0 = cx - width * 0.5
        local top
        if how and how.above then
            top = y - height - 4
        else
            top = y + UNDER_FEET
        end

        local crowded = false
        if not (how and how.claim == false) then
            local start = top
            local shift = 0
            while shift < SHIFT_ROWS do
                local blocked = overlaps(x0, top, x0 + width, top + height)
                if not blocked then break end
                top = blocked + 2
                shift = shift + 1
            end
            if shift >= SHIFT_ROWS and overlaps(x0, top, x0 + width, top + height) then
                -- No room: print where it stands rather than vanish.
                top = start
                crowded = true
                stats.crowded = stats.crowded + 1
            end
            claim(x0, top, x0 + width, top + height)
        end

        for i = 1, row_n do
            local r = rows[i]
            if r.h > 0 and r.w > 0 then
                paint_row(r, cx, top)
                top = top + r.h + ROW_GAP
                stats.rows = stats.rows + 1
            end
        end
        stats.cards = stats.cards + 1
        return true, crowded, height
    end

    return M
end

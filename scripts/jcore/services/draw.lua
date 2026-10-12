-- JCore / draw -- z-ordered batching, a shared world-to-screen cache, one theme.
--
-- Depends on: util, log, units.
--
-- THREE PROBLEMS, ONE MODULE
--
-- 1. Z-ORDER. Native render callbacks fire in load order, so whichever plugin
--    happened to load last paints on top. An ESP box drawn over a HUD panel is
--    not a bug in either plugin, it is the absence of a shared ordering. Here
--    every primitive is submitted with a layer and the whole frame is painted
--    in layer order at the end of the render phase.
--
-- 2. WORLD TO SCREEN. core.graphics.w2s is a native projection call, and the
--    same unit position gets projected once per plugin that draws on it. With
--    an ESP plugin, a danger-drawing plugin and a rotation overlay all marking
--    the same forty units, that is a hundred-odd redundant projections a frame.
--    Projected positions are cached per unit per frame here.
--
-- 3. THEME. Every plugin inventing its own red means nothing on screen reads as
--    one system, and colour-blind users get no consistent treatment at all.
--    One palette, overridable in one place.
--
-- USAGE
-- Call the primitives from inside a render job. They queue; nothing is painted
-- until the core flushes. That means you may submit in any order from any
-- plugin and still get correct layering.

return function(rt)
    local util = rt.util
    local units = rt.units
    local log = rt.log.for_tag("JCore/draw")
    local floor = math.floor

    local color_lib
    do
        local ok, mod = pcall(require, "common/color")
        if ok then color_lib = mod end
    end

    -- The 2D graphics calls take a real vec2. A plain { x =, y = } table has
    -- the right fields but is not the same userdata type, and passing one
    -- either draws nothing or errors depending on the primitive -- so every
    -- screen position this module derives goes through the constructor.
    local vec2_lib
    do
        local ok, mod = pcall(require, "common/geometry/vector_2")
        if ok then vec2_lib = mod end
    end

    local vec3_lib
    do
        local ok, mod = pcall(require, "common/geometry/vector_3")
        if ok then vec3_lib = mod end
    end

    local function vec2(x, y)
        if vec2_lib then
            local ok, v = pcall(vec2_lib.new, x, y)
            if ok then return v end
        end
        return { x = x, y = y }
    end

    local function vec3(x, y, z)
        if vec3_lib then
            local ok, v = pcall(vec3_lib.new, x, y, z)
            if ok then return v end
        end
        return { x = x, y = y, z = z }
    end

    --- Coerces a screen point to a real vec2.
    ---
    --- Callers naturally write `{ x = 10, y = 20 }` for a HUD corner, and that
    --- plain table is the single easiest way to get a silently blank overlay.
    --- Accepting it here and converting is cheaper than every consumer
    --- remembering. A value that already came from w2s passes through: vec2
    --- carries its own metatable, so the rawget tells the two apart without
    --- reconstructing a point that is already correct.
    local function to_vec2(p)
        if not p then return nil end
        if not vec2_lib then return p end
        if getmetatable(p) ~= nil then return p end
        return vec2(p.x or 0, p.y or 0)
    end

    local M = {}

    --- Painting order, low to high. Pick the band that matches what the mark
    --- MEANS, not how visible you want it to be -- "important" is what colour
    --- and thickness are for.
    M.LAYER = {
        BACKGROUND = 0,    -- ground decals, zone shading
        WORLD      = 100,  -- paths, nav lines, spell ranges
        DANGER     = 200,  -- telegraphs, avoidable damage. Above world geometry.
        UNITS      = 300,  -- unit boxes, health bars, nameplate additions
        OVERLAY    = 400,  -- target markers, cast bars
        HUD        = 500,  -- fixed screen panels
        TOOLTIP    = 600,  -- always last
    }

    -- layer -> array of queued draw closures for this frame
    local queue = {}
    local layers_used = {}

    -- OVER THE GAME'S FRAMES (1.8.1). The render pass is painted under the
    -- client's own UI, so a JCore window sat behind the bags, the map or a
    -- quest log whenever one was open over it. The native window pass
    -- (core.register_on_render_window_callback, wired in main.lua) is painted
    -- over them, so the screen UI -- the HUD band and up: windows, panels,
    -- popups, tooltips, toasts -- is handed to it at each flush, in layer
    -- order. The world bands stay in the render pass, under the game's frames
    -- the way its own nameplates are. Only while that pass is seen firing:
    -- a loader without it, or the switch off (Core > UI), paints the UI in
    -- the render pass as before.
    local UI_BAND = M.LAYER.HUD
    local ui_buckets, ui_n = {}, 0
    local window_frame = nil -- frame_id of the last window pass
    local window_passes = 0  -- window passes since the last flush
    -- Render frames without a window pass before the UI goes back to the
    -- render pass, so a loader that stops calling it costs a blink, not
    -- the UI.
    local WINDOW_GRACE = 3
    -- Window passes one flush is painted for. The two passes run once a
    -- frame each; this keeps the UI up if they ever drift apart, and stops a
    -- frozen copy staying on screen when the render pass stops.
    local WINDOW_STALE = 2
    local window_stats = { pass = "render", window_calls = 0, window_painted = 0 }
    --- Paint the screen UI over the game's own frames. Core > UI sets it.
    M.over_game = true

    -- Per-frame world-to-screen cache, keyed by unit guid. Entries are reused
    -- in place and the table is dropped on the same cadence as the other
    -- per-guid caches (see _begin_frame); before 1.5.3 it was never emptied,
    -- so every unit ever projected stayed in it for the session.
    local w2s_cache = {}
    local frame_id = 0

    --- A unit's guid, and its sweep row when it was in this tick's sweep.
    ---
    --- A swept unit was valid this frame and its guid and position are on its
    --- row, so asking the client again -- is_valid, get_guid, get_position,
    --- two or three round trips per helper per mark -- buys nothing. Anything
    --- outside the sweep is asked the slow way, as before.
    ---@param unit game_object
    ---@return string|nil guid
    ---@return table|nil row
    ---@return boolean valid
    local function ident(unit)
        if not unit then return nil, nil, false end
        local row = units.snapshot(unit)
        if row then return row.guid, row, true end
        local ok, valid = pcall(unit.is_valid, unit)
        if not ok or not valid then return nil, nil, false end
        local ok_g, guid = pcall(unit.get_guid, unit)
        return ok_g and guid or nil, nil, true
    end

    --- A unit's position: off its sweep row when it has one.
    local function position_of(unit, row)
        if row then return row.pos end
        local ok, pos = pcall(unit.get_position, unit)
        return ok and pos or nil
    end

    -- Model height by guid. It changes with a mount or a shapeshift, not from
    -- frame to frame, so a box re-reads it twice a second rather than every
    -- frame.
    local height_cache = {}
    local HEIGHT_FRAMES = 30
    local function height_of(unit, guid)
        local entry = guid and height_cache[guid]
        if entry and frame_id - entry.frame < HEIGHT_FRAMES then return entry.height end
        local ok, height = pcall(unit.get_height, unit)
        if not ok or not height or height <= 0 then height = 2.0 end
        if guid then
            if entry then entry.frame, entry.height = frame_id, height
            else height_cache[guid] = { frame = frame_id, height = height } end
        end
        return height
    end

    local screen_w, screen_h = 0, 0
    -- Off-screen margin, in pixels. A box whose centre is just outside the
    -- viewport can still have visible edges, so culling exactly at the border
    -- makes marks pop at the screen edge.
    local CULL_MARGIN = 120

    local stats = { submitted = 0, culled = 0, painted = 0, dropped = 0 }

    -- Maximum DROPPABLE submissions per frame; 0 disables the cap. A plugin
    -- that marks its least important work droppable (an ESP's far-distance
    -- tier, say) degrades by losing those marks on a heavy frame instead of
    -- losing the frame. Nothing is dropped unless the caller opted in.
    local budget = 0

    -- --- theme --------------------------------------------------------------

    local function make_color(r, g, b, a)
        if color_lib then
            local ok, c = pcall(color_lib.new, r, g, b, a or 255)
            if ok then return c end
        end
        return { r = r, g = g, b = b, a = a or 255 }
    end

    --- The shared palette. Replace any entry through M.set_theme; every plugin
    --- that reads from here follows automatically.
    M.theme = {
        enemy      = make_color(235, 87, 87),
        ally       = make_color(87, 190, 120),
        neutral    = make_color(230, 190, 90),
        player     = make_color(90, 160, 235),
        danger     = make_color(240, 100, 60),
        warning    = make_color(240, 180, 60),
        good       = make_color(100, 200, 140),
        text       = make_color(235, 235, 240),
        text_dim   = make_color(165, 168, 178),
        accent     = make_color(140, 120, 240),
        backdrop   = make_color(18, 18, 22, 200),
        outline    = make_color(0, 0, 0, 180),
        -- Sits one pixel behind world-anchored text. Overlay text competes
        -- with whatever terrain is behind it -- snow, sand, lava -- and a
        -- shadow is what makes it legible over all three without putting a
        -- box around every word.
        shadow     = make_color(0, 0, 0, 205),
    }

    ---@param overrides table<string, any>
    function M.set_theme(overrides)
        util.deep_merge(M.theme, overrides)
    end

    --- Palette colour for a unit, by its relationship to the player.
    ---@param unit game_object
    ---@return color
    function M.unit_color(unit)
        local player = units.player()
        if not player or not unit then return M.theme.neutral end
        -- The sweep already sorted this unit into self, enemy or ally.
        local row = units.snapshot(unit)
        if row then
            if row.is_self then return M.theme.player end
            if row.is_enemy then return M.theme.enemy end
            if row.is_ally then return M.theme.ally end
            return M.theme.neutral
        end
        if unit:get_guid() == player:get_guid() then return M.theme.player end
        if player:can_attack(unit) then return M.theme.enemy end
        if player:is_friend_with(unit) then return M.theme.ally end
        return M.theme.neutral
    end

    -- --- projection ---------------------------------------------------------

    --- Projects a world position with NO culling. Use this only for a point
    --- that is geometrically derived from an already-visible one -- the top of
    --- a unit's bounding box, the far end of a line -- where culling the
    --- derived point would throw away a mark whose anchor is on screen.
    ---@param position vec3
    ---@return vec2|nil
    function M.project(position)
        if not position then return nil end
        local ok, screen = pcall(core.graphics.w2s, position)
        if not ok or not screen then return nil end
        return screen
    end

    --- Projects a world position. Returns nil when it is behind the camera or
    --- far enough off-screen not to be worth drawing.
    ---@param position vec3
    ---@return vec2|nil
    function M.w2s(position)
        local screen = M.project(position)
        if not screen then return nil end
        -- w2s answers a position for points behind the camera too; they come
        -- back mirrored rather than nil, which is why the cull is by bounds
        -- rather than by a nil check.
        if screen.x < -CULL_MARGIN or screen.y < -CULL_MARGIN
            or screen.x > screen_w + CULL_MARGIN or screen.y > screen_h + CULL_MARGIN then
            return nil
        end
        return screen
    end

    --- Projected screen position of a unit, computed at most once per frame
    --- however many plugins ask for it.
    ---@param unit game_object
    ---@return vec2|nil
    function M.unit_w2s(unit)
        local guid, row, valid = ident(unit)
        if not valid then return nil end
        if not guid then return M.w2s(position_of(unit, row)) end

        local entry = w2s_cache[guid]
        if entry and entry.frame == frame_id then
            return entry.screen
        end

        local screen = M.w2s(position_of(unit, row))
        if entry then
            entry.frame, entry.screen = frame_id, screen
        else
            w2s_cache[guid] = { frame = frame_id, screen = screen }
        end
        return screen
    end

    --- True when a world position is worth drawing at all this frame.
    ---@param position vec3
    ---@return boolean
    function M.is_visible(position)
        return M.w2s(position) ~= nil
    end

    --- Viewport size, read once per frame. Prefer this over calling
    --- core.graphics.get_screen_size from a render job, which pays a native
    --- call per plugin per frame for a value that cannot change mid-frame.
    ---@return number width
    ---@return number height
    function M.screen_size()
        return screen_w, screen_h
    end

    -- --- submission ---------------------------------------------------------

    --- Queues an arbitrary draw closure on a layer. Everything else in this
    --- module is sugar over this.
    ---
    --- The closure runs during the flush, not now, so do not capture anything
    --- you are about to mutate -- capture values, not tables you will reuse.
    ---
    --- `droppable` marks the submission as expendable: once the frame is over
    --- budget it is refused and counted rather than queued. Use it for the
    --- marks you would rather lose than drop a frame for, never for a warning.
    ---@param layer integer
    ---@param fn function
    ---@param droppable? boolean
    function M.submit(layer, fn, droppable)
        if droppable and budget > 0 and stats.submitted >= budget then
            stats.dropped = stats.dropped + 1
            return
        end
        layer = layer or M.LAYER.OVERLAY
        local bucket = queue[layer]
        if not bucket then
            bucket = {}
            queue[layer] = bucket
            layers_used[#layers_used + 1] = layer
        end
        bucket[#bucket + 1] = fn
        stats.submitted = stats.submitted + 1
    end

    ---@param center vec3
    ---@param radius number
    ---@param col color
    ---@param opts? { layer?: integer, thickness?: number, filled?: boolean, fade?: number }
    function M.circle_3d(center, radius, col, opts)
        opts = opts or {}
        if not M.is_visible(center) then
            stats.culled = stats.culled + 1
            return
        end
        local filled = opts.filled
        local thickness = opts.thickness or 1.5
        local fade = opts.fade or 1.0
        M.submit(opts.layer or M.LAYER.WORLD, function()
            if filled then
                core.graphics.circle_3d_filled(center, radius, col)
            else
                core.graphics.circle_3d(center, radius, col, thickness, fade)
            end
        end, opts.droppable)
    end

    ---@param from vec3
    ---@param to vec3
    ---@param col color
    ---@param opts? { layer?: integer, thickness?: number, fade?: number }
    function M.line_3d(from, to, col, opts)
        opts = opts or {}
        -- A line is worth drawing when EITHER end is on screen; culling on both
        -- would drop every line that crosses the viewport.
        if not M.is_visible(from) and not M.is_visible(to) then
            stats.culled = stats.culled + 1
            return
        end
        local thickness = opts.thickness or 1.5
        local fade = opts.fade or 1.0
        M.submit(opts.layer or M.LAYER.WORLD, function()
            core.graphics.line_3d(from, to, col, thickness, fade)
        end, opts.droppable)
    end

    ---@param position vec3
    ---@param text string
    ---@param col color
    ---@param opts? { layer?: integer, size?: number, centered?: boolean, font_id?: integer }
    function M.text_3d(position, text, col, opts)
        opts = opts or {}
        if not M.is_visible(position) then
            stats.culled = stats.culled + 1
            return
        end
        local size = opts.size or 14
        local centered = opts.centered ~= false
        local font_id = opts.font_id
        M.submit(opts.layer or M.LAYER.OVERLAY, function()
            core.graphics.text_3d(text, position, size, col, centered, font_id)
        end, opts.droppable)
    end

    ---@param position vec2
    ---@param text string
    ---@param col color
    ---@param opts? { layer?: integer, size?: number, centered?: boolean, font_id?: integer, shadow?: boolean, droppable?: boolean }
    function M.text_2d(position, text, col, opts)
        opts = opts or {}
        local size = opts.size or 14
        local centered = opts.centered == true
        local font_id = opts.font_id
        local at = to_vec2(position)

        -- The shadow is a second native call, not a second queue entry: the
        -- two can never be usefully separated, and a mark that lost its
        -- shadow to another plugin's layer would look like a rendering bug.
        if opts.shadow then
            local behind = vec2(at.x + 1, at.y + 1)
            local shadow_col = M.theme.shadow
            M.submit(opts.layer or M.LAYER.HUD, function()
                core.graphics.text_2d(text, behind, size, shadow_col, centered, font_id)
                core.graphics.text_2d(text, at, size, col, centered, font_id)
            end, opts.droppable)
            return
        end

        M.submit(opts.layer or M.LAYER.HUD, function()
            core.graphics.text_2d(text, at, size, col, centered, font_id)
        end, opts.droppable)
    end

    ---@param top_left vec2
    ---@param width number
    ---@param height number
    ---@param col color
    ---@param opts? { layer?: integer, filled?: boolean, thickness?: number, rounding?: number }
    function M.rect_2d(top_left, width, height, col, opts)
        opts = opts or {}
        local filled = opts.filled
        local thickness = opts.thickness or 1.0
        local rounding = opts.rounding or 0
        local at = to_vec2(top_left)
        M.submit(opts.layer or M.LAYER.HUD, function()
            if filled then
                core.graphics.rect_2d_filled(at, width, height, col, rounding)
            else
                core.graphics.rect_2d(at, width, height, col, thickness, rounding)
            end
        end, opts.droppable)
    end

    ---@param from vec2
    ---@param to vec2
    ---@param col color
    ---@param opts? { layer?: integer, thickness?: number }
    function M.line_2d(from, to, col, opts)
        opts = opts or {}
        local thickness = opts.thickness or 1.0
        local a, b = to_vec2(from), to_vec2(to)
        M.submit(opts.layer or M.LAYER.HUD, function()
            core.graphics.line_2d(a, b, col, thickness)
        end, opts.droppable)
    end

    --- Screen-space bounding box around a unit -- the classic ESP mark.
    ---
    --- Derived by projecting the unit's feet and the point one model-height
    --- above them, so the box tracks perspective: it shrinks with distance and
    --- grows for a large model, without any per-creature tuning.
    ---
    --- The TOP point is projected without culling on purpose. A tall unit
    --- standing at the bottom of the screen has its head above the viewport,
    --- and culling that derived point would drop a box whose subject is in
    --- plain view.
    ---@param unit game_object
    ---@param col? color
    ---@param opts? { layer?: integer, thickness?: number, aspect?: number, filled?: boolean, min_height?: number }
    function M.unit_box(unit, col, opts)
        opts = opts or {}
        local guid, row, valid = ident(unit)
        if not valid then return end

        local base = M.unit_w2s(unit)
        if not base then
            stats.culled = stats.culled + 1
            return
        end

        local pos = position_of(unit, row)
        if not pos then return end

        -- get_height can answer 0 for an object the client has not fully
        -- resolved; a fixed fallback beats a zero-height box.
        local height = height_of(unit, guid)

        local top = M.project(vec3(pos.x, pos.y, pos.z + height))
        if not top then return end

        local box_h = math.abs(base.y - top.y)
        local min_h = opts.min_height or 6
        if box_h < min_h then box_h = min_h end
        local box_w = box_h * (opts.aspect or 0.55)

        local origin = vec2(base.x - box_w * 0.5, math.min(base.y, top.y))
        local use = col or M.unit_color(unit)
        local thickness = opts.thickness or 1.0
        local filled = opts.filled
        local layer = opts.layer or M.LAYER.UNITS

        M.submit(layer, function()
            if filled then
                core.graphics.rect_2d_filled(origin, box_w, box_h, use, 0)
            else
                core.graphics.rect_2d(origin, box_w, box_h, use, thickness, 0)
            end
        end, opts.droppable)

        return origin, box_w, box_h
    end

    --- The screen point a mark should hang from: above the unit's head, not a
    --- fixed number of pixels above wherever its feet project to.
    ---
    --- WHY IT MATTERS: the feet anchor puts a label THROUGH the model of a
    --- tall unit and well above a small one, and the error changes with the
    --- camera angle. The model's own name attachment is where the game puts a
    --- nameplate, so a mark hung from it sits above the creature at every
    --- distance and every pitch.
    ---
    --- Falls back to the feet projection, so a caller never has to branch.
    ---@param unit game_object
    ---@param lift? number Pixels above the head.
    ---@return vec2|nil
    function M.unit_anchor(unit, lift)
        local head = M.unit_head(unit)
        local screen = head and M.w2s(head) or nil
        if not screen then
            screen = M.unit_w2s(unit)
            if not screen then return nil end
        end
        return vec2(screen.x, screen.y - (lift or 0))
    end

    --- Text anchored above a unit, with `offset` pixels of lift. The single
    --- most common ESP primitive, and the one that most wants the shared
    --- projection cache.
    ---@param unit game_object
    ---@param text string
    ---@param col? color
    ---@param opts? { layer?: integer, size?: number, offset?: number, shadow?: boolean, head?: boolean, at?: vec2, droppable?: boolean }
    function M.unit_label(unit, text, col, opts)
        opts = opts or {}

        -- Coerced, because a caller computing a row position naturally writes
        -- `{ x =, y = }` and that plain table draws nothing.
        local anchor = to_vec2(opts.at)
        if not anchor then
            local screen = opts.head and M.unit_anchor(unit, opts.offset or 0)
                or (function()
                    local s = M.unit_w2s(unit)
                    return s and vec2(s.x, s.y - (opts.offset or 0)) or nil
                end)()
            if not screen then
                stats.culled = stats.culled + 1
                return
            end
            anchor = screen
        end

        local size = opts.size or 14
        local use = col or M.unit_color(unit)
        local shadow = opts.shadow
        local shadow_col = M.theme.shadow
        local behind = shadow and vec2(anchor.x + 1, anchor.y + 1) or nil

        M.submit(opts.layer or M.LAYER.UNITS, function()
            if behind then
                core.graphics.text_2d(text, behind, size, shadow_col, true)
            end
            core.graphics.text_2d(text, anchor, size, use, true)
        end, opts.droppable)
    end

    --- Horizontal bar above a unit -- health, cast progress, anything 0..1.
    ---@param unit game_object
    ---@param fraction number 0..1
    ---@param col color
    ---@param opts? { layer?: integer, width?: number, height?: number, offset?: number, background?: color }
    function M.unit_bar(unit, fraction, col, opts)
        opts = opts or {}

        -- `at` is a point the caller already worked out -- typically the line
        -- below a name label, so the bar belongs to the text above it instead
        -- of floating its own distance from the unit's feet.
        local screen = opts.at
        if not screen then
            screen = M.unit_w2s(unit)
            if not screen then
                stats.culled = stats.culled + 1
                return
            end
        end

        local width = opts.width or 60
        local height = opts.height or 5
        local offset = opts.at and 0 or (opts.offset or 20)
        local background = opts.background or M.theme.backdrop
        local border = opts.border
        local layer = opts.layer or M.LAYER.UNITS
        local filled = util.clamp(fraction, 0, 1) * width
        local origin = vec2(screen.x - width * 0.5, screen.y - offset)

        M.submit(layer, function()
            core.graphics.rect_2d_filled(origin, width, height, background, 1)
            if filled > 0 then
                core.graphics.rect_2d_filled(origin, filled, height, col, 1)
            end
            if border then
                core.graphics.rect_2d(origin, width, height, border, 1.0, 1)
            end
        end, opts.droppable)
    end

    -- --- measurement --------------------------------------------------------

    -- Text width is a native call and the same strings are measured every
    -- frame -- a panel that right-aligns eight rows measures eight strings
    -- sixty times a second for an answer that only changes when the text
    -- does. Keyed by text and size, and cleared wholesale when it grows past
    -- the point where the strings are clearly dynamic rather than reused.
    local measure_cache = {}
    local measure_count = 0
    local MEASURE_CACHE_MAX = 512

    --- Rendered width of a string, in pixels.
    ---@param text string
    ---@param size? number
    ---@param font_id? integer
    ---@return number
    function M.measure(text, size, font_id)
        if not text or text == "" then return 0 end
        size = size or 14
        local key = size .. "|" .. (font_id or 0) .. "|" .. text
        local hit = measure_cache[key]
        if hit then return hit end

        local ok, width = pcall(core.graphics.get_text_width, text, size, font_id)
        width = (ok and width) or (#text * size * 0.5)

        if measure_count >= MEASURE_CACHE_MAX then
            measure_cache = {}
            measure_count = 0
        end
        measure_cache[key] = width
        measure_count = measure_count + 1
        return width
    end

    --- Text on a backdrop sized to fit it.
    ---
    --- The reason this exists rather than callers drawing a rect and a string:
    --- white text over snow, and any text over lava, is unreadable, and an
    --- overlay that is unreadable a quarter of the time is not a working
    --- overlay. The backdrop is the difference, and it has to be measured.
    ---@param position vec2
    ---@param text string
    ---@param col? color
    ---@param opts? { layer?: integer, size?: number, centered?: boolean, pad?: number, background?: color, font_id?: integer, droppable?: boolean }
    function M.text_bg(position, text, col, opts)
        opts = opts or {}
        if not text or text == "" then return end

        local size = opts.size or 14
        local pad = opts.pad or 3
        local centered = opts.centered == true
        local font_id = opts.font_id
        local width = M.measure(text, size, font_id)
        local height = size + pad

        local at = to_vec2(position)
        local left = centered and (at.x - width * 0.5) or at.x
        local origin = vec2(left - pad, at.y - pad * 0.5)
        local back = opts.background or M.theme.backdrop
        local use = col or M.theme.text
        local box_w, box_h = width + pad * 2, height + pad

        M.submit(opts.layer or M.LAYER.OVERLAY, function()
            core.graphics.rect_2d_filled(origin, box_w, box_h, back, 2)
            core.graphics.text_2d(text, at, size, use, centered, font_id)
        end, opts.droppable)
    end

    -- --- unit marks ---------------------------------------------------------

    --- Corner brackets instead of a closed box.
    ---
    --- Same information as unit_box, a quarter of the ink. With thirty units
    --- on screen a full box per unit is a wall of rectangles; the corners read
    --- as a mark without filling the screen with lines.
    ---@param unit game_object
    ---@param col? color
    ---@param opts? { layer?: integer, thickness?: number, aspect?: number, length?: number, min_height?: number, droppable?: boolean }
    function M.unit_box_corners(unit, col, opts)
        opts = opts or {}
        local guid, row, valid = ident(unit)
        if not valid then return end

        local base = M.unit_w2s(unit)
        if not base then
            stats.culled = stats.culled + 1
            return
        end

        local pos = position_of(unit, row)
        if not pos then return end

        local height = height_of(unit, guid)

        local top = M.project(vec3(pos.x, pos.y, pos.z + height))
        if not top then return end

        local box_h = math.abs(base.y - top.y)
        if box_h < (opts.min_height or 6) then box_h = opts.min_height or 6 end
        local box_w = box_h * (opts.aspect or 0.55)

        local x0 = base.x - box_w * 0.5
        local y0 = math.min(base.y, top.y)
        local x1, y1 = x0 + box_w, y0 + box_h
        -- Bracket arms are a fraction of the box, so they stay proportional
        -- as the unit moves away instead of swallowing a distant box whole.
        local arm = math.max(3, math.min(box_w, box_h) * (opts.length or 0.28))
        local use = col or M.unit_color(unit)
        local thickness = opts.thickness or 1.4

        M.submit(opts.layer or M.LAYER.UNITS, function()
            local function corner(cx, cy, dx, dy)
                core.graphics.line_2d(vec2(cx, cy), vec2(cx + arm * dx, cy), use, thickness)
                core.graphics.line_2d(vec2(cx, cy), vec2(cx, cy + arm * dy), use, thickness)
            end
            corner(x0, y0,  1,  1)
            corner(x1, y0, -1,  1)
            corner(x0, y1,  1, -1)
            corner(x1, y1, -1, -1)
        end, opts.droppable)

        return x0, y0, box_w, box_h
    end

    --- A true 3D box around the model, drawn in world space.
    ---
    --- Twelve edges go out as ONE queued closure rather than twelve. The queue
    --- exists to order work, not to hold it; a mark whose parts can never be
    --- separated by another plugin's layer belongs in one entry.
    ---@param unit game_object
    ---@param col? color
    ---@param opts? { layer?: integer, thickness?: number, radius?: number, height?: number, fade?: number, droppable?: boolean }
    function M.unit_box_3d(unit, col, opts)
        opts = opts or {}
        local _, row, valid = ident(unit)
        if not valid then return end

        local pos = position_of(unit, row)
        if not pos or not M.is_visible(pos) then
            stats.culled = stats.culled + 1
            return
        end

        local radius = opts.radius
        if not radius then
            local ok, value = pcall(unit.get_bounding_radius, unit)
            radius = (ok and value and value > 0) and value or 0.6
        end

        local height = opts.height
        if not height then
            local ok, value = pcall(unit.get_height, unit)
            height = (ok and value and value > 0) and value or 2.0
        end

        local z0, z1 = pos.z, pos.z + height
        local x0, x1 = pos.x - radius, pos.x + radius
        local y0, y1 = pos.y - radius, pos.y + radius

        local bottom = {
            vec3(x0, y0, z0), vec3(x1, y0, z0), vec3(x1, y1, z0), vec3(x0, y1, z0),
        }
        local top = {
            vec3(x0, y0, z1), vec3(x1, y0, z1), vec3(x1, y1, z1), vec3(x0, y1, z1),
        }

        local use = col or M.unit_color(unit)
        local thickness = opts.thickness or 1.2
        local fade = opts.fade or 1.0

        M.submit(opts.layer or M.LAYER.UNITS, function()
            for i = 1, 4 do
                local j = (i % 4) + 1
                core.graphics.line_3d(bottom[i], bottom[j], use, thickness, fade)
                core.graphics.line_3d(top[i], top[j], use, thickness, fade)
                core.graphics.line_3d(bottom[i], top[i], use, thickness, fade)
            end
        end, opts.droppable)
    end

    --- A bar above a unit made of several stacked fractions.
    ---
    --- Health, absorb and incoming heals are three answers about the same bar,
    --- and drawing them as three bars costs three times the vertical space for
    --- information that only means anything side by side.
    ---@param unit game_object
    ---@param segments { fraction: number, color: color }[] Drawn left to right, cumulative.
    ---@param opts? { layer?: integer, width?: number, height?: number, offset?: number, background?: color, border?: color, droppable?: boolean }
    function M.unit_bar_multi(unit, segments, opts)
        opts = opts or {}
        local screen = M.unit_w2s(unit)
        if not screen then
            stats.culled = stats.culled + 1
            return
        end

        local width = opts.width or 60
        local height = opts.height or 5
        local offset = opts.offset or 20
        local background = opts.background or M.theme.backdrop
        local border = opts.border
        local origin = vec2(screen.x - width * 0.5, screen.y - offset)

        -- Flattened at submit time: the caller's segment table is theirs to
        -- reuse next frame, and the closure runs after they have.
        local plan, cursor = {}, 0
        for i = 1, #segments do
            local seg = segments[i]
            local span = util.clamp(seg.fraction or 0, 0, 1) * width
            if span > 0 and cursor < width then
                if cursor + span > width then span = width - cursor end
                plan[#plan + 1] = { x = origin.x + cursor, w = span, color = seg.color }
                cursor = cursor + span
            end
        end

        M.submit(opts.layer or M.LAYER.UNITS, function()
            core.graphics.rect_2d_filled(origin, width, height, background, 1)
            for i = 1, #plan do
                local part = plan[i]
                core.graphics.rect_2d_filled(vec2(part.x, origin.y), part.w, height, part.color, 1)
            end
            if border then
                core.graphics.rect_2d(origin, width, height, border, 1.0, 1)
            end
        end, opts.droppable)
    end

    -- Model attachment points resolve through a native call per unit per ask,
    -- and every mark that wants a head position wants the same one.
    local attach_cache = {}
    local head_cache = {}

    --- World position of one of a unit's model attachment points, or nil when
    --- the model has not loaded.
    ---
    --- The native call answers a ZERO VECTOR rather than nil for an unloaded
    --- model, which lands the mark at the centre of the map. That check is the
    --- reason to route through here rather than calling it directly.
    ---@param unit game_object
    ---@param attachment_id integer
    ---@return vec3|nil
    function M.attachment(unit, attachment_id)
        local guid, _, valid = ident(unit)
        if not valid then return nil end
        local key = (guid or tostring(unit)) .. "#" .. attachment_id

        local entry = attach_cache[key]
        if entry and entry.frame == frame_id then return entry.pos end

        local ok, pos = pcall(unit.get_attachment_position, unit, attachment_id)
        if not ok or not pos or (pos.x == 0 and pos.y == 0 and pos.z == 0) then
            pos = nil
        end
        attach_cache[key] = { frame = frame_id, pos = pos }
        return pos
    end

    --- The anchor above a unit's head, where the game puts its name. Falls
    --- back to the unit's position plus its height, so a caller always gets
    --- something to draw against.
    ---@param unit game_object
    ---@return vec3|nil
    function M.unit_head(unit)
        local guid, row, valid = ident(unit)
        if not valid then return nil end
        local key = guid or unit

        local entry = head_cache[key]
        if entry and entry.frame == frame_id then return entry.pos end

        local pos
        local ok, value = pcall(unit.get_attachment_name_position, unit)
        if ok and value and not (value.x == 0 and value.y == 0 and value.z == 0) then
            pos = value
        else
            local base = position_of(unit, row)
            if base then
                pos = vec3(base.x, base.y, base.z + height_of(unit, guid))
            end
        end

        if entry then
            entry.frame, entry.pos = frame_id, pos
        else
            head_cache[key] = { frame = frame_id, pos = pos }
        end
        return pos
    end

    -- --- world shapes -------------------------------------------------------

    --- A partial ring on the ground -- a cast in progress, a respawn clock, a
    --- cooldown, anything with a fraction and a place in the world.
    ---
    --- NOTE ON UNITS: the native call takes a "percentage" whose scale is not
    --- documented and has not been verified against a build. This wrapper
    --- takes a 0..1 FRACTION and multiplies by 100. If arcs come out full or
    --- invisible, this multiply is the one line to change.
    ---@param center vec3
    ---@param radius number
    ---@param fraction number 0..1
    ---@param col color
    ---@param opts? { layer?: integer, thickness?: number, droppable?: boolean }
    function M.arc_3d(center, radius, fraction, col, opts)
        opts = opts or {}
        if not M.is_visible(center) then
            stats.culled = stats.culled + 1
            return
        end
        local pct = util.clamp(fraction or 0, 0, 1) * 100
        local thickness = opts.thickness or 2.0
        M.submit(opts.layer or M.LAYER.WORLD, function()
            core.graphics.circle_3d_percentage(center, radius, col, pct, thickness)
        end, opts.droppable)
    end

    -- --- shader ring and curtain (1.11.0) --------------------------------------
    --
    -- The loader's render_circle_percentage_3d paints a flat ring on the
    -- ground from one SDF quad: soft edges, a band all the way round, and a
    -- fill shading from one colour to another. ring_3d uses it while
    -- M.shaders is on (the "Shader drawing" switch on the JCore/UI page) and
    -- the loader has it; otherwise, and from the first time the call raises,
    -- the plain circle_3d and circle_3d_percentage outlines.

    M.shaders = true
    local ring_native = nil -- nil: not asked yet

    local function ring_shader()
        if not M.shaders then return false end
        if ring_native == nil then
            local g = core.graphics
            ring_native = g ~= nil and type(g.render_circle_percentage_3d) == "function"
        end
        return ring_native
    end

    local function channels(c)
        if type(c) == "table" and c.r then return c.r, c.g, c.b, c.a or 255 end
        if c and c.get then
            local ok, r, g, b, a = pcall(c.get, c)
            if ok and r then return r, g, b, a or 255 end
        end
        return 255, 255, 255, 255
    end

    --- `a` carried `t` of the way to `b`.
    local function blend(a, b, t)
        if t <= 0 then return a end
        if t >= 1 then return b end
        local r1, g1, b1, a1 = channels(a)
        local r2, g2, b2, a2 = channels(b)
        return make_color(floor(r1 + (r2 - r1) * t + 0.5), floor(g1 + (g2 - g1) * t + 0.5),
            floor(b1 + (b2 - b1) * t + 0.5), floor(a1 + (a2 - a1) * t + 0.5))
    end
    M.blend = blend

    --- `c` with its alpha times `mul` (1.13.0).
    local function with_alpha(c, mul)
        local r, g, b, a = channels(c)
        return make_color(r, g, b, floor(util.clamp(a * mul, 0, 255) + 0.5))
    end
    M.with_alpha = with_alpha

    ---@class jcore_ring_opts
    ---@field layer? integer     default WORLD
    ---@field bg? color          the band all the way round (default theme.backdrop)
    ---@field to? color          the fill's colour where it ends (default the fill colour)
    ---@field inner? number      inner edge as a fraction of the radius (default 0.70)
    ---@field outer? number      outer edge (default 0.98)
    ---@field start? number      radians where the fill starts (default -pi/2)
    ---@field direction? number  positive clockwise, negative counter-clockwise (default 1)
    ---@field softness? number   edge softness in pixels (default 1)
    ---@field thickness? number  outline width when there is no shader (default 2)
    ---@field droppable? boolean

    --- A flat ring on the ground that fills -- a cast, a countdown, a timer.
    --- One render_circle_percentage_3d where the loader has it; two outlines
    --- otherwise (the band, and circle_3d_percentage for the fill in the
    --- colour it has reached).
    ---@param center vec3
    ---@param radius number yards, to the ring's outer edge
    ---@param fraction number 0..1 of the ring filled
    ---@param col color the fill's colour where it starts
    ---@param opts? jcore_ring_opts
    function M.ring_3d(center, radius, fraction, col, opts)
        opts = opts or {}
        if not M.is_visible(center) then
            stats.culled = stats.culled + 1
            return
        end
        fraction = util.clamp(tonumber(fraction) or 0, 0, 1)
        local bg = opts.bg or M.theme.backdrop
        local to = opts.to or col
        local inner, outer = opts.inner or 0.70, opts.outer or 0.98
        local mid = radius * (inner + outer) / 2
        local reached = blend(col, to, fraction)
        local thickness = opts.thickness or 2.0
        local function outlines()
            local g = core.graphics
            g.circle_3d(center, mid, bg, thickness, 1.0)
            if fraction > 0 then g.circle_3d_percentage(center, mid, reached, fraction * 100, thickness) end
        end
        if not ring_shader() then
            M.submit(opts.layer or M.LAYER.WORLD, outlines, opts.droppable)
            return
        end
        local start, direction, softness = opts.start or -math.pi / 2, opts.direction or 1, opts.softness or 1.0
        M.submit(opts.layer or M.LAYER.WORLD, function()
            if ring_native then
                local ok, err = pcall(core.graphics.render_circle_percentage_3d, center, radius, bg, col, to,
                    fraction, start, direction, inner, outer, softness)
                if ok then return end
                ring_native = false
                log.fmt("warn", "render_circle_percentage_3d raised, rings draw as outlines instead: %s", tostring(err))
            end
            outlines()
        end, opts.droppable)
    end

    ---@class jcore_curtain_opts
    ---@field layer? integer     default WORLD
    ---@field height? number     yards (default 1)
    ---@field points? integer    around the circle (default 36, 8..96)
    ---@field rings? integer     horizontal rings, bottom to top (default 4, 2..9)
    ---@field verticals? integer a vertical line every this many points (default 3; 0 for none)
    ---@field folds? number      waves in and out around the circle (default 3)
    ---@field vfolds? number     waves up and down around the circle (default 2)
    ---@field wave? number       yards in and out (default a quarter of the radius, at most 0.5)
    ---@field vwave? number      yards up and down at the top (default 0.3)
    ---@field speed? number      how fast the waves travel (default 1)
    ---@field spin? number       radians a second the whole curtain turns (default 1)
    ---@field to? color          the top ring's colour (default the base colour)
    ---@field thickness? number  default 1.5
    ---@field fade? number       default 1
    ---@field time? number       seconds (default core.time())
    ---@field droppable? boolean
    ---@field fill? number       1.13.0: a see-through sheet between the rings, this strong (0..1) at the bottom and fading to nothing at the top
    ---@field lines? boolean     1.13.0: the lines themselves (default true; false with `fill` for the sheet alone)
    ---@field lod? boolean       1.13.0: fewer points with distance from you, full detail out to `near` (never under 10 points)
    ---@field near? number       yards of full detail with `lod` (default 20)
    ---@field cull_height? boolean  1.13.0: drawn while its top is on screen too, not only its foot (a tall beacon behind a hill)

    --- A rippling curtain of lines standing on a circle: the wave of Lemons'
    --- Aurora Systems, built to run on many units at once. The waves are
    --- worked out once per call, there is one colour per ring rather than per
    --- line, and the whole curtain is one submission. The base stays on the
    --- ground; the waves grow toward the top. 4 rings of 36 points with a
    --- vertical every third point is 180 line_3d calls (Aurora Systems'
    --- defaults are 1,020).
    ---@param center vec3
    ---@param radius number yards
    ---@param col color the bottom ring's colour
    ---@param opts? jcore_curtain_opts
    function M.curtain_3d(center, radius, col, opts)
        opts = opts or {}
        local visible = M.is_visible(center)
        if not visible and opts.cull_height then
            visible = M.is_visible(vec3(center.x, center.y, center.z + (opts.height or 1.0)))
        end
        if not visible then
            stats.culled = stats.culled + 1
            return
        end
        local points = util.clamp(floor(opts.points or 36), 8, 96)
        if opts.lod then
            local me = units.player_position and units.player_position()
            if me and me.x then
                local dx, dy = center.x - me.x, center.y - me.y
                local d = math.sqrt(dx * dx + dy * dy)
                local near = opts.near or 20
                if d > near then points = math.max(10, math.min(points, floor(points * near / d + 0.5))) end
            end
        end
        local rings = util.clamp(floor(opts.rings or 4), 2, 9)
        local every = floor(opts.verticals or 3)
        local height = opts.height or 1.0
        local folds, vfolds = opts.folds or 3, opts.vfolds or 2
        local wave = opts.wave or math.min(0.5, radius * 0.25)
        local vwave = opts.vwave or 0.3
        local speed, spin = opts.speed or 1, opts.spin or 1
        local t = opts.time or core.time()
        local to = opts.to or col
        local thickness, fade = opts.thickness or 1.5, opts.fade or 1.0
        local cx, cy, cz = center.x, center.y, center.z
        local sin, cos, tau = math.sin, math.cos, 2 * math.pi

        local draw_lines = opts.lines ~= false
        local fill = tonumber(opts.fill) or 0
        local fills = nil
        if fill > 0 then
            local g = core.graphics
            if g and type(g.triangle_3d_filled) == "function" then
                fills = {}
                for k = 1, rings - 1 do
                    local hf = (k - 1) / (rings - 1)
                    fills[k] = with_alpha(blend(col, to, hf), fill * (1 - hf) ^ 1.3)
                end
            end
        end
        if not draw_lines and not fills then return end

        local grid, colors = {}, {}
        for k = 1, rings do
            local hf = (k - 1) / (rings - 1)
            colors[k] = blend(col, to, hf)
            local row = {}
            for i = 1, points do
                local a = (i / points) * tau + t * spin
                local wr = radius + sin(a * folds + t * speed) * wave * (0.35 + 0.65 * hf)
                local vw = sin(a * vfolds + t * speed * 0.8 + hf * 0.5 * math.pi)
                row[i] = vec3(cx + cos(a) * wr, cy + sin(a) * wr, cz + hf * (height + vw * vwave))
            end
            grid[k] = row
        end

        M.submit(opts.layer or M.LAYER.WORLD, function()
            if fills then
                local tri = core.graphics.triangle_3d_filled
                for k = 1, rings - 1 do
                    local c, a, b = fills[k], grid[k], grid[k + 1]
                    for i = 1, points do
                        local j = i % points + 1
                        tri(a[i], a[j], b[j], c)
                        tri(a[i], b[j], b[i], c)
                    end
                end
            end
            if not draw_lines then return end
            local line = core.graphics.line_3d
            for k = 1, rings do
                local row, c = grid[k], colors[k]
                for i = 1, points do
                    line(row[i], row[i % points + 1], c, thickness, fade)
                end
            end
            if every > 0 then
                for i = 1, points, every do
                    for k = 1, rings - 1 do
                        line(grid[k][i], grid[k + 1][i], colors[k], thickness, fade)
                    end
                end
            end
        end, opts.droppable)
    end

    ---@class jcore_beacon_opts
    ---@field height? number   yards (default 12)
    ---@field radius? number   yards (default 0.45)
    ---@field to? color        the top's colour (default the base colour, nearly clear)
    ---@field fill? number     the sheet's strength (default 0.5; 0 for lines alone)
    ---@field glow? boolean    a soft ring on the ground at its foot (default true)
    ---@field points? integer  default 14, fewer with distance
    ---@field thickness? number
    ---@field time? number
    ---@field layer? integer
    ---@field droppable? boolean

    --- A tall, thin pillar of light to find a place or a far unit by (1.13.0):
    --- a narrow filled curtain, drawn while its top is on screen even when
    --- its foot is behind a hill, with fewer points the further it is, and a
    --- glow on the ground at its foot.
    ---@param pos vec3
    ---@param col color
    ---@param opts? jcore_beacon_opts
    function M.beacon_3d(pos, col, opts)
        opts = opts or {}
        local radius = opts.radius or 0.45
        M.curtain_3d(pos, radius, col, {
            to = opts.to or with_alpha(col, 0.12),
            height = opts.height or 12, points = opts.points or 14, rings = 5, verticals = 2,
            folds = 2, vfolds = 1, wave = radius * 0.35, vwave = 0.4, speed = 0.8, spin = 0.9,
            fill = opts.fill or 0.5, lod = true, near = 30, cull_height = true,
            thickness = opts.thickness or 1.5, time = opts.time, layer = opts.layer, droppable = opts.droppable,
        })
        if opts.glow ~= false then
            M.ring_3d(pos, radius * 4, 1, with_alpha(col, 0.5), { bg = with_alpha(col, 0.12),
                inner = 0.35, outer = 1.0, softness = 4, layer = opts.layer, droppable = opts.droppable })
        end
    end

    -- --- pulses (1.13.0) ----------------------------------------------------------
    --
    -- A ring that opens out and fades over a moment, for something that just
    -- happened: a kick landed, a rare appeared, a party member dropped low.
    -- Fire one and forget it; JCore draws it on the frames that follow, at a
    -- place or under a unit it follows.

    local pulses = {}
    local PULSE_MAX = 32
    local pulse_cols = setmetatable({}, { __mode = "k" })

    --- The colour at a tenth of its alpha per step, made once per colour.
    local function faded(col, step)
        local list = pulse_cols[col]
        if not list then
            list = {}
            pulse_cols[col] = list
        end
        local c = list[step]
        if not c then
            c = with_alpha(col, step / 10)
            list[step] = c
        end
        return c
    end

    ---@class jcore_pulse_opts
    ---@field life? number   seconds (default 0.7)
    ---@field from? number   yards when it starts (default 0.6)
    ---@field to? number     yards when it ends (default 2.4)
    ---@field inner? number  the band's inner edge (default 0.86)
    ---@field layer? integer

    --- @param at vec3|game_object a place, or a unit to follow
    --- @param col color
    --- @param opts? jcore_pulse_opts
    function M.pulse(at, col, opts)
        if not at or not col then return end
        opts = opts or {}
        local ok, x = pcall(function() return at.x end)
        if #pulses >= PULSE_MAX then table.remove(pulses, 1) end
        pulses[#pulses + 1] = {
            at = at, unit = not (ok and type(x) == "number"), col = col, born = core.time(),
            life = opts.life or 0.7, r0 = opts.from or 0.6, r1 = opts.to or 2.4,
            inner = opts.inner or 0.86, layer = opts.layer or M.LAYER.WORLD,
        }
    end

    --- How many pulses are still playing.
    function M.pulse_count() return #pulses end

    local function draw_pulses()
        if #pulses == 0 then return end
        local now = core.time()
        local keep = 1
        for i = 1, #pulses do
            local p = pulses[i]
            local t = (now - p.born) / p.life
            if t < 1 then
                pulses[keep] = p
                keep = keep + 1
                local pos = p.at
                if p.unit then pos = position_of(p.at) end
                if pos then
                    local step = math.max(1, floor((1 - t) * 10 + 0.5))
                    M.ring_3d(pos, p.r0 + (p.r1 - p.r0) * t, 1, faded(p.col, step),
                        { bg = faded(p.col, math.max(1, floor(step / 3))), inner = p.inner, outer = 1.0, layer = p.layer })
                end
            end
        end
        for i = #pulses, keep, -1 do pulses[i] = nil end
    end

    --- A cone in world space, from a point towards another.
    ---@param from vec3
    ---@param towards vec3
    ---@param radius number
    ---@param degrees number
    ---@param col color
    ---@param opts? { layer?: integer, fade?: number, droppable?: boolean }
    function M.cone_3d(from, towards, radius, degrees, col, opts)
        opts = opts or {}
        if not from or not towards then return end
        if not M.is_visible(from) then
            stats.culled = stats.culled + 1
            return
        end
        local fade = opts.fade
        M.submit(opts.layer or M.LAYER.DANGER, function()
            core.graphics.cone_3d(from, towards, radius, degrees, col, fade)
        end, opts.droppable)
    end

    --- A closed ring of world-space points. One ring per call: the native
    --- triangulator ear-clips the list, so two loops concatenated come out as
    --- garbage rather than as two shapes.
    ---@param points vec3[] Maximum 256.
    ---@param col color
    ---@param opts? { layer?: integer, filled?: boolean, thickness?: number, fade?: number, droppable?: boolean }
    function M.polygon_3d(points, col, opts)
        opts = opts or {}
        if not points or #points < 3 then return end

        local any = false
        for i = 1, #points do
            if M.is_visible(points[i]) then
                any = true
                break
            end
        end
        if not any then
            stats.culled = stats.culled + 1
            return
        end

        local filled = opts.filled == true
        local thickness = opts.thickness or 2
        local fade = opts.fade or 2
        M.submit(opts.layer or M.LAYER.WORLD, function()
            core.graphics.render_polygon_3d(points, col, filled, thickness, fade)
        end, opts.droppable)
    end

    --- A polyline through world positions, optionally dashed.
    ---
    --- WHY A PATH AND NOT A LINE: a single line between two points at
    --- different elevations spends most of its length underground. A caller
    --- that samples terrain height gets a line that follows the hill, and it
    --- should not pay a queue entry per segment to do it -- the segments of
    --- one path can never be usefully separated by another plugin's layer, so
    --- they go out as one submission.
    ---
    --- Dashes are measured in WORLD units along the path, not per segment, so
    --- the pattern stays even across segments of different lengths and does
    --- not bunch up where the ground is rough.
    ---@param points vec3[] In order. Fewer than two draws nothing.
    ---@param col color
    ---@param opts? { layer?: integer, thickness?: number, fade?: number, dash?: number, gap?: number, droppable?: boolean }
    function M.path_3d(points, col, opts)
        opts = opts or {}
        if not points or #points < 2 then return end

        local any = false
        for i = 1, #points do
            if M.is_visible(points[i]) then
                any = true
                break
            end
        end
        if not any then
            stats.culled = stats.culled + 1
            return
        end

        local thickness = opts.thickness or 2.0
        local fade = opts.fade or 1.0
        local dash = opts.dash
        local gap = opts.gap or dash

        if not dash or dash <= 0 then
            M.submit(opts.layer or M.LAYER.WORLD, function()
                for i = 1, #points - 1 do
                    core.graphics.line_3d(points[i], points[i + 1], col, thickness, fade)
                end
            end, opts.droppable)
            return
        end

        -- Walk the path once and cut it into drawn pieces. Done here rather
        -- than in the closure so the arithmetic happens once per submission
        -- instead of once per paint, and so the closure holds finished points.
        local pieces = {}
        local travelled = 0
        local period = dash + gap

        for i = 1, #points - 1 do
            local a, b = points[i], points[i + 1]
            local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
            local length = math.sqrt(dx * dx + dy * dy + dz * dz)
            if length > 0 then
                local walked = 0
                -- A segment of this length holds at most this many dashes and
                -- gaps. The walk advances by float arithmetic, and a step that
                -- rounds to nothing would otherwise spin here for ever; the
                -- cap turns that into a segment that ends a dash early.
                local steps_left = math.ceil(length / period) * 2 + 4
                while walked < length and steps_left > 0 do
                    steps_left = steps_left - 1
                    local phase = (travelled + walked) % period
                    if phase < dash then
                        -- Inside a dash: draw until the dash ends or the
                        -- segment does, whichever comes first.
                        local run = math.min(dash - phase, length - walked)
                        local t0 = walked / length
                        local t1 = (walked + run) / length
                        pieces[#pieces + 1] = {
                            vec3(a.x + dx * t0, a.y + dy * t0, a.z + dz * t0),
                            vec3(a.x + dx * t1, a.y + dy * t1, a.z + dz * t1),
                        }
                        walked = walked + run
                    else
                        walked = walked + math.min(period - phase, length - walked)
                    end
                end
                travelled = travelled + length
            end
        end

        if #pieces == 0 then return end

        M.submit(opts.layer or M.LAYER.WORLD, function()
            for i = 1, #pieces do
                core.graphics.line_3d(pieces[i][1], pieces[i][2], col, thickness, fade)
            end
        end, opts.droppable)
    end

    ---@param center vec2
    ---@param radius number
    ---@param col color
    ---@param opts? { layer?: integer, filled?: boolean, thickness?: number, droppable?: boolean }
    function M.circle_2d(center, radius, col, opts)
        opts = opts or {}
        local at = to_vec2(center)
        local filled = opts.filled
        local thickness = opts.thickness or 1.0
        M.submit(opts.layer or M.LAYER.HUD, function()
            if filled then
                core.graphics.circle_2d_filled(at, radius, col)
            else
                core.graphics.circle_2d(at, radius, col, thickness)
            end
        end, opts.droppable)
    end

    --- A filled triangle pointing along `angle` (radians, 0 = up, clockwise).
    --- The building block for compass arrows and off-screen indicators.
    ---@param center vec2
    ---@param angle number
    ---@param size number
    ---@param col color
    ---@param opts? { layer?: integer, droppable?: boolean }
    function M.arrow_2d(center, angle, size, col, opts)
        opts = opts or {}
        local at = to_vec2(center)
        local sin, cos = math.sin(angle), math.cos(angle)

        -- Local space: tip ahead, two tails behind and to the sides. Rotated
        -- into screen space here so the closure holds finished points.
        local function rotate(lx, ly)
            return vec2(at.x + lx * cos - ly * sin, at.y + lx * sin + ly * cos)
        end

        local tip   = rotate(0, -size)
        local left  = rotate(-size * 0.62, size * 0.55)
        local right = rotate(size * 0.62, size * 0.55)

        M.submit(opts.layer or M.LAYER.HUD, function()
            core.graphics.triangle_2d_filled(tip, left, right, col)
        end, opts.droppable)
    end

    -- --- screen furniture ---------------------------------------------------

    --- Clips every later submission on the same layer to a rectangle, until
    --- clip_pop. Push and pop must be submitted on the SAME layer and in
    --- order, because the clip stack is unwound during the flush, not now.
    ---@param x number
    ---@param y number
    ---@param w number
    ---@param h number
    ---@param layer? integer
    function M.clip_push(x, y, w, h, layer)
        M.submit(layer or M.LAYER.HUD, function()
            core.graphics.scissor_push(x, y, w, h)
        end)
    end

    ---@param layer? integer
    function M.clip_pop(layer)
        M.submit(layer or M.LAYER.HUD, function()
            core.graphics.scissor_pop()
        end)
    end

    --- Backdrop, border and optional title bar for a HUD panel. Returns the
    --- y of the first content row, so callers stop hand-computing it.
    ---@param origin vec2
    ---@param width number
    ---@param height number
    ---@param opts? { layer?: integer, title?: string, title_color?: color, background?: color, border?: color, size?: number, rounding?: number }
    ---@return number content_y
    function M.panel(origin, width, height, opts)
        opts = opts or {}
        local at = to_vec2(origin)
        local layer = opts.layer or M.LAYER.HUD
        local size = opts.size or 13
        local rounding = opts.rounding or 4
        local background = opts.background or M.theme.backdrop
        local border = opts.border

        M.rect_2d(at, width, height, background,
            { layer = layer, filled = true, rounding = rounding })
        if border then
            M.rect_2d(at, width, height, border,
                { layer = layer, filled = false, rounding = rounding, thickness = 1.0 })
        end

        if opts.title then
            M.text_2d(vec2(at.x + 10, at.y + 6), opts.title,
                opts.title_color or M.theme.text, { layer = layer, size = size })
            return at.y + 6 + size + 6
        end
        return at.y + 6
    end

    --- An arrow at the edge of the screen pointing at something off it.
    ---
    --- Bearing comes from the PLAYER'S facing rather than the camera's, which
    --- the API does not expose. The two agree except while mouse-looking, and
    --- a bearing that is right except mid-swing beats no indicator at all.
    ---@param position vec3 World position of the thing being pointed at.
    ---@param col color
    ---@param opts? { layer?: integer, size?: number, margin?: number, label?: string, text_size?: number, droppable?: boolean }
    ---@return boolean drawn
    function M.edge_indicator(position, col, opts)
        opts = opts or {}
        if not position then return false end

        local player = units.player()
        if not player then return false end

        local origin = player:get_position()
        if not origin then return false end

        local ok, facing = pcall(player.get_rotation, player)
        if not ok or not facing then return false end

        local atan2 = math.atan2 or math.atan
        local bearing = atan2(position.y - origin.y, position.x - origin.x) - facing
        -- Wrapped with a modulo, not a subtract-until loop: a loop never ends
        -- on a facing of inf, and a render job that never ends is the frame.
        bearing = (bearing + math.pi) % (2 * math.pi) - math.pi
        if bearing ~= bearing then return false end

        -- Screen angle, measured from straight up and increasing clockwise:
        -- the world bearing is counter-clockwise from the facing direction.
        local screen_angle = -bearing

        local margin = opts.margin or 60
        local half_w = math.max(1, screen_w * 0.5 - margin)
        local half_h = math.max(1, screen_h * 0.5 - margin)
        local dx, dy = math.sin(screen_angle), -math.cos(screen_angle)

        -- Project the direction onto the rectangle: whichever axis saturates
        -- first decides which edge the arrow sits on.
        local scale = math.huge
        if math.abs(dx) > 1e-4 then scale = math.min(scale, half_w / math.abs(dx)) end
        if math.abs(dy) > 1e-4 then scale = math.min(scale, half_h / math.abs(dy)) end
        if scale == math.huge then return false end

        local cx = screen_w * 0.5 + dx * scale
        local cy = screen_h * 0.5 + dy * scale
        local size = opts.size or 10

        M.arrow_2d(vec2(cx, cy), screen_angle, size, col,
            { layer = opts.layer or M.LAYER.HUD, droppable = opts.droppable })

        if opts.label then
            M.text_2d(vec2(cx, cy + size + 2), opts.label, col, {
                layer = opts.layer or M.LAYER.HUD,
                size = opts.text_size or 11,
                centered = true,
            })
        end
        return true
    end

    -- --- icons --------------------------------------------------------------

    local assets_helper
    do
        local ok, mod = pcall(require, "common/utility/assets_helper")
        if ok then assets_helper = mod end
    end

    --- A spell's own icon art, through the asset registry ("spell:<id>": the
    --- icon's name from Wowhead's tooltip service, the picture from the web
    --- icon cache). Silently draws nothing until the art has arrived -- an
    --- icon is never load-bearing, so a caller must not have to branch on it.
    ---
    --- Until 1.8.3 this went through the loader's icons_helper, which drew
    --- nothing in the game (2026-10-01) and looks spells up on
    --- www.wowhead.com, where every lookup is refused 403 with an [ERR] line
    --- in the console (2026-10-04).
    ---@param spell_id integer
    ---@param position vec2
    ---@param size number
    ---@param tint? color
    ---@param opts? { layer?: integer, droppable?: boolean }
    ---@return boolean available
    -- Never nil: see the note on the same default in the assets service.
    local WHITE = make_color(255, 255, 255, 255)

    function M.spell_icon(spell_id, position, size, tint, opts)
        if type(spell_id) ~= "number" or spell_id <= 0 then return false end
        return M.image("spell:" .. spell_id, position, size, size, tint, opts)
    end

    --- A texture from the loader's own data folder.
    ---@param data_path string
    ---@param position vec2
    ---@param width number
    ---@param height number
    ---@param tint? color
    ---@param opts? { layer?: integer, droppable?: boolean }
    ---@return boolean available
    function M.texture(data_path, position, width, height, tint, opts)
        opts = opts or {}
        if not assets_helper or not data_path then return false end
        tint = tint or WHITE
        local at = to_vec2(position)
        M.submit(opts.layer or M.LAYER.OVERLAY, function()
            pcall(assets_helper.draw_local_texture, assets_helper, data_path, at, width, height, tint)
        end, opts.droppable)
        return true
    end

    --- Any asset by reference -- "spell:2061", "addon:Questie/Icons/available",
    --- "data:icons/x.png", "icon:inv_misc_questionmark", a URL. Queued and
    --- cached by the asset registry; draws nothing until the art is loaded.
    --- Resolved at call time because assets is built after this module.
    ---@param ref string
    ---@param position vec2
    ---@param width number
    ---@param height number
    ---@param tint? color
    ---@param opts? { layer?: integer, droppable?: boolean, uv?: number[] }
    ---@return boolean available
    function M.image(ref, position, width, height, tint, opts)
        local assets = rt.assets
        if not assets or not ref then return false end
        opts = opts or {}
        return assets.submit(ref, to_vec2(position), width, height, tint, {
            layer = opts.layer or M.LAYER.OVERLAY, droppable = opts.droppable, uv = opts.uv,
        })
    end

    -- --- visibility ---------------------------------------------------------

    -- Line of sight is a trace through world geometry, which is the most
    -- expensive question in this module. Cached per unit, and rationed: past
    -- the budget the answer is "visible", because hiding a mark on a frame
    -- that ran out of time is worse than showing one behind a wall.
    --
    -- KEPT FOR HALF A SECOND, NOT ONE FRAME (1.8.0). It only fades a mark, and
    -- re-asked every frame it was ~97% of every ray the plugins cast (the API
    -- recorder: the world layer's fade, up to eight rays a frame). Each ray is
    -- also a chance at the client's own assert: Forever crashed twice in
    -- Forlorn Rowe, Duskwood (2026-10-11, ASSERT(m_data) in M2HitTest.cpp)
    -- inside a ray from the player to a mob, once a mob 58 yards off with
    -- nothing targeted. A mark now fades up to half a second late.
    local LOS_KEEP = 0.5
    local los_cache = {}
    local los_spent = 0
    local los_budget = 12

    ---@param n integer Traces allowed per frame. 0 disables line-of-sight checks.
    function M.set_los_budget(n)
        los_budget = math.max(0, n or 0)
    end

    --- Can the player see this unit?
    ---@param unit game_object
    ---@return boolean
    function M.unit_los(unit)
        if los_budget == 0 then return true end
        local guid, _, valid = ident(unit)
        if not valid then return false end

        local player = units.player()
        if not player then return true end

        local now = core.time()
        local entry = guid and los_cache[guid]
        if entry and (entry.frame == frame_id or (now - entry.at) < LOS_KEEP) then
            return entry.visible
        end

        if los_spent >= los_budget then
            -- Keep the last answer rather than inventing one; a wall does
            -- not move between frames.
            if entry then return entry.visible end
            return true
        end

        los_spent = los_spent + 1
        -- geometry.sight: on Forever a model-free ray, never the native that
        -- asserts there (1.8.0). Unknown paints the mark as visible.
        local geometry = rt.geometry
        local visible
        if geometry and geometry.sight then
            visible = geometry.sight(player, unit) ~= false
        else
            local ok, v = pcall(core.graphics.is_line_of_sight, player, unit)
            visible = ok and v or false
        end
        if guid then los_cache[guid] = { frame = frame_id, at = now, visible = visible } end
        return visible
    end

    --- Line of sight between two arbitrary units. Not cached: the pair is not
    --- a stable key and callers ask about a handful at most.
    ---@param from game_object
    ---@param to game_object
    ---@return boolean
    function M.los(from, to)
        if not from or not to then return false end
        local geometry = rt.geometry
        if geometry and geometry.sight then return geometry.sight(from, to) ~= false end
        local ok, visible = pcall(core.graphics.is_line_of_sight, from, to)
        return ok and visible or false
    end

    -- --- notifications ------------------------------------------------------

    -- The native call STACKS on a repeated id rather than replacing, so a
    -- caller that fires one from a render job paints a column of identical
    -- toasts in half a second. The dedup window is what makes it safe to call
    -- from the same place the condition is detected.
    local notified_at = {}

    ---@param id string Unique per kind of notification.
    ---@param title string
    ---@param message string
    ---@param duration? number seconds
    ---@param col? color
    ---@param dedup? number Seconds to suppress a repeat of the same id. Default 5.
    ---@return boolean shown
    function M.notify(id, title, message, duration, col, dedup)
        if not id then return false end
        local now = core.time()
        local last = notified_at[id]
        if last and (now - last) < (dedup or 5) then return false end
        notified_at[id] = now

        local ok, shown = pcall(core.graphics.add_notification, id, title, message,
            duration or 4, col or M.theme.warning)
        if not ok then
            log.fmt("error", "notification failed: %s", tostring(shown))
            return false
        end
        return shown == true
    end

    -- --- budget -------------------------------------------------------------

    --- Caps DROPPABLE submissions per frame. 0 removes the cap.
    ---@param n integer
    function M.set_budget(n)
        budget = math.max(0, n or 0)
    end

    -- --- frame lifecycle ----------------------------------------------------

    --- Starts a frame. Registered first in the render phase.
    function M._begin_frame()
        frame_id = frame_id + 1
        local ok, size = pcall(core.graphics.get_screen_size)
        if ok and size then
            screen_w, screen_h = size.x, size.y
        end
        stats.submitted, stats.culled, stats.painted, stats.dropped = 0, 0, 0, 0
        los_spent = 0

        -- The per-guid caches are stamped with the frame they were filled on,
        -- so a stale entry is never READ -- but nothing removes the row for a
        -- unit that is gone, and a long session walks past a lot of units.
        -- Dropping both wholesale on a cadence costs one frame's re-reads.
        if frame_id % 600 == 0 then
            attach_cache = {}
            head_cache = {}
            los_cache = {}
            w2s_cache = {}
            height_cache = {}
        end
    end

    local function paint(bucket)
        for j = 1, #bucket do
            -- One bad primitive must not cost the rest of the frame.
            local ok, err = pcall(bucket[j])
            if ok then
                stats.painted = stats.painted + 1
            else
                log.fmt("error", "draw call failed: %s", tostring(err))
            end
        end
    end

    --- Paints everything submitted this frame, in layer order, then clears.
    --- The screen UI is handed to the window pass instead while it runs.
    --- Registered last in the render phase.
    function M._flush()
        draw_pulses()
        -- The last hand-off goes first: a frame with no UI leaves none up.
        for i = ui_n, 1, -1 do ui_buckets[i] = nil end
        ui_n = 0
        window_passes = 0
        local defer = M.over_game and window_frame ~= nil and frame_id - window_frame <= WINDOW_GRACE
        window_stats.pass = defer and "window" or "render"
        if #layers_used == 0 then return end

        table.sort(layers_used)

        for i = 1, #layers_used do
            local layer = layers_used[i]
            local bucket = queue[layer]
            if bucket then
                if defer and layer >= UI_BAND then
                    ui_n = ui_n + 1
                    ui_buckets[ui_n] = bucket
                else
                    paint(bucket)
                end
            end
        end

        for i = 1, #layers_used do
            queue[layers_used[i]] = nil
        end
        for i = #layers_used, 1, -1 do
            layers_used[i] = nil
        end
    end

    --- Paints the screen UI the last flush handed over. Registered on the
    --- native window pass.
    function M._flush_window()
        if window_frame == nil then
            log.fmt("info", "window pass found: the screen UI paints over the game's frames")
        end
        window_frame = frame_id
        window_passes = window_passes + 1
        window_stats.window_calls = window_stats.window_calls + 1
        if window_passes > WINDOW_STALE or ui_n == 0 then return end
        window_stats.window_painted = window_stats.window_painted + 1
        for i = 1, ui_n do paint(ui_buckets[i]) end
    end

    function M.stats()
        return {
            submitted   = stats.submitted,
            culled      = stats.culled,
            painted     = stats.painted,
            dropped     = stats.dropped,
            budget      = budget,
            los_spent   = los_spent,
            screen_w    = screen_w,
            screen_h    = screen_h,
            cached_w2s  = util.count(w2s_cache),
            -- "window" while the screen UI paints over the game's frames
            ui_pass     = window_stats.pass,
            over_game   = M.over_game,
            window_calls = window_stats.window_calls,
            window_painted = window_stats.window_painted,
        }
    end

    return M
end

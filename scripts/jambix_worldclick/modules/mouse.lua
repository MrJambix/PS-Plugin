-- World Click to Move / mouse -- telling a click on the world from everything
-- else the mouse button does.
--
-- The button is read every frame (core.input.is_key_pressed, the same read
-- JCore's windows make). A click is a press and a release:
--
--   * released within CLICK_MAX s. Held longer, the button turns the camera
--     (left) or you (right), and nothing is walked to;
--   * with your facing turned less than TURN_MAX on the way. A right-drag
--     turns you, and a quick flick of one is still a turn, not a click;
--   * not over a JCore window or the loader's menu, not while you type, and
--     with the modifier held when one is chosen.
--
-- WHAT A CLICK IS ON, in this order:
--   1. the minimap, once it has been found (minimap.lua): the spot it shows;
--   2. nothing while the world map is open: it covers the world;
--   3. a thing: the game's mouseover, else a node, corpse or npc near the
--      cursor on screen (pick.lua);
--   4. the ground under the cursor (ground.lua), unless the game named a
--      unit nowhere near the cursor: that is a unit frame, the game's UI.
--
-- THE GROUND AND THE GAME'S UI. A click on an action bar, a bag or a frame
-- is on nothing in the world either, and the loader cannot read the game's
-- frames. But over the world the game takes the press for the camera: it
-- hides the cursor and moves it (JCore saw it leap 1,400 px, and read
-- -FLT_MAX, 2026-10-08). Over its UI it does not. So with "Only when the
-- game takes the click" on (the default), a ground click counts only when
-- the cursor was hidden or moved more than HIDE_PX while the button was
-- down. In game that is unverified: the trace says "stayed put" for each
-- ground click it turned away, and the switch turns the check off.
--
-- THE CURSOR WHILE THE BUTTON IS DOWN IS NOT TRUSTED for where the click is.
-- Over the world the game hides the cursor as soon as a button goes down and
-- moves it about while it turns the camera, and some frames answer
-- -FLT_MAX. So what is under the cursor is taken from the frame BEFORE the
-- press, while it still showed: the game may already have dropped its
-- mouseover by the first frame the button reads down. That frame's
-- mouseover is kept by guid (a game_object is good for one tick) with the
-- cursor position, and re-read at the press.
--
-- FINDING THE MINIMAP takes the next two clicks of either button, wherever
-- they are but on a JCore window or the menu (minimap.lua).

return function(P)
    local ctx, units = P.ctx, P.units
    local input = ctx.input
    local opt, try = P.opt, P.try
    local abs, pi = math.abs, math.pi

    local M = {}

    -- The "button" dropdown, in its order.
    M.BUTTON_NAMES = { "Right-click", "Left-click", "Middle-click" }
    local BUTTONS = { 0x02, 0x01, 0x04 }
    M.RIGHT = 0x02
    -- The "modifier" dropdown, in its order.
    M.MODIFIER_NAMES = { "Nothing", "Shift", "Ctrl", "Alt" }
    local MODIFIERS = { false, 0x10, 0x11, 0x12 }

    local CLICK_MAX = 0.45        -- s: held longer is the camera (or you) turning
    local TURN_MAX = 0.06         -- rad (about 3.5 degrees) your facing may turn during a click
    local HOVER_KEEP = 0.25       -- s the frame-before sample stays good for a press
    local HIDE_PX = 6             -- px the cursor moves while down: the game took the press
    local UNLIMITED = 1e9         -- yd: no limit

    local was_down = false
    local press = nil             -- { at, x, y, facing, thing, why, vk, moved }
    local hover = nil             -- { guid, x, y, at }: the frame before the press
    local stats = { presses = 0, clicks = 0, turns = 0, long = 0, blocked = 0, nothing = 0, ui = 0 }
    local last_why = nil          -- why the latest press came to nothing

    -- Finding the minimap: either button, each its own press and release.
    local cal_down = {}           -- vk -> { x, y } while down
    local CAL_BUTTONS = { 0x01, 0x02 }

    local function now() return core.time() end

    local function cursor()
        local pos = try(input.cursor_position)
        local x, y = pos and tonumber(pos.x), pos and tonumber(pos.y)
        if not x or not y or abs(x) > 1e6 or abs(y) > 1e6 then return nil end
        return x, y
    end

    --- Over one of our own surfaces: the JCore windows or the loader's menu.
    local function over_ui()
        local ui = P.JCore and P.JCore.ui
        if ui and ui.is_cursor_over_ui then
            local ok, yes = pcall(ui.is_cursor_over_ui)
            if ok and yes then return "a JCore window" end
        end
        local m = _G.menu
        if type(m) == "table" and m.is_cursor_over_ui then
            local ok, yes = pcall(m.is_cursor_over_ui, m)
            if ok and yes then return "the menu" end
        end
        return nil
    end

    local function facing()
        local player = units.player()
        return player and tonumber(P.call(player, "get_rotation")) or nil
    end

    local function turned(a, b)
        if not a or not b then return false end
        local d = abs(a - b) % (2 * pi)
        if d > pi then d = 2 * pi - d end
        return d > TURN_MAX
    end

    --- The button the page says to walk on.
    function M.button()
        return BUTTONS[opt("button", 1)] or M.RIGHT
    end

    --- Yards a click may reach: the page's limit, or none.
    function M.range()
        if opt("limit_range", false) then return opt("max_range", 100) + 10 end
        return UNLIMITED
    end

    --- Why a press now is none of ours, or nil.
    local function blocked()
        if not P.enabled() then return "switched off" end
        if try(input.is_typing) == true then return "typing" end
        local mod = MODIFIERS[opt("modifier", 1)]
        if mod and try(input.is_key_pressed, mod) ~= true then
            return M.MODIFIER_NAMES[opt("modifier", 1)] .. " not held"
        end
        local ui = over_ui()
        if ui then return "over " .. ui end
        local player = units.player()
        if not player then return "not in the world" end
        if not opt("in_combat", false) and P.call(player, "is_in_combat") == true then return "in combat" end
        return nil
    end

    --- The frame-before sample's mouseover, again by its guid.
    local function hover_obj(t)
        if not hover or not hover.guid or t - hover.at > HOVER_KEEP then return nil end
        local obj = units.by_guid(hover.guid)
        if obj and P.call(obj, "is_valid") == true then return obj end
        return nil
    end

    local function world_map_open()
        local ui = type(core) == "table" and core.game_ui or nil
        return ui ~= nil and try(ui.is_map_open) == true
    end

    --- What a press at (x, y) is on: a thing (a spot for the minimap and the
    --- ground), or nil and why not.
    local function what_is_at(x, y, t)
        local spot, mwhy, on_minimap = P.minimap.spot_at(x, y)
        if spot then return spot end
        if on_minimap then return nil, mwhy end
        if world_map_open() then return nil, "the world map is open" end
        local thing, why, framed = P.pick.under_cursor(x, y, M.range(), hover_obj(t))
        if thing then return thing end
        if framed or not opt("walk_ground", true) then return nil, why end
        local pos, how = P.ground.at(x, y)
        if not pos then return nil, how end
        return { kind = "spot", how = "ground", name = "the ground", pos = pos, found = how }
    end

    -- --- finding the minimap ----------------------------------------------------------------

    local function calibrate_tick()
        for i = 1, #CAL_BUTTONS do
            local vk = CAL_BUTTONS[i]
            local down = try(input.is_key_pressed, vk) == true
            local held = cal_down[vk]
            if down and not held then
                local x, y = cursor()
                -- A JCore window or the menu (the button that started this): not a point.
                if x and not over_ui() then cal_down[vk] = { x = x, y = y } else cal_down[vk] = false end
            elseif not down and held ~= nil then
                cal_down[vk] = nil
                if held then P.minimap.calibrate_point(held.x, held.y) end
            end
        end
    end

    function M.tick()
        local vk = M.button()
        local t = now()
        local cx, cy = cursor()

        if P.enabled() then P.minimap.wheel(cx, cy) end

        if P.minimap.calibrating() then
            -- These clicks are the minimap's: none of them walks.
            press, was_down = nil, true
            calibrate_tick()
            return
        end
        for k in pairs(cal_down) do cal_down[k] = nil end

        local down = try(input.is_key_pressed, vk) == true

        if not down then
            -- Sample what is under the cursor while it still shows.
            if P.enabled() and cx then
                local obj = P.pick.mouse_over()
                hover = { guid = obj and units.guid(obj) or nil, x = cx, y = cy, at = t }
            end
        end

        if down and not was_down then
            stats.presses = stats.presses + 1
            press = nil
            local why = blocked()
            if why then
                stats.blocked = stats.blocked + 1
                last_why = why
            else
                local x, y = cx, cy
                local fresh = hover and t - hover.at <= HOVER_KEEP
                if fresh then x, y = hover.x, hover.y end
                if x then
                    local thing, why2 = what_is_at(x, y, t)
                    press = { at = t, x = x, y = y, facing = facing(), thing = thing, why = why2, vk = vk,
                        moved = cx == nil or (cx - x) ^ 2 + (cy - y) ^ 2 > HIDE_PX * HIDE_PX }
                else
                    last_why = "no cursor"
                end
            end
        elseif down and press then
            if not press.turned and turned(press.facing, facing()) then press.turned = true end
            if not press.moved and (not cx or (cx - press.x) ^ 2 + (cy - press.y) ^ 2 > HIDE_PX * HIDE_PX) then
                press.moved = true
            end
        elseif not down and was_down and press then
            local p = press
            press = nil
            local thing = p.thing
            if p.turned then
                stats.turns = stats.turns + 1
                last_why = "you turned (a drag)"
            elseif t - p.at > CLICK_MAX then
                stats.long = stats.long + 1
                last_why = "held too long (a drag)"
            elseif not thing then
                stats.nothing = stats.nothing + 1
                last_why = p.why or "nothing there"
            elseif thing.how == "ground" and not p.moved and opt("ground_guard", true) then
                -- The game did not take the press: its own UI (a bar, a bag, a frame).
                stats.ui = stats.ui + 1
                last_why = "the cursor stayed put: a click on the game's own UI, not the ground"
                P.note("ground click at %d, %d not walked: the cursor stayed put (the game's UI?)",
                    math.floor(p.x), math.floor(p.y))
            else
                stats.clicks = stats.clicks + 1
                last_why = nil
                P.on_click(thing, { button = p.vk, game_clicks = p.vk == M.RIGHT and thing.kind ~= "spot" })
            end
        end
        was_down = down
    end

    function M.last_why() return last_why end
    function M.stats() return stats end
    function M.pressed() return press ~= nil end

    return M
end

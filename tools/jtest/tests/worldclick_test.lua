-- World Click to Move: a click on a thing in the world walks you to it.
--
-- The user, 2026-10-11: "When you Click on a Mob, an item, a Corpser a
-- resource ndoe it basically auto walks you to it". A fake Forever world:
-- you at the origin, a Peacebloom 40 yd east, a hostile wolf, a corpse of
-- yours with loot on it, a friendly npc; a camera looking straight down on
-- you (8 px a yard, up the screen 20 px a yard of height) so every object has
-- a place on screen; the mouse (buttons and the cursor) and the client's
-- mouseover; a fake Sentinel Navigation that walks you at 7 yd/s, or takes
-- the route and never moves you, or is not connected; and the client's own
-- movement (face a point, hold forward).

local mock = require("mock_core")
mock.install()
mock.frame_dt = 0.05
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"

local function assert_eq(got, want, label)
    if got ~= want then error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2) end
end

-- --- the world ------------------------------------------------------------------

local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z or 0 }, V) end
function V.dist_to(a, b) local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z return math.sqrt(dx * dx + dy * dy + dz * dz) end
function V.squared_dist_to(a, b) local d = V.dist_to(a, b) return d * d end
function V.dist_to_ignore_z(a, b) local dx, dy = a.x - b.x, a.y - b.y return math.sqrt(dx * dx + dy * dy) end
function V.squared_dist_to_ignore_z(a, b) local d = V.dist_to_ignore_z(a, b) return d * d end
function V.clone(a) return vec3(a.x, a.y, a.z) end

local function object(fields)
    local obj = {}
    for k, v in pairs(fields) do
        if type(v) == "function" then obj[k] = v else obj[k] = function() return v end end
    end
    return setmetatable(obj, { __index = function() return function() return nil end end })
end

local W = { pos = vec3(0, 0, 0), rot = 0, combat = false, casting = false, hover = nil,
    used = 0, interacted = 0, looted = 0, targeted = nil, loot_count = 0, events = {}, keys = {},
    face = nil, fwd = false, left = false, right = false }

local HERB_AT, WOLF_AT, CORPSE_AT, NPC_AT, NEAR_HERB_AT = vec3(40, 0, 0), vec3(0, 30, 0), vec3(-25, 0, 0),
    vec3(0, -20, 0), vec3(3.5, 0, 0)

local me = object({
    is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001", get_name = "Walker",
    get_level = 30, get_health = 1000, get_max_health = 1000, get_power = 0, get_max_power = 100,
    is_moving = false, is_mounted = false, is_in_combat = function() return W.combat end,
    is_casting_spell = function() return W.casting end, is_channelling_spell = false,
    get_auras = {}, get_buffs = {}, get_debuffs = {},
    get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
    is_player = true, is_unit = true, get_type = 6, get_position = function() return W.pos end,
    get_rotation = function() return W.rot end,
    get_combat_reach = 1.5, get_class = 1, get_race_id = 1, get_loss_of_control_info = { valid = false },
})

local herb = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-1617-0001", get_name = "Peacebloom", is_unit = false,
    is_player = false, get_type = 8, can_be_used = true, get_position = HERB_AT,
})
local near_herb = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-1617-0002", get_name = "Silverleaf", is_unit = false,
    is_player = false, get_type = 8, can_be_used = true, get_position = NEAR_HERB_AT,
})
local wolf_pos = WOLF_AT
local wolf = object({
    is_valid = true, is_dead = false, get_guid = "Creature-0-1-2-3-299-0001", get_name = "Young Wolf",
    get_level = 3, get_health = 100, get_max_health = 100, is_player = false, is_unit = true, get_type = 5,
    get_position = function() return wolf_pos end, is_in_combat = false, get_npc_flags = 0,
    get_auras = {}, get_buffs = {}, get_debuffs = {}, get_combat_reach = 1.0,
})
local corpse = object({
    is_valid = true, is_dead = true, get_guid = "Creature-0-1-2-3-299-0002", get_name = "Young Wolf",
    get_level = 3, get_health = 0, get_max_health = 100, is_player = false, is_unit = true, get_type = 5,
    get_position = CORPSE_AT, has_loot = true, can_be_looted = true, is_in_combat = false,
    get_auras = {}, get_buffs = {}, get_debuffs = {}, get_combat_reach = 1.0,
})
local npc = object({
    is_valid = true, is_dead = false, get_guid = "Creature-0-1-2-3-1234-0003", get_name = "Innkeeper Farley",
    get_level = 30, get_health = 1000, get_max_health = 1000, is_player = false, is_unit = true, get_type = 5,
    get_position = NPC_AT, is_in_combat = false, get_npc_flags = 0x80, get_auras = {}, get_buffs = {},
    get_debuffs = {}, get_combat_reach = 1.0,
})
local MAILBOX_AT, MAGEROYAL_AT = vec3(25, 25, 0), vec3(-20, 20, 0)
local mailbox = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-142075-0004", get_name = "Mailbox", is_unit = false,
    is_player = false, get_type = 19, can_be_used = true, get_position = MAILBOX_AT,
})
local mageroyal = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-1620-0005", get_name = "Mageroyal", is_unit = false,
    is_player = false, get_type = 8, can_be_used = true, get_position = MAGEROYAL_AT,
})
me.can_attack = function(_, other) return other == wolf end
me.is_friend_with = function(_, other) return other == npc end

-- 150 yd east: past the old 100 yd limit.
local FAR_HERB_AT = vec3(150, 0, 0)
local far_herb = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-1617-0006", get_name = "Earthroot", is_unit = false,
    is_player = false, get_type = 8, can_be_used = true, get_position = FAR_HERB_AT,
})

local all = { me, herb, near_herb, wolf, corpse, npc, mailbox, mageroyal, far_herb }
mock.core.object_manager.get_local_player = function() return me end
mock.core.object_manager.get_visible_objects = function() return all end
mock.core.object_manager.get_object_from_guid = function(g)
    for _, o in ipairs(all) do if o.get_guid() == g then return o end end
    return nil
end
mock.core.object_manager.get_mouse_over_object = function() return W.hover end

-- The camera: straight down on you. Objects in `behind` come back mirrored,
-- as w2s answers a point behind the camera.
local behind = {}
local function screen_of(pos)
    local x = 960 + (pos.x - W.pos.x) * 8
    local y = 540 - (pos.y - W.pos.y) * 8 - (pos.z - W.pos.z) * 20
    return x, y
end
mock.core.graphics.w2s = function(pos)
    local x, y = screen_of(pos)
    for _, b in ipairs(behind) do
        if math.abs(pos.x - b.x) < 0.01 and math.abs(pos.y - b.y) < 0.01 then x, y = 1920 - x, 1080 - y end
    end
    return { x = x, y = y }
end

-- The client's movement and the rest of the input path. (JCore takes the
-- movement functions when it loads: set before it does.)
local HELD = { move_forward = "fwd", strafe_left = "left", strafe_right = "right" }
for _, k in ipairs({ "turn_left", "turn_right", "move_forward", "move_backward", "strafe_left", "strafe_right" }) do
    mock.core.input[k .. "_start"] = function()
        W.keys[k] = (W.keys[k] or 0) + 1
        if HELD[k] then W[HELD[k]] = true end
    end
    mock.core.input[k .. "_stop"] = function() if HELD[k] then W[HELD[k]] = false end end
end
mock.core.input.look_at = function(point) W.face = { x = point.x, y = point.y } end
mock.core.input.use_object = function(obj)
    W.used = W.used + 1
    if obj.get_position():dist_to(W.pos) <= 5 then
        if obj == mailbox then
            W.events[#W.events + 1] = { "MAIL_SHOW", {} }
        elseif obj == mageroyal then
            W.events[#W.events + 1] = { "UI_ERROR_MESSAGE", { 50, "Requires Herbalism 50" } }
        else
            W.casting = true
        end
    end
    return false                     -- Forever answers false even when it works
end
mock.core.input.interact_with_object = function() W.interacted = W.interacted + 1 return true end
mock.core.input.set_target = function(obj) W.targeted = obj return true end
mock.core.input.loot_object = function(obj)
    W.looted = W.looted + 1
    if obj.get_position():dist_to(W.pos) <= 5 then
        W.loot_count = 2
        W.events[#W.events + 1] = { "LOOT_OPENED", { false } }
    end
    return true
end
mock.core.input.loot_item = function() if W.loot_count > 0 then W.loot_count = W.loot_count - 1 end end
mock.core.game_ui.get_loot_item_count = function() return W.loot_count end

-- A fake Sentinel Navigation: walks you at 7 yards a second, or not at all.
local nav = { moving = false, target = nil, cb = nil, mode = "moves", up = true, moves = 0, stops = 0 }
_G.SentinelNavClient = { VERSION = "test", client = {
    is_server_available = function() return nav.up end,
    move_to = function(_, target, cb)
        nav.moves = nav.moves + 1
        nav.moving, nav.target, nav.cb = true, target, cb
        return true
    end,
    stop = function()
        nav.stops = nav.stops + 1
        local cb = nav.cb
        nav.moving, nav.cb = false, nil
        if cb then cb(false, "stopped") end
    end,
    replan = function() end,
    is_moving = function() return nav.moving end,
    get_state = function() return nav.moving and "navigating" or "idle" end,
    get_current_path = function() return nav.target and { nav.target } or nil end,
    get_path_index = function() return 1 end,
} }

local WC
local traces = {}               -- the plugin's "world click:" lines, as the recorder gets them
local function run(seconds)
    local n = math.max(1, math.floor(seconds / mock.frame_dt + 0.5))
    for _ = 1, n do
        if W.face and (W.fwd or W.left or W.right) then
            local dx, dy = W.face.x - W.pos.x, W.face.y - W.pos.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 0.01 then
                local step = math.min(d, 7 * mock.frame_dt)
                if W.fwd then W.pos = vec3(W.pos.x + dx / d * step, W.pos.y + dy / d * step, W.pos.z) end
            end
        end
        if nav.moving and nav.target and nav.mode == "moves" then
            local dx, dy = nav.target.x - W.pos.x, nav.target.y - W.pos.y
            local d = math.sqrt(dx * dx + dy * dy)
            local step = 7 * mock.frame_dt
            if d <= step then
                W.pos = vec3(nav.target.x, nav.target.y, W.pos.z)
                nav.moving = false
                local cb = nav.cb
                nav.cb = nil
                if cb then cb(true) end
            else
                W.pos = vec3(W.pos.x + dx / d * step, W.pos.y + dy / d * step, W.pos.z)
            end
        end
        mock.frame(1)
        if #W.events > 0 then
            local evs = W.events
            W.events = {}
            for _, e in ipairs(evs) do mock.game_event(e[1], e[2]) end
        end
    end
end

--- A click: the cursor on `obj` on screen (the mouseover naming `hover`,
--- `obj` by default), the button down for `hold` s, then up.
local function click(obj, opts)
    opts = opts or {}
    local vk = opts.vk or 0x02
    local x, y
    if opts.at then x, y = opts.at[1], opts.at[2] else x, y = screen_of(obj.get_position()) end
    mock.move(x, y - 10)             -- on its body, a little above its feet
    if opts.hover ~= nil then W.hover = opts.hover or nil else W.hover = obj end
    run(0.1)                         -- the cursor shows over it a moment
    mock.press(vk)
    if opts.drop_hover then W.hover = nil end
    -- Over the world the game hides the cursor while the button is down.
    if opts.hide then mock.move(-3.4e38, -3.4e38) end
    run(mock.frame_dt)               -- the press is read
    if opts.turn then W.rot = W.rot + opts.turn end
    run((opts.hold or 0.1) - mock.frame_dt)
    if opts.hide then mock.move(x, y - 10) end
    mock.release(vk)
    run(0.1)
    W.hover = nil
end

local function reset(at)
    if WC and WC.walk.active() then WC.walk.cancel("test reset") end
    run(0.2)
    W.pos, W.rot = at or vec3(0, 0, 0), 0
    W.casting, W.combat, W.targeted, W.loot_count = false, false, nil, 0
    W.fwd, W.left, W.right, W.face = false, false, false, nil
    nav.mode, nav.up, nav.moving, nav.target, nav.cb = "moves", true, false, nil, nil
    wolf_pos = WOLF_AT
    mock.keys = {}
    if WC then
        -- A test that failed half way must not leave its settings to the next.
        WC.menu:set("button", 1)
        WC.menu:set("modifier", 1)
        WC.menu:set("enemy_reach", 1)
    end
    run(0.3)
end

local function fail_on_errors(label)
    if #mock.errors > 0 then error(label .. ":\n" .. mock.error_text()) end
end

local function trace_has(text)
    for i = #traces, 1, -1 do
        if traces[i]:find(text, 1, true) then return traces[i] end
    end
    return nil
end

local T = {}

T[#T + 1] = { "boots on JCore with its page and nothing walking", function()
    require("jcore/main")
    require("jambix_worldclick/main")
    WC = _G.JambixWorldClick
    WC.ctx.on("jcore.recorder.trace", function(text) traces[#traces + 1] = tostring(text) end)
    run(1)
    fail_on_errors("boot")
    assert(WC and WC.walk and WC.mouse and WC.pick, "the public table")
    assert_eq(WC.opt("enabled", nil), true, "on by default")
    assert_eq(WC.opt("button", nil), 1, "right-click by default")
    assert_eq(WC.walk.active(), false, "not walking")
    mock.menu:render_titles()
    assert_eq(#mock.menu.title_errors, 0, "the live lines render: " .. table.concat(mock.menu.title_errors, "; "))
end }

T[#T + 1] = { "a right-click on a herb 40 yd off walks you there with Sentinel and gathers it", function()
    reset()
    click(herb)
    fail_on_errors("click")
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    assert_eq(nav.moves, 1, "one route asked of Sentinel")
    assert(nav.target and math.abs(nav.target.x - 40) < 0.01, "to the herb")
    run(8)
    fail_on_errors("walk")
    assert(W.pos:dist_to(HERB_AT) <= 4.0, "there: " .. W.pos.x)
    assert_eq(W.used, 1, "used once")
    assert_eq(WC.walk.active(), false, "done")
    assert(trace_has("gathering"), "said it is gathering")
    assert(not nav.moving and not W.fwd, "standing still")
    assert_eq(WC.walk.stats().by_nav, 1, "by Sentinel")
end }

T[#T + 1] = { "a herb already in the game's reach is the game's own click: nothing walks", function()
    reset()
    local used, moves = W.used, nav.moves
    click(near_herb)
    run(1)
    assert_eq(WC.walk.active(), false, "no walk")
    assert_eq(nav.moves, moves, "no route")
    assert_eq(W.used, used, "no second press on top of the game's")
    assert(WC.last_click and WC.last_click.text:find("game's own click", 1, true), "said why")
end }

T[#T + 1] = { "a held button is a camera turn, and a quick right-drag that turns you is too", function()
    reset()
    local moves = nav.moves
    click(herb, { hold = 0.8 })
    assert_eq(WC.walk.active(), false, "held: no walk")
    assert(tostring(WC.mouse.last_why()):find("held too long", 1, true), "held: " .. tostring(WC.mouse.last_why()))
    click(herb, { turn = 0.5 })
    assert_eq(WC.walk.active(), false, "turned: no walk")
    assert(tostring(WC.mouse.last_why()):find("turned", 1, true), "turned: " .. tostring(WC.mouse.last_why()))
    assert_eq(nav.moves, moves, "no route either time")
end }

T[#T + 1] = { "a click over a JCore window is the window's", function()
    reset()
    local ui = _G.JCore.ui
    local was = ui.is_cursor_over_ui
    ui.is_cursor_over_ui = function() return true end
    click(herb)
    ui.is_cursor_over_ui = was
    assert_eq(WC.walk.active(), false, "no walk")
    assert(tostring(WC.mouse.last_why()):find("JCore window", 1, true), "said so: " .. tostring(WC.mouse.last_why()))
end }

T[#T + 1] = { "a unit frame names the wolf, but the cursor is nowhere near it: nothing walks", function()
    reset()
    click(wolf, { at = { 120, 60 } })   -- top-left, where a target frame sits
    assert_eq(WC.walk.active(), false, "no walk")
    assert(tostring(WC.mouse.last_why()):find("not under the cursor", 1, true),
        "said why: " .. tostring(WC.mouse.last_why()))
end }

T[#T + 1] = { "the mouseover gone by the press: the frame before's is used", function()
    reset()
    click(herb, { drop_hover = true })
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(8)
    assert(W.pos:dist_to(HERB_AT) <= 4.0, "there")
end }

T[#T + 1] = { "no mouseover at all: the herb nearest the cursor on screen is taken", function()
    reset()
    click(herb, { hover = false })
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    assert_eq(WC.walk.target().how, "near", "picked by the cursor's nearness")
    WC.walk.cancel("enough")
end }

T[#T + 1] = { "a corpse behind the camera is not picked by its mirrored place on screen", function()
    reset()
    behind[1] = CORPSE_AT
    local mx, my = screen_of(CORPSE_AT)
    click(corpse, { hover = false, at = { 1920 - mx, 1080 - my + 10 } })
    behind[1] = nil
    assert_eq(WC.walk.active(), false, "no walk")
end }

T[#T + 1] = { "a hostile mob: walked to melee range, following it as it moves, then targeted", function()
    reset()
    click(wolf)
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(1.5)
    wolf_pos = vec3(10, 30, 0)        -- it wanders 10 yd east
    local moves = nav.moves
    run(1.5)
    assert(nav.moves > moves, "a new route to where it is now")
    run(6)
    fail_on_errors("mob")
    assert(W.pos:dist_to(wolf_pos) <= 3.6, "in melee: " .. W.pos:dist_to(wolf_pos))
    assert_eq(W.targeted, wolf, "targeted")
    assert_eq(W.interacted, 0, "not attacked (the switch is off)")
    assert_eq(WC.walk.active(), false, "done")
end }

T[#T + 1] = { "a hostile mob at casting range: walked to 28 yd and no nearer", function()
    reset()
    WC.menu:set("enemy_reach", 3)
    W.pos = vec3(0, -30, 0)           -- 60 yd from the wolf
    run(0.2)
    click(wolf)
    assert(WC.walk.active(), "walking")
    run(8)
    local d = W.pos:dist_to(WOLF_AT)
    assert(d <= 28.5 and d >= 24, "stopped at casting range: " .. d)
    -- At 20 yd, a right-click is the game's own (an Auto Shot, a pull).
    W.pos = vec3(0, 10, 0)
    run(0.2)
    click(wolf)
    assert_eq(WC.walk.active(), false, "in range: the game's click")
    WC.menu:set("enemy_reach", 1)
end }

T[#T + 1] = { "a corpse of yours: walked to, opened the Forever way, its window taken", function()
    reset()
    click(corpse)
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(8)
    fail_on_errors("corpse")
    assert(W.pos:dist_to(CORPSE_AT) <= 2.0, "beside it: " .. W.pos:dist_to(CORPSE_AT))
    assert(W.looted >= 1, "opened")
    assert_eq(W.loot_count, 0, "every slot taken")
    assert_eq(WC.walk.active(), false, "done")
    assert(trace_has("looted"), "said looted")
end }

T[#T + 1] = { "a friendly npc: walked to and talked to", function()
    reset()
    local talks = W.interacted
    click(npc)
    run(6)
    assert(W.pos:dist_to(NPC_AT) <= 3.5, "beside them")
    assert_eq(W.interacted, talks + 1, "talked once")
end }

T[#T + 1] = { "a mailbox: walked to and used once, its window is enough", function()
    reset()
    local used = W.used
    click(mailbox)
    run(8)
    fail_on_errors("mailbox")
    assert(W.pos:dist_to(MAILBOX_AT) <= 4.0, "beside it")
    assert_eq(W.used, used + 1, "used once, not pressed again")
    assert_eq(WC.walk.last().text, "opened", "opened")
end }

T[#T + 1] = { "a herb you lack the skill for: the game's error ends it after one press", function()
    reset()
    local used = W.used
    click(mageroyal)
    run(8)
    fail_on_errors("skill")
    assert_eq(W.used, used + 1, "pressed once")
    assert(WC.walk.last().text:find("Requires Herbalism 50", 1, true), "said the game's words: " .. WC.walk.last().text)
    assert_eq(WC.walk.active(), false, "done")
end }

T[#T + 1] = { "Sentinel takes the route and never moves you: dropped, and walked straight at it", function()
    reset()
    nav.mode = "never"
    click(herb)
    assert(WC.walk.active(), "walking")
    run(12)
    fail_on_errors("never moves")
    assert(W.pos:dist_to(HERB_AT) <= 4.0, "there all the same: " .. W.pos.x)
    assert(WC.walk.stats().nav_drops >= 1, "Sentinel dropped")
    assert(W.casting, "gathering")
    assert(not W.fwd, "forward let go")
end }

T[#T + 1] = { "Sentinel not connected: near is walked straight at, far is refused and said", function()
    reset()
    nav.up = false
    W.pos = vec3(-30, 0, 0)            -- the herb 70 yd off
    run(0.2)
    click(herb)
    assert_eq(WC.walk.active(), false, "70 yd: refused")
    assert(WC.last_click and WC.last_click.text:find("not connected", 1, true), "said why")
    W.pos = vec3(20, 0, 0)             -- 20 yd off
    run(0.2)
    click(herb)
    assert(WC.walk.active(), "20 yd: walking")
    assert_eq(WC.walk.stats().mode, "line", "straight at it")
    run(5)
    assert(W.pos:dist_to(HERB_AT) <= 4.0, "there")
end }

T[#T + 1] = { "steering (W) stops the walk and lets go of everything", function()
    reset()
    click(herb)
    run(1)
    assert(WC.walk.active(), "walking")
    mock.press(0x57)
    run(0.3)
    mock.release(0x57)
    assert_eq(WC.walk.active(), false, "stopped")
    assert(not nav.moving, "Sentinel stopped")
    assert(WC.walk.last().text:find("you moved", 1, true), "said why")
end }

T[#T + 1] = { "with Shift chosen, a click without Shift does nothing; with it, walks", function()
    reset()
    WC.menu:set("modifier", 2)
    click(herb)
    assert_eq(WC.walk.active(), false, "no Shift: nothing")
    mock.press(0x10)
    click(herb)
    mock.release(0x10)
    assert(WC.walk.active(), "Shift: walking")
    WC.menu:set("modifier", 1)
end }

T[#T + 1] = { "left-click chosen: a node in reach is used at once, with no walk", function()
    reset()
    WC.menu:set("button", 2)
    local used, moves = W.used, nav.moves
    click(near_herb, { vk = 0x01 })
    run(0.5)
    assert_eq(nav.moves, moves, "no route")
    assert_eq(W.used, used + 1, "used")
    WC.menu:set("button", 1)
end }

T[#T + 1] = { "in combat: no walk unless \"Also in combat\" is on, and combat stops one", function()
    reset()
    W.combat = true
    click(herb)
    assert_eq(WC.walk.active(), false, "in combat: nothing")
    W.combat = false
    click(herb)
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    W.combat = true
    run(0.3)
    assert_eq(WC.walk.active(), false, "combat stopped it")
    W.combat = false
    fail_on_errors("combat")
end }

-- --- 1.1.0: as far as you like, any npc, the ground, the minimap ----------------------
--
-- The user, 2026-10-11: "world click to move should be as far as I
-- ant...should allow me to click the minimap and also do that Should be any
-- NPC should also be a click on the ground".

-- The ground: flat, at z 0 (0.01: the client answers 0 for a miss). A probe
-- from below it finds nothing.
mock.core.get_height_for_position = function(p, o)
    local up = type(o) == "table" and tonumber(o.probe_up) or 2
    if p.z + up >= 0.01 then return 0.01 end
    return 0
end
local map_open = false
mock.core.game_ui.is_map_open = function() return map_open end

--- Where on the ground the cursor at (sx, sy) is, by the test camera.
local function ground_of(sx, sy)
    return (sx - 960) / 8 + W.pos.x, (540 - sy) / 8 + W.pos.y
end

local function reset2()
    reset()
    map_open = false
    WC.menu:set("limit_range", false)
    WC.menu:set("walk_ground", true)
    WC.menu:set("ground_guard", true)
    WC.menu:set("mm_on", true)
    WC.menu:set("mm_zoom", 1)
    WC.menu:set("mm_rotate", false)
    run(0.1)
end

T[#T + 1] = { "no distance limit by default: a herb 150 yd off is walked to; with the limit on, it is not", function()
    reset2()
    click(far_herb)
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(0.2)                         -- the walk's tick asks Sentinel
    assert(nav.target and math.abs(nav.target.x - 150) < 0.01, "to the far herb")
    WC.walk.cancel("enough")
    WC.menu:set("limit_range", true)
    click(far_herb)
    assert_eq(WC.walk.active(), false, "limit on: no walk")
    assert(WC.last_click and WC.last_click.text:find("yd away; the limit is 100", 1, true), "said why: "
        .. tostring(WC.last_click and WC.last_click.text))
    WC.menu:set("limit_range", false)
end }

T[#T + 1] = { "any npc: one the mouseover does not name is picked by the cursor on its body", function()
    reset2()
    local talks = W.interacted
    click(npc, { hover = false })
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    assert_eq(WC.walk.target().how, "near", "picked by the cursor's nearness")
    assert_eq(WC.walk.target().kind, "npc", "an npc")
    run(6)
    assert(W.pos:dist_to(NPC_AT) <= 3.5, "beside them")
    assert_eq(W.interacted, talks + 1, "talked once")
end }

T[#T + 1] = { "a click on the ground walks you to that spot, and nothing is done there", function()
    reset2()
    local used, talks, looted = W.used, W.interacted, W.looted
    local sx, sy = 896, 476          -- 8 yd west, 8 yd north on the test camera (the click is 10 px up)
    local gx, gy = ground_of(sx, sy - 10)
    click(nil, { at = { sx, sy }, hover = false, hide = true })
    fail_on_errors("ground")
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(0.2)
    assert(nav.target and math.abs(nav.target.x - gx) < 0.3 and math.abs(nav.target.y - gy) < 0.3,
        string.format("to the spot (%.1f, %.1f): %s, %s", gx, gy, tostring(nav.target and nav.target.x),
            tostring(nav.target and nav.target.y)))
    assert_eq(WC.walk.target().kind, "spot", "a spot")
    assert(trace_has("the ground (spot)"), "said so in the trace")
    run(5)
    fail_on_errors("ground walk")
    assert_eq(WC.walk.active(), false, "done")
    assert(math.sqrt((W.pos.x - gx) ^ 2 + (W.pos.y - gy) ^ 2) <= 3.0, "there")
    assert_eq(WC.walk.last().text, "there", "said there")
    assert_eq(W.used + W.interacted + W.looted, used + talks + looted, "pressed nothing")
end }

T[#T + 1] = { "a ground click where the cursor stayed put (a bar, a bag) walks nothing; the switch allows it", function()
    reset2()
    local moves = nav.moves
    click(nil, { at = { 896, 476 }, hover = false })
    assert_eq(WC.walk.active(), false, "no walk")
    assert_eq(nav.moves, moves, "no route")
    assert(tostring(WC.mouse.last_why()):find("stayed put", 1, true), "said why: " .. tostring(WC.mouse.last_why()))
    assert(trace_has("stayed put"), "said so in the trace")
    WC.menu:set("ground_guard", false)
    click(nil, { at = { 896, 476 }, hover = false })
    assert(WC.walk.active(), "guard off: walking: " .. tostring(WC.mouse.last_why()))
    WC.walk.cancel("enough")
    WC.menu:set("ground_guard", true)
end }

T[#T + 1] = { "a ground click beside a mob walks to the ground, not the mob; ground off walks nothing", function()
    reset2()
    -- 4 yd south of the wolf's feet: 32 px below them on screen.
    local wx, wy = screen_of(WOLF_AT)
    click(nil, { at = { wx, wy + 42 }, hover = false, hide = true })
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    assert_eq(WC.walk.target().kind, "spot", "the ground")
    WC.walk.cancel("enough")
    WC.menu:set("walk_ground", false)
    click(nil, { at = { 896, 476 }, hover = false, hide = true })
    assert_eq(WC.walk.active(), false, "ground off: no walk")
    WC.menu:set("walk_ground", true)
end }

T[#T + 1] = { "a unit frame's click is the game's UI: never a ground click", function()
    reset2()
    click(wolf, { at = { 120, 60 }, hide = true })
    assert_eq(WC.walk.active(), false, "no walk")
    assert(tostring(WC.mouse.last_why()):find("not under the cursor", 1, true),
        "said why: " .. tostring(WC.mouse.last_why()))
end }

T[#T + 1] = { "the world map open: a click walks nothing", function()
    reset2()
    map_open = true
    click(herb, { hide = true })
    map_open = false
    assert_eq(WC.walk.active(), false, "no walk")
    assert(tostring(WC.mouse.last_why()):find("world map", 1, true), "said why: " .. tostring(WC.mouse.last_why()))
end }

T[#T + 1] = { "the minimap: found by two clicks, then a click on it walks you to the spot it shows", function()
    reset2()
    assert_eq(WC.minimap.set_up(), false, "not found yet")
    local moves = nav.moves
    WC.minimap.start_calibration()
    assert(WC.minimap.status_line():find("MIDDLE", 1, true), "asks for the middle")
    click(nil, { at = { 1300, 810 }, vk = 0x01, hover = false })      -- its middle (1300, 800)
    assert(WC.minimap.status_line():find("EDGE", 1, true), "asks for the edge")
    click(nil, { at = { 1400, 810 }, vk = 0x01, hover = false })      -- its edge, 100 px off
    assert_eq(WC.minimap.set_up(), true, "found")
    assert_eq(WC.opt("mm_x", 0), 1300, "centre x")
    assert_eq(WC.opt("mm_y", 0), 800, "centre y")
    assert_eq(WC.opt("mm_r", 0), 100, "radius")
    assert_eq(nav.moves, moves, "finding it walked nothing")

    -- 50 px right of the middle, all the way out (466.7 yd across): 116.7 yd east.
    click(nil, { at = { 1350, 810 }, hover = false })
    fail_on_errors("minimap")
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(0.2)
    assert(nav.target and math.abs(nav.target.x - 0) < 0.1 and math.abs(nav.target.y + 116.67) < 0.1,
        string.format("116.7 yd east: %s, %s", tostring(nav.target and nav.target.x), tostring(nav.target and nav.target.y)))
    assert(trace_has("the minimap spot"), "said so")
    WC.walk.cancel("enough")

    -- On the rim: its buttons.
    click(nil, { at = { 1398, 810 }, hover = false })
    assert_eq(WC.walk.active(), false, "rim: no walk")
    assert(tostring(WC.mouse.last_why()):find("rim", 1, true), "said why: " .. tostring(WC.mouse.last_why()))
end }

T[#T + 1] = { "the minimap: the wheel over it zooms, and a turning minimap is read the way you face", function()
    reset2()
    WC.menu:set("mm_x", 1300)
    WC.menu:set("mm_y", 800)
    WC.menu:set("mm_r", 100)
    mock.move(1300, 800)
    run(0.1)
    mock.wheel = 120               -- one notch in
    run(mock.frame_dt)
    assert_eq(WC.minimap.zoom(), 1, "zoomed in one level")
    assert(math.abs(WC.minimap.yards_across() - 400) < 0.01, "400 yd across")
    mock.wheel = -240              -- two notches out: no further than all the way out
    run(mock.frame_dt)
    assert_eq(WC.minimap.zoom(), 0, "all the way out")
    mock.move(10, 10)
    mock.wheel = 120               -- off the minimap: the game's own wheel
    run(mock.frame_dt)
    assert_eq(WC.minimap.zoom(), 0, "not over it: unchanged")

    -- Facing west with a turning minimap: 50 px up is 116.7 yd west (+y).
    WC.menu:set("mm_rotate", true)
    W.rot = math.pi / 2
    click(nil, { at = { 1300, 760 }, hover = false })
    assert(WC.walk.active(), "walking: " .. tostring(WC.mouse.last_why()))
    run(0.2)
    assert(nav.target and math.abs(nav.target.x) < 0.1 and math.abs(nav.target.y - 116.67) < 0.1,
        string.format("116.7 yd west: %s, %s", tostring(nav.target and nav.target.x), tostring(nav.target and nav.target.y)))
    WC.walk.cancel("enough")
    WC.menu:set("mm_rotate", false)
    W.rot = 0
    -- Its middle: you are there already.
    click(nil, { at = { 1300, 810 }, hover = false })
    assert_eq(WC.walk.active(), false, "the middle: no walk")
    assert(WC.last_click and WC.last_click.text:find("there already", 1, true), "said why")
    WC.minimap.forget()
    assert_eq(WC.minimap.set_up(), false, "forgotten")
end }

T[#T + 1] = { "the page's five live lines render, the minimap's among them", function()
    mock.menu:render_titles()
    assert_eq(#mock.menu.title_errors, 0, "the live lines render: " .. table.concat(mock.menu.title_errors, "; "))
    fail_on_errors("page")
end }

T[#T + 1] = { "the ground under the cursor through a real perspective camera, a roof and the horizon", function()
    reset2()
    -- A camera 10 yd behind you and 15 up, looking north and down at a
    -- point 10 yd ahead, 800 px focal length. A point behind it comes back
    -- mirrored, as w2s answers one.
    local C = { x = -10, y = 0, z = 15 }
    local fx, fy, fz = 20, 0, -15
    local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
    local f = { x = fx / fl, y = fy / fl, z = fz / fl }
    local r = { x = f.y, y = -f.x, z = 0 }
    local rl = math.sqrt(r.x * r.x + r.y * r.y)
    r = { x = r.x / rl, y = r.y / rl, z = 0 }
    local u = { x = r.y * f.z - r.z * f.y, y = r.z * f.x - r.x * f.z, z = r.x * f.y - r.y * f.x }
    local was_w2s, was_height = mock.core.graphics.w2s, mock.core.get_height_for_position
    mock.core.graphics.w2s = function(p)
        local vx, vy, vz = p.x - C.x, p.y - C.y, p.z - C.z
        local zc = vx * f.x + vy * f.y + vz * f.z
        if math.abs(zc) < 1e-6 then zc = 1e-6 end
        return { x = 960 + 800 * (vx * r.x + vy * r.y + vz * r.z) / zc,
                 y = 540 - 800 * (vx * u.x + vy * u.y + vz * u.z) / zc }
    end
    -- Flat ground at 0.01, and a block 20 to 40 yd north whose roof is at 6.
    mock.core.get_height_for_position = function(p, o)
        local top = p.z + (type(o) == "table" and tonumber(o.probe_up) or 2)
        if p.x > 20 and p.x < 40 and p.y > -10 and p.y < 10 and top >= 6 then return 6 end
        if top >= 0.01 then return 0.01 end
        return 0
    end
    local function screen(x, y, z) local s = mock.core.graphics.w2s({ x = x, y = y, z = z }) return s.x, s.y end
    local ok, err = pcall(function()
        -- Flat ground 8 yd ahead, 3 yd west.
        local spot, how = WC.ground.at(screen(8, 3, 0.01))
        assert(spot, "found: " .. tostring(how))
        assert(math.abs(spot.x - 8) < 0.3 and math.abs(spot.y - 3) < 0.3 and math.abs(spot.z - 0.01) < 0.01,
            string.format("the flat ground: %.2f, %.2f, %.2f", spot.x, spot.y, spot.z))
        assert_eq(how, "from the camera", "the search started at the camera")
        -- The block's roof, 30 yd ahead, 4 yd east.
        spot, how = WC.ground.at(screen(30, -4, 6))
        assert(spot, "found the roof: " .. tostring(how))
        assert(math.abs(spot.x - 30) < 0.3 and math.abs(spot.y + 4) < 0.3 and math.abs(spot.z - 6) < 0.01,
            string.format("the roof: %.2f, %.2f, %.2f", spot.x, spot.y, spot.z))
        -- The ground beyond the block, behind it from here: the roof is what the cursor is on.
        spot = WC.ground.at(screen(50, 0, 0.01))
        assert(spot and spot.z == 6, "the roof in front of the ground behind it: " .. tostring(spot and spot.z))
        local probes = WC.ground.last().probes or 0
        assert(probes > 0 and probes <= 250, "probes kept in bounds: " .. probes)
        -- The sky (the horizon is just above the screen's top).
        local none, why = WC.ground.at(960, -200)
        assert_eq(none, nil, "above the horizon: nothing")
        assert(tostring(why):find("horizon", 1, true) or tostring(why):find("no ground", 1, true), "said why: " .. tostring(why))
    end)
    mock.core.graphics.w2s, mock.core.get_height_for_position = was_w2s, was_height
    if not ok then error(err, 0) end
    fail_on_errors("perspective")
end }

return T

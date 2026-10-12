-- Jambix Market on Forever: the mail run and staying active.
--
-- The user, 2026-10-07: "let's add pathin to Mailbox pick up all the mail and
-- pathing back to the auctioneer without getting stuck anywhere....Also Anti
-- AFK where it wont go 'afk' status"; 2026-10-08: "its thinking its
-- collecting mailbox but it never actually made the movement there". A fake
-- world: you at an auctioneer, a mailbox 50 yards off (with a wall in
-- between, for some tests), a fake Sentinel Navigation that walks you, or
-- takes the route and never moves you (as in the user's game), or is not
-- connected; the client's own movement (face a point, hold forward) that
-- does move you; a mailbox holding money and a COD parcel; and the system
-- messages the client sends when you go Away.

local mock = require("mock_core")
mock.install()
mock.frame_dt = 0.1
package.loaded["common/utility/spell_helper"] = { is_spell_castable = function() return false end }
local bag_helper = { rows = {} }
function bag_helper.get_character_bag_slots(self) return self.rows end
package.loaded["common/utility/inventory_helper"] = bag_helper
package.loaded["common/utility/icons_helper"] = {
    get_spell_icon_name = function() return nil end, draw_spell_icon = function() return false end,
}
mock.game_version = "Forever"
mock.exact_game_version = "wow_forever_us"
mock.core.character.get_realm_name = function() return "Errand Realm" end

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

local W = { pos = vec3(0, 0, 0), combat = false, gold = 1000000, ah_open = false, mail_open = false,
    keys = {}, jumps = 0, used = 0, interacted = 0, events = {},
    face = nil, fwd = false, back = false, left = false, right = false, blocked = false, wall = false }
-- The wall, when up: a block the straight line from the auctioneer to the
-- mailbox runs through; the way around is up the x = 0 side and along y = 30.
local WALL = { x1 = 10, x2 = 30, y1 = 5, y2 = 25 }
local function in_wall(x, y)
    return W.wall and x >= WALL.x1 and x <= WALL.x2 and y >= WALL.y1 and y <= WALL.y2
end
local HOME, MAILBOX_AT, AUCTIONEER_AT = vec3(0, 0, 0), vec3(40, 30, 0), vec3(2, 0, 0)

local me = object({
    is_valid = true, is_dead = false, is_ghost = false, get_guid = "Player-1-0001", get_name = "Trader",
    get_level = 30, get_health = 1000, get_max_health = 1000, get_power = 0, get_max_power = 100,
    is_moving = false, is_mounted = false, is_in_combat = function() return W.combat end,
    is_casting_spell = false, is_channelling_spell = false, get_auras = {}, get_buffs = {}, get_debuffs = {},
    get_active_spell_cast_end_time = 0, get_active_channel_cast_end_time = 0,
    is_player = true, is_unit = true, get_type = 6, get_position = function() return W.pos end,
    get_combat_reach = 1.5, get_rotation = 0, get_class = 1, get_race_id = 1,
    get_loss_of_control_info = { valid = false },
})
local auctioneer = object({
    is_valid = true, is_dead = false, get_guid = "Creature-0-1-2-3-8719-0001", get_name = "",
    get_level = 50, get_health = 5000, get_max_health = 5000, is_player = false, is_unit = true, get_type = 5,
    get_npc_flags = 0x200000, get_npc_id = 8719, get_position = AUCTIONEER_AT, is_in_combat = false,
    get_auras = {}, get_buffs = {}, get_debuffs = {}, get_combat_reach = 1.5,
})
local mailbox = object({
    is_valid = true, get_guid = "GameObject-0-1-2-3-142075-0001", get_name = "Mailbox", get_npc_id = 142075,
    is_unit = false, is_player = false, get_type = 257, is_basic_object = true, can_be_used = true,
    get_position = MAILBOX_AT, get_npc_flags = 0,
})
local all = { me, auctioneer, mailbox }
mock.core.object_manager.get_local_player = function() return me end
mock.core.object_manager.get_visible_objects = function() return all end
mock.core.object_manager.get_object_from_guid = function(g)
    for _, o in ipairs(all) do if o.get_guid() == g then return o end end
    return nil
end
mock.core.inventory.get_gold = function() return W.gold end

-- Movement keys and the rest of the input path, counted. (JCore takes these
-- functions when it loads: set before it does.)
local HELD = { move_forward = "fwd", move_backward = "back", strafe_left = "left", strafe_right = "right" }
for _, k in ipairs({ "turn_left", "turn_right", "move_forward", "move_backward", "strafe_left", "strafe_right" }) do
    mock.core.input[k .. "_start"] = function()
        W.keys[k] = (W.keys[k] or 0) + 1
        if HELD[k] then W[HELD[k]] = true end
    end
    mock.core.input[k .. "_stop"] = function() if HELD[k] then W[HELD[k]] = false end end
end
mock.core.input.look_at = function(point) W.face = { x = point.x, y = point.y } end
mock.core.input.jump = function() W.jumps = W.jumps + 1 end
mock.core.input.use_object = function(obj)
    W.used = W.used + 1
    if obj == mailbox and W.pos:dist_to(MAILBOX_AT) <= 5 then
        W.mail_open = true
        W.events[#W.events + 1] = { "MAIL_SHOW", {} }
    end
    return false                     -- Forever answers false even when it opens
end
mock.core.input.interact_with_object = function(obj)
    W.interacted = W.interacted + 1
    if obj == auctioneer and W.pos:dist_to(AUCTIONEER_AT) <= 5 then
        W.ah_open = true
        W.events[#W.events + 1] = { "AUCTION_HOUSE_SHOW", {} }
    end
    return true
end

-- The auction house: open or shut, and nothing else asked of it here.
mock.core.auction_house = {
    is_auction_house_shown = function() return W.ah_open end,
    is_throttled_message_system_ready = function() return true end,
    replicate_items = function() end, get_num_replicate_items = function() return 0 end,
    send_search_query = function() end, get_num_commodity_search_results = function() return 0 end,
    get_num_item_search_results = function() return 0 end, query_owned_auctions = function() end,
    get_num_owned_auctions = function() return 0 end, get_item_info = function() return {} end,
}

-- The mailbox: two sale mails, a letter with money, and a COD parcel.
local mails = {}
local function fill_mail()
    mails = {
        { subject = "Auction successful: Lion Meat (8)", money = 3000, item_count = 0, cod_amount = 0 },
        { subject = "Auction successful: Rockscale Cod (20)", money = 2660, item_count = 0, cod_amount = 0 },
        { subject = "Hello", money = 500, item_count = 0, cod_amount = 0, sender = "Friend" },
        { subject = "Parcel", money = 0, item_count = 1, cod_amount = 2000, sender = "Seller" },
    }
end
fill_mail()
mock.core.mail = {
    get_num_inbox_items = function() return #mails end,
    get_inbox_header_info = function(i) return mails[i] end,
    take_inbox_money = function(i)
        local m = mails[i]
        if not m then return end
        W.gold = W.gold + m.money
        m.money = 0
        if m.item_count == 0 then table.remove(mails, i) end
    end,
    auto_loot_mail_item = function(i) table.remove(mails, i) end,
}

-- A fake Sentinel Navigation: walks you at 7 yards a second, or not at all.
-- mode: "moves" walks you; "never" takes the route and never moves you.
local nav = { moving = false, target = nil, cb = nil, mode = "moves", up = true, moves = 0, stops = 0, replans = 0 }
_G.SentinelNavClient = { VERSION = "test", client = {
    is_server_available = function() return nav.up end,
    move_to = function(_, target, cb) nav.moves = nav.moves + 1; nav.moving, nav.target, nav.cb = true, target, cb; return true end,
    move_direct = function(_, target, cb) nav.moves = nav.moves + 1; nav.moving, nav.target, nav.cb = true, target, cb; return true end,
    stop = function()
        nav.stops = nav.stops + 1
        local cb = nav.cb
        nav.moving, nav.cb = false, nil
        if cb then cb(false, "stopped") end
    end,
    replan = function() nav.replans = nav.replans + 1 end,
    is_moving = function() return nav.moving end,
    get_state = function() return nav.moving and "navigating" or "idle" end,
    get_current_path = function() return nav.target and { nav.target } or nil end,
    get_path_index = function() return 1 end,
} }

local MK
local function run(seconds)
    local n = math.max(1, math.floor(seconds / mock.frame_dt + 0.5))
    for _ = 1, n do
        -- The client's own movement: facing a point and holding forward,
        -- sidesteps across it; nothing through the wall, nothing when blocked.
        if not W.blocked and W.face and (W.fwd or W.left or W.right) then
            local dx, dy = W.face.x - W.pos.x, W.face.y - W.pos.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 0.01 then
                local ux, uy = dx / d, dy / d
                local mx, my = 0, 0
                if W.fwd then mx, my = mx + ux * 7 * mock.frame_dt, my + uy * 7 * mock.frame_dt end
                if W.left then mx, my = mx - uy * 4 * mock.frame_dt, my + ux * 4 * mock.frame_dt end
                if W.right then mx, my = mx + uy * 4 * mock.frame_dt, my - ux * 4 * mock.frame_dt end
                if W.fwd and d < 7 * mock.frame_dt then mx, my = dx, dy end
                if not in_wall(W.pos.x + mx, W.pos.y + my) then W.pos = vec3(W.pos.x + mx, W.pos.y + my, W.pos.z) end
            end
        end
        -- Sentinel's walk.
        if nav.moving and nav.target and nav.mode == "moves" and not W.blocked then
            local tx, ty = nav.target.x, nav.target.y
            local dx, dy = tx - W.pos.x, ty - W.pos.y
            local d = math.sqrt(dx * dx + dy * dy)
            local stepd = 7 * mock.frame_dt
            if d <= stepd then
                W.pos = vec3(tx, ty, W.pos.z)
                nav.moving = false
                local cb = nav.cb
                nav.cb = nil
                if cb then cb(true) end
            else
                W.pos = vec3(W.pos.x + dx / d * stepd, W.pos.y + dy / d * stepd, W.pos.z)
            end
        end
        -- Walking off closes what was open.
        if W.ah_open and W.pos:dist_to(AUCTIONEER_AT) > 6 then
            W.ah_open = false
            W.events[#W.events + 1] = { "AUCTION_HOUSE_CLOSED", {} }
        end
        if W.mail_open and W.pos:dist_to(MAILBOX_AT) > 6 then
            W.mail_open = false
            W.events[#W.events + 1] = { "MAIL_CLOSED", {} }
        end
        mock.frame(1)
        if #W.events > 0 then
            local evs = W.events
            W.events = {}
            for _, e in ipairs(evs) do mock.game_event(e[1], e[2]) end
        end
    end
end

local function activity_has(text)
    for _, a in ipairs(MK.activity_log()) do
        if a.text:find(text, 1, true) then return a.text end
    end
    return nil
end

local function fail_on_errors(label)
    if #mock.errors > 0 then error(label .. ":\n" .. mock.error_text()) end
end

local T = {}

T[#T + 1] = { "boot at the auctioneer with Auto on and money sold", function()
    require("jcore/main")
    require("jambix_market/main")
    MK = _G.JambixMarket
    run(3)
    W.ah_open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(2)
    MK.menu:set("enabled", true)               -- Market is off at every load
    MK.menu:set("auto_trade", true)
    assert_eq(MK.errands.walking_on(), false, "walking is off until the box is ticked")
    MK.menu:set("mail_runs", true)
    -- An auction of Auto's sold: 95s on its way to the mailbox.
    MK.trader.posts()["777"] = { id = 3731, qty = 8, unit = 12500, t = MK.util.now(), sold = MK.util.now(), deposit = 100 }
    run(1)
    fail_on_errors("boot")
    assert(MK.trader.mail_waiting().total > 90000, "money waiting: " .. MK.trader.mail_waiting().total)
end }

T[#T + 1] = { "the mail run: walks to the mailbox, takes the mail, walks back, opens the auction house", function()
    local gold0 = W.gold
    local went = false
    for _ = 1, 600 do                -- a minute at most to set off (the auction house work first)
        run(0.1)
        if MK.errands.running() then went = true break end
    end
    fail_on_errors("setting off")
    assert(went, "a run started: " .. tostring((MK.errands.status())))
    run(0.3)                         -- the route is asked for on the run's first tick
    assert(nav.target and nav.target.x > 30 and nav.target.y > 20, "walking to the mailbox")
    run(25)                          -- 50 yards at 7 a second, the mail, and back
    fail_on_errors("the run")
    assert(W.used >= 1, "the mailbox was used")
    assert_eq(#mails, 1, "every mail taken but the COD parcel")
    assert_eq(mails[1].subject, "Parcel", "the COD parcel left alone")
    assert_eq(W.gold - gold0, 3000 + 2660 + 500, "the sale money and the letter's")
    assert(W.pos:dist_to(AUCTIONEER_AT) <= 4.5, "back at the auctioneer: " .. W.pos.x .. "," .. W.pos.y)
    assert(W.ah_open, "the auction house open again")
    assert(not MK.errands.running(), "the run is over")
    assert(activity_has("Mail run: done"), "said so")
    assert(activity_has("COD"), "said why the parcel was left")
    assert(not nav.moving, "standing still")
    assert(not W.fwd and not W.left and not W.right, "no key held")
end }

local function log_has(text)
    for _, l in ipairs(MK.errands.log()) do
        if l.text:find(text, 1, true) then return l.text end
    end
    return nil
end

local function next_run(label)
    fill_mail()
    MK.trader.posts()[label] = { id = 3731, qty = 8, unit = 12500, t = MK.util.now(), sold = MK.util.now(),
        deposit = 100 }
    mock.time = mock.time + 31 * 60  -- past the gap between runs, and any pause
    for _ = 1, 600 do
        run(0.1)
        if MK.errands.running() then return true end
    end
    return false
end

T[#T + 1] = { "Sentinel takes the route and never moves you: dropped, and the walk goes on straight", function()
    nav.mode = "never"               -- as in the user's game, 2026-10-08
    local forwards = W.keys.move_forward or 0
    assert(next_run("778"), "a run started")
    run(40)
    fail_on_errors("never moves")
    assert(log_has("Sentinel Navigation dropped: did not move you"), "Sentinel dropped")
    assert((W.keys.move_forward or 0) > forwards, "walked by holding forward")
    assert(activity_has("Mail run: done"), "the run finished: " .. tostring((MK.errands.status())))
    assert_eq(#mails, 1, "the mail taken")
    assert(W.ah_open, "the auction house open again")
    assert(not W.fwd, "standing still")
    nav.mode = "moves"
end }

T[#T + 1] = { "the way you walk is learned, and a run walks it around a wall", function()
    nav.up = false                   -- no Sentinel: the learned way or nothing
    W.wall = true
    -- You walk to the mailbox: up the x = 0 side, along y = 30, and open it.
    local path = {}
    for y = 0, 30, 1 do path[#path + 1] = vec3(0, y, 0) end
    for x = 1, 37, 1 do path[#path + 1] = vec3(x, 30, 0) end
    for _, p in ipairs(path) do
        W.pos = p
        run(0.15)
    end
    mock.core.input.use_object(mailbox)
    run(2)
    assert_eq(#MK.errands.routes(), 1, "the way to the mailbox learned")
    -- And back to the auction house; it opens.
    W.events[#W.events + 1] = { "MAIL_CLOSED", {} }
    for i = #path, 1, -1 do
        W.pos = path[i]
        run(0.15)
    end
    W.pos = vec3(0, 0, 0)
    W.ah_open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(1)
    assert_eq(#MK.errands.routes(), 1, "learned again, not twice")
    -- The straight line is walled off now: without the way you walked, no run.
    local through_corner = math.huge
    assert(next_run("779"), "a run started: " .. tostring((MK.errands.status())))
    for _ = 1, 400 do
        run(0.1)
        through_corner = math.min(through_corner, W.pos:dist_to(vec3(0, 30, 0)))
        if not MK.errands.running() then break end
    end
    fail_on_errors("route")
    assert(log_has("by the way you walked it"), "walked the learned way")
    assert(through_corner < 3, "round the corner of the wall: " .. through_corner)
    assert(activity_has("Mail run: done"), "the run finished: " .. tostring((MK.errands.status())))
    assert_eq(#mails, 1, "the mail taken")
    assert(W.ah_open, "the auction house open again")
end }

T[#T + 1] = { "a mail run that gets stuck jumps, sidesteps, then stops, stands still, and says where", function()
    W.blocked = true                 -- something in the way: nothing moves
    local start = W.pos:clone()
    local jumps = W.jumps
    assert(next_run("780"), "a run started")
    run(30)
    fail_on_errors("stuck")
    assert(not MK.errands.running(), "the run stopped")
    assert(W.jumps - jumps >= 5, "jumped and sidestepped first: " .. (W.jumps - jumps))
    assert(not W.fwd and not W.left and not W.right, "no key held")
    assert(activity_has("Mail run: stuck to the mailbox"), "said why")
    local line = MK.errands.status()
    assert(line and line:find("paused"), "runs pause: " .. tostring(line))
    W.blocked = false
    assert(W.pos:dist_to(start) < 0.01, "it never went anywhere")
end }

T[#T + 1] = { "combat ends a run at once", function()
    assert(next_run("781"), "a run started")
    run(2)
    W.combat = true
    run(1)
    fail_on_errors("combat")
    assert(not MK.errands.running(), "ended")
    assert(not nav.moving and not W.fwd, "standing still")
    assert(activity_has("ended: in combat"), "said why")
    W.combat = false
    -- Walk home for the next test.
    W.pos = vec3(0, 0, 0)
    W.ah_open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(1)
end }

T[#T + 1] = { "box unticked: nothing walks; you open the mailbox and Auto takes the mail", function()
    MK.menu:set("mail_runs", false)
    fill_mail()
    MK.trader.posts()["782"] = { id = 3731, qty = 8, unit = 12500, t = MK.util.now(), sold = MK.util.now(),
        deposit = 100 }
    mock.time = mock.time + 31 * 60
    local moves, forwards = nav.moves, W.keys.move_forward or 0
    for _ = 1, 300 do
        run(0.1)
        assert(not MK.errands.running(), "no run with the box unticked")
    end
    fail_on_errors("unticked")
    assert_eq(nav.moves, moves, "Sentinel never asked")
    assert_eq(W.keys.move_forward or 0, forwards, "never walked")
    local line = MK.errands.status()
    assert(line and line:find("Mail run off", 1, true), "the window says so: " .. tostring(line))
    -- You walk there yourself and open it: Auto takes the mail.
    local gold0 = W.gold
    W.pos = vec3(MAILBOX_AT.x - 2, MAILBOX_AT.y, 0)
    run(0.5)
    mock.core.input.use_object(mailbox)
    run(8)
    fail_on_errors("by hand")
    assert_eq(#mails, 1, "every mail taken but the COD parcel")
    assert(W.gold - gold0 >= 3000 + 2660 + 500, "the money")
    -- And back to the auction house, by hand too.
    W.pos = vec3(0, 0, 0)
    run(0.5)
    W.ah_open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(1)
end }

T[#T + 1] = { "unticking the box mid-run stops the run at once and lets go of every key", function()
    MK.menu:set("mail_runs", true)
    assert(next_run("783"), "a run started")
    run(1.5)
    assert(MK.errands.running(), "walking")
    MK.menu:set("mail_runs", false)
    run(0.5)
    fail_on_errors("unticked mid-run")
    assert(not MK.errands.running(), "stopped")
    assert(not W.fwd and not W.left and not W.right and not nav.moving, "every key let go")
    assert(activity_has("ended: mail runs switched off"), "said why")
    local line = MK.errands.status()
    assert(line and not line:find("paused", 1, true), "no pause: it was switched off, not stuck")
    -- Home for the tests that follow.
    W.pos = vec3(0, 0, 0)
    W.ah_open = true
    mock.game_event("AUCTION_HOUSE_SHOW", {})
    run(1)
end }

T[#T + 1] = { "anti-AFK: a keep-alive every two minutes, and the kind that fails is dropped", function()
    MK.presence.reset()
    local turns = W.keys.turn_left or 0
    run(125)
    fail_on_errors("keep-alive")
    assert((W.keys.turn_left or 0) > turns, "a turn went out")
    assert_eq(MK.presence.state().kind, "turn", "turning first")
    -- The client says Away a minute later: the turn did not reset its clock.
    run(60)
    local sides = W.keys.strafe_left or 0
    local forwards = W.keys.move_forward or 0
    mock.game_event("CHAT_MSG_SYSTEM", { "You are now Away: AFK" })
    run(1)
    assert_eq(MK.presence.state().kind, "step", "a step next")
    assert((W.keys.strafe_left or 0) > sides, "a sidestep, at once")
    assert_eq(W.keys.move_forward or 0, forwards, "never the forward key (it would cut off your own walking)")
    -- Away again right after: the step fails too; the jump is last.
    run(61)
    mock.game_event("CHAT_MSG_SYSTEM", { "You are now Away: AFK" })
    run(1)
    assert_eq(MK.presence.state().kind, "jump", "a jump last")
    run(61)
    local jumps = W.jumps
    mock.game_event("CHAT_MSG_SYSTEM", { "You are now Away: AFK" })
    run(130)
    fail_on_errors("gave up")
    assert_eq(MK.presence.state().kind, nil, "every kind failed")
    assert_eq(W.jumps, jumps, "no more keep-alives once none holds")
    local line = MK.presence.status()
    assert(line and line:find("gave up"), "the window says so: " .. tostring(line))
    MK.presence.reset()
end }

T[#T + 1] = { "anti-AFK: Away with no keep-alive before it says nothing of the kind", function()
    MK.menu:set("auto_trade", false)
    run(1)
    MK.presence.reset()
    MK.menu:set("auto_trade", true)
    mock.game_event("CHAT_MSG_SYSTEM", { "You are now Away: AFK" })   -- idle before Auto started
    run(1)
    assert_eq(MK.presence.state().kind, "turn", "the turn is still the one to try")
    assert(MK.presence.state().sent >= 1, "answered with a keep-alive")
    MK.menu:set("auto_trade", false)
end }

return T

-- Jambix AIO 1.61.0: three things players asked for.
--   * The rogue's Stealth rule follows its "Stealth by itself" setting:
--     Never, Only before an opener (the default), or Before an opener and
--     near enemies (the 1.46.0 rule).
--   * Fishing casts the rank the player has: after Journeyman (75-150) the
--     Apprentice rank the profession call casts is gone and the cast never
--     started. The Apprentice rank keeps the profession call.
--   * 1.65.2: above Apprentice the profession call is never used, not even
--     after a cast by id that started nothing ("Spell not learned" on Forever).
--   * 1.66.1: a catch is the loot window opening after the click, whatever
--     use_object answered and whoever emptied the window; the game's
--     "Inventory is full" after a click stops fishing.
--   * 1.7.5 (after 1.67.1's jump, which never kept Forever's Away off):
--     Jambix Market's keep-alive between casts -- a short turn each way,
--     else a sidestep, else a jump, each judged by "You are now Away".

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}

-- --- the rogue's Stealth by itself ------------------------------------------------

T[#T + 1] = { "rogue: Stealth by itself -- never, only before an opener (default), or near enemies too", function()
    local asked = {}
    local mode = nil
    local H = {
        book = {},
        buff_up = function() return false end,
        buff_remaining = function() return 0 end,
        bursting = function() return false end,
        spread = function() return false end,
        dot_worth_it = function() return false end,
        stealth_wanted = function(_, opts) asked[#asked + 1] = opts or "old rule" return true end,
    }
    local CS = { opt = function(id, default) if id == "stealth_mode" and mode then return mode end return default end }
    package.loaded["jambix_aio/modules/classes/rogue"] = nil
    local def = require("jambix_aio/modules/classes/rogue")({}, H, CS)
    local rule
    for _, r in ipairs(def.profiles.combat.rules) do if r[1] == "Stealth" then rule = r[2] end end
    assert(rule, "the combat profile has a Stealth rule")
    local s = { player = {}, in_combat = false }

    assert_eq(rule(s), true, "default: asks")
    assert_eq(asked[1].engaging, true, "default: only a target the rotation will open on")
    assert_eq(asked[1].no_sneak, true, "default: not for a hostile walked past")
    mode = 3
    rule(s)
    assert_eq(asked[2], "old rule", "near enemies: the 1.46.0 rule")
    mode = 1
    assert_eq(rule(s), false, "never")
    assert_eq(#asked, 2, "never asks at all")
    assert(type(def.settings) == "function", "the Rogue page has the setting")
end }

-- --- fishing: the rank the player has ----------------------------------------------

local function fishing_world(known_ids, book_fishing, setup)
    local W = { calls = {}, clock = 100, handlers = {}, opts = {}, traces = {},
        loot_count = 0, loot_names = {}, objects = {} }
    local known = {}
    for _, id in ipairs(known_ids) do known[id] = true end
    _G.core = {
        time = function() return W.clock end,
        profession = { FISHING = 9, open_profession = function()
            W.calls[#W.calls + 1] = "open_profession"
            return true
        end },
        input = { cast_target_spell = function(id)
            W.calls[#W.calls + 1] = "cast " .. tostring(id)
            return true
        end, close_loot = function() W.calls[#W.calls + 1] = "close" end,
            loot_item = function(i) W.calls[#W.calls + 1] = "loot " .. tostring(i) end,
            jump = function() W.calls[#W.calls + 1] = "jump" end },
        game_ui = {
            get_loot_item_count = function() return W.loot_count end,
            get_loot_item_name = function(i) return W.loot_names[i + 1] end,
            get_loot_is_gold = function() return false end,
        },
        spell_book = { is_spell_known = function(id) return known[id] == true end },
    }
    local player = { get_guid = function() return "Player-1-ME" end }
    for _, m in ipairs({ "is_dead", "is_ghost", "is_in_combat", "is_mounted", "is_moving",
        "is_casting_spell" }) do
        player[m] = function() return false end
    end
    player.is_valid = function() return true end
    player.is_channelling_spell = function() return W.channelling == true end
    player.get_active_channel_spell_id = function() return 7731 end
    W.player = player
    local tick
    local P = {
        ctx = {
            tick = function(fn) tick = fn end,
            every = function() end, render = function() end,
            emit = function(name, text)
                if name == "jcore.recorder.trace" then W.traces[#W.traces + 1] = text end
            end,
            on = function(name, fn) W.handlers[name] = fn end,
            spells = { learned = function(id) return known[id] == true, "known" end },
        },
        log = { fmt = function() end, debug = function() end, info = function() end },
        units = { player = function() return player end, objects = function() return W.objects end },
        actions = {
            perform = function()
                W.calls[#W.calls + 1] = "click"
                return W.click_answer == true, W.click_tried
            end,
            forget = function() end,
        },
        opt = function(id, default)
            if W.opts[id] ~= nil then return W.opts[id] end
            if id == "fish_enabled" then return true end
            return default
        end,
        master_on = function() return true end,
        spellbook = { id = function(name) return name == "Fishing" and book_fishing or nil end },
    }
    if setup then setup(W, P) end
    package.loaded["jambix_aio/modules/fishing"] = nil
    W.fishing = require("jambix_aio/modules/fishing")(P)
    function W.tick() tick() end
    return W
end

T[#T + 1] = { "fishing: Journeyman and up are cast by their own id; the Apprentice rank keeps the profession call", function()
    local W = fishing_world({ 7731 })
    W.tick()
    assert_eq(W.calls[1], "cast 7731", "Journeyman: its own id")
    assert_eq(W.fishing.fishing_rank(), 7731, "the rank found")

    W = fishing_world({ 7731, 7732 })
    W.tick()
    assert_eq(W.calls[1], "cast 7732", "the highest rank known")

    W = fishing_world({ 7620 }, 7620)
    W.tick()
    assert_eq(W.calls[1], "open_profession", "Apprentice: the call that always worked")

    -- Forever (1.61.1): the book holds the classic 7620 AND its own 1240948,
    -- both "Fishing"; 1240948 cast by id starts nothing. Not by name, then.
    W = fishing_world({ 7620, 1240948 }, 1240948)
    W.tick()
    assert_eq(W.calls[1], "open_profession", "Forever's two Fishing spells: the profession call")

    -- Forever after training Journeyman (the 1.65.2 dump): 7731 and Forever's
    -- own 1240959, no 7620.
    W = fishing_world({ 7731, 1240959 }, 1240959)
    W.tick()
    assert_eq(W.calls[1], "cast 7731", "Forever Journeyman: the classic id")

    -- 1.65.2: a cast by id that starts no channel does NOT hand over to the
    -- profession call -- that casts Apprentice, which Journeyman took out of
    -- the book: "Spell not learned". By id again, and four in a row stop
    -- fishing with the client's own words.
    W = fishing_world({ 7731 })
    for n = 1, 4 do
        W.tick()
        assert_eq(W.calls[n], "cast 7731", "cast " .. n .. ": by id, never the profession call")
        W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 50, "Your cast didn't land in fishable water", "ERR_SPELL_FAILED_S" })
        W.clock = W.clock + 2.6
        W.tick()
        W.clock = W.clock + 5
    end
    assert_eq(#W.calls, 4, "nothing else was cast")
    local first = W.traces[1] or ""
    assert(first:find("Fishing 7731 started no channel (1 in a row)", 1, true)
        and first:find("fishable water", 1, true), "the trace says which cast and why: " .. first)
    local stopped = W.fishing.stats().stopped or ""
    assert(stopped:find("fishable water", 1, true), "the stop gives the client's words: " .. stopped)

    -- Red text from before the cast, or long after it, is not ours.
    W = fishing_world({ 7731 })
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 1, "Not enough mana", "ERR_OUT_OF_MANA" })
    W.tick()
    W.clock = W.clock + 2.6
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 1, "Out of range", "ERR_OUT_OF_RANGE" })
    W.tick()
    assert(not (W.traces[1] or ""):find("client says", 1, true), "no stale text: " .. tostring(W.traces[1]))

    -- A rank cast the client did not take is a failed cast too, not a handover.
    W = fishing_world({ 7731 })
    _G.core.input.cast_target_spell = function(id)
        W.calls[#W.calls + 1] = "cast " .. tostring(id)
        return false
    end
    W.tick()
    W.clock = W.clock + 3
    W.tick()
    assert_eq(W.calls[2], "cast 7731", "not issued: by id again")
    assert((W.traces[1] or ""):find("Fishing 7731 was not issued (1 in a row)", 1, true), "traced: " .. tostring(W.traces[1]))

    W = fishing_world({})
    W.tick()
    assert_eq(W.calls[1], "open_profession", "nothing found: the profession call")
end }

-- --- 1.66.1: catches, and full bags ---------------------------------------------

--- Casts, starts the channel, shows our bobber, a bite, and clicks it.
local function hook_a_fish(W)
    W.tick()                                   -- the cast
    W.channelling = true
    W.clock = W.clock + 0.2
    W.tick()                                   -- the channel started: waiting
    local bobber = {}
    function bobber.get_guid() return "GameObject-0-1-0-0-35591-BOBBER" end
    function bobber.is_valid() return true end
    function bobber.get_creator_object() return W.player end
    function bobber.is_basic_object() return true end
    function bobber.get_max_health() return 0 end
    function bobber.does_bobber_have_fish() return W.bite == true end
    W.objects = { bobber }
    W.clock = W.clock + 0.2
    W.tick()                                   -- found it
    W.bite = true
    W.clock = W.clock + 0.2
    W.tick()                                   -- a bite: the reaction starts
    W.clock = W.clock + 1.0
    W.tick()                                   -- the click
end

T[#T + 1] = { "fishing (1.66.1): a catch the game's own auto-loot takes counts as a catch, not as got away", function()
    -- Forever: use_object answers false even when the window opens.
    local W = fishing_world({ 7731 })
    W.click_answer, W.click_tried = false, true
    hook_a_fish(W)
    assert_eq(W.calls[#W.calls], "click", "the bobber was clicked")
    assert_eq(W.fishing.stats().state, "hooked", "hooked, though the call answered false")

    -- The window opens with the fish, the game takes it, the channel ends.
    W.loot_count, W.loot_names = 1, { "Raw Brilliant Smallfish" }
    W.handlers["jcore.game_event.LOOT_OPENED"]({ true, false })
    W.loot_count, W.loot_names, W.channelling = 0, {}, false
    W.handlers["jcore.game_event.LOOT_CLOSED"]({})
    W.clock = W.clock + 0.1
    W.tick()
    local s = W.fishing.stats()
    assert_eq(s.catches, 1, "one catch")
    assert_eq(s.misses, 0, "nothing got away")
    assert_eq(s.last_loot, "Raw Brilliant Smallfish", "what it was, read as the window opened")
    assert_eq(s.state, "idle", "and on to the next cast")

    -- Our own looting still counts once, and reads the name before taking it.
    W = fishing_world({ 7731 })
    W.click_answer, W.click_tried = false, true
    hook_a_fish(W)
    W.loot_count, W.loot_names = 1, { "Oily Blackmouth" }
    W.handlers["jcore.game_event.LOOT_OPENED"]({ false, false })
    W.clock = W.clock + 0.1
    W.tick()                                   -- looting
    W.clock = W.clock + 0.3
    W.tick()                                   -- takes it
    s = W.fishing.stats()
    assert_eq(s.catches, 1, "one catch, looted by us")
    assert_eq(s.last_loot, "Oily Blackmouth", "named")

    -- A channel that ends with no click is still a fish that got away.
    W = fishing_world({ 7731 })
    W.tick()
    W.channelling = true
    W.clock = W.clock + 0.2
    W.tick()
    W.channelling = false
    W.clock = W.clock + 0.2
    W.tick()
    assert_eq(W.fishing.stats().misses, 1, "got away")
end }

T[#T + 1] = { "fishing (1.66.1): the game's \"Inventory is full\" after a click stops fishing", function()
    local W = fishing_world({ 7731 })
    W.click_answer, W.click_tried = false, true
    hook_a_fish(W)
    W.loot_count, W.loot_names = 1, { "Raw Brilliant Smallfish" }
    W.handlers["jcore.game_event.LOOT_OPENED"]({ true, false })
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 3, "Inventory is full.", "ERR_INV_FULL" })
    W.clock = W.clock + 0.1
    W.tick()
    local s = W.fishing.stats()
    assert(s.stopped and s.stopped:find("Inventory is full", 1, true), "stopped with the game's words: " .. tostring(s.stopped))
    assert_eq(s.catches, 0, "the fish did not fit: no catch")
    local n = #W.calls
    W.clock = W.clock + 10
    W.tick()
    assert_eq(#W.calls, n, "no cast after the stop")
    W.fishing.on_toggle()
    W.loot_count, W.channelling = 0, false
    W.tick()
    assert_eq(W.calls[#W.calls], "cast 7731", "toggled back on: fishing again")

    -- Switched off: the text does not stop it.
    W = fishing_world({ 7731 })
    W.opts.fish_stop_full = false
    W.click_answer, W.click_tried = false, true
    hook_a_fish(W)
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 3, "Inventory is full.", "ERR_INV_FULL" })
    W.clock = W.clock + 0.1
    W.tick()
    assert_eq(W.fishing.stats().stopped, nil, "the switch is off")

    -- The same text with no click behind it is somebody else's.
    W = fishing_world({ 7731 })
    W.handlers["jcore.game_event.UI_ERROR_MESSAGE"]({ 3, "Inventory is full.", "ERR_INV_FULL" })
    W.tick()
    assert_eq(W.fishing.stats().stopped, nil, "no click: not ours")
end }

--- A fishing world with JCore's input (1.7.5). The calls list gets "+key" and
--- "-key" for the movement keys, "jump" and "look_at", and W.at[i] is when
--- call i went out. The facing store is W.store. Each cast channels for 4.5 s
--- and catches nothing, so fishing keeps going. The clock moves in eighths of
--- a second, which add up exactly.
local function keepalive_world(store_data)
    local W = fishing_world({ 7620 }, nil, function(W, P)
        W.at = {}
        W.store = { data = store_data or {}, touched = 0 }
        function W.store:touch() self.touched = self.touched + 1 end
        P.ctx.store = function(name) return name == "presence" and W.store or nil end
        local held, leases = {}, {}
        local function call(what)
            W.calls[#W.calls + 1] = what
            W.at[#W.calls] = W.clock
            if W.player.is_channelling_spell() then W.during_cast = (W.during_cast or 0) + 1 end
        end
        P.ctx.input = {
            CHANNEL = { MOVEMENT = "movement", FACING = "facing" },
            acquire = function(channel)
                if W.deny then return false end
                leases[channel] = true
                return true
            end,
            release = function(channel)
                leases[channel] = nil
                if channel == "movement" then
                    for key in pairs(held) do held[key] = nil; call("-" .. key) end
                end
            end,
            set_key = function(key, down)
                if not leases.movement then return false end
                if down and not held[key] then held[key] = true; call("+" .. key)
                elseif not down and held[key] then held[key] = nil; call("-" .. key) end
                return true
            end,
            jump = function() call("jump") end,
            is_typing = function() return W.typing == true end,
            look_at = function(point)
                if leases.facing then W.looked = point; call("look_at") end
            end,
        }
    end)
    local open = core.profession.open_profession
    core.profession.open_profession = function(...)
        W.channel_until = W.clock + 4.5
        return open(...)
    end
    W.player.is_channelling_spell = function() return W.clock < (W.channel_until or 0) end
    W.player.get_position = function() return { x = 0, y = 0, z = 0 } end
    W.player.get_direction = function() return { x = 0, y = 1, z = 0 } end
    function W.say(text) W.handlers["jcore.game_event.CHAT_MSG_SYSTEM"]({ text }) end
    function W.count(what)
        local n = 0
        for _, c in ipairs(W.calls) do if c == what then n = n + 1 end end
        return n
    end
    function W.keepalives() return W.count("+turn_left") + W.count("+left") + W.count("jump") end
    --- Runs the loop for `seconds`, a tick every `step` (an eighth by default).
    function W.run(seconds, step)
        step = step or 0.125
        local stop = W.clock + seconds
        while W.clock < stop do
            W.clock = W.clock + step
            W.tick()
        end
    end
    return W
end

T[#T + 1] = { "fishing (1.7.5): Jambix Market's keep-alive -- a short turn each way between casts, the facing kept", function()
    local W = keepalive_world()
    W.tick()
    assert_eq(W.calls[1], "+turn_left", "the first gap: a turn, before any cast")
    W.run(0.125)
    assert_eq(W.calls[2], "-turn_left", "let go after a tenth of a second or so")
    assert_eq(W.calls[3], "+turn_right", "and turned back")
    W.run(0.125)
    assert_eq(W.calls[4], "-turn_right", "let go")
    assert_eq(W.at[4] - W.at[3], W.at[2] - W.at[1], "as long each way")
    assert_eq(W.calls[5], "look_at", "the facing from before is looked at again")
    assert_eq(W.looked.x, 0, "ten yards along it")
    assert_eq(W.looked.y, 10, "ten yards along it")
    W.run(0.125)
    assert_eq(W.calls[6], "open_profession", "then the cast")

    -- Two minutes on, the next one, at a gap between casts.
    W.run(130)
    assert_eq(W.count("+turn_left"), 2, "two minutes on: the next keep-alive")
    local second
    for i, c in ipairs(W.calls) do if c == "+turn_left" then second = i end end
    assert(W.at[second] - W.at[1] >= 120 and W.at[second] - W.at[1] < 130,
        "every two minutes: " .. (W.at[second] - W.at[1]))
    assert_eq(W.during_cast, nil, "never during a cast")
    assert_eq(W.count("jump"), 0, "no jump while the turn has not failed")
    assert_eq(W.count("-turn_left") + W.count("-turn_right"), 4, "every key let go")

    -- Switched off: nothing. Typing, or movement held by something else:
    -- the cast goes out instead.
    local off = keepalive_world()
    off.opts.fish_stay_active = false
    off.run(300)
    assert_eq(off.keepalives(), 0, "switched off: no keep-alive")
    assert(off.count("open_profession") > 10, "fishing goes on")
    local typing = keepalive_world()
    typing.typing = true
    typing.tick()
    assert_eq(typing.calls[1], "open_profession", "while you type: the cast, no keys")
    typing.typing = false
    typing.run(10)
    assert_eq(typing.count("+turn_left"), 1, "the turn at the next gap")
    local denied = keepalive_world()
    denied.deny = true
    denied.tick()
    assert_eq(denied.calls[1], "open_profession", "the lease refused: the cast")
    -- Without JCore's input: fishing as before.
    local bare = fishing_world({ 7620 })
    bare.tick()
    assert_eq(bare.calls[1], "open_profession", "no ctx.input: the cast")
end }

T[#T + 1] = { "fishing (1.7.5): Away within five minutes of a turn fails it; a sidestep answers, then a jump, then it gives up", function()
    local W = keepalive_world()
    W.run(60)
    assert_eq(W.count("+turn_left"), 1, "a turn at the start")
    -- The turn did not reach the idle clock: Away, under five minutes on.
    W.say("You are now Away: Away")
    assert_eq(W.fishing.presence().failed.turn, "Away came anyway", "the turn failed")
    assert(W.store.touched > 0, "and that is kept")
    W.run(10)
    assert_eq(W.count("+left"), 1, "a sidestep answers at the next gap")
    assert_eq(W.count("-left") + W.count("+right") + W.count("-right"), 3, "left, then right, let go")
    assert_eq(W.count("look_at"), 1, "only the turn looks back")
    -- It takes the Away off, and the idle clock puts it straight back.
    W.say("You are no longer Away.")
    W.run(1)
    W.say("You are now Away: Away")
    assert_eq(W.fishing.presence().failed.step, "Away came back right after it", "the step failed")
    W.run(30)
    assert_eq(W.count("jump"), 0, "a minute at least between answers")
    W.run(40)
    assert_eq(W.count("jump"), 1, "then a jump")
    W.say("You are no longer Away.")
    W.run(100)
    W.say("You are now Away: Away")
    assert_eq(W.fishing.presence().kind, nil, "every kind failed")
    assert(W.fishing.stats().away_anyway, "and why")

    -- From here on nothing answers Away, and nothing goes out on time.
    local casts, sent = W.count("open_profession"), W.keepalives()
    for _ = 1, 10 do
        W.run(60)
        W.say("You are now Away: Away")
    end
    assert_eq(W.keepalives(), sent, "nothing after giving up")
    assert(W.count("open_profession") > casts + 50, "fishing itself goes on")
    local lines = W.fishing.status_lines()
    assert(lines[#lines]:find("Anti-AFK gave up", 1, true), "the Fishing page says so: " .. lines[#lines])

    -- What failed is kept: the same file next session starts at the step.
    local again = keepalive_world({ failed = { turn = "Away came anyway" } })
    again.run(1)
    assert_eq(again.count("+left"), 1, "the step first")
    assert_eq(again.count("+turn_left"), 0, "no turn")
end }

T[#T + 1] = { "fishing (1.7.5): Away before any keep-alive says nothing; one that stays on fails it; holding is kept; off and on forgets", function()
    local W = keepalive_world()
    W.opts.fish_enabled = false
    W.run(400, 0.5)
    W.say("You are now Away: Away")            -- idle before fishing started
    W.opts.fish_enabled = true
    W.fishing.on_toggle()
    W.run(0.125)
    assert_eq(W.count("+turn_left"), 1, "fishing starts: a turn at once")
    assert_eq(W.fishing.presence().failed.turn, nil, "the Away before it says nothing of the turn")
    -- No "no longer Away": the turn did not even take it off.
    W.run(41)
    assert_eq(W.fishing.presence().failed.turn, "Away stayed on", "still Away 30 s after the turn: it failed")
    assert_eq(W.count("+left"), 1, "a sidestep answers")
    W.say("You are no longer Away.")

    -- Fifteen minutes and more without an Away: the step holds.
    W.run(16 * 60, 0.5)
    assert_eq(W.fishing.presence().held.step, true, "on record as holding")
    assert(W.count("+left") >= 7, "every two minutes meanwhile: " .. W.count("+left"))
    local lines = W.fishing.status_lines()
    assert(lines[#lines]:find("sidestep", 1, true) and lines[#lines]:find("keeps you active", 1, true),
        "the Fishing page says which and that it works: " .. lines[#lines])

    -- Switched off and on: every kind is tried again.
    W.opts.fish_stay_active = false
    W.run(1)
    W.opts.fish_stay_active = true
    W.run(1)
    assert_eq(W.fishing.presence().failed.turn, nil, "the failure forgotten")
    assert_eq(W.fishing.presence().held.step, nil, "and the hold")
    assert_eq(W.fishing.presence().kind, "turn", "the turn first again")
end }

return T

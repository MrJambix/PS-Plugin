-- Jambix AIO 1.55.3: a vein is mined until it is gone. The user, 2026-10-03:
-- "the automated Mining only does it 2 times instead of until it's depleted".
-- Every attempt counted toward the three-attempt blacklist, successes too, so
-- the third press on a vein (mined twice, its window open) gave it up for two
-- minutes. The real world.lua and actions.lua on a hand-built world: a cast or
-- a loot window after an attempt clears its failures; the press that landed
-- between the cast and its window ("That is already being used.") is held;
-- six openings end a node anyway; a node that never answers is still given
-- up on after three. Era and Forever alike (shared code).

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(list, text)
    for i = 1, #list do if list[i]:find(text, 1, true) then return true end end
    return false
end

local function world(recording)
    local W = { clock = 100, traces = {}, used = 0, handlers = {}, every = {}, nodes = {},
        casting = false, window = 0 }
    _G.core = {
        time = function() return W.clock end,
        game_ui = { get_loot_item_count = function() return W.window end },
        input = { use_object = function() W.used = W.used + 1 return true end },
        is_textbox_focused = function() return false end,
    }
    local player = {
        is_dead = function() return false end, is_ghost = function() return false end,
        is_casting_spell = function() return W.casting end, is_channelling_spell = function() return false end,
        is_moving = function() return false end, is_mounted = function() return false end,
        is_in_combat = function() return false end,
    }
    local tick
    local ctx = {
        world = { client = function() return { recording = recording } end },
        on = function(name, fn)
            W.handlers[name] = W.handlers[name] or {}
            table.insert(W.handlers[name], fn)
        end,
        every = function(_, fn) W.every[#W.every + 1] = fn end,
        render = function(fn) tick = fn end,
        tick = function() end,
        emit = function(name, text) if name == "jcore.recorder.trace" then W.traces[#W.traces + 1] = text end end,
    }
    local P = {
        ctx = ctx,
        log = { fmt = function() end, debug = function() end },
        units = { player = function() return player end, distance = function(o) return o.d end },
        master_on = function() return true end,
        opt = function(id, default)
            if id == "gather_ore" then return true end
            return default
        end,
        esp = { corpses = function() return {} end, nodes = function() return W.nodes end, stats = function() return {} end },
    }
    package.loaded["jambix_aio/modules/actions"] = nil
    package.loaded["jambix_aio/modules/world"] = nil
    P.actions = require("jambix_aio/modules/actions")(P)
    require("jambix_aio/modules/world")(P)
    W.actions = P.actions
    function W.node(guid, d, name)
        local o = { guid = guid, d = d, is_valid = function() return true end, get_guid = function() return guid end }
        W.nodes[#W.nodes + 1] = { obj = o, guid = guid, distance = d, kind = "ore", name = name }
        return o
    end
    function W.tick() tick() end
    function W.fire(name, args)
        for _, fn in ipairs(W.handlers[name] or {}) do fn(args) end
    end
    -- One Mining swing as the client plays it: the cast, its end, the window
    -- a moment later, emptied and closed. A press tried at every step.
    function W.mine_once()
        W.fire("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-1", 2575 })
        W.casting = true
        for _ = 1, 3 do W.clock = W.clock + 1 W.tick() end
        W.casting = false
        W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-1", 2575 })
        W.clock = W.clock + 0.4
        W.tick()                                     -- the gap: held
        W.clock = W.clock + 0.3
        W.window = 2
        W.fire("jcore.game_event.LOOT_OPENED", { true, false })
        W.tick()                                     -- the window: blocked
        W.window = 0
        W.fire("jcore.game_event.LOOT_CLOSED", {})
        W.clock = W.clock + 0.7
    end
    return W
end

local T = {}

for _, recording in ipairs({ true, false }) do
    local client = recording and "Forever" or "Era"

    T[#T + 1] = { client .. ": a vein is mined swing after swing, never given up on while it answers", function()
        local W = world(recording)
        W.node("GameObject-0-1-2-3-1731-00004167C4", 3.0, "Copper Vein")
        for swing = 1, 5 do
            W.tick()
            assert_eq(W.used, swing, "swing " .. swing .. " pressed once")
            W.mine_once()
        end
        assert_eq(W.used, 5, "no press in the gap or on the window")
        assert_eq(W.actions.is_blacklisted("GameObject-0-1-2-3-1731-00004167C4"), false, "still being mined")
        assert(not has(W.traces, "giving up on Copper Vein"), "not given up: " .. table.concat(W.traces, " | "))
        -- Depleted: the vein leaves the world, and the list.
        W.nodes = {}
        W.tick()
        assert_eq(W.used, 5, "nothing to press")
    end }

    T[#T + 1] = { client .. ": six openings end a node anyway (bags full)", function()
        local W = world(recording)
        W.node("GameObject-0-1-2-3-1731-00004167C5", 3.0, "Copper Vein")
        for _ = 1, 6 do
            W.tick()
            W.mine_once()
        end
        assert_eq(W.used, 6, "six swings")
        assert_eq(W.actions.is_blacklisted("GameObject-0-1-2-3-1731-00004167C5"), true, "then left alone")
        if recording then
            assert(has(W.traces, "done with Copper Vein 00004167C5 for 120s after 6 openings"), "said: " .. table.concat(W.traces, " | "))
        end
        W.clock = W.clock + 5
        W.tick()
        assert_eq(W.used, 6, "no seventh")
    end }

    T[#T + 1] = { client .. ": a node that never answers is still given up on after three", function()
        local W = world(recording)
        W.node("GameObject-0-1-2-3-1731-00004167C6", 3.0, "Copper Vein")
        for _ = 1, 5 do
            W.tick()
            W.clock = W.clock + 1.1
        end
        assert_eq(W.used, 3, "three tries")
        assert_eq(W.actions.is_blacklisted("GameObject-0-1-2-3-1731-00004167C6"), true, "given up on")
        if recording then
            assert(has(W.traces, "giving up on Copper Vein"), "said: " .. table.concat(W.traces, " | "))
        end
    end }

    T[#T + 1] = { client .. ": a cast long after an attempt counts for nothing", function()
        local W = world(recording)
        W.node("GameObject-0-1-2-3-1731-00004167C7", 3.0, "Copper Vein")
        W.tick()
        W.clock = W.clock + 7                        -- past SUCCESS_WITHIN
        W.fire("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-2", 133 })
        W.tick()
        W.clock = W.clock + 1.1
        W.tick()
        assert_eq(W.used, 3, "the stray cast cleared nothing")
        assert_eq(W.actions.is_blacklisted("GameObject-0-1-2-3-1731-00004167C7"), true, "given up on")
    end }
end

return T

-- Jambix AIO 1.55.1: what auto-loot did, in the recorder trace, where the
-- recorder runs (Forever). The real world.lua and actions.lua on a hand-built
-- world: a corpse out of reach says so; one in reach is tried, with its
-- distance and attempt; a loot window after it, or nothing, is said; blocked
-- (in combat) says why. Era (no recorder) writes none of it.

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

local function world(recording, with_jcore)
    local W = { clock = 100, traces = {}, looted = 0, interacted = 0, handlers = {}, every = {}, in_combat = false,
        corpses = {}, moving = false, opts = {}, skinned = 0 }
    _G.core = {
        time = function() return W.clock end,
        game_ui = { get_loot_item_count = function() return 0 end },
        input = {
            loot_object = function() W.looted = W.looted + 1 return true end,
            interact_with_object = function() W.interacted = W.interacted + 1 return true end,
            skin_object = function() W.skinned = W.skinned + 1 return false end,
        },
        is_textbox_focused = function() return false end,
    }
    local player = {
        is_dead = function() return false end, is_ghost = function() return false end,
        is_casting_spell = function() return false end, is_channelling_spell = function() return false end,
        is_moving = function() return W.moving end, is_mounted = function() return W.mounted == true end,
        is_in_combat = function() return W.in_combat end,
    }
    local tick
    -- JCore 1.6.1's loot service, the real one, as Forever runs it.
    local facts = with_jcore and require("mock/jcore_unit_facts").build({
        forever = true,
        units = {
            guid = function(o) return o and o.guid end,
            player = function() return player end,
            position = function(o) return o and o.pos end,
        },
    }) or nil
    local ctx = {
        world = { client = function() return { recording = recording } end },
        loot = facts and facts.loot or nil,
        on = function(name, fn)
            W.handlers[name] = W.handlers[name] or {}
            table.insert(W.handlers[name], fn)
            if facts then facts.on(name, fn) end
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
            if id == "autoloot_on" then return true end
            if W.opts[id] ~= nil then return W.opts[id] end
            return default
        end,
        esp = { corpses = function() return W.corpses end, nodes = function() return {} end, stats = function() return {} end },
    }
    package.loaded["jambix_aio/modules/actions"] = nil
    package.loaded["jambix_aio/modules/world"] = nil
    P.actions = require("jambix_aio/modules/actions")(P)
    W.M = require("jambix_aio/modules/world")(P)
    function W.corpse(guid, d, skinnable)
        local o = { guid = guid, d = d, is_valid = function() return true end, get_guid = function() return guid end }
        W.corpses[#W.corpses + 1] = { obj = o, guid = guid, distance = d, skinnable = skinnable == true }
        return o
    end
    function W.tick() tick() end
    function W.fire(name, args)
        if facts and facts.handlers[name] then facts.handlers[name](args)
        else for _, fn in ipairs(W.handlers[name] or {}) do fn(args) end end
    end
    function W.run_every() for _, fn in ipairs(W.every) do fn() end end
    return W
end

local T = {}

T[#T + 1] = { "Forever: out of reach, tried, a window, nothing, blocked -- each is said", function()
    local W = world(true)
    W.corpse("Creature-0-1-2-3-4-00004139AA", 8)
    W.tick()
    assert(has(W.traces, "1 corpse(s) listed, nearest 8.0 yd (reach 4.5), 1 ready; not looting: none within reach and ready"),
        "out of reach: " .. table.concat(W.traces, " | "))
    assert_eq(W.looted, 0, "nothing tried")

    W.corpses = {}
    W.corpse("Creature-0-1-2-3-4-00004139BB", 3)
    W.clock = W.clock + 6
    W.tick()
    assert_eq(W.looted, 1, "tried")
    assert(has(W.traces, "auto-loot: loot corpse 00004139BB at 3.0 yd, attempt 1 of 3, accepted=true"),
        "the attempt: " .. table.concat(W.traces, " | "))
    W.fire("jcore.game_event.LOOT_OPENED", { true, false })
    assert(has(W.traces, "loot window opened (auto-loot true)"), "the window")

    -- Another try that opens nothing.
    W.clock = W.clock + 2
    W.tick()
    W.clock = W.clock + 5
    W.run_every()
    -- The window cleared its failures (1.55.3): this try counts from one again.
    local firsts = 0
    for i = 1, #W.traces do if W.traces[i]:find("attempt 1 of 3", 1, true) then firsts = firsts + 1 end end
    assert_eq(firsts, 2, "the second attempt, counted afresh")
    assert(has(W.traces, ": nothing opened after"), "and nothing came of it: " .. table.concat(W.traces, " | "))

    -- Blocked: in combat.
    W.in_combat = true
    W.clock = W.clock + 6
    W.tick()
    assert(has(W.traces, "not looting: in combat"), "blocked, and why")
end }

T[#T + 1] = { "Forever with JCore: the corpse is opened once (loot_object first, 1.6.2), and not pressed again while pending", function()
    local W = world(true, true)
    W.corpse("Creature-0-1-2-3-4-00004161C9", 3.7)
    W.tick()
    assert_eq(W.looted, 1, "loot_object first")
    assert_eq(W.interacted, 0, "the interact only if that brings nothing")
    -- The character walks there: no second press however long it takes.
    W.moving = true
    for _ = 1, 10 do
        W.clock = W.clock + 1
        W.tick()
    end
    W.moving = false
    W.clock = W.clock + 0.5
    W.tick()
    assert_eq(W.interacted + W.looted, 1, "one press while it walked and arrived")
    W.fire("jcore.game_event.LOOT_OPENED", { true, false })
    assert(has(W.traces, "loot window opened"), "the window: " .. table.concat(W.traces, " | "))
end }

for _, recording in ipairs({ true, false }) do
    local client = recording and "Forever" or "Era"
    T[#T + 1] = { client .. ": a corpse listed only to skin is left alone while skinning is off (1.55.4)", function()
        local W = world(recording)
        W.corpse("Creature-0-1-2-3-4-00004169EE", 1.3, true)
        for _ = 1, 4 do
            W.clock = W.clock + 6
            W.tick()
        end
        assert_eq(W.looted, 0, "no loot press on a looted corpse")
        assert_eq(W.skinned, 0, "and no skin: it is off")
        assert(not has(W.traces, "corpse(s) listed"), "nothing listed to loot: " .. table.concat(W.traces, " | "))
        W.opts.autoloot_skin = true
        W.clock = W.clock + 6
        W.tick()
        assert_eq(W.skinned, 1, "skinning on: skinned")
        assert_eq(W.looted, 0, "still no loot press")
    end }
end

T[#T + 1] = { "Era: the same, and no trace line at all", function()
    local W = world(false)
    W.corpse("Creature-0-1-2-3-4-00004139CC", 8)
    W.tick()
    W.corpses = {}
    W.corpse("Creature-0-1-2-3-4-00004139DD", 3)
    W.clock = W.clock + 6
    W.tick()
    assert_eq(W.looted, 1, "looted as before")
    assert_eq(#W.traces, 0, "no trace lines on Era")
end }

-- --- loot before the next pull (1.57.1) ---------------------------------------

T[#T + 1] = { "loot first: a corpse auto-loot will press holds the pull; one it will not does not", function()
    local W = world(false)
    assert_eq(W.M.looting(), false, "no corpse: nothing to wait for")
    W.corpse("Creature-0-1-2-3-4-0000419EBC", 8)
    assert_eq(W.M.looting(), false, "out of reach: auto-loot does not press it")
    W.corpses = {}
    W.corpse("Creature-0-1-2-3-4-0000419EBC", 1.9)
    assert_eq(W.M.looting(), true, "in reach: loot it first")
    W.moving = true
    assert_eq(W.M.looting(), true, "walking: that passes")
    W.moving = false
    W.mounted = true
    assert_eq(W.M.looting(), false, "mounted: auto-loot will not press it, so no hold")
    W.mounted = false

    W.corpses = {}
    W.corpse("Creature-0-1-2-3-4-0000419D1F", 2, true)
    assert_eq(W.M.looting(), false, "skin only with skinning off: auto-loot leaves it")
    W.opts.autoloot_skin = true
    assert_eq(W.M.looting(), true, "skinning on: skin it first")
    W.opts.autoloot_skin = nil

    -- Given up on after its three tries: the pull goes ahead.
    W.corpses = {}
    W.corpse("Creature-0-1-2-3-4-00004199AA", 2)
    for _ = 1, 3 do
        W.clock = W.clock + 2
        W.tick()
    end
    assert_eq(W.looted, 3, "three tries, nothing opened")
    assert_eq(W.M.looting(), false, "blacklisted: no hold")
end }

T[#T + 1] = { "loot first: not for ever on one corpse; a press waiting on its window holds it (JCore)", function()
    local W = world(false)
    W.corpse("Creature-0-1-2-3-4-0000419EBC", 1.9)
    W.in_combat = true          -- auto-loot blocked for now, the corpse waits
    assert_eq(W.M.looting(), false, "in combat: no hold (the rotation fights anyway)")
    W.in_combat = false
    assert_eq(W.M.looting(), true, "out of combat: hold")
    W.clock = W.clock + 9.5
    assert_eq(W.M.looting(), true, "still within ten seconds")
    W.clock = W.clock + 1
    assert_eq(W.M.looting(), false, "ten seconds on one corpse: the pull goes ahead")

    local J = world(true, true)
    J.corpse("Creature-0-1-2-3-4-00004161C9", 3.7)
    J.tick()
    assert_eq(J.looted, 1, "pressed")
    J.corpses = {}
    assert_eq(J.M.looting(), true, "off the list, but its press is waiting on the window")
    J.clock = J.clock + 2.5
    assert_eq(J.M.looting(), false, "nothing came and nothing is listed: no hold")
end }

return T

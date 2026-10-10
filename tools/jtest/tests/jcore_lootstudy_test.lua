-- JCore 1.6.8: services/lootstudy.lua on a hand-built runtime. A corpse the
-- player right-clicks: it was seen die, its window is put down to the corpse
-- under the mouse, the slots are read 0..count, the read that changed while
-- the window was open is tallied with that moment, the corpse is read again
-- after the close, and the file is written (and encodes). A window our own
-- press brought says so, with the call. On every client until the Dump
-- page's switch turns it off.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(list, text)
    for i = 1, #list do
        local v = list[i]
        if type(v) == "table" then v = v.what end
        if type(v) == "string" and v:find(text, 1, true) then return true end
    end
    return false
end

local clock = { t = 100 }
local W = {}

local function reset()
    W.by, W.tokens, W.list, W.snaps = {}, {}, {}, {}
    W.mouseover, W.attempt, W.file, W.doc = nil, nil, nil, nil
    W.loot = { count = 0, slots = {} }
    W.me = { is_moving = function() return false end, get_active_spell_id = function() return 0 end,
        get_active_channel_spell_id = function() return 0 end, is_in_combat = function() return false end }
end

--- A unit in the world, with the reads the study asks for.
local function mob(guid, fields)
    local o = { guid = guid, dead = false, pos = { x = 1, y = 0, z = 0 }, npc = 1126, name = "Large Crag Boar" }
    for k, v in pairs(fields or {}) do o[k] = v end
    local u = {}
    u.get_guid = function() return o.guid end
    u.is_valid = function() return true end
    u.is_dead = function() return o.dead end
    u.is_unit = function() return true end
    u.get_position = function() return o.pos end
    u.get_npc_id = function() return o.npc end
    u.get_name = function() return o.name end
    for _, k in ipairs({ "has_loot", "can_be_looted", "can_be_skinned", "has_skin" }) do
        u[k] = function() return o[k] == true end
    end
    u.is_tap_denied = function() return false end
    u.get_npc_flags = function() return 0 end
    u.get_health = function() return o.dead and 0 or 100 end
    W.by[guid] = u
    W.list[#W.list + 1] = u
    W.snaps[u] = { guid = guid, dist = 1, is_player = false, dead = false }
    return u, o
end

local function set_dead(u, o, dead)
    o.dead = dead
    W.snaps[u].dead = dead
end

_G.core = {
    time = function() return clock.t end,
    object_manager = {
        get_object_from_guid = function(g) return W.tokens[g] or W.by[g] end,
        get_mouse_over_object = function() return W.mouseover end,
    },
    game_ui = {
        get_loot_item_count = function() return W.loot.count end,
        get_loot_item_id = function(i) local s = W.loot.slots[i + 1] return s and s.id or nil end,
        get_loot_item_name = function(i) local s = W.loot.slots[i + 1] return s and s.name or nil end,
        get_loot_is_gold = function(i) local s = W.loot.slots[i + 1] return s and false or nil end,
    },
}

local function runtime(recording)
    local handlers = {}
    local rt = {}
    rt.VERSION = "test"
    rt.log = { for_tag = function() return { fmt = function() end } end }
    rt.events = {
        on = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        emit = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end,
    }
    rt.world = { client = function() return { version = "Forever", exact = "wow_forever_beta_us", recording = recording } end }
    rt.storage = { write_json = function(name, doc) W.file, W.doc = name, doc return true end }
    rt.units = {
        units = function() return W.list end,
        snapshot = function(u) return W.snaps[u] end,
        player = function() return W.me end,
        player_position = function() return { x = 0, y = 0, z = 0 } end,
    }
    rt.loot = { attempt = function() return W.attempt end }
    package.loaded["jambix_debug/services/lootstudy"] = nil
    rt.lootstudy = require("jambix_debug/services/lootstudy")(rt)
    function rt.fire(name, args)
        rt.events.emit("jcore.game_event", name, args)
        rt.events.emit("jcore.game_event." .. name, args)
    end
    function rt.step(seconds)
        clock.t = clock.t + seconds
        rt.lootstudy._poll()
    end
    return rt
end

local T = {}

T[#T + 1] = { "a corpse the player right-clicks: seen die, the window's source, its slots, the read that changed", function()
    reset()
    local rt = runtime(true)
    local u, o = mob("Creature-0-1-0-0-1126-000141AB28")
    rt.step(0.3)                                  -- alive in reach
    set_dead(u, o, true)
    o.has_loot, o.has_skin, o.can_be_skinned = true, true, true
    rt.step(0.3)
    W.mouseover = u
    rt.step(0.3)                                  -- the pointer is on it
    W.loot = { count = 1, slots = { { id = 7074, name = "Chipped Claw" } } }
    rt.fire("LOOT_OPENED", { true, false })
    o.has_loot = false
    rt.step(0.3)                                  -- read while open; slots again at 0.3 s
    W.loot = { count = 0, slots = {} }
    rt.step(0.1)
    rt.fire("LOOT_CLOSED", {})
    rt.step(1.1)
    rt.step(2.0)
    assert_eq(W.doc, nil, "not written yet")
    rt.step(0.5)
    assert(W.doc, "written after the close")
    assert_eq(W.file, "jcore/jcore.lootstudy.forever.json", "the file")

    local w = W.doc.windows[1]
    assert(w.source:find("right-click", 1, true), "the source: " .. tostring(w.source))
    assert_eq(w.corpse, "000141AB28", "the corpse")
    assert_eq(w.pointers.get_mouse_over_object.guid, "000141AB28", "the mouse was on it")
    assert_eq(w.slots[1].count, 1, "one slot")
    assert_eq(w.slots[1].slots[1].slot, 0, "read from slot 0")
    assert_eq(w.slots[1].slots[1].name, "Chipped Claw", "slot 0 is the item")
    assert_eq(w.slots[1].slots[2].name, "nil", "slot 1 (count) is past the end")
    assert_eq(#w.slots, 2, "and read again 0.3 s later")
    assert_eq(w.counts[#w.counts].n, 0, "emptied before it closed")
    assert_eq(#w.after, 3, "the corpse read at the close, 1 s and 3 s after")
    assert_eq(w.after[3].reads.has_loot, false, "no loot after")
    assert(has(w.history, "pointer:"), "the pointer is in the history: " .. table.concat(w.history, " | "))

    local c = W.doc.corpses[1]
    assert_eq(c.seen_die, true, "seen die")
    assert_eq(c.opened, true, "opened")
    assert_eq(c.first.has_loot, true, "had loot at first")
    assert(has(W.doc.summary.changes, "has_loot true -> false (window open)"),
        "the change and its moment: " .. tostring(W.doc.summary.changes[1] and W.doc.summary.changes[1].what))
    assert(has(W.doc.summary.sources, "right-click"), "the source tallied")
    assert_eq(W.doc.summary.first_reads.opened.has_loot["true"], 1, "first reads of opened corpses")

    local json = require("jcore/lib/json")
    local text = json.encode(W.doc, { pretty = true })
    assert(type(text) == "string" and #text > 200, "it encodes")
    -- A sample for tools/jcheck/lootstudy_diff.js to be tried on.
    if jtest and jtest.write_file then jtest.write_file("lootstudy_sample.json", text) end
end }

T[#T + 1] = { "a window our press brought: the source is ours, with the call and the walk", function()
    reset()
    local rt = runtime(true)
    local u, o = mob("Creature-0-1-0-0-1127-000041AB99")
    set_dead(u, o, true)
    o.has_loot = true
    rt.step(0.3)
    W.attempt = { kind = "loot", call = "interact_with_object", guid = "Creature-0-1-0-0-1127-000041AB99",
        at = clock.t - 0.4, walked = true, pending = true }
    W.loot = { count = 1, slots = { {} } }
    rt.fire("LOOT_OPENED", { true, false })
    assert(rt.lootstudy.write(), "written on demand")
    local w = W.doc.windows[1]
    assert_eq(w.source, "ours: interact_with_object", "ours")
    assert_eq(w.our_press.walked, true, "it walked")
    assert_eq(w.our_press.corpse, "000041AB99", "that corpse")
    assert_eq(w.near[1].guid, "000041AB99", "the corpse beside us, listed")
end }

T[#T + 1] = { "Forever's second LOOT_OPENED of one window is counted on it, not a new window (1.6.10)", function()
    reset()
    local rt = runtime(true)
    local u, o = mob("Creature-0-1-0-0-475-0000C1CBAC")
    set_dead(u, o, true)
    o.has_loot = true
    rt.step(0.3)
    W.loot = { count = 2, slots = { {}, { name = "Linen Cloth" } } }
    rt.fire("LOOT_OPENED", { true, false })
    clock.t = clock.t + 0.13
    rt.fire("LOOT_OPENED", { true, false })
    W.loot = { count = 0, slots = {} }
    rt.step(0.2)
    rt.fire("LOOT_CLOSED", {})
    rt.fire("LOOT_CLOSED", {})
    assert(rt.lootstudy.write(), "written")
    assert_eq(#W.doc.windows, 1, "one window")
    assert_eq(W.doc.windows[1].events, 2, "two events on it")
    assert(W.doc.windows[1].open_for, "and its close recorded")
end }

T[#T + 1] = { "a press that brought nothing is recorded with its events, pointers and the corpse (1.6.11)", function()
    reset()
    local rt = runtime(true)
    local u, o = mob("Creature-0-1-0-0-94-000041C8E0", { name = "Defias Cutpurse" })
    set_dead(u, o, true)
    o.has_loot = true
    W.tokens.target = u
    rt.step(0.3)
    local pressed = clock.t
    rt.events.emit("jcore.recorder.trace", "loot: loot 000041C8E0 via loot_object (try 1, answered true, targeted it first)")
    rt.fire("PLAYER_STARTED_MOVING", {})
    clock.t = clock.t + 1.8
    rt.events.emit("jcore.loot.nothing", { kind = "loot", call = "loot_object", guid = "Creature-0-1-0-0-94-000041C8E0",
        at = pressed, walked = true, targeted = true })
    rt.step(3.6)
    assert(W.doc, "written after the miss")
    local m = W.doc.misses[1]
    assert(m, "the miss")
    assert_eq(m.call, "loot_object", "its call")
    assert_eq(m.walked, true, "it walked")
    assert_eq(m.targeted, true, "it targeted first")
    assert_eq(m.corpse, "000041C8E0", "the corpse")
    assert_eq(m.reads.has_loot, true, "which still had loot")
    assert_eq(m.pointers.target.guid, "000041C8E0", "and was the target")
    assert(has(m.history, "PLAYER_STARTED_MOVING"), "the events: " .. table.concat(m.history, " | "))
    assert(has(m.history, "targeted it first"), "and our press")
    assert(has(W.doc.summary.missed, "loot_object, walked, targeted first, target the corpse"),
        "tallied: " .. tostring(W.doc.summary.missed[1] and W.doc.summary.missed[1].what))
end }

T[#T + 1] = { "on every client by default (Era, SoD, Retail too); the switch turns it off", function()
    reset()
    local rt = runtime(false)                     -- a client without the recorder
    local u, o = mob("Creature-0-1-0-0-1126-0000AAAAAA")
    set_dead(u, o, true)
    rt.step(0.3)
    assert_eq(rt.lootstudy.stats().corpses, 1, "studied without the recorder")
    rt.lootstudy.set_enabled(false)
    local v, p = mob("Creature-0-1-0-0-1126-0000BBBBBB")
    set_dead(v, p, true)
    rt.step(0.3)
    rt.fire("LOOT_OPENED", { true, false })
    assert_eq(rt.lootstudy.stats().corpses, 1, "switched off: no new corpse")
    assert_eq(rt.lootstudy.stats().windows, 0, "and no window")
end }

return T

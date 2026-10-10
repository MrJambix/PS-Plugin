-- JCore 1.6.0: services/names.lua and services/loot.lua, driven through a
-- small hand-built runtime. Forever: names gathered (client, this unit, kept
-- by npc id, the creature cache), Jambix AIO's saved names taken in once;
-- whose mob it is (the client's is_tap_denied, or a stranger's fight), what
-- fought us, and whether a corpse is ours, cleared by its loot window. Era:
-- get_name as it is, tapped false with no read, the client's own corpse reads.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local clock = { t = 100 }
local calls = {}
local targeted = {}         -- set_target calls, kept apart so the call order above stays as it was
_G.core = {
    time = function() return clock.t end,
    input = {
        loot_object = function() calls[#calls + 1] = "loot_object" return true end,
        skin_object = function() calls[#calls + 1] = "skin_object" return false end,
        interact_with_object = function() calls[#calls + 1] = "interact_with_object" return true end,
        set_target = function(u) targeted[#targeted + 1] = u return true end,
        use_object = function() calls[#calls + 1] = "use_object" return false end,
    },
}

--- A unit: methods on the object, as the client serves them.
local function unit(o)
    local u = { guid = o.guid, npc = o.npc or 0, name = o.name or "", tap = o.tap == true,
        reads = 0, pos = o.pos or { x = 0, y = 0, z = 0 } }
    u.get_name = function(self) return self.name end
    u.get_npc_id = function(self) return self.npc end
    u.is_tap_denied = function(self) self.reads = self.reads + 1 return self.tap end
    u.can_be_skinned = function() return o.skin == true end
    u.can_be_looted = function() return o.lootable == true end
    u.has_loot = function() return o.has_loot == true end
    return u
end

--- The runtime both services read, with a recording event bus.
local function runtime(forever, opts)
    opts = opts or {}
    local handlers = {}
    local stores = opts.stores or {}
    local rt = {}
    rt.log = { for_tag = function() return { fmt = function() end } end }
    rt.events = {
        on = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
        emit = function(name, ...) for _, fn in ipairs(handlers[name] or {}) do fn(...) end end,
    }
    rt.world = { client = function() return { forever = forever } end }
    rt.storage = { store = function(name)
        local s = stores[name]
        if not s then
            s = { data = {}, touched = 0 }
            s.touch = function(self) self.touched = self.touched + 1 end
            stores[name] = s
        end
        return s
    end }
    rt.target = nil
    rt.combat = { target = function() return rt.target end }
    local snaps = opts.snaps or {}
    rt.units = {
        guid = function(u) return u and u.guid end,
        snapshot = function(u) return snaps[u] end,
        position = function(u) return u and u.pos end,
        player = function() return opts.player end,
    }
    rt.creatures = opts.creatures
    rt.group = { objects = function() return opts.group or {} end }
    rt.enemies = { all = function() return opts.rows or {} end }
    rt.stores = stores
    package.loaded["jcore/services/names"] = nil
    package.loaded["jcore/services/loot"] = nil
    rt.names = require("jcore/services/names")(rt)
    rt.loot = require("jcore/services/loot")(rt)
    return rt
end

local T = {}

-- --- names --------------------------------------------------------------------

T[#T + 1] = { "Forever names: the client's when real, then this unit's, then its kind's, then the cache", function()
    local cache = { name = function(id) return ({ [705] = "Ragged Young Wolf" })[id] end }
    local rt = runtime(true, { creatures = cache })
    local wolf = unit({ guid = "Creature-1", npc = 705 })
    local name, source = rt.names.of(wolf)
    assert_eq(name, "Ragged Young Wolf", "the cache names a creature never cast at")
    assert_eq(source, "cache", "and says so")

    -- Casting at the target: its name rides on UNIT_SPELLCAST_SENT.
    local trogg = unit({ guid = "Creature-2", npc = 707 })
    rt.target = trogg
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_SENT", { "player", "Rockjaw Trogg", "Cast-1", 1752 })
    name, source = rt.names.of(trogg)
    assert_eq(name, "Rockjaw Trogg", "learned from the cast")
    assert_eq(source, "known", "for this very unit")
    local other = unit({ guid = "Creature-3", npc = 707 })
    name, source = rt.names.of(other)
    assert_eq(name, "Rockjaw Trogg", "every one of its kind")
    assert_eq(source, "learned", "by npc id")
    assert_eq(rt.stores["jcore.names"].data.npcs["707"], "Rockjaw Trogg", "kept in the jcore.names store")

    local named = unit({ guid = "Creature-4", npc = 999, name = "Sten Stoutarm" })
    assert_eq((rt.names.of(named)), "Sten Stoutarm", "the client's own answer when it gives one")
    local unknown = unit({ guid = "Creature-5", npc = 1000, name = "Unknown" })
    assert_eq((rt.names.of(unknown)), nil, "a placeholder is no name")
    rt.names.learn(unknown, 1000, "Unknown")
    assert_eq(rt.stores["jcore.names"].data.npcs["1000"], nil, "and is never learned")
end }

T[#T + 1] = { "Forever names: Jambix AIO's saved names are taken in once", function()
    local old = { data = { npcs = { ["250873"] = "Juvenile Vuldren", ["1"] = "Unknown" } }, touch = function() end }
    local rt = runtime(true, { stores = { ["jambix.aio.forever_names"] = old } })
    local u = unit({ guid = "Creature-9", npc = 250873 })
    local name, source = rt.names.of(u)
    assert_eq(name, "Juvenile Vuldren", "taken in")
    assert_eq(source, "learned", "as a kept name")
    assert_eq(rt.names.stats().imported, 1, "the placeholder left behind")
end }

T[#T + 1] = { "Era names: get_name as it is, nothing learned or kept", function()
    local rt = runtime(false)
    local u = unit({ guid = "Creature-1", npc = 705, name = "Ragged Young Wolf" })
    local name, source = rt.names.of(u)
    assert_eq(name, "Ragged Young Wolf", "the client's")
    assert_eq(source, "client", "source")
    rt.target = u
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_SENT", { "player", "Something Else", "Cast-1", 1 })
    assert_eq(rt.stores["jcore.names"], nil, "no store opened on Era")
    assert_eq((rt.names.of(unit({ guid = "x", name = "" }))), nil, "a blank is nil")
end }

-- --- loot ----------------------------------------------------------------------

T[#T + 1] = { "Forever: the client's is_tap_denied, or a stranger's fight, makes it somebody else's", function()
    local denied = unit({ guid = "Creature-1", tap = true })
    local fought_stranger = unit({ guid = "Creature-2" })
    local free = unit({ guid = "Creature-3" })
    local mate = unit({ guid = "Player-1-MATE" })
    local rows = {
        { guid = "Creature-1", obj = denied, in_combat = false },
        { guid = "Creature-2", obj = fought_stranger, in_combat = true, target_guid = "Player-9-STRANGER" },
        { guid = "Creature-3", obj = free, in_combat = true, target_guid = "Player-1-MATE" },
    }
    local rt = runtime(true, { rows = rows, group = { mate } })
    rt.loot._poll()
    local t, how = rt.loot.tapped(denied)
    assert_eq(t, true, "the client says so")
    assert_eq(how, "client", "in its own words")
    t, how = rt.loot.tapped("Creature-2")
    assert_eq(t, true, "a stranger's fight")
    assert_eq(how, "fight", "inferred")
    assert_eq(rt.loot.tapped(free), false, "our group's fight is ours")
    -- The inferred tag goes when it leaves combat.
    rows[2].in_combat = false
    rt.loot._poll()
    assert_eq(rt.loot.tapped("Creature-2"), false, "out of combat: no longer tagged")
    -- is_tap_denied is read every couple of seconds, not every tick.
    local reads = denied.reads
    rt.loot._poll()
    assert_eq(denied.reads, reads, "not read again within the interval")
end }

T[#T + 1] = { "Forever: is_tap_denied as the .api types it, a number -- non-zero is tapped, 0 is not (1.8.8)", function()
    local one = unit({ guid = "Creature-1" })
    one.tap = 1
    local zero = unit({ guid = "Creature-2" })
    zero.tap = 0
    local rows = {
        { guid = "Creature-1", obj = one, in_combat = false },
        { guid = "Creature-2", obj = zero, in_combat = false },
    }
    local rt = runtime(true, { rows = rows })
    rt.loot._poll()
    local t, how = rt.loot.tapped(one)
    assert_eq(t, true, "a 1 is somebody else's")
    assert_eq(how, "client", "in the client's words")
    assert_eq(rt.loot.tapped(zero), false, "a 0 is nobody's")
    -- A corpse never polled is asked directly, the same way.
    local corpse = unit({ guid = "Creature-3", has_loot = true })
    corpse.tap = 1
    assert_eq((rt.loot.corpse(corpse)), false, "has loot, but a 1 makes it somebody else's")
end }

T[#T + 1] = { "Forever corpses: ours when it fought us; the loot window beside it takes that away", function()
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    local kill = unit({ guid = "Creature-7", pos = { x = 3, y = 0, z = 0 }, skin = true })
    local stranger = unit({ guid = "Creature-8", pos = { x = 4, y = 0, z = 0 } })
    local denied = unit({ guid = "Creature-9", pos = { x = 2, y = 0, z = 0 }, tap = true })
    local rows = {
        { guid = "Creature-7", obj = kill, in_combat = true, engaged = true, targeting_me = true },
        { guid = "Creature-9", obj = denied, in_combat = true, engaged = true, targeting_me = true },
    }
    local rt = runtime(true, { rows = rows, player = me })
    rt.loot._poll()
    assert(rt.loot.fought(kill), "it fought us")
    local lootable, skinnable = rt.loot.corpse(kill)
    assert_eq(lootable, true, "our kill")
    assert_eq(skinnable, true, "and the client says it can be skinned")
    assert_eq((rt.loot.corpse(stranger)), false, "never fought us: not ours")
    assert_eq((rt.loot.corpse(denied)), false, "the client calls it somebody else's")

    -- A bag item's window is not the corpse's; the corpse's own is.
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, true })
    assert_eq((rt.loot.corpse(kill)), true, "still ours after a bag item")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(kill)), false, "looted")
end }

T[#T + 1] = { "Era: tapped is false with no read, a corpse is the client's own answer, nothing tracked", function()
    local mob = unit({ guid = "Creature-1", tap = true })
    local rt = runtime(false, { rows = { { guid = "Creature-1", obj = mob, in_combat = true, engaged = true } } })
    rt.loot._poll()
    assert_eq(rt.loot.tapped(mob), false, "Era never asked")
    assert_eq(mob.reads, 0, "and nothing was read")
    assert_eq(rt.loot.fought(mob), nil, "nothing tracked")
    local corpse = unit({ guid = "Creature-2", lootable = true })
    assert_eq((rt.loot.corpse(corpse)), true, "the client's can_be_looted")
end }

-- --- opening a corpse (JCore 1.6.1) -----------------------------------------------

T[#T + 1] = { "Forever: the kind's own call first; pending while walking; a window teaches it", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 }, moving = false }
    me.is_moving = function(self) return self.moving end
    local rt = runtime(true, { player = me })
    local a = unit({ guid = "Creature-1" })
    assert_eq(rt.loot.open(a, "loot"), true, "dispatched")
    assert_eq(calls[1], "loot_object", "loot_object first (1.6.2)")
    assert_eq(rt.loot.opening(), true, "pending: nothing has come of it yet")
    -- Walking there keeps it pending however long it takes.
    me.moving = true
    clock.t = clock.t + 5
    assert_eq(rt.loot.opening(), true, "still walking")
    me.moving = false
    clock.t = clock.t + 1
    assert_eq(rt.loot.opening(), true, "arrived a moment ago")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq(rt.loot.opening(), false, "the window came")
    assert_eq(rt.loot.open_call("loot"), "loot_object", "and the call is learned")
    local b = unit({ guid = "Creature-2" })
    rt.loot.open(b, "loot")
    assert_eq(calls[2], "loot_object", "the next corpse: the learned call")
end }

T[#T + 1] = { "Forever: a try that brings nothing settles after standing still, and the next try alternates", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local c = unit({ guid = "Creature-3" })
    rt.loot.open(c, "loot")
    clock.t = clock.t + 0.5
    assert_eq(rt.loot.opening(), true, "pending (standing still counts from here)")
    clock.t = clock.t + 1.0
    assert_eq(rt.loot.opening(), true, "a second still: still pending")
    clock.t = clock.t + 1.5
    assert_eq(rt.loot.opening(), false, "two seconds still with nothing: settled")
    rt.loot.open(c, "loot")
    assert_eq(calls[2], "interact_with_object", "the second try: the right-click's interact")
    assert_eq(rt.loot.open_call("loot"), nil, "nothing learned")
    -- Skinning: its cast settles it.
    rt.loot.open(c, "skin")
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-1", 8613 })
    assert_eq(rt.loot.opening(), false, "the skinning cast came")
end }

T[#T + 1] = { "Forever: the learned call goes first, the other on the next try at that corpse; skin tries apart (1.6.5)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local a = unit({ guid = "Creature-61" })
    rt.loot.open(a, "loot")
    rt.loot.open(a, "loot")
    assert_eq(calls[2], "interact_with_object", "the second try: the interact")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq(rt.loot.open_call("loot"), "interact_with_object", "it opened: learned")
    clock.t = clock.t + 2                         -- the next corpse, a while later
    local b = unit({ guid = "Creature-62" })
    rt.loot.open(b, "loot")
    assert_eq(calls[3], "interact_with_object", "the next corpse: the learned call first")
    rt.loot.open(b, "loot")
    assert_eq(calls[4], "loot_object", "and loot_object on its second try (it was never tried again before 1.6.5)")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq(rt.loot.open_call("loot"), "loot_object", "loot_object opened it: first again")
    rt.loot.open(b, "skin")
    assert_eq(calls[5], "skin_object", "the corpse's first skin try, whatever its looting took")
end }

T[#T + 1] = { "Forever: a press that walked there is over half a second after arriving; one that did not waits two (1.6.7)", function()
    calls = {}
    local traces = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 }, moving = false }
    me.is_moving = function(self) return self.moving end
    local rt = runtime(true, { player = me })
    rt.events.on("jcore.recorder.trace", function(text) traces[#traces + 1] = text end)
    local c = unit({ guid = "Creature-71" })
    rt.loot.open(c, "loot")
    -- The press walks the character there; nobody asks while it moves, the
    -- tick sees it.
    me.moving = true
    clock.t = clock.t + 0.2
    rt.loot._poll()
    clock.t = clock.t + 0.4
    me.moving = false
    rt.loot._poll()
    clock.t = clock.t + 0.3
    assert_eq(rt.loot.opening(), true, "just arrived: a moment for the window")
    clock.t = clock.t + 0.3
    assert_eq(rt.loot.opening(), false, "half a second beside it with nothing: over, press again")
    local said = false
    for i = 1, #traces do if traces[i]:find("it walked there", 1, true) then said = true end end
    assert(said, "the trace says it walked: " .. table.concat(traces, " | "))
    rt.loot.open(c, "loot")
    assert_eq(calls[2], "interact_with_object", "the next press: the other call, from beside it")
    -- Standing beside it already: the full two seconds.
    clock.t = clock.t + 0.1
    rt.loot._poll()
    assert_eq(rt.loot.opening(), true, "pending")
    clock.t = clock.t + 1.0
    assert_eq(rt.loot.opening(), true, "a second with no walk: still waiting")
    clock.t = clock.t + 1.1
    assert_eq(rt.loot.opening(), false, "two seconds: over")
end }

T[#T + 1] = { "Forever: has_loot makes a corpse ours though no fight was seen, unless somebody else's (1.6.2)", function()
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local missed = unit({ guid = "Creature-21", has_loot = true, pos = { x = 2, y = 0, z = 0 } })
    local theirs = unit({ guid = "Creature-22", has_loot = true, tap = true })
    local empty = unit({ guid = "Creature-23" })
    assert_eq((rt.loot.corpse(missed)), true, "the client says it has loot: ours")
    assert_eq((rt.loot.corpse(theirs)), false, "somebody else's, loot or not")
    assert_eq((rt.loot.corpse(empty)), false, "no loot, no fight: not ours")
end }

T[#T + 1] = { "Forever: the window goes to the corpse being opened, not the nearest (1.6.2)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local near = unit({ guid = "Creature-31", has_loot = true, pos = { x = 1, y = 0, z = 0 } })
    local far = unit({ guid = "Creature-32", has_loot = true, pos = { x = 4, y = 0, z = 0 } })
    rt.loot.corpse(near)
    rt.loot.corpse(far)
    rt.loot.open(far, "loot")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(far)), false, "the one opened is looted")
    assert_eq((rt.loot.corpse(near)), true, "the nearer one is still to loot")
end }

T[#T + 1] = { "Forever: 'Creature must be looted first' to a skin: loot it (1.6.2)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local c = unit({ guid = "Creature-41", skin = true })
    assert_eq((rt.loot.corpse(c)), false, "no fight seen, no has_loot: skin only")
    rt.loot.open(c, "skin")
    rt.events.emit("jcore.game_event.UI_ERROR_MESSAGE", { 50, "Creature must be looted first", "ERR_USE_LOCKED_WITH_ITEM_S" })
    assert_eq((rt.loot.corpse(c)), true, "the client says it has loot: ours to loot now")
    assert_eq(rt.loot.opening(), false, "and the skin attempt is over")
end }

T[#T + 1] = { "Forever: a window long after an attempt is not its; the nearest corpse takes it (1.6.3)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local old = unit({ guid = "Creature-51", has_loot = true, pos = { x = 30, y = 0, z = 0 } })
    local here = unit({ guid = "Creature-52", has_loot = true, pos = { x = 1, y = 0, z = 0 } })
    rt.loot.corpse(old)
    rt.loot.open(old, "loot")
    -- Nothing came, and nobody asked opening() since: 84 s go by.
    clock.t = clock.t + 84
    rt.loot.corpse(here)
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(here)), false, "the corpse beside you is the one looted")
    assert_eq((rt.loot.corpse(old)), true, "the old attempt's corpse still has its loot")
    assert_eq(rt.loot.opening(), false, "and that attempt is over")
end }

T[#T + 1] = { "Forever: a window right after a cast of yours (a vein) is no corpse's (1.6.3)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local c = unit({ guid = "Creature-61", has_loot = true, pos = { x = 2, y = 0, z = 0 } })
    rt.loot.corpse(c)
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-1", 2575 })
    clock.t = clock.t + 3.2
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-1", 2575 })
    clock.t = clock.t + 0.3
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(c)), true, "the corpse beside the vein keeps its loot")
    -- A right-click of yours later, with no cast before it: the corpse's.
    clock.t = clock.t + 5
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(c)), false, "your own right-click loots it")
end }

T[#T + 1] = { "Forever: a skinned corpse is done; an interrupted skin is not (1.6.3)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local a = unit({ guid = "Creature-71", skin = true, pos = { x = 1, y = 0, z = 0 } })
    local b = unit({ guid = "Creature-72", skin = true, pos = { x = 2, y = 0, z = 0 } })
    assert_eq(select(2, rt.loot.corpse(a)), true, "skinnable")
    rt.loot.open(a, "skin")
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-2", 8613 })
    clock.t = clock.t + 1.6
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-2", 8613 })
    clock.t = clock.t + 0.3
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    clock.t = clock.t + 2       -- past the skin read's keep: read again
    assert_eq(select(2, rt.loot.corpse(a)), false, "skinned: not listed again (the client still said yes)")

    rt.loot.open(b, "skin")
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_START", { "player", "Cast-3", 8613 })
    rt.events.emit("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", { "player", "Cast-3", 8613 })
    clock.t = clock.t + 2
    assert_eq(select(2, rt.loot.corpse(b)), true, "interrupted: still to skin")
end }

T[#T + 1] = { "Era: loot_object and skin_object as always, nothing ever pending", function()
    calls = {}
    local rt = runtime(false)
    local c = unit({ guid = "Creature-4" })
    rt.loot.open(c, "loot")
    rt.loot.open(c, "skin")
    assert_eq(calls[1], "loot_object", "loot_object")
    assert_eq(calls[2], "skin_object", "skin_object")
    assert_eq(rt.loot.opening(), false, "never pending")
end }

T[#T + 1] = { "Forever: once has_loot has answered, an empty corpse we fought is not ours to loot (1.6.9)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local spider = { guid = "Creature-81", pos = { x = 2, y = 0, z = 0 } }
    local rows = { { guid = "Creature-81", obj = spider, engaged = true } }
    local rt = runtime(true, { player = me, rows = rows })
    rt.loot._poll()                               -- fought it
    local empty = unit({ guid = "Creature-81", pos = { x = 2, y = 0, z = 0 } })
    assert_eq((rt.loot.corpse(empty)), true, "before has_loot has answered: the fight stands in")
    local cutpurse = unit({ guid = "Creature-82", has_loot = true, pos = { x = 3, y = 0, z = 0 } })
    assert_eq((rt.loot.corpse(cutpurse)), true, "has_loot true: ours")
    clock.t = clock.t + 1.1                       -- the empty one is read again
    assert_eq((rt.loot.corpse(empty)), false, "has_loot answers now: fought but empty is not lootable")
    -- The window takes the loot; has_loot catches up a moment later.
    rt.loot.open(cutpurse, "loot")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(cutpurse)), false, "just looted: off the list though has_loot still read true")
    clock.t = clock.t + 3.1
    assert_eq((rt.loot.corpse(cutpurse)), true, "has_loot still true after the hold: something was left, back on")
end }

T[#T + 1] = { "Forever: the second LOOT_OPENED of one window marks no other corpse looted (1.6.10)", function()
    calls = {}
    local me = { guid = "Player-1-ME", pos = { x = 0, y = 0, z = 0 } }
    me.is_moving = function() return false end
    local rt = runtime(true, { player = me })
    local opened = unit({ guid = "Creature-91", has_loot = true, pos = { x = 2, y = 0, z = 0 } })
    local beside = unit({ guid = "Creature-92", has_loot = true, pos = { x = 1, y = 0, z = 0 } })
    rt.loot.corpse(opened)
    rt.loot.corpse(beside)
    rt.loot.open(opened, "loot")
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    clock.t = clock.t + 0.13
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(opened)), false, "the one opened is looted")
    assert_eq((rt.loot.corpse(beside)), true, "the one beside it is still to loot")
    -- A window a while later that nobody pressed for still goes to the nearest.
    clock.t = clock.t + 5
    rt.events.emit("jcore.game_event.LOOT_OPENED", { true, false })
    assert_eq((rt.loot.corpse(beside)), false, "a later window of the player's own: the nearest")
end }

T[#T + 1] = { "Era: the latest press is told to the loot study for two seconds, never waited on (1.6.8)", function()
    calls = {}
    local rt = runtime(false)
    local c = unit({ guid = "Creature-5" })
    assert_eq(rt.loot.attempt(), nil, "nothing pressed yet")
    rt.loot.open(c, "loot")
    local a = rt.loot.attempt()
    assert_eq(a.call, "loot_object", "the call")
    assert_eq(a.guid, "Creature-5", "the corpse")
    assert_eq(a.pending, true, "a window now is this press's")
    assert_eq(rt.loot.opening(), false, "but nothing waits on it")
    clock.t = clock.t + 2.5
    assert_eq(rt.loot.attempt().pending, false, "two seconds on: not any more")
end }

return T

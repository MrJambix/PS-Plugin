-- Jambix AIO 1.89.0: node memory and the bobber (modules/nodememory.lua).
--
-- A herb, vein or chest that goes while you are near is remembered: a ring
-- filling over the respawn, its name and the time left, kept per zone across
-- reloads by the realm's clock, forgotten with a pulse when it is back.
-- Walking away, a list that changes and a node the client still has are not
-- gathering. Your bobber gets a ring, and a pulse when a fish bites: the
-- fishing loop's own (the staged modules/fishing.lua exposes it), or one
-- cast by hand. Drawn through a recording draw, and through the real world
-- layer over one.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0, server = 1790000000 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
    get_server_time = function() return clock.server end,
}
local function advance(dt)
    clock.s = clock.s + dt
    clock.server = clock.server + dt
end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, label, eps)
    if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-6) then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function all(calls, name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
end

--- A fake P around the module: the ESP's node list, the client's objects,
--- you, the world, a store, and a recording draw.
local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    local W = { inst = 1, map = 1429, itype = "none" }
    local me = { pos = { x = 0, y = 0, z = 0 }, guid = "Player-1" }
    function me.get_guid(self) return self.guid end
    function me.is_dead(self) return self.dead == true end
    function me.is_ghost() return false end
    function me.is_channelling_spell(self) return self.chan ~= nil end
    function me.get_active_channel_spell_id(self) return self.chan end
    local listed, client, objects = {}, {}, {}
    local store = o.store or { data = {} }
    store.touched = store.touched or 0
    store.touch = function(self) self.touched = self.touched + 1 end

    local function marks()
        local keys = {}
        for g in pairs(listed) do keys[#keys + 1] = g end
        table.sort(keys)
        local out = {}
        for i = 1, #keys do
            local n = listed[keys[i]]
            local dx, dy = n.pos.x - me.pos.x, n.pos.y - me.pos.y
            if o.classic then
                out[i] = { obj = n, guid = n.guid, kind = n.kind, name = n.name, distance = math.sqrt(dx * dx + dy * dy) }
            else
                out[i] = { obj = n, guid = n.guid, cat = n.kind, name = n.name, d = math.sqrt(dx * dx + dy * dy), pos = n.pos }
            end
        end
        return out
    end

    local P = {
        opt = function(id, fallback)
            local v = settings[id]
            if v == nil then return fallback end
            return v
        end,
        color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end,
        ctx = {
            LAYER = { WORLD = 100 },
            store = function(name)
                assert_eq(name, "nodememory", "the store's name")
                return store
            end,
            world = {
                instance_id = function() return W.inst end,
                map_id = function() return W.map end,
                instance_type = function() return W.itype end,
            },
            spells = { name = function(id) return (o.spell_names or {})[id] end },
        },
        units = {
            player = function() return me end,
            player_position = function() return me.pos end,
            position = function(obj) return obj and obj.pos end,
            by_guid = function(g) return client[g] end,
            guid = function(obj) return obj and obj.guid end,
            objects = function() return objects end,
            distance = function(obj)
                local dx, dy = obj.pos.x - me.pos.x, obj.pos.y - me.pos.y
                return math.sqrt(dx * dx + dy * dy)
            end,
        },
        draw = { ring_3d = rec("ring_3d"), pulse = rec("pulse"), text_3d = rec("text_3d") },
    }
    if o.classic then
        P.esp = { nodes = marks }
    elseif not o.no_esp then
        P.esp = { forever = { node_marks = marks } }
    end
    if o.no_store then P.ctx.store = nil end
    if o.no_world then P.ctx.world = nil end
    if o.fishing then P.fishing = o.fishing end
    if o.draw then P.draw = o.draw(rec) end
    if o.layer then
        package.loaded["jambix_aio/modules/worldlayer"] = nil
        P.worldmarks = require("jambix_aio/modules/worldlayer")(P)
    end
    package.loaded["jambix_aio/modules/nodememory"] = nil
    local M = require("jambix_aio/modules/nodememory")(P)
    local b = { M = M, P = P, calls = calls, me = me, W = W, store = store, settings = settings,
        listed = listed, client = client, objects = objects }
    function b.node(guid, x, y, kind, name)
        local n = { guid = guid, pos = { x = x, y = y, z = 0 }, kind = kind or "herb", name = name or "Peacebloom" }
        listed[guid], client[guid] = n, n
        return n
    end
    function b.gather(guid) listed[guid], client[guid] = nil, nil end
    --- A frame a moment later (the lists are looked at five times a second).
    function b.step(dt)
        advance(dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
        return calls
    end
    return b
end

local function spots(b) return b.store.data.zones and b.store.data.zones["1"] or {} end

local T = {}

T[#T + 1] = { "a herb gathered near you: remembered, a ring there filling over the respawn, the name and time left", function()
    local b = bundle()
    b.node("H1", 10, 0, "herb", "Peacebloom")
    b.step()
    assert_eq(#spots(b), 0, "nothing while it stands")
    assert_eq(#all(b.calls, "ring_3d"), 0, "no ring under a live node")
    local gone_at = math.floor(clock.server + 0.25)
    b.gather("H1")
    local calls = b.step()
    local s = spots(b)
    assert_eq(#s, 1, "remembered")
    assert_eq(s[1].k, "herb", "its kind"); assert_eq(s[1].n, "Peacebloom", "its name")
    assert_eq(s[1].x, 10, "where"); assert_eq(s[1].zn, 1429, "its zone")
    assert_eq(s[1].t, gone_at, "when, on the realm's clock")
    assert(b.store.touched > 0, "the store is told")
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "a ring at once")
    assert_eq(r[1][1].x, 10, "on the spot"); near(r[1][2], 1.1, "its radius")
    near(r[1][3], 0, "empty as it goes", 0.01)
    assert_eq(r[1][5].prio, "decor", "decoration"); assert_eq(r[1][5].module, "nodes", "the nodes'")
    assert_eq(r[1][5].to.g, 230, "filling toward the herb's green")
    local tx = all(calls, "text_3d")
    assert_eq(#tx, 1, "the countdown")
    assert_eq(tx[1][2], "Peacebloom  5:00", "its name and five minutes")
    near(tx[1][1].z, 0.6, "above the ring")
    calls = b.step(150)
    near(all(calls, "ring_3d")[1][3], 150.25 / 300, "half full after half the respawn", 0.01)
    assert_eq(all(calls, "text_3d")[1][2], "Peacebloom  2:30", "two and a half minutes left")
    calls = b.step(151)
    near(all(calls, "ring_3d")[1][3], 1, "full once due")
    assert_eq(all(calls, "ring_3d")[1][4].g, 230, "in the full colour")
    assert_eq(all(calls, "text_3d")[1][2], "Peacebloom  due", "due")
    assert_eq(b.M.stats().gone, 1, "counted")
end }

T[#T + 1] = { "walking away is not gathering, nor a node the ESP stops listing that the client still has", function()
    local b = bundle()
    b.node("H1", 10, 0)
    b.step()
    b.me.pos = { x = 200, y = 0, z = 0 }
    b.gather("H1")
    b.step()
    assert_eq(#spots(b), 0, "190 yd away: out of sight, not taken")

    local b2 = bundle()
    b2.node("H2", 20, 0)
    b2.step()
    b2.listed.H2 = nil                       -- capped, filtered or its switch off
    b2.step(); b2.step(5)
    assert_eq(#spots(b2), 0, "the client still has it")
    b2.step(20)                              -- no longer watched
    b2.client.H2 = nil
    b2.step()
    assert_eq(#spots(b2), 0, "gone long after it left the list: not known to be taken")

    local b3 = bundle()
    b3.node("H3", 59, 0)
    b3.step()
    b3.me.pos = { x = -5, y = 0, z = 0 }    -- 64 yd: past SIGHT
    b3.gather("H3")
    b3.step()
    assert_eq(#spots(b3), 0, "past 60 yd the client may simply have dropped it")
end }

T[#T + 1] = { "seen at the spot again: forgotten with one pulse; another kind there does not count", function()
    local b = bundle()
    b.node("H1", 10, 0)
    b.step(); b.gather("H1"); b.step()
    assert_eq(#spots(b), 1, "remembered")
    b.node("O1", 10.5, 0.5, "ore", "Copper Vein")
    local calls = b.step()
    assert_eq(#spots(b), 1, "a vein at a herb's spot is not its respawn")
    assert_eq(#all(calls, "pulse"), 0, "no pulse")
    b.gather("O1"); b.client.O1 = nil
    b.node("H9", 10.4, -0.6, "herb", "Silverleaf")
    calls = b.step()
    assert_eq(#spots(b), 1, "the herb's spot forgotten, the vein's remembered")
    assert_eq(spots(b)[1].k, "ore", "the vein's is what is left")
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "one pulse")
    assert_eq(p[1][1].x, 10, "at the spot"); assert_eq(p[1][3].prio, "info", "information")
    assert_eq(p[1][3].module, "nodes", "the nodes'")
    calls = b.step()
    assert_eq(#all(calls, "pulse"), 0, "once")
    assert_eq(b.M.stats().respawned, 1, "counted")
end }

T[#T + 1] = { "kept across a reload by the realm's clock; a spot timed by a session's clock is not", function()
    local b = bundle()
    b.node("H1", 10, 0)
    b.step(); b.gather("H1"); b.step()
    local gone_at = spots(b)[1].t
    local data = b.store.data
    data.zones["1"][2] = { x = 30, y = 0, z = 0, k = "ore", n = "Tin Vein", t = 50, zn = 1429, s = 1 }
    clock.s = 5                               -- a reload: core.time() starts over
    clock.server = gone_at + 100
    local again = bundle({ store = { data = data } })
    assert_eq(#data.zones["1"], 1, "the session-timed spot dropped on load")
    local calls = again.step(0)
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "the ring is back")
    near(r[1][3], 100 / 300, "a third full: a hundred seconds on the realm's clock", 0.01)
    assert_eq(all(calls, "text_3d")[1][2], "Peacebloom  3:20", "3:20 left")
    clock.s = 2000
end }

T[#T + 1] = { "the newest 30 a zone; another zone's spots are its own", function()
    local b = bundle()
    for i = 1, 31 do
        local a = i * 2 * math.pi / 31
        b.node("H" .. i, 20 * math.cos(a), 20 * math.sin(a))
    end
    b.step()
    for i = 1, 31 do
        b.gather("H" .. i)
        b.step(1)
    end
    local s = spots(b)
    assert_eq(#s, 30, "thirty kept")
    for i = 1, #s do
        assert(math.abs(s[i].x - 20 * math.cos(2 * math.pi / 31)) > 0.01 or math.abs(s[i].y - 20 * math.sin(2 * math.pi / 31)) > 0.01,
            "the first one gone")
    end
    b.W.map = 1430
    b.node("X1", 40, 0)
    b.step(1.1)
    b.gather("X1")
    b.step()
    assert_eq(#spots(b), 31, "the next zone's own thirty")
    assert_eq(spots(b)[31].zn, 1430, "tagged with its zone")
    assert_eq(#all(b.calls, "ring_3d"), 12, "at most twelve rings")
end }

T[#T + 1] = { "not when more than three go at once, not while dead, not in a dungeon", function()
    local b = bundle()
    for i = 1, 4 do b.node("H" .. i, 10 * i, 0) end
    b.step()
    for i = 1, 4 do b.gather("H" .. i) end
    b.step()
    assert_eq(#spots(b), 0, "four at once: a phase or a loading screen")
    assert_eq(b.M.stats().mass, 1, "counted")
    for i = 1, 3 do b.node("J" .. i, 10 * i, 5) end
    b.step()
    for i = 1, 3 do b.gather("J" .. i) end
    b.step()
    assert_eq(#spots(b), 3, "three at once still count")

    local d = bundle()
    d.node("H1", 10, 0)
    d.step()
    d.me.dead = true
    d.gather("H1")
    d.step()
    assert_eq(#spots(d), 0, "dead: what you see is not what is there")

    local g = bundle()
    g.W.itype = "party"
    g.node("H1", 10, 0)
    g.step(); g.gather("H1"); g.step()
    assert_eq(#(g.store.data.zones["1"] or {}), 0, "nothing respawns in a dungeon")
end }

T[#T + 1] = { "rings out to 120 yd, the countdown to 60; the respawn setting; forgotten half an hour after due", function()
    local now = math.floor(clock.server)
    local data = { zones = { ["1"] = {
        { x = 50, y = 0, z = 0, k = "herb", n = "Mageroyal", t = now, zn = 1429 },
        { x = 100, y = 0, z = 0, k = "ore", n = "Tin Vein", t = now, zn = 1429 },
        { x = 130, y = 0, z = 0, k = "container", n = "Battered Chest", t = now, zn = 1429 },
        { x = 0, y = 30, z = 0, k = "herb", n = "Old", t = now - 600 - 1801, zn = 1429 },
    } } }
    local b = bundle({ store = { data = data }, settings = { nodemem_respawn = 600 } })
    local calls = b.step(0)
    assert_eq(#data.zones["1"], 3, "the one long past due forgotten")
    local r = all(calls, "ring_3d")
    assert_eq(#r, 2, "50 and 100 yd, not 130")
    assert_eq(r[1][1].x, 50, "nearest first")
    assert_eq(r[2][5].to.r, 235, "a vein in its colour")
    assert_eq(#all(calls, "text_3d"), 1, "the countdown on the near one only")
    calls = b.step(300)
    near(all(calls, "ring_3d")[1][3], 0.5, "half of 600 s", 0.01)
end }

T[#T + 1] = { "the Classic ESP's list (P.esp.nodes) works the same", function()
    local b = bundle({ classic = true })
    b.node("O1", 15, 0, "ore", "Copper Vein")
    b.step(); b.gather("O1"); b.step()
    assert_eq(#spots(b), 1, "remembered")
    assert_eq(spots(b)[1].k, "ore", "a vein"); assert_eq(spots(b)[1].n, "Copper Vein", "named")
    assert_eq(all(b.calls, "text_3d")[1][2], "Copper Vein  5:00", "its countdown")
end }

T[#T + 1] = { "switches: node memory off remembers and draws nothing; fishing off draws no bobber", function()
    local bob = { pos = { x = 5, y = 5, z = 0 } }
    local b = bundle({ settings = { nodemem_on = false }, fishing = { bobber = function() return bob, "B1", false end } })
    b.node("H1", 10, 0)
    b.step(); b.gather("H1"); b.step()
    assert_eq(#spots(b), 0, "nothing remembered")
    local r = all(b.calls, "ring_3d")
    assert_eq(#r, 1, "the bobber's ring only")
    assert_eq(r[1][5].module, "fishing", "the fishing one")
    b.settings.nodemem_fishing = false
    assert_eq(#b.step(), 0, "and with fishing off, nothing")
end }

T[#T + 1] = { "fishing, the loop's bobber: a small ring on it, a bright pulse once when it bites", function()
    local bob = { pos = { x = 15, y = 2, z = 0 } }
    local cur = { obj = bob, guid = "B1", bite = false }
    local b = bundle({ fishing = { bobber = function()
        if not cur.obj then return nil end
        return cur.obj, cur.guid, cur.bite
    end } })
    local calls = b.step()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "a ring on it")
    assert_eq(r[1][1].x, 15, "on the bobber"); near(r[1][2], 0.7, "small")
    assert_eq(r[1][5].prio, "info", "information"); assert_eq(r[1][5].module, "fishing", "the fishing one")
    assert_eq(#all(calls, "pulse"), 0, "no pulse yet")
    local quiet = r[1][4]
    cur.bite = true
    calls = b.step(0.05)
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "the splash")
    assert_eq(p[1][1].x, 15, "on the bobber"); assert_eq(p[1][3].prio, "warn", "something to act on")
    assert_eq(p[1][3].module, "fishing", "the fishing one")
    assert(all(calls, "ring_3d")[1][4] ~= quiet, "the ring lit up")
    calls = b.step(0.05)
    assert_eq(#all(calls, "pulse"), 0, "once a bite")
    cur.obj = nil
    calls = b.step()
    assert_eq(#all(calls, "ring_3d"), 0, "no bobber, no ring")
    cur.obj, cur.guid, cur.bite = { pos = { x = 9, y = 9, z = 0 } }, "B2", false
    calls = b.step()
    assert_eq(all(calls, "ring_3d")[1][4], quiet, "a new cast: quiet again")
    cur.bite = true
    assert_eq(#all(b.step(), "pulse"), 1, "and its own splash")
    assert_eq(b.M.stats().bites, 2, "two bites")
end }

T[#T + 1] = { "fishing by hand: the bobber that came with the channel, the loop's bite read on it", function()
    local reads = 0
    local b = bundle({
        fishing = { has_bite = function(obj) reads = reads + 1 return obj.fish == true end },
        spell_names = { [1240959] = "Fishing", [689] = "Drain Life" },
    })
    local function made(guid, x, by)
        local obj = { guid = guid, pos = { x = x, y = 0, z = 0 } }
        local creator = { is_valid = function() return true end, get_guid = function() return by or "Player-1" end }
        obj.get_creator_object = function() return creator end
        obj.is_basic_object = function() return true end
        obj.get_max_health = function() return 0 end
        obj.is_valid = function() return true end
        obj.get_name = function() return "" end
        b.objects[#b.objects + 1] = obj
        return obj
    end
    made("Fire", 2)                          -- your campfire, from before
    made("Other", 12, "Player-2")            -- somebody else's bobber
    b.step()
    b.me.chan = 689
    assert_eq(#all(b.step(), "ring_3d"), 0, "not fishing: nothing")
    b.me.chan = nil
    b.step()
    b.me.chan = 7620
    assert_eq(#all(b.step(), "ring_3d"), 0, "the channel has begun, no bobber yet; never the campfire")
    assert_eq(#all(b.step(1), "ring_3d"), 0, "still never the campfire")
    local bob = made("Bob", 16)
    local calls = b.step()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 1, "the new one is the bobber")
    assert_eq(r[1][1].x, 16, "on it")
    assert_eq(b.M.stats().bobber, "hand", "cast by hand")
    bob.fish = true
    calls = b.step(0.15)
    assert_eq(#all(calls, "pulse"), 1, "the splash")
    assert(reads > 0, "read through the loop's bite read")
    b.me.chan = nil
    assert_eq(#all(b.step(), "ring_3d"), 0, "the channel over: no ring")

    -- Forever's own Fishing, known by its name; the bobber already there
    -- when the channel is first seen.
    b.objects[#b.objects] = nil
    b.me.chan = 1240959
    made("Bob2", 18)
    b.step()
    calls = b.step(0.6)
    assert_eq(#all(calls, "ring_3d"), 1, "the only one away from your feet")
    assert_eq(all(calls, "ring_3d")[1][1].x, 18, "the bobber, not the campfire")

    -- Two away from your feet, both there from the start: the one called a bobber.
    b.me.chan = nil
    b.step()
    b.objects[#b.objects] = nil
    made("Trap", 9)
    local named = made("Bob3", 17)
    named.get_name = function() return "Fishing Bobber" end
    b.me.chan = 7620
    calls = b.step()
    assert_eq(#all(calls, "ring_3d"), 1, "found by its name")
    assert_eq(all(calls, "ring_3d")[1][1].x, 17, "the bobber, not the trap")
end }

T[#T + 1] = { "the staged fishing loop: its bobber and its bite read, read-only, end to end", function()
    local ticks = {}
    local chan = false
    local fp = {}
    function fp.get_guid() return "Player-1" end
    function fp.is_dead() return false end
    function fp.is_ghost() return false end
    function fp.is_in_combat() return false end
    function fp.is_mounted() return false end
    function fp.is_moving() return false end
    function fp.is_casting_spell() return false end
    function fp.is_channelling_spell() return chan end
    function fp.get_active_channel_spell_id() return chan and 7620 or 0 end
    local fobjs = {}
    local saved = {}
    for k, v in pairs(_G.core) do saved[k] = v end
    _G.core.game_ui = { get_loot_item_count = function() return 0 end }
    _G.core.profession = { FISHING = 1, open_profession = function() return true end }
    local Pf = {
        ctx = { on = function() end, tick = function(fn) ticks[#ticks + 1] = fn end, emit = function() end,
            spells = { learned = function() return false end }, inventory = { is_full = function() return false end } },
        log = { debug = function() end, info = function() end, fmt = function() end },
        units = { player = function() return fp end, objects = function() return fobjs end },
        actions = { perform = function() return true, false end, forget = function() end },
        opt = function(id, d)
            if id == "fish_enabled" then return true end
            if id == "fish_stay_active" then return false end
            return d
        end,
        master_on = function() return true end,
    }
    package.loaded["jambix_aio/modules/fishing"] = nil
    local F = require("jambix_aio/modules/fishing")(Pf)
    assert(F.bobber and F.has_bite, "the staged loop exposes them")
    assert_eq(F.bobber(), nil, "no bobber before a cast")
    local tick = ticks[1]
    advance(1); tick()                       -- idle: the cast
    chan = true
    advance(0.1); tick()                     -- casting: the channel
    local bob = { pos = { x = 14, y = 3, z = 0 }, fish = false }
    bob.get_guid = function() return "Bobber-1" end
    bob.is_valid = function() return true end
    bob.get_creator_object = function()
        return { is_valid = function() return true end, get_guid = function() return "Player-1" end }
    end
    bob.is_basic_object = function() return true end
    bob.get_max_health = function() return 0 end
    bob.does_bobber_have_fish = function(self) return self.fish end
    fobjs[1] = bob
    advance(0.1); tick()                     -- waiting: the bobber found
    local o, g, bite = F.bobber()
    assert_eq(o, bob, "the bobber"); assert_eq(g, "Bobber-1", "its guid"); assert_eq(bite, false, "no bite yet")
    assert_eq(F.has_bite(bob), false, "the bite read: nothing")

    local b = bundle({ fishing = F })
    local calls = b.step(0)
    assert_eq(#all(calls, "ring_3d"), 1, "the ring on the loop's bobber")
    assert_eq(b.M.stats().bobber, "loop", "the loop's")
    bob.fish = true
    advance(0.1); tick()                     -- the bite seen
    assert_eq(F.has_bite(bob), true, "the bite read")
    assert_eq(select(3, F.bobber()), true, "the bite, read-only")
    calls = b.step(0)
    assert_eq(#all(calls, "pulse"), 1, "the splash")
    for k in pairs(_G.core) do _G.core[k] = nil end
    for k, v in pairs(saved) do _G.core[k] = v end
end }

T[#T + 1] = { "an older JCore and a bare AIO: no ring_3d draws nothing; no pulse or text_3d, rings only", function()
    local b = bundle({ draw = function() return {} end })
    b.node("H1", 10, 0)
    b.step(); b.gather("H1")
    assert_eq(#b.step(), 0, "nothing, and no error")
    local b2 = bundle({ draw = function(rec) return { ring_3d = rec("ring_3d") } end,
        fishing = { bobber = function() return { pos = { x = 3, y = 3, z = 0 } }, "B", true end } })
    b2.node("H1", 10, 0)
    b2.step(); b2.gather("H1")
    local calls = b2.step()
    assert_eq(#all(calls, "ring_3d"), 2, "the spot's ring and the bobber's")
    b2.node("H2", 10.2, 0)
    b2.step()
    assert_eq(#spots(b2), 0, "forgotten without a pulse to draw")
    local b3 = bundle({ no_esp = true, no_store = true, no_world = true })
    b3.step(); b3.step()
    assert_eq(#b3.M.spots(), 0, "no ESP: nothing to remember, no error")
    local b4 = bundle({ no_store = true, no_world = true })
    b4.node("H1", 10, 0)
    b4.step(); b4.gather("H1"); b4.step()
    assert_eq(#b4.M.spots(), 1, "no store and no world service: kept for the session")
end }

T[#T + 1] = { "through the world layer: rings decor as 'nodes', the bobber info, its splash a warning; Minimal drops the rings and the countdown", function()
    local cur = { bite = false }
    local bob = { pos = { x = 15, y = 2, z = 0 } }
    local b = bundle({ layer = true, fishing = { bobber = function() return bob, "B1", cur.bite end } })
    b.node("H1", 10, 0)
    b.step(); b.P.worldmarks.flush()
    b.gather("H1")
    local calls = b.step()
    assert_eq(#all(calls, "ring_3d"), 0, "kept by the layer, not drawn yet")
    assert_eq(#all(calls, "text_3d"), 1, "the countdown straight through")
    b.P.worldmarks.flush()
    local r = all(calls, "ring_3d")
    assert_eq(#r, 2, "the spot's ring and the bobber's at the flush")
    assert_eq(r[1][5].prio, nil, "the layer's options gone")
    local by = b.P.worldmarks.stats().by
    assert_eq(by.nodes, 1, "one as the nodes'"); assert_eq(by.fishing, 1, "one as fishing's")

    b.settings.world_density = 3
    cur.bite = true
    calls = b.step()
    assert_eq(#all(calls, "text_3d"), 0, "Minimal: no countdown")
    b.P.worldmarks.flush()
    assert_eq(#all(calls, "ring_3d"), 1, "the bobber's ring, not the spot's")
    assert_eq(#all(calls, "pulse"), 1, "the splash kept")
    assert_eq(b.P.worldmarks.stats().dropped, 1, "the decoration dropped")

    b.settings.world_density = 1
    b.node("H2", 10.3, 0.2)
    calls = b.step()
    b.P.worldmarks.flush()
    local p = all(calls, "pulse")
    assert_eq(#p, 1, "the respawn's pulse through the layer")
    assert_eq(p[1][3].prio, nil, "drawn as JCore's")
end }

return T

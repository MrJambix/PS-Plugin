-- Jambix AIO 1.89.0: group extras (modules/groupextras.lua).
--
-- A grey ring under each member past your heal range (a healing class only);
-- a curtain round the tank, green / amber / red by how well it holds the
-- group's mobs (JCore's threat boards, else who each mob is hitting); a blue
-- ring under each healer filling with their mana, red under a fifth. Drawn
-- through a recording draw, and through the real world layer over one.

local root = (jtest and jtest.scripts) or "scripts"
if not package.path:find(root .. "/?.lua", 1, true) then
    package.path = root .. "/?.lua;" .. package.path
end

local clock = { s = 1000.0 }
_G.core = { time = function() return clock.s end, game_time = function() return math.floor(clock.s * 1000 + 0.5) end }

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

--- A group member: where, how far from you, their class, their mana.
local function member(guid, dist, o)
    o = o or {}
    local u = { guid = guid, dist = dist or 10, pos = { x = dist or 10, y = 0, z = 0 }, hp = o.hp or 1,
        class = o.class or 1, mana = o.mana or 0, mana_max = o.mana_max or 0, reach = o.reach or 1.5,
        reads = { power = 0, max = 0, class = 0 } }
    u.get_power = function(self, kind)
        self.reads.power = self.reads.power + 1
        assert(kind == 0, "mana is power type 0")
        return self.mana
    end
    u.get_max_power = function(self, kind)
        self.reads.max = self.reads.max + 1
        assert(kind == 0, "mana is power type 0")
        return self.mana_max
    end
    u.get_class = function(self)
        self.reads.class = self.reads.class + 1
        return self.class
    end
    return u
end

local HEALER_CLASS = { heal_capable = true }
local WARRIOR_CLASS = { heal_capable = false, tank_capable = true }

local function bundle(o)
    o = o or {}
    local calls = {}
    local function rec(name) return function(...) calls[#calls + 1] = { name = name, ... } end end
    local settings = o.settings or {}
    -- 1.7.6: curtains are off by default. These tests are about them, so
    -- each starts on unless a test sets it; `curtains_default` keeps the
    -- shipped defaults.
    if not o.curtains_default then
        for _, id in ipairs({ "groupx_tank" }) do
            if settings[id] == nil then settings[id] = true end
        end
    end
    local me = o.me or member("me", 0, { class = 5 })
    local state = {
        members = o.members or { me },
        tanks = o.tanks or {},
        healers = o.healers or {},
        my_role_healer = o.my_role_healer,
        boards = o.boards or {},
        rows = o.rows or {},
        class_module = o.class_module,
        class_id = o.class_id or 5,
        tune = o.tune or {},
    }
    local draw = o.draw
    if draw == nil then
        draw = { ring_3d = rec("ring_3d"), curtain_3d = rec("curtain_3d"), pulse = rec("pulse") }
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
            group = {
                objects = function() return state.members end,
                tanks = function() return state.tanks end,
                healers = function() return state.healers end,
                is_healer = function(u) return u == me and state.my_role_healer == true end,
            },
            threat = { boards = function() return state.boards end },
            enemies = { all = function() return state.rows end },
            player = { class_id = function() return state.class_id end },
        },
        units = {
            player = function() return me end,
            guid = function(u) return u and u.guid end,
            position = function(u) return u and u.pos end,
            distance = function(u) return u and u.dist or math.huge end,
            combat_reach = function(u) return u and u.reach or 1.5 end,
            health_fraction = function(u) return u and u.hp or 0 end,
            by_guid = function(g)
                for i = 1, #state.members do if state.members[i].guid == g then return state.members[i] end end
                return nil
            end,
        },
        draw = draw,
        assist = o.assist and { state = o.assist } or nil,
        tune_secs = function(id, fallback)
            local v = state.tune[id]
            if v == nil then return fallback end
            return v
        end,
    }
    if not o.no_rotation then
        P.rotation = { active_class = function() return state.class_module end }
    end
    if o.no_group then P.ctx.group = nil end
    if o.no_threat then P.ctx.threat = nil end
    local W = nil
    if o.layer then
        package.loaded["jambix_aio/modules/worldlayer"] = nil
        W = require("jambix_aio/modules/worldlayer")(P)
        P.worldmarks = W
    end
    package.loaded["jambix_aio/modules/groupextras"] = nil
    local M = require("jambix_aio/modules/groupextras")(P)
    local function frame(dt)
        clock.s = clock.s + (dt or 0.25)
        for i = #calls, 1, -1 do calls[i] = nil end
        M.render()
        if W then W.flush() end
    end
    return M, calls, state, frame, settings, W, P
end

local function all(calls, name, module)
    local out = {}
    for i = 1, #calls do
        local c = calls[i]
        if c.name == name and (not module or (c[name == "ring_3d" and 5 or 4] or {}).module == module) then
            out[#out + 1] = c
        end
    end
    return out
end
local function opts_of(c) return c.name == "ring_3d" and c[5] or c[4] end

local EDGE = 1.5 + 0.3       -- a member's model edge at combat reach 1.5

local T = {}

-- --- out of reach ------------------------------------------------------------------

T[#T + 1] = { "out of reach: a grey ring in the reach lane under each member past your heal range; none in range, dead or you", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5 })
    local a, b, c = member("a", 30), member("b", 50), member("c", 60, { hp = 0 })
    local M, calls, _, frame = bundle({ me = me, members = { me, a, b, c }, class_module = HEALER_CLASS })
    frame(0)
    local rings = all(calls, "ring_3d", "reach")
    assert_eq(#rings, 1, "one member out of reach and alive")
    local r = rings[1]
    assert_eq(r[1], b.pos, "under b")
    near(r[2], EDGE + 0.7 + 0.25, "the reach lane's radius without the world layer")
    assert_eq(r[3], 1, "a whole ring")
    assert(r[4].r == 165 and r[4].g == 165 and r[4].b == 175, "grey")
    local op = r[5]
    assert_eq(op.lane, "reach", "lane"); assert_eq(op.unit, b, "unit"); assert_eq(op.prio, "info", "prio")
    assert_eq(op.module, "reach", "module"); assert_eq(op.layer, 100, "layer")
    near(op.inner, 1 - 0.2 / r[2], "a thin band inside the lane")
    assert_eq(M.stats().reach, 1, "counted")
    assert_eq(M.stats().range, 40, "the default range")
end }

T[#T + 1] = { "out of reach only when you can heal: a warrior none, a heal class yes; no rotation, the class id; a healer role", function()
    clock.s = 1000.0
    local me, far = member("me", 0), member("far", 50)
    local _, calls, _, frame = bundle({ me = me, members = { me, far }, class_module = WARRIOR_CLASS })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 0, "a warrior has no heal")

    _, calls, _, frame = bundle({ me = me, members = { me, far }, class_module = HEALER_CLASS })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 1, "a hybrid or healer, any spec")

    _, calls, _, frame = bundle({ me = me, members = { me, far }, no_rotation = true, class_id = 11 })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 1, "no rotation: a druid by its class id")

    local M, st
    M, calls, st, frame = bundle({ me = me, members = { me, far }, no_rotation = true, class_id = 4 })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 0, "a rogue")
    st.my_role_healer = true
    frame(1.0)
    assert_eq(#all(calls, "ring_3d", "reach"), 0, "who you are is asked every two seconds")
    frame(1.1)
    assert_eq(#all(calls, "ring_3d", "reach"), 1, "the group says you heal")
    assert_eq(M.stats().healer, true, "stats")
end }

T[#T + 1] = { "the heal range: a healing class's own (the class window's, worked out from its heals), else the setting", function()
    clock.s = 1000.0
    local me, a, b = member("me", 0), member("a", 35), member("b", 42)
    local M, calls, _, frame = bundle({ me = me, members = { me, a, b }, class_module = HEALER_CLASS,
        tune = { rot_heal_range = 30 }, settings = { groupx_heal_range = 45 } })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 2, "30 yd: both out")
    assert_eq(M.stats().range, 30, "the class's range wins")

    M, calls, _, frame = bundle({ me = me, members = { me, a, b }, no_rotation = true, class_id = 7,
        settings = { groupx_heal_range = 45 } })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 0, "no rotation: the setting's 45 yd")
    b.dist = 46
    frame(2.1)
    assert_eq(#all(calls, "ring_3d", "reach"), 1, "past 45")
    b.dist = 42
end }

-- --- the tank's hold ------------------------------------------------------------------

local function tank_group(o)
    o = o or {}
    local me = member("me", 0, { class = 5 })
    local tank = member("T", 8, { class = 1 })
    local dps = member("A", 12, { class = 8 })
    o.me, o.members = me, { me, tank, dps }
    if o.tanks == nil then o.tanks = { tank } end
    o.class_module = o.class_module or HEALER_CLASS
    local M, calls, st, frame, settings = bundle(o)
    return M, calls, st, frame, settings, me, tank, dps
end

T[#T + 1] = { "the tank's hold: green with room, amber with someone within a fifth, red with a mob on someone else", function()
    clock.s = 1000.0
    local M, calls, st, frame, _, _, tank = tank_group()
    st.boards = { { guid = "m1", tank = { guid = "T" }, next_percent = 50 } }
    frame()
    local cs = all(calls, "curtain_3d", "tank")
    assert_eq(#cs, 1, "a curtain")
    assert_eq(cs[1][1], tank.pos, "round the tank")
    near(cs[1][2], EDGE + 1.6, "outside the mana lane")
    assert(cs[1][3].r == 90 and cs[1][3].g == 220, "green")
    assert_eq(cs[1][4].prio, "info", "green is information"); assert_eq(cs[1][4].unit, tank, "under the tank")
    assert_eq(M.stats().tank, "held", "stats")

    st.boards[1].next_percent = 85
    frame()
    cs = all(calls, "curtain_3d", "tank")
    assert(cs[1][3].r == 245 and cs[1][3].g == 190, "amber")
    assert_eq(cs[1][4].prio, "warn", "amber warns")
    st.boards[1].next_percent = 78
    frame()
    assert_eq(M.stats().tank, "close", "back under 80 is not green yet")
    st.boards[1].next_percent = 70
    frame()
    assert_eq(M.stats().tank, "held", "under 75: green again")

    st.boards[2] = { guid = "m2", tank = { guid = "A" }, next_percent = 40 }
    frame()
    cs = all(calls, "curtain_3d", "tank")
    assert(cs[1][3].r == 240 and cs[1][3].g == 70, "red")
    assert_eq(cs[1][4].prio, "warn", "red warns")
    assert_eq(M.stats().tank, "off", "stats")

    st.boards[2] = nil
    frame()
    assert_eq(M.stats().tank, "off", "red holds a moment (a mob turning to a caster mid-cast)")
    frame(0.5)
    assert_eq(M.stats().tank, "held", "then green")

    st.boards = {}
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "no fight: no curtain")
end }

T[#T + 1] = { "the hold is read five times a second, not every frame", function()
    clock.s = 1000.0
    local M, _, st, frame = tank_group()
    local asked = 0
    st.boards = { { guid = "m1", tank = { guid = "T" }, next_percent = 10 } }
    local real = st.boards
    st.boards = setmetatable({}, { __index = function(_, k) asked = asked + 1 return real[k] end,
        __len = function() return #real end })
    for _ = 1, 60 do frame(1 / 60) end
    assert(asked <= 12, "about five reads in a second, got " .. asked)
    assert_eq(M.stats().tank, "held", "and it answers")
end }

T[#T + 1] = { "Forever: no threat read -- who each mob is hitting says on the tank or off it, never amber", function()
    clock.s = 1000.0
    local M, calls, st, frame = tank_group()
    st.boards = {}
    st.rows = { { guid = "m1", in_combat = true, target_guid = "T" },
        { guid = "m9", in_combat = true, target_guid = "stranger" },
        { guid = "m8", in_combat = false, target_guid = "A" } }
    frame()
    assert_eq(M.stats().tank, "held", "on the tank; a stranger's mob and one out of the fight do not count")
    st.rows[4] = { guid = "m2", in_combat = true, target_guid = "A" }
    frame()
    assert_eq(M.stats().tank, "off", "one on the dps")
    st.rows[4] = { guid = "m2", in_combat = true, target_guid = "A", activity = "dead" }
    frame(1)
    assert_eq(M.stats().tank, "held", "a dead mob does not count")

    -- A board JCore inferred from the mob's target has no runner-up to trust.
    st.rows = {}
    st.boards = { { guid = "m1", tank = { guid = "T", inferred = true }, next_percent = 95 } }
    frame()
    assert_eq(M.stats().tank, "held", "inferred: never amber")
    -- A board's word beats the row's: the client says the tank holds it.
    st.boards = { { guid = "m1", tank = { guid = "T" }, next_percent = 20 } }
    st.rows = { { guid = "m1", in_combat = true, target_guid = "A" } }
    frame()
    assert_eq(M.stats().tank, "held", "the board, not the mob's passing target")

    M, calls, st, frame = tank_group({ no_threat = true })
    st.rows = { { guid = "m1", in_combat = true, target_guid = "T" } }
    frame()
    assert_eq(#all(calls, "curtain_3d", "tank"), 1, "no threat service at all: the rows")
end }

T[#T + 1] = { "the tank: the group's role, else Assist the tank's, else you; none known, no curtain", function()
    clock.s = 1000.0
    local tank_obj = nil
    local M, calls, st, frame, _, me, tank = tank_group({ tanks = {}, assist = { tank_guid = "T" } })
    tank_obj = tank
    st.rows = { { guid = "m1", in_combat = true, target_guid = "T" } }
    frame()
    local cs = all(calls, "curtain_3d", "tank")
    assert_eq(#cs, 1, "Assist the tank's tank")
    assert_eq(cs[1][1], tank_obj.pos, "round them")

    M, calls, st, frame, _, me = tank_group({ tanks = {}, assist = { why = "you are the tank" } })
    st.rows = { { guid = "m1", in_combat = true, target_guid = "me" } }
    frame()
    cs = all(calls, "curtain_3d", "tank")
    assert_eq(#cs, 1, "you")
    assert_eq(cs[1][1], me.pos, "round you")
    assert_eq(cs[1][4].unit, nil, "no unit under yourself")

    M, calls, st, frame = tank_group({ tanks = {} })
    st.rows = { { guid = "m1", in_combat = true, target_guid = "A" } }
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "no tank known: nothing")
end }

-- --- healer mana ------------------------------------------------------------------

T[#T + 1] = { "healer mana: a blue ring in the mana lane filling with their mana, red and a warning under a fifth; not you", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5, mana = 100, mana_max = 1000 })
    local h = member("H", 10, { class = 11, mana = 600, mana_max = 1000 })
    local M, calls, _, frame = bundle({ me = me, members = { me, h }, healers = { me, h }, class_module = WARRIOR_CLASS })
    frame(0)
    local rings = all(calls, "ring_3d", "mana")
    assert_eq(#rings, 1, "one ring: yours is your own bar")
    local r = rings[1]
    assert_eq(r[1], h.pos, "under the healer")
    near(r[2], EDGE + 1.05 + 0.25, "the mana lane")
    near(r[3], 0.6, "60% mana")
    assert(r[4].b == 245 and r[4].r == 70, "blue")
    assert_eq(r[5].lane, "mana", "lane"); assert_eq(r[5].unit, h, "unit"); assert_eq(r[5].prio, "info", "info")
    h.mana = 150
    frame(0.6)
    r = all(calls, "ring_3d", "mana")[1]
    near(r[3], 0.15, "15%")
    assert(r[4].r == 240 and r[4].g == 70, "red under a fifth")
    assert_eq(r[5].prio, "warn", "and a warning")
    assert_eq(M.stats().mana, 1, "stats")

    local blind = member("B", 10, { class = 5, mana = 0, mana_max = 0 })
    _, calls, _, frame = bundle({ me = me, members = { me, blind }, healers = { blind } })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "mana"), 0, "0 of 0 (Forever): no ring rather than an empty one")
    h.mana = 600
end }

T[#T + 1] = { "mana reads are rationed: two healers a frame, twice a second each, the pool every five seconds", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 1 })
    local a = member("a", 10, { class = 5, mana = 500, mana_max = 1000 })
    local b = member("b", 10, { class = 5, mana = 500, mana_max = 1000 })
    local c = member("c", 10, { class = 5, mana = 500, mana_max = 1000 })
    local _, calls, _, frame = bundle({ me = me, members = { me, a, b, c }, healers = { a, b, c }, class_module = WARRIOR_CLASS })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "mana"), 2, "two read in the first frame")
    frame(1 / 60)
    assert_eq(#all(calls, "ring_3d", "mana"), 3, "the third the next")
    for _ = 1, 58 do frame(1 / 60) end
    assert(a.reads.power <= 3, "about twice a second, got " .. a.reads.power)
    assert_eq(a.reads.max, 1, "the pool once")
    for _ = 1, 300 do frame(1 / 60) end
    assert(a.reads.max <= 2, "and again after five seconds, got " .. a.reads.max)
end }

T[#T + 1] = { "nobody set as a healer: every healing class but you and the tank, the class asked once", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5, mana = 900, mana_max = 1000 })
    local pr = member("pr", 10, { class = 5, mana = 400, mana_max = 1000 })
    local wa = member("wa", 10, { class = 1, mana = 0, mana_max = 0 })
    local dr = member("dr", 10, { class = 11, mana = 400, mana_max = 1000 })
    local _, calls, _, frame = bundle({ me = me, members = { me, pr, wa, dr }, healers = {}, tanks = { dr },
        class_module = HEALER_CLASS })
    frame(0)
    local rings = all(calls, "ring_3d", "mana")
    assert_eq(#rings, 1, "only the priest")
    assert_eq(rings[1][1], pr.pos, "under the priest")
    frame(1)
    assert_eq(pr.reads.class, 1, "a member's class asked once")
end }

-- --- switches and older parts ---------------------------------------------------------

T[#T + 1] = { "switches, and nothing out of a group", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5 })
    local tank = member("T", 50, { class = 1 })
    local h = member("H", 10, { class = 7, mana = 500, mana_max = 1000 })
    local _, calls, st, frame, settings = bundle({ me = me, members = { me, tank, h }, tanks = { tank }, healers = { h },
        class_module = HEALER_CLASS, rows = { { guid = "m1", in_combat = true, target_guid = "T" } } })
    frame(0)
    assert_eq(#all(calls, "ring_3d", "reach"), 1, "reach on")
    assert_eq(#all(calls, "curtain_3d", "tank"), 1, "tank on")
    assert_eq(#all(calls, "ring_3d", "mana"), 1, "mana on")
    settings.groupx_range = false
    frame()
    assert_eq(#all(calls, "ring_3d", "reach"), 0, "reach off")
    assert_eq(#all(calls, "curtain_3d", "tank"), 1, "tank still on")
    settings.groupx_range, settings.groupx_tank = true, false
    frame()
    assert_eq(#all(calls, "curtain_3d"), 0, "tank off")
    settings.groupx_tank, settings.groupx_mana = true, false
    frame()
    assert_eq(#all(calls, "ring_3d", "mana"), 0, "mana off")
    settings.groupx_mana, settings.groupx_on = true, false
    frame()
    assert_eq(#calls, 0, "all off")
    settings.groupx_on = true
    st.members = { me }
    frame()
    assert_eq(#calls, 0, "a group of one: nothing")
end }

T[#T + 1] = { "an older JCore: no ring or curtain in its draw, no group, no threat -- nothing drawn, no error", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5 })
    local tank = member("T", 50, { class = 1 })
    local h = member("H", 10, { class = 7, mana = 500, mana_max = 1000 })
    local base = { me = me, members = { me, tank, h }, tanks = { tank }, healers = { h }, class_module = HEALER_CLASS,
        rows = { { guid = "m1", in_combat = true, target_guid = "T" } } }
    local function with(extra)
        local o = {}
        for k, v in pairs(base) do o[k] = v end
        for k, v in pairs(extra) do o[k] = v end
        return o
    end
    local _, calls, _, frame = bundle(with({ draw = {} }))
    frame(0)
    assert_eq(#calls, 0, "a draw with neither")
    _, calls, _, frame = bundle(with({ draw = false }))
    frame(0)
    assert_eq(#calls, 0, "no draw at all")
    local rings = {}
    _, calls, _, frame = bundle(with({ draw = { ring_3d = function(...) rings[#rings + 1] = { ... } end } }))
    frame(0)
    assert_eq(#rings, 2, "rings without a curtain: reach and mana, no curtain asked for")
    _, calls, _, frame = bundle(with({ no_group = true }))
    frame(0)
    assert_eq(#calls, 0, "no group service")
    _, calls, _, frame = bundle(with({ no_threat = true, rows = {} }))
    frame(0)
    assert_eq(#all(calls, "curtain_3d"), 0, "no threat service and no rows: no fight")

    -- The world layer over an older draw: kept, never drawn, no error.
    local layered = {}
    _, calls, _, frame = bundle(with({ layer = true, draw = { pulse = function() layered[#layered + 1] = 1 end } }))
    frame(0)
    assert_eq(#calls + #layered, 0, "under the layer too")
end }

T[#T + 1] = { "through the world layer: each band outside the one before, the curtain outside them all, counted per module", function()
    clock.s = 1000.0
    local me = member("me", 0, { class = 5 })
    local tank = member("T", 50, { class = 1, mana = 0, mana_max = 0 })
    local h = member("H", 55, { class = 7, mana = 300, mana_max = 1000, reach = 2.0 })
    -- 1.7.6: the tank's curtain is off by default.
    local M, calls, st, frame, _, W = bundle({ layer = true, me = me, members = { me, tank, h }, tanks = { tank },
        healers = { h }, class_module = HEALER_CLASS, rows = { { guid = "m1", in_combat = true, target_guid = "H" } },
        settings = { groupx_tank = true } })
    frame(0)
    local reach = all(calls, "ring_3d")
    assert_eq(#reach, 3, "two reach rings and a mana ring")
    local by = W.stats().by
    assert_eq(by.reach, 2, "reach"); assert_eq(by.mana, 1, "mana"); assert_eq(by.tank, 1, "tank")
    -- The healer's rings: reach then mana, each outside the party lane's band.
    local hr, hm
    for i = 1, #reach do
        local c = reach[i]
        if c[1] == h.pos and c[3] == 1 then hr = c elseif c[1] == h.pos then hm = c end
    end
    assert(hr and hm, "both under the healer")
    near(hr[2], W.lane_radius(h, "reach"), "the layer's reach lane")
    near(hm[2], W.lane_radius(h, "mana"), "the layer's mana lane")
    assert(hr[2] * hr[5].inner > W.lane_radius(h, "party"), "reach clear of the health ring")
    assert(hm[2] * hm[5].inner > hr[2], "mana clear of reach")
    assert_eq(hr[5].lane, nil, "the layer took its own options off")
    local cs = all(calls, "curtain_3d")
    assert_eq(#cs, 1, "the curtain")
    assert(cs[1][2] > W.lane_radius(tank, "mana"), "round the tank, outside every ring")
    assert(cs[1][3].r == 240 and cs[1][3].g == 70, "red: the mob is on the healer")
    assert_eq(M.stats().tank, "off", "stats")
    st.rows = {}
    frame(1)
    assert_eq(#all(calls, "curtain_3d"), 0, "the fight is over")
end }

return T

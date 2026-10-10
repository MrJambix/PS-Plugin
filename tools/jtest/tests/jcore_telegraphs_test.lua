-- JCore 1.8.0 / services/telegraphs.lua: where an enemy's spell is about to
-- land, from the files tools/jcheck/telegraph_extract.js wrote (the real ones,
-- scripts_data/jcore/telegraphs/<client>). The service runs against a
-- hand-made runtime: a scripted clock, the player, mobs whose casts are set by
-- hand, missiles, auras, and the combat log fired directly.
--
--   cone        Onyxia's Flame Breath from her facing: in front is in, behind is out
--   placed      Flamestrike lands where its target stood when it started, and the
--               ground stays for the spell's duration once the cast completes
--   unplaced    a hostile player's Blizzard with no unit target: an alert, no ground
--   wide        Bellowing Roar's 100 yards is the room: an alert, not a circle
--   missile     Onyxia's Fireball: an 8-yard circle where the missile lands
--   hazards     Chill on you (an aura) and Nauseous Gas hitting you (the log)
--   cost        a mob casting nothing known costs no native call

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local json = require("jcore/lib/json")
local make_geometry = require("jcore/services/geometry")
local make_telegraphs = require("jcore/services/telegraphs")

local clock = { s = 1000.0 }
_G.core = {
    time = function() return clock.s end,
    game_time = function() return math.floor(clock.s * 1000) end,
}

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end
local function near(got, want, eps, label)
    if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-6) then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A runtime around the service. `client` is "vanilla" or "forever".
local function world(client)
    local W = { rows = {}, missiles = {}, objects = {}, auras = {}, emitted = {}, handlers = {},
        reads = { rotation = 0, spell_target = 0 }, in_combat = true }
    function W.obj(guid, x, y, z, o)
        o = o or {}
        local u = { guid = guid, pos = { x = x, y = y, z = z or 0 }, is_player = o.is_player, is_enemy = o.is_enemy }
        u.is_valid = function() return true end
        u.get_guid = function() return guid end
        u.is_in_combat = function() return W.in_combat end
        u.get_rotation = function()
            W.reads.rotation = W.reads.rotation + 1
            return u.facing or 0
        end
        u.get_active_spell_target = function()
            W.reads.spell_target = W.reads.spell_target + 1
            return u.spell_target
        end
        W.objects[guid] = u
        return u
    end
    W.me = W.obj("me", 0, 0, 0)
    --- A hostile mob row as enemies.all() hands it out.
    function W.mob(guid, x, y, o)
        local u = W.obj(guid, x, y, 0, { is_enemy = true, is_player = o and o.is_player })
        local row = { guid = guid, obj = u, x = x, y = y, z = 0, target_guid = o and o.target or "me" }
        W.rows[#W.rows + 1] = row
        return row, u
    end
    function W.cast(row, spell_id, seconds, opts)
        local now_ms = core.game_time()
        row.casting = {
            spell_id = spell_id, channel = opts and opts.channel or false,
            start_at = now_ms, end_at = now_ms + math.floor(seconds * 1000),
            interruptible = true, remaining = seconds,
        }
    end
    local function read(name)
        local text = jtest.read_file("scripts_data/" .. name)
        if not text then return nil, "missing " .. name end
        return json.decode(text)
    end
    local events = {
        on = function(name, fn) W.handlers[name] = fn end,
        emit = function(name, t) W.emitted[#W.emitted + 1] = { name = name, key = t and t.key, spell = t and t.spell_id } end,
    }
    local units = {
        player = function() return W.me end,
        player_position = function() return W.me.pos end,
        guid = function(u) return u and u.guid end,
        by_guid = function(g) return W.objects[g] end,
        position = function(u) return u and u.pos end,
        snapshot = function(u) return u and { guid = u.guid, is_enemy = u.is_enemy == true, is_player = u.is_player == true } end,
        aura_index = function() return W.auras end,
    }
    local rt = {
        util = { clamp = function(v, a, b) return math.max(a, math.min(b, v)) end },
        events = events,
        log = { for_tag = function() return { fmt = function() end, info = function() end, debug = function() end } end },
        cache = {
            new = function() return { get = function() return nil, false end, put = function(_, _, v) return v end } end,
            try = function(fn, ...) local ok, v = pcall(fn, ...) if ok then return v end end,
        },
        units = units,
        enemies = { all = function() return W.rows end },
        missiles = {
            all = function() return W.missiles end,
            time_to_impact = function(m)
                local dx, dy = m.impact_position.x - m.current_position.x, m.impact_position.y - m.current_position.y
                return math.sqrt(dx * dx + dy * dy) / m.speed
            end,
        },
        storage = { read_json = read },
        world = { client = function() return { forever = client == "forever" } end },
    }
    rt.geometry = make_geometry(rt)
    W.rt = rt
    W.T = make_telegraphs(rt)
    function W.tick(dt)
        clock.s = clock.s + (dt or 0)
        W.T._poll()
    end
    function W.find(spell_id, phase)
        local list = W.T.active()
        for i = 1, #list do
            if list[i].spell_id == spell_id and (not phase or list[i].phase == phase) then return list[i] end
        end
        return nil
    end
    function W.count(name)
        local n = 0
        for i = 1, #W.emitted do if W.emitted[i].name == name then n = n + 1 end end
        return n
    end
    return W
end

local T = {}

T[#T + 1] = { "the data: shapes from the spell tables, advice from DBM", function()
    local W = world("vanilla")
    assert_eq(W.T.available(), true, "available")
    local fb = W.T.info(18435)
    assert(fb and fb.sh and fb.sh[1], "Flame Breath has a shape")
    assert_eq(fb.sh[1].k, "cone", "Flame Breath is a cone")
    assert_eq(fb.sh[1].r, 45, "45 yards")
    assert_eq(fb.sh[1].d, 120, "120 degrees")
    assert_eq(fb.n, "Flame Breath", "name from SpellName")
    assert_eq(W.T.info(17086).hint, "Breath: get out of the front", "Deep Breath: DBM's breathsoon")
    assert_eq(W.T.info(17086).lv, 3, "a boss mod says move: level 3")
    local ww = W.T.info(13736)
    assert_eq(ww.sh[1].via, 15589, "Whirlwind's 8 yards come from the spell it triggers")
    assert_eq(W.T.info(133), nil, "Fireball (the mage's) leaves no shape")
    assert_eq(W.T.info(999999), nil, "an unknown id")
end }

T[#T + 1] = { "a cone: in front is in, behind is out, from the caster's facing", function()
    local W = world("vanilla")
    local row, ony = W.mob("ony", 0, 0)
    ony.facing = 0                                   -- facing +x
    W.me.pos = { x = 20, y = 0, z = 0 }              -- straight ahead
    W.cast(row, 18435, 2.0)
    W.tick(0)
    local t = W.find(18435, "cast")
    assert(t, "Flame Breath is live")
    assert_eq(t.shape, "cone", "cone")
    assert_eq(t.placed, true, "placed")
    assert_eq(t.wide, false, "45 yards, but a cone is never the room")
    assert_eq(t.inside, true, "ahead of her: in it")
    near(t.facing, 0, 1e-9, "her facing")
    near(t.towards.x, 45, 1e-6, "towards: the point at her radius straight ahead")
    assert_eq(W.count("jcore.telegraph.started"), 1, "started once")
    assert_eq(W.count("jcore.telegraph.on_me"), 1, "on me once")
    W.tick(1.0)
    near(t.progress, 0.5, 1e-6, "half way through the cast")
    near(t.remaining, 1.0, 1e-6, "a second left")
    W.me.pos = { x = -20, y = 0, z = 0 }             -- behind her
    W.tick(0.1)
    assert_eq(W.find(18435).inside, false, "behind her: out")
    W.me.pos = { x = 10, y = 30, z = 0 }             -- 71.6 degrees off her nose, outside the 60 each side
    W.tick(0.1)
    assert_eq(W.find(18435).inside, false, "off to the side: out")
    W.me.pos = { x = 30, y = 10, z = 0 }             -- 18 degrees off: in
    W.tick(0.1)
    assert_eq(W.find(18435).inside, true, "a little off her nose: in")
    assert_eq(W.count("jcore.telegraph.started"), 1, "still the one telegraph")
    assert_eq(W.T.on_me()[1], W.find(18435), "on_me lists it")
    row.casting = nil
    W.tick(0.1)
    assert_eq(W.find(18435), nil, "the cast ended: gone (no ground left behind)")
end }

T[#T + 1] = { "placed at the target, locked as ground, and the ground stays once the cast completes", function()
    local W = world("vanilla")
    local row, caster = W.mob("mage", 0, 30)
    caster.spell_target = W.me
    W.me.pos = { x = 0, y = 0, z = 0 }
    W.cast(row, 11829, 3.0)                          -- Flamestrike: 5 yards at the target, 8 s of fire
    W.tick(0)
    local t = W.find(11829, "cast")
    assert(t and t.placed, "placed")
    near(t.x, 0, 1e-9, "on me")
    assert_eq(t.inside, true, "standing in it")
    assert_eq(W.reads.spell_target, 1, "the cast target is read once")
    W.me.pos = { x = 10, y = 0, z = 0 }              -- step out
    W.tick(1.0)
    t = W.find(11829, "cast")
    near(t.x, 0, 1e-9, "the ground point does not follow me")
    assert_eq(t.inside, false, "stepped out")
    assert_eq(W.reads.spell_target, 1, "still one read")
    W.tick(2.0)
    row.casting = nil                                -- the cast completed on time
    W.tick(0.05)
    local g = W.find(11829, "linger")
    assert(g, "the fire stays on the ground")
    near(g.remaining, 8.0, 1e-6, "for the spell's 8 seconds")
    W.tick(7.0)
    assert(W.find(11829, "linger"), "still there at 7 s")
    W.tick(1.5)
    assert_eq(W.find(11829), nil, "gone after 8 s")
end }

T[#T + 1] = { "a cast cut short leaves no ground", function()
    local W = world("vanilla")
    local row, caster = W.mob("mage", 0, 30)
    caster.spell_target = W.me
    W.cast(row, 11829, 3.0)
    W.tick(0)
    W.tick(1.0)
    row.casting = nil                                -- interrupted two seconds early
    W.tick(0.05)
    assert_eq(W.find(11829), nil, "no fire")
end }

T[#T + 1] = { "a hostile player's ground spell with no unit target: an alert, no ground", function()
    local W = world("vanilla")
    local row = W.mob("rogue_mage", 0, 25, { is_player = true })
    W.cast(row, 10, 8.0, { channel = true })         -- Blizzard
    W.tick(0)
    local t = W.find(10)
    assert(t, "Blizzard is live")
    assert_eq(t.phase, "channel", "a channel")
    assert_eq(t.placed, false, "its point is not readable: not placed")
    assert_eq(t.inside, false, "and nobody is said to be in it")
end }

T[#T + 1] = { "the room: Bellowing Roar is wide", function()
    local W = world("vanilla")
    local row = W.mob("ony", 0, 30)
    W.cast(row, 18431, 1.5)
    W.tick(0)
    local t = W.find(18431)
    assert(t, "live")
    assert_eq(t.wide, true, "100 yards: wide")
    assert_eq(t.hint, "Fear soon", "DBM's fearsoon")
    assert_eq(W.T.danger_at({ x = 0, y = 0, z = 0 }), nil, "a wide one is no place to avoid")
end }

T[#T + 1] = { "a missile: a circle where it lands, filling as it flies", function()
    local W = world("vanilla")
    local _, ony = W.mob("ony", 0, 40)
    W.missiles[1] = {
        spell_id = 18392, caster = ony, speed = 20,
        source_position = { x = 0, y = 40, z = 0 }, current_position = { x = 0, y = 40, z = 0 },
        impact_position = { x = 1, y = 0, z = 0 },
    }
    W.tick(0)
    local t = W.find(18392, "missile")
    assert(t and t.placed, "placed at the impact")
    assert_eq(t.radius, 8, "8 yards")
    assert_eq(t.inside, true, "I am under it")
    near(t.progress, 0, 1e-9, "just fired")
    W.missiles[1].current_position = { x = 0.5, y = 20, z = 0 }
    W.tick(1.0)
    assert(t.progress > 0.45 and t.progress < 0.55, "half way: " .. tostring(t.progress))
    W.missiles[1] = nil
    W.tick(0.1)
    assert_eq(W.find(18392), nil, "landed: gone")
end }

T[#T + 1] = { "a friendly missile is not a telegraph", function()
    local W = world("vanilla")
    local friend = W.obj("friend", 0, 10, 0, { is_enemy = false })
    W.missiles[1] = {
        spell_id = 18392, caster = friend, speed = 20,
        current_position = { x = 0, y = 10, z = 0 }, impact_position = { x = 0, y = 0, z = 0 },
    }
    W.tick(0)
    assert_eq(#W.T.active(), 0, "nothing")
end }

T[#T + 1] = { "hazards with no cast bar: Chill on me, and Nauseous Gas hitting me", function()
    local W = world("vanilla")
    W.auras[28547] = { buff_id = 28547 }
    W.tick(0.3)
    local t = W.find(28547, "aura")
    assert(t, "Chill on me")
    assert_eq(t.inside, true, "in it")
    assert_eq(t.hint, "Out of the bad", "DBM's watchfeet")
    assert_eq(t.placed, true, "Chill's own 3 yards, around me")
    assert_eq(t.level, 3, "level 3")
    W.auras[28547] = nil
    W.tick(0.3)
    assert_eq(W.find(28547), nil, "the aura fell off")

    local cleu = W.handlers["jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED"]
    assert(cleu, "the service listens to the combat log")
    cleu({ 0, "SPELL_DAMAGE", false, "boss", "Boss", 0x48, 0, "me", "Me", 0, 0, 438136, "Nauseous Gas", 8 })
    W.tick(0.05)
    local h = W.find(438136, "hit")
    assert(h, "a hit by Nauseous Gas")
    assert_eq(h.hint, "Out of the bad", "DBM's watchfeet voice, ahead of its gtfo kind")
    assert_eq(h.placed, false, "no ground: an alert")
    W.tick(2.0)
    assert_eq(W.find(438136), nil, "the alert drops after a moment")
    cleu({ 0, "SPELL_DAMAGE", false, "boss", "Boss", 0x48, 0, "someone", "Them", 0, 0, 438136, "Nauseous Gas", 8 })
    W.tick(0.05)
    assert_eq(W.find(438136), nil, "a hit on someone else is not mine")
end }

T[#T + 1] = { "an instant cast that leaves its ground (Consecration), from the combat log", function()
    local W = world("vanilla")
    W.mob("pally", 3, 0)
    local cleu = W.handlers["jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED"]
    W.tick(0)
    cleu({ 0, "SPELL_CAST_SUCCESS", false, "pally", "Pally", 0x548, 0, "", "", 0, 0, 26573, "Consecration", 2 })
    W.tick(0.05)
    local t = W.find(26573, "linger")
    assert(t and t.placed, "on the ground where the paladin stood")
    assert_eq(t.inside, true, "3 yards from it: in")
    cleu({ 0, "SPELL_CAST_SUCCESS", false, "friend", "Friend", 0x511, 0, "", "", 0, 0, 26573, "Consecration", 2 })
    W.tick(0.05)
    local n = 0
    for _, x in ipairs(W.T.active()) do if x.spell_id == 26573 then n = n + 1 end end
    assert_eq(n, 1, "a friendly one is not")
end }

T[#T + 1] = { "cost: a mob casting nothing known reads nothing", function()
    local W = world("vanilla")
    local row = W.mob("boar", 5, 5)
    W.tick(0)
    row.casting = { spell_id = 133, start_at = 0, end_at = 1 }   -- a plain Fireball: no shape
    W.tick(0.1)
    assert_eq(W.reads.rotation + W.reads.spell_target, 0, "no native reads")
    assert_eq(#W.T.active(), 0, "nothing live")
end }

T[#T + 1] = { "Forever reads its own copy", function()
    local W = world("forever")
    assert_eq(W.T.available(), true, "available")
    assert_eq(W.T.stats().source, "jcore/telegraphs/forever", "the forever folder")
    local bz = W.T.info(10)
    assert(bz and bz.sh and bz.sh[1].at == "dest" and bz.sh[1].r == 8, "Blizzard: 8 yards at a ground point")
end }

return T

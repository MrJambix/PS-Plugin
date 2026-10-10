-- Jambix AIO: what a frame of the overlay costs, in calls into the game.
--
-- The whole plugin on the whole JCore (mock/aio_boot), as the Era client, in
-- a scripted world: a crowd of hostile mobs in front of the camera, more
-- behind it, corpses, friendly NPCs and players. Every function of `core` and
-- every method of every game object is counted, because a round trip into
-- the client is what makes a frame slow here (README, "Periodic freezes").
--
-- JTEST_PERF=1 prints the breakdown by call.

local boot = require("mock/aio_boot")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- --- the counter ----------------------------------------------------------------

local native = { n = 0, by = {} }
local function tally(name)
    native.n = native.n + 1
    native.by[name] = (native.by[name] or 0) + 1
end
local function reset() native.n, native.by = 0, {} end

--- Wraps every function of `core` and of its namespaces, before JCore keeps
--- a reference to any of them.
local function wrap_core(core)
    local function wrap(label, t)
        local names = {}
        for k, v in pairs(t) do
            if type(v) == "function" then names[#names + 1] = k end
        end
        for i = 1, #names do
            local k = names[i]
            local fn = rawget(t, k)
            rawset(t, k, function(...)
                tally(label .. k)
                return fn(...)
            end)
        end
    end
    wrap("core.", core)
    for k, v in pairs(core) do
        if type(v) == "table" then wrap(k .. ".", v) end
    end
end

-- --- the world ------------------------------------------------------------------

local PX, PY, PZ = 100, 100, 0

--- A game object answering from `spec`; any method not in it answers nil.
--- Every call is counted. A spec value that is a function is called with the
--- object and the arguments (can_attack, is_friend_with).
local function object(spec)
    local o = { spec = spec }
    local methods = {}
    return setmetatable(o, {
        __index = function(_, key)
            local m = methods[key]
            if m then return m end
            m = function(self, ...)
                tally("unit:" .. key)
                local v = spec[key]
                if type(v) == "function" then return v(self, ...) end
                return v
            end
            methods[key] = m
            return m
        end,
    })
end

local function at(x, y, z) return { x = x, y = y, z = z or PZ } end

local guid_n = 0
local function mob(fields)
    guid_n = guid_n + 1
    local spec = {
        is_valid = true, is_unit = true, is_player = false, is_dead = false,
        get_guid = "Creature-0-0-0-0-" .. (3000 + guid_n) .. "-" .. guid_n,
        get_name = "Mob " .. guid_n, get_level = 30, get_npc_id = 3000 + guid_n,
        get_creature_type = 7, get_classification = 0,
        get_health = 800, get_max_health = 1000, get_power = 0, get_max_power = 0,
        is_in_combat = false, get_rotation = 0, get_bounding_radius = 0.6,
        get_height = 2, get_combat_reach = 1.5,
        can_be_looted = false, has_loot = false, can_be_skinned = false, has_skin = false,
        is_tapped_by_other = false, hostile = true,
        get_loss_of_control_info = { valid = false },
    }
    for k, v in pairs(fields or {}) do spec[k] = v end
    spec.can_attack = function() return spec.hostile end
    return object(spec)
end

local function world()
    local list = {}
    -- In front of the camera: the crowd the overlay is for.
    for i = 1, 30 do
        list[#list + 1] = mob({
            get_position = at(PX + 12 + (i % 10) * 4, PY - 20 + (i * 7) % 40),
            is_in_combat = i <= 6,
        })
    end
    -- Behind the camera: in the sweep, never on screen.
    for i = 1, 10 do
        list[#list + 1] = mob({ get_position = at(PX - 10 - i * 3, PY - 15 + i * 3) })
    end
    -- Corpses in front, looted out.
    for i = 1, 6 do
        list[#list + 1] = mob({ get_position = at(PX + 10 + i * 2, PY + 6 + i), is_dead = true,
            get_health = 0 })
    end
    -- Friendly NPCs and players.
    for i = 1, 6 do
        list[#list + 1] = mob({ get_position = at(PX + 20 + i * 3, PY + 25 - i), hostile = false,
            friendly = true, get_name = "Guard " .. i })
    end
    for i = 1, 4 do
        list[#list + 1] = mob({ get_position = at(PX + 18 + i * 5, PY - 25 + i), hostile = false,
            friendly = true, is_player = true, get_class = 1 + i, get_race_id = i,
            get_name = "Friend" .. i, get_npc_id = 0 })
    end
    return list
end

local function player()
    local spec = {
        is_valid = true, is_unit = true, is_player = true, is_dead = false, is_ghost = false,
        get_guid = "Player-1-0001", get_name = "Me", get_class = 3, get_race_id = 1, get_level = 30,
        get_health = 900, get_max_health = 1000, get_power = 800, get_max_power = 1000,
        get_position = at(PX, PY), get_rotation = 0, is_moving = false, is_mounted = false,
        is_in_combat = false, get_auras = {}, get_buffs = {}, get_debuffs = {},
        get_loss_of_control_info = { valid = false },
    }
    spec.can_attack = function(_, other) return other and other.spec and other.spec.hostile or false end
    spec.is_friend_with = function(_, other) return other and other.spec and other.spec.friendly or false end
    spec.is_enemy_with = function(_, other) return other and other.spec and other.spec.hostile or false end
    return object(spec)
end

--- A camera at the player looking along +x: anything behind it does not
--- project, as the client's w2s answers nil.
local function w2s(pos)
    if type(pos) ~= "table" or not pos.x then return nil end
    local depth = pos.x - PX
    if depth < 2 then return nil end
    local sx = 960 + (pos.y - PY) * 600 / depth
    local sy = 540 - ((pos.z or 0) - PZ - 1) * 600 / depth
    if sx < 0 or sx > 1920 or sy < 0 or sy > 1080 then return nil end
    return { x = sx, y = sy }
end

-- --- boot -----------------------------------------------------------------------

local b
local me = player()
local crowd = world()
local visible = crowd     -- what the object manager answers; emptied by a test

local function set(page, id, value)
    b.mock.menu:set("Jambix AIO/" .. page, id, value)
    b.P.opt_invalidate()
end

--- Calls per frame over `frames` frames, and the breakdown.
local function measure(frames)
    reset()
    b.mock.frame(frames)
    local by = {}
    for name, n in pairs(native.by) do by[#by + 1] = { name = name, n = n / frames } end
    table.sort(by, function(x, y) return x.n > y.n end)
    return native.n / frames, by
end

local function report(label, per_frame, by)
    if not (jtest and jtest.env and jtest.env("JTEST_PERF")) then return end
    print(string.format("%s: %.0f calls into the game per frame", label, per_frame))
    for i = 1, math.min(25, #by) do
        print(string.format("    %7.1f  %s", by[i].n, by[i].name))
    end
end

local T = {}
local results = {}

T[#T + 1] = { "a crowd: the whole plugin boots and draws marks", function()
    b = boot.run("Vanilla", "wow_vanilla_us", { "_classic_era_" }, function(mock)
        wrap_core(mock.core)
        rawset(mock.core.object_manager, "get_local_player", function() tally("object_manager.get_local_player") return me end)
        rawset(mock.core.object_manager, "get_visible_objects", function()
            tally("object_manager.get_visible_objects")
            return visible
        end)
        rawset(mock.core.graphics, "w2s", function(pos) tally("graphics.w2s") return w2s(pos) end)
        rawset(mock.core.graphics, "is_line_of_sight", function() tally("graphics.is_line_of_sight") return true end)
    end)
    assert_eq(b.errors(), "", "core.log_error during boot")
    -- The overlay's toggle key, held on as a player would have it.
    set("ESP", "toggle_key", { vk = 0x5A, active = true, toggled = true })
    assert_eq(b.P.toggle_active(), true, "the overlay is toggled on")
    b.mock.frame(120)
    assert_eq(b.errors(), "", "core.log_error while running")
    assert(b.P.esp.count() >= 30, "the overlay collected the crowd: " .. tostring(b.P.esp.count()))
    assert((native.by["graphics.w2s"] or 0) > 0, "and projected it")
end }

T[#T + 1] = { "a crowd: calls into the game per frame, ESP on and off", function()
    local on, by_on = measure(60)
    report("ESP on", on, by_on)
    set("ESP", "enabled", false)
    b.mock.frame(10)
    local off, by_off = measure(60)
    report("ESP off", off, by_off)
    set("ESP", "enabled", true)
    b.mock.frame(10)
    results.on, results.off = on, off
    local l = b.P.esp_elements and b.P.esp_elements.layout and b.P.esp_elements.layout() or nil
    if l and jtest and jtest.env and jtest.env("JTEST_PERF") then
        print(string.format("marks: %d whole, %d cut to the name, %d with nothing above the head, %d off screen", l.full, l.name, l.hidden, l.offscreen))
    end
    if jtest and jtest.env and jtest.env("JTEST_PERF") then
        print(string.format("the ESP's share: %.0f calls per frame", on - off))
    end
    assert_eq(b.errors(), "", "core.log_error while measuring")
    assert(on > off, "the ESP costs something")
    -- Measured on 2026-10-02: 2124 with the ESP on and 884 off before the
    -- 1.40 / JCore 1.5.3 work, 1172 and 705 after. The ceilings leave room
    -- for a feature, not for a per-mark native creeping back in.
    assert(on < 1400, string.format("ESP on: %.0f calls a frame", on))
    assert(on - off < 600, string.format("the ESP's share: %.0f calls a frame", on - off))
    -- And the calls that used to be asked per mark, or per unit more than
    -- once: before, after.
    local per = {}
    for i = 1, #by_on do per[by_on[i].name] = by_on[i].n end
    local ceilings = {
        ["core.time"] = 40,          -- 276 before: every icon, every mark, every unit
        ["unit:is_dead"] = 90,       -- 143: the sweep asked twice, units.is_dead a third time
        ["unit:get_target"] = 25,    -- 56: "is this my target" per mark
        ["unit:is_valid"] = 140,     -- 204: every draw helper per mark
        ["unit:get_guid"] = 100,     -- 168: the same
    }
    for name, ceiling in pairs(ceilings) do
        assert((per[name] or 0) < ceiling,
            string.format("%s: %.1f a frame, ceiling %d", name, per[name] or 0, ceiling))
    end
end }


-- --- JCore under the same crowd --------------------------------------------------

local function lines_with(list, from, text)
    local n = 0
    for i = from + 1, #list do
        if tostring(list[i]):find(text, 1, true) then n = n + 1 end
    end
    return n
end

T[#T + 1] = { "JCore: a unit in the sweep is projected without asking the client about it again", function()
    local draw = b.JCore.draw
    local unit = crowd[1]
    draw._begin_frame()            -- a new frame: nothing projected yet
    reset()
    local screen = draw.unit_w2s(unit)
    assert(screen, "on screen")
    assert_eq(native.by["graphics.w2s"], 1, "one projection")
    assert_eq(native.by["unit:is_valid"], nil, "no is_valid")
    assert_eq(native.by["unit:get_guid"], nil, "no get_guid")
    assert_eq(native.by["unit:get_position"], nil, "no get_position")
    reset()
    draw.unit_w2s(unit)
    draw.unit_head(unit)
    draw.unit_head(unit)
    assert_eq(native.by["graphics.w2s"], nil, "the second ask is the cache's")
    assert_eq(native.by["unit:get_attachment_name_position"], 1, "the head once a frame")
end }

T[#T + 1] = { "JCore: the projection cache is emptied with the others", function()
    local draw = b.JCore.draw
    assert(draw.stats().cached_w2s > 0, "the crowd is in it")
    visible = {}
    local frames = 0
    while draw.stats().cached_w2s > 0 and frames < 601 do
        b.mock.frame(1)
        frames = frames + 1
    end
    local left = draw.stats().cached_w2s
    visible = crowd
    b.mock.frame(5)
    assert_eq(left, 0, "emptied within 600 frames")
end }

T[#T + 1] = { "JCore: a core stage that throws is logged once and skipped; the rest of the tick runs; nothing pauses", function()
    local combat, enemies = b.JCore.combat, b.JCore.enemies
    local poll, enemies_poll = combat._poll, enemies._poll
    local from = #b.mock.errors
    local polled = 0
    combat._poll = function() error("boom") end
    enemies._poll = function(...) polled = polled + 1 return enemies_poll(...) end
    b.mock.frame(30)
    combat._poll, enemies._poll = poll, enemies_poll
    assert_eq(lines_with(b.mock.errors, from, "core stage combat failed"), 1, "logged once")
    assert_eq(lines_with(b.mock.errors, from, "keeps failing"), 0, "no job paused")
    assert_eq(polled, 30, "the stage after it ran every tick")
    for i = #b.mock.errors, from + 1, -1 do table.remove(b.mock.errors, i) end
end }

T[#T + 1] = { "JCore: cast requests never outlive their tick -- not a bad priority, not a decision that threw", function()
    local cast = b.JCore.cast
    local from = #b.mock.errors
    assert_eq(cast.request({ spell_id = 133, priority = "high", owner = "test" }), true, "accepted")
    b.mock.frame(1)
    assert_eq(cast.stats().pending_gcd, 0, "decided")
    assert_eq(lines_with(b.mock.errors, from, "compare"), 0, "a string priority did not throw")

    -- The decision itself throws (the player's death read): the lane is
    -- still empty after it.
    local is_dead = me.spec.is_dead
    me.spec.is_dead = function() error("not in world") end
    cast.request({ spell_id = 133, owner = "test" })
    b.mock.frame(1)
    me.spec.is_dead = is_dead
    assert_eq(cast.stats().pending_gcd, 0, "a throwing tick keeps nothing")
    for i = #b.mock.errors, from + 1, -1 do table.remove(b.mock.errors, i) end
end }

T[#T + 1] = { "JCore: art from the archives fails for good, said once and not as a warning, when they cannot be read", function()
    local assets = b.JCore.assets
    local refs = {}
    for i = 1, 3 do
        refs[i] = "game:Interface/Icons/Test_" .. i .. ".blp"
        assets.request(refs[i])
    end
    b.mock.frame(30)
    for i = 1, 3 do
        local e = assets.get(refs[i])
        assert(e and e.dead, refs[i] .. " is dead, not waiting to retry")
        assert_eq(assets.request(refs[i]), false, "and asking again does not requeue it")
        assert_eq(e.state, "failed", "still failed")
    end
    -- 1.8.3: on a loader that cannot read them (this user's, every session)
    -- that is how things are, not a warning: the casc reader says why once,
    -- at info, and the pictures' own line goes to the debug log.
    assert_eq(lines_with(b.mock.warnings, 0, "archives"), 0, "no warning about it")
    assert_eq(lines_with(b.mock.logs, 0, "game archives not readable"), 1, "the reason said once, at info")
    assert_eq(lines_with(b.mock.warnings, 0, "asset game:"), 0, "and none per picture")
end }

T[#T + 1] = { "JCore: time to die from a falling health bar", function()
    local combat = b.JCore.combat
    local mob = crowd[2]
    local t0 = b.mock.time
    mob.spec.get_health = function() return math.max(0, 1000 - (b.mock.time - t0) * 100) end
    me.spec.is_in_combat = true
    b.mock.frame(150)
    local ttd = combat.time_to_die(mob)
    me.spec.is_in_combat = false
    mob.spec.get_health = 800
    -- 10% a second, from 100%: after 2.5s, 75% left, 7.5s to go.
    assert(ttd > 6 and ttd < 9, "about 7.5s: " .. tostring(ttd))
end }

return T

-- Jambix AIO: the reaction engine (modules/react), driven through a hand-built
-- bundle with a scripted clock.
--
-- What these hold it to: several things valid at once and the most important
-- one wins; an event is answered once and the answer is waited on; nothing
-- flips state around a threshold; a refused action is backed off, briefly;
-- an enemy spell is never cast on ourselves; and the rotation still runs
-- whenever nothing more important is happening.

-- run.js already searches scripts/, after any JTEST_OVERLAY copy; a prefix
-- here would hide the staged copy, so it is only for running outside it.
if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has_line(lines, needle)
    for i = 1, #lines do
        if lines[i]:find(needle, 1, true) then return true end
    end
    return false
end

local function fresh(module)
    for k in pairs(package.loaded) do
        if k:find("^jambix_aio/modules/react") or k == module then package.loaded[k] = nil end
    end
    return require(module)
end

local function recording_log(G)
    G.lines = {}
    local function put(level, text) G.lines[#G.lines + 1] = { level = level, text = text } end
    return {
        fmt = function(level, f, ...) put(level, string.format(f, ...)) end,
        once = function(level, _, text) put(level, text) end,
        info = function(text) put("info", text) end,
        debug = function(text) put("debug", text) end,
        warn = function(text) put("warn", text) end,
        error = function(text) put("error", text) end,
    }
end

-- --- the bundle -------------------------------------------------------------------

local function unit(G, guid, fields)
    local u = {
        guid = guid, name = fields and fields.name or guid,
        hostile = fields and fields.hostile ~= false or false,
        dead = false, level = fields and fields.level or 30,
        classification = fields and fields.classification or 0,
    }
    if fields and fields.hostile == nil then u.hostile = true end
    function u.is_valid() return true end
    function u.is_dead() return u.dead end
    function u.get_guid() return u.guid end
    function u.get_level() return u.level end
    function u.get_classification() return u.classification end
    function u.is_player() return false end
    function u.is_boss() return u.classification == 3 end
    function u.get_name() return u.name end
    u.npc = fields and fields.npc or 0
    function u.get_npc_id() return u.npc end
    -- Forever's is_tap_denied: false for everything until client patch 1.60.1.70205.
    function u.is_tap_denied() return u.tap == true end
    G.by_guid[guid] = u
    return u
end

local function bundle(opts)
    opts = opts or {}
    local G = {
        clock = 1000.0,
        settings = { react_enabled = true },
        casts = {}, pet_casts = {}, used = {}, handlers = {},
        known = {}, unready = {}, blocked = {}, ids = {}, names = {}, next_id = 1000,
        hp = 1.0, hp_rate = 0, in_combat = true, moving = false, power = 80, power_max = 100,
        plan = "BURN", shape = "SINGLE", count = 1, elites = 0, escalating = false,
        ttl = math.huge, reason = "",
        pet_alive = false, pet_rate = 0, pet_target = nil, pet_known = {},
        rows = {}, row = nil, health = {}, by_guid = {}, auras = {},
        items = {}, bail = false, loc = nil, cast_remaining = 0, casting_id = nil,
        context = "solo", group = { in_group = false }, threat_pct = nil, armed = {},
        catalog = {}, roles = {}, distance = 20, hold_fire = false,
    }

    _G.core = {
        time = function() return G.clock end,
        game_time = function() return G.clock * 1000 end,
        spell_book = { is_item_usable = function() return true end },
    }

    G.player = unit(G, "player", { name = "Me", hostile = false })
    function G.player.can_attack(_, other) return other ~= nil and other.hostile == true end
    G.target = unit(G, "mob", { name = "Defias Pillager" })

    local function id_of(name)
        local id = G.ids[name]
        if not id then
            G.next_id = G.next_id + 1
            id = G.next_id
            G.ids[name], G.names[id] = id, name
        end
        return id
    end
    G.id_of = id_of

    local P = {
        log = recording_log(G),
        load = function(path) return require("jambix_aio/" .. path) end,
        opt = function(id, default)
            local v = G.settings[id]
            if v == nil then return default end
            return v
        end,
        optpct = function(id, default)
            local v = G.settings[id]
            if v == nil then v = default end
            return v / 100
        end,
        tune = function(id, default)
            if G.tune and G.tune[id] then return G.tune[id] end
            return default / 100
        end,
        tune_secs = function(_, default) return default end,
        derived = function(id, default)
            if G.tune and G.tune[id] then return G.tune[id] end
            return default / 100
        end,
        key_armed = function(id) return G.armed[id] == true end,
        loc_types = { FEAR = 5, STUN = 6, ROOT = 8 },
        enums = { buff_type = { MAGIC = 1, CURSE = 2, DISEASE = 3, POISON = 4 } },
        ctx = {
            id = "jambix.aio",
            on = function(event, fn)
                G.handlers[event] = G.handlers[event] or {}
                table.insert(G.handlers[event], fn)
            end,
            emit = function(name, data)
                G.emits = G.emits or {}
                G.emits[#G.emits + 1] = { name = name, data = data }
            end,
            render = function() end,
            cast = function(request)
                request.owner = "jambix.aio"
                G.casts[#G.casts + 1] = request
                if G.dispatch then G.fire("jcore.cast.sent", request) end
            end,
            PRIORITY = { IDLE = 10, FILLER = 30, ROTATION = 50, COOLDOWN = 70, UTILITY = 100,
                         INTERRUPT = 150, DEFENSIVE = 200, EMERGENCY = 255 },
            LAYER = { HUD = 500 },
            spells = { name = function(id) return G.names[id] or "" end },
            player = {
                casting_spell_id = function() return G.casting_id end,
                is_channelling = function() return G.channelling ~= nil end,
                loss_of_control = function() return G.loc end,
                level = function() return 30 end,
            },
            group = {
                in_group = function() return G.group.in_group end,
                in_raid = function() return false end,
                size = function() return G.group.in_group and 3 or 0 end,
                objects = function() return G.group.objects or {} end,
                tanks = function() return G.group.tanks or {} end,
                healers = function() return G.group.healers or {} end,
                is_tank = function() return G.group.me_tank == true end,
            },
            threat = {
                closest_to_pulling = function()
                    if G.threat_pct then return { obj = G.target }, G.threat_pct end
                    return nil, 0
                end,
                holding = function() return 0 end,
                mine = function() return G.threat_pct, 2, 3, false end,
            },
        },
        units = {
            player = function() return G.player end,
            guid = function(u) return u and u.guid or nil end,
            name = function(u) return u and u.name or "" end,
            by_guid = function(g) return G.by_guid[g] end,
            health_fraction = function(u) return G.health[u.guid] or 1 end,
            aura_index = function(u) return G.auras[u.guid] or {} end,
            is_dead = function(u) return u.dead end,
        },
        combat = { cast_remaining = function() return G.cast_remaining end },
        spellbook = {
            id = function(name) return G.known[name] and id_of(name) or nil end,
            ids = function(name) return G.known[name] and { id_of(name) } or nil end,
            known = function(name) return G.known[name] == true end,
            ready = function(name) return G.known[name] == true and not G.unready[name] end,
            castable = function(name) return G.known[name] == true and not G.unready[name] end,
        },
        resources = {
            hp_rate = function() return G.hp_rate end,
            fight_left = function() return G.fight_left or 20 end,
            power_empty = function() return G.power_empty or math.huge end,
        },
        hardcore = {
            should_stop_fighting = function() return G.bail end,
            item = function(kind)
                if G.items[kind] then return 5000, G.items[kind] end
                return nil
            end,
            use_item = function(kind) G.used[#G.used + 1] = kind return true end,
        },
        targeting = { context = function() return G.context end },
        sense = { pvp_active = function() return false end },
        catalog = {
            ability = function(name) return G.catalog[name] end,
            with_role = function(role) return G.roles[role] or {} end,
        },
    }
    P.field = { state = setmetatable({}, { __index = function(_, k)
        local map = { plan = G.plan, shape = G.shape, reason = G.reason, count = G.count,
                      inbound = 0, elites = G.elites, escalating = G.escalating,
                      time_to_live = G.ttl, time_to_clear = G.ttc or 10,
                      my_hp = G.my_hp, their_dps = G.their_dps, my_dps = G.my_dps }
        return map[k]
    end }) }
    P.pet = {
        OFF = 1, ASSIST = 2, TANK = 3, FOCUS = 4,
        pet = function() return G.pet_alive and G.pet or nil end,
        hp_rate = function() return G.pet_rate end,
        pet_target = function() return G.pet_target end,
        mode = function() return 2 end,
        knows = function(n) return G.pet_known[n] == true end,
        cast = function(n, t) G.pet_casts[#G.pet_casts + 1] = { name = n, target = t } return true end,
        assign = function(u, reason, seconds)
            G.assigned = { unit = u, reason = reason, seconds = seconds }
            return true
        end,
        spell_id = function() return 900 end,
        growl_wanted = function() return true end,
    }
    P.rotation = {
        helpers = {
            key_allows = function(name) return not (G.gated and G.gated[name]) end,
            escape_target = function(name, s)
                if G.enemy_spells and G.enemy_spells[name] then return s.target end
                return s.player
            end,
            channel_active = function(name) return G.channelling == name end,
        },
        press_blocked = function(name) return G.blocked[name] end,
        active_class = function() return G.class end,
    }
    G.P = P

    G.class = opts.class or {
        key = "testclass", class_name = "ROGUE", power = "ENERGY",
        interrupts = { "Kick" }, defensives = { "Evasion" }, escapes = { "Vanish" },
    }
    G.profile = { label = "Test", rules = {} }
    G.pet = unit(G, "pet", { name = "Wolf", hostile = false })

    -- The Forever client (1.45.0): its paths are built only when this is set.
    if opts.forever then P.forever = true end
    -- JCore's client flags, as Forever or Era answer them (1.6.0).
    P.ctx.world = { client = function()
        local f = opts.forever == true
        return { forever = f, combat_log = not f, recording = f, auto_repeat_once = f, auto_start_melee = f }
    end }
    -- JCore 1.5.15's creature cache, and 1.6.0's loot, as a plugin sees them.
    if opts.creatures then P.ctx.creatures = opts.creatures end
    if opts.loot then P.ctx.loot = opts.loot end
    -- JCore's JSON, for sharing reactions (1.79.0).
    if opts.json then P.ctx.json = opts.json end
    G.React = fresh("jambix_aio/modules/react/init")(P)

    function G.fire(event, data)
        for _, fn in ipairs(G.handlers[event] or {}) do fn(data) end
    end

    function G.snapshot()
        local on_me = 0
        for i = 1, #G.rows do if G.rows[i].targeting_me then on_me = on_me + 1 end end
        return {
            player = G.player, target = G.target_present ~= false and G.target or nil,
            hp = G.hp, thp = G.health.mob or 1, in_combat = G.in_combat, ttd = G.ttd or 20,
            power = G.power, power_max = G.power_max, posture = "HEALTHY", moving = G.moving,
            hold_fire = G.hold_fire, enemies = G.rows, enemy_count = #G.rows,
            target_row = G.row, on_me = on_me, closing = 0, distance = G.distance,
            can = {}, ally = G.ally,
        }
    end

    function G.tick()
        G.verdict = G.React.tick(G.class, G.profile, G.snapshot())
        return G.verdict
    end

    --- Advances the clock in tenth-of-a-second ticks.
    function G.run(seconds)
        local steps = math.floor(seconds * 10 + 0.5)
        for _ = 1, steps do
            G.clock = G.clock + 0.1
            G.tick()
        end
    end

    function G.sent(name)
        local n, last = 0, nil
        for i = 1, #G.casts do
            local id = G.casts[i].spell_id
            if G.names[id] == name then n, last = n + 1, G.casts[i] end
        end
        return n, last
    end

    --- A hostile row for the enemies tracker, optionally casting.
    function G.row_for(u, fields)
        local r = {
            obj = u, guid = u.guid, dist = 20, engaged = true, targeting_me = false,
            targeting_pet = false, control = nil, activity = "attacking", closing = 0,
        }
        for k, v in pairs(fields or {}) do r[k] = v end
        return r
    end

    function G.casting(spell, remaining, total, interruptible)
        local id = id_of(spell)
        return {
            spell_id = id, channel = false,
            start_at = (G.clock - ((total or 3) - remaining)) * 1000,
            end_at = (G.clock + remaining) * 1000,
            interruptible = interruptible ~= false,
        }
    end

    return G
end

local T = {}

-- --- hysteresis ------------------------------------------------------------------------

T[#T + 1] = { "combat log: a stale player object after a loading screen is replaced, never compared (Invalid game object!)", function()
    local G = bundle()
    -- The client's game objects compare through a native __eq that raises
    -- once either side is stale.
    local native = { __eq = function(a, b)
        if a.stale or b.stale then error("Invalid game object!") end
        return rawequal(a, b)
    end }
    setmetatable(G.player, native)
    local function hit(source, amount)
        G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
            0, "SPELL_DAMAGE", false, source, "Me", 0, 0, "mob", "Defias Pillager", 0, 0,
            75, "Auto Shot", 1, amount,
        })
    end
    local dealt = G.React.damage.dealt

    hit("player", 10)
    assert_eq(dealt("mob"), 10, "a hit of ours is counted")

    -- A loading screen: the old object is stale, the sweep hands out a new one.
    G.player.stale = true
    G.player = setmetatable(unit(G, "player", { name = "Me", hostile = false }), native)
    local ok, err = pcall(hit, "player", 5)
    assert(ok, "the handler must not compare the stale object: " .. tostring(err))
    assert_eq(dealt("mob"), 15, "and keeps counting")

    -- A different character after a relog: its guid is read afresh.
    G.player.stale = true
    G.player = setmetatable(unit(G, "player-2", { name = "Alt", hostile = false }), native)
    hit("player", 100)
    assert_eq(dealt("mob"), 15, "the old character's guid is not ours any more")
    hit("player-2", 7)
    assert_eq(dealt("mob"), 22, "the new one's hits are")
end }

T[#T + 1] = { "latch: enters at one line, leaves only at the other, and does not chatter", function()
    local L = fresh("jambix_aio/modules/react/latch")()
    local l = L.new({ enter = 0.30, exit = 0.45, below = true })
    local now = 0
    local function feed(v) now = now + 0.1 return (l.update(v, now)) end
    assert_eq(feed(0.31), false, "above the entry line")
    assert_eq(feed(0.30), true, "at the entry line: on")
    assert_eq(feed(0.31), true, "one percent back up: still on")
    assert_eq(feed(0.44), true, "just under the exit line: still on")
    assert_eq(feed(0.45), false, "at the exit line: off")
    assert_eq(feed(0.44), false, "back under the exit line: stays off")

    local t = L.new({ enter = 70, exit = 60, below = false })
    assert_eq((t.update(69, 1)), false, "threat 69: safe")
    assert_eq((t.update(70, 2)), true, "threat 70: warning")
    assert_eq((t.update(61, 3)), true, "threat 61: still warning")
    assert_eq((t.update(60, 4)), false, "threat 60: safe again")
end }

-- --- behaviour states --------------------------------------------------------------------

T[#T + 1] = { "mode: up at once, down only after a dwell, and down from an emergency through recovery", function()
    local G = bundle()
    G.tick()
    assert_eq(G.React.stats().mode, "NORMAL", "healthy")

    G.hp, G.hp_rate = 0.33, -0.03
    G.run(0.1)
    assert_eq(G.React.stats().mode, "DEFENSIVE", "under the 35% line: defensive at once")

    G.hp = 0.36
    G.run(3.0)
    assert_eq(G.React.stats().mode, "DEFENSIVE", "one percent over the line is not recovered (exit at 50%)")

    G.hp, G.hp_rate = 0.20, -0.06
    G.run(0.1)
    assert_eq(G.React.stats().mode, "EMERGENCY", "critical: emergency at once")

    G.hp, G.hp_rate = 0.70, 0
    G.run(1.0)
    assert_eq(G.React.stats().mode, "EMERGENCY", "a potion landing does not end it inside the dwell")
    G.run(1.0)
    assert_eq(G.React.stats().mode, "RECOVERY", "down from an emergency goes through recovery")
    G.run(3.5)
    assert_eq(G.React.stats().mode, "NORMAL", "and from recovery to normal once it has held")
    assert(has_line(G.React.log_lines(20), "mode EMERGENCY -> RECOVERY"), "the journal has the step down")
end }

T[#T + 1] = { "mode: the field's FLEE is ESCAPE, and running out of options escalates an emergency", function()
    local G = bundle()
    G.plan, G.reason, G.hp, G.hp_rate = "FLEE", "3s to live -- cannot win this", 0.30, -0.08
    G.ttl = 3
    G.tick()
    assert_eq(G.React.stats().mode, "ESCAPE", "flee")

    local H = bundle()
    H.hp, H.hp_rate = 0.18, -0.05
    H.rows = { H.row_for(H.target, { targeting_me = true }) }
    H.unready.Evasion = true          -- nothing defensive left, no potion in the bags
    H.tick()
    assert_eq(H.React.stats().mode, "EMERGENCY", "critical")
    H.run(2.2)
    assert_eq(H.React.stats().mode, "ESCAPE", "options exhausted while still being hit")
end }

-- --- scoring and selection ------------------------------------------------------------------

T[#T + 1] = { "several valid reactions: the dangerous interrupt beats the pet heal, and the readout says why", function()
    local G = bundle()
    G.known.Kick = true
    G.known["Mend Pet"] = true
    G.pet_alive, G.health.pet, G.pet_target = true, 0.18, G.target
    G.row = G.row_for(G.target, { casting = G.casting("Greater Heal", 0.8, 3.0) })
    G.rows = { G.row }

    G.React.debug_lines()   -- the page is open: the next decision is recorded for it
    G.tick()
    local lines = G.React.debug_lines()

    assert_eq(G.sent("Kick"), 1, "the interrupt went out")
    assert_eq(G.sent("Mend Pet"), 0, "one action per lane: the pet heal waits")
    assert_eq(G.verdict.gcd, true, "the global cooldown is the reaction's: the rotation does not run")
    assert(has_line(lines, "Selected: Kick"), "Selected: Kick")
    assert(has_line(lines, "+90 base: Interrupt"), "the base priority line")
    assert(has_line(lines, "+40 dangerous cast (Greater Heal)"), "the danger line")
    assert(has_line(lines, "+25 cast ends in 0.8s"), "the urgency line")
    assert(has_line(lines, "Other candidates: Mend Pet"), "the runner-up is listed with its score")
end }

T[#T + 1] = { "interrupt: one cast is one event -- kicked once, and a new cast is a new event", function()
    local G = bundle()
    G.known.Kick = true
    G.row = G.row_for(G.target, { casting = G.casting("Fear", 1.4, 1.5) })
    G.rows = { G.row }

    G.tick()
    assert_eq(G.sent("Kick"), 1, "kicked")
    G.run(0.5)
    assert_eq(G.sent("Kick"), 1, "the same cast is handled: not kicked again while it still shows")

    G.row.casting = G.casting("Fear", 1.4, 1.5)    -- a new cast: new start time
    G.run(0.1)
    assert_eq(G.sent("Kick"), 2, "a new cast is a new event")
end }

T[#T + 1] = { "the pet's kick: its own lane, never the player's global cooldown, and one kick per cast", function()
    local G = bundle({ class = {
        key = "warlocklike", class_name = "WARLOCK", power = "MANA",
        interrupts = {}, pet_interrupts = { "Spell Lock" }, defensives = {}, escapes = {},
    } })
    G.pet_alive, G.pet_known["Spell Lock"] = true, true
    G.row = G.row_for(G.target, { casting = G.casting("Shadow Bolt", 0.9, 3.0) })
    G.rows = { G.row }
    G.tick()
    assert_eq(#G.pet_casts, 1, "the pet kicked")
    assert_eq(G.pet_casts[1].name, "Spell Lock", "with Spell Lock")
    assert_eq(G.verdict.gcd, false, "the player's global cooldown is untouched: the rotation runs")
    assert_eq(G.verdict.pet, true, "the pet lane was used")

    local H = bundle({ class = {
        key = "both", class_name = "WARLOCK", power = "MANA",
        interrupts = { "Kick" }, pet_interrupts = { "Spell Lock" }, defensives = {}, escapes = {},
    } })
    H.known.Kick = true
    H.pet_alive, H.pet_known["Spell Lock"] = true, true
    H.row = H.row_for(H.target, { casting = H.casting("Greater Heal", 0.9, 3.0) })
    H.rows = { H.row }
    H.tick()
    assert_eq(H.sent("Kick"), 1, "the player kicked")
    assert_eq(#H.pet_casts, 0, "and the pet did not kick the same cast")
end }

T[#T + 1] = { "interrupt: a harmless cast is kicked late, a dangerous one at once", function()
    local G = bundle()
    G.known.Kick = true
    G.row = G.row_for(G.target, { casting = G.casting("Arcane Missiles", 2.6, 3.0) })
    G.rows = { G.row }
    G.tick()
    assert_eq(G.sent("Kick"), 0, "2.6s left on a harmless cast: waits")
    G.clock = G.clock + 0.8
    G.tick()
    assert_eq(G.sent("Kick"), 1, "1.8s left: kicked")

    local H = bundle()
    H.known.Kick = true
    H.row = H.row_for(H.target, { casting = H.casting("Polymorph", 2.9, 3.0) })
    H.rows = { H.row }
    H.tick()
    assert_eq(H.sent("Kick"), 1, "a polymorph is kicked the moment it is seen")
end }

T[#T + 1] = { "interrupt in the world (1.85.0): the waiting kick is a mark under the caster, and the kick a ring under it", function()
    local G = bundle()
    G.known.Kick = true
    G.target.pos = { x = 4, y = 0, z = 0 }
    G.row = G.row_for(G.target, { casting = G.casting("Arcane Missiles", 2.6, 3.0) })
    G.rows = { G.row }
    G.tick()
    local marks = G.React.marks
    assert(marks, "the reactions carry their marks")
    assert_eq(marks.stats().kicks, 1, "the kick it waits on is marked")
    local rings = {}
    G.P.draw = { ring_3d = function(...) rings[#rings + 1] = { ... } end, curtain_3d = function() end }
    G.P.units.position = function(u) return u and u.pos end
    marks.render()
    assert_eq(#rings, 1, "one ring under the caster")
    assert_eq(rings[1][1], G.target.pos, "at its feet")
    assert(rings[1][3] > 0 and rings[1][3] < 1, "filling toward the kick, got " .. tostring(rings[1][3]))
    G.clock = G.clock + 0.8
    G.tick()
    assert_eq(G.sent("Kick"), 1, "kicked")
    rings = {}
    marks.render()
    local full, pulse = 0, 0
    for i = 1, #rings do
        if rings[i][1] == G.target.pos and rings[i][3] == 1 then
            if rings[i][5].inner == 0.86 then pulse = pulse + 1 else full = full + 1 end
        end
    end
    assert_eq(full, 1, "the chosen kick: a full ring")
    assert_eq(pulse, 1, "and the ring opening out where it landed")
end }

T[#T + 1] = { "interrupt: a spell that does not take the caster is passed over for the next (1.77.4)", function()
    local function paladin_bundle(kind)
        local G = bundle({ class = {
            key = "paladinlike", class_name = "PALADIN", power = "MANA",
            interrupts = { "Hammer of Justice", "Repentance" }, defensives = {}, escapes = {},
            creature_types = { Repentance = { 7 } },
        } })
        G.known["Hammer of Justice"], G.known.Repentance = true, true
        G.unready["Hammer of Justice"] = true
        G.target.get_creature_type = function() return kind end
        G.row = G.row_for(G.target, { casting = G.casting("Polymorph", 1.0, 1.5) })
        G.rows = { G.row }
        return G
    end

    local G = paladin_bundle(7)
    G.tick()
    assert_eq(G.sent("Repentance"), 1, "a humanoid, the Hammer on cooldown: Repentance")

    local B = paladin_bundle(1)
    B.tick()
    assert_eq(B.sent("Repentance"), 0, "a beast: never Repentance")
    B.unready["Hammer of Justice"] = nil
    B.row.casting = B.casting("Polymorph", 1.0, 1.5)
    B.run(0.1)
    assert_eq(B.sent("Hammer of Justice"), 1, "the Hammer, once it is back")
end }

T[#T + 1] = { "the pet: healed once per dip, predictively, and the dip is waited on", function()
    local G = bundle()
    G.known["Mend Pet"] = true
    G.pet_alive, G.pet_target = true, G.target
    G.health.pet, G.pet_rate = 0.28, -0.06     -- 28%, falling 6%/s: 13% in 2.5s
    G.tick()
    assert_eq(G.sent("Mend Pet"), 1, "healed before it reached the 20% line")

    G.channelling = "Mend Pet"
    G.health.pet = 0.19
    G.run(2.0)
    assert_eq(G.sent("Mend Pet"), 1, "not again while the channel runs (was Mend Pet x3)")

    G.channelling = nil
    G.run(3.0)
    assert_eq(G.sent("Mend Pet"), 1, "the dip is handled until the result has had time to show")
    G.run(2.0)
    assert_eq(G.sent("Mend Pet"), 2, "still low after that: a second heal")

    assert_eq(G.React.owns("Mend Pet"), true, "the engine owns Mend Pet")
    G.settings.react_enabled, G.settings.pet_heal = false, false
    assert_eq(G.React.owns("Mend Pet"), true, "and the removed switches cannot take it back")
end }

-- --- memory -------------------------------------------------------------------------------

T[#T + 1] = { "memory: two refusals back a spell off, briefly; a success clears it", function()
    local G = bundle()
    local mem = G.React.memory
    local id = G.id_of("Evasion")
    mem.attempt({ name = "Evasion", id = id, rule = "test" })
    mem.on_sent(id, "player")
    mem.on_failure(id, "SPELL_FAILED_NOT_READY")
    local n, left = mem.failures("Evasion")
    assert_eq(n, 1, "one failure")
    assert_eq(left, 0, "one is not a pattern")
    mem.attempt({ name = "Evasion", id = id, rule = "test" })
    mem.on_failure(id, "SPELL_FAILED_NOT_READY")
    n, left = mem.failures("Evasion")
    assert_eq(n, 2, "two failures")
    assert(left > 1 and left <= mem.BACKOFF_MAX, "backed off, and never for long")
    mem.on_success(id)
    n, left = mem.failures("Evasion")
    assert_eq(left, 0, "a success clears the back-off")

    -- A refusal of something we never sent is not ours to count.
    assert_eq(mem.on_failure(G.id_of("Sprint"), "pressed by hand"), nil, "the player's own press")
    assert_eq((mem.failures("Sprint")), 0, "not counted")
end }

T[#T + 1] = { "memory: a refusal that will repeat (out of range) is backed off, briefly, and says why", function()
    local G = bundle()
    G.dispatch = true
    G.known.Sprint = true
    G.React.add_rule({
        name = "Test: sprint", category = "utility", priority = 60, target = "self",
        retry = { hold = 0.5 },
        propose = function(W, offer) offer({ name = "Sprint" }) end,
    })
    local OUT_OF_RANGE = { 0, "Out of range.", "SPELL_FAILED_OUT_OF_RANGE" }
    G.tick()
    assert_eq(G.sent("Sprint"), 1, "pressed")
    G.fire("jcore.game_event.UI_ERROR_MESSAGE", OUT_OF_RANGE)
    G.clock = G.clock + 0.6
    G.tick()
    assert_eq(G.sent("Sprint"), 2, "one refusal: tried again after its hold")
    G.fire("jcore.game_event.UI_ERROR_MESSAGE", OUT_OF_RANGE)
    G.React.debug_lines()
    G.clock = G.clock + 0.6
    G.tick()
    assert_eq(G.sent("Sprint"), 2, "refused twice for the same lasting reason: backed off")
    assert(has_line(G.React.log_lines(20), "[retry]"), "logged as a retry held back")
    assert(has_line(G.React.debug_lines(), "failed 2 time(s) (SPELL_FAILED_OUT_OF_RANGE)"), "the readout says why")
    G.clock = G.clock + 1.6
    G.tick()
    assert_eq(G.sent("Sprint"), 3, "and only briefly")
end }

T[#T + 1] = { "memory: \"not ready yet\" and a bare FAILED never hold anything back (the standing-still bug)", function()
    local G = bundle()
    G.dispatch = true
    G.known.Sprint = true
    G.React.add_rule({
        name = "Test: sprint", category = "utility", priority = 60, target = "self",
        retry = { hold = 0.5 },
        propose = function(W, offer) offer({ name = "Sprint" }) end,
    })
    local id = G.id_of("Sprint")
    for i = 1, 4 do
        G.tick()
        G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Spell is not ready yet.", "SPELL_FAILED_NOT_READY" })
        G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Another action is in progress", "SPELL_FAILED_SPELL_IN_PROGRESS" })
        G.fire("jcore.game_event.UNIT_SPELLCAST_FAILED", { "player", "guid", id })
        G.clock = G.clock + 0.6
    end
    assert_eq(G.sent("Sprint"), 4, "pressed every time its own hold allowed: transient errors count for nothing")
    assert_eq(select(2, G.React.memory.failures("Sprint")), 0, "no back-off")
    assert_eq(G.React.gate("Sprint", nil), nil, "and the rotation's gate holds nothing either")
end }

T[#T + 1] = { "memory: the rotation's own press is never backed off, even after a lasting refusal (1.35.2)", function()
    -- The live log: two "You are too far away!" held Auto Shot for seconds
    -- after the mob had walked into range. A reaction is still backed off;
    -- the rotation's gate is not.
    local G = bundle()
    local mem = G.React.memory
    local id = G.id_of("Auto Shot")
    for _ = 1, 3 do
        mem.attempt({ name = "Auto Shot", id = id, rule = "rotation" })
        mem.on_sent(id, "mob")
        mem.on_failure(id, "ERR_BADATTACKPOS")
    end
    local n, left = mem.failures("Auto Shot")
    assert_eq(n, 3, "three refusals counted")
    assert(left > 0, "the memory would back a reaction off")
    assert_eq(G.React.gate("Auto Shot", G.target), nil, "the rotation's gate lets it through")
    assert(not has_line(G.React.log_lines(20), "[retry]"), "and logs no hold for it")
end }

T[#T + 1] = { "the manual Growl reaction is gone: the pet's autocast does it (1.35.2)", function()
    local G = bundle()
    assert_eq(G.React.engine.rule("Pet: take the mob back"), nil, "no such rule")
    assert(G.React.engine.rule("Heal the pet"), "the other pet reactions are still there")
end }

T[#T + 1] = { "memory: Hunter's Mark stays where it is while the target flaps", function()
    local G = bundle()
    local mem = G.React.memory
    G.React.unique("Hunter's Mark")
    local a, b = G.target, unit(G, "mob2", { name = "Second" })
    G.health.mob, G.health.mob2 = 0.8, 0.9
    local id = G.id_of("Hunter's Mark")
    mem.target_seen("mob")
    -- The rotation marks A, the client confirms it.
    mem.on_sent(id, "mob", "Hunter's Mark")
    mem.on_success(id)
    assert_eq((mem.applied("Hunter's Mark")), "mob", "the mark is on A")

    -- A, B, A, B inside two seconds.
    for _, g in ipairs({ "mob2", "mob", "mob2" }) do
        G.clock = G.clock + 0.4
        mem.target_seen(g)
    end
    local why = G.React.gate("Hunter's Mark", b)
    assert(why and why:find("flapping", 1, true), "marking B now would only move it: " .. tostring(why))
    assert_eq(G.React.gate("Arcane Shot", b), nil, "the gate is only for one-per-caster debuffs")

    G.clock = G.clock + 7
    assert_eq(G.React.gate("Hunter's Mark", b), nil, "the target has settled: mark it")
    a.dead = true
end }

-- --- safety ---------------------------------------------------------------------------------

T[#T + 1] = { "safety: an enemy spell with no enemy is never self-cast; the catalogue's word is checked", function()
    local G = bundle()
    G.known.Kick, G.known.Evasion = true, true
    local R = G.React
    local hits = {}
    R.add_rule({
        name = "Test: kick nothing", category = "interrupt", priority = 99,
        propose = function(W, offer) offer({ name = "Kick", target = nil, target_kind = "enemy" }) end,
    })
    R.add_rule({
        name = "Test: self-only on an enemy", category = "defensive", priority = 98, lane = "fast",
        propose = function(W, offer) offer({ name = "Evasion", target = G.target, target_kind = "enemy" }) end,
    })
    G.catalog.Evasion = { name = "Evasion", range = "self" }
    G.target_present = false
    G.tick()
    G.React.debug_lines()
    G.tick()
    assert_eq(#G.casts, 0, "nothing was cast")
    local lines = R.debug_lines()
    assert(has_line(lines, "no enemy target (would self-cast)"), "says why the kick was refused")
    G.target_present = true
    G.tick()
    lines = R.debug_lines()
    assert(has_line(lines, "catalogue: self-only, not cast on an enemy"), "says why the self spell was refused")
    R.remove_rule("Test: kick nothing")
    R.remove_rule("Test: self-only on an enemy")
    assert_eq(R.engine.rule("Test: kick nothing"), nil, "rules come out as easily as they go in")
end }

T[#T + 1] = { "hardcore bail-out: a hold, not an action -- attacks stop, potions still go", function()
    local G = bundle()
    G.known.Kick = true
    G.items.healthstone = "Major Healthstone"
    G.bail, G.hp, G.hp_rate = true, 0.15, -0.04
    G.rows = { G.row_for(G.target, { targeting_me = true,
                                     casting = G.casting("Shadow Bolt", 1.0, 3.0) }) }
    G.row = G.rows[1]
    G.row.targeting_me = false        -- the bolt is not at us: an attack, not a defence
    G.tick()
    assert_eq(G.verdict.halt, true, "the rotation is halted")
    assert_eq(G.used[1], "healthstone", "the healthstone went out")
    assert_eq(G.sent("Kick"), 0, "no attacks during a bail-out")
    assert(has_line(G.React.log_lines(10), "bail-out START"), "bail-out start is logged")
    G.bail = false
    G.tick()
    assert(has_line(G.React.log_lines(10), "bail-out END"), "and its end")
end }

T[#T + 1] = { "hardcore bail-out: no END is logged for a bail-out that never started", function()
    local G = bundle()
    G.tick()
    G.run(0.5)
    assert(not has_line(G.React.log_lines(20), "bail-out"), "a fresh reload at full health says nothing")
    G.bail, G.hp = true, 0.15
    G.tick()
    G.bail, G.hp = false, 0.6
    G.tick()
    local lines = G.React.log_lines(20)
    assert(has_line(lines, "bail-out START"), "a real start")
    assert(has_line(lines, "bail-out END"), "and its real end")
end }

T[#T + 1] = { "hardcore: the bail-out line has two edges (enter at 20%, leave at 35%)", function()
    package.loaded["jambix_aio/modules/hardcore"] = nil
    local make_hardcore = require("jambix_aio/modules/hardcore")
    local G = { clock = 1000 }
    _G.core = { time = function() return G.clock end }
    local hc = make_hardcore({
        log = recording_log(G),
        ctx = { every = function() end, on = function() end, tick = function() end,
                render = function() end, emit = function() end },
        units = { player = function() return {} end }, combat = {}, draw = {},
        spellbook = {},
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    })
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.19 }), true, "under the line")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.21 }), true, "a percent over: still bailing")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.34 }), true, "under the exit line")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.35 }), false, "over it: attacking again")
    assert_eq(hc.should_stop_fighting({ in_combat = true, hp = 0.30 }), false, "and 30% alone does not re-enter")
end }

-- --- threat ---------------------------------------------------------------------------------

T[#T + 1] = { "threat: rising towards the tank's is dropped before it pulls; nothing to drop with eases off", function()
    local G = bundle({ class = {
        key = "testclass", class_name = "HUNTER", power = "MANA",
        interrupts = {}, defensives = {}, escapes = {},
    } })
    local tank = unit(G, "tank", { name = "Tank", hostile = false })
    G.group = { in_group = true, tanks = { tank }, objects = { tank } }
    G.context = "party"
    G.known["Feign Death"] = true
    G.threat_pct = 72
    G.tick()
    G.clock = G.clock + 0.5
    G.threat_pct = 85                  -- +26/s: 100 within a second and a half
    G.tick()
    assert_eq(G.sent("Feign Death"), 1, "dropped before it pulled")

    local H = bundle({ class = { key = "x", class_name = "HUNTER", power = "MANA" } })
    local tank2 = unit(H, "tank", { name = "Tank", hostile = false })
    H.group = { in_group = true, tanks = { tank2 }, objects = { tank2 } }
    H.context = "party"
    H.threat_pct = 95
    H.tick()
    assert_eq(H.verdict.halt, false, "95% and steady: no pause -- a pause is a character standing still")
    H.threat_pct = 99
    H.clock = H.clock + 0.2
    H.tick()
    assert_eq(H.verdict.halt, true, "99%: no threat drop, so the rotation eases off")
    H.run(2.0)
    assert_eq(H.verdict.halt, false, "for a second and a half, not for ever")
end }

T[#T + 1] = { "hardcore bail-out with nothing left to bail out with: fight on instead of standing still", function()
    local G = bundle()
    G.known.Kick = true
    G.bail, G.hp, G.hp_rate = true, 0.15, -0.04
    G.unready.Evasion, G.unready.Vanish = true, true        -- nothing defensive, no escape, no potion
    G.row = G.row_for(G.target, { targeting_me = true, casting = G.casting("Shadow Bolt", 1.0, 3.0) })
    G.row.targeting_me = false
    G.rows = { G.row }
    G.tick()
    assert_eq(G.verdict.halt, false, "the rotation is not held: standing still would only take the hits")
    assert(has_line(G.React.log_lines(10), "nothing left to bail out with -- fighting on"), "and it says so")

    local H = bundle()
    H.bail, H.hp, H.hp_rate = true, 0.15, -0.04
    H.items.healthstone = "Major Healthstone"
    H.tick()
    assert_eq(H.verdict.halt, true, "with a healthstone in the bag the bail-out holds as before")
end }

-- --- low priority, modularity, cost -------------------------------------------------------

T[#T + 1] = { "below the rotation: the pet is topped up only on a tick the rotation had nothing to press", function()
    local G = bundle()
    G.known["Mend Pet"] = true
    G.in_combat = false
    G.pet_alive, G.health.pet = true, 0.5
    G.tick()
    assert_eq(G.sent("Mend Pet"), 0, "not over the rotation")
    G.React.after_rotation("Aspect of the Hawk")
    assert_eq(G.sent("Mend Pet"), 0, "the rotation pressed something: it waits")
    G.clock = G.clock + 0.6
    G.tick()
    G.React.after_rotation(nil)
    assert_eq(G.sent("Mend Pet"), 1, "the rotation was idle: topped up")
end }

T[#T + 1] = { "cost: a rule asks on its own interval, and an event wakes it early", function()
    local G = bundle()
    local asked = 0
    G.React.add_rule({
        name = "Test: slow", category = "low", priority = 10, every = 0.5,
        wake = { "jcore.enemy.casting" },
        propose = function() asked = asked + 1 end,
    })
    G.React.sync_class_rules()       -- re-wires wake events after a rule is added
    G.run(1.0)
    assert(asked >= 2 and asked <= 3, "twice in a second at 0.5s, not ten times (" .. asked .. ")")
    local before = asked
    G.fire("jcore.enemy.casting", {})
    G.clock = G.clock + 0.01
    G.tick()
    assert_eq(asked, before + 1, "woken by the event")
end }

-- --- what it draws and says ---------------------------------------------------------------

T[#T + 1] = { "overlay: off the threat panel and the low-health banner by default, and draggable", function()
    local G = bundle()
    local rects, texts = {}, {}
    G.P.color = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    G.P.draw = {
        screen_size = function() return 1920, 1080 end,
        rect_2d = function(at, w, h) rects[#rects + 1] = { x = at.x, y = at.y, w = w, h = h } end,
        text_2d = function(at, text) texts[#texts + 1] = { x = at.x, y = at.y, text = text } end,
    }
    G.settings.react_overlay = true
    G.known.Kick = true
    G.row = G.row_for(G.target, { casting = G.casting("Greater Heal", 0.8, 3.0) })
    G.rows = { G.row }
    G.React.overlay_lines()
    G.tick()
    G.React.render()
    assert(#rects >= 2 and #texts >= 3, "drew a bar, a body and lines")

    -- The threat panel: x 24..279, centred vertically. The banner: full width,
    -- 30% down, 54 tall. Neither may be under any part of the panel.
    local banner_bottom = 1080 * 0.30 + 54
    for i = 1, #rects do
        local r = rects[i]
        assert(r.x > 279, "clear of the threat panel's column (x " .. r.x .. ")")
        assert(r.y >= banner_bottom, "below the banner (y " .. r.y .. ")")
        assert(r.x + r.w <= 1920, "on the screen")
    end
    assert(#texts <= 14, "a summary, not the whole readout (" .. #texts .. " lines)")

    -- With JCore's overlay UI, the window is wherever the player dragged it.
    local asked = nil
    G.P.JCore = { ui = { theme = { title_h = 24, scale = 1 } } }
    G.P.ctx.ui = {
        begin_window = function(_, id, opts) asked = { id = id, x = opts.x, y = opts.y } return true, { x = 600, y = 200 } end,
        end_window = function() end,
    }
    rects, texts = {}, {}
    G.React.render()
    assert_eq(asked and asked.id, "react_overlay", "its own remembered window")
    assert_eq(rects[1].x, 600, "drawn where the window was dragged")
    assert_eq(rects[1].y, 224, "under its title bar")
end }

T[#T + 1] = { "readout: never more lines than the menu has rows, even with every lane firing", function()
    local G = bundle({ class = {
        key = "all", class_name = "WARLOCK", power = "MANA",
        interrupts = { "Kick" }, pet_interrupts = { "Spell Lock" },
        defensives = { "Evasion" }, escapes = {},
    } })
    G.known.Kick, G.known.Evasion = true, true
    G.pet_alive, G.pet_known["Spell Lock"] = true, true
    G.hp, G.hp_rate, G.bail = 0.15, -0.08, true
    G.items.potion = "Healing Potion"
    local add = unit(G, "mob2", { name = "Second" })
    G.row = G.row_for(G.target, { targeting_me = true, casting = G.casting("Greater Heal", 0.8, 3.0) })
    G.rows = { G.row, G.row_for(add, { targeting_me = true, casting = G.casting("Fear", 0.9, 1.5) }) }
    G.React.debug_lines()
    G.tick()
    local lines = G.React.debug_lines()
    assert(#lines <= 30, "fits the 30 menu rows (" .. #lines .. ")")
    assert(has_line(lines, "Memory:"), "and the memory line is still there at the bottom")
end }

T[#T + 1] = { "narration: an escape the field already announced is not announced twice", function()
    local G = bundle()
    local said = {}
    G.P.narrate = { say = function(_, title) said[#said + 1] = title return true end }
    G.plan, G.reason, G.hp, G.hp_rate, G.ttl = "FLEE", "3s to live", 0.30, -0.08, 3
    G.tick()
    assert_eq(G.React.stats().mode, "ESCAPE", "escaping")
    assert_eq(#said, 0, "the field said Break off; no second banner: " .. tostring(said[1]))

    local H = bundle()
    local heard = {}
    H.P.narrate = { say = function(_, title) heard[#heard + 1] = title return true end }
    H.hp, H.hp_rate = 0.18, -0.05
    H.tick()
    assert_eq(heard[1], "Emergency", "an emergency nobody else announced is said")
end }

-- --- more than one enemy ---------------------------------------------------------------------

local function mage()
    return { key = "magelike", class_name = "MAGE", power = "MANA",
             interrupts = {}, defensives = {}, escapes = {} }
end

T[#T + 1] = { "surrounded: three in melee is an area control; not in a group unasked, not next to a sheep", function()
    local G = bundle({ class = mage() })
    G.known["Frost Nova"] = true
    local function surround(H)
        H.rows = {}
        for i = 1, 3 do
            local u = unit(H, "m" .. i, { name = "Mob " .. i })
            H.rows[i] = H.row_for(u, { targeting_me = true, dist = 4 })
        end
    end
    surround(G)
    G.tick()
    local n, req = G.sent("Frost Nova")
    assert_eq(n, 1, "novaed")
    assert_eq(req.target, G.player, "a nova is cast on ourselves, not on a mob")

    local H = bundle({ class = mage() })
    H.known["Frost Nova"] = true
    surround(H)
    H.context, H.group = "party", { in_group = true }
    H.tick()
    assert_eq(H.sent("Frost Nova"), 0, "in a group, crowd control waits for its key")
    H.armed.rot_fear_key = true
    H.clock = H.clock + 0.2
    H.tick()
    assert_eq(H.sent("Frost Nova"), 1, "and goes when the key is held")

    local S = bundle({ class = mage() })
    S.known["Frost Nova"] = true
    surround(S)
    S.rows[2].control = { type = 1, remaining = 20 }      -- a sheep
    S.tick()
    assert_eq(S.sent("Frost Nova"), 0, "never next to something already controlled")
end }

T[#T + 1] = { "the pet picks up the add when the mob it holds will stay on it -- our threat on that one decides (1.56.0)", function()
    local G = bundle()
    G.pet_alive, G.pet_target = true, G.target
    local add = unit(G, "add", { name = "Add" })
    G.row = G.row_for(G.target, { targeting_pet = true, hp = 0.6, threat = { percent = 78 } })
    G.rows = { G.row, G.row_for(add, { targeting_me = true }) }
    G.React.debug_lines()
    G.tick()
    assert_eq(G.assigned, nil, "our threat on the pet's mob is 78%: it would turn on us, so the pet stays")
    assert(has_line(G.React.debug_lines(), "pet leaves Add: your threat on Defias Pillager is 78%"),
        "the plan says why the pet stays")

    -- The pet's threat on its mob does not go with the pet: with ours low, it stays put.
    G.row.threat.percent = 35
    G.clock = G.clock + 0.3
    G.tick()
    assert(G.assigned and G.assigned.unit == add, "ours is 35%: the pet is sent at the add, its mob still healthy")
    assert(G.assigned.seconds and G.assigned.seconds > 0, "and pinned there for a few seconds")

    local N = bundle()
    N.pet_alive, N.pet_target = true, N.target
    local add3 = unit(N, "add", { name = "Add" })
    N.row = N.row_for(N.target, { targeting_pet = true, hp = 0.2, threat = { percent = 95 } })
    N.rows = { N.row, N.row_for(add3, { targeting_me = true }) }
    N.tick()
    assert(N.assigned and N.assigned.unit == add3, "its mob is nearly dead: the pet goes whatever our threat")

    local H = bundle()
    H.pet_alive, H.pet_target = true, H.target
    H.context = "party"
    local add2 = unit(H, "add", { name = "Add" })
    H.rows = { H.row_for(H.target, { targeting_pet = true, hp = 0.1 }), H.row_for(add2, { targeting_me = true }) }
    H.tick()
    assert_eq(H.assigned, nil, "in a group a tank holds the adds, not the pet")
end }

T[#T + 1] = { "nothing selected: the pet is not sent at the add, nor a pet skill aimed at a mob (1.87.1)", function()
    local G = bundle()
    G.pet_alive, G.pet_target = true, G.target
    local add = unit(G, "add", { name = "Add" })
    G.rows = { G.row_for(G.target, { targeting_pet = true, hp = 0.2, threat = { percent = 95 } }),
               G.row_for(add, { targeting_me = true }) }
    local home = true
    G.P.pet.home = function() return home end
    G.tick()
    assert_eq(G.assigned, nil, "nothing selected: the pet stays with you")
    home = false
    G.clock = G.clock + 0.3
    G.tick()
    assert(G.assigned and G.assigned.unit == add, "a mob selected: the pet takes the add")
end }


-- --- the plan for the fight (react/tactics.lua, 1.56.0) ---------------------------------------

--- A hit on us from `source`, as the combat log reports a swing.
local function swing_at_me(G, source, amount)
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
        0, "SWING_DAMAGE", false, source, source, 0, 0, "player", "Me", 0, 0, amount,
    })
end

T[#T + 1] = { "plan: an add joins -- it is announced with the kill order, the pet takes it, the readout says so", function()
    local G = bundle()
    G.pet_alive, G.pet_target = true, G.target
    G.row = G.row_for(G.target, { targeting_pet = true, hp = 0.4, threat = { percent = 30 } })
    G.rows = { G.row }
    G.tick()
    assert_eq(G.React.plan().live, false, "one mob: no plan, the rotation as written")

    G.run(2.0)
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.rows = { G.row, G.row_for(add, { targeting_me = true, dist = 4 }) }
    G.React.debug_lines()
    G.run(0.1)
    local plan = G.React.plan()
    assert_eq(plan.live, true, "two engaged: a plan")
    assert_eq(plan.focus, G.target, "the pet's mob at 40% dies first; the fresh add on us waits")
    assert(has_line(G.React.log_lines(10), "Mottled Boar joined: 2 in the fight -- kill Defias Pillager first (40%, on the pet)"),
        "the journal names the add and the answer")
    assert(G.assigned and G.assigned.unit == add, "the pet takes the add off us: its own mob stays on it")
    local lines = G.React.debug_lines()
    assert(has_line(lines, "Plan: 2 in the fight (Mottled Boar joined 0s ago) -- kill Defias Pillager (40%, on the pet), then Mottled Boar (100%, on you)"),
        "the readout has the kill order")
    assert(has_line(lines, "pet takes Mottled Boar: your threat on Defias Pillager is 30%: it stays on the pet"),
        "and the pet's job, with its reason")
end }

T[#T + 1] = { "plan: the mob doing the most for the health it has goes first; a sheep never does; a switch needs a margin", function()
    local G = bundle()
    local b = unit(G, "b", { name = "Kobold" })
    G.row = G.row_for(G.target, { targeting_me = true, hp = 0.9 })
    local brow = G.row_for(b, { targeting_me = true, hp = 0.3 })
    G.rows = { G.row, brow }
    swing_at_me(G, "mob", 30)
    swing_at_me(G, "b", 30)
    G.tick()
    local focus, live = G.React.focus()
    assert_eq(live, true, "a plan")
    assert_eq(focus, b, "same damage, a third of the health left: the Kobold first")

    -- The Kobold is polymorphed: out of the fight until something hits it.
    brow.control = { type = 99, remaining = 20 }
    G.clock = G.clock + 2.0
    G.React.debug_lines()
    G.tick()
    assert_eq((G.React.focus()), G.target, "never the sheep")
    assert(has_line(G.React.debug_lines(), "Kobold (controlled: leave it)"), "the readout says to leave it")

    -- Nearly level: the one we are on stays (a switch costs a global cooldown and the mark).
    local H = bundle()
    local c = unit(H, "c", { name = "Kobold" })
    H.row = H.row_for(H.target, { targeting_me = true, hp = 0.5 })
    H.rows = { H.row, H.row_for(c, { targeting_me = true, hp = 0.45 }) }
    swing_at_me(H, "mob", 30)
    swing_at_me(H, "c", 30)
    H.tick()
    assert_eq((H.React.focus()), H.target, "45% against 50%: not worth a switch")

    -- In a group the tank decides; the plan stays out of it.
    local Q = bundle()
    Q.context = "party"
    local d = unit(Q, "d", { name = "Kobold" })
    Q.rows = { Q.row_for(Q.target, { targeting_me = true, hp = 0.9 }), Q.row_for(d, { targeting_me = true, hp = 0.2 }) }
    Q.tick()
    local f2, live2 = Q.React.focus()
    assert_eq(live2, false, "no plan in a group")
    assert_eq(f2, nil, "and no focus")
end }

T[#T + 1] = { "plan: the race counts the add from its first hit -- outnumbered is DEFENSIVE, and fires no defensive by itself", function()
    local G = bundle()
    G.known.Evasion = true
    G.my_hp, G.ttc = 300, 12
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.rows = { G.row_for(G.target, { targeting_me = true, hp = 0.8 }) }
    G.tick()
    swing_at_me(G, "mob", 30)
    G.run(2.0)
    swing_at_me(G, "mob", 30)
    assert_eq(G.React.stats().mode, "NORMAL", "one mob hitting for 15 a second: 20s to live, 12s to clear")

    -- The add lands its first hit: 30 a second on 300 health is 10s, against 12s to clear.
    G.rows[2] = G.row_for(add, { targeting_me = true, dist = 4 })
    swing_at_me(G, "add", 30)
    G.run(0.1)
    assert_eq(G.React.stats().mode, "DEFENSIVE", "outnumbered at once, before the health bar shows it")
    assert(has_line(G.React.log_lines(10), "outnumbered: 2 on you"), "the journal says so")
    assert_eq(G.sent("Evasion"), 0, "a defensive cooldown is not fired on a forecast alone")

    -- The add is controlled: one on us again, the race is won, the mode steps down.
    G.rows[2].control = { type = 99, remaining = 10 }
    G.run(2.0)
    assert_eq(G.React.stats().mode, "NORMAL", "no longer outnumbered")
end }

T[#T + 1] = { "plan on Forever: no combat log -- JCore's rates from our health drive the kill order and the race (1.57.0)", function()
    local G = bundle({ forever = true })
    local rates = {}
    G.P.ctx.enemies = { damage_rate = function(guid) return rates[guid] end }
    G.my_hp, G.ttc = 300, 12
    local b = unit(G, "b", { name = "Kobold" })
    G.row = G.row_for(G.target, { targeting_me = true, hp = 0.9 })
    local brow = G.row_for(b, { targeting_me = true, hp = 0.9 })
    G.rows = { G.row, brow }
    rates.mob, rates.b = 5, 25              -- the Kobold hits five times as hard
    G.React.debug_lines()
    G.tick()
    assert_eq((G.React.focus()), b, "the one hurting us most goes first, from JCore's rates")
    assert_eq(G.React.stats().mode, "DEFENSIVE", "30 a second on 300 health against 12s to clear: outnumbered")
    assert(has_line(G.React.debug_lines(), "(their damage read from your health)"), "the readout says where it came from")

    -- JCore read a stun off the Kobold's debuffs: still the one to kill.
    brow.control = { kind = "stun", breaks = false, remaining = 4 }
    G.clock = G.clock + 2.0
    G.tick()
    assert_eq((G.React.focus()), b, "stunned is not asleep: damage does not end a stun")
    -- A polymorph read off its debuffs: never.
    brow.control = { kind = "incapacitate", breaks = true, remaining = 20 }
    G.clock = G.clock + 2.0
    G.tick()
    assert_eq((G.React.focus()), G.target, "the sheep is left alone")
end }

T[#T + 1] = { "plan on Forever: threat JCore calls unread keeps the pet on a mob you have hit (no fake 0%) (1.57.0)", function()
    local G = bundle({ forever = true })
    G.dispatch = true
    G.pet_alive, G.pet_target = true, G.target
    local add = unit(G, "add", { name = "Add" })
    G.row = G.row_for(G.target, { targeting_pet = true, hp = 0.6 })          -- threat = nil: unread
    G.rows = { G.row, G.row_for(add, { targeting_me = true }) }
    G.fire("jcore.cast.sent", { spell_id = G.id_of("Arcane Shot"), target = G.target, owner = "jambix.aio" })
    G.React.debug_lines()
    G.tick()
    assert_eq(G.assigned, nil, "you have hit the pet's mob and its threat is unread: the pet stays")
    assert(has_line(G.React.debug_lines(), "pet leaves Add: your threat on Defias Pillager is unread"), "and says why")

    local H = bundle({ forever = true })
    H.pet_alive, H.pet_target = true, H.target
    local add2 = unit(H, "add", { name = "Add" })
    H.rows = { H.row_for(H.target, { targeting_pet = true, hp = 0.6 }), H.row_for(add2, { targeting_me = true }) }
    H.tick()
    assert(H.assigned and H.assigned.unit == add2, "you have not hit it: it stays on the pet, so the pet takes the add")
end }

-- --- the plan in a group, and the hunter's add (1.58.0) ---------------------------------------

--- A party around the bundle: a tank, a healer, mobs fighting them. The tank's
--- target is whatever `G.tank_on` names.
local function party(G)
    G.context = "party"
    local tank = unit(G, "tank", { name = "Brick", hostile = false })
    local healer = unit(G, "healer", { name = "Mend", hostile = false })
    function tank.get_target() return G.tank_on end
    G.group = { in_group = true, tanks = { tank }, healers = { healer }, objects = { tank, healer } }
    G.tank_unit, G.healer_unit = tank, healer
    return tank, healer
end

local function on(G, u, who, fields)
    local r = G.row_for(u, { engaged = false, in_combat = true, target_guid = who, dist = 15 })
    for k, v in pairs(fields or {}) do r[k] = v end
    return r
end

T[#T + 1] = { "group plan: the tank's target first, a skull before it, never a mob you would pull off the tank", function()
    local G = bundle()
    party(G)
    local c = unit(G, "c", { name = "Kobold Geomancer" })
    G.rows = { on(G, G.target, "tank"), on(G, c, "tank") }
    G.tank_on = c
    G.React.debug_lines()
    G.tick()
    local plan = G.React.plan()
    assert_eq(plan.live, true, "a damage dealer in a group: a plan")
    assert_eq(plan.mode, "group", "in group mode")
    assert_eq((G.React.focus()), c, "everyone on the tank's target")
    local lines = G.React.debug_lines()
    assert(has_line(lines, "Plan (group): 2 in the fight -- kill Kobold Geomancer (100%, on the tank, the tank's target)"),
        "the readout says why")

    -- A skull outranks the tank's target.
    local H = bundle()
    party(H)
    local s = unit(H, "s", { name = "Kobold Tunneler" })
    function s.get_target_marker_index() return 8 end
    local c2 = unit(H, "c", { name = "Kobold Geomancer" })
    H.rows = { on(H, s, "tank"), on(H, c2, "tank") }
    H.tank_on = c2
    H.tick()
    assert_eq((H.React.focus()), s, "skull first")

    -- Our threat on the tank's target is at 96%: leave it to the tank for a moment.
    local Q = bundle()
    party(Q)
    local c3 = unit(Q, "c", { name = "Kobold Geomancer" })
    Q.rows = { on(Q, Q.target, "tank"), on(Q, c3, "tank", { threat = { percent = 96 } }) }
    Q.tank_on = c3
    Q.tick()
    assert_eq((Q.React.focus()), Q.target, "not the one about to turn on you")
end }

-- 1.74.0: the live log (a five-man on Forever) re-planned "kill X first"
-- every one to three seconds while the tank tabbed through the pack.
T[#T + 1] = { "group plan: a tank tabbing for Sunders does not move the kill; a skull does (1.74.0)", function()
    local G = bundle()
    party(G)
    local a = G.target
    local c = unit(G, "c", { name = "Kobold Geomancer" })
    G.rows = { on(G, a, "tank"), on(G, c, "tank") }
    G.tank_on = c
    G.tick()
    assert_eq((G.React.focus()), c, "the tank's target at the start")
    G.target = c                               -- targeting went to it
    G.run(2)
    G.tank_on = a                              -- the tank tabs to the other, and stays a while
    G.run(6)
    assert_eq((G.React.focus()), c, "x1.6 for the tank's target is not twice as urgent: the kill stays")
    function a.get_target_marker_index() return 8 end
    G.run(0.5)
    assert_eq((G.React.focus()), a, "a skull is the group's kill")
end }

T[#T + 1] = { "group plan: the healer's attacker before the tank's mob; the tank and the healer keep their own; no tank is solo", function()
    local G = bundle()
    party(G)
    local b = unit(G, "b", { name = "Kobold Miner" })
    G.rows = { on(G, G.target, "tank"), on(G, b, "healer") }
    G.tick()
    assert_eq((G.React.focus()), b, "the mob hitting the healer")

    local K = bundle()
    party(K)
    K.group.me_tank = true
    K.rows = { on(K, K.target, "tank"), on(K, unit(K, "b", {}), "healer") }
    K.tick()
    assert_eq(K.React.plan().live, false, "the tank picks its own targets")

    local L = bundle()
    party(L)
    L.group.healers = { L.player }
    L.rows = { on(L, L.target, "tank"), on(L, unit(L, "b", {}), "tank") }
    L.tick()
    assert_eq(L.React.plan().live, false, "and so does the healer")

    local D = bundle()
    party(D)
    D.tank_unit.dead = true
    local b2 = unit(D, "b", { name = "Kobold Miner" })
    D.rows = { D.row_for(D.target, { targeting_me = true, hp = 0.9 }), D.row_for(b2, { targeting_me = true, hp = 0.3 }) }
    D.tick()
    local plan = D.React.plan()
    assert_eq(plan.live, true, "the tank is dead: fought as solo")
    assert_eq(plan.mode, "solo", "solo mode")
end }

T[#T + 1] = { "group plan: a hit on a member counts as that mob's damage (the combat log, by source)", function()
    local G = bundle()
    party(G)
    G.rows = { on(G, G.target, "tank") }
    G.tick()                                   -- the group roster is read
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", {
        0, "SWING_DAMAGE", false, "mob", "Defias Pillager", 0, 0, "healer", "Mend", 0, 0, 40,
    })
    local rate = G.React.tactics.measured("mob")
    assert(rate and rate > 0, "the hit on the healer is the mob's")
end }

--- A hunter in the bundle, with Wing Clip.
local function hunter(G)
    G.known["Wing Clip"] = true
    G.debuffs = {}
    G.P.rotation.helpers.debuff_up = function(u, name) return G.debuffs[u.guid .. ":" .. name] == true end
end

T[#T + 1] = { "hunter: an add in melee that is not the target is clipped -- unless the pet is taking it (1.58.0)", function()
    local HUNTER = { key = "hunter", class_name = "HUNTER", power = "MANA", interrupts = {}, defensives = {}, escapes = {} }
    local G = bundle({ class = HUNTER })
    hunter(G)
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = G.row_for(G.target, { targeting_me = false, dist = 25 })
    G.rows = { G.row, G.row_for(add, { targeting_me = true, dist = 3 }) }
    G.React.debug_lines()
    G.tick()
    local n, last = G.sent("Wing Clip")
    assert_eq(n, 1, "no pet to take it: Wing Clip")
    assert_eq(last.target, add, "on the add, not the target")
    assert(has_line(G.React.debug_lines(), "in the dead zone, not the target"), "the readout says why")

    -- The pet will take it: the plan says its own mob stays on it.
    local P2 = bundle({ class = HUNTER })
    hunter(P2)
    P2.pet_alive, P2.pet_target = true, P2.target
    local add2 = unit(P2, "add", { name = "Mottled Boar" })
    P2.row = P2.row_for(P2.target, { targeting_pet = true, dist = 25, threat = { percent = 20 } })
    P2.rows = { P2.row, P2.row_for(add2, { targeting_me = true, dist = 3 }) }
    P2.tick()
    assert_eq(P2.sent("Wing Clip"), 0, "the pet takes it instead")
    assert(P2.assigned and P2.assigned.unit == add2, "and is sent")

    -- The pet cannot leave its mob (ours on it is 80%): clip the add.
    local P3 = bundle({ class = HUNTER })
    hunter(P3)
    P3.pet_alive, P3.pet_target = true, P3.target
    local add3 = unit(P3, "add", { name = "Mottled Boar" })
    P3.row = P3.row_for(P3.target, { targeting_pet = true, dist = 25, threat = { percent = 80 } })
    P3.rows = { P3.row, P3.row_for(add3, { targeting_me = true, dist = 3 }) }
    P3.tick()
    assert_eq(P3.sent("Wing Clip"), 1, "the pet stays: Wing Clip the add")

    -- Already clipped: nothing.
    local C = bundle({ class = HUNTER })
    hunter(C)
    local add4 = unit(C, "add", { name = "Mottled Boar" })
    C.debuffs["add:Wing Clip"] = true
    C.rows = { C.row_for(C.target, { dist = 25 }), C.row_for(add4, { targeting_me = true, dist = 3 }) }
    C.tick()
    assert_eq(C.sent("Wing Clip"), 0, "it cannot follow already")
end }

-- --- mana ---------------------------------------------------------------------------------------

T[#T + 1] = { "mana: a gem first, a potion only when a healing potion will not be wanted, nothing near the end", function()
    local G = bundle({ class = mage() })
    G.power, G.items.mana_gem, G.items.mana_potion = 8, "Mana Ruby", "Major Mana Potion"
    G.tick()
    assert_eq(G.used[1], "mana_gem", "the gem: its own cooldown")

    local H = bundle({ class = mage() })
    H.power, H.items.mana_potion = 8, "Major Mana Potion"
    H.items.potion = "Major Healing Potion"
    H.hp = 0.40
    H.tick()
    assert_eq(#H.used, 0, "at 40% health the shared cooldown is kept for the healing potion")
    H.hp = 0.9
    H.clock = H.clock + 2.1
    H.tick()
    assert_eq(H.used[1], "mana_potion", "healthy: the mana potion")

    local E = bundle({ class = mage() })
    E.power, E.items.mana_gem, E.fight_left = 8, "Mana Ruby", 3
    E.tick()
    assert_eq(#E.used, 0, "three seconds of fight left: drink afterwards instead")

    local R = bundle({ class = mage() })
    R.power, R.power_empty, R.fight_left, R.items.mana_gem = 30, 8, 20, "Mana Ruby"
    R.tick()
    assert_eq(R.used[1], "mana_gem", "30% is not low, but it runs dry 12s before the fight does")
end }

T[#T + 1] = { "mana: Evocation between pulls, never with something hitting you", function()
    local G = bundle({ class = mage() })
    G.known.Evocation = true
    G.in_combat, G.power = false, 15
    G.tick()
    assert_eq(G.sent("Evocation"), 1, "out of combat at 15%: evocate instead of sitting down")

    local H = bundle({ class = mage() })
    H.known.Evocation = true
    H.power = 8
    H.rows = { H.row_for(H.target, { targeting_me = true }) }
    H.tick()
    assert_eq(H.sent("Evocation"), 0, "a channel under attack is pushed back to nothing")
end }

T[#T + 1] = { "the removed switches do nothing: a stale saved value cannot turn a reaction off", function()
    local G = bundle()
    for _, id in ipairs({ "rot_interrupt", "rot_use_defensives", "rot_dispel", "rot_use_racials",
                          "pet_heal", "pet_interrupt", "pet_manage_growl", "hc_use_consumables",
                          "hc_bail_out", "hc_escape_abilities", "rot_escape_when_losing", "react_enabled" }) do
        G.settings[id] = false
    end
    G.settings.hc_potion_hp, G.settings.rot_defensive_hp, G.settings.pet_heal_hp = 5, 5, 5
    G.known.Kick = true
    G.row = G.row_for(G.target, { casting = G.casting("Greater Heal", 0.8, 3.0) })
    G.rows = { G.row }
    G.items.healthstone = "Major Healthstone"
    G.hp, G.hp_rate = 0.30, -0.05
    G.tick()
    assert_eq(G.sent("Kick"), 1, "still interrupts")
    assert_eq(G.used[1], "healthstone", "still drinks at 30% (a saved 5% line is ignored)")
end }

-- --- the rotation, with the engine in front of it -------------------------------------------

local function rotation_bundle()
    local G = bundle()
    local P = G.P
    package.loaded["jambix_aio/modules/rotation"] = nil
    local make_rotation = require("jambix_aio/modules/rotation")

    G.player.get_class = function() return 4 end              -- rogue
    G.player.is_moving = function() return false end
    G.player.is_mounted = function() return false end
    G.player.get_attack_speed = function() return 2 end
    G.target.is_casting_spell = function() return G.row ~= nil and G.row.casting ~= nil end
    G.target.is_active_spell_interruptable = function() return true end

    P.ctx.tick = function() end
    P.ctx.every = function() end
    P.ctx.enemies = {
        all = function() return G.rows end,
        count = function() return #G.rows end,
        get = function(u) return u == G.target and G.row or nil end,
        first_arrival = function() return nil, math.huge end,
        next_cast = function() return nil, nil end,
    }
    P.ctx.spells.ready = function() return true end
    P.rotation_active = function() return true end
    P.power = function() return 80 end
    P.power_max = function() return 100 end
    P.units.distance = function() return 4 end
    P.units.has_aura = function() return false end
    P.units.lowest_health_ally = function() return nil end
    P.combat.target = function() return G.target end
    P.combat.in_combat = function() return true end
    P.combat.time_to_die = function() return 20 end
    P.targeting.aoe_count = function() return 1 end
    P.targeting.best_cluster = function() return 1, nil end
    P.targeting.loose = function() return 0 end
    P.targeting.better_target = function() return nil end
    P.field.by_weakest = function() return { G.target } end
    P.field.in_trouble = function() return false end
    P.field.plan = function() return G.plan end
    P.talents = { rank = function() return 0 end }
    P.resources.fight_left = function() return 20 end
    P.resources.state = { posture = "HEALTHY" }
    P.settings = G.settings
    G.settings.rot_enabled = true

    local react = G.React
    P.rotation = make_rotation(P)
    P.react = react
    P.rotation.classes.ROGUE = {
        key = "rogue", class_name = "ROGUE", power = "ENERGY",
        interrupts = { "Kick" }, defensives = { "Evasion" }, escapes = {},
        profiles = { test = { label = "Test", rules = {
            { "Sinister Strike", function() return true end },
        } } },
        profile_order = { "test" },
    }
    G.known["Sinister Strike"], G.known.Kick = true, true
    return G
end

T[#T + 1] = { "rotation (1.62.0): a spell the class window keeps is never pressed by the walk", function()
    local G = rotation_bundle()
    G.P.rotation.tick()
    assert(G.sent("Sinister Strike") >= 1, "pressed while nothing owns it")
    local before = G.sent("Sinister Strike")
    G.P.classwin = { owns = function(name) return name == "Sinister Strike" end, form_choice = function() return nil end }
    G.clock = G.clock + 3
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), before, "the window keeps it: the walk leaves it alone")
    assert_eq(G.P.rotation.press_blocked("Sinister Strike", { player = G.player }, G.target), "the class window keeps it",
        "and a reaction is told why")
end }

T[#T + 1] = { "rotation: a reaction on the global cooldown replaces the walk for that tick only", function()
    local G = rotation_bundle()
    G.row = G.row_for(G.target, { casting = G.casting("Greater Heal", 1.0, 3.0) })
    G.rows = { G.row }
    G.P.rotation.tick()
    assert_eq(G.sent("Kick"), 1, "the interrupt")
    assert_eq(G.sent("Sinister Strike"), 0, "and no strike in the same tick")
    assert(G.casts[1].reason:find("react: Kick", 1, true), "sent by the engine, with its reason")

    G.row.casting = nil
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), 0, "the kick has not landed yet: the walk does not press over it")
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", G.id_of("Kick") })
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), 1, "confirmed, nothing urgent: the rotation runs as before")
end }

T[#T + 1] = { "rotation: a channel the engine sent is not cut off before it shows on the cast bar", function()
    local G = rotation_bundle()
    G.known["Mend Pet"] = true
    G.pet_alive, G.pet_target = true, G.target
    G.health.pet = 0.15
    G.P.rotation.tick()
    assert_eq(G.sent("Mend Pet"), 1, "the heal went out")

    -- The client confirms a channel BEFORE it starts it; the cast bar is still empty.
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", G.id_of("Mend Pet") })
    G.health.pet = 0.5
    G.React.debug_lines()
    for _ = 1, 2 do
        G.clock = G.clock + 0.1
        G.P.rotation.tick()
    end
    assert_eq(G.sent("Sinister Strike"), 0, "nothing pressed into the gap (was the 7:27 Mend Pet)")
    assert(has_line(G.React.debug_lines(), "waiting for Mend Pet to start"), "the readout says why")

    -- The channel shows: the hold ends, and the rotation's own cast gate
    -- keeps the walk off it until it is done.
    G.cast_remaining = 4.5
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), 0, "not over the running channel")
    G.cast_remaining = 0
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), 1, "the channel ended: the rotation runs")

    -- Nothing ever answers: the hold gives up on its own, within a second.
    local H = rotation_bundle()
    H.known["Mend Pet"] = true
    H.pet_alive, H.pet_target = true, H.target
    H.health.pet = 0.15
    H.P.rotation.tick()
    H.health.pet = 0.5
    for _ = 1, 9 do
        H.clock = H.clock + 0.1
        H.P.rotation.tick()
    end
    assert_eq(H.sent("Sinister Strike") >= 1, true, "the hold is bounded")
end }

T[#T + 1] = { "pet heal: a tuned line that swings does not open a new dip (the 7:27 / 7:31 double heal)", function()
    local G = bundle()
    G.known["Mend Pet"] = true
    G.pet_alive, G.pet_target = true, G.target
    G.tune = { pet_heal_hp = 0.49 }        -- the pet is taking a beating: the line is high
    G.health.pet, G.pet_rate = 0.48, -0.10
    G.tick()
    assert_eq(G.sent("Mend Pet"), 1, "healed at 48% under a 49% line")
    local lines = G.React.log_lines(10)
    assert(has_line(lines, "pet_low ON"), "the dip opened")

    -- The damage stops for a moment: the line falls to 10%, the pet sits at 36%.
    G.tune.pet_heal_hp, G.pet_rate, G.health.pet = 0.10, 0, 0.36
    G.run(1.0)
    assert(not has_line(G.React.log_lines(10), "pet_low off"), "still the same dip: it ends at 74%, not at 35%")
    -- The damage resumes, the line jumps back: still the same dip, still handled.
    G.tune.pet_heal_hp, G.pet_rate, G.health.pet = 0.40, -0.08, 0.30
    G.run(2.0)
    assert_eq(G.sent("Mend Pet"), 1, "no second heal four seconds after the first")

    -- The heal is refused outright: the dip is open again at once.
    local H = bundle()
    H.known["Mend Pet"] = true
    H.pet_alive, H.pet_target = true, H.target
    H.health.pet, H.pet_rate = 0.15, -0.05
    H.tick()
    H.fire("jcore.game_event.UNIT_SPELLCAST_FAILED", { "player", "g", H.id_of("Mend Pet") })
    H.clock = H.clock + 2.1
    H.tick()
    assert_eq(H.sent("Mend Pet"), 2, "a refused heal does not keep the dip marked as answered")
end }

-- --- the pet heal, weighed (1.66.0, react/petcare.lua) -------------------------------------

--- A pet holding the target, at this health and losing this much a second.
local function pet_fight(G, pet_hp, pet_rate)
    G.known["Mend Pet"] = true
    G.pet_alive, G.pet_target = true, G.target
    G.health.pet, G.pet_rate = pet_hp, pet_rate
    G.row = G.row_for(G.target, { targeting_pet = true, dist = 25 })
    G.rows = { G.row }
end

T[#T + 1] = { "pet heal (1.66.0): never started when standing still would get you killed", function()
    -- A mob in melee with you at 45%: five seconds standing in it is too many.
    local G = bundle()
    pet_fight(G, 0.15, -0.05)
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.rows[2] = G.row_for(add, { targeting_me = true, dist = 3 })
    G.hp = 0.45
    G.React.debug_lines()
    G.tick()
    assert_eq(G.sent("Mend Pet"), 0, "not with a mob on you at 45%")
    assert(has_line(G.React.debug_lines(), "1 in melee with you at 45%"), "the readout says why")
    assert(has_line(G.React.log_lines(10), "Mend Pet waits: 1 in melee with you at 45%"), "and so does the log")

    -- The same at 90%: it costs points, it is not a veto.
    local H = bundle()
    pet_fight(H, 0.15, -0.05)
    local add2 = unit(H, "add", { name = "Mottled Boar" })
    H.rows[2] = H.row_for(add2, { targeting_me = true, dist = 3 })
    H.hp = 0.90
    H.React.debug_lines()
    H.tick()
    assert_eq(H.sent("Mend Pet"), 1, "healthy: healed anyway")
    assert(has_line(H.React.debug_lines(), "hits cut the channel short"), "with the cost in the readout")

    -- Your own health would end the channel under the defensive line.
    local F = bundle()
    pet_fight(F, 0.15, -0.05)
    local caster = unit(F, "caster", { name = "Defias Conjurer" })
    F.rows[2] = F.row_for(caster, { targeting_me = true, dist = 25 })
    F.hp, F.hp_rate = 0.55, -0.05
    F.tick()
    assert_eq(F.sent("Mend Pet"), 0, "55% falling 5%/s ends the channel at 30%")
    assert(has_line(F.React.log_lines(10), "you would end it at 30%"), "said so")

    -- A mob arriving inside the channel, at 40%.
    local A = bundle()
    pet_fight(A, 0.15, -0.05)
    local runner = unit(A, "runner", { name = "Gnoll Brute" })
    A.rows[2] = A.row_for(runner, { targeting_me = true, dist = 15, closing = 6, time_to_reach = 1.7 })
    A.hp = 0.40
    A.tick()
    assert_eq(A.sent("Mend Pet"), 0, "it would reach you halfway through")
    assert(has_line(A.React.log_lines(10), "Gnoll Brute reaches you in 1.7s"), "said so")

    -- Standing in ground about to be hit.
    local D = bundle()
    pet_fight(D, 0.15, -0.05)
    D.P.ctx.telegraphs = { on_me = function() return { { name = "Flamestrike" } } end }
    D.tick()
    assert_eq(D.sent("Mend Pet"), 0, "not rooted in a Flamestrike")
    assert(has_line(D.React.log_lines(10), "standing in Flamestrike"), "said so")
    D.P.ctx.telegraphs = { on_me = function() return {} end }
    D.clock = D.clock + 0.1
    D.tick()
    assert_eq(D.sent("Mend Pet"), 1, "out of it: healed")

    -- The mana Feign Death needs is kept while something is on you.
    local M = bundle({ class = { key = "hunterlike", class_name = "HUNTER", power = "MANA",
                                 interrupts = {}, defensives = {}, escapes = { "Feign Death" } } })
    pet_fight(M, 0.15, -0.05)
    M.known["Feign Death"] = true
    M.P.auto = { cost = function(name) return (name == "Feign Death" and 50) or (name == "Mend Pet" and 40) or 0, 0 end }
    local add3 = unit(M, "add", { name = "Mottled Boar" })
    M.rows[2] = M.row_for(add3, { targeting_me = true, dist = 25 })
    M.power = 80
    M.tick()
    assert_eq(M.sent("Mend Pet"), 0, "80 mana - 40 leaves 40, and Feign Death needs 50")
    assert(has_line(M.React.log_lines(10), "Feign Death needs 50"), "said so")
    M.power = 95
    M.clock = M.clock + 0.1
    M.tick()
    assert_eq(M.sent("Mend Pet"), 1, "with enough for both: healed")
end }

T[#T + 1] = { "pet heal (1.66.0): a pet that outlives the fight finishes it; one that dies inside the channel is not channelled into", function()
    local G = bundle()
    pet_fight(G, 0.18, -0.01)          -- eighteen seconds to live
    G.ttd = 3                           -- the mob has three
    G.tick()
    assert_eq(G.sent("Mend Pet"), 0, "the mob dies first: shooting on")
    assert(has_line(G.React.log_lines(10), "shooting on"), "said so")
    G.ttd = 20
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.sent("Mend Pet"), 1, "a long fight: healed")

    -- Losing 30%/s: even a generous guess at the heal cannot keep up.
    local H = bundle()
    pet_fight(H, 0.15, -0.30)
    H.tick()
    assert_eq(H.sent("Mend Pet"), 0, "it would die inside the channel")
    assert(has_line(H.React.log_lines(10), "dies inside the channel"), "said so")

    -- The tooltip says what it heals: 100 over 5s on a 1000-health pet is
    -- 2%/s, and a pet losing 5%/s at 14% does not see the end of it.
    local K = bundle()
    pet_fight(K, 0.14, -0.05)
    _G.core.spell_book.get_spell_description = function() return "Heals your pet for 100 health over 5 sec." end
    K.P.units.max_health = function() return 1000 end
    K.tick()
    assert_eq(K.sent("Mend Pet"), 0, "2%/s against 5%/s")
    assert(has_line(K.React.log_lines(10), "heals ~2%/s"), "read from the tooltip")
    K.P.units.max_health = function() return 300 end    -- a small pet: 6.7%/s
    K.clock = K.clock + 0.1
    K.tick()
    assert_eq(K.sent("Mend Pet"), 1, "the same heal on a small pet keeps up")

    local parse = K.React.petcare.parse_heal
    assert_eq(select(1, parse("Heals your pet for 1,225 health over 5 sec.")), 245, "Classic text, with a comma")
    assert_eq(select(2, parse("Heals your pet for 25% of its total health over 10 sec.")), 0.025, "a share of the bar")
    assert_eq(select(1, parse("Gives 12 health to the caster's pet every second for 10 sec as long as the caster channels.")), 12,
        "Health Funnel")
end }

T[#T + 1] = { "pet heal (1.66.0): Improved Mend Pet frees a feared pet at any health and clears a poison sooner", function()
    local HUNTER = { key = "hunter", class_name = "HUNTER", power = "MANA", interrupts = {}, defensives = {}, escapes = {} }
    local G = bundle({ class = HUNTER })
    hunter(G)
    pet_fight(G, 0.95, 0)
    G.P.talents = { rank = function(n) return n == "Improved Mend Pet" and 2 or 0 end,
                    points = function() return 21, 0, 30 end }
    G.pet_debuffs = { { buff_name = "Psychic Scream", buff_id = 8122, type = 1 } }      -- Magic
    G.pet.get_debuffs = function() return G.pet_debuffs end
    G.React.debug_lines()
    G.tick()
    assert_eq(G.sent("Mend Pet"), 1, "a feared pet at 95%: Mend Pet frees it")
    local lines = G.React.debug_lines()
    assert(has_line(lines, "97% to free it from Psychic Scream"), "the talent's chance, in the readout")
    assert(has_line(lines, "Beast Mastery (21 points)"), "and what the pet is worth")

    -- Without the talent Mend Pet cannot free it: nothing.
    local H = bundle({ class = HUNTER })
    hunter(H)
    pet_fight(H, 0.95, 0)
    H.P.talents = { rank = function() return 0 end }
    H.pet.get_debuffs = function() return { { buff_name = "Psychic Scream", buff_id = 8122, type = 1 } } end
    H.tick()
    assert_eq(H.sent("Mend Pet"), 0, "no talent: no channel")

    -- A poison it can clear raises the line.
    local K = bundle()
    pet_fight(K, 0.28, 0)
    K.P.talents = { rank = function(n) return n == "Improved Mend Pet" and 2 or 0 end }
    K.pet.get_debuffs = function() return K.pet_debuffs or {} end
    K.tick()
    assert_eq(K.sent("Mend Pet"), 0, "28% with nothing on it: not yet")
    K.pet_debuffs = { { buff_name = "Deadly Poison", buff_id = 2818, type = 4 } }
    K.clock = K.clock + 0.6             -- the pet's debuffs are read twice a second
    K.tick()
    assert_eq(K.sent("Mend Pet"), 1, "a poison it can clear: healed sooner")
end }

T[#T + 1] = { "pet heal (1.66.0): a channel that turns dangerous gives way -- reactions may cut it, the cast gate opens", function()
    local G = rotation_bundle()
    pet_fight(G, 0.15, -0.05)
    -- Something on the global cooldown that would not outscore a running heal.
    G.known.Gouge = true
    G.React.add_rule({ name = "Test: gouge", category = "utility", priority = 60, needs = { "combat" },
        propose = function(_, offer) offer({ name = "Gouge" }) end })
    G.P.rotation.tick()
    assert_eq(G.sent("Mend Pet"), 1, "the heal went out")
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", G.id_of("Mend Pet") })

    -- The channel shows on the cast bar.
    G.cast_remaining, G.casting_id = 4.0, G.id_of("Mend Pet")
    G.player.is_channelling_spell = function() return true end
    G.player.get_active_channel_spell_id = function() return G.id_of("Mend Pet") end
    G.clock = G.clock + 0.2
    G.P.rotation.tick()
    assert_eq(G.React.yielding(), nil, "a safe channel does not give way")
    assert_eq(G.P.rotation.cast_gate_busy(), true, "and the walk waits for it")
    assert_eq(G.sent("Gouge"), 0, "nor does a lesser reaction talk over it")

    -- The mob turns on you, in melee, and you are at 30% and falling.
    G.row.targeting_pet, G.row.targeting_me, G.row.dist = false, true, 3
    G.health.player, G.hp_rate = 0.30, -0.04
    G.clock = G.clock + 0.2
    G.P.rotation.tick()
    assert(G.React.yielding(), "now it gives way")
    assert(has_line(G.React.log_lines(10), "Mend Pet gives way"), "said so")
    assert_eq(G.P.rotation.cast_gate_busy(), false, "the cast gate opens for the walk and the kite")
    assert_eq(G.sent("Gouge"), 1, "and a reaction may cut it")
end }

T[#T + 1] = { "latch: the exit line is fixed when it turns on, so a moving threshold cannot flap it", function()
    local L = fresh("jambix_aio/modules/react/latch")()
    local l = L.new({ enter = 0.20, exit = 0.45, below = true })
    assert_eq((l.update(0.48, 1, 0.49, 0.74)), true, "on under a high line")
    assert_eq((l.update(0.36, 2, 0.10, 0.35)), true, "the line falls to 10%: still on (exit stays 74%)")
    assert_eq((l.update(0.60, 3, 0.10, 0.35)), true, "60% is still under the exit fixed at entry")
    assert_eq((l.update(0.75, 4, 0.10, 0.35)), false, "off once over it")
    assert_eq((l.update(0.30, 5, 0.10, 0.35)), false, "and a low line does not re-enter at 30%")
end }

-- --- the rotation, changed by the fight ---------------------------------------------------

local function always() return true end

--- The real rotation, with the engine in front, running a profile of our own.
local function adaptive_bundle(rules, power)
    local G = rotation_bundle()
    local cls = G.P.rotation.classes.ROGUE
    cls.power = power or "ENERGY"
    cls.profiles.test.rules = rules
    cls.profiles.test.power = power
    G.player.is_moving = function() return G.moving == true end
    G.P.power = function() return G.power_now or 80 end
    G.P.auto = { cost_fraction = function(name) return G.costs and G.costs[name] end,
                 value = function() return nil end }
    G.P.combat.time_to_die = function() return G.ttd_now or 20 end
    for _, r in ipairs(rules) do G.known[r[1]] = true end
    return G
end

T[#T + 1] = { "adaptive rotation: a pack makes the area spell win; one target makes it lose", function()
    local G = adaptive_bundle({ { "Sinister Strike", always }, { "Arcane Explosion", always } })
    G.P.rotation.tick()
    assert_eq(G.sent("Sinister Strike"), 1, "one target: the single-target spell (area -15)")
    assert_eq(G.sent("Arcane Explosion"), 0, "not the area spell")

    local H = adaptive_bundle({ { "Sinister Strike", always }, { "Arcane Explosion", always } })
    H.count = 4
    H.React.debug_lines()
    H.P.rotation.tick()
    assert_eq(H.sent("Arcane Explosion"), 1, "four engaged: the area spell, though it is second in the list")
    assert_eq(H.sent("Sinister Strike"), 0, "not the single-target one")
    local lines = H.React.debug_lines()
    assert(has_line(lines, "Rotation: Arcane Explosion"), "the readout names the rotation's pick")
    assert(has_line(lines, "4 in reach: hit them all"), "and says why")
end }


T[#T + 1] = { "area spells count where they land: Multi-Shot reaches the mob beside the target, never wakes a sheep, never pulls (1.56.0)", function()
    local function build(second)
        local G = adaptive_bundle({ { "Sinister Strike", always }, { "Multi-Shot", always } })
        local add = unit(G, "add", { name = "Mottled Boar" })
        G.row = G.row_for(G.target, { x = 0, y = 0, z = 0, dist = 25, targeting_me = true })
        local other = G.row_for(add, { x = 3, y = 0, z = 0, dist = 25 })
        for k, v in pairs(second or {}) do other[k] = v end
        G.rows = { G.row, other }
        G.React.debug_lines()
        return G
    end
    local G = build({ targeting_pet = true })
    G.P.rotation.tick()
    assert_eq(G.sent("Multi-Shot"), 1, "two in reach of the target: the area shot wins")
    assert(has_line(G.React.debug_lines(), "2 in reach: hit them all"), "and says why")

    local F = build({ x = 30, targeting_pet = true })
    F.P.rotation.tick()
    assert_eq(F.sent("Multi-Shot"), 0, "the second one is thirty yards off: one in reach")
    assert_eq(F.sent("Sinister Strike"), 1, "the single-target strike instead")

    local S = build({ targeting_pet = true, control = { type = 99, remaining = 20 } })
    S.P.rotation.tick()
    assert_eq(S.sent("Multi-Shot"), 0, "never beside a sheep")

    local I = build({ engaged = false, in_combat = false, activity = "idle" })
    I.P.rotation.tick()
    assert_eq(I.sent("Multi-Shot"), 0, "an idle mob beside the target: it would be pulled")
end }

T[#T + 1] = { "H.spread: the class's area rule counts the plan's reach -- two beside the target is enough (1.56.0)", function()
    local G = adaptive_bundle({ { "Sinister Strike", always } })
    local P = G.P
    P.field.spread_ok = function() return true end
    local H = P.rotation.helpers
    local cls = P.rotation.classes.ROGUE
    table.insert(cls.profiles.test.rules, 1, { "Multi-Shot", function(s) return H.spread(s, 3) end })
    G.known["Multi-Shot"] = true
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = G.row_for(G.target, { x = 0, y = 0, z = 0, dist = 25 })
    G.rows = { G.row, G.row_for(add, { x = 4, y = 0, z = 0, dist = 25, targeting_pet = true }) }
    P.rotation.tick()
    assert_eq(G.sent("Multi-Shot"), 1, "nothing in melee (the old count said no), two beside the target: yes")

    local N = adaptive_bundle({ { "Sinister Strike", always } })
    N.P.field.spread_ok = function() return true end
    local HN = N.P.rotation.helpers
    table.insert(N.P.rotation.classes.ROGUE.profiles.test.rules, 1,
        { "Multi-Shot", function(s) return HN.spread(s, 3) end })
    N.known["Multi-Shot"] = true
    N.row = N.row_for(N.target, { x = 0, y = 0, z = 0, dist = 25 })
    N.rows = { N.row }
    N.P.rotation.tick()
    assert_eq(N.sent("Multi-Shot"), 0, "one mob: the rule says no")
end }


T[#T + 1] = { "range is hitbox to hitbox (1.58.1): a shot is not pressed ten yards from a mob's centre, and is at twelve", function()
    local G = adaptive_bundle({ { "Arcane Shot", always } }, "MANA")
    G.catalog["Arcane Shot"] = { name = "Arcane Shot", range = { min = 8, max = 35 }, roles = { "damage" }, cast = 0 }
    local reach = { [G.player] = 1.5, [G.target] = 1.5 }
    G.P.units.combat_reach = function(u) return reach[u] or 0 end
    G.dist_now = 10
    G.P.units.distance = function() return G.dist_now end
    G.P.rotation.tick()
    assert_eq(G.sent("Arcane Shot"), 0, "ten from the centre is seven from its edge: inside the eight-yard minimum")
    G.dist_now = 12
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert_eq(G.sent("Arcane Shot"), 1, "twelve from the centre, nine from the edge: the shot goes")

    local H = G.P.rotation.helpers
    assert_eq(H.gap(G.target, 10), 7, "the gap is the centre less both combat reaches")
    assert_eq(H.in_melee(G.target, 5), true, "a normal mob: melee to five yards")
    assert_eq(H.in_melee(G.target, 6), false, "and not at six")
    reach[G.target] = 4
    assert(math.abs(H.melee_range(G.target) - (1.5 + 4 + 4 / 3)) < 1e-9, "a big mob: both reaches and a third")
    assert_eq(H.in_melee(G.target, 6.5), true, "6.5 yards from a big mob's centre is melee")
end }

T[#T + 1] = { "adaptive rotation: no cast on the move, and no long cast on something about to die", function()
    local function build()
        local G = adaptive_bundle({ { "Frostbolt", always }, { "Fire Blast", always } }, "MANA")
        G.catalog.Frostbolt = { name = "Frostbolt", cast = 2.5, roles = { "damage" }, range = 30 }
        G.catalog["Fire Blast"] = { name = "Fire Blast", cast = 0, roles = { "damage" }, range = 20 }
        return G
    end
    local G = build()
    G.P.rotation.tick()
    assert_eq(G.sent("Frostbolt"), 1, "standing, a healthy mob: the list's first choice")

    local M = build()
    M.moving = true
    M.P.rotation.tick()
    assert_eq(M.sent("Frostbolt"), 0, "moving: a cast is not a candidate at all")
    assert_eq(M.sent("Fire Blast"), 1, "the instant goes instead")

    local D = build()
    D.ttd_now = 1.5
    D.P.rotation.tick()
    assert_eq(D.sent("Frostbolt"), 0, "it dies in 1.5s: the 2.5s cast is wasted")
    assert_eq(D.sent("Fire Blast"), 1, "the instant finishes it")
end }

T[#T + 1] = { "adaptive rotation: on a low bar the cheap spell beats the dear one, by what each costs", function()
    local G = adaptive_bundle({ { "Greater Heal Bolt", always }, { "Cheap Bolt", always } }, "MANA")
    G.costs = { ["Greater Heal Bolt"] = 0.12, ["Cheap Bolt"] = 0.02 }
    G.P.rotation.tick()
    assert_eq(G.sent("Greater Heal Bolt"), 1, "a full bar: the list's order")

    local H = adaptive_bundle({ { "Greater Heal Bolt", always }, { "Cheap Bolt", always } }, "MANA")
    H.costs = { ["Greater Heal Bolt"] = 0.12, ["Cheap Bolt"] = 0.02 }
    H.power_now = 8
    H.P.rotation.tick()
    assert_eq(H.sent("Cheap Bolt"), 1, "8% mana: the cheap one")
    assert_eq(H.sent("Greater Heal Bolt"), 0, "not the one that costs 12% of the bar")
end }

T[#T + 1] = { "standing still in combat is caught and explained", function()
    local G = adaptive_bundle({ { "Frostbolt", always } }, "MANA")
    G.dispatch = true
    G.catalog.Frostbolt = { name = "Frostbolt", cast = 2.5, roles = { "damage" }, range = 30 }
    G.unready.Frostbolt = true       -- the client will not take it: nothing goes out
    G.P.rotation.tick()
    for _ = 1, 8 do
        G.clock = G.clock + 0.1
        G.P.rotation.tick()
    end
    local log = G.React.log_lines(20)
    assert(has_line(log, "[idle] standing still in combat"), "the idle stretch is reported")
    assert(has_line(log, "Frostbolt"), "naming the rule that did not go out, and why")
    assert(G.React.idle_stats().episodes == 1, "one episode")
    G.unready.Frostbolt = nil
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    assert(has_line(G.React.log_lines(20), "moving again after"), "and its end")
end }

T[#T + 1] = { "idle: Auto Shot firing is not standing still, whatever the auto-attack flag says (1.35.2)", function()
    local G = adaptive_bundle({ { "Frostbolt", always } }, "MANA")
    G.dispatch = true
    G.catalog.Frostbolt = { name = "Frostbolt", cast = 2.5, roles = { "damage" }, range = 30 }
    G.unready.Frostbolt = true       -- nothing the rotation offers goes out
    local shot = G.id_of("Auto Shot")
    for i = 1, 40 do
        G.clock = G.clock + 0.1
        if i % 20 == 1 then G.React.memory.on_success(shot) end   -- a shot every two seconds
        G.P.rotation.tick()
    end
    assert(not has_line(G.React.log_lines(40), "[idle]"),
        "shooting is not idle: " .. table.concat(G.React.log_lines(40), " || "):sub(1, 600))
end }

-- --- what each skill does ---------------------------------------------------------------------

--- An adaptive bundle whose spells have tooltips, and a target with a health pool.
local function damage_bundle(rules, tooltips, power)
    local G = adaptive_bundle(rules, power)
    G.tooltips = tooltips
    _G.core.spell_book.get_spell_description = function(id) return G.tooltips[G.names[id]] or "" end
    G.P.units.health = function(u) return G.hp_abs and G.hp_abs[u.guid] or 5000 end
    return G
end

T[#T + 1] = { "damage: tooltips are read for what a spell should do", function()
    local G = damage_bundle({ { "Shadow Bolt", always } }, {})
    local D = G.React.damage
    local hit = D.parse("Sends a shadowy bolt at the enemy, causing 13 to 18 Shadow damage.")
    assert_eq(hit.direct, 15.5, "a range is its middle")
    local dot = D.parse("Corrupts the target, causing 40 Shadow damage over 12 sec.")
    assert_eq(dot.dot, 40, "damage over time")
    assert_eq(dot.duration, 12, "and its duration")
    local flat = D.parse("An instant shot that causes 15 Arcane damage.")
    assert_eq(flat.direct, 15, "a flat hit")
    assert_eq(D.parse("Increases ranged attack power by 20."), nil, "no damage, no reading")
end }

T[#T + 1] = { "damage: what a skill really deals is measured from the combat log, per cast", function()
    local G = damage_bundle({ { "Arcane Shot", always } }, { ["Arcane Shot"] = "causes 15 Arcane damage." })
    local id = G.id_of("Arcane Shot")
    local function cast(amounts)
        G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", id })
        for _, amount in ipairs(amounts) do
            G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
                { 0, "SPELL_DAMAGE", false, "player", "Me", 0, 0, "mob", "Mob", 0, 0, 0, "Arcane Shot", 64, amount })
        end
        G.clock = G.clock + 3.5
        G.React.damage.tick()
    end
    assert_eq(select(2, G.React.damage.expected("Arcane Shot", 20)), "tooltip", "before any cast: the tooltip")
    cast({ 100 })
    cast({ 140 })
    local value, source = G.React.damage.expected("Arcane Shot", 20)
    assert_eq(source, "measured", "after two casts: measured")
    assert(value > 100 and value < 140, "the average of what it really did (" .. tostring(value) .. ")")
    -- Someone else's damage is not ours.
    G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", id })
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SPELL_DAMAGE", false, "other", "Them", 0, 0, "mob", "Mob", 0, 0, 0, "Arcane Shot", 64, 9999 })
    G.clock = G.clock + 3.5
    G.React.damage.tick()
    assert(G.React.damage.expected("Arcane Shot", 20) < 200, "another hunter's Arcane Shot is not counted")
end }

T[#T + 1] = { "weighing: the skill that does more per second wins, wherever it sits in the list", function()
    local G = damage_bundle({ { "Weak Bolt", always }, { "Strong Bolt", always } },
        { ["Weak Bolt"] = "causing 30 Fire damage.", ["Strong Bolt"] = "causing 90 Fire damage." })
    G.React.debug_lines()
    G.P.rotation.tick()
    assert_eq(G.sent("Strong Bolt"), 1, "three times the damage: it goes first though it is listed second")
    local lines = G.React.debug_lines()
    assert(has_line(lines, "Rotation: Strong Bolt"), "the readout names it")

    local H = damage_bundle({ { "Slow Nuke", always }, { "Quick Shot", always } },
        { ["Slow Nuke"] = "causing 240 Fire damage.", ["Quick Shot"] = "causing 150 Fire damage." })
    H.catalog["Slow Nuke"] = { name = "Slow Nuke", cast = 3, roles = { "damage" }, range = 30 }
    H.P.rotation.tick()
    assert_eq(H.sent("Quick Shot"), 1, "240 over a 3s cast is 80/s; 150 in a 1.5s global cooldown is 100/s")
end }

T[#T + 1] = { "weighing: a DoT is worth only the ticks it lives for; an area skill counts its targets", function()
    local G = damage_bundle({ { "Long Dot", always, dot = true }, { "Hit", always } },
        { ["Long Dot"] = "causing 300 Shadow damage over 15 sec.", ["Hit"] = "causing 100 Shadow damage." })
    G.P.rotation.tick()
    assert_eq(G.sent("Long Dot"), 1, "a long fight: 300 over the target's life beats 100")
    local D = damage_bundle({ { "Long Dot", always, dot = true }, { "Hit", always } },
        { ["Long Dot"] = "causing 300 Shadow damage over 15 sec.", ["Hit"] = "causing 100 Shadow damage." })
    D.ttd_now = 3
    D.P.rotation.tick()
    assert_eq(D.sent("Hit"), 1, "three seconds to live: the DoT is worth 60, the hit 100")

    local A = damage_bundle({ { "Sinister Strike", always }, { "Arcane Explosion", always } },
        { ["Sinister Strike"] = "causing 100 damage.", ["Arcane Explosion"] = "causing 60 Arcane damage." })
    A.count = 2
    A.P.rotation.tick()
    assert_eq(A.sent("Arcane Explosion"), 1, "two targets: 60 twice beats 100 once")
end }

T[#T + 1] = { "weighing: the killing blow goes to the quickest, cheapest skill that finishes it", function()
    local G = damage_bundle({ { "Big Nuke", always }, { "Cheap Shot", always } },
        { ["Big Nuke"] = "causing 500 Fire damage.", ["Cheap Shot"] = "causing 120 Fire damage." })
    G.catalog["Big Nuke"] = { name = "Big Nuke", cast = 3, roles = { "damage" }, range = 30 }
    G.hp_abs = { mob = 100 }
    G.React.debug_lines()
    G.P.rotation.tick()
    assert_eq(G.sent("Cheap Shot"), 1, "100 health left: the instant kills it, the three-second nuke is overkill")
    assert(has_line(G.React.debug_lines(), "kills it: 100 health left"), "and the readout says so")
end }

T[#T + 1] = { "triggers: a window that only opens for a moment, and procs that change the pick", function()
    local G = damage_bundle({ { "Mortal Strike", always }, { "Overpower", always } },
        { ["Mortal Strike"] = "causing 100 damage.", ["Overpower"] = "causing 80 damage." })
    G.P.rotation.tick()
    assert_eq(G.sent("Overpower"), 1, "the dodge window: 80 now beats 100 that will still be there")

    local C = damage_bundle({ { "Frostbolt", always }, { "Fireball", always } },
        { ["Frostbolt"] = "causing 100 Frost damage.", ["Fireball"] = "causing 100 Fire damage." }, "MANA")
    C.costs = { Frostbolt = 0.03, Fireball = 0.10 }
    C.auras.player = { [1] = { buff_name = "Clearcasting" } }
    C.P.rotation.tick()
    assert_eq(C.sent("Fireball"), 1, "Clearcasting: the dearer spell is free, so it gains most")

    local S = damage_bundle({ { "Corruption", always, dot = true }, { "Shadow Bolt", always } },
        { ["Corruption"] = "causing 40 Shadow damage over 12 sec.", ["Shadow Bolt"] = "causing 13 to 18 Shadow damage." },
        "MANA")
    S.catalog["Shadow Bolt"] = { name = "Shadow Bolt", cast = 3, roles = { "damage" }, range = 30 }
    S.moving = true
    S.auras.player = { [1] = { buff_name = "Shadow Trance" } }
    S.P.rotation.tick()
    assert_eq(S.sent("Shadow Bolt"), 1, "Shadow Trance: the Shadow Bolt is instant, so it goes even on the move")
end }

-- --- a real class, end to end ----------------------------------------------------------------
--
-- The hunter's own rules, the hunter's own catalogue, the real rotation and the
-- real engine, against a client that has a global cooldown, a cast bar,
-- debuffs that land, cooldowns, and a pet holding the mob.

local function hunter_fight()
    local G = bundle()
    local P = G.P
    for _, m in ipairs({ "jambix_aio/modules/rotation", "jambix_aio/modules/catalog/init",
                         "jambix_aio/modules/catalog/hunter", "jambix_aio/modules/classes/hunter" }) do
        package.loaded[m] = nil
    end

    G.dispatch = true
    G.gcd_until, G.cast_until, G.auto_on = 0, 0, false
    G.cd, G.target_auras, G.order = {}, {}, {}
    _G.core.spell_book.is_current_spell = function() return false end

    local pl, mob = G.player, G.target
    pl.get_class = function() return 3 end
    pl.is_moving = function() return G.moving == true end
    pl.is_mounted = function() return false end
    pl.is_auto_attacking = function() return G.auto_on end
    pl.get_attack_speed = function() return 2.8 end
    pl.get_unit_ranged_damage = function() return { speed = 2.8 } end
    pl.get_item_at_inventory_slot = function() return nil end
    mob.get_target = function() return G.pet end
    mob.is_casting_spell = function() return false end
    mob.get_creature_type = function() return 1 end
    mob.get_max_power = function() return 0 end
    mob.is_moving = function() return false end

    -- The client: a global cooldown, cooldowns, a cast bar.
    local OFF_GCD = { ["Auto Shot"] = true }
    local function ready(name)
        if not G.known[name] then return false end
        if not OFF_GCD[name] and G.clock < G.gcd_until then return false end
        return G.clock >= (G.cd[name] or 0)
    end
    P.spellbook.ready = ready
    P.spellbook.castable = function(name) return ready(name) end
    P.ctx.spells.ready = function() return true end
    P.ctx.spells.gcd = function() return math.max(0, G.gcd_until - G.clock) end
    P.ctx.spells.cooldown = function() return 0 end
    P.ctx.spells.usable = function() return true end
    P.ctx.spells.info = function() return { cast_time = 0 } end
    P.ctx.tick, P.ctx.every = function() end, function() end
    P.combat.cast_remaining = function() return math.max(0, G.cast_until - G.clock) end
    P.combat.in_combat = function() return true end
    P.combat.target = function() return mob end
    P.combat.time_to_die = function() return 25 end

    local function aura_left(u, ids)
        if u ~= mob or type(ids) ~= "table" then return 0 end
        for i = 1, #ids do
            local until_at = G.target_auras[ids[i]]
            if until_at and until_at > G.clock then return until_at - G.clock end
        end
        return 0
    end
    P.units.distance = function() return 25 end
    P.units.has_aura = function(u, ids) return aura_left(u, ids) > 0 end
    P.units.aura_remaining = aura_left
    P.units.aura_stacks = function(u, ids) return aura_left(u, ids) > 0 and 1 or 0 end
    P.units.lowest_health_ally = function() return nil end
    P.units.health = function() return 3000 end

    P.power = function() return 80 end
    P.power_max = function() return 100 end
    P.rotation_active = function() return true end
    G.settings.rot_enabled = true
    P.targeting.aoe_count = function() return 1 end
    P.targeting.best_cluster = function() return 1, nil end
    P.targeting.loose = function() return 0 end
    P.targeting.better_target = function() return nil end
    P.targeting.may_control_pull = function() return true end
    P.targeting.SOLO = "solo"
    P.field.by_weakest = function() return { mob } end
    P.field.in_trouble = function() return false end
    P.field.plan = function() return G.plan end
    P.resources.fight_left = function() return 25 end
    P.resources.state = { posture = "HEALTHY" }
    P.talents = { rank = function() return 0 end, points = function() return 0, 0, 0 end }
    P.auto = { cost_fraction = function() return 0.05 end, value = function() return nil end }
    P.kite = { active = function() return false end, wants_slow = function() return false end }
    P.weave = { last_shot_at = function() return 0 end }
    P.pet.alive = function() return true end
    P.pet.health = function() return 1 end
    P.pet.sent_for = function() return 10 end
    G.pet_alive, G.pet_target = true, mob

    G.row = { obj = mob, guid = "mob", dist = 25, engaged = true, targeting_pet = true,
              targeting_me = false, closing = 0, activity = "attacking" }
    G.rows = { G.row }
    P.ctx.enemies = {
        all = function() return G.rows end,
        count = function() return #G.rows end,
        get = function(u) return u == mob and G.row or nil end,
        first_arrival = function() return nil, math.huge end,
        next_cast = function() return nil, nil end,
    }

    for _, name in ipairs({ "Hunter's Mark", "Auto Shot", "Serpent Sting", "Arcane Shot", "Aimed Shot",
                            "Concussive Shot", "Wing Clip", "Raptor Strike", "Mend Pet", "Aspect of the Hawk" }) do
        G.known[name] = true
    end

    P.catalog = require("jambix_aio/modules/catalog/init")(P)
    P.rotation = require("jambix_aio/modules/rotation")(P)
    P.react = G.React
    local CS = {
        prefix = "rot_hunter_",
        opt = function(id, d) return P.opt("rot_hunter_" .. id, d) end,
        pct = function(id, d) return P.optpct("rot_hunter_" .. id, d) end,
        tune = function(id, d) return P.tune("rot_hunter_" .. id, d) end,
        tune_secs = function(id, d) return P.tune_secs("rot_hunter_" .. id, d) end,
    }
    P.rotation.classes.HUNTER = require("jambix_aio/modules/classes/hunter")(P, P.rotation.helpers, CS)

    -- What the client does with a press: the global cooldown, a cast bar for
    -- Aimed Shot, cooldowns, the debuff on the mob, and the confirmation.
    local send = P.ctx.cast
    P.ctx.cast = function(req)
        local name = G.names[req.spell_id]
        if name ~= "Auto Shot" and not req.fast and G.clock < G.gcd_until then return end
        send(req)
        G.order[#G.order + 1] = name
        if name == "Auto Shot" then
            G.auto_on = true
        elseif not req.fast then
            G.gcd_until = G.clock + 1.5
        end
        if name == "Aimed Shot" then G.cast_until, G.cd[name] = G.clock + 3, G.clock + 9 end
        if name == "Arcane Shot" then G.cd[name] = G.clock + 6 end
        if name == "Hunter's Mark" or name == "Serpent Sting" then
            G.target_auras[req.spell_id] = G.clock + 15
        end
        G.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "g", req.spell_id })
    end

    function G.fight(seconds)
        for _ = 1, math.floor(seconds * 10 + 0.5) do
            G.clock = G.clock + 0.1
            P.rotation.tick()
        end
    end
    return G
end

T[#T + 1] = { "a real hunter, end to end: mark, Auto Shot, the opener, the sting, the fillers -- and never idle", function()
    local G = hunter_fight()
    G.settings.react_overlay = true          -- the panel is open, as in the game
    G.fight(12)

    local seen = {}
    for i = 1, #G.order do seen[G.order[i]] = (seen[G.order[i]] or 0) + 1 end
    assert(seen["Hunter's Mark"] == 1, "the mark, once (" .. table.concat(G.order, ", ") .. ")")
    assert(seen["Auto Shot"] and seen["Auto Shot"] >= 1, "Auto Shot started")
    assert(seen["Aimed Shot"] and seen["Aimed Shot"] >= 1, "the Aimed Shot opener")
    assert(seen["Serpent Sting"] == 1, "the sting, once while it is up")
    assert(seen["Arcane Shot"] and seen["Arcane Shot"] >= 1, "Arcane Shot as a filler")
    local gcd_presses = 0
    for name, n in pairs(seen) do if name ~= "Auto Shot" then gcd_presses = gcd_presses + n end end
    assert(gcd_presses >= 5, "something on nearly every global cooldown for 12s (" .. gcd_presses .. ")")
    assert(not has_line(G.React.log_lines(40), "[idle]"), "never reported standing still: " .. table.concat(G.React.log_lines(40), " || "):sub(1, 900))

    -- The panel says what the rotation is doing, not "nothing to press".
    local panel = table.concat(G.React.overlay_lines(), " / ")
    assert(not panel:find("nothing to press", 1, true), "no 'nothing to press' while it works: " .. panel)
    assert(panel:find("Rotation: ", 1, true) and (panel:find("pressed ", 1, true) or panel:find("last ", 1, true)
        or panel:find("casting", 1, true)), "it names the last press or the cast: " .. panel)
end }

T[#T + 1] = { "the panel says when the rotation is off or paused, instead of a frozen last frame", function()
    local G = hunter_fight()
    G.settings.react_overlay = true
    G.fight(1)
    G.settings.rot_enabled = false
    G.clock = G.clock + 3
    local panel = table.concat(G.React.overlay_lines(), " / ")
    assert(panel:find("OFF", 1, true), "switched off: it says so (" .. panel .. ")")
    G.settings.rot_enabled = true
    G.P.rotation_active = function() return false end
    panel = table.concat(G.React.overlay_lines(), " / ")
    assert(panel:find("paused", 1, true), "key off: it says so (" .. panel .. ")")
end }

T[#T + 1] = { "a pull we opened stays ours: a marked mob that has not noticed us is not 'holding fire'", function()
    local G = rotation_bundle()
    G.dispatch = true
    G.P.combat.in_combat = function() return false end
    G.row, G.rows = nil, {}
    assert_eq(G.P.rotation.may_engage_unit(G.target), false, "a mob we have not touched is not ours yet")
    -- We mark it (a Classic mark does not put it in combat with us).
    G.known["Hunter's Mark"] = true
    G.P.ctx.cast({ spell_id = G.id_of("Hunter's Mark"), target = G.target, reason = "Hunter's Mark" })
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "we started it: the shots follow the mark")
    G.clock = G.clock + 25
    assert_eq(G.P.rotation.may_engage_unit(G.target), false, "but not for ever")
end }

-- 1.75.0, the user: "i shouldnt be just auto initiating fights either. Should
-- be when I go into Attack mode". A hunter's opener used to pull whatever
-- auto-targeting selected in shot range with Start fights off.
T[#T + 1] = { "nothing pulls by itself (1.75.0): a class's opener only with Start fights on; your attack, a mob on you, the key do", function()
    local G = rotation_bundle()
    G.P.combat.in_combat = function() return false end
    G.row, G.rows = nil, {}
    local says, attacking = true, false
    G.P.rotation.classes.ROGUE.may_open = function()
        if says then return true end
        return false, "target is a player"
    end
    G.player.is_auto_attacking = function() return attacking end
    local may = G.P.rotation.may_engage_unit
    assert_eq(may(G.target), false, "Start fights off: a selected mob the opener likes is not pulled")
    attacking = true
    assert_eq(may(G.target), true, "you attacked it (Attack, a right-click): the rotation takes over")
    attacking = false
    G.armed.rot_engage_key = true
    assert_eq(may(G.target), true, "the engage key forces it")
    G.armed.rot_engage_key = nil
    G.settings.rot_open_combat = true
    assert_eq(may(G.target), true, "Start fights on: the class's opener decides")
    says = false
    assert_eq(may(G.target), false, "and when it says no (a player), nothing")
    G.P.rotation.classes.ROGUE.may_open = nil
    assert_eq(may(G.target), true, "a class with no opener: the switch opens on any selected mob")
    G.settings.rot_open_combat = false
    G.row = G.row_for(G.target, { targeting_me = true })
    G.rows = { G.row }
    assert_eq(may(G.target), true, "a mob that comes for you is a fight")
end }

T[#T + 1] = { "loot first (1.57.1): no new pull while auto-loot works a corpse; the key and a mob on us still fight", function()
    local G = rotation_bundle()
    G.P.combat.in_combat = function() return false end
    G.row, G.rows = nil, {}
    local looting = true
    G.P.world = { looting = function() return looting end }
    G.settings.rot_open_combat = true
    assert_eq(G.P.rotation.may_engage_unit(G.target), false, "the start-fights switch waits for the corpse")
    looting = false
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "and opens once it is looted")
    -- The class's own opener (a hunter's: in shot range), under the switch (1.75.0).
    G.P.rotation.classes.ROGUE.may_open = function() return true end
    looting = true
    assert_eq(G.P.rotation.may_engage_unit(G.target), false, "the class's opener waits too")
    looting = false
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "and opens once it is looted")
    G.settings.rot_open_combat = false
    looting = true
    G.row = G.row_for(G.target, { targeting_me = true })
    G.rows = { G.row }
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "a mob coming for us is a fight anyway")
    G.row, G.rows = nil, {}
    G.armed.rot_engage_key = true
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "the engage key still pulls")
    G.armed.rot_engage_key = nil
    G.settings.rot_open_combat = true
    G.P.world = { looting = function() error("broke") end }
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "a world module that raises holds nothing")
    G.P.world = nil
    assert_eq(G.P.rotation.may_engage_unit(G.target), true, "no world module: as before")
end }

T[#T + 1] = { "rotation: if the engine itself fails, the old fixed sequence still interrupts that tick", function()
    local G = rotation_bundle()
    G.P.react = { tick = function() error("engine broke") end, gate = function() return nil end,
                  active = function() return true end, after_rotation = function() end }
    G.row = G.row_for(G.target, { casting = G.casting("Greater Heal", 1.0, 3.0) })
    G.rows = { G.row }
    G.P.rotation.tick()
    local n, request = G.sent("Kick")
    assert_eq(n, 1, "kicked by the legacy path")
    assert_eq(request.reason, "interrupt with Kick", "the legacy reason, not the engine's")
end }

-- --- the pet is the tank (1.36.0) -------------------------------------------------------------

--- Counts the specials (anything but the mark, Auto Shot and the aspect) in a fight's press order.
local function specials(order, from)
    local n = 0
    for i = from or 1, #order do
        local name = order[i]
        if name == "Serpent Sting" or name == "Arcane Shot" or name == "Aimed Shot" then n = n + 1 end
    end
    return n
end

T[#T + 1] = { "pet tank: the specials wait for the pet to settle the mob; Auto Shot does not", function()
    local G = hunter_fight()
    -- No mark and no aspect to take the first global cooldown: only the
    -- pet's settling stands between the pull and the first special.
    G.known["Hunter's Mark"], G.known["Aspect of the Hawk"] = nil, nil
    G.fight(1.2)
    assert_eq(specials(G.order), 0, "no sting, Arcane or Aimed Shot in the pet's first second: "
        .. table.concat(G.order, ", "))
    assert_eq(G.auto_on, true, "Auto Shot is on")
    G.fight(3)
    assert(specials(G.order) >= 1, "once the pet has held it a moment, the specials go: " .. table.concat(G.order, ", "))
end }

T[#T + 1] = { "pet tank: at 85% threat the specials hold until it is back under 70; Auto Shot keeps going", function()
    local G = hunter_fight()
    G.fight(4)
    assert(specials(G.order) >= 1, "specials going: " .. table.concat(G.order, ", "))

    G.threat_pct = 90
    local from = #G.order + 1
    G.fight(6)
    assert_eq(specials(G.order, from), 0, "90%: nothing but Auto Shot: " .. table.concat(G.order, ", ", from))
    assert_eq(G.auto_on, true, "Auto Shot never waits")
    assert(has_line(G.React.log_lines(40), "pet_threat ON"), "the state is logged")
    local why = G.P.rotation.explain("Arcane Shot")
    assert(why:find("the fight: 90% threat: the pet keeps it", 1, true), "and the held special says why: " .. why)

    G.threat_pct = 75
    from = #G.order + 1
    G.fight(2)
    assert_eq(specials(G.order, from), 0, "75%: still over the line it leaves by")

    G.threat_pct = 50
    from = #G.order + 1
    G.fight(7)
    assert(specials(G.order, from) >= 1, "50%: the specials are back: " .. table.concat(G.order, ", ", from))
end }

T[#T + 1] = { "pet tank: a special that would push our threat over the line waits; a small one does not", function()
    local G = bundle()
    G.pet_alive, G.pet_target = true, G.target
    G.row = G.row_for(G.target, { targeting_pet = true })
    G.rows = { G.row }
    G.threat_pct = 60
    G.run(2.0)
    local W = G.React.world.W
    assert_eq(W.pet.tanking, true, "solo, the mob on the pet: the pet is the tank")
    assert(W.pet.held_for >= 1.5, "and has held it a while: " .. tostring(W.pet.held_for))

    local D = G.React.damage
    D.dealt = function() return 100 end
    D.expected = function() return 60 end
    local rule, row = { "Arcane Shot" }, { roles = { "damage" }, cast = 0 }
    local _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse and refuse:find("the pet would lose it", 1, true), "60% now, 96% after: it waits: " .. tostring(refuse))

    D.expected = function() return 20 end
    _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert_eq(refuse, nil, "72% after: it goes")

    -- In a group the tank is a player, and this is not the pet's business.
    D.expected = function() return 60 end
    G.group.in_group = true
    G.run(0.1)
    _, _, refuse = G.React.adapt(rule, row, G.React.world.W.s, { target = G.React.world.W.s.target })
    assert(refuse == nil or not refuse:find("pet", 1, true), "in a group the pet guard is off: " .. tostring(refuse))
end }

T[#T + 1] = { "pet tank: a mob that leaves the pet for us gets Disengage, never the pet's Cower, and the log says so", function()
    local G = bundle()
    G.dispatch = true
    G.pet_alive, G.pet_target = true, G.target
    G.row = G.row_for(G.target, { targeting_pet = true, dist = 3 })
    G.rows = { G.row }
    G.threat_pct = 40
    G.known.Disengage, G.known.Cower = true, true
    G.enemy_spells = { Disengage = true, Cower = true }
    G.roles.threat_drop = { { name = "Cower" }, { name = "Disengage" } }
    G.run(2.0)
    assert_eq(G.sent("Disengage"), 0, "on the pet: nothing to shed")

    G.row.targeting_pet, G.row.targeting_me = false, true
    G.threat_pct = 112
    G.run(0.3)
    assert_eq(G.sent("Disengage"), 1, "it left the pet: Disengage")
    assert_eq(G.sent("Cower"), 0, "not the pet's Cower")
    local log = G.React.log_lines(40)
    assert(has_line(log, "left the pet for you: your threat 112%, the pet had it 1.9s"),
        "the moment is logged with the threat: " .. table.concat(log, " || "):sub(1, 800))
end }

T[#T + 1] = { "damage dealt: every hit of ours on a mob is counted, swings included; nobody else's", function()
    local G = bundle()
    local D = G.React.damage
    local function cleu(sub, src, dst, a12, a13, a15)
        G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
            { 0, sub, false, src, "x", 0, 0, dst, "y", 0, 0, a12, a13, 1, a15 })
    end
    cleu("SWING_DAMAGE", "player", "mob", 25)
    cleu("RANGE_DAMAGE", "player", "mob", 75, "Auto Shot", 40)
    cleu("SPELL_PERIODIC_DAMAGE", "player", "mob", 13549, "Serpent Sting", 12)
    cleu("SPELL_DAMAGE", "pet", "mob", 900, "Claw", 30)
    cleu("SPELL_DAMAGE", "player", "mob2", 14281, "Arcane Shot", 70)
    assert_eq(D.dealt("mob"), 77, "25 + 40 + 12, and not the pet's 30")
    assert_eq(D.dealt("mob2"), 70, "per mob")
    D.reset_dealt()
    assert_eq(D.dealt("mob"), 0, "a new fight starts at nothing")
end }

T[#T + 1] = { "just stopped moving: a channel waits a moment, Auto Shot and the instants do not", function()
    local G = hunter_fight()
    G.moving = true
    G.fight(0.3)
    G.moving = false
    G.clock = G.clock + 0.1
    G.P.rotation.tick()
    local s = G.React.world.W.s
    assert_eq(G.P.rotation.press_blocked("Mend Pet", s, G.pet), "catalogue: just stopped moving",
        "Mend Pet the frame after stopping")
    local why = G.P.rotation.press_blocked("Auto Shot", s, G.target)
    assert(why == nil or not why:find("just stopped", 1, true), "Auto Shot is armed at once: " .. tostring(why))
    G.fight(0.3)
    why = G.P.rotation.press_blocked("Mend Pet", G.React.world.W.s, G.pet)
    assert(why == nil or not why:find("moving", 1, true), "a moment later it goes: " .. tostring(why))
end }

T[#T + 1] = { "minimum range: a mob running in needs more room than one standing at the same distance", function()
    local G = hunter_fight()
    G.dist = 9
    G.P.units.distance = function() return G.dist end
    G.row.dist, G.row.closing, G.row.targeting_me, G.row.targeting_pet = 9, 6, true, false
    G.fight(0.2)
    local why = G.P.rotation.press_blocked("Concussive Shot", G.React.world.W.s, G.target)
    assert(why and why:find("while it closes", 1, true), "9y and closing at 6y/s: too close by the time it lands: " .. tostring(why))
    G.row.closing = 0
    G.fight(0.2)
    why = G.P.rotation.press_blocked("Concussive Shot", G.React.world.W.s, G.target)
    assert(why == nil or not why:find("minimum range", 1, true), "9y and standing: fine: " .. tostring(why))
end }

-- --- what the fights taught (1.37.0) -----------------------------------------------------------

--- Fires one combat-log line from us.
local function cleu(G, sub, dst, dst_name, a12, a13, a15, src)
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, sub, false, src or "player", "Me", 0, 0, dst, dst_name, 0, 0, a12, a13, 1, a15 })
end

T[#T + 1] = { "learn: one immune answer holds that spell on that mob; a second mob of the name learns it", function()
    local G = bundle()
    local Lr = G.React.learn
    local b = unit(G, "mob2", { name = "Defias Pillager" })
    cleu(G, "SPELL_MISSED", "mob", "Defias Pillager", 5116, "Concussive Shot", "IMMUNE")
    local why = Lr.blocks("Concussive Shot", G.target)
    assert(why and why:find("immune to it", 1, true), "held on that mob: " .. tostring(why))
    assert_eq(Lr.blocks("Concussive Shot", b), nil, "one answer is not the whole name yet")
    assert_eq(Lr.blocks("Arcane Shot", G.target), nil, "only that spell")

    cleu(G, "SPELL_MISSED", "mob2", "Defias Pillager", 5116, "Concussive Shot", "IMMUNE")
    why = Lr.blocks("Concussive Shot", b)
    assert(why and why:find("learned: Defias Pillager is immune to it", 1, true), "two mobs: learned: " .. tostring(why))
    G.tick()
    assert(has_line(G.React.log_lines(10), "[learn] Defias Pillager is immune to Concussive Shot"), "and said once")

    -- A hit from it on the name says otherwise.
    cleu(G, "SPELL_DAMAGE", "mob3", "Defias Pillager", 5116, "Concussive Shot", 12)
    G.React.learn.combat_end()
    assert_eq(Lr.blocks("Concussive Shot", b), nil, "it took the spell after all: unlearned")
end }

T[#T + 1] = { "learn: immune to two spells at once is a bubble on one mob, not what the name is", function()
    local G = bundle()
    local Lr = G.React.learn
    local b = unit(G, "mob2", { name = "Defias Pillager" })
    cleu(G, "SPELL_MISSED", "mob", "Defias Pillager", 1, "Arcane Shot", "IMMUNE")
    G.clock = G.clock + 1
    cleu(G, "SPELL_MISSED", "mob", "Defias Pillager", 2, "Serpent Sting", "IMMUNE")
    cleu(G, "SPELL_MISSED", "mob2", "Defias Pillager", 1, "Arcane Shot", "IMMUNE")
    assert_eq(Lr.blocks("Arcane Shot", unit(G, "mob4", { name = "Defias Pillager" })), nil,
        "the bubble's answers taught nothing about the name")
    assert(Lr.blocks("Serpent Sting", G.target), "the bubbled mob itself is held a moment")
end }

T[#T + 1] = { "learn: an evading mob takes nothing; it is held a few seconds after the last miss", function()
    local G = bundle()
    cleu(G, "SWING_MISSED", "mob", "Defias Pillager", "EVADE")
    local why = G.React.learn.blocks("Arcane Shot", G.target)
    assert(why and why:find("evading", 1, true), "evading: " .. tostring(why))
    G.tick()
    assert_eq(G.React.world.W.target.evading, true, "the world knows")
    G.clock = G.clock + 5
    assert_eq(G.React.learn.blocks("Arcane Shot", G.target), nil, "and lets go")
end }

T[#T + 1] = { "learn: 'Target too close' at a steady reading moves that mob's dead zone out; a closing one is not read", function()
    local G = bundle()
    G.dispatch = true
    G.known["Concussive Shot"] = true
    G.P.units.distance = function() return G.dist or 8.6 end
    G.P.rotation.range_of = function() return 8, 35 end
    G.P.ctx.enemies = { get = function() return { closing = G.closing or 0 } end }
    local function press_and_refuse(text_id)
        G.P.ctx.cast({ spell_id = G.id_of("Concussive Shot"), target = G.target, reason = "Concussive Shot" })
        G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Target too close", text_id })
    end
    G.closing = 6
    press_and_refuse("SPELL_FAILED_TOO_CLOSE")
    local min = G.React.learn.range("Concussive Shot", G.target, 8, 35)
    assert_eq(min, 8, "a mob running in moves its own reading: nothing learned")

    G.closing, G.clock = 0, G.clock + 1
    press_and_refuse("SPELL_FAILED_TOO_CLOSE")
    min = G.React.learn.range("Concussive Shot", G.target, 8, 35)
    assert(math.abs(min - 9.1) < 0.01, "too close at 8.6: the edge is 9.1 on this mob: " .. tostring(min))
    G.tick()
    assert(has_line(G.React.log_lines(10), "its dead zone reaches 9.1y"), "and said")

    G.dist, G.clock = 13, G.clock + 1
    press_and_refuse("SPELL_FAILED_TOO_CLOSE")
    min = G.React.learn.range("Concussive Shot", G.target, 8, 35)
    assert(min <= 11, "never more than three yards past the catalogue: " .. tostring(min))
end }

T[#T + 1] = { "learn: the rotation stops pressing what the mob is immune to, and says why", function()
    local G = hunter_fight()
    cleu(G, "SPELL_MISSED", "mob", G.target.name, 1, "Serpent Sting", "IMMUNE")
    cleu(G, "SPELL_MISSED", "mob9", G.target.name, 1, "Serpent Sting", "IMMUNE")
    G.fight(10)
    for i = 1, #G.order do
        assert(G.order[i] ~= "Serpent Sting", "never pressed: " .. table.concat(G.order, ", "))
    end
    local why = G.P.rotation.press_blocked("Serpent Sting", G.React.world.W.s, G.target)
    assert(why and why:find("immune", 1, true), "the reason: " .. tostring(why))
    assert(#G.order > 0, "and the rest of the rotation went on: " .. table.concat(G.order, ", "))
end }

T[#T + 1] = { "keep the mana: a mob being finished anyway gets no special; one on us, or a full bar, does", function()
    local G = bundle()
    G.P.auto = { cost_fraction = function() return 0.04 end, value = function() return nil end }
    G.pet_alive, G.pet_target = true, G.target
    G.row = G.row_for(G.target, { targeting_pet = true })
    G.rows = { G.row }
    G.power = 40
    G.class.power = "MANA"
    G.run(2.0)
    local W = G.React.world.W
    W.s.ttd = 1.4
    local rule, row = { "Arcane Shot" }, { roles = { "damage" }, cast = 0 }
    local _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse and refuse:find("keep the mana", 1, true), "1.4s left, the pet on it, 40% mana: " .. tostring(refuse))

    W.player.power_pct = 0.95
    _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse == nil or not refuse:find("keep the mana", 1, true), "a full bar spends: " .. tostring(refuse))

    W.player.power_pct = 0.4
    W.target.targets_me = true
    _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse == nil or not refuse:find("keep the mana", 1, true), "on us: quicker is safer: " .. tostring(refuse))
end }

-- --- runners and the evading mob (1.38.0) ------------------------------------------------------

T[#T + 1] = { "learn: a mob seen running low says the name runs; two that died where they stood say it does not", function()
    local G = bundle()
    local Lr = G.React.learn
    local a = unit(G, "r1", { name = "Kolkar Bloodcharger" })
    Lr.observe({ { obj = a, guid = "r1", engaged = true, hp = 0.6, activity = "attacking" } }, 1)
    assert_eq(Lr.runs("Kolkar Bloodcharger"), nil, "nothing seen yet")
    Lr.observe({ { obj = a, guid = "r1", engaged = true, hp = 0.18, activity = "fleeing" } }, 1)
    assert_eq(Lr.runs("Kolkar Bloodcharger"), true, "seen running low")
    G.tick()
    assert(has_line(G.React.log_lines(10), "[learn] Kolkar Bloodcharger runs when it is low"), "said once")

    for i = 1, 2 do
        local b = unit(G, "s" .. i, { name = "Oasis Snapjaw" })
        Lr.observe({ { obj = b, guid = "s" .. i, engaged = true, hp = 0.08, activity = "attacking" } }, 1)
        G.clock = G.clock + 4
        Lr.observe({}, 0)
    end
    assert_eq(Lr.runs("Oasis Snapjaw"), false, "two died under 15% without running")
end }

T[#T + 1] = { "keep the slow for the run: Concussive Shot waits on a humanoid that runs before it is back", function()
    local G = bundle()
    G.target.get_creature_type = function() return 7 end
    G.health.mob = 0.35
    G.run(0.3)
    local W = G.React.world.W
    assert_eq(W.target.runs, true, "a humanoid: presumed to run")
    W.s.ttd = 6
    local rule, row = { "Concussive Shot" }, { roles = { "slow", "debuff" }, cooldown = 12, cast = 0 }
    local _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse and refuse:find("saving it", 1, true), "runs in ~3s, back in 12s: kept: " .. tostring(refuse))

    G.row = G.row_for(G.target, { activity = "fleeing" })
    G.rows = { G.row }
    G.run(0.1)
    W = G.React.world.W
    W.s.ttd = 6
    _, _, refuse = G.React.adapt(rule, row, W.s, { target = W.s.target })
    assert(refuse == nil or not refuse:find("saving", 1, true), "it is running: now is the time: " .. tostring(refuse))

    -- A beast is not presumed to run.
    local B = bundle()
    B.target.get_creature_type = function() return 1 end
    B.health.mob = 0.35
    B.run(0.3)
    local WB = B.React.world.W
    WB.s.ttd = 6
    _, _, refuse = B.React.adapt(rule, row, WB.s, { target = WB.s.target })
    assert(refuse == nil or not refuse:find("saving", 1, true), "a beast: no reason to keep it: " .. tostring(refuse))
end }

T[#T + 1] = { "stop the runner: the moment a low mob runs, the class's slow goes on it", function()
    local G = bundle()
    G.dispatch = true
    G.known["Concussive Shot"] = true
    G.roles.slow = { { name = "Concussive Shot", applies = { aura = "Concussive Shot" } } }
    G.health.mob = 0.15
    G.row = G.row_for(G.target, { activity = "attacking" })
    G.rows = { G.row }
    G.run(0.3)
    assert_eq(G.sent("Concussive Shot"), 0, "not running: nothing")
    G.row.activity = "fleeing"
    G.run(0.2)
    assert_eq(G.sent("Concussive Shot"), 1, "running at 15%: slowed")
    assert(has_line(G.React.log_lines(20), "Stop the runner"), "by the runner reaction")
end }

T[#T + 1] = { "evading: the pet's own misses say so, and the pet is called back off it", function()
    local G = bundle()
    G.dispatch = true
    G.pet_alive, G.pet_target = true, G.target
    G.P.pet.recall = function(reason, guid, seconds)
        G.recalled = { reason = reason, guid = guid, seconds = seconds }
        return true
    end
    G.run(0.3)
    assert_eq(G.recalled, nil, "nothing evading: the pet stays on it")
    G.fire("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED",
        { 0, "SWING_MISSED", false, "pet", "Wolf", 0, 0, "mob", G.target.name, 0, 0, "EVADE" })
    G.run(0.3)
    assert(G.recalled, "called back")
    assert_eq(G.recalled.guid, "mob", "and kept off that mob")
    assert_eq(G.React.world.W.pet.target_evading, true, "the world knows the pet's mob is evading")
end }

-- --- Forever (1.45.0): what its client does not say --------------------------------------------

T[#T + 1] = { "a mob's name is JCore's (units.name, 1.55.0); 'npc <id>' while JCore has none", function()
    local G = bundle({ forever = true })
    local a = unit(G, "Creature-0-1-0-0-3124-0000ABCDEF", { name = "" })
    assert_eq(G.React.forever_name(a), "npc 3124", "nothing known yet: its creature id")
    -- JCore learned it (from our cast, kept by npc id): units.name answers it.
    a.name = "Roiling Winds"
    assert_eq(G.React.forever_name(a), "Roiling Winds", "JCore's name")
    assert_eq(G.React.learn.name_of(a), "Roiling Winds", "the lessons are kept under it")
    assert_eq(G.handlers["jcore.game_event.UNIT_SPELLCAST_SENT"], nil,
        "the AIO no longer listens for cast names: JCore does")
end }

T[#T + 1] = { "Forever: no combat log, so a cast's expected damage goes on the target's tally", function()
    local G = bundle({ forever = true })
    G.React.damage.expected = function(name) return name == "Sinister Strike" and 40 or nil end
    G.fire("jcore.spell.cast", { spell_id = G.id_of("Sinister Strike"), caster = G.player, target = G.target })
    assert_eq(G.React.damage.dealt("mob"), 40, "the tooltip's 40 on the mob")

    local E = bundle()
    E.React.damage.expected = function() return 40 end
    E.fire("jcore.spell.cast", { spell_id = E.id_of("Sinister Strike"), caster = E.player, target = E.target })
    assert_eq(E.React.damage.dealt("mob"), 0, "Era: the combat log is the tally, never an estimate")
end }

T[#T + 1] = { "Forever: a mob we hit that is out of combat and healing is going home", function()
    local G = bundle({ forever = true })
    G.dispatch = true
    G.P.ctx.cast({ spell_id = G.id_of("Sinister Strike"), target = G.target, reason = "Sinister Strike" })
    G.row = G.row_for(G.target, { in_combat = false, hp = 0.4 })
    G.rows = { G.row }
    G.run(0.2)
    assert_eq(G.React.learn.evading("mob"), false, "out of combat at 40%: not yet")
    G.row.hp = 0.5
    G.run(0.1)
    assert_eq(G.React.learn.evading("mob"), true, "and its health coming back: evading")
    assert_eq(G.React.world.W.target.evading, true, "the world says so")

    -- A mob only marked (never hit, full health) is not evading.
    local M = bundle({ forever = true })
    M.dispatch = true
    M.P.ctx.cast({ spell_id = M.id_of("Hunter's Mark"), target = M.target, reason = "Hunter's Mark" })
    M.row = M.row_for(M.target, { in_combat = false, hp = 1 })
    M.rows = { M.row }
    M.run(0.5)
    assert_eq(M.React.learn.evading("mob"), false, "full health, never hurt: just not pulled yet")
end }

T[#T + 1] = { "Forever: the engine's decisions go into the recorder's timeline, and the readout says what it works around", function()
    local G = bundle({ forever = true })
    G.React.journal("state", "mana_low ON (0.09)")
    local traced = false
    for _, e in ipairs(G.emits or {}) do
        if e.name == "jcore.recorder.trace" and tostring(e.data):find("react state: mana_low ON", 1, true) then traced = true end
    end
    assert(traced, "a state line reached the recorder's trace")
    G.React.debug_lines()
    G.run(0.1)
    assert(has_line(G.React.debug_lines(), "Forever: GCD"), "the readout has its Forever line")

    local E = bundle()
    E.React.journal("state", "mana_low ON (0.09)")
    for _, e in ipairs(E.emits or {}) do
        assert(e.name ~= "jcore.recorder.trace", "Era: nothing is sent to the recorder")
    end
    E.React.debug_lines()
    E.run(0.1)
    assert(not has_line(E.React.debug_lines(), "Forever:"), "Era: no Forever line")
    assert_eq(E.handlers["jcore.game_event.UNIT_SPELLCAST_SENT"], nil, "Era: no extra event subscriptions")
    assert_eq(E.React.learn.name_of(E.target), "Defias Pillager", "Era: the client's own name")
end }

T[#T + 1] = { "Forever: an unreadable channel is left alone, an unread mana bar is not 'empty'", function()
    local G = hunter_fight()
    local H = G.P.rotation.helpers
    G.player.is_channelling_spell = function() return true end
    G.player.get_active_channel_spell_id = function() return 3739147998 end
    assert_eq(H.channelling("Mend Pet"), false, "Era: an id that is not Mend Pet's is not Mend Pet")
    -- JCore's channel id on Forever (1.6.0): an impossible id is nil there.
    G.P.ctx.player.channel_spell_id = function() return nil end
    assert_eq(H.channelling("Mend Pet"), true, "Forever: an impossible id is a channel we cannot name -- not clipped")
    G.P.ctx.player.channel_spell_id = nil

    assert_eq(H.power_fraction({ power = 0, power_max = 0 }), 0, "no information and nothing said: 0, as always")
    assert_eq(H.power_fraction({ power = 0, power_max = 0, power_unknown = 1 }), 1, "Forever: unread is fine")
    assert_eq(H.power_fraction({ power = 0, power_max = 0, power_unknown = 0.05 }), 0.05, "or dry, when the client said so")
end }

T[#T + 1] = { "the ESP is never asked for a name: JCore keeps them all (1.55.0)", function()
    local G = bundle({ forever = true })
    local a = unit(G, "Creature-0-1-0-0-250873-0000ABCDEF", { name = "" })
    local asked = 0
    G.P.esp = { forever = { name_for = function() asked = asked + 1 return "Juvenile Vuldren", "learned" end } }
    assert_eq(G.React.forever_name(a), "npc 250873", "only JCore's answer counts")
    assert_eq(asked, 0, "the ESP was not asked")
end }

T[#T + 1] = { "Forever: a fight leaves a sample line in the recorder's timeline every two seconds; Era leaves none", function()
    local G = bundle({ forever = true })
    G.run(4.1)
    local samples = 0
    for _, e in ipairs(G.emits or {}) do
        if e.name == "jcore.recorder.trace" and tostring(e.data):find("react sample: mode=", 1, true) then samples = samples + 1 end
    end
    assert(samples >= 2 and samples <= 3, "one every two seconds: " .. samples)

    local E = bundle()
    E.run(4.1)
    for _, e in ipairs(E.emits or {}) do
        assert(e.name ~= "jcore.recorder.trace", "Era: nothing sent to the recorder")
    end
end }

-- --- stealth: when it is worth it (1.46.0) -----------------------------------------------------

T[#T + 1] = { "stealth: for a target we are going for, or a hostile close enough to notice -- not every moment out of combat", function()
    local G = hunter_fight()
    local H = G.P.rotation.helpers
    local me = G.player
    me.is_mounted = function() return G.mounted == true end
    me.get_level = function() return 10 end
    me.is_enemy_with = function(_, other) return other.red == true end
    local function mob(guid, level, red)
        local u = unit(G, guid, { name = "Mob" })
        u.get_level = function() return level end
        u.red = red
        return u
    end
    local s = { in_combat = false, player = me, target = nil, distance = math.huge, enemies = {} }

    local ok, why = H.stealth_wanted(s)
    assert_eq(ok, false, "nothing about: no -- it is only slower: " .. why)

    -- The opener.
    local pull = mob("m1", 10, true)
    s.target, s.distance, s.target_row = pull, 30, { in_combat = false, engaged = false }
    ok, why = H.stealth_wanted(s)
    assert_eq(ok, true, "a target we are going for, 30 yards out: " .. why)
    s.distance = 60
    assert_eq((H.stealth_wanted(s)), false, "60 yards: not yet")
    s.distance = 20
    s.target_row = { in_combat = true }
    assert_eq((H.stealth_wanted(s)), false, "already fighting someone: no opener to save")
    s.target, s.target_row = nil, nil

    -- The sneak.
    local near = mob("m2", 10, true)
    s.enemies = { { obj = near, dist = 18, engaged = false, in_combat = false } }
    ok, why = H.stealth_wanted(s)
    assert_eq(ok, true, "a red mob at 18 yards, our level: " .. why)
    s.enemies[1].dist = 35
    assert_eq((H.stealth_wanted(s)), false, "35 yards: past its reach")
    s.enemies[1].dist = 18
    near.red = false
    assert_eq((H.stealth_wanted(s)), false, "a yellow one does not come at us")
    near.red = true
    near.get_level = function() return 3 end
    assert_eq((H.stealth_wanted(s)), false, "a grey one neither")
    near.get_level = function() return 14 end
    s.enemies[1].dist = 27
    assert_eq((H.stealth_wanted(s)), true, "four levels above us: it notices from further")
    near.get_level = function() return 10 end
    s.enemies[1].dist = 18

    -- Never mounted, never in combat.
    G.mounted = true
    assert_eq((H.stealth_wanted(s)), false, "mounted")
    G.mounted = false
    s.in_combat = true
    assert_eq((H.stealth_wanted(s)), false, "in combat")
end }

T[#T + 1] = { "stealth (1.61.0): the rogue's default -- only before an opener the rotation will make, never for a hostile walked past", function()
    local G = hunter_fight()
    local H = G.P.rotation.helpers
    local me = G.player
    me.is_mounted = function() return false end
    me.get_level = function() return 10 end
    me.is_enemy_with = function(_, other) return other.red == true end
    local function mob(guid, level, red)
        local u = unit(G, guid, { name = "Mob" })
        u.get_level = function() return level end
        u.red = red
        return u
    end
    local opts = { engaging = true, no_sneak = true }
    local s = { in_combat = false, player = me, target = nil, distance = math.huge, enemies = {} }
    local near = mob("m2", 10, true)
    s.enemies = { { obj = near, dist = 18, engaged = false, in_combat = false } }
    assert_eq((H.stealth_wanted(s)), true, "the old rule stealths for a hostile walked past")
    assert_eq((H.stealth_wanted(s, opts)), false, "the default does not")
    local picked = mob("m1", 10, true)
    s.target, s.distance, s.target_row = picked, 30, { in_combat = false, engaged = false }
    s.hold_fire = true
    assert_eq((H.stealth_wanted(s, opts)), false, "auto-target picked it and the rotation holds fire: no stealth")
    s.hold_fire = false
    assert_eq((H.stealth_wanted(s, opts)), true, "the rotation is going to open on it: stealth")
end }

-- --- someone else's fight (1.47.4) -------------------------------------------------------------

T[#T + 1] = { "interrupt: a mob fighting a stranger is left alone -- unless it is on us, or we started it", function()
    local G = bundle()
    G.dispatch = true
    G.known.Kick = true
    G.row = G.row_for(G.target, { casting = G.casting("Fear", 1.4, 1.5), in_combat = true,
                                  target_guid = "Player-9-STRANGER", engaged = false })
    G.rows = { G.row }
    G.tick()
    assert_eq(G.React.world.W.target.others_fight, true, "someone else's fight")
    assert_eq(G.sent("Kick"), 0, "not kicked: it would only pull it onto us")

    -- It turns on us: our fight now.
    G.row.target_guid, G.row.targeting_me = "player", true
    G.row.casting = G.casting("Fear", 1.4, 1.5)
    G.run(0.1)
    assert_eq(G.sent("Kick"), 1, "on us: kicked")

    -- A stranger's mob we started on ourselves is ours too.
    local H = bundle()
    H.dispatch = true
    H.known.Kick = true
    H.P.ctx.cast({ spell_id = H.id_of("Sinister Strike"), target = H.target, reason = "Sinister Strike" })
    H.row = H.row_for(H.target, { casting = H.casting("Fear", 1.4, 1.5), in_combat = true,
                                  target_guid = "Player-9-STRANGER", engaged = false })
    H.rows = { H.row }
    H.tick()
    assert_eq(H.React.world.W.target.others_fight, false, "we hit it first: ours")
    assert_eq(H.sent("Kick"), 1, "kicked")
end }

T[#T + 1] = { "the rank and whose mob it is are JCore's (units.classification, loot.tapped; 1.55.0)", function()
    local loot = { tapped = function(u) return u.tap == true end }
    local G = bundle({ forever = true, loot = loot })
    G.P.units.classification = function(u) return u.npc == 4242 and 1 or 0 end
    G.target.npc = 4242
    G.row = G.row_for(G.target, { in_combat = true, engaged = false })
    G.rows = { G.row }
    G.tick()
    local tg = G.React.world.W.target
    assert_eq(tg.elite, true, "elite: JCore's rank (the creature cache's on Forever)")
    assert_eq(tg.others_fight, false, "nobody else's yet")
    G.target.tap = true
    G.run(0.1)
    assert_eq(G.React.world.W.target.others_fight, true, "JCore calls it somebody else's")

    -- Era: JCore answers 0 and false there; the AIO asks the same way.
    local E = bundle({ loot = { tapped = function() return false end } })
    E.P.units.classification = function() return 0 end
    E.target.npc, E.target.tap = 4242, true
    E.row = E.row_for(E.target, { in_combat = true, engaged = false })
    E.rows = { E.row }
    E.tick()
    assert_eq(E.React.world.W.target.elite, false, "normal")
    assert_eq(E.React.world.W.target.others_fight, false, "nobody else's")
end }

-- --- out of Cheetah before the hit (1.50.0) ---------------------------------------------

--- A hunter in Cheetah, with the real Aspects module on the bundle: the
--- engine's "aspect" action is handed to it. Auto swap aspects (1.7.6) on
--- unless `auto_swap` is false.
local function cheetah_bundle(auto_swap)
    local G = bundle({ class = {
        key = "hunter", class_name = "HUNTER", power = "MANA",
        interrupts = {}, defensives = {}, escapes = {},
    } })
    G.dispatch = true
    G.in_combat = false
    G.settings.rot_hunter_auto_aspect = auto_swap ~= false
    for _, name in ipairs({ "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah" }) do
        G.known[name] = true
    end
    G.P.ctx.tick = function() end
    G.P.ctx.spells.gcd = function() return 0 end
    G.P.units.has_aura = function(u, ids)
        local index = G.auras[u.guid] or {}
        for i = 1, #ids do if index[ids[i]] then return true end end
        return false
    end
    G.P.aspects = require("jambix_aio/modules/aspects")(G.P)
    G.auras.player = { [G.id_of("Aspect of the Cheetah")] = { buff_name = "Aspect of the Cheetah" } }
    return G
end

T[#T + 1] = { "hunter: out of Cheetah before the hit -- the switch is handed to the Aspects window, once", function()
    local G = cheetah_bundle()
    G.rows = { G.row_for(G.target, { targeting_me = true, dist = 12, time_to_reach = 0.7, moving = true,
                                     in_combat = true }) }
    G.tick()
    local n, last = G.sent("Aspect of the Hawk")
    assert_eq(n, 1, "Hawk went out before the mob arrived")
    assert_eq(last.priority, 200, "in the defensive band")
    assert(last.reason:find("reaches you in 0.7s", 1, true), "the cast says why: " .. tostring(last.reason))
    assert_eq(G.P.aspects.stats().wanted, "Aspect of the Hawk", "the window's switch moved to Hawk")
    assert(has_line(G.React.log_lines(10), "Out of Cheetah before the hit"), "the reaction is in the log")
    G.run(0.5)
    assert_eq(G.sent("Aspect of the Hawk"), 1, "one swap for one hit")
    assert_eq(G.sent("Aspect of the Cheetah"), 0, "Cheetah never cast")
end }

T[#T + 1] = { "hunter: out of Cheetah -- not for a mob being outrun, and never as a plain spell", function()
    local G = cheetah_bundle()
    G.rows = { G.row_for(G.target, { targeting_me = true, dist = 15, time_to_reach = math.huge, moving = true,
                                     in_combat = true, closing = -2 }) }
    G.run(2)
    assert_eq(G.sent("Aspect of the Hawk"), 0, "losing ground on us: Cheetah stays")

    -- Without the Aspects module the action has nowhere to go: refused, not cast.
    local H = cheetah_bundle()
    H.P.aspects = nil
    H.rows = { H.row_for(H.target, { targeting_me = true, dist = 3, in_combat = true }) }
    H.run(0.5)
    assert_eq(H.sent("Aspect of the Hawk"), 0, "no module, no aspect")
end }

T[#T + 1] = { "hunter: out of Cheetah -- never with Auto swap aspects off (1.7.6)", function()
    local G = cheetah_bundle(false)
    G.rows = { G.row_for(G.target, { targeting_me = true, dist = 3, in_combat = true }) }
    for _ = 1, 20 do
        G.run(0.1)
        G.P.aspects._tick()         -- the keeper's guard too, as with the rotation off
    end
    assert_eq(G.sent("Aspect of the Hawk"), 0, "a mob in melee: no swap")
    assert_eq(G.sent("Aspect of the Monkey"), 0, "into nothing else either")
    assert_eq(G.P.aspects.stats().wanted, "Aspect of the Cheetah", "Cheetah's switch stays on")
    assert(not has_line(G.React.log_lines(20), "Out of Cheetah before the hit"), "the reaction never offered")
end }

T[#T + 1] = { "a spell you have not learned is never a candidate: not listed, not refused, not logged (1.54.1)", function()
    local G = bundle()
    G.dispatch = true
    G.known.Sprint = true             -- learned; Vanish is not
    G.React.add_rule({
        name = "Test: get away", category = "utility", priority = 60, target = "self",
        propose = function(W, offer)
            local c = offer({ name = "Vanish" })
            c:add(50, "would win if it were learned")
            offer({ name = "Sprint" })
        end,
    })
    G.React.debug_lines()
    G.tick()
    assert_eq(G.sent("Vanish"), 0, "never pressed")
    assert_eq(G.sent("Sprint"), 1, "the learned one is")
    local readout = table.concat(G.React.debug_lines(), "\n")
    assert(not readout:find("Vanish", 1, true), "not in the readout:\n" .. readout)
    assert(not table.concat(G.React.overlay_lines(), "\n"):find("Vanish", 1, true), "not in the window")
    assert(not has_line(G.React.log_lines(30), "Vanish"), "not in the journal")
end }

-- --- the pet's taunt (react/petthreat.lua, 1.68.0) ------------------------------------------

--- A pet with Growl, its taunt clock and the positions the planner measures
--- from. `ready` sets Growl's seconds to ready; `at` places a unit.
local function taunting(G, known)
    G.pet_alive = true
    for _, name in ipairs(known or { "Growl" }) do G.pet_known[name] = true end
    G.ready_in, G.pos, G.aimed = {}, {}, 0
    G.P.pet.ready_in = function(name) return G.ready_in[name] or 0 end
    G.P.pet.aim_taunt = function() G.aimed = G.aimed + 1 return "Growl" end
    G.P.pet.focus_power = function() return G.focus end
    G.P.units.position = function(u) return u and G.pos[u.guid] or nil end
    G.pos.pet = { x = 0, y = 0, z = 0 }
end

local function at(G, row, x, y)
    row.x, row.y, row.z = x, y, 0
    return row
end

local function pet_cast(G)
    return G.pet_casts[#G.pet_casts]
end

T[#T + 1] = { "pet taunt: Growl goes to the add hitting you inside the pet's reach, not the pet's own mob", function()
    local G = bundle()
    taunting(G)
    G.pet_target = G.target
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6, threat = { percent = 30 } }), 2, 0)
    G.rows = { G.row, at(G, G.row_for(add, { targeting_me = true, dist = 4 }), 3, 1) }
    G.React.debug_lines()
    G.tick()
    local c = pet_cast(G)
    assert(c and c.name == "Growl", "the pet Growled")
    assert_eq(c.target, add, "at the add on you, standing beside the pet's mob")
    assert(G.aimed > 0, "the engine aims it (autocast held off)")
    local lines = G.React.debug_lines()
    assert(has_line(lines, "Growl -> Mottled Boar"), "the readout shows the pet's press")
    assert(has_line(lines, "+14 it is on you"), "and why")
end }

T[#T + 1] = { "pet taunt: on cooldown it waits and says so; ready, it goes on the pet's own mob, as autocast did", function()
    local G = bundle()
    taunting(G)
    G.pet_target = G.target
    G.row = at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6 }), 2, 0)
    G.rows = { G.row }
    G.ready_in.Growl = 2.5
    G.React.debug_lines()
    G.tick()
    assert_eq(#G.pet_casts, 0, "not ready: nothing pressed")
    assert(has_line(G.React.debug_lines(), "Pet taunt: Growl in 2.5s | next Defias Pillager (the pet's own"),
        "the readout says when, and at what")

    G.ready_in.Growl = 0
    G.clock = G.clock + 0.2
    G.tick()
    local c = pet_cast(G)
    assert(c and c.name == "Growl" and c.target == G.target, "ready: on the pet's own mob")

    -- Nearly dead: the focus is the pet's damage, not a taunt.
    local D = bundle()
    taunting(D)
    D.pet_target = D.target
    D.rows = { at(D, D.row_for(D.target, { targeting_pet = true, hp = 0.05 }), 2, 0) }
    D.tick()
    assert_eq(#D.pet_casts, 0, "no upkeep on a mob about to die")

    -- Short of focus: waits, and says why.
    local F = bundle()
    taunting(F)
    F.focus = 9
    F.pet_target = F.target
    F.rows = { at(F, F.row_for(F.target, { targeting_pet = true, hp = 0.6 }), 2, 0) }
    F.React.debug_lines()
    F.tick()
    assert_eq(#F.pet_casts, 0, "9 focus: no Growl")
    assert(has_line(F.React.debug_lines(), "the pet has 9 focus, Growl costs 15"), "and the readout says so")
end }

T[#T + 1] = { "pet taunt: a mob about to turn to you is Growled first -- at 90%, or climbing to 100 inside 2s (Era)", function()
    local G = bundle()
    taunting(G)
    G.pet_target = G.target
    local b = unit(G, "b", { name = "Kobold" })
    G.row = at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6, threat = { percent = 30 } }), 2, 0)
    G.rows = { G.row, at(G, G.row_for(b, { targeting_pet = true, hp = 0.8, threat = { percent = 92 } }), 2, 2) }
    G.tick()
    local c = pet_cast(G)
    assert(c and c.target == b, "92% on the Kobold: it gets the Growl, not the pet's own mob")

    -- Climbing: 80% now, 88% half a second later -- 100 inside two seconds.
    local R = bundle()
    taunting(R)
    R.pet_target = R.target
    R.row = at(R, R.row_for(R.target, { targeting_pet = true, hp = 0.6, threat = { percent = 80 } }), 2, 0)
    R.rows = { R.row }
    R.ready_in.Growl = 3
    R.tick()
    R.clock = R.clock + 0.5
    R.row.threat.percent = 88
    R.ready_in.Growl = 0
    R.React.debug_lines()
    R.tick()
    local lines = R.React.debug_lines()
    assert(has_line(lines, "your threat 88%, +16/s: on you in ~"), "the climb is the reason")
    assert(pet_cast(R) and pet_cast(R).target == R.target, "and Growl goes before it turns")

    -- Forever: threat unread -- nothing is "about to turn"; only what is on you.
    local Q = bundle({ forever = true })
    taunting(Q)
    Q.pet_target = Q.target
    local b2 = unit(Q, "b", { name = "Kobold" })
    Q.rows = { at(Q, Q.row_for(Q.target, { targeting_pet = true, hp = 0.6 }), 2, 0),
               at(Q, Q.row_for(b2, { targeting_pet = true, hp = 0.8 }), 2, 2) }
    Q.tick()
    assert(pet_cast(Q) and pet_cast(Q).target == Q.target, "Forever: the pet's own mob, as autocast did")
end }

T[#T + 1] = { "pet taunt: a mob on you out of the pet's reach -- the pet goes to it, then Growls it there", function()
    local G = bundle()
    taunting(G)
    G.pet_target = G.target
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6, threat = { percent = 30 } }), 2, 0)
    local arow = at(G, G.row_for(add, { targeting_me = true, dist = 3 }), 20, 0)
    G.rows = { G.row, arow }
    G.ready_in.Growl = 3
    G.React.debug_lines()
    G.tick()
    assert(G.assigned and G.assigned.unit == add, "out of reach: the pet is sent to it")
    assert(has_line(G.React.debug_lines(), "the pet goes to Mottled Boar (on you, 20y from the pet: out of reach)"),
        "the readout says where the pet goes")

    -- The pet is there, on the add; Growl is ready.
    G.pos.pet = { x = 19, y = 0, z = 0 }
    G.pet_target = add
    G.ready_in.Growl = 0
    G.clock = G.clock + 0.3
    G.tick()
    local c = pet_cast(G)
    assert(c and c.name == "Growl" and c.target == add, "Growled where it stands")
end }

T[#T + 1] = { "pet taunt: the pet takes a melee add even when the mob it leaves would turn -- and that one is not shot", function()
    local G = bundle()
    taunting(G)
    G.pet_target = G.target
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = G.row_for(G.target, { targeting_pet = true, hp = 0.4, threat = { percent = 92 } })
    G.rows = { G.row, G.row_for(add, { targeting_me = true, dist = 3 }) }
    G.ready_in.Growl = 3
    G.React.debug_lines()
    G.tick()
    assert(G.assigned and G.assigned.unit == add, "the add hitting you in melee goes to the pet")
    local plan = G.React.plan()
    assert_eq(plan.focus, add, "92% on the pet's mob: the shots go to the add, the pet's mob is left to its threat")
    assert(has_line(G.React.debug_lines(),
        "pet takes Mottled Boar: Mottled Boar is hitting you in melee: the pet takes it, Defias Pillager stays on the pet's threat"),
        "the plan says so")

    -- Without a taunt the old rule stands: the pet stays.
    local N = bundle()
    N.pet_alive, N.pet_target = true, N.target
    local add2 = unit(N, "add", { name = "Mottled Boar" })
    N.rows = { N.row_for(N.target, { targeting_pet = true, hp = 0.4, threat = { percent = 92 } }),
               N.row_for(add2, { targeting_me = true, dist = 3 }) }
    N.tick()
    assert_eq(N.assigned, nil, "a pet that cannot taunt does not leave a mob that would turn")
end }

T[#T + 1] = { "pet taunt: in a group it only rescues you -- no upkeep, never a boss, never the tank's mob", function()
    local G = bundle()
    party(G)
    taunting(G)
    G.pet_target = G.target
    local b = unit(G, "b", { name = "Kobold" })
    local brow = at(G, G.row_for(b, { targeting_me = true, dist = 4 }), 2, 2)
    G.rows = { at(G, on(G, G.target, "tank", { targeting_pet = false }), 2, 0), brow }
    G.tick()
    local c = pet_cast(G)
    assert(c and c.target == b, "the mob on you, beside the pet: Growled off you")

    local U = bundle()
    party(U)
    taunting(U)
    U.pet_target = U.target
    U.rows = { at(U, U.row_for(U.target, { targeting_pet = true, hp = 0.6 }), 2, 0) }
    U.tick()
    assert_eq(#U.pet_casts, 0, "the pet's own mob in a group: no upkeep (the tank holds it)")

    local K = bundle()
    party(K)
    taunting(K)
    local b2 = unit(K, "b", { name = "Kobold" })
    K.rows = { at(K, K.row_for(b2, { targeting_me = true, dist = 4 }), 2, 2) }
    K.tank_on = b2
    K.tick()
    assert_eq(#K.pet_casts, 0, "the tank is on it: the tank takes it back, not the pet")

    local B = bundle()
    party(B)
    taunting(B)
    local boss = unit(B, "boss", { name = "Mutanus", classification = 3 })
    B.rows = { at(B, B.row_for(boss, { targeting_me = true, dist = 4 }), 2, 2) }
    B.tick()
    assert_eq(#B.pet_casts, 0, "never a boss in a group")
end }

T[#T + 1] = { "pet taunt: Suffering for two or more around the Voidwalker that Torment cannot reach", function()
    local WARLOCK = { key = "warlock", class_name = "WARLOCK", power = "MANA", interrupts = {}, defensives = {}, escapes = {} }
    local G = bundle({ class = WARLOCK })
    taunting(G, { "Torment", "Suffering" })
    local a, b = unit(G, "a", { name = "Kobold" }), unit(G, "b", { name = "Kobold Miner" })
    G.rows = { at(G, G.row_for(a, { targeting_me = true, dist = 3 }), 7, 0),
               at(G, G.row_for(b, { targeting_me = true, dist = 3 }), 0, 7) }
    G.React.debug_lines()
    G.tick()
    local c = pet_cast(G)
    assert(c and c.name == "Suffering", "two on you within ten yards of the Voidwalker: Suffering")
    assert_eq(c.target, G.pet, "cast by the pet, around itself")

    G.ready_in.Suffering = 100
    G.pet_casts = {}
    G.clock = G.clock + 3
    G.tick()
    local again = pet_cast(G)
    assert(not (again and again.name == "Suffering"), "not again while it is on cooldown")
end }

T[#T + 1] = { "pet taunt: autocast will not stay off -- the pet is moved onto the mob instead of pressing (1.68.1)", function()
    local G = bundle()
    taunting(G)
    G.P.pet.aim_taunt = function() return nil end
    G.P.pet.taunt_stuck = function() return "the pet used Growl by itself 2 times after it was switched off" end
    G.pet_target = G.target
    local add = unit(G, "add", { name = "Mottled Boar" })
    G.row = at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6, threat = { percent = 30 } }), 2, 0)
    G.rows = { G.row, at(G, G.row_for(add, { targeting_me = true, dist = 4 }), 3, 1) }
    G.React.debug_lines()
    G.tick()
    assert_eq(#G.pet_casts, 0, "no press: autocast Growls")
    assert(G.assigned and G.assigned.unit == add, "the pet goes onto the add, beside it")
    assert(has_line(G.React.debug_lines(), "Growl left on autocast (the pet used Growl by itself"), "the readout says why")

    local O = bundle()
    taunting(O)
    O.P.pet.aim_taunt = function() return nil end
    O.pet_target = O.target
    O.rows = { at(O, O.row_for(O.target, { targeting_pet = true, hp = 0.6 }), 2, 0) }
    O.tick()
    assert_eq(#O.pet_casts, 0, "its own mob: autocast keeps it")
    assert_eq(O.assigned, nil, "and nothing moves")
end }

T[#T + 1] = { "a client error names everything sent with it: a refused Growl is not read as Auto Shot's (1.68.1)", function()
    local G = bundle()
    G.dispatch = true
    taunting(G)
    G.pet_target = G.target
    G.rows = { at(G, G.row_for(G.target, { targeting_pet = true, hp = 0.6 }), 2, 0) }
    G.tick()
    assert(pet_cast(G) and pet_cast(G).name == "Growl", "the pet's Growl went out")
    G.fire("jcore.cast.sent", { spell_id = G.id_of("Auto Shot"), target = G.target, owner = "jambix.aio" })
    G.fire("jcore.game_event.UI_ERROR_MESSAGE", { 0, "Spell is not ready yet.", "SPELL_FAILED_NOT_READY" })
    assert(has_line(G.React.log_lines(5), "client error after Auto Shot (or Growl, sent with it): Spell is not ready yet."),
        "both named")
end }

T[#T + 1] = { "hunter: Intimidation gives the pet its mob back when Growl cannot (1.68.0)", function()
    local HUNTER = { key = "hunter", class_name = "HUNTER", power = "MANA", interrupts = {}, defensives = {}, escapes = {} }
    local G = bundle({ class = HUNTER })
    hunter(G)
    taunting(G)
    G.known.Intimidation = true
    G.pet_target = G.target
    G.row = at(G, G.row_for(G.target, { targeting_me = true, dist = 25, hp = 0.6 }), 2, 0)
    G.rows = { G.row }
    G.tick()
    assert_eq(G.sent("Intimidation"), 0, "Growl is ready: it goes first")
    assert(pet_cast(G) and pet_cast(G).name == "Growl", "the Growl")

    -- A second and a half later it is still on you, and Growl is cooling down.
    G.ready_in.Growl = 3.5
    G.clock = G.clock + 1.5
    G.tick()
    local n, req = G.sent("Intimidation")
    assert_eq(n, 1, "the Growl did not bring it back: Intimidation")
    assert_eq(req.target, G.player, "cast on yourself; the pet's next hit lands it")

    local N = bundle({ class = HUNTER })
    hunter(N)
    taunting(N)
    N.known.Intimidation = true
    N.pet_target = N.target
    N.rows = { at(N, N.row_for(N.target, { targeting_pet = true, dist = 25, hp = 0.6 }), 2, 0) }
    N.ready_in.Growl = 4
    N.tick()
    assert_eq(N.sent("Intimidation"), 0, "still on the pet: nothing to give back")
end }

-- --- the pet's own skills (react/rules/pet.lua, 1.69) ---------------------------------------

local BEASTS = require("jambix_aio/modules/beasts_data").vanilla

--- A pet that knows `known`, with the spell tables' numbers, a clock, its
--- focus, and positions the rules measure from (the pet at the origin).
local function skilled(G, known)
    G.pet_alive = true
    G.pet_known, G.ready_in, G.pos, G.dist, G.owned = {}, {}, {}, {}, {}
    for _, name in ipairs(known) do G.pet_known[name] = true end
    G.P.pet.skill = function(name) return BEASTS.skills[name] end
    G.P.pet.ready_in = function(name) return G.ready_in[name] or 0 end
    G.P.pet.focus_power = function() return G.focus end
    G.P.pet.aim = function(name, restore)
        G.owned[name] = { restore = restore }
        return not (G.stuck and G.stuck[name])
    end
    G.P.pet.aim_taunt = function() return "Growl" end
    G.P.pet.taunt_aimed = function() return G.pet_known.Growl == true end
    G.P.pet.sent_for = function() return nil end
    G.P.units.position = function(u) return u and G.pos[u.guid] or nil end
    G.P.units.distance = function(u) return u and G.dist[u.guid] or 99 end
    G.P.units.distance_between = function(a, b)
        local pa, pb = a and G.pos[a.guid], b and G.pos[b.guid]
        if not pa or not pb then return math.huge end
        local dx, dy = pa.x - pb.x, pa.y - pb.y
        return math.sqrt(dx * dx + dy * dy)
    end
    G.pos.pet = { x = 0, y = 0, z = 0 }
end

local function place(G, row, x, y)
    row.x, row.y, row.z = x, y, 0
    G.pos[row.guid] = { x = x, y = y, z = 0 }
    return row
end

local function last_pet(G) return G.pet_casts[#G.pet_casts] end

T[#T + 1] = { "pet skills: Furious Howl only with two or more within 15 yd of the wolf -- never solo at range (1.71.0)", function()
    local G = bundle()
    skilled(G, { "Furious Howl" })
    G.pet_target = G.target
    G.rows = { place(G, G.row_for(G.target, { targeting_pet = true, hp = 0.8 }), 2, 0) }
    G.dist.pet = 28                                  -- you shoot from 28 yd
    G.tick()
    assert_eq(#G.pet_casts, 0, "solo at range: no howl")
    assert(G.owned["Furious Howl"], "but it is held off autocast (its 60 focus every 10 s)")

    G.dist.pet = 10
    G.clock = G.clock + 0.3
    G.tick()
    assert_eq(#G.pet_casts, 0, "you alone in reach: one attack is not worth 60 focus")

    -- A party: a member beside the wolf as well.
    local P2 = bundle()
    party(P2)
    skilled(P2, { "Furious Howl" })
    P2.pet_target = P2.target
    P2.rows = { place(P2, P2.row_for(P2.target, { targeting_pet = true, hp = 0.8 }), 2, 0) }
    P2.dist.pet = 10
    P2.pos.tank = { x = 3, y = 0, z = 0 }
    P2.tick()
    local c = last_pet(P2)
    assert(c and c.name == "Furious Howl", "you and the tank within 15 yd: howl")
    assert_eq(c.target, P2.pet, "cast by the wolf, around itself")
end }

T[#T + 1] = { "pet skills: Dash when its mob is 15 yd or more away; Charge from 8 to 25 yd (1.71.0)", function()
    local G = bundle()
    skilled(G, { "Dash" })
    G.pet_target = G.target
    G.rows = { place(G, G.row_for(G.target, { targeting_me = true, hp = 0.9 }), 30, 0) }
    G.tick()
    local c = last_pet(G)
    assert(c and c.name == "Dash", "30 yd to its mob, which is on you: Dash")
    G.pet_casts = {}
    G.ready_in.Dash = 25
    G.clock = G.clock + 3
    G.tick()
    assert_eq(#G.pet_casts, 0, "not again on its cooldown")

    local N = bundle()
    skilled(N, { "Dash" })
    N.pet_target = N.target
    N.rows = { place(N, N.row_for(N.target, { targeting_pet = true }), 4, 0) }
    N.tick()
    assert_eq(#N.pet_casts, 0, "already on it: no Dash")

    local B = bundle()
    skilled(B, { "Charge" })
    B.pet_target = B.target
    B.rows = { place(B, B.row_for(B.target, { targeting_me = true }), 15, 0) }
    B.tick()
    local ch = last_pet(B)
    assert(ch and ch.name == "Charge" and ch.target == B.target, "15 yd: the boar charges its mob")

    for _, far in ipairs({ 6, 40 }) do
        local X = bundle()
        skilled(X, { "Charge" })
        X.pet_target = X.target
        X.rows = { place(X, X.row_for(X.target, { targeting_me = true }), far, 0) }
        X.tick()
        assert_eq(#X.pet_casts, 0, string.format("%d yd: out of Charge's 8 to 25", far))
    end
end }

T[#T + 1] = { "pet skills: Thunderstomp for two within 8 yd of the gorilla, or the one on you beside it (1.71.0)", function()
    local G = bundle()
    skilled(G, { "Thunderstomp" })
    G.pet_target = G.target
    local b = unit(G, "b", { name = "Kobold" })
    G.rows = { place(G, G.row_for(G.target, { targeting_pet = true }), 2, 0),
               place(G, G.row_for(b, { targeting_pet = true }), 0, 3) }
    G.tick()
    assert(last_pet(G) and last_pet(G).name == "Thunderstomp", "two within 8 yd: stomp")

    local O = bundle()
    skilled(O, { "Thunderstomp" })
    O.pet_target = O.target
    O.rows = { place(O, O.row_for(O.target, { targeting_pet = true }), 2, 0) }
    O.tick()
    assert_eq(#O.pet_casts, 0, "one, on the pet: kept for the pack")

    local M = bundle()
    skilled(M, { "Thunderstomp" })
    M.pet_target = M.target
    local c = unit(M, "c", { name = "Kobold" })
    M.rows = { place(M, M.row_for(M.target, { targeting_pet = true }), 20, 0),
               place(M, M.row_for(c, { targeting_me = true, dist = 3 }), 0, 4) }
    M.tick()
    assert(last_pet(M) and last_pet(M).name == "Thunderstomp", "the one on you, beside the gorilla: stomp")
end }

T[#T + 1] = { "pet skills: Shell Shield when the turtle is tanking and going down, or three are on it (1.71.0)", function()
    local G = bundle()
    skilled(G, { "Shell Shield" })
    G.pet_target = G.target
    G.health.pet = 0.9
    G.rows = { G.row_for(G.target, { targeting_pet = true }) }
    G.tick()
    assert_eq(#G.pet_casts, 0, "healthy, one on it: nothing")

    G.health.pet, G.pet_rate = 0.4, -0.06
    G.clock = G.clock + 0.3
    G.tick()
    assert(last_pet(G) and last_pet(G).name == "Shell Shield", "40% and falling 6%/s: the shell")

    local C = bundle()
    skilled(C, { "Shell Shield" })
    C.health.pet = 0.9
    local rows = {}
    for i = 1, 3 do rows[i] = C.row_for(unit(C, "m" .. i, {}), { targeting_pet = true }) end
    C.rows = rows
    C.tick()
    assert(last_pet(C) and last_pet(C).name == "Shell Shield", "three on it: the shell")
end }

T[#T + 1] = { "pet skills: Cower only in a group, when the pet is about to pull off the tank -- never on autocast (1.71.0)", function()
    local G = bundle()
    party(G)
    skilled(G, { "Cower" })
    G.pet_target = G.target
    G.rows = { on(G, G.target, "tank") }
    G.boards = { mob = { pet = { percent = 92 } } }
    G.P.ctx.threat.get = function(u) return G.boards[u.guid] end
    G.tick()
    local c = last_pet(G)
    assert(c and c.name == "Cower" and c.target == G.target, "the pet at 92% of the tank's: Cower")
    assert_eq(G.owned.Cower.restore, false, "and Cower goes back OFF autocast when the engine lets go")

    G.boards.mob.pet.percent = 50
    G.pet_casts = {}
    G.clock = G.clock + 3
    G.tick()
    assert_eq(#G.pet_casts, 0, "50%: nothing")

    local S = bundle()
    skilled(S, { "Cower" })
    S.pet_target = S.target
    S.rows = { S.row_for(S.target, { targeting_pet = true }) }
    S.tick()
    assert_eq(#S.pet_casts, 0, "solo the pet is the tank: never Cower")
    assert(S.owned.Cower, "but held off autocast all the same")
end }

T[#T + 1] = { "pet skills: Sacrifice when you are about to die; Seduction on a humanoid add; Consume Shadows after (1.71.0)", function()
    local WARLOCK = { key = "warlock", class_name = "WARLOCK", power = "MANA", interrupts = {}, defensives = {}, escapes = {} }
    local G = bundle({ class = WARLOCK })
    skilled(G, { "Sacrifice" })
    G.rows = { G.row_for(G.target, { targeting_me = true, dist = 3 }) }
    G.hp = 0.6
    G.tick()
    assert_eq(#G.pet_casts, 0, "60%: no")
    G.hp, G.hp_rate = 0.2, -0.05
    G.clock = G.clock + 0.3
    G.tick()
    local c = last_pet(G)
    assert(c and c.name == "Sacrifice" and c.target == G.pet, "20% and falling with a mob on you: the Voidwalker's shield")

    local S = bundle({ class = WARLOCK })
    skilled(S, { "Seduction" })
    local add = unit(S, "add", { name = "Defias Thug" })
    function add.get_creature_type() return 7 end
    local beast = unit(S, "beast", { name = "Wolf" })
    function beast.get_creature_type() return 1 end
    S.rows = { S.row_for(S.target, { targeting_me = true }), S.row_for(beast, { targeting_me = true }),
               S.row_for(add, { targeting_me = true }) }
    S.hp = 0.5
    S.tick()
    local sd = last_pet(S)
    assert(sd and sd.name == "Seduction" and sd.target == add, "the humanoid add, not the beast, not the target")

    local Q = bundle({ class = WARLOCK })
    party(Q)
    skilled(Q, { "Seduction" })
    local add2 = unit(Q, "add", { name = "Defias Thug" })
    function add2.get_creature_type() return 7 end
    Q.rows = { Q.row_for(Q.target, { targeting_me = true }), Q.row_for(add2, { targeting_me = true }) }
    Q.hp = 0.5
    Q.tick()
    assert_eq(#Q.pet_casts, 0, "in a group, crowd control waits for its key")

    local V = bundle({ class = WARLOCK })
    skilled(V, { "Consume Shadows" })
    V.in_combat = false
    V.health.pet = 0.5
    V.rows, V.count = {}, 0
    V.tick()
    assert(last_pet(V) and last_pet(V).name == "Consume Shadows", "out of combat, Voidwalker at 50%: it heals itself")
end }

T[#T + 1] = { "pet skills: 15 focus kept for Growl while the pet is the tank; a skill left on autocast is not pressed (1.71.0)", function()
    local G = bundle()
    skilled(G, { "Thunderstomp", "Growl" })
    G.pet_target = G.target
    G.focus = 65
    G.ready_in.Growl = 2
    local b = unit(G, "b", { name = "Kobold" })
    G.rows = { place(G, G.row_for(G.target, { targeting_pet = true }), 2, 0),
               place(G, G.row_for(b, { targeting_pet = true }), 0, 3) }
    G.React.debug_lines()
    G.tick()
    assert_eq(#G.pet_casts, 0, "65 focus: Thunderstomp's 60 would leave Growl short")
    assert(table.concat(G.React.debug_lines(), "\n"):find("Thunderstomp", 1, true), "it is shown, waiting")

    G.focus = 80
    G.clock = G.clock + 0.3
    G.tick()
    assert(last_pet(G) and last_pet(G).name == "Thunderstomp", "80 focus: 60 for it, 15 left for Growl")

    local A = bundle()
    skilled(A, { "Thunderstomp" })
    A.stuck = { Thunderstomp = true }
    A.pet_target = A.target
    local b2 = unit(A, "b", { name = "Kobold" })
    A.rows = { place(A, A.row_for(A.target, { targeting_pet = true }), 2, 0),
               place(A, A.row_for(b2, { targeting_pet = true }), 0, 3) }
    A.tick()
    assert_eq(#A.pet_casts, 0, "it would not stay off autocast here: the pet's own autocast has it")
end }

-- --- your own reactions (the Reactions window, 1.76.0) -------------------------------

--- A bundle whose class is known and whose world says where it is.
local function custom_bundle(class_name, opts)
    local G = bundle(opts)
    G.P.rotation.detect_class = function() return class_name or "MAGE" end
    G.where = { itype = "none", name = "", id = 0 }
    local client = G.P.ctx.world.client
    G.P.ctx.world = {
        client = client,
        instance_type = function() return G.where.itype end,
        instance_name = function() return G.where.name end,
        instance_id = function() return G.where.id end,
    }
    G.C = G.React.custom
    assert(G.C, "react/init loads react/custom")
    G.C.sync()
    return G
end

local function go_to(G, itype, name, id)
    G.where = { itype = itype, name = name or "", id = id or 0 }
    G.clock = G.clock + 1.1      -- past the 1 s instance cache
end

T[#T + 1] = { "your reactions: a GUI reaction casts its spell once its conditions hold, on the target it names", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local id = C.save({
        name = "Panic", importance = "survival",
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 30 } },
        actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } },
    })
    assert(id, "saved")
    assert(C.rule_of(id), "it is a rule in the engine")
    assert_eq(C.rule_of(id).name, "My: Panic", "named for the window and the log")
    G.hp = 0.6
    G.run(0.3)
    assert_eq((G.sent("Ice Block")), 0, "health 60%: the condition does not hold")
    local rt = C.runtime(id)
    assert(rt and rt.pass == false, "the reaction was asked and said no")
    assert_eq(rt.conds[1].shown, "60%", "the condition shows what it read")
    G.hp = 0.25
    G.tick()
    local n, req = G.sent("Ice Block")
    assert_eq(n, 1, "health 25%: Ice Block goes out")
    assert(req.target == G.player, "on yourself")
    assert_eq(C.rule_of(id).fired_n, 1, "the engine counts it for the window")
end }

T[#T + 1] = { "your reactions: Lua rows use the same function set as the GUI rows, and a GUI row turns into that Lua", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    assert(C.lua_available(), "the harness runs Lua code")
    assert_eq(C.cond_code({ mode = "gui", key = "me_hp", op = "<", value = 30 }), "me.hp < 30", "a number row")
    assert_eq(C.cond_code({ mode = "gui", key = "t_casting", op = "not" }), "not target.casting", "a yes/no row")
    assert_eq(C.cond_code({ mode = "gui", key = "me_buff", op = "is", value = "Ice Barrier" }), 'buff("Ice Barrier")', "a text row")
    assert_eq(C.action_code({ mode = "gui", kind = "spell", spell = "Ice Block", target = "self" }), 'cast("Ice Block", "self")', "an action")
    local id = C.save({
        name = "Coded", importance = "defensive",
        conds = { { mode = "lua", code = 'check("me_hp", "<", 30) and fight.on_me >= 0' } },
        actions = { { mode = "lua", code = 'if not cast("Fireball") then\n    cast("Ice Block", "self")\nend' } },
    })
    G.hp = 0.5
    G.run(0.2)
    assert_eq((G.sent("Ice Block")), 0, "check() says no at 50%")
    G.hp = 0.2
    G.tick()
    assert_eq((G.sent("Ice Block")), 1, "check() says yes at 20%; Fireball is not known, so the second cast() goes")
    local rt = C.runtime(id)
    assert(rt.conds[1].ok == true and rt.conds[1].shown == "true", "the Lua condition's answer is kept for the window")
    -- An action written as an expression naming the spell works too.
    C.save({ name = "Named", importance = "survival", combat_only = false,
        conds = { { mode = "lua", code = "me.hp < 30" } },
        actions = { { mode = "lua", code = '"Ice Block", "self"' } } })
    G.clock = G.clock + 5
    G.tick()
    assert_eq((G.sent("Ice Block")), 2, "an action that returns a spell name casts it")
    assert(C.reaction_code(C.get(id)):find("if condition1()", 1, true), "the whole reaction reads as code")
end }

T[#T + 1] = { "your reactions: the class Library's functions are callable from code and offered to the GUI", function()
    local G = custom_bundle()
    G.known["Frost Nova"] = true
    local C = G.C
    local err = C.set_library("function swarmed()\n    return fight.on_me >= 2\nend\nfunction nova()\n    return cast(\"Frost Nova\")\nend\n")
    assert(err == nil, "the Library compiles: " .. tostring(err))
    local labels = C.choices("library")
    assert(labels[1] == "nova" and labels[2] == "swarmed", "its functions are offered: " .. table.concat(labels, ","))
    C.save({ name = "Swarmed", importance = "cc",
        conds = { { mode = "gui", key = "lua_fn", op = "is", value = "swarmed" } },
        actions = { { mode = "gui", kind = "lua_fn", fn = "nova" } } })
    G.rows = { G.row_for(G.target, { targeting_me = true }) }
    G.run(0.2)
    assert_eq((G.sent("Frost Nova")), 0, "one mob on me: swarmed() says no")
    local add = unit(G, "add", { name = "Defias Thug" })
    G.rows[2] = G.row_for(add, { targeting_me = true })
    G.tick()
    assert_eq((G.sent("Frost Nova")), 1, "two on me: the GUI asked the Library, and its action cast through it")
    local e2, line = C.set_library("function broken(\n  return 1\nend")
    assert(e2 and line == 2, "a Library error names its line: " .. tostring(e2))
end }

T[#T + 1] = { "your reactions: compile errors carry their line, an endless loop is stopped, a raising row is only that row's failure", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local _, err, line = C.compiled("local x = 1\nif x then\n  x = = 2\nend", "act", "test")
    assert(err and line == 3, "the error is on line 3: " .. tostring(err))
    local id = C.save({ name = "Loops", importance = "survival",
        conds = { { mode = "lua", code = "while true do end" } },
        actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } } })
    local ok, raised = pcall(G.tick)
    assert(ok, "the tick survives the loop: " .. tostring(raised))
    local rt = C.runtime(id)
    assert(rt.conds[1].err and rt.conds[1].err:find("took too long", 1, true), "stopped by the watchdog: " .. tostring(rt.conds[1].err))
    assert_eq((G.sent("Ice Block")), 0, "a failed condition does not act")
    local probs = C.problems({ name = "x", conds = { { mode = "lua", code = "me.hp <" } }, actions = {} })
    assert(#probs >= 2, "a draft's problems are listed: " .. table.concat(probs, " | "))
end }

T[#T + 1] = { "your reactions: where -- open world, dungeons by name (aliases, learned ones), and the window's line", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    assert_eq(C.where(), "world", "outside: the open world")
    go_to(G, "party", "The Deadmines", 36)
    local kind, name = C.where()
    assert_eq(kind, "dungeon", "a party instance is a dungeon")
    assert_eq(name, "The Deadmines", "by its name")
    assert_eq(C.where_text(), "Dungeon: The Deadmines", "the window's line")
    local env = C.fresh_env()
    assert(C.env_ok(env), "everywhere is fine")
    env.dungeon_pick = "Gnomeregan"
    assert(not C.env_ok(env), "only Gnomeregan: not here")
    env.dungeon_pick = "The Deadmines"
    assert(C.env_ok(env), "the Deadmines: here")
    go_to(G, "party", "Deadmines", 36)
    assert(C.env_ok(env), "an alias of the name")
    env.dungeon = false
    assert(not C.env_ok(env), "dungeons switched off")
    go_to(G, "party", "Zephras Depths", 2600)
    local places = C.places("dungeon")
    assert_eq(places[#places], "Zephras Depths", "an instance not in the list is learned and offered")
    go_to(G, "raid", "Molten Core", 409)
    assert_eq((C.where()), "raid", "a raid")
    -- A reaction held to one raid stays quiet elsewhere.
    local renv = C.fresh_env()
    renv.raid_pick = "Blackwing Lair"
    C.save({ name = "BWL only", importance = "survival", env = renv,
        conds = {}, actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } } })
    G.tick()
    assert_eq((G.sent("Ice Block")), 0, "in Molten Core: the Blackwing Lair reaction is off")
    go_to(G, "raid", "Blackwing Lair", 469)
    G.tick()
    assert_eq((G.sent("Ice Block")), 1, "in Blackwing Lair: on")
    assert(C.env_text(renv):find("Blackwing Lair", 1, true), "its place line names the raid: " .. C.env_text(renv))
end }

T[#T + 1] = { "the built-in reactions: one switched off, or held to some places, stays quiet; the master switch stops all but the Hardcore page's", function()
    local G = custom_bundle("ROGUE")
    G.items.potion = "Healing Potion"
    local C = G.C
    local function drink()
        G.used = {}
        G.hp, G.hp_rate = 0.2, -0.05
        G.rows = { G.row_for(G.target, { targeting_me = true }) }
        G.clock = G.clock + 3
        G.tick()
        return #G.used > 0
    end
    assert(drink(), "Emergency potion works as before")
    local found = false
    for _, d in ipairs(C.defaults()) do
        if d.name == "Emergency potion" then
            found = true
            assert(d.info and d.info ~= "", "it has a line for the window")
            assert(d.fired_n >= 1, "and its fired count")
        end
    end
    assert(found, "the defaults list has it")
    C.set_default_on("Emergency potion", false)
    assert(not drink(), "switched off: no potion")
    C.set_default_on("Emergency potion", true)
    local env = C.fresh_env()
    env.world = false
    C.set_default_env("Emergency potion", env)
    assert(not drink(), "held out of the open world: no potion here")
    go_to(G, "party", "Stratholme", 329)
    assert(drink(), "in a dungeon: the potion again")
    C.set_default_env("Emergency potion", nil)
    G.settings.react_active = false
    assert(not drink(), "the master switch off: no reaction at all")
    G.bail = true
    G.settings.hc_enabled = true
    G.tick()
    assert(G.verdict.halt == true, "but the Hardcore bail-out still holds the attacks (its own switch)")
end }

-- --- dungeons and the open world (1.78.0) ----------------------------------------------

local function row_named(C, name)
    for _, d in ipairs(C.defaults()) do
        if d.name == name then return d end
    end
    error("no built-in reaction named " .. name)
end

--- Would the engine let this built-in act where the bundle stands?
local function allowed(G, name)
    local def = G.React.engine.rule(name)
    assert(def, "the engine has " .. name)
    return G.React.engine.filter(def, { env = {} }) ~= false
end

T[#T + 1] = { "built-in reactions by place: the pet's taunt comes off in dungeons and raids, the rest act everywhere", function()
    local G = custom_bundle("HUNTER")
    local C = G.C
    local taunt = row_named(C, "Pet: taunt")
    assert_eq(taunt.world, true, "the taunt in the open world, as it comes")
    assert_eq(taunt.dungeon, false, "not in dungeons, as it comes")
    assert(taunt.shipped_why and taunt.shipped_why:find("tank", 1, true), "it says why: " .. tostring(taunt.shipped_why))
    assert_eq(taunt.mine, false, "nothing of yours yet")
    assert_eq(C.env_text(taunt.env), "Everywhere; not in Dungeons, Raids", "its Where line")
    local kick = row_named(C, "Interrupt")
    assert(kick.world and kick.dungeon and kick.env == nil, "Interrupt: everywhere, as it comes")

    assert(allowed(G, "Pet: taunt"), "outside: the taunt acts")
    assert_eq(row_named(C, "Pet: taunt").here, true, "and the window says so")
    go_to(G, "party", "The Deadmines", 36)
    assert(not allowed(G, "Pet: taunt"), "in the Deadmines: the taunt stays out")
    assert_eq(row_named(C, "Pet: taunt").here, false, "and the window says so")
    assert(allowed(G, "Interrupt"), "Interrupt acts in the dungeon")
    go_to(G, "raid", "Molten Core", 409)
    assert(not allowed(G, "Pet: taunt"), "nor in a raid")
    go_to(G, "pvp", "Warsong Gulch", 489)
    assert(allowed(G, "Pet: taunt"), "a battleground is not a dungeon")
end }

T[#T + 1] = { "built-in reactions by place: the columns switch one place, keep the rest, and are stored only when they differ", function()
    local G = custom_bundle("HUNTER")
    local C = G.C
    local b = C.bucket()
    -- The taunt switched on for dungeons (to solo one): raids stay as they come.
    C.set_default_place("Pet: taunt", "dungeon", true)
    local taunt = row_named(C, "Pet: taunt")
    assert(taunt.dungeon and taunt.mine, "on in dungeons, and marked as yours")
    assert_eq(taunt.env.raid, false, "raids untouched")
    go_to(G, "party", "The Deadmines", 36)
    assert(allowed(G, "Pet: taunt"), "it acts in the dungeon now")
    -- Back off: that is how it comes, so nothing is kept.
    C.set_default_place("Pet: taunt", "dungeon", false)
    assert_eq(b.defaults["Pet: taunt"], nil, "the same as it comes: no entry kept")
    assert_eq(row_named(C, "Pet: taunt").mine, false, "not marked as yours")

    -- A reaction everywhere, switched off in dungeons only.
    C.set_default_place("Interrupt", "dungeon", false)
    assert(not allowed(G, "Interrupt"), "off in the dungeon")
    go_to(G, "none")
    assert(allowed(G, "Interrupt"), "still on outside")
    assert_eq(C.env_text(row_named(C, "Interrupt").env), "Everywhere; not in Dungeons", "its Where line")

    -- One switched off everywhere (the 1.76.0 switch, kept by older saves) shows
    -- both columns off; a column then switches it on in that place alone.
    b.defaults["Stop the runner"] = { off = true }
    local runner = row_named(C, "Stop the runner")
    assert(not runner.world and not runner.dungeon and not runner.on, "off everywhere: both columns off")
    assert(not allowed(G, "Stop the runner"), "and the engine keeps it out")
    C.set_default_place("Stop the runner", "world", true)
    runner = row_named(C, "Stop the runner")
    assert(runner.world and not runner.dungeon, "on in the open world alone")
    assert_eq(C.env_text(runner.env), "Only: Open world", "nowhere else")
    assert(allowed(G, "Stop the runner"), "it acts outside")
    -- Both columns off and nothing else on: kept as switched off.
    C.set_default_place("Stop the runner", "world", false)
    assert(b.defaults["Stop the runner"].off == true and b.defaults["Stop the runner"].env == nil, "nowhere is kept as off")

    -- Where's own panel: everywhere for the taunt is kept, not mistaken for "as it comes".
    C.set_default_env("Pet: taunt", C.fresh_env())
    assert(row_named(C, "Pet: taunt").dungeon == true and b.defaults["Pet: taunt"], "everywhere, kept as yours")
    C.set_default_env("Pet: taunt", nil)
    assert(b.defaults["Pet: taunt"] == nil and row_named(C, "Pet: taunt").dungeon == false, "nil: back to how it comes")
end }

T[#T + 1] = { "built-in reactions by place: Reset puts one column back, or everything", function()
    local G = custom_bundle("HUNTER")
    local C = G.C
    local b = C.bucket()
    C.set_default_place("Interrupt", "dungeon", false)
    C.set_default_place("Interrupt", "world", false)
    C.set_default_place("Pet: taunt", "dungeon", true)
    b.defaults["Stop the runner"] = { off = true }
    assert_eq(C.reset_defaults("world"), 2, "two had the open world changed")
    local kick = row_named(C, "Interrupt")
    assert(kick.world and not kick.dungeon, "Interrupt: the open world back, dungeons as you set them")
    local runner = row_named(C, "Stop the runner")
    assert(runner.world and not runner.dungeon, "the switched-off one: back on in the open world only")
    assert_eq(row_named(C, "Pet: taunt").dungeon, true, "the taunt's dungeon switch is not the open world's")
    assert_eq(C.reset_defaults("dungeon"), 3, "three had dungeons changed")
    assert_eq(b.defaults["Interrupt"], nil, "Interrupt is as it comes again")
    assert_eq(b.defaults["Pet: taunt"], nil, "the taunt too: out of dungeons")
    assert_eq(C.reset_defaults("dungeon"), 0, "nothing left to reset there")
    C.set_default_place("Dispel", "world", false)
    assert(C.reset_defaults() >= 2, "everything: Dispel and the runner")
    assert_eq(next(b.defaults), nil, "nothing of yours left")
end }

T[#T + 1] = { "starter packs: a dungeon and an open world pack for the class, what each needs, and adding them", function()
    local G = custom_bundle("HUNTER")
    G.known["Feign Death"] = true
    local C = G.C
    assert(C.packs, "custom loads the packs")
    local packs = C.packs.list()
    assert_eq(#packs, 2, "two packs")
    assert_eq(packs[1].key, "dungeon", "dungeons first")
    assert_eq(packs[2].key, "world", "then the open world")
    local by_key = {}
    for _, it in ipairs(packs[1].items) do by_key[it.key] = it end
    assert(by_key.any_no_healer_drink and by_key.any_no_healer_drink.usable, "every class's: an item, always usable")
    assert(by_key.hunter_wipe_fd and by_key.hunter_wipe_fd.usable, "the hunter's Feign Death: known")
    local tranq = by_key.hunter_tranq
    assert(tranq and not tranq.usable and tranq.missing[1] == "Tranquilizing Shot", "Tranquilizing Shot is not learned")
    assert_eq(by_key.hunter_wipe_fd.where, "Only: Dungeons, Raids", "where it acts once added")

    local done = C.packs.add_all("dungeon")
    assert_eq(done.added, 2, "the two it can use")
    assert_eq(#done.waiting, 1, "one waits for its spell")
    assert_eq(#C.list(), 2, "they are in My reactions")
    local r = C.list()[2]
    assert_eq(r.name, "Wipe coming: Feign Death", "named as in the pack")
    assert(r.on and r.source and r.source.pack == "dungeon" and r.source.item == "hunter_wipe_fd", "switched on, and where it came from")
    assert(r.env.dungeon and r.env.raid and not r.env.world and not r.env.world_pvp, "held to dungeons and raids")
    assert(C.rule_of(r.id), "and in the engine")
    packs = C.packs.list()
    assert_eq(packs[1].added, 2, "the pack counts them as added")
    done = C.packs.add_all("dungeon")
    assert_eq(done.added, 0, "not added twice")
    assert_eq(done.already, 2, "both already there")
    local _, err = C.packs.add("dungeon", "hunter_wipe_fd")
    assert(err, "nor one at a time")

    -- Deleted: the pack offers it again. A name already taken gets a number.
    C.delete(r.id)
    C.save({ name = "Wipe coming: Feign Death", importance = "survival",
        conds = {}, actions = { { mode = "gui", kind = "spell", spell = "Feign Death", target = "self" } } })
    local id = C.packs.add("dungeon", "hunter_wipe_fd")
    assert(id, "added again once deleted")
    assert_eq(C.get(id).name, "Wipe coming: Feign Death (2)", "beside yours of the same name")

    -- Another class has its own; every class has the open world pack.
    local W = custom_bundle("WARLOCK")
    local wl = W.C.packs.list()
    local keys = {}
    for _, it in ipairs(wl[1].items) do keys[#keys + 1] = it.key end
    assert(table.concat(keys, ","):find("warlock_aggro_coil", 1, true), "the warlock's dungeon pack: " .. table.concat(keys, ","))
    assert(not table.concat(keys, ","):find("hunter", 1, true), "nothing of the hunter's")
    assert(#wl[2].items >= 2, "an open world pack")
end }

T[#T + 1] = { "starter packs: Wipe coming fires in a dungeon when the tank is dead, and never in the open world", function()
    local G = custom_bundle("HUNTER")
    G.known["Feign Death"] = true
    local C = G.C
    assert(C.packs.add("dungeon", "hunter_wipe_fd"), "added")
    local healer = unit(G, "healer", { name = "Priest", hostile = false })
    local fallen = unit(G, "tank", { name = "Warrior", hostile = false })
    fallen.dead = true
    G.group = { in_group = true, objects = { healer, fallen }, tanks = {}, healers = { healer } }
    G.rows = { G.row_for(G.target, { targeting_me = true, dist = 5 }) }
    G.tick()
    assert_eq((G.sent("Feign Death")), 0, "the open world: not its place")
    go_to(G, "party", "The Deadmines", 36)
    G.tick()
    assert_eq((G.sent("Feign Death")), 1, "in the dungeon, the tank dead and a mob on you: Feign Death")

    -- No roles set and nobody dead: no tank to read is not a dead tank.
    local H = custom_bundle("HUNTER")
    H.known["Feign Death"] = true
    assert(H.C.packs.add("dungeon", "hunter_wipe_fd"), "added")
    local mate = unit(H, "mate", { name = "Mage", hostile = false })
    H.group = { in_group = true, objects = { mate }, tanks = {}, healers = {} }
    H.rows = { H.row_for(H.target, { targeting_me = true, dist = 5 }) }
    go_to(H, "party", "The Deadmines", 36)
    H.tick()
    assert_eq((H.sent("Feign Death")), 0, "nobody dead: it waits")
end }

-- --- 1.79.0: more to react to, more to do, and saying why ------------------------------

local function gui(key, op, value, extra)
    local row = { mode = "gui", key = key, op = op, value = value }
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
end

local function holds(C, W, row)
    local ok, shown, err = C.eval_gui(row, W)
    return ok, shown, err
end

T[#T + 1] = { "1.79.0 conditions: seconds left and stacks, cooldowns, the target's target, running away, a key, an item, group health, time in combat", function()
    local G = custom_bundle("MAGE")
    local C = G.C
    G.auras.player = { [1] = { buff_name = "Ice Barrier", expire_time = (G.clock + 4) * 1000, count = 1 } }
    G.auras.mob = { [2] = { buff_name = "Sunder Armor", expire_time = (G.clock + 20) * 1000, count = 3 } }
    G.P.spellbook.cooldown = function(name) return name == "Frost Nova" and 4 or 0 end
    G.P.ctx.input = { is_key_pressed = function(vk) return vk == 0x46 end }
    G.P.hardcore.named = function(n) if n:lower() == "free action potion" then return 5634, "Free Action Potion" end end
    local tank = unit(G, "tank", { name = "Warrior", hostile = false })
    G.health.tank = 0.3
    G.group = { in_group = true, objects = { tank }, tanks = { tank }, healers = {} }
    G.P.ctx.group.lowest_health = function() return tank end
    G.P.ctx.group.count_below = function() return 2 end
    G.row = G.row_for(G.target, { activity = "fleeing", target_guid = "tank" })
    local near = unit(G, "near", { name = "Kobold" })
    G.rows = { G.row, G.row_for(near, { dist = 3 }) }
    G.tick()
    local W = C.latest_W()
    assert(W, "the picture")
    local ok, shown = holds(C, W, gui("me_buff_left", "<", "Ice Barrier", { num = 5 }))
    assert(ok and shown == "4s", "Ice Barrier has 4 s left, under 5: " .. tostring(shown))
    assert(not holds(C, W, gui("me_buff_left", "<", "Ice Barrier", { num = 3 })), "not under 3")
    assert(holds(C, W, gui("me_buff_left", "<", "Mana Shield", { num = 3 })), "a buff you lack has 0 s left")
    assert(holds(C, W, gui("t_debuff_stacks", ">=", "Sunder Armor", { num = 3 })), "three Sunders on the target")
    assert(not holds(C, W, gui("t_debuff_stacks", ">=", "Sunder Armor", { num = 5 })), "not five")
    assert(holds(C, W, gui("spell_cd", ">", "Frost Nova", { num = 3 })), "Frost Nova has 4 s of cooldown")
    assert(holds(C, W, gui("t_fleeing", "is")), "the target runs")
    assert(holds(C, W, gui("t_on_tank", "is")), "the target hits the tank")
    assert(not holds(C, W, gui("t_on_healer", "is")), "not the healer")
    assert(holds(C, W, gui("key_held", "is", 0x46)), "F is held")
    assert(not holds(C, W, gui("key_held", "is", 0x47)), "G is not")
    local _, _, kerr = holds(C, W, gui("key_held", "is", 0))
    assert(kerr and kerr:find("no key", 1, true), "no key picked says so")
    assert(holds(C, W, gui("me_has_item", "is", "Free Action Potion")), "the potion is carried")
    assert(not holds(C, W, gui("me_has_item", "is", "Limited Invulnerability Potion")), "that one is not")
    assert(holds(C, W, gui("g_lowest", "<", 40)), "the lowest member is at 30%")
    assert(holds(C, W, gui("g_hurt", ">=", 2)), "two under half")
    assert(holds(C, W, gui("f_within8", "==", 1)), "one enemy within 8 yd")
    assert(holds(C, W, gui("t_name", "is", "defias pillager")), "the target's name, any case")
    G.clock = G.clock + 5
    G.tick()
    W = C.latest_W()
    local cok, cshown = holds(C, W, gui("me_combat_time", ">=", 4))
    assert(cok, "five seconds into the fight: " .. tostring(cshown))
    -- What each stands for in Lua, and in words.
    assert_eq(C.cond_code(gui("me_buff_left", "<", "Ice Barrier", { num = 3 })), 'buff_left("Ice Barrier") < 3', "a name and a number")
    assert_eq(C.cond_code(gui("key_held", "is", 0x46)), "key(0x46)", "a key")
    assert(C.cond_text(gui("me_hp", "<", 40, { for_s = 1.5 })):find("for 1.5s", 1, true), "a timer in words")
end }

T[#T + 1] = { "1.79.0 hold for: a condition counts only once it has held long enough, and says how long is left", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local id = C.save({ name = "Low for a second", importance = "survival",
        conds = { gui("me_hp", "<", 30, { for_s = 1.0 }) },
        actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } } })
    G.hp = 0.2
    G.tick()
    assert_eq((G.sent("Ice Block")), 0, "just went low: it waits")
    local why = C.why(C.get(id))
    assert(why:find("must hold", 1, true), "why says it must hold longer: " .. why)
    G.run(0.5)
    assert_eq((G.sent("Ice Block")), 0, "half a second: still waiting")
    G.run(0.7)
    local went = G.sent("Ice Block")
    assert(went >= 1, "past a second: it goes")
    -- Back up and down again: the count starts over.
    G.hp = 0.9
    G.run(1.0)
    G.hp = 0.2
    G.clock = G.clock + 30
    G.tick()
    assert_eq((G.sent("Ice Block")), went, "low again: the second starts over")
end }

T[#T + 1] = { "1.79.0 instant actions: an alert and a target switch go at once, the spell after them still goes, the alert repeats only after its gap", function()
    local G = custom_bundle()
    G.known["Frost Nova"] = true
    local C = G.C
    local targeted = {}
    G.P.ctx.input = { set_target = function(_, u) targeted[#targeted + 1] = u return true end, cancel_spells = function() end }
    local add = unit(G, "add", { name = "Kobold" })
    G.rows = { G.row_for(G.target, { targeting_me = true }), G.row_for(add, { targeting_me = true, dist = 3 }) }
    local id = C.save({ name = "Swarmed", importance = "cc",
        conds = { gui("me_attackers", ">=", 2) },
        actions = { { mode = "gui", kind = "alert", text = "SWARMED", color = "red", sound = false },
                    { mode = "gui", kind = "target", who = "attacker" },
                    { mode = "gui", kind = "spell", spell = "Frost Nova", target = "self" } } })
    G.tick()
    assert_eq(#C.alerts, 1, "one alert on screen")
    assert_eq(C.alerts[1].text, "SWARMED", "its text")
    assert(targeted[1] == add, "the target switched to the add")
    assert_eq((G.sent("Frost Nova")), 1, "and Frost Nova still went: instant actions never end the list")
    -- Counted in the log: the history keeps the latest 15 fires, and Frost
    -- Nova (always ready here) fills it.
    local function count()
        local n = 0
        for _, l in ipairs(G.lines) do if l.text:find("alert: SWARMED", 1, true) then n = n + 1 end end
        return n
    end
    G.run(2.0)
    assert_eq(count(), 1, "two seconds on, still one alert (it repeats every 6 s)")
    G.run(4.5)
    assert_eq(count(), 2, "past 6 s, while it still holds: again")
    assert(C.reaction_code(C.get(id)):find("-- at once", 1, true), "the code says which go at once")
    -- Lua code can do the same.
    local L = custom_bundle()
    local Lid = L.C.save({ name = "Lua alert", importance = "utility", combat_only = false,
        conds = { gui("me_hp", "<", 50) },
        actions = { { mode = "lua", code = 'alert("LOW", "yellow", false)' } } })
    L.hp = 0.4
    L.tick()
    assert_eq(#L.C.alerts, 1, "alert() from Lua")
    assert_eq(L.C.history(Lid)[1].what, "Alert: LOW", "and kept in its history")
end }

T[#T + 1] = { "1.79.0 items by name: a trinket or any potion you carry, through the engine, off the global cooldown", function()
    local G = custom_bundle()
    local C = G.C
    local used = {}
    G.P.hardcore.named = function(n) if n:lower() == "earthstrike" then return 21180, "Earthstrike" end end
    G.P.hardcore.named_ready = function(n) return n:lower() == "earthstrike" end
    G.P.hardcore.use_named = function(n, why) used[#used + 1] = n return true end
    C.save({ name = "Trinket", importance = "offense", off_gcd = true, per_fight = 1,
        conds = { gui("t_hp", "<", 90) },
        actions = { { mode = "gui", kind = "named_item", name = "earthstrike" } } })
    G.health.mob = 0.5
    G.tick()
    assert_eq(#used, 1, "used once")
    assert_eq(used[1], "Earthstrike", "by the name the game spells")
    G.clock = G.clock + 30
    G.tick()
    assert_eq(#used, 1, "once a fight")
    local missing = C.save({ name = "Nothing", importance = "offense", conds = {},
        actions = { { mode = "gui", kind = "named_item", name = "Lifestone" } } })
    G.tick()
    local slot = C.runtime(missing).actions[C.get(missing).actions[1].uid]
    assert(slot and slot.note:find("not carried", 1, true), "an item you lack says so: " .. tostring(slot and slot.note))
end }

T[#T + 1] = { "1.79.0 limits and word: at most once a fight, an alert when it goes, and again next fight", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local id = C.save({ name = "Panic", importance = "survival", per_fight = 1, notify_alert = true,
        conds = { gui("me_hp", "<", 30) },
        actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } } })
    G.hp = 0.2
    G.tick()
    assert_eq((G.sent("Ice Block")), 1, "it went")
    assert_eq(C.alerts[1] and C.alerts[1].text, "Panic: Ice Block", "the alert says what went")
    local h = C.history(id)[1]
    assert(h and h.what == "Ice Block" and h.hp == 20, "the history keeps it, with your health")
    assert(h.reads:find("20%", 1, true), "and what its conditions read: " .. tostring(h.reads))
    G.clock = G.clock + 10
    G.tick()
    assert_eq((G.sent("Ice Block")), 1, "once this fight")
    assert(C.why(C.get(id)):find("Used 1 of its 1", 1, true), "why says so: " .. C.why(C.get(id)))
    G.in_combat = false
    G.tick()
    G.in_combat = true
    G.clock = G.clock + 1
    G.tick()
    assert_eq((G.sent("Ice Block")), 2, "a new fight: again")
end }

T[#T + 1] = { "1.79.0 why not: switched off, not here, which condition and what it read, and just went out", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local env = C.fresh_env()
    for _, k in ipairs({ "world", "world_pvp", "bg", "arena", "raid" }) do env[k] = false end
    local id = C.save({ name = "Dungeon only", importance = "survival", env = env,
        conds = { gui("me_hp", "<", 30) },
        actions = { { mode = "gui", kind = "spell", spell = "Ice Block", target = "self" } } })
    G.hp = 0.6
    G.tick()
    local text, tone = C.why(C.get(id))
    assert(text:find("Not here", 1, true) and tone == "off", "outside: not here: " .. text)
    go_to(G, "party", "The Deadmines", 36)
    G.tick()
    text, tone = C.why(C.get(id))
    assert(text:find("Condition 1 does not hold", 1, true) and text:find("60%", 1, true) and tone == "wait",
        "in the dungeon at 60%: the condition and its reading: " .. text)
    G.hp = 0.2
    G.tick()
    text, tone = C.why(C.get(id))
    assert(text:find("Just went out", 1, true) and tone == "ok", "it went: " .. text)
    C.set_on(id, false)
    assert_eq((C.why(C.get(id))), "Switched off.", "switched off")
end }

T[#T + 1] = { "1.79.0 test bench: a reaction against a made-up situation says what it would do, without casting", function()
    local G = custom_bundle()
    G.known["Ice Block"] = true
    local C = G.C
    local r = { name = "Panic", importance = "survival", match = "all", env = C.fresh_env(), combat_only = true,
        conds = { gui("me_hp", "<", 30, { uid = 1 }), { mode = "lua", code = "fight.on_me >= 2", uid = 2 } },
        actions = { { mode = "gui", kind = "alert", text = "PANIC", uid = 3 },
                    { mode = "gui", kind = "spell", spell = "Ice Block", target = "self", uid = 4 } } }
    local presets = {}
    for _, p in ipairs(C.D.BENCH_PRESETS) do presets[p.key] = p.s end
    local res = C.bench(r, presets.panic)
    assert(res.pass, "low health, two on me: it holds")
    assert_eq(res.sends, "Ice Block on you", "it would send Ice Block on you")
    assert(res.verdict:find("Alert: PANIC", 1, true) and res.tone == "ok", "and the alert: " .. res.verdict)
    assert_eq(res.conds[1].shown, "22%", "the health it read")
    assert_eq(res.conds[2].ok, true, "the Lua condition reads the made-up fight")
    assert_eq(#C.alerts, 0, "nothing was shown for real")
    assert_eq((G.sent("Ice Block")), 0, "nothing was cast")
    res = C.bench(r, presets.calm)
    assert(not res.pass and res.verdict:find("do not hold", 1, true), "all fine: nothing goes: " .. res.verdict)
    res = C.bench(r, presets.idle)
    assert(res.verdict:find("only in combat", 1, true), "out of combat, for an in-combat one: " .. res.verdict)
    r.env.world = false
    res = C.bench(r, presets.panic)
    assert(res.verdict:find("Not here", 1, true), "held out of the open world: " .. res.verdict)
    -- The dungeon pack's Wipe coming, in the dungeon situation.
    G.known["Feign Death"] = true
    local wipe = C.packs.draft("dungeon", "hunter_wipe_fd", "HUNTER")
    for i, row in ipairs(wipe.conds) do row.uid = i end
    for i, row in ipairs(wipe.actions) do row.uid = 10 + i end
    res = C.bench(wipe, presets.wipe)
    assert_eq(res.sends, "Feign Death on you", "the tank dead in a dungeon: Feign Death")
    -- An item you name, carried in the situation.
    local trinket = { name = "T", conds = {}, env = C.fresh_env(), combat_only = false,
        actions = { { mode = "gui", kind = "named_item", name = "Earthstrike", uid = 1 } } }
    local s = C.copy(presets.calm)
    s.items = "Earthstrike, Hearthstone"
    assert_eq(C.bench(trinket, s).sends, "Earthstrike", "carried in the situation: used")
end }

T[#T + 1] = { "1.79.0 sharing keeps the new fields: timers, a name and a number, keys, alerts, target switches, items, limits", function()
    local G = custom_bundle(nil, { json = require("jcore/lib/json") })
    local C = G.C
    local r = { name = "Everything", importance = "utility", priority = 60, per_fight = 2, notify_alert = true,
        notify_sound = true, match = "all", env = C.fresh_env(),
        conds = { gui("me_hp", "<", 40, { for_s = 1.5 }), gui("me_buff_left", "<", "Ice Barrier", { num = 3 }),
                  gui("key_held", "is", 0x46) },
        actions = { { mode = "gui", kind = "alert", text = "GO", color = "green", sound = false },
                    { mode = "gui", kind = "target", who = "lowest" },
                    { mode = "gui", kind = "named_item", name = "Earthstrike" } } }
    local text = C.share.encode(r, "MAGE")
    local items = C.share.decode(text, "MAGE")
    local back = items[1].r
    assert_eq(back.per_fight, 2, "the limit")
    assert(back.notify_alert and back.notify_sound, "the alert and the sound when it goes")
    assert_eq(back.conds[1].for_s, 1.5, "the timer")
    assert_eq(back.conds[2].num, 3, "the number with the name")
    assert_eq(back.conds[3].value, 0x46, "the key")
    assert_eq(back.actions[1].text, "GO", "the alert's text")
    assert_eq(back.actions[1].color, "green", "its colour")
    assert_eq(back.actions[1].sound, false, "no sound")
    assert_eq(back.actions[2].who, "lowest", "whom to target")
    assert_eq(back.actions[3].name, "Earthstrike", "the item")
end }

return T

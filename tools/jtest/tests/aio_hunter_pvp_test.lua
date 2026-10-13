-- Jambix AIO: the PvP hunter's reactions (1.7.6, ALPHA/TEST) --
-- react/rules/hunter_pvp.lua and modules/pvphunter.lua, driven through the
-- reaction engine with a scripted clock. The bundle is aio_pvp_test's, with
-- a hunter and the PvP hunter switched on.
--
-- What these hold it to: nothing at all with the switch off or outside a
-- fight with a player; a player in melee is clipped first, and once the clip
-- has not shaken it (or it ignores slows) the trap goes at your feet --
-- never onto a player something of ours ticks on, and not while the pet's
-- next bite would break it; a scattered player beside you wakes in the trap;
-- Feign Death meets a Polymorph in its last moment; a player attacking you
-- while you shoot a mob becomes your target.
--
-- At the end, the other hunter reactions a test of this kind holds
-- (react/rules/hunter.lua): Beast Mastery's move of the target to a mob still
-- without its Serpent Sting (the AOE melee weave's, 1.7.6; 1.8.1), and
-- Disengage when hit (1.8.1).

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function fresh(module)
    for k in pairs(package.loaded) do
        if k:find("^jambix_aio/modules/react") or k == module then package.loaded[k] = nil end
    end
    return require(module)
end

-- --- the bundle --------------------------------------------------------------------

local function unit(G, guid, fields)
    fields = fields or {}
    local u = {
        guid = guid, name = fields.name or guid, dead = false, level = 60, classification = 0,
        player = fields.player == true,
    }
    u.hostile = fields.hostile ~= false
    function u.is_valid() return true end
    function u.is_dead() return u.dead end
    function u.get_guid() return u.guid end
    function u.get_level() return u.level end
    function u.get_classification() return u.classification end
    function u.is_player() return u.player end
    function u.is_boss() return false end
    function u.get_name() return u.name end
    function u.get_npc_id() return 0 end
    function u.is_tap_denied() return false end
    G.by_guid[guid] = u
    return u
end

local function bundle(opts)
    opts = opts or {}
    local G = {
        clock = 1000.0,
        settings = { react_enabled = true, rot_hunter_pvp_alpha = true },
        casts = {}, pet_casts = {}, used = {}, named_used = {}, handlers = {}, switched = {},
        known = {}, unready = {}, blocked = {}, ids = {}, names = {}, next_id = 1000,
        hp = 1.0, hp_rate = 0, in_combat = true, moving = false, power = 80, power_max = 100,
        rows = {}, row = nil, health = {}, by_guid = {}, auras = {}, items = {}, carried = {},
        slots = {}, schools = {}, loc = nil, cast_remaining = 0, context = "solo",
        group = { in_group = false }, armed = {}, catalog = {}, roles = {}, distance = 5,
        pet_alive = false, pet_known = {}, form = nil,
        cooldowns = { ["Freezing Trap"] = true, ["Frost Trap"] = true, ["Scatter Shot"] = true,
                      ["Intimidation"] = true, ["Deterrence"] = true, ["Feign Death"] = true },
    }

    _G.core = {
        time = function() return G.clock end,
        game_time = function() return G.clock * 1000 end,
        spell_book = { is_item_usable = function() return true end },
        quests = { get_item_spell = function() return {} end },
    }

    G.player = unit(G, "player", { name = "Me", hostile = false })
    function G.player.can_attack(_, other) return other ~= nil and other.hostile == true end
    function G.player.get_item_at_inventory_slot(_, slot)
        local item = G.slots[slot]
        if not item then return {} end
        return { object = {
            get_item_id = function() return item.id end,
            get_name = function() return item.name end,
        } }
    end
    G.target = unit(G, "Player-1-00000001", { name = "Enemy", player = true })

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
        log = { fmt = function() end, once = function() end, info = function() end, debug = function() end,
                warn = function() end, error = function() end },
        load = function(path) return require("jambix_aio/" .. path) end,
        opt = function(id, default)
            local v = G.settings[id]
            if v == nil then return default end
            return v
        end,
        tune = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
        derived = function(_, default) return default / 100 end,
        key_armed = function(id) return G.armed[id] == true end,
        loc_types = { FEAR = 5, STUN = 6, ROOT = 8 },
        enums = { buff_type = { MAGIC = 1, CURSE = 2, DISEASE = 3, POISON = 4 },
                  spell_schools_flags = { Physical = 1 } },
        ctx = {
            id = "jambix.aio",
            on = function(event, fn)
                G.handlers[event] = G.handlers[event] or {}
                table.insert(G.handlers[event], fn)
            end,
            emit = function() end,
            render = function() end,
            cast = function(request)
                request.owner = "jambix.aio"
                G.casts[#G.casts + 1] = request
                local name = G.names[request.spell_id]
                if name and G.cooldowns[name] then G.unready[name] = true end
            end,
            PRIORITY = { IDLE = 10, FILLER = 30, ROTATION = 50, COOLDOWN = 70, UTILITY = 100,
                         INTERRUPT = 150, DEFENSIVE = 200, EMERGENCY = 255 },
            LAYER = { HUD = 500 },
            spells = {
                name = function(id) return G.names[id] or "" end,
                info = function(id) return { school = G.schools[G.names[id] or ""] or 0 } end,
            },
            player = {
                casting_spell_id = function() return nil end,
                is_channelling = function() return false end,
                loss_of_control = function() return G.loc end,
                level = function() return 60 end,
            },
            group = {
                in_group = function() return false end,
                in_raid = function() return false end,
                size = function() return 0 end,
                objects = function() return {} end,
                tanks = function() return {} end,
                healers = function() return {} end,
                is_tank = function() return false end,
            },
            threat = {
                closest_to_pulling = function() return nil, 0 end,
                holding = function() return 0 end,
                mine = function() return nil, 2, 3, false end,
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
            distance = function(u) return G.dist and G.dist[u.guid] or 5 end,
            position = function(u) return { x = 1, y = 2, z = 3, of = u.guid } end,
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
            fight_left = function() return 20 end,
            power_empty = function() return math.huge end,
        },
        hardcore = {
            should_stop_fighting = function() return false end,
            item = function(kind)
                if G.items[kind] then return 5000, G.items[kind] end
                return nil
            end,
            use_item = function(kind) G.used[#G.used + 1] = kind return true end,
            named = function(name)
                if G.carried[name] then return G.carried[name], name end
                return nil
            end,
            named_ready = function(name)
                if not G.carried[name] then return false, "not carried" end
                if G.item_cd and G.item_cd[name] then return false, "on its cooldown" end
                return true
            end,
            use_named = function(name) G.named_used[#G.named_used + 1] = name return true end,
        },
        targeting = {
            context = function() return G.context end,
            switch_to = function(u) G.switched[#G.switched + 1] = u return true end,
        },
        sense = {
            pvp_active = function() return true end,
            stealth_suspected = function() return G.suspected == true, "Sneaky" end,
        },
        forms = { current = function() return G.form end },
        catalog = {
            ability = function(name) return G.catalog[name] end,
            with_role = function(role) return G.roles[role] or {} end,
        },
    }
    P.field = { state = setmetatable({}, { __index = function(_, k)
        local map = { plan = "BURN", shape = "SINGLE", reason = "", count = 1, inbound = 0, elites = 0,
                      escalating = false, time_to_live = math.huge, time_to_clear = 10 }
        return map[k]
    end }) }
    P.pet = {
        OFF = 1, ASSIST = 2, TANK = 3, FOCUS = 4,
        pet = function() return G.pet_alive and G.pet or nil end,
        hp_rate = function() return 0 end,
        pet_target = function() return G.pet_on end,
        mode = function() return 2 end,
        knows = function(n) return G.pet_known[n] == true end,
        cast = function(n, t) G.pet_casts[#G.pet_casts + 1] = { name = n, target = t } return true end,
        spell_id = function() return 900 end,
        growl_wanted = function() return false end,
    }
    P.rotation = {
        helpers = {
            key_allows = function() return true end,
            escape_target = function(_, s) return s.player end,
            channel_active = function() return false end,
        },
        press_blocked = function(name) return G.blocked[name] end,
        active_class = function() return G.class end,
    }
    -- What the hunter's PvP rules read off the rotation's helpers.
    P.rotation.helpers.debuff_up = function(u, name)
        for _, a in pairs(G.auras[u and u.guid or ""] or {}) do
            if a.buff_name == name then return true end
        end
        return false
    end
    P.rotation.helpers.since_cast = function(name) return G.since and G.since[name] or math.huge end
    P.combat = { target = function() return G.target_present ~= false and G.target or nil end }
    P.ctx.enemies = { all = function() return G.rows end }
    G.P = P

    G.class = opts.class or {
        key = "hunter", class_name = "HUNTER", power = "MANA",
        interrupts = {}, defensives = { "Feign Death", "Deterrence" }, escapes = {},
    }
    G.profile = { label = "Test", rules = {}, power = G.class.power }
    G.pet = unit(G, "pet", { name = "Felhunter", hostile = false })
    P.ctx.world = { client = function() return { forever = false, combat_log = true } end }
    package.loaded["jambix_aio/modules/pvphunter"] = nil
    P.pvphunter = require("jambix_aio/modules/pvphunter")(P)
    P.ctx.react = require("jcore/services/react")({}).for_owner("jambix.aio", P.ctx)
    G.React = fresh("jambix_aio/modules/react/init")(P)
    P.react = G.React

    function G.fire(event, data)
        for _, fn in ipairs(G.handlers[event] or {}) do fn(data) end
    end

    function G.snapshot()
        local on_me = 0
        for i = 1, #G.rows do if G.rows[i].targeting_me then on_me = on_me + 1 end end
        return {
            player = G.player, target = G.target_present ~= false and G.target or nil,
            hp = G.hp, thp = G.health[G.target.guid] or 1, in_combat = G.in_combat, ttd = 20,
            power = G.power, power_max = G.power_max, posture = "HEALTHY", moving = G.moving,
            hold_fire = false, enemies = G.rows, enemy_count = #G.rows,
            target_row = G.row, on_me = on_me, closing = 0, distance = G.distance,
            can = {},
        }
    end

    function G.tick()
        G.verdict = G.React.tick(G.class, G.profile, G.snapshot())
        return G.verdict
    end

    function G.run(seconds)
        for _ = 1, math.floor(seconds * 10 + 0.5) do
            G.clock = G.clock + 0.1
            G.tick()
        end
    end

    function G.sent(name)
        local n = 0
        for i = 1, #G.casts do
            if G.names[G.casts[i].spell_id] == name then n = n + 1 end
        end
        return n
    end

    function G.used_named(name)
        local n = 0
        for i = 1, #G.named_used do if G.named_used[i] == name then n = n + 1 end end
        return n
    end

    --- An aura row as the client's buff list gives it.
    function G.aura(guid, name, seconds, fields)
        G.auras[guid] = G.auras[guid] or {}
        local id = (fields and fields.id) or id_of("aura:" .. name)
        G.auras[guid][id] = {
            buff_id = id, buff_name = name,
            expire_time = seconds and (G.clock + seconds) * 1000 or 0,
            caster = fields and fields.caster or nil,
        }
    end

    --- An enemies row.
    function G.row_for(u, fields)
        local r = {
            obj = u, guid = u.guid, dist = 5, engaged = true, targeting_me = true,
            targeting_pet = false, control = nil, activity = "attacking", closing = 0, hp = 1,
        }
        for k, v in pairs(fields or {}) do r[k] = v end
        return r
    end

    function G.casting(spell, remaining, total)
        local id = id_of(spell)
        return {
            spell_id = id, channel = false,
            start_at = (G.clock - ((total or 3) - remaining)) * 1000,
            end_at = (G.clock + remaining) * 1000,
            interruptible = true,
        }
    end

    --- A trinket worn in a slot, carried by its name.
    function G.wear(slot, id, name)
        G.slots[slot] = { id = id, name = name }
        G.carried[name] = id
    end

    -- A player on you in melee, as the default fight.
    G.row = G.row_for(G.target)
    G.rows = { G.row }
    return G
end

local T = {}

local ROGUE, PALADIN = 4, 2

--- An enemy rogue in melee with you, on you.
local function rogue(G)
    G.target.get_class = function() return ROGUE end
    G.row.dist = 3
    G.known["Wing Clip"], G.known["Freezing Trap"], G.known["Scatter Shot"] = true, true, true
end

T[#T + 1] = { "off: with the switch off, a rogue in melee gets nothing from these", function()
    local G = bundle()
    G.settings.rot_hunter_pvp_alpha = false
    rogue(G)
    G.tick()
    assert_eq(G.sent("Wing Clip") + G.sent("Freezing Trap") + G.sent("Scatter Shot"), 0, "nothing")
    assert_eq(G.P.pvphunter.mode(), false, "and no PvP mode")
end }

T[#T + 1] = { "mode: a player target is PvP; it holds 4 s past the last sign, then lets go", function()
    local G = bundle()
    local on, why = G.P.pvphunter.mode()
    assert_eq(on, true, "your target is a player")
    assert(tostring(why):find("your target is Enemy", 1, true), "and says so: " .. tostring(why))
    G.target_present, G.rows = false, {}
    G.clock = G.clock + 2
    assert_eq(G.P.pvphunter.mode(), true, "2 s later: still on")
    G.clock = G.clock + 3
    assert_eq(G.P.pvphunter.mode(), false, "5 s later: off")
    local mob = unit(G, "Creature-0-1-2-3-4-5", { name = "Wolf" })
    G.rows = { G.row_for(mob) }
    G.clock = G.clock + 1
    assert_eq(G.P.pvphunter.mode(), false, "a mob on you is no PvP")
    local p2 = unit(G, "Player-1-00000009", { name = "Ganker", player = true })
    G.rows[2] = G.row_for(p2, { dist = 30 })
    G.clock = G.clock + 1
    on, why = G.P.pvphunter.mode()
    assert_eq(on, true, "a player on you is")
    assert(tostring(why):find("Ganker is on you", 1, true), "and says who: " .. tostring(why))
end }

T[#T + 1] = { "foe: the class, a druid's form, the healer it is seen to be", function()
    local G = bundle()
    local pvp = G.React.pvp
    G.target.get_class = function() return 11 end
    local f = pvp.foe(G.target)
    assert_eq(f.role, "caster", "a druid out of form")
    assert(f.mana and f.stealth, "a mana user that can prowl")
    G.aura(G.target.guid, "Cat Form", nil)
    G.clock = G.clock + 0.1
    f = pvp.foe(G.target)
    assert_eq(f.role, "melee", "in Cat Form")
    assert(not f.mana, "no mana to drain in Cat Form")
    G.target.get_class = function() return PALADIN end
    local paladin = unit(G, "Player-1-00000005", { name = "Pally", player = true })
    paladin.get_class = function() return PALADIN end
    assert_eq(pvp.foe(paladin).role, "melee", "a paladin is melee until seen healing")
    local row = G.row_for(paladin, { dist = 20, targeting_me = false })
    row.casting = G.casting("Holy Light", 1.5, 2.5)
    G.rows[2] = row
    G.tick()
    G.clock = G.clock + 0.1
    assert_eq(pvp.foe(paladin).role, "healer", "seen casting Holy Light")
    assert_eq(pvp.foe_text(pvp.foe(paladin)), "Paladin (healer)", "the readout")
end }

T[#T + 1] = { "peel: a rogue in melee, not slowed: Wing Clip first", function()
    local G = bundle()
    rogue(G)
    G.tick()
    assert_eq(G.sent("Wing Clip"), 1, "clipped")
    assert_eq(G.sent("Freezing Trap"), 0, "the trap is kept")
end }

T[#T + 1] = { "peel: clipped and still on you 1.5 s later: Freezing Trap at your feet", function()
    local G = bundle()
    rogue(G)
    G.aura(G.target.guid, "Wing Clip", 8)
    G.tick()
    assert_eq(G.sent("Freezing Trap"), 0, "just clipped: give it a moment")
    G.run(1.6)
    assert_eq(G.sent("Freezing Trap"), 1, "the clip did not shake it: trapped")
    local last = G.casts[#G.casts]
    assert(last.target == G.player, "laid at your feet")
end }

T[#T + 1] = { "peel: something of ours ticking on it: no trap, Scatter Shot instead", function()
    local G = bundle()
    rogue(G)
    G.aura(G.target.guid, "Wing Clip", 8)
    G.aura(G.target.guid, "Serpent Sting", 15)
    G.run(1.8)
    assert_eq(G.sent("Freezing Trap"), 0, "the sting would break it")
    assert_eq(G.sent("Scatter Shot"), 1, "scattered")
end }

T[#T + 1] = { "peel: the pet on it: Intimidation before the trap its bite would break", function()
    local G = bundle()
    rogue(G)
    G.known.Intimidation = true
    G.pet_alive, G.pet_on = true, G.target
    G.aura(G.target.guid, "Wing Clip", 8)
    G.run(1.8)
    assert_eq(G.sent("Intimidation"), 1, "stunned by the pet")
    assert_eq(G.sent("Freezing Trap"), 0, "no trap under the pet's bite")
end }

T[#T + 1] = { "peel: hurt with a rogue on you and nothing else ready: Deterrence, once (the core defensive)", function()
    local G = bundle()
    rogue(G)
    G.known["Freezing Trap"], G.known["Scatter Shot"] = nil, nil
    G.known.Deterrence = true
    G.aura(G.target.guid, "Wing Clip", 8)
    G.hp = 0.35
    G.run(0.5)
    assert_eq(G.sent("Deterrence"), 1, "Deterrence")
end }

T[#T + 1] = { "peel: Blessing of Freedom (ignores slows): straight to the trap, no clip", function()
    local G = bundle()
    rogue(G)
    G.target.get_class = function() return PALADIN end
    G.aura(G.target.guid, "Blessing of Freedom", 10)
    G.tick()
    assert_eq(G.sent("Wing Clip"), 0, "a clip would do nothing")
    assert_eq(G.sent("Freezing Trap"), 1, "trapped")
end }

T[#T + 1] = { "scatter into the trap: a scattered player beside you wakes in the trap", function()
    local G = bundle()
    G.known["Freezing Trap"] = true
    G.row.dist = 3
    G.row.targeting_me = false
    G.aura(G.target.guid, "Scatter Shot", 3)
    G.tick()
    assert_eq(G.sent("Freezing Trap"), 1, "the trap under it")
    local kind, left = G.P.pvphunter.held(G.target)
    assert_eq(kind, "scatter", "pvphunter reads our Scatter Shot")
    assert(left > 2.5 and left <= 3, "with its time left")
end }

T[#T + 1] = { "Feign Death: a Polymorph at you is met in its last moment, not before", function()
    local G = bundle()
    G.known["Feign Death"] = true
    G.row.dist = 25
    G.row.casting = G.casting("Polymorph", 1.2, 1.5)
    G.tick()
    assert_eq(G.sent("Feign Death"), 0, "1.2 s out: not yet")
    G.row.casting = G.casting("Polymorph", 0.5, 1.5)
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.sent("Feign Death"), 1, "0.5 s out: feigned")
end }

T[#T + 1] = { "Feign Death: a Frostbolt only when hurt", function()
    local G = bundle()
    G.known["Feign Death"] = true
    G.row.dist = 25
    G.row.casting = G.casting("Frostbolt", 0.4, 2.5)
    G.tick()
    assert_eq(G.sent("Feign Death"), 0, "a Frostbolt at full health: taken")
    G.hp = 0.4
    G.row.casting = G.casting("Frostbolt", 0.4, 2.5)
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.sent("Feign Death"), 1, "at 40%: feigned")
end }

T[#T + 1] = { "turn: shooting a mob, a player attacks you: it becomes the target", function()
    local G = bundle()
    local ganker = unit(G, "Player-1-00000002", { name = "Ganker", player = true })
    local mob = unit(G, "Creature-0-1-2-3-4-5", { name = "Wolf" })
    G.target = mob
    G.health[mob.guid] = 0.8
    G.row = G.row_for(mob, { dist = 20, targeting_me = false })
    G.rows = { G.row, G.row_for(ganker, { dist = 10 }) }
    G.tick()
    assert_eq(#G.switched, 1, "one switch")
    assert(G.switched[1] == ganker, "to the player")
    -- Its option went (2026-10-10: the PvP hunter is one option); a value
    -- it saved changes nothing.
    G.settings.rot_hunter_pvp_turn = false
    G.target, G.switched = mob, {}
    G.clock = G.clock + 5
    G.tick()
    assert_eq(#G.switched, 1, "the old option saved off: still turned")
end }

T[#T + 1] = { "trapped: pvphunter reads the trap, and the kite walks 25 yd from it (no option now)", function()
    local G = bundle()
    G.aura(G.target.guid, "Freezing Trap Effect", 9)
    G.tick()
    local kind, left = G.P.pvphunter.held(G.target)
    assert_eq(kind, "trap", "our trap")
    assert(left > 8, "nine seconds left")
    assert_eq(G.P.pvphunter.reset_to(G.target), 25, "walk 25 yd")
    G.settings.rot_hunter_pvp_reset = 11              -- saved by the slider that went
    assert_eq(G.P.pvphunter.reset_to(G.target), 25, "still 25: the slider is gone")
    G.settings.rot_hunter_pvp_reset = nil
    G.aura(G.target.guid, "Freezing Trap Effect", 2)
    assert_eq(G.P.pvphunter.reset_to(G.target), nil, "two seconds left: no walk worth starting")
end }

T[#T + 1] = { "trapped: another player on you becomes the target while the trap holds", function()
    local G = bundle()
    G.aura(G.target.guid, "Freezing Trap Effect", 9)
    G.row.targeting_me = false
    local other = unit(G, "Player-1-00000003", { name = "Priest", player = true })
    G.rows[2] = G.row_for(other, { dist = 20 })
    G.tick()
    assert_eq(#G.switched, 1, "switched")
    assert(G.switched[1] == other, "to the one not frozen")
end }

T[#T + 1] = { "finish: another player at 15% while yours is at 80%, a shot of yours ready: switched", function()
    local G = bundle()
    G.known["Arcane Shot"] = true            -- the kill window (Stage 9) asks for something to finish it with
    G.row.targeting_me = false
    G.row.dist = 25
    G.health[G.target.guid] = 0.8
    local low = unit(G, "Player-1-00000004", { name = "Low", player = true })
    G.rows[2] = G.row_for(low, { dist = 25, targeting_me = false, hp = 0.15 })
    G.tick()
    assert_eq(#G.switched, 1, "switched")
    assert(G.switched[1] == low, "to the low one")
end }

T[#T + 1] = { "finish: the kill window decides when the PvP layer reads one -- a low player it calls no kill (immune, healed) is left; one it calls a kill window is taken (Stage 9)", function()
    local G = bundle()
    G.row.targeting_me = false
    G.row.dist = 25
    G.health[G.target.guid] = 0.8
    local low = unit(G, "Player-1-00000004", { name = "Low", player = true })
    G.rows[2] = G.row_for(low, { dist = 25, targeting_me = false, hp = 0.15 })
    local kill = G.React.intel and G.React.intel.kill
    assert(kill and kill.for_guid, "the kill window is loaded")
    local orig = kill.for_guid
    kill.for_guid = function(g) if g == low.guid then return { v = "NO_KILL_OPPORTUNITY" } end return nil end
    G.tick()
    assert_eq(#G.switched, 0, "at 15% but no kill (its immunity, its healer): left alone")
    kill.for_guid = function(g) if g == low.guid then return { v = "HIGH_CONFIDENCE_KILL_WINDOW" } end return nil end
    G.clock = G.clock + 4
    G.tick()
    kill.for_guid = orig
    assert_eq(#G.switched, 1, "a kill window: switched")
    assert(G.switched[1] == low, "to it")
end }

T[#T + 1] = { "status: the class window's line says what it faces and what it last did", function()
    local G = bundle()
    rogue(G)
    G.tick()
    local line = G.P.pvphunter.status()
    assert(line:find("your target is Enemy", 1, true), line)
    assert(line:find("Rogue (melee)", 1, true), line)
    assert(line:find("last: Wing Clip on Enemy", 1, true), line)
    G.settings.rot_hunter_pvp_alpha = false
    assert_eq(G.P.pvphunter.status(), "PvP hunter (ALPHA/TEST): off", "off")
end }


-- --- Beast Mastery's stings (1.7.6 as the AOE melee weave's; 1.8.1) ---------------
-- The user: "renew as many Serpent stings on Multiple target in combat with
-- US!!! it can Swap through target automatically Aslong as its in combat with
-- us and Renew while we mvoe back in". Since 1.8.1 the rotation's spread
-- stings every mob of the fight straight onto it; out of melee, once the
-- target has its sting, a mob that has gone four seconds without one all the
-- same becomes the target.

--- A fight with three mobs on the pet, out of melee, Beast Mastery running.
--- The stings are read through the rotation's helper: G.stings[guid] = seconds.
local function bm_stings(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.class.weave_running = function() return G.weave ~= false end
    G.known["Serpent Sting"] = true
    G.stings = {}
    local h = G.P.rotation.helpers
    h.debuff_remaining = function(u, name)
        return name == "Serpent Sting" and (G.stings[u and u.guid or ""] or 0) or 0
    end
    h.in_melee = function(_, d) return (d or 5) <= 5 end
    h.gap = function(_, d) return d end
    G.target = unit(G, "Creature-0-1-2-3-4-1", { name = "Boar" })
    G.distance = 20
    G.row = G.row_for(G.target, { dist = 20, targeting_me = false, targeting_pet = true })
    local b = unit(G, "Creature-0-1-2-3-4-2", { name = "Bear" })
    local c = unit(G, "Creature-0-1-2-3-4-3", { name = "Cat" })
    G.rows = { G.row, G.row_for(b, { dist = 22, targeting_me = false, targeting_pet = true }),
               G.row_for(c, { dist = 18, targeting_me = false, targeting_pet = true }) }
    G.stings[G.target.guid] = 15
    return b, c
end

--- Four seconds of the rotation's own spread, then the reaction's turn.
local function past_the_grace(G)
    G.tick()
    G.clock = G.clock + 4.1
    G.tick()
end

T[#T + 1] = { "Beast Mastery stings: the rotation's spread first; after four seconds a mob still without one becomes the target", function()
    local G = bundle()
    local b, c = bm_stings(G)
    G.stings[b.guid] = 12
    G.tick()
    assert_eq(#G.switched, 0, "at once: the rotation stings it straight on, your target kept")
    G.clock = G.clock + 2
    G.tick()
    assert_eq(#G.switched, 0, "two seconds: still the spread's")
    G.clock = G.clock + 2.1
    G.tick()
    assert_eq(#G.switched, 1, "four seconds without one: one switch")
    assert(G.switched[1] == c, "to the one with no sting")
end }

T[#T + 1] = { "Beast Mastery stings: a mob stung meanwhile starts its wait again when its sting runs out", function()
    local G = bundle()
    local b, c = bm_stings(G)
    G.stings[b.guid] = 12
    G.tick()
    G.clock = G.clock + 3
    G.stings[c.guid] = 12                             -- the spread got it
    G.tick()
    G.clock = G.clock + 2
    G.stings[c.guid] = 0                              -- and it ran out again
    G.tick()
    assert_eq(#G.switched, 0, "a fresh wait, not the old one")
    G.clock = G.clock + 4.1
    G.tick()
    assert(G.switched[1] == c, "then the switch")
end }

T[#T + 1] = { "Beast Mastery stings: the least sting left goes first -- none before one running out; the nearest of equals", function()
    local G = bundle()
    local b, c = bm_stings(G)
    G.stings[b.guid], G.stings[c.guid] = 1.5, 0
    past_the_grace(G)
    assert(G.switched[1] == c, "no sting before one running out")

    local H2 = bundle()
    local _, c2 = bm_stings(H2)
    past_the_grace(H2)
    assert(H2.switched[1] == c2, "neither stung: the nearer (18 yd before 22)")

    local R = bundle()
    local b3 = bm_stings(R)
    R.stings[b3.guid] = 1.5
    R.rows[3].engaged, R.rows[3].targeting_pet = false, false   -- the cat is not fighting us
    past_the_grace(R)
    assert(R.switched[1] == b3, "running out: renewed")
end }

T[#T + 1] = { "Beast Mastery stings: nothing moves while the target still wants its own sting, in melee, in another profile, or with no mana", function()
    local G = bundle()
    bm_stings(G)
    G.stings[G.target.guid] = 0
    past_the_grace(G)
    assert_eq(#G.switched, 0, "the target first: the rotation stings it")

    local M = bundle()
    bm_stings(M)
    M.distance, M.row.dist = 3, 3
    past_the_grace(M)
    assert_eq(#M.switched, 0, "in melee: the burst's turn")

    local O = bundle()
    bm_stings(O)
    O.weave = false
    past_the_grace(O)
    assert_eq(#O.switched, 0, "another profile than Beast Mastery: nothing")

    local L = bundle()
    bm_stings(L)
    L.power = 10
    past_the_grace(L)
    assert_eq(#L.switched, 0, "a tenth of a bar: no sting is coming")
end }

T[#T + 1] = { "Beast Mastery stings: only mobs fighting you or the pet, in reach, outside the dead zone, not held, living for it", function()
    local function only(setup, label)
        local G = bundle()
        local b, c = bm_stings(G)
        G.stings[b.guid] = 12                         -- the bear is done: only the cat is asked about
        setup(G, G.rows[3], c)
        past_the_grace(G)
        assert_eq(#G.switched, 0, label)
    end
    only(function(_, r) r.engaged, r.targeting_pet = false, false end, "not in the fight: left alone")
    only(function(_, r) r.dist = 40 end, "out of a shot's reach")
    only(function(_, r) r.dist = 6 end, "inside the dead zone")
    only(function(_, r) r.control = { breaks = true, remaining = 8 } end, "held by control that damage breaks")
    only(function(G, _, c)
        G.P.combat.time_to_die = function(u) return u == c and 4 or 30 end
    end, "about to die: not worth a sting")
end }

-- --- Disengage when hit (1.8.1) ------------------------------------------------------
-- The user: "add a button Turn it on if being attacked to disengage".
-- Forever's Disengage is Classic's threat drop in melee range (its table's
-- one effect, as Era's), so a mob hitting you is handed back to the pet.

--- A mob of the fight hitting you in melee, the pet on it, Disengage known.
local function hit_by_mob(G)
    G.settings.rot_hunter_pvp_alpha = false
    G.known["Disengage"] = true
    local mob = unit(G, "Creature-0-1-2-3-4-9", { name = "Raptor" })
    G.target, G.distance = mob, 3
    G.row = G.row_for(mob, { dist = 3, targeting_me = true })
    G.rows = { G.row }
    G.pet_alive, G.pet_on = true, mob
    return mob
end

T[#T + 1] = { "Disengage when hit: off by default -- a mob hitting you in melee gets nothing", function()
    local G = bundle()
    hit_by_mob(G)
    G.run(1)
    assert_eq(G.sent("Disengage"), 0, "the switch off: never")
end }

T[#T + 1] = { "Disengage when hit: on, a mob hitting you in melee that the pet fights goes back to it -- once a cooldown", function()
    local G = bundle()
    local mob = hit_by_mob(G)
    G.settings.rot_hunter_disengage = true
    G.tick()
    assert_eq(G.sent("Disengage"), 1, "Disengage")
    assert(G.casts[#G.casts].target == mob, "on the mob hitting you")
    G.run(1)
    assert_eq(G.sent("Disengage"), 1, "once, not every tick")
end }

T[#T + 1] = { "Disengage when hit: never with nobody to take the mob, at range, on a player, or not trained", function()
    local function none(setup, label)
        local G = bundle()
        hit_by_mob(G)
        G.settings.rot_hunter_disengage = true
        setup(G)
        G.run(0.5)
        assert_eq(G.sent("Disengage"), 0, label)
    end
    none(function(G) G.pet_alive = false end, "no pet out, solo: the drop would leave it on you")
    none(function(G)
        G.pet_on = unit(G, "Creature-0-1-2-3-4-8", { name = "Other" })
    end, "the pet on another mob: nothing to hand it back to")
    none(function(G) G.row.dist, G.distance = 20, 20 end, "a mob at range: Disengage is melee")
    none(function(G)
        local p = unit(G, "Player-1-00000007", { name = "Rogue", player = true })
        G.target, G.row = p, G.row_for(p, { dist = 3, targeting_me = true })
        G.rows, G.pet_on = { G.row }, p
    end, "a player: threat means nothing to one")
    none(function(G) G.known["Disengage"] = nil end, "not trained")
end }

return T

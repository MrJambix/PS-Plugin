-- jtest / mock / intel_bundle -- the hand-built reaction bundle the PvP
-- intelligence tests drive: aio_hunter_pvp_test's, with the reads the
-- intel layer adds (positions, facing, a geometry service, the instance
-- type, the catalogue's ranges and role lists, the group's members).
-- Shared by aio_intel_state_test and aio_intel_threat_test.

if not jtest then package.path = "scripts/?.lua;" .. package.path end


local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function assert_near(got, want, tol, label)
    if type(got) ~= "number" or math.abs(got - want) > tol then
        error(string.format("%s: expected about %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local function has(text, piece, label)
    if type(text) ~= "string" or not text:find(piece, 1, true) then
        error(string.format("%s: %q not in %q", label or "line", piece, tostring(text)), 2)
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
        cooldowns = {},
        me_pos = { x = 0, y = 0, z = 0 }, pos = {}, instance = "none", instance_name = "",
        members = {}, tank = nil, healer = nil, sight = nil, sight_calls = 0, ranges = nil,
    }

    _G.core = {
        time = function() return G.clock end,
        game_time = function() return G.clock * 1000 end,
        spell_book = { is_item_usable = function() return true end },
        quests = { get_item_spell = function() return {} end },
    }

    G.player = unit(G, "player", { name = "Me", hostile = false })
    function G.player.can_attack(_, other) return other ~= nil and other.hostile == true end
    function G.player.get_item_at_inventory_slot() return {} end
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

    local client = opts.client or { forever = false, combat_log = true }

    local P = {
        log = { fmt = function() end, once = function() end, info = function() end, debug = function() end,
                warn = function() end, error = function() end },
        load = function(path)
            -- The shipped central address (modules/central_config.lua) is
            -- the machine's own, git-ignored: the tests see only what they
            -- set (opts.shipped_central), never the real token.
            if path == "modules/central_config" then return opts.shipped_central end
            return require("jambix_aio/" .. path)
        end,
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
                rotation = function() return G.me_rotation or 0 end,
                is_moving = function() return G.moving end,
                movement_speed = function() return G.moving and 7 or 0 end,
                focus = function() return G.focus end,
                mouseover = function() return nil end,
            },
            group = {
                in_group = function() return G.group.in_group end,
                in_raid = function() return false end,
                size = function() return #G.members end,
                objects = function() return G.members end,
                tanks = function() return G.tank and { G.tank } or {} end,
                healers = function() return G.healer and { G.healer } or {} end,
                is_tank = function(u) return u == G.tank end,
                is_healer = function(u) return u == G.healer end,
            },
            threat = {
                closest_to_pulling = function() return nil, 0 end,
                holding = function() return 0 end,
                mine = function() return nil, 2, 3, false end,
            },
            world = {
                client = function() return client end,
                instance_type = function() return G.instance end,
                instance_name = function() return G.instance_name end,
                in_battleground = function() return G.instance == "pvp" end,
                in_arena = function() return G.instance == "arena" end,
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
            position = function(u) return G.pos[u.guid] or { x = 1, y = 2, z = 3, of = u.guid } end,
            player_position = function() return G.me_pos end,
        },
        combat = { cast_remaining = function() return G.cast_remaining end },
        spellbook = {
            id = function(name) return G.known[name] and id_of(name) or nil end,
            ids = function(name) return G.known[name] and { id_of(name) } or nil end,
            known = function(name) return G.known[name] == true end,
            ready = function(name) return G.known[name] == true and not G.unready[name] end,
            castable = function(name) return G.known[name] == true and not G.unready[name] end,
            cooldown = function(name) return G.unready[name] and 12 or 0 end,
        },
        resources = {
            hp_rate = function() return G.hp_rate end,
            fight_left = function() return 20 end,
            power_empty = function() return math.huge end,
        },
        hardcore = {
            should_stop_fighting = function() return false end,
            item = function() return nil end,
            use_item = function(kind) G.used[#G.used + 1] = kind return true end,
            named = function() return nil end,
            named_ready = function() return false, "not carried" end,
            use_named = function() return true end,
        },
        targeting = {
            context = function() return G.context end,
            switch_to = function(u) G.switched[#G.switched + 1] = u return true end,
        },
        sense = {
            pvp_active = function() return true end,
            stealth_suspected = function() return false end,
        },
        forms = { current = function() return G.form end },
        catalog = {
            ability = function(name) return G.catalog[name] end,
            with_role = function(role) return G.roles[role] or {} end,
            current = function() return G.ranges and { ranges = G.ranges } or nil end,
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
        -- Your own reactions (custom.lua) keep a bucket per class name.
        detect_class = function() return G.class and G.class.class_name or nil end,
    }
    P.rotation.helpers.debuff_up = function(u, name)
        for _, a in pairs(G.auras[u and u.guid or ""] or {}) do
            if a.buff_name == name then return true end
        end
        return false
    end
    P.rotation.helpers.since_cast = function() return math.huge end
    P.combat = {
        target = function() return G.target_present ~= false and G.target or nil end,
        duration = function() return G.fight_age or 0 end,
    }
    -- The Aspects window (aspects.lua) as the aspect kind and rules/intel.lua see it.
    G.aspect_switch = {}
    P.aspects = {
        auto_swap_on = function() return G.settings.rot_hunter_auto_aspect == true end,
        can_switch = function(name)
            if G.settings.rot_hunter_auto_aspect ~= true then return "Auto swap aspects is off" end
            if not G.known[name] then return "not trained" end
            return nil
        end,
        switch_to = function(name) G.aspect_switch[#G.aspect_switch + 1] = name return true end,
    }
    -- The narration module: what the layer says on screen.
    G.said = {}
    P.narrate = { say = function(severity, title, why, key)
        G.said[#G.said + 1] = { severity = severity, title = title, why = why, key = key }
        return true
    end }
    P.ctx.enemies = { all = function() return G.rows end }
    G.P = P

    G.class = opts.class or {
        key = "hunter", class_name = "HUNTER", power = "MANA",
        interrupts = {}, defensives = { "Feign Death", "Deterrence" }, escapes = {},
    }
    G.profile = { label = "Test", rules = {}, power = G.class.power }
    G.pet = unit(G, "pet", { name = "Wolf", hostile = false })
    package.loaded["jambix_aio/modules/pvphunter"] = nil
    P.pvphunter = require("jambix_aio/modules/pvphunter")(P)
    P.ctx.react = require("jcore/services/react")({}).for_owner("jambix.aio", P.ctx)
    G.React = fresh("jambix_aio/modules/react/init")(P)
    P.react = G.React
    G.I = G.React.intel
    G.S = G.I.S

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
            x = 5, y = 0, z = 0, speed = 0, moving = false, in_combat = true,
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

    --- The geometry service, answering what the test says.
    function G.with_sight(answer)
        G.sight = answer
        P.ctx.geometry = { sight = function()
            G.sight_calls = G.sight_calls + 1
            return G.sight
        end }
    end

    -- A player on you in melee, as the default fight.
    G.row = G.row_for(G.target)
    G.rows = { G.row }
    return G
end

local ROGUE, PRIEST, WARRIOR = 4, 5, 1

--- An enemy rogue in melee with you, on you.
local function rogue(G)
    G.target.get_class = function() return ROGUE end
    G.row.dist = 3
    G.distance = 3
end

local function hunter_ranges(G)
    G.ranges = { ranged = { min = 8, max = 35 }, melee = 5, dead_zone = { min = 5, max = 8 } }
end


return {
    assert_eq = assert_eq, assert_near = assert_near, has = has, fresh = fresh,
    unit = unit, bundle = bundle, rogue = rogue, hunter_ranges = hunter_ranges,
    ROGUE = ROGUE, PRIEST = PRIEST, WARRIOR = WARRIOR,
}

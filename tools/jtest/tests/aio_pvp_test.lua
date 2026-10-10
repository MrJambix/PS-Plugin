-- Jambix AIO: PvP on Classic Era (1.81.0) -- react/pvp.lua and rules/pvp.lua,
-- driven through the reaction engine with a scripted clock.
--
-- What these hold it to: the PvP trinket breaks only what Era's Insignia of
-- that class breaks, and only when the control costs more than the trinket
-- is worth; something cheaper goes first; nothing is pressed into an
-- immunity; a burst is answered with something the burster is not immune
-- to; a player's bubble is never learned for the name; and the burst window
-- keeps a control breaker.

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
        settings = { react_enabled = true },
        casts = {}, pet_casts = {}, used = {}, named_used = {}, handlers = {}, switched = {},
        known = {}, unready = {}, blocked = {}, ids = {}, names = {}, next_id = 1000,
        hp = 1.0, hp_rate = 0, in_combat = true, moving = false, power = 80, power_max = 100,
        rows = {}, row = nil, health = {}, by_guid = {}, auras = {}, items = {}, carried = {},
        slots = {}, schools = {}, loc = nil, cast_remaining = 0, context = "solo",
        group = { in_group = false }, armed = {}, catalog = {}, roles = {}, distance = 5,
        pet_alive = false, pet_known = {}, form = nil,
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
        pet_target = function() return nil end,
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
    G.P = P

    G.class = opts.class or {
        key = "testclass", class_name = "WARRIOR", power = "RAGE",
        interrupts = { "Pummel" }, defensives = {}, escapes = {},
    }
    G.profile = { label = "Test", rules = {}, power = G.class.power }
    G.pet = unit(G, "pet", { name = "Felhunter", hostile = false })
    P.ctx.world = { client = function() return { forever = false, combat_log = true } end }
    G.React = fresh("jambix_aio/modules/react/init")(P)

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

local INSIGNIA = "Insignia of the Alliance"

-- --- the data ---------------------------------------------------------------------------

T[#T + 1] = { "data: each Era Insignia breaks what its class's version breaks, and nothing breaks Blind", function()
    local G = bundle()
    local pvp = G.React.pvp
    local warrior, mage, rogue = pvp.BREAKS[pvp.INSIGNIA[18854]], pvp.BREAKS[pvp.INSIGNIA[18859]],
        pvp.BREAKS[pvp.INSIGNIA[18857]]
    assert(warrior.stun and warrior.root and warrior.snare, "a warrior's breaks stuns, roots and snares")
    assert(not warrior.fear and not warrior.polymorph, "and no fear, no polymorph")
    assert(mage.polymorph and mage.fear and mage.snare and not mage.stun, "a mage's: fear, polymorph, snare")
    assert(rogue.charm and rogue.fear and rogue.polymorph and not rogue.stun, "a rogue's: charm, fear, polymorph")
    for item, spell in pairs(pvp.INSIGNIA) do
        local set = pvp.BREAKS[spell]
        assert(set, "item " .. item .. " has a known effect")
        if set ~= pvp.ALL_CONTROL then
            for _, mech in ipairs({ "disorient", "knockout", "freeze", "sleep", "horror" }) do
                assert(not set[mech], string.format("item %d does not break %s", item, mech))
            end
        end
    end
    assert_eq(pvp.CONTROL.Blind.dispel, "POISON", "Blind is a poison")
    assert_eq(pvp.CONTROL["Psychic Scream"].dispel, nil, "Psychic Scream cannot be dispelled")
end }

-- --- break the control -------------------------------------------------------------------

T[#T + 1] = { "break: a warrior stunned and beaten through it uses the Insignia (balanced)", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Kidney Shot", 5, { caster = G.target })
    G.hp, G.hp_rate = 0.7, -0.06
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 1, "the trinket broke the stun")
end }

T[#T + 1] = { "break: stunned at full health with nothing hitting you, the Insignia is kept", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Kidney Shot", 5, { caster = G.target })
    G.rows[1].targeting_me = false
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "held: a stun nobody is using is worth less than the trinket")
    G.settings.react_pvp_trinket = 3
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 1, "'Break any control': used")
end }

T[#T + 1] = { "break: the readout says why the trinket is held", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Kidney Shot", 5, { caster = G.target })
    G.rows[1].targeting_me = false
    G.React.debug_lines()
    G.tick()
    local said = false
    for _, line in ipairs(G.React.debug_lines()) do
        if line:find("held: Kidney Shot is worth 30, the trinket needs 40 (balanced)", 1, true) then said = true end
    end
    assert(said, "the held line is in the readout")
end }

T[#T + 1] = { "break: a mob's stun is not the trinket's, even with a player in sight", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    local mob = unit(G, "Creature-0-1-2-3-4-5", { name = "Guard" })
    G.aura("player", "Bash", 4, { caster = mob })
    G.hp, G.hp_rate = 0.3, -0.08
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "a mob's stun: kept")
    G.aura("player", "Warsong Flag", nil)
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 1, "unless you carry the flag")
end }

T[#T + 1] = { "break: 'only to stay alive' keeps it at 70% health, spends it at 25%", function()
    local G = bundle()
    G.settings.react_pvp_trinket = 1
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Kidney Shot", 5, { caster = G.target })
    G.hp, G.hp_rate = 0.7, -0.06
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "70% and hit: kept")
    G.hp = 0.25
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 1, "25% and hit: used")
end }

T[#T + 1] = { "break: a warrior's Insignia cannot break a fear; Berserker Rage does", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.known["Berserker Rage"] = true
    G.aura("player", "Fear", 6, { caster = G.target })
    G.hp, G.hp_rate = 0.6, -0.05
    G.tick()
    assert_eq(G.sent("Berserker Rage"), 1, "Berserker Rage out of the fear")
    assert_eq(G.used_named(INSIGNIA), 0, "the Insignia stays")
end }

T[#T + 1] = { "break: Blind is waited out, and the journal says nothing breaks it", function()
    local G = bundle({ class = { key = "r", class_name = "ROGUE", power = "ENERGY", interrupts = { "Kick" },
                                 defensives = {}, escapes = {} } })
    G.wear(13, 18857, INSIGNIA)
    G.aura("player", "Blind", 8, { caster = G.target })
    G.hp, G.hp_rate = 0.4, -0.05
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "no Insignia breaks Blind")
    local said = false
    for _, line in ipairs(G.React.log_lines(20)) do
        if line:find("Blind (disorient): nothing you have breaks it", 1, true) then said = true end
    end
    assert(said, "the journal says why")
end }

T[#T + 1] = { "break: a mage Blinks out of a stun before any trinket", function()
    local G = bundle({ class = { key = "m", class_name = "MAGE", power = "MANA", interrupts = { "Counterspell" },
                                 defensives = {}, escapes = {} } })
    G.known.Blink = true
    G.wear(13, 216938, "Insignia of the Alliance (SoD)")
    G.aura("player", "Cheap Shot", 4, { caster = G.target })
    G.hp, G.hp_rate = 0.5, -0.05
    G.tick()
    assert_eq(G.sent("Blink"), 1, "Blink out of the stun")
    assert_eq(G.used_named("Insignia of the Alliance (SoD)"), 0, "the trinket that breaks everything is kept")
end }

T[#T + 1] = { "break: the felhunter devours a Polymorph off its warlock", function()
    local G = bundle({ class = { key = "w", class_name = "WARLOCK", power = "MANA", interrupts = {},
                                 pet_interrupts = { "Spell Lock" }, defensives = {}, escapes = {} } })
    G.pet_alive, G.pet_known["Devour Magic"] = true, true
    G.aura("player", "Polymorph", 8, { caster = G.target })
    G.hp, G.hp_rate = 0.8, -0.04
    G.tick()
    assert_eq(#G.pet_casts, 1, "the pet cast")
    assert_eq(G.pet_casts[1].name, "Devour Magic", "Devour Magic")
    assert(G.pet_casts[1].target == G.player, "on the warlock")
end }

T[#T + 1] = { "break: under a second left, nothing is spent", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Kidney Shot", 0.8, { caster = G.target })
    G.hp, G.hp_rate = 0.2, -0.1
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "a stun about to end is not worth the trinket")
end }

T[#T + 1] = { "break: the flag carrier breaks a Hamstring", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Hamstring", 12, { caster = G.target })
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 0, "a snare alone: kept")
    G.aura("player", "Warsong Flag", nil)
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.used_named(INSIGNIA), 1, "carrying the flag: broken")
end }

T[#T + 1] = { "potion: never tried while stunned, at once when the stun ends", function()
    local G = bundle()
    G.items.potion = "Major Healing Potion"
    G.aura("player", "Kidney Shot", 3, { caster = G.target })
    G.hp, G.hp_rate = 0.2, -0.05
    G.tick()
    assert_eq(#G.used, 0, "no potion under the stun")
    G.auras.player = {}
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.used[1], "potion", "the potion once it is over")
end }

-- --- stop the cast ----------------------------------------------------------------------

T[#T + 1] = { "stop the cast: a player's heal with Kick down: Kidney Shot", function()
    local G = bundle({ class = { key = "r", class_name = "ROGUE", power = "ENERGY", interrupts = { "Kick" },
                                 defensives = {}, escapes = {} } })
    G.known.Kick, G.unready.Kick = true, true
    G.known["Kidney Shot"] = true
    G.row.casting = G.casting("Greater Heal", 1.5, 3.0)
    G.row.targeting_me = false
    G.tick()
    assert_eq(G.sent("Kidney Shot"), 1, "a stun stops the heal")
end }

T[#T + 1] = { "stop the cast: Grounding Totem takes a Polymorph aimed at you", function()
    local G = bundle({ class = { key = "s", class_name = "SHAMAN", power = "MANA", interrupts = { "Earth Shock" },
                                 defensives = {}, escapes = {} } })
    G.known["Earth Shock"], G.unready["Earth Shock"] = true, true
    G.known["Grounding Totem"] = true
    G.row.casting = G.casting("Polymorph", 1.0, 1.5)
    G.tick()
    assert_eq(G.sent("Grounding Totem"), 1, "grounded")
end }

T[#T + 1] = { "stop the cast: Berserker Rage just before a fear lands", function()
    local G = bundle()
    G.known.Pummel, G.unready.Pummel = true, true
    G.known["Berserker Rage"] = true
    G.row.casting = G.casting("Fear", 1.4, 1.5)
    G.tick()
    assert_eq(G.sent("Berserker Rage"), 0, "too early: the fear is 1.4s out")
    G.row.casting = G.casting("Fear", 0.6, 1.5)
    G.clock = G.clock + 0.2
    G.tick()
    assert_eq(G.sent("Berserker Rage"), 1, "0.6s out: fearless before it lands")
end }

-- --- the burst ----------------------------------------------------------------------------

T[#T + 1] = { "burst: a warrior in Recklessness is fearless: the priest shields instead of screaming", function()
    local G = bundle({ class = { key = "p", class_name = "PRIEST", power = "MANA", interrupts = { "Silence" },
                                 defensives = {}, escapes = {} } })
    G.known["Psychic Scream"], G.known["Power Word: Shield"] = true, true
    G.aura(G.target.guid, "Recklessness", 15)
    G.tick()
    assert_eq(G.sent("Psychic Scream"), 0, "no fear into Recklessness")
    assert_eq(G.sent("Power Word: Shield"), 1, "the shield")
end }

T[#T + 1] = { "burst: a rogue's Adrenaline Rush in melee: Evasion", function()
    local G = bundle({ class = { key = "r", class_name = "ROGUE", power = "ENERGY", interrupts = { "Kick" },
                                 defensives = {}, escapes = {} } })
    G.known.Evasion = true
    G.aura(G.target.guid, "Adrenaline Rush", 15)
    G.tick()
    assert_eq(G.sent("Evasion"), 1, "Evasion for the burst")
end }

-- --- immunity -----------------------------------------------------------------------------

T[#T + 1] = { "immune: Divine Shield on the target: switched to the other player on you", function()
    local G = bundle({ class = { key = "r", class_name = "ROGUE", power = "ENERGY", interrupts = { "Kick" },
                                 defensives = {}, escapes = {} } })
    G.aura(G.target.guid, "Divine Shield", 10)
    local other = unit(G, "Player-1-00000002", { name = "Other", player = true })
    G.rows[#G.rows + 1] = G.row_for(other, { dist = 8 })
    G.tick()
    assert_eq(#G.switched, 1, "one switch")
    assert(G.switched[1] == other, "to the other player")
    assert(G.React.out_of_fight(G.target), "and the bubble is out of the fight for the auto-target")
end }

T[#T + 1] = { "immune: Blessing of Protection is out of the fight for a rogue, not for a mage", function()
    local rogue = bundle({ class = { key = "r", class_name = "ROGUE", power = "ENERGY", interrupts = { "Kick" },
                                     defensives = {}, escapes = {} } })
    rogue.aura(rogue.target.guid, "Blessing of Protection", 8)
    rogue.tick()
    assert(rogue.React.out_of_fight(rogue.target), "a rogue has nothing that lands")
    local mage = bundle({ class = { key = "m", class_name = "MAGE", power = "MANA", interrupts = { "Counterspell" },
                                    defensives = {}, escapes = {} } })
    mage.aura(mage.target.guid, "Blessing of Protection", 8)
    mage.tick()
    assert(not mage.React.out_of_fight(mage.target), "a mage's spells still land")
end }

T[#T + 1] = { "immune: what the rotation must not press into a player's buff", function()
    local G = bundle()
    local pvp = G.React.pvp
    G.known["Sinister Strike"], G.known.Fear, G.known.Polymorph, G.known.Frostbolt = true, true, true, true
    G.schools["Sinister Strike"], G.schools.Frostbolt = 1, 16
    G.aura(G.target.guid, "Blessing of Protection", 8)
    G.tick()
    assert(pvp.blocks("Sinister Strike", G.target), "a physical attack into Blessing of Protection")
    assert_eq(pvp.blocks("Frostbolt", G.target), nil, "a spell goes through it")
    G.auras[G.target.guid] = {}
    G.aura(G.target.guid, "Berserker Rage", 10)
    G.aura(G.target.guid, "Cat Form", nil)
    G.clock = G.clock + 0.1
    assert(pvp.blocks("Fear", G.target), "no fear into Berserker Rage")
    assert(pvp.blocks("Polymorph", G.target), "no sheep on a cat")
    local mob = unit(G, "Creature-0-1-2-3-4-5", { name = "Boar" })
    G.aura(mob.guid, "Berserker Rage", 10)
    assert_eq(pvp.blocks("Fear", mob), nil, "a mob is not read")
end }

T[#T + 1] = { "learn: a player's immunity is held a moment and never learned for the name", function()
    local G = bundle()
    local learn = G.React.learn
    local guid = G.target.guid
    learn.on_miss(guid, "Enemy", "Sinister Strike", "IMMUNE")
    assert(learn.blocks("Sinister Strike", G.target), "held at once")
    G.clock = G.clock + 13
    learn.on_miss(guid, "Enemy", "Sinister Strike", "IMMUNE")
    G.clock = G.clock + 5
    assert_eq(learn.blocks("Sinister Strike", G.target), nil, "free again: a bubble, not a lesson")
end }

-- --- what players do ----------------------------------------------------------------------

T[#T + 1] = { "trinket: an enemy's Insignia buff marks its trinket down for five minutes", function()
    local G = bundle()
    G.aura(G.target.guid, "Immune Fear/Polymorph/Stun", 2, { id = 23276 })
    G.tick()
    local st = G.React.pvp.state(G.target)
    assert(st.trinket_down, "its trinket is down")
    assert(st.trinket_back > 290 and st.trinket_back <= 300, "back in about five minutes")
    assert(st.mech.stun and st.mech.fear, "and immune to what it breaks while the buff lasts")
    G.auras[G.target.guid] = {}
    G.clock = G.clock + 301
    G.tick()
    assert(not G.React.pvp.state(G.target).trinket_down, "back after five minutes")
end }

T[#T + 1] = { "purge: a shaman takes Blessing of Protection off its target", function()
    local G = bundle({ class = { key = "s", class_name = "SHAMAN", power = "MANA", interrupts = { "Earth Shock" },
                                 defensives = {}, escapes = {} } })
    G.known.Purge = true
    G.aura(G.target.guid, "Blessing of Protection", 8)
    G.aura(G.target.guid, "Mark of the Wild", 1800)
    G.tick()
    assert_eq(G.sent("Purge"), 1, "purged")
end }

T[#T + 1] = { "vanish: a rogue gone from beside a mage: Arcane Explosion", function()
    local G = bundle({ class = { key = "m", class_name = "MAGE", power = "MANA", interrupts = { "Counterspell" },
                                 defensives = {}, escapes = {} } })
    G.known["Arcane Explosion"] = true
    G.row.dist = 6
    G.tick()
    G.target_present, G.rows, G.row = false, {}, nil
    G.target.visible = false
    G.by_guid[G.target.guid] = nil
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.sent("Arcane Explosion"), 1, "the area brings it out")
end }

T[#T + 1] = { "vanish: a hunter Flares the spot", function()
    local G = bundle({ class = { key = "h", class_name = "HUNTER", power = "MANA", interrupts = {},
                                 defensives = {}, escapes = {} } })
    G.known.Flare = true
    G.row.dist = 12
    G.tick()
    G.target_present, G.rows, G.row = false, {}, nil
    G.by_guid[G.target.guid] = nil
    G.clock = G.clock + 0.1
    G.tick()
    assert_eq(G.sent("Flare"), 1, "Flare")
    local last = G.casts[#G.casts]
    assert(last.position and last.position.of == "Player-1-00000001", "on where the rogue stood")
end }

-- --- the burst window keeps the trinket ------------------------------------------------------

T[#T + 1] = { "burst: a control-breaking trinket is kept out of the burst window", function()
    local G = bundle()
    local pvp = G.React.pvp
    G.wear(13, 18854, INSIGNIA)
    G.wear(14, 19950, "Zandalarian Hero Charm")
    assert(pvp.keeps(18854), "the Insignia is kept")
    assert(not pvp.keeps(19950), "a damage trinket is not")
    -- One the table does not list still says what it breaks.
    core.quests.get_item_spell = function(id)
        if id == 99999 then return { spell_id = 777, spell_name = "Immune Fear/Polymorph/Stun" } end
        return {}
    end
    G.wear(14, 99999, "Unknown Insignia")
    G.fire("jcore.game_event.PLAYER_EQUIPMENT_CHANGED")
    assert(pvp.keeps(99999), "read from its spell's name")
    local t = pvp.trinket_for("fear")
    assert(t and t.name == "Unknown Insignia", "and it is the one for a fear")
end }

-- --- custom reactions see it -----------------------------------------------------------------

T[#T + 1] = { "custom: what PvP fields a reaction of your own can read", function()
    local G = bundle()
    G.wear(13, 18854, INSIGNIA)
    G.aura("player", "Hamstring", 6, { caster = G.target })
    G.aura(G.target.guid, "Ice Block", 10)
    G.React.debug_lines()          -- the readout is built only while something reads it
    G.tick()
    local V = G.React.world.W.pvp
    assert(V and V.active, "the picture is live")
    assert_eq(V.snare.name, "Hamstring", "the snare on you")
    assert_eq(V.target.immune, "all", "the target's Ice Block")
    local lines = G.React.debug_lines()
    local found = false
    for _, line in ipairs(lines) do
        if line:find("PvP:", 1, true) and line:find("Insignia", 1, true) then found = true end
    end
    assert(found, "the readout has the PvP line")
end }

return T

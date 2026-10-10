-- Jambix AIO: the 1.77.3 review of the druid, mage, priest, rogue, shaman and
-- warrior files against the client's own spell and talent tables (Era
-- 1.15.9, Forever 1.60.1). The talent reader on Forever's one trait tree
-- (modules/talents.lua, modules/talent_trees.lua), the spellbook's form names
-- (modules/spellbook.lua), the rotation's aura reads by id (modules/rotation.lua),
-- and each class's changed rules, asked directly with a scripted H.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_talents = require("jambix_aio/modules/talents")
local make_spellbook = require("jambix_aio/modules/spellbook")
local make_rotation = require("jambix_aio/modules/rotation")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

local T = {}

-- --- talents: Forever's one tree, split by the client's node columns -------------

local FOREVER = { version = "Forever", forever = true, trait_talents = true }

local function talents_on_forever(active, spec)
    local P = {
        log = { fmt = function() end, once = function() end, debug = function() end },
        opt = function(_, default) return default end,
        ctx = {
            on = function() end, emit = function() end, every = function() end, after = function() end,
            world = { client = function() return FOREVER end },
        },
    }
    _G.core = {
        time = function() return 1000 end,
        game_ui = {
            get_talent_info = function() return {} end,
            get_active_talents = function() return active end,
            get_talent_tree_ids = function() return { 1089 } end,   -- the druid's one tree
            get_talent_tree_nodes = function() return {} end,
            get_specialization = function() return spec end,
        },
    }
    return make_talents(P)
end

T[#T + 1] = { "talents on Forever: one tree, each node counted for the tab its column is in", function()
    -- A Feral druid at 21 points, as the client lists it (node ids from the
    -- 1.60.1 tables; specialization 1, which is Balance).
    local talents = talents_on_forever({
        { node_id = 104938, name = "Ferocity", rank = 5, max_rank = 5 },
        { node_id = 104940, name = "Feral Instinct", rank = 3, max_rank = 3 },
        { node_id = 104939, name = "Heart of the Wild", rank = 5, max_rank = 5 },
        { node_id = 104949, name = "Primal Bite", rank = 1, max_rank = 1 },
        { node_id = 104955, name = "Leader of the Pack", rank = 1, max_rank = 1 },
        { node_id = 104923, name = "Improved Wrath", rank = 5, max_rank = 5 },
        { node_id = 104958, name = "Furor", rank = 1, max_rank = 5 },
    }, 1)
    local balance, feral, resto = talents.points()
    assert_eq(balance, 5, "Balance")
    assert_eq(feral, 15, "Feral Combat")
    assert_eq(resto, 1, "Restoration")
    assert_eq(talents.dominant(), 2, "Feral, not the spec's tab")
    assert_eq(talents.stats().split, "nodes", "split by the client's columns")
    assert_eq(talents.max_rank("Furor"), 5, "max rank")
    assert_eq(talents.max_rank("Swiftmend"), 0, "an untaken talent's max rank is unknown")
end }

T[#T + 1] = { "talents on Forever: a moved talent goes where Forever put it; an unknown node takes the spec", function()
    -- Insect Swarm is Restoration on Era and Balance on Forever; Natural
    -- Shapeshifter the other way. Node 11 is in no table: the spec's tab.
    local talents = talents_on_forever({
        { node_id = 104930, name = "Insect Swarm", rank = 1, max_rank = 1 },
        { node_id = 104919, name = "Natural Shapeshifter", rank = 3, max_rank = 3 },
        { node_id = 11, name = "Something New", rank = 2, max_rank = 2 },
    }, 2)
    local balance, feral, resto = talents.points()
    assert_eq(balance, 1, "Insect Swarm in Balance")
    assert_eq(feral, 2, "the unknown node on the spec's tab")
    assert_eq(resto, 3, "Natural Shapeshifter in Restoration")
end }

T[#T + 1] = { "talents on Forever 1.60.1.70291: the warrior's new and moved nodes count for their own tab (1.84.0)", function()
    -- A Fury warrior at 21 points on the patched client: Gore Drinker and the
    -- new Iron Will are nodes 70205 never had, which fell back to the spec's
    -- tab (Arms); Lingering Rage took the old Iron Will's node.
    local talents = talents_on_forever({
        { node_id = 105939, name = "Cruelty", rank = 5, max_rank = 5 },
        { node_id = 113569, name = "Gore Drinker", rank = 3, max_rank = 3 },
        { node_id = 110857, name = "Lingering Rage", rank = 1, max_rank = 1 },
        { node_id = 105953, name = "Furious Precision", rank = 3, max_rank = 3 },
        { node_id = 113570, name = "Iron Will", rank = 2, max_rank = 5 },
    }, 1)
    local arms, fury, prot = talents.points()
    assert_eq(fury, 12, "Cruelty, Gore Drinker, Lingering Rage, Furious Precision: Fury")
    assert_eq(prot, 2, "the new Iron Will: Protection")
    assert_eq(arms, 0, "nothing left on the spec's tab")
end }

-- --- spellbook: one name over a cat and a bear spell -------------------------------

local function spellbook(names)
    local ids = {}
    for id in pairs(names) do ids[#ids + 1] = id end
    _G.core = {
        time = function() return 100 end,
        spell_book = {
            get_spells = function() return ids end,
            get_spell_name = function(id) return names[id] or "" end,
            is_spell_known = function(id) return names[id] ~= nil end,
        },
    }
    local P = {
        log = { once = function() end, fmt = function() end, info = function() end },
        ctx = {
            on = function() end, every = function() end, emit = function() end,
            spells = {
                ready = function() return true end,
                castable = function() return true end,
                learned = function(id) return names[id] ~= nil, "known" end,
            },
        },
    }
    local book = make_spellbook(P)
    book.refresh()
    return book
end

T[#T + 1] = { "spellbook: the cat's Swipe and Mangle and the bear's are filed apart", function()
    local book = spellbook({
        [769] = "Swipe", [9908] = "Swipe", [411128] = "Swipe",
        [407993] = "Mangle", [407995] = "Mangle", [5221] = "Shred",
    })
    assert_eq(book.id("Swipe"), 9908, "Swipe is the bear's best rank, not the cat's 411128")
    assert_eq(book.id("Swipe (Cat)"), 411128, "the cat's Swipe")
    assert_eq(book.id("Mangle (Cat)"), 407993, "Mangle (Cat)")
    assert_eq(book.id("Mangle (Bear)"), 407995, "Mangle (Bear)")
    assert_eq(book.known("Mangle"), false, "no bare Mangle to press in the wrong form")
    assert_eq(book.id("Shred"), 5221, "everything else as before")
end }

T[#T + 1] = { "spellbook: Forever's name for 407995 is Primal Bite, and stays it", function()
    local book = spellbook({ [407995] = "Primal Bite", [769] = "Swipe" })
    assert_eq(book.id("Primal Bite"), 407995, "Primal Bite")
    assert_eq(book.id("Mangle (Bear)"), nil, "not renamed: the client does not call it Mangle")
    assert_eq(book.id("Swipe"), 769, "Swipe")
end }

-- --- rotation: an aura that is no spell of yours, by id ----------------------------

T[#T + 1] = { "rotation helpers: a list of ids is read as the aura, a name through the spellbook", function()
    local asked = {}
    _G.core = { time = function() return 1000 end, spell_book = {} }
    local player = { get_guid = function() return "player" end, get_class = function() return 5 end }
    local P = {
        log = { fmt = function() end, once = function() end, info = function() end, debug = function() end,
                warn = function() end, error = function() end },
        ctx = { on = function() end, tick = function() end, emit = function() end, cast = function() end,
                PRIORITY = { ROTATION = 50, COOLDOWN = 80, EMERGENCY = 100 } },
        units = {
            player = function() return player end,
            distance = function() return 5 end,
            has_aura = function(_, ids, guid) asked[#asked + 1] = { ids = ids, guid = guid }; return ids[1] == 6788 end,
            aura_stacks = function(_, ids) return ids[1] == 22959 and 3 or 0 end,
            aura_remaining = function(_, ids) return ids[1] == 400573 and 7 or 0 end,
        },
        combat = { cast_remaining = function() return 0 end },
        spellbook = {
            id = function() return nil end,
            ids = function(name) return name == "Renew" and { 139 } or nil end,
            known = function() return false end, ready = function() return false end,
            castable = function() return false end, names = function() return {} end,
        },
        talents = { rank = function() return 0 end },
        targeting = {},
        catalog = { ability = function() return nil end, current = function() return nil end,
                    with_role = function() return {} end },
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    }
    local H = make_rotation(P).helpers
    local target = {}
    assert_eq(H.debuff_up_any(player, { 6788 }), true, "Weakened Soul by id")
    assert_eq(asked[#asked].guid, nil, "anyone's")
    assert_eq(H.debuff_stacks(target, { 22959 }), 3, "Fire Vulnerability stacks by id")
    assert_eq(H.buff_remaining(player, { 400573 }), 7, "the Arcane Blast stack by id")
    assert_eq(H.buff_up(player, "Weakened Soul"), false, "by name it is not in the book: never read")
    H.buff_up(player, "Renew")
    assert_eq(asked[#asked].ids[1], 139, "a name still goes through the spellbook")
end }

T[#T + 1] = { "rotation helpers: a warlock's defensive Drain Life drains the enemy, not you (1.80.0)", function()
    _G.core = { time = function() return 1000 end, spell_book = {} }
    local player = { get_guid = function() return "player" end, get_class = function() return 9 end }
    local mob = { get_guid = function() return "mob" end }
    local P = {
        log = { fmt = function() end, once = function() end, info = function() end, debug = function() end,
                warn = function() end, error = function() end },
        ctx = { on = function() end, tick = function() end, emit = function() end, cast = function() end,
                PRIORITY = { ROTATION = 50, COOLDOWN = 80, EMERGENCY = 100 } },
        units = { player = function() return player end, distance = function() return 5 end,
                  has_aura = function() return false end },
        combat = { cast_remaining = function() return 0 end },
        spellbook = {
            id = function() return nil end, ids = function() return nil end,
            known = function() return true end, ready = function() return true end,
            castable = function() return true end, names = function() return {} end,
        },
        talents = { rank = function() return 0 end },
        targeting = {},
        catalog = { ability = function() return nil end, current = function() return nil end,
                    with_role = function() return {} end },
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
    }
    local H = make_rotation(P).helpers
    local s = { player = player, target = mob }
    assert_eq(H.escape_target("Drain Life", s), mob, "Drain Life on the mob")
    assert_eq(H.escape_target("Death Coil", s), mob, "Death Coil on the mob, as before")
    assert_eq(H.escape_target("Healing Wave", s), player, "a heal on yourself, as before")
end }

-- --- the class files, over a scripted H ---------------------------------------------

--- Auras are keyed by name, or by "#<first id>" when a rule asks by id.
local function key(name)
    if type(name) == "table" then return "#" .. tostring(name[1]) end
    return name
end

local function class(path, forever)
    local W = { auras = {}, stacks = {}, remaining = {}, talents = {}, max = {}, ids = {},
                spread = 1, mana = 1, moving = false }
    local function up(_, name) return W.auras[key(name)] == true end
    local function remaining(_, name)
        local k = key(name)
        return W.remaining[k] or (W.auras[k] and 20 or 0)
    end
    local H = {
        book = {
            id = function(name) return W.ids[name] end,
            known = function(name) return W.ids[name] ~= nil end,
            ready = function() return true end,
        },
        targeting = {
            reclaim_target = function() return nil end,
            may_control_pull = function() return false end,
        },
        talents = {
            rank = function(name) return W.talents[name] or 0 end,
            max_rank = function(name) return W.max[name] or 0 end,
        },
        units = { distance = function() return 5 end },
        buff_up = up, debuff_up = up, debuff_up_any = up,
        buff_remaining = remaining, debuff_remaining = remaining,
        debuff_stacks = function(_, name) return W.stacks[key(name)] or 0 end,
        dot_worth_it = function(s, name) return s.target ~= nil and remaining(nil, name) <= 2 end,
        has_talent = function(name) return (W.talents[name] or 0) > 0 end,
        talent = function(name) return W.talents[name] or 0 end,
        spread = function(_, n) return W.spread >= n end,
        power_fraction = function() return W.mana end,
        execute_phase = function() return false end,
        filler_ok = function() return true end,
        wand_wanted = function() return false end,
        bleeding = function() return false end,
        bursting = function() return false end,
        stealth_wanted = function() return false end,
        in_trouble = function() return false end,
        enemy_caster = function() return false end,
        melee_start_wanted = function() return false end,
    }
    W.P = {
        forever = forever == true,
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
        derived = function(_, pct) return pct / 100 end,
    }
    W.H = H
    W.class = require(path)(W.P, H, { opt = function(_, default) return default end })
    W.player = { is_moving = function() return W.moving end }
    W.target = {}
    function W.rule(profile, name, nth)
        local rules, seen = W.class.profiles[profile].rules, 0
        for i = 1, #rules do
            if rules[i][1] == name then
                seen = seen + 1
                if seen == (nth or 1) then return rules[i], i end
            end
        end
        return nil
    end
    function W.ask(profile, name, s, nth)
        local rule = W.rule(profile, name, nth)
        assert(rule, "no " .. name .. " rule in " .. profile)
        s = s or {}
        s.player = s.player or W.player
        if s.target == nil then s.target = W.target end
        if s.in_combat == nil then s.in_combat = true end
        s.hp, s.ttd, s.combo = s.hp or 1, s.ttd or 30, s.combo or 0
        s.ally_hp = s.ally_hp or 1
        s.loose = s.loose or {}
        return rule[2](s) == true
    end
    --- Every spell name the file declares in its rules and lists.
    function W.names()
        local out = {}
        for _, profile in pairs(W.class.profiles) do
            for _, rule in ipairs(profile.rules) do out[rule[1]] = true end
        end
        for _, field in ipairs({ "interrupts", "defensives", "escapes" }) do
            for _, name in ipairs(W.class[field] or {}) do out[name] = true end
        end
        for _, field in ipairs({ "dispels", "buffs", "burst" }) do
            for _, row in ipairs(W.class[field] or {}) do out[row.spell] = true end
        end
        return out
    end
    return W
end

-- No class spell on Era 1.15.9 or Forever 1.60.1 (TBC and Wrath names, and
-- "Remove Curse", a druid's on both).
local NOWHERE = {
    druid = {}, priest = {}, warrior = {},
    mage = { "Remove Curse", "Invisibility" },
    rogue = { "Cloak of Shadows" },
    shaman = { "Cure Toxins", "Wind Shear", "Totem of Wrath", "Bloodlust" },
}

T[#T + 1] = { "names: nothing in the six files that neither client has", function()
    for file, names in pairs(NOWHERE) do
        local W = class("jambix_aio/modules/classes/" .. file)
        local have = W.names()
        for _, name in ipairs(names) do
            assert_eq(have[name], nil, file .. ": " .. name)
        end
        assert_eq(have["Mangle"], nil, file .. ": no bare Mangle")
    end
    local warrior = class("jambix_aio/modules/classes/warrior")
    for _, profile in ipairs({ "tank_arms", "tank_fury", "tank_prot" }) do
        assert_eq(warrior.rule(profile, "Devastate"), nil, profile .. ": Devastate is a passive (Sunder)")
    end
end }

T[#T + 1] = { "priest: Weakened Soul by its id holds the shield, on you and on an ally", function()
    local W = class("jambix_aio/modules/classes/priest")
    local s = { hp = 0.5, on_me = 2 }
    assert_eq(W.ask("leveling", "Power Word: Shield", s), true, "hit, no shield: shield")
    W.auras["#6788"] = true
    assert_eq(W.ask("leveling", "Power Word: Shield", { hp = 0.5, on_me = 2 }), false, "Weakened Soul")
    local ally = {}
    assert_eq(W.ask("holy", "Power Word: Shield", { ally = ally, ally_hp = 0.5 }), false, "an ally's Weakened Soul")
    W.auras["#6788"] = nil
    assert_eq(W.ask("holy", "Power Word: Shield", { ally = ally, ally_hp = 0.5 }), true, "gone: shield")
end }

T[#T + 1] = { "priest: Forever's Penance and Prayer of Mending heal; Confounding Flash is a way out", function()
    local W = class("jambix_aio/modules/classes/priest")
    local ally = {}
    assert_eq(W.ask("holy", "Penance", { ally = ally, ally_hp = 0.4 }), true, "Penance at the flash line")
    assert_eq(W.ask("holy", "Penance", { ally = ally, ally_hp = 0.9 }), false, "not on a scratch")
    assert_eq(W.ask("discipline", "Prayer of Mending", { ally = ally, ally_hp = 0.8 }), true, "Mending in a fight")
    assert_eq(W.ask("discipline", "Prayer of Mending", { ally = ally, ally_hp = 0.8, in_combat = false }), false,
        "not out of one")
    assert_eq(W.ask("leveling", "Penance", {}), true, "levelling: holy damage on cooldown")
    local escapes = table.concat(W.class.escapes, ",")
    assert(escapes:find("Confounding Flash", 1, true), "Confounding Flash among the escapes")
end }

T[#T + 1] = { "mage: Scorch only with Improved Scorch, counting Fire Vulnerability (22959)", function()
    local W = class("jambix_aio/modules/classes/mage")
    assert_eq(W.ask("fire", "Scorch"), false, "no talent: nothing to build")
    W.talents["Improved Scorch"] = 3
    assert_eq(W.ask("fire", "Scorch"), true, "no stacks: build")
    W.stacks["#22959"], W.remaining["#22959"] = 5, 25
    assert_eq(W.ask("fire", "Scorch"), false, "five, fresh: Fireball")
    W.remaining["#22959"] = 4
    assert_eq(W.ask("fire", "Scorch"), true, "five, running out: refresh")
end }

T[#T + 1] = { "mage: Ice Lance on a Frostbite freeze or Fingers of Frost; Missiles on the Arcane Blast stack", function()
    local W = class("jambix_aio/modules/classes/mage")
    assert_eq(W.ask("frost", "Ice Lance"), false, "nothing frozen")
    W.auras["#12494"] = true
    assert_eq(W.ask("frost", "Ice Lance"), true, "Frostbite (12494)")
    W.auras = { ["#400669"] = true }
    assert_eq(W.ask("frost", "Ice Lance"), true, "Fingers of Frost (400669)")
    W.auras, W.mana = {}, 0.3
    -- The second Missiles rule since 1.80.0: the first is the Missile Barrage proc.
    assert_eq(W.ask("arcane", "Arcane Missiles", nil, 2), false, "no stack")
    W.auras["#400573"] = true
    assert_eq(W.ask("arcane", "Arcane Missiles", nil, 2), true, "the stack (400573), mana low")
end }

T[#T + 1] = { "druid: Tiger's Fury gives energy on Forever and the rune, and waits for room", function()
    local W = class("jambix_aio/modules/classes/druid")
    W.ids["Tiger's Fury"] = 9846   -- Era's buff, 30 energy
    assert_eq(W.ask("feral_cat", "Tiger's Fury", { power = 100 }), true, "Era: the buff when it is down")
    W.auras["Tiger's Fury"] = true
    assert_eq(W.ask("feral_cat", "Tiger's Fury", { power = 100 }), false, "Era: not while up")
    W.auras = {}
    W.ids["Tiger's Fury"] = 417045   -- the rune: 60 energy
    assert_eq(W.ask("feral_cat", "Tiger's Fury", { power = 80 }), false, "rune: no room for 60")
    assert_eq(W.ask("feral_cat", "Tiger's Fury", { power = 30 }), true, "rune: room")
    local F = class("jambix_aio/modules/classes/druid", true)
    F.ids["Tiger's Fury"] = 5217
    assert_eq(F.ask("feral_cat", "Tiger's Fury", { power = 90 }), false, "Forever: no room")
    assert_eq(F.ask("feral_cat", "Tiger's Fury", { power = 40 }), true, "Forever: room")
    assert_eq(F.ask("feral_cat", "Tiger's Fury", { power = 10, in_combat = false }), false, "not out of a fight")
end }

T[#T + 1] = { "druid: Faerie Fire (Feral) reads its own debuff; Primal Bite, Swipe (Cat) and Berserk", function()
    local W = class("jambix_aio/modules/classes/druid")
    assert_eq(W.ask("feral_cat", "Faerie Fire (Feral)"), true, "neither up")
    W.remaining["Faerie Fire (Feral)"] = 30
    assert_eq(W.ask("feral_cat", "Faerie Fire (Feral)"), false, "its own up: not again")
    W.remaining = { ["Faerie Fire"] = 30 }
    assert_eq(W.ask("feral_bear", "Faerie Fire (Feral)"), false, "a caster's up: enough")
    local _, mangle = W.rule("feral_bear", "Mangle (Bear)")
    local _, bite = W.rule("feral_bear", "Primal Bite")
    assert(mangle and bite and mangle < bite, "Primal Bite beside Mangle (Bear)")
    W.spread = 2
    assert_eq(W.ask("feral_cat", "Swipe (Cat)"), false, "two: single target")
    W.spread = 3
    assert_eq(W.ask("feral_cat", "Swipe (Cat)"), true, "three: Swipe")
    assert_eq(W.class.burst[1].spell, "Berserk", "Berserk opens a burst")
    assert_eq(W.class.burst[1].duration, 15, "for 15 s")
end }

T[#T + 1] = { "warrior: Slam at Improved Slam's top, 4 of Era's 5 or both of Forever's 2; Spearing Strike", function()
    local W = class("jambix_aio/modules/classes/warrior")
    W.talents["Improved Slam"], W.max["Improved Slam"] = 2, 2
    assert_eq(W.ask("dps_arms", "Slam"), true, "Forever 2/2")
    W.talents["Improved Slam"] = 1
    assert_eq(W.ask("dps_arms", "Slam"), false, "Forever 1/2")
    W.talents["Improved Slam"], W.max["Improved Slam"] = 4, 5
    assert_eq(W.ask("dps_arms", "Slam"), true, "Era 4/5")
    W.talents["Improved Slam"] = 3
    assert_eq(W.ask("dps_arms", "Slam"), false, "Era 3/5")
    W.talents["Improved Slam"], W.max["Improved Slam"] = 4, 0
    assert_eq(W.ask("dps_arms", "Slam"), true, "max unread: 4 as before")
    W.talents["Improved Slam"] = 0
    assert_eq(W.ask("dps_arms", "Slam"), false, "untalented")
    local _, ms = W.rule("dps_arms", "Mortal Strike")
    local _, spear = W.rule("dps_arms", "Spearing Strike")
    assert(ms and spear and spear == ms + 1, "Spearing Strike after Mortal Strike")
end }

T[#T + 1] = { "shaman: Maelstrom Weapon at five makes the Bolt worth pressing; Lava Burst; Rage of the Farseer", function()
    local W = class("jambix_aio/modules/classes/shaman")
    assert_eq(W.ask("enhancement", "Lightning Bolt"), false, "no stacks")
    W.stacks["#408505"] = 4
    assert_eq(W.ask("enhancement", "Lightning Bolt"), false, "four")
    W.stacks["#408505"] = 5
    assert_eq(W.ask("enhancement", "Lightning Bolt"), true, "five: instant")
    assert_eq(W.ask("leveling", "Lightning Bolt"), true, "levelling, in melee, five")
    W.stacks = {}
    assert_eq(W.ask("leveling", "Lightning Bolt"), false, "levelling, in melee, none")
    assert_eq(W.ask("leveling", "Lightning Bolt", { in_combat = false }), true, "the pull")
    local _, shock = W.rule("elemental", "Flame Shock")
    local _, burst = W.rule("elemental", "Lava Burst")
    assert(shock and burst and shock < burst, "Lava Burst after Flame Shock")
    assert_eq(W.class.burst[1].spell, "Rage of the Farseer", "Rage of the Farseer first")
    assert_eq(W.class.interrupts[1], "Earth Shock", "Earth Shock interrupts")
end }

T[#T + 1] = { "rogue: Venom kept up in a fight by an Assassination rogue", function()
    local W = class("jambix_aio/modules/classes/rogue")
    assert_eq(W.ask("assassination", "Venom", { combo = 3 }), true, "points, no Venom")
    assert_eq(W.ask("assassination", "Venom", { combo = 3, in_combat = false }), false, "not out of a fight")
    assert_eq(W.ask("assassination", "Venom", { combo = 1 }), false, "one point from nothing: wait")
    W.remaining["Venom"] = 12
    assert_eq(W.ask("assassination", "Venom", { combo = 5 }), false, "up")
    assert_eq(W.ask("assassination", "Slice and Dice", { combo = 2 }), true, "Slice and Dice as before")
end }

-- 1.78.2: the warlock, the one file 1.77.3 left with names neither client
-- reads that way.
T[#T + 1] = { "warlock: a Nightfall proc (Shadow Trance, 17941) is an instant bolt before the dots (1.78.2)", function()
    local W = class("jambix_aio/modules/classes/warlock", true)
    W.talents["Nightfall"] = 2
    assert_eq(W.ask("leveling", "Shadow Bolt"), false, "no proc: nothing")
    W.auras["Shadow Trance"] = true
    assert_eq(W.ask("leveling", "Shadow Bolt"), false, "asked by name it would never be seen")
    W.auras["Shadow Trance"], W.auras["#17941"] = nil, true
    assert_eq(W.ask("leveling", "Shadow Bolt"), true, "by its id: the instant bolt")
    W.moving = true
    assert_eq(W.ask("leveling", "Shadow Bolt"), true, "moving too: it needs no cast")
    for _, profile in ipairs({ "leveling", "leveling_bolt" }) do
        local _, proc = W.rule(profile, "Shadow Bolt")
        local _, corruption = W.rule(profile, "Corruption")
        assert(proc and corruption and proc < corruption, profile .. ": before the damage over time")
    end
    W.talents["Nightfall"] = nil
    assert_eq(W.ask("leveling", "Shadow Bolt"), false, "no Nightfall: not this rule")
end }

T[#T + 1] = { "warlock: a soulstone already on you (by its id) is not used again; no Fel Intelligence (1.78.2)", function()
    local W = class("jambix_aio/modules/classes/warlock", true)
    local used = {}
    W.P.hardcore = {
        item = function(kind) return kind == "soulstone" and { name = "Minor Soulstone" } or nil end,
        use_item = function(kind) used[#used + 1] = kind return true end,
    }
    W.H.units.player = function() return W.player end
    local s = { in_combat = false, player = W.player }
    assert_eq(W.class.idle(s), true, "in the bags, not on you: put on")
    assert_eq(used[1], "soulstone", "the stone")
    used = {}
    W.auras["Soulstone Resurrection"] = true
    W.class.idle(s)
    assert_eq(#used, 1, "asked by name it would never be seen")
    used = {}
    W.auras["Soulstone Resurrection"], W.auras["#20707"] = nil, true
    assert_eq(W.class.idle(s), false, "on you, by its id: left in the bags")
    assert_eq(#used, 0, "nothing used")
    assert_eq(W.names()["Fel Intelligence"], nil, "Fel Intelligence: on neither client")
end }

-- --- 1.80.0: the Forever rotation comparison's fixes ----------------------------------

--- The index of a rule in a profile, or nil.
local function at(W, profile, name, nth)
    local _, i = W.rule(profile, name, nth)
    return i
end

T[#T + 1] = { "warlock: Agony is Bane of Agony on Forever and Curse of Agony on Era, in every profile (1.80.0)", function()
    local F = class("jambix_aio/modules/classes/warlock", true)
    local E = class("jambix_aio/modules/classes/warlock")
    F.H.should_recover = function() return false end
    for _, profile in ipairs({ "leveling", "leveling_bolt", "affliction", "destruction", "demonology" }) do
        assert(F.rule(profile, "Bane of Agony"), profile .. ": Forever asks for Bane of Agony")
        assert_eq(F.rule(profile, "Curse of Agony"), nil, profile .. ": never Curse of Agony on Forever")
        assert(E.rule(profile, "Curse of Agony"), profile .. ": Era keeps Curse of Agony")
        assert_eq(E.rule(profile, "Bane of Agony"), nil, profile .. ": no Bane on Era")
    end
    assert_eq(F.ask("leveling", "Bane of Agony"), true, "no Agony on the target: put it up")
    F.remaining["Bane of Agony"] = 20
    assert_eq(F.ask("leveling", "Bane of Agony"), false, "its own debuff, by the Forever name, holds it")
end }

T[#T + 1] = { "warlock: Curse of the Elements beside the Bane on Forever's elites and long fights, never on Era (1.80.0)", function()
    local F = class("jambix_aio/modules/classes/warlock", true)
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 15 }), false, "a normal mob, 15 s: no curse")
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 40 }), true, "a 40 s fight: curse")
    F.P.units = { classification = function() return 1 end }
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 15 }), true, "an elite: curse")
    F.remaining["Curse of the Elements"] = 200
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 15 }), false, "already ours")
    F.remaining = {}
    F.auras["Curse of Recklessness"] = true
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 15 }), false, "never over a curse of ours")
    F.auras = {}
    assert_eq(F.ask("affliction", "Curse of the Elements", { ttd = 15, in_combat = false }), false, "not before a fight")
    local E = class("jambix_aio/modules/classes/warlock")
    E.P.units = { classification = function() return 3 end }
    assert_eq(E.ask("affliction", "Curse of the Elements", { ttd = 60 }), false, "Era: the curse slot is Agony's")
    local curse, agony = at(F, "affliction", "Curse of the Elements"), at(F, "affliction", "Bane of Agony")
    assert(curse and agony and curse < agony, "the curse before the DoTs")
end }

T[#T + 1] = { "warlock: Wrack is Affliction's filler before Shadow Bolt (1.80.0)", function()
    local F = class("jambix_aio/modules/classes/warlock", true)
    F.H.filler_after_dots = function() return true end
    local wrack, bolt = at(F, "affliction", "Wrack"), at(F, "affliction", "Shadow Bolt", 2)
    assert(wrack and bolt and wrack < bolt, "Wrack before the Shadow Bolt filler")
    assert_eq(F.ask("affliction", "Wrack", { ttd = 20 }), true, "dots up, a long fight: Wrack")
    assert_eq(F.ask("affliction", "Wrack", { ttd = 4 }), false, "dies before the channel ends")
    F.moving = true
    assert_eq(F.ask("affliction", "Wrack", { ttd = 20 }), false, "not on the move")
    assert_eq(F.rule("leveling", "Wrack"), nil, "the capstone is Affliction's alone")
end }

T[#T + 1] = { "priest: levelling Renew waits for the last one to run out, under 65% too (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/priest")
    assert_eq(W.ask("leveling", "Renew", { hp = 0.5 }), true, "under 65%, no Renew: Renew")
    W.auras["Renew"] = true
    assert_eq(W.ask("leveling", "Renew", { hp = 0.5 }), false, "under 65% with Renew ticking: not again (was every 3 s)")
    assert_eq(W.ask("leveling", "Renew", { hp = 0.9 }), false, "healthy: no")
end }

T[#T + 1] = { "healers: the big heal comes before the fast one, so both lines work (1.80.0)", function()
    local priest = class("jambix_aio/modules/classes/priest")
    assert(at(priest, "holy", "Greater Heal") < at(priest, "holy", "Flash Heal"), "priest: Greater Heal first")
    assert(at(priest, "holy", "Heal") < at(priest, "holy", "Flash Heal"), "priest: Heal before Flash Heal")
    local paladin = class("jambix_aio/modules/classes/paladin")
    assert(at(paladin, "holy", "Holy Light") < at(paladin, "holy", "Flash of Light"), "paladin: Holy Light first")
    local druid = class("jambix_aio/modules/classes/druid")
    assert(at(druid, "restoration", "Swiftmend") < at(druid, "restoration", "Regrowth"), "druid: Swiftmend first")
    assert(at(druid, "restoration", "Healing Touch") < at(druid, "restoration", "Regrowth"), "druid: Healing Touch first")
    local shaman = class("jambix_aio/modules/classes/shaman")
    assert(at(shaman, "restoration", "Healing Wave") < at(shaman, "restoration", "Lesser Healing Wave"),
        "shaman: Healing Wave first")
    local ally = {}
    assert_eq(shaman.ask("restoration", "Healing Wave", { ally = ally, ally_hp = 0.45 }), false, "45%: not the big heal")
    assert_eq(shaman.ask("restoration", "Lesser Healing Wave", { ally = ally, ally_hp = 0.45 }), true, "45%: the fast one")
    assert_eq(shaman.ask("restoration", "Healing Wave", { ally = ally, ally_hp = 0.3 }), true, "30%, standing: the big one")
    shaman.moving = true
    assert_eq(shaman.ask("restoration", "Healing Wave", { ally = ally, ally_hp = 0.3 }), false, "on the move: not a cast")
    shaman.moving = false
    assert_eq(shaman.ask("restoration", "Chain Heal", { ally = ally, ally_hp = 0.4 }), false, "one hurt: no Chain Heal")
    shaman.P.ctx = { group = { count_below = function() return 3 end } }
    assert_eq(shaman.ask("restoration", "Chain Heal", { ally = ally, ally_hp = 0.4 }), true, "three hurt: Chain Heal")
    assert(at(shaman, "restoration", "Chain Heal") < at(shaman, "restoration", "Healing Wave"), "Chain Heal first")
end }

T[#T + 1] = { "shaman: Lightning Shield for an Elemental without Water Shield; Fire Nova with a fire totem down (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/shaman", true)
    local water, lightning = at(W, "elemental", "Water Shield"), at(W, "elemental", "Lightning Shield")
    assert(water and lightning and water < lightning, "Lightning Shield after Water Shield")
    assert_eq(W.ask("elemental", "Lightning Shield"), true, "no shield: Lightning Shield goes up")
    W.auras["Water Shield"] = true
    assert_eq(W.ask("elemental", "Lightning Shield"), false, "a shield is up: nothing")
    local since = {}
    W.H.since_cast = function(name) return since[name] or math.huge end
    W.spread = 3
    assert_eq(W.ask("enhancement", "Fire Nova"), false, "no fire totem: nothing to explode")
    since["Searing Totem"] = 10
    assert_eq(W.ask("enhancement", "Fire Nova"), true, "a Searing Totem 10 s old, three close: Fire Nova")
    W.spread = 1
    assert_eq(W.ask("enhancement", "Fire Nova"), false, "one mob: not worth it")
    W.spread = 3
    since["Searing Totem"] = 45
    assert_eq(W.ask("leveling", "Fire Nova"), false, "the totem is gone")
end }

T[#T + 1] = { "shaman: the best weapon imbue out of combat, when the main hand's runs out (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/shaman", true)
    local left_ms = 0
    local weapon = { item_enchant_expiration = function() return left_ms end }
    W.P.ctx = { inventory = { equipped_at = function(slot) return slot == 16 and { object = weapon } or nil end } }
    local since = {}
    W.H.since_cast = function(name) return since[name] or math.huge end
    W.ids["Rockbiter Weapon"] = 8017
    assert_eq(W.ask("leveling", "Rockbiter Weapon", { in_combat = false }), true, "no enchant: Rockbiter")
    W.ids["Flametongue Weapon"] = 8024
    assert_eq(W.ask("leveling", "Rockbiter Weapon", { in_combat = false }), false, "Flametongue trained: not Rockbiter")
    assert_eq(W.ask("leveling", "Flametongue Weapon", { in_combat = false }), true, "Flametongue")
    W.ids["Windfury Weapon"] = 8232
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), true, "Windfury above both")
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = true }), false, "never in a fight")
    left_ms = 1500000
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), false, "25 minutes left: leave it")
    left_ms = 60000
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), true, "a minute left: renew")
    since["Windfury Weapon"] = 30
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), false,
        "pressed 30 s ago and still read as gone: no imbue every few seconds")
    since["Windfury Weapon"] = 400
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), true, "five minutes on: try again")
    since["Windfury Weapon"] = 1700
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), true, "28 minutes on: the imbue is running out")
    W.P.ctx = { inventory = { equipped_at = function() return { object = nil } end } }
    assert_eq(W.ask("enhancement", "Windfury Weapon", { in_combat = false }), false, "no weapon: nothing")
end }

T[#T + 1] = { "mage: Missiles on a Missile Barrage proc, Pyroblast on three Heating Up, Frostfire before Fireball (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/mage", true)
    for _, profile in ipairs({ "leveling", "frost", "fire", "arcane" }) do
        assert(W.rule(profile, "Arcane Missiles"), profile .. ": a Missiles rule")
    end
    assert_eq(W.ask("arcane", "Arcane Missiles"), false, "no proc, full mana: Arcane Blast instead")
    W.auras["#400589"] = true
    assert_eq(W.ask("arcane", "Arcane Missiles"), true, "Missile Barrage (400589): Missiles")
    assert(at(W, "arcane", "Arcane Missiles") < at(W, "arcane", "Arcane Blast"), "the proc before Arcane Blast")
    W.moving = true
    assert_eq(W.ask("arcane", "Arcane Missiles"), false, "not on the move")
    W.moving, W.auras = false, {}
    W.stacks["#400625"] = 2
    assert_eq(W.ask("fire", "Pyroblast"), false, "two Heating Up: Fireball")
    W.stacks["#400625"] = 3
    assert_eq(W.ask("fire", "Pyroblast"), true, "three: Pyroblast")
    assert(at(W, "fire", "Frostfire Bolt") < at(W, "fire", "Fireball"), "Frostfire Bolt before Fireball")
    W.auras["#12494"] = true
    assert_eq(W.ask("leveling", "Ice Lance"), true, "levelling: Ice Lance on a Frostbite freeze")
end }

T[#T + 1] = { "warrior: Victory Rush in every list; Rend first for Arms only with Bloodthrill (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/warrior", true)
    for _, profile in ipairs({ "dps_arms", "dps_fury", "tank_arms", "tank_fury", "tank_prot" }) do
        assert(W.rule(profile, "Victory Rush"), profile .. ": Victory Rush")
    end
    assert_eq(W.ask("dps_arms", "Victory Rush"), true, "free: whenever the client allows it")
    local early, late = at(W, "dps_arms", "Rend", 1), at(W, "dps_arms", "Rend", 2)
    assert(early and late and early < at(W, "dps_arms", "Overpower") and late > at(W, "dps_arms", "Mortal Strike"),
        "an early Rend above Overpower, the old one below Mortal Strike")
    W.target = { get_creature_type = function() return 7 end }
    assert_eq(W.ask("dps_arms", "Rend", { ttd = 30 }, 1), false, "no Bloodthrill: the early Rend stays quiet")
    W.talents["Bloodthrill"] = 3
    assert_eq(W.ask("dps_arms", "Rend", { ttd = 30 }, 1), true, "Bloodthrill: Rend first")
end }

T[#T + 1] = { "druid: Bear Form before Dire Bear Form is trained; Shifting Power under 60 energy; Wild Growth (1.80.0)", function()
    local W = class("jambix_aio/modules/classes/druid", true)
    assert_eq(W.ask("feral_bear", "Bear Form"), true, "no Dire Bear Form yet, no bear: Bear Form")
    W.auras["Bear Form"] = true
    assert_eq(W.ask("feral_bear", "Bear Form"), false, "already a bear")
    W.auras = {}
    W.ids["Dire Bear Form"] = 9634
    assert_eq(W.ask("feral_bear", "Bear Form"), false, "Dire Bear Form trained: its own rule")
    assert_eq(W.ask("feral_cat", "Shifting Power", { power = 70 }), false, "70 energy: the 40 would spill")
    assert_eq(W.ask("feral_cat", "Shifting Power", { power = 30 }), true, "30 energy: Shifting Power")
    assert_eq(W.ask("feral_cat", "Shifting Power", { power = 30, in_combat = false }), false, "not out of a fight")
    local ally = {}
    assert_eq(W.ask("restoration", "Wild Growth", { ally = ally, ally_hp = 0.6 }), false, "no group read: no party heal")
    W.P.ctx = { group = { count_below = function() return 3 end } }
    assert_eq(W.ask("restoration", "Wild Growth", { ally = ally, ally_hp = 0.6 }), true, "three hurt: Wild Growth")
end }

return T

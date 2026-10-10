-- Jambix AIO: how a unit fights -- melee, ranged, caster -- in
-- modules/esp/fight.lua. Learned from casts the enemy tracker announces,
-- kept per npc id in a store, and guessed before anything has been seen.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local cfg = require("jambix_aio/modules/config")
local make_fight = require("jambix_aio/modules/esp/fight")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

-- Spell facts as the client's spell book answers them.
local SPELLS = {
    [6660]  = { school = 1,  range = 30 },   -- Shoot
    [10277] = { school = 1,  range = 30 },   -- Throw
    [116]   = { school = 16, range = 30 },   -- Frostbolt
    [403]   = { school = 8,  range = 30 },   -- Lightning Bolt
    [12345] = { school = 1,  range = 5 },    -- a melee special with a cast time
    [999]   = { school = 0,  range = 0 },    -- nothing known
}

_G.core = {
    time = function() return 1000 end,
    spell_book = {
        get_spell_school = function(id) return SPELLS[id] and SPELLS[id].school or 0 end,
        get_spell_max_range = function(id) return SPELLS[id] and SPELLS[id].range or 0 end,
    },
}

--- A module over a store, with the cast event's handler captured.
local function build(data, cached)
    local handlers = {}
    local store = { data = data or {}, touched = 0 }
    function store:touch() self.touched = self.touched + 1 end
    local P = {
        cfg = cfg,
        ctx = {
            store = function() return store end,
            on = function(name, fn) handlers[name] = fn end,
        },
        esp_classify = { cached = function(guid) return cached and cached[guid] or nil end },
    }
    return make_fight(P), handlers, store
end

local T = {}

T[#T + 1] = { "a physical cast with reach is a ranged attack, a magic one a spell", function()
    local F = build()
    assert_eq(F.kind_of_cast(6660), "ranged", "Shoot")
    assert_eq(F.kind_of_cast(10277), "ranged", "Throw")
    assert_eq(F.kind_of_cast(116), "caster", "Frostbolt")
    assert_eq(F.kind_of_cast(403), "caster", "Lightning Bolt")
    assert_eq(F.kind_of_cast(12345), nil, "a melee special says nothing")
    assert_eq(F.kind_of_cast(999), nil, "an unknown school says nothing")
end }

T[#T + 1] = { "learned from the enemy tracker's casts, by the creature's npc id", function()
    local cached = { m1 = { npc_id = 3100, name = "Razormane Hunter" }, p1 = { is_player = true, npc_id = 7 } }
    local F, on, store = build(nil, cached)
    local cast = on["jcore.enemy.casting"]
    assert(cast, "listens for the tracker's casts")
    cast({ guid = "m1" }, { spell_id = 6660 })
    assert_eq(F.seen(3100), "ranged", "seen shooting")
    assert(store.touched > 0, "saved")
    assert_eq(store.data.npcs["3100"].r, 1, "one ranged cast on record")

    cast({ guid = "p1" }, { spell_id = 116 })
    assert_eq(F.seen(7), nil, "a player's casts teach nothing about a creature")

    -- not in the classifier's cache: the id is read off the unit
    cast({ guid = "m2", obj = { get_npc_id = function() return 4200 end } }, { spell_id = 116 })
    assert_eq(F.seen(4200), "caster", "read off the unit")
end }

T[#T + 1] = { "the more frequent wins; a tie goes to the caster", function()
    local F = build()
    for _ = 1, 3 do F.observe(3100, 6660) end
    F.observe(3100, 116)
    assert_eq(F.seen(3100), "ranged", "three shots, one bolt")
    F.observe(3100, 116)
    F.observe(3100, 116)
    assert_eq(F.seen(3100), "caster", "three and three: it casts, so it can be interrupted")
end }

T[#T + 1] = { "what was learned outlives the session", function()
    local F1, _, store = build()
    F1.observe(3100, 6660)
    local F2 = build(store.data)
    assert_eq(F2.seen(3100), "ranged", "a new session reads the same store")
end }

T[#T + 1] = { "seen beats everything; a name or class is likely; a mana pool alone a guess", function()
    local F = build()
    F.observe(3101, 6660)
    local fight, sure = F.role({ npc_id = 3101, name = "Kobold Geomancer", caster = true })
    assert_eq(fight, "ranged", "seen shooting, whatever the name says")
    assert_eq(sure, "seen", "seen")

    local function role(info) return F.role(info) end
    local f, s = role({ name = "Razormane Hunter", creature_type = 7 })
    assert_eq(f, "ranged", "a Hunter shoots"); assert_eq(s, "likely", "by name")
    f, s = role({ name = "Kobold Geomancer", creature_type = 7 })
    assert_eq(f, "caster", "-mancer"); assert_eq(s, "likely", "by name")
    f = role({ name = "Defias Shadowcaster", creature_type = 7 })
    assert_eq(f, "caster", "-caster")
    f = role({ name = "Bloodscalp Witch Doctor", creature_type = 7 })
    assert_eq(f, "caster", "a two-word name")
    f, s = role({ name = "Ridge Huntress", creature_type = 1 })
    assert_eq(f, "melee", "a beast bites, whatever it is called"); assert_eq(s, "likely", "by type")
    f, s = role({ name = "Defias Pillager", creature_type = 7, class_id = cfg.CLASS_IDS.MAGE })
    assert_eq(f, "caster", "a mage-class npc"); assert_eq(s, "likely", "by class")
    f = role({ name = "Scarlet Crusader", creature_type = 7, class_id = cfg.CLASS_IDS.PALADIN, caster = true })
    assert_eq(f, "melee", "a paladin-class npc has mana and swings")
    f, s = role({ name = "Gnoll Brute", creature_type = 7, caster = true })
    assert_eq(f, "caster", "a mana pool"); assert_eq(s, "guess", "only a guess")
    f, s = role({ name = "Gnoll Brute", creature_type = 7 })
    assert_eq(f, "melee", "nothing to go on"); assert_eq(s, "guess", "a guess")
end }

T[#T + 1] = { "players: by spec, as sure as the role behind it", function()
    local F = build()
    local f, s = F.role({ is_player = true, spec = 253, role_certain = true })
    assert_eq(f, "ranged", "a hunter"); assert_eq(s, "likely", "certain role")
    f = F.role({ is_player = true, spec = 64 })
    assert_eq(f, "caster", "a frost mage")
    f = F.role({ is_player = true, spec = 263 })
    assert_eq(f, "melee", "an enhancement shaman")
    f, s = F.role({ is_player = true, spec = 105, role_certain = false })
    assert_eq(f, "caster", "a restoration druid"); assert_eq(s, "guess", "a guessed role")
    f = F.role({ is_player = true })
    assert_eq(f, nil, "no spec, no answer")
end }

T[#T + 1] = { "config: every role has a word, a letter and a colour; every spec the resolver gives has a style", function()
    for _, role in ipairs({ "melee", "ranged", "caster" }) do
        assert(cfg.FIGHT_WORD[role] and cfg.FIGHT_LETTER[role] and cfg.FIGHT_RGB[role], role)
    end
    for class, by_role in pairs(cfg.ROLE_SPEC) do
        for _, spec in pairs(by_role) do
            assert(cfg.FIGHT_SPEC[spec], class .. " spec " .. spec .. " has no fighting style")
        end
    end
end }

return T

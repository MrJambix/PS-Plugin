-- JCore 1.6.0 / services/power.lua: the player's resources on Forever, where
-- the client reads every one of them as 0 (the API recorder, 2026-10-02:
-- 164,586 of 164,586 get_power calls). Counted from our own casts, corrected
-- by the client's own usability answer and its "Not enough ..." text, and
-- dropped the moment a read says anything but 0. Jambix AIO's
-- modules/forever_power.lua did this until AIO 1.55.0; these are its tests,
-- moved. Era: the read passes through, nothing counted.

if not jtest then package.path = "scripts/?.lua;" .. package.path end

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- A client and a runtime, just big enough for the service.
local function world(forever)
    local W = {
        clock = 1000.0, in_combat = true, target = { guid = "Creature-0-1-0-0-3124-0000ABCDEF" },
        usable = {}, handlers = {}, regen = 10,
        costs = {
            [1752] = { { cost = 45, min_cost = 45, cost_type = 3 } },     -- Sinister Strike: energy
            [2098] = { { cost = 35, min_cost = 35, cost_type = 3 } },     -- Eviscerate: energy
            [1833] = { { cost = 60, min_cost = 60, cost_type = 3 } },     -- Cheap Shot
            [78]   = { { cost = 15, min_cost = 15, cost_type = 1 } },     -- Heroic Strike: rage
            [133]  = { { cost = 30, min_cost = 30, cost_type = 0 } },     -- Fireball: mana
        },
        texts = {
            [1752] = "An instant strike that causes 3 damage in addition to your normal weapon damage. Awards 1 combo point.",
            [2098] = "Finishing move that causes damage per combo point.",
            [1833] = "Stuns the target for 4 sec. Must be stealthed. Awards 2 combo points.",
            [78] = "A strong attack that increases melee damage by 11.",
            [133] = "Hurls a fiery ball that causes 14 to 22 Fire damage.",
        },
        book = {},
    }
    _G.core = {
        time = function() return W.clock end,
        spell_book = {
            get_spell_costs = function(id) return W.costs[id] end,
            get_spell_description = function(id) return W.texts[id] end,
            get_base_power_regen = function() return W.regen end,
            is_usable_spell = function(id) return W.usable[id] == true end,
            get_spell_name = function() return "" end,
            get_spells = function() return W.book end,
            is_spell_known = function(id) return W.costs[id] ~= nil end,
        },
    }
    local rt = {
        log = { for_tag = function() return { fmt = function() end } end },
        events = { on = function(event, fn)
            W.handlers[event] = W.handlers[event] or {}
            table.insert(W.handlers[event], fn)
        end },
        world = { client = function() return { forever = forever ~= false } end },
        units = { guid = function(u) return u and u.guid end },
        combat = {
            in_combat = function() return W.in_combat end,
            target = function() return W.target end,
        },
    }
    package.loaded["jcore/services/power"] = nil
    W.power = require("jcore/services/power")(rt)
    function W.fire(event, data)
        for _, fn in ipairs(W.handlers[event] or {}) do fn(data) end
    end
    function W.cast(id)
        W.fire("jcore.cast.sent", { spell_id = id })
        W.fire("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", { "player", "Cast-1", id })
    end
    function W.read(kind) return W.power.read(kind, 0) end
    return W
end

local T = {}

T[#T + 1] = { "combo points are counted from our casts: builders by their tooltip, a finisher spends them", function()
    local W = world()
    assert_eq(W.read("COMBOPOINTS"), 0, "nothing yet")
    W.cast(1752); W.cast(1752); W.cast(1752)
    assert_eq(W.read("COMBOPOINTS"), 3, "three Sinister Strikes: three points (the read said 0 every time)")
    W.cast(1833)
    assert_eq(W.read("COMBOPOINTS"), 5, "Cheap Shot awards two, and five is the most")
    assert_eq(W.power.max(4, 0), 5, "out of five (by power id)")
    W.cast(2098)
    assert_eq(W.read("COMBOPOINTS"), 0, "Eviscerate spends them all")

    W.cast(1752); W.cast(1752)
    W.target = { guid = "Creature-0-1-0-0-3125-0000ABCDE0" }
    assert_eq(W.read("COMBOPOINTS"), 2, "a new target keeps them (1.8.12: Forever's points stay with you)")

    W.fire("jcore.cast.sent", { spell_id = 2098 })
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", { 50, "That ability requires combo points", "SPELL_FAILED_NO_COMBO_POINTS" })
    assert_eq(W.read("COMBOPOINTS"), 0, "the client says the finisher needs combo points: none")

    W.usable[2098] = true
    assert_eq(W.read("COMBOPOINTS"), 1, "Eviscerate usable: at least one point")
end }

T[#T + 1] = { "energy: spent by cost, regenerated at the client's rate, corrected both ways", function()
    local W = world()
    assert_eq(W.read("ENERGY"), 100, "a full bar to start")
    assert_eq(W.power.max(3, 0), 100, "out of a hundred")
    W.cast(1752)
    assert_eq(W.read("ENERGY"), 55, "Sinister Strike cost 45")
    W.clock = W.clock + 2
    assert_eq(W.read("ENERGY"), 75, "two seconds at ten a second")
    W.fire("jcore.cast.sent", { spell_id = 1752 })
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", { 62, "Not enough energy", "ERR_OUT_OF_ENERGY" })
    assert_eq(W.read("ENERGY"), 44, "the client says less than 45: 44")
    W.cast(1752)
    W.cast(2098)
    assert(W.read("ENERGY") < 45, "spent down")
    W.usable[1752] = true
    assert_eq(W.read("ENERGY"), 45, "Sinister Strike usable: at least 45")
end }

T[#T + 1] = { "a read that says anything but 0 is trusted from then on", function()
    local W = world()
    W.cast(1752)
    assert_eq(W.read("ENERGY"), 55, "counted")
    assert_eq(W.power.read(3, 37), 37, "the client read 37: that is the answer")
    assert_eq(W.power.read(3, 0), 0, "and from then on its 0 is a real 0")
    assert_eq(W.power.counted(3), false, "no longer counted")
    assert_eq(W.power.max(3, 100), 100, "its maximum too")
end }

T[#T + 1] = { "rage: nothing is readable but the client's usability; it fades out of combat", function()
    local W = world()
    assert_eq(W.read("RAGE"), 0, "starts empty")
    W.usable[78] = true
    W.cast(78)
    W.usable[78] = true
    assert_eq(W.read("RAGE"), 15, "Heroic Strike usable: at least 15")
    W.usable[78] = false
    W.in_combat = false
    W.clock = W.clock + 4
    assert_eq(W.read("RAGE"), 10, "four seconds out of combat: 1.25 a second gone")
end }

T[#T + 1] = { "every known spell is a probe from the start: a warrior's first Heroic Strike is not waited on", function()
    local W = world()
    W.book = { 78 }
    W.usable[78] = true
    assert_eq(W.read("RAGE"), 15, "usable before it was ever cast: at least its cost")
end }

T[#T + 1] = { "mana is not counted (no maximum to count against): fine, or dry after the client says so", function()
    local W = world()
    assert_eq(W.power.read(0, 0), 0, "the read passes through")
    assert_eq(W.power.max(0, 0), 0, "0 of 0: no information")
    assert_eq(W.power.unread(0), 1, "and the rotation is told it is fine")
    W.cast(133)
    W.fire("jcore.game_event.UI_ERROR_MESSAGE", { 62, "Not enough mana", "ERR_OUT_OF_MANA" })
    assert_eq(W.power.unread(0), 0.05, "the client said not enough: dry")
    W.usable[133] = true
    assert_eq(W.power.unread(0), 1, "a spell that costs mana is usable again: fine")
    assert_eq(W.power.unread(3), nil, "a counted resource is not 'unread'")
    assert_eq(W.power.read(0, 812), 812, "a real mana read is trusted")
    assert_eq(W.power.unread(0), nil, "and then it is not unread either")
end }

T[#T + 1] = { "Era: every read passes through; nothing counted, nothing unread", function()
    local W = world(false)
    W.cast(1752)
    assert_eq(W.power.read(3, 0), 0, "the client's 0 is the answer")
    assert_eq(W.power.read(4, 2), 2, "and its 2")
    assert_eq(W.power.max(3, 0), 0, "no made-up maximum")
    assert_eq(W.power.counted(3), false, "nothing counted")
    assert_eq(W.power.unread(0), nil, "nothing unread")
end }

return T

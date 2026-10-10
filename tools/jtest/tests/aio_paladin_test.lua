-- Jambix AIO: the paladin's rule predicates (modules/classes/paladin.lua),
-- asked directly with a hand-built H and snapshot (1.77.1).
--
-- From the 1.77.1 review: a seal not on the old five-name list read as no
-- seal (Judgement never went out under Wisdom, Light, Justice or Forever's
-- Seal of Fury), only the levelling list kept an aura up, Exorcism was
-- pressed at every creature type, and the group's tank under 20 points
-- played the levelling list.

local root = (jtest and jtest.scripts) or "scripts"
package.path = package.path .. ";" .. root .. "/?.lua"   -- after JTEST_OVERLAY, so a staged copy wins

local make_paladin = require("jambix_aio/modules/classes/paladin")

local function assert_eq(got, want, label)
    if got ~= want then
        error(string.format("%s: expected %s, got %s", label, tostring(want), tostring(got)), 2)
    end
end

--- The class module over a fake H whose buffs are `W.buffs` (name -> true).
local function paladin()
    local W = {
        buffs = {},              -- name (or "ids:<first id>") -> true, on you
        rows = {},               -- unit -> aura rows by name, for aura_named
        melee = true, talents = {}, swinging = true, since = math.huge, swing = 3.0,
        hurt = 0, loose = nil, cooldown = {}, known = {},
    }
    local H = {
        book = {
            cooldown = function(name) return W.cooldown[name] or 0 end,
            known = function(name) return W.known[name] ~= false end,
        },
        targeting = { reclaim_target = function() return W.loose end },
        buff_up = function(_, name)
            if type(name) == "table" then return W.buffs["ids:" .. name[1]] == true end
            return W.buffs[name] == true
        end,
        units = {
            aura_index = function(unit)
                local out = {}
                for name in pairs(W.rows[unit] or {}) do out[#out + 1] = { buff_name = name } end
                return out
            end,
        },
        in_melee = function() return W.melee end,
        melee_start_wanted = function() return W.melee end,
        power_fraction = function() return 1 end,
        execute_phase = function() return false end,
        spread = function() return false end,
        bleeding = function() return false end,
        has_talent = function(name) return W.talents[name] == true end,
        since_cast = function() return W.since end,
        swing_period = function() return W.swing end,
    }
    local P = {
        derived = function(_, pct) return pct / 100 end,
        opt = function(_, default) return default end,
        optpct = function(_, default) return default / 100 end,
        tune_secs = function(_, default) return default end,
        ctx = { group = { count_below = function() return W.hurt end } },
    }
    W.class = make_paladin(P, H, {})
    W.player = { is_auto_attacking = function() return W.swinging end }
    function W.rule(profile, name)
        local rules = W.class.profiles[profile].rules
        for i = 1, #rules do
            if rules[i][1] == name then return rules[i] end
        end
        error("no " .. name .. " rule in " .. profile, 2)
    end
    --- Asks a rule with a snapshot.
    function W.ask(profile, name, s)
        s = s or {}
        s.player = s.player or W.player
        if s.in_combat == nil then s.in_combat = true end
        s.hp = s.hp or 1
        return W.rule(profile, name)[2](s) == true
    end
    return W
end

local T = {}

T[#T + 1] = { "any seal counts: Judgement goes out under Wisdom, Light, Justice and Seal of Fury", function()
    local W = paladin()
    local target = {}
    assert_eq(W.ask("leveling", "Judgement", { target = target }), false, "no seal: no Judgement")
    assert_eq(W.ask("leveling", "Seal of Righteousness", { target = target }), true, "no seal: one goes up")
    for _, seal in ipairs({ "Seal of Wisdom", "Seal of Light", "Seal of Justice", "Seal of Fury",
                            "Seal of Righteousness", "Seal of Command" }) do
        W.buffs = { [seal] = true }
        assert_eq(W.ask("leveling", "Judgement", { target = target }), true, seal .. ": Judgement")
        assert_eq(W.ask("leveling", "Seal of Righteousness", { target = target }), false,
            seal .. ": not covered by Righteousness")
    end
end }

T[#T + 1] = { "the tank's seal: Seal of Fury first where it is trained", function()
    local W = paladin()
    local rules = W.class.profiles.protection.rules
    local fury, righteousness
    for i = 1, #rules do
        if rules[i][1] == "Seal of Fury" then fury = i end
        if rules[i][1] == "Seal of Righteousness" then righteousness = i end
    end
    assert(fury and righteousness and fury < righteousness, "Seal of Fury before Righteousness")
end }

T[#T + 1] = { "seals: in a fight, or out of one with an enemy picked within 30 yards; never with nobody about (1.7.5)", function()
    local W = paladin()
    -- The plain upkeep rule of each profile (Retribution's first two are the
    -- Twist of Light swaps).
    local function upkeep_rule(profile, name)
        local rules = W.class.profiles[profile].rules
        for i = 1, #rules do
            if rules[i][1] == name and rules[i].upkeep == 2 then return rules[i] end
        end
        error("no upkeep rule for " .. name .. " in " .. profile, 2)
    end
    local function wants(profile, name, s)
        s.player = W.player
        s.hp = 1
        return upkeep_rule(profile, name)[2](s) == true
    end
    local enemy = {}
    for _, case in ipairs({ { "leveling", "Seal of Righteousness" }, { "retribution", "Seal of Command" },
                            { "retribution", "Seal of Righteousness" }, { "protection", "Seal of Fury" },
                            { "protection", "Seal of Righteousness" } }) do
        local profile, seal = case[1], case[2]
        local label = profile .. ", " .. seal
        W.buffs = {}
        assert_eq(wants(profile, seal, { in_combat = true }), true, label .. ": in a fight")
        assert_eq(wants(profile, seal, { in_combat = false }), false, label .. ": nobody about")
        assert_eq(wants(profile, seal, { in_combat = false, target = enemy, distance = 25 }), true,
            label .. ": an enemy picked at 25 yd, before the pull")
        assert_eq(wants(profile, seal, { in_combat = false, target = enemy, distance = 45 }), false,
            label .. ": an enemy picked at 45 yd")
        W.buffs = { ["Seal of Wisdom"] = true }
        assert_eq(wants(profile, seal, { in_combat = true }), false, label .. ": a seal up already")
    end
end }

T[#T + 1] = { "auras: every profile keeps one up out of combat, and leaves any aura already up", function()
    local W = paladin()
    for _, profile in ipairs({ "leveling", "retribution", "protection" }) do
        W.buffs = {}
        assert_eq(W.ask(profile, "Devotion Aura", { in_combat = false }), true, profile .. ": none up")
        assert_eq(W.ask(profile, "Devotion Aura", { in_combat = true }), false, profile .. ": not in combat")
        W.buffs = { ["Concentration Aura"] = true }
        assert_eq(W.ask(profile, "Devotion Aura", { in_combat = false }), false,
            profile .. ": a Concentration Aura you chose stays")
    end
    -- Retribution prefers its own aura: listed first.
    local rules = W.class.profiles.retribution.rules
    local ret, dev
    for i = 1, #rules do
        if rules[i][1] == "Retribution Aura" then ret = i end
        if rules[i][1] == "Devotion Aura" then dev = i end
    end
    assert(ret and dev and ret < dev, "Retribution Aura before Devotion for Retribution")
end }

T[#T + 1] = { "Exorcism: demons and undead only; an unread type is left to the client", function()
    local W = paladin()
    local function mob(kind)
        return { get_creature_type = function() return kind end }
    end
    assert_eq(W.ask("leveling", "Exorcism", { target = mob(6) }), true, "undead")
    assert_eq(W.ask("leveling", "Exorcism", { target = mob(3) }), true, "demon")
    assert_eq(W.ask("leveling", "Exorcism", { target = mob(1) }), false, "a beast")
    assert_eq(W.ask("leveling", "Exorcism", { target = mob(7) }), false, "a humanoid")
    assert_eq(W.ask("leveling", "Exorcism", { target = mob(nil) }), true, "unread")
    assert_eq(W.ask("leveling", "Exorcism", {}), false, "no target")
end }

T[#T + 1] = { "Holy Strike: in melee only, in every profile that fights", function()
    local W = paladin()
    local target = {}
    for _, profile in ipairs({ "leveling", "retribution", "protection" }) do
        W.melee = true
        assert_eq(W.ask(profile, "Holy Strike", { target = target }), true, profile .. ": in melee")
        W.melee = false
        assert_eq(W.ask(profile, "Holy Strike", { target = target }), false, profile .. ": out of reach")
    end
    W.melee = true
    assert_eq(W.ask("holy", "Holy Strike", { target = target }), true, "holy: in melee, in combat")
    assert_eq(W.ask("holy", "Holy Strike", { target = target, in_combat = false }), false, "holy: not out of combat")
end }

T[#T + 1] = { "the profile: the group's tank under 20 points tanks; otherwise as before", function()
    local W = paladin()
    local function talents(holy, prot, ret)
        return { points = function() return holy, prot, ret end }
    end
    assert_eq(W.class.suggest(talents(0, 0, 0), false), "leveling", "level 9, solo")
    assert_eq(W.class.suggest(talents(0, 0, 0), true), "protection", "level 9, the group's tank")
    assert_eq(W.class.suggest(talents(0, 5, 21), false), "retribution", "Retribution")
    assert_eq(W.class.suggest(talents(0, 5, 21), true), "protection", "Retribution, the group's tank")
    assert_eq(W.class.suggest(talents(21, 5, 0), false), "holy", "Holy")
end }

T[#T + 1] = { "talents on Forever: the trees from the names, not the one tab the client names", function()
    local W = paladin()
    -- Forever: every point on tab 1 (Holy), whatever the build.
    local function forever(points, ranks)
        return {
            points = function() return points, 0, 0 end,
            stats = function() return { source = "traits" } end,
            rank = function(name) return ranks[name] or 0 end,
        }
    end
    local ret = { ["Benediction"] = 5, ["Improved Judgement"] = 2, ["Seal of Command"] = 1,
                  ["Conviction"] = 5, ["Two-Handed Weapon Specialization"] = 3, ["Sacred Arbiter"] = 3,
                  ["Divine Intellect"] = 2 }
    assert_eq(W.class.suggest(forever(21, ret), false), "retribution", "a Retribution build on Forever")
    local prot = { ["Redoubt"] = 5, ["Toughness"] = 5, ["Improved Righteous Fury"] = 3,
                   ["Shield Specialization"] = 3, ["Blessing of Sanctuary"] = 1, ["Reckoning"] = 4 }
    assert_eq(W.class.suggest(forever(21, prot), false), "protection", "a Protection build on Forever")
    local holy = { ["Divine Intellect"] = 5, ["Spiritual Focus"] = 5, ["Healing Light"] = 3,
                   ["Illumination"] = 5, ["Divine Favor"] = 1, ["Holy Power"] = 2 }
    assert_eq(W.class.suggest(forever(21, holy), false), "holy", "a Holy build on Forever")
    -- Names it does not know: the module's own split, as before.
    assert_eq(W.class.suggest(forever(21, { ["Something New"] = 5 }), false), "holy", "unknown names")
    -- Era reads three trees: its split stands, the names are not asked.
    local era = {
        points = function() return 0, 0, 21 end,
        stats = function() return { source = "trees" } end,
        rank = function() error("not asked on Era") end,
    }
    assert_eq(W.class.suggest(era, false), "retribution", "Era")
end }

T[#T + 1] = { "blessings: any one up is one; the party list never blesses you; Forbearance locks the bubbles", function()
    local W = paladin()
    for _, b in ipairs({ "Blessing of Salvation", "Blessing of Light", "Greater Blessing of Kings",
                         "Greater Blessing of Wisdom", "Blessing of Sanctuary" }) do
        W.buffs = { [b] = true }
        assert_eq(W.ask("leveling", "Blessing of Might", { in_combat = false }), false, b .. " counts")
    end
    W.buffs = {}
    assert_eq(W.ask("leveling", "Blessing of Might", { in_combat = false }), true, "none: Might")
    assert_eq(W.class.buff_others_only, true, "your own blessing is the profile's")
    for _, name in ipairs({ "Divine Shield", "Divine Protection", "Blessing of Protection", "Templar's Bulwark" }) do
        assert_eq(W.class.locked_by[name] and W.class.locked_by[name].name, "Forbearance", name)
    end
    assert_eq(W.class.locked_by["Lay on Hands"], nil, "Lay on Hands is not locked on Classic")
end }

T[#T + 1] = { "Twist of Light: one seal swap a swing, never over a waiting echo (1.77.4)", function()
    local W = paladin()
    local target = {}
    local function twist() return W.ask("retribution", "Seal of Righteousness", { target = target }) end
    W.buffs = { ["Seal of Command"] = true }
    assert_eq(twist(), false, "not talented: no swap")
    W.talents["Twist of Light"] = true
    assert_eq(twist(), true, "Command up, swinging, no echo: swap to Righteousness")
    -- Its mirror: Righteousness up swaps back to Command.
    W.buffs = { ["Seal of Righteousness"] = true }
    assert_eq(W.ask("retribution", "Seal of Command", { target = target }), true, "and back to Command")
    W.buffs = { ["Seal of Command"] = true }

    W.rows[W.player] = { ["Echo of Command"] = true }
    assert_eq(twist(), false, "an echo waits for the swing (by name)")
    W.rows[W.player] = {}
    W.buffs["ids:1311701"] = true
    assert_eq(twist(), false, "an echo waits for the swing (by id)")
    W.buffs["ids:1311701"] = nil

    W.since = 1.0
    assert_eq(twist(), false, "swapped a moment ago: one swap a swing")
    W.since = 2.6
    assert_eq(twist(), true, "most of a 3 s swing later")
    W.swinging = false
    assert_eq(twist(), false, "not swinging")
    W.swinging = true
    W.melee = false
    assert_eq(twist(), false, "out of melee")
    W.melee = true
    assert_eq(twist(), true, "back in melee")
    assert_eq(W.ask("retribution", "Seal of Righteousness", { target = target, in_combat = false }), false,
        "out of combat")
end }

T[#T + 1] = { "the tank's Judgement under Seal of Fury, and Swift Judgement for it (1.77.4)", function()
    local W = paladin()
    local loose = {}
    W.buffs = { ["Seal of Fury"] = true }
    local s = {}
    assert_eq(W.ask("protection", "Judgement", s), false, "nothing loose: no taunt")
    W.loose = loose
    s = {}
    assert_eq(W.ask("protection", "Judgement", s), true, "a mob loose: Judgement at it")
    assert_eq(s.reclaim, loose, "aimed at the loose mob")
    W.buffs = { ["Seal of Righteousness"] = true }
    assert_eq(W.ask("protection", "Judgement", {}), false, "no Seal of Fury: no taunt in it")

    W.buffs = { ["Seal of Fury"] = true }
    assert_eq(W.ask("protection", "Swift Judgement", {}), false, "Judgement ready: nothing to finish")
    W.cooldown["Judgement"] = 6
    assert_eq(W.ask("protection", "Swift Judgement", {}), true, "loose, Judgement 6 s away: finish it")
    W.loose = nil
    assert_eq(W.ask("protection", "Swift Judgement", {}), false, "nothing loose: keep it")
    -- Off the global cooldown, as the client's tables have it.
    assert_eq(W.rule("protection", "Swift Judgement").fast, true, "off the global cooldown")
    for _, rule in ipairs(W.class.profiles.protection.rules) do
        assert(rule[1] ~= "Righteous Defense", "Righteous Defense is on neither client")
    end
end }

T[#T + 1] = { "Holy: a seal for its Judgement, Light's Vigil, Holy Shock on it, Voice of Truth (1.77.4)", function()
    local W = paladin()
    local ally = {}
    assert_eq(W.ask("holy", "Seal of Wisdom", {}), true, "no seal in combat: Wisdom")
    W.buffs = { ["Seal of Wisdom"] = true }
    assert_eq(W.ask("holy", "Seal of Wisdom", {}), false, "one is up")
    assert_eq(W.ask("holy", "Judgement", {}), true, "and Judgement goes out under it")
    assert_eq(W.ask("holy", "Seal of Wisdom", { in_combat = false }), false, "not out of combat")

    W.hurt = 2
    assert_eq(W.ask("holy", "Light's Vigil", { ally = ally, ally_hp = 0.7 }), false, "two hurt: not worth its cast")
    W.hurt = 3
    assert_eq(W.ask("holy", "Light's Vigil", { ally = ally, ally_hp = 0.7 }), true, "three hurt: Light's Vigil")
    W.rows[ally] = { ["Light's Vigil"] = true }
    assert_eq(W.ask("holy", "Light's Vigil", { ally = ally, ally_hp = 0.7 }), false, "already on them")
    assert_eq(W.ask("holy", "Holy Shock", { ally = ally, ally_hp = 0.7 }), true, "Holy Shock on the vigil")
    W.rows[ally] = {}
    assert_eq(W.ask("holy", "Holy Shock", { ally = ally, ally_hp = 0.7 }), false, "no vigil, 70%: no Holy Shock")
    W.known["Holy Shock"] = false
    W.hurt = 3
    assert_eq(W.ask("holy", "Light's Vigil", { ally = ally, ally_hp = 0.7 }), false, "no Holy Shock: no vigil")

    local caster = { targeting_me = true, casting = { name = "Silence" } }
    assert_eq(W.ask("holy", "Voice of Truth", { ally = ally, ally_hp = 0.3, enemies = {} }), false, "nothing to stop it")
    assert_eq(W.ask("holy", "Voice of Truth", { ally = ally, ally_hp = 0.3, enemies = { caster } }), true,
        "a heal due and a mob casting at you")
    assert_eq(W.ask("holy", "Voice of Truth", { ally = ally, ally_hp = 0.9, enemies = { caster } }), false,
        "no heal due")
    local rogue = { targeting_me = true, dist = 4, obj = { is_player = function() return true end } }
    assert_eq(W.ask("holy", "Voice of Truth", { ally = ally, ally_hp = 0.3, enemies = { rogue } }), true,
        "an enemy player in reach of you")
    assert_eq(W.rule("holy", "Voice of Truth").fast, true, "off the global cooldown")
end }

T[#T + 1] = { "Repentance: humanoids only, an interrupt after Hammer of Justice (1.77.4)", function()
    local W = paladin()
    assert_eq(W.class.creature_types["Repentance"][1], 7, "humanoids")
    local list = W.class.interrupts
    local hoj, rep
    for i = 1, #list do
        if list[i] == "Hammer of Justice" then hoj = i end
        if list[i] == "Repentance" then rep = i end
    end
    assert(hoj and rep and hoj < rep, "Repentance after Hammer of Justice")
    assert_eq(W.class.creature_types["Exorcism"][2], 6, "Exorcism: undead (and demons)")
end }

T[#T + 1] = { "spellbook: a spell the class locks behind an aura is not ready while the aura is up", function()
    local ids = { [642] = "Divine Shield", [498] = "Divine Protection", [633] = "Lay on Hands" }
    _G.core = {
        time = function() return 100 end,
        spell_book = {
            get_spells = function() return { 642, 498, 633 } end,
            get_spell_name = function(id) return ids[id] or "" end,
            is_spell_known = function(id) return ids[id] ~= nil end,
        },
    }
    local aura_rows = {}
    local player = {}
    local P = {
        log = { once = function() end, fmt = function() end, info = function() end },
        ctx = {
            on = function() end, every = function() end, emit = function() end,
            spells = {
                ready = function() return true end,
                castable = function() return true end,
                learned = function(id) return ids[id] ~= nil, "known" end,
            },
        },
        units = {
            player = function() return player end,
            aura_index = function() return aura_rows end,
        },
    }
    local book = require("jambix_aio/modules/spellbook")(P)
    book.refresh()
    local W = paladin()
    P.rotation = { active_class = function() return W.class end }

    assert_eq(book.ready("Divine Shield"), true, "no Forbearance: ready")
    aura_rows = { [25771] = { buff_id = 25771, buff_name = "Forbearance" } }
    assert_eq(book.ready("Divine Shield"), false, "Forbearance by id: locked")
    assert_eq(book.ready("Divine Protection"), false, "and Divine Protection")
    assert_eq(book.castable("Divine Protection", player), false, "castable says so too")
    assert_eq(book.ready("Lay on Hands"), true, "Lay on Hands is free: the defensive list reaches it")
    -- Another client's id for it: the name.
    aura_rows = { [1234567] = { buff_id = 1234567, buff_name = "Forbearance" } }
    assert_eq(book.ready("Divine Shield"), false, "Forbearance by name: locked")
    aura_rows = {}
    assert_eq(book.ready("Divine Shield"), true, "gone: ready again")
end }

return T

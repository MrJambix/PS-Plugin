-- Jambix AIO / classes / paladin

return function(P, H, CS)
    local book, targeting = H.book, H.targeting

    local function low_mana(s) return H.power_fraction(s) < 0.2 end

    -- EVERY SEAL (1.77.1). The list had five, so a seal not on it read as no
    -- seal at all: Wisdom, Light or Justice kept by the class window, and
    -- Forever's Seal of Fury (its tanking seal, level 10). Righteousness was
    -- then put over it, and Judgement, which waits for a seal, never went out.
    local SEALS = {
        "Seal of Righteousness", "Seal of Command", "Seal of the Crusader",
        "Seal of Fury", "Seal of Wisdom", "Seal of Light", "Seal of Justice",
        "Seal of Vengeance", "Seal of Blood",
    }

    --- Seals fall off after 30 seconds and are the paladin's entire damage
    --- model, so keeping one up outranks everything except Judgement.
    local function seal_missing(s)
        for i = 1, #SEALS do
            if H.buff_up(s.player, SEALS[i]) then return false end
        end
        return true
    end

    --- A seal to put up (1.7.5): in a fight, or out of one with an enemy
    --- picked within SEAL_AHEAD yards, so the opening Judgement has one. It
    --- went up every 30 s with nobody about: four seals in two minutes of an
    --- idle offline run, each one mana and five seconds without regeneration.
    local SEAL_AHEAD = 30
    local function seal_wanted(s)
        if not seal_missing(s) then return false end
        if s.in_combat then return true end
        return s.target ~= nil and (s.distance or math.huge) <= SEAL_AHEAD
    end

    --- Judgement releases the seal (on Era it consumes it; on Forever the
    --- seal stays), so it only fires while there is one -- otherwise it is a
    --- wasted global cooldown and a wasted cooldown on the Judgement itself.
    local function judgement_ready(s)
        return not seal_missing(s)
    end

    --- In melee with the target. Holy Strike has no catalogue row to say so,
    --- and on Forever the client gives no range, so a press from further out
    --- would only be refused.
    local function in_melee(s)
        return s.target ~= nil and H.in_melee(s.target, s.distance)
    end

    -- WHAT A SPELL TAKES (from the client's tables, Era and Forever alike):
    -- Exorcism and Holy Wrath demons (3) and undead (6), Turn Undead undead,
    -- Repentance humanoids (7). The client refuses anything else with red
    -- text, and on Forever nothing stopped the next press. Handed to the
    -- rotation as `creature_types` (1.77.4), so the walk and every reaction
    -- -- Repentance as an interrupt, or on an add -- are held by it too.
    local CREATURE_TYPES = {
        ["Exorcism"] = { 3, 6 }, ["Holy Wrath"] = { 3, 6 },
        ["Turn Undead"] = { 6 }, ["Repentance"] = { 7 },
    }

    --- Does `name` take the target? A type the client does not say: yes, and
    --- the client decides, as before.
    local function works_on(s, name)
        if not s.target then return false end
        local only = CREATURE_TYPES[name]
        if not only then return true end
        local ok, kind = pcall(s.target.get_creature_type, s.target)
        if not ok or type(kind) ~= "number" or kind <= 0 then return true end
        for i = 1, #only do
            if only[i] == kind then return true end
        end
        return false
    end

    local function exorcism_target(s) return works_on(s, "Exorcism") end

    --- An aura on `unit` by its name, or by how its name starts (`prefix`).
    --- For auras that are no spell of yours to look up by: the echoes Twist
    --- of Light leaves on you, Light's Vigil on an ally.
    local function aura_named(unit, name, prefix)
        local units = H.units
        if not unit or not (units and units.aura_index) then return false end
        local ok, index = pcall(units.aura_index, unit)
        if not ok or type(index) ~= "table" then return false end
        for _, row in pairs(index) do
            local n = type(row) == "table" and row.buff_name or nil
            if type(n) == "string" and (n == name or (prefix and n:sub(1, #name) == name)) then
                return true
            end
        end
        return false
    end

    -- TWIST OF LIGHT (Forever, Retribution; passive, 1.77.4). Replacing
    -- Command, Righteousness, Fury or Justice with another seal leaves an
    -- Echo of the old one, and your next swing applies it as well. So with
    -- Command and Righteousness both trained the seal is swapped once each
    -- swing, and each swing carries both. Never while an echo waits: a second
    -- swap before the swing would replace it unused. Echo of Fury, Command,
    -- Righteousness and Justice, from the client's tables; the name too.
    local ECHOES = { 1311701, 1311703, 1311704, 1311705 }

    local function echo_up(s)
        return H.buff_up(s.player, ECHOES) or aura_named(s.player, "Echo of ", true)
    end

    --- The seal to swap to, from `from`, when Twist of Light wants a swap now.
    local function twist_from(from)
        return function(s)
            if not (H.has_talent and H.has_talent("Twist of Light")) then return false end
            if not s.in_combat or not in_melee(s) or low_mana(s) then return false end
            if not H.buff_up(s.player, from) or echo_up(s) then return false end
            local ok, swinging = pcall(s.player.is_auto_attacking, s.player)
            if not (ok and swinging == true) then return false end
            local since = math.min(H.since_cast("Seal of Command"), H.since_cast("Seal of Righteousness"))
            local swing = (H.swing_period and H.swing_period()) or 3.0
            return since >= swing * 0.8
        end
    end

    --- A mob loose from the tank, put where the rule's `retarget` reads it.
    local function loose_mob(s)
        local loose = targeting.reclaim_target(P.tune_secs("rot_target_range", 30))
        if not loose then return false end
        s.reclaim = loose
        return true
    end

    --- Party members under `line` within 40 yards, you included.
    local function party_hurt(line)
        local group = P.ctx and P.ctx.group
        if not (group and group.count_below) then return 0 end
        local ok, n = pcall(group.count_below, line, 40)
        return ok and tonumber(n) or 0
    end

    --- Something that would stop a heal: a mob casting at you (a silence), or
    --- an enemy player in reach of you (a kick).
    local function interrupt_threat(s)
        local list = s.enemies or {}
        for i = 1, #list do
            local row = list[i]
            if row and row.targeting_me then
                if row.casting then return true end
                local obj = row.obj
                if obj and (tonumber(row.dist) or math.huge) <= 8 then
                    local ok, player = pcall(obj.is_player, obj)
                    if ok and player == true then return true end
                end
            end
        end
        return false
    end

    -- EVERY AURA (1.77.1). Only the levelling list kept one up, so a
    -- Retribution or Protection paladin on Auto fought with none; and that
    -- list knew two, so a Concentration Aura you chose was put back to
    -- Devotion. Out of combat, as before; an aura lasts until it is changed.
    local AURAS = {
        "Devotion Aura", "Retribution Aura", "Concentration Aura", "Sanctity Aura",
        "Shadow Resistance Aura", "Frost Resistance Aura", "Fire Resistance Aura",
        "Crusader Aura",
    }

    local function aura_missing(s)
        if s.in_combat then return false end
        for i = 1, #AURAS do
            if H.buff_up(s.player, AURAS[i]) then return false end
        end
        return true
    end

    -- EVERY BLESSING (1.77.1): a paladin's blessing on a target replaces its
    -- last one there, so any of these up means one is. Salvation, Light and
    -- the Greater ones were missing: the profile's blessing went over a
    -- Greater Blessing of Kings (and its Symbol) on you, and the group list
    -- over your Salvation on a party member.
    local BLESSINGS = {
        "Blessing of Might", "Blessing of Wisdom", "Blessing of Kings", "Blessing of Sanctuary",
        "Blessing of Salvation", "Blessing of Light",
        "Greater Blessing of Might", "Greater Blessing of Wisdom", "Greater Blessing of Kings",
        "Greater Blessing of Sanctuary", "Greater Blessing of Salvation", "Greater Blessing of Light",
    }

    local function blessing_missing(s)
        if s.in_combat then return false end
        for i = 1, #BLESSINGS do
            if H.buff_up(s.player, BLESSINGS[i]) then return false end
        end
        return true
    end

    -- FORBEARANCE (1.77.1): after Divine Shield, Divine Protection, Blessing
    -- of Protection or Forever's Templar's Bulwark, none of them can go for a
    -- minute. Nothing knew: see spellbook.lua (`locked_by`).
    local FORBEARANCE = { name = "Forbearance", ids = { 25771 } }

    -- THE TREES BY NAME (1.77.1). On Forever every talent sits in one trait
    -- tree, and talents.lua gives each point to the tab the client's
    -- specialization names, 1 on the recording, which is Holy: past 20
    -- points a Retribution or Protection build was played as a healer. These
    -- are the Classic trees, and Forever's new talents whose tree the guides
    -- agree on; a name not here counts nowhere.
    local TREE_OF = {}
    for tab, names in ipairs({
        { "Divine Strength", "Divine Intellect", "Spiritual Focus", "Improved Seal of Righteousness",
          "Healing Light", "Consecration", "Improved Lay on Hands", "Unyielding Faith", "Illumination",
          "Improved Blessing of Wisdom", "Divine Favor", "Lasting Judgement", "Holy Power", "Holy Shock",
          "Light's Vigil", "Voice of Truth" },
        { "Improved Devotion Aura", "Redoubt", "Precision", "Guardian's Favor", "Toughness",
          "Blessing of Kings", "Improved Righteous Fury", "Shield Specialization", "Anticipation",
          "Improved Hammer of Justice", "Improved Concentration Aura", "Blessing of Sanctuary", "Reckoning",
          "One-Handed Weapon Specialization", "Holy Shield", "Templar's Bulwark", "Improved Seal of Fury" },
        { "Improved Blessing of Might", "Benediction", "Improved Judgement", "Improved Seal of the Crusader",
          "Deflection", "Vindication", "Conviction", "Seal of Command", "Pursuit of Justice", "Eye for an Eye",
          "Improved Retribution Aura", "Two-Handed Weapon Specialization", "Sanctity Aura", "Vengeance",
          "Repentance", "Twist of Light", "Sacred Arbiter", "Holy Conduit" },
    }) do
        for _, name in ipairs(names) do TREE_OF[name] = tab end
    end

    --- Holy, Protection, Retribution points. The talents module's own split
    --- where it read three trees (Era), or Forever's one tree by the client's
    --- own node columns (1.77.3: every talent, the new ones included); on a
    --- trait client without that, the names above, unless they find nothing.
    local function tree_points(t)
        local holy, prot, ret = t.points()
        local ok, stats = pcall(function() return t.stats and t.stats() end)
        if not (ok and type(stats) == "table" and stats.source == "traits") or stats.split == "nodes"
            or type(t.rank) ~= "function" then
            return holy, prot, ret
        end
        local by = { 0, 0, 0 }
        for name, tab in pairs(TREE_OF) do
            by[tab] = by[tab] + (tonumber(t.rank(name)) or 0)
        end
        if by[1] + by[2] + by[3] == 0 then return holy, prot, ret end
        return by[1], by[2], by[3]
    end

    --- The melee swing (1.76.1). Nothing a paladin presses before Crusader
    --- Strike (Era) or Holy Strike (Forever) starts it, and the swing is most
    --- of the damage while levelling. Off the global cooldown, sent as the client's START
    --- (`direct`), so it never displaces a Judgement and never switches a
    --- running swing off; the upkeep spaces the presses while the client
    --- has not caught up.
    local ATTACK = { "Attack", H.melee_start_wanted, direct = true, fast = true, upkeep = 1 }

    -- HOLY STRIKE (Forever, baseline at level 6): an instant melee strike,
    -- weapon and Holy damage, on its own 10 to 12 s cooldown. The rotation
    -- did not know it, so a Forever paladin's one real attack button was
    -- never pressed. Retribution presses it before Judgement. Unknown on
    -- Era, where the rule is never a candidate.
    local HOLY_STRIKE = { "Holy Strike", in_melee, upkeep = 1 }

    local function emergency_heal(s)
        -- The line is the fight's: the derived defensive line, or sooner while
        -- health is draining fast (1.35.x; was a 40% slider).
        local line = P.derived and P.derived("rot_defensive_hp", 40) or 0.40
        return s.in_combat and (s.hp < line + 0.05 or (H.bleeding() and s.hp < 0.6))
    end

    local profiles = {}

    profiles.leveling = {
        label = "Levelling (Retribution)",
        power = "MANA",
        rules = {
            { "Blessing of Might", blessing_missing, self = true, upkeep = 30 },
            { "Devotion Aura", aura_missing, self = true, upkeep = 30 },
            { "Holy Light", emergency_heal, self = true, upkeep = 2 },
            { "Flash of Light", emergency_heal, self = true, upkeep = 2 },
            { "Lay on Hands", function(s)
                return s.in_combat and s.hp < 0.15
            end, self = true, upkeep = 60 },
            ATTACK,
            { "Seal of Righteousness", seal_wanted, self = true, upkeep = 2 },
            HOLY_STRIKE,
            { "Judgement", judgement_ready, upkeep = 1 },
            { "Hammer of Wrath", function(s) return H.execute_phase(s, 0.2) end, upkeep = 1 },
            { "Crusader Strike", function() return true end },
            { "Exorcism", exorcism_target, upkeep = 2 },
            { "Consecration", function(s)
                return H.spread(s, 2) and not low_mana(s)
            end, self = true, upkeep = 8 },
        },
    }

    profiles.retribution = {
        label = "Retribution",
        power = "MANA",
        rules = {
            -- Kings where it is trained (Forever: everyone's at 20), else Might.
            { "Blessing of Kings", blessing_missing, self = true, upkeep = 30 },
            { "Blessing of Might", blessing_missing, self = true, upkeep = 30 },
            { "Sanctity Aura", aura_missing, self = true, upkeep = 30 },
            { "Retribution Aura", aura_missing, self = true, upkeep = 30 },
            { "Devotion Aura", aura_missing, self = true, upkeep = 30 },
            { "Holy Light", emergency_heal, self = true, upkeep = 2 },
            ATTACK,
            -- Twist of Light: one swap a swing (1.77.4).
            { "Seal of Righteousness", twist_from("Seal of Command"), self = true, upkeep = 1 },
            { "Seal of Command", twist_from("Seal of Righteousness"), self = true, upkeep = 1 },
            { "Seal of Command", seal_wanted, self = true, upkeep = 2 },
            { "Seal of Righteousness", seal_wanted, self = true, upkeep = 2 },
            HOLY_STRIKE,
            { "Judgement", judgement_ready, upkeep = 1 },
            { "Hammer of Wrath", function(s) return H.execute_phase(s, 0.2) end, upkeep = 1 },
            { "Crusader Strike", function() return true end },
            { "Divine Storm", function(s) return H.spread(s, 2) end, self = true },
            { "Consecration", function(s) return H.spread(s, 2) end, self = true, upkeep = 8 },
            { "Exorcism", exorcism_target, upkeep = 2 },
        },
    }

    profiles.protection = {
        label = "Protection (tank)",
        power = "MANA",
        rules = {
            { "Blessing of Sanctuary", blessing_missing, self = true, upkeep = 30 },
            -- Forever has no Sanctuary; its tanks take Kings.
            { "Blessing of Kings", blessing_missing, self = true, upkeep = 30 },
            { "Devotion Aura", aura_missing, self = true, upkeep = 30 },
            { "Righteous Fury", function(s)
                return not H.buff_up(s.player, "Righteous Fury")
            end, self = true, upkeep = 20 },
            { "Holy Light", emergency_heal, self = true, upkeep = 2 },
            -- Aggro recovery above threat generation. Hand of Reckoning is a
            -- Season of Discovery rune. (Righteous Defense, TBC's, is on
            -- neither client and is gone, 1.77.4.)
            { "Hand of Reckoning", loose_mob, retarget = "reclaim", upkeep = 1 },
            -- Forever: under Seal of Fury, Judgement is the tank's taunt; Swift
            -- Judgement (no global cooldown) finishes its cooldown when a mob
            -- is loose and it is not ready (1.77.4).
            { "Judgement", function(s)
                return H.buff_up(s.player, "Seal of Fury") and loose_mob(s)
            end, retarget = "reclaim", upkeep = 1 },
            { "Swift Judgement", function(s)
                return s.in_combat and H.buff_up(s.player, "Seal of Fury")
                    and book.cooldown("Judgement") > 1.5
                    and targeting.reclaim_target(P.tune_secs("rot_target_range", 30)) ~= nil
            end, self = true, fast = true, upkeep = 2 },
            ATTACK,
            -- Forever's tanking seal (level 10) first; Righteousness where it
            -- is not trained.
            { "Seal of Fury", seal_wanted, self = true, upkeep = 2 },
            { "Seal of Righteousness", seal_wanted, self = true, upkeep = 2 },
            { "Holy Shield", function(s)
                return s.in_combat and not H.buff_up(s.player, "Holy Shield")
            end, self = true, upkeep = 3 },
            { "Avenger's Shield", function() return true end, upkeep = 2 },
            { "Judgement", judgement_ready, upkeep = 1 },
            { "Consecration", function() return true end, self = true, upkeep = 8 },
            { "Hammer of the Righteous", function(s) return H.spread(s, 2) end },
            HOLY_STRIKE,
            { "Crusader Strike", function() return true end },
            { "Exorcism", exorcism_target, upkeep = 2 },
        },
    }

    --- A seal for the healer's Judgement (1.77.4): the list had none, so
    --- Judgement waited for a seal that never came. Wisdom, else Light, else
    --- Righteousness, under the same switch as the Judgement.
    local function healer_seal(s)
        return P.opt("rot_heal_dps", true) and s.in_combat and seal_missing(s)
    end

    local heal_rules = {
        { "Blessing of Wisdom", blessing_missing, self = true, upkeep = 30 },
        -- Voice of Truth (Forever, Holy; no global cooldown, 3 min): no
        -- silence or interrupt for 6 s, when a heal is due and something is
        -- about to stop it (1.77.4).
        { "Voice of Truth", function(s)
            return s.in_combat and s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                and interrupt_threat(s)
        end, self = true, fast = true, upkeep = 5 },
        { "Lay on Hands", function(s)
            return s.ally ~= nil and s.ally_hp < 0.12
        end, heal = true, upkeep = 60 },
        -- Light's Vigil (Forever, Holy): the next Holy Shock on its target
        -- costs no cooldown and heals the whole party. Worth its cast with
        -- three of you hurt (1.77.4).
        { "Light's Vigil", function(s)
            return s.in_combat and s.ally ~= nil and book.known("Holy Shock")
                and party_hurt(0.8) >= 3 and not aura_named(s.ally, "Light's Vigil")
        end, heal = true, upkeep = 6 },
        -- Holy Light before Flash of Light (1.80.0): heals keep their list
        -- order, so with Flash of Light first the big heal fired only when
        -- Flash of Light could not. Below the big line and standing, Holy
        -- Light; otherwise Flash of Light.
        { "Holy Light", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                and not s.player:is_moving()
        end, heal = true },
        { "Flash of Light", function(s)
            return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_flash_hp", 50)
        end, heal = true },
        { "Holy Shock", function(s)
            if s.ally == nil then return false end
            if s.ally_hp < P.optpct("rot_heal_flash_hp", 50) then return true end
            -- On a Light's Vigil: the party heal, while two are hurt.
            return aura_named(s.ally, "Light's Vigil") and party_hurt(0.9) >= 2
        end, heal = true, upkeep = 2 },
        { "Seal of Wisdom", healer_seal, self = true, upkeep = 2 },
        { "Seal of Light", healer_seal, self = true, upkeep = 2 },
        { "Seal of Righteousness", healer_seal, self = true, upkeep = 2 },
        { "Judgement", function(s)
            return P.opt("rot_heal_dps", true) and s.in_combat and judgement_ready(s)
        end, upkeep = 2 },
        -- Under the same switch, and only where a healer already stands in
        -- melee: nothing here walks it there.
        { "Holy Strike", function(s)
            return P.opt("rot_heal_dps", true) and s.in_combat and in_melee(s)
        end, upkeep = 1 },
        { "Attack", function(s)
            return P.opt("rot_heal_dps", true) and H.melee_start_wanted(s)
        end, direct = true, fast = true, upkeep = 1 },
    }

    profiles.holy = { label = "Holy", power = "MANA", rules = heal_rules }

    return {
        key = "paladin",
        label = "Paladin",
        trees = { "Holy", "Protection", "Retribution" },
        dispels = {
            { spell = "Cleanse", types = { "POISON", "DISEASE", "MAGIC" } },
            { spell = "Purify",  types = { "POISON", "DISEASE" } },
        },
        -- A paladin's blessing on a target replaces the paladin's last one
        -- there, so any of them counts as having one (1.62.0): with Kings and
        -- Might both trained the list put one up, then the other over it,
        -- every two seconds out of combat. Since 1.77.1 every blessing counts.
        buffs = {
            { spell = "Greater Blessing of Kings", replaces = BLESSINGS },
            { spell = "Blessing of Kings", replaces = BLESSINGS },
            { spell = "Blessing of Might", replaces = BLESSINGS },
        },
        -- Your own blessing is the profile's (Might, Sanctuary, Wisdom); the
        -- list above is for your party (1.77.1).
        buff_others_only = true,
        -- Spells that cannot go while an aura is on you (spellbook.lua).
        locked_by = {
            ["Divine Shield"] = FORBEARANCE, ["Divine Protection"] = FORBEARANCE,
            ["Blessing of Protection"] = FORBEARANCE, ["Templar's Bulwark"] = FORBEARANCE,
        },
        icon = "shield",
        tank_capable = true,
        heal_capable = true,
        -- This class has something that hits more than one target, so the
        -- field module may plan an AoE. Declared rather than inferred: a rule
        -- predicate is a closure and cannot be asked what it would do.
        aoe_capable = true,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        burst = {
            { spell = "Avenging Wrath", duration = 20 },
        },

        class_name = "PALADIN",
        power = "MANA",
        -- Repentance (Retribution) when Hammer of Justice is not ready; a
        -- humanoid only, which `creature_types` says.
        interrupts = { "Avenger's Shield", "Hammer of Justice", "Repentance" },
        creature_types = CREATURE_TYPES,
        -- Templar's Bulwark (Forever, Protection): an absorb as large as your
        -- health, and you go on fighting. First where it is trained.
        defensives = { "Templar's Bulwark", "Divine Shield", "Divine Protection", "Lay on Hands" },
        escapes = { "Divine Shield", "Hammer of Justice", "Divine Protection" },
        profiles = profiles,
        profile_order = { "leveling", "retribution", "protection", "holy" },
        suggest = function(t, prefer_tank)
            local holy, prot, ret = tree_points(t)
            local total = holy + prot + ret
            -- The group's tank under 20 points (1.77.1): Righteous Fury and
            -- Forever's Seal of Fury, which the levelling list has neither of.
            if total < 20 then return prefer_tank and "protection" or "leveling" end
            if prot >= holy and prot >= ret then return "protection" end
            if holy >= ret then return "holy" end
            return prefer_tank and "protection" or "retribution"
        end,
    }
end

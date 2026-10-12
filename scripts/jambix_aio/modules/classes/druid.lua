-- Jambix AIO / classes / druid
--
-- The only class whose RESOURCE changes with its form: mana in caster, rage in
-- bear, energy in cat. Each profile therefore declares its own `power`, which
-- is why the engine reads the resource off the profile rather than the class.

return function(P, H, CS)
    local book, targeting = H.book, H.targeting

    local BEAR, CAT, MOONKIN, TRAVEL, AQUATIC =
        "Dire Bear Form", "Cat Form", "Moonkin Form", "Travel Form", "Aquatic Form"

    local function cp(s) return s.combo or 0 end

    -- THE FIGHT DECIDES WHEN TO SPEND (1.35.x): five points, or fewer when the
    -- target will not live long enough for the rest -- points left on a corpse
    -- are damage never dealt.
    local function finisher_ready(s)
        local points = cp(s)
        if points >= 5 then return true end
        local ttd = s.ttd or 0
        if s.target and ((s.thp or 1) < 0.15 or (ttd > 0 and ttd < 4)) then return points >= 2 end
        if s.target and ttd > 0 and ttd < 7 then return points >= 3 end
        return false
    end

    --- Mark of the Wild is cast out of combat only; mid-fight it is a wasted
    --- global cooldown on a buff that was almost certainly already up.
    local function motw_wanted(s)
        return not s.in_combat
            and not H.buff_up(s.player, "Mark of the Wild")
            and not H.buff_up(s.player, "Gift of the Wild")
    end

    --- FAERIE FIRE IN FORM (1.77.3). Faerie Fire (Feral) puts up its OWN
    --- debuff, and the rule asked after the caster's "Faerie Fire" -- never
    --- up, so it went out on every 6 s cooldown, a global cooldown each.
    --- Either one on the target will do. Forever has no form version: its
    --- rule never resolves there.
    local function feral_ff_wanted(s)
        return H.dot_worth_it(s, "Faerie Fire (Feral)", 15)
            and H.debuff_remaining(s.target, "Faerie Fire") <= 2
    end

    --- TIGER'S FURY, TWO SPELLS (1.77.3). On Era it costs 30 energy for a
    --- 6 s damage buff (5217 to 9846). Season of Discovery's rune (417045)
    --- and Forever make it free on a 30 s cooldown, and it GIVES 60 energy:
    --- pressed whenever no buff was up, it went out at full energy and the
    --- gift was lost. That one waits for room.
    local TF_REFILL = 417045
    local function tigers_fury_wanted(s)
        if not s.in_combat then return false end
        if P.forever or book.id("Tiger's Fury") == TF_REFILL then return (s.power or 0) <= 40 end
        return not H.buff_up(s.player, "Tiger's Fury")
    end

    --- SHIFTING POWER (Forever, Feral, 1.80.0): mana into 40 energy, on a
    --- 16 s cooldown. Icy Veins and wowtbc.gg press it below 60 energy so
    --- none of the 40 is lost to the cap.
    local function shifting_power_wanted(s)
        return s.in_combat and (s.power or 0) < 60
    end

    --- A heal on yourself mid-fight: the fight's defensive line, or sooner
    --- while health is draining fast -- the paladin's and shaman's line.
    local function self_heal_wanted(s)
        local line = P.derived and P.derived("rot_defensive_hp", 40) or 0.40
        return s.in_combat and (s.hp < line + 0.05 or (H.bleeding() and s.hp < 0.6))
    end

    --- Party members under `line` within 40 yards, you included.
    local function party_hurt(line)
        local group = P.ctx and P.ctx.group
        if not (group and group.count_below) then return 0 end
        local ok, n = pcall(group.count_below, line, 40)
        return ok and tonumber(n) or 0
    end

    local profiles = {}

    -- Feral cat. Mangle (or Claw) builds, Rip is the finisher on anything with
    -- a health bar worth bleeding, Ferocious Bite on things that will die first.
    local feral_rules = {
        { "Mark of the Wild", motw_wanted, self = true, upkeep = 30 },
        { "Cat Form", function(s)
            return not H.buff_up(s.player, "Cat Form")
        end, self = true, upkeep = 5 },
        { "Tiger's Fury", tigers_fury_wanted, self = true, upkeep = 6 },
        { "Shifting Power", shifting_power_wanted, self = true, upkeep = 2 },
        { "Faerie Fire (Feral)", feral_ff_wanted, upkeep = 5 },
        { "Rip", function(s)
            return finisher_ready(s) and H.dot_worth_it(s, "Rip", 12)
        end, upkeep = 2, dot = true },
        { "Ferocious Bite", finisher_ready },
        { "Rake", function(s) return H.dot_worth_it(s, "Rake", 8) end, upkeep = 2, dot = true },
        -- The cat's Swipe (411128: Season of Discovery's rune, and on
        -- Forever's spell list): every enemy close by, a combo point.
        { "Swipe (Cat)", function(s) return H.spread(s, 3) end, self = true },
        -- Mangle (Cat) is Season of Discovery's rune, filed under its form
        -- by the spellbook (1.77.3); "Mangle" alone was the bear's.
        { "Mangle (Cat)", function() return true end },
        { "Claw", function() return true end },
        { "Shred", function() return true end },
    }

    profiles.leveling = {
        label = "Levelling (Feral)", power = "ENERGY",
        form = CAT, acceptable = { [CAT] = true }, rules = feral_rules,
    }

    profiles.feral_cat = {
        label = "Feral (Cat)", power = "ENERGY",
        form = CAT, acceptable = { [CAT] = true }, rules = feral_rules,
    }

    -- BEFORE THE FORMS (1.8.1). Every levelling rule was a cat's, and Cat
    -- Form is trained at 20 (Bear Form at 10), so a druid of 1 to 19 had
    -- nothing to press. The live log (Forever, a level 1) has it standing
    -- still in every fight, "no rotation rule passed", with Wrath and Healing
    -- Touch in the book. Until Bear Form, a caster; then the bear's rules
    -- until Cat Form (`suggest`, below).
    profiles.leveling_caster = {
        label = "Levelling (Caster)",
        power = "MANA",
        rules = {
            { "Mark of the Wild", motw_wanted, self = true, upkeep = 30 },
            -- Waits for the last one to run out, as the priest's Renew does.
            { "Rejuvenation", function(s)
                return s.in_combat and (s.hp < 0.65 or (H.bleeding() and s.hp < 0.85))
                    and not H.buff_up(s.player, "Rejuvenation")
            end, self = true, upkeep = 3 },
            { "Healing Touch", function(s)
                return self_heal_wanted(s) and not s.player:is_moving()
            end, self = true, upkeep = 2 },
            { "Moonfire", function(s) return H.dot_worth_it(s, "Moonfire", 8) end, upkeep = 2, dot = true },
            { "Wrath", function(s) return not s.player:is_moving() end },
        },
    }

    local bear = {
        form = BEAR,
        acceptable = { [BEAR] = true, ["Bear Form"] = true },
        rules = {
            { "Mark of the Wild", motw_wanted, self = true, upkeep = 30 },
            { "Dire Bear Form", function(s)
                return not (H.buff_up(s.player, "Dire Bear Form")
                    or H.buff_up(s.player, "Bear Form"))
            end, self = true, upkeep = 5 },
            -- BEFORE DIRE BEAR FORM (1.80.0). It is trained at 40, and the
            -- form manager only ever shifted into it, so a bear tank from 29
            -- to 39 was never put into Bear Form at all.
            { "Bear Form", function(s)
                return not book.known("Dire Bear Form") and not H.buff_up(s.player, "Bear Form")
            end, self = true, upkeep = 5 },
            -- Aggro recovery outranks threat generation, for the same reason
            -- it does on a warrior: extra threat on the current target does
            -- nothing for a mob nobody is holding.
            { "Growl", function(s)
                local loose = targeting.reclaim_target(P.tune_secs("rot_target_range", 30))
                if not loose then return false end
                s.reclaim = loose
                return true
            end, retarget = "reclaim", upkeep = 1 },
            { "Challenging Roar", function(s)
                return #s.loose >= P.opt("rot_challenging_shout_count", 3)
                    and targeting.reclaim_target(P.tune_secs("rot_target_range", 30)) ~= nil
            end, self = true, upkeep = 20 },
            { "Demoralizing Roar", function(s)
                return H.spread(s, 1) and not H.debuff_up(s.target, "Demoralizing Roar")
            end, self = true, upkeep = 8 },
            { "Faerie Fire (Feral)", feral_ff_wanted, upkeep = 5 },
            { "Mangle (Bear)", function() return true end },
            -- Primal Bite (Forever, Feral, 25): what Season of Discovery calls
            -- Mangle (Bear), 407995 -- weapon damage and high threat, 6 s.
            { "Primal Bite", function() return true end },
            { "Lacerate", function(s)
                return H.debuff_stacks(s.target, "Lacerate") < 5
                    or H.debuff_remaining(s.target, "Lacerate") < 4
            end, upkeep = 1 },
            -- The bear's ranks only: the cat's is "Swipe (Cat)" (1.77.3).
            { "Swipe", function(s) return H.spread(s, 2) end, self = true },
            -- Rage over what Swipe and the bear's other presses need: the
            -- rest is a Maul (it was a fixed 45-rage slider until 1.35.x).
            { "Maul", function(s)
                return s.power >= (H.spread(s, 2) and 35 or 30)
            end, fast = true },
        },
    }

    profiles.feral_bear = {
        label = "Feral (Bear tank)", power = "RAGE",
        form = bear.form, acceptable = bear.acceptable, rules = bear.rules,
    }

    -- From Bear Form at 10 to Cat Form at 20 (1.8.1).
    profiles.leveling_bear = {
        label = "Levelling (Bear)", power = "RAGE",
        form = bear.form, acceptable = bear.acceptable, rules = bear.rules,
    }

    profiles.balance = {
        label = "Balance",
        power = "MANA",
        form = MOONKIN,
        acceptable = { [MOONKIN] = true, ["None"] = true },
        rules = {
            { "Mark of the Wild", motw_wanted, self = true, upkeep = 30 },
            { "Moonkin Form", function(s)
                return book.known("Moonkin Form") and not H.buff_up(s.player, "Moonkin Form")
            end, self = true, upkeep = 10 },
            { "Faerie Fire", function(s) return H.dot_worth_it(s, "Faerie Fire", 15) end,
              upkeep = 5 },
            { "Moonfire", function(s) return H.dot_worth_it(s, "Moonfire", 8) end, upkeep = 2, dot = true },
            { "Insect Swarm", function(s) return H.dot_worth_it(s, "Insect Swarm", 10) end,
              upkeep = 2, dot = true },
            { "Starfire", function(s) return not s.player:is_moving() end },
            { "Wrath", function(s) return not s.player:is_moving() end },
        },
    }

    profiles.restoration = {
        label = "Restoration",
        power = "MANA",
        -- No form: shifting out to heal is the point, and Tree of Life is a
        -- separate decision the player owns.
        rules = {
            { "Mark of the Wild", motw_wanted, self = true, upkeep = 30 },
            -- Wild Growth (Forever, Restoration, 40): the party heal every
            -- level-60 guide leads with. Three of you hurt (1.80.0).
            { "Wild Growth", function(s)
                return s.in_combat and s.ally ~= nil and party_hurt(0.85) >= 3
            end, heal = true, upkeep = 6 },
            { "Rejuvenation", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_renew_hp", 85)
                    and not H.buff_up(s.ally, "Rejuvenation")
            end, heal = true, upkeep = 2 },
            -- The big heals before Regrowth (1.80.0): heals keep their list
            -- order, so Regrowth (below 50%) went out ahead of Swiftmend and
            -- Healing Touch (below 40%) whenever its HoT was missing.
            { "Swiftmend", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                    and (H.buff_up(s.ally, "Rejuvenation") or H.buff_up(s.ally, "Regrowth"))
            end, heal = true, upkeep = 2 },
            { "Healing Touch", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_big_hp", 40)
                    and not s.player:is_moving()
            end, heal = true },
            { "Regrowth", function(s)
                return s.ally ~= nil and s.ally_hp < P.optpct("rot_heal_flash_hp", 50)
                    and not H.buff_up(s.ally, "Regrowth")
            end, heal = true, upkeep = 2 },
            { "Moonfire", function(s)
                return P.opt("rot_heal_dps", true) and s.in_combat
                    and H.dot_worth_it(s, "Moonfire", 8)
            end, upkeep = 2, dot = true },
            { "Wrath", function(s)
                return P.opt("rot_heal_dps", true) and s.in_combat and not s.player:is_moving()
            end },
        },
    }

    return {
        key = "druid",
        label = "Druid",
        trees = { "Balance", "Feral Combat", "Restoration" },
        dispels = {
            { spell = "Abolish Poison", types = { "POISON" } },
            { spell = "Cure Poison",   types = { "POISON" } },
            { spell = "Remove Curse",  types = { "CURSE" } },
        },
        buffs = {
            { spell = "Gift of the Wild", replaces = { "Mark of the Wild" } },
            { spell = "Mark of the Wild", replaces = { "Gift of the Wild" } },
            { spell = "Thorns" },
        },
        icon = "leaf",
        tank_capable = true,
        heal_capable = true,
        uses_forms = true,
        -- THE BURST SEQUENCE (modules/burst.lua). Berserk: Forever's Feral
        -- talent and Season of Discovery's rune, 15 s, in Cat or Bear Form.
        burst = {
            { spell = "Berserk", duration = 15 },
        },
        -- This class has something that hits more than one target, so the
        -- field module may plan an AoE. Declared rather than inferred: a rule
        -- predicate is a closure and cannot be asked what it would do.
        aoe_capable = true,
        class_name = "DRUID",
        power = "MANA",
        -- Shapeshift bar order. Only the ORDER is assumed; which entries exist
        -- is read from what is actually trained.
        forms = { "Bear Form", BEAR, AQUATIC, CAT, TRAVEL, MOONKIN, "Tree of Life" },
        -- Forms for getting about: the rotation leaves them be out of combat,
        -- and in one while you move (rotation.lua, 1.7.5).
        travel_forms = { TRAVEL, AQUATIC },
        interrupts = { "Feral Charge", "Bash" },
        defensives = { "Survival Instincts", "Barkskin", "Frenzied Regeneration" },
        escapes = { "Travel Form", "Dash", "Entangling Roots", "Hibernate" },
        profiles = profiles,
        profile_order = { "leveling", "leveling_caster", "leveling_bear", "feral_cat", "feral_bear",
            "balance", "restoration" },
        suggest = function(t, prefer_tank)
            local balance, feral, resto = t.points()
            local total = balance + feral + resto
            if total < 20 then
                -- The cat's rules need Cat Form, the bear's Bear Form (1.8.1).
                if book.known(CAT) then return "leveling" end
                if book.known("Bear Form") or book.known(BEAR) then return "leveling_bear" end
                return "leveling_caster"
            end
            if feral >= balance and feral >= resto then
                return prefer_tank and "feral_bear" or "feral_cat"
            end
            if balance >= resto then return "balance" end
            return "restoration"
        end,
    }
end

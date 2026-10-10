-- Jambix AIO / classes / mage
--
-- Levelling is Frost: Frostbolt does the damage, the slow does the surviving.
-- Endgame splits by tree.

return function(P, H, CS)
    local book = H.book

    local function low_mana(s) return H.power_fraction(s) < 0.2 end

    -- AURAS THAT ARE NO SPELL IN YOUR BOOK (1.77.3). By name they read your
    -- spellbook and never matched; by id, from the client's tables (the same
    -- on Era and Forever):
    --   Fire Vulnerability  what Improved Scorch puts on the target, 5 stacks.
    --                       "Improved Scorch" is the talent: its stacks read
    --                       0 for ever, so Fire cast Scorch and nothing else
    --   Frostbite           the freeze (12494), not the talent (11071...)
    --   Fingers of Frost    your next spells treat the target as frozen
    --                       (Forever's talent, Season of Discovery's rune)
    --   Arcane Blast        the stack on you is 400573; the cast is 400574
    local FIRE_VULNERABILITY = { 22959 }
    local FROSTBITE = { 12494 }
    local FINGERS_OF_FROST = { 400669 }
    local ARCANE_BLAST_STACK = { 400573 }
    -- PROCS THE GUIDES BUILD ON (1.80.0; Forever's talents, Season of
    -- Discovery's runes, the same ids on both):
    --   Missile Barrage  the next Arcane Missiles is free and twice as fast
    --                    (400589; the talent is 400588). Every Arcane guide's
    --                    rotation is "Blast until it procs, then Missiles"
    --   Heating Up       Fire crits shorten the next Pyroblast, 3 stacks
    --                    (400625; the talent is 400624)
    local MISSILE_BARRAGE = { 400589 }
    local HEATING_UP = { 400625 }

    --- Arcane Missiles on a Missile Barrage proc: free, half the channel.
    local barrage_rule = { "Arcane Missiles", function(s)
        return not s.player:is_moving() and H.buff_up(s.player, MISSILE_BARRAGE)
    end, channel = true }

    --- Ice Lance only on a frozen target, or with Fingers of Frost.
    local function frozen(s)
        return H.debuff_up(s.target, "Frost Nova")
            or H.debuff_up(s.target, FROSTBITE)
            or H.buff_up(s.player, FINGERS_OF_FROST)
    end

    --- Armour and Intellect are cast out of combat only. Re-buffing mid-fight
    --- costs a global cooldown and the buff was almost certainly already up --
    --- the aura check just could not see it.
    local function buff_missing(name)
        return function(s)
            return not s.in_combat and not H.buff_up(s.player, name)
        end
    end

    --- One armour rule covering all three ranks of the idea. The highest one
    --- trained is the one that resolves; the others simply do not.
    local function armour_up(s)
        if s.in_combat then return false end
        return not (H.buff_up(s.player, "Ice Armor")
            or H.buff_up(s.player, "Frost Armor")
            or H.buff_up(s.player, "Mage Armor")
            or H.buff_up(s.player, "Molten Armor"))
    end

    local function nova_wanted(s)
        -- Only worth it when something is actually on top of us, and only if
        -- we are not about to root a mob we still need to melee.
        return s.in_combat and H.spread(s, 1)
    end

    local profiles = {}

    profiles.leveling = {
        label = "Levelling (Frost)",
        power = "MANA",
        rules = {
            { "Ice Armor", armour_up, self = true, upkeep = 30 },
            { "Frost Armor", armour_up, self = true, upkeep = 30 },
            { "Arcane Intellect", buff_missing("Arcane Intellect"), self = true, upkeep = 30 },
            { "Evocation", function(s) return not s.in_combat and low_mana(s) end,
              self = true, upkeep = 10 , channel = true },
            { "Ice Barrier", function(s)
                return s.in_combat and not H.buff_up(s.player, "Ice Barrier")
            end, self = true, upkeep = 10 },
            { "Frost Nova", nova_wanted, self = true, upkeep = 8 },
            { "Arcane Explosion", function(s) return H.spread(s, 3) end, self = true },
            { "Cone of Cold", function(s) return H.spread(s, 2) end, self = true, upkeep = 6 },
            { "Ice Lance", frozen },
            barrage_rule,
            -- Fire Blast is the instant: worth it while moving, and as the
            -- finisher on something that will die before a Frostbolt lands.
            { "Fire Blast", function(s)
                return s.player:is_moving() or H.execute_phase(s, 0.15)
            end },
            { "Shoot", H.wand_wanted, upkeep = 3 },
            { "Frostbolt", function(s)
                return not s.player:is_moving() and H.filler_ok(s)
            end },
        },
    }

    profiles.frost = {
        label = "Frost",
        power = "MANA",
        rules = {
            { "Ice Armor", armour_up, self = true, upkeep = 30 },
            { "Arcane Intellect", buff_missing("Arcane Intellect"), self = true, upkeep = 30 },
            { "Ice Barrier", function(s)
                return not H.buff_up(s.player, "Ice Barrier")
            end, self = true, upkeep = 10 },
            { "Frost Nova", nova_wanted, self = true, upkeep = 8 },
            -- Only worth pressing on a frozen target; otherwise it is the
            -- weakest button in the book.
            { "Ice Lance", frozen },
            { "Arcane Explosion", function(s) return H.spread(s, 3) end, self = true },
            barrage_rule,
            { "Fire Blast", function(s) return s.player:is_moving() end },
            { "Frostbolt", function(s) return not s.player:is_moving() end },
        },
    }

    profiles.fire = {
        label = "Fire",
        power = "MANA",
        rules = {
            { "Molten Armor", armour_up, self = true, upkeep = 30 },
            { "Mage Armor", armour_up, self = true, upkeep = 30 },
            { "Arcane Intellect", buff_missing("Arcane Intellect"), self = true, upkeep = 30 },
            -- Scorch exists to build and hold the fire vulnerability debuff.
            -- Once it is at five stacks it is a damage loss, so it stops; and
            -- without Improved Scorch there is no debuff to build.
            { "Scorch", function(s)
                if not H.has_talent("Improved Scorch") then return false end
                return H.debuff_stacks(s.target, FIRE_VULNERABILITY) < 5
                    or H.debuff_remaining(s.target, FIRE_VULNERABILITY) < 6
            end, upkeep = 1 },
            { "Fire Blast", function(s) return s.player:is_moving() end },
            { "Flamestrike", function(s) return H.spread(s, 4) end, self = true, upkeep = 8 },
            { "Arcane Explosion", function(s) return H.spread(s, 3) end, self = true },
            -- Three Heating Up stacks: Pyroblast at a quarter of its cast
            -- (wowtbc.gg, Mobalytics). Forever trains it at 20.
            { "Pyroblast", function(s)
                return not s.player:is_moving() and H.debuff_stacks(s.player, HEATING_UP) >= 3
            end },
            barrage_rule,
            -- Frostfire Bolt replaces Fireball once trained (40 on Forever):
            -- Icy Veins and wowtbc.gg. The engine still weighs the two.
            { "Frostfire Bolt", function(s) return not s.player:is_moving() end },
            { "Fireball", function(s) return not s.player:is_moving() end },
        },
    }

    profiles.arcane = {
        label = "Arcane",
        power = "MANA",
        rules = {
            { "Mage Armor", armour_up, self = true, upkeep = 30 },
            { "Arcane Intellect", buff_missing("Arcane Intellect"), self = true, upkeep = 30 },
            { "Evocation", function(s) return low_mana(s) end, self = true, upkeep = 10 , channel = true },
            { "Arcane Explosion", function(s) return H.spread(s, 3) end, self = true },
            { "Fire Blast", function(s) return s.player:is_moving() end },
            barrage_rule,
            -- Arcane Blast stacks a cost increase on itself; drop back to
            -- Missiles rather than ride the stack into an empty mana bar.
            { "Arcane Missiles", function(s)
                return H.buff_up(s.player, ARCANE_BLAST_STACK) and H.power_fraction(s) < 0.4
            end, channel = true },
            { "Arcane Blast", function(s) return not s.player:is_moving() end },
            { "Arcane Missiles", function(s) return not s.player:is_moving() end, channel = true },
            { "Frostbolt", function(s) return not s.player:is_moving() end },
        },
    }

    return {
        key = "mage",
        label = "Mage",
        wand_capable = true,
        trees = { "Arcane", "Fire", "Frost" },
        -- Remove Lesser Curse is the mage's, on Era and Forever alike; "Remove
        -- Curse" is a druid's spell on both (1.77.3).
        dispels = {
            { spell = "Remove Lesser Curse", types = { "CURSE" } },
        },
        buffs = {
            { spell = "Arcane Brilliance", replaces = { "Arcane Intellect" } },
            { spell = "Arcane Intellect",  replaces = { "Arcane Brilliance" } },
        },
        icon = "sparkles",
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
            { spell = "Arcane Power", duration = 15 },
            { spell = "Icy Veins", duration = 20 },
            { spell = "Combustion", duration = 15 },
            { spell = "Presence of Mind", duration = 6 },
        },

        class_name = "MAGE",
        power = "MANA",
        interrupts = { "Counterspell" },
        defensives = { "Ice Block", "Ice Barrier", "Mana Shield" },
        escapes = { "Frost Nova", "Blink" },
        profiles = profiles,
        profile_order = { "leveling", "frost", "fire", "arcane" },
        suggest = function(t)
            local arcane, fire, frost = t.points()
            if frost >= fire and frost >= arcane then
                return (frost > 20) and "frost" or "leveling"
            end
            if fire >= arcane then return "fire" end
            return "arcane"
        end,
    }
end

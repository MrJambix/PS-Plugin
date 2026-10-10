-- Jambix AIO / catalog / hunter -- what every hunter ability actually does.
--
-- This is DATA, read by modules/catalog/init.lua. Nothing here decides
-- anything; it describes. The class rule lists still say what to press and
-- when, but they can now ask the catalogue what a thing IS instead of
-- restating it, and the coverage check on the Debug page names every trained
-- ability this file does not describe.
--
-- NUMBERS. Every figure is Classic Era at max rank (level 60) unless the row
-- says otherwise, written from the game's own tooltips and the levelling
-- guides. Mana costs are deliberately absent: they differ per rank and the
-- client answers the real one at runtime through get_spell_costs. A row
-- marked `approx = true` is one whose figure was recalled rather than read
-- and should be checked against the tooltip in game before being relied on
-- for arithmetic.
--
-- FOREVER. The same file describes the Forever client (1.60.1.70291), whose
-- hunter has its own talent tree, retuned spells and a few spells of its
-- own. A row only one client has says so with `client`; a row both have
-- keeps Era's figures and says what Forever changes in `forever`. Forever's
-- figures are read from that client's own tables -- the tooltip (Spell.db2)
-- with its numbers from SpellEffect, SpellCooldowns, SpellCastTimes and
-- SpellDuration, and for a talent its rank curve
-- (TraitDefinitionEffectPoints) -- at the highest rank unless the row says
-- per rank.
--
-- SCHEMA (one row per ability, keyed by the English name the spellbook uses)
--
--   roles     what it is for: damage, dot, heal, slow, root, stun, fear,
--             disorient, sleep, silence, interrupt, dispel, cooldown, toggle,
--             aspect, buff, debuff, threat, threat_drop, trap, pet, utility,
--             opener, execute, aoe, mana_drain, tracking, cc, defensive,
--             escape (the last three are what the rotation's capability
--             list and the kite read; keep the spelling)
--   kind      instant | cast | channel | toggle | trap | aura | pet_command
--   school    physical | nature | arcane | fire | frost | none
--   cost      mana | none
--   range     "ranged" (8-35 base) | "melee" | "self" | "pet" | "party" | number | { min, max }
--   needs     what has to be true: ranged_weapon, ammo, melee_weapon,
--             standing (cast or aim), facing, pet, pet_alive, out_of_combat,
--             behind? (none for hunters), target_beast, after_dodge,
--             after_parry, no_other_sting
--   cast      seconds (0 = instant); channel = seconds for channels
--   cooldown  seconds, 0 = none; "traps" = the shared trap cooldown
--   duration  seconds the effect lasts on its target, where it has one
--   applies   { aura = "name shown on the target or on you", on = "target"|"self"|"pet"|"ground", ... }
--   damage    { delivery = weapon | flat | dot | per_tick, school, amount, ticks, scaling = "rap"|"weapon"|"none", coefficient }
--   heal      same shape, for Mend Pet
--   learned   level it is trained
--   expansion "classic" (default) | "tbc"
--   client    "forever" -- only the Forever client has it | "era" -- every
--             client but Forever. Absent: every client.
--   forever   { field = value, ... } -- what Forever changes, laid over the
--             row there and ignored elsewhere. A field named here replaces
--             the row's whole field, a table included; `talent = false`
--             says no talent grants it on Forever.
--   stacks    "sting" -- one sting per target; a new one replaces the old
--   synergy   { "plain sentences about how it works with other things" }
--   talents   { ["Talent Name"] = "what that talent changes about this ability" }
--   talent    the talent that grants the ability, where one does
--   source    where it is learned when not from a trainer
--   exclusive "aspect" | "tracking" -- one of the group at a time
--   arm, lasts  traps: seconds before it is live, seconds it stays down
--   ground_targeted, on_next_swing   booleans, as they sound
--
-- TALENTS are listed by tree with tier, max rank and effect, keyed by the
-- English name the talent scan uses. `affects` names the abilities each one
-- changes, which is how the catalogue answers "what does this talent do to
-- my rotation" without a second table.
--
-- Forever's talents are one trait tree (modules/talent_trees.lua). A tier
-- there is the client's own gate, five points spent in the tree per tier
-- (TraitCond.SpentAmountRequired); max and effect are the node's rank
-- curve, and a Forever `affects` names what the tooltip names, checked
-- against the talent's spell class mask.
--
-- COMBOS are the interactions that only exist BETWEEN abilities -- the things
-- a single row cannot say.

return {
    class = "hunter",
    label = "Hunter",
    resource = "MANA",

    -- Ordered lists the class module used to carry itself. Order is
    -- priority: the first that is ready is the one used.
    lists = {
        interrupts = { "Silencing Shot" },
        pet_interrupts = { "Pummel", "Nether Shock" },
        defensives = { "Feign Death", "Deterrence" },
        -- No trap here: Classic traps cannot be laid in combat, which is the
        -- only time an escape is asked for.
        escapes = { "Feign Death", "Wing Clip", "Disengage" },
        slows = { "Concussive Shot", "Wing Clip", "Frost Trap" },
        controls = { "Freezing Trap", "Scatter Shot", "Wyvern Sting", "Scare Beast", "Intimidation" },
    },

    ranges = {
        -- Base ranged band. Hawk Eye adds 2 yards per rank to the maximum.
        ranged = { min = 8, max = 35 },
        melee = 5,
        -- Inside minimum range and outside melee: nothing works. Kiting
        -- exists to stay out of this band.
        dead_zone = { min = 5, max = 8 },
    },

    abilities = {

        -- --- the shots -------------------------------------------------

        ["Auto Shot"] = {
            roles = { "damage", "toggle" },
            kind = "toggle", school = "physical", cost = "none", range = "ranged",
            needs = { "ranged_weapon", "ammo", "standing", "facing" },
            cast = 0, cooldown = 0, learned = 1,
            damage = { delivery = "weapon", school = "physical", scaling = "weapon",
                note = "full ranged weapon damage plus ammo, once per weapon speed; the "
                    .. "half-second aim before each shot needs you standing, the rest of the swing does not" },
            synergy = {
                "Most of a hunter's damage. Every special that is not worth its mana is a shot not taken.",
                "The swing timer keeps running while you move; only the aim needs you still. That is what weaving is.",
                "A press is a toggle: pressing while it runs STOPS it. It reports no cast, so nothing confirms it.",
                "Aimed Shot resets the swing timer, so it is fired right after an Auto Shot, never right before one.",
                "Multi-Shot's half-second cast fired during the aim clips the Auto Shot; fire it just after one lands.",
            },
            talents = {
                ["Improved Aspect of the Hawk"] = "each Auto Shot has a chance to grant 30% ranged haste for 12s (the 'quick shots' proc)",
                ["Ranged Weapon Specialization"] = "up to +5% ranged weapon damage",
                ["Lethal Shots"] = "up to +5% ranged crit",
                ["Mortal Shots"] = "ranged crits deal up to +30% more damage",
            },
            forever = {
                talents = {
                    ["Deadly Aspects"] = "in Hawk, each Auto Shot has a 2% chance per rank (10% at 5) to grant +30% ranged attack speed for 12s",
                    ["Ranged Weapon Specialization"] = "up to +5% ranged weapon damage",
                    ["Lethal Attacks"] = "up to +5% crit with every attack",
                    ["Mortal Shots"] = "ranged crits deal up to +30% more damage",
                },
            },
        },

        ["Aimed Shot"] = {
            roles = { "damage", "opener" },
            kind = "cast", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "ammo", "standing", "facing" },
            cast = 3.0, cooldown = 6, learned = 20, talent = "Aimed Shot",
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 600,
                note = "ranged weapon damage + 600 at rank 6; scales with RAP through the weapon" },
            synergy = {
                "The opener: three seconds of cast that land while the mob is still walking over.",
                "Resets the Auto Shot swing timer when it fires. After an Auto Shot, never before one.",
                "Cannot be cast while moving. Arcane Shot is the moving substitute.",
                "Pushed back by damage taken like any cast: it is a ranged-only ability in practice.",
            },
            talents = {
                ["Aimed Shot"] = "the ability itself (Marksmanship, tier 3, 1 point)",
                ["Mortal Shots"] = "its crits deal up to +30% more",
                ["Efficiency"] = "up to -10% mana cost",
            },
            -- Forever: trained, not a talent, and quicker.
            forever = {
                cast = 2.0, talent = false,
                damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 166,
                    note = "ranged weapon damage + 166 at rank 6" },
                synergy = {
                    "Trained at level 20 on Forever, not a talent, and a two-second cast.",
                    "Shares its six-second cooldown with Multi-Shot: one or the other, not both.",
                    "Cannot be cast while moving. Arcane Shot is the moving substitute.",
                },
                talents = {
                    ["Mortal Shots"] = "its crits deal up to +30% more",
                    ["Barrage"] = "up to +10% damage",
                    ["Efficiency"] = "up to -15% mana cost",
                },
            },
        },

        ["Multi-Shot"] = {
            roles = { "damage", "aoe" },
            kind = "cast", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "ammo", "standing", "facing" },
            cast = 0.5, cooldown = 10, learned = 18,
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 150, targets = 3,
                note = "ranged weapon damage + 150 at rank 5, to the target and up to two more near it" },
            synergy = {
                "Three targets, but worth pressing on one: weapon damage plus a bonus for one global.",
                "Its half-second cast clips an Auto Shot that is aiming. Fire it just after a shot lands.",
                "Breaks crowd control on the extra targets: a sheeped or trapped mob next to the target wakes up.",
            },
            talents = {
                ["Barrage"] = "up to +15% Multi-Shot and Volley damage",
                ["Efficiency"] = "up to -10% mana cost",
            },
            -- Forever: one rank, no bonus damage, and Aimed Shot's cooldown.
            forever = {
                cooldown = 6,
                damage = { delivery = "weapon", school = "physical", scaling = "weapon", targets = 3,
                    note = "ranged weapon damage to the target and up to two more near it; one rank, no flat bonus" },
                synergy = {
                    "Three targets, weapon damage each. It shares Aimed Shot's six-second cooldown: one or the other.",
                    "Its half-second cast clips an Auto Shot that is aiming. Fire it just after a shot lands.",
                    "Breaks crowd control on the extra targets: a sheeped or trapped mob next to the target wakes up.",
                },
                talents = {
                    ["Barrage"] = "up to +10% Multi-Shot, Aimed Shot and Volley damage",
                    ["Efficiency"] = "up to -15% mana cost",
                },
            },
        },

        ["Arcane Shot"] = {
            roles = { "damage" },
            kind = "instant", school = "arcane", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "ammo", "facing" },
            cast = 0, cooldown = 6, learned = 6,
            damage = { delivery = "flat", school = "arcane", amount = 183, scaling = "none",
                note = "183 arcane at rank 8; no attack power scaling in Classic (that is TBC); ignores armour" },
            synergy = {
                "The instant: castable while moving, so it is the shot for kiting and for a mob in the dead zone's edge.",
                "Does not reset the swing timer. Safe to fire at any point in the swing.",
                "Poor mana for damage next to Auto Shot; a filler when mana is fine, not a rotation.",
            },
            talents = {
                ["Improved Arcane Shot"] = "up to -1s cooldown (5 seconds at max)",
                ["Efficiency"] = "up to -10% mana cost",
            },
            forever = {
                damage = { delivery = "flat", school = "arcane", amount = 217, scaling = "none",
                    note = "217 arcane at rank 8; ignores armour. Its cooldown is shared with Summon Hawk" },
                talents = {
                    ["Improved Arcane Shot"] = "-0.3s cooldown per rank (4.5 seconds at max); not the cooldown Summon Hawk shares",
                    ["Efficiency"] = "up to -15% mana cost",
                },
            },
        },

        ["Steady Shot"] = {
            roles = { "damage" }, expansion = "tbc", client = "era",
            kind = "cast", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "ammo", "standing", "facing" },
            cast = 1.5, cooldown = 0, learned = 62,
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 150, coefficient = 0.2,
                note = "base weapon damage plus 150 plus 20% of RAP, and 175 more against a dazed target; the TBC filler between Auto Shots" },
            synergy = {
                "TBC's rotation is Steady Shot between Auto Shots without clipping either: the 'one-one' rotation.",
                "Dazed targets take extra damage from it.",
            },
        },

        ["Concussive Shot"] = {
            roles = { "slow", "debuff" },
            kind = "instant", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing" },
            cast = 0, cooldown = 12, duration = 4, learned = 8,
            applies = { aura = "Concussive Shot", on = "target", effect = "dazed: -50% movement speed" },
            synergy = {
                "The levelling hunter's kiting tool: four seconds at half speed is the distance the next two shots need.",
                "Fire it as soon as the mob is inside about thirty yards; a daze on a mob still far away is wasted.",
                "Stacks with Wing Clip's slow in time, not in effect: the two cover each other's gaps.",
                "Steady Shot (TBC) hits dazed targets harder.",
            },
            talents = {
                ["Improved Concussive Shot"] = "up to a 20% chance to also stun for 3s",
            },
        },

        ["Scatter Shot"] = {
            roles = { "disorient", "damage" },
            kind = "instant", school = "physical", cost = "mana", range = { min = 0, max = 15 },
            needs = { "ranged_weapon", "facing" },
            cast = 0, cooldown = 30, duration = 4, learned = 30, talent = "Scatter Shot",
            applies = { aura = "Scatter Shot", on = "target", effect = "disoriented: wanders, breaks on damage" },
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", fraction = 0.5,
                note = "50% weapon damage" },
            synergy = {
                "Short range on purpose: it is for the mob that reached you. Scatter, step back out of the dead zone, shoot.",
                "Scatter into a Freezing Trap: disorient, drop the trap under it, walk away. The classic control chain.",
                "Any damage breaks it -- including your pet's. Call the pet off or use it on the mob the pet is not on.",
            },
            talents = {
                ["Scatter Shot"] = "the ability itself (Marksmanship, tier 5, 1 point)",
            },
        },

        ["Distracting Shot"] = {
            roles = { "threat" },
            kind = "instant", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing" },
            cast = 0, cooldown = 8, learned = 12,
            applies = { effect = "adds threat on the target", amount = 600 },
            synergy = {
                "Pulls a mob off the pet or a party member onto you. Only useful when you WANT it on you.",
            },
        },

        ["Tranquilizing Shot"] = {
            roles = { "dispel" },
            kind = "instant", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing" },
            cast = 0, cooldown = 20, learned = 60, source = "Tome of Tranquilizing Shot, dropped by Lucifron",
            applies = { effect = "removes one Frenzy (enrage) effect from the target" },
            synergy = {
                "Raid utility: Magmadar, Chromaggus. Nothing in the open world needs it.",
            },
        },

        ["Silencing Shot"] = {
            roles = { "silence", "interrupt", "damage" }, expansion = "tbc", client = "era",
            kind = "instant", school = "physical", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing" },
            cast = 0, cooldown = 20, duration = 3, learned = 60, talent = "Silencing Shot",
            applies = { aura = "Silencing Shot", on = "target", effect = "silenced 3s; interrupts the current cast" },
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", fraction = 0.5 },
            synergy = {
                "The hunter's only interrupt, and it is the 41-point Marksmanship talent. Classic hunters have none.",
            },
            talents = {
                ["Silencing Shot"] = "the ability itself (Marksmanship, tier 9, 1 point, TBC)",
            },
        },

        -- Forever's Beast Mastery talent (1.80.0). The hawk is sent at the
        -- target, not cast at it from the bow, so it has no minimum range.
        ["Summon Hawk"] = {
            roles = { "damage" }, client = "forever",
            kind = "instant", school = "physical", cost = "mana", range = 35,
            needs = {},
            cast = 0, cooldown = 6, duration = 18, learned = 25, talent = "Summon Hawk",
            damage = { delivery = "flat", school = "physical", scaling = "rap",
                note = "Forever: a hawk dive-bombs the target and keeps attacking it for 18s; two at once" },
            synergy = {
                "Shares its cooldown with Arcane Shot. Every guide keeps two hawks out.",
                "Mobalytics' levelling guide drops Arcane Shot once the hawks are trained; Icy Veins fires one only with both out and mana to spare.",
            },
        },

        -- Forever's Marksmanship talent (tier 7), the long shot. Ranks at
        -- 40, 48 and 58.
        ["Sniper Shot"] = {
            roles = { "damage" }, client = "forever",
            kind = "cast", school = "physical", cost = "mana", range = { min = 8, max = 45 },
            needs = { "ranged_weapon", "ammo", "standing", "facing" },
            cast = 4.0, cooldown = 15, duration = 10, learned = 40, talent = "Sniper Shot",
            applies = { aura = "Sniper Shot", on = "self", effect = "your next 3 shots reach 10 yards further, for 10s" },
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 295,
                note = "ranged weapon damage + 295 at rank 3" },
            synergy = {
                "Forty-five yards: a shot from outside the ranged band, and the three shots after it reach as far.",
                "A four-second cast, so it is for a mob that is still far away, not one that is closing.",
            },
            talents = {
                ["Sniper Shot"] = "the ability itself (Marksmanship, tier 7, 1 point)",
                ["Hawk Eye"] = "+2 yards per rank",
            },
        },

        -- --- the stings --------------------------------------------------
        -- One sting per target. A new sting replaces the one that is up.

        ["Serpent Sting"] = {
            roles = { "dot", "damage", "debuff" },
            kind = "instant", school = "nature", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing", "no_other_sting" },
            cast = 0, cooldown = 0, duration = 15, learned = 4, stacks = "sting",
            applies = { aura = "Serpent Sting", on = "target" },
            damage = { delivery = "dot", school = "nature", amount = 555, ticks = 5, scaling = "none",
                note = "555 nature over 15s at rank 9 (111 every 3s, 5 ticks); no attack power scaling in Classic (that is TBC); ignores armour" },
            synergy = {
                "The best mana-to-damage the class has outside Auto Shot. Up on anything that lives ten seconds.",
                "Does not reset the swing timer and casts while moving: the kiting hunter's other button.",
                "Refreshing it early wastes the remaining ticks. Reapply when it is about to fall off, not before.",
                "Replaces any other sting on the target -- a Viper Sting or Scorpid Sting is lost when this lands.",
            },
            talents = {
                ["Improved Serpent Sting"] = "up to +10% damage",
                ["Improved Stings"] = "TBC: up to +30% Serpent and Wyvern Sting damage and Viper Sting drain",
            },
            forever = {
                talents = {
                    ["Improved Serpent Sting"] = "up to +10% damage",
                    ["Improved Stings"] = "up to +20% damage",
                },
            },
        },

        ["Viper Sting"] = {
            roles = { "mana_drain", "debuff" },
            kind = "instant", school = "nature", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing", "no_other_sting", "target_has_mana" },
            cast = 0, cooldown = 0, duration = 8, learned = 36, stacks = "sting", approx = true,
            applies = { aura = "Viper Sting", on = "target", effect = "drains mana over 8s, in four ticks", amount = 830,
                note = "830 at rank 3 is recalled, not read; 1108 is the TBC rank 4 figure. Check the tooltip." },
            synergy = {
                "For casters, and only for casters: a mob with no mana takes nothing from it.",
                "Replaces Serpent Sting on the target. Choose: the damage or the drain.",
            },
            -- Forever: read from the tooltip, and a fifteen-second cooldown.
            forever = {
                cooldown = 15, approx = false,
                applies = { aura = "Viper Sting", on = "target", effect = "drains mana over 8s, in four ticks", amount = 1108,
                    note = "1108 at rank 3" },
                talents = { ["Improved Stings"] = "up to -6s cooldown" },
            },
        },

        ["Scorpid Sting"] = {
            roles = { "debuff" },
            kind = "instant", school = "nature", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing", "no_other_sting" },
            cast = 0, cooldown = 0, duration = 20, learned = 22, stacks = "sting",
            applies = { aura = "Scorpid Sting", on = "target", effect = "-strength and -agility (68 each at rank 4)", amount = 68 },
            synergy = {
                "A mitigation debuff for a melee mob beating on the pet: less strength is less damage taken.",
                "Replaces Serpent Sting. On a mob the pet is tanking for a long time it can be worth more than the dot.",
            },
            talents = {
                ["Improved Scorpid Sting"] = "also reduces stamina by up to 30% of the strength taken",
            },
            -- Forever: one rank, and it takes hit chance instead.
            forever = {
                applies = { aura = "Scorpid Sting", on = "target", effect = "-2% chance to hit with attacks", amount = 2 },
                synergy = {
                    "A mitigation debuff for a mob beating on the pet: two percent fewer of its attacks land.",
                    "Replaces Serpent Sting. On a mob the pet is tanking for a long time it can be worth more than the dot.",
                },
                talents = { ["Improved Stings"] = "up to +45s duration" },
            },
        },

        ["Wyvern Sting"] = {
            roles = { "sleep", "dot", "debuff", "cc" }, client = "era",
            kind = "instant", school = "nature", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "facing", "no_other_sting" },
            cast = 0, cooldown = 120, duration = 12, learned = 40, talent = "Wyvern Sting", stacks = "sting",
            applies = { aura = "Wyvern Sting", on = "target", effect = "asleep 12s (breaks on damage), then nature damage over 12s on waking" },
            damage = { delivery = "dot", school = "nature", amount = 600, ticks = 6, note = "600 nature over 12s at rank 3 (100 every 2s), after the sleep ends" },
            synergy = {
                "The 31-point Survival talent: a second crowd control that needs no trap and, unlike a trap, can be cast in combat.",
                "Any damage wakes it. The pet has to be off that mob.",
            },
            talents = {
                ["Wyvern Sting"] = "the ability itself (Survival, tier 7, 1 point)",
            },
        },

        -- --- melee -------------------------------------------------------

        ["Raptor Strike"] = {
            roles = { "damage" },
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing" },
            cast = 0, cooldown = 6, learned = 1, on_next_swing = true,
            damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 140,
                note = "next melee swing + 140 at rank 8; on-next-swing, so it costs no global cooldown" },
            synergy = {
                "The button for the dead zone. Not a reason to be there: a hunter in melee is doing a fraction of its damage.",
                "On-next-swing: queue it and keep auto-attacking; it fires with the swing.",
            },
            talents = {
                ["Savage Strikes"] = "up to +20% crit on Raptor Strike and Mongoose Bite",
            },
            forever = {
                damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 70,
                    note = "melee weapon damage + 70 at rank 8; no global cooldown" },
                talents = {
                    ["Savage Strikes"] = "up to +4% crit",
                    ["Predator's Edge"] = "its crits deal up to +30% more",
                },
            },
        },

        ["Mongoose Bite"] = {
            roles = { "damage" },
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing", "after_dodge" },
            cast = 0, cooldown = 5, learned = 16,
            damage = { delivery = "flat", school = "physical", amount = 115, scaling = "none", note = "115 at rank 4" },
            synergy = {
                "Only after you dodge, and only for five seconds after. Aspect of the Monkey makes the dodge happen.",
            },
            talents = {
                ["Savage Strikes"] = "up to +20% crit",
            },
            forever = {
                damage = { delivery = "weapon", school = "physical", scaling = "weapon", amount = 57,
                    note = "melee weapon damage + 57 at rank 4" },
                talents = {
                    ["Savage Strikes"] = "up to +4% crit",
                    ["Expose Prey"] = "your attacks on a target under your Hunter's Mark can make it usable without a dodge",
                    ["Lacerating Strikes"] = "it also bleeds the target for 40% of its damage over 21s",
                },
            },
        },

        -- Forever's Survival talent (1.80.0): the melee hunter's strike.
        ["Strider Kick"] = {
            roles = { "damage" }, client = "forever",
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing" },
            cast = 0, cooldown = 8, learned = 30, talent = "Strider Kick",
            damage = { delivery = "weapon", school = "physical", scaling = "weapon",
                note = "Forever: 100% melee weapon damage, and 30% run speed for 3s" },
            synergy = {
                "Forever's Survival is a melee spec: Raptor Strike, Strider Kick and Mongoose Bite (Icy Veins, wowtbc.gg, Mobalytics).",
            },
        },

        -- Forever's trained bleed. Ranks at 30, 40, 50 and 60.
        ["Lacerate"] = {
            roles = { "dot", "damage", "debuff" }, client = "forever",
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing" },
            cast = 0, cooldown = 0, duration = 21, learned = 30,
            applies = { aura = "Lacerate", on = "target" },
            damage = { delivery = "dot", school = "physical", amount = 406, ticks = 7, scaling = "none",
                note = "406 over 21s at rank 4 (58 every 3s)" },
            synergy = {
                "The melee hunter's dot: up on anything that lives the twenty-one seconds.",
                "Not a sting, so it sits beside Serpent Sting rather than replacing it.",
            },
        },

        ["Counterattack"] = {
            roles = { "damage", "root" },
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing", "after_parry" },
            cast = 0, cooldown = 5, duration = 5, learned = 30, talent = "Counterattack",
            applies = { aura = "Counterattack", on = "target", effect = "rooted 5s" },
            damage = { delivery = "flat", school = "physical", amount = 110, note = "110 at rank 3" },
            synergy = {
                "After a parry, and Deflection is what makes parries happen. Root it, step out of the dead zone, shoot.",
            },
            talents = {
                ["Counterattack"] = "the ability itself (Survival, tier 5, 1 point)",
                ["Deflection"] = "up to +5% parry, which is how often this is available",
            },
            forever = {
                damage = { delivery = "weapon", school = "physical", scaling = "weapon", fraction = 0.5, amount = 110,
                    note = "50% weapon damage + 110 at rank 3" },
                talents = {
                    ["Counterattack"] = "the ability itself (Survival, tier 4, 1 point)",
                    ["Deflection"] = "up to +5% parry, which is how often this is available",
                },
            },
        },

        ["Wing Clip"] = {
            roles = { "slow", "debuff" },
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing" },
            cast = 0, cooldown = 0, duration = 10, learned = 12,
            applies = { aura = "Wing Clip", on = "target", effect = "-50% movement speed" },
            synergy = {
                "The melee slow: clip the mob that reached you, then run out past eight yards and shoot it.",
                "No cooldown. With Concussive Shot it is a permanent slow on one mob.",
                "Improved Wing Clip's root is the escape from the dead zone: rooted, it cannot follow you out.",
            },
            talents = {
                ["Improved Wing Clip"] = "up to a 20% chance to root for 5s instead",
            },
            forever = {
                talents = { ["Improved Wing Clip"] = "a 7%, 13%, then 20% chance to immobilize for 5s" },
            },
        },

        ["Disengage"] = {
            roles = { "threat_drop" },
            kind = "instant", school = "physical", cost = "mana", range = "melee",
            needs = { "melee_weapon", "facing" },
            cast = 0, cooldown = 5, learned = 20,
            applies = { effect = "reduces the target's threat towards you (405 at rank 3)", amount = 405 },
            synergy = {
                "Classic's Disengage is a threat drop, not a leap. It pushes a mob back onto the pet or the tank.",
                "Melee range only: you are already where you do not want to be when it is usable.",
            },
        },

        -- --- marks and aspects ---------------------------------------------

        ["Hunter's Mark"] = {
            roles = { "debuff", "buff" },
            kind = "instant", school = "arcane", cost = "mana", range = 100,
            needs = { "facing" },
            cast = 0, cooldown = 0, duration = 120, learned = 6,
            applies = { aura = "Hunter's Mark", on = "target", effect = "+ranged attack power against this target for everyone; visible through stealth", amount = 110 },
            synergy = {
                "First on every pull: 110 RAP at rank 4 for the whole fight, for the whole party.",
                "Keeps a stealthed or invisible target visible and targetable. The rogue cannot vanish out of it.",
                "Two minutes; refresh only when it is gone, not per pull on a mob that dies in ten seconds.",
            },
            talents = {
                ["Improved Hunter's Mark"] = "up to +15% to the ranged attack power bonus",
            },
            forever = {
                applies = { aura = "Hunter's Mark", on = "target", effect = "+ranged attack power against this target for everyone; visible through stealth", amount = 71 },
                synergy = {
                    "First on every pull: 71 RAP at rank 4 for the whole fight, for the whole party.",
                    "Keeps a stealthed or invisible target visible and targetable. The rogue cannot vanish out of it.",
                    "Two minutes; refresh only when it is gone, not per pull on a mob that dies in ten seconds.",
                },
                talents = { ["Expose Prey"] = "your attacks on the marked target can make Mongoose Bite usable" },
            },
        },

        ["Aspect of the Hawk"] = {
            roles = { "aspect", "buff" },
            kind = "aura", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 0, learned = 10,
            applies = { aura = "Aspect of the Hawk", on = "self", effect = "+ranged attack power", amount = 120 },
            exclusive = "aspect",
            synergy = {
                "The damage aspect, and the one to be in whenever you are shooting. One aspect at a time.",
                "Improved Aspect of the Hawk turns it into the class's best proc: quick shots after an Auto Shot.",
            },
            talents = {
                ["Improved Aspect of the Hawk"] = "Auto Shots have a chance to grant +30% ranged haste for 12s",
            },
            forever = {
                synergy = {
                    "The damage aspect, and the one to be in whenever you are shooting. One aspect at a time.",
                    "Deadly Aspects gives it the quick-shots proc on Forever: +30% ranged attack speed after an Auto Shot.",
                },
                talents = { ["Deadly Aspects"] = "Auto Shots have a 2% chance per rank (10% at 5) to grant +30% ranged attack speed for 12s" },
            },
        },

        ["Aspect of the Monkey"] = {
            roles = { "aspect", "buff" },
            kind = "aura", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 0, learned = 4,
            applies = { aura = "Aspect of the Monkey", on = "self", effect = "+8% dodge" },
            exclusive = "aspect",
            synergy = {
                "The melee aspect: dodges feed Mongoose Bite. Switch to it only when stuck in melee for a while.",
                "Costs a global to switch each way. Not worth the swap for a mob that dies in three swings.",
            },
            talents = {
                ["Improved Aspect of the Monkey"] = "up to +5% more dodge",
            },
            forever = {
                talents = { ["Improved Aspect of the Monkey"] = "+2% more dodge per rank (6% at 3), and the pet gets half the aspect" },
            },
        },

        ["Aspect of the Cheetah"] = {
            roles = { "aspect", "buff", "utility" },
            kind = "aura", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 0, learned = 20,
            applies = { aura = "Aspect of the Cheetah", on = "self", effect = "+30% run speed; DAZED when hit" },
            exclusive = "aspect",
            synergy = {
                "Travel only. Hit while in it and you are dazed at half speed with no aspect worth having.",
                "Never for kiting: one hit and the mob you were kiting catches you dazed.",
            },
        },

        ["Aspect of the Pack"] = {
            roles = { "aspect", "buff", "utility" },
            kind = "aura", school = "nature", cost = "mana", range = "party",
            needs = {}, cast = 0, cooldown = 0, learned = 40,
            applies = { aura = "Aspect of the Pack", on = "party", effect = "+30% run speed for the party; each member is dazed when hit" },
            exclusive = "aspect",
            synergy = { "Cheetah for the group, with the same daze for everyone. Off before any pull." },
        },

        ["Aspect of the Wild"] = {
            roles = { "aspect", "buff" },
            kind = "aura", school = "nature", cost = "mana", range = "party",
            needs = {}, cast = 0, cooldown = 0, learned = 46,
            applies = { aura = "Aspect of the Wild", on = "party", effect = "+nature resistance for the party", amount = 60 },
            exclusive = "aspect",
            synergy = { "A raid aspect for nature fights. Costs the Hawk RAP while it is up." },
        },

        ["Aspect of the Beast"] = {
            roles = { "aspect", "buff" },
            kind = "aura", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 0, learned = 30,
            applies = { aura = "Aspect of the Beast", on = "self", effect = "untrackable by Track Humanoids" },
            exclusive = "aspect",
            synergy = { "For hiding from other hunters on a PvP server. Nothing else." },
            -- Forever: four ranks (30, 40, 50, 60), and the melee aspect.
            forever = {
                applies = { aura = "Aspect of the Beast", on = "self", effect = "+melee attack power, and untrackable", amount = 110 },
                synergy = {
                    "Forever's melee aspect: 110 melee attack power at rank 4, and still untrackable.",
                    "Deadly Aspects gives it a proc: +30% melee attack speed after a melee auto attack.",
                },
                talents = { ["Deadly Aspects"] = "melee auto attacks have a 2% chance per rank (10% at 5) to grant +30% melee attack speed for 12s" },
            },
        },

        ["Trueshot Aura"] = {
            roles = { "buff", "aura" },
            kind = "aura", school = "arcane", cost = "mana", range = "party",
            needs = {}, cast = 0, cooldown = 0, learned = 40, talent = "Trueshot Aura",
            applies = { aura = "Trueshot Aura", on = "party", effect = "+attack power for party members within 30 yards; lasts until cancelled", amount = 100 },
            synergy = {
                "The 31-point Marksmanship talent: 100 attack power at rank 3 for everyone near you, melee included.",
                "Not an aspect -- it stacks with Aspect of the Hawk and stays up through aspect swaps.",
                "Put it up once per session and forget it; it only needs re-casting after death.",
            },
            talents = {
                ["Trueshot Aura"] = "the ability itself (Marksmanship, tier 7, 1 point)",
            },
            -- Forever: the talent gives rank 1 at 25, the trainer the rest.
            forever = {
                learned = 25, approx = true,
                applies = { aura = "Trueshot Aura", on = "party", effect = "+ranged attack power for party members within 45 yards; lasts 30 min", amount = 50,
                    note = "30, 40, 50 and 75 at levels 25, 32, 40 and 50; the client's table says 50 at 60, below rank 4 -- check it in game" },
                synergy = {
                    "Forever's Marksmanship tier-4 talent gives rank 1 at level 25; ranks 2 to 5 are trained at 32, 40, 50 and 60.",
                    "Ranged attack power only, for everyone within 45 yards.",
                    "Not an aspect -- it stacks with Aspect of the Hawk and stays up through aspect swaps.",
                    "Thirty minutes: put it up before a run of pulls and again when it falls off.",
                },
                talents = { ["Trueshot Aura"] = "its first rank (Marksmanship, tier 4, 1 point)" },
            },
        },

        ["Aspect of the Viper"] = {
            roles = { "aspect", "buff" }, expansion = "tbc", client = "era",
            kind = "aura", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 0, learned = 64,
            applies = { aura = "Aspect of the Viper", on = "self", effect = "mana regeneration scaled by how empty the bar is" },
            exclusive = "aspect",
            synergy = { "TBC's answer to drinking: swap in when low, swap back to Hawk when full." },
        },

        -- --- cooldowns ---------------------------------------------------

        ["Rapid Fire"] = {
            roles = { "cooldown", "buff" },
            kind = "instant", school = "physical", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 300, duration = 15, learned = 26,
            applies = { aura = "Rapid Fire", on = "self", effect = "+40% ranged attack speed" },
            synergy = {
                "Fifteen seconds of forty percent more Auto Shots. Worth the most on a target that lives that long.",
                "Stacks with the quick-shots proc and with Bestial Wrath: the burst window is all three at once.",
            },
            talents = {
                ["Rapid Killing"] = "TBC: up to -2 minutes cooldown",
            },
            forever = {
                applies = { aura = "Rapid Fire", on = "self", effect = "+40% ranged and melee attack speed" },
                talents = { ["Rapid Killing"] = "-1 minute cooldown per rank" },
            },
        },

        ["Bestial Wrath"] = {
            roles = { "cooldown", "pet", "buff" },
            kind = "instant", school = "nature", cost = "mana", range = "pet",
            needs = { "pet_alive" }, cast = 0, cooldown = 120, duration = 18, learned = 40, talent = "Bestial Wrath",
            applies = { aura = "Bestial Wrath", on = "pet", effect = "pet +50% damage and immune to all crowd control and fear" },
            synergy = {
                "The Beast Mastery 31-point talent. Eighteen seconds of a pet that hits half again as hard and cannot be stopped.",
                "Two minutes against fights every thirty seconds: use it on cooldown while levelling, hold it for nothing.",
                "With Intimidation: stun, then wrath -- the pet's big window opens on a mob that cannot move.",
            },
            talents = {
                ["Bestial Wrath"] = "the ability itself (Beast Mastery, tier 7, 1 point)",
                ["The Beast Within"] = "TBC 41-point: you rage too, for +10% damage, -20% mana costs and the immunity",
            },
            forever = {
                talents = { ["Bestial Wrath"] = "the ability itself (Beast Mastery, tier 7, 1 point)" },
            },
        },

        ["Intimidation"] = {
            roles = { "stun", "pet", "threat" },
            kind = "instant", school = "physical", cost = "mana", range = "pet",
            needs = { "pet_alive", "pet_on_target" }, cast = 0, cooldown = 60, duration = 3, learned = 30, talent = "Intimidation",
            applies = { aura = "Intimidation", on = "target", effect = "stunned 3s by the pet's next attack; the pet gains a large amount of threat" },
            synergy = {
                "The pet does the stunning, so the pet has to be ON the mob: fired while it is still running in, it stuns nothing.",
                "Three seconds of a mob that cannot move is three free shots, or the gap to get out of the dead zone.",
                "The threat is the point when the pet has lost the mob: Intimidation hands it back.",
            },
            talents = {
                ["Intimidation"] = "the ability itself (Beast Mastery, tier 5, 1 point)",
            },
            forever = {
                applies = { aura = "Intimidation", on = "target", effect = "stunned 3s by the pet's next attack, which has +100% crit chance; the pet gains a large amount of threat" },
            },
        },

        ["Deterrence"] = {
            roles = { "cooldown", "buff", "defensive" },
            kind = "instant", school = "physical", cost = "none", range = "self",
            needs = {}, cast = 0, cooldown = 300, duration = 10, learned = 30, talent = "Deterrence",
            applies = { aura = "Deterrence", on = "self", effect = "+25% dodge and +25% parry" },
            synergy = {
                "Ten seconds of not being hit in melee. The defensive for the mob that reached you and will not let go.",
                "Parries feed Counterattack: Deterrence up, parry, root it, walk away.",
            },
            talents = {
                ["Deterrence"] = "the ability itself (Survival, tier 3, 1 point)",
            },
            forever = {
                talents = {
                    ["Deterrence"] = "the ability itself (Survival, tier 3, 1 point)",
                    ["Survivalist's Discipline"] = "up to -40% cooldown",
                },
            },
        },

        ["Feign Death"] = {
            roles = { "threat_drop", "cooldown", "utility", "defensive", "escape" },
            kind = "instant", school = "physical", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 30, duration = 360, learned = 30,
            applies = { aura = "Feign Death", on = "self", effect = "you appear dead: every mob drops you from its threat list and leaves combat with you" },
            synergy = {
                "The reset button. Mobs walk back to the pet, or home if there is no pet.",
                "Drops YOU out of combat, which is what lets a trap be laid mid-fight in Classic: feign, trap, stand up.",
                "Can be resisted by higher-level mobs; Improved Feign Death lowers that.",
                "Moving or acting ends it. Stand up when the mob has turned, not before.",
            },
            talents = {
                ["Improved Feign Death"] = "up to -4% chance of being resisted",
            },
            forever = {
                applies = { aura = "Feign Death", on = "self", effect = "you appear dead: every mob drops you from its threat list and leaves combat with you; still down after 6 min, you die" },
                synergy = {
                    "The reset button. Mobs walk back to the pet, or home if there is no pet.",
                    "Can be resisted by higher-level mobs; Survival Tactics lowers that.",
                    "Moving or acting ends it. Stand up when the mob has turned, not before.",
                },
                talents = { ["Survival Tactics"] = "up to +10% chance to hit: resisted less often" },
            },
        },

        ["Readiness"] = {
            roles = { "cooldown" }, expansion = "tbc", client = "era",
            kind = "instant", school = "physical", cost = "none", range = "self",
            needs = {}, cast = 0, cooldown = 300, learned = 60, talent = "Readiness",
            applies = { effect = "finishes the cooldown of every other hunter ability" },
            synergy = { "TBC 41-point Survival: a second trap, a second Wyvern Sting, a second everything." },
        },

        ["Misdirection"] = {
            roles = { "threat", "utility" }, expansion = "tbc", client = "era",
            kind = "instant", school = "physical", cost = "mana", range = 100,
            needs = { "friendly_target" }, cast = 0, cooldown = 120, duration = 30, learned = 70,
            applies = { aura = "Misdirection", on = "friend", effect = "your next three attacks' threat goes to the target" },
            synergy = { "Onto the tank at the pull: Multi-Shot, Arcane Shot, Auto Shot all land on the tank's threat." },
        },

        -- --- traps ------------------------------------------------------
        -- Classic traps cannot be laid while in combat, arm two seconds
        -- after being placed, last a minute, and share one cooldown.
        -- Forever's can be laid in combat and come in two kinds: one Frost
        -- trap (Freezing, Frost) and one Fire trap (Immolation, Explosive)
        -- may be down at a time, each kind on its own 30-second cooldown.

        ["Freezing Trap"] = {
            roles = { "trap", "root", "cc" },
            kind = "trap", school = "frost", cost = "mana", range = "self",
            needs = { "out_of_combat" }, cast = 0, cooldown = 15, duration = 20, learned = 20, arm = 2, lasts = 60,
            applies = { aura = "Freezing Trap Effect", on = "target", effect = "frozen in a block of ice for up to 20s at rank 3; breaks on damage" },
            synergy = {
                "The long control. Laid before the pull so the second mob walks into it, or mid-fight after a Feign Death.",
                "Scatter Shot into it: the disoriented mob wanders onto the trap.",
                "Any damage breaks it -- the pet, a dot, a Multi-Shot. Serpent Sting on a trapped mob is a broken trap.",
            },
            talents = {
                ["Clever Traps"] = "up to +30% duration",
                ["Trap Mastery"] = "up to -10% chance to be resisted",
            },
            forever = {
                needs = {}, cooldown = 30,
                talents = {
                    ["Clever Traps"] = "up to +30% duration",
                    ["Survival Tactics"] = "up to +10% chance to hit",
                    ["Survivalist's Discipline"] = "up to -40% cooldown",
                },
            },
        },

        ["Frost Trap"] = {
            roles = { "trap", "slow", "aoe" },
            kind = "trap", school = "frost", cost = "mana", range = "self",
            needs = { "out_of_combat" }, cast = 0, cooldown = 15, duration = 30, learned = 28, arm = 2, lasts = 60,
            applies = { aura = "Frost Trap Aura", on = "ground", effect = "-60% movement speed to everything in a 10-yard patch for 30s" },
            synergy = {
                "The kiting trap. Lay it, pull across it, shoot the mob crawling through it.",
                "Does not break on damage: this is the one trap the pet and the dots may hit through.",
            },
            talents = {
                ["Clever Traps"] = "up to +30% duration",
                ["Entrapment"] = "up to a 25% chance to root what enters it for 5s",
            },
            forever = {
                needs = {}, cooldown = 30,
                talents = {
                    ["Clever Traps"] = "up to +30% duration",
                    ["Entrapment"] = "roots what sets it off for 1s per rank (5s at 5)",
                    ["Survival Tactics"] = "up to +10% chance to hit",
                    ["Survivalist's Discipline"] = "up to -40% cooldown",
                },
            },
        },

        ["Immolation Trap"] = {
            roles = { "trap", "dot", "damage" },
            kind = "trap", school = "fire", cost = "mana", range = "self",
            needs = { "out_of_combat" }, cast = 0, cooldown = 15, duration = 15, learned = 16, arm = 2, lasts = 60,
            applies = { aura = "Immolation Trap Effect", on = "target" },
            damage = { delivery = "dot", school = "fire", amount = 690, ticks = 5, note = "690 fire over 15s at rank 5 (138 every 3s)" },
            synergy = { "Free damage on a pull: laid first, the mob takes it walking in." },
            talents = { ["Clever Traps"] = "up to +30% damage", ["Trap Mastery"] = "up to -10% resist chance" },
            forever = {
                needs = {}, cooldown = 30,
                talents = {
                    ["Clever Traps"] = "up to +30% damage",
                    ["Entrapment"] = "roots what sets it off for 1s per rank (5s at 5)",
                    ["Survival Tactics"] = "up to +10% chance to hit",
                    ["Survivalist's Discipline"] = "up to -40% cooldown",
                },
            },
        },

        ["Explosive Trap"] = {
            roles = { "trap", "aoe", "damage", "dot" },
            kind = "trap", school = "fire", cost = "mana", range = "self",
            needs = { "out_of_combat" }, cast = 0, cooldown = 15, duration = 20, learned = 34, arm = 2, lasts = 60,
            applies = { aura = "Explosive Trap Effect", on = "target" },
            damage = { delivery = "flat", school = "fire", amount = 236, then_dot = 330, ticks = 10,
                note = "208 to 265 fire to everything within 10 yards at rank 3, then 330 fire over 20s (33 every 2s)" },
            synergy = { "The AoE trap, for a pack walking in together." },
            talents = { ["Clever Traps"] = "up to +30% damage", ["Trap Mastery"] = "up to -10% resist chance" },
            forever = {
                needs = {}, cooldown = 30,
                damage = { delivery = "flat", school = "fire", amount = 229, then_dot = 330, ticks = 10,
                    note = "229 fire to everything within 10 yards at rank 3, then 330 fire over 20s (33 every 2s)" },
                talents = {
                    ["Clever Traps"] = "up to +30% damage",
                    ["Entrapment"] = "roots what it catches for 1s per rank (5s at 5)",
                    ["Survival Tactics"] = "up to +10% chance to hit",
                    ["Survivalist's Discipline"] = "up to -40% cooldown",
                },
            },
        },

        ["Snake Trap"] = {
            roles = { "trap", "utility" }, expansion = "tbc", client = "era",
            kind = "trap", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, cooldown = 30, learned = 68, arm = 2, lasts = 60,
            applies = { effect = "releases snakes that poison and slow whatever set it off" },
        },

        -- --- utility ------------------------------------------------------

        ["Volley"] = {
            roles = { "aoe", "damage" },
            kind = "channel", school = "arcane", cost = "mana", range = "ranged",
            needs = { "ranged_weapon", "ammo", "standing" },
            cast = 0, channel = 6, cooldown = 60, learned = 40, ground_targeted = true,
            damage = { delivery = "per_tick", school = "arcane", amount = 80, ticks = 6,
                note = "arcane damage every second to everything in an 8-yard circle, for six seconds" },
            synergy = {
                "Ground-targeted and channelled: nothing else happens for six seconds. Only for a pack that will stand in it.",
            },
            talents = { ["Barrage"] = "up to +15% damage" },
            -- Forever: no cooldown. Its range table has no minimum either; the
            -- row keeps the ranged band so Hawk Eye still counts for it.
            forever = {
                cooldown = 0,
                damage = { delivery = "per_tick", school = "arcane", amount = 112, ticks = 6,
                    note = "112 arcane every second at rank 3 to everything in an 8-yard circle, for six seconds" },
                talents = { ["Barrage"] = "up to +10% damage" },
            },
        },

        ["Flare"] = {
            roles = { "utility" },
            kind = "instant", school = "arcane", cost = "mana", range = 30,
            needs = {}, cast = 0, cooldown = 15, duration = 30, learned = 32, ground_targeted = true,
            applies = { effect = "reveals stealthed and invisible units within 10 yards of the point for 30s" },
            synergy = { "Against rogues and druids. The stealth-sense module says when one is close; this is what finds it." },
        },

        ["Scare Beast"] = {
            roles = { "fear", "cc" },
            kind = "cast", school = "nature", cost = "mana", range = 10,
            needs = { "target_beast", "standing" }, cast = 1.5, cooldown = 30, duration = 20, learned = 14,
            applies = { aura = "Scare Beast", on = "target", effect = "a beast flees in fear for up to 20s at rank 3; breaks on damage" },
            synergy = {
                "Beasts only, which is most of the open world. A cast, so not while moving, and ten yards: it is for the second beast, not the one you are shooting.",
                "The other hunter's pet and a druid in cat or bear form count as beasts.",
            },
        },

        ["Eagle Eye"] = {
            roles = { "utility" }, kind = "channel", school = "nature", cost = "mana", range = "self",
            needs = {}, cast = 0, channel = 60, cooldown = 0, learned = 14,
            applies = { effect = "your view moves to a distant point" },
        },

        ["Track Beasts"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 1, exclusive = "tracking" },
        ["Track Humanoids"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 10, exclusive = "tracking" },
        ["Track Undead"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 18, exclusive = "tracking" },
        ["Track Hidden"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 24, exclusive = "tracking",
            synergy = { "Also raises your stealth detection while it is on. The tracking to run on a PvP server." } },
        ["Track Elementals"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 26, exclusive = "tracking" },
        ["Track Demons"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 32, exclusive = "tracking" },
        ["Track Giants"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 40, exclusive = "tracking" },
        ["Track Dragonkin"] = { roles = { "tracking" }, kind = "aura", school = "none", cost = "none", range = "self", needs = {}, cast = 0, cooldown = 0, learned = 50, exclusive = "tracking" },

        -- --- the pet ------------------------------------------------------

        ["Call Pet"] = { roles = { "pet" }, kind = "instant", school = "none", cost = "none", range = "self", needs = { "no_pet" }, cast = 0, cooldown = 0, learned = 10,
            synergy = { "The pet is the tank from ten onwards. Everything in the levelling profile assumes it is out." } },
        ["Dismiss Pet"] = { roles = { "pet" }, kind = "cast", school = "none", cost = "none", range = "pet", needs = { "pet_alive" }, cast = 5, cooldown = 0, learned = 10 },
        ["Revive Pet"] = { roles = { "pet" }, kind = "cast", school = "nature", cost = "mana", range = "self", needs = { "pet_dead", "standing" }, cast = 10, cooldown = 0, learned = 10,
            synergy = { "Ten seconds standing still. Never in combat unless everything else has already gone wrong." },
            talents = { ["Improved Revive Pet"] = "up to -6s cast time, -40% mana, and the pet returns with more health" } },
        ["Feed Pet"] = { roles = { "pet" }, kind = "channel", school = "none", cost = "none", range = "pet", needs = { "pet_alive", "food_item" }, cast = 0, channel = 20, cooldown = 0, learned = 10,
            applies = { aura = "Feed Pet Effect", on = "pet", effect = "happiness rises over 20s; breaks if the pet fights" },
            synergy = { "Happiness is pet damage: content is 100%, unhappy is 75%. Feed between fights, never during." } },
        ["Mend Pet"] = {
            roles = { "heal", "pet" },
            kind = "channel", school = "nature", cost = "mana", range = 20,
            needs = { "pet_alive", "standing" }, cast = 0, channel = 5, cooldown = 0, learned = 12,
            heal = { delivery = "per_tick", amount = 1225, ticks = 5, note = "1225 over 5s at rank 7 (245 a second); channelled, so you stop shooting" },
            synergy = {
                "The pet is the tank, so keeping it alive outranks any shot. Every second of the channel is a second of no Auto Shot.",
                "Improved Mend Pet also cleanses the pet: poison, disease, magic, curse.",
            },
            talents = { ["Improved Mend Pet"] = "up to a 50% chance each tick to remove a poison, disease, magic or curse effect" },
            forever = {
                talents = { ["Improved Mend Pet"] = "up to a 50% chance each tick to remove a poison, disease, magic or curse effect, and up to -20% mana" },
            },
        },
        ["Tame Beast"] = { roles = { "pet", "utility" }, kind = "channel", school = "nature", cost = "none", range = 30, needs = { "target_beast", "no_pet", "standing" }, cast = 0, channel = 20, cooldown = 0, learned = 10,
            synergy = { "Twenty seconds of the beast hitting you. Freezing Trap it first, or use Aspect of the Monkey." } },
        ["Beast Lore"] = { roles = { "pet", "utility" }, kind = "instant", school = "none", cost = "none", range = 40, needs = { "target_beast" }, cast = 0, cooldown = 0, learned = 24 },
        ["Eyes of the Beast"] = { roles = { "pet", "utility" }, kind = "channel", school = "nature", cost = "mana", range = "pet", needs = { "pet_alive" }, cast = 0, channel = 60, cooldown = 0, learned = 14,
            forever = { channel = 120 } },
        ["Beast Training"] = { roles = { "pet", "utility" }, kind = "instant", school = "none", cost = "none", range = "self", needs = { "pet_alive" }, cast = 0, cooldown = 0, learned = 10 },
        -- Forever's pet cooldown: learned at 20 and cast by the pet itself,
        -- for 10 of its focus.
        ["Trickster's Dance"] = {
            roles = { "cooldown", "pet", "buff" }, client = "forever",
            kind = "pet_command", school = "physical", cost = "none", range = "pet",
            needs = { "pet_alive" }, cast = 0, cooldown = 180, duration = 12, learned = 20,
            applies = { aura = "Trickster's Dance", on = "pet", effect = "pet +50% dodge and 30% less time between its attacks" },
            synergy = { "Twelve seconds of fifty points more dodge and faster attacks on the pet: for the pull the pet is losing." },
        },
        ["Kill Command"] = {
            roles = { "damage", "pet" }, expansion = "tbc", client = "era",
            kind = "instant", school = "physical", cost = "mana", range = "pet",
            needs = { "pet_alive", "after_your_crit" }, cast = 0, cooldown = 5, learned = 66,
            damage = { delivery = "flat", school = "physical", amount = 127, note = "the pet's next attack deals +127" },
            synergy = { "TBC: available for a moment after one of your attacks crits. Off the global; press it whenever it lights." },
            talents = { ["Ferocious Inspiration"] = "TBC: the pet's crits grant the party +3% damage", ["Go for the Throat"] = "TBC: your ranged crits give the pet focus" },
        },
    },

    -- --- talents ------------------------------------------------------------

    talents = {
        -- Beast Mastery
        ["Improved Aspect of the Hawk"] = { tree = "Beast Mastery", tier = 1, max = 5, affects = { "Auto Shot", "Aspect of the Hawk" },
            effect = "Auto Shots in Hawk have up to a 5% chance to grant +30% ranged attack speed for 12s", client = "era" },
        ["Endurance Training"] = { tree = "Beast Mastery", tier = 1, max = 5, affects = { "pet" }, effect = "pet up to +15% health",
            forever = { effect = "pet +3% health and armour per rank (15% at 5)" } },
        ["Improved Eyes of the Beast"] = { tree = "Beast Mastery", tier = 2, max = 2, affects = { "Eyes of the Beast" }, effect = "+30s duration per rank", client = "era" },
        ["Improved Aspect of the Monkey"] = { tree = "Beast Mastery", tier = 2, max = 5, affects = { "Aspect of the Monkey" }, effect = "up to +5% dodge in Monkey",
            forever = { max = 3, affects = { "Aspect of the Monkey", "pet" }, effect = "+2% dodge in Monkey per rank (6% at 3), and the pet gets half the aspect" } },
        ["Thick Hide"] = { tree = "Beast Mastery", tier = 2, max = 3, affects = { "pet" }, effect = "pet up to +30% armour", client = "era" },
        ["Improved Revive Pet"] = { tree = "Beast Mastery", tier = 2, max = 2, affects = { "Revive Pet" }, effect = "-3s cast and -20% mana per rank; pet returns with more health" },
        ["Pathfinding"] = { tree = "Beast Mastery", tier = 3, max = 2, affects = { "Aspect of the Cheetah", "Aspect of the Pack" }, effect = "+3% speed per rank in Cheetah and Pack",
            forever = { tier = 2 } },
        ["Bestial Swiftness"] = { tree = "Beast Mastery", tier = 3, max = 1, affects = { "pet" }, effect = "pet +30% outdoor movement speed: it reaches the mob sooner",
            forever = { effect = "pet +30% movement speed: it reaches the mob sooner" } },
        ["Unleashed Fury"] = { tree = "Beast Mastery", tier = 3, max = 5, affects = { "pet" }, effect = "pet up to +20% damage",
            forever = { affects = { "pet", "Summon Hawk" }, effect = "pets and hawks +3% damage per rank (15% at 5)" } },
        ["Improved Mend Pet"] = { tree = "Beast Mastery", tier = 4, max = 2, affects = { "Mend Pet" }, effect = "a 15%, then 50%, chance per tick to cleanse the pet",
            forever = { effect = "a 15%, then 50%, chance per tick to cleanse the pet, and -10% Mend Pet mana per rank" } },
        ["Ferocity"] = { tree = "Beast Mastery", tier = 4, max = 5, affects = { "pet" }, effect = "pet up to +15% crit",
            forever = { affects = { "pet", "Summon Hawk" }, effect = "pets and hawks +2% crit per rank (10% at 5)" } },
        ["Spirit Bond"] = { tree = "Beast Mastery", tier = 5, max = 2, affects = { "pet" }, effect = "you and the pet regenerate 1% health per rank every 10s while the pet is out" },
        ["Intimidation"] = { tree = "Beast Mastery", tier = 5, max = 1, affects = { "Intimidation" }, effect = "grants Intimidation" },
        ["Bestial Discipline"] = { tree = "Beast Mastery", tier = 5, max = 2, affects = { "pet" }, effect = "pet focus regeneration up to +20%: more pet abilities",
            forever = { affects = { "pet", "mana" }, effect = "pet focus regeneration +10% per rank, and 25% of your mana regeneration per rank goes on while casting" } },
        ["Frenzy"] = { tree = "Beast Mastery", tier = 6, max = 5, affects = { "pet" }, effect = "pet crits have up to a 100% chance to grant it +30% attack speed for 8s" },
        ["Bestial Wrath"] = { tree = "Beast Mastery", tier = 7, max = 1, affects = { "Bestial Wrath" }, effect = "grants Bestial Wrath" },
        ["Animal Handler"] = { tree = "Beast Mastery", tier = 6, max = 2, affects = { "pet" }, effect = "TBC: pet +2% hit per rank, you +4% mounted speed per rank", expansion = "tbc", client = "era" },
        ["Ferocious Inspiration"] = { tree = "Beast Mastery", tier = 7, max = 3, affects = { "pet" }, effect = "TBC: pet crits give the party +1% damage per rank for 10s", expansion = "tbc", client = "era" },
        ["Catlike Reflexes"] = { tree = "Beast Mastery", tier = 7, max = 3, affects = { "pet" }, effect = "TBC: you up to +3% dodge, the pet up to +9%", expansion = "tbc", client = "era" },
        ["Serpent's Swiftness"] = { tree = "Beast Mastery", tier = 8, max = 5, affects = { "Auto Shot", "pet" }, effect = "TBC: up to +20% ranged and pet attack speed", expansion = "tbc", client = "era" },
        ["The Beast Within"] = { tree = "Beast Mastery", tier = 9, max = 1, affects = { "Bestial Wrath" }, effect = "TBC: while the pet is in Bestial Wrath you rage too: +10% damage, -20% mana costs, immune to control", expansion = "tbc", client = "era" },
        ["Deadly Aspects"] = { tree = "Beast Mastery", tier = 1, max = 5, affects = { "Auto Shot", "Aspect of the Hawk", "Aspect of the Beast" }, client = "forever",
            effect = "a 2% chance per rank (10% at 5) of +30% attack speed for 12s: Auto Shots in Hawk, melee auto attacks in Beast" },
        ["Focused Fire"] = { tree = "Beast Mastery", tier = 2, max = 2, affects = { "damage", "pet" }, effect = "you and the pet +1% damage per rank while the pet is out", client = "forever" },
        ["Summon Hawk"] = { tree = "Beast Mastery", tier = 4, max = 1, affects = { "Summon Hawk" }, effect = "grants Summon Hawk", client = "forever" },

        -- Marksmanship
        ["Improved Concussive Shot"] = { tree = "Marksmanship", tier = 1, max = 5, affects = { "Concussive Shot" }, effect = "up to a 20% chance to stun for 3s" },
        ["Efficiency"] = { tree = "Marksmanship", tier = 1, max = 5, affects = { "Aimed Shot", "Multi-Shot", "Arcane Shot", "Serpent Sting" }, effect = "shots and stings up to -10% mana",
            forever = { tier = 2, effect = "shots, stings and melee abilities -3% mana per rank (15% at 5)",
                affects = { "Aimed Shot", "Multi-Shot", "Arcane Shot", "Concussive Shot", "Distracting Shot", "Scatter Shot", "Tranquilizing Shot",
                    "Volley", "Summon Hawk", "Serpent Sting", "Viper Sting", "Scorpid Sting", "Raptor Strike", "Mongoose Bite", "Counterattack",
                    "Wing Clip", "Lacerate" } } },
        ["Improved Hunter's Mark"] = { tree = "Marksmanship", tier = 2, max = 5, affects = { "Hunter's Mark" }, effect = "up to +15% to the mark's ranged attack power bonus", client = "era" },
        ["Lethal Shots"] = { tree = "Marksmanship", tier = 2, max = 5, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Arcane Shot" }, effect = "up to +5% ranged crit", client = "era" },
        ["Aimed Shot"] = { tree = "Marksmanship", tier = 3, max = 1, affects = { "Aimed Shot" }, effect = "grants Aimed Shot", client = "era" },
        ["Improved Arcane Shot"] = { tree = "Marksmanship", tier = 3, max = 5, affects = { "Arcane Shot" }, effect = "up to -1s cooldown",
            forever = { effect = "-0.3s cooldown per rank (1.5s at 5); not the cooldown Summon Hawk shares" } },
        ["Hawk Eye"] = { tree = "Marksmanship", tier = 3, max = 3, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Arcane Shot", "Serpent Sting", "Concussive Shot" }, effect = "+2 yards ranged range per rank",
            forever = { tier = 1, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Arcane Shot", "Concussive Shot", "Distracting Shot", "Scatter Shot",
                "Tranquilizing Shot", "Volley", "Serpent Sting", "Viper Sting", "Scorpid Sting", "Sniper Shot", "Summon Hawk" } } },
        -- On Forever this node sits off the tree's canvas (y 39300, ten times
        -- a real row) beside Improved Stings, which covers it. Its gate is 15
        -- points, tier 4, so it is described as it stands.
        ["Improved Serpent Sting"] = { tree = "Marksmanship", tier = 4, max = 5, affects = { "Serpent Sting" }, effect = "up to +10% damage" },
        ["Mortal Shots"] = { tree = "Marksmanship", tier = 4, max = 5, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Arcane Shot" }, effect = "ranged crits deal up to +30% more" },
        ["Scatter Shot"] = { tree = "Marksmanship", tier = 5, max = 1, affects = { "Scatter Shot" }, effect = "grants Scatter Shot" },
        ["Barrage"] = { tree = "Marksmanship", tier = 5, max = 3, affects = { "Multi-Shot", "Volley" }, effect = "up to +15% damage",
            forever = { affects = { "Multi-Shot", "Aimed Shot", "Volley" }, effect = "+3%, 7%, then 10% damage" } },
        ["Improved Scorpid Sting"] = { tree = "Marksmanship", tier = 5, max = 3, affects = { "Scorpid Sting" }, effect = "also reduces the target's stamina by up to 30% of the strength taken", client = "era" },
        ["Ranged Weapon Specialization"] = { tree = "Marksmanship", tier = 6, max = 5, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot" }, effect = "up to +5% ranged weapon damage" },
        ["Trueshot Aura"] = { tree = "Marksmanship", tier = 7, max = 1, affects = { "Trueshot Aura", "party" }, effect = "grants Trueshot Aura: +100 attack power for the party",
            forever = { tier = 4, effect = "grants Trueshot Aura's first rank: +30 ranged attack power for the party; the trainer has the rest" } },
        ["Improved Stings"] = { tree = "Marksmanship", tier = 4, max = 5, affects = { "Serpent Sting", "Wyvern Sting", "Viper Sting" }, effect = "TBC: up to +30% Serpent and Wyvern Sting damage and Viper Sting drain", expansion = "tbc",
            forever = { tier = 2, max = 3, affects = { "Serpent Sting", "Viper Sting", "Scorpid Sting" },
                effect = "Serpent Sting +6%, 13%, then 20% damage; Viper Sting -2s cooldown and Scorpid Sting +15s duration per rank" } },
        ["Go for the Throat"] = { tree = "Marksmanship", tier = 3, max = 2, affects = { "pet" }, effect = "TBC: your ranged crits give the pet focus", expansion = "tbc", client = "era" },
        ["Rapid Killing"] = { tree = "Marksmanship", tier = 3, max = 2, affects = { "Rapid Fire" }, effect = "TBC: -1 minute cooldown per rank; kills grant a damage bonus to the next shot", expansion = "tbc",
            forever = { effect = "Rapid Fire -1 minute cooldown per rank; a kill, or a death under your Serpent Sting, gives the next shot within 20s +10% damage per rank" } },
        ["Concussive Barrage"] = { tree = "Marksmanship", tier = 5, max = 3, affects = { "Auto Shot" }, effect = "TBC: Auto Shots have up to a 6% chance to daze for 4s", expansion = "tbc", client = "era" },
        ["Combat Experience"] = { tree = "Marksmanship", tier = 6, max = 2, affects = { "self" }, effect = "TBC: +agility and +intellect", expansion = "tbc", client = "era" },
        ["Careful Aim"] = { tree = "Marksmanship", tier = 7, max = 3, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot" }, effect = "TBC: intellect adds to ranged attack power", expansion = "tbc",
            forever = { tier = 2, max = 5, effect = "+20% of your intellect as attack power per rank (100% at 5)" } },
        ["Master Marksman"] = { tree = "Marksmanship", tier = 8, max = 5, affects = { "Auto Shot", "Aimed Shot", "Multi-Shot", "Steady Shot" }, effect = "TBC: up to +10% ranged attack power", expansion = "tbc", client = "era" },
        ["Silencing Shot"] = { tree = "Marksmanship", tier = 9, max = 1, affects = { "Silencing Shot" }, effect = "TBC: grants Silencing Shot", expansion = "tbc", client = "era" },
        ["Lethal Attacks"] = { tree = "Marksmanship", tier = 1, max = 5, affects = { "damage" }, effect = "+1% crit per rank with every attack", client = "forever" },
        ["Lone Wolf"] = { tree = "Marksmanship", tier = 3, max = 1, affects = { "damage" }, effect = "+20% damage with every attack while you have no pet out", client = "forever" },
        ["Rapid Recuperation"] = { tree = "Marksmanship", tier = 5, max = 2, affects = { "Serpent Sting", "mana" }, client = "forever",
            effect = "for 15s after a Serpent Sting hits, 25% of your mana regeneration per rank goes on while casting; 50% per rank after Rapid Killing is spent" },
        ["Sniper Shot"] = { tree = "Marksmanship", tier = 7, max = 1, affects = { "Sniper Shot" }, effect = "grants Sniper Shot", client = "forever" },

        -- Survival
        ["Monster Slaying"] = { tree = "Survival", tier = 1, max = 3, affects = { "damage" }, effect = "up to +3% damage and crit damage against beasts, giants and dragonkin", client = "era" },
        ["Humanoid Slaying"] = { tree = "Survival", tier = 1, max = 3, affects = { "damage" }, effect = "up to +3% damage and crit damage against humanoids", client = "era" },
        ["Deflection"] = { tree = "Survival", tier = 1, max = 5, affects = { "Counterattack" }, effect = "up to +5% parry, which is what makes Counterattack available" },
        ["Entrapment"] = { tree = "Survival", tier = 2, max = 5, affects = { "Frost Trap", "Immolation Trap", "Explosive Trap" }, effect = "traps have up to a 25% chance to root for 5s",
            forever = { affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap" }, effect = "whatever a trap catches is rooted for 1s per rank (5s at 5)" } },
        ["Savage Strikes"] = { tree = "Survival", tier = 2, max = 2, affects = { "Raptor Strike", "Mongoose Bite" }, effect = "+10% crit per rank",
            forever = { affects = { "Raptor Strike", "Mongoose Bite", "Strider Kick", "Counterattack", "Wing Clip", "Lacerate" }, effect = "+2% crit per rank with every melee ability" } },
        ["Improved Wing Clip"] = { tree = "Survival", tier = 2, max = 5, affects = { "Wing Clip" }, effect = "up to a 20% chance to root for 5s",
            forever = { max = 3, effect = "a 7%, 13%, then 20% chance to immobilize for 5s" } },
        ["Clever Traps"] = { tree = "Survival", tier = 3, max = 2, affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap" }, effect = "+15% Freezing and Frost Trap duration and +15% Immolation and Explosive Trap damage per rank" },
        ["Survivalist"] = { tree = "Survival", tier = 3, max = 5, affects = { "self" }, effect = "up to +10% health",
            forever = { tier = 2 } },
        ["Deterrence"] = { tree = "Survival", tier = 3, max = 1, affects = { "Deterrence" }, effect = "grants Deterrence" },
        ["Trap Mastery"] = { tree = "Survival", tier = 4, max = 2, affects = { "Freezing Trap", "Immolation Trap", "Explosive Trap" }, effect = "-5% resist chance per rank", client = "era" },
        ["Surefooted"] = { tree = "Survival", tier = 4, max = 3, affects = { "self" }, effect = "+1% hit per rank and up to 15% resistance to movement-impairing effects",
            forever = { tier = 3, effect = "+1% hit per rank, and movement-impairing effects on you last 10% less per rank" } },
        ["Improved Feign Death"] = { tree = "Survival", tier = 4, max = 2, affects = { "Feign Death" }, effect = "-2% resist chance per rank", client = "era" },
        ["Killer Instinct"] = { tree = "Survival", tier = 5, max = 3, affects = { "damage" }, effect = "+1% crit per rank with everything", client = "era" },
        ["Counterattack"] = { tree = "Survival", tier = 5, max = 1, affects = { "Counterattack" }, effect = "grants Counterattack",
            forever = { tier = 4 } },
        -- Forever has two Lightning Reflexes nodes, both tier 6: one on the
        -- canvas at 2% per rank, one off it (x 102800) at 3%. The talent scan
        -- keeps the higher rank of the two; this describes the one on the
        -- canvas.
        ["Lightning Reflexes"] = { tree = "Survival", tier = 6, max = 5, affects = { "self" }, effect = "up to +15% agility",
            forever = { effect = "+2% agility per rank (10% at 5)" } },
        ["Wyvern Sting"] = { tree = "Survival", tier = 7, max = 1, affects = { "Wyvern Sting" }, effect = "grants Wyvern Sting", client = "era" },
        ["Survival Instincts"] = { tree = "Survival", tier = 5, max = 2, affects = { "damage" }, effect = "TBC: +2% attack power per rank, -2% damage taken", expansion = "tbc", client = "era" },
        ["Resourcefulness"] = { tree = "Survival", tier = 6, max = 3, affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Snake Trap" }, effect = "TBC: traps and melee cost less and cool down faster", expansion = "tbc",
            forever = { tier = 5, max = 2,
                affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Raptor Strike", "Mongoose Bite", "Counterattack", "Wing Clip", "mana" },
                effect = "traps and melee abilities -30% mana per rank; crits have a 50% chance per rank to let 50% of your mana regeneration go on while casting for 30s" } },
        ["Expose Weakness"] = { tree = "Survival", tier = 7, max = 3, affects = { "party" }, effect = "TBC: your ranged crits give the party attack power equal to a share of your agility", expansion = "tbc", client = "era" },
        ["Thrill of the Hunt"] = { tree = "Survival", tier = 7, max = 3, affects = { "Aimed Shot", "Multi-Shot", "Arcane Shot", "Steady Shot" }, effect = "TBC: a crit has up to a 100% chance to refund 40% of the shot's mana", expansion = "tbc", client = "era" },
        ["Master Tactician"] = { tree = "Survival", tier = 8, max = 5, affects = { "damage" }, effect = "TBC: hits have a chance to grant up to +10% crit", expansion = "tbc", client = "era" },
        ["Readiness"] = { tree = "Survival", tier = 9, max = 1, affects = { "Readiness" }, effect = "TBC: grants Readiness", expansion = "tbc", client = "era" },
        ["Improved Tracking"] = { tree = "Survival", tier = 1, max = 5, client = "forever",
            affects = { "damage", "Track Beasts", "Track Demons", "Track Dragonkin", "Track Elementals", "Track Giants", "Track Humanoids", "Track Undead" },
            effect = "+1% damage per rank (5% at 5) against the creature type you are tracking" },
        ["Survival Tactics"] = { tree = "Survival", tier = 4, max = 2, affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Feign Death" }, client = "forever",
            effect = "traps and Feign Death +5% chance to hit per rank: resisted less often" },
        ["Predator's Edge"] = { tree = "Survival", tier = 4, max = 5, affects = { "Raptor Strike", "Mongoose Bite", "Strider Kick", "Counterattack", "Wing Clip", "Lacerate", "damage" }, client = "forever",
            effect = "melee crits +6% damage per rank (30% at 5), and off-hand weapon damage +10% per rank" },
        ["Expose Prey"] = { tree = "Survival", tier = 5, max = 2, affects = { "Hunter's Mark", "Mongoose Bite" }, client = "forever",
            effect = "your attacks on a target under your Hunter's Mark have a 5% chance per rank to make Mongoose Bite usable for 10s" },
        ["Survivalist's Discipline"] = { tree = "Survival", tier = 5, max = 2, affects = { "Freezing Trap", "Frost Trap", "Immolation Trap", "Explosive Trap", "Deterrence" }, client = "forever",
            effect = "traps and Deterrence -20% cooldown per rank" },
        ["Strider Kick"] = { tree = "Survival", tier = 5, max = 1, affects = { "Strider Kick" }, effect = "grants Strider Kick", client = "forever" },
        ["Lacerating Strikes"] = { tree = "Survival", tier = 7, max = 1, affects = { "Mongoose Bite" }, effect = "Mongoose Bite also makes the target bleed for 40% of its damage over 21s", client = "forever" },
    },

    -- --- combos: what only exists between abilities --------------------------

    combos = {
        {
            name = "The pull",
            uses = { "Hunter's Mark", "Aimed Shot", "Auto Shot", "Serpent Sting" },
            how = "Mark, then Aimed Shot while the mob walks in, then Auto Shot starts and the sting goes up. "
                .. "Aimed Shot first because it resets the swing timer and there is no swing yet to reset.",
        },
        {
            name = "Shot weaving",
            uses = { "Auto Shot", "Multi-Shot", "Aimed Shot", "Steady Shot" },
            how = "Every cast shot either resets the swing (Aimed Shot) or clips it if it lands during the aim "
                .. "(Multi-Shot, Steady Shot). Fire them the moment an Auto Shot lands, never in the half-second before one.",
        },
        {
            name = "Kiting before the pet",
            uses = { "Concussive Shot", "Wing Clip", "Auto Shot", "Arcane Shot", "Serpent Sting" },
            how = "Stand only for the aim, run the rest of the swing. Concussive Shot at thirty yards buys the distance; "
                .. "Wing Clip if it reaches you, then back out past eight yards. Arcane Shot and Serpent Sting cast on the move.",
        },
        {
            name = "The dead zone escape",
            uses = { "Wing Clip", "Counterattack", "Scatter Shot", "Intimidation", "Raptor Strike" },
            how = "Inside eight yards nothing ranged works. Slow or root it -- Wing Clip, a Counterattack after a parry, "
                .. "Scatter Shot, the pet's Intimidation -- then step out and shoot. Raptor Strike only while stuck.",
        },
        {
            name = "The burst window",
            uses = { "Rapid Fire", "Bestial Wrath", "Intimidation", "Aimed Shot", "Multi-Shot" },
            how = "Intimidation to pin it, Bestial Wrath for the pet, Rapid Fire for you, then every shot. "
                .. "All three at once; a cooldown spent alone multiplies nothing.",
        },
        {
            name = "Trap chains",
            uses = { "Freezing Trap", "Scatter Shot", "Feign Death", "Frost Trap" },
            how = "Classic traps cannot be laid in combat, so Feign Death first, trap, stand. Scatter Shot walks a mob "
                .. "onto a Freezing Trap. Frost Trap is the one trap damage does not break -- lay it and kite through it.",
        },
        {
            name = "Stings do not stack",
            uses = { "Serpent Sting", "Viper Sting", "Scorpid Sting", "Wyvern Sting" },
            how = "One sting per target. Serpent for damage, Viper for a caster's mana, Scorpid for a mob the pet is "
                .. "holding for a while, Wyvern to sleep it. Applying one removes the last.",
        },
        {
            name = "The pet as the tank",
            uses = { "Mend Pet", "Intimidation", "Distracting Shot", "Feign Death", "Disengage" },
            how = "The pet holds the mob; you shoot. Mend Pet when it is losing. If the mob comes for you: Intimidation "
                .. "hands it back with threat, Feign Death drops it entirely, Disengage pushes it off in melee.",
        },
        {
            name = "Aspects are a choice",
            uses = { "Aspect of the Hawk", "Aspect of the Monkey", "Aspect of the Cheetah" },
            how = "Hawk to shoot, Monkey when stuck in melee for more than a few swings, Cheetah only between fights. "
                .. "Each swap costs a global. Never Cheetah into a fight: one hit dazes you.",
        },
        {
            name = "Crowd control breaks on damage",
            uses = { "Freezing Trap", "Scatter Shot", "Wyvern Sting", "Scare Beast", "Multi-Shot", "Serpent Sting" },
            how = "Everything the hunter uses to stop a mob ends the moment it takes damage -- your dot, your pet, the "
                .. "extra targets of a Multi-Shot. Control one mob only when nothing of yours will touch it.",
        },
    },
}

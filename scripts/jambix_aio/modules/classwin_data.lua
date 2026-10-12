-- Jambix AIO / classwin_data -- what each class's window holds (1.62.0).
--
-- One entry per class (by the client's class file name). Each holds groups;
-- modules/classwin.lua explains the three kinds. Only trained spells get a
-- row, so a level 10 sees what a level 10 has.
--
--   kind     "pick" one of the set, "keep" each on or off, "form" a stance or
--            form held by the rotation's form keeper (forms.lua)
--   auto     the group offers "Auto" -- the rotation decides, as before -- and
--            starts on it. Without it the group starts on "None".
--   combat   false: only cast out of combat (the rotation's rules for these
--            were out of combat only). Per group, or per spell.
--   consumed true: it goes away by being used (a seal judged, a shield's
--            charges hit), so its going is never taken for a click-off.
--   default  for a "keep" spell: on where the rotation kept it up before.
--   fight    true: a buff for the fight itself, half a minute long (the
--            seal). While the rotation is paused it is kept only with
--            "Everything picked here" (1.7.5).
--
-- The defaults are what the rotation did before this window existed, so a
-- player who never opens it sees no change.

local function s(name, short, tip, extra)
    local row = { name = name, short = short or name, tip = tip }
    for k, v in pairs(extra or {}) do row[k] = v end
    return row
end

local DATA = {
    WARRIOR = {
        key = "warrior", label = "Warrior",
        groups = {
            { key = "stance", kind = "form", label = "Stance", auto = true,
              tip = "Auto: the stance the rotation's profile wants. A stance picked here is held instead.",
              spells = {
                s("Battle Stance", "Battle"),
                s("Defensive Stance", "Defensive"),
                s("Berserker Stance", "Berserker"),
              } },
            { key = "warrior_keep", kind = "keep", label = "Keep up",
              spells = {
                s("Battle Shout", nil, "Refreshed before it runs out, in combat too.", { default = true, refresh = 10 }),
              } },
        },
    },

    PALADIN = {
        key = "paladin", label = "Paladin",
        groups = {
            { key = "aura", kind = "pick", label = "Aura", auto = true,
              tip = "Auto: the profile's aura (Devotion while levelling and tanking, Retribution or Sanctity for Retribution), only where none is up.",
              spells = {
                s("Devotion Aura", "Devotion"),
                s("Retribution Aura", "Retribution"),
                s("Concentration Aura", "Concentration"),
                s("Sanctity Aura", "Sanctity"),
                s("Shadow Resistance Aura", "Shadow resistance"),
                s("Frost Resistance Aura", "Frost resistance"),
                s("Fire Resistance Aura", "Fire resistance"),
              } },
            { key = "seal", kind = "pick", label = "Seal", auto = true, consumed = true,
              fight = true,
              tip = "Auto: the profile's seal. A seal picked here is put back after every Judgement. While the rotation is paused, only with Everything picked here.",
              spells = {
                s("Seal of Righteousness", "Righteousness"),
                s("Seal of Command", "Command"),
                s("Seal of Fury", "Fury"),
                s("Seal of the Crusader", "Crusader"),
                s("Seal of Light", "Light"),
                s("Seal of Wisdom", "Wisdom"),
                s("Seal of Justice", "Justice"),
              } },
            { key = "blessing", kind = "pick", label = "Blessing on you", auto = true, combat = false,
              tip = "Out of combat. Auto: the profile's blessing.",
              spells = {
                s("Blessing of Might", "Might"),
                s("Blessing of Wisdom", "Wisdom"),
                s("Blessing of Kings", "Kings"),
                s("Blessing of Sanctuary", "Sanctuary"),
                s("Blessing of Salvation", "Salvation"),
                s("Blessing of Light", "Light"),
              } },
            { key = "fury", kind = "pick", label = "Righteous Fury", auto = true,
              tip = "Auto: on for the protection profile.",
              spells = { s("Righteous Fury", "On") } },
        },
    },

    HUNTER = {
        key = "hunter", label = "Hunter",
        aspects = true,             -- modules/aspects.lua's switches, at the top
        groups = {
            { key = "hunter_keep", kind = "keep", label = "Keep up",
              spells = {
                s("Trueshot Aura", nil, "Attack power for you and your party.", { default = false }),
              } },
        },
    },

    ROGUE = {
        key = "rogue", label = "Rogue",
        groups = {},
    },

    PRIEST = {
        key = "priest", label = "Priest",
        groups = {
            { key = "priest_keep", kind = "keep", label = "Keep up",
              spells = {
                s("Power Word: Fortitude", "Fortitude", "Out of combat.", { default = true, combat = false }),
                s("Inner Fire", nil, "In combat too.", { default = true, consumed = true }),
                s("Shadow Protection", nil, "Out of combat.", { default = false, combat = false }),
              } },
            { key = "shadowform", kind = "pick", label = "Shadowform", auto = true, combat = false,
              tip = "Auto: on for the shadow profile, out of combat.",
              spells = { s("Shadowform", "On") } },
        },
    },

    SHAMAN = {
        key = "shaman", label = "Shaman",
        groups = {
            { key = "shield", kind = "pick", label = "Shield", auto = true, consumed = true,
              tip = "Auto: Lightning Shield, or Water Shield for the casters, as the profiles did.",
              spells = {
                s("Lightning Shield", "Lightning"),
                s("Water Shield", "Water"),
              } },
        },
    },

    MAGE = {
        key = "mage", label = "Mage",
        groups = {
            { key = "armor", kind = "pick", label = "Armor", auto = true, combat = false,
              tip = "Out of combat. Auto: the profile's armor.",
              spells = {
                s("Frost Armor", "Frost"),
                s("Ice Armor", "Ice"),
                s("Mage Armor", "Mage"),
                s("Molten Armor", "Molten"),
              } },
            { key = "mage_keep", kind = "keep", label = "Keep up",
              spells = {
                s("Arcane Intellect", nil, "Out of combat.", { default = true, combat = false }),
              } },
        },
    },

    WARLOCK = {
        key = "warlock", label = "Warlock",
        groups = {
            { key = "armor", kind = "pick", label = "Armor", auto = true, combat = false,
              tip = "Out of combat. Auto: Demon Armor, else Demon Skin.",
              spells = {
                s("Demon Skin", "Demon Skin"),
                s("Demon Armor", "Demon Armor"),
                s("Fel Armor", "Fel Armor"),
              } },
        },
    },

    DRUID = {
        key = "druid", label = "Druid",
        groups = {
            { key = "form", kind = "form", label = "Form", auto = true,
              tip = "Auto: the form the rotation's profile wants. A form picked here is held instead.",
              spells = {
                s("Bear Form", "Bear"),
                s("Dire Bear Form", "Dire Bear"),
                s("Cat Form", "Cat"),
                s("Moonkin Form", "Moonkin"),
                s("Tree of Life", "Tree of Life"),
              } },
            { key = "druid_keep", kind = "keep", label = "Keep up",
              spells = {
                s("Mark of the Wild", nil, "Out of combat.", { default = true, combat = false }),
                s("Thorns", nil, "Out of combat.", { default = true, combat = false }),
                s("Omen of Clarity", nil, "Out of combat.", { default = false, combat = false }),
              } },
        },
    },
}

-- OPTIONS (1.63.0): the class's settings, in its window. The values are the
-- menu's, the same ids the Rotation page declares: the window reads them with
-- P.opt and writes them to that page, so the two always agree.
--   common  the shared ones, shown when the rotation's class module has the flag
--           (no flag: every class)
--   <CLASS> that class's own ("<Class> options" on the Rotation page)
local function toggle(id, label, default, tip) return { kind = "toggle", id = id, label = label, default = default, tip = tip } end
local function slider(id, label, lo, hi, default) return { kind = "slider", id = id, label = label, min = lo, max = hi, default = default } end
local function dropdown(id, label, items, default, tip) return { kind = "dropdown", id = id, label = label, items = items, default = default, tip = tip } end
local function button(id, label) return { kind = "button", id = id, label = label } end
-- A live line from a module (classwin.lua NOTES), not a setting.
local function note(id) return { kind = "note", id = id } end

DATA.OPTIONS = {
    common = {
        { flag = "tank_capable", label = "Threat", rows = {
            toggle("rot_hold_aggro", "Reclaim loose enemies", true),
            slider("rot_challenging_shout_count", "Mass taunt at", 2, 8, 3),
            dropdown("rot_aggro_scope", "Reclaim aggro in", { "Solo only", "Solo and open-world groups",
                "Everywhere except raids", "Everywhere" }, 2),
        } },
        { flag = "uses_forms", label = "Stances and forms", rows = {
            toggle("rot_allow_dance", "Allow switching mid-fight", false),
        } },
        { flag = "wand_capable", label = "Wand", rows = {
            toggle("rot_use_wand", "Use the wand", true),
        } },
        { flag = "heal_capable", label = "Healing", rows = {
            slider("rot_heal_range", "Heal range (yd)", 20, 40, 40),
            slider("rot_heal_renew_hp", "Heal-over-time below %", 50, 100, 85),
            slider("rot_heal_flash_hp", "Fast heal below %", 20, 90, 50),
            slider("rot_heal_big_hp", "Big heal below %", 10, 80, 40),
            slider("rot_heal_shield_hp", "Shield below %", 20, 100, 70),
            toggle("rot_heal_dps", "Damage when nobody is hurt", true),
        } },
        { flag = "pet_capable", label = "Pet", rows = {
            dropdown("pet_mode", "Pet mode", { "Off", "Assist my target", "Tank loose enemies", "Focus one unit" }, 2),
            button("pet_focus_target", "Focus my current target"),
            button("pet_focus_clear", "Clear pet focus"),
        } },
        -- Every class's (1.70.0): the tank's target, followed (modules/assist.lua).
        { label = "Group", rows = {
            toggle("rot_assist_tank", "Assist the tank", false,
                "In a group, playing damage: your target is the tank's, and changes when the tank's does. The tank pulls."),
            note("assist"),
        } },
        -- Every class's (1.7.5): what the window keeps up with the rotation
        -- paused or off. The menu declares it in the Class window section.
        { label = "While the rotation is paused", rows = {
            dropdown("classwin_paused", "Keep up", { "Out-of-combat buffs", "Everything picked here", "Nothing" }, 1,
                "What this window keeps up while the rotation is paused or off. Out-of-combat buffs: armors, auras, blessings, Fortitude and the like, out of combat only; never a seal, a stance or a form, and nothing in a fight. Everything picked here: as before 1.7.5, but a stance or form you take yourself is left alone. Nothing: the window waits for the rotation. What nobody picked waits for the rotation either way."),
        } },
    },
    HUNTER = {
        toggle("rot_hunter_kite", "Run and shoot before there is a pet", false),
        toggle("rot_hunter_step_out", "Step out of melee once clipped", true,
            "Not in Beast Mastery once you have a pet (1.8.1): its melee weave is yours to walk in and out of, and a step out would undo the walk in."),
        -- 1.84.0
        dropdown("rot_hunter_mark_on", "Hunter's Mark on",
            { "Every target", "Elites and bosses", "Bosses only", "Never" }, 1,
            "Bosses only: dungeon and raid bosses, by the client's own boss flag. Era has no such flag and reads its dungeon bosses as elites: take Elites and bosses there."),
        dropdown("rot_hunter_sting_spread", "Serpent Sting on",
            { "My target only", "Up to 2 mobs", "Up to 3 mobs", "Every mob fighting you" }, 4,
            "With more than one mob on you, the sting goes on each in turn, as long as it will live long enough for the sting to pay. Straight onto each mob: your target, Auto Shot and the pet stay where they are. Never a mob held by crowd control (a sheep, a sap, your trap)."),
        -- 1.8.1: Disengage, when a mob hits you (react/rules/hunter.lua).
        toggle("rot_hunter_disengage", "Disengage when a mob hits you", false,
            "A mob hitting you in melee that your pet is fighting (in a group, the tank's) is handed back with Disengage. On Forever, as on Era, Disengage is a threat drop in melee range (5 s cooldown), not a leap: with nobody else on the mob it would do nothing, so then it waits. A reaction: it needs Reactions on (the Reactions page). Off: nothing ever presses Disengage for you, not the threat reaction and not the escapes."),
        -- 1.7.4
        dropdown("rot_hunter_mana_use", "Mana for extra shots",
            { "Spend freely", "Balanced", "Save for regen" }, 2,
            "Every special stops mana regeneration for five seconds. Balanced: under half a bar only the essentials go out (the opener, the mark, a sting on a long fight, one hawk, Multi-Shot on a pack) until spirit has the bar back to 80%, and the fillers (Multi-Shot on one mob, Arcane Shot) only above 80%. Save for regen: the same from 70% to 95%. Spend freely: as before 1.7.4."),
        -- 1.8.1: the AOE melee weave is Beast Mastery's (no switch). The line
        -- says which side of the weave you stand on and what that side does.
        note("hunter_weave"),
        -- 1.7.6: the PvP hunter (modules/pvphunter.lua). The line under it
        -- says whether PvP mode is on, what it faces and what it last did.
        toggle("rot_hunter_pvp_alpha", "PvP hunter (ALPHA/TEST)", false,
            "ALPHA/TEST: not yet tried in game. No Forever PvP guide exists yet, so this follows the Classic hunter PvP guides with Forever's changes. While your target is an enemy player, or one is on you or your pet, or you are in a battleground with one near: the PvP rotation and its reactions run. Concussive Shot on melee coming at you, Wing Clip when they reach you, then Freezing Trap at your feet, Scatter Shot, Intimidation or Deterrence when the clip does not shake them; the kite walks you out, and from a frozen player on to range for an Aimed Shot opener (with Rapid Fire). Viper Sting on casters (36+), Scorpid Sting on melee players and hunters (22+: less chance to hit you), Serpent Sting on the rest; Multi-Shot only with two or more enemies where it lands; Feign Death into a Polymorph, Fear or big bolt; a switch to a player who attacks you. Fights are still yours to start: the plugin never opens on a player by itself."),
        note("hunter_pvp"),
    },
    ROGUE = {
        dropdown("rot_rogue_stealth_mode", "Stealth by itself",
            { "Never", "Only before an opener", "Before an opener and near enemies" }, 2),
    },
    WARLOCK = {
        toggle("rot_warlock_make_healthstone", "Keep a Healthstone in the bags", true),
        toggle("rot_warlock_soulstone", "Keep a Soulstone, and wear it", true),
        toggle("rot_warlock_shard_dump", "Keep soul shards under a limit", true,
            "At the limit Drain Soul stops making more (only Improved Drain Soul's mana refund while mana is short, and Soul Harvest's kills, still cast it). In a fight a shard over the limit is destroyed at once; out of combat a spare becomes a Spellstone or a Firestone first."),
        slider("rot_warlock_shard_cap", "Soul shards to keep", 4, 32, 20),
    },
}

return DATA

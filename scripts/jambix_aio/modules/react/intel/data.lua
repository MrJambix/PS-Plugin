-- Jambix AIO / react / intel / data -- what each class can do to you, as far
-- as this plugin has verified it (PvP intelligence, Stage 2).
--
-- EVERY TABLE SAYS WHERE IT CAME FROM. Nothing here is a spell id or a
-- cooldown: those are Stage 3's, generated from the installed clients'
-- tables (tools/jcheck). What is here is names and reaches the plugin
-- already relies on:
--   * CONTROLS: the stuns, fears, incapacitates and roots a class throws at
--     a player, with the yards they reach from the caster. The names and
--     reaches are the ones react/rules/pvp.lua's STOPPERS and ANSWERS use
--     (1.81.0, checked against the Era 1.15.9 client's tables). Forever's
--     kits were not checked against this (README, PvP on Classic Era).
--   * MOBILITY: the gap closers and sprints, by name, seen as a cast event or
--     as the buff they leave. Charge's 8-25 yd and Intercept's 25 are the
--     Classic tooltip figures (Intercept's is in rules/pvp.lua); the rest
--     carry no reach, because none was read from a client table.
--   * PROTECTION: what a buff on US covers, so a threat already answered is
--     not scored as if it were not. The immune and avoid rows are
--     react/pvp.lua's ENEMY table (the same auras, on us); the absorbs and
--     reductions are the names rules/pvp.lua's ANSWERS already press.
--
-- A later stage that needs more than names (ranges from SpellRange, the
-- Forever kits) adds it to pvp_data.lua, generated, and this file reads it.

local D = {}

D.SOURCE = {
    CONTROLS = "react/rules/pvp.lua STOPPERS and ANSWERS (Era 1.15.9 tables, 1.81.0); Forever unchecked",
    MOBILITY = "names only; Charge and Intercept reach from the Classic tooltip (Intercept's also in rules/pvp.lua)",
    PROTECTION = "react/pvp.lua ENEMY (immune, avoid) and rules/pvp.lua ANSWERS (absorb, reduce)",
}

--- A control a class throws at a player: `reach` yards from the caster
--- (`from`: not closer than), `kind` the mechanic (pvp.lua's words),
--- `around` when it goes off around the caster.
D.CONTROLS = {
    WARRIOR = {
        { name = "Concussion Blow", reach = 5, kind = "stun" },
        { name = "Intercept", reach = 25, from = 8, kind = "stun" },
        { name = "Intimidating Shout", reach = 10, kind = "fear", around = true },
        { name = "Disarm", reach = 5, kind = "disarm" },
    },
    ROGUE = {
        { name = "Kidney Shot", reach = 5, kind = "stun" },
        { name = "Gouge", reach = 5, kind = "knockout" },
        { name = "Blind", reach = 10, kind = "disorient" },
    },
    PRIEST = {
        { name = "Psychic Scream", reach = 8, kind = "fear", around = true },
    },
    WARLOCK = {
        { name = "Death Coil", reach = 30, kind = "horror" },
        { name = "Howl of Terror", reach = 10, kind = "fear", around = true },
        { name = "Fear", reach = 20, kind = "fear" },
    },
    MAGE = {
        { name = "Frost Nova", reach = 10, kind = "root", around = true },
        { name = "Polymorph", reach = 30, kind = "polymorph" },
    },
    PALADIN = {
        { name = "Hammer of Justice", reach = 10, kind = "stun" },
    },
    DRUID = {
        { name = "Bash", reach = 5, kind = "stun" },
        { name = "Entangling Roots", reach = 30, kind = "root" },
    },
    HUNTER = {
        { name = "Scatter Shot", reach = 15, kind = "disorient" },
        { name = "Concussive Shot", reach = 35, kind = "snare" },
        { name = "Wing Clip", reach = 5, kind = "snare" },
    },
    SHAMAN = {
        { name = "Frost Shock", reach = 20, kind = "snare" },
        { name = "Earthbind Totem", reach = 10, kind = "snare", around = true },
    },
}

--- The mechanics that take you out of the fight (pvp.lua's HELPLESS, by
--- the same words), weighed heavier than a snare.
D.CONTROL_WEIGHT = {
    stun = 1.0, fear = 1.0, horror = 1.0, polymorph = 0.9, knockout = 0.9, disorient = 0.9,
    sleep = 0.9, charm = 1.0, root = 0.5, snare = 0.3, disarm = 0.4, silence = 0.5,
}

--- Gap closers and sprints: a player using one has committed to reaching
--- you (or leaving). Seen as a cast event, or as the buff it leaves.
--- `out_of_combat`: the Classic tooltip's "Cannot be used in combat"
--- (Charge): against a player already fighting, it is not a reach. Whether
--- Forever lifts that is UNKNOWN; the Classic rule is kept.
D.MOBILITY = {
    ["Charge"] = { reach = 25, from = 8, closes = true, out_of_combat = true },
    ["Intercept"] = { reach = 25, from = 8, closes = true },
    ["Feral Charge"] = { closes = true },
    ["Blink"] = { closes = false },
    ["Sprint"] = { closes = true },
    ["Dash"] = { closes = true },
    ["Shadowstep"] = { closes = true },     -- not in Classic Era; harmless if never seen
}

--- What a buff on us covers: "all" (nothing lands), "physical" (no melee or
--- ranged weapon damage), "melee" (dodged), "absorb" (a shield), "reduce"
--- (less damage), "fear" (immune to fear).
D.PROTECTION = {
    ["Divine Shield"] = "all", ["Divine Protection"] = "all", ["Ice Block"] = "all",
    ["Blessing of Protection"] = "physical", ["Deterrence"] = "physical", ["Evasion"] = "melee",
    ["Power Word: Shield"] = "absorb", ["Ice Barrier"] = "absorb",
    ["Shield Wall"] = "reduce", ["Barkskin"] = "reduce",
    ["Berserker Rage"] = "fear", ["Fear Ward"] = "fear",
}

--- What a protection answers: the burst kinds pvp.lua names ("physical",
--- "spell") and the damage of a melee player.
D.COVERS = {
    all = { physical = 1.0, spell = 1.0, melee = 1.0 },
    physical = { physical = 0.85, spell = 0.0, melee = 0.85 },
    melee = { physical = 0.5, spell = 0.0, melee = 0.75 },
    absorb = { physical = 0.35, spell = 0.35, melee = 0.35 },
    reduce = { physical = 0.3, spell = 0.3, melee = 0.3 },
    fear = { physical = 0.0, spell = 0.0, melee = 0.0 },
}

-- --- the control plan (Stage 6) ------------------------------------------------------

D.SOURCE.DR_ERA = "DRList-1.0's Classic Era list by name (carried by pvpx.lua until 2026-10-11, each name checked against the Era 1.15.9 client); the multiplier rule 1, 1/2, 1/4, immune and the 18 s window are DRList's"
D.SOURCE.DR_FOREVER = "SpellCategories.DiminishType in the Forever 1.60.1.70338 client (pvp_data.lua, generated): which spells share each id is read off that table; what each id does in play is UNVERIFIED"
D.SOURCE.BREAKERS = "react/rules/pvp.lua BREAKERS (1.81.0): what a class presses to break a control on itself"
D.SOURCE.OUR_DOTS = "rules/hunter_pvp.lua trap_first: the hunter's own ticks that break a trap (Viper Sting's drain too, Wowhead's Classic dueling guide)"

--- Classic Era's diminishing-returns categories, by the debuff's name. The
--- categories are Era's, not the mechanics: Kidney Shot alone; the stuns you
--- aim share one, the stuns that proc another; Polymorph, Sap, Gouge,
--- Scatter Shot, the trap, Wyvern Sting, Hibernate and Repentance share
--- one; Blind, Death Coil, the silences and the disarms have none.
D.DR_ERA = {}
do
    local lists = {
        stun = { "Bash", "Pounce", "Intimidation", "Deep Freeze", "Hammer of Justice", "Cheap Shot",
                 "Concussion Blow", "Intercept Stun", "Charge Stun", "War Stomp", "Iron Grenade",
                 "Thorium Grenade", "M73 Frag Grenade", "Big Iron Bomb", "Hi-Explosive Bomb",
                 "Rough Copper Bomb", "Mithril Frag Bomb", "Dark Iron Bomb", "Big Bronze Bomb",
                 "Small Bronze Bomb", "Large Copper Bomb", "Goblin Mortar", "Tidal Charm", "The Big One" },
        random_stun = { "Starfire Stun", "Improved Concussive Shot", "Impact", "Stun", "Blackout", "Pyroclasm",
                 "Revenge Stun", "Mace Stun Effect", "Stunning Blow", "Earthshaker" },
        kidney_shot = { "Kidney Shot", "Between the Eyes" },
        incapacitate = { "Hibernate", "Freezing Trap Effect", "Freezing Trap", "Scatter Shot", "Wyvern Sting",
                 "Polymorph", "Polymorph: Pig", "Polymorph: Turtle", "Repentance", "Gouge", "Sap", "Sleep",
                 "Reckless Charge", "Glimpse of Madness" },
        fear = { "Scare Beast", "Psychic Scream", "Fear", "Howl of Terror", "Seduction", "Intimidating Shout",
                 "Flash Bomb" },
        root = { "Entangling Roots", "Counterattack", "Frost Nova" },
        random_root = { "Improved Wing Clip", "Improved Hamstring", "Freeze" },
        mind_control = { "Mind Control", "Gnomish Mind Control Cap" },
        frost_shock = { "Frost Shock" },
    }
    for cat, names in pairs(lists) do
        for i = 1, #names do D.DR_ERA[names[i]] = cat end
    end
end

--- Forever's DiminishType ids, named by which spells carry each in the
--- extracted table: 1 Entangling Roots and Frost Nova; 4 Bash, Pounce,
--- Hammer of Justice, Intimidation, War Stomp, Cheap Shot, Concussion Blow;
--- 8 Mind Control; 16 Hibernate, Scatter Shot, Polymorph, Repentance,
--- Gouge, Sap, Shackle Undead, Banish; 32 the fears, Seduction, Turn
--- Undead; 64 Silence; 128 Kidney Shot; 256 Distract.
D.DR_FOREVER_TYPES = {
    [1] = "root", [4] = "stun", [8] = "mind_control", [16] = "incapacitate", [32] = "fear",
    [64] = "silence", [128] = "kidney_shot", [256] = "distract",
}

D.DR_LABEL = {
    stun = "Stun", random_stun = "Proc stun", kidney_shot = "Kidney Shot", incapacitate = "Incapacitate",
    fear = "Fear", root = "Root", random_root = "Proc root", mind_control = "Mind Control",
    frost_shock = "Frost Shock", silence = "Silence", distract = "Distract",
}

--- What a class presses to break a control on itself, with the mechanics
--- it answers (`magic`: anything Magic, the felhunter's Devour). The
--- racials (Will of the Forsaken, Escape Artist) are not listed: the
--- player's race is not read.
D.BREAKERS = {
    WARRIOR = { { name = "Berserker Rage", mechs = { fear = true } } },
    MAGE = { { name = "Blink", mechs = { stun = true, root = true } } },
    PALADIN = { { name = "Blessing of Freedom", mechs = { root = true, snare = true } } },
    DRUID = { { name = "a shapeshift", mechs = { root = true, snare = true } } },
    WARLOCK = { { name = "Devour Magic", mechs = { magic = true } } },
}

--- The hunter's own damage over time: each tick breaks a trap, a Scatter
--- Shot or a Wyvern Sting on the same player.
D.OUR_DOTS = { ["Serpent Sting"] = true, ["Viper Sting"] = true, ["Immolation Trap Effect"] = true,
               ["Explosive Trap Effect"] = true }

-- --- opponent prediction (Stage 7) ---------------------------------------------------

D.SOURCE.PATTERNS = "the brief's Phase 6 list of tendencies; the consequence, response and fallback are this plugin's words for a hunter (Wowhead's Classic dueling guide for the trap and Scatter Shot answers)"
D.SOURCE.OUR_SLOW_CASTS = "the hunter's slows pressed as a cast (states.lua SLOWS lists the auras they leave)"
D.SOURCE.OUR_BURSTS = "the hunter's burst cooldowns (burst.lua)"
D.SOURCE.INTERRUPTS = "Classic Era's interrupts by name: the class catalogues' interrupt rows, the felhunter's Spell Lock, the priest's Silence, the druid's Feral Charge"

--- What a player tends to do, as the brief lists it. Each: `consequence`
--- what to expect (a %d for the health, a %s for the opener), `response`
--- what a hunter does about it, `fallback` when that is not there;
--- `chance` when the question is asked, `hit`, `miss`, `attribution` in
--- words (predict.lua does what they say); `needs` the inputs a MISS
--- rests on -- a miss is recorded only once those were seen live this
--- session (T.inputs), else the chance is "unverified"; `ability` the
--- player's ability the chance needs usable (the ledger: not "down").
D.PATTERNS = {
    { key = "mobility_when_slowed", consequence = "it closes the gap the moment it is slowed",
      response = "slow it with the trap or Scatter Shot ready, or step out right after the clip",
      fallback = "Feign Death when it reaches you",
      chance = "our Wing Clip or Concussive Shot lands on a player whose class has a gap closer not seen down",
      hit = "a gap closer cast or buff from it within 2 s", miss = "2 s pass without one",
      attribution = "its own cast or aura event (observed)",
      needs = { "enemy_events" }, ability = "CLASS_GAP_CLOSERS" },
    { key = "defensive_threshold", consequence = "a defensive at about %d%% health",
      response = "hold the burst until it is spent", fallback = "shoot another while it is up",
      chance = "in combat its health falls under 60% with a defensive of its class not seen down (one episode per fall)",
      hit = "a defensive buff appears (its health then is the measure)", miss = "it falls under 15%, dies or the fight ends without one",
      attribution = "its own aura event (observed)",
      needs = { "enemy_auras" }, ability = "CLASS_DEFENSIVES" },
    { key = "interrupts_casts", consequence = "it interrupts your casts",
      response = "bait its kick with a cheap cast, Aimed Shot after", fallback = "instant shots only while it is in reach",
      chance = "a cast of ours with a cast time, a player within its interrupt's reach with the interrupt not seen down",
      hit = "our cast interrupted", miss = "our cast went through",
      attribution = "the interrupt seen cast within 0.8 s (observed), else the player on us in reach (inferred, half weight)",
      needs = { "our_interrupted" }, ability = "CLASS_INTERRUPT" },
    { key = "escape_after_control", consequence = "it breaks a control at once (trinket or breaker)",
      response = "a cheap control first to draw the trinket, the real one after",
      fallback = "no second control until its trinket is down",
      chance = "a breakable control of ours lands while its trinket is not seen down or a breaker of its class is usable",
      hit = "its trinket seen used or a breaker cast within 1.5 s", miss = "1.5 s pass with the control on",
      attribution = "the trinket off its auras (polled, always live); a breaker off its cast events",
      needs = {}, ability = "BREAKERS" },
    { key = "over_committing", consequence = "it stacks its bursts",
      response = "survive the window: a defensive, line of sight, distance", fallback = "Feign Death",
      chance = "a burst buff starts on it", hit = "another starts within 10 s", miss = "10 s pass without",
      attribution = "its auras (polled by pvp.lua)", needs = {} },
    { key = "targeting_pet", consequence = "it goes for your pet",
      response = "Mend Pet early, Intimidation ready", fallback = "call the pet back",
      chance = "once a second in combat with the pet out, while it targets you or the pet (an ally is no sample)",
      hit = "it targets the pet", miss = "it targets you", attribution = "its target off the row (observed, half weight a sample)",
      needs = { "foe_target" } },
    { key = "same_opener", consequence = "it opens with %s",
      response = "answer the opener before it lands", fallback = "the usual opening",
      chance = "a fight with it begins and an earlier fight's opener is known", hit = "its first cast within 6 s is one seen before",
      miss = "a different first cast; none within 6 s is no answer", attribution = "its cast events (observed)",
      needs = { "enemy_casts" } },
    { key = "retreating_when_pressured", consequence = "it backs off under pressure",
      response = "press when it backs off: Concussive Shot, then range", fallback = "do not pursue past your allies",
      chance = "our Rapid Fire or Bestial Wrath goes off while the player's movement is read", hit = "it opens the distance (closing under -1 yd/s) within 5 s",
      miss = "5 s pass without", attribution = "its movement off the row (observed)",
      needs = { "motion" } },
    { key = "saving_cooldowns_until_low", consequence = "it holds its defensive until low",
      response = "burst before it is low enough to pop it", fallback = "expect the defensive under 35%",
      chance = "a defensive of its appears (no forecast is scored: a measurement)", hit = "its health then is under 35%", miss = "above",
      attribution = "its aura event (observed)", needs = { "enemy_auras" } },
}
--- The brief's patterns this stage does not read, and why.
D.NOT_BUILT_PATTERNS = {
    chasing_bad_terrain = "needs the walk map's clear line behind the player (not read here)",
}
--- The inputs a miss rests on, in words (T.inputs).
D.INPUT_WORDS = {
    enemy_casts = "enemy cast event", enemy_auras = "enemy aura event", our_casts = "cast of ours",
    our_interrupted = "interrupted cast of ours", control_ends = "control ending", foe_target = "enemy target read",
    motion = "player movement read",
}
D.OUR_SLOW_CASTS = { ["Wing Clip"] = true, ["Concussive Shot"] = true }
D.OUR_BURSTS = { ["Rapid Fire"] = true, ["Bestial Wrath"] = true }
--- Our casts with a cast time: a player in reach that lets one through
--- did not interrupt it.
D.OUR_CASTS = { ["Aimed Shot"] = true }
--- A class's gap closers (MOBILITY by the Classic class that has each):
--- a slow is a chance only for a player that can close.
D.CLASS_GAP_CLOSERS = {
    WARRIOR = { "Charge", "Intercept" }, DRUID = { "Feral Charge" }, ROGUE = { "Sprint" },
}
D.INTERRUPTS = { ["Kick"] = true, ["Pummel"] = true, ["Shield Bash"] = true, ["Counterspell"] = true,
                 ["Earth Shock"] = true, ["Spell Lock"] = true, ["Silence"] = true, ["Feral Charge"] = true }

-- --- bait detection (Stage 8) ----------------------------------------------------------

D.SOURCE.CLASS_DEFENSIVES = "the PROTECTION names above, by the Classic class that has each (Evasion a rogue's, Ice Block and Ice Barrier a mage's, the bubbles a paladin's, Shield Wall a warrior's, Power Word: Shield a priest's, Barkskin a druid's, Deterrence a hunter's)"
D.SOURCE.CLASS_INTERRUPT = "Classic Era's interrupt per class (INTERRUPTS above); the reaches are the Classic tooltips (Kick, Pummel and Shield Bash melee; Counterspell 30 yd; Earth Shock 20; Spell Lock 30; Silence 30; Feral Charge 25)"

-- --- the decision episodes (the collector, 2026-10-12) -------------------------------

D.SOURCE.EPISODE_TYPES = "the brief's list of tactical opportunities, each tied to what the picture observes; the result rules are score.lua EPISODES"

--- The tactical opportunities an episode opens on: `pattern` the
--- predictor's pattern it tests (none: the prediction reads NONE),
--- `horizon` the window in seconds, `needs_role` a result that would rest
--- on the player's inferred role reads UNKNOWN unless the role is sure.
D.EPISODE_TYPES = {
    { key = "gap_close_attempt", label = "a melee player closes the gap", pattern = "mobility_when_slowed", horizon = 5 },
    { key = "rogue_opener", label = "a rogue opens on you", pattern = "same_opener", horizon = 6 },
    { key = "blink", label = "a mage blinks", horizon = 4 },
    { key = "enemy_burst", label = "an enemy's burst cooldown", pattern = "over_committing", horizon = 10 },
    { key = "rooted_under_pressure", label = "you are rooted with players on you", horizon = 6 },
    { key = "dead_zone_entry", label = "the target enters your dead zone", horizon = 5 },
    { key = "pet_breaks_cc", label = "your pet threatens a control", horizon = 4 },
    { key = "kill_opportunity", label = "a kill window opens", horizon = 8 },
    { key = "defensive_change", label = "the opponent changes its defence", pattern = "defensive_threshold", horizon = 6 },
    { key = "outnumbered", label = "several players on you", horizon = 8 },
}
--- Our casts that do damage (a hold is broken by one), and the ones that
--- spend a cooldown worth keeping (a defensive, an escape, a control).
D.OUR_DAMAGE = { ["Auto Shot"] = true, ["Aimed Shot"] = true, ["Arcane Shot"] = true, ["Multi-Shot"] = true, ["Serpent Sting"] = true,
                 ["Raptor Strike"] = true, ["Mongoose Bite"] = true, ["Immolation Trap"] = true, ["Explosive Trap"] = true }
D.OUR_COOLDOWNS = { ["Feign Death"] = true, ["Deterrence"] = true, ["Scatter Shot"] = true, ["Intimidation"] = true, ["Freezing Trap"] = true,
                    ["Rapid Fire"] = true, ["Bestial Wrath"] = true, ["Wyvern Sting"] = true }

--- A class's defensives, as the ledger can see them used.
D.CLASS_DEFENSIVES = {
    ROGUE = { "Evasion" }, MAGE = { "Ice Block", "Ice Barrier" },
    PALADIN = { "Divine Shield", "Divine Protection", "Blessing of Protection" },
    WARRIOR = { "Shield Wall" }, PRIEST = { "Power Word: Shield" }, DRUID = { "Barkskin" },
    HUNTER = { "Deterrence" }, WARLOCK = {}, SHAMAN = {},
}
--- A class's interrupt, and how far each reaches.
D.CLASS_INTERRUPT = {
    ROGUE = "Kick", WARRIOR = "Pummel", MAGE = "Counterspell", SHAMAN = "Earth Shock",
    WARLOCK = "Spell Lock", PRIEST = "Silence", DRUID = "Feral Charge",
}
D.INTERRUPT_REACH = {
    ["Kick"] = 5, ["Pummel"] = 5, ["Shield Bash"] = 5, ["Counterspell"] = 30, ["Earth Shock"] = 20,
    ["Spell Lock"] = 30, ["Silence"] = 30, ["Feral Charge"] = 25,
}

return D

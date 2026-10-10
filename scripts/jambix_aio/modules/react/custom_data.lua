-- Jambix AIO / react / custom_data -- what the Reactions window offers (1.76.0).
--
-- Pure data: the conditions a reaction can be built from, the actions, the
-- targets, how important it is, where it applies (every Classic dungeon,
-- raid and battleground by name), templates, a line on what each of the
-- built-in reactions does, and where each acts by default (1.78.0).
-- modules/react/custom.lua makes reactions of it; modules/reactwin.lua
-- draws it.
--
-- ONE FUNCTION SET FOR THE GUI AND FOR LUA. Every condition is written as
-- the Lua expression it stands for ("me.hp", "target.casting",
-- 'buff("Name")'). The window shows that expression under each row and turns
-- a row into Lua with one click; Lua code reads the same names and can call
-- any row by its key with check(key, op, value). The reads behind the names
-- are custom.lua's, over the reaction engine's one picture of the fight.

local D = {}

-- --- comparisons ------------------------------------------------------------

--- Ops by value type. `code` is how the op reads in Lua.
D.OPS = {
    number = {
        { key = "<", label = "below", code = "<" },
        { key = "<=", label = "at most", code = "<=" },
        { key = ">", label = "above", code = ">" },
        { key = ">=", label = "at least", code = ">=" },
        { key = "==", label = "exactly", code = "==" },
    },
    bool = {
        { key = "is", label = "yes" },
        { key = "not", label = "no" },
    },
    text = {
        { key = "is", label = "yes" },
        { key = "not", label = "no" },
    },
    choice = {
        { key = "is", label = "is" },
        { key = "not", label = "is not" },
    },
    -- A key held (1.79.0): the row's value is the key.
    key = {
        { key = "is", label = "held" },
        { key = "not", label = "not held" },
    },
}
-- A name and a number (1.79.0): "seconds left on my buff Ice Barrier below 3".
D.OPS.text_number = D.OPS.number

-- --- choices ------------------------------------------------------------------

D.CREATURES = { "Beast", "Dragonkin", "Demon", "Elemental", "Giant", "Undead", "Humanoid",
    "Critter", "Mechanical", "Totem" }
--- The client's creature type number -> the name above.
D.CREATURE_BY_ID = { [1] = "Beast", [2] = "Dragonkin", [3] = "Demon", [4] = "Elemental", [5] = "Giant",
    [6] = "Undead", [7] = "Humanoid", [8] = "Critter", [9] = "Mechanical", [11] = "Totem" }

D.MODES = { "NORMAL", "DEFENSIVE", "EMERGENCY", "ESCAPE", "RECOVERY" }

--- What can take control of you, as react/pvp.lua names it (1.81.0).
D.CONTROLS = { "stun", "fear", "polymorph", "charm", "sleep", "knockout", "disorient", "freeze", "horror",
               "silence", "disarm", "root", "snare" }

--- The engine's situations (react/detect.lua), as a player reads them.
D.SITUATIONS = {
    { key = "hp_low", label = "My health is low" },
    { key = "hp_critical", label = "My health is critical" },
    { key = "pet_low", label = "The pet's health is low" },
    { key = "pet_critical", label = "The pet's health is critical" },
    { key = "mana_low", label = "Mana is low" },
    { key = "threat_warning", label = "My threat is high" },
    { key = "threat_critical", label = "I am about to pull aggro" },
    { key = "danger_high", label = "Danger is high" },
    { key = "danger_extreme", label = "Danger is extreme" },
    { key = "aoe", label = "Three or more mobs (area fight)" },
    { key = "adds", label = "Adds joined the fight" },
    { key = "flee", label = "The fight is lost: get out" },
    { key = "losing", label = "Losing the race" },
    { key = "outnumbered", label = "Outnumbered" },
    { key = "incoming", label = "Mobs on their way" },
    { key = "spike", label = "Damage spike" },
    { key = "aggro_pulled", label = "I pulled aggro" },
    { key = "pet_lost_aggro", label = "The pet lost its mob" },
    { key = "incapacitated", label = "I cannot act (stun, fear...)" },
    { key = "bailout", label = "Hardcore bail-out" },
}

--- Where you are, as the window and where.kind name it.
D.WHERE = {
    { key = "world", label = "Open world" },
    { key = "world_pvp", label = "Open world PvP" },
    { key = "bg", label = "Battleground" },
    { key = "arena", label = "Arena" },
    { key = "dungeon", label = "Dungeon" },
    { key = "raid", label = "Raid" },
}

-- --- conditions -----------------------------------------------------------------
--
--   key     permanent: saved reactions name it, and so does check() in Lua
--   label   what the dropdown says
--   group   the heading it sits under
--   type    number | bool | text | choice
--   code    the Lua it stands for; %s is the text or choice value
--   min/max/step/suffix  the slider, for numbers
--   choices for a choice; "creatures", "modes", "situations", "where", "library", "controls"
--   default the value a new row starts with
--   pick    for text: "spell" (your spellbook), "aura", "cast" (free text)

D.CONDITIONS = {
    -- Me
    { key = "me_hp", group = "Me", label = "My health %", type = "number", code = "me.hp",
      min = 1, max = 100, suffix = "%", default = 40, op = "<" },
    { key = "me_falling", group = "Me", label = "My health falling (% a second)", type = "number",
      code = "me.falling", min = 0, max = 50, suffix = "%/s", default = 5, op = ">=" },
    { key = "me_ttl", group = "Me", label = "I die within (seconds, at this rate)", type = "number",
      code = "me.ttl", min = 1, max = 60, suffix = "s", default = 6, op = "<" },
    { key = "me_power", group = "Me", label = "My mana / rage / energy %", type = "number",
      code = "me.power_pct", min = 0, max = 100, suffix = "%", default = 20, op = "<" },
    { key = "me_power_raw", group = "Me", label = "My mana / rage / energy (points)", type = "number",
      code = "me.power", min = 0, max = 3000, suffix = "", default = 30, op = ">=" },
    { key = "me_combo", group = "Me", label = "Combo points", type = "number", code = "me.combo",
      min = 0, max = 5, default = 5, op = ">=" },
    { key = "me_combat", group = "Me", label = "I am in combat", type = "bool", code = "me.in_combat" },
    { key = "me_moving", group = "Me", label = "I am moving", type = "bool", code = "me.moving" },
    { key = "me_casting", group = "Me", label = "I am casting or channelling", type = "bool", code = "me.casting" },
    { key = "me_attacking", group = "Me", label = "I am auto-attacking or shooting", type = "bool",
      code = "me.attacking" },
    { key = "me_controlled", group = "Me", label = "I am stunned, feared or rooted", type = "bool",
      code = "me.controlled" },
    { key = "me_buff", group = "Me", label = "I have the buff", type = "text", code = 'buff(%q)',
      pick = "spell", default = "" },
    { key = "me_attackers", group = "Me", label = "Mobs attacking me", type = "number", code = "fight.on_me",
      min = 0, max = 10, default = 2, op = ">=" },
    { key = "me_melee", group = "Me", label = "Mobs in melee range of me", type = "number",
      code = "fight.melee_on_me", min = 0, max = 10, default = 2, op = ">=" },
    { key = "me_healthstone", group = "Me", label = "A healthstone is ready", type = "bool", code = "me.healthstone" },
    { key = "me_potion", group = "Me", label = "A healing potion is ready", type = "bool", code = "me.potion" },
    { key = "me_mana_potion", group = "Me", label = "A mana potion is ready", type = "bool", code = "me.mana_potion" },
    { key = "me_level", group = "Me", label = "My level", type = "number", code = "me.level",
      min = 1, max = 80, default = 60, op = ">=" },
    -- 1.79.0
    { key = "me_combat_time", group = "Me", label = "Seconds in combat", type = "number", code = "me.combat_time",
      min = 0, max = 120, suffix = "s", default = 10, op = ">=" },
    { key = "me_buff_left", group = "Me", label = "Seconds left on my buff", type = "text_number", code = 'buff_left(%q)',
      pick = "spell", default = "", min = 0, max = 60, step = 0.5, suffix = "s", default_num = 3, op = "<" },
    { key = "me_buff_stacks", group = "Me", label = "Stacks of my buff", type = "text_number", code = 'buff_stacks(%q)',
      pick = "spell", default = "", min = 0, max = 20, default_num = 3, op = ">=" },
    { key = "me_has_item", group = "Me", label = "I carry the item", type = "text", code = 'has_item(%q)',
      pick = "item", default = "" },
    -- 1.81.0: PvP (react/pvp.lua)
    { key = "me_control_kind", group = "Me", label = "I am controlled by", type = "choice",
      code = "me.control_kind == %q", choices = "controls", default = "stun" },
    { key = "me_pvp_trinket", group = "Me", label = "My PvP trinket is ready", type = "bool", code = "me.pvp_trinket" },

    -- Spells
    { key = "spell_ready", group = "Spells", label = "This spell is ready", type = "text", code = 'ready(%q)',
      pick = "spell", default = "" },
    { key = "spell_known", group = "Spells", label = "I know this spell", type = "text", code = 'known(%q)',
      pick = "spell", default = "" },
    { key = "spell_cd", group = "Spells", label = "Cooldown left on the spell", type = "text_number", code = 'cooldown(%q)',
      pick = "spell", default = "", min = 0, max = 120, step = 0.5, suffix = "s", default_num = 1, op = "<" },

    -- Target
    { key = "t_exists", group = "Target", label = "I have a target", type = "bool", code = "target.exists" },
    { key = "t_hp", group = "Target", label = "Target health %", type = "number", code = "target.hp",
      min = 1, max = 100, suffix = "%", default = 20, op = "<" },
    { key = "t_distance", group = "Target", label = "Target distance (yards)", type = "number",
      code = "target.distance", min = 0, max = 60, suffix = "yd", default = 8, op = "<" },
    { key = "t_ttd", group = "Target", label = "Target dies within (seconds)", type = "number",
      code = "target.ttd", min = 1, max = 120, suffix = "s", default = 5, op = "<" },
    { key = "t_casting", group = "Target", label = "Target is casting", type = "bool", code = "target.casting" },
    { key = "t_interruptible", group = "Target", label = "Target's cast can be interrupted", type = "bool",
      code = "target.interruptible" },
    { key = "t_cast_name", group = "Target", label = "Target is casting the spell", type = "text",
      code = 'target.cast_name == %q', pick = "cast", default = "" },
    { key = "t_cast_left", group = "Target", label = "Target's cast ends within (seconds)", type = "number",
      code = "target.cast_left", min = 0, max = 10, step = 0.1, suffix = "s", default = 1, op = "<" },
    { key = "t_on_me", group = "Target", label = "Target is attacking me", type = "bool", code = "target.on_me" },
    { key = "t_on_pet", group = "Target", label = "Target is attacking my pet", type = "bool", code = "target.on_pet" },
    { key = "t_elite", group = "Target", label = "Target is elite", type = "bool", code = "target.elite" },
    { key = "t_boss", group = "Target", label = "Target is a boss", type = "bool", code = "target.boss" },
    { key = "t_rare", group = "Target", label = "Target is rare", type = "bool", code = "target.rare" },
    { key = "t_player", group = "Target", label = "Target is a player", type = "bool", code = "target.player" },
    { key = "t_level", group = "Target", label = "Target's level above mine", type = "number",
      code = "target.level_diff", min = -10, max = 10, default = 3, op = ">=" },
    { key = "t_creature", group = "Target", label = "Target's creature type", type = "choice",
      code = "target.creature == %q", choices = "creatures", default = "Humanoid" },
    { key = "t_aura", group = "Target", label = "Target has the buff or debuff", type = "text",
      code = 'debuff(%q)', pick = "spell", default = "" },
    { key = "t_my_aura", group = "Target", label = "Target has MY debuff", type = "text",
      code = 'debuff(%q, true)', pick = "spell", default = "" },
    { key = "t_controlled", group = "Target", label = "Target is crowd-controlled", type = "bool",
      code = "target.controlled" },
    { key = "t_threat", group = "Target", label = "My threat on the target %", type = "number",
      code = "target.threat", min = 0, max = 130, suffix = "%", default = 90, op = ">=" },
    { key = "t_runs", group = "Target", label = "Target runs at low health", type = "bool", code = "target.runs" },
    { key = "t_others", group = "Target", label = "Target is someone else's fight", type = "bool",
      code = "target.others" },
    -- 1.79.0
    { key = "t_name", group = "Target", label = "Target's name is", type = "text", code = 'target.name == %q',
      pick = "name", default = "" },
    { key = "t_fleeing", group = "Target", label = "Target is running away", type = "bool", code = "target.fleeing" },
    { key = "t_on_tank", group = "Target", label = "Target is attacking the tank", type = "bool", code = "target.on_tank" },
    { key = "t_on_healer", group = "Target", label = "Target is attacking the healer", type = "bool",
      code = "target.on_healer" },
    { key = "t_on_group", group = "Target", label = "Target is attacking someone in my group", type = "bool",
      code = "target.on_group" },
    { key = "t_debuff_left", group = "Target", label = "Seconds left on MY debuff on the target", type = "text_number",
      code = 'debuff_left(%q)', pick = "spell", default = "", min = 0, max = 60, step = 0.5, suffix = "s",
      default_num = 3, op = "<" },
    { key = "t_debuff_stacks", group = "Target", label = "Stacks of a debuff on the target", type = "text_number",
      code = 'debuff_stacks(%q)', pick = "spell", default = "", min = 0, max = 20, default_num = 5, op = "<" },
    -- 1.81.0: PvP (react/pvp.lua)
    { key = "t_immune", group = "Target", label = "Target is immune (Divine Shield, Ice Block, Blessing of Protection)",
      type = "bool", code = "target.immune" },
    { key = "t_bursting", group = "Target", label = "Target has a burst cooldown up (Recklessness, Arcane Power...)",
      type = "bool", code = "target.bursting" },
    { key = "t_trinket_down", group = "Target", label = "Target's PvP trinket is on its cooldown", type = "bool",
      code = "target.trinket_down" },

    -- Pet
    { key = "pet_exists", group = "Pet", label = "My pet is out", type = "bool", code = "pet.exists" },
    { key = "pet_hp", group = "Pet", label = "Pet health %", type = "number", code = "pet.hp",
      min = 1, max = 100, suffix = "%", default = 40, op = "<" },
    { key = "pet_attackers", group = "Pet", label = "Mobs attacking my pet", type = "number", code = "pet.attackers",
      min = 0, max = 10, default = 2, op = ">=" },
    { key = "pet_tanking", group = "Pet", label = "My pet holds the target", type = "bool", code = "pet.tanking" },

    -- Group
    { key = "g_group", group = "Group", label = "I am in a group", type = "bool", code = "group.in_group" },
    { key = "g_raid", group = "Group", label = "I am in a raid", type = "bool", code = "group.in_raid" },
    { key = "g_dead", group = "Group", label = "Group members dead", type = "number", code = "group.dead",
      min = 0, max = 40, default = 1, op = ">=" },
    { key = "g_tank", group = "Group", label = "The tank is alive", type = "bool", code = "group.tank_alive" },
    { key = "g_healer", group = "Group", label = "The healer is alive", type = "bool", code = "group.healer_alive" },
    { key = "g_healer_cc", group = "Group", label = "The healer is crowd-controlled", type = "bool",
      code = "group.healer_controlled" },
    { key = "g_lowest", group = "Group", label = "Lowest group member's health %", type = "number", code = "group.lowest",
      min = 1, max = 100, suffix = "%", default = 40, op = "<" },
    { key = "g_hurt", group = "Group", label = "Group members under 50% health", type = "number", code = "group.hurt",
      min = 0, max = 40, default = 2, op = ">=" },

    -- Fight
    { key = "f_mode", group = "Fight", label = "The fight's mode", type = "choice", code = "fight.mode == %q",
      choices = "modes", default = "EMERGENCY" },
    { key = "f_situation", group = "Fight", label = "Situation", type = "choice", code = "situation(%q)",
      choices = "situations", default = "outnumbered" },
    { key = "f_danger", group = "Fight", label = "Danger (0-100)", type = "number", code = "fight.danger",
      min = 0, max = 100, default = 55, op = ">=" },
    { key = "f_engaged", group = "Fight", label = "Mobs in the fight", type = "number", code = "fight.engaged",
      min = 0, max = 15, default = 3, op = ">=" },
    { key = "f_nearby", group = "Fight", label = "Enemies within 40 yards", type = "number", code = "fight.nearby",
      min = 0, max = 30, default = 5, op = ">=" },
    { key = "f_casters", group = "Fight", label = "Enemies casting near me", type = "number", code = "fight.casting",
      min = 0, max = 8, default = 1, op = ">=" },
    { key = "f_elites", group = "Fight", label = "Elites in the fight", type = "number", code = "fight.elites",
      min = 0, max = 10, default = 1, op = ">=" },
    { key = "f_boss", group = "Fight", label = "A boss fight", type = "bool", code = "fight.boss" },
    { key = "f_pvp", group = "Fight", label = "Fighting players (PvP)", type = "bool", code = "fight.pvp" },
    { key = "f_within8", group = "Fight", label = "Enemies within 8 yards of me", type = "number", code = "fight.within8",
      min = 0, max = 15, default = 3, op = ">=" },
    { key = "f_within30", group = "Fight", label = "Enemies within 30 yards of me", type = "number", code = "fight.within30",
      min = 0, max = 30, default = 5, op = ">=" },
    { key = "f_players", group = "Fight", label = "Enemy players within 40 yards", type = "number", code = "fight.players",
      min = 0, max = 20, default = 1, op = ">=" },

    -- Keys (1.79.0): a reaction you fire with a key, when its other conditions hold.
    { key = "key_held", group = "Keys", label = "This key is held", type = "key", code = "key(%d)", default = 0 },

    -- Where
    { key = "w_kind", group = "Where", label = "Where I am", type = "choice", code = "where.kind == %q",
      choices = "where", default = "dungeon" },
    { key = "w_name", group = "Where", label = "Inside the instance named", type = "text", code = 'place(%q)',
      pick = "place", default = "" },

    -- Your Lua
    { key = "lua_fn", group = "My Lua", label = "My Lua function says yes", type = "choice", code = "%s()",
      choices = "library", default = "" },
}

D.CONDITION_BY_KEY = {}
for i = 1, #D.CONDITIONS do D.CONDITION_BY_KEY[D.CONDITIONS[i].key] = D.CONDITIONS[i] end

-- --- actions ---------------------------------------------------------------------

D.ACTION_KINDS = {
    { key = "spell", label = "Cast a spell" },
    { key = "item", label = "Use an item" },
    { key = "named_item", label = "Use an item by name" },
    { key = "pet_spell", label = "Pet ability" },
    { key = "pet_attack", label = "Send the pet" },
    { key = "lua_fn", label = "Run my Lua function" },
    { key = "hold", label = "Hold the rotation (stop attacking)" },
    -- Instant (1.79.0): they take no global cooldown and never stop the list.
    { key = "alert", label = "Alert on screen", instant = true },
    { key = "target", label = "Switch my target", instant = true },
    { key = "stop_cast", label = "Stop my cast", instant = true },
}
D.ACTION_KIND_BY_KEY = {}
for i = 1, #D.ACTION_KINDS do D.ACTION_KIND_BY_KEY[D.ACTION_KINDS[i].key] = D.ACTION_KINDS[i] end

--- Who "Switch my target" picks (1.79.0).
D.SWITCH_TARGETS = {
    { key = "attacker", label = "An enemy attacking me (not my target)" },
    { key = "caster", label = "An enemy that is casting" },
    { key = "tank_target", label = "The tank's target" },
    { key = "healer_attacker", label = "An enemy attacking the healer" },
    { key = "lowest", label = "The enemy with the least health" },
    { key = "nearest", label = "The nearest enemy in the fight" },
}

--- An alert's colour (1.79.0).
D.ALERT_COLORS = {
    { key = "red", label = "Red", rgb = { 255, 90, 90 } },
    { key = "orange", label = "Orange", rgb = { 255, 165, 70 } },
    { key = "yellow", label = "Yellow", rgb = { 255, 225, 90 } },
    { key = "green", label = "Green", rgb = { 120, 225, 140 } },
    { key = "blue", label = "Blue", rgb = { 110, 180, 255 } },
    { key = "white", label = "White", rgb = { 240, 240, 245 } },
}
D.ALERT_COLOR_BY_KEY = {}
for i = 1, #D.ALERT_COLORS do D.ALERT_COLOR_BY_KEY[D.ALERT_COLORS[i].key] = D.ALERT_COLORS[i] end

D.TARGETS = {
    { key = "target", label = "My target", code = "target" },
    { key = "self", label = "Myself", code = "self" },
    { key = "pet", label = "My pet", code = "pet" },
    { key = "caster", label = "An enemy that is casting", code = "caster" },
    { key = "attacker", label = "An enemy attacking me (not my target)", code = "attacker" },
    { key = "tank", label = "The group's tank", code = "tank" },
    { key = "healer", label = "The group's healer", code = "healer" },
}

D.ITEMS = {
    { key = "healthstone", label = "Healthstone" },
    { key = "potion", label = "Healing potion" },
    { key = "mana_potion", label = "Mana potion" },
    { key = "mana_gem", label = "Mana gem" },
    { key = "bandage", label = "Bandage" },
}

--- Pet abilities a hunter's beast or a warlock's demon can have in
--- Classic; the window lists the ones your pet knows.
D.PET_SPELLS = { "Growl", "Claw", "Bite", "Dash", "Dive", "Charge", "Cower", "Furious Howl", "Prowl",
    "Screech", "Scorpid Poison", "Lightning Breath", "Fire Breath", "Thunderstomp", "Shell Shield",
    "Firebolt", "Blood Pact", "Fire Shield", "Phase Shift", "Torment", "Sacrifice", "Suffering",
    "Consume Shadows", "Lash of Pain", "Seduction", "Soothing Kiss", "Lesser Invisibility",
    "Devour Magic", "Spell Lock", "Tainted Blood", "Paranoia" }

-- --- how important -----------------------------------------------------------------
--
-- The engine's own scale (rules/core.lua): a reaction must score 40 (the
-- rotation) to take the global cooldown from it; under that it goes out
-- only on a tick the rotation had nothing to press.

D.IMPORTANCE = {
    { key = "survival", label = "Life or death", category = "survival", priority = 100 },
    { key = "interrupt", label = "Interrupt", category = "interrupt", priority = 90 },
    { key = "escape", label = "Escape", category = "escape", priority = 88 },
    { key = "cc", label = "Crowd control", category = "cc", priority = 85 },
    { key = "defensive", label = "Defensive", category = "defensive", priority = 80 },
    { key = "resource", label = "Mana and resources", category = "resource", priority = 72 },
    { key = "pet", label = "Pet", category = "pet", priority = 70 },
    { key = "threat", label = "Threat", category = "threat", priority = 65 },
    { key = "utility", label = "Utility", category = "utility", priority = 60 },
    { key = "buff", label = "Buff", category = "buff", priority = 50 },
    { key = "offense", label = "Damage (ahead of the rotation)", category = "utility", priority = 45, offensive = true },
    { key = "filler", label = "Only when the rotation is idle", category = "low", priority = 20 },
}
D.IMPORTANCE_BY_KEY = {}
for i = 1, #D.IMPORTANCE do D.IMPORTANCE_BY_KEY[D.IMPORTANCE[i].key] = D.IMPORTANCE[i] end

--- Category colours for the window's cards (r, g, b).
D.COLORS = {
    survival = { 235, 87, 87 }, bailout = { 235, 87, 87 }, interrupt = { 240, 180, 60 },
    escape = { 200, 120, 240 }, cc = { 90, 160, 235 }, defensive = { 100, 200, 140 },
    resource = { 70, 120, 230 }, pet = { 210, 160, 90 }, threat = { 240, 130, 70 },
    utility = { 160, 163, 176 }, buff = { 140, 120, 240 }, low = { 105, 108, 120 },
}

-- --- where ---------------------------------------------------------------------------
--
-- Matched by the instance's name as the client says it (an English client),
-- and by the instance id where the name is missing. A wing that shares its
-- instance with the others (Scarlet Monastery, Dire Maul, Blackrock Spire)
-- cannot be told apart from the client's answer, so they are one entry.
-- An instance not listed here is learned the first time you enter it and
-- offered from then on.

D.DUNGEONS = {
    { name = "Ragefire Chasm", id = 389, level = "13-18" },
    { name = "Wailing Caverns", id = 43, level = "17-24" },
    { name = "The Deadmines", id = 36, level = "17-26", aliases = { "Deadmines" } },
    { name = "Shadowfang Keep", id = 33, level = "22-30" },
    { name = "Blackfathom Deeps", id = 48, level = "24-32" },
    { name = "The Stockade", id = 34, level = "24-32", aliases = { "Stormwind Stockade", "Stockade" } },
    { name = "Gnomeregan", id = 90, level = "29-38" },
    { name = "Razorfen Kraul", id = 47, level = "29-38" },
    { name = "Scarlet Monastery", id = 189, level = "34-45", note = "all four wings",
      aliases = { "Scarlet Monastery Graveyard", "Scarlet Monastery Library", "Scarlet Monastery Armory",
                  "Scarlet Monastery Cathedral" } },
    { name = "Razorfen Downs", id = 129, level = "37-46" },
    { name = "Uldaman", id = 70, level = "41-51" },
    { name = "Zul'Farrak", id = 209, level = "42-46" },
    { name = "Maraudon", id = 349, level = "46-55" },
    { name = "Sunken Temple", id = 109, level = "50-56",
      aliases = { "The Temple of Atal'Hakkar", "Temple of Atal'Hakkar" } },
    { name = "Blackrock Depths", id = 230, level = "52-60" },
    { name = "Blackrock Spire", id = 229, level = "55-60", note = "lower and upper",
      aliases = { "Lower Blackrock Spire", "Upper Blackrock Spire" } },
    { name = "Dire Maul", id = 429, level = "55-60", note = "east, west and north",
      aliases = { "Dire Maul East", "Dire Maul West", "Dire Maul North" } },
    { name = "Scholomance", id = 289, level = "58-60" },
    { name = "Stratholme", id = 329, level = "58-60" },
}

D.RAIDS = {
    { name = "Molten Core", id = 409 },
    { name = "Onyxia's Lair", id = 249 },
    { name = "Blackwing Lair", id = 469 },
    { name = "Zul'Gurub", id = 309 },
    { name = "Ruins of Ahn'Qiraj", id = 509, aliases = { "Ahn'Qiraj Ruins", "AQ20" } },
    { name = "Temple of Ahn'Qiraj", id = 531, aliases = { "Ahn'Qiraj Temple", "Ahn'Qiraj", "AQ40" } },
    { name = "Naxxramas", id = 533 },
}

D.BATTLEGROUNDS = {
    { name = "Warsong Gulch", id = 489 },
    { name = "Arathi Basin", id = 529 },
    { name = "Alterac Valley", id = 30 },
}

D.ARENAS = {}

--- The environment switches, in the window's order. `list` is the
--- instance list a "which one" dropdown offers.
D.ENV = {
    { key = "world", label = "Open world" },
    { key = "world_pvp", label = "Open world PvP" },
    { key = "bg", label = "Battlegrounds (PvP)", list = "BATTLEGROUNDS" },
    { key = "arena", label = "Arenas (PvP)", list = "ARENAS" },
    { key = "dungeon", label = "Dungeons", list = "DUNGEONS" },
    { key = "raid", label = "Raids", list = "RAIDS" },
}

-- --- the built-in reactions ------------------------------------------------------------

D.DEFAULT_INFO = {
    ["Emergency potion"] = "A healthstone, else a healing potion, when your health is about to cross the potion line in a fight.",
    ["Hardcore bail-out"] = "Stops every attack while the Hardcore bail-out holds, so you can get away (Hardcore page).",
    ["Hearthstone out"] = "The Hearthstone as the last way out (Hardcore page).",
    ["Interrupt"] = "Kicks the most dangerous enemy cast it can reach, late enough to be sure, early enough to land.",
    ["Break contact"] = "Your escape (Feign Death, Vanish, Frost Nova, Blink...) when the fight is lost.",
    ["Crowd control an add"] = "Puts a second mob out of the fight (Polymorph, Sap, Fear...) when two or more are on you.",
    ["Defensive cooldown"] = "Your class's defensive cooldown when the damage is more than you can take.",
    ["Defensive racial"] = "Stoneform, Will of the Forsaken, Escape Artist and the like, when they answer what is happening.",
    ["Heal the pet"] = "Mend Pet or Health Funnel when the pet is losing, never when standing still would get you killed.",
    ["Pet: taunt"] = "Growl or Torment at the mob about to leave the pet for you.",
    ["Shed threat"] = "Feign Death, Fade, Cower and friends when your threat is about to pull the mob off the tank.",
    ["Dispel"] = "Removes a harmful magic, curse, poison or disease that you can remove.",
    ["Top up the pet"] = "Mend Pet with nothing else going on.",
    ["Surrounded: area control"] = "Frost Nova, Thunder Clap, Psychic Scream... when several mobs are in melee range.",
    ["Stop the runner"] = "Slows or roots a mob running away at low health before it brings friends.",
    ["Pet: off the evading mob"] = "Calls the pet back from a mob that is evading.",
    ["Pet: pick up the add"] = "Sends the pet at an add that is hitting you.",
    ["Restore mana"] = "A mana gem, else a mana potion, when mana runs out before the fight does.",
    ["Mana cooldown"] = "Evocation, Innervate, Life Tap and the like when mana is short.",
    ["Clip the add"] = "Wing Clip on a mob meleeing you that is not your target, so you can step away from it.",
    ["Stop the cast with crowd control"] = "Scatter Shot or Intimidation to stop a cast that Counter Shot cannot.",
    ["Intimidation: save the pet"] = "Intimidation when the pet is about to die under its mob.",
    ["Intimidation: give the pet its mob back"] = "Intimidation to hand back a mob that turned on you.",
    ["Out of Cheetah before the hit"] = "Leaves Aspect of the Cheetah before a mob reaches you (dazed).",
    -- 1.7.6: the hunter's AOE melee weave (ALPHA/TEST)
    ["AOE weave: sting the next mob"] = "AOE melee weave (ALPHA/TEST) only: out of melee, once your target has its Serpent Sting, the target moves on to the next mob fighting you or your pet whose sting is missing or running out.",
    ["Pet: Furious Howl"] = "The wolf's Furious Howl when you are about to hit.",
    ["Pet: sprint to its mob"] = "Dash or Dive to reach the pet's mob sooner.",
    ["Pet: Charge"] = "The boar's Charge at its mob.",
    ["Pet: Thunderstomp"] = "The gorilla's Thunderstomp with several mobs around the pet.",
    ["Pet: Shell Shield"] = "The turtle's Shell Shield when the pet is losing.",
    ["Pet: Cower"] = "Cower when the pet is about to take a mob that is not its own.",
    ["Pet: Sacrifice"] = "The voidwalker's Sacrifice when you are about to die.",
    ["Pet: Seduction"] = "The succubus seduces a second mob.",
    ["Pet: Consume Shadows"] = "The voidwalker heals itself out of combat.",
    -- 1.81.0: PvP (rules/pvp.lua)
    ["PvP: break the control"] = "Out of a player's stun, fear, sheep or root with the cheapest thing that breaks it (Blink, Berserker Rage, Will of the Forsaken, a form, the felhunter); the PvP trinket only when the control costs more than the trinket is worth (Reactions page: PvP trinket).",
    ["PvP: stop the cast"] = "A player's heal, sheep or fear with no interrupt ready: a stun or a fear stops it; aimed at you, Grounding Totem, Tremor Totem, Berserker Rage, Fear Ward or a druid's form.",
    ["PvP: answer the burst"] = "A player on you pops Recklessness, Arcane Power, Adrenaline Rush...: take them out for it, or your own defensive.",
    ["PvP: off the immune target"] = "Your target is in Divine Shield or Ice Block (Blessing of Protection, for a warrior or a rogue): switches to an enemy something lands on.",
    ["PvP: find the stealthy"] = "A player vanished beside you: Flare, Arcane Explosion, Holy Nova, Consecration or Thunder Clap; Perception when a stealthed player is about.",
    ["PvP: purge"] = "Purge, Dispel Magic or the felhunter's Devour Magic on a player's buff worth taking off (Blessing of Protection, Power Infusion, Arcane Power, a shield...).",
}

--- Built-in reactions only one class's pet can do: the window lists them
--- for that class only. Pet reactions at all: the classes with a pet.
D.DEFAULT_CLASS = {
    ["Pet: Seduction"] = "WARLOCK", ["Pet: Sacrifice"] = "WARLOCK", ["Pet: Consume Shadows"] = "WARLOCK",
    ["Pet: Furious Howl"] = "HUNTER", ["Pet: sprint to its mob"] = "HUNTER", ["Pet: Charge"] = "HUNTER",
    ["Pet: Thunderstomp"] = "HUNTER", ["Pet: Shell Shield"] = "HUNTER", ["Pet: Cower"] = "HUNTER",
    ["Clip the add"] = "HUNTER", ["Stop the cast with crowd control"] = "HUNTER",
    ["Intimidation: save the pet"] = "HUNTER", ["Intimidation: give the pet its mob back"] = "HUNTER",
    ["Out of Cheetah before the hit"] = "HUNTER", ["AOE weave: sting the next mob"] = "HUNTER",
}
D.PET_CLASSES = { HUNTER = true, WARLOCK = true }

--- The built-in reactions the plugin's own switches govern: the Reactions
--- master switch leaves them to their own page.
D.OWN_SWITCH = { ["Hardcore bail-out"] = "Hardcore page", ["Hearthstone out"] = "Hardcore page" }

-- --- the built-in reactions in dungeons and the open world (1.78.0) ------------------------
--
-- Where each built-in reaction acts before you change it. Every one acts
-- everywhere except those listed here: in a dungeon or a raid the tank holds
-- the mobs, and what these do pulls them off it. The rest already tell a
-- group from solo by themselves (crowd control and area fears wait for the
-- key in a group, the pet picks up adds only solo, threat drops only in a
-- group), so they need nothing per place. `env` names the places switched
-- off; `why` is the window's line.

D.DEFAULT_PLACES = {
    ["Pet: taunt"] = { env = { dungeon = false, raid = false },
        why = "the tank holds the mobs, and the pet's taunt pulls them off it. Switch it on to solo a dungeon." },
    ["Pet: Thunderstomp"] = { env = { dungeon = false, raid = false },
        why = "its threat on everything around the gorilla takes the pack off the tank." },
    ["Intimidation: give the pet its mob back"] = { env = { dungeon = false, raid = false },
        why = "a mob that leaves you is the tank's to take back, not the pet's." },
}

--- The two places the built-in list is set up for, side by side.
D.PLACE_COLUMNS = {
    { key = "world", label = "Open world", short = "World" },
    { key = "dungeon", label = "Dungeons", short = "Dungeon" },
}

-- --- starting points ---------------------------------------------------------------------

D.TEMPLATES = {
    { label = "Blank reaction", reaction = { name = "New reaction", importance = "defensive",
        conds = {}, actions = { { mode = "gui", kind = "spell", spell = "", target = "target" } } } },
    { label = "Panic button: low health with mobs on me", reaction = { name = "Panic button", importance = "survival",
        conds = { { mode = "gui", key = "me_hp", op = "<", value = 30 },
                  { mode = "gui", key = "me_attackers", op = ">=", value = 1 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "self" } } } },
    { label = "Interrupt my target's cast", reaction = { name = "Kick the cast", importance = "interrupt",
        conds = { { mode = "gui", key = "t_casting", op = "is" },
                  { mode = "gui", key = "t_interruptible", op = "is" } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "target" } } } },
    { label = "Finisher under 20% health", reaction = { name = "Execute range", importance = "offense",
        conds = { { mode = "gui", key = "t_hp", op = "<", value = 20 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "target" } } } },
    { label = "Two or more mobs on me: defensive", reaction = { name = "Too many on me", importance = "defensive",
        conds = { { mode = "gui", key = "me_attackers", op = ">=", value = 2 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "self" } } } },
    { label = "Mana potion when mana runs low", reaction = { name = "Mana potion", importance = "resource",
        conds = { { mode = "gui", key = "me_power", op = "<", value = 15 },
                  { mode = "gui", key = "me_combat", op = "is" } },
        actions = { { mode = "gui", kind = "item", item = "mana_potion" } } } },
    { label = "Save the pet", reaction = { name = "Pet in trouble", importance = "pet",
        conds = { { mode = "gui", key = "pet_hp", op = "<", value = 30 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "pet" } } } },
    { label = "Lua: written in code", reaction = { name = "Written in Lua", importance = "defensive",
        conds = { { mode = "lua", code = "-- true when this reaction should act\nreturn me.hp < 50 and fight.on_me >= 2" } },
        actions = { { mode = "lua", code = "-- the first cast that goes through wins\nif not cast(\"Frost Nova\") then\n    cast(\"Blink\", \"self\")\nend" } } } },
    -- 1.79.0
    { label = "Alert: the healer is down", reaction = { name = "Healer down!", importance = "utility", combat_only = false,
        conds = { { mode = "gui", key = "g_group", op = "is" }, { mode = "gui", key = "g_healer", op = "not" },
                  { mode = "gui", key = "g_dead", op = ">=", value = 1 } },
        actions = { { mode = "gui", kind = "alert", text = "HEALER DOWN", color = "red", sound = true } } } },
    { label = "Trinket when a boss fight is on", reaction = { name = "Boss trinket", importance = "offense", off_gcd = true,
        per_fight = 1, conds = { { mode = "gui", key = "f_boss", op = "is" } },
        actions = { { mode = "gui", kind = "named_item", name = "" } } } },
    { label = "Pick up the mob hitting the healer", reaction = { name = "Peel for the healer", importance = "utility",
        conds = { { mode = "gui", key = "g_group", op = "is" }, { mode = "gui", key = "t_on_healer", op = "not" } },
        actions = { { mode = "gui", kind = "target", who = "healer_attacker" } } } },
    { label = "Press a key: my panic button", reaction = { name = "Key: panic", importance = "survival",
        conds = { { mode = "gui", key = "key_held", op = "is", value = 0 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "self" } } } },
    { label = "Keep my buff up (refresh before it drops)", reaction = { name = "Keep it up", importance = "buff",
        combat_only = false,
        conds = { { mode = "gui", key = "me_buff_left", op = "<", value = "", num = 3 } },
        actions = { { mode = "gui", kind = "spell", spell = "", target = "self" } } } },
}

--- The test bench's ready-made situations (1.79.0): what the Try it step
--- starts from. Anything a situation leaves out reads as nothing (0, no).
D.BENCH_PRESETS = {
    { key = "calm", label = "In a fight, all fine", s = { in_combat = true, hp = 90, power = 80, target = true,
        t_hp = 70, t_distance = 20, on_me = 1, melee_on_me = 0, engaged = 1, combat_time = 8 } },
    { key = "panic", label = "Low health, two on me", s = { in_combat = true, hp = 22, power = 40, target = true,
        t_hp = 60, t_distance = 4, on_me = 2, melee_on_me = 2, engaged = 2, combat_time = 15, falling = 12, t_on_me = true } },
    { key = "caster", label = "My target is casting", s = { in_combat = true, hp = 75, power = 60, target = true,
        t_hp = 80, t_distance = 25, on_me = 1, engaged = 1, t_casting = true, t_interruptible = true,
        t_cast_left = 1.2, casters = 1, combat_time = 5 } },
    { key = "wipe", label = "Dungeon: the tank is dead", s = { in_combat = true, hp = 55, power = 50, target = true,
        t_hp = 70, t_distance = 6, on_me = 2, melee_on_me = 1, engaged = 4, where = "dungeon", in_group = true,
        tank_alive = false, healer_alive = true, dead = 1, combat_time = 40, t_on_me = true, elites = 2 } },
    { key = "healer", label = "Dungeon: the healer is dead", s = { in_combat = true, hp = 45, power = 50, target = true,
        t_hp = 50, t_distance = 5, on_me = 1, engaged = 3, where = "dungeon", in_group = true, tank_alive = true,
        healer_alive = false, dead = 1, lowest = 30, hurt = 2, combat_time = 30 } },
    { key = "pet", label = "My pet is dying", s = { in_combat = true, hp = 80, power = 60, target = true, t_hp = 60,
        t_distance = 20, engaged = 1, pet = true, pet_hp = 18, pet_attackers = 2, t_on_pet = true, combat_time = 12 } },
    { key = "boss", label = "Raid boss under 20%", s = { in_combat = true, hp = 85, power = 55, target = true, t_hp = 18,
        t_distance = 10, engaged = 1, boss = true, t_boss = true, t_elite = true, where = "raid", in_group = true,
        in_raid = true, tank_alive = true, healer_alive = true, combat_time = 180 } },
    { key = "pvp", label = "A player in melee", s = { in_combat = true, hp = 60, power = 50, target = true, t_hp = 65,
        t_distance = 3, on_me = 1, melee_on_me = 1, engaged = 1, t_player = true, t_on_me = true, pvp = true,
        players = 1, where = "world_pvp", combat_time = 6 } },
    { key = "idle", label = "Out of combat", s = { in_combat = false, hp = 100, power = 100 } },
}

D.LIBRARY_EXAMPLE = [[-- Your class's own Lua, shared by every reaction of the class.
-- A function made here can be called from any Lua condition or
-- action, and picked in the GUI as "My Lua function".
-- Everything the GUI reads is here too: me, target, pet, group,
-- fight, where, check(), ready(), known(), buff(), debuff(),
-- situation(), place(), and for actions cast(), use(), pet_cast(),
-- pet_attack(), hold().

function in_trouble()
    return me.hp < 40 and fight.on_me >= 2
end
]]

--- Every name the Lua side gives code, for the editor's colours and the
--- window's reference list.
D.API = {
    { name = "me", text = "hp, falling, ttl, power, power_pct, power_kind, combo, level, in_combat, combat_time, moving, casting, attacking, controlled, healthstone, potion, mana_potion" },
    { name = "target", text = "exists, name, hp, distance, ttd, casting, cast_name, cast_left, interruptible, on_me, on_pet, on_tank, on_healer, on_group, fleeing, elite, boss, rare, player, level_diff, creature, controlled, threat, runs, others" },
    { name = "pet", text = "exists, hp, attackers, tanking" },
    { name = "group", text = "in_group, in_raid, members, dead, tank_alive, healer_alive, healer_controlled, lowest (health %), hurt (under 50%)" },
    { name = "fight", text = "mode, danger, engaged, on_me, melee_on_me, nearby, within8, within30, players, casting, elites, boss, pvp" },
    { name = "where", text = "kind (world, world_pvp, bg, arena, dungeon, raid), name" },
    { name = "check", text = 'check("me_hp", "<", 40): any GUI condition by its key' },
    { name = "ready", text = 'ready("Spell"), known("Spell"), cooldown("Spell") in seconds' },
    { name = "buff", text = 'buff("Name") on you, debuff("Name") on the target, debuff("Name", true) yours only' },
    { name = "buff_left", text = 'buff_left("Name") / buff_stacks("Name"); debuff_left("Name") / debuff_stacks("Name", mine)' },
    { name = "has_item", text = 'has_item("Free Action Potion"): carried; key(0x10): that key is held' },
    { name = "situation", text = 'situation("outnumbered"); place("Molten Core")' },
    { name = "cast", text = 'cast("Spell", "target"|"self"|"pet"|"caster"|"attacker"|"tank"|"healer"): true when it can go' },
    { name = "use", text = 'use("healthstone"|"potion"|"mana_potion"|"mana_gem"|"bandage"), or use("Any Item Name")' },
    { name = "pet_cast", text = 'pet_cast("Growl", "target"); pet_attack("attacker"); hold("why")' },
    { name = "alert", text = 'alert("Text", "red"): on screen, with a sound; set_target("attacker"); stop_cast()' },
    { name = "vars", text = "a table kept between ticks, shared by the class's code; now() is the clock; log(...) writes to the log" },
}
D.API_WORDS = {}
for _, w in ipairs({ "me", "target", "pet", "group", "fight", "where", "check", "known", "ready", "cooldown",
    "buff", "debuff", "situation", "place", "cast", "use", "pet_cast", "pet_attack", "hold", "vars", "now", "log",
    "buff_left", "buff_stacks", "debuff_left", "debuff_stacks", "has_item", "key", "alert", "set_target",
    "stop_cast" }) do
    D.API_WORDS[w] = true
end

return D

-- Jambix AIO / config -- static data. No dependencies, no behaviour.
--
-- Plain table, not a factory: nothing here needs the plugin bundle.

local M = {}

-- --- classification ---------------------------------------------------------
-- Ids from the game_object.get_classification contract.

M.CLASS_UNKNOWN     = -1
M.CLASS_NORMAL      = 0
M.CLASS_ELITE       = 1
M.CLASS_RARE_ELITE  = 2
M.CLASS_WORLD_BOSS  = 3
M.CLASS_RARE        = 4
M.CLASS_TRIVIAL     = 5
M.CLASS_MINUS       = 6

M.CLASSIFICATION_TAG = {
    [M.CLASS_ELITE]      = "Elite",
    [M.CLASS_RARE_ELITE] = "Rare Elite",
    [M.CLASS_WORLD_BOSS] = "Boss",
    [M.CLASS_RARE]       = "Rare",
    [M.CLASS_TRIVIAL]    = "Trivial",
    [M.CLASS_MINUS]      = "Minus",
}

M.CREATURE_CRITTER = 8

-- --- classes ----------------------------------------------------------------
--
-- WoW's own class ids, unchanged across every client this runs on. The
-- shared enums module is asked first wherever a class id is mapped, and this
-- table answers when that module is missing or renumbered -- which is how
-- the rotation has always found its class, and how the class portrait, the
-- class colours and the role badge now do too. Trusting the enums alone
-- shipped a portrait with nothing inside it: no name for the id, so no art,
-- no initial, no role.

M.CLASS_IDS = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5,
    DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10,
    DRUID = 11, DEMONHUNTER = 12, EVOKER = 13,
}

--- Numeric class id for a class name: the enums where they answer, the
--- table above otherwise.
---@param enums table|nil
---@param name string
---@return integer|nil
function M.class_id_for(enums, name)
    if enums and type(enums.class_id) == "table" and type(enums.class_id[name]) == "number" then
        return enums.class_id[name]
    end
    return M.CLASS_IDS[name]
end

-- --- palette ----------------------------------------------------------------

M.CLASS_RGB = {
    WARRIOR     = { 199, 156, 110 },
    PALADIN     = { 245, 140, 186 },
    HUNTER      = { 171, 212, 115 },
    ROGUE       = { 255, 245, 105 },
    PRIEST      = { 255, 255, 255 },
    DEATHKNIGHT = { 196,  31,  59 },
    SHAMAN      = {   0, 112, 222 },
    MAGE        = { 105, 204, 240 },
    WARLOCK     = { 148, 130, 201 },
    MONK        = {   0, 255, 150 },
    DRUID       = { 255, 125,  10 },
    DEMONHUNTER = { 163,  48, 201 },
    EVOKER      = {  51, 147, 127 },
}

-- --- categories -------------------------------------------------------------
--
-- Each gets its own toggle, colour and range. A single global range cannot
-- express "rares at 150 yards but normal mobs at 40", which is what people
-- actually want.
--
-- `key` is baked into every widget id on the Categories page, so a key is
-- permanent. Labels are free to change.

-- `plain` marks a category whose colour carries no information of its own. A
-- rare is gold because it is a rare, and that is worth more than knowing it is
-- attackable; a normal NPC is just an NPC, so its colour is free to say
-- something -- whether you can attack it, or how dangerous its level is. The
-- unit colour mode applies to the plain categories only, which is why turning
-- it on does not cost you the gold rares or the blue guide targets.

-- `prio` is what survives a cap. When more things are in range than the mark
-- limit allows, the overlay keeps the ones that matter and drops the ones that
-- do not -- a rare at ninety yards outranks the boar at thirty. It is also the
-- order marks are submitted in, so the draw budget runs out on the boars.
--
-- Normal NPCs ship ON, at a range that reaches what you can see. They used to
-- ship off at 45 yards on the theory that they are noise, and the result was
-- an overlay that appeared not to work: a field of mobs in plain view, none of
-- them marked, and nothing on screen saying why. Reaction colouring and the
-- mark limit are what make a full field readable instead of noisy.

M.CATEGORIES = {
    { key = "hostile_player",  label = "Hostile players",      on = true,  rgb = { 235,  70,  70 }, range = 100, prio = 80 },
    { key = "friendly_player", label = "Friendly players",     on = false, rgb = {  90, 200, 120 }, range = 60,  prio = 20 },
    -- Off by default, all three: they are the marks that crowd a town or a
    -- group and answer nothing about what is about to hit you. A quest giver
    -- or guide npc is still marked -- quest and guide outrank these.
    -- Players in your group. They have frames and plates of their own.
    { key = "party",           label = "Party members",        on = false, rgb = { 100, 180, 255 }, range = 100, prio = 15 },
    -- Hunter and warlock pets, minions, guardians -- yours and everyone's.
    { key = "pet",             label = "Pets and minions",     on = false, rgb = { 150, 200, 150 }, range = 60,  prio = 10, plain = true },
    -- NPCs you cannot attack: guards, vendors, trainers, flight masters.
    { key = "friendly_npc",    label = "Friendly NPCs (cannot be attacked)", on = false, rgb = {  95, 205, 125 }, range = 60, prio = 12, plain = true },
    { key = "boss",            label = "Bosses",               on = true,  rgb = { 200, 110, 240 }, range = 150, prio = 100 },
    { key = "rare",            label = "Rares",                on = true,  rgb = { 255, 205,  80 }, range = 150, prio = 95 },
    { key = "elite",           label = "Elites",               on = true,  rgb = { 245, 150,  60 }, range = 100, prio = 60, plain = true },
    { key = "normal",          label = "Normal NPCs",          on = true,  rgb = { 220, 120, 120 }, range = 100, prio = 30, plain = true },
    { key = "critter",         label = "Critters",             on = false, rgb = { 140, 140, 150 }, range = 30,  prio = 5,  plain = true },
    { key = "corpse",          label = "Lootable / skinnable", on = true,  rgb = { 210, 180, 120 }, range = 80,  prio = 55 },
    { key = "herb",            label = "Herbs",                on = true,  rgb = { 120, 235, 130 }, range = 120, prio = 50 },
    { key = "ore",             label = "Ore veins",            on = true,  rgb = { 225, 175,  95 }, range = 120, prio = 50 },
    { key = "container",       label = "Chests & containers",  on = true,  rgb = { 240, 220, 120 }, range = 120, prio = 50 },
    { key = "quest",           label = "Quest targets",        on = true,  rgb = { 255, 225,  80 }, range = 120, prio = 90 },
    { key = "guide",           label = "Guide targets",        on = true,  rgb = { 120, 200, 255 }, range = 150, prio = 92 },
    { key = "object",          label = "Other objects",        on = false, rgb = { 110, 220, 215 }, range = 80,  prio = 25 },
}

M.CATEGORY_BY_KEY = {}
for i = 1, #M.CATEGORIES do
    M.CATEGORY_BY_KEY[M.CATEGORIES[i].key] = M.CATEGORIES[i]
end

-- --- overlay elements -------------------------------------------------------
--
-- One row per mark the overlay can paint. The menu declares a toggle from each
-- row; modules/esp/elements.lua supplies the drawing for each `key`. Both read
-- this table, so a mark cannot exist with no way to switch it off, and a
-- toggle cannot exist with nothing behind it.
--
-- `key` is the widget id and is therefore permanent. Order is paint order
-- within a layer.
--
-- `kind` is what the mark applies to: a unit or a world object.
--
-- `lod` is the LEAST detail tier the mark is drawn at, when detail falloff is
-- on: "far" is always, "mid" stops at the middle range, "full" is nearest
-- only. A health bar four pixels wide at a hundred yards is not information,
-- so it stops at "mid".
--
-- `below` marks a row that moves UNDER A UNIT'S FEET while `esp_rows_below`
-- is on (the default), and gives its order there, nearest the model first.
-- The space above a head is where every nameplate addon draws, and on
-- 2026-09-30 a Plater-style plate was seen covering the level, distance and
-- line-of-sight rows completely. Under the feet nothing of the game's sits.
-- The name, portrait, raid icon and health bar stay above: they say what the
-- thing IS, and the plate says the same, so losing them under it costs
-- nothing. Objects have no plate, and keep every row above.

-- THE SHAPE OF A MARK
--
-- Everything used to go on one line -- badge, name, level, health, distance --
-- which at forty yards is a sentence of red text lying across the creature it
-- describes. A mark is now a small stack hung above the model's head:
--
--     Razormane Thornweaver      the name, in the mark's colour
--     ===================        a health bar, only when hurt
--     11 - 88y                   the rest, dimmer and smaller
--     Kill the Quilboar 3/8      one line per quest that wants it
--
-- The hierarchy is the point: the name is what you read, and the rest is
-- there when you look for it rather than competing for the same attention.

M.ELEMENTS = {
    { key = "show_box",       label = "Bounding box",         default = false, kind = "unit",   lod = "full" },
    -- The raid icon a party leader put on it, at the very top of the stack,
    -- where the game itself hangs one over a nameplate. At every distance:
    -- a skull at a hundred yards is exactly when it is worth seeing.
    { key = "show_raid_marker", label = "Raid marker", default = true, kind = "unit", lod = "far" },
    -- First, because it sits at the top of the stack: a round class portrait
    -- above a player's name, with a tank / healer / damage badge on its rim.
    -- Players only; a boar has no class.
    { key = "show_class_icon", label = "Class and role icon (players)", default = true, kind = "unit", lod = "mid" },
    -- The same portrait for a creature: its type -- beast, humanoid, undead
    -- -- in the mark's colour, badged caster or melee.
    { key = "show_creature_icon", label = "Creature icon (NPCs)", default = true, kind = "unit", lod = "mid" },
    { key = "show_label",     label = "Name",                 default = true,  kind = "unit",   lod = "far" },
    { key = "show_bar",       label = "Health bar",           default = true,  kind = "unit",   lod = "mid" },
    -- Blue, under the health bar, for anything with a mana pool: a caster
    -- mob's mana is how long it keeps casting. Nothing for a mob without one.
    { key = "show_power",     label = "Mana bar (anything with mana)", default = true, kind = "unit", lod = "mid" },
    -- Under the health bar, where every nameplate puts one. White when it
    -- can be interrupted, red when it cannot: "kick this" and "do not waste
    -- the kick" are the two answers, and the colour gives them at a glance.
    { key = "show_cast",      label = "Cast bar (white: interruptible, red: not)", default = true, kind = "unit", lod = "mid", below = 1 },
    { key = "show_details",   label = "Level, distance, health", default = true, kind = "unit", lod = "mid", below = 5 },
    -- What it is doing to whom: on you, on your pet, on a party member,
    -- crowd-controlled, tagged by someone else. Only when there is something
    -- to say, so most marks never grow this row.
    { key = "show_status",    label = "Status: on you, on your pet, crowd control, tapped", default = true, kind = "unit", lod = "mid", below = 3 },
    -- Your threat on it and where that ranks you in the group, ranked the
    -- way Details!' Tiny Threat ranks it: "threat 72%, #2 of 5", or
    -- "aggro, #1 of 5, next 85%" when it is yours. From JCore's threat
    -- service, which asks the client's threat table about every member. On
    -- every mob you have threat on, solo included: "aggro, #1 of 1" on what
    -- is hitting you, and your place behind your pet on what it holds.
    { key = "show_threat",    label = "Threat: your % and rank in the group (as Tiny Threat)", default = true, kind = "unit", lod = "mid", below = 4 },
    { key = "node_label",     label = "Node names",           default = true,  kind = "object", lod = "far" },
    { key = "node_ring",      label = "Node ground rings",    default = true,  kind = "object", lod = "far" },
    -- After both name rows, because it belongs under whatever the thing is
    -- called -- and this table's order is the order the stack is drawn in,
    -- for units and objects alike.
    { key = "show_quest_tag", label = "Which quest, and progress", default = true, kind = "any", lod = "mid", below = 6 },
    -- The selected target only: whether it is in line of sight and inside
    -- this class's reach, in words and a colour, so "why is nothing firing"
    -- is answered by looking at the mob. Last, so it is the bottom row of
    -- the stack, nearest the head.
    { key = "show_reach",     label = "Target: line of sight and range", default = true, kind = "unit", lod = "mid", below = 2 },
    -- On the ground rather than in the stack: a ring under everything that
    -- has you targeted, so "which of these six is on me" is answered by
    -- looking at their feet.
    { key = "show_aggro",     label = "Red ring under anything targeting you", default = true, kind = "unit", lod = "far" },
    -- On the ground too (1.85.0): a ring just outside that one under anything
    -- casting, filling as the cast runs (a channel empties), in the cast
    -- bar's colour and turning red as it closes.
    { key = "show_cast_ring", label = "Ring on the ground filling as a cast runs", default = true, kind = "unit", lod = "far" },
    -- A pillar of light (1.88.0, JCore's beacon_3d) on a rare, a boss, a
    -- quest or guide target, or a corpse with loot on it, once it is further
    -- off than `esp_beacon_from`: the user, 2026-10-08, "Far things as
    -- beacons". Units only: modules/beacons.lua puts the pillars on nodes.
    -- 1.7.6: off by default -- a pillar is a curtain, and the user, 2026-10-10:
    -- "enemies should not have Curtain up by default".
    { key = "show_beacon",    label = "Pillars of light on far rares, bosses, quest targets and loot", default = false, kind = "unit", lod = "far" },
    -- A line from an attacker to whoever it is after -- you, your pet, a
    -- party member -- for as long as it is still on its way. Once it has
    -- arrived the line is under its own model and says nothing, so it goes.
    { key = "show_target_line", label = "Lines from attackers on their way to you or your group", default = true, kind = "unit", lod = "far" },
    { key = "show_tracer",    label = "Tracers",              default = false, kind = "unit",   lod = "mid" },
}

-- --- box styles ---------------------------------------------------------------
--
-- The dropdown `box_style`, in this order. Corners is the default because
-- thirty closed rectangles are a wall of lines; the corners read as a mark at
-- the same glance and leave the creature visible inside them.

M.BOX_STYLES = {
    "Corner brackets",
    "Full box",
    "3D box",
    "Curtain",
}

M.BOX_CORNERS = 1
M.BOX_FULL    = 2
M.BOX_3D      = 3
-- 1.88.0: a short curtain round the unit in its colour (JCore's curtain_3d),
-- the default since the user asked for every ESP in the new look. The other
-- three stay for anyone who set one. 1.7.6: curtains are off by default, so
-- the corners are the default again (main.lua's CURTAINS moved a saved
-- curtain to them once).
M.BOX_CURTAIN = 4
M.BOX_DEFAULT = M.BOX_CORNERS

-- --- cast bar and status ------------------------------------------------------

M.CAST_RGB = {
    interruptible = { 240, 240, 245 },
    locked        = { 230,  80,  70 },
}

-- A cast longer than this is not a cast: it is a latched flag, or a clock in
-- another base. Tame Beast is twenty seconds, so the line sits above it.
M.CAST_MAX_SECONDS = 30

-- The status row says one thing and is coloured by the most urgent.
M.STATUS_RGB = {
    me      = { 240,  80,  70 },    -- it is on you
    group   = { 245, 175,  70 },    -- on your pet or a party member
    control = { 120, 200, 255 },    -- crowd-controlled: do not break it
    tapped  = { 150, 150, 150 },    -- somebody else's kill
    quiet   = { 165, 168, 178 },    -- in combat, mounted
}

-- The threat row. Green while comfortable, amber closing on the holder, red
-- within pulling distance. On a mob that is yours the same three answer "how
-- close is the runner-up" -- for a tank. For anyone else holding it the row
-- is red outright: a mage holding the boss is the emergency, not a margin.
M.THREAT_RGB = {
    safe    = { 105, 200, 115 },
    close   = { 230, 190,  85 },
    pulling = { 240,  80,  70 },
}
M.THREAT_CLOSE = 70      -- percent: amber from here
M.THREAT_PULLING = 90    -- percent: red from here

-- What a mob tagged by someone else is drawn in: the grey the client's own
-- nameplate turns, because no kill credit and no loot is the whole story.
M.TAPPED_RGB = { 150, 150, 150 }

-- An attacker this close to its target has arrived, and the line between
-- them would be drawn under its own model.
M.TARGET_LINE_MIN = 6

-- --- raid markers -------------------------------------------------------------
--
-- By get_target_marker_index. The art is the client's own chat-icon file for
-- each marker; the colour and name are the fallback while it loads or where
-- the archives cannot be read.

-- --- nameplates ----------------------------------------------------------------
--
-- What the mark does when a nameplate addon's plate is up over the unit. The
-- plate sits exactly where the mark hangs, and draws its own auras above its
-- bar -- outside the rectangle the client reports -- so "on top of the plate"
-- can still be covered. Under the feet nothing of the game's ever sits, which
-- is why that is the default. The dropdown `esp_plate_mode`, in this order.

M.PLATE_MODES = {
    "Move the mark under the feet",
    "Sit on top of the plate",
    "Leave it above the head",
}

M.PLATE_BELOW  = 1
M.PLATE_ABOVE  = 2
M.PLATE_IGNORE = 3

-- The pill a dead unit gets in place of its reaction: no longer friend or foe.
M.DEAD_RGB = { 170, 170, 175 }

-- `shape` is the stand-in when the archives cannot be read: Plater's own
-- marker shapes, pale grey and made to be tinted, drawn in the marker's
-- colour. Each was decoded and looked at (addon_art_probe_test). Plater's
-- triangle points down; `flip` turns it the way the game's points.
M.RAID_MARKERS = {
    [1] = { name = "star",     rgb = { 255, 230,  60 }, shape = "Plater/media/star_full_64.tga" },
    [2] = { name = "circle",   rgb = { 255, 150,  40 }, shape = "Plater/media/sphere_full_64.tga" },
    [3] = { name = "diamond",  rgb = { 210,  90, 240 }, shape = "Plater/media/diamond_64.tga" },
    [4] = { name = "triangle", rgb = {  80, 220,  80 }, shape = "Plater/media/triangle_64.tga", flip = true },
    [5] = { name = "moon",     rgb = { 200, 215, 230 }, shape = "Plater/media/moon_64.tga" },
    [6] = { name = "square",   rgb = {  70, 150, 255 }, shape = "Plater/media/square_64.tga" },
    [7] = { name = "cross",    rgb = { 240,  60,  50 }, shape = "Plater/media/x_64.tga" },
    [8] = { name = "skull",    rgb = { 245, 245, 245 }, shape = "Plater/media/skullbones_64.tga" },
}

---@param index integer 1..8
---@return string ref
function M.raid_marker_ref(index)
    return "game:Interface/TargetingFrame/UI-RaidTargetingIcon_" .. index .. ".blp"
end

-- --- the game's own UI art ----------------------------------------------------
--
-- Textures the client paints its own frames with, out of its archives. Each
-- was extracted from the 1.15.9 archives on 2026-10-01 and LOOKED AT before
-- any coordinate here was written (tools/jtest/tests/casc_probe_art_test.lua
-- writes them out as PNGs), so a crop names the part of the sheet that holds
-- the picture rather than a guess at it.
--
-- Cells are left, right, top, bottom, as fractions -- the client's
-- SetTexCoord order, like the class sheet above.

M.GAME_UI_SHEETS = {
    -- The state icons by the player portrait: resting top left, the
    -- crossed swords of combat top right; the bottom row is their glows.
    state = {
        ref = "game:Interface/CharacterFrame/UI-StateIcon.blp",
        cells = { resting = { 0, 0.5, 0, 0.5 }, combat = { 0.5, 1, 0, 0.5 } },
    },
    -- The gold dragon a default nameplate curls round an elite's level. It
    -- fills the left half of a 64 x 32 sheet; the right half is empty.
    elite = {
        ref = "game:Interface/Tooltips/EliteNameplateIcon.blp",
        cells = { dragon = { 0, 0.5, 0, 1 } },
    },
    -- The PvP badges on the target frame. Each emblem sits in the top-left
    -- 40 x 40 of its 64 x 64 square.
    horde = {
        ref = "game:Interface/TargetingFrame/UI-PVP-Horde.blp",
        cells = { emblem = { 0, 0.625, 0, 0.625 } },
    },
    alliance = {
        ref = "game:Interface/TargetingFrame/UI-PVP-Alliance.blp",
        cells = { emblem = { 0, 0.625, 0, 0.625 } },
    },
}

M.GAME_UI = {
    -- The skull the target frame shows in place of a level: bosses, ??, and
    -- anything ten or more levels above you.
    skull = "game:Interface/TargetingFrame/UI-TargetingFrame-Skull.blp",
    -- The gossip window's quest marks: the "!" of a quest to take, the "?"
    -- of one to hand in.
    quest_available = "game:Interface/GossipFrame/AvailableQuestIcon.blp",
    quest_active = "game:Interface/GossipFrame/ActiveQuestIcon.blp",
    -- The grey gradient every status bar in the game is painted with,
    -- tinted to the bar's colour. 64 x 8.
    status_bar = "game:Interface/TargetingFrame/UI-StatusBar.blp",
}

-- WHEN THE ARCHIVES CANNOT BE READ. In the game on 2026-10-01 the archive
-- reader had never produced a file -- scripts_data/jcore/game was empty, and
-- the Debug page's "Game archives" line names why -- while web icons and the
-- installed addons' files loaded fine. So every piece of UI art above has a
-- stand-in that does load there, tried in order after the game's own:
-- { ref, addon?, tint = { r, g, b }? }. An addon's file is used only when the
-- addon is installed; a tint colours a pale shape.
M.GAME_UI_FALLBACK = {
    skull = {
        { "addon:Plater/media/skullbones_64.tga", "Plater", tint = { 230, 230, 235 } },
        { "icon:inv_misc_bone_humanskull_01" },
    },
    ["elite.dragon"] = { { "icon:inv_misc_head_dragon_01" } },
    ["horde.emblem"] = {
        { "addon:Questie/Icons/icon_horde.tga", "Questie" },
        { "addon:RXPGuides/Textures/rxp_horde-64.blp", "RXPGuides" },
        { "icon:inv_bannerpvp_01" },
    },
    ["alliance.emblem"] = {
        { "addon:Questie/Icons/icon_alliance.tga", "Questie" },
        { "addon:RXPGuides/Textures/rxp_alliance-64.blp", "RXPGuides" },
        { "icon:inv_bannerpvp_02" },
    },
    ["state.combat"] = { { "icon:ability_dualwield" } },
    status_bar = { { "addon:WeakAuras/Media/Textures/Statusbar_Clean.blp", "WeakAuras" } },
}

-- What a gathering node is, as the icon of the profession that gathers it.
M.NODE_ICON = {
    herb = "trade_herbalism",
    ore = "trade_mining",
    container = "inv_box_02",
    object = "inv_misc_bag_10",
}

-- Which side a player's race is on, for the faction emblem.
-- The allied races and later ones are Retail's; a Pandaren picks a side, so
-- the two halves have ids of their own (24, the neutral one, has none).
M.RACE_FACTION = {
    [1] = "alliance", [3] = "alliance", [4] = "alliance", [7] = "alliance", [11] = "alliance",
    [2] = "horde", [5] = "horde", [6] = "horde", [8] = "horde", [9] = "horde", [10] = "horde",
    [22] = "alliance", [25] = "alliance", [29] = "alliance", [30] = "alliance",
    [32] = "alliance", [34] = "alliance", [37] = "alliance", [52] = "alliance", [85] = "alliance",
    [26] = "horde", [27] = "horde", [28] = "horde", [31] = "horde", [35] = "horde",
    [36] = "horde", [70] = "horde", [84] = "horde",
}

-- --- tags ---------------------------------------------------------------------
--
-- WHY A THING IS MARKED, as a chip in front of its name. These used to be the
-- words "quest", "guide", "loot" and "skin" glued to the front of the name in
-- the name's own colour, and on 2026-09-30 "quest Kawahmwhaz" read as a player
-- called that. A chip is a word in capitals on its own dark pill, outlined in
-- its family's colour, with the icon the matching addon itself uses beside it:
--
--   quest   yellow   what the quest wants done: PICK UP (!), TURN IN (?),
--                    KILL, COLLECT (it drops the item), USE (an object) --
--                    Questie's own icons for each
--   guide   blue     RestedXP's current step wants it -- RestedXP's logo
--   loot    green    a corpse with loot on it
--   skin    brown    a corpse you can skin
--
-- `art` lists sources best first, each { ref, addon? }: an addon's icon is
-- used only when that addon is installed. Game icons are written out in full
-- rather than through M.game_icon, which is defined further down this file.
-- Four families, four hues, so the colour alone tells them apart before the
-- word is read.

M.TAG_RGB = {
    quest = { 255, 210,  60 },
    guide = {  90, 185, 255 },
    loot  = { 125, 225, 110 },
    skin  = { 215, 150,  90 },
    tame  = { 185, 140, 255 },     -- a beast a hunter can tame (1.72.0)
}

M.TAGS = {
    pick_up = { word = "PICK UP", family = "quest", art = { { "game:Interface/GossipFrame/AvailableQuestIcon.blp" }, { "addon:Questie/Icons/available.blp", "Questie" } } },
    turn_in = { word = "TURN IN", family = "quest", art = { { "game:Interface/GossipFrame/ActiveQuestIcon.blp" }, { "addon:Questie/Icons/complete.blp", "Questie" } } },
    kill    = { word = "KILL",    family = "quest", art = { { "addon:Questie/Icons/slay.blp", "Questie" } } },
    collect = { word = "COLLECT", family = "quest", art = { { "addon:Questie/Icons/loot.blp", "Questie" } } },
    use     = { word = "USE",     family = "quest", art = { { "addon:Questie/Icons/object.blp", "Questie" } } },
    quest   = { word = "QUEST",   family = "quest", art = { { "game:Interface/Icons/inv_misc_note_01.blp" }, { "icon:inv_misc_note_01" } } },
    guide   = { word = "GUIDE",   family = "guide", art = { { "addon:RXPGuides/Textures/rxp_logo-64.blp", "RXPGuides" } } },
    loot    = { word = "LOOT",    family = "loot",  art = { { "game:Interface/Icons/inv_misc_coin_01.blp" }, { "icon:inv_misc_coin_01" } } },
    skin    = { word = "SKIN",    family = "skin",  art = { { "game:Interface/Icons/inv_misc_pelt_wolf_01.blp" }, { "icon:inv_misc_pelt_wolf_01" } } },
    tame    = { word = "TAME",    family = "tame",  art = { { "game:Interface/Icons/ability_hunter_beasttaming.blp" }, { "icon:ability_hunter_beasttaming" } } },
}

-- When a quest mark serves several quests, the chip shows the most pressing
-- thing to do there: hand a quest in before picking one up, and so on.
M.QUEST_TAG_ORDER = { "turn_in", "pick_up", "kill", "collect", "use", "quest" }

-- --- class and spec art -----------------------------------------------------
--
-- THE GAME'S OWN IMAGES, OUT OF ITS ARCHIVES. JCore's casc service reads the
-- client's data store, so the sheets and icons below are the files the
-- client itself draws from: the class icon sheet its frames use, the role
-- circles it hangs on party portraits, and the talent-tab icons. A "game:"
-- reference names a file by its game path; the registry extracts it once
-- per client build and keeps the bytes under scripts_data.
--
-- Two fallbacks stand behind that, in order. Details and Plater ship
-- pixel-exact copies of the class crest and spec sheets as TGA files in the
-- WoW folder, which the loader reads directly. And the icon CDN serves the
-- same icons by name. A portrait picks the first source that has loaded,
-- so it is never empty for want of one of them.
--
-- Coordinates are in the order the client's SetTexCoord takes them: left,
-- right, top, bottom, as fractions of the sheet.

-- The client's class icon sheet: 64px cells in a 4x4 grid, the coordinates
-- the client's own CLASS_ICON_TCOORDS table names. Classic Era's sheet holds
-- the nine classes it has; a cell for a class the client lacks is empty and
-- the portrait falls through to the next source.
M.GAME_CLASS_SHEET = {
    ref = "game:Interface/Glues/CharacterCreate/UI-CharacterCreate-Classes.blp",
    cells = {
        WARRIOR     = { 0,          0.25,       0,    0.25 },
        MAGE        = { 0.25,       0.49609375, 0,    0.25 },
        ROGUE       = { 0.49609375, 0.7421875,  0,    0.25 },
        DRUID       = { 0.7421875,  0.98828125, 0,    0.25 },
        HUNTER      = { 0,          0.25,       0.25, 0.5 },
        SHAMAN      = { 0.25,       0.49609375, 0.25, 0.5 },
        PRIEST      = { 0.49609375, 0.7421875,  0.25, 0.5 },
        WARLOCK     = { 0.7421875,  0.98828125, 0.25, 0.5 },
        PALADIN     = { 0,          0.25,       0.5,  0.75 },
        DEATHKNIGHT = { 0.25,       0.49609375, 0.5,  0.75 },
        MONK        = { 0.49609375, 0.7421875,  0.5,  0.75 },
        DEMONHUNTER = { 0.7421875,  0.98828125, 0.5,  0.75 },
        EVOKER      = { 0,          0.25,       0.75, 1 },
    },
}

-- The client's role circles, the ones on party portraits: a 64px sheet of
-- 19px circles, at the coordinates GetTexCoordsForRoleSmallCircle answers.
M.GAME_ROLE_SHEET = {
    ref = "game:Interface/LFGFrame/UI-LFG-ICON-PORTRAITROLES.blp",
    cells = {
        tank   = { 0,       19 / 64, 22 / 64, 41 / 64 },
        healer = { 20 / 64, 39 / 64, 1 / 64,  20 / 64 },
        dps    = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
    },
}

--- A game icon by its Interface\Icons name.
---@param slug string
---@return string ref
function M.game_icon(slug)
    return "game:Interface/Icons/" .. slug .. ".blp"
end

-- The talent-tab icon of each specialisation, by the icon name the client
-- keeps it under. The tree clients' own tab art for the nine classes; the
-- later classes use the icons their spec pickers show, which an older
-- client will not have -- and then the badge falls through.
M.SPEC_ICON = {
    [71] = "ability_rogue_eviscerate", [72] = "ability_warrior_innerrage", [73] = "inv_shield_06",
    [65] = "spell_holy_holybolt", [66] = "spell_holy_devotionaura", [70] = "spell_holy_auraoflight",
    [253] = "ability_hunter_beasttaming", [254] = "ability_marksmanship", [255] = "ability_hunter_swiftstrike",
    [259] = "ability_rogue_eviscerate", [260] = "ability_backstab", [261] = "ability_stealth",
    [256] = "spell_holy_wordfortitude", [257] = "spell_holy_holybolt", [258] = "spell_shadow_shadowwordpain",
    [262] = "spell_nature_lightning", [263] = "spell_nature_lightningshield", [264] = "spell_nature_magicimmunity",
    [62] = "spell_holy_magicalsentry", [63] = "spell_fire_flamebolt", [64] = "spell_frost_frostbolt02",
    [265] = "spell_shadow_deathcoil", [266] = "spell_shadow_metamorphosis", [267] = "spell_shadow_rainoffire",
    [102] = "spell_nature_starfall", [103] = "ability_racial_bearform", [104] = "ability_racial_bearform",
    [105] = "spell_nature_healingtouch",
    [250] = "spell_deathknight_bloodpresence", [251] = "spell_deathknight_frostpresence", [252] = "spell_deathknight_unholypresence",
    [268] = "spell_monk_brewmaster_spec", [269] = "spell_monk_windwalker_spec", [270] = "spell_monk_mistweaver_spec",
    [577] = "ability_demonhunter_specdps", [581] = "ability_demonhunter_spectank", [1480] = "ability_demonhunter_specdps",
    [1467] = "classicon_evoker_devastation", [1468] = "classicon_evoker_preservation", [1473] = "classicon_evoker_augmentation",
}

-- The addon copies, for a client whose archives cannot be read. Details
-- carries the class crest sheet (256px, crests in its top-left quarter,
-- hence the halves) and the spec sheet; Plater the spec sheet.

M.CLASS_SHEET = {
    addon = "Details",
    ref = "addon:Details/images/classes_small_alpha.tga",
    cells = {
        WARRIOR     = { 0,              0.25 / 2,       0,        0.25 / 2 },
        MAGE        = { 0.25 / 2,       0.49609375 / 2, 0,        0.25 / 2 },
        ROGUE       = { 0.49609375 / 2, 0.7421875 / 2,  0,        0.25 / 2 },
        DRUID       = { 0.7421875 / 2,  0.98828125 / 2, 0,        0.25 / 2 },
        EVOKER      = { 0.50390625,     0.625,          0,        0.125 },
        HUNTER      = { 0,              0.25 / 2,       0.25 / 2, 0.5 / 2 },
        SHAMAN      = { 0.25 / 2,       0.49609375 / 2, 0.25 / 2, 0.5 / 2 },
        PRIEST      = { 0.49609375 / 2, 0.7421875 / 2,  0.25 / 2, 0.5 / 2 },
        WARLOCK     = { 0.7421875 / 2,  0.98828125 / 2, 0.25 / 2, 0.5 / 2 },
        PALADIN     = { 0,              0.25 / 2,       0.5 / 2,  0.75 / 2 },
        DEATHKNIGHT = { 0.25 / 2,       0.5 / 2,        0.5 / 2,  0.75 / 2 },
        MONK        = { 0.5 / 2,        0.73828125 / 2, 0.5 / 2,  0.75 / 2 },
        DEMONHUNTER = { 0.73828126 / 2, 1 / 2,          0.5 / 2,  0.75 / 2 },
    },
}

-- The first installed one is used.
M.SPEC_SHEETS = {
    { addon = "Details", ref = "addon:Details/images/spec_icons_normal_alpha.tga" },
    { addon = "Plater",  ref = "addon:Plater/images/spec_icons_normal_alpha.tga" },
}

-- 512px sheet, 64px cells, keyed by the client's specialisation id.
local function cell(col, row, nudge)
    return { col * 64 / 512 + (nudge or 0), (col + 1) * 64 / 512, row * 64 / 512, (row + 1) * 64 / 512 }
end

M.SPEC_CELLS = {
    [250] = cell(0, 0), [251] = cell(1, 0), [252] = cell(2, 0),               -- death knight: blood, frost, unholy
    [102] = cell(3, 0), [103] = cell(4, 0), [104] = cell(5, 0), [105] = cell(6, 0), -- druid: balance, feral, guardian, restoration
    [253] = cell(7, 0), [254] = cell(0, 1), [255] = cell(1, 1),               -- hunter: beast mastery, marksmanship, survival
    [62] = cell(2, 1, 0.001953125), [63] = cell(3, 1), [64] = cell(4, 1),     -- mage: arcane, fire, frost
    [268] = cell(5, 1), [270] = cell(6, 1), [269] = cell(7, 1),               -- monk: brewmaster, mistweaver, windwalker
    [65] = cell(0, 2), [66] = cell(1, 2), [70] = cell(2, 2, 0.001953125),     -- paladin: holy, protection, retribution
    [256] = cell(3, 2), [257] = cell(4, 2), [258] = cell(5, 2, 0.0078125),    -- priest: discipline, holy, shadow
    [259] = cell(6, 2), [260] = cell(7, 2), [261] = cell(0, 3),               -- rogue: assassination, combat, subtlety
    [262] = cell(1, 3), [263] = cell(2, 3), [264] = cell(3, 3),               -- shaman: elemental, enhancement, restoration
    [265] = cell(4, 3), [266] = cell(5, 3), [267] = cell(6, 3),               -- warlock: affliction, demonology, destruction
    [71] = cell(7, 3), [72] = cell(0, 4), [73] = cell(1, 4),                  -- warrior: arms, fury, protection
    [577] = cell(2, 4), [581] = cell(3, 4), [1480] = cell(7, 4),              -- demon hunter: havoc, vengeance, devourer
    [1467] = cell(4, 4), [1468] = cell(5, 4), [1473] = cell(6, 4),            -- evoker: devastation, preservation, augmentation
}

-- The spec a class is playing for a given role, when the client will not say
-- (the tree clients have no spec ids). Classic's usual choices: a levelling
-- mage is frost, a levelling warlock is affliction, a damage druid is feral
-- unless Moonkin Form says balance -- the tells in ROLE_TELLS override this.
M.ROLE_SPEC = {
    WARRIOR     = { tank = 73,  dps = 71 },
    PALADIN     = { tank = 66,  healer = 65,  dps = 70 },
    HUNTER      = { dps = 253 },
    ROGUE       = { dps = 260 },
    PRIEST      = { healer = 257, dps = 258 },
    DEATHKNIGHT = { tank = 250, dps = 251 },
    SHAMAN      = { healer = 264, dps = 263 },
    MAGE        = { dps = 64 },
    WARLOCK     = { dps = 265 },
    MONK        = { tank = 268, healer = 270, dps = 269 },
    DRUID       = { tank = 104, healer = 105, dps = 103 },
    DEMONHUNTER = { tank = 581, dps = 577 },
    EVOKER      = { healer = 1468, dps = 1467 },
}

-- --- role badge --------------------------------------------------------------
--
-- Drawn around the spec icon when the sheet is there, and as a lettered disc
-- when it is not.

M.ROLE_RGB = {
    tank   = {  95, 150, 235 },
    healer = {  95, 205, 125 },
    dps    = { 225,  85,  75 },
}

M.ROLE_LETTER = { tank = "T", healer = "H", dps = "D" }

-- Forms, stances and auras that only one role uses. Spell ids, every rank
-- the tree clients have; a row's first hit wins, so the certain ones lead.
-- The third value is the spec the tell implies, where it implies one more
-- specific than ROLE_SPEC would guess. Anything not listed falls through to
-- ROLE_DEFAULT.
M.ROLE_TELLS = {
    WARRIOR = {
        { { 71 },                      "tank",   73 },  -- Defensive Stance
        { { 2457 },                    "dps",    71 },  -- Battle Stance: arms
        { { 2458 },                    "dps",    72 },  -- Berserker Stance: fury
    },
    DRUID = {
        { { 5487, 9634 },              "tank",   104 }, -- Bear, Dire Bear
        { { 768 },                     "dps",    103 }, -- Cat
        { { 24858 },                   "dps",    102 }, -- Moonkin
        { { 33891 },                   "healer", 105 }, -- Tree of Life
    },
    PRIEST = {
        { { 15473 },                   "dps",    258 }, -- Shadowform
    },
    PALADIN = {
        { { 25780 },                   "tank",   66 },  -- Righteous Fury
    },
    DEATHKNIGHT = {
        { { 48263 },                   "tank",   250 }, -- Blood Presence
        { { 48265 },                   "dps",    252 }, -- Unholy Presence
        { { 48266 },                   "dps",    251 }, -- Frost Presence
    },
    MONK = {
        { { 115069 },                  "tank",   268 }, -- Sturdy Ox
        { { 115070 },                  "healer", 270 }, -- Wise Serpent
    },
}

-- What a class is doing when nothing above says otherwise, and whether
-- that is a fact (a class with one job) or the role it usually plays in a
-- group (a hybrid in no telling form). The second value is `certain`.
M.ROLE_DEFAULT = {
    WARRIOR     = { "dps",    false },
    PALADIN     = { "healer", false },
    HUNTER      = { "dps",    true  },
    ROGUE       = { "dps",    true  },
    PRIEST      = { "healer", false },
    DEATHKNIGHT = { "dps",    false },
    SHAMAN      = { "healer", false },
    MAGE        = { "dps",    true  },
    WARLOCK     = { "dps",    true  },
    MONK        = { "dps",    false },
    DRUID       = { "healer", false },
    DEMONHUNTER = { "dps",    false },
    EVOKER      = { "dps",    false },
}

-- --- creature portraits -----------------------------------------------------
--
-- A creature has no class, so its portrait is its TYPE, by the ids
-- get_creature_type answers. Each is a game icon by name, from the same
-- registry as the class art; every name here was checked against the CDN
-- on 2026-09-27. Beasts get the wolf, humanoids the human head, undead the
-- raise-dead skull -- the most recognisable icon in the family rather than
-- the most literal.

M.CREATURE_ICON = {
    [1]  = "ability_hunter_pet_wolf",             -- Beast
    [2]  = "inv_misc_head_dragon_01",             -- Dragonkin
    [3]  = "spell_shadow_summonfelhunter",        -- Demon
    [4]  = "spell_frost_summonwaterelemental",    -- Elemental
    [5]  = "ability_warrior_titansgrip",          -- Giant
    [6]  = "spell_shadow_raisedead",              -- Undead
    [7]  = "inv_misc_head_human_01",              -- Humanoid
    [8]  = "inv_pet_ratcage",                     -- Critter
    [9]  = "inv_misc_enggizmos_27",               -- Mechanical
    [10] = "inv_misc_questionmark",               -- Not specified
    [11] = "spell_nature_strengthofearthtotem02", -- Totem
    [12] = "inv_box_petcarrier_01",               -- Non-combat pet
    [13] = "spell_shadow_plaguecloud",            -- Gas cloud
    [14] = "inv_box_petcarrier_01",               -- Wild pet
    [15] = "inv_misc_slime_01",                   -- Aberration
}

-- The initial shown until the art arrives.
M.CREATURE_TYPE_NAME = {
    [1] = "Beast", [2] = "Dragonkin", [3] = "Demon", [4] = "Elemental",
    [5] = "Giant", [6] = "Undead", [7] = "Humanoid", [8] = "Critter",
    [9] = "Mechanical", [10] = "Unknown", [11] = "Totem", [12] = "Pet",
    [13] = "Gas cloud", [14] = "Wild pet", [15] = "Aberration",
}

-- A creature's "role" is the one thing about it that changes how it is
-- fought and that the client will say outright: whether it has a mana pool.
-- A caster can be interrupted, kited and drained; a melee cannot.
M.NPC_ROLE_RGB = {
    caster = { 170, 120, 240 },
    melee  = { 235, 150,  70 },
}

M.NPC_ROLE_LETTER = { caster = "C", melee = "M" }

-- --- how it fights: melee, ranged, caster ------------------------------------
--
-- See modules/esp/fight.lua: what a mob is seen casting, kept per npc id
-- across sessions, and before that a guess from these.

M.FIGHT_RGB = {
    melee  = { 235, 150,  70 },
    ranged = { 120, 210, 110 },
    caster = { 175, 125, 245 },
}
M.FIGHT_WORD = { melee = "MELEE", ranged = "RANGED", caster = "CASTER" }
M.FIGHT_LETTER = { melee = "M", ranged = "R", caster = "C" }

-- Whole words in a mob's name that say it shoots or throws. A beast is
-- never ranged by its name: a "Ridge Huntress" is a cat.
M.FIGHT_RANGED_WORDS = {
    "archer", "bowman", "marksman", "rifleman", "gunner", "sharpshooter",
    "sniper", "hunter", "huntress", "headhunter", "thrower", "spearthrower",
    "deadeye", "crossbowman", "musketeer", "slinger",
}

-- Whole words that say it casts. Checked before the ranged words, because a
-- caster's spells are the thing to interrupt.
M.FIGHT_CASTER_WORDS = {
    "mage", "magus", "sorcerer", "sorceress", "wizard", "warlock", "shaman",
    "priest", "priestess", "mystic", "oracle", "seer", "witch", "hexer",
    "conjurer", "summoner", "cultist", "acolyte", "adept", "apprentice",
    "arcanist", "channeler", "invoker", "evoker", "enchanter", "enchantress",
    "spellbinder", "spellweaver", "thaumaturge", "druid", "cleric", "augur",
    "diviner", "elementalist", "illusionist", "healer", "necrolyte",
    "shadowmage", "earthbinder", "warmage", "battlemage",
}
-- Word endings: geomancer, necromancer, shadowcaster, runecaster,
-- stormcaller, tidecaller.
M.FIGHT_CASTER_SUFFIXES = { "mancer", "caster", "caller" }
-- Two-word names.
M.FIGHT_CASTER_PHRASES = { "witch doctor", "medicine man" }

-- A player's fighting style by specialisation id, as the role resolver
-- answers it (cfg.ROLE_SPEC, cfg.ROLE_TELLS).
M.FIGHT_SPEC = {
    [71] = "melee", [72] = "melee", [73] = "melee",              -- warrior
    [65] = "caster", [66] = "melee", [70] = "melee",             -- paladin
    [253] = "ranged", [254] = "ranged", [255] = "ranged",        -- hunter
    [259] = "melee", [260] = "melee", [261] = "melee",           -- rogue
    [256] = "caster", [257] = "caster", [258] = "caster",        -- priest
    [262] = "caster", [263] = "melee", [264] = "caster",         -- shaman
    [62] = "caster", [63] = "caster", [64] = "caster",           -- mage
    [265] = "caster", [266] = "caster", [267] = "caster",        -- warlock
    [102] = "caster", [103] = "melee", [104] = "melee", [105] = "caster", -- druid
    [250] = "melee", [251] = "melee", [252] = "melee",           -- death knight
    [268] = "melee", [269] = "melee", [270] = "caster",          -- monk
    [577] = "melee", [581] = "melee",                            -- demon hunter
    [1467] = "caster", [1468] = "caster", [1473] = "caster",     -- evoker
}

-- --- unit colour ------------------------------------------------------------
--
-- What the colour of a plain category's mark MEANS. The dropdown that picks
-- between these is `unit_color_mode`, and the order here is the order there.

M.COLOR_MODES = {
    "Category colour",
    "Reaction -- hostile, neutral, friendly",
    "Level difficulty",
}

M.COLOR_MODE_CATEGORY   = 1
M.COLOR_MODE_REACTION   = 2
M.COLOR_MODE_DIFFICULTY = 3

M.REACTION_RGB = {
    hostile  = { 235,  75,  75 },
    -- Orange, not yellow: yellow is the quest colour, and a neutral mob
    -- next to a quest mob has to read as a different thing.
    neutral  = { 245, 150,  50 },
    friendly = {  95, 205, 125 },
}

-- The game's own five bands, by the level difference between a unit and you.
M.DIFFICULTY_RGB = {
    impossible = { 255,  70,  70 },   -- skull, or five levels above
    hard       = { 255, 150,  60 },   -- three or four above
    even       = { 255, 220,  85 },   -- within two
    easy       = { 105, 210, 105 },   -- below you, still worth experience
    trivial    = { 155, 155, 155 },   -- grey
}

-- A level number's own colour, band by band, as the target frame paints it
-- (the game's QuestDifficultyColors). Only the number: DIFFICULTY_RGB above,
-- softer, colours whole marks.
M.LEVEL_RGB = {
    impossible = { 255,  26,  26 },
    hard       = { 255, 128,  64 },
    even       = { 255, 209,   0 },
    easy       = {  64, 191,  64 },
    trivial    = { 128, 128, 128 },
}

--- Which difficulty band a level sits in, relative to the player.
---
--- The green-to-grey boundary is WoW's own formula: below level 6 nothing is
--- grey, and from there the span widens with level. Getting it from the
--- formula rather than a flat "eight levels below" is what makes the grey
--- band agree with the game's own colouring at every level.
---@param unit_level integer
---@param player_level integer
---@return string band
function M.difficulty_band(unit_level, player_level)
    if not unit_level or unit_level <= 0 or not player_level or player_level <= 0 then
        return "even"
    end

    local delta = unit_level - player_level
    if delta >= 5 then return "impossible" end
    if delta >= 3 then return "hard" end
    if delta >= -2 then return "even" end

    local grey_at
    if player_level <= 5 then
        grey_at = 0
    elseif player_level <= 39 then
        grey_at = player_level - math.floor(player_level / 10) - 5
    elseif player_level <= 59 then
        grey_at = player_level - math.floor(player_level / 5) - 1
    else
        grey_at = player_level - 9
    end

    if unit_level <= grey_at then return "trivial" end
    return "easy"
end

-- --- quest colours ----------------------------------------------------------
--
-- Handed out in quest-log order so two quests on the same screen are told
-- apart by colour without either of them needing a setting. Deliberately not
-- the category palette: these mark a QUEST, not a kind of thing.

M.QUEST_PALETTE = {
    { 255, 225,  80 },
    { 120, 210, 255 },
    { 175, 245, 150 },
    { 255, 165, 115 },
    { 225, 165, 255 },
    { 130, 235, 215 },
    { 255, 190, 215 },
    { 205, 205, 130 },
}

M.ELEMENT_BY_KEY = {}
for i = 1, #M.ELEMENTS do
    M.ELEMENT_BY_KEY[M.ELEMENTS[i].key] = M.ELEMENTS[i]
end

-- --- the icon card (1.69.0) ------------------------------------------------
--
-- The Forever ESP draws every mark as an icon card (modules/esp/card.lua):
-- the game's own icons where the game has one, words only for names, numbers
-- and quest titles, each fact once. Its page (modules/esp/page_forever.lua)
-- is a Style dropdown and a grid of what to show; with advanced settings on,
-- every piece below and a detail level per category.
--
-- HOW MUCH A CATEGORY'S MARK SAYS, the dropdown `<key>_detail`, in this
-- order. The middle one keeps what tells you to act: the health bar and a
-- cast.
M.DETAILS = { "Everything", "Icon, name, health and casts", "Icon only" }
M.DETAIL_FULL, M.DETAIL_NAME, M.DETAIL_ICON = 1, 2, 3
-- The categories that start lighter than Everything: they crowd a town or a
-- group, and they are off by default anyway.
M.CATEGORY_DETAIL = { critter = 3, pet = 2, party = 2, friendly_player = 2 }

-- THE STYLE, the dropdown `esp_style`: every piece of a mark at once.
-- Changing a piece by hand makes it Custom.
M.ESP_STYLES = { "Minimal", "Clean", "Detailed", "Custom" }

-- The aurora around you (modules/aurora.lua, 1.86.0).
M.AURORA_COLORS = { "Reacts to the fight", "Class colour", "Aurora (turquoise to purple)", "Rainbow" }
M.STYLE_MINIMAL, M.STYLE_CLEAN, M.STYLE_DETAILED, M.STYLE_CUSTOM = 1, 2, 3, 4

-- The pieces, in menu order: the widget id (permanent), its label, and what
-- Minimal, Clean and Detailed set it to. Clean is each one's default.
M.ESP_PIECES = {
    { id = "show_icon",        label = "What it is, as the game's own icon",            styles = { true,  true,  true } },
    { id = "show_name",        label = "Name",                                          styles = { true,  true,  true } },
    { id = "show_bar",         label = "Health bar, once it is hurt",                   styles = { true,  true,  true } },
    { id = "show_level",       label = "Level, in its target frame's colour",           styles = { false, true,  true } },
    { id = "show_distance",    label = "Distance",                                      styles = { false, true,  true } },
    { id = "show_badges",      label = "Elite, rare, boss: the target frame's dragon or skull", styles = { true, true, true } },
    { id = "show_fight_role",  label = "How it fights: sword, bow or staff",            styles = { false, true,  true } },
    { id = "show_quest_tag",   label = "Quest: what to do there, progress and title",   styles = { true,  true,  true } },
    { id = "show_status",      label = "Crowd control, and who it is on (with the ring off)", styles = { true, true, true } },
    { id = "show_threat",      label = "Your threat on it, in a group",                 styles = { false, true,  true } },
    { id = "show_title",       label = "Town NPC titles: <Armorer>",                    styles = { false, true,  true } },
    { id = "show_health_text", label = "Health as a number, once it is hurt",           styles = { false, false, true } },
    { id = "show_corpse_name", label = "Corpse names",                                  styles = { false, false, true } },
    { id = "node_label",       label = "Herb, ore and chest names",                     styles = { true,  true,  true } },
    { id = "node_ring",        label = "Ring under herbs, ore and chests",              styles = { false, true,  true } },
    { id = "show_box",         label = "Box round mobs nearby",                         styles = { false, false, true } },
}

-- --- gathering nodes --------------------------------------------------------
--
-- Mining nodes are detected by SHAPE, not by an id list: every Classic and TBC
-- vein ends in "Vein" or "Deposit". That one rule covers the whole range
-- including the ooze-covered and Hakkari variants, and it keeps working on a
-- private server with custom nodes, which a hard-coded id table would not.
--
-- Herbs get an explicit set because herb names are just plant names with no
-- shared suffix to match on.

M.ORE_SUFFIXES = { "vein", "deposit", "seam" }

-- Ore names that appear inside a node's name rather than at its end: The
-- War Within's nodes are "Bismuth", "Rich Ironclaw", "Crystallized
-- Aqirite"... with no "Vein" or "Deposit" to match on.
M.ORE_WORDS = { "bismuth", "ironclaw", "aqirite" }

-- A handful of mining nodes break the suffix rule.
M.ORE_EXTRA = {
    ["ooze covered thorium vein"] = true,
    ["lesser bloodstone deposit"] = true,
    ["dark iron deposit"]         = true,
    ["small obsidian chunk"]      = true,
    ["large obsidian chunk"]      = true,
}

M.HERBS = {}
do
    local names = {
        -- Classic
        "peacebloom", "silverleaf", "earthroot", "mageroyal", "briarthorn",
        "stranglekelp", "bruiseweed", "wild steelbloom", "grave moss",
        "kingsblood", "liferoot", "fadeleaf", "goldthorn", "khadgar's whisker",
        "wintersbite", "firebloom", "purple lotus", "arthas' tears", "sungrass",
        "blindweed", "ghost mushroom", "gromsblood", "golden sansam",
        "dreamfoil", "mountain silversage", "plaguebloom", "icecap",
        "black lotus", "bloodvine", "sorrowmoss",
        -- TBC
        "felweed", "dreaming glory", "ragveil", "flame cap", "terocone",
        "ancient lichen", "netherbloom", "nightmare vine", "mana thistle",
        "fel lotus", "netherdust bush", "glowcap",
    }
    for i = 1, #names do M.HERBS[names[i]] = true end
end

-- Herbs of the later expansions, for the overlay on those clients. Matched
-- INSIDE a node's name, not as the whole of it, because their nodes come in
-- variants -- "Lush Hochenblume", "Irradiated Mycobloom", "Frozen Herb" --
-- that an exact list would never keep up with. Each is a word no other kind
-- of object is called.
M.HERB_WORDS = {
    -- Wrath
    "goldclover", "tiger lily", "talandra's rose", "adder's tongue", "lichbloom",
    "icethorn", "frost lotus", "firethorn", "frozen herb", "deadnettle",
    -- Cataclysm
    "cinderbloom", "stormvine", "azshara's veil", "heartblossom", "whiptail",
    "twilight jasmine",
    -- Mists
    "green tea leaf", "silkweed", "snow lily", "fool's cap", "rain poppy",
    "golden lotus", "sha-touched herb",
    -- Warlords
    "frostweed", "fireweed", "gorgrond flytrap", "starflower", "nagrand arrowbloom",
    "talador orchid",
    -- Legion
    "aethril", "dreamleaf", "foxflower", "fjarnskaggl", "starlight rose", "astral glory",
    -- Battle for Azeroth
    "riverbud", "star moss", "akunda's bite", "winter's kiss", "siren's pollen",
    "sea stalk", "anchor weed", "zin'anthid",
    -- Shadowlands
    "death blossom", "marrowroot", "rising glory", "vigil's torch", "widowbloom",
    "nightshade", "first flower",
    -- Dragonflight
    "hochenblume", "bubble poppy", "saxifrage", "writhebark",
    -- The War Within
    "mycobloom", "luredrop", "orbinid", "blessing blossom", "arathor's spear", "null lotus",
}

-- Containers are matched on keywords for the same reason as ore: the set is
-- open-ended and every entry shares one of a small number of nouns.
M.CONTAINER_KEYWORDS = {
    "chest", "trunk", "lockbox", "strongbox", "footlocker", "coffer",
    "casket", "crate", "barrel", "cache", "junkbox", "clam", "strongchest",
    "supply", "stash", "urn", "sack", "dirt pile", "buried",
}

-- --- helpers ----------------------------------------------------------------

---@param name string
---@return boolean
function M.is_ore(name)
    local lowered = name:lower()
    if M.ORE_EXTRA[lowered] then return true end
    for i = 1, #M.ORE_WORDS do
        if lowered:find(M.ORE_WORDS[i], 1, true) then return true end
    end
    for i = 1, #M.ORE_SUFFIXES do
        local suffix = M.ORE_SUFFIXES[i]
        if lowered:sub(-#suffix) == suffix then return true end
    end
    return false
end

---@param name string
---@return boolean
function M.is_herb(name)
    local lowered = name:lower()
    if M.HERBS[lowered] then return true end
    for i = 1, #M.HERB_WORDS do
        if lowered:find(M.HERB_WORDS[i], 1, true) then return true end
    end
    return false
end

-- --- gathering skill (1.88.0) ------------------------------------------------
--
-- The user, 2026-10-08: "Only Show Gatherables that I can Gather with my
-- skills  If i Cannot then Write (Requires Skill # )". What Classic asks of
-- your Herbalism or Mining for each node, by its name in lower case. A herb
-- or vein not listed (another expansion's, a custom one) asks for nothing
-- known: it is shown to anyone with the profession.

M.GATHER_SKILL = {
    herbalism = {
        ["peacebloom"] = 1, ["silverleaf"] = 1, ["earthroot"] = 15, ["mageroyal"] = 50,
        ["briarthorn"] = 70, ["stranglekelp"] = 85, ["bruiseweed"] = 100, ["wild steelbloom"] = 115,
        ["grave moss"] = 120, ["kingsblood"] = 125, ["liferoot"] = 150, ["fadeleaf"] = 160,
        ["goldthorn"] = 170, ["khadgar's whisker"] = 185, ["wintersbite"] = 195, ["firebloom"] = 205,
        ["purple lotus"] = 210, ["arthas' tears"] = 220, ["sungrass"] = 230, ["blindweed"] = 235,
        ["ghost mushroom"] = 245, ["gromsblood"] = 250, ["golden sansam"] = 260, ["dreamfoil"] = 270,
        ["mountain silversage"] = 280, ["plaguebloom"] = 285, ["icecap"] = 290, ["black lotus"] = 300,
    },
    mining = {
        ["copper vein"] = 1, ["tin vein"] = 65, ["incendicite mineral vein"] = 65,
        ["silver vein"] = 75, ["ooze covered silver vein"] = 75, ["lesser bloodstone deposit"] = 75,
        ["iron deposit"] = 125, ["indurium mineral vein"] = 150, ["gold vein"] = 155,
        ["ooze covered gold vein"] = 155, ["mithril deposit"] = 175, ["ooze covered mithril deposit"] = 175,
        ["truesilver deposit"] = 230, ["ooze covered truesilver deposit"] = 230, ["dark iron deposit"] = 230,
        ["small thorium vein"] = 245, ["ooze covered thorium vein"] = 245, ["rich thorium vein"] = 275,
        ["ooze covered rich thorium vein"] = 275, ["hakkari thorium vein"] = 275,
        ["small obsidian chunk"] = 305, ["large obsidian chunk"] = 305,
    },
}
M.GATHER_PROFESSION = { herb = "herbalism", ore = "mining" }

--- What a node asks for: its profession ("herbalism", "mining") and the
--- skill, or the profession and nil when the name is not listed. nil, nil
--- for a node no profession gathers (a chest).
---@param kind string "herb", "ore", "container", ...
---@param name? string
---@return string|nil profession
---@return integer|nil skill
function M.gather_requirement(kind, name)
    local prof = M.GATHER_PROFESSION[kind]
    if not prof then return nil, nil end
    local need = type(name) == "string" and M.GATHER_SKILL[prof][name:lower()] or nil
    return prof, need
end

--- Should a node be shown, and with what note? `skill_of(prof)` answers your
--- skill in a profession, or nil without it (JCore's player.skill).
--- Answers "show", "requires" (with the skill it asks for) or "hide".
---@param kind string
---@param name? string
---@param skill_of fun(prof: string): integer|nil
---@return string verdict
---@return integer|nil need
function M.gather_verdict(kind, name, skill_of)
    local prof, need = M.gather_requirement(kind, name)
    if not prof then return "show", nil end
    local have = skill_of and skill_of(prof) or nil
    if not have then return "hide", need end
    if need and have < need then return "requires", need end
    return "show", need
end

---@param name string
---@return boolean
function M.is_container(name)
    local lowered = name:lower()
    for i = 1, #M.CONTAINER_KEYWORDS do
        if lowered:find(M.CONTAINER_KEYWORDS[i], 1, true) then return true end
    end
    return false
end

--- Splits a comma separated user filter into lowercase terms.
---@param text string|nil
---@return string[]
function M.split_terms(text)
    local out = {}
    if not text or text == "" then return out end
    for term in tostring(text):gmatch("[^,]+") do
        term = term:match("^%s*(.-)%s*$"):lower()
        if term ~= "" then out[#out + 1] = term end
    end
    return out
end

-- Telegraphs (1.65.0): whose spells get one. A dropdown's index is what is
-- saved, so these keep their order; add to the end.
M.TELE_WHO = { "Every hostile cast", "Elites, bosses and boss-mod spells", "Boss-mod spells only" }
-- 1.65.1: where telegraphs are drawn. Same rule: add to the end.
M.TELE_WHERE = { "Everywhere", "Raids and dungeons only" }

---@param name string
---@param terms string[]
---@return boolean
function M.matches_any(name, terms)
    if #terms == 0 then return false end
    local lowered = name:lower()
    for i = 1, #terms do
        if lowered:find(terms[i], 1, true) then return true end
    end
    return false
end

return M

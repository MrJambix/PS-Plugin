-- Jambix AIO / esp/forever -- the overlay on the Forever client, built only on
-- what that client is known to answer.
--
-- WHY A SEPARATE ESP
-- The ESP for the classic clients (collect / classify / elements) leans on
-- reads that JCore's API recorder caught failing on Forever (2026-10-02):
-- get_name is "" for every unit, get_nameplate is nil, get_classification,
-- get_race_id and get_power are always 0, has_loot / can_be_looted always
-- false, the head attachment always (0,0,0), get_target_marker_index 16. It
-- was switched off there (1.41.0) and this replaces it on Forever only. Every
-- other client never loads this file.
--
-- WHAT IT READS (each confirmed answering on Forever in the recording)
--   JCore's sweep        position, distance, dead, attackable, is_player
--   units.health_fraction  health, cached by JCore per tick
--   ctx.enemies          cast, crowd control, who it targets, in combat,
--                        approaching -- read by JCore on its own clock
--   ctx.threat           your place on its threat table (get_threat_situation)
--   per unit, 2 s cache  get_level, get_class, get_creature_type, get_npc_id,
--                        get_max_health, get_bounding_radius, is_enemy_with,
--                        get_name, is_pet, is_minion
--   per corpse, 1 s      can_be_skinned
--   per object, 5 s      get_name (real for objects), can_be_used
--   you, per frame       get_direction (get_rotation was never seen there)
--   draw                 w2s, checked correct on Forever against the player
--
-- WHAT IT DRAWS: an icon card under the feet (1.69.0, see THE ICON CARD
-- below), each piece behind the ESP page's own switch, each fact once
--   a mob or player      what it is (creature type, class crest, a town
--                        service, a quest giver's ! or ?) and its name; a
--                        health bar once hurt; the elite / rare dragon ring
--                        or boss skull, how it fights (sword, bow, staff),
--                        level in its target frame's colour and distance;
--                        what a quest wants (attack / loot / use cursor,
--                        2/8, the quest's title); crowd control; a cast bar
--                        with the shield when it cannot be interrupted;
--                        for a hunter, what a tameable beast teaches
--                        (icon, skill, rank: WHAT A BEAST TEACHES); for a
--                        skinner, the Pristine it can give (PRISTINE)
--   corpses              the loot bag, and the pelt when your Skinning
--                        reaches it (a corpse with neither is not marked);
--                        under the pelt, what skinning it gives (icon, item,
--                        chance: WHAT SKINNING GIVES), Pristine included
--   gathering            herbs, ore veins, chests, and (off by default) any
--                        other object you can use: icon, name, distance, a ring;
--                        herbs and ore by your skill (GATHER BY SKILL below)
--   in the world         the box (box_style; a curtain by default), a ring
--                        under anything on you or yours, a line from it to
--                        whoever it is after, a beacon over a far rare, boss,
--                        quest mark or corpse to loot
--   on screen            the threat panel, alerts, arrows for threats off
--                        screen
--
-- THE NEW LOOK (1.88.0). The user, 2026-10-08: "Take all ESPs and convert it
-- to this!", choosing "Ground rings, Boxes to curtains, Far things as
-- beacons, Cards and bars". Every ring this file draws on the ground is
-- JCore's shader ring (ring_3d), the old outline circle where JCore has none;
-- the box gains a short curtain round the unit (cfg.BOX_CURTAIN, now the
-- default); a far rare, boss, quest mark or corpse to loot gets a pillar of
-- light (beacon_3d, "esp_beacons" past "esp_beacon_from" yards); the cards'
-- plates and bars are esp/card.lua's (SOFT CARDS AND BARS there). Each new
-- call is looked for first, so an older JCore draws what it always did.
-- 1.7.6: the corners are the default again (curtains are off by default,
-- each behind its own switch); the curtain is a Box style to pick.
--
-- THE CATEGORIES (1.48.0). Every mark falls in one of the page's categories
-- (cfg.CATEGORIES), and that category's switch, range (when automatic ranges
-- are off) and, for nodes, colour decide it, as on the Classic ESP. Bosses,
-- rares and elites are their own categories since 1.52.0: get_classification
-- is 0 for every unit on Forever, but the client's own creature cache knows
-- (see RARES AND ELITES). Guide targets need RestedXP, which Forever does not
-- have.
--
-- QUESTS APART FROM THE ESP (1.73.0). Quest marks and quest areas follow the
-- Quests page's "Enable quest ESP" alone; this page has no quest row. With
-- the ESP page's "Enable ESP" off they are still drawn (render's
-- quest_visuals): nothing else is marked then, and they leave out the
-- fight's extras -- the cast bar, the ring and the line.
--
-- WHAT THE RECORDED API MADE POSSIBLE (1.48.0)
--   NODES. get_name answers for game objects on Forever ("Copper Vein",
--     "Peacebloom", "Silverleaf"), so the Classic ESP's name rules
--     (cfg.is_herb, is_ore, is_container) apply as they are. can_be_used
--     answered true on every herb and vein recorded and false on scenery
--     ("Ley Line", "Construct Parts"), so it stands in for has_loot (always
--     false there) in deciding what an "other object" is.
--   LOOT and TAPPED are JCore's since 1.55.0 (JCore 1.6.0, services/loot.lua):
--     loot.corpse(unit) says whether a corpse is ours to loot (no read tells a
--     lootable corpse from a looted one there, so JCore infers it from who it
--     fought, and a loot window beside it clears it), and loot.tapped(unit)
--     whether a mob is somebody else's (the client's is_tap_denied, true since
--     patch 1.60.1.70205, or a stranger's fight). Tapped mobs are greyed when
--     "Grey out mobs someone else has tagged" is on, say "tapped", and their
--     corpses never say LOOT. A kill that dropped nothing keeps its LOOT until
--     it despawns: there is no window to clear it.
--
-- NAMES are JCore's too (services/names.lua): the client's when it answers,
-- else a name heard for that unit, else one learned for its kind (from your
-- casts, kept by npc id across sessions), else the client's own creature
-- cache. Failing all of them a mark says what it is (its creature type, or a
-- player's class). The cache also gives a town npc's title, shown under its
-- name: <Weapon Merchant>.
--
-- WHERE A MARK GOES. Under the feet. Forever draws its nameplates where the
-- game hangs a name, above the head, and the plates paint over the overlay;
-- nothing of the game's sits under the feet. A mark that finds its spot
-- taken moves down a little, and when there is no room it prints anyway:
-- on Forever a mark that vanished was the bug this file replaces. Marks are
-- laid out in order of importance, as on the Classic ESP: your target first,
-- then by category, then nearest first in three-yard bands, so two mobs at
-- nearly the same distance do not trade places every frame.
--
-- RARES AND ELITES (1.52.0). get_classification is always 0 there, so the
-- rank is the creature cache's, by npc id: an ELITE / RARE / RARE ELITE /
-- BOSS pill, the page's Elites, Rares and Bosses rows, and an alert for an
-- elite, rare elite or boss coming at you. A creature the cache has not seen
-- yet is drawn as the normal mob it looks like, and the alerts are also
-- given for any mob that many levels above you coming at you.
--
-- RARES FROM THE LIST (1.7.5). The user, 2026-10-09: "I wanna pull up a list
-- of all Forever Rare Mobs (includes classic) and tag them in ESP with RARE".
-- The cache only holds what earlier sessions saw, so a rare met for the
-- first time was drawn as a normal mob. When the cache gives no rank, the
-- game is asked (get_classification answers on Forever since the 2026-10-06
-- core: 4 for Morgaine the Sly and Matriarch Bristlefur in the recording),
-- and when that gives none either, modules/rares_data.lua: 421 rares and
-- rare elites by npc id, Classic's 398 from the client's QuestieDB plus
-- Forever's and Season of Discovery's own (tools/jcheck/rares_extract.js).
-- A rank the game does give always wins: the list says rare elite for
-- VanCleef, Forever says elite. The fesp trace says where a rank came from
-- (rank=4/list).
--
-- THE RANK IN WORDS (1.7.5). Since 1.69.0 the art pack's dragon ring or
-- skull stood alone for the rank. The user, in Wailing Caverns: "I see
-- Elites and I dont see Elite Tags on them". Every rank now says so in words
-- on the name row, after the name, in its category's colour: ELITE, RARE
-- ELITE, BOSS or RARE, at every detail and with or without the art pack,
-- under the page's rank switch (show_badges); the ring or skull stays.
-- Forever never answers 3, so an elite the client calls a boss (is_boss) is
-- a BOSS (rank=3/game+boss in the trace); a rare elite it calls one stays a
-- RARE ELITE.
--
-- QUESTS FROM THE GAME (1.53.0). When JCore's gamelua bridge reaches the
-- game's own Lua (esp/forever_quests.lua reads the quest log through it), a
-- mob the game ties to one of your quests -- its tooltip names the quest and
-- an objective, or C_QuestLog.UnitIsRelatedToActiveQuest says so -- is a
-- quest mark with that objective's chip (KILL 2/8, LOOT 1/6, USE 0/1) and the
-- quest's title under it. A mob whose kind drops an item an unfinished
-- objective wants (the creature cache's quest items) gets LOOT n/m. Names come
-- from the game first. Each quest's AREA from the game's quest map is drawn:
-- a ring on it, a line towards it and its title with the distance, under the
-- Quests page's "Point to the nearest known spawn" switch, range, line length
-- and path limit; "A live target beats a map marker" hides the area of a
-- quest whose mob is marked on screen. Without the bridge none of this shows
-- and the marks are what they were.
--
-- QUEST OBJECTS FROM THE QUEST DATABASE (1.59.0). A crate, a bundle or a
-- basket a quest you are on wants is marked from the start: COLLECT or USE,
-- the count once the game has reported one ("COLLECT 1/8"), and the quest's
-- title under it. It goes when that objective is done. The objects come
-- from quests.lua's index (JCore's questdb, QuestieDB's data); see
-- esp/forever_quests.lua. Before 1.59.0 such an object was only marked
-- after its first pickup.
--
-- GATHER BY SKILL (1.88.0). The user, 2026-10-08: "Only Show Gatherables
-- that I can Gather with my skills  If i Cannot then Write (Requires Skill
-- # )". With "gather_skill_only" on (the default) a herb or a vein is weighed
-- by cfg.gather_verdict against your Herbalism or Mining (JCore's
-- player.skill, read once a frame): without the profession it is not marked;
-- above your skill it is marked dimmed, "Mithril Deposit (Requires Skill
-- 175)"; else as before. A JCore without player.skill, or a read that
-- raised, hides nothing. Chests ask for no skill. The automation's list
-- (M.nodes) is not filtered: hiding a mark must not change what it does.
--
-- WHAT A BEAST TEACHES (1.7.6). The user, 2026-10-09: "I'd like an ESP on
-- beasts as a Hunter class that shows me the image and name of the ability
-- and rank it is ... give me an option to turn it off too in the esp", with
-- Petopia's Forever ability page as the reference. For a hunter, a beast
-- that can be tamed gets one pill per skill it teaches under its card: the
-- game's own icon for that skill, as on the pet's bar (the art pack's
-- "pet.<FileDataID>" cell, cut from the client by the spell's own icon; the
-- user, 2026-10-10: "The Games own Skill Icon like Bite should be Bites
-- Icons"), else the rank's spell icon from the web; then "Dismember 2".
-- modules/tame.lua decides what it teaches: Petopia's list for that kind, or
-- what it was seen using, in the TAME violet; else its family's skills
-- nobody can vouch for, dimmed and with "?" ("Pinch 3?"), when
-- "pet_skill_guesses" is on. "new" in green:
-- above the rank your pet has now. Above your level the rows are dimmed and
-- the first says "tame at 34". Every detail but the icon alone shows them;
-- "show_pet_skills" (the ESP page's Hunters section) switches them off.
--
-- WHAT SKINNING GIVES (1.7.6). The user, 2026-10-10: "I want ESP now to show
-- similar thing for What skinable corpse can give me by % if its multiple
-- items". Under a corpse marked SKIN (your Skinning reaches it), one pill
-- per item its kind can give, most likely first: the item's own icon (the
-- art pack's "item.<item id>" cell, cut from the client's Item.db2, else the
-- web icon), its name in its quality's colour, "x1-2" when it can be more
-- than one, and its chance: "Light Leather x1-2 · 41%", "Medium Hide · 3.4%".
-- Most kinds' items share one roll, so their chances add up to 100%; a
-- dragon's or a boss's roll some on their own and add up past it. The tables are
-- CMaNGOS's Classic ones (modules/skinning_data.lua,
-- tools/jcheck/skinning_extract.js): 924 creatures, by npc id. Forever's own
-- creatures are not in them and keep the pelt alone. Every detail but the
-- icon alone shows them; "show_skin_loot" (the ESP page's World section)
-- switches them off.
--
-- PRISTINE (1.7.6). The user, 2026-10-10: "Let's add Mobs that when skined
-- also give pristine cause i dont see any so far". Forever's Pristine
-- Leather, Hide and Scale are a rare bonus on top of a skin's leather, and
-- Classic's tables have never heard of them. skinning_data.lua's `pristine`
-- lists the creatures they have been seen from: the Forever client's
-- QuestieDB (41 for the Leather, level 10 to 24: Goretusks, Barrens
-- plainstriders and zhevras, Darkshore bears...; none yet for the Hide or the
-- Scale) and the player's own skins in TrackMe's log (Starving Dire Wolf,
-- Gray Fox). Nobody knows a chance for each creature (the player's: 3 of 259
-- skins gave 2 or 3), so its pill says "rare": "Pristine Leather · rare",
-- green, with the item's icon. One goes under such a corpse your Skinning
-- reaches, after the Classic rows (a Forever creature with no Classic table
-- gets it alone), and one under the LIVING creature, so you know which to
-- kill: nothing without Skinning; dimmed, "(Requires Skill 115)", above
-- yours. Every detail but the icon alone shows them; "show_pristine" (the ESP
-- page's World section) switches both off.
--
-- TRACE. Twice a second the nearest marks are written to JCore's recorder
-- trace (scripts_data/jcore/jcore.trace.txt) as "fesp" lines: what was read
-- and where it was drawn, so the next problem is seen rather than guessed.

return function(P)
    local ctx, cfg, log = P.ctx, P.cfg, P.log
    local CRITTER = (cfg and cfg.CREATURE_CRITTER) or 8
    local CATEGORY = (cfg and cfg.CATEGORY_BY_KEY) or {}
    local units, draw = P.units, P.draw
    -- JCore 1.5.15: what the client's own creature cache says, by npc id.
    local creatures = ctx.creatures
    -- JCore 1.6.0: names, and whose mob / whose corpse, answered per client.
    local names, jloot = ctx.names, ctx.loot
    -- WoW's classification ids, as the cache gives them: the category a mob
    -- is marked under, its pill, and whether it is worth an alert.
    -- `art` is its icon in the art pack: the target frame's dragon ring
    -- (gold elite, silver rare, dark silver rare elite) or its skull.
    local RANK = {
        [1] = { cat = "elite", word = "ELITE", alert = "Elite", danger = true, art = "elite" },
        [2] = { cat = "rare", word = "RARE ELITE", alert = "Rare elite", danger = true, art = "rare_elite" },
        [3] = { cat = "boss", word = "BOSS", alert = "Boss", danger = true, art = "boss" },
        [4] = { cat = "rare", word = "RARE", art = "rare" },
    }
    -- Every rare known for the Forever world, Classic's included
    -- (modules/rares_data.lua, tools/jcheck/rares_extract.js), by npc id: see
    -- RARES FROM THE LIST.
    local RARES = nil
    do
        local ok, data = pcall(function()
            if P.load then return P.load("modules/rares_data") end
            return require("jambix_aio/modules/rares_data")
        end)
        if ok and type(data) == "table" and type(data.rares) == "table" then RARES = data.rares end
    end
    -- What skinning gives, by npc id (modules/skinning_data.lua,
    -- tools/jcheck/skinning_extract.js): see WHAT SKINNING GIVES.
    local SKINNING = nil
    do
        local ok, data = pcall(function()
            if P.load then return P.load("modules/skinning_data") end
            return require("jambix_aio/modules/skinning_data")
        end)
        if ok and type(data) == "table" and type(data.loot) == "table" and type(data.items) == "table" then
            SKINNING = data
        end
    end

    local M = {}
    local quests -- esp/forever_quests, built further down; read by read_settings

    -- --- tuning -------------------------------------------------------------

    local STATIC_TTL = 2.0          -- level, class, type, npc id, reaction, name, pet
    local CORPSE_TTL = 1.0          -- can_be_skinned
    local OBJECT_TTL = 5.0          -- an object's name, and whether it can be used
    local LINE_ARRIVED = 6.0        -- yards: an attacker this close has arrived
    local PANEL_ROWS = 8
    local TRACE_EVERY, TRACE_MARKS = 0.5, 8
    local BAND = 3                  -- yards: marks hold their order within a band
    local LOOT_REACH = 6.0          -- yards: a loot window belongs to a corpse this near
    local FOUGHT_KEEP = 120         -- seconds a fight still counts towards LOOT
    local NODE_RING = 0.9           -- yards: the ring under a node
    local CAST_RING_GAP = 0.35      -- yards: the cast ring sits this far outside the aggro ring
    -- THE RING UNDER A MOB ON YOU OR YOURS (1.66.2). The native circle glows
    -- inward from its edge, and its fade says how far: JCore passes 1.0,
    -- which spread the glow over the whole disc, so four to seven mobs on
    -- the pet painted the ground under them solid. A fast fade keeps the glow
    -- on the rim, one ring alone is see-through, and the more rings there are
    -- the fainter each is (down to `floor` of one alone), so a pile of them
    -- still shows the mobs and the ground. The colours are col.on_you and
    -- col.group's. Since 1.88.0 it is JCore's shader ring (ring_3d): a thin
    -- band at the rim (RING_INNER.aggro) with no glow inward, still fainter
    -- the more there are. `fade` is for the outline circle an older JCore
    -- draws instead.
    local RING = {
        fade = 6.0,     -- the native default is 2.5; bigger keeps the glow nearer the rim
        stack = 8,      -- past this many, every ring is at its floor
        n = 0, last = 0, -- rings drawn this frame, and last frame
        on_you = { rgb = { 240, 80, 70 }, alpha = 200, floor = 0.6, thickness = 2.0, colors = {} },
        group = { rgb = { 240, 170, 60 }, alpha = 150, floor = 0.45, thickness = 1.5, colors = {} },
    }
    -- THE NEW LOOK (1.88.0). Each shader ring's band runs from this fraction
    -- of its radius out to the radius.
    local RING_INNER = { aggro = 0.86, node = 0.72, place = 0.92 }
    local CURTAIN_HEIGHT = 2.0      -- yards: a curtain box (no model height is read here)
    local BEACON_HEIGHT = 10        -- yards: a beacon over a far mark
    local BEACON_MAX = 6            -- beacons a frame, the most relevant marks first
    local BEACON_CATS = { rare = true, boss = true, quest = true }
    -- A spell id above this is not a spell: the channel read answered
    -- 3739147998 on Forever, and a bar for it would be a bar for nothing.
    local SPELL_ID_MAX = 5000000

    local CREATURE = {
        [1] = "Beast", [2] = "Dragonkin", [3] = "Demon", [4] = "Elemental", [5] = "Giant",
        [6] = "Undead", [7] = "Humanoid", [8] = "Critter", [9] = "Mechanical", [11] = "Totem",
        [12] = "Pet", [13] = "Gas Cloud", [14] = "Wild Pet", [15] = "Aberration",
    }

    local col = {
        hostile  = P.color(235, 87, 87),
        neutral  = P.color(230, 190, 90),
        player   = P.color(235, 70, 70),
        friendly = P.color(100, 200, 140),
        corpse   = P.color(210, 180, 120),
        text     = P.color(240, 240, 245),
        dim      = P.color(170, 172, 182),
        back     = P.color(12, 12, 16, 220),
        bar_back = P.color(0, 0, 0, 180),
        on_you   = P.color(240, 80, 70),
        group    = P.color(240, 170, 60),
        control  = P.color(170, 120, 250),
        cast     = P.color(240, 180, 60),
        kick     = P.color(170, 120, 250),
        skin     = P.color(190, 140, 90),
        loot     = P.color(110, 210, 110),
        tapped   = P.color(150, 150, 155),
        melee    = P.color(230, 150, 90),
        ranged   = P.color(120, 200, 120),
        caster   = P.color(140, 160, 250),
        safe     = P.color(120, 200, 120),
        warm     = P.color(240, 180, 60),
        hot      = P.color(240, 80, 70),
        panel    = P.color(240, 180, 60),
        quest    = P.color(255, 210, 60),
        quest_dim = P.color(170, 150, 80),
        clear    = P.color(0, 0, 0, 0),
    }

    -- A LEVEL IN ITS TARGET FRAME'S COLOUR (1.67.0). The user: "their level
    -- to be drawn the same color as their level in their frame". Red five
    -- levels up, orange three, yellow within two, green, then grey: the
    -- game's bands (cfg.difficulty_band) in the game's colours
    -- (cfg.LEVEL_RGB). Only what you can attack; the frame paints a friendly
    -- level plainly too.
    local level_col = {}
    for band, rgb in pairs((cfg and cfg.LEVEL_RGB) or {}) do level_col[band] = P.color(rgb[1], rgb[2], rgb[3]) end
    local function level_color(level, mine)
        if not (cfg and cfg.difficulty_band) or type(level) ~= "number" or level <= 0 then return nil end
        return level_col[cfg.difficulty_band(level, mine)]
    end

    local atan2 = math.atan2 or math.atan

    local function now() return core.time() end

    local function ask(obj, method, ...)
        if not obj then return nil end
        local ok_f, fn = pcall(function() return obj[method] end)
        if not ok_f or type(fn) ~= "function" then return nil end
        local ok, value = pcall(fn, obj, ...)
        if ok then return value end
        return nil
    end

    --- A category's colour: the picker on the ESP page when main.lua has
    --- built it (P.category_color, rebuilt only when a picker moves), the
    --- category's own default otherwise.
    local fallback_color = {}
    local function category_color(key)
        local picked = P.category_color and P.category_color[key]
        if picked then return picked end
        local c = fallback_color[key]
        if not c then
            local rgb = CATEGORY[key] and CATEGORY[key].rgb or { 200, 200, 200 }
            c = P.color(rgb[1], rgb[2], rgb[3])
            fallback_color[key] = c
        end
        return c
    end

    -- --- settings, read once a frame ------------------------------------------

    local S = { on = {}, range = {}, detail = {} }
    local include_text, include_terms = nil, {}
    local CATEGORY_DETAIL = (cfg and cfg.CATEGORY_DETAIL) or {}
    local function read_settings(master, esp_on)
        S.size = P.opt("text_size", 13)
        -- The pieces of a mark (cfg.ESP_PIECES; the Style sets them all).
        S.icon = P.opt("show_icon", true)
        S.name = P.opt("show_name", true)
        S.bar = P.opt("show_bar", true)
        S.level = P.opt("show_level", true)
        S.distance = P.opt("show_distance", true)
        S.badges = P.opt("show_badges", true)
        S.fight_role = P.opt("show_fight_role", true)
        S.quest_tag = P.opt("show_quest_tag", true)
        S.status = P.opt("show_status", true)
        S.threat = P.opt("show_threat", true)
        S.title = P.opt("show_title", true)
        S.health_text = P.opt("show_health_text", false)
        S.corpse_name = P.opt("show_corpse_name", false)
        S.node_label = P.opt("node_label", true)
        S.node_ring = P.opt("node_ring", true)
        S.box = P.opt("show_box", false)
        -- In a fight.
        S.cast = P.opt("show_cast", true)
        S.cast_ring = P.opt("show_cast_ring", true)
        S.aggro = P.opt("show_aggro", true)
        S.lines = P.opt("show_target_line", true)
        -- The look.
        S.health_exact = P.opt("show_health_exact", false)
        S.bar_always = P.opt("bar_always", false)
        S.bar_w = tonumber(P.opt("bar_width", 54)) or 54
        S.bar_h = tonumber(P.opt("bar_height", 4)) or 4
        S.game_bars = P.opt("game_bars", true)
        -- 1.88.0: the soft cards, the beacons, and herbs and ore by your
        -- skill. 1.7.6: the corners by default again, and the beacons off --
        -- a beacon is a curtain, and enemies carry none by default.
        S.box_style = P.opt("box_style", cfg and (cfg.BOX_DEFAULT or cfg.BOX_CORNERS) or 1)
        S.shader_look = P.opt("esp_shader_look", true) ~= false
        S.beacons = P.opt("esp_beacons", false) == true
        S.beacon_from = tonumber(P.opt("esp_beacon_from", 40)) or 40
        S.gather_skill_only = P.opt("gather_skill_only", true) == true
        -- 1.7.6: what a tameable beast teaches a hunter (WHAT A BEAST TEACHES).
        S.pet_skills = P.opt("show_pet_skills", true) ~= false
        S.pet_guesses = P.opt("pet_skill_guesses", true) ~= false
        -- 1.7.6: what a skinnable corpse gives (WHAT SKINNING GIVES).
        S.skin_loot = P.opt("show_skin_loot", true) ~= false
        -- 1.7.6: the creatures a skin can give Pristine from (PRISTINE).
        S.pristine = P.opt("show_pristine", true) ~= false
        S.grey_tapped = P.opt("grey_tapped", true)
        S.color_mode = tonumber(P.opt("unit_color_mode", cfg and cfg.COLOR_MODE_REACTION or 2)) or 2
        S.max_marks = tonumber(P.opt("esp_max_marks", 60)) or 60
        S.full_range = P.opt("lod_full_range", 45)
        -- Each category's switch, range and detail, as the Classic ESP reads
        -- the first two: automatic ranges mean the master range for all.
        local auto = P.opt("auto_ranges", true)
        local cats = cfg and cfg.CATEGORIES or {}
        for i = 1, #cats do
            local c = cats[i]
            S.on[c.key] = P.opt(c.key .. "_on", c.on) == true
            local r = auto and master or tonumber(P.opt(c.key .. "_range", c.range)) or master
            S.range[c.key] = math.min(r, master)
            S.detail[c.key] = tonumber(P.opt(c.key .. "_detail", CATEGORY_DETAIL[c.key] or 1)) or 1
        end
        -- Quest marks are the Quests page's (1.73.0). With the ESP off
        -- (esp_on false) they are all that is marked, without the fight's
        -- extras.
        S.quests = quests ~= nil and P.opt("questie_on", true) == true
        S.on.quest = S.quests
        if not esp_on then
            for i = 1, #cats do
                local key = cats[i].key
                if key ~= "quest" then S.on[key] = false end
            end
            S.cast, S.cast_ring, S.aggro, S.lines = false, false, false, false
            -- The beacons are this page's (1.88.0): not with its ESP off.
            S.beacons = false
        end
        S.nodes = S.on.herb or S.on.ore or S.on.container or S.on.object
        local include = P.opt("objects_include", "")
        if include ~= include_text then
            include_text = include
            include_terms = (cfg and cfg.split_terms) and cfg.split_terms(include) or {}
        end
    end

    -- --- names --------------------------------------------------------------

    -- Kept by JCore since 1.55.0 (services/names.lua), which took in the
    -- forever_names store this file kept until then.

    local stats = {
        learned = 0, drawn = 0, offscreen = 0, crowded = 0, units = 0, threats = 0,
        nodes = 0, loot = 0, tapped = 0, tap_read = 0, gather_hidden = 0,
    }

    -- --- the game's own icons, and the card (1.69.0) ---------------------------
    --
    -- The art is the plugin's own since 1.69.0 (esp/art.lua, esp/art_pack.lua):
    -- one atlas of the game's icons cut out of the client's archives offline
    -- and shipped inside the plugin, so every player has it. Until then the
    -- Forever ESP's icons were PNGs cut into this machine's scripts_data, which
    -- the players it was given to never had. esp/card.lua lays every mark out.
    -- Both are the bundle's when something built them first, else built here.
    local function part(name, field)
        if P[field] then return P[field] end
        local ok, factory = pcall(function()
            if P.load then return P.load("modules/esp/" .. name) end
            return require("jambix_aio/modules/esp/" .. name)
        end)
        if ok and type(factory) == "function" then
            local ok2, mod = pcall(factory, P)
            if ok2 and type(mod) == "table" then
                P[field] = mod
                return mod
            end
            if log and log.fmt then log.fmt("error", "esp/%s did not build: %s", name, tostring(mod)) end
        elseif log and log.fmt then
            log.fmt("error", "esp/%s did not load: %s", name, tostring(factory))
        end
        return nil
    end
    local art = part("art", "esp_art")
    local card = part("card", "esp_card")
    local fight = P.esp_fight
    M.art, M.card = art, card

    --- A cell of the art pack on the card's current row. True when the pack
    --- has it -- it may still be loading for a frame or two -- so a caller
    --- knows the icon is saying what a word would.
    local function add_icon(key, tint)
        local ref = art and art.ref(key)
        if not ref then return false end
        card.icon(ref, tint)
        return true
    end

    --- A spell's own icon (the web icon cache), for a cast or a crowd control.
    local function add_spell(id)
        if type(id) ~= "number" or id <= 0 or id > SPELL_ID_MAX then return end
        card.icon("spell:" .. id)
    end

    -- --- quests ----------------------------------------------------------------
    --
    -- What the quests want, from esp/forever_quests.lua: quest givers (PICK UP,
    -- TURN IN), kill objectives (KILL 4/6) and quest objects (USE). Built only
    -- here, so only on Forever.
    do
        local ok, factory = pcall(function()
            if P.load then return P.load("modules/esp/forever_quests") end
            return require("jambix_aio/modules/esp/forever_quests")
        end)
        if ok and type(factory) == "function" then
            local ok2, mod = pcall(factory, P)
            if ok2 and type(mod) == "table" then quests = mod end
        end
    end
    M.quests = quests

    -- A name the client gives when it does not know one. Recorded on Forever
    -- as get_name's answer for most quest givers and town npcs; until 1.45.2 it
    -- was learned as though it were a name, and could overwrite a real one.
    local PLACEHOLDER = { ["Unknown"] = true, ["Unknown Being"] = true, ["UNKNOWNOBJECT"] = true }
    local function placeholder(name) return PLACEHOLDER[name] == true end

    --- How many names JCore has learned this session.
    local function learned_count()
        if not (names and names.stats) then return 0 end
        local ok, st = pcall(names.stats)
        return ok and type(st) == "table" and tonumber(st.learned) or 0
    end

    -- --- what is remembered per guid ------------------------------------------

    local facts = {}         -- guid -> the unit's slow reads (facts_of)
    local object_info = {}   -- guid -> { name, base, used, at } (object_of)

    if ctx.on then
        ctx.on("jcore.unit.removed", function(guid)
            facts[guid], object_info[guid] = nil, nil
        end)
        ctx.on("jcore.zone.changed", function()
            facts, object_info = {}, {}
        end)
    end

    -- --- per-unit facts -----------------------------------------------------

    local function facts_of(obj, guid, row, player, t)
        local f = facts[guid]
        if f and t < f.at then return f end
        f = f or {}
        facts[guid] = f
        -- Spread over time, so a crowd that arrived together is not re-read
        -- together on one frame two seconds later.
        f.at = t + STATIC_TTL * (0.75 + 0.5 * math.random())
        f.level = tonumber(ask(obj, "get_level")) or 0
        f.npc = tonumber(ask(obj, "get_npc_id")) or 0
        f.max_health = tonumber(ask(obj, "get_max_health")) or 0
        f.radius = tonumber(ask(obj, "get_bounding_radius")) or 0
        if row.is_player then
            f.class = tonumber(ask(obj, "get_class"))
        else
            f.ctype = tonumber(ask(obj, "get_creature_type"))
            f.flags = tonumber(ask(obj, "get_npc_flags"))
            -- The client's creature cache (1.52.0): name, title, rank.
            local info = nil
            if creatures and f.npc > 0 then
                local ok_i, got = pcall(creatures.info, f.npc)
                if ok_i and type(got) == "table" then info = got end
            end
            f.info = info
            -- JCore's rank: the creature cache's on Forever.
            f.rank, f.rank_src = 0, nil
            if units.classification then
                local ok_r, r = pcall(units.classification, obj)
                if ok_r and type(r) == "number" then f.rank = r end
            end
            if RANK[f.rank] then f.rank_src = "cache" end
            -- 1.7.5: the game's own answer, then the rare list (RARES FROM
            -- THE LIST).
            if not RANK[f.rank] then
                local live = tonumber(ask(obj, "get_classification"))
                if live and RANK[live] then f.rank, f.rank_src = live, "game" end
            end
            if not RANK[f.rank] and RARES and f.npc > 0 then
                local listed = RARES[f.npc]
                if listed and RANK[listed.rank] then f.rank, f.rank_src = listed.rank, "list" end
            end
            -- 1.7.5: Forever never says 3. Its dungeon bosses are elites the
            -- client calls a boss (VanCleef, Mr. Smite); a rare elite it calls
            -- one (Marisa du'Paige) stays a rare.
            if f.rank == 1 and ask(obj, "is_boss") == true then
                f.rank, f.rank_src = 3, (f.rank_src or "-") .. "+boss"
            end
            if (f.ctype == nil or f.ctype == 0) and info and info.type then f.ctype = info.type end
            -- Both answered on Forever in the recording; a pet or minion is
            -- the Pets category, yours and everyone's, as on the Classic ESP.
            f.pet = ask(obj, "is_pet") == true or ask(obj, "is_minion") == true
        end
        f.hostile = row.is_enemy and (ask(player, "is_enemy_with", obj) == true
            or ask(obj, "is_enemy_with", player) == true) or false
        return f
    end

    --- What a unit is called, and where that came from: JCore's names
    --- ("client", "known", "learned", "cache"), else what it is.
    local function name_of(obj, guid, f, row)
        -- 1.53.0: the game's own name, from a nameplate, the target or a
        -- tooltip (esp/forever_quests via JCore's gamelua), handed to JCore,
        -- which keeps it by npc id like any other.
        local g = quests and quests.unit_name and quests.unit_name(guid) or nil
        if g and not placeholder(g) and names and names.learn then
            pcall(names.learn, guid, (not row.is_player) and f.npc or nil, g)
        end
        if names and names.of and obj then
            local ok, n, source = pcall(names.of, obj)
            if ok and type(n) == "string" and n ~= "" and not placeholder(n) then return n, source end
        end
        if row.is_player then
            local roles = P.esp_roles
            local cls = roles and roles.class_name and f.class and roles.class_name(f.class)
            return (cls and cls ~= "" and cls or "Player"), "class"
        end
        return CREATURE[f.ctype or 0] or "NPC", "type"
    end

    -- --- objects -------------------------------------------------------------

    --- A game object's name (real on Forever, unlike a unit's) and what kind
    --- of node it is by the Classic ESP's name rules, re-read every few
    --- seconds. A quest object ("Ley Line Trap (Quest)") is told apart by
    --- its name too.
    local function object_of(obj, guid, t)
        local c = object_info[guid]
        if c and t < c.at then return c end
        c = c or {}
        object_info[guid] = c
        c.at = t + OBJECT_TTL
        local name = ask(obj, "get_name")
        if type(name) ~= "string" or name == "" or placeholder(name) then name = nil end
        c.name, c.base, c.used = name, nil, nil
        if name and cfg then
            if cfg.is_herb(name) then c.base = "herb"
            elseif cfg.is_ore(name) then c.base = "ore"
            elseif cfg.is_container(name) then c.base = "container" end
        end
        return c
    end

    local function object_name(obj, guid, t) return object_of(obj, guid, t).name end

    --- The node category of an object, or nil. "Other objects" (off by
    --- default) are the ones named under "extra object names", or that the
    --- client says can be used: true for every herb and vein recorded on
    --- Forever, false for scenery. Asked only while that category is on.
    local function node_kind(obj, c)
        if c.base then return c.base end
        if not S.on.object or not c.name then return nil end
        if #include_terms > 0 and cfg.matches_any(c.name, include_terms) then return "object" end
        if c.used == nil then c.used = ask(obj, "can_be_used") == true end
        return c.used and "object" or nil
    end

    -- --- text ---------------------------------------------------------------

    -- The card's glyph-summed width, for the threat panel's "you".
    local text_width = card and card.text_width or function(text, size) return #text * size * 0.5 end

    -- --- what a mob is doing --------------------------------------------------

    local group_guids = {}
    local function refresh_group()
        for k in pairs(group_guids) do group_guids[k] = nil end
        local group = ctx.group
        local members = group and group.members and group.members() or nil
        if type(members) ~= "table" then return end
        for i = 1, #members do
            local m = members[i]
            local guid = type(m) == "table" and (m.guid or (m.object and units.guid(m.object))) or nil
            if guid then group_guids[guid] = true end
        end
    end

    --- Somebody else's mob, by JCore (loot.tapped), and whether the client
    --- itself said so ("client") or it was read from the fight ("fight").
    local function tapped_of(guid)
        if not (jloot and jloot.tapped) then return false, nil end
        local ok, tapped, how = pcall(jloot.tapped, guid)
        if not ok then return false, nil end
        return tapped == true, how
    end

    --- How many creatures the client's cache held when JCore read it.
    local function creature_count()
        if not creatures or type(creatures.stats) ~= "function" then return 0 end
        local ok, st = pcall(creatures.stats)
        return ok and type(st) == "table" and tonumber(st.count) or 0
    end

    local function spell_name(id)
        if type(id) ~= "number" or id <= 0 or id > SPELL_ID_MAX then return nil end
        local ok, name = pcall(function() return core.spell_book.get_spell_name(id) end)
        if ok and type(name) == "string" and name ~= "" then return name end
        return nil
    end

    --- The one status worth a row, most urgent first, with the spell whose
    --- icon goes beside it. Crowd control; then who it is on -- but only
    --- while the ring under it is off, because the ring says that already;
    --- then "tapped" when tapped mobs are not greyed. "In combat" is not a
    --- row: it is the combat swords beside the level (card_unit).
    local function status_of(e, tapped)
        if e then
            local c = e.control
            if type(c) == "table" and (c.remaining or 0) > 0 then
                return string.format("%s %.0fs", spell_name(c.spell_id) or "controlled", c.remaining),
                    col.control, c.spell_id
            end
            if not S.aggro then
                if e.targeting_me then return "on you", col.on_you end
                if e.targeting_pet then return "on your pet", col.group end
                if e.target_guid and group_guids[e.target_guid] then return "on your group", col.group end
            end
        end
        if tapped and not S.grey_tapped then return "tapped", col.tapped end
        return nil
    end

    --- Your place on its threat table, in a group only: solo, "aggro #1 of
    --- 1" was "on you" said a second time, and "threat 0%" was nothing.
    local function threat_of(guid)
        local service = ctx.threat
        local board = service and service.get and service.get(guid) or nil
        if not board or (board.count or 0) <= 1 then return nil end
        local me = board.me
        if not me then return nil end
        if me.tanking then
            return string.format("aggro \194\183 #%d of %d", me.rank or 1, board.count), col.hot
        end
        local pct = me.percent or 0
        if pct <= 0 then return nil end
        local c = pct >= 90 and col.hot or (pct >= 70 and col.warm or col.safe)
        return string.format("threat %.0f%% \194\183 #%d of %d", pct, me.rank or 0, board.count), c
    end

    local function cast_of(e, now_ms)
        local c = e and e.casting
        if type(c) ~= "table" then return nil end
        if type(c.spell_id) ~= "number" or c.spell_id <= 0 or c.spell_id > SPELL_ID_MAX then return nil end
        local start_at, end_at = tonumber(c.start_at), tonumber(c.end_at)
        local left = (end_at and now_ms) and (end_at - now_ms) / 1000 or nil
        if left and left < 0 then return nil end
        local fraction = nil
        if start_at and end_at and end_at > start_at and now_ms then
            fraction = math.max(0, math.min(1, (now_ms - start_at) / (end_at - start_at)))
            if c.channel then fraction = 1 - fraction end
        end
        local text = spell_name(c.spell_id) or "Casting"
        if left then text = string.format("%s %.1fs", text, left) end
        return text, c.interruptible == true, fraction, c.spell_id
    end

    --- LOOT and SKIN for a corpse: JCore's loot.corpse (see LOOT at the top).
    local function corpse_state(obj)
        if not (jloot and jloot.corpse) then return false, false end
        local ok, lootable, skin = pcall(jloot.corpse, obj)
        if not ok then return false, false end
        return lootable == true, skin == true
    end

    -- SKIN ONLY WHAT YOUR SKILL CAN (1.67.0). The user: "compare Skinnable
    -- corpses to Current Skinning skill ... If its not skinnable by my level
    -- don't even draw the corpse". JCore 1.8.5's player.can_skin weighs the
    -- corpse's level against your Skinning: read from the client where it
    -- answers, else the rank you know, whose cap is then the skill. A corpse
    -- left with nothing (no LOOT) is not marked, and the automation does not
    -- try it. An older JCore, or a level that did not read, hides nothing.
    -- Each new answer is written to the trace: "fesp skinning: ...".
    local skin_said = nil
    local function skin_ok(level)
        local me = ctx.player
        if not (me and me.can_skin) then return true end
        local ok, yes, required, skill, how = pcall(me.can_skin, level)
        if not ok then return true end
        if required then
            local said = string.format("fesp skinning: skill %s (%s)", tostring(skill or "none"), tostring(how or "no skinning"))
            if said ~= skin_said then
                skin_said = said
                pcall(ctx.emit, "jcore.recorder.trace", string.format("%s; a level %d corpse asks for %d",
                    said, level, required))
            end
        end
        return yes == true
    end

    -- GATHER BY SKILL (1.88.0; see the top). Your Herbalism and Mining, read
    -- once a frame: the level, false without the profession, "?" when the
    -- read raised. Each new answer is written to the trace: "fesp gathering".
    local gather_skill, gather_said = {}, {}

    local function skill_now(prof)
        local v = gather_skill[prof]
        if v == nil then
            local ok, level = pcall(ctx.player.skill, prof)
            if not ok then v = "?" else v = tonumber(level) or false end
            gather_skill[prof] = v
            local said = string.format("fesp gathering: %s %s", prof, v == false and "none" or tostring(v))
            if said ~= gather_said[prof] then
                gather_said[prof] = said
                pcall(ctx.emit, "jcore.recorder.trace", said)
            end
        end
        return v
    end

    local function skill_of(prof)
        local v = skill_now(prof)
        return type(v) == "number" and v or nil
    end

    --- What the gathering switch makes of a herb or a vein: "show",
    --- "requires" with the skill it asks for, or "hide" (cfg.gather_verdict).
    local function gather_of(kind, name)
        if not (S.gather_skill_only and cfg and cfg.gather_verdict and cfg.gather_requirement) then return "show", nil end
        local me = ctx.player
        if not (me and type(me.skill) == "function") then return "show", nil end
        local profs = cfg.GATHER_PROFESSION
        local prof = profs and profs[kind]
        if not profs then prof = cfg.gather_requirement(kind, name) end
        if not prof or skill_now(prof) == "?" then return "show", nil end
        return cfg.gather_verdict(kind, name, skill_of)
    end

    -- --- the frame ----------------------------------------------------------

    local marks = {}
    local mark_n = 0

    -- WHAT THE AUTOMATION ACTS ON (1.54.0). world.lua's auto-loot, skinning
    -- and gathering read P.esp.corpses() and P.esp.nodes(), which the classic
    -- collector fills -- and it never runs on Forever, so neither had ever
    -- acted there. These are the same two lists in the collector's shape,
    -- filled every frame whatever the display switches, ranges and mark limit
    -- say (hiding a mark must not turn looting off), and only while a switch
    -- that reads them is on. No new reads: corpse_state, facts_of and
    -- object_of keep their own caches.
    local AUTO_REACH = 12           -- yards; the interact range slider tops out at 10
    local auto_corpses, auto_nodes = {}, {}
    local auto_corpse_n, auto_node_n = 0, 0
    local trace_at = -1e9

    -- The threat rows the panel, the alerts and the arrows read: built every
    -- frame whether or not the overlay is shown, as the classic ESP's are.
    local threats = {}
    local threat_n = 0

    -- What the quest paths read (1.55.4). modules/quests.lua draws a path to
    -- the nearest target of each quest from P.esp.entities(), the classic
    -- collector's list -- empty on Forever, so no path was ever drawn here.
    -- This is that list for the marks this frame: { obj, guid, distance,
    -- kind, quest_entries }, the entries from quests.lua's own index (the
    -- classic quest data: Forever's own quests are not in it). No new reads:
    -- the npc id is facts_of's, an object's name object_of's.
    local quest_entities = {}
    local quest_n = 0

    --- Your target first, then the category's weight, then nearest first in
    --- three-yard bands, then the guid: the Classic ESP's order. The band
    --- keeps two mobs at nearly the same distance from trading places, and
    --- their blocks trading slots on screen, every time one steps.
    local function by_relevance(a, b)
        if a.prio ~= b.prio then return a.prio > b.prio end
        if a.band ~= b.band then return a.band < b.band end
        return tostring(a.guid) < tostring(b.guid)
    end
    local function by_urgency(a, b)
        if a.on_me ~= b.on_me then return a.on_me end
        return a.d < b.d
    end

    local function level_of_player(player)
        local level = tonumber(ask(player, "get_level"))
        return level or 0
    end

    local function add_mark(obj, guid, row, d, dead, kind, cat, target_guid)
        mark_n = mark_n + 1
        local m = marks[mark_n] or {}
        marks[mark_n] = m
        m.obj, m.guid, m.row, m.d, m.dead, m.kind, m.cat = obj, guid, row, d, dead, kind, cat
        m.hp, m.loot, m.skin, m.tapped = nil, false, false, false
        m.name, m.requires = nil, nil
        m.prio = ((CATEGORY[cat] and CATEGORY[cat].prio) or 0) + (guid == target_guid and 1000 or 0)
        m.band = math.floor(d / BAND)
        return m
    end

    --- The category a living NPC is marked under, or nil.
    local function npc_category(obj, guid, row, f)
        local cat
        if f.pet then
            cat = "pet"
        elseif row.is_enemy then
            -- Boss, rare or elite from the creature cache (1.52.0).
            local r = RANK[f.rank or 0]
            cat = (f.ctype == CRITTER) and "critter" or (r and r.cat) or "normal"
        else
            cat = "friendly_npc"
        end
        -- A quest giver, or a mob an unfinished objective names, is a quest
        -- mark whatever it is: a KILL on a critter outranks the critter switch.
        if S.quests and cat ~= "pet" then
            if quests.giver(f.npc, f.flags) ~= nil then
                cat = "quest"
            elseif row.is_enemy then
                local name, source = name_of(obj, guid, f, row)
                local o = source ~= "type" and quests.objective(name) or nil
                if o and o.kind ~= "item" then cat = "quest" end
            end
            -- 1.53.0: what the game says about it, and what its kind drops.
            if cat ~= "quest" and quests.unit and quests.unit(guid, f.npc) then cat = "quest" end
        end
        return cat
    end

    --- Walks the sweep once: the marks to draw and the threats to list.
    local function collect(player, player_guid, master, t)
        mark_n, threat_n = 0, 0
        auto_corpse_n, auto_node_n = 0, 0
        for k in pairs(gather_skill) do gather_skill[k] = nil end
        stats.gather_hidden = 0
        local acting = not P.master_on or P.master_on()
        local want_corpses = acting and P.opt("autoloot_on", false) == true
        local want_nodes = acting and (P.opt("gather_herbs", false) == true or P.opt("gather_ore", false) == true
            or P.opt("gather_containers", false) == true)
        local list = units.units()
        stats.units = #list
        local enemies = ctx.enemies
        local my_level = level_of_player(player)
        local delta = P.opt("alert_level_delta", 2)
        local player_range = P.opt("alert_player_range", 60)
        local elite_range = P.opt("alert_elite_range", 35)
        local target_guid = nil
        do
            local combat = P.combat
            local ok, target = pcall(function() return combat and combat.target and combat.target() end)
            if ok and target then target_guid = units.guid(target) end
        end

        for i = 1, #list do
            local obj = list[i]
            local guid = units.guid(obj)
            local row = units.snapshot(obj)
            if guid and row and guid ~= player_guid and not row.is_self then
                local dead = row.dead == true
                local d = row.dist or math.huge
                local e = (not dead) and enemies and enemies.get and enemies.get(guid) or nil

                -- A corpse for the automation: ours to loot, or skinnable.
                if want_corpses and dead and not row.is_player and d <= AUTO_REACH then
                    local loot, skin = corpse_state(obj)
                    if skin and not skin_ok(facts_of(obj, guid, row, player, t).level) then skin = false end
                    if loot or skin then
                        auto_corpse_n = auto_corpse_n + 1
                        local c = auto_corpses[auto_corpse_n] or {}
                        auto_corpses[auto_corpse_n] = c
                        c.obj, c.guid, c.distance, c.skinnable = obj, guid, d, skin and not loot
                    end
                end

                if d <= master then
                    local cat, loot, skin
                    if dead then
                        if not row.is_player and S.on.corpse then
                            local f = facts_of(obj, guid, row, player, t)
                            loot, skin = corpse_state(obj)
                            if skin and not skin_ok(f.level) then skin = false end
                            if loot or skin then cat = "corpse" end
                        end
                    elseif row.is_player then
                        if group_guids[guid] then
                            cat = "party"
                        else
                            cat = row.is_enemy and "hostile_player" or "friendly_player"
                        end
                    elseif row.is_enemy or S.on.friendly_npc or S.on.pet or S.quests then
                        -- A friendly npc is only read when something could
                        -- mark it: its own switch, the pets', or the quests'.
                        cat = npc_category(obj, guid, row, facts_of(obj, guid, row, player, t))
                    end
                    if cat and S.on[cat] and d <= (S.range[cat] or master) then
                        local m = add_mark(obj, guid, row, d, dead, "unit", cat, target_guid)
                        m.loot, m.skin = loot == true, skin == true
                        local tapped, how = false, nil
                        if not dead and not row.is_player then tapped, how = tapped_of(guid) end
                        m.tapped, m.tap_client = tapped, how == "client"
                    end
                end

                -- A threat: a hostile player near enough, anything on you,
                -- or a mob well above your level coming at you.
                if not dead and row.is_enemy then
                    local on_me = e ~= nil and e.targeting_me == true
                    local is_threat = (row.is_player and d <= player_range) or on_me
                    if not is_threat and not row.is_player and d <= elite_range and e
                        and (e.activity == "approaching" or e.activity == "attacking") then
                        local f = facts_of(obj, guid, row, player, t)
                        local r = RANK[f.rank or 0]
                        is_threat = f.level >= my_level + delta or (r ~= nil and r.danger == true)
                    end
                    if is_threat then
                        threat_n = threat_n + 1
                        local th = threats[threat_n] or {}
                        threats[threat_n] = th
                        th.obj, th.guid, th.row, th.d, th.on_me = obj, guid, row, d, on_me
                    end
                end
            end
        end

        -- Game objects: what a quest uses (tagged "(Quest)" by the client, or
        -- named by an unfinished objective), then herbs, veins, chests and
        -- the other usable objects, each behind its own switch.
        if S.quests or S.nodes then
            local objs = units.objects and units.objects() or {}
            for i = 1, #objs do
                local obj = objs[i]
                local row = units.snapshot(obj)
                local guid = row and row.guid
                local d = row and row.dist or math.huge
                if guid and d <= master then
                    local c = object_of(obj, guid, t)
                    if c.name then
                        local cat, kind
                        if S.quests and quests.quest_object(c.name) then
                            cat, kind = "quest", "object"
                        elseif S.nodes then
                            cat, kind = node_kind(obj, c), "node"
                        end
                        if cat and S.on[cat] and d <= (S.range[cat] or master) then
                            -- A herb or vein by your skill (1.88.0): beyond
                            -- the profession not marked, beyond the skill
                            -- marked with what it asks for.
                            local verdict, need = "show", nil
                            if kind == "node" then verdict, need = gather_of(cat, c.name) end
                            if verdict == "hide" then
                                stats.gather_hidden = stats.gather_hidden + 1
                            else
                                local m = add_mark(obj, guid, row, d, false, kind, cat, target_guid)
                                if kind == "node" then
                                    m.name = c.name
                                    if verdict == "requires" then m.requires = need end
                                end
                            end
                        end
                    end
                end
            end
        end
        -- Herbs, veins and chests for the automation, by the Classic ESP's
        -- name rules: the gathering kind, whatever the mark's category.
        if want_nodes then
            local objs = units.objects and units.objects() or {}
            for i = 1, #objs do
                local obj = objs[i]
                local row = units.snapshot(obj)
                local guid = row and row.guid
                local d = row and row.dist or math.huge
                if guid and d <= AUTO_REACH then
                    local c = object_of(obj, guid, t)
                    -- The gathering switch here too (1.88.0): a herb or vein your
                    -- skill cannot take is not offered, one it is short of says so
                    -- (world.lua passes it by).
                    local verdict, need = "show", nil
                    if c.base and c.name then verdict, need = gather_of(c.base, c.name) end
                    if c.base and c.name and verdict ~= "hide" then
                        auto_node_n = auto_node_n + 1
                        local n = auto_nodes[auto_node_n] or {}
                        auto_nodes[auto_node_n] = n
                        n.obj, n.guid, n.kind, n.name, n.distance = obj, guid, c.base, c.name, d
                        n.requires = verdict == "requires" and need or nil
                    end
                end
            end
        end
        for i = auto_corpse_n + 1, #auto_corpses do auto_corpses[i] = nil end
        for i = auto_node_n + 1, #auto_nodes do auto_nodes[i] = nil end
        for i = mark_n + 1, #marks do marks[i] = nil end
        for i = threat_n + 1, #threats do threats[i] = nil end
        table.sort(marks, by_relevance)
        local cap = S.max_marks
        if cap > 0 and mark_n > cap then
            for i = cap + 1, mark_n do marks[i] = nil end
            mark_n = cap
        end
        table.sort(threats, by_urgency)
        stats.threats = threat_n
    end

    --- The colour of the frame's next ring, thinned by how many there are:
    --- this frame's so far or last frame's whole count, whichever is more.
    --- Made once per (style, count).
    local function ring_color(style)
        RING.n = RING.n + 1
        local n = math.min(RING.stack, math.max(RING.last, RING.n))
        local c = style.colors[n]
        if not c then
            local a = style.alpha * math.max(style.floor, 1 / math.sqrt(n))
            c = P.color(style.rgb[1], style.rgb[2], style.rgb[3], math.floor(a + 0.5))
            style.colors[n] = c
        end
        return c
    end

    -- --- the new look (1.88.0) ---------------------------------------------------

    --- A colour made from another once per colour: `make` may answer nil
    --- (an older JCore without draw.blend or draw.with_alpha).
    local function per_color(make)
        local made = setmetatable({}, { __mode = "k" })
        return function(c)
            if c == nil then return nil end
            local v = made[c]
            if v == nil then
                v = make(c) or false
                made[c] = v
            end
            return v or nil
        end
    end
    -- A curtain box's top: its colour nearly clear.
    local curtain_top = per_color(function(c) return draw.with_alpha and draw.with_alpha(c, 0.15) end)
    -- A herb or vein above your skill: its colour greyed.
    local dimmed = per_color(function(c) return draw.blend and draw.blend(c, col.dim, 0.55) end)

    --- A full ring on the ground: JCore's shader ring, a band from `inner`
    --- of the radius out to it; the outline circle on a JCore without it.
    local function ground_ring(pos, radius, c, inner, thickness, layer, fade)
        if draw.ring_3d then
            draw.ring_3d(pos, radius, 1, c, { bg = col.clear, inner = inner, outer = 1.0,
                thickness = thickness, layer = layer })
        elseif draw.circle_3d then
            draw.circle_3d(pos, radius, c, { layer = layer, thickness = thickness, fade = fade })
        end
    end

    --- A pillar of light over a far mark worth walking to: a rare, a boss or
    --- a quest mark in its mark's colour, a corpse to loot in the loot
    --- colour. Never a node: modules/beacons.lua has those. At most
    --- BEACON_MAX a frame, the marks being in order of relevance.
    local beacon_n = 0
    local function draw_beacon(m, color, layer_world)
        if not (S.beacons and draw.beacon_3d) or m.kind == "node" then return end
        if beacon_n >= BEACON_MAX or not (m.d > S.beacon_from) then return end
        local c = nil
        if m.dead then
            if m.loot then c = col.loot end
        elseif BEACON_CATS[m.cat] then
            c = color or col.quest
        end
        if not c then return end
        local pos = m.row.pos or units.position(m.obj)
        if not pos then return end
        beacon_n = beacon_n + 1
        draw.beacon_3d(pos, c, { height = BEACON_HEIGHT, layer = layer_world, droppable = true })
    end

    --- The ground under one mark: box, cast ring, aggro ring, line.
    local function draw_world(m, f, e, color, player, layer_world, layer_units, now_ms)
        local pos = m.row.pos or units.position(m.obj)
        if not pos then return end
        if m.kind == "node" then
            if S.node_ring then ground_ring(pos, NODE_RING, color, RING_INNER.node, 1.5, layer_world) end
            return
        end
        if S.box and m.d <= S.full_range then
            if S.box_style == (cfg and cfg.BOX_CURTAIN) and draw.curtain_3d then
                -- 1.88.0: a short curtain round it in its colour, just
                -- outside its reach, fading to nearly clear at the top.
                local reach = tonumber(f.radius) or 0
                draw.curtain_3d(pos, math.max(0.8, reach + 0.2), color, {
                    to = curtain_top(color), height = CURTAIN_HEIGHT, points = 16, rings = 2, verticals = 4,
                    fill = 0.18, lod = true, layer = layer_world, droppable = true,
                })
            else
                local opts = { layer = layer_units, thickness = 1.3 }
                if S.box_style == (cfg and cfg.BOX_FULL) then
                    if draw.unit_box then draw.unit_box(m.obj, color, opts) end
                elseif S.box_style == (cfg and cfg.BOX_3D) then
                    opts.layer = layer_world
                    if draw.unit_box_3d then draw.unit_box_3d(m.obj, color, opts) end
                elseif draw.unit_box_corners then
                    -- Corners, and the curtain on a JCore without curtain_3d.
                    draw.unit_box_corners(m.obj, color, opts)
                end
            end
        end
        if not e then return end
        -- THE CAST RING (1.85.0): JCore 1.11's ring_3d on the ground under a
        -- caster, just outside its aggro ring, filling as the cast runs (a
        -- channel empties). It starts in the cast bar's colour -- purple you
        -- can kick, amber you cannot -- and turns red as it closes.
        if S.cast_ring and e.casting and draw.ring_3d then
            local _, kick, fraction = cast_of(e, now_ms)
            if fraction then
                local radius = ((f.radius and f.radius > 0) and f.radius or 1.5) + CAST_RING_GAP
                draw.ring_3d(pos, radius, fraction, kick and col.kick or col.cast,
                    { to = col.on_you, bg = col.bar_back, layer = layer_world })
            end
        end
        local on_me, on_mine = e.targeting_me == true,
            e.targeting_pet == true or (e.target_guid ~= nil and group_guids[e.target_guid] == true)
        if not on_me and not on_mine then return end
        local c = on_me and col.on_you or col.group
        if S.aggro and (draw.ring_3d or draw.circle_3d) then
            local radius = (f.radius and f.radius > 0) and f.radius or 1.5
            local style = on_me and RING.on_you or RING.group
            ground_ring(pos, radius, ring_color(style), RING_INNER.aggro, style.thickness, layer_world, RING.fade)
        end
        if S.lines and on_me and m.d > LINE_ARRIVED and draw.line_3d then
            local me = units.position(player)
            if me then
                local geometry = ctx.geometry
                local function chest(p)
                    if geometry and geometry.vec then
                        local ok, v = pcall(geometry.vec, p.x, p.y, p.z + 1)
                        if ok and v then return v end
                    end
                    return { x = p.x, y = p.y, z = p.z + 1 }
                end
                draw.line_3d(chest(pos), chest(me), c, { layer = layer_world, thickness = 1.5 })
            end
        end
    end

    -- --- quest areas (1.53.0) --------------------------------------------------
    --
    -- Each quest's area from the game's quest map (esp/forever_quests'
    -- locations): a ring on the ground there, a line from you towards it and
    -- its title with the distance -- "TURN IN: <quest>" in green for a
    -- complete one. The Quests page decides it: "Point to the nearest known
    -- spawn" (lines), its range and line length, the path limit, paths in
    -- dungeons, and "A live target beats a map marker".

    local place_seen = {}     -- quest id -> true: a mob of it is marked this frame
    local PLACE_RING = 6.0    -- yards
    local PLACE_RING_WITHIN = 200
    local FRONT = 1.75        -- radians either side of your facing: the label is drawn

    --- Is pos in front of you (within FRONT of your facing)? A point behind
    --- the camera projects mirrored, so a label is only drawn in front.
    local function in_front(player, me, pos)
        local d = ask(player, "get_direction")
        if type(d) ~= "table" or type(d.x) ~= "number" or type(d.y) ~= "number" or (d.x == 0 and d.y == 0) then
            return true
        end
        local facing = atan2(d.y, d.x)
        local angle = atan2(pos.y - me.y, pos.x - me.x)
        local rel = (angle - facing + math.pi) % (2 * math.pi) - math.pi
        return math.abs(rel) <= FRONT
    end

    local function ground_z(x, y, near_z)
        local ok, h = pcall(core.get_height_for_position, { x = x, y = y, z = near_z + 50 })
        if ok and type(h) == "number" and h ~= 0 and math.abs(h - near_z) < 300 then return h end
        return near_z
    end

    local function draw_places(player, size, layer, layer_world)
        stats.places = 0
        if not (S.quests and quests and quests.locations) then return end
        local list = quests.locations()
        if #list == 0 then return end
        local me = units.position(player)
        if not me then return end
        local range = tonumber(P.opt("quest_spawn_range", 2000)) or 2000
        local max_n = tonumber(P.opt("quest_max_lines", 3)) or 3
        local lines_on = P.opt("quest_lines", true) and P.opt("quest_spawn_paths", true)
        local line_len = tonumber(P.opt("quest_spawn_line_length", 60)) or 60
        local prefer_live = P.opt("quest_paths_prefer_live", true)
        if lines_on and not P.opt("quest_lines_in_dungeons", false) then
            local ok, kind = pcall(core.get_instance_type)
            kind = ok and type(kind) == "string" and kind:lower() or "none"
            if kind ~= "" and kind ~= "none" and kind ~= "pvp" and kind ~= "arena" then lines_on = false end
        end
        for i = 1, #list do
            local l = list[i]
            l.d = math.sqrt((l.x - me.x) ^ 2 + (l.y - me.y) ^ 2)
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        local shown = 0
        for i = 1, #list do
            if shown >= max_n then break end
            local l = list[i]
            if l.d <= range and not (prefer_live and place_seen[l.quest.id]) then
                shown = shown + 1
                local p = l.poi
                if not p.ground then p.ground = ground_z(l.x, l.y, me.z or 0) end
                local pos = { x = l.x, y = l.y, z = p.ground }
                local c = l.done and col.safe or col.quest
                if l.d <= PLACE_RING_WITHIN then
                    ground_ring(pos, PLACE_RING, c, RING_INNER.place, 2.0, layer_world)
                end
                local tip = pos
                if lines_on and draw.line_3d and l.d > PLACE_RING then
                    local k = math.min(1, line_len / l.d)
                    tip = { x = me.x + (l.x - me.x) * k, y = me.y + (l.y - me.y) * k,
                        z = (me.z or 0) + (pos.z - (me.z or 0)) * k }
                    draw.line_3d({ x = me.x, y = me.y, z = (me.z or 0) + 0.3 }, { x = tip.x, y = tip.y, z = tip.z + 0.3 },
                        c, { layer = layer_world, thickness = 2.0 })
                end
                local at = in_front(player, me, pos) and draw.w2s and draw.w2s(pos) or nil
                if not at and tip ~= pos and in_front(player, me, tip) and draw.w2s then at = draw.w2s(tip) end
                if at and card then
                    -- The ? of a quest to hand in, then its title and how far.
                    card.start(size, layer)
                    card.pill(c)
                    local marked = l.done and add_icon("quest_turnin")
                    card.text(string.format("%s%s \194\183 %.0fy", (l.done and not marked) and "TURN IN: " or "",
                        l.quest.title, l.d), col.text)
                    card.place(at.x, at.y, { above = true, claim = false })
                end
            end
        end
        stats.places = shown
    end

    --- The quest paths' list, from this frame's marks (see quest_entities).
    local function collect_quest_entities(player, t)
        quest_n = 0
        local Q = P.quests
        if Q and Q.quest_entries and P.opt("quest_lines", true) then
            for i = 1, mark_n do
                local m = marks[i]
                if m and not m.dead and not (m.row and m.row.is_player) then
                    local entries = nil
                    if m.kind == "unit" then
                        local f = facts_of(m.obj, m.guid, m.row, player, t)
                        local npc = f and f.npc
                        if type(npc) == "number" and npc > 0 then
                            local ok, e = pcall(Q.quest_entries, m.obj, nil, npc)
                            if ok then entries = e end
                        end
                    elseif m.kind == "object" or m.kind == "node" then
                        local c = object_of(m.obj, m.guid, t)
                        if c and c.name then
                            local ok, e = pcall(Q.quest_entries, m.obj, c.name, false, true)
                            if ok then entries = e end
                        end
                    end
                    if entries then
                        quest_n = quest_n + 1
                        local q = quest_entities[quest_n] or {}
                        quest_entities[quest_n] = q
                        q.obj, q.guid, q.distance, q.kind, q.quest_entries = m.obj, m.guid, m.d, m.kind, entries
                    end
                end
            end
        end
        for i = quest_n + 1, #quest_entities do quest_entities[i] = nil end
    end

    -- --- the icon card (1.69.0) -------------------------------------------------
    --
    -- The user, 2026-10-04: "cleaner, more in-game icons, nothing double". Every
    -- mark is a card (esp/card.lua) of the game's own icons (esp/art.lua): what
    -- it is before its name, what to do with it before its quest's progress,
    -- the elite's dragon ring, a cast's spell and the shield of one that cannot
    -- be interrupted. Words only for names, numbers and quest titles, and EACH
    -- FACT ONCE:
    --   on you, your pet, your group   the ring under it; a row only with the ring off
    --   in combat with somebody else    the combat swords, no words
    --   elite, rare, boss               the dragon ring or the skull, no pill
    --   health                          the bar; a number only when asked for
    --   threat                          only in a group (solo it said "on you" again)
    --   loot, skin                      the bag and the pelt, no words
    --   a name it does not know         the icon alone ("Elemental" said it twice)
    -- How much a category's mark says is its own setting (<key>_detail):
    -- everything; icon, name, health and casts; or the icon alone.
    -- An icon that has not loaded yet is left out for that frame; where the
    -- art pack is missing altogether, the old word stands in.

    local DETAIL_FULL = (cfg and cfg.DETAIL_FULL) or 1
    local DETAIL_ICON = (cfg and cfg.DETAIL_ICON) or 3
    local COLOR_CATEGORY = (cfg and cfg.COLOR_MODE_CATEGORY) or 1
    local COLOR_DIFFICULTY = (cfg and cfg.COLOR_MODE_DIFFICULTY) or 3
    local SEP = " \194\183 "
    local NO_FACTS = { level = 0 }

    local hp_full, hp_mid, hp_low = P.color(105, 200, 115), P.color(230, 190, 85), P.color(225, 85, 75)
    --- Green, amber, red as it empties: the bar says how dead, not what it is.
    local function health_color(f)
        if f > 0.6 then return hp_full end
        if f > 0.3 then return hp_mid end
        return hp_low
    end
    local guess_tint = P.color(255, 255, 255, 140)
    local difficulty_col = {}
    for band, rgb in pairs((cfg and cfg.DIFFICULTY_RGB) or {}) do difficulty_col[band] = P.color(rgb[1], rgb[2], rgb[3]) end

    -- --- what a beast teaches (1.7.6) -----------------------------------------------
    --
    -- See WHAT A BEAST TEACHES at the top. One pill per skill: its icon, then
    -- "Bite 3". The frame's time is render's, set before the marks are built.

    local BEAST_TYPE = 1              -- get_creature_type
    local PET_ROWS = 5                -- skills on one beast (a family has four, and Cower)
    local pet_col = {
        sure = P.color(185, 140, 255),    -- the Classic ESP's TAME violet
        new = P.color(120, 200, 120),
    }
    local frame_now = nil

    --- The rows for a beast a hunter can tame: nothing for anyone else, or
    --- with the switch off. Returns how many rows it added.
    local function card_beast(m, f, row)
        if not S.pet_skills or row.is_player or f.pet or f.ctype ~= BEAST_TYPE then return 0 end
        local tame = P.tame
        if not (tame and tame.beast) then return 0 end
        local ok, t = pcall(tame.beast, f.npc, f.level, m.guid, frame_now)
        if not ok or type(t) ~= "table" then return 0 end
        local shown = 0
        for i = 1, #t.skills do
            local s = t.skills[i]
            if shown >= PET_ROWS then break end
            if s.sure or S.pet_guesses then
                shown = shown + 1
                local later = not t.can_now
                card.pill((s.sure and not later) and pet_col.sure or nil)
                local tint = (later or not s.sure) and guess_tint or nil
                local iconed = s.icon ~= nil and add_icon("pet." .. s.icon, tint)
                if not iconed and type(s.spell) == "number" and s.spell > 0 and s.spell <= SPELL_ID_MAX then
                    card.icon("spell:" .. s.spell, tint)
                end
                card.text(string.format("%s %d%s", s.name, s.rank, s.sure and "" or "?"),
                    (s.sure and not later) and col.text or col.dim)
                if s.new and not later then card.text(SEP .. "new", pet_col.new) end
                if later and shown == 1 then card.text(SEP .. "tame at " .. tostring(t.level), col.dim) end
            end
        end
        return shown
    end

    -- --- pristine (1.7.6) ------------------------------------------------------------
    --
    -- See PRISTINE at the top. One pill per Pristine item a kind of creature
    -- has been seen to give: its icon, its name in the game's green, "rare".

    local pristine_col = P.color(30, 255, 0)

    --- The Pristine items skinning this kind of creature can give, or nil.
    local function pristine_of(npc)
        if not (S.pristine and SKINNING and type(SKINNING.pristine) == "table") then return nil end
        if type(npc) ~= "number" or npc <= 0 then return nil end
        return SKINNING.pristine[npc]
    end

    --- One pill per item of the list; dimmed, with the Skinning it asks
    --- for, when `need` says yours does not reach it. Returns how many.
    local function pristine_rows(list, need)
        local tint = need and guess_tint or nil
        for i = 1, #list do
            local id = list[i]
            local item = SKINNING.items[id] or {}
            card.pill()
            if not add_icon("item." .. tostring(id), tint) then card.icon("item:" .. tostring(id), tint) end
            card.text(item.name or ("item " .. tostring(id)), need and col.dim or pristine_col)
            card.text(SEP .. (need and string.format("(Requires Skill %d)", need) or "rare"), col.dim)
        end
        return #list
    end

    --- Under a living creature a skin can give Pristine from: nothing
    --- without Skinning, dimmed above your skill. A JCore that cannot say
    --- (no player.skill, no can_skin) hides and dims nothing. Returns how
    --- many rows.
    local function card_pristine(m, f, row)
        if row.is_player or f.pet then return 0 end
        local list = pristine_of(f.npc)
        if not list then return 0 end
        local me = ctx.player
        if me and type(me.skill) == "function" and skill_now("skinning") == false then return 0 end
        local need = nil
        if me and me.can_skin then
            local ok, yes, required = pcall(me.can_skin, f.level)
            if ok and yes == false and tonumber(required) then need = tonumber(required) end
        end
        return pristine_rows(list, need)
    end

    -- A town npc's service, by its npc flags (the client's UNIT_NPC_FLAGS; a
    -- vendor that repairs read 4224 = 0x1080 on Forever), the most telling
    -- first: an armourer sells too, but the anvil is why you walk over.
    local SERVICES = {
        { 0x2000, "service.flight" }, { 0x10000, "service.inn" }, { 0x20000, "service.bank" },
        { 0x200000, "service.auction" }, { 0x400000, "service.stable" }, { 0x4000, "service.spirit" },
        { 0x8000, "service.spirit" }, { 0x100000, "service.battlemaster" }, { 0x20, "service.trainer" },
        { 0x40, "service.profession" }, { 0x1000, "service.repair" }, { 0x400, "service.poisons" },
        { 0x800, "service.reagents" }, { 0x100, "service.ammo" }, { 0x200, "service.food" },
        { 0x80, "service.vendor" }, { 0x10, "service.trainer" },
    }
    local function service_of(flags)
        flags = tonumber(flags)
        if not flags or flags <= 0 then return nil end
        for i = 1, #SERVICES do
            if math.floor(flags / SERVICES[i][1]) % 2 == 1 then return SERVICES[i][2] end
        end
        return nil
    end
    M.service_of = service_of

    -- THE TOWN'S NPCS, FOR THE ROUTES (1.89.0). Read-only: the living npcs
    -- near you that are not your enemies, with their npc flags, the service
    -- those say, the creature cache's title (<Armorer>) and where they stand,
    -- for modules/routes.lua's vendor and repair beacon. Off the facts kept
    -- per guid above (2 s), so an npc the ESP marks costs nothing more. It
    -- marks nothing and changes nothing the ESP draws.
    local town, town_n = {}, 0
    ---@param range number yards
    ---@return table[] rows { obj, guid, d, pos, flags, service, title, npc }, the same table each call
    function M.town_npcs(range)
        town_n = 0
        range = tonumber(range) or 100
        local list = units.units and units.units() or {}
        local player = units.player and units.player()
        local t = now()
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot(obj)
            local guid = row and row.guid
            if guid and not row.is_self and not row.is_player and not row.is_enemy and not row.dead
                and (row.dist or math.huge) <= range then
                local f = facts_of(obj, guid, row, player, t)
                if not f.pet and (f.flags or 0) > 0 then
                    town_n = town_n + 1
                    local r = town[town_n] or {}
                    town[town_n] = r
                    r.obj, r.guid, r.d, r.pos, r.flags, r.npc = obj, guid, row.dist, row.pos, f.flags, f.npc
                    r.service, r.title = service_of(f.flags), f.info and f.info.title or nil
                end
            end
        end
        for i = town_n + 1, #town do town[i] = nil end
        return town
    end

    -- A quest objective's kind as the cursor the game shows for it, and its
    -- word for when there is no art.
    local QUEST_ICON = { kill = "kill", item = "loot", found = "use" }
    local QUEST_WORD = { kill = "KILL", item = "LOOT", found = "USE" }
    local OBJECT_ICON = { COLLECT = "loot", USE = "use", ["TURN IN"] = "quest_turnin", ["PICK UP"] = "quest_pickup" }

    --- The colour a living unit's name is drawn in: grey when someone else
    --- has tagged it, then the colour mode -- its reaction to you (the
    --- default), its level's difficulty, or its category's own colour.
    local function unit_color(m, f, row, my_level)
        if m.tapped and S.grey_tapped then return col.tapped end
        if m.cat == "party" or m.cat == "pet" then return category_color(m.cat) end
        if S.color_mode == COLOR_CATEGORY then return category_color(m.cat) end
        if row.is_player then return row.is_enemy and col.player or col.friendly end
        if not row.is_enemy then return col.friendly end
        if S.color_mode == COLOR_DIFFICULTY and (f.level or 0) > 0 and cfg and cfg.difficulty_band then
            return difficulty_col[cfg.difficulty_band(f.level, my_level)] or col.hostile
        end
        return f.hostile and col.hostile or col.neutral
    end

    -- The facts row's texts, built per mark into scratch arrays.
    local fact_t, fact_c = {}, {}

    --- A living unit's card. Returns what its quest row says, for the trace.
    local function card_unit(m, f, name, source, e, now_ms, my_level, color, detail, layer)
        local row = m.row
        local note = nil
        local giver = nil
        if S.quests and not row.is_player then giver = quests.giver(f.npc, f.flags) end
        if giver then note = (giver == "turnin" and "TURN IN") or (giver == "pickup" and "PICK UP") or "QUEST" end

        -- What it is: a quest giver's ! or ?, a town service, a class crest,
        -- a creature type.
        local key
        if giver == "turnin" then key = "quest_turnin"
        elseif giver == "pickup" then key = "quest_pickup"
        elseif giver then key = "quest_none"
        elseif row.is_player then key = f.class and ("class." .. tostring(f.class)) or nil
        elseif not row.is_enemy then key = service_of(f.flags) end
        key = key or ("creature." .. tostring(f.ctype or 10))

        local hp = m.hp or 0
        -- The rank's art, and its word on the name row (THE RANK IN WORDS).
        local rank_key, rank_word, rank_col = nil, nil, nil
        if S.badges and not row.is_player then
            local r = RANK[f.rank or 0]
            if r then
                rank_key, rank_word, rank_col = r.art, r.word, category_color(r.cat)
            elseif row.is_enemy and (f.level or 0) < 0 then
                rank_key, rank_word, rank_col = "boss", "BOSS", category_color("boss")
            end
        end
        local fight_key, fight_guess = nil, false
        if S.fight_role and fight and fight.role then
            local kind, sure = fight.role({
                is_player = row.is_player, npc_id = f.npc, creature_type = f.ctype,
                name = source ~= "type" and name or nil, class_id = f.class,
            })
            if kind then fight_key, fight_guess = "fight." .. kind, sure == "guess" end
        end
        -- Fighting somebody else: what is on you or yours has its ring.
        local busy = S.status and e ~= nil and e.in_combat == true and not e.targeting_me
            and not e.targeting_pet and not (e.target_guid and group_guids[e.target_guid])

        local nf = 0
        -- With no art pack at all, how it fights falls back to its word, at
        -- the front of the facts. The rank's word is on the name row already.
        if not (art and art.available) then
            rank_key = nil
            if fight_key then
                local kind = fight_key:sub(7)
                nf = nf + 1
                fact_t[nf] = ((cfg and cfg.FIGHT_WORD and cfg.FIGHT_WORD[kind]) or kind) .. (fight_guess and "?" or "")
                fact_c[nf] = col[kind] or col.text
                fight_key = nil
            end
        end
        if row.is_enemy or row.is_player then
            if S.level and (f.level or 0) > 0 then
                nf = nf + 1
                fact_t[nf] = tostring(f.level)
                fact_c[nf] = row.is_enemy and level_color(f.level, my_level) or col.text
            end
        elseif S.title and f.info and f.info.title then
            nf = nf + 1
            fact_t[nf], fact_c[nf] = "<" .. f.info.title .. ">", col.dim
        end
        if S.health_text and hp > 0 and hp < 0.995 then
            nf = nf + 1
            if S.health_exact and (f.max_health or 0) > 0 then
                fact_t[nf] = string.format("%d/%d", math.floor(hp * f.max_health + 0.5), f.max_health)
            else
                fact_t[nf] = string.format("%d%%", math.floor(hp * 100 + 0.5))
            end
            fact_c[nf] = col.text
        end
        if S.distance then
            nf = nf + 1
            fact_t[nf], fact_c[nf] = string.format("%.0fy", m.d), col.dim
        end

        card.start(S.size, layer)
        card.head()
        local iconed = false
        if S.icon or (giver and S.quest_tag) then iconed = add_icon(key) end
        local named
        if detail == DETAIL_ICON then
            named = not iconed
        else
            -- A name it does not know is only what the icon already says.
            local known = source ~= "type" and source ~= "class"
            named = S.name and (known or not iconed)
        end
        if named then card.text(name, color) end
        if rank_word then
            if named then card.text(SEP, col.dim) end
            card.text(rank_word, rank_col)
        end
        if detail == DETAIL_ICON then return note end
        local full = detail == DETAIL_FULL
        if full and nf == 0 then
            -- No facts to sit beside: the icons join the name.
            if rank_key then add_icon(rank_key) end
            if fight_key then add_icon(fight_key, fight_guess and guess_tint or nil) end
            if busy then add_icon("combat") end
        end

        if S.bar and hp > 0 and (hp < 0.995 or S.bar_always) then
            card.bar(hp, health_color(hp), S.bar_w, S.bar_h,
                S.game_bars and art and art.ref("statusbar") or nil, art and art.cells.statusbar or nil)
        end

        if full then
            if nf > 0 then
                card.pill()
                if rank_key then add_icon(rank_key) end
                if fight_key then add_icon(fight_key, fight_guess and guess_tint or nil) end
                if busy then add_icon("combat") end
                for i = 1, nf do
                    if i > 1 then card.text(SEP, col.dim) end
                    card.text(fact_t[i], fact_c[i])
                end
            end

            -- What a quest wants with it: the objective's cursor, its count,
            -- the quest's title.
            if S.quests and S.quest_tag and not row.is_player then
                local kind, have, need, title = nil, nil, nil, nil
                local said = quests.unit and quests.unit(m.guid, f.npc) or nil
                if said then
                    kind, have, need, title = said.kind or "other", said.have, said.need, said.title
                    note = note and (note .. " + " .. said.text) or said.text
                    if said.qid then place_seen[said.qid] = true end
                elseif source ~= "type" and row.is_enemy then
                    local o = quests.objective(name)
                    if o and o.kind ~= "item" then
                        kind, have, need = "kill", o.have, o.need
                        local text = string.format("KILL %d/%d", o.have or 0, o.need or 0)
                        note = note and (note .. " + " .. text) or text
                    end
                end
                -- On something you can attack, what the quest wants done is
                -- to kill it, whatever the game called the objective: "Roiling
                -- Winds destroyed" comes tagged as a thing found.
                if row.is_enemy and (kind == "found" or kind == "other") then kind = "kill" end
                if kind then
                    card.pill()
                    local any = false
                    if not add_icon(QUEST_ICON[kind] or "quest_none") and QUEST_WORD[kind] then
                        card.text(QUEST_WORD[kind], col.quest)
                        any = true
                    end
                    if have and need and need > 0 then
                        card.text((any and " " or "") .. string.format("%d/%d", have, need), col.text)
                        any = true
                    end
                    if title and title ~= "" then
                        card.text((any and SEP or "") .. title, col.quest)
                    elseif not any then
                        card.text("quest", col.quest)
                    end
                elseif giver and not iconed then
                    -- The giver's mark is its icon; with no art, its word.
                    card.pill(col.quest)
                    card.text(note, col.quest)
                end
            end

            if S.status then
                local text, c, spell = status_of(e, m.tapped)
                if text then
                    card.pill(c)
                    add_spell(spell)
                    card.text(text, col.text)
                end
            end
            if S.threat and row.is_enemy then
                local text, c = threat_of(m.guid)
                if text then
                    card.pill(c)
                    card.text(text, c)
                end
            end
        end

        -- What it teaches a hunter, at every detail but the icon alone.
        card_beast(m, f, row)
        -- The Pristine its skin can give a skinner (1.7.6), the same.
        card_pristine(m, f, row)

        if S.cast then
            local text, kick, fraction, spell = cast_of(e, now_ms)
            if text then
                local c = kick and col.kick or col.cast
                card.pill(c)
                add_spell(spell)
                if not kick then add_icon("shield") end
                card.text(text, col.text)
                card.under(fraction or 1, c)
            end
        end
        return note
    end

    -- --- what skinning gives (1.7.6) ------------------------------------------------
    --
    -- See WHAT SKINNING GIVES at the top. One pill per item: its icon, its
    -- name in its quality's colour, how many when more than one, its chance.

    local SKIN_ROWS = 8             -- the longest table (a boss's) has eight
    -- The game's item quality colours, grey to orange; white is the text's.
    local quality_col = {
        [0] = P.color(157, 157, 157), [1] = col.text, [2] = P.color(30, 255, 0),
        [3] = P.color(0, 112, 221), [4] = P.color(163, 53, 238), [5] = P.color(255, 128, 0),
    }

    --- "60%", or "3.4%" under ten.
    local function chance_text(pct)
        if pct >= 9.95 then return string.format("%d%%", math.floor(pct + 0.5)) end
        local s = string.format("%.1f", pct):gsub("%.0$", "")
        return s .. "%"
    end

    --- The items skinning this kind of corpse gives, or nil.
    local function skin_loot(npc)
        if not SKINNING or type(npc) ~= "number" or npc <= 0 then return nil end
        local id = (SKINNING.alias and SKINNING.alias[npc]) or npc
        return SKINNING.loot[id]
    end

    --- The rows under a corpse your Skinning can take, its Pristine last.
    --- Returns how many.
    local function card_skin_loot(m, f)
        if not m.skin then return 0 end
        local npc = f and f.npc
        local list = S.skin_loot and skin_loot(npc) or {}
        local shown = 0
        for i = 1, #list do
            if shown >= SKIN_ROWS then break end
            local row = list[i]
            local id, pct = row[1], tonumber(row[2]) or 0
            local item = SKINNING.items[id] or {}
            shown = shown + 1
            card.pill()
            if not add_icon("item." .. tostring(id)) then card.icon("item:" .. tostring(id)) end
            card.text(item.name or ("item " .. tostring(id)), quality_col[item.quality or 1] or col.text)
            local lo, hi = tonumber(row[3]) or 1, tonumber(row[4]) or 1
            if hi > 1 then
                card.text(lo == hi and string.format(" x%d", hi) or string.format(" x%d-%d", lo, hi), col.text)
            end
            card.text(SEP .. chance_text(pct), col.dim)
        end
        -- Your Skinning reaches it (m.skin), so the Pristine is never dimmed.
        local pristine = pristine_of(npc)
        if pristine then shown = shown + pristine_rows(pristine) end
        return shown
    end

    --- A corpse: the bag when it has loot for you, the pelt when you can
    --- skin it, and how far; under it, what skinning it gives (1.7.6).
    local function card_corpse(m, f, name, detail, layer)
        card.start(S.size, layer)
        card.head()
        local words = false
        if m.loot and not add_icon("loot") then
            card.text("LOOT", col.loot)
            words = true
        end
        if m.skin and not add_icon("skin") then
            card.text((words and " " or "") .. "SKIN", col.skin)
            words = true
        end
        if detail == DETAIL_ICON and not words then return end
        local any = words
        if S.corpse_name and S.name and name and name ~= "" then
            card.text((any and SEP or "") .. name, category_color("corpse"))
            any = true
        end
        if S.distance and detail == DETAIL_FULL then
            card.text((any and SEP or "") .. string.format("%.0fy", m.d), col.dim)
        end
        if detail ~= DETAIL_ICON then card_skin_loot(m, f) end
    end

    --- A herb, a vein, a chest: its profession's icon, its name, how far --
    --- one line. One above your skill (1.88.0) is dimmed, icon and all, and
    --- says what it asks for: "Mithril Deposit (Requires Skill 175)".
    local function card_node(m, name, color, detail, layer)
        card.start(S.size, layer)
        card.head()
        local iconed = S.icon and add_icon("node." .. tostring(m.cat), m.requires and guess_tint or nil) or false
        if detail == DETAIL_ICON and iconed then return end
        local any = false
        local need = m.requires and string.format("(Requires Skill %d)", m.requires) or nil
        if S.node_label and name ~= "" then
            card.text(need and (name .. " " .. need) or name, color)
            any = true
        elseif need then
            card.text(need, color)
            any = true
        end
        if S.distance and detail == DETAIL_FULL then
            card.text((any and SEP or "") .. string.format("%.0fy", m.d), col.dim)
        end
    end

    --- An object a quest wants: what to do with it (the cursor), its name,
    --- then the count, the quest's title and how far. Returns the trace's
    --- note and the name.
    local function card_object(m, raw, detail, layer)
        local _, display, o, info = quests.quest_object(raw)
        local name = display or "?"
        local word = (info and info.word) or (o and (o.kind == "item" and "COLLECT" or "USE")) or "USE"
        local counted = o and o.have and o.need
        local note = counted and string.format("%s %d/%d", word, o.have, o.need) or word
        if info and info.qid then place_seen[info.qid] = true end

        card.start(S.size, layer)
        card.head()
        local iconed = add_icon(OBJECT_ICON[word] or "use")
        if not iconed then card.text(word, col.quest) end
        if detail == DETAIL_ICON and iconed then return note, name end
        if S.name or not iconed then card.text((iconed and "" or " ") .. name, col.quest) end
        if detail == DETAIL_FULL then
            local any = false
            card.pill()
            if counted then
                card.text(string.format("%d/%d", o.have, o.need), col.text)
                any = true
            end
            if info and info.title and S.quest_tag then
                card.text((any and SEP or "") .. info.title, col.quest_dim)
                any = true
            end
            if S.distance then card.text((any and SEP or "") .. string.format("%.0fy", m.d), col.dim) end
        end
        return note, name
    end

    -- What the card is told each frame: the soft look or the flat (1.88.0).
    local card_look = { soft = true }

    --- Draws every mark for this frame and rebuilds the threat list.
    ---@param visuals boolean Whether the ESP is shown.
    ---@param master number Master range, in yards.
    ---@param quest_visuals? boolean With the ESP off: whether the quest marks
    ---  and areas still are (the Quests page's own switch, 1.73.0).
    function M.render(visuals, master, quest_visuals)
        local player = units.player()
        if not player then
            mark_n, threat_n, quest_n = 0, 0, 0
            auto_corpses, auto_nodes = {}, {}
            return
        end
        master = master or 100
        read_settings(master, visuals)
        local player_guid = units.guid(player)
        local t = now()
        refresh_group()
        if S.quests then pcall(quests.refresh) end
        for k in pairs(place_seen) do place_seen[k] = nil end
        collect(player, player_guid, master, t)
        collect_quest_entities(player, t)
        if not (visuals or (quest_visuals and S.quests)) or not card then return end

        local ok_ms, now_ms = pcall(function() return core.game_time() end)
        now_ms = ok_ms and now_ms or nil
        local size = S.size
        local enemies = ctx.enemies
        local L = ctx.LAYER or {}
        local layer = L.OVERLAY or 300
        local layer_units = L.UNITS or 200
        local layer_world = L.WORLD or 100
        local my_level = level_of_player(player)
        frame_now = t

        card_look.soft = S.shader_look
        card.begin_frame(card_look)
        RING.last, RING.n = RING.n, 0
        beacon_n = 0
        stats.drawn, stats.offscreen, stats.crowded = 0, 0, 0
        stats.nodes, stats.loot, stats.tapped = 0, 0, 0
        local tracing = (t - trace_at) >= TRACE_EVERY
        if tracing then trace_at = t end
        local traced = 0

        for i = 1, mark_n do
            local m = marks[i]
            local obj, guid, row = m.obj, m.guid, m.row
            local detail = S.detail[m.cat] or DETAIL_FULL
            local e = (not m.dead and m.kind == "unit") and enemies and enemies.get and enemies.get(guid) or nil
            local f, name, source, color, note = NO_FACTS, nil, nil, nil, nil

            -- The card is built whether or not the mark is on screen: building
            -- it is what tells the quest areas a live target is marked.
            if m.kind == "object" then
                note, name = card_object(m, object_name(obj, guid, t) or "", detail, layer)
                source = "object"
            elseif m.kind == "node" then
                stats.nodes = stats.nodes + 1
                local raw = object_name(obj, guid, t) or ""
                name, source = raw ~= "" and raw or "?", "node"
                color = category_color(m.cat)
                if m.requires then
                    color = dimmed(color) or col.dim
                    note = "requires " .. tostring(m.requires)
                end
                card_node(m, name, color, detail, layer)
            else
                f = facts_of(obj, guid, row, player, t)
                name, source = name_of(obj, guid, f, row)
                if m.dead then
                    color = category_color("corpse")
                    if m.loot then stats.loot = stats.loot + 1 end
                    card_corpse(m, f, name, detail, layer)
                else
                    if m.tapped then
                        stats.tapped = stats.tapped + 1
                        if m.tap_client then stats.tap_read = stats.tap_read + 1 end
                    end
                    m.hp = units.health_fraction(obj) or 0
                    color = unit_color(m, f, row, my_level)
                    note = card_unit(m, f, name, source, e, now_ms, my_level, color, detail, layer)
                end
            end

            if color and m.kind ~= "object" then draw_world(m, f, e, color, player, layer_world, layer_units, now_ms) end
            draw_beacon(m, color, layer_world)

            local feet = draw.unit_w2s(obj)
            local how
            if not feet then
                stats.offscreen = stats.offscreen + 1
                how = "offscreen"
            else
                local drawn, crowded = card.place(feet.x, feet.y)
                if drawn then
                    stats.drawn = stats.drawn + 1
                    if crowded then stats.crowded = stats.crowded + 1 end
                    how = string.format("drawn@%.0f,%.0f", feet.x, feet.y)
                else
                    how = "nothing to say"
                end
            end

            if tracing and traced < TRACE_MARKS then
                traced = traced + 1
                ctx.emit("jcore.recorder.trace", string.format(
                    "fesp %s %-20s (%s) %s d=%5.1f lvl=%d hp=%s dead=%s enemy=%s hostile=%s on_me=%s cast=%s quest=%s loot=%s tapped=%s rank=%d/%s tap_read=%s | %s",
                    tostring(guid):sub(-10), tostring(name), tostring(source), tostring(m.cat), m.d, f.level or 0,
                    m.hp and string.format("%.0f%%", m.hp * 100) or "-",
                    tostring(m.dead), tostring(row.is_enemy == true), tostring(f.hostile),
                    tostring(e ~= nil and e.targeting_me == true),
                    tostring(e and type(e.casting) == "table" and e.casting.spell_id or "-"),
                    tostring(note or "-"), tostring(m.loot), tostring(m.tapped), f.rank or 0, f.rank_src or "-",
                    tostring(m.tap_client == true), how or "-"))
            end
        end

        do
            local ok, err = pcall(draw_places, player, size, layer, layer_world)
            if not ok and log and type(log.once) == "function" then
                log.once("warn", "forever_places", "quest areas: " .. tostring(err))
            end
        end

        if tracing then
            stats.learned = learned_count()
            ctx.emit("jcore.recorder.trace", string.format(
                "fesp frame units=%d marks=%d drawn=%d offscreen=%d crowded=%d threats=%d learned=%d nodes=%d loot=%d tapped=%d (read %d) creatures=%d places=%d",
                stats.units, mark_n, stats.drawn, stats.offscreen, stats.crowded, threat_n, stats.learned,
                stats.nodes, stats.loot, stats.tapped, stats.tap_read, creature_count(), stats.places or 0))
        end
    end

    -- --- where it is from you ---------------------------------------------------

    local ARROWS = { "^", "<^", "<", "<v", "v", "v>", ">", "^>" }

    --- The player's facing from get_direction, which answered on Forever;
    --- get_rotation never did there. nil when neither answers.
    local function facing_of(player)
        local d = ask(player, "get_direction")
        if type(d) == "table" and type(d.x) == "number" and type(d.y) == "number"
            and (d.x ~= 0 or d.y ~= 0) then
            return atan2(d.y, d.x)
        end
        local r = tonumber(ask(player, "get_rotation"))
        return r
    end

    --- Radians to turn (counter-clockwise positive) to face `pos`.
    local function relative_bearing(player, pos)
        local me = units.position(player)
        local facing = facing_of(player)
        if not me or not facing or not pos then return nil end
        local angle = atan2(pos.y - me.y, pos.x - me.x)
        local rel = (angle - facing + math.pi) % (2 * math.pi) - math.pi
        if rel ~= rel then return nil end
        return rel
    end

    local function arrow_text(rel)
        if not rel then return "" end
        local octant = math.floor((rel + math.pi / 8) / (math.pi / 4)) % 8
        return ARROWS[octant + 1] or ""
    end

    local function threat_color(th, f)
        if th.row.is_player then return col.player end
        return f.hostile and col.hostile or col.neutral
    end

    -- --- the threat panel ---------------------------------------------------------

    function M.draw_threat_panel()
        if not P.opt("alerts_on", true) or not P.opt("alert_panel", true) then return end
        if threat_n == 0 then return end
        local player = units.player()
        if not player then return end

        local size = P.opt("text_size", 13)
        local line_h = size + 6
        local width = 255
        local shown = math.min(threat_n, PANEL_ROWS)
        local height = line_h * (shown + 1) + 8
        local _, screen_h = draw.screen_size()
        local x = 24
        local y = (screen_h or 1080) * 0.5 - height * 0.5
        local hud = (ctx.LAYER and ctx.LAYER.HUD) or 500

        local content_y = draw.panel({ x = x, y = y }, width, height, {
            layer = hud, title = string.format("THREATS  (%d)", threat_n),
            title_color = col.panel, size = size,
        })
        local t = now()
        for i = 1, shown do
            local th = threats[i]
            local f = facts_of(th.obj, th.guid, th.row, player, t)
            local name = name_of(th.obj, th.guid, f, th.row)
            local pos = th.row.pos or units.position(th.obj)
            local row_y = content_y + line_h * (i - 1)
            draw.text_2d({ x = x + 10, y = row_y },
                string.format("%-2s %-15s %2d %3.0fy", arrow_text(relative_bearing(player, pos)),
                    name:sub(1, 15), f.level, th.d),
                threat_color(th, f), { layer = hud, size = size })
            if th.on_me then
                local tag_w = text_width("you", size)
                draw.text_2d({ x = x + width - 10 - tag_w, y = row_y }, "you", col.on_you,
                    { layer = hud, size = size })
            end
        end
    end

    -- --- arrows for threats off screen --------------------------------------------

    function M.draw_threat_arrows()
        if not P.opt("alerts_on", true) or not P.opt("alert_arrows", false) then return end
        if threat_n == 0 then return end
        local player = units.player()
        if not player or not draw.arrow_2d then return end
        local w, h = draw.screen_size()
        if not w or not h or w <= 0 or h <= 0 then return end
        local cx, cy = w * 0.5, h * 0.5
        local radius = math.min(w, h) * 0.42
        local hud = (ctx.LAYER and ctx.LAYER.HUD) or 500
        local t = now()
        for i = 1, threat_n do
            local th = threats[i]
            if not draw.unit_w2s(th.obj) then
                local pos = th.row.pos or units.position(th.obj)
                local rel = relative_bearing(player, pos)
                if rel then
                    -- Screen angle from straight up, clockwise: the world
                    -- bearing is counter-clockwise from the facing.
                    local a = -rel
                    local at = { x = cx + math.sin(a) * radius, y = cy - math.cos(a) * radius }
                    local f = facts_of(th.obj, th.guid, th.row, player, t)
                    local c = threat_color(th, f)
                    draw.arrow_2d(at, a, 12, c, { layer = hud })
                    draw.text_2d({ x = at.x, y = at.y + 10 }, string.format("%.0fy", th.d), c,
                        { size = 12, centered = true, shadow = true, layer = hud })
                end
            end
        end
    end

    -- --- alerts --------------------------------------------------------------

    local alerted_at = {}

    function M.alert_check()
        if not P.opt("alerts_on", true) then return end
        local player = units.player()
        if not player then return end
        local t = now()
        local cooldown = P.opt("alert_cooldown", 15)
        local my_level = level_of_player(player)
        local delta = P.opt("alert_level_delta", 2)
        -- IN A DUNGEON EVERY MOB IS AN ELITE (1.74.0): the rank alone is no
        -- alert there. The live log (a five-man) warned, with a sound, of
        -- every Dark Iron Looter in the place every fifteen seconds. A boss, a
        -- rare elite and a mob above your level still are.
        local instanced = false
        local tg = P.targeting
        if tg and type(tg.context) == "function" then
            local ok, here = pcall(tg.context)
            instanced = ok and here ~= nil and (here == tg.DUNGEON or here == tg.RAID)
        end

        for i = 1, threat_n do
            local th = threats[i]
            local f = facts_of(th.obj, th.guid, th.row, player, t)
            local should, reason
            if th.row.is_player and P.opt("alert_players", true) then
                should, reason = true, "Hostile player"
            elseif not th.row.is_player and P.opt("alert_elites", true) then
                local r = RANK[f.rank or 0]
                if r and r.danger and not (instanced and r.cat == "elite") then
                    should, reason = true, r.alert
                elseif f.level >= my_level + delta then
                    should, reason = true, "Dangerous mob"
                end
            end
            if should and (not alerted_at[th.guid] or (t - alerted_at[th.guid]) > cooldown) then
                alerted_at[th.guid] = t
                local name = name_of(th.obj, th.guid, f, th.row)
                if log and log.fmt then
                    log.fmt("warn", "%s: %s (%d) at %.0f yards", reason, name, f.level, th.d)
                end
                if P.opt("alert_sound", true) then pcall(core.play_sound_by_id, 8959) end
                if P.opt("alert_toast", false) and draw.notify then
                    draw.notify("jambix.aio.threat." .. tostring(th.guid), reason,
                        string.format("%s (%d) -- %.0f yards", name, f.level, th.d), 4, col.hot, cooldown)
                end
                ctx.emit("jambix.aio.threat", {
                    guid = th.guid, name = name, level = f.level,
                    category = th.row.is_player and "hostile_player" or "dangerous", distance = th.d, reason = reason,
                })
            end
        end
        for guid, at in pairs(alerted_at) do
            if (t - at) > (cooldown * 4) then alerted_at[guid] = nil end
        end
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        return {
            units = stats.units, marks = mark_n, drawn = stats.drawn, threats = threat_n,
            offscreen = stats.offscreen, crowded = stats.crowded, learned = learned_count(),
            nodes = stats.nodes, loot = stats.loot, tapped = stats.tapped, tap_read = stats.tap_read,
            creatures = creature_count(),
            places = stats.places or 0,
            beacons = beacon_n, gather_hidden = stats.gather_hidden or 0,
            quests = quests and quests.stats() or nil,
        }
    end

    --- The name a unit would be marked with, and where it came from.
    function M.name_for(obj)
        local guid = units.guid(obj)
        local row = units.snapshot(obj)
        local player = units.player()
        if not guid or not row or not player then return nil end
        local f = facts_of(obj, guid, row, player, now())
        return name_of(obj, guid, f, row)
    end

    --- This frame's corpses and nodes for the automation (world.lua), in the
    --- classic collector's shape: { obj, guid, distance, skinnable } and
    --- { obj, guid, kind, name, distance }. Read-only, valid this frame.
    function M.corpses() return auto_corpses end
    function M.nodes() return auto_nodes end

    --- This frame's node marks -- herbs, veins, chests and other objects --
    --- for the beacons (1.87.0): { obj, guid, cat, d, pos, name, requires }.
    --- The automation's M.nodes() holds only what is within its reach; these
    --- are the marks the ESP drew, out to each category's range. Since 1.88.0
    --- a herb or vein your skill cannot gather says the skill it asks for
    --- (`requires`, else nil), and one you lack the profession for is not a
    --- mark, so not here. A new list per call.
    function M.node_marks()
        local out = {}
        for i = 1, mark_n do
            local m = marks[i]
            if m.kind == "node" then
                out[#out + 1] = { obj = m.obj, guid = m.guid, cat = m.cat, d = m.d, pos = m.row and m.row.pos,
                    name = m.name, requires = m.requires }
            end
        end
        return out
    end

    --- This frame's quest targets, for modules/quests.lua's paths, in the
    --- classic collector's shape (read-only, valid this frame; 1.55.4).
    function M.entities() return quest_entities end
    function M.count() return quest_n end

    --- This frame's threats, most urgent first (read-only).
    function M.threats()
        local out = {}
        for i = 1, threat_n do out[i] = threats[i] end
        return out
    end

    return M
end

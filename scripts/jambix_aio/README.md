# Jambix AIO

All-class levelling and endgame rotations, pet control, world overlay and
gathering automation, built on JCore. **The ESP runs on every client** --
Classic Era, Hardcore, Season of Discovery, TBC, Wrath, Mists and Retail. The
rotations and the automation run on the Vanilla client (Era, Hardcore and
Season of Discovery) and on Forever; see [Clients](#clients).

**Requires:** JCore 1.8.0 or newer (the reaction framework, `ctx.react`),
loaded from `scripts/jcore/`. 1.7.8 ships with JCore 1.8.1.
**Optional:** Questie, RestedXP Guides, Sentinel Navigation (for following the
guide, 1.7.4). Each feature disappears when its addon is absent; none is
required for anything else to work.

**Version numbers.** 1.7.4 follows local 1.89.0: from there the AIO's version
follows project-sylvanas.net's numbering for it (plugin 1129, where the last
upload reads 1.7.3). Sections tagged 1.89.0 and below keep their local numbers.
1.8.0 (2026-10-11) puts the reactions apart from the rotation, on JCore's
reaction framework; see *Reactions*. **1.8.0 and 1.8.1 were working labels,
never uploaded: that work is released as 1.7.8** (2026-10-12). Where this README or the code's comments tag
something 1.8.0 or 1.8.1 about the AIO, it is in 1.7.8; JCore's own 1.8.0
and 1.8.1 are JCore's versions and stand.

---

## Clients

| Client | `get_game_version` | What runs |
|---|---|---|
| Classic Era, Hardcore, Season of Discovery | Vanilla | everything |
| Forever | Forever | everything |
| TBC (Anniversary or Classic) | Tbc | the ESP only |
| Wrath | Titan | the ESP only |
| Mists | Mop | the ESP only |
| Retail | Midnight | the ESP only |

**ESP only** means the overlay and nothing that acts: every mark, quest path,
panel, threat arrow, alert and narration works, and nothing presses a key.
The rotations, the pet, the reactions, the spell window, looting, resting,
gathering, fishing and the hardcore survival automation are built against the
Vanilla client's spells, talents and items, and pressing those on another
client is worse than not pressing anything. Three locks hold it, because
acting paths do not all go one way:

- the rotation's gate (`rotation_active`), which the pet, the reactions, the
  kiting and the weave all ride, is shut;
- every other acting feature's master switch reads OFF, whatever the menu
  says (`ESP_ONLY_OFF` in main.lua's `opt`);
- the plugin's own cast and input leases are refused outright.

Each of those pages opens with a "Not on <client>" notice saying so, and the
Overview page and the log say it once at load. Season of Discovery runs the
Era client and cannot be told apart from it, so it gets everything; its
runes are not in the rotations.

**What the overlay knows on the later clients.** Quest marks come from the
game's quest log, which works on Retail, TBC, Wrath and Mists (Questie is a
classic addon; RestedXP runs everywhere). Herbs are recognised by name, and
the later expansions' herbs are matched inside a node's name, because their
nodes come in variants ("Lush Hochenblume", "Irradiated Mycobloom"); ore by
its "Vein", "Deposit" or "Seam", and The War Within's by name. Every allied
race has a faction for the emblem. Players' fighting styles come from their
real specialisation where the client has one.

**Two ESPs, kept apart (1.47.0).** The **Classic ESP** (`modules/esp/`:
collect, classify, elements, panels, roles) runs on every client but Forever.
The **Classic Forever ESP** (`esp/forever.lua`, `forever_quests.lua`,
`forever_icons.lua`) runs on Forever only; `esp/init.lua` picks one at load
from the client's own version name, and the other is never drawn. Both use
`esp/fight.lua`, the melee / ranged / caster learner, each with its own file.
What each keeps to itself:

| | Classic ESP | Classic Forever ESP |
|---|---|---|
| Code | `modules/esp/*`, no Forever branch in it (bar fight.lua's file name) | `esp/forever*.lua`, loaded on Forever only |
| Menu page | **ESP**, with the values saved there as always | **Forever ESP**, with values of its own |
| First section of the page | *Classic ESP* | *Classic Forever ESP* |
| Melee / ranged / caster learned | `scripts_data/jcore/jambix.aio.fight.json` | `jambix.aio.forever_fight.json` |
| Names and quest marks | Questie, RestedXP, the quest log | the `forever_names` and `forever_quests` stores |

The menu saves a widget under its page's path, so the two pages share widget
ids but not values: a switch moved on Forever no longer moves the Classic one,
and the other way round. Forever's page starts from the defaults. Before
1.47.0 both ESPs read the one ESP page and wrote the one fight file. On its
first load Forever takes the creatures only it has (npc ids 250000 and up)
from that file into its own, and only reads it: the Classic file is left as it
was. Still shared: the Overview's master switch and *Enable quest ESP* on the
Quests page. Tests: `aio_esp_split_era_test`, `aio_esp_split_forever_test`.

**Tested headless on each.** `aio_boot_retail_test`, `aio_boot_tbc_test` and
`aio_boot_era_test` boot the whole plugin, on top of the whole JCore runtime,
as that client -- the first time `main.lua` itself has run outside the game
-- and check that it loads clean, that nothing acts on the ESP-only clients
even with every switch turned on, that the ESP answers to its own settings,
that each page carries its notice, and that a second of frames runs clean. On
an install with several clients, each must be handed its own folder.

## Settings

The sidebar node **Jambix AIO** is an overview page. Every feature area is a
peer page beneath it:

```
Jambix AIO          master switch + live status for every subsystem
  ESP               overlay: elements, categories, proximity alerts
  Rotation          class rotations, targeting, pet, healing, cooldowns
  Hardcore          survival guardrails, emergency items, warnings
  Automation        safety checks, auto-loot, gathering
  Fishing           cast, click on a bite, loot by filter, session counts
  Quests            Questie and RestedXP
  World marks       the look of every mark on the ground, its budget, the test pattern (1.89.0)
  Debug             inspector, dump, status readout
```

### Overview

One switch — **Enable everything** — and a live line per subsystem showing what
is actually running. Turning it off stops the overlay, the rotation and all
automation at once.

### ESP

| Section | What it holds |
|---|---|
| General | Enable ESP, toggle keybind (default Z), master range, text size |
| Elements | One toggle per mark — box, raid marker, class and role icon, name, health bar, mana bar, cast bar, the cast ring on the ground (1.85.0), status line, threat percent and rank, quest tag, ring under anything on you, lines from attackers, tracers, node names, node rings — then where the information rows go (under the feet by default), keeping marks from overlapping, sitting on top of nameplates, the tag chips, what the label says (name, level, health, mana, reaction, distance), the box style, the colour mode, class colours, tapped grey, distance fade, and the icon's size and role badge |
| Categories | Per-category enable, range and colour — 14 of them |
| Hardcore alerts | Proximity warnings, threat panel, off-screen arrows, sound, notifications, re-alert cooldown |
| Telegraphs | Show telegraphs, whose spells (every hostile cast / elites, bosses and boss-mod spells / boss-mod spells only), where (everywhere / raids and dungeons only), hostile players' spells, range, labels, alerts at the top of the screen, the countdown wall rising round a circle's edge (1.85.0), fill strength (0-50%, default 15%); with advanced settings: missiles, ground that stays |
| Performance | Detail falloff, mark cap, draw budget, detail-read budget, line-of-sight budget, live counters |
| Aurora around you | The aurora around your character (1.86.0, both ESPs): on/off, colours, a glowing sheet (1.87.0), only in a fight, size, height, speed, detail. See below |
| Fight timers | Your damage and healing over time spells as rings under your target, red with 3 s left and a pulse when one runs out; a curtain on the mob the reactions' plan says to kill next (1.87.0) |
| Group and healing | A ring under each hurt party member filling red, a curtain on the one who most needs a heal (*Heal at*, 50%), an orange curtain on a mob loose on someone not the tank (1.87.0) |

**On Forever the page is the icon card's (1.69.0).** Same page ("Forever ESP")
and the same widget ids, so nothing saved is lost; only where each sits changed.

| Section | Shown | What it holds |
|---|---|---|
| ESP | always | Enable ESP, toggle key, **Style** (Minimal / Clean / Detailed / Custom), range, text size |
| In a fight | always | Cast bars, the cast ring on the ground (1.85.0), the ring under anything on you or yours, the line from anything coming at you, threat panel, telegraphs, alerts, alert sound |
| Enemies / World / Friends | always | One switch per category: the grid of what to show. No quest row since 1.73.0: quest marks are the Quests page's |
| What a mark shows | advanced | Every piece of a mark (cfg.ESP_PIECES). The Style sets them all; change one and the Style reads Custom |
| Look | advanced | Colour names by (reaction / difficulty / category), grey tapped, game-texture bars, bars at full health, exact health, bar size, box style, boxes out to, the mark limit |
| Each category | advanced | Automatic ranges; per category what its mark shows (Everything / Icon, name, health and casts / Icon only), its range, its colour |
| Alerts, Telegraphs | advanced | The fine tuning |
| Aurora around you | always | As on the Classic ESP's page (1.86.0) |
| Fight timers, Group and healing | always | As on the Classic ESP's page (1.87.0) |

**The aurora around you (1.86.0).** Lemons' Aurora Systems plugin draws a
rippling curtain of lines round your character. This is that curtain, drawn
with JCore 1.11's `curtain_3d` (180 lines a frame at the default detail;
Aurora Systems draws 1,020 and reads its settings 9,400 times a frame), and
it reads the fight:

- Out of combat it stands low and drifts; in a fight it rises and quickens, eased over about half a second.
- Under half health it warms toward amber; under a quarter it burns red and breathes, faster the lower you are.
- Each enemy on you, up to three, adds a fold to its wave.

**Colours:** *Reacts to the fight* (your class colour rising into violet, warmed by your health), *Class colour*, *Aurora* (Aurora Systems' turquoise to purple) or *Rainbow*. Its glow ring and the ring at your feet for your cast went in 1.88.0 (the user: not necessary), and with them the style choice. *Only in a fight* fades it out with the fight. It follows the master switch and the toggle key, not the ESP's own switch. Lemons' plugin is not needed; with both on there are two curtains. Needs JCore 1.11.

Categories: hostile players, friendly players, party members, pets and minions,
friendly NPCs, bosses, rares, elites, normal NPCs, critters, lootable/skinnable
corpses, herbs, ore veins, chests and containers, quest targets, guide targets,
other objects.

**The new look (1.88.0, both ESPs).** The rings under anything on you, under
nodes and on quest areas are JCore's smooth shader rings; the box style
defaults to *Curtain*, a short curtain round the unit in its colour (boxes are
still off until *Boxes* is on); a rare, a boss, a quest target or a corpse with
loot further than 40 yd off gets a pillar of light; and with *Soft cards and
bars* on, each pill is a soft-edged plate and each bar a gradient on a rounded
rail (JCore 1.15's plate and bar; until then, and with it off, the flat ones).
Herbs and veins follow your skill (*Only herbs and ore I can gather*, on): not
marked without the profession, dimmed with "(Requires Skill N)" when your skill
is short of Classic's requirement, and the gatherer passes both by.

**Party members, pets and friendly NPCs ship off.** They are what crowds a town
or a group, and none of them is about to hit you. Each has its own switch under
Categories. A friendly NPC is anything you cannot attack: guards, vendors,
trainers, flight masters. A quest giver or a guide's npc is still marked,
because quest and guide outrank all three.

**Critters ship off too, and stay off (1.47.1).** Only their own switch under
Categories turns them on: *Show every category but critters* leaves them
alone. A value saved on before 1.47.1 (that button used to switch them on) is
switched off once, a second after load, on each ESP page; after that the
switch is yours. The note that it was done is in
`scripts_data/jcore/jambix.aio.migrations.json`. The Forever ESP follows the
same switch: it used to mark critters as neutral mobs.

Each has its own range because a single global range cannot express "rares at
150 yards but normal mobs at 40".

**Ranges are automatic.** With *Set each category's range automatically* on —
which it is by default — everything switched on is drawn out to the one **Range**
slider, and the per-category yard settings are ignored and hidden. Turn it off
to get them back, for "rares at 150 but boars at 40".

What keeps that from becoming noise in a crowd is the **mark limit** rather
than a range: 60 things, and what it keeps is what matters. Bosses, rares,
quest and guide targets outrank hostile players, which outrank elites, which
outrank normal mobs and critters; within a rank, nearest wins. That same order
is what the draw budget and the detail reads are spent in, so when something
has to give, it gives on the boar and not on the rare.

**Still nothing marked?** Switch on **Explain what is NOT being marked** under
Performance. The live line then names the nearest thing the overlay skipped and
the setting that skipped it, and says outright when the toggle key is simply
holding the overlay hidden.

**What a mark looks like.** Two small blocks: what the thing *is*, above its
head, and what it is *doing*, under its feet.

```
          (skull)                    the raid icon, when it has one
           ( W )                     the portrait: class, or creature type
   [!] PICK UP  Razormane Thornweaver   why it is marked, then the name
   ===================               a health bar, green to red, only when hurt
   ===================               a mana bar, blue, for anything with mana

        ~ the model ~

  [*] ( Lightning Bolt  1.4 )        a cast bar, only while casting: white when it
      ======-----------                can be interrupted, red when it cannot
    ( LoS ) ( Out of Range )         the selected target only: line of sight, and
                                       whether it is inside this class's reach
          ( on you )                 what it is doing to whom, when that says something
    ( threat 72% · #2 of 5 )         your threat on it and your rank, in a group fight
  ( RANGED ) ( 11 · 88y ) ( hostile )   how it fights first; then level, distance,
                                       health, mana -- and the
                                       reaction in its own colour
   ( Blood of the Quilboar 3/8 )     one row per quest that wants it
```

**Why under the feet.** A nameplate addon draws its plate exactly where the
game hangs a name, above the head, and that is where these rows used to end:
with Plater's plate up, the level, distance and line-of-sight rows were under it
and could not be read at all. Nothing of the game's sits under a unit's feet.
The name and portrait stay on top because they say what the plate says anyway.
When the feet are near the bottom of the screen the block is lifted to stay on
it. **Elements → Placement → "Cast bar, target range, status and details under
the feet"** puts everything back above the head.

**Every information row is a pill**: the text at full size, bright, on a dark
rounded backdrop, outlined in its own colour where the colour is the answer (a
red `on you`, a green `LoS` next to an amber `Out of Range`). Small dim text
over bare ground was unreadable over Durotar's red sand; a backdrop reads the
same over sand, snow and lava. The name above the head keeps its shadow and no
backdrop, and its anchor is the model's own name attachment, so a mark sits
above a kodo and above a rabbit without either being wrong.

**Why it is marked: tags.** A chip in front of the name, in capitals on its own
dark pill, outlined in its family's colour, with the icon the matching addon
itself uses beside it:

| Chip | Colour | Means | Icon |
|---|---|---|---|
| `PICK UP` | quest yellow | the guide wants you to take a quest from it -- an npc, or a thing in the world (a wanted poster, a book) | Questie's `!` |
| `TURN IN` | quest yellow | a finished quest goes back to it -- an npc, or a thing in the world | Questie's `?` |
| `KILL` | quest yellow | it is itself a quest objective | Questie's sword |
| `COLLECT` | quest yellow | it drops (or holds) a quest item | Questie's bag |
| `USE` | quest yellow | an object a quest wants used | Questie's cog |
| `QUEST` | quest yellow | Questie lists it, without saying for what | a note |
| `GUIDE` | blue | RestedXP's current step wants it; the step's own text is the first row under its feet | RestedXP's logo |
| `LOOT` | green | a corpse with loot on it | gold coins |
| `SKIN` | brown | a corpse your Skinning can skin (1.67.0: weighed against its level; a corpse too high for you, with no loot, is not marked at all) | a pelt |

These used to be the words "quest", "guide", "loot" and "skin" glued to the
front of the name in the name's colour, where "quest Kawahmwhaz" read as a
player's name. Four families, four hues. A mark serving two quests shows the
most pressing thing to do there (turn in, then pick up, then kill...). A corpse
that is both gets both chips. Every icon was checked on this install: Questie's
five, RestedXP's logo, and the three game icons out of the 1.15.9 archives.

**Things in the world you click for a quest (1.47.5).** Objects get the same
chips as npcs, with the quest's own line under them: `USE` on what an
objective wants clicked, `COLLECT` on what holds a quest item, `TURN IN` on
the object a finished quest is handed in at (a journal, a grave, a chest),
and `PICK UP` on one the guide's next quest starts from. Turn-in and pick-up
objects are new: Questie lists a quest's start and end as npcs first and
objects second, and only the npcs used to be read. An object is found by its
id, and failing that by the name Questie has for it, because the client is
not proven to answer an object's own id. Objects and npcs are kept apart:
an npc whose id happens to equal a quest object's is no longer marked `USE`,
nor the other way round.

**Never on a player or a pet.** Quest and guide matching both work by name,
and used to match any name hiding inside a longer one. A player called
"Kawahmwhaz" in the Crossroads, or a pet called "Boar" against "Bristleback
Quilboar". Players and pets are no longer matched at all, and names are now
compared as whole words, in the singular, so "Mangy Wolf" does match a guide
step reading "Kill 8 Mangy Wolves", which a plain substring test never did. The
guide used to compare a goal's `ids`, which the contract says are QUEST ids,
against every unit's NPC id, so an npc whose id equalled a quest id in the
step was marked "guide". It no longer compares ids.

**When a nameplate covers the mark.** A nameplate addon draws its plate where
the game hangs a name, and its auras above the plate's bar. That is exactly
where the mark hangs. Seen on 2026-09-30: Plater's debuff timers over the
portrait and raid icon, and the mark's name behind the plate's bar. So while a
unit's plate is up, its whole mark moves under its feet: raid icon, portrait,
tag chips, then the information rows. Nothing of the game's sits there. The
name and health bar are left to the plate, which already shows them; the mana
bar comes along, because a plate does not show it. When the plate goes (out of
nameplate range), the mark goes back above the head.

A plate counts as up when either of two independent answers says so: the
client's `get_nameplate`, or the unit wearing a `nameplateN` unit token
(five tokens checked a frame, round robin). **Elements → "When a nameplate
covers the mark"** can instead set it on top of the plate's bar, using the
rectangle the client reports, with a clearance slider for a plate whose auras
sit higher. That option falls back to under the feet when the rectangle cannot
be read. Or the mark can be left above the head. The ESP page's live lines
count what each route sees, and the first raw rectangle the client gives is
written to the log once.

**On Forever, its own ESP (1.42.0, 1.43.0).** The ESP above is switched off
on the Forever client (1.41.0). On Forever it draws nothing and walks nothing,
and the lists it publishes stay empty, so quest tags, auto-loot and gathering
have nothing to act on there. `modules/esp/forever.lua` is the overlay there
instead. It is built only on reads JCore's API recorder saw answering on
Forever; every other client never loads it. Every piece below has a switch of
the same name as its classic counterpart, on the **Forever ESP** page, which
keeps its own values (1.47.0; see *Two ESPs, kept apart* under Clients).

- **What it marks:** hostile mobs (red), neutral mobs (yellow), hostile players
  (red, named by class), corpses (`LOOT`, and `SKIN` when your Skinning
  reaches it: 1.67.0), and gathering nodes.
  Friendly players, party members, pets and minions, friendly NPCs, critters
  (creature type 8, since 1.47.1) and other objects follow their category
  switches (off by default).
- **The page's categories apply (1.48.0).** Each mark falls in one of the
  Categories rows, and that row's switch, range (when automatic ranges are
  off) and, for nodes, colour decide it, as on the Classic ESP. Bosses, rares
  and elites are their own rows since 1.52.0, by the client's creature cache,
  and rares by a list of every known one too since 1.7.5 (see *Names, ranks
  and other people's mobs on Forever*). Guide
  targets need RestedXP, which Forever does not have. The Name, Details,
  creature icon, class icon, node name and node ring switches under Elements
  work too, and so does the mark limit under Performance. Marks are laid out
  in the Classic ESP's order: your target first, then by category, then
  nearest first in three-yard bands, so two mobs at nearly the same distance
  do not trade places every frame.
- **Gathering nodes (1.48.0).** The recorder showed that `get_name` answers
  for game objects on Forever ("Copper Vein", "Peacebloom", "Silverleaf"), so
  the Classic ESP's name rules sort them into Herbs, Ore veins and Chests and
  containers. Each shows its name in the category's colour, its distance, a
  ground ring and the game's own icon. "Other objects" (off by default) are the
  ones named under extra object names, or that the client says can be used.
  `can_be_used` answered true on every herb and vein recorded and false on
  scenery such as "Ley Line"; `has_loot` is always false there. A "(Quest)"
  object keeps its USE mark.
- **LOOT is inferred (1.48.0).** No read tells a lootable corpse from a looted
  one on Forever: `has_loot`, `can_be_looted` and the npc and state flags
  answered the same before and after 35 recorded loot windows. So a corpse
  says `LOOT` when it fought you, your pet or your group (or you cast at it),
  and nobody outside your group had it. The `LOOT` goes when a loot window
  opens within six yards of it (`LOOT_OPENED`, not one from a bag item). A
  kill that dropped nothing keeps its `LOOT` until it despawns, because
  there is no window to clear it.
- **Tapped mobs are inferred too (1.48.0).** `is_tap_denied` is always false
  on Forever. A mob in combat with a player, or a player's pet, outside your
  group, with none of your threat, is somebody else's tag. It is greyed when
  "Grey out mobs someone else has tagged" is on, says `tapped` in its status,
  and gets no `LOOT` when it dies. The tag goes when it leaves combat. Since
  client patch 1.60.1.70205 `is_tap_denied` answers true for somebody else's
  mob, and 1.52.0 believes it when it does.
- **Under the feet:**
  - the name, then a health bar;
  - `MELEE / RANGED / CASTER` with `level · health · distance` (health as
    numbers when that is switched on). The level is in its target frame's
    colour, grey to red, on anything you can attack (1.67.0). A corpse has
    no level;
  - one status: crowd control with its time left, `on you`, `on your pet`,
    `on your group`, `tapped`, or `in combat`;
  - your threat on it in a fight (`threat 72% · #2 of 3`, or `aggro`);
  - a cast with its time left and a progress bar, outlined purple when it can
    be interrupted. A channel whose spell id reads as nonsense on Forever
    (3739147998 was seen) is not drawn.
- **In the world:** the box (`box_style`, within full-detail range), a ring
  under anything on you (red) or on your pet or group (amber, thinner), see-through
  and fainter the more of them there are (1.66.3), and a line from
  it to you while it is still more than six yards away.
- **On screen:** the threat panel, alerts and off-screen arrows. They list what
  is on you, hostile players within the alert range, and any mob
  `alert_level_delta` levels above you that is coming at you. An elite, rare
  elite or boss the client's creature cache knows is one too, whatever its
  level (1.52.0) -- except inside a dungeon or raid (1.74.0), where every mob is
  an elite and the rank alone rang the alert for each one; bosses, rare elites and
  mobs above your level still do. The level rule covers the creatures it does not know yet. Your facing comes from
  `get_direction`; `get_rotation` was never seen answering there.
- **Why under the feet:** Forever's nameplates draw above the head and paint
  over the overlay.
- **In a crowd:** a mark that finds its spot taken moves down. When there is
  no room it prints where it stands rather than vanish.
- **Names:** `get_name` is "" for every unit on Forever. A name is learned
  from `UNIT_SPELLCAST_SENT`, which carries the name of what you cast at (your
  target), and is kept by NPC id in the `forever_names` store, so naming one
  wolf names every wolf of that kind, across sessions. Failing that, the
  client's own creature cache names it (1.52.0), and a town npc gets its title
  under its name. Until then a mob is shown by its creature type
  ("Elemental", "Beast"), and a player by class.
- **Trace:** twice a second the nearest marks go to the recorder trace as
  `fesp` lines (what was read, where it was drawn) and a `fesp frame` summary.
- **Quests (1.45.2), `esp/forever_quests.lua`.** Questie and RestedXP are not
  on Forever, and its classic quest log answers nothing, so the marks come
  from what the recorder showed Forever does answer. They follow "Enable quest
  ESP" and the Quest targets category.

  | Chip | On | From |
  |---|---|---|
  | `PICK UP` | a quest giver with a quest you have not taken | the giver's window (`get_gossip_available_quests`), checked against `is_on_quest` and `is_quest_flagged_completed` |
  | `TURN IN` | the giver a finished quest goes back to | the giver's active list (`get_gossip_active_quests`, `is_complete`) |
  | `QUEST` (dim) | a giver you have not talked to yet, or one holding a quest still in progress | npc flag bit 2 (quest giver) |
  | `KILL 4/6` | mobs an unfinished objective names | "Roiling Winds destroyed: 4/6" (`UI_INFO_MESSAGE`), matched to the names learned from your casts, singular or plural |
  | `USE` / `COLLECT n/m` | game objects a quest uses | the client tags them "(Quest)" by name (shown without the tag), or an item objective names them |

  A quest giver is marked whatever the Friendly NPCs category says. What it
  learns (givers, quests, objectives) is kept in the `forever_quests` store
  across sessions. A giver's marks are only as fresh as the last time you
  talked to it. A KILL chip needs the first progress message, which comes
  with the first kill, and a learned name for the mob. Only getters are
  called: nothing accepts, completes or hands in.
- **"Unknown" is not a name.** `get_name` answers "Unknown" for many quest
  givers and town NPCs on Forever. Until 1.45.2 that was learned as a name and
  could overwrite a real one; it is now ignored, and purged from the store on
  load.
- **The game's own icons:** a creature-type icon or class crest goes before the
  name, a herb, ore, chest or gear icon before a node's name (1.48.0), and a
  loot bag beside `LOOT` or the skinning pelt beside `SKIN`. Icons sit beside pills, never on
  them, because textures paint beneath every shape. The loader cannot read the
  game's archives in the game, so they are cut out of the Forever client's own
  archives OFFLINE, into `scripts_data/jcore/game_icons/forever/`:

  ```
  JTEST_LIVE=1 JTEST_ICONS=1 node tools/jtest/run.js forever_icons
  ```

  The list is `esp/forever_icons.lua`; run this again after a client patch.
  Six minutes the first time, seconds after, because the archive index is kept
  in `tools/jtest/out/forever_icons/`. The extractor writes a
  `manifest.json`, and the ESP draws only what it lists; before the extractor
  has run, the marks have no icons. Not extractable from this install
  (2026-10-02): the unknown-type and aberration icons, and the combat swords.
  They read as "no BLTE header" from `data.010`, so "in combat" has no icon.

Tests: `aio_esp_forever_test`, and the whole plugin on Forever in
`aio_boot_forever_test`.

What led there (2026-10-02, 1.40.1 to 1.40.5): on Forever, `get_nameplate` is
always nil and the `nameplateN` tokens almost never resolve, so the plate
logic above sees nothing. Two layout workarounds were tried and removed again.
The recorder's trace then showed the projection is correct there: `w2s` and the
client's own `world_to_screen` agree, and the player projects to the exact
centre of the screen. The game also never reported a nearby unit as not
visible. The user then saw the mobs' own models flicker with the ESP off, which
no overlay can cause. So the ESP was cleared from Forever rather than patched
further.

**Dead.** A dead unit's details pill reads `dead`, in grey, in place of its
reaction, whether or not the reaction words are switched on.

**The game's own art.** Beyond the portraits and raid icons, the marks carry
pictures out of the client's own UI -- and, because in the game the archives
were not readable on this machine (see below), a stand-in for each that does
load there:

| Where | Picture | From the archives | Stand-in that loads in the game |
|---|---|---|---|
| Before the name of a boss, a `??`, or anything ten levels above you | a skull | the target frame's level skull | Plater's skull and crossbones; then a skull icon |
| Before an elite's or rare elite's name | a dragon | the default nameplate's gold elite dragon | a dragon's head icon |
| Before a hostile player's name | the Horde or Alliance emblem, by race | the target frame's PvP badge | Questie's emblems; RestedXP's; the PvP banner icons |
| Before a herb, ore vein, chest or other node | herbalism, mining, a treasure chest, a bag | the professions' icons | the same icons, from the web |
| On a `PICK UP` / `TURN IN` chip | the yellow `!` and `?` | the gossip window's quest marks | Questie's |
| Beside any pill of a unit that is fighting -- `on you`, `on your pet`, `in combat` | crossed swords | the combat icon by your own portrait | the Dual Wield icon |
| Beside a crowd-control pill, and on a cast bar | that spell's own icon | | the asset registry's web icon cache |
| Health, mana and cast bars | a grey gradient, tinted | the status-bar texture every bar in the game uses | WeakAuras' clean bar; then flat |
| The raid marker | the marker | the client's raid icons | Plater's marker shapes, in the marker's colour |

One badge at most before a name, danger first: the skull outranks the dragon.
Every one of these was pulled out of the 1.15.9 archives and looked at before
its crop was written; `casc_probe_art_test` writes them out as PNGs, and the
live check asserts each is still there. Textures paint beneath every shape in
this loader, so none of them sits on a pill: a badge goes before the chips, an
icon beside its pill, and a textured bar has a textured backing rather than a
filled one. Until a picture has loaded, the mark is drawn without it, and the
bars are the flat ones. *Badge before the name* and *Bars in the game's own
texture* switch each off.

Not from the archives: the spell icon on a cast bar. A cast can be any spell,
and a file the archive reader has not been asked for before costs a re-scan
of the archive index -- fine once at load for the fixed art above, not in the
middle of a fight for every new spell. Those come from the same Blizzard icon
through the asset registry's web icon cache. (They used to go through the
shared icon helper, which drew nothing in the game; the registry had already
cached icons there.)

**In the game, the archives cannot be read -- answered 2026-10-02.** The
loader's file sandbox is the client folder (`_classic_era_`), and the
archives are in the install folder above it, so no spelling of the path
reaches them (JCore's README, *Assets and icons*, has the evidence). The
stand-ins above are therefore the permanent answer on this loader, and since
JCore 1.5.3 an archive picture fails for good at once instead of being
retried all session. The history: on
2026-10-01: `scripts_data/jcore/game`, where every file read out of them is
kept, was empty, and the reader had never written its index -- while web
icons and the installed addons' files had loaded. Every check against the
archives here ran in the offline harness, which reads the install directly,
not through the loader. So the stand-ins above are what the game shows today,
and the Debug page's "Game archives" line says why the reader fails. The
likeliest reason is the one the assumptions table below names: the loader
letting a plugin read inside the client folder but not the install root above
it, where `.build.info` and `Data/` are. Every stand-in was decoded from the
installed addons and looked at before use (`addon_art_probe_test`).
Since JCore 1.5.2 the reader tries other spellings of the root (`../`,
`./`, `<client folder>/../`). If none of them opens, it saves what the loader
will and will not open to `scripts_data/jcore/jcore.casc.json`. After one game
session, that file answers the question.

**In a crowd.** No mark prints over another (1.40.0: the stack above the
head too, not only the block under the feet). Marks are laid out most
important first: your target, then bosses, rares, quest and guide targets,
then the nearest, and the first to claim a spot keeps it.

- **Above the head**, a stack that would land on another moves up by up to
  two rows. If that is not enough it is cut to its name (and raid icon),
  which may move up four. If even the name will not fit, nothing is drawn
  above that head; its rings, lines and the rows under its feet still are.
- **Under the feet**, a block that would land on another moves down. If it
  would have to move more than three rows, it is cut to the rows that cannot
  wait, which may move up to six. If even that will not fit, it is not drawn
  this frame.
- **What cannot wait is decided by what a row says**, not by which row it
  is: a cast, line of sight, "on you" / "on your pet" / "on <party member>",
  crowd control, and threat that is close or pulling. "In combat",
  "tapped", "mounted" and "threat 0%" are dropped from a cut block -- in a
  group pull every mob not on you said one of them.
- **The most important mark paints on top.** Your target paints over every
  other mark, at any distance; among the rest, the more relevant over the
  less, the nearer band over the farther.
- **The order holds still.** Marks of the same importance are ordered by
  three-yard bands and then by identity, so two mobs walking past each other
  no longer swap places (and blocks) every frame.
- Solo, "on you" is not repeated underneath as "aggro, #1 of 1".

"Keep marks from overlapping in a crowd" turns the moving and cutting off.

**Mana.** A blue bar under the health bar for anything with a mana pool, and
"62% mana" on the details pill once some is gone. Like the health bar, it
appears when it has something to say, or always with "Health and mana bars
even when full". The read is rationed and kept a third of a second, and a mob
the classifier found no mana pool on is never asked.

**Players get a portrait.** Above a player's name, hostile or friendly, sits
the game's own class icon — the one the client paints on its frames — framed
in the class colour, with the client's own role circle on the rim: the blue
shield, the green cross, the red swords that a party portrait carries. Where
the client cannot say the role, the badge shows the talent-spec icon instead,
inside a ring coloured by role.

**Where the art comes from.** Out of the game itself. The client keeps that
art inside its data archives, and JCore reads those archives directly: the
class icon sheet, the role circles and the talent-tab icons are pulled from
the client's own files, once per client build, and kept under scripts_data.
Two fallbacks stand behind that, in order, for a machine where the archives
cannot be read: the pixel-exact copies of the class crest and spec sheets that
Details and Plater ship as plain files in the WoW folder, and the same icons
by name from the icon CDN. A portrait takes the first source that has loaded,
and the badge becomes a letter — **T**, **H**, **D** — only when none has.

```
      (  W  )T          the class portrait, badge on the rim
   Grimtusk               name, in the class colour
   60 · 31y
```

Where the role comes from, in order: the role the client reports for a member
of your own group; the specialisation, on clients that have one; and failing
both, what the player is visibly doing. Defensive Stance, Bear and Cat Form,
Moonkin, Shadowform, Righteous Fury and the death knight presences each give a
role away, and a hunter, rogue, mage or warlock has only one. A hybrid in no
telling form — a paladin, shaman, priest or caster-form druid — gets the role
its class usually plays in a group, and the badge is drawn **dimmer** so a
guess never looks like a fact.

The spec icon follows the same evidence. The tree clients have no spec ids, so
the icon is the spec the class plays that role as — a Defensive Stance warrior
shows Protection, a Berserker Stance one Fury, a Moonkin shows Balance, a cat
Feral, a levelling mage Frost, a levelling warlock Affliction — and on a client
that does report spec ids, the client's own answer is used as it stands.

**Creatures get one too.** An NPC's portrait is its creature type — the wolf
for a beast, the human head for a humanoid, the skull for undead, and so on
through dragonkin, demons, elementals, giants, mechanicals and the rest —
framed in the mark's own colour, so a hostile humanoid's ring is red and a
neutral one's is orange. Its badge says how it fights -- **M**, **R** or **C**
-- faded when that is a guess (see below). Corpses get no portrait.

**How it fights: melee, ranged or caster.** The thing that decides how a pull
goes: a melee mob has to reach you and can be kited; a ranged one shoots from
where it stands and is pulled round a corner; a caster stands still to cast
and can be interrupted. It leads the details row under the feet, in its own
colour -- **MELEE** orange, **RANGED** green, **CASTER** purple -- and is the
letter on the creature portrait's badge.

It is LEARNED FROM WHAT THE MOB DOES. JCore's enemy tracker reads every
hostile's casts already; each one it announces is sorted by the spell's
school: physical with reach past melee (Shoot, Throw) is a ranged attack, any
magic school a spell. The sightings are counted per kind of creature (its npc
id) and **kept across sessions** -- the first Razormane Hunter seen shooting
settles it for every Razormane Hunter, today and next time. The more frequent
kind wins; a tie goes to caster, because "it can be interrupted" is true
either way. Classic keeps them in `jambix.aio.fight.json`; Forever, since
1.47.0, in its own `jambix.aio.forever_fight.json`.

Before a mob has done anything, a guess, and the mark says which it is:

| How sure | From | Shown |
|---|---|---|
| seen | it has been seen doing it | `RANGED` |
| likely | its creature type (a beast bites), a word in its name (Archer, Rifleman, Hunter; Geomancer, Shaman, anything ending -mancer, -caster or -caller), or its class (a mage-class NPC casts, a paladin-class one swings) | `RANGED` |
| guess | only a mana pool, or nothing at all | `RANGED?`, faded |

Players come from their spec: a hunter is ranged, a mage, warlock or priest a
caster, an Enhancement shaman or a cat druid melee -- as sure as the role
behind it. *Melee, ranged or caster* on the Elements page switches the pill
off; the badge stays with the portrait.

The art is fetched once per class or creature type through the asset registry
and cached on disk; until it arrives the disc shows an initial. The portraits
are on the Elements page: one toggle each for players and NPCs, a shared size
slider, and a toggle for the badges. If a ring ever stays empty, the Debug page
lists the class ids seen on players and the load state of every portrait icon,
which tells an id nothing can name apart from art that never arrived.

**Colour.** Bosses, rares, quest and guide targets keep their category colour,
because that colour already says something. The plain categories — normal
NPCs, elites, critters — are coloured by whichever question you picked:

| Mode | What the colour means |
|---|---|
| Category colour | the old behaviour: one colour per category |
| Reaction *(default)* | red hostile, orange neutral, green friendly (orange, not yellow: yellow is the quest colour) |
| Level difficulty | the game's own five bands, red through grey |

Reaction is the default because "will this attack me if I walk past" and "can
I attack it" are different questions, and the overlay used to answer neither.
Players keep class colours over all of it.

**What it is doing, and to whom.** The marks above say what a thing *is*. These
say what it is *doing*, which is what changes the next button you press:

| Mark | What it says |
|---|---|
| **Cast bar** | The spell, its icon and the seconds left, the first row under the feet. **White** when it can be interrupted, **red** when it cannot, so "kick this" and "save the kick" read at a glance. A channel drains instead of filling. Only while casting: a mob that starts a cast grows a pill and a bar under it, which is a movement the eye catches. |
| **Status line** | One line, coloured by the most urgent thing it says: the crowd control on it and how long is left (`Polymorph 6s`, pale blue — do not break it), `on you` (red), `on your pet` or `on Thrall` (amber), `tapped` (grey), `in combat`, `mounted`. Nothing at all when there is nothing to say, so most marks never grow it. |
| **Threat** | Your threat on it and where that ranks you, the way Details' Tiny Threat ranks it: `threat 72% · #2 of 5`. **Green**, then **amber** from 70%, then **red** from 90%, when you are about to pull it. When it is yours: `aggro · #1 of 5 · next 85%`. For a tank (group role, spec, or a tank's stance or form) that is coloured by how close the runner-up is; for anyone else it is red outright. The numbers come from JCore's threat service, which asks the client about every party and raid member and their pets on every mob in the fight. Shown on every mob you have threat on, solo included (`aggro · #1 of 1`, green when nobody else could hold it). The Debug page's **Threat** line says what the service sees: how many mobs it ranks, who is in the roster, and how often the client answered. |
| **Ring under anything on you** | A red ring at the feet of every unit that has you targeted, sized to the model. "Which of these six is on me" is answered by looking at the ground. The ring is see-through, its glow stays on the rim, and the more rings there are the fainter each one is (1.66.3), so a pack still shows the mobs and the ground under them. |
| **Lines from attackers** | A line at chest height from anything attacking you (red), your pet or a party member (amber) to the one it is after — for as long as it is still on its way. Within six yards it has arrived, the line would be drawn under its own model, and it goes. This is the add that is coming, before it arrives. |
| **Tapped grey** | A mob somebody else has tagged is drawn grey, the way the game greys its nameplate — over every other colour, a rare's gold and a quest's yellow included, because no kill credit and no loot is the one thing about it that matters. |
| **Raid marker** | The skull, cross, moon and the rest, at the top of the stack: the client's own icons, read out of its archives (all eight verified in Classic Era 1.15.9). The marker's name, in its colour, stands in while the art loads. |
| **Threat panel** | Anything on the panel that has you targeted moves to the top and carries a red `you`. |

The ring and the lines are warnings, so the draw budget never drops them. The
box has three styles now: corner brackets (the default), a full box, and a 3D
box in the world.

**What that costs: nothing new for a hostile.** JCore's enemy tracker already
reads cast, target, combat and crowd control for every attackable unit in range,
every tick, for the rotation. The overlay reads those rows instead of asking the
unit again, so a mark costs no native call. Its own rationed read is kept for
the few units the tracker filters out. The slow facts (tapped, raid marker,
mounted) ride the classification's two-second refresh. Friendly units are never
read at all, and with the four marks switched off nothing is read.

**Detail falloff.** Health bars and tracers stop at the reduced-detail range
(90 yards by default); boxes and names carry on to the edge of each category's
own range. A health bar four pixels wide at a hundred yards is not information.
Turn the falloff off to get the old behaviour, where every mark was drawn at
every distance.

**Budgets.** All three ship at "no limit" and exist for the frame where a city
or a forty-pull says otherwise. The mark cap keeps the nearest things. The draw
budget only ever drops reduced-detail marks — never a warning, never the
nearest tier. The detail-read budget rations the overlay's own reads of cast
state and target, for the few units JCore's enemy tracker does not cover:
whatever is not refreshed this frame reuses an answer from a fraction of a second
ago. The live counters under them show what
is actually being drawn, so the sliders are set against measurements.

**Pull safety (1.87.0, Hardcore page).** Under each hostile mob not yet
fighting, a ring at the radius it notices you from: 20 yd at your level, a
yard less for each level you are above it and a yard more for each it is
above you, 5 to 45 yd (Classic's rule; *Aggro range at your own level* is a
setting, as Forever's may differ). It shows within 12 yd of its edge, fills
as you close in and turns from amber to red; full and red, you are inside it.
Neutral mobs are never ringed, nor are players or their pets and minions
(1.8.1): they notice nobody from a distance. An elite, rare or boss walking toward you gets
a curtain (gold, silver, red); a rare a pulse the first time it is seen.

The PvP marks, the PvP extras and the reactions' own world marks (the kick
lined up, who a reaction acted on, your reactions' rings, the rotation's
pick) left the plugin on 2026-10-11 with the Reactions page's old sections
(see *Reactions*).

**Beacons (1.87.0, Quests page).** Pillars of light you can see over a hill:
RestedXP's next waypoint (gold), the nearest three quest areas from Forever's
quest map (yellow to do, green to turn in; none while the game Lua bridge is
down), and the nearest five herbs (green), veins (orange) and chests (gold)
the ESP marks within 90 yd.

### Rotation

**You only ever see your own class.** Nothing on this page names an ability
your class does not have.

| Section | Shown | What it holds |
|---|---|---|
| Profile | always | No selector since 1.33.0: from your talents and your group role |
| Rotation | always | Enable, keybind (default X, ships **off**), opener, offensive cooldowns, trinkets |
| Reading the fight | always | **Spread keybind (default C, ships on)** |
| Reactions | -- | Nothing here since 1.8.0: the reactions are apart, on the Reactions page -- the switch, the decision panel and log, their marks, the readout |
| Crowd control | always | **Fear keybind (default V, ships OFF)** -- nothing fires without it |
| Tuning | always | Only count your own DoTs. Every threshold is derived; no sliders since 1.33.0 |
| Targeting | always | Auto target, search range, switch margin, assist the tank (also in the class window, under Group) |
| Threat and aggro | **tank-capable classes** | Taunts, mass taunt, reclaim scope |
| Forms and stances | **warrior, druid** | Switching mid-fight |
| Healing | **paladin, priest, shaman, druid** | Heal thresholds |
| Pet | **hunter, warlock** | Pet mode, growl, pet healing, focus |
| Spell window | always | Show it, icon size, how many used / coming, suggestions while off, auto attacks, combat only -- see *The spell window* |
| *Class* options | **that class only** | Everything that names one of its abilities |

So a warlock sees Life Tap and Drain Life thresholds; a warrior sees Shield
Block, Intercept, Bloodrage and rage pooling; a rogue sees combo points and
stealth. Neither sees the other's.

Class-specific widget ids are namespaced (`rot_warrior_dump_rage`,
`rot_druid_dump_rage`). Two classes can want the same setting without
colliding on one page, and a warrior's answer stays separate from a druid's —
which matters because settings persist per plugin, not per character.

The rotation has its **own keybind**, separate from the overlay's. Hiding the
ESP does not stop the rotation and vice versa.

### Reactions

Apart from the rotation (1.8.0). No switch since 2026-10-11 (the user:
"reactions should automatically activate in PvP when PvP is detected", not
an option): the reactions run on their own, the PvP ones and the
intelligence waking when PvP is detected, and the page's first live line
says what is detected now (then built-in and your own, where you are, the
last one sent); **Decisions** (*Show the
decision on screen*, *Log every decision and every refusal*); **Advanced PvP
Intelligence** (the PvP intelligence layer's switches, under *PvP
intelligence* below); and the readout at the bottom, which says why the last
decision was made. Nothing else is on this page: on 2026-10-11, at the
user's request ("drop/delete old stuff and not get it confused"), the old
*PvP* (the trinket's line), *PvP marks*, *PvP extras* and *In the world*
sections were removed with their modules, and the **Open Reactions UI**
button went the same day ("removed from being accessed by the player but
leave it in the code for future"): the window described under *Your own
reactions: the Reactions tab* is still in the plugin and still rendered, but
nothing a player can reach opens it. The built-in reactions and any of your
own already saved keep running from their saved state.

### World marks (1.89.0)

Every ring, curtain, beacon and pulse the AIO puts on the ground goes through
one layer (`modules/worldlayer.lua`), which draws them all at the end of the
frame (priority 190). The ESP's own marks are not in it: they are the ESP
page's. The **World marks** page holds the layer's settings, three sections of
marks, the test pattern and a live count of what was drawn, dropped and faded,
by mark, with where each mark's own switches are. The older marks keep their
switches where they were (a setting moved to another page loses what you
saved).

**Curtains (1.7.6).** The user: "the Aura curtains are over power the entire
game! We need to Work them yes but have them off by Default", then "any and
all should have an option to turn on and off". Every curtain the AIO draws
has a switch of its own, beside the rest of its mark, and every one is **off**
by default:

| Curtain | Its switch |
|---|---|
| The aurora around you | ESP, *Aurora around you* (`aurora_on`) |
| An elite, rare or boss heading your way | Hardcore, *Pull safety* (`pull_curtains`) |
| The mob to kill next | ESP, *Fight timers* (`killnext_on`) |
| Who most needs a heal; a mob loose on someone not the tank | ESP, *Group and healing* (`party_heal_curtain`, `party_loose`) |
| Round the tank | ESP, *Group extras* (`groupx_tank`) |
| Your target in execute range | World marks, *Combat rings* (`cr_execute_curtain`, new) |
| A wall round a telegraph as it lands | ESP, *Telegraphs* (`tele_wall`) |
| Boxes round mobs, when shown | ESP, *Box style* *Curtain* (the default is the corners again) |

The World marks page's *Curtains* section lists them and has *Switch every
curtain on* and *Switch every curtain off*. They shipped on, and the menu had
saved that as everyone's value, so each was switched off once
(`curtains_off_1:` in the migrations store; a saved *Curtain* box style
moved to the corners); after that every switch is the player's. Where a
switch covered more than its curtain (the execute ring and pulse, the
reactions' kick and control rings) the curtain got a switch of its own and
the rest stays on.

**Look.** *Draw the AIO's world marks* (on); *Brightness* (25-150%); *Detail*:
Full, Reduced (fewer lines and a fainter sheet on curtains and beacons) or
Minimal (also leaves the decoration out: the aurora, node pillars, patrol
routes, node memory's countdowns); *Colour-blind colours*: protanopia,
deuteranopia or tritanopia, every mark's colours shifted so what tells them
apart is a difference you can see.

**Performance.** *Most world shapes a frame* (200; 0: no cap). A curtain costs
by its lines, a beacon three, a ring or a pulse one. Past the cap decoration
goes first, then information; a warning (inside a mob's aggro range, a loose
mob, a kick, a missile landing on you) never. *Fade marks under units behind
walls* (on): a mark under a unit you cannot see is drawn at a third, through
JCore's rationed line-of-sight checks (*Line-of-sight checks a frame*, 8,
advanced). A mark whose drawing raises is counted and skipped; the rest of the
frame still draws.

**Lanes.** Rings under one unit never overlap: each kind has a band of its
own, outside the unit's model edge (its combat reach + 0.3 yd, as the ESP
measures it), and a kind with several steps outward:

| Under | Lanes, from the inside out |
|---|---|
| An enemy player | aggro and cast (the ESP's), time to die, your timers (four); the lanes kept for the kick, the trinket, crowd control, diminishing returns and your reactions have stood empty since their marks left on 2026-10-11 |
| Anything else hostile | the same: your timers move in where those lanes would be |
| A party member | health, out of your heal range, a healer's mana, a missile landing on them |
| You | your global cooldown, your swing, a missile landing on you |

**Calibration.** *Show the test pattern (12 s)* draws each shader shape round
you, lettered, straight through JCore's draw: A a shader ring a quarter full
with +x, -x, +y and -y round it (where does the fill start, which way does it
run?), B the plain ring asked for a quarter, C a curtain with its sheet, D a
beacon, a pulse every 2 s, E a card plate beside a spell icon (does the shadow
lie on the icon?) and F a bar asked for half. E and F need JCore 1.15. One
screenshot settles what was built from the API's descriptions alone.

**Combat rings** (World marks page; `modules/combatrings.lua`). At your feet,
in a fight while you attack, a ring filling as your next swing or shot comes
round (empty the moment one goes out), and a thin ring inside it emptying over
your global cooldown. The swing comes from the Swing Timer addon when it is
loaded, the loader's auto-attack helper, your casts of the swing, Auto Shot or
the wand, and on Era the combat log; its length from the addon, your weapon's
speed, the gap between the last two, or 3 s melee / 2.5 s ranged. Past the next
swing's time it keeps going round dimmer: a guess. Under your target, a ring as
full as its health with JCore's time to die at its feet; with your execute in
range (Execute or Hammer of Wrath under 20%, Kill Shot or Shadow Word: Death
under 20% where the client has them, Drain Soul under 25%; whichever is in
your spellbook) the ring turns red, a red curtain stands round it and a pulse goes
out as it crosses the line.

**Missiles, facing and patrols** (World marks page; `modules/tracks.lua`). A
missile in flight at you or your group, or fired by a hostile within *Look this
far* (40 yd): a line from where it is to where it lands and a ring there
filling as it flies, red on you, amber elsewhere; under the one it is aimed at,
following them. A missile whose landing the telegraphs already paint keeps its
line and gets no ring. Each hostile mob not yet fighting (the nearest eight): a
faint wedge the way it faces, as long as the range it notices you from (Pull
safety's rule). A mob walking, not fighting (the nearest four): the route it
walked, the last 20 s, older fainter, and an arrow ahead of it.

**Node memory** (World marks page; `modules/nodememory.lua`). A herb, vein or
chest the ESP lists that goes while you are within 60 yd, alive, in the open
world: a ring where it stood, filling back up over *Expected respawn* (300 s),
with its name and the time left ("Peacebloom 2:30", "Peacebloom due"). A node
of the same kind seen there again forgets the spot with a pulse. Kept by the
realm's clock across reloads, 30 a zone, forgotten 30 minutes after due. With
*A ring on your bobber* (on): a ring on the bobber, lit with a pulse when a
fish bites, by hand or with the fishing loop.

**Group extras** (ESP page; `modules/groupextras.lua`). For a priest,
paladin, druid or shaman, a grey ring under anyone further than your heal
range (the class window's *Heal range*, else the setting). In a fight a
curtain round the tank: green holding, amber when someone is within a fifth of
pulling a mob, red with one on someone else (on Forever, where every threat
read is 0, green or red by who each mob is hitting). Under each healer but you,
a blue ring filling with their mana, red under a fifth. Stack and spread are
not drawn: nothing JCore can read says them.

**Route and services** (Quests page; `modules/routes.lua`). The stops of
RestedXP's step after the one its gold beacon points at (up to *Guide stops
after the next one*, 2), fainter and shorter, with a dashed line along the
ground from each to the next. With your bags at *Bags: free slots at or under*
(4) or your worst piece of gear at *Gear: durability at or under* (25%), a
pillar on the nearest npc that buys (any merchant) or repairs, labelled "Sell"
or "Repair" and how far. While you are dead, a tall pillar on your corpse
(where the client says, else where you were last alive on that map). No
trainer: nothing readable says which spells your class could learn.

**The HUD's panels** take JCore 1.15's soft plates and bars where they are
drawn by the AIO: the Reactions overlay's body, the low-health banner, the
spell window's cast bar, and the ESP's info panels (through JCore's
`draw.panel`). The spell window's backdrop stays cut round its icons. The
next spell not ready yet gets a sweep round it filling as the wait runs down.
With *Shader drawing* off, or before JCore 1.15, all of it is flat as before.

---

## Rotations

**Your class is detected and decides which rule set runs.** This was a bug
until 1.5.0: the rotation *was* the warrior rotation, so a warlock got a
warrior priority list — every rule failed to resolve, nothing fired, and
nothing said why. An unsupported class is now idle and says so in the log.

| Class | Profiles |
|---|---|
| Warrior | Levelling Arms / Fury, Tank Arms / Fury / Full Prot |
| Paladin | Levelling (Ret), Retribution, Protection, Holy |
| Hunter | Levelling, Beast Mastery (with the melee weave, 1.8.1), Marksmanship, Survival; PvP (ALPHA/TEST) in a fight with a player, when its option is on |
| Rogue | Levelling, Combat, Assassination, Subtlety |
| Priest | Levelling (Shadow), Shadow, Holy, Discipline |
| Shaman | Levelling (Enh), Enhancement, Elemental, Restoration |
| Mage | Levelling (Frost), Frost, Fire, Arcane |
| Warlock | Levelling (drain tank), Affliction, Destruction, Demonology |
| Druid | Levelling (Caster) before Bear Form, Levelling (Bear) before Cat Form, Levelling (Feral), Feral Cat, Feral Bear, Balance, Restoration |

Death Knight, Monk, Demon Hunter and Evoker have no rule set: they do not exist
in Classic Era or TBC, which is what this targets.

**There is no profile selector (1.33.0).** A profile is only which spells you
have, and your talents say that; what to press with them is decided by the
fight (see *The rotation changes with the fight*). The one thing talents cannot
say is whether this group wants you to tank, and the group's role assignment
can: a warrior, paladin or druid given the tank role gets the tank profile.
The per-class selectors that used to be here, and *Auto prefers the tank
profile*, are retired; a value saved in them is never read.

### Architecture

`modules/rotation.lua` is the class-agnostic engine: situation snapshot,
priority walk, off-GCD lane, interrupts, defensives, healing target selection,
form maintenance, deadlock breaker. A class file in `modules/classes/` supplies
only data — its profiles, its interrupt/defensive/escape lists, and how to pick
a profile from talents.

Apart from the priority walk run the reactions, `modules/react/` (1.31.0;
apart since 1.8.0): interrupts, defensives, potions, mana, the pet, threat,
crowd control, escapes and the hardcore bail-out are weighed together by
score, with a memory of what was just done, in a job of their own just
before the rotation's, on the snapshot the two share. They leave a verdict
the rotation reads -- a reaction took the global cooldown, or something
says stop attacking -- and gives way to; the rotation never calls into them.
See *Reactions* below. Switched off (the Reactions page), the rotation runs
by itself: its own fixed sequence -- defensives, racials, the Hardcore
page's bail-out, breaking contact, dispels, interrupts -- as before 1.32.0.

**Resource is per profile, not per class.** A druid reads mana in caster form,
rage in bear and energy in cat, so the profile declares which.

### Healing

Healing profiles use the engine's `heal` rule shape: the target is the
lowest-health ally in range, resolved once per tick, so a heal rule reads as a
threshold rather than a search. Thresholds live under *Rotation → Healing*.

---

## Reactions: what happens before the priority list

The priority list answers "what is the best damage right now". It was never
the right tool for "several things are happening at once — which matters
most?" That used to be a fixed sequence in front of it: defensives, then
racials, then the hardcore bail-out, then breaking contact, then dispels, then
interrupts, each with its own lockout and none aware of the others. A pet heal
fired on its own clock in a third place. Nothing remembered what it had just
done, so a condition that stayed true (the pet is low, the race is lost) was
answered again on every frame it stayed true.

`modules/react/` replaces that sequence with one decision per tick:

```
game reads  ->  world state  ->  situations  ->  behaviour state
            ->  every reaction proposes  ->  score  ->  one per lane
            ->  safety checks  ->  cast  ->  remember
```

| File | Layer |
|---|---|
| `world.lua` | **Observe.** One shared table per tick: player, pet, target, every hostile, the group, the encounter. Built almost entirely from data already in hand (the rotation snapshot, JCore's enemy rows and threat boards); rules never read the game themselves |
| `detect.lua` | **Understand.** What the numbers mean — low health, a dangerous cast, threat about to pull — each a situation with two lines (`latch.lua`); the danger level, 0–100 |
| `behavior.lua` | **What kind of moment.** NORMAL → DEFENSIVE → EMERGENCY → ESCAPE, RECOVERY on the way back; and BOSS / AOE / PVP |
| JCore's `ctx.react` (`jcore/services/react.lua`, 1.8.0) | **Decide, act and re-evaluate.** The framework: the rules, candidates, scores, selection per lane, validation, execution, the memory of what was asked for, sent, confirmed or refused and which events are already answered, the latch and the journal. This folder's `engine.lua`, `memory.lua` and `latch.lua` until 1.8.0; `init.lua` now tells it about the AIO's world (`engine.configure`: the spellbook by name, the catalogue's word on a target, the rotation's gates, and the AIO's own action kinds -- the pet, the bag, an aspect, a target switch) |
| `pvp.lua` | **The other player** (1.81.0): what controls you, what each enemy player is immune to or bursting with, which worn trinket breaks what (`W.pvp`) |
| `rules/core.lua`, `rules/pet.lua`, `rules/pvp.lua`, `rules/hunter.lua` | **The reactions**, as data |

**Apart from the rotation (1.8.0).** The user: "Reactions themselves I wanna
separate completely from Rotations... Reactions will become Specifics you
set if you need the rotations to adjust for some reason but apart". The
reactions run in a job of their own, just before the rotation's (JCore's
scheduler, priorities 59 and 60), on the snapshot the two share
(`rotation.snapshot()`: whichever asks first builds it, the other reuses
it), and publish a verdict for the tick (`react.verdict()`). The rotation
reads the verdict and gives way: a reaction on the global cooldown means the
priority walk does not run that tick; a hold (the hardcore bail-out, easing
off threat) means nothing offensive runs; an off-GCD reaction (a potion,
Evasion) and a pet order (its own lane) leave the walk alone. The rotation
never calls into the reactions, and whatever a reaction sends outranks the
rotation in the cast arbiter anyway. A second job after the rotation's takes
its pick for the readout and sends the deferred reaction when the walk had
nothing to press. If the reactions' job ever raises there is no verdict for
that tick, the rotation runs by itself, and the log says so once.

**No switch (2026-10-11).** The engine is "the path, not an option" again
(1.32.0). From 1.8.0 until 2026-10-11 the Reactions page had *Use reactions
in the rotation*: off, no reaction acted, nothing owned a spell, the verdict
was empty and the rotation ran by itself with its own fixed sequence
(defensives, racials, the Hardcore page's bail-out through
`hardcore.should_stop_fighting`, breaking contact, dispels, interrupts), and
the readouts opened with *Reactions: OFF*. The user then said reactions
should activate on their own in PvP when it is detected, not by an option:
`R.active()` and `custom.master_on()` always say yes, a value saved for the
old switch changes nothing, and the rotation's own fixed sequence is only
the fallback for a tick without a verdict. The reactions outside PvP
(interrupts, defensives, the pet, the stings) run as they did with the
switch on; the PvP reactions and the intelligence wake on the picture's PvP
signs, which the Reactions page's first live line reports.

### The rotation changes with the fight (1.33.0)

A reaction is not only a defensive. It is what the fight does to every choice,
and the biggest is the rotation's: of the spells that would go out right now,
which is the right one HERE?

The priority walk used to press the first rule that passed, in the order the
class file wrote — the same order against one boar and against four, on the
move and standing, at full mana and empty, on a mob with a minute to live and
one with two seconds. Now every rule that passes is a **candidate**. Its place
in the class's list is its starting score (50, then half a point less per
place — the author's order is still the prior), and `modules/react/adapt.lua`
moves it from the same picture of the fight the reactions read:

| The fight | What moves |
|---|---|
| Two or more in reach of an area spell (1.56.0: counted where it lands) | +4 for each one past the first, up to +12; with three or more engaged, single-target damage −3 |
| One in reach | Area spells −15 |
| A crowd-controlled mob in reach, or (solo) an idle one it would pull | The area spell is not a candidate |
| Moving | Anything with a cast or channel is not a candidate at all — for every class, not only the hunter |
| Target dies before the cast lands | That cast −20 |
| Target dies inside 8s | Damage-over-time −12; an execute in range +10 |
| A long fight (25s+) | Damage-over-time +5 |
| Mana low, or recovering | Each spell minus what it costs (×150, up to −25) |
| Mana will not last the fight | Each spell minus what it costs (×90, up to −15) |
| Conserving | Each spell minus what it costs (×50, up to −8) |
| DEFENSIVE / EMERGENCY | Slows, roots and stuns +8; heals +8; a long cast while you are hit −6 |
| ESCAPE | Control +15; damage −10 |
| The target is running | Slows +10 |
| The target is closing on you | Slows +6; a cast it will interrupt by arriving −10 |
| PvP | Control +5 |

Every point carries its reason, and the readout's **Rotation:** line shows the
walk's candidates with their scores and why the pick won:

```
Rotation: Arcane Explosion 61.5 (pressed), Sinister Strike 50.0
  Arcane Explosion: +12 4 engaged: hit them all
```

The spell window's *next* follows the same scores. What did **not** change:
every gate that keeps a press from repeating or misfiring (upkeep, back-off,
the swing, the unanswered second, the channel, the key, the catalogue,
holding fire, the memory) runs first, exactly as before; the lanes are
separate; toggles (Auto Shot, a wand) and rules marked `fixed` keep their
place and are asked only when their turn comes, because asking arms them; and
with no reaction engine the scores are the list order, so the walk presses
exactly what it always did.

**Retired with it (1.33.0):** the profile selectors and *Auto prefers the tank
profile*; the whole Tuning section's sliders (*Work the numbers out
automatically*, AoE radius, minimum time-to-die for DoTs, critical and
conserving health and mana, the trade floor) — every one is derived; *Spread
damage from this many targets*; the wand's *Stop casting filler below* and
*Re-arm window*; *Spend whenever the fight is long enough*; and the hunter's
own options except the two that move your character (*Run and shoot before
there is a pet*, *Step out of melee*). Retired ids are listed once, in
`RETIRED` in `main.lua`: the plugin's setting read answers their built-in
default without looking at the menu, so no module — touched or not — can be
steered by a value saved before they went.

### What each skill does (1.34.0)

The scored walk knew what the FIGHT was doing; it did not know what each SKILL
does. Now it does, and weighs them against each other by it.

**What a skill is worth is measured.** JCore relays the combat log, and every
point of damage we deal arrives with the spell's name. Each cast of ours opens
a window; the damage that spell deals inside it -- the hit, the crit, every
damage-over-time tick, every missile -- is that cast's worth, averaged over the
last eight casts (`modules/react/damage.lua`). Until a skill has been measured
twice, its tooltip says what it should do ("13 to 18 Shadow damage", "40
Shadow damage over 12 sec"), read from `get_spell_description` once per rank.
Other players' damage is never counted.

**And weighed by what it does in the time it takes.** Of the damage skills
that would go out right now, each is worth its damage per second of the lane
it holds: a three-second cast holds it for three, an instant for the global
cooldown. An area skill counts every target it would hit (up to five); a
damage-over-time skill counts only the ticks the target will live to take.
When mana is what runs out first, it is damage per point of mana instead. The
best gets nothing, and every other loses up to 8 points in proportion -- so a
mark, an aspect or a toggle keeps its place, and among the damage skills the
one that kills fastest rises.

| What decides it | Example |
|---|---|
| Damage per second of the lane | 150 from an instant (100/s) beats 240 from a 3s cast (80/s) |
| Damage over time, by what it lives to take | 300 over 15s beats a 100 hit on a long fight, loses to it on a mob with 3s left |
| Targets hit | Arcane Explosion's 60 on two targets beats Sinister Strike's 100 |
| Damage per mana, when mana runs out first | The cheap spell's damage for the mana beats the dear one's |
| **The killing blow** (+6) | 100 health left: the instant that finishes it, not the 3s nuke that overkills it |
| **A window** (+8) | Overpower, Revenge, Riposte, Counterattack, Mongoose Bite: only usable for a moment after a dodge, parry or block |
| **Clearcasting / Inner Focus** | The next spell is free, so the dearest one gains most (up to +15) |
| **Shadow Trance / Presence of Mind / Nature's Swiftness** (+10) | The cast is instant: it goes, even on the move |

The readout's **Rotation:** line shows the reasons ("33% of the best damage
per second (Strong Bolt)", "kills it: 100 health left"), and **Damage per
cast:** what each skill has been measured to deal and over how many casts.

**A loading screen no longer stops the measuring (1.48.2).** The combat-log
reader kept the player's game object to know which hits were ours, and
compared it with `~=`. A game object compares through the client's own
`__eq`, which raises "Invalid game object!" once either side is stale, and
the kept one is stale after a loading screen. The raise came before the
cache could be replaced, so on Era it repeated on every hit for the rest of
the session, and nothing more was measured. The core log showed it every
three seconds from 14:17 on. It is an identity check now (`rawequal`, the
way JCore keys its units), and the guid is read again whenever the object
changes. Test: `aio_react_test` ("a stale player object after a loading
screen"). The picture of the fight (`react/world.lua`) kept the player's
object the same way, and compared it the old way, until 1.8.1: after a
loading screen every reactions tick raised, the log said so once, and the
rotation ran without them for the rest of the session (Forever, 2026-10-11).
Identity there too now; the test is beside the first ("world: a stale player
object after a loading screen").

### Standing still (1.33.1)

"Sometimes I'm just standing there doing nothing." Four causes, all fixed:

- **The red error text was read as a refusal.** "Spell is not ready yet" and
  "Another action is in progress" fire with every queued press, and two of them
  backed the rotation's own spell off for up to four seconds. Now only a refusal
  that will repeat on the next press counts (out of range, not facing, no line
  of sight, too close, the wrong target, immune); a bare UNIT_SPELLCAST_FAILED
  never does, and the rotation's presses are no longer backed off at all.
- **A pull we opened was dropped.** A Classic mark does not put the mob in
  combat with you, so when the marked mob wandered out of the opening range the
  rotation went back to *holding fire*: one to six seconds between the mark and
  the first shot. A mob we pressed anything at in the last twenty seconds is ours.
- **The bail-out stood still with nothing to wait for.** Under 20% with no
  potion, no defensive and no escape ready, holding the attacks back only took
  the hits; it now fights on and says so ("nothing left to bail out with").
- **Holds were longer than they needed to be.** Easing off threat is only for
  threat still climbing (or at 98%+), at most 1.5s every 8s; the wait for an
  instant reaction to land is at most half a second.

**And anything else is caught as it happens.** In combat, with a target, not
casting, the global cooldown free, no auto attack running and no Auto Shot or
wand shot in the last 4.5s, standing still, and nothing of ours sent for 0.6s: the log gets one `[idle]` line naming every
reason -- the hold, the cast it is waiting for, holding fire, each rotation
candidate's state, and the gates on the rules that never became candidates --
and another when it ends. The readout keeps the count and the last reason.

**"Rotation: nothing to press" was the panel, not the rotation (1.34.1).** The
rotation presses on one frame in dozens; the global cooldown fills the rest. The
panel named the rotation only on the frame it pressed, so a working rotation
read "nothing to press" nearly all the time. It now says what the rotation is
doing: *pressed Arcane Shot*, *last Aimed Shot 0.8s ago; next Serpent Sting*,
*casting Aimed Shot*, *holding fire*, *held -- Hardcore bail-out*, *waiting for
Mend Pet to start* -- and *OFF*, *paused* (the rotation key) or *not running*
instead of a frozen last frame. A headless fight with the real hunter rules,
catalogue, rotation and engine now checks it end to end.

**Two more, from a live hunter log (1.35.2).**
- *The rotation's own spells were still backed off.* The note above said they
  no longer were; that was not true for a refusal that repeats. Two "You are
  too far away!" held Auto Shot for several seconds after the mob had walked
  into range. The rotation's gate no longer backs anything off; reactions
  still are.
- *"Standing still" while shooting.* The client's auto-attack flag does not
  cover Auto Shot or a wand on every build, so the idle report fired with Auto
  Shot going off. A shot in the last swing now counts as busy.

The same log showed a manual Growl reaction meeting "Spell is not ready yet"
every few seconds; it is gone (the pet's autocast does it). The client's red
text is logged as *client error after Arcane Shot: ...* instead of reading as
the reaction's own refusal.

### What the fights teach (1.37.0)

The catalogue says what a spell does in general; the client says, every fight,
what it did *here*, and until now nothing kept the answer. Since 1.35.2 the
rotation's own presses are never backed off, so a spell the mob is immune to
would go out again every second -- and an immune hit still costs the mana and
the global cooldown. `modules/react/learn.lua` remembers, by mob name, for the
session (a reload starts over):

| What the client said | What is learned | Read by |
|---|---|---|
| *Immune* (the combat log's miss, or the red text) | That spell on that mob is held for 12s. The same answer from a second mob of the name, or from the same mob 12s later, learns it for the name. Immune to two different spells at once is a bubble on one mob and teaches nothing; a hit from the spell later unlearns it | the rotation and every reaction |
| *Target too close* at a steady reading of d yards | That mob's dead zone reaches d + 0.5 (at most three yards past the catalogue's eight) | the minimum-range check |
| *Out of range* at d, inside the catalogue's reach | That spell reaches d - 0.5 on that mob | the range check |
| *Evade* | The mob is going home; nothing is pressed at it until 4s after the last | the rotation and every reaction |

**Range is measured hitbox to hitbox (1.58.1).** The client measures a spell's
range -- a shot's reach and the eight-yard minimum that makes the hunter's dead
zone -- between the EDGES of the two hitboxes: both combat reaches come off the
centre distance. A melee swing reaches max(5, both reaches + 4/3) yards from the
centre. Until 1.58.1 the hunter's rules and the rotation's range check measured
the centre against eight and five, so:

- Auto Shot was wanted 8 to 11 yards from a normal mob's centre -- 5 to 8 from
  its edge, still the dead zone -- and the client answered "Target too close"
  (the Forever trace: *Snow Tracker Wolf: too close at 10.2y*; session 26:
  *3 presses, 0 shots at 9.5 to 11 yards*).
- Raptor Strike and Mongoose Bite were not wanted 5 to 7 yards from a big mob
  the client lets you hit from there, which the rules took for the dead zone.
- On Forever, the step that switches a leftover melee attack off so Auto Shot
  can start (it reads the attack flag past "eight yards") could switch your
  melee off while you were still in melee with a big mob.

Now `H.gap` (centre less both combat reaches, JCore's `units.combat_reach`),
`H.melee_range` and `H.in_melee` in rotation.lua are the one geometry, read by
the hunter's rules (at range, in melee, the opener, Concussive Shot), the range
check every press passes, the spell window's forecast, the kite's step out
(clear once the edge is nine yards off), the plan's dead-zone weight and *Clip
the add*. With a normal mob (both reaches 1.5) the dead zone is 5 to 11 yards
from its centre. The learned edges are read the same way: "too close at 7.2y"
now means seven yards from the mob's edge.

A mob running in moves its own reading, so a range answer is only kept while
the gap is steady. Each lesson is logged once (*[learn] Savannah Prowler: too
close at 8.6y -- its dead zone reaches 9.1y*), the reaction readout has a
**Learned:** row, and a held spell names it (*Serpent Sting held: learned:
Stonevault Basher is immune to it*).

**Runners (1.38.0).** In Classic most humanoids run at about a fifth of their
health and come back with company. Which mobs do is learned too: one of the
name seen fleeing while low says the name runs (*[learn] Kolkar Bloodcharger
runs when it is low*); two that went under 15% and died where they stood say it
does not. Until a name has shown either, humanoids are presumed to run and
nothing else is. On a mob that runs:

- **the rotation keeps the slow for it.** A slow with a real cooldown
  (Concussive Shot's twelve seconds) is not spent while the mob will run before
  it is back (*saving it: it runs at 20% in about 3s*). Wing Clip and Hamstring
  have no cooldown and are never held.
- **the moment it runs, *Stop the runner* puts it on** -- the class's slow, root
  or stun from the catalogue, the first that is ready and in range, at priority
  70, and nothing if one is already on it.

**An evading mob and the pet.** The pet's own misses are read too: the pet is
usually the one still hitting a mob that is going home, and chasing it there
drags it through whatever is on the way. *Pet: off the evading mob* calls it
back, and the pet module refuses to send it at that mob again for 8 seconds,
even from an assignment.

**Nothing spent on the dead.** A mob with under two seconds to live, that is
not on you, while your shots, your swings or the pet are already finishing it:
a special that costs mana waits (*it dies in 1.4s anyway: keep the mana*). Not
when the bar is 80% or fuller, and never on a mob that is hitting you -- there,
quicker is safer.

### The pet is the tank (1.36.0)

A live hunter log, pull after pull: the mark, Serpent Sting a second later,
Arcane Shot -- and the mob leaves the pet. From there it is in the dead zone,
where Auto Shot cannot fire, for most of the fight: one stretch was 27 seconds
of a Raptor Strike every six. The old wait ended the moment the mob turned onto
the pet, when the pet's threat is still one Growl.

Solo, with the target on the pet, a damage special now waits:

- **for the pet to settle it** -- 1.5 seconds on the pet first;
- **while you are near pulling it** -- your threat on it (the client's percent,
  100 = it turns to you) at 85% or more, until it is back under 70%. The log
  shows *pet_threat ON (87)*;
- **when this one would do it** -- what you have dealt it so far (counted from
  the combat log, swings and Auto Shot included) and that percent say what one
  more of the spell would make it; at 85% it waits.

Auto Shot, a wand and melee swings never wait, nothing waits once the mob is on
you anyway, nothing waits on a mob with under four seconds to live, and in a
group (a player tanks) none of this applies. Control (Concussive Shot, Wing
Clip) and the mark are not damage specials and go as before. A waiting
special says why in the idle report and its watch line (*Arcane Shot held:
the fight: 87% threat: the pet keeps it*): *the pet has held it 0.8s*, *87%
threat: the pet keeps it*, *62% threat, about 91% after it*.

**When it leaves the pet anyway,** *Shed threat* now covers the solo pet:
Disengage in melee (level 20), Feign Death (30) -- never Cower, which on a
hunter is the pet's own and would hand the mob to you for good. The log gets
one line with what to tune from: *Savannah Prowler left the pet for you: your
threat 104%, the pet had it 6.2s; last press Arcane Shot 0.3s ago*.

**Two small ones from the same log.**
- *Mend Pet on the frame you stopped.* The moving flag drops for a frame between
  two movement keys; a channel pressed then is "Can't do that while moving". A
  cast or channel now waits until you have been still for a quarter second.
  Auto Shot and instants are not held by it.
- *"Target too close" at eight yards.* A mob running in covers a yard and more
  before the press lands. While the gap is closing, the inside edge of a
  ranged spell's range moves out by up to two yards with the closing speed.

### Mend Pet, weighed (1.66.0)

A player asked for "auto Mend Pet at a pet health %". The reaction already
healed by the pet's health. Since 1.66.0 that line only opens the question,
because Mend Pet is a five-second channel: you stand still, Auto Shot stops,
and the kite cannot step out. `react/petcare.lua` asks three things, in this
order, and the first that fails is the reason the heal waits. The readout
shows it, and the reaction log gets *Mend Pet waits: ...* every 3 s at most.

**Can you afford to stand still?** These are vetoes:

| Situation | Says |
|---|---|
| Hardcore bail-out, or ESCAPE mode | *bail-out: leaving, not standing still* / *escaping: no time to stand still* |
| You stand in a telegraph (`ctx.telegraphs.on_me`) | *standing in Flamestrike: move first* |
| Something is on you, or you are losing health, and your health at the end of the channel would be under the defensive line (35%) | *you would end it at 30% (falling 5%/s)* |
| Something is on you and your time to live (the field's, or the plan's with every mob counted) is under the channel plus 2 s | *3s to live with 2 on you* |
| Under 50% health, with a mob in melee with you or arriving inside the channel (`time_to_reach`) | *1 in melee with you at 45%* / *Gnoll Brute reaches you in 1.7s* |
| Something is on you (or you are outnumbered), and the heal would leave less mana than your first ready escape costs (`P.auto.cost`) | *it leaves 40 mana and Feign Death needs 50* |

Short of a veto, a mob in melee costs 8 points each (hits push a channel back),
one arriving costs 5 and a big cast at you costs 6.

**Will it matter?** The pet's seconds to live, at the rate it is losing,
against what it is holding. For one mob that is your target, that mob's time to
die (not for a mob that runs at low health). For more than one, the plan's time
to clear. If the pet outlives that by 1.3x plus a second, it finishes the fight
(*the pet lasts ~18s and its fight ends in ~3s: shooting on*), and *Top up the
pet* heals it afterwards. A critical pet (12%) is healed anyway.

**Will it work?** Healing per second, from the tooltip ("Heals your pet for
1225 health over 5 sec." over the pet's maximum health; the retail "% of its
total health" form and Health Funnel's "every second" form are read too).
Until the tooltip reads, the guess is a third of the bar over the channel. A
pet whose loss outruns the heal so far that it dies inside the channel is not
channelled into (*the pet is losing 30%/s and Mend Pet heals ~7%/s: it dies
inside the channel*). A guessed heal counts as 1.5x bigger here, so a bad guess
never gives up on the pet. Intimidation (*Intimidation: save the pet*) is the
answer to that pet: once the mob is stunned, the heal works again.

**What the pet is worth.** On top of the old points (under the line, falling,
critical, more than one on it, the tank when solo): +6 when it has under the
channel plus 1.5 s to live. A Beast Mastery hunter with 11 or more points
gets up to +6 (*Beast Mastery (21 points): the pet is much of your damage*).

**Improved Mend Pet** (15% / 50% per tick, five ticks: 56% / 97% a channel).
The pet's debuffs are read twice a second, only with the talent, and only
removable types count (Magic, Curse, Disease, Poison). One whose name is crowd
control (Fear, Sleep, Polymorph, Scream, Terrify, Seduction ...) means the pet is out of the fight and
the talent is your only way to free it. It is its own event
(`pet_free:<pet>:<aura>`) at any health, worth up to +18 (*Improved Mend Pet
2/2: 97% to free it from Psychic Scream*), +6 more if its mob turned on you.
Any other removable debuff raises the heal line by up to 15 points and adds up
to +5.

**A channel that turns dangerous gives way.** While the heal runs, the same
safety questions are asked with the time it has left (none in its last half
second; mana is already paid). When one says no, the rule's `yield` hook
(`engine.yielding`) does two things. Any reaction that beats the rotation
may cut the channel; before, it had to outscore the heal by 10. And
`rotation.cast_gate_busy` opens, so the walk can press and the kite can step
out. The log says *Mend Pet gives way: you would end it at 14% (falling
4%/s)*. Any rule that owns a channel can declare
`yield = function(W, spell) return why_or_nil end`.

Tests: four *pet heal (1.66.0)* cases in `aio_react_test` (the vetoes, the
forecast and the tooltip parse, Improved Mend Pet and Beast Mastery, giving way
through the real rotation's cast gate).

### The pet's taunt, aimed (1.68.0)

The user asked for the pet to Growl any mob that is about to pull off it
because of your threat, and any mob already on you. The reaction should scan
every mob in the fight and switch the pet's target, or use a spell on a mob,
when that makes sense.

**What a Growl is.** The client's spell tables (DB2, read offline) say Growl
and Torment are threat at melee range, not a forced taunt. Growl ranks give
50 to 415 threat, Torment 45 to 395, from five yards or both combat reaches
and 4/3. The mob turns to the pet once the pet's threat passes the holder's.
Suffering is the same for everything within ten yards of the Voidwalker.

**Why autocast is off while the engine runs.** Autocast fires at the pet's own
target the moment Growl is ready. Any Growl wanted elsewhere found it on
cooldown: that is why the manual Growl went in 1.35.2. So while the reaction
engine runs, `modules/pet.lua` takes Growl (or Torment) off autocast and the
*Pet: taunt* reaction presses it. Autocast goes back to what it was once the
engine stops asking for 1.5 s: the rotation off, mounted, dead, pet mode Off
or Focus. It also goes back at once when the plugin is paused or unloaded
(`on_disable` / `on_unload` in `main.lua`). A new pet's autocast is read
afresh. The cooldown clock is our own press plus the pet's own
`UNIT_SPELLCAST_SUCCEEDED` (autocast, a click on its bar), with the base
cooldown from `get_spell_base_cooldown` (5 s by default, 120 s for Suffering).
A press the client refused (`UNIT_SPELLCAST_FAILED` for the pet) was never
used. Growl waits for 15 focus where the client says what the pet has.

**Who needs it** (`modules/react/petthreat.lua`, every engaged mob, every pass):

| Need | When | Points over the base 74 |
|---|---|---|
| on you | its target is you | +14; +6 in melee with you, +8 when you are under 50%, +4 elite, +4 outnumbered |
| turning | your threat on it (the client's percent) is 90 or more, or 75 and climbing to 100 within 2 s | +6 to +14 |
| the pet's own | what the pet is attacking: on cooldown, as autocast did (not under 8% health) | -22 (52: still above the rotation) |

The taunt goes to the neediest mob **inside the pet's reach**, measured from
where the pet stands. That can be a mob beside the pet's own: the pet does not
have to change targets. A mob on you **outside** its reach is where the pet
goes (*Pet: pick up the add*), and it Growls the mob once there. The
Voidwalker's Suffering goes out for two or more on you or about to be within
ten yards of it.

**Across the fight** (`tactics.lua`, solo, a pet that taunts):

- The mob on you goes to the pet even when it is the one to kill first. You
  kill it once it is on the pet.
- When the mob the pet leaves would turn on you, the pet still goes if the one
  on you is hitting you in melee or you are under 60%. The plan says *Mottled
  Boar is hitting you in melee: the pet takes it, Defias Pillager stays on the
  pet's threat*.
- A mob on the pet whose threat you are close to pulling (75%: x0.7, 90%:
  x0.4) drops down the kill order, unless the taunt lands on it within a
  second. You shoot something else and it stays on the pet.

**Intimidation** (hunter, priority 73): when the pet's mob has turned on you
(or your threat on it is 95%+) and Growl cannot fix it, the pet's mob is
stunned and the pet gets a large amount of threat. "Cannot fix it" means
Growl is not ready within a second, or it went out at that mob 1 to 4 s ago
and the mob stayed on you.

**In a group** with a living tank, the tank holds the mobs. There is no upkeep
Growl and nothing for "turning" (that is Feign Death's job). A mob on you is
Growled only when it is not a boss and the tank is not on it. Pet mode Tank
ignores the group.

**Forever:** the pet's spellbook reads empty there (`get_pet_spells` always
`{}`, the API recorder). So nothing is aimed, autocast is untouched, and none
of this runs until JCore can read the pet's book. Its threat is unread too, so
"turning" would never fire there anyway.

**Proof, not the client's word (1.68.1).** The first log of 1.68.0 had two
aimed Growls refused with "Spell is not ready yet". The mob came back to the
pet a second later anyway: the pet was still Growling by itself, because the
switch-off was skipped whenever the client's autocast flag read "off". The
spell tables (`SpellCooldowns`, `SpellCategories`) settle what "not ready"
means: Growl has its own 5 s category cooldown (category 82, shared with
Cower rank 1) and no global cooldown. Claw, Bite and Torment are on the
pet's 1.5 s one. So autocast is now switched off and back on without asking
the flag. The pet's own `UNIT_SPELLCAST_SUCCEEDED` says whether that worked:
a Growl we did not press within 1.5 s means autocast is still on. The first
one gets it switched off again (one within a second of the switch-off proves
nothing). The next one gives up for the session: autocast is back on as the
mode wants, and *Pet: taunt* sends the pet onto the neediest mob in reach
instead of pressing (`Pet: attack`, pinned 4 s). Its own mob it keeps
Growling by itself. A "not ready" error within 0.6 s of our press means the
press was not used: it is asked again in a second, not five. Two such
refusals with no press ever confirmed by the pet's events, or three in 20 s,
give up the same way. A refusal followed by the pet's own SUCCEEDED for that
press was somebody else's error. The reaction log names every spell sent with
an unnamed client error. A click on the pet's Growl while the engine aims it
also reads as "by itself".

Readout: *Pet taunt: Growl in 2.1s | next Mottled Boar (on you, 3y from the pet)
| the pet goes to Kobold (on you, 20y from the pet: out of reach)*. It is its
own row with one mob, and it rides on the plan's second row with two or more.
The press itself shows as *Pet: Growl -> Mottled Boar* with its points.

Tests: eight *pet taunt* / *Intimidation* cases in `aio_react_test`, four
*the aimed taunt* cases in `aio_hunter_test` (autocast taken and given back,
a fresh pet, the clock, a mob that is not the pet's target).

### The pet's skills, when they help (1.71.0)

The user asked for the same treatment for every pet skill: the best time to
use it, and on which target. What each skill does comes from the client's spell
tables, extracted offline by `tools/jcheck/beasts_extract.js` into
`modules/beasts_data.lua`: every rank and its level, cooldown, global
cooldown, focus or mana cost, range, and area radius. Rerun it after a client
patch. The file holds both clients, and each
reads its own (1.78.2): Forever's tables differ (Furious Howl is a 30 s
cooldown there, not 10) and have 19 skills Era does not. The rules are
`modules/react/rules/pet.lua`, loaded for every class.

Left to the pet's autocast, because damage on cooldown is their job: Claw,
Bite, Screech, Lightning Breath, Scorpid Poison, Firebolt, Lash of Pain. Prowl
stays as you set it.

| Skill | Pressed when | Score |
|---|---|---|
| Furious Howl (60 focus, 10 s, next attack of the party within 15 yd of the wolf) | in combat, 2+ of you in reach (you count, each party member counts) | 50 + 5 per extra |
| Dash / Dive (15 s sprint, 30 s) | the pet's mob is 15 yd+ from it, hitbox to hitbox, and in a fight (or the one it was sent to) | 60, +10 when it is on you |
| Charge (boar, 8-25 yd) | its mob is 8.5 to 24.5 yd away, in a fight | 62, +10 on you |
| Thunderstomp (60 focus, 60 s, 8 yd) | 2+ engaged within 8 yd of the gorilla, or one on you beside it | 56 + 6 per extra, +8 |
| Shell Shield (12 s, 3 min) | in combat with something on the turtle, and under 50% falling 3%/s+, or 3+ on it, or pet critical | 70 + up to 15 |
| Cower | in combat, in a group with a living tank, not the tank, pet mode not Tank: the threat board's pet entry at 90%+, or the pet holds it | 66 (threat), +14 holding |
| Sacrifice (Voidwalker) | in combat at 25% or less and falling or being hit, or at 35% heading under 10% | 82 (defensive) |
| Seduction | a humanoid (creature type 7) add on you, not your target, not controlled, not a player; solo, or the crowd-control key held; event `cc:<guid>`, shared with *Crowd control an add* | 84 (cc) |
| Consume Shadows | out of combat, nothing engaged, Voidwalker under 80% | 45 |

Every pet skill above is pressed on the pet lane and **held** while the
engine runs: `pet.aim(name, restore)` takes it off autocast once per pet and
renews a 1.5 s lease each pass. That includes out of combat, so autocast
cannot fire one in a fight's first moment. `pet.release_all()`, before the
pet tick's gates and in `main.lua`'s `on_disable` / `on_unload`, gives it
back as it was (Cower back *off*). A skill the client says has no autocast is
only pressed. The 1.68.1 proof works per skill:
- A use the engine did not press means autocast is still on. The first one
  gets it switched off again; the second gives up for the session.
- Refusals give up too, but only for skills off the pet's global cooldown.
  Claw, Bite and most skills start that cooldown (1.5 s, category 133);
  Growl does not. A "not ready" for a skill on it is asked again after it
  and proves nothing.

**Focus.** A skill whose cost would leave the pet under 15 focus waits while
Growl is aimed, the pet is the solo tank, and Growl is ready within 3 s. The
readout says *the pet has 65 focus, Thunderstomp needs 75 (15 kept for
Growl)*. Where the client does not say what the pet has, nothing is held back.

Tests: seven *pet skills* cases in `aio_react_test` and two in
`aio_hunter_test`.

### Tameable beasts on the ESP (1.72.0)

The user asked for the ESP to tell a hunter "which mob is tameable and what
rank spell/skill they have that we can get". `modules/tame.lua`, drawn by
`esp/elements.lua` (a TAME chip, and text on the details line):

- **Tameable and family** come from the client's creature cache, the server's
  type flags for each creature it has described (`ctx.creatures.beast`,
  JCore 1.8.6). The client writes it when it exits, so a beast first met this
  session is known from the next one on. Era's cache held 119 tameable beasts
  out of 175 beasts on 2026-10-04.
- **What a beast of level L teaches:** each of its family's skills
  (`beasts_data.lua`, the family's own line; trainer skills such as Growl and
  Great Stamina are left out), at the highest rank learned at L or below.
- **"?"** until that npc id has been seen using the skill. The combat log's
  SPELL_CAST_SUCCESS / SPELL_DAMAGE / SPELL_AURA_APPLIED from a Creature guid,
  named as a family skill, counts. The Classic log has no spell id, so the
  rank stays the level's. Kept in `ctx.store("tame")` by npc id. Cower is
  listed only once seen.
- **"new":** above the rank of that skill in your current pet's book, or not
  in it. The hunter's own Beast Training list is not readable.
- **TAME** only at or under your level; above, the line says *tame at 32*.
  Never on players, pets, or anything that is not a beast. Nothing is read
  unless you are a hunter.
- Cost: one table lookup per beast mark, cached two seconds per unit, using
  the frame's own time (`P.esp_collect.now` / the view's `now`). The
  frame-cost test (`aio_esp_perf`) caught a clock read per mark before that.

Tests: `aio_tame_test` (4) and one case in `aio_esp_marks_test`.

### Stealth when it is worth it (1.46.0)

The rogue's Stealth rule was "out of combat and not stealthed": every run
between quest givers went at stealth speed, and food was cancelled the moment
it started. Now the world decides (`H.stealth_wanted`, rotation.lua). Stealth
goes up for:

- **the opener** -- a target you are going for, attackable and not fighting
  yet, within 40 yards: the approach is unseen and Ambush (or Cheap Shot while
  levelling) is there when you arrive;
- **the sneak** -- a hostile (red, not yellow) that is not fighting you, close
  enough to notice you: about 20 yards at your level, a yard more or less per
  level between you (plus 5 for walking towards it), and a grey one not at all.

Never mounted, eating or drinking, or with nothing about -- then it is only
slower. It works the same on Era and Forever (`is_enemy_with` answers on both).

### The classes' own pages (1.35.1)

The last of the rotation options. Each class's own section kept switches and
lines the fight can decide; they are gone, and nothing reads them:

| Class | Retired | What decides it now |
|---|---|---|
| Warrior | Dump rage above, Bloodrage below / needs health above / before a pull, Pool rage for Execute, Sunder while target above, Shield Block, Intercept, Hamstring runners, Break fear, Demoralizing Shout | The main attack's own cost (Mortal Strike and Bloodthirst 30, Whirlwind 25, Shield Slam 20): Bloodrage below it, a dump above it plus a Heroic Strike; Bloodrage never while health is the problem; Sunder while the fight lasts 12s+; Intercept only for a target out of reach and not coming; Demoralizing Shout with two or more on you; the rest always |
| Rogue, Druid | Spend combo points at, Open from stealth, Maul rage above | Five points, or three on a target with under 7s, two under 4s or 15%; stealth always opens; Maul above 30 rage (35 with Swipe to pay for) |
| Paladin, Shaman | Heal myself below, Drop totems | The derived defensive line, or sooner while health drains fast; totems always |
| Priest | Shield myself below, Renew myself below | A shield when something is on you below 85% or health is draining; Renew under 65%, or 85% while draining |
| Mage | Frost Nova when something reaches you | Always, when something is in melee |
| Warlock | Fear adds the pet is not holding, and the seven manual-override sliders | The crowd-control key; every threshold derived |

**What stays is the warlock's bag:** keep a Healthstone, keep and wear a
Soulstone, and the soul-shard limit with what to keep -- a setting that
destroys items is the player's, not the fight's. And the hunter's two that
move the character. A whole-plugin boot with the rotation on and a hunter
logged in (tests/aio_boot_react_test.lua) runs every frame through the
reaction engine and checks the log stays clean.

### What it took over (1.32.0)

The reactions replace settings, not just code. Every one of these is gone from
the menu, and no code reads it — so a value saved before 1.32.0 cannot keep
steering anything from a settings file nobody can see:

| Removed | What decides it now |
|---|---|
| Interrupt casts | Always: one kick per cast, harmless casts late, dangerous ones at once |
| Use defensive cooldowns, Defensive threshold | Low health, the lost race, a big cast incoming, a spike, being surrounded; the line is derived from what is hitting you |
| Use racial abilities | Each defensive racial waits for the problem it fixes; the offensive one goes into a burst window |
| Dispel harmful effects | Always, by aura type: you first, then the most hurt ally, the healer, the tank |
| Break contact when the fight is not winnable, Life in reserve to run | The measured race; the runway is your quickest escape's own cast time |
| Manage Growl, Let the pet interrupt | Growl always follows the pet mode; since 1.68.0 the engine aims it at the mob that needs it (see *The pet's taunt, aimed*); the pet's kick is scored with yours |
| Mend Pet / Health Funnel, Heal the pet below | One heal per dip, before the line; the line follows how fast the pet is losing, up to 45% solo and 25% in a group. Since 1.66.0 the line only opens the question: see *Mend Pet, weighed* |
| Stop fighting when critical, Stop fighting below | *Enable hardcore utilities* is the switch; under 20% until back over 35% |
| Use healthstone or potion, Drink below | Everyone, hardcore or not: under 35% or on course for it |
| Use offensive cooldowns, Use on-use trinkets (1.39.0) | The burst window, from the fight: long enough to use the window, enough mana to follow through, and spending changes something -- losing the race, a pack, or a fight long enough that the cooldown comes back anyway. The same terms the offensive racial always had |
| Allow single-target taunts (1.39.0) | Never read: taunts already followed *Reclaim enemies nobody is holding* |
| Rest: Eat below, Drink below (1.39.0) | Never read: rest sits down under what the next pull needs and stands up once it has it |
| Fear or slow to break contact, Hearth below | Escapes when the fight is lost or bailing; the hearthstone stays opt-in, at 15% with nothing hitting you |
| Decide urgent actions by score | The engine is the path |

What stays is what is genuinely yours to choose: the rotation's switch and
keys, *Enable hardcore utilities*, *Hearthstone as a last resort*, the
crowd-control key (crowd control still waits to be asked in a group), the pet
mode, offensive cooldowns and trinkets, targeting, and the readout and overlay
toggles.

### The scale

Every reaction has a base priority on one scale; the rotation's own presses
stand at 40.

| Base | What |
|---|---|
| 100 | Survival: healthstone, healing potion |
| 96 / 95 | Hearthstone out (opt-in); the hardcore bail-out |
| 92 | PvP: break a player's control, the PvP trinket last (1.81.0) |
| 90 | Interrupt (86 for a hunter's Scatter Shot or Intimidation used as one; 87 for a stun or fear on a player's cast, or Grounding Totem and the like) |
| 82 | PvP: answer a player's burst (Recklessness, Arcane Power...) |
| 88 | Break contact (escapes) |
| 87 / 85 | Surrounded: area control (Frost Nova, Psychic Scream, Howl of Terror, Intimidating Shout, War Stomp); crowd control an add |
| 80 / 78 | Defensive cooldown; a racial that fixes the specific problem |
| 75 / 72 | Restore mana (a gem, then a mana potion); a mana cooldown (Evocation, Innervate, Mana Tide Totem) |
| 74 / 73 | The pet's taunt (Growl, Torment, Suffering) at the mob that needs it most (1.68.0); Intimidation to give the pet back a mob that turned on you |
| 74 / 70 / 68 | Intimidation to save the pet; heal the pet; the pet picking up an add, when the plan says what it holds will stay on it (or, with a pet that taunts, when the add is hitting you in melee or you are under 60%) |
| 70 | Stop the runner: the class's slow, root or stun on a low mob the moment it runs; PvP: off a target in Divine Shield or Ice Block |
| 66 | Pet: off the evading mob -- called back and kept off it for 8s |
| 65 | Shed threat (Feign Death, Fade, Cower), or ease off; solo, Disengage or Feign Death when a mob leaves the pet for you |
| 64 | PvP: find a player who vanished beside you |
| 60 | Dispel |
| 58 | PvP: purge a player's buff worth it |
| 40 | **the rotation** |
| 20 | Top the pet up between pulls |

### Scoring

The base is where a reaction starts, not where it ends. Each rule adds its own
reasons — an interrupt gains for a dangerous cast (a heal, a fear, a big bolt:
read from the spell's name), for a cast about to finish, for a boss caster,
for a cast aimed at you — and the engine adds three more:

- **the mode**: an emergency raises survival and escapes and lowers the pet
  heal (a five-second channel is not what a dying character should start);
  ESCAPE raises escapes by thirty; a boss raises interrupts and threat
- **the memory**: something the client refused twice in a row loses fifty
- **the lane**: one winner for the global cooldown, one off it, one for the
  pet. Every valid reaction is never fired; the rest are listed with their
  scores.

Anything scoring below the rotation's 40 waits for a tick on which the
rotation had nothing to press.

### Memory: one event, one answer

An attempt is remembered from the moment it is asked for until the client
answers — `jcore.cast.sent`, then `UNIT_SPELLCAST_SUCCEEDED`, or
`UNIT_SPELLCAST_FAILED` / `UI_ERROR_MESSAGE`. And the EVENT it answered is
remembered as handled:

- a cast is one event — caster, spell, start time — kicked once, however long
  it stays on the cast bar
- a dip of the pet's health is one event, from the first moment it needed a
  heal until it is back over the exit line: one Mend Pet, then six and a half
  seconds to see whether it worked, and only then another
- two refusals of the same spell inside six seconds back it off for 1.5s,
  doubling to a ceiling of 4s; a success clears it. Only refusals of things
  WE sent count — a key you pressed by hand that fails holds nothing back

The rotation asks the same memory before each press (`R.gate`), for two
bounded things only: a spell a reaction pressed under a second ago, and
Hunter's Mark while the target is flapping between two mobs — the mark stays
on the one it is on until the target settles. The back-off is for reactions
only (1.35.2): the rotation checks range itself and retries a refused press on
the next frame it is ready, so holding its own spells back only cost shots. A
press the memory knows nothing about always goes through.

### Two lines for everything

| Situation | On at | Off again at |
|---|---|---|
| Low health | the defensive line (35%, or tuned) | 15 points above it |
| Critical health | the critical line (25%, or tuned) | 15 points above it |
| Pet low | the pet heal line (20%, or tuned) | 25 points above it |
| Mana low | the critical mana line | 15 points above it |
| Threat warning / critical | 70% / 90% | 60% / 80% |
| Danger high / extreme | 55 / 80 | 35 / 60 |
| Hardcore bail-out | the bail-out line (20%) | 15 points above it |

The mode adds time on top: trouble is acted on the frame it is seen, but
leaving it needs the situation to have stayed better for a second and a half
(three seconds out of RECOVERY), and the way down from EMERGENCY or ESCAPE
passes through RECOVERY. Health hovering around a line does not flip anything.

**A line that moves cannot flip it either.** Auto-tuned lines move — the pet
heal line follows how fast the pet is losing health, anywhere from 10% up to
the slider — so the exit line is fixed at the moment a situation turns on and
can only move further away while it stays on. The first live log had the pet
"low" at 49% and "fine" at 35% a second later, four edges in four seconds, and
a second Mend Pet four seconds after the first; a dip now ends where it was
going to end when it began.

**And a cast the engine sends is not pressed over.** Between sending a spell
and the client showing it on the cast bar there is a round trip in which the
character reads as idle. The rotation used to press into it and cut a Mend Pet
off before it started. Now the priority walk waits until the cast or channel
shows, the client confirms or refuses it, or a grace of at most 0.8s runs out
(the readout's header says *waiting for Mend Pet to start*). A refused or
interrupted action also releases the event it was answering, so the next try
is not held for the full handled time.

### Prediction

- **Interrupts by time left**: a dangerous cast is kicked when it is seen; a
  harmless one is left until its last two seconds, so the interrupt is ready
  for the heal that follows it.
- **Threat before it pulls**: threat is sampled for its rate, and a figure
  that will reach 100 within a second and a half is dropped now.
- **Defensives before the hit**: a dangerous cast aimed at you with two
  seconds left, a spike (15% gone in a second and a half), or health on course
  for the line within two seconds.
- **The pet before the line**: a pet falling fast enough to cross it within
  2.5 seconds is healed now.
- **Potions before the line**: health heading under the potion line in two
  seconds is treated as under it.
- **ESCAPE** comes from the field's measured race (FLEE), or from an emergency
  that has run out of options: nothing defensive ready, nothing in the bags,
  still being hit, health still falling.

### Safety

Before anything is sent: trained, ready, its key held if it is key-gated, not
blocked by the catalogue (moving for a channel, the pet not on the target,
the debuff already up), in range, not already handled, not just refused, not
talking over a reaction of ours that scored higher and is still casting. And
the target is the right KIND: an enemy spell with no enemy target is refused
(`ctx.cast` would otherwise send it at yourself), a self-only spell is never
aimed at an enemy, and the catalogue's range is checked against both.
Offensive reactions wait while holding fire and during a hardcore bail-out.
Crowd control still waits to be asked in a group: it fires on its own only
solo, and otherwise only while the crowd-control key is held.

### Reading a decision

The bottom of the Rotation page:

```
Reactions: DEFENSIVE + BOSS   (2.1s: low health (31%))   danger 62
  danger: health 31% +28, falling 6%/s +15, 5s to live +17, 2 on you +8
Selected: Kick -> Defias Pillager   score 174   [Interrupt]
    +90 base: Interrupt
    +40 dangerous cast (Greater Heal)
    +25 cast ends in 0.8s
    +9 boss caster
    +10 context BOSS
Other candidates: Mend Pet 65 (outscored), Evasion 98, Sinister Strike 40 (rotation)
  rejected Evasion (98): Evasion 2.0s ago, holding before another
Memory: tried Kick 0.0s ago | ok Sinister Strike 1.2s ago | failed -
  2 event(s) handled: Interrupt: Kick; Heal the pet: Mend Pet   target changes 0 in 6s
```

The Debug page keeps the history — every state change, every reaction sent
with its score, every refusal and why, bail-out start and end, retries held
back — and **Log every decision and every refusal** mirrors all of it into the
log. **Show the decision on screen** draws a short version of it — mode,
choice, top reasons, runners-up, last refusal — in a window titled
*Reactions* that drags by its title bar and is remembered where you leave it
(double-click the title to fold it). It opens on the right-hand side, clear of
the threat panel and the low-health banner.

### Adding a reaction

A reaction is a table handed to `P.react.add_rule` (JCore's `ctx.react`
underneath, 1.8.0: the same shape works in any plugin); nothing in the engine
changes. The simple shape:

```lua
P.react.add_rule({
    name = "Interrupt Dangerous Cast",
    category = "interrupt", priority = 90,
    condition = function(W)
        return W.target.casting and W.target.cast.interruptible
            and W.target.cast.danger >= 25
    end,
    action = "Counter Shot",           -- or a list: the first ready one is used
    target = "enemy",                  -- "self", "pet", or a function(W)
    retry = { hold = 2 },
    score = function(W, c)
        if W.target.cast.remaining < 1 then c:add(20, "cast ends soon") end
    end,
})
```

The full shape (`propose`, offering one candidate per answer with an event
key) is documented at the top of `rules/core.lua`, which has a dozen worked
examples. A class's own reactions go in `rules/<class key>.lua` (listed in
`CLASS_RULE_FILES` in `init.lua`), or in a class module's `reactions(R, P,
lib)` hook. `P.react.remove_rule(name)` and `P.react.set_enabled(name, on)`
take one out. A rule that needs a player's say has an `enabled` function;
since 1.32.0 the only ones are *Enable hardcore utilities* (the bail-out and
the hearthstone) and *Hearthstone as a last resort*.

### Your own reactions: the Reactions tab (1.76.0)

The **Reactions** page has no switch since 2026-10-11: the reactions are
automatic (the 1.8.0 *Use reactions in the rotation* switch, under which the
rotation ran by itself, is gone, and a value saved for it changes nothing);
the PvP reactions and the intelligence wake when PvP is detected (a player
targeted or on you, an enemy player within 40 yd, a player's control on you,
a battleground, an arena, a duel). The **Open Reactions UI** button that opened the window
below left the page on 2026-10-11: the window is kept in the code
(`P.reactwin.open(tab)`) and rendered, out of the player's reach, for a
later day. What follows describes it as it is.

**The window** (`modules/reactwin.lua`, laid out anew in 1.77.0). Move it
by its title bar and resize it by its bottom-right corner; it keeps its
place and size, and is never bigger than the screen. On the left, a
sidebar that stays put: your class, the master switch (click to turn every
reaction on or off), where you are, whether the fight picture is live, the
five views with a line each, and *+ New reaction*. On the right, the view:
its title bar and tools stay at the top, and the body under them scrolls
(the wheel, drag the bar, or press on the track). Each view keeps its own
place. A code box under the cursor takes the wheel before the page does.

**Text size (1.78.1).** *A-* / *A+* in the sidebar set the window's text
size, 90% to 200% (125% to start), on top of JCore's *UI scale*. Everything
in the window grows with it (boxes, rows, buttons, spacing), the window
itself grows and shrinks by the same step, and the size is kept between
sessions. Secondary text is a step brighter than the theme's, nothing is
10 px, and the background is solid.

| View | What it is for |
|---|---|
| Built-in | Every built-in reaction your class can have, by category: a switch for the **Open world** and one for **Dungeons** (1.78.0), what it does, how often it went out, and *Where* else it may act. Kept per class. The top shows both places and which one you are in; *Reset open world*, *Reset dungeons*, *Reset everything*. A category's strip folds it away (*Collapse all* / *Expand all*); a search opens every category it finds something in. |
| My reactions | The **Dungeon** and **Open world** starter packs (1.78.0), then your class's own, as cards: each says in words what it is doing or what stops it (1.79.0). A search, a filter, *All on* / *All off*, *Paste*. Create one blank or from a template; On, Edit, As Lua (opens it on its code), Up/Down, Copy, Share (to the clipboard), Delete. |
| Editor | Six steps as tabs: **1 Basics** (name, importance, priority, wait, combat, global cooldown, at most per fight, an alert or a sound when it goes, the whole reaction at a glance, *Right now*, *Latest fires*), **2 When** (conditions, all or any; *Hold for* on any), **3 Do this** (actions in order: the first spell, item or pet order that can go is sent; alerts, target switches and Stop my cast go at once), **4 Where**, **5 As code**, **6 Try it** (the test bench). Save, Save and close, Revert and Close stay in view under every step, with *Saved*, *Unsaved changes* or what to look at. |
| Library | Your class's shared Lua. Its functions are callable from every Lua row and pickable in the GUI. The reference of what code can read and call folds open under it. |
| Live | Where you are, the fight's mode, the danger and the mobs as tiles; what each of your reactions is doing or what stops it, every fire of yours this session, what went out last, the journal. |
| Import (1.77.2) | Someone's reactions from a GitHub link, picked from a preview; and yours exported to files to share. Listed under My reactions in the sidebar. |

**Dungeons and the open world (1.78.0).** Two halves.
- **The built-in reactions, set up for each place.** Each row has an *Open world* switch and a *Dungeon* switch; raids, battlegrounds, arenas, open world PvP and which dungeon stay under its *Where*. Most built-ins already tell a group from solo by themselves, so they come on everywhere. Three come off in dungeons and raids (custom_data's `DEFAULT_PLACES`), because each pulls mobs off the tank: *Pet: taunt* (the pet's autocast then follows its mode, and Assist keeps Growl off in an instance), *Pet: Thunderstomp*, and *Intimidation: give the pet its mob back*. A row you set otherwise is marked *changed*. Only what differs from how a reaction comes is saved (`defaults[name] = { off, env }`), so a reset drops it. One switched off before 1.78.0 shows both columns off.
- **Starter packs** (`modules/react/packs.lua`): a Dungeon pack and an Open world pack for every class. Each reaction answers something the built-ins do not watch: a death in the group, a healer gone, threat on one mob, an enraged mob, several mobs on you, a player in melee. *Add* puts one in My reactions, switched on, its Where set to its place; *Add the pack* adds every one you can use now. One whose spell you lack waits, marked *Needs a spell*. Once added it is yours (`source = { pack, item }`), and it is not added twice while you keep it. "The tank is dead" and "no healer is standing" also need a group member dead: a group with no roles set has no tank to read. GUI rows only.

**Why not, history, Try it, and more to react to and do (1.79.0).**
- **Why not** (`custom.why`): one line on what a reaction is doing, or the first thing in its way, in the order the engine meets them: the master switch, its own switch, Where, *At most per fight*, the rotation not running, *Only in combat*, its wait, the first condition that does not hold (in words, with what it read, or how long it must still hold), then what the engine made of it (`custom.after_decide` keeps each reaction's latest `outcome`: going out, outscored and by what, refused and why, below the rotation, already answered). Shown on the cards, in step 1 and in Live, coloured by its tone (going, held up, not here, broken, nothing to judge).
- **History** (`custom.history`): the latest 15 fires of each, with what went out, on whom, your health, where, and each condition's reading; counts this session and this fight (the count starts over when a fight starts or ends; a fire on the fight's first tick counts for that fight).
- **Try it** (`custom.bench`): the draft against a made-up picture (`bench_world`): a ready-made situation (custom_data's `BENCH_PRESETS`), or the fight as it is now (`situation_now`), changed field by field. The function set reads the made-up picture (where, buffs, debuffs, items, a key held included), so GUI rows and Lua alike answer from it. Spells and items are checked against your real spellbook and bags; nothing is cast or shown.
- **Hold for** (a row's `for_s`): the row holds only once it has held that long; a gap of more than half a second between reads starts it over.
- **Instant actions** (*Alert on screen*, *Switch my target*, *Stop my cast*; `alert()`, `set_target()`, `stop_cast()` in Lua): they go when the conditions hold, take no lane, and never end the list; the first spell, item or pet order after them is offered as before. Each repeats no sooner than 6 s (alert), 1.5 s (target) or 1 s (stop), or the reaction's wait, while the conditions keep holding, and at once after they stopped for half a second. Alerts are drawn by their own render job (priority 207, whatever the overlay's switches), with the raid warning sound unless switched off.
- **Items by name** (*Use an item by name*, `use("Item Name")`): `hardcore.lua`'s bag scan keeps every carried and worn item by name; the engine's `named_item` kind checks it is carried, usable and off cooldown, and uses it by id.
- Reactions keep `per_fight`, `notify_alert` and `notify_sound`; GUI rows gain the `text_number` type (a name and `num`) and the `key` type (a key code). The shared format carries them all.

**Import and share (1.77.2).** `modules/react/share.lua`.
- **The link:** a public GitHub repository with a folder called **Reaction** (or Reactions, any case), that folder itself, or one `.json` file in it (a `blob` or raw link). One call to GitHub's API lists the repository; GitHub allows 60 an hour without signing in. The files come from raw.githubusercontent.com: up to 40, of 128 KB each, with one level of subfolders.
- **The preview:** every reaction found, picked to start with. Each shows its class, importance and a *Lua* mark, what it does, and what to know before importing it: spells you lack, Library functions you do not have, a name you already use, rows left out. A file that cannot be read says why.
- **Importing:** yours go into *My reactions*, another class's into that class's list. A name you already have gets a number. They arrive switched off unless you say otherwise. The author's Library is appended to yours on request, once.
- **Nothing runs on import:** a file is read as JSON and every field is checked against what the editor can make. Lua rows are kept, and run in the sandbox like your own.
- **Export** writes your class's reactions to `scripts_data/jambix_aio/share/Reaction`, one `.json` each, plus `library_<class>.lua`. Put that folder in a repository and share the link.

The format (`"format": "jambix-reaction"`, `"version": 1`) is the editor's own fields:

```json
{ "format": "jambix-reaction", "version": 1, "class": "HUNTER",
  "name": "Panic button", "importance": "survival", "priority": 100,
  "wait": 0, "combat_only": false, "off_gcd": false, "match": "all",
  "conds":   [ { "mode": "gui", "key": "me_hp", "op": "<", "value": 40 },
               { "mode": "lua", "code": "return fight.on_me >= 2" } ],
  "actions": [ { "mode": "gui", "kind": "spell", "spell": "Feign Death", "target": "self" } ],
  "env": { "world": true, "world_pvp": true, "bg": true, "arena": false,
           "dungeon": true, "raid": true, "raid_pick": "Molten Core" } }
```

- `class` may be left out: the reaction then goes to whoever imports it.
- A file may hold several reactions as `"reactions": [ ... ]`, which share the file's `class`.
- A subfolder named after a class (`Reaction/Mage/`) gives its files that class.
- `library.lua` is the author's Library for the importer's class; `library_<class>.lua` is that class's.

**One function set for the GUI and for Lua.** Each GUI condition is a Lua
expression (`custom_data.lua` names it): *My health % below 40* is
`me.hp < 40`, *Target is casting* is `target.casting`, *I have the buff Ice
Barrier* is `buff("Ice Barrier")`. The editor prints it under the row, *To
Lua* turns the row into it, and Lua calls any GUI row by its key with
`check("me_hp", "<", 40)`. What code can read and call:

| Name | What |
|---|---|
| `me` | hp, falling, ttl, power, power_pct, power_kind, combo, level, in_combat, combat_time, moving, casting, attacking, controlled, healthstone, potion, mana_potion; control_kind ("stun", "fear", "polymorph", "root"... or ""), pvp_trinket (1.81.0) |
| `target` | exists, name, hp, distance, ttd, casting, cast_name, cast_left, interruptible, on_me, on_pet, on_tank, on_healer, on_group, fleeing, elite, boss, rare, player, level_diff, creature, controlled, threat, runs, others; immune, bursting, trinket_down (a player's, 1.81.0) |
| `pet`, `group`, `fight`, `where` | the pet; the group's tank and healer, `lowest` (health %), `hurt` (under 50%); mode, danger, mobs, `within8`, `within30`, `players`, casters; kind and name of where you are |
| `check`, `ready`, `known`, `cooldown`, `buff`, `debuff`, `situation`, `place` | the GUI's functions |
| `buff_left`, `buff_stacks`, `debuff_left`, `debuff_stacks`, `has_item`, `key` | seconds left and stacks by name (`debuff_left` yours by default); an item carried; a key held (`key(0x46)`) (1.79.0) |
| `cast(spell, who)`, `use(item)`, `pet_cast(spell, who)`, `pet_attack(who)`, `hold(why)` | actions: the first one that can go is queued and sent; `use` takes an item's name too |
| `alert(text, colour, sound)`, `set_target(who)`, `stop_cast()` | instant: they go at once and never end the list (1.79.0) |
| `vars`, `now()`, `log(...)` | state kept between ticks, the clock, the log |

`who` is `"target"`, `"self"`, `"pet"`, `"caster"` (an enemy casting,
interruptible first), `"attacker"` (an enemy on you that is not your
target), `"tank"` or `"healer"`; and since 1.79.0 `"tank_target"`,
`"healer_attacker"` (an enemy on the healer), `"lowest"` (the enemy in the
fight with the least health) or `"nearest"`. A Lua condition is an expression or
statements that return; a Lua action is statements, or an expression naming
a spell (and a target).

**How it runs.** Each reaction is compiled into an engine rule named
`My: <name>`: its importance gives the category and base score (life or
death 100 down to *only when the rotation is idle* 20; 40 is the rotation),
*Only in combat* is its `needs`, *Wait between uses* its retry hold, *Off the
global cooldown* its lane, *Where* its `enabled`. The engine scores,
validates and casts it like any other. The built-in ones are switched and
placed through `engine.filter`, asked for every rule each tick.

**The sandbox.** Code gets its own globals: the function set, `math`,
`string`, `table` (copies), and the basic functions; no `core`, no files. A
loop that never ends is stopped after 200 000 instructions (a debug hook,
where the loader has the debug library; the loader's own hook is never
replaced). A row that raises fails alone, shown red with its message.

**Where.** Open world, open world PvP (a player target or the awareness
module's PvP flag), battlegrounds, arenas, dungeons, raids; and which
dungeon, raid or battleground, every Classic one by name. Matched by the
instance's name as the client says it, with aliases; by id when the name is
empty. A wing that shares its instance (Scarlet Monastery, Dire Maul,
Blackrock Spire) is one entry. An instance not listed is learned when you
enter it (the log says so) and offered from then on.

**Edit in a file.** The loader writes only under `scripts_data` and cannot
start a program. A saved reaction's Lua row, or the Library, is written to
`scripts_data/jambix_aio/reactions/<CLASS>/<id>-<row>.lua` (or
`library.lua`) and read back every 2 s while linked: save it in VS Code or
Notepad++ and it loads, with a log line.

**Stored** per class in the `reactions` store (`scripts_data/jcore/`), so
every character of the class shares them.

### More than one enemy: the plan (1.56.0)

The class's priority list knows its spells. It does not know that a second mob
has just walked in, and until 1.56.0 every choice after that moment was a
choice about one mob in a fight with two: the target score kept whatever it had
picked, area spells waited for a third mob (and counted every engaged mob,
wherever it stood), and the pet let go of its mob only once that one was nearly
dead. Now the rotation is the default and the fight decides.
`modules/react/tactics.lua` re-plans whenever the fight changes shape (an
add, a death, a sheep) and at most five times a second otherwise, and the
rotation reads the plan:

| The plan says | How | Who reads it |
|---|---|---|
| **Who dies first** | Each mob's damage on you (the combat log, by source, from its first hit; a guess from the others until it has hit) times who it is hitting (you 1, the pet ½, more when the pet is low), against the health it has left in points. The highest goes first: its damage leaves the fight soonest. A heal being cast counts half again. A hunter's damage on a mob inside the dead zone counts 0.6; a melee class's on a mob out of reach that is not coming, 0.7; anything past 40 yards, 0.3. **A mob crowd-controlled in a way damage breaks is never chosen.** A switch must be 30% more urgent than the mob you are on, and a choice stands at least 1.5s | Target selection, in combat, solo, with two or more engaged — in place of the old score. Out of combat, in a group, or with one mob, the old score as before (which now also never picks a crowd-controlled mob) |
| **Who holds what** | Solo with a pet that is above 40%: the add on you that you are not killing goes to the pet, **if the mob the pet holds will stay on it**. The pet's threat on that one does not leave with the pet, so it stays unless yours on it is close: under 60% (the client's threat percent) it stays; nearly dead or controlled it does not matter; unread, only if you have not hit it | *Pet: pick up the add* (pinned there five seconds; the assist pass then sends the pet back to your target, and the add stays on the pet by the threat it built) |
| **What an area spell reaches** | Counted where it lands: around the target for Multi-Shot, Volley, Chain Lightning, Blizzard, Flamestrike, Rain of Fire, Hurricane; around you for Arcane Explosion, Cleave, Swipe, Whirlwind, Thunder Clap, Consecration, the novas, Hellfire, the totems, Explosive Trap. Each has its own cap (Multi-Shot three, Cleave two). A mob crowd-controlled beside it, or an idle mob it would pull (solo), and it is not a candidate | The scored walk (react/adapt.lua) and the class files' area rules through `H.spread`: **two in reach is enough to be a candidate**; the scoring weighs it against the single-target spell by damage per second (per mana when mana is short), times what it hits |
| **Whether you survive it** | The race again, with each mob on you counted from its first hit instead of after your health bar shows it: your health against their damage, against the field's time to clear them. Losing it on paper (needs half of that damage measured, inside 30s of life) is **outnumbered** | The mode: DEFENSIVE at once — control and heals rise, *Crowd control an add* is allowed. Nothing defensive fires on the forecast alone |

The Rotation page shows it under the situations, and the journal says each
change ("Mottled Boar joined: 2 in the fight -- kill Defias Pillager first (40%,
on the pet)", "outnumbered: 2 on you, 10s to live against 12s to clear"):

```
Plan: 2 in the fight (Mottled Boar joined 3s ago) -- kill Defias Pillager (40%, on the pet), then Mottled Boar (100%, on you)
  pet takes Mottled Boar: your threat on Defias Pillager is 30%: it stays on the pet | race: 24s to live, 9s to clear
```

*Show the decision on screen* adds one line: "Plan: 2 up, kill Defias Pillager
first".

**The same plan on Forever (1.57.0, JCore 1.6.4).** Forever's client leaves
three of these inputs out, and JCore answers each from what it does say; the
plan never asks which client it is:

- **The damage on you** (kill order, *outnumbered*): Forever's combat log is
  Blizzard's 12.0 locked kind -- the event fires, its contents are secret to
  addon code, which is why it reaches us empty (Details treats Forever the same
  way, and BetterForeverChat's own probe calls it "the secure combat-log API").
  So JCore shares each drop in your own and the pet's health among the mobs
  attacking each. The race line says "(their damage read from your health)".
  What Blizzard offers instead is its own damage meter; JCore 1.6.6 asks it
  (once a session, then every two seconds of a fight) and says what it
  answered, but it only ever has totals -- your damage taken, each enemy's
  damage taken -- never who hit whom.
- **Crowd control** (never the focus, never inside an area spell): JCore reads
  it off the mob's debuffs and says whether damage breaks it. A stunned mob can
  still be the one to kill; a sheep never is.
- **Threat** (the pet taking the add): the client has only ever answered
  zeros. JCore proves that from a mob hitting you that "you hold nothing on",
  and then reports threat as unread instead of a 0% that would read as "safe".
  With it unread the pet takes the add only when you have not hit the mob it
  holds, or that mob is nearly dead or controlled.

The Forever line at the bottom of the Rotation page says which: "combat log
locked: ours from tooltips, theirs from your health | threat read / unread (the
client answers zeros) / not known yet | damage meter answers in combat /
nothing usable in combat / unavailable".

**In a group (1.58.0).** A damage dealer in a group with a living tank gets the
plan too, weighted the way a group kills:

| Weight | Why |
|---|---|
| The tank's target x1.6 | everyone on one mob kills it soonest |
| Skull x2.5, cross x1.8 | the marks say the order (Era; Forever's client answers no marks) |
| On the healer 1.6, on another member or you 1.3, on the tank 1.0 | the healer going down loses the pull |
| Your threat on it: down to x0.2 as it climbs, x0.1 at 95% | the mob that would leave the tank for you waits |

The damage on any member counts as that mob's (the combat log, by source, on
Era). The readout says "Plan (group):" and tags each mob ("on the tank, the
tank's target, skull"). The tank keeps its own targeting (picking up what is
loose) and so does the healer; the pet stays the tank's business (*Pet: pick
up the add* is solo only); the race is the healer's, so *outnumbered* is solo
only. A group whose tank is dead is fought as solo.

**Assist the tank (1.70.0).** The user: "in all dps classes lets add an option
to assist tank meaning his target and swaps to his targets". One switch, off by
default: *Assist the tank in a group* (Rotation page, Targeting; every class's
window, Group). On, a damage dealer in a group is on the tank's target and
follows it. `modules/assist.lua` answers two questions:

| Asked by | Answer |
|---|---|
| `targeting.better_target`, before the plan and the score (and with *Pick targets automatically* off) | The tank's target, once the tank has kept it 0.3 s (a tab through the pack is not followed mob by mob; with no target of yours, at once). In a fight, the mob you are killing is kept (1.74.0, below). Not followed: nothing, a friend, a mob crowd-controlled in a way damage breaks, somebody else's mob, one past 60 yd, and in a fight a mob not in combat yet (a tank looking at the next pack). Then the plan and the score pick as before |
| `rotation.may_engage_unit`, out of combat, after the engage key | A mob not in combat yet: **wait** (no attack, no pet, no hunter opener). In combat with the tank's target, us, the pet or a group member: **join**, though we are not in combat ourselves yet. Anything else: no say |

The tank is the group's role. Era players rarely set one, so without it the
group shows who: 3 points per mob in combat on a member, 6 for Defensive Stance,
Bear or Dire Bear Form or Righteous Fury, 4 kept by the tank found last (a mob
on a damage dealer for a moment does not move the tank; a druid out of Bear Form
between pulls stays the tank). Looked up once a second, the tank's target read
every 0.1 s, nothing at all while the switch is off. It stands aside for the
tank and the healer (group role, else a tank or healing profile), solo, and
while the tank is dead. The class window shows a line under the switch
("Assisting Tanky (group role): on Kobold Miner.", "... waiting for Tanky to
pull Kobold Miner.", "Assist: you are the healer."); the log says "assist: the
tank is ... (...)" when the tank changes. Tests: `aio_assist_test`.

**In a fight the kill is kept (1.74.0).** A log of a Forever five-man had a
warrior holding three mobs by tabbing through them for a Sunder on each, and the
hunter following every tab: a new target every one to three seconds, with a
Hunter's Mark, an Auto Shot re-arm and a fresh sting each time, and the damage
spread so thin that nothing died sooner. Now, once the fight is on, your target
stays until it dies. You go to the tank's target when:

| | |
|---|---|
| the tank has kept it 4 s (KEEP) | a real switch, not a Sunder |
| your mob died, or will not do any more (crowd-controlled, somebody else's, out of the fight, past 60 yd) | at once |
| it carries a skull (or a cross) and yours does not | after 0.3 s (Era: Forever's client answers no marks) |

A mob of yours under 35% (FINISH) is finished first whatever the tank is on.
The class window line says it: "staying on Kobold Miner until it dies (the tank
is on Kobold Tunneler, 1.5s)", "finishing Kobold Tunneler (30%) before Kobold
Geomancer"; the log says when a mob is left for the tank's ("assist: the tank
has been on X 4s: leaving Y for it"). The group plan above holds its kill the
same way: once it has one, another mob must be twice as urgent (not 1.3 times,
which the tank's own x1.6 beat on every tab) and the first held 4 s; the fight's
first pick and the solo plan are as before.

**The hunter's add (1.58.0).** A mob hitting you in melee that is not your
target is inside the dead zone: no shot lands on it, and every swing it takes
is one the pet should be taking. When the pet is not going to take it -- no
pet, the pet under 40%, or the plan says the pet's own mob would turn on you --
*Clip the add* puts Wing Clip on it (priority 72), and the kite's step out
walks you clear of it (eleven yards) while Auto Shot stays on the target. It
never steps so far that the target goes past 32 yards; it never clips a mob
already slowed or rooted; and when the pet is about to take the add, it leaves
it to the pet. Before the pet levels the same step applies to a second mob,
where the run-and-shoot otherwise stops.

And the reactions that were already there:

- **Interrupts** are weighed across the target and up to three other casters:
  the heal at the back outscores the bolt in front.
- **Surrounded** — three in melee, two once it is an emergency — is an area
  control: everything out of the fight at once. In a group it waits for the
  crowd-control key, and never next to something already controlled.
- **An add on you** is crowd-controlled (solo, or with the key held) when the
  fight is going badly, or the moment it joins.
- **Defensives** also fire when surrounded, and every score rises with each
  enemy on you; the danger level counts them, and ESCAPE weighs them.

### Mana

Mana is a race of its own: does the bar last as long as the fight? The
resource model measures both sides, so mana is restored when the bar will run
dry before the mobs do — at 30% if that is what the numbers say, not at a line.
A mana gem first (its own cooldown); a mana potion only when a healing potion
will not be wanted soon, because the two share one; nothing in the last few
seconds of a fight, when drinking afterwards is free. Mages evocate, druids
innervate and shamans drop Mana Tide in the same situation — and between pulls
a mage at 20% evocates instead of sitting down, never while something is
hitting it. Life Tap and Dark Pact stay with the warlock's rules, which pay for
them in health through the trade gate.

A reaction that **owns** a spell (`owns = { "Mend Pet" }`) is the only thing
that casts it while the engine is on: the hunter's Mend Pet rule and the pet
module's healing pass both stand aside, so there is one decision and one
lockout instead of two casting in turn.

### PvP on Classic Era (1.81.0)

A mob does the same thing every time; a player answers you. A Polymorph so a
bandage can tick, an Ice Block to wait out your cooldowns, Recklessness the
moment their healer is free, the PvP trinket the moment a stun would cost them
the fight. `modules/react/pvp.lua` reads those moves off the client once a tick
(`W.pvp`), and `modules/react/rules/pvp.lua` answers them. Every class, Era only
in what it knows (Forever is untouched: none of its classes' kits were
checked against this).

**What it reads.**

| What | From | Used for |
|---|---|---|
| What controls you | your debuffs by name (`pvp.CONTROL`), else the client's loss of control: the mechanic, seconds left, whether damage breaks it, its dispel type, whether a player put it on you | breaking it, the potion, the readout |
| Each enemy player | its auras (`pvp.ENEMY`): immune to everything (Divine Shield, Divine Protection, Ice Block), to physical (Blessing of Protection), to a mechanic (Berserker Rage, Death Wish, Recklessness, Will of the Forsaken, Fear Ward: fear; Blessing of Freedom, Free Action: roots and snares; Cat, Bear, Travel Form: Polymorph); bursting; what a purge would take; when it last used its own trinket | every rule, the rotation's usable check, the auto-target |
| Your trinkets | slots 13 and 14: Era's Insignia by item id, else the item's on-use spell (`core.quests.get_item_spell`) and its name ("Immune Fear/Polymorph/Stun") | breaking control; kept out of the burst window |
| A player who vanished | one that was on you, alive, inside 15 yards, and is gone without dying | finding it again |

**The data is the client's.** Every mechanic, dispel type and immunity was read
from the Era 1.15.9 client's own tables (SpellCategories, SpellEffect,
ItemEffect, with `tools/jcheck`), not remembered. Some of it is not what a
player would guess:

- The Insignia of the Alliance / Horde is five trinkets, by class: **Warrior,
  Hunter, Shaman** root, snare, stun; **Rogue, Warlock** charm, fear,
  polymorph; **Mage** fear, polymorph, snare; **Priest, Paladin** fear,
  polymorph, stun; **Druid** charm, fear, stun. Five-minute cooldown. Season of
  Discovery's "PvP Trinket" breaks every control (two minutes on 233728).
- **No Insignia breaks** Blind or Scatter Shot (disorient), Sap, Gouge or
  Repentance (knockout), a Freezing Trap (freeze), Wyvern Sting (sleep) or
  Death Coil (horror).
- Blind and Wyvern Sting are **poisons**; the warlock's Fear, Howl of Terror,
  Seduction, Death Coil, Polymorph, Hammer of Justice, Frost Nova and
  Entangling Roots are **Magic**; Psychic Scream and Intimidating Shout cannot
  be dispelled.
- Purgeable (Magic): Blessing of Protection, Blessing of Freedom, Power
  Infusion, Arcane Power, Combustion, Presence of Mind, Nature's Swiftness,
  Innervate, Power Word: Shield, Ice Barrier, Fear Ward, Barkskin, Rapid Fire.
  Not: Recklessness, Death Wish, Evasion, Adrenaline Rush, Blade Flurry, Cold
  Blood, Divine Shield, Ice Block, Berserker Rage, Will of the Forsaken.

**The reactions.**

| Base | Reaction | What it does |
|---|---|---|
| 92 | PvP: break the control | Out of a player's control with the cheapest thing that breaks it, and only when it is worth it (below) |
| 87 | PvP: stop the cast | A player's heal, sheep, fear or big hit with your interrupt down or out of reach: a stun, a gouge, a fear (Kidney Shot, Gouge, Blind; Concussion Blow, Intercept, Intimidating Shout; Psychic Scream; Death Coil, Howl of Terror; War Stomp). Aimed at you, make it land on nothing: Grounding Totem (any spell, its last 1.5 s), Tremor Totem (a fear, charm or sleep), Berserker Rage (a fear's last 0.8 s), Fear Ward, a druid's form against a Polymorph. One event per cast, shared with the core Interrupt |
| 82 | PvP: answer the burst | A player on you with Recklessness, Death Wish, Adrenaline Rush, Blade Flurry, Cold Blood, Rapid Fire, Arcane Power, Combustion, Power Infusion, Presence of Mind or Elemental Mastery: per class, best first, take them out for it or your own defensive. Anything they are immune to is passed over: a warrior in Recklessness gets no fear |
| 70 | PvP: off the immune target | Divine Shield or Ice Block on your target (Blessing of Protection for a warrior or a rogue): switched to an enemy something lands on, a player on you first |
| 64 | PvP: find the stealthy | A player vanished beside you: a hunter's Flare on the spot; Arcane Explosion or Frost Nova, Holy Nova, Consecration, Thunder Clap when it was in their reach; a Human's Perception when a stealthed player is suspected about (sense.lua) |
| 58 | PvP: purge | Purge (shaman), Dispel Magic (priest), the felhunter's Devour Magic (pet lane, free) on the target, else a player on you, when it carries a buff worth 8 or more |

Each is a built-in reaction with its own switch and Where in the Reactions
window, and acts only against players (`W.pvp.active`: in a battleground, a
player target, the awareness module's PvP flag, a player on you, or a control a
player put on you). A control a mob put on you (the debuff's caster says) is
never the trinket's, even with a player in sight, unless you carry the flag.

**Hold or use the trinket.** Every control is weighed before anything is
pressed, and the points are the candidate's reasons, so the readout says why:

| | Points |
|---|---|
| The control | charm 40; stun, fear, horror 30; polymorph, sleep, knockout, disorient, freeze 25; silence, disarm, root 10; snare 5. Times its seconds left over four (at most once); under a second left it is not answered at all |
| Hit through it | +20 (falling, or 5% gone in 1.5 s) |
| Your health | +15 under 50%, +30 under 30% |
| Players on you | +10 for each past the first, up to +20 |
| Damage breaks it and nothing is hitting you | −15, and −10 more for a Polymorph under 90% health (the sheep heals you) |
| A player's dangerous cast on its way to you | +15 |
| You carry the flag | +40 |
| A caster silenced, a melee disarmed | +15 |
| A root or snare: a melee whose player target is out of reach, or a caster with a player in melee | +15; +15 more when your target is getting away under 25% |

Then the cheapest thing that breaks it, in this order, goes once the points
clear its line: Blink (a stun or a root, pressed while stunned), Berserker Rage
(a fear, pressed while feared), a druid's form
(roots and snares; one it is not already in), Blessing of Freedom, the
felhunter's Devour Magic (anything Magic) — 15; Will of the Forsaken (fear,
charm, sleep), Escape Artist (roots, snares) — 15; a Living Action Potion
(stun, root, snare) — 35; **the trinket last, at the Balanced line, 40**: a
stun or a fear while you are hit (2.7 s or more left); a root or a snare on
the flag carrier; not a sheep nobody is using. (The *Use the PvP trinket*
dropdown, with its *Only to stay alive* line at 60 and *Break any control*
at 1, left the Reactions page on 2026-10-11 with the old PvP sections; the
PvP intelligence layer's cooldown economy is to own that choice.)

A cheaper breaker's line is never above the trinket's, so the trinket is never
spent while something cheaper would have gone. A control nothing you carry
breaks is said once in the journal ("Blind (disorient): nothing you have breaks
it; Insignia of the Alliance breaks charm, fear, polymorph -- waiting it out"),
and a held trinket shows in the readout's rejected lines ("held: Kidney Shot is
worth 30, the trinket needs 40 (balanced)").

**And the rest of the plugin knows.**
- **The burst window never presses a control breaker** (`burst.lua` asks
  `pvp.keeps`). Before 1.81.0 it pressed whatever trinket was worn, the
  Insignia included, and the stun that followed found it on cooldown.
- **The rotation presses nothing into an immunity** (`rotation.lua`'s usable
  check asks `pvp.blocks`): nothing into Divine Shield or Ice Block, nothing
  physical into Blessing of Protection (the spell's school, from the client),
  no fear into Berserker Rage, no sheep on a cat, no snare into Blessing of
  Freedom. The auto-target, the pet and the swing skip a player in Divine
  Shield or Ice Block, and a warrior's or a rogue's skip one in Blessing of
  Protection (`R.out_of_fight`), so the auto-target does not switch back.
- **A player's immunity is never learned for the name** (`learn.lua`): it is
  held on that one player for 4 s. A paladin who bubbled twice twelve seconds
  apart used to be "immune to Sinister Strike" for the session.
- **No potion while stunned, feared or sheeped**: the client refuses it, and
  the refusals backed the potion off for the moment the control ended.
- **Player casts that matter** count as dangerous: Mana Burn, Drain Mana,
  Aimed Shot, Soul Fire, a Hearthstone.
- **The readout** has a PvP line while one is on: `PvP: 2 player(s), 1 on you |
  stun by Kidney Shot (3.1s) | trinket Insignia of the Alliance (stun, root,
  snare) ready | target in Ice Block (7s) | target's trinket back in 212s`.
- **Your own reactions** can read it: *I am controlled by* (stun, fear,
  polymorph, ...), *My PvP trinket is ready*, *Target is immune*, *Target has a
  burst cooldown up*, *Target's PvP trinket is on its cooldown*
  (`me.control_kind`, `me.pvp_trinket`, `target.immune`, `target.bursting`,
  `target.trinket_down`).

**Not done.** Line of sight (nothing here can move you behind a pillar); a
second enemy's crowd control chained after yours (diminishing returns are not
tracked); the flag carrier as a target priority; a rogue's poisons; reading an
enemy's class to guess what it will do before it does it.

### PvP intelligence: the picture (Phase 2, 1.8.1)

The brief behind `PVP_INTEL_PLAN.md` asks for a layer that evaluates a PvP
fight the way an experienced player does: threat, cooldown economy, what the
opponent is likely to do, baits, crowd-control plans, positioning, kill
windows, team fights. Its first piece is the picture everything later reads,
`W.intel` (`modules/react/intel/state.lua`), built once a tick right after
`W.pvp` and before the situations, and kept honest in one way: every field
is one of three kinds.

| Kind | How it looks | Example |
|---|---|---|
| **Observed** | a plain field, from a documented call the client answered | `foe.dist`, `foe.class` (`get_class`), `foe.casting.name`, `me.control.name` |
| **Inferred** | `{ v, conf, why }`; a rule reads it through `intel.sure(x, threshold)` and gets nil below the threshold | `foe.inferred.role` = melee at 0.9 for a rogue, caster at 0.6 for a priest not seen healing, healer at 0.9 once it has; `me.velocity` from a position trail; the mode `duel` |
| **Unknown** | an inferred entry at confidence 0 saying which call would answer; `S.unavailable` (this client leaves it out); `S.unknown` (no client says it) | a player's specialisation; cooldowns before one is seen; on Forever the combat log by source and threat |

What it carries: you (health and its slope, power, what controls you and
whether the read was an aura with its caster or the client's own word, the
cast on your bar, your abilities by what they are for -- defensives,
escapes, controls, slows, interrupts, each known, ready or on cooldown --
position, rotation, velocity, target, focus, mouseover, the flag); the pet
(and whether its target is a player under a control that damage breaks);
each enemy player within 40 yd, nearest first, up to ten (distance,
health, whom it targets, closing and motion, the cast on its bar, the
control on it, class and form, `pvp.lua`'s immunities and bursts, whether
it faces you, and the last twelve abilities seen from it: its cast events
by unit token, its aura records, on Era the combat log's cast lines); the
group's members with role, health and distance; the ground (the class's
ranges, the target's band -- melee, the dead zone, ranged, far -- and line
of sight through `geometry.sight`, true, false or unknown, at most twice a
second); the mode (battleground or arena observed, a duel inferred from
`DUEL_REQUESTED` and one player fighting you, world PvP from any sign,
solo / party / raid) and one answer to "is this PvP" with every sign that
says so.

The Reactions page's readout gains two rows while the picture is on:

```
Intel: world_pvp (solo) | 1 player(s) in 40 yd, 1 on you | target ROGUE melee (0.90), 3 yd melee, facing you, LOS yes | you: stun 4.0s (Kidney Shot, a player's) | ready: 0/0 defensives, 1/1 escapes, 0/1 controls
Intel: 2 cast(s), 1 aura(s), 0 log line(s) seen | last cast Sprint 1.2s ago | not on Forever: combat log by source, threat, a player's mana maximum
```

Nothing acts on it yet: the later phases propose through the one reaction
engine, and Phase 13 puts the switches on this page. The budgets are at the
top of `state.lua`; the model reads nothing the reactions did not already
pay for, except the nearest four players' facing every quarter second, one
sight ray every half second, the group twice a second and the instance type
once a second. Tests: `aio_intel_state_test`, `aio_forever_class_hunter_intel_test`.

**The threat read (Stage 2).** On that picture, `intel/threat.lua` scores
how much danger is coming on detect.lua's 0..100 scale, into
`W.intel.threat`: a burst up on a player on you, a dangerous cast at you or
at an ally, a melee player about to reach you, standing inside the reach of
a control its class throws, a player on the healer, a gap closer just used,
several players on you, rooted with a melee player near, no escape ready,
dying by the field's race, under 30% and hit, a player vanished beside you.
Each indicator carries its points, the seconds until it lands, the
reliability of the read and words; urgency, health, having nothing to
answer with, and what a defensive of ours already covers scale them
(`intel/score.lua`, every weight with its reason; `intel/data.lua`, every
name and reach with where it came from). The level -- CRITICAL, HIGH,
MODERATE, LOW, INFORMATIONAL -- has two lines and a dwell, and the band's
top adds every unknown against you: missing information is never read as
safety. Your reactions read it as *PvP threat level*, *PvP threat score*,
*A dangerous cast is coming at me*, *Target used a gap closer or sprint*,
*Target has a defensive up* (`fight.threat`, `fight.threat_score`,
`fight.incoming_cast`, `target.mobility`, `target.defensive`). Test:
`aio_intel_threat_test`.

**The cooldown ledger (Stage 3).** `intel/cooldowns.lua` keeps, per enemy
player, every ability seen from it (a cast event, the buff a cooldown
leaves, on Era the combat log's line), with when it was seen, how sure, and
-- from the clients' own tables, `modules/pvp_data.lua`, generated by
`tools/jcheck/pvp_extract.js` for Era and Forever -- when it is back, a
shared category holding its sisters down and the estimate fading once the
cooldown has run out. A spell never seen is unknown, never ready. It answers
the brief's economy questions: whether a protection of yours already covers
a burst (then *PvP: answer the burst* and *Defensive cooldown* hold a second
defensive, never under critical health), the cheapest ready answer by
cooldown, and what to keep (the last control for a melee player closing,
the last defensive for a burst the ledger says is back soon). Your reactions
read it as *Target was seen using*, *Seconds until the target's ability is
back*, *A defensive of mine already covers me* (`enemy_cd_seen`,
`enemy_cd_ready_in`, `me.protected`). Test: `aio_intel_cooldowns_test`.

**The state, the move and the words (Stage 4).** `intel/states.lua` names
the moment with the brief's eighteen tactical states (DISENGAGE, ANTI_BURST,
DEFENSIVE, INTERRUPT_OPPORTUNITY, CONTROL_DISTANCE, RESET_FIGHT,
CROWD_CONTROL_SETUP, PROTECT_ALLY, PEEL_ENEMY, KILL_WINDOW, COUNTER_ATTACK,
OBJECTIVE_CONTROL, OPENING, SUSTAINED_PRESSURE, RANGED_PRESSURE,
RESOURCE_RECOVERY, PREPARATION, BAIT_OPPONENT), each with its actions, what
to avoid, what to keep, its rank and its confidence; an emergency takes over
at once, anything else waits 0.8 s while the state in force still holds.
`intel/position.lua` says where a hunter should stand -- hold, increase,
reduce, regain or keep out of sight, stay near the allies, avoid the
reinforcements, do not pursue -- with the direction, the yards and the
reason: slow an unslowed melee player before running, step out once it is
slowed, keep out of a warrior's 8-25 yd Charge and Intercept band unless the
ledger says Intercept is down, wait for Auto Shot's aim. Nothing in it moves
you. The one reaction the layer presses so far is the aspect for the moment
(Monkey with a melee player on you), through the Aspects window's own
switch. `intel/explain.lua` keeps the tick's summary for the readout's third
row and says each new state or move once on screen (`intel_alerts`). Your
reactions read *PvP tactical state*, *PvP move advice*, *My target is inside
my minimum ranged distance*, *A safe escape is available* (`fight.tactic`,
`fight.advice`, `me.dead_zone`, `me.safe_escape`). Test:
`aio_intel_tactics_test`.

**On the page and in the window (Stage 5).** The Reactions page's
*Advanced PvP Intelligence* section holds the layer's emergency switch, the
alerts, and one switch per module (threat, cooldowns, tactics, positioning,
kill windows, teamfight awareness; the four not built yet under advanced,
each naming its stage); a module off reads calm. The Reactions window's
Try-it bench has a *PVP INTELLIGENCE* group whose fields build a made-up
picture, so every intel condition can be tried without a fight (the
situation *PvP: a warrior bursting on me* has them set), and *From the
fight now* copies the live one; its Live view shows the state, the threat,
the next action and the move as tiles, with their reasons, the abilities
seen from the target, what was kept back and what is unknown. Three more
conditions: *A kill window on my target*, *Seconds left on the control on my
target*, *My pet is on a player held by a control that damage breaks*
(`fight.kill_window`, `target.cc_left`, `pet.breaks_cc`). Test:
`aio_intel_window_test`.

**The control plan (Stage 6, `react/intel/ccplan.lua`).** Every control on
every enemy player: its name, kind and seconds left; whose it is (the aura's
caster, "yours" at 0.6 when the list carries none, "not yours" when another
unit's); what the player could break it with (its trinket as seen used, its
class's breakers as the ledger saw them); who of ours would break it (the pet
on it, a sting or a fire trap of ours ticking); what keeping it is worth, in
the order a fight asks (survive, stop_heal, stop_burst, kill, peel, distance,
reset, none); the trap to follow a Scatter Shot. Diminishing returns are
counted per category from the aura events and the row read: on Classic Era
by DRList's list and rule (full, half, quarter, immune; 18 s from the end of
the last), on Forever by the client's own `DiminishType` column with the
multiplier UNKNOWN -- nothing there claims a halved duration. The hunter's
trap rules ask it (Era's "immune" holds the trap back). One reaction, *Intel:
keep the control on your target*: a hold on the rotation's presses while a
breakable control with a global cooldown left is worth keeping, or the trap
could follow; none with a tick of ours on it. The pet's recall is pet.lua's;
the plan says why. `pvphunter.held` checks the caster: another hunter's trap
is not ours. Conditions: *The control on my target is worth keeping for*,
*Diminishing returns: what my next control on the target gets*, *The
control on my target is mine* (`target.cc_value`, `target.dr_next`,
`target.cc_ours`). Switch: *Crowd control planning*. Test:
`aio_intel_ccplan_test`.

**Opponent prediction (Stage 7, `react/intel/predict.lua`; reworked on
review 2026-10-12).** What each player tends to do, counted per player this
session. Every pattern is a question with a chance, a hit, a miss and an
attribution (`data.lua` `PATTERNS` spells them out): closes the gap when
slowed, a defensive at about N% health (an episode under 60%: it pops one or
falls under 15% without), saves cooldowns until low, interrupts your casts
(observed when an interrupt was seen cast, inferred at half weight else;
an Aimed Shot let through is the miss), escapes control at once, stacks
bursts, goes for your pet, the same opener, backs off under pressure;
chasing through bad terrain is listed as not built. A chance the player
could not answer -- its ability seen down by the ledger, its class without
it -- is skipped and said; a miss is recorded only once the input it rests
on (enemy casts, auras, our interrupted casts, its target, its movement)
was seen live this session, else the chance is unverified (the Live view's
*Inputs* line says what has been seen). Two numbers: the rate `p` (blended
with a prior that weighs two chances, so one sighting reads 0.67 and is
never a prediction) and the evidence `reliability` (two chances read 0.5,
LOW whatever the rate; moderate from about three, high from six). Two
clocks: this fight with the player (a 60 s half-life) and the session (600
s); when they disagree by 0.35 the player is *adapting*, the prediction is
withdrawn and the baits stand down. Every forecast is scored when made,
weak ones too (a Brier score and bands per pattern), never rewritten; a
sure one that fails lowers the prior. A zone change forgets the player;
nothing is persisted. Each prediction carries its consequence, the hunter's
response and a fallback, and reaches the third intel row, the Live view's
*Predict* lines, one banner per player and pattern (rate, reliability and
count), and the window: *Target's surest pattern this session*, its rate %
and the evidence behind it % (`target.pattern`, `target.pattern_conf`,
`target.pattern_reliability`), and `prediction_confidence("...")` /
`prediction_reliability("...")` in Lua. Switches: *Opponent prediction*,
*Opponent pattern learning*. Test: `aio_intel_predict_test`.

**Bait detection (Stage 8, `react/intel/bait.lua`).** The first stage to
act on a prediction, through `intel.sure` only, with the counter ready and
never while the threat is HIGH. Four baits on the target: *mobility* (it
closes when slowed and is not on you: Concussive Shot with the trap, Scatter
Shot or the clip ready), *defensive* (your burst held while its defensive is
unseen, or while it is within 15% of the health the predictor says it pops
at; said for the burst's gate, advice until it reads it), *interrupt* (it
interrupts your casts and its interrupt reaches you: show Aimed Shot and
stop it -- advice, nothing is cancelled here), *trinket* (it breaks a
control at once: Concussive Shot first, the trap after, the threat at most
MODERATE). Gates: you not controlled, no control of yours being kept on it,
its defensive not up. One reaction, *Intel: the bait*, presses the Concussive
Shot a mobility or a trinket bait asks for, under the survival and escape
bands, once per player per 10 to 15 s. The third intel row, the Live view's
*Bait* line and the condition *PvP bait on my target* (`fight.bait`) carry
it. Switch: *Cooldown baiting*. Test: `aio_intel_bait_test`.

**Fight debriefs (`react/intel/debrief.lua`).** Each fight with a player,
from its first tick to its end (won, lost, fled, reset, draw): who was in
it, what each side used, the controls on you, your lows, the threat's
peak, the states, the baits, the holds, the moments; and the lessons --
what stayed ready that could have turned it (a defensive through danger, a
slow never cast, the trap never laid, a kill window that got away, your
own control broken by your hit, a cast not stopped), what beat you, what
held, the forecasts' score -- each naming the seconds and the names it
rests on. The log, a banner, the Reactions page's *Fight debriefs and the
shared network* section, and `scripts_data/jambix.aio.fights.json` (the
last 50, your own file). Test: `aio_intel_debrief_test`.

**Decision episodes (`react/intel/episodes.lua`; `CENTRAL_NETWORK.md`
§10).** A bounded window round each tactical moment (a charge, a rogue's
opener, a Blink, a burst, a root under pressure, the dead zone, the pet on
a control, a kill window, a defence changing, several on you) with the
state before and after, the prediction and the recommendation as they
stood, what you did, and three outcomes by written rule: the prediction's
(hit, miss, censored, invalid, none), the recommendation's (followed, not
followed, unknown, with the reason) and the result (survival improved,
position improved, control successful, damage opportunity created,
cooldown saved, objective progress, situation worsened, no measurable
change, unknown). Duplicates, inferred triggers, missing feeds, cut windows
and test data are flagged and never counted as lessons. Each fight's
summary and candidate lessons (confidence from comparable episodes, never
from one) are on the page and travel in the batch. Switch: *Decision
episodes*. Test: `aio_intel_episodes_test`.

**The shared network (`react/intel/central.lua`; `CENTRAL_NETWORK.md`).**
Off until you turn it on: *Contribute my fights* queues each fight's
forecast observations and lesson, stripped of every name, under a random
identifier, and sends them between frames with backoff (never in a combat
tick's way); *Download the network's learning* fetches the published
model (a manifest with schema and plugin range; a withdrawn version is
dropped) whose reliable entries seed a new opponent's prior in the
predictor; two buttons delete the queue or ask for your records' deletion
and replace the identifier. The service is the GitHub repository itself
(issues filed by an Action into a data branch, the model read off it) or
`tools/fightlog_server`. What the service learns is per game and per
learning group (your class and theirs, your level bracket, the encounter,
1v1 or outnumbered, down to the class and the game alone); a new
opponent's prior comes from the narrowest group with a reliable rate, and
the reason names it. A model reaches you only after release gates on
fights it never saw, the first versions as a canary to a share of
players; its tactical findings show as associations, never as rules
(`CENTRAL_NETWORK.md` §11). Tests: `aio_intel_central_test`, and the Node
suites under `tools/fightlog_server`.

---

## Pet control

A pet has exactly one job at a time, and the interesting question is never
"attack or not" — it is **which unit**. Three answers are genuinely different
intents, so they are a mode rather than a pile of toggles:

| Mode | Behaviour | Growl |
|---|---|---|
| **Off** | The pet is sent nowhere (it is still kept Passive, and called back when nothing is selected) | untouched |
| **Assist** | Attacks my target | **on when solo, off in a group.** Solo there is nobody else to hold a mob, and a pet without Growl loses it to the first Aimed Shot and walks it to you. In a group a pet taunting off the tank is worse than the damage it adds |
| **Tank** | Goes for whatever **nobody is holding**, not my target. That is the point: my target is already handled and something else is not | **on** |
| **Focus** | Stays on one designated unit and ignores everything, including my target changing | unchanged |

While the rotation runs, Assist (solo) and Tank hand Growl to the reaction
engine. It is off autocast and aimed at the mob that needs it, then put back
when the engine stops (1.68.0, *The pet's taunt, aimed*). In a group, Assist
Growls only a mob that is on you.

"Loose" comes from `get_threat_situation` — the client's own threat table, the
same source the tank logic uses. A pet sent at something already held is wasted.

**Always Passive (1.75.2).** The user: "should always be on Passive". In every
mode, with the rotation paused or off too, the pet's stance is kept Passive:
it attacks only what it is sent at. Aggressive and Defensive (1.75.1's choice)
are switched back. It is read off the pet bar's active PET_MODE_ button; where
the bar says nothing (Forever) it is set once per pet and after every fight.
Defensive's one useful habit is done by the plugin instead: in a fight, with
a mob selected, a pet with nothing to do (no live target of its own, nothing
it was sent at still alive) is sent at a mob hitting it, else at the nearest
one hitting you, never at one held by breakable crowd control. An ESP-only
client is left alone.

**Nothing selected, the pet comes home (1.87.1).** The user: "If no mobs
selected all pets will come back to you as passive". With no live hostile mob
as your target (nothing, a dead one, a friend) the pet is sent at nothing: not
by the rotation, the defence above or a reaction, and no pet skill is aimed at
a mob. After a second with nothing selected (the auto-target's time to pick
the next mob after a kill), a pet still on a mob, still running at one, or
fighting more than 10 yd from you is called back with Follow; on Passive it
stays. Every mode, the rotation off too, except Focus with its unit alive.

Orders are **held, not re-issued**. `pet_attack` is a command, not a request,
and repeating it every frame makes the pet stutter in place because each order
restarts its approach.

Pet spells go through `pet_cast_target_spell`, not the player cast path — a
Felhunter's Spell Lock routed through the player's interrupt list would
silently never fire, because the player does not know that spell.

---

## Warrior rotations

### What is detected automatically

| Thing | How |
|---|---|
| Talents | The three Classic trees are walked with `get_talent_info` (on Forever, its one trait tree is split by the client's own node columns: see [Talents on Forever](#talents-on-forever-from-the-clients-own-tables-1773)). Points per tree pick the profile; individual talents change specific rules (Improved Slam gates Slam at 4 of Era's 5 ranks or both of Forever's 2, Tactical Mastery sets the stance-dance budget). |
| Abilities | Resolved by **English name** from your live spellbook, highest known rank. Train a new rank and the rotation follows on the next refresh. An ability you have not trained simply does not fire. The best rank is the highest id, except on the lines whose ids do not rise with their levels (Battle Shout, Seal of the Crusader, Consecration, Hammer of Wrath, Devotion Aura, Mark of the Wild, Inner Fire, Sap, Swipe, Holy Fire, Distracting Shot, Create Healthstone; on Forever also Trueshot Aura, Counterattack, Slam, Seal of Fury, Ice Lance, Conflagrate and others), where the level decides (1.88.1, `modules/rank_order.lua`, written from the client's own tables by `tools/jcheck/ranks_extract.js`). |
| Stances | The shapeshift bar is reconstructed from the stances you have actually trained, so index 2 means Defensive at level 12 *and* at level 40 — it is not assumed. |
| Timing | Rage, cooldown, range, stance eligibility, the Overpower dodge window and the Revenge block window all come from the client's own `is_usable_spell`. None of it is re-implemented here. |

### Auto profile selection

- Protection the largest tree (with any points in it) → **Tank Full Spec**
- Otherwise the larger of Arms and Fury decides, and the group's role decides
  which variant: the tank role picks Tank Arms or Tank Fury, anything else the
  DPS profile
- No points spent → **DPS Arms**

### Priorities

**DPS Arms** — Berserker Rage (feared), Bloodrage, Battle Shout, Charge,
Hamstring (runners), Sweeping Strikes (2+), Rend (first, with Forever's
Bloodthrill), Overpower, Execute (<20%), Victory Rush, Mortal Strike, Spearing
Strike (Forever), Whirlwind, Thunder Clap (3+), Demoralizing Shout (2+), Rend,
Sunder Armor (while the fight lasts 12 s+), Slam (with Improved Slam), then
Cleave / Heroic Strike as rage dumps.

**DPS Fury** — Berserker Rage, Bloodrage, Battle Shout, Charge/Intercept,
Hamstring, Execute, Victory Rush, Bloodthirst, Whirlwind, Rampage, Overpower,
Rend, Sunder, dumps. Death Wish and Recklessness are not in the list: the burst
window fires them (see *Bursting*).

**Tanks** — Berserker Rage, Bloodrage, Battle Shout, Charge, **aggro recovery**
(Challenging Shout / Taunt / Mocking Blow), Shield Block (off-GCD), Revenge,
Victory Rush, Shield Slam, Thunder Clap (2+), Demoralizing Shout (2+), Sunder to
five stacks, the spec's main attack (Mortal Strike, or Bloodthirst for Tank
Fury), Execute, dumps. Tank Full Spec adds Concussion Blow after Execute, when
an enemy is casting or you are in trouble.

All profiles also run interrupts (Pummel / Shield Bash, whichever the current
stance allows) and defensives (Shield Wall / Last Stand) above everything else.

Two placements look arbitrary and are not:

- **Sweeping Strikes and Overpower sit above Execute.** Both are windows that
  expire — a buff on the next five swings, a five second dodge proc — while the
  execute window does not close while the target lives.
- **Shield Block is off-GCD.** As a global-cooldown rule it displaced Revenge or
  Shield Slam every time it came off cooldown, which is a straight threat loss.

**Rage is pooled for Execute.** Execute consumes *all* remaining rage, so the
off-GCD dump is blocked for the whole execute window rather than spending rage
that is about to be worth far more. There is no switch for it (retired in 1.35.x).

### Targeting and threat

| Question | How it is answered |
|---|---|
| Which target? | Scored: nearly dead first, then what is hitting you, then quest and guide targets, then closeness. Elites and world bosses are scored **down** — while levelling an elite is usually a thing to avoid. A switch margin stops it flapping between two similar targets. |
| Is this AoE? | Counts enemies **engaged with you**, not enemies nearby. Standing at the edge of an unpulled camp otherwise reads as a five-target opportunity. |
| Who is loose? | `get_threat_situation` per unit — the client's own threat table, not an inference from facing. Tanks reclaim with Challenging Shout (3+ loose), Taunt, then Mocking Blow. |

Aggro recovery and the opener are gated on **where you are**, read from the
client's instance type plus group size:

| Scope setting | Reclaims aggro in |
|---|---|
| Solo only | Open world, no group |
| **Solo and open-world groups** (default) | Above, plus a world group |
| Everywhere except raids | Above, plus dungeons |
| Everywhere | Above, plus raids |

Never in PvP instances at any scope. Taunting inside an instance is a decision
with consequences for four other people, so the default leaves it alone.

### It will not pull something new mid-fight

`unit:is_in_combat()` answers "in combat with ANYONE" -- a mob fighting another
player, or one something else pulled, reads as true. Target selection uses a
stricter test: the threat table first, then "is it hitting me or my pet".

The "nearest enemy" fallback is strictly an **out-of-combat opener**. In combat
the only candidates are units already fighting you, and if none is in range the
answer is no target rather than a new one.

This came from live play: running away at low health, the mob being fought
dropped out of the search range, the candidate list went empty, and the old
fallback pulled an unengaged hostile standing nearby. Auto-target also stops
entirely once the hardcore layer has decided the fight is lost -- picking a
target is the opposite of disengaging.

### Stance dancing is off by default

A stance change destroys rage above 25 (+5 per point of Tactical Mastery). While
levelling, rage is the binding constraint, so the default is to enter the
profile's stance once and stay. Turn dancing on in *Cooldowns and stance* if
your Tactical Mastery is paying for it.

### Sources

Priorities follow the Classic levelling and tanking guides:

- [Icy Veins — Arms Warrior Levelling 1-60](https://www.icy-veins.com/wow-classic/arms-warrior-leveling-guide-1-60)
- [Icy Veins — Fury Warrior Levelling 1-60](https://www.icy-veins.com/wow-classic/fury-warrior-leveling-guide-1-60)
- [Icy Veins — Warrior Tank Rotation](https://www.icy-veins.com/wow-classic/warrior-tank-pve-rotation-cooldowns-abilities)
- [Wowhead — Warrior Tank Abilities and Rotation](https://www.wowhead.com/classic/guide/classes/warrior/tank-rotation-cooldowns-abilities-pve)

### Localisation

Ability lookup keys are **English spell names**. On a non-English client nothing
resolves and the rotation does nothing. The Rotation page lists every
unresolved ability, so that failure is visible rather than subtle — but it is a
real limitation, not a bug to be worked around.

---

---

## Hardcore

Each item exists because of a specific way one-life characters die.

| Cause of death | What the plugin does |
|---|---|
| Fighting on through a fight already lost | **Stops the rotation** below a health floor and runs the emergency path instead |
| Pulling while hurt | **Blocks the opener** below a health floor |
| A consumable sitting unused in the bag | Uses a **healthstone, then a healing potion** under 35% health -- or when health is on course to cross it within two seconds. Not only on hardcore characters |
| No way to break contact | **Intimidating Shout / Piercing Howl**, then Hearthstone as an opt-in last resort |
| Adds arriving unnoticed | **Warns** when the engaged count rises mid-fight |
| Drowning | **Warns** on the breath bar, which otherwise kills silently |
| Armour at zero | **Warns** on low durability |
| Not looking at the health bar | **Full-width pulsing banner** across the screen |

**Order matters and is deliberate:** Shield Wall and Last Stand fire *before*
the hardcore layer decides to disengage. A warrior at 20% with a defensive
available is not in the situation the bail-out was written for — letting the
bail-out preempt it would trade a button that wins the fight for one that runs
from it.

**The bail-out has two edges.** It starts at 20% health and ends only at 35%
(or when combat ends) — fixed lines since 1.32.0, with *Enable hardcore
utilities* as the one switch. It used to end one
percent over the line: a potion landing put the rotation back on the attack,
the next hit put it back under, and it flipped every few frames. With the
reaction engine on, the bail-out is a hold: nothing offensive goes out, while
the potions, escapes and defensives that outrank it still do. The start and
the end are both logged.

**Nothing here moves your character.** Fleeing is your decision. What the
plugin can do is buy the seconds in which that decision is possible.

---

### Automation

| Section | What it holds |
|---|---|
| Safety checks | Never while moving / mounted / casting / in combat, interact range, action pacing, retry delay |
| Automatic looting | Loot corpses, skin corpses, confirm bind-on-pickup, close a stuck loot window |
| Gathering | Gather herbs, mine ore, open containers, extra object names to show |
| Vendor and quests | **Forever only.** Sell grey items, accept quests, turn in finished quests with the reward that fits the class (see *Vendor and quests on Forever*) |

**Showing a node and gathering it are separate settings.** Enabling the Herbs
category draws herbs; it does not walk up and click them. That is
`Gathering → Gather herbs`.

**A node is worked until it is gone (1.55.3).** Each target gets three tries
before it is left alone for two minutes. Before 1.55.3 a vein's successful
swings counted as tries too, so mining stopped after two swings. Now anything a
try brings within 6 s clears its count, once per try:

- a loot window opening;
- for gathering and skinning, the player starting a cast.

The vein is mined until it disappears from the world. Two limits remain:

- **Six openings end a target anyway.** With full bags the window opens and
  nothing leaves it.
- **A short hold after each swing.** After a gathering cast finishes, the next
  press waits 1.2 s for its loot window. Without the hold it landed in between
  and got "That is already being used."

A target that never answers is still given up on after three tries. On
Forever the trace says `auto-loot: done with <name> ... after 6 openings` or
`giving up on <name> ...`. This applies to Era too, which had the same bug.

### Quests

**Apart from the ESP (1.73.0).** The user: "quests ESP and Forever ESP have
them be separate so if i dont want ESP but I want RestedXP I can have that".
The ESP page's *Enable ESP* switches off the ESP's marks only. The quest
marks, the quest paths, the quest areas (Forever), the guide's marks
(Classic), the guide panel and its waypoint line follow this page's own
switches (*Enable quest ESP*, *Enable RestedXP ESP*, *Mark what the guide
wants*), and show with the ESP off.

- With the ESP off nothing else is marked. A quest mark then leaves out the fight's extras: the cast bar, the ring under it and the line from it (the ESP page's *In a fight*). The threat panel, its arrows and the telegraphs are the ESP's. Alerts keep their own switch, as before.
- The overlay's toggle key (Z) still hides everything, the quest side included. The marks' look (Style, text size, range, each category's detail and colour) is still set on the ESP page.
- The Forever ESP page has no *Quest targets* row any more: quest marks follow *Enable quest ESP* alone. Whoever had that row off finds *Enable quest ESP* off instead, once (migration key `quest_row_1:<page>`).
- The Classic ESP page keeps its *Quest targets* and *Guide targets* rows until it moves to the icon card. *RestedXP guide only* (Classic) is unchanged: the guide and nothing else, quest marks included.
- In code: main.lua's render job calls `P.esp.render(visuals, master, quest_visuals)`. With `visuals` false, esp/init.lua draws only `quest` and `guide` entities, and `elements.begin_frame(quests_only)` and forever.lua's `read_settings(master, esp_on)` turn the fight's extras off for the frame. The HUD job (priority 200) draws the guide and the quest paths whatever *Enable ESP* says. quests.lua's `draw_quest_lines` follows `questie_on`.
- Tests: `aio_boot_quests_apart_test` (Forever, the whole plugin), 3 in `aio_esp_forever_test`, 1 in `aio_esp_marks_test`, 1 in `aio_boot_rxp_only_test` (Era).

**Quest targets.** Every mob, npc and object your quests want is marked and
**named with the quest that wants it**, plus that objective's live progress —
`Thazz'ril's Pick  1/1`. A mob that serves two quests gets a line for each, in
each quest's own colour.

The attribution comes from three places, each covering what the others cannot:

| Source | What it answers | Required? |
|---|---|---|
| Your quest log | which quests you are on, the objective text, the real x/y progress | always there |
| Questie | which npc ids belong to which quest, **which mobs drop a quest item**, and who hands the quest out or takes it back | optional |
| RestedXP | which of them the guide wants next, and which quest it is sending you to pick up | optional |

Without Questie this still works: an objective reads "Bristleback Quilboar
slain: 3/8" and that name matches the mob in front of you. Collection quests
are the ones that need the database, because "Bristleback Tusk: 2/8" never
names the boar.

**Quest objects are asked about before the name rules, not after.** A quest
pickup -- a pile of bones, a wanted poster, a crate to search -- is none of
herb, ore or container and reports no loot, so it used to be dropped from the
object pass before the quest index ever saw it. Every object in range is now
checked against the index (by id, read once, and by name), and one the quests
want is marked as a quest target whatever it is. A herb that is also a quest
target is drawn as a quest target and still gathered as a herb.

**Quest paths.** A dashed line along the ground to the nearest target of each
quest, in that quest's colour — the same colour its name is written in above
the mob it leads to. One path per quest, capped at three, so a camp of eight
quest mobs is one line rather than eight. The path is rebuilt from the target's
live position every frame, so it follows the mob rather than ending where it
was standing.

**Targets not in range.** When nothing a quest wants is on screen, its path
leads to where Questie says the nearest target *spawns*, with the quest's name
and the distance at the end of the line. A complete quest points at its turn-in
npc; a quest the guide is about to send you to pick up points at its giver.
These use whatever the path cap leaves after the live paths, and a quest with a
live target never gets one. Needs Questie.

Questie records spawns by the client's *area* id while the map API works in
UiMapIDs, and the client reports no area id at all. So the plugin seeds a table
of the classic zones and *checks it before trusting it*: the npcs on screen
answer their home zone from the same database, and a mapping is accepted only
once one of their recorded spawns, converted through it, lands within three
hundred yards of where the npc actually stands. A zone the seed does not know is
learned the same way from the map id the client is showing. The Debug page
counts verified zones and unresolved spawns; "0 zones verified" means no path
will appear until a few Questie-known npcs have been on screen for a couple of
seconds.

**A live target beats a map marker.** A guide waypoint is a *coordinate* — the
spot where the thing you want is supposed to be. That is worth a line while you
are still walking there and can see nothing. The moment the mob that drops the
item is on screen, the same line points at a patch of empty ground beside it,
so it is not drawn: the live paths take over. Turn that preference off under
Quest paths to get both.

**Not in a dungeon or raid (1.47.3).** Inside one, no quest path, spawn path
or guide waypoint line is drawn by default: in there a path runs through walls
and packs. The marks and chips on the mobs stay, and so does the guide panel.
*Draw paths in dungeons and raids* under Quest paths brings them back. A
battleground is not a dungeon.

**RestedXP.** Current step, goals, objective progress, waypoint panel, and the
current waypoint's path. The *other* stops in a step are off by default — a
step with eight stops is eight dashed lines running off to nowhere — and
capped when you turn them on.

**The guide panel is a window (1.83.0).** Drag it by its title bar (the
step), resize it from its bottom-right corner, double-click the title to fold
it away. JCore's overlay UI remembers its place, size and fold. Rows wrap to
the width, and a window shorter than its rows scrolls. With the overlay UI
switched off it is painted where the window was last left.

**Following the guide (1.7.4).** The user: "add sentinel to the Rested EXP
as an option so it now follows quests from rested exp automaticlaly and does it
for it too". One switch at the bottom of the RestedXP section, *Follow the
guide with Sentinel Navigation*, off by default. On, it walks RestedXP's
current step with Sentinel Navigation and does what the step says:

| The step | What it does |
|---|---|
| `.turnin`, `.accept` | Walks to the npc who takes the quest back or hands it out (the quest database's givers and enders, the quest marks, the step's `.target` names, else a quest giver standing on the waypoint), talks to it, and answers its windows for **the step's quests only**: the hand-in first, then the pick-up. The reward is the one the guide names; else the one Forever's quest givers would take (gear your class wears that beats what you have on, else the one that sells for most). A quest that starts or ends at an object (a wanted poster) is used instead. |
| `.complete`, `.mob` | Walks to the nearest mob the step's quests want (the quest marks for those quests, the step's `.mob` names) and pulls it: at 26 yards for a caster or a hunter, in melee for the rest. The rotation opens on it and fights; with the rotation off an attack is started and the fight is yours. A sticky step's mobs are pulled within 30 yards. The step's quest objects are walked to and used. Nothing in sight at the waypoint: the step's other stops are walked in turn until something shows. |
| `.goto` | Walks to the waypoint; RestedXP ticks the step off. |
| anything else | (a hearthstone, a flight, a trainer, an item to use) walks to the waypoint and waits, saying what the step wants, until you do it and the step changes. |

Your kills within 30 yards are walked to and looted (by auto-loot when that is
on). Four switches under it turn the talking, the pulling, the objects and the
looting off one by one; *Look for them within* (60 yards, advanced) is how far
it looks.

- **How it walks.** Sentinel Navigation, through JCore's `ctx.nav`, as the Market's mail run does. Every walk is watched: Sentinel not moving you within 6 s, no yard gained in 10 s (planned again twice), or a route it gives up, and a target within 40 yards is walked straight at instead (facing it and holding forward, with a jump and a sidestep when stuck); a farther one pauses the walk for 20 s and says why. Three walks in a row that Sentinel never moved pause it for a minute. A moving mob is planned again when it has gone 5 yards.
- **It waits**, letting go of every key and saying why, while: you are dead; in combat (the rotation fights, or you do); the rest module is eating or drinking, or you are under 60% health, before a pull; hardcore says no pull; a loot or quest window is open; Sentinel is not connected and the target is far; and for 3 s after you press W, A, S, D, Q, E, Space or an arrow key. **Steering is how you take over**: it walks on when you let go.
- **The windows it answers** are only those that open within 10 s of it talking to someone, never with Shift held, and never on Forever when *Accept quests* or *Turn in finished quests* is on (those answer their own). A detail window for a quest the step does not want is declined, an npc with nothing for the step is closed and left alone for a minute, and one that never answers three tries is left too.
- **Not on an ESP-only client** (TBC, Wrath, Mists, Retail): the switch reads off there, like every acting feature. JCore's navigation takes its own movement lease, which would get round the AIO's input lock.
- **What it does not do yet:** fly, take a flight path, use the hearthstone, train, buy, or walk back to your corpse. Those steps wait for you.
- **A stop on another continent is not walked** (1.7.6). A RestedXP waypoint is placed only when the map call puts it on your continent and its distance agrees with RestedXP's own. In game on Forever a Darkshore waypoint, read in Stormwind, had sent the walk off for 15,210 yd. Now the walk says "the guide's next stop is in Darkshore, on Kalimdor (you are in the Eastern Kingdoms): get there yourself", and nothing is drawn there.
- **The route it walks, on the ground** (1.7.6, *Draw the route it walks*, on). While it moves you, a solid line in the guide's colour runs to what it is walking to. It follows Sentinel's own path from the leg you are on, cut at *Line length*, and its label gives the distance along the route. It takes the guide line's place. Without a Sentinel path it is the ground line straight at the goal.
- The Quests page's three lines say what it is doing, whether Sentinel is connected (with its version), and what it has done (talks, accepted, handed in, pulls, objects, walks and straight walks); the Overview page has a *Guide walk* line. The trace says when a walk starts and when it gets there.
- In code: `modules/guidewalk.lua` (P.guidewalk). `rotation.may_engage_unit` returns true for `guidewalk.pulling(target)` (only once it stands in range), and out of combat `targeting.better_target` takes `guidewalk.pull_target()`. `quests.lua` reads RestedXP while the walk is on with *Enable RestedXP ESP* off too (`is_guide_target` still follows that switch; `guide_goal` does not), and has `quest_people(id)` and `quest_name(id)`. The reward choice moved, unchanged, from `forever_npc.lua` to `modules/rewards.lua`. main.lua: `rxp_follow` in `ESP_ONLY_OFF`.
- Tests: `aio_guidewalk_test` (34), `aio_guidewalk_hooks_test` (3, the whole plugin as Era), `aio_guide_waypoint_test` (13: placing the waypoint, the route, the spawn seeds); `rxp_follow` joins the boot suites' acting switches.

**The RestedXP ESP acts as you walk up (1.8.1).** The user: "let's make
RestedExp ESP - Allow Quest Grab, allow the Combat System to work with it and
Turn in quests". A second switch in the RestedXP section, *Act on the guide's
marks as you walk up to them*, off by default, for playing by the ESP without
Sentinel: you move, by the guide's marks, its panel and its line, and nothing
walks you or holds a key. What it does when you get there:

| You | It |
|---|---|
| stand within 5 yards of the npc (or the object) the step's quest goes back to or comes from | talks to it and answers its windows as the walk does: the hand-in first, then the pick-up, **the step's quests only**, with the reward the guide names or the one `rewards.lua` chooses. *Pick up the step's quests* and *Hand in the step's quests* turn each half off; a half that is off is neither asked for nor answered. |
| come within pull range of a mob the step wants killed (26 yards for a caster or a hunter, melee for the rest) | hands it to the rotation: out of combat automatic targeting takes it (`guidewalk.pull_target`) and the rotation may open on it (`guidewalk.pulling`, through `rotation.may_engage_unit`). It is never selected, faced or hit by this; with the rotation off the line says to switch it on. *Let the rotation fight what the step wants killed* turns it off. Resting, low health and hardcore's no-pull hold it, as they hold the walk. |

- Nothing else: no quest object is used, nothing is looted (auto-loot does), and it never gets you off your mount (it says to). Steering never pauses it; the actions gate still waits while you move, so a quest giver you run past is not talked to until you stop.
- The guide panel's first row says what it is doing ("> walk up to Marshal McBride to hand in (12 yd)", "> Kobold Vermin in range: the rotation's to open on", "> follow the line to Northshire Abbey (80 yd)"). The Quests page's first line reads *Guide ESP:* in this mode; the Overview's *Guide walk* line is on for either switch.
- Both switches on: the walk wins; it does all of this and moves you too. Switching one for the other mid-walk stops the walk's route and lets go. Not on an ESP-only client, like the walk.
- In code: `guidewalk.lua` -- `mode()` ("walk" | "act"), `wants_of()` (which kinds this mode looks for; `talk_quest` and `scan` read it), `talk_here` (the walk's talk, by the npc) and `pull_gate` (its rest, hardcore and health checks) shared with `act_talk`, `act_fight` and `act_tick`; `wanted_ids` answers nothing for a kind whose switch is off; `M.active()`; `stats().switch`. `quests.lua` reads RestedXP while it is on and its panel shows the line. main.lua: `rxp_act` in `ESP_ONLY_OFF`.
- Tests: 7 new in `aio_guidewalk_test` (41); `aio_guidewalk_hooks_test` boots with it on; `rxp_act` joins the boot suites' acting switches.

Paths follow the ground by sampling terrain height along their length. Each
sample is accepted only if it is a plausible continuation of the one before it,
which is what stops a mark ending up on a tent roof; samples are cached per
four-yard cell, so a path costs table lookups rather than a hundred and fifty
native height queries a frame.

### Debug

Object inspector, a log dump of everything in range, a button to clear retry
and blacklist state, and a live status readout.

---

## How the automation behaves

Everything automated goes through `modules/actions.lua`. Nothing else in the
plugin calls `core.input`.

- **One interaction at a time.** The game accepts one; two features firing on
  the same frame means one is silently dropped.
- **Safety is checked immediately before the call,** not when the request was
  made. You start moving between those two points constantly.
- **Failures are counted.** A node you cannot reach or lack the skill for would
  otherwise retry forever and block everything queued behind it. After three
  attempts a target is set aside for two minutes.
- **Priority:** corpses before nodes. Loot despawns; nodes do not.
- **The toggle keybind hides the overlay but does not silence the alerts.** On
  a hardcore character the warnings are the part that protects you.

The interaction path is `use_object` for nodes and chests, `loot_object` for
corpses, `skin_object` for skinning. These are not interchangeable —
`loot_object` rejects anything that is not a unit.

---

## When something does not work

Open **Debug**. The status readout names the layer that declined, in order:
the safety gate (with the specific reason), the retry timer, the blacklist,
range, or a feature toggle. It also calls out explicitly when the master
toggle or the keybind is off, which is the usual answer.

If a node will not gather, it is almost always that its name does not match the
rules in `modules/config.lua`. Click **Dump objects in range to the log** — an
object that was not recognised is logged as `-> ignored` followed by its exact
name string in quotes. Add that name to `Gathering → Extra object names`, or to
the tables in `config.lua`.

Node detection works by name shape, not by an id list:

- **Ore** — anything ending in "Vein" or "Deposit", plus a few named
  exceptions. Covers every Classic and TBC node including the ooze-covered and
  Hakkari variants, and keeps working with custom nodes on a private server.
- **Herbs** — an explicit list, because herb names have no shared suffix.
- **Containers** — keyword match (chest, trunk, lockbox, crate, cache, …).

---

## Layout

```
jambix_aio/
  header.lua
  main.lua               boot, menu declaration, render pipeline wiring
  modules/
    config.lua           categories, node name rules, palette. Data only.
    actions.lua          safety gate + interaction queue. The only core.input caller.
    world.lua            auto-gather, auto-loot, the loot window
    esp/
      classify.lua       what a unit or object IS, cached by guid
      collect.lua        one walk -> entities, threats, corpses, nodes
      elements.lua       one drawer per mark
      panels.lua         proximity alerts, threat panel, off-screen arrows
      init.lua           the package, and the old esp_units surface
    quests.lua           quest index, quest paths, RestedXP, guide panel
    guidewalk.lua        follows RestedXP with Sentinel Navigation and does the steps (1.7.4);
                         or does them as you walk up yourself (1.8.1)
    rewards.lua          which quest reward to take; forever_npc.lua and guidewalk.lua (1.7.4)
    spellbook.lua        name -> highest known rank. No hard-coded spell ids.
    rank_order.lua       the rank lines out of id order, per client. GENERATED.
    rares_data.lua       every rare known for the Forever world, by npc id (1.7.5). GENERATED.
    questxp_data.lua     what each quest pays: QuestieDB's quest xp table (1.7.6). GENERATED.
    xpbar.lua            the two experience bars on Forever's ESP (1.7.6)
    rotation.lua         the class-agnostic priority engine
    react/               the reactions, apart from the priority walk (1.8.0), on JCore's framework
      init.lua           the picture of the fight, JCore's engine configured for the AIO,
                         the two jobs round the rotation's and its verdict, the readouts, the overlay
      world.lua          one shared world state per tick
      detect.lua         situations and the danger level (JCore's latch: two-line thresholds)
      behavior.lua       NORMAL / DEFENSIVE / EMERGENCY / ESCAPE / RECOVERY
      adapt.lua          the rotation, scored by the fight and by what each skill does
      damage.lua         what each skill deals: the combat log, the tooltip until then
      learn.lua          what the fights taught: immunities, real range edges, evading mobs
      rules/*.lua        the reactions. Data only.
      (propose, score, select, validate, execute, the memory and the journal are
       jcore/services/react.lua since 1.8.0)
    pet.lua              pet mode, designation, growl, pet spells
    rest.lua             out-of-combat food and drink
    sense.lua            stealth and PvP awareness. Decides what is TRUE.
    narrate.lua          tells the player what happened and why
    forms.lua            stances and shapeshifts
    classes/*.lua        one rule set per class. Data only.
    targeting.lua        target scoring, AoE counts, threat, instance context
    hardcore.lua         survival guardrails, emergency items, warnings
    worldlayer.lua       every world mark goes through it: lanes, budget, look, wall fade (1.89.0)
    calibration.lua      the World marks page's test pattern (1.89.0)
    aurora.lua           the aurora around you (1.86.0)
    pull.lua timers.lua party.lua beacons.lua
                         the 1.87.0 world marks
    combatrings.lua tracks.lua groupextras.lua routes.lua nodememory.lua
                         the 1.89.0 world marks
    talents.lua          Classic tree scan, spec detection, profile suggestion

    debug.lua            inspector, dump, status readout
```

Rotation modules load in dependency order: spellbook, talents, stance, warrior.

### Render pipeline

Six jobs, one frame, in priority order:

| Priority | Job |
|---|---|
| 100 | the ESP — draws units and nodes, fills the threat, corpse and node lists |
| 110 | the aurora around you |
| 111 | world marks — pull safety, fight timers, combat rings, missiles and facing, your group, group extras |
| 113 | beacons, route and services (after the ESP's node lists) |
| 114 | node memory and the bobber |
| 120 | telegraphs |
| 150 | alerts (5 Hz) — reads threats |
| 189 | the calibration pattern |
| 190 | the world layer draws every mark kept since 110 (1.89.0) |
| 200 | HUD — threat panel, guide panel, waypoint line |
| 205 | spell window — used, casting, next (`timeline.lua`) |
| 206, 207 | the class window, the Reactions window, your reactions' alerts |
| 208 | the experience bars, on Forever (`xpbar.lua`): under the ESP's switch and toggle key |
| 250 | the low-health banner |

They are co-located in one phase deliberately. A `game_object` handle is only
trustworthy for the tick that produced it, so the later jobs read lists built
*this* frame rather than last.

---

## Awareness and narration

### Stealth

Read from the aura **TYPE**, not a name list — the enum has a `STEALTH`
member, so it covers a rogue, a druid, Shadowmeld and any PvE mob alike,
including custom ones a name list would miss.

The harder case is something you *cannot* see. A stealthed rogue is not in the
object manager at all, so no aura check will ever find it. What **is**
observable is the moment it leaves: a hostile player who was 5 yards away and
is suddenly gone did not walk away in one tick. That transition is the warning
worth having. A disappearance further out is treated as a zone change and says
nothing, so it does not cry wolf.

### Narration — and the honest limit on "voice"

**There is no text-to-speech in this API.** The entire audio surface is
`core.play_sound_by_id`, which plays an existing game sound by numeric id.
There is no way to synthesise speech or play an arbitrary file from a plugin,
so spoken narration is not something I can build — only something I could
pretend to build.

What it does instead: every decision carries its **reason**, surfaced as an
on-screen notification plus a distinct sound cue per severity.

| Severity | Sound | Throttle | Example |
|---|---|---|---|
| danger | yes | **none** | "Stealth nearby — Ganker vanished 5 yards away" |
| warn | yes | 3s | "Ability skipped — Whirlwind said it was castable but never fired" |
| action | no | 2s | "Pet — sent in to grab aggro" |
| info | no | 5s | "Resting — drinking to refill mana" |

Danger is deliberately never throttled into silence: the one that matters must
not be swallowed because three others arrived first. Each severity has its own
switch, because the useful setting is "warn me about danger, stop narrating
every global cooldown". The Debug page keeps the last few lines with reasons.

"Cast Taunt" tells you nothing you could not see. "Taunt — Mob B is hitting
the healer" tells you whether the plugin was *right*. A rotation you cannot
audit is one you have to trust blindly.

### Dispel and group buffs

Dispel is driven by the aura **type** the class declares it can remove
(`MAGIC`, `CURSE`, `DISEASE`, `POISON`), so no debuff name list exists to rot.
Self first, then the lowest-health ally — a poison ticking on you is the one
that kills you, and you are the only target you can always reach.

Group buffs run **out of combat only**, one per pass, greater ranks counting as
the lesser. Mid-fight buffing trades damage for a buff that was almost
certainly already up.

Warlock Devour Magic is declared as a **pet** dispel, since the player does not
know that spell.

---

## Also handled

| Capability | Notes |
|---|---|
| **Racial abilities** | Resolved by name, so no race detection. Defensive racials (Stoneform, Will of the Forsaken, Escape Artist, War Stomp…) fire at the defensive threshold; offensive ones (Blood Fury, Berserking, Arcane Torrent, and Forever's Night Elf Elune's Light) fire with cooldowns. Whichever your race has is the one that resolves. |
| **On-use trinkets** | Both equipped slots. No item list — a stat-stick reports not-usable and is skipped, which is exactly the filter wanted. Off by default. |
| **Eat and drink** | Between pulls, under *Automation → Rest*. Drinks before eating when both are low, because mana decides how soon the next pull can happen. Found by **flag** through the shipped inventory helper, so this one works on any locale. |
| **Pet interrupts** | Through the pet's own spellbook and `pet_cast_target_spell`. For a warlock this is the *only* interrupt the class has. |

---

## Casters and the wand

Levelling a caster is a mana game, not a damage race. The guides are explicit
that a priest wins by recovering faster and sitting down less, and the wand is
what makes that possible: damage for no mana at all.

| Class | Where the wand sits |
|---|---|
| Priest | Levelling only. Shield, DoT, Mind Blast, Penance, Mind Flay while mana is above the wand line, then **wand**, Smite last |
| Warlock | Supplements the DoTs, which are the damage. Shadow Bolt is expensive filler |
| Mage | Frostbolt is the damage; the wand takes over once mana is the constraint |

Below the mana-conserve line the rotation stops spending mana and lets the wand
work. Above it, casting kills faster and is worth the mana. That line is the
same one the resource posture uses and is derived, not set -- see *Automatic
tuning* below.

**A wand is a TOGGLE.** Pressing Shoot again STOPS it. A live log showed Shoot
dispatched every few seconds for two minutes -- a wand firing almost never. It
is now guarded twice: by the client's own `is_current_spell`, and by a time
lockout that **self-calibrates** -- once an active wand has been confirmed even
once the check is known to work and the lockout shrinks, so a build where that
call does not report auto-repeat still cannot spam.

---

## Awareness: what the rotation knows before it decides

Four things feed every tick of the rotation, and none of them is a guess:

| What | Where it comes from | What the rules see |
|---|---|---|
| **Every hostile's position and motion** | the core's enemies service, one read per tick with a memory per unit | `s.enemies` nearest first; `s.target_row` with distance, closing speed, seconds until it reaches melee, activity; `s.arriving` and `s.arrives_in` for who gets here first; `s.closing`, `s.on_me`, `s.attacking` counts |
| **Every hostile's state** | the same service | each row's health and time to die, its target and whether that is you or your pet, its cast (spell, remaining, interruptible), its threat on you, any stun or fear it is under; `s.caster_row` is the soonest-finishing interruptible cast among all of them |
| **Your resources** | `modules/resources.lua`, measured rates not thresholds | `s.hp`, `s.power`, `s.posture`, `s.fight_left`, whether a health-for-mana trade is affordable |
| **What your spells do** | the skill catalogue | `s.can`: trained abilities by role -- interrupts, slows, roots, stuns, defensives, escapes, heals, dots -- and, for every rule, the needs and auras the engine enforces |

And it acts on that picture **without input**, for the rotation only -- it never
moves you:

- **Targets itself, and that is not attacking.** Auto-targeting is on by
  default. In a fight it prefers what is nearly dead, then what is hitting you,
  then quest targets, and never pulls something new. Out of a fight it selects
  whatever is *closing on you or already looking at you* first, then the
  nearest thing standing still -- but nothing offensive fires on a selected
  target until it engages you or your pet, you attack it yourself, the engage
  key is held, or "Start fights on the selected target" is on (off by
  default). That includes a hunter's opener since 1.75.0. Self buffs and heals still run; interrupts and the pet's assist
  charge wait with everything else. The readout says "holding fire" while it
  waits.
- **Interrupts what matters.** The target if it is casting, and otherwise any
  hostile in range casting something interruptible -- the healer at the back
  that was never the target.
- **Retargets when the target dies**, opens the next fight when recovered, and
  holds the pull while the resource model says the last one has not been paid
  for.
- **Reports what it sees** on the Rotation page: hostile counts by activity,
  the next arrival and when, the target's distance, motion, health and cast,
  the interruptible cast in range, and the trained abilities by role.

The master switch, "Enable rotation", stays a human decision.

## Reading the fight

A priority list that fires the same rules at one boar and at four is not a
rotation, it is a macro. And a rotation that notices trouble when health gets
low notices it about eight seconds after the moment it could have done
something about it.

`modules/field.lua` measures the only comparison that decides a fight:

```
   how long until everything on me is dead     (their health / my damage)
   how long until I am dead                    (my health / their damage)
```

**Both sides are measured, neither is assumed.** Their health is read off the
units. My damage is the rate that health is actually falling — which folds in
the pet, procs, weapon speed and everything else I could not have computed.
Their damage is the rate my own bar is falling. No spell coefficients, no gear
table, nothing that goes stale at the next level.

That produces one word for the shape of the fight and one for the plan:

| Plan | When | What changes |
|---|---|---|
| `BURN` | Winning, one target or a pack worth focusing | Normal priority list |
| `AOE` | Enough clustered targets, and the class has something that reaches them | Spread damage |
| `CONTROL` | Adds landed or more are walking in | Take the pressure off before it builds |
| `SURVIVE` | Losing the race, with time to fix it | Defensives fire — *without* waiting for a health percentage |
| `FLEE` | Losing, and not enough life left to fix it | Break contact using the class's own escape list |

### Adds are an event, not a number

A second mob arriving changes the answer to the race **instantly**, and the
health bar will not show it for several seconds. So the engaged roster is
watched for arrivals directly — a new enemy after the pull is announced, counted
and fed straight into the verdict. Hostiles *closing* on us that have not
engaged yet are tracked too, because a patrol fifteen yards out and walking in
is already part of this fight.

### Breaking contact does not require hardcore mode

The hardcore bail-out triggers on a health percentage and only exists when
hardcore utilities are on. Breaking contact triggers on the race and applies to
everyone: a level 20 character that pulled four mobs has the same problem
whether or not it can be resurrected afterwards. How much life to keep in
reserve is derived from the class's own quickest escape — its cast time, plus a
global cooldown to press it, plus a second of running.

**An escape is cast on whoever it works on.** Both escape paths, this one and
the hardcore emergency, used to cast every escape on the player. Half the
class lists are cast on the enemy: Wing Clip, Fear, Blind, Gouge, Hammer of
Justice, Frost Shock, Entangling Roots, Hibernate, Death Coil. Aimed at
yourself, the client refuses them. `helpers.escape_target` now decides. The
catalogue's range answers where it describes the ability (`"self"` is yours),
and a short name list covers the rest. An enemy escape that is out of reach
is skipped for the next one in the list.

**The bail-out says so.** Under its health line the hardcore bail-out stops
the priority walk before the watch line runs, so from the log it looked like
the rotation hanging. A fourteen-second silence mid-fight could have been
either. It now logs when it starts ("under the bail-out line") and when it
ends.

### Spreading damage is a veto, not a count

Each AoE rule keeps its own target minimum, because how many things a spell
reaches is a property of the spell — Cleave reaches two, Multi-Shot three,
Flamestrike more. What the field adds is a veto: killing one mob removes its
damage from the fight and an AoE that leaves everything standing removes none,
so against a short pack containing an elite, concentrating wins even though the
count says otherwise.

The whole read is on the Rotation page, and published as `jambix.aio.field` for
anything else that wants it.

---

## Resources: mana and health as one problem

A warlock at 30% mana and 70% health taps for mana. Now it is at 55% mana and
50% health, so it drains life to get health back, which costs mana, so it taps
again. Every individual decision read correct against its own threshold and the
character died with both bars empty.

**A threshold cannot see a spiral. A slope can.** `modules/resources.lua` keeps
a six-second history of both bars and answers the questions a percentage could
not: is health falling, how fast, and does it run out before the fight does?

It publishes one word for how much trouble the bars are in, and the class rule
lists ask that instead of inventing their own numbers:

| Posture | Meaning |
|---|---|
| `HEALTHY` | Spend freely |
| `CONSERVE` | This fight is affordable, the next one is not |
| `RECOVER` | One of the bars will not last this fight; recovery is worth a global cooldown |
| `CRITICAL` | Nothing but staying alive |

Every health-for-mana trade — Life Tap, Health Funnel — goes through one gate
that refuses for four separate reasons, where the old check tested one: the
cost takes us under the floor, health is falling fast enough that the cost plus
incoming damage empties the bar first, we are already in trouble, or mana was
never the binding constraint to begin with.

The posture and both slopes are on the Rotation page, so a rotation holding
back to recover no longer looks identical to a broken one.

---

## Bursting

Every class file used to gate its cooldowns on `s.ttd > 15` — or 20 on a mage,
or 25 on a shaman, for no reason anyone could have stated. Worse, nothing
coordinated them: Recklessness, a trinket and a racial were three independent
rules that happened to share a list, so they fired on three different ticks
across three different mobs and multiplied nothing. Bursting is the one place in
a rotation where **order and overlap are the whole point**, and no code knew it.

### When

A cooldown is only wasted if the fight would have been won anyway, or lost
anyway. So the question is never "is this mob big":

1. **Will the fight last?** Derived from the buff's own duration against the
   measured time to die — half the buff is the bar, because demanding the full
   duration means never using it while levelling. Against a pack it uses the
   time to clear *everything*, not just the current target.
2. **Would it change anything?** Three ways it can: we are losing the race and
   killing faster is the way out; there are enough enemies that clearing sooner
   means less damage taken; or the cooldown comes back before the next fight
   anyway, which makes holding it a loss rather than patience.
3. **Can we follow through?** A burst window on an empty mana bar is a buff
   ticking away over a wand.

Never while breaking contact — the escape needs those global cooldowns more
than the damage does.

**An unmeasured fight is not a long one.** The time to die reads infinite
until the mob has lost health for a moment, and the window used to take that
as "it will last". It opened on the first second of every pull, logged as an
"infs fight", including pulls that were over in ten seconds. It now waits for
a measurement, which takes a second or two of damage.

**A window that ran out counts as closed.** The twenty-second reopen guard
used to start only when a window was closed *early*, so a window that simply
expired reopened on the next second. The live log shows "burst:" six seconds
apart three times running, and each reopen was a fresh round of racial and
trinket presses. A window also no longer opens for an offensive racial when
racials are switched off, since the racial pass will never press it.

### How

Ramp first, spend second, everything inside one window. Each class declares an
ordered `burst` sequence with durations; the module fires them **off the global
cooldown lane** so they cost no damage, one per tick (a queue of six instant
buffs in a single frame is how half of them get dropped), and pulls the
trinkets and the offensive racial into the same few seconds. Nothing fires
twice inside one window.

The window is a **state**, not an instant, which is what lets the priority list
behave differently for its duration instead of each rule re-deciding. Class
rules ask `H.bursting()`.

**A class may hold the window back (1.8.1).** The module names why it would
open (`losing`, `pack` for three or more, `elite`, or `freely`: a fight long
enough, the levelling case) and asks the class's `burst_veto(s, kind,
lasting)`; a reason back keeps it shut and is the readout's reason.

### The hunter's burst (1.8.1)

The user asked when a hunter should burst in PvE and what goes in it, from the
guides. None of the Forever guides has a cooldown section yet (read
2026-10-11): wowtbc.gg's level-60 list says "Cast Rapid Fire, Bestial Wrath,
and any on-use effects" then "Cast Intimidation"; Mobalytics keeps Rapid Fire
solo for "harder encounters" because "It's going to generate a lot of threat for
you quickly, and might pull enemies off your pet", and calls it "better used in
group play or Dungeons"; Icy Veins' Classic guide stacks Rapid Fire, trinkets
and Berserking "together on pull" with a tank and says "do not give up extra
uses of a cooldown by delaying it". The user chose Mobalytics' rule.

- **What:** Rapid Fire, Bestial Wrath, Intimidation (only with the pet on the
  mob), then the offensive racial (Blood Fury, Berserking, Elune's Light) and
  the on-use trinkets. Rapid Fire, Bestial Wrath and Intimidation are pressed
  nowhere else in the PvE rotation; their rules only catch a window whose
  sequence went by before they could go. The hawks stay rotational, as in every
  guide; no guide uses a damage potion.
- **When, solo:** a harder fight only -- an elite, a rare or a boss, three or
  more mobs, a fight you are losing, or a mob that lives 20 s or more -- and
  only once the pet holds the mob (it is on the pet, or already on you), so
  Rapid Fire's threat does not pull it to you. Not the ordinary levelling mob.
- **When, with a tank:** as the module decides for everyone, freely on any
  fight long enough.
- Intimidation also stops a dangerous cast and takes a mob off you when
  Disengage cannot (see *Intimidation* in the hunter's section).

### The shape of a burst: the whole set, then fillers

A DoT in Classic **snapshots your spell power when it is applied** and ticks at
that strength for its full duration. One landed under a trinket keeps hitting
like that long after the trinket has gone, so spending those seconds on a
filler instead trades a whole duration of amplified ticks for a single
amplified cast. For Affliction that is the worst trade the spec can make.

So inside a burst window every damage-over-time spell goes on the target first,
and only then do the fillers run — including the wand, which is off the global
cooldown and would otherwise be the one thing still firing while the set goes
up.

Rules opt in by carrying `dot = true`, declared rather than inferred: a rule
predicate is a closure and there is no asking a closure what it would have
done. Only spells the character **actually knows** count as missing, so a
level 20 warlock with no Siphon Life is not waiting for one.

**And the hold is bounded.** A DoT missing because it is out of range, or the
target is immune, or a rank exists that will not land, must not keep the filler
shut for the whole window — thirty seconds of a character standing still is the
shape of every silent rotation this plugin has had. The bound is the time it
should *take*: one global cooldown per DoT still to go up, and one spare. Past
that the set is not going up, whatever the reason, and damage beats waiting.

Outside a burst window nothing is held: the priority list already puts the DoTs
above the filler, so they go up first anyway, and forcing a wait there would
only mean standing still whenever one of them happened to be unavailable.

A class whose opener is a set of DoTs also needs a **longer fight** to be worth
bursting at all, and for a different reason: those global cooldowns buy damage
that arrives later. Four DoTs is six seconds of setup, and a fight that ends in
eight has been fought almost entirely in setup. Twice the ramp is the bar.

### The silence had a cause, and it was not a gate

Chasing a test I could not make pass turned up the real one, and it was worse
than any of the gates: **an unguarded accessor on the first line of the priority
walk**.

`combat.cast_remaining` read `get_active_channel_cast_end_time` straight off the
player object. A build that does not implement it RAISES rather than answering
nil. That read happens inside `reap_pending`, which is the first statement of
the priority walk, so the error did not degrade the rotation -- it took the
whole tick with it, every tick, for as long as a channel was running. Nothing
in the log said so, because the scheduler isolates a failing job silently.

All four accessors in that function are now read through `pcall`, and the
rotation guards its own call as well. The lesson is the one this codebase keeps
relearning: `pcall(core.X.Y, ...)` indexes before it protects, and a method
read off a game object is no different -- on a build that lacks it, calling it
is an error, not a nil.

### Whose dot, and on how many things

The aura scan answered two of the three questions that matter.

**Is it on the target?** Yes — indexed once per tick off the shared sweep, matched
against *every known rank id* of the name, because a Corruption applied at rank 3
reports as rank 3 and matching only the best rank would read as missing for ever.

**Is it about to fall off?** Yes — re-applied once two seconds remain, and only if
the target will live long enough to take the ticks.

**Is it ours?** It is now. A DoT snapshots the caster who applied it, so a second
warlock's Corruption on the same mob is worth nothing to us — and reading it as
ours means never applying our own. Inside a burst window, where the whole point
is landing the set while a trinket is up, it would mean landing none of it. The
`buff` row carries a `caster` and nothing was reading it.

The filter **fails open**: an aura whose caster is missing, unreadable, or whose
object will not give up a guid counts as ours. A build that does not populate the
field therefore behaves exactly as before, rather than deciding none of our own
damage-over-time spells ever landed and re-applying all of them for ever. (This
is why `MINIMUM_CORE` stays at 1.0.0 — on an older core the extra argument is
simply dropped, which lands on the same safe behaviour.)

### Spreading

A DoT belongs on **everything in combat with us**, not only on whatever is
selected: three mobs each carrying a Corruption is three times the damage for the
same three global cooldowns, and it is the entire reason the class has
damage-over-time spells.

Rules opt in with `spread = true`. The predicate already knows how to answer
"is this worth casting on `s.target`", so the engine swaps the unit underneath it
rather than teaching every class file to iterate. **The selected target is tried
first**, so a single-target fight behaves exactly as it did; only when the
selected mob already carries the debuff does the rule look elsewhere. The burst
hold counts the set across every engaged enemy for the same reason, and its
bound grows with the count, so it stays proportionate.

**Spreading has a key of its own** (default **C**, toggle or hold). It is right
most of the time and wrong for a few seconds at a time -- next to something
somebody has sheeped, or on a pull being held together on one target -- and a
settings page is the wrong place to answer something that changes that fast.
The plain toggle stays for people who never want it, and the keybind ships
**active**, so an unbound key is never the reason spreading silently stopped.

Switching it off narrows the rotation without stopping it: the selected target
still gets the full set, and the burst hold stops counting the rest of the pack,
so the filler is not left waiting for casts that are never coming.

### Did it land?

The deadlock breaker watches whether a spell we won arbitration for was ever
*cast*. Nothing watched whether the debuff then *appeared*, and those are
different failures: a full resist, an immunity, a dispel, or a mob that died on
the travel time all produce a cast that landed nothing.

Every dispatched DoT is now checked two seconds later. A target that died or left
the sweep is not counted — that is a finished pull, not a resist. Everything else
is tallied, published as `jambix.aio.dot_missed`, and shown on the Rotation page
as `Not landing: Corruption 4/4 missed`.

**It was diagnostics, not a gate, on purpose.** Something that quietly stopped
casting a rule because "it never lands" would be one more way for the rotation to
go silent, and this plugin has had enough of those. The existing behaviour —
notice it is missing, cast it again — is already correct; what was missing was
anybody saying so.

**Since 1.74.0 a confirmed cast that never shows is a gate, out loud.** The log of
a Forever five-man had Serpent Sting on one Lesser Stone Golem every two to four
seconds: the client confirmed each cast (UNIT_SPELLCAST_SUCCEEDED) and the sting
never appeared, so every look found it missing. An immunity is said in the
combat log, which Forever does not give, so `react/learn.lua` never heard it.
`H.dot_worth_it` (every class's DoTs) now asks `H.dot_noshow`, fed by this
watch from confirmed casts only (a refused press says nothing about the mob):

| Seen | Then |
|---|---|
| one confirmed cast, not on the mob | taken as ticking for 12 s (NOSHOW_HOLD), not re-cast every upkeep |
| two on one mob, while the spell shows on other mobs this session | that mob is left alone; the log says so |
| two mobs of one name like that, none of that name took it | every mob of that name, from its first look; logged once ("never shows on Lesser Stone Golem (2 of them, each cast confirmed): left off that mob") |
| it shows on that name later | cast on it again, logged |

A spell that has shown on no mob this session is never left off: the client may
not show it at all, and then it is re-cast on its duration (12 s).

### And it keeps earning itself

A window opened on what was true a moment ago. Fights change — the mob dies,
adds arrive and the plan becomes a retreat, the mana that was going to pay for
it goes elsewhere. So an open window is re-validated every tick and closes
early when the remainder has become worthless. The bar for abandoning one is
higher than the bar for starting it, because the ramp is already spent.

---

## Recovering

*"Drink below 50%"* says when to sit down and nothing at all about when to stand
up, so a character either drinks to full every time — minutes of a session spent
watching a bar that was already enough — or stands up at the same 50% that made
it sit.

What matters is whether the **next pull** is affordable, and that is already
derived from what a cast actually costs and how long a fight actually lasts.
Recovery aims at it and stops there.

| | |
|---|---|
| **Bandage first** where health is the problem | Free, faster than food, and nothing was using it — the item was already being found in the bags for the hardcore emergency and then only ever used at death's door |
| **Drink before eating** when both are low | Mana regenerates more slowly, so it is what decides how soon the next pull can happen |
| **Hold the pull** while below the target | Pulling at half a mana bar is how a character ends up sitting down after every single mob |

---

## Automatic tuning

Every threshold used to be a slider with a number I picked. *"Life Tap needs
health above 60%."* Sixty percent of what, at what level, against what? A level
12 warlock and a level 60 warlock have nothing in common except the shape of
the bar, and a slider makes the player responsible for a guess the plugin then
blames them for.

The client knows the real numbers. `modules/auto.lua` reads them —
`get_spell_costs`, `get_spell_cast_time`, `get_spell_max_range`,
`get_base_power_regen` — and measures the rest from what is actually happening.
**Automatic tuning is the only tuning (1.33.0)**: there are no sliders behind it
any more. Where a derivation cannot answer yet (spell data loads late, and a
character that has not been hit yet has no damage history) the built-in
default is used.

| Was a slider | Is now |
|---|---|
| Critical health | The health needed to survive what is currently hitting us for as long as this fight has left |
| Critical mana | Enough for one more filler cast, at what that filler actually costs |
| Start conserving mana | The mana this fight still needs, net of regeneration |
| Never trade health below | Critical health, plus the cost of the trade, plus what lands during it |
| Life Tap's health cost | **Measured** off a real cast, since `get_spell_costs` reports mana and says nothing about a spell paid for in health |
| Target search range | The longest reach among the abilities the active profile actually uses |
| Minimum time-to-die for DoTs | How long the DoT must tick to beat casting the filler instead |
| Heal the pet below | Where the pet's health is *headed* — five seconds of life at its current rate — never above 45% solo (the pet is your tank) or 25% in a group. There is no slider since 1.32.0 |
| When to start a Drain Soul | How much of this target's bar one channel removes, from measured damage |
| How long a fight must last to be worth a cooldown | The burst buff's own duration — half of it, since demanding the whole thing means never using it |
| How far to recover before pulling again | What the next fight costs, from real spell costs and measured fight length |
| Life left in reserve to run | The class's quickest escape: its cast time, a global cooldown to press it, and a second of running. No slider since 1.32.0 |
| Stop casting filler | The mana-conserve line, so the two cannot drift apart |

The Rotation page prints what it chose and why, including the measured incoming
damage and the filler's real cost.

---

## Talents change what you do

Not just how hard it hits. `H.talent(name)` / `H.has_talent(name)` read the
live tree, so a rule can exist only when the talent is taken and a respec needs
no reload. The warlock is the clearest case:

| Talent | What it changes |
|---|---|
| **Dark Pact** | Mana from the pet at **no health cost**. Replaces Life Tap outright, and is the single best answer to the spiral above |
| **Improved Drain Soul** | A kill with Drain Soul refunds mana, which turns the execute window from a mana cost into a mana *source* |
| **Nightfall** | Procs Shadow Trance: the next Shadow Bolt is instant and castable while moving. Read by its id, 17941 (1.78.2), and cast before the damage over time |
| **Improved Drain Life** | Is what makes Drain Life an actual heal rather than a slow way to lose a fight |
| **Improved Life Tap** | A better trade, so it is worth taking slightly earlier |
| **Siphon Life** | Is itself a talent, so the rule only exists when taken |

Improved Drain Soul is worded as a flat mana refund in Vanilla and TBC and as a
burst of regeneration in a later expansion. Nothing here depends on which: the
rule is *"a kill with Drain Soul pays for itself"*, and that holds either way.

---

## The warlock, in full

Nothing on the Warlock options page is a number you have to choose any more.
Every threshold is worked out from the real mana cost of your spells, the
measured rate you are dealing and taking damage, and which talents you actually
have. The sliders remain only as the manual override, used when automatic
tuning is switched off.

### Crowd control waits to be asked

Fear never fires on its own. It waits for a key (default **V**, hold or toggle)
on the Rotation page, and **an unbound key means never** -- including on the
escape path, which would otherwise be a way for a held-back ability to fire
automatically after all.

**This is the one gate in the plugin that fails closed**, and it is deliberate.
Everywhere else an unreadable signal must not be able to silence the rotation,
because the cost of a gate stuck shut is a character standing still. Crowd
control inverts that: the cost of a fear that did not fire is an opportunity
missed, and the cost of one that fired unasked is a broken sheep, a second pack
pulled, or a group wiped.

Even with the key held, fear only ever goes on **the add** -- something engaged
with us that we are not killing. A fear on the current target would break on the
first tick of our own damage-over-time spells.

The mechanism is general: a class lists `key_gated = { ["Fear"] = "rot_fear_key" }`
and the engine checks it in the priority walk and in both escape lists. A mage
could hold Polymorph behind the same key without any new code.

### The drain tank

Source: the [noobtoboss Classic warlock levelling guide](https://noobtoboss.com/wow-classic-warlock-leveling-guide/),
which builds the whole levelling plan around one loop -- the pet tanks, every
damage-over-time spell goes up, and then Drain Life is **channelled as the
filler** while they tick. The health it returns and the mana Life Tap converts
close the circle, and, in the guide's words, "you never stop to eat or drink".

That is a different playstyle from the one this plugin had, where Drain Life
was an emergency heal and Shadow Bolt was the filler. Both now exist:

| Profile | Filler | For |
|---|---|---|
| **Levelling (drain tank)** | Drain Life, wand below the mana line | The guide's build, default |
| **Levelling (bolt)** | Shadow Bolt | A warlock not yet talented into the drains |

**The opener is the guide's order**: pet in, Corruption, Curse of Agony,
Immolate, Siphon Life, then the channel. Corruption leads because it is instant
once talented, so it is the one spell that can be up before the mob arrives --
a different reason from the old order's "longest duration first", and the
better one while levelling.

**Spreading is Corruption only** in this profile, also from the guide: *"Apply
Corruption to 2-3 enemies, then focus your other DoTs and drains on the primary
target."* Immolate and Siphon Life on a mob the pet is holding are mana spent
killing something slowly that was never the problem. The endgame Affliction
profile still multi-dots everything, which is right at 60.

**Fear goes on the add, never the target.** The guide: *"Fear dangerous enemies
when your Voidwalker loses aggro or you pull accidental adds."* Both are the
same unit -- something engaged with us that we are not killing -- and a fear on
the target would break on the first tick of our own DoTs.

Two things from the guide that are **not** implemented, and are worth knowing:

- **Pet by level** (Imp 1-10, Voidwalker 10-20, Succubus 20-60, Felhunter for
  casters). The pet module manages whatever pet is out; it does not summon or
  swap one.
- ~~Voidwalker Sacrifice~~ is done now: the reaction *Pet: Sacrifice* (see
  *The pet's skills, when they help*).

The guide also says to keep **20-30 shards**; the cap here defaults to 20, the
bottom of that range, because it is what was asked for. Raise it on the Warlock
page if you want the guide's upper end.

### The killing tick

Improved Drain Soul refunds mana when the target dies **while the channel is
running**. Miss that tick and the talent gives nothing at all, so the rotation
is built around landing it:

- **The window is measured, not chosen.** How much of *this* target's health bar
  we remove during one channel — from the measured damage rate and the target's
  actual bar. A warlock doing a fifth of a mob's health per second can start at
  nearly full; one chipping at an elite has to wait. Same character, different
  answers an hour apart, which is exactly why a slider was the wrong shape.
- **Nothing may take the kill.** Once the channel is running, every damage rule
  in the class stands down — the DoTs, the filler, and above all the wand, which
  fires off the global cooldown and is the likeliest thief.
- **There is no lower bound**, and the first version of this had one, which was
  backwards. The refund is paid for a death *during* the channel, so starting
  earlier is strictly better and there is no such thing as too close to death to
  bother. The floor also made the window about half a second wide, which the
  cast service could not hold on to: the intent was superseded by the filler on
  the next tick before the global cooldown came round. A rule true for one tick
  may as well be false.

### Soul shards

A shard is one bag slot and they do not stack, so a levelling warlock spends the
whole game watching its bags fill up. Past the cap — twenty by default, a full
small bag — every Drain Soul is costing a slot that could hold loot.

**Spending beats destroying**, and there is usually something to spend one on.
The healthstone and soulstone rules already conjure one when the bags have none,
and each eats a shard; past the cap a spare also becomes a Spellstone or a
Firestone, which are weapon enchants worth having anyway. Only what is left over
after all of that is destroyed.

**Destroying is irreversible and there is no confirmation step.** Blizzard's
"type DELETE" box belongs to the default bag UI; going straight to the engine
skips it entirely, so the guards are the only thing standing between a bug here
and somebody's bags:

- The `(bag, slot)` pair comes from `inventory_helper`, which owns the shift
  between the raw scan indices and what the destroy call expects. Passing a raw
  `slot_id` from `get_items_in_bag` destroys the item **next to** the one you
  meant — the API stub says so in as many words, and that is the whole reason
  this path does not reuse the existing bag scan.
- The name at that row is re-read and re-matched *immediately* before the call,
  so a stale row cannot name a slot that now holds something else.
- One per call, with a lockout, so no single frame can empty a bag.
- Never below the cap. Out of combat at first; since 1.73.4 one spare shard a
  fight may also go in combat, at most one every 2 s.

Every destruction is logged at warning level and published as
`jambix.aio.item_destroyed`. The whole feature has its own toggle, and the cap
is a slider rather than a derivation: how much bag space to spend on shards is a
preference, not something the fight can be read for.

### The stones

A soulstone on yourself is a free resurrection where you stand — no run back, no
durability, and on a hardcore character the difference between a bad pull and
the end of the character. The plugin was ignoring the spell entirely. It now
conjures one when the bags are empty and wears it when nothing is, both out of
combat only.

**Ranked names.** Almost every ability keeps one name across its ranks, which is
why resolving by name works at all. The conjuring spells do not:

```
Create Healthstone (Minor)    Create Soulstone (Minor)
Create Healthstone (Lesser)   Create Soulstone (Lesser)
Create Healthstone            Create Soulstone
Create Healthstone (Greater)  Create Soulstone (Greater)
```

An exact lookup for `Create Healthstone` resolves for exactly one rank out of
five. The rule using it had been in the plugin for several versions and would
have worked between levels 42 and 53 and at no other point — silently, like
every resolution failure. Rules can now be marked `prefix`, which resolves the
whole line and takes the best rank.

---

## The skill catalogue

Until this existed nothing in the plugin or the core knew what a skill *did*.
The core knows a spell's cooldown, range, cost and whether it is usable; the
rotation knows what to press because a class file says so, one rule at a time.
"Serpent Sting is a damage-over-time effect" lived only as a tag typed on a
rule, "Concussive Shot slows" only in the fact that a rule fires it at runners,
and a trained ability no rule named was invisible.

`modules/catalog/<class>.lua` is one data file per class describing every
ability: its **roles** (damage, dot, heal, slow, root, stun, fear, disorient,
sleep, silence, interrupt, dispel, cooldown, toggle, aspect, trap, pet, threat,
...), its **kind** (instant, cast, channel, toggle, trap, aura), its resource,
its range band and what it **needs** (a ranged weapon, standing, the pet on the
target, a parry just before), what it **applies** and the aura's name, what it
**does** (delivery, school, amount, ticks, what it scales with), how it works
**with** the others, and which talents change it. Then every **talent** with
its tree, tier, max rank, effect and the abilities it affects, and the
**combos** that only exist between abilities: the pull, shot weaving, the dead
zone escape, the burst window, trap chains, why stings do not stack.

`modules/catalog/init.lua` loads the right file for the character and merges it
with what is live:

```lua
P.catalog.ability("Concussive Shot")          -- the row
P.catalog.with_role("slow", true)              -- every trained slow
P.catalog.applies("Serpent Sting")             -- "Serpent Sting", "target"
P.catalog.talents_affecting("Auto Shot", true) -- taken talents, with ranks
P.catalog.combos_using("Freezing Trap")
P.catalog.coverage()                           -- trained abilities the file does not describe
```

Numbers are Classic Era at max rank, from tooltips and the levelling guides;
rows marked `approx` were recalled rather than read and want checking in game
before anything does arithmetic on them. Mana costs are absent on purpose: they
differ per rank and the client answers the real one at runtime.

**Forever (1.88.1, the hunter).** One file describes both clients. A row only
one client has says `client = "forever"` or `client = "era"`; a row both have
keeps Era's figures and lists what Forever changes in `forever = { ... }`, laid
over the row there. `init.lua` resolves both when it loads, so every reader sees
the row as a file written for that client alone would give it, and Era's rows
are exactly what they were. The hunter's Forever figures are read from that
client's own tables: the tooltips, their numbers from SpellEffect,
SpellCooldowns and SpellCastTimes, and for a talent its rank curve. Its talents
are Forever's own tree: 14 Forever-only talents (Deadly Aspects, Focused Fire,
Lone Wolf, Lethal Attacks, Sniper Shot, Predator's Edge, ...), five with other
max ranks (Improved Aspect of the Monkey 3, Improved Wing Clip 3, Improved
Stings 3, Resourcefulness 2, Careful Aim 5), and the Era and TBC talents Forever
has not, marked `era`. Abilities: Aimed Shot is trained at 20 (a 2 s cast, not a
talent), Multi-Shot has one rank and a 6 s cooldown shared with Aimed Shot, the
traps a 30 s cooldown, and Sniper Shot, Lacerate and Trickster's Dance are new.
The priority walk forecasts from `cast` and `cooldown`, so on Forever it now
times those with the client's numbers.

The **coverage line on the Debug page** names every trained ability the
catalogue does not describe. That is what keeps the data honest as a character
levels, and it is the first thing to read when a new spell seems ignored.

The catalogue **decides nothing**, but the things that decide now ask it:

- **The priority walk** enforces a row's `needs` and `applies` for every rule
  that names a described ability. A cast that needs standing is skipped while
  moving; a trap is skipped in combat; Intimidation waits for the pet to be on
  the target; a sting is not cast over another sting of yours; anything that
  puts an aura on a target, on you or on the pet is not re-cast while that aura
  has more than a moment left (dot rules keep their own refresh logic). A rule
  that knows better opts out with `ignore_catalog = true`, a deliberate
  replacement with `replace = true`, a deliberate reapply with `reapply = true`.
  A row of kind `toggle` is pressed directly, never queued, without the rule
  saying so.
- **The priority walk decides range from the catalogue** for every described
  ability with a stated reach -- a number, a band, or "ranged" (the class's
  ranged band plus two yards per rank of Hawk Eye) -- and asks the client
  about everything else with its range check skipped. The client evaluates
  range from its own per-spell range data, and where that data is missing
  its answer is "in range" only at touching distance: Hunter's Mark, which
  reaches a hundred yards, was being pressed only once the mob was in melee.
  Melee, self, pet and party abilities are still left to the client.
- **The class module** takes its interrupt, defensive and escape lists from
  the catalogue's `lists`, with the old literals as the fallback.
- **The weave** asks for the trained damage toggle that needs a ranged
  weapon, which is how it will find the right thing for the next class
  without a new special case.

Hunter is the first class described; the others follow the same schema, and
each one written turns these generic checks on for that class.

---

## The hunter, levelling

The levelling profile follows the Classic Beast Mastery levelling guide's
rotation, in its order: pet attacks; Hunter's Mark; Intimidation; Bestial
Wrath; Aimed Shot; Auto Shot; Serpent Sting; Auto Shot; Aimed Shot if fine on
mana; Multi-Shot if fine on mana; Auto Shot until the enemy is dead.

Two entries in that list are not casts, and both were missing before.

**Auto Shot is a toggle**, the wand's twin: pressing it starts auto-repeat,
pressing it again *stops* it, and no shot ability starts it for you. The old
profile never pressed it, so the hunter fired specials into the gaps of an Auto
Shot that was not running. It now goes through the same guarded press logic as
the wand -- `H.auto_repeat` in `rotation.lua`, one instance per toggle spell --
which is what stops a toggle from flickering on and off every tick, and which
self-calibrates against a client that misreports whether it is running. The
re-arm window is the wand's setting on the Rotation page.

Whether it is running is read from three sources, and any one of them saying
"running" holds the press back: the client's current-spell reading, the unit's
own auto-attack flag (Auto Shot *is* the auto attack), and the cast stream -- a
shot reported within one swing of the weapon means it is running whatever the
flags say. There is also a quiet window: a cast pauses Auto Shot without
stopping it, so no press goes out within a swing of any cast of ours. The
failure all of this guards against is the obvious one -- a press on a running
toggle *stops* it, so a single wrong "not running" is Auto Shot switching
itself off every few seconds.

The press itself is sent to the client *once*, bypassing the shared spell
queue (`direct = true` on the rule). A toggle reports no cast to confirm
against, so an entry left in the queue is a second press waiting to happen --
and a second press is the off switch.

Three things used to keep Auto Shot off for most of a fight, and each is
now handled:

- **The quiet window fired after every cast.** A cast pauses a running Auto
  Shot without stopping it, so no press goes out within a swing of a cast of
  ours -- but that used to apply whether or not Auto Shot was running. The
  rotation casts something every global cooldown, so Auto Shot was never
  started while there was anything else to do. The window now applies only
  when the toggle was seen running just before the cast.
- **The melee auto attack read as Auto Shot.** Wing Clip or Raptor Strike
  starts the melee swing, which in Classic *stops* Auto Shot, and then the
  unit's attack flag reads "attacking" for the rest of the fight. The class
  file now tells the guard what it cannot see: standing, in range, able to
  shoot, for longer than a swing, and no shot -- and once shots have been
  observed at all this session, that is believed over the flag. The weave's
  readout of the last real shot (including the swing timer addon's) feeds
  the guard, so a shot the cast stream missed still counts.
- **Presses went through the cast confirmation breaker.** A slow bow's first
  shot lands after the two-second deadline, and a press that stopped the
  toggle reports nothing, so three in a row earned Auto Shot a fifteen-second
  back-off. Toggles are no longer judged by it.

A new target also resets what the guard believed: Auto Shot stopped with
the old one, so it is pressed as soon as it is wanted rather than a swing
after the last cast.

**The press is a START, not a toggle.** The client ships an auto-attack
helper (`common/utility/auto_attack_helper`) with a start, a stop and a
toggle for each auto attack, keyed by the attack's own spell id: 75 for Auto
Shot, 5019 for a wand's Shoot, 6603 for the melee swing. JCore's cast
service now routes every direct request for one of those through the
helper's start. Already running means nothing happens, which is what makes
every wrong "not running" guess above harmless: the worst case is a start
that does nothing, never a stop. Right-clicking a mob starts your melee
swing, which cancels Auto Shot; the next start puts it back within a second.

**And then the guesswork is bypassed altogether.** The game fires
`START_AUTOREPEAT_SPELL` when Auto Shot (or a wand) starts and
`STOP_AUTOREPEAT_SPELL` when it stops, and the core relays every game event
by name. Once either has been seen in a session, the guard uses that state
and nothing else: no flags, no quiet window, no inferred staleness, just a
one-second gap between presses so a press whose START has not arrived yet
is not repeated. The log says so the first time
("auto-repeat events are relayed by this client"). Everything above remains
the fallback for a build that does not relay them.

**Kept on, because those events never come.** The core does not relay
every game event. Its callback delivers a fixed list (`.api/core.lua`, above
`register_on_game_event_callback`), and the two auto-repeat events are not on
it, so the exact path above has never run on this client. What did run was the
fallback, and it had one bad habit. A shot at the *previous* target counted as
"running", so after a kill and a switch Auto Shot stayed off for a whole
swing or more. Since the press is a START, none of that caution is needed for
Auto Shot. The hunter's guard is now `keep_on`. Every new target gets a press
at once ("Auto Shot: on for <mob> (new target)" in the log). After that, a
swing with no shot at *this* target, while standing in range, gets another
press at most every 1.5 seconds. A START on a running Auto Shot does nothing,
so a wrong guess costs nothing. Shots before the switch no longer count. The
keep-on path is used only when the client's auto-attack helper confirms Auto
Shot is one of its attacks. Otherwise the cautious toggle logic above stays.

**On Forever, one shot per press (1.48.1).** On the Forever beta the hunter
fired once and then stood there. The recorder trace (2026-10-03, a level-3
dwarf hunter, three wolves) shows it. The press went out (`cast_target_spell(75)`
from the auto-attack helper, four times in 175 seconds). The client reported
the shot at once, and the wolf lost a quarter of its health. Then nothing
came: three seconds standing in range with no second shot. The kept-on
guard's "a swing with no shot" pressed again at 3.5 s, and by then the wolf
was in melee and Raptor Strike took over. The rogue never showed this,
because every Sinister Strike restarts its melee swing. The weapon speed does
not help either: `get_unit_ranged_damage` answers all zeros there, so the
2.5 s starter-bow guess stands. So on Forever the guard is told to **re-arm**
(`rearm`, set by the hunter only when `P.forever`). Every shot seen is followed
by the next START a quarter of a second later; the rule's upkeep keeps that to
one a second. A press that has had no shot yet is waiting on the swing timer,
or was refused, and gets another START after 1.5 seconds. A START on a
running Auto Shot does nothing, so if the client does keep it going, the
extra presses cost nothing. Era passes no `rearm` and runs the kept-on path
above unchanged. Each mob's Auto Shot is summed up in the Forever trace when
the next one is taken: `hunter Auto Shot at <guid>: N presses (new target,
after a shot, retries), M shots in Ts`. Shots close to presses mean
the re-arm is doing the work. Tests: `aio_rotation_test` (the guard, Forever
and Era) and `aio_hunter_test` (the hunter asks for it on Forever only, and
writes the line).

**Why a press made no shot (1.52.0).** Session 26 still had targets with no
shot: "3 presses (1 new target, 0 after a shot, 2 retries), 0 shots in
17.4s" at a Burly Rockjaw Trogg 9.5 to 11 yards away, with nothing to say
why. The line now goes on: `; ready <s>, moving <s>, too close <s>, too
far <s>; refused <n> (quietly <n>); errors: <red text> x<n>`. It says where the time went while that mob was the target
(standing in range able to shoot, moving, inside the minimum range, too far;
gaps of a second or more between asks are not counted). It says how often
the client refused Auto Shot itself (`UNIT_SPELLCAST_FAILED` /
`_FAILED_QUIET` for spell 75; the recording has quiet refusals of 75). And
it gives the red text that came within 1.5 s of a press: the event does not
say which spell it was about, so an error there may belong to something
else. Forever only.

**Melee attack left on (1.52.0, Forever).** The press goes out through the
loader's auto-attack helper as a START (`start_attack(target, 75)`). That
helper reads the player's one attack flag, which a melee swing sets as well.
So after Raptor Strike, or after the player right-clicks the mob, a START at
range looks like "already running", and nothing is sent. In the trace that
shows as presses with no shot and nothing refused: "1 presses (1 new
target, 0 after a shot, 0 retries), 0 shots in 15.7s" after a wolf fought
in melee. Session -16 found the cause.

Now a retry press stops the melee attack first (`core.input.stop_attack`).
That happens only when all of these hold:
- the press had no shot after it, so Auto Shot is plainly not running;
- the flag still reads on;
- you are standing past the 8-yard minimum.

The START then goes through, at the latest on the next retry. A new
target's press, and the press after a shot, never stop anything: Auto Shot
sets the same flag. The line then ends `; melee attack stopped N`.
`stop_attack` had never been called on Forever, so whether it clears the
flag is for the next hunter session to show.

**Auto Shot never waits for the pet.** The wait described next is for the
threat a pet cannot out-growl. An Auto Shot's threat is its damage, a
fraction of one Growl. The first version of this skipped the wait only for a
switch mid-fight. The next log showed two to four seconds of nothing after
every pull's mark, a quarter of a twelve-second fight. Every target now gets
Auto Shot as soon as it can fire, the pull's included.

**The watch line follows Auto Shot.** The hunter's watch used to be Hunter's
Mark, from when the pull's first press was the open question. The mark has
gone out on every pull since, and Auto Shot is what matters now: one later log
still had it starting one to six seconds after the mark on some pulls, with
nothing saying why. `watch: Auto Shot ...` now reads "firing at this target"
while shots land on the target. Otherwise it gives what holds it: moving, too
close or too far (with the distances), holding fire, a cast in flight, or
"started, waiting for its first shot". A toggle's rule cannot be asked
without pressing it, so the class answers through `toggle_status`.

**The mark is the pull; the big threat waits for the pet.** Hunter's Mark goes
first, always: it carries almost no threat and it is what starts the mob
moving, so it is never held back. Solo, the pet is the tank, and a mob is on
whoever has the most threat -- so Aimed Shot and the sting wait until the
mob is actually *on the pet* before they start. One Aimed Shot
before the pet has the mob is six hundred threat the pet cannot out-growl,
and that is how a mob ends up in your face. The wait is bounded: a couple of
seconds if the pet module has not sent the pet at all, four if it was sent and
the mob has still not turned to it, and none at all once the mob is on you in
melee (then it is clipped and fought). Concussive Shot is not held back
either: dazing a mob charging you is what buys the pet the time to catch it.
In a group with its own tank nothing waits. The pet's Growl follows the same
logic -- see *Pet control*.

**A hunter opens the pull itself -- only with "Start fights" on (1.75.0).** The
user: "i shouldnt be just auto initiating fights either. Should be when I go
into Attack mode basically". With auto-targeting, the opener below pulled every
mob selected in shot range. It is now asked only while "Start fights on the
selected target" is on, as that switch's judgement for a hunter. If it says no,
the other readings still decide (you attacked it, it came for you). With the
switch off, the pull is yours: Attack, a right-click or your own Auto Shot, and the
rotation takes it from the first press (the attack flag) or the first hit (the
mob on you). The watch line then reads "waiting for you to attack it, or the
engage key". What follows is the opener as it works with the switch on.

The rotation-wide rule is that selecting
is not attacking: with "Start fights on the selected target" off (the
default), nothing fires at a mob that has not engaged you. For a hunter that
rule was the whole problem. A mob only counts as engaged once it has aggroed
by walking into its own radius, ten to fifteen yards out, and from there it
reaches melee before a mark and a three-second cast can land -- which is why
the mark seemed to go out only at melee range. So the class module declares
how it opens (`may_open`), and the engage gate asks it: a selected mob that
is not a player, not already fighting someone else, not under control, and
between eight and thirty-five yards is ours to open on, wherever the
aggro-scope setting says pulls are ours to start (never in PvP instances).
The mark goes out at thirty yards, the pet is sent the same moment, and the
shots follow once the mob is on the pet. (The Hunter option "Open on the
selected mob from range" that once turned this off is long gone; since 1.75.0
the rotation-wide switch is that choice.)

**The opener is a question of time, not of health.** Aimed Shot is a
three-second cast that is worth starting exactly when it lands before the
mob does. The rules read how long the mob needs to reach you -- from the
awareness reader's closing speed when it is charging you, from distance at
run speed when it is not yet engaged, and never when it is on the pet -- and
cast it only with that much time in hand. A mob two seconds out gets
instants instead: Concussive Shot to daze it, Arcane Shot and Serpent Sting
on the way in. Aimed Shot still appears twice in the list -- once as the
first of the fight, once as the mana-permitting filler after the sting.

**A mob that reaches you is clipped and walked away from.** Inside eight
yards nothing ranged works. Wing Clip goes on the mob that is on you (a mob
on the pet needs no clip: it will not follow), and then the kite module steps
you straight back out past eight yards -- a bounded few seconds of running,
never from an unslowed mob that keeps pace, never off a drop, never while you
hold a movement key -- and the shots resume. Raptor Strike and Mongoose Bite
are for being *stuck*, not for being close: they fire only while no step out
is running. Concussive Shot fires on a mob charging you that the pet does not
have, and on a runner; never on a mob that is running at the pet, which is
where you want it.

**Raptor Strike is pressed once per swing.** It rides the next melee swing,
and the client calls it ready until that swing lands and starts the
cooldown, so the old walk pressed it every frame: the live log has eleven
dispatches inside one second. An on-next-swing ability (the catalogue's
`on_next_swing`, or by name: Raptor Strike, Heroic Strike, Cleave, Maul) now
goes in the off-GCD lane, is held while the client reports it queued, and
for one weapon swing after a press on a build that does not report it. The
confirmation breaker leaves it alone, because its confirmation comes with the
swing, not with the press. The same log has Arcane Shot dispatched twenty times
in three seconds, from presses the client refused without starting a
cooldown. Any press that went out and has not been confirmed is now retried
once a second rather than every frame. That is shorter than a global
cooldown, so a cast that landed is never held by it. The watch line says
"queued on the next swing" or "pressed under a second ago, not confirmed yet".

**The mark stays put in a pack.** A hunter has one Hunter's Mark, and
marking a new target takes it off the old one. In a pack the target changes
whenever a mob turns onto you, and the mark used to follow it: four marks in
twenty seconds on a three-mob pull, each costing a global cooldown and mana.
Mid-fight, the mark now stays on whichever mob of the fight carries it until
that mob is under a fifth of its health. The pull is marked as before.

**Mend Pet has one owner.** The hunter's Mend Pet rule and the pet module's
healing pass each cast it on their own lockout, so they alternated. One cast
on you (it still lands on the pet) and the next on the pet: six in
thirty-three seconds, with the hunter channelling instead of shooting. The
pet module now stands aside for any spell the active profile has a rule for
(`rotation.has_rule`). Since 1.31.0 the reaction engine owns Mend Pet and both
stand aside for it; since 1.32.0 there is no switch or slider for it at all.

**Intimidation waits for the pet.** It stuns whatever the *pet* is hitting, so
it fires only once the pet's target is ours. **Bestial Wrath goes on cooldown**
while levelling, as the guide has it: a two-minute cooldown against fights every
half a minute is back before it is wanted again. It still needs a fight long
enough to use some of it, and a burst window opened by the burst module always
counts. Both have their own toggles under Hunter options, separate from the
global cooldown switch, because the guide treats them as part of the rotation
rather than as something to save.

**Weaving is yours.** A ranged auto attack keeps its swing timer running
while you move, but the shot only goes out while you are *standing* for the
half-second aim. Earlier revisions of `modules/weave.lua` held the character
still for that aim through the client's movement lock, and one of them turned
the character to face the target as well. Both made the hunter feel jerky: a
stop every weapon speed, and a character that came out of the stop running
somewhere else. Neither is done any more. The rotation presses Auto Shot the
moment it detects it can -- standing, at range, and the toggle not already
running -- and the shot goes out on its own whenever you stand; how and when
you stop is your call. What remains of the module is a readout: when the last
real shot went out (the core's cast callback, or the swing timer addon's
last swing when it is loaded) and when the next is due. It takes no input
lease and holds nothing.

**Mana is spent in tiers.** Auto Shot is free and is most of the damage;
every special is mana spent to end the fight a little sooner, and mana spent
is drinking later. The five-second rule makes it worse: any cast stops mana
regeneration for five seconds, so a hunter who only shoots regenerates
through the fight and one who casts a filler every global cooldown never
does. So specials are bought best value first, from the bar and the resource
model's posture:

| Bar | What is bought |
|---|---|
| Will not last the fight, or under 15% | Nothing that costs mana except safety (Concussive Shot, Wing Clip) and Mend Pet. The mark only on a fight long enough to pay for it |
| Under 45% | The essentials: Hunter's Mark, the Aimed Shot opener, Serpent Sting on a mob that will live to take every tick |
| 45% and up, but the bar will not last this fight (or the posture says conserve) | Plus the second Aimed Shot, and the sting on a normal mob |
| 45% and up, and it will | Plus the fillers, Multi-Shot and Arcane Shot on one target, which add the least damage for the most mana |

Multi-Shot against a pack is bought at any tier above empty; Arcane Shot on
the move, or with the mob too close for a three-second cast, from the
essentials tier up, because nothing else casts then. The fillers used to
wait for a fixed 70% (a slider); since 1.33.0 they go out while the measured
bar will last the fight, and the reaction engine scores each by what it costs.

Once Summon Hawk is trained (Forever, Beast Mastery) Arcane Shot is not
pressed at all, in any profile: the two share a cooldown, and the hawks get
it, as in Mobalytics' levelling guide (1.7.5). Before 1.7.5 it went out in the
gap while both hawks were up.

**Before there is a pet** (levels one to ten) the kite module runs the
guide's pattern: stand for the half-second aim, run for the rest of the
swing, Concussive Shot as early as it is available. It is loaded from
`main.lua` alongside the weave and stops the moment Tame Beast is trained;
from then on its only job is the step out above. Both have toggles under
Hunter options.

**Beast Mastery (1.7.6; the melee weave in it since 1.8.1).** The Forever
guides' rotation (Icy Veins, wowtbc.gg, Mobalytics; read 2026-10-10). It runs
for every hunter whose talents lead with Beast Mastery, from the first point
and with none spent yet; under 20 points, Levelling keeps the hunters led by
Marksmanship or Survival. It shipped first as an ALPHA behind its own option;
the user then made it the Beast Mastery rotation and the option went. On
2026-10-11 the AOE melee weave (below) went into it the same way: "add AOE
melee weave into our Normal Beast master rotation no longer alpha/test". The
order:

1. Hunter's Mark, and the pet sent in.
2. **The pet hits first.** Every shot waits for it, Auto Shot included
   (Levelling fires Auto Shot at once), and so do Rapid Fire and the hawks. The
   wait ends at the pet's first hit: the mob turning onto the pet, losing
   health with the pet beside it, or a second with the pet beside it. Forever
   has no combat log to say so outright. No wait in a group, with no pet out,
   with the pet off or held on a focus, or once the mob is on you. The pet
   module gets 2 s to send the pet, and a pet not there 5 s after it was sent
   is not waited for. The wait is for the pull only: the other mobs of the
   fight never wait for it (1.8.1, see the sting below).
3. **Multi-Shot first with two or more mobs where it lands**, standing at
   range, and **never on one mob** (1.8.1: the weave's rule, "Neither PvP or AoE
   meele wave should Multishot if its not 2+ enemy mobs", is Beast Mastery's
   now; the one-mob quick shot when the aim would not land is gone). Multi-Shot
   and Aimed Shot share one cooldown on Forever.
4. Auto Shot, and on both sides of the dead zone: **two hawks at all times**
   (Summon Hawk has no minimum range; a bar that is refilling still keeps two).
   **Rapid Fire** (on Forever it speeds melee too), **Bestial Wrath** and
   **Intimidation** go out in a burst window only (see *The hunter's burst*
   below).
5. **Serpent Sting on every mob fighting you or your pet** (the default of
   *Serpent Sting on* since 1.8.1), straight onto each, your target kept.
6. Aimed Shot on its cooldown, at Forever's 2 s cast, when it lands before the
   mob does, and only with one mob where Multi-Shot would land.
7. **In melee, the burst:** Immolation Trap at your feet (Explosive Trap with
   two or more round you; Forever lays traps in a fight), Raptor Strike,
   Mongoose Bite, Strider Kick, Counterattack, Lacerate on a mob that lives
   12 s, and the plain swing -- at a mob that came to you, and at one on the
   pet you walked up to.

**You walk in and out yourself**; the rotation reads which side of the dead
zone you stand on. Once the pet levels have begun (Tame Beast trained) the step
out and the run-and-shoot stand aside while Beast Mastery runs; before them the
run-and-shoot is still the kite module's (a hunter with no points reads as
Beast Mastery). Auto Shot is pressed again the moment you are back out, because
a strike or the swing switches it off.

With the pet out there is no Concussive Shot on a charging mob and no Wing
Clip; a mob running away is still dazed. With no pet out, Levelling's slow and
clip come back. Arcane Shot goes only before Summon Hawk is trained. Kill
Command and Steady Shot (Era's runes) stay in the list for Era; Forever has
neither. The mana rules (*Mana for extra shots*) hold as everywhere else: on an
empty bar nothing costs mana, and nothing that costs mana goes at a mob about
to die (the plain swing still does). Keep Aspect of the Hawk up in a fight for
Deadly Aspects: aspects are yours, in the Aspects window.

The line in the class window (where the weave's switch was) says which side
you are on, how many mobs carry a sting and how many hawks are out, or that
Beast Mastery is not your rotation.

*Where it came from: the AOE melee weave (1.7.6, ALPHA/TEST).* A hunter option
that ran its own profile in place of your talents', replacing the melee weave
on a key (which ran the hunter in and out by itself and is gone). The user's
design: "When in meele range u can still cast summon hawk, immolation trap and
other Meele skilss to burst down dmg same as Rapid fire ... We manually Move out
and when we move out we use Multi-shot! ... renew as many Serpent stings on
Multiple target in combat with US!!! ... at all times keep 2 hawks up". Since
1.8.1 the option and the profile are gone; a value the option saved changes
nothing.

**The stings, and the target swap (1.8.1).** The weave moved your target from
mob to mob to sting each one. That moved Auto Shot and the assisting pet along
with it. Now the rotation's spread puts the sting straight onto every mob of
the fight, your target kept. The reaction *Beast Mastery: sting the next mob*
(formerly *AOE weave: sting the next mob*) is what is left of the swap: out of
melee, once your target carries its sting, a mob of the fight that has gone
**4 s needing one all the same** (the spread switched off, or the client
refusing the sting there) becomes the target. The least sting left goes first,
then the nearest. It only picks mobs within 35 yd, outside the dead zone, not
under control that damage breaks, and living 8 s or more, and only while Beast
Mastery runs.

**Disengage when a mob hits you (1.8.1).** A hunter option, off by default, in
the class window and under Hunter options. The user: "add a button Turn it on
if being attacked to disengage". Forever's Disengage is Classic's: the
client's own table (`SpellEffect`) gives all three ranks one effect, a threat
drop (effect 63, as Era's -141/-281/-406), melee range and a 5 s cooldown --
not the later leap. So the switch means: a mob hitting you in melee that your
pet is fighting (in a group, the tank) is handed back with Disengage (the
reaction *Disengage when hit*, your target first, else the nearest). With
nobody else on the mob the drop would leave it on you and waste the global, so
then it waits; players are left alone. It is a reaction, so it needs Reactions
on (the Reactions page). Off, **nothing ever presses Disengage for you**: not
the threat reaction (*Shed threat*), not the escapes, not the hardcore
bail-out. The class gates it through `key_gated` (`rotation.lua`,
`H.key_allows`, which every one of those paths asks); `key_gated` takes a
function since 1.8.1 as well as a key.

**Intimidation (fixed in 1.8.1).** The user: "what about intimidation? I learned
it recently from my talents but i dont see it being used". It had never been
pressed, on any client. Its catalogue row needs the pet on the target, and it
is cast on yourself (it lands on whatever the pet hits next), so the gate
compared your own guid with the pet's target and refused it every time -- the
rotation and the three Intimidation reactions alike. On yourself the need is
now "the pet is on a mob". And Forever does not say what the pet is attacking
(1.73.1): Intimidation and Bestial Wrath read the pet module's answer now,
`P.pet.fighting()` -- the client's, else the mob the pet was last sent at while
it lives, for 30 s, as the reactions already did.

It is a cooldown to spend, not a filler. The user: "it stunts target and next
sucess full attack gains 100% critical chance and Generate high threat so it
should be used ina Burst, Interrupt (stunt) or when I really need a mob off me
and Disengage is not available". So:

- **In a burst.** It is in the hunter's burst sequence after Bestial Wrath (the
  pet's next hit a sure crit inside the window), skipped while the pet is on
  nothing or the mob is held by crowd control. The rotation's own rule presses
  it only inside a burst window, for a window whose sequence went by before the
  pet reached the mob; never on a mob about to die.
- **To stop a cast.** *Stop the cast with crowd control*: Scatter Shot first,
  Intimidation when the pet is on the caster.
- **A mob off you.** *Intimidation: give the pet its mob back*: the pet's mob is
  on you, Growl cannot bring it back, and Disengage cannot either (its switch
  off, not trained, on its cooldown, or the mob out of melee reach). It waits
  2 s after a Disengage, which needs that moment to turn the mob.
- *Intimidation: save the pet* (the pet about to die under its mob) stays.

**PvP hunter (1.7.6, ALPHA/TEST).** A hunter option, off by default, in the
class window and under Hunter options. It has not been tried in game. Nobody
has published a PvP guide for the Forever hunter yet (checked 2026-10-10:
Mobalytics, Icy Veins and wowtbc.gg are PvE only), so it follows the Classic
hunter PvP guides (Icy Veins, Wowhead's dueling guide) with what Forever
changed: traps can be laid in combat, Freezing Trap shares its cooldown with
Frost Trap, Multi-Shot shares Aimed Shot's.

*When it runs.* PvP mode is on while your target is an enemy player, an enemy
player within 40 yd is on you or your pet, or you are in a battleground with
one that close. It holds 4 s past the last sign. In PvP mode the PvP profile
runs, whatever your talents, and so do its reactions. Fights are still yours to
start: nothing opens on a player by itself.

*What it reads off the other player.* Its class, a druid's form, and from
those melee, caster or ranged. A player seen casting a heal in the last 20 s
counts as a healer. It also reads whether it has mana to drain and whether it
can stealth. Immunities, Deterrence, bursts and diminishing returns are the
reactions' existing reads.

*The rotation (PvP profile).*
1. Hunter's Mark on every player (*Hunter's Mark on: Never* still means never).
2. In melee: Wing Clip while it is not slowed; Strider Kick (Forever) on a
   clipped one, for the run speed. The step out then walks you away.
3. Concussive Shot on a melee player coming at you, and on anyone running off.
4. Rapid Fire (and Bestial Wrath) once the fight is on, at range, not into a
   bubble, Deterrence or your own trap.
5. Aimed Shot where it lands: a caster or healer standing, a player stunned for
   the cast's length, a melee player far enough off. Never with a player in
   melee with you.
6. Auto Shot. One sting each: Viper Sting on a caster or healer with mana
   (from 36); Scorpid Sting on a player who fights with attacks, melee or a
   hunter's bow (from 22): on Forever it takes their chance to hit for 20 s.
   It does no damage, so it goes before the trap too. Serpent Sting on the
   rest, and on an attacker before Scorpid Sting is trained. A rogue or druid
   now gets Scorpid Sting, not the dot that kept it in combat; Hunter's Mark
   still shows it stealthed. Two hawks. Multi-Shot only with two or more
   enemies where it lands, never beside a trapped player. Arcane Shot until
   the hawks are trained.
7. Raptor Strike, Mongoose Bite and Counterattack only while stuck in melee.

*The reactions (before the rotation, every tick).*
- **Peel the melee.** An enemy player in melee with you gets Wing Clip first.
  If the clip has not shaken it after 1.5 s, it ignores slows, you are under
  half health, or two are on you, the next answers are:
  - Freezing Trap at your feet, but never on a player one of your stings or
    hawks is ticking on, or one the pet is biting: either breaks the trap;
  - Scatter Shot;
  - the pet's Intimidation, when the pet is on it;
  - Frost Trap against two.

  Deterrence comes from the core defensive at low health and from the burst
  answer.
- **Scatter into the trap.** A player in your Scatter Shot beside you, nothing
  ticking on it: Freezing Trap goes down under it before it wakes.
- **Feign Death the cast.** A Polymorph, Fear, sleep or charm about to land on
  you, or a big hit (Pyroblast, an enemy's Aimed Shot), in its last 0.6 s:
  they lose you as a target and the cast fails. A Frostbolt counts only under
  half health. Scatter Shot from 15 yd goes first (the same cast, answered
  once). The core defensive no longer spends Feign Death early on a cast.
- **Turn on the player attacking you** while you shoot a mob.
- **Shoot another while this one is trapped,** if one is in the fight.
- **Finish the low one:** another enemy player at 20% or less while yours is
  above 40%.
- **Scatter Shot stops an enemy healer's heal** within 15 yd, not only casts
  aimed at you.

*Nothing breaks your own control.*
- A player in your Freezing Trap or Scatter Shot (or anyone's sheep) takes no
  shot, sting or hawk.
- The pet is not sent at it and no pet skill is aimed there; one already on it
  goes to your target if that is free, else whoever is hitting it or you, else
  it is called back (this holds outside PvP too, for any mob held by control
  that damage breaks, whoever sent the pet: 1.8.1).
- No burst window opens on it.
- Forever fires Auto Shot once per press, so not pressing stops it. On Era the
  attack is stopped once (a guess: that stop-attack ends Auto Shot).

*The trap opener.* From a player frozen in your trap the step out keeps walking
to 25 yd (Intercept and Charge reach 25). Then Rapid Fire and Aimed Shot: its damage breaks the trap,
and the player has the whole distance to cover again under Concussive Shot.
If the trap is about to end, the opener goes from wherever you stand.

*The trap first.* While Freezing Trap is ready or nearly so, a melee player
coming at you gets Auto Shot, Aimed Shot and Multi-Shot only. Each sting or
hawk tick would break the trap.

*One option.* The PvP hunter is its switch alone. The user, 2026-10-10:
"Remove all the PVP hunter Options off the UI and just into one option still
Alpha". The four that tuned it (the trap first, the 25 yd walk, the turn on an
attacker, the switch to a player about to die) are fixed at what they
defaulted to, and a value one of them saved is not read.

The line under the option in the class window says whether PvP mode is on, who
you face (for example "Rogue (melee)"), how long your trap holds, and the last
thing the reactions did.

---

### Which mobs get the mark, and the sting on more than one (1.84.0)

The user, on Forever: "a setting to only mark bosses? in dungeon also" and "my
hunter spends more time putting up mark than actually dpsing". Every pull
opened with Hunter's Mark: a global cooldown and mana for a bonus that a
levelling mob dies under. The mark itself was read correctly on Forever (the
client's tables: the debuff carries the spell's own id, 1130 and its ranks,
exactly as on Era); it was simply cast on everything.

**Hunter's Mark on** (hunter options, and the hunter's class window):

| Choice | Marked |
|---|---|
| Every target (default) | as before |
| Elites and bosses | elites, rare elites and bosses |
| Bosses only | bosses only, dungeons and raids included |
| Never | nothing |

A boss is the client's own word: its classification (3, a boss) or its boss
flag (`is_boss`, which answers on Forever and retail). Era has no boss flag and
reads its dungeon bosses as elites, so on Era *Bosses only* marks world and raid
bosses, and *Elites and bosses* is the one for a dungeon. The pull does not
need the mark: Auto Shot and the Aimed Shot opener start a fight without it.

**Serpent Sting on** (same places): *My target only*, *Up to 2 mobs*, *Up to
3 mobs*, or *Every mob fighting you* (the default since 1.8.1; *Up to 3 mobs*
before). With more than one mob in the fight, once your target has
its sting the rule is asked about each other engaged mob in turn
(`spread`, the engine's DoT spread, as the warlock's Corruption), and a sting
goes on the first that is worth one, until that many carry yours. Each must
live long enough for the sting on its own time to die, and the bar has to
afford it (the spend tiers above). Only the target waits for the pet; the
other mobs are in the fight already (1.8.1: the wait was asked about each of
them with one clock, so each add restarted it for the next, and while the
target was not yet on the pet or on you two adds were never stung). Never a
mob held by crowd control that damage breaks, and never one inside the dead
zone: the next mob is asked. The engine also skips a mob the spell cannot
reach -- out of range, inside its minimum range, out of sight -- and asks the
next (1.8.1, `rotation.lua` `ask`, for every class's spread: the first mob the
rule liked used to be the answer, and a press there failed, so one add hitting
you in melee kept the sting off every other). The engine sets `s.spreading`
while it asks about a mob other than the target, which is how the cap is told
apart from the target's own sting.

## Healing the pet

The old rule was *"pet below 50% and I am above 40%, so heal it"*. Health Funnel
then ran on a pet three mobs were beating on, channelled through the warlock's
own health bar, and ended with a dead pet **and** a dead warlock.

The percentage was never the question. Four things now have to be true, where
the old rule checked one:

1. The pet is low enough to be worth a global cooldown — and *low* is derived
   from how fast it is losing health, not from a fixed number.
2. The pet is **holding something**. A pet at 20% that is not tanking is not
   about to be hit again.
3. We can afford it. Health Funnel is paid in our health, so it goes through the
   same trade gate as Life Tap.
4. It will actually save the pet. If the pet is losing health faster than the
   funnel restores it, the funnel buys a second and costs us the fight.

**One heal per dip (1.31.0).** With the reaction engine on, the pet's health
dropping is one event: from the first moment it needs a heal — or will within
two and a half seconds, at the rate it is falling — until it is back 25 points
over the line. One Mend Pet answers it, and the event stays answered for the
channel and a beat after, the time it takes to see whether the heal worked.
The hunter's own Mend Pet rule and the pet module's healing pass stand aside
while the engine owns the spell. Out of combat, a pet under 70% is topped up
only on a tick the rotation has nothing else to press, and never while you
are eating or drinking.

---

## The spell window

A small window, right of centre just above the action bars, that reads left to
right as time:

```
 Rotation  -  Levelling                                  (title bar: drag it)
 USED                                  NEXT  Serpent Sting
 [ ][ ][Mark][Arcane][Raptor][Bolt▬▬]  >  [ STING ] [Arcane] [Bolt]
                                                     +1.5     +3.0
```

- **Used**, oldest on the left, fading with age. The thin bar under each icon
  is the accent colour when the plugin pressed it and grey when you did.
- **In flight**: the cast or channel happening now, in the newest slot with a
  progress bar under it. When it completes it becomes the newest used spell, in
  the same place.
- **Next** (the large icon) and the presses after it, each with its own icon.
  A next spell still on cooldown is dimmed with its seconds on it; the smaller
  ones show `+seconds` under them. An off-GCD press (Raptor Strike on the next
  swing) has an amber frame.

With the rotation **off or paused** the window keeps suggesting what it would
press -- the title says `(paused, suggesting)` -- so it doubles as a helper
while you play by hand. *Suggest the next spells while the rotation is off*
turns that off.

Drag it by its title bar; double-click the title to fold it away. Where it was
left is remembered by JCore's overlay UI (**JCore > UI > reset layout** puts it
back). Settings are on the Rotation page under **Spell window**: icon size, how
many used and coming spells to show, whether Auto Shot / wand / melee swings
count, and combat-only.

### Where "next" comes from

The priority walk cannot say what comes after its choice: it stops at the first
rule that fires. `rotation.lua` therefore has a **forecast**: every rule of the
active profile is asked against the tick's own snapshot, through the same gates
the walk applies, and the answers are played forward a few global cooldowns:

| A rule that... | appears |
|---|---|
| has an upkeep, is a DoT, a self buff, a heal, or applies an aura (catalogue) | **once** -- after it lands its own predicate says no |
| has a cooldown (catalogue, else the client's base cooldown) | again when the cooldown is over |
| has neither | as a filler, repeating (Shadow Bolt, Shadow Bolt) |
| is a toggle (Auto Shot, a wand) | never -- it is a running state, not a press |
| was just pressed and is waiting to land | never -- it is in flight |

The lane starts when both the global cooldown and the cast in flight are done;
off-GCD presses take no time from it; nothing past twelve seconds is shown.
Holding fire is ignored on purpose: with a mob selected and no fight yet, the
window shows the opener rather than nothing. It is a projection from *now*, not
a simulation -- a proc, a dodge window or a mob dying changes the answer on the
next projection, five times a second.

**A predicate that keeps state must not let the forecast write it.** The
forecast asks about mobs the walk is not acting on yet, so state it started
would change the fight itself whenever the window is open. `H.forecasting()`
is true only while the forecast is asking: read state then, never start or
reset it. The hunter's wait for the pet is the case that needed it -- selecting
a mob started the two-second "has the pet been sent" clock, and an engage
after that shot before the pet was sent (`aio_hunter_test`).

### Why the backdrop has holes in it

Textures paint beneath every 2D shape (see *Unverified assumptions*), so a
panel behind the icons would be drawn **over** them. The body's backdrop is
filled band by band *around* each icon slot, and only shapes meant to sit on an
icon -- its frame, the cooldown dim, the countdown -- touch one. For the same
reason the JCore overlay window is **only the title bar**: its body is a solid
fill. `aio_timeline_test` checks that no opaque fill overlaps any icon.

An icon still loading (the first sight of a spell: a download, then the disk
cache) or one that failed shows the spell's initials on a tile instead.

## The aspects window (1.49.0)

A hunter's aspects are switched by hand. Neither the rotation nor the reactions
cast one: the four hunter profiles lost their *Aspect of the Hawk* rule, and the
catalogue gate (`rotation.lua`, `catalog_blocks`) refuses any ability whose
row says `exclusive = "aspect"`. That gate is the one both the priority walk
and the reaction engine (`press_blocked`) go through, so no rule and no
reaction picking abilities by role can bring an aspect back.

In their place, a small window (left of centre, above the action bars) with one
slide switch per trained aspect:

```
 Aspects               (title bar: drag it)
 Hawk                  ( o   )
 Monkey                (   o )   <- on
 Cheetah               ( o   )
 Monkey is up.
```

- **On** puts the aspect up and keeps it up: after a death once you are alive
  again, and after a reload. It waits, and the line under the switches says
  why, while you are dead, mounted, feigning death, eating or drinking,
  casting, short of mana, or with the plugin switched off.
- **Off** cancels it (`core.input.cancel_buff`, given the row `get_buffs()`
  handed out) and nothing replaces it.
- **One at a time**, as in the game: sliding one on slides the other off, and
  the new aspect is cast over the old one.
- **The switches follow the game.** An aspect picked from the action bar
  slides its own switch on; one clicked off the buff bar while you are alive
  slides it off (after 1.5 s, so a loading screen's empty buff list is not
  taken for a click). The window never fights a choice made outside it.
- The choice is kept per character (the `aspects` store, keyed by GUID).
- Forever, on a core before 2026-10-06: `cancel_buff` does nothing there (that
  client has no UnitBuff), so *off* leaves the aspect up and the window says to
  click it off the buff bar. From that core on, *off* cancels it there too.

The window is a JCore overlay window made of its slide switches (`ui:toggle`),
so it takes the mouse like any JCore window and needs the overlay UI switched
on. It has no icons: a JCore window's body is a solid fill, which would hide
them (see *Why the backdrop has holes in it*). *Show the Aspects window* is in
the hunter-only **Aspects** section of the Rotation page. Hiding the window does
not stop a switched-on aspect being kept up; switch it off first.

Tests: `aio_aspects_test` (the keeper with a scripted clock, the window against
a mock UI, the walk and `press_blocked` refusing an aspect, no profile rule)
and `aio_boot_aspects_test` (the whole plugin on Era: JCore's real window, a
mouse click on a switch casts the aspect, a second click cancels it).

### Out of Cheetah before the hit (1.50.0)

Hit while in Cheetah and you are dazed; hit while in Pack and so is every party
member who was hit. So the one time an aspect is switched for you is just
before a hit lands: the switch moves out of Cheetah (or Pack) into the aspect
you last fought in -- Hawk, else Monkey -- and the cast goes out at once, in the
defensive band. The window's line says what happened: *Out of Cheetah: Boar
reaches you in 0.8s.*

Only with **Auto swap aspects** on (1.7.6; `rot_hunter_auto_aspect`, off by
default): the switch under the aspect switches in the Hunter window, also on
the Rotation page. Off, no aspect is ever swapped for you -- neither caller
below acts, and Cheetah stays up through the hit. The aspect you switched on is
still put back after a death or a dismount; that keeps your choice, it swaps
nothing.

What counts as a hit about to land (`aspects.lua`, `M.incoming`, read from
JCore's enemies rows and missiles -- no reads of its own):

| On you | switches |
|---|---|
| a mob in melee (5.5 yd) | at once |
| a mob closing that reaches you within 1 s plus the global cooldown left | then |
| a mob casting at you | at once -- the spell lands wherever you run |
| a hostile missile landing on you within 2.5 s | at once |
| a mob in the fight, standing still at range, on you for 0.6 s | it is attacking from there |
| a mob chasing you and losing ground | **never** -- Cheetah is how you get away |
| a stunned, feared or otherwise controlled mob | never |
| in Pack: a mob in a fight with a party member within 40 yd | at once |

Two callers, one decision. The reaction engine asks it every tick as the hunter
reaction *Out of Cheetah before the hit* (`react/rules/hunter.lua`): an
`"aspect"` action that the engine hands to `P.aspects.switch_to` instead of
casting a spell, so the catalogue gate that keeps aspects out of the rotation
still holds, and the window's switch moves with the cast. When the engine is
not running -- rotation off, its key up, mounted -- the Aspects keeper asks the
same question itself, ten times a second while a travel aspect is up, and
stands aside whenever the engine asked within the last 0.35 s. It does not put
Cheetah back after the fight: slide it on again when you travel.

Tests: `aio_aspects_test` (the detector case by case, the keeper's guard:
once, back to the last fighting aspect, outrunning, mounted, the engine
watching, the global cooldown) and `aio_react_test` (the real engine and the
hunter rules with the real Aspects module: one swap for one hit, in the
defensive band, nothing for a mob being outrun, nothing without the module).

---

## Periodic freezes

Reported as "the game freezes every so often, like an overload of memory". Found
by counting native calls per frame in the harness -- each one is a round trip
into the client, which is what actually makes a frame slow here -- and comparing
an ordinary frame with the frames where timers fire.

**Every repeating timer fired on the same frame.** All of them are created during
load, in one frame, and the scheduler set each one due at `now + interval`. So
the bag scan, the talent scan, the quest index rebuild, the class check and the
core housekeeping all ran together every five seconds, with the ten-second jobs
on top every other time. Each timer now runs at its own point in its cycle,
spread by the golden ratio so no two sharing an interval land close together.

**And they re-synchronised after every loading screen.** An overdue timer was
clamped to `now + interval`, so after any stall every one of them lined up again.
The clamp now returns each to its own phase.

**The soul-shard count walked the bags three times a frame** -- the idle hook
plus two stone rules -- measured at fifteen container reads per frame while
doing nothing, plus a fresh lowercased string per item per walk for the garbage
collector. Counts are now cached for a second and invalidated on `BAG_UPDATE` or
a destroy.

**`SPELLS_CHANGED` triggered four full rescans in the handler**, and the client
fires it in bursts -- login, talent changes, and every pet summon. Five events was
five spellbook walks and five talent scans in one frame. It now marks the book
dirty and one coalesced broadcast goes out, at most twice a second.

**A render job threw on every frame.** `modules/esp/elements.lua` formatted a
fractional health value with `%d`, which Lua 5.3 and later reject. The job died
mid-draw sixty times a second, building and discarding a traceback each time.
Fixed with `%.0f` throughout the ESP modules.

**And that class of failure can no longer spin.** A scheduled job that throws
five times running is now paused, for pauses that double from two seconds up to
thirty, and a single success resets it. Paused rather than switched off, because
a job failing for a few frames during a loading screen -- when every object is
briefly invalid -- has to come back by itself.

**`QUEST_LOG_UPDATE` ran the whole quest index inside the handler.** The client
fires it in bursts -- a dozen in one frame on login and after every loading
screen, once per kill credit, once per loot, and whenever an addon touches the
log -- and every one of them rebuilt the index (a native call per quest, per
objective) and walked Questie's quest log for the flat id set, in the same
frame. Accepting or turning in a quest also wiped Questie's per-quest database
answers, so the next rebuild re-queried every quest in the log at once. Both
handlers now only mark the index dirty; one coalesced rebuild runs on a later
tick, at most twice a second, and the database answers are kept for the session
because they are static data.

**Quest paths had no ceiling on terrain traces.** Every point on a ground path
is up to three `get_height_for_position` calls, and a fresh path -- after a zone
change, after the cell cache filled, or whenever a new target appeared -- was
sampled end to end in one frame: three hundred traces for four quest paths and
the guide's waypoint. Height queries are now rationed to thirty a frame; a point
past the budget holds the previous height and is sampled on a later frame, so a
path arrives over a few frames instead of stalling one.

**Every setting read walked all eight menu pages.** `P.opt` tried each page in
turn, a guarded host call per page, and the overlay reads fifteen-odd settings
per mark per frame -- thousands of menu reads a frame for values that only
change when a slider moves. Reads are memoised per frame now; a colour picker's
`on_change` handler invalidates the memo because it reads back in the same frame.

**The unit classification was dropped wholesale every two seconds**, a leftover
from when guide membership lived in it. Every unit in range was then re-read in
one frame, eleven native calls apiece. Entries now expire per unit on a jittered
two-second clock, so the same refresh happens a few units per frame.

**Two angle wraps were subtract-until loops.** A rotation the client answers as
`inf` -- which it can, for a unit whose model is not loaded -- would never leave
`while rel > pi do rel = rel - 2*pi end`, and a render job that never returns is
the whole game hung. Both wrap with a modulo now. The dashed-path walker got an
iteration cap for the same reason: it advances by float arithmetic, and a step
that rounds to nothing is a spin.

**The threat row was built not to be the next entry here.** Ranking you on a
mob means asking the client about every group member: in a raid, forty natives
per mob. JCore's threat service (1.5.0) does that on its own budget, never
from a render job: the target twice a second and every other mob once, at most
24 natives a tick (but always at least one whole mob, so a raid does not
starve), and the forty raid tokens are probed eight a tick, never in one frame.
Your own figure comes from the enemies row the core already read, so a solo
fight costs nothing. The overlay reads the finished boards: one table lookup
per mark.

**The spell window was built not to be the next entry here either.** Its
forecast asks every rule of the profile instead of stopping at the first, so
it runs five times a second, not every frame, and only while the window is
on screen. It reuses the tick's own snapshot, and the cooldown and usability
reads come from the core's per-tick spell cache the walk already filled;
range comes from the catalogue, so there is no `castable()` and no
line-of-sight trace. With the rotation off it builds its own snapshot at the
same five a second. The history is fed by events, not polled.

**The overlay asked the client the same questions over and over (1.40.0,
JCore 1.5.3).** `aio_esp_perf_test` boots the whole plugin in a scripted
crowd -- thirty mobs in view, ten behind the camera, corpses, friendly NPCs
and players -- and counts every call into the client. Before: 2,124 a frame
with the overlay on, 884 with it off. After: 1,172 and 705. What went:

- **The clock, 276 a frame.** The asset registry stamped every icon request
  with `core.time()` (four to eleven per textured mark, most of them for
  archive art that could never load and was retried all session); the
  classifier read it per unit, the detail read per mark. Now once a tick.
- **Marks behind the camera did all their work.** Detail, status, threat,
  art, mana and the nameplate were read for marks nobody could see, and spent
  the frame's rationed reads before the marks in view got theirs. A mark off
  screen now draws only the line from an attacker to you, from free data.
- **Questions the sweep had answered.** Every draw helper asked each unit
  `is_valid`, `get_guid` and `get_position` again, per mark; "is this my
  target" asked the client per mark; the sweep asked `is_dead` twice per
  unit. Now read off the sweep's row, the collection pass and one read.
- **Corpses** were asked about their loot three or four times each, every
  frame; now twice a second.
- **Settings**: about five thousand reads a frame for a few dozen answers,
  now read once a frame.
- **Memory**: JCore's projection cache kept every unit ever projected for
  the session; time-to-die kept six hundred samples per enemy. Both bounded.

The test fails if the total, the overlay's share, or any of those calls
creeps back over its ceiling.

**The reaction engine was built not to be the next entry here (1.31.0).** It
reads almost nothing itself: the world state is assembled from the rotation's
snapshot, JCore's enemy rows and threat boards, all already paid for. What it
adds is rationed — a unit's level and rank once per unit per ten seconds, the
group roster twice a second, one pet read a tick, an item's usability once a
second. Rules on an interval (dispel, crowd control, threat) are asked only
when due, or when an event (`jcore.enemy.casting`) wakes them; at most four
candidates per lane are validated a tick, which caps the range and sight
checks; interrupts consider the target and at most three other casters. The
readout's words — the danger reasons, the decision snapshot — are only built
while the Rotation page or the overlay is showing them, and a refusal
repeated every frame is formatted once every three seconds, not sixty times.

---

## Forever (Classic+)

Forever is a level-60 classic world on the retail engine. Its client has
retail's API, not the classic globals the core calls on Era, so two readers
used to come back empty there. JCore's `ctx.world.client()` says which client
is running, once per session, and each reader picks its path from that.

Forever support is **added beside** the classic code, never in place of it. On
Era every reader below runs exactly as before, and the Forever machinery (the
trait reader, the talent events, the quest tracking, its per-frame sweep job,
the retail objective format) is not even registered there. Everything else
the AIO does (spells by name, auras, pet control, ESP, Questie, RestedXP) uses
calls for which the `.api` notes no Forever gap. The JCore API recorder has
since run on a Forever client and found gaps the notes did not have; what the
reactions and the rotation do about them is below.

**Talents** come from the trait API (`get_active_talents`) instead of
`get_talent_info`, by name as before, so `H.talent` / `H.has_talent` and every
talent-gated rule work unchanged. The three tab totals the profile suggestion
counts with need each talent's tree. With three trait trees, a tree's position
is its tab. With a single tree, the chosen specialization is the tab. When
neither holds, ranks are still read but the totals stay at zero, which every
class reads as "levelling", and the Rotation page shows
`Traits (no tree split)`. On Forever the trait events (`TRAIT_CONFIG_UPDATED`,
`PLAYER_TALENT_UPDATE`) coalesce into one scan half a second later; if the
trait API answers nothing, the classic walk is tried before giving up.

**Quests** come from `modules/questlog.lua`. On Era it reads the quest log as
before. On Forever it keeps the set itself: `QUEST_ACCEPTED` adds,
`QUEST_TURNED_IN` removes, and each rebuild re-asks `is_on_quest` about what
it holds. A quest is dropped on the second "not on it" in a row, so a loading
screen cannot empty the log. The quests already in the log at login are found
by one sweep over Questie's quest ids, 60 a frame (about a second for a few
thousand). Names and levels come from Questie, completion from Questie, and
objective text and counts from RestedXP. On Forever objective text is parsed
in both formats, Era's `Name slain: 3/8` and the retail engine's
`3/8 Name slain`; on Era only the first, as always.
Without Questie, only the guide's quests and quests accepted this session are
known. Without RestedXP, quests are marked by Questie's ids but carry no
progress counts. On the 2026-10-06 core all of that comes from the game
instead: the set, names, levels, objectives and completion (see *The
2026-10-06 core (1.82.0)* below), and each piece falls back to the way above
where the core has no answer.

On Forever the Debug page adds a line for the client and talent source and one
for the tracked quest log; on Era the page is unchanged.

### The reactions and the rotation on Forever (1.45.0)

From the JCore API recorder's recording (`scripts_data/jcore/jcore.recorder.json`,
18 sessions of a rogue on the Forever beta). Four answers the reactions and the
rotation depend on are wrong there:

| The client answers | What it broke | What runs on Forever instead |
|---|---|---|
| `get_power` 0, every one of 164,586 calls (energy, combo points; mana unread) | A rogue reading 0 combo points never presses a finisher: no Eviscerate, no Slice and Dice. A mana class reading 0 of 0 would think it was dry | JCore's `services/power.lua` (this plugin's `modules/forever_power.lua` until 1.55.0) **counts** them from our own casts: combo points by each builder's tooltip ("Awards 1 combo point"), spent by a finisher, kept through a target change since 1.80.0 (JCore 1.8.12), zeroed by "requires combo points"; energy and rage spent by each cast's cost (`get_spell_costs`), energy regenerating at the client's rate; both corrected by the client -- a spell it calls usable means at least its cost, "Not enough energy" means less. Mana has no readable maximum, so it is not counted: the rotation is told the bar is fine, or dry for a few seconds after "Not enough mana". Any read that says anything but 0 is trusted from then on |
| `get_global_cooldown` 0, every one of 363,398 calls | The spell window's forecast and the idle report's GCD | JCore reads the GCD off a spell with no cooldown of its own (`get_spell_cooldown` works: Sinister Strike read 0.816 mid-GCD) |
| `COMBAT_LOG_EVENT_UNFILTERED` with no arguments, 13,696 of 13,696 | Measured damage, the damage tally the pet's threat guard reads, immunity and evade learning | Damage from the tooltips (the readout says so); the tally from what each cast is expected to deal; an evading mob seen from the mob itself -- one we hit, out of combat, its health coming back. Immunity and range edges still learn from the red text |
| `get_name` "" for units | Every lesson and log line named a blank | Names from our own casts (`UNIT_SPELLCAST_SENT` carries the target's name), kept per creature id; then the names the Forever ESP has learned and kept across sessions (1.45.1: the second recording logged `npc 250873` while the ESP knew it as Juvenile Vuldren); else `npc <id>` |

**Nothing was pressed at all on Forever before JCore 1.5.10.** The loader's
`spell_helper`, which JCore's castable check asked, does not know that client
(it asks `get_control_object`, always nil there, and the client's range data,
always 0), so every spell read *not usable* / *not castable on target* and the
rogue stood still until it died. JCore now checks castability itself on Forever
(see the JCore README).

**Groups and other people's mobs (1.47.4, JCore 1.5.13).** In a party on
Forever every unit's own role read -1, so the reactions never saw a tank or a
healer; JCore now reads roles from the party rows. And the client never says
"tapped by another" there (`is_tap_denied` answered false on every mob the
recorder caught fighting a stranger), so a mob's fight is read from who it is
hitting: a mob in combat with someone outside your group, that you did not
start on, is *someone else's fight* -- the interrupt reactions (a Kick, a Gouge,
Scatter Shot) leave it alone, because they would only pull it onto you. That
one holds on Era too.

And the active channel's id is sometimes garbage (3,739,147,998): an id no
spell can have is a channel we cannot name, and it is left alone -- a Mend Pet
is not clipped as "not ours".

On Forever the engine's decisions (states, triggers, lessons, the idle report)
also go into the recorder's timeline, `jcore.trace.txt`, beside what the
client answered -- and, every two seconds of a fight (1.45.1), one sample line:
*react sample: mode=NORMAL gcd=0.82 energy=55/100(counted) combo=3 target=Juvenile
Vuldren 45% ttd=4.2 last=Sinister Strike 0.3s ago* -- and the reaction readout
gets one more row:
*Forever: GCD off spell 1752 | energy counted (55), combopoints counted (3) |
combat log empty: damage from tooltips | 4 name(s) from casts*. On Era none of
it is built: no extra events, reads, rows or trace lines
(`tools/jtest/tests/aio_boot_react_test.lua`, `aio_forever_power_test.lua`,
`aio_boot_forever_react_test.lua`).

### Every class on Forever (1.50.1, JCore 1.5.14)

Only a rogue and a hunter had been played on Forever. Each of the nine classes
now has a test that boots the whole plugin on the whole of JCore as Forever
(`tools/jtest/mock/forever_class.lua`, `aio_forever_class_<class>_test.lua`).
Each test uses a level-20 spellbook and a mob, and the client answers the way
the recorder saw Forever answer:
- every power read 0, no pet from `get_pet`, no range data;
- the shapeshift form unread, the worst case, since it was never seen there.

Behind that sits a hidden pool, so the client's usable answers, cooldowns,
auras and cast events stay truthful. Before this, two classes failed:

| Class | What it did | What it does now |
|---|---|---|
| Druid | Cast Cat Form ten times in one fight: the form read 0, so `forms.maintain` cast it again, and a druid's form spell is a toggle, so it left the form every time. Nothing else was pressed | `forms.lua`, Forever only: a 0 is believed once the read has named a form. Until then the form comes from the player's auras, then from our own last successful form cast (a form cast in again counts as leaving it). Enters Cat Form once, then Claw and Rake |
| Warrior | Pressed Battle Stance 21 times in 24 s (same cause), and never Heroic Strike: its counted rage could only fall, so it never reached the 30 that Heroic Strike waits for | Takes its stance once. JCore's `services/power.lua` builds counted rage in combat at an estimated 3.5 a second. Every known spell's cost is a probe from the start, so the client's usable answers lift the bar, and "Not enough rage" pulls it down. Entering Bear or Cat Form starts that bar at 0. Sunder Armor to five, Rend, Heroic Strike, no refusals |
| Hunter, Warlock | Fought, but with the pet invisible (`get_pet` nil): never sent, mended or funnelled | `pet.lua` asks JCore's `units.player_pet()` on Forever, which looks for the pet through the minion list and `is_pet` + `get_owner` (see the JCore README). The pet is found and sent at the target |
| Rogue, Mage, Priest, Paladin, Shaman | Already fought | Unchanged; now covered |

**Not yet seen on a real Forever client** (the recorder will show each one the
first time a class that uses it is played):
- `get_shapeshift_form`: if it names forms there, the fallbacks step aside on
  the first non-zero answer;
- whether forms are auras on Forever;
- `get_all_minions` and `get_owner`;
- the rage estimate: the client corrects it both ways.

### Talents on Forever, from the client's own tables (1.77.3)

Forever keeps a class's three classic trees in **one** trait tree, side by
side. The client answers that one tree (`get_talent_tree_ids`) and
specialization 1, so until 1.77.3 every point counted for the first tab: past
20 points a Feral druid played Balance, a Frost mage Arcane, a Combat rogue
Assassination, a Fury warrior Arms. The column a node sits in is its tab, and
the client's tables say where each node sits. `tools/jcheck/talents_extract.js`
reads them out of the Forever install (TraitNode, SkillLineXTraitTree, and the
entry and definition tables for the names) and writes
`modules/talent_trees.lua`: every class node with its tab. `talents.lua`
counts each bought node for its tab. A node it does not know (a newer client)
falls back to the specialization, as before. Run the extractor again after a
Forever patch. Last run for client 1.60.1.70291 (1.84.0): that patch added
the warrior's Gore Drinker (Fury) and a new Iron Will (Protection), nodes the
70205 file did not know and so counted for Arms; it renamed the old Iron Will
to Lingering Rage and Predatory Instincts to Natural Instinct, and took out
Improved Cleave, Precision and Toughness.

The same tables, with Era's, were the check for every name the druid, mage,
priest, rogue, shaman and warrior files use (the 1.77.3 changelog has the
list). Abilities are still found by name in your own spellbook. What changed:
- **Auras that are not your spells** are read by id: Weakened Soul, Fire
  Vulnerability, a Frostbite freeze, Fingers of Frost, the Arcane Blast stack
  and Maelstrom Weapon.
- **The cat and bear versions under one name** (the cat's Swipe, Season of
  Discovery's Mangle) are filed under `Swipe (Cat)`, `Mangle (Cat)` and
  `Mangle (Bear)` (`spellbook.lua` `FORM_NAMES`).

### The rotations against the Forever guides (1.80.0, JCore 1.8.12)

Every class's lists were set beside the published Forever guides (Icy Veins,
wowtbc.gg, Mobalytics) and checked against the Forever client's own spell
tables. What that changed:

| Class | Fixed | Added from the guides |
|---|---|---|
| Warlock | Forever calls Curse of Agony **Bane of Agony** (same ids), so no Agony was ever cast there; every profile asks for the Forever name now. A defensive Drain Life drained *you* (refused); it drains the enemy. Improved Drains and Soul Siphon count as Improved Drain Life | Curse of the Elements on elites, bosses and 30 s fights, beside the Bane (Forever only: on Era Agony is the curse). Wrack as Affliction's filler |
| Priest | Levelling Renew was recast every 3 s under 65% while it ticked (`and` before `or`). Holy and Discipline: Greater Heal and Heal never fired while Flash Heal could | -- |
| Paladin | Holy Light never fired while Flash of Light could | -- |
| Shaman | An Elemental kept no shield (Water Shield is a Restoration talent on Forever). Healing Wave and Chain Heal never fired while Lesser Healing Wave could | The best weapon imbue out of combat when the main hand's runs out (Windfury, Flametongue, Rockbiter). Fire Nova on two or more while a fire totem is down. Chain Heal when two or more are hurt |
| Mage | -- | Arcane Missiles on a Missile Barrage proc (400589), every profile. Pyroblast at three Heating Up stacks (400625). Frostfire Bolt before Fireball. Ice Lance on a freeze while levelling |
| Hunter | Traps waited for the fight to end; Forever lays them in combat, so Survival's Explosive Trap can fire | Summon Hawk, two kept out (levelling and Beast Mastery), and Arcane Shot holds its shared cooldown for them. Strider Kick and Mongoose Bite first for Survival in melee |
| Warrior | A stance change looked 25 rage cheaper than it was (Era keeps 5 a point of Tactical Mastery; Forever keeps 10 plus 5 a point of Improved Tactical Mastery). The class window put Battle Shout back only once gone; it refreshes it in its last 10 s, as its tooltip said | Victory Rush in every list. Rend first for Arms with Bloodthrill |
| Druid | Berserk's burst window read the class's mana: no window under 35% energy or rage. A bear tank from 29 to 39 was never put into Bear Form (only Dire Bear Form was tried). Regrowth went out ahead of Swiftmend and Healing Touch | Shifting Power under 60 energy. Wild Growth when three are hurt |
| Rogue, druid cat | JCore zeroed counted combo points on every target change; Forever's guides say they stay. Kept now, and zeroed when the client says "requires combo points" | -- |

Left alone, and why:
- **Rogue poisons.** The loader can use an item on you, a unit or the ground, not
  on an equipment slot, so a poison cannot be put on a weapon from here.
- **Season of Discovery runes** in the lists (Crusader Strike, Envenom, Lava
  Lash, Mangle, Kill Command and others) stay: Era runs them, and on Forever an
  unlearned spell is never a candidate.
- **Mana on Forever** still reads 0 of 0 where the client says so; every mana
  line then reads full except just after "Not enough mana".
- Not built yet: Survival walking *into* melee, Call of the Elements (it drops
  the player's own totem bar), the Seal of the Crusader opener, Sniper Shot,
  Decimation's Soul Fire, Bane of Havoc, Eclipse.

### The 2026-10-06 core (1.82.0, JCore 1.9.0)

The loader's 2026-10-06 core (branch `lua_requests_06_10`) answers on Forever
much of what it did not before, and fixed a few reads on every classic build.
JCore 1.9.0 knows that core by the functions it added
(`world.client().core_20261006`, `.quest_ids`); on an older core every reader
below does exactly what it did in 1.81.0.

- **Your quests on Forever come from the game.** `modules/questlog.lua` takes
  the set from `core.quests.get_quest_log_quest_ids` on every rebuild (no
  Questie sweep), names and levels from the quest log's own rows (so Forever's
  own quests, which no Questie database has, are named), objectives from
  `get_quest_objectives`, and completion from `is_quest_complete`. A quest
  under a header you collapsed is kept while `is_on_quest` says you are on it.
- **"Ready to hand in" never showed on Forever.** Completion came from
  Questie's call, and both ways of reaching it were wrong there: the Questie
  addon's cache answers 0 for a quest that is ready (the `.api`), and JCore's
  quest database answered `true` / `false` where the code waited for Questie's
  `1`. On an older core a quest now also reads complete when every objective
  is finished, and JCore 1.9.0's database answers 1 / 0.
- **The quest ESP's live counts without the game Lua bridge.**
  `esp/forever_quests.lua` builds the same quest lines from the core's readers
  every 2 s while the bridge is not up (it has failed its probe on Forever
  since 2026-10-03), so the KILL / LOOT / USE chips and the quest objects
  follow your progress. Quest areas, the game's unit names and tooltip
  matches still need the bridge.
- **Aspects switch off on Forever.** JCore let `cancel_buff` through only where
  it worked; that core fixed it there, so *off* cancels the aspect.
- **Who holds a mob** (`targeting.lua`: `loose`, `tanking`,
  `engaged_with_me`) is threat status 2 or 3, or the scaled 100% the holder
  reads, not `is_tanking`. Before that core `is_tanking` compared a hardcoded
  offset on Era, MoP, Titan and the private servers, and `status` was 0 on
  every classic build; only the percent was right everywhere. On Era with an
  older core, a mob the wrong offset called yours is now seen as loose.
- Also from that core, with nothing to change here: `get_group_role` answers
  on Era, TBC and Forever (JCore's party rows already had the roles on
  Forever), the Skill window answers on Forever (JCore's skinning and
  gathering skill), the auction house works on Forever (Jambix Market).

### Vendor and quests on Forever (1.51.0)

Asked for on Forever, built only there: `modules/forever_npc.lua` is loaded
when `P.forever`, and the Automation page gets a **Vendor and quests**
section with three switches, all off until you turn them on. On Era the
module is never built and the page is unchanged
(`aio_boot_era_npc_test.lua`). Holding **Shift** as a window opens leaves
that window to you.

| Switch | What it does |
|---|---|
| Sell grey items at any vendor | At `MERCHANT_SHOW`, every grey item (`get_item_info` quality 0) with a sell price goes, one every 0.3 s, through `use_container_item` |
| Accept quests | A giver's offered quest is picked from the gossip list, and the detail window is accepted. Grey (trivial), repeatable and ignored quests are left: a repeatable one is usually a turn-in that spends something from the bags |
| Turn in finished quests | A giver's complete quest is picked first, the progress window continued, the reward window answered |

**Each sale is checked (by place since 1.54.0).** The bag and slot pair
comes from `inventory_helper`, and a wrong pair sells the item next to the
one meant. After every sale the plugin reads, straight from the client and by
guid, where every carried item sits. The item meant must have left its slot,
and no other carried item may have. If another one left, selling stops until
the scripts are reloaded, and the log and the trace name it, so it can be
bought back under the merchant's Buyback tab. Three sales that left their
item in place end the visit. Items with no `get_item_info` answer, or no
guid, are never sold.

*Why by place (first Forever session with it on, 2026-10-03).* 1.51.0 counted
items instead. On Forever a sold item stays in the player's item array
(`get_items_in_bag(0)` is that whole array, buyback included), so no count
ever fell:
- the first visit sold three grey items and logged them as "changed nothing";
- the next visit's recount then saw an item from the first visit move and
  stopped selling, naming a grey item that had in fact been sold correctly.

The API was not at fault: every namespace exposed the same functions as in the
earlier recordings, and the slot pairs named the right items. The first sale
of a session now leaves one trace line with the client slot it came from and
where the client put it: *sell junk: <item> left client slot <bag:slot> for
client slot <bag:slot>*. That line settles where Forever keeps sold items.

*Only the bags (1.66.2, Forever session 2026-10-04).* `inventory_helper`
reads bag 0 from that same array, from client slot 35 on, and does not
stop where the backpack does. The merchant's Buyback list comes back as
bag 0 slots past the backpack. After a reload, which forgets what was sold,
Broken Boar Tusk was offered as *bag 0 slot 39 (client slot 0:73)*. Three
such sales changed nothing, and selling gave up for the visit. The same
rows were also watched, so any real sale, which moves the Buyback list,
could have stopped selling as a wrong sale. Now a bag 0 row past the
backpack's size (JCore's `inventory.bag_slots(1)`, 16 when it cannot
say) is neither sold nor watched. One trace line counts them:
*sell junk: N item(s) past the 16-slot backpack (the merchant's Buyback)
are not in the bags; left alone*.

**The reward that fits.** No core call reads an item's stats from a quest
window, so the fit goes on what `get_item_info` does answer:
1. Gear the class can use, on classic rules:
   - the armour it should be wearing: mail for warriors and paladins before
     40 and plate after, leather for hunters and shamans before 40 and mail
     after; lighter or heavier armour does not fit;
   - its weapons and its shield;
   - a relic of its own.
2. That gear must not be below the item level worn in that slot. For rings
   and trinkets the weaker of the two worn is the one compared.
3. Among the gear that fits, these add to the score: an empty slot, the item
   level over the worn piece, quality, and the role's weapon. The role comes
   from the profile the talents chose: a tank wants a one-hander and a shield,
   a caster a staff, a hunter a bow or gun, melee a two-hander.
4. When nothing fits, the choice that sells for the most is taken.

A choice whose item data has not arrived is waited for up to 2 s. The pick
and why go to the log and the trace: *quest reward: took Leather Boots
(leather feet, item level 8 over 5 worn) for a hunter ranged, out of 3*.

**Seen working on Forever (recorder session 28, 2026-10-03):**
`get_item_info` (by id and by link; links are `|cnIQ1:|Hitem:...`),
`get_quest_item_link`, `use_container_item` at a merchant, `accept_quest`,
`complete_quest`, `get_quest_reward`, both gossip selects,
`select_available_quest` on the older multi-quest window (whose titles answer
there), and `get_item_at_inventory_slot`. Not yet seen: `select_active_quest`.
With no reward links, a reward window is taken with choice 0, which is right
for a quest that offers no choice.
Tests: `aio_forever_npc_test.lua` (module; its fake client keeps sold items in
bag 0's array, as Forever does), `aio_boot_forever_npc_test.lua` (whole plugin
as Forever).

### Experience bars on Forever (1.7.6)

The user: "a moveable EXP Bar that show's Exp/hour counts how much EXP going
to get and fills the bar once completed quests are Turned in and one that does
the same but for all quests in my Questlog". `modules/xpbar.lua` is built
when `P.forever`; its switches are on the Forever ESP page, section
**Experience bars**. The first version was a pair of JCore windows. The user
then asked: "Make it ESP not like a UI", "also more readable". So the bars
are now the ESP's own drawing on its HUD layer. They hide with the ESP's
switch, its toggle key and *RestedXP guide only*, like every mark. Your
experience is read on the bars' own timer, so the rate keeps counting while
they are hidden.

- **Two bars, each with its own switch, both on:**
  - *TURN-INS* (`xpbar_ready`): your experience in purple, and in gold what the quests you have finished add when you hand them in.
  - *QUEST LOG* (`xpbar_log`): the same, then in blue what the rest of your log adds.
- **Each is one dark plate**, the ESP's pill backdrop (soft where JCore has `plate_2d` and *Soft cards and bars* is on). All text has a dark rim, at *Text size* (`xpbar_text_size`, 16 px):
  - top: `TURN-INS  +1,350 XP  -> Level 19 (2%)`, with the XP per hour at the right end;
  - the bar: shaded stretches, the rested pool's end in blue, tenths ticked, and `18,500 / 19,400   95.4%` on it;
  - bottom: what is in the sum (`1 finished quest to hand in`; the log's `1 finished +1,350 XP | 1 to do +~1,350 XP`), with `Level in 1h 05m` at the right end.
- **Width:** *Bar width* (`xpbar_width`, 460 px) sets both bars. A bar is never narrower than its words need at the text size, and both stay one width.
- **A sum past the level** fills the bar. A strip under it shows how far into the next level the sum reaches.
- **The cursor on a bar** lists its quests under it (above it near the bottom of the screen), largest first, each with its pay. Hovering needs no mouse capture, so this works while the bars are locked. It is not shown while the cursor is on a JCore window.
- **Moving them:** *Move the XP bars* (`xpbar_move`, off). The ESP cannot take the mouse from the game, and a drag the game sees turns the camera and pins the cursor. So while the switch is on, a small JCore handle titled *Drag to move: TURN-INS bar* sits above each bar, and the bar follows it. Switched off, the handles go and the bars stay where they were left (`pos` in `jambix.aio.xpbar.json`). Until moved, they sit under the middle of the screen, two thirds of the way down.
- Handing a quest in fills the bar for real, and its gold goes.

**What a quest pays.** No client call says: `core.quests` has no reward
reader, and Forever's gamelua bridge is down. So the pay is worked out, in
this order:
1. **The table:** `modules/questxp_data.lua`, generated by `tools/jcheck/questxp_extract.js` from the QuestieDB in the Forever client (`support/Forever/QuestXP/xpDB-classic.lua`, the table Questie's QuestXP reads). It has 3,490 Classic quests as level and base xp. Exact on Forever: the recorder's two `QUEST_TURNED_IN` examples (quest 244 for 290, quest 65 for 1,350) are the table's numbers.
2. **Learned:** a quest the table lacks pays what it paid when it was last handed in, on any character, from `QUEST_TURNED_IN` (id, xp, money). It is kept in `jambix.aio.xpbar.json`.
3. **A guess, shown with `~`:** Forever's own quests (ids past 90000) are paid at what a standard quest of their level pays (`typical`: 850 at 10, 1,550 at 20, 2,450 at 30, 6,600 at 60). Once three guessed quests have been handed in, every guess after them takes the ratio they actually paid.

Then the level penalty Questie uses (cmangos'): full pay up to the quest's
level + 5, then 80, 60, 40 and 20%, then 10%, rounded as the server rounds.
Every table quest you hand in is also checked against its prediction. When
the median of the last few (in 6 hours) is 4% or more off, an xp buff or a
server rate, every table and learned quest is multiplied by it.

**Experience per hour.** Your experience is read twice a second, from
`core.character.get_xp` and `get_xp_max` (the 2026-10-06 core), or the
player's own `get_xp` and `get_max_xp`. What it rises by, across a level-up
too, is the session's. A level-up is the level going up or the level's need
changing. A read of 0 of 0 below level 60 (a loading screen) is skipped, and
so is a drop with neither, because Classic has no experience loss. The rate is what the last *XP per hour over the last*
minutes gave (`xpbar_rate_minutes`, 30), shown from the first minute.
*Start XP per hour again* (`xpbar_reset`) starts the session over.

Limits:
- The quest log is the one `modules/questlog.lua` reads (the bars sum `P.quests.index`). A guide's offered quests and failed ones are not counted. Nor is a quest for 10 s after it was handed in: the index drops it up to a second later.
- The levels a sum runs into past your current one use Classic's table: the bar's own level is the game's `get_xp_max`.
- At level 60, or when `get_xp_max` answers 0, the bars say *Max level*.
- Not yet seen in game.

Tests: `aio_xpbar_test.lua` (module), `aio_boot_xpbar_test.lua` (whole
plugin as Forever: both bars painted through JCore's draw queue with no
window, hidden with the ESP, the move handles as JCore windows).

### Auto-loot and gathering on Forever (1.54.0)

`world.lua`'s auto-loot, skinning and gathering read `P.esp.corpses()` and
`P.esp.nodes()`. Those came from the classic collector, which has not run on
Forever since the classic ESP was taken off it (1.41.0). So the
**Automatic looting** and **Gathering** switches did nothing there:
`loot_object`, `skin_object` and `use_object` were never called in 29
recorded sessions.

`esp/forever.lua` now fills the same two lists, and `esp/init.lua` hands them
out on Forever:
- **Corpses** within 12 yd: one that fought you (LOOT, as the ESP infers it),
  or one that can be skinned. Not one the client calls somebody else's
  (`is_tap_denied`), and not once a loot window opened beside it.
- **Nodes** within 12 yd: herbs, veins and chests, by their names.

The lists are filled whatever the display switches, ranges and mark limit say,
so hiding a mark does not turn looting off. They are only built while a
looting or gathering switch is on, and they add no reads: the ESP's own caches
answer. A corpse that dropped nothing keeps its LOOT, so `actions.lua`'s
blacklist (three tries, then two minutes) is what stops the retries. Era is
unchanged and still reads the classic collector. Tests:
`aio_forever_automation_test.lua`, plus the list wiring in
`aio_boot_forever_npc_test.lua` and `aio_boot_era_npc_test.lua`.

**The window opened, and the loot stayed in it (1.54.2).** The user, after
1.54.0: "still not looting from corpses". Session 31 showed:
- `loot_object` was called, and it did open the corpses. It walked the
  character up to one first: 3.8 yd, then 0.8 yd.
- `LOOT_OPENED` even said auto-loot, but the items stayed in the window.
  One corpse's window opened five times, with its Rough Stone still there
  the second and third time, and slot 0 (the coins: slots are 0 based, and
  the money comes first) on every one.
- `world.lua`'s stuck-window closer shut it each time (`close_loot` from
  line 137). The corpse kept its loot, and the retries ran into the
  blacklist.

So on Forever the loot-window tick now takes the slots itself, with
`core.input.loot_item`. That happens in up to two passes, about 0.3 s and
1.3 s after the window opened (it is not filled on the frame that opens it),
and only then does the closer get its turn. Each pass covers slots 0 to the
count minus 1, as the `.api` numbers them (1.78.2, JCore 1.8.11). Until then
it ran to the count inclusive, for a client that counts from 1; the loot study
showed Forever counts from 0, and `loot_item` raised "specified invalid slot"
for the extra one. The trace says what happened:
- `loot window: 2 slot(s): Rough Stone, coins; took slots 0-1 (pass 1)`, then
- `loot window: emptied after 1 pass(es)`, or
- `loot window: closed with N slot(s) left after 2 pass(es)`.

`loot_item` had never been called on Forever, so that line is how the
next session shows it works. Era is unchanged: no `loot_item`, and the
same closer. Test: `aio_forever_loot_window_test.lua` (slots from 0 and none
past the window, a window that will not empty, Era).

### Names, ranks and other people's mobs on Forever (1.52.0, JCore 1.5.15)

Two things the Forever ESP and the rotation could not know until now: what a
creature is called and whether it is elite, and whose mob it is. The first
recording after client patch 1.60.1.70205 (session 26) and the client's own
cache folder answered both.

**The client's creature cache.** `get_name` is "" and `get_classification`
0 for every unit on Forever. The client, though, keeps the server's
description of every creature it has met in
`Cache/WDB/enUS/creaturecache.wdb`. That is inside the client folder, so the
loader can read it. JCore 1.5.15 reads it (`ctx.creatures`, see the JCore
README) and gives, by npc id:

| Field | Example (from the real file) |
|---|---|
| name | 705 Ragged Young Wolf, 267279 Cadoc Winterheart (a Forever-only id) |
| title | Cadoc Winterheart: *Mountaineer's Assistant* |
| type and family | the Imp: demon, imp family; Small Crag Boar: beast, boar |
| classification | 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare |
| quest items it drops | Ragged Young Wolf: one |

The client writes the file when it exits, and a new build wipes it. So it
knows what EARLIER sessions saw: today's 16 creatures, after the patch.
What it gives:
- **Forever ESP:** a name for a mob never cast at, and for town npcs (with
  their title, `<Weapon Merchant>`). An ELITE / RARE / RARE ELITE / BOSS
  pill, and the page's Elites, Rares and Bosses rows with their switches and
  ranges. An elite, rare elite or boss coming at you is a threat and an
  alert ("Elite", "Boss") whatever its level. The `fesp` lines carry
  `rank=` and the source `(cache)`; the frame line carries `creatures=N`.
- **Rares the cache has not met (1.7.5).** When the cache gives no rank, the
  Forever ESP asks the game (`get_classification` answers there since the
  2026-10-06 core), and failing that `modules/rares_data.lua`: 421 rares and
  rare elites by npc id. Classic's 398 come from the QuestieDB in the Forever
  client; Forever's own 15 (Matriarch Bristlefur, Snarlsnout, the Zephras Isle
  set...) and 8 of Season of Discovery's (Mokwa, Raluk...) are listed by hand
  in `tools/jcheck/rares_extract.js`, which writes the file. A rank the game
  does give wins (the list says rare elite for VanCleef; Forever says elite).
  `rank=4/list` in the `fesp` lines says where a rank came from (`cache`,
  `game`, `list`). Only the ESP reads the list: targeting, the field and the
  reactions still take JCore's rank.
- **The rank in words (1.7.5).** Every rank says so after the name, in its
  category's colour: **ELITE**, **RARE ELITE**, **BOSS**, **RARE**. It shows
  at every detail and with or without the art pack, beside the dragon ring
  or skull; the rank switch (*Elite, rare, boss*) turns both off. Forever
  never answers 3: its dungeon bosses are elites the client flags `is_boss`,
  and the ESP marks those BOSS (`rank=3/cache+boss`). A rare elite with
  `is_boss` (Marisa du'Paige) stays a RARE ELITE.
- **Rotation and reactions:** the target's elite / boss / rare flags
  (`react/world.lua`), the field's elite count and BOSS shape (`field.lua`),
  and target selection pushing elites down (`targeting.lua`) all read the
  cache's rank where the client said 0. The reactions' lessons name mobs
  from it.

A cast-learned name still wins over the cache's.

**Somebody else's mob.** `is_tap_denied` answered false on everything until
the patch. Since then it answered true on the strangers' fights the recorder
caught and on 26 corpse reads, and false on all 40 corpses we looted. A true
read is believed. A false one proves nothing, since false was the only answer
before, so the old inference stays (in combat with a player outside the
group, none of your threat). With it:
- **Forever ESP:** the mob is `tapped` and grey, and its corpse never says
  LOOT.
- **Reactions:** it is *someone else's fight*: no Kick, Gouge or Scatter Shot
  that would only pull it onto you.
- **Target selection (Forever only):** such a mob is never picked: one the
  client calls tap-denied, or one fighting a player or a stranger's pet
  outside your group and not you. Out of combat the score loves a nearly
  dead mob most, and on a busy beta realm that was usually somebody else's
  kill.

Era: none of it runs. The cache is never opened, `is_tap_denied` is not read
by these paths, and target selection scores exactly as before.

Tests: `jcore_creatures_test` (the real file, built records with every rank,
a record that does not add up, the service finding the file),
`jcore_era_client_test` (never read on Era), `aio_esp_forever_test` (names,
titles, rank pills and rows, the elite alert, the tap read),
`aio_react_test` (rank and tap on Forever, not on Era),
`aio_targeting_forever_test` (somebody else's mob, the cache's elite, Era
unchanged).

### Spells you have not learned on Forever (1.52.1)

The user: "Stop trying to use spells that aren't learned -- we need to be able
to identify these things." The AIO spellbook (`modules/spellbook.lua`) walks
`get_spells` and asks `is_spell_known` about each id. When that said no, it
asked `has_spell` as well and took a yes. The API notes say only the
private-server path leaves out the book's FUTURESPELL rows, and Forever walks
the book natively. A spell the book shows but you have not learned could get
in that way. Anything that casts on `known()` alone would then press it: the
Aspects window and forms. The rotation's rules and the reaction engine were
safe, because they also ask `ready()`, and JCore's `spells.ready()` already
takes `is_spell_known`'s no as final.

**On Forever a no from `is_spell_known` is final now.** The recorder has it
answering every id there (true 2,803 times, false 566, never raising), so
`has_spell` is no longer asked. Era keeps the fallback, which exists for builds
where `is_spell_known` is not implemented for some ids.

**What the client called learned is in the trace.** Every refresh that
changes the answer writes one line:

    spellbook: 14 known: Aspect of the Hawk, Attack, Auto Shot, ...; not learned, left out: Arcane Shot 900001

A spell that only `has_spell` vouched for (Era) is listed after `known only by
has_spell:`. If a spell you have not learned still shows under `known`,
`is_spell_known` itself says yes for it on this client. That spell is the next
thing to chase. The array positions `get_spells` hands back (1..N, GM spells
nobody has) are never listed.

Test: `aio_forever_unlearned_test` (a Forever hunter whose Arcane Shot
`is_spell_known` denies and `has_spell` vouches for: left out, never pressed,
named in the trace; the old module fails it).

**And never a candidate (1.54.1).** The user, after 1.52.1: "again its trying
to use spells on the reaction that isn't part of my spellbook". The book was
right by then (the trace listed the 16 spells the hunter has), and nothing
unlearned was ever pressed. But the reaction rules still OFFERED spells by
name. The engine refused each one at validation ("not trained"), and the
refusal was what showed: "Other candidates: Vanish 110", "rejected Vanish:
not trained", "Refused Vanish: not trained" in the window, and a [reject]
line in the journal. The rotation's walk did the same with its rules, listed
as "(not usable)". Now an unlearned spell never becomes a candidate at all.
The engine's `offer()` drops a spell (or aspect) the book does not know,
and the walk skips a rule whose spell it does not know (one rank of a
prefix line is enough). What is pressed has not changed; what is listed,
refused and logged has. Tests: `aio_react_test` and `aio_rotation_test` ("not
learned ... (1.54.1)"; both fail on the old engine and walk).

---

### Quests from the game on Forever (1.53.0, JCore 1.5.16)

Asked for on Forever: the active quest objectives, then ESP on where the
quests are and on the mobs that are objectives or drop the items. Forever's
client reports an empty quest log to the core and has no Questie, so until
now only quest givers and kill counts heard from objective messages could
be marked. The game itself knows everything, so this reads it there. JCore
1.5.16 bridges to the game's own Lua (`ctx.gamelua`, see JCore's README), and
`esp/forever_quests.lua` asks through it. This is Forever only: the bridge is
inert everywhere else, and the Classic quest ESP above is untouched.

**The first Forever session said no (2026-10-03, 14:18).** All three probes
failed the same way. `core.execute` returned nil. `read_lua_string` answered "" for
the global it had just set, and also for `ERR_QUEST_ADD_KILL_SII`, a GlobalStrings
constant every client has. `read_lua_integer("WOW_PROJECT_ID")` answered 0. So
on this loader the read_lua calls do not reach the game's globals, and
nothing showed whether execute runs at all. The bridge turned itself off
("gamelua: off for this session") and every quest mark stayed as it was.
Everything below waits for a route into the game's Lua that works.

| Every | What it asks the game | What it becomes |
|---|---|---|
| 2 s | the quest log (C_QuestLog, or the classic calls): quests, complete, each objective's type, text and x/y | the objectives the KILL / LOOT / USE chips and the quest objects read; the quests you are on |
| 2 s | your map and where you stand on it; each quest's area (GetQuestsOnMap, QuestPOIGetIconInfo, GetNextWaypoint) | quest areas as world positions |
| 0.75 s | every nameplate, your target and mouseover: guid, name, UnitIsRelatedToActiveQuest, tooltip lines; the nearest mobs without one by guid (tooltip by "unit:" link); the names of quest items asked about | which mob is which quest's objective, with its progress; the game's name for each unit; item names |

**On the mobs.** A mob whose tooltip names one of your quests, followed by an
objective line, is a quest mark. The chip says what that objective needs:
KILL 2/8, LOOT 1/6 or USE 0/1. The quest's title is under it, and the game's
own name is on top. A mob the game only calls "related" gets QUEST. A mob
whose KIND drops an item an unfinished objective wants gets LOOT n/m. That
comes from the creature cache's quest items (JCore's creatures, by npc id),
with the item's name asked of the game. The name match from objective
messages stays as the fallback. Names learned from the game are kept by npc
id like any other.

**The quest areas.** Each quest's area is drawn as a ring on the ground, a
line from you towards it and its title with the distance. A complete quest's
turn-in is drawn in green as "TURN IN: ...". It uses the Quests page's
existing settings: *Point to the nearest known spawn* (the lines), *Only for
spawns within*, *Line length*, *At most this many paths*, *Draw paths in
dungeons and raids*, and *A live target beats a map marker*, which hides a
quest's area while one of its mobs is marked on screen. A label is drawn
only for a point in front of you, because a point behind the camera
projects mirrored. **The map-to-world conversion is checked on you first.**
Your own map position, converted with `get_world_pos_from_map_pos`, must land
within 25 yards of where you stand, either way round (the axes are taken
swapped if that is what fits), or no area is placed at all.

**What the next Forever session will say** (`scripts_data/jcore/jcore.trace.txt`):
- `gamelua: ready: execute reaches the game's Lua ...` means the bridge works.
  `gamelua: off for this session: <why>` means it does not, and every mark is
  as it was before 1.53.0.
- `gamelua: census: ... missing: ...` lists which of the game calls this client
  lacks.
- `fquests: log: N quests via C_QuestLog, map M, conversion direct (x yd), K areas from P points`
  shows what the log answered. `errors: ...` names a part of it that raised.
- `fquests: units: N answered (by nameplate, by guid), R on a quest` shows the units.
- the `fesp frame` line ends with `places=N`, the quest areas drawn.
The full probe is in `scripts_data/jcore/jcore.gamelua.json`.

Tests: `aio_forever_quests_live_test` (the module's real game-side code
against a scripted game through the real bridge: the log, kill and item
objectives, a mob's chip and name, a drop, areas both axis orders, a refused
conversion, a failing part, no bridge) and two in `aio_esp_forever_test` (the
chip, the quest under it and the hidden area; the ring, line and label, and
the switches).

### Quest objects from the start (1.59.0)

The user, 2026-10-04: world items that quests want should show on the ESP, from Questie's data if needed. They already showed, but only after the first one was picked up. Until then nothing marked them.

- **Why.** The Forever ESP knew a quest object by its name only. Either the client tagged it "(Quest)", which has not been seen lately, or an objective the game had already reported named it. "Bundle of Wood: 1/8" arrives after the first bundle, so that one was never marked. A Shimmerweed Basket, whose progress names the Shimmerweed inside it, was never marked at all.
- **Now.** `esp/forever_quests.lua` also asks `quests.lua`'s index, by the object's name. The index knows the quests you are on (the questlog's `is_on_quest` sweep), and from JCore's questdb (QuestieDB's data) the objects each quest's objectives name and the objects that hold an item it wants. The object's item is looked up too, because the progress message names the item. The mark says COLLECT or USE from the start, gets its count once the game reports one ("COLLECT 1/8"), shows the quest's title under it with Details on, and goes when that objective is done, the quest is complete, or it is turned in.
- **Limits.** Forever's own quests (ids past 90000) are not in the database, so their objects are still found by name after the first progress message.
- **To verify in game.** A trace line `fquests: db: Bundle of Wood is wanted by A Bundle of Trouble (5545): COLLECT, no progress heard yet`, once per object and quest. `F.quests.stats().db_objects` counts the objects marked this way.

Tests: four in `aio_esp_forever_test` (the bundle before and after progress and at 8/8; the basket counting its item; a USE objective done by its own text; turned in, and quest marks off).

### Auto-loot that opens the corpse (1.55.1, 1.55.2; JCore 1.6.1)

The user: "the autoloot from corpses does not work". 1.55.1 traced every attempt (`auto-loot:` lines: the corpse, its distance, the attempt, what followed; and, every few seconds while a corpse is listed but not looted, why: blocked, out of reach, waiting). The first traced session showed it: three `loot_object` calls within two seconds at a corpse 3.7 yd away, the first walking the character onto it, no window from any, then the two-minute give-up. On Forever `loot_object` does not open a corpse. 1.55.2 opens it through JCore (`ctx.loot.open`), which uses the right-click's interact there and keeps whichever call is followed by a window, and does not press again while an attempt is walking or waiting (`ctx.loot.opening`). Era calls `loot_object` / `skin_object` as always. Tests: `aio_autoloot_trace_test`, `jcore_names_loot_test`.

Corrected by the 1.55.2 trace (JCore 1.6.2): the interact never opened a corpse, and `loot_object` does when it is pressed once and waited on. The earlier failures were three presses within two seconds, each cancelling the one before. So `loot_object` is now tried first.

### The icon card (1.69.0)

The user, 2026-10-04: "rework ESP ... cleaner, more in-game icons, nothing
double/repeating itself, better customization of Simple and Advanced". They
chose an icon card, a Style and a grid of what to show, and Forever first.
The Classic ESP is unchanged: it moves to the same card in a later pass.

**A mark is a card** (`modules/esp/card.lua`): rows of the game's own icons
beside ONE pill of text, never an icon on a pill (the loader paints textures
under every shape). Words only for names, numbers and quest titles.

| Fact | Before | Now, once |
|---|---|---|
| What it is | creature portrait, and its type as the name when the name was unknown ("Elemental") | the creature-type icon, class crest, town-service icon or quest giver's ! / ?; an unknown name is not said again |
| On you / your pet / your group | red or amber ring, a line, an "on you" pill, and "aggro #1 of 1" | the ring and the line; a row only with the ring switched off |
| Elite, rare, boss | ELITE pill, category colour | the target frame's dragon ring (gold elite, silver rare, dark silver rare elite) or its skull |
| How it fights | MELEE pill | sword, bow or staff icon (faded when it is a guess) |
| Health | bar and "100%" | the bar, once hurt; a number only when asked for |
| In combat | "in combat" pill with swords | the combat swords, and only when it is fighting someone else |
| Threat | every engaged mob, "threat 0%" solo | only in a group |
| Quest | KILL 2/8 pill, then the title | attack / loot / use cursor, 2/8, the title: one row |
| Corpse | LOOT and SKIN pills with icons | the bag and the pelt, and the distance |
| Herb, ore, chest | icon, name, distance on two rows | icon, name and distance on one line |
| Cast | name, time, bar | the spell's icon, the shield when it cannot be interrupted, name, time, bar |
| Town npc | name, <title> | its service icon (repair anvil, flight boot, inn, bank, trainer ... from npc flags), name, <title>; no level |

**The art is the plugin's own.** `modules/esp/art_pack.lua` carries one PNG
atlas (78 cells of 32 px plus the status-bar texture, 288 x 372, 185 KB) as
base64. `modules/esp/art.lua` writes it once to
`scripts_data/jambix_aio/art/esp_<version>.png` (an older version's file is
deleted) and registers it with JCore as the atlas `jambix_esp_art`. It is
generated offline from the Era archives:

    node tools/jcheck/art_pack.js        # rewrites art_pack.lua, preview in tools/jtest/out

Add an icon by adding a row to its ENTRIES (cursor, icon or ui mode; the cursor
pointer's gold corner is masked) and rerunning. This replaces the Forever ESP's
old icons, which were PNGs cut into THIS machine's
`scripts_data/jcore/game_icons/forever`: the players the plugin is given to
never had them. `esp/forever_icons.lua` and its extractor test are gone; that
folder is unused. With no art at all (the write failed), every mark falls back
to its words, and the ESP page's live lines say why.

**How much a category says** is its own dropdown, `<key>_detail`: Everything;
Icon, name, health and casts; or Icon only. Critters start on Icon only;
pets, party members and friendly players on the middle one.

**The Style** (`esp_style`) writes every piece at once. A piece changed by hand
makes it Custom, but only when the pieces really differ from the Style, so a
menu host that reports the Style's own writes a frame late cannot undo it.

**Moved once** (migration `esp_card_1:<page>`): "Health as a number" was on by
default and now is not (the bar says it); a value still at the old default is
switched off, and the Style is set to whichever style the pieces read as, else
Custom. New ids: `esp_style`, `show_icon` (replaces the class-icon and
creature-icon switches on Forever), `show_title`, `show_corpse_name`,
`<key>_detail`.

**Fixed on the way:** an objective the game tags as found ("Roiling Winds
destroyed: 4/6") on a mob you can attack is a kill.

**Unverified in game:** the look, the icon size (text size + 5 px), the atlas
loading through scripts_data (the same route as the web icon cache, which works
there), and npc flag bits other than vendor + repair (4224, recorded).

Tests: `aio_esp_card_test` (new, 5), `aio_esp_forever_test` (8 new, the rest
updated to the card), `aio_esp_split_forever_test` (the page, the Style, the
migration, the art pack through JCore's asset registry).

### Telegraphs (1.65.0; JCore 1.8.0)

**1.69.1: the edge's glow, not the fill, was painting the disc solid.** The user, of a 5 yd Throw Dynamite in a dark cave: "u cant see shit with it".
- **Measured off the screenshot.** Going in from the edge, the colour was 92% of full at the edge, then 85%, 75%, 64%, 54% and still 45% two thirds of the way in. That is linear in the distance from the middle, on top of the 15% fill.
- **Why.** The native `circle_3d` glows inward from its edge by alpha × (d / r) ^ fade, and JCore's `draw.circle_3d` passes a fade of 1.0 when none is given (the native default is 2.5). With fade 1 the glow covers the whole disc. The sweep ring (alpha 200) did the same over the middle. The Forever ESP's rings hit this in 1.66.2 and moved to a fade of 6.
- **The fix** (`fade_for` in `modules/telegraphs.lua`): every ring is given the fade that solves (1 - band / r) ^ fade = 1/4. That keeps the glow to a band of fixed width whatever the radius: 0.5 yd for the edge, 0.3 yd for the sweep. The fade is clamped to 2.5-128, and a ring under twice its band keeps 2.5. For 5 yd that is a fade of about 13. For 30 yd it is about 82.
- JCore's default was left alone. Its other callers draw small rings (0.7-1.5 yd), and no one has said those look solid.
- Cones were not affected. Their edges are `line_3d` lines, whose fade only softens the line.

**1.65.1: danger only, see-through, raids and dungeons.** The user, after asking for safe zones and then taking it back: "it suppose to be the unsafe zones we highlight", and "it shouldnt be Full one color cant see other mobs or myself in it". Only the danger ground is drawn, never safe ground.
- **Why it was solid.** 1.65.0 drew a second, denser fill that grew over the first as the cast ran. By the end it was about two thirds opaque.
- **The fill.** It is now the only fill. "Fill strength" is on the simple page, 0-50% with a default of 15%, and is capped at half whatever value is saved. A value still at 1.65.0's default of 25% is moved to 15% once (`tele_fill_15:<page>` in the migrations store). Any other saved value is left alone.
- **Progress** is a thin line sweeping out to the edge, so mobs and you stay visible in it.
- **Cones** are drawn from their own points (a fan polygon, the two edges and the arc). The fill and the outline are therefore the same shape whatever angle convention the native `cone_3d` uses.
- **"Show telegraphs in"** (`tele_where`, `cfg.TELE_WHERE`) offers Everywhere (the default) or Raids and dungeons only.
- **A heavier edge** marks a boss's mechanics: classification 3, or a spell a boss mod warns of.
- Classic dungeon bosses are elites, so "Elites, bosses and boss-mod spells" is the choice that covers them. DBM's dungeon pack (DBM-Party-Vanilla) is not installed, so dungeon spells have their shapes but no DBM advice.

The user, 2026-10-04: "using DBM Addon and any other possible addons out there let's import things needed to build our own Telegraphs system Into AIO".

**What a player sees.** When an enemy starts a spell that hits an area, the ground it will hit is painted on JCore's DANGER layer. A circle goes around the caster or where it aims, a cone in front of it. A see-through fill and a crisp edge show the area. A thin line sweeps out from the middle to the edge as the cast runs (a ring for a circle, an arc for a cone). It turns red while you are standing in it, and a boss's mechanics get a heavier edge. A label names the spell, gives the boss mod's advice ("Dodge", "Run out", "Breath: get out of the front") and the seconds left. A short stack at the top of the screen covers what has no ground to paint: a circle as big as the room (Bellowing Roar), a spell whose point the client does not say (a player's Blizzard), a hazard on you (Chill, Living Bomb), and whatever you are standing in right now. Missiles get a circle where they land, filling as they fly. Ground that stays bad after a completed cast (Flamestrike, Consecration) stays painted for the spell's duration.

**Where the data comes from.** All of it is imported offline by `node tools/jcheck/telegraph_extract.js` into `scripts_data/jcore/telegraphs/{vanilla,forever}/`:
- **The game's own spell tables are the authority on geometry.** SpellEffect, SpellRadius, SpellTargetRestrictions, SpellMisc, SpellCastTimes, SpellDuration and SpellName are read out of the CASC archives (`tools/jcheck/lib/casc.js`) and decoded with WoWDBDefs (`lib/db2.js`, `tools/jcheck/dbd/`). An effect aimed at an enemy area is a shape:
  - target 15: a circle around the caster;
  - targets 16 and 28: a circle at a destination, set by 18 (the caster), 53 (the target), 87 (a ground point) or 17 (a fixed point we cannot see);
  - targets 24, 54 and 104: a cone, with ConeDegrees (default 60).
  - Effects 27 and 179 leave the area on the ground for the duration. A spell with no shape of its own takes the shape of the spell it triggers (Whirlwind).
- **DBM** (every pack whose TOC says `X-DBM-Mod-Category: Classic`: DBM-Raids-Vanilla and DBM-Azeroth) is parsed with luaparse, never run. It gives, per spell:
  - the warning kind (NewSpecialWarningDodge, Run, MoveAway, GTFO, Interrupt and so on);
  - the voice keys it plays (watchstep, runout, breathsoon...);
  - role filters, combat-log events, cast timers and cooldowns;
  - per mod, creature ids, encounter and zones.
- **Plater's script library** files spell ids under cast scripts ("Cast - Frontal Cone"). Only ids the client has are kept, which today is none (they are retail ids).
- The danger level is 1 for spell tables alone, 2 when a boss mod warns of it, and 3 when a boss mod says move.

**Who draws what.** JCore owns the reading (`services/telegraphs.lua`, see its README) and `modules/telegraphs.lua` only paints. It reads nothing from the game and is inert on a JCore older than 1.8.0. The render job sits at priority 120 and follows the overlay's switch and toggle key, and is hidden by "RestedXP guide only".

**Counts (2026-10-04).** Era 1.15.9.70003: 2,413 spells, 2,037 with a shape (187 cones, 138 leaving ground), 640 named by DBM, 49 hazards. Forever 1.60.1.70205: 2,632 spells, 2,258 with a shape.

**Not done yet.**
- Dynamic objects and area triggers already on the ground before you arrive: nothing reads them yet.
- Onyxia's Deep Breath: the spell tables fix its destination in the database, not in the world, so it is an alert, not a lane.
- Instant casts on Forever: no cast bar and no combat log there.
- The rotation does not move you out yet. `ctx.telegraphs.on_me()` and `danger_at(pos)` are there for when it should.

**To verify in game.**
- JCore's Core page shows a `telegraphs:` line once data has loaded.
- The log says `telegraphs: N spells (...) for <build>` on the first enemy cast.
- Every live telegraph sends a `jcore.telegraph.started` event.

Tests:
- `jcore_telegraphs_test`: the data, cones, placed and locked ground, ground left behind and cut short, players' unplaced spells, wide circles, missiles, hazards from auras and the log, cost, and Forever's copy.
- `aio_telegraphs_test`: the whole plugin as Era with Onyxia's Flame Breath; the cone, label and alert, then the switches.

### Quest marks only for what is still wanted (1.64.1)

The user, 2026-10-04: quest ESP kept marking things after the quest showed "Quest Complete", and kept marking a mob whose drop was already collected while the quest still waited on another mob's drop.

- **Why.** `quests.lua` filed every Questie target of a quest (kill mobs, the mobs and objects that drop its items, the objects to use) while the quest was not complete, whichever objective each one served.
- **Now, per objective.** `questie_targets` also returns `groups`: one per Questie objective, `{ name, npcs, objects, collect }`. The name is the item's name (`query_item_single(id, "name")`), the object's, or the objective's text. The index files a group's targets only while that objective is not done. An objective's state comes from:
  - the quest log, matched by subject: "Kobold Vermin slain" matches "Kobold Vermin", plurals too;
  - on Forever, where there is no quest log text, the progress messages (`esp/forever_quests.lua` `M.progress(name)`, from "Gold Dust: 8/10").
- **Every objective done** means the quest counts as complete, so its turn-in is marked instead.
- **A kill objective Questie gives no name for** is checked at the unit: its own name against the quest's objectives (`quest_entries` drops a `kill` entry that is not `named` once that objective is done).
- **Also cleaned up:** `is_questie_id` is false for an npc only finished objectives want, and the spawn paths (`nearest_spawn`) lead only to targets still wanted.
- **Unchanged:** an objective nothing reports on stays marked, as before. On Forever an objective clears only once a progress message for it has arrived this session.
- The index rebuilds on `UI_INFO_MESSAGE` too, since that is how progress arrives on Forever.

Tests: four in `aio_quest_tags_test` (one drop collected and the other not; all done, so the turn-in is marked; an unnamed kill objective done; Forever's progress messages).

### Hunter kiting off by default (1.64.1)

"Run and shoot before there is a pet" (`rot_hunter_kite`, the Hunter section and the class window) now defaults to off. The menu saves a default as the player's value, so a new default alone would change nothing for anyone who has played. It is switched off **once**, a second after load, and noted in `jambix.aio.migrations.json` (`hunter_kite_off`), the same way the critters were. After that the switch is the player's again. Tests: `aio_boot_kite_off_test`.

### The menus: Simple or Advanced (1.64.0)

This is the second half of the user's "reorganize all the menus", where the answer was "both": fewer, clearer pages AND a simple/advanced split.

- **One switch, "Show advanced settings"** on the Overview page (`show_advanced`), off by default. `P.advanced()` reads it.
- **Hidden in Simple:**
  - whole sections: ESP Performance; ESP "Look and placement" (the second-line, placement, plate, bar, colour, portrait, tag and game-art rows, now a section of their own on the same page); Rotation Tuning, Cooldowns and Reactions; Automation Safety checks;
  - single rows: ten advanced elements (raid marker, icons, mana bar, details, status, threat, node rings, reach, target lines), per-category ranges and colours, the alert level and cooldown, the cast-slack timings, the spell-window sizing, the target-switch margin, vanish memory, narration verbosity, warning thresholds, the loot-window timings, `objects_include`, fishing timing and item ids, the quest-path styling, and the RestedXP waypoint fine-tuning;
  - the Rotation page's class sections (threat, stances, wand, healing, pet, "<Class> options"): they are in each class's window since 1.63.0, and in the menu with advanced settings on.
- **Hidden is not off.** Every value still reads as set.
- **Nothing moved page.** A widget's saved value is keyed by its page path, and the menu host's own docs warn that moving one orphans its value and resets it. So the "Hardcore alerts" section stays on the ESP page, `objects_include` stays on Automation, and Fishing stays its own page. Merging pages needs a one-off migration of every moved value, which is the user's call.
- The Cooldowns section's last two labels named switches removed in 1.39.0; they are gone.

Tests: `aio_boot_advanced_test`. The test mock menu now records each widget's options, and `menu:visible(path, id)` answers them.

### Options and status in the class window (1.63.0)

Under its groups, each class window holds that class's settings, with the same ids and values as the Rotation page.
- The window reads each value with `P.opt` and writes it with `P.pages.rotation:set`, so the menu stays the one place a value lives.
- **What to keep up while the rotation is paused** (1.7.5): every class's window, and the Rotation page's Class window section (`classwin_paused`).
- **Shared options** appear by the class module's capability flags: threat (`tank_capable`), stances and forms (`uses_forms`), wand (`wand_capable`), healing thresholds (`heal_capable`), and the pet's mode with its two focus buttons (`pet_capable`).
- **The class's own options:** hunter kiting, step-out, *Hunter's Mark on* and *Serpent Sting on* (1.84.0), the rogue's "Stealth by itself", and the warlock's Healthstone, Soulstone and shard limit. So the rogue's window shows even with no buff to switch.
- **A status line** under the switches: the rotation on or off, the profile, and the stance or form. It sits under them so the hunter's aspect switches keep their place at the top.
- `P.pages` names every menu page. The data is `OPTIONS` in `classwin_data.lua`. Tests: three more cases in `aio_classwin_test`.

### Every class gets its own window (1.62.0)

The user, 2026-10-04: "let's reorganize all the menus!! each class should have its own UI for things like Hunter does for aspects!" Asked what a class window should hold, they answered: both hand-switched buffs and the class's options with a live status. This release is the window and its buffs; the options, the status and the menu regroup follow.

`modules/classwin.lua` is the engine and `modules/classwin_data.lua` holds what each class has. A group appears only once one of its spells is trained. Each group is one of three kinds:

- **pick**: one of a set, picked from a dropdown. The sets are the paladin's aura, seal, blessing on you and Righteous Fury; the mage's and warlock's armor; the shaman's shield; and Shadowform.
  - **Auto** is the default: the rotation decides, exactly as before, and the window keeps nothing.
  - A spell picked here is kept up, and the rotation casts none of the set.
  - **None** keeps none up, and the rotation casts none either.
- **keep**: one buff, on or off, defaulting to what the rotation kept up: Battle Shout, Fortitude, Inner Fire, Arcane Intellect, Mark of the Wild and Thorns are on; Shadow Protection, Trueshot Aura and Omen of Clarity are off. The window owns these buffs either way.
- **form**: the warrior's stance, or the druid's form, with Auto. A stance or form picked here is what the rotation's form keeper (`forms.maintain`) holds instead of the profile's. While the rotation is off, the window holds it itself, with *Everything picked here* (1.7.5).

The window follows these rules:
- **When it acts.** A default that nobody has changed acts only while the rotation runs, which is when the rotation used to cast these. A choice made in the window acts whenever the plugin is on, as an aspect does.
  - **Since 1.7.5, only as far as *While the rotation is paused, keep up* allows.** A player asked for "a setting to stop auto applying seal even when rota is paused". A seal lasts 30 s, so a picked one was recast twice a minute with the rotation paused; shields, shouts and stances went out in fights played by hand.
    - *Out-of-combat buffs* (the default): out of combat only, never a seal (`fight = true` in `classwin_data.lua`), a stance or a form.
    - *Everything picked here*: whenever the plugin is on, as before.
    - *Nothing*: the window waits for the rotation.
  - **"Runs"** is the rotation's own test since 1.7.5: *Enable rotation* on and its key active. The key alone used to count.
  - **A stance or form you take yourself** while the rotation is paused is left alone (1.7.5). The pick is held again after a death or a mount, once the rotation has run, or when you pick again.
- **The game leads.** A member of a set put up from the action bar becomes the pick. A buff that vanishes out of combat with more than 3 s left was clicked off, and its switch follows. A buff that ran out, was judged, or had its charges used is put back.
- **Holds.** Dead, mounted, stealthed (Stealth, Prowl, Shadowmeld, Vanish, Feign Death), eating, casting, out-of-combat-only spells in combat, not ready.
- **The rotation's gate.** `P.classwin.owns(name)` is checked in the priority walk, in the spell window's projection, in `press_blocked` (so the reactions see it), in the "why not" explanation, and in the group-buff pass. The group-buff pass skips you, but not the party, for a buff the window keeps.
- **The hunter's window** holds the Aspects switches (`modules/aspects.lua`, unchanged) above its own groups, so the separate Aspects window is gone.
  - One switch on the Rotation page, `class_window`, shows the window. `aspect_window` is no longer read.
  - The window records why it is not on screen, as the Aspects window did in 1.61.3.

**Also fixed:** the paladin's group-buff list put Kings up, then Might over it, every 2 s out of combat on a paladin who knew both, because a paladin's blessings on one target replace each other. Now any blessing counts as having one.

Tests: `aio_classwin_test` (eight cases), a rotation-gate case in `aio_react_test`, and `aio_boot_aspects_test`, which now clicks the aspects in the Hunter window.

### Three things players asked for (1.61.0)

- **"RestedXP guide only", one switch on the ESP page.** The players asked: "wish u could turn off all ESP but keep the RXP esp only with 1 setting".
  - When it is on, the overlay draws the guide's marks (category `guide`), its panel and its waypoint line, and nothing else. Every other mark, the threat panel and arrows, and the quest paths are hidden.
  - The overlay's master switch and the guide's own switches (`enabled`, `rxp_on`, `guide_on`) read ON while it is on, so nothing else has to be visited.
  - The Forever ESP has no guide marks, so there it draws nothing; it still collects what the automation acts on.
  - Alerts keep their own switch.
- **The rogue stops stealthing whenever it walks near a mob.** The players asked about this: "anytime i get any where close to a enemy even if im just walking around it auto stealth". Both halves of 1.46.0's Stealth rule caused it. The sneak stealthed for any hostile close enough to notice. The opener stealthed for any target within 40 yd, and auto-target had picked that target while the player only walked past.
  - The Rogue page now has a **Stealth by itself** choice: Never, **Only before an opener** (the default), or Before an opener and near enemies (the 1.46.0 rule).
  - "Only before an opener" means the rotation is about to open on the target: start fights is on, the engage key is held, or you hit it. In code that is `H.stealth_wanted(s, { engaging = true, no_sneak = true })`.
- **Fishing after 75.** The players asked: "does it not fish after u learn 75-150? It worked fine from 0-75". `core.profession.open_profession(FISHING)` casts the Apprentice rank by its fixed id (7620). Once Journeyman is learned the spellbook holds 7731 instead, the cast never started, and after four refused casts fishing switched itself off.
  - Now the highest rank known is cast by its id: 18248, 7732 or 7731 by id, so the client's language does not matter, else whatever the spellbook calls Fishing (Forever's ids).
  - The Apprentice rank, or no rank found, keeps the profession call that always worked.
  - **Corrected in 1.61.1.** The spellbook fallback broke Forever below 75. Its book holds two spells named Fishing, the classic 7620 and Forever's own 1240948. The higher id won, and casting 1240948 by id started nothing: nine casts, then fishing switched off.
    - Now only the classic ranks 7731, 7732 and 18248 are cast by id; everything else uses the profession call.
    - A cast by id that starts no channel hands over to the profession call for the rest of the session.
  - **Corrected in 1.65.2.** That handover was wrong. The user, on Forever: "Spell not learned for Fishing Journeyman". Training Journeyman takes Apprentice out of the book: the Forever dump afterwards holds 7731 and Forever's own 1240959, and no 7620. So the profession call, which casts 7620, can only be refused. After one rank cast that started no channel, every cast was "Spell not learned" until four refusals switched fishing off. The catalog shows 7731 cast by id does catch fish on Forever.
    - With a rank above Apprentice known, the profession call is never used. A cast that starts nothing, or is not issued, counts as an ordinary failed cast, and the next cast is by id again.
    - Red text (`UI_ERROR_MESSAGE`) within 2.5 s of a cast counts as the client's answer to it. Each failure is a trace line, `fishing: Fishing 7731 started no channel (N in a row): the client says "..."` (or `was not issued`), and the stop reason quotes the text.
  - **1.66.1: catches and full bags.** The user, on Forever: "its also counting catches as got away and then also Stop when bags are full don't work properly".
    - The trace had `use fishing bobber ... accepted=false` and then `loot window opened (auto-loot true) after 0.4s`. `use_object` answers false on Forever every time (197 of 214 calls in the recording). The loop stayed in `waiting`, the catch ended the channel, and that counted as got away.
    - Now `actions.perform` also returns `attempted`, and fishing is `hooked` once the click is sent. `LOOT_OPENED` after it marks the catch and reads the names then, so a window the game's own auto-loot empties between ticks still counts. A `LOOT_OPENED` while still `waiting` counts as well.
    - Full bags: the free-slot count was stale on Forever (fixed in JCore 1.8.2, `inventory:` trace lines). The game's `ERR_INV_FULL` within 5 s of a click now stops fishing on its own, and that window is not counted as a catch. The "Stop when bags are full" switch governs both.
    - Test: `aio_feedback_161_test`. Unverified in game.

Tests: `aio_feedback_161_test`, `aio_boot_rxp_only_test`, and one more stealth case in `aio_react_test`.

**Not marked Away while fishing (1.61.2).** The user: "wile fishing I can go as AFK/Away status which means bad news".
- The client marks a player Away after about 5 minutes without input, and logs them out after about 30. The loop's cast (`core.profession`) and its bobber clicks did not count as input on Forever.
- `clear_afk` only clears the flag, and the client raises it again (the .api). Input through the input path resets the idle clock.
- So between casts the character jumps every 150 s, and at the next gap after `PLAYER_FLAGS_CHANGED` for the player (how going Away shows). The next cast waits 1.5 s for the landing.
- On by default, with the Fishing page switch `fish_stay_active`. Each jump is a `fishing: jumped to stay active (...)` trace line.
- Not yet seen in game whether the loader's jump resets the idle clock on Forever.
- **Seen in 1.67.1: it does not.** The user, on Forever: "the jumps arnt keeping the bot from going away. So then it finally gets marked away and just spam jumps. Chat just says 'you are away' 'you are no longer away' 30 times. If I babysit and move its fine".
  - The jumps every 150 s did not stop Away, so they never reached the idle clock. Once Away, each jump took the flag off (the client clears Away on a move). The idle clock put it straight back. Every change fired `PLAYER_FLAGS_CHANGED`, and 1.61.2 answered each one with a jump: a ping-pong.
  - A flag change within `ECHO` (30 s) of our own keep-alive is now its echo and is never answered. Two echoes (Away off, Away back) mean the idle clock ignores the loader's input, so keep-alives stop for the session. Each one would only flip Away again.
  - Backstop: keep-alives answering a flag change are at least `ANSWER_GAP` (60 s) apart. A fourth inside `ANSWER_SPAN` (10 min) is not sent, and that also stops them.
  - The keep-alive taps `turn_left_start` and `turn_left_stop` in the same tick before the jump. The .api names a turn among the input that refreshes the hardware-action timestamp. The jump is the game's JumpOrAscendStart action and may not take that path. Unverified in game: if Away still comes straight back, the Fishing page shows "Stay active gave up". Then the loader's input does not reach the Forever idle clock at all, which is a core matter (the clear_afk note in the .api says that timestamp is refreshed on the input path).
  - There is no AFK reader. `CHAT_MSG_SYSTEM` ("You are now Away") has never been recorded on Forever, so the flag event is the only signal.
  - Test: `aio_feedback_161_test` (two 1.67.1 cases). A staged copy without the echo check fails it.
- **Replaced in 1.7.5 by Jambix Market's keep-alive.** The user: "change finishs anti afk from jumping to the one marketplace uses". Fishing now runs Jambix Market's `modules/presence.lua` between casts, with no jump first.
  - Every 120 s, at the next gap between casts, one keep-alive goes out. It is the first kind not yet shown to fail:
    - **turn:** `turn_left` for about a tenth of a second, then `turn_right` for exactly as long. Both go through JCore's movement lease (`ctx.input.set_key`, priority 10, so anything else moving wins). Afterwards the facing read before the turn (`get_direction`, else `get_rotation`) is looked at again, so the bobber keeps landing in the same water.
    - **step:** a sidestep left, then right for as long.
    - **jump:** the next cast waits 1.5 s for the landing.
  - Away is read from the system message "You are now Away" / "You are no longer Away". Jambix Market recorded it on Forever on 2026-10-07, so the 1.67.1 note above is out of date. `PLAYER_FLAGS_CHANGED` and its echo rules are gone. A kind fails when:
    - Away comes less than 300 s after it (the idle clock it should have reset);
    - or it went out while Away and the Away is still on 30 s later. Market does not have this rule. Without it, a kind that neither clears Away nor resets the clock would go out for ever while the logout clock ran.
  - Away with no keep-alive in the 300 s before it (fishing started after you had been idle) is not held against any kind.
  - The next kind answers the Away at the next gap, at most once a minute. A kind with no Away for 15 minutes is recorded as holding.
  - What failed and what held is kept in `scripts_data/jcore/jambix.aio.presence.json`. This is the AIO's own file: what Jambix Market learned in `jambix.market.presence.json` is not shared. Switching *Stay active* off and on forgets it all and starts again from the turn. Once every kind has failed, keep-alives stop and the Fishing page says so.
  - Nothing goes out while you type, during a cast, or when something else holds movement; the cast goes out instead.
  - The Fishing page: the switch now reads *Stay active so you are not marked Away (anti-AFK)*, with two lines under it, and a fourth live line shows the kind in use. Trace lines: `fishing: keep-alive (turn)` and `fishing: stay active: ...`.
  - Fishing's copy has not been seen in game yet. Market's own file (`jambix.market.presence.json`, 2026-10-08 19:08) records the turn as holding: 15 minutes of turns with no Away and nothing failed. That is the best sign so far that a loader turn reaches Forever's idle clock. It is not proof, because your own keys and mouse in those 15 minutes would hold Away off too.
  - Test: `aio_feedback_161_test` (three 1.7.5 cases replace the 1.61.2 and 1.67.1 ones).

### The Debug page is Jambix Debug's (1.60.0, JCore 1.7.0)

The user, 2026-10-04: "move all the Dump, Api recorder and Debug off JCore and Jambix AIO and make it its own ... where I don't upload it to users".
- The Debug page and `modules/debug.lua` moved to `scripts/jambix_debug/aio/debug.lua`. That covers the object inspector, the automation status lines, the recent narration, the reaction history and the portrait self-test.
- The page now sits under **Jambix Debug** in the sidebar, and its own settings (`debug_inspect`, `debug_range`, `portrait_selftest`) live on it. `main.lua` builds it with this bundle when `_G.JambixDebug` is there, and waits for it up to 30 s, once a second. Without the plugin, `P.debug` stays nil and there is no page.
- `actions.lua` and `world.lua` read `world.client().recording` live instead of once, so a recorder that attaches after this plugin loads still turns their trace lines on. That flag is now true only with Jambix Debug on Forever. The other modules already held the flags table.
- Do not ship `scripts/jambix_debug`.

### Loot before the next pull (1.57.1, JCore 1.6.5)

The user, 2026-10-03, asked how to fix Forever's auto-loot. The 1.57.0 trace showed two causes.

- **The rotation pulled over the press.** A Crag Boar's corpse was pressed at 444.5 s and nothing opened. By 447.6 s the rotation had opened on a Large Crag Boar 33 yd away with Serpent Sting: a hunter pulls whatever is in shot range as soon as it is out of combat (the class's `may_open`). The second press, made under that pull, brought nothing either. The corpse opened at the first press after that fight. A cast cancels the interaction under way, and the new fight blocks auto-loot until it ends.
  - Now `world.looting()` is true while auto-loot has a corpse to work. That means one in reach that it will press (not blacklisted, not skin-only with skinning off, auto-loot not blocked by mounting or typing), or a press still waiting on its window (`ctx.loot.opening()`).
  - While it is true, `rotation.may_engage_unit` lets neither the *start fights* switch nor the class's opener start a fight. The pet reads the same answer.
  - The engage key, a mob already pressed at, and a mob that comes for us still fight.
  - The hold ends after 10 s on one corpse whatever the reason. The readout says `holding fire: looting first`.
- **One window locked in the call (JCore).** The first window in that session came from `interact_with_object`, pressed point-blank after `loot_object` had walked the character onto the corpse, and from then on only the interact was pressed. The next corpse refused it twice, and `loot_object` was never tried again. Now the call that last opened a corpse goes first, and the other goes on the next try at the same corpse. Skin tries are counted apart from loot tries.

Tests: `aio_autoloot_trace_test` (two), `aio_react_test` (one), `jcore_names_loot_test` (one).

### The Forever audit (1.55.4, JCore 1.6.3)

The user asked to "identify everything not working on WoW Forever" and then "fix all that". This release fixes what the traces of 2026-10-03 showed going wrong in our own code.

**Fixed:**

- **A looted corpse was pressed again.**
  - Cause: a corpse can still be skinned after it is looted, so both ESPs keep it listed as "skin only". With *Skin corpses* off, `world.lua` pressed *loot* on it anyway. On Forever that right-click starts Skinning, and three presses later the corpse was given up on. Two wolves and a bear went that way in one session.
  - Now a skin-only corpse is left alone while skinning is off.
  - This applies to Era too, which had the same bug.
- **A loot window was put down to the wrong corpse (JCore).**
  - Cause: a try that brought nothing stayed pending until the next corpse press. One tried at 165 s was still pending at 249 s, and the window that came then (another corpse's) was put down to it.
  - Now a window more than 8 s after a try is not that try's, and goes to the nearest corpse.
- **A vein's window took a corpse off the list (JCore).**
  - Cause: a window that came right after a cast of yours (mining, herbing, skinning, opening a chest) was given to the nearest corpse, which then went unlooted.
  - Now a window within 2 s of such a cast ending is the cast's own.
- **A skinned corpse was pressed again (JCore).** It stayed listed, and the client said "Invalid target". Now a corpse is done once a skinning cast on it succeeds. An interrupted skin leaves it to skin.
- **Quest paths were never drawn on Forever.** They read the classic ESP's entity list, which is empty there. The Forever ESP now publishes its own: the marks this frame whose npc or object is a target in the quest index, with no new reads. Forever's own quests are not in that index, since it is classic quest data.
- **Smaller fixes:**
  - The reaction state no longer says "losing the race: losing the race:".
  - The hunter's "Auto Shot: on for ..." log names the target through JCore.
  - The loot window trace names the nameless coin slot.

**Not ours to fix:** these are limits of the client.

- The game Lua bridge (`execute` returns nil).
- The empty combat log.
- `cancel_buff`.
- Raid markers, player race and creature mana.
- Ranged weapon speed.
- A few icons that cannot be extracted.

`scripts/jcore/FOREVER_API.md` (since 1.60.0 `scripts/jambix_debug/FOREVER_API.md`) was regenerated from the recorder (38 sessions).

Tests:
- `jcore_names_loot_test`: three new tests.
- `aio_autoloot_trace_test`: skin-only corpses, Forever and Era.
- `aio_esp_forever_test`: the quest paths' list.
- `aio_forever_loot_window_test`: the coin slot.

### Forever's API is JCore's (1.55.0, JCore 1.6.0)

The user: "let's bring all of Forever's API into JCore so that AIO doesn't need
to handle any of the stuff; it reads it from the core." Everything this plugin
did to work round what Forever's client cannot read now lives in JCore. JCore
answers the same question per client. On Era its answer is the client's own
read, exactly as before.

| Was in this plugin | Now in JCore | The plugin asks |
|---|---|---|
| Names learned from our casts, kept by npc id (`esp/forever.lua`, `react/init.lua`, the `forever_names` store) | `services/names.lua` (took the store in) | `units.name`, `ctx.names.of` |
| Rank from the creature cache (ESP, reactions, targeting, field) | `units.classification` | `units.classification` |
| Who fought what, somebody else's mob, LOOT on a corpse, the loot window clearing it (`esp/forever.lua`, `react/world.lua`, `targeting.lua`) | `services/loot.lua` | `ctx.loot.tapped / fought / corpse` |
| Taking a loot window's slots (`world.lua`, 1.54.2) | `ctx.loot.take_window` | `ctx.loot.window_needs_taking` |
| Counted energy, rage, combo points; mana "unread" (`modules/forever_power.lua`, deleted) | `services/power.lua` behind `player.power` | `P.power` / `P.power_max` / `P.power_unread` through `ctx.player` |
| A shapeshift form the client will not name (`forms.lua`) | `player.shapeshift_index()` (nil = unknown) | the auras / last form cast only while JCore says unknown |
| `is_spell_known`'s no as final (`spellbook.lua`) | `spells.learned` | `ctx.spells.learned` |
| Garbage channel ids (`rotation.lua`) | `player.channel_spell_id` | that |
| The pet `get_pet` will not name (`pet.lua`) | `units.player_pet` | that, on every client |
| "Is this Forever?" for Auto Shot's re-arm and melee stop, the combat-log workarounds, the trace lines | `world.client()` flags: `auto_repeat_once`, `auto_start_melee`, `combat_log`, `recording` | the flags |

`P.forever` is left only where the plugin chooses something, not where it reads
something:
- the Forever ESP page and its own renderer (`esp/forever.lua`);
- the Forever-only vendor and quest automation;
- the menu labels;
- the file the fight memory is kept in.

`esp/forever_quests.lua` still learns Forever's own quest givers and
objectives from the gossip windows and objective messages. That is next.

**Questie is not needed (1.55.0).** `quests.lua` and `questlog.lua` take
Questie's calls from JCore's own quest database (`ctx.questdb.questie()`;
see JCore's README, *Quest database*). That database was extracted from
QuestieDB's data with `tools/jcheck/questdb_extract.js` into
`scripts_data/jcore/questdb/`. It covers names, objectives, starters and
finishers, spawns and drops. With no extracted database the addon's bridge
answers as before. It is the classic world's data: Forever's own quests come
from what the game says.

**A dump to compare the clients.** JCore's **Dump** page writes this
character's spells (with ids and details), talents and the API surface.
`tools/jcheck/dump_diff.js` compares a Forever dump with an Era dump: new,
missing and changed spells, the talent systems, and the API on one client
only.

Tests:
- JCore: `jcore_names_loot_test`, `jcore_power_test` (forever_power's tests,
  moved), `jcore_dump_test`, `jcore_questdb_test`.
- AIO, rewritten to the new contract: `aio_esp_forever_test` and
  `aio_forever_automation_test` run the real JCore services through
  `mock/jcore_unit_facts.lua`.
- Also updated: `aio_react_test`, `aio_targeting_forever_test`,
  `aio_hunter_test`, `aio_forever_loot_window_test`, and
  `aio_quest_tags_test` (Questie's answers from JCore, the addon a trap).
- The nine Forever class boots run on all of it.

## Unverified assumptions

Everything below is built against the `.api` stubs and a mocked client. These
are the places where the stub did not say, so the code guesses — each one is
written to fail in the *safe* direction, but none has been seen running.

| Assumption | If wrong | Mitigation in place |
|---|---|---|
| **A JCore overlay window may be only its title bar** (`h` = the title height; the spell window paints its own body under it because a window body is a solid fill over the icons) | The bar draws taller than intended, or not at all | Built only from documented window options; where `begin_window` fails or the overlay UI is off the bar is drawn by the plugin itself at the same place |
| **`get_spell_cooldown` counts the global cooldown for every spell on it** (the forecast reads it as "seconds until pressable") | Nothing: the lane already starts after the global cooldown | Either reading gives the same first slot |
| **`circle_2d` strokes are centred on the radius** (the class portrait masks a square icon's corners with a ring of the disc colour) | A sliver of each corner shows outside the round window, or the window is a pixel or two smaller than the rim | The ring is drawn 1.5px wider than the band it covers, and the rim ring overlaps it from outside |
| **Textures paint beneath every 2D shape**, whatever order they were submitted in (`draw_texture` goes to the loader's background list) | Nothing, now: the portrait puts no shape under the icon. Seen in the game on 2026-09-27, as a class ring with nothing inside it, when a backing disc was drawn first | The disc is drawn only in the fallback, when there is no art for it to hide; a failed icon is named in the log once |
| **`common/enums` is absent or renumbered in the game** (the class portrait, the class colours and the role badge all mapped class ids through it alone, and the ring stayed empty with no initial and no badge, which is what an unnamed id looks like) | Nothing, now: every class-id lookup falls back to WoW's own numbering, as the rotation always has | `cfg.class_id_for`; the Debug page names the ids seen on players so an unnamed one is visible |
| **A nil tint on `draw_texture` really defaults to white** (the contract says so; the loader's own examples never rely on it). Seen in the game on 2026-09-27: every shape of the portrait painted, every texture invisible, on JPEG icons and the TGA sheet alike | Every icon drawn through the asset registry is fully transparent | JCore 1.3.1 never sends nil: the registry and the draw service substitute white. A draw that throws is recorded on the asset and shown on the Debug page; the **Portrait self-test** toggle there paints the art in frames at a fixed screen spot with each one's state |
| **ANSWERED, NO (2026-10-02): the loader's `read_file` / `read_file_partial` reach `.build.info` and `Data/` at the install root.** The sandbox is the client folder | Portraits use the addon sheets and the CDN instead of the game's own art | Verified offline on 2026-09-27: the Lua reader, fed the real install through the same three calls, resolved all 53 portrait images in Classic Era 1.15.9 and extracted them byte-identical to an independent reader. **But in the game it has not worked on this machine:** on 2026-10-01 `scripts_data/jcore/game` was empty and no archive index had been written. Every piece of archive art has a stand-in (addon files, web icons) that loads in the game; the Debug page's "Game archives" line names the reason |
| **`get_nameplate`'s rectangle is in pixels or in UI units** (the contract says "scaled screen pixels", bottom-left origin) | The stack sits beside or far above the plate | Both readings are tried and the one whose centre lands on the unit's own head is believed; a plate whose centre lands nowhere near it is ignored, and the stack hangs from the head as before |
| **`is_pet` / `is_minion` / `is_party_member` answer as named** | A pet is marked as a normal mob, or a party member as a stranger | Each sits behind its own category switch, so a wrong answer shows up as a mark in the wrong category, not a missing one |
| **`get_max_power(MANA)` answers a creature's mana pool** | The caster / melee badge on creatures is wrong or absent | Absent rather than wrong: a failed or non-numeric read draws no badge |
| **`get_loss_of_control_info` answers for a mob, not only for the player** (the enemies service reads it per hostile; the ESP's status line shows it as `Polymorph 6s`) | A sheeped or feared mob shows no crowd-control line | Absent rather than wrong: an invalid answer draws nothing, and the line falls through to `on you`, `tapped` and the rest |
| **`is_active_spell_interruptable` is read for casts only, and every channel can be kicked** (the contract has no flag for a channel) | An uninterruptible channel is drawn white | The same assumption JCore's enemies service makes; before 1.27.0 the overlay's own read left channels at false, which would have drawn every Drain Life red |
| **`get_group_role` numbering matches `common/enums`** (the contract lists -1/0/1/2, the enums module 0/1/2/3) | A group member's badge shows the wrong role | Read through the group service's reconciled table, never the literal; anything unrecognised falls through to the form and class tiers |
| **`is_usable_spell` covers stance** | An ability reports ready, never fires, and starves everything below it in the priority list — silently | Deadlock breaker: an ability we won arbitration for and never observed casting is backed off for 15s and named on the Rotation page. Self-calibrating — dormant until it has seen at least one confirmed cast, so a build that never reports casts does not back off everything |
| **`get_instance_type()` returns WoW's `none`/`party`/`raid`/`pvp`/`arena`** | Wrong context → wrong aggro scope | An unrecognised non-`none` value is treated as a **dungeon**, not open world. A missed taunt outdoors beats pulling somebody else's pack |
| **Stance bar order is Battle → Defensive → Berserker** | Stance detection and switching target the wrong stance | Bar is reconstructed from stances actually trained, so only the *order* is assumed, not the indices |
| **`get_spell_name` returns the bare name** (no rank suffix) | Nothing resolves; rotation does nothing | Rotation page lists every unresolved ability |
| **Higher spell id = later rank within one name** | Wrong rank cast | Holds for every Blizzard-authored rank chain; would show as casting a low rank |
| **Menu icon keys** (`eye`, `swords`, `shield`, …) | Missing or default icon | Cosmetic only. `common/menu/icons.lua` is not in the API dump, so the catalog could not be checked |
| **`UNIT_SPELLCAST_SUCCEEDED` arg order is `(unit, castGUID, spellID)`** | Deadlock breaker never calibrates | Stays dormant, which is the safe state |
| **Sound kit `8959`** | No sound on warnings | Log line still fires |
| **Bag 0 contains the backpack** (verified in the stub) plus equipped gear | Worn item name-matches a consumable pattern | No equipped item is named "Healthstone"; health potions now come from `inventory_helper`'s flag instead of a name |
| **`get_spell_costs` reports `cost_type` 0 for mana** | Costs read as zero, so every derived mana threshold collapses | A cost of nil (not zero) is returned when no mana row matches, and every derivation returns nil rather than a guess, so the sliders answer instead |
| **`get_spell_cast_time` returns 0 only for a genuine instant** | A not-yet-loaded spell reads as instant, shortening a derived channel deadline | `drainlife_min_runway` refuses a zero and defers to the slider; elsewhere instants are common enough that zero is taken as truth |
| **`get_base_power_regen` is mana per second** | The "enough to finish the fight" figure is off by whatever the real unit is | Only ever *subtracted* from a requirement and the result is clamped, so a wrong unit widens or narrows the band rather than inverting it |
| **Talent names match the English client** | `H.has_talent` answers false, so talent-gated rules never fire | Fails to the untalented behaviour, which is correct-but-conservative rather than wrong. Same known limitation as spell names |
| **Forever's trait trees are either three trees (one per classic tab) or one tree plus a specialization** | The profile suggestion counts the wrong tab, or none | Ranks by name are right either way. With neither layout the totals stay at zero (levelling profile) and the Rotation page says `Traits (no tree split)` rather than guessing |
| **Forever's talents keep their classic names** (Tactical Mastery, Improved Overpower, ...) | A renamed talent reads as untaken | Same safe direction as above: the rule it gates simply does not fire |
| **`is_on_quest` answers on Forever** (the `.api` flags only the quest *log* calls as missing there) | The tracked quest log stays empty | Questie's flat id set still marks quest mobs, as it did before |
| **`QUEST_ACCEPTED` carries the quest id at position 1 or 2** | Accepts are missed until the guide or a rebuild names the quest | Both positions are offered and `is_on_quest` decides; the guide's quest ids are fed in every second |
| **Ranked conjure names follow the `Create X (Rank)` pattern** | `prefix` resolution finds nothing and the stones are never made | Falls back to no stone rather than the wrong spell; the Rotation page lists every unresolved ability |
| **Where a shader ring's fill starts and which way it runs; whether `render_circle_percentage_3d` is a fraction; whether a plate's shadow lies on an icon beside it** (1.89.0) | A ring fills from the wrong side or the wrong way; a shadow darkens an icon | Each is drawn, lettered, by the World marks page's *Show the test pattern*: one screenshot answers all of them |
| **A mob's facing: `get_direction` answers on Forever, `get_rotation` on Era, and a rotation of exactly 0 means "not known"** (tracks, PvP extras' stealth rings) | A wedge points the wrong way; a stealth ring keeps its full size behind an enemy | A mob with no answer gets no wedge (a walking one faces the way it walks); a stealth ring with no facing stays the larger, safe size |
| **Classic Era's diminishing-return categories hold on Forever** (Forever's client has a DiminishType field this does not read) | A ring says half where the next control is full, or the reverse | Only a ring under the enemy: nothing casts or holds a spell by it yet |
| **How far an enemy notices a stealthed player** (9 yd at your level facing you, a yard a level, a third behind: the emulators' rule and an estimate) | The ring is a few yards off | *Noticed at, same level, facing you* is a setting |
| **One respawn time fits every node** (node memory) | A ring says "due" early or late; Classic pools its spawns, so a node may come back elsewhere | *Expected respawn* is a setting; a spot is forgotten 30 minutes after due |
| **Life Tap's health cost can be measured from the bar** | A mob hitting us during the sample inflates the recorded cost | Samples outside 0.6–2.5s are discarded, and only drops between 2% and 60% are recorded; until one lands, the ratio of the two pools is used |

**That it loads** is no longer an assumption: it has run in the game since
September 2026, and `aio_boot_*_test` boot the whole plugin on the whole
JCore runtime headless, as each client.

## Notes

- `config.lua` category `key` values are baked into every widget id on the
  Categories page. Renaming a key orphans the saved setting. Labels are free.
- Menu persistence is salted with the **page path**, so moving a widget between
  pages orphans its saved value exactly as renaming its id would. The ESP
  settings moved from the root page to `Jambix AIO/ESP` in 1.2.0, which resets
  them to defaults once.
- Classification is cached per guid and cleared on the core's unit-removed and
  zone-changed events. If a unit's faction can change mid-session on your realm
  (mind control, phasing), that cache would go stale.
- The RestedXP waypoint is a map coordinate. Converting it needs a second
  terrain-height query, because `get_world_pos_from_map_pos` answers a vec2
  with no z; without that the line would be drawn under the map.
- That height query answers the surface *near* a position, which under a tent
  or on a bridge can be the roof, and zero when it cannot answer at all. A
  single query is therefore not trustworthy: heights are probed three times,
  accepted only when they continue the previous height along the path, and
  cached per four-yard cell. A cell keeps the first answer it was given until
  the zone changes, so one cell sampled from under a roof stays high — its
  neighbours pull the line back down either side.
- Reaction uses `is_enemy_with` and `is_friend_with` rather than `can_attack`,
  because a neutral mob is attackable. If a realm reports those differently,
  neutral and hostile would be coloured the same.

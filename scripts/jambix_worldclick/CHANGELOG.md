# World Click to Move changelog

## 1.1.0 (2026-10-11)

- **Starts only once a character is in the world** (2026-10-12). The loader started the plugins
  at the character select screen, and the game died 0.2 s later with `ASSERT(IsLoaded())`: a game
  table was read before the game had loaded it. Its start-up now waits for JCore 1.8.1's
  `JCore.in_world()` as well as for JCore itself. The "JCore never loaded" timeout still applies
  only when JCore is missing. If you load in the world, nothing changes. Test:
  `jcore_world_gate_test`, which loads World Click before JCore, as the loader does.

The user: "world click to move should be as far as I ant...should allow me to click the minimap
and also do that Should be any NPC should also be a click on the ground".

- **No distance limit.** A click walks you as far away as the thing or the spot is. The old
  100 yd limit is now a switch, "Only walk to what is within the distance below", off by default;
  the slider goes to 500 yd. Walks that long get a longer time limit (a third of a second a yard,
  plus 20 s).
- **Any npc.** When the game's mouseover names nothing, any living npc or mob whose body is
  within 24 px of the cursor on screen is taken, not only corpses and nodes. Players count only
  with "Players" on.
- **The ground.** A click on nothing walks you to the spot on the ground under the cursor (a
  roof, a dock or a bridge included). The loader has no camera read, so the plugin finds the
  cursor's line of sight from the loader's world-to-screen call and walks out along it with the
  game's ground-height probe. The spot found must land back under the cursor. The loader's
  "cursor world position" call is not used: it was never tried on Forever, and the client has
  crashed on the loader's rays before.
  - "Ground: only when the game takes the click" (on) skips clicks on the game's bars, bags and
    frames. The game hides the cursor during a click on the world and not on its UI; a ground
    click whose cursor stayed put is not walked, and the trace says so.
  - A click that the mouseover names a unit for, far from the cursor (a unit frame), is never a
    ground click.
  - "The ground" switch under "What a click walks you to" turns it off.
- **The minimap.** A click on the minimap walks you to the spot it shows. The game does not say
  where the minimap is, so "Find my minimap" on the page takes two clicks: its middle, then its
  edge. They are kept as three sliders (centre across, centre down, radius).
  - The scale is the game's yards across per zoom level, outdoors and indoors. The zoom is a
    dropdown, and it follows the mouse wheel over the minimap.
  - "My minimap turns with me" for the game's Rotate Minimap.
  - Clicks on its rim (the outer 6%, the zoom and tracking buttons) are left alone.
  - The outline shows for a few seconds after it is found.
- **Nothing while the world map is open**: it covers the world behind it.
- The page has a fifth live line, for the minimap.
- **Tests**: 11 new, 32 in all. One drives a real perspective camera over flat ground, a roof
  and the sky. All offline; not seen in game yet.

## 1.0.0 (2026-10-11)

The user: "i'd like to creatre a World Click to Move Plugin which basically uses Sentinels
navigation When you Click on a Mob, an item, a Corpser a resource ndoe it basically auto walks
you to it".

- **New plugin, on JCore.** Right-click (or left-click or middle-click, optionally with Shift,
  Ctrl or Alt held) on a mob, a corpse, a herb or vein, a chest or quest object, an npc or
  (switched off by default) a player. Out of reach, Sentinel Navigation walks you to it through
  JCore's `ctx.nav`, with the movement lease at priority 60: over the rotation and idle walks,
  under utility and defensives.
- **When you get there**: loots a corpse (JCore's `loot.open`, which also takes the window that
  Forever leaves full), skins one with nothing left to loot, gathers or opens an object
  (`use_object`), talks to an npc, targets a mob or a player. Attacking is a switch, off by
  default. You get off your mount first.
- **Knowing it worked**: a loot window, any other window (a mailbox, a poster's quest, a
  gossip) or your cast starting ends the job. The game's error after a press ("Requires
  Herbalism 50") ends it too, and the page shows the game's words. Otherwise it presses again,
  up to 3 times.
- **In reach, the game does it**: a right-click within the game's own reach walks nothing.
- **Hostile mobs**: walked to 28 yd for hunters, mages, warlocks and priests, and to melee range
  for everyone else. A dropdown changes this.
- **Watched the way the AIO guide walk is**:
  - a route that has not moved you a yard in 4 s is dropped;
  - a route that gains nothing in 6 s, gives up, or ends short is planned again (twice) and then
    dropped;
  - after a drop, anything within 40 yd is walked straight at;
  - a mob that moves 3 yd gets a new route.
- **Stops** on W, A, S, D, Q, E, Space, an arrow key or Esc, when the target is gone, in combat
  (unless "Also in combat" is on), on death, or on a zone change.
- **Clicks told apart**: a release within 0.45 s with your facing unchanged. The mouseover is
  taken from the frame before the press and must be under the cursor on screen, which rules out
  unit frames. Failing that, the nearest usable object or corpse to the cursor is taken.
  Ignored over JCore windows and the loader's menu, and while typing.
- **On the world**: a ring, a name, Sentinel's route and a pulse on each click.
- **"world click:" lines** go to the recorder's trace and the log.
- **Tests**: `tools/jtest/tests/worldclick_test.lua`, 21 tests, all offline. Not seen in game yet.

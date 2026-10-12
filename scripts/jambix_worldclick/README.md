# World Click to Move

Click something and Sentinel Navigation walks you there, however far it is. You can click:

- a mob, a corpse, a herb or a vein, a chest or a quest object, or any npc;
- the ground;
- the minimap, once you have shown the plugin where your minimap is.

When you reach a thing, it does what the game's own right-click would have done if you had been
close enough: it loots, gathers, talks or targets. A spot on the ground or the minimap is only
walked to.

The loader's own Click to Move walks you to a place you click on the **world map**. This one
covers the **world** and the **minimap**.

It needs JCore 1.7.9 or newer. It needs Sentinel Navigation for walks longer than 40 yards.
Without Sentinel, anything within 40 yards is walked straight at. It works on every client JCore
runs on.

## Using it

1. Right-click what you want. If it is out of reach, you walk to it. A ring shows under it, its
   name shows above it, and Sentinel's route is drawn from you to it.
2. When you get there:
   - **corpse**: looted. With nothing left to loot, it is skinned if it can be.
   - **herb, vein, chest or other object**: gathered or opened.
   - **npc**: talked to.
   - **hostile mob**: targeted. It is attacked only with "Attack hostile mobs" on.
   - **player**: targeted. Players are off by default.
   - **a spot on the ground or the minimap**: nothing. You stop there.

   You get off your mount first for everything but targeting and spots. If the game refuses (for
   example "Requires Herbalism 50"), the walk ends and the page shows the game's words. Otherwise
   a press that brings nothing is tried again, up to 3 times.
3. To stop the walk, press **W, A, S, D, Q, E, Space, an arrow key or Esc**. A walk also stops
   when what you clicked is gone, when you enter combat (unless "Also in combat" is on), when you
   die, or when it takes too long. Clicking something else starts a new walk instead.

**There is no distance limit.** A click walks you as far away as the thing or the spot is. To
set a limit, turn on "Only walk to what is within the distance below" and set the slider.

**In reach, the game does it.** Right-click is the game's own "interact" click. When you are
already within the game's reach (5 yards, or your attack range for a hostile mob), the game
loots, gathers, talks or attacks by itself. In that case nothing walks, because a walk and a
second press would only get in its way: moving cancels a gathering cast.

**Hunters and casters.** By default a hostile mob is walked to 28 yards if you are a hunter,
mage, warlock or priest, and to melee range otherwise. A right-click on a mob you can already
shoot is left to the game, so your Auto Shot or pull happens as it always did. You can change
this with "Stop at a hostile mob".

**Turn off the game's own Click-to-Move** (Interface > Mouse) if it is on. Otherwise the game
walks you in a straight line while Sentinel walks you along its route.

## The ground

A click on nothing walks you to the spot on the ground under the cursor. That includes a roof, a
dock or a bridge, whatever the cursor is on.

The loader cannot see the game's own bars, bags and frames. So a right-click on a bag item has
nothing in the world under it either. To tell the two apart, the plugin uses what the game does
with the cursor: over the world, the game hides the cursor while the button is down; over its own
UI, it does not. With "Ground: only when the game takes the click" on (the default), a ground
click only walks you when the cursor was hidden or moved during the click.

If ground clicks never walk you, turn that switch off. The page's "Last press" line then says
"the cursor stayed put". With the switch off, a right-click on a bag or a bar can also walk you
to the ground behind it.

## The minimap

The game does not tell the plugin where your minimap is (Forever lets Edit Mode put it anywhere,
at any size), so you show it once:

1. On the page, under **Minimap**, press **Find my minimap**.
2. Click the **middle** of your minimap (your arrow), with either button.
3. Click its **edge**, with either button.

The outline is drawn for a few seconds so you can check it. The centre and radius are kept in
the three sliders below, which you can nudge by hand. If you move or resize the minimap in Edit
Mode, find it again.

After that, a click on the minimap (with the button you walk on) walks you to the spot it shows.
A click on the minimap's rim (its outer 6%) is left alone, because the zoom, tracking and mail
buttons sit there.

**The zoom.** The plugin cannot read the minimap's zoom either. Set "Minimap zoom" to match the
game's. "Follow the mouse wheel over the minimap" moves it a level for each notch you scroll over
the minimap, as the game does. Zooming with the + and - buttons is not followed, so set the
dropdown again after using them. Indoors, the minimap shows less ground, and that is counted.

**Rotate Minimap.** If the game's Rotate Minimap is on, turn on "My minimap turns with me".

## Settings

| Setting | Default | What it does |
|---|---|---|
| Enable | on | The whole plugin. Off: a click is only the game's. |
| Walk when you | Right-click | Or Left-click (the game only targets on it; in reach, the action happens at once), or Middle-click. |
| While holding | Nothing | Or Shift, Ctrl, Alt: only clicks made while holding it walk. |
| Only walk to what is within the distance below | off | Off: no limit. On: a click on anything farther away than the slider is ignored, and the page says so. |
| Farthest it walks you | 100 yd | The limit, when the switch above is on. |
| Also in combat | off | Off: clicks in combat are the game's, and combat stops a walk. |
| Walk straight at it when Sentinel can't | on | When Sentinel is not connected, or does not move you, anything within 40 yd is walked straight at (facing it, holding forward, with a jump and a sidestep when stuck). |
| Show the route and where you're going | on | The ring, the name, the route line, and a pulse on each click (in the warning colour when a click is refused). |
| What a click walks you to | mobs and npcs, corpses, objects, the ground: on; players: off | Each kind has its own switch. |
| Ground: only when the game takes the click | on | See "The ground" above. |
| Stop at a hostile mob | By your class | Or in melee range, or at 28 yd. |
| Walk where you click on the minimap | on | Once the minimap has been found. |
| Find my minimap / Forget my minimap | | See "The minimap" above. |
| Minimap zoom | All the way out | Match the game's. |
| Follow the mouse wheel over the minimap | on | The zoom setting follows your scrolling over the minimap. |
| My minimap turns with me | off | Turn on if the game's Rotate Minimap is on. |
| When you get there | all on but attacking | Loot, skin, gather or open, talk, attack. |

The top of the page shows what it is doing, whether Sentinel is connected, how the last click
went (or why it was ignored), how many walks there have been, and where the minimap is and its
zoom.

## How it reads a click

- **A click** is a press and a release within 0.45 s with your facing unchanged. Holding the
  button longer turns the camera, and a right-drag turns you, so neither of those walks you
  anywhere.
- **What it is on**, in this order:
  1. The minimap, if the cursor is inside the circle you showed it.
  2. Nothing, while the world map is open.
  3. The game's mouseover, taken in the frame **before** the press. The game may drop the
     mouseover once a button goes down, and it hides and moves the cursor while you hold one. The
     object must also be drawn under the cursor, near the line from its feet to just above its
     head. A unit frame or a party frame names a unit that is nowhere near the cursor, so it does
     not count, and such a click is never taken as a ground click either.
  4. When the game names nothing: the nearest usable object or corpse within 36 px of the
     cursor, or any living npc or mob whose body is within 24 px of it. That covers a herb or a
     vein the mouseover may not name, and any npc.
  5. The ground under the cursor (see "The ground" above).
- **How the ground is found.** The loader has no camera read, but it can put any world point on
  the screen. The points it puts at the cursor are the cursor's line of sight. The plugin finds
  that line, then walks out along it and asks the game for the ground height under each point,
  until the line goes into the ground, a roof or a dock. The spot found must land back under the
  cursor. It does not use the loader's "cursor world position" call, because that call has never
  been tried on Forever and this client has crashed on the loader's rays before.
- **Ignored clicks**: over a JCore window, over the loader's menu, while typing in chat, or
  without the modifier.

Every walk writes "world click:" lines to the recorder's trace
(`scripts_data/jcore/jcore.trace.txt`) and to the log. They say:

- what was clicked, and how it was picked ("mouse", "near", "ground" with "from the camera" or
  "from above you", or "minimap");
- how it walked ("Sentinel" or "straight");
- what was pressed when it got there, and what the press answered;
- how the walk ended;
- each ground click turned away because "the cursor stayed put", and where the minimap was set.

Read these first when something does not work in game.

## Not yet seen in game

This build has only been tested offline (`tools/jtest/tests/worldclick_test.lua`, 32 tests).
Check these first in game:

- **Ground clicks.** Whether the game hides or moves the cursor during a quick click on the
  world. If every ground click says "the cursor stayed put", turn off "Ground: only when the game
  takes the click".
- **Ground spots.** Whether the spot found is where you clicked. The trace says how it was found;
  "from above you" means the camera could not be located, and the search started above you.
- **The minimap.** Whether the mouse wheel zooms Forever's minimap. If it does not, turn off
  "Follow the mouse wheel" and set the zoom by hand.
- Whether the mouseover names herbs, veins and chests, or only units. On Forever it has named
  live mobs and corpses (1,803 answers in the API recorder). Objects fall back to "near" picks;
  the trace says which was used.
- Whether a quick right-click turns your facing in the client. If every click comes back as "you
  turned (a drag)", `TURN_MAX` in `modules/mouse.lua` needs widening.
- Whether Sentinel's walk is ever read as you steering. AIO's guide walk makes the same check, and
  its loot walks on Forever were not cancelled by it.

# Jambix Debug

The developer's tools for JCore and Jambix AIO, kept out of what users get
(1.0.0, with JCore 1.7.0 and Jambix AIO 1.60.0). The user, 2026-10-04: "move
all the Dump, Api recorder and Debug off JCore and Jambix AIO and make it its
own ... where I don't upload it to users".

**Do not ship this folder.** JCore and Jambix AIO run the same without it.

## What is in it

    main.lua                publishes _G.JambixDebug; attaches to JCore if JCore came first
    services/faults.lua     the Faults page: every error, native raise and nil, logged on the hit; the crash black box (1.1.0)
    services/recorder.lua   the Forever API recorder and its trace (was JCore's); its watch feeds the fault log
    services/dump.lua       the Dump page: spells, talents, API; the study's switch; the click-to-move probe (was JCore's)
    services/lootstudy.lua  the corpse and loot-window study (was JCore's)
    aio/debug.lua           Jambix AIO's Debug page: object inspector, automation status, narration, reaction history (was the AIO's)
    RECORDER_README.md      the recorder's guide and findings
    FOREVER_API.md          the Forever API reference built from the recordings

The three services are factories of JCore's runtime and are built **by
JCore**: the recorder wraps every `core.*` function in place and has to come
before any JCore service captures a native, so JCore builds it at the same
point of its boot it always did. `aio/debug.lua` is built by Jambix AIO with
its bundle. All their pages sit under **Jambix Debug** in the sidebar. Their
files stay in `scripts_data/jcore/`, so the tools read them as before.

**Load order** is not guaranteed, and a require across package roots does not
work on every loader build:
- `main.lua` publishes `_G.JambixDebug`.
- JCore looks for the global at boot, then tries `require("jambix_debug/main")`.
- If this plugin runs after JCore, it calls `JCore.attach_debug`, which builds the services late. A late recorder misses what JCore's services captured at their own build.
- Jambix AIO waits up to 30 s for the global before giving up on its page. Its trace lines read `world.client().recording` live, so a late attach still turns them on.

**Without this folder:** no pages, no files, no wrapping, and
`world.client().recording` is false, so the AIO does not even build its trace
lines.

## Tools (tools/jcheck)

    node tools/jcheck/recorder_report.js [--ns input] [--md]   # the recording against scripts/.api; --md writes FOREVER_API.md here
    node tools/jcheck/dump_diff.js <forever dump> <era dump> --md   # writes FOREVER_VS_ERA.md here
    node tools/jcheck/lootstudy_diff.js <study files...> --md      # writes LOOT_STUDY.md here

Tests: `jcore_faults_test`, `jcore_recorder_test`, `jcore_dump_test`, `jcore_lootstudy_test`,
`jcore_debug_split_test` (JCore without this plugin, then a late attach),
and the boot tests, which load it from `scripts/`.

## Faults (1.1.0, with JCore 1.8.1)

The user, 2026-10-11, after an evening of crashes that left only the
"Fatal Error: Your game crashed" popup and no report: "add to the Debug All
Captures of anything we running thats going Null, or Crashing us for any
Error whatso ever and log it on the hit so we can fix it/report it".

**Where:** `scripts_data/jcore/jambix.debug.faults.log`. Each fault's first
hit is written at once, in full. A repeat is counted, and written again as
"again, xN" at its 2nd, 10th, 100th... hit. `core.write_data_file` appends,
so a line written survives the game dying a moment later. Past 2 MB the log
moves to `.prev.log` at the next start.
`jambix.debug.faults.summary.txt` lists this session's faults by count. It is
rewritten every 30 s and on logout.

**What is caught.** JCore's `lib/faults` hands these over while this plugin
listens. Without it, JCore runs a plain `pcall` as before.

| Kind | What |
|---|---|
| ERROR | A job, timer, event handler or core stage raised, from any plugin or JCore. The entry has the traceback, the locals of the frame that raised, the job (owner, phase, priority, file:line), what was running, and where you were (zone, position, combat, target, units, fps). |
| NATIVE | A `core.*` function or game-object method raised, even when the caller's `pcall` swallowed it. Comes from the recorder's watch (Forever only); the entry has the function and its call site. |
| NULL | A native answered nil after answering values before. Logged once per call site; the nils are counted. From the watch (Forever only). |
| SWALLOWED | An error JCore's `cache.try` swallowed. |
| LOG | A warn or error line of JCore's log, which every plugin's `ctx.log` writes to. |
| CRASH | Written at the next start: the last session ended without logging out. Says when, and what was running then (see the black box). |

Not caught: a plugin's own `pcall` around its own Lua code (the global
`pcall` is not replaced, because the loader attributes calls by walking the
stack), and the loader's packed code.

**The black box.** A game that is killed outright runs no more Lua, so the
box is written *ahead*, to `jambix.debug.blackbox.1.txt` and `.2.txt` in
turn (2000 lines each). The Faults page's *Crash black box* sets the level:

- *Once a second*: a context line only.
- *Every pass* (the default): also a line as each of the loader's passes
  begins and ends (update, pre_tick, render, window, menu, control_panel, the
  spell-cast callbacks). A scheduler pass with no job in it (pre_tick today)
  is not marked: nothing of ours runs there.
- *Every job and handler*: also every scheduler job, event handler and core
  stage. This is heavy.

At the next start the last session's lines are read back. If `core.time`
went back (it counts from the injection, so the game was restarted) and
there is no "logged out" mark, the session died. The passes still open at
the end are what was running, and a CRASH entry lists them with the last 30
marks. "Between passes" means it was not in anything JCore runs: a game
event or the loader itself. "Not known" means the box had stepped down below
*Every pass* by then, so no pass was marked.

If the plugins load at the character select screen, JCore runs no pass until
a character is in the world (JCore 1.8.1's world gate). The box then says
"G waiting for the world (the character screen)", and later "G in the
world: the passes start". If a box ends on the first of these, the game died
before any of our passes ran. While waiting, the context line asks nothing:
the map and zone natives would read tables the game has not loaded yet.

The box times its own writes. Three seconds over 60 ms a second steps it
down one level, with a line in the log. The page shows its writes and
milliseconds per second.

In a group or an instance it allows 120 ms a second instead. On the way into
one it goes back up to the page's level if it had stepped down, but no higher
than *Every pass* (*Every job* writes ~7000 lines a second in a dungeon), with
a "black box: in a group; back to pass" line in the log. That is where the
crashes come: on 2026-10-12 all three deaths in the world were in Shadowfang
Keep or with a group in Redridge. Every one of those sessions had stepped
down to a line a second within 30 s of loading, so no CRASH entry could say
what was running. The context line now names the instance kind (dungeon,
raid...) and "in a group".

**The native watch** (in `services/recorder.lua`, Forever only). The
recorder's wrappers stay in place with *Record calls* off, and every call
goes through a `pcall`. The first answers of each function are searched for
game objects, so their methods are watched too. Switch: *Watch every native
call* on the Faults page. `recorder.watch_stats()` gives the counts.

## The API recorder (Forever only)

**Since JCore 1.5.4; format 2 since 1.5.12.** Full guide and
the recordings' findings: [RECORDER_README.md](RECORDER_README.md). Most Forever
notes in `.api` were written from the core's source, not from a running Forever
client, so on Forever `services/recorder.lua` records what the client really
answers. At boot, before anything captures a native, it wraps every `core.*`
function (namespaces and one level of sub-namespace, such as
`core.addons.questie`) and the `game_object` methods, the latter through the
objects' shared metatable.

The recording is one entry per function, a foundation that only grows when
something new turns up. Each entry has:

- **kind:** read, action, loader, file, net, paint or clock;
- **args / returns:** the value kinds seen at each position;
- **answers:** how often each answer shape came back;
- **examples:** a few distinct calls, each with its answer and what triggered it;
- **triggers:** what triggered the calls. That is the phase (update, render,
  `event NAME`, `recorder`, `outside JCore`) and, when the client exposes
  `debug`, the call site, plus the plugin line behind a JCore service;
- **effects:** for an action, the game events that followed its calls within
  2 s, as a count per call watched;
- **origin:** `C` for the client's own function, `Lua` for one another script
  defined.

Game events keep one example per argument layout, plus the actions called just
before each event, or `unprompted` when none were. Combat log events are keyed
by sub-event (`COMBAT_LOG_EVENT_UNFILTERED:SPELL_DAMAGE`), and the spell-cast
callbacks are kept too. A `sessions` log says what each session added.
Repeats add nothing: examples and triggers are capped and unique, and the trace
skips a line that only differs in its numbers for a minute.

The recording is saved to `scripts_data/jcore/jcore.recorder.json` (within 20 s
of anything new, every 2 minutes otherwise). The next session on the same
client adds to it, and a format 1 file is converted, not lost. Read it with:

```
node tools/jcheck/recorder_report.js            # [file] [--all] [--ns input] [--md [out.md]]
```

The report compares the recording with `scripts/.api` and lists:

- coverage per namespace;
- every action called, with what triggered it and what followed it;
- the new API (calls `.api` does not document) with what each answered;
- calls the client lacks;
- readers that always came back empty;
- calls that raised, with their messages;
- `VERSIONS` notes that say Forever answers empty when the client answered
  with data;
- the events and what set them off;
- what was never called.

`--md` writes the reference, one table per namespace, to
[FOREVER_API.md](FOREVER_API.md).

To keep the cost low, a function's first 40 calls each session and every
97th after that are inspected in full (kinds, shape, trigger); the rest are only
counted and tallied. An action's call also opens its effect window. The clocks
and the graphics paint calls are only counted. The recorder leaves alone
anything the loader may attribute to a plugin by walking the Lua stack:
`core.menu`, `get_owning_plugin_name`, `register_*` and the log calls. The
**Jambix Debug → API recorder** page shows what it has seen and what this session
learned, and has buttons to save or clear the recording. Its switch stops
recording and puts every original back, including the scheduler and event-bus
hooks that give the phase. On every other client the factory returns an inert
stub: it wraps nothing, reads nothing and adds no page (`jcore_recorder_test`).


## Dump (since JCore 1.6.0)

The **Jambix Debug → Dump** page's button writes `scripts_data/jcore/jcore.dump.<client>.json`.
It holds every spellbook spell the client names, with its id, how it is
known, its base and override ids, school, cast time, cooldown, costs, ranges
and tooltip. It also holds the pet's spellbook, the talents, and the whole API
surface: every `core.*` function by namespace and every `game_object` method.
The talents are Era's classic tabs with each talent's spell, or Forever's
trait trees with every node, its entries and ranks. Forever's trait calls
give no spell for an entry until it is taken; only the active talents carry
one. Only getters are called. Dump the same class on Forever and on Era, then:

    node tools/jcheck/dump_diff.js scripts_data/jcore/jcore.dump.forever.json \
         scripts_data/jcore/jcore.dump.vanilla.json --md

That writes `scripts/jambix_debug/FOREVER_VS_ERA.md` with these sections:
- spells only on Forever;
- spells only on Era;
- spells on both that changed (id, cast time, cost, cooldown, range, tooltip);
- the talents side by side;
- functions and methods only on one client;
- what the Forever recorder found answering nothing. `jcore_dump_test`.

## Loot study (since JCore 1.6.8)

The user asked (2026-10-03): "I need to dump how the game identifies corpse has loot, and how players open corpses", and then "experiment the way SoD does it, Retail does it". `services/lootstudy.lua` records both on every client, and each client writes its own file: `scripts_data/jcore/jcore.lootstudy.<client>.json`. The file is written 3.5 s after each loot window closes, or from the **Dump** page, which also has the switch that turns the study off. Only getters are called.

- **Corpses.** Every dead unit within 40 yd that is not a player is read every 0.25 s. The reads are `has_loot`, `can_be_looted`, `can_be_skinned`, `has_skin`, `can_be_used`, `is_tap_denied`, the npc and state flags, `is_dead`, `is_visible`, `get_health`, `is_in_combat` and the marker; these are only getters the Forever recorder has seen answer without an error. The study keeps the first answers, then every change with the moment it came: at death, window open, after window, skinning, or none of those.
- **Windows.** For each `LOOT_OPENED` the study records:
  - who opened it: our press, with its call and whether it walked (`ctx.loot.attempt()`), or nobody's (the player's);
  - what pointed at the corpse: `get_mouse_over_object` and the tokens `mouseover`, `target`, `softinteract`, `softenemy`, `softfriend`, `npc` and `focus`;
  - every corpse within 6 yd, with its reads;
  - the player's movement and cast;
  - the last 4 s of game events and of our `loot:` / `auto-loot:` trace lines;
  - slots 0 to count, read at the open and again 0.3 s and 1 s later (slot = count shows whether the slots are really 0 based);
  - the slot count each time it changes;
  - the corpse's reads at the close, then 1 s and 3 s after.
- **Summary.** It tallies every read change by moment, the windows by source, and the first reads of corpses that were opened against corpses never opened.

Compare the clients (Season of Discovery runs the Vanilla client and writes the `vanilla` file):

    node tools/jcheck/lootstudy_diff.js scripts_data/jcore/jcore.lootstudy.forever.json          scripts_data/jcore/jcore.lootstudy.vanilla.json scripts_data/jcore/jcore.lootstudy.retail.json --md

That writes `scripts/jambix_debug/LOOT_STUDY.md`. Tests: `jcore_lootstudy_test`, and two in `jcore_names_loot_test` (Era presses are reported to the study for 2 s and never waited on).

**The player's own opens, and the corpse as target (1.6.11).** In the third study, auto-loot was off and the player looted 5 corpses: 4 with the interact key and 1 with a right-click.
- In every one of the 5 windows the corpse was the TARGET. Forever clears the target when the mob dies, and the player re-targets the corpse (with a click, or the interact key on the corpse just killed). The game then walks to about 2 yd and opens it, about 0.8 s after stopping.
- The soft-interact pointer took no part.
- The player's windows fire `LOOT_OPENED` once; our presses fire it twice.
- Back on auto-loot, a Defias Cutpurse with loot refused three presses from beside it.
- So `loot.open` on Forever now targets the corpse first (`core.input.set_target`, only when it is not the target already) and then presses. The `loot:` trace line says `targeted it first`, and `attempt()` carries `targeted`.
- A press that brings nothing emits `jcore.loot.nothing`. The study keeps those as `misses`, each with the call, the walk, the targeting, the corpse's reads, the pointers and the events from 2 s before the press. `lootstudy_diff.js` tallies them.

**A third call (1.6.12).** The first misses recorded, at a Prowler, show three presses, all with nothing opening, though the client said a player could loot it: `has_loot` and `can_be_looted` true, the corpse the target 1.8 yd away, the player standing and out of combat. The player's interact key opened it later.
- Our calls seem to put the corpse under a simulated mouse: the mouseover changes to the corpse, then disappears within about 1.3 s.
- After the first press the target was cleared at +2.0 s. Nothing of ours calls `clear_target`.
- `use_object` (44 windows in 123 calls on nodes and chests) had never been tried on a corpse. Now the calls are tried in turn at a corpse: the one that last opened one first, then the others in the order `loot_object`, `interact_with_object`, `use_object`. Skinning stays `skin_object` then the interact.


The two experiments above (targeting first, `use_object`) were taken out
of JCore again in 1.7.0; see JCore's README, "Tried and taken out".

## Jambix AIO's Debug page

`aio/debug.lua` is the AIO's old `modules/debug.lua`, plus the page the AIO's
`main.lua` used to build for it:
- **Object inspector:** a label with each thing's identity, its range, a dump of everything in range to the log, and a button that clears the retry and blacklist state.
- **Status:** the portrait self-test, and the live lines that say which layer of the automation said no.
- **Recent narration**, and the **reaction history** with its reset button.

Its own settings (`debug_inspect`, `debug_range`, `portrait_selftest`) are
read from this page, not through the AIO's `opt`.

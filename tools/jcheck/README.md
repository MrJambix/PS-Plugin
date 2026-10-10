# jcheck

Static checker for the JCore Lua runtime.

There is no Lua interpreter on this machine and the only thing that loads these
files is the game. That makes the edit-test loop "alt-tab into WoW and hope",
and it means a mistake in a file that runs once at boot takes the whole core
down with an error nobody sees until the next reload.

jcheck parses the code with a real Lua parser and then runs the checks that are
specific to how JCore is put together.

```
node tools/jcheck/check.js          # checks scripts/jcore
npm --prefix tools/jcheck run check
npm --prefix tools/jcheck run selftest
```

Exit code is `1` when there are errors, `0` otherwise, so it drops into a hook
or a pre-commit step as-is. Warnings do not fail the run.

---

## What it checks

| # | Pass | Level | Catches |
|---|---|---|---|
| 1 | Syntax | error | Anything that will not parse, with line and column |
| 2 | Core API | warn | `core.*` calls with no declaration in `scripts/.api` |
| 3 | Wiring | error | `rt.*` reads that `main.lua` never builds, or builds **too late** |
| 4 | Globals | warn | Reads of globals that are not the host, the stdlib, or an injected type |
| 5 | Members | warn | Method names that are declared nowhere — i.e. misspellings |

**Pass 3 is the one that matters.** Modules are factories that take their
dependencies as upvalues at build time:

```lua
return function(rt)
    local cache = rt.cache   -- resolved ONCE, when main.lua builds this module
```

If `main.lua` builds this module before it builds `rt.cache`, that line does
not degrade anything — it captures `nil`, and the runtime never starts. Nothing
about the source looks wrong, and the failure is at boot with no output. That
has already happened once in this project. Pass 3 reports it with both line
numbers:

```
jcore/services/broken.lua
  2:19  ERROR rt.cache is read at factory scope but is built later
               (main.lua:5, after this module at main.lua:4) -- this captures nil
```

Reads nested inside another function are fine at any build order, because by
the time they run the whole runtime exists. The checker knows the difference
and only flags factory scope.

---

## What it does not check

It is a static checker, not a type system. It will not catch calling a real
method on the wrong kind of object, an argument in the wrong position, or any
logic error. Pass 5 is a **spelling** check: a name counts as real if it is
declared anywhere at all, in the stubs or in the project.

A clean run means the code parses, is wired in a workable order, and does not
reference anything that does not exist. It does not mean the code is correct.

---

## Tuning

`--no-globals` and `--no-members` turn off passes 4 and 5, which are the two
that can produce noise. Pass a path to check a tree other than the default:

```
node check.js ../../scripts        # explicit
node check.js ./fixture            # the self-test fixture
```

Two allowlists in `check.js` are the things most likely to need extending:

- `KNOWN_GLOBALS` — host globals and injected types. Add to it when the
  platform starts injecting something new.
- `STDLIB_METHODS` — methods that live on a standard metatable and so are
  declared nowhere. `text:gsub(...)` is real but nothing declares `gsub`.

---

## Self-test

`fixture/` holds one deliberate instance of each class of problem, plus correct
code that must **not** be reported. `selftest.js` asserts that every pass fires
and that none of them produces a false positive.

Run it after changing `check.js`. A checker that has never been seen to fail is
not evidence of anything — if a pass silently stops working, the self-test says
so, rather than real code getting a clean bill of health it has not earned.

---

## Known warnings on current code

```
jcore/services/spells.lua
  166  WARN  core path not in .api stubs: core.spell_book.is_usable_spell
```

True positive, already handled: `spells.lua` tests for the function and assumes
usable when the build does not have it. It is the correct shape for an optional
native, and the warning is the checker doing its job.

---

## Telegraph data

```
node tools/jcheck/telegraph_extract.js [--client vanilla|forever|all] [--wow <install>] [--dbm <AddOns dir>] [--out <dir>]
```

Not a check either. It writes `scripts_data/jcore/telegraphs/<client>/`, which JCore's telegraph service reads. It merges three sources per spell id:
- the client's own spell tables;
- DBM's classic boss mods (parsed with luaparse);
- Plater's cast scripts.

Re-run it after a client patch or a DBM update. It takes about a second per client.

The spell tables come out of the CASC store through two Node readers:
- **`lib/casc.js`** is the same walk as JCore's `services/casc.lua`. It also covers two things that walk does not:
  - Forever's root carries no names, so tables are found by FileDataID (the ids are global);
  - Forever stores some BLTE containers with no 30-byte local header.
- **`lib/db2.js`** decodes WDC3/4/5 with the WoWDBDefs definition kept in `dbd/`, picked by the file's layout hash. A newer client build fails with that hash named; download the newer `.dbd` from github.com/wowdev/WoWDBDefs. Encrypted sections arrive zero-filled and are skipped.

## Forever recording report

```
node tools/jcheck/recorder_report.js            # scripts_data/jcore/jcore.recorder.json
node tools/jcheck/recorder_report.js <file> --all
```

Not a check: it reads what JCore's API recorder (`services/recorder.lua`,
Forever only) saw the Forever client answer, and lists it against the stubs in
`scripts/.api`:

- calls documented there that the client lacks, and calls on the client that
  are not documented;
- readers whose every answer was empty;
- calls that raised;
- `VERSIONS` notes that say Forever answers empty when the client answered
  with data.

It does the same for `game_object` methods, and lists every game event seen
with its argument layouts. No dependencies; exit code is always 0.
`jcore_recorder_test` leaves a small sample recording in
`tools/jtest/out/recorder/` to try it on.

## Class names against the client

```
node tools/jcheck/class_names_check.js                 # every file in modules/classes
node tools/jcheck/class_names_check.js druid mage      # some
node tools/jcheck/class_names_check.js warrior --all   # every name, not just the problems
```

A check, against the game rather than the code. It reads both rotation
clients' spell and talent tables (Era, which Season of Discovery shares, and
Forever) and every English name a class file asks for: rule names, the
interrupt, defensive, escape, form, buff, dispel and burst lists, talent reads
and aura reads. Each one is placed as one of:
- a spell on the class's skill lines, with the level it is learned;
- a Season of Discovery rune;
- an Era talent (with its tab) or a Forever trait;
- only an aura.

Two kinds of problem fail the run (exit code 1):
- **On neither client.** The name never resolves, silently: a TBC or Wrath
  name, or another class's spell.
- **Ask by id.** An aura read by a name that is no spell of yours. The rotation
  reads names through your own spellbook, so it is never found. Pass its ids
  (`H.buff_up(unit, { 6788 })`) instead.

`spellbook.lua`'s `FORM_NAMES` (Swipe (Cat), Mangle (Cat), Mangle (Bear)) count
as the spells they file. Lists under a `pet_` key are the pet's and are
skipped. It takes about two seconds.

## Forever talent tabs

```
node tools/jcheck/talents_extract.js [--wow <install>] [--out <file>]
```

Not a check. It writes `scripts/jambix_aio/modules/talent_trees.lua`, which
`talents.lua` reads on Forever. Forever keeps a class's three classic trees in
one trait tree, and the API cannot tell them apart. The extractor reads, for
every trait node, its column from the client's TraitNode table, and splits each
class tree at its two widest column gaps. A stray column (1.60.1: the hunter's
Lightning Reflexes at x 102800) is counted in the end band it lies beyond. A
tree that does not fall into three clear bands stops the run. Run it again
after a Forever patch.

## Ranks out of id order

```
node tools/jcheck/ranks_extract.js [--client all|vanilla|forever] [--wow <install>] [--out <file>]
```

Not a check. It writes `scripts/jambix_aio/modules/rank_order.lua`, which
`spellbook.lua` reads to pick a spell's best rank. A later rank does not always
have the higher id: Battle Shout's rank 1 is 6673 and its ranks 2 and 3 are 5242
and 6192, Hammer of Wrath runs backwards, and Forever added Trueshot Aura ranks
at 25 and 32 above the 40 to 60 ones. For every class's own skill lines (not the
pet lines) the spells are grouped by name less a trailing "(...)", and every
group whose ids do not rise with their SpellLevels is written whole, each id with
its level, per client (1.15.9: 32 lines; Forever 1.60.1: 38). Season of
Discovery's rune spells (ids 400000 to 999999) are left out. Run it again after
a client patch.

## Forever rares

```
node tools/jcheck/rares_extract.js [--addons <AddOns dir>] [--qdb <questdb_extract out dir>] [--out <file>]
```

Not a check. It writes `scripts/jambix_aio/modules/rares_data.lua`, the list the
Forever ESP falls back on when the game gives a mob no rank (AIO 1.7.5). Classic's
rares come from the QuestieDB in the Forever client: every npc of rank 4 (rare) or
2 (rare elite), read through `questdb_extract.js` (398 at QuestieDB 1.0.5).
Forever's own rares and the Season of Discovery rares in its world have no rank
there, so they are listed by hand in the script (`FOREVER`, `SOD`), each with
where it was seen. Add to those lists as new ones turn up (the recorder's catalog,
`npcs` with classification 2 or 4, is the place to look) and run it again.

## Skinning loot and Pristine

```
node tools/jcheck/skinning_extract.js [--sql <ClassicDB_*.sql.gz>] [--wow <install>] [--out <file>]
     [--addons <AddOns dir>] [--qdb <questdb_extract out dir>] [--trackme <TrackMe.lua>|none]
```

Not a check. It writes `scripts/jambix_aio/modules/skinning_data.lua`, which the
Forever ESP reads (AIO 1.7.6). It has two parts:
- **What a corpse gives, with chances.** These are CMaNGOS's Classic skinning tables,
  fetched from github.com/cmangos/classic-db (13 MB, cached in the OS temp folder).
  That is 924 creatures and 774 tables.
- **Which creatures can give Pristine Leather, Hide or Scale.** These are Forever's
  Scarce bonus, which no table has:
  - each item's `npcDrops` in the Forever client's QuestieDB (through
    `questdb_extract.js`): 41 creatures for the Leather at QuestieDB 1.0.5;
  - the player's own skins, from the TrackMe addon's SavedVariables. Every
    `WTF/Account/*/SavedVariables/TrackMe.lua` of the Forever client is read, unless
    `--trackme` names a file, or `none`.

TrackMe keeps only its latest skins, so a find from it is copied by hand into the
script's `SEEN` list. A run prints each new one, ready to paste. Run `art_pack.js`
afterwards: every item in the file gets an icon cell.

## Quest experience

```
node tools/jcheck/questxp_extract.js [--addons <AddOns dir>] [--out <file>]
```

Not a check. It writes `scripts/jambix_aio/modules/questxp_data.lua`, what each
quest pays, for the experience bars (AIO 1.7.6). The rows are QuestieDB's own
table in the Forever client (`support/Forever/QuestXP/xpDB-classic.lua`, the one
Questie's QuestXP reads): quest level and base xp, 3,490 quests at QuestieDB
1.0.5, with Questie's event quests (level -1) left out. It also writes `typical`,
what a standard quest pays at each level: the most common amount in the upper
half of that level's quests, never less than the level below. The bars use it
for Forever's own quests, which the table lacks. Run it again after a QuestieDB
update.

# PvP Intelligence — Phase 1: repository and client audit

> **Status: Phase 1 (the audit) is done, 2026-10-11. Phase 2 (Stage 1, the
> shared PvP state model) is built and tested, 2026-10-11 evening: §3.6.
> Stage 2 (the brief's Phase 4, threat assessment) is built and tested the
> same night: §3.7. Stage 3 (the brief's Phase 5, cooldown tracking, with
> the generated `pvp_data.lua`) too: §3.8. Stage 4 (the brief's Phases 3, 9,
> 11-hunter and 15: the tactical states, the move, the words): §3.9. Stage 5
> (the brief's Phase 13: the switches, the bench, the Live view): §3.10. The
> Reactions page's cleanup the user then asked for (the old PvP sections and
> the world marks deleted): §3.11. Stage 6 (the brief's Phase 8: the control
> plan, diminishing returns, the pet, the caster check): §3.12. Stage 7 (the
> brief's Phase 6: opponent prediction): §3.13. Stage 8 (the brief's Phase
> 7: bait detection): §3.14. Stage 11-a (the fight debrief and the shared
> network, the brief's Phase 16 in part, on the user's requests of
> 2026-10-12): §3.15 and `CENTRAL_NETWORK.md`. The rest is not.** The audit's §1.3 row
> for the Reactions page and the §1.11 / §1.12 mentions of `pvpmarks`,
> `pvpx`, `plays` and `react/marks` describe the tree before §3.11; they are
> kept as the record of what was there. Every statement below was read from the working tree on
> 2026-10-11 between 10:20 and 11:10 EDT, from the saved client data in
> `scripts_data/`, and from the loader's API stubs in `scripts/.api/`. Where
> the repository does not say, the line says **UNKNOWN**. Nothing is invented:
> no API, no event, no spell id, no cooldown, no client capability.
>
> **The tree is mid-refactor and uncommitted.** `git status` shows the
> reaction engine moving out of this plugin into JCore 1.8.0
> (`scripts/jcore/services/react.lua`, untracked, last written 10:55 today;
> `modules/react/engine.lua`, `memory.lua` and `latch.lua` deleted;
> `modules/react/init.lua`, `rotation.lua`, `main.lua`, `jcore/api.lua` and
> `jcore/main.lua` modified; HEAD `ce83bb9` still has the engine in this
> plugin at JCore 1.7.9). The AIO CHANGELOG's uncommitted lines do not
> describe that move yet; JCore's README does (its *Reactions (1.8.0)*
> section and version note), and a new `tools/jtest/tests/jcore_react_test.lua`
> is untracked beside it. This document describes the **working tree** and
> cites `init.lua`, `main.lua`, `rotation.lua` and JCore's `react.lua` by
> function, section or widget id rather than line, because all four were
> rewritten between 10:42 and 11:08 (their line numbers moved by 10–20 lines
> during the audit). Every other file cited by line was last modified on
> 2026-10-10 or earlier (checked by mtime).
>
> **Double-checked 2026-10-11 13:50–14:00:** every constant, line citation,
> dump value and survey claim below was re-read against the tree; the
> corrections are listed under *Validation performed* (§3.5). The engine
> move had paused (nothing written since 11:08:38); a second uncommitted
> change landed 14:37–15:01 in `jcore/services/geometry.lua`, `draw.lua`,
> `spells.lua` and `jambix_aio/modules/esp/elements.lua` (line of sight on
> Forever, §1.7), with CHANGELOG entries under JCore 1.8.0 and AIO 1.8.1.
> Nothing was committed.

---

## 0. What the brief asked, and where each answer is

| Audit item | Where it is | Section |
|---|---|---|
| Reactions manager | `modules/react/init.lua` (`R.*`), on JCore's engine `ctx.react` | §1.2 |
| Rule evaluator | JCore `services/react.lua` (`engine.decide`, `validate`, `execute`) | §1.2 |
| Settings UI | `main.lua` Reactions page (six sections, the decision readout at its foot); `modules/reactwin.lua`; `classwin_data.lua` | §1.3 |
| History logging | engine journal (60 rows), memory (48 attempts), `custom.history` (15 per reaction), Debug page, Forever recorder trace | §1.4 |
| Test bench | `tools/jtest` (headless); `custom.bench` / reactwin *Try it* (in game) | §1.5 |
| Action dispatcher | `engine.execute` → `ctx.cast` → JCore cast arbiter → `spell_queue`; input leases for the legs | §1.6 |
| How combat info is collected | JCore `units` sweep → `enemies` rows → `rotation.snapshot` → `react/world.lua` `W` | §1.7 |
| Client differences | Vanilla (Era / Hardcore / SoD) and Forever act; TBC / Wrath / MoP / Retail are ESP-only | §1.8 |
| Forever custom spells and mechanics | `catalog/hunter.lua` `forever` overlays; `jcore.dump.forever.json`; DB2 through `tools/jcheck` | §1.9 |
| The actual character | level 26 dwarf hunter on the Forever beta (US), realm *Classic Beta PvP* | §1.10 |
| Existing hunter PvP, kiting, aspects, interrupts, weave | `pvphunter.lua`, `rules/hunter_pvp.lua`, `rules/pvp.lua`, `kite.lua`, `aspects.lua`, `classes/hunter.lua` | §1.11 |
| Existing prediction and threat evaluation | `detect.danger`, `field` race, `tactics` plan, `learn`, `pvp.foe/state`, `pvpx` DR, JCore `enemies` motion, `missiles`, `telegraphs`; three **unused** loader modules | §1.12 |
| Gaps | §1.13 | |
| Data availability (observed / inferred / unknown) | §2 | |
| Implementation plan | §3 | |
| Risks and what only the game can answer | §4 | |

---

## 1. Architecture summary (what exists)

### 1.1 The three layers

```
loader API   scripts/.api/core.lua, game_object.lua; common/* helper modules
   │         core.register_on_game_event_callback, register_on_spell_cast_callback,
   │         core.object_manager, core.spell_book, core.input, core.graphics ...
   ▼
JCore 1.8.0  scripts/jcore: one runtime, services on a tick pipeline
   │         units → spells → combat → enemies → threat → loot → input → missiles →
   │         telegraphs → nav → walkmap → plugin jobs → cast._arbitrate
   │         ctx = { units, spells, combat, enemies, threat, player, world, group,
   │                 geometry, missiles, telegraphs, power, names, creatures, walkmap,
   │                 nav, input (leases), cast, react (1.8.0), on/emit, tick, store ... }
   ▼
Jambix AIO 1.8.0  scripts/jambix_aio: rotation + reactions + ESP + automation
             main.lua                   settings, pages, P.* wiring
             modules/rotation.lua       snapshot, priority walk, press gates
             modules/react/             the fight picture and the reactions (§1.2)
             modules/classes/hunter.lua the profiles, including `pvp` and `aoe_weave`
             modules/pvphunter.lua      PvP mode latch, "our control", the reset walk
             modules/kite.lua           the legs (input leases)
             modules/pvpx.lua, pvpmarks.lua, sense.lua   PvP overlay and stealth sense
```

JCore's README (`scripts/jcore/README.md`, uncommitted) documents `ctx.react`
in its *Reactions (1.8.0)* section: `R.configure({ spells, target_kind,
key_allows, channel_active, press_blocked, kinds, band, filter, explain,
trace, log, on_refused, units })` and `R.add_rule({...})`; the service's
header comment (`services/react.lua`, lines 1–75) carries the same contract.

### 1.2 The Reactions framework (working tree, JCore 1.8.0)

**Pipeline, one tick** (`modules/react/init.lua`, `R.tick`):

```
rotation.snapshot()  →  world.build()  →  pvp.read() → W.pvp  →  learn.observe
  →  detect.update (situations, danger)  →  petthreat.update  →  tactics.update (plan)
  →  behavior.update (mode, context)  →  engine.decide(W)  →  engine.execute per lane
  →  custom.after_decide, marks.capture  →  verdict { gcd, fast, halt, mode, waiting }
```

- **Where it runs.** Since 1.8.0 the reactions are a job of their own:
  `ctx.tick(before_rotation, { priority = 59 })` and
  `ctx.tick(after_rotation_job, { priority = 61 })` (`init.lua`, the
  "apart from the rotation" block). Both share `rotation.snapshot()` (built
  once per tick epoch, `rotation.lua` `M.snapshot`). The rotation's tick
  reads `react.verdict()` ("THE REACTIONS COME FIRST, APART (1.8.0)") and
  skips its priority walk when `verdict.gcd` or `verdict.halt`; with no
  verdict it runs its own fixed sequence (`defensives`, `racials`, hardcore,
  field).
- **The engine** is JCore's `services/react.lua`, one per plugin through
  `rt.react.for_owner(id, ctx)` (built on first `ctx.react` access,
  `jcore/api.lua` diff). The AIO tells it about its world through
  `engine.configure({...})` (`init.lua`): `spells` (known / ready / id by
  name), `spell_name`, `target_kind` (the catalogue), `key_allows`,
  `channel_active`, `press_blocked` (`rotation.press_blocked`: catalogue
  range, `learn.blocks`, `pvp.blocks`, `book.castable`), and its own action
  **kinds**: `pet_spell`, `item`, `named_item`, `pet_send`, `pet_recall`,
  `aspect`, `set_target` (each with `validate` and `execute`). The engine
  reads only `W.now, W.mode, W.context, W.player.{unit, in_combat, busy,
  casting_id}, W.pet.{unit, alive}, W.target.{unit, casting},
  W.group.in_group, W.enemies.casting_n, W.bailout, W.fight_on, W.hold_fire,
  W.pending, W.yield, W.s` (react.lua header); everything else in `W` is the
  rules' own.
- **A rule is data** (`rules/core.lua` 1–40; react.lua 9–34): `name,
  category, priority, lane (gcd | fast | pet), needs, every, wake, enabled,
  retry.hold, owns, condition + action | propose(W, offer), target,
  score(W, c), validate(W, c)`. `offer()` drops any spell that is not in the
  spellbook.
- **Selection:** base priority + the rule's reasons + `MODE_MODS` +
  `CONTEXT_MODS` (`PVP = { cc = 10, interrupt = 5, escape = 5 }`) − memory
  failures; one winner per lane; at most 4 validations per lane per tick;
  a winner must score ≥ `ROTATION_SCORE` 40 or it is deferred to an idle
  tick. Categories: survival, bailout, interrupt, cc, escape, defensive, pet,
  threat, utility, buff, low, resource. The base scale is in the README under
  *The scale* (100 potion … 92 PvP break the control … 40 the rotation … 20
  top the pet up).
- **Rule files:** `rules/core.lua` (everyone), `rules/pet.lua`, `rules/pvp.lua`
  (every class, Era-verified), `rules/hunter.lua`, `rules/hunter_pvp.lua`
  (loaded through `CLASS_EXTRA_RULES = { hunter = { "hunter_pvp" } }`,
  `init.lua` `sync_class_rules`). A class module may also add rules through a
  `reactions(R, P, lib)` hook.
- **Your own reactions:** `modules/react/custom.lua` compiles GUI or Lua
  reactions into engine rules named `My: <name>`; `custom_data.lua` is the
  vocabulary (`D.CONDITIONS`, some 60 keys; `D.ACTION_KINDS`; `D.WHERE`;
  `D.IMPORTANCE`; `D.DEFAULT_INFO`, a description of every built-in;
  `D.DEFAULT_CLASS`; `D.DEFAULT_PLACES`; `D.TEMPLATES`; `D.BENCH_PRESETS`;
  `D.API`). `engine.filter` (set in `custom.lua` ~1720) is the player's
  per-rule, per-place switch, asked for every rule every tick.
- **Modules around the engine** (all in `modules/react/`, none changed since
  2026-10-10): `world.lua` (one `W` per tick; `NEAR` 40, `MAX_CASTERS` 8,
  unit facts kept 10 s, the group re-read twice a second), `detect.lua`
  (situations and danger 0–100), `behavior.lua` (mode NORMAL → DEFENSIVE →
  EMERGENCY → ESCAPE, RECOVERY on the way back; context BOSS / AOE / PVP),
  `tactics.lua` (kill order, pet holds, AoE reach, the race; PvE-shaped),
  `adapt.lua` (rotation scoring), `learn.lua` (per-name lessons), `pvp.lua`
  (the other player, `W.pvp`), `petcare.lua`, `petthreat.lua`, `damage.lua`,
  `marks.lua` (ground marks), `packs.lua`, `share.lua`.

**Hysteresis and stability already present:** the engine's `latch` (two
lines, a locked exit line, an optional hold) and `debounce`; `behavior`'s
DWELL of 3.0 / 1.5 / 1.5 / 2.5 s before stepping down and RECOVERY on the way
out of EMERGENCY or ESCAPE; `memory.handle(event_key, ttl)` (one event, one
answer); retry holds; failure back-off 1.5 → 4 s; `pvphunter`'s 4 s mode hold;
`tactics`' SWITCH 1.3× and SETTLE 1.5 s for target changes.

### 1.3 Settings UI

| Where | What | File |
|---|---|---|
| **Reactions** page (root; `ctx.menu({ sub = "Reactions", root = true })`), sections as of 13:50 | *Reactions in the rotation*: `react_active` (on), **Open Reactions UI**. *Decisions*: `react_overlay` (off), `react_explain_log` (off), and the live decision readout (`R.debug_lines`) at the bottom of the page. *PvP*: `react_pvp_trinket` (lines 60 / 40 / 1). *PvP marks*: `pvpmarks_on`, `pvp_kill_target`, `pvp_kill_range` 40, `pvp_healers`, `pvp_cc_timers`, `pvp_trinkets`. *PvP extras*: `pvpx_on`, `pvpx_dr`, `pvpx_dr_reset` 18 s, `pvpx_bg`, `pvpx_stealth`, `pvpx_stealth_base` 9 yd, `pvpx_stealth_mobs`. *In the world*: `react_world` (on), `react_curtain_vanish`, `react_curtain_burst` (off) | `main.lua` (the Rotation page's old advanced *Reactions* section moved here in the uncommitted 1.8.0 work; cite by id) |
| **Hunter** class window and Hunter options | `rot_hunter_pvp_alpha` *PvP hunter (ALPHA/TEST)* off; `rot_hunter_aoe_weave` off; `rot_hunter_auto_aspect` off; `rot_hunter_step_out` on; `rot_hunter_kite` off | `classwin_data.lua` 254–261; `classes/hunter.lua` settings |
| **Reactions window** | Built-in view grouped by `def.category`, with `D.DEFAULT_INFO` text and Open world / Dungeon switches; My reactions; Editor (6 steps, including *Try it*); Library; Live; Import | `modules/reactwin.lua` |
| Sense and alerts | Hardcore page, *Awareness*: `sense_stealth_watch`, `sense_vanish_range` 25, `sense_vanish_memory` 12. ESP page, *Hardcore alerts*: `alert_player_range` 60 (its widget is hidden on Forever) | `main.lua` (by id) |

A new group of switches has two natural homes: a **section on the Reactions
page** (as *PvP extras* is) for the module switches, and the **Built-in view**
of the window for the per-reaction, per-place switches, which it already
derives from `def.category`, `D.DEFAULT_INFO` and `engine.filter`.

### 1.4 History and logging

| Store | Bound | Content | Shown |
|---|---|---|---|
| Engine journal | 60 rows; one line per key per 3 s | state, plan, trigger (with the score's reasons), select / hold, reject, retry, error, learn, idle | the Reactions page's readout (*Decisions*); Jambix Debug *Reaction history* (12 lines); reactwin Live |
| Engine memory | 48 attempts; 6 s failure window; 10 s target trail; 4 s of health samples | requested / sent / ok / failed / lost / unknown per attempt; handled event keys; `damage_taken(window)` | the readout's *Memory:* line |
| `custom.history` | 15 fires per reaction; `fight_n`, `total_n` | what went out, on whom, health, where, each condition's reading | cards, Editor step 1, Live |
| `def.fired_n / fired_at / fired_name` | per rule | counts | Built-in view, Live |
| Forever recorder trace | a ring of 6000 lines → `scripts_data/jcore/jcore.trace.txt` | every non-debug journal line as `react <kind>: …`, plus a `react sample:` line every 2 s in combat | the file; `tools/jcheck/recorder_report.js` |

There is **no persisted per-fight analytics, no prediction ledger and no
replay**: the recorder captures API answers and a human-readable timeline;
nothing feeds a recording back into the engine or the tests.

### 1.5 Test bench

- **Headless:** `node tools/jtest/run.js [filter …]` (fengari, Lua 5.3).
  Three styles. (A) A hand-built bundle driving `React.tick` on a scripted
  clock (`tests/aio_hunter_pvp_test.lua`, `aio_pvp_test.lua`,
  `aio_react_test.lua`): fake units whose `get_class` a test overrides, enemy
  rows `{ obj, guid, dist, engaged, targeting_me, targeting_pet, control,
  activity, closing, hp, casting }`, auras through `G.aura(guid, name,
  seconds, { caster, id })`, `G.loc` for loss of control, `G.hp` /
  `G.hp_rate`, `G.known` / `G.unready`, `G.wear` for trinkets,
  `G.fire(event)`; outputs `G.casts`, `G.sent(name)`, `G.switched`,
  `G.verdict`, `React.debug_lines()`. (B) The whole plugin booted on
  `mock/forever_class` (`sim.check("hunter", { setup = rogue_player, … })`;
  one boot per file, 30–40 s each; the mob never hits, casts or applies
  auras, so it proves only which profile runs and that nothing errors).
  (C) One JCore service on a hand-made runtime. **Mock limits:** no combat
  log, no positions that move, `is_line_of_sight` false, `get_instance_type`
  "none" unless overridden, no helper to fire the loader's spell-cast
  callback.
- **In game:** reactwin *Try it* → `custom.bench(r, s)` against
  `bench_world(s)`, with `D.BENCH_PRESETS` (`calm, panic, caster, wipe,
  healer, pet, boss, pvp, idle`) or `situation_now()`. **Gap:** the bench
  never fills `W.pvp`, so `t_immune`, `t_bursting` and `t_trinket_down` are
  always false there, and `me_control_kind` only ever says "stun".
- **Baseline today (working tree, mid-refactor):** see *Validation
  performed* at the end of §3; the full suite was not run.

### 1.6 Action dispatch (execution is already separate from decision)

`engine.execute(c, W)` → for a spell, `ctx.cast({ spell_id, target, position,
priority = band, reason, fast, direct })`; other kinds go through the AIO's
registered `kinds` (pet, items, aspects, target switch). `ctx.cast` is JCore's
per-tick **arbiter** (`services/cast.lua`): bands IDLE 10, FILLER 30,
ROTATION 50, COOLDOWN 70, UTILITY 100, INTERRUPT 150, DEFENSIVE 200,
EMERGENCY 255; one winner per lane (gcd / fast); the same spell is not resent
within the ping; dispatch through the loader's `common/modules/spell_queue`.
**There is no authorization layer beyond arbitration**: any registered plugin
may request a cast. The locks that exist are the ESP-only client lock
(`main.lua` 114–131: `ctx.cast` refused, input leases refused),
`rotation_active`, `rot_enabled`, the per-ability key gates (`key_allows`),
and the Reactions page master switch. Movement is only ever taken through
**input leases** (`ctx.input.acquire` movement and facing at a priority;
`kite.lua` 284–286) and stands aside the moment the player presses a movement
key (`kite.lua` 150–161).

### 1.7 How combat information is collected

**Observed, polled by JCore each tick** (`services/units.lua`:
`get_visible_objects` once a tick; `services/enemies.lua` rows): `guid, obj,
x, y, z, dist, speed, closing, time_to_reach, moving` (from a 0.15 s trail of
8 samples, trusted after 0.4 s), `hp, ttd, in_combat, casting { spell_id,
channel, start_at, end_at, interruptible, remaining }, target_guid,
targeting_me, targeting_pet, engaged, threat, control, activity`. Detail reads
go to the nearest 12 enemies within 60 yd (the rest every 1.5 s); threat is
read every 0.5 s, control every 0.25 s. **Not on rows:** auras, class, race,
spec, facing, a velocity vector. Auras: `units.aura_index(unit)` (built once
per tick per unit from `get_auras`; a row is `{ buff_name, buff_id, count,
expire_time (engine ms), duration, type, caster }`). The player: `ctx.player.*`
(memoised per tick), including `loss_of_control()`, `gcd`, `is_moving`,
`movement_speed`. The group: `ctx.group` (roles; on Forever from the party
rows). The instance: `ctx.world.instance_type / instance_name / instance_id`,
`in_battleground`, `in_arena`, `battlefield_state`, `match_state`. Line of
sight: **`ctx.geometry.sight(from, to)`** (uncommitted, 2026-10-11 15:01):
true, false or nil. On Forever it never calls the client's
`is_line_of_sight`, because build 70338 (auto-patched 00:45 that day)
asserts inside the client (`ASSERT(m_data)`, `M2HitTest.cpp`) when a ray is
tested against a model whose data has not loaded: four crashes that day,
three of them rays to the selected target. There it is a `trace_line`
through buildings and terrain only (`WmoCollision + Terrain +
IgnoreWmoDoodad`), calibrated by a down ray and an up ray, nil until
calibrated, kept 0.2 s per pair; trees, rocks and units do not block it, so a
Forever "true" is weaker than Era's. `geometry.line_of_sight`, `visible`,
`draw.unit_los`, `draw.los`, `spells.in_line_of_sight`, `spells.castable` and
the ESP's *Target: line of sight and range* row all go through it (the ESP
row used to call the native at the target every frame with no cache). On
every other client `is_line_of_sight` is still used.

**Event-driven, forwarded raw** (`jcore.game_event.<NAME>(args)`; nil leaves a
hole, so never `ipairs`): `UNIT_SPELLCAST_START / STOP / SUCCEEDED / FAILED /
INTERRUPTED / CHANNEL_*` with `{ unit_token, cast_guid, spell_id }` for **any
unit the client has a frame for** (target, focus, party, raid, arena, boss,
nameplates; `.api/core.lua` 192–227); `UNIT_AURA` as one record per aura
`{ "added" | "updated" | "removed" | "full", unit_token, instance_id,
spell_id, name, stacks, duration, expiration (GetTime seconds), source_unit,
is_helpful, is_harmful, dispel_name }` (168–190); `COMBAT_LOG_EVENT_UNFILTERED`
flattened (165; **empty on Forever**); `PLAYER_REGEN_*`, `PLAYER_DEAD`,
`PLAYER_ENTERING_WORLD`, `UNIT_PET`, `DUEL_REQUESTED` / `DUEL_FINISHED`,
`GROUP_ROSTER_UPDATE`, `UI_ERROR_MESSAGE` (the full list is at 60–160).
JCore's own events: `jcore.enemy.engaged / approaching / casting / fleeing /
controlled / died`, `jcore.combat.enter / leave`, `jcore.target.changed`,
`jcore.player.died`, `jcore.zone.changed`, `jcore.unit.added / removed`,
`jcore.cast.sent`, `jcore.spell.cast` (the loader's spell-cast callback,
`{ spell_id, caster, target, spell_cast_time }`; whether it fires for other
players' casts is **UNKNOWN**; `react.lua` filters by caster, which suggests
it does), `jcore.missile.launched`, `jcore.telegraph.started / on_me`.

**Today's consumers keep only their own casts from the event stream.** The
engine memory and `power.lua` filter `UNIT_SPELLCAST_*` to `"player"` and
`"pet"`; nothing in the repository keeps another unit's cast events. The
Forever recorder saw `UNIT_SPELLCAST_SUCCEEDED` 2,209 times with the
`"player"` token, and `UNIT_AURA` records for `nameplateN` tokens with spell
names (`scripts/jambix_debug/FOREVER_API.md` 1547, 1553). Whether
`UNIT_SPELLCAST_START / SUCCEEDED` arrive for `target` or `nameplateN` tokens
on Forever is **UNKNOWN** (no such example in the recorder) and is the first
thing Stage 3 must probe.

### 1.8 Clients, and how they are told apart

`core.get_game_version()` answers "Vanilla" | "Forever" | "Tbc" | "Titan" |
"Mop" | "Midnight"; JCore's `world.client()` normalises it once per session
(`forever`, `retail`, `combat_log = not forever`, `unit_names`,
`trait_talents`, `auto_repeat_once = forever`, `cancel_buff`,
`core_20261006`, `quest_ids`, `recording`); the AIO reads `P.forever`
(`main.lua` 151) and `ESP_ONLY_VERSIONS = { Tbc, Titan, Mop, Midnight }`
(114). Season of Discovery cannot be told from Era (README *Clients*).

| | Classic Era / Hardcore / SoD ("Vanilla") | Forever ("Forever", `wow_forever_beta_us`, a retail 12.0 engine) |
|---|---|---|
| Rotation, reactions, pet, kite, PvP rules | yes | yes; the PvP rules are written against Era's tables (README, *PvP on Classic Era (1.81.0)*: "Forever is untouched: none of its classes' kits were checked against this") |
| Combat log | arguments present (`telegraphs.lua` reads them) | **fires with no arguments**: no damage by source, no SPELL_CAST_SUCCESS, no SPELL_INTERRUPT attribution |
| Power and GCD | read | `get_power` 0 and the GCD 0 → JCore counts power and reads the GCD off a probe spell |
| Unit names | read | often "" → the `names` service |
| A mob's control | `get_loss_of_control_info` per unit (unverified on mobs; README *Unverified assumptions*) | from debuff names (`enemies.lua` 70–87) |
| Threat | read (the scaled percent is unverified) | answers zeros → reported as unread |
| Talents | `get_talent_info` | the trait API; one tree with three columns (`talent_trees.lua`) |
| The pet | `get_pet` | nil → minions, then `is_pet` and `get_owner` |
| Battleground and arena readers | `get_instance_type` works; `get_battlefield_arena_faction` is nil on Era | `get_score_info`, `get_match_pvp_stat_columns`, rated info: **Retail and Forever only** (`.api/core.lua` 1690–1760) |
| Arena frames and opponent spec | not expected (Era has no arena) | `object_manager.get_arena_target / _frames / _opponent_spec`: **UNKNOWN on Forever** (never called in 99 recorded sessions) |
| Auto Shot | repeats | one shot per press (`auto_repeat_once`) |
| DR categories | DRList's Classic Era list (`pvpx.lua`) | the client has a `DiminishType` field; **not read** (README *Unverified assumptions*; `pvpx.lua` header) |
| The loader's `pvp_helper` and `cooldown_tracker` | have a "Vanilla" database | **fall back to the MoP database** (`.api/common/utility/pvp_helper.lua` 8–11; `cooldown_tracker.lua` 12–15): the wrong ids on Forever |

### 1.9 What Forever changes for a hunter in PvP (verified versus unknown)

**Verified from the installed clients' DB2 tables** (`tools/jcheck`; Era
1.15.9.70003 against the Forever beta 1.60.1.70338; the generated Lua data is
one build behind, at 70291) and from `scripts_data/jcore/jcore.dump.forever.json`
(tooltips with cooldown, cost and range):

| Mechanic | Era | Forever | Source |
|---|---|---|---|
| Aimed Shot | a Marksmanship talent; 3 s cast; 6 s cooldown | trained at 20; 2 s cast; 6 s cooldown **shared with Multi-Shot** | `catalog/hunter.lua` 142–176; the dump's tooltip |
| Multi-Shot | 10 s cooldown | 6 s, shared with Aimed Shot; one rank | catalog 194–208; DB2 6000 vs 10000 ms |
| Arcane Shot | 6 s | 6 s, **shared with Summon Hawk** | catalog 227–234 |
| Traps | out of combat only; 15 s shared cooldown | **laid in combat**; 30 s cooldown; one frost-kind and one fire-kind trap down at a time | catalog 855–941; DB2 30000 vs 15000 ms |
| Scatter Shot | 30 s; 15 yd; a Marksmanship talent | the same, and "turns your attack off" | catalog 267–283; CHANGELOG 1.7.6 |
| Scorpid Sting | −Strength / Agility | −2% chance to hit for 20 s | catalog 406–427; the dump |
| Viper Sting | no cooldown | 15 s cooldown | catalog 386–403 |
| Hunter's Mark | +RAP | +RAP, and **shows a stealthed target** | catalog 580–602 |
| Rapid Fire | +40% ranged | +40% ranged **and melee** | catalog 732–747 |
| Feign Death | 30 s | 30 s; you die if still down after 6 min; Survival Tactics lowers the resist | catalog 807–830 |
| Freezing and Frost Trap sharing a cooldown on Forever | — | stated by the 1.7.6 research line | not re-verified in DB2 here: **UNKNOWN** which category they share |
| Forever-only: Summon Hawk (BM talent at 25; 6 s; two hawks of 18 s), Strider Kick (Survival talent at 30), Lacerate (30), Sniper Shot (MM, 40), Trickster's Dance (pet, 20) | — | present | the catalog's `client = "forever"` rows |
| Era-only, **absent on Forever**: Wyvern Sting, Steady Shot, Silencing Shot, Readiness, Kill Command, Aspect of the Viper, Misdirection, Snake Trap, Improved Feign Death, Trap Mastery | present | absent | the catalog's `client = "era"` rows |

**UNKNOWN on Forever (nothing in the repository answers it):** the
diminishing-return categories and reset time; whether a PvP trinket or
Insignia exists and what it breaks (the Era table is `pvp.lua` `INSIGNIA` /
`BREAKS`); honor and battleground rule changes; whether Feign Death drops a
player's target; whether `UNIT_SPELL_DIMINISH_CATEGORY_STATE_UPDATED` fires
(the `.api` says the classic branches never fire it; Forever is a
retail-engine client, so one probe is worth it); whether arenas exist. No
published Forever hunter PvP guide existed on 2026-10-10 (CHANGELOG 1.7.6:
Mobalytics 404, Icy Veins and wowtbc.gg PvE only).

### 1.10 The actual character (from saved state only)

Sources: `scripts_data/jcore/jcore.dump.forever.json` (written 2026-10-11
02:11 by Jambix Debug's dump service), `jcore.trace.txt` lines 1 and 189,
`jcore.recorder.json`.

| Fact | Value | Evidence |
|---|---|---|
| Client | Forever beta US (`"exact": "wow_forever_beta_us"`), realm *Classic Beta PvP* (a PvP realm) | dump line 1531; the recorder's `get_realm_name` |
| Class, race, level | Hunter (class_id 3), Dwarf (race_id 3), **level 26** (35013 / 36400 XP) | dump 1518–1519; trace 189 |
| Name | Dutansi (GUID `Player-4619-01430691`) | a recorded CHAT_MSG_EMOTE; the key in `jambix.aio.aspects.json` |
| Talents | 22 points, all Beast Mastery: Deadly Aspects 5, Bestial Discipline 2, **Summon Hawk 1**, Ferocity 3, Unleashed Fury 5, Bestial Swiftness 1, Improved Revive Pet 1, Pathfinding 2, Focused Fire 2; `unspent` 0. Node 104964 (Intimidation in `talent_trees.lua`) is `is_available = true` with 0 ranks: purchasable, not taken. Node 104961 (Bestial Wrath) is `is_available = false`: not reachable yet | the dump's `talents.active` and `talents.trees` |
| Pet | family **inferred Wolf** (pet spells 17257 Bite, 24605 Furious Howl 2, 14916 Growl, per `beasts_data.lua`); its name UNKNOWN; an earlier session had a Carrion Bird | dump 1543 |
| Spellbook: PvP-relevant abilities **available now** (the AIO's spellbook line counts 51 class abilities; the dump marks 69 of its 107 entries known, professions, passives and racials included) | Auto Shot, Aimed Shot (6 s, 8–35 yd), Multi-Shot (6 s), Arcane Shot 3 (6 s), Summon Hawk (6 s), Concussive Shot (12 s), Distracting Shot, Serpent Sting 4, Scorpid Sting, Hunter's Mark 2, Raptor Strike 4, Mongoose Bite, Wing Clip, Disengage (5 s), Rapid Fire (300 s), Freezing Trap (30 s), Immolation Trap, Scare Beast, Eyes of the Beast, Mend Pet 2, Aspects of the Hawk / Monkey / Cheetah, Track Beasts / Humanoids / Hidden, Stoneform (racial). Every cooldown here is the dump's own `cooldown_ms` | trace line 1; the dump's spells |
| **Not available at 26** (from the brief's candidate list) | Feign Death (30), Scatter Shot (talent, 30), Frost Trap (28), Explosive Trap (34), Viper Sting (36), Flare (32), Intimidation (talent, not taken), Deterrence (Survival talent), Counterattack (Survival talent), Bestial Wrath (40), Wyvern Sting (Era only), Trueshot Aura (an MM talent at 25 on Forever, not taken) | the catalog's `learned`; the dump |
| Equipped items | **UNKNOWN** (no slot or item ids are saved; the trinket slots 13 and 14 answered empty rows; one ranged-weapon reading of 35–45 damage at 1.636 speed) | the recorder |
| PvP history | **UNKNOWN** (no battleground or duel data anywhere) | — |

The consequence for every later phase: **capability gating stays dynamic**
(`book.known`, `book.ready`, the catalogue's `forever` overlay), never a level
table. The existing PvP hunter already does this. A level-26 Beast Mastery
hunter has no Scatter Shot, no Feign Death, no Deterrence and no Frost Trap
today, so the "peel" chain reduces to Wing Clip → Freezing Trap, and the
"Feign Death the cast" rule never proposes.

### 1.11 Existing hunter PvP, kiting, aspects, interrupts, weave and pet behaviour

| Behaviour | Where | What it does today | Gaps found |
|---|---|---|---|
| **PvP mode** | `pvphunter.lua` `M.mode()` | a latched boolean: the option on and (an enemy player targeted, or an enemy player within 40 yd on you or the pet, or a battleground with one that close); 4 s hold; re-read every 0.1 s | three separate "PvP active" notions exist: `W.env.pvp` (targeting context `pvp`, a player target, or `sense.pvp_active` within 60 yd), `W.pvp.active`, and `pvphunter.mode()` |
| **Our control on a player** | `pvphunter.held(unit)` (`OURS`: Freezing Trap, Scatter Shot, Wyvern Sting) | nothing shoots it; the pet is kept off it (`pet.lua` ~1305–1329 through `react.out_of_fight`); the burst window stays shut (`burst.lua`) | **does not check the caster**: another hunter's trap reads as ours (`pvphunter.lua` 193–199) |
| **The reset walk** | `pvphunter.reset_to` 25 yd; `kite.lua` 350–353 | from a frozen player, step out to 25 yd (Intercept and Charge reach) for the Aimed Shot opener | |
| **PvP profile** | `classes/hunter.lua` `pvp` (1841–1866) | Mark → clip or Strider Kick in melee → Concussive Shot → Rapid Fire / Bestial Wrath → Aimed Shot → Auto Shot → Viper (casters) / Scorpid (attackers) / Serpent → two hawks → Multi-Shot only with two or more → Arcane → Mend Pet → melee only while stuck | the Multi-Shot "two or more" rule holds in `pvp` and `aoe_weave` only; Levelling and Beast Mastery still Multi-Shot a single mob |
| **PvP hunter reactions** | `rules/hunter_pvp.lua` | 85 peel the melee (Wing Clip; after 1.5 s unshaken: Freezing Trap at your feet / Scatter Shot ≤15 yd / Intimidation if the pet is on it / Frost Trap against two); 84 Scatter into the trap; 88 Feign Death the cast (0.08–0.6 s before a polymorph, fear, charm, sleep, horror or danger ≥30 lands); 76 turn on the attacking player; 68 shoot another while this one is trapped; 66 finish the low one (<20%) | every one "UNTESTED IN GAME" (file header 44–46) |
| **Generic PvP reactions** | `rules/pvp.lua` | 92 break the control (weighed; the trinket last at the page's line); 87 stop the cast (STOPPERS has **no HUNTER entry**; the hunter's Scatter / Intimidation stopper lives in `rules/hunter.lua` at 86 and extends to a player's heal in PvP mode); 82 answer the burst (HUNTER: Scatter ≤15, Deterrence on self when melee ≤8, Wing Clip ≤5, Concussive 8–35); 70 off the immune target; 64 find the stealthy (Flare on the vanish spot); 58 purge | Era-verified tables; Forever unchecked |
| **What is read off the other player** | `react/pvp.lua` `M.state` (immune all / physical, avoid, mechanic immunities, burst physical / spell with name and time left, purge list, trinket_down / back) and `M.foe` (class from `get_class`, a druid's form, role melee / ranged / caster / healer-if-seen-healing-in-20 s, mana, stealth) | per GUID, rebuilt each tick, swept after 30 s | healer detection duplicated in `pvpmarks.lua`; no per-player ability history |
| **Kiting** | `kite.lua` | the pre-pet run-and-shoot (`rot_hunter_kite`, off); with a pet only the **step out** to a gap ≥9 yd from a clipped or held mob (`rot_hunter_step_out`, on); the AOE weave and the player's own keys make it stand aside; allowed on Forever | no strafe, no line of sight, no "increase distance" beyond the step |
| **Dead zone** | the catalogue's `ranged { 8, 35 }`, `melee 5`, `dead_zone { 5, 8 }` (`catalog/hunter.lua` 98–105); `H.gap`, `H.melee_range`, `MIN_RANGE` 8 everywhere | the inner edge grows while the target closes (`rotation.lua` ~2307) and is learned per name (`learn.range`) | no on-screen dead-zone warning in `pvpmarks` or `pvpx` |
| **Aspects** | `aspects.lua` | a window and a keeper; the only automatic swap is out of Cheetah or Pack before a predicted hit (`M.incoming`: melee ≤5.5 yd, `time_to_reach`, a cast at you, a shooter standing still, a missile ≤2.5 s), gated by `rot_hunter_auto_aspect` (off) | no PvP aspect logic (Monkey against a melee player, for instance) |
| **Interrupts** | a hunter has none at 26; the catalogue's `interrupts = { Silencing Shot }` (Era only); `rules/hunter.lua` 86 uses Scatter Shot and Intimidation as stoppers | | |
| **AOE melee weave** | the `aoe_weave` profile in `classes/hunter.lua` (`rot_hunter_aoe_weave`, off); `weave.lua` is only the swing-timer readout | the player walks in and out; PvP mode takes precedence | |
| **The pet** | `pet.lua`: modes OFF / ASSIST / TANK / FOCUS, always Passive; `pet_attack`, follow (shuns a unit for N s), `pet_cast_target_spell`; **no "stay"**; engine lane `pet` with `pet_spell`, `pet_send`, `pet_recall` | kept off a target under breakable control; the peel's trap scores −10 while the pet is on it | no explicit "recall before I trap" reaction |
| **Stealth** | `sense.lua` (the STEALTH aura type; a vanish heuristic, 25 yd and 12 s of memory; `pvp_active`); `pvpx.lua` stealth rings; `rules/pvp.lua` Flare and Perception; Track Hidden in the book | | Forever's "Hunter's Mark shows a stealthed target" is unused |
| **Overlay** | `pvpmarks.lua` (the lowest player, healers, our CC rings, enemy trinket rings); `pvpx.lua` (DR rings, flag-carrier beacons, stealth rings); `react/marks.lua` (kick lines, the vanish ring, the burst curtain) | | |

### 1.12 Existing prediction and estimation (do not duplicate)

| System | Where | What it predicts | Scope |
|---|---|---|---|
| Danger 0–100 | `detect.danger` | health ×40; falling rate up to 25; ttl < 12 s up to 30; 8 per extra attacker; elites; boss +10; an incoming cast +10; lost control +15; a spike ≥15% in 1.5 s +10; latches 55/35 and 80/60 | any fight |
| The race | `field.lua` (`my_dps` and `their_dps` measured from the bars; `time_to_live` / `time_to_clear`; plans BURN / AOE / CONTROL / SURVIVE / FLEE) | will I win this | PvE-shaped; no PvP branch |
| The plan | `tactics.lua` (kill order dps × weight × reach / hp; who the pet holds; AoE reach; outnumbered) | who dies first | mobs; no PvP branch |
| Cast danger by name | `detect.cast_danger` (the DANGER table, including 1.81.0's player casts: Mana Burn, Drain Mana, Aimed Shot, Soul Fire, Hearthstone) | is this cast worth stopping | any |
| Interrupt timing | `rules/core.lua` Interrupt (a dangerous cast now; a harmless one in its last 2 s) | | any |
| A defensive before the hit | `rules/core.lua` (a cast at you with ≤2 s left; a spike; health on course for the line within 2 s) | | any |
| A hit, for the aspects | `aspects.M.incoming` | a melee hit, a missile or a cast about to land | hunter |
| Lessons | `learn.lua` (immune, range edges, evade, runs-when-low, per mob **name**; a player's immunity held per GUID for 4 s only) | | PvE names; players are never learned |
| The other player | `react/pvp.lua` `state` and `foe` (immunities, a burst up, purge value, a trinket used → 120 or 300 s, a healer seen within 20 s, vanished within 3 s) | what it is wearing right now | Era tables |
| Diminishing returns | `pvpx.lua` (DRList Classic Era categories; 1 / 0.5 / 0.25 / 0; 18 s reset; `M.dr(guid, category_or_spell)`) | what the next control gets | Era categories, applied on Forever unverified |
| Enemy motion | JCore `enemies`: `closing`, `time_to_reach`, `first_arrival`; `combat.time_to_die`; `missiles.time_to_impact`; `telegraphs.danger_at` | arrival and impact | any |
| Threat trend | `world.threat_rate`; `petthreat` (8 samples over 2.5 s) | pulling off | PvE |
| **Loader modules, present but used by neither JCore nor the AIO** | `.api/common/utility/pvp_helper.lua` (CC / DR / immunity / burst / purge tables per version; `get_unit_dr`, `is_crowd_controlled`, `on_trinket_usage`, `time_since_last_trinket`); `cooldown_tracker.lua` (`get_remaining_cooldown(unit, spell_id)`, `get_last_cast_time`, `has_any_kick_up`, a runtime whitelist); `health_prediction.lua` (`get_incoming_damage(target, deadline)`, `is_pvp_situation`); `combat_forecast.lua`; `spell_prediction.lua` | enemy cooldowns, DR, incoming damage | "Vanilla" databases exist for Era; **Forever falls back to the MoP database**, so none can be trusted there; none has been seen running on this install (**UNKNOWN** whether they even load on Forever) |

### 1.13 Gaps against the brief (what does not exist)

1. **No enemy cooldown tracking** beyond the PvP trinket (seen through its
   immunity buff) and "a healer seen in the last 20 s".
2. **No per-player behaviour history** (patterns, openers, defensive
   thresholds). `learn.lua` deliberately refuses to learn players by name.
3. **No cooldown economy**: `W.player.defensives_ready` and `escapes_ready`
   are counts; nothing weighs "is the protection I already have enough".
4. **No positioning model** beyond the kite's step out and the 25 yd reset;
   line of sight is read only by the ESP and the world layer, never by a
   decision.
5. **No kill-window, bait or team-fight logic**; `tactics` and `field` are
   mob-shaped and carry no PvP branch; "finish the low one" is a target
   switch below 20% and nothing more.
6. **No CC planner**: DR lives in an overlay module (`pvpx`) consulted by two
   call sites; "the pet would break it" is handled by three independent
   checks (pet.lua, the peel's scoring, burst.lua) rather than one plan.
7. **No prediction ledger and no analytics**; nothing is persisted per fight.
8. **The Try-it bench carries no PvP state** (`W.pvp` is nil there).
9. **Era-only data** in the whole PvP layer (`pvp.lua`'s tables, DR
   categories, trinkets); Forever's own tables are readable offline and
   unread.
10. Small defects found on the way: `pvphunter.held` ignores the caster;
    `rules/pvp.lua` STOPPERS has no HUNTER entry (the hunter's stopper lives
    in `rules/hunter.lua`; the two share an event key, so only one fires, but
    they score differently); `pvpmarks.lua` keeps its own `healer_at`;
    `rot_hunter_kite_stop_at` and `rot_hunter_kite_max_distance` have no
    widget.

---

## 2. Data availability for the Phase 2 state model: OBSERVED / INFERRED / UNKNOWN

The state model must label every field. This is what each one can be on this
repository today. *Observed* = read from a documented API that has answered
on the client; *inferred* = derived; *UNKNOWN* = no source.

### Player

| Field | Era | Forever | Source |
|---|---|---|---|
| Health, % | observed | observed | `s.hp`; `units.health_fraction` |
| Mana | observed | **counted**, and only "dry for a few seconds" after "Not enough mana" (the maximum is unreadable) | `power.lua`; `W.player.power_pct` |
| Buffs and debuffs with expiry | observed | observed (`UNIT_AURA` records seen on Forever) | `units.aura_index(player)`; `W.player.aura_names` |
| Control (stun, fear, root, silence, disarm) | observed (`loss_of_control`, plus debuff names in `pvp.CONTROL`) | debuff names; `get_loss_of_control_info`'s recorded example answers `valid = false`; **UNKNOWN** whether it ever answers true there | `W.pvp.control`; `W.player.control` |
| Cast, channel, GCD | observed | observed; the GCD off a probe spell | `ctx.player`; `W.player.gcd` |
| Abilities and cooldowns | observed | observed | `spellbook.ready / cooldown` |
| Defensive and offensive resources | observed (counts) | the same | `W.player.defensives_ready / escapes_ready`; the catalogue's roles |
| Position, moving, speed, facing | observed (the player only) | observed (`get_direction` answered on Forever) | `ctx.player`; `units.player_position`; `get_rotation` |
| Velocity vector | inferred (a position trail) | the same | JCore does not expose it for the player; derive it |
| Target, focus, mouseover | observed | observed | `ctx.player.target / focus / mouseover` |
| The pet's health, target, mode, abilities | observed; the pet's target is sometimes **inferred** from the last send (`pet.target_inferred`) | the same, the pet found through minions | `W.pet.*`; `P.pet.knows` |
| Combat status | observed | observed | `s.in_combat` |

### Enemy player

| Field | Era | Forever | Source |
|---|---|---|---|
| Class | observed (`get_class`) | observed (the recorder: `get_class` answers) | `pvp.foe.class` |
| Race | the API exists (`get_race_id`); never read for enemies | UNKNOWN in practice | add to `foe` |
| Specialisation | **UNKNOWN** (no Era API; talents are not visible) | arena-only readers; UNKNOWN on Forever | mark INFERRED from observed abilities, with a confidence |
| Current target | observed (`row.target_guid`, `targeting_me / pet`) | observed | `enemies` rows |
| Health | observed | observed | rows |
| Resources (mana) | `get_max_power(MANA)` is unverified even on creatures (README); for players **UNKNOWN** | UNKNOWN | mark UNKNOWN unless probed |
| Visible buffs and debuffs | observed | observed | `units.aura_index(unit)` |
| Active casts and channels | observed (polled; instants invisible) | observed | rows' `.casting` |
| Recently observed abilities | **not kept today**; raw `UNIT_SPELLCAST_SUCCEEDED` by unit token is available on Era; on Forever UNKNOWN for non-player tokens | | Stage 3's probe |
| Estimated cooldown availability | not kept; would be INFERRED from the above plus DB2 base cooldowns | | Stage 3 |
| Immunity and damage reduction | observed from auras (`pvp.state.immune / mech / avoid`) | the same reads, with Era's aura **names** | `pvp.ENEMY` |
| Movement and position | position observed; speed, closing and moving inferred from the trail; facing readable (`get_direction` / `get_rotation`; "a rotation of exactly 0 means not known") | the same | rows; `units.is_facing` |
| Recent offensive behaviour | partly observed: `burster`, `cast_at_me`, `attackers`, damage on me (Era: the combat log by source; Forever: **shared out of my own health drop**, `enemies.damage_rate`) | | `tactics.taken`; `W.pvp` |
| Crowd-control history | DR counts (`pvpx`) | Era categories applied, unverified | |
| Likely objective | INFERRED only | | Stage 7 |
| Confidence | to be added to every inferred field | | |

### Environment

| Field | Availability |
|---|---|
| Melee and ranged distances; the minimum ranged distance | observed (`H.gap`, `H.melee_range`; the catalogue's 5 / 8 / 35) |
| Line of sight | observed on request through `geometry.sight(from, to)` only: Era true/false from the native, cached; Forever true/false/**nil** from a model-free ray (buildings and terrain, not trees, rocks or units), nil until calibrated, kept 0.2 s per pair, and the native must never be called there (client assert on build 70338). `draw.unit_los` answers "visible" past 12 rays a frame and must not gate a decision |
| Nearby hostile players and their threat | count and distance observed (`W.pvp.players / attackers / melee_attackers`; detailed rows within 40 yd); threat INFERRED |
| Friendly players and their condition | observed (`ctx.group`, `units.allies`); `group.healer_controlled` |
| Obstructions and terrain | the walk map (`ctx.walkmap.clear_line / probe / around`; a 20-yd grid; calibrated rays; built for walking, not for projectiles); terrain height; water and drop probes (the kite uses `get_height_for_position`) |
| Movement paths | `walkmap.path` (A*); Sentinel through `ctx.nav` (on Forever it "accepts a route and never moves the character"); **not to be driven by this feature** |
| Battleground objectives | flag carriers from auras only (`pvpx`); bases and graveyards **UNKNOWN** (no API) |
| Combat mode | the instance type (`none / party / raid / pvp / arena`), `in_battleground`, `in_arena`, `battlefield_state`; a duel: the `DUEL_REQUESTED` / `DUEL_FINISHED` events exist and are **untested**; world PvP = `W.env.pvp` |

---

## 3. Implementation plan

### 3.1 The architectural decisions that matter

1. **One engine.** Every recommendation that acts is a rule registered through
   `R.add_rule` on `ctx.react`, in a new `rules/intel.lua`, scored on the
   existing scale, selected per lane, validated and executed by the existing
   engine. No second evaluator, no second cast path, no key injection. Where a
   recommendation must not act (its module off, a client gap, information
   missing), it is a **notification** through the existing instant-action
   path (`custom`'s alerts, `narrate`), a readout line and a ground mark: the
   three channels built-in reactions already use.
2. **Three separated stages, three separate tables.**
   - **Observation**: `W.pvp` (exists) and a new `W.intel.obs`: facts, each
     with `source` and `at`. Nothing in it is a guess.
   - **Inference and prediction**: `W.intel.{ threat, cds, predict, bait, cc,
     pos, kill, team }`. Every entry carries `confidence` (0–1), `basis` (the
     observations it rests on) and `why` (words). A rule may read a
     prediction only through `intel.sure(pred, threshold)`, so a guess can
     never be consumed as a fact by accident.
   - **Decision**: `rules/intel.lua` proposes candidates with reasons. The
     engine's hard constraints (known, ready, the kind of target, the key, the
     catalogue, range, immunity, the memory) already run before ranking,
     which is the brief's "reject impossible, unavailable, blocked" list. The
     intel layer adds two more as `validate` hooks: *required information
     missing* and *contradicts a higher recommendation this tick*.
3. **Capability gating is the spellbook plus the catalogue**, never a level
   or a client name: `book.known`, `book.ready`, `catalog.ability(name)` with
   its `forever` overlay. A rule for an ability the character lacks never
   proposes (the engine already drops unknown spells at `offer`).
4. **Era and Forever are the same code with different data.** Spell, aura,
   cooldown and DR tables come from the installed clients through
   `tools/jcheck` into generated Lua (`modules/pvp_data.lua`, keyed by client
   like `beasts_data.lua` and `rank_order.lua`). No hand-typed ids.
5. **Budget first.** The layer reads nothing from the game itself: it works
   on `W`, the enemies rows, the aura index and the event stream, on a
   per-module interval (0.1–0.5 s), with bounded per-player state (the
   nearest 10 players, swept after 30 s as `pvp.lua` does) and bounded ledgers.
6. **Every number is a named constant with a comment saying where it came
   from** (a guide, a client table, or "estimate, unverified"), in the module
   that uses it, as the codebase already does.

### 3.2 Files to add (nothing replaces existing logic)

```
modules/react/intel/            the PvP intelligence layer (new)
  init.lua                      wires the modules, the budgets, W.intel, the switches
  state.lua                     Phase 2: observations with source and time; confidence helpers
  threat.lua                    Phase 4: the threat score and class CRITICAL .. INFORMATIONAL
  cooldowns.lua                 Phase 5: own and enemy cooldown ledger; the economy questions
  predict.lua                   Phase 6: per-player patterns, decay, calibration
  bait.lua                      Phase 7
  ccplan.lua                    Phase 8: the control plan, DR, the pet breaking control
  position.lua                  Phase 9: the hunter's spatial analyser (directional advice)
  killwindow.lua                Phase 10
  team.lua                      Phase 12
  score.lua                     Phase 14: documented weights and the hard constraints
  explain.lua                   Phase 15: readout, overlay and alert text
  history.lua                   Phase 16: the decision and prediction ledger; metrics
modules/react/rules/intel.lua   Phase 13: the reactions (candidates), the holds and the alerts
modules/pvp_data.lua            generated: spells, auras, mechanics, DR categories, cooldowns per client
tools/jcheck/pvp_extract.js     the generator (SpellCategories, SpellCooldowns, SpellEffect,
                                SpellMisc, ItemEffect; Era and Forever)
tools/jtest/tests/aio_intel_*_test.lua   one file per stage (bundle style) plus one Forever boot
```

Touch points in existing files, all small and additive: `react/init.lua`
(load `intel`; run it after `pvp.read` and before `detect.update`; add
`"intel"` to `CLASS_EXTRA_RULES.hunter`); `react/custom_data.lua` (new
`D.CONDITIONS` keys, `D.DEFAULT_INFO` texts, a `pvp_intel` bench preset);
`react/custom.lua` (`bench_world` fills `W.pvp` and `W.intel`;
`situation_now` copies them); `main.lua` (a Reactions page section
*Advanced PvP Intelligence*: ten module switches and an emergency off);
`reactwin.lua` (Live rows: tactical state, highest threat, recommendation,
reason, confidence, observed enemy cooldowns, suppressed, unavailable);
`pvphunter.lua` (`held` checks the caster and consults `W.intel.cc`);
`pvpmarks.lua` (drop its private `healer_at`; read `pvp.foe`).

### 3.3 Delivery stages (the brief's order), each with files, conditions, clients, validation and limits

**Stage 1 — the shared PvP state model** (brief Phase 2)
- Files: `intel/init.lua`, `intel/state.lua`; `pvp_extract.js` →
  `pvp_data.lua` (first cut: the tables `pvp.lua` now hard-codes, generated
  for Era and Forever, with a report of what differs between the two).
- Changes: one `W.intel` per tick, built incrementally: enemy players keyed
  by GUID (class, role, form, target, health, auras of interest, cast,
  position, closing, facing when known, last seen), allies (health, role,
  controlled), the environment (mode: duel / world / battleground / arena /
  group, from `instance_type`, the `DUEL_*` events, `W.env.pvp` and the group
  size; distances; the minimum ranged distance; line of sight to the target
  through `geometry.sight` at most twice a second, stored as true / false /
  unknown with its source, never through the client's `is_line_of_sight`),
  and one "PvP active" answer with a reason in place of today's three. Event-driven parts:
  subscribe to `jcore.game_event.UNIT_AURA` records and `UNIT_SPELLCAST_*`
  for non-player tokens, resolving tokens to GUIDs with `units.by_guid` (the
  `.api` warns that tokens are recycled), feeding each player's entry instead
  of re-reading its auras every tick.
- New conditions: none yet (internal).
- Clients: Era and Forever; on Forever the combat log and threat are listed in
  `W.intel.env.unavailable`, which the readout shows.
- Validation: bundle tests (fake rows, auras, events); a Forever boot that
  asserts no error and the unavailable list.
- Limits: enemy spec UNKNOWN; players' mana UNKNOWN; Forever's
  `UNIT_SPELLCAST_*` for other tokens UNKNOWN until Stage 3's probe.

**Stage 2 — threat assessment** (Phase 4)
- Files: `intel/threat.lua`; `intel/score.lua` (first weights).
- Changes: indicators as named detectors: a burst buff on a player on you; a
  dangerous cast at you or an ally (`detect.cast_danger` plus `pvp_data`'s
  player casts); a melee player closing with `time_to_reach` ≤ 1.5 s; CC
  range entered (the class reach tables now in `rules/pvp.lua` STOPPERS and
  ANSWERS, moved to data); a player targeting a vulnerable ally; mobility
  used (Charge, Intercept, Blink, Sprint, Dash seen as an aura or a cast);
  several attackers; rooted while threatened; escapes gone; lethal within N
  seconds from `field`'s measured `their_dps` and `W.player.ttl`. The score is
  expected damage × control severity ÷ time to impact, scaled by health,
  defensives, escapes, attackers and **reliability** (1.0 observed; lower when
  inferred; Forever's damage attribution counts as inferred). Classes
  CRITICAL / HIGH / MODERATE / LOW / INFORMATIONAL with latches (two lines, as
  `detect` does). Missing data never lowers a score; it widens the confidence
  band, and the readout says "unknown: …".
- New conditions: `pvp_threat` (the level), `pvp_threat_score`,
  `incoming_cast_threat`, `enemy_mobility_committed`, `enemy_defensive_active`.
- Validation: a scenario per indicator; a test that a burst with Deterrence
  already up does not reach CRITICAL; a test that "no combat log" does not
  read as safe.
- Limits: expected damage on Forever is inferred from health drops.

**Stage 3 — cooldown tracking** (Phase 5)
- Files: `intel/cooldowns.lua`; `pvp_data.lua` gains per-class cooldown tables
  (spell id → base cooldown, category) for both clients.
- The first task is a **probe**, not code: a recorder session on Forever and
  one on Era that logs which `UNIT_SPELLCAST_START / SUCCEEDED` tokens arrive
  for enemy players (target, nameplates) and whether `jcore.spell.cast`
  reports other casters. The design has two inputs and uses whichever
  answers: (a) cast events by token → GUID; (b) aura appearances as a proxy
  (Recklessness, Blessing of Protection, Evasion, Sprint and the like give
  the cast time; that is already how the trinket is tracked). A ledger entry
  is `{ spell, seen_at, source (event | aura), base_cd, ready_at, confidence }`
  with confidence 1.0 for an event, 0.7 for an aura proxy, decaying after the
  estimated ready time.
- The economy questions as functions: `protection_now()` (what of ours is up
  and what it covers, from the catalogue's roles and `pvp.state`),
  `sufficient(threat)`, `cheapest_answer(threat)` (ordered by the catalogue's
  cost and cooldown), `reserve()` (what Stage 2's forecast will need). Rule 82
  "answer the burst" and the core defensive gain a `validate` that refuses a
  second major defensive while `sufficient()` holds.
- New conditions: `enemy_cd_seen(name)`, `enemy_cd_ready_in(name)`,
  `my_protection_sufficient`.
- Limits: uncertain timers are shown as ranges; a spell never observed is
  "unknown", never "ready".

**Stage 4 — hunter defensive and positioning recommendations** (Phases 9 and 11)
- Files: `intel/position.lua`; `intel/explain.lua`; `rules/intel.lua` (the
  first rules). `kite.lua` only reads the advice; it gains no new movement.
- Changes: the spatial answer for a hunter: `zone` (melee / dead zone / ranged
  / far) from `H.gap`; `advice` ∈ { hold, increase, reduce, strafe,
  break_los, regain_los, stay_near_allies, avoid_reinforcements, do_not_pursue }
  with a direction word (away from X, towards Y) and a reason; inputs: enemy
  reach tables (Charge 8–25, Intercept 25, Blink and the rest from
  `pvp_data`), our slows and roots up, `closing`, line of sight to the target
  (budgeted), allies' positions, third-party players within 40 yd. No path is
  invented: when the walk map cannot say, the advice is directional only.
  Hunter-specific: Auto Shot preservation (no move advised inside the 0.5 s
  aim window, `weave.next_shot_in`); aspect advice (Monkey when a melee
  player is inside 8 yd and no clip holds, Hawk otherwise) offered through the
  existing `aspect` kind and gated by `rot_hunter_auto_aspect`. The 18
  tactical states of Phase 3 are the `tactical_state` field, each with entry
  and exit conditions, emergency interrupts (the engine's EMERGENCY and
  ESCAPE modes keep the final say), recommended and avoided actions, reserved
  resources, priority, confidence and reason; hysteresis through the
  engine's latch.
- Rules: advice-only reactions use the instant `alert` path; a `hold` kind
  where attacking would be wrong (not shooting a target under our breakable
  control is a gate today and becomes a stated hold with a reason).
- New conditions: `in_min_ranged_distance`, `pvp_zone`, `tactical_state`,
  `position_advice`, `safe_escape_available`.
- Validation: bundle scenarios: a warrior's gap closer; a warrior whose
  Intercept is unknown versus seen; a hunter in the dead zone; rooted and
  threatened.
- Limits: strafing and line-of-sight advice is text and marks only;
  `geometry.sight` is read at most twice a second and the advice says "LOS
  unknown" when it answers nil (Forever before calibration) or the budget is
  spent; on Forever a clear ray means "no building or terrain between", so
  `break_los` / `regain_los` advice there is given at reduced confidence and
  never names a tree or rock as cover.

**Stage 5 — reaction-condition integration** (Phase 13)
- Files: `custom_data.lua` (the keys below; `D.DEFAULT_INFO` for every `intel`
  rule; a category label), `custom.lua` (readers for the new keys;
  `bench_world` fills `W.pvp` and `W.intel`), `main.lua` (the section),
  `reactwin.lua` (the Live rows).
- Conditions (the brief's list): `pvp_threat_level`, `tactical_state`,
  `enemy_cd_observed`, `enemy_cd_ready`, `enemy_mobility_committed`,
  `incoming_cast_threat`, `enemy_defensive_active`, `kill_window`,
  `safe_escape_available`, `in_min_ranged_distance`, `cc_expiring_in`,
  `prediction_confidence`, `opponent_pattern`, `pet_will_break_cc`. Each is a
  Lua expression over `intel`, like the existing keys, usable from GUI rows
  and from Lua.
- Switches: an *Advanced PvP Intelligence* section with one toggle per module
  (Threat evaluation, Cooldown management, Opponent prediction, Cooldown
  baiting, Crowd control planning, Positioning awareness, Kill window
  detection, Hunter PvP tactics, Teamfight awareness, Opponent pattern
  learning) and *Emergency off*. Each `intel` rule's `enabled` reads its
  module's switch; the Built-in view lists them under the new category; the
  per-place switches come free from `engine.filter`.
- Also: evaluation intervals per module (`every`); hysteresis through the
  engine's latch; suppression reasons through `candidate:wait(why)` and the
  rejected list, both already rendered.
- Validation: tests in the `aio_react_test` style for every condition, from
  the bench and from a live `W`; a snapshot test of the window rows.

**Stage 6 — crowd control and pet control awareness** (Phase 8)
- Files: `intel/ccplan.lua`; `pvphunter.held` fixed to check the caster
  (the aura's `caster` from `aura_index`; it fails open to "unknown caster"
  at a lower confidence, as the index's caster matching does).
- Changes: one control plan: each control on each player (its category from
  `pvp_data`; Era's categories as DRList; Forever **UNKNOWN until the
  DiminishType column is extracted and verified**, so Forever starts at "DR
  unknown" and never claims a halved duration), applied and expires, breaks
  on damage, the breakers available to the target (a trinket seen or ready;
  class breakers from `pvp.lua`), nearby enemies and **our pet** that could
  break it, the next chain, and the strategic value (survive, kill, stop a
  heal, stop a burst, distance, peel, reset). A `hold` rule says "no damage
  on X: it would break Y" with the reason; a `pet_recall` rule calls the pet
  back before our trap or Scatter Shot lands and while the control holds; the
  three existing checks (pet.lua, the peel's scoring, burst.lua) read the
  plan.
- New conditions: `pet_will_break_cc`, `cc_expiring_in`, `cc_value`.
- Validation: the pet about to break the trap; a sting ticking on the target;
  DR at a quarter so the trap is not worth laying.

**Stage 7 — opponent prediction** (Phase 6)
- Files: `intel/predict.lua`.
- Changes: per-player (by GUID, this session only) pattern counters fed by
  observations: mobility when slowed (a slow applied → a gap closer within
  2 s); a defensive threshold (health when a defensive aura appeared);
  interrupts on our first cast (our cast interrupted → their action); escape
  after control (a trinket or breaker within 1 s of our control); chasing
  through bad terrain (`walkmap.clear_line` behind them); over-committing
  (two bursts within 10 s); targeting the pet (the `targeting_pet` share);
  the same opener; retreating when pressured (`closing` < 0 after our burst);
  saving cooldowns until low. Each prediction is `{ category, basis,
  confidence, consequence, response, fallback }`; confidence from counts with
  decay (a half-life of about 60 s; reset on death or zone), calibration from
  Stage 11's ledger (predicted against observed); a failed prediction lowers
  its pattern's prior. Rules read predictions only through
  `intel.sure(p, threshold)`.
- New conditions: `prediction_confidence(category)`, `opponent_pattern`.
- Limits: no history across sessions (the brief allows session history only;
  nothing is persisted per player).

**Stage 8 — bait opportunity detection** (Phase 7)
- Files: `intel/bait.lua`; rules in `rules/intel.lua` scored below the
  survival and escape bands.
- Changes: a mobility bait (a gap closer predicted above the threshold
  **and** a verified counter ready: Freezing Trap, Scatter Shot or Wing Clip,
  with room to step); a defensive bait (the burst held while the enemy's
  defensive is unseen and pressure can be kept with non-cooldown shots); an
  interrupt bait (needs a cancellable cast, which at 26 is Aimed Shot alone,
  and an observed early-interrupt pattern; offered as advice, never
  auto-cancelled unless `stop_cast` is already permitted in the user's own
  reactions); a CC bait (a low-cost control only when losing it is not
  dangerous by Stage 2's reading). No bait proposes while Stage 2 says HIGH
  or CRITICAL.
- Validation: a scenario where the counter is on cooldown gives no bait.

**Stage 9 — kill window analysis** (Phase 10)
- Files: `intel/killwindow.lua`.
- Changes: effective health (health plus known absorbs where the client
  answers, plus a defensive up); heals available (a healer nearby, a class
  that can heal, mana unknown counted as available); our burst available
  (Rapid Fire, hawks, Aimed or Multi-Shot off cooldown, mana); their escapes
  (trinket, Blink, Vanish observed or unknown); our survivability after
  committing (Stage 2's forecast); third parties within 40 yd; allies'
  contribution. Results NO_KILL_OPPORTUNITY / BUILD_PRESSURE /
  FORCE_DEFENSIVE / PREPARE_BURST / HIGH_CONFIDENCE_KILL_WINDOW /
  ABORT_COMMITMENT with reasons; `burst.lua` asks it before opening a window;
  "finish the low one" reads it instead of health < 20%.
- New condition: `kill_window`.

**Stage 10 — multiplayer expansion** (Phase 12)
- Files: `intel/team.lua`.
- Changes: threat across several enemies; protecting a vulnerable ally (peel
  recommendations reuse Stage 6); interrupt priority across casters (the
  core Interrupt already weighs up to three); target-switch advice; healer
  pressure; overlap avoidance (allies' cooldowns are not readable, so only
  our own overlap is prevented); overextension (distance from allies against
  enemies); friendly CC awareness (allies' control on a target, from its
  auras); battleground objectives (flag carriers only; no base data);
  disengage advice.
- Limits: Retail arena assumptions excluded; Forever's battleground rules
  UNKNOWN.

**Stage 11 — the test bench and analytics** (Phase 16)
- Files: `intel/history.lua`; `tests/aio_intel_scenarios_test.lua` (bundle
  style; one scenario per item in the brief: a warrior's gap closer, a
  warrior with mobility still available, a rogue's opener, a rogue's reset, a
  mage's Blink, a mage controlling the hunter, a warlock's dangerous cast, a
  healer under pressure, the dead zone, the pet about to break control,
  several enemies at once, an immunity, no defensives left, a low enemy with
  dangerous cooldowns, incomplete data, a wrong prediction, PvP turning into
  PvE, a missing client ability), each with its initial state, events,
  expected state, expected and forbidden recommendations, explanation and
  fallback. `custom_data.BENCH_PRESETS` gains the same scenarios for the
  in-game bench.
- The ledger (a bounded ring, per fight): what was observed, predicted and
  recommended, why, whether it changed, whether a prediction was confirmed
  or contradicted, whether the outcome was measurable. Metrics: prediction
  accuracy; cooldown preservation (majors spent while `sufficient()` held);
  unnecessary overlap; recommendation stability (changes per 10 s); invalid
  recommendations (rejected by validation). No kill or win rate. Shown in the
  Live view and written to the recorder trace on Forever.

**Stage 12 — performance tuning** (Phase 17)
- `aio_esp_perf_test`'s native-call counting becomes `aio_intel_perf_test`
  with ceilings; per-module `every`; the nearest-10 player cap; a sweep after
  30 s; line of sight through `geometry.sight` only, at most 2 pairs a tick,
  and an `aio_intel_perf_test` ceiling that the client's `is_line_of_sight`
  is called zero times on Forever (the pattern `aio_esp_marks_test` now
  uses); event handlers filter on their
  first line (the `.api`'s own advice); stale state dropped on
  `jcore.unit.removed`, `jcore.target.changed`, `jcore.player.died`,
  `jcore.zone.changed`, `UNIT_PET`, `PLAYER_LOGOUT`; alerts de-duplicated by
  the existing 6 s instant-alert throttle; determinism: every module takes
  `now` and reads only `W`, so the bundle tests replay exactly.

### 3.4 The brief's phases mapped to the stages

| Brief phase | Stage | Brief phase | Stage |
|---|---|---|---|
| 2 state model | 1 | 10 kill window | 9 |
| 3 tactical states | 4 (hunter) and 10 (team) | 11 hunter | 4, 6 |
| 4 threat | 2 | 12 multiplayer | 10 |
| 5 cooldowns | 3 | 13 reactions integration | 5 |
| 6 prediction | 7 | 14 scoring | `score.lua`: started in Stage 2, extended by every stage |
| 7 baiting | 8 | 15 reasoning | `explain.lua`: Stage 4 onwards |
| 8 crowd control | 6 | 16 tests and analytics | 11 |
| 9 positioning | 4 | 17 performance | 12 |

### 3.5 Validation performed for Phase 1

- Read-only audit; no source file was changed. This document is the only
  addition.
- `node tools/jtest/run.js pvp` (one of the surveys, about 10:35): 76 passed,
  1 failed (`jcore_questdb_test`: the extracted quest database is missing;
  the known baseline).
- `node tools/jtest/run.js aio_react_test aio_hunter_pvp aio_pvp_test
  aio_boot_react aio_boot_forever_react aio_pvpx aio_pvpmarks jcore_boot`,
  run twice on the mid-refactor tree: at 10:58 **227 passed, 33 failed**; at
  11:05 **256 passed, 4 failed**. The files under test were rewritten between
  and during the two runs (`services/react.lua`, `react/init.lua` and
  `jcore/main.lua` were last written at 11:08:38, while this was being
  read), so neither number is a baseline for the PvP work. The four failures
  of the second run: `aio_react_test` "a real hunter, end to end" (the readout
  names the rotation's press, not the last press) and "if the reactions fail,
  there is no verdict …" (`has_line` on a nil readout line); `jcore_boot_test`
  "publishes JCore 1.8.1" (the test expects 1.7.9, the header says 1.8.0:
  the test and the header are being changed apart); `jcore_questdb_test`
  (missing extracted data, the known baseline). Every hunter PvP, PvP, PvP
  extras, PvP marks and boot-react test passed in both runs.
- The full suite was not run (it takes many minutes; each Forever boot is
  30–40 s).

**Double check, 2026-10-11 13:50–14:00.** Re-read against the tree, all
holding: the engine's `ROTATION_SCORE` 40, `VALIDATE_PER_LANE` 4, the PVP
context modifiers, `JOURNAL_MAX` 60, the memory's 48 / 6 s / 1.5–4 s /
10 s / 4 s (`services/react.lua`); the arbiter's bands (`cast.lua`
`M.PRIORITY`); the enemies service's 12 / 60 yd / 1.5 s / 0.5 s / 0.25 s /
0.15 s / 8 samples / 0.4 s; `world.lua`'s 40 / 8 / 10 s; `custom.lua`'s
`HISTORY_MAX` 15 and `engine.filter`; `draw.lua`'s `los_budget` 12; every
`catalog/hunter.lua`, `kite.lua`, `pvphunter.lua`, `hunter_pvp.lua`,
`pet.lua` (1128, 1312–1326 through `react.out_of_fight`), `enemies.lua`,
`rules/pvp.lua` STOPPERS, `pvpmarks.lua` `healer_at`, `classes/hunter.lua`
(the `pvp` profile 1841–1866; `multishot_wanted` on one target at tier 3),
`classwin_data.lua`, `.api`, `FOREVER_API.md`, dump and trace citation; the
dump's own cooldowns (Freezing Trap 30000 ms, Multi-Shot 6000 "shares its
cooldown with Aimed Shot", Aimed Shot 6000, Summon Hawk 6000, Rapid Fire
300000, Disengage 5000, Concussive Shot 12000); the talent node states; the
bench building no `W.pvp`; the test helpers named in §1.5; that the engine
keeps only `"player"` and `"pet"` cast events (`react.lua` 1727) and drops
unlearned spells at `offer` (1355); that nothing in JCore or the AIO requires
`pvp_helper`, `cooldown_tracker` or `health_prediction`. **Corrected:**
JCore's README now has a *Reactions (1.8.0)* section (it had none at 10:40);
the Rotation page's advanced *Reactions* section no longer exists, its
widgets are on the Reactions page under *Decisions* and *In the world*, and
`main.lua` is cited by id from now on; the README's "Forever is untouched"
line is at 2114, not 2078 (the file gained lines), so it is cited by section;
`rotation.lua` is cited by function; the spellbook count is given both ways
(51 class abilities in the AIO's line, 69 of 107 entries known in the dump);
a new untracked `jcore_react_test.lua` is noted. **Still unverified by me:**
the Era-side DB2 figures (Multi-Shot 10000 ms, Freezing Trap 15000 ms) come
from the client-data survey's read-only DB2 run and agree with the
catalogue's Era rows; the two Blizzard article URLs (§5). **Added at 15:10**
after a peer session's line-of-sight change (verified in the tree:
`geometry.sight`, `SIGHT_MASK`, `SIGHT_KEEP` 0.2, the calibration, the draw /
spells / ESP call sites, the README note, the CHANGELOG entries, the
`WALL_MASK` left as it was): §1.7, the §2 environment row, Stages 1, 4 and
12, and risk 9 now say LOS is `geometry.sight` only.

### 3.6 Stage 1 delivered (Phase 2, the shared PvP state model) — 2026-10-11

**Modified files**
- new `modules/react/intel/state.lua` (the model, ~700 lines) and
  `modules/react/intel/init.lua` (wiring, events, the switch);
- `modules/react/init.lua`: loads `intel` with `world`, `pvp`, `memory`, the
  client flags and `spell_name`; calls `intel.update(W, now)` after
  `pvp.read` and before `detect.update`; exposes `R.intel`; the readout's two
  rows; `intel.reset()` in `R.reset`;
- `modules/react/pvp.lua`: each control entry from `read_control` carries
  `source` ("aura" | "client") — one field, nothing else changed;
- `main.lua`: the Reactions page readout's row count 37/38 → 39/40;
- `CHANGELOG.md` (1.8.1 entry), `README.md` (*PvP intelligence: the picture*);
- new `tools/jtest/tests/aio_intel_state_test.lua` (25 tests) and
  `aio_forever_class_hunter_intel_test.lua` (1 boot test).

**What changed.** One `W.intel` per tick (reused), with observed fields flat,
inferred fields as `{ v, conf, why }` behind `intel.sure(x, threshold)`, and
the client's gaps in `S.unavailable` / `S.unknown`. Players keyed by GUID
(nearest ten within 40 yd carried in `foe_list`; entries kept 30 s), allies
twice a second, the mode (bg / arena observed; duel inferred; world_pvp;
solo / party / raid) and one "PvP active" answer with its signs. Events kept
per player in a ring of twelve: `UNIT_SPELLCAST_*` by token, `UNIT_AURA`
"added", Era's `SPELL_CAST_SUCCESS`. Line of sight only through
`geometry.sight`, every 0.5 s, nil kept apart from false. Facing from
`get_rotation` or `get_direction`, nearest four every 0.25 s, 0 = unknown.

**New reaction conditions:** none (Stage 5 / Phase 13).

**Client support.** Era and Forever. On Forever the combat-log handler is not
subscribed, `S.unavailable` lists the combat log by source, threat and the
mana maximum, and the readout's second row says "not on Forever: …". Whether
`UNIT_SPELLCAST_*` arrive for `target` / `nameplateN` tokens on Forever, and
whether other players' `get_rotation` / `get_direction` answer, are still
the Stage 3 probe items; the model degrades to "unknown" without them.

**Validation.** `node tools/jtest/run.js aio_intel_state`: 25 passed (the
one FAIL printed is the known `jcore_questdb` baseline, a file that fails to
load on every filtered run). `aio_forever_class_hunter_intel`: passed (46 s;
the readout read "Intel: world_pvp (solo) | 1 player(s) in 40 yd, 1 on you |
target ROGUE melee (0.90), 17 yd ranged, facing you, LOS unknown | …" and
"… not on Forever: combat log by source, threat, a player's mana maximum").
`aio_hunter_pvp` and `aio_pvp_test`: passing. The wider subset
(`aio_react_test aio_boot_react aio_boot_forever_react aio_hunter_test
aio_reactwin_snapshot aio_boot_forever_test aio_pvpx aio_pvpmarks
aio_react_marks aio_react_share aio_boot_era`): 282 passed, 2 failed, both
pre-existing (`jcore_questdb`; `aio_react_test` "a real hunter, end to end",
a PvE readout assertion that was already failing in the mid-refactor tree
at 11:05, before Phase 2, and that the intel rows never touch, since they are
added only while the picture is on). Not run in game.

**Known limitations.** The facing read spends up to 16 natives a second on
four players (`FACE_N × 1/FACE_EVERY`); allies' loss of control is read only
for the healer (what `world.lua` already reads); a player's mana is not read
at all; the `jcore.spell.cast` callback is not used (whether it fires for
other casters is UNKNOWN); the bench (`custom.bench`) still builds no
`W.intel` (Stage 5); the generated `pvp_data.lua` planned for this stage is
deferred to Stage 3, where its first consumer (cooldown tables) is.

### 3.7 Stage 2 delivered (the brief's Phase 4, threat assessment) — 2026-10-11

**Why this before the brief's Phase 3.** The brief's roadmap and its Phase
18 order put threats and cooldowns in the foundation right after the state
model; the tactical states (Phase 3) are built in Stage 4 on top of them.

**Modified files**
- new `modules/react/intel/threat.lua` (the read), `intel/score.lua` (every
  weight with its reason), `intel/data.lua` (class controls with reach,
  mobility names, what a protection covers, each table with its source);
- `intel/init.lua`: runs the threat read after the picture; the threat line
  on the first readout row; `I.threat`, `I.data`, `I.weights`;
- `intel/state.lua`: `foe.time_to_reach` from the row;
- `react/custom_data.lua`: conditions `f_threat` (choice), `f_threat_score`,
  `f_incoming_cast`, `t_mobility`, `t_defensive`; `D.THREATS`; the API text;
- `react/custom.lua`: the `threats` choices, the `FIGHT` readers `threat`,
  `threat_score`, `incoming_cast`, the `TARGET` readers `mobility`,
  `defensive`, `TEXT_READ.f_threat`;
- `CHANGELOG.md`, `README.md`;
- tests: new `tools/jtest/tests/aio_intel_threat_test.lua` (15); the bundle
  moved to `tools/jtest/mock/intel_bundle.lua` (shared), which also gained
  `rotation.detect_class` so your own reactions get their class bucket.

**What changed.** `W.intel.threat = { level, score, low, high, worst,
reasons, list, by_foe, highest, unknown, protection, incoming_cast,
changed, since }`. Twelve indicators (the brief's list, §1 of threat.lua),
each `{ name, base, tti, rel, raw, points, why, guid }`; urgency by
time-to-impact, health scaling 0.8–1.4, +15% with nothing to answer,
per-read reliability (Forever damage 0.7, unnamed class 0.6), protection
cover from our own buffs; levels with two lines and a 0.6 s dwell; the band
widened by UNKNOWN_WIDENS (10) per named unknown; `worst` = the level of
the band's top.

**New reaction conditions:** `f_threat`, `f_threat_score`,
`f_incoming_cast`, `t_mobility`, `t_defensive` (GUI and Lua). The Try-it
bench has no picture yet, so they read calm there (Stage 5).

**Client support.** Era and Forever. On Forever the lethal read's
reliability is 0.7 and "incoming damage is read from your own health drop"
is in `unknown`, so the band is wider and the readout says "up to N". The
control reaches are Era-verified names (`rules/pvp.lua`); Forever's kits
are unchecked, as the data file says.

**Validation.** `node tools/jtest/run.js aio_intel_threat aio_intel_state
aio_react_test aio_hunter_pvp aio_pvp_test aio_reactwin_snapshot`: the
intel files pass (15 + 25) after the last fix; the pre-existing
`aio_react_test` end-to-end readout failure and the `jcore_questdb`
baseline remain. Not run in game.

**Known limitations.** The weights are first values, not tuned; expected
damage is the field's measured race, not a per-ability estimate (Stage 3
adds observed cooldowns, Stage 9 effective health); the CC-reach indicator
knows only the classes and abilities in `data.CONTROLS`; mobility is
recognised by name only; a burst's "physical / spell" kind comes from
`pvp.ENEMY`; no indicator yet reads allies' cooldowns (not readable) or an
enemy's cooldown state (Stage 3).

### 3.8 Stage 3 delivered (the brief's Phase 5, cooldown tracking) — 2026-10-11

**Modified files**
- new `tools/jcheck/pvp_extract.js` → new generated
  `modules/pvp_data.lua` (Era 1.15.9.70003: 299 abilities; Forever
  1.60.1.70338: 297; per ability id, level, cd, cat_cd, category, gcd,
  mechanic, dispel, min, range, duration, school, ids, and on Forever
  `diminish`); `SpellCategories` read by its file id 1139939, resolved from
  the Era client's named root;
- new `modules/react/intel/cooldowns.lua`; `intel/score.lua` `CD` weights;
  `intel/init.lua` loads the data and runs the ledger after the threat, the
  readout's second row;
- `react/rules/pvp.lua` (*PvP: answer the burst*) and `react/rules/core.lua`
  (*Defensive cooldown*): a `validate` each, asking `hold_answer` /
  `hold_defensive`; nothing else in either rule changed;
- `react/custom_data.lua`: `t_cd_seen`, `t_cd_ready_in`, `me_protected`,
  the API words; `react/custom.lua`: `enemy_cd_seen`, `enemy_cd_ready_in`,
  `me.protected`, the two text readers;
- `CHANGELOG.md`, `README.md`; tests: new `aio_intel_cooldowns_test.lua` (12).

**What changed.** `foe.cds[name] = { seen_at, source, kind, conf, base,
category, cat_cd, ready_at, ready_eff, state (unknown | down | ready |
interrupted), ready_in, conf_now }`, fed from the recent ring; `foe.cds_cat`
per shared category. `W.intel.cds = { tracked, down, unknown, ready, target,
protection { names, left, physical, spell, melee }, reserved, answer, data,
data_build }`. Functions: `fact(name, class)`, `seen`, `ready_in`,
`sufficient(kind)`, `cheapest(kind)`, `answer(kind)`, `hold_answer`,
`hold_defensive`, `line`.

**New reaction conditions:** `t_cd_seen` (text), `t_cd_ready_in`
(text-number, 999 = never seen / unknown), `me_protected` (bool); Lua
`enemy_cd_seen`, `enemy_cd_ready_in`, `me.protected`.

**Client support.** Era and Forever halves of the data; the module picks
the running client's. On Forever the ledger's inputs are the aura records
(seen) and, if they arrive, the cast events (the open probe); the combat log
is absent. Forever's `diminish` column is carried for Stage 6 and not yet
read.

**Validation.** `node tools/jtest/run.js aio_intel_cooldowns`: 12 pass
(after two fixes: escapes and slows left out of the burst answers, since a
Wing Clip does not answer a Recklessness; and a test that meant to hide the
data file used `false`, which `require` reads as "not loaded"). The state
and threat suites still pass; the rules suites (`aio_react_test`,
`aio_hunter_pvp`, `aio_pvp_test`, `aio_reactwin_snapshot`) re-run below.
Not run in game.

**Known limitations.** The ledger keys by spell name, so a renamed rank or
a buff named differently from its ability is a separate entry; our own
cooldown costs come from the same tables by our class, else the catalogue;
reserve logic covers two cases only (a closing melee player, a burst back
soon); the "none" verdict names alternatives but does not rank them (Stage
4); Era's rune versions are left out, so Season of Discovery abilities are
unknown to the ledger.

### 3.9 Stage 4 delivered (the brief's Phases 3, 9, 11-hunter, 15) — 2026-10-11

**Modified files**
- new `modules/react/intel/states.lua` (the eighteen states as rows:
  `enter(X) → ok, why, conf`; `actions`, `avoid`, `reserve` as names or
  functions; `priority` as a number or a function; `emergency`), with the
  chooser (emergency at once, else DWELL 0.8 s, else the top candidate);
- new `modules/react/intel/position.lua` (the hunter's move: zone, advice,
  direction, yards, why, conf; `wait_for_shot`; the aspect for the moment;
  the gap-closer band from the ledger's `fact()` by the player's class);
- new `modules/react/intel/explain.lua` (the summary table and the alerts);
- new `modules/react/rules/intel.lua` (*Intel: the aspect for the moment*,
  kind `aspect`, through `P.aspects.auto_swap_on` / `can_switch`);
- `intel/score.lua` `TACTIC` and `POSITION`; `intel/init.lua` runs the
  three after the ledger, the third readout row, `I.summary`;
  `react/init.lua` `CLASS_EXTRA_RULES.hunter` gains `"intel"`; `main.lua`
  readout rows 40/41;
- `react/custom_data.lua`: `D.TACTICAL_STATES`, `D.ADVICE`, conditions
  `f_tactic`, `f_advice`, `me_dead_zone`, `me_safe_escape`, the API text;
  `react/custom.lua`: the choices, the readers, `TEXT_READ.f_tactic` /
  `f_advice`;
- `tools/jtest/mock/intel_bundle.lua`: `combat.duration`, a fake Aspects
  window (`G.aspect_switch`), a fake narration module (`G.said`);
- `CHANGELOG.md`, `README.md`; tests: new `aio_intel_tactics_test.lua` (13).

**What changed.** `W.intel.tactic = { state, prev, since, why, conf,
priority, emergency, actions, avoid, reserve, candidates, changed }`;
`W.intel.pos = { zone, advice, direction, target, yards, why, conf,
wait_for_shot, aspect, aspect_why, current_aspect, closer, closer_band,
third_parties, los }`; `I.summary()` = `{ state, state_why, state_conf,
threat, threat_why, threat_score, action, action_why, action_conf, move,
move_why, move_conf, cooldowns, suppressed, unknown }`.

**New reaction conditions:** `f_tactic` (choice), `f_advice` (choice),
`me_dead_zone`, `me_safe_escape`; Lua `fight.tactic`, `fight.advice`,
`me.dead_zone`, `me.safe_escape`.

**Client support.** Era and Forever. The Intercept band reads the running
client's table through the ledger (Era: Charge and Intercept 8–25); Forever
LOS confidence capped at 0.6; held/slowed reads use the rotation's
`debuff_up` and `pvphunter.held` (the latter still ignores the caster: a
Stage 6 fix).

**Validation.** `node tools/jtest/run.js aio_intel_tactics`: 13 pass after
the ordering fixes (RANGED_PRESSURE needs combat; a held melee player is not
CONTROL_DISTANCE's; the flag outranks a peel; the band names every closer).
The combined run with the other intel suites, the Forever boot and the
rules/window suites is recorded in the changelog line. Not run in game.

**Known limitations.** The states' actions are names, not scored
candidates (Stage 14 scores them); only one state acts (the aspect); the
move never drives the legs (kite.lua's step out is unchanged); no strafing
or LOS geometry beyond the one ray; BAIT_OPPONENT never enters (Stage 8);
KILL_WINDOW is half-confidence by design until Stage 9; the per-class
matchup notes of Phase 11 are expressed only through the data tables (reach,
mobility, protection), not as matchup-specific states.

### 3.10 Stage 5 delivered (the brief's Phase 13, Reactions integration) — 2026-10-11

**Modified files**
- `main.lua`: the Reactions page section *Advanced PvP Intelligence*
  (`intel_enabled`, `intel_alerts`, `intel_threat`, `intel_cooldowns`,
  `intel_tactics`, `intel_position`, `intel_kill`, `intel_team`; advanced:
  `intel_cc`, `intel_predict`, `intel_bait`, `intel_learn`), all on;
- `intel/init.lua`: `I.module_on(name)`; threat, cooldowns, tactics and
  position run behind their switches and reset when off;
  `intel/cooldowns.lua`: `enabled()`, the two hooks stand down;
  `intel/states.lua`: KILL_WINDOW behind `intel_kill`, PROTECT_ALLY /
  PEEL_ENEMY / OBJECTIVE_CONTROL behind `intel_team`;
- `react/custom.lua`: `bench_world` builds a `W.intel` from the situation
  (`pvp_threat`, `pvp_threat_score`, `pvp_tactic`, `pvp_advice`,
  `pvp_incoming_cast`, `t_mobility`, `t_defensive`, `t_cd_seen`,
  `t_cd_ready`, `t_cc_left`, `me_protected`, `me_dead_zone`,
  `me_safe_escape`, `pet_breaks_cc`); `situation_now` copies them from the
  live picture; readers `fight.kill_window`, `target.cc_left`,
  `pet.breaks_cc`;
- `react/custom_data.lua`: the three conditions, the `pvp_intel` preset,
  `DEFAULT_INFO` / `DEFAULT_CLASS` for the aspect rule, the API text;
- `reactwin.lua`: the bench's *PVP INTELLIGENCE* group; the Live view's
  *PvP intelligence* block;
- `CHANGELOG.md`, `README.md`; tests: new `aio_intel_window_test.lua` (5).

**New reaction conditions:** `f_kill_window`, `t_cc_left`, `pet_breaks_cc`.
Of the brief's Phase 13 list, not yet rowed: prediction confidence and
opponent pattern (Stage 7), and "crowd control about to expire" beyond the
control's own clock (Stage 6's planner).

**Client support.** No client-specific code in this stage.

**Validation.** `node tools/jtest/run.js aio_intel_window`: 5 pass (after
giving the preset a pet, since the pet-group conditions read "no pet"
without one). The combined run of the intel suites with `aio_react_test`,
`aio_hunter_pvp`, `aio_pvp_test`, `aio_reactwin_snapshot`, `aio_react_share`,
`aio_hunter_test`, `aio_boot_react`, `aio_boot_forever_react` and
`aio_forever_class_hunter_intel`: 356 pass, 2 fail, both older than this
work (the questdb baseline, and `aio_react_test`'s "a real hunter, end to
end" overlay assertion, which fails the same way on the committed tree
with the working-tree changes stashed). The window's
drawing is not unit-tested beyond `aio_reactwin_snapshot_test`, which still
passes; the group and the block are to be looked at in game.

**Known limitations.** The bench's picture is flat: no per-player ledger
beyond the target, no allies, no mode other than the situation's `where`;
the Live block shows the summary, not the per-player table; the four
unbuilt modules' switches gate nothing yet.

### 3.11 The Reactions page cleaned down to the engine and the layer — 2026-10-11

The user, after Stage 5: "Remove all other reactions from the menu that
don't have to do with these phases. Reason is we want to drop/delete old
stuff and not get it confused." Read as: the Reactions page (the menu's
*Reactions* tab) carries the engine's own switches, the decision readout and
the *Advanced PvP Intelligence* section, and nothing older; what leaves the
page is deleted, not hidden, so nothing keeps drawing without a switch.

**Removed from the page, deleted with their modules and tests**
- *PvP* (`react_pvp_trinket`): the dropdown. `rules/pvp.lua` *PvP: break the
  control* stays, its line fixed at Balanced (40); a saved mode is ignored
  (`aio_pvp_test` checks that). The cooldown economy (Stage 6's control plan
  with Stage 3's ledger) is to own the trinket decision.
- *PvP marks* (`modules/pvpmarks.lua`, `aio_pvpmarks_test`): the lowest
  player, the healers, our control rings, the enemy trinket ring.
- *PvP extras* (`modules/pvpx.lua`, `aio_pvpx_test`): the diminishing-returns
  tracker and rings, the flag carriers' beacon, the stealth rings. The two
  call sites (`classes/hunter.lua` `trap_first`, `rules/hunter_pvp.lua`
  `dr()`) now take every control as full. **Until Stage 6 there is no DR
  tracking anywhere in the plugin**; the audit's gap 6 ("DR lives in an
  overlay module") is now "DR is not tracked", and Stage 6 builds it from
  `pvp_data`'s `diminish` column with Forever at UNKNOWN until verified.
- *In the world* (`modules/plays.lua`, `modules/react/marks.lua`,
  `aio_plays_test`, `aio_react_marks_test`): the reaction rings, the
  rotation's pick, the kick lined up, who a reaction acted on, the control
  ring, the vanish and burst curtains. `react/init.lua` no longer loads
  `marks` or hands it each decision.
- `P.CURTAINS` loses its six Reactions-page entries (ten remain); the render
  job at priority 125 is gone; the World marks page's switch list no longer
  names them. `aio_boot_beacons_off_test` and `aio_esp_split_forever_test`
  trimmed to match.

**Kept.** *Reactions in the rotation* as a section of text only: its *Open
Reactions UI* button went a moment later (the user: "removed from being
accessed by the player but leave it in the code for future", so
`reactwin.lua` is loaded, rendered and openable only from code through
`P.reactwin.open`), and then its `react_active` switch (the user: "this
shouldn't be... reactions should automatically activate in PvP when PvP is
detected"): `R.active()` and `custom.master_on()` always say yes, a saved
value changes nothing, and the page's first live line reports the
intelligence layer's PvP detection (`W.intel.active` and its signs, `env.pvp`
under it). Read as: no manual gate on the engine; the PvE reactions keep
running (the rotation and the hunter work of the day rely on them), the PvP
side wakes on detection as it already did. Not touched: the Rotation page's
`rot_hunter_pvp_alpha` (the PvP hunter profile, which moves the character)
and `intel_enabled` (the brief's emergency switch),
*Decisions* (`react_overlay`, `react_explain_log`, the readouts), *Advanced
PvP Intelligence*. The Reactions window's code and every built-in reaction
(`rules/core.lua`, `hunter.lua`, `pet.lua`, `pvp.lua`, `hunter_pvp.lua`,
`intel.lua`) are untouched: they are the engine the brief said to integrate
into, and the user's rule was "without breaking Jambix's current reactions".
`react/pvp.lua` (the `W.pvp` read) stays: the intel layer builds on it.

**Validation.** The run in the changelog entry; nothing of this is seen in
game yet (the page's new shape).

**Open.** Whether the user also wants the Reactions window's built-in list
cut to PvP (it was read as "the menu", the page, not the window); whether a
kick line or the control ring should return under the intelligence layer's
own switches once `explain.lua` draws (Stage 11's bench and analytics is the
nearest place).

### 3.12 Stage 6 delivered (the brief's Phase 8, crowd control and pet control awareness) — 2026-10-11

**New files**
- `modules/react/intel/ccplan.lua`: the control plan. Per enemy player
  (`f.cc`): `held` { kind, name, left, breaks, source, category,
  category_conf, category_source, ours "yes" / "unknown" / "no",
  ours_conf, ours_kind }, `dr[category]` { count, last_at, ends_at,
  reset_at, name, conf, source }, `breakers`, `dots`, `pet_on`, `value`
  { kind, why, conf }, `chain`, `next_level`, `next_mult`. The tick's table
  (`W.intel.cc`): `target` (the plan row of the current target), `hold`
  { guid, name, value, left, conf, why }, `doomed`, `held_n`, `ours_n`,
  `pet` { recall, guid, name, why }, `dr_rule`, `unknown`. API:
  `category(name)`, `next_of(count)`, `next(S, guid, category)`,
  `update`, `reset`, `line`, `enabled`.
- `tools/jtest/tests/aio_intel_ccplan_test.lua` (10).

**Modified files**
- `intel/data.lua`: `DR_ERA` (DRList-1.0's Classic Era list by name, from
  the deleted pvpx.lua), `DR_FOREVER_TYPES` (DiminishType id → category,
  read off which spells carry each id in `pvp_data.lua`), `DR_LABEL`,
  `BREAKERS`, `OUR_DOTS`; `SOURCE` rows for each.
- `intel/score.lua`: `CC` (dr_window 18, dr_mult / dr_level, hold_min_left
  1.0, unknown_caster_conf 0.6, era_conf 0.85, forever_table_conf 0.9,
  forever_era_fallback_conf 0.5, value_points, dedupe 0.6, duration_guess
  8 / duration_cap 20, kill_hp 0.25, survive_hp 0.5).
- `intel/init.lua`: loads `ccplan` after the ledger (it reads
  `lib.cooldowns.fact` for durations and DiminishType, `seen` for the
  breakers), runs it behind `intel_cc` before the tactical states, appends
  its piece to the second readout row, resets it with the rest.
- `rules/intel.lua`: *Intel: keep the control on your target* (category cc,
  priority 72, kind hold, every 0.2; `enabled` intel_cc).
- `intel/explain.lua`: `summary.control`, `summary.control_why`; the pet's
  recall among `suppressed`; the plan's `unknown` in `unknown`.
- `modules/pvphunter.lua`: `caster_of(aura)` ("yes" / "other" /
  "unknown"); `held(unit)` skips another unit's aura and returns `ours` as
  its third value (the audit's defect 10).
- `react/custom.lua`: readers `target.cc_value`, `target.dr_next`,
  `target.cc_ours`; `target.cc_left` and `pet.breaks_cc` read the plan
  first; `TEXT_READ` rows; `choices("cc_values")`, `choices("dr")`;
  `bench_world` builds `I.cc` and the target's `cc` row; `situation_now`
  copies the three.
- `react/custom_data.lua`: `CC_VALUES`, `DR_LEVELS`; rows `t_cc_value`,
  `t_dr_next`, `t_cc_ours`; the preset; the API text; `DEFAULT_INFO` /
  `DEFAULT_CLASS` for the rule.
- `reactwin.lua`: two picks and a toggle in the bench's PVP INTELLIGENCE
  group; a *Control* line in the Live view.
- `main.lua`: the *Crowd control planning* switch's text (built; not under
  advanced any more).
- `classes/hunter.lua` `trap_first` and `rules/hunter_pvp.lua` `dr()`: ask
  `I.cc.next(S, guid, "incapacitate")`; Era's 0 holds the trap back,
  Forever's nil is taken as full.
- `tools/jtest/tests/aio_intel_window_test.lua`: the three new conditions
  on the bench.

**New reaction conditions:** `t_cc_value`, `t_dr_next`, `t_cc_ours`
(the plan's `pet_will_break_cc` is the existing `pet_breaks_cc`, now read
from the plan; `cc_expiring_in` is `t_cc_left`, likewise).

**Client support.** Era: categories by DRList's name list (0.85), the rule
DRList's. Forever: categories by the client's `DiminishType` (0.9; an
effect aura the table lacks takes Era's list at 0.5), the count observed,
the multiplier UNKNOWN and never claimed; the trap is laid whatever the
count. Whether Forever's `UNIT_AURA` arrives for enemy players' debuffs
(the count beyond the one control the row shows depends on it) and whether
its aura list fills `caster` are the two open probes.

**What was not done, and why.** No `pet_recall` reaction: pet.lua's own
"the pet kept off crowd control" (1.8.1, the hunter session's work of the
same day) recalls the pet; a second recaller would be the competing engine
the brief forbids. The plan says the reason and the window reads it; once
that work lands, pet.lua can read `W.intel.cc.pet` instead of its own
check (the plan's §3.2 "the three existing checks read the plan" is
deferred for the same reason: burst.lua and the peel's scoring are that
session's files today). Racial breakers (Will of the Forsaken, Escape
Artist) are not listed: the race is not read. An ally's damage about to
break a control has no read.

**Validation.** `aio_intel_ccplan_test`: 10 pass on the first run. The
combined run of the intel suites with `aio_forever_class_hunter_*`,
`aio_hunter_pvp`, `aio_hunter_test`, `aio_react_test`,
`aio_reactwin_snapshot`, `aio_boot_react`, `aio_boot_forever_react`,
`aio_boot_reactions`, `aio_pvp_test`, `aio_react_share` and `aio_aspects`:
408 pass, 2 fail, both older than this work (the questdb baseline and
`aio_react_test`'s end-to-end overlay assertion). Nothing of this is seen
in game.

### 3.13 Stage 7 delivered (the brief's Phase 6, opponent prediction) — 2026-10-12

**New files**
- `modules/react/intel/predict.lua`: per player `f.pat` (the counters:
  `cats[key]` { events { at, hit, w, why }, values, prior, hits_w, miss_w,
  n, conf, hits, total }, the pending chances, the openers) and
  `f.predict[key]` { category, v (the consequence), conf, samples, hits,
  total, prior, sure, why (the basis), response, fallback }. The tick's
  table (`W.intel.predict`): `target`, `top`, `players`, `observed`,
  `alerts` (queued until explain.lua says them), `calibration[key]`
  { predicted, right }, `not_built`. API: `on_our_cast(S, id, target_guid,
  now)`, `on_our_interrupted(S, id, now)`, `confidence(S, guid, key)`,
  `pattern(S, guid)`, `update`, `reset`, `line`, `enabled`, `learning`.
- `tools/jtest/tests/aio_intel_predict_test.lua` (11).

**Modified files**
- `intel/data.lua`: `PATTERNS` (key, consequence, response, fallback),
  `NOT_BUILT_PATTERNS`, `OUR_SLOW_CASTS`, `OUR_BURSTS`, `INTERRUPTS`, with
  `SOURCE` rows.
- `intel/score.lua`: `PREDICT` (half_life 60, keep 12, prior 0.5,
  prior_weight 2, threshold 0.6, min_samples 1.5, forming_show 0.5,
  inferred_weight 0.5, slow_window 2, control_window 1.5, burst_window 10,
  retreat_window 5, retreat_speed 1, interrupt_window 0.8,
  pet_sample_every 1, pet_sample_weight 0.5, defensive_low 0.35,
  prior_step 0.1, prior_min 0.2, prior_max 0.8).
- `intel/init.lua`: loads `predict` after the control plan, runs it behind
  `intel_predict` before the tactical states, hands it our own
  `UNIT_SPELLCAST_SUCCEEDED` / `UNIT_SPELLCAST_INTERRUPTED` ("player"),
  appends its piece to the third readout row, resets it with the rest.
- `intel/explain.lua`: `summary.predictions` (the surest first, the
  response; a forming one with its basis); the banner, one per player and
  pattern, after the state's and the move's.
- `react/custom.lua`: readers `target.pattern`, `target.pattern_conf`;
  `TEXT_READ` `t_pattern`; `choices("patterns")`; `FUNCS.prediction_confidence`;
  the bench's `foe.predict`; `situation_now` copies the two.
- `react/custom_data.lua`: `PATTERNS` (the keys and "none"); rows
  `t_pattern`, `t_pattern_conf`; the API text and word; the preset.
- `reactwin.lua`: a pick and a slider in the bench group; *Predict* lines
  in the Live view.
- `main.lua`: the two switches' texts (built).
- `react/init.lua`: the decision panel's pick line carries
  `rotation_state` underneath again ("pressed X" / "last X 0.4s ago; next
  Y"), the end-to-end test's assertion since the engine's move to JCore.
- `tools/jtest/tests/aio_intel_window_test.lua`: the two conditions and the
  function on the bench.

**New reaction conditions:** `t_pattern`, `t_pattern_conf`;
`prediction_confidence(category)` in Lua. The brief's Phase 13 list is now
complete but for a crowd-control planner's "about to expire" beyond the
control's own clock.

**Client support.** Nothing client-specific; the inputs are the picture's
(Stage 1's events) and ours. Open on Forever: enemy `UNIT_AURA` (the
defensive, the breaker as a buff), the aura list's `caster`, and whether
`UNIT_SPELLCAST_INTERRUPTED` arrives for "player".

**What was not done, and why.** *Chasing through bad terrain*: needs
`ctx.walkmap` behind the player (a geometry read the picture does not
make; Stage 12 or a later pass). Calibration against Stage 11's ledger: the
prior moves and the per-pattern counts are kept now, the ledger that
replays them is Stage 11's. No rule acts on a prediction: that is Stage 8's
(bait), and the tactical states read none yet.

**Validation.** `aio_intel_predict_test`: 11 pass. The combined run of the
intel suites with `aio_forever_class_hunter_*`, `aio_hunter_pvp`,
`aio_hunter_test`, `aio_react_test`, `aio_reactwin_snapshot`,
`aio_boot_react`, `aio_boot_forever_react`, `aio_boot_reactions`,
`aio_pvp_test`, `aio_react_share` and `aio_aspects`: 420 pass, 1 fail (the
questdb baseline, missing extracted data). The end-to-end overlay
assertion passes again. Nothing of this is seen in game.

**Reworked on the user's review, 2026-10-12 (after Stage 8).** Seven
points, all taken; the changelog entry *The predictor reworked on review*
lists them. In the table's terms: (1) `data.PATTERNS` rows carry `chance`,
`hit`, `miss`, `attribution`, `needs` (the inputs a miss rests on) and
`ability` (what the player must have usable); the defensive episode, the
quiet burst window, the let-through cast and the unseen opener are the
new misses and non-answers. (2) `e.p` (the rate) and `e.reliability` (n /
(n + 2), labelled) are separate; `e.conf` stays as the rate for the API;
the bait's confidence is their product. (3) `M.availability(S, f, name)`:
ready / down / estimated / unknown off the ledger; `skip()` counts a chance
the player could not answer. (4) `recent` (this encounter, within 120 s,
60 s half-life), `earlier`, `session` (600 s); `basis` says which carries
the headline. (5) `adapting` when recent and earlier disagree by
`adapt_gap`; the bait blocks on it. (6) `T.ledger[key]` { forecasts,
brier, right, bands } scored against the forecast snapshotted when the
chance opened; `T.calibration` keeps the sure ones; the prior moves on
those only. (7) `T.inputs` and `needs_live(key)`: a miss waits for its
input; `unverified()` counts the rest; `M.inputs_text()` for the Live
view. Tests: `aio_intel_predict_test` rewritten (16), `aio_intel_bait_test`
adjusted; the combined run after the rework: 431 pass, 1 fail (the questdb
baseline).

### 3.14 Stage 8 delivered (the brief's Phase 7, bait opportunity detection) — 2026-10-12

**New files**
- `modules/react/intel/bait.lua`: the tick's table (`W.intel.bait`):
  `target` (the surest bait) { kind mobility / defensive / interrupt / cc,
  guid, name, v, why, conf, press, counter, hold }, `list`, `hold_burst`,
  `hold_why`, `blocked`, `candidates`. API: `update`, `reset`, `line`,
  `enabled`.
- `tools/jtest/tests/aio_intel_bait_test.lua` (7).

**Modified files**
- `intel/data.lua`: `CLASS_DEFENSIVES`, `CLASS_INTERRUPT`,
  `INTERRUPT_REACH`, with `SOURCE` rows.
- `intel/score.lua`: `BAIT` (max_threat HIGH, cc_max_threat MODERATE,
  cheap_slow / cheap_control Concussive Shot, real_control Freezing Trap,
  cancellable_cast Aimed Shot, counters { Freezing Trap 1.0 room 10,
  Scatter Shot 0.9, Wing Clip 0.6 }, melee_gap 6, defensive_margin 0.15,
  unseen_conf 0.55, min_power 0.3, points { mobility 12, cc 10 },
  repeat_after { mobility 10, cc 15 }).
- `intel/init.lua`: `lib.sure = state.sure` (the one way a module reads an
  inference); loads `bait` after the predictor, runs it behind
  `intel_bait` before the tactical states, appends its piece to the third
  readout row, resets it with the rest.
- `rules/intel.lua`: *Intel: the bait* (utility, priority 52, every 0.3;
  `event_key` per bait kind and player, `handled_for` BAIT.repeat_after).
- `intel/explain.lua`: `summary.bait`, `summary.bait_why`; the held burst
  among `suppressed`.
- `react/custom.lua`: reader `fight.bait`; `TEXT_READ` `f_bait`;
  `choices("baits")`; the bench's `I.bait`; `situation_now` copies it.
- `react/custom_data.lua`: `BAITS`; row `f_bait`; the API text; the preset;
  `DEFAULT_INFO` / `DEFAULT_CLASS` for the rule.
- `reactwin.lua`: a pick in the bench group; a *Bait* line in the Live
  view.
- `main.lua`: the switch's text (built).
- `tools/jtest/tests/aio_intel_window_test.lua`: the condition on the bench.

**New reaction conditions:** `f_bait`.

**Client support.** Nothing client-specific.

**What was not done, and why.** The defensive bait does not hold the burst
itself: the burst is pressed by `burst.lua` inside the rotation (not a
reaction, so no engine hook), and that file is the hunter session's
today; `W.intel.bait.hold_burst` says the hold for it to read. The
interrupt bait cancels nothing (the brief's rule). The trinket bait's
"trinket not seen used" is pvp.lua's `trinket_down`; a trinket the ledger
never saw reads as ready, which is the conservative side (the bait is
offered, the real control waits). "Room to step" for the trap is 10 yd
between you, not a walk-map read.

**Validation.** `aio_intel_bait_test`: 7 pass. The combined run of the
intel suites with `aio_forever_class_hunter_*`, `aio_hunter_pvp`,
`aio_hunter_test`, `aio_react_test`, `aio_reactwin_snapshot`,
`aio_boot_react`, `aio_boot_forever_react`, `aio_boot_reactions`,
`aio_pvp_test`, `aio_react_share` and `aio_aspects`: 427 pass, 1 fail (the
questdb baseline). Nothing of this is seen in game.

### 3.15 Stage 11-a delivered (the fight debrief and the shared network) — 2026-10-12

Out of the plan's order, on the user's requests of the day: "each PvP
fight should also be a lessons learned", then the central network brief,
then "the database can be GitHub". The design, the audit of what was
reused, the data model, the routes, the local-first rules, the privacy
controls, the tests and what is not done are in `CENTRAL_NETWORK.md`; the
changelog entries *Fight debriefs* and *The shared PvP intelligence
network* list the files.

**New files**: `intel/debrief.lua`, `intel/central.lua`,
`modules/central_config.example.lua`, `tools/fightlog_server/{server,
validate, learn, github_ingest}.js` with their tests and README,
`.github/workflows/jambix-central.yml`, `tools/jtest/tests/aio_intel_debrief_test.lua`
(8), `aio_intel_central_test.lua` (8).

**Modified**: `intel/predict.lua` (`score_forecast` hands each scored
forecast to `central.observe`; a new pattern's prior comes from
`central.prior_for` when the model calls it reliable and enough fights
back it, and the basis says so), `intel/score.lua` (`DEBRIEF`, `CENTRAL`),
`intel/init.lua` (loads central before the predictor and the debrief last;
our casts to the debrief; death closes the fight before the picture forgets;
`central.update` after everything), `main.lua` (the section *Fight debriefs
and the shared network*: two debrief switches on, three consent switches
off, two buttons, the notice, 14 live lines).

**Then the collector brief** (*PvP Combat Experience & Lessons Learned
Collector*, the same day): `intel/episodes.lua`, the decision episodes --
`CENTRAL_NETWORK.md` §10 has the table of opportunities, the record, the
outcome rules, the contamination flags and the lesson confidence; the
changelog entry *The decision episodes* lists the files
(`episodes.lua`, `data.lua` `EPISODE_TYPES` / `OUR_DAMAGE` /
`OUR_COOLDOWNS`, `score.lua` `EPISODES`, `init.lua`, `debrief.lua`,
`central.lua`, `main.lua`'s switch, `validate.js`, `learn.js`,
`aio_intel_episodes_test.lua` 13, `test.js` +2).

**The brief's Phase 16 left**: the analytics ledger across sessions (the
debrief log is per machine, 50 fights), the test bench's replay of
recorded fights (Stage 11-b), and the network's first live run.

**Validation.** Lua: `aio_intel_debrief_test` 8, `aio_intel_central_test`
8, `aio_intel_episodes_test` 13; Node: `test.js` 10,
`github_ingest.test.js` 3. The combined run of every intel suite with the
hunter, reaction, window, boot and PvP suites: 469 pass, 1 fail (the
questdb baseline). Nothing of this is seen in game or against a live
repository.

### 3.16 The global learning engine, and the first live death — 2026-10-12

Out of the plan's order, on the user's brief *Global PvP Learning,
Prediction & Tactical Knowledge Engine*: the service side of the brief's
Phase 16 ("learns from a database"). `CENTRAL_NETWORK.md` §11 is the
design; the changelog entry *The global learning engine* lists the
pieces. In one line each: learning groups at four levels with the game in
every key and a backoff the client walks (`groups.js`, `central.lua
prior_for`); a trust screen that quarantines duplicates, replays,
impossible numbers and floods with reasons and an audit (`trust.js`);
opponent models with intervals on the effective count, calibration,
conditional rates, drift by build and a matchup-apart flag (`learn.js`);
eight tactics as stratified associations with counterexamples and
staleness, never causes; a chronological holdout against production, the
prior and a baseline (`evaluate.js`); release gates, a hold on noise, a
canary by contributor id, promotion, rollback, and the model version in
every batch for the canary's monitoring (`release.js`). No model is a
rule: the client reads rates into the prior and shows validated tactics
as words.

**The first live PvP death** (the user's log the same day, a fight with
Astro, level 30): the debrief's `os.time` crashed in the game's sandbox
and stalled the whole layer until reload; the network client's seed had
the same call. Fixed with one wall clock and one seeded id maker on the
layer's `lib`, and the fight's close made of five protected steps. The
same log showed *Shed threat* pressing Disengage (a threat drop on
Forever) and the pet's taunt asking for Growl at a player: *the pet lost
its mob* is no longer true for a player, and the taunt never lists one.

**Validation.** Node: `learn.test.js` 10, `test.js` 10,
`github_ingest.test.js` 3. Lua: `aio_intel_central_test` 12,
`aio_intel_debrief_test` 9, `aio_react_test` +1. Each of the two live
fixes has a test that fails on the old code with the log's own symptom.
The learning engine is tested on synthetic records only; no contributor
has sent one.

### 3.17 The relook of the first real fights — 2026-10-12

The user asked what was left and what needed a relook; nine items came
back, and "let's fix the first 9". Read from the user's own fight log, the
upload queue and the API recorder: (1) a player that left was recorded as
dead (JCore's gone-is-dead) -- a death now needs a unit still there,
rogues and druids get 30 s to come back; (2) no enemy ability reached a
fight's record although Forever fires the events -- tokens now resolve
through three paths and every enemy event kept or dropped is counted per
fight (`feeds`), and the defensive bait no longer treats silence as
evidence; (3) "goes for your pet" sampled every second -- one chance a
15 s window now; (4) a Freezing Trap broke under a standing hold -- the
hold now stops an attack already running, and the debrief names what
broke a control; (5) upload problems are kept on disk; (6) the field
checks (`intel/fieldcheck.lua`) let the game answer the hunter work's
assumptions and measure Forever's DR; (7) the learning engine checks the
threat weights against measured outcomes; (8) one issue per fight, hourly
filing, the two-player rule as a repository variable; (9) a new crash
(19:04, a bag item asked for its position by JCore's object sweep) fixed
in JCore's sweep and World Click's mouseover -- the earlier crash
workarounds (no Forever sight rays, the UI over the game's windows) are
unchanged, nothing new explains the crashes they answer.

**Validation.** Lua: `aio_intel_debrief_test` +5, `aio_intel_predict_test`
(the pet test rewritten), `aio_intel_bait_test`, `aio_intel_central_test`
(one issue per fight), new `aio_intel_fieldcheck_test` (5), new
`jcore_units_item_test` (fails on the old sweep). Node: 27.

### 3.22 The second live batch — 2026-10-13

Seventeen fights with players arrived as issues #14 to #30 between 00:16
and 00:39 UTC (hunter 30, Forever PvP realm; 12 won, 2 lost both 1 against
5, 3 fled), on top of the first three. Read back from the issues and
replayed through the service locally, they showed four faults; the user:
"fix all the issues".

1. **Attribution.** The debrief's `used` and the predictor's defensive
   habits read every helpful aura on a player as the player's own: a
   priest's Power Word: Shield on a rogue (issue #24), a paladin's Blessing
   of Protection on a priest (#14), and an Aimed Shot cast row on a paladin
   with no enemy hunter in the fight (#17, a token read a moment late). The
   UNIT_AURA record carries the caster's token (`args[9]`); `state.on_aura`
   keeps it as `row.by` ("self" / "other" / nil) and `state.own(f, row)`
   (also `lib.own`) answers false for another's aura or another class's
   spell (`pvp_data.lua`, unique names; PET, RACIAL and shared names give
   no owner), true for its own aura, nil when nothing says. Readers of "its
   doing" skip false: `cooldowns.feed`, `predict` (every pattern's chance
   and hit), the debrief's `used`. Readers of "what is on it" read every
   row: threat, kill window, team, episodes, the control plan.
   `S.events.not_own` counts the rows recorded as another's (at entry, when
   the class is known); the feeds carry it.
2. **The fight's clock.** `debrief.T.fight` stays on a closed fight
   (`T.open` is the running flag). `episodes.open_windows` and
   `predict`'s observation stamp read `T.fight` alone, so between fights
   (and on a fight's first tick, before the debrief opens it) they timed
   from the last fight; those episodes were sent with the next fight past
   its end (#19, #21, #27, #28, #30) and one forecast too. Both read
   `T.open` now; `episodes.close_fight(S, now, started_at)` times each
   episode from the fight's start (one that opened just before it at 0)
   and drops one whose window closed before the start
   (`summary.dropped_outside`).
3. **Rounding.** `encounter.duration` was `floor(x + 0.5)`: a 0.3 s kill
   was "0 s" with forecasts in it (#21, #30). It is `ceil` now (the service
   validates whole seconds).
4. **Brier.** The lesson's `predictions.brier` was the sum of squared
   errors; it is the mean, the sum as `brier_sum`.

The records carry `client.rev = 2` (`central.lua M.REV`). The service
repairs revision 1 (`trust.js repair`, CENTRAL_NETWORK §14): with the
repair all twenty fights are used, twelve records repaired, none set
aside. What the batch says otherwise, for the stages: enemy casts barely
reach the picture (42 cast events against 343 auras; 13 of 17 fights had
none), so the cast-based patterns stay thin; the hold and the bait never
fired in 17 fights (nothing to judge them on yet); the movement advice was
followed 3 times, not followed 14, unknown 21; the network's forecasts
score a coin's 0.25.

**Validation.** New `aio_intel_attribution_test` (5); the server's
`learn.test.js` gains the repair and the fights table (28 Node tests).

---

## 4. Risks, unknowns, and what only the game can answer

1. **The engine is moving while this is written.** Stage 1 must start from a
   committed tree; until the 1.8.0 move is committed, line numbers in
   `init.lua` and `services/react.lua` are unreliable, and the rule shape the
   AIO uses is JCore's (`react.lua` header), identical in substance today.
2. **Forever's enemy cast events** (`UNIT_SPELLCAST_*` for non-player tokens)
   are the hinge of cooldown tracking. If they do not arrive, Stage 3 is
   aura-proxy only and its confidence ceiling is 0.7.
3. **Forever's DR, trinket and PvP rules** are unread. `pvp_extract.js` must
   read Forever's `SpellCategories.DiminishType` and `ItemEffect`, and the
   result must be verified in a battleground before any DR claim is shown as
   more than "unknown".
4. **Loss of control on Forever**: the recorded example answer is
   `valid = false`. If it never answers, "what controls me" is debuff names
   only (already the fallback) and helplessness is inferred.
5. **Every in-game assumption listed in CHANGELOG 1.7.6** for the PvP hunter
   still stands (a trap under a standing player springs; Feign Death fails a
   player's cast on Forever; hawks break a trap; stop-attack ends Auto Shot on
   Era). Stage 4 inherits them and must not add to the list without a
   recorder session.
6. **The character is level 26.** Most of the brief's hunter ability list is
   not in the book; the tests must run both the level-26 spellbook (from the
   dump) and a level-60 spellbook, so that nothing is built only for
   abilities the character will have later and nothing assumes them now.
7. **No Forever hunter PvP guide exists.** The sources for the weights are
   the Classic guides the 1.7.6 work already used (Icy Veins' Classic Hunter
   PvP guide; Wowhead's Classic hunter dueling guide by class) and Blizzard's
   three articles named in the brief; every weight they inspire is documented
   as such and is data or a setting, not a literal.
8. **The loader's helper modules** (`pvp_helper`, `cooldown_tracker`,
   `health_prediction`) are candidates on Era only. Stage 3 may probe
   `cooldown_tracker:get_last_cast_time` on Era as a cross-check; nothing
   depends on them, and on Forever they are not used (the MoP fallback).
9. **Line of sight can crash the Forever client.** Build 70338 asserts on a
   ray tested against an unloaded model (§1.7). Every LOS read in the intel
   layer goes through `geometry.sight`, is bounded per tick, and treats nil as
   unknown; a test asserts the native is never called on Forever. The ESP row
   that asked the native once per frame is the cautionary example for any
   per-frame read this layer might be tempted to add. The walk map's wall
   rays still include doodads (`walkmap.lua` `WALL_MASK`), so the positioning
   stage must not trigger walk-map rays on Forever either; it reads only what
   the map already holds.

---

## 5. Sources named in the brief (checked 2026-10-11)

| Reference | What was found | Use |
|---|---|---|
| Blizzard, *Balancing the Cooldown Equation* | "Opening Moves: Balancing the Cooldown Equation", the third of Blizzard's *Opening Moves* series: https://worldofwarcraft.blizzard.com/en-us/news/21464978 | Stage 3's economy: trade cooldowns, force the enemy's defensives before spending offensives |
| Blizzard, *Positioning and Preparation* | the *Opening Moves* positioning article ("Preparing the Front"); only an Icy Veins forum mirror surfaced, the Blizzard URL is **not resolved** | Stage 4's positioning advice |
| Blizzard, *Adapt, Survive, and Thrive* | the fourth of Blizzard's *Midgame Moves* series; only an Icy Veins forum mirror surfaced, the Blizzard URL is **not resolved** | Stage 7's adaptation and prediction correction |
| Wowhead, Classic Hunter dueling by class | https://www.wowhead.com/classic/guide/hunter-dps-pvp-dueling-classic-wow (the `tw` locale copy surfaced in search; the same path serves English): kiting, resets with Scatter Shot, Feign Death and Frost Trap, per-class advice | Stage 4 and the per-class matchups of Phase 11 |
| Icy Veins, Classic Hunter PvP | https://www.icy-veins.com/wow-classic/classic-hunter-pvp-guide: Hawk Eye range, Concussive Shot, the Frost Trap with Entrapment / Clever Traps / Trap Mastery, Marksmanship with Survival's Surefooted and Deterrence | the same; note the Classic talents it leans on (Trap Mastery, Improved Feign Death) do not exist on Forever (§1.9) |
| Forever hunter PvP guides | none existed on 2026-10-10 (CHANGELOG 1.7.6); not re-searched today | — |

None of these was fetched in full during Phase 1; the weights they inspire are
to be documented at the constant that uses them (§3.1, rule 6).

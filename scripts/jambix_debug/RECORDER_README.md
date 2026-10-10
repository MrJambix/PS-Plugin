# Forever API recorder

JCore records what the Forever client actually answers to every `core.*` call
and every `game_object` method, plus the game events it sends. The `.api` stubs
in `scripts/.api` describe each call per client ("always nil on Forever",
"Forever unverified"), but most of the Forever notes were written from the
core's source, not from a running Forever client. The recording is the
evidence for fixing them.

It runs on **Forever only**. On Classic Era and every other client it does
nothing: it wraps nothing, reads nothing and adds no page.

Code: `services/recorder.lua` (JCore 1.5.4; the format 2 layout since 1.5.12).
Report tool: `tools/jcheck/recorder_report.js`. Generated reference:
[FOREVER_API.md](FOREVER_API.md).

---

## Using it

1. Play on Forever with JCore 1.5.4 or later. Recording starts at load; there
   is nothing to switch on.
2. **JCore → API recorder** in the menu shows what it has seen so far. It also
   has **Save now**, **Clear recording**, and a **Record calls** switch. The
   switch stops recording and puts every original call back.
3. The recording is saved to `scripts_data/jcore/jcore.recorder.json`. A save
   happens within 20 s of anything new, every 2 minutes otherwise, and when
   recording stops. The next session on the same client adds to the file.
4. Out of the game, read it:

```
node tools/jcheck/recorder_report.js            # the file above
node tools/jcheck/recorder_report.js <file> --all
node tools/jcheck/recorder_report.js --ns input # one namespace, every function
node tools/jcheck/recorder_report.js --md       # writes scripts/jcore/FOREVER_API.md
```

### The recording's layout (format 2, JCore 1.5.12)

One entry per function, merged across sessions. A row is only added for
something not seen before, so a call made a million times costs the same few
lines as one made ten times. `functions` holds the `core` calls by path and
`methods` holds the `game_object` methods. The file opens with an `_about`
block that explains each field.

```json
"input.cast_target_spell": {
  "kind": "action",
  "status": "answers",
  "calls": 26, "inspected": 26, "tallied": 26, "empty": 0, "errors": 0,
  "first_session": 3, "last_session": 25, "origin": "C",
  "args": ["num", "obj"], "returns": ["true"],
  "answers": { "true": 26 },
  "examples": [
    { "call": "(1784, obj)", "answer": "true", "shape": "true",
      "by": "update jcore/services/cast:301 < jambix_aio/modules/rotation:412",
      "then": ["UNIT_SPELLCAST_SENT(player)", "UNIT_SPELLCAST_SUCCEEDED(player)"] }
  ],
  "triggers": { "update jcore/services/cast:301 < jambix_aio/modules/rotation:412": 26 },
  "effects": { "windows": 26, "UNIT_SPELLCAST_SENT(player)": 24, "UI_ERROR_MESSAGE:ERR_ABILITY_COOLDOWN": 2 }
}
```

| Field | What it says |
|---|---|
| `kind` | `read`, `action`, `loader` (the loader's own settings, such as `set_console_key`), `file`, `net`, `paint` or `clock`. Paint and clock calls are only counted. The kind is worked out from the name: a getter filed as an action costs a window, but an action filed as a getter would lose its effects, so the rule leans towards `action` |
| `status` | `answers`, `always empty`, `only false`, `returns nothing`, `raises`, `answers (sometimes raises)` |
| `args`, `returns` | The value kinds seen at each position: `num`, `0`, `str`, `""`, `true`, `false`, `nil`, `tbl`, `{}`, `obj`, `fn`. `num\|nil` means both were seen |
| `examples` | Up to 8 distinct calls (other arguments or another answer shape), and 4 more for answer shapes not seen yet. Each has `by` (its trigger) and, for an action, `then` (the first events that followed it) |
| `triggers` | **What triggered it.** The phase comes from JCore's scheduler entry points and event bus, which are hooked while recording: `update`, `render`, `menu`, `panel`, `pre_tick`, `event NAME`, `on jcore.topic`, `recorder` (the catalog's own reads) or `outside JCore` (the loader's scripts, or a plugin's own native callback). After it comes the call site `file:line`, read with `debug.getinfo` when the client exposes it. If the site is inside a JCore service, the plugin line behind it follows the `<`. Counted over inspected calls, 12 distinct triggers at most |
| `effects` | **What it does**, for actions only. Each call opens a 2 s window, cut short by the next call of the same action. `windows` is how many calls were watched, and each event is how many of those calls it followed. Events are counted by tag (`UI_ERROR_MESSAGE:ERR_ABILITY_COOLDOWN`) or by kind of unit (`UNIT_AURA(nameplate)`) |
| `origin` | `C` for the client's own function. `Lua` for one another script defined on top of it: the izi SDK and similar libraries add hundreds of methods to the shared object metatable, and these are kept apart from the client's API |

Each event has `layouts` (one example per argument layout, with its value
kinds), `after` (the actions called in the 2 s before it) and `unprompted`
(how often no action was being watched, meaning the game or the player did
it). `coverage` counts, per namespace, the functions the client exposes and
how many were ever called. `sessions.log` keeps the last 30 sessions, each
with what it `learned`: new functions, examples, triggers, effects, events
and layouts. A session that adds nothing shows up as all zeros.

A format 1 file (JCore 1.5.4 to 1.5.11) is converted at load, and nothing in
it is dropped. Its samples become examples, its answer shapes give the
answer kinds, and every entry counts as already known. It has no triggers
or effects; those start with the first session on 1.5.12.

**The report's lift.** "UNIT_SPELLCAST_SENT(player) 24/26 (92% x14.0)" means
24 of the 26 calls watched were followed by that event. It came 14 times more
often after this action than after the calls of every action together. An
event the game sends all the time, such as the combat log in a fight, follows
everything alike and has a lift near 1. What the action actually does stands
out.

### What the report lists

| Section | Meaning | How much to trust it |
|---|---|---|
| Coverage | Per namespace: functions exposed, called, and not in `.api` | Solid |
| Actions | Every action called: what triggered it, its answer, and the events that followed | Triggers solid; effects are what FOLLOWED, so weigh them by the lift |
| New API | In the client's `core` table, not in `.api`: what each answered and who called it | Solid |
| Missing on the client | Documented in `.api`, but not in the client's `core` table | Solid |
| Always empty | Called, and every answer was `nil`, `0`, `""` or `{}` | A lead, not proof (see below) |
| Raised | Called, and it raised an error; the message and arguments are kept | Solid |
| Notes to fix | `.api` says Forever answers empty or does nothing, but the client answered with data | Solid |
| Always false | A predicate that never answered `true` | Weak: the state may simply not have happened |
| Game object | The same lists for `game_object` methods; the methods other scripts define (origin `Lua`) listed apart | As above |
| Events | Every game event seen, with an example of each argument layout, the actions called just before it, and how often it came unprompted | Layouts solid; "after" as weak as effects |
| Never called | Documented and on the client, never called: the answers are unknown. `--ns <namespace>` lists one namespace in full | The to-do list |

**"Always empty" is not proof of a broken call.** A level-3 character really
has no talents. Every mob in a starter zone really is classification 0. A
rogue really has no pet. Before calling a read broken, ask whether a working
client would have answered something else in that session.

### What is and is not recorded

- Every function on `core` and its namespaces is recorded, including one level
  of sub-namespace (`core.addons.questie.*`), and so is every `game_object`
  method.
- The clocks and the graphics paint calls (`rect_2d`, `text_2d`,
  `draw_texture` and so on) are only counted. The graphics readers are recorded
  in full, including `w2s` since the update after the first recording.
- Never wrapped: `core.menu`, `core.get_owning_plugin_name`, `register_*` and
  the log calls. The loader may decide which plugin is calling them by walking
  the Lua stack, and a wrapper would sit on that stack.
- `core` is shared, so the loader's own scripts are recorded too. Calls like
  `get_user_role_flags`, `is_rendering_kick_warning` and
  `input.get_control_object` are the loader's, not JCore's.
- Each function's first 40 calls per session are inspected in full, and every
  97th after that. Inspection covers the argument and answer kinds, the shape
  and the trigger. Every call is counted and its first answer checked for
  emptiness. Errors on calls that are not inspected pass through uncounted.
- Every call of an action opens its effect window, not only the inspected
  ones, so `effects.windows` equals the calls made while recording.
- The call site needs the `debug` library. The file's `triggers_from` says
  whether the client had it ("the call stack") or not ("the phase only"). The
  loader's sandbox may leave it out; the phase is recorded either way.

---

## The first recording (2026-10-02)

Forever beta (`wow_forever_beta_us`), map 2521, a level-3 rogue, about two
minutes of questing with a fight or two. JCore 1.5.4, Jambix AIO with the ESP
on. 172 functions were called and 20 event types seen. The other 611
documented functions were never called, so their answers are still unknown.

### Broken on Forever (strong evidence)

| Call | What it answered | Why that is wrong | Who it hurts |
|---|---|---|---|
| `COMBAT_LOG_EVENT_UNFILTERED` | **No arguments at all**, 245 of 245 events | `.api` says the args are the flattened `CombatLogGetCurrentEventInfo()` payload | `react/damage.lua` never learns what a skill hits for; the rotation's damage weighting falls back to tooltip estimates |
| `game_object:get_power(3)` | 0 every time (155 inspected of 11,250) | A rogue's energy is 0 to 100 and was being spent | Anything that gates on energy |
| `spell_book.get_global_cooldown()` | 0 every time (143 inspected of 9,995) | Casts went off throughout, so the GCD must have been running some of the time | Rotation timing, weaving |
| `game_object:get_nameplate()` | nil every time (365) | Nameplates were up: the spellcast events name `nameplate1`–`nameplate3` | The ESP's plate logic sees nothing; the ESP is **off on Forever since AIO 1.41.0**, pending a rewrite |
| `object_manager.get_object_from_guid("nameplateN")` | nil 7,192 of 7,193 | Same | Same |

| `game_object:get_name()` on units | `""` in 226 of 263 inspected calls; the only real names were items' | Mobs and players have names | Every name the ESP or the logs would show is blank |

### Suspicious (check in a session that exercises it)

| Call | What it answered | What would settle it |
|---|---|---|
| `game_object:get_attachment_name_position()` | `{0,0,0}` every time (9,741) | A unit whose model is loaded should have a head point. JCore already treats zero as "not loaded" and falls back to position plus height |
| `game_object:get_target_marker_index()` | 16 | No raid marker should be 0. Put a marker on a mob and see what it answers |
| `inventory.get_item_durability(slot)` | `{current=0, max=0}` | Check with damaged gear on |
| `game_object:get_max_power(0)` | 0 every time | Only asked of units with no mana in this session; ask a caster mob |
| `game_ui.get_talent_info`, `get_active_talents` | `{}` | Level 3 has no talents; check at 10 or above |
| `game_object:get_classification()`, `get_race_id()` | 0 | Normal mobs are 0; check an elite and a player |

### Works on Forever (confirmed)

Unit position, health, level, class, target, auras/buffs/debuffs (Forever spell
ids above 1,000,000 included), casting state and cast times, threat situation,
loss of control, movement, `spell_book.get_spell_cooldown`,
`get_spell_cast_time`, `get_spell_costs`, `get_spell_description`,
`is_spell_known`, `is_usable_spell`, `get_visible_objects` (about 50 objects),
missiles, bag contents, file reads under `Interface/AddOns` and `scripts_data`,
`load_texture`, `get_screen_size` (3440×1440 here), `get_cursor_position`.

### Checked with the trace (2026-10-02)

- **The projection is correct.** Both `w2s` and the client's own
  `world_to_screen` put the player's feet at x = 1720 on a 3440-wide screen,
  dead centre, and they agree on every point. A unit with no screen position
  was off screen.
- **The game keeps nearby units visible.** Of 2,650 trace lines, no nearby
  unit had `is_visible` false. Units left the client's list only at about
  100 yd ("the client no longer has it").
- **The mobs' models flickered with the ESP off.** No overlay can cause that.
  It is the client or the loader's renderer, not a call these scripts make.

### Event layouts seen

- `UNIT_AURA`: the per-aura records `.api` describes:
  `"added", unit, instance_id, spell_id, name, stacks, duration, expiration, source, is_helpful, is_harmful`.
- `UNIT_SPELLCAST_START` / `STOP`: `unit, cast_guid, spell_id, cast_bar_id`. The
  fourth field, `"CastBar-…"`, is not in `.api`.
- `UNIT_SPELLCAST_INTERRUPTED`: `unit, cast_guid, spell_id, nil, cast_bar_id`.
- `UNIT_SPELLCAST_SENT`: `unit, target_name, cast_guid, spell_id`.
- `UNIT_SPELLCAST_SUCCEEDED` / `FAILED` / `FAILED_QUIET`: `unit, cast_guid, spell_id`.
- `UI_ERROR_MESSAGE` / `UI_INFO_MESSAGE`: `message_type, text, error_name`.
- `LOOT_OPENED`: `auto_loot, is_from_item`.
- The spell-cast callback:
  `{ spell_id, cast_time (ms), caster, target }`. The legit one passes
  `(spell_id, caster, target)`.

### The client's API surface against `.api`

- **Documented but absent:** `spell_book.get_buff_description`,
  `graphics.load_image`, `graphics.draw_image`, and the `game_object` methods
  `get_aura_data`, `get_buff_data`, `get_debuff_data`.
- **Present but undocumented:** 55 core functions, including
  `graphics.world_to_screen`, `input.is_key_down`,
  `input.get_control_object` / `set_control_object`, `read_cvar` /
  `write_cvar`, the `read_lua_*` family (`read_lua_integer`, `read_lua_string`,
  `read_lua_table_integer`, `read_lua_table_string`), `execute`, `write_file`,
  `spell_book.is_player_in_control` and `spell_book.is_usable_spell`. On
  objects there are also `get_animation_id` and `get_memory_address`.
- **Sandbox:** `read_file(".build.info")` is nil, as on Era: the game's
  archives cannot be read in-game (see `jcore.casc.json`).

### Cost worth knowing

`object_manager.get_arena_frames` ran about 110 times a second on a map with
no arena. JCore's group service asks once per tick through its cache, and the
loader's own scripts ask too. It is cheap, but it is a native call that
answers `{}` every time outside an arena.

---

## The trace

The per-call totals cannot say what happened to ONE unit, in order. The trace
can. It is a timeline of plain lines, the newest 6,000, written with each save
to `scripts_data/jcore/jcore.trace.txt`. The first save of a session moves the
previous session's file to `jcore.trace.prev.txt`, so a reload keeps the last
one.

- **`sweep + <id> d=.. dead=.. enemy=..`:** JCore's unit sweep gained a unit.
- **`sweep - <id> <probe>`:** the sweep lost a unit. The probe says whether
  the client still has it, and if so whether it is valid, visible or dead, and
  how far away it is.
- **Any plugin's own lines:** a plugin adds them with
  `ctx.emit("jcore.recorder.trace", text)`. The ESP's per-unit and per-frame
  lines were removed with the ESP (AIO 1.41.0). Add new ones for whatever is
  being rewritten next.

IDs are the guid's last 10 characters: 6 were seen shared by two mobs.

**No repeats (JCore 1.5.12).** A line that says what an earlier line said,
numbers aside (the same unit in the same state, a few yards on), is skipped
for 60 s. When it is written again it ends with "(xN since)". A change of
state (`drawn@` to `offscreen`, a new name) is a different line and is
written at once. Before this, the Forever ESP's per-frame lines made up four
fifths of the file: the same mark in the same state, hundreds of times. The
page shows how many lines were kept and how many repeats were skipped.

## The catalog (JCore 1.5.8)

Totals say what a call answers in general. The catalog keeps every THING the
client names, merged across sessions into
`scripts_data/jcore/jcore.catalog.json`, and printed at the end of the report:

| Section | What is in it | Where it comes from |
|---|---|---|
| spells | every spell id seen, with name, school, cast time, ranges, base cooldown, costs, description, base/override id, known; where it was seen (spellbook, cast_player, cast_npc, cast_other, aura, talent); which npcs cast it | the spellbook every 10 s, `UNIT_SPELLCAST_*`, `UNIT_AURA` records, JCore's enemy casts; facts asked 8 spells per 2 s |
| talents | classic tabs and talents (with talent spell id and name), trait tree ids, every node's info, the active talents, unspent points, specialization | every 2 minutes and on talent, level and spellbook events; nodes 40 per 2 s |
| npcs | every npc id: creature type, max health, level range, how often seen, the spells it cast, and the NAMES you cast at it | the unit sweep; `UNIT_SPELLCAST_SENT`'s target name with your target |
| items | every item id in your bags, with its name | one bag every 6 s |
| maps | map id and name | every 10 s |
| quests | each quest id: accepted, turned in (xp, money), what `is_on_quest` and `is_quest_flagged_completed` answer | `QUEST_ACCEPTED`, `QUEST_TURNED_IN`, `QUEST_REMOVED`; probed every 10 s |
| objectives | quest objective progress: "Roiling Winds destroyed" 4/6 | `UI_INFO_MESSAGE` with an `ERR_QUEST_*` tag |
| gossip | the last 40 DISTINCT quest-giver windows: available and active quests, options, titles, reward money, which npc; the same window again only bumps its `seen` count (1.5.12) | `GOSSIP_SHOW`, `QUEST_DETAIL`, `QUEST_PROGRESS`, `QUEST_COMPLETE`, `QUEST_GREETING` |
| probes | the classic quest log (count, titles, objectives), the completed-quest list | every 10 s / 60 s |

**Only getters are called.** Nothing in the catalog accepts, abandons,
completes, selects, pushes or buys anything. `core.quests.get_quest_reward`
looks like a getter but takes the reward and finishes the quest, so it is never
called (`jcore_recorder_test` checks that).

The objectives and the npc names are what quest marks on the Forever ESP will be
built on. An objective names its mob ("Roiling Winds destroyed"), and the names
cast at an npc id say which mobs those are.

## Not available on Forever yet: what the recorder collects (JCore 1.5.9)

Seven features the Forever ESP could not have at first, because the read each
one stands on answers nothing there. For each, the catalog's `features` section
counts every CANDIDATE read's answers, and keeps whatever ground truth the
game hands over, so the read that works can be picked from evidence. The
report prints it all under "NOT AVAILABLE ON FOREVER YET".

As of AIO 1.52.0 five of the seven have marks:
- **Quest tags and gathering nodes** read what works.
- **Lootable corpses and tapped grey** are inferred from fights and loot
  windows, because no read told them apart. A real read would still beat
  the inference, so the recorder keeps counting the candidates. Since client
  patch 1.60.1.70205 `is_tap_denied` does answer (see the table), and AIO
  1.52.0 believes it when it says true.
- **Rare / elite** come from the client's own creature cache (JCore 1.5.15,
  `services/creatures.lua`), not from a unit read.

| Feature | Status (AIO 1.48.0) | Why it was missing | Candidate reads counted | Ground truth kept |
|---|---|---|---|---|
| Lootable corpse marks | **Inferred** (1.48.0). LOOT goes on a corpse that fought you, your pet or your group (or that you cast at), when nobody outside your group had it. A loot window opening within 6 yd clears it. A kill that dropped nothing keeps LOOT until it despawns, since no window clears it. | `has_loot` / `can_be_looted` always false; across 35 recorded loot windows every candidate read answered the same before and after | `has_loot`, `can_be_looted`, `can_be_skinned`, `has_skin`, npc flags, state flags, `is_tap_denied` on corpses within 40 yd | each loot window: the corpse within 6 yd, its reads from before, during and after, and what the window held (item ids, names, money) |
| Quest tags | **Done** (1.45.2, `esp/forever_quests.lua`), from npc flags, the gossip lists and objective messages | Questie is not on Forever | `is_quest_unit`, npc flags (also kept per npc id) | the quests, objectives and quest-giver windows above |
| Gathering-node marks | **Done** (1.48.0). Object `get_name` answers there, so the Classic ESP's name rules apply. `can_be_used` was true on every herb and vein recorded and false on scenery, so it decides what an "other object" is. | the classic ESP's node list is off there | on game objects within 60 yd: name, type, entry id, item id, `is_basic_object`, `can_be_used`, `has_loot`, flags | each successful gathering cast (herb, mining, skinning, opening, fishing): the object within 6 yd and its reads |
| Raid markers | Open | `get_target_marker_index` answers 16 | the index on every npc | every change of a unit's index. Put a marker on a mob and see what it becomes |
| Tapped-grey mobs | **Inferred** (1.48.0), and **read** since 1.52.0. A mob is tapped when it is in combat with a player, or a player's pet, outside your group, and none of the threat is yours, or when `is_tap_denied` says true. It is greyed, says "tapped", and gets no LOOT when it dies; on Forever the rotation no longer picks it (targeting.lua). The inferred tag goes when it leaves combat. | `is_tap_denied` always false until client patch 1.60.1.70205; since then true on the strangers' fights recorded and on 26 corpse reads, false on all 40 corpses we looted | `is_tap_denied`, flags | each mob seen fighting someone outside your group, once, with its reads |
| Rare / elite detection | **Done** (1.52.0) from the client's creature cache (`Cache/WDB/<locale>/creaturecache.wdb`, JCore 1.5.15). It knows only creatures an earlier session saw (the client writes it on exit); the rest are drawn as the normal mobs they look like | `get_classification` always 0 | `get_classification`, `is_boss`, and health per level by npc id | the spread of those answers across every npc |
| In-combat icon | **Done** (AIO 1.69.0) | the state-icon sheet would not read from the Forever archives | (art, not a call) | the ESP's art is the plugin'**Icons (AIO 1.69.0).** The Forever ESP no longer reads icons cut into this
machine's `scripts_data/jcore/game_icons/forever` (the offline extractor and its
manifest are gone): every icon is a cell of the art pack the plugin ships,
so players get them too. That folder is unused and can be deleted.

uild, flagged `kept_from_earlier_build`
in `scripts_data/jcore/game_icons/forever/manifest.json`.

To fill it in a session:
- loot a few corpses, including a kill that drops nothing;
- gather a herb or a vein;
- put a raid marker on a mob;
- pass mobs other players are fighting;
- go near an elite or a rare.

Units are read eight at a time in rotation, every two seconds.

## What to fix next

- [ ] `.api`: add `VERSIONS` notes for the broken calls above, document the
      `UNIT_SPELLCAST_*` `cast_bar_id` field, and stub the undocumented calls
      JCore may want (`world_to_screen`, `is_key_down`, `read_lua_*`).
- [ ] `.api`: mark `get_buff_description`, `load_image`, `draw_image` and the
      `get_*_data` object methods as absent on Forever.
- [x] Combat log on Forever: the reaction engine's damage tally runs on
      expected cast damage (tooltip estimates), and its readout says so
      (AIO 1.45.0, session 39). A real source for damage done is still open:
      the `read_lua_*` calls may reach the game's own state.
- [x] Energy on Forever: counted rather than read. `modules/forever_power.lua`
      models energy, rage and combo points from costs, regeneration, usability
      and the "Not enough X" errors (AIO 1.45.0). JCore 1.5.7 reads the GCD off a
      probe spell's cooldown.
- [x] Rewrite the ESP for Forever: AIO 1.42.0, `modules/esp/forever.lua`.
      Names are learned from `UNIT_SPELLCAST_SENT` while `get_name` is blank.
      Icons from the client's own archives, extracted offline (AIO 1.45.0).
- [x] Quest marks on the Forever ESP (AIO 1.45.2, `esp/forever_quests.lua`):
      PICK UP / TURN IN / QUEST on givers from npc flags and the gossip lists,
      KILL n/m from objective messages and learned names, USE on "(Quest)"
      objects. Non-progress quest messages are kept apart (JCore 1.5.11).
- [x] Gathering-node marks on the Forever ESP (AIO 1.48.0, session 57): object
      `get_name` with the Classic name rules, `can_be_used` for other objects.
- [x] Lootable corpses and tapped grey on the Forever ESP (AIO 1.48.0, session
      57): inferred from who fought the mob and from loot windows, because no
      read tells them apart.
- [ ] A real lootable read would still beat the inference, which cannot clear
      LOOT on a kill that dropped nothing. The same goes for a real tapped
      read. Keep the candidates counted.
- [~] A better name source for Forever: probe the undocumented `read_lua_*` /
      `execute` calls. JCore 1.5.16's `services/gamelua` probes them on Forever
      and writes what it found to `jcore.gamelua.json`; AIO 1.53.0 reads the
      quest log, quest areas and unit names through it. Waiting on the first
      Forever session to say whether they reach the game.
- [ ] Icons after client patch 1.60.1.70205: `Spell_Shadow_SummonFelHunter` and
      `Spell_Shadow_PlagueCloud` read "no BLTE header", so they are kept from
      the earlier build (`kept_from_earlier_build` in the manifest). Find out
      why the new build's entries will not read.
- [x] Rare / elite on Forever (AIO 1.52.0, JCore 1.5.15): the classification
      byte of the client's creature cache. No elite was in the cache yet when
      it was written (16 creatures of Coldridge Valley), so the byte's place
      is known from the layout, not from an elite: check the first elite's
      `fesp ... rank=1` line and the `creatures:` load line.
- [ ] The creature cache only fills when the client exits. Names and ranks
      for creatures first seen this session still come from casts only.
- [ ] Hunter Auto Shot on Forever: the per-mob trace line now says where the
      time went and what the client refused (AIO 1.52.0). Session 26 had
      "3 presses, 0 shots in 17.4s" at 9.5 to 11 yards with no reason.
- [ ] Play a warrior or a druid, and a warlock or a hunter with a pet: the
      rotation's Forever fallbacks (AIO 1.50.1, JCore 1.5.14) stand on reads
      never seen there. Check what `get_shapeshift_form`, `get_all_minions` and
      `game_object:get_owner` answer, and whether a form shows as an aura.
- [ ] Record a longer session that covers the suspicious calls: a caster mob,
      an elite, a raid marker, damaged gear, a level-10+ character with
      talents, a mailbox and a vendor.

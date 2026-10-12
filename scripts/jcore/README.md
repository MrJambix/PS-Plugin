# JCore

A shared runtime for plugins on this scripting platform. Plugins register with
it and receive a context handle; the core owns the native callbacks, the object
manager sweep, cast arbitration and the render order, so plugins stop competing
over them.

**Requires:** `core` API 2.058 or later (the declarative `_G.menu` host, and
`core.register_on_game_event_callback`).

**Version numbers:** 1.8.1 (2026-10-11) paints the screen UI over the game's
own frames (see *Drawing*), and runs nothing until a character is in the
world (2026-10-12, see *Connecting*). 1.8.0 (2026-10-11) adds the reaction framework,
`ctx.react` (see *Reactions*). 1.7.9 is the build that was numbered 1.13.1 here. JCore was
renumbered on 2026-10-09 to continue the line on project-sylvanas.net (plugin 1128,
which showed 1.7.8). Version tags in brackets elsewhere in this README and in the code,
from 1.5.15 to 1.13.1, are the old local numbers and predate 1.7.9.

---

## Why a core

Four problems appear as soon as a second plugin is loaded. None of them is a
bug in either plugin.

| Problem | Without a core | With JCore |
|---|---|---|
| Object manager sweeps | Every plugin calls `get_visible_objects()` and walks it. Three plugins = three full sweeps of native calls per frame. | One sweep per tick, classified once, read by everyone. |
| Cast collisions | Two plugins queue in the same GCD. Both send. The second lands a beat late. | One intent per GCD, highest priority wins, losers are dropped. |
| Draw order | Native render callbacks fire in load order. Whoever loaded last paints on top. | Every primitive carries a layer; the core paints in layer order. |
| Blame | A frame-time regression means unloading plugins one at a time to bisect. | Every job is timed and attributed on the Core diagnostics page. |
| Repeated reads | A priority list asks the player's health nine times while walking it. Nine native round trips. | Every reader is memoised for the tick. Nine table lookups. |
| Movement | A follow plugin holds forward, an evade plugin strafes left, the character walks into a wall. | Movement is a leased channel with priorities, like the GCD. |
| Coverage | Anything the core does not wrap, a plugin calls raw — unguarded, uncached, and fatal when the build lacks it. | Every remaining `core.*` namespace is mirrored, guarded and memoised. |
| Windows | Every HUD hand-rolls its own drag code, colours and hit-testing on raw rects, and whichever painted last takes the click. | One window toolkit: shared theme, z-order, persistence, input capture, and the same widgets for every plugin's code. |
| Art | Icons come from wherever each plugin found them; addon art in BLP cannot be loaded at all. | One reference string for any source, decoded and cached once, with the addons' own icons imported into a catalog. |

---

## Connecting

Package load order is not guaranteed, so do not assume `_G.JCore` exists when
your file runs. Copy this block:

```lua
local MINIMUM_CORE = "1.0.0"

local function start(JCore)
    if not JCore.require_version(MINIMUM_CORE) then
        core.log_error("[MyPlugin] needs JCore " .. MINIMUM_CORE .. " or newer")
        return
    end
    -- everything else goes here
end

-- Not before a character is in the world (JCore 1.8.1); an older core has
-- no in_world and starts you at once.
local function in_world(J)
    return type(J.in_world) ~= "function" or J.in_world()
end

if _G.JCore and in_world(_G.JCore) then
    start(_G.JCore)
else
    local deadline, started = core.time() + 15.0, false
    core.register_on_update_callback(function()
        if started then return end
        local J = _G.JCore
        if J then
            if in_world(J) then
                started = true
                start(J)
            end
        elseif core.time() > deadline then
            started = true
            core.log_error("[MyPlugin] JCore never loaded; plugin inactive")
        end
    end)
end
```

A package that sits inside the JCore tree can use `require("jcore/main")`
instead. The global is the portable door; both return the same table.

**The world gate (1.8.1).** The loader can start the plugins at the
character select screen. The game has not loaded its world tables there,
and a native that reads one (a spell, item, map or zone name) kills the
client with `ASSERT(IsLoaded())` in `WowClientDB2.cpp`, which no `pcall`
survives. This happened on 2026-10-12, 0.2 s after a load at that screen.
So JCore runs no pass and forwards no game event until a local player is
valid. Only its update callback asks, once a frame. Once open, the gate
stays open: a loading screen or a logout later runs as it always has.

`JCore.in_world()` answers it, and `jcore.world.waiting` and
`jcore.world.open` mark it. Start your plugin behind it, as above, and do
no game reads at file load. The offline harness has no player, so
`mock.install()` sets `JCORE_NO_WORLD_GATE`; `jcore_world_gate_test` sets
it back.

`examples/jcore_example_plugin/` is a complete working consumer.

---

## Registering

```lua
local ctx = JCore.register({
    id      = "yourname.plugin",   -- reverse-DNS, STABLE FOREVER
    name    = "Your Plugin",       -- display name
    version = "1.0.0",
    kind    = "rotation",          -- rotation | plugin | library | esp

    requires  = { "yourname.other" },  -- held back until those are running
    on_load   = function(ctx) end,
    on_unload = function(ctx) end,
    on_enable = function(ctx) end,
    on_disable = function(ctx) end,
})
```

`id` is the owner tag on every hook you create through `ctx`. That tag is what
lets the core pause you, unload you cleanly and bill you for frame time, so
treat it as permanent — changing it later orphans everything keyed to it.

`requires` holds `on_load` until those ids are **running**. A dependency that
never arrives leaves you in `waiting` (visible on the diagnostics page) rather
than half-starting. For an optional integration use `ctx.depends_on_running(id)`
instead.

---

## The context handle

### Scheduling

```lua
ctx.tick(fn, opts)          -- update phase; decisions go here
ctx.render(fn, opts)        -- render phase; SUBMIT draws, do not paint
ctx.pre_tick(fn, opts)      -- before update (reads LAST frame's unit sweep)
ctx.render_menu(fn, opts)
ctx.render_control_panel(fn, opts)

ctx.after(0.5, fn)          -- one-shot timer, returns id
ctx.every(2.0, fn)          -- repeating timer, returns id
ctx.cancel(timer_id)
ctx.remove_job(job)

ctx.request_unit_range(150) -- widen the shared unit cache while loaded
```

`ctx.request_unit_range` is how a plugin that draws or scans further than the
default asks the shared sweep to reach that far. Requests are **additive**: the
cache uses the largest of the user's Core setting and every plugin's request,
capped at 250 yards, and your request is released automatically on unregister.
Never write `JCore.units.set_max_range` from a plugin — that is the user's
setting, and overwriting it both undoes their choice and fights any other
plugin doing the same.

`opts` is `{ priority, interval, deferrable }`. Lower priority runs earlier;
default 100. `interval` throttles in seconds (`0.25` = 4 Hz). `deferrable`
lets the core skip the job on a frame that has already blown its budget — set
it on anything cosmetic, never on safety logic.

### Events

```lua
ctx.on(event, fn, { priority = 100, once = false })  -- returns a handle
ctx.once(event, fn)
ctx.off(handle)
ctx.emit("yourname.plugin.something", payload)
```

Handlers are `pcall`ed; one that raises five times in a row is quarantined
rather than left to poison every frame. All of your subscriptions are dropped
automatically when you unregister.

Core events:

| Event | Payload |
|---|---|
| `jcore.ready` | the public table |
| `jcore.world.waiting` | — loaded at the character select screen: no pass runs yet (1.8.1) |
| `jcore.world.open` | — a character is in the world; the passes start (once, 1.8.1) |
| `jcore.combat.enter` | — |
| `jcore.combat.leave` | duration in seconds |
| `jcore.target.changed` | new target, previous guid |
| `jcore.player.died` / `jcore.player.revived` | — |
| `jcore.zone.changed` | new map id, previous map id |
| `jcore.unit.added` / `jcore.unit.removed` | guid, object |
| `jcore.spell.cast` | `OnProcessSpellCastData` |
| `jcore.enemy.engaged` | the enemy row -- it turned on you or your pet |
| `jcore.enemy.approaching` | the enemy row -- a hostile not yet engaged is closing on you |
| `jcore.enemy.casting` | the enemy row, the cast -- a cast or channel started |
| `jcore.enemy.fleeing` | the enemy row -- an engaged enemy started running |
| `jcore.enemy.controlled` | the enemy row -- it is stunned, feared, rooted |
| `jcore.enemy.died` | guid, the enemy row |
| `jcore.threat.gained` / `jcore.threat.lost` | the threat board -- you became, or stopped being, the mob's top threat |
| `jcore.game_event` | event name, args array |
| `jcore.game_event.<NAME>` | args array |
| `jcore.cast.sent` | the winning request |
| `jcore.plugin.started` / `.failed` / `.registered` / `.unregistered` | id |

> `args` on a game event follows the native contract: a nil argument leaves a
> **hole** in the array, so index positionally and never use `ipairs` or `#`
> on it.

### Logging

```lua
ctx.log.info("ready")
ctx.log.fmt("warn", "%s at %.0f yards", name, distance)
ctx.log.once("error", "key", "said once per session")
ctx.log.raw("info", line)            -- bypasses the rate limiter
ctx.log.rawf("info", fmt, ...)
```

Every call site gets its own token bucket — four lines per second, then a
suppression count — so a line in a hot path degrades instead of flooding the
console. `fmt` keys the bucket on the **format string**, so a message whose
numbers change every frame still collapses correctly.

`raw`/`rawf` skip the limiter. Use them only for bulk output a human asked for,
such as a diagnostic dump that prints one line per nearby object: that is one
call site deliberately emitting many distinct lines, and the limiter would
swallow it after the fourth. Never call them from a tick.

### Units

```lua
ctx.units.player()                        -- nil during a loading screen
ctx.units.enemies() / .allies() / .players() / .objects() / .all()
ctx.units.enemies_within(range, origin?)
ctx.units.count_enemies_within(range)     -- no allocation; use in hot paths
ctx.units.nearest_enemy(range?)
ctx.units.lowest_health_ally(range?)
ctx.units.cluster_size(unit, radius)      -- "where do I drop the AoE"
ctx.units.best(list, score_fn)            -- nil score excludes the unit

ctx.units.lowest_health_enemy(range?) / .biggest_enemy(range?)
ctx.units.best_cluster(radius, range?)    -- unit, position, count
ctx.units.enemies_in_cone(range, half_angle_degrees)
ctx.units.enemies_in_line(range, width)
ctx.units.enemies_by_distance()           -- sorted once per tick, shared
ctx.units.count_allies_within(range, origin?)
ctx.units.for_each_enemy_within(range, fn, origin?)   -- no allocation at all

ctx.units.distance(unit)                  -- free if the unit was in this sweep
ctx.units.distance_between(a, b)
ctx.units.melee_distance(unit)            -- hitbox to hitbox, not centre to centre
ctx.units.position(unit) / .guid(unit) / .name(unit)
ctx.units.health(unit) / .max_health(unit) / .health_deficit(unit)
ctx.units.health_fraction(unit)           -- 0..1, 0 for dead
ctx.units.is_facing(unit, target, half_angle_degrees)
ctx.units.snapshot(unit)                  -- this sweep's row: x, y, z, dist
ctx.units.by_guid(guid)

ctx.units.has_aura(unit, spell_id_or_list)
ctx.units.aura_remaining(unit, id)        -- seconds; math.huge if permanent
ctx.units.aura_stacks(unit, id)
ctx.units.aura_index(unit)                -- spell_id -> buff, built once
```

The sweep **records** as well as classifies. Every object that survives the
range cut gets a snapshot row holding its guid, its position as three raw
numbers and its distance from the player — all things the sweep had to ask for
anyway. Health, name and combat reach are filled in lazily by the first caller
that wants them.

So none of the queries above calls back into the game. `count_enemies_within(8)`
is a loop over a float array; four calls to it while walking a priority list
cost four loops rather than 4×N native position reads. Take positions from
`ctx.units.position()` rather than `unit:get_position()` for the same reason.

The pickers — `nearest_enemy`, `nearest_ally`, `lowest_health_ally`,
`lowest_health_enemy` — return exactly **one** value on purpose. They get
written straight into calls like `ctx.cast_spell(id, ctx.units.nearest_enemy())`,
and a second return value would splice itself into that argument list as the
priority. Ask `ctx.units.distance(unit)` afterwards; it is free.

**Staleness contract.** The returned arrays are rebuilt in place every tick.
Read them inside your tick; never hold one across frames. To carry a unit
across a frame boundary, store `unit:get_guid()` and re-resolve with
`ctx.units.by_guid()` — `game_object` userdata is only trustworthy for the tick
that produced it.

### Spells

Read-only. Nothing here has a side effect, so a priority list can be evaluated
end to end safely.

```lua
ctx.spells.ready(id)             -- known + off cooldown (or has a charge) + usable
ctx.spells.castable(id, target, opts)   -- ready + range + facing + line of sight
ctx.spells.cooldown(id)          -- seconds remaining
ctx.spells.gcd()
ctx.spells.charges(id)           -- current, max
ctx.spells.in_range(id, target)
ctx.spells.info(id)              -- name, ranges, cast_time (seconds), school
```

### Casting

You do not cast. You **request**, every tick you want it. One request wins per
GCD across all plugins; losing is normal and needs no handling. Nothing is
remembered between ticks, so stop asking and you stop being represented.

```lua
ctx.cast({
    spell_id = 1234,
    target   = someUnit,      -- or position = vec3 for ground-targeted
    priority = ctx.PRIORITY.ROTATION,
    reason   = "filler",      -- shows up in the cast log; worth filling in
    fast     = false,         -- true = off-GCD, arbitrated in its own lane
})

ctx.cast_spell(id, target, priority, reason)   -- shorthand

ctx.suppress_casting(1.5, "mid-sequence")      -- hold the gate
ctx.release_casting()
```

Priority bands — pick one and vary within it rather than inventing a number
that outranks everything:

| Band | Value | For |
|---|---|---|
| `IDLE` | 10 | out-of-combat upkeep |
| `FILLER` | 30 | bottom of a rotation |
| `ROTATION` | 50 | normal rotational abilities |
| `COOLDOWN` | 70 | burst windows, on-use trinkets |
| `UTILITY` | 100 | dispels, taunts, purges |
| `INTERRUPT` | 150 | kicks |
| `DEFENSIVE` | 200 | damage reduction, self-heals |
| `EMERGENCY` | 255 | last-stand buttons |

Two rules worth knowing: the **fast lane is separate**, so an off-GCD ability
lands in the same tick as the GCD ability it buffs; and **`EMERGENCY` punches
through suppression**, so a plugin holding the gate can never stop someone
else's defensive from firing.

### Combat

```lua
ctx.combat.in_combat()
ctx.combat.duration()              -- seconds since the pull
ctx.combat.time_since_combat()
ctx.combat.target()
ctx.combat.is_busy()               -- casting or channelling
ctx.combat.cast_remaining()        -- seconds left on the current cast
ctx.combat.time_to_die(unit)       -- math.huge when unknown
ctx.combat.lives_longer_than(unit, seconds)
```

`time_to_die` returns `math.huge` both when there is not enough history yet and
when the unit is not losing health. Treating a huge number as "it will be alive
a while" is correct in both cases, so no special check is needed.

Health is sampled **four times a second** (1.5.3), not every frame, over a
ten-second window, so the first estimate needs about three-quarters of a
second of history. Only the first and last samples enter the estimate; a
sample a frame kept six hundred tables per enemy and shifted the whole list
every frame to drop the oldest.

### Enemies

Every hostile in range, read once per tick, **with a memory**. The unit cache
answers "what is there" for one tick and forgets; almost every question about
an enemy is about change -- is it coming, is it running, did it just start
casting, did it just switch to my pet, how long until it reaches me -- and none
of that is readable from one frame. This service keeps one history per hostile
and answers from it, so no plugin keeps its own.

```lua
ctx.enemies.all()                  -- every row this tick, nearest first
ctx.enemies.count()
ctx.enemies.get(unit_or_guid)      -- the row, or nil
ctx.enemies.engaged()              -- targeting you or your pet, or holding threat
ctx.enemies.inbound()              -- closing on you, not engaged yet
ctx.enemies.casting()
ctx.enemies.next_cast(interruptible_only)  -- row, cast -- the one finishing soonest
ctx.enemies.targeting_me()
ctx.enemies.fleeing()
ctx.enemies.nearest(predicate)
ctx.enemies.first_arrival()        -- row, seconds -- who reaches melee first
ctx.enemies.time_to_reach(unit)    -- math.huge when it is not closing
ctx.enemies.count_by_activity()
ctx.enemies.situation(mob, holder, targeted)  -- the threat entry, asked the way round the client answers
ctx.enemies.threat_order()         -- "holder", "mob", or nil while both ways are asked
ctx.enemies.threat_readable()      -- true once threat has said something; false once Forever's zeros are proven; nil otherwise
ctx.enemies.damage_rate(guid)      -- Forever: damage per second it does to you or the pet, from your health; nil where the combat log speaks
ctx.enemies.meter_summary()        -- Forever: what Blizzard's damage meter answered, in one line; nil elsewhere
ctx.enemies.where(predicate)       -- allocates; prefer the specific queries in a hot path
```

A row:

| Field | Meaning |
|---|---|
| `obj`, `guid`, `dist`, `x`, `y`, `z` | this tick's identity and position, from the sweep |
| `speed`, `moving` | yards per second over the last second or so |
| `closing` | yards per second **towards you**; negative is away. Measured against you, so a mob standing still while you run at it reads as closing -- what matters is when you meet |
| `time_to_reach` | seconds until melee reach at the current closing speed, `math.huge` when not closing |
| `hp`, `ttd`, `in_combat` | health fraction, time to die, the unit's own combat flag |
| `casting` | `{ spell_id, channel, remaining, interruptible, start_at, end_at }` or nil |
| `target_guid`, `targeting_me`, `targeting_pet` | whom it is on |
| `engaged` | targeting you or your pet, or in combat with threat on you |
| `threat` | `{ tanking, status, percent }` from the client's threat table, refreshed twice a second |
| `control` | `{ spell_id, type, remaining }` while stunned, feared, rooted; nil otherwise. Read off the mob's debuffs on Forever, with `kind` (incapacitate, fear, stun, root), `name` and `breaks` (damage ends it) |
| `activity`, `activity_since` | one word for what it is doing, and since when |

`activity` is one of `idle`, `patrolling`, `approaching`, `attacking`,
`casting`, `fleeing`, `controlled`, `dead`, in that order of precedence. The
`jcore.enemy.*` events fire on the transitions -- once per change, never once
per frame.

**Cost.** Position and distance are free every tick. The detailed state --
cast, target, threat, control, health -- is read on a budget: the nearest
twelve enemies within sixty yards get a fresh read every tick and the rest hold
their last one, refreshed at least every second and a half. `set_detail_budget`
and `set_detail_range` move those. A row handed out or carried on an event is
**live**: the same table the next tick rewrites. Read it, do not keep it.

**What Forever's client does not say (1.6.4).** Three answers come from what
it does say instead, decided once from `world.client()`; on every other
client the service reads exactly what it always read (`jcore_enemies_forever_test`
holds both halves):

- **Damage on you.** The combat log arrives with no arguments there. Each drop
  in your own health between polls is shared among the rows targeting you, and
  the pet's among the rows targeting it -- by what each has done so far, a
  newcomer as much as the average of the others. `damage_rate(guid)` is that
  mob's total over the time since its first hit plus a swing, forgotten after
  six seconds without one. A heal is not damage.
- **Crowd control.** Loss of control reads "not valid" for every mob there (on
  the retail engine it is the player's own). For a mob in combat the row's
  `control` comes from its debuffs by name instead -- Polymorph, Freezing
  Trap, Sap, Fear, Scare Beast, Hammer of Justice, Frost Nova and the rest --
  with `breaks` saying whether damage ends it, so a plugin knows a sheep from
  a stun.
- **Threat.** `get_threat_situation` has only ever answered zeros there. A read
  of a mob that is hitting its holder and says the holder has nothing on it is
  a vote; six with no read ever saying more and threat is **unread**:
  `situation` answers nil (so the row's `threat` is nil), costs nothing, and
  is not asked again, and the trace says so once. One answer that says
  anything makes it live for the session.
- **The damage meter (1.6.6).** The combat log there is Blizzard's 12.0 locked
  kind: the event fires and its contents are secret to addon code. What
  Blizzard offers instead is its own damage meter, which the loader wraps as
  `core.damage_meter`. It is asked once a session (`is_available`) and then,
  in combat, every two seconds for the current session's types 7, 9 and 10
  (damage taken, and whichever of deaths and enemy damage taken this client
  numbers so); each change of answer goes to the trace, and
  `ctx.enemies.meter_summary()` says it in one line ("damage meter answers in
  combat", "nothing usable in combat", "unavailable (why)"). It has totals
  only, never who hit whom, so it does not replace `damage_rate`.

### Threat

The whole group's threat on every mob it is fighting, **ranked** -- what
Details!' Tiny Threat plugin shows for your target, for every mob at once. The
enemies row already carries *your* threat; what it cannot say is where that
puts you, because that needs everyone else's. This service asks the client's
threat table once per group member per mob (`mob:get_threat_situation(member)`,
the call behind Tiny Threat's `UnitDetailedThreatSituation`) and sorts the
answers.

```lua
ctx.threat.get(unit_or_guid)       -- the board, or nil when the group is not fighting it
ctx.threat.mine(unit_or_guid)      -- percent, rank, count, tanking -- your standing
ctx.threat.boards()                -- this tick's boards: the target, then nearest
ctx.threat.count()
ctx.threat.roster()                -- everyone who can hold threat, you first
ctx.threat.closest_to_pulling()    -- board, percent -- where you are nearest to pulling
ctx.threat.holding()               -- how many of the group's mobs you hold
ctx.threat.set_enabled(on)
```

A board:

| Field | Meaning |
|---|---|
| `guid`, `obj`, `at`, `is_target` | the mob, when it was last read, whether it is your target |
| `entries[1..n]` | everyone with any threat on it, ranked: `{ guid, name, obj, percent, rank, status, tanking, is_me, is_pet, mine, role, class }` |
| `count` | how many are ranked: `n`, plus one when `outside_tank` |
| `tank` | the entry holding it, or nil when nobody in the group does |
| `outside_tank` | the mob is on somebody outside the group, who therefore holds rank 1 |
| `me`, `my_rank`, `my_percent` | your entry and standing, nil while you have no threat on it |
| `pet` | your pet's entry |
| `next_percent` | the highest percent of anyone **not** holding it -- how close the tank is to losing it |

`percent` is the client's **scaled** percent, Tiny Threat's default: 100 is the
point at which that member becomes the mob's target, with the 110% melee / 130%
ranged rule already folded in. The holder reads 100; a mage at 90 is ten points
from pulling. Ranks go by it, so #2 is "next to pull". Who holds it is
`status >= 2`, not `is_tanking`; when nobody reports holding it, the member the
mob is targeting does. Before the 2026-10-06 core both were wrong on every
classic build (`status` always 0, `is_tanking` a hardcoded offset) and only
`percent` was right, so that fallback did the work there; that core fixed both,
and the board simply has the client's word from then on.

**Who is asked.** You, your pet, every party member the client holds an object
for and their pets, and in a raid every `raidN` token that resolves (no raid
pets, as in Tiny Threat). Rebuilt every two seconds and on a roster event; the
raid tokens are probed eight a tick, never forty in one frame.

**Which mobs.** Enemies rows in combat and fighting the group -- on one of
the roster, or holding some of your threat -- within sixty yards; the target
first, at most ten. A mob that stops qualifying loses its board on the same
tick.

**Cost.** One native per roster member per mob per read: the target twice a
second, the rest once, at most 24 natives a tick (one whole board is always
read, so a raid does not starve). Your own answer comes from the enemies row
when it is fresh, so a solo fight costs nothing. Boards are **live**, like
enemy rows: read them, do not keep them.

**Which way round.** The contract calls `get_threat_situation` "the threat
situation from the game_object to another", which reads as
`holder:get_threat_situation(mob)`; every caller here was first written
`mob:get_threat_situation(holder)`, and the in-game ESP showed no threat row in
a party fight. A wrong way round answers zeros, which look exactly like "no
threat yet". So every read goes through `ctx.enemies.situation`, which asks both
ways and uses the answer that says more until the client settles it: a read
where the mob is targeting the holder must say that holder holds it, and three
such reads agreeing (none against) fix the order for the session, one native per
read from then. The Debug page's **Threat** line shows the order and how often
the client answered at all.

**When the client says nothing** about anyone on a mob that is plainly on one of
us, whoever it is targeting holds it (`inferred = true` on the entry), so the
board is never empty mid-fight. Still unverified: that `threat_percent` is the
scaled figure (Tiny Threat's default) rather than the raw one; if it is raw, ranks
order the same except across the 110% / 130% thresholds.

### Reactions (1.8.0)

"Several things are happening; which matters most?" A priority list answers
"what is the best press right now"; it was never the right tool for an
interrupt, a defensive, a potion, a pet heal and a hardcore bail-out all
valid in the same frame. The reaction framework answers that: every rule
proposes, everything is scored, one per lane is validated and sent, and
what was just done is remembered so nothing is done twice for one event.
Until 1.8.0 it was Jambix AIO's `modules/react` engine; it is the core's now,
so any plugin can register reactions, and the AIO's are one consumer.

```lua
local R = ctx.react                  -- this plugin's engine, built on first access

R.configure({                        -- what the engine needs to know about your world
    spells = { known = f, ready = f, id = f },   -- your spellbook, by name (ids by default)
    target_kind = f,                 -- "self" | "pet" | "ally" | "enemy" | nil, from a catalogue
    key_allows = f, channel_active = f, press_blocked = f,   -- gates a press passes
    kinds = { potion = { validate = f, execute = f, target_kind = "self", answer = "done" } },
    band = f, filter = f, explain = f, trace = f, log = t, on_refused = f, units = t,
})

R.add_rule({                         -- a reaction is DATA; the engine does the rest
    name = "Interrupt", category = "interrupt", priority = 90, lane = "gcd",
    needs = { "combat", "target" }, every = 0.2, wake = { "jcore.enemy.casting" },
    retry = { hold = 2 }, owns = { "Counter Shot" },
    condition = function(W) return W.target.casting end,
    action = "Counter Shot", target = "enemy",
    score = function(W, c) c:add(25, "cast ends soon") end,
    validate = function(W, c) return nil end,
})
R.remove_rule(name) / R.set_enabled(name, on) / R.rule(name) / R.rules()
R.filter = function(def, W) ... end  -- the player's switches: false keeps a rule out

local d = R.decide(W)                -- { cands, gcd, fast, pet, deferred, holds, rejected }
for _, lane in ipairs({ "fast", "gcd", "pet" }) do
    if d[lane] then R.execute(d[lane], W) end
end
R.owns(spell, W) / R.yielding(W) / R.wake(def) / R.unique(name)
R.memory                             -- what was asked for, sent, confirmed, refused, handled
R.latch.new / R.latch.debounce       -- a threshold with two lines; a boolean that must settle
R.journal(kind, text, key) / R.journal_due(key) / R.log_lines(n) / R.reset() / R.stats()
```

**The pipeline, one tick.** `decide(W)`: every enabled rule that is due looks
at `W` and offers zero or more candidates, each with the event it answers
(`event_key`). Each is scored -- its base priority, the rule's own `score`,
what the mode (`W.mode`: NORMAL, RECOVERY, DEFENSIVE, EMERGENCY, ESCAPE) and
the context (`W.context`: BOSS, AOE, PVP) add or take away, and a mark-down
for a name the client refused lately; every point carries its reason. Then
one winner per lane (`gcd`, `fast`, `pet`): highest score first, the first
that passes validation. A `hold` is not an action and takes no lane: it is
listed in `holds` for a rotation to stop on. A candidate that scores under
`ROTATION_SCORE` (40) is never pressed over a rotation; the first such for
the global cooldown comes back as `deferred`, for a tick on which the
rotation had nothing to press. `execute(c, W)` sends it: a spell through
`ctx.cast` in the band its category earns (survival, bail-out, escape and
defensive in EMERGENCY; interrupt in INTERRUPT; crowd control in DEFENSIVE;
the pet, threat, utility and resource in UTILITY; a buff just over
ROTATION), anything else through the `execute` of its kind.

**Validation** refuses, in this order: an offensive rule while `W.hold_fire`
or during a bail-out (`W.bailout` without `W.fight_on`); an event already
handled; a name inside its `retry.hold`; a name backed off after refusals;
the wrong kind of target (an enemy spell with no enemy target would
self-cast; a self spell aimed elsewhere; a dead or friendly "enemy"); for a
spell: not known, the catalogue's word (`target_kind`), its key, not ready,
its channel running, `press_blocked`, a cast of ours still starting
(`W.pending`), a reaction of ours in progress that scored higher (unless
`W.yield` says it gives way); for any other kind, its own `validate`; then
the rule's own `validate`.

**The memory** is fed by the game on its own, through this handle:
`jcore.cast.sent` for this owner, `UNIT_SPELLCAST_SUCCEEDED` / `FAILED` /
`INTERRUPTED`, `UI_ERROR_MESSAGE`, the channel events, and
`jcore.combat.leave`. An attempt is `requested`, then `sent`, then `ok`,
`failed`, `lost` (never sent: it lost arbitration) or `unknown` (silence,
which only counts against a reaction, and only for a name the client has
confirmed before). Two refusals of a name inside six seconds back it off for
1.5 s, doubling to 4 s; a success clears it. Only a refusal that will repeat
counts (`persistent_error`: out of range, facing, line of sight, too close,
a bad target, immune); "not ready yet" is recorded and never counted. A
rotation's own presses arrive through `jcore.cast.sent` too, so the memory
knows every press, not only the reactions. `handle(key, ttl)` marks an event
answered; a refused answer releases it. `attacked(guid, window)`,
`sent_recently(window)`, `since(name)`, `waiting(name)`, `failures(name)`,
`in_progress(spell_id)`, `applied(name)` (a one-per-caster debuff declared
with `unique`), the target trail (`target_seen`, `flaps`, `stable_for`), the
health trail (`sample_hp`, `damage_taken`) and named states (`set_state`,
`state`) are the questions it answers.

**The picture (`W`) is yours.** The engine reads a few fields and hands the
rest to the rules untouched: `now`, `mode`, `context`, `player.{unit,
in_combat, busy, casting_id}`, `pet.{unit, alive}`, `target.{unit, casting}`,
`group.in_group`, `enemies.casting_n`, `bailout`, `fight_on`, `hold_fire`,
`pending`, `yield`, `s`. Any may be absent. `needs` gates read them:
`combat`, `pet`, `target`, `group`, `casting`.

**Your own kinds.** Beyond `spell` and `hold`, `configure({ kinds = ... })`
declares what else a candidate may be -- an order to the pet, a bag item, a
target switch -- each with `validate(c, W)` (why not, or nil), `execute(c, W)`
(sent, and the spell id to track), and optionally `target_kind`, `lane`
(`pet` for anything with its own global cooldown), `answer` (how the client
answers it: `arbiter`, the default; `sent`, the client still confirms it;
`done`, asking is doing) and `spell_named` (the name is a spell to know).

**Owner tagging.** The engine casts, subscribes and logs as the plugin that
holds it; its rules go on `unregister`, and `JCore.react.stats()` and the
Core page's cost readout count engines, rules, decisions and what went out.
`JCore.react.new(owner, ctx)` builds one by hand (the tests do); `latch` and
`new_memory` are reachable on it without an engine.

### Player

Everything about the local player, resolved at most once per tick. Nothing here
has a side effect, so a priority list can read it freely.

```lua
ctx.player.exists()                -- false through a loading screen
ctx.player.health_pct() / .health() / .max_health() / .health_deficit()
ctx.player.shield() / .incoming_heals() / .heal_absorb()
ctx.player.effective_health()      -- health + shield

ctx.player.power(type?) / .max_power(type?) / .power_pct(type?)
ctx.player.power_deficit(type?)    -- what a builder would waste by overcapping
ctx.player.combo_points()
ctx.player.runes_ready()           -- death knight

ctx.player.is_busy()               -- casting or channelling
ctx.player.casting_spell_id() / .cast_remaining() / .cast_target()
ctx.player.gcd() / .haste()
ctx.player.empower_stage()         -- evoker

ctx.player.is_moving() / .is_mounted() / .is_flying() / .in_combat()
ctx.player.is_swimming() / .is_resting() / .is_indoors()
ctx.player.form()                  -- shapeshift / stance id, 0 for none
ctx.player.loss_of_control()       -- nil when free

ctx.player.target() / .focus() / .pet() / .mouseover()
ctx.player.has_buff(id_or_list) / .buff_remaining(id) / .buff_stacks(id)
ctx.player.equipped_items() / .item_at_slot(slot) / .gold()
ctx.player.talents() / .professions()
ctx.player.skill("skinning")      -- level, how ("profession" | "skill" | "rank"), max (1.8.5)
ctx.player.can_skin(level)         -- ok, required, skill, how; skin_required(level) (1.8.5)

ctx.POWER.MANA / .RAGE / .ENERGY / .COMBOPOINTS / ...
```

**The pet on Forever (1.5.14).** `get_pet` answered nil on all 746,898 calls
the API recorder caught on Forever, a hunter's included. So `units.player_pet()`
is now where `ctx.player.pet()` and the enemy rows' "on your pet" get the pet.
On every other client it asks `get_pet` exactly as before. On Forever, when
`get_pet` has nothing, it looks for the pet:
1. first in the player's minion list (`get_all_minions`);
2. then among the swept units, for one that says it is a pet (`is_pet`) and
   names the player as its owner (`get_owner`).

A pet once found is kept while it lives. A search that finds nothing waits
2 s, so a class with no pet pays a few calls every two seconds.
`get_all_minions` and `get_owner` had never been called on Forever when this
was written. The recorder will show what they answer, and until then this is
unverified (`aio_forever_class_hunter_test`, `aio_forever_class_warlock_test`).

`spec_id()` is tick-scoped, not session-scoped: swapping spec mid-session is
ordinary, and a rotation that cached it at login would keep running the wrong
priority list. Class and race are held for the session and dropped on the
events that can change them.

### Creatures (Forever, 1.5.15)

```lua
ctx.creatures.info(npc_id)        -- { id, name, title, type, family, classification, quest_items, leader, checked } or nil
ctx.creatures.name(npc_id)        -- the server's name for it, or nil
ctx.creatures.classification(npc_id)  -- 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare, 5 trivial, 6 minus; nil = unknown
ctx.creatures.classification_of(unit) -- the client's answer, else (Forever, when it says 0) the cache's
ctx.creatures.stats()             -- path, build, locale, count, ranked, unchecked, error, tried
ctx.creatures.load(true)          -- read the file again
ctx.creatures.beast(npc_id)       -- { tameable, family, type, name, classification } or nil, on Era too (1.8.6)
```

**The beast lookup (1.8.6).** `beast` answers whether the client says a creature
can be tamed (type flags bit 0, CREATURE_TYPE_FLAG_TAMEABLE) and its family. It
works on Era as on Forever: on Era the file is read the first time `beast` is
asked and never before, and `info`, `name` and `classification` still answer
nil, so no Era name or rank changes. Era's build 70003 writes one more header
bit after the cursor length and one more u32 before the display count. The
parser picks the layout per file, by which one more of its first 24 records
hold to. The user's Era cache (977 records, all holding) is the fixture
`tools/jtest/mock/fixtures/era_creaturecache_70003.wdb`.

On Forever `get_name` is "" for every unit and `get_classification` is 0
(3,293 of 3,293 recorded reads). The client still knows both. Every creature
the server has described to it is kept in
`Cache/WDB/<locale>/creaturecache.wdb`: the server's creature-query answer.
The loader's file sandbox is the client folder (answered on Era, 2026-10-02),
so the file can be read in the game. It is read once, on first use. The
locale comes from `WTF/Config.wtf`'s `textLocale`, then `enUS`. The
asset registry's client folder is tried first, then the bare path.

Two things decide what it knows:
- **The client writes the file when it exits.** On 2026-10-03 its time
  matched the end of the session before, not the session running. So it
  holds what EARLIER sessions saw, Forever's own npc ids (250000 and up)
  included.
- **A new client build wipes it.** After patch 1.60.1.70205 it held 16
  creatures.

Every record is held to the exact length the layout gives (see the top of
`services/creatures.lua`). One that does not add up keeps its name and loses
its type, family and rank. So a changed layout costs the rank; it never
gives a wrong one. `stats().unchecked` counts such records. All 16 records
of build 70205 hold. A copy of that file is the test fixture:
`tools/jtest/mock/fixtures/forever_creaturecache_70205.wdb`
(`jcore_creatures_test`).

On every other client the service is inert: nothing is read, and `info`
answers nil (`jcore_era_client_test`). Loading writes one recorder trace
line: `creatures: 16 from Cache/WDB/enUS/creaturecache.wdb (build 70205,
enUS): 0 with a rank, 0 not in the known layout`.

### Game Lua (Forever, 1.5.16)

```lua
ctx.gamelua.state()          -- "off" (not Forever), "untried", "probing", "retry", "ready", "failed"; and why
ctx.gamelua.ready()          -- true once the probe has seen the bridge work
ctx.gamelua.run(slot, body, function(text, why) end)  -- body: game Lua that writes with out(text)
ctx.gamelua.report()         -- what the probe found (also scripts_data/jcore/jcore.gamelua.json)
ctx.gamelua.stats()          -- state, piece size, integer reads, latency, runs, answers, errors, timeouts
ctx.gamelua.probe_now()      -- forget the calibration and probe again
```

The loader has five calls no stub documents: `core.execute` and
`core.read_lua_string`, `read_lua_integer`, `read_lua_table_string`,
`read_lua_table_integer`. Nothing had called them before this. If execute
runs a chunk in the GAME's Lua state and the reads read that state's globals,
everything the Forever client will not tell the core directly (the quest
log, real names, the combat log's arguments) is a few lines of the game's own
API away. `services/gamelua.lua` finds out before anything relies on it.

**The probe** runs five seconds after load. It reads a global that cannot
exist yet, a GlobalStrings constant and `WOW_PROJECT_ID`, then executes a chunk
that sets a string, an integer, a table and a 4,000-character string. If the
string shows up in our own `_G`, execute ran in the loader's Lua and is no
use. Otherwise it is read back every 0.05 s for three seconds. The string
coming back means the bridge works and how long an answer takes. The integer
says whether `read_lua_integer` can be used for numbers. The long string's
length is the most one read returns, and answers are cut into pieces that
size. The table reads record which key convention `read_lua_table_*` takes. A
failed probe is tried twice more, twenty seconds apart. When the last
session's file already says "failed" (every Forever session so far), it is
one probe, with its lines in the trace and the debug log only (1.8.3); a
bridge that answers is announced as ever, and `probe_now()` does all three
aloud. Then a census
records which of the game API the readers want exists (C_QuestLog, C_Map,
C_NamePlate, C_TooltipInfo, ...). All of it goes to
`scripts_data/jcore/jcore.gamelua.json` and to the recorder's trace as
"gamelua:" lines.

**A run** sends `body` inside a pcall with an `out(text)` function. What it
wrote is joined with newlines, cut into pieces and stored in
`JCORE_GL_<slot>_1..N`, with N and a sequence number beside them. Each is
also written as a string (`NS`, `SEQS`) for a loader whose integer read does
not work. The answer is polled until the sequence matches, read back piece by
piece and handed to the callback, or `(nil, why)` for an error raised in the
game or no answer in three seconds. One run per slot at a time. Bodies are
the game's Lua 5.1. JCore sends only what callers give it, and the callers
in this repository only read.

**Every other client:** decided once at load. No job, no read, no execute;
`state()` is "off" and `run()` answers false (`jcore_era_client_test`).
Tests: `jcore_gamelua_test` (a fake game behind the five calls,
`tools/jtest/mock/gamelua_fake.lua`: working, deferred, string-only reads, short
reads, loader-side, raising and silent execute).

### Forever, answered per client (1.6.0)

A plugin asks the same question on every client and JCore answers for the one
that is running. On Era every answer below is the client's own read, exactly
as before, with nothing tracked, read or registered extra. On Forever, where
the API recorder found the reads empty or wrong, JCore works it out. Jambix AIO
1.55.0 handles none of this itself any more.

```lua
-- what Forever does differently, as flags (ask about the behaviour, not the name)
ctx.world.client().combat_log        -- false: COMBAT_LOG_EVENT_UNFILTERED has no arguments
ctx.world.client().auto_repeat_once  -- true: Auto Shot fires once per press
ctx.world.client().auto_start_melee  -- true: melee Attack makes the helper drop an Auto Shot START
ctx.world.client().unit_names        -- false: get_name is "" for units
ctx.world.client().recording         -- true: the API recorder runs (Forever, with Jambix Debug)

-- units
ctx.units.name(unit)                 -- Forever: services/names.lua
ctx.units.classification(unit)       -- Forever: the creature cache's rank where the read says 0
ctx.names.of(unit)                   -- name, source ("client", "known", "learned", "cache")
ctx.names.learn(unit_or_guid, npc_id, name)   -- teach it a name from another source
ctx.loot.tapped(unit_or_guid)        -- somebody else's mob? (Era: false, no read)
ctx.loot.fought(unit_or_guid)        -- when it last fought us, our pet or our group
ctx.loot.corpse(unit)                -- lootable, skinnable
ctx.loot.window_needs_taking()       -- Forever: the loot window does not empty itself
ctx.loot.take_window()               -- takes slots 0..count-1 (1.8.11)
ctx.loot.open(unit, "loot"|"skin")    -- opens a corpse the way that works here (1.6.1)
ctx.loot.opening()                   -- an attempt still walking or waiting on its window

-- the player
ctx.player.power(type) / max_power(type)   -- Forever: counted while the read says 0 (services/power.lua)
ctx.player.power_unread(type)        -- mana on Forever: 1 fine, 0.05 dry for a moment; nil where read
ctx.player.power_counted(type) / power_summary()
ctx.player.shapeshift_index()        -- nil = unknown (Forever, until the read names a form)
ctx.player.channel_spell_id()        -- nil for an id no spell can have (Forever)
ctx.spells.learned(id)               -- learned, how: "known" / "has_spell" / "refused" (Forever: final)
```

**Names** (`services/names.lua`). On Forever: `get_name` when it gives a real
name; a name heard for this unit (UNIT_SPELLCAST_SENT carries the name of
your target); one learned for its kind, kept by npc id in the `jcore.names`
store (Jambix AIO's `forever_names` store was taken in once); the creature
cache. "Unknown" is never a name.

**Loot** (`services/loot.lua`, polled once a tick after the enemies stage).
On Forever no read tells a lootable corpse from a looted one, and
`is_tap_denied` answered false until client patch 1.60.1.70205. So "fought"
is a mob seen engaged with us, our pet or group, or cast at by us. "Tapped" is
`is_tap_denied` true (read every 2 s per hostile), or in combat with a
stranger with none of it on us. A corpse is ours when it fought us within
120 s and is not tapped; the loot window within 6 yd clears it.

**The tap, read as the contract types it (1.8.8).** `scripts/.api` types
`is_tap_denied` as a number, while Forever's client answers a boolean. `loot.lua`
took only `true`, so a `1` from a build that keeps to the contract counted as
nobody's mob and its corpse as ours. Now `true` or any non-zero number is
somebody else's tag, in `tapped()` and in the corpse read, the same way Jambix
AIO's ESP reads it. Test: `jcore_names_loot_test` ("is_tap_denied as the .api
types it").

**Opening a corpse (1.6.1, corrected 1.6.2).** The first traced session had three `loot_object` calls at a corpse 3.7 yd away within two seconds, the first walking the character onto it, and no window from any -- each press cancelled the one before. Pressed once and waited on, `loot_object` does open a corpse (a Wendigo in 0.6 s), and `interact_with_object` never has. So `loot.open` there uses the kind's own call (`loot_object`, `skin_object`) first and the interact next, alternating until one is followed by a loot window (or, for skinning, the player's cast), then keeps that one. An attempt stays pending while the character walks and until it has stood still for 2 s; `loot.opening()` says so, so a caller does not press again on top of it. Each try and its outcome go to the trace as `loot:` lines. Era: `loot_object` / `skin_object` as always, never pending.

**The other call on the next try (1.6.5).** One window used to settle the call for good. In the AIO 1.57.0 trace a single interact window (pressed point-blank after `loot_object` had walked there) taught the interact, and the next corpse refused it twice with `loot_object` never tried again. Now the call that last opened one goes first, and the other goes on the next try at the same corpse. Tries are counted per kind, so a corpse's first skin try is `skin_object` whatever its looting took.

**A press that walked there (1.6.7).** A press from a few yards first walks the character onto the corpse, and that press seldom opens it. Across the AIO 1.57.0 and 1.58.0 traces one walking press in four opened its corpse, while every press made standing beside one opened it within 0.4 s (five of five). So once a press has walked and the character has stood still for 0.5 s with nothing, `loot.opening()` ends the attempt and the caller presses again from beside the corpse. This replaces the 2 s wait; an Elder Crag Boar lost 2.8 s to it. The walk is watched in `_poll`, because no caller asks while the character moves. The trace line reads `brought nothing ... (it walked there; pressing again from beside it)`. The recorder now traces sweep arrivals and departures only for units within 100 yd: in a town, players at the edge of sight filled 5,692 of a session's 6,000 kept lines and pushed the auto-loot lines out.

**What the first Forever study showed, and the change it led to (1.6.9).**
- `has_loot` was true from death until the window took the loot on the one corpse opened, and false on all five never opened. One of those five was a Forest Spider we killed that had nothing on it.
- `can_be_looted` went true about 3 s after the kill and false as the press went out, so it means "you may loot it now", not "it has loot".
- `loot_object` set the mouseover, then the target, to the corpse before the window opened, like a right-click.
- Slot 0 held the coins (`get_loot_is_gold` true), confirming the slots count from 0.
- "We fought it" had made the empty spider lootable, and auto-loot pressed it three times. Now, once `has_loot` has answered true in a session, `loot.corpse` lists a corpse exactly when `has_loot` says so and it is not somebody else's. A window keeps it off the list for 3 s, until `has_loot` catches up. Before `has_loot` has answered, the fight still counts as before.

**One window, two events (1.6.10).** The second study (at Kobolds) showed that Forever sends `LOOT_OPENED` twice for every loot window, about 0.13 s apart, and `LOOT_CLOSED` twice as well. On the second event `loot.lua` had no press pending, took it for a window nobody pressed for, and marked the nearest *other* corpse looted. Now a second `LOOT_OPENED` within 0.5 s of the first is ignored. The study counts it on the same window instead (`events`), and `lootstudy_diff.js` shows the count per window. The same session also showed that both open calls drive the pointers before a window comes: the mouseover becomes the corpse, then the target, then the window opens, 0.6 to 2.4 s after the press. `softinteract` never named a corpse; `softenemy` did name live mobs.

**Tried and taken out (1.7.0).** Two experiments from the loot study opened no
corpse that the two calls above had not: targeting the corpse before the
press (1.6.11; it also took the player's target away) and `use_object` as a
third call (1.6.12). Both are gone. `loot.attempt()` and the
`jcore.loot.nothing` event stay, for Jambix Debug's study. What a press
brings on Forever is the loader's: its loot calls open a corpse within 2 s
about half the time (99 of 221 `loot_object`, 41 of 115 interact presses),
where Era's always do.

**Power** (`services/power.lua`; Jambix AIO's `forever_power.lua` until AIO
1.55.0). Energy, rage and combo points counted from our casts, corrected by the
client's usable answers and "Not enough X". Each one is trusted from the first
read that is not 0. Combo points are kept through a target change (1.8.12) and
emptied by the client's "requires combo points". `jcore_power_test`.

### Debug tools (Jambix Debug, 1.7.0)

The Dump page, the loot study and the API recorder are no longer part of
JCore. They live in `scripts/jambix_debug`, a separate plugin that users do
not get; its README covers them. When that folder is there, JCore builds them
at boot with its own runtime (the recorder at its old place, before any
service captures a native), or late through `JCore.attach_debug` if the
plugin runs after JCore. Without it `rt.recorder`, `rt.lootstudy` and
`rt.dump` (`ctx.dump`, `JCore.dump`) are nil, the `lootstudy` stage is
skipped, and `world.client().recording` is false. `jcore_debug_split_test`
boots JCore without the plugin and then attaches it.

### Quest database (1.6.0)

Our own copy of QuestieDB's data, so nothing needs the Questie addon. Run
`node tools/jcheck/questdb_extract.js --client forever` (and
`--client vanilla`) to read QuestieDB's baked TOC from the client's AddOns
folder. That metadata is base64, then zlib for the id lists, then CBOR. The
field names and types come from QuestieDB's own `src/meta/*Meta.lua`. The
copy is written to `scripts_data/jcore/questdb/<client>/`: an index plus
1000-id buckets, 7.5 MB, which JCore reads a bucket at a time on first use.
The copy holds 4,257 quests, 10,122 npcs, 6,666 objects and 14,899 items,
with spawns, objectives, starters and finishers, and drops. It leaves out the
npc waypoints. QuestieDB's Dynamic Corrections are not applied. It is the
classic world's data: Forever's own quests and creatures are not in it.

```lua
ctx.questdb.available()
ctx.questdb.get(kind, id, key)        -- "quest" | "npc" | "object" | "item", QuestieDB's field names
ctx.questdb.row(kind, id) / quest_ids()
ctx.questdb.active()                  -- the quests you are on (Forever: the game's list, or quest events + one is_on_quest sweep)
ctx.questdb.objective_ids(quest_id)   -- npcs, objects its objectives want (item droppers included)
ctx.questdb.is_doable(quest_id) / is_complete(quest_id)
ctx.questdb.questie()                 -- core.addons.questie's calls, answered from here
```

On Forever with the 2026-10-06 core (`client().quest_ids`), `active()` is the
game's own list (`core.quests.get_quest_log_quest_ids`; a quest under a
collapsed header stays while `is_on_quest` says you are on it) and
`is_complete()` is the game's word (`core.quests.is_quest_complete`). On an
older core "complete" has no source but the Questie addon, asked when it
happens to be loaded; it answers 1 / 0 / -1, which this compared against `true`
before 1.9.0, so it never said yes. The `questie()` calls answer
`is_quest_complete` in Questie's own shape since 1.9.0: 1 or 0, not true or
false. Jambix AIO 1.55.0's quests and quest log read Questie's calls from here
first, so Questie is not needed. `jcore_questdb_test` runs against the real
extracted files; `jcore_forever_core_test` covers the 2026-10-06 core.

### World

```lua
ctx.world.map_id() / .map_name() / .instance_name() / .instance_type()
ctx.world.in_instance() / .in_dungeon() / .in_raid_instance()
ctx.world.in_arena() / .in_battleground() / .in_pvp()
ctx.world.difficulty_id() / .difficulty_name()

ctx.world.keystone_level() / .in_keystone_run() / .keystone_info()
ctx.world.encounters(map_id?) / .boss_count() / .in_encounter()
ctx.world.in_delve()

ctx.world.is_flyable() / .height_at(pos) / .is_raid_marker_active(i)
ctx.world.place_raid_marker(index, position)
ctx.world.ping() / .game_version() / .region() / .realm()
ctx.world.corpse_position() / .resurrect_delay()
ctx.world.completed_quest_ids() / .is_quest_complete(id) / .is_on_quest(id)

ctx.world.client()      -- { version, exact, forever, retail, trait_talents,
                        --   classic_quest_log, completed_quest_list, cancel_buff,
                        --   core_20261006, quest_ids, ... }
ctx.world.is_forever()
```

Zone facts are cached by how often they can change, and everything held *about
a place* is dropped wholesale on `jcore.zone.changed` — after a zone change
every one of those answers is about somewhere you have left.

**Which client.** `client()` turns `core.get_game_version`'s one word per
product into what the client can do, read once per session. Branch on the
capability flags, not on the version string. Forever (Classic+, 2026: a
level-60 classic world on the retail engine) is the client where they matter.

Forever support is **added beside** the classic paths, never in place of them.
Every Forever branch in JCore and Jambix AIO is behind `client().forever` (or
a flag only Forever and Retail set), decided once per session, so on Era every
call, read and log line is what it was before. `jcore_era_client_test` boots
Era with a Forever client installed beside it and checks exactly that.

| Flag | Forever | What to do there |
|---|---|---|
| `trait_talents` | true (Retail too) | `get_talent_info` is `{}`; read `core.game_ui.get_active_talents` and the trait tree calls |
| `classic_quest_log` | false | JCore does not walk the classic log there. Before the 2026-10-06 core `get_num_quest_log_entries` is 0 and `get_quest_log_title` empty; that core answers them, but its leader boards are undocumented for Forever, so read the quest-ID calls (`quest_ids`) or `is_on_quest(id)` |
| `completed_quest_list` | false before the 2026-10-06 core (Retail too); true from it | `completed_quest_ids()` is `{}`; ask `is_quest_complete(id)` per id |
| `cancel_buff` | false before the 2026-10-06 core; true from it | the old native silently does nothing (no UnitBuff), so `ctx.input.cancel_buff` returns `false` and logs once |
| `core_20261006` | true on that core, any client | the 2026-10-06 core (branch `lua_requests_06_10`), known by the functions it added (`core.get_server_time`, `core.quests.get_quest_log_quest_ids`, `core.character.get_xp`): 1.9.0 |
| `quest_ids` | true on that core, any client | `core.quests.get_quest_log_quest_ids`, `get_quest_objectives` and `is_quest_complete` answer your quests from the game |

The 2026-10-06 core also fixed, on every classic build, things JCore read
around without a flag: `get_threat_situation`'s `status` and `is_tanking`
(see **Threat**), `get_group_role` (Era, TBC, Forever and the private servers
always answered -1; the Forever party-row read below is kept, and agrees), and
on Forever the Skill window (`core.skill`, the "skill" source of
`player.skill()`).

Also Forever-only, in JCore itself: the backpack size, which the core reads
at a classic offset never measured on that client, is replaced by 16 when it
answers something no backpack can have (below 1 or above 36), and the client
folder is found from the install (see **Assets and icons**). Since 1.5.7, from
the API recorder's evidence: `spells.gcd()` and `player.gcd()` read the global
cooldown off a spell with no cooldown of its own (`get_spell_base_cooldown`:
`cooldown_ms` 0, `gcd_ms` above 0), because `get_global_cooldown` answers 0
every time there and `get_spell_cooldown` of such a spell reports the GCD
(`spells.gcd_probe()` names it); and `player.casting_spell_id()` answers nil for
an id no spell can have (above 5,000,000), which the active channel sometimes
reads. Since 1.5.10, `spells.castable()` on Forever does not ask the loader's
`spell_helper` at all: it calls `input.get_control_object` (nil on all 481,552
recorded calls) and reads the client's range data (`get_spell_max_range` 0 on
43,505 of 43,544), and so called every spell uncastable -- a rogue stood still.
The gate there is JCore's own: known, usable, cooldown, line of sight
(`geometry.sight`, one ray per target per tick since 1.8.0 -- never
`graphics.is_line_of_sight` on Forever, which asserts in the client on build
70338, `ASSERT(m_data)` in `M2HitTest.cpp`: see *Line of sight on Forever*
below), melee reach from the two positions and combat
reaches (`max(5, reach + 4/3)` yards), and a range the client does not give is
left to the client. Since 1.5.13, in a party on Forever, `group.role()` and
`group.objects()` read the party rows: `get_group_role` answered -1 and
`is_party_member` false for everyone there, while each `get_party_members` row
carried `role = "DAMAGER"` (or TANK / HEALER) and `object = <the member>` -- so
no tank or healer was ever found. Era makes the same calls it always did.

The `.api` notes say Questie and RestedXP ship for Forever and that its
`UNIT_AURA` carries the same per-aura records as Era. They note no Forever gap
in `get_buffs` / `get_debuffs`. None of this has been run on a Forever client
yet.

**The API recorder** is Jambix Debug's since JCore 1.7.0
(`scripts/jambix_debug`, with its guide and the Forever API reference).

### Group

`ctx.units.allies()` is a **proximity** list: every friendly unit in cache
range, including other people's pets and passing strangers. This is the actual
group.

```lua
ctx.group.members()                -- client rows, in or out of range
ctx.group.objects()                -- resolvable to live objects, incl. player
ctx.group.size() / .in_group() / .in_raid()

ctx.group.tanks() / .healers() / .damagers()
ctx.group.role(unit) / .is_tank(unit) / .is_healer(unit)
ctx.group.contains(unit)

ctx.group.lowest_health(range?)
ctx.group.count_below(0.5, range?)  -- "is a raid cooldown worth it"
ctx.group.average_health(range?)
ctx.group.with_aura(spell_id_or_list)

ctx.group.arena_opponents() / .arena_target(i) / .arena_opponent_spec(i)
```

The three role lists are built in **one** pass and cached together, so asking
for tanks and then healers costs the same as asking for either.

### Inventory

```lua
ctx.inventory.has(item_id) / .count(item_id) / .locate(item_id)
ctx.inventory.ready(item_id)        -- carried + usable + off cooldown
ctx.inventory.first_usable({ id, id, id })
ctx.inventory.cooldown(item_id) / .in_range(item_id, target)

ctx.inventory.free_slots() / .is_full()
ctx.inventory.equipped() / .equipped_at(slot)
ctx.inventory.worst_durability()    -- 0..1 across the set
ctx.inventory.gold() / .split_money(copper?)
ctx.inventory.repair_all(use_guild_bank?)
```

Walking six bags is over two hundred native calls, so it happens on
`BAG_UPDATE` and friends rather than per tick, and the result is indexed by
item id on the way through. `has()` is then one table lookup.

**On Forever (1.8.2)** none of those bag events ever arrive (the recorder's 82
event types there include only `PLAYER_EQUIPMENT_CHANGED`), so every bag
answer also expires one second after it was read. Bag 0 there is the player's
whole item array (worn gear and sold items as well as the backpack), so
`free_slots()` counts the loader's `inventory_helper` rows (its per-build
backpack offsets) and falls back to the row count. Each new answer is a trace
line, `inventory: N of M bag slots free (inventory_helper; K row(s) past the
bags left out)`. Other clients are unchanged and read nothing new.

The helper does not stop at the backpack's size either: the merchant's
Buyback list comes back as bag 0 slots past it (a sold item seen as "bag 0
slot 39" on a 20-slot backpack). So since 1.8.4 a row counts only inside its
bag. `ctx.inventory.bag_rows()` hands out those rows (bag 0 up to the
backpack, bags 1 to 4 up to theirs, one per slot), with the count left out
and the capacity. Their `(bag_id, bag_slot)` is the pair
`use_container_item` takes.

To *use* an item on the global cooldown, go through the arbiter —
`ctx.use_item(id, target)` — not `core.input.use_item`. A potion and a
defensive spell compete for one GCD, and a plugin that calls the native
directly wins that contest by ignoring it.

### Geometry

```lua
ctx.geometry.visible(target)        -- line of sight from the player
ctx.geometry.line_of_sight(from, to)
ctx.geometry.sight(from, to)        -- true / false / nil (unknown); what every LoS question in JCore asks
ctx.geometry.trace_line(from, to, flags?)

ctx.geometry.distance(a, b) / .distance_2d(a, b) / .distance_sq(a, b)
ctx.geometry.angle_to(from, to) / .angle_delta(a, b)
ctx.geometry.in_cone(origin, facing, point, half_angle, range?)
ctx.geometry.in_rect(origin, facing, point, length, width)
ctx.geometry.project(origin, facing, distance)
ctx.geometry.toward(from, to, distance)

ctx.geometry.centroid(list)
ctx.geometry.best_circle(list, radius)   -- position, covered
ctx.geometry.height_at(pos) / .is_grounded(pos, tolerance?)
ctx.geometry.vec(x, y, z)           -- a REAL vec3, not a plain table
```

**Line of sight on Forever (1.8.0).** `graphics.is_line_of_sight` is never called there. On build 70338 (the client patched itself on 2026-10-11) it asserts inside the client, `ASSERT(m_data)` in `M2HitTest.cpp`: a ray tested against a model whose data has not loaded. Four crashes that day, as a hunter in Duskwood and a druid in Teldrassil, each a ray from the player to a mob. On Forever, `geometry.sight` is a `trace_line` through buildings and terrain only (`WmoCollision + Terrain + IgnoreWmoDoodad`): no model on the way, so trees and rocks do not block it and the client refuses a cast behind one. trace_line's boolean is calibrated first, a ray down from the player's chest (must hit) and one straight up (must not); until both agree, sight is nil and callers treat it as unknown (a cast is left to the client, a mark is painted). `draw.unit_los`, `draw.los`, `spells.castable`, `spells.in_line_of_sight` and `geometry.line_of_sight` all ask it; an answer is kept 0.2 s per pair. Every other client keeps `is_line_of_sight`. `geometry.sight_stats()` says whether it calibrated. A fifth crash at 18:15 the same day (a hunter in Dun Modr) came from none of these: the game's Lua stack was `UseAction` on a pressed action-bar key, and the ray had the native's own ends (eye +1.6, mob +2.03), so the loader's packed Lua (the spell queue picks up pressed keys) had asked the native. So on Forever JCore also replaces `core.graphics.is_line_of_sight` in place, for every package (`services/sightguard`, built before the recorder and before anything that loads the loader's libraries). It answers `geometry.sight`, with unknown counting as in sight, and the loader's `spell_helper.is_spell_in_line_of_sight` answers the same way. `JCore.sightguard.stats()` (also on `diagnostics()`) counts the calls and keeps the file:line of each caller, each logged once. The walk map's wall rays still include doodads (it needs trees and rocks): only Market's mail errands and the walk map overlay run them.

Line of sight is a ray cast through world geometry and is the most expensive
single call a rotation makes. It is cached per unit pair per tick, so checking
it for six different spells on the same target casts one ray.

`ctx.geometry.line_of_sight` is the **authoritative** check. `ctx.draw.unit_los`
answers the same question for painting and is rationed — past its per-frame
trace budget it answers "visible" rather than spend another ray. Never gate a
cast on that one.

Prefer `distance_2d` for range checks: a target on a ledge three yards up is in
range of a ground spell, and counting the height difference says otherwise.

### Missiles

```lua
ctx.missiles.incoming(radius?)      -- aimed at the player
ctx.missiles.next_incoming()        -- missile, seconds
ctx.missiles.incoming_within(1.5)   -- the reactive-defensive check
ctx.missiles.time_to_impact(missile)
ctx.missiles.aimed_at(unit, radius?)
ctx.missiles.of_spell(id_or_list) / .from(unit)
```

Also raises `jcore.missile.launched` once per projectile — once, not once per
frame it stays in the air.

`time_to_impact` returns `math.huge` for a missile with no usable speed rather
than zero, so `time_to_impact(m) < 1` does not read an unknown as an emergency.

### Telegraphs (1.8.0)

Where an enemy's spell is about to land.

```lua
ctx.telegraphs.active()            -- every live telegraph: those on you first, then danger, then soonest
ctx.telegraphs.on_me()             -- the ones the player stands in
ctx.telegraphs.danger_at(pos)      -- the worst covering a point, or nil
ctx.telegraphs.covers(t, pos, pad?)
ctx.telegraphs.info(spell_id)      -- the data row: n, s, ct, du, lv, sh = { {k, at, r, d, w, p, via} }, dbm, pl, hint
ctx.telegraphs.available() / .stats()
```

**The data** is `scripts_data/jcore/telegraphs/<vanilla|forever>/` (`index.json` plus `spells/<id/1000>.json`). It is read on first use, a bucket at a time, like questdb. `node tools/jcheck/telegraph_extract.js` writes it from three sources:
- the client's own spell tables, decoded out of the CASC archives offline;
- DBM's classic boss mods;
- Plater's cast scripts.

Forever reads its own copy, because its spell tables differ (Blizzard is an area trigger there). Every other client reads the vanilla one.

**A row** (live: read it, do not keep it) has these fields:
- `phase`: cast, channel, missile, linger, aura, or hit.
- `shape`: circle, cone, or none.
- `anchor`: caster, target, dest, front, fixed, or player.
- `placed`: false when the client cannot say where it lands.
- `wide`: a circle of 40 yd or more, which is the room.
- Position: `pos` / `x y z`, plus `towards` and `facing` for a cone.
- Size: `radius`, `degrees`, `width`.
- Timing: `progress` (0..1) and `remaining` (seconds).
- `level`: 1 for the spell tables alone, 2 when DBM warns of it, 3 when DBM says move.
- `hint` (DBM's advice), `inside` (the player is in it, with the player's own reach `PAD` = 1 yd), `dist`.
- `source_guid`, `source`, `by_player`, `interruptible`.

**Where it comes from each tick** (core stage `telegraphs`, after missiles):
- **Enemy casts and channels**, from the enemies rows. A ground point (`dest`) is fixed where the cast target stood at the start. A unit target is followed.
- **A player's ground spell with no unit target** has no readable point: the row is not placed.
- **A cone faces the caster's `get_rotation`**, read each tick while the cast lasts.
- **Missiles** with a placed circle show where they will land.
- **A completed cast that leaves ground** lingers there for its duration. A completed cast is one that vanished within 0.35 s of its end.
- **DBM's hazards** (49 on Era: Chill, Living Bomb...) come from the player's aura index, four times a second in combat.
- **On Era only, from the combat log:**
  - DBM hazard damage on the player, held for 1.5 s;
  - instant hostile casts that leave ground around the caster (Consecration).

**Events**, on transition only:
- `jcore.telegraph.started` (row);
- `jcore.telegraph.on_me` (row).

**Cost.** Nothing is read for an enemy that is not casting a known spell. A known cast costs:
- one `get_active_spell_target` when it starts;
- for a cone, one `get_rotation` a tick.

Tests: `jcore_telegraphs_test`.

### Addons

```lua
ctx.addons.is_loaded("bigwigs")     -- and exboss, details, questie, mdt, tsm,
                                    -- zygor, rested_xp, conroc, maxdps,
                                    -- swing_timer, arena_core,
                                    -- timeline_reminders
ctx.addons.available()              -- all of them, with a boolean each

ctx.addons.boss_timers()            -- BigWigs + ExBoss, merged and sorted
ctx.addons.next_ability(only_emphasized?)
ctx.addons.ability_within("Breath", 3.0)

ctx.addons.swing_remaining()        -- math.huge when no addon is present
ctx.addons.suggested_spell()        -- spell_id, source

ctx.addons.bigwigs.get_bars()       -- every namespace mirrored verbatim
```

Timers merge on **seconds remaining**, not on expiry: BigWigs reports expiry
against engine time and ExBoss against the addon clock, so the two absolute
figures are not comparable. `spell_id` is only set for ExBoss bars — a BigWigs
bar key is an opaque handle, not a spell.

### Control

Movement, facing and targeting are shared the way the GCD is shared, so they
are **leased**. Acquire every tick you want the channel; a lease that stops
being renewed lapses on its own, which is what makes a crashed plugin give
movement back.

```lua
ctx.input.acquire(ctx.CHANNEL.MOVEMENT, ctx.PRIORITY.ROTATION, "kiting")
ctx.input.holds(channel) / .holder(channel) / .release(channel)

ctx.input.set_key("forward", true)   -- forward|backward|left|right|
                                     -- turn_left|turn_right|up|down|descend
ctx.input.stop_moving()
ctx.input.hold(true) / .hold(false)  -- hold the character STILL against its own
                                     -- keys, for the half-second an Auto Shot
                                     -- needs; lifts with the lease
ctx.input.face(unit) / .look_at(point)
ctx.input.set_target(unit) / .set_focus(unit)

-- no lease needed: these do not conflict the way a held key does
ctx.input.loot(unit) / .skin(unit) / .interact(object) / .use_object(object)
ctx.input.jump() / .mount(i) / .dismount() / .cancel_buff(buff)
ctx.input.is_key_pressed(vkey) / .is_typing()
ctx.input.pet.attack(target) / .follow() / .passive() / ...
```

Losing a lease is normal and needs no handling. A plugin that **was** holding
keys down when it lost gets them released for it — otherwise a preempted plugin
that never runs again leaves the character running into terrain for ever.

Check `ctx.input.is_typing()` before reacting to a key. A user typing in chat
should not trigger a keybind.

### Navigation

Wraps the Sentinel navigation plugin when it is installed. Requests go through
the movement lease, so a defensive that needs to move *now* preempts a
gathering route instead of fighting it.

```lua
if ctx.nav.available() then
    ctx.nav.move_to(position, {
        priority = ctx.PRIORITY.IDLE,
        reason   = "to the node",
        on_done  = function(ok, why) end,
    })
end

ctx.nav.is_moving() / .state() / .progress() / .destination()
ctx.nav.remaining_distance()   -- along the PATH, not the straight line
ctx.nav.stop()                 -- your route only; never someone else's
ctx.nav.validate(target, callback)
```

`available()` is false when the plugin is absent **or** its server is not
connected. Check it rather than assuming.

### Walk map (1.12.0)

What is round the player, a yard at a time, so a plugin that moves the
character knows what is in front of it and does not walk into it. It needs no
other plugin: where Sentinel is missing, or (on Forever) accepts a route and
never moves, this is the way round things.

```lua
-- What is in front, and which way round it.
local a = ctx.walkmap.ahead(5)          -- { clear, distance, reason, at, heading, unknown }
if not a.clear then
    -- a.reason: "wall" | "ledge" | "object" | "stuck" | "drop" | "steep" | "water" | "hole"
    local side, heading, free = ctx.walkmap.free_side(4)   -- "left"/"right", radians, yards
end
ctx.walkmap.probe(heading, distance, opts?)    -- the same, along any heading
ctx.walkmap.around(distance?, count?)          -- 16 probes round the player

-- Can I walk this straight line?
local ok, free, reason, at, unknown = ctx.walkmap.clear_line(from, to, opts?)

-- The point to face right now (greedy, the next few yards).
local point, info = ctx.walkmap.steer(goal)   -- info.offset: degrees off the goal bearing

-- A route round what is in the way (A*, one-yard cells, smoothed).
local waypoints, why = ctx.walkmap.path(from, to, { arrive = 1.5 })   -- why "partial" or the failure

-- All of it, driving the character (face + forward, behind the movement lease).
ctx.walkmap.walk_to(goal, {
    priority = ctx.PRIORITY.IDLE, reason = "to the mailbox", arrive = 1.5,
    on_done = function(ok, reason) end,   -- "arrived", "preempted", "no way through", "no progress", "timed out", "stopped", "replaced"
})
ctx.walkmap.stop()                     -- your walk only

ctx.walkmap.request(20) / .release()   -- keep the map filled out to N yards (default 20, max 40)
ctx.walkmap.cell(pos) / .blocked(pos)  -- one cell: z, water, wall score, stuck, object, ledge
ctx.walkmap.mark(pos, "blocked"|"open") / .learn_stuck(pos, heading) / .forget(pos?, r?)
ctx.walkmap.stats() / .rays()          -- what it knows, and how its rays were calibrated
```

`opts` on every query: `objects = false` (ignore game objects), `water = true`
(swimming is fine: the floor is the surface), `drops = true` (ledges are fine,
going down), `unknown = "stop"` (unprobed cells block; by default they pass and
are counted), `body = yards` (half-width a line keeps clear, default 0.4).

**Five sources, because no one sees everything.** *Ground*: height probes,
chained outward cell to cell so a cell is measured against its neighbour, not
the player (a bridge deck or a tent roof is not the floor); a fall past 2.5 is
a drop, no ground a hole. *Slopes and steps* (1.13.1): a rise of more than
0.45 between two cells is looked at closely, by halving the line between them.
Spread out, it is a slope, walked up to 1.2 yards a yard (about fifty
degrees). All at once, it is a step -- a table, a bench, a counter, a cliff --
which is never walked up: the reason is `ledge`. The step is kept on the edge
between the two cells, not on either cell, so a table top is still somewhere
to stand: walking along it and stepping off it are fine, which is what the game
allows. *Water*: the same probe with `{ water = true }`, where the ground falls
below the player; over 1.4 yards deep swims. *Walls*: rays at shin (0.35),
knee (0.7) and chest (1.6) height, fanned out from the player (96 directions,
the front third twice as often) along the line the character would walk --
so a ray meets the side of a table rather than riding up onto its top --
against buildings and doodads only. Terrain is left out of the mask, because a
knee-height ray up a hill hits the hill. Each hit is probed just past it: no
surface near its height is a wall; a top more than a step above where the ray
came from is furniture (a wall mark when it is narrower than a cell, like a
rail or a bench, and the ground layer's ledge when it is not); the floor
rising smoothly into the ray is a ramp or a stair, and not in the way. *Objects*: every game
object nearby as a circle of its bounding radius, because the API says rays
miss stoves, chairs and benches although the client collides with them. They
are a cost, not a wall: a herb is a game object too. *Stuck*: the character
pushed forward (our walker, or the player's own W) for 0.6 s and did not move.
That spot is marked, saved per map in `scripts_data/jcore/walkmap.json`, and
cleared the moment the player is seen within half a yard of it. A root, a
stun, a cast, swimming or flying is never taken for a wall.

**The rays are calibrated, not trusted.** `native_intersect` and `trace_line`
had never been called on Forever, and their docs leave the argument order,
what `distance` means and what `trace_line`'s boolean says open. So before a
wall ray counts, a ray straight down under the player must hit the ground and a
short one at their chest must miss; the first call shape that gets both right
is used for the zone. The first hits are then checked against a second ray
stopping just short of them -- a hit from the far face of a wall turns the
argument order round. With no working ray call, walls come from objects and
stuck spots alone, and `rays().state` says `failed` or `unavailable`.

**Cost.** Nothing is cast unless something asked: a `request`, a `walk_to`, a
query in the last five seconds, or the overlay. Then 24 rays and 16 height
probes a tick at most, nearest cells first, under a 1.5 ms CPU cap
(`set_budget(rays, probes)` changes the counts). The ground does not move, so a
cell is probed once per zone; the map is kept as the player walks (30,000 cells,
then whatever is near) and dropped on a zone change.

**The walker** plans at most once a second and whenever the map changes on the
leg in front of it, faces the next waypoint, and holds forward -- the
`look_at` + forward that moves the character on Forever. A corner is cut only
when the leg after it is clear. Four seconds without getting closer is a jump
and a re-plan, four times, then `no progress`.

**See it.** *Show walk map* on the Core page (World section) paints what the
map knows: walls red, the tops of steps (tables, benches, counters, cliff
edges) deep orange, stuck spots magenta, holes light orange, deep water blue,
objects yellow, the five yards ahead green or red, and the walk's route. Open
ground is not painted.

Events: `jcore.walkmap.calibrated (state, note)`, `jcore.walkmap.stuck (pos,
heading)`, `jcore.walkmap.walk_started (owner, goal)`, `jcore.walkmap.walk_done
(owner, ok, reason)`.

### HTTP

```lua
ctx.net.get(url, { ttl = 300 }, function(result)
    if result.ok then ... end      -- .ok .status .body .type .headers
end)

ctx.net.get_json(url, function(data, err, result) end)
ctx.net.post_json(url, payload, function(data, err, result) end)
```

Identical in-flight requests are collapsed into one, answers are held for a
caller-chosen lifetime, at most four run at once and the rest queue. Callbacks
are delivered on the next update rather than inside the native completion hook,
and are `pcall`ed — so a raise in yours lands in the log instead of somewhere
nobody is watching.

Pass `fresh = true` to bypass the cache for a resource you know just changed.

### Storage

A named table that loads itself and saves itself, namespaced under your plugin
id. For state that is not a setting — routes, counters, histories. Menu widget
values are already persisted by the menu host and do not belong here.

```lua
local store = ctx.store()          -- or ctx.store("routes")

store:get("kills", 0)
store:set("last_zone", map_id)
store:increment("kills")
store:update({ a = 1, b = 2 })
store:all()                        -- by reference; call store:touch() after
store:save()                       -- force a write now
```

Writes are debounced a couple of seconds after the last change. Writing on
every `set` means a file write per kill; writing only on unload loses
everything if the client exits badly.

### Everything else

Every remaining `core.*` namespace is mirrored: guarded so it cannot raise,
with readers memoised and writers passed straight through.

```lua
ctx.bridge.auction_house / .mail / .trade_skill / .pet_battle / .lfg_list
ctx.bridge.quests / .taxi / .profession / .game_ui / .character / .delves
ctx.bridge.spell_book / .object_manager / .inventory / .graphics / .input
ctx.bridge.client.get_map_name()   -- the calls that sit directly on `core`

ctx.bridge.has("some.new.call")    -- is it on this build?
ctx.bridge.call("some.new.call", arg)
```

Shapes and argument order are exactly the native ones, so the stubs in
`scripts/.api` are the documentation. Half of this API only works while a
particular UI frame is open; here that answers nil instead of raising.

`graphics` and `input` are mirrored with caching **off** on purpose — both are
almost entirely side effects, and their few readers are cached properly by
`ctx.geometry` and `ctx.input`, which know what the right key is.

### Drawing

Submit from a render job; the core paints everything in layer order once every
plugin has submitted. Never call `core.graphics.*` directly from a render job —
that is what reintroduces the z-order problem.

```lua
ctx.draw.circle_3d(pos, radius, color, { layer =, thickness =, filled = })
ctx.draw.line_3d(from, to, color, opts)
ctx.draw.line_2d(from, to, color, opts)
ctx.draw.text_3d(pos, text, color, opts)
ctx.draw.text_2d(pos, text, color, opts)
ctx.draw.rect_2d(top_left, w, h, color, opts)
ctx.draw.unit_box(unit, color?, { thickness =, aspect =, filled = })
ctx.draw.unit_label(unit, text, color?, { offset = 30 })
ctx.draw.unit_bar(unit, fraction, color, { offset = 20, width = 60 })
ctx.draw.submit(layer, fn, droppable?)   -- anything else

ctx.draw.unit_w2s(unit)            -- cached; use instead of core.graphics.w2s
ctx.draw.project(pos)              -- uncached, UNCULLED; derived points only
ctx.draw.screen_size()             -- w, h; read once per frame for everyone
ctx.draw.unit_color(unit)          -- palette colour by relationship
ctx.draw.theme.enemy / .ally / .danger / .warning / .text / .accent / ...
JCore.draw.set_theme({ enemy = my_color })
```

More marks, same queue and same cache:

```lua
ctx.draw.measure(text, size)             -- cached text width
ctx.draw.text_bg(pos, text, color, opts) -- text on a fitted backdrop
ctx.draw.unit_box_corners(unit, color, opts)   -- brackets, not a closed box
ctx.draw.unit_box_3d(unit, color, opts)        -- a real cube, one submission
ctx.draw.unit_bar_multi(unit, segments, opts)  -- health + absorb + incoming
ctx.draw.arc_3d(center, radius, fraction, color, opts)  -- ring at the feet
ctx.draw.ring_3d(center, radius, fraction, color, { to =, bg =, inner =, outer = })  -- 1.11.0
ctx.draw.curtain_3d(center, radius, color, { to =, height =, points =, rings = })   -- 1.11.0
ctx.draw.beacon_3d(pos, color, { height =, radius =, fill = })  -- 1.13.0: a pillar of light
ctx.draw.pulse(pos_or_unit, color, { life =, from =, to = })    -- 1.13.0: fire and forget
ctx.draw.blend(a, b, t)                  -- a colour part of the way to another
ctx.draw.cone_3d(from, towards, radius, degrees, color, opts)
ctx.draw.polygon_3d(points, color, { filled = })        -- ONE closed ring
ctx.draw.circle_2d(center, radius, color, opts)
ctx.draw.arrow_2d(center, angle, size, color, opts)
ctx.draw.edge_indicator(world_pos, color, { label = }) -- off-screen pointer
ctx.draw.panel(origin, w, h, { title = })    -- returns the first row's y
ctx.draw.clip_push(x, y, w, h, layer) / ctx.draw.clip_pop(layer)
ctx.draw.spell_icon(spell_id, pos, size, tint?)  -- = ctx.draw.image("spell:<id>", ...) since 1.8.3
ctx.draw.texture(data_path, pos, w, h, tint?)
ctx.draw.attachment(unit, id) / ctx.draw.unit_head(unit)  -- cached per frame
ctx.draw.unit_los(unit)                  -- rationed; see set_los_budget
ctx.draw.notify(id, title, message, duration?, color?, dedup?)
```

**Rings and curtains (1.11.0).** `ring_3d` is a flat ring on the ground
that fills: a cast, a countdown, a timer. Where the loader has
`render_circle_percentage_3d` and the JCore/UI page's *Shader drawing* switch
is on, it is one SDF quad with soft edges, a band all the way round (`bg`,
default the theme's backdrop) and a fill shading from `color` to `to`;
otherwise two outlines, the fill in the colour it has reached. A call that
raises is warned about once and the outlines are used from then on.
`curtain_3d` is the wave of Lemons' Aurora Systems as one submission: a
curtain of `line_3d` standing on a circle, its base on the ground, rippling
in and out and up and down, shading from `color` at the bottom to `to` at
the top. The defaults (4 rings of 36 points, a vertical every third point)
are 180 lines; Aurora Systems' own defaults draw 1,020. Test:
`jcore_draw_world_test`.

**Sheets, beacons and pulses (1.13.0).** `curtain_3d` takes `fill` (0..1): a
see-through sheet of `triangle_3d_filled` between its rings, that strong at
the bottom and gone at the top (`lines = false` for the sheet alone); `lod`:
fewer points with distance from you, full detail out to `near` (20 yd),
never under 10; and `cull_height`: drawn while its top is on screen, not only
its foot. `beacon_3d` is a tall thin filled curtain with all three, and a
soft glow at its foot: a place or a far unit you can find from across a zone.
`pulse` is a ring that opens out and fades for something that just happened;
fire it once and JCore draws it on the frames that follow (in the flush), at a
place or under a unit it follows. At most 32 play at once.

**Budgets.** `set_budget(n)` caps DROPPABLE submissions per frame and
`set_los_budget(n)` caps line-of-sight traces (0 disables them). A submission
is only ever dropped if the caller passed `droppable`, so the way to use this
is to mark your least important marks expendable and leave your warnings
alone. `stats()` reports `submitted`, `painted`, `culled` and `dropped`.

`attachment`, `unit_head` and `unit_los` answer from a per-frame cache for the
same reason `unit_w2s` does: they are native calls that several plugins ask for
on the same unit in the same frame. `unit_los` keeps its answer for half a
second (1.8.0): it only fades a mark, and re-asked every frame it was nearly
every ray the plugins cast, each one a chance at the client's own crash in a
ray (Forever, Forlorn Rowe, 2026-10-11). `attachment` returns nil rather than the
zero vector the native call gives for a model that has not loaded — that vector
would put your mark at the centre of the map.

`arc_3d` takes a 0..1 fraction. The native call underneath takes a
"percentage" whose scale is undocumented, and the wrapper multiplies by 100; if
arcs ever come out full or invisible, that multiply is the one line to change.

`unit_box` is the standard ESP mark: it projects the unit's feet and the point
one model-height above them, so the box tracks perspective with no per-creature
tuning.

The 2D primitives coerce a plain `{ x =, y = }` table into a real `vec2` for
you, so a HUD corner written inline works as written.

Layers, low to high: `BACKGROUND` `WORLD` `DANGER` `UNITS` `OVERLAY` `HUD`
`TOOLTIP` (on `ctx.LAYER`). Pick the band that matches what the mark *means* —
colour and thickness are for importance.

**The screen UI paints over the game's frames (1.8.1).** The loader's render
pass is painted *under* the client's own UI, so before 1.8.1 a JCore window, an
ESP panel or a tooltip went behind the bags, the map or a quest log whenever
one was open over it. The loader's window pass
(`core.register_on_render_window_callback`) is painted over them. At each flush
JCore now hands everything from `HUD` up (windows, panels, popups, tooltips,
toasts, a plugin's own `HUD` text) to that pass, in the same layer order; the
world bands (`BACKGROUND` to `OVERLAY`) stay in the render pass, under the
game's frames as its own nameplates are. Nothing changes for a plugin: submit
as before. The hand-off only happens while the window pass is seen running. A
loader without it paints everything in the render pass as before, and one that
stops calling it gets the UI back in the render pass within three frames. A
hand-off is painted by at most two window passes, so a render pass that stops
cannot leave a frozen copy on screen. *Draw over the game's windows* on the
JCore/UI page (on by default) turns it off. `stats()` adds `ui_pass`
(`"window"` while the UI paints over the game, else `"render"`), `over_game`,
`window_calls` and `window_painted`; the Core page's `draw:` line says which.
Mouse input is unchanged: a window takes the mouse from the game while the
cursor is on it only with *Capture the mouse over windows* on (the default).
With it off, a click on a window also reaches the game frame under it. Test:
`jcore_ui_over_game_test`.

### Menu

```lua
local menu = ctx.menu({ icon = "widgets" })   -- page under the JCore node
local s = menu:section("General", "settings")
s:toggle("enabled", "Enable", true)
s:slider("range", "Engage range", 5, 40, 30, "yd")
s:keybind("burst", "Burst", 0x54, { mode = "hold" })

menu:get("enabled")
menu:get_or("enabled", true)       -- prefer this; nil in a hot path is silent
menu:set("enabled", false)
menu:on_change("range", function(new, old) end)
menu:is_keybind_active("burst")    -- keybind values are tables, not booleans
menu:title(fn_or_string, opts)     -- the ONLY element taking a live provider
menu:live_lines(count, provider)   -- fixed-height live readout
```

Pass `{ root = true }` to sit at the sidebar top level instead of under JCore.

Widget ids are the persistence key. Renaming one orphans the saved value and
silently resets the widget to its default, so treat ids as permanent and change
only labels.

`Section:label` takes a **plain string** fixed at declaration. Anything that
updates per frame must use `menu:title(fn)` or `menu:live_lines`.

### Overlay UI

The declarative menu holds **settings**. Anything that lives on the screen
while the menu is closed -- a threat panel, a rotation HUD, a session
readout, a boss-timer strip -- is a **window**, and windows come from
`ctx.ui`. They drag, collapse, resize, remember where they were, stack in a
shared z-order and paint through the same layer queue as every other mark, so
they always sit above world drawings and never fight another plugin over the
mouse. Since 1.8.1 they also paint over the game's own frames (the bags, the
map, a quest log), not under them: see *The screen UI paints over the game's
frames* under *Drawing*.

The toolkit is immediate mode with retained state: describe the window every
frame from a render job, read the values back from the calls.

```lua
ctx.render(function()
    local ui = ctx.ui
    if ui:begin_window("hud", { title = "My HUD", x = 80, y = 120, w = 260 }) then
        ui:text("Target: " .. (name or "none"))
        if ui:button("pull", "Pull", { style = "primary" }) then pull() end
        local auto = ui:toggle("auto", "Auto mode", true, { persist = true })
        local range = ui:slider("range", "Range", 5, 40, 30, { suffix = "yd" })
        ui:progress(ctx.player.health_pct() / 100, { color = "health", text = "HP" })
    end
    ui:end_window()   -- ALWAYS, whatever begin_window returned
end)
```

Or let the toolkit own the job:

```lua
local hud = ctx.ui:window("hud", { title = "My HUD", anchor = "top-right", x = 20, y = 200 }, function(ui, handle)
    ui:player_frame({ level = true })
    ui:unit_frame(ctx.player.target())
    ui:spell_row({ 2061, 2050, 585 }, 28, { highlight = next_spell })
end)
hud.toggle()   -- .show() .hide() .is_visible() .remove() .get(id) .set_value(id, v) .on_change(id, fn)
```

Window options: `title` (or `false` for none), `x`, `y`, `w`, `h` (omit for
auto-height), `anchor` (`top-left`|`top-right`|`bottom-left`|`bottom-right`|`center`),
`movable`, `resizable`, `collapsible`, `closable`, `persist`, `scroll`, `opacity`, `bg`,
`padding`, `min_w`, `min_h`, `max_h`, `capture_mouse`, `always_on_top`, `on_close`,
`visible`, `scale` (this window's size against the global UI scale, 1.8.10). Double-click the title bar to collapse; right-click a toggle, slider,
dropdown or keybind to reset it.

**Widgets** (every call returns its value; most take an `opts` with `persist`,
`disabled`, `tooltip`):

```lua
ui:text(s, { size =, color =, align =, wrap = })   ui:heading(s)   ui:live(fn)
ui:separator(label?)   ui:spacer(h)   ui:key_value(k, v)   ui:badge(s, tone)
ui:button(id, label, { style = "primary"|"danger"|"ghost"|"success", icon = ref })  -> clicked
ui:icon_button(id, ref, { size =, label = })  -> clicked
ui:toggle(id, label, default)   ui:checkbox(id, label, default)  -> value, changed
ui:slider(id, label, lo, hi, default, { step =, integer =, suffix =, format = })  -> value, changed
ui:dropdown(id, label, options, default)  -> index, changed   (a pick from the list: changed on the next call, 1.8.1)
ui:tabs(id, options, default)  -> index
ui:text_input(id, label, default, { placeholder =, max_len =, numeric =, password = })  -> text, submitted
ui:code(id, default, { rows =, words =, error_line =, error =, line_numbers =, disabled = })  -> text, changed, focused
ui:keybind(id, label, default_vk, { mode = "hold"|"toggle", ctrl =, shift =, alt = })  -> active, vk
ui:color(id, label, { r, g, b, a })  -> rgba table, colour object
ui:progress(fraction, { text =, color = })   ui:bar(label, fraction, { color =, text = })
ui:image(ref, w, h, { fit =, tint = })   ui:icon(ref, size)   ui:spell_icon(spell_id, size)
ui:spell_row(spell_ids, size, { highlight =, cooldowns = })
ui:list(id, items, { h =, icons = })  -> selected, clicked, double_clicked
ui:table(id, columns, rows, { h =, sort = true })  -> selected, clicked
ui:tree(id, label, default_open) ... ui:end_tree()
ui:group(id, title, { collapsible =, default_open = }) ... ui:end_group()   -- ALWAYS end
ui:row({ 0.5, 0.5 }) ... ui:end_row()   ui:columns(3)   ui:skip()   ui:indent()/unindent()
ui:scroll(id, h) ... ui:end_scroll()        -- the wheel, a draggable bar, a press on the track (1.8.9)
ui:avail()  -> x, y, w, h_left   ui:metrics()  -> { pad, gap, row, title_h, scrollbar, font_small, font_body }
ui:unit_frame(unit, { level =, power = })   ui:player_frame()
ui:context_menu(id, items)  -> chosen        -- right-click on the last widget
ui:tooltip(s)   ui:hovered()   ui:right_clicked()   ui:last_rect()   ui:mouse()
ui:custom(id, h, function(canvas) canvas:fill(...) canvas:text(...) end)  -> hovered, clicked
ui:raw(h, function(x, y, w, h) core.graphics.rect_2d(...) end)   -- legacy paint code, in place
```

**A dropdown's list is a popup (1.8.1).** The toolkit runs the list at the end of the frame, after `ui:dropdown` has returned, so a row picked from it is reported on the NEXT call: as `changed`, and over anything the caller set in between with `ui:set`. A window that mirrors a setting can therefore set the widget from the setting before every draw and write back on `changed`. Before 1.8.1 a pick from the list never said `changed` (only the wheel and a right click did), so such a window put the old value straight back, and so did `menu_dropdown` and the combobox mirrors. Jambix AIO's class window hit it with its pet mode and pick lists. Test: `jcore_boot_test` ("a pick from the list is reported changed...").

**A code box (1.8.7).** `ui:code` is a multi-line text field for code: Enter breaks the line and keeps its indent, Tab puts in four spaces, the arrows walk the lines, Backspace and Delete join them, Ctrl+A / C / X / V, Escape lets go. Lua is coloured, and so are the names in `words` (an API the code calls). `error_line` marks a line red and `error` writes the message under the box; `disabled` makes a read-only view. One string in and out, like `text_input`: set it from your model before the call and write back on `changed`. Jambix AIO's Reactions window is the first user. Test: `jcore_boot_test` ("code box: ...").

**Panes that fill a resizable window (1.8.9).**
- `ui:avail()` says where the next widget goes and how much room is left below it, down to the bottom of the enclosing scroll region or window body. A window with `resizable = true, scroll = false` can split its body into panes that always fill it: a row of `ui:scroll` regions, each `select(4, ui:avail())` tall, with fixed bars above or below a region that takes what is left.
- A scroll region's bar can be dragged, and a press on its track jumps there. The bar takes the press before the content does.
- The wheel goes to what is under the cursor inside the region first: a code box, a list, a nested region. The region scrolls only when nothing inside took the wheel.
- A widget inside a region is stored under the region's path: `ui:set(window, "body/search", v)` for a `search` field in region `body`.
- A resizable window is never bigger than the screen, nor smaller than its `min_w` / `min_h`.
- Jambix AIO's Reactions window (1.77.0) is built this way. Test: `jcore_boot_test` ("scroll region: ...").

**A window's own scale (1.8.10).**
- `scale = 1.25` in a window's options draws everything in it at the global *UI scale* times 1.25: its title bar, padding, widgets and text, the lists its dropdowns open, and its tooltips. Other windows keep the global scale.
- A window can offer its own text size this way without moving everyone else's.
- `ui:metrics().scale` is the scale in force where it is asked, and a number given as a text size (`size = 15`, `canvas:text(s, x, y, col, 15)`) follows it.
- A `ui:custom` painter is in pixels: multiply its offsets by `ui:metrics().scale` (or draw through a wrapper that does), or its boxes stay one size while the text in them grows.
- Test: `jcore_boot_test` ("a window's own scale: ...").

Frame-level surfaces, from anywhere:

```lua
JCore.ui.toast("Saved", { kind = "success", title = "Profile", duration = 3, icon = "spell:2061" })
JCore.ui.confirm({ title = "Reset?", body = "Cannot be undone.", tone = "danger", on_confirm = fn })
JCore.ui.set_theme({ accent = my_color, font = { body = 14 } })   JCore.ui.set_scale(1.2)
JCore.ui.reset_layout()   JCore.ui.windows()   JCore.ui.is_cursor_over_ui()
ui:show("hud") / ui:hide("hud") / ui:toggle("hud")   ui:get("hud", "auto")   ui:set("hud", "auto", false)
```

**Shader-drawn shapes (1.10.0).** Where the loader has them, windows draw
some shapes with its `core.graphics.render_*` calls, each one shape from one
SDF pixel shader:

- Window and popup shadows: `render_drop_shadow`, 10 px soft and 4 px down, instead of a hard copy of the window 2 by 3 px off.
- Title bars, labelled separators and switches that are on: `render_linear_gradient`. A labelled separator becomes a plate fading out to the right, with an accent underline.
- Hovered switch and checkbox rows: `render_hover_pill`, eased in and out. Slider tracks: `render_slider_track`. Dropdown fields: `render_dropdown_field`.
- "Shader drawing" on the JCore/UI page (or `JCore.ui.settings.shaders = false`; since 1.11.0 it covers `ring_3d` too) turns them off: the plain shapes from 1.9. A client without one of the calls gets the plain shape for that call alone. A call that raises is warned about once and not used again until a reload.
- Colours come from theme keys `shadow_soft`, `title_glow`, `accent_lo`, `accent_hi`, `pill`, `streak`, `header` and `clear`. They are set by hand, not derived from `accent`, so a theme that changes `accent` should set them too.
- Widget code can ask `JCore.ui.shader("render_slider_track")` and draw with `ui.paint.shadow`, `.gradient`, `.pill`, `.slider_track` and `.field`.
- Not yet seen in-game: the drop shadow's quad is passed as the window grown by the blur plus the offset on every side, with the window's own size as `element_w`/`element_h`. If the shadow looks too large or cut off, that is the first thing to adjust (`OP_SHADOW` in `replay`).
- Test: `jcore_ui_shader_test`.

**Every kind of plugin code lands on the same windows.** Four fronts, all in
`services/ui_compat.lua`:

```lua
-- Declarative: a spec table, values read back by id.
local win = ctx.ui:declare({
    id = "panel", title = "Panel", anchor = "bottom-left", x = 20, y = 20,
    content = {
        { "heading", nil, "Session" },
        { "toggle", "auto", "Auto mode", true, on_change = function(v) end },
        { "slider", "range", "Range", 30, min = 5, max = 40 },
        { kind = "row", widths = { 0.5, 0.5 }, children = {
            { "button", "start", "Start", on_click = function() end },
            { "button", "stop", "Stop" },
        } },
        { kind = "live", fn = function() return "kills: " .. kills end },
        { "bind", ctx.menu(), "enabled", "Enabled" },     -- mirrors a menu setting
    },
})
win.get("auto")

-- Menu mirrors: the HUD edits the same value the settings page shows.
ui:menu_toggle(menu, "enabled", "Enabled")
ui:menu_slider(menu, "range", "Range", 5, 40)
ui:menu_dropdown(menu, "mode", "Mode", { "Single", "AoE" })
ui:menu_keybind(menu, "burst", "Burst")           -- read-only pill with live state
ui:menu_mirror(menu, { "enabled", { id = "range", lo = 5, hi = 40 } })

-- Native core.menu elements, rendered here and written back through their setters.
ui:native(my_checkbox, "Enable")   ui:native(my_slider, "Range", { lo = 0, hi = 100 })

-- Legacy simple_ui-shaped menus: change the require, keep the code.
local m = ctx.ui:legacy_menu("Old Panel", 300, 400, "old_panel")
local cb = m:add_checkbox("Enable", 0, 0, true, function(self, on) end)
m:add_slider("Range", 0, 0, 0, 100, 40)
cb:get_value()
```

**Input rules.** Hover goes to the topmost window under the cursor by last
frame's rectangles, so a widget in a covered window never reacts. The mouse is
captured from the game only while over a window (`capture_mouse = false` on a
window makes it click-through) and released the moment it leaves; the keyboard
only while a text field or key capture has focus. Nothing reacts while the
client's own menu owns the cursor or its chat box has the keyboard. The
**JCore > UI** page has opacity, scale, window locking, capture, *Draw over
the game's windows* (1.8.1), a layout reset, and the toolkit's own windows: the icon browser, the asset inspector
and a widget gallery to check a build in-game.

On a fresh install only the small **JCore launcher** window is visible (top
right), with buttons for those three; close it and it stays closed, and the UI
page brings it back. A toast a couple of seconds after boot confirms the paint
path works on the build. Every other window comes from a plugin.

### Assets and icons

One reference string names any art, and `ctx.assets` finds, decodes, uploads
and caches it. Draw it with `ctx.draw.image` in world overlays or `ui:image`
in windows.

| Reference | Source |
|---|---|
| `data:icons/sword.png` | a file under scripts_data |
| `game:Interface/Icons/ClassIcon_Warrior.blp` | a file inside the client's own data archives, by game path (see below) |
| `addon:Questie/Icons/available` | a file inside an installed addon (extension optional; .blp/.tga/.png probed) |
| `wow:_retail_/Interface/AddOns/X/y.tga` | any file under the WoW install |
| `icon:spell_holy_flashheal`, `Interface\\Icons\\Spell_Holy_FlashHeal` | a game icon by name, from Wowhead's CDN, disk-cached |
| `spell:2061`, `item:6948` | resolved to the icon name by Wowhead's tooltip service (Forever's data first on Forever, then Classic, then live), then as above |
| `https://...` | any image on the web, disk-cached |
| `tex:<name>` | a texture you loaded yourself (`assets.register_texture`) |
| `atlas:<name>/<cell>` | one cell of a sprite sheet (`assets.atlas`) |

BLP -- the format nearly every addon icon is in, and one the native loader
does not read -- is decoded in Lua (palette, DXT1/3/5, ARGB) and wrapped as a
PNG for upload. Big textures are read at the mip level that fits the
**Max texture size** setting. All of it runs on a per-frame budget off the
update phase: a draw of an asset that is not ready yet queues it, paints
nothing and answers `false`; the next frame that asks gets the texture.

```lua
ctx.draw.image("spell:2061", pos, 24, 24)             -- world overlay, layer queue
ctx.assets.request(ref)  -> ready, entry               -- queue without drawing
ctx.assets.preload({ "spell:2061", "spell:2050" })
ctx.assets.is_ready(ref)   ctx.assets.get(ref)         -- entry: state, tex, w, h, err
ctx.assets.register("data:myplugin/logo.png", { label = "Logo", source = "myplugin" })
ctx.assets.atlas("buffs", "data:myplugin/buffs.png", { cols = 8, rows = 4 })   -- "atlas:buffs/17"
```

**The game's own files.** `ctx.casc` reads the client's CASC store -- the
archives under `Data/` that hold every texture the client draws -- with
nothing but the loader's sandboxed byte-range reads. It walks `.build.info`,
the build config, the local indices, the encoding file and the root file to
turn a game path into an archive offset, and inflates the zlib chunks in Lua
(`lib/inflate`). The root walk is the expensive step: it happens once per
client build, for every path asked for so far, and the answers are kept in
scripts_data; a later session reads a chunk and inflates it, nothing more.
Extracted bytes are kept under `scripts_data/jcore/game/`, keyed by build.
A path the client does not have is remembered as such for that build.

```lua
ctx.draw.image("game:Interface/Icons/ClassIcon_Warrior.blp", pos, 24, 24)
ctx.assets.atlas("classes", "game:Interface/Glues/CharacterCreate/UI-CharacterCreate-Classes.blp",
    { WARRIOR = { 0, 0, 0.25, 0.25 } })                 -- u0, v0, u1, v1
ctx.casc.available()  -> ok, reason      ctx.casc.build()  -> { product, key, version }
ctx.casc.want(path)                      -- register ahead, so one root scan answers many
ctx.casc.lookup(path)                    -- entry, false (not in this build), or nil (not asked yet)
ctx.casc.read(path, step)                -- bytes; heavy, meant for the asset pump's coroutine
ctx.casc.stats()
```

Encrypted chunks are not supported (no key ring), and neither are the
pre-CASC MPQ clients. Both answer with a reason, never a stall.

**In the game, the archives cannot be read** (answered 2026-10-02). The
loader's file sandbox is the **client folder** (`_classic_era_`, where the
game's exe is), not the install root above it where `.build.info` and
`Data/` live. The evidence, from the diagnosis below after one session on
Classic Era: addon files load as `Interface/AddOns/...` with no client
folder in front, the client folder is detected as the sandbox root (`""`),
and `.build.info`, `../.build.info`, `./.build.info` and every `Data/`
path answer size 0 and unreadable while the install's `.build.info` exists.
So the reader works in the offline harness only, and every `game:` reference
has to have a stand-in. Since 1.5.3 a `game:` reference fails **for good**
when the archives cannot be opened, with one line for all of them: it used
to be retried on the backoff for the whole session, and each retry put it
back to "loading", which blanked every mark drawing it for a frame. Since
1.8.3 that is no warning. The reader says why once, at info, and only at
debug when the reason is the one the last session saved. The assets'
"falls back to its stand-in" line is debug.

**Icon names** (1.8.3). A `spell:` or `item:` reference is resolved
through Wowhead's tooltip service, data environment 16 (Forever), 4
(Classic) and 1 (live), in the order the client wants. Only 16 knows
Forever's own spells. The loader's `icons_helper` is no longer asked: it
reads www.wowhead.com, which refuses it with 403 and an `[ERR]` line per
spell. An id no environment knows fails for good, without a warning. One
that could not be fetched is retried on the backoff.

**Where the install root is, and why it will not open** (1.5.2). Every path
the reader asks for is relative to the install root. If `.build.info` will
not open there, the reader tries `../`, `./` and `<client folder>/../` in
turn, and uses the first one that works for every read after that
(`stats().root`). If none of them works, or the build config will not open,
the reason is saved once per session in the reader's store,
`scripts_data/jcore/jcore.casc.json`, under `diagnosis`: the error, the
client folder, the game version, and the probe paths, each with the size the
loader reports and whether the loader will read it. The diagnosis is cleared
once the archives open. `ctx.casc.diagnosis()` returns it.

**Importing from addons.** The loader cannot list the game folder, so an
addon's textures are found the way the client finds them: read its .toc, walk
the Lua and XML it lists, collect every `Interface\\AddOns\\...` path that
exists on disk, and map every `Interface\\Icons\\...` mention to its Wowhead
icon. The result is a persistent **catalog** the icon browser shows and any
plugin can query.

```lua
ctx.assets.scan_addon("Questie", { force = false }, function(result, err) end)
ctx.assets.scan_installed(function(names) end)   -- probes a known list of addons
ctx.assets.scan_data("icons", function(result) end)   -- images under scripts_data/icons
ctx.assets.catalog({ source = "Questie", text = "quest", limit = 50 })  -> { { ref, label, source, kind } }
ctx.assets.sources()   ctx.assets.addon_catalog("Questie")   ctx.assets.flavor()
ctx.assets.product()   -- the client folder's Battle.net product, e.g. "wow_classic_era"
```

The client folder under the install (`_classic_era_`, `_retail_`, ...) is
detected by probing for a config file. **The running client's own folders are
probed first** (1.5.1), by `core.get_game_version`: Vanilla
`_classic_era_`; TBC `_anniversary_` then `_classic_`; Wrath and Mists
`_classic_`; Retail `_retail_` and its test realms. An install with several
clients has a config file in each, and the fixed list alone handed Retail the
Era folder -- its AddOns, its archives, its art. A private server, whose
folder may be its own, falls through to the fixed list, first match wins.

On **Forever** a step is added in front of that probe, because the list
cannot know Forever's folder, and when Forever shares an install root with Era,
Era's folder would win the probe. The candidates are the known folders, one
per `.build.info` product row (`wow_classic_era` lives in `_classic_era_`;
`wow`, `wowt` and `wowxptr` are the exceptions), and any folder Battle.net's
`.product.db` names. The first one with a `WTF/Config.wtf` whose
`.flavor.info` names a product that is not an older client's is taken. CASC
opens that product's build; the known folders keep their fixed product table.
On every other client none of these files is read. Set the folder on the
**JCore > UI** page when none of that works out.

---

## Teardown

```lua
ctx.set_enabled(false)   -- pause: jobs stop, registrations survive
ctx.unregister()         -- full teardown
```

Events, scheduler jobs, timers, draw submissions, overlay windows, control
leases and reactions (1.8.0) are all dropped for you. `on_unload` is only for
state the core does not own.

---

## Diagnostics

The **Core** menu page shows live per-phase and per-plugin frame cost, the
plugin list with dependency and error state, unit-cache counters and draw
counters, plus controls for log level, update budget and unit-cache range.

`JCore.diagnostics()` returns all of it as a table — the right thing to dump
into a log when someone reports a frame-time problem. It now carries a row per
service plus `caches` and `cache_rows`, which is where to look first when a
frame-time problem turns out to be a cache that never hits.

---

## Speed

The rule this runtime is built on: **a native round trip costs orders of
magnitude more than a table lookup.** Nothing here is slow because of Lua.

Three lifetimes cover every fact:

| Scope | Valid for | Used for |
|---|---|---|
| `tick` | the current update | health, position, cooldowns, casting state — anything the game can change between frames |
| `ttl` | N seconds | facts with no event to hang off: whether an addon is loaded, what is in a vendor window |
| `manual` | until invalidated | static data, and anything with a real event: spell names, the bag index, map names |

What that buys, concretely:

- A priority list asking the player's health nine times makes **one** call.
- `count_enemies_within(8)` makes **zero** — it reads the coordinate arrays the
  sweep already built.
- Checking line of sight on one target for six spells casts **one** ray.
- `ctx.inventory.has(id)` is a table lookup; the bags are walked on
  `BAG_UPDATE`, not per frame.
- Two plugins requesting the same URL in the same second open **one**
  connection.

A tick-scoped cache does not stamp its entries. It stamps itself and drops the
whole table on the first access of a new tick, so a hit is two table lookups and
an integer compare — a cache that costs more than the call it replaces is a
pessimisation with extra steps.

If you are writing a service of your own, `ctx` does not expose `cache`, but
`JCore.cache` does: `cache.new(name, { scope = "tick" })` then `c:fetch(key, fn,
a, b)`. Pass the arguments through rather than closing over them; a closure per
call allocates, and this is rotation code.

**What the sweep already knows is not asked again** (1.5.3). A unit in this
tick's sweep was valid this frame, and its guid, position and death are on its
row (`units.snapshot`). The draw helpers (`unit_w2s`, `unit_head`, the
boxes, `unit_los`, `unit_color`), `combat.time_to_die` and the time-to-die
poll read them there instead of calling `is_valid`, `get_guid` and
`get_position` again for every mark; the sweep asks `is_dead` once per unit
and keeps the answer, where it used to ask twice and `units.is_dead` a third
time. The asset registry reads the clock once per tick, not on every
`request` of every icon. Measured in `aio_esp_perf_test`, a crowd of
fifty-odd units with the Jambix AIO overlay on: 2,124 calls into the client
per frame before, 1,172 after.

**Each core stage fails on its own** (1.5.3). The per-tick stages -- the
sweep, spells, combat, enemies, threat, input, missiles, nav, walkmap -- each run under
their own guard. One that throws is logged (the first time, then every
600th) and skipped for that tick; the stages after it still run, and the
jobs that carry them never fail, so the scheduler never pauses them. Before,
one stage throwing skipped every stage after it, lease expiry among them, and
five in a row paused the job for up to 30 seconds -- with the cache epoch, so
every tick-scoped answer froze. The cast lanes are handed out at the start of
a decision, so a decision that throws keeps nothing for the next tick, and a
request whose priority is not a number is given the rotation's.

The per-guid draw caches (projection, attachment, head, height, line of
sight) are emptied together every 600 frames; the projection cache used to
be kept for the session.

Two things are **not** cached, deliberately. Actions never are — caching a
second call to a mutator would swallow it silently. And the clocks
(`core.time`, `game_time`, `delta_time`, `cpu_time`) are passed through raw on
`ctx.bridge.client`, because a memoised clock hands the same instant to
everyone for a whole frame, which is right for a game fact and useless for
measuring how long something took.

---

## Layout

```
jcore/
  header.lua              package manifest (name/version/author/load)
  main.lua                boot; the ONLY file that touches core.register_*
  api.lua                 builds the context handle and the public table
  lib/
    util.lua              helpers; stable sort, ring buffer, version parsing
    json.lua              encode/decode, for HTTP and storage
    log.lua               namespaced logging, per-call-site rate limiting
    cache.lua             the memoisation layer every service reads through
    events.lua            the bus; priorities, quarantine, owner tagging
    scheduler.lua         phase fan-out, throttling, budget, cost attribution
    registry.lua          registration, dependencies, lifecycle
    menu_ns.lua           per-plugin menu slice
    image.lua             BLP and TGA decoders, PNG encoder (leaf)
    inflate.lua           zlib/DEFLATE decoder, pure Lua (leaf)
  services/
    units.lua             the shared object-manager sweep and its snapshot
    spells.lua            spell metadata, cached per tick
    cast.lua              cast arbitration
    combat.lua            combat state, derived events, time-to-die
    enemies.lua           every hostile with a memory: motion, cast, target, activity
    threat.lua            the group's threat on every mob in the fight, ranked
    draw.lua              layer batching, w2s cache, theme
    player.lua            the local player, one read per fact per tick
    world.lua             zone, instance, keystone, encounters, client facts
    group.lua             party, raid, arena; roles built in one pass
    inventory.lua         bags indexed by item id, rebuilt on BAG_UPDATE
    geometry.lua          line of sight, terrain, cones, vector maths
    missiles.lua          projectiles in flight and time to impact
    addons.lua            BigWigs, ExBoss, Details, MDT, TSM and the rest
    input.lua             leased movement/facing/targeting, world actions
    nav.lua               Sentinel pathing, behind the movement lease
    walkmap.lua           the yard-by-yard map round the player; routes and a walker on it
    net.lua               HTTP with caching, dedupe and a concurrency cap
    storage.lua           files and self-saving stores
    bridge.lua            every remaining core.* namespace, guarded
    creatures.lua         Forever only: the client's own creature cache (names, titles, rank, quest drops)
    names.lua             what a unit is called, per client (Forever: learned, kept, the cache)
    loot.lua              whose mob it is, what fought us, whether a corpse is ours; the loot window
    power.lua             Forever: energy, rage, combo points counted while the read says 0
    react.lua             the reaction framework: rules as data, scored per lane, a memory and a journal; one engine per plugin (ctx.react)
    questdb.lua           our own quest database (from QuestieDB), and Questie's bridge calls from it
    casc.lua              the client's own data archives: build, indices, encoding, root, BLTE
    assets.lua            icons and textures from the game, addons, data files, the web; the catalog
    ui.lua                overlay windows: input, layout, paint list, core widgets
    ui_widgets.lua        dropdown, tabs, text input, keybind, colour, list, table, toasts, modal
    ui_compat.lua         declarative specs, legacy simple_ui menus, menu and native mirrors
    ui_builtin.lua        the UI settings page, icon browser, asset inspector, widget gallery
  examples/
    jcore_example_plugin/ a complete working consumer
```

Modules are factories (`function(rt) ... return M end`) wired in `main.lua`.
The order of the `build_module` calls there **is** the dependency graph: each
module reads the ones above it off `rt` and none reads one below it. Adding a
service means adding a file and one line in that list.

---

## Gotchas worth knowing

- `core.cpu_time()` answers **nanoseconds**, not seconds. Getting this wrong is
  silent — the budget comparison still runs, it just always trips.
- `buff.expire_time` is **engine time in milliseconds**, the same base as
  `core.game_time()`. Subtract first, then convert.
- `core.time()` is the wall clock and keeps running through a loading screen;
  `core.game_time()` does not. The runtime schedules on `core.time()`.
- 2D graphics calls want a real `vec2`. A plain `{ x =, y = }` table has the
  right fields but is not the same type.
- `core.graphics.is_menu_open` is replaced at boot by the Lua menu host. Read it
  live; a module-scope cache keeps the wrong native one for the whole session.
- `ui:end_window`, `ui:end_group`, `ui:end_row` and `ui:end_scroll` are **always**
  called, whatever their begin returned. A body that raises is unwound by the
  core at the end of the frame, but a missing end in normal flow shifts every
  widget after it.
- A widget's `id` is its state key **within the window**. Two widgets with one
  id in one window share a value; the same id in two windows does not.
- `core.graphics.load_texture` reads PNG, JPEG, BMP, GIF and TGA. It does not
  read BLP; the asset registry converts those, at the cost of one decode per
  texture per session.
- `get_spell_cast_time` answers **milliseconds**. Everything on `ctx` speaks
  seconds; the conversion happens once, in `spells.info`.
- A game event's `args` array leaves a **hole** for a nil argument, so index it
  positionally and never use `ipairs` or `#` on it.
- JSON `null` cannot decode to `nil` — `{"a": null}` and `{}` would become the
  same table. It decodes to `JCore.json.null`; compare against that, or call
  `json.strip_nulls` when the difference does not matter.
- A multiple return splices itself into an argument list. That is why the unit
  pickers return one value, and it is worth remembering before adding a second
  return to anything a caller might write inline.
- `return ok and value or nil` after a `pcall` is wrong whenever the value can
  legitimately be `false` — a toggle switched off collapses to `nil` and reads
  back as its default. Test `ok` on its own line.

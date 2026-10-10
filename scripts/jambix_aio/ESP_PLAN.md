# ESP — build-out plan

> **Status: phases 1 and 2 are done.** The overlay is now the pipeline
> described in §1, and the primitives in §2 are in JCore. What shipped:
>
> - `modules/esp/` — `classify`, `collect`, `elements`, `panels`, `init`.
>   `esp_units.lua` is gone; `modules/world.lua` kept only the automation half.
> - One walk of units *and* objects per frame, distance-sorted, with detail
>   tiers and three budgets (marks, draw calls, detail reads) on an ESP →
>   Performance page with live counters.
> - Marks are rows in `cfg.ELEMENTS` plus a drawer in `esp/elements.lua`. The
>   menu builds its toggles from the same table.
> - JCore's draw service gained measuring, backdropped text, corner and 3D
>   boxes, segmented bars, arcs, cones, polygons, 2D circles and arrows,
>   off-screen edge indicators, clipped panels, spell icons and textures,
>   cached attachment points, rationed line-of-sight, notifications, and a
>   droppable-submission budget.
> - Two marks that came free with the new primitives: off-screen threat arrows
>   and threat notifications, both off by default.
>
> Defaults were chosen to keep the overlay looking the way it did, with one
> deliberate exception: detail falloff is ON, so health bars and tracers stop
> at 90 yards. Everything else is "no limit" until you say otherwise.
>
> **Part of phase 3 landed next, out of order, because it was asked for:**
>
> - **Quest attribution.** A quest index built from the quest log (names and
>   live x/y progress, no addon needed), Questie's database (npc ids, the mobs
>   that drop a quest item, quest givers and turn-in npcs) and RestedXP (what
>   the guide wants next). Every quest mark now names its quest and shows that
>   objective's progress, one line per quest, in that quest's own colour.
> - **Quest paths.** A dashed ground path to the nearest target of each quest,
>   plus every stop in the guide's step instead of only the current one.
> - **Reaction and difficulty colouring.** Plain categories are coloured red /
>   yellow / green by reaction (default) or by the game's five level bands.
>   Rares, bosses, quest and guide targets keep their category colour.
> - **Health on the mark**, as a percentage or exact numbers, and an optional
>   hostile / neutral / friendly word.
> - `draw.path_3d`, with world-space dashes, and a ground-sampling fix: heights
>   are probed three times and accepted only when they continue the previous
>   height, which is what stops marks sitting on tent roofs.
>
> **The rest of phase 3 landed in 1.27.0:**
>
> - **Cast bar** under the health bar: spell icon, name, seconds left, white
>   when interruptible and red when not, draining for a channel. Only while
>   casting, so the stack grows upward by two rows when a cast starts.
> - **Status line**: crowd control and its time left, `on you`, `on your pet`,
>   `on <party member>`, `tapped`, `in combat`, `mounted`, one line coloured
>   by the most urgent.
> - **Targeting you**: a red ring at the feet of anything on you, and a line
>   from every attacker to you, your pet or a party member while it is still
>   more than six yards away. Neither is droppable.
> - **Tapped grey** over every colour, **raid markers** from the client's own
>   icons (verified in the 1.15.9 archives), **box styles** (corners, full, 3D),
>   and a `you` tag plus on-you-first ordering in the threat panel.
>
> **The cost question §1 worried about did not arise.** JCore's enemies service
> (built after this plan was written) already reads cast, target, combat and loss
> of control for every attackable unit, every tick, for the rotation. The ESP
> reads those rows rather than the unit, so a hostile's fight marks cost no
> native call. The ESP's own rationed read is now only the fallback for units
> that service filters out. Tapped, marker and mounted ride classify's jittered
> two-second refresh.
>
> **Not done: the full aura row** (§3 item 5). Crowd control, the part of it
> that changes a decision, comes free through loss of control. A row of buff and
> debuff icons would mean `get_auras` per unit, the cost this plan says is
> unmeasured, so it waits for a measurement.

Where the overlay is today, what the loader's API actually allows, and the
order to close the gap.

Today the overlay is **one file** (`modules/esp_units.lua`, ~380 lines) plus the
world-object half of `modules/world.lua`. It draws four things — box, health
bar, label, optional tracer — across 14 categories, and alerts on two of them.
Everything it draws comes from six `game_object` getters.

The `game_object` contract exposes roughly **90** getters. `core.graphics`
exposes **30+** primitives, of which the draw service wraps 9. None of the map,
missile, attachment, line-of-sight, notification or image calls are used at
all. The headroom is not incremental.

---

## 0. The constraint that shapes everything

Every mark is submitted to JCore's draw queue; one walk of the core's unit list
per frame; no direct `core.graphics` calls; no widening of the shared unit
cache. That is what keeps this plugin cheap next to a rotation. **Every item
below has to stay inside it**, which rules out the obvious way to add features
(another pass, another native call per unit per frame) and dictates the
architecture in §1.

Budget target: **≤ 2 ms/frame** at 60 visible entities with everything on, and
zero native calls for a mark that is toggled off.

---

## 1. Architecture: from a pass to a pipeline

`esp_units.render` is a single loop whose body knows about every mark type. Add
twenty options to it and it becomes unreadable *and* pays for marks nobody
enabled. Split it:

```
modules/esp/
  collect.lua    one walk -> frame-local entity list (units AND objects),
                 classified, distance-sorted, LOD-tagged, capped
  classify.lua   category resolution, lifted out of esp_units
  rules.lua      user watchlist engine (name / npc id / level band / aura /
                 creature type -> colour, priority, alert, element overrides)
  elements.lua   registry: { key, label, default, layer, draw(entity, view) }
  panels.lua     threat panel, nearby list, session stats
  radar.lua      2D radar + off-screen edge arrows
  map.lua        world-map and minimap overlay
  memory.lua     persistent per-map node/rare memory (scripts_data/jambix_esp_nodes)
  inspect.lua    mouseover / nearest detail card
```

The ESP page declaration stays in `main.lua`. Moving it here was the original
plan and it does not work: `P.opt` reads across every page, so the pages have
to exist before any module loads, and a menu module would have to be loaded
before the bundle it needs. The duplication that move was meant to prevent is
prevented instead by `cfg.ELEMENTS` -- the menu builds a toggle per row, this
package supplies a drawer per row, and neither can exist without the other.

`collect.lua` produces one `entity` table per drawn thing:

```lua
{ obj, guid, kind = "unit"|"object", info, category, badge,
  distance, screen, lod, flags = { targeting_me, tapped, casting, ... } }
```

Elements are pure consumers of that table. Adding a mark becomes adding one
function and one registry row — not an edit to the pass.

**LOD tiers**, assigned in `collect`:

| tier | when | drawn |
|---|---|---|
| `full` | nearest N (default 20) and < 40 yd | everything enabled |
| `mid` | on screen, within category range | box + name + bar |
| `far` | beyond LOD distance, or capped out | dot, or nothing |

**Throttled reads.** Auras, casts, threat, equipped gear and line-of-sight are
never read for the whole list. `collect` round-robins a budget (default 8
units/frame) through the `full` tier and caches with a TTL, so a 60-unit pull
costs about what a 10-unit one does.

---

## 2. Draw service: primitives to add (`jcore/services/draw.lua`)

These belong in JCore, not the plugin — every plugin gets them, and they
inherit the layer queue and the w2s cache.

| addition | native call behind it | unlocks |
|---|---|---|
| `measure(text, size)` | `get_text_width` | right-aligned rows, backdrops that fit |
| `text_bg(pos, text, col, opts)` | rect + text | labels readable over snow and lava |
| `unit_box_corners` | `rect_2d` ×4 | corner-bracket box style |
| `unit_box_3d` | `line_3d` ×12 | true 3D cube around the model |
| `arc_3d(pos, r, pct)` | `circle_3d_percentage` | cast / respawn / cooldown rings at the feet |
| `cone_3d(from, to, r, deg)` | `cone_3d` | facing cone, cleave cone, "it is looking at you" |
| `polygon_3d`, `rect_3d` | `render_polygon_3d`, `rect_3d` | ground decals, danger rectangles |
| `arrow_2d(center, angle, size)` | `triangle_2d_filled` | off-screen indicators, compass |
| `icon(tex, pos, size)` | `load_image` / `draw_image` + `assets_helper` | spell icons, class icons, node icons |
| `spell_icon(spell_id)` | `icons_helper` (Wowhead disk cache) | cast bars and aura rows with real art |
| `panel(x, y, w, rows)` | `scissor_push` / `scissor_pop` | scrollable, clipped HUD lists |
| `bar_segmented` | `rect_2d_filled` | health + absorb + incoming heal in one bar |
| `edge_indicator(world_pos)` | clamp + `arrow_2d` | anything off-screen, at the right bearing |
| `los(a, b)`, cached per frame | `is_line_of_sight` | dim or hide what you cannot see |
| `attachment(unit, id)`, cached | `get_attachment_position` | head dots, skeletons, correct label anchoring |
| `notify(id, title, body)` | `add_notification` | toast alerts that survive a busy chat frame |

Plus a per-frame **draw budget** with a stat counter, so an overloaded frame
drops `far`-tier marks instead of dropping frames.

---

## 3. Elements — the actual feature list

Each is one registry row, each gets a toggle, and each can be overridden per
category (phase 4).

### Unit marks

1. **Box styles** — full / corner brackets / 3D cube / filled tint / off.
2. **Health bar** — horizontal or vertical, absorb and incoming-heal segments,
   optional numeric `%` or `12.4k`, coloured by health, class, or threat.
3. **Power bar** — mana/rage/energy for players; tells you what a caster has left.
4. **Cast bar** — spell name, icon, time remaining, and **red when the cast is
   not interruptible, white when it is** (`is_active_spell_interruptable`), with
   a channel variant. The single highest-value missing mark.
5. **Aura row** — filtered buff/debuff icons: crowd control, immunities,
   drinking, stealth, bleeds, your own DoTs. Filter list user-editable.
6. **Target line** — from a unit to *its* target, so an incoming add is visible
   before it arrives; plus a **"targeting you"** highlight.
7. **Facing cone / arrow** — `get_rotation` + `cone_3d`; who is looking at you.
8. **Feet ring** — combat reach, level-scaled aggro radius, or a flat radius.
9. **Skeleton / head dot** — `get_attachment_position`; also fixes labels that
   currently float at a fixed pixel offset regardless of model size.
10. **Tracer origins** — bottom-centre, crosshair, or the unit's own feet, per category.
11. **Status badges** — tapped by someone else (`is_tap_denied`), phased
    (`get_unit_phase`), mounted, in combat, stealthed, guild/party membership,
    raid marker (`get_target_marker_index`).
12. **Difficulty colouring** — grey/green/yellow/orange/red by level delta, the
    way the game colours a nameplate, instead of one flat colour per category.
13. **Corpse detail** — `[loot]` / `[skin]` exist; add "already looted",
    "someone else's tap", and a fade as it despawns.

### World marks

14. **Node memory** — persist every node seen, per map (the format already sitting
    in `scripts_data/jambix_esp_nodes/1411.txt`), and draw remembered-but-absent
    nodes as ghosts with an estimated respawn clock. Turns a gathering route into
    a map instead of a 120-yard bubble.
15. **Missile ESP** — `get_all_missiles` gives source, current and impact position
    per projectile. Draw the impact marker and the line; on a hardcore character,
    an incoming Frostbolt you can see is a Blink you actually use.
16. **Danger decals** — ground circles for dangerous casts, on the existing
    `DANGER` layer.
17. **Corpse run** — `get_corpse_position` line and distance while dead.

### Screen furniture

18. **Radar** — rotating 2D blip panel, zoom slider, per-category blips.
19. **Off-screen arrows** — edge-clamped, coloured by category, distance label.
20. **Nearby list panel** — sortable rows (distance / level / health); the threat
    panel generalised beyond threats.
21. **Inspect card** — mouseover (`get_mouse_over_object`) or nearest: level,
    classification, health, power, armour, auras, cast, its target, threat
    (`get_threat_situation`), equipped gear for players.
22. **Session stats** — units seen by category, nodes gathered, gathered/hour,
    XP/hour, alerts fired.

### Alerts (extending `alert_check`)

23. Per-category alert rules instead of the two hard-coded ones — each with its
    own range, cooldown, sound id, toast, and narrator line.
24. **First-seen rare log** — a rare you walked past three zones ago, with coords.
25. **Auto raid marker** on rares and quest targets (`place_raid_marker`), and
    `send_ping` for party play.

---

## 4. Filtering and options

Category settings today are `on` / `range` / `colour`. Extend to:

- **Per-category element mask** — bosses get box+bar+cast+auras, critters get a dot.
- **Watchlist rules** (`rules.lua`) — match on name substring, npc id, level band,
  creature type, or carried aura; produce a custom colour, priority, forced element
  set, alert. Text-input driven, one rule per line, persisted.
- **Global gates** — only in combat / only out of combat, hide in cities, hide while
  flying or on a taxi, hide dead, hide below level N, hide what you cannot see (LOS),
  cap total marks.
- **Presets** — Gathering, Hardcore PvP, Dungeon, Minimal, Everything: buttons that
  write the whole page at once, plus export/import through `settings_export`.
- **Performance page** — entity cap, LOD distances, read budget, throttle intervals,
  and a live readout of submitted / culled / painted / ms from `draw.stats()`.

---

## 5. Map overlay

`world_pos_to_map_pos_normalized`, `get_map_top_left` / `get_map_bottom_right`,
`get_world_pos_from_map_pos` and `coords_helper` are all present and unused.

- **World map** — remembered nodes, rares, quest targets, your corpse, party.
- **Minimap** — live blips for the same, respecting the ESP toggles.
- **Route hint** — nearest unvisited remembered node, as a bearing on the radar.

---

## 6. Phasing

| phase | contents | why this order |
|---|---|---|
| ~~**1. Foundation**~~ ✅ | §1 split into `modules/esp/`, entity pipeline, LOD, read budget, element registry | Nothing else is affordable until the pass stops being one loop. No user-visible change beyond frame time. |
| ~~**2. Draw primitives**~~ ✅ | §2, in JCore | Every later phase draws through these. |
| ~~**3. High-value marks**~~ ✅ | cast bars, ~~aura rows~~ (CC only), target lines, targeting-you, status badges, difficulty colours, box styles | The marks that change what you do in a fight. |
| **4. Options layer** | per-category element masks, watchlist rules, global gates, presets, performance page | Makes phase 3 usable instead of overwhelming. |
| **5. Screen furniture** | radar, off-screen arrows, nearby panel, inspect card, session stats | Depends on `panel`, `arrow_2d`, `measure`. |
| **6. World & memory** | node memory + respawn clocks, missiles, danger decals, corpse run | The gathering / hardcore payoff. |
| **7. Map overlay** | world map + minimap | Reads the phase-6 memory store. |
| **8. Alerts** | per-category rules, toasts, rare log, auto-markers | Reads everything above. |

Phases 1–2 are load-bearing; 3 onward are independently shippable and can be
reordered by taste.

---

## 7. Risks

- **Frame cost is the real enemy**, not complexity. Every phase lands with the
  Debug page's stats line showing before and after, and nothing merges that moves
  the 60-entity frame budget past 2 ms.
- **`get_buffs`, `get_attachment_position` and `is_line_of_sight` costs are
  unmeasured** on this core. Phase 1's read budget exists so that finding out they
  are expensive does not mean rewriting anything.
- **Menu id permanence** — category keys are baked into widget ids and must not be
  renamed. New per-category ids follow `<key>_<element>_on`.
- **Option sprawl** — 60 toggles with no defaults that work is a *worse* overlay
  than 4 toggles. Every phase ships with its preset entries updated, and the
  presets are the intended way in.

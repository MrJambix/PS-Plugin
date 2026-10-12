# Jambix — Central PvP Intelligence Network

> **Status, 2026-10-12.** Built and tested offline: the client adapter
> (`modules/react/intel/central.lua`, two backends: the GitHub repository
> itself, §9, or an HTTP service), the per-fight debrief that feeds it
> (`modules/react/intel/debrief.lua`), the predictor's observation hook, the
> consent controls on the Reactions page, the central service
> (`tools/fightlog_server/`: data service, learning engine, knowledge
> distribution) with its tests, and the repository's Action with its
> ingest script. **Nothing of it has run against a live
> server from a live client, and the network is not learning anything yet:
> no contributor has sent a record.** The learning engine refuses to offer a
> pattern until several contributors, enough chances and a measured
> forecast quality back it (§6), so a published model from an empty or thin
> database carries only `unreliable` entries.

## 1. Audit: what existed, what was reused

Read on 2026-10-12 before building (the PvP intelligence layer's own audit
is `PVP_INTEL_PLAN.md` §1).

| Area | What exists | Reused as |
|---|---|---|
| Prediction | `intel/predict.lua`: per-player patterns with a chance / hit / miss / attribution each, two clocks, forecasts snapshotted when a chance opens and scored at the outcome (`T.ledger`), inputs instrumented (`T.inputs`) | the **observation** record: every scored forecast is handed to the client adapter as it stood, with its outcome, evidence and input reliability (`score_forecast` → `central.observe`) |
| Data and weights | `intel/data.lua` (`PATTERNS` with `needs` and `ability`), `intel/score.lua` (`PREDICT`, `BAIT`, `DEBRIEF`, `CENTRAL`) | the pattern vocabulary the service validates against; every threshold written down |
| Reactions engine | JCore `services/react.lua` (`ctx.react`), rules as data, `W.intel` read by rules through `intel.sure` | **untouched**: no rule reads the network; the predictor's prior is the only thing a downloaded model changes, and only for a pattern with no local evidence yet |
| Tactical states, baits, control plan | `intel/states.lua`, `bait.lua`, `ccplan.lua` | the debrief reads their tick tables (states entered, baits offered, holds) for the lesson |
| Combat diagnostics | `intel/explain.lua` (summary, inputs line), the Reactions page readouts | the page section *Fight debriefs and the shared network* shows the last fight and the network's status |
| Event providers | `intel/init.lua`: `UNIT_SPELLCAST_*`, `UNIT_AURA`, the combat log on Era, our own casts, `jcore.player.died`, `jcore.combat.leave` | the debrief's inputs (what each side used, death, the end of a fight); nothing new is subscribed |
| Client handling | `ctx.world.client()` profile: `version` (Vanilla / Forever), `exact` build, capability flags | the record's `client.game` and `client.build`; the plugin version from `ctx.version` (the manifest's) |
| Networking | `core.http_get` / `core.http_post` (scripts/.api/core.lua, HTTP, 2026-10-06: asynchronous, redirects followed, a curl code on failure) wrapped by JCore `services/net.lua` (`ctx.net`: per-host pacing, a concurrency cap of 4, a queue cap of 256, callbacks delivered on the next update and pcall'ed, `get_json` / `post_json`) | every call the adapter makes |
| Persistence | JCore `services/storage.lua` (`ctx.storage.read_json` / `write_json` under `scripts_data/`) | the queue, the cached model, the contributor id, the local fight log |
| Settings | `ctx.menu` pages: toggles, buttons, live lines; `P.opt` | the consent switches and the two buttons |
| Identity | `core.get_session_jwt_token()` (a PS-signed JWT naming the PS user) | **not used**: it would identify the account; the brief forbids that. The service takes a shared client key and a random contributor id |

Nothing that existed was replaced. The predictor's local behaviour is the
same with the network off, which is the default.

## 2. Architecture

```
  Jambix client (in the game, Lua)                       Central service (Node, tools/fightlog_server)
  ─────────────────────────────────                      ────────────────────────────────────────────
  predict.lua ──forecast scored──► central.observe()     POST /v1/combat/batches ─► validate.js ─► batches.jsonl
  debrief.lua ──fight closed────► central.share()        POST /v1/lessons        ─► validate.js ─► lessons.jsonl
        │                              │                 POST /v1/privacy/delete ─► records under the id removed
        │                   queue on disk (bounded,
        │                   retried with backoff,        learn.js: aggregate ─► evaluate ─► mark unreliable
        │                   one in flight, consent)            │
        ▼                              │                 publish ─► models/vN.json + manifest (active / withdrawn)
  the Reactions page ◄── status ───────┘                       │
  (consent, buttons, lines)                              GET /v1/models/manifest, /v1/models/{v}
                                       ◄── cached model ─┘   GET /v1/knowledge/matchups, /abilities, /v1/client/status
  predict.lua prior ◄── central.prior_for() (reliable entries only, enough fights, compatible, active)
```

- **Jambix client** (`central.lua`): collects (`observe`, `share`), validates
  locally (bounds, no names: `anonymise` in the debrief's record, names
  replaced in diagnostics), keeps the local prediction memory untouched,
  queues, uploads with consent, downloads with consent.
- **Central Data Service** (`server.js` + `validate.js`): the shared client
  key, record validation with the reason, forbidden fields refused, size
  and rate limits, dedupe by record id, JSONL storage with the schema
  version, retention, deletion by contributor id.
- **Global Learning Engine** (`learn.js`): per opponent class and pattern
  the rate, the chances, the fights, the contributors, the forecast quality
  (Brier) and the share of chances with verified inputs; `unreliable` with
  `why` when a threshold fails; matchup outcomes and the lesson codes that
  told won fights from lost ones; abilities per fight; an evaluation per
  pattern with calibration bands.
- **Knowledge Distribution** (`server.js`): numbered model versions with a
  manifest (`schema`, `min_plugin`, `status` active or withdrawn),
  `withdraw` as rollback (the previous active stands), 410 for a withdrawn
  model, a client status route that says whether this plugin and schema
  are accepted.

## 3. The data model

**Observation** (one per forecast scored; a batch per fight):
`pattern`, `enemy_class`, `p` (the forecast as it stood), `reliability`
(the evidence behind it), `sure`, `basis` (recent / session), `evidence`
(weighted chances), `inputs_ok` (every input a miss rests on was seen live
this session), `hit`, `correct`, `t` (seconds into the fight), `context`
{ `mode`, `threat`, `me_hp` as a band 0..4, `controlled` }.

**Batch**: `schema`, `id`, `fight`, `contributor`, `client` { `plugin`,
`game`, `build` }, `me` { `class`, `level` }, `encounter` { `type`,
`duration`, `outcome` }, `observations[]`, `censored` (why some were
dropped: "buffer full"), `diagnostics` (only with *extra detail* on:
moments with names replaced, states, the threat's peak).

**Lesson** (one per fight): the same head; `enemies[]` { `class`, `role`,
`level`, `used` (ability name → count), `controls_on_me`, `bursts`,
`trinket`, `hp_min`, `died`, `fled`, `time_on_me`, `patterns` (this
fight's counts) }, `lessons[]` (codes), `predictions` { `forecasts`,
`right`, `brier` }, `baits`, `holds`, `threat_peak`.

**Never**: names, account, character, chat, realm, addresses. The client
never puts them in; `validate.js` refuses any record with such a key
anywhere (`forbidden field batch.me.name`); the service stores no
address with a record. The contributor id is random, 24 hex characters,
made once on the machine and replaced on request: a pseudonym, which the
page says in so many words.

The local fight log (`scripts_data/jambix.aio.fights.json`) is the
player's own file and keeps the opponents' names; it never leaves the
machine.

## 4. The service's interfaces

`tools/fightlog_server/README.md` lists them. In short, under
`X-Jambix-Key`: `POST /v1/combat/batches`, `POST /v1/lessons`,
`GET /v1/models/manifest`, `GET /v1/models/{version}`,
`GET /v1/knowledge/matchups`, `GET /v1/knowledge/abilities`,
`GET /v1/client/status`, `POST /v1/privacy/delete`; under
`X-Jambix-Admin`: publish, withdraw, evaluate. Bodies to 256 KB, 60
requests a minute per contributor and per address, schema 1 only, TLS by
the reverse proxy in front (the service speaks plain HTTP; the loader
follows redirects and sends no Authorization header across hosts).

## 5. Local-first

- The queue lives on disk (`jambix.aio.central_queue.json`), at most 60
  items, the oldest leaving first; one item in flight; a failure waits 30 s,
  then 60, 120 ... up to 30 min, and gives up after 8 tries; a 4xx other
  than 429 drops the item at once (a record the service will never take).
- Every network call is `ctx.net`'s: asynchronous, answered on a later
  update. The predictor reads the model from the cache loaded at start;
  nothing in a combat tick waits for a request.
- With the service down, the internet gone, consent off, no address
  configured, or the net service absent in the loader, every module runs as
  it did; the status line says which it is.
- A model that is incompatible (schema, plugin range) is never adopted; a
  cached one that the manifest no longer lists active is dropped and the
  local priors stand.

## 6. Privacy and permissions

Three switches, all off until the player turns them on, and two buttons,
on the Reactions page under *Fight debriefs and the shared network*:
*Contribute my fights*, *include extra detail*, *Download the network's
learning*; *Delete queued local submissions*; *Request deletion of my
uploaded records and start a new identifier*. The section's text says what
goes up, when (queued at the end of a fight, sent between frames), what
never does, how long it is kept (the service's retention, 180 days by
default) and how to withdraw (the switch, the buttons).

**To check before shipping**: the loader's own rules on plugins that
contact servers, and the data-protection duties of whoever runs the
service for players in jurisdictions that have them (a privacy notice at
the address, deletion honoured — the route exists — and the retention
kept). Neither was checked from here.

## 7. Tests

- Client (`tools/jtest/tests/aio_intel_central_test.lua`, 6): off by
  default; the batch and the lesson sent one at a time with the key and
  the id and no name anywhere; offline — refused transport, a server
  failure with backoff, a refusal for good, a 429 — with the queue on disk
  and combat running on; the bounded queue, deleting it, the deletion
  request going first under the old id and the id replaced; downloads —
  the manifest, the newest compatible active version fetched and cached,
  schema and plugin mismatches skipped, a withdrawn cached model dropped;
  a cached model serving offline, a malformed one refused.
- Debrief (`aio_intel_debrief_test.lua`, 8): the fight record, won / lost /
  fled, the lessons, the local log, the banner, the page's lines, the
  lesson queued for the network, the status with no address or no net.
- Service (`node --test tools/fightlog_server/test.js`, 8): authorisation,
  invalid data, duplicates, body and rate limits, privacy deletion,
  versions and compatibility, the learning engine's thresholds, retention.

## 9. GitHub as the service (the user's choice, 2026-10-12)

"The database can be GitHub: MrJambix/PS-Plugin." The plugin's own
repository serves as the central service, with no server to host:

- **Up.** The client opens an issue per record on the repository
  (`POST /repos/{repo}/issues`, GitHub's REST API, version header
  2022-11-28): title `jambix-batch <id>`, `jambix-lesson <id>` or
  `jambix-delete <contributor>`, labels `jambix` and `jambix-<kind>`, the
  record as a fenced JSON block, trimmed to the body limit (a batch loses
  observations from the end and says so in `censored`). The token every
  client carries is a fine-grained personal access token for this one
  repository with **Issues: write, Contents: read, Metadata: read** and an
  expiry; it can open issues and read the repository, nothing else, and is
  rotated with a plugin update. A 403 or 429 (a rate limit) is retried; a
  422 (a bad record) is dropped. GitHub's rate limit is per token, so it is
  shared by every player: 5000 requests an hour, two per fight.
- **Filing.** `.github/workflows/jambix-central.yml` runs on each opened
  issue and every six hours: `tools/fightlog_server/github_ingest.js`
  validates each issue with the same bounds as the HTTP service
  (`validate.js`), files the accepted ones into the data branch
  (`jambix-data`: `data/batches.jsonl`, `data/lessons.jsonl`, `ids.json`
  for duplicates, `deletions.jsonl`), comments the reason on a refusal,
  closes every issue; on the schedule it publishes a model
  (`data/models/vN.json`, `manifest.json`) with `learn.js`; `withdraw N`
  by hand (Actions > Jambix central > Run workflow).
- **Down.** The client reads `data/models/manifest.json` and
  `data/models/v<N>.json` off the data branch through the contents API
  asked for raw (`Accept: application/vnd.github.raw+json`), the same
  compatibility and withdrawal rules as with the service. There is no
  status route; the manifest is the repository's word.
- **Privacy on GitHub.** The repository is private: the issues and the data
  branch are visible to its collaborators only. The records carry no
  names; the issue's author is the token's owner (the plugin author's
  account), not the player, so GitHub itself does not learn who played.
  The token is a shared secret in a shipped file
  (`modules/central_config.lua`): keep the repository private, scope the
  token as above, set an expiry, rotate.
- **Configuration.** `central_config.example.lua` shows the form
  (`github = { repo, branch, token }`); the same keys in
  `scripts_data/jambix.aio.central.json` override it on one machine. The
  real `central_config.lua` is git-ignored; `release.yml` writes it from
  the Actions secret `JAMBIX_CENTRAL_CONFIG` (the file's whole text) just
  before packing, so the token never enters the history. Without the
  secret the plugin ships with no central address and the network stays
  off. For a local pack (`tools/repack.ps1`), put the file in place by hand.

**To set it up**: (1) make the fine-grained token on the repository with
the three permissions and an expiry; (2) copy the example to the file's
text with the token and save it as the `JAMBIX_CENTRAL_CONFIG` secret
(Settings > Secrets and variables > Actions); (3) merge
`.github/workflows/jambix-central.yml` on main (it creates the
`jambix-data` branch on its first run); (4) bump the plugin's version to
release; (5) on a client, turn *Contribute my fights* and *Download the
network's learning* on, fight, and watch the repository's issues be filed
and closed; (6) after enough fights, `Run workflow` > `publish`.

Tests: `aio_intel_central_test` ("GitHub as the service", "the issue body
is kept under GitHub's limit"); `node --test
tools/fightlog_server/github_ingest.test.js` (parsing, accepted / refused /
duplicate / deletion with every issue closed, publish and withdraw).

## 10. The decision episodes (the collector brief, 2026-10-12)

"Convert participating players' PvP experiences into valid, reusable
training records." `modules/react/intel/episodes.lua` opens a bounded
window on each tactical opportunity the brief lists and closes it with a
record that answers the brief's ten questions from named sources:

| Opportunity | Opens on (observed) | Window | Tied pattern |
|---|---|---|---|
| a melee player closes the gap | a gap-closer cast or buff from a melee player (its event) | 5 s | mobility_when_slowed |
| a rogue opens on you | a rogue entering combat on you (the row) | 6 s | same_opener |
| a mage blinks | a Blink cast or buff (its event) | 4 s | — |
| an enemy's burst cooldown | a burst aura starting (polled) | 10 s | over_committing |
| you are rooted with players on you | a root on you with attackers (your auras) | 6 s | — |
| the target enters your dead zone | the zone turning dead_zone (the row) | 5 s | — |
| your pet threatens a control | the control plan's pet recall (the row) | 4 s | — |
| a kill window opens | its health under 25% (the row) | 8 s | — |
| the opponent changes its defence | a defensive aura (polled); or the predictor's *adapting* (inferred, flagged) | 6 s | defensive_threshold |
| several players on you | attackers rising to two (the row) | 8 s | — |

**The record**: `before` (your health, power, control, zone and gap,
movement, defensives / escapes / controls / slows ready, the threat as the
previous tick read it -- before the behaviour, not with it -- attackers,
the tactical state, the move, the bait, the hold, the pet; the player's
health, distance, burst, defensive, control), `trigger` (text, source,
observed), `prediction` (the tied pattern's rate, evidence, sure, inputs as
they stood), `recommendation` (the state's first action, the move, the
bait, the hold, as they stood), `actions` (your casts with targets),
`moved`, `events` (bounded), `after`, and the three outcomes.

**Outcomes, by written rule** (`episodes.lua` judge_*; the thresholds in
`score.lua EPISODES`):
- prediction: HIT / MISS by the tied pattern's consequence in the window
  (melee reached; a second burst; the opener matching; the defensive within
  15% of the predicted health); CENSORED when the window was cut; INVALID
  when the pattern's inputs were not live or the trigger was inferred;
  NONE when no pattern is tied or none stood.
- recommendation: a spell named → FOLLOWED if cast, NOT_FOLLOWED if it was
  ready and not cast, UNKNOWN if not ready or unknown; "no damage on it" /
  a hold → by the casts at that player; "shoot another" → by a cast at
  another; a move → FOLLOWED if you moved and the gap grew 5 yd (UNKNOWN
  when movement is not read); else UNKNOWN with the reason.
- result: SURVIVAL_IMPROVED, POSITION_IMPROVED, CONTROL_SUCCESSFUL,
  DAMAGE_OPPORTUNITY_CREATED, COOLDOWN_SAVED, OBJECTIVE_PROGRESS,
  SITUATION_WORSENED, NO_MEASURABLE_CHANGE, UNKNOWN -- each by the rule
  written at `score.lua EPISODES`, the primary and every one that applies,
  the measure in `why`. A worsening alongside an improvement is the primary.

**Contamination**: a duplicate trigger (same type and player within 3 s)
opens nothing and is counted; an inferred trigger flags `unattributed` and
makes the prediction INVALID; a pattern whose inputs were never seen live
flags `feeds_missing` and INVALID; a window cut (the player gone, you dead,
the fight over) is CENSORED, its result UNKNOWN, flagged `incomplete`; a
result that would rest on inferred data flags `guess_only` and reads
UNKNOWN; under the test harness every episode carries `test_data`, the
network client refuses to queue the fight, and the service refuses any
record carrying it. Upload duplicates are caught by the record id.

**Lessons**: each closed episode carries a candidate worded from the type,
the recommendation's outcome and the result, with a confidence from the
comparable episodes (same type and class) of the session -- `candidate`
under three, `contested` when fewer than 60% share the result, then low /
moderate / high by count. The fight's summary (the debrief record, the
page, the batch) deduplicates them per type, class and result and keeps
the latest. The service's learning engine validates an episode lesson
only with enough measured episodes from enough contributors agreeing
(`learn.js` minEpisodes 6, minContributors 2, agree 0.6) and publishes it
in the model with the result shares when the recommendation was followed
and when it was not.

**Session summary** (per fight): episodes by type, prediction and
recommendation outcomes, the results, the major threats, the cooldowns
each side spent, positioning changes, the candidate lessons, the inputs
line, the duplicates dropped.

**Tests**: `aio_intel_episodes_test` (13: one per type with its result;
duplicates; the player leaving; the inferred trigger; the summary, the
page, the confidence, the test-data refusal; the batch's compact
episodes); `test.js` (episodes validated and refused with the reason; the
learning engine's episode lessons).

## 8. Not done, and why

- Movement-based recommendations are judged by the target's gap and your
  own moving flag; a "break line of sight" cannot be verified (no read).
- "Invalid cooldown assumptions" are flagged only through the predictor's
  availability (a chance skipped); an episode does not re-check the
  recommended spell's availability beyond "ready at open".
- A corrupted combat session (a clock jump, a reload mid-fight) is not
  detected as such: the windows close by horizon or censor by departure.

- The repository's Action cannot answer a client at upload time: the
  client learns of a refusal only by looking at the issue (the HTTP
  service answers at once). The client treats the issue's creation (201)
  as "accepted"; a record the Action refuses is dropped there, counted in
  the issue's comment.

- No live run: the service was not deployed and no client has contacted
  one. The first deployment is the test of the loader's HTTP in practice
  (and of its redirect and header rules).
- Rotating identifiers on a schedule: the id rotates on request only.
- The PS session JWT is not used for authentication (it names the
  account); the shared client key is a weak gate and the brief's
  "authenticates clients" is met only to that extent. A per-install
  registration that issues a credential without an account link is the
  next step if abuse appears.
- Diagnostic detail is bounded (40 moments) but still free text: with the
  switch on, a moment's text could carry a name the replacement missed (an
  ability name that is also a player's name, say). The switch is off by
  default and says what it includes.
- The model's advice is per opponent class only; class and specialisation
  of the contributor shape nothing yet beyond `me.class` in the record.

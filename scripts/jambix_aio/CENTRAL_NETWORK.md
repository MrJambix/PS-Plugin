# Jambix — Central PvP Intelligence Network

> **Status, 2026-10-12.** Built and tested offline: the client adapter
> (`modules/react/intel/central.lua`, two backends: the GitHub repository
> itself, §9, or an HTTP service), the per-fight debrief that feeds it
> (`modules/react/intel/debrief.lua`), the predictor's observation hook, the
> consent controls on the Reactions page, the central service
> (`tools/fightlog_server/`: data service, learning engine, knowledge
> distribution) with its tests, and the repository's Action with its
> ingest script. **First live run, 2026-10-12 18:15 UTC**: the
> infrastructure pushed to main (commit 3aca274, no plugin file, so no
> release), issue #1 (a deletion request for a contributor that never
> existed) opened with the fine-grained token, the Action accepted it
> ("accepted: 0 record(s) removed"), closed it and created the
> `jambix-data` branch within a minute. The client side in a live game and
> the first published model are still to come. **The global learning
> engine (§11, the same day)**: learning groups with backoff, a trust screen
> with quarantine and audit, opponent models with intervals and drift,
> tactics as associations with counterexamples, a chronological holdout,
> release gates and a canary rollout -- tested on synthetic records only.
> **First live game, 2026-10-12**: the debrief crashed on your death (the
> game's Lua has no `os` table) and took the intel layer down with it until
> reload; fixed (a safe clock and a seeded id maker in `intel/init.lua`,
> each step of a fight's close protected, a regression test that runs a
> fight with no `os`). **Nothing of it has run against a live
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

## 11. The global learning engine (the brief of 2026-10-12)

"Continuously evaluate newly accepted combat experiences and periodically
generate candidate global intelligence updates ... Do not allow
unvalidated new submissions to directly change live tactical
recommendations." The service side lives in `tools/fightlog_server/`:

| File | What it is |
|---|---|
| `groups.js` | the learning groups and the backoff (§1 of the brief) |
| `trust.js` | the trust screen: duplicates, replays, suspicious numbers, volume, quarantine, audit (§5) |
| `learn.js` | the opponent models, the tactics, the episodes' lessons, the monitoring (§2, §3, §4) |
| `evaluate.js` | the chronological holdout against production, the prior and the baseline (§6) |
| `release.js` | the gates, the canary, promotion, rollback, the hold on noise (§7, §8) |
| `store.js` | the data directory both the HTTP service and the repository's Action use |

**The learning groups.** Every record is filed four times, narrowest
first, and the game variant is in every key, so nothing on Forever and
nothing on Era ever share a number:

| Level | Key | What it answers |
|---|---|---|
| exact | game, your class, their class, your level bracket (tens; 60), the encounter, 1v1 or outnumbered | this very matchup in this context |
| matchup | game, your class, their class | your class against theirs |
| class | game, their class | how that class behaves, whoever faces it |
| general | game | the compatible baseline |

The build is kept beside each rate, never in the key, so drift can be
measured. The client walks the same keys (`central.lua` `context`,
`key_at`, `prior_for`) and takes the narrowest level whose entry is
reliable, drawn toward even odds by that level's certainty -- broader
evidence, less certainty: exact 1, matchup 0.85, class 0.7, general 0.5
(a class-wide 0.9 seeds 0.78); the predictor's `why` names the level ("the database's over 30
fights at the matchup level"). Conditions that change inside a fight
(threat, your health) are not levels: they are conditional rates inside a
group (`by_condition`, shown with five chances or more). **Not keyed**:
specialisation (no record carries it yet; `me.spec` is accepted for when
one does), ability availability, resource state.

**The opponent model** of one group and pattern (`learn.js
patternEntry`): the chances, hits, misses and censored ones (episodes
whose window was cut); the weighted counts; the rate shrunk toward 0.5
by two chances; a 95% interval whose width uses the **effective count**
-- the observations of one fight are clusters, not independent draws,
so `n_eff = (Σw)² / Σw²` over fights; the forecast quality as the
forecasts stood (Brier, a calibration error over three bands with each
band's mean forecast and hit rate); the share with verified inputs; the
contributors and fights; the first and last time seen and the builds;
and `unreliable` with `why` when any bar fails (20 weighted chances, 2
contributors, 10 effective chances, Brier 0.30, half the inputs
verified, no contributor over 60% of the weight). A level whose rate
stands 0.2 or more from its parent's is marked `separate`: that matchup
needs its own model.

**Drift.** When the latest build has 10 chances and the earlier builds
10, and their rates stand 0.25 apart, the earlier builds' chances are
set aside for the rate and the entry says so (`drift`, `basis: latest
build`).

**Tactics as associations** (`learn.js tactic`). The brief's strategies,
each read off the decision episodes:

| Strategy | Episodes | The two arms |
|---|---|---|
| controlling the distance | a gap closer, the opener, a Blink, the dead zone, with a slow, a control or a move advised | followed / not followed |
| interrupting the cast | an interrupt advised | followed / not followed |
| waiting out the defensive | the opponent's defence changing | followed / not followed |
| managing the pet during control | the pet threatening a control | followed / not followed |
| pressing the kill opportunity | a kill window | followed / not followed |
| disengaging under pressure | outnumbered, rooted, a burst, with an escape or defensive advised | followed / not followed |
| preserving the escape | pressure with a defensive ready | kept / spent (what was done) |
| trading cooldowns | any episode with a cooldown spent | minor (slow, control, interrupt) / major (escape, defensive) |
| protecting allies | -- | **not measured**: no record carries an ally's state |

Only measured episodes with no quality flag count. Per group (exact,
matchup, class; never "against anyone"): each arm's count, fights,
effective count, contributors and good rate (a good result: survival,
position, damage opportunity, control, cooldown saved, objective); the
difference with its interval (fights as clusters); the same difference
**stratified** by the confounders the records carry (your health band,
two or more attackers, HIGH threat, a defensive ready) -- when the
stratified difference points the other way, the finding is "weak, the
confounders carry it"; a strength (insufficient: under 6 episodes or 3
fights an arm or one contributor; weak: the interval crosses zero;
moderate; strong: 0.2 or more); and the words "an association". Every
tactic carries `causal: false`, the confounders it was stratified by and
the ones it was not (gear, skill, teammates, the opponent's remaining
cooldowns).

**Successes and failures.** In the better arm the failures are the
counterexamples, kept with every finding: how many, their results, and
the conditions that told them apart from the successes (a condition at
least 30 points more common among the failures, "attackers = 2+ in 3 of
4 failures, 1 of 26 successes"). A strategy whose good rate fell 25
points in the last 30 days against its earlier self, with 6 episodes on
each side, is `stale` and no longer validated: a strategy that stopped
working.

**Poisoning and domination** (`trust.js`, before anything is counted).
Client uploads are claims; the screen reads the numbers, not the label:

- **duplicate content**: the same fight under a new id (a fingerprint of
  the record without its ids and clock);
- **replays**: half or more of a batch's episodes already seen from that
  contributor;
- **suspicious numbers**: a forecast or episode past the fight's end, more
  than three forecasts a second, fifteen or more forecasts all sure and
  all right, a fight of 0 s with records in it, a fight id another
  contributor filed, one fight at two levels or on two games;
- **volume**: more than 40 fights from one contributor on one day.

What fails is **quarantined** with its reasons (the model's `screen`
block counts them) and written to the audit; nothing is dropped
silently. Then, inside the learner: a forecast without verified inputs
weighs half (source quality); with three or more contributors none may
hold more than 40% of a group's weight (capped, and the entry says how
many were); a contributor whose own rate stands 0.4 from the **median
of the other contributors' own rates** (one vote each, so a flood cannot
make the honest ones the outliers) weighs half and is listed; a group
where one contributor still holds over 60% is not offered.

**Evaluation** (`evaluate.js`). The fights in the order received: the
earlier 70% teach a candidate, the later 30% test it; nothing from the
test fights reaches the training. On the same test forecasts: the
candidate, **production** (the model the clients run), the **prior**
(0.5, what every client starts with) and the **baseline** (the training
fights' matchup or class rate, reliable or not). For each: the Brier
score with its standard error (fights as clusters), the calibration
error over five bins, the coverage (the share of forecasts the model
had a usable rate for, and at which level), the accuracy, the false and
true positive rates at 0.6, the skill against the prior, and the same by
matchup and by game. Then paired comparisons fight by fight (better /
worse / indistinguishable at two standard errors), and the
recommendation stability between the candidate and production (the
share of shared usable rates that moved under 0.1; the share of shared
validated tactics with the same better arm). The holdout says when it is
too small (under 10 test forecasts) to mean anything.

**Release gates** (`release.js gates`), all written into the package:

1. contributors: 2 or more;
2. content: at least one usable rate or validated tactic;
3. not worse than the prior (Brier within 0.02), on the holdout;
4. not worse than production (Brier within 0.02), on the holdout;
5. calibration error at most 0.15, with 30 test forecasts or more;
6. material change: 20 new fights since production, or 10% more, or a
   holdout verdict "better" -- otherwise **hold** (no new version on a
   tiny fluctuation).

Gates 3 to 5 are skipped and said to be when the holdout is too small. A
cycle ends `unchanged` (no record arrived since the last cycle and
production is the same: nothing is written, so the six-hourly schedule
does not commit to the data branch for nothing), `reject` (a gate failed:
the evaluation and the audit are written, nothing else), `hold` (passed,
nothing material) or `publish`.

**Publishing.** A version is a package: the model; `compatibility`
(schema, minimum plugin, the games and their builds); `release` with the
evidence (usable rates, validated tactics), the gates and their checks,
the evaluation, the stability, the rollback target and the known
limitations; the version and the time. The first version goes out
**full**; every later one as a **canary** to 25% of clients, chosen by
the contributor id (the same client always lands on the same side),
until promoted by hand; the clients still on the full version keep it.
Each batch now carries the model version its client ran under
(`client.model`), so the next cycle reads how the forecasts made under
each version scored (`monitoring`): the canary's own record in play,
compared with the full version's, before anyone promotes it. Withdrawing
a version rolls back to the previous active one; promotion and
withdrawal are audited. **No model is ever a rule**: the client reads
rates into the predictor's prior and shows validated tactics as words
("association: ..."); the reaction engine never reads a model (the
client test "nothing from a model becomes a rule" holds that).

**Continuous improvement.** Every six hours the repository's Action
ingests the issues and runs a learning cycle; most cycles end in hold
or reject, and that is the design: a version changes only when the
evidence grew enough and the holdout does not say it got worse. By hand:
`evaluate` (the candidate, the gates, the holdout, nothing written),
`publish` (one cycle), `publish --force` (past the gates, written as
forced), `promote N`, `withdraw N`. The HTTP service has the same as
admin routes, and `GET /v1/admin/audit`, `GET /v1/knowledge/tactics`.

**Tests.** `node --test tools/fightlog_server/learn.test.js` (10): the
groups and the backoff; the trust screen (duplicate content, replays,
the three suspicious numbers, the volume cap, a shared fight id, the
audit); the opponent model (the interval, the effective count and
calibration; a flood capped, the outlier by the median, one person
alone refused; no merge across games; a matchup apart from its class;
conditional rates; drift); tactics (an association with its interval,
strength, counterexamples and the condition that told them apart; too
thin; stale); the evaluation (the holdout, beating the prior, production
compared and beaten paired by fight, the thin holdout, stability); the
release (rejected, first full, held, canary, promoted, withdrawn,
forced, the audit's order; a worse candidate against production and the
monitoring under a version; preview writes nothing). `test.js` and
`github_ingest.test.js` follow the gated publish. On the client,
`aio_intel_central_test`: the narrowest reliable level wins and says so,
an unreliable one backs off, another game's knowledge is never read; the
canary by share, at 100%, the same side every time; each batch carries
its model version and the number of players faced; adopting a model
changes no rule and shows only validated tactics, as associations.

**Success, as the brief states it**, is "measurable, repeatable
improvements ... without letting noisy or malicious data degrade the
network". The machinery to measure that exists and is tested on
synthetic records. **Whether it happens is unknown**: no contributor has
sent a record yet, so no model has been judged on real fights.

## 12. The first live fights, and the learning log (2026-10-12)

**The first uploads.** AIO 1.7.8 went live at about 21:40 UTC; by 22:05 the
user's own client had filed one fight (a level 29 hunter against a rogue,
won in 15 s: 19 forecast checks, 3 decision episodes) -- five times, issues
#2 to #6, each after a doubling wait. GitHub had taken every one (the
Action answered "accepted (duplicate)" from the second), but the client
counted each try a failure, so it tried again and the fight's lesson and
two more fights waited behind it in the queue. What the client read is
unknown (the recorder logs calls, not answers); every reading of it is now
handled: a 2xx is delivered whatever its answer says; a try that ends with
no status or a server error makes the next one ask GitHub for the issue by
title first and stop if it is there; every failure is logged with its
status; a queue read from disk is due at once (its waits were on the last
session's clock) and an item tried before is looked for first. The fix is
in the client and needs a release to reach players. Test: `aio_intel_central_test`
("live 2026-10-12: a fight filed five times").

**Empty tables, either shape.** Replaying the user's real stuck queue (six
records) through the fixed client showed what the service would have done
with them: the second fight's batch refused (an episode with no actions,
written `"actions": {}` by the client's own encoder) and, with the game's
encoder (JCore's, which writes every empty table as `[]`), all three
lessons refused (an enemy that never controlled you: `"controls_on_me": []`).
Lua cannot tell an empty list from an empty map. The service now gives an
empty value the shape its field has before checking it
(`validate.js normalize`; the trust screen does the same for anything
stored before), and still refuses a non-empty value of the wrong shape. This
is the service's side, so it holds for every 1.7.8 client already out.
Test: `github_ingest.test.js` ("an empty table in either shape").

**The empty v1.** The old schedule (before the gated cycle was pushed)
published an empty v1 at 18:41. A production with no fight is now no
production: the first real model goes to every player, with no rollback
to an empty one.

**The learning log** (`tools/fightlog_server/report.js`). Each learning
cycle that saw something new writes an entry, newest first, to
`data/LEARNING_LOG.md` on the data branch, and the same text on the
Action run's summary page:

- what arrived since the last cycle (fights, players, the matchups, the
  outcomes) and what was set aside, with the reasons;
- what players get: a new version and what is in it, or "nothing changes"
  with the gates that held it back;
- what the network knows per game: each opponent habit's rate, checks and
  fights, and either **used** with its interval or how far it is from the
  bars ("15 of 20 checks, 1 of 2 players, 1 of 10 independent fights'
  worth"); the validated tactics, and the nearest ones with their counts;
- what changed since the last cycle: new habits, ones that became used or
  stopped being used, rates that moved five points or more, tactics found
  or lost, lessons confirmed.

A compact snapshot (`data/models/last_cycle.json`) is what the next entry
is compared with; "new" means received after the newest record the last
cycle saw. A cycle with nothing new writes nothing. `evaluate` prints the
entry it would write and writes nothing. Test: `learn.test.js` ("the
learning log").

## 13. The relook of the first fights (2026-10-12, later)

The user's three real fights, read back, showed what was wrong in what had
been built; the user: "let's fix the first 9". In the network's terms:

- **Outcomes.** Two of the three were uploaded as "won" when the opponent
  had left (a Vanish, out of sight): a gone unit read as dead. A death now
  needs the game's word on a unit still there; rogues and druids are
  waited for 30 s. Lessons from before the fix carry the wrong outcome; at
  three records the learner has nothing to undo.
- **Enemy events.** Every fight's lesson now carries `feeds`: the enemy
  casts and auras the client kept, the ones it dropped and by which unit
  token. The service stores them as they come (not validated beyond the
  record's bounds); the next fights say whether Forever's events reach the
  picture.
- **One chance a window** for "goes for your pet" (it was a sample a
  second), so one fight no longer fills the 20-check bar.
- **One issue per fight** (`jambix-fight <id>`: the lesson and, when
  there is one, the batch; `validate.js validateFight`, `github_ingest.js`).
  Older clients' `jambix-batch` / `jambix-lesson` issues still file.
- **Hourly filing.** The Action no longer runs on each issue: it files the
  open issues at :07 every hour and learns at :17 every six hours. Every run
  is billed at least a minute of the private repository's Actions minutes,
  so a run per issue grew with the players; this is some 30 runs a day
  whatever comes in. An upload waits up to an hour to be filed; the
  client's "already filed?" lookup reads open issues too.
- **The two-player rule is a setting**: the repository variable
  `JAMBIX_MIN_CONTRIBUTORS` (Settings > Secrets and variables > Actions >
  Variables) sets how many players a habit, a tactic and a release need;
  unset, 2. Nothing changed it.
- **The weights check** (`learn.js threatCheck`, in every learning log
  entry): with 8 measured moments on each side, does a HIGH or CRITICAL
  threat read come before things getting worse more often than a LOW one?
  *separates*, *unclear* or *inverted* ("the weights want reweighing"). A
  check, never a tuning: the client's weights change by hand with this as
  the evidence.
- **The token** in every copy of the plugin stays the open risk: anyone
  with the plugin can open issues. The trust screen refuses what is
  malformed or implausible; a relay service in front of GitHub is the way
  to remove the token from the plugin, and does not exist.

## 14. The second live batch: the repair (2026-10-13)

Seventeen more fights (issues #14 to #30) showed two faults in what the
clients up to AIO 1.7.8 send (PVP_INTEL_PLAN §3.22): an enemy credited with
what was only on it (another's shield, another class's spell) in the
lesson's `used` and in that class's defensive habits; and episodes and
forecasts timed from the fight before, past this fight's end, with a
sub-second fight sent as 0 s. The client is fixed and marks its records
`client.rev = 2`. Records without it are revision 1, and the trust screen
now **repairs** them before it screens (`trust.js repair`), rather than
quarantining a whole fight for one stray episode:

- a name in an enemy's `used` that the client's tables give to another
  class (`owners.js`, read off `scripts/jambix_aio/modules/pvp_data.lua`,
  the file the plugin reads) is taken out;
- when such a name is a defensive (Power Word: Shield, Blessing of
  Protection, ...), that class's `defensive_threshold` and
  `saving_cooldowns_until_low` observations in the same fight's batch are
  taken out;
- episodes and forecasts timed more than 5 s past the fight's end are
  taken out; a 0 s fight with records is its rounding, not suspect.

The repair only takes away; the stored records never change (it works on
copies at every cycle); each repair is an audit row (`action: repaired`)
with its reasons. A revision 2 record is held to its numbers as before: a
forecast past its end or a 0 s fight with records in it is quarantined.

The learning log gains **The fights**: one row per fight (the new ones; the
first time, every one) with when it was received, the matchup and levels,
the result, the length, its checks and episodes, and what became of it
(used, used and repaired with why, or set aside with why); and a
**Repaired** line beside *Set aside*.

A learning cycle also runs again when the **engine** changed: each cycle
writes a fingerprint of the learning code and the spell tables it reads
(`release.js ENGINE`), and "unchanged" now needs the same records *and*
the same engine. The repair came in with no new record, and the cycle had
answered "unchanged" over records the old screen had set aside.

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
- Specialisation is not a level: no record carries it (the validator
  accepts `me.spec` for when one does). Your class, level bracket, the
  encounter and 1v1 or outnumbered are (§11).
- The global learning engine's limits (§11): a tactic is an association,
  never a cause (no fight was randomised); gear, skill, teammates and the
  opponent's remaining cooldowns are confounders the records do not carry;
  the effective count treats a fight as one cluster, which is an
  approximation (one player met in several fights is not clustered);
  "protecting allies" is not measured; the trust screen catches a
  duplicate, a replay and impossible numbers, but a careful forger who
  sends plausible, varied fights under many identifiers is limited only by
  the per-identifier caps, the median outlier check and the two-contributor
  bars, and the GitHub token every client carries lets anyone with the
  plugin open issues. The release gates judge forecasts on a holdout of the
  same contributors' later fights, not on new players.
- The first canary's monitoring needs batches sent under it: until enough
  arrive, a canary's own record in play is empty and the promotion is a
  judgement on the holdout alone.

# Jambix central service

The Central Data Service, the Global Learning Engine and the Knowledge
Distribution Service of the shared PvP intelligence network. The client is
`scripts/jambix_aio/modules/react/intel/central.lua`; the design is
`scripts/jambix_aio/CENTRAL_NETWORK.md` (§11 for the learning engine).

| File | What it is |
|---|---|
| `server.js` | the HTTP service: routes, keys, limits |
| `github_ingest.js` | the same service with the GitHub repository as the database (the Action runs it) |
| `validate.js` | what a record must look like and must never contain |
| `store.js` | the data directory: records, ids, deletions, the audit, the models and their manifest, the evaluations |
| `trust.js` | the trust screen: duplicates, replays, suspicious numbers, volume caps, quarantine |
| `groups.js` | the learning groups (exact, matchup, class, general; the game in every key) and the backoff |
| `learn.js` | the opponent models, the tactics as associations, the episodes' lessons, the monitoring |
| `evaluate.js` | the chronological holdout: candidate against production, the prior and the baseline |
| `release.js` | the gates, the canary, promotion, rollback, the hold on noise |

## Run

```
KEY=client-key ADMIN_KEY=admin-key PORT=8787 DATA_DIR=./data node server.js
```

Put HTTPS in front (Caddy: `reverse_proxy localhost:8787`); the service
speaks plain HTTP. Keep it up with pm2 or a systemd unit. `DATA_DIR` holds
the database: `batches.jsonl`, `lessons.jsonl`, `ids.json` (dedupe),
`deletions.jsonl`, `audit.jsonl`, `models/` (`manifest.json`, `vN.json`,
`evaluations.jsonl`). Back it up.

Limits: `MAX_BODY` (256 KB), `RATE_PER_MINUTE` per contributor and per
address (60), `RETENTION_DAYS` (180, purged daily).

## Learn and publish

Every cycle that saw something new writes an entry to `data/LEARNING_LOG.md`
(`report.js`): what arrived, every fight in a table (what it brought and
what the screen did with it), what the network knows and how far each habit
is from being used, what changed, and what players get. Records of an older
client (no `client.rev`) are repaired before the screen (`trust.js repair`:
another class's spell in "used", the defensive habits read off another's
shield, episodes and forecasts timed past the fight's end; `owners.js` reads
which class owns a spell off `scripts/jambix_aio/modules/pvp_data.lua`);
each repair is in the audit. On GitHub it is at
`https://github.com/MrJambix/PS-Plugin/blob/jambix-data/data/LEARNING_LOG.md`,
and each Action run's summary page shows its entry.

A publish is a **learning cycle**: the candidate is built from every
accepted record that passes the trust screen, judged on the later fights
it never saw against production, the plain prior and the baseline, and
run through the gates (two contributors, some usable content, not worse
than the prior or production on the holdout, calibrated, and a material
change since production). It ends `unchanged` (no record since the last
cycle: nothing written), `reject` (only the evaluation and the audit are
written), `hold` (passed, nothing material: no new version) or `publish`.
A cycle with no new record still runs when the learning code changed
(`release.js ENGINE`, a fingerprint written with each cycle). The first version goes out full; later ones as a canary to 25%
of clients until promoted.

```
node server.js evaluate                  # the candidate, the gates, the holdout -- nothing written
node server.js publish "note"            # one cycle
node server.js publish --force "note"    # a version whatever the gates say, written as forced
node server.js promote 3                 # the canary to everyone
node server.js withdraw 3                # rollback: the previous active version stands
```

Or over HTTP with the admin key: `POST /v1/admin/publish { note, force, full }`,
`POST /v1/admin/promote { version }`, `POST /v1/admin/withdraw { version }`,
`GET /v1/admin/evaluate`, `GET /v1/admin/audit?limit=`.

A model is per game (`games.Forever`, `games.Vanilla`; nothing crosses
them): `groups` (every pattern's rate, interval, effective count,
calibration, conditional rates, drift by build, and `unreliable` with
`why`), `by_class` (outcomes, advice, abilities, the episodes' lessons),
`tactics` (associations with their arms, interval, strength,
counterexamples, staleness; `causal: false` always) and `monitoring` (how
the forecasts made under each published version scored). The package adds
`compatibility` and `release` (the gates, the evaluation, the stability,
the rollback target, the known limitations). Clients seed a prior only
from a reliable entry, from the narrowest group that has one; no model is
ever a rule.

## Filing and settings on GitHub

The Action files the open issues once an hour (:07) and runs a learning
cycle every six hours (:17); it no longer runs on each issue, so its cost
in Actions minutes does not grow with the players. A fight comes as one
issue (`jambix-fight <id>`, its lesson and its batch); older clients' two
issues still file. The repository variable `JAMBIX_MIN_CONTRIBUTORS` sets
how many players a habit, a tactic and a release need (unset: 2).

## Routes

All under the client key (`X-Jambix-Key`) except `/health`.

| Route | What |
|---|---|
| `POST /v1/combat/batches` | a fight's forecast observations and episodes; `{ ok, duplicate? }` |
| `POST /v1/lessons` | a fight's lesson; `{ ok, duplicate? }` |
| `GET /v1/models/manifest` | the versions: `{ version, schema, min_plugin, status, stage, rollout, gates, rollback, created_at }` |
| `GET /v1/models/{version}` | one model; 410 once withdrawn |
| `GET /v1/knowledge/matchups?game=` | production's outcomes, advice, rates and episode lessons per game and opponent class |
| `GET /v1/knowledge/abilities?game=` | production's abilities per game and opponent class (with `verified`) |
| `GET /v1/knowledge/tactics?game=` | production's tactical associations per game |
| `GET /v1/client/status?plugin=&schema=` | `{ accepted, min_plugin, message, fights, active_model }` |
| `POST /v1/privacy/delete` | `{ schema, contributor }`: every record under it removed, the request logged |

## Tests

```
node --test tools/fightlog_server/test.js tools/fightlog_server/github_ingest.test.js tools/fightlog_server/learn.test.js
```

`test.js`: authorisation, invalid data, duplicates, the body and rate
limits, privacy deletion, the gated publish with forced versions, canary
and promotion, the audit, the knowledge routes, episodes, retention.
`learn.test.js`: the groups and the backoff, the trust screen and the
repair of older records, the fights table, the opponent model (caps, outliers, clusters, drift, conditions, a matchup
apart), tactics (association, counterexamples, staleness), the
evaluation, the release (reject, full, hold, canary, promote, withdraw,
force, a worse candidate, the monitoring, preview).

## Or: the repository as the service

No server: the clients open issues on `MrJambix/PS-Plugin` with a
fine-grained token (Issues: write, Contents: read, Metadata: read), and
`.github/workflows/jambix-central.yml` runs `github_ingest.js` to file
them into the `jambix-data` branch and run a learning cycle every six
hours. `scripts/jambix_aio/CENTRAL_NETWORK.md` §9 has the whole of it; by
hand:

```
GITHUB_REPOSITORY=MrJambix/PS-Plugin GITHUB_TOKEN=... DATA_DIR=./data node github_ingest.js ingest
DATA_DIR=./data node github_ingest.js evaluate
DATA_DIR=./data node github_ingest.js publish "note"
DATA_DIR=./data node github_ingest.js promote 2
```

Actions > Jambix central > Run workflow takes `ingest`, `evaluate`,
`publish`, `publish --force`, `promote N`, `withdraw N`.

## Point the plugin at it

Copy `scripts/jambix_aio/modules/central_config.example.lua` to
`central_config.lua` with the address and the client key and ship it; or
set `scripts_data/jambix.aio.central.json` on one machine. Contribution and
downloads stay off on every client until the player turns them on (the
Reactions page, *Fight debriefs and the shared network*).

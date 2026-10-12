# Jambix central service

The Central Data Service, the Global Learning Engine and the Knowledge
Distribution Service of the shared PvP intelligence network, in one Node
process (`server.js`, `learn.js`, `validate.js`). The client is
`scripts/jambix_aio/modules/react/intel/central.lua`; the design is
`scripts/jambix_aio/CENTRAL_NETWORK.md`.

## Run

```
KEY=client-key ADMIN_KEY=admin-key PORT=8787 DATA_DIR=./data node server.js
```

Put HTTPS in front (Caddy: `reverse_proxy localhost:8787`); the service
speaks plain HTTP. Keep it up with pm2 or a systemd unit. `DATA_DIR` holds
the database: `batches.jsonl`, `lessons.jsonl`, `ids.json` (dedupe),
`deletions.jsonl`, `models/`. Back it up.

Limits: `MAX_BODY` (256 KB), `RATE_PER_MINUTE` per contributor and per
address (60), `RETENTION_DAYS` (180, purged daily).

## Publish what it learned

```
node server.js publish "first model"     # builds models/v1.json and lists it active
node server.js withdraw 1                # rollback: the previous active version stands
```

Or over HTTP with the admin key: `POST /v1/admin/publish`,
`POST /v1/admin/withdraw { "version": "1" }`, `GET /v1/admin/evaluate` (the
model as it would be built, without publishing).

A model's `patterns[key]` carries the rate, the chances, the fights, the
contributors, the forecast quality (a Brier score against the forecasts as
they stood) and `unreliable` with `why` when any threshold fails
(`learn.js DEFAULTS`: 20 chances, 2 contributors, Brier 0.30, half the
chances with verified inputs). Clients seed a prior only from a reliable
entry. The network is not "learning" until a published model has entries
that pass those thresholds; `GET /v1/admin/evaluate` shows how far it is.

## Routes

All under the client key (`X-Jambix-Key`) except `/health`.

| Route | What |
|---|---|
| `POST /v1/combat/batches` | a fight's forecast observations; `{ ok, duplicate? }` |
| `POST /v1/lessons` | a fight's lesson; `{ ok, duplicate? }` |
| `GET /v1/models/manifest` | the versions, each `{ version, schema, min_plugin, status, created_at }` |
| `GET /v1/models/{version}` | one model; 410 once withdrawn |
| `GET /v1/knowledge/matchups` | the active model's outcomes, advice and patterns per opponent class |
| `GET /v1/knowledge/abilities` | the active model's abilities per opponent class |
| `GET /v1/client/status?plugin=&schema=` | `{ accepted, min_plugin, message, fights, active_model }` |
| `POST /v1/privacy/delete` | `{ schema, contributor }`: every record under it removed, the request logged |

## Tests

```
node --test tools/fightlog_server/test.js
```

Authorisation, invalid data (schema, fields, forbidden names, unknown
patterns and codes), duplicates, the body and rate limits, privacy
deletion, version publish / withdraw / 410 / client status, the learning
engine's thresholds and matchup advice, retention.

## Or: the repository as the service

No server: the clients open issues on `MrJambix/PS-Plugin` with a
fine-grained token (Issues: write, Contents: read, Metadata: read), and
`.github/workflows/jambix-central.yml` runs `github_ingest.js` to file
them into the `jambix-data` branch and publish models every six hours.
`scripts/jambix_aio/CENTRAL_NETWORK.md` §9 has the whole of it; by hand:

```
GITHUB_REPOSITORY=MrJambix/PS-Plugin GITHUB_TOKEN=... DATA_DIR=./data node github_ingest.js ingest
DATA_DIR=./data node github_ingest.js publish "note"
node --test tools/fightlog_server/github_ingest.test.js
```

## Point the plugin at it

Copy `scripts/jambix_aio/modules/central_config.example.lua` to
`central_config.lua` with the address and the client key and ship it; or
set `scripts_data/jambix.aio.central.json` on one machine. Contribution and
downloads stay off on every client until the player turns them on (the
Reactions page, *Fight debriefs and the shared network*).

#!/usr/bin/env node
'use strict';
// Jambix central service -- the Central Data Service and the Knowledge
// Distribution Service of the shared PvP intelligence network
// (scripts/jambix_aio/CENTRAL_NETWORK.md). The learning engine is learn.js
// (with groups.js and trust.js), the evaluation evaluate.js, the release
// gates release.js, the record bounds validate.js, the files store.js. The
// client is scripts/jambix_aio/modules/react/intel/central.lua.
//
// Routes (all under the shared client key, header X-Jambix-Key, except /health):
//   POST /v1/combat/batches      a fight's forecast observations and episodes -> { ok, duplicate? }
//   POST /v1/lessons             a fight's lesson                              -> { ok, duplicate? }
//   GET  /v1/models/manifest     the versions: schema, plugin range, status, stage (canary / full), rollout, gates, rollback
//   GET  /v1/models/{version}    one model (410 once withdrawn, 404 unknown)
//   GET  /v1/knowledge/matchups  the production model's outcomes, advice and class-level rates per game and opponent class (?game=)
//   GET  /v1/knowledge/abilities the production model's abilities per game and opponent class
//   GET  /v1/knowledge/tactics   the production model's tactical associations per game
//   GET  /v1/client/status       { ok, schema, min_plugin, accepted, message, fights, active_model }
//   POST /v1/privacy/delete      { schema, contributor } -> every record under it removed
//   POST /v1/admin/publish       (X-Jambix-Admin) { note?, force?, full? } one learning cycle: build, evaluate, gate; a canary when it passes
//   POST /v1/admin/promote       (X-Jambix-Admin) { version } -> the canary rolled out to everyone
//   POST /v1/admin/withdraw      (X-Jambix-Admin) { version } -> withdrawn (the previous active stands: rollback)
//   GET  /v1/admin/evaluate      (X-Jambix-Admin) the candidate, its evaluation and the gates' verdict, nothing written
//   GET  /v1/admin/audit         (X-Jambix-Admin) the last decisions (?limit=)
//
// Run:  KEY=client-key ADMIN_KEY=admin-key PORT=8787 DATA_DIR=./data node server.js
//       node server.js publish [--force] [note]   node server.js promote 3   node server.js withdraw 3   node server.js evaluate
// Put HTTPS in front (a reverse proxy); this speaks plain HTTP. Limits: bodies
// to MAX_BODY, RATE_PER_MINUTE per contributor and per address, records
// older than RETENTION_DAYS purged daily. No address is stored with a record.

const http = require('http');
const path = require('path');
const { SCHEMA, validateBatch, validateLesson, validateDelete } = require('./validate');
const { createStore, vnum } = require('./store');
const release = require('./release');

const MIN_PLUGIN = release.DEFAULTS.minPlugin;

function createApp(options) {
    const opts = Object.assign({
        dataDir: process.env.DATA_DIR || path.join(__dirname, 'data'),
        key: process.env.KEY || '',
        adminKey: process.env.ADMIN_KEY || '',
        maxBody: Number(process.env.MAX_BODY) || 256 * 1024,
        ratePerMinute: Number(process.env.RATE_PER_MINUTE) || 60,
        retentionDays: Number(process.env.RETENTION_DAYS) || 180,
        minPlugin: MIN_PLUGIN,
        learn: {},                 // learn.js thresholds
        release: {},               // release.js gates
        now: () => Date.now(),
    }, options || {});

    const store = createStore(opts.dataDir, { retentionDays: opts.retentionDays, now: opts.now });
    store.purge();
    const purgeTimer = setInterval(() => store.purge(), 3600 * 1000);
    purgeTimer.unref();
    const releaseOpts = extra => Object.assign({ minPlugin: opts.minPlugin, learn: opts.learn }, opts.release, extra || {});

    // --- the learning engine, released ----------------------------------------------------
    const evaluate = () => release.preview(store, releaseOpts());
    const publish = (note, extra) => release.cycle(store, releaseOpts(Object.assign({ note }, extra || {})));
    const promote = version => release.promote(store, version);
    const withdraw = version => release.withdraw(store, version);

    // --- rate limiting --------------------------------------------------------------------
    const buckets = new Map();
    function allowed(key) {
        const now = opts.now();
        let b = buckets.get(key);
        if (!b) { b = { tokens: opts.ratePerMinute, at: now }; buckets.set(key, b); }
        b.tokens = Math.min(opts.ratePerMinute, b.tokens + (now - b.at) / 60000 * opts.ratePerMinute);
        b.at = now;
        if (b.tokens < 1) return false;
        b.tokens -= 1;
        return true;
    }

    // --- http -----------------------------------------------------------------------------
    const send = (res, code, value) => {
        const body = JSON.stringify(value);
        res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
        res.end(body);
    };
    const readBody = (req, res, cb) => {
        let body = '', over = Number(req.headers['content-length'] || 0) > opts.maxBody;
        req.on('data', chunk => {
            if (over) return;                      // drained, not stored: the answer is 413
            body += chunk;
            if (body.length > opts.maxBody) { over = true; body = ''; }
        });
        req.on('end', () => {
            if (over) return send(res, 413, { error: 'body too large' });
            let value;
            try { value = JSON.parse(body); } catch (e) { return send(res, 400, { error: 'not json' }); }
            cb(value);
        });
    };

    function accept(req, res, kind, validate) {
        readBody(req, res, record => {
            const err = validate(record);
            if (err) return send(res, 400, { error: err });
            if (String(record.contributor) !== String(req.headers['x-jambix-contributor'] || record.contributor)) {
                return send(res, 400, { error: 'contributor header does not match the record' });
            }
            const r = store.accept(kind, record);
            if (r.duplicate) return send(res, 200, { ok: true, duplicate: true });
            send(res, 200, { ok: true, kind });
        });
    }

    const production = () => { const a = store.activeVersion(); return a ? store.readModel(a.version) : null; };

    const server = http.createServer((req, res) => {
        const url = new URL(req.url, 'http://x');
        const p = url.pathname;
        if (req.method === 'GET' && p === '/health') return send(res, 200, { ok: true, fights: store.ids.size });
        if (!p.startsWith('/v1/')) return send(res, 404, { error: 'no such route' });
        if (opts.key && req.headers['x-jambix-key'] !== opts.key) return send(res, 401, { error: 'bad key' });
        const who = String(req.headers['x-jambix-contributor'] || '') || (req.socket && req.socket.remoteAddress) || 'unknown';
        if (!allowed(who) || !allowed('addr:' + (req.socket && req.socket.remoteAddress))) return send(res, 429, { error: 'rate limited' });

        if (p.startsWith('/v1/admin/')) {
            if (!opts.adminKey || req.headers['x-jambix-admin'] !== opts.adminKey) return send(res, 401, { error: 'bad admin key' });
            if (req.method === 'POST' && p === '/v1/admin/publish') {
                return readBody(req, res, body => {
                    const r = publish(body && body.note, { force: !!(body && body.force), full: !!(body && body.full) });
                    send(res, 200, { ok: true, decision: r.decision, version: r.version, stage: r.stage || null, failed: r.verdict.failed, checks: r.verdict.checks, material: r.verdict.material,
                        fights: r.candidate ? r.candidate.fights : null, contributors: r.candidate ? r.candidate.contributors : null });
                });
            }
            if (req.method === 'POST' && p === '/v1/admin/promote') {
                return readBody(req, res, body => send(res, promote(body && body.version) ? 200 : 404, { ok: true }));
            }
            if (req.method === 'POST' && p === '/v1/admin/withdraw') {
                return readBody(req, res, body => send(res, withdraw(body && body.version) ? 200 : 404, { ok: true }));
            }
            if (req.method === 'GET' && p === '/v1/admin/evaluate') return send(res, 200, evaluate());
            if (req.method === 'GET' && p === '/v1/admin/audit') return send(res, 200, { rows: store.readAudit(Number(url.searchParams.get('limit')) || 200) });
            return send(res, 404, { error: 'no such admin route' });
        }

        if (req.method === 'POST' && p === '/v1/combat/batches') return accept(req, res, 'batch', validateBatch);
        if (req.method === 'POST' && p === '/v1/lessons') return accept(req, res, 'lesson', validateLesson);
        if (req.method === 'GET' && p === '/v1/models/manifest') return send(res, 200, store.readManifest());
        const mv = p.match(/^\/v1\/models\/([0-9a-z.]+)$/i);
        if (req.method === 'GET' && mv) {
            const entry = store.readManifest().versions.find(v => String(v.version) === mv[1]);
            if (!entry) return send(res, 404, { error: 'no such model' });
            if (entry.status !== 'active') return send(res, 410, { error: 'withdrawn' });
            const model = store.readModel(mv[1]);
            return model ? send(res, 200, model) : send(res, 404, { error: 'model file missing' });
        }
        const kv = p.match(/^\/v1\/knowledge\/(matchups|abilities|tactics)$/);
        if (req.method === 'GET' && kv) {
            const model = production();
            if (!model) return send(res, 404, { error: 'no active model' });
            const want = url.searchParams.get('game');
            const out = { version: model.version, fights: model.fights, contributors: model.contributors, games: {} };
            for (const [game, G] of Object.entries(model.games || {})) {
                if (want && want !== game) continue;
                if (kv[1] === 'tactics') { out.games[game] = { fights: G.fights, tactics: G.tactics }; continue; }
                const by_class = {};
                for (const [cls, c] of Object.entries(G.by_class || {})) {
                    by_class[cls] = kv[1] === 'matchups'
                        ? { fights: c.fights, outcomes: c.outcomes, advice: c.advice, patterns: c.patterns, episode_lessons: c.episode_lessons }
                        : { fights: c.fights, abilities: c.abilities };
                }
                out.games[game] = { fights: G.fights, by_class };
            }
            return send(res, 200, out);
        }
        if (req.method === 'GET' && p === '/v1/client/status') {
            const plugin = url.searchParams.get('plugin') || '';
            const schema = Number(url.searchParams.get('schema') || 0);
            const accepted = schema === SCHEMA && vnum(plugin) >= vnum(opts.minPlugin);
            const active = store.activeVersion();
            return send(res, 200, {
                ok: true, schema: SCHEMA, min_plugin: opts.minPlugin, accepted,
                message: accepted ? `accepted: plugin ${plugin}, schema ${schema}` : `not accepted: needs plugin ${opts.minPlugin} and schema ${SCHEMA}`,
                fights: store.ids.size, active_model: active ? active.version : null,
            });
        }
        if (req.method === 'POST' && p === '/v1/privacy/delete') {
            return readBody(req, res, body => {
                const err = validateDelete(body);
                if (err) return send(res, 400, { error: err });
                send(res, 200, { ok: true, removed: store.forget(body.contributor) });
            });
        }
        return send(res, 404, { error: 'no such route' });
    });

    return { server, store, publish, promote, withdraw, evaluate, files: store.files, options: opts, close: () => { clearInterval(purgeTimer); server.close(); } };
}

if (require.main === module) {
    const app = createApp();
    const cmd = process.argv[2];
    const say = r => console.log(r.version
        ? `published model v${r.version} (${r.stage}): ${r.candidate.fights} fight(s), ${r.candidate.contributors} contributor(s), ${r.candidate.observations} observation(s)${r.decision === 'forced' ? ' -- FORCED past the gates: ' + r.verdict.failed.join(', ') : ''}`
        : `${r.decision}: ${r.verdict.failed.length ? 'failed ' + r.verdict.failed.join(', ') : r.verdict.material.why}`);
    if (cmd === 'publish') {
        const args = process.argv.slice(3);
        const force = args.includes('--force');
        say(app.publish(args.filter(a => a !== '--force').join(' '), { force }));
        process.exit(0);
    } else if (cmd === 'promote') {
        console.log(app.promote(process.argv[3]) ? `promoted v${process.argv[3]} to everyone` : 'no such active version');
        process.exit(0);
    } else if (cmd === 'withdraw') {
        console.log(app.withdraw(process.argv[3]) ? `withdrawn v${process.argv[3]}` : 'no such version');
        process.exit(0);
    } else if (cmd === 'evaluate') {
        const r = app.evaluate();
        console.log(JSON.stringify({ decision: r.verdict.decision, checks: r.verdict.checks, material: r.verdict.material, holdout: r.report.holdout, models: Object.fromEntries(Object.entries(r.report.models).map(([k, v]) => [k, v && v.n ? { n: v.n, brier: v.brier, ece: v.ece, coverage: v.coverage, skill: v.skill } : null])) }, null, 2));
        process.exit(0);
    } else {
        const port = Number(process.env.PORT) || 8787;
        app.server.listen(port, () => {
            console.log(`jambix central service on :${port}, data ${app.options.dataDir}, key ${app.options.key ? 'set' : 'NOT SET (anyone may post)'}, admin key ${app.options.adminKey ? 'set' : 'NOT SET (no publishing over http)'}`);
        });
    }
}

module.exports = { createApp, MIN_PLUGIN };

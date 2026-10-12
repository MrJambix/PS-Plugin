#!/usr/bin/env node
'use strict';
// Jambix central service -- the Central Data Service and the Knowledge
// Distribution Service of the shared PvP intelligence network
// (scripts/jambix_aio/CENTRAL_NETWORK.md). The learning engine is learn.js,
// the record bounds validate.js. The client is
// scripts/jambix_aio/modules/react/intel/central.lua.
//
// Routes (all under the shared client key, header X-Jambix-Key, except /health):
//   POST /v1/combat/batches      a fight's forecast observations      -> { ok, duplicate? }
//   POST /v1/lessons             a fight's lesson                     -> { ok, duplicate? }
//   GET  /v1/models/manifest     the model versions, active or withdrawn, each with its schema and plugin range
//   GET  /v1/models/{version}    one model (410 once withdrawn, 404 unknown)
//   GET  /v1/knowledge/matchups  the active model's outcomes and advice per opponent class
//   GET  /v1/knowledge/abilities the active model's abilities per opponent class
//   GET  /v1/client/status       { ok, schema, min_plugin, accepted, message, fights, active_model }
//   POST /v1/privacy/delete      { schema, contributor } -> every record under it removed
//   POST /v1/admin/publish       (X-Jambix-Admin) build and publish a model version
//   POST /v1/admin/withdraw      (X-Jambix-Admin) { version } -> withdrawn (the previous active stands: rollback)
//   GET  /v1/admin/evaluate      (X-Jambix-Admin) the model as it would be built, without publishing
//
// Run:  KEY=client-key ADMIN_KEY=admin-key PORT=8787 DATA_DIR=./data node server.js
//       node server.js publish        node server.js withdraw 3
// Put HTTPS in front (a reverse proxy); this speaks plain HTTP. Limits: bodies
// to MAX_BODY, RATE_PER_MINUTE per contributor and per address, records
// older than RETENTION_DAYS purged daily. No address is stored with a record.

const http = require('http');
const fs = require('fs');
const path = require('path');
const { SCHEMA, validateBatch, validateLesson, validateDelete } = require('./validate');
const learn = require('./learn');

const MIN_PLUGIN = '1.8.1';

function vnum(s) {
    const m = String(s || '').match(/(\d+)\.?(\d*)\.?(\d*)/);
    if (!m) return 0;
    return (Number(m[1]) || 0) * 1e6 + (Number(m[2]) || 0) * 1e3 + (Number(m[3]) || 0);
}

function createApp(options) {
    const opts = Object.assign({
        dataDir: process.env.DATA_DIR || path.join(__dirname, 'data'),
        key: process.env.KEY || '',
        adminKey: process.env.ADMIN_KEY || '',
        maxBody: Number(process.env.MAX_BODY) || 256 * 1024,
        ratePerMinute: Number(process.env.RATE_PER_MINUTE) || 60,
        retentionDays: Number(process.env.RETENTION_DAYS) || 180,
        minPlugin: MIN_PLUGIN,
        learn: {},
        now: () => Date.now(),
    }, options || {});

    const dir = opts.dataDir;
    const modelsDir = path.join(dir, 'models');
    fs.mkdirSync(modelsDir, { recursive: true });
    const FILES = {
        batches: path.join(dir, 'batches.jsonl'),
        lessons: path.join(dir, 'lessons.jsonl'),
        ids: path.join(dir, 'ids.json'),
        deletions: path.join(dir, 'deletions.jsonl'),
        manifest: path.join(modelsDir, 'manifest.json'),
    };

    // --- storage --------------------------------------------------------------------
    const readLines = file => {
        if (!fs.existsSync(file)) return [];
        const out = [];
        for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
            if (!line.trim()) continue;
            try { out.push(JSON.parse(line)); } catch (e) { /* a torn line: skipped */ }
        }
        return out;
    };
    const writeLines = (file, rows) => fs.writeFileSync(file, rows.map(r => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
    const append = (file, row) => fs.appendFileSync(file, JSON.stringify(row) + '\n');

    let ids = new Set(fs.existsSync(FILES.ids) ? JSON.parse(fs.readFileSync(FILES.ids, 'utf8')) : []);
    const saveIds = () => {
        const list = Array.from(ids);
        if (list.length > 50000) ids = new Set(list.slice(list.length - 50000));
        fs.writeFileSync(FILES.ids, JSON.stringify(Array.from(ids)));
    };

    const readManifest = () => fs.existsSync(FILES.manifest) ? JSON.parse(fs.readFileSync(FILES.manifest, 'utf8')) : { schema: SCHEMA, versions: [] };
    const writeManifest = m => fs.writeFileSync(FILES.manifest, JSON.stringify(m, null, 2));
    const activeVersion = () => {
        const m = readManifest();
        const active = m.versions.filter(v => v.status === 'active').sort((a, b) => vnum(b.version) - vnum(a.version));
        return active[0] || null;
    };
    const readModel = version => {
        const file = path.join(modelsDir, `v${String(version).replace(/[^0-9a-z.]/gi, '')}.json`);
        return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
    };

    function purge() {
        const cutoff = opts.now() - opts.retentionDays * 86400 * 1000;
        for (const file of [FILES.batches, FILES.lessons]) {
            const rows = readLines(file);
            const kept = rows.filter(r => !r.received_at || Date.parse(r.received_at) >= cutoff);
            if (kept.length !== rows.length) writeLines(file, kept);
        }
    }
    purge();
    const purgeTimer = setInterval(purge, 3600 * 1000);
    purgeTimer.unref();

    // --- the learning engine, published ------------------------------------------------
    function evaluate() {
        return learn.build(readLines(FILES.batches), readLines(FILES.lessons), opts.learn);
    }
    function publish(note) {
        const m = readManifest();
        const next = m.versions.reduce((n, v) => Math.max(n, Number(v.version) || 0), 0) + 1;
        const model = evaluate();
        model.version = String(next);
        fs.writeFileSync(path.join(modelsDir, `v${next}.json`), JSON.stringify(model));
        m.versions.push({ version: String(next), schema: SCHEMA, min_plugin: opts.minPlugin, status: 'active',
            created_at: new Date().toISOString(), fights: model.fights, contributors: model.contributors, note: note || undefined });
        writeManifest(m);
        return model;
    }
    function withdraw(version) {
        const m = readManifest();
        const entry = m.versions.find(v => String(v.version) === String(version));
        if (!entry) return false;
        entry.status = 'withdrawn';
        entry.withdrawn_at = new Date().toISOString();
        writeManifest(m);
        return true;
    }

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

    function accept(req, res, kind, file, validate) {
        readBody(req, res, record => {
            const err = validate(record);
            if (err) return send(res, 400, { error: err });
            if (String(record.contributor) !== String(req.headers['x-jambix-contributor'] || record.contributor)) {
                return send(res, 400, { error: 'contributor header does not match the record' });
            }
            if (ids.has(record.id)) return send(res, 200, { ok: true, duplicate: true });
            record.received_at = new Date(opts.now()).toISOString();
            append(file, record);
            ids.add(record.id);
            saveIds();
            send(res, 200, { ok: true, kind });
        });
    }

    const server = http.createServer((req, res) => {
        const url = new URL(req.url, 'http://x');
        const p = url.pathname;
        if (req.method === 'GET' && p === '/health') return send(res, 200, { ok: true, fights: ids.size });
        if (!p.startsWith('/v1/')) return send(res, 404, { error: 'no such route' });
        if (opts.key && req.headers['x-jambix-key'] !== opts.key) return send(res, 401, { error: 'bad key' });
        const who = String(req.headers['x-jambix-contributor'] || '') || (req.socket && req.socket.remoteAddress) || 'unknown';
        if (!allowed(who) || !allowed('addr:' + (req.socket && req.socket.remoteAddress))) return send(res, 429, { error: 'rate limited' });

        if (p.startsWith('/v1/admin/')) {
            if (!opts.adminKey || req.headers['x-jambix-admin'] !== opts.adminKey) return send(res, 401, { error: 'bad admin key' });
            if (req.method === 'POST' && p === '/v1/admin/publish') {
                return readBody(req, res, body => {
                    const model = publish(body && body.note);
                    send(res, 200, { ok: true, version: model.version, fights: model.fights, contributors: model.contributors });
                });
            }
            if (req.method === 'POST' && p === '/v1/admin/withdraw') {
                return readBody(req, res, body => send(res, withdraw(body && body.version) ? 200 : 404, { ok: true }));
            }
            if (req.method === 'GET' && p === '/v1/admin/evaluate') return send(res, 200, evaluate());
            return send(res, 404, { error: 'no such admin route' });
        }

        if (req.method === 'POST' && p === '/v1/combat/batches') return accept(req, res, 'batch', FILES.batches, validateBatch);
        if (req.method === 'POST' && p === '/v1/lessons') return accept(req, res, 'lesson', FILES.lessons, validateLesson);
        if (req.method === 'GET' && p === '/v1/models/manifest') return send(res, 200, readManifest());
        const mv = p.match(/^\/v1\/models\/([0-9a-z.]+)$/i);
        if (req.method === 'GET' && mv) {
            const entry = readManifest().versions.find(v => String(v.version) === mv[1]);
            if (!entry) return send(res, 404, { error: 'no such model' });
            if (entry.status !== 'active') return send(res, 410, { error: 'withdrawn' });
            const model = readModel(mv[1]);
            return model ? send(res, 200, model) : send(res, 404, { error: 'model file missing' });
        }
        if (req.method === 'GET' && (p === '/v1/knowledge/matchups' || p === '/v1/knowledge/abilities')) {
            const active = activeVersion();
            const model = active && readModel(active.version);
            if (!model) return send(res, 404, { error: 'no active model' });
            const out = { version: model.version, fights: model.fights, by_class: {} };
            for (const [cls, c] of Object.entries(model.by_class)) {
                out.by_class[cls] = p.endsWith('matchups')
                    ? { fights: c.fights, outcomes: c.outcomes, advice: c.advice, patterns: c.patterns }
                    : { fights: c.fights, abilities: c.abilities };
            }
            return send(res, 200, out);
        }
        if (req.method === 'GET' && p === '/v1/client/status') {
            const plugin = url.searchParams.get('plugin') || '';
            const schema = Number(url.searchParams.get('schema') || 0);
            const accepted = schema === SCHEMA && vnum(plugin) >= vnum(opts.minPlugin);
            const active = activeVersion();
            return send(res, 200, {
                ok: true, schema: SCHEMA, min_plugin: opts.minPlugin, accepted,
                message: accepted ? `accepted: plugin ${plugin}, schema ${schema}` : `not accepted: needs plugin ${opts.minPlugin} and schema ${SCHEMA}`,
                fights: ids.size, active_model: active ? active.version : null,
            });
        }
        if (req.method === 'POST' && p === '/v1/privacy/delete') {
            return readBody(req, res, body => {
                const err = validateDelete(body);
                if (err) return send(res, 400, { error: err });
                let removed = 0;
                for (const file of [FILES.batches, FILES.lessons]) {
                    const rows = readLines(file);
                    const kept = rows.filter(r => r.contributor !== body.contributor);
                    removed += rows.length - kept.length;
                    if (kept.length !== rows.length) writeLines(file, kept);
                }
                append(FILES.deletions, { contributor: body.contributor, at: new Date(opts.now()).toISOString(), removed });
                send(res, 200, { ok: true, removed });
            });
        }
        return send(res, 404, { error: 'no such route' });
    });

    return { server, publish, withdraw, evaluate, files: FILES, options: opts, close: () => { clearInterval(purgeTimer); server.close(); } };
}

if (require.main === module) {
    const app = createApp();
    const cmd = process.argv[2];
    if (cmd === 'publish') {
        const model = app.publish(process.argv.slice(3).join(' '));
        console.log(`published model v${model.version}: ${model.fights} fight(s), ${model.contributors} contributor(s), ${model.observations} observation(s)`);
        process.exit(0);
    } else if (cmd === 'withdraw') {
        console.log(app.withdraw(process.argv[3]) ? `withdrawn v${process.argv[3]}` : 'no such version');
        process.exit(0);
    } else {
        const port = Number(process.env.PORT) || 8787;
        app.server.listen(port, () => {
            console.log(`jambix central service on :${port}, data ${app.options.dataDir}, key ${app.options.key ? 'set' : 'NOT SET (anyone may post)'}, admin key ${app.options.adminKey ? 'set' : 'NOT SET (no publishing over http)'}`);
        });
    }
}

module.exports = { createApp, MIN_PLUGIN };

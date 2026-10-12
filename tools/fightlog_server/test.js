'use strict';
// Jambix central service -- the tests: authorisation, invalid data,
// duplicates, rate limiting, privacy deletion, version compatibility, the
// learning engine's thresholds, the body limit. Run: node --test tools/fightlog_server/test.js

const test = require('node:test');
const assert = require('node:assert');
const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createApp } = require('./server');

function start(extra) {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-central-'));
    const app = createApp(Object.assign({ dataDir, key: 'k', adminKey: 'a', ratePerMinute: 1000 }, extra || {}));
    return new Promise(resolve => app.server.listen(0, () => resolve({ app, port: app.server.address().port, dataDir })));
}

function req(port, method, p, body, headers) {
    return new Promise((resolve, reject) => {
        const data = body === undefined ? '' : JSON.stringify(body);
        const r = http.request({ host: '127.0.0.1', port, method, path: p,
            headers: Object.assign({ 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }, headers || {}) },
            res => {
                let out = '';
                res.on('data', c => out += c);
                res.on('end', () => { let v = null; try { v = JSON.parse(out); } catch (e) { v = out; } resolve({ status: res.statusCode, body: v }); });
            });
        r.on('error', reject);
        r.end(data);
    });
}

const KEY = { 'X-Jambix-Key': 'k' };
const ADMIN = { 'X-Jambix-Key': 'k', 'X-Jambix-Admin': 'a' };

function batch(contributor, id, overrides) {
    return Object.assign({
        schema: 1, id, contributor,
        client: { plugin: '1.7.8', game: 'Forever', build: '1.60.1.70338', schema: 1 },
        me: { class: 'HUNTER', level: 26 },
        encounter: { type: 'world_pvp', duration: 42, outcome: 'won' },
        observations: [
            { pattern: 'mobility_when_slowed', enemy_class: 'WARRIOR', p: 0.5, reliability: 0, sure: false, basis: 'session', evidence: 0,
              inputs_ok: true, hit: true, correct: true, t: 4.2, context: { mode: 'world_pvp', threat: 'LOW', me_hp: 4, controlled: false } },
            { pattern: 'mobility_when_slowed', enemy_class: 'WARRIOR', p: 0.667, reliability: 0.33, sure: false, basis: 'recent', evidence: 1,
              inputs_ok: true, hit: true, correct: true, t: 9.0 },
        ],
    }, overrides || {});
}

function lesson(contributor, id, outcome, codes) {
    return {
        schema: 1, id, contributor,
        client: { plugin: '1.7.8', game: 'Forever', build: '1.60.1.70338', schema: 1 },
        me: { class: 'HUNTER', level: 26 },
        encounter: { type: 'world_pvp', duration: 42, outcome },
        enemies: [{ class: 'WARRIOR', role: 'melee', used: { Charge: 1, Hamstring: 2 }, controls_on_me: {}, bursts: 1, trinket: false,
                    hp_min: 0, died: outcome === 'won', fled: false, time_on_me: 30, patterns: { mobility_when_slowed: { hits: 2, total: 2 } } }],
        lessons: codes || [], predictions: { forecasts: 2, right: 2, brier: 0.36 }, baits: { offered: 0, kinds: {} }, holds: 0,
        threat_peak: { level: 'MODERATE', score: 40 },
    };
}

const hex = n => Array.from({ length: n }, (_, i) => '0123456789abcdef'[(i * 7 + n) % 16]).join('');

test('authorisation: no key or a wrong key is refused, /health is open, admin routes need the admin key', async () => {
    const { app, port } = await start();
    try {
        assert.strictEqual((await req(port, 'GET', '/health')).status, 200);
        assert.strictEqual((await req(port, 'GET', '/v1/models/manifest')).status, 401);
        assert.strictEqual((await req(port, 'GET', '/v1/models/manifest', undefined, { 'X-Jambix-Key': 'wrong' })).status, 401);
        assert.strictEqual((await req(port, 'GET', '/v1/models/manifest', undefined, KEY)).status, 200);
        assert.strictEqual((await req(port, 'POST', '/v1/admin/publish', {}, KEY)).status, 401);
        assert.strictEqual((await req(port, 'GET', '/v1/admin/evaluate', undefined, ADMIN)).status, 200);
    } finally { app.close(); }
});

test('invalid data is refused with the reason: a wrong schema, a missing field, a forbidden name, an unknown pattern', async () => {
    const { app, port } = await start();
    try {
        let r = await req(port, 'POST', '/v1/combat/batches', batch(hex(24), hex(20), { schema: 2 }), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /schema 2/);
        r = await req(port, 'POST', '/v1/combat/batches', batch(hex(24), hex(20), { me: { class: 'MONK' } }), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /me.class/);
        const withName = batch(hex(24), hex(20)); withName.me.name = 'Dutansi';
        r = await req(port, 'POST', '/v1/combat/batches', withName, KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /forbidden field batch.me.name/);
        const badPattern = batch(hex(24), hex(20)); badPattern.observations[0].pattern = 'reads_minds';
        r = await req(port, 'POST', '/v1/combat/batches', badPattern, KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /pattern unknown/);
        r = await req(port, 'POST', '/v1/lessons', lesson(hex(24), hex(20), 'won', ['made_up']), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /lesson code made_up/);
        r = await req(port, 'POST', '/v1/combat/batches', 'not json at all', KEY);
        assert.strictEqual(r.status, 400);
        assert.strictEqual(fs.existsSync(app.files.batches), false, 'nothing stored');
    } finally { app.close(); }
});

test('a valid batch is stored once: the same id again is a duplicate, not a second record', async () => {
    const { app, port } = await start();
    try {
        const b = batch(hex(24), hex(20));
        let r = await req(port, 'POST', '/v1/combat/batches', b, KEY);
        assert.deepStrictEqual(r.body, { ok: true, kind: 'batch' });
        r = await req(port, 'POST', '/v1/combat/batches', b, KEY);
        assert.deepStrictEqual(r.body, { ok: true, duplicate: true });
        const rows = fs.readFileSync(app.files.batches, 'utf8').trim().split('\n');
        assert.strictEqual(rows.length, 1);
        assert.ok(JSON.parse(rows[0]).received_at, 'stamped when received');
        assert.strictEqual(JSON.parse(rows[0]).ip, undefined, 'no address stored');
    } finally { app.close(); }
});

test('the body limit and the rate limit refuse politely', async () => {
    const { app, port } = await start({ ratePerMinute: 3, maxBody: 2048 });
    try {
        const big = batch(hex(24), hex(20)); big.censored = 'x'.repeat(100); big.observations = Array.from({ length: 30 }, () => big.observations[0]);
        assert.strictEqual((await req(port, 'POST', '/v1/combat/batches', big, KEY)).status, 413);
        const h = Object.assign({ 'X-Jambix-Contributor': hex(24) }, KEY);
        for (let i = 0; i < 3; i++) await req(port, 'GET', '/v1/models/manifest', undefined, h);
        assert.strictEqual((await req(port, 'GET', '/v1/models/manifest', undefined, h)).status, 429);
    } finally { app.close(); }
});

test('privacy: a deletion request removes every record under the contributor and is recorded', async () => {
    const { app, port } = await start();
    try {
        const me = hex(24), other = 'f'.repeat(24);
        await req(port, 'POST', '/v1/combat/batches', batch(me, '1'.repeat(20)), KEY);
        await req(port, 'POST', '/v1/lessons', lesson(me, '2'.repeat(20), 'won'), KEY);
        await req(port, 'POST', '/v1/lessons', lesson(other, '3'.repeat(20), 'lost'), KEY);
        const r = await req(port, 'POST', '/v1/privacy/delete', { schema: 1, contributor: me }, KEY);
        assert.deepStrictEqual(r.body, { ok: true, removed: 2 });
        const left = fs.readFileSync(app.files.lessons, 'utf8').trim().split('\n').map(JSON.parse);
        assert.strictEqual(left.length, 1); assert.strictEqual(left[0].contributor, other);
        assert.strictEqual(fs.readFileSync(app.files.batches, 'utf8').trim(), '');
        assert.ok(fs.readFileSync(app.files.deletions, 'utf8').includes(me));
        assert.strictEqual((await req(port, 'POST', '/v1/privacy/delete', { schema: 1, contributor: 'short' }, KEY)).status, 400);
    } finally { app.close(); }
});

test('versions: the gates refuse an empty database and say why; a forced publish makes an active model and is written as forced; withdraw marks it and the previous active stands; a withdrawn model answers 410; the client status checks the plugin', async () => {
    const { app, port } = await start();
    try {
        let r = await req(port, 'POST', '/v1/admin/publish', { note: 'first' }, ADMIN);
        assert.strictEqual(r.body.decision, 'reject'); assert.strictEqual(r.body.version, null);
        assert.deepStrictEqual(r.body.failed, ['contributors', 'content']);
        assert.ok(r.body.checks.find(c => c.name === 'holdout' && c.pass === null), 'the holdout gate skipped on nothing and said so');
        r = await req(port, 'POST', '/v1/admin/publish', { note: 'first', force: true }, ADMIN);
        assert.strictEqual(r.body.decision, 'forced'); assert.strictEqual(r.body.version, '1');
        r = await req(port, 'POST', '/v1/admin/publish', { force: true }, ADMIN);
        assert.strictEqual(r.body.version, '2');
        let m = (await req(port, 'GET', '/v1/models/manifest', undefined, KEY)).body;
        assert.deepStrictEqual(m.versions.map(v => [v.version, v.status, v.schema, v.min_plugin]), [['1', 'active', 1, '1.7.8'], ['2', 'active', 1, '1.7.8']]);
        assert.strictEqual(m.versions[0].gates.forced, true); assert.strictEqual(m.versions[0].stage, 'full');
        // v1 holds no fight: it is no production to stage behind or roll back to (the live empty v1 of 2026-10-12).
        assert.strictEqual(m.versions[1].stage, 'full', 'an empty production: the next version goes to everyone');
        assert.strictEqual(m.versions[1].rollout, 100); assert.strictEqual(m.versions[1].rollback, null);
        const audit = (await req(port, 'GET', '/v1/admin/audit', undefined, ADMIN)).body.rows;
        assert.deepStrictEqual(audit.map(a => [a.kind, a.action || a.forced]), [['cycle', 'reject'], ['publish', true], ['publish', true]]);
        assert.strictEqual((await req(port, 'POST', '/v1/admin/promote', { version: '2' }, ADMIN)).status, 200);
        assert.strictEqual((await req(port, 'GET', '/v1/models/manifest', undefined, KEY)).body.versions[1].stage, 'full');
        assert.strictEqual((await req(port, 'GET', '/v1/models/2', undefined, KEY)).body.version, '2');
        r = await req(port, 'POST', '/v1/admin/withdraw', { version: '2' }, ADMIN);
        assert.strictEqual(r.status, 200);
        m = (await req(port, 'GET', '/v1/models/manifest', undefined, KEY)).body;
        assert.strictEqual(m.versions[1].status, 'withdrawn');
        assert.strictEqual((await req(port, 'GET', '/v1/models/2', undefined, KEY)).status, 410);
        assert.strictEqual((await req(port, 'GET', '/v1/models/9', undefined, KEY)).status, 404);
        const status = (await req(port, 'GET', '/v1/client/status?plugin=1.7.8&schema=1', undefined, KEY)).body;
        assert.strictEqual(status.accepted, true); assert.strictEqual(status.active_model, '1');
        assert.strictEqual((await req(port, 'GET', '/v1/client/status?plugin=1.7.6&schema=1', undefined, KEY)).body.accepted, false);
        assert.strictEqual((await req(port, 'GET', '/v1/client/status?plugin=1.7.8&schema=2', undefined, KEY)).body.accepted, false);
    } finally { app.close(); }
});

test('the learning engine: a pattern backed by several contributors with verified inputs is offered; one contributor or too few chances is marked unreliable and says why; the matchup advice tells won from lost', async () => {
    const { app, port } = await start({ learn: { minChances: 4, minContributors: 2, minEff: 2, minLessonFights: 2 } });
    try {
        const c1 = '1'.repeat(24), c2 = '2'.repeat(24), c3 = '3'.repeat(24);
        let n = 0;
        const id = () => (++n).toString(16).padStart(20, '0');
        for (const c of [c1, c2, c3]) {
            const fight = id();
            await req(port, 'POST', '/v1/combat/batches', batch(c, id(), { fight }), KEY);
            await req(port, 'POST', '/v1/lessons', Object.assign(lesson(c, id(), c === c3 ? 'lost' : 'won', c === c3 ? ['trap_unused'] : ['trap_won']), { fight }), KEY);
        }
        // One contributor's rogue, two chances: not enough.
        const rogue = batch(c1, id());
        rogue.observations = [{ pattern: 'interrupts_casts', enemy_class: 'ROGUE', p: 0.5, reliability: 0, sure: false, basis: 'session', evidence: 0, inputs_ok: false, hit: true, correct: true }];
        await req(port, 'POST', '/v1/combat/batches', rogue, KEY);
        const model = (await req(port, 'POST', '/v1/admin/publish', { force: true }, ADMIN)).body;
        const full = (await req(port, 'GET', '/v1/models/' + model.version, undefined, KEY)).body;
        const w = full.games.Forever.by_class.WARRIOR.patterns.mobility_when_slowed;
        assert.strictEqual(w.chances, 6); assert.strictEqual(w.contributors, 3); assert.ok(w.p > 0.8 && w.p < 1, `shrunk toward 0.5: ${w.p}`);
        assert.strictEqual(w.unreliable, false, w.why);
        assert.ok(w.brier < 0.3);
        assert.ok(w.interval[0] < w.p && w.interval[1] >= w.p, 'the interval');
        const r = full.games.Forever.by_class.ROGUE.patterns.interrupts_casts;
        assert.strictEqual(r.unreliable, true);
        assert.match(r.why, /0.5 weighted chance\(s\), needs 4/, 'unverified inputs weigh half'); assert.match(r.why, /1 contributor\(s\), needs 2/); assert.match(r.why, /verified inputs/);
        const matchups = (await req(port, 'GET', '/v1/knowledge/matchups?game=Forever', undefined, KEY)).body;
        assert.deepStrictEqual(matchups.games.Forever.by_class.WARRIOR.outcomes, { won: 2, lost: 1 });
        const advice = matchups.games.Forever.by_class.WARRIOR.advice;
        assert.ok(advice.find(a => a.code === 'trap_unused' && a.lost === 1 && a.won === 0), 'the trap never laid told lost fights');
        assert.ok(advice.find(a => a.code === 'trap_won' && a.won === 1), 'the trap laid told won ones');
        const abilities = (await req(port, 'GET', '/v1/knowledge/abilities', undefined, KEY)).body;
        assert.strictEqual(abilities.games.Forever.by_class.WARRIOR.abilities.Hamstring.per_fight, 2);
        assert.strictEqual(abilities.games.Forever.by_class.WARRIOR.abilities.Hamstring.verified, true, 'seen by several contributors');
        assert.ok(full.evaluation.mobility_when_slowed.bands.mid.n >= 3, 'the calibration bands');
        const tactics = (await req(port, 'GET', '/v1/knowledge/tactics', undefined, KEY)).body;
        assert.deepStrictEqual(tactics.games.Forever.tactics, [], 'no episodes: no tactics');
        assert.ok(full.release.known_limitations.some(l => /association/.test(l)));
        assert.ok(Object.keys(full.games.Forever.groups).includes('g:Forever|me:HUNTER|e:WARRIOR|lv:20-29|enc:world_pvp|1v1'), 'the exact level, the combat read off the lesson\'s one enemy');
    } finally { app.close(); }
});

function episode(id, type, result, followed, extra) {
    return Object.assign({
        id, type, enemy_class: 'WARRIOR', t: 12, horizon: 5,
        trigger: { text: 'the player Intercept at 20 yd', observed: true, source: 'event' },
        before: { hp: 1, zone: 'ranged', gap: 20, threat: 'LOW', attackers: 1, controlled: false, defensives_ready: 2 },
        after: { hp: 0.9, zone: 'ranged', gap: 22, threat: 'LOW', attackers: 0, controlled: false, defensives_ready: 2 },
        prediction: { pattern: 'mobility_when_slowed', p: 0.75, reliability: 0.5, sure: true, outcome: 'HIT' },
        recommendation: { action: 'Wing Clip', move: 'increase', outcome: followed ? 'FOLLOWED' : 'NOT_FOLLOWED' },
        actions: followed ? ['Wing Clip'] : [], moved: true,
        result: { primary: result, all: [result] },
        quality: { unattributed: false, feeds_missing: false, incomplete: false, guess_only: false, unsupported: false, test_data: false },
        lesson: { confidence: 'candidate', candidate: 'when a melee player closes the gap...' },
    }, extra || {});
}

test('episodes: a valid one is stored; an unknown type, an unknown result and test data are refused with the reason', async () => {
    const { app, port } = await start();
    try {
        const ok = batch(hex(24), hex(20), { episodes: [episode('a'.repeat(20), 'gap_close_attempt', 'SURVIVAL_IMPROVED', true)] });
        assert.strictEqual((await req(port, 'POST', '/v1/combat/batches', ok, KEY)).status, 200);
        let r = await req(port, 'POST', '/v1/combat/batches', batch(hex(24), 'b'.repeat(20), { episodes: [episode('a'.repeat(20), 'reads_minds', 'SURVIVAL_IMPROVED', true)] }), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /episodes\[0\].type unknown/);
        r = await req(port, 'POST', '/v1/combat/batches', batch(hex(24), 'c'.repeat(20), { episodes: [episode('a'.repeat(20), 'blink', 'WON', true)] }), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /result.primary unknown/);
        const testData = episode('a'.repeat(20), 'blink', 'NO_MEASURABLE_CHANGE', true); testData.quality.test_data = true;
        r = await req(port, 'POST', '/v1/combat/batches', batch(hex(24), 'd'.repeat(20), { episodes: [testData] }), KEY);
        assert.strictEqual(r.status, 400); assert.match(r.body.error, /is test data/);
    } finally { app.close(); }
});

test('the learning engine validates an episode lesson only with enough comparable episodes from enough contributors agreeing', async () => {
    const { app, port } = await start({ learn: { minEpisodes: 4, minContributors: 2, agree: 0.6 } });
    try {
        let n = 0;
        const id = () => (++n).toString(16).padStart(20, '0');
        const c1 = '1'.repeat(24), c2 = '2'.repeat(24);
        for (const c of [c1, c2]) {
            await req(port, 'POST', '/v1/combat/batches', batch(c, id(), { episodes: [
                episode(id(), 'gap_close_attempt', 'POSITION_IMPROVED', true), episode(id(), 'gap_close_attempt', 'POSITION_IMPROVED', true),
                episode(id(), 'gap_close_attempt', 'SITUATION_WORSENED', false),
            ] }), KEY);
        }
        await req(port, 'POST', '/v1/combat/batches', batch(c1, id(), { episodes: [episode(id(), 'blink', 'NO_MEASURABLE_CHANGE', false)] }), KEY);
        const model = (await req(port, 'POST', '/v1/admin/publish', { force: true }, ADMIN)).body;
        const full = (await req(port, 'GET', '/v1/models/' + model.version, undefined, KEY)).body;
        assert.strictEqual(full.episodes, 7, 'seven episodes aggregated');
        const w = full.games.Forever.by_class.WARRIOR;
        assert.strictEqual(w.episodes.gap_close_attempt.n, 6);
        assert.deepStrictEqual(w.episodes.gap_close_attempt.results, { POSITION_IMPROVED: 4, SITUATION_WORSENED: 2 });
        assert.deepStrictEqual(w.episodes.gap_close_attempt.when_followed, { POSITION_IMPROVED: 4 });
        assert.deepStrictEqual(w.episodes.gap_close_attempt.when_not_followed, { SITUATION_WORSENED: 2 });
        const lesson = w.episode_lessons.find(l => l.type === 'gap_close_attempt');
        assert.strictEqual(lesson.validated, true, lesson.why);
        assert.strictEqual(lesson.result, 'POSITION_IMPROVED');
        assert.strictEqual(lesson.when_followed, 1); assert.strictEqual(lesson.when_not_followed, 0);
        assert.match(lesson.text, /position improved in 67% of 6 episode/);
        const blink = w.episode_lessons.find(l => l.type === 'blink');
        assert.strictEqual(blink.validated, false);
        assert.match(blink.why, /1 measured episode\(s\), needs 4/); assert.match(blink.why, /1 contributor\(s\), needs 2/);
    } finally { app.close(); }
});

test('retention: records older than the retention window are purged', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-central-'));
    const old = Object.assign(batch(hex(24), hex(20)), { received_at: new Date(Date.now() - 400 * 86400 * 1000).toISOString() });
    const fresh = Object.assign(batch(hex(24), 'a'.repeat(20)), { received_at: new Date().toISOString() });
    fs.writeFileSync(path.join(dataDir, 'batches.jsonl'), JSON.stringify(old) + '\n' + JSON.stringify(fresh) + '\n');
    const app = createApp({ dataDir, key: 'k', retentionDays: 180 });
    try {
        const rows = fs.readFileSync(app.files.batches, 'utf8').trim().split('\n');
        assert.strictEqual(rows.length, 1);
        assert.strictEqual(JSON.parse(rows[0]).id, 'a'.repeat(20));
    } finally { app.close(); }
});

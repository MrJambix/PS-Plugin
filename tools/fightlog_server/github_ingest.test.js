'use strict';
// The GitHub ingest: an issue's fenced JSON becomes a record under the same
// bounds as the HTTP service; accepted ones are filed and the issue closed
// with a word, refused ones closed with the reason, duplicates noted,
// deletions honoured; publish writes a model and the manifest.
// Run: node --test tools/fightlog_server/github_ingest.test.js

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createStore, parseIssue, ingest } = require('./github_ingest');

const hex = n => Array.from({ length: n }, (_, i) => '0123456789abcdef'[(i * 7 + n) % 16]).join('');

function batch(contributor, id) {
    return { schema: 1, id, contributor, client: { plugin: '1.7.8', game: 'Forever', build: '1.60.1.70338', schema: 1 },
        me: { class: 'HUNTER', level: 26 }, encounter: { type: 'world_pvp', duration: 30, outcome: 'won' },
        observations: [{ pattern: 'mobility_when_slowed', enemy_class: 'WARRIOR', p: 0.5, reliability: 0, sure: false, basis: 'session',
            evidence: 0, inputs_ok: true, hit: true, correct: true }] };
}
const issue = (number, title, record) => ({ number, title, body: 'From a client\n```json\n' + JSON.stringify(record) + '\n```' });

function fakeApi(issues) {
    const api = { comments: [], closed: [], listIssues: async () => issues,
        comment: async (n, text) => { api.comments.push([n, text]); }, close: async n => { api.closed.push(n); } };
    return api;
}

test('an issue is parsed from its title and fenced body; a stray issue is not', () => {
    const b = batch(hex(24), hex(20));
    assert.deepStrictEqual(parseIssue(issue(1, `jambix-batch ${b.id}`, b)), { kind: 'batch', record: b });
    assert.deepStrictEqual(parseIssue({ title: 'Bug: the trap', body: 'hello' }), { error: 'not a jambix issue' });
    assert.deepStrictEqual(parseIssue({ title: 'jambix-lesson abc123', body: '```json\nnot json\n```' }), { kind: 'lesson', error: 'the body is not JSON' });
});

test('ingest: accepted, refused with the reason, a duplicate, a deletion; every issue closed; the files hold what was accepted', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-ingest-'));
    const store = createStore(dataDir);
    const me = hex(24);
    const good = batch(me, '1'.repeat(20));
    const bad = batch(me, '2'.repeat(20)); bad.me.name = 'Dutansi';
    const issues = [
        issue(1, `jambix-batch ${good.id}`, good),
        issue(2, `jambix-batch ${bad.id}`, bad),
        issue(3, `jambix-batch ${good.id}`, good),
        { number: 4, title: 'jambix-lesson zzz', body: 'no fence here' },
        issue(5, `jambix-delete ${me}`, { schema: 1, contributor: me }),
    ];
    const api = fakeApi(issues);
    const s = await ingest(store, api);
    assert.deepStrictEqual(s, { seen: 5, accepted: 2, refused: 2, duplicates: 1, deletions: 1 });
    assert.deepStrictEqual(api.closed, [1, 2, 3, 4, 5]);
    assert.deepStrictEqual(api.comments, [
        [1, 'accepted'], [2, 'refused: forbidden field batch.me.name'], [3, 'accepted (duplicate)'],
        [4, 'refused: the body is not JSON'], [5, 'accepted: 1 record(s) removed'],
    ]);
    assert.strictEqual(fs.readFileSync(store.files.batches, 'utf8').trim(), '', 'the deletion emptied it');
    assert.ok(fs.readFileSync(store.files.deletions, 'utf8').includes(me));
});

test('publish is a gated learning cycle: one contributor is rejected and only the evaluation and the audit are written; forced, it writes the model and the manifest as forced; promote and withdraw mark a version', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-ingest-'));
    const store = createStore(dataDir);
    const api = fakeApi([issue(1, 'jambix-batch ' + '3'.repeat(20), batch(hex(24), '3'.repeat(20)))]);
    await ingest(store, api);
    let r = store.publish('first');
    assert.strictEqual(r.decision, 'reject'); assert.strictEqual(r.version, null);
    assert.deepStrictEqual(r.verdict.failed, ['contributors', 'content']);
    assert.strictEqual(store.readManifest().versions.length, 0);
    assert.ok(fs.existsSync(path.join(dataDir, 'models', 'evaluations.jsonl')));
    assert.ok(fs.existsSync(path.join(dataDir, 'audit.jsonl')));
    r = store.publish('first', { force: true });
    assert.strictEqual(r.decision, 'forced'); assert.strictEqual(r.version, '1');
    assert.strictEqual(r.candidate.fights, 1);
    const manifest = store.readManifest();
    assert.strictEqual(manifest.versions[0].status, 'active');
    assert.strictEqual(manifest.versions[0].min_plugin, '1.7.8');
    assert.strictEqual(manifest.versions[0].gates.forced, true);
    assert.ok(fs.existsSync(path.join(dataDir, 'models', 'v1.json')));
    const ev = store.evaluate();
    assert.strictEqual(ev.verdict.decision, 'reject', 'still one contributor');
    assert.match(ev.verdict.material.why, /0 fight\(s\) since v1/);
    assert.strictEqual(store.promote('1'), true);
    assert.strictEqual(store.withdraw('1'), true);
    assert.strictEqual(store.readManifest().versions[0].status, 'withdrawn');
    assert.strictEqual(store.withdraw('9'), false);
});

test('an empty table in either shape (live 2026-10-12): an episode\'s "actions": {} and a lesson\'s "controls_on_me": [] are taken, stored in the shape the field has, and the learner reads them', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-ingest-'));
    const store = createStore(dataDir);
    const me = hex(24);
    const b = batch(me, '4'.repeat(20));
    b.observations = {};                                   // the client's own encoder: an empty list as {}
    b.episodes = [{ id: '5'.repeat(20), type: 'gap_close_attempt', enemy_class: 'ROGUE', t: 3, horizon: 5,
        trigger: { text: 'the player Sprint', observed: true, source: 'event' },
        before: { hp: 1, attackers: 1, controlled: false }, after: { hp: 0.9, attackers: 1, controlled: false },
        prediction: { outcome: 'NONE' }, recommendation: { outcome: 'UNKNOWN' }, actions: {}, moved: false,
        result: { primary: 'NO_MEASURABLE_CHANGE', all: {} }, quality: { test_data: false } }];
    const l = { schema: 1, id: '6'.repeat(20), contributor: me, client: b.client, me: b.me, encounter: b.encounter,
        enemies: [{ class: 'ROGUE', role: 'melee', used: [], controls_on_me: [], bursts: 0, hp_min: 1 }],   // JCore's encoder: an empty map as []
        lessons: [] };
    const api = fakeApi([issue(1, 'jambix-batch ' + b.id, b), issue(2, 'jambix-lesson ' + l.id, l)]);
    const s = await ingest(store, api);
    assert.deepStrictEqual(api.comments, [[1, 'accepted'], [2, 'accepted']]);
    assert.strictEqual(s.accepted, 2);
    const stored = store.batches()[0];
    assert.deepStrictEqual(stored.observations, []); assert.deepStrictEqual(stored.episodes[0].actions, []); assert.deepStrictEqual(stored.episodes[0].result.all, []);
    const lesson = store.lessons()[0];
    assert.deepStrictEqual(lesson.enemies[0].used, {}); assert.deepStrictEqual(lesson.enemies[0].controls_on_me, {});
    // A non-empty value of the wrong shape is still refused.
    const bad = batch(me, '7'.repeat(20)); bad.observations = { a: 1 };
    const api2 = fakeApi([issue(3, 'jambix-batch ' + bad.id, bad)]);
    await ingest(store, api2);
    assert.match(api2.comments[0][1], /refused: observations must be a list/);
    // And the learner reads what was stored, and an older record stored in the wrong empty shape.
    const learn = require('./learn');
    const m = learn.build([...store.batches(), Object.assign({}, b, { id: '8'.repeat(20), fight: '8'.repeat(20), observations: {}, episodes: {} })], store.lessons());
    assert.ok(m.games.Forever, 'built');
});

test('one issue per fight: "jambix-fight" carries the lesson and the batch; both are filed, the same issue again is a duplicate, a bad lesson refuses the whole fight with the reason', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-ingest-'));
    const store = createStore(dataDir);
    const me = hex(24);
    const b = batch(me, 'a'.repeat(24));
    const l = { schema: 1, id: 'b'.repeat(24), contributor: me, client: b.client, me: b.me, encounter: b.encounter,
        enemies: [{ class: 'WARRIOR', role: 'melee', used: {}, controls_on_me: {}, bursts: 0, hp_min: 0.5 }], lessons: [] };
    const f = { schema: 1, id: 'c'.repeat(24), contributor: me, lesson: l, batch: b };
    const bad = { schema: 1, id: 'd'.repeat(24), contributor: me, lesson: Object.assign({}, l, { id: 'e'.repeat(24), lessons: ['made_up'] }) };
    const api = fakeApi([issue(1, 'jambix-fight ' + f.id, f), issue(2, 'jambix-fight ' + f.id, f), issue(3, 'jambix-fight ' + bad.id, bad)]);
    const s = await ingest(store, api);
    assert.deepStrictEqual(api.comments, [[1, 'accepted'], [2, 'accepted (duplicate)'], [3, 'refused: lesson: lesson code made_up unknown']]);
    assert.strictEqual(s.accepted, 1);
    assert.strictEqual(store.batches().length, 1);
    assert.strictEqual(store.lessons().length, 1);
    // A fight with no batch (no forecast, no episode): the lesson alone.
    const lone = { schema: 1, id: 'f'.repeat(24), contributor: me, lesson: Object.assign({}, l, { id: '9'.repeat(24) }) };
    const api2 = fakeApi([issue(4, 'jambix-fight ' + lone.id, lone)]);
    await ingest(store, api2);
    assert.deepStrictEqual(api2.comments, [[4, 'accepted']]);
    assert.strictEqual(store.lessons().length, 2);
});

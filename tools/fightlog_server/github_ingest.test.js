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
    return { schema: 1, id, contributor, client: { plugin: '1.8.1', game: 'Forever', build: '1.60.1.70338', schema: 1 },
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
    const s = await ingest(store, api, Date.now());
    assert.deepStrictEqual(s, { seen: 5, accepted: 2, refused: 2, duplicates: 1, deletions: 1 });
    assert.deepStrictEqual(api.closed, [1, 2, 3, 4, 5]);
    assert.deepStrictEqual(api.comments, [
        [1, 'accepted'], [2, 'refused: forbidden field batch.me.name'], [3, 'accepted (duplicate)'],
        [4, 'refused: the body is not JSON'], [5, 'accepted: 1 record(s) removed'],
    ]);
    assert.strictEqual(fs.readFileSync(store.files.batches, 'utf8').trim(), '', 'the deletion emptied it');
    assert.ok(fs.readFileSync(store.files.deletions, 'utf8').includes(me));
});

test('publish writes the model and the manifest; withdraw marks a version', async () => {
    const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-ingest-'));
    const store = createStore(dataDir);
    const api = fakeApi([issue(1, 'jambix-batch ' + '3'.repeat(20), batch(hex(24), '3'.repeat(20)))]);
    await ingest(store, api, Date.now());
    const model = store.publish('first');
    assert.strictEqual(model.version, '1');
    assert.strictEqual(model.fights, 1);
    const manifest = store.readManifest();
    assert.strictEqual(manifest.versions[0].status, 'active');
    assert.strictEqual(manifest.versions[0].min_plugin, '1.8.1');
    assert.ok(fs.existsSync(path.join(dataDir, 'models', 'v1.json')));
    assert.strictEqual(store.withdraw('1'), true);
    assert.strictEqual(store.readManifest().versions[0].status, 'withdrawn');
    assert.strictEqual(store.withdraw('9'), false);
});

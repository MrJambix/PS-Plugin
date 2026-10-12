#!/usr/bin/env node
'use strict';
// Jambix central service on GitHub -- the repository as the database
// (CENTRAL_NETWORK.md §9). The clients open issues ("jambix-batch <id>",
// "jambix-lesson <id>", "jambix-delete <contributor>", a fenced JSON body);
// this script, run by the repository's Action, validates each one with the
// same bounds as the HTTP service (validate.js), files the accepted ones in
// the data branch's JSONL files, answers and closes the issue; on a
// schedule it publishes a model version (learn.js) into data/models/.
//
//   node github_ingest.js ingest            open issues -> data files (GITHUB_TOKEN, GITHUB_REPOSITORY, DATA_DIR)
//   node github_ingest.js publish [note]    data files -> data/models/vN.json + manifest.json
//   node github_ingest.js withdraw N        the version marked withdrawn (the previous active stands)
//
// Nothing here needs the game; nothing here runs in it.

const fs = require('fs');
const path = require('path');
const { SCHEMA, validateBatch, validateLesson, validateDelete } = require('./validate');
const learn = require('./learn');

const MIN_PLUGIN = process.env.MIN_PLUGIN || '1.8.1';
const RETENTION_DAYS = Number(process.env.RETENTION_DAYS) || 180;

// --- the GitHub API, minimal, through fetch (Node 18+) ---------------------------------
function githubApi(repo, token) {
    const base = `https://api.github.com/repos/${repo}`;
    const headers = { 'Authorization': `Bearer ${token}`, 'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'jambix-central-ingest' };
    async function call(method, p, body) {
        const r = await fetch(base + p, { method, headers: Object.assign({ 'Content-Type': 'application/json' }, headers),
            body: body === undefined ? undefined : JSON.stringify(body) });
        if (!r.ok) throw new Error(`${method} ${p}: ${r.status} ${await r.text()}`);
        return r.status === 204 ? null : r.json();
    }
    return {
        async listIssues() {
            const out = [];
            for (let page = 1; page <= 20; page++) {
                const batch = await call('GET', `/issues?state=open&per_page=100&page=${page}&labels=jambix`);
                out.push(...batch.filter(i => !i.pull_request));
                if (batch.length < 100) break;
            }
            return out;
        },
        comment: (number, text) => call('POST', `/issues/${number}/comments`, { body: text }),
        close: number => call('PATCH', `/issues/${number}`, { state: 'closed', state_reason: 'completed' }),
    };
}

// --- the data files -------------------------------------------------------------------------
function createStore(dataDir) {
    fs.mkdirSync(path.join(dataDir, 'models'), { recursive: true });
    const files = {
        batches: path.join(dataDir, 'batches.jsonl'), lessons: path.join(dataDir, 'lessons.jsonl'),
        ids: path.join(dataDir, 'ids.json'), deletions: path.join(dataDir, 'deletions.jsonl'),
        manifest: path.join(dataDir, 'models', 'manifest.json'),
    };
    const readLines = f => fs.existsSync(f) ? fs.readFileSync(f, 'utf8').split('\n').filter(l => l.trim()).map(l => { try { return JSON.parse(l); } catch (e) { return null; } }).filter(Boolean) : [];
    const writeLines = (f, rows) => fs.writeFileSync(f, rows.map(r => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
    const ids = new Set(fs.existsSync(files.ids) ? JSON.parse(fs.readFileSync(files.ids, 'utf8')) : []);
    const saveIds = () => fs.writeFileSync(files.ids, JSON.stringify(Array.from(ids).slice(-50000)));
    const readManifest = () => fs.existsSync(files.manifest) ? JSON.parse(fs.readFileSync(files.manifest, 'utf8')) : { schema: SCHEMA, versions: [] };
    const writeManifest = m => fs.writeFileSync(files.manifest, JSON.stringify(m, null, 2));
    return {
        files, readLines, writeLines, ids, saveIds, readManifest, writeManifest,
        append(file, row) { fs.appendFileSync(file, JSON.stringify(row) + '\n'); },
        purge(now) {
            const cutoff = (now || Date.now()) - RETENTION_DAYS * 86400 * 1000;
            for (const f of [files.batches, files.lessons]) {
                const rows = readLines(f);
                const kept = rows.filter(r => !r.received_at || Date.parse(r.received_at) >= cutoff);
                if (kept.length !== rows.length) writeLines(f, kept);
            }
        },
        publish(note) {
            const m = readManifest();
            const next = m.versions.reduce((n, v) => Math.max(n, Number(v.version) || 0), 0) + 1;
            const model = learn.build(readLines(files.batches), readLines(files.lessons));
            model.version = String(next);
            fs.writeFileSync(path.join(dataDir, 'models', `v${next}.json`), JSON.stringify(model));
            m.versions.push({ version: String(next), schema: SCHEMA, min_plugin: MIN_PLUGIN, status: 'active',
                created_at: new Date().toISOString(), fights: model.fights, contributors: model.contributors, note: note || undefined });
            writeManifest(m);
            return model;
        },
        withdraw(version) {
            const m = readManifest();
            const e = m.versions.find(v => String(v.version) === String(version));
            if (!e) return false;
            e.status = 'withdrawn';
            e.withdrawn_at = new Date().toISOString();
            writeManifest(m);
            return true;
        },
    };
}

// --- one issue -> one record ---------------------------------------------------------------
function parseIssue(issue) {
    const m = String(issue.title || '').match(/^jambix-(batch|lesson|delete)\b/i);
    if (!m) return { error: 'not a jambix issue' };
    const kind = m[1].toLowerCase();
    const body = String(issue.body || '');
    const fence = body.match(/```json\s*([\s\S]*?)```/) || body.match(/```\s*([\s\S]*?)```/);
    const text = fence ? fence[1] : body;
    let record;
    try { record = JSON.parse(text); } catch (e) { return { kind, error: 'the body is not JSON' }; }
    return { kind, record };
}

function ingestOne(store, issue, now) {
    const { kind, record, error } = parseIssue(issue);
    if (error) return { accepted: false, kind, reason: error };
    if (kind === 'delete') {
        const err = validateDelete(record);
        if (err) return { accepted: false, kind, reason: err };
        let removed = 0;
        for (const f of [store.files.batches, store.files.lessons]) {
            const rows = store.readLines(f);
            const kept = rows.filter(r => r.contributor !== record.contributor);
            removed += rows.length - kept.length;
            if (kept.length !== rows.length) store.writeLines(f, kept);
        }
        store.append(store.files.deletions, { contributor: record.contributor, at: new Date(now || Date.now()).toISOString(), removed });
        return { accepted: true, kind, removed };
    }
    const err = kind === 'batch' ? validateBatch(record) : validateLesson(record);
    if (err) return { accepted: false, kind, reason: err };
    if (store.ids.has(record.id)) return { accepted: true, kind, duplicate: true };
    record.received_at = new Date(now || Date.now()).toISOString();
    store.append(kind === 'batch' ? store.files.batches : store.files.lessons, record);
    store.ids.add(record.id);
    store.saveIds();
    return { accepted: true, kind };
}

async function ingest(store, api, now) {
    const issues = await api.listIssues();
    const summary = { seen: issues.length, accepted: 0, refused: 0, duplicates: 0, deletions: 0 };
    for (const issue of issues) {
        const r = ingestOne(store, issue, now);
        if (r.accepted) {
            if (r.duplicate) summary.duplicates += 1; else summary.accepted += 1;
            if (r.kind === 'delete') summary.deletions += 1;
            await api.comment(issue.number, r.kind === 'delete' ? `accepted: ${r.removed} record(s) removed` : `accepted${r.duplicate ? ' (duplicate)' : ''}`);
        } else {
            summary.refused += 1;
            await api.comment(issue.number, `refused: ${r.reason}`);
        }
        await api.close(issue.number);
    }
    store.purge(now);
    return summary;
}

if (require.main === module) {
    const cmd = process.argv[2];
    const dataDir = process.env.DATA_DIR || path.join(process.cwd(), 'data');
    const store = createStore(dataDir);
    (async () => {
        if (cmd === 'ingest') {
            const repo = process.env.GITHUB_REPOSITORY, token = process.env.GITHUB_TOKEN;
            if (!repo || !token) throw new Error('GITHUB_REPOSITORY and GITHUB_TOKEN are needed');
            const s = await ingest(store, githubApi(repo, token));
            console.log(`ingest: ${s.seen} issue(s), ${s.accepted} accepted, ${s.duplicates} duplicate(s), ${s.refused} refused, ${s.deletions} deletion(s)`);
        } else if (cmd === 'publish') {
            const model = store.publish(process.argv.slice(3).join(' '));
            console.log(`published model v${model.version}: ${model.fights} fight(s), ${model.contributors} contributor(s), ${model.observations} observation(s)`);
        } else if (cmd === 'withdraw') {
            console.log(store.withdraw(process.argv[3]) ? `withdrawn v${process.argv[3]}` : 'no such version');
        } else {
            console.log('usage: github_ingest.js ingest | publish [note] | withdraw N');
            process.exit(2);
        }
    })().catch(e => { console.error(e.message); process.exit(1); });
}

module.exports = { createStore, parseIssue, ingestOne, ingest, githubApi };

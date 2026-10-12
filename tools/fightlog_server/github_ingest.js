#!/usr/bin/env node
'use strict';
// Jambix central service on GitHub -- the repository as the database
// (CENTRAL_NETWORK.md §9). The clients open issues ("jambix-batch <id>",
// "jambix-lesson <id>", "jambix-delete <contributor>", a fenced JSON body);
// this script, run by the repository's Action, validates each one with the
// same bounds as the HTTP service (validate.js), files the accepted ones in
// the data branch's JSONL files, answers and closes the issue; on a
// schedule it runs a learning cycle (release.js: build, evaluate, gate) and
// publishes a canary version into data/models/ when the gates pass.
//
//   node github_ingest.js ingest                 open issues -> data files (GITHUB_TOKEN, GITHUB_REPOSITORY, DATA_DIR)
//   node github_ingest.js publish [note]         one learning cycle; a version only when the gates pass
//   node github_ingest.js publish --force [note] a version whatever the gates say (written in the audit)
//   node github_ingest.js promote N              the canary rolled out to everyone
//   node github_ingest.js withdraw N             the version marked withdrawn (the previous active stands)
//   node github_ingest.js evaluate               the candidate, the gates and the holdout, nothing written
//
// Nothing here needs the game; nothing here runs in it.

const path = require('path');
const { validateBatch, validateLesson, validateDelete } = require('./validate');
const storeLib = require('./store');
const release = require('./release');

const MIN_PLUGIN = process.env.MIN_PLUGIN || release.DEFAULTS.minPlugin;
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

// --- the data files, with the release commands on them ---------------------------------------
function createStore(dataDir, opts) {
    const o = Object.assign({ retentionDays: RETENTION_DAYS, minPlugin: MIN_PLUGIN }, opts || {});
    const store = storeLib.createStore(dataDir, { retentionDays: o.retentionDays, now: o.now });
    const ro = extra => Object.assign({ minPlugin: o.minPlugin, learn: o.learn }, o.release || {}, extra || {});
    store.publish = (note, extra) => release.cycle(store, ro(Object.assign({ note }, extra || {})));
    store.promote = version => release.promote(store, version);
    store.withdraw = version => release.withdraw(store, version);
    store.evaluate = () => release.preview(store, ro());
    return store;
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

function ingestOne(store, issue) {
    const { kind, record, error } = parseIssue(issue);
    if (error) return { accepted: false, kind, reason: error };
    if (kind === 'delete') {
        const err = validateDelete(record);
        if (err) return { accepted: false, kind, reason: err };
        return { accepted: true, kind, removed: store.forget(record.contributor) };
    }
    const err = kind === 'batch' ? validateBatch(record) : validateLesson(record);
    if (err) return { accepted: false, kind, reason: err };
    const r = store.accept(kind, record);
    return { accepted: true, kind, duplicate: !!r.duplicate };
}

async function ingest(store, api) {
    const issues = await api.listIssues();
    const summary = { seen: issues.length, accepted: 0, refused: 0, duplicates: 0, deletions: 0 };
    for (const issue of issues) {
        const r = ingestOne(store, issue);
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
    store.purge();
    return summary;
}

// The learning log's entry on the Action run's summary page, too.
function toSummary(text) {
    if (!text || !process.env.GITHUB_STEP_SUMMARY) return;
    try { require('fs').appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + '\n'); } catch (e) { /* the summary is a nicety */ }
}

function sayCycle(r) {
    toSummary(r.log);
    if (r.version) {
        console.log(`published model v${r.version} (${r.stage}): ${r.candidate.fights} fight(s), ${r.candidate.contributors} contributor(s), ${r.candidate.observations} observation(s)` +
            (r.decision === 'forced' ? ` -- FORCED past the gates: ${r.verdict.failed.join(', ') || r.verdict.material.why}` : ''));
    } else {
        console.log(`${r.decision}: ${r.verdict.failed.length ? 'failed ' + r.verdict.failed.join(', ') : r.verdict.material.why}`);
    }
    for (const c of r.verdict.checks) console.log(`  ${c.pass === null ? 'skip' : c.pass ? 'pass' : 'FAIL'}  ${c.name}: ${c.detail}`);
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
            const args = process.argv.slice(3);
            const force = args.includes('--force');
            sayCycle(store.publish(args.filter(a => a !== '--force').join(' '), { force }));
        } else if (cmd === 'promote') {
            console.log(store.promote(process.argv[3]) ? `promoted v${process.argv[3]} to everyone` : 'no such active version');
        } else if (cmd === 'withdraw') {
            console.log(store.withdraw(process.argv[3]) ? `withdrawn v${process.argv[3]}` : 'no such version');
        } else if (cmd === 'evaluate') {
            const r = store.evaluate();
            console.log(`${r.verdict.decision} (production ${r.production ? 'v' + r.production : 'none'}): ${r.verdict.material.why}`);
            for (const c of r.verdict.checks) console.log(`  ${c.pass === null ? 'skip' : c.pass ? 'pass' : 'FAIL'}  ${c.name}: ${c.detail}`);
            const m = r.report.models;
            console.log(`  holdout: ${r.report.holdout.train_fights} fight(s) teach, ${r.report.holdout.test_fights} test (${r.report.holdout.test_forecasts} forecast(s))` +
                (m.candidate.n ? `; Brier candidate ${m.candidate.brier}, prior ${m.prior.brier}, baseline ${m.baseline.brier}${m.production ? ', production ' + m.production.brier : ''}` : ''));
            console.log('\n--- the learning log entry this would write ---\n' + r.log);
            toSummary('(evaluate: nothing written)\n\n' + r.log);
        } else {
            console.log('usage: github_ingest.js ingest | publish [--force] [note] | promote N | withdraw N | evaluate');
            process.exit(2);
        }
    })().catch(e => { console.error(e.message); process.exit(1); });
}

module.exports = { createStore, parseIssue, ingestOne, ingest, githubApi };

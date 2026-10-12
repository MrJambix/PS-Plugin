'use strict';
// Jambix central service -- the data directory, shared by the HTTP service
// (server.js) and the repository's Action (github_ingest.js):
//
//   batches.jsonl, lessons.jsonl   the records, one a line, stamped received_at
//   ids.json                        the record ids seen (duplicates)
//   deletions.jsonl                 the privacy deletions honoured
//   audit.jsonl                     every decision: quarantines, gates, publishes, promotions, withdrawals
//   models/manifest.json            the versions: status, stage, rollout, gates, rollback
//   models/vN.json                  the models
//   models/evaluations.jsonl        one evaluation per learning cycle, published or held

const fs = require('fs');
const path = require('path');
const { SCHEMA } = require('./validate');

function vnum(s) {
    const m = String(s || '').match(/(\d+)\.?(\d*)\.?(\d*)/);
    if (!m) return 0;
    return (Number(m[1]) || 0) * 1e6 + (Number(m[2]) || 0) * 1e3 + (Number(m[3]) || 0);
}

function createStore(dataDir, opts) {
    const o = Object.assign({ retentionDays: 180 }, opts || {});
    if (typeof o.now !== 'function') o.now = () => Date.now();
    const modelsDir = path.join(dataDir, 'models');
    fs.mkdirSync(modelsDir, { recursive: true });
    const files = {
        batches: path.join(dataDir, 'batches.jsonl'), lessons: path.join(dataDir, 'lessons.jsonl'),
        ids: path.join(dataDir, 'ids.json'), deletions: path.join(dataDir, 'deletions.jsonl'), audit: path.join(dataDir, 'audit.jsonl'),
        manifest: path.join(modelsDir, 'manifest.json'), evaluations: path.join(modelsDir, 'evaluations.jsonl'),
        learningLog: path.join(dataDir, 'LEARNING_LOG.md'), snapshot: path.join(modelsDir, 'last_cycle.json'),
    };
    const readLines = f => {
        if (!fs.existsSync(f)) return [];
        const out = [];
        for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
            if (!line.trim()) continue;
            try { out.push(JSON.parse(line)); } catch (e) { /* a torn line: skipped */ }
        }
        return out;
    };
    const writeLines = (f, rows) => fs.writeFileSync(f, rows.map(r => JSON.stringify(r)).join('\n') + (rows.length ? '\n' : ''));
    const append = (f, row) => fs.appendFileSync(f, JSON.stringify(row) + '\n');
    let ids = new Set(fs.existsSync(files.ids) ? JSON.parse(fs.readFileSync(files.ids, 'utf8')) : []);
    const saveIds = () => {
        const list = Array.from(ids);
        if (list.length > 50000) ids = new Set(list.slice(list.length - 50000));
        fs.writeFileSync(files.ids, JSON.stringify(Array.from(ids)));
    };
    const readManifest = () => fs.existsSync(files.manifest) ? JSON.parse(fs.readFileSync(files.manifest, 'utf8')) : { schema: SCHEMA, versions: [] };
    const writeManifest = m => fs.writeFileSync(files.manifest, JSON.stringify(m, null, 2));
    const modelFile = v => path.join(modelsDir, `v${String(v).replace(/[^0-9a-z.]/gi, '')}.json`);
    const store = {
        files, dataDir, modelsDir, readLines, writeLines, append, saveIds, readManifest, writeManifest, vnum,
        get ids() { return ids; },
        now: () => o.now(),
        stamp: () => new Date(o.now()).toISOString(),
        batches: () => readLines(files.batches),
        lessons: () => readLines(files.lessons),
        readModel: v => (fs.existsSync(modelFile(v)) ? JSON.parse(fs.readFileSync(modelFile(v), 'utf8')) : null),
        writeModel: (v, model) => fs.writeFileSync(modelFile(v), JSON.stringify(model)),
        nextVersion: () => readManifest().versions.reduce((n, v) => Math.max(n, Number(v.version) || 0), 0) + 1,
        /** The newest active version, the fully rolled-out one first (what "production" means). */
        activeVersion: () => {
            const active = readManifest().versions.filter(v => v.status === 'active').sort((a, b) => vnum(b.version) - vnum(a.version));
            return active.find(v => !v.stage || v.stage === 'full' || v.rollout === 100) || active[0] || null;
        },
        audit: row => append(files.audit, Object.assign({ at: new Date(o.now()).toISOString() }, row)),
        readAudit: limit => readLines(files.audit).slice(-(limit || 200)),
        evaluations: () => readLines(files.evaluations),
        recordEvaluation: row => append(files.evaluations, row),
        /** The learning log (report.js): the last cycle's snapshot, and the log's text. */
        readSnapshot: () => { try { return fs.existsSync(files.snapshot) ? JSON.parse(fs.readFileSync(files.snapshot, 'utf8')) : null; } catch (e) { return null; } },
        writeSnapshot: snap => fs.writeFileSync(files.snapshot, JSON.stringify(snap)),
        readLearningLog: () => (fs.existsSync(files.learningLog) ? fs.readFileSync(files.learningLog, 'utf8') : ''),
        writeLearningLog: text => fs.writeFileSync(files.learningLog, text),
        /** A record accepted: stored once (its id), stamped. Returns { duplicate } or { stored }. */
        accept(kind, record) {
            if (ids.has(record.id)) return { duplicate: true };
            record.received_at = new Date(o.now()).toISOString();
            append(kind === 'batch' ? files.batches : files.lessons, record);
            ids.add(record.id);
            saveIds();
            return { stored: true };
        },
        /** Every record under a contributor removed, the deletion logged. */
        forget(contributor) {
            let removed = 0;
            for (const f of [files.batches, files.lessons]) {
                const rows = readLines(f);
                const kept = rows.filter(r => r.contributor !== contributor);
                removed += rows.length - kept.length;
                if (kept.length !== rows.length) writeLines(f, kept);
            }
            append(files.deletions, { contributor, at: new Date(o.now()).toISOString(), removed });
            return removed;
        },
        purge() {
            const cutoff = o.now() - o.retentionDays * 86400 * 1000;
            for (const f of [files.batches, files.lessons]) {
                const rows = readLines(f);
                const kept = rows.filter(r => !r.received_at || Date.parse(r.received_at) >= cutoff);
                if (kept.length !== rows.length) writeLines(f, kept);
            }
        },
    };
    return store;
}

module.exports = { createStore, vnum };

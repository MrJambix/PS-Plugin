'use strict';
// Jambix central service -- the release (the brief's §7 and §8): a learning
// cycle builds a candidate from every accepted record, judges it on the
// fights it never saw (evaluate.js), runs it through the gates, and only a
// candidate that passes them becomes a version the clients may adopt --
// staged: a canary first (a share of the clients, by their identifier),
// promoted to full by hand once the monitoring (the forecasts made under it,
// learn.js monitoring) holds up; withdrawn to roll back (the previous active
// stands). A candidate that fails a gate is written down (evaluations.jsonl,
// audit.jsonl) and nothing changes. A candidate that passes but adds nothing
// material is held: the clients' model does not flap on noise.
//
// Nothing a client runs is a rule from here: a model is rates, intervals and
// worded associations; the reaction engine never reads it. (The client's
// test "nothing from a model becomes a rule" holds that.)

const learn = require('./learn');
const evaluate = require('./evaluate');
const { SCHEMA } = require('./validate');
const reportLib = require('./report');

const DEFAULTS = {
    minPlugin: process.env.MIN_PLUGIN || '1.7.8',
    minContributors: 2,       // a network, not a person
    tolerance: 0.02,          // a Brier this much worse than production (or the prior) is still "not worse"
    maxEce: 0.15,             // calibration error past this fails, when the test holds enough forecasts
    minTestForecasts: 10,     // fewer and the holdout cannot speak: the gates on it are skipped and said so
    minGrowthFights: 20,      // new fights since production before a new version is worth the change ...
    minGrowthShare: 0.1,      // ... or this share more
    canaryRollout: 25,        // the share of clients a new version reaches first
};

function summarizeCandidate(model) {
    let usable = 0, entries = 0, tactics = 0, validated = 0;
    for (const G of Object.values(model.games || {})) {
        for (const g of Object.values(G.groups || {})) for (const e of Object.values(g.patterns || {})) { entries += 1; if (!e.unreliable) usable += 1; }
        for (const t of G.tactics || []) { tactics += 1; if (t.validated) validated += 1; }
    }
    return { entries, usable, tactics, validated };
}

/** The model the clients run: the active version, unless it holds no fight at all
 *  (an empty version -- the first scheduled publish of 2026-10-12 -- is not a
 *  production to compare with, roll back to, or stage behind). */
function productionOf(store, active) {
    const m = active ? store.readModel(active.version) : null;
    return m && Number(m.fights) > 0 ? m : null;
}

/** The learning log's entry for a cycle, written unless `dry` (report.js). */
function logCycle(store, result, records, production, dry) {
    const prev = store.readSnapshot();
    const e = reportLib.entry(result, prev, records, { current: production ? production.version : null });
    if (!dry) {
        store.writeLearningLog(reportLib.prepend(store.readLearningLog(), e.markdown));
        store.writeSnapshot(e.snapshot);
    }
    return e;
}

/** The gates, each with its verdict and what it saw. */
function gates(candidate, report, production, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const checks = [];
    const check = (name, pass, detail, skipped) => checks.push({ name, pass: skipped ? null : !!pass, detail });
    const s = summarizeCandidate(candidate);
    check('contributors', candidate.contributors >= o.minContributors, `${candidate.contributors} contributor(s), needs ${o.minContributors}`);
    check('content', s.usable > 0 || s.validated > 0, `${s.usable} usable rate(s) of ${s.entries}, ${s.validated} validated tactic(s) of ${s.tactics}`);
    const enough = report && report.holdout && report.holdout.enough;
    const m = report && report.models || {};
    if (!enough) {
        check('holdout', null, `${report && report.holdout ? report.holdout.test_forecasts : 0} test forecast(s), fewer than ${o.minTestForecasts}: not judged`, true);
    } else {
        check('not worse than the prior', m.candidate.brier <= m.prior.brier + o.tolerance,
            `Brier ${m.candidate.brier} against the prior's ${m.prior.brier} on ${m.candidate.n} forecast(s) (${report.comparisons.candidate_vs_prior.verdict})`);
        if (production && m.production) {
            check('not worse than production', m.candidate.brier <= m.production.brier + o.tolerance,
                `Brier ${m.candidate.brier} against production's ${m.production.brier} (${report.comparisons.candidate_vs_production.verdict}, ±${report.comparisons.candidate_vs_production.se})`);
        }
        check('calibration', m.candidate.n < 30 || m.candidate.ece <= o.maxEce, `calibration error ${m.candidate.ece} on ${m.candidate.n} forecast(s), limit ${o.maxEce}${m.candidate.n < 30 ? ' (under 30: not held to it)' : ''}`);
    }
    let material = true, materialWhy = 'the first model';
    if (production) {
        const grown = candidate.fights - (production.fights || 0);
        material = grown >= o.minGrowthFights || grown >= (production.fights || 0) * o.minGrowthShare;
        materialWhy = `${grown} fight(s) since v${production.version} (${production.fights || 0}); needs ${o.minGrowthFights} or ${(o.minGrowthShare * 100).toFixed(0)}%`;
        if (!material && report && report.comparisons.candidate_vs_production && report.comparisons.candidate_vs_production.verdict === 'better') {
            material = true; materialWhy += '; but it forecasts better on the holdout';
        }
    }
    const failed = checks.filter(c => c.pass === false).map(c => c.name);
    const decision = failed.length ? 'reject' : material ? 'publish' : 'hold';
    return { decision, pass: failed.length === 0, failed, checks, material: { yes: material, why: materialWhy }, summary: s };
}

/** The package the clients download: the model with its release block. */
function packageOf(model, version, report, verdict, production, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    return Object.assign({}, model, {
        version: String(version),
        compatibility: { schema: SCHEMA, min_plugin: o.minPlugin, games: Object.keys(model.games || {}), builds: Object.fromEntries(Object.entries(model.games || {}).map(([g, G]) => [g, Object.keys(G.builds || {})])) },
        release: {
            released_at: model.built_at, evidence: verdict.summary, gates: { decision: verdict.decision, checks: verdict.checks, material: verdict.material },
            evaluation: report ? { holdout: report.holdout, models: Object.fromEntries(Object.entries(report.models).map(([k, v]) => [k, v && v.n ? { n: v.n, brier: v.brier, brier_se: v.brier_se, ece: v.ece, coverage: v.coverage, skill: v.skill, false_positive_rate: v.false_positive_rate, by_matchup: v.by_matchup, by_game: v.by_game } : v])), comparisons: report.comparisons } : null,
            stability: evaluate.stability(model, production),
            rollback: production ? { to: String(production.version), how: 'withdraw this version; the previous active stands' } : null,
            known_limitations: model.limitations,
        },
    });
}

/**
 * One learning cycle on a store: build, evaluate, gate, and publish a
 * canary (or the first full version) when the gates pass. `force` publishes
 * whatever the gates say (an admin's explicit call, written in the audit).
 */
function cycle(store, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const batches = store.batches(), lessons = store.lessons();
    const active = store.activeVersion();
    // Nothing arrived since the last cycle and production is the same: the
    // answer would be the same, so nothing is written (the schedule runs
    // every six hours; the data branch is not committed to for nothing).
    const records = batches.length + lessons.length;
    const newest = [...batches, ...lessons].reduce((a, r) => (r.received_at && r.received_at > a ? r.received_at : a), '');
    const last = store.evaluations().slice(-1)[0];
    if (!o.force && last && last.records === records && last.newest === newest && (last.published || last.production) === (active ? active.version : null)) {
        return { decision: 'unchanged', version: null, verdict: { failed: [], checks: [], material: { yes: false, why: `no record since the last cycle (${last.at})` } }, report: null, candidate: null };
    }
    const production = productionOf(store, active);
    const candidate = learn.build(batches, lessons, o.learn);
    const report = evaluate.evaluate(batches, lessons, production, Object.assign({}, o.learn, o.evaluate));
    const verdict = gates(candidate, report, production, o);
    const row = { at: store.stamp(), records, newest, decision: verdict.decision, forced: !!o.force, failed: verdict.failed, material: verdict.material,
        candidate: { fights: candidate.fights, contributors: candidate.contributors, observations: candidate.observations, episodes: candidate.episodes, quarantined: candidate.screen.quarantined },
        production: active ? active.version : null,
        holdout: report.holdout, brier: { candidate: report.models.candidate.brier, production: report.models.production ? report.models.production.brier : null, prior: report.models.prior.brier, baseline: report.models.baseline.brier },
        note: o.note || undefined };
    if (verdict.decision !== 'publish' && !o.force) {
        store.recordEvaluation(row);
        store.audit({ kind: 'cycle', action: verdict.decision, failed: verdict.failed, material: verdict.material.why, candidate: row.candidate });
        const result = { decision: verdict.decision, version: null, verdict, report, candidate };
        result.log = logCycle(store, result, { batches, lessons }, production).markdown;
        return result;
    }
    const version = store.nextVersion();
    row.published = String(version);
    store.recordEvaluation(row);
    const pkg = packageOf(candidate, version, report, verdict, production, o);
    store.writeModel(version, pkg);
    const m = store.readManifest();
    const stage = production && !o.full ? 'canary' : 'full';
    m.versions.push({
        version: String(version), schema: SCHEMA, min_plugin: o.minPlugin, status: 'active', stage, rollout: stage === 'canary' ? o.canaryRollout : 100,
        created_at: store.stamp(), fights: candidate.fights, contributors: candidate.contributors, note: o.note || undefined,
        gates: { decision: verdict.decision, forced: !!o.force || undefined, failed: verdict.failed.length ? verdict.failed : undefined },
        rollback: production ? String(production.version) : null,
    });
    store.writeManifest(m);
    store.audit({ kind: 'publish', version: String(version), stage, rollout: stage === 'canary' ? o.canaryRollout : 100, forced: !!o.force, decision: verdict.decision, failed: verdict.failed, candidate: row.candidate });
    const result = { decision: o.force && verdict.decision !== 'publish' ? 'forced' : 'publish', version: String(version), stage, verdict, report, candidate: pkg };
    result.log = logCycle(store, result, { batches, lessons }, production).markdown;
    return result;
}

/** The canary becomes the version for everyone. */
function promote(store, version) {
    const m = store.readManifest();
    const e = m.versions.find(v => String(v.version) === String(version));
    if (!e || e.status !== 'active') return false;
    e.stage = 'full'; e.rollout = 100; e.promoted_at = store.stamp();
    store.writeManifest(m);
    store.audit({ kind: 'promote', version: String(version) });
    return true;
}

/** Rollback: the version marked withdrawn; the previous active stands. */
function withdraw(store, version) {
    const m = store.readManifest();
    const e = m.versions.find(v => String(v.version) === String(version));
    if (!e) return false;
    e.status = 'withdrawn'; e.withdrawn_at = store.stamp();
    store.writeManifest(m);
    store.audit({ kind: 'withdraw', version: String(version) });
    return true;
}

/** The candidate and its evaluation as they would stand, nothing written. */
function preview(store, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const batches = store.batches(), lessons = store.lessons();
    const active = store.activeVersion();
    const production = productionOf(store, active);
    const candidate = learn.build(batches, lessons, o.learn);
    const report = evaluate.evaluate(batches, lessons, production, Object.assign({}, o.learn, o.evaluate));
    const verdict = gates(candidate, report, production, o);
    const pkg = packageOf(candidate, 'candidate', report, verdict, production, o);
    const log = logCycle(store, { decision: verdict.decision, version: null, verdict, report, candidate: pkg }, { batches, lessons }, production, true).markdown;
    return { verdict, report, candidate: pkg, production: active ? active.version : null, log };
}

module.exports = { DEFAULTS, gates, cycle, promote, withdraw, preview, packageOf, summarizeCandidate };

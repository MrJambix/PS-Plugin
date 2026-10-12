'use strict';
// Jambix central service -- the evaluation (the brief's §6): a candidate
// model is judged on fights it never saw, in time order (the earlier fights
// teach it, the later ones test it; nothing from the test leaks into the
// training), against three others on the same test fights:
//
//   production   the model the clients run now (none before the first)
//   prior        the plain predictor every client starts with: 0.5
//   baseline     the compatible class or matchup rate from the training fights,
//                reliable or not (what pooling without the groups would say)
//
// For each: the Brier score with its standard error (fights as clusters), the
// calibration error (five bins), the coverage (how many test forecasts the
// model had a usable rate for), the false positive rate, the accuracy, the
// skill against the prior, and the same by matchup and by game. The candidate
// against production is a paired comparison, fight by fight. Every number
// carries its count.

const groups = require('./groups');
const trust = require('./trust');
const learn = require('./learn');

const DEFAULTS = {
    trainShare: 0.7,         // the earlier share of fights that teaches; the rest tests
    positive: 0.6,           // a forecast at or above this is "it will happen"
    minTest: 10,             // fewer test forecasts than this and the evaluation says so
};

const r3 = x => Number(x.toFixed(3));
const r2 = x => Number(x.toFixed(2));

/** What a model says for one forecast: its rate at the narrowest usable level, or nothing. */
function forecastOf(model, ctx, pattern, allowUnreliable, fromLevel) {
    const G = model && model.games && model.games[ctx.game];
    if (!G || !G.groups) return null;
    if (fromLevel) {
        for (const { level, key } of groups.keysOf(ctx)) {
            if (groups.LEVELS.indexOf(level) < groups.LEVELS.indexOf(fromLevel)) continue;
            const e = G.groups[key] && G.groups[key].patterns && G.groups[key].patterns[pattern];
            if (e && (allowUnreliable || !e.unreliable)) return { p: e.p, level };
        }
        return null;
    }
    const r = groups.resolve(G.groups, ctx, pattern, allowUnreliable);
    return r ? { p: r.p, level: r.level } : null;
}

function metrics(rows, pick, prior) {
    // rows: { fight, enemy_class, game, hit, p_* }, pick: row -> { p, covered }
    const n = rows.length;
    if (n === 0) return { n: 0 };
    let brier = 0, covered = 0, right = 0, fp = 0, negatives = 0, tp = 0, positives = 0;
    const perFight = {}, bins = Array.from({ length: 5 }, () => ({ n: 0, sum_p: 0, hits: 0 }));
    const byMatchup = {}, byGame = {}, byLevel = {};
    for (const r of rows) {
        const f = pick(r);
        const p = f && f.p !== null && f.p !== undefined ? f.p : prior;
        const y = r.hit ? 1 : 0;
        const sq = (p - y) ** 2;
        brier += sq;
        if (f && f.covered) { covered += 1; byLevel[f.level || '?'] = (byLevel[f.level || '?'] || 0) + 1; }
        if ((p >= 0.5) === r.hit) right += 1;
        if (r.hit) { positives += 1; if (p >= DEFAULTS.positive) tp += 1; } else { negatives += 1; if (p >= DEFAULTS.positive) fp += 1; }
        const pf = perFight[r.fight] || (perFight[r.fight] = { n: 0, sum: 0 });
        pf.n += 1; pf.sum += sq;
        const b = bins[Math.min(4, Math.floor(p * 5))]; b.n += 1; b.sum_p += p; b.hits += y;
        const m = byMatchup[r.enemy_class] || (byMatchup[r.enemy_class] = { n: 0, brier: 0 }); m.n += 1; m.brier += sq;
        const g = byGame[r.game] || (byGame[r.game] = { n: 0, brier: 0 }); g.n += 1; g.brier += sq;
    }
    // The standard error with fights as clusters: the fight means' spread over the fights.
    const fights = Object.values(perFight);
    const fightMeans = fights.map(x => x.sum / x.n);
    const mean = brier / n;
    const fm = fightMeans.reduce((a, b) => a + b, 0) / fights.length;
    const varF = fights.length > 1 ? fightMeans.reduce((a, b) => a + (b - fm) ** 2, 0) / (fights.length - 1) : 0;
    const se = fights.length > 1 ? Math.sqrt(varF / fights.length) : null;
    let ece = 0;
    for (const b of bins) if (b.n > 0) ece += (b.n / n) * Math.abs(b.sum_p / b.n - b.hits / b.n);
    return {
        n, fights: fights.length, brier: r3(mean), brier_se: se === null ? null : r3(se), ece: r3(ece),
        coverage: r2(covered / n), by_level: byLevel, accuracy: r2(right / n),
        false_positive_rate: negatives > 0 ? r2(fp / negatives) : null, true_positive_rate: positives > 0 ? r2(tp / positives) : null,
        by_matchup: Object.fromEntries(Object.entries(byMatchup).map(([k, v]) => [k, { n: v.n, brier: r3(v.brier / v.n) }])),
        by_game: Object.fromEntries(Object.entries(byGame).map(([k, v]) => [k, { n: v.n, brier: r3(v.brier / v.n) }])),
        bins: bins.map((b, i) => ({ range: `${(i * 0.2).toFixed(1)}-${((i + 1) * 0.2).toFixed(1)}`, n: b.n, mean_p: b.n ? r2(b.sum_p / b.n) : null, hit_rate: b.n ? r2(b.hits / b.n) : null })),
    };
}

/** Paired, fight by fight: how much lower (better) a's Brier is than b's, with its standard error. */
function paired(rows, pickA, pickB, prior) {
    const perFight = {};
    for (const r of rows) {
        const a = pickA(r), b = pickB(r);
        const pa = a && a.p !== null && a.p !== undefined ? a.p : prior, pb = b && b.p !== null && b.p !== undefined ? b.p : prior;
        const y = r.hit ? 1 : 0;
        const d = (pb - y) ** 2 - (pa - y) ** 2;             // positive: a better
        const f = perFight[r.fight] || (perFight[r.fight] = { n: 0, sum: 0 });
        f.n += 1; f.sum += d;
    }
    const means = Object.values(perFight).map(f => f.sum / f.n);
    if (!means.length) return { fights: 0, improvement: null, se: null, verdict: 'nothing to compare' };
    const m = means.reduce((x, y) => x + y, 0) / means.length;
    const v = means.length > 1 ? means.reduce((x, y) => x + (y - m) ** 2, 0) / (means.length - 1) : 0;
    const se = means.length > 1 ? Math.sqrt(v / means.length) : null;
    const verdict = se === null ? 'one fight: no verdict' : m > 1.96 * se ? 'better' : m < -1.96 * se ? 'worse' : 'indistinguishable';
    return { fights: means.length, improvement: r3(m), se: se === null ? null : r3(se), verdict };
}

/**
 * The chronological evaluation. `production` is the model the clients run
 * (or null). Returns the report; the candidate it judged was built on the
 * training fights only (the published candidate is built on all of them
 * by release.js, and this report travels with it).
 */
function evaluate(batchesIn, lessonsIn, production, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const screened = trust.screen(batchesIn, lessonsIn, o);
    const fightOf = r => String(r.fight || r.id);
    const order = [];
    const seen = new Set();
    const rows = [...screened.batches, ...screened.lessons].sort((a, b) => String(a.received_at || '').localeCompare(String(b.received_at || '')) || String(a.id).localeCompare(String(b.id)));
    for (const r of rows) { const f = fightOf(r); if (!seen.has(f)) { seen.add(f); order.push(f); } }
    const cut = Math.floor(order.length * o.trainShare);
    const train = new Set(order.slice(0, cut));
    const trainB = screened.batches.filter(b => train.has(fightOf(b))), trainL = screened.lessons.filter(l => train.has(fightOf(l)));
    const testB = screened.batches.filter(b => !train.has(fightOf(b))), testL = screened.lessons.filter(l => !train.has(fightOf(l)));
    const candidate = learn.build(trainB, trainL, o);
    const enemiesOf = {};
    for (const l of testL) enemiesOf[fightOf(l)] = Array.isArray(l.enemies) ? l.enemies.length : undefined;
    const test = [];
    for (const b of testB) {
        for (const ob of b.observations || []) {
            const ctx = groups.contextOf(b, ob.enemy_class, { enemies: enemiesOf[fightOf(b)] });
            const cand = forecastOf(candidate, ctx, ob.pattern, false);
            const prod = forecastOf(production, ctx, ob.pattern, false);
            const base = forecastOf(candidate, ctx, ob.pattern, true, 'matchup');
            test.push({ fight: fightOf(b), enemy_class: ctx.enemy_class, game: ctx.game, hit: ob.hit === true, contributor: b.contributor,
                candidate: cand ? { p: cand.p, covered: true, level: cand.level } : null,
                production: prod ? { p: prod.p, covered: true, level: prod.level } : null,
                baseline: base ? { p: base.p, covered: true, level: base.level } : null });
        }
    }
    const prior = 0.5;
    const report = {
        at: new Date().toISOString(),
        holdout: { fights: order.length, train_fights: cut, test_fights: order.length - cut, test_forecasts: test.length,
            test_contributors: new Set(test.map(r => r.contributor)).size, cut_after: cut > 0 ? (rows.find(r => fightOf(r) === order[cut - 1]) || {}).received_at || null : null,
            enough: test.length >= o.minTest, note: test.length >= o.minTest ? undefined : `${test.length} test forecast(s), fewer than ${o.minTest}: the numbers below say little` },
        models: {
            candidate: metrics(test, r => r.candidate, prior),
            production: production ? metrics(test, r => r.production, prior) : null,
            prior: metrics(test, () => ({ p: prior, covered: true }), prior),
            baseline: metrics(test, r => r.baseline, prior),
        },
        comparisons: {
            candidate_vs_production: production ? paired(test, r => r.candidate, r => r.production, prior) : null,
            candidate_vs_prior: paired(test, r => r.candidate, () => ({ p: prior }), prior),
            candidate_vs_baseline: paired(test, r => r.candidate, r => r.baseline, prior),
        },
        trained_on: { fights: candidate.fights, contributors: candidate.contributors, observations: candidate.observations },
        quarantined: screened.quarantined.length,
    };
    const m = report.models;
    for (const k of ['candidate', 'production', 'baseline']) if (m[k] && m[k].n) m[k].skill = m.prior.brier > 0 ? r3(1 - m[k].brier / m.prior.brier) : null;
    return report;
}

/**
 * Recommendation stability (the brief's §6): how much of what the clients
 * would read changes between two full models -- the usable pattern rates
 * (moved under 0.1) and the validated tactics (the same better arm).
 */
function stability(candidate, production) {
    if (!production || !production.games) return { patterns: null, tactics: null, note: 'no production model' };
    let common = 0, steady = 0, tcommon = 0, tsteady = 0;
    for (const [g, G] of Object.entries(candidate.games || {})) {
        const P = production.games[g];
        if (!P) continue;
        for (const [key, grp] of Object.entries(G.groups || {})) {
            const pg = P.groups && P.groups[key];
            if (!pg) continue;
            for (const [pat, e] of Object.entries(grp.patterns || {})) {
                const pe = pg.patterns && pg.patterns[pat];
                if (!pe || e.unreliable || pe.unreliable) continue;
                common += 1;
                if (Math.abs(e.p - pe.p) < 0.1) steady += 1;
            }
        }
        for (const t of G.tactics || []) {
            if (!t.validated) continue;
            const pt = (P.tactics || []).find(x => x.strategy === t.strategy && x.level === t.level && x.enemy_class === t.enemy_class && x.me_class === t.me_class);
            if (!pt || !pt.validated) continue;
            tcommon += 1;
            if (pt.better === t.better) tsteady += 1;
        }
    }
    return { patterns: common ? { common, steady: r2(steady / common) } : null, tactics: tcommon ? { common: tcommon, steady: r2(tsteady / tcommon) } : null };
}

module.exports = { DEFAULTS, evaluate, metrics, paired, stability, forecastOf };

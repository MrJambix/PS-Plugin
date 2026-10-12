'use strict';
// Jambix central service -- the global learning engine's tests: the learning
// groups and their backoff; the trust screen (duplicates, replays, suspicious
// numbers, volume); the opponent model's weights (contributor caps,
// outliers, fights as clusters, drift by build, conditional rates, a level
// apart from its parent); the tactics as associations with counterexamples
// and staleness; the chronological evaluation against production, the prior
// and the baseline; the release gates, the canary, promotion, rollback and
// the hold on nothing material. Run: node --test tools/fightlog_server/learn.test.js

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const groups = require('./groups');
const trust = require('./trust');
const learn = require('./learn');
const evaluate = require('./evaluate');
const release = require('./release');
const { createStore } = require('./store');

// --- fixtures -------------------------------------------------------------------------------------
let seq = 0, tick = 0;
const id = () => (++seq).toString(16).padStart(20, '0');
// Real fights differ: a moment, a rate, a duration. The fixtures vary the
// same way, or the trust screen reads them as duplicates and replays.
const moment = () => 3 + (++tick % 37) * 0.7;
const who = n => String(n).repeat(24);
const at = (day, h) => new Date(Date.UTC(2026, 9, 1 + day, h || 10)).toISOString();

function obs(pattern, enemy, p, hit, extra) {
    return Object.assign({ pattern, enemy_class: enemy, p, reliability: 0.5, sure: p >= 0.6 || p <= 0.4, basis: 'recent', evidence: 2,
        inputs_ok: true, hit, correct: (p >= 0.5) === hit, t: moment(), context: { mode: 'world_pvp', threat: 'LOW', me_hp: 4, controlled: false } }, extra || {});
}
function batch(contributor, day, observations, extra) {
    const fight = id();
    return Object.assign({ schema: 1, id: id(), fight, contributor, received_at: at(day),
        client: { plugin: '1.7.8', game: 'Forever', build: '1.60.1.70338' },
        me: { class: 'HUNTER', level: 26 }, encounter: { type: 'world_pvp', duration: 30 + (++tick % 23), outcome: 'won', enemies: 1 },
        observations }, extra || {});
}
function episode(type, result, followed, extra) {
    return Object.assign({
        id: id(), type, enemy_class: 'WARRIOR', t: moment(), horizon: 5,
        trigger: { text: 'the player Intercept at 20 yd', observed: true, source: 'event' },
        before: { hp: 1, zone: 'ranged', gap: 20, threat: 'LOW', attackers: 1, controlled: false, defensives_ready: 2, foe_hp: 1 },
        after: { hp: 0.9, zone: 'ranged', gap: 22, threat: 'LOW', attackers: 0, controlled: false, defensives_ready: 2, foe_hp: 0.9 },
        prediction: { pattern: 'mobility_when_slowed', p: 0.75, reliability: 0.5, sure: true, outcome: 'HIT' },
        recommendation: { action: 'Wing Clip', move: 'increase', outcome: followed ? 'FOLLOWED' : 'NOT_FOLLOWED' },
        actions: followed ? ['Wing Clip'] : [], moved: true,
        result: { primary: result, all: [result] },
        quality: { unattributed: false, feeds_missing: false, incomplete: false, guess_only: false, unsupported: false, test_data: false },
    }, extra || {});
}
function lesson(contributor, day, fight, outcome, codes, enemies) {
    return { schema: 1, id: id(), fight, contributor, received_at: at(day),
        client: { plugin: '1.7.8', game: 'Forever', build: '1.60.1.70338' }, me: { class: 'HUNTER', level: 26 },
        encounter: { type: 'world_pvp', duration: 30 + (++tick % 23), outcome },
        enemies: enemies || [{ class: 'WARRIOR', role: 'melee', used: { Charge: 1, Hamstring: 1 + (tick % 4) }, controls_on_me: {}, bursts: 1, trinket: false, hp_min: 0, died: outcome === 'won', fled: false, time_on_me: 30 }],
        lessons: codes || [], predictions: { forecasts: 2, right: 2, brier: 0.36 } };
}
/** A network of `n` contributors, `fightsEach` fights each, every fight `k` chances of the pattern at rate `rate`. */
function network(n, fightsEach, k, rate, opts) {
    const o = Object.assign({ pattern: 'mobility_when_slowed', enemy: 'WARRIOR', p: 0.6, day: 0, build: '1.60.1.70338', game: 'Forever', start: 1 }, opts || {});
    const batches = [], lessons = [];
    let i = 0;
    for (let c = 0; c < n; c++) {
        for (let f = 0; f < fightsEach; f++) {
            const observations = [];
            for (let j = 0; j < k; j++) { i += 1; observations.push(obs(o.pattern, o.enemy, o.p, (i % 10) / 10 < rate)); }
            const b = batch(who(o.start + c), o.day + f, observations, { client: { plugin: '1.7.8', game: o.game, build: o.build } });
            batches.push(b);
            lessons.push(lesson(who(o.start + c), o.day + f, b.fight, f % 3 === 0 ? 'lost' : 'won', f % 3 === 0 ? ['trap_unused'] : ['trap_won']));
        }
    }
    return { batches, lessons };
}
const classKey = (game, enemy) => groups.keyAt({ game, enemy_class: enemy }, 'class');
const matchupKey = (game, me, enemy) => groups.keyAt({ game, me_class: me, enemy_class: enemy }, 'matchup');

// --- groups -----------------------------------------------------------------------------------------
test('groups: a record is filed under four keys, narrowest first, every one carrying the game; the backoff walks to the first usable level and says which', () => {
    const b = batch(who(1), 0, []);
    const ctx = groups.contextOf(b, 'WARRIOR', { enemies: 1 });
    assert.deepStrictEqual(groups.keysOf(ctx).map(k => k.key), [
        'g:Forever|me:HUNTER|e:WARRIOR|lv:20-29|enc:world_pvp|1v1', 'g:Forever|me:HUNTER|e:WARRIOR', 'g:Forever|e:WARRIOR', 'g:Forever']);
    assert.strictEqual(groups.bracket(60), '60'); assert.strictEqual(groups.bracket(7), '0-9'); assert.strictEqual(groups.bracket(undefined), '?');
    assert.strictEqual(groups.combatOf(3), 'outnumbered');
    const model = { 'g:Forever|e:WARRIOR': { patterns: { x: { p: 0.7, unreliable: false } } }, 'g:Forever|me:HUNTER|e:WARRIOR': { patterns: { x: { p: 0.9, unreliable: true } } } };
    const r = groups.resolve(model, ctx, 'x');
    assert.strictEqual(r.level, 'class'); assert.strictEqual(r.p, 0.7); assert.strictEqual(r.certainty, 0.7);
    assert.strictEqual(groups.resolve(model, Object.assign({}, ctx, { game: 'Vanilla' }), 'x'), null, 'never across the game');
    assert.strictEqual(groups.resolve(model, ctx, 'x', true).level, 'matchup', 'allowed unreliable: the narrower one');
});

// --- trust ---------------------------------------------------------------------------------------------
test('trust: the same fight under a new id is quarantined as duplicate content; a contributor\'s episodes seen already are a replay; impossible numbers are suspicious; the day\'s volume is capped; every decision is in the audit', () => {
    const c = who(1);
    const a = batch(c, 0, [obs('mobility_when_slowed', 'WARRIOR', 0.6, true)]);
    const again = Object.assign({}, a, { id: id(), fight: id(), received_at: at(0, 11) });
    const eps = [episode('gap_close_attempt', 'POSITION_IMPROVED', true), episode('gap_close_attempt', 'POSITION_IMPROVED', true)];
    const e1 = batch(c, 1, [], { episodes: eps });
    const e2 = batch(c, 2, [obs('same_opener', 'ROGUE', 0.5, false)], { episodes: eps.map(e => Object.assign({}, e, { id: id() })) });
    const late = batch(c, 3, [obs('mobility_when_slowed', 'WARRIOR', 0.6, true, { t: 200 })]);
    const flood = batch(c, 4, Array.from({ length: 150 }, () => obs('mobility_when_slowed', 'WARRIOR', 0.6, true)));
    const perfect = batch(c, 5, Array.from({ length: 20 }, () => obs('mobility_when_slowed', 'WARRIOR', 0.9, true)));
    const r = trust.screen([a, again, e1, e2, late, flood, perfect], [], { maxPerDay: 40 });
    assert.strictEqual(r.batches.length, 2, 'the first and the first episodes batch');
    const reasons = Object.fromEntries(r.quarantined.map(q => [q.id, q.reasons.join('; ')]));
    assert.match(reasons[again.id], /duplicate content/);
    assert.match(reasons[e2.id], /2 of 2 episodes seen before/);
    assert.match(reasons[late.id], /past the fight's end/);
    assert.match(reasons[flood.id], /150 forecasts in \d+ s/);
    assert.match(reasons[perfect.id], /every one sure and right/);
    assert.strictEqual(r.audit.length, 5);
    // Volume: the 41st fight of a day is quarantined.
    const many = Array.from({ length: 41 }, () => batch(who(2), 0, [obs('mobility_when_slowed', 'WARRIOR', 0.6, true)]));
    const v = trust.screen(many, [], { maxPerDay: 40 });
    assert.strictEqual(v.batches.length, 40);
    assert.match(v.quarantined[0].reasons[0], /more than 40 fights on 2026-10-01/);
    // A fight id two contributors claim: the second is quarantined.
    const b1 = batch(who(3), 0, [obs('mobility_when_slowed', 'WARRIOR', 0.6, true)]);
    const b2 = Object.assign(batch(who(4), 0, [obs('mobility_when_slowed', 'WARRIOR', 0.6, true)]), { fight: b1.fight });
    const f = trust.screen([b1, b2], []);
    assert.strictEqual(f.batches.length, 1);
    assert.match(f.quarantined[0].reasons[0], /another contributor filed/);
});

// --- the opponent model ----------------------------------------------------------------------------------
test('the opponent model: a pattern from several contributors over enough fights is offered with its interval, effective count and calibration; one contributor\'s flood is capped and marked; an outlier weighs half; the general, class, matchup and exact levels all exist', () => {
    const net = network(3, 8, 3, 0.7);
    const m = learn.build(net.batches, net.lessons);
    const G = m.games.Forever;
    const e = G.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed;
    assert.strictEqual(e.unreliable, false, e.why);
    assert.strictEqual(e.chances, 72); assert.strictEqual(e.contributors, 3); assert.strictEqual(e.n, 24);
    assert.ok(e.p > 0.6 && e.p < 0.8, `rate ${e.p}`);
    assert.ok(e.interval[0] < e.p && e.interval[1] > e.p);
    assert.ok(e.n_eff <= e.chances && e.n_eff >= e.n, `effective ${e.n_eff}: between the fights and the chances`);
    assert.ok(e.brier < 0.3); assert.ok(typeof e.calibration.ece === 'number');
    assert.deepStrictEqual(Object.keys(G.groups).sort(), ['g:Forever', 'g:Forever|e:WARRIOR', 'g:Forever|me:HUNTER|e:WARRIOR', 'g:Forever|me:HUNTER|e:WARRIOR|lv:20-29|enc:world_pvp|1v1']);
    assert.strictEqual(G.by_class.WARRIOR.patterns.mobility_when_slowed, e, 'by_class reads the class level');
    // A flood from one contributor: capped at the share, the entry says so.
    const flood = network(1, 60, 3, 0.2, { start: 9 });
    const m2 = learn.build([...net.batches, ...flood.batches], [...net.lessons, ...flood.lessons], { maxPerDay: 1000 });
    const e2 = m2.games.Forever.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed;
    assert.strictEqual(e2.capped, 1, 'one contributor capped');
    assert.ok(e2.outliers && e2.outliers.length === 1, 'and an outlier: its rate stands far from the others');
    assert.ok(e2.p > 0.45, `the flood did not drag the rate to its own 0.2: ${e2.p}`);
    assert.strictEqual(e2.unreliable, false, e2.why);
    // One person alone: dominated and unreliable, said why.
    const alone = learn.build(flood.batches, flood.lessons, { maxPerDay: 1000 });
    const e3 = alone.games.Forever.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed;
    assert.strictEqual(e3.unreliable, true);
    assert.match(e3.why, /1 contributor\(s\), needs 2/); assert.match(e3.why, /one contributor holds more than 60%/);
});

test('the opponent model: nothing merges across the game; a level far from its parent is marked apart; a conditional rate shows with enough behind it; the latest build drifting sets the earlier ones aside', () => {
    const forever = network(3, 8, 3, 0.8);
    const era = network(3, 8, 3, 0.2, { game: 'Vanilla', start: 5 });
    const m = learn.build([...forever.batches, ...era.batches], [...forever.lessons, ...era.lessons]);
    assert.ok(m.games.Forever.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed.p > 0.65);
    assert.ok(m.games.Vanilla.groups[classKey('Vanilla', 'WARRIOR')].patterns.mobility_when_slowed.p < 0.35);
    assert.strictEqual(m.games.Forever.groups['g:Forever'].contributors, 3, 'the general level of one game');
    // A matchup apart from the class: hunters see 0.9, priests facing the same warriors see 0.3.
    const hunters = network(3, 8, 3, 0.9);
    const priests = network(3, 8, 3, 0.3, { start: 5 });
    for (const b of priests.batches) b.me = { class: 'PRIEST', level: 26 };
    for (const l of priests.lessons) l.me = { class: 'PRIEST', level: 26 };
    const m2 = learn.build([...hunters.batches, ...priests.batches], [...hunters.lessons, ...priests.lessons]);
    const h = m2.games.Forever.groups[matchupKey('Forever', 'HUNTER', 'WARRIOR')].patterns.mobility_when_slowed;
    assert.strictEqual(h.separate, true, `hunter matchup apart from the class: ${h.vs_parent}`);
    assert.ok(h.vs_parent > 0.2);
    // Conditional rates: threat HIGH chances miss, LOW ones hit.
    const cond = network(3, 6, 4, 1);
    for (const b of cond.batches) b.observations.forEach((o, i) => { o.context.threat = i % 2 ? 'HIGH' : 'LOW'; o.hit = i % 2 === 0; o.correct = (o.p >= 0.5) === o.hit; });
    const m3 = learn.build(cond.batches, cond.lessons);
    const c = m3.games.Forever.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed.by_condition.threat;
    assert.strictEqual(c.LOW.p, 1); assert.strictEqual(c.HIGH.p, 0); assert.strictEqual(c.LOW.n, 36);
    // Drift: the old build's chances hit, the new build's miss.
    const old = network(3, 6, 3, 1, { build: '1.60.0.70000', day: 0 });
    const neu = network(3, 6, 3, 0, { build: '1.60.1.70338', day: 10 });
    const m4 = learn.build([...old.batches, ...neu.batches], [...old.lessons, ...neu.lessons]);
    const d = m4.games.Forever.groups[classKey('Forever', 'WARRIOR')].patterns.mobility_when_slowed;
    assert.ok(d.drift, 'drift read');
    assert.strictEqual(d.drift.build, '1.60.1.70338'); assert.strictEqual(d.drift.p_now, 0); assert.strictEqual(d.drift.p_before, 1);
    assert.strictEqual(d.basis, 'latest build');
    assert.ok(d.p < 0.1, `the rate is the latest build's: ${d.p}`);
});

// --- tactics ---------------------------------------------------------------------------------------------
test('tactics: an association between following the advice and the result, within comparable contexts, stratified by the confounders, with its interval, its strength, the counterexamples and what told them apart; never a cause; too thin says so', () => {
    const batches = [], lessons = [];
    // Three contributors, five fights each; controlling the distance followed ends well 80%, not followed 20%;
    // the failures when followed come with two attackers.
    for (let c = 1; c <= 3; c++) {
        for (let f = 0; f < 5; f++) {
            const eps = [];
            for (let i = 0; i < 4; i++) {
                const followed = i < 2;
                const good = followed ? (f + i) % 5 !== 0 : (f + i) % 5 === 0;
                eps.push(episode('gap_close_attempt', good ? 'POSITION_IMPROVED' : 'SITUATION_WORSENED', followed,
                    followed && !good ? { before: { hp: 1, zone: 'ranged', gap: 20, threat: 'LOW', attackers: 2, controlled: false, defensives_ready: 2, foe_hp: 1 } } : {}));
            }
            const b = batch(who(c), f, [], { episodes: eps });
            batches.push(b);
            lessons.push(lesson(who(c), f, b.fight, 'won', []));
        }
    }
    const m = learn.build(batches, lessons);
    const t = m.games.Forever.tactics.find(x => x.strategy === 'controlling_distance' && x.level === 'matchup');
    assert.ok(t, 'the matchup-level tactic');
    assert.strictEqual(t.evidence, 'association'); assert.strictEqual(t.causal, false);
    assert.strictEqual(t.better, 'followed');
    assert.ok(t.diff > 0.5, `difference ${t.diff}`);
    assert.ok(t.interval[0] > 0, 'the interval clear of zero');
    assert.strictEqual(t.strength, 'strong'); assert.strictEqual(t.validated, true);
    assert.strictEqual(t.arms.followed.n, 30); assert.strictEqual(t.arms.not_followed.n, 30);
    assert.ok(t.counterexamples.n > 0, 'counterexamples recorded');
    assert.strictEqual(t.counterexamples.distinguishing[0].condition, 'attackers');
    assert.strictEqual(t.counterexamples.distinguishing[0].value, '2+');
    assert.match(t.text, /an association/); assert.match(t.text, /counterexample/);
    assert.ok(typeof t.diff_stratified === 'number');
    // The class level holds the same episodes (hunters only here): present as well.
    assert.ok(m.games.Forever.tactics.find(x => x.strategy === 'controlling_distance' && x.level === 'class'));
    // Preserving the escape and trading cooldowns: arms from what was done, not from the advice.
    const pe = m.games.Forever.tactics.find(x => x.strategy === 'preserve_escape' && x.level === 'matchup');
    assert.ok(pe, 'preserve_escape measured (a defensive was ready, none spent)');
    assert.strictEqual(pe.strength, 'insufficient'); assert.match(pe.why, /arms of 60 and 0/);
    assert.ok(m.limitations.some(l => /protecting allies: not measured/.test(l)));
    // Too thin: one contributor, two fights.
    const thin = learn.build(batches.slice(0, 2), lessons.slice(0, 2));
    const tt = thin.games.Forever.tactics.find(x => x.strategy === 'controlling_distance' && x.level === 'matchup');
    assert.strictEqual(tt.strength, 'insufficient'); assert.strictEqual(tt.validated, false);
    assert.match(tt.why, /needs 6/); assert.match(tt.why, /1 contributor\(s\), needs 2/);
});

test('tactics: a strategy that stopped working lately is marked stale and no longer validated', () => {
    const batches = [], lessons = [];
    for (let c = 1; c <= 3; c++) {
        for (let f = 0; f < 8; f++) {
            const recent = f >= 4;                       // the last four fights are 40 days on
            const eps = [];
            for (let i = 0; i < 3; i++) {
                const good = recent ? i === 0 && f === 4 : true;
                eps.push(episode('gap_close_attempt', good ? 'POSITION_IMPROVED' : 'SITUATION_WORSENED', true));
            }
            for (let i = 0; i < 2; i++) eps.push(episode('gap_close_attempt', 'SITUATION_WORSENED', false));
            const b = batch(who(c), recent ? 40 + f : f, [], { episodes: eps });
            batches.push(b);
            lessons.push(lesson(who(c), recent ? 40 + f : f, b.fight, 'won', []));
        }
    }
    const m = learn.build(batches, lessons);
    const t = m.games.Forever.tactics.find(x => x.strategy === 'controlling_distance' && x.level === 'matchup');
    assert.ok(t.stale, 'stale');
    assert.strictEqual(t.stale.earlier_rate, 1);
    assert.ok(t.stale.recent_rate < 0.2);
    assert.strictEqual(t.validated, false);
    assert.match(t.text, /fell \d+ points in the last 30 days/);
});

// --- the evaluation -------------------------------------------------------------------------------------------
test('evaluation: the later fights test what the earlier ones taught; the candidate beats the prior and is compared with production and the baseline on the same forecasts; the numbers carry their counts; a thin test says so', () => {
    const net = network(3, 12, 3, 0.85);
    const r = evaluate.evaluate(net.batches, net.lessons, null, {});
    assert.strictEqual(r.holdout.fights, 36); assert.strictEqual(r.holdout.train_fights, 25); assert.strictEqual(r.holdout.test_fights, 11);
    assert.strictEqual(r.holdout.enough, true);
    assert.ok(r.holdout.cut_after, 'the time of the cut');
    const m = r.models;
    assert.ok(m.candidate.n === r.holdout.test_forecasts);
    assert.ok(m.candidate.brier < m.prior.brier, `candidate ${m.candidate.brier} beats the prior ${m.prior.brier}`);
    assert.ok(m.candidate.skill > 0);
    assert.strictEqual(m.production, null);
    assert.strictEqual(m.candidate.coverage, 1, 'every test forecast had a usable rate');
    assert.ok(m.candidate.by_level.exact || m.candidate.by_level.matchup || m.candidate.by_level.class, 'the level it came from');
    assert.ok(m.candidate.by_matchup.WARRIOR.n > 0); assert.ok(m.candidate.by_game.Forever.n > 0);
    assert.ok(typeof m.candidate.brier_se === 'number');
    assert.strictEqual(r.comparisons.candidate_vs_production, null);
    assert.ok(['better', 'indistinguishable'].includes(r.comparisons.candidate_vs_prior.verdict));
    // With a production model that forecasts the wrong way, the candidate is better, paired by fight.
    const wrong = learn.build(network(3, 12, 3, 0.15).batches, []);
    const r2 = evaluate.evaluate(net.batches, net.lessons, wrong, {});
    assert.ok(r2.models.production.brier > r2.models.candidate.brier);
    assert.strictEqual(r2.comparisons.candidate_vs_production.verdict, 'better');
    assert.ok(r2.comparisons.candidate_vs_production.fights === 11);
    // A thin test: said so.
    const thin = evaluate.evaluate(net.batches.slice(0, 4), net.lessons.slice(0, 4), null, {});
    assert.strictEqual(thin.holdout.enough, false); assert.match(thin.holdout.note, /fewer than 10/);
    // Stability between two full models.
    const s = evaluate.stability(learn.build(net.batches, net.lessons), learn.build(net.batches, net.lessons));
    assert.strictEqual(s.patterns.steady, 1);
});

// --- the release ------------------------------------------------------------------------------------------------
test('release: the first cycle publishes a full version when the gates pass; one contributor is rejected and nothing is written but the evaluation and the audit; a later cycle with nothing material holds; with enough new fights it publishes a canary; promote rolls it out; withdraw rolls back', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-release-'));
    const store = createStore(dir, { now: () => Date.UTC(2026, 9, 20) });
    const one = network(1, 10, 3, 0.8);
    for (const b of one.batches) store.accept('batch', b);
    for (const l of one.lessons) store.accept('lesson', l);
    let r = release.cycle(store, {});
    assert.strictEqual(r.decision, 'reject'); assert.strictEqual(r.version, null);
    assert.deepStrictEqual(r.verdict.failed, ['contributors', 'content']);
    assert.strictEqual(store.readManifest().versions.length, 0);
    assert.strictEqual(store.evaluations().length, 1);
    assert.strictEqual(store.readAudit()[0].kind, 'cycle'); assert.strictEqual(store.readAudit()[0].action, 'reject');
    // Two more contributors: the gates pass, the first version is full.
    const more = network(2, 10, 3, 0.8, { start: 2 });
    for (const b of more.batches) store.accept('batch', b);
    for (const l of more.lessons) store.accept('lesson', l);
    r = release.cycle(store, { note: 'first' });
    assert.strictEqual(r.decision, 'publish'); assert.strictEqual(r.version, '1'); assert.strictEqual(r.stage, 'full');
    const m1 = store.readManifest().versions[0];
    assert.strictEqual(m1.status, 'active'); assert.strictEqual(m1.stage, 'full'); assert.strictEqual(m1.rollout, 100); assert.strictEqual(m1.rollback, null);
    assert.strictEqual(m1.gates.decision, 'publish');
    const pkg = store.readModel('1');
    assert.strictEqual(pkg.version, '1');
    assert.deepStrictEqual(pkg.compatibility.games, ['Forever']);
    assert.ok(pkg.release.gates.checks.length >= 4);
    assert.ok(pkg.release.evaluation.holdout.test_forecasts > 0);
    assert.ok(Array.isArray(pkg.release.known_limitations));
    assert.strictEqual(pkg.release.rollback, null);
    // Nothing arrived: unchanged, and nothing is written (no evaluation row, no audit row).
    const rows = store.evaluations().length;
    r = release.cycle(store, {});
    assert.strictEqual(r.decision, 'unchanged'); assert.strictEqual(r.version, null);
    assert.match(r.verdict.material.why, /no record since the last cycle/);
    assert.strictEqual(store.evaluations().length, rows, 'no evaluation written');
    // Two new fights: not material, held; no new version.
    const two = network(2, 1, 3, 0.8, { start: 2, day: 15 });
    for (const b of two.batches) store.accept('batch', b);
    for (const l of two.lessons) store.accept('lesson', l);
    r = release.cycle(store, {});
    assert.strictEqual(r.decision, 'hold'); assert.strictEqual(r.version, null);
    assert.match(r.verdict.material.why, /2 fight\(s\) since v1/);
    assert.strictEqual(store.readManifest().versions.length, 1);
    // Twenty new fights: a canary.
    const fresh = network(2, 10, 3, 0.8, { start: 2, day: 20 });
    for (const b of fresh.batches) store.accept('batch', b);
    for (const l of fresh.lessons) store.accept('lesson', l);
    r = release.cycle(store, {});
    assert.strictEqual(r.decision, 'publish'); assert.strictEqual(r.version, '2'); assert.strictEqual(r.stage, 'canary');
    const m2 = store.readManifest().versions[1];
    assert.strictEqual(m2.rollout, 25); assert.strictEqual(m2.rollback, '1');
    assert.strictEqual(store.readModel('2').release.rollback.to, '1');
    assert.strictEqual(store.activeVersion().version, '1', 'production is still the full one');
    assert.strictEqual(release.promote(store, '2'), true);
    assert.strictEqual(store.readManifest().versions[1].stage, 'full');
    assert.strictEqual(store.activeVersion().version, '2');
    assert.strictEqual(release.withdraw(store, '2'), true);
    assert.strictEqual(store.activeVersion().version, '1', 'rolled back');
    assert.strictEqual(release.promote(store, '2'), false, 'a withdrawn version is not promoted');
    const kinds = store.readAudit().map(a => a.kind);
    assert.deepStrictEqual(kinds, ['cycle', 'publish', 'cycle', 'publish', 'promote', 'withdraw']);
    // Forced past the gates: written as such.
    const empty = createStore(fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-release-')), {});
    const f = release.cycle(empty, { force: true, note: 'by hand' });
    assert.strictEqual(f.decision, 'forced'); assert.strictEqual(f.version, '1');
    assert.strictEqual(empty.readManifest().versions[0].gates.forced, true);
    assert.deepStrictEqual(empty.readManifest().versions[0].gates.failed, ['contributors', 'content']);
});

test('release: a candidate that forecasts worse than production on the holdout is rejected; the monitoring reads the forecasts made under each version', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-release-'));
    const store = createStore(dir, { now: () => Date.UTC(2026, 9, 20) });
    const good = network(3, 10, 3, 0.85);
    for (const b of good.batches) store.accept('batch', b);
    for (const l of good.lessons) store.accept('lesson', l);
    assert.strictEqual(release.cycle(store, {}).version, '1');
    // Then a wave the other way, and the latest fights test it: the rate flips, the candidate forecasts worse.
    const bad = network(3, 20, 3, 0.15, { day: 20 });
    for (const b of bad.batches) { b.client.model = '1'; store.accept('batch', b); }
    for (const l of bad.lessons) store.accept('lesson', l);
    const r = release.cycle(store, {});
    assert.ok(r.verdict.checks.find(c => c.name === 'not worse than production'), 'production compared');
    const mon = r.candidate.games.Forever.monitoring['1'];
    assert.ok(mon && mon.n === 180, 'the forecasts made under v1 are read');
    assert.ok(typeof mon.brier === 'number');
});

test('release: preview writes nothing', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'jambix-release-'));
    const store = createStore(dir, {});
    const net = network(3, 10, 3, 0.8);
    for (const b of net.batches) store.accept('batch', b);
    const p = release.preview(store, {});
    assert.strictEqual(p.verdict.decision, 'publish');
    assert.strictEqual(p.candidate.version, 'candidate');
    assert.strictEqual(store.readManifest().versions.length, 0);
    assert.strictEqual(store.evaluations().length, 0);
});

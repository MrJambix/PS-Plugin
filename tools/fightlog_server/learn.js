'use strict';
// Jambix central service -- the global learning engine (the brief of
// 2026-10-12, "Global PvP Learning, Prediction & Tactical Knowledge
// Engine"). From the records the trust screen let through (trust.js) it
// builds, per game variant and never across one:
//
//   groups     the learning groups at four levels (groups.js): per pattern the
//              eligible chances, the weighted hits and misses, the censored
//              ones, the sample's diversity, a rate with its uncertainty, the
//              forecast quality as the forecasts stood (Brier, calibration),
//              the conditional rates, the drift by build, whether the level
//              differs from its parent -- and `unreliable` with `why`
//   by_class   the class-level view the clients and the knowledge routes read:
//              outcomes, the lesson codes that told won from lost, abilities
//              (verified by several contributors), the episodes' histograms
//   tactics    the strategies the brief names, each as an association between
//              what was done and what was measured within comparable contexts,
//              stratified by the confounders the records carry, with the
//              counterexamples and the conditions that told them apart, and
//              whether it stopped working lately
//   monitoring the forecast quality of the observations made under each
//              published model version (what the rollout did in play)
//
// Nothing here is a fact: every number carries its count, every finding its
// strength, and a tactic is an association, never a cause.

const groups = require('./groups');
const trust = require('./trust');

const LESSON_TEXT = {
    defensive_unused: 'a defensive stayed ready through danger',
    slow_unused: 'a melee player stayed unslowed',
    trap_unused: 'the trap was never laid',
    kill_missed: 'a kill window got away',
    own_cc_broken: 'your own control was broken by your hit',
    cast_unstopped: 'a dangerous cast was not stopped',
    controlled: 'you were controlled',
    burst_lost: 'its burst took the fight',
    trinket_spent: 'it spent its trinket',
    trap_won: 'the trap was laid',
    hold_won: 'your controls were kept',
};

const DEFAULTS = {
    minChances: 20,          // weighted chances a pattern needs before its rate is offered
    minContributors: 2,      // one person's fights are not a network
    minEff: 10,              // effective chances (fights are clusters) a rate needs
    maxBrier: 0.30,          // a forecast quality worse than this is not offered as a prior
    minInputsOk: 0.5,        // fewer verified inputs than this and the misses are suspect
    priorWeight: 2,          // the rate shrinks toward 0.5 by this many chances
    maxShare: 0.4,           // one contributor's share of a group's weight, with three or more contributors
    dominatedShare: 0.6,     // past this share the group is one person's and is not offered
    outlierMin: 8,           // a contributor with this many chances is compared with the others
    outlierDelta: 0.4,       // this far from the others' rate: an outlier, weighing half
    driftMin: 10,            // chances on the latest build and on the earlier ones before drift is read
    driftDelta: 0.25,        // the rates this far apart: the earlier builds' knowledge is set aside
    separateDelta: 0.2,      // a level this far from its parent needs its own model
    conditionMin: 5,         // a conditional rate shows with this many chances
    minLessonFights: 5,      // fights an advice line needs
    minEpisodes: 6,          // measured episodes a validated episode lesson needs
    agree: 0.6,              // the share of them with the same result
    minArm: 6,               // measured episodes each arm of a tactic needs
    minArmFights: 3,         // fights each arm needs (episodes of one fight are not independent)
    strongDelta: 0.2,        // a difference this large with the interval clear of zero is strong
    staleDays: 30,           // the recent window a tactic is checked against its earlier self
    staleDrop: 0.25,         // the good rate falling this much lately: stale
    abilityContributors: 2,  // an ability is verified when this many contributors saw it
};

// --- what a spell is, by name (the only thing the records carry) -------------------------
const ROLES = {
    SLOWS: ['Wing Clip', 'Concussive Shot', 'Hamstring', 'Frost Shock', 'Frostbolt', 'Cone of Cold', 'Crippling Poison', 'Curse of Exhaustion', 'Earthbind Totem', 'Piercing Howl'],
    CONTROLS: ['Freezing Trap', 'Scatter Shot', 'Frost Nova', 'Entangling Roots', 'Polymorph', 'Fear', 'Psychic Scream', 'Hammer of Justice', 'Kidney Shot',
        'Cheap Shot', 'Gouge', 'Blind', 'Sap', 'Bash', 'Hibernate', 'Scare Beast', 'Wyvern Sting', 'Intimidation', 'Death Coil', 'Howl of Terror', 'Seduction',
        'Repentance', 'Charge', 'Intercept', 'Concussion Blow', 'Pounce', 'Maim'],
    INTERRUPTS: ['Counterspell', 'Kick', 'Pummel', 'Shield Bash', 'Earth Shock', 'Silencing Shot', 'Feral Charge', 'Spell Lock'],
    ESCAPES: ['Feign Death', 'Disengage', 'Blink', 'Vanish', 'Sprint', 'Escape Artist', 'Will of the Forsaken', 'Travel Form', 'Dash', 'Ghost Wolf',
        'Blessing of Freedom', 'Insignia of the Alliance', 'Insignia of the Horde', 'Cat Form'],
    DEFENSIVES: ['Deterrence', 'Evasion', 'Ice Block', 'Divine Shield', 'Divine Protection', 'Shield Wall', 'Last Stand', 'Barkskin', 'Power Word: Shield',
        'Frenzied Regeneration', 'Cloak of Shadows', 'Ice Barrier', 'Mana Shield', 'Stoneform', 'Lay on Hands', 'Blessing of Protection', 'Shadow Ward', 'Bear Form', 'Dire Bear Form'],
};
const SET = Object.fromEntries(Object.entries(ROLES).map(([k, v]) => [k, new Set(v)]));
const MAJOR = new Set([...ROLES.ESCAPES, ...ROLES.DEFENSIVES]);
const MINOR = new Set([...ROLES.SLOWS, ...ROLES.CONTROLS, ...ROLES.INTERRUPTS]);

const GOOD = new Set(['SURVIVAL_IMPROVED', 'POSITION_IMPROVED', 'DAMAGE_OPPORTUNITY_CREATED', 'CONTROL_SUCCESSFUL', 'COOLDOWN_SAVED', 'OBJECTIVE_PROGRESS']);
const BAD = 'SITUATION_WORSENED';

const STRATEGY_TEXT = {
    controlling_distance: 'controlling the distance',
    interrupting_casts: 'interrupting the cast',
    waiting_out_defensive: 'waiting out the defensive',
    managing_pet_in_cc: 'managing the pet during control',
    creating_kill_opportunity: 'pressing the kill opportunity',
    disengaging_under_pressure: 'disengaging under pressure',
    preserve_escape: 'preserving the escape',
    trading_cooldowns: 'trading a minor cooldown rather than a major one',
};
const NOT_MEASURED = { protecting_allies: 'no record carries an ally\'s state; nothing to compare' };

// --- small numbers -------------------------------------------------------------------------
const r3 = x => Number(x.toFixed(3));
const r2 = x => Number(x.toFixed(2));
const hpBand = hp => (typeof hp !== 'number' ? '?' : hp <= 0.2 ? 0 : hp <= 0.4 ? 1 : hp <= 0.6 ? 2 : hp <= 0.8 ? 3 : 4);
const HIGH = new Set(['HIGH', 'CRITICAL']);
// Observations of one fight are not independent: the effective count of a
// set of fight weights is (sum w)^2 / sum w^2 (the design-effect form).
function neff(perFight) {
    let s = 0, s2 = 0;
    for (const w of Object.values(perFight)) { s += w; s2 += w * w; }
    return s2 > 0 ? s * s / s2 : 0;
}
function halfWidth(p, n) { return 1.96 * Math.sqrt(Math.max(p * (1 - p), 0.0025) / (n + 2)); }
const bandOf = p => (p < 0.4 ? 'low' : p < 0.6 ? 'mid' : 'high');

// --- the opponent model of one (group, pattern): from its rows to its entry --------------------
function patternEntry(rows, censored, o, parentEntry) {
    // 1. Weights: source quality, then each contributor's share capped, then the outliers.
    const byC = {};
    for (const r of rows) { r.w = trust.observationWeight(r, o); byC[r.contributor] = (byC[r.contributor] || 0) + r.w; }
    const contributors = Object.keys(byC);
    let total = Object.values(byC).reduce((a, b) => a + b, 0);
    const capped = [];
    if (contributors.length >= 3) {
        for (let pass = 0; pass < 3; pass++) {
            for (const c of contributors) {
                const share = byC[c] / total;
                if (share > o.maxShare) {
                    const f = (o.maxShare * total) / byC[c];
                    for (const r of rows) if (r.contributor === c) r.w *= f;
                    byC[c] *= f;
                    if (!capped.includes(c)) capped.push(c);
                    total = Object.values(byC).reduce((a, b) => a + b, 0);
                }
            }
        }
    }
    // An outlier: a contributor whose own rate stands far from the others'.
    // The reference is the median of the other contributors' own rates --
    // one vote each, whatever their volume -- so a flood cannot make the
    // honest ones the outliers (robust aggregation).
    const outliers = [];
    const ownRate = {};
    for (const c of contributors) {
        const mine = rows.filter(r => r.contributor === c);
        if (mine.length >= o.outlierMin) ownRate[c] = mine.filter(r => r.hit).length / mine.length;
    }
    for (const [c, pm] of Object.entries(ownRate)) {
        const others = Object.entries(ownRate).filter(([k]) => k !== c).map(([, v]) => v).sort((a, b) => a - b);
        if (!others.length) continue;
        const ref = others.length % 2 ? others[(others.length - 1) / 2] : (others[others.length / 2 - 1] + others[others.length / 2]) / 2;
        if (Math.abs(pm - ref) >= o.outlierDelta) {
            const mine = rows.filter(r => r.contributor === c);
            outliers.push({ contributor: c.slice(0, 6), chances: mine.length, own_rate: r2(pm), others_rate: r2(ref) });
            for (const r of mine) r.w *= 0.5;
        }
    }
    const dominated = contributors.length > 0 && Math.max(...contributors.map(c => rows.filter(r => r.contributor === c).reduce((a, r) => a + r.w, 0))) / rows.reduce((a, r) => a + r.w, 0) > o.dominatedShare;

    // 2. Drift by build: the latest build against the earlier ones.
    const builds = {};
    for (const r of rows) {
        const b = builds[r.build] || (builds[r.build] = { n: 0, hits: 0, w: 0, hw: 0, first: r.at, last: r.at });
        b.n += 1; b.w += r.w; if (r.hit) { b.hits += 1; b.hw += r.w; }
        if (r.at && (!b.first || r.at < b.first)) b.first = r.at;
        if (r.at && (!b.last || r.at > b.last)) b.last = r.at;
    }
    const buildKeys = Object.keys(builds).sort((a, b) => String(builds[b].last || '').localeCompare(String(builds[a].last || '')));
    let drift = null, used = rows;
    if (buildKeys.length >= 2) {
        const latest = buildKeys[0];
        const now = builds[latest], rest = buildKeys.slice(1).reduce((a, k) => ({ n: a.n + builds[k].n, hits: a.hits + builds[k].hits }), { n: 0, hits: 0 });
        if (now.n >= o.driftMin && rest.n >= o.driftMin) {
            const pn = now.hits / now.n, pr = rest.hits / rest.n;
            if (Math.abs(pn - pr) >= o.driftDelta) {
                drift = { build: latest, p_now: r2(pn), n_now: now.n, p_before: r2(pr), n_before: rest.n, note: 'the earlier builds\' chances are set aside for the rate' };
                used = rows.filter(r => r.build === latest);
            }
        }
    }

    // 3. The rate, its uncertainty, the forecast quality as the forecasts stood.
    const perFight = {};
    let hw = 0, cw = 0, hits = 0;
    for (const r of used) { cw += r.w; if (r.hit) { hw += r.w; hits += 1; } perFight[r.fight] = (perFight[r.fight] || 0) + r.w; }
    const n_eff = neff(perFight);
    const p = (hw + o.priorWeight * 0.5) / (cw + o.priorWeight);
    const half = halfWidth(p, n_eff);
    let brier = 0, inputs = 0, sure = 0, sureRight = 0;
    const bands = { low: { n: 0, hits: 0, sum_p: 0 }, mid: { n: 0, hits: 0, sum_p: 0 }, high: { n: 0, hits: 0, sum_p: 0 } };
    for (const r of rows) {
        brier += (r.p - (r.hit ? 1 : 0)) ** 2;
        if (r.inputs_ok) inputs += 1;
        if (r.sure) { sure += 1; if (r.correct) sureRight += 1; }
        const b = bands[bandOf(r.p)]; b.n += 1; b.sum_p += r.p; if (r.hit) b.hits += 1;
    }
    brier = rows.length ? brier / rows.length : 1;
    let ece = 0;
    for (const b of Object.values(bands)) if (b.n > 0) ece += (b.n / rows.length) * Math.abs(b.sum_p / b.n - b.hits / b.n);
    const inputsShare = rows.length ? inputs / rows.length : 0;

    // 4. The conditional rates (threat, your health) with enough behind them.
    const by_condition = { threat: {}, me_hp: {} };
    const cond = (map, k, r) => { if (k === undefined || k === null) return; const x = map[k] || (map[k] = { n: 0, hits: 0 }); x.n += 1; if (r.hit) x.hits += 1; };
    for (const r of rows) { cond(by_condition.threat, r.threat, r); cond(by_condition.me_hp, r.me_hp, r); }
    for (const map of Object.values(by_condition)) {
        for (const [k, x] of Object.entries(map)) { if (x.n < o.conditionMin) delete map[k]; else map[k] = { n: x.n, p: r2(x.hits / x.n) }; }
    }

    // 5. Reliability, said why.
    const why = [];
    if (cw < o.minChances) why.push(`${r2(cw)} weighted chance(s), needs ${o.minChances}`);
    if (contributors.length < o.minContributors) why.push(`${contributors.length} contributor(s), needs ${o.minContributors}`);
    if (n_eff < o.minEff) why.push(`${r2(n_eff)} effective chance(s) over ${Object.keys(perFight).length} fight(s), needs ${o.minEff}`);
    if (brier > o.maxBrier) why.push(`forecast quality ${brier.toFixed(2)} worse than ${o.maxBrier}`);
    if (inputsShare < o.minInputsOk) why.push(`only ${(inputsShare * 100).toFixed(0)}% of chances with verified inputs`);
    if (dominated) why.push(`one contributor holds more than ${(o.dominatedShare * 100).toFixed(0)}% of the weight`);

    const fights = new Set(rows.map(r => r.fight));
    const entry = {
        p: r3(p), interval: [r3(Math.max(0, p - half)), r3(Math.min(1, p + half))], uncertainty: r3(half),
        chances: rows.length, hits, misses: rows.length - hits, censored: censored || 0,
        weighted: { chances: r2(cw), hits: r2(hw) }, n: fights.size, n_eff: r2(n_eff), contributors: contributors.length,
        brier: r3(brier), calibration: { ece: r3(ece), bands: Object.fromEntries(Object.entries(bands).map(([k, b]) => [k, { n: b.n, hit_rate: b.n ? r2(b.hits / b.n) : null, mean_p: b.n ? r2(b.sum_p / b.n) : null }])) },
        inputs_ok: r2(inputsShare), sure_forecasts: sure, sure_right: sureRight,
        by_condition, drift, basis: drift ? 'latest build' : 'all builds',
        compatibility: { builds: buildKeys, first_seen: rows.reduce((a, r) => (r.at && (!a || r.at < a) ? r.at : a), null), last_seen: rows.reduce((a, r) => (r.at && (!a || r.at > a) ? r.at : a), null) },
        capped: capped.length ? capped.length : undefined, outliers: outliers.length ? outliers : undefined, dominated: dominated || undefined,
        unreliable: why.length > 0, why: why.length ? why.join('; ') : undefined,
    };
    if (parentEntry && n_eff >= o.minEff && parentEntry.n_eff >= o.minEff) {
        const d = p - parentEntry.p;
        entry.vs_parent = r3(d);
        if (Math.abs(d) >= o.separateDelta) entry.separate = true;
    }
    return entry;
}

// --- the tactics: what was done against what was measured, within a group ---------------------
function strategyOf(e) {
    const r = e.recommendation || {}, action = String(r.action || ''), move = r.move;
    const type = e.type;
    if (type === 'pet_breaks_cc') return 'managing_pet_in_cc';
    if (type === 'kill_opportunity') return 'creating_kill_opportunity';
    if (type === 'defensive_change') return 'waiting_out_defensive';
    if (SET.INTERRUPTS.has(action)) return 'interrupting_casts';
    if ((type === 'outnumbered' || type === 'rooted_under_pressure' || type === 'enemy_burst') && MAJOR.has(action)) return 'disengaging_under_pressure';
    if ((type === 'gap_close_attempt' || type === 'dead_zone_entry' || type === 'rogue_opener' || type === 'blink') &&
        (SET.SLOWS.has(action) || SET.CONTROLS.has(action) || (move && move !== 'none'))) return 'controlling_distance';
    return null;
}
const PRESERVE_TYPES = new Set(['gap_close_attempt', 'rooted_under_pressure', 'outnumbered', 'enemy_burst', 'rogue_opener']);

function tacticRows(e, meta) {
    if (!trust.episodeCounts(e)) return [];
    const b = e.before || {};
    const primary = e.result.primary;
    const base = Object.assign({
        good: GOOD.has(primary), bad: primary === BAD, result: primary,
        strata: `${hpBand(b.hp)}|${(b.attackers || 0) >= 2}|${HIGH.has(b.threat)}|${(b.defensives_ready || 0) > 0}`,
        conditions: { me_hp: hpBand(b.hp), attackers: (b.attackers || 0) >= 2 ? '2+' : (b.attackers || 0), threat: b.threat || '?',
            defensives_ready: (b.defensives_ready || 0) > 0 ? 'some' : 'none', zone: b.zone || '?', foe_hp: hpBand(b.foe_hp), controlled: b.controlled === true },
    }, meta);
    const out = [];
    const s = strategyOf(e);
    const ro = e.recommendation && e.recommendation.outcome;
    if (s && (ro === 'FOLLOWED' || ro === 'NOT_FOLLOWED')) out.push(Object.assign({ strategy: s, arm: ro === 'FOLLOWED' ? 'followed' : 'not_followed' }, base));
    const actions = e.actions || [];
    const spentMajor = actions.some(a => MAJOR.has(a)), spentMinor = actions.some(a => MINOR.has(a));
    if (PRESERVE_TYPES.has(e.type) && (b.defensives_ready || 0) > 0) out.push(Object.assign({ strategy: 'preserve_escape', arm: spentMajor ? 'spent' : 'kept' }, base));
    if (actions.length > 0 && (spentMajor || spentMinor)) out.push(Object.assign({ strategy: 'trading_cooldowns', arm: spentMajor ? 'major' : 'minor' }, base));
    return out;
}

const ARMS = {
    controlling_distance: ['followed', 'not_followed'], interrupting_casts: ['followed', 'not_followed'], waiting_out_defensive: ['followed', 'not_followed'],
    managing_pet_in_cc: ['followed', 'not_followed'], creating_kill_opportunity: ['followed', 'not_followed'], disengaging_under_pressure: ['followed', 'not_followed'],
    preserve_escape: ['kept', 'spent'], trading_cooldowns: ['minor', 'major'],
};

function armStats(rows) {
    const perFight = {};
    for (const r of rows) perFight[r.fight] = (perFight[r.fight] || 0) + 1;
    const good = rows.filter(r => r.good).length, bad = rows.filter(r => r.bad).length;
    return { n: rows.length, fights: Object.keys(perFight).length, n_eff: r2(neff(perFight)), contributors: new Set(rows.map(r => r.contributor)).size,
        good, bad, neutral: rows.length - good - bad, good_rate: rows.length ? r2(good / rows.length) : null };
}

function tactic(strategy, rows, desc, o, newestAt) {
    const [A, B] = ARMS[strategy];
    const ra = rows.filter(r => r.arm === A), rb = rows.filter(r => r.arm === B);
    const a = armStats(ra), b = armStats(rb);
    const out = { strategy, text_of: STRATEGY_TEXT[strategy], level: desc.level, game: desc.game, me_class: desc.me_class, enemy_class: desc.enemy_class,
        arms: { [A]: a, [B]: b }, evidence: 'association', causal: false, confounders: ['your health', 'attackers', 'threat', 'a defensive ready'],
        not_accounted: ['gear', 'skill', 'teammates', 'the opponent\'s cooldowns'] };
    const why = [];
    if (a.n < o.minArm || b.n < o.minArm) why.push(`arms of ${a.n} and ${b.n} measured episode(s), each needs ${o.minArm}`);
    if (a.fights < o.minArmFights || b.fights < o.minArmFights) why.push(`arms over ${a.fights} and ${b.fights} fight(s), each needs ${o.minArmFights}`);
    const contributors = new Set(rows.map(r => r.contributor)).size;
    if (contributors < o.minContributors) why.push(`${contributors} contributor(s), needs ${o.minContributors}`);
    if (why.length) { out.strength = 'insufficient'; out.validated = false; out.why = why.join('; '); return out; }
    const pa = a.good / a.n, pb = b.good / b.n;
    const diff = pa - pb;
    const se = Math.sqrt(Math.max(pa * (1 - pa), 0.0025) / a.n_eff + Math.max(pb * (1 - pb), 0.0025) / b.n_eff);
    const ci = [r2(diff - 1.96 * se), r2(diff + 1.96 * se)];
    // Stratified by the confounders: only strata holding both arms, weighted by their size.
    const strata = {};
    for (const r of rows) { const s = strata[r.strata] || (strata[r.strata] = { a: [], b: [] }); (r.arm === A ? s.a : s.b).push(r); }
    let sw = 0, sdiff = 0, both = 0;
    for (const s of Object.values(strata)) {
        if (!s.a.length || !s.b.length) continue;
        const n = s.a.length + s.b.length;
        sw += n; both += 1;
        sdiff += n * (s.a.filter(r => r.good).length / s.a.length - s.b.filter(r => r.good).length / s.b.length);
    }
    out.diff = r2(diff); out.interval = ci; out.diff_stratified = sw > 0 ? r2(sdiff / sw) : null; out.strata_compared = both;
    const better = diff > 0 ? A : diff < 0 ? B : null;
    out.better = better;
    const clear = ci[0] > 0 || ci[1] < 0;
    out.strength = !clear ? 'weak' : Math.abs(diff) >= o.strongDelta ? 'strong' : 'moderate';
    if (out.diff_stratified !== null && Math.sign(out.diff_stratified) !== Math.sign(diff) && out.diff_stratified !== 0) {
        out.strength = 'weak';
        out.note = 'the stratified difference points the other way: the confounders carry it';
    }
    out.validated = out.strength === 'moderate' || out.strength === 'strong';
    // Counterexamples in the better arm, and what told them from the successes.
    if (better) {
        const win = better === A ? ra : rb;
        const ok = win.filter(r => r.good), ko = win.filter(r => !r.good);
        const distinguishing = [];
        if (ko.length >= 2) {
            for (const key of ['me_hp', 'attackers', 'threat', 'defensives_ready', 'zone', 'foe_hp', 'controlled']) {
                const values = new Set(win.map(r => String(r.conditions[key])));
                for (const v of values) {
                    const inKo = ko.filter(r => String(r.conditions[key]) === v).length, inOk = ok.filter(r => String(r.conditions[key]) === v).length;
                    if (inKo + inOk < 2) continue;
                    const gap = inKo / ko.length - (ok.length ? inOk / ok.length : 0);
                    if (gap >= 0.3) distinguishing.push({ condition: key, value: v, in_failures: `${inKo} of ${ko.length}`, in_successes: `${inOk} of ${ok.length}`, gap: r2(gap) });
                }
            }
            distinguishing.sort((x, y) => y.gap - x.gap);
        }
        out.counterexamples = { n: ko.length, share: r2(ko.length / win.length), results: ko.reduce((m, r) => (m[r.result] = (m[r.result] || 0) + 1, m), {}), distinguishing: distinguishing.slice(0, 3) };
        // Stopped working lately?
        if (newestAt) {
            const cut = newestAt - o.staleDays * 86400 * 1000;
            const recent = win.filter(r => r.at && Date.parse(r.at) >= cut), earlier = win.filter(r => !(r.at && Date.parse(r.at) >= cut));
            if (recent.length >= o.minArm && earlier.length >= o.minArm) {
                const pr = recent.filter(r => r.good).length / recent.length, pe = earlier.filter(r => r.good).length / earlier.length;
                out.stale = pe - pr >= o.staleDrop ? { recent_rate: r2(pr), recent_n: recent.length, earlier_rate: r2(pe), earlier_n: earlier.length, why: `the good rate fell ${((pe - pr) * 100).toFixed(0)} points in the last ${o.staleDays} days` } : null;
                if (out.stale) out.validated = false;
            }
        }
    }
    const who = `${desc.me_class ? desc.me_class.toLowerCase() + ' ' : ''}against a ${desc.enemy_class.toLowerCase()} on ${desc.game}`;
    out.text = `${who}: ${STRATEGY_TEXT[strategy]} -- ${A.replace(/_/g, ' ')} ended well in ${(pa * 100).toFixed(0)}% of ${a.n} episode(s), ${B.replace(/_/g, ' ')} in ${(pb * 100).toFixed(0)}% of ${b.n} (difference ${diff >= 0 ? '+' : ''}${(diff * 100).toFixed(0)} points, interval ${ci[0] >= 0 ? '+' : ''}${(ci[0] * 100).toFixed(0)} to ${ci[1] >= 0 ? '+' : ''}${(ci[1] * 100).toFixed(0)}; ${out.strength}, an association)` +
        (out.counterexamples && out.counterexamples.n ? `; ${out.counterexamples.n} counterexample(s)` + (out.counterexamples.distinguishing[0] ? ` told by ${out.counterexamples.distinguishing[0].condition} = ${out.counterexamples.distinguishing[0].value}` : '') : '') +
        (out.stale ? `; ${out.stale.why}` : '');
    return out;
}

// --- the build ----------------------------------------------------------------------------------
function build(batchesIn, lessonsIn, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const screened = trust.screen(batchesIn, lessonsIn, o);
    const batches = screened.batches, lessons = screened.lessons;
    const fightOf = r => String(r.fight || r.id);
    const atOf = r => r.received_at || null;
    let newestAt = 0;
    for (const r of [...batches, ...lessons]) { const t = r.received_at ? Date.parse(r.received_at) : NaN; if (Number.isFinite(t) && t > newestAt) newestAt = t; }
    const enemiesOf = {};                 // fight -> opponents in it (the lesson says)
    for (const l of lessons) enemiesOf[fightOf(l)] = Array.isArray(l.enemies) ? l.enemies.length : undefined;

    const games = {};
    const game = g => (games[g] || (games[g] = { fights: new Set(), contributors: new Set(), builds: {}, plugins: new Set(), classes: {}, groups: {}, tacticRows: {}, monitoring: {} }));
    const cls = (G, c) => (G.classes[c] || (G.classes[c] = { patterns: {}, outcomes: {}, lessons: {}, abilities: {}, fights: new Set(), lesson_fights: new Set(), contributors: new Set(), episodes: {} }));
    const grp = (G, key, desc) => (G.groups[key] || (G.groups[key] = { desc, rows: {}, censored: {}, fights: new Set(), contributors: new Set() }));
    const contributors = new Set(), fightIds = new Set();
    let observations = 0, episodesSeen = 0;

    for (const b of batches) {
        const G = game(String(b.client && b.client.game || '?'));
        const fid = fightOf(b);
        contributors.add(b.contributor); fightIds.add(fid); G.fights.add(fid); G.contributors.add(b.contributor);
        const build_ = String(b.client && b.client.build || '?');
        (G.builds[build_] || (G.builds[build_] = new Set())).add(fid);
        if (b.client && b.client.plugin) G.plugins.add(String(b.client.plugin));
        const modelV = b.client && b.client.model ? String(b.client.model) : null;
        for (const ob of b.observations || []) {
            observations += 1;
            const ctx = groups.contextOf(b, ob.enemy_class, { enemies: enemiesOf[fid] });
            const c = cls(G, ctx.enemy_class);
            c.fights.add(fid); c.contributors.add(b.contributor);
            const row = { contributor: b.contributor, fight: fid, build: ctx.build, at: atOf(b), p: ob.p, hit: ob.hit === true, sure: ob.sure === true, correct: ob.correct === true,
                inputs_ok: ob.inputs_ok === true, threat: ob.context && ob.context.threat, me_hp: ob.context && ob.context.me_hp };
            for (const { level, key } of groups.keysOf(ctx)) {
                const g = grp(G, key, groups.describe(ctx, level));
                g.fights.add(fid); g.contributors.add(b.contributor);
                (g.rows[ob.pattern] || (g.rows[ob.pattern] = [])).push(Object.assign({}, row));
            }
            if (modelV) {
                const m = G.monitoring[modelV] || (G.monitoring[modelV] = { n: 0, brier: 0, hits: 0, fights: new Set(), contributors: new Set() });
                m.n += 1; m.brier += (ob.p - (ob.hit ? 1 : 0)) ** 2; if (ob.hit) m.hits += 1; m.fights.add(fid); m.contributors.add(b.contributor);
            }
        }
        for (const e of b.episodes || []) {
            if (e.quality && e.quality.test_data) continue;
            episodesSeen += 1;
            const ctx = groups.contextOf(b, e.enemy_class, { enemies: Number.isInteger(e.before && e.before.attackers) && e.before.attackers >= 2 ? e.before.attackers : enemiesOf[fid] });
            const c = cls(G, ctx.enemy_class);
            c.fights.add(fid); c.contributors.add(b.contributor);
            episodeInto(c, e, b.contributor);
            const po = e.prediction && e.prediction.outcome, pat = e.prediction && e.prediction.pattern;
            const meta = { contributor: b.contributor, fight: fid, at: atOf(b) };
            for (const { level, key } of groups.keysOf(ctx)) {
                const g = grp(G, key, groups.describe(ctx, level));
                if (po === 'CENSORED' && pat) g.censored[pat] = (g.censored[pat] || 0) + 1;
                if (level === 'general') continue;              // a tactic against "anyone" says nothing
                for (const tr of tacticRows(e, meta)) (G.tacticRows[`${key}|${tr.strategy}`] || (G.tacticRows[`${key}|${tr.strategy}`] = { desc: groups.describe(ctx, level), rows: [] })).rows.push(tr);
            }
        }
    }
    for (const l of lessons) {
        const G = game(String(l.client && l.client.game || '?'));
        const fid = fightOf(l);
        contributors.add(l.contributor); fightIds.add(fid); G.fights.add(fid); G.contributors.add(l.contributor);
        const outcome = l.encounter && l.encounter.outcome || '?';
        for (const e of l.enemies || []) {
            const c = cls(G, String(e.class || '?'));
            c.fights.add(fid); c.lesson_fights.add(fid); c.contributors.add(l.contributor);
            c.outcomes[outcome] = (c.outcomes[outcome] || 0) + 1;
            for (const code of l.lessons || []) {
                const x = c.lessons[code] || (c.lessons[code] = { won: 0, lost: 0 });
                if (outcome === 'won') x.won += 1;
                if (outcome === 'lost') x.lost += 1;
            }
            for (const [name, n] of Object.entries(e.used || {})) {
                const a = c.abilities[name] || (c.abilities[name] = { uses: 0, fights: 0, contributors: new Set() });
                a.uses += n; a.fights += 1; a.contributors.add(l.contributor);
            }
        }
    }

    // --- the output per game ---
    const out_games = {};
    const evaluation = {};
    for (const [gname, G] of Object.entries(games)) {
        const out_groups = {};
        // Parents first (general, then class, matchup, exact) so a level can be compared with its parent.
        const keys = Object.keys(G.groups).sort((a, b) => groups.LEVELS.indexOf(G.groups[b].desc.level) - groups.LEVELS.indexOf(G.groups[a].desc.level));
        for (const key of keys) {
            const g = G.groups[key];
            const parentLevel = groups.parentOf(g.desc.level);
            const parentKey = parentLevel ? groups.keyAt({ game: g.desc.game, enemy_class: g.desc.enemy_class, me_class: g.desc.me_class }, parentLevel) : null;
            const patterns = {};
            for (const [pat, rows] of Object.entries(g.rows)) {
                const parent = parentKey && out_groups[parentKey] && out_groups[parentKey].patterns[pat];
                patterns[pat] = patternEntry(rows, g.censored[pat], o, parent);
                const ev = evaluation[pat] || (evaluation[pat] = { chances: 0, brier: 0, bands: { low: [0, 0], mid: [0, 0], high: [0, 0] } });
                if (g.desc.level === 'general') {
                    for (const r of rows) { ev.chances += 1; ev.brier += (r.p - (r.hit ? 1 : 0)) ** 2; ev.bands[bandOf(r.p)][0] += 1; if (r.hit) ev.bands[bandOf(r.p)][1] += 1; }
                }
            }
            out_groups[key] = Object.assign({}, g.desc, { fights: g.fights.size, contributors: g.contributors.size, patterns });
        }
        const tactics = [];
        for (const [k, t] of Object.entries(G.tacticRows)) {
            const strategy = k.slice(k.lastIndexOf('|') + 1);
            tactics.push(tactic(strategy, t.rows, t.desc, o, newestAt || null));
        }
        tactics.sort((a, b) => (b.validated - a.validated) || ((b.arms ? Object.values(b.arms).reduce((n, x) => n + x.n, 0) : 0) - (a.arms ? Object.values(a.arms).reduce((n, x) => n + x.n, 0) : 0)));
        const by_class = {};
        for (const [name, c] of Object.entries(G.classes)) {
            const classKey = groups.keyAt({ game: gname, enemy_class: name }, 'class');
            const patterns = out_groups[classKey] ? out_groups[classKey].patterns : {};
            const won = c.outcomes.won || 0, lost = c.outcomes.lost || 0;
            const advice = [];
            for (const [code, x] of Object.entries(c.lessons)) {
                if (!LESSON_TEXT[code] || won + lost < o.minLessonFights) continue;
                const w = won > 0 ? x.won / won : 0, lo = lost > 0 ? x.lost / lost : 0;
                advice.push({ code, text: LESSON_TEXT[code], won: r2(w), lost: r2(lo), gap: r2(Math.abs(w - lo)) });
            }
            advice.sort((a, b) => b.gap - a.gap);
            const abilities = {};
            const fights = c.lesson_fights.size || 1;
            for (const [ab, a] of Object.entries(c.abilities)) {
                abilities[ab] = { per_fight: r2(a.uses / fights), in_fights: r2(a.fights / fights), contributors: a.contributors.size, verified: a.contributors.size >= o.abilityContributors };
            }
            const { episodes, episode_lessons } = episodeLessons(c, name, o);
            by_class[name] = { fights: c.fights.size, contributors: c.contributors.size, outcomes: c.outcomes, patterns, advice: advice.slice(0, 6), abilities, episodes, episode_lessons };
        }
        const monitoring = {};
        for (const [v, m] of Object.entries(G.monitoring)) monitoring[v] = { n: m.n, brier: r3(m.brier / m.n), hit_rate: r2(m.hits / m.n), fights: m.fights.size, contributors: m.contributors.size };
        out_games[gname] = {
            fights: G.fights.size, contributors: G.contributors.size, plugins: Array.from(G.plugins).sort(),
            builds: Object.fromEntries(Object.entries(G.builds).map(([b, s]) => [b, s.size])),
            by_class, groups: out_groups, tactics, monitoring,
        };
    }
    const evaluationOut = {};
    for (const [key, g] of Object.entries(evaluation)) {
        evaluationOut[key] = { chances: g.chances, brier: g.chances ? r3(g.brier / g.chances) : null,
            bands: Object.fromEntries(Object.entries(g.bands).map(([b, [n, h]]) => [b, { n, hit_rate: n > 0 ? r2(h / n) : null }])) };
    }
    const limitations = [
        'every tactic is an association within comparable contexts; nothing here was randomised, so no finding says an action caused a result',
        'confounders the records do not carry (gear, skill, teammates, the opponent\'s remaining cooldowns) are not accounted for',
        'observations of one fight are not independent; the effective counts (n_eff) and the intervals treat fights as clusters, approximately',
        'a client\'s version label and signature prove nothing about the gameplay; the trust screen reads the numbers, not the claim',
    ];
    for (const [s, why] of Object.entries(NOT_MEASURED)) limitations.push(`${s.replace(/_/g, ' ')}: not measured (${why})`);
    for (const [gname, g] of Object.entries(out_games)) if (g.contributors < o.minContributors) limitations.push(`${gname}: ${g.contributors} contributor(s); nothing on it is offered`);
    const reasons = {};
    for (const q of screened.quarantined) for (const r of q.reasons) reasons[r.replace(/\d+/g, 'N')] = (reasons[r.replace(/\d+/g, 'N')] || 0) + 1;
    return {
        schema: 1, built_at: new Date().toISOString(), fights: fightIds.size, contributors: contributors.size, observations,
        episodes: episodesSeen, lessons: lessons.length, games: out_games, evaluation: evaluationOut, limitations,
        screen: { quarantined: screened.quarantined.length, reasons, contributors: Object.keys(screened.contributors).length },
        thresholds: o,
    };
}

// --- the episodes' histograms and validated lessons per class (unchanged in substance) -------------
function episodeInto(c, e, contributor) {
    const x = c.episodes[e.type] || (c.episodes[e.type] = { n: 0, contributors: new Set(), prediction: {}, recommendation: {}, results: {}, when_followed: {}, when_not: {}, actions: {}, censored: 0, invalid: 0 });
    x.n += 1;
    x.contributors.add(contributor);
    const po = e.prediction && e.prediction.outcome || 'NONE';
    x.prediction[po] = (x.prediction[po] || 0) + 1;
    const ro = e.recommendation && e.recommendation.outcome || 'UNKNOWN';
    x.recommendation[ro] = (x.recommendation[ro] || 0) + 1;
    const res = e.result && e.result.primary || 'UNKNOWN';
    x.results[res] = (x.results[res] || 0) + 1;
    if (res !== 'UNKNOWN') {
        const bucket = ro === 'FOLLOWED' ? x.when_followed : ro === 'NOT_FOLLOWED' ? x.when_not : null;
        if (bucket) bucket[res] = (bucket[res] || 0) + 1;
    }
    const action = e.recommendation && e.recommendation.action;
    if (action) x.actions[action] = (x.actions[action] || 0) + 1;
    if (e.quality && e.quality.incomplete) x.censored += 1;
    if (po === 'INVALID') x.invalid += 1;
}

function episodeLessons(c, name, o) {
    const episodes = {}, episode_lessons = [];
    for (const [type, x] of Object.entries(c.episodes)) {
        const measured = Object.entries(x.results).filter(([r]) => r !== 'UNKNOWN');
        const total = measured.reduce((n, [, v]) => n + v, 0);
        let top = null, topN = 0;
        for (const [r, v] of measured) if (v > topN) { top = r; topN = v; }
        const action = Object.entries(x.actions).sort((a, b2) => b2[1] - a[1])[0];
        episodes[type] = { n: x.n, contributors: x.contributors.size, prediction: x.prediction, recommendation: x.recommendation, results: x.results,
            when_followed: x.when_followed, when_not_followed: x.when_not, censored: x.censored, invalid: x.invalid, usual_recommendation: action ? action[0] : null };
        const why = [];
        if (total < o.minEpisodes) why.push(`${total} measured episode(s), needs ${o.minEpisodes}`);
        if (x.contributors.size < o.minContributors) why.push(`${x.contributors.size} contributor(s), needs ${o.minContributors}`);
        if (top && total > 0 && topN / total < o.agree) why.push(`the results disagree (${top} in ${(topN / total * 100).toFixed(0)}%)`);
        if (!top) why.push('nothing measured');
        const followed = (x.recommendation.FOLLOWED || 0), notFollowed = (x.recommendation.NOT_FOLLOWED || 0);
        const wf = x.when_followed[top] || 0, wn = x.when_not[top] || 0;
        episode_lessons.push({
            type, result: top, share: total > 0 ? r2(topN / total) : 0, n: total, contributors: x.contributors.size, recommendation: action ? action[0] : null,
            when_followed: followed > 0 ? r2(wf / followed) : null, when_not_followed: notFollowed > 0 ? r2(wn / notFollowed) : null,
            validated: why.length === 0, why: why.length ? why.join('; ') : undefined,
            text: top ? `when ${type.replace(/_/g, ' ')} against a ${name.toLowerCase()}, the result was ${top.replace(/_/g, ' ').toLowerCase()} in ${(topN / Math.max(total, 1) * 100).toFixed(0)}% of ${total} episode(s)` : null,
        });
    }
    episode_lessons.sort((a, b2) => (b2.validated - a.validated) || (b2.n - a.n));
    return { episodes, episode_lessons };
}

module.exports = { build, LESSON_TEXT, DEFAULTS, ROLES, STRATEGY_TEXT, NOT_MEASURED, strategyOf, tacticRows, patternEntry, neff };

'use strict';
// Jambix central service -- the learning log: one entry per learning cycle,
// in words, for the people who run the network and the players who wonder
// what their fights turned into. It says what arrived since the last cycle,
// what the network knows now and how far each thing is from being used, what
// changed since the last cycle, and what players get from it. The entries
// go, newest first, into data/LEARNING_LOG.md (on the data branch, beside the
// records); a compact snapshot (data/models/last_cycle.json) is what the next
// entry is compared with. A cycle with nothing new writes nothing.

const groups = require('./groups');
const trust = require('./trust');

const PATTERN_TEXT = {
    mobility_when_slowed: 'closes the gap when slowed',
    defensive_threshold: 'uses a defensive at a health line',
    interrupts_casts: 'interrupts your casts',
    escape_after_control: 'breaks your control at once',
    over_committing: 'stacks its bursts',
    targeting_pet: 'goes for your pet',
    same_opener: 'repeats its opener',
    retreating_when_pressured: 'backs off under pressure',
    saving_cooldowns_until_low: 'saves its cooldowns until low',
};
const STRATEGY_TEXT = {
    controlling_distance: 'controlling the distance', interrupting_casts: 'interrupting the cast', waiting_out_defensive: 'waiting out the defensive',
    managing_pet_in_cc: 'managing the pet during control', creating_kill_opportunity: 'pressing the kill opportunity',
    disengaging_under_pressure: 'disengaging under pressure', preserve_escape: 'preserving the escape', trading_cooldowns: 'trading a minor cooldown, not a major one',
};

const pct = x => `${Math.round(x * 100)}%`;
const n2 = x => (Number.isInteger(x) ? String(x) : x.toFixed(1));
const cap = s => (s ? s[0].toUpperCase() + s.slice(1) : s);
const cls = c => String(c || '?').toLowerCase();

/** What a record set says about the fights in it (games, classes, outcomes). */
function fightsOf(batches, lessons) {
    const fights = new Map();
    const fid = r => String(r.fight || r.id);
    for (const b of batches) {
        const f = fights.get(fid(b)) || { game: b.client && b.client.game, me: b.me && b.me.class, outcome: b.encounter && b.encounter.outcome, foes: new Set(), contributor: b.contributor, obs: 0, eps: 0 };
        f.obs += (b.observations || []).length;
        f.eps += (b.episodes || []).length;
        for (const o of b.observations || []) f.foes.add(o.enemy_class);
        for (const e of b.episodes || []) f.foes.add(e.enemy_class);
        fights.set(fid(b), f);
    }
    for (const l of lessons) {
        const f = fights.get(fid(l)) || { game: l.client && l.client.game, me: l.me && l.me.class, outcome: l.encounter && l.encounter.outcome, foes: new Set(), contributor: l.contributor, obs: 0, eps: 0 };
        for (const e of l.enemies || []) f.foes.add(e.class);
        f.outcome = f.outcome || (l.encounter && l.encounter.outcome);
        fights.set(fid(l), f);
    }
    return Array.from(fights.values());
}

/** One row per fight in the records the filter lets through, oldest first,
 *  with what the trust screen did with its batch and its lesson. */
const FIGHT_ROWS = 60;
function fightRows(records, keep, th) {
    const screened = trust.screen(records.batches || [], records.lessons || [], th || {});
    const fate = {};                        // record id -> { kind: 'repaired' | 'set aside', reasons }
    for (const r of screened.repaired || []) fate[r.id] = { kind: 'repaired', reasons: r.reasons };
    for (const q of screened.quarantined) fate[q.id] = { kind: 'set aside', reasons: q.reasons };
    const fights = new Map();
    const fid = r => String(r.fight || r.id);
    const row = r => fights.get(fid(r)) || { received: r.received_at || '', game: r.client && r.client.game, me: r.me, encounter: r.encounter || {},
        foes: [], obs: 0, eps: 0, fates: [] };
    for (const b of (records.batches || []).filter(keep)) {
        const f = row(b);
        f.obs += (b.observations || []).length; f.eps += (b.episodes || []).length;
        if (fate[b.id]) f.fates.push(fate[b.id]);
        if (!f.foes.length) for (const x of b.observations || []) if (!f.foes.includes(x.enemy_class)) f.foes.push(x.enemy_class);
        fights.set(fid(b), f);
    }
    for (const l of (records.lessons || []).filter(keep)) {
        const f = row(l);
        f.foes = (l.enemies || []).map(e => e.class);       // the lesson names every one
        f.encounter = l.encounter || f.encounter;
        if (fate[l.id]) f.fates.push(fate[l.id]);
        if (!f.received || (l.received_at && l.received_at < f.received)) f.received = l.received_at || f.received;
        fights.set(fid(l), f);
    }
    return Array.from(fights.values()).sort((a, b) => String(a.received).localeCompare(String(b.received))).map(f => {
        const counted = {};
        for (const c of f.foes.filter(Boolean).map(cls)) counted[c] = (counted[c] || 0) + 1;
        const vs = Object.entries(counted).map(([c, n]) => (n > 1 ? `${c} x${n}` : c)).join(' + ') || 'unknown';
        const setAside = f.fates.filter(x => x.kind === 'set aside');
        const repaired = f.fates.filter(x => x.kind === 'repaired');
        const status = setAside.length ? `set aside: ${setAside[0].reasons.join('; ')}`
            : repaired.length ? `used, repaired: ${repaired.map(x => x.reasons.join('; ')).join('; ')}` : 'used';
        return { when: String(f.received).replace('T', ' ').slice(0, 16),
            what: `${f.game || '?'}: ${cls(f.me && f.me.class)}${f.me && f.me.level ? ' ' + f.me.level : ''} vs ${vs}`,
            outcome: f.encounter.outcome || '?', length: f.encounter.duration !== undefined ? `${f.encounter.duration} s` : '?',
            obs: f.obs, eps: f.eps, status };
    });
}

function describeFights(list) {
    if (!list.length) return 'no fight';
    const contributors = new Set(list.map(f => f.contributor)).size;
    const byMatch = {};
    const outcomes = {};
    for (const f of list) {
        const foes = Array.from(f.foes).filter(Boolean).map(cls).sort().join(' + ') || 'unknown';
        const k = `${f.game || '?'}: ${cls(f.me)} vs ${foes}`;
        byMatch[k] = (byMatch[k] || 0) + 1;
        outcomes[f.outcome || '?'] = (outcomes[f.outcome || '?'] || 0) + 1;
    }
    const matches = Object.entries(byMatch).map(([k, n]) => (n > 1 ? `${k} x${n}` : k)).join('; ');
    const outs = Object.entries(outcomes).map(([k, n]) => `${k} ${n}`).join(', ');
    return `${list.length} fight(s) from ${contributors} contributor(s) -- ${matches} (${outs})`;
}

/** The compact state a later entry is compared with. */
function snapshotOf(model, decision, version) {
    const snap = { at: model.built_at, decision, version: version || null, fights: model.fights, contributors: model.contributors,
        observations: model.observations, episodes: model.episodes, quarantined: model.screen ? model.screen.quarantined : 0,
        repaired: model.screen ? model.screen.repaired || 0 : 0, fights_listed: true, engine: null,
        patterns: {}, tactics: {}, lessons: {} };
    for (const [game, G] of Object.entries(model.games || {})) {
        for (const [klass, c] of Object.entries(G.by_class || {})) {
            for (const [pat, e] of Object.entries(c.patterns || {})) {
                snap.patterns[`${game}|${klass}|${pat}`] = { p: e.p, chances: e.chances, usable: !e.unreliable };
            }
            for (const l of c.episode_lessons || []) {
                snap.lessons[`${game}|${klass}|${l.type}`] = { validated: l.validated, result: l.result, n: l.n };
            }
        }
        for (const t of G.tactics || []) {
            snap.tactics[`${game}|${t.level}|${t.me_class || '-'}|${t.enemy_class}|${t.strategy}`] = { validated: !!t.validated, better: t.better || null, strength: t.strength, stale: !!t.stale };
        }
    }
    return snap;
}

/** How far a pattern entry is from being offered, in words; '' when it is usable. */
function shortfall(e, th) {
    if (!e.unreliable) return '';
    const parts = [];
    if (e.weighted.chances < th.minChances) parts.push(`${n2(e.weighted.chances)} of ${th.minChances} checks`);
    if (e.contributors < th.minContributors) parts.push(`${e.contributors} of ${th.minContributors} players`);
    if (e.n_eff < th.minEff) parts.push(`${n2(e.n_eff)} of ${th.minEff} independent fights' worth`);
    if (e.brier > th.maxBrier) parts.push(`forecast error ${e.brier.toFixed(2)} (needs ${th.maxBrier} or less)`);
    if (e.inputs_ok < th.minInputsOk) parts.push(`${pct(e.inputs_ok)} of checks with verified inputs (needs ${pct(th.minInputsOk)})`);
    if (e.dominated && e.contributors >= th.minContributors) parts.push('one player holds most of it');
    return parts.join(', ');
}

/** Progress toward being offered, 0..1: the worst of the count bars. */
function progress(e, th) {
    if (!e.unreliable) return 1;
    return Math.min(1, e.weighted.chances / th.minChances, e.contributors / th.minContributors, e.n_eff / th.minEff);
}

/**
 * One entry of the learning log, as markdown. `cycle` is release.cycle's
 * result (decision, version, stage, verdict, candidate); `prev` the last
 * snapshot (or null); `records` { batches, lessons } every accepted record,
 * from which the ones since `prev.at` are the new ones.
 */
function entry(cycle, prev, records, opts) {
    const o = opts || {};
    const model = cycle.candidate;
    const th = model.thresholds || {};
    // New: received after the newest record the last cycle saw (its watermark).
    const since = prev ? (prev.newest || prev.at || null) : null;
    const fresh = r => !since || (r.received_at && r.received_at > since);
    const newFights = fightsOf(records.batches.filter(fresh), records.lessons.filter(fresh));
    const when = (model.built_at || new Date().toISOString()).replace('T', ' ').slice(0, 16) + ' UTC';
    const head = cycle.decision === 'publish' || cycle.decision === 'forced'
        ? `model v${cycle.version} published (${cycle.stage === 'canary' ? 'canary: 25% of players first' : 'to every player'})`
        : cycle.decision === 'hold' ? 'held: nothing material changed, no new version'
        : 'no new version: not enough to go on yet';
    const L = [];
    L.push(`## ${when} -- ${head}`);
    L.push('');
    L.push(`**New since the last cycle:** ${describeFights(newFights)}.`);
    if (prev && o.engine && prev.engine !== o.engine) L.push('**The learning engine changed since the last cycle:** every record is judged again by the new code.');
    const q = model.screen ? model.screen.quarantined : 0;
    const qNew = q - (prev ? prev.quarantined || 0 : 0);
    if (qNew > 0) L.push(`**Set aside (quarantined):** ${qNew} record(s): ${Object.entries(model.screen.reasons || {}).map(([r, n]) => `${r} (${n})`).join('; ')}.`);
    const rp = model.screen ? model.screen.repaired || 0 : 0;
    const rpNew = rp - (prev ? prev.repaired || 0 : 0);
    if (rpNew > 0) L.push(`**Repaired (an older client's known faults taken out, the rest kept):** ${rpNew} record(s): ${Object.entries(model.screen.repairs || {}).map(([r, n]) => `${r} (${n})`).join('; ')}.`);
    L.push(`**In all:** ${model.fights} fight(s) from ${model.contributors} player(s), ${model.observations} prediction check(s), ${model.episodes} decision episode(s).`);
    L.push('');

    // The fights themselves, one row each: the new ones (every one, the first
    // time this table is written), what each brought and what the screen did with it.
    const listed = fightRows(records, prev && prev.fights_listed ? fresh : () => true, th);
    if (listed.length) {
        L.push(`### The fights (${prev && prev.fights_listed ? 'new since the last cycle' : 'every fight so far'})`);
        L.push('| Received (UTC) | Fight | Result | Length | Checks | Episodes | What became of it |');
        L.push('|---|---|---|---|---|---|---|');
        for (const f of listed.slice(0, FIGHT_ROWS)) L.push(`| ${f.when} | ${f.what} | ${f.outcome} | ${f.length} | ${f.obs} | ${f.eps} | ${f.status} |`);
        if (listed.length > FIGHT_ROWS) L.push(`| ... | and ${listed.length - FIGHT_ROWS} more | | | | | |`);
        L.push('');
    }

    // What players get.
    L.push('### What players get');
    if (cycle.decision === 'publish' || cycle.decision === 'forced') {
        let usable = 0, tactics = 0;
        for (const G of Object.values(model.games || {})) {
            for (const g of Object.values(G.groups || {})) for (const e of Object.values(g.patterns || {})) if (!e.unreliable) usable += 1;
            for (const t of G.tactics || []) if (t.validated) tactics += 1;
        }
        L.push(`- Version ${cycle.version}: ${usable} opponent rate(s) a player's predictor may start from, ${tactics} tactic(s) shown as associations. Players with *Download the network's learning* on pick it up within 30 minutes${cycle.stage === 'canary' ? ' (a quarter of them first; the rest once it is promoted)' : ''}.`);
        if (cycle.decision === 'forced') L.push(`- Published by hand past failed gates: ${cycle.verdict.failed.join(', ')}.`);
    } else {
        L.push(`- Nothing changes for players${o.current ? ` (they keep v${o.current})` : ''}. ${cycle.verdict.failed.length ? 'Gates not passed: ' + cycle.verdict.checks.filter(c => c.pass === false).map(c => `${c.name} (${c.detail})`).join('; ') + '.' : cycle.verdict.material.why + '.'}`);
    }
    L.push('');

    // What the network knows, per game: the class-level rates, nearest to usable first.
    for (const [game, G] of Object.entries(model.games || {})) {
        const rows = [];
        for (const [klass, c] of Object.entries(G.by_class || {})) {
            for (const [pat, e] of Object.entries(c.patterns || {})) rows.push({ klass, pat, e });
        }
        if (!rows.length && !(G.tactics || []).length) continue;
        L.push(`### What the network knows on ${game}`);
        if (rows.length) {
            rows.sort((a, b) => progress(b.e, th) - progress(a.e, th) || b.e.chances - a.e.chances);
            L.push('');
            L.push('| Opponent | Habit | Rate | Checks | Fights | Status |');
            L.push('|---|---|---|---|---|---|');
            for (const { klass, pat, e } of rows.slice(0, 20)) {
                const status = e.unreliable ? `not used yet: ${shortfall(e, th)}` : `**used** (${pct(e.interval[0])}-${pct(e.interval[1])})`;
                L.push(`| ${cap(cls(klass))} | ${PATTERN_TEXT[pat] || pat} | ${pct(e.p)} | ${e.chances} | ${e.n} | ${status} |`);
            }
            if (rows.length > 20) L.push(`| ... | ${rows.length - 20} more | | | | |`);
        }
        const validated = (G.tactics || []).filter(t => t.validated);
        // One line per strategy and opponent (the levels repeat the same episodes): the matchup's, else the first.
        const seen = new Set();
        const nearest = (G.tactics || []).filter(t => !t.validated && t.arms)
            .sort((a, b) => (b.level === 'matchup') - (a.level === 'matchup') ||
                Object.values(b.arms).reduce((n, x) => n + x.n, 0) - Object.values(a.arms).reduce((n, x) => n + x.n, 0))
            .filter(t => { const k = t.strategy + '|' + t.enemy_class; if (seen.has(k)) return false; seen.add(k); return true; })
            .slice(0, 3);
        if (validated.length || nearest.length) {
            L.push('');
            L.push('Tactics (associations, never causes):');
            for (const t of validated) L.push(`- ${t.text}`);
            for (const t of nearest) {
                const arms = Object.entries(t.arms).map(([k, a]) => `${k.replace(/_/g, ' ')} ${a.n}`).join(' / ');
                L.push(`- not yet: ${STRATEGY_TEXT[t.strategy] || t.strategy} against a ${cls(t.enemy_class)} (${t.level}): ${arms} episode(s); ${t.why || t.strength}`);
            }
        }
        L.push('');
    }

    // The weights check (learn.js threatCheck), per game.
    const checks = Object.entries(model.games || {}).filter(([, G]) => G.threat_check);
    if (checks.length) {
        L.push('### Weights check');
        for (const [game, G] of checks) L.push(`- ${game}: does the threat level tell the dangerous moments? **${G.threat_check.verdict}** -- ${G.threat_check.why}.`);
        L.push('');
    }

    // Changes since the last cycle.
    const now = snapshotOf(model, cycle.decision, cycle.version);
    now.engine = o.engine || null;
    now.newest = [...records.batches, ...records.lessons].reduce((a, r) => (r.received_at && r.received_at > a ? r.received_at : a), '') || null;
    const changes = [];
    const before = prev ? prev.patterns || {} : {};
    for (const [k, e] of Object.entries(now.patterns)) {
        const [game, klass, pat] = k.split('|');
        const name = `${game} ${cls(klass)}: ${PATTERN_TEXT[pat] || pat}`;
        const b = before[k];
        if (!b) changes.push(`new: ${name} -- ${pct(e.p)} over ${e.chances} check(s)${e.usable ? ', used' : ''}`);
        else {
            if (e.usable && !b.usable) changes.push(`now used: ${name} at ${pct(e.p)}`);
            if (!e.usable && b.usable) changes.push(`no longer used: ${name}`);
            if (Math.abs(e.p - b.p) >= 0.05) changes.push(`moved: ${name} ${pct(b.p)} -> ${pct(e.p)} (${b.chances} -> ${e.chances} checks)`);
        }
    }
    const tBefore = prev ? prev.tactics || {} : {};
    for (const [k, t] of Object.entries(now.tactics)) {
        const b = tBefore[k];
        const [game, level, me, enemy, strategy] = k.split('|');
        const name = `${game} ${me !== '-' ? cls(me) + ' ' : ''}vs ${cls(enemy)} (${level}): ${STRATEGY_TEXT[strategy] || strategy}`;
        if (t.validated && !(b && b.validated)) changes.push(`tactic found: ${name} -- ${t.better ? t.better.replace(/_/g, ' ') : '?'} did better (${t.strength})`);
        if (!t.validated && b && b.validated) changes.push(`tactic no longer holds: ${name}${t.stale ? ' (it stopped working lately)' : ''}`);
    }
    const lBefore = prev ? prev.lessons || {} : {};
    for (const [k, l] of Object.entries(now.lessons)) {
        const b = lBefore[k];
        const [game, klass, type] = k.split('|');
        if (l.validated && !(b && b.validated)) changes.push(`lesson confirmed: ${game} vs ${cls(klass)}, ${type.replace(/_/g, ' ')}: ${String(l.result).replace(/_/g, ' ').toLowerCase()} over ${l.n} episode(s)`);
    }
    L.push('### Changes since the last cycle');
    if (!prev) L.push('- The first entry: everything above is new.');
    else if (!changes.length) L.push('- Nothing the network knows moved enough to report.');
    for (const c of changes.slice(0, 25)) L.push(`- ${c}`);
    if (changes.length > 25) L.push(`- ... and ${changes.length - 25} more`);
    L.push('');

    // The bars, said once.
    L.push(`<sub>A habit is used once it has ${th.minChances} checks from ${th.minContributors}+ players over ${th.minEff}+ independent fights' worth, forecasts within an error of ${th.maxBrier}, and half its inputs verified; a client starts from it only with ${o.minFights || 10}+ fights behind it. A tactic needs ${th.minArm}+ measured episodes on each side over ${th.minArmFights}+ fights from ${th.minContributors}+ players.</sub>`);
    L.push('');
    return { markdown: L.join('\n'), snapshot: now, changes };
}

/** Prepends an entry to the log file's body, under its title. */
function prepend(existing, md) {
    const title = '# Jambix central -- learning log\n\nWhat each learning cycle took in, what the network knows, what changed and what players get. Newest first.\n\n';
    let body = existing || '';
    if (body.startsWith('# Jambix central')) {
        const i = body.indexOf('\n## ');
        body = i >= 0 ? body.slice(i + 1) : '';
    }
    return title + md + '\n' + body;
}

module.exports = { entry, snapshotOf, prepend, fightsOf, fightRows, describeFights, shortfall, PATTERN_TEXT };

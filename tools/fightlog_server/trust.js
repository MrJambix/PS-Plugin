'use strict';
// Jambix central service -- the trust screen (the brief's §5). Every upload
// is a claim a client makes; nothing in it proves the gameplay happened.
// Before a record reaches the learner it goes through this screen, and
// what fails it is quarantined with the reasons, never silently dropped
// and never silently kept: the audit log holds each decision.
//
//   duplicate content   the same fight again under a new id (its fingerprint)
//   replayed episodes   a contributor's episodes seen already in another batch
//   suspicious          numbers no fight produces (forecasts past the duration,
//                       more than three a second, perfect foresight over many,
//                       a fight id two contributors share, one fight with two
//                       levels or two games)
//   volume              more than maxPerDay fights from one contributor on a day
//
// Weights (the learner's): a forecast with its inputs verified live weighs
// 1, one without 0.5 (source quality); an episode with a quality flag
// weighs nothing in a result; a contributor's share of a group is capped
// (learn.js capShares); a contributor whose own rate stands far from the
// others' is an outlier and weighs half (learn.js outliers).

const crypto = require('crypto');
const { normalize } = require('./validate');

const DEFAULTS = {
    maxPerDay: 40,              // fights one contributor may file on one day; the rest quarantined
    maxObsPerSecond: 3,         // forecasts per second of fight past which the batch is suspect
    perfectMin: 15,             // this many forecasts all sure and all right is foresight, not play
    tPastDuration: 5,           // a forecast's t this far past the duration is impossible
    replayShare: 0.5,           // this share of a batch's episodes seen before = a replay
    inputsWeight: 0.5,          // a forecast without verified inputs weighs this
};

const hash = v => crypto.createHash('sha256').update(JSON.stringify(v)).digest('hex').slice(0, 24);

/** What a batch is, with its ids and its clock taken off. */
function batchFingerprint(b) {
    return hash({
        contributor: b.contributor, me: b.me, enc: b.encounter, client: b.client,
        obs: (b.observations || []).map(o => [o.pattern, o.enemy_class, o.p, o.hit, o.t]),
        eps: (b.episodes || []).map(episodeFingerprint),
    });
}

function episodeFingerprint(e) {
    const b = e.before || {}, a = e.after || {};
    return hash([e.type, e.enemy_class, e.t, e.horizon, b.hp, b.gap, b.attackers, a.hp, a.gap, e.result && e.result.primary,
        e.prediction && e.prediction.p, (e.actions || []).join(',')]);
}

function lessonFingerprint(l) {
    return hash({ contributor: l.contributor, me: l.me, enc: l.encounter, client: l.client, enemies: l.enemies, lessons: l.lessons });
}

function dayOf(r) {
    const t = r.received_at ? Date.parse(r.received_at) : NaN;
    return Number.isFinite(t) ? new Date(t).toISOString().slice(0, 10) : '?';
}

/** The reasons a batch's own numbers make it suspect; empty when none. */
function suspicious(b, o) {
    const why = [];
    const d = Number(b.encounter && b.encounter.duration) || 0;
    const obs = b.observations || [];
    if (obs.some(x => typeof x.t === 'number' && x.t > d + o.tPastDuration)) why.push('a forecast past the fight\'s end');
    if (obs.length > 0 && obs.length > Math.max(1, d) * o.maxObsPerSecond) why.push(`${obs.length} forecasts in ${d} s`);
    if (obs.length >= o.perfectMin && obs.every(x => x.sure && x.correct)) why.push(`${obs.length} forecasts, every one sure and right`);
    const eps = b.episodes || [];
    if (eps.some(e => typeof e.t === 'number' && e.t > d + o.tPastDuration)) why.push('an episode past the fight\'s end');
    if (d === 0 && (obs.length > 0 || eps.length > 0)) why.push('a fight of 0 s with records in it');
    return why;
}

/**
 * The screen. Returns the accepted batches and lessons, what was
 * quarantined (each with its reasons), the audit rows, and per-contributor
 * counts. Records are taken in the order received.
 */
function screen(batchesIn, lessonsIn, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    // Every record in the shapes the learner reads (an empty {} list or [] map
    // from an older ingest), and nothing that is not a record at all.
    const batches = (batchesIn || []).filter(r => r && typeof r === 'object').map(normalize);
    const lessons = (lessonsIn || []).filter(r => r && typeof r === 'object').map(normalize);
    const quarantined = [];
    const audit = [];
    const perDay = {};                  // contributor|day -> fights filed
    const fightsSeen = {};              // fight id -> { contributor, level, game }
    const batchPrints = new Set();
    const lessonPrints = new Set();
    const episodePrints = {};           // contributor -> Set of episode fingerprints
    const contributors = {};            // contributor -> { batches, lessons, quarantined }

    const stat = c => (contributors[c] || (contributors[c] = { batches: 0, lessons: 0, quarantined: 0 }));
    const quarantine = (kind, r, reasons) => {
        quarantined.push({ kind, id: r.id, contributor: r.contributor, fight: r.fight || null, received_at: r.received_at || null, reasons });
        stat(r.contributor).quarantined += 1;
        audit.push({ at: r.received_at || null, kind, id: r.id, contributor: r.contributor, action: 'quarantined', reasons });
    };
    // A fight two records claim with a different contributor, level or game.
    const fightConflict = r => {
        if (!r.fight) return null;
        const seen = fightsSeen[r.fight];
        const mine = { contributor: r.contributor, level: r.me && r.me.level, game: r.client && r.client.game };
        if (!seen) { fightsSeen[r.fight] = mine; return null; }
        if (seen.contributor !== mine.contributor) return 'a fight id another contributor filed';
        if (seen.level !== mine.level) return 'one fight at two levels';
        if (seen.game !== mine.game) return 'one fight on two games';
        return null;
    };
    const overVolume = r => {
        const k = `${r.contributor}|${dayOf(r)}`;
        perDay[k] = (perDay[k] || 0) + 1;
        return perDay[k] > o.maxPerDay ? `more than ${o.maxPerDay} fights on ${dayOf(r)}` : null;
    };

    const batchesOut = [];
    const sorted = rows => rows.slice().sort((a, b) => String(a.received_at || '').localeCompare(String(b.received_at || '')) || String(a.id).localeCompare(String(b.id)));
    for (const b of sorted(batches)) {
        const why = [];
        const fp = batchFingerprint(b);
        if (batchPrints.has(fp)) why.push('duplicate content: the same fight under a new id');
        batchPrints.add(fp);
        const prints = episodePrints[b.contributor] || (episodePrints[b.contributor] = new Set());
        const eps = b.episodes || [];
        if (eps.length > 0) {
            const seen = eps.filter(e => prints.has(episodeFingerprint(e))).length;
            if (seen / eps.length >= o.replayShare) why.push(`${seen} of ${eps.length} episodes seen before from this contributor`);
            for (const e of eps) prints.add(episodeFingerprint(e));
        }
        why.push(...suspicious(b, o));
        const conflict = fightConflict(b);
        if (conflict) why.push(conflict);
        const vol = overVolume(b);
        if (vol) why.push(vol);
        if (why.length) { quarantine('batch', b, why); continue; }
        stat(b.contributor).batches += 1;
        batchesOut.push(b);
    }
    const lessonsOut = [];
    for (const l of sorted(lessons)) {
        const why = [];
        const fp = lessonFingerprint(l);
        if (lessonPrints.has(fp)) why.push('duplicate content: the same lesson under a new id');
        lessonPrints.add(fp);
        const conflict = fightConflict(l);
        if (conflict) why.push(conflict);
        // A lesson counts toward the day's fights only when its fight has no batch (else the batch counted it).
        if (!(l.fight && fightsSeen[l.fight] && fightsSeen[l.fight].contributor === l.contributor && batchesOut.some(b => b.fight === l.fight))) {
            const vol = overVolume(l);
            if (vol) why.push(vol);
        }
        if (why.length) { quarantine('lesson', l, why); continue; }
        stat(l.contributor).lessons += 1;
        lessonsOut.push(l);
    }
    return { batches: batchesOut, lessons: lessonsOut, quarantined, audit, contributors, options: o };
}

/** The weight of one forecast observation (source quality). */
function observationWeight(ob, o) {
    const opts = Object.assign({}, DEFAULTS, o || {});
    return ob.inputs_ok ? 1 : opts.inputsWeight;
}

/** Whether an episode's result may count: measured, and no quality flag on it. */
function episodeCounts(e) {
    const q = e.quality || {};
    if (q.test_data || q.incomplete || q.guess_only || q.unsupported) return false;
    const r = e.result && e.result.primary;
    return !!r && r !== 'UNKNOWN';
}

module.exports = { DEFAULTS, screen, batchFingerprint, episodeFingerprint, lessonFingerprint, suspicious, observationWeight, episodeCounts };

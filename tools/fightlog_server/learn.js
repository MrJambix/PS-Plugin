'use strict';
// Jambix central service -- the global learning engine: the observations
// everyone contributed, aggregated per opponent class and pattern, each
// pattern's forecast quality measured (a Brier score against the forecasts
// as they stood), the unreliable ones marked and said why, the matchup
// lessons that told won fights from lost ones, the abilities seen. The
// result is a model version the clients download (knowledge distribution);
// nothing in it is a fact, every number carries its count.

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
    minChances: 20,          // forecast chances a pattern needs before its rate is offered
    minContributors: 2,      // one person's fights are not a network
    maxBrier: 0.30,          // a forecast quality worse than this is not offered as a prior
    minInputsOk: 0.5,        // fewer verified inputs than this and the misses are suspect
    minLessonFights: 5,      // fights an advice line needs
    minEpisodes: 6,          // measured episodes a validated episode lesson needs
    agree: 0.6,              // the share of them with the same result
};

function build(batches, lessons, opts) {
    const o = Object.assign({}, DEFAULTS, opts || {});
    const by = {};
    const contributors = new Set();
    const fightIds = new Set();
    let observations = 0, episodesSeen = 0;
    const perPattern = {};

    const cls = c => (by[c] || (by[c] = {
        patterns: {}, outcomes: {}, lessons: {}, abilities: {}, fights: new Set(), contributors: new Set(), episodes: {},
    }));
    // The decision episodes: per opponent class and type, what was predicted
    // and advised, whether it was followed, and the measured result -- and,
    // with enough comparable episodes from enough contributors agreeing, a
    // validated lesson.
    const episodeOf = (c, e, contributor) => {
        const x = c.episodes[e.type] || (c.episodes[e.type] = {
            n: 0, contributors: new Set(), prediction: {}, recommendation: {}, results: {}, when_followed: {}, when_not: {},
            actions: {}, censored: 0, invalid: 0,
        });
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
    };

    // A batch and a lesson of the same fight share its `fight` id (older
    // records carry none: their own id stands in).
    const fightOf = r => String(r.fight || r.id);
    for (const b of batches) {
        contributors.add(b.contributor);
        fightIds.add(fightOf(b));
        for (const e of b.episodes || []) {
            if (e.quality && e.quality.test_data) continue;
            episodesSeen += 1;
            const c = cls(String(e.enemy_class || '?'));
            c.fights.add(fightOf(b));
            c.contributors.add(b.contributor);
            episodeOf(c, e, b.contributor);
        }
        for (const ob of b.observations || []) {
            observations += 1;
            const c = cls(String(ob.enemy_class || '?'));
            c.fights.add(fightOf(b));
            c.contributors.add(b.contributor);
            const p = c.patterns[ob.pattern] || (c.patterns[ob.pattern] = {
                chances: 0, hits: 0, brier: 0, inputs_ok: 0, sure: 0, sure_right: 0, fights: new Set(), contributors: new Set(),
            });
            p.chances += 1;
            if (ob.hit) p.hits += 1;
            p.brier += (ob.p - (ob.hit ? 1 : 0)) ** 2;
            if (ob.inputs_ok) p.inputs_ok += 1;
            if (ob.sure) { p.sure += 1; if (ob.correct) p.sure_right += 1; }
            p.fights.add(fightOf(b));
            p.contributors.add(b.contributor);
            const g = perPattern[ob.pattern] || (perPattern[ob.pattern] = { chances: 0, brier: 0, bands: { low: [0, 0], mid: [0, 0], high: [0, 0] } });
            g.chances += 1;
            g.brier += (ob.p - (ob.hit ? 1 : 0)) ** 2;
            const band = ob.p < 0.4 ? 'low' : ob.p < 0.6 ? 'mid' : 'high';
            g.bands[band][0] += 1;
            if (ob.hit) g.bands[band][1] += 1;
        }
    }
    for (const l of lessons) {
        contributors.add(l.contributor);
        fightIds.add(fightOf(l));
        const outcome = l.encounter && l.encounter.outcome || '?';
        for (const e of l.enemies || []) {
            const c = cls(String(e.class || '?'));
            c.fights.add(fightOf(l));
            c.lesson_fights = c.lesson_fights || new Set();
            c.lesson_fights.add(fightOf(l));
            c.contributors.add(l.contributor);
            c.outcomes[outcome] = (c.outcomes[outcome] || 0) + 1;
            for (const code of l.lessons || []) {
                const x = c.lessons[code] || (c.lessons[code] = { won: 0, lost: 0 });
                if (outcome === 'won') x.won += 1;
                if (outcome === 'lost') x.lost += 1;
            }
            for (const [name, n] of Object.entries(e.used || {})) {
                const a = c.abilities[name] || (c.abilities[name] = { uses: 0, fights: 0 });
                a.uses += n;
                a.fights += 1;
            }
        }
    }

    const by_class = {};
    for (const [name, c] of Object.entries(by)) {
        const patterns = {};
        for (const [key, p] of Object.entries(c.patterns)) {
            const rate = p.chances > 0 ? p.hits / p.chances : 0;
            const brier = p.chances > 0 ? p.brier / p.chances : 1;
            const inputs = p.chances > 0 ? p.inputs_ok / p.chances : 0;
            const why = [];
            if (p.chances < o.minChances) why.push(`${p.chances} chance(s), needs ${o.minChances}`);
            if (p.contributors.size < o.minContributors) why.push(`${p.contributors.size} contributor(s), needs ${o.minContributors}`);
            if (brier > o.maxBrier) why.push(`forecast quality ${brier.toFixed(2)} worse than ${o.maxBrier}`);
            if (inputs < o.minInputsOk) why.push(`only ${(inputs * 100).toFixed(0)}% of chances with verified inputs`);
            patterns[key] = {
                p: Number(rate.toFixed(3)), chances: p.chances, hits: p.hits, n: p.fights.size, contributors: p.contributors.size,
                brier: Number(brier.toFixed(3)), inputs_ok: Number(inputs.toFixed(2)),
                sure_forecasts: p.sure, sure_right: p.sure_right,
                unreliable: why.length > 0, why: why.length > 0 ? why.join('; ') : undefined,
            };
        }
        const won = c.outcomes.won || 0, lost = c.outcomes.lost || 0;
        const advice = [];
        for (const [code, x] of Object.entries(c.lessons)) {
            if (!LESSON_TEXT[code]) continue;
            if (won + lost < o.minLessonFights) continue;
            const w = won > 0 ? x.won / won : 0, lo = lost > 0 ? x.lost / lost : 0;
            advice.push({ code, text: LESSON_TEXT[code], won: Number(w.toFixed(2)), lost: Number(lo.toFixed(2)), gap: Number(Math.abs(w - lo).toFixed(2)) });
        }
        advice.sort((a, b) => b.gap - a.gap);
        const abilities = {};
        const fights = (c.lesson_fights && c.lesson_fights.size) || 1;      // abilities come with lessons
        for (const [ab, a] of Object.entries(c.abilities)) {
            abilities[ab] = { per_fight: Number((a.uses / fights).toFixed(2)), in_fights: Number((a.fights / fights).toFixed(2)) };
        }
        // The episodes: the histogram per type, and a validated lesson where
        // enough comparable episodes from enough contributors agree on the
        // result (minEpisodes, minContributors, agree).
        const episodes = {};
        const episode_lessons = [];
        for (const [type, x] of Object.entries(c.episodes)) {
            const measured = Object.entries(x.results).filter(([r]) => r !== 'UNKNOWN');
            const total = measured.reduce((n, [, v]) => n + v, 0);
            let top = null, topN = 0;
            for (const [r, v] of measured) if (v > topN) { top = r; topN = v; }
            const action = Object.entries(x.actions).sort((a, b2) => b2[1] - a[1])[0];
            episodes[type] = {
                n: x.n, contributors: x.contributors.size, prediction: x.prediction, recommendation: x.recommendation, results: x.results,
                when_followed: x.when_followed, when_not_followed: x.when_not, censored: x.censored, invalid: x.invalid,
                usual_recommendation: action ? action[0] : null,
            };
            const why = [];
            if (total < o.minEpisodes) why.push(`${total} measured episode(s), needs ${o.minEpisodes}`);
            if (x.contributors.size < o.minContributors) why.push(`${x.contributors.size} contributor(s), needs ${o.minContributors}`);
            if (top && total > 0 && topN / total < o.agree) why.push(`the results disagree (${top} in ${(topN / total * 100).toFixed(0)}%)`);
            if (!top) why.push('nothing measured');
            const followed = (x.recommendation.FOLLOWED || 0), notFollowed = (x.recommendation.NOT_FOLLOWED || 0);
            const wf = x.when_followed[top] || 0, wn = x.when_not[top] || 0;
            episode_lessons.push({
                type, result: top, share: total > 0 ? Number((topN / total).toFixed(2)) : 0, n: total, contributors: x.contributors.size,
                recommendation: action ? action[0] : null,
                when_followed: followed > 0 ? Number((wf / followed).toFixed(2)) : null,
                when_not_followed: notFollowed > 0 ? Number((wn / notFollowed).toFixed(2)) : null,
                validated: why.length === 0, why: why.length ? why.join('; ') : undefined,
                text: top ? `when ${type.replace(/_/g, ' ')} against a ${name.toLowerCase()}, the result was ${top.replace(/_/g, ' ').toLowerCase()} in ${(topN / Math.max(total, 1) * 100).toFixed(0)}% of ${total} episode(s)` : null,
            });
        }
        episode_lessons.sort((a, b2) => (b2.validated - a.validated) || (b2.n - a.n));
        by_class[name] = {
            fights: c.fights.size, contributors: c.contributors.size, outcomes: c.outcomes, patterns, advice: advice.slice(0, 6), abilities,
            episodes, episode_lessons,
        };
    }
    const evaluation = {};
    for (const [key, g] of Object.entries(perPattern)) {
        evaluation[key] = {
            chances: g.chances, brier: Number((g.brier / g.chances).toFixed(3)),
            bands: Object.fromEntries(Object.entries(g.bands).map(([b, [n, h]]) => [b, { n, hit_rate: n > 0 ? Number((h / n).toFixed(2)) : null }])),
        };
    }
    return {
        schema: 1, built_at: new Date().toISOString(), fights: fightIds.size, contributors: contributors.size, observations,
        episodes: episodesSeen, lessons: lessons.length, by_class, evaluation, thresholds: o,
    };
}

module.exports = { build, LESSON_TEXT, DEFAULTS };

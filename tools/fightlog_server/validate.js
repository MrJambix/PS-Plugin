'use strict';
// Jambix central service -- what an incoming record must look like, and what
// it must never contain. Every check here is a bound: a record past it is
// refused with the reason, never trimmed into shape.

const CLASSES = new Set(['WARRIOR', 'PALADIN', 'HUNTER', 'ROGUE', 'PRIEST', 'SHAMAN', 'MAGE', 'WARLOCK', 'DRUID', '?']);
const PATTERNS = new Set(['mobility_when_slowed', 'defensive_threshold', 'interrupts_casts', 'escape_after_control',
    'over_committing', 'targeting_pet', 'same_opener', 'retreating_when_pressured', 'saving_cooldowns_until_low']);
const OUTCOMES = new Set(['won', 'lost', 'fled', 'reset', 'draw', '?']);
const ENCOUNTERS = new Set(['duel', 'world_pvp', 'bg', 'arena', 'world', 'none', '?']);
const LESSON_CODES = new Set(['defensive_unused', 'slow_unused', 'trap_unused', 'kill_missed', 'own_cc_broken',
    'cast_unstopped', 'controlled', 'burst_lost', 'trinket_spent', 'trap_won', 'hold_won', 'forecasts']);
const FORBIDDEN_KEYS = new Set(['name', 'realm', 'account', 'chat', 'ip', 'email', 'guid', 'player_name', 'character']);
const SCHEMA = 1;
const EPISODE_TYPES = new Set(['gap_close_attempt', 'rogue_opener', 'blink', 'enemy_burst', 'rooted_under_pressure', 'dead_zone_entry',
    'pet_breaks_cc', 'kill_opportunity', 'defensive_change', 'outnumbered']);
const PREDICTION_OUTCOMES = new Set(['HIT', 'MISS', 'CENSORED', 'INVALID', 'NONE']);
const RECOMMENDATION_OUTCOMES = new Set(['FOLLOWED', 'NOT_FOLLOWED', 'UNKNOWN']);
const RESULTS = new Set(['SURVIVAL_IMPROVED', 'POSITION_IMPROVED', 'DAMAGE_OPPORTUNITY_CREATED', 'CONTROL_SUCCESSFUL', 'COOLDOWN_SAVED',
    'OBJECTIVE_PROGRESS', 'NO_MEASURABLE_CHANGE', 'SITUATION_WORSENED', 'UNKNOWN']);
const CONFIDENCES = new Set(['none', 'candidate', 'contested', 'low', 'moderate', 'high']);

const isStr = (v, max) => typeof v === 'string' && v.length > 0 && v.length <= (max || 64);
const isNum = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;
const isHex = (v, min, max) => typeof v === 'string' && /^[0-9a-f]+$/.test(v) && v.length >= min && v.length <= max;

// A key that must never travel, anywhere in the record.
function forbiddenKey(v, path) {
    if (Array.isArray(v)) {
        for (let i = 0; i < v.length; i++) { const f = forbiddenKey(v[i], `${path}[${i}]`); if (f) return f; }
        return null;
    }
    if (v && typeof v === 'object') {
        for (const [k, x] of Object.entries(v)) {
            if (FORBIDDEN_KEYS.has(k.toLowerCase())) return `${path}.${k}`;
            const f = forbiddenKey(x, `${path}.${k}`);
            if (f) return f;
        }
    }
    return null;
}

function countsMap(v, maxEntries, label) {
    if (v === undefined || v === null) return null;
    if (!v || typeof v !== 'object' || Array.isArray(v)) return `${label} must be a map`;
    const entries = Object.entries(v);
    if (entries.length > maxEntries) return `${label} has more than ${maxEntries} entries`;
    for (const [k, n] of entries) {
        if (!isStr(k, 48)) return `${label} has a bad key`;
        if (!isInt(n, 0, 10000)) return `${label}.${k} must be a count`;
    }
    return null;
}

function head(r, what) {
    if (!r || typeof r !== 'object' || Array.isArray(r)) return `${what} must be an object`;
    if (r.schema !== SCHEMA) return `schema ${r.schema} is not ${SCHEMA}`;
    if (!isHex(r.id, 16, 64)) return 'id must be 16 to 64 hex characters';
    if (!isHex(r.contributor, 16, 64)) return 'contributor must be 16 to 64 hex characters';
    if (r.fight !== undefined && r.fight !== null && !isHex(r.fight, 16, 64)) return 'fight must be 16 to 64 hex characters';
    if (!r.client || typeof r.client !== 'object') return 'client missing';
    if (!isStr(r.client.plugin, 32) || !isStr(r.client.game, 32) || !isStr(r.client.build, 48)) return 'client.plugin, game, build must be short strings';
    // The model version the client ran under (the rollout's monitoring); optional.
    if (r.client.model !== undefined && r.client.model !== null && !isStr(r.client.model, 16)) return 'client.model must be a short string';
    if (!r.me || typeof r.me !== 'object' || !CLASSES.has(String(r.me.class))) return 'me.class must be a class';
    if (r.me.level !== undefined && r.me.level !== null && !isInt(r.me.level, 1, 80)) return 'me.level out of range';
    if (r.me.spec !== undefined && r.me.spec !== null && !isStr(r.me.spec, 24)) return 'me.spec must be a short string';
    if (!r.encounter || typeof r.encounter !== 'object') return 'encounter missing';
    if (!ENCOUNTERS.has(String(r.encounter.type))) return 'encounter.type unknown';
    if (!isInt(r.encounter.duration, 0, 3600)) return 'encounter.duration out of range';
    if (!OUTCOMES.has(String(r.encounter.outcome))) return 'encounter.outcome unknown';
    if (r.encounter.enemies !== undefined && r.encounter.enemies !== null && !isInt(r.encounter.enemies, 0, 40)) return 'encounter.enemies out of range';
    const f = forbiddenKey(r, what);
    if (f) return `forbidden field ${f}`;
    return null;
}

// An empty table is ambiguous in Lua: JCore's encoder writes every empty
// table as [] (an empty map too), the client's own fallback writes {} (an
// empty list too). Live on 2026-10-12 a batch with an episode that had no
// actions came out as "actions": {} and a lesson's empty "controls_on_me"
// would come out as []. So before checking, an EMPTY value takes the shape
// its field has: [] or {} for a list, {} or [] for a map. A non-empty value
// of the wrong shape is still refused. This mutates the record, which is
// what the callers store.
const isEmptyObj = v => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === 0;
const isEmptyArr = v => Array.isArray(v) && v.length === 0;
const asList = (o, k) => { if (o && isEmptyObj(o[k])) o[k] = []; };
const asMap = (o, k) => { if (o && isEmptyArr(o[k])) o[k] = {}; };

function normalize(r) {
    if (!r || typeof r !== 'object') return r;
    asList(r, 'observations'); asList(r, 'episodes'); asList(r, 'enemies'); asList(r, 'lessons');
    for (const e of Array.isArray(r.episodes) ? r.episodes : []) {
        if (!e || typeof e !== 'object') continue;
        asList(e, 'actions');
        if (e.result && typeof e.result === 'object') asList(e.result, 'all');
    }
    for (const x of Array.isArray(r.enemies) ? r.enemies : []) {
        if (!x || typeof x !== 'object') continue;
        asMap(x, 'used'); asMap(x, 'controls_on_me'); asMap(x, 'patterns'); asMap(x, 'defensives');
    }
    if (r.diagnostics && typeof r.diagnostics === 'object') { asList(r.diagnostics, 'moments'); asList(r.diagnostics, 'states'); }
    if (r.baits && typeof r.baits === 'object') asMap(r.baits, 'kinds');
    return r;
}

function validateBatch(b) {
    normalize(b);
    const e = head(b, 'batch');
    if (e) return e;
    if (!Array.isArray(b.observations)) return 'observations must be a list';
    if (b.observations.length > 200) return 'more than 200 observations';
    for (let i = 0; i < b.observations.length; i++) {
        const o = b.observations[i];
        const at = `observations[${i}]`;
        if (!o || typeof o !== 'object') return `${at} must be an object`;
        if (!PATTERNS.has(String(o.pattern))) return `${at}.pattern unknown`;
        if (!CLASSES.has(String(o.enemy_class))) return `${at}.enemy_class unknown`;
        if (!isNum(o.p, 0, 1)) return `${at}.p must be 0..1`;
        if (!isNum(o.reliability, 0, 1)) return `${at}.reliability must be 0..1`;
        if (typeof o.sure !== 'boolean' || typeof o.hit !== 'boolean' || typeof o.inputs_ok !== 'boolean' || typeof o.correct !== 'boolean') {
            return `${at}: sure, hit, inputs_ok, correct must be booleans`;
        }
        if (!isNum(o.evidence, 0, 1000)) return `${at}.evidence out of range`;
        if (!isStr(o.basis, 16)) return `${at}.basis must be a short string`;
        if (o.t !== undefined && o.t !== null && !isNum(o.t, 0, 3600)) return `${at}.t out of range`;
        if (o.context !== undefined && (typeof o.context !== 'object' || o.context === null)) return `${at}.context must be an object`;
        if (o.context && o.context.me_hp !== undefined && !isInt(o.context.me_hp, 0, 4)) return `${at}.context.me_hp must be a band 0..4`;
    }
    if (b.censored !== undefined && b.censored !== null && !isStr(b.censored, 120)) return 'censored must be a short string';
    if (b.episodes !== undefined && b.episodes !== null) {
        if (!Array.isArray(b.episodes) || b.episodes.length > 40) return 'episodes: a list of at most 40';
        for (let i = 0; i < b.episodes.length; i++) {
            const e = b.episodes[i];
            const at = `episodes[${i}]`;
            if (!e || typeof e !== 'object') return `${at} must be an object`;
            if (!isHex(e.id, 16, 64)) return `${at}.id must be hex`;
            if (!EPISODE_TYPES.has(String(e.type))) return `${at}.type unknown`;
            if (!CLASSES.has(String(e.enemy_class))) return `${at}.enemy_class unknown`;
            if (!isNum(e.t, 0, 3600) || !isNum(e.horizon, 0, 60)) return `${at}: t and horizon out of range`;
            if (!e.trigger || !isStr(e.trigger.text, 160) || typeof e.trigger.observed !== 'boolean') return `${at}.trigger malformed`;
            for (const side of ['before', 'after']) {
                const s = e[side];
                if (s === undefined || s === null) continue;
                if (typeof s !== 'object' || !isNum(s.hp, 0, 1) || !isInt(s.attackers, 0, 40) || typeof s.controlled !== 'boolean') return `${at}.${side} malformed`;
                if (s.zone !== undefined && s.zone !== null && !isStr(s.zone, 16)) return `${at}.${side}.zone malformed`;
            }
            if (!e.prediction || !PREDICTION_OUTCOMES.has(String(e.prediction.outcome))) return `${at}.prediction.outcome unknown`;
            if (e.prediction.pattern !== undefined && e.prediction.pattern !== null && !PATTERNS.has(String(e.prediction.pattern))) return `${at}.prediction.pattern unknown`;
            if (!e.recommendation || !RECOMMENDATION_OUTCOMES.has(String(e.recommendation.outcome))) return `${at}.recommendation.outcome unknown`;
            if (e.recommendation.action !== undefined && e.recommendation.action !== null && typeof e.recommendation.action !== 'string') return `${at}.recommendation.action malformed`;
            if (typeof e.recommendation.action === 'string' && e.recommendation.action.length > 120) return `${at}.recommendation.action too long`;
            if (!Array.isArray(e.actions) || e.actions.length > 16) return `${at}.actions: a list of at most 16`;
            for (const a of e.actions) if (!isStr(a, 48)) return `${at}.actions has a bad name`;
            if (!e.result || !RESULTS.has(String(e.result.primary))) return `${at}.result.primary unknown`;
            if (!Array.isArray(e.result.all) || e.result.all.length > 8) return `${at}.result.all malformed`;
            for (const r of e.result.all) if (!RESULTS.has(String(r))) return `${at}.result.all has an unknown category`;
            if (!e.quality || typeof e.quality !== 'object') return `${at}.quality missing`;
            if (e.quality.test_data === true) return `${at} is test data`;
            if (e.lesson !== undefined && e.lesson !== null) {
                if (typeof e.lesson !== 'object' || !CONFIDENCES.has(String(e.lesson.confidence))) return `${at}.lesson.confidence unknown`;
                if (e.lesson.candidate !== undefined && e.lesson.candidate !== null && !isStr(e.lesson.candidate, 400)) return `${at}.lesson.candidate too long`;
            }
        }
    }
    if (b.diagnostics !== undefined && b.diagnostics !== null) {
        const d = b.diagnostics;
        if (typeof d !== 'object') return 'diagnostics must be an object';
        if (d.moments && (!Array.isArray(d.moments) || d.moments.length > 40)) return 'diagnostics.moments: at most 40';
        for (const m of d.moments || []) {
            if (!m || !isInt(m.t, 0, 3600) || !isStr(m.text, 200)) return 'a diagnostics moment is malformed';
        }
    }
    return null;
}

function validateLesson(l) {
    normalize(l);
    const e = head(l, 'lesson');
    if (e) return e;
    if (!Array.isArray(l.enemies) || l.enemies.length > 10) return 'enemies must be a list of at most 10';
    for (let i = 0; i < l.enemies.length; i++) {
        const x = l.enemies[i];
        const at = `enemies[${i}]`;
        if (!x || typeof x !== 'object') return `${at} must be an object`;
        if (!CLASSES.has(String(x.class))) return `${at}.class unknown`;
        if (x.role !== undefined && x.role !== null && !isStr(x.role, 16)) return `${at}.role must be a short string`;
        if (x.level !== undefined && x.level !== null && !isInt(x.level, 1, 80)) return `${at}.level out of range`;
        let m = countsMap(x.used, 80, `${at}.used`); if (m) return m;
        m = countsMap(x.controls_on_me, 20, `${at}.controls_on_me`); if (m) return m;
        if (!isInt(x.bursts || 0, 0, 100)) return `${at}.bursts out of range`;
        if (!isNum(x.hp_min === undefined ? 1 : x.hp_min, 0, 1)) return `${at}.hp_min must be 0..1`;
        if (x.patterns) {
            if (typeof x.patterns !== 'object') return `${at}.patterns must be a map`;
            for (const [k, c] of Object.entries(x.patterns)) {
                if (!PATTERNS.has(k)) return `${at}.patterns.${k} unknown`;
                if (!c || !isInt(c.hits, 0, 1000) || !isInt(c.total, 0, 1000) || c.hits > c.total) return `${at}.patterns.${k} counts are wrong`;
            }
        }
    }
    if (!Array.isArray(l.lessons) || l.lessons.length > 12) return 'lessons must be a list of at most 12 codes';
    for (const c of l.lessons) if (!LESSON_CODES.has(String(c))) return `lesson code ${c} unknown`;
    if (l.predictions && typeof l.predictions === 'object') {
        if (!isInt(l.predictions.forecasts || 0, 0, 10000) || !isInt(l.predictions.right || 0, 0, 10000)) return 'predictions counts are wrong';
        if (!isNum(l.predictions.brier || 0, 0, 10000)) return 'predictions.brier is wrong';
    }
    return null;
}

// One fight in one record (the GitHub backend since 2026-10-12: one issue
// per fight, not two): its lesson and, when it made forecasts or episodes,
// its batch, under one id and one contributor.
function validateFight(f) {
    if (!f || typeof f !== 'object' || Array.isArray(f)) return 'fight must be an object';
    if (f.schema !== SCHEMA) return `schema ${f.schema} is not ${SCHEMA}`;
    if (!isHex(f.id, 16, 64)) return 'id must be 16 to 64 hex characters';
    if (!isHex(f.contributor, 16, 64)) return 'contributor must be 16 to 64 hex characters';
    if (!f.lesson || typeof f.lesson !== 'object') return 'lesson missing';
    let e = validateLesson(f.lesson);
    if (e) return 'lesson: ' + e;
    if (f.lesson.contributor !== f.contributor) return 'lesson.contributor does not match';
    if (f.batch !== undefined && f.batch !== null) {
        e = validateBatch(f.batch);
        if (e) return 'batch: ' + e;
        if (f.batch.contributor !== f.contributor) return 'batch.contributor does not match';
    }
    const extra = forbiddenKey(f, 'fight');
    if (extra) return `forbidden field ${extra}`;
    return null;
}

function validateDelete(d) {
    if (!d || typeof d !== 'object') return 'must be an object';
    if (d.schema !== SCHEMA) return `schema ${d.schema} is not ${SCHEMA}`;
    if (!isHex(d.contributor, 16, 64)) return 'contributor must be 16 to 64 hex characters';
    return null;
}

module.exports = { normalize, SCHEMA, CLASSES, PATTERNS, OUTCOMES, ENCOUNTERS, LESSON_CODES, EPISODE_TYPES, RESULTS,
    validateBatch, validateLesson, validateFight, validateDelete, forbiddenKey };

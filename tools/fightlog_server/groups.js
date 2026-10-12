'use strict';
// Jambix central service -- the learning groups (the brief's §1): the
// context a record carries, the four levels it is filed under, and the
// backoff a reader walks when the narrow level is thin.
//
//   exact    game | my class | opponent class | my level bracket | encounter | 1v1 or outnumbered
//   matchup  game | my class | opponent class
//   class    game | opponent class                 (how that class behaves, whoever faces it)
//   general  game                                  (the compatible baseline)
//
// The game variant (Classic Era "Vanilla", "Forever", ...) is in every key:
// nothing merges across it, whatever the level. The build is kept beside
// the key (drift is measured by build, never pooled away). Conditions that
// change inside a fight -- health, threat, control -- are not levels: they
// are reported as conditional rates inside a group (learn.js by_condition).

const LEVELS = ['exact', 'matchup', 'class', 'general'];
// Broader evidence carries less certainty: the reliability a reader may
// attach to a rate found at each level, 1 at the exact level.
const CERTAINTY = { exact: 1.0, matchup: 0.85, class: 0.7, general: 0.5 };

function bracket(level) {
    if (!Number.isInteger(level) || level < 1) return '?';
    if (level >= 60) return '60';
    const lo = Math.floor(level / 10) * 10;
    return `${lo}-${lo + 9}`;
}

function combatOf(enemies) {
    if (!Number.isInteger(enemies)) return '?';
    return enemies >= 2 ? 'outnumbered' : '1v1';
}

/** The context of one record (a batch or a lesson) against one opponent class. */
function contextOf(record, enemyClass, extra) {
    const c = record.client || {}, me = record.me || {}, enc = record.encounter || {};
    const x = extra || {};
    return {
        game: String(c.game || '?'), build: String(c.build || '?'), plugin: String(c.plugin || '?'),
        model: c.model ? String(c.model) : null,
        me_class: String(me.class || '?'), me_level: Number.isInteger(me.level) ? me.level : null, bracket: bracket(me.level),
        me_spec: me.spec ? String(me.spec) : '?',
        enemy_class: String(enemyClass || '?'), encounter: String(enc.type || '?'),
        combat: combatOf(Number.isInteger(x.enemies) ? x.enemies : (Number.isInteger(enc.enemies) ? enc.enemies : undefined)),
    };
}

function keyAt(ctx, level) {
    switch (level) {
        case 'general': return `g:${ctx.game}`;
        case 'class': return `g:${ctx.game}|e:${ctx.enemy_class}`;
        case 'matchup': return `g:${ctx.game}|me:${ctx.me_class}|e:${ctx.enemy_class}`;
        case 'exact': return `g:${ctx.game}|me:${ctx.me_class}|e:${ctx.enemy_class}|lv:${ctx.bracket}|enc:${ctx.encounter}|${ctx.combat}`;
        default: throw new Error(`no such level: ${level}`);
    }
}

/** The four keys of a context, narrowest first. */
function keysOf(ctx) {
    return LEVELS.map(level => ({ level, key: keyAt(ctx, level) }));
}

/** The parent level's key (what an entry is compared with). */
function parentOf(level) {
    const i = LEVELS.indexOf(level);
    return i < 0 || i === LEVELS.length - 1 ? null : LEVELS[i + 1];
}

function describe(ctx, level) {
    return {
        level, game: ctx.game, enemy_class: ctx.enemy_class,
        me_class: level === 'exact' || level === 'matchup' ? ctx.me_class : undefined,
        bracket: level === 'exact' ? ctx.bracket : undefined,
        encounter: level === 'exact' ? ctx.encounter : undefined,
        combat: level === 'exact' ? ctx.combat : undefined,
    };
}

/**
 * The backoff: the first level, narrowest first, whose entry for the pattern
 * is usable (`unreliable` false). Returns { p, level, certainty, entry } or
 * null when no level holds one. Never crosses the game: every key carries
 * it. `groups` is a model's `games[game].groups` map.
 */
function resolve(groups, ctx, pattern, allowUnreliable) {
    if (!groups) return null;
    for (const { level, key } of keysOf(ctx)) {
        const g = groups[key];
        const e = g && g.patterns && g.patterns[pattern];
        if (!e) continue;
        if (e.unreliable && !allowUnreliable) continue;
        return { p: e.p, level, key, certainty: CERTAINTY[level], entry: e };
    }
    return null;
}

module.exports = { LEVELS, CERTAINTY, bracket, combatOf, contextOf, keyAt, keysOf, parentOf, describe, resolve };

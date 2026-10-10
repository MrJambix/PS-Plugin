// recorder_report -- reads what JCore's API recorder saw on the Forever client
// and lists what to fix in scripts/.api.
//
// Usage:
//   node tools/jcheck/recorder_report.js [recording.json] [--all] [--ns <namespace>] [--md [out.md]]
//
// The recording defaults to scripts_data/jcore/jcore.recorder.json (the game
// writes scripts_data into the workspace). --all prints every row instead of
// the first 40 of each list. --ns input lists every function of one namespace
// (called or not). --md writes the reference, one table per namespace, to
// scripts/jambix_debug/FOREVER_API.md (or the path given).
//
// The recording (format 2, JCore 1.5.12) is one entry per function: its kind,
// what triggered each call, what it answered, and for an action the events
// that followed it. A format 1 recording (JCore 1.5.4 to 1.5.11) is read too;
// it has no triggers or effects.
//
// What it prints:
//   coverage      per namespace: what the client exposes, what was called,
//                 what .api lacks
//   actions       every action called: what triggered it, what it answered,
//                 and the events that followed (with how much more often
//                 than after other actions: the lift)
//   new API       on the client, not in .api: what each answered and who
//                 called it
//   missing       documented in .api, absent from the client's core table
//   always empty  called, and every answer was nil / 0 / "" / {}
//   raised        called, and raised (the message and arguments)
//   notes to fix  the stub says Forever answers empty or does nothing, and
//                 the client answered something real
//   always false  predicates that never said true (weak evidence: the state
//                 may simply not have happened while recording)
//   objects       the same for game_object methods, with the methods other
//                 scripts define (origin Lua) kept apart from the client's
//   events        every game event: its layouts, and the actions before it
//   never called  documented and on the client, never called: the to-do list
//
// No dependencies. Exit code 0 always: this is a reading aid, not a check.

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const API = path.join(ROOT, 'scripts', '.api');

const args = process.argv.slice(2);
const all = args.includes('--all');
const flagValue = (flag) => {
  const i = args.indexOf(flag);
  if (i < 0) return undefined;
  const v = args[i + 1];
  return v && !v.startsWith('--') ? v : null;
};
const nsFilter = flagValue('--ns');
const mdOut = flagValue('--md');
const wantMd = args.includes('--md');
const flagArgs = new Set([nsFilter, mdOut].filter(Boolean));
const file = args.find((a) => !a.startsWith('--') && !flagArgs.has(a))
  || path.join(ROOT, 'scripts_data', 'jcore', 'jcore.recorder.json');
const LIMIT = all ? Infinity : 40;

if (!fs.existsSync(file)) {
  console.error(`no recording at ${file}`);
  console.error('Play a session on the Forever client with JCore 1.5.4 or later, then run this again.');
  process.exit(0);
}

const raw = JSON.parse(fs.readFileSync(file, 'utf8'));

// --- format 1 -> format 2 -------------------------------------------------------

const READ_PREFIXES = ['get_', 'is_', 'has_', 'can_', 'read_', 'does_', 'num_', 'query_', 'calculate_', 'translate_',
  'scale_', 'normalize_', 'trace_', 'native_', 'cursor_has_', 'spell_has_', 'world_pos_', 'ui_pos_', 'load_'];
const READ_NAMES = new Set(['w2s', 'world_to_screen', 'node_name']);
const GAME_TOP = new Set(['execute', 'play_sound_by_id', 'stop_sound_by_handle', 'reload_game_ui', 'write_cvar']);
const METHOD_ACTIONS = ['set_', 'use_', 'cast_', 'interact', 'loot_', 'select_', 'cancel_', 'stop_'];
const isRead = (n) => READ_NAMES.has(n) || READ_PREFIXES.some((p) => n.startsWith(p));

/** The recorder's kind_for, for a format 1 file that has no kinds. */
function kindFor(key, mode, method) {
  const name = method ? key : key.slice(key.lastIndexOf('.') + 1);
  const ns = method ? '' : (key.includes('.') ? key.slice(0, key.lastIndexOf('.')) : '');
  if (mode === 'count') return ns === 'graphics' ? 'paint' : 'clock';
  if (method) return METHOD_ACTIONS.some((p) => name.startsWith(p)) ? 'action' : 'read';
  if (ns === '') {
    if (name.startsWith('http_')) return 'net';
    if (GAME_TOP.has(name)) return 'action';
    if (/^(create|delete|write)_/.test(name)) return 'file';
    return isRead(name) ? 'read' : 'loader';
  }
  if (ns === 'graphics') return 'read';
  return isRead(name) ? 'read' : 'action';
}

function statusOf(r) {
  if (r.kind === 'paint' || r.kind === 'clock') return 'counted';
  if (!r.tallied) return r.errors ? 'raises' : 'not inspected';
  if (r.empty === r.tallied) {
    const firsts = Object.keys(r.answers || {}).map((s) => s.split(',')[0]);
    if (firsts.some((f) => f !== 'none' && f !== 'false')) return 'always empty';
    if (firsts.includes('false')) return 'only false';
    return 'returns nothing';
  }
  return r.errors ? 'answers (sometimes raises)' : 'answers';
}

function fromV1(r, key, method, sessions) {
  const kind = kindFor(key, r.mode, method);
  const out = {
    kind, calls: r.calls, tallied: r.tallied, empty: r.empty, inspected: r.inspected, errors: r.errors,
    answers: r.shapes || {}, first_session: 1, last_session: sessions,
    examples: (r.samples || []).map((s) => ({ call: `(${s.args})`, answer: s.ret, shape: s.shape })),
    raised: (r.error_samples || []).map((e) => ({ error: e.error, call: `(${e.args})` })),
    triggers: {},
  };
  out.status = statusOf(out);
  return out;
}

function normalise(rec) {
  if (rec.format === 2) return rec;
  const sessions = rec.sessions || 1;
  const functions = {};
  const methods = {};
  for (const [key, r] of Object.entries(rec.calls || {})) {
    if (key.startsWith('game_object:')) methods[key.slice(12)] = fromV1(r, key.slice(12), true, sessions);
    else functions[key] = fromV1(r, key, false, sessions);
  }
  const events = {};
  for (const [key, e] of Object.entries(rec.events || {})) {
    events[key] = { count: e.count, layouts: (e.samples || []).map((s) => ({ size: s.size, example: s.args })), after: {} };
  }
  return {
    format: 1, client: rec.client, functions, methods, events, surface: rec.surface || {},
    sessions: { count: sessions, log: [] }, triggers_from: 'not recorded (format 1, before JCore 1.5.12)',
  };
}

const rec = normalise(raw);
const functions = rec.functions || {};
const methods = rec.methods || {};
const events = rec.events || {};
const surface = rec.surface || {};

// --- the .api stubs ----------------------------------------------------------

/** core functions by dotted path ("spell_book.get_spell_cooldown"), with the
 *  comment block written above each. */
function readCoreApi() {
  const out = new Map();
  const lines = fs.readFileSync(path.join(API, 'core.lua'), 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const m = /^function core\.([A-Za-z0-9_.]+)\s*\(/.exec(lines[i]);
    if (!m) continue;
    const doc = [];
    for (let j = i - 1; j >= 0 && /^\s*---/.test(lines[j]); j--) doc.unshift(lines[j].replace(/^\s*---\s?/, ''));
    out.set(m[1], { line: i + 1, doc });
  }
  return out;
}

/** game_object methods, with the comment lines between the previous field and
 *  this one. */
function readObjectApi() {
  const out = new Map();
  const lines = fs.readFileSync(path.join(API, 'game_object.lua'), 'utf8').split(/\r?\n/);
  let inClass = false;
  let doc = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^---@class\s+game_object\b/.test(line)) { inClass = true; doc = []; continue; }
    if (!inClass) continue;
    // The class ends at the first line that is not a comment, or at the
    // next class.
    if (!/^\s*--/.test(line) || /^---@class\s/.test(line)) { inClass = false; continue; }
    const f = /^---@field\s+([A-Za-z0-9_]+)\s+fun\(\s*self/.exec(line);
    if (f) {
      out.set(f[1], { line: i + 1, doc });
      doc = [];
    } else if (!/^---@field\s/.test(line)) {
      doc.push(line.replace(/^\s*---?\s?/, ''));
    } else {
      doc = [];
    }
  }
  return out;
}

const coreApi = readCoreApi();
const objectApi = readObjectApi();

// --- helpers -------------------------------------------------------------------

const EMPTY_CLAIM = /(always|answers?)\s+(nil|0|\{\}|""|false|empty|an empty)|does nothing|silently does nothing|no-op|NOT WORKING|BROKEN|never answers/i;

function foreverNote(doc) {
  if (!doc) return null;
  const hit = doc.find((l) => /Forever/.test(l));
  return hit ? hit.trim() : null;
}

/** The first sentence of a stub's description, for "what .api says": the
 *  description before the VERSIONS notes when there is one. */
function summary(doc) {
  if (!doc) return '';
  const lines = doc.map((l) => l.trim()).filter((l) => l && !l.startsWith('@'));
  const cut = lines.findIndex((l) => /^VERSIONS\b/.test(l));
  const text = (cut > 0 ? lines.slice(0, cut) : lines).join(' ').replace(/\s+/g, ' ').trim();
  const first = text.split(/(?<=\.)\s/)[0] || '';
  return first.length > 110 ? `${first.slice(0, 107)}...` : first;
}

function claimsEmptyOnForever(doc) {
  if (!doc) return false;
  const text = doc.join(' ');
  // A sentence naming Forever and an empty answer, or a VERSIONS line that
  // lists the products the call works on and leaves Forever out is not
  // decidable here; only explicit claims count.
  return text.split(/(?<=\.)\s+/).some((s) => /Forever/.test(s) && EMPTY_CLAIM.test(s));
}

function head(list) {
  return list.slice(0, LIMIT);
}

function more(list) {
  return list.length > LIMIT ? `  ... ${list.length - LIMIT} more (--all)` : null;
}

function section(title, rows) {
  console.log('');
  console.log(`${title} (${rows.length})`);
  console.log('-'.repeat(Math.min(78, title.length + 6)));
  if (rows.length === 0) { console.log('  none'); return; }
  for (const r of head(rows)) console.log(r);
  const m = more(rows);
  if (m) console.log(m);
}

const byCount = (o) => Object.entries(o || {}).sort((a, b) => b[1] - a[1]);

function shapes(r) {
  return byCount(r.answers).map(([s, n]) => `${s} x${n}`).join(', ');
}

function example(r) {
  const e = (r.examples || [])[0];
  return e ? `${e.call} -> ${e.answer}` : '';
}

function signature(r) {
  if (!r.args && !r.returns) return '';
  return `(${(r.args || []).join(', ')}) -> ${(r.returns || []).join(', ') || 'nothing'}`;
}

function triggers(r, n = 3) {
  const rows = byCount(r.triggers);
  if (!rows.length) return '';
  const shown = rows.slice(0, n).map(([t, c]) => `${t} x${c}`).join('; ');
  return rows.length > n ? `${shown}; +${rows.length - n} more` : shown;
}

// The lift: how much more often an event followed THIS action's calls than
// it followed the calls of every action together. An event the game sends
// all the time (the combat log in a fight) follows everything alike, lift
// near 1; what the action does stands out.
const baseline = (() => {
  let windows = 0;
  const followed = {};
  for (const r of [...Object.values(functions), ...Object.values(methods)]) {
    if (!r.effects) continue;
    windows += r.effects.windows || 0;
    for (const [ev, n] of Object.entries(r.effects)) if (ev !== 'windows') followed[ev] = (followed[ev] || 0) + n;
  }
  return { windows, followed };
})();

function effects(r, n = 4) {
  const eff = r.effects;
  if (!eff || !eff.windows) return '';
  const rows = byCount(Object.fromEntries(Object.entries(eff).filter(([k]) => k !== 'windows')));
  if (!rows.length) return `nothing followed (${eff.windows} calls watched)`;
  return rows.slice(0, n).map(([ev, c]) => {
    const share = c / eff.windows;
    const base = baseline.windows ? (baseline.followed[ev] || 0) / baseline.windows : 0;
    const lift = base > 0 && baseline.windows > eff.windows ? ` x${(share / base).toFixed(1)}` : '';
    return `${ev} ${c}/${eff.windows} (${Math.round(share * 100)}%${lift})`;
  }).join('; ');
}

const origin = (r) => (r.origin ? ` [${r.origin}]` : '');

// --- header ----------------------------------------------------------------------

const c = rec.client || {};
const sess = rec.sessions || {};
console.log(`FOREVER API -- ${path.relative(ROOT, file)} (format ${rec.format})`);
console.log(`Client ${c.version || '?'} (${c.exact || '?'}), JCore ${c.jcore || '?'}, ${sess.count || 1} session(s); triggers from ${rec.triggers_from || '?'}`);
console.log(`${Object.keys(functions).length} functions and ${Object.keys(methods).length} object methods called, ` +
  `${Object.keys(events).length} event keys, game object index: ${surface.object_index || '?'}`);
const log = sess.log || [];
if (log.length) {
  const last = log[log.length - 1];
  const l = last.learned || {};
  console.log(`Session ${last.n} (${last.started || '?'}, ${last.seconds || 0}s): learned ${l.functions || 0} functions, ` +
    `${l.examples || 0} examples, ${l.triggers || 0} triggers, ${l.effects || 0} effects, ${l.events || 0} events, ${l.layouts || 0} layouts`);
  const idle = log.filter((s) => s.learned && Object.values(s.learned).every((v) => !v)).length;
  if (idle) console.log(`${idle} of the last ${log.length} sessions learned nothing new`);
}
if ((surface.unwritable || []).length) console.log(`NOT RECORDED (could not wrap): ${surface.unwritable.join(', ')}`);

// --- the client's surface ------------------------------------------------------

const onClient = new Set();
for (const name of surface.core || []) onClient.add(name);
for (const [ns, names] of Object.entries(surface.namespaces || {})) {
  for (const name of names) onClient.add(`${ns}.${name}`);
}
for (const name of surface.skipped || []) {
  if (!name.endsWith('.*')) onClient.add(name);
}
const skippedNs = new Set((surface.skipped || []).filter((n) => n.endsWith('.*')).map((n) => n.slice(0, -2)));
const skippedFns = new Set((surface.skipped || []).filter((n) => !n.endsWith('.*')));
const clientNs = new Set(Object.keys(surface.namespaces || {}));
const nsOf = (key) => (key.includes('.') ? key.slice(0, key.lastIndexOf('.')) : 'core');

// --- coverage --------------------------------------------------------------------

const coverage = new Map();
const cover = (ns) => {
  if (!coverage.has(ns)) coverage.set(ns, { exposed: 0, called: 0, undocumented: 0, actions: 0 });
  return coverage.get(ns);
};
for (const key of onClient) {
  if (skippedFns.has(key)) continue;
  const row = cover(nsOf(key));
  row.exposed += 1;
  if (functions[key] && functions[key].calls > 0) row.called += 1;
  if (!coreApi.has(key)) row.undocumented += 1;
  if (kindFor(key, 'full', false) === 'action') row.actions += 1;
}
const methodSurface = new Set([...(surface.object_methods || []), ...Object.keys(methods)]);
if (methodSurface.size) {
  const row = cover('game_object');
  for (const m of methodSurface) {
    row.exposed += 1;
    if (methods[m] && methods[m].calls > 0) row.called += 1;
    if (!objectApi.has(m)) row.undocumented += 1;
  }
}
section('COVERAGE: what the client exposes, what was ever called, what .api lacks',
  [...coverage].sort((a, b) => b[1].exposed - a[1].exposed).map(([ns, r]) =>
    `  ${ns.padEnd(28)} ${String(r.exposed).padStart(4)} exposed  ${String(r.called).padStart(4)} called` +
    `  ${String(r.undocumented).padStart(4)} not in .api${r.actions ? `  (${r.actions} actions)` : ''}`));

if (nsFilter) {
  const names = nsFilter === 'core' ? (surface.core || []) : (surface.namespaces || {})[nsFilter] || [];
  section(`EVERY FUNCTION IN ${nsFilter}`, names.map((n) => {
    const key = nsFilter === 'core' ? n : `${nsFilter}.${n}`;
    const r = functions[key];
    const info = coreApi.get(key);
    if (!r) return `  ${n.padEnd(36)} never called${info ? '' : '  NOT IN .api'}${info ? `\n      .api: ${summary(info.doc)}` : ''}`;
    return `  ${n.padEnd(36)} ${r.kind}, ${r.status}, x${r.calls}${info ? '' : '  NOT IN .api'}  ${example(r)}` +
      (triggers(r) ? `\n      by   ${triggers(r)}` : '') + (effects(r) ? `\n      then ${effects(r)}` : '');
  }));
}

// --- actions ---------------------------------------------------------------------

const actionRows = Object.entries(functions)
  .filter(([, r]) => r.kind === 'action' && r.calls > 0)
  .sort((a, b) => b[1].calls - a[1].calls)
  .map(([key, r]) => {
    const lines = [`  ${key}  x${r.calls}  ${r.status}  ${example(r)}${coreApi.has(key) ? '' : '  NOT IN .api'}`];
    if (triggers(r)) lines.push(`      by   ${triggers(r)}`);
    lines.push(`      then ${effects(r) || 'no effect data (recorded before JCore 1.5.12)'}`);
    return lines.join('\n');
  });
section('ACTIONS: what triggered them, and what they did', actionRows);

const otherKinds = ['loader', 'net', 'file'].map((kind) => {
  const keys = Object.entries(functions).filter(([, r]) => r.kind === kind && r.calls > 0)
    .sort((a, b) => b[1].calls - a[1].calls).map(([k, r]) => `${k} x${r.calls}`);
  return keys.length ? `  ${kind}: ${keys.join(', ')}` : null;
}).filter(Boolean);
if (otherKinds.length) section('THE LOADER, FILES AND NET (not game actions)', otherKinds);

// --- new API ---------------------------------------------------------------------

if (onClient.size > 0) {
  const undocumented = [...onClient].filter((k) => !coreApi.has(k) && !skippedFns.has(k)).sort();
  const calledNew = undocumented.filter((k) => functions[k] && functions[k].calls > 0);
  const quietNew = undocumented.filter((k) => !(functions[k] && functions[k].calls > 0));
  const rows = calledNew.map((k) => {
    const r = functions[k];
    return `  core.${k}  ${r.kind}, ${r.status}, x${r.calls}${origin(r)}  ${example(r)}` +
      (signature(r) ? `\n      kinds ${signature(r)}` : '') + (triggers(r) ? `\n      by    ${triggers(r)}` : '') +
      (effects(r) ? `\n      then  ${effects(r)}` : '');
  });
  if (quietNew.length) rows.push(`  never called (${quietNew.length}): ${quietNew.map((k) => `core.${k}`).join(', ')}`);
  section(`NEW API: on the client, not in .api (${calledNew.length} called)`, rows);

  const missing = [];
  const absentNs = new Map();
  for (const [key, info] of coreApi) {
    if (onClient.has(key)) continue;
    const ns = key.includes('.') ? key.slice(0, key.lastIndexOf('.')) : '';
    if (ns && skippedNs.has(ns.split('.')[0])) continue;
    if (ns && !clientNs.has(ns)) {
      absentNs.set(ns, (absentNs.get(ns) || 0) + 1);
      continue;
    }
    const note = foreverNote(info.doc);
    missing.push(`  core.${key}  (.api core.lua:${info.line})${note ? `\n      stub: ${note}` : ''}`);
  }
  const wholeNs = [...absentNs].sort()
    .map(([ns, n]) => `  core.${ns}.*  whole namespace absent (${n} documented calls)`);
  section('MISSING ON THE CLIENT (documented, not in core)', wholeNs.concat(missing));
}

// --- answers -----------------------------------------------------------------------

function answerRows(table, isMethod) {
  const empty = [];
  const alwaysFalse = [];
  const raised = [];
  const wrongNotes = [];
  for (const [key, r] of Object.entries(table)) {
    if (isMethod && r.origin === 'Lua') continue;
    const info = isMethod ? objectApi.get(key) : coreApi.get(key);
    const where = info ? (isMethod ? `game_object.lua:${info.line}` : `core.lua:${info.line}`) : 'not in .api';
    const label = isMethod ? `game_object:${key}` : `core.${key}`;
    const note = info && foreverNote(info.doc);
    const by = triggers(r, 2);

    if (r.status === 'always empty' || r.status === 'only false') {
      (r.status === 'always empty' ? empty : alwaysFalse).push({
        calls: r.calls,
        text: `  ${label}  x${r.calls}  [${shapes(r)}]  (${where})\n      ${example(r)}` +
          (by ? `\n      by: ${by}` : '') + (note ? `\n      stub: ${note}` : ''),
      });
    }
    if (r.errors > 0) {
      const msgs = (r.raised || []).map((e) => `      raised: ${e.error}\n        call: ${e.call}${e.by ? `  by ${e.by}` : ''}`).join('\n');
      raised.push({ calls: r.errors, text: `  ${label}  ${r.errors} raise(s) in ${r.inspected} inspected  (${where})\n${msgs}` });
    }
    if (info && r.tallied > r.empty && claimsEmptyOnForever(info.doc)) {
      const real = (r.examples || []).find((s) => !/^(nil|false|0|""|\{\}|none)(,|$)/.test(s.shape || ''));
      wrongNotes.push({
        calls: r.calls,
        text: `  ${label}  answered ${r.tallied - r.empty} of ${r.tallied} times  (${where})\n      stub: ${note}` +
          (real ? `\n      saw:  ${real.call} -> ${real.answer}` : ''),
      });
    }
  }
  const order = (a, b) => b.calls - a.calls;
  return {
    empty: empty.sort(order).map((r) => r.text),
    alwaysFalse: alwaysFalse.sort(order).map((r) => r.text),
    raised: raised.sort(order).map((r) => r.text),
    wrongNotes: wrongNotes.sort(order).map((r) => r.text),
  };
}

const core = answerRows(functions, false);
section('ALWAYS EMPTY (every answer nil / 0 / "" / {})', core.empty);
section('RAISED', core.raised);
section('NOTES TO FIX (the stub says Forever answers empty; it did not)', core.wrongNotes);
section('ALWAYS FALSE (a predicate; real only if its state happened while recording)', core.alwaysFalse);

const obj = answerRows(methods, true);
section('GAME OBJECT: ALWAYS EMPTY', obj.empty);
section('GAME OBJECT: RAISED', obj.raised);
section('GAME OBJECT: NOTES TO FIX', obj.wrongNotes);
section('GAME OBJECT: ALWAYS FALSE', obj.alwaysFalse);

if (surface.object_index === 'table' || surface.object_index === 'function') {
  const seen = methodSurface;
  if (surface.object_index === 'table') {
    const absent = [...objectApi.keys()].filter((m) => !seen.has(m)).sort()
      .map((m) => `  game_object:${m}  (game_object.lua:${objectApi.get(m).line})`);
    section('GAME OBJECT: DOCUMENTED, NOT ON THE CLIENT', absent);
  }
  const extra = [...seen].filter((m) => !objectApi.has(m)).sort();
  const helpers = extra.filter((m) => methods[m] && methods[m].origin === 'Lua');
  const native = extra.filter((m) => !(methods[m] && methods[m].origin === 'Lua'));
  section('GAME OBJECT: ON THE CLIENT, NOT DOCUMENTED (the client\'s own, or origin not recorded)',
    native.map((m) => `  game_object:${m}${methods[m] ? `  x${methods[m].calls}  ${example(methods[m])}${origin(methods[m])}` : ''}`));
  if (helpers.length) {
    section('GAME OBJECT: METHODS OTHER SCRIPTS DEFINE (origin Lua, not the client\'s API)',
      [`  ${helpers.join(', ')}`]);
  }
}

// --- events -------------------------------------------------------------------------

const evRows = Object.entries(events)
  .sort((a, b) => b[1].count - a[1].count)
  .map(([name, e]) => {
    const layouts = (e.layouts || []).map((s) => `      [${s.kinds != null ? s.kinds : `${s.size} args`}] ${s.example}`).join('\n');
    const after = byCount(e.after).map(([a, n]) => `${a} ${n}`).join(', ');
    const cause = after || e.unprompted !== undefined
      ? `\n      after: ${after || 'no action'}${e.unprompted !== undefined ? `; unprompted ${e.unprompted}` : ''}`
      : '';
    return `  ${name}  x${e.count}, ${(e.layouts || []).length} layout(s)\n${layouts}${cause}`;
  });
section('EVENTS: what the game sent, and what set it off', evRows);

// --- never called ------------------------------------------------------------------

const neverByNs = new Map();
for (const key of onClient) {
  if (functions[key] || !coreApi.has(key) || skippedFns.has(key)) continue;
  const ns = nsOf(key);
  if (!neverByNs.has(ns)) neverByNs.set(ns, []);
  neverByNs.get(ns).push(key.slice(key.lastIndexOf('.') + 1));
}
const neverTotal = [...neverByNs.values()].reduce((n, l) => n + l.length, 0);
section(`NEVER CALLED: documented and on the client, answers unknown (${neverTotal} functions)`,
  [...neverByNs].sort((a, b) => b[1].length - a[1].length).map(([ns, names]) =>
    all ? `  ${ns} (${names.length}): ${names.sort().join(', ')}` : `  ${ns.padEnd(28)} ${names.length}`));
if (!all) console.log('  (--all lists the names; --ns <namespace> shows one namespace in full)');

// --- the reference (--md) -----------------------------------------------------------

if (wantMd) {
  const out = mdOut || path.join(ROOT, 'scripts', 'jambix_debug', 'FOREVER_API.md');
  const esc = (s) => String(s == null ? '' : s).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
  const code = (s) => (s ? `\`${String(s).replace(/`/g, "'")}\`` : '');
  const md = [];
  md.push('# Forever API, as recorded');
  md.push('');
  md.push(`Generated by \`node tools/jcheck/recorder_report.js --md\` from \`${path.relative(ROOT, file).replace(/\\/g, '/')}\`. ` +
    'Do not edit by hand: play a session on Forever and generate it again.');
  md.push('');
  md.push(`Client ${esc(c.version)} (${esc(c.exact)}), JCore ${esc(c.jcore)}, ${sess.count || 1} session(s). ` +
    `Triggers from ${esc(rec.triggers_from)}.`);
  md.push('');
  md.push('**Kind**: read, action, loader (the loader\'s own settings), file, net, paint, clock. ' +
    '**Status**: answers, always empty, only false, returns nothing, raises, never called. ' +
    '**Triggered by**: the phase (update, render, event NAME, recorder, outside JCore) and the call site. ' +
    '**Did**: for an action, the events that followed its calls, as a share of the calls. ' +
    '**.api says**: the stub\'s first sentence, when there is a stub.');
  md.push('');
  md.push('## Coverage');
  md.push('');
  md.push('| Namespace | Exposed | Called | Not in .api |');
  md.push('|---|---:|---:|---:|');
  for (const [ns, r] of [...coverage].sort((a, b) => a[0].localeCompare(b[0]))) {
    md.push(`| ${esc(ns)} | ${r.exposed} | ${r.called} | ${r.undocumented} |`);
  }
  const nsList = ['core', ...Object.keys(surface.namespaces || {}).sort()];
  for (const ns of nsList) {
    const names = ns === 'core' ? (surface.core || []).filter((n) => !skippedFns.has(n)) : surface.namespaces[ns];
    if (!names || !names.length) continue;
    const called = names.filter((n) => functions[ns === 'core' ? n : `${ns}.${n}`]).length;
    md.push('');
    md.push(`## ${ns === 'core' ? 'core (top level)' : ns} (${names.length} functions, ${called} called)`);
    md.push('');
    md.push('| Function | Kind | Status | Example | Triggered by | Did | .api says |');
    md.push('|---|---|---|---|---|---|---|');
    for (const n of [...names].sort()) {
      const key = ns === 'core' ? n : `${ns}.${n}`;
      const r = functions[key];
      const info = coreApi.get(key);
      const said = info ? summary(info.doc) : '**not in .api**';
      if (!r) {
        md.push(`| ${code(n)} | ${kindFor(key, 'full', false)} | never called | | | | ${esc(said)} |`);
        continue;
      }
      md.push(`| ${code(n)} | ${r.kind} | ${esc(r.status)}${r.origin === 'Lua' ? ' (Lua)' : ''} | ${code(example(r))} | ` +
        `${esc(triggers(r, 2))} | ${esc(effects(r, 3))} | ${esc(said)} |`);
    }
  }
  if (methodSurface.size) {
    const native = [...methodSurface].filter((m) => !(methods[m] && methods[m].origin === 'Lua')).sort();
    const helpers = [...methodSurface].filter((m) => methods[m] && methods[m].origin === 'Lua').sort();
    md.push('');
    md.push(`## game_object methods (${native.length})`);
    md.push('');
    md.push('| Method | Status | Example | Triggered by | .api says |');
    md.push('|---|---|---|---|---|');
    for (const m of native) {
      const r = methods[m];
      const info = objectApi.get(m);
      const said = info ? summary(info.doc) : '**not in .api**';
      md.push(r
        ? `| ${code(m)} | ${esc(r.status)} | ${code(example(r))} | ${esc(triggers(r, 2))} | ${esc(said)} |`
        : `| ${code(m)} | never called | | | ${esc(said)} |`);
    }
    if (helpers.length) {
      md.push('');
      md.push(`Defined by other scripts on top of the client (origin Lua, ${helpers.length}): ` +
        helpers.map((m) => code(m)).join(', '));
    }
  }
  md.push('');
  md.push(`## Events (${Object.keys(events).length})`);
  md.push('');
  md.push('| Event | Count | Layout | Example | After actions | Unprompted |');
  md.push('|---|---:|---|---|---|---:|');
  for (const [name, e] of Object.entries(events).sort((a, b) => b[1].count - a[1].count)) {
    const l = (e.layouts || [])[0] || {};
    const layout = l.kinds != null ? l.kinds : (l.size != null ? `${l.size} args` : '');
    md.push(`| ${code(name)} | ${e.count} | ${esc(layout)} | ${code(l.example)} | ` +
      `${esc(byCount(e.after).map(([a, n]) => `${a} ${n}`).join(', '))} | ${e.unprompted === undefined ? '' : e.unprompted} |`);
  }
  md.push('');
  fs.writeFileSync(out, md.join('\n'));
  console.log('');
  console.log(`REFERENCE written to ${path.relative(ROOT, out)}`);
}

// --- the catalog (jcore.catalog.json, beside the recording) -------------------------

const catalogFile = path.join(path.dirname(file), 'jcore.catalog.json');
if (fs.existsSync(catalogFile)) {
  const cat = JSON.parse(fs.readFileSync(catalogFile, 'utf8'));
  const entries = (o) => Object.entries(o || {});
  console.log('');
  console.log(`CATALOG: ${path.relative(ROOT, catalogFile)}`);

  const spells = entries(cat.spells);
  const bySource = {};
  for (const [, s] of spells) for (const src of Object.keys(s.from || {})) bySource[src] = (bySource[src] || 0) + 1;
  section(`SPELLS (by source: ${Object.entries(bySource).map(([k, v]) => `${k} ${v}`).join(', ') || 'none'})`,
    spells.sort((a, b) => (b[1].seen || 0) - (a[1].seen || 0)).map(([id, s]) =>
      `  ${id.padStart(8)}  ${(s.name || '?').padEnd(28)} seen ${s.seen || 0}  from ${Object.keys(s.from || {}).join('/')}` +
      (s.cast_time !== undefined ? `  cast ${JSON.stringify(s.cast_time)}` : '') +
      (s.npcs ? `  npcs ${Object.keys(s.npcs).join(',')}` : '')));

  section('NPCS', entries(cat.npcs).sort((a, b) => (b[1].seen || 0) - (a[1].seen || 0)).map(([id, n]) =>
    `  ${id.padStart(8)}  ${Object.keys(n.names || {}).join(' / ') || '(no name learned)'}  type ${n.creature_type}` +
    `  level ${n.level_min}-${n.level_max}  seen ${n.seen || 0}` +
    (n.spells ? `  casts ${Object.keys(n.spells).join(',')}` : '')));

  section('QUESTS', entries(cat.quests).map(([id, q]) =>
    `  ${id.padStart(8)}  on_quest=${q.on_quest} completed=${q.flagged_completed}` +
    (q.accepted_at ? '  accepted' : '') + (q.turned_in_at ? `  turned in (xp ${q.xp}, money ${q.money})` : '')));

  section('QUEST OBJECTIVES (from UI_INFO_MESSAGE)', entries(cat.objectives).map(([what, o]) =>
    `  ${what}  ${o.have !== undefined ? `${o.have}/${o.need}` : ''}  (${o.tag})`));

  const t = cat.talents || {};
  const nodes = Object.keys(t.nodes || {}).length;
  console.log('');
  console.log(`TALENTS: classic tabs ${t.classic ? t.classic.tabs : '?'}, trait trees ${JSON.stringify(t.tree_ids || [])}, ` +
    `${nodes} nodes read, active ${Array.isArray(t.active) ? t.active.length : Object.keys(t.active || {}).length}, ` +
    `unspent ${JSON.stringify(t.unspent)}`);
  console.log(`ITEMS: ${Object.keys(cat.items || {}).length}   MAPS: ${entries(cat.maps).map(([id, m]) => `${id} ${m.name}`).join(', ')}`);
  const gossip = cat.gossip || [];
  if (gossip.length) {
    const g = gossip[gossip.length - 1];
    console.log(`QUEST WINDOWS: ${gossip.length} distinct; last ${g.event}, npc ${g.npc || '?'}` +
      `${g.seen ? `, seen ${g.seen}x` : ''}, available ${JSON.stringify(g.available)}, active ${JSON.stringify(g.active)}`);
  }
  const qlog = (cat.probes || {}).quest_log;
  if (qlog) console.log(`CLASSIC QUEST LOG: ${qlog.count} entries`);

  // The seven features not available on Forever yet: what each candidate read
  // answered, and the ground truth beside it.
  const feats = cat.features || {};
  const hist = (reads) => entries(reads).map(([m, h]) =>
    `      ${m.padEnd(26)} ${entries(h).sort((a, b) => b[1] - a[1]).map(([v, n]) => `${v} x${n}`).join(', ')}`);
  const featureRows = [];
  const add = (title, f, extra) => {
    if (!f) return;
    featureRows.push(`  ${title}`);
    for (const line of hist(f.reads)) featureRows.push(line);
    for (const line of extra(f)) featureRows.push(line);
  };
  add('LOOTABLE CORPSES (reads on corpses; ground truth: what was looted)', feats.loot, (f) =>
    (f.opened || []).slice(-6).map((o) => `      looted ${o.npc || '?'}: ${o.items} item(s) ` +
      `${(o.contents || []).map((x) => x.name).join(', ')} | before ${JSON.stringify(o.reads_before)}` +
      ` | after ${JSON.stringify(o.reads_after)}`));
  add('QUEST TAGS (reads on npcs)', feats.quest, () =>
    entries(cat.npcs).filter(([, n]) => n.quest_unit !== undefined).slice(0, 12).map(([id, n]) =>
      `      npc ${id} ${Object.keys(n.names || {}).join('/') || ''}: is_quest_unit ${n.quest_unit}, npc_flags ${n.npc_flags}`));
  add('GATHERING NODES (reads on game objects; ground truth: what was gathered)', feats.nodes, (f) =>
    entries(f.objects).slice(0, 15).map(([k, o]) => `      object "${k}" x${o.seen}: ${JSON.stringify(o.reads)}`)
      .concat((f.gathered || []).slice(-6).map((g) => `      gathered with ${g.spell_name}: ${JSON.stringify(g.reads)}`)));
  add('RAID MARKERS (index answers; ground truth: changes)', feats.markers, (f) =>
    (f.changes || []).slice(-8).map((x) => `      ${x.guid} (npc ${x.npc}): ${x.from} -> ${x.to}`));
  add('TAPPED GREY (ground truth: mobs fighting someone outside your group)', feats.tapped, (f) =>
    (f.fighting_others || []).slice(-6).map((o) => `      npc ${o.npc}: is_tap_denied ${o.is_tap_denied}, ` +
      `state_flags ${o.state_flags}, npc_flags ${o.npc_flags}`));
  add('RARE / ELITE', feats.rank, () =>
    entries(cat.npcs).filter(([, n]) => n.health_per_level).sort((a, b) => b[1].health_per_level - a[1].health_per_level)
      .slice(0, 8).map(([id, n]) => `      npc ${id} ${Object.keys(n.names || {}).join('/')}: ` +
        `${n.health_per_level} hp/level, classification ${n.classification}, boss ${n.is_boss}`));
  if (featureRows.length) section('NOT AVAILABLE ON FOREVER YET: what the recorder has', featureRows);
}

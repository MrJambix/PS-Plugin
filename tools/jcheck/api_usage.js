#!/usr/bin/env node
// api_usage.js -- what our plugins touch of the loader's API, and what of it
// scripts/.api does not document.
//
// The user, 2026-10-12: "Check all our rotation and ESP matches with .API if
// anything is outside the .api we need to identify it".
//
// Two sources, because neither sees everything:
//   STATIC   the plugins' source: every core.* path (through local aliases,
//            `local sb = core.spell_book`, too), every loader library
//            (require "common/...") and the members used from it, and every
//            method called on an object (`unit:get_x()`, `pcall(u.get_x, u)`,
//            `u.get_x(u)`), sorted against the stubs and our own declarations.
//   RUNTIME  scripts_data/jcore/jcore.recorder.json: what the recorder saw
//            called in game, with the call sites, split into ours and the
//            loader's own code. This sees calls the source only makes by a
//            name held in a string.
//
//   node tools/jcheck/api_usage.js                 jcore + jambix_aio
//   node tools/jcheck/api_usage.js --all           every plugin of ours
//   node tools/jcheck/api_usage.js --md <file>     also write the report as Markdown
//
// Exit code 0 always: this is an inventory, not a gate.

'use strict';

const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

const ROOT = path.resolve(__dirname, '..', '..');
const SCRIPTS = path.join(ROOT, 'scripts');
const API_DIR = path.join(SCRIPTS, '.api');
const RECORDING = path.join(ROOT, 'scripts_data', 'jcore', 'jcore.recorder.json');

const args = process.argv.slice(2);
const ALL = args.includes('--all');
const mdAt = args.indexOf('--md');
const MD_FILE = mdAt >= 0 ? args[mdAt + 1] : null;

const OURS = ['jcore', 'jambix_aio', 'jambix_market', 'jambix_worldclick', 'jambix_debug', 'jambix_postprobe']
  .filter((p) => fs.existsSync(path.join(SCRIPTS, p)));
const TARGETS = ALL ? OURS : ['jcore', 'jambix_aio'];

const posix = (p) => p.split(path.sep).join('/');

function luaFiles(dir) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...luaFiles(full));
    else if (e.name.endsWith('.lua')) out.push(full);
  }
  return out;
}

const PARSE = { luaVersion: 'LuaJIT', locations: true, scope: false, comments: false };
function parse(file) {
  const src = fs.readFileSync(file, 'utf8');
  try { return luaparse.parse(src, PARSE); } catch (e) {
    try { return luaparse.parse(src, Object.assign({}, PARSE, { luaVersion: '5.1' })); } catch (e2) { return null; }
  }
}

function walk(node, visit, parent) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) { for (const n of node) walk(n, visit, parent); return; }
  if (node.type) visit(node, parent);
  for (const key of Object.keys(node)) {
    if (key === 'loc' || key === 'range') continue;
    const v = node[key];
    if (v && typeof v === 'object') walk(v, visit, node.type ? node : parent);
  }
}

const strOf = (n) => (n && n.type === 'StringLiteral' && typeof n.raw === 'string') ? n.raw.slice(1, -1) : null;

// --- the documented surface ------------------------------------------------------

const api = {
  corePaths: new Set(),
  classes: new Map(),        // class -> Map(member -> Set(api files))
  fileMembers: new Map(),    // "common/utility/spell_helper" -> Set(members)
  files: 0,
};

function addCorePath(dotted) {
  const parts = dotted.split('.');
  for (let i = 1; i <= parts.length; i++) api.corePaths.add(parts.slice(0, i).join('.'));
}

function addMember(cls, name, rel) {
  if (!cls) return;
  if (!api.classes.has(cls)) api.classes.set(cls, new Map());
  const m = api.classes.get(cls);
  if (!m.has(name)) m.set(name, new Set());
  m.get(name).add(rel);
}

// core tables typed by a class (`---@type profession` over `core.profession = {}`,
// or a class named like the table): that class's fields are core paths too.
const coreTyped = [];   // [core path, class]

for (const file of luaFiles(API_DIR)) {
  api.files++;
  const rel = posix(path.relative(API_DIR, file));
  const mod = rel.replace(/\.lua$/, '');
  const members = new Set();
  api.fileMembers.set(mod, members);
  let cls = null;
  let typed = null;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    let m;
    if ((m = line.match(/^\s*---@type\s+([\w.]+)/))) { typed = m[1]; continue; }
    if ((m = line.match(/^\s*(core(?:\.\w+)+)\s*=/))) {
      addCorePath(m[1]);
      coreTyped.push([m[1], typed || m[1].split('.').pop()]);
      if (m[1].split('.').length > 1) coreTyped.push([m[1], m[1]]);
      typed = null;
      continue;
    }
    if (!/^\s*---/.test(line) && line.trim() !== '') typed = null;
    if ((m = line.match(/^\s*---@class\s+([\w.]+)/))) { cls = m[1]; continue; }
    if ((m = line.match(/^\s*---@field\s+([A-Za-z_]\w*)/))) { addMember(cls, m[1], rel); members.add(m[1]); continue; }
    if ((m = line.match(/^\s*function\s+([\w.:]+)\s*\(/))) {
      const full = m[1];
      const cut = Math.max(full.lastIndexOf('.'), full.lastIndexOf(':'));
      if (cut > 0) {
        const owner = full.slice(0, cut);
        const name = full.slice(cut + 1);
        addMember(owner, name, rel);
        members.add(name);
        if (owner === 'core' || owner.startsWith('core.')) addCorePath(owner + '.' + name);
      }
      continue;
    }
  }
}
for (const [corePath, cls] of coreTyped) {
  const members = api.classes.get(cls);
  if (members) for (const name of members.keys()) addCorePath(corePath + '.' + name);
}
for (const [cls, members] of api.classes) {
  if (cls === 'core' || cls.startsWith('core.')) for (const name of members.keys()) addCorePath(cls + '.' + name);
}

const goAll = api.classes.get('game_object') || new Map();
const goNative = new Set([...goAll].filter(([, files]) => files.has('game_object.lua')).map(([n]) => n));
const goIzi = new Set([...goAll].filter(([, files]) => !files.has('game_object.lua')).map(([n]) => n));
const otherApiNames = new Map();   // member name -> classes (not game_object)
for (const [cls, members] of api.classes) {
  if (cls === 'game_object') continue;
  for (const name of members.keys()) {
    if (!otherApiNames.has(name)) otherApiNames.set(name, new Set());
    otherApiNames.get(name).add(cls);
  }
}

// --- our own declarations (a method of ours is not the loader's) -------------------

const STDLIB = new Set(['byte', 'char', 'dump', 'find', 'format', 'gmatch', 'gsub', 'len', 'lower', 'match', 'rep',
  'reverse', 'sub', 'upper', 'close', 'flush', 'lines', 'read', 'seek', 'setvbuf', 'write']);

const ourNames = new Set();
const parsed = new Map();
for (const plugin of OURS) {
  for (const file of luaFiles(path.join(SCRIPTS, plugin))) {
    const ast = parse(file);
    if (!ast) continue;
    parsed.set(file, ast);
    walk(ast, (n) => {
      if (n.type === 'FunctionDeclaration' && n.identifier && n.identifier.type === 'MemberExpression') {
        ourNames.add(n.identifier.identifier.name);
      } else if (n.type === 'AssignmentStatement') {
        for (const v of n.variables || []) if (v.type === 'MemberExpression') ourNames.add(v.identifier.name);
      } else if (n.type === 'TableKeyString' && n.key) {
        ourNames.add(n.key.name);
      }
    });
  }
}

// --- where a site is ----------------------------------------------------------------

function area(rel) {
  if (rel.startsWith('jcore/')) return 'JCore';
  if (!rel.startsWith('jambix_aio/')) return rel.split('/')[0];
  if (/\/esp\/|worldlayer|elements|combatrings|xpbar|rares|skinning|curtain|beacon|aurora|marks|\/draw/.test(rel)) return 'ESP';
  if (/rotation|\/classes\/|\/react\/|burst|\/pet\.|kite|pull|spellbook|talents|catalog|tactics|aspects|interrupt|pvphunter|stance/.test(rel)) return 'Rotation';
  return 'AIO';
}

// --- the static scan ------------------------------------------------------------------

// Helpers that call their first argument with the rest: pcall(u.get_x, u).
const PROTECTED = new Set(['pcall', 'xpcall', 'try', 'try_bool', 'call', 'safe', 'guard', 'ask', 'probe', 'read']);

const used = {
  core: new Map(),      // path -> [{ site, how }]
  dynamic: [],          // core[...] with a variable
  modules: new Map(),   // module path -> { sites: [], members: Map(name -> sites) }
  methods: new Map(),   // method name -> [sites]
};
const push = (map, key, val) => { if (!map.has(key)) map.set(key, []); map.get(key).push(val); };

function chainOf(node) {
  // -> { root, parts, dynamic } for a.b.c / a["b"] / a:b; null for anything else.
  const parts = [];
  let cur = node;
  let dynamic = false;
  while (cur && (cur.type === 'MemberExpression' || cur.type === 'IndexExpression')) {
    if (cur.type === 'MemberExpression') parts.unshift(cur.identifier.name);
    else {
      const s = strOf(cur.index);
      if (s && /^[A-Za-z_]\w*$/.test(s)) parts.unshift(s);
      else { dynamic = true; parts.length = 0; }
    }
    cur = cur.base;
  }
  if (!cur || cur.type !== 'Identifier') return null;
  return { root: cur.name, parts, dynamic };
}

for (const plugin of TARGETS) {
  for (const file of luaFiles(path.join(SCRIPTS, plugin))) {
    const ast = parsed.get(file);
    if (!ast) continue;
    const rel = posix(path.relative(SCRIPTS, file)).replace(/\.lua$/, '');
    const coreAlias = new Map([['core', 'core']]);   // local name -> core path
    const modAlias = new Map();                        // local name -> "common/..."

    // Pass 1: aliases. File-flat, so a name bound to two different things in
    // the file (`local g = core.graphics` here, `local g = inner.group` there)
    // is no alias at all: guessing which one a use means would invent paths.
    const bindings = new Map();   // name -> Set of what it was bound to ("core.x", "mod:common/x", "other")
    const bind = (name, what) => {
      if (!bindings.has(name)) bindings.set(name, new Set());
      bindings.get(name).add(what);
    };
    walk(ast, (n) => {
      if (n.type !== 'LocalStatement' && n.type !== 'AssignmentStatement') return;
      const vars = n.variables || [];
      const init = n.init || [];
      // local ok, mod = pcall(require, "common/x")
      if (init.length === 1 && init[0].type === 'CallExpression' && init[0].base.type === 'Identifier'
          && init[0].base.name === 'pcall' && init[0].arguments.length >= 2
          && init[0].arguments[0].type === 'Identifier' && init[0].arguments[0].name === 'require') {
        const p = strOf(init[0].arguments[1]);
        vars.forEach((v, i) => {
          if (v.type === 'Identifier') bind(v.name, i === 1 && p && p.startsWith('common/') ? 'mod:' + p : 'other');
        });
        return;
      }
      vars.forEach((v, i) => {
        if (v.type !== 'Identifier') return;
        const e = init[i];
        if (!e) { if (n.type === 'AssignmentStatement') bind(v.name, 'other'); return; }
        if (e.type === 'CallExpression' && e.base.type === 'Identifier' && e.base.name === 'require') {
          const p = strOf(e.arguments[0]);
          bind(v.name, p && p.startsWith('common/') ? 'mod:' + p : 'other');
          return;
        }
        const c = chainOf(e);
        if (c && !c.dynamic) bind(v.name, 'ref:' + [c.root, ...c.parts].join('.'));
        else bind(v.name, 'other');
      });
    });
    // Resolve, following one name to another (unit_helper = mod), to a fixed point.
    for (let round = 0; round < 4; round++) {
      for (const [name, set] of bindings) {
        if (set.size !== 1 || name === 'core') continue;
        const what = [...set][0];
        if (what.startsWith('mod:')) { modAlias.set(name, what.slice(4)); continue; }
        if (!what.startsWith('ref:')) continue;
        const parts = what.slice(4).split('.');
        const root = parts.shift();
        if (coreAlias.has(root)) coreAlias.set(name, [coreAlias.get(root), ...parts].join('.'));
        else if (modAlias.has(root) && parts.length === 0) modAlias.set(name, modAlias.get(root));
      }
    }

    // Lookup helpers: a local function that indexes core by its first
    // parameter (`core[namespace]`) and the result by its second, called as
    // api("game_ui", "get_gossip_options"). Their two-string calls are paths.
    const helpers = new Set();
    walk(ast, (n) => {
      if (n.type !== 'FunctionDeclaration' || !n.identifier || n.identifier.type !== 'Identifier') return;
      const p0 = n.parameters && n.parameters[0] && n.parameters[0].name;
      if (!p0) return;
      let indexes = false;
      walk(n.body, (m) => {
        if (m.type === 'IndexExpression' && m.base.type === 'Identifier' && coreAlias.get(m.base.name) === 'core'
            && m.index.type === 'Identifier' && m.index.name === p0) indexes = true;
      });
      if (indexes) helpers.add(n.identifier.name);
    });
    // The bridge's list of top-level natives it mirrors by name.
    walk(ast, (n) => {
      if (n.type !== 'LocalStatement') return;
      (n.variables || []).forEach((v, i) => {
        const t = n.init && n.init[i];
        if (v.name !== 'TOP_LEVEL' || !t || t.type !== 'TableConstructorExpression') return;
        for (const f of t.fields) {
          const s = f.type === 'TableValue' && strOf(f.value);
          if (s) push(used.core, 'core.' + s, { site: `${rel}:${f.loc.start.line}`, how: 'by name' });
        }
      });
    });

    // Pass 2: uses.
    const longest = new Map();   // "line:col" -> { path, how }
    walk(ast, (n, parent) => {
      if (n.type === 'CallExpression' && n.base.type === 'Identifier' && helpers.has(n.base.name)) {
        const ns = strOf(n.arguments[0]);
        const fn = strOf(n.arguments[1]);
        if (ns && fn) push(used.core, `core.${ns}.${fn}`, { site: `${rel}:${n.loc.start.line}`, how: 'by name' });
        else if (ns && n.arguments.length === 1) push(used.core, `core.${ns}`, { site: `${rel}:${n.loc.start.line}`, how: 'by name' });
      }
      if (n.type === 'MemberExpression' || n.type === 'IndexExpression') {
        const c = chainOf(n);
        if (!c) return;
        const site = `${rel}:${n.loc.start.line}`;
        const key = `${n.loc.start.line}:${n.loc.start.column}`;
        if (coreAlias.has(c.root)) {
          if (c.dynamic) { used.dynamic.push(site); return; }
          const full = [coreAlias.get(c.root), ...c.parts].join('.');
          const how = parent && parent.type === 'CallExpression' && parent.base === n ? 'call' : 'ref';
          const prev = longest.get(key);
          if (!prev || prev.path.length < full.length) longest.set(key, { path: full, how, site });
        } else if (modAlias.has(c.root) && c.parts.length > 0) {
          const p = modAlias.get(c.root);
          if (!used.modules.has(p)) used.modules.set(p, { sites: [], members: new Map() });
          push(used.modules.get(p).members, c.parts[0], site);
        }
      }
      if (n.type === 'CallExpression') {
        const site = `${rel}:${n.loc.start.line}`;
        const b = n.base;
        // x:name(...)
        if (b.type === 'MemberExpression' && b.indexer === ':') {
          const c = chainOf(b.base);
          const root = c ? c.root : null;
          if (!(root && (coreAlias.has(root) || modAlias.has(root)))) push(used.methods, b.identifier.name, site);
        }
        // x.name(x, ...)
        if (b.type === 'MemberExpression' && b.indexer === '.' && b.base.type === 'Identifier'
            && n.arguments[0] && n.arguments[0].type === 'Identifier' && n.arguments[0].name === b.base.name
            && !coreAlias.has(b.base.name) && !modAlias.has(b.base.name)) {
          push(used.methods, b.identifier.name, site);
        }
        // pcall(x.name, x, ...) / try(x.name, x): only through a protected-call helper
        const a0 = n.arguments[0];
        const a1 = n.arguments[1];
        const callee = b.type === 'Identifier' ? b.name : (b.type === 'MemberExpression' ? b.identifier.name : '');
        if (PROTECTED.has(callee)
            && a0 && a1 && a0.type === 'MemberExpression' && a0.indexer === '.' && a0.base.type === 'Identifier'
            && a1.type === 'Identifier' && a1.name === a0.base.name
            && !coreAlias.has(a0.base.name) && !modAlias.has(a0.base.name)) {
          push(used.methods, a0.identifier.name, site);
        }
        // require("common/x") used inline
        if (b.type === 'Identifier' && b.name === 'require') {
          const p = strOf(n.arguments[0]);
          if (p && p.startsWith('common/')) {
            if (!used.modules.has(p)) used.modules.set(p, { sites: [], members: new Map() });
            used.modules.get(p).sites.push(site);
          }
        }
      }
    });
    for (const { path: p, how, site } of longest.values()) push(used.core, p, { site, how });
    for (const [name, p] of modAlias) {
      if (!used.modules.has(p)) used.modules.set(p, { sites: [], members: new Map() });
      used.modules.get(p).sites.push(`${rel} (as ${name})`);
    }
  }
}

// --- the runtime side ------------------------------------------------------------------

let rec = null;
try { rec = JSON.parse(fs.readFileSync(RECORDING, 'utf8')); } catch (e) { rec = null; }

const OUR_SITE = /\b(jcore|jambix_[a-z]+)\//;
function triggersOf(entry) {
  const t = Object.entries((entry && entry.triggers) || {}).sort((a, b) => b[1] - a[1]);
  const ours = t.filter(([k]) => OUR_SITE.test(k));
  const theirs = t.filter(([k]) => !OUR_SITE.test(k));
  return { ours, theirs };
}

// --- the report --------------------------------------------------------------------------

const out = [];
const say = (s = '') => out.push(s);
const uniq = (list) => [...new Set(list)];
const sitesText = (sites, n = 4) => {
  const u = uniq(sites);
  const shown = u.slice(0, n).map((s) => `${s} [${area(s)}]`).join('; ');
  return u.length > n ? `${shown}; +${u.length - n} more` : shown;
};

say(`# API usage against scripts/.api`);
say();
say(`Scanned: ${TARGETS.join(', ')}. The .api: ${api.files} files, ${api.corePaths.size} core paths, ` +
  `${goNative.size} native game_object methods (+${goIzi.size} izi_sdk Lua extensions).`);
say();

// core.* paths
const corePaths = [...used.core.keys()].sort();
const coreMissing = corePaths.filter((p) => !api.corePaths.has(p));
say(`## Static: core.* paths`);
say();
const byName = corePaths.filter((p) => used.core.get(p).some((u) => u.how === 'by name')).length;
say(`${corePaths.length} distinct paths used (${byName} of them reached by name through a lookup helper), ` +
  `${corePaths.length - coreMissing.length} in .api, **${coreMissing.length} not**.`);
say();
for (const p of coreMissing) {
  const uses = used.core.get(p);
  const calls = uses.filter((u) => u.how === 'call').length;
  say(`- \`${p}\` -- ${uses.length} site(s), ${calls} direct call(s): ${sitesText(uses.map((u) => u.site))}`);
}
if (used.dynamic.length) {
  say();
  say(`core[...] by a name held in a variable (not checkable here; the runtime side covers them): ${sitesText(used.dynamic, 40)}`);
}
say();

// libraries
say(`## Static: loader libraries (require "common/...")`);
say();
for (const [p, u] of [...used.modules].sort()) {
  const doc = api.fileMembers.get(p);
  const members = [...u.members.keys()].sort();
  if (!doc) {
    say(`- \`${p}\` -- **no .api file**; members used: ${members.join(', ') || '(none seen)'}; ${sitesText(u.sites, 3)}`);
    continue;
  }
  const missing = members.filter((m) => !doc.has(m));
  say(`- \`${p}\` -- ${members.length} member(s) used${missing.length ? `, **not in .api: ${missing.join(', ')}**` : ', all in .api'}`);
  for (const m of missing) say(`  - \`${m}\`: ${sitesText(u.members.get(m), 3)}`);
}
say();

// methods
const methodNames = [...used.methods.keys()].sort();
const buckets = { native: [], izi: [], other: [], ours: [], std: [], missing: [] };
for (const name of methodNames) {
  if (goNative.has(name)) buckets.native.push(name);
  else if (goIzi.has(name)) buckets.izi.push(name);
  else if (otherApiNames.has(name)) buckets.other.push(name);
  else if (ourNames.has(name)) buckets.ours.push(name);
  else if (STDLIB.has(name)) buckets.std.push(name);
  else buckets.missing.push(name);
}
say(`## Static: methods called on objects`);
say();
say(`${methodNames.length} distinct names: ${buckets.native.length} native game_object methods in .api, ` +
  `${buckets.other.length} other .api classes (menu, vec3, color...), ${buckets.ours.length} our own, ` +
  `${buckets.izi.length} izi_sdk-only, **${buckets.missing.length} found nowhere**.`);
say();
if (buckets.missing.length) {
  say(`Found nowhere (not in .api, not declared by us): candidates for natives outside the .api.`);
  for (const name of buckets.missing) say(`- \`${name}\`: ${sitesText(used.methods.get(name))}`);
  say();
}
if (buckets.izi.length) {
  say(`izi_sdk Lua extensions (exist only while izi_sdk is loaded):`);
  for (const name of buckets.izi) say(`- \`${name}\`: ${sitesText(used.methods.get(name))}`);
  say();
}

// runtime
say(`## Runtime: what the recorder saw called in game`);
say();
if (!rec) {
  say(`No recording at ${posix(path.relative(ROOT, RECORDING))}.`);
} else {
  const sessions = rec.sessions && rec.sessions.count;
  const fnKeys = Object.keys(rec.functions || {}).sort();
  const fnMissing = fnKeys.filter((k) => !api.corePaths.has('core.' + k));
  const mKeys = Object.keys(rec.methods || {}).sort();
  const mMissing = mKeys.filter((k) => !goNative.has(k));
  say(`${sessions} sessions. ${fnKeys.length} core functions called, **${fnMissing.length} not in .api**; ` +
    `${mKeys.length} game_object methods called, **${mMissing.length} not in .api**.`);
  say();
  // The recording is history: a call of ours that the source no longer
  // makes (removed since) is said to be gone, not current.
  const line = (label, entry, stillInSource) => {
    const { ours, theirs } = triggersOf(entry);
    const sites = ours.slice(0, 4).map(([k, n]) => `${k} x${n}`).join('; ') + (ours.length > 4 ? `; +${ours.length - 4} more` : '');
    const who = ours.length
      ? (stillInSource ? `**OURS, still in the source**: ${sites}` : `ours BEFORE, gone from the source now: ${sites}`)
      : `only the loader's own code${theirs.length ? `: ${theirs.slice(0, 2).map(([k, n]) => `${k} x${n}`).join('; ')}` : ''}`;
    const errs = entry.errors ? `, raised ${entry.errors}x` : '';
    say(`- \`${label}\` x${entry.calls || 0}${errs} (${entry.status || '?'}) -- ${who}`);
  };
  if (fnMissing.length) {
    say(`Core functions:`);
    for (const k of fnMissing) line('core.' + k, rec.functions[k], used.core.has('core.' + k));
    say();
  }
  if (mMissing.length) {
    say(`game_object methods:`);
    for (const k of mMissing) line('game_object:' + k, rec.methods[k], used.methods.has(k));
    say();
  }
}

const text = out.join('\n');
console.log(text);
if (MD_FILE) {
  fs.writeFileSync(MD_FILE, text + '\n');
  console.log(`\nwrote ${MD_FILE}`);
}

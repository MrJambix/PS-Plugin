#!/usr/bin/env node
'use strict';

// jcheck -- static checker for the JCore Lua runtime.
//
// WHY THIS EXISTS
// There is no Lua interpreter on this machine and the only thing that loads
// these files is the game itself. That makes the edit-test loop "alt-tab into
// WoW and hope", and it means a typo in a file that runs once at boot takes the
// whole core down with an error nobody sees until the next reload.
//
// So this parses the code properly -- a real Lua parser, not a regex -- and
// then runs the checks that are specific to how JCore is wired. Four passes:
//
//   1. SYNTAX    Does every file parse at all?
//   2. CORE API  Does every core.* call exist in scripts/.api?
//   3. WIRING    Is every rt.* read something main.lua actually builds, and is
//                it built BEFORE the module that reads it at factory scope?
//   4. GLOBALS   Is every global read a real one, or a typo?
//
// Pass 3 is the one that matters most. Modules are factories that take their
// dependencies as upvalues at build time, so reading rt.cache before the line
// that builds it does not degrade anything -- it captures nil and the runtime
// never starts. That failure has happened here before.
//
// Usage:  node check.js [path-to-scripts] [--quiet] [--no-globals]

const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

// --- locations --------------------------------------------------------------

const args = process.argv.slice(2);
const flags = new Set(args.filter((a) => a.startsWith('--')));
const positional = args.filter((a) => !a.startsWith('--'));

// Default to the scripts/ directory two levels up from tools/jcheck.
const SCRIPTS = path.resolve(positional[0] || path.join(__dirname, '..', '..', 'scripts'));
const TARGET = path.join(SCRIPTS, 'jcore');
const API_DIR = path.join(SCRIPTS, '.api');

// --- findings ---------------------------------------------------------------

const findings = [];

function report(level, file, line, column, message) {
  findings.push({ level, file, line: line || 0, column: column || 0, message });
}

const relative = (file) => path.relative(SCRIPTS, file).replace(/\\/g, '/');

// --- parsing ----------------------------------------------------------------

// LuaJIT is what the client runs, so parse as LuaJIT where the parser supports
// it. Falling back rather than failing keeps this working if the dependency
// changes what it accepts.
const PARSE_OPTIONS = {
  luaVersion: 'LuaJIT',
  locations: true,
  scope: true,
  comments: false,
};

function parseFile(file) {
  const source = fs.readFileSync(file, 'utf8');
  try {
    return { ast: luaparse.parse(source, PARSE_OPTIONS), source };
  } catch (first) {
    try {
      return {
        ast: luaparse.parse(source, Object.assign({}, PARSE_OPTIONS, { luaVersion: '5.1' })),
        source,
      };
    } catch (err) {
      report('error', file, err.line, err.column, `syntax: ${err.message.replace(/^\[[^\]]*\]\s*/, '')}`);
      return null;
    }
  }
}

// --- AST walking ------------------------------------------------------------

// `depth` counts enclosing function bodies. A module file is
// `return function(rt) ... end`, so its factory body is depth 1: anything read
// there is read at BUILD time. Anything at depth 2 or deeper runs later, when
// the whole runtime exists, and is therefore safe whatever the build order.
function walk(node, visit, depth = 0) {
  if (!node || typeof node !== 'object') return;

  if (Array.isArray(node)) {
    for (const child of node) walk(child, visit, depth);
    return;
  }

  if (typeof node.type === 'string') {
    visit(node, depth);
    const inner = node.type === 'FunctionDeclaration' ? depth + 1 : depth;
    for (const key of Object.keys(node)) {
      if (key === 'type' || key === 'loc' || key === 'range') continue;
      walk(node[key], visit, inner);
    }
    return;
  }

  for (const key of Object.keys(node)) walk(node[key], visit, depth);
}

// Turns a chain of MemberExpressions back into "core.spell_book.get_spell_name".
// Returns null for anything dynamic (core[name]), which cannot be checked
// statically and is not guessed at.
function dottedPath(node) {
  const parts = [];
  let current = node;

  while (current && current.type === 'MemberExpression') {
    if (!current.identifier || current.identifier.type !== 'Identifier') return null;
    parts.unshift(current.identifier.name);
    current = current.base;
  }

  if (current && current.type === 'Identifier') {
    parts.unshift(current.name);
    return parts.join('.');
  }
  return null;
}

const lineOf = (node) => (node.loc ? node.loc.start.line : 0);
const colOf = (node) => (node.loc ? node.loc.start.column + 1 : 0);

// --- pass 2 setup: what does the platform actually expose? ------------------

// Every dotted path declared in the API stubs, plus every prefix of one, so
// that `core.addons` counts as real because `core.addons.bigwigs.is_loaded`
// was declared.
function buildApiIndex() {
  const paths = new Set();

  const add = (dotted) => {
    if (!dotted || !dotted.startsWith('core')) return;
    const parts = dotted.split('.');
    for (let i = 1; i <= parts.length; i++) paths.add(parts.slice(0, i).join('.'));
  };

  const files = fs.existsSync(API_DIR)
    ? fs.readdirSync(API_DIR).filter((f) => f.endsWith('.lua')).map((f) => path.join(API_DIR, f))
    : [];

  for (const file of files) {
    const parsed = parseFile(file);
    if (!parsed) continue;

    walk(parsed.ast, (node) => {
      // function core.x.y() end
      if (node.type === 'FunctionDeclaration' && node.identifier) {
        add(dottedPath(node.identifier));
      }
      // core.x = {}
      if (node.type === 'AssignmentStatement') {
        for (const target of node.variables || []) add(dottedPath(target));
      }
    });
  }

  return paths;
}

// --- pass 3 setup: what does main.lua build, and in what order? -------------

function buildWiringIndex(mainFile) {
  const parsed = parseFile(mainFile);
  if (!parsed) return null;

  // rt.<name> -> line it is assigned on.
  const assigned = new Map();
  // module path passed to build_module/load_module -> line.
  const builtAt = new Map();

  walk(parsed.ast, (node) => {
    if (node.type === 'AssignmentStatement') {
      for (let i = 0; i < (node.variables || []).length; i++) {
        const dotted = dottedPath(node.variables[i]);
        if (!dotted || !dotted.startsWith('rt.')) continue;

        const name = dotted.split('.')[1];
        const line = lineOf(node);
        if (!assigned.has(name)) assigned.set(name, line);

        // rt.units = build_module("services/units")
        const init = (node.init || [])[i];
        if (
          init &&
          init.type === 'CallExpression' &&
          init.base &&
          init.base.type === 'Identifier' &&
          /^(build|load)_module$/.test(init.base.name) &&
          init.arguments &&
          init.arguments[0] &&
          init.arguments[0].type === 'StringLiteral'
        ) {
          const raw = init.arguments[0].raw || '';
          builtAt.set(raw.slice(1, -1), line);
        }
      }
    }

    // The `local rt = { VERSION = ..., started_at = ... }` literal at the top.
    if (node.type === 'LocalStatement') {
      for (let i = 0; i < (node.variables || []).length; i++) {
        if (node.variables[i].name !== 'rt') continue;
        const init = (node.init || [])[i];
        if (!init || init.type !== 'TableConstructorExpression') continue;
        for (const field of init.fields || []) {
          if (field.key && field.key.name) assigned.set(field.key.name, lineOf(node));
        }
      }
    }
  });

  return { assigned, builtAt };
}

// --- pass 5 setup: every member name that exists anywhere -------------------

// A typo detector for method calls. `unit:get_helath()` is as fatal as a bad
// core path and no amount of reading catches it reliably.
//
// The test is deliberately weak: a name counts as real if it appears ANYWHERE
// as a field, key, method or declaration, in the API stubs or in the project
// itself. That will never catch calling a real method on the wrong kind of
// object -- inferring types through this much dynamic Lua is not worth it --
// but it catches the misspelling, with close to no false positives, which is
// the failure that actually happens.
// Methods that live on a standard metatable and are therefore declared
// nowhere in either the stubs or the project. `text:gsub(...)` is real.
const STDLIB_METHODS = [
  'byte', 'char', 'dump', 'find', 'format', 'gmatch', 'gsub', 'len', 'lower',
  'match', 'rep', 'reverse', 'sub', 'upper',
];

function buildMemberNameIndex(files) {
  const names = new Set(STDLIB_METHODS);

  for (const file of files) {
    let source;
    try {
      source = fs.readFileSync(file, 'utf8');
    } catch {
      continue;
    }

    // ---@field <name>, which is how the stubs declare game_object methods.
    for (const match of source.matchAll(/---@field\s+([A-Za-z_][\w]*)/g)) {
      names.add(match[1]);
    }

    const parsed = parseFile(file);
    if (!parsed) continue;

    walk(parsed.ast, (node) => {
      // DECLARATIONS ONLY. Harvesting every member expression instead would
      // make the check self-defeating: the misspelled call is itself a member
      // expression, so it would add its own typo to the set of known names and
      // then find it there.

      // function M.name() / function Store:name()
      if (node.type === 'FunctionDeclaration' && node.identifier &&
          node.identifier.type === 'MemberExpression' && node.identifier.identifier) {
        names.add(node.identifier.identifier.name);
      }

      // M.name = function() ... end, and any other assignment to a field
      if (node.type === 'AssignmentStatement') {
        for (const target of node.variables || []) {
          if (target.type === 'MemberExpression' && target.identifier) {
            names.add(target.identifier.name);
          }
        }
      }

      // { name = ... }
      if (node.type === 'TableKeyString' && node.key) {
        names.add(node.key.name);
      }

      // Names reached dynamically: ns[fn_name], cache:fetch(key, fn) driven by
      // a string, and the mirrored-namespace tables built from string lists.
      if (node.type === 'StringLiteral' && node.raw) {
        const literal = node.raw.slice(1, -1);
        if (/^[A-Za-z_]\w*$/.test(literal)) names.add(literal);
      }
    });
  }

  return names;
}

// --- pass 4 setup: legitimate globals ---------------------------------------

const KNOWN_GLOBALS = new Set([
  // The host.
  'core', '_G', 'require', 'JCore', 'SentinelNavClient', 'menu',
  // Types the runtime injects.
  'vec2', 'vec3', 'color',
  // Lua standard library, 5.1 through 5.4 plus LuaJIT.
  'assert', 'collectgarbage', 'dofile', 'error', 'getfenv', 'getmetatable',
  'ipairs', 'load', 'loadfile', 'loadstring', 'module', 'next', 'pairs',
  'pcall', 'print', 'rawequal', 'rawget', 'rawlen', 'rawset', 'select',
  'setfenv', 'setmetatable', 'tonumber', 'tostring', 'type', 'unpack',
  'xpcall', 'coroutine', 'debug', 'io', 'math', 'os', 'package', 'string',
  'table', 'bit', 'jit', 'utf8', 'arg', '_VERSION',
]);

// --- the run ----------------------------------------------------------------

function luaFilesUnder(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...luaFilesUnder(full));
    else if (entry.name.endsWith('.lua')) out.push(full);
  }
  return out;
}

function main() {
  if (!fs.existsSync(TARGET)) {
    console.error(`jcheck: no such directory: ${TARGET}`);
    process.exit(2);
  }

  const apiPaths = buildApiIndex();
  const mainFile = path.join(TARGET, 'main.lua');
  const wiring = fs.existsSync(mainFile) ? buildWiringIndex(mainFile) : null;

  const files = luaFilesUnder(TARGET);
  const apiFiles = fs.existsSync(API_DIR)
    ? luaFilesUnder(API_DIR)
    : [];
  const memberNames = flags.has('--no-members')
    ? null
    : buildMemberNameIndex(apiFiles.concat(files));

  // Findings raised while indexing the stubs are about the stubs, not about
  // JCore. Drop them; they are not this project's to fix.
  findings.length = 0;
  let parsed = 0;

  for (const file of files) {
    const result = parseFile(file);
    if (!result) continue; // syntax error already reported
    parsed++;

    const rel = relative(file);
    // header.lua files are manifests, not modules; main.lua builds rather than
    // consumes, so the build-order rule does not apply to either.
    const isModule = !/\/header\.lua$/.test(rel) && !/\/main\.lua$/.test(rel);
    const moduleKey = rel.replace(/^jcore\//, '').replace(/\.lua$/, '');
    const selfBuiltAt = wiring ? wiring.builtAt.get(moduleKey) : undefined;

    walk(result.ast, (node, depth) => {
      // --- pass 5: method-name typos --------------------------------------
      if (
        memberNames &&
        node.type === 'CallExpression' &&
        node.base &&
        node.base.type === 'MemberExpression' &&
        node.base.indexer === ':' &&
        node.base.identifier &&
        !memberNames.has(node.base.identifier.name)
      ) {
        report('warn', file, lineOf(node.base), colOf(node.base),
          `method name appears nowhere else: ${node.base.identifier.name}`);
      }

      if (node.type !== 'MemberExpression') return;
      const dotted = dottedPath(node);
      if (!dotted) return;

      // --- pass 2: core.* paths -----------------------------------------
      if (dotted.startsWith('core.') && apiPaths.size > 0) {
        // Only flag the deepest chain, so core.spell_book inside
        // core.spell_book.get_x is not reported separately.
        if (!apiPaths.has(dotted)) {
          const parent = dotted.slice(0, dotted.lastIndexOf('.'));
          if (apiPaths.has(parent)) {
            report('warn', file, lineOf(node), colOf(node),
              `core path not in .api stubs: ${dotted}`);
          }
        }
      }

      // --- pass 3: rt.* wiring ------------------------------------------
      // Only the two-part head of the chain. `rt.ghost.thing` visits both
      // `rt.ghost` and `rt.ghost.thing`, and both name the same service, so
      // without this every deep read is reported twice.
      if (dotted.startsWith('rt.') && wiring && dotted.split('.').length === 2) {
        const name = dotted.split('.')[1];
        const assignedAt = wiring.assigned.get(name);

        if (assignedAt === undefined) {
          report('error', file, lineOf(node), colOf(node),
            `rt.${name} is read but main.lua never assigns it`);
        } else if (isModule && depth <= 1 && selfBuiltAt !== undefined && assignedAt > selfBuiltAt) {
          report('error', file, lineOf(node), colOf(node),
            `rt.${name} is read at factory scope but is built later ` +
            `(main.lua:${assignedAt}, after this module at main.lua:${selfBuiltAt}) ` +
            `-- this captures nil`);
        }
      }
    });

    // --- pass 4: globals ---------------------------------------------------
    if (!flags.has('--no-globals')) {
      for (const identifier of result.ast.globals || []) {
        if (KNOWN_GLOBALS.has(identifier.name)) continue;
        report('warn', file, lineOf(identifier), colOf(identifier),
          `undefined global: ${identifier.name}`);
      }
    }
  }

  // --- output ------------------------------------------------------------

  findings.sort((a, b) =>
    a.file === b.file ? a.line - b.line : a.file.localeCompare(b.file));

  let currentFile = null;
  for (const finding of findings) {
    if (finding.file !== currentFile) {
      currentFile = finding.file;
      console.log(`\n${relative(currentFile)}`);
    }
    const where = `${finding.line}:${finding.column}`.padEnd(9);
    console.log(`  ${where} ${finding.level.toUpperCase().padEnd(5)} ${finding.message}`);
  }

  const errors = findings.filter((f) => f.level === 'error').length;
  const warnings = findings.length - errors;

  console.log(
    `\n${parsed}/${files.length} files parsed, ` +
    `${apiPaths.size} core paths indexed, ` +
    `${errors} error(s), ${warnings} warning(s)`);

  process.exit(errors > 0 ? 1 : 0);
}

main();

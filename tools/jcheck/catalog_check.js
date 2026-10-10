// catalog_check -- validates a Jambix AIO skill catalogue data file.
//
// Usage: node tools/jcheck/catalog_check.js scripts/jambix_aio/modules/catalog/<class>.lua [...]
//
// Parses the file with the same Lua parser jcheck uses and checks the shape
// documented at the top of modules/catalog/hunter.lua: every ability row has
// the required fields with the right types, talent references resolve, list
// and combo entries name real abilities, and no key is declared twice (Lua
// would silently keep the last one). Exit code 1 on any error.

const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('usage: node catalog_check.js <catalog.lua> [...]');
  process.exit(2);
}

const ROLES = new Set([
  'damage', 'dot', 'heal', 'hot', 'shield', 'slow', 'root', 'stun', 'fear', 'disorient',
  'sleep', 'silence', 'interrupt', 'dispel', 'purge', 'cooldown', 'toggle', 'aspect',
  'stance', 'form', 'buff', 'debuff', 'threat', 'threat_drop', 'trap', 'pet', 'utility',
  'opener', 'execute', 'aoe', 'mana_drain', 'tracking', 'cc', 'defensive', 'escape',
  'finisher', 'generator', 'taunt', 'resurrect', 'summon', 'totem', 'seal', 'blessing',
  'aura', 'curse', 'mobility', 'stealth', 'immunity', 'mana', 'drain', 'teleport', 'poison',
]);
const KINDS = new Set(['instant', 'cast', 'channel', 'toggle', 'trap', 'aura', 'pet_command', 'stance', 'form', 'passive']);
const COSTS = new Set(['mana', 'rage', 'energy', 'none', 'health', 'reagent', 'combo']);
const ON = new Set(['target', 'self', 'pet', 'party', 'ground', 'friend']);
const AFFECT_WORDS = new Set(['pet', 'party', 'self', 'damage', 'healing', 'all', 'threat', 'mana', 'forms', 'totems']);

let totalErrors = 0;

function strKey(f) {
  if (f.type === 'TableKey' && f.key.type === 'StringLiteral') return f.key.raw.slice(1, -1);
  if (f.type === 'TableKeyString') return f.key.name;
  return null;
}
function fieldsOf(table) {
  const out = new Map();
  for (const f of table.fields) {
    const k = strKey(f);
    if (k !== null) out.set(k, f.value);
  }
  return out;
}
function literal(node) {
  if (!node) return undefined;
  if (node.type === 'StringLiteral') return node.raw.slice(1, -1);
  if (node.type === 'NumericLiteral') return node.value;
  if (node.type === 'BooleanLiteral') return node.value;
  if (node.type === 'UnaryExpression' && node.operator === '-') return -literal(node.argument);
  if (node.type === 'BinaryExpression' && node.operator === '..') return String(literal(node.left)) + String(literal(node.right));
  return node;
}
function arrayStrings(node) {
  if (!node || node.type !== 'TableConstructorExpression') return null;
  return node.fields.filter((f) => f.type === 'TableValue').map((f) => literal(f.value));
}

for (const file of files) {
  const errors = [];
  const warn = [];
  const src = fs.readFileSync(file, 'utf8');
  let ast;
  try {
    ast = luaparse.parse(src, { luaVersion: '5.3' });
  } catch (e) {
    console.log(`${file}\n  ERROR parse: ${e.message}`);
    totalErrors++;
    continue;
  }
  const ret = ast.body.find((s) => s.type === 'ReturnStatement');
  const root = ret && ret.arguments[0];
  if (!root || root.type !== 'TableConstructorExpression') {
    console.log(`${file}\n  ERROR the file must return a table`);
    totalErrors++;
    continue;
  }
  const top = fieldsOf(root);
  for (const need of ['class', 'label', 'resource', 'abilities', 'talents', 'combos']) {
    if (!top.has(need)) errors.push(`missing top-level field '${need}'`);
  }
  const abilities = top.get('abilities');
  const talents = top.get('talents');
  const combos = top.get('combos');
  const lists = top.get('lists');

  const dupCheck = (table, what) => {
    const seen = new Set();
    for (const f of table.fields) {
      const k = strKey(f);
      if (k === null) continue;
      if (seen.has(k)) errors.push(`${what} '${k}' is declared twice; Lua keeps only the last`);
      seen.add(k);
    }
  };

  const abilityNames = new Set();
  const talentNames = new Set();
  if (talents && talents.type === 'TableConstructorExpression') {
    dupCheck(talents, 'talent');
    for (const f of talents.fields) { const k = strKey(f); if (k) talentNames.add(k); }
  }
  if (abilities && abilities.type === 'TableConstructorExpression') {
    dupCheck(abilities, 'ability');
    for (const f of abilities.fields) {
      const name = strKey(f);
      if (!name) continue;
      abilityNames.add(name);
      const row = fieldsOf(f.value);
      const at = `ability '${name}'`;
      const roles = arrayStrings(row.get('roles'));
      if (!roles || roles.length === 0) errors.push(`${at}: roles must be a non-empty array`);
      else for (const r of roles) if (!ROLES.has(r)) warn.push(`${at}: unknown role '${r}'`);
      const kind = literal(row.get('kind'));
      if (!KINDS.has(kind)) errors.push(`${at}: kind '${kind}' is not one of ${[...KINDS].join('|')}`);
      const cost = literal(row.get('cost'));
      if (!COSTS.has(cost)) errors.push(`${at}: cost '${cost}' is not one of ${[...COSTS].join('|')}`);
      if (!row.has('range')) errors.push(`${at}: range is required`);
      if (!row.has('needs')) errors.push(`${at}: needs is required (use {} for none)`);
      if (typeof literal(row.get('cast')) !== 'number') errors.push(`${at}: cast must be a number of seconds`);
      const cd = literal(row.get('cooldown'));
      if (typeof cd !== 'number' && cd !== 'traps' && cd !== 'shared') errors.push(`${at}: cooldown must be a number of seconds`);
      if (typeof literal(row.get('learned')) !== 'number') errors.push(`${at}: learned must be a level`);
      const applies = row.get('applies');
      if (applies) {
        const a = fieldsOf(applies);
        const on = literal(a.get('on'));
        if (a.has('aura') && typeof literal(a.get('aura')) !== 'string') errors.push(`${at}: applies.aura must be a string`);
        if (a.has('on') && !ON.has(on)) errors.push(`${at}: applies.on '${on}' is not one of ${[...ON].join('|')}`);
        if (a.has('aura') && !a.has('on')) errors.push(`${at}: applies.aura needs applies.on`);
      }
      const tref = row.get('talents');
      if (tref) for (const tf of tref.fields) {
        const tn = strKey(tf);
        if (tn && !talentNames.has(tn)) errors.push(`${at}: refers to talent '${tn}' which is not in the talents table`);
      }
      const syn = row.get('synergy');
      if (syn && !arrayStrings(syn)) errors.push(`${at}: synergy must be an array of strings`);
    }
  }
  if (talents && talents.type === 'TableConstructorExpression') {
    for (const f of talents.fields) {
      const name = strKey(f);
      if (!name) continue;
      const row = fieldsOf(f.value);
      const at = `talent '${name}'`;
      for (const need of ['tree', 'tier', 'max', 'effect', 'affects']) if (!row.has(need)) errors.push(`${at}: missing '${need}'`);
      const affects = arrayStrings(row.get('affects'));
      if (affects) for (const a of affects) {
        if (!abilityNames.has(a) && !AFFECT_WORDS.has(a)) errors.push(`${at}: affects '${a}' which is not a catalogued ability`);
      }
    }
  }
  if (combos && combos.type === 'TableConstructorExpression') {
    for (const f of combos.fields) {
      const row = fieldsOf(f.value);
      const name = literal(row.get('name')) || '?';
      for (const need of ['name', 'uses', 'how']) if (!row.has(need)) errors.push(`combo '${name}': missing '${need}'`);
      const uses = arrayStrings(row.get('uses')) || [];
      for (const u of uses) if (!abilityNames.has(u)) errors.push(`combo '${name}': uses '${u}' which is not a catalogued ability`);
    }
  }
  if (lists && lists.type === 'TableConstructorExpression') {
    for (const f of lists.fields) {
      const ln = strKey(f);
      const names = arrayStrings(f.value) || [];
      for (const n of names) if (!abilityNames.has(n) && ln !== 'pet_interrupts') errors.push(`lists.${ln}: '${n}' is not a catalogued ability`);
    }
  }

  const rel = path.relative(process.cwd(), file);
  console.log(`${rel}: ${abilityNames.size} abilities, ${talentNames.size} talents, ${combos ? combos.fields.length : 0} combos`);
  for (const w of warn) console.log(`  WARN  ${w}`);
  for (const e of errors) console.log(`  ERROR ${e}`);
  totalErrors += errors.length;
}

process.exit(totalErrors > 0 ? 1 : 0);

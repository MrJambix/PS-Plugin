#!/usr/bin/env node
// class_names_check -- every spell and talent name a class file uses, against
// the client's own tables.
//
//   node tools/jcheck/class_names_check.js [druid mage ...] [--wow <install>] [--all]
//
// The class files name abilities, auras and talents in English, and the
// spellbook resolves them at runtime. A name the client does not have never
// resolves -- silently, like every other resolution failure -- and an aura
// asked for by a name that is no spell of yours (Weakened Soul, a talent's
// debuff) is never read at all (rotation.lua `aura_ids`). This reads both
// rotation clients (Era, which Season of Discovery shares, and Forever) and
// says, for each name in the file:
//   spell    on the class's skill lines (L = level learned)
//   rune     a Season of Discovery rune (Era's Engraving line)
//   talent   Era's trees (tab N) / Forever's trait tree
//   aura     a spell name only: fine as a buff_up/debuff_up NAME only when
//            it is also one of your spells -- otherwise ask by id
// and lists, per class, the names neither client has. Exit code 1 when a rule,
// list or talent read names something neither client has; --all prints every
// name, not just the problems.
"use strict";
const fs = require("fs");
const path = require("path");
const luaparse = require("luaparse");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const ALL = argv.includes("--all");
const CLASS_DIR = path.join(ROOT, "scripts", "jambix_aio", "modules", "classes");
const wanted = argv.filter((a, i) => !a.startsWith("--") && argv[i - 1] !== "--wow");
const files = (wanted.length ? wanted : fs.readdirSync(CLASS_DIR).map(f => f.replace(/\.lua$/, "")))
    .filter(f => fs.existsSync(path.join(CLASS_DIR, f + ".lua")));

const CLASS_NAMES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE",
    "WARLOCK", "MONK", "DRUID"];
// FileDataIDs, for clients whose root carries no names (Forever's).
const TABLES = {
    SkillLine: 1240935, SkillLineAbility: 1266278, SkillRaceClassInfo: 1240406, SpellName: 1990283,
    SpellLevels: 1140079, Talent: 1369062, TalentTab: 2178102, SkillLineXTraitTree: 4505477,
    TraitNode: 4420297, TraitNodeXTraitNodeEntry: 4420304, TraitNodeEntry: 4420298, TraitDefinition: 4420327,
};
const CLIENTS = { era: "wow_classic_era", forever: "wow_classic_beta" };
// Every class has these and no skill line lists them.
const GENERAL = new Set(["Attack"]);

/** spellbook.lua's FORM_NAMES: id -> { shared, name }, a form's spell filed apart. */
function formNames() {
    const src = fs.readFileSync(path.join(ROOT, "scripts", "jambix_aio", "modules", "spellbook.lua"), "utf8");
    const out = [];
    const re = /\[(\d+)\]\s*=\s*\{\s*shared\s*=\s*"([^"]+)",\s*name\s*=\s*"([^"]+)"\s*\}/g;
    for (let m; (m = re.exec(src));) out.push({ id: Number(m[1]), shared: m[2], name: m[3] });
    return out;
}
const FORMS = formNames();

function readClient(product) {
    const casc = cascLib.open({ wow: WOW, product });
    const T = {};
    for (const [name, fdid] of Object.entries(TABLES)) {
        let bytes;
        try { bytes = casc.read("DBFilesClient/" + name + ".db2"); }
        catch (e) { bytes = casc.read(fdid); }
        T[name] = db2.parse(bytes, db2.loadDbd(path.join(__dirname, "dbd", name + ".dbd")));
    }
    const build = (casc.build && casc.build.version) || "?";
    casc.close();

    const N = id => (T.SpellName.byId.get(id) || {}).Name_lang;
    const allNames = new Set(T.SpellName.rows.map(r => r.Name_lang));
    const level = new Map();
    for (const r of T.SpellLevels.rows) if (!level.has(r.SpellID) || !r.DifficultyID) level.set(r.SpellID, r.BaseLevel || r.SpellLevel || 0);
    const lines = new Map(T.SkillLine.rows.map(r => [r.ID, r]));
    const classes = {};
    CLASS_NAMES.forEach((cls, i) => {
        const bit = 1 << i;
        const own = new Set();
        for (const r of T.SkillRaceClassInfo.rows) {
            const line = lines.get(r.SkillID);
            if (line && line.CategoryID === 7 && r.ClassMask > 0 && (r.ClassMask & bit)) own.add(r.SkillID);
        }
        if (own.size === 0) return;
        const C = { spells: new Map(), runes: new Set(), talents: new Map(), traits: new Set() };
        for (const r of T.SkillLineAbility.rows) {
            // The class's own lines, and any line that names the class
            // (Wands: Shoot for priests, mages and warlocks).
            const mine = own.has(r.SkillLine) ? !r.ClassMask || (r.ClassMask & bit) : r.ClassMask > 0 && (r.ClassMask & bit);
            if (!mine) continue;
            const name = N(r.Spell);
            if (!name) continue;
            const rune = name.match(/^Engrave \w+ - (.+)$/);
            if (rune) { C.runes.add(rune[1]); continue; }
            const form = FORMS.find(f => f.id === r.Spell && f.shared === name.toLowerCase());
            const lv = level.get(r.Spell);
            if (form) C.spells.set(form.name, lv === undefined ? null : lv);
            const prev = C.spells.get(name);
            if (prev === undefined || (lv !== undefined && lv < prev)) C.spells.set(name, lv === undefined ? null : lv);
        }
        const tabs = T.TalentTab.rows.filter(t => t.ClassMask & bit).sort((a, b) => a.OrderIndex - b.OrderIndex);
        const tabOf = new Map(tabs.map((t, k) => [t.ID, k + 1]));
        for (const r of T.Talent.rows) {
            if (!tabOf.has(r.TabID)) continue;
            const name = N((r.SpellRank || []).find(Boolean));
            if (name) C.talents.set(name, tabOf.get(r.TabID));
        }
        const link = T.SkillLineXTraitTree.rows.find(l => own.has(l.SkillLineID));
        if (link) {
            const entryOf = new Map(T.TraitNodeXTraitNodeEntry.rows.map(x => [x.TraitNodeID, x.TraitNodeEntryID]));
            for (const node of T.TraitNode.rows) {
                if (node.TraitTreeID !== link.TraitTreeID) continue;
                const entry = T.TraitNodeEntry.byId.get(entryOf.get(node.ID));
                const def = entry && T.TraitDefinition.byId.get(entry.TraitDefinitionID);
                const name = def && (def.OverrideName_lang || N(def.SpellID));
                if (name) C.traits.add(name);
            }
        }
        classes[cls] = C;
    });
    return { build, classes, allNames, trait: Object.values(classes).some(c => c.traits.size) };
}

/** Every English name the file asks the client for, by how it asks. */
function namesIn(file) {
    const src = fs.readFileSync(file, "utf8");
    const ast = luaparse.parse(src, { luaVersion: "5.3", locations: true });
    const uses = new Map();
    const add = (node, kind) => {
        const name = node.raw.slice(1, -1).replace(/\\'/g, "'");
        if (!uses.has(name)) uses.set(name, { kinds: new Set(), lines: new Set() });
        uses.get(name).kinds.add(kind);
        uses.get(name).lines.add(node.loc.start.line);
    };
    const AURA = new Set(["buff_up", "debuff_up", "debuff_up_any", "debuff_stacks", "debuff_remaining",
        "buff_remaining", "dot_worth_it"]);
    const TALENT = new Set(["talent", "has_talent", "rank", "max_rank"]);
    const BOOK = new Set(["known", "ready", "castable", "cooldown", "id", "ids"]);
    const LISTS = new Set(["interrupts", "defensives", "escapes", "forms"]);
    const RULE_KEYS = new Set(["self", "upkeep", "heal", "dot", "fast", "channel", "retarget", "direct", "prefix"]);
    (function walk(n) {
        if (!n || typeof n !== "object") return;
        if (Array.isArray(n)) { n.forEach(walk); return; }
        // pet_dispels and the like name the pet's spells, not the class's.
        if (n.type === "TableKeyString" && /^pet_/.test(n.key.name)) return;
        if (n.type === "CallExpression" && n.base.type === "MemberExpression") {
            const fn = n.base.identifier.name;
            const strs = n.arguments.filter(a => a.type === "StringLiteral");
            if (AURA.has(fn)) strs.forEach(s => add(s, "aura"));
            else if (TALENT.has(fn)) strs.forEach(s => add(s, "talent"));
            else if (BOOK.has(fn)) strs.forEach(s => add(s, "spell"));
        }
        if (n.type === "TableConstructorExpression") {
            const first = n.fields[0];
            if (first && first.type === "TableValue" && first.value.type === "StringLiteral"
                && n.fields.some(f => (f.type === "TableKeyString" && RULE_KEYS.has(f.key.name))
                    || (f === n.fields[1] && f.type === "TableValue" && f.value.type !== "StringLiteral"))) {
                add(first.value, "rule");
            }
            for (const f of n.fields) {
                if (f.type !== "TableKeyString") continue;
                if (f.key.name === "spell" && f.value.type === "StringLiteral") add(f.value, "list");
                if (LISTS.has(f.key.name) && f.value.type === "TableConstructorExpression") {
                    for (const g of f.value.fields) if (g.type === "TableValue" && g.value.type === "StringLiteral") add(g.value, "list");
                }
            }
        }
        for (const k of Object.keys(n)) if (k !== "loc" && k !== "range") walk(n[k]);
    })(ast);
    return uses;
}

function describe(C, all, name) {
    const out = [];
    if (GENERAL.has(name)) out.push("general");
    if (C.spells.has(name)) out.push("spell" + (C.spells.get(name) != null ? " L" + C.spells.get(name) : ""));
    if (C.runes.has(name)) out.push("rune");
    if (C.talents.has(name)) out.push("talent tab " + C.talents.get(name));
    if (C.traits.has(name)) out.push("talent");
    if (out.length === 0 && all.has(name)) out.push("aura");
    return out.join(", ");
}

const clients = {};
for (const [key, product] of Object.entries(CLIENTS)) {
    clients[key] = readClient(product);
    console.log(`${key} ${clients[key].build}`);
}

let problems = 0;
for (const file of files) {
    const cls = file.toUpperCase();
    const uses = namesIn(path.join(CLASS_DIR, file + ".lua"));
    const rows = [];
    for (const [name, u] of [...uses.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
        const at = {};
        for (const [key, c] of Object.entries(clients)) at[key] = c.classes[cls] ? describe(c.classes[cls], c.allNames, name) : "";
        const real = v => v && v !== "aura";
        const asked = [...u.kinds];
        // A spell or talent neither client has. An aura read by name must be
        // one of your spells to be found; one that is only an aura is too.
        let flag = "";
        if (!Object.values(at).some(real)) {
            flag = asked.includes("aura") && !asked.some(k => k !== "aura") && Object.values(at).some(Boolean)
                ? "ASK BY ID (an aura, no spell of yours)" : "ON NEITHER CLIENT";
        }
        if (flag) problems++;
        if (flag || ALL) {
            rows.push(`  ${name.padEnd(30)} ${asked.join(",").padEnd(16)} line ${[...u.lines].join(",")}`
                + Object.entries(at).map(([k, v]) => `  ${k}: ${v || "-"}`).join("") + (flag ? `   <- ${flag}` : ""));
        }
    }
    console.log(`\n${file}: ${uses.size} names` + (rows.length ? "" : ", all found"));
    for (const r of rows) console.log(r);
}
process.exit(problems > 0 ? 1 : 0);

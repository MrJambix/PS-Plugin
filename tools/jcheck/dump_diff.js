#!/usr/bin/env node
// Compares two JCore dumps (services/dump.lua): what Forever has that Era does
// not, what changed, and which API is missing or empty on one of them.
//
//   node tools/jcheck/dump_diff.js scripts_data/jcore/jcore.dump.forever.json \
//        scripts_data/jcore/jcore.dump.vanilla.json [--md [out.md]]
//
// Spells are compared by NAME (ids differ between the two clients for the same
// spell) and by id. A spellbook is the character's, so dump the same class on
// both clients for the spell and talent sections to mean anything; the API
// section holds whatever the class. With --md the report is also written as
// Markdown (default scripts/jambix_debug/FOREVER_VS_ERA.md). The Forever recorder's
// always-empty functions are added when scripts_data/jcore/jcore.recorder.json
// is there.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const args = process.argv.slice(2);
const files = args.filter(a => !a.startsWith("--") && a.endsWith(".json"));
const mdIndex = args.indexOf("--md");
const mdOut = mdIndex >= 0 ? (args[mdIndex + 1] && !args[mdIndex + 1].startsWith("--") && !args[mdIndex + 1].endsWith(".json")
    ? args[mdIndex + 1] : path.join(ROOT, "scripts", "jambix_debug", "FOREVER_VS_ERA.md")) : null;
if (files.length < 2) {
    console.error("usage: dump_diff.js <forever dump> <era dump> [--md [out.md]]");
    process.exit(2);
}
const load = f => JSON.parse(fs.readFileSync(path.resolve(f), "utf8"));
const A = load(files[0]);   // the new client (Forever)
const B = load(files[1]);   // the old one (Era)
const nameA = (A.client && A.client.version) || "A";
const nameB = (B.client && B.client.version) || "B";

const lines = [];
const out = s => lines.push(s);
const list = arr => Array.isArray(arr) ? arr : [];

// --- spells ------------------------------------------------------------------

const spellsA = list(A.spells).filter(s => !s.position_only);
const spellsB = list(B.spells).filter(s => !s.position_only);
const byName = arr => {
    const m = new Map();
    for (const s of arr) {
        if (!m.has(s.name)) m.set(s.name, []);
        m.get(s.name).push(s);
    }
    return m;
};
const nA = byName(spellsA), nB = byName(spellsB);
const idsB = new Set(spellsB.map(s => s.id));
const costText = c => list(c).map(x => `${x.cost ?? x.min_cost ?? "?"}/${x.cost_type ?? "?"}`).join(",");
const best = arr => arr.slice().sort((x, y) => y.id - x.id)[0];

const newSpells = [], goneSpells = [], changed = [];
for (const [name, rows] of nA) {
    if (!nB.has(name)) { newSpells.push(best(rows)); continue; }
    const a = best(rows), b = best(nB.get(name));
    const diffs = [];
    if (a.id !== b.id) diffs.push(`id ${b.id} -> ${a.id}`);
    if (JSON.stringify(a.cast_time) !== JSON.stringify(b.cast_time)) diffs.push(`cast ${b.cast_time} -> ${a.cast_time}`);
    if (costText(a.costs) !== costText(b.costs)) diffs.push(`cost ${costText(b.costs) || "-"} -> ${costText(a.costs) || "-"}`);
    if (JSON.stringify(a.cooldown) !== JSON.stringify(b.cooldown)) diffs.push(`cooldown ${JSON.stringify(b.cooldown)} -> ${JSON.stringify(a.cooldown)}`);
    if (JSON.stringify(a.max_range) !== JSON.stringify(b.max_range)) diffs.push(`range ${b.max_range} -> ${a.max_range}`);
    if ((a.description || "") !== (b.description || "")) diffs.push("tooltip");
    if (diffs.length) changed.push({ name, a, b, diffs });
}
for (const [name, rows] of nB) if (!nA.has(name)) goneSpells.push(best(rows));

const ch = c => c && c.character ? `class ${c.character.class_id}, race ${c.character.race_id}, level ${c.character.level}` : "?";
out(`# ${nameA} vs ${nameB}`);
out("");
out(`- ${nameA}: ${files[0]} (${ch(A)}, JCore ${A.jcore || "?"}, ${spellsA.length} spells)`);
out(`- ${nameB}: ${files[1]} (${ch(B)}, JCore ${B.jcore || "?"}, ${spellsB.length} spells)`);
if (A.character && B.character && A.character.class_id !== B.character.class_id) {
    out(`- NOTE: different classes; the spell and talent sections compare unlike spellbooks.`);
}
out("");
out(`## Spells only on ${nameA} (${newSpells.length})`);
out("");
for (const s of newSpells.sort((x, y) => x.name.localeCompare(y.name))) {
    const tip = (s.description || "").replace(/\s+/g, " ").slice(0, 140);
    out(`- **${s.name}** (${s.id})${s.known ? "" : " (not known)"}${tip ? ": " + tip : ""}`);
}
out("");
out(`## Spells only on ${nameB} (${goneSpells.length})`);
out("");
for (const s of goneSpells.sort((x, y) => x.name.localeCompare(y.name))) out(`- ${s.name} (${s.id})`);
out("");
out(`## Spells on both, changed (${changed.length})`);
out("");
for (const c of changed.sort((x, y) => x.name.localeCompare(y.name))) out(`- ${c.name}: ${c.diffs.join("; ")}`);
out("");

// --- talents -----------------------------------------------------------------

const talentNames = d => {
    const out = new Set();
    const t = d.talents || {};
    const classic = t.classic || {};
    for (let tab = 1; tab <= (classic.tabs || 0); tab++) {
        for (const row of list((classic[tab] || classic[String(tab)] || {}).talents)) {
            const n = row && (row.talent_name || row.name);
            if (n) out.add(n);
        }
    }
    for (const a of list(t.active)) if (a && a.name) out.add(a.name);
    return out;
};
const tA = talentNames(A), tB = talentNames(B);
const treeCount = d => Object.values((d.talents && d.talents.trees) || {}).reduce((n, rows) => n + list(rows).length, 0);
out("## Talents");
out("");
out(`- ${nameA}: ${(A.talents && A.talents.classic && A.talents.classic.tabs) || 0} classic tabs, trait trees ${JSON.stringify((A.talents && A.talents.tree_ids) || [])} with ${treeCount(A)} nodes, ${list(A.talents && A.talents.active).length} active`);
out(`- ${nameB}: ${(B.talents && B.talents.classic && B.talents.classic.tabs) || 0} classic tabs, trait trees ${JSON.stringify((B.talents && B.talents.tree_ids) || [])} with ${treeCount(B)} nodes, ${list(B.talents && B.talents.active).length} active`);
const onlyA = [...tA].filter(n => !tB.has(n)).sort(), onlyB = [...tB].filter(n => !tA.has(n)).sort();
out(`- Named only on ${nameA}: ${onlyA.join(", ") || "-"}`);
out(`- Named only on ${nameB}: ${onlyB.join(", ") || "-"}`);
out(`- (A trait node names nothing until it is taken: the core has no call from an entry id to its spell.)`);
out("");

// --- API ---------------------------------------------------------------------

const fnSet = d => {
    const s = new Set();
    const core = (d.api && d.api.core) || {};
    for (const [ns, fns] of Object.entries(core)) for (const f of list(fns)) s.add(ns === "(root)" ? `core.${f}` : `core.${ns}.${f}`);
    return s;
};
const fA = fnSet(A), fB = fnSet(B);
const mA = new Set(list(A.api && A.api.game_object)), mB = new Set(list(B.api && B.api.game_object));
const only = (x, y) => [...x].filter(k => !y.has(k)).sort();
out("## API");
out("");
out(`- core functions: ${fA.size} on ${nameA}, ${fB.size} on ${nameB}; game_object methods: ${mA.size} / ${mB.size}`);
const fOnlyA = only(fA, fB), fOnlyB = only(fB, fA), mOnlyA = only(mA, mB), mOnlyB = only(mB, mA);
out(`- Functions only on ${nameA} (${fOnlyA.length}): ${fOnlyA.join(", ") || "-"}`);
out(`- Functions only on ${nameB} (${fOnlyB.length}): ${fOnlyB.join(", ") || "-"}`);
out(`- Methods only on ${nameA} (${mOnlyA.length}): ${mOnlyA.slice(0, 200).join(", ") || "-"}${mOnlyA.length > 200 ? " ..." : ""}`);
out(`- Methods only on ${nameB} (${mOnlyB.length}): ${mOnlyB.join(", ") || "-"}`);
out("");

const rec = path.join(ROOT, "scripts_data", "jcore", "jcore.recorder.json");
if (fs.existsSync(rec)) {
    try {
        const r = JSON.parse(fs.readFileSync(rec, "utf8"));
        const empty = [], falsy = [];
        for (const [k, v] of Object.entries(r.functions || {})) {
            if (v.status === "always empty") empty.push(`core.${k}`);
            else if (v.status === "only false") falsy.push(`core.${k}`);
        }
        for (const [k, v] of Object.entries(r.methods || {})) {
            if (v.status === "always empty") empty.push(`game_object:${k}`);
            else if (v.status === "only false") falsy.push(`game_object:${k}`);
        }
        out(`## What answers nothing on Forever (the API recorder, ${(r.sessions && r.sessions.count) || "?"} sessions)`);
        out("");
        out(`- Always empty (${empty.length}): ${empty.sort().join(", ") || "-"}`);
        out(`- Only ever false (${falsy.length}; real only if its state happened while recording): ${falsy.sort().join(", ") || "-"}`);
        out("");
    } catch (e) {
        out(`(the recorder file could not be read: ${e.message})`);
    }
}

const text = lines.join("\n");
console.log(text);
if (mdOut) {
    fs.writeFileSync(mdOut, text + "\n");
    console.error(`written: ${mdOut}`);
}

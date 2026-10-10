#!/usr/bin/env node
// Which classic talent tab each Forever trait node belongs to, from the
// client's own trait tables.
//
//   node tools/jcheck/talents_extract.js [--wow <install>] [--out <file>]
//
// Forever puts all of a class's talents in ONE trait tree, laid out as the
// three classic trees side by side. get_talent_tree_ids answers that one tree
// and get_specialization answers 1, so modules/talents.lua had no way to tell
// the tabs apart and counted every point for tab 1. The client never says
// which tab a node is in; where it sits does:
//   SkillLineXTraitTree  class skill line -> the class's trait tree
//   TraitNode            each node's tree and column (PosX)
//   TraitNodeXTraitNodeEntry, TraitNodeEntry, TraitDefinition, SpellName
//                        the talent's name, written beside the node for review
// In every class tree the columns fall into three bands with wide gaps between
// them (1.60.1: x 1020-2820, 5020-6820, 9080-10880). The two widest gaps are
// the tab edges; a tree whose bands are not three clear groups stops the run.
//
// WRITTEN: scripts/jambix_aio/modules/talent_trees.lua, read by
// modules/talents.lua. Do not edit it by hand: run this again after a client
// patch.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "talent_trees.lua");

// FileDataIDs, for clients whose root carries no names (Forever's). From the
// community listfile (github.com/wowdev/wow-listfile).
const TABLES = {
    SkillLine: 1240935, SkillRaceClassInfo: 1240406, SkillLineXTraitTree: 4505477, TraitNode: 4420297,
    TraitNodeXTraitNodeEntry: 4420304, TraitNodeEntry: 4420298, TraitDefinition: 4420327, SpellName: 1990283,
};

// ChrClasses ids, by the bit a ClassMask carries (1 << (id - 1)).
const CLASS_NAMES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE",
    "WARLOCK", "MONK", "DRUID"];

function readTables(casc) {
    const out = {};
    for (const [name, fdid] of Object.entries(TABLES)) {
        let bytes;
        try { bytes = casc.read("DBFilesClient/" + name + ".db2"); }
        catch (e) { bytes = casc.read(fdid); }
        out[name] = db2.parse(bytes, db2.loadDbd(path.join(__dirname, "dbd", name + ".dbd")));
    }
    return out;
}

/** The two widest gaps between distinct columns, as the x where tab 2 and tab 3 start. */
function bandEdges(xs, label) {
    let cols = [...new Set(xs)].sort((a, b) => a - b);
    // A column further out than the rest of the tree is wide is a stray
    // (1.60.1: the hunter's Lightning Reflexes at x 102800, its band ending at
    // 10880). It stays in the end band it lies beyond.
    while (cols.length > 3 && cols[cols.length - 1] - cols[cols.length - 2] > cols[cols.length - 2] - cols[0]) {
        console.log(`  ${label}: column x ${cols[cols.length - 1]} is a stray, counted in tab 3`);
        cols = cols.slice(0, -1);
    }
    while (cols.length > 3 && cols[1] - cols[0] > cols[cols.length - 1] - cols[1]) {
        console.log(`  ${label}: column x ${cols[0]} is a stray, counted in tab 1`);
        cols = cols.slice(1);
    }
    const gaps = [];
    for (let i = 1; i < cols.length; i++) gaps.push({ at: cols[i], size: cols[i] - cols[i - 1] });
    gaps.sort((a, b) => b.size - a.size);
    if (gaps.length < 2) throw new Error(`${label}: fewer than three columns`);
    const [wide, next] = gaps;
    const narrowest = gaps[2] ? gaps[2].size : 0;
    // Two clear gaps: each at least twice any gap inside a band.
    if (next.size < 2 * narrowest) {
        throw new Error(`${label}: no three clear column bands (gaps ${gaps.slice(0, 4).map(g => g.size).join(", ")})`);
    }
    return [Math.min(wide.at, next.at), Math.max(wide.at, next.at)];
}

function extract() {
    const casc = cascLib.open({ wow: WOW, product: "wow_classic_beta" });
    const T = readTables(casc);
    const build = (casc.build && casc.build.version) || "?";
    casc.close();

    const spellName = id => (T.SpellName.byId.get(id) || {}).Name_lang;
    const lines = new Map(T.SkillLine.rows.map(r => [r.ID, r]));
    // Class skill lines (category 7) -> the class they belong to.
    const classOfLine = new Map();
    for (const r of T.SkillRaceClassInfo.rows) {
        const line = lines.get(r.SkillID);
        if (!line || line.CategoryID !== 7 || r.ClassMask <= 0) continue;
        const bits = CLASS_NAMES.filter((_, i) => r.ClassMask & (1 << i));
        if (bits.length === 1) classOfLine.set(r.SkillID, bits[0]);
    }
    const entryOf = new Map();
    for (const x of T.TraitNodeXTraitNodeEntry.rows) if (!entryOf.has(x.TraitNodeID) || x.Index === 0) entryOf.set(x.TraitNodeID, x.TraitNodeEntryID);
    const nameOfNode = node => {
        const entry = T.TraitNodeEntry.byId.get(entryOf.get(node.ID));
        const def = entry && T.TraitDefinition.byId.get(entry.TraitDefinitionID);
        return def ? (def.OverrideName_lang || spellName(def.SpellID) || "spell " + def.SpellID) : "?";
    };

    const trees = [];
    for (const link of T.SkillLineXTraitTree.rows) {
        const cls = classOfLine.get(link.SkillLineID);
        if (!cls || trees.some(t => t.id === link.TraitTreeID)) continue;
        const nodes = T.TraitNode.rows.filter(n => n.TraitTreeID === link.TraitTreeID);
        if (nodes.length === 0) continue;
        const label = `${cls} tree ${link.TraitTreeID}`;
        const [tab2, tab3] = bandEdges(nodes.map(n => n.PosX), label);
        const rows = nodes.map(n => ({
            id: n.ID, tab: n.PosX < tab2 ? 1 : (n.PosX < tab3 ? 2 : 3), x: n.PosX, y: n.PosY, name: nameOfNode(n),
        })).sort((a, b) => a.tab - b.tab || a.x - b.x || a.y - b.y);
        const counts = [1, 2, 3].map(t => rows.filter(r => r.tab === t).length);
        if (counts.some(c => c < 5)) throw new Error(`${label}: a band holds under 5 nodes (${counts.join("/")})`);
        trees.push({ id: link.TraitTreeID, cls, rows, counts, edges: [tab2, tab3] });
        console.log(`  ${label}: ${counts.join("/")} nodes per tab (tab 2 from x ${tab2}, tab 3 from x ${tab3})`);
    }
    trees.sort((a, b) => a.cls.localeCompare(b.cls));
    if (trees.length === 0) throw new Error("no class trait trees found");
    return { build, trees };
}

function lua({ build, trees }) {
    const L = [];
    L.push("-- Jambix AIO / talent_trees -- GENERATED by tools/jcheck/talents_extract.js from the");
    L.push("-- Forever client's trait tables (SkillLineXTraitTree, TraitNode, TraitNodeXTraitNodeEntry,");
    L.push("-- TraitNodeEntry, TraitDefinition, SpellName). Do not edit by hand: run it again after a");
    L.push("-- client patch.");
    L.push("--");
    L.push("-- Forever keeps a class's three classic talent trees in one trait tree, side by side;");
    L.push("-- the column a node sits in is its tab. trees[tree id] = { class, nodes = { [trait node");
    L.push("-- id] = tab (1, 2, 3) } }, each node commented with its talent.");
    L.push("return {");
    L.push("    forever = {");
    L.push(`        build = "${build}",`);
    L.push("        trees = {");
    for (const t of trees) {
        L.push(`            [${t.id}] = {`);
        L.push(`                class = "${t.cls}",`);
        L.push("                nodes = {");
        for (const r of t.rows) L.push(`                    [${r.id}] = ${r.tab}, -- ${r.name}`);
        L.push("                },");
        L.push("            },");
    }
    L.push("        },");
    L.push("    },");
    L.push("}");
    return L.join("\n") + "\n";
}

const data = extract();
fs.writeFileSync(OUT, lua(data));
console.log(`forever ${data.build}: ${data.trees.length} class trees -> ${path.relative(ROOT, OUT)}`);

#!/usr/bin/env node
// Spell ranks whose ids do not rise with their levels, from the client's own tables.
//
//   node tools/jcheck/ranks_extract.js [--client all|vanilla|forever] [--wow <install>] [--out <file>]
//
// The AIO's spellbook resolves an ability by name and keeps its best known
// rank. Until 1.88.1 "best" was the highest id, on the belief that a later
// rank always has the higher id. The client's tables say otherwise, on both
// clients: Battle Shout's rank 1 is 6673 and its ranks 2 and 3 are 5242 and
// 6192; Seal of the Crusader's rank 1 (21082) and Consecration's (26573) are
// above every later rank; Hammer of Wrath runs backwards; Forever added
// Trueshot Aura ranks at 25 and 32 (1299346, 1299348) above the 40 to 60 ones.
// So a warrior of 12 to 31 shouted rank 1, and a paladin judged rank 1 seals.
//
// For every class's own skill lines (not the pet lines), the spells are
// grouped by name less a trailing "(...)" (Create Healthstone (Minor) to
// (Major) on Era are one line, which spellbook.id_prefix compares). A group
// whose ids, in rising order, do not rise in level is written whole: every
// id in it with the level SpellLevels gives it. The spellbook compares two
// ids it has levels for by level, and anything else by id, as before.
// Season of Discovery's rune spells (ids 400000 to 999999) are left out:
// they share levels with the ranks they shadow, and the old order holds them.
//
// WRITTEN: scripts/jambix_aio/modules/rank_order.lua. Do not edit it by hand:
// run this again after a client patch.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "rank_order.lua");
const CLIENTS = {
    vanilla: { product: "wow_classic_era" },
    forever: { product: "wow_classic_beta" },
};
const wantClient = (opt("--client") || "all").toLowerCase();

// FileDataIDs, for clients whose root carries no names (Forever's).
const TABLES = {
    SkillLine: 1240935, SkillLineAbility: 1266278, SkillRaceClassInfo: 1240406, SpellName: 1990283,
    SpellLevels: 1140079,
};
const CLASS_NAMES = ["WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN", "MAGE",
    "WARLOCK", "MONK", "DRUID"];
const SOD = id => id >= 400000 && id < 1000000;
const base = name => name.replace(/\s*\([^)]*\)$/, "");

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

function extract(clientKey) {
    const casc = cascLib.open({ wow: WOW, product: CLIENTS[clientKey].product });
    const T = readTables(casc);
    // The build, as casc read it from .build.info (the product row).
    const build = (casc.build && casc.build.version) || "?";
    casc.close();

    const nameOf = id => (T.SpellName.byId.get(id) || {}).Name_lang;
    const level = new Map();
    for (const r of T.SpellLevels.rows) {
        if (!level.has(r.SpellID) || !r.DifficultyID) level.set(r.SpellID, r.BaseLevel || r.SpellLevel || 0);
    }
    const lines = new Map(T.SkillLine.rows.map(r => [r.ID, r]));
    const groups = [];   // { cls, name, ranks: [{ id, level }] }
    CLASS_NAMES.forEach((cls, i) => {
        const bit = 1 << i;
        const own = new Set();
        for (const r of T.SkillRaceClassInfo.rows) {
            const line = lines.get(r.SkillID);
            if (line && line.CategoryID === 7 && r.ClassMask > 0 && (r.ClassMask & bit)) own.add(r.SkillID);
        }
        const byBase = new Map();
        for (const r of T.SkillLineAbility.rows) {
            if (!own.has(r.SkillLine) || (r.ClassMask && !(r.ClassMask & bit))) continue;
            if (/^Pet /.test((lines.get(r.SkillLine) || {}).DisplayName_lang || "")) continue;
            const name = nameOf(r.Spell);
            const lv = level.get(r.Spell);
            if (!name || /^Engrave /.test(name) || SOD(r.Spell) || !lv) continue;
            const key = base(name);
            if (!byBase.has(key)) byBase.set(key, new Map());
            byBase.get(key).set(r.Spell, lv);
        }
        for (const [name, m] of byBase) {
            const ranks = [...m.entries()].map(([id, lv]) => ({ id, level: lv })).sort((a, b) => a.id - b.id);
            let ordered = true;
            for (let a = 0; a < ranks.length && ordered; a++) {
                for (let b = a + 1; b < ranks.length; b++) {
                    if (ranks[b].level < ranks[a].level) { ordered = false; break; }
                }
            }
            if (!ordered) groups.push({ cls, name, ranks });
        }
    });
    // One id under two classes' lines (none today) keeps its first level.
    groups.sort((a, b) => CLASS_NAMES.indexOf(a.cls) - CLASS_NAMES.indexOf(b.cls) || (a.name < b.name ? -1 : 1));
    return { build, groups };
}

const out = {};
for (const key of (wantClient === "all" ? Object.keys(CLIENTS) : [wantClient])) {
    try {
        out[key] = extract(key);
        const ids = out[key].groups.reduce((n, g) => n + g.ranks.length, 0);
        console.log(`${key} ${out[key].build}: ${out[key].groups.length} lines out of id order, ${ids} ids`);
    } catch (e) {
        console.error(`${key}: ${e.message}`);
    }
}

// One line per spell line, so a diff after a patch reads as which lines moved.
const lua = [];
lua.push(`-- Jambix AIO / rank_order -- GENERATED by tools/jcheck/ranks_extract.js from the
-- client's spell tables (SkillLine, SkillLineAbility, SkillRaceClassInfo, SpellName,
-- SpellLevels). Do not edit by hand: run it again after a client patch.
--
-- The spell lines whose ids do not rise with their levels, per client: every id
-- in each such line with the level its rank is learned at. modules/spellbook.lua
-- compares two ranks it has levels for by level, and anything else by id.
-- levels[spell id] = level`);
lua.push("return {");
for (const key of Object.keys(out)) {
    const c = out[key];
    lua.push(`    ${key} = {`);
    lua.push(`        build = ${JSON.stringify(c.build)},`);
    lua.push(`        levels = {`);
    let cls = null;
    const seen = new Set();
    for (const g of c.groups) {
        if (g.cls !== cls) { cls = g.cls; lua.push(`            -- ${cls}`); }
        const ranks = g.ranks.filter(r => !seen.has(r.id));
        ranks.forEach(r => seen.add(r.id));
        if (!ranks.length) continue;
        lua.push("            " + ranks.map(r => `[${r.id}] = ${r.level},`).join(" ") + " -- " + g.name);
    }
    lua.push(`        },`);
    lua.push(`    },`);
}
lua.push("}");
fs.writeFileSync(OUT, lua.join("\n") + "\n");
console.log("wrote " + path.relative(ROOT, OUT));

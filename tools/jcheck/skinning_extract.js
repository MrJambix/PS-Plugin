#!/usr/bin/env node
// What skinning a creature gives, and how likely each item is.
//
//   node tools/jcheck/skinning_extract.js [--sql <ClassicDB_*.sql.gz>] [--wow <install>] [--out <file>]
//        [--addons <AddOns dir>] [--qdb <questdb_extract out dir>] [--trackme <TrackMe.lua>|none]
//
// The user, 2026-10-10: "I want ESP now to show similar thing for What skinable
// corpse can give me by % if its multiple items" -- "similar" to the hunter's
// rows under a tameable beast: the item's own icon, its name, its chance.
//
// WHERE IT COMES FROM. The client has no loot tables. CMaNGOS's Classic world
// database does (github.com/cmangos/classic-db, Full_DB, GPL): every creature's
// SkinningLootId (creature_template) and that table's items, chances and
// counts (skinning_loot_template). foreverdb.net's skinning page is built on
// the same Classic data. Skinning tables are simple there, with no references
// to other tables. Most share one roll among their items (groupid 1, the
// chances add up to 100). 42 of 774 do not: a few leave a chance of nothing,
// and dragons and bosses roll some items on their own (groupid 0) or in
// several groups, so theirs add up past 100 (Gyth's to 487). Each item's
// chance is written as it is: how likely skinning is to give it. A chance of
// 0 in a group is an equal share of what the group's others leave. Forever's
// own creatures (ids past 250000) are not in it: their corpses keep the SKIN
// mark alone.
//
// Item names and quality are CMaNGOS's (item_template). Each item's icon is the
// client's own (Item.db2 IconFileDataID, Forever's client, else Era's), so the
// art pack (art_pack.js reads this file) cuts the icon the game shows in your
// bags: the cell "item.<item id>".
//
// The dump is fetched (13 MB, cached in the OS temp folder) unless --sql
// names a saved copy.
//
// PRISTINE (1.7.6). The user, 2026-10-10: "Let's add Mobs that when skined also
// give pristine cause i dont see any so far". Forever's three Scarce skinning
// materials -- Pristine Leather (249427), Pristine Hide (249428), Pristine Scale
// (249429) -- are a bonus a skin sometimes gives on top of its leather, and
// CMaNGOS has never heard of them. No site has the rates: Wowhead's Forever
// database lists the creatures it has seen give them, but answers scripts with a
// 403. Two sources do say which creatures:
//   - the QuestieDB in the Forever client (QuestieDB_Forever.toc, read through
//     questdb_extract.js): each item's npcDrops. 41 creatures of level 10 to 24
//     for the Leather at QuestieDB 1.0.5 (Goretusks, Barrens plainstriders and
//     zhevras, Darkshore bears, Loch crocolisks...), none yet for the Hide or
//     the Scale.
//   - TrackMe (a Forever addon, MaeX78), when it is installed: its SavedVariables
//     keep the player's own recent skins, each with the creature's name and what
//     it gave. Every creature one of them gave a Pristine item from is added,
//     its id found by name in QuestieDB, else in JCore's names
//     (scripts_data/jcore/jcore.names.json: Forever's own creatures). On
//     2026-10-10 that added Starving Dire Wolf and Gray Fox (277645, Forever's
//     own) to Rabid Dire Wolf, all three Duskwood: 3 of 259 skins gave 2 or 3.
//     The log rolls over, so each find is also written into SEEN below.
// Neither has a chance per creature, so the ESP says "rare".
//
// WRITTEN: scripts/jambix_aio/modules/skinning_data.lua. Do not edit it by
// hand: run this again.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");

const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");
const savedvars = require("./lib/savedvars");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "skinning_data.lua");
const ADDONS = opt("--addons") || path.join(WOW, "_classic_beta_", "Interface", "AddOns");
const DUMP = "ClassicDB_1_12_1_z2815.sql.gz";
const DUMP_URL = "https://raw.githubusercontent.com/cmangos/classic-db/master/Full_DB/" + DUMP;
const ITEM_FDID = 841626;   // DBFilesClient/Item.db2, for a root without names (Forever's)

// --- the dump ------------------------------------------------------------------------

async function dump() {
    let file = opt("--sql");
    if (!file) {
        const dir = path.join(os.tmpdir(), "jambix_cmangos");
        file = path.join(dir, DUMP);
        if (!fs.existsSync(file)) {
            fs.mkdirSync(dir, { recursive: true });
            const res = await fetch(DUMP_URL);
            if (!res.ok) throw new Error(`${DUMP_URL}: HTTP ${res.status}`);
            fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
        }
    }
    const bytes = fs.readFileSync(file);
    return { file, sql: (bytes[0] === 0x1f && bytes[1] === 0x8b ? zlib.gunzipSync(bytes) : bytes).toString("utf8") };
}

/** A table's column names, from its CREATE TABLE. */
function columns(sql, table) {
    const i = sql.indexOf("CREATE TABLE `" + table + "`");
    if (i < 0) throw new Error(`no table ${table} in the dump`);
    return [...sql.slice(i, sql.indexOf(") ENGINE", i)).matchAll(/^\s*`(\w+)`/gm)].map(m => m[1]);
}

/** Every row of a table's INSERT statements, as objects by column name. */
function rows(sql, table) {
    const cols = columns(sql, table);
    const out = [];
    const head = "INSERT INTO `" + table + "` VALUES ";
    let at = 0;
    for (;;) {
        const i = sql.indexOf(head, at);
        if (i < 0) break;
        let p = i + head.length, row = null, cur = "", inStr = false, depth = 0, quoted = false;
        const push = () => { row.push(quoted ? cur : Number(cur)); cur = ""; quoted = false; };
        for (; p < sql.length; p++) {
            const c = sql[p];
            if (inStr) {
                if (c === "\\") { cur += sql[++p]; continue; }
                if (c === "'") { inStr = false; continue; }
                cur += c;
                continue;
            }
            if (c === "'") { inStr = true; quoted = true; continue; }
            if (c === "(" && depth === 0) { depth = 1; row = []; cur = ""; quoted = false; continue; }
            if (c === "," && depth === 1) { push(); continue; }
            if (c === ")" && depth === 1) {
                push();
                const o = {};
                cols.forEach((name, k) => { o[name] = row[k]; });
                out.push(o);
                depth = 0;
                continue;
            }
            if (c === ";" && depth === 0) break;
            if (depth === 1) cur += c;
        }
        at = p;
    }
    return out;
}

// --- the client's item icons ------------------------------------------------------------

function itemIcons(ids) {
    const def = db2.loadDbd(path.join(__dirname, "dbd", "Item.dbd"));
    const icons = new Map();
    for (const product of ["wow_classic_beta", "wow_classic_era"]) {
        let casc;
        try { casc = cascLib.open({ wow: WOW, product }); } catch (e) { console.log(`  ${product}: ${e.message}`); continue; }
        try {
            let bytes;
            try { bytes = casc.read("DBFilesClient/Item.db2"); } catch (e) { bytes = casc.read(ITEM_FDID); }
            const t = db2.parse(bytes, def);
            for (const id of ids) {
                const r = t.byId.get(id);
                if (!icons.has(id) && r && r.IconFileDataID) icons.set(id, r.IconFileDataID);
            }
            console.log(`  icons from ${product} ${casc.build.version}: ${icons.size} of ${ids.length}`);
        } finally {
            casc.close();
        }
        if (icons.size === ids.length) break;
    }
    return icons;
}

// --- pristine: Forever's Scarce skinning materials (see PRISTINE) -------------------------

// All three are Uncommon (green) in the client's tooltips.
const PRISTINE = new Map([[249427, "Pristine Leather"], [249428, "Pristine Hide"], [249429, "Pristine Scale"]]);

// Creatures seen giving one that QuestieDB does not list: [npc, item, where].
// Kept by hand, because TrackMe's log only holds the latest skins and a later
// run would lose them. A run prints each new TrackMe find to add here.
const SEEN = [
    [213, 249427, "TrackMe 2026-10-10: Starving Dire Wolf, Duskwood, 1 of 43 skins gave 2"],
    [277645, 249427, "TrackMe 2026-10-10: Gray Fox, Duskwood, 1 of 4 skins gave 3"],
];

/** QuestieDB's npcs and the Pristine items' npcDrops, through questdb_extract.js. */
function questdb() {
    let dir = opt("--qdb");
    let temp = null;
    if (!dir) {
        temp = fs.mkdtempSync(path.join(os.tmpdir(), "skinning-qdb-"));
        const run = spawnSync(process.execPath, [path.join(__dirname, "questdb_extract.js"),
            "--client", "forever", "--addons", ADDONS, "--out", temp], { encoding: "utf8" });
        if (run.status !== 0) throw new Error("questdb_extract.js failed:\n" + run.stdout + run.stderr);
        dir = temp;
    }
    const read = kind => {
        const out = {};
        const d = path.join(dir, kind);
        for (const f of fs.readdirSync(d)) Object.assign(out, JSON.parse(fs.readFileSync(path.join(d, f), "utf8")));
        return out;
    };
    const npcs = read("npc"), items = read("item");
    if (temp) fs.rmSync(temp, { recursive: true, force: true });
    let version = "?";
    try {
        const toc = fs.readFileSync(path.join(ADDONS, "QuestieDB", "QuestieDB_Forever.toc"), "latin1").slice(0, 4096);
        version = (/^## Version:\s*(\S+)/m.exec(toc) || [])[1] || "?";
    } catch (e) { /* the version is a label only */ }
    const drops = new Map();
    for (const id of PRISTINE.keys()) drops.set(id, (items[id] && items[id].npcDrops) || []);
    return { npcs, drops, label: "QuestieDB " + version + " (Forever)" };
}

/** Every TrackMe.lua under the Forever client's accounts, unless --trackme says which (or none). */
function trackmeFiles() {
    const given = opt("--trackme");
    if (given) return given === "none" ? [] : [given];
    const accounts = path.join(WOW, "_classic_beta_", "WTF", "Account");
    if (!fs.existsSync(accounts)) return [];
    return fs.readdirSync(accounts)
        .map(a => path.join(accounts, a, "SavedVariables", "TrackMe.lua"))
        .filter(f => fs.existsSync(f));
}

/**
 * The player's own skins in TrackMe's log: by creature name, how many skins
 * and how many of them gave each Pristine item. A skin is logged under the
 * session and again under the journal; it is counted once.
 */
function trackme(files) {
    const byName = new Map();
    const seen = new Set();
    for (const file of files) {
        const vars = savedvars.read(fs.readFileSync(file, "utf8"));
        const visited = new Set();
        (function walk(o) {
            if (!o || typeof o !== "object" || visited.has(o)) return;
            visited.add(o);
            if (o.actionKey === "Gather:Skinning" && typeof o.source === "string" && o.items) {
                const key = [o.ts, o.source, JSON.stringify(o.items)].join("|");
                if (!seen.has(key)) {
                    seen.add(key);
                    if (!byName.has(o.source)) byName.set(o.source, { skins: 0, gave: new Map() });
                    const b = byName.get(o.source);
                    b.skins++;
                    for (const id of PRISTINE.keys()) {
                        if (o.items[id]) b.gave.set(id, (b.gave.get(id) || 0) + 1);
                    }
                }
                return;
            }
            for (const k of Object.keys(o)) walk(o[k]);
        })(vars.TrackMeDB);
    }
    return byName;
}

/** pristine[npc] = { items: Set, why: [text] }, from QuestieDB and TrackMe. */
function pristine() {
    const q = questdb();
    const out = new Map();
    const add = (npc, item, why) => {
        if (!out.has(npc)) out.set(npc, { items: new Set(), why: [] });
        const p = out.get(npc);
        p.items.add(item);
        if (!p.why.includes(why)) p.why.push(why);
    };
    for (const [item, npcs] of q.drops) for (const npc of npcs) add(npc, item, "QuestieDB");
    for (const [npc, item, where] of SEEN) add(npc, item, where);
    // A name to its npc ids: QuestieDB's, else the names JCore has met.
    const ids = new Map();
    for (const [id, n] of Object.entries(q.npcs)) {
        if (!n.name) continue;
        if (!ids.has(n.name)) ids.set(n.name, []);
        ids.get(n.name).push(Number(id));
    }
    let jnames = {};
    try { jnames = JSON.parse(fs.readFileSync(path.join(ROOT, "scripts_data", "jcore", "jcore.names.json"), "utf8")).npcs || {}; } catch (e) { /* none */ }
    const files = trackmeFiles();
    const mine = trackme(files);
    const unknown = [];
    for (const [name, b] of mine) {
        if (!b.gave.size) continue;
        let found = ids.get(name);
        if (!found) found = Object.entries(jnames).filter(([, n]) => n === name).map(([id]) => Number(id));
        if (!found.length) { unknown.push(name); continue; }
        for (const [item, n] of b.gave) {
            for (const npc of found) {
                if (SEEN.some(s => s[0] === npc && s[1] === item)) continue;
                const known = out.has(npc) && out.get(npc).items.has(item);
                add(npc, item, `TrackMe: ${n} of ${b.skins} skins`);
                if (!known) console.log(`  TrackMe: new, add it to SEEN: [${npc}, ${item}, "TrackMe <date>: ${name}, ${n} of ${b.skins} skins"]`);
            }
        }
    }
    const names = new Map();
    for (const npc of out.keys()) {
        const n = q.npcs[npc];
        names.set(npc, (n && n.name) || jnames[npc] || "");
    }
    console.log(`  pristine: ${out.size} creatures (${q.label}; TrackMe: ${files.length} file(s), ${mine.size} creatures skinned)` +
        (unknown.length ? `; no npc id for ${unknown.join(", ")}` : ""));
    return { list: out, names, label: q.label, trackme: files.length > 0 };
}

// --- the tables ---------------------------------------------------------------------------

/** One table's items with each one's chance: a group's 0-chance rows share what is left. */
function chances(list) {
    const groups = new Map();
    for (const r of list) {
        if (r.condition_id) continue;               // quest-bound: not every skinner's
        if (r.mincountOrRef < 0) throw new Error(`table ${r.entry} references ${-r.mincountOrRef}: not handled`);
        const g = r.groupid || 0;
        if (!groups.has(g)) groups.set(g, []);
        groups.get(g).push(r);
    }
    const out = [];
    for (const [g, list2] of groups) {
        const explicit = list2.filter(r => r.ChanceOrQuestChance > 0);
        const zero = list2.filter(r => !(r.ChanceOrQuestChance > 0));
        const left = Math.max(0, 100 - explicit.reduce((a, r) => a + r.ChanceOrQuestChance, 0));
        for (const r of list2) {
            const pct = r.ChanceOrQuestChance > 0 ? r.ChanceOrQuestChance : (g ? left / zero.length : 100);
            out.push({ item: r.item, pct, min: Math.max(1, r.mincountOrRef || 1), max: Math.max(1, r.maxcount || 1) });
        }
    }
    return out.sort((a, b) => b.pct - a.pct || a.item - b.item);
}

const lua = s => JSON.stringify(String(s));
const pct = v => {
    const r = Math.round(v * 10) / 10;
    return Number.isInteger(r) ? String(r) : r.toFixed(1);
};

async function main() {
    const { file, sql } = await dump();
    const creatures = rows(sql, "creature_template");
    const skin = rows(sql, "skinning_loot_template");
    const items = new Map(rows(sql, "item_template").map(r => [r.entry, r]));

    const tables = new Map();
    for (const r of skin) {
        if (!tables.has(r.entry)) tables.set(r.entry, []);
        tables.get(r.entry).push(r);
    }
    const loot = new Map(), alias = new Map(), named = new Map();
    for (const c of creatures) {
        const id = c.SkinningLootId;
        if (!id || !tables.has(id)) continue;
        if (!loot.has(id)) loot.set(id, chances(tables.get(id)));
        if (id !== c.Entry) alias.set(c.Entry, id);
        if (!named.has(id) || c.Entry === id) named.set(id, c.Name);
    }
    const used = new Set();
    for (const list of loot.values()) for (const r of list) used.add(r.item);
    const prist = pristine();
    for (const p of prist.list.values()) for (const id of p.items) used.add(id);
    const ids = [...used].sort((a, b) => a - b);
    const icons = itemIcons(ids);

    const out = [];
    out.push("-- Jambix AIO / skinning_data -- GENERATED by tools/jcheck/skinning_extract.js from");
    out.push("-- CMaNGOS's Classic world database (skinning_loot_template, creature_template,");
    out.push("-- item_template) and the client's Item.db2 for the icons. Do not edit by hand: run");
    out.push("-- it again.");
    out.push("--");
    out.push("-- items[item id] = { name, quality (0 grey .. 5 orange), icon (FileDataID; the art");
    out.push("--                   pack's \"item.<item id>\" cell) }");
    out.push("-- loot[table id] = { { item id, chance (%), min, max (count; 1 when left out) }, ... },");
    out.push("--                   most likely first. A table's id is its creature's npc id, unless");
    out.push("-- alias[npc id] = table id says otherwise.");
    out.push("-- pristine[npc id] = { item id, ... }: Forever's Pristine Leather, Hide or Scale, a");
    out.push("--                   rare bonus on top of the leather. Seen in the Forever client's");
    out.push("--                   QuestieDB, or in the player's own skins (TrackMe's log); no chance.");
    out.push("-- esp/forever.lua lists them under a corpse your Skinning can take, and the");
    out.push("-- pristine ones under the living creature too.");
    out.push("return {");
    out.push(`    source = ${lua("cmangos/classic-db Full_DB " + path.basename(file))},`);
    out.push(`    pristine_source = ${lua(prist.label + (prist.trackme ? " + TrackMe" : ""))},`);
    out.push(`    count = { npcs = ${[...creatures].filter(c => c.SkinningLootId && loot.has(c.SkinningLootId)).length}, tables = ${loot.size}, items = ${ids.length}, pristine = ${prist.list.size} },`);
    out.push("    items = {");
    for (const id of ids) {
        const it = items.get(id) || {};
        const icon = icons.get(id);
        const name = PRISTINE.get(id) || it.name || ("item " + id);
        const quality = PRISTINE.has(id) ? 2 : (it.Quality || 0);
        out.push(`        [${id}] = { name = ${lua(name)}, quality = ${quality}${icon ? `, icon = ${icon}` : ""} },`);
    }
    out.push("    },");
    out.push("    loot = {");
    for (const id of [...loot.keys()].sort((a, b) => a - b)) {
        const parts = loot.get(id).map(r => r.min === 1 && r.max === 1
            ? `{ ${r.item}, ${pct(r.pct)} }` : `{ ${r.item}, ${pct(r.pct)}, ${r.min}, ${r.max} }`);
        out.push(`        [${id}] = { ${parts.join(", ")} }, -- ${named.get(id) || ""}`);
    }
    out.push("    },");
    out.push("    alias = {");
    for (const npc of [...alias.keys()].sort((a, b) => a - b)) out.push(`        [${npc}] = ${alias.get(npc)},`);
    out.push("    },");
    out.push("    pristine = {");
    for (const npc of [...prist.list.keys()].sort((a, b) => a - b)) {
        const p = prist.list.get(npc);
        const list = [...p.items].sort((a, b) => a - b).join(", ");
        out.push(`        [${npc}] = { ${list} }, -- ${prist.names.get(npc)} (${p.why.join("; ")})`);
    }
    out.push("    },");
    out.push("}");
    out.push("");
    fs.writeFileSync(OUT, out.join("\n"));
    const missing = ids.filter(id => !icons.has(id));
    console.log(`written ${path.relative(ROOT, OUT)}: ${loot.size} tables, ${alias.size} aliases, ${ids.length} items, ${prist.list.size} pristine` +
        (missing.length ? `; no icon for ${missing.join(", ")}` : ""));
}

main().catch(err => { console.error(err.stack || String(err)); process.exit(1); });

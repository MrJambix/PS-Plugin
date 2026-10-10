#!/usr/bin/env node
// Every rare the Forever world is known to have, Classic's included.
//
//   node tools/jcheck/rares_extract.js [--addons <AddOns dir>] [--qdb <questdb_extract out dir>] [--out <file>]
//
// The user, 2026-10-09: "I wanna pull up a list of all Forever Rare Mobs
// (includes classic) and tag them in ESP with RARE". The Forever ESP took a
// mob's rank from the client's creature cache alone, and the cache only holds
// what earlier sessions saw (a new build wipes it), so a rare met for the first
// time was drawn as a normal mob. This list is what the ESP falls back on.
//
// THE CLASSIC RARES come from the QuestieDB in the Forever client
// (QuestieDB_Forever.toc), read through questdb_extract.js: every npc whose
// `rank` is 4 (rare) or 2 (rare elite). 398 at build 1.60.1.70291. The Era
// client's QuestieDB gives the same ranks for every id both have.
// foreverdb.net/rares (354 rares, CMaNGOS ranks, checked 2026-10-09) is a
// subset of it; the 44 it leaves out are mostly dungeon and event rares
// (Miner Johnson, Skul, Stonespine, the Blasted Lands trio), kept here.
//
// FOREVER'S OWN RARES carry no rank in QuestieDB (none of its 3,116 Forever
// creatures has one), so they are listed by hand below, each with where it was
// seen. Ids are QuestieDB's, found by name. Some of Season of Discovery's rares
// are in Forever's world too; those are listed the same way (their ids are
// SoD's, in QuestieDB's sodBaseNPCs.lua). Add to the lists as more are found:
// the recorder's catalog (scripts_data/jcore/jcore.catalog.json, npcs with
// classification 2 or 4) is the place to look.
//
// WRITTEN: scripts/jambix_aio/modules/rares_data.lua. Do not edit it by hand:
// edit the lists here and run this again.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const ADDONS = opt("--addons") || "C:/Program Files (x86)/World of Warcraft/_classic_beta_/Interface/AddOns";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "rares_data.lua");

// Forever's own rares: [id, rank, min level, max level, where it was seen].
// Rank 4 rare, 2 rare elite. Names and zones come from QuestieDB.
//   wclbox    wowforever.wclbox.com/en/xiyou ("Rare, new in Forever")
//   mmonster  mmonster.co/wow-forever/guides/hunter-pets/rare-pets
//   recorder  JCore's recorder read get_classification 4 in the game
//   gamewave  gamewave.fr's Wetlands ring guide (rank not given: rare assumed)
const FOREVER = [
    [276109, 4, 10, 10, "wclbox"],                       // Snarlsnout, Mulgore
    [276101, 4, 10, 10, "wclbox, mmonster"],             // Nightscreech, Teldrassil
    [271080, 4, 10, 10, "wclbox"],                       // Blightsculler, Tirisfal Glades
    [276111, 4, 10, 10, "mmonster"],                     // Ghostfang, Dun Morogh
    [276189, 4, 10, 10, "recorder, mmonster"],           // Matriarch Bristlefur, Elwynn Forest
    [276198, 4, 9, 9, "mmonster"],                       // Shal'ma, Durotar
    [274300, 4, 12, 12, "mmonster"],                     // Coldrasp, Tirisfal Glades
    [256492, 4, 10, 10, "wclbox, mmonster"],             // Fernfeather, Zephras Isle
    [259398, 4, 11, 11, "wclbox"],                       // Galemender Delanea, Zephras Isle
    [250936, 4, 13, 13, "wclbox"],                       // Den'dralass, Zephras Isle
    [259388, 4, 13, 13, "wclbox, mmonster"],             // Mystmane, Zephras Isle
    [259385, 4, 13, 13, "wclbox"],                       // Tel'daeor the Stormspeaker, Zephras Isle
    [255887, 2, 0, 0, "wclbox, mmonster"],               // Slydris, Zephras Isle
    [259394, 2, 0, 0, "wclbox"],                         // Snapbeak the Quick, Zephras Isle
    [270589, 4, 31, 32, "gamewave"],                     // Nightveiled Rotheap, Wetlands
];

// Season of Discovery's rares in Forever's world (mmonster's rare pets list),
// with SoD's names for the three Forever's QuestieDB does not have.
const SOD = [
    [205382, 4, 7, 7, "mmonster", "Mokwa", 215],
    [208124, 4, 7, 7, "mmonster"],                       // Raluk, Durotar
    [208812, 4, 8, 8, "mmonster"],                       // Jorul, Dun Morogh
    [209928, 4, 8, 8, "mmonster"],                       // Mowgh, Teldrassil
    [210107, 4, 15, 16, "mmonster", "Kackle", 38],
    [211951, 4, 25, 25, "mmonster"],                     // Koartul, Hillsbrad Foothills
    [211965, 4, 25, 25, "mmonster"],                     // Carrodin, Wetlands
    [222243, 4, 43, 43, "mmonster", "Zopilote", 440],
];

// --- QuestieDB's npcs ------------------------------------------------------------

function questdb() {
    let dir = opt("--qdb");
    let temp = null;
    if (!dir) {
        temp = fs.mkdtempSync(path.join(os.tmpdir(), "rares-qdb-"));
        const run = spawnSync(process.execPath, [path.join(__dirname, "questdb_extract.js"),
            "--client", "forever", "--addons", ADDONS, "--out", temp], { encoding: "utf8" });
        if (run.status !== 0) throw new Error("questdb_extract.js failed:\n" + run.stdout + run.stderr);
        dir = temp;
    }
    const npcs = {};
    const npcDir = path.join(dir, "npc");
    for (const f of fs.readdirSync(npcDir)) {
        const bucket = JSON.parse(fs.readFileSync(path.join(npcDir, f), "utf8"));
        for (const [id, row] of Object.entries(bucket)) npcs[id] = row;
    }
    if (temp) fs.rmSync(temp, { recursive: true, force: true });
    // The addon's own version, from the TOC the data was read from.
    let version = "?";
    try {
        const toc = fs.readFileSync(path.join(ADDONS, "QuestieDB", "QuestieDB_Forever.toc"), "latin1").slice(0, 4096);
        version = (/^## Version:\s*(\S+)/m.exec(toc) || [])[1] || "?";
    } catch (e) { /* the version is a label only */ }
    return { npcs, build: "QuestieDB " + version + " (Forever)" };
}

// --- zone names ----------------------------------------------------------------------
//
// QuestieDB's zone ids are AreaTable ids. Its map tables name each one in a
// comment ("[12] = 1429, -- Elwynn Forest"), and dungeons.lua names the
// instances.

// QuestieDB's synthetic ids for a whole continent: the zone only when nothing
// nearer is known (Scarshield Quartermaster).
const CONTINENT = { 10073: "Kalimdor", 10074: "Eastern Kingdoms" };

function zoneNames() {
    const names = {};
    const db = path.join(ADDONS, "QuestieDB", "support");
    for (const file of ["Zones/areaIdToUiMapId.lua", "Forever/Zones/areaIdToUiMapId.lua"]) {
        const p = path.join(db, file);
        if (!fs.existsSync(p)) continue;
        for (const m of fs.readFileSync(p, "utf8").matchAll(/^\s*\[(\d+)\]\s*=\s*\d+,\s*--\s*(.+?)\s*$/gm)) {
            if (!/^(Referenced|Synthetic|Existing|Legacy|Deeprun|Hall of|Champions)|continent map/.test(m[2])) names[m[1]] = m[2];
        }
    }
    const dungeons = path.join(db, "Zones", "dungeons.lua");
    if (fs.existsSync(dungeons)) {
        for (const m of fs.readFileSync(dungeons, "utf8").matchAll(/^\s*\[(\d+)\]\s*=\s*\{"([^"]+)",(?:nil|\{([\d,]*)\})/gm)) {
            names[m[1]] = m[2];
            for (const alt of (m[3] || "").split(",").filter(Boolean)) names[alt] = m[2];
        }
    }
    return names;
}

// --- the list --------------------------------------------------------------------------

function build() {
    const { npcs, build } = questdb();
    const zones = zoneNames();
    const rows = new Map();
    // Its zone, else the first zone it spawns in that has a name.
    const zoneOf = (row, fallback) => {
        const ids = [];
        if (row && row.zoneID) ids.push(row.zoneID);
        if (row && row.spawns) ids.push(...Object.keys(row.spawns).map(Number).filter(k => k > 0));
        if (fallback) ids.push(fallback);
        for (const z of ids) if (zones[z]) return zones[z];
        for (const z of ids) if (CONTINENT[z]) return CONTINENT[z];
        return ids.length ? "zone " + ids[0] : "No known spawn";
    };

    for (const [id, row] of Object.entries(npcs)) {
        if (row.rank !== 4 && row.rank !== 2) continue;
        rows.set(+id, {
            id: +id, name: row.name, rank: row.rank,
            min: row.minLevel || 0, max: row.maxLevel || row.minLevel || 0,
            zone: zoneOf(row), from: "classic",
        });
    }
    const hand = (list, from) => {
        for (const [id, rank, min, max, seen, name, zone] of list) {
            const row = npcs[id];
            if (!row && !name) throw new Error(`${from} rare ${id} is not in QuestieDB and has no name here`);
            rows.set(id, {
                id, name: (row && row.name) || name, rank,
                min: min || (row && row.minLevel) || 0, max: max || (row && row.maxLevel) || min || 0,
                zone: zoneOf(row, zone), from, seen,
            });
        }
    };
    hand(SOD, "sod");
    hand(FOREVER, "forever");
    return { rows: [...rows.values()], build };
}

// --- Lua -------------------------------------------------------------------------------

const lua = s => JSON.stringify(String(s));

function write() {
    const { rows, build: qdbBuild } = build();
    rows.sort((a, b) => a.zone.localeCompare(b.zone) || a.min - b.min || a.name.localeCompare(b.name) || a.id - b.id);
    const count = { classic: 0, sod: 0, forever: 0, rare: 0, rare_elite: 0 };
    for (const r of rows) {
        count[r.from]++;
        count[r.rank === 2 ? "rare_elite" : "rare"]++;
    }
    const out = [];
    out.push("-- Jambix AIO / rares_data -- GENERATED by tools/jcheck/rares_extract.js from the");
    out.push("-- QuestieDB in the Forever client (npc rank 4 rare, 2 rare elite) and that script's");
    out.push("-- own lists of Forever's and Season of Discovery's rares. Do not edit by hand: add");
    out.push("-- to the lists there and run it again.");
    out.push("--");
    out.push("-- rares[npc id] = { name, rank (4 rare, 2 rare elite), min, max (level; 0 unknown),");
    out.push("--                   zone, from (\"classic\", \"sod\" or \"forever\"), seen (where a");
    out.push("--                   hand-listed one was found) }");
    out.push("-- esp/forever.lua marks one of these RARE when the game itself gives no rank for it.");
    out.push("return {");
    out.push(`    questdb = ${lua(qdbBuild)},`);
    out.push(`    count = { total = ${rows.length}, classic = ${count.classic}, sod = ${count.sod}, forever = ${count.forever}, rare = ${count.rare}, rare_elite = ${count.rare_elite} },`);
    out.push("    rares = {");
    let zone = null;
    for (const r of rows) {
        if (r.zone !== zone) {
            zone = r.zone;
            out.push(`        -- ${zone}`);
        }
        const fields = [`name = ${lua(r.name)}`, `rank = ${r.rank}`, `min = ${r.min}`, `max = ${r.max}`,
            `zone = ${lua(r.zone)}`, `from = ${lua(r.from)}`];
        if (r.seen) fields.push(`seen = ${lua(r.seen)}`);
        out.push(`        [${r.id}] = { ${fields.join(", ")} },`);
    }
    out.push("    },");
    out.push("}");
    out.push("");
    fs.writeFileSync(OUT, out.join("\n"));
    console.log(`written ${OUT}: ${rows.length} rares (${count.rare} rare, ${count.rare_elite} rare elite; ` +
        `${count.classic} classic, ${count.sod} sod, ${count.forever} forever) from QuestieDB ${qdbBuild}`);
}

write();

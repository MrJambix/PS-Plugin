#!/usr/bin/env node
// What each tameable beast teaches, from Petopia's pet ability pages.
//
//   node tools/jcheck/petopia_extract.js [--forever <html>] [--classic <html>] [--out <file>]
//
// The user, 2026-10-09: "I'd like an ESP on beasts as a Hunter class that
// shows me the image and name of the ability and rank it is that Im looking
// at ... use this as refrence (its for Forever)
// https://www.wow-petopia.com/classic/abilities.php#dismember".
//
// WHY PETOPIA. The client knows a beast's family, so the skills its family
// can learn (beasts_extract.js), but never which of them one beast carries:
// not every cat has Prowl. Petopia lists, for every rank of every ability,
// the beasts known to teach it, by npc id. Two pages, one layout:
//   forever  https://www.wow-petopia.com/forever/abilities.php
//            Forever's own skills (Dismember, Savage Rend, Tendon Rip, Web,
//            Mine!...) say "No known training source" for every rank: nobody
//            has found which beast teaches them yet.
//   vanilla  https://www.wow-petopia.com/classic/abilities.php (Era)
// The /classic/ URL the user gave is the Era page; Dismember is only on the
// /forever/ one. Every npc either lists is a Classic creature (all ids under
// 20000 on 2026-10-09): Petopia does not cover Forever's or Season of
// Discovery's new beasts.
//
// The pages are fetched unless a saved copy is given. Plain HTTP works; the
// abilities page needs no script (the family pages fill their npc lists by
// script, so they are no use here).
//
// WRITTEN: scripts/jambix_aio/modules/petopia_data.lua. Do not edit it by
// hand: run this again.
//
// NO ICONS. Petopia's icon names are not always the game's: its Bite is the
// druid's Ferocious Bite (the pet's own is Ability_Racial_Cannibalize) and
// Forever's Demoralizing Screech the bat's. The user, 2026-10-10: "The Games
// own Skill Icon like Bite should be Bites Icons". The ESP draws the client's
// own icon (beasts_extract.js reads SpellMisc), so none is written here.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "petopia_data.lua");

const PAGES = [
    { key: "forever", url: "https://www.wow-petopia.com/forever/abilities.php", file: opt("--forever") },
    { key: "vanilla", url: "https://www.wow-petopia.com/classic/abilities.php", file: opt("--classic") },
];

// --- the page ------------------------------------------------------------------

const ENTITY = { amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " " };
function text(html) {
    return html.replace(/<[^>]*>/g, "")
        .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
        .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
        .replace(/&(\w+);/g, (m, n) => ENTITY[n] ?? m)
        .replace(/\s+/g, " ").trim();
}

/** The skills under "Learned from wild creatures:" in the page's index. */
function wildSkills(html) {
    const a = html.indexOf("Learned from wild creatures");
    const b = html.indexOf("Learned from the trainer", a);
    if (a < 0 || b < 0) throw new Error("no 'Learned from wild creatures' index");
    const names = new Set();
    for (const m of html.slice(a, b).matchAll(/<a [^>]*>(?:<img[^>]*>)?([^<]+)<\/a>/g)) names.add(text(m[1]));
    return names;
}

function parse(html) {
    const wild = wildSkills(html);
    const skills = {}, npcs = new Map();
    // One <h3> per ability, then its <ul> of ranks.
    const heads = [...html.matchAll(/<h3 class='guide_heading[^']*' id='([^']+)'><img [^>]*src='\/images\/icons\/([^'.]+)\.png'>([^<]+)<\/h3>/g)];
    if (heads.length < 10) throw new Error(`only ${heads.length} abilities found: has the page changed?`);
    heads.forEach((h, i) => {
        const name = text(h[3]);
        const body = html.slice(h.index, i + 1 < heads.length ? heads[i + 1].index : html.length);
        const skill = { wild: wild.has(name), ranks: [] };
        const ranks = [...body.matchAll(/<li id='[^']+' class='abilityrank[^']*'>/g)];
        ranks.forEach((r, j) => {
            const part = body.slice(r.index, j + 1 < ranks.length ? ranks[j + 1].index : body.length);
            const head = part.match(/<span class='abilityrankname[^']*'>([^<]+)<\/span>: Pet Level (\d+), Cost (\d+) TP/);
            if (!head) throw new Error(`${name}: a rank without "Pet Level, Cost": ${text(part).slice(0, 80)}`);
            const rank = Number(text(head[1]).match(/(\d+)$/)?.[1] || j + 1);
            const source = text(part.match(/<span class='abilitysourceheading[^']*'>([^<]*)<\/span>/)?.[1] || "");
            const from = /taming/i.test(source) ? "beast" : /trainer/i.test(source) ? "trainer" : "unknown";
            skill.ranks[rank - 1] = { level: Number(head[2]), tp: Number(head[3]), from };
            for (const n of part.matchAll(/<li class='abilityranknpc[^']*'><a [^>]*href='[^']*npc=(\d+)'>([^<]+)<\/a> \(([^)]*(?:\([^)]*\))?[^)]*)\)<\/li>/g)) {
                const id = Number(n[1]);
                const fields = text(n[3]).split(", ");
                const family = fields.shift() || "";
                const levels = (fields.shift() || "").split("-").map(Number).filter(Number.isFinite);
                const zone = fields.join(", ");
                let row = npcs.get(id);
                if (!row) {
                    row = { id, name: text(n[2]), family, min: levels[0] || 0, max: levels[1] || levels[0] || 0, zone, teaches: {} };
                    npcs.set(id, row);
                }
                const had = row.teaches[name];
                if (had && had !== rank) console.log(`  ${row.name} (${id}) teaches ${name} ${had} and ${rank}: kept the higher`);
                row.teaches[name] = Math.max(had || 0, rank);
            }
        });
        // Not every skill starts at rank 1: Slower Attack is ranks 2 and 3,
        // as in the client. The Lua keeps each rank's own number.
        if (!skill.ranks.some(Boolean)) throw new Error(`${name}: no ranks`);
        skills[name] = skill;
    });
    return { skills, npcs: [...npcs.values()].sort((a, b) => a.id - b.id) };
}

async function load(page) {
    if (page.file) return fs.readFileSync(page.file, "utf8");
    const res = await fetch(page.url, { headers: { "User-Agent": "Mozilla/5.0 (jambix petopia_extract)" } });
    if (!res.ok) throw new Error(`${page.url}: HTTP ${res.status}`);
    return res.text();
}

// --- Lua -------------------------------------------------------------------------

const lua = s => JSON.stringify(String(s));
const key = s => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s) ? s : `[${lua(s)}]`;

async function main() {
    const today = new Date().toISOString().slice(0, 10);
    const out = [];
    out.push("-- Jambix AIO / petopia_data -- GENERATED by tools/jcheck/petopia_extract.js from");
    out.push("-- Petopia's pet ability pages (wow-petopia.com/forever/ and /classic/abilities.php).");
    out.push("-- Do not edit by hand: run it again.");
    out.push("--");
    out.push("-- skills[name] = { wild (beasts teach it, not the trainer),");
    out.push("--                  ranks = { [rank] = { level, tp, from } } }");
    out.push("--   from: \"beast\" (some beast is known to teach that rank), \"trainer\", or");
    out.push("--         \"unknown\" (no known source: Forever's own skills, so far)");
    out.push("-- npcs[npc id] = { name, family, min, max (level), zone, teaches = { [skill] = rank } }");
    out.push("-- modules/tame.lua reads it. No icons: the ESP draws the game's own (beasts_data).");
    out.push("return {");
    const counts = [];
    for (const page of PAGES) {
        const { skills, npcs } = parse(await load(page));
        const names = Object.keys(skills).sort();
        out.push(`    ${page.key} = {`);
        out.push(`        source = ${lua(page.url)},`);
        out.push(`        fetched = ${lua(page.file ? "saved copy, " + today : today)},`);
        out.push("        skills = {");
        for (const n of names) {
            const s = skills[n];
            const ranks = [];
            s.ranks.forEach((r, k) => { if (r) ranks.push(`[${k + 1}] = { level = ${r.level}, tp = ${r.tp}, from = ${lua(r.from)} }`); });
            out.push(`            ${key(n)} = { wild = ${s.wild}, ranks = {`);
            for (const r of ranks) out.push(`                ${r},`);
            out.push("            } },");
        }
        out.push("        },");
        out.push("        npcs = {");
        for (const r of npcs) {
            const teaches = Object.keys(r.teaches).sort().map(n => `${key(n)} = ${r.teaches[n]}`).join(", ");
            out.push(`            [${r.id}] = { name = ${lua(r.name)}, family = ${lua(r.family)}, min = ${r.min}, max = ${r.max}, ` +
                `zone = ${lua(r.zone)}, teaches = { ${teaches} } },`);
        }
        out.push("        },");
        out.push("    },");
        const wild = names.filter(n => skills[n].wild).length;
        const unknown = names.filter(n => skills[n].ranks.filter(Boolean).every(r => r.from === "unknown")).length;
        counts.push(`${page.key}: ${names.length} skills (${wild} from beasts, ${unknown} with no known source), ${npcs.length} npcs`);
    }
    out.push("}");
    out.push("");
    fs.writeFileSync(OUT, out.join("\n"));
    console.log(`written ${path.relative(ROOT, OUT)}`);
    for (const c of counts) console.log("  " + c);
}

main().catch(err => { console.error(err.stack || String(err)); process.exit(1); });

#!/usr/bin/env node
// Compares JCore loot studies (services/lootstudy.lua, JCore 1.6.8) from
// several clients, side by side: how each client marks a corpse that has loot,
// and how a loot window gets opened there.
//
//   node tools/jcheck/lootstudy_diff.js scripts_data/jcore/jcore.lootstudy.forever.json \
//        scripts_data/jcore/jcore.lootstudy.vanilla.json \
//        scripts_data/jcore/jcore.lootstudy.retail.json [--md [out.md]]
//
// One file is enough for a report of that client alone. The user (2026-10-03):
// "experiment the way SoD does it, Retail does it" -- Forever is the classic
// world on the retail engine, so this says which of the two it follows.
// Season of Discovery runs the Vanilla client and writes the "vanilla" file
// (Era and Hardcore do too; they cannot be told apart). With --md the report is
// also written as Markdown (default scripts/jambix_debug/LOOT_STUDY.md).
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const args = process.argv.slice(2);
const files = args.filter(a => !a.startsWith("--") && a.endsWith(".json"));
const mdIndex = args.indexOf("--md");
const mdOut = mdIndex >= 0 ? (args[mdIndex + 1] && !args[mdIndex + 1].startsWith("--") && !args[mdIndex + 1].endsWith(".json")
    ? args[mdIndex + 1] : path.join(ROOT, "scripts", "jambix_debug", "LOOT_STUDY.md")) : null;
if (files.length < 1) {
    console.error("usage: lootstudy_diff.js <study.json> [more studies...] [--md [out.md]]");
    process.exit(2);
}

const studies = files.map(f => {
    const doc = JSON.parse(fs.readFileSync(path.resolve(f), "utf8"));
    doc._name = String(doc.client && doc.client !== "nil" ? doc.client : path.basename(f));
    return doc;
});
const names = studies.map(s => s._name);
const list = v => Array.isArray(v) ? v : [];
const lines = [];
const out = s => lines.push(s);

/** A table: one row per key, one column per client. */
function table(title, rowsByClient, note) {
    out(`\n## ${title}\n`);
    if (note) out(note + "\n");
    const keys = new Set();
    for (const m of rowsByClient) for (const k of Object.keys(m)) keys.add(k);
    if (keys.size === 0) { out("_nothing recorded_"); return; }
    const sorted = [...keys].sort((a, b) => {
        const na = rowsByClient.reduce((t, m) => t + (typeof m[a] === "number" ? m[a] : 0), 0);
        const nb = rowsByClient.reduce((t, m) => t + (typeof m[b] === "number" ? m[b] : 0), 0);
        return nb - na || a.localeCompare(b);
    });
    out(`| | ${names.join(" | ")} |`);
    out(`|---|${names.map(() => "---").join("|")}|`);
    for (const k of sorted) out(`| ${k} | ${rowsByClient.map(m => m[k] ?? "").join(" | ")} |`);
}

const add = (m, k, n = 1) => { m[k] = (m[k] || 0) + n; };

// --- the clients ----------------------------------------------------------------

out("# Loot study: how a corpse with loot is marked, and how it is opened\n");
out(`| | ${names.join(" | ")} |`);
out(`|---|${names.map(() => "---").join("|")}|`);
out(`| build | ${studies.map(s => s.exact).join(" | ")} |`);
out(`| JCore | ${studies.map(s => s.jcore).join(" | ")} |`);
out(`| corpses studied | ${studies.map(s => list(s.corpses).length).join(" | ")} |`);
out(`| loot windows | ${studies.map(s => list(s.windows).length).join(" | ")} |`);
out(`| corpses seen die | ${studies.map(s => list(s.corpses).filter(c => c.seen_die).length).join(" | ")} |`);

// --- how windows were opened ---------------------------------------------------------

table("Who opened each loot window", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) add(m, w.source || "?");
    return m;
}), "\"ours\" is a press of JCore's loot.open (the AIO's auto-loot); \"player\" is a window nobody pressed for, put down to what pointed at a corpse.");

table("LOOT_OPENED events per window", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) add(m, `${w.events ?? "1 (before 1.6.10, not counted)"} event(s)`);
    return m;
}), "Forever sends two for every window; the second is folded into the first since JCore 1.6.10.");

table("What pointed at the corpse when the player opened it", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) {
        if (!String(w.source || "").startsWith("player")) continue;
        add(m, "(player windows)");
        for (const [name, p] of Object.entries(w.pointers || {})) {
            if (p && w.corpse && p.guid === w.corpse) add(m, name);
        }
    }
    return m;
}), "Per pointer: in how many of the player's windows it named the corpse the window came from. The mouse means a right-click; softinteract means the interact key.");

table("Our presses that brought a window", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) {
        const p = w.our_press;
        if (!p) continue;
        add(m, `${p.call} (${p.kind})${p.walked ? ", walked there" : ""}`);
    }
    return m;
}));

table("How long our press took to bring its window (s)", studies.map(s => {
    const m = {};
    const by = {};
    for (const w of list(s.windows)) {
        const p = w.our_press;
        if (!p || !String(w.source || "").startsWith("ours")) continue;
        const k = `${p.call}${p.walked ? " (walked)" : ""}`;
        (by[k] = by[k] || []).push(Number(p.seconds_before) || 0);
    }
    for (const [k, v] of Object.entries(by)) {
        v.sort((a, b) => a - b);
        m[k] = `${v.length}x, median ${v[Math.floor(v.length / 2)].toFixed(2)}, max ${v[v.length - 1].toFixed(2)}`;
    }
    return m;
}));

table("Our presses that brought nothing", studies.map(s => {
    const m = {};
    for (const x of list(s.summary && s.summary.missed)) m[x.what] = x.n;
    return m;
}), "Each with whether it walked, whether the corpse was targeted first (JCore 1.6.11), and what the target was when it was given up. The file's misses list has each one's events.");

// --- which read marks a corpse with loot ---------------------------------------------

const reads = [...new Set(studies.flatMap(s => list(s.reads)))];

table("Every change of a corpse read, and the moment it came", studies.map(s => {
    const m = {};
    for (const c of list(s.summary && s.summary.changes)) m[c.what] = c.n;
    return m;
}), "\"window open\": while a window from that corpse was open; \"after window\": within 3 s of it closing; \"at death\": within 2 s of it being seen alive; \"skinning\": within 6 s of a skinning cast on it.");

out("\n## First reads: corpses later opened against corpses never opened\n");
out("A read that tells loot apart answers one way on the first and the other on the second.\n");
out(`| read | ${names.map(n => `${n}: opened | ${n}: never`).join(" | ")} |`);
out(`|---|${names.map(() => "---|---").join("|")}|`);
const fmt = m => m ? Object.entries(m).sort((a, b) => b[1] - a[1]).map(([v, n]) => `${v} ${n}`).join(", ") : "";
for (const r of reads) {
    out(`| ${r} | ${studies.map(s => {
        const f = (s.summary && s.summary.first_reads) || {};
        return `${fmt(f.opened && f.opened[r])} | ${fmt(f.never_opened && f.never_opened[r])}`;
    }).join(" | ")} |`);
}

table("The corpse after its window closed: has_loot / can_be_looted", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) {
        for (const a of list(w.after)) {
            if (!a || typeof a.reads !== "object") { add(m, `+${a && a.after}s gone`); continue; }
            add(m, `+${a.after}s has_loot=${a.reads.has_loot} can_be_looted=${a.reads.can_be_looted}`);
        }
    }
    return m;
}));

// --- the slots -------------------------------------------------------------------

table("Loot slots: which index answers", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) {
        for (const read of list(w.slots)) {
            const count = Number(read.count) || 0;
            if (count === 0) continue;
            for (const slot of list(read.slots)) {
                const filled = (slot.name && slot.name !== "nil" && slot.name !== "") || (slot.id && slot.id !== "nil");
                const where = slot.slot === 0 ? "slot 0" : slot.slot === count ? "slot = count (one past a 0-based end)"
                    : slot.slot < count ? "slots 1..count-1" : "beyond";
                add(m, `${where}: ${filled ? "named" : "empty (coins, or not filled yet)"}`);
            }
        }
    }
    return m;
}), "If \"slot = count\" is never named, the slots are 0 based, as the API says.");

table("Slot count while the window was open", studies.map(s => {
    const m = {};
    for (const w of list(s.windows)) {
        const c = list(w.counts);
        if (c.length === 0) continue;
        const first = c[0].n, last = c[c.length - 1];
        add(m, `${first} -> ${last.n}${last.closed ? " at close" : ""} (open ${w.open_for ?? "?"} s)`.replace(/\(open ([\d.]+) s\)/, (_, x) => `(open ${Number(x) < 1 ? "<1" : Number(x) < 3 ? "1-3" : "3+"} s)`));
    }
    return m;
}));

const text = lines.join("\n") + "\n";
process.stdout.write(text);
if (mdOut) {
    fs.writeFileSync(mdOut, text);
    console.error(`written: ${path.relative(ROOT, mdOut)}`);
}

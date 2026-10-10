#!/usr/bin/env node
// Pet skills and beast families, from the client's own spell tables.
//
//   node tools/jcheck/beasts_extract.js [--client all|vanilla|forever] [--wow <install>] [--out <file>]
//
// Both clients by default (Jambix AIO 1.78.2): the AIO reads the running
// client's half, and one client alone would drop the other's from the file.
//
// What a pet can learn is client data: each CreatureFamily row names its skill
// lines (SkillLine[0] is the family's own, [1] the shared "Pet - Generic"), and
// SkillLineAbility lists the spells on each line. Per spell rank:
//   SpellLevels      the level the rank is learned at
//   SpellCooldowns   cooldown (RecoveryTime, or the category's), global cooldown
//   SpellPower       focus (power type 2) or mana, and its cost
//   SpellMisc/Range  min and max range
//   SpellEffect      the area radius, when there is one
// Which skills one beast in the world carries is the server's: the client is
// never told, so the AIO estimates it from the family and the beast's level.
//
// WRITTEN: scripts/jambix_aio/modules/beasts_data.lua, a plain Lua table the
// AIO loads (react/petskills.lua, the tame marks on the ESP). Do not edit it by
// hand: run this again after a client patch.
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts", "jambix_aio", "modules", "beasts_data.lua");
const CLIENTS = {
    vanilla: { product: "wow_classic_era" },
    forever: { product: "wow_classic_beta" },
};
const wantClient = (opt("--client") || "all").toLowerCase();

// FileDataIDs, for clients whose root carries no names (Forever's).
const TABLES = {
    CreatureFamily: 1351351, SkillLine: 1240935, SkillLineAbility: 1266278, SpellLevels: 1140079,
    SpellCooldowns: 1139924, SpellPower: 982806, SpellMisc: 1003144, SpellRange: 1146820,
    SpellName: 1990283, SpellEffect: 1140088, SpellRadius: 1134584,
};

// Learned from a Pet Trainer, not from a beast: never on a tame mark.
const TRAINER = new Set(["Growl", "Great Stamina", "Natural Armor", "Fire Resistance", "Frost Resistance",
    "Arcane Resistance", "Nature Resistance", "Shadow Resistance"]);
// Passives and markers that are no skill anyone chooses.
const SKIP = /\(DND\)|Pet Hardiness|Pet Aggression|Pet Recovery|Pet Resistance|Pet Scaling|Demonic Pact|Devour Magic Effect|Intercept Stun/;
// Pet families a hunter tames (CreatureFamily.PetFoodMask > 0, less the event pet).
const HUNTER_FOOD = f => (f.PetFoodMask || 0) > 0;

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

function firstBy(rows, key) {
    const m = new Map();
    for (const r of rows) if (!m.has(r[key]) || !r.DifficultyID) m.set(r[key], r);
    return m;
}

function extract(clientKey) {
    const c = CLIENTS[clientKey];
    const casc = cascLib.open({ wow: WOW, product: c.product });
    const T = readTables(casc);
    // The build, as casc read it from .build.info (the product row).
    const build = (casc.build && casc.build.version) || "?";
    casc.close();

    const name = id => (T.SpellName.byId.get(id) || {}).Name_lang;
    const levels = firstBy(T.SpellLevels.rows, "SpellID");
    const cds = firstBy(T.SpellCooldowns.rows, "SpellID");
    const misc = firstBy(T.SpellMisc.rows, "SpellID");
    const power = new Map();
    for (const r of T.SpellPower.rows) if (!power.has(r.SpellID)) power.set(r.SpellID, r);
    const radius = new Map();
    for (const e of T.SpellEffect.rows) {
        for (const i of e.EffectRadiusIndex || []) {
            const r = i && T.SpellRadius.byId.get(i);
            const yd = r ? (r.Radius || r.RadiusMax || 0) : 0;
            if (yd > (radius.get(e.SpellID) || 0)) radius.set(e.SpellID, yd);
        }
    }
    const byLine = new Map();
    for (const r of T.SkillLineAbility.rows) {
        if (!byLine.has(r.SkillLine)) byLine.set(r.SkillLine, []);
        byLine.get(r.SkillLine).push(r);
    }

    const skills = {};
    function addSkill(spell) {
        const n = name(spell);
        if (!n || SKIP.test(n)) return null;
        const lv = levels.get(spell);
        const level = lv ? (lv.BaseLevel || lv.SpellLevel || 0) : 0;
        const s = skills[n] || (skills[n] = { ranks: [] });
        if (!s.ranks.some(r => r[0] === spell)) s.ranks.push([spell, level]);
        return n;
    }

    /** A skill's numbers, from its first rank (the ranks share them). */
    function describe(n, s, spell) {
        {
            const cd = cds.get(spell);
            s.cd = cd ? Math.max(cd.RecoveryTime || 0, cd.CategoryRecoveryTime || 0) / 1000 : 0;
            s.gcd = cd ? (cd.StartRecoveryTime || 0) / 1000 : 0;
            const p = power.get(spell);
            if (p && (p.ManaCost || p.PowerCostPct)) {
                s.power = p.PowerType === 2 ? "focus" : (p.PowerType === 0 ? "mana" : String(p.PowerType));
                s.cost = p.ManaCost || 0;
                if (p.PowerCostPct) s.cost_pct = p.PowerCostPct;
            }
            const m = misc.get(spell);
            const rg = m && T.SpellRange.byId.get(m.RangeIndex);
            if (rg) {
                s.min = rg.RangeMin[0] || 0;
                s.range = rg.RangeMax[0] || 0;
            }
            // The icon the game draws for it (AIO 1.7.6): its file in the
            // client's archives, by FileDataID. Every rank shares it.
            if (m && m.SpellIconFileDataID) s.icon = m.SpellIconFileDataID;
            if (radius.get(spell)) s.radius = radius.get(spell);
            if (TRAINER.has(n)) s.trainer = true;
        }
    }

    const families = {};
    for (const f of T.CreatureFamily.rows) {
        const lines = (f.SkillLine || []).map(v => v & 0xffff).filter(Boolean);
        if (!lines.length) continue;
        const own = new Set();
        for (const L of lines) {
            for (const a of byLine.get(L) || []) {
                const n = addSkill(a.Spell);
                if (n && L === lines[0]) own.add(n);
            }
        }
        const generic = new Set();
        for (const a of byLine.get(lines[1]) || []) { const n = name(a.Spell); if (n && skills[n]) generic.add(n); }
        families[f.ID] = {
            name: f.Name_lang,
            hunter: HUNTER_FOOD(f) && f.ID !== 28,
            own: [...own].sort(),
            generic: [...generic].sort(),
        };
    }
    for (const [n, s] of Object.entries(skills)) {
        s.ranks.sort((a, b) => a[1] - b[1] || a[0] - b[0]);
        describe(n, s, s.ranks[0][0]);
    }
    return { build, families, skills };
}

// --- Lua writer ---------------------------------------------------------------------

function lua(v, indent) {
    indent = indent || "";
    const pad = indent + "    ";
    if (Array.isArray(v)) {
        if (v.every(x => typeof x !== "object")) return "{ " + v.map(x => lua(x)).join(", ") + " }";
        return "{\n" + v.map(x => pad + lua(x, pad)).join(",\n") + ",\n" + indent + "}";
    }
    if (v && typeof v === "object") {
        const keys = Object.keys(v).sort((a, b) => {
            const na = Number(a), nb = Number(b);
            if (!isNaN(na) && !isNaN(nb)) return na - nb;
            return a < b ? -1 : a > b ? 1 : 0;
        });
        return "{\n" + keys.map(k => {
            const key = /^\d+$/.test(k) ? `[${k}]` : (/^[A-Za-z_]\w*$/.test(k) ? k : `[${JSON.stringify(k)}]`);
            return pad + key + " = " + lua(v[k], pad);
        }).join(",\n") + ",\n" + indent + "}";
    }
    if (typeof v === "string") return JSON.stringify(v);
    if (typeof v === "boolean") return v ? "true" : "false";
    return String(v);
}

const out = {};
for (const key of (wantClient === "all" ? Object.keys(CLIENTS) : [wantClient])) {
    try {
        out[key] = extract(key);
        const n = Object.keys(out[key].skills).length;
        console.log(`${key}: ${Object.keys(out[key].families).length} families, ${n} skills`);
    } catch (e) {
        console.error(`${key}: ${e.message}`);
    }
}
const header = `-- Jambix AIO / beasts_data -- GENERATED by tools/jcheck/beasts_extract.js from the
-- client's spell tables (CreatureFamily, SkillLine, SkillLineAbility, SpellLevels,
-- SpellCooldowns, SpellPower, SpellMisc, SpellRange, SpellEffect). Do not edit by
-- hand: run it again after a client patch.
--
-- families[id] = { name, hunter (a hunter tames it), own (its skills), generic }
-- skills[name] = { ranks = { { spell id, level learned }, ... }, cd, gcd (seconds),
--                  power ("focus" | "mana"), cost, min, range, radius (yards),
--                  trainer (from a Pet Trainer, not from a beast),
--                  icon (the game's own icon: SpellMisc.SpellIconFileDataID; the
--                  art pack's "pet.<icon>" cell) }
`;
fs.writeFileSync(OUT, header + "return " + lua(out) + "\n");
console.log("wrote " + path.relative(ROOT, OUT));

#!/usr/bin/env node
// Telegraph data: where an enemy spell lands, and what the boss mods say to do
// about it (JCore's services/telegraphs.lua reads it; the AIO draws it).
//
//   node tools/jcheck/telegraph_extract.js [--client vanilla|forever|all] [--wow <install>] [--dbm <AddOns dir>] [--out <dir>]
//
// THREE SOURCES, MERGED PER SPELL ID
//
// 1. The client's own spell tables (the authority on geometry), read out of the
//    CASC store with lib/casc.js and decoded with lib/db2.js + WoWDBDefs:
//      SpellEffect             Effect, ImplicitTarget[2], EffectRadiusIndex[2], EffectTriggerSpell
//      SpellRadius             yards
//      SpellTargetRestrictions ConeDegrees, Width
//      SpellMisc               CastingTimeIndex, DurationIndex, SchoolMask
//      SpellCastTimes / SpellDuration / SpellName
//    An effect aimed at an enemy AREA is a shape: target 15 a circle around the
//    caster, 16 / 28 a circle at a destination (set by 18 caster, 53 target, 87
//    ground, 17 a fixed point), 24 / 54 / 104 a cone. Effect 27 (persistent area
//    aura) and 179 (area trigger) leave it on the ground for the spell's duration.
//    A spell with no shape of its own takes the shape of the spell it triggers
//    (effect 64, aura 23 / 227), two levels deep: a channelled whirlwind.
//
// 2. DBM's boss mods (every DBM pack whose TOC says X-DBM-Mod-Category: Classic),
//    parsed with luaparse, never run: per spell, the warnings a mod builds
//    (NewSpecialWarningDodge -> "dodge", ...Run, ...MoveAway, ...Interrupt, ...GTFO),
//    the voice keys it plays (:Play("watchstep")), role filters ("Tank", "-Melee"),
//    the combat-log events it registers the spell on, cast timers and cooldowns;
//    per mod, its creature ids, encounter id and zones.
//
// 3. Plater's script library: the cast scripts it files spell ids under
//    ("Cast - Frontal Cone [Plater]" ...). Mostly retail ids; only ids this
//    client's spell table has are kept.
//
// WRITTEN, per client (vanilla = Classic Era / HC / SoD, forever = _classic_beta_):
//   <out>/<client>/index.json            build, counts, sources, mods, hint texts
//   <out>/<client>/spells/<bucket>.json  bucket = floor(id / 1000): { "<id>": row }
// A row: n name, s school mask, ct cast ms, du duration ms, lv danger 1..3,
//        sh [ { k "circle"|"cone", at "caster"|"target"|"dest"|"front"|"fixed",
//               r yards, d cone degrees, w width, p linger ms, via triggered id } ],
//        dbm { k kinds, v voice keys, role, ev events, mods, cast s, cd [min, max] },
//        pl Plater categories
"use strict";
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const luaparse = require(path.join(__dirname, "node_modules", "luaparse"));
const cascLib = require("./lib/casc");
const db2 = require("./lib/db2");

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const WOW = opt("--wow") || "C:/Program Files (x86)/World of Warcraft";
const OUT = opt("--out") || path.join(ROOT, "scripts_data", "jcore", "telegraphs");
const CLIENTS = {
    vanilla: { product: "wow_classic_era", folder: "_classic_era_" },
    forever: { product: "wow_classic_beta", folder: "_classic_beta_" },
};
const wantClient = (opt("--client") || "all").toLowerCase();
// DBM's classic packs live in the Era client; Forever's DBM is Midnight-only,
// and its world is the classic one, so both clients read Era's mods by default.
const DBM_DIR = opt("--dbm") || path.join(WOW, "_classic_era_", "Interface", "AddOns");
const PLATER_DIR = opt("--plater") || path.join(WOW, "_classic_era_", "Interface", "AddOns", "Plater");

// FileDataIDs, for clients whose root carries no names (Forever's).
const TABLES = {
    SpellEffect: 1140088, SpellRadius: 1134584, SpellTargetRestrictions: 1139993, SpellMisc: 1003144,
    SpellCastTimes: 1134089, SpellName: 1990283, SpellDuration: 1137828,
};

// --- 1. geometry from the spell tables ------------------------------------------

const AREA_SRC = new Set([15]);                 // around the source (the caster)
const AREA_DEST = new Set([16, 28]);            // around the destination
const CONE = new Set([24, 54, 104]);
const DEST_SETTER = {                           // what fixes the destination
    18: "caster", 22: "caster", 1: "caster",
    47: "front", 41: "front", 55: "front",
    53: "target", 63: "target", 6: "target", 25: "target",
    87: "dest", 28: "dest",
    17: "fixed",
};
const PLACED = new Set(["target", "dest"]);   // both resolve to the cast target's ground
const LINGER_EFFECTS = new Set([27, 179]);      // persistent area aura, area trigger
const TRIGGER_EFFECTS = new Set([64, 142]);     // trigger spell (with value)
const TRIGGER_AURAS = new Set([23, 227]);       // periodic trigger spell (with value)

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

function buildSpells(T) {
    const radius = id => { const r = id && T.SpellRadius.byId.get(id); return r ? (r.Radius || r.RadiusMax || 0) : 0; };
    const effects = new Map();
    for (const e of T.SpellEffect.rows) {
        if (e.DifficultyID && e.DifficultyID !== 0) {
            // A difficulty variant: keep only when the spell has no normal row for that index.
            const list = effects.get(e.SpellID);
            if (list && list.some(x => x.EffectIndex === e.EffectIndex)) continue;
        }
        if (!effects.has(e.SpellID)) effects.set(e.SpellID, []);
        const list = effects.get(e.SpellID);
        if (list.some(x => x.EffectIndex === e.EffectIndex && x.Effect === e.Effect)) continue;
        list.push(e);
    }
    const restrict = new Map();
    for (const r of T.SpellTargetRestrictions.rows) if (!restrict.has(r.SpellID) || !r.DifficultyID) restrict.set(r.SpellID, r);
    const misc = new Map();
    for (const m of T.SpellMisc.rows) if (!misc.has(m.SpellID) || !m.DifficultyID) misc.set(m.SpellID, m);
    const castMs = id => { const m = misc.get(id); const c = m && T.SpellCastTimes.byId.get(m.CastingTimeIndex); return c ? Math.max(0, c.Base) : 0; };
    const durMs = id => { const m = misc.get(id); const d = m && T.SpellDuration.byId.get(m.DurationIndex); return d ? d.Duration : 0; };

    /** The enemy-area shapes of one spell's own effects. */
    function ownShapes(id) {
        const out = [];
        const list = effects.get(id) || [];
        const linger = list.some(e => LINGER_EFFECTS.has(e.Effect)) ? Math.max(0, durMs(id)) : 0;
        const rs = restrict.get(id);
        for (const e of list) {
            const [a, b] = e.ImplicitTarget || [0, 0];
            const [ra, rb] = (e.EffectRadiusIndex || [0, 0]).map(radius);
            const r = Math.max(ra, rb);
            if (!r) continue;
            let shape = null;
            if (CONE.has(a) || CONE.has(b)) {
                shape = { k: "cone", at: "caster", r, d: (rs && rs.ConeDegrees) || 60 };
            } else if (AREA_SRC.has(a) || AREA_SRC.has(b)) {
                shape = { k: "circle", at: "caster", r };
            } else if (AREA_DEST.has(a) || AREA_DEST.has(b)) {
                const other = AREA_DEST.has(b) ? a : b;
                const at = DEST_SETTER[other] || (other === 0 ? (a === 28 || b === 28 ? "dest" : "target") : null);
                if (!at) continue;           // random points (72, 86, 91 ...): no fixed place to draw
                shape = { k: "circle", at, r };
            }
            if (!shape) continue;
            if (rs && rs.Width) shape.w = rs.Width;
            if (linger && (LINGER_EFFECTS.has(e.Effect) || shape.at !== "caster")) shape.p = linger;
            // One circle per place: a hit at the target and the ground it leaves
            // there (Flamestrike) are the same mark, drawn for the longer time.
            const twin = out.find(s => s.k === shape.k && s.r === shape.r && s.d === shape.d &&
                (s.at === shape.at || (PLACED.has(s.at) && PLACED.has(shape.at))));
            if (twin) {
                if (shape.p && !(twin.p >= shape.p)) twin.p = shape.p;
                if (twin.at === "target" && shape.at === "dest") twin.at = "dest";
                continue;
            }
            out.push(shape);
        }
        return out;
    }

    function shapesOf(id, depth, seen) {
        const own = ownShapes(id);
        if (own.length || depth >= 2) return own;
        const out = [];
        for (const e of effects.get(id) || []) {
            const t = e.EffectTriggerSpell;
            if (!t || seen.has(t)) continue;
            if (!(TRIGGER_EFFECTS.has(e.Effect) || (e.Effect === 6 && TRIGGER_AURAS.has(e.EffectAura)))) continue;
            seen.add(t);
            for (const s of shapesOf(t, depth + 1, seen)) {
                const c = Object.assign({}, s);
                if (!c.via) c.via = t;
                out.push(c);
            }
        }
        return out;
    }

    const spells = new Map();
    for (const id of effects.keys()) {
        const sh = shapesOf(id, 0, new Set([id]));
        if (!sh.length) continue;
        spells.set(id, { sh });
    }
    function describe(id, row) {
        const name = T.SpellName.byId.get(id);
        if (name && name.Name_lang) row.n = name.Name_lang;
        const m = misc.get(id);
        if (m && m.SchoolMask) row.s = m.SchoolMask;
        const ct = castMs(id); if (ct) row.ct = ct;
        const du = durMs(id); if (du > 0) row.du = du;
        return row;
    }
    return { spells, describe, has: id => T.SpellName.byId.has(id) || effects.has(id) };
}

// --- 2. DBM -----------------------------------------------------------------------

// Warning constructor -> kind. Order matters: longest names first.
const DBM_KINDS = [
    ["NewSpecialWarningDodge", "dodge"], ["NewSpecialWarningRun", "run"], ["NewSpecialWarningMoveAway", "moveaway"],
    ["NewSpecialWarningMoveTo", "moveto"], ["NewSpecialWarningGTFO", "gtfo"], ["NewSpecialWarningMove", "move"],
    ["NewSpecialWarningKeepMove", "keepmove"], ["NewSpecialWarningStopMove", "stopmove"], ["NewSpecialWarningJump", "jump"],
    ["NewSpecialWarningInterrupt", "interrupt"], ["NewSpecialWarningDefensive", "defensive"], ["NewSpecialWarningTaunt", "taunt"],
    ["NewSpecialWarningSoak", "soak"], ["NewSpecialWarningLookAway", "lookaway"], ["NewSpecialWarningReflect", "reflect"],
    ["NewSpecialWarningDispel", "dispel"], ["NewSpecialWarningSwitch", "switch"], ["NewSpecialWarningAdds", "adds"],
    ["NewSpecialWarningYou", "you"], ["NewSpecialWarningClose", "close"], ["NewSpecialWarningTarget", "target"],
    ["NewSpecialWarningStack", "stack"], ["NewSpecialWarningSoon", "soon"], ["NewSpecialWarningCast", "cast"],
    ["NewSpecialWarningCount", "spell"], ["NewSpecialWarningSpell", "spell"], ["NewSpecialWarning", "spell"],
    ["NewCastAnnounce", "announce_cast"], ["NewTargetNoFilterAnnounce", "announce_target"], ["NewTargetAnnounce", "announce_target"],
    ["NewSpellAnnounce", "announce"], ["NewCountAnnounce", "announce"], ["NewSoonAnnounce", "announce_soon"],
    ["NewStackAnnounce", "announce_stack"], ["NewYell", "yell"], ["NewShortYell", "yell"],
];
// Kinds that mean "where you stand matters": a telegraph.
const AVOID_KINDS = new Set(["dodge", "run", "moveaway", "gtfo", "move", "keepmove", "jump", "lookaway"]);
const AVOID_VOICES = new Set(["watchstep", "watchfeet", "runout", "justrun", "runaway", "scatter", "breathsoon", "frontal",
    "shockwave", "farfromline", "keepmove", "carefly", "turnaway", "watchorb", "whirlwind", "laserrun", "runtoedge", "pushbackincoming",
    "range5", "stilldanger", "aesoon", "fearsoon", "watchwave", "behindboss", "dodgeboss", "findshelter"]);
// Combat-log events that mean "it is on you / you are standing in it".
const HAZARD_EVENTS = new Set(["SPELL_AURA_APPLIED", "SPELL_AURA_APPLIED_DOSE", "SPELL_PERIODIC_DAMAGE", "SPELL_PERIODIC_MISSED",
    "SPELL_DAMAGE", "SPELL_MISSED", "SPELL_AURA_REFRESH"]);
const HAZARD_KINDS = new Set(["gtfo", "move", "moveaway", "run", "you", "close", "keepmove", "jump"]);
// What the plugin may say about a voice key (the rest fall back to the kind).
const VOICE_HINTS = {
    watchstep: "Watch your step", watchfeet: "Out of the bad", runout: "Run out", justrun: "Run!", runaway: "Run away",
    scatter: "Spread out", breathsoon: "Breath: get out of the front", frontal: "Frontal: get out of the front",
    shockwave: "Shockwave: get out of the line", farfromline: "Stay out of the line", keepmove: "Keep moving", stopmove: "Stop moving",
    carefly: "Careful", turnaway: "Turn away", watchorb: "Watch the orbs", whirlwind: "Whirlwind: get away", laserrun: "Beam: run",
    runtoedge: "Run to the edge", pushbackincoming: "Knockback", range5: "Keep 5 yards apart", stilldanger: "Still dangerous",
    aesoon: "AoE soon", fearsoon: "Fear soon", findshelter: "Find shelter", kickcast: "Interrupt", stopcast: "Stop casting",
    tauntboss: "Taunt", defensive: "Defensive", gather: "Stack up", gathershare: "Stack up", linegather: "Line up", helpsoak: "Soak",
    soakbeam: "Soak the beam", targetyou: "On you", bombyou: "Bomb on you: move away", dispelnow: "Dispel", stopattack: "Stop attacking",
    moveboss: "Move the boss", movetotank: "Move to the tank", dontmove: "Don't move", breaklos: "Break line of sight",
    stunsoon: "Stun soon", killmob: "Kill the add",
};
const KIND_HINTS = {
    dodge: "Dodge", run: "Run out", moveaway: "Move away from others", moveto: "Move", gtfo: "Get out", move: "Move",
    keepmove: "Keep moving", stopmove: "Stop moving", jump: "Jump", interrupt: "Interrupt", defensive: "Defensive",
    taunt: "Taunt", soak: "Soak", lookaway: "Look away", reflect: "Reflect", dispel: "Dispel", switch: "Switch target",
    adds: "Adds", you: "On you", close: "Near you", target: "Targeted", stack: "Stacks", soon: "Soon", cast: "Casting",
    spell: "Incoming",
};

function tocInfo(dir) {
    const tocs = fs.readdirSync(dir).filter(f => f.toLowerCase().endsWith(".toc"));
    const text = tocs.length ? fs.readFileSync(path.join(dir, tocs[0]), "utf8") : "";
    const get = k => { const m = text.match(new RegExp("^## " + k + ":\\s*(.*?)\\s*$", "mi")); return m ? m[1] : null; };
    return { mod: get("X-DBM-Mod") === "1", category: (get("X-DBM-Mod-Category") || "").toLowerCase() };
}

function luaFilesUnder(dir) {
    const out = [];
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) out.push(...luaFilesUnder(p));
        else if (e.name.endsWith(".lua") && !/^local(e|ization)|^locale/i.test(e.name)) out.push(p);
    }
    return out;
}

function walk(node, fn) {
    if (!node || typeof node !== "object") return;
    if (Array.isArray(node)) { for (const n of node) walk(n, fn); return; }
    if (node.type) fn(node);
    for (const k of Object.keys(node)) {
        if (k === "loc" || k === "range") continue;
        const v = node[k];
        if (v && typeof v === "object") walk(v, fn);
    }
}

const num = a => (a && a.type === "NumericLiteral") ? a.value
    : (a && a.type === "UnaryExpression" && a.operator === "-" && a.argument.type === "NumericLiteral") ? -a.argument.value : null;
const str = a => (a && a.type === "StringLiteral") ? (a.value != null ? a.value : String(a.raw).slice(1, -1)) : null;
const ROLE_RE = /^-?(Tank|Healer|Melee|Ranged|Dps|SpellCaster|Physical|MagicDispeller|RemoveCurse|RemovePoison|RemoveDisease|RemoveMagic|HasInterrupt|HasImmunity|CasterDps|MeleeDps|RangedDps|TargetedCooldown|Mana)(\|-?\w+)*$/;

function parseDbm(dbmDir) {
    const mods = {};
    const spells = new Map();       // id -> { k:Set, v:Set, role:Set, ev:Set, mods:Set, cast, cd }
    const touch = id => {
        if (!spells.has(id)) spells.set(id, { k: new Set(), v: new Set(), role: new Set(), ev: new Set(), mods: new Set() });
        return spells.get(id);
    };
    const packs = [];
    if (!fs.existsSync(dbmDir)) return { mods, spells, packs };
    for (const name of fs.readdirSync(dbmDir)) {
        if (!name.startsWith("DBM-")) continue;
        const dir = path.join(dbmDir, name);
        if (!fs.statSync(dir).isDirectory()) continue;
        const toc = tocInfo(dir);
        if (!toc.mod || toc.category !== "classic") continue;
        packs.push(name);
        for (const file of luaFilesUnder(dir)) {
            let ast;
            try { ast = luaparse.parse(fs.readFileSync(file, "utf8"), { luaVersion: "LuaJIT", comments: false, encodingMode: "x-user-defined" }); }
            catch (e) { console.warn(`  dbm: ${path.relative(dbmDir, file)} does not parse: ${e.message}`); continue; }
            let modId = null;
            const vars = new Map();     // local name -> { kind, spell }
            const plays = [];           // [var, key]
            const meta = { addon: name, file: path.relative(dbmDir, file).replace(/\\/g, "/"), creatures: [], zone: [], encounter: null };
            const events = [];
            walk(ast, n => {
                if (n.type !== "CallExpression" && n.type !== "StringCallExpression") return;
                const base = n.base;
                if (!base || base.type !== "MemberExpression") return;
                const method = base.identifier && base.identifier.name;
                const args = n.arguments || (n.argument ? [n.argument] : []);
                if (base.base.type === "Identifier" && base.base.name === "DBM" && method === "NewMod") {
                    const a = args[0];
                    modId = str(a) != null ? str(a) : (num(a) != null ? String(num(a)) : modId);
                    return;
                }
                if (method === "Play" && base.base.type === "Identifier" && str(args[0])) { plays.push([base.base.name, str(args[0])]); return; }
                if (base.base.type !== "Identifier" || base.base.name !== "mod") return;
                if (method === "SetCreatureID" || method === "SetMainBossID") { for (const a of args) if (num(a) != null) meta.creatures.push(num(a)); return; }
                if (method === "SetEncounterID") { if (num(args[0]) != null) meta.encounter = num(args[0]); return; }
                if (method === "SetZone") { for (const a of args) if (num(a) != null) meta.zone.push(num(a)); return; }
                if (method === "RegisterEventsInCombat" || method === "RegisterEvents" || method === "RegisterShortTermEvents") {
                    for (const a of args) { const s = str(a); if (s) events.push(s); }
                }
            });
            // Constructors: `local x = mod:NewXxx(...)`, so walk assignments for the variable name.
            walk(ast, n => {
                if (n.type !== "LocalStatement" && n.type !== "AssignmentStatement") return;
                (n.init || []).forEach((init, i) => {
                    if (!init || init.type !== "CallExpression" || !init.base || init.base.type !== "MemberExpression") return;
                    const b = init.base;
                    if (b.base.type !== "Identifier" || b.base.name !== "mod") return;
                    const method = b.identifier.name;
                    const target = n.variables[i];
                    const varName = target && target.type === "Identifier" ? target.name : null;
                    const args = init.arguments || [];
                    let kind = null;
                    for (const [m, k] of DBM_KINDS) if (method === m) { kind = k; break; }
                    const isTimer = /Timer$/.test(method);
                    if (!kind && !isTimer) return;
                    const spellArg = isTimer ? args[1] : args[0];
                    const spell = num(spellArg);
                    if (!spell || spell <= 0) return;
                    const row = touch(spell);
                    if (modId) row.mods.add(modId);
                    if (kind) row.k.add(kind);
                    for (const a of args) {
                        const s = str(a);
                        if (s && ROLE_RE.test(s)) row.role.add(s);
                        if (s && kind && !isTimer && /^[a-z0-9]{3,24}$/.test(s) && s !== "nil") row.v.add(s);
                    }
                    if (isTimer) {
                        const t = args[0];
                        const secs = num(t);
                        const range = str(t) && str(t).match(/^v?(\d+(?:\.\d+)?)(?:-(\d+(?:\.\d+)?))?$/);
                        if (/^NewCast/.test(method)) { if (secs) row.cast = secs; }
                        else if (/^New(CD|Var|Next)/.test(method)) {
                            const lo = secs || (range ? Number(range[1]) : null);
                            const hi = range && range[2] ? Number(range[2]) : lo;
                            if (lo) row.cd = row.cd ? [Math.min(row.cd[0], lo), Math.max(row.cd[1], hi)] : [lo, hi];
                        }
                    }
                    if (varName) vars.set(varName, spell);
                });
            });
            for (const [v, key] of plays) { const spell = vars.get(v); if (spell) touch(spell).v.add(key); }
            for (const e of events) {
                const parts = e.trim().split(/\s+/);
                const ev = parts.shift();
                for (const p of parts) { const id = Number(p); if (id > 0) { const row = touch(id); row.ev.add(ev); if (modId) row.mods.add(modId); } }
            }
            if (modId) mods[modId] = meta;
        }
    }
    return { mods, spells, packs };
}

// --- 3. Plater ----------------------------------------------------------------------

function parsePlater(dir) {
    const out = new Map();     // id -> Set(category)
    const file = path.join(dir, "Plater_ScriptLibrary.lua");
    if (!fs.existsSync(file)) return out;
    const add = (id, script) => {
        const cat = script.replace(/\s*\[[^\]]*\]\s*$/, "").replace(/^Cast - /, "").trim().toLowerCase();
        if (!out.has(id)) out.set(id, new Set());
        out.get(id).add(cat);
    };
    let ast;
    try { ast = luaparse.parse(fs.readFileSync(file, "utf8"), { luaVersion: "LuaJIT", encodingMode: "x-user-defined" }); }
    catch (e) { console.warn("  plater: does not parse: " + e.message); return out; }
    walk(ast, n => {
        if (n.type === "TableKeyString" || n.type === "TableKey") {
            const key = n.type === "TableKey" ? str(n.key) : null;
            if (key && /^Cast - |Affix/.test(key) && n.value && n.value.type === "TableConstructorExpression") {
                for (const f of n.value.fields) { const id = num(f.value); if (id) add(id, key); }
            }
        }
        if (n.type === "CallExpression" && n.base && n.base.type === "MemberExpression" && n.base.identifier.name === "AddTriggerToScript") {
            const id = num(n.arguments[0]), script = str(n.arguments[2]);
            if (id && script) add(id, script);
        }
    });
    return out;
}

// --- merge and write -----------------------------------------------------------------

function level(row) {
    const d = row.dbm;
    const kinds = (d && d.k) || [], voices = (d && d.v) || [];
    if (kinds.some(k => AVOID_KINDS.has(k)) || voices.some(v => AVOID_VOICES.has(v))) return 3;
    if (d || (row.pl && row.pl.length)) return 2;
    return 1;
}

function extract(clientKey, dbm, plater) {
    const c = CLIENTS[clientKey];
    const t0 = Date.now();
    const casc = cascLib.open({ wow: WOW, product: c.product });
    const T = readTables(casc);
    casc.close();
    const { spells, describe, has } = buildSpells(T);
    let dbmSpells = 0, platerSpells = 0;
    for (const [id, d] of dbm.spells) {
        if (!has(id)) continue;
        dbmSpells++;
        const row = spells.get(id) || { sh: [] };
        row.dbm = { k: [...d.k], v: [...d.v], role: [...d.role], ev: [...d.ev], mods: [...d.mods] };
        if (d.cast) row.dbm.cast = d.cast;
        if (d.cd) row.dbm.cd = d.cd;
        for (const k of ["k", "v", "role", "ev"]) if (!row.dbm[k].length) delete row.dbm[k];
        spells.set(id, row);
    }
    for (const [id, cats] of plater) {
        if (!has(id)) continue;
        platerSpells++;
        const row = spells.get(id) || { sh: [] };
        row.pl = [...cats];
        spells.set(id, row);
    }
    const dir = path.join(OUT, clientKey);
    fs.rmSync(path.join(dir, "spells"), { recursive: true, force: true });
    fs.mkdirSync(path.join(dir, "spells"), { recursive: true });
    const buckets = new Map();
    let shaped = 0, cones = 0, lingering = 0, levels = { 1: 0, 2: 0, 3: 0 };
    for (const [id, row] of [...spells.entries()].sort((a, b) => a[0] - b[0])) {
        describe(id, row);
        if (!row.sh.length) delete row.sh; else shaped++;
        if (row.sh && row.sh.some(s => s.k === "cone")) cones++;
        if (row.sh && row.sh.some(s => s.p)) lingering++;
        row.lv = level(row);
        levels[row.lv]++;
        const b = Math.floor(id / 1000);
        if (!buckets.has(b)) buckets.set(b, {});
        buckets.get(b)[id] = row;
    }
    for (const [b, rows] of buckets) fs.writeFileSync(path.join(dir, "spells", b + ".json"), JSON.stringify(rows));
    const mods = {};
    for (const [id, m] of Object.entries(dbm.mods)) mods[id] = m;
    // Hazards with no cast bar: an aura or a damage tick on you that a mod
    // says to move for ("gtfo" Chill, "you" Living Bomb). Read up front, not
    // per bucket: the player's auras and the combat log are checked against them.
    const auras = {};
    for (const [id, row] of spells) {
        const d = row.dbm;
        if (!d || !d.ev || !d.ev.some(e => HAZARD_EVENTS.has(e))) continue;
        const kinds = d.k || [], voices = d.v || [];
        if (kinds.some(k => HAZARD_KINDS.has(k)) || voices.some(v => AVOID_VOICES.has(v) || v === "bombyou" || v === "targetyou")) {
            auras[id] = { k: kinds.filter(k => HAZARD_KINDS.has(k)), ev: d.ev.filter(e => HAZARD_EVENTS.has(e)) };
        }
    }
    const index = {
        client: clientKey, product: c.product, version: casc.build.version, build_time: new Date().toISOString(),
        source: "tools/jcheck/telegraph_extract.js",
        sources: { tables: Object.keys(TABLES), dbm_packs: dbm.packs, plater: fs.existsSync(PLATER_DIR) },
        counts: { spells: spells.size, shaped, cones, lingering, dbm: dbmSpells, plater: platerSpells, levels, auras: Object.keys(auras).length },
        buckets: [...buckets.keys()].sort((a, b) => a - b),
        mods, auras, voice_hints: VOICE_HINTS, kind_hints: KIND_HINTS,
    };
    fs.writeFileSync(path.join(dir, "index.json"), JSON.stringify(index, null, 1));
    console.log(`${clientKey} (${casc.build.version}): ${spells.size} spells, ${shaped} with a shape (${cones} cones, ${lingering} lingering), ` +
        `${dbmSpells} from DBM, ${platerSpells} from Plater, danger ${JSON.stringify(levels)}, ${buckets.size} buckets, ${Date.now() - t0} ms -> ${path.relative(ROOT, dir)}`);
    return index;
}

function main() {
    const dbm = parseDbm(DBM_DIR);
    console.log(`dbm: ${dbm.packs.join(", ") || "(no classic packs)"}: ${Object.keys(dbm.mods).length} mods, ${dbm.spells.size} spell ids`);
    const plater = parsePlater(PLATER_DIR);
    console.log(`plater: ${plater.size} spell ids`);
    const keys = wantClient === "all" ? Object.keys(CLIENTS) : [wantClient];
    for (const k of keys) {
        if (!CLIENTS[k]) throw new Error("unknown client " + k);
        try { extract(k, dbm, plater); }
        catch (e) { console.error(`${k}: ${e.message}`); if (wantClient !== "all") process.exitCode = 1; }
    }
}

if (require.main === module) main();
module.exports = { parseDbm, parsePlater, buildSpells };

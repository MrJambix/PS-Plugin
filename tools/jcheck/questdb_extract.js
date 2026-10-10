#!/usr/bin/env node
// Our own copy of QuestieDB's data, so nothing needs Questie at run time
// (JCore's services/questdb.lua reads it).
//
//   node tools/jcheck/questdb_extract.js [--client forever|vanilla] [--addons <AddOns dir>] [--out <dir>]
//
// QuestieDB ships its database "baked" into a TOC file's metadata lines:
//   ## X-<Kind>-IDS: base64(zlib(CBOR [ids...]))
//   ## X-<Kind>-<id>-S: base64(CBOR { [fieldIndex] = scalar, p = presence mask })
//   ## X-<Kind>-<id>-<fieldIndex>: base64(CBOR table)   (a table field, present when its p bit is set)
// A value of the shape "~N~" is a chunk header: the value is the concatenation
// of "<key>-1" .. "<key>-N". Field names, types and constants come from
// QuestieDB's own src/meta/<kind>Meta.lua, read here, so a schema change upstream
// is picked up rather than guessed.
//
// Written: <out>/index.json (flavor, build, counts, every quest id) and
// <out>/<kind>/<bucket>.json with bucket = floor(id / 1000): { "<id>": { field: value } }.
// Waypoints (npc patrol paths) are left out: large, and nothing reads them.
// QuestieDB's Dynamic Corrections (Lua code applied at load) are NOT applied.
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const ROOT = path.resolve(__dirname, "..", "..");
const luaparse = require(path.join(__dirname, "node_modules", "luaparse"));

const argv = process.argv.slice(2);
const opt = name => { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : null; };
const client = (opt("--client") || "forever").toLowerCase();
const FOLDER = { forever: "_classic_beta_", vanilla: "_classic_era_" };
const TOC = { forever: ["QuestieDB_Forever.toc", "QuestieDB_Camelot.toc"], vanilla: ["QuestieDB_Vanilla.toc"] };
const addons = opt("--addons") || path.join("C:/Program Files (x86)/World of Warcraft", FOLDER[client] || FOLDER.forever, "Interface/AddOns");
const dbDir = path.join(addons, "QuestieDB");
const outDir = opt("--out") || path.join(ROOT, "scripts_data", "jcore", "questdb", client);
const SKIP_FIELDS = new Set(["waypoints"]);

// --- CBOR ---------------------------------------------------------------------

function cbor(buf) {
    let pos = 0;
    function uint(info) {
        if (info < 24) return info;
        if (info === 24) return buf[pos++];
        if (info === 25) { const v = buf.readUInt16BE(pos); pos += 2; return v; }
        if (info === 26) { const v = buf.readUInt32BE(pos); pos += 4; return v; }
        if (info === 27) { const v = Number(buf.readBigUInt64BE(pos)); pos += 8; return v; }
        throw new Error("indefinite length not supported");
    }
    function half(h) {
        const s = (h & 0x8000) ? -1 : 1, e = (h >> 10) & 0x1f, f = h & 0x3ff;
        if (e === 0) return s * Math.pow(2, -14) * (f / 1024);
        if (e === 31) return f ? NaN : s * Infinity;
        return s * Math.pow(2, e - 15) * (1 + f / 1024);
    }
    function item() {
        const b = buf[pos++];
        const major = b >> 5, info = b & 31;
        switch (major) {
            case 0: return uint(info);
            case 1: return -1 - uint(info);
            case 2: { const n = uint(info); const v = buf.subarray(pos, pos + n); pos += n; return v.toString("latin1"); }
            case 3: { const n = uint(info); const v = buf.toString("utf8", pos, pos + n); pos += n; return v; }
            case 4: { const n = uint(info); const a = []; for (let i = 0; i < n; i++) a.push(item()); return a; }
            case 5: { const n = uint(info); const m = {}; for (let i = 0; i < n; i++) { const k = item(); m[k] = item(); } return m; }
            case 6: { uint(info); return item(); }
            case 7:
                if (info === 20) return false;
                if (info === 21) return true;
                if (info === 22 || info === 23) return null;
                if (info === 25) { const h = buf.readUInt16BE(pos); pos += 2; return half(h); }
                if (info === 26) { const v = buf.readFloatBE(pos); pos += 4; return v; }
                if (info === 27) { const v = buf.readDoubleBE(pos); pos += 8; return v; }
                return null;
        }
        throw new Error("bad CBOR major " + major);
    }
    return item();
}

// --- QuestieDB's meta, from its own Lua --------------------------------------

function evalLua(node) {
    switch (node.type) {
        case "TableConstructorExpression": {
            const out = {};
            let n = 0;
            for (const f of node.fields) {
                if (f.type === "TableKey") out[evalLua(f.key)] = evalLua(f.value);
                else if (f.type === "TableKeyString") out[f.key.name] = evalLua(f.value);
                else out[++n] = evalLua(f.value);
            }
            return out;
        }
        case "StringLiteral": return node.value !== null ? node.value : node.raw.slice(1, -1);
        case "NumericLiteral": return node.value;
        case "BooleanLiteral": return node.value;
        case "NilLiteral": return null;
        case "UnaryExpression": if (node.operator === "-") return -evalLua(node.argument); return null;
        default: return null;
    }
}

function readMeta(kind) {
    const file = path.join(dbDir, "src", "meta", kind.toLowerCase() + "Meta.lua");
    const src = fs.readFileSync(file, "utf8");
    const ast = luaparse.parse(src, { luaVersion: "5.1", encodingMode: "x-user-defined" });
    for (const st of ast.body) {
        if (st.type === "LocalStatement" && st.variables[0] && st.variables[0].name === "meta") {
            return evalLua(st.init[0]);
        }
    }
    throw new Error("no meta table in " + file);
}

// --- the TOC store -------------------------------------------------------------

function readToc() {
    for (const name of TOC[client] || TOC.forever) {
        const file = path.join(dbDir, name);
        if (fs.existsSync(file)) {
            const store = new Map();
            for (const line of fs.readFileSync(file, "latin1").split(/\r?\n/)) {
                if (!line.startsWith("## X-")) continue;
                const colon = line.indexOf(":");
                if (colon < 0) continue;
                store.set(line.slice(3, colon).trim(), line.slice(colon + 1).trim());
            }
            return { file, store };
        }
    }
    throw new Error("no QuestieDB TOC in " + dbDir);
}

function stored(store, key) {
    const value = store.get(key);
    if (value === undefined) return undefined;
    const m = /^~(\d+)~$/.exec(value);
    if (!m) return value;
    const parts = [];
    for (let i = 1; i <= Number(m[1]); i++) {
        const part = store.get(key + "-" + i);
        if (part === undefined) throw new Error(`${key}: part ${i} of ${m[1]} missing`);
        parts.push(part);
    }
    return parts.join("");
}

function inflate(buf) {
    for (const fn of [zlib.inflateSync, zlib.inflateRawSync, zlib.gunzipSync]) {
        try { return fn(buf); } catch (e) { /* next */ }
    }
    throw new Error("could not decompress the id list");
}

// --- normalizers (src/meta/normalize.lua's, the ones the schema names) ----------

const FACTION = { 1: "A", 2: "H", 3: "AH" };
function normalize(name, value) {
    if (name === "faction" && typeof value === "number") return FACTION[value] || value;
    return value;
}

// --- one kind --------------------------------------------------------------------

function extract(store, kind) {
    const meta = readMeta(kind);
    const prefix = "X-" + meta.metaPrefix;
    const idsRaw = stored(store, prefix + "IDS");
    if (!idsRaw) throw new Error("no " + prefix + "IDS");
    const ids = cbor(inflate(Buffer.from(idsRaw, "base64")));
    const types = meta.types || {}, names = meta.names || {};
    const constants = meta.constantValues || {}, emptyIsNil = meta.emptyIsNil || {};
    const norm = meta.normalize || {};
    const buckets = new Map();
    let rows = 0, fields = 0, bytes = 0;
    for (const id of ids) {
        const s = stored(store, `${prefix}${id}-S`);
        if (s === undefined) continue;
        const row = cbor(Buffer.from(s, "base64"));
        const mask = typeof row.p === "number" ? row.p : 0;
        const out = {};
        for (let fi = 1; fi <= meta.fieldCount; fi++) {
            const name = names[fi];
            if (!name || SKIP_FIELDS.has(name) || constants[fi] !== undefined) continue;
            let value;
            if (types[fi] === "table") {
                if (Math.floor(mask / Math.pow(2, fi - 1)) % 2 !== 1) continue;
                const t = stored(store, `${prefix}${id}-${fi}`);
                if (t === undefined) continue;
                value = cbor(Buffer.from(t, "base64"));
                if (emptyIsNil[fi] && value && typeof value === "object" && Object.keys(value).length === 0) continue;
            } else {
                value = row[fi];
                if (value === undefined || value === null) continue;
            }
            if (norm[fi]) value = normalize(norm[fi], value);
            out[name] = value;
            fields++;
        }
        const b = Math.floor(id / 1000);
        if (!buckets.has(b)) buckets.set(b, {});
        buckets.get(b)[id] = out;
        rows++;
    }
    const dir = path.join(outDir, kind.toLowerCase());
    fs.mkdirSync(dir, { recursive: true });
    for (const [b, data] of buckets) {
        const text = JSON.stringify(data);
        bytes += text.length;
        fs.writeFileSync(path.join(dir, b + ".json"), text);
    }
    return { ids, rows, fields, bytes, buckets: [...buckets.keys()].sort((a, b) => a - b) };
}

// --- main -------------------------------------------------------------------------

const { file, store } = readToc();
fs.mkdirSync(outDir, { recursive: true });
const index = {
    format: 1,
    source: path.basename(file),
    flavor: store.get("X-Flavor") || null,
    build_commit: store.get("X-BUILD-COMMIT") || null,
    build_time: store.get("X-BUILD-TIME") || null,
    extracted: new Date().toISOString(),
    corrections_applied: false,
    kinds: {},
};
let total = 0;
for (const kind of ["Quest", "Npc", "Object", "Item"]) {
    const r = extract(store, kind);
    index.kinds[kind.toLowerCase()] = { rows: r.rows, buckets: r.buckets };
    if (kind === "Quest") index.quest_ids = r.ids.slice().sort((a, b) => a - b);
    total += r.bytes;
    console.log(`${kind}: ${r.rows} rows, ${r.fields} fields, ${(r.bytes / 1e6).toFixed(1)} MB in ${r.buckets.length} buckets`);
}
fs.writeFileSync(path.join(outDir, "index.json"), JSON.stringify(index));
console.log(`written ${outDir} (${(total / 1e6).toFixed(1)} MB) from ${file}`);

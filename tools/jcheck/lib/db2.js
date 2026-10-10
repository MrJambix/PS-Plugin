// DB2 tables (WDC3 / WDC4 / WDC5), decoded with WoWDBDefs column definitions.
//
//   const db2 = require("./lib/db2");
//   const def = db2.loadDbd("tools/jcheck/dbd/SpellEffect.dbd");
//   const table = db2.parse(bytes, def);       // picks the definition by the file's layout hash
//   table.rows   -> [{ ID, SpellID, Effect, ImplicitTarget: [a, b], ... }]
//   table.byId   -> Map(id -> row)
//
// The .dbd files come from https://github.com/wowdev/WoWDBDefs (definitions/),
// kept in tools/jcheck/dbd so the tools run offline. A client build missing
// there fails with the layout hash named; download the newer .dbd.
//
// Encrypted sections (tact key the client does not hold) arrive zero-filled
// from the CASC reader; they are skipped and counted in `table.skipped`.
"use strict";
const fs = require("fs");

// --- .dbd ---------------------------------------------------------------------

function loadDbd(file) {
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split(/\r?\n/);
    const columns = {};
    const versions = [];
    let i = 0;
    if (lines[0].trim() !== "COLUMNS") throw new Error(file + ": no COLUMNS header");
    for (i = 1; i < lines.length; i++) {
        const line = lines[i].replace(/\/\/.*$/, "").trim();
        if (!line) break;
        const m = line.match(/^(\w+)(?:<[^>]*>)?\s+(\w+)\??$/);
        if (m) columns[m[2]] = m[1];
    }
    let cur = null;
    for (; i < lines.length; i++) {
        const line = lines[i].replace(/\/\/.*$/, "").trim();
        if (!line) { cur = null; continue; }
        if (!cur) { cur = { layouts: [], builds: [], fields: [] }; versions.push(cur); }
        if (line.startsWith("LAYOUT ")) { cur.layouts.push(...line.slice(7).split(",").map(s => s.trim().toUpperCase())); continue; }
        if (line.startsWith("BUILD ")) { cur.builds.push(line.slice(6)); continue; }
        if (line.startsWith("COMMENT")) continue;
        const m = line.match(/^(?:\$([\w,]+)\$)?(\w+)(?:<(u?)(\d+)>)?(?:\[(\d+)\])?$/);
        if (!m) continue;
        const ann = new Set((m[1] || "").split(",").filter(Boolean));
        const name = m[2];
        cur.fields.push({
            name, type: columns[name] || "int",
            unsigned: m[3] === "u", bits: m[4] ? Number(m[4]) : 32, array: m[5] ? Number(m[5]) : 0,
            id: ann.has("id"), relation: ann.has("relation"), noninline: ann.has("noninline"),
        });
    }
    return { file, columns, versions };
}

function pickVersion(def, layout) {
    const hex = layout.toString(16).toUpperCase().padStart(8, "0");
    const v = def.versions.find(v => v.layouts.includes(hex));
    if (!v) throw new Error(`${def.file}: no definition for layout ${hex} (update the .dbd from WoWDBDefs)`);
    return v;
}

// --- the file -------------------------------------------------------------------

function parse(buf, def) {
    const magic = buf.toString("latin1", 0, 4);
    let h;
    if (magic === "WDC5") h = 136;
    else if (magic === "WDC3" || magic === "WDC4") h = 4;
    else throw new Error("not a WDC3/4/5 db2: " + JSON.stringify(magic));
    const recordCount = buf.readUInt32LE(h), fieldCount = buf.readUInt32LE(h + 4), recordSize = buf.readUInt32LE(h + 8);
    const layout = buf.readUInt32LE(h + 20);
    const flags = buf.readUInt16LE(h + 36), idIndex = buf.readUInt16LE(h + 38);
    const totalFieldCount = buf.readUInt32LE(h + 40);
    const storageInfoSize = buf.readUInt32LE(h + 52), commonSize = buf.readUInt32LE(h + 56), palletSize = buf.readUInt32LE(h + 60);
    const sectionCount = buf.readUInt32LE(h + 64);
    if (flags & 1) throw new Error("sparse (offset-map) tables are not handled");
    const version = pickVersion(def, layout);
    const inline = version.fields.filter(f => !f.noninline);
    if (inline.length !== fieldCount) throw new Error(`${def.file}: definition has ${inline.length} inline fields, file has ${fieldCount}`);

    let p = h + 68;
    const sections = [];
    for (let s = 0; s < sectionCount; s++) {
        sections.push({
            tact: buf.readBigUInt64LE(p), offset: buf.readUInt32LE(p + 8), records: buf.readUInt32LE(p + 12),
            strings: buf.readUInt32LE(p + 16), recordsEnd: buf.readUInt32LE(p + 20), idListSize: buf.readUInt32LE(p + 24),
            relSize: buf.readUInt32LE(p + 28), offsetMapCount: buf.readUInt32LE(p + 32), copyCount: buf.readUInt32LE(p + 36),
        });
        p += 40;
    }
    p += 4 * totalFieldCount;                       // field_structure: superseded by the storage info
    const storage = [];
    for (let f = 0; f < storageInfoSize / 24; f++) {
        storage.push({
            offsetBits: buf.readUInt16LE(p), sizeBits: buf.readUInt16LE(p + 2), extra: buf.readUInt32LE(p + 4),
            type: buf.readUInt32LE(p + 8), v1: buf.readUInt32LE(p + 12), v2: buf.readUInt32LE(p + 16), v3: buf.readUInt32LE(p + 20),
        });
        p += 24;
    }
    const palletAt = p; p += palletSize;
    const commonAt = p; p += commonSize;
    // WDC4+: per encrypted section, the ids it holds. Only skipped over here.
    if (magic !== "WDC3" && sections.length && p !== sections[0].offset) {
        let q = p;
        for (const s of sections) if (s.tact !== 0n) { const n = buf.readUInt32LE(q); q += 4 + 4 * n; }
        if (q === sections[0].offset) p = q;
    }
    if (sections.length && p !== sections[0].offset) throw new Error(`${def.file}: section data expected at ${p}, header says ${sections[0].offset}`);

    // Pallet and common data, located per field.
    const palletOf = [], commonOf = [];
    let pa = palletAt, ca = commonAt;
    storage.forEach((st, f) => {
        if (st.type === 3 || st.type === 4) { palletOf[f] = pa; pa += st.extra; }
        if (st.type === 2) {
            const m = new Map();
            for (let q = ca; q < ca + st.extra; q += 8) m.set(buf.readUInt32LE(q), buf.readUInt32LE(q + 4));
            commonOf[f] = m;
            ca += st.extra;
        }
    });

    // All string tables, in section order, as one virtual block.
    const stringParts = [];
    for (const s of sections) stringParts.push(buf.subarray(s.offset + s.records * recordSize, s.offset + s.records * recordSize + s.strings));
    const strings = Buffer.concat(stringParts);

    const f32 = Buffer.alloc(4);
    const asFloat = u => { f32.writeUInt32LE(u >>> 0, 0); return f32.readFloatLE(0); };
    const signed = (v, bits) => (bits < 32 && v >= 2 ** (bits - 1)) ? v - 2 ** bits : (bits === 32 ? v | 0 : v);

    function bitsAt(rec, offBits, nBits) {
        // Little-endian bit field, up to 32 bits wide.
        let v = 0;
        for (let b = 0; b < nBits; b++) {
            const bit = offBits + b;
            if ((buf[rec + (bit >> 3)] >> (bit & 7)) & 1) v += 2 ** b;
        }
        return v;
    }

    const rows = [];
    const byId = new Map();
    let skipped = 0;
    let globalIndex = 0;
    for (const s of sections) {
        const recBase = s.offset;
        let q = s.offset + s.records * recordSize + s.strings;
        const idList = [];
        for (let k = 0; k < s.idListSize / 4; k++) idList.push(buf.readUInt32LE(q + 4 * k));
        q += s.idListSize;
        const copies = [];
        for (let k = 0; k < s.copyCount; k++) { copies.push([buf.readUInt32LE(q), buf.readUInt32LE(q + 4)]); q += 8; }
        q += 6 * s.offsetMapCount;
        const relation = new Map();
        if (s.relSize > 0) {
            const n = buf.readUInt32LE(q);
            for (let k = 0; k < n; k++) relation.set(buf.readUInt32LE(q + 12 + 8 * k + 4), buf.readUInt32LE(q + 12 + 8 * k));
        }
        // An encrypted section the client cannot read is all zeros.
        const encrypted = s.tact !== 0n && !buf.subarray(recBase, recBase + s.records * recordSize).some(b => b !== 0);
        if (encrypted) { skipped += s.records; globalIndex += s.records; continue; }

        const sectionRows = new Map();
        for (let r = 0; r < s.records; r++, globalIndex++) {
            const rec = recBase + r * recordSize;
            const row = {};
            let id = idList.length ? idList[r] : undefined;
            if (id === undefined) {
                const st = storage[idIndex];
                id = st.type === 0 ? buf.readUInt32LE(rec + (st.offsetBits >> 3)) : bitsAt(rec, st.offsetBits, st.sizeBits);
            }
            for (let f = 0; f < inline.length; f++) {
                const fd = inline[f], st = storage[f];
                const n = fd.array || 1;
                const out = [];
                if (st.type === 0) {
                    const ebytes = fd.type === "float" || fd.type === "string" || fd.type === "locstring" ? 4 : fd.bits / 8;
                    for (let j = 0; j < n; j++) {
                        const at = rec + (st.offsetBits >> 3) + j * ebytes;
                        let v;
                        if (fd.type === "float") v = buf.readFloatLE(at);
                        else if (fd.type === "string" || fd.type === "locstring") {
                            const raw = buf.readUInt32LE(at);
                            const pos = globalIndex * recordSize + (at - rec) + raw - recordCount * recordSize;
                            const end = strings.indexOf(0, pos);
                            v = pos >= 0 && pos < strings.length ? strings.toString("utf8", pos, end < 0 ? strings.length : end) : "";
                        } else if (ebytes === 1) v = fd.unsigned ? buf.readUInt8(at) : buf.readInt8(at);
                        else if (ebytes === 2) v = fd.unsigned ? buf.readUInt16LE(at) : buf.readInt16LE(at);
                        else if (ebytes === 8) v = Number(fd.unsigned ? buf.readBigUInt64LE(at) : buf.readBigInt64LE(at));
                        else v = fd.unsigned ? buf.readUInt32LE(at) : buf.readInt32LE(at);
                        out.push(v);
                    }
                } else if (st.type === 1 || st.type === 5) {
                    let v = bitsAt(rec, st.offsetBits, st.sizeBits);
                    if (st.type === 5) v = signed(v, st.sizeBits);
                    out.push(fd.type === "float" ? asFloat(v) : v);
                } else if (st.type === 2) {
                    const m = commonOf[f];
                    const raw = m.has(id) ? m.get(id) : st.v1;
                    out.push(fd.type === "float" ? asFloat(raw) : (fd.unsigned ? raw >>> 0 : signed(raw, fd.bits)));
                } else if (st.type === 3 || st.type === 4) {
                    const index = bitsAt(rec, st.offsetBits, st.sizeBits);
                    const count = st.type === 4 ? st.v3 : 1;
                    for (let j = 0; j < count; j++) {
                        const raw = buf.readUInt32LE(palletOf[f] + 4 * (index * count + j));
                        out.push(fd.type === "float" ? asFloat(raw) : (fd.unsigned ? raw >>> 0 : signed(raw, fd.bits)));
                    }
                } else {
                    throw new Error(`field ${fd.name}: storage type ${st.type} not handled`);
                }
                row[fd.name] = fd.array ? out : out[0];
            }
            for (const fd of version.fields) {
                if (!fd.noninline) continue;
                if (fd.id) row[fd.name] = id;
                else if (fd.relation) row[fd.name] = relation.has(r) ? relation.get(r) : 0;
            }
            if (row.ID === undefined) row.ID = id;
            rows.push(row);
            sectionRows.set(id, row);
            byId.set(id, row);
        }
        for (const [newId, from] of copies) {
            const src = sectionRows.get(from) || byId.get(from);
            if (!src) continue;
            const row = Object.assign({}, src, { ID: newId });
            rows.push(row);
            byId.set(newId, row);
        }
    }
    return { layout: layout.toString(16).toUpperCase(), rows, byId, skipped, builds: version.builds };
}

module.exports = { loadDbd, parse };

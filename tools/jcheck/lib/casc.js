// The game's CASC store, read offline (Node). The same walk as JCore's
// services/casc.lua, which proved every step against this install; this copy
// exists because the extractors want whole multi-megabyte tables (DB2s), which
// the Lua reader under fengari would take minutes over.
//
//   const casc = require("./lib/casc").open({ wow: "C:/Program Files (x86)/World of Warcraft", product: "wow_classic_era" });
//   const bytes = casc.read("DBFilesClient/SpellEffect.db2");   // Buffer, or throws
//
// .build.info -> build config -> encoding (ckey -> ekey) -> root (name hash ->
// fdid + ckey) -> local index (ekey -> archive, offset, size) -> data.NNN
// (30-byte local header, then BLTE: N raw / Z zlib / E encrypted chunks).
// An encrypted chunk is filled with zeros and counted in `stats.encrypted`:
// DB2 sections under a key the client does not hold read as zero records.
"use strict";
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// --- Jenkins lookup3 hashlittle2, the root's name hash ------------------------

function rot(x, k) { return ((x << k) | (x >>> (32 - k))) >>> 0; }

function hashlittle2(buf) {
    let length = buf.length;
    let a = (0xdeadbeef + length) >>> 0, b = a, c = a;
    let p = 0;
    while (length > 12) {
        a = (a + buf.readUInt32LE(p)) >>> 0;
        b = (b + buf.readUInt32LE(p + 4)) >>> 0;
        c = (c + buf.readUInt32LE(p + 8)) >>> 0;
        a = (a - c) >>> 0; a = (a ^ rot(c, 4)) >>> 0;  c = (c + b) >>> 0;
        b = (b - a) >>> 0; b = (b ^ rot(a, 6)) >>> 0;  a = (a + c) >>> 0;
        c = (c - b) >>> 0; c = (c ^ rot(b, 8)) >>> 0;  b = (b + a) >>> 0;
        a = (a - c) >>> 0; a = (a ^ rot(c, 16)) >>> 0; c = (c + b) >>> 0;
        b = (b - a) >>> 0; b = (b ^ rot(a, 19)) >>> 0; a = (a + c) >>> 0;
        c = (c - b) >>> 0; c = (c ^ rot(b, 4)) >>> 0;  b = (b + a) >>> 0;
        length -= 12;
        p += 12;
    }
    if (length === 0) return [c, b];
    const k = i => (p + i < buf.length ? buf[p + i] : 0);
    a = (a + k(0) + k(1) * 256 + k(2) * 65536 + k(3) * 16777216) >>> 0;
    b = (b + k(4) + k(5) * 256 + k(6) * 65536 + k(7) * 16777216) >>> 0;
    c = (c + k(8) + k(9) * 256 + k(10) * 65536 + k(11) * 16777216) >>> 0;
    c = (c ^ b) >>> 0; c = (c - rot(b, 14)) >>> 0;
    a = (a ^ c) >>> 0; a = (a - rot(c, 11)) >>> 0;
    b = (b ^ a) >>> 0; b = (b - rot(a, 25)) >>> 0;
    c = (c ^ b) >>> 0; c = (c - rot(b, 16)) >>> 0;
    a = (a ^ c) >>> 0; a = (a - rot(c, 4)) >>> 0;
    b = (b ^ a) >>> 0; b = (b - rot(a, 14)) >>> 0;
    c = (c ^ b) >>> 0; c = (c - rot(b, 24)) >>> 0;
    return [c, b];
}

/** The 8 bytes the root stores for a path: le32(secondary) .. le32(primary), as hex. */
function nameHash(p) {
    const [pc, pb] = hashlittle2(Buffer.from(String(p).replace(/\//g, "\\").toUpperCase(), "latin1"));
    const out = Buffer.alloc(8);
    out.writeUInt32LE(pb, 0);
    out.writeUInt32LE(pc, 4);
    return out.toString("hex");
}

// --- the store ---------------------------------------------------------------------

function parseTable(text) {
    const lines = text.split(/\r?\n/).filter(Boolean);
    const cols = lines[0].split("|").map(c => c.split("!")[0]);
    return lines.slice(1).map(line => {
        const cells = line.split("|");
        const row = {};
        cols.forEach((c, i) => { row[c] = cells[i]; });
        return row;
    });
}

function parseConfig(text) {
    const out = {};
    for (const line of text.split(/\r?\n/)) {
        const m = line.match(/^\s*([\w-]+)\s*=\s*(.*?)\s*$/);
        if (m) out[m[1]] = m[2];
    }
    return out;
}

function open(opts) {
    const wow = opts.wow || "C:/Program Files (x86)/World of Warcraft";
    const dataDir = path.join(wow, "Data", "data");
    const stats = { encrypted: 0, chunks: 0, reads: 0 };

    const rows = parseTable(fs.readFileSync(path.join(wow, ".build.info"), "latin1"));
    const row = rows.find(r => r.Product === opts.product) || null;
    if (!row) throw new Error(`product ${opts.product} is not in .build.info (have: ${rows.map(r => r.Product).join(", ")})`);
    const buildKey = row["Build Key"].toLowerCase();
    const cfg = parseConfig(fs.readFileSync(path.join(wow, "Data", "config", buildKey.slice(0, 2), buildKey.slice(2, 4), buildKey), "latin1"));
    const rootCkey = (cfg.root || "").split(/\s+/)[0];
    const [, encEkey] = (cfg.encoding || "").split(/\s+/);
    if (!rootCkey || !encEkey) throw new Error("build config lacks root or encoding keys");
    const build = { product: row.Product, version: row.Version, key: buildKey };

    // Local indices: the newest version of each bucket's .idx.
    const idxFiles = {};
    for (const f of fs.readdirSync(dataDir)) {
        const m = f.match(/^([0-9a-f]{2})([0-9a-f]{8})\.idx$/i);
        if (!m) continue;
        const b = parseInt(m[1], 16), v = parseInt(m[2], 16);
        if (!idxFiles[b] || idxFiles[b].v < v) idxFiles[b] = { v, f };
    }
    const idxCache = {};
    function loadIdx(bucket) {
        if (idxCache[bucket]) return idxCache[bucket];
        const entry = idxFiles[bucket];
        if (!entry) throw new Error(`no index for bucket ${bucket}`);
        const raw = fs.readFileSync(path.join(dataDir, entry.f));
        const headerHashSize = raw.readUInt32LE(0);
        const version = raw.readUInt16LE(8);
        const spanSize = raw[12], spanOffs = raw[13], keyBytes = raw[14], offsBits = raw[15];
        if (version !== 7) throw new Error(`index ${entry.f} has version ${version}`);
        const headerEnd = 8 + headerHashSize;
        const entriesAt = headerEnd + ((16 - (headerEnd % 16)) % 16);
        const entriesSize = raw.readUInt32LE(entriesAt);
        const entryLen = keyBytes + spanOffs + spanSize;
        const idx = { raw, first: entriesAt + 8, count: Math.floor(entriesSize / entryLen), entryLen, keyBytes, spanOffs, spanSize, offsBits };
        idxCache[bucket] = idx;
        return idx;
    }
    function bucketOf(ekey) {
        let b = 0;
        for (let i = 0; i < 9; i++) b ^= ekey[i];
        return (b & 0xf) ^ (b >> 4);
    }
    function findLocal(ekeyHex) {
        const ekey = Buffer.from(ekeyHex, "hex");
        const idx = loadIdx(bucketOf(ekey));
        const key = ekey.subarray(0, idx.keyBytes);
        let lo = 0, hi = idx.count - 1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const at = idx.first + mid * idx.entryLen;
            const c = Buffer.compare(idx.raw.subarray(at, at + idx.keyBytes), key);
            if (c === 0) {
                let v = 0;
                for (let i = 0; i < idx.spanOffs; i++) v = v * 256 + idx.raw[at + idx.keyBytes + i];
                const per = Math.pow(2, idx.offsBits);
                return { archive: Math.floor(v / per), offset: v % per, size: idx.raw.readUInt32LE(at + idx.keyBytes + idx.spanOffs) };
            }
            if (c < 0) lo = mid + 1; else hi = mid - 1;
        }
        return null;
    }

    const fds = {};
    function readAt(archive, offset, size) {
        const file = path.join(dataDir, "data." + String(archive).padStart(3, "0"));
        if (!fds[file]) fds[file] = fs.openSync(file, "r");
        const buf = Buffer.alloc(size);
        fs.readSync(fds[file], buf, 0, size, offset);
        stats.reads++;
        return buf;
    }

    const LOCAL_HEADER = 30;
    function blte(entry) {
        // Usually a 30-byte local header precedes the BLTE container. Forever's
        // client (12.0 engine) also stores entries with the container right at the
        // index offset, so look at both places.
        const head = readAt(entry.archive, entry.offset, Math.min(entry.size, LOCAL_HEADER + 4));
        let skip;
        if (head.toString("latin1", LOCAL_HEADER, LOCAL_HEADER + 4) === "BLTE") skip = LOCAL_HEADER;
        else if (head.toString("latin1", 0, 4) === "BLTE") skip = 0;
        else throw new Error("no BLTE header");
        const raw = readAt(entry.archive, entry.offset + skip, entry.size - skip);
        const headerSize = raw.readUInt32BE(4);
        const chunks = [];
        if (headerSize === 0) {
            chunks.push({ at: 8, comp: raw.length - 8, decomp: null });
        } else {
            const count = raw.readUIntBE(9, 3);
            let p = 12, at = headerSize;
            for (let i = 0; i < count; i++) {
                const comp = raw.readUInt32BE(p), decomp = raw.readUInt32BE(p + 4);
                chunks.push({ at, comp, decomp });
                at += comp;
                p += 24;
            }
        }
        const parts = [];
        for (const c of chunks) {
            stats.chunks++;
            const body = raw.subarray(c.at, c.at + c.comp);
            const kind = String.fromCharCode(body[0]);
            let out;
            if (kind === "N") out = body.subarray(1);
            else if (kind === "Z") out = zlib.inflateSync(body.subarray(1));
            else if (kind === "E") {
                if (c.decomp == null) throw new Error("encrypted single-chunk file");
                stats.encrypted++;
                out = Buffer.alloc(c.decomp);
            } else throw new Error(`BLTE chunk kind ${JSON.stringify(kind)} not handled`);
            if (c.decomp != null && out.length !== c.decomp) throw new Error(`chunk decoded to ${out.length}, expected ${c.decomp}`);
            parts.push(out);
        }
        return Buffer.concat(parts);
    }

    function readEkey(ekeyHex) {
        const entry = findLocal(ekeyHex);
        if (!entry) throw new Error(`ekey ${ekeyHex} is not in the local archives`);
        return blte(entry);
    }

    // Encoding: content key -> encoded key, decoded whole once.
    let encoding = null;
    function ckeyToEkey(ckeyHex) {
        if (!encoding) {
            const buf = readEkey(encEkey);
            if (buf.toString("latin1", 0, 2) !== "EN") throw new Error("encoding file has a bad header");
            // "EN", version, ckey size, ekey size, page kb (u16be), espec kb, page count (u32be at 9) ...
            const cs = buf[3], es = buf[4], pageKb = buf.readUInt16BE(5), pages = buf.readUInt32BE(9);
            const especSize = buf.readUInt32BE(18);
            const tableAt = 22 + especSize;
            encoding = { buf, cs, es, pageBytes: pageKb * 1024, pages, tableAt, pagesAt: tableAt + pages * (cs + 16) };
        }
        const { buf, cs, es, pageBytes, pages, tableAt, pagesAt } = encoding;
        const ckey = Buffer.from(ckeyHex, "hex");
        let lo = 0, hi = pages - 1, page = 0;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const at = tableAt + mid * (cs + 16);
            if (Buffer.compare(buf.subarray(at, at + cs), ckey) <= 0) { page = mid; lo = mid + 1; } else hi = mid - 1;
        }
        const pg = buf.subarray(pagesAt + page * pageBytes, pagesAt + (page + 1) * pageBytes);
        let p = 0;
        while (p + 6 + cs + es <= pg.length) {
            const keyCount = pg[p];
            if (keyCount === 0) break;
            if (Buffer.compare(pg.subarray(p + 6, p + 6 + cs), ckey) === 0) return pg.subarray(p + 6 + cs, p + 6 + cs + es).toString("hex");
            p += 6 + cs + keyCount * es;
        }
        return null;
    }

    // Root: name hash -> { fdid, ckey }, for the paths asked for.
    let rootBuf = null;
    function root() {
        if (rootBuf) return rootBuf;
        const ekey = ckeyToEkey(rootCkey);
        if (!ekey) throw new Error("root content key is not in the encoding file");
        rootBuf = readEkey(ekey);
        return rootBuf;
    }

    /** fdid and content key of each path (or fdid number), enUS (or all-locale) copy preferred. */
    function lookup(names) {
        const buf = root();
        const want = new Map();   // hash hex -> name
        const wantFdid = new Map(); // fdid -> name
        for (const n of names) {
            if (typeof n === "number") wantFdid.set(n, n); else want.set(nameHash(n), n);
        }
        let p = 0, version = 0, total = -1, named = -1;
        if (buf.toString("latin1", 0, 4) === "TSFM") {
            const a = buf.readUInt32LE(4), c = buf.readUInt32LE(8);
            if (a >= 12 && a <= 64 && c <= 10) { version = c; total = buf.readUInt32LE(12); named = buf.readUInt32LE(16); p = a; }
            else { version = 1; total = a; named = c; p = 12; }
        }
        const allNamed = total === named;
        const found = new Map();
        while (p + 12 <= buf.length) {
            const n = buf.readUInt32LE(p);
            let locale, noHash;
            if (version >= 2) {
                locale = buf.readUInt32LE(p + 4);
                const cf1 = buf.readUInt32LE(p + 8), cf2 = buf.readUInt32LE(p + 12);
                noHash = !allNamed && (((cf1 >>> 28) & 1) === 1 || ((cf2 >>> 28) & 1) === 1);
                p += 17;
            } else {
                const content = buf.readUInt32LE(p + 4);
                locale = buf.readUInt32LE(p + 8);
                noHash = version >= 1 && ((content >>> 28) & 1) === 1;
                p += 12;
            }
            const deltasAt = p, ckeysAt = p + 4 * n, hashesAt = ckeysAt + 16 * n;
            p = hashesAt + (noHash ? 0 : 8 * n);
            const ours = locale === 0xffffffff || (locale & 2) === 2;
            let fdid = -1;
            for (let i = 0; i < n; i++) {
                fdid += 1 + buf.readInt32LE(deltasAt + 4 * i);
                let name = wantFdid.get(fdid);
                if (name === undefined && !noHash) name = want.get(buf.toString("hex", hashesAt + 8 * i, hashesAt + 8 * i + 8));
                if (name !== undefined) {
                    const prior = found.get(name);
                    if (!prior || (ours && !prior.ours)) {
                        found.set(name, { fdid, ckey: buf.toString("hex", ckeysAt + 16 * i, ckeysAt + 16 * i + 16), ours, locale });
                    }
                }
            }
        }
        return found;
    }

    const resolved = new Map();
    /** A file's bytes by path or fdid. Throws with the reason when it cannot. */
    function read(name) {
        if (!resolved.has(name)) {
            const f = lookup([name]).get(name);
            resolved.set(name, f || null);
        }
        const f = resolved.get(name);
        if (!f) throw new Error(`${name} is not in the ${opts.product} root`);
        const ekey = ckeyToEkey(f.ckey);
        if (!ekey) throw new Error(`${name}: content key not in the encoding file`);
        return readEkey(ekey);
    }

    /** Diagnostics: every root entry for a path or fdid, with its index entry and first archive bytes. */
    function locate(name) {
        const buf = root();
        const want = typeof name === "number" ? null : nameHash(name);
        const out = [];
        let p = buf.toString("latin1", 0, 4) === "TSFM" ? buf.readUInt32LE(4) : 0;
        const total = buf.readUInt32LE(12), named = buf.readUInt32LE(16);
        while (p + 12 <= buf.length) {
            const n = buf.readUInt32LE(p), locale = buf.readUInt32LE(p + 4);
            const cf1 = buf.readUInt32LE(p + 8), cf2 = buf.readUInt32LE(p + 12);
            const noHash = total !== named && (((cf1 >>> 28) & 1) === 1 || ((cf2 >>> 28) & 1) === 1);
            p += 17;
            const deltasAt = p, ckeysAt = p + 4 * n, hashesAt = ckeysAt + 16 * n;
            p = hashesAt + (noHash ? 0 : 8 * n);
            let fdid = -1;
            for (let i = 0; i < n; i++) {
                fdid += 1 + buf.readInt32LE(deltasAt + 4 * i);
                const hit = want ? (!noHash && buf.toString("hex", hashesAt + 8 * i, hashesAt + 8 * i + 8) === want) : fdid === name;
                if (!hit) continue;
                const ckey = buf.toString("hex", ckeysAt + 16 * i, ckeysAt + 16 * i + 16);
                const ekey = ckeyToEkey(ckey);
                const entry = ekey && findLocal(ekey);
                let head = null;
                if (entry) head = readAt(entry.archive, entry.offset, Math.min(64, entry.size)).toString("hex");
                out.push({ fdid, locale: locale.toString(16), cf1: cf1.toString(16), cf2: cf2.toString(16), ckey, ekey, entry, head });
            }
        }
        return out;
    }

    function close() {
        for (const k of Object.keys(fds)) fs.closeSync(fds[k]);
    }

    return { build, read, lookup, locate, stats, close, nameHash };
}

module.exports = { open, nameHash, hashlittle2 };

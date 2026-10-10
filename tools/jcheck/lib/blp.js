// The client's BLP2 textures, decoded offline (Node): palettised (1/4/8-bit
// alpha), DXT1/3/5 and raw BGRA. The largest mip only. BLP1 is not handled:
// nothing the art pack reads uses it.
//
//   const { decode } = require("./lib/blp");
//   const img = decode(casc.read("Interface/Cursor/Attack.blp"));  // { w, h, rgba: Buffer }
"use strict";

function rgb565(c) {
    const r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
    return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)];
}

function dxtColorBlock(buf, at, out, w, h, bx, by, dxt1) {
    const c0 = buf.readUInt16LE(at), c1 = buf.readUInt16LE(at + 2);
    const bits = buf.readUInt32LE(at + 4);
    const p0 = rgb565(c0), p1 = rgb565(c1);
    const pal = [p0.concat(255), p1.concat(255)];
    if (!dxt1 || c0 > c1) {
        pal.push([(2 * p0[0] + p1[0]) / 3 | 0, (2 * p0[1] + p1[1]) / 3 | 0, (2 * p0[2] + p1[2]) / 3 | 0, 255]);
        pal.push([(p0[0] + 2 * p1[0]) / 3 | 0, (p0[1] + 2 * p1[1]) / 3 | 0, (p0[2] + 2 * p1[2]) / 3 | 0, 255]);
    } else {
        pal.push([(p0[0] + p1[0]) >> 1, (p0[1] + p1[1]) >> 1, (p0[2] + p1[2]) >> 1, 255]);
        pal.push([0, 0, 0, 0]);
    }
    for (let i = 0; i < 16; i++) {
        const x = bx + (i & 3), y = by + (i >> 2);
        if (x >= w || y >= h) continue;
        const c = pal[(bits >>> (2 * i)) & 3];
        const o = (y * w + x) * 4;
        out[o] = c[0]; out[o + 1] = c[1]; out[o + 2] = c[2];
        if (dxt1) out[o + 3] = c[3];
    }
}

function decode(buf) {
    const magic = buf.toString("latin1", 0, 4);
    if (magic !== "BLP2") throw new Error("not BLP2: " + magic);
    const compression = buf[8], alphaDepth = buf[9], alphaType = buf[10];
    const w = buf.readUInt32LE(12), h = buf.readUInt32LE(16);
    const off = buf.readUInt32LE(20), size = buf.readUInt32LE(20 + 64);
    const out = Buffer.alloc(w * h * 4);
    const data = buf.subarray(off, off + size);
    if (compression === 1) {
        const pal = buf.subarray(148, 148 + 1024);
        for (let i = 0; i < w * h; i++) {
            const p = data[i] * 4;
            out[i * 4] = pal[p + 2]; out[i * 4 + 1] = pal[p + 1]; out[i * 4 + 2] = pal[p]; out[i * 4 + 3] = 255;
        }
        const a = data.subarray(w * h);
        if (alphaDepth === 8) for (let i = 0; i < w * h; i++) out[i * 4 + 3] = a[i];
        else if (alphaDepth === 1) for (let i = 0; i < w * h; i++) out[i * 4 + 3] = (a[i >> 3] >> (i & 7)) & 1 ? 255 : 0;
        else if (alphaDepth === 4) for (let i = 0; i < w * h; i++) out[i * 4 + 3] = ((a[i >> 1] >> ((i & 1) * 4)) & 15) * 17;
    } else if (compression === 2) {
        let at = 0;
        for (let by = 0; by < h; by += 4) for (let bx = 0; bx < w; bx += 4) {
            if (alphaType === 0 || alphaDepth <= 1) {
                dxtColorBlock(data, at, out, w, h, bx, by, true);
                if (alphaDepth === 0) for (let i = 0; i < 16; i++) {
                    const x = bx + (i & 3), y = by + (i >> 2);
                    if (x < w && y < h) out[(y * w + x) * 4 + 3] = 255;
                }
                at += 8;
            } else if (alphaType === 1) {
                for (let i = 0; i < 16; i++) {
                    const x = bx + (i & 3), y = by + (i >> 2);
                    const v = (data[at + (i >> 1)] >> ((i & 1) * 4)) & 15;
                    if (x < w && y < h) out[(y * w + x) * 4 + 3] = v * 17;
                }
                dxtColorBlock(data, at + 8, out, w, h, bx, by, false);
                at += 16;
            } else {
                const a0 = data[at], a1 = data[at + 1];
                const pal = [a0, a1];
                if (a0 > a1) for (let k = 1; k <= 6; k++) pal.push(((7 - k) * a0 + k * a1) / 7 | 0);
                else { for (let k = 1; k <= 4; k++) pal.push(((5 - k) * a0 + k * a1) / 5 | 0); pal.push(0, 255); }
                let bits = 0n;
                for (let k = 0; k < 6; k++) bits |= BigInt(data[at + 2 + k]) << BigInt(8 * k);
                for (let i = 0; i < 16; i++) {
                    const x = bx + (i & 3), y = by + (i >> 2);
                    const idx = Number((bits >> BigInt(3 * i)) & 7n);
                    if (x < w && y < h) out[(y * w + x) * 4 + 3] = pal[idx];
                }
                dxtColorBlock(data, at + 8, out, w, h, bx, by, false);
                at += 16;
            }
        }
    } else if (compression === 3) {
        for (let i = 0; i < w * h; i++) {
            out[i * 4] = data[i * 4 + 2]; out[i * 4 + 1] = data[i * 4 + 1]; out[i * 4 + 2] = data[i * 4]; out[i * 4 + 3] = data[i * 4 + 3];
        }
    } else throw new Error("compression " + compression);
    return { w, h, rgba: out };
}

module.exports = { decode };

// An addon's SavedVariables file (WTF/.../SavedVariables/<Addon>.lua), read
// into plain objects: { <global name>: value }. The game writes these as Lua
// table constructors only -- ["key"] = value, [1] = value, strings, numbers,
// booleans, nil -- so this reads that much and no other Lua. A table's
// keys come back as object keys (numbers turned to strings, as JSON does).
//
//   const { read } = require("./lib/savedvars");
//   const vars = read(fs.readFileSync(file, "utf8"));   // vars.TrackMeDB
"use strict";

function read(src) {
    let pos = 0;
    const fail = what => { throw new Error(`savedvars: ${what} at ${pos}: ${JSON.stringify(src.slice(pos, pos + 40))}`); };
    function space() {
        for (;;) {
            while (pos < src.length && /[\s,;]/.test(src[pos])) pos++;
            if (!src.startsWith("--", pos)) return;
            while (pos < src.length && src[pos] !== "\n") pos++;
        }
    }
    function string() {
        const quote = src[pos++];
        let out = "";
        for (;;) {
            if (pos >= src.length) fail("unfinished string");
            const c = src[pos++];
            if (c === quote) return out;
            if (c !== "\\") { out += c; continue; }
            const e = src[pos++];
            if (e === "n") out += "\n";
            else if (e === "t") out += "\t";
            else if (e === "r") out += "\r";
            else if (/\d/.test(e)) {
                let d = e;
                while (d.length < 3 && /\d/.test(src[pos])) d += src[pos++];
                out += String.fromCharCode(Number(d));
            } else out += e;
        }
    }
    function value() {
        space();
        const c = src[pos];
        if (c === "{") return table();
        if (c === '"' || c === "'") return string();
        const m = /^(?:true|false|nil|-?(?:0x[0-9a-f]+|inf|nan|\d+\.?\d*(?:e[-+]?\d+)?))/i.exec(src.slice(pos, pos + 64));
        if (!m) fail("not a value");
        pos += m[0].length;
        if (m[0] === "true") return true;
        if (m[0] === "false") return false;
        if (m[0] === "nil") return null;
        return Number(m[0]);
    }
    function table() {
        pos++;
        const t = {};
        let n = 1;
        for (;;) {
            space();
            if (pos >= src.length) fail("unfinished table");
            if (src[pos] === "}") { pos++; return t; }
            if (src[pos] === "[") {
                pos++;
                const k = value();
                space();
                if (src[pos++] !== "]") fail("no ]");
                space();
                if (src[pos++] !== "=") fail("no =");
                t[k] = value();
                continue;
            }
            const m = /^[A-Za-z_]\w*\s*=/.exec(src.slice(pos, pos + 128));
            if (m) {
                pos += m[0].length;
                t[m[0].replace(/\s*=$/, "")] = value();
            } else {
                t[n++] = value();
            }
        }
    }
    const vars = {};
    for (;;) {
        space();
        if (pos >= src.length) return vars;
        const m = /^[A-Za-z_]\w*/.exec(src.slice(pos, pos + 128));
        if (!m) fail("not a variable");
        pos += m[0].length;
        space();
        if (src[pos++] !== "=") fail("no =");
        vars[m[0]] = value();
    }
}

module.exports = { read };

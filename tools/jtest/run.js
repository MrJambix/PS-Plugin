#!/usr/bin/env node
// jtest -- offline Lua test runner for the project's Lua modules.
//
// Runs every tools/jtest/tests/*.lua file in a fengari (Lua 5.3 in JS) state
// whose package.path resolves `require("jcore/lib/image")` against scripts/.
// A JS helper table `jtest` is exposed to the tests for things pure Lua
// cannot do offline (decode a PNG with pngjs, write a file).
//
// Usage: node tools/jtest/run.js [test-name-substring ...]

"use strict";

const fs = require("fs");
const path = require("path");
const fengari = require("fengari");
const { PNG } = require("pngjs");

const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const ROOT = path.resolve(__dirname, "..", "..");
const SCRIPTS = path.join(ROOT, "scripts");
const TESTS = path.join(__dirname, "tests");

// --- binary-safe string helpers ---------------------------------------------
// Lua strings are byte strings. fengari represents them as Uint8Array; never
// route binary data through to_jsstring/to_luastring (those are UTF-8).

function bufToLua(L, buf) {
    const u8 = buf instanceof Uint8Array ? buf : Buffer.from(buf);
    lua.lua_pushlstring(L, u8, u8.length);
}

function luaToBuf(L, idx) {
    const u8 = lua.lua_tolstring(L, idx);
    if (u8 === null) throw new Error("expected a string");
    return Buffer.from(u8.buffer, u8.byteOffset, u8.length);
}

function textToLua(L, s) {
    lua.lua_pushstring(L, to_luastring(String(s)));
}

function slashes(p) {
    return p.replace(/\\/g, "/");
}

// --- jtest helper table ------------------------------------------------------

const helpers = {
    // jtest.png_decode(bytes) -> w, h, rgba_bytes   (or nil, err)
    png_decode(L) {
        const bytes = luaToBuf(L, 1);
        let png;
        try {
            png = PNG.sync.read(bytes);
        } catch (e) {
            lua.lua_pushnil(L);
            textToLua(L, e.message || String(e));
            return 2;
        }
        lua.lua_pushinteger(L, png.width);
        lua.lua_pushinteger(L, png.height);
        bufToLua(L, png.data);
        return 3;
    },

    // jtest.png_encode(w, h, rgba_bytes) -> png_bytes   (a reference PNG from pngjs)
    png_encode(L) {
        const w = lua.lua_tointeger(L, 1);
        const h = lua.lua_tointeger(L, 2);
        const data = luaToBuf(L, 3);
        const png = new PNG({ width: w, height: h });
        data.copy(png.data, 0, 0, Math.min(data.length, png.data.length));
        bufToLua(L, PNG.sync.write(png));
        return 1;
    },

    // jtest.write_file(path, bytes) -> true   (relative paths resolve against the scratch dir)
    write_file(L) {
        const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
        const bytes = luaToBuf(L, 2);
        const target = path.isAbsolute(p) ? p : path.join(__dirname, "out", p);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, bytes);
        lua.lua_pushboolean(L, true);
        return 1;
    },

    // jtest.read_file(path) -> bytes | nil, err
    read_file(L) {
        const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
        const target = path.isAbsolute(p) ? p : path.join(ROOT, p);
        try {
            bufToLua(L, fs.readFileSync(target));
            return 1;
        } catch (e) {
            lua.lua_pushnil(L);
            textToLua(L, e.message || String(e));
            return 2;
        }
    },

    // jtest.hex(bytes) -> "0a0b..."  (handy in failure messages)
    hex(L) {
        textToLua(L, luaToBuf(L, 1).toString("hex"));
        return 1;
    },

    // jtest.read_partial(path, offset, size) -> bytes | nil, err   (absolute paths only;
    // for reading slices of files far too big to load, such as game archives)
    read_partial(L) {
        const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
        const offset = lua.lua_tonumber(L, 2);
        const size = lua.lua_tonumber(L, 3);
        let fd;
        try {
            fd = fs.openSync(p, "r");
            const buf = Buffer.alloc(size);
            const n = fs.readSync(fd, buf, 0, size, offset);
            bufToLua(L, buf.subarray(0, n));
            return 1;
        } catch (e) {
            lua.lua_pushnil(L);
            textToLua(L, e.message || String(e));
            return 2;
        } finally {
            if (fd !== undefined) fs.closeSync(fd);
        }
    },

    // jtest.file_size(path) -> bytes (0 when missing)
    file_size(L) {
        const p = to_jsstring(lauxlib.luaL_checkstring(L, 1));
        try {
            lua.lua_pushnumber(L, fs.statSync(p).size);
        } catch (e) {
            lua.lua_pushnumber(L, 0);
        }
        return 1;
    },

    // jtest.env(name) -> string | nil
    env(L) {
        const v = process.env[to_jsstring(lauxlib.luaL_checkstring(L, 1))];
        if (v === undefined) lua.lua_pushnil(L); else textToLua(L, v);
        return 1;
    },

    // jtest.clock() -> seconds, wall time
    clock(L) {
        lua.lua_pushnumber(L, Date.now() / 1000);
        return 1;
    },

    // jtest.deflate(bytes, level?) -> zlib_bytes   (a reference zlib stream from Node,
    // for exercising the pure-Lua inflater; level 0 gives stored blocks)
    deflate(L) {
        const bytes = luaToBuf(L, 1);
        const level = lua.lua_isnoneornil(L, 2) ? 6 : lua.lua_tointeger(L, 2);
        bufToLua(L, require("zlib").deflateSync(bytes, { level }));
        return 1;
    },

    // jtest.inflate(zlib_bytes) -> bytes | nil, err   (Node's inflater, as an oracle)
    inflate(L) {
        try {
            bufToLua(L, require("zlib").inflateSync(luaToBuf(L, 1)));
            return 1;
        } catch (e) {
            lua.lua_pushnil(L);
            textToLua(L, e.message || String(e));
            return 2;
        }
    },
};

// --- Lua state ---------------------------------------------------------------

function makeState() {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);

    // package.path: scripts/?.lua;scripts/?/init.lua;tools/jtest/?.lua
    // JTEST_OVERLAY=<dir> is searched first: a staged copy of a module (laid
    // out as under scripts/) is tested before it replaces the live file.
    const overlay = process.env.JTEST_OVERLAY;
    const ppath = [
        ...(overlay ? [slashes(path.join(overlay, "?.lua")), slashes(path.join(overlay, "?", "init.lua"))] : []),
        slashes(path.join(SCRIPTS, "?.lua")),
        slashes(path.join(SCRIPTS, "?", "init.lua")),
        slashes(path.join(__dirname, "?.lua")),
        slashes(path.join(TESTS, "?.lua")),
    ].join(";");
    lua.lua_getglobal(L, to_luastring("package"));
    textToLua(L, ppath);
    lua.lua_setfield(L, -2, to_luastring("path"));
    lua.lua_pop(L, 1);

    // jtest helper table
    lua.lua_newtable(L);
    for (const [name, fn] of Object.entries(helpers)) {
        lua.lua_pushjsfunction(L, fn);
        lua.lua_setfield(L, -2, to_luastring(name));
    }
    textToLua(L, slashes(ROOT));
    lua.lua_setfield(L, -2, to_luastring("root"));
    textToLua(L, slashes(SCRIPTS));
    lua.lua_setfield(L, -2, to_luastring("scripts"));
    lua.lua_setglobal(L, to_luastring("jtest"));

    return L;
}

// --- test protocol -----------------------------------------------------------
//
// A test file returns a table of { name = function } (or an array of
// { name, fn } pairs, run in order). Each function either returns normally
// (PASS) or raises (FAIL, with the error message). A test file that fails to
// load or returns nothing counts as one failed test.

function runTestFile(file, filter) {
    const L = makeState();
    const rel = path.relative(ROOT, file);
    const results = [];

    let status = lauxlib.luaL_loadfilex(L, to_luastring(slashes(file)), null);
    if (status !== lua.LUA_OK) {
        results.push({ name: rel + " (load)", ok: false, err: to_jsstring(lua.lua_tostring(L, -1)) });
        return results;
    }
    status = lua.lua_pcall(L, 0, 1, 0);
    if (status !== lua.LUA_OK) {
        results.push({ name: rel + " (run)", ok: false, err: to_jsstring(lua.lua_tostring(L, -1)) });
        return results;
    }
    if (!lua.lua_istable(L, -1)) {
        results.push({ name: rel, ok: false, err: "test file must return a table of tests" });
        return results;
    }

    // Collect { name, ref } pairs. Array part first (ordered), then hash part.
    const tests = [];
    const n = lua.lua_rawlen(L, -1);
    for (let i = 1; i <= n; i++) {
        lua.lua_rawgeti(L, -1, i);
        if (lua.lua_istable(L, -1)) {
            lua.lua_rawgeti(L, -1, 1);
            const name = to_jsstring(lua.lua_tostring(L, -1));
            lua.lua_pop(L, 1);
            lua.lua_rawgeti(L, -1, 2);
            const ref = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
            tests.push({ name, ref });
        }
        lua.lua_pop(L, 1);
    }
    lua.lua_pushnil(L);
    const named = [];
    while (lua.lua_next(L, -2) !== 0) {
        if (lua.lua_type(L, -2) === lua.LUA_TSTRING && lua.lua_isfunction(L, -1)) {
            const name = to_jsstring(lua.lua_tostring(L, -2));
            lua.lua_pushvalue(L, -1);
            const ref = lauxlib.luaL_ref(L, lua.LUA_REGISTRYINDEX);
            named.push({ name, ref });
        }
        lua.lua_pop(L, 1);
    }
    named.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    tests.push(...named);
    lua.lua_pop(L, 1);

    // Add a traceback handler for nicer failure messages.
    lua.lua_pushjsfunction(L, (L) => {
        const msg = lua.lua_tostring(L, 1);
        lauxlib.luaL_traceback(L, L, msg, 1);
        return 1;
    });
    const tracebackIdx = lua.lua_gettop(L);

    for (const t of tests) {
        if (filter.length && !filter.some((f) => t.name.includes(f) || rel.includes(f))) continue;
        lua.lua_rawgeti(L, lua.LUA_REGISTRYINDEX, t.ref);
        const started = Date.now();
        const st = lua.lua_pcall(L, 0, 0, tracebackIdx);
        const ms = Date.now() - started;
        if (st === lua.LUA_OK) {
            results.push({ name: t.name, ok: true, ms });
        } else {
            results.push({ name: t.name, ok: false, ms, err: to_jsstring(lua.lua_tostring(L, -1)) });
            lua.lua_pop(L, 1);
        }
    }
    lua.lua_pop(L, 1);
    lua.lua_close(L);
    return results;
}

function main() {
    const filter = process.argv.slice(2);
    if (!fs.existsSync(TESTS)) {
        console.error("no tests directory: " + TESTS);
        process.exit(2);
    }
    const files = fs
        .readdirSync(TESTS)
        .filter((f) => f.endsWith(".lua"))
        .sort()
        .map((f) => path.join(TESTS, f));

    let pass = 0;
    let fail = 0;
    for (const file of files) {
        const rel = slashes(path.relative(ROOT, file));
        console.log("== " + rel);
        for (const r of runTestFile(file, filter)) {
            const time = r.ms !== undefined ? ` (${r.ms} ms)` : "";
            if (r.ok) {
                pass++;
                console.log("  PASS  " + r.name + time);
            } else {
                fail++;
                console.log("  FAIL  " + r.name + time);
                for (const line of String(r.err).split("\n")) console.log("        " + line);
            }
        }
    }
    console.log("");
    console.log(`${pass} passed, ${fail} failed`);
    process.exit(fail ? 1 : 0);
}

main();

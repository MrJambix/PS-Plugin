# jtest

Offline test harness for the project's Lua. There is no Lua interpreter on
this machine, so the tests run inside [fengari](https://github.com/fengari-lua/fengari)
(Lua 5.3 implemented in JavaScript) under Node.

## Run

```
node tools/jtest/run.js            # every tests/*.lua file
node tools/jtest/run.js dxt tga    # only tests whose name contains one of the words
cd tools/jtest && npm test         # same as the first form
```

Exit code is 1 when any test fails. First-time setup: `cd tools/jtest && npm install`.

**Testing a change before it goes live.** The game reloads scripts whenever
the user presses F6, so a module should only change once it passes. Lay a
staged copy out the way it sits under `scripts/` (for example
`<dir>/jcore/services/recorder.lua`) and run with `JTEST_OVERLAY=<dir>`. That
directory is searched before `scripts/`, so the tests load the staged copy.
Copy it over the live file in one write once they pass.

## Writing tests

Each `tests/*.lua` file returns a list of `{ "name", function() ... end }`
pairs (a plain `name = function` table also works). A test passes when it
returns and fails when it raises; the error message and traceback are printed.

`package.path` is set so `require("jcore/lib/image")` resolves against
`scripts/`. A global `jtest` table gives access to things pure Lua cannot do
offline:

- `jtest.png_decode(bytes) -> w, h, rgba` (or `nil, err`) via pngjs
- `jtest.png_encode(w, h, rgba) -> png` reference encoder via pngjs
- `jtest.write_file(path, bytes)` (relative paths land in `tools/jtest/out/`)
- `jtest.read_file(path) -> bytes` (relative to the project root)
- `jtest.hex(bytes) -> string`
- `jtest.root`, `jtest.scripts`: absolute paths

## Caveats: fengari is not the game's Lua

- It is Lua 5.3, so anything LuaJIT-only (`bit`, `ffi`, `jit`, 5.1 `setfenv`,
  `unpack` as a global) is absent. Modules must fall back cleanly, as
  `image.lua` does for its bit operations.
- Its integers are 32-bit. Hex literals at or above `0x80000000` are negative
  (`0xFFFFFFFF == -1`) and integer arithmetic wraps at 2^31; decimal literals
  that do not fit become floats. Fold with `% 2^32` before comparing, and expect
  code that sums large integers (Adler-32 over big buffers, for instance) to
  behave differently here than on LuaJIT's doubles or 64-bit Lua.
- It is slow. Keep fixtures small; the bit-op fallbacks loop per bit.

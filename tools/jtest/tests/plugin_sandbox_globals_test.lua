-- The game's Lua sandbox, checked on the source: no plugin indexes `os`.
--
-- Seen live on Forever (2026-10-12): the loader's Lua has no `os` table, and
-- `debrief.lua:530: attempt to index global 'os' (a nil value)` stalled the
-- whole PvP intelligence layer on the player's death. This runner (fengari)
-- HAS `os`, so no behaviour test can see the mistake; this one reads the
-- files instead. A line may name `os` only behind a `type(os)` check on it
-- or on the line before (modules/nodememory.lua, intel/init.lua
-- lib.wall_time). Comments do not count.
--
-- Our plugins only: JCore, Jambix AIO, Debug, Market, World Click to Move.

if not jtest then return {} end

local PLUGINS = { "scripts/jcore", "scripts/jambix_aio", "scripts/jambix_debug", "scripts/jambix_market", "scripts/jambix_worldclick" }

local function code_of(line)
    -- The part before a comment (a "--" outside a string; good enough here:
    -- no plugin line puts "--" inside a string next to an os call).
    local cut = line:find("%-%-")
    return cut and line:sub(1, cut - 1) or line
end

local function offenders()
    local out = {}
    for _, dir in ipairs(PLUGINS) do
        for _, file in ipairs(jtest.list_files(dir, ".lua")) do
            local text = jtest.read_file(file)
            if text then
                local prev, n = "", 0
                for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                    n = n + 1
                    local code = code_of(line)
                    -- `os.` or `os[` as a name of its own (not "pos.", "cost.", "ammos.").
                    local hit = code:find("%f[%w_]os%s*[%.%[]")
                    if hit and not (code:find("type%(%s*os%s*%)") or code_of(prev):find("type%(%s*os%s*%)")) then
                        out[#out + 1] = string.format("%s:%d: %s", file, n, (line:gsub("^%s+", "")))
                    end
                    prev = line
                end
            end
        end
    end
    return out
end

local T = {}

T[#T + 1] = { "no plugin indexes os without checking it exists (the game's Lua has none)", function()
    local files = jtest.list_files("scripts/jambix_aio", ".lua")
    assert(#files > 20, "the plugin's files were found: " .. #files)
    local bad = offenders()
    assert(#bad == 0, #bad .. " unguarded os use(s):\n  " .. table.concat(bad, "\n  "))
end }

T[#T + 1] = { "the check itself: it finds os.time, skips pos.x, comments and a guarded line", function()
    local probe = {
        { "local t = os.time()", true },
        { "local x = pos.x + cost.y", false },
        { "-- os.time() in a comment", false },
        { "local o = type(os) == \"table\" and os.time() or nil", false },
        { "x = os [\"time\"]", true },
    }
    for _, p in ipairs(probe) do
        local code = code_of(p[1])
        local hit = code:find("%f[%w_]os%s*[%.%[]") ~= nil and not code:find("type%(%s*os%s*%)")
        assert(hit == p[2], string.format("%q: expected %s", p[1], tostring(p[2])))
    end
end }

return T

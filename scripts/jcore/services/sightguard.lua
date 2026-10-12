-- JCore / sightguard -- on Forever nobody reaches the client's own
-- line-of-sight ray: not JCore, not a plugin, not the loader's libraries.
--
-- Depends on: log. Reads geometry at call time (it is built further down).
--
-- WHY A GUARD (1.8.0). geometry.sight stopped JCore and the AIO asking
-- core.graphics.is_line_of_sight on Forever, where build 70338 asserts inside
-- it (ASSERT(m_data), M2HitTest.cpp). At 18:15 the same day it crashed there
-- once more, as a hunter in Dun Modr -- and not from a JCore job: the game's
-- Lua stack was UseAction on action button 3, a key press, and the ray had
-- the native's own ends (the eye 1.6 yards up, the mob 2.03; sight's are 2.0
-- at both). Code in the loader's packed Lua asked the native while the client
-- handled the press; the spell queue picks up pressed keys, and nothing of
-- ours answers a cast with a ray. Packed code cannot be changed, but `core`
-- is one table every package shares (the recorder's wrappers saw the loader's
-- ObstacleService call through them), so the function is replaced in place:
-- on Forever is_line_of_sight answers geometry.sight, the model-free ray, and
-- an unknown answer is "in sight" -- the server judges the cast, as it does
-- for ours. The loader's spell_helper gets the same for
-- is_spell_in_line_of_sight, for a caller that kept the native from before
-- this ran. It is built before anything that loads the loader's libraries
-- (spells, cast) and before the recorder, so a library that copies the
-- function when it loads copies this one, and the recorder sees who asks.
-- Every new caller is logged once and counted in stats().

return function(rt)
    local log = rt.log.for_tag("JCore/sightguard")

    local MAX_CALLERS = 32           -- distinct call sites kept for stats()

    local M = { installed = false, helper = false, calls = 0 }
    local callers, caller_count = {}, 0

    local function on_forever()
        local fn = core.get_game_version
        if type(fn) ~= "function" then return false end
        local ok, version = pcall(fn)
        return ok and version == "Forever"
    end

    --- file:line of whoever asked: the first frame above the guard that is
    --- neither native ("[C]", "[JS]" offline) nor the recorder's wrapper.
    local function caller()
        local getinfo = debug and debug.getinfo
        if type(getinfo) ~= "function" then return "?" end
        for level = 3, 8 do
            local info = getinfo(level, "Sl")
            if not info then break end
            local src = tostring(info.short_src)
            if info.what ~= "C" and src:sub(1, 1) ~= "[" and not src:find("recorder", 1, true) then
                return src .. ":" .. tostring(info.currentline)
            end
        end
        return "?"
    end

    local function note(where)
        M.calls = M.calls + 1
        local n = callers[where]
        if n then
            callers[where] = n + 1
        elseif caller_count < MAX_CALLERS then
            caller_count = caller_count + 1
            callers[where] = 1
            log.fmt("info", "is_line_of_sight asked by %s: answered by the model-free ray", where)
        end
    end

    --- The client's answer, without the client's ray: false only when the
    --- model-free ray is blocked; clear or unknown is true.
    local function answer(from, to)
        local geometry = rt.geometry
        if not (from and to and geometry and geometry.sight) then return true end
        local ok, seen = pcall(geometry.sight, from, to)
        return not (ok and seen == false)
    end

    local function guard(from, to)
        note(caller())
        return answer(from, to)
    end

    local function helper_guard(_, _, caster, target)
        note(caller())
        return answer(caster, target)
    end

    local function guard_helper()
        local ok, helper = pcall(require, "common/utility/spell_helper")
        if not ok or type(helper) ~= "table" then return end
        if type(helper.is_spell_in_line_of_sight) ~= "function" then return end
        local set = pcall(function() helper.is_spell_in_line_of_sight = helper_guard end)
        M.helper = set and helper.is_spell_in_line_of_sight == helper_guard
    end

    --- Replaces graphics.is_line_of_sight on Forever. True once it is in place.
    function M.install()
        if M.installed or not on_forever() then return M.installed end
        local graphics = core.graphics
        if type(graphics) ~= "table" or type(graphics.is_line_of_sight) ~= "function" then return false end
        M.native = graphics.is_line_of_sight
        local set = pcall(function() graphics.is_line_of_sight = guard end)
        if not (set and graphics.is_line_of_sight == guard) then
            log.fmt("warn", "Forever: graphics.is_line_of_sight could not be replaced; the client's M2HitTest assert is still reachable")
            return false
        end
        M.installed = true
        guard_helper()
        log.fmt("info", "Forever: graphics.is_line_of_sight answers the model-free ray for every package (spell_helper too: %s)",
            tostring(M.helper))
        return true
    end

    --- For the tests and the Core page: whether it is in, and who asked.
    function M.stats()
        local copy = {}
        for where, n in pairs(callers) do copy[where] = n end
        return { installed = M.installed, helper = M.helper, calls = M.calls, callers = copy }
    end

    M.install()
    return M
end

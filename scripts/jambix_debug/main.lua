-- Jambix Debug -- the developer's tools, kept out of what users get (1.0.0).
--
-- The user (2026-10-04): "move all the Dump, Api recorder and Debug off JCore
-- and Jambix AIO and make it its own ... where I don't upload it to users".
-- So they live here, and JCore and Jambix AIO run without this folder:
--
--   services/recorder.lua   the Forever API recorder and its trace (was JCore)
--   services/lootstudy.lua  the corpse and loot-window study (was JCore)
--   services/dump.lua       the Dump page: spells, talents and the API, the
--                           study's switch, the click-to-move probe (was JCore)
--   aio/debug.lua           Jambix AIO's Debug page: the object inspector, the
--                           automation status, narration, reaction history
--                           (was the AIO's modules/debug.lua and its page)
--
-- The three services are factories of JCore's runtime and are built BY JCore
-- (main.lua there): the recorder has to wrap the client's functions before
-- JCore's own services capture any of them, so it is built at the same point
-- of JCore's boot it always was. The AIO page is built by Jambix AIO with its
-- bundle. Their pages sit under "Jambix Debug" in the sidebar.
--
-- WITHOUT THIS FOLDER nothing of theirs exists: no pages, no files, no
-- wrapping, and JCore's world.client().recording is false, so the AIO's
-- trace lines are not even built.
--
-- LOAD ORDER is not guaranteed, and requiring across package roots does not
-- work on every loader build. So: this file publishes _G.JambixDebug. JCore
-- looks for that global, and failing that tries to require this file, while
-- it boots. If this file runs after JCore instead, it hands itself to
-- JCore.attach_debug, which builds the same services late (the recorder then
-- misses what JCore's services captured at their own build). Jambix AIO waits
-- a while for the global before giving up on its page.

if type(_G.JambixDebug) == "table" then return _G.JambixDebug end

local PACKAGE = "jambix_debug"

--- Requires a module of this package by whichever path convention the loader
--- uses: from the scripts root, or from this package's folder.
local function load(relative)
    local candidates = { PACKAGE .. "/" .. relative, relative, "./" .. relative }
    local errors = {}
    for i = 1, #candidates do
        local ok, result = pcall(require, candidates[i])
        local kind = type(result)
        if ok and (kind == "function" or kind == "table") then return result end
        errors[#errors + 1] = ok and ("returned " .. kind .. " from " .. candidates[i]) or tostring(result)
    end
    error("Jambix Debug: could not load '" .. relative .. "': " .. table.concat(errors, " | "))
end

local D = {
    VERSION = "1.0.0",
    recorder = load("services/recorder"),
    lootstudy = load("services/lootstudy"),
    dump = load("services/dump"),
    aio_debug = load("aio/debug"),
}

_G.JambixDebug = D

-- After JCore: hand the services over. JCore.attach_debug builds what it has
-- not built already, so a second call does nothing.
local JCore = _G.JCore
if type(JCore) == "table" and type(JCore.attach_debug) == "function" then
    local ok, err = pcall(JCore.attach_debug, D)
    if not ok and type(core) == "table" and core.log_error then
        core.log_error("[Jambix Debug] could not attach to JCore: " .. tostring(err))
    end
end

return D

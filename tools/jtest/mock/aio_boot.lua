-- Boots the whole JCore runtime and then the whole Jambix AIO plugin
-- (scripts/jambix_aio/main.lua) against mock_core, as a given client.
--
-- One boot per Lua state: the harness runs each test file in a fresh one,
-- so a file boots once, as one client, and asks its questions after.
--
--   local boot = require("mock/aio_boot")
--   local b = boot.run("Midnight", "wow_midnight_us")
--   b.ctx.aio.opt("autoloot_on", true)   -- the plugin's own settings reader

local M = {}

---@param version string What core.get_game_version answers.
---@param exact? string What core.get_exact_game_version answers.
---@param folders? string[] Client folders to give a WTF/Config.wtf, as an
--- install with several clients has.
---@param before? fun(mock) Runs after the mock core is installed and before
--- JCore loads: the place to replace or wrap a native that JCore keeps a
--- reference to.
---@return table boot { mock, JCore, ctx, P, errors }
function M.run(version, exact, folders, before)
    local mock = require("mock_core")
    mock.game_version = version
    mock.exact_game_version = exact or ""
    mock.install()
    for i = 1, #(folders or {}) do mock.wow_fs[folders[i] .. "/WTF/Config.wtf"] = "x" end
    if before then before(mock) end

    local ok, err = pcall(require, "jcore/main")
    if not ok then error("JCore did not boot: " .. tostring(err)) end
    local JCore = _G.JCore
    assert(JCore, "JCore did not publish itself")

    -- The plugin registers itself on load; keep its context.
    local captured
    local register = JCore.register
    JCore.register = function(manifest)
        local ctx = register(manifest)
        if type(manifest) == "table" and manifest.id == "jambix.aio" then captured = ctx end
        return ctx
    end

    local ok2, err2 = pcall(require, "jambix_aio/main")
    JCore.register = register
    if not ok2 then error("Jambix AIO did not load: " .. tostring(err2)) end
    assert(captured, "Jambix AIO never registered")

    return {
        mock = mock,
        JCore = JCore,
        ctx = captured,
        P = captured.aio,
        errors = function() return mock.error_text() end,
    }
end

return M

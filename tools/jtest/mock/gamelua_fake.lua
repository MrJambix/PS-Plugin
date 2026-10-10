-- A fake game behind the loader's core.execute and core.read_lua_*, for
-- JCore's services/gamelua and what is built on it.
--
--   local fake = require("gamelua_fake")
--   local W = fake.game({ mode = "deferred", globals = { C_QuestLog = {...} } })
--   local R = fake.build(W, true)      -- the service, on its own, as Forever
--   R.run(5.5)                         -- probe: ready
--   R.M.run("slot", "out('x')", cb)
--
-- game(opts): opts.mode is nil (execute applies at once), "deferred" (on the
-- game's next frame), "loader" (in OUR Lua), "raise", or "void" (nothing
-- happens); opts.max_read cuts what one read returns; opts.int_reads = false
-- makes read_lua_integer answer nil; opts.globals are put in the game's _G.
-- build(W, forever): the service with stand-ins for log, events, storage,
-- scheduler and world; R.run(seconds) steps the clock 0.05 s at a time,
-- running the game's frame and the service's job each step.

local M = {}

function M.game(opts)
    opts = opts or {}
    local env = {
        string = string, table = table, math = math, pcall = pcall, tostring = tostring,
        tonumber = tonumber, type = type, ipairs = ipairs, pairs = pairs, error = error,
        select = select, next = next,
        ERR_QUEST_ADD_KILL_SII = "%s slain: %d/%d", WOW_PROJECT_ID = 2,
        GetBuildInfo = function() return "1.60.1", "70205", "Oct 1 2026", 16001 end,
    }
    for k, v in pairs(opts.globals or {}) do env[k] = v end
    env._G = env
    local W = { env = env, queue = {}, executed = 0, clock = 1000.0 }
    local function run_code(code)
        local chunk, err = load(code, "game", "t", env)
        if not chunk then error("game chunk did not compile: " .. tostring(err) .. "\n" .. code) end
        chunk()
    end
    W.core = {
        time = function() return W.clock end,
        execute = function(code)
            W.executed = W.executed + 1
            W.last_code = code
            if opts.mode == "raise" then error("execute is not allowed here") end
            if opts.mode == "loader" then
                local chunk = assert(load(code, "loader", "t", _G))
                chunk()
                return
            end
            if opts.mode == "void" then return end
            if opts.mode == "deferred" then
                W.queue[#W.queue + 1] = code
                return
            end
            run_code(code)
        end,
        read_lua_string = function(name)
            local v = env[name]
            if type(v) ~= "string" then return nil end
            if opts.max_read and #v > opts.max_read then return v:sub(1, opts.max_read) end
            return v
        end,
        read_lua_integer = function(name)
            if opts.int_reads == false then return nil end
            local v = env[name]
            if type(v) ~= "number" then return nil end
            return math.floor(v)
        end,
        read_lua_table_string = function(t, k)
            local tbl = env[t]
            if type(tbl) ~= "table" then return nil end
            local v = tbl[k]
            return type(v) == "string" and v or nil
        end,
        read_lua_table_integer = function(t, k)
            local tbl = env[t]
            if type(tbl) ~= "table" then return nil end
            local v = tbl[k]
            return type(v) == "number" and v or nil
        end,
    }
    --- The game's frame: what a deferred execute queued runs now.
    function W.game_frame()
        local q = W.queue
        W.queue = {}
        for i = 1, #q do run_code(q[i]) end
    end
    return W
end

--- prior: files the last session left (name -> decoded JSON), read through
--- storage.read_json.
function M.build(W, forever, prior)
    -- core is the fake's, plus anything a test put on the table it handed in.
    _G.core = W.core
    local R = { jobs = {}, traced = {}, files = {}, logs = {} }
    local rt = {
        log = { for_tag = function()
            local l = {}
            function l.fmt(level, f, ...) R.logs[#R.logs + 1] = level .. ": " .. string.format(f, ...) end
            function l.once(level, _, text) R.logs[#R.logs + 1] = level .. ": " .. text end
            return l
        end },
        events = { emit = function(name, text)
            if name == "jcore.recorder.trace" then R.traced[#R.traced + 1] = text end
        end },
        storage = {
            write_json = function(name, value) R.files[name] = value return true end,
            read_json = function(name)
                if prior and prior[name] ~= nil then return prior[name] end
                return nil, "not found or empty"
            end,
        },
        scheduler = { add = function(phase, fn, opts) R.jobs[#R.jobs + 1] = { phase = phase, fn = fn, opts = opts } end },
        world = { is_forever = function() return forever end },
    }
    package.loaded["jcore/services/gamelua"] = nil
    R.M = require("jcore/services/gamelua")(rt)
    --- Extra work to do each step (a module riding on the bridge).
    R.each_step = nil
    function R.run(seconds)
        local steps = math.floor(seconds / 0.05 + 0.5)
        for _ = 1, steps do
            W.clock = W.clock + 0.05
            W.game_frame()
            for i = 1, #R.jobs do R.jobs[i].fn() end
            if R.each_step then R.each_step() end
        end
    end
    function R.traced_has(needle)
        for i = 1, #R.traced do
            if R.traced[i]:find(needle, 1, true) then return true end
        end
        return false
    end
    return R
end

return M

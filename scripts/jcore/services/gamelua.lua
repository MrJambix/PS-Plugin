-- JCore / gamelua -- the game's own Lua, through the loader's undocumented
-- core.execute and core.read_lua_* (JCore 1.5.16). Forever only.
--
-- WHY
-- On Forever the quest log reads empty (get_num_quest_log_entries 0), names
-- read "" and the combat log arrives with no arguments, yet the game itself
-- knows all of it: its own UI shows your quests and their objectives. The
-- loader exposes five calls no stub documents and nothing had ever called
-- (the API recorder, 2026-10-02): execute, read_lua_string,
-- read_lua_integer, read_lua_table_string and read_lua_table_integer. If
-- execute runs a chunk in the GAME's Lua state and read_lua_* reads that
-- state's globals back, every one of those reads is a few lines of the
-- game's own API away.
-- The 2026-10-06 core answers the quest log itself on Forever (the quest-ID
-- readers, world.client().quest_ids), so the quest readers no longer wait on
-- this bridge there; names and the combat log still would.
--
-- WHAT IS ASSUMED, AND PROBED BEFORE ANYTHING USES IT
-- Nothing about these calls is documented, so nothing is believed until it is
-- seen working. The first time the world is up, the probe:
--   1. reads a global that cannot exist yet (expects nil), a GlobalStrings
--      constant (ERR_QUEST_ADD_KILL_SII) and WOW_PROJECT_ID, to see whether
--      read_lua_* reaches the game's state on its own;
--   2. executes a chunk that sets four globals: a string, an integer, a table
--      and a 4,000-character string;
--   3. checks our OWN _G for the string: if it is there, execute ran in the
--      loader's Lua, not the game's, and is no use here;
--   4. reads the globals back every frame for three seconds. The string
--      coming back means the bridge works (and how many seconds the answer
--      took); the integer says whether read_lua_integer can be used for
--      numbers; the long string's length is the most one read returns, and
--      results are cut into pieces that size; the table reads say which key
--      convention read_lua_table_* takes.
-- Then one run takes a census of the game API the readers want (C_QuestLog,
-- C_Map, C_NamePlate, C_TooltipInfo, ...): which exist, as what type. All of
-- it goes to scripts_data/jcore/jcore.gamelua.json and to the recorder's
-- trace, so the next session's file says what this client can do.
-- A failed probe is tried again twice, twenty seconds apart (a loading
-- screen can swallow the first); after that the bridge stays off for the
-- session and says why.
-- When the last session's file already says "failed", nothing has changed
-- unless the loader has: one quiet probe, its lines in the trace and the
-- debug log only. A bridge that answers is still announced. (1.8.3: every
-- session on Forever since 2026-10-03 printed three failed probes.) The
-- debug page's "probe again" does the full three, aloud.
--
-- HOW A RUN WORKS
-- M.run(slot, body, on_result) sends the game a chunk that runs `body` with
-- an `out(text)` function in a pcall, joins what it wrote with newlines,
-- cuts it into pieces and stores them in JCORE_GL_<slot>_1..N with N and a
-- sequence number beside them (each also as a string, NS and SEQS, for a
-- loader whose read_lua_integer does not work). The answer is polled every 0.05 s until the
-- sequence matches (or three seconds pass), read back piece by piece, and
-- handed to on_result(text) -- or on_result(nil, why) for an error raised in
-- the game or a timeout. One run per slot at a time. Bodies are game Lua
-- (5.1): no goto, no integer division, no bit operators.
--
-- WHAT IT NEVER DOES
-- It sends only what callers give it, and the callers in this repository
-- only READ: no protected call, no movement, no chat, no setting written.
--
-- EVERY OTHER CLIENT: inert. Decided once at load: no job, no read, no
-- execute; run() answers false and state() "off".

local FILE = "jcore/jcore.gamelua.json"
local G = "JCORE_GL_"
local PROBE_DELAY = 5.0        -- seconds after load before the first probe
local PROBE_WAIT = 3.0         -- seconds the probe waits for execute's effect
local PROBE_RETRY = 20.0       -- seconds between attempts
local PROBE_TRIES = 3
local RESULT_WAIT = 3.0        -- seconds a run waits for its answer
local POLL_EVERY = 0.05
local LONG_LEN = 4000          -- the probe's long string
local CHUNK_MIN, CHUNK_MAX = 64, 3800
local MAX_PIECES = 400

-- What the readers built on this want from the game, checked by the census.
local CENSUS = {
    "C_QuestLog", "C_QuestLog.GetNumQuestLogEntries", "C_QuestLog.GetInfo",
    "C_QuestLog.GetQuestObjectives", "C_QuestLog.IsComplete", "C_QuestLog.GetTitleForQuestID",
    "C_QuestLog.GetQuestsOnMap", "C_QuestLog.GetNextWaypoint", "C_QuestLog.UnitIsRelatedToActiveQuest",
    "C_QuestLog.GetQuestIDForLogIndex", "C_QuestLog.GetLogIndexForQuestID",
    "GetNumQuestLogEntries", "GetQuestLogTitle", "GetNumQuestLeaderBoards", "GetQuestLogLeaderBoard",
    "GetQuestObjectiveInfo", "QuestPOIGetIconInfo", "GetQuestLogSpecialItemInfo",
    "C_Map", "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition", "C_Map.GetWorldPosFromMapPos",
    "C_Map.GetMapInfo", "CreateVector2D", "UnitPosition",
    "C_NamePlate", "C_NamePlate.GetNamePlates", "C_NamePlate.GetNamePlateForUnit",
    "C_TooltipInfo", "C_TooltipInfo.GetUnit", "C_TooltipInfo.GetHyperlink",
    "UnitGUID", "UnitName", "UnitExists", "UnitIsQuestBoss", "C_Item", "C_Item.GetItemNameByID",
    "GetItemInfo", "C_CombatLog", "CombatLogGetCurrentEventInfo", "GetBuildInfo", "WOW_PROJECT_ID",
}

local function valid_slot(slot)
    return type(slot) == "string" and #slot <= 24 and slot:match("^[%w_]+$") ~= nil
end

--- The game-side chunk for one run: `body` in a pcall with an `out`, its
--- text cut into pieces of `chunk` characters, then N and the sequence.
local function wrap(slot, seq, body, chunk)
    local base = G .. slot .. "_"
    return table.concat({
        "do local __o = {} ",
        "local function out(s) __o[#__o + 1] = tostring(s) end ",
        "local __ok, __err = pcall(function(out) ", body, "\nend, out) ",
        "if not __ok then __o = { '\\001ERR\\t' .. tostring(__err) } end ",
        "local __s = table.concat(__o, '\\n') ",
        "local __n = 0 ",
        "for __i = 1, string.len(__s), ", tostring(chunk), " do ",
        "__n = __n + 1 ",
        "_G['", base, "' .. __n] = string.sub(__s, __i, __i + ", tostring(chunk - 1), ") ",
        "if __n >= ", tostring(MAX_PIECES), " then break end ",
        "end ",
        "_G['", base, "N'] = __n ",
        "_G['", base, "NS'] = tostring(__n) ",
        "_G['", base, "SEQS'] = '", tostring(seq), "' ",
        "_G['", base, "SEQ'] = ", tostring(seq), " ",
        "end",
    })
end

--- The census body: every name in CENSUS with the type of what it names.
local function census_body()
    local quoted = {}
    for i = 1, #CENSUS do quoted[i] = string.format("%q", CENSUS[i]) end
    return table.concat({
        "local names = {", table.concat(quoted, ","), "} ",
        "for i = 1, #names do ",
        "local v = _G ",
        "for part in string.gmatch(names[i], '[^%.]+') do ",
        "if type(v) == 'table' then v = v[part] else v = nil end ",
        "end ",
        "out(names[i] .. '=' .. type(v)) ",
        "end ",
        "local ok, a, b, c, d = pcall(GetBuildInfo) ",
        "out('build=' .. tostring(a) .. ' ' .. tostring(b) .. ' ' .. tostring(d)) ",
        "out('project=' .. tostring(WOW_PROJECT_ID))",
    })
end

return function(rt)
    local log = rt.log.for_tag("JCore/gamelua")
    local events, storage, scheduler, world = rt.events, rt.storage, rt.scheduler, rt.world

    local M = {}

    local forever = false
    if world and type(world.is_forever) == "function" then
        local ok, yes = pcall(world.is_forever)
        forever = ok and yes == true
    end

    local st = {
        state = forever and "untried" or "off",
        reason = forever and nil or "not Forever",
        chunk = 240,
        int_reads = false,
        tries = 0,
    }
    local report = { client = "Forever", attempts = {} }
    local stats = { runs = 0, answers = 0, errors = 0, timeouts = 0, busy = 0, pieces = 0 }

    -- What the last session found, read before this one writes over it.
    local last = nil
    if forever and storage and type(storage.read_json) == "function" then
        local ok, value = pcall(storage.read_json, FILE)
        if ok and type(value) == "table" then last = value end
    end
    local quiet = last ~= nil and last.state == "failed"
    local tries_max = quiet and 1 or PROBE_TRIES

    function M.state() return st.state, st.reason end
    function M.ready() return st.state == "ready" end
    function M.report() return report end
    function M.stats()
        return {
            state = st.state, reason = st.reason, chunk = st.chunk, int_reads = st.int_reads,
            latency = st.latency, runs = stats.runs, answers = stats.answers, errors = stats.errors,
            timeouts = stats.timeouts, busy = stats.busy, pieces = stats.pieces,
        }
    end

    if not forever then
        function M.run() return false end
        function M.probe_now() return false end
        return M
    end

    local function now() return core.time() end

    local function trace(text, level)
        log.fmt(level or "info", "%s", text)
        if events then pcall(events.emit, "jcore.recorder.trace", "gamelua: " .. text) end
    end

    local function save()
        if storage and type(storage.write_json) == "function" then
            report.state, report.reason = st.state, st.reason
            report.chunk, report.int_reads, report.latency = st.chunk, st.int_reads, st.latency
            report.stats = stats
            pcall(storage.write_json, FILE, report, true)
        end
    end

    -- The calls, looked up when used: the recorder wraps core.* at build.
    local function native(name)
        local f = type(core) == "table" and core[name] or nil
        return type(f) == "function" and f or nil
    end

    local function call(name, ...)
        local f = native(name)
        if not f then return false, "no core." .. name end
        return pcall(f, ...)
    end

    local function read_str(name)
        local ok, v = call("read_lua_string", name)
        if ok and type(v) == "string" then return v end
        return nil
    end

    --- A number the game side wrote twice, as a number (KEY) and as a string
    --- (KEYS): read_lua_integer when the probe saw it work, the string otherwise.
    local function read_num(base, key)
        if st.int_reads then
            local ok, v = call("read_lua_integer", base .. key)
            if ok and type(v) == "number" then return v end
        end
        return tonumber(read_str(base .. key .. "S"))
    end

    local function describe(ok, v)
        if not ok then return "raised: " .. tostring(v) end
        if type(v) == "string" then return string.format("%q", #v > 80 and (v:sub(1, 80) .. "...") or v) end
        return type(v) .. ":" .. tostring(v)
    end

    -- --- runs -------------------------------------------------------------------

    local seq = 0
    local pending = {}            -- slot -> { seq, cb, at }

    ---@param slot string [A-Za-z0-9_], at most 24
    ---@param body string game Lua; writes its answer with out(text)
    ---@param on_result fun(text: string|nil, why: string|nil)
    ---@return boolean sent
    function M.run(slot, body, on_result)
        if st.state ~= "ready" or not valid_slot(slot) or type(body) ~= "string" then return false end
        local p = pending[slot]
        if p and (now() - p.at) < RESULT_WAIT then
            stats.busy = stats.busy + 1
            return false
        end
        seq = seq + 1
        local ok, err = call("execute", wrap(slot, seq, body, st.chunk))
        if not ok then
            stats.errors = stats.errors + 1
            log.once("warn", "gamelua_execute_" .. slot, "execute raised: " .. tostring(err))
            return false
        end
        pending[slot] = { seq = seq, cb = on_result, at = now() }
        stats.runs = stats.runs + 1
        return true
    end

    local function deliver(cb, text, why)
        if type(cb) ~= "function" then return end
        local ok, err = pcall(cb, text, why)
        if not ok then log.fmt("warn", "a run's handler raised: %s", tostring(err)) end
    end

    local function poll_runs()
        local t = now()
        for slot, p in pairs(pending) do
            local base = G .. slot .. "_"
            if read_num(base, "SEQ") == p.seq then
                pending[slot] = nil
                local n = read_num(base, "N") or 0
                local parts = {}
                for i = 1, math.min(n, MAX_PIECES) do parts[i] = read_str(base .. i) or "" end
                stats.pieces = stats.pieces + n
                local text = table.concat(parts)
                if text:sub(1, 5) == "\1ERR\t" then
                    stats.errors = stats.errors + 1
                    deliver(p.cb, nil, text:sub(6))
                else
                    stats.answers = stats.answers + 1
                    deliver(p.cb, text, nil)
                end
            elseif (t - p.at) > RESULT_WAIT then
                pending[slot] = nil
                stats.timeouts = stats.timeouts + 1
                deliver(p.cb, nil, "no answer in " .. RESULT_WAIT .. "s")
            end
        end
    end

    -- --- the probe --------------------------------------------------------------

    local probe = nil             -- { tag, sent, attempt }
    local loaded_at = now()

    local function census()
        local sent = M.run("census", census_body(), function(text, why)
            report.census = {}
            if not text then
                report.census_error = why
                trace("census failed: " .. tostring(why))
            else
                local missing = {}
                for line in text:gmatch("[^\n]+") do
                    local k, v = line:match("^(.-)=(.*)$")
                    if k then
                        report.census[k] = v
                        if v == "nil" then missing[#missing + 1] = k end
                    end
                end
                trace(string.format("census: %d names, missing: %s", #CENSUS,
                    #missing > 0 and table.concat(missing, ", ") or "none"))
                trace("census: " .. tostring(report.census.build) .. ", project " .. tostring(report.census.project))
            end
            save()
        end)
        if not sent then trace("census not sent") end
    end

    local function finish(ok_state, reason, attempt)
        attempt.result = ok_state and "ready" or ("failed: " .. tostring(reason))
        if ok_state then
            st.state, st.reason = "ready", nil
            trace(string.format("ready: execute reaches the game's Lua (answer in %.2fs, pieces of %d, integer reads %s)",
                st.latency or -1, st.chunk, st.int_reads and "yes" or "no"))
            save()
            census()
            return
        end
        st.reason = reason
        if st.tries < tries_max then
            st.state = "retry"
            trace(string.format("probe %d of %d failed (%s); trying again in %ds", st.tries, tries_max,
                tostring(reason), PROBE_RETRY))
        elseif quiet then
            st.state = "failed"
            trace("off for this session, as last session: " .. tostring(reason), "debug")
        else
            st.state = "failed"
            trace("off for this session: " .. tostring(reason))
        end
        save()
    end

    local function start_probe()
        st.tries = st.tries + 1
        st.state = "probing"
        local attempt = { at = math.floor(now()) }
        report.attempts[#report.attempts + 1] = attempt
        local tag = string.format("pong-%d-%d", st.tries, math.floor(now() * 1000) % 1000000)
        attempt.tag = tag

        -- 1. Before: does read_lua_* reach the game's state on its own?
        attempt.before = {
            ping = describe(call("read_lua_string", G .. "PING")),
            globalstring = describe(call("read_lua_string", "ERR_QUEST_ADD_KILL_SII")),
            project_int = describe(call("read_lua_integer", "WOW_PROJECT_ID")),
            project_str = describe(call("read_lua_string", "WOW_PROJECT_ID")),
        }

        -- 2. The chunk.
        local code = table.concat({
            G, "PING = ", string.format("%q", tag), " ",
            G, "PINGI = ", tostring(st.tries * 1000 + 7), " ",
            G, "PINGT = { s = 'tbl', n = 7, [1] = 'one' } ",
            G, "LONG = string.rep('0123456789', ", tostring(LONG_LEN / 10), ")",
        })
        local ok, ret = call("execute", code)
        attempt.execute = describe(ok, ret)
        -- 3. Our own Lua: a loader-side execute is no bridge to the game.
        attempt.ran_in_loader = rawget(_G, G .. "PING") == tag
        if not ok then return finish(false, "execute " .. attempt.execute, attempt) end
        if attempt.ran_in_loader then
            return finish(false, "execute ran in the loader's own Lua, not the game's", attempt)
        end
        probe = { tag = tag, sent = now(), attempt = attempt, int = st.tries * 1000 + 7 }
    end

    -- 4. After: every frame until the string comes back or the wait runs out.
    local function poll_probe()
        local p = probe
        if not p then return end
        local back = read_str(G .. "PING")
        local t = now()
        if back ~= p.tag then
            if (t - p.sent) > PROBE_WAIT then
                probe = nil
                p.attempt.after = describe(call("read_lua_string", G .. "PING"))
                finish(false, "the string set by execute never read back (" .. p.attempt.after .. ")", p.attempt)
            end
            return
        end
        probe = nil
        local a = p.attempt
        st.latency = t - p.sent
        a.latency = st.latency
        local ok_i, int = call("read_lua_integer", G .. "PINGI")
        a.int = describe(ok_i, int)
        st.int_reads = ok_i and int == p.int
        local long = read_str(G .. "LONG")
        a.long_len = long and #long or 0
        st.chunk = math.max(CHUNK_MIN, math.min(CHUNK_MAX, (a.long_len >= LONG_LEN) and CHUNK_MAX or (a.long_len - 16)))
        a.table_str_key = describe(call("read_lua_table_string", G .. "PINGT", "s"))
        a.table_str_index = describe(call("read_lua_table_string", G .. "PINGT", 1))
        a.table_int_key = describe(call("read_lua_table_integer", G .. "PINGT", "n"))
        if a.long_len < CHUNK_MIN + 16 then
            return finish(false, "a read returns at most " .. a.long_len .. " characters", a)
        end
        finish(true, nil, a)
    end

    local retry_at = 0

    local function tick()
        local t = now()
        if st.state == "untried" then
            if (t - loaded_at) >= PROBE_DELAY then start_probe() end
        elseif st.state == "probing" then
            poll_probe()
        elseif st.state == "retry" then
            if retry_at == 0 then retry_at = t + PROBE_RETRY end
            if t >= retry_at then
                retry_at = 0
                start_probe()
            end
        elseif st.state == "ready" then
            if next(pending) ~= nil then poll_runs() end
        end
    end

    --- Probes again now (the debug page's button). Forgets the calibration.
    function M.probe_now()
        quiet, tries_max = false, PROBE_TRIES
        st.state, st.reason, st.tries, probe = "untried", nil, 0, nil
        loaded_at = now() - PROBE_DELAY
        return true
    end

    if scheduler and type(scheduler.add) == "function" then
        scheduler.add("update", tick, { owner = "jcore.gamelua", interval = POLL_EVERY, priority = 40 })
    end

    -- For the tests: the chunk a run sends.
    M._wrap = wrap
    M._census_body = census_body
    return M
end

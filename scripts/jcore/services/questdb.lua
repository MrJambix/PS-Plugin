-- JCore / questdb -- the quest database, our own copy of it (JCore 1.6.0).
--
-- Every quest, npc, object and item Questie knows, read from files JCore keeps
-- in scripts_data, so nothing needs the Questie addon at run time:
--
--   node tools/jcheck/questdb_extract.js --client forever   (and --client vanilla)
--
-- writes scripts_data/jcore/questdb/<client>/ from QuestieDB's own baked
-- database (its TOC metadata: base64, zlib, CBOR), with QuestieDB's field
-- names: quest name / questLevel / requiredLevel / startedBy / finishedBy /
-- objectives / preQuestSingle / preQuestGroup / requiredRaces /
-- requiredClasses ..., npc name / spawns / zoneID / questStarts / questEnds /
-- subName / rank ..., object name / spawns ..., item name / npcDrops /
-- objectDrops ... QuestieDB's Dynamic Corrections are not applied. The data is
-- the classic world's: Forever's own quests and creatures are not in it (its
-- ids start past 90000 and 250000); those are learned in the game.
--
-- Files are read on first use, a 1000-id bucket at a time.
--
-- WHAT IT ANSWERS
--   get(kind, id, key), row(kind, id), quest_ids()
--   active()               the quests you are on: the classic quest log where
--                          the client has one. On Forever, the game's own
--                          list (core.quests.get_quest_log_quest_ids) on the
--                          2026-10-06 core; on an older core (whose log reads
--                          empty) QUEST_ACCEPTED / QUEST_TURNED_IN /
--                          QUEST_REMOVED, after one is_on_quest sweep over
--                          every quest id (60 a tick, from the first ask)
--   is_complete(id)        ready to hand in: the classic log's word; on
--                          Forever the game's (core.quests.is_quest_complete,
--                          1.9.0), Questie's on an older core
--   objective_ids(id)      the npcs and objects a quest's objectives want,
--                          item drops included
--   questie()              the same calls as the Questie bridge
--                          (core.addons.questie), answered from here: a
--                          plugin can swap one for the other

local SWEEP_PER_TICK = 60

return function(rt)
    local log = rt.log.for_tag("JCore/questdb")
    local events = rt.events

    local M = {}
    M.KINDS = { "quest", "npc", "object", "item" }

    local state = { base = nil, index = nil, read = false, error = nil, buckets_read = 0 }
    local buckets = { quest = {}, npc = {}, object = {}, item = {} }

    local function client()
        local world = rt.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        return ok and type(c) == "table" and c or {}
    end

    local function base()
        if state.base then return state.base end
        local c = client()
        local name = c.forever and "forever" or tostring(c.version or "vanilla"):lower()
        state.base = "jcore/questdb/" .. name
        return state.base
    end

    --- JSON gave string keys and a null sentinel; Questie's tables have
    --- number keys (objective kinds, zone ids) and holes.
    local NULL = rt.json and rt.json.null
    local function renumber(t)
        local moves = nil
        for k, v in pairs(t) do
            if NULL ~= nil and v == NULL then
                moves = moves or {}
                moves[#moves + 1] = { k, nil, true }
            else
                if type(v) == "table" then renumber(v) end
                if type(k) == "string" and k:match("^%-?%d+$") then
                    moves = moves or {}
                    moves[#moves + 1] = { k, v }
                end
            end
        end
        if moves then
            for i = 1, #moves do
                local m = moves[i]
                t[m[1]] = nil
                if not m[3] then t[tonumber(m[1])] = m[2] end
            end
        end
        return t
    end

    local function read_json(name)
        local storage = rt.storage
        if not (storage and storage.read_json) then return nil, "no storage" end
        local ok, value, err = pcall(storage.read_json, name)
        if not ok then return nil, tostring(value) end
        return value, err
    end

    local function index()
        if state.read then return state.index end
        state.read = true
        local value, err = read_json(base() .. "/index.json")
        if type(value) ~= "table" then
            state.error = "no database at scripts_data/" .. base() .. " (" .. tostring(err) .. ")"
            log.fmt("info", "questdb: %s", state.error)
            return nil
        end
        state.index = value
        local q = value.kinds and value.kinds.quest and value.kinds.quest.rows or 0
        log.fmt("info", "questdb: %d quests from %s (%s, built %s)", q, base(),
            tostring(value.source), tostring(value.build_time))
        return value
    end

    local function bucket(kind, id)
        local by_kind = buckets[kind]
        if not by_kind then return nil end
        local b = math.floor(id / 1000)
        local data = by_kind[b]
        if data == nil then
            data = false
            local value = read_json(base() .. "/" .. kind .. "/" .. b .. ".json")
            if type(value) == "table" then
                data = renumber(value)
                state.buckets_read = state.buckets_read + 1
            end
            by_kind[b] = data
        end
        return data or nil
    end

    --- Is the database there?
    function M.available()
        return index() ~= nil
    end

    --- One entity's row (read-only), or nil.
    ---@param kind "quest"|"npc"|"object"|"item"
    ---@param id integer
    ---@return table|nil
    function M.row(kind, id)
        id = tonumber(id)
        if not id or not index() then return nil end
        local data = bucket(kind, id)
        return data and data[id] or nil
    end

    ---@param kind "quest"|"npc"|"object"|"item"
    ---@param id integer
    ---@param key string QuestieDB's field name
    function M.get(kind, id, key)
        local row = M.row(kind, id)
        if not row then return nil end
        return row[key]
    end

    --- Every quest id in the database, sorted (read-only).
    ---@return integer[]
    function M.quest_ids()
        local idx = index()
        return idx and idx.quest_ids or {}
    end

    -- --- the quests you are on ------------------------------------------------

    local active = {}          -- quest id -> true
    local complete = {}        -- quest id -> true (Era: the log says so)
    local swept, sweep_job, sweep_pos = false, nil, 1

    local function native(ns, name)
        local t = core[ns]
        local fn = type(t) == "table" and t[name] or nil
        return type(fn) == "function" and fn or nil
    end

    local function read_classic_log()
        local count_fn, title_fn = native("quests", "get_num_quest_log_entries"), native("quests", "get_quest_log_title")
        if not (count_fn and title_fn) then return end
        local ok, n = pcall(count_fn)
        if not ok or type(n) ~= "number" then return end
        local fresh, done = {}, {}
        for i = 1, n do
            local ok_r, row = pcall(title_fn, i)
            if ok_r and type(row) == "table" and not row.is_header then
                local id = tonumber(row.quest_id)
                if id and id > 0 then
                    fresh[id] = true
                    if row.is_complete == 1 then done[id] = true end
                end
            end
        end
        active, complete = fresh, done
    end

    local function on_quest(id)
        local fn = native("quests", "is_on_quest")
        if not fn then return false end
        local ok, v = pcall(fn, id)
        return ok and v == true
    end

    --- Forever: one is_on_quest sweep over every quest id, a few a tick.
    local function start_sweep()
        if swept or sweep_job then return end
        local scheduler = rt.scheduler
        if not (scheduler and scheduler.add) then return end
        local ids = M.quest_ids()
        sweep_pos = 1
        sweep_job = scheduler.add("update", function()
            local stop = math.min(#ids, sweep_pos + SWEEP_PER_TICK - 1)
            for i = sweep_pos, stop do
                if on_quest(ids[i]) then active[ids[i]] = true end
            end
            sweep_pos = stop + 1
            if sweep_pos > #ids then
                swept = true
                local job = sweep_job
                sweep_job = nil
                pcall(scheduler.remove, job)
            end
        end, { owner = "jcore", priority = 900 })
    end

    --- Forever on the 2026-10-06 core (1.9.0): the game's own list of the
    --- quests in your log. It lists only the rows the quest log SHOWS, so a
    --- quest under a collapsed header is missing from it: one held from
    --- before that is_on_quest still says you are on is kept. false when the
    --- core has no such list, and the sweep is the way.
    local function read_id_log()
        local fn = native("quests", "get_quest_log_quest_ids")
        if not fn then return false end
        local ok, ids = pcall(fn)
        if not ok or type(ids) ~= "table" then return false end
        local fresh = {}
        for i = 1, #ids do
            local id = tonumber(ids[i])
            if id and id > 0 then fresh[id] = true end
        end
        for id in pairs(active) do
            if not fresh[id] and on_quest(id) then fresh[id] = true end
        end
        for id in pairs(complete) do
            if not fresh[id] then complete[id] = nil end
        end
        active = fresh
        return true
    end

    --- The quests you are on, as an array.
    ---@return integer[]
    function M.active()
        local c = client()
        if c.classic_quest_log == false then
            if not read_id_log() and index() then start_sweep() end
        else
            read_classic_log()
        end
        local out = {}
        for id in pairs(active) do out[#out + 1] = id end
        table.sort(out)
        return out
    end

    --- Is a quest ready to hand in? The classic log's word. On Forever the
    --- game's (core.quests.is_quest_complete, the 2026-10-06 core); on an
    --- older core the Questie addon's, when it happens to be there, and false
    --- when nothing says.
    ---@param quest_id integer
    ---@return boolean
    function M.is_complete(quest_id)
        local c = client()
        if c.classic_quest_log ~= false then
            read_classic_log()
            return complete[tonumber(quest_id) or -1] == true
        end
        local fn = native("quests", "is_quest_complete")
        if fn then
            local ok, v = pcall(fn, quest_id)
            if ok and type(v) == "boolean" then return v end
        end
        -- An older core: Questie can tell (it reads the game's own quest
        -- log). It answers 1 / 0 / -1 (complete / not / failed), never true,
        -- which this compared against until 1.9.0, so it never said yes.
        local addons = core.addons
        local q = type(addons) == "table" and addons.questie or nil
        if type(q) == "table" and type(q.is_quest_complete) == "function" and type(q.is_loaded) == "function" then
            local ok_l, loaded = pcall(q.is_loaded)
            if ok_l and loaded then
                local ok, v = pcall(q.is_quest_complete, quest_id)
                if ok then return v == 1 or v == true end
            end
        end
        return false
    end

    local opts = { owner = "jcore", priority = 0 }
    events.on("jcore.game_event.QUEST_ACCEPTED", function(args)
        if client().classic_quest_log ~= false or type(args) ~= "table" then return end
        -- Forever passes the quest id (the older (index, id) shape is taken too).
        local id = tonumber(args[2]) or tonumber(args[1])
        if id and id > 0 then active[id] = true end
    end, opts)
    local function gone(args)
        if client().classic_quest_log ~= false or type(args) ~= "table" then return end
        local id = tonumber(args[1])
        if id then active[id], complete[id] = nil, nil end
    end
    events.on("jcore.game_event.QUEST_TURNED_IN", gone, opts)
    events.on("jcore.game_event.QUEST_REMOVED", gone, opts)

    -- --- what a quest wants ------------------------------------------------------

    --- The npcs and objects a quest's objectives want (Questie's objectives:
    --- [1] creatures {{npc, text}}, [2] objects {{object, text}}, [3] items
    --- {{item, text}} -- found on their droppers -- and [5] kill credit
    --- {{{npcs...}, base, text}}).
    ---@param quest_id integer
    ---@return table<integer, boolean> npcs
    ---@return table<integer, boolean> objects
    function M.objective_ids(quest_id)
        local npcs, objects = {}, {}
        local obj = M.get("quest", quest_id, "objectives")
        if type(obj) ~= "table" then return npcs, objects end
        for _, row in ipairs(type(obj[1]) == "table" and obj[1] or {}) do
            if type(row) == "table" and tonumber(row[1]) then npcs[tonumber(row[1])] = true end
        end
        for _, row in ipairs(type(obj[2]) == "table" and obj[2] or {}) do
            if type(row) == "table" and tonumber(row[1]) then objects[tonumber(row[1])] = true end
        end
        for _, row in ipairs(type(obj[3]) == "table" and obj[3] or {}) do
            local item = type(row) == "table" and tonumber(row[1]) or nil
            if item then
                for _, n in ipairs(M.get("item", item, "npcDrops") or {}) do npcs[n] = true end
                for _, o in ipairs(M.get("item", item, "objectDrops") or {}) do objects[o] = true end
            end
        end
        for _, row in ipairs(type(obj[5]) == "table" and obj[5] or {}) do
            if type(row) == "table" then
                for _, n in ipairs(type(row[1]) == "table" and row[1] or {}) do npcs[n] = true end
                if tonumber(row[2]) then npcs[tonumber(row[2])] = true end
            end
        end
        return npcs, objects
    end

    --- Could you take this quest now? Not done, not on it, your level, your
    --- class and (where the client can say) race, and its prerequisites done.
    ---@param quest_id integer
    ---@return boolean
    function M.is_doable(quest_id)
        local q = M.row("quest", quest_id)
        if not q then return false end
        local world = rt.world
        local done = function(id)
            local ok, v = pcall(function() return world and world.is_quest_complete and world.is_quest_complete(id) end)
            return ok and v == true
        end
        if done(quest_id) or on_quest(quest_id) then return false end
        local player = rt.player
        local level = player and player.level and player.level() or 0
        if tonumber(q.requiredLevel) and level > 0 and level < q.requiredLevel then return false end
        local class_id = player and player.class_id and player.class_id() or 0
        if tonumber(q.requiredClasses) and q.requiredClasses > 0 and class_id and class_id > 0 then
            if math.floor(q.requiredClasses / 2 ^ (class_id - 1)) % 2 ~= 1 then return false end
        end
        local race_id = player and player.race_id and player.race_id() or 0
        if tonumber(q.requiredRaces) and q.requiredRaces > 0 and race_id and race_id > 0 then
            if math.floor(q.requiredRaces / 2 ^ (race_id - 1)) % 2 ~= 1 then return false end
        end
        if type(q.preQuestGroup) == "table" then
            for _, id in ipairs(q.preQuestGroup) do if not done(id) then return false end end
        end
        if type(q.preQuestSingle) == "table" and #q.preQuestSingle > 0 then
            local any = false
            for _, id in ipairs(q.preQuestSingle) do if done(id) then any = true break end end
            if not any then return false end
        end
        return true
    end

    -- --- the Questie bridge's calls, from here -----------------------------------------

    local facade = nil

    --- A table with core.addons.questie's calls, answered by this database.
    function M.questie()
        if facade then return facade end
        facade = {
            is_loaded = function() return M.available() end,
            is_ready = function() return M.available() end,
            get_quest_ids = function() return M.quest_ids() end,
            get_quest_npc_ids = function()
                local out, seen = {}, {}
                for _, quest_id in ipairs(M.active()) do
                    local npcs, objects = M.objective_ids(quest_id)
                    if M.is_complete(quest_id) then
                        npcs, objects = {}, {}
                        for _, f in ipairs(M.get("quest", quest_id, "finishedBy") or {}) do
                            -- finishedBy: {{npcs...}, {objects...}}
                            if type(f) == "table" then for _, id in ipairs(f) do npcs[id] = true end end
                        end
                    end
                    for id in pairs(npcs) do if not seen[id] then seen[id] = true out[#out + 1] = id end end
                    for id in pairs(objects) do if not seen[id] then seen[id] = true out[#out + 1] = id end end
                end
                return out
            end,
            query_quest_single = function(id, key) return M.get("quest", id, key) end,
            query_npc_single = function(id, key) return M.get("npc", id, key) end,
            query_object_single = function(id, key) return M.get("object", id, key) end,
            query_item_single = function(id, key) return M.get("item", id, key) end,
            is_quest_doable = function(id) return M.is_doable(id) end,
            -- Questie's own shape: 1 complete, 0 not. A boolean until 1.9.0,
            -- which a caller checking for Questie's 1 never saw as complete.
            is_quest_complete = function(id) return M.is_complete(id) and 1 or 0 end,
        }
        return facade
    end

    function M.stats()
        local idx = state.read and state.index or nil
        local n = 0
        for _ in pairs(active) do n = n + 1 end
        return {
            available = idx ~= nil, base = state.base, error = state.error,
            quests = idx and idx.kinds and idx.kinds.quest and idx.kinds.quest.rows or 0,
            npcs = idx and idx.kinds and idx.kinds.npc and idx.kinds.npc.rows or 0,
            buckets_read = state.buckets_read, active = n, swept = swept,
        }
    end

    return M
end

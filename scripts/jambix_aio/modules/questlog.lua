-- Jambix AIO / questlog -- the quests you are on, on every client.
--
-- quests.lua builds its index (which quest wants this mob, and how far along
-- it is) from the quest log. The core's quest log reads --
-- get_num_quest_log_entries, get_quest_log_title, the leader boards -- call
-- the classic globals, and the Forever client (Classic+, a classic world on
-- the retail engine) does not have them: there they answer 0 and an empty
-- row, the index stayed empty, and every quest mob drew a bare "[quest]" from
-- Questie's flat id set and nothing more.
--
-- So this file answers "which quests am I on, and how far along" two ways:
--
--   classic   the quest log, as before: titles, levels, objective text and
--             counts, all from the client.
--   tracked   Forever. is_on_quest still answers per id there, so the set is
--             kept by its edges: QUEST_ACCEPTED adds, QUEST_TURNED_IN removes,
--             and each read re-asks is_on_quest about what it holds, which is
--             how an abandon is noticed (the pump has no QUEST_REMOVED). The
--             quests already in the log at login are found by ONE sweep over
--             Questie's quest id list, a slice per frame; without Questie, the
--             guide's quests and whatever is accepted this session are known.
--             Names and levels come from Questie's database, completion from
--             Questie, objective text and counts from RestedXP.
--
-- THE 2026-10-06 CORE (1.82.0). It answers the quest log on Forever itself,
-- so the tracked set takes the game's word first wherever the core has it,
-- and each piece falls back to the way above where it does not:
--   the set         core.quests.get_quest_log_quest_ids, every read (no
--                   sweep). It lists only what the quest log shows, so a quest
--                   under a collapsed header stays held while is_on_quest
--                   says you are on it.
--   name, level     the quest log's own rows (get_quest_log_title), so
--                   Forever's own quests, which no Questie database has, are
--                   named too
--   objectives      core.quests.get_quest_objectives
--   complete        core.quests.is_quest_complete. Questie's answer was
--                   wrong both ways here before: its cache says 0 on Forever
--                   for a quest ready to hand in (the .api), and JCore's
--                   quest database answered true / false where Questie
--                   answers 1, so nothing read as complete.
-- The classic clients read their log exactly as before.
--
-- Both answer the same row shape, so the index does not know which ran:
--   { id, name, level, log_index?, complete, failed,
--     objectives = { { text, name, have, need, finished, kind } } }

return function(P)
    local ctx, log = P.ctx, P.log

    local M = {}

    --- core.<ns>.<field> when it is a function, else nil. Indexing inside a
    --- pcall's argument list happens BEFORE the pcall protects anything, so
    --- every native is resolved through here first.
    local function native(ns_name, field)
        local ns = type(core) == "table" and core[ns_name] or nil
        local fn = type(ns) == "table" and ns[field] or nil
        return type(fn) == "function" and fn or nil
    end

    local function bridge(name)
        -- Questie's calls from JCore's own quest database when it is there
        -- (1.55.0): the Questie addon is no longer needed.
        if name == "questie" then
            local db = ctx and ctx.questdb
            if db and db.available and db.questie then
                local ok, yes = pcall(db.available)
                if ok and yes then return db.questie() end
            end
        end
        local root = type(core) == "table" and core.addons or nil
        local addon = type(root) == "table" and root[name] or nil
        return type(addon) == "table" and addon or nil
    end

    --- An addon bridge that says it is loaded (and, for Questie, that its
    --- database is ready), or nil.
    local function questie_ready()
        local questie = bridge("questie")
        if not questie or type(questie.is_ready) ~= "function" then return nil end
        local ok, ready = pcall(questie.is_ready)
        return (ok and ready) and questie or nil
    end

    local function rested_loaded()
        if P.opt and not P.opt("rxp_on", true) then return nil end
        local rested = bridge("rested_xp")
        if not rested or type(rested.is_loaded) ~= "function" then return nil end
        local ok, loaded = pcall(rested.is_loaded)
        return (ok and loaded) and rested or nil
    end

    -- Forever or not; set once, below, before anything here runs.
    local TRACKED = false

    --- Splits an objective line into a name and its counts.
    ---
    --- The classic client writes "Bristleback Quilboar slain: 3/8"; the
    --- retail engine writes "3/8 Bristleback Quilboar slain", and that form is
    --- read on Forever only, so a classic objective parses as it always has. An
    --- objective with no counter -- "Speak with Gazrog" -- has neither. The
    --- trailing verb is stripped because the name is matched against a unit's
    --- name, and no mob is called "Quilboar slain".
    ---@param description string
    ---@return string name
    ---@return integer have
    ---@return integer need
    function M.parse_objective(description)
        if type(description) ~= "string" then return "", 0, 0 end

        local name, have, need = description:match("^(.-):%s*(%d+)%s*/%s*(%d+)%s*$")
        if not name and TRACKED then
            -- Forever only: the retail engine puts the count first.
            have, need, name = description:match("^%s*(%d+)%s*/%s*(%d+)%s+(.-)%s*$")
        end
        if not name then
            return description, 0, 0
        end

        name = name:gsub("%s+(slain)$", ""):gsub("%s+(killed)$", "")
        return name, tonumber(have) or 0, tonumber(need) or 0
    end

    local parse_objective = M.parse_objective

    -- --- which reader ---------------------------------------------------------

    --- Forever, by the JCore world service: the client whose quest log calls
    --- answer nothing. Every other client reads its quest log exactly as
    --- before, and none of the tracked machinery below is even registered.
    local function tracked_mode()
        local world = ctx and ctx.world
        if type(world) ~= "table" or type(world.client) ~= "function" then return false end
        local ok, client = pcall(world.client)
        return ok and type(client) == "table" and client.classic_quest_log == false
    end

    -- Decided once: a client cannot change without a restart.
    TRACKED = tracked_mode()

    -- --- classic ---------------------------------------------------------------

    local function classic_rows()
        local get_count = native("quests", "get_num_quest_log_entries")
        local get_title = native("quests", "get_quest_log_title")
        local get_boards = native("quests", "get_num_quest_leader_boards")
        local get_board = native("quests", "get_quest_log_leader_board")

        local entries_count = select(2, pcall(get_count))
        if type(entries_count) ~= "number" then entries_count = 0 end

        local rows = {}
        for i = 1, entries_count do
            local ok, row = pcall(get_title, i)
            if ok and type(row) == "table" and not row.is_header then
                local quest_id = row.quest_id
                if type(quest_id) == "number" and quest_id > 0 then
                    local quest = {
                        id = quest_id,
                        name = row.title or ("Quest " .. quest_id),
                        level = row.level,
                        log_index = i,
                        complete = row.is_complete == 1,
                        failed = row.is_complete == -1,
                        objectives = {},
                    }

                    local ok_n, n = false, nil
                    if get_boards then ok_n, n = pcall(get_boards, i) end
                    if ok_n and type(n) == "number" and get_board then
                        for j = 1, n do
                            local ok_lb, lb = pcall(get_board, j, i)
                            if ok_lb and type(lb) == "table" and lb.description then
                                local name, have, need = parse_objective(lb.description)
                                quest.objectives[#quest.objectives + 1] = {
                                    text = lb.description,
                                    name = name,
                                    have = have,
                                    need = need,
                                    finished = lb.is_completed and true or false,
                                    kind = lb.objective_type,
                                }
                            end
                        end
                    end

                    rows[#rows + 1] = quest
                end
            end
        end
        return rows
    end

    -- --- tracked (Forever) ----------------------------------------------------

    local held = {}          -- quest id -> true
    local held_order = {}    -- quest ids, first seen first
    local misses = {}        -- quest id -> reads in a row that said "not on it"
    local meta = {}          -- quest id -> { name, level } from Questie, static
    local sweep = nil        -- { ids, pos, found } while the login sweep runs
    local swept = false
    local checks = 0         -- is_on_quest calls made, for the debug page
    local asked = {}         -- quest id -> core.time() of the last consider() miss

    -- 60 ids a frame clears a Questie database of a few thousand quests in
    -- about a second, at a native call apiece; the freeze log in the README is
    -- why it is sliced at all.
    local SWEEP_SLICE = 60

    -- consider() is fed the guide's quest ids every second; one that is not
    -- in your log (a turn-in you have not picked up) is asked again only after
    -- this long.
    local CONSIDER_RETRY = 10.0

    -- A quest is dropped on the SECOND read in a row that says you are not on
    -- it. A loading screen can answer false for everything for a moment, and
    -- a quest dropped then would not come back until the next accept.
    local MISSES_TO_DROP = 2

    local function changed()
        if ctx and ctx.emit then ctx.emit("jambix.aio.questlog_changed") end
    end

    local function is_on(id)
        local fn = native("quests", "is_on_quest")
        if not fn then return false end
        checks = checks + 1
        local ok, on = pcall(fn, id)
        return ok and on == true
    end

    local function hold(id)
        if held[id] then return end
        held[id] = true
        misses[id] = nil
        held_order[#held_order + 1] = id
        changed()
    end

    local function drop(id)
        if not held[id] then return end
        held[id] = nil
        misses[id] = nil
        for i = #held_order, 1, -1 do
            if held_order[i] == id then table.remove(held_order, i) end
        end
        changed()
    end

    --- Adds a quest id if the client says you are on it. A no-op on the
    --- classic clients, whose log is read directly. quests.lua passes the
    --- guide's quest ids here, which is how the set fills without Questie.
    ---@param quest_id integer
    ---@return boolean held
    function M.consider(quest_id)
        if type(quest_id) ~= "number" or quest_id <= 0 then return false end
        if held[quest_id] then return true end
        if not TRACKED then return false end
        local now = core.time()
        local last = asked[quest_id]
        if last and (now - last) < CONSIDER_RETRY then return false end
        if is_on(quest_id) then
            asked[quest_id] = nil
            hold(quest_id)
            return true
        end
        asked[quest_id] = now
        return false
    end

    local function maybe_start_sweep()
        if swept or sweep then return end
        local questie = questie_ready()
        if not questie or type(questie.get_quest_ids) ~= "function" then return end
        local ok, ids = pcall(questie.get_quest_ids)
        if not ok or type(ids) ~= "table" or #ids == 0 then return end
        sweep = { ids = ids, pos = 1, found = 0 }
        log.fmt("info", "quest log: finding your quests in Questie's %d", #ids)
    end

    local function sweep_step()
        local s = sweep
        if not s then return end
        local ids = s.ids
        local last = math.min(s.pos + SWEEP_SLICE - 1, #ids)
        for i = s.pos, last do
            local id = ids[i]
            if type(id) == "number" and id > 0 and not held[id] and is_on(id) then
                hold(id)
                s.found = s.found + 1
            end
        end
        s.pos = last + 1
        if s.pos > #ids then
            sweep = nil
            swept = true
            log.fmt("info", "quest log: %d quest(s) found by the Questie sweep", s.found)
        end
    end

    --- Re-asks is_on_quest about every held quest but the ones the game has
    --- just listed (`listed`, id -> true), which need no asking.
    local function verify(listed)
        -- Copied first: a drop edits held_order.
        local ids = {}
        for i = 1, #held_order do ids[i] = held_order[i] end
        for i = 1, #ids do
            local id = ids[i]
            if (listed and listed[id]) or is_on(id) then
                misses[id] = nil
            else
                misses[id] = (misses[id] or 0) + 1
                if misses[id] >= MISSES_TO_DROP then drop(id) end
            end
        end
    end

    -- --- the game's own answers, the 2026-10-06 core (1.82.0) -----------------
    --
    -- Each is nil on a core without the call, and the old way answers.

    --- The quest ids the game lists in your log, in log order.
    local function game_list()
        local fn = native("quests", "get_quest_log_quest_ids")
        if not fn then return nil end
        local ok, ids = pcall(fn)
        if not ok or type(ids) ~= "table" then return nil end
        local out, seen = {}, {}
        for i = 1, #ids do
            local id = tonumber(ids[i])
            if id and id > 0 and not seen[id] then
                seen[id] = true
                out[#out + 1] = id
            end
        end
        return out
    end

    --- The quest log's own rows by quest id (title, level, is_complete).
    --- Empty on a core whose Forever log reads nothing.
    local function log_rows()
        local by_id = {}
        local get_count = native("quests", "get_num_quest_log_entries")
        local get_title = native("quests", "get_quest_log_title")
        if not (get_count and get_title) then return by_id end
        local ok, n = pcall(get_count)
        if not ok or type(n) ~= "number" then return by_id end
        for i = 1, n do
            local ok_r, row = pcall(get_title, i)
            if ok_r and type(row) == "table" and not row.is_header then
                local id = tonumber(row.quest_id)
                if id and id > 0 then by_id[id] = row end
            end
        end
        return by_id
    end

    --- A quest's objectives, as the game lists them.
    local function game_objectives(id)
        local fn = native("quests", "get_quest_objectives")
        if not fn then return nil end
        local ok, list = pcall(fn, id)
        if not ok or type(list) ~= "table" then return nil end
        local out = {}
        for j = 1, #list do
            local o = list[j]
            if type(o) == "table" and type(o.text) == "string" and o.text ~= "" then
                local name, have, need = parse_objective(o.text)
                out[#out + 1] = {
                    text = o.text,
                    name = name,
                    have = tonumber(o.fulfilled) or have,
                    need = tonumber(o.required) or need,
                    finished = o.finished and true or false,
                    kind = o.type,
                }
            end
        end
        return out
    end

    --- Ready to hand in, the game's own answer.
    local function game_complete(id)
        local fn = native("quests", "is_quest_complete")
        if not fn then return nil end
        local ok, v = pcall(fn, id)
        if ok and type(v) == "boolean" then return v end
        return nil
    end

    -- --- the older answers ------------------------------------------------------

    local function rested_objectives(rested, id)
        local objectives = {}
        if rested and type(rested.get_objectives) == "function" then
            local ok, list = pcall(rested.get_objectives, id)
            if ok and type(list) == "table" then
                for j = 1, #list do
                    local o = list[j]
                    if type(o) == "table" and type(o.text) == "string" and o.text ~= "" then
                        local name, have, need = parse_objective(o.text)
                        objectives[#objectives + 1] = {
                            text = o.text,
                            name = name,
                            have = tonumber(o.num_fulfilled) or have,
                            need = tonumber(o.num_required) or need,
                            finished = o.finished and true or false,
                            kind = o.type,
                        }
                    end
                end
            end
        end
        return objectives
    end

    --- Questie's 1 / 0 / -1, or nil. JCore's quest database answered true /
    --- false here before JCore 1.9.0; those are read as 1 and 0.
    local function questie_status(questie, id)
        if not (questie and type(questie.is_quest_complete) == "function") then return nil end
        local ok, value = pcall(questie.is_quest_complete, id)
        if not ok then return nil end
        if value == true then return 1 end
        if value == false then return 0 end
        return tonumber(value)
    end

    local function quest_meta(questie, id)
        local cached = meta[id]
        if cached then return cached end
        if not questie or type(questie.query_quest_single) ~= "function" then return nil end
        local ok_n, name = pcall(questie.query_quest_single, id, "name")
        if not ok_n or type(name) ~= "string" or name == "" then return nil end
        local ok_l, level = pcall(questie.query_quest_single, id, "questLevel")
        cached = { name = name, level = (ok_l and type(level) == "number") and level or nil }
        meta[id] = cached
        return cached
    end

    local listed_last = nil  -- how many the game listed on the last read, nil without the call

    local function tracked_rows()
        -- The game's own list where the core has one: what it lists is held
        -- at once and needs no is_on_quest to stay held, and no sweep runs.
        local listed = game_list()
        local in_list = {}
        if listed then
            for i = 1, #listed do
                in_list[listed[i]] = true
                hold(listed[i])
            end
        end
        listed_last = listed and #listed or nil
        verify(in_list)
        if not listed then maybe_start_sweep() end

        local questie = questie_ready()
        local rested = rested_loaded()
        local by_id = listed and log_rows() or {}

        -- The game's order first, then what else is held (a collapsed header's).
        local order = {}
        if listed then
            for i = 1, #listed do order[#order + 1] = listed[i] end
        end
        for i = 1, #held_order do
            if not in_list[held_order[i]] then order[#order + 1] = held_order[i] end
        end

        local rows = {}
        for i = 1, #order do
            local id = order[i]
            local row = by_id[id]
            local info = quest_meta(questie, id)

            local objectives = game_objectives(id)
            if not objectives or #objectives == 0 then
                local older = rested_objectives(rested, id)
                if #older > 0 or not objectives then objectives = older end
            end

            local complete = game_complete(id)
            local failed = row ~= nil and row.is_complete == -1
            if complete == nil then
                local status = questie_status(questie, id)
                local all_done = #objectives > 0
                for j = 1, #objectives do
                    if not objectives[j].finished then all_done = false end
                end
                -- Questie's cache can say 0 on Forever for a quest that is
                -- ready (the .api), so every objective finished says it too.
                complete = status ~= -1 and (status == 1 or all_done)
                failed = failed or status == -1
            end

            local name = row and type(row.title) == "string" and row.title ~= "" and row.title or nil
            rows[#rows + 1] = {
                id = id,
                name = name or (info and info.name) or ("Quest " .. id),
                level = (row and tonumber(row.level)) or (info and info.level) or nil,
                complete = complete,
                failed = failed,
                objectives = objectives,
            }
        end
        return rows
    end

    -- Edges, Forever only; the classic clients read the log directly.
    --
    -- QUEST_ACCEPTED is (quest_id) on the retail engine and (log_index,
    -- quest_id) on the classic clients. Both positions are offered and
    -- is_on_quest decides, so the shape does not have to be known.
    if TRACKED then
        ctx.on("jcore.game_event.QUEST_ACCEPTED", function(args)
            if type(args) ~= "table" then return end
            for i = 1, 2 do
                local v = args[i]
                if type(v) == "number" then
                    asked[v] = nil   -- an accept is news: never throttled
                    M.consider(v)
                end
            end
        end)

        ctx.on("jcore.game_event.QUEST_TURNED_IN", function(args)
            if type(args) ~= "table" then return end
            local id = args[1]
            if type(id) == "number" then drop(id) end
        end)

        -- Only does work while the login sweep runs.
        ctx.tick(function()
            if sweep then sweep_step() end
        end, { priority = 60 })
    end

    -- --- public ----------------------------------------------------------------

    --- The quests you are on, as rows (see the top of this file). nil when the
    --- client has no way to say: no quest log calls and no is_on_quest.
    ---@return table[]|nil rows
    ---@return string mode "classic" or "tracked"
    function M.read()
        if TRACKED then
            if not native("quests", "is_on_quest") then return nil, "tracked" end
            return tracked_rows(), "tracked"
        end
        if not (native("quests", "get_num_quest_log_entries") and native("quests", "get_quest_log_title")) then
            return nil, "classic"
        end
        return classic_rows(), "classic"
    end

    function M.stats()
        return {
            mode = TRACKED and "tracked" or "classic",
            held = #held_order,
            sweeping = sweep ~= nil,
            sweep_pos = sweep and sweep.pos or 0,
            sweep_total = sweep and #sweep.ids or 0,
            swept = swept,
            checks = checks,
            -- The game's own list (the 2026-10-06 core): how many it listed
            -- on the last read, nil on a core without it.
            listed = listed_last,
        }
    end

    --- Does the game list your quests itself (the 2026-10-06 core)? Only
    --- known once a tracked read has run; false on the classic clients.
    function M.game_listed()
        return TRACKED and listed_last ~= nil
    end

    return M
end

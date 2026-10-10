-- Jambix AIO / quests -- Questie targets, RestedXP guide state, waypoint line.
--
-- Both addons are read through core.addons, which is a real bridge into the
-- running addon rather than a file parse, so everything here is live. Both are
-- optional: every entry point checks is_loaded and the feature simply does not
-- appear when the addon is absent.
--
-- The two are complementary rather than redundant. Questie answers "is this
-- specific object one of my quest targets", by id, for anything on screen.
-- RestedXP answers "what does the guide want me to do next", which is a small
-- ordered set of goals plus a waypoint.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, draw = P.units, P.draw

    local M = {}

    --- What a quest objective asks you to do with its target, by the
    --- objective type the client (or RestedXP) reports. Anything not listed
    --- -- an event, a reputation, a player kill -- gets no tag, and the mark
    --- says plainly "quest".
    M.OBJECTIVE_TAG = {
        monster = "kill",
        item = "collect",
        object = "use",
    }

    -- --- name matching -------------------------------------------------------
    --
    -- Shared by the quest index and the guide: a unit's name against a quest
    -- objective's name or a guide goal's text, compared WORD BY WORD in the
    -- singular. Up here because the index is rebuilt while this file loads.

    --- One word in the singular, near enough for matching a creature's name
    --- against a guide's plural: wolves -> wolf, harpies -> harpy, kobolds ->
    --- kobold. Applied to BOTH sides, so a rule that is wrong for some word
    --- ("boxes" -> "boxe") is wrong the same way on each side and still meets.
    local function singular(word)
        local n = #word
        if n > 4 and word:sub(-3) == "ves" then return word:sub(1, -4) .. "f" end
        if n > 4 and word:sub(-3) == "ies" then return word:sub(1, -4) .. "y" end
        if n > 3 and word:sub(-1) == "s" and word:sub(-2) ~= "ss" then return word:sub(1, -2) end
        return word
    end

    --- The form a guide goal and a unit name are compared in: lower case,
    --- every word singular.
    ---@param text string
    ---@return string
    function M.guide_key(text)
        return (text:lower():gsub("[%a']+", singular))
    end

    --- Does `needle` appear in `hay` as the START of a word? "mangy wolf"
    --- is in "kill 8 mangy wolf" (the goal, singularised); "kaw" is not in
    --- "kawahmwhaz". A bare substring test matched any name hiding inside any
    --- longer word, and never matched a plural at all: "mangy wolf" is not a
    --- substring of "mangy wolves".
    local function word_in(hay, needle)
        local from = 1
        while true do
            local s = hay:find(needle, from, true)
            if not s then return false end
            if s == 1 or not hay:sub(s - 1, s - 1):match("[%w']") then return true end
            from = s + 1
        end
    end

    -- A name shorter than this is too likely to sit inside some goal's text
    -- by chance to count as the guide naming it.
    local MIN_GUIDE_NAME = 3


    -- Which quests you are on: the classic quest log, or the tracked set on
    -- Forever, whose client has no classic quest log (see modules/questlog).
    local questlog = P.questlog or P.load("modules/questlog")(P)
    P.questlog = questlog
    M.questlog = questlog

    --- Resolves an addon bridge, or nil.
    ---
    --- core.addons is not guaranteed to exist. Reaching straight for
    --- core.addons.questie.is_loaded indexes TWO fields before the pcall that
    --- was supposed to make the call safe, so on a build without the bridge
    --- the error escapes and takes the whole plugin down at load. Every access
    --- below goes through here instead.
    ---@param name string
    ---@return table|nil
    local function bridge(name)
        -- Questie's calls come from JCore's own quest database (1.55.0, JCore
        -- 1.6.0: scripts_data/jcore/questdb, extracted from QuestieDB) when it
        -- is there: the Questie addon is no longer needed for any of this.
        if name == "questie" then
            local db = ctx and ctx.questdb
            if db and db.available and db.questie then
                local ok, yes = pcall(db.available)
                if ok and yes then return db.questie() end
            end
        end
        local root = core.addons
        if type(root) ~= "table" then return nil end
        local addon = root[name]
        if type(addon) ~= "table" then return nil end
        return addon
    end

    -- --- Questie ------------------------------------------------------------

    -- npc/object id -> true, refreshed on a timer. get_quest_npc_ids walks
    -- Questie's quest log every call, so this is not something to do per frame.
    local questie_ids = {}
    local questie_ready = false
    local questie_count = 0

    local function refresh_questie()
        if not P.opt("questie_on", true) then return end

        local questie = bridge("questie")
        if not questie then
            questie_ready = false
            return
        end

        local ok, loaded = pcall(questie.is_loaded)
        if not ok or not loaded then
            questie_ready = false
            return
        end

        local ok_ids, ids = pcall(questie.get_quest_npc_ids)
        if not ok_ids or type(ids) ~= "table" then return end

        local fresh = {}
        local n = 0
        for i = 1, #ids do
            local id = ids[i]
            if type(id) == "number" then
                fresh[id] = true
                n = n + 1
            end
        end

        questie_ids = fresh
        questie_count = n
        questie_ready = true
    end

    ctx.every(3.0, refresh_questie)
    refresh_questie()

    -- The quest log changing is the event that actually invalidates this. It
    -- is NOT bound here directly: see the coalesced QUEST_LOG_UPDATE handler
    -- below the index rebuild, which runs this and the rebuild together.

    function M.questie_status()
        if not questie_ready then return "not loaded" end
        return string.format("%d target id(s)", questie_count)
    end

    -- --- the quest index ----------------------------------------------------
    --
    -- get_quest_npc_ids answers a flat set of ids with no attribution, which
    -- is why every quest mob used to be marked "[quest]" and nothing more: the
    -- overlay genuinely did not know WHICH quest, and could not have said.
    --
    -- So the attribution is assembled here from three sources, each answering
    -- the part the others cannot:
    --
    --   the game's quest log   the quests you are on, their real objective
    --                          text and the real x/y progress. Authoritative,
    --                          always available, needs no addon.
    --   Questie's database     which npc and object ids belong to which quest,
    --                          including the mobs that drop a quest item and
    --                          the npcs that hand a quest out. Optional.
    --   RestedXP               which of them the guide wants next. Optional.
    --
    -- Without Questie the index still works: an objective reads "Bristleback
    -- Quilboar slain: 3/8", and that name matches the mob standing in front of
    -- you. Collection quests are the ones that need the database, because
    -- "Bristleback Tusk: 2/8" never names the boar.

    local index = {
        quests = {},     -- quest_id -> quest
        order = {},      -- quest ids, quest-log order
        by_npc = {},     -- npc id -> entry[]
        by_name = {},    -- lowercase target name -> entry[]
        by_object = {},       -- world object id -> entry[] (1.47.5)
        by_object_name = {},  -- Questie's lowercase name for that object -> entry[]
        names = {},      -- the same names as an array, for containment scans
        memo = {},       -- npc id or "n:<name>" -> entry[] | false
        count = 0,
        signature = "",
    }

    M.index = index

    -- Questie database answers, cached per quest id for the session. A quest's
    -- npc list is static data -- it does not change while you are on the
    -- quest, or after -- and each answer is several database round trips
    -- into the addon. This used to be wiped on every accept and turn-in,
    -- which re-queried every quest in the log in one frame each time.
    local questie_db_cache = {}

    --- Every number and string anywhere inside a Questie objective blob.
    ---
    --- The shape of `objectives` differs between entry kinds -- a creature
    --- objective is {npcId, text}, a kill-credit objective is {{ids}, npcId,
    --- text} -- and it has changed between Questie versions. Walking for the
    --- numbers is tolerant of all of them, and the only thing that could go
    --- wrong is picking up an id that does not exist in the world, which
    --- marks nothing.
    local function harvest(node, ids, texts, depth)
        if type(node) ~= "table" or depth > 4 then return end
        for _, value in pairs(node) do
            local kind = type(value)
            if kind == "number" then
                if value > 0 then ids[#ids + 1] = value end
            elseif kind == "string" then
                if value ~= "" then texts[#texts + 1] = value end
            elseif kind == "table" then
                harvest(value, ids, texts, depth + 1)
            end
        end
    end

    -- Questie's name for a world object, lowercased, by object id: static
    -- data, asked once per object for the session.
    local object_name_cache = {}

    --- What Questie calls a world object, so it can be found by name when the
    --- client will not say which object it is.
    ---@param id integer
    ---@return string|nil
    local function questie_object_name(id)
        local cached = object_name_cache[id]
        if cached ~= nil then return cached or nil end
        local questie = bridge("questie")
        if not questie or type(questie.query_object_single) ~= "function" then return nil end
        local ok, name = pcall(questie.query_object_single, id, "name")
        object_name_cache[id] = (ok and type(name) == "string" and name ~= "") and name:lower() or false
        return object_name_cache[id] or nil
    end

    --- Files an entry under a world object: by its id, and by the name
    --- Questie has for it.
    local function add_object_entry(add, by_object, by_object_name, id, entry)
        add(by_object, id, entry)
        add(by_object_name, questie_object_name(id), entry)
    end

    --- npc and object ids associated with a quest, from Questie's database.
    ---@param quest_id integer
    ---@return table|nil { npcs = integer[], objects = integer[], givers = integer[], enders = integer[], texts = string[] }
    local function questie_targets(quest_id)
        local cached = questie_db_cache[quest_id]
        if cached ~= nil then return cached or nil end

        local questie = bridge("questie")
        if not questie then
            questie_db_cache[quest_id] = false
            return nil
        end

        local ok_ready, ready = pcall(questie.is_ready)
        if not ok_ready or not ready then
            -- NOT cached: Questie's database loads a moment after the addon
            -- does, and caching a miss here would leave the index blind for
            -- the rest of the session.
            return nil
        end

        -- `npcs` and `objects` hold every target, because the spawn paths
        -- want the drop mobs too. `collect` marks the ids that are there
        -- only because they DROP a quest item -- so the mark can say
        -- "collect" over a quilboar that carries the tusks, and "kill" over
        -- one that is itself the objective.
        -- giver_objects / ender_objects (1.47.5): quests that start or end at
        -- something in the world rather than at an npc -- a wanted poster, a
        -- journal, a grave, a chest. Questie lists them second in startedBy
        -- and finishedBy, after the npcs.
        local out = { npcs = {}, objects = {}, givers = {}, enders = {}, texts = {}, collect = {},
            giver_objects = {}, ender_objects = {} }

        local ok, objectives = pcall(questie.query_quest_single, quest_id, "objectives")
        -- PER OBJECTIVE (1.64.1): the same targets, grouped by the objective
        -- they serve -- { name, npcs, objects, collect } -- so that once one
        -- objective is done its mobs stop being marked while the quest still
        -- wants something else. The name is what the quest log calls the
        -- objective: an item's name, an object's, or the objective's text.
        out.groups = {}
        if ok and type(objectives) == "table" then
            local function entries(list) return type(list) == "table" and list or {} end
            local function item_name(id)
                local ok_n, n = pcall(questie.query_item_single, id, "name")
                return (ok_n and type(n) == "string" and n ~= "") and n or nil
            end
            for _, e in ipairs(entries(objectives[1])) do
                local ids, texts = {}, {}
                harvest(e, ids, texts, 0)
                if #ids > 0 then out.groups[#out.groups + 1] = { name = texts[1], npcs = ids, objects = {} } end
            end
            for _, e in ipairs(entries(objectives[5])) do
                local ids, texts = {}, {}
                harvest(e, ids, texts, 0)
                if #ids > 0 then out.groups[#out.groups + 1] = { name = texts[1], npcs = ids, objects = {} } end
            end
            for _, e in ipairs(entries(objectives[2])) do
                local ids, texts = {}, {}
                harvest(e, ids, texts, 0)
                if #ids > 0 then
                    out.groups[#out.groups + 1] = { name = texts[1] or questie_object_name(ids[1]),
                        npcs = {}, objects = ids }
                end
            end
            for _, e in ipairs(entries(objectives[3])) do
                local ids, texts = {}, {}
                harvest(e, ids, texts, 0)
                local item = ids[1]
                if item then
                    local npcs, objs = {}, {}
                    local ok_drop, drops = pcall(questie.query_item_single, item, "npcDrops")
                    if ok_drop then harvest(drops, npcs, {}, 3) end
                    local ok_obj, obj_drops = pcall(questie.query_item_single, item, "objectDrops")
                    if ok_obj then harvest(obj_drops, objs, {}, 3) end
                    out.groups[#out.groups + 1] = { name = item_name(item) or texts[1], npcs = npcs,
                        objects = objs, collect = true }
                end
            end
        end
        if ok and type(objectives) == "table" then
            -- 1 creatures, 2 objects, 3 items, 4 reputation, 5 kill credit.
            -- Reputation is skipped: its numbers are faction ids, and nothing
            -- in the world carries one.
            harvest(objectives[1], out.npcs, out.texts, 0)
            harvest(objectives[5], out.npcs, out.texts, 0)
            harvest(objectives[2], out.objects, out.texts, 0)

            local direct = {}
            for i = 1, #out.npcs do direct["n" .. out.npcs[i]] = true end
            for i = 1, #out.objects do direct["o" .. out.objects[i]] = true end

            local item_ids, drop_npcs, drop_objects = {}, {}, {}
            harvest(objectives[3], item_ids, out.texts, 0)
            for i = 1, #item_ids do
                local ok_drop, drops = pcall(questie.query_item_single, item_ids[i], "npcDrops")
                if ok_drop then harvest(drops, drop_npcs, out.texts, 3) end
                local ok_obj, obj_drops = pcall(questie.query_item_single, item_ids[i], "objectDrops")
                if ok_obj then harvest(obj_drops, drop_objects, out.texts, 3) end
            end
            for i = 1, #drop_npcs do
                local id = drop_npcs[i]
                out.npcs[#out.npcs + 1] = id
                if not direct["n" .. id] then out.collect[id] = true end
            end
            for i = 1, #drop_objects do
                local id = drop_objects[i]
                out.objects[#out.objects + 1] = id
                if not direct["o" .. id] then out.collect[id] = true end
            end
        end

        local ok_start, started_by = pcall(questie.query_quest_single, quest_id, "startedBy")
        if ok_start and type(started_by) == "table" then
            harvest(started_by[1], out.givers, out.texts, 0)
            harvest(started_by[2], out.giver_objects, out.texts, 0)
        end

        local ok_end, finished_by = pcall(questie.query_quest_single, quest_id, "finishedBy")
        if ok_end and type(finished_by) == "table" then
            harvest(finished_by[1], out.enders, out.texts, 0)
            harvest(finished_by[2], out.ender_objects, out.texts, 0)
        end

        questie_db_cache[quest_id] = out
        return out
    end

    -- --- how far along an objective is (1.64.1) --------------------------------

    local SUBJECT_VERBS = { " slain", " killed", " destroyed", " defeated", " collected", " freed",
        " rescued", " captured", " found", " used", " activated", " investigated" }

    --- What an objective is about, lowered: "Kobold Vermin slain" -> "kobold vermin".
    local function subject(s)
        if type(s) ~= "string" then return nil end
        s = s:lower():gsub("%s*%(quest%)%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
        for i = 1, #SUBJECT_VERBS do
            local v = SUBJECT_VERBS[i]
            if s:sub(-#v) == v then s = s:sub(1, -#v - 1) break end
        end
        if s == "" then return nil end
        return s
    end

    local function same_subject(a, b)
        if not a or not b then return false end
        if a == b then return true end
        return a .. "s" == b or b .. "s" == a or a .. "es" == b or b .. "es" == a
    end

    --- The Forever quest marks' progress (esp/forever_quests.lua), where the
    --- client has no quest log to say.
    local function forever_progress(name)
        local esp = P.esp
        local fq = esp and esp.forever and esp.forever.quests
        if not (fq and type(fq.progress) == "function") then return nil end
        local ok, p = pcall(fq.progress, name)
        if ok and type(p) == "table" and tonumber(p.need) and p.need > 0 then return p end
        return nil
    end

    --- Is the objective this name stands for done? true / false, and the
    --- quest log's objective when it has one; nil when nothing says.
    local function objective_done(quest, name)
        local want = subject(name)
        if not want then return nil end
        for _, o in ipairs(quest.objectives or {}) do
            if o.name and o.name ~= "" and same_subject(subject(o.name), want) then
                return o.finished == true, o
            end
        end
        local p = forever_progress(name)
        if p then return (tonumber(p.have) or 0) >= p.need, nil end
        return nil
    end

    local function add_entry(map, key, entry)
        if not key or key == "" then return end
        local list = map[key]
        if not list then
            list = {}
            map[key] = list
        end
        -- One quest, one entry per target. A mob that appears in two
        -- objectives of the same quest is still one line on the mark.
        for i = 1, #list do
            if list[i].quest.id == entry.quest.id then return end
        end
        list[#list + 1] = entry
    end

    --- Rebuilds the whole index from the quest log outward.
    ---
    --- The log itself comes from modules/questlog.lua, which reads the classic
    --- quest log where the client has one and keeps the set by its edges on
    --- Forever, where it does not -- from the game's own quest list there on
    --- the 2026-10-06 core. The rows are the same shape either way.
    local function rebuild_index()
        local rows, mode = questlog.read()
        if not rows then
            log.once("warn", "no_quest_api",
                "this build has no quest log API; the quest index is empty")
            return
        end
        if mode == "tracked" then
            if questlog.game_listed and questlog.game_listed() then
                log.once("info", "questlog_game",
                    "Forever: quests, objectives and completion from the game's own quest log (2026-10-06 core)")
            else
                log.once("info", "questlog_tracked",
                    "no classic quest log on this client (Forever): quests are tracked from accept/turn-in, Questie and RestedXP")
            end
        end

        local quests, order = {}, {}
        local by_npc, by_name, names = {}, {}, {}
        -- World objects by their own id (1.47.5). They used to share by_npc,
        -- so an npc whose id happened to equal a quest object's was marked
        -- USE, and the other way round.
        local by_object, by_object_name = {}, {}

        for i = 1, #rows do
            local quest = rows[i]
            if not quests[quest.id] then
                quest.color_index = #order + 1
                quests[quest.id] = quest
                order[#order + 1] = quest.id
            end
        end

        -- Name targets come from the objective text, which needs no addon.
        --
        -- Every entry carries a `tag`: what the mark asks you to DO with the
        -- thing -- "kill", "collect", "use", "turn_in", "pick_up" -- so a
        -- quest mark can say so instead of the bare word "quest". (Not to be
        -- confused with an objective's `kind`, the client's own objective
        -- type, which is where the name entries' tag comes from.)
        for i = 1, #order do
            local quest = quests[order[i]]
            for j = 1, #quest.objectives do
                local objective = quest.objectives[j]
                if objective.name ~= "" and not objective.finished then
                    local key = objective.name:lower()
                    add_entry(by_name, key, { quest = quest, objective = objective,
                        tag = M.OBJECTIVE_TAG[objective.kind] })
                    names[#names + 1] = key
                end
            end
        end

        -- Id targets come from Questie, and cover what the text cannot: the
        -- mobs that drop a quest item, and the npc that hands the quest out.
        --
        -- ONLY WHAT IS STILL WANTED (1.64.1). The user, 2026-10-04: marks
        -- stayed on after "Quest Complete", and on a mob whose drop was
        -- already collected while the quest waited on another mob's. Each
        -- objective's targets are now filed only while that objective is not
        -- done (the quest log says, or on Forever the progress messages), and
        -- a quest whose every objective is done counts as complete: its
        -- turn-in is marked instead. An objective nothing says anything
        -- about stays marked, as before.
        local finished_npcs, wanted_npcs = {}, {}
        local wanted_by_quest = {}
        for i = 1, #order do
            local quest = quests[order[i]]
            local targets = questie_targets(quest.id)
            if targets then
                local unfinished = nil
                for j = 1, #quest.objectives do
                    if not quest.objectives[j].finished then
                        unfinished = quest.objectives[j]
                        break
                    end
                end

                local groups = targets.groups
                local states = {}
                local all_done = groups ~= nil and #groups > 0
                for g = 1, #(groups or {}) do
                    local done, objective = objective_done(quest, groups[g].name)
                    states[g] = { done = done, objective = objective }
                    if done ~= true then all_done = false end
                end
                if all_done then quest.complete = true end

                if not quest.complete and groups and #groups > 0 then
                    local wanted = { npcs = {}, objects = {} }
                    wanted_by_quest[quest.id] = wanted
                    for g = 1, #groups do
                        local grp, st = groups[g], states[g]
                        if st.done == true then
                            for _, id in ipairs(grp.npcs) do finished_npcs[id] = true end
                        else
                            local objective = st.objective or unfinished
                            for _, id in ipairs(grp.npcs) do
                                wanted_npcs[id] = true
                                wanted.npcs[#wanted.npcs + 1] = id
                                add_entry(by_npc, id, { quest = quest, objective = objective,
                                    tag = grp.collect and "collect" or "kill", named = grp.name ~= nil })
                            end
                            for _, id in ipairs(grp.objects) do
                                wanted.objects[#wanted.objects + 1] = id
                                add_object_entry(add_entry, by_object, by_object_name, id,
                                    { quest = quest, objective = objective,
                                        tag = grp.collect and "collect" or "use" })
                            end
                        end
                    end
                elseif not quest.complete then
                    local collect = targets.collect or {}
                    for j = 1, #targets.npcs do
                        local id = targets.npcs[j]
                        wanted_npcs[id] = true
                        add_entry(by_npc, id, { quest = quest, objective = unfinished,
                            tag = collect[id] and "collect" or "kill" })
                    end
                    for j = 1, #targets.objects do
                        local id = targets.objects[j]
                        add_object_entry(add_entry, by_object, by_object_name, id,
                            { quest = quest, objective = unfinished,
                                tag = collect[id] and "collect" or "use" })
                    end
                end

                -- The turn-in npc, once the quest is actually ready to hand
                -- in. Marking it before then would point at the far end of a
                -- quest you have not done yet. And the turn-in OBJECT, for a
                -- quest handed in at something in the world (1.47.5).
                if quest.complete then
                    for j = 1, #targets.enders do
                        add_entry(by_npc, targets.enders[j],
                            { quest = quest, turn_in = true, tag = "turn_in" })
                    end
                    for j = 1, #targets.ender_objects do
                        add_object_entry(add_entry, by_object, by_object_name, targets.ender_objects[j],
                            { quest = quest, turn_in = true, tag = "turn_in" })
                    end
                end
            end
        end

        -- An npc only finished objectives want, and nothing else does.
        for id in pairs(wanted_npcs) do finished_npcs[id] = nil end
        index.finished_npcs = finished_npcs
        index.wanted_by_quest = wanted_by_quest
        index.quests = quests
        index.order = order
        index.by_npc = by_npc
        index.by_name = by_name
        index.by_object = by_object
        index.by_object_name = by_object_name
        index.names = names
        local keys = {}
        for i = 1, #names do keys[i] = M.guide_key(names[i]) end
        index.name_keys = keys
        index.memo = {}
        index.count = #order
    end

    --- Quest ids the guide wants that are NOT in the log yet -- the ones it is
    --- about to send you to pick up. Their quest givers are worth marking.
    local function index_guide_givers(guide_quest_ids)
        for quest_id in pairs(guide_quest_ids) do
            if not index.quests[quest_id] then
                local targets = questie_targets(quest_id)
                local questie = bridge("questie")
                if targets and questie and (#targets.givers + #targets.giver_objects) > 0 then
                    local ok, name = pcall(questie.query_quest_single, quest_id, "name")
                    local quest = {
                        id = quest_id,
                        name = (ok and type(name) == "string" and name)
                            or ("Quest " .. quest_id),
                        objectives = {},
                        color_index = index.count + 1,
                        offered = true,
                    }
                    index.quests[quest_id] = quest
                    index.order[#index.order + 1] = quest_id
                    index.count = index.count + 1
                    for j = 1, #targets.givers do
                        add_entry(index.by_npc, targets.givers[j],
                            { quest = quest, pick_up = true, tag = "pick_up" })
                    end
                    -- A quest picked up from something in the world (1.47.5).
                    for j = 1, #targets.giver_objects do
                        add_object_entry(add_entry, index.by_object, index.by_object_name,
                            targets.giver_objects[j], { quest = quest, pick_up = true, tag = "pick_up" })
                    end
                    index.memo = {}
                end
            end
        end
    end

    M.index_guide_givers = index_guide_givers

    -- Who hands a quest out and who takes it back, as id sets, for the guide
    -- walk (1.7.4): the npc to talk to for an .accept or a .turnin step,
    -- whether or not the quest is in the log or counted complete yet.
    local people_cache = {}

    ---@param quest_id integer
    ---@return { givers: table<integer, true>, enders: table<integer, true>, giver_objects: table<integer, true>, ender_objects: table<integer, true> }|nil
    function M.quest_people(quest_id)
        if type(quest_id) ~= "number" or quest_id <= 0 then return nil end
        local hit = people_cache[quest_id]
        if hit then return hit end
        local targets = questie_targets(quest_id)
        if not targets then return nil end
        local function set(list)
            local out = {}
            for i = 1, #(list or {}) do out[list[i]] = true end
            return out
        end
        hit = { givers = set(targets.givers), enders = set(targets.enders),
            giver_objects = set(targets.giver_objects), ender_objects = set(targets.ender_objects) }
        people_cache[quest_id] = hit
        return hit
    end

    --- A quest's name: the log's, else the quest database's, else nil.
    ---@param quest_id integer
    ---@return string|nil
    function M.quest_name(quest_id)
        local quest = index.quests[quest_id]
        if quest and type(quest.name) == "string" and quest.name ~= "" then return quest.name end
        local questie = bridge("questie")
        if not (questie and questie.query_quest_single) then return nil end
        local ok, name = pcall(questie.query_quest_single, quest_id, "name")
        if ok and type(name) == "string" and name ~= "" then return name end
        return nil
    end

    -- The quest log is the thing that invalidates this, and it fires its own
    -- event. The timer is a backstop for progress that arrives without one.
    --
    -- QUEST_LOG_UPDATE, COALESCED. The client fires it in bursts -- a dozen
    -- in one frame on login and after a loading screen, once per kill credit,
    -- once per loot, and every time an addon touches the log -- and each one
    -- used to run a full index rebuild (a native call per quest, per
    -- objective) AND Questie's own quest-log walk, inside the handler, in the
    -- same frame. A burst of twelve was twelve of each: the same freeze the
    -- SPELLS_CHANGED handler had. Now the events only mark the index dirty
    -- and ONE rebuild runs on a later tick, at most twice a second. Nothing
    -- is lost: every burst still ends in a rebuild, it just ends in one.
    local index_dirty, last_rebuild = false, 0
    local REBUILD_COALESCE = 0.5

    local function mark_dirty() index_dirty = true end
    ctx.on("jcore.game_event.QUEST_LOG_UPDATE", mark_dirty)
    ctx.on("jcore.game_event.QUEST_ACCEPTED", mark_dirty)
    ctx.on("jcore.game_event.QUEST_TURNED_IN", mark_dirty)
    ctx.on("jambix.aio.questlog_changed", mark_dirty)
    -- "Gold Dust: 8/10": on Forever this is how an objective's progress arrives.
    ctx.on("jcore.game_event.UI_INFO_MESSAGE", mark_dirty)

    ctx.tick(function()
        if not index_dirty then return end
        local now = core.time()
        if (now - last_rebuild) < REBUILD_COALESCE then return end
        index_dirty, last_rebuild = false, now
        refresh_questie()
        rebuild_index()
    end, { priority = 5 })

    ctx.every(5.0, rebuild_index)
    rebuild_index()

    --- Entries matched by name, for a unit whose id the index does not know.
    local function match_by_name(name)
        local lowered = name:lower()
        local exact = index.by_name[lowered]
        if exact then return exact end

        -- An objective can name a group the unit belongs to ("Bristleback
        -- Quilboar" against "Bristleback Quilboar Geomancer"), and it can also
        -- be the longer of the two, so the containment is tested both ways --
        -- as WHOLE WORDS, in the singular. A bare substring test put a pet
        -- called "Boar" on a quest for "Bristleback Quilboar", and never
        -- matched "Plainstrider" against an objective naming "Plainstriders".
        if #name < MIN_GUIDE_NAME then return nil end
        local key = M.guide_key(name)
        local keys = index.name_keys or {}
        for i = 1, #index.names do
            local other = keys[i] or index.names[i]
            if word_in(other, key) or word_in(key, other) then
                return index.by_name[index.names[i]]
            end
        end
        return nil
    end

    --- Which quests, if any, want this unit or object -- with the live
    --- objective progress for each.
    ---
    --- Memoised per npc id, because the answer is the same for every boar of
    --- the same kind and the containment scan above is the expensive part.
    ---@param obj game_object
    ---@param name? string
    ---@param known_npc_id? integer|false The id if the caller already read it. The
    --- classifier does, once per unit, and passing it back saves a native call
    --- per unit per frame for an answer that cannot change. False when the
    --- caller asked and there was none (a spell effect, a player's corpse):
    --- nil would ask the client again, every frame.
    ---@param is_object? boolean A world object rather than a unit (1.47.5):
    --- looked up among the quest objects, by id and then by Questie's name for
    --- it, so it is found even where the client answers no id for objects.
    ---@return table[]|nil entries { quest, objective?, turn_in?, pick_up? }
    function M.quest_entries(obj, name, known_npc_id, is_object)
        if index.count == 0 then return nil end

        local npc_id
        if type(known_npc_id) == "number" then
            if known_npc_id > 0 then npc_id = known_npc_id end
        elseif known_npc_id ~= false then
            local ok, id = pcall(obj.get_npc_id, obj)
            if ok and type(id) == "number" and id > 0 then npc_id = id end
        end

        local key = npc_id or (name and name ~= "" and ("n:" .. name) or nil)
        if not key then return nil end
        -- An object's key carries its name too: what the client answers as an
        -- object's id is not proven to be the object's own, and one id shared
        -- by every object would otherwise give them all one answer.
        if is_object then key = "o:" .. tostring(npc_id or "") .. ":" .. tostring(name or "") end

        local memo = index.memo[key]
        if memo ~= nil then
            if memo == false then return nil end
            return memo
        end

        local entries
        if is_object then
            entries = (npc_id and index.by_object[npc_id])
                or (name and name ~= "" and index.by_object_name[name:lower()])
                or nil
        else
            entries = npc_id and index.by_npc[npc_id] or nil
        end
        if not entries and name and name ~= "" then
            entries = match_by_name(name)
        end

        -- A target filed by id under an objective Questie gave no name for:
        -- the unit's own name says whether that objective is done (1.64.1).
        if entries and name and name ~= "" and not is_object then
            local kept = nil
            for i = 1, #entries do
                local e = entries[i]
                local drop = false
                if e.tag == "kill" and not e.named and e.quest then
                    drop = objective_done(e.quest, name) == true
                end
                if drop and not kept then
                    kept = {}
                    for j = 1, i - 1 do kept[#kept + 1] = entries[j] end
                elseif kept and not drop then
                    kept[#kept + 1] = e
                end
            end
            if kept then entries = #kept > 0 and kept or nil end
        end

        index.memo[key] = entries or false
        return entries
    end

    --- Questie's own flat id set. The fast path, and the only thing that
    --- answers for a quest whose objectives the index could not resolve.
    ---@param npc_id integer|nil
    ---@return boolean
    function M.is_questie_id(npc_id)
        if not questie_ready or type(npc_id) ~= "number" then return false end
        -- Not one only finished objectives want (1.64.1).
        if index.finished_npcs and index.finished_npcs[npc_id] then return false end
        return questie_ids[npc_id] == true
    end

    --- Is this object or NPC one of the player's current quest targets?
    ---
    --- Kept for callers outside the overlay -- the targeting module asks this
    --- about one unit at a time. The overlay itself takes the entries instead,
    --- because it wants to SAY which quest.
    ---@param obj game_object
    ---@return boolean
    function M.is_quest_target(obj)
        local ok, id = pcall(obj.get_npc_id, obj)
        local npc_id = (ok and type(id) == "number") and id or nil
        if M.is_questie_id(npc_id) then return true end

        local ok_name, name = pcall(obj.get_name, obj)
        return M.quest_entries(obj, ok_name and name or nil, npc_id) ~= nil
    end

    --- The colour that identifies a quest, so two quests on one screen are
    --- told apart without a setting.
    ---
    --- Built once and kept on the quest, which lives until the quest log
    --- changes. Allocating a colour per mark per frame is exactly the cost the
    --- category palette is pre-built to avoid.
    ---@param quest table
    ---@return color
    function M.quest_color(quest)
        local cached = quest.color
        if cached then return cached end
        local palette = P.cfg.QUEST_PALETTE
        local rgb = palette[((quest.color_index or 1) - 1) % #palette + 1]
        cached = P.color(rgb[1], rgb[2], rgb[3])
        quest.color = cached
        return cached
    end

    --- Every tracked quest, in quest-log order.
    ---@return table[]
    function M.tracked()
        local out = {}
        for i = 1, #index.order do
            local quest = index.quests[index.order[i]]
            if quest then out[#out + 1] = quest end
        end
        return out
    end

    -- --- RestedXP -----------------------------------------------------------

    -- Guide state, refreshed on a timer. Each getter crosses into the addon,
    -- so a per-frame read would be several addon round trips per frame for
    -- data that changes a few times a minute.
    local rxp = {
        loaded = false,
        step = nil,
        stickies = {},
        waypoint = nil,
        targets = {},       -- M.guide_key(goal text) -> { text, action }
        memo = {},          -- unit name -> goal | false, until the next refresh
        target_ids = {},    -- quest id -> true (a multi-quest goal's ids; never matched against a unit)
        objectives = {},    -- flattened { text, num_fulfilled, num_required, finished }
        world_waypoint = nil,
        step_waypoints = {},-- { raw = waypoint, world = vec3 } for the whole step
    }

    M.rxp = rxp

    -- --- ground sampling ----------------------------------------------------
    --
    -- WHY THIS IS NOT ONE HEIGHT QUERY
    --
    -- core.get_height_for_position takes a position and answers a surface
    -- height near it. Under a tent, on a bridge, beside a cliff or inside a
    -- building, "near it" can be the ROOF rather than the floor; when the
    -- query cannot answer at all it returns zero, and the old code then fell
    -- back to the player's own height. Those two failures are the same
    -- symptom -- a waypoint marker hanging in the air, or buried -- and they
    -- happen exactly where the ground is interesting.
    --
    -- A height is therefore only accepted when it is a plausible CONTINUATION
    -- of the height already established. Ground does not move twelve yards in
    -- a six-yard step; a roof does. Walking outward and carrying the last good
    -- height forward as the reference turns one unreliable query into a chain
    -- where every answer is checked against the one before it, and a sample
    -- that cannot be checked holds the previous height instead of inventing
    -- one.

    local GROUND_STEP = 6         -- yards between samples along a path
    local MAX_GROUND_STEP = 12    -- height change tolerated between samples

    -- HEIGHT QUERIES ARE RATIONED. get_height_for_position is a terrain trace
    -- into the client, and nothing bounds how many a frame used to make: a
    -- fresh path is three probes per point, twenty points per path, up to
    -- four quest paths plus the guide's waypoint -- three hundred traces in
    -- the one frame after a zone change, after the cell cache filled up, or
    -- whenever a new quest target appeared, and a steady trickle every frame
    -- while moving. This many is allowed per frame; a point that misses the
    -- budget holds the previous height for this frame and is sampled on a
    -- later one, so a path arrives over a few frames instead of stalling one.
    local GROUND_PROBE_BUDGET = 30
    local probes_left = GROUND_PROBE_BUDGET

    --- Ground height at a point, or nil when nothing plausible came back.
    ---@param x number
    ---@param y number
    ---@param reference_z number The height this point is expected to be near.
    ---@param tolerance? number
    ---@return number|nil
    local function sample_ground(x, y, reference_z, tolerance)
        local best, best_delta

        -- Three probes: just above the reference, well above it, and below it.
        -- Which one lands on the real floor depends on whether the reference
        -- is currently under something, which is not knowable in advance.
        local probes = { reference_z + 2, reference_z + 30, reference_z - 20 }
        for i = 1, #probes do
            probes_left = probes_left - 1
            local ok, height = pcall(core.get_height_for_position,
                { x = x, y = y, z = probes[i] })
            if ok and type(height) == "number" and height ~= 0 then
                local delta = math.abs(height - reference_z)
                if not best or delta < best_delta then
                    best, best_delta = height, delta
                end
            end
        end

        if best and best_delta <= (tolerance or MAX_GROUND_STEP) then return best end
        return nil
    end

    M.sample_ground = sample_ground

    -- Three probes per sample, ten samples per path, one path per quest, every
    -- frame: that is a hundred and fifty native height queries a frame for
    -- ground that has not moved since the zone loaded. So the answers are kept
    -- per four-yard cell, and a path crossing ground it has already walked
    -- costs table lookups. A moving player adds a cell or two a frame.
    --
    -- The trade: a cell keeps whichever answer it was first given, so a cell
    -- first sampled from under a roof keeps the roof until the zone changes.
    -- That is a mark a few yards high on one cell, against the alternative of
    -- paying for the whole path every frame -- and the neighbouring cells,
    -- sampled from their own references, pull the line back down either side.
    local GROUND_CELL = 4
    local ground_cache = {}
    local ground_cells = 0
    local GROUND_CACHE_MAX = 4096

    ctx.on("jcore.zone.changed", function()
        ground_cache = {}
        ground_cells = 0
    end)

    ---@param x number
    ---@param y number
    ---@param reference_z number
    ---@param tolerance? number
    ---@return number|nil
    local function cached_ground(x, y, reference_z, tolerance)
        local key = math.floor(x / GROUND_CELL) .. ":" .. math.floor(y / GROUND_CELL)
        local hit = ground_cache[key]
        if hit ~= nil then
            if hit == false then return nil end
            return hit
        end

        -- Over budget for this frame: answer nothing and cache nothing, so
        -- the caller carries its reference height and this cell is sampled
        -- on a later frame instead.
        if probes_left < 3 then return nil end

        local z = sample_ground(x, y, reference_z, tolerance)

        if ground_cells >= GROUND_CACHE_MAX then
            ground_cache = {}
            ground_cells = 0
        end
        -- A miss is cached too, as false. Ground that could not be sampled
        -- once will not sample any better sixty times a second.
        ground_cache[key] = z or false
        ground_cells = ground_cells + 1
        return z
    end

    --- Points from `from` towards `to` that follow the ground.
    ---
    --- Returns the points, the true flat distance, and how much of it the path
    --- actually covers -- which is less whenever `max_length` cut it short.
    ---@param from vec3
    ---@param to vec3
    ---@param max_length? number
    ---@return vec3[]|nil points
    ---@return number flat_distance
    local function ground_path(from, to, max_length)
        if not from or not to then return nil, 0 end

        local dx, dy = to.x - from.x, to.y - from.y
        local flat = math.sqrt(dx * dx + dy * dy)
        if flat < 1 then return nil, flat end

        local drawn = math.min(flat, max_length or flat)
        local segments = math.max(2, math.floor(drawn / GROUND_STEP))

        local points = { from }
        local reference = from.z

        for i = 1, segments do
            local t = (i / segments) * (drawn / flat)
            local x = from.x + dx * t
            local y = from.y + dy * t
            -- Tolerance grows with the step, because a path drawn across a
            -- long distance takes longer strides and real ground can climb
            -- faster than the per-sample limit over one of them.
            local z = cached_ground(x, y, reference, MAX_GROUND_STEP + drawn / segments)
            if z then reference = z end
            points[#points + 1] = { x = x, y = y, z = z or reference }
        end

        return points, flat, drawn
    end

    M.ground_path = ground_path

    -- THE CLASSIC FAMILY'S ZONE MAPS (2026-10-10). Era and Forever number
    -- their zone maps 1411-1458, not the retail ids AREA_TO_MAP seeds below:
    -- read from both clients' own UiMap tables (Forever 1.60.1.70291, Era
    -- 1.15.9.70003), where 37 and 52 do not exist -- and Forever answers
    -- {0, 0} for them (the recorder: maps 49 and 52, every call). Map id ->
    -- { name, continent (0 the Eastern Kingdoms, 1 Kalimdor), AreaTable id }.
    local CLASSIC_MAPS = {
        [1411] = { "Durotar", 1, 14 },               [1412] = { "Mulgore", 1, 215 },
        [1413] = { "The Barrens", 1, 17 },           [1416] = { "Alterac Mountains", 0, 36 },
        [1417] = { "Arathi Highlands", 0, 45 },      [1418] = { "Badlands", 0, 3 },
        [1419] = { "Blasted Lands", 0, 4 },          [1420] = { "Tirisfal Glades", 0, 85 },
        [1421] = { "Silverpine Forest", 0, 130 },    [1422] = { "Western Plaguelands", 0, 28 },
        [1423] = { "Eastern Plaguelands", 0, 139 },  [1424] = { "Hillsbrad Foothills", 0, 267 },
        [1425] = { "The Hinterlands", 0, 47 },       [1426] = { "Dun Morogh", 0, 1 },
        [1427] = { "Searing Gorge", 0, 51 },         [1428] = { "Burning Steppes", 0, 46 },
        [1429] = { "Elwynn Forest", 0, 12 },         [1430] = { "Deadwind Pass", 0, 41 },
        [1431] = { "Duskwood", 0, 10 },              [1432] = { "Loch Modan", 0, 38 },
        [1433] = { "Redridge Mountains", 0, 44 },    [1434] = { "Stranglethorn Vale", 0, 33 },
        [1435] = { "Swamp of Sorrows", 0, 8 },       [1436] = { "Westfall", 0, 40 },
        [1437] = { "Wetlands", 0, 11 },              [1438] = { "Teldrassil", 1, 141 },
        [1439] = { "Darkshore", 1, 148 },            [1440] = { "Ashenvale", 1, 331 },
        [1441] = { "Thousand Needles", 1, 400 },     [1442] = { "Stonetalon Mountains", 1, 406 },
        [1443] = { "Desolace", 1, 405 },             [1444] = { "Feralas", 1, 357 },
        [1445] = { "Dustwallow Marsh", 1, 15 },      [1446] = { "Tanaris", 1, 440 },
        [1447] = { "Azshara", 1, 16 },               [1448] = { "Felwood", 1, 361 },
        [1449] = { "Un'Goro Crater", 1, 490 },       [1450] = { "Moonglade", 1, 493 },
        [1451] = { "Silithus", 1, 1377 },            [1452] = { "Winterspring", 1, 618 },
        [1453] = { "Stormwind City", 0, 1519 },      [1454] = { "Orgrimmar", 1, 1637 },
        [1455] = { "Ironforge", 0, 1537 },           [1456] = { "Thunder Bluff", 1, 1638 },
        [1457] = { "Darnassus", 1, 1657 },           [1458] = { "Undercity", 0, 1497 },
    }

    local CONTINENT_NAMES = { [0] = "the Eastern Kingdoms", [1] = "Kalimdor", [530] = "Outland", [571] = "Northrend" }

    --- The continent (instance map id) you stand on, or nil when the client
    --- does not say. 0 is the Eastern Kingdoms, 1 Kalimdor; in a dungeon it
    --- is the dungeon's map.
    local function here_continent()
        local world = ctx.world
        if type(world) == "table" and type(world.instance_id) == "function" then
            local ok, id = pcall(world.instance_id)
            if ok and type(id) == "number" then return id end
        end
        local fn = type(core) == "table" and core.get_instance_id or nil
        if type(fn) == "function" then
            local ok, id = pcall(fn)
            if ok and type(id) == "number" then return id end
        end
        return nil
    end

    --- Converts a RestedXP waypoint (map id + normalized map coords) into a
    --- world position.
    ---
    --- get_world_pos_from_map_pos answers a vec2 -- world x and y with no
    --- height, which the doc comment says outright -- so the z has to come
    --- from a separate terrain query. Without that second step the line would
    --- be drawn at z = 0, which is under the map almost everywhere.
    ---
    --- The z here is a FIRST GUESS and is allowed to be wrong: the path drawn
    --- to it re-samples the ground the whole way out and ends on a height that
    --- was checked against its neighbours. Anything that needs the waypoint's
    --- real height should take the last point of that path.
    ---
    --- NOT ON THIS CONTINENT: nil, and why. World x and y are per continent,
    --- so a Darkshore waypoint read in Stormwind converts to a spot that is
    --- nowhere you can walk. In game (2026-10-10, Forever) the guide walk set
    --- off on Sentinel from Stormwind for "(15210 yd)": RestedXP's waypoint
    --- was map 1439 at 0.3721, 0.4422, the conversion answered x 6402,
    --- y 504.4 on continent 1, and the waypoint itself did not say
    --- wrong_continent. So the continent the conversion answers is checked
    --- against yours, and RestedXP's own distance against ours.
    ---@return vec3|nil world
    ---@return table|nil away { why = "continent"|"distance", continent?, ours?, theirs? }
    local function waypoint_to_world(wp)
        if not wp or not wp.map_id or wp.map_id == 0 then return nil end
        local known = CLASSIC_MAPS[wp.map_id]
        if wp.wrong_continent then return nil, { why = "continent", continent = known and known[2] } end

        -- The namespace is read before pcall runs, so resolve it first (an
        -- index inside pcall's argument list is not protected).
        local ui = type(core.game_ui) == "table" and core.game_ui or nil
        local to_world = ui and ui.get_world_pos_from_map_pos
        if type(to_world) ~= "function" then return nil end
        local ok, flat, continent = pcall(to_world, wp.map_id, { x = wp.x, y = wp.y })
        if not ok or type(flat) ~= "table" or not flat.x or not flat.y then return nil end
        -- Zero is what the call answers for a map it cannot place.
        if flat.x == 0 and flat.y == 0 then return nil end

        -- A known map's continent is the client's UiMap table's; else the
        -- call's, whose 0 also means "not known" and is only taken from a
        -- map this table names.
        local there = known and known[2] or tonumber(continent)
        if there == 0 and not known then there = nil end
        local here = here_continent()
        if here and there and there ~= here then return nil, { why = "continent", continent = there } end

        local player_pos = units.player_position()
        local probe_z = player_pos and player_pos.z or 0

        -- RestedXP measures the same distance (0 when it cannot). Ours off
        -- by more than its own size and 200 yd is a conversion gone wrong.
        local theirs = tonumber(wp.dist) or 0
        if player_pos and theirs >= 1 then
            local dx, dy = flat.x - player_pos.x, flat.y - player_pos.y
            local ours = math.sqrt(dx * dx + dy * dy)
            if math.abs(ours - theirs) > math.max(200, theirs) then
                return nil, { why = "distance", ours = ours, theirs = theirs }
            end
        end

        -- A distant waypoint can legitimately be far above or below you, so
        -- the tolerance here is wide. The path is what tightens it.
        local height = sample_ground(flat.x, flat.y, probe_z, 500)

        return { x = flat.x, y = flat.y, z = height or probe_z }
    end

    M.waypoint_to_world = waypoint_to_world

    --- What to say about a waypoint that cannot be walked or drawn: where
    --- it is, by the map's name when this table knows it.
    local function describe_away(wp, away)
        local known = CLASSIC_MAPS[wp.map_id]
        local zone = known and known[1] or nil
        local title = (type(wp.title) == "string" and wp.title ~= "") and wp.title or nil
        local out = { why = away.why, zone = zone, title = title, map_id = wp.map_id }
        if away.why == "continent" then
            out.continent = away.continent and CONTINENT_NAMES[away.continent] or nil
            out.here = CONTINENT_NAMES[here_continent() or -1]
            local where = zone or title or ("map " .. tostring(wp.map_id))
            out.text = where .. (out.continent and (", on " .. out.continent) or ", on another continent")
        else
            out.text = string.format("%s: RestedXP says %.0f yd, the map says %.0f yd",
                zone or title or ("map " .. tostring(wp.map_id)), away.theirs or 0, away.ours or 0)
        end
        return out
    end

    local function refresh_rxp()
        -- The guide walk (1.7.4, modules/guidewalk.lua) reads the guide too,
        -- with the RestedXP marks switched off or on.
        if not P.opt("rxp_on", true) and not P.opt("rxp_follow", false) then
            rxp.loaded = false
            return
        end

        local rested = bridge("rested_xp")
        if not rested then
            rxp.loaded = false
            return
        end

        local ok, loaded = pcall(rested.is_loaded)
        rxp.loaded = ok and loaded or false
        if not rxp.loaded then return end

        local ok_step, step = pcall(rested.get_current_step)
        rxp.step = (ok_step and type(step) == "table") and step or nil

        local ok_sticky, stickies = pcall(rested.get_current_stickies)
        rxp.stickies = (ok_sticky and type(stickies) == "table") and stickies or {}

        local ok_wp, waypoint = pcall(rested.get_current_waypoint)
        -- "None" is a zero-valued waypoint (map 0), and 0 is true in Lua.
        rxp.waypoint = (ok_wp and type(waypoint) == "table" and (tonumber(waypoint.map_id) or 0) ~= 0) and waypoint
            or nil
        rxp.world_waypoint, rxp.waypoint_away = nil, nil
        if rxp.waypoint then
            local world, away = waypoint_to_world(rxp.waypoint)
            rxp.world_waypoint = world
            if away then
                rxp.waypoint_away = describe_away(rxp.waypoint, away)
                -- Said once per waypoint, in the log and the trace.
                local key = tostring(rxp.waypoint.map_id) .. ":" .. tostring(rxp.waypoint.x) .. ":"
                    .. tostring(rxp.waypoint.y)
                if key ~= rxp.away_said then
                    rxp.away_said = key
                    local line = "guide waypoint not walked or drawn: " .. rxp.waypoint_away.text
                        .. (rxp.waypoint_away.here and (" (you are in " .. rxp.waypoint_away.here .. ")") or "")
                    log.fmt("info", "%s", line)
                    if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", line) end
                end
            end
        end

        -- A step can have several stops. Converting them here rather than per
        -- frame matters: each conversion is a map-to-world call plus the
        -- ground probes behind it.
        local step_waypoints = {}
        local ok_wps, list = pcall(rested.get_step_waypoints)
        if ok_wps and type(list) == "table" then
            for i = 1, #list do
                local wp = list[i]
                if type(wp) == "table" and wp.map_id and wp.map_id ~= 0 then
                    local world = waypoint_to_world(wp)
                    if world then
                        step_waypoints[#step_waypoints + 1] = { raw = wp, world = world }
                    end
                end
            end
        end
        rxp.step_waypoints = step_waypoints

        -- Flatten every goal across the current step and its stickies into one
        -- target set, plus the objective progress for each quest goal.
        local targets, target_ids, objectives = {}, {}, {}
        -- Quests the guide names that you are not on yet. Their quest givers
        -- are worth marking: "go and pick this up" is a step like any other.
        local wanted_quests = {}

        local function absorb(s)
            if type(s) ~= "table" or type(s.goals) ~= "table" then return end
            for i = 1, #s.goals do
                local goal = s.goals[i]
                if type(goal) == "table" then
                    -- Kept as the goal itself, not `true`, so a mark can say
                    -- WHAT the guide wants with the thing it matched.
                    if type(goal.text) == "string" and goal.text ~= "" then
                        targets[M.guide_key(goal.text)] = {
                            text = goal.text,
                            action = type(goal.action) == "string" and goal.action or nil,
                        }
                    end
                    if type(goal.quest_id) == "number" and goal.quest_id > 0 then
                        if goal.action == "accept" then
                            wanted_quests[goal.quest_id] = true
                        else
                            -- Any other goal is about a quest you hold. On
                            -- Forever that is how the tracked log learns of
                            -- it without Questie; elsewhere it is a no-op.
                            questlog.consider(goal.quest_id)
                        end
                        local ok_obj, list = pcall(rested.get_objectives, goal.quest_id)
                        if ok_obj and type(list) == "table" then
                            for j = 1, #list do
                                local o = list[j]
                                if type(o) == "table" and o.text then
                                    objectives[#objectives + 1] = {
                                        text = o.text,
                                        have = o.num_fulfilled or 0,
                                        need = o.num_required or 0,
                                        finished = o.finished and true or false,
                                        action = goal.action,
                                    }
                                end
                            end
                        end
                    end
                    if type(goal.ids) == "table" then
                        for j = 1, #goal.ids do
                            if type(goal.ids[j]) == "number" then
                                target_ids[goal.ids[j]] = true
                            end
                        end
                    end
                end
            end
        end

        absorb(rxp.step)
        for i = 1, #rxp.stickies do absorb(rxp.stickies[i]) end

        rxp.targets = targets
        rxp.target_ids = target_ids
        rxp.memo = {}
        rxp.objectives = objectives

        -- A quest the guide is sending you to pick up is not in the log yet,
        -- so the index has never heard of it. Its quest giver is exactly the
        -- npc you are walking towards.
        if next(wanted_quests) then
            index_guide_givers(wanted_quests)
        end
    end

    ctx.every(1.0, refresh_rxp)
    refresh_rxp()

    --- Does this unit or object match something the guide currently wants?
    ---
    --- RestedXP goals are TEXT -- a quest name, an NPC name, an item name --
    --- so the name is the signal: the goal's whole text, or the name as a word
    --- inside it, because a goal reads "Kill 8 Mangy Wolves" while the unit is
    --- a "Mangy Wolf".
    ---
    --- NOT BY ID. A goal's `ids` are QUEST ids (the contract's
    --- rested_xp_goal_info), and this used to compare them against the
    --- unit's NPC id -- so any npc whose id happened to equal a quest id in
    --- the current step was marked "guide". `known_id` is accepted and
    --- ignored, for the callers that pass it.
    ---@param obj game_object
    ---@param name string
    ---@param known_id? integer Unused; see above.
    ---@return boolean matched
    ---@return table|nil goal { text, action } -- what the guide wants with it
    function M.is_guide_target(obj, name, known_id)
        if not rxp.loaded then return false, nil end
        -- Read for the guide walk alone (1.7.4): the marks stay off.
        if not P.opt("rxp_on", true) then return false, nil end
        return M.guide_goal(name)
    end

    --- The guide goal a name matches, or false: is_guide_target without the
    --- RestedXP marks' switch, for the guide walk.
    ---@param name string
    ---@return boolean matched
    ---@return table|nil goal { text, action }
    function M.guide_goal(name)
        if not rxp.loaded then return false, nil end
        if not name or #name < MIN_GUIDE_NAME then return false, nil end

        -- Asked for every unit, every frame, and the answer only changes
        -- when the guide does: remembered per name until the next refresh.
        local memo = rxp.memo
        local known = memo[name]
        if known ~= nil then
            if known then return true, known end
            return false, nil
        end

        local key = M.guide_key(name)
        local found = rxp.targets[key]
        if not found then
            for goal_key, goal in pairs(rxp.targets) do
                if word_in(goal_key, key) then
                    found = goal
                    break
                end
            end
        end
        memo[name] = found or false
        if found then return true, found end
        return false, nil
    end

    -- --- waypoint line ------------------------------------------------------

    -- The empty part of a full ring: never seen, and nothing extra drawn
    -- when ring_3d has no shader and lays the band down as an outline.
    local clear_band = P.color and P.color(0, 0, 0, 0) or nil

    --- One ground-following path, its end ring and its label.
    ---
    --- Dashed by default. With several of these on screen at once -- one per
    --- quest -- solid lines read as a net; dashes stay legible because the eye
    --- follows the rhythm rather than the line.
    ---@param to vec3
    ---@param col color
    ---@param label? string
    ---@param opts? { max_length?: number, dash?: number, thickness?: number, ring?: number }
    ---@return boolean drawn
    local function draw_path_to(to, col, label, opts)
        opts = opts or {}

        local from = units.player_position()
        if not from or not to then return false end

        local points, flat_distance, drawn_length = ground_path(from, to,
            opts.max_length or P.opt("rxp_line_length", 60))
        if not points then return false end

        -- A path that had to stop short did not arrive anywhere, so it gets no
        -- ring: a circle drawn in the middle of empty ground says "it is here"
        -- about a place nothing is. The label carries the real distance.
        local reached = (drawn_length or flat_distance) >= flat_distance - 0.5

        local dash = opts.dash
        draw.path_3d(points, col, {
            layer = ctx.LAYER.WORLD,
            thickness = opts.thickness or 2.5,
            dash = dash,
            gap = dash and dash * 0.7 or nil,
        })

        -- The end ring is JCore's shader ring_3d where it has one (1.88.0,
        -- the user: "Ground rings"): a thin band, full all the way round.
        local last = points[#points]
        if reached and opts.ring ~= false then
            if draw.ring_3d then
                draw.ring_3d(last, opts.ring or 1.5, 1, col,
                    { bg = clear_band or col, inner = 0.86, outer = 1.0, layer = ctx.LAYER.WORLD })
            else
                draw.circle_3d(last, opts.ring or 1.5, col,
                    { layer = ctx.LAYER.WORLD, thickness = 2 })
            end
        end

        -- A label on a live target belongs on the TARGET, where the mark
        -- already is, not floating at the end of the line. Only a path to a
        -- place -- a waypoint -- labels its own end.
        if label and label ~= "" then
            draw.text_3d({ x = last.x, y = last.y, z = last.z + 1.6 },
                string.format("%s  (%.0fy)", label, flat_distance),
                col, { layer = ctx.LAYER.OVERLAY, size = P.opt("text_size", 13) })
        end
        return true
    end

    M.draw_path_to = draw_path_to

    --- The guide's waypoints. The current one always; every waypoint of the
    --- step when asked, because a step with four stops used to draw one line
    --- and leave the other three invisible.
    --- The guide's waypoint, drawn only when there is nothing alive to point
    --- at instead.
    ---
    --- A waypoint is a MAP COORDINATE: a spot where the thing you want is
    --- supposed to be. A path to it is worth drawing when you are still on
    --- your way and cannot see anything yet. The moment the mob that drops
    --- the item is actually on screen, that same path is a line to a patch of
    --- empty ground next to it, and the live path to the mob -- which moves
    --- when the mob moves -- is strictly better. So live wins, always.
    ---
    --- Every stop in the step used to be drawn at once. A step with eight
    --- stops is eight dashed lines radiating off to nowhere, all clipped at
    --- the line length, none of them attached to anything you can see.
    ---@param live_paths integer How many live target paths were just drawn.
    local function draw_waypoint_lines(live_paths)
        if not P.opt("rxp_on", true) then return end
        if not P.opt("rxp_line", true) then return end
        if not rxp.loaded then return end

        if live_paths > 0 and P.opt("quest_paths_prefer_live", true) then return end

        local col = P.category_color.guide or draw.theme.accent
        local label_on = P.opt("rxp_waypoint_label", true)
        local dash = P.opt("quest_line_dashed", true) and 2.5 or nil

        if rxp.world_waypoint then
            local title = rxp.waypoint and rxp.waypoint.title
            if type(title) ~= "string" or title == "" then
                local known = rxp.waypoint and CLASSIC_MAPS[rxp.waypoint.map_id]
                title = known and known[1] or nil
            end
            draw_path_to(rxp.world_waypoint, col, label_on and title or nil, { dash = dash })
        end

        if not P.opt("rxp_all_waypoints", false) then return end

        local current = rxp.waypoint
        local drawn = 0
        local limit = P.opt("rxp_max_waypoints", 3)

        for i = 1, #rxp.step_waypoints do
            if drawn >= limit then break end
            local wp = rxp.step_waypoints[i]
            -- The current waypoint is drawn above, at full strength. Skip it
            -- here rather than painting it twice at two thicknesses.
            local is_current = current and wp.raw
                and wp.raw.x == current.x and wp.raw.y == current.y
                and wp.raw.map_id == current.map_id
            if wp.world and not is_current then
                drawn = drawn + 1
                draw_path_to(wp.world, P.faded(col, 40, 60),
                    label_on and wp.raw and wp.raw.title or nil,
                    { dash = dash, thickness = 1.6, ring = 1.0 })
            end
        end
    end

    -- --- the guide walk's route ----------------------------------------------
    --
    -- WHERE IT IS TAKING YOU (2026-10-10; the user: "ensure its giving ESP
    -- Pathing to wheres its suppose to go and that sentinel works"). While
    -- the guide walk (modules/guidewalk.lua) moves you, its line takes the
    -- guide's place: to what it is walking to -- the npc, the mob, the
    -- corpse or the waypoint -- along Sentinel's own path while Sentinel
    -- walks it, round the walls it will go round. Solid, so it is not read
    -- as the guide's dashed straight line. Without a path of Sentinel's (a
    -- straight walk, a route not planned yet) it is the ground line straight
    -- at it.

    --- The first point of `path` still ahead of `from`: the end of the leg
    --- you are nearest. The legs behind you are walked.
    local function route_start(path, from)
        local n = #path
        if n < 2 then return 1 end
        local best_i, best_d = 1, math.huge
        for i = 1, n - 1 do
            local a, b = path[i], path[i + 1]
            local ax, ay = a.x, a.y
            local dx, dy = b.x - ax, b.y - ay
            local len2 = dx * dx + dy * dy
            local k = len2 > 0 and ((from.x - ax) * dx + (from.y - ay) * dy) / len2 or 0
            if k < 0 then k = 0 elseif k > 1 then k = 1 end
            local px, py = ax + dx * k - from.x, ay + dy * k - from.y
            local d = px * px + py * py
            if d < best_d then best_i, best_d = i, d end
        end
        return best_i + 1
    end

    ---@return boolean drawn
    local function draw_walk_route()
        if not P.opt("rxp_follow_route", true) then return false end
        local walk = P.guidewalk
        local ok, route = pcall(function() return walk and walk.route and walk.route() or nil end)
        if not ok or type(route) ~= "table" or not route.goal then return false end
        local col = P.category_color.guide or draw.theme.accent
        local label = (type(route.label) == "string" and route.label ~= "") and route.label or nil
        local path = route.path
        if type(path) ~= "table" or #path == 0 then
            return draw_path_to(route.goal, col, label, { thickness = 3 })
        end

        local from = units.player_position()
        if not from then return false end
        local max_length = P.opt("rxp_line_length", 60)
        local points, length, total = { from }, 0, 0
        local prev = from
        for i = route_start(path, from), #path do
            local p = path[i]
            local dx, dy = p.x - prev.x, p.y - prev.y
            local seg = math.sqrt(dx * dx + dy * dy)
            local pz = p.z or prev.z
            if length < max_length and seg > 0 then
                if length + seg > max_length then
                    local k = (max_length - length) / seg
                    points[#points + 1] = { x = prev.x + dx * k, y = prev.y + dy * k, z = prev.z + (pz - prev.z) * k }
                    length = max_length
                else
                    points[#points + 1] = { x = p.x, y = p.y, z = pz }
                    length = length + seg
                end
            end
            total = total + seg
            prev = { x = p.x, y = p.y, z = pz }
        end
        if #points < 2 then return false end

        draw.path_3d(points, col, { layer = ctx.LAYER.WORLD, thickness = 3 })
        local last = points[#points]
        if length >= total - 0.5 then
            if draw.ring_3d then
                draw.ring_3d(last, 1.5, 1, col,
                    { bg = clear_band or col, inner = 0.86, outer = 1.0, layer = ctx.LAYER.WORLD })
            else
                draw.circle_3d(last, 1.5, col, { layer = ctx.LAYER.WORLD, thickness = 2 })
            end
        end
        if label then
            -- The distance along the route, not the straight line.
            draw.text_3d({ x = last.x, y = last.y, z = last.z + 1.6 },
                string.format("%s  (%.0fy)", label, total),
                col, { layer = ctx.LAYER.OVERLAY, size = P.opt("text_size", 13) })
        end
        return true
    end

    M.draw_walk_route = draw_walk_route

    -- --- quest target spawns ------------------------------------------------
    --
    -- Where a quest's targets ARE when none of them is on screen. Questie's
    -- database records every spawn of every quest npc and object, as
    -- percentages of a zone map keyed by AREA id (the client's AreaTable),
    -- while the map API converts coordinates on a UiMapID. The two id spaces
    -- are unrelated, and the client answers no area id at all.
    --
    -- So the bridge between them is a seed table of the classic zones,
    -- CHECKED before it is trusted: the npcs actually on screen answer their
    -- home zone from the same database, and a mapping is accepted only once
    -- one of those npcs' recorded spawns, converted through it, lands within
    -- a few hundred yards of where the npc actually stands. A zone the seed
    -- does not know is learned the same way, from the map id the client is
    -- showing. Walking through a zone teaches it.

    -- Classic AreaTable id -> UiMapID. Kalimdor and the Eastern Kingdoms;
    -- cities included because turn-ins live there.
    local AREA_TO_MAP = {
        -- Eastern Kingdoms
        [1] = 27,     -- Dun Morogh
        [3] = 17,     -- Badlands
        [4] = 19,     -- Blasted Lands
        [8] = 51,     -- Swamp of Sorrows
        [10] = 47,    -- Duskwood
        [11] = 56,    -- Wetlands
        [12] = 37,    -- Elwynn Forest
        [28] = 22,    -- Western Plaguelands
        [33] = 50,    -- Stranglethorn Vale
        [36] = 15,    -- Alterac Mountains
        [38] = 48,    -- Loch Modan
        [40] = 52,    -- Westfall
        [41] = 42,    -- Deadwind Pass
        [44] = 49,    -- Redridge Mountains
        [45] = 14,    -- Arathi Highlands
        [46] = 36,    -- Burning Steppes
        [47] = 26,    -- The Hinterlands
        [51] = 32,    -- Searing Gorge
        [85] = 18,    -- Tirisfal Glades
        [130] = 21,   -- Silverpine Forest
        [139] = 23,   -- Eastern Plaguelands
        [267] = 25,   -- Hillsbrad Foothills
        [1497] = 90,  -- Undercity
        [1519] = 84,  -- Stormwind City
        [1537] = 87,  -- Ironforge
        -- Kalimdor
        [14] = 1,     -- Durotar
        [15] = 70,    -- Dustwallow Marsh
        [16] = 76,    -- Azshara
        [17] = 10,    -- The Barrens
        [141] = 57,   -- Teldrassil
        [148] = 62,   -- Darkshore
        [215] = 7,    -- Mulgore
        [331] = 63,   -- Ashenvale
        [357] = 69,   -- Feralas
        [361] = 77,   -- Felwood
        [400] = 64,   -- Thousand Needles
        [405] = 66,   -- Desolace
        [406] = 65,   -- Stonetalon Mountains
        [440] = 71,   -- Tanaris
        [490] = 78,   -- Un'Goro Crater
        [493] = 80,   -- Moonglade
        [618] = 83,   -- Winterspring
        [1377] = 81,  -- Silithus
        [1637] = 85,  -- Orgrimmar
        [1638] = 88,  -- Thunder Bluff
        [1657] = 89,  -- Darnassus
    }

    -- Era ("Vanilla") and Forever seed from their own map ids (CLASSIC_MAPS,
    -- read from their clients): AREA_TO_MAP's retail ids do not exist there,
    -- so before this every spawn waited for its zone to be learned on the spot.
    local SEED = AREA_TO_MAP
    if P.client_version == "Vanilla" or P.client_version == "Forever" or P.forever then
        SEED = {}
        for map_id, row in pairs(CLASSIC_MAPS) do SEED[row[3]] = map_id end
    end

    local area_map = {}        -- area id -> UiMapID, verified this session
    local area_rejected = {}   -- area id -> UiMapID that failed the check
    local area_version = 0     -- bumped whenever a mapping is accepted
    local npc_zone = {}        -- npc id -> area id | false

    -- A spawn converted through the wrong map lands on the wrong continent
    -- or the far side of this one. Within this of the live npc is a match.
    local VERIFY_YARDS = 300

    --- The map API, or nil on a build without it. Read per call, never
    --- cached: a pcall does not protect the index that names its function.
    local function map_api(field)
        local ui = type(core.game_ui) == "table" and core.game_ui or nil
        local fn = ui and ui[field]
        return type(fn) == "function" and fn or nil
    end

    --- Questie percentages on an area's map -> world x/y, or nil.
    ---@param map_id integer UiMapID
    ---@param x number 0..100
    ---@param y number 0..100
    ---@return table|nil { x, y }
    local function map_to_world(map_id, x, y)
        local to_world = map_api("get_world_pos_from_map_pos")
        if not to_world then return nil end
        local ok, flat = pcall(to_world, map_id, { x = x / 100, y = y / 100 })
        if not ok or type(flat) ~= "table" or not flat.x or not flat.y then return nil end
        -- Zero is what the call answers for a map it cannot place.
        if flat.x == 0 and flat.y == 0 then return nil end
        return { x = flat.x, y = flat.y }
    end

    --- Raw spawn rows for an npc or object: { area, x, y } each, from
    --- Questie. Instance spawns are recorded as -1 and dropped.
    ---@param kind "n"|"o"
    ---@param id integer
    ---@return table[]
    local function raw_spawns(kind, id)
        local questie = bridge("questie")
        if not questie then return {} end
        local query = kind == "o" and questie.query_object_single or questie.query_npc_single
        local ok, spawns = pcall(query, id, "spawns")
        if not ok or type(spawns) ~= "table" then return {} end

        local out = {}
        for area, list in pairs(spawns) do
            if type(area) == "number" and type(list) == "table" then
                for i = 1, #list do
                    local p = list[i]
                    if type(p) == "table" then
                        local x, y = p[1], p[2]
                        if type(x) == "number" and type(y) == "number"
                            and x >= 0 and y >= 0 and x <= 100 and y <= 100 then
                            out[#out + 1] = { area, x, y }
                        end
                    end
                end
            end
        end
        return out
    end

    --- Does converting `area` through `map_id` put one of `unit`'s spawns
    --- near where the unit actually is?
    ---@return boolean|nil verdict nil when the unit has no spawn in that area
    local function verify_area(area, map_id, npc_id, live_pos)
        local rows = raw_spawns("n", npc_id)
        local any = false
        for i = 1, #rows do
            local row = rows[i]
            if row[1] == area then
                any = true
                local world = map_to_world(map_id, row[2], row[3])
                if world then
                    local dx, dy = world.x - live_pos.x, world.y - live_pos.y
                    if dx * dx + dy * dy <= VERIFY_YARDS * VERIFY_YARDS then
                        return true
                    end
                end
            end
        end
        if not any then return nil end
        return false
    end

    -- How many zone lookups a learning pass may make. Each is a database
    -- query into the addon, and the answer for an npc id never changes.
    local LEARN_QUERIES = 4

    --- Works out which area the current map shows, from the npcs on screen,
    --- and verifies or learns the mapping for it.
    local function learn_current_zone()
        if not P.opt("quest_spawn_paths", true) then return end
        if not P.esp then return end

        local questie = bridge("questie")
        if not questie then return end
        if select(2, pcall(questie.is_ready)) ~= true then return end

        local get_map = map_api("get_current_map_id")
        if not get_map then return end
        local ok, map_id = pcall(get_map)
        if not ok or type(map_id) ~= "number" or map_id <= 0 then return end

        -- Tally the home zones of the npcs on screen. The one most of them
        -- agree on is the zone the current map id shows; the minority are
        -- mobs standing near a border.
        local entities = P.esp.entities()
        local n = P.esp.count()
        local votes, total, queries = {}, 0, 0
        local witness = {}   -- area -> an entity standing in it

        for i = 1, n do
            local e = entities[i]
            local info = e.info
            local id = e.kind == "unit" and info and not info.is_player and info.npc_id
            if type(id) == "number" and id > 0 then
                local zone = npc_zone[id]
                if zone == nil and queries < LEARN_QUERIES then
                    queries = queries + 1
                    local ok_z, z = pcall(questie.query_npc_single, id, "zoneID")
                    zone = (ok_z and type(z) == "number" and z > 0) and z or false
                    npc_zone[id] = zone
                end
                if zone then
                    votes[zone] = (votes[zone] or 0) + 1
                    total = total + 1
                    witness[zone] = witness[zone] or e
                end
            end
        end

        local area, best = nil, 0
        for zone, count in pairs(votes) do
            if count > best then area, best = zone, count end
        end
        if not area or best < 3 or best * 3 < total * 2 then return end
        if area_map[area] == map_id or area_rejected[area] == map_id then return end

        -- This runs on a timer, so the entity list is last frame's and its
        -- handles are not to be trusted: re-resolve by guid against the
        -- current sweep before reading anything.
        local e = witness[area]
        local unit = e and units.by_guid(e.guid)
        local pos = unit and units.position(unit)
        if not pos then return end

        local verdict = verify_area(area, map_id, e.info.npc_id, pos)
        if verdict == true then
            area_map[area] = map_id
            area_version = area_version + 1
            log.fmt("info", "quest spawns: area %d is map %d (%s)", area, map_id,
                SEED[area] == map_id and "as seeded" or "learned")
        elseif verdict == false then
            area_rejected[area] = map_id
            log.fmt("warn", "quest spawns: map %d is not area %d; spawns there stay unresolved",
                map_id, area)
        end
    end

    ctx.every(2.0, learn_current_zone)

    ---@param area integer
    ---@return integer|nil map_id
    local function map_for_area(area)
        local verified = area_map[area]
        if verified then return verified end
        local seeded = SEED[area]
        if seeded and area_rejected[area] ~= seeded then return seeded end
        return nil
    end

    M.map_for_area = map_for_area

    -- Converted spawn points per target, for the session. A common mob has
    -- dozens of spawns and each conversion is a native call, so the
    -- conversions are rationed per frame and resumed on the next one; a
    -- target whose area is not mapped yet keeps its rows and tries again
    -- when a mapping is learned.
    local spawn_cache = {}
    local CONVERT_BUDGET = 40
    local conversions_left = CONVERT_BUDGET

    --- World points where a target spawns, as far as they have been resolved.
    ---@param kind "n"|"o"
    ---@param id integer
    ---@return table[] points { x, y, z? }
    local function spawn_points(kind, id)
        local key = kind .. id
        local entry = spawn_cache[key]
        if not entry then
            entry = { points = {}, pending = raw_spawns(kind, id), version = -1, starved = false }
            spawn_cache[key] = entry
        end

        local pending = entry.pending
        if #pending > 0 and (entry.starved or entry.version ~= area_version) then
            entry.version = area_version
            entry.starved = false
            local keep = {}
            for i = 1, #pending do
                local row = pending[i]
                local map_id = map_for_area(row[1])
                if not map_id then
                    keep[#keep + 1] = row
                elseif conversions_left <= 0 then
                    keep[#keep + 1] = row
                    entry.starved = true
                else
                    conversions_left = conversions_left - 1
                    local world = map_to_world(map_id, row[2], row[3])
                    if world then entry.points[#entry.points + 1] = world end
                end
            end
            entry.pending = keep
        end

        return entry.points
    end

    -- Ids per quest that are worth resolving. An item that every humanoid in
    -- the game drops lists hundreds of npcs; the first few dozen -- the
    -- direct objectives come first -- are the ones that matter.
    local SPAWN_IDS_PER_QUEST = 40

    --- The nearest known spawn of anything this quest currently wants.
    ---@param quest table
    ---@param from vec3
    ---@return table|nil point
    ---@return number distance
    local function nearest_spawn(quest, from)
        local targets = questie_targets(quest.id)
        if not targets then return nil, math.huge end

        local lists
        if quest.offered then
            lists = { { "n", targets.givers } }
        elseif quest.complete then
            lists = { { "n", targets.enders } }
        else
            local wanted = index.wanted_by_quest and index.wanted_by_quest[quest.id]
            if wanted then
                lists = { { "n", wanted.npcs }, { "o", wanted.objects } }
            else
                lists = { { "n", targets.npcs }, { "o", targets.objects } }
            end
        end

        local best, best_sq = nil, math.huge
        local considered = 0
        for l = 1, #lists do
            local kind, ids = lists[l][1], lists[l][2]
            for i = 1, #ids do
                if considered >= SPAWN_IDS_PER_QUEST then break end
                considered = considered + 1
                local points = spawn_points(kind, ids[i])
                for j = 1, #points do
                    local p = points[j]
                    local dx, dy = p.x - from.x, p.y - from.y
                    local sq = dx * dx + dy * dy
                    if sq < best_sq then best, best_sq = p, sq end
                end
            end
        end

        if not best then return nil, math.huge end
        return best, math.sqrt(best_sq)
    end

    -- The nearest spawn per quest is re-chosen on a short clock, a few
    -- quests per frame, rather than every frame for every quest: it is a
    -- distance test against every known spawn of every target.
    local spawn_target = {}   -- quest id -> { at, point, distance }
    local SPAWN_TTL = 0.5
    local SPAWN_REFRESH_PER_FRAME = 3

    --- The nearest-spawn answer for a quest, refreshed when stale and the
    --- frame still has refreshes to spend.
    ---@return table|nil point
    ---@return number distance
    local function spawn_target_for(quest, from, now, refreshes)
        local held = spawn_target[quest.id]
        if held and (now - held.at) < SPAWN_TTL then
            return held.point, held.distance
        end
        if refreshes.left <= 0 then
            if held then return held.point, held.distance end
            return nil, math.huge
        end
        refreshes.left = refreshes.left - 1

        local point, distance = nearest_spawn(quest, from)
        held = held or {}
        held.at, held.point, held.distance = now, point, distance
        spawn_target[quest.id] = held
        return point, distance
    end

    --- Paths to where the targets of quests with nothing on screen spawn.
    ---
    --- Drawn AFTER the live paths and only for quests that got none: a path
    --- to a spawn point is a guess about where a mob will be, and it should
    --- never compete with a path to where one is.
    ---@param has_live table quest id -> true for quests with a live path
    ---@param room integer How many more paths may be drawn this frame.
    ---@return integer drawn
    local function draw_spawn_paths(has_live, room)
        if room <= 0 then return 0 end
        if not P.opt("quest_spawn_paths", true) then return 0 end

        local from = units.player_position()
        if not from then return 0 end

        local max_distance = P.opt("quest_spawn_range", 2000)
        local max_length = P.opt("quest_spawn_line_length", 60)
        local dash = P.opt("quest_line_dashed", true) and 2.0 or nil
        local now = core.time()
        local refreshes = { left = SPAWN_REFRESH_PER_FRAME }
        local drawn = 0

        for i = 1, #index.order do
            if drawn >= room then break end
            local quest = index.quests[index.order[i]]
            if quest and not has_live[quest.id] then
                local point, distance = spawn_target_for(quest, from, now, refreshes)
                if point and distance <= max_distance then
                    -- The spawn's height is sampled once, with a wide
                    -- tolerance, the way a guide waypoint is: it is a first
                    -- guess that the ground path corrects on the way out.
                    if not point.z then
                        point.z = sample_ground(point.x, point.y, from.z, 500) or from.z
                    end

                    local label = quest.name
                    if quest.complete then
                        label = "turn in: " .. label
                    elseif quest.offered then
                        label = "pick up: " .. label
                    end
                    if #label > 30 then label = label:sub(1, 29) .. "\226\128\166" end

                    if draw_path_to({ x = point.x, y = point.y, z = point.z },
                        M.quest_color(quest), label,
                        { max_length = max_length, dash = dash, thickness = 1.6, ring = 1.5 }) then
                        drawn = drawn + 1
                    end
                end
            end
        end

        return drawn
    end

    -- --- quest target lines -------------------------------------------------

    --- A dashed path to the nearest target of each quest you are on.
    ---
    --- Reads the overlay's entity list rather than walking the world again --
    --- the collector built it earlier this same frame, with distances already
    --- measured and quest membership already resolved. Grouping by quest and
    --- keeping the nearest is what stops a camp of eight quest mobs becoming
    --- eight lines to the same place.
    ---@return integer drawn How many live paths were painted this frame.
    local function draw_quest_lines()
        -- The quest ESP's (1.73.0): off with "Enable quest ESP", whatever the
        -- ESP page says.
        if not P.opt("questie_on", true) or not P.opt("quest_lines", true) then return 0 end
        if not P.esp then return 0 end

        local entities = P.esp.entities()
        local n = P.esp.count and P.esp.count() or #entities
        if n == 0 then return 0 end

        local every = P.opt("quest_lines_all", false)
        local max_lines = P.opt("quest_max_lines", 4)
        local range = P.opt("quest_line_range", 120)
        local dash = P.opt("quest_line_dashed", true) and 2.0 or nil

        -- quest id -> the nearest entity serving it
        local nearest, order = {}, {}
        -- quest id -> true once anything live is serving it, on screen or
        -- not: a quest with a target in range gets no spawn path even when
        -- the line cap left that target undrawn.
        local has_live = {}
        local drawn = 0

        for i = 1, n do
            local e = entities[i]
            if e.quest_entries and e.distance <= range then
                local entries = e.quest_entries
                for j = 1, #entries do
                    local quest = entries[j].quest
                    has_live[quest.id] = true
                    if every then
                        if drawn < max_lines then
                            drawn = drawn + 1
                            local pos = e.obj:get_position()
                            if pos then
                                -- No end label here either: the mark above
                                -- the target already says which quest it is.
                                draw_path_to(pos, M.quest_color(quest), nil, {
                                    max_length = range, dash = dash, thickness = 1.8,
                                    ring = false,
                                })
                            end
                        end
                    else
                        -- Compared rather than assumed: the entity list is
                        -- ordered by relevance now, not by distance, so the
                        -- first target seen for a quest is not necessarily
                        -- the closest one.
                        local held = nearest[quest.id]
                        if not held then
                            nearest[quest.id] = e
                            order[#order + 1] = quest
                        elseif e.distance < held.distance then
                            nearest[quest.id] = e
                        end
                    end
                end
            end
        end

        if not every then
            for i = 1, math.min(#order, max_lines) do
                local quest = order[i]
                local e = nearest[quest.id]
                -- Read fresh every frame, so the path follows the mob rather
                -- than ending where it was standing when the frame before
                -- last looked.
                local pos = e.obj:get_position()
                if pos then
                    -- No label at the end of the line: the mark above the
                    -- mob already names the quest and its progress, in this
                    -- same colour. Two copies of it, one of them floating at
                    -- the creature's feet, is the clutter this was meant to
                    -- remove.
                    if draw_path_to(pos, M.quest_color(quest), nil, {
                        max_length = range, dash = dash, thickness = 1.8, ring = false,
                    }) then
                        drawn = drawn + 1
                    end
                end
            end
        end

        -- Everything above was a path to something on screen. What is left
        -- of the line cap goes to quests with nothing in range at all.
        draw_spawn_paths(has_live, max_lines - drawn)

        return drawn
    end

    -- --- guide panel --------------------------------------------------------
    --
    -- A JCore window (1.83.0; the user: "make the rested exp guide panel
    -- moveable, resizeable"): dragged by its title bar, resized from its
    -- bottom-right corner, folded away with a double-click on the title, and
    -- JCore's overlay UI remembers where it was left and how big. The panel
    -- is text only, so unlike the spell window the whole window is JCore's:
    -- there is no texture under it for a solid body to hide. Where the
    -- overlay UI is missing or switched off the panel is drawn here, where
    -- the window was last left.

    local GUIDE_WINDOW = "rxp_guide"
    local GUIDE_W, GUIDE_H = 300, 200

    --- The panel's rows: `text`, then a `tail` (a count, a distance) that is
    --- kept whole when the row has to be cut short.
    local function guide_rows()
        local rows = {}

        if rxp.step then
            local goals = rxp.step.goals or {}
            for i = 1, math.min(#goals, 6) do
                local goal = goals[i]
                rows[#rows + 1] = {
                    text = (goal.is_complete and "x " or "- ") .. (goal.text or goal.action or ""),
                    col = goal.is_complete and draw.theme.good or draw.theme.text,
                }
            end
        end

        for i = 1, math.min(#rxp.objectives, 6) do
            local o = rxp.objectives[i]
            rows[#rows + 1] = {
                text = o.text,
                tail = o.need > 0 and string.format("%.0f/%.0f", o.have, o.need) or nil,
                col = o.finished and draw.theme.good or draw.theme.text_dim,
            }
        end

        local away = rxp.waypoint_away
        if away then
            rows[#rows + 1] = {
                text = "-> " .. away.text,
                tail = away.why == "continent" and "away" or "?",
                col = draw.theme.warning,
            }
        elseif rxp.waypoint then
            -- A goto step's waypoint often has no title: its zone's name then.
            local known = CLASSIC_MAPS[rxp.waypoint.map_id]
            local title = rxp.waypoint.title
            if type(title) ~= "string" or title == "" then title = known and known[1] or "the waypoint" end
            rows[#rows + 1] = {
                text = "-> " .. title,
                tail = string.format("%.0fy", rxp.waypoint.dist or 0),
                col = draw.theme.warning,
            }
        end

        return rows
    end

    --- The panel without JCore's overlay UI: the title in the accent colour,
    --- then the rows, each cut to the width with its tail kept.
    local function draw_guide_fallback(title, rows, x, y, width, size)
        local line_h = size + 5
        local chars = math.max(8, math.floor((width - 20) / (size * 0.54)))
        local height = line_h * (#rows + 1) + 14
        local layer = ctx.LAYER.HUD

        draw.rect_2d({ x = x, y = y }, width, height, draw.theme.backdrop,
            { layer = layer, filled = true, rounding = 4 })
        draw.text_2d({ x = x + 10, y = y + 7 }, title:sub(1, chars), draw.theme.accent,
            { layer = layer, size = size })

        for i = 1, #rows do
            local r = rows[i]
            local room = chars - 2 - (r.tail and #r.tail + 2 or 0)
            local text = r.text:sub(1, math.max(1, room)) .. (r.tail and ("  " .. r.tail) or "")
            draw.text_2d({ x = x + 22, y = y + 7 + line_h * i }, text, r.col,
                { layer = layer, size = size })
        end
    end

    local function draw_guide_panel()
        if not P.opt("rxp_on", true) or not P.opt("rxp_panel", true) then return end
        if not rxp.loaded then return end

        local rows = guide_rows()
        if #rows == 0 and not rxp.step then return end

        local title = "RestedXP"
        if rxp.step then
            title = string.format("RestedXP  -  Step %d%s", rxp.step.num or 0,
                rxp.step.is_complete and "  (complete)" or "")
        end

        local size = P.opt("text_size", 13)
        local screen_w = draw.screen_size()
        local x, y, width = screen_w - GUIDE_W - 24, 120, GUIDE_W

        local ui = ctx.ui
        if ui and ui.begin_window then
            local ok, open, win = pcall(ui.begin_window, ui, GUIDE_WINDOW, {
                title = title, x = x, y = y, w = GUIDE_W, h = GUIDE_H, min_w = 160, min_h = 60,
                resizable = true, movable = true, collapsible = true, closable = false,
            })
            if ok and open then
                for i = 1, #rows do
                    local r = rows[i]
                    ui:text(r.tail and (r.text .. "  " .. r.tail) or r.text, { color = r.col, size = size })
                end
            end
            -- ALWAYS paired, whatever begin answered.
            pcall(ui.end_window, ui)
            if ok and type(win) == "table" then
                if open or win.collapsed or win.visible == false then return end
                -- The overlay UI is switched off: where it was, our own panel.
                x, y, width = win.x or x, win.y or y, win.w or width
            end
        end

        draw_guide_fallback(title, rows, math.floor(x), math.floor(y), width, size)
    end

    --- Inside a dungeon or a raid. JCore keeps the answer for the zone, so
    --- asking every frame is a table lookup.
    local function in_dungeon()
        local world = ctx.world
        if type(world) ~= "table" or type(world.instance_type) ~= "function" then return false end
        local ok, kind = pcall(world.instance_type)
        return ok and (kind == "party" or kind == "raid")
    end

    --- Everything the quest layer paints, called from the plugin's HUD render
    --- job -- which runs after the collector, so the entity list the quest
    --- lines read was built this frame.
    function M.render_hud()
        -- A fresh height budget per frame. The guide refresh on its timer
        -- spends from the same pool, which is fine: it runs once a second and
        -- converts a handful of waypoints.
        probes_left = GROUND_PROBE_BUDGET
        conversions_left = CONVERT_BUDGET

        -- NO PATHS IN A DUNGEON OR RAID, by default (1.47.3, user: "in
        -- dungeons by default dont show lines to quests and stuff"): the
        -- quest paths, the spawn paths and the guide's waypoint lines. In
        -- there a path runs through walls and packs; the marks on the mobs
        -- themselves still say what a quest wants, and the panel stays.
        if in_dungeon() and not P.opt("quest_lines_in_dungeons", false) then
            draw_guide_panel()
            return
        end

        -- Live targets are resolved FIRST, because whether any exist is what
        -- decides if a path to a map coordinate is worth drawing at all.
        -- RestedXP only (1.61.0): no quest paths, the guide's line still.
        local live_paths = (not P.opt("rxp_only", false)) and (draw_quest_lines() or 0) or 0
        -- The guide walk's route, while it walks, in the guide line's place.
        if not draw_walk_route() then draw_waypoint_lines(live_paths) end
        draw_guide_panel()
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local by_npc = 0
        for _ in pairs(index.by_npc) do by_npc = by_npc + 1 end
        local by_name = 0
        for _ in pairs(index.by_name) do by_name = by_name + 1 end

        local areas, spawn_targets, spawn_pts, unresolved = 0, 0, 0, 0
        for _ in pairs(area_map) do areas = areas + 1 end
        for _, entry in pairs(spawn_cache) do
            spawn_targets = spawn_targets + 1
            spawn_pts = spawn_pts + #entry.points
            unresolved = unresolved + #entry.pending
        end

        return {
            quests = index.count,
            questlog = questlog.stats(),
            quest_npc_ids = by_npc,
            quest_names = by_name,
            spawn_areas = areas,
            spawn_targets = spawn_targets,
            spawn_points = spawn_pts,
            spawn_unresolved = unresolved,
            questie_ready = questie_ready,
            questie_ids = questie_count,
            rxp_loaded = rxp.loaded,
            rxp_step = rxp.step and rxp.step.num or nil,
            rxp_targets = (function()
                local n = 0
                for _ in pairs(rxp.targets) do n = n + 1 end
                return n
            end)(),
            rxp_objectives = #rxp.objectives,
            rxp_waypoint = rxp.waypoint and rxp.waypoint.title or nil,
            rxp_world_waypoint = rxp.world_waypoint ~= nil,
            rxp_waypoint_away = rxp.waypoint_away and rxp.waypoint_away.text or nil,
        }
    end

    return M
end

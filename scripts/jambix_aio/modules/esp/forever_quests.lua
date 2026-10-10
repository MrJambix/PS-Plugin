-- Jambix AIO / esp/forever_quests -- what the quests want, on the Forever
-- client, from what that client was recorded answering.
--
-- Forever has none of what the classic quest marks stand on: Questie and
-- RestedXP are not loaded there, the classic quest log answers nothing
-- (get_num_quest_log_entries 0), and is_quest_unit is always false. What it
-- DOES answer (JCore's API recorder, 2026-10-02):
--
--   get_npc_flags            bit 2 (0x2) on every quest giver
--   get_gossip_active_quests  rows of { quest_id, title, quest_level,
--   get_gossip_available_quests  is_complete, ... } while a giver's window is
--                            open; the ACTIVE list is the quests that go
--                            back to that giver
--   is_on_quest(id), is_quest_flagged_completed(id)   per quest id
--   QUEST_ACCEPTED (id), QUEST_TURNED_IN (id, xp, money), QUEST_REMOVED (id)
--   UI_INFO_MESSAGE          "Roiling Winds destroyed: 4/6" with an
--                            ERR_QUEST_ADD_*_SII tag: an objective's subject
--                            and how far along it is
--   game_object:get_name     real names on game objects, quest ones tagged
--                            "(Quest)" ("Ley Line Trap (Quest)")
--
-- From those it answers four questions for esp/forever.lua:
--   giver(npc_id)            "turnin", "pickup", "progress", "unknown" or nil
--   objective(name)          the unfinished objective a mob or object's name
--                            matches, as { have, need, kind, subject }
--   quest_object(name)       a game object a quest uses, and what to call it;
--                            since 1.59.0 also the ones the quest database
--                            says a quest you are on wants (see QUEST OBJECTS
--                            FROM THE QUEST DATABASE below)
--   stats()
--
-- Everything learned is kept in a store, so a giver talked to yesterday is
-- still known today. Getters only: nothing accepts, completes or turns in.
--
-- THE GAME'S OWN QUEST LOG (1.53.0). When JCore's gamelua bridge works on
-- this client (it probes core.execute / read_lua_* before anything uses
-- them), the quest log is read from the game itself every two seconds:
-- every quest you are on, whether it is complete, and each objective's type,
-- text and x/y -- from C_QuestLog, or the classic quest-log calls when that
-- is what the client has. The same run says which map you are on, where you
-- stand on it, and where each quest's area is (C_QuestLog.GetQuestsOnMap,
-- QuestPOIGetIconInfo, C_QuestLog.GetNextWaypoint). Map positions become
-- world positions through core.game_ui.get_world_pos_from_map_pos, and that
-- conversion is checked on YOU first: your own map position, converted, must
-- land within 25 yards of where you stand, or no quest area is placed.
-- Every 0.75 s a second run asks about the units: every nameplate, your
-- target and your mouseover by unit token (UnitGUID, UnitName,
-- C_QuestLog.UnitIsRelatedToActiveQuest and the unit's tooltip lines,
-- C_TooltipInfo.GetUnit), and the nearest mobs without one by guid
-- (C_TooltipInfo.GetHyperlink("unit:" .. guid)). A tooltip that names one of
-- your quests and an objective under it makes that unit a quest target with
-- that objective's progress. What a mob DROPS for quests comes from the
-- client's creature cache (JCore's creatures: quest item ids by npc id),
-- with the item names asked of the game. Without the bridge every answer
-- below is what it was before 1.53.0.
--   unit(guid, npc_id)       { text = "KILL 2/8" | "LOOT 1/6" | "USE 0/1" |
--                            "QUEST", title, qid, kind = "kill" | "item" |
--                            "found" | "other", have, need } or nil
--   unit_name(guid)          the game's name for a unit it has told us about
--   locations()              { quest, x, y, z, done, source } per quest with
--                            an area placed on the world
--
-- THE CORE'S OWN QUEST LOG (1.82.0). The 2026-10-06 core answers the quest
-- log on Forever itself: core.quests.get_quest_log_quest_ids,
-- get_quest_objectives, is_quest_complete and the log's titles. While the
-- bridge is not up -- and on Forever its probe has failed every session
-- since 2026-10-03 -- the same lines are built from those every two seconds
-- and read the same way, so the KILL / LOOT / USE chips and the quest
-- objects follow the live counts. The bridge is still the only source of
-- the map, the quest areas and the units' tooltip lines, so locations(),
-- unit_name() and a tooltip-matched chip answer only with it.

-- The game-side bodies (WoW's Lua 5.1, sent through ctx.gamelua.run). Each
-- section runs in its own pcall and reports an error as an "E" line, so one
-- missing call costs that section only. Read only: nothing here acts.
local QUEST_BODY = [==[
local QL = C_QuestLog
local function clean(s) s = tostring(s or '') s = string.gsub(s, '[\t\n\r]', ' ') return s end
local ids = {}
local ok, err = pcall(function()
  local count, how = 0, 'none'
  if QL and QL.GetNumQuestLogEntries then count = QL.GetNumQuestLogEntries() or 0 how = 'C_QuestLog'
  elseif GetNumQuestLogEntries then count = GetNumQuestLogEntries() or 0 how = 'classic' end
  out('N\t' .. tostring(count) .. '\t' .. how)
  for i = 1, count do
    local id, title, header, complete
    if QL and QL.GetInfo then
      local info = QL.GetInfo(i)
      if info then id, title, header = info.questID, info.title, info.isHeader end
    elseif GetQuestLogTitle then
      local t, _, _, h, _, c, _, qid = GetQuestLogTitle(i)
      id, title, header, complete = qid, t, h, (c == 1 or c == true)
    end
    if id and id > 0 and not header then
      if QL and QL.IsComplete then complete = QL.IsComplete(id) end
      ids[#ids + 1] = id
      out('Q\t' .. id .. '\t' .. (complete and 1 or 0) .. '\t' .. clean(title))
      local objs = QL and QL.GetQuestObjectives and QL.GetQuestObjectives(id)
      if type(objs) == 'table' and #objs > 0 then
        for j = 1, #objs do
          local o = objs[j]
          out('O\t' .. id .. '\t' .. j .. '\t' .. clean(o.type) .. '\t' .. (o.finished and 1 or 0) .. '\t'
            .. tostring(o.numFulfilled or '') .. '\t' .. tostring(o.numRequired or '') .. '\t' .. clean(o.text))
        end
      elseif GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
          local text, typ, done = GetQuestLogLeaderBoard(j, i)
          out('O\t' .. id .. '\t' .. j .. '\t' .. clean(typ) .. '\t' .. (done and 1 or 0) .. '\t\t\t' .. clean(text))
        end
      end
    end
  end
end)
if not ok then out('E\tlog\t' .. clean(err)) end
local map
ok, err = pcall(function()
  map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit('player')
  if not map then return end
  local px, py
  local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, 'player')
  if pos then
    px, py = pos.x, pos.y
    if pos.GetXY then px, py = pos:GetXY() end
  end
  out('M\t' .. map .. '\t' .. tostring(px) .. '\t' .. tostring(py))
  if QL and QL.GetQuestsOnMap then
    local list = QL.GetQuestsOnMap(map)
    if type(list) == 'table' then
      for k = 1, #list do
        local p = list[k]
        out('P\t' .. tostring(p.questID) .. '\t' .. tostring(p.x) .. '\t' .. tostring(p.y) .. '\t' .. map .. '\tonmap')
      end
    end
  end
  if QuestPOIGetIconInfo then
    for k = 1, #ids do
      local done, x, y = QuestPOIGetIconInfo(ids[k])
      if x and y then out('P\t' .. ids[k] .. '\t' .. x .. '\t' .. y .. '\t' .. map .. '\tpoi\t' .. (done and 1 or 0)) end
    end
  end
end)
if not ok then out('E\tmap\t' .. clean(err)) end
ok, err = pcall(function()
  if not (QL and QL.GetNextWaypoint) then return end
  for k = 1, #ids do
    local wmap, x, y = QL.GetNextWaypoint(ids[k])
    if wmap and x and y then out('P\t' .. ids[k] .. '\t' .. x .. '\t' .. y .. '\t' .. wmap .. '\twaypoint') end
  end
end)
if not ok then out('E\twaypoint\t' .. clean(err)) end
]==]

-- Asked about the units: "wanted" (guids) and "items" (item ids) are put in
-- front of this by units_body below.
local UNITS_BODY = [==[
local QL = C_QuestLog
local function clean(s) s = tostring(s or '') s = string.gsub(s, '[\t\n\r\031]', ' ') return s end
local seen = {}
local function lines_of(data)
  if type(data) ~= 'table' or type(data.lines) ~= 'table' then return '', nil end
  local t = {}
  for k = 2, #data.lines do
    local l = data.lines[k]
    if type(l) == 'table' then t[#t + 1] = tostring(l.type) .. ':' .. clean(l.leftText) end
  end
  local first = data.lines[1]
  return table.concat(t, '\031'), (type(first) == 'table' and first.leftText or nil)
end
local function unit(token, src)
  if not (UnitExists and UnitExists(token)) then return end
  local guid = UnitGUID(token)
  if not guid or seen[guid] then return end
  seen[guid] = true
  local rel = QL and QL.UnitIsRelatedToActiveQuest and QL.UnitIsRelatedToActiveQuest(token)
  local lines = ''
  if C_TooltipInfo and C_TooltipInfo.GetUnit then
    local ok, data = pcall(C_TooltipInfo.GetUnit, token)
    if ok then lines = lines_of(data) end
  end
  out('U\t' .. guid .. '\t' .. (rel and 1 or 0) .. '\t' .. clean(UnitName and UnitName(token)) .. '\t' .. src .. '\t' .. lines)
end
local ok, err = pcall(function()
  unit('target', 'target')
  unit('mouseover', 'mouseover')
  if C_NamePlate and C_NamePlate.GetNamePlates then
    local plates = C_NamePlate.GetNamePlates() or {}
    for k = 1, #plates do
      local f = plates[k]
      local token = f and (f.namePlateUnitToken or (f.UnitFrame and f.UnitFrame.unit))
      if token then unit(token, 'plate') end
    end
  end
end)
if not ok then out('E\tunits\t' .. clean(err)) end
ok, err = pcall(function()
  if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return end
  for k = 1, #wanted do
    local g = wanted[k]
    if not seen[g] then
      seen[g] = true
      local fine, data = pcall(C_TooltipInfo.GetHyperlink, 'unit:' .. g)
      if fine then
        local lines, name = lines_of(data)
        out('U\t' .. g .. '\t-\t' .. clean(name) .. '\tlink\t' .. lines)
      end
    end
  end
end)
if not ok then out('E\tlinks\t' .. clean(err)) end
ok, err = pcall(function()
  for k = 1, #items do
    local id = items[k]
    local n = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or (GetItemInfo and GetItemInfo(id))
    if n then out('I\t' .. id .. '\t' .. clean(n)) end
  end
end)
if not ok then out('E\titems\t' .. clean(err)) end
]==]

return function(P)
    local ctx = P.ctx
    local units = P.units

    local M = {}

    local QUESTGIVER = 2              -- UNIT_NPC_FLAG_QUESTGIVER
    local SPIRIT_HEALER = 0x4000      -- UNIT_NPC_FLAG_SPIRITHEALER
    local SPIRIT_GUIDE = 0x8000       -- UNIT_NPC_FLAG_SPIRITGUIDE (a battleground's)
    local GIVER_REACH = 8.0           -- yards: the giver whose window just opened
    local RECENT_GIVER = 60           -- seconds a giver stays "the one you talked to"
    local OBJECTIVE_TTL = 3 * 3600    -- an objective not heard of for this long is dropped
    local REFRESH_EVERY = 5.0         -- is_on_quest / completed, per known quest

    local function now() return core.time() end

    local store = (ctx.store and ctx.store("forever_quests")) or nil
    local data = store and store.data or {}
    data.givers = type(data.givers) == "table" and data.givers or {}
    data.quests = type(data.quests) == "table" and data.quests or {}
    data.objectives = type(data.objectives) == "table" and data.objectives or {}
    local function touch() if store then store:touch() end end

    local stats = { gossip = 0, objectives = 0, accepted = 0, turned_in = 0 }

    -- Bumped whenever an objective's progress changes, so quest_object's
    -- short cache never answers an old count (1.59.0).
    local objectives_rev = 0

    local function call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function quests_api() return type(core) == "table" and core.quests or nil end

    --- Has the npc flag bit set. Arithmetic, not a bitwise operator: the
    --- game's Lua is 5.1 and has none.
    ---
    --- NOT A SPIRIT HEALER (1.78.2). The graveyard's Spirit Healer carries the
    --- quest giver bit too (16387: gossip, quest giver, spirit healer; the
    --- Forever trace, 2026-10-05) and has no quest. Never talked to, it was
    --- marked QUEST for as long as you stood there, and at the graveyard it
    --- was the nearest "giver" for a window that opened with no target.
    function M.is_giver_flags(flags)
        flags = tonumber(flags)
        if not flags or flags < 0 then return false end
        if math.floor(flags / SPIRIT_HEALER) % 2 == 1 or math.floor(flags / SPIRIT_GUIDE) % 2 == 1 then
            return false
        end
        return math.floor(flags / QUESTGIVER) % 2 == 1
    end

    -- --- names -------------------------------------------------------------

    local function norm(s)
        if type(s) ~= "string" then return nil end
        s = s:lower():gsub("%s*%(quest%)%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if s == "" then return nil end
        return s
    end

    local SUBJECT_VERBS = { " slain", " killed", " destroyed", " defeated", " collected", " freed",
        " rescued", " captured", " found", " used", " activated", " investigated" }

    --- The thing an objective is about: "Roiling Winds destroyed" -> "roiling winds".
    local function subject_of(text)
        local s = norm(text)
        if not s then return nil end
        for i = 1, #SUBJECT_VERBS do
            local v = SUBJECT_VERBS[i]
            if #s > #v and s:sub(-#v) == v then return s:sub(1, -#v - 1) end
        end
        return s
    end

    --- The forms a name may take in an objective: as is, plural, singular.
    local function forms(name)
        local out = { name }
        if name:sub(-3) == "ies" then out[#out + 1] = name:sub(1, -4) .. "y"
        elseif name:sub(-2) == "es" then out[#out + 1] = name:sub(1, -3)
        end
        if name:sub(-1) == "s" then out[#out + 1] = name:sub(1, -2) end
        if name:sub(-1) == "y" then out[#out + 1] = name:sub(1, -2) .. "ies" end
        out[#out + 1] = name .. "s"
        out[#out + 1] = name .. "es"
        return out
    end

    -- --- quest state --------------------------------------------------------------

    local function quest(id, title, level)
        id = tonumber(id)
        if not id or id <= 0 then return nil end
        local key = tostring(math.floor(id))
        local q = data.quests[key]
        if not q then
            q = {}
            data.quests[key] = q
            touch()
        end
        if type(title) == "string" and title ~= "" then q.title = title end
        if tonumber(level) then q.level = tonumber(level) end
        return q, key
    end

    --- Whether a quest is still something to do: not turned in, and either
    --- not yet taken or taken and not finished.
    local function open_for(q)
        if not q then return false end
        if q.done then return false end
        return true
    end

    -- The giver whose window is open, or was a moment ago.
    local last_giver, last_giver_at = nil, -1e9

    local function giver_now()
        local combat = P.combat
        local target = combat and combat.target and combat.target() or nil
        if target then
            local ok, id = pcall(function() return target:get_npc_id() end)
            id = ok and tonumber(id) or 0
            if id > 0 then return tostring(id) end
        end
        -- No target: the nearest quest giver within reach.
        local best, best_d = nil, GIVER_REACH
        local list = units and units.units and units.units() or {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot and units.snapshot(obj) or nil
            if row and not row.is_player and not row.dead and (row.dist or 99) <= best_d then
                local okf, flags = pcall(function() return obj:get_npc_flags() end)
                if okf and M.is_giver_flags(flags) then
                    local ok, id = pcall(function() return obj:get_npc_id() end)
                    id = ok and tonumber(id) or 0
                    if id > 0 then best, best_d = tostring(id), row.dist end
                end
            end
        end
        return best
    end

    local function read_rows(rows, into, state, npc)
        if type(rows) ~= "table" then return end
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == "table" and tonumber(r.quest_id) then
                local q, key = quest(r.quest_id, r.title, r.quest_level)
                into[key] = { state = state, complete = r.is_complete == true }
                if state == "active" then
                    q.turn_in = npc
                    q.complete = r.is_complete == true
                else
                    q.giver = q.giver or npc
                end
            end
        end
    end

    --- A giver's window: what it offers and what it takes back.
    local function on_gossip()
        local api = quests_api()
        if not api then return end
        local npc = giver_now()
        if not npc then return end
        last_giver, last_giver_at = npc, now()
        local available = call(api.get_gossip_available_quests)
        local active = call(api.get_gossip_active_quests)
        if available == nil and active == nil then return end
        local g = { at = math.floor(now()), quests = {} }
        read_rows(available, g.quests, "available", npc)
        read_rows(active, g.quests, "active", npc)
        data.givers[npc] = g
        stats.gossip = stats.gossip + 1
        touch()
    end

    local function on_objective(text, tag)
        if type(text) ~= "string" or type(tag) ~= "string" or not tag:find("^ERR_QUEST_ADD") then return end
        local what, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)")
        if not what then return end
        local subject = subject_of(what)
        if not subject then return end
        local kind = tag:find("KILL") and "kill" or (tag:find("ITEM") and "item")
            or (tag:find("FOUND") and "found") or "other"
        data.objectives[subject] = {
            text = text, have = tonumber(have), need = tonumber(need), kind = kind, at = math.floor(now()),
        }
        stats.objectives = stats.objectives + 1
        objectives_rev = objectives_rev + 1
        touch()
    end

    if ctx.on then
        for _, name in ipairs({ "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE" }) do
            ctx.on("jcore.game_event." .. name, function() pcall(on_gossip) end)
        end
        ctx.on("jcore.game_event.QUEST_ACCEPTED", function(args)
            local q = quest(type(args) == "table" and args[1])
            if not q then return end
            q.accepted_at = math.floor(now())
            q.on_quest = true
            if last_giver and now() - last_giver_at <= RECENT_GIVER then q.giver = q.giver or last_giver end
            stats.accepted = stats.accepted + 1
            touch()
        end)
        ctx.on("jcore.game_event.QUEST_TURNED_IN", function(args)
            local q = quest(type(args) == "table" and args[1])
            if not q then return end
            q.done = true
            q.on_quest = false
            stats.turned_in = stats.turned_in + 1
            touch()
        end)
        ctx.on("jcore.game_event.QUEST_REMOVED", function(args)
            local q = quest(type(args) == "table" and args[1])
            if q then q.on_quest = false; touch() end
        end)
        ctx.on("jcore.game_event.UI_INFO_MESSAGE", function(args)
            if type(args) == "table" then pcall(on_objective, args[2], args[3]) end
        end)
    end

    -- --- keeping it current -----------------------------------------------------------

    local refreshed_at = -1e9

    --- Asks the client about every quest still open: two getters per quest,
    --- every few seconds, from the ESP's frame.
    function M.refresh()
        local t = now()
        if t - refreshed_at < REFRESH_EVERY then return end
        refreshed_at = t
        local api = quests_api()
        if not api then return end
        for key, q in pairs(data.quests) do
            if not q.done then
                local id = tonumber(key)
                local on = call(api.is_on_quest, id)
                local completed = call(api.is_quest_flagged_completed, id)
                if completed == true then
                    q.done, q.on_quest = true, false
                    touch()
                elseif on ~= nil and on ~= q.on_quest then
                    q.on_quest = on == true
                    touch()
                end
            end
        end
        for subject, o in pairs(data.objectives) do
            if (t - (o.at or 0)) > OBJECTIVE_TTL then
                data.objectives[subject] = nil
                objectives_rev = objectives_rev + 1
                touch()
            end
        end
    end

    -- --- the answers -------------------------------------------------------------------

    --- What a quest giver means to you now.
    ---@param npc_id integer|string
    ---@param flags integer|nil its npc flags, for a giver never talked to
    ---@return string|nil "turnin", "pickup", "progress", "unknown" or nil
    function M.giver(npc_id, flags)
        local g = data.givers[tostring(npc_id)]
        if not g then
            return M.is_giver_flags(flags) and "unknown" or nil
        end
        local pickup, progress = false, false
        for key, entry in pairs(g.quests or {}) do
            local q = data.quests[key]
            if open_for(q) then
                if entry.state == "active" then
                    if q.on_quest ~= false then
                        if q.complete or entry.complete then return "turnin" end
                        progress = true
                    end
                elseif entry.state == "available" and not q.on_quest then
                    pickup = true
                end
            end
        end
        if pickup then return "pickup" end
        if progress then return "progress" end
        return nil
    end

    --- The unfinished objective a name matches.
    ---@param name string
    ---@return table|nil { have, need, kind, subject, text }
    function M.objective(name)
        local n = norm(name)
        if not n then return nil end
        local f = forms(n)
        for i = 1, #f do
            local o = data.objectives[f[i]]
            if o and o.have and o.need and o.have < o.need then
                return { have = o.have, need = o.need, kind = o.kind, subject = f[i], text = o.text }
            end
        end
        return nil
    end

    --- How far along the objective a name matches is, finished or not: what
    --- quests.lua's index asks to tell a finished objective's targets from the
    --- rest (1.64.1). { have, need } or nil.
    ---@param name string
    ---@return table|nil
    function M.progress(name)
        local n = norm(name)
        if not n then return nil end
        local f = forms(n)
        for i = 1, #f do
            local o = data.objectives[f[i]]
            if o and o.have and o.need then return { have = o.have, need = o.need } end
        end
        return nil
    end

    -- --- quest objects from the quest database (1.59.0) ------------------------------
    --
    -- Until 1.59.0 an object was a quest object only by its name: tagged
    -- "(Quest)" by the client, or named by an objective the game had already
    -- reported progress on. "Bundle of Wood: 1/8" only arrives once the first
    -- bundle is picked up, so the first one was never marked. An object whose
    -- progress names the item inside it ("Shimmerweed" from a "Shimmerweed
    -- Basket") was never marked at all.
    --
    -- quests.lua's index knows them from the start. It has the quests you are
    -- on (the questlog's is_on_quest sweep). From JCore's questdb (QuestieDB's
    -- data) it has the objects each quest's objectives name, and the objects
    -- holding an item a quest wants (quest objectives -> the item's
    -- objectDrops). It is asked by the object's name, because an object's id
    -- is not proven on Forever. The item an object holds is looked up here
    -- too, because the progress message names the item, not the object. That
    -- gives the chip its count, and the mark goes once the objective is done.
    -- Forever's own quests (ids past 90000) are not in the database; their
    -- objects are still found by name, as before.

    local qdb = ctx.questdb
    local QO_TTL = 1.0                -- seconds an object name's answer is kept
    local QO_MAX = 256                -- names kept before the cache starts over
    local qo_cache, qo_n = {}, 0      -- raw name -> { at, rev, is, display, o, info }
    local subjects_cache = {}         -- "qid|name|c" -> { subject, ... }
    local db_said = {}                -- "qid|name" -> true once traced
    local db_marked = {}              -- display name -> true: marked from the database

    local function db_trace(text)
        if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", "fquests: " .. text) end
    end

    local function db_get(kind, id, key)
        if not (qdb and type(qdb.get) == "function") then return nil end
        local ok, v = pcall(qdb.get, kind, id, key)
        if ok then return v end
        return nil
    end

    local function db_name(kind, id)
        local n = db_get(kind, id, "name")
        if type(n) == "string" and n ~= "" then return n end
        return nil
    end

    --- What a quest's progress messages call the thing an object of this
    --- name gives you: the items it holds that the quest wants (collect),
    --- or the object objective's own text ("Cache of Explosives Destroyed").
    --- The object's name when the database says neither.
    local function subjects_for(qid, lowered, collect)
        local key = qid .. "|" .. lowered .. (collect and "|c" or "|u")
        local cached = subjects_cache[key]
        if cached then return cached end
        local out, seen = {}, {}
        local function add(s)
            s = s and subject_of(s)
            if s and not seen[s] then
                seen[s] = true
                out[#out + 1] = s
            end
        end
        local objectives = db_get("quest", qid, "objectives")
        if type(objectives) == "table" then
            -- Questie's objectives: [2] objects { id, text }, [3] items { id }.
            if collect and type(objectives[3]) == "table" then
                for _, row in pairs(objectives[3]) do
                    local item = type(row) == "table" and tonumber(row[1]) or nil
                    local drops = item and db_get("item", item, "objectDrops")
                    if type(drops) == "table" then
                        for _, oid in pairs(drops) do
                            local n = tonumber(oid) and db_name("object", tonumber(oid))
                            if n and n:lower() == lowered then
                                add(db_name("item", item))
                                break
                            end
                        end
                    end
                end
            elseif not collect and type(objectives[2]) == "table" then
                for _, row in pairs(objectives[2]) do
                    local oid = type(row) == "table" and tonumber(row[1]) or nil
                    local n = oid and db_name("object", oid)
                    if n and n:lower() == lowered and type(row[2]) == "string" then add(row[2]) end
                end
            end
        end
        if #out == 0 then add(lowered) end
        subjects_cache[key] = out
        return out
    end

    --- The stored progress of the first of these subjects not yet done, and
    --- whether every one of them has been heard of and is done.
    local function progress_of_subjects(subjects)
        local open, done = nil, true
        for i = 1, #subjects do
            local f = forms(subjects[i])
            local o, said = nil, nil
            for k = 1, #f do
                o = data.objectives[f[k]]
                if o then
                    said = f[k]
                    break
                end
            end
            if not (o and o.have and o.need) then
                done = false
            elseif o.have < o.need then
                done = false
                open = open or { have = o.have, need = o.need, kind = o.kind, subject = said, text = o.text }
            end
        end
        return open, done
    end

    --- What the quests you are on want with an object of this name, by
    --- quests.lua's index: nil when none does, { done = true } when every
    --- quest that does has that objective done, else { word, title, qid, o }.
    local function from_db(display)
        local Q = P.quests
        if not (Q and type(Q.quest_entries) == "function") then return nil end
        local ok, entries = pcall(Q.quest_entries, nil, display, false, true)
        if not ok or type(entries) ~= "table" or #entries == 0 then return nil end
        local lowered = display:lower()
        local best = nil
        for i = 1, #entries do
            local e = entries[i]
            local q = type(e) == "table" and e.quest or nil
            local qid = q and tonumber(q.id)
            local s = qid and data.quests[tostring(qid)]
            if qid and not (s and s.done) then
                local title = (s and s.title) or (type(q.name) == "string" and q.name) or nil
                if e.turn_in or e.tag == "turn_in" then
                    return { word = "TURN IN", title = title, qid = qid }
                elseif e.pick_up or e.tag == "pick_up" then
                    best = best or { word = "PICK UP", title = title, qid = qid }
                elseif not (s and s.complete) then
                    local collect = e.tag == "collect"
                    local open, done = progress_of_subjects(subjects_for(qid, lowered, collect))
                    if not done then
                        local r = { word = collect and "COLLECT" or "USE", title = title, qid = qid, o = open }
                        if open then return r end
                        if not best or best.word == "PICK UP" then best = r end
                    end
                end
            end
        end
        return best or { done = true }
    end

    --- A game object a quest uses: tagged "(Quest)" by the client, named by
    --- an unfinished objective, or (1.59.0) one the quest database says a
    --- quest you are on wants, until that objective is done.
    ---@param name string
    ---@return boolean is_quest
    ---@return string|nil display The name without the tag.
    ---@return table|nil objective { have, need, kind, subject, text } once its progress is known
    ---@return table|nil info { word, title, qid } when the quest database knows it
    function M.quest_object(name)
        if type(name) ~= "string" or name == "" then return false end
        local t = now()
        local c = qo_cache[name]
        if c and c.rev == objectives_rev and (t - c.at) < QO_TTL then
            return c.is, c.display, c.o, c.info
        end
        local display = name:gsub("%s*%([Qq]uest%)%s*", "")
        local o = M.objective(display)
        local ok, db = pcall(from_db, display)
        local info = (ok and type(db) == "table" and not db.done) and db or nil
        if info then
            o = o or info.o
            local key = tostring(info.qid) .. "|" .. display
            if not db_said[key] then
                db_said[key] = true
                db_marked[display] = true
                db_trace(string.format("db: %s is wanted by %s (%s): %s%s", display, tostring(info.title),
                    tostring(info.qid), info.word,
                    o and string.format(" %s/%s", tostring(o.have), tostring(o.need)) or ", no progress heard yet"))
            end
        end
        local is = o ~= nil or info ~= nil or display ~= name
        if not c then
            if qo_n >= QO_MAX then
                qo_cache, qo_n = {}, 0
            end
            c = {}
            qo_cache[name] = c
            qo_n = qo_n + 1
        end
        c.at, c.rev, c.is, c.display, c.o, c.info = t, objectives_rev, is, display, o, info
        return is, display, o, info
    end

    function M.stats()
        local givers, quests, open, objectives = 0, 0, 0, 0
        for _ in pairs(data.givers) do givers = givers + 1 end
        for _, q in pairs(data.quests) do
            quests = quests + 1
            if open_for(q) then open = open + 1 end
        end
        for _ in pairs(data.objectives) do objectives = objectives + 1 end
        local db_objects = 0
        for _ in pairs(db_marked) do db_objects = db_objects + 1 end
        return { givers = givers, quests = quests, open = open, objectives = objectives,
            gossip = stats.gossip, accepted = stats.accepted, turned_in = stats.turned_in,
            db_objects = db_objects }
    end

    -- --- the game's own quest log (1.53.0) -------------------------------------------
    --
    -- See the top of the file. Every reader here answers what it did before
    -- 1.53.0 until the bridge has answered once.

    local gl = ctx.gamelua
    local creatures = ctx.creatures
    local LOG_EVERY = 2.0             -- the quest log and the quest areas
    local UNITS_EVERY = 0.75          -- the units' quest lines and names
    local UNIT_TTL = 6.0              -- a unit's answer is believed this long
    local LINK_RANGE = 60             -- yards: units asked about by guid
    local LINK_AGAIN = 4.0            -- seconds before a unit is asked again
    local MAX_LINK_UNITS = 8
    local ITEM_ASK = 10
    local CONV_REACH = 25             -- yards: your own map position, converted, lands this near you

    local live = {
        ok = false, at = -1e9, quests = {}, order = {}, by_title = {}, map = nil, pois = {},
        units = {}, items = {}, conv = nil, conv_error = nil, how = nil, count = nil, errors = {},
    }
    M.live = live
    local live_stats = { logs = 0, unit_runs = 0, failed = 0, last_error = nil, units = 0, related = 0,
        plates = 0, links = 0 }
    local log_at, units_at, swept_at = -1e9, -1e9, -1e9
    local item_wanted = {}            -- item id -> true: a name to ask the game for

    local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

    local function fields(line)
        local t = {}
        for v in (line .. "\t"):gmatch("(.-)\t") do t[#t + 1] = v end
        return t
    end

    local function trace(text)
        if ctx.emit then pcall(ctx.emit, "jcore.recorder.trace", "fquests: " .. text) end
    end

    --- "Wolf Pelt: 2/8" (classic) or "2/8 Wolf Pelt" (the retail order):
    --- what, have, need. nil for text with no count.
    local function progress_of(text)
        if type(text) ~= "string" then return nil end
        local what, have, need = text:match("^(.-):%s*(%d+)%s*/%s*(%d+)")
        if what and what ~= "" then return what, tonumber(have), tonumber(need) end
        have, need, what = text:match("^%s*(%d+)%s*/%s*(%d+)%s+(.+)$")
        if what then return what, tonumber(have), tonumber(need) end
        return nil
    end
    M.progress_of = progress_of

    -- The objective types the game reports, as the chips name them.
    local KIND = { monster = "kill", item = "item", object = "found" }
    local WORD = { kill = "KILL", item = "LOOT", found = "USE", other = "QUEST" }

    --- Feeds what the log says into the store the name-matching readers use,
    --- so the KILL chips and the quest objects follow the live counts too.
    local function sync_store()
        local changed = false
        local t = math.floor(now())
        for i = 1, #live.order do
            local q = live.order[i]
            local s = quest(q.id, q.title)
            if s and (s.on_quest ~= true or s.complete ~= q.complete) then
                s.on_quest, s.complete = true, q.complete
                changed = true
            end
            for j = 1, #q.objectives do
                local o = q.objectives[j]
                if o.subject and o.need and o.need > 0 then
                    local old = data.objectives[o.subject]
                    if not old or old.have ~= o.have or old.need ~= o.need then changed = true end
                    data.objectives[o.subject] = {
                        text = o.text, have = o.have or 0, need = o.need, kind = o.kind, at = t, quest = q.id,
                    }
                end
            end
        end
        -- The log is the whole truth once it has listed anything: a quest it
        -- no longer has was turned in or dropped.
        if (live.count or 0) > 0 then
            for key, s in pairs(data.quests) do
                if s.on_quest and not live.quests[tonumber(key)] then
                    s.on_quest = false
                    changed = true
                end
            end
        end
        if changed then
            objectives_rev = objectives_rev + 1
            touch()
        end
    end

    --- A map position as a world one, with the axes the check on you chose.
    local function to_world(map_id, x, y)
        local ui = type(core.game_ui) == "table" and core.game_ui or nil
        local f = ui and ui.get_world_pos_from_map_pos
        if type(f) ~= "function" or not map_id or not x or not y then return nil end
        local ok, v = pcall(f, map_id, { x = x, y = y })
        if not ok or type(v) ~= "table" then return nil end
        local wx, wy = tonumber(v.x), tonumber(v.y)
        if not wx or not wy then return nil end
        if live.conv == "swapped" then return wy, wx end
        return wx, wy
    end

    --- Your own map position, converted, must land where you stand.
    local function calibrate()
        local m = live.map
        local me = units.player_position and units.player_position()
        if not (m and m.id and m.x and m.y and me) then return end
        live.conv = nil
        local wx, wy = to_world(m.id, m.x, m.y)
        if not wx then
            live.conv = "none"
            return
        end
        local d = math.sqrt((wx - me.x) ^ 2 + (wy - me.y) ^ 2)
        local ds = math.sqrt((wy - me.x) ^ 2 + (wx - me.y) ^ 2)
        if d <= CONV_REACH then
            live.conv, live.conv_error = "direct", d
        elseif ds <= CONV_REACH then
            live.conv, live.conv_error = "swapped", ds
        else
            live.conv, live.conv_error = "bad", math.min(d, ds)
        end
    end

    local function place_pois(raw)
        local pois = {}
        if live.conv == "direct" or live.conv == "swapped" then
            local me = units.player_position and units.player_position()
            for i = 1, #raw do
                local p = raw[i]
                local wx, wy = to_world(p.map, p.x, p.y)
                if live.quests[p.id] and wx then
                    local list = pois[p.id] or {}
                    pois[p.id] = list
                    list[#list + 1] = { x = wx, y = wy, z = me and me.z or 0, source = p.source, done = p.done }
                end
            end
        end
        live.pois = pois
    end

    local said = nil

    local function parse_log(text, why)
        live_stats.logs = live_stats.logs + 1
        if not text then
            live_stats.failed = live_stats.failed + 1
            live_stats.last_error = why
            trace("the quest log run failed: " .. tostring(why))
            return
        end
        local qs, order, by_title, raw, errs = {}, {}, {}, {}, {}
        local map, count, how = nil, nil, nil
        for line in text:gmatch("[^\n]+") do
            local f = fields(line)
            local k = f[1]
            if k == "Q" then
                local id = tonumber(f[2])
                if id then
                    local q = { id = id, complete = f[3] == "1", title = f[4] or "", objectives = {} }
                    qs[id] = q
                    order[#order + 1] = q
                    if q.title ~= "" then by_title[q.title:lower()] = q end
                end
            elseif k == "O" then
                local q = qs[tonumber(f[2])]
                if q then
                    local o = { index = tonumber(f[3]), type = f[4] or "", finished = f[5] == "1",
                        have = tonumber(f[6]), need = tonumber(f[7]), text = f[8] or "" }
                    local what, h, n = progress_of(o.text)
                    if not o.need or o.need == 0 then o.have, o.need = h or o.have, n or o.need end
                    o.subject = subject_of(what or o.text)
                    o.kind = KIND[o.type] or "other"
                    if o.finished and o.need then o.have = o.need end
                    q.objectives[#q.objectives + 1] = o
                end
            elseif k == "N" then
                count, how = tonumber(f[2]), f[3]
            elseif k == "M" then
                map = { id = tonumber(f[2]), x = tonumber(f[3]), y = tonumber(f[4]) }
            elseif k == "P" then
                local id, x, y, m = tonumber(f[2]), tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
                if id and x and y and m then
                    raw[#raw + 1] = { id = id, x = x, y = y, map = m, source = f[6], done = f[7] == "1" }
                end
            elseif k == "E" then
                errs[#errs + 1] = (f[2] or "?") .. ": " .. (f[3] or "")
            end
        end
        live.quests, live.order, live.by_title, live.map = qs, order, by_title, map
        live.count, live.how, live.errors = count, how, errs
        live.ok, live.at = true, now()
        calibrate()
        place_pois(raw)
        sync_store()
        local placed = 0
        for _ in pairs(live.pois) do placed = placed + 1 end
        local line = string.format("log: %s quests via %s, map %s, conversion %s (%s yd), %d areas from %d points%s",
            tostring(#order), tostring(how), tostring(map and map.id), tostring(live.conv),
            live.conv_error and string.format("%.0f", live.conv_error) or "-", placed, #raw,
            #errs > 0 and (", errors: " .. table.concat(errs, "; ")) or "")
        if line ~= said then
            said = line
            trace(line)
        end
    end

    --- A unit's tooltip lines: a line naming one of your quests, then the
    --- objective lines under it.
    local function read_lines(u, joined)
        if type(joined) ~= "string" or joined == "" then return end
        local cur = nil
        for raw in joined:gmatch("[^\031]+") do
            local text = trim(raw:match("^[^:]*:(.*)$") or raw)
            local q = live.by_title[text:lower()]
            if q then
                cur = q
                u.quest = u.quest or q
            elseif cur and text ~= "" and not u.objective then
                local what, have, need = progress_of((text:gsub("^%-%s*", "")))
                if what then
                    u.objective = { quest = cur, subject = subject_of(what), have = have, need = need }
                end
            end
        end
    end

    local function parse_units(text, why)
        live_stats.unit_runs = live_stats.unit_runs + 1
        if not text then
            live_stats.failed = live_stats.failed + 1
            live_stats.last_error = why
            return
        end
        local t = now()
        local n, related, plates, links = 0, 0, 0, 0
        for line in text:gmatch("[^\n]+") do
            local f = fields(line)
            if f[1] == "U" and f[2] and f[2] ~= "" then
                local u = { at = t, rel = f[3] == "1", name = (f[4] ~= "" and f[4] ~= "nil") and f[4] or nil, src = f[5] }
                read_lines(u, f[6])
                live.units[f[2]] = u
                n = n + 1
                if u.rel or u.quest then related = related + 1 end
                if u.src == "plate" then plates = plates + 1 elseif u.src == "link" then links = links + 1 end
            elseif f[1] == "I" then
                local id = tonumber(f[2])
                if id and f[3] and f[3] ~= "" then live.items[id] = f[3] end
            end
        end
        live_stats.units, live_stats.related = n, related
        live_stats.plates, live_stats.links = plates, links
    end

    local function units_body(guids, items)
        local g, it = {}, {}
        for i = 1, #guids do g[i] = string.format("%q", guids[i]) end
        for i = 1, #items do it[i] = tostring(math.floor(items[i])) end
        return "local wanted = {" .. table.concat(g, ",") .. "} local items = {" .. table.concat(it, ",") .. "}\n"
            .. UNITS_BODY
    end
    M._units_body = units_body
    M._quest_body = QUEST_BODY

    --- The nearest units the game has not told us about lately.
    local function link_candidates()
        local list = units and units.units and units.units() or {}
        local t = now()
        local cand = {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot and units.snapshot(obj) or nil
            if row and not row.is_player and not row.dead and not row.is_self and (row.dist or 99) <= LINK_RANGE then
                local guid = units.guid(obj)
                local u = guid and live.units[guid]
                if guid and (not u or (t - u.at) > LINK_AGAIN) then
                    cand[#cand + 1] = { guid = guid, d = row.dist or 99 }
                end
            end
        end
        table.sort(cand, function(a, b) return a.d < b.d end)
        local out = {}
        for i = 1, math.min(#cand, MAX_LINK_UNITS) do out[i] = cand[i].guid end
        return out
    end

    local units_said_at = -1e9

    local function one_line(s) return (tostring(s or ""):gsub("[\t\n\r]", " ")) end

    --- The 2026-10-06 core (1.82.0): the same N / Q / O lines QUEST_BODY
    --- writes, from the core's own quest-ID readers, for when the bridge is
    --- not up (on Forever its probe has failed every session since
    --- 2026-10-03). No M or P lines: the map, the quest areas and the unit
    --- tooltips are the bridge's alone. nil on a core without the readers.
    local function core_log_text()
        local q = quests_api()
        local list_fn = q and q.get_quest_log_quest_ids
        local obj_fn = q and q.get_quest_objectives
        if type(list_fn) ~= "function" or type(obj_fn) ~= "function" then return nil end
        local ok, ids = pcall(list_fn)
        if not ok or type(ids) ~= "table" then return nil end
        -- Titles from the log's own rows, which the same core answers there.
        local titles = {}
        local count_fn, title_fn = q.get_num_quest_log_entries, q.get_quest_log_title
        if type(count_fn) == "function" and type(title_fn) == "function" then
            local n = tonumber(call(count_fn)) or 0
            for i = 1, n do
                local row = call(title_fn, i)
                local id = type(row) == "table" and not row.is_header and tonumber(row.quest_id) or nil
                if id and type(row.title) == "string" and row.title ~= "" then titles[id] = row.title end
            end
        end
        local lines = { "N\t" .. #ids .. "\tcore" }
        for i = 1, #ids do
            local id = tonumber(ids[i])
            if id and id > 0 then
                local done = call(q.is_quest_complete, id) == true
                lines[#lines + 1] = "Q\t" .. id .. "\t" .. (done and 1 or 0) .. "\t"
                    .. one_line(titles[id] or db_name("quest", id))
                local objs = call(obj_fn, id)
                if type(objs) == "table" then
                    for j = 1, #objs do
                        local o = objs[j]
                        if type(o) == "table" then
                            lines[#lines + 1] = "O\t" .. id .. "\t" .. j .. "\t" .. one_line(o.type) .. "\t"
                                .. (o.finished and 1 or 0) .. "\t" .. tostring(tonumber(o.fulfilled) or "") .. "\t"
                                .. tostring(tonumber(o.required) or "") .. "\t" .. one_line(o.text)
                        end
                    end
                end
            end
        end
        return table.concat(lines, "\n")
    end
    M._core_log_text = core_log_text

    local function live_tick()
        if not (gl and type(gl.ready) == "function" and gl.ready()) then
            local t = now()
            if (t - log_at) >= LOG_EVERY then
                local text = core_log_text()
                if text then
                    log_at = t
                    parse_log(text)
                end
            end
            return
        end
        local t = now()
        if (t - log_at) >= LOG_EVERY then
            if gl.run("aio_ql", QUEST_BODY, parse_log) then log_at = t end
        end
        if (t - units_at) >= UNITS_EVERY then
            local items = {}
            for id in pairs(item_wanted) do
                items[#items + 1] = id
                item_wanted[id] = nil
                if #items >= ITEM_ASK then break end
            end
            if gl.run("aio_qu", units_body(link_candidates(), items), parse_units) then units_at = t end
        end
        if (t - swept_at) >= 10 then
            swept_at = t
            for guid, u in pairs(live.units) do
                if (t - u.at) > 30 then live.units[guid] = nil end
            end
        end
        if live_stats.unit_runs > 0 and (t - units_said_at) >= 15 then
            units_said_at = t
            trace(string.format("units: %d answered (%d by nameplate, %d by guid), %d on a quest; items named %d",
                live_stats.units, live_stats.plates, live_stats.links, live_stats.related,
                (function() local c = 0 for _ in pairs(live.items) do c = c + 1 end return c end)()))
        end
    end

    -- M.refresh runs every ESP frame on Forever: the live runs ride on it.
    local refresh_before = M.refresh
    function M.refresh()
        pcall(live_tick)
        return refresh_before()
    end

    --- The live objective of a quest that a subject names (as is, plural,
    --- singular).
    local function live_objective(q, subject)
        if not q or not subject then return nil end
        local f = forms(subject)
        for i = 1, #q.objectives do
            local o = q.objectives[i]
            for k = 1, #f do
                if o.subject == f[k] then return o end
            end
        end
        return nil
    end

    local function chip(kind, have, need, q)
        local word = WORD[kind or "other"] or "QUEST"
        local text = word
        if have and need and need > 0 then text = string.format("%s %d/%d", word, have, need) end
        -- kind, have and need for the icon card (1.69.0): the objective's
        -- icon and its count, apart from the word.
        return { text = text, title = q and q.title or nil, qid = q and q.id or nil,
            kind = kind or "other", have = have, need = need }
    end

    --- What a unit is to your quests, or nil: from what the game said about
    --- it (its tooltip, or its quest relation), then from what its kind drops
    --- for quests (the creature cache) against the unfinished item
    --- objectives.
    ---@param guid string|nil
    ---@param npc_id integer|nil
    ---@return table|nil { text, title, qid }
    function M.unit(guid, npc_id)
        local t = now()
        local u = guid and live.units[guid]
        if u and (t - u.at) <= UNIT_TTL then
            if u.objective then
                local q = u.objective.quest
                local o = live_objective(q, u.objective.subject)
                local have = o and o.have or u.objective.have
                local need = o and o.need or u.objective.need
                if not (have and need and have >= need) then
                    return chip(o and o.kind or "other", have, need, q)
                end
            elseif u.quest and not u.quest.complete then
                return chip("other", nil, nil, u.quest)
            elseif u.rel then
                return chip("other")
            end
        end
        npc_id = tonumber(npc_id)
        if not (creatures and creatures.info and npc_id and npc_id > 0) then return nil end
        local ok, info = pcall(creatures.info, npc_id)
        local items = ok and type(info) == "table" and info.quest_items or nil
        if type(items) ~= "table" then return nil end
        for i = 1, #items do
            local id = items[i]
            local name = live.items[id]
            if name then
                local o = M.objective(name)
                if o and o.kind == "item" then
                    local s = data.objectives[o.subject]
                    return chip("item", o.have, o.need, s and s.quest and live.quests[s.quest] or nil)
                end
            elseif id then
                item_wanted[id] = true
            end
        end
        return nil
    end

    --- The game's name for a unit, from a nameplate, the target or a tooltip.
    ---@param guid string|nil
    ---@return string|nil
    function M.unit_name(guid)
        local u = guid and live.units[guid]
        local n = u and u.name
        if type(n) ~= "string" or n == "" or n == "Unknown" or n == "Unknown Being" then return nil end
        return n
    end

    --- One place per quest with an area placed on the world: the area on
    --- this map before a waypoint elsewhere.
    ---@return table[] { quest, x, y, z, done, source }
    function M.locations()
        local out = {}
        if not live.ok then return out end
        for i = 1, #live.order do
            local q = live.order[i]
            local list = live.pois[q.id]
            if list then
                local best = nil
                for k = 1, #list do
                    local p = list[k]
                    if not best or (best.source == "waypoint" and p.source ~= "waypoint") then best = p end
                end
                if best then
                    out[#out + 1] = { quest = q, x = best.x, y = best.y, z = best.z, done = q.complete,
                        source = best.source, poi = best }
                end
            end
        end
        return out
    end

    local stats_before = M.stats
    function M.stats()
        local s = stats_before()
        local placed = 0
        for _ in pairs(live.pois) do placed = placed + 1 end
        s.live = live.ok
        s.live_quests = #live.order
        s.live_how = live.how
        s.live_conv = live.conv
        s.live_areas = placed
        s.live_units = live_stats.units
        s.live_related = live_stats.related
        s.live_failed = live_stats.failed
        s.live_error = live_stats.last_error
        s.bridge = gl and gl.state and (gl.state()) or "none"
        return s
    end

    M.data = data
    return M
end

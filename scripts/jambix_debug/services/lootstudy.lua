-- JAMBIX DEBUG (1.0.0): moved here from JCore's services/lootstudy.lua with JCore
-- 1.7.0, so users do not get it. Still a factory of JCore's runtime, built by
-- JCore's main.lua when this plugin is there (see jambix_debug/main.lua). Its
-- page sits under "Jambix Debug" in the sidebar; its files stay in
-- scripts_data/jcore/, so the tools in tools/jcheck read them as before.
--
-- Jambix Debug / lootstudy -- how the game marks a corpse that has loot, and how a
-- loot window comes to be opened (JCore 1.6.8). Written for the question
-- (2026-10-03): "I need to dump how the game identifies corpse has loot, and
-- how players open corpses".
--
-- CORPSES. Every dead unit that is not a player, within REACH yards, is read
-- every EVERY seconds: each read in READS (only no-argument getters the API
-- recorder has seen answer on Forever without an error). The first answers
-- are kept, then every change, with when and what was going on at that
-- moment ("when"):
--   at death      it was seen alive within the last 2 s
--   window open   a loot window from this corpse is open
--   after window  within 3 s of its window closing
--   skinning      within 6 s of a skinning cast starting on it
--   -             none of those
-- The summary tallies read, change and moment over every corpse, and the
-- first answers of corpses that were opened against those never opened:
-- which read tells a corpse with loot from an empty one.
--
-- WINDOWS. Each LOOT_OPENED: whether JCore's loot.open had a press waiting
-- (ours, and with which call) or not (the player's own right-click or
-- interact key, a bag item, a node); what the unit tokens point at
-- (mouseover, target, softinteract, softenemy, softfriend, npc, focus) and
-- get_mouse_over_object; every corpse within NEAR yards with its reads; the
-- player (moving, casting); the last HISTORY seconds of game events, of our
-- own "loot:" / "auto-loot:" trace lines, and of what the pointer and tokens
-- pointed at; the slots 0..count, read at the open and again 0.3 s and 1 s
-- later (the window is not filled on the frame that opens it, and slot
-- count+1 shows whether the slots are really 0 based); the slot count each
-- time it changes while open; and the source corpse's reads at the close and
-- 1 s and 3 s after.
--
-- MISSES (1.6.11). A press of JCore's loot.open that brought nothing
-- ("jcore.loot.nothing") is recorded too: the call, whether it walked and
-- whether the corpse was targeted first, the corpse's reads, the pointers,
-- the player, and the events from 2 s before the press until it was given
-- up -- the record a window gets, for the presses that got no window.
--
-- EVERY CLIENT. The user (2026-10-03): "experiment the way SoD does it,
-- Retail does it". Forever is the classic world on the retail engine, so the
-- same study on Season of Discovery (the Vanilla client: Era, Hardcore and
-- SoD cannot be told apart) and on Retail says which of the two Forever
-- follows: the reads that mark a corpse with loot, and how a player opens
-- one there. So it runs on every client unless the Dump page's switch is
-- turned off, and each client writes its own file:
-- scripts_data/jcore/jcore.lootstudy.<client>.json, WRITE_AFTER seconds
-- after each loot window closes, and from the Dump page. Compare them with
--   node tools/jcheck/lootstudy_diff.js scripts_data/jcore/jcore.lootstudy.*.json
-- Only getters are called.

local READS = { "has_loot", "can_be_looted", "can_be_skinned", "has_skin", "can_be_used", "is_tap_denied",
    "get_npc_flags", "get_npc_flags2", "get_state_flags", "is_dead", "is_visible", "get_health",
    "is_in_combat", "get_target_marker_index" }
local TOKENS = { "mouseover", "target", "softinteract", "softenemy", "softfriend", "npc", "focus" }
local REACH = 40            -- yd: corpses studied
local NEAR = 6              -- yd: corpses listed with a window
local EVERY = 0.25          -- s between corpse reads
local HISTORY = 4.0         -- s of events and pointer kept with a window
local KEEP_CORPSES = 40
local KEEP_WINDOWS = 40
local MAX_CHANGES = 80      -- per corpse
local MAX_HISTORY = 200
local MAX_SLOTS = 12
local LATER = { 0.3, 1.0 }  -- s after the open: the slots again
local AFTER = { 1.0, 3.0 }  -- s after the close: the corpse again
local WRITE_AFTER = 3.5
local QUIET = { COMBAT_LOG_EVENT_UNFILTERED = true }
local SKINNING = 8613
local SAME_WINDOW = 0.5     -- s: Forever sends LOOT_OPENED twice per window (1.6.10)

local function round(x, places)
    if type(x) ~= "number" then return x end
    local p = 10 ^ (places or 2)
    return math.floor(x * p + 0.5) / p
end

local function short(guid)
    if guid == nil then return nil end
    return tostring(guid):sub(-10)
end

--- A read's answer as a JSON value: nil becomes "nil", so a change from or
--- to nothing still shows and no array gets a hole.
local function show(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if t == "boolean" or t == "string" then return v end
    return "(" .. t .. ")"
end

return function(rt)
    local log = rt.log.for_tag("JambixDebug/lootstudy")
    local events = rt.events
    local units = rt.units

    local M = {}

    local function now() return core.time() end
    local started = now()
    local function rel(t) return round(t - started, 2) end

    local function call(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, a = pcall(fn, ...)
        if ok then return a end
        return nil
    end

    local function method(obj, name)
        if obj == nil then return nil end
        local ok_f, fn = pcall(function() return obj[name] end)
        if not ok_f or type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, obj)
        if ok then return v end
        return nil
    end

    local function read_all(obj)
        local out = {}
        for i = 1, #READS do out[READS[i]] = show(method(obj, READS[i])) end
        return out
    end

    local function client()
        local world = rt.world
        local c = world and world.client and call(world.client)
        return type(c) == "table" and c or {}
    end

    local function client_tag()
        local v = tostring(client().version or "")
        if v == "" then return "unknown" end
        return (v:lower():gsub("[^%w]", ""))
    end

    local override = nil        -- the Dump page's switch, once it has said
    --- Is the study running? On every client unless the Dump page's switch
    --- has been turned off.
    function M.enabled()
        if override ~= nil then return override end
        return true
    end
    function M.set_enabled(on) override = on and true or false end

    local corpses = {}          -- full guid -> timeline
    local order = {}            -- full guids, oldest first
    local alive_seen = {}       -- full guid -> when last seen alive in reach
    local windows = {}
    local misses = {}           -- presses that brought nothing (1.6.11)
    local history = {}          -- { t, text }, oldest first
    local open = nil            -- the window open now
    local afters = {}           -- { at, w, guid, after }
    local write_at = nil
    local last_poll, last_prune = -1e9, -1e9
    local last_pointer = nil
    local cast_ended = nil      -- { at, spell }: the player's last finished cast
    local skinning = nil        -- { guid, at }
    local stats = { corpses = 0, changes = 0, windows = 0, written = 0 }

    local function push(t, text)
        history[#history + 1] = { t = t, text = text }
        if #history > MAX_HISTORY then table.remove(history, 1) end
    end

    local function find(guid_or_token)
        local om = core.object_manager
        local obj = call(om and om.get_object_from_guid, guid_or_token)
        if obj and method(obj, "is_valid") == false then return nil end
        return obj
    end

    local function distance(obj)
        local me = units.player_position and units.player_position()
        local pos = method(obj, "get_position")
        if type(me) ~= "table" or type(pos) ~= "table" or not (me.x and pos.x) then return nil end
        local dx, dy, dz = pos.x - me.x, pos.y - me.y, (pos.z or 0) - (me.z or 0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- What one pointer names: the guid, dead or not, how far.
    local function describe(obj)
        if not obj then return nil end
        local guid = method(obj, "get_guid")
        if not guid then return nil end
        return { guid = short(guid), full = guid, dead = method(obj, "is_dead") == true,
            unit = method(obj, "is_unit") == true, d = round(distance(obj), 1) }
    end

    --- Every pointer the client offers, now.
    local function pointers()
        local out = {}
        for i = 1, #TOKENS do out[TOKENS[i]] = describe(find(TOKENS[i])) end
        local om = core.object_manager
        out.get_mouse_over_object = describe(call(om and om.get_mouse_over_object))
        return out
    end

    local function pointer_text(p)
        local parts = {}
        local names = { "get_mouse_over_object" }
        for i = 1, #TOKENS do names[#names + 1] = TOKENS[i] end
        for i = 1, #names do
            local d = p[names[i]]
            if d then
                parts[#parts + 1] = string.format("%s=%s%s%s", names[i], d.guid, d.dead and "(dead)" or "",
                    d.d and string.format("@%.1f", d.d) or "")
            end
        end
        return #parts > 0 and table.concat(parts, " ") or "nothing"
    end

    -- --- corpses --------------------------------------------------------------

    local function when(guid, t)
        local c = corpses[guid]
        if open and open.guid == guid then return "window open" end
        if c and c.closed_at and t - c.closed_at <= 3 then return "after window" end
        if skinning and skinning.guid == guid and t - skinning.at <= 6 then return "skinning" end
        if c and c.died_at and t - c.died_at <= 2 then return "at death" end
        return "-"
    end

    local function remember(guid, c)
        corpses[guid] = c
        order[#order + 1] = guid
        stats.corpses = stats.corpses + 1
        while #order > KEEP_CORPSES do
            local old = table.remove(order, 1)
            corpses[old] = nil
        end
    end

    local function observe(obj, row, t)
        local guid = row.guid
        local reads = read_all(obj)
        local c = corpses[guid]
        if not c then
            local seen = alive_seen[guid]
            c = {
                guid = short(guid), npc = show(method(obj, "get_npc_id")), name = show(method(obj, "get_name")),
                first_seen = rel(t), d = round(row.dist, 1),
                seen_die = seen ~= nil and (t - seen) <= 2,
                first = reads, changes = {}, windows = {},
            }
            if c.seen_die then c.died_at = t end
            c.last = reads
            remember(guid, c)
            return
        end
        c.last_seen, c.d = rel(t), round(row.dist, 1)
        for i = 1, #READS do
            local k = READS[i]
            local was, is = c.last[k], reads[k]
            if was ~= is then
                stats.changes = stats.changes + 1
                if #c.changes < MAX_CHANGES then
                    c.changes[#c.changes + 1] = { t = rel(t), read = k, from = was, to = is, when = when(guid, t),
                        d = round(row.dist, 1) }
                end
            end
        end
        c.last = reads
    end

    -- --- windows --------------------------------------------------------------

    local function read_slots()
        local ui = core.game_ui
        local n = tonumber((call(ui and ui.get_loot_item_count))) or 0
        local slots = {}
        for i = 0, math.min(n, MAX_SLOTS) do
            slots[#slots + 1] = {
                slot = i,
                id = show(call(ui.get_loot_item_id, i)),
                name = show(call(ui.get_loot_item_name, i)),
                gold = show(call(ui.get_loot_is_gold, i)),
            }
        end
        return n, slots
    end

    local function near_corpses()
        local out = {}
        local list = units.units and units.units() or {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot(obj)
            if row and row.dead and not row.is_player and not row.is_self and (row.dist or 1e9) <= NEAR then
                out[#out + 1] = { guid = short(row.guid), full = row.guid, d = round(row.dist, 1),
                    npc = show(method(obj, "get_npc_id")), reads = read_all(obj) }
            end
        end
        table.sort(out, function(a, b) return a.d < b.d end)
        return out
    end

    --- Where the window came from, as far as can be told, and the corpse.
    local function source_of(w, attempt, p, near, t)
        if w.from_item == true then return "a bag item", nil end
        if attempt and attempt.pending then
            return "ours: " .. tostring(attempt.call), attempt.guid
        end
        if cast_ended and t - cast_ended.at <= 2 then
            local guid = attempt and attempt.kind == "skin" and attempt.guid or (near[1] and near[1].full) or nil
            return "a cast of the player's (spell " .. tostring(cast_ended.spell) .. ")", guid
        end
        local function dead_pointer(name, label)
            local d = p[name]
            if d and d.dead and d.unit and (d.d or 1e9) <= NEAR + 2 then return label, d.full end
        end
        local label, guid = dead_pointer("get_mouse_over_object", "player: the corpse under the mouse (right-click)")
        if label then return label, guid end
        label, guid = dead_pointer("mouseover", "player: the mouseover corpse (right-click)")
        if label then return label, guid end
        label, guid = dead_pointer("softinteract", "player: the soft-interact corpse (interact key)")
        if label then return label, guid end
        label, guid = dead_pointer("target", "player: the targeted corpse")
        if label then return label, guid end
        if near[1] then return "player: nearest corpse (nothing pointed at it)", near[1].full end
        return "unknown (no corpse within " .. NEAR .. " yd: a node or chest?)", nil
    end

    events.on("jcore.game_event.LOOT_OPENED", function(args)
        if not M.enabled() then return end
        local t = now()
        -- The same window's second event (1.6.10): counted on it, not a new one.
        if open and t - open.t < SAME_WINDOW then
            open.w.events = (open.w.events or 1) + 1
            return
        end
        args = type(args) == "table" and args or {}
        local w = { at = rel(t), autoloot = show(args[1]), from_item = show(args[2]), events = 1 }
        local loot = rt.loot
        local attempt = loot and loot.attempt and call(loot.attempt) or nil
        if attempt and t - (attempt.at or -1e9) > 8 then attempt = nil end
        if attempt then
            w.our_press = { kind = attempt.kind, call = attempt.call, corpse = short(attempt.guid),
                seconds_before = round(t - attempt.at, 2), walked = attempt.walked == true,
                targeted = attempt.targeted == true, still_waiting = attempt.pending == true }
        end
        local p = pointers()
        local near = near_corpses()
        local source, guid = source_of(w, attempt, p, near, t)
        w.source, w.corpse = source, short(guid)
        for _, d in pairs(p) do d.full = nil end
        w.pointers = p
        for i = 1, #near do near[i].full = nil end
        w.near = near
        local me = units.player and units.player()
        w.player = { moving = show(method(me, "is_moving")), casting = show(method(me, "get_active_spell_id")),
            channel = show(method(me, "get_active_channel_spell_id")), in_combat = show(method(me, "is_in_combat")) }
        local n, slots = read_slots()
        w.slots = { { after = 0, count = n, slots = slots } }
        w.counts = { { t = 0, n = n } }
        local h = {}
        for i = 1, #history do
            local e = history[i]
            if t - e.t <= HISTORY then h[#h + 1] = string.format("%+.2f %s", e.t - t, e.text) end
        end
        w.history = h
        windows[#windows + 1] = w
        while #windows > KEEP_WINDOWS do table.remove(windows, 1) end
        stats.windows = stats.windows + 1
        local c = guid and corpses[guid] or nil
        if c then c.windows[#c.windows + 1] = w.at; c.opened = true end
        open = { w = w, t = t, guid = guid, later = 1, count = n }
    end, { owner = "jcore.lootstudy", priority = -10 })

    events.on("jcore.game_event.LOOT_CLOSED", function()
        local o = open
        if not o then return end
        open = nil
        local t = now()
        local w = o.w
        w.open_for = round(t - o.t, 2)
        local ui = core.game_ui
        local n = tonumber((call(ui and ui.get_loot_item_count))) or 0
        w.counts[#w.counts + 1] = { t = round(t - o.t, 2), n = n, closed = true }
        if o.guid then
            local obj = find(o.guid)
            w.after = { { after = 0, reads = obj and read_all(obj) or "gone" } }
            for i = 1, #AFTER do afters[#afters + 1] = { at = t + AFTER[i], w = w, guid = o.guid, after = AFTER[i] } end
            local c = corpses[o.guid]
            if c then c.closed_at = t end
        end
        write_at = t + WRITE_AFTER
    end, { owner = "jcore.lootstudy", priority = -10 })

    events.on("jcore.loot.nothing", function(a)
        if not M.enabled() or type(a) ~= "table" then return end
        local t = now()
        local at = tonumber(a.at) or t
        local obj = a.guid and find(a.guid) or nil
        local m = { at = rel(t), kind = a.kind, call = a.call, corpse = short(a.guid), seconds = round(t - at, 2),
            walked = a.walked == true, targeted = a.targeted == true,
            d = round(obj and distance(obj) or nil, 1), reads = obj and read_all(obj) or "gone" }
        local p = pointers()
        for _, d in pairs(p) do d.full = nil end
        m.pointers = p
        local me = units.player and units.player()
        m.player = { moving = show(method(me, "is_moving")), casting = show(method(me, "get_active_spell_id")),
            in_combat = show(method(me, "is_in_combat")) }
        local h = {}
        for i = 1, #history do
            local e = history[i]
            if e.t >= at - 2 then h[#h + 1] = string.format("%+.2f %s", e.t - at, e.text) end
        end
        m.history = h
        misses[#misses + 1] = m
        while #misses > KEEP_WINDOWS do table.remove(misses, 1) end
        stats.misses = (stats.misses or 0) + 1
        write_at = write_at or (t + WRITE_AFTER)
    end, { owner = "jcore.lootstudy", priority = -10 })

    -- Every game event, briefly, for the history a window carries.
    events.on("jcore.game_event", function(name, args)
        if not M.enabled() or QUIET[name] then return end
        local parts = {}
        if type(args) == "table" then
            for i = 1, 4 do
                local v = args[i]
                if v ~= nil then parts[#parts + 1] = tostring(v):sub(1, 40) end
            end
        end
        push(now(), #parts > 0 and (tostring(name) .. " " .. table.concat(parts, ", ")) or tostring(name))
    end, { owner = "jcore.lootstudy", priority = -10 })

    -- Our own presses (JCore's loot.open, the AIO's auto-loot), as the trace has them.
    events.on("jcore.recorder.trace", function(text)
        if not M.enabled() or type(text) ~= "string" then return end
        if text:sub(1, 5) == "loot:" or text:sub(1, 10) == "auto-loot:" then push(now(), text) end
    end, { owner = "jcore.lootstudy", priority = -10 })

    events.on("jcore.game_event.UNIT_SPELLCAST_START", function(args)
        if not M.enabled() or type(args) ~= "table" or args[1] ~= "player" then return end
        if tonumber(args[3]) ~= SKINNING then return end
        local loot = rt.loot
        local attempt = loot and loot.attempt and call(loot.attempt) or nil
        local guid = attempt and attempt.kind == "skin" and attempt.guid or nil
        if not guid then
            local near = near_corpses()
            guid = near[1] and near[1].full or nil
        end
        if guid then skinning = { guid = guid, at = now() } end
    end, { owner = "jcore.lootstudy", priority = -10 })

    events.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
        if type(args) ~= "table" or args[1] ~= "player" then return end
        cast_ended = { at = now(), spell = args[3] }
    end, { owner = "jcore.lootstudy", priority = -10 })

    -- --- the tick -------------------------------------------------------------

    function M._poll()
        if not M.enabled() then return end
        local t = now()

        local o = open
        if o then
            local ui = core.game_ui
            local n = tonumber((call(ui and ui.get_loot_item_count))) or 0
            if n ~= o.count then
                o.count = n
                o.w.counts[#o.w.counts + 1] = { t = round(t - o.t, 2), n = n }
            end
            local due = LATER[o.later]
            if due and t - o.t >= due then
                o.later = o.later + 1
                local count, slots = read_slots()
                o.w.slots[#o.w.slots + 1] = { after = due, count = count, slots = slots }
            end
        end

        for i = #afters, 1, -1 do
            local a = afters[i]
            if t >= a.at then
                table.remove(afters, i)
                local obj = find(a.guid)
                a.w.after[#a.w.after + 1] = { after = a.after, reads = obj and read_all(obj) or "gone" }
            end
        end

        if write_at and t >= write_at then
            write_at = nil
            local ok, err = pcall(M.write)
            if not ok then log.fmt("warn", "lootstudy: could not write: %s", tostring(err)) end
        end

        if t - last_poll < EVERY then return end
        last_poll = t

        local p = pointers()
        local text = pointer_text(p)
        if text ~= last_pointer then
            last_pointer = text
            push(t, "pointer: " .. text)
        end

        local list = units.units and units.units() or {}
        for i = 1, #list do
            local obj = list[i]
            local row = units.snapshot(obj)
            if row and row.guid and not row.is_player and not row.is_self and (row.dist or 1e9) <= REACH then
                if row.dead then observe(obj, row, t) else alive_seen[row.guid] = t end
            end
        end

        if t - last_prune >= 10 then
            last_prune = t
            for guid, at in pairs(alive_seen) do
                if t - at > 30 then alive_seen[guid] = nil end
            end
        end
    end

    -- --- the file ---------------------------------------------------------------

    local function tally_add(map, key)
        map[key] = (map[key] or 0) + 1
    end

    local function sorted(map)
        local out = {}
        for k, n in pairs(map) do out[#out + 1] = { what = k, n = n } end
        table.sort(out, function(a, b)
            if a.n ~= b.n then return a.n > b.n end
            return a.what < b.what
        end)
        return out
    end

    --- What the corpses and windows add up to.
    function M.summary()
        local changes, sources = {}, {}
        local first = { opened = {}, never_opened = {} }
        local n_corpses = 0
        for i = 1, #order do
            local c = corpses[order[i]]
            if c then
                n_corpses = n_corpses + 1
                for j = 1, #c.changes do
                    local ch = c.changes[j]
                    tally_add(changes, string.format("%s %s -> %s (%s)", ch.read, tostring(ch.from), tostring(ch.to), ch.when))
                end
                local side = c.opened and first.opened or first.never_opened
                for k, v in pairs(c.first or {}) do
                    side[k] = side[k] or {}
                    tally_add(side[k], tostring(v))
                end
            end
        end
        for i = 1, #windows do tally_add(sources, windows[i].source or "?") end
        local missed = {}
        for i = 1, #misses do
            local m = misses[i]
            local target = m.pointers and m.pointers.target
            tally_add(missed, string.format("%s%s%s, target %s", tostring(m.call), m.walked and ", walked" or "",
                m.targeted and ", targeted first" or "",
                target and (target.guid == m.corpse and "the corpse" or "another unit") or "none"))
        end
        return {
            corpses = n_corpses, windows = #windows, misses = #misses,
            changes = sorted(changes), sources = sorted(sources), missed = sorted(missed),
            first_reads = first,
        }
    end

    --- Writes the study. Returns the file name, or nil and why.
    function M.write()
        local c = client()
        local list = {}
        for i = 1, #order do
            local x = corpses[order[i]]
            if x then
                list[#list + 1] = {
                    guid = x.guid, npc = x.npc, name = x.name, first_seen = x.first_seen, last_seen = x.last_seen,
                    d = x.d, seen_die = x.seen_die, opened = x.opened == true, windows = x.windows,
                    first = x.first, last = x.last, changes = x.changes,
                }
            end
        end
        local doc = {
            format = 1, jcore = rt.VERSION, client = show(c.version), exact = show(c.exact),
            reads = READS, tokens = TOKENS,
            summary = M.summary(), windows = windows, misses = misses, corpses = list,
        }
        local filename = "jcore/jcore.lootstudy." .. client_tag() .. ".json"
        local storage = rt.storage
        if not (storage and storage.write_json) then return nil, "no storage" end
        if not storage.write_json(filename, doc, true) then
            stats.error = "could not write " .. filename
            return nil, stats.error
        end
        stats.written, stats.file, stats.error = stats.written + 1, filename, nil
        return filename
    end

    function M.stats()
        return { enabled = M.enabled(), corpses = stats.corpses, changes = stats.changes, windows = stats.windows,
            misses = stats.misses or 0,
            written = stats.written, file = stats.file, error = stats.error }
    end

    return M
end

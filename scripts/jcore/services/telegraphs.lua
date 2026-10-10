-- JCore / telegraphs -- where an enemy's spell is about to land (JCore 1.8.0).
--
-- Depends on: util, log, events, units, enemies, missiles, geometry, storage.
--
-- WHAT IT KNOWS
-- scripts_data/jcore/telegraphs/<client>/, written offline by
--
--   node tools/jcheck/telegraph_extract.js
--
-- from three sources merged per spell id: the client's own spell tables (the
-- shape: a circle around the caster, a circle where it aims, a cone in front,
-- how far, how wide, whether the ground stays bad afterwards), DBM's boss mods
-- (what to do about it: dodge, run out, interrupt; how dangerous) and Plater's
-- cast scripts. Files are read on first use, a 1000-id bucket at a time, like
-- questdb. Forever reads its own copy (its spell tables differ: Blizzard is an
-- area trigger there); every other client reads the vanilla one.
--
-- WHAT IT ANSWERS, every tick, after enemies and missiles:
--   active()        every live telegraph, those on you first, then by danger
--   on_me()         the ones you are standing in
--   danger_at(pos)  the worst one covering a point (a place to stand, or not)
--   info(spell_id)  the data row for a spell, or nil
--
-- A TELEGRAPH (a live row; read it, do not keep it):
--   key, spell_id, name, phase   "cast" | "channel" | "missile" | "linger" | "aura" | "hit"
--   shape    "circle" | "cone" | "none" (no shape: an alert only)
--   anchor   "caster" | "target" | "dest" | "front" | "fixed" | "player"
--   placed   false when the client cannot say where it lands: draw no ground
--   wide     a circle as big as the room (40 yd or more): an alert, not a circle
--   pos      vec3 centre (a cone's apex); x, y, z the same
--   towards  vec3, for a cone: the point straight ahead at its radius
--   facing, radius, degrees, width
--   progress 0..1 through the cast or flight, remaining seconds (nil: unknown)
--   level    1 the spell tables alone, 2 a boss mod warns of it, 3 a boss mod
--            says move for it
--   hint     what to do ("Dodge", "Run out", "Breath: get out of the front")
--   inside   the player is in it (with the player's own reach, PAD)
--   dist     yards from the player to the centre or apex
--   source_guid, source (this tick's object or nil), by_player, interruptible
--
-- EVENTS, on transition only:
--   jcore.telegraph.started  a telegraph appeared       (row)
--   jcore.telegraph.on_me    the player stepped into one (row)
--
-- COST. No native call for an enemy that is not casting a known spell. A known
-- cast costs one get_active_spell_target when it starts (shapes placed at the
-- target) and, for a cone, one get_rotation a tick while it lasts. Missiles
-- come from the missiles service's own sweep. The player's auras are read four
-- times a second in combat, from the units service's per-sweep index.

local WIDE = 40              -- yards: as big as the room; an alert, not a circle
local PAD = 1.0              -- yards: the player's own reach, as the server counts it
local LINGER_GRACE = 0.35    -- seconds: a cast that vanished this close to its end completed
local AURA_EVERY = 0.25
local HIT_HOLD = 1.5         -- seconds a combat-log hit keeps its alert up
local MISSILE_NEAR = 30      -- yards: a missile whose caster is unknown counts when it lands this near
local MAX_ACTIVE = 32
local HAZARD_SUBEVENTS = {
    SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true, SPELL_MISSED = true, SPELL_PERIODIC_MISSED = true,
}
local AVOID_KINDS = { dodge = true, run = true, moveaway = true, gtfo = true, move = true, keepmove = true, jump = true, lookaway = true }

return function(rt)
    local events = rt.events
    local units = rt.units
    local enemies = rt.enemies
    local missiles = rt.missiles
    local geometry = rt.geometry
    local log = rt.log.for_tag("JCore/telegraphs")

    local sqrt, atan2, cos, sin, floor, huge = math.sqrt, math.atan2 or math.atan, math.cos, math.sin, math.floor, math.huge
    local pi = math.pi

    local M = {}
    M.WIDE = WIDE
    M.PAD = PAD

    -- --- the data ----------------------------------------------------------

    local state = { base = nil, index = nil, read = false, error = nil, buckets_read = 0, hazards = nil }
    local buckets = {}
    local infos = {}            -- spell id -> row | false

    local function client()
        local world = rt.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        return ok and type(c) == "table" and c or {}
    end

    local function base()
        if state.base then return state.base end
        state.base = "jcore/telegraphs/" .. (client().forever and "forever" or "vanilla")
        return state.base
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
            state.error = "no telegraph data at scripts_data/" .. base() .. " (" .. tostring(err) .. ")"
            log.fmt("info", "telegraphs: %s", state.error)
            return nil
        end
        state.index = value
        local c = value.counts or {}
        log.fmt("info", "telegraphs: %s spells (%s with a shape, %s from DBM) for %s, built %s",
            tostring(c.spells), tostring(c.shaped), tostring(c.dbm), tostring(value.version), tostring(value.build_time))
        return value
    end

    --- The DBM hazards (no cast bar: an aura or a hit on you), by spell id.
    local function hazards()
        if state.hazards then return state.hazards end
        local idx = index()
        local out = {}
        if idx and type(idx.auras) == "table" then
            for k, v in pairs(idx.auras) do
                local id = tonumber(k)
                if id then out[id] = v end
            end
        end
        state.hazards = out
        return out
    end

    local function bucket(id)
        local b = floor(id / 1000)
        local data = buckets[b]
        if data == nil then
            data = false
            local value = read_json(base() .. "/spells/" .. b .. ".json")
            if type(value) == "table" then
                data = value
                state.buckets_read = state.buckets_read + 1
            end
            buckets[b] = data
        end
        return data or nil
    end

    --- What to say about a spell: the boss mod's advice, the most urgent first.
    local function hint_of(row)
        local d = row.dbm
        if type(d) ~= "table" then return nil end
        local idx = index() or {}
        local voice_hints, kind_hints = idx.voice_hints or {}, idx.kind_hints or {}
        local voices, kinds = d.v or {}, d.k or {}
        for i = 1, #voices do
            local h = voice_hints[voices[i]]
            if h then return h end
        end
        for i = 1, #kinds do
            if AVOID_KINDS[kinds[i]] and kind_hints[kinds[i]] then return kind_hints[kinds[i]] end
        end
        for i = 1, #kinds do
            local h = kind_hints[kinds[i]]
            if h then return h end
        end
        return nil
    end

    --- The data row for a spell, or nil. Read-only.
    ---@param spell_id integer
    ---@return table|nil
    function M.info(spell_id)
        spell_id = tonumber(spell_id)
        if not spell_id or spell_id <= 0 then return nil end
        local hit = infos[spell_id]
        if hit ~= nil then return hit or nil end
        if not index() then return nil end
        local data = bucket(spell_id)
        local row = data and (data[tostring(spell_id)] or data[spell_id]) or nil
        if type(row) == "table" then
            row.hint = hint_of(row)
            infos[spell_id] = row
            return row
        end
        infos[spell_id] = false
        return nil
    end

    function M.available() return index() ~= nil end

    -- --- the live list -------------------------------------------------------

    local live = {}             -- key -> telegraph
    local active, n_active = {}, 0
    local on_me_list = {}
    local stats = { casts = 0, missiles = 0, lingering = 0, hazards = 0, hits = 0, started = 0, on_me = 0 }
    local last_aura_check = 0
    local aura_rows = {}        -- spell id -> aura telegraph (refreshed at AURA_EVERY)
    local hits = {}             -- spell id -> { at, hint }
    local missile_first = {}    -- key -> first time to impact seen

    local function vec(x, y, z) return geometry.vec(x, y, z) end

    local function shape_of(info)
        local sh = info.sh
        return type(sh) == "table" and sh or nil
    end

    --- The player-relative bits every telegraph needs, computed once a tick.
    local function finish(t, px, py, pz)
        local dx, dy = (t.x or 0) - px, (t.y or 0) - py
        local d = sqrt(dx * dx + dy * dy)
        t.dist = d
        local inside = false
        if t.placed then
            if t.shape == "circle" then
                inside = d <= (t.radius or 0) + PAD
            elseif t.shape == "cone" then
                if d <= (t.radius or 0) + PAD then
                    if d <= PAD then
                        inside = true
                    else
                        local bearing = atan2(py - t.y, px - t.x)
                        local delta = bearing - (t.facing or 0)
                        while delta > pi do delta = delta - 2 * pi end
                        while delta < -pi do delta = delta + 2 * pi end
                        inside = math.abs(delta) <= math.rad((t.degrees or 60) / 2)
                    end
                end
            end
        elseif t.anchor == "player" then
            inside = true
        end
        local was = t.inside
        t.inside = inside
        if inside and not was then
            stats.on_me = stats.on_me + 1
            events.emit("jcore.telegraph.on_me", t)
        end
        t.pos = vec(t.x or 0, t.y or 0, t.z or 0)
        if t.shape == "cone" and t.facing then
            local r = t.radius or 0
            t.towards = vec(t.x + cos(t.facing) * r, t.y + sin(t.facing) * r, t.z)
        end
    end

    local function new_row(key, spell_id, info, shape, phase, now)
        local t = {
            key = key, spell_id = spell_id, name = info.n, phase = phase,
            shape = shape and shape.k or "none", anchor = shape and shape.at or "fixed",
            radius = shape and shape.r or 0, degrees = shape and shape.d or nil, width = shape and shape.w or nil,
            linger = shape and shape.p or nil,
            level = info.lv or 1, hint = info.hint, kinds = info.dbm and info.dbm.k or nil,
            mods = info.dbm and info.dbm.mods or nil, school = info.s,
            started_at = now, inside = false, placed = false,
        }
        -- Only a circle can be "the room": a cone of any length still has a
        -- side to stand on (Flame Breath reaches 45 yards).
        t.wide = t.shape == "circle" and (t.radius or 0) >= WIDE
        live[key] = t
        stats.started = stats.started + 1
        return t
    end

    local function emit_started(t)
        events.emit("jcore.telegraph.started", t)
    end

    --- Where a unit is this tick, by guid, from the sweep.
    local function where(guid)
        if not guid then return nil end
        local obj = units.by_guid(guid)
        if not obj then return nil end
        local pos = units.position(obj)
        if not pos then return nil end
        return pos.x, pos.y, pos.z
    end

    local function is_player_row(row)
        local snap = row.obj and units.snapshot(row.obj)
        return snap ~= nil and snap.is_player == true
    end

    -- casts and channels ------------------------------------------------------

    local function place_cast(t, row, cast)
        local at = t.anchor
        if at == "caster" then
            t.x, t.y, t.z, t.placed = row.x, row.y, row.z, true
        elseif at == "front" then
            local f = t.facing or 0
            local r = t.radius or 0
            t.x, t.y, t.z, t.placed = row.x + cos(f) * r, row.y + sin(f) * r, row.z, true
        elseif at == "target" or at == "dest" then
            if t.locked then return end
            local x, y, z = where(t.target_guid)
            if x then
                t.x, t.y, t.z, t.placed = x, y, z, true
                -- A ground point is chosen when the cast starts and does not
                -- follow anyone afterwards; a unit target is followed.
                if at == "dest" then t.locked = true end
            else
                t.placed = false
            end
        else
            t.placed = false
        end
    end

    local function poll_casts(now, game_ms, seen)
        local rows = enemies.all()
        for i = 1, #rows do
            local row = rows[i]
            local cast = row.casting
            local info = cast and cast.spell_id and M.info(cast.spell_id)
            local shapes = info and shape_of(info)
            if info and (shapes or info.dbm) then
                local base_key = tostring(row.guid) .. ":" .. tostring(cast.spell_id) .. ":" .. tostring(cast.start_at)
                local list = shapes or { false }
                for s = 1, #list do
                    local shape = list[s] or nil
                    local key = base_key .. "#" .. s
                    local t = live[key]
                    local fresh = t == nil
                    if fresh then
                        t = new_row(key, cast.spell_id, info, shape, cast.channel and "channel" or "cast", now)
                        t.source_guid = row.guid
                        t.by_player = is_player_row(row)
                        t.channel = cast.channel == true
                        if shape and (shape.at == "target" or shape.at == "dest") then
                            local obj = row.obj
                            local ok, target = pcall(function() return obj and obj:get_active_spell_target() end)
                            local guid = nil
                            if ok and target then
                                local ok2, g = pcall(function() return target:is_valid() and target:get_guid() end)
                                if ok2 and g then guid = g end
                            end
                            -- A player's ground spell with no unit target: its
                            -- point is not readable. A mob's lands on its target.
                            if not guid and not t.by_player then guid = row.target_guid end
                            t.target_guid = guid
                        end
                    end
                    t.source = row.obj
                    t.interruptible = cast.interruptible == true
                    t.start_ms, t.end_ms = cast.start_at, cast.end_at
                    if t.shape == "cone" or t.anchor == "front" then
                        local obj = row.obj
                        local ok, f = pcall(function() return obj:get_rotation() end)
                        if ok and type(f) == "number" then
                            t.facing = f
                        else
                            local x, y = where(row.target_guid)
                            if x then t.facing = atan2(y - row.y, x - row.x) end
                        end
                        if not t.facing then t.placed = false end
                    end
                    place_cast(t, row, cast)
                    if t.shape == "cone" and not t.facing then t.placed = false end
                    local s0, e0 = tonumber(cast.start_at), tonumber(cast.end_at)
                    if s0 and e0 and e0 > s0 then
                        t.progress = math.max(0, math.min(1, (game_ms - s0) / (e0 - s0)))
                        t.remaining = math.max(0, (e0 - game_ms) / 1000)
                    else
                        t.progress, t.remaining = nil, cast.remaining
                    end
                    seen[key] = true
                    if fresh then emit_started(t) end
                    stats.casts = stats.casts + 1
                end
            end
        end
    end

    --- A cast that ended near its end time completed: the ground it leaves
    --- stays, where it last was, for the spell's own duration.
    local function maybe_linger(t, now, game_ms)
        if t.phase ~= "cast" or t.channel or not t.linger or t.linger <= 0 or not t.placed then return false end
        local e0 = tonumber(t.end_ms)
        if not e0 or game_ms < e0 - LINGER_GRACE * 1000 then return false end
        t.phase = "linger"
        t.expires = now + t.linger / 1000
        t.source = nil
        t.progress, t.remaining = nil, t.linger / 1000
        return true
    end

    -- missiles --------------------------------------------------------------

    local function poll_missiles(now, px, py, seen)
        local list = missiles.all()
        for i = 1, #list do
            local m = list[i]
            local info = m and m.spell_id and M.info(m.spell_id)
            local shapes = info and shape_of(info)
            local impact = m and m.impact_position
            if shapes and impact then
                local caster = m.caster or m.source
                local snap = caster and units.snapshot(caster) or nil
                local hostile = snap and snap.is_enemy == true
                local near = false
                if not snap then
                    local dx, dy = impact.x - px, impact.y - py
                    near = (dx * dx + dy * dy) <= MISSILE_NEAR * MISSILE_NEAR
                end
                if hostile or near then
                    for s = 1, #shapes do
                        local shape = shapes[s]
                        if shape.k == "circle" and shape.at ~= "caster" then
                            local key = "m:" .. tostring(snap and snap.guid or "?") .. ":" .. tostring(m.spell_id) .. ":" ..
                                floor(impact.x) .. ":" .. floor(impact.y) .. "#" .. s
                            local t = live[key]
                            local fresh = t == nil
                            if fresh then
                                t = new_row(key, m.spell_id, info, shape, "missile", now)
                                t.source_guid = snap and snap.guid or nil
                            end
                            t.x, t.y, t.z, t.placed = impact.x, impact.y, impact.z, true
                            local eta = missiles.time_to_impact(m)
                            if eta ~= huge then
                                local first = missile_first[key]
                                if not first then first = eta; missile_first[key] = eta end
                                t.remaining = eta
                                t.progress = first > 0 and math.max(0, math.min(1, 1 - eta / first)) or 1
                            end
                            t.missile_seen = now
                            seen[key] = true
                            if fresh then emit_started(t) end
                            stats.missiles = stats.missiles + 1
                        end
                    end
                end
            end
        end
    end

    -- hazards with no cast bar: auras on you, and (Era) hits on you ----------------

    local function poll_auras(now, seen)
        local player = units.player()
        if not player then return end
        local list = hazards()
        if not next(list) then return end
        local ok, c = pcall(function() return player:is_in_combat() end)
        local in_combat = ok and c == true
        if now - last_aura_check >= AURA_EVERY then
            last_aura_check = now
            aura_rows = {}
            if in_combat or next(live) then
                local idx = units.aura_index(player)
                for id in pairs(idx) do
                    if list[id] then aura_rows[id] = true end
                end
            end
        end
        local pos = units.player_position()
        if not pos then return end
        for id in pairs(aura_rows) do
            local info = M.info(id) or { n = nil, lv = 3 }
            local key = "a:" .. id
            local t = live[key]
            local fresh = t == nil
            if fresh then
                local shape = nil
                local sh = shape_of(info)
                if sh and sh[1] and sh[1].k == "circle" and (sh[1].r or 0) < WIDE then shape = sh[1] end
                t = new_row(key, id, info, shape, "aura", now)
                t.anchor = "player"
                t.level = 3
                t.hint = info.hint or "On you"
            end
            t.x, t.y, t.z = pos.x, pos.y, pos.z
            t.placed = t.shape ~= "none" and (t.radius or 0) > 0
            seen[key] = true
            if fresh then emit_started(t) end
            stats.hazards = stats.hazards + 1
        end
        for id, h in pairs(hits) do
            if now - h.at > HIT_HOLD then
                hits[id] = nil
            else
                local info = M.info(id) or {}
                local key = "h:" .. id
                local t = live[key]
                local fresh = t == nil
                if fresh then
                    t = new_row(key, id, info, nil, "hit", now)
                    t.anchor = "player"
                    t.level = 3
                    t.hint = info.hint or "Get out"
                end
                t.x, t.y, t.z = pos.x, pos.y, pos.z
                t.remaining = HIT_HOLD - (now - h.at)
                seen[key] = true
                if fresh then emit_started(t) end
            end
        end
    end

    -- The combat log, where the client gives one (not Forever: locked there).
    local my_guid, my_unit = nil, nil
    events.on("jcore.game_event.COMBAT_LOG_EVENT_UNFILTERED", function(a)
        if type(a) ~= "table" then return end
        local sub = a[2]
        local hazard = HAZARD_SUBEVENTS[sub]
        if not hazard and sub ~= "SPELL_CAST_SUCCESS" then return end
        if not state.index then return end
        if hazard then
            local player = units.player()
            if not rawequal(player, my_unit) then
                my_unit = player
                my_guid = player and units.guid(player) or nil
            end
            if not my_guid or a[8] ~= my_guid then return end
            local id = tonumber(a[12])
            local h = id and hazards()[id]
            if h then
                hits[id] = { at = core.time() }
                stats.hits = stats.hits + 1
            end
            return
        end
        -- An instant cast by a hostile that leaves its ground where it stood
        -- (Consecration): no cast bar ever showed it.
        local flags = tonumber(a[6]) or 0
        if floor(flags / 64) % 2 ~= 1 then return end
        local id = tonumber(a[12])
        local info = id and M.info(id)
        local shapes = info and shape_of(info)
        if not shapes then return end
        for s = 1, #shapes do
            local shape = shapes[s]
            if shape.p and shape.p > 0 and shape.at == "caster" and (shape.r or 0) < WIDE then
                local x, y, z = where(a[4])
                if x then
                    local now = core.time()
                    local key = "l:" .. tostring(a[4]) .. ":" .. id .. ":" .. floor(now * 10) .. "#" .. s
                    if not live[key] then
                        local t = new_row(key, id, info, shape, "linger", now)
                        t.source_guid = a[4]
                        t.x, t.y, t.z, t.placed = x, y, z, true
                        t.expires = now + shape.p / 1000
                        t.remaining = shape.p / 1000
                        emit_started(t)
                    end
                end
            end
        end
    end, { owner = "jcore", priority = 0 })

    -- --- the tick --------------------------------------------------------------

    local function by_urgency(a, b)
        if a.inside ~= b.inside then return a.inside end
        if a.level ~= b.level then return a.level > b.level end
        return (a.remaining or huge) < (b.remaining or huge)
    end

    function M._poll()
        if not index() then return end
        local now = core.time()
        local game_ms = core.game_time()
        local seen = {}
        stats.casts, stats.missiles, stats.hazards = 0, 0, 0
        local pos = units.player_position()
        local px, py, pz = 0, 0, 0
        if pos then px, py, pz = pos.x, pos.y, pos.z end

        poll_casts(now, game_ms, seen)
        poll_missiles(now, px, py, seen)
        poll_auras(now, seen)

        local lingering = 0
        for key, t in pairs(live) do
            if not seen[key] then
                if t.phase == "linger" then
                    if t.expires and now < t.expires then
                        t.remaining = t.expires - now
                        t.progress = t.linger and t.linger > 0 and (1 - t.remaining / (t.linger / 1000)) or nil
                        seen[key] = true
                        lingering = lingering + 1
                    end
                elseif maybe_linger(t, now, game_ms) then
                    seen[key] = true
                    lingering = lingering + 1
                end
                if not seen[key] then
                    live[key] = nil
                    missile_first[key] = nil
                end
            end
        end
        stats.lingering = lingering

        for i = n_active, 1, -1 do active[i] = nil end
        n_active = 0
        for _, t in pairs(live) do
            finish(t, px, py, pz)
            n_active = n_active + 1
            active[n_active] = t
        end
        table.sort(active, by_urgency)
        if n_active > MAX_ACTIVE then
            for i = n_active, MAX_ACTIVE + 1, -1 do active[i] = nil end
            n_active = MAX_ACTIVE
        end
        for i = #on_me_list, 1, -1 do on_me_list[i] = nil end
        for i = 1, n_active do
            if active[i].inside then on_me_list[#on_me_list + 1] = active[i] end
        end
    end

    --- Every live telegraph, those on you first, then the most dangerous, then
    --- the soonest. The same table every tick, rebuilt in place.
    ---@return table[]
    function M.active() return active end

    --- The telegraphs the player is standing in.
    ---@return table[]
    function M.on_me() return on_me_list end

    --- Is a point inside a telegraph's ground?
    ---@param t table a row from active()
    ---@param p vec3
    ---@param pad? number yards of reach to count (default PAD)
    ---@return boolean
    function M.covers(t, p, pad)
        if not t or not t.placed or not p then return false end
        pad = pad or PAD
        local dx, dy = p.x - t.x, p.y - t.y
        local d = sqrt(dx * dx + dy * dy)
        if t.shape == "circle" then return d <= (t.radius or 0) + pad end
        if t.shape == "cone" then
            if d > (t.radius or 0) + pad then return false end
            if d <= pad then return true end
            return geometry.in_cone(t.pos, t.facing or 0, p, (t.degrees or 60) / 2)
        end
        return false
    end

    --- The worst telegraph covering a point, or nil: a place to stand, or not.
    ---@param p vec3
    ---@return table|nil
    function M.danger_at(p)
        local best = nil
        for i = 1, n_active do
            local t = active[i]
            if not t.wide and M.covers(t, p) and (not best or t.level > best.level) then best = t end
        end
        return best
    end

    function M.stats()
        local idx = state.index
        return {
            available = idx ~= nil, source = base(), error = state.error,
            spells = idx and idx.counts and idx.counts.spells or 0,
            buckets_read = state.buckets_read,
            active = n_active, on_me = #on_me_list,
            casts = stats.casts, missiles = stats.missiles, lingering = stats.lingering,
            hazards = stats.hazards, hits = stats.hits, started = stats.started, stepped_in = stats.on_me,
        }
    end

    return M
end

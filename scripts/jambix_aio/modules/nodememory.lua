-- Jambix AIO / nodememory -- where a herb, vein or chest was, and your bobber (1.89.0).
--
-- The user, 2026-10-09, choosing the next world marks: "Node memory +
-- fishing".
--
--   NODE MEMORY  a herb, vein or chest that disappears while you are near
--                enough to see it -- gathered, by you or by someone else --
--                is remembered: where it stood, what kind, its name. A ring
--                on the ground there fills back up over the respawn you
--                expect ("Node respawn", 300 s: Classic's respawns vary,
--                so one figure for every kind), with the name and the time
--                left above it, "due" once it is up. A node of that kind
--                seen at the spot again is forgotten, with a pulse. Kept per
--                zone across reloads (the realm's clock, so a reload does
--                not start the rings over), the newest 30 a zone, forgotten
--                half an hour after due; rings out to 120 yd.
--   FISHING      while your bobber is out, a small ring on it; the moment a
--                fish bites, a bright pulse there and the ring lights up.
--                The fishing loop's own bobber and bite read
--                (modules/fishing.lua); a cast by hand gets the same bite
--                read on the bobber found here.
--
-- GONE, OR ONLY OUT OF SIGHT. A node leaves the ESP's list when it is
-- gathered, but also when you walk away, when its switch or its range
-- changes and when the marks are capped. So it only counts as gone when the
-- client itself no longer has it (JCore's units.by_guid, which asks the
-- object manager past the sweep) while you stand within SIGHT (60 yd) of it,
-- well inside the distance the client keeps game objects at; and only while
-- you are alive, in the open world (nothing respawns in a dungeon), and when
-- no more than MASS went at once (a phase change or a loading screen, not
-- gathering).
--
-- The lists are the ESP's: the Forever ESP's node marks
-- (P.esp.forever.node_marks), the Classic one's nodes (P.esp.nodes). A node
-- the ESP does not list -- its category off, past its range, on Forever a
-- herb or vein you have not the profession for -- is never remembered.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min, sqrt, ceil = math.floor, math.max, math.min, math.sqrt, math.ceil

    local M = {}

    local KINDS = { herb = true, ore = true, container = true }
    local WORD = { herb = "Herb", ore = "Vein", container = "Chest" }
    local UPDATE_EVERY = 0.2     -- seconds between looks at the node lists
    local NEAR_EVERY = 0.5       -- seconds between sorting the spots near you
    local WHERE_EVERY = 1.0      -- seconds between asking where you are
    local PRUNE_EVERY = 30       -- seconds between dropping spots long past due
    local SIGHT = 60             -- yards: a node that goes this near was taken
    local KEEP = 20              -- seconds an unlisted node is still watched
    local MASS = 3               -- more than this gone at once is not gathering
    local SPOT = 2.5             -- yards: a node this near a spot is its respawn
    local MATCH_RANGE = 200      -- yards: spots looked at for a respawn
    local RANGE = 120            -- yards: rings out to
    local TEXT_RANGE = 60        -- yards: the countdown out to
    local RINGS = 12             -- at most this many rings
    local PER_ZONE = 30          -- spots kept a zone
    local PAST_DUE = 1800        -- seconds after due a spot is forgotten
    local RING_R = 1.1           -- yards
    local DUNGEON = { party = true, raid = true, pvp = true, arena = true, scenario = true }

    -- Fishing. The classic ranks by id (Apprentice to Artisan); any other
    -- channel is Fishing when the spell book calls it that (Forever's own).
    local FISHING_IDS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }
    local FISH_EVERY = 0.25      -- seconds between looks for a bobber cast by hand
    local BITE_EVERY = 0.1       -- seconds between bite reads on it
    local BOBBER_REACH = 35      -- yards: a bobber is never further
    local AWAY = 5               -- yards: a bobber lands further out than this
    local BOBBER_R = 0.7         -- yards

    local function clock() return core.time() end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local C = {
        band = color(0, 0, 0, 90), text = color(225, 230, 240, 220),
        herb = { from = color(60, 140, 80, 130), to = color(110, 230, 130, 235), pulse = color(140, 245, 160, 235) },
        ore = { from = color(150, 100, 50, 130), to = color(235, 160, 80, 235), pulse = color(245, 185, 110, 235) },
        container = { from = color(160, 140, 60, 130), to = color(245, 210, 90, 235), pulse = color(250, 225, 130, 235) },
        bobber = color(120, 200, 255, 170), bobber_bg = color(0, 0, 0, 80),
        bite = color(255, 235, 120, 255), splash = color(255, 245, 170, 245),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function vec(x, y, z)
        local geo = ctx and ctx.geometry
        local v = geo and ask(geo.vec, x, y, z)
        return v or { x = x, y = y, z = z }
    end

    local stats = {
        spots = 0, rings = 0, texts = 0, zone = nil, clock = nil,
        gone = 0, respawned = 0, mass = 0, bobber = nil, bites = 0,
    }

    -- --- the clock ------------------------------------------------------------
    --
    -- A spot outlives a reload, so its time is the realm's (unix seconds,
    -- core.get_server_time), else the PC's (os.time). core.time() counts from
    -- the injection and starts over. Asked until one answers, then carried
    -- on core.time(). With neither, spots are kept for the session only.

    local wall_offset, wall_asked = nil, -1e9
    local function wall(now)
        if not wall_offset and now - wall_asked >= 5 then
            wall_asked = now
            local s = tonumber(ask(core.get_server_time))
            if s and s > 0 then
                wall_offset, stats.clock = s - now, "realm"
            else
                local o = type(os) == "table" and tonumber(ask(os.time)) or nil
                if o and o > 0 then wall_offset, stats.clock = o - now, "pc" end
            end
        end
        if wall_offset then return now + wall_offset, true end
        return now, false
    end

    -- --- the store ------------------------------------------------------------
    --
    -- store.data.zones[continent] = { { x, y, z, k = kind, n = name,
    -- t = when it went, zn = zone, s = 1 when timed by the session only } }.
    -- By continent (the instance map id), since that is what positions are
    -- in; each spot carries its zone (the map id) for the 30 a zone.

    local store = nil
    do
        local ok, s = pcall(function() return ctx.store and ctx.store("nodememory") end)
        if ok and type(s) == "table" and type(s.data) == "table" then store = s end
    end
    local data = store and store.data or {}
    if type(data.zones) ~= "table" then data.zones = {} end
    -- A spot timed by a session's clock means nothing in the next one.
    for key, list in pairs(data.zones) do
        if type(list) == "table" then
            for i = #list, 1, -1 do
                if type(list[i]) ~= "table" or list[i].s then table.remove(list, i) end
            end
        else
            data.zones[key] = nil
        end
    end

    local function touch()
        if store and store.touch then pcall(store.touch, store) end
    end

    -- --- where you are --------------------------------------------------------

    local here = { key = nil, zone = nil, dungeon = false, at = -1e9 }

    local function where(now)
        if here.key and now - here.at < WHERE_EVERY then return here end
        here.at = now
        local w = ctx.world
        local inst = w and tonumber(ask(w.instance_id)) or nil
        if inst == nil then inst = tonumber(ask(core.get_instance_id)) end
        local map = w and tonumber(ask(w.map_id)) or nil
        local kind = w and ask(w.instance_type) or nil
        here.key = tostring(floor(inst or map or 0))
        here.zone = floor(map or inst or 0)
        here.dungeon = DUNGEON[kind] == true
        return here
    end

    local function spots_here(create)
        local list = data.zones[here.key]
        if type(list) ~= "table" then
            if not create then return nil end
            list = {}
            data.zones[here.key] = list
        end
        return list
    end

    local function respawn_of()
        return max(30, min(7200, tonumber(opt("nodemem_respawn", 300)) or 300))
    end

    -- --- spots near you -----------------------------------------------------------

    local vec_of = setmetatable({}, { __mode = "k" })     -- spot -> its ring's centre
    local top_of = setmetatable({}, { __mode = "k" })     -- spot -> its countdown's place
    local dist_of = setmetatable({}, { __mode = "k" })    -- spot -> yards from you
    local label_of = setmetatable({}, { __mode = "k" })   -- spot -> { secs, text }
    local near_spots, near_n = {}, 0                      -- within MATCH_RANGE
    local ring_spots, ring_n = {}, 0                      -- within RANGE, nearest first
    local near_at, dirty = -1e9, true

    local function by_distance(a, b) return (dist_of[a] or 0) < (dist_of[b] or 0) end

    local function refresh_near(me)
        near_n, ring_n = 0, 0
        local list = spots_here(false)
        if list then
            for i = 1, #list do
                local r = list[i]
                local dx, dy = r.x - me.x, r.y - me.y
                local d = sqrt(dx * dx + dy * dy)
                dist_of[r] = d
                if d <= MATCH_RANGE then
                    near_n = near_n + 1
                    near_spots[near_n] = r
                    if d <= RANGE then
                        ring_n = ring_n + 1
                        ring_spots[ring_n] = r
                    end
                end
            end
        end
        for i = near_n + 1, #near_spots do near_spots[i] = nil end
        for i = ring_n + 1, #ring_spots do ring_spots[i] = nil end
        table.sort(ring_spots, by_distance)
        if ring_n > RINGS then
            for i = RINGS + 1, ring_n do ring_spots[i] = nil end
            ring_n = RINGS
        end
        stats.spots = list and #list or 0
        dirty = false
    end

    local function at_spot(r, x, y, z)
        local dx, dy = r.x - x, r.y - y
        return dx * dx + dy * dy <= SPOT * SPOT and math.abs((r.z or z) - z) <= 5
    end

    local function round1(v) return floor(v * 10 + 0.5) / 10 end

    -- --- remembering and forgetting -------------------------------------------------

    local function remember(s, now)
        local list = spots_here(true)
        local t, real = wall(now)
        for i = #list, 1, -1 do
            if at_spot(list[i], s.x, s.y, s.z) then table.remove(list, i) end
        end
        local rec = { x = round1(s.x), y = round1(s.y), z = round1(s.z), k = s.kind, n = s.name,
            t = floor(t), zn = here.zone }
        if not real then rec.s = 1 end
        list[#list + 1] = rec
        -- The newest PER_ZONE of this zone: the oldest goes first.
        while true do
            local count, oldest, oldest_t = 0, nil, nil
            for i = 1, #list do
                local r = list[i]
                if r.zn == here.zone then
                    count = count + 1
                    if not oldest_t or r.t < oldest_t then oldest, oldest_t = i, r.t end
                end
            end
            if count <= PER_ZONE or not oldest then break end
            table.remove(list, oldest)
        end
        stats.gone = stats.gone + 1
        dirty = true
        touch()
    end

    --- A node listed at a remembered spot of its kind: it is back.
    local function respawned(kind, x, y, z, draw, layer)
        if near_n == 0 then return end
        local list = spots_here(false)
        if not list then return end
        for i = near_n, 1, -1 do
            local r = near_spots[i]
            if r and r.k == kind and at_spot(r, x, y, z) then
                for j = #list, 1, -1 do
                    if list[j] == r then table.remove(list, j) break end
                end
                table.remove(near_spots, i)
                near_n = near_n - 1
                stats.respawned = stats.respawned + 1
                if draw.pulse then
                    local c = C[r.k] or C.herb
                    -- No `to`: the staged world layer shades a pulse's `to`
                    -- (yards) as a colour; JCore's 2.4 yd end it is.
                    draw.pulse(vec_of[r] or vec(r.x, r.y, r.z), c.pulse, { life = 1.0, from = 0.6,
                        layer = layer, prio = "info", module = "nodes" })
                end
                dirty = true
                touch()
            end
        end
    end

    local function prune(now)
        local t, real = wall(now)
        local limit = respawn_of() + PAST_DUE
        local changed = false
        for key, list in pairs(data.zones) do
            if type(list) == "table" then
                for i = #list, 1, -1 do
                    local r = list[i]
                    if type(r) ~= "table" or type(r.x) ~= "number" or type(r.y) ~= "number"
                        or type(r.t) ~= "number" or (real and r.s) or t - r.t > limit then
                        table.remove(list, i)
                        changed = true
                    end
                end
                if #list == 0 then data.zones[key] = nil end
            end
        end
        if changed then
            dirty = true
            touch()
        end
    end

    -- --- watching the nodes ---------------------------------------------------------

    local seen = {}              -- guid -> { x, y, z, kind, name, at, stamp }
    local stamp = 0
    local gone = {}
    local here_set, here_stamp = {}, -1

    --- This frame's herbs, veins and chests: the Forever ESP's marks, else the
    --- Classic ESP's nodes.
    local function node_list()
        local esp = P.esp
        if not esp then return nil, nil end
        local fe = esp.forever
        if fe and fe.node_marks then
            local list = ask(fe.node_marks)
            if type(list) == "table" then return list, true end
        end
        local list = esp.nodes and ask(esp.nodes)
        if type(list) == "table" then return list, false end
        return nil, nil
    end

    --- Does the client still have it? JCore's by_guid asks the object manager
    --- past the sweep; an older JCore has only this sweep's objects.
    local function still_there(guid)
        if units.by_guid then return ask(units.by_guid, guid) ~= nil end
        if here_stamp ~= stamp then
            here_stamp = stamp
            for k in pairs(here_set) do here_set[k] = nil end
            local objs = units.objects and ask(units.objects) or nil
            if type(objs) == "table" then
                for i = 1, #objs do
                    local g = units.guid and ask(units.guid, objs[i])
                    if g then here_set[g] = true end
                end
            end
        end
        return here_set[guid] == true
    end

    local function update(now, me, draw, layer)
        stamp = stamp + 1
        local list, forever = node_list()
        if list then
            for i = 1, #list do
                local e = list[i]
                local kind = forever and e.cat or e.kind
                local guid = e.guid
                if guid and KINDS[kind] then
                    local pos = (forever and e.pos) or (units.position and ask(units.position, e.obj))
                    if pos and pos.x then
                        local s = seen[guid]
                        if not s then
                            s = {}
                            seen[guid] = s
                        end
                        s.x, s.y, s.z = pos.x, pos.y, pos.z or 0
                        s.kind, s.name, s.at, s.stamp = kind, e.name, now, stamp
                        respawned(kind, s.x, s.y, s.z, draw, layer)
                    end
                end
            end
        end
        local n = 0
        for guid, s in pairs(seen) do
            if s.stamp ~= stamp then
                local dx, dy, dz = s.x - me.x, s.y - me.y, s.z - (me.z or s.z)
                if dx * dx + dy * dy + dz * dz > SIGHT * SIGHT or now - s.at > KEEP then
                    seen[guid] = nil
                elseif not still_there(guid) then
                    seen[guid] = nil
                    n = n + 1
                    gone[n] = s
                end
            end
        end
        if n > MASS then
            stats.mass = stats.mass + 1
        else
            for i = 1, n do remember(gone[i], now) end
        end
        for i = 1, n do gone[i] = nil end
    end

    -- --- drawing the spots ------------------------------------------------------------

    local function label(r, left)
        local secs = left > 0 and ceil(left) or 0
        local l = label_of[r]
        if l and l.secs == secs then return l.text end
        local name = (type(r.n) == "string" and r.n ~= "") and r.n or WORD[r.k] or "Node"
        local text
        if secs <= 0 then
            text = name .. "  due"
        else
            text = string.format("%s  %d:%02d", name, floor(secs / 60), secs % 60)
        end
        label_of[r] = { secs = secs, text = text }
        return text
    end

    --- Text is not the world layer's to drop: left out with the world marks
    --- off, and with Minimal density, which leaves decoration out.
    local function text_allowed()
        if not P.worldmarks then return true end
        if opt("world_on", true) == false then return false end
        return floor(tonumber(opt("world_density", 1)) or 1) < 3
    end

    local updated_at, pruned_at = -1e9, -1e9
    local was_alive = true

    local function nodes_frame(now, draw, layer, me, my_pos)
        local h = where(now)
        if h.key ~= stats.zone then
            -- Another continent: what was watched is somewhere else now.
            stats.zone = h.key
            for k in pairs(seen) do seen[k] = nil end
            dirty = true
        end
        if h.dungeon then
            for k in pairs(seen) do seen[k] = nil end
            return
        end
        if now - pruned_at >= PRUNE_EVERY then
            pruned_at = now
            prune(now)
        end
        if dirty or now - near_at >= NEAR_EVERY then
            near_at = now
            refresh_near(my_pos)
        end
        if now - updated_at >= UPDATE_EVERY then
            updated_at = now
            local alive = ask(me.is_dead, me) ~= true and ask(me.is_ghost, me) ~= true
            if alive and was_alive then
                update(now, my_pos, draw, layer)
            else
                for k in pairs(seen) do seen[k] = nil end
            end
            was_alive = alive
            if dirty then
                near_at = now
                refresh_near(my_pos)
            end
        end

        local respawn = respawn_of()
        local t = wall(now)
        local text = draw.text_3d and text_allowed()
        for i = 1, ring_n do
            local r = ring_spots[i]
            local v = vec_of[r]
            if not v then
                v = vec(r.x, r.y, r.z)
                vec_of[r] = v
            end
            local elapsed = max(0, t - r.t)
            local frac = min(1, elapsed / respawn)
            local c = C[r.k] or C.herb
            draw.ring_3d(v, RING_R, frac, frac >= 1 and c.to or c.from, { to = c.to, bg = C.band,
                inner = 0.74, outer = 1.0, layer = layer, prio = "decor", module = "nodes" })
            stats.rings = stats.rings + 1
            if text and (dist_of[r] or 0) <= TEXT_RANGE then
                local top = top_of[r]
                if not top then
                    top = vec(r.x, r.y, r.z + 0.6)
                    top_of[r] = top
                end
                draw.text_3d(top, label(r, respawn - elapsed), frac >= 1 and c.to or C.text, { size = 12 })
                stats.texts = stats.texts + 1
            end
        end
    end

    -- --- the bobber -----------------------------------------------------------------

    local fish = {
        obj = nil, guid = nil, key = nil, v = nil, bite = false, hand = false,
        look_at = -1e9, bite_at = -1e9, bite_now = false, chan = nil, snap = nil,
        names = {},              -- guid -> its name says bobber, this channel
    }
    local fishing_by_name = {}   -- channel spell id -> its name says Fishing

    local function clear_fish()
        fish.obj, fish.guid, fish.key, fish.v = nil, nil, nil, nil
        fish.bite, fish.hand, fish.bite_now = false, false, false
    end

    local function fishing_channel(me)
        if ask(me.is_channelling_spell, me) ~= true then return false end
        local id = tonumber(ask(me.get_active_channel_spell_id, me))
        if not id then return false end
        if FISHING_IDS[id] then return true end
        local known = fishing_by_name[id]
        if known == nil then
            local spells = ctx.spells
            local name = spells and spells.name and ask(spells.name, id) or nil
            if type(name) ~= "string" and core.spell_book then name = ask(core.spell_book.get_spell_name, id) end
            known = type(name) == "string" and name:find("Fishing", 1, true) ~= nil
            fishing_by_name[id] = known
        end
        return known
    end

    --- In this sweep, or the client says so.
    local function valid(obj)
        if units.snapshot and units.snapshot(obj) then return true end
        if type(obj.is_valid) ~= "function" then return true end
        return ask(obj.is_valid, obj) == true
    end

    --- The fishing loop's test for a bobber: a basic object with no health,
    --- made by you, near.
    local function candidates(my_guid, out)
        local n = 0
        local objs = units.objects and ask(units.objects) or nil
        if type(objs) ~= "table" then return 0 end
        for i = 1, #objs do
            local obj = objs[i]
            local row = units.snapshot and units.snapshot(obj)
            local d = row and row.dist or tonumber(units.distance and ask(units.distance, obj)) or math.huge
            if d <= BOBBER_REACH then
                local creator = ask(obj.get_creator_object, obj)
                if creator and ask(creator.is_valid, creator) == true and ask(creator.get_guid, creator) == my_guid
                    and ask(obj.is_basic_object, obj) == true
                    and (tonumber(ask(obj.get_max_health, obj)) or 0) == 0 then
                    local guid = (units.guid and units.guid(obj)) or ask(obj.get_guid, obj)
                    if guid then
                        n = n + 1
                        out[n] = out[n] or {}
                        out[n].obj, out[n].guid, out[n].d = obj, guid, d
                    end
                end
            end
        end
        for i = n + 1, #out do out[i] = nil end
        return n
    end

    local cands = {}

    --- A bobber cast by hand: what is yours and appeared during the fishing
    --- channel; failing that, one called a bobber; failing that, half a
    --- second into the channel, the only one away from your feet.
    local function by_hand(now, me)
        if now - fish.look_at < FISH_EVERY then return end
        fish.look_at = now
        if not fishing_channel(me) then
            if fish.chan then fish.chan, fish.snap, fish.names = nil, nil, {} end
            if fish.hand then clear_fish() end
            return
        end
        if fish.hand and fish.obj then
            if valid(fish.obj) then return end
            clear_fish()
        end
        local my_guid = (units.guid and units.guid(me)) or ask(me.get_guid, me)
        if not my_guid then return end
        local n = candidates(my_guid, cands)
        if not fish.chan then
            fish.chan, fish.snap = now, {}
            for i = 1, n do fish.snap[cands[i].guid] = true end
        end
        local pick = nil
        for i = 1, n do
            if not fish.snap[cands[i].guid] then pick = cands[i] break end
        end
        if not pick then
            for i = 1, n do
                local c = cands[i]
                local named = fish.names[c.guid]
                if named == nil then
                    local name = ask(c.obj.get_name, c.obj)
                    named = type(name) == "string" and name:find("obber", 1, true) ~= nil
                    fish.names[c.guid] = named
                end
                if named then pick = c break end
            end
        end
        if not pick and now - fish.chan >= 0.5 then
            -- Already there when the channel was first seen: the one away
            -- from your feet (a campfire or a trap is where you stood).
            local away = 0
            for i = 1, n do
                if cands[i].d >= AWAY then
                    away = away + 1
                    pick = cands[i]
                end
            end
            if away ~= 1 then pick = nil end
        end
        if pick then
            clear_fish()
            fish.obj, fish.guid, fish.key, fish.hand = pick.obj, pick.guid, pick.guid, true
        end
    end

    local function read_bite(obj)
        local F = P.fishing
        if F and F.has_bite then return ask(F.has_bite, obj) == true end
        return ask(obj.does_bobber_have_fish, obj) == true
    end

    local function fishing_frame(now, draw, layer, me)
        local F = P.fishing
        local obj, guid, bite = nil, nil, false
        if F and F.bobber then
            local ok, o, g, b = pcall(F.bobber)
            if ok and o then obj, guid, bite = o, g, b == true end
        end
        if obj then
            local key = guid or obj
            if fish.hand or key ~= fish.key then
                clear_fish()
                fish.obj, fish.guid, fish.key = obj, guid, key
            end
            stats.bobber = "loop"
        else
            if not fish.hand and fish.obj then clear_fish() end
            by_hand(now, me)
            obj = fish.hand and fish.obj or nil
            if not obj then
                stats.bobber = nil
                return
            end
            if now - fish.bite_at >= BITE_EVERY then
                fish.bite_at = now
                fish.bite_now = read_bite(obj)
            end
            bite = fish.bite_now
            stats.bobber = "hand"
        end
        if not fish.v then
            local pos = valid(obj) and units.position and ask(units.position, obj) or nil
            if not (pos and pos.x) then return end
            fish.v = vec(pos.x, pos.y, pos.z or 0)
        end
        if bite and not fish.bite then
            fish.bite = true
            stats.bites = stats.bites + 1
            if draw.pulse then
                draw.pulse(fish.v, C.splash, { life = 1.0, from = 0.3, layer = layer,
                    prio = "warn", module = "fishing" })
            end
        end
        draw.ring_3d(fish.v, BOBBER_R, 1, fish.bite and C.bite or C.bobber, { bg = C.bobber_bg,
            inner = 0.72, outer = 1.0, layer = layer, prio = "info", module = "fishing" })
        stats.rings = stats.rings + 1
    end

    -- --- the frame --------------------------------------------------------------------

    --- One frame. Called by main.lua's render job under the toggle key, after
    --- the ESP's job (100), whose node lists it reads.
    function M.render()
        stats.rings, stats.texts = 0, 0
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        local me = units.player and units.player()
        local my_pos = me and ((units.player_position and units.player_position()) or (units.position and units.position(me)))
        if not (my_pos and my_pos.x) then
            -- A loading screen: whatever was watched is gone from view, not taken.
            for k in pairs(seen) do seen[k] = nil end
            clear_fish()
            return
        end
        local now = clock()
        local layer = (ctx.LAYER or {}).WORLD or 100
        if opt("nodemem_on", true) then
            nodes_frame(now, draw, layer, me, my_pos)
        else
            for k in pairs(seen) do seen[k] = nil end
        end
        if opt("nodemem_fishing", true) then
            fishing_frame(now, draw, layer, me)
        elseif fish.obj then
            clear_fish()
            stats.bobber = nil
        end
    end

    --- The spots remembered on this continent (read-only).
    function M.spots() return spots_here(false) or {} end

    function M.stats() return stats end

    return M
end

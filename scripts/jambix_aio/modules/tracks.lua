-- Jambix AIO / tracks -- what is flying at you, which way they face, where they walk (1.89.0).
--
-- The user, 2026-10-09, choosing the next world marks: "Missiles" and
-- "Facing + patrol paths".
--
--   MISSILES   a projectile in flight at you or your group, or any a hostile
--              fired within "Look this far": a line from where it is to where
--              it lands, and a ring there filling as it flies (full: it has
--              landed). Red when it lands on you, amber anywhere else. One
--              aimed at someone lands on them, so its ring stands under them,
--              outside their other rings (a second and third step outward);
--              one with no target lands on the ground, where it was sent.
--              The telegraphs already paint the ground a known spell's
--              missile will hit (modules/telegraphs.lua): such a missile keeps
--              its line and gets no ring here.
--   FACING     each hostile mob not yet fighting, the nearest eight: a faint
--              wedge on the ground the way it faces, as long as the range it
--              notices you from (Pull safety's rule: 20 yd at your level, a
--              yard a level between, 5 to 45).
--   PATROLS    a hostile mob walking, not fighting, the nearest four: the
--              route it walked (the last twenty seconds, fainter the older),
--              and an arrow ahead of it the way it is going. A patrol that
--              stops at the end of its path keeps its route for six seconds.
--
-- WHAT IS READ. JCore's missile sweep and the telegraphs' live list (once a
-- tick, by JCore); the enemies' rows (position, combat, motion: free); per
-- mob, its facing at most five times a second (get_direction, which answers
-- on Forever, else get_rotation), its level every 30 s and whether it is
-- your enemy every 3 s. The enemies' own trail is about a second long, a
-- few yards: a route is kept here, a point for every yard and a half walked,
-- seeded from that trail the first time a mob is seen.
--
-- The rings go through the world layer (prio "warn" or "info", module
-- "missiles"). Lines, wedges and routes pass straight through to JCore's
-- draw, so they are few, droppable when JCore's frame is full (all but the
-- line of a missile coming at you), and take the World marks page's
-- brightness, colour-blind correction and "Show world marks" here;
-- "Minimal" density leaves the routes out.

local NEAR = 3.0             -- yards: a missile landing this near someone lands on them (JCore's aimed_at)
local GROUND = 2.0           -- yards: the ring where a missile with no target lands
local LANE = 1.4             -- yards outside a model's edge: the ring under someone a missile is aimed at
local STEP, BAND = 0.35, 0.25 -- the world layer's lane step and band
local MISSILES_MAX = 12
local FACING_MAX = 8
local FACE_EVERY = 0.2       -- seconds: a mob's facing is read at most this often
local CONE_DEG = 90          -- the wedge's width
local ARC = 8                -- points along the wedge's arc
local MOVED, TURNED = 0.25, 0.035 -- yards, radians: past these a wedge is worked out again
local PATROLS_MAX = 4
local STRIDE = 1.5           -- yards walked between two points of a route
local ROUTE_MAX = 16         -- points kept
local ROUTE_AGE = 20         -- seconds a point is kept
local ROUTE_HOLD = 6         -- seconds a route stays up after its last step
local ROUTE_MIN = 4          -- yards of route before it is drawn
local SAMPLE_PAST = 10       -- yards past "Look this far" a route is already kept
local LEVEL_EVERY, HOSTILE_EVERY = 30, 3
local FORGET = 30            -- seconds unseen before a mob is forgotten
local SWEEP_EVERY = 2

return function(P)
    local ctx = P.ctx or {}
    local units = P.units or ctx.units or {}
    local opt = P.opt
    local floor, max, min, abs = math.floor, math.max, math.min, math.abs
    local sqrt, cos, sin, pi, huge = math.sqrt, math.cos, math.sin, math.pi, math.huge
    local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

    local M = {}

    local function clock() return core.time() end

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function index(o, k) return o[k] end

    --- obj:name(arg), or nil when it is missing or raises.
    local function call(obj, name, arg)
        if obj == nil then return nil end
        local ok, fn = pcall(index, obj, name)
        if not ok or type(fn) ~= "function" then return nil end
        local ok2, v = pcall(fn, obj, arg)
        if ok2 then return v end
        return nil
    end

    local function xy(v) return v.x, v.y end

    local function color(r, g, b, a)
        r, g, b = floor(max(0, min(255, r)) + 0.5), floor(max(0, min(255, g)) + 0.5), floor(max(0, min(255, b)) + 0.5)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    local function vec(x, y, z)
        local geo = ctx.geometry
        if geo and geo.vec then
            local v = ask(geo.vec, x, y, z)
            if v then return v end
        end
        return { x = x, y = y, z = z }
    end

    local function guid_of(obj)
        if obj == nil then return nil end
        local g = units.guid and ask(units.guid, obj)
        if g then return g end
        return call(obj, "get_guid")
    end

    local function wrap(a)
        return (a + pi) % (2 * pi) - pi
    end

    -- --- colours --------------------------------------------------------------------
    --
    -- The rings' go through the world layer, which shades them; the rest pass
    -- straight through and are shaded here, the same way, once per setting.

    local C = {
        warn = color(255, 120, 50, 230), warn_to = color(240, 45, 40, 255), warn_bg = color(240, 60, 40, 70),
        info = color(245, 205, 95, 190), info_to = color(250, 140, 50, 235), info_bg = color(0, 0, 0, 90),
    }

    local RAW = {
        line_warn = { 255, 110, 60, 220 }, line_info = { 245, 205, 95, 150 },
        cone = { 250, 220, 140, 24 }, cone_edge = { 250, 220, 140, 85 },
        route_old = { 150, 185, 255, 45 }, route_new = { 150, 185, 255, 115 }, arrow = { 175, 205, 255, 190 },
    }
    local PC, pc_bright, pc_cb = {}, nil, nil

    local function passthrough_colors(draw)
        local bright = (tonumber(opt("world_brightness", 100)) or 100) / 100
        local cb = floor(tonumber(opt("world_colorblind", 1)) or 1)
        if bright == pc_bright and cb == pc_cb then return PC end
        pc_bright, pc_cb = bright, cb
        local dalt = cb > 1 and draw.daltonize or nil
        for name, c in pairs(RAW) do
            local r, g, b = c[1], c[2], c[3]
            if dalt then
                local ok, r2, g2, b2 = pcall(dalt, r, g, b, cb)
                if ok and type(r2) == "number" then r, g, b = r2, g2, b2 end
            end
            PC[name] = color(r, g, b, c[4] * bright)
        end
        return PC
    end

    local stats = { missiles = 0, rings = 0, covered = 0, facing = 0, unread = 0, patrols = 0 }

    -- --- missiles --------------------------------------------------------------------

    -- The group this frame (not you): guid, object, where they stand.
    local g_guid, g_obj, g_x, g_y, g_n = {}, {}, {}, {}, 0
    -- The telegraphs painting a missile's landing this frame.
    local t_spell, t_src, t_x, t_y, t_r, t_n = {}, {}, {}, {}, {}, 0
    local picks, pick_n = {}, 0
    local per_target = {}
    local ring_opts = {}         -- one per ring; the layer lets go of them at its flush
    local line_opts = { thickness = 1.5 }
    local first_left, first_at = {}, {} -- a missile with no source_position: yards left when first seen

    local function gather_group(me_guid)
        g_n = 0
        local group = ctx.group
        local list = group and ask(group.objects)
        if type(list) ~= "table" then return end
        for i = 1, #list do
            local o = list[i]
            local g = guid_of(o)
            local pos = g and g ~= me_guid and units.position and ask(units.position, o)
            if pos then
                g_n = g_n + 1
                g_guid[g_n], g_obj[g_n], g_x[g_n], g_y[g_n] = g, o, pos.x, pos.y
            end
        end
        for i = g_n + 1, #g_obj do g_obj[i] = nil end
    end

    --- Who a missile lands on in the group: the one it is aimed at, else the
    --- one standing where it lands. An index into the g_ arrays, or nil.
    local function member_hit(tguid, imp, near2)
        if tguid ~= nil then
            for i = 1, g_n do
                if g_guid[i] == tguid then return i end
            end
        end
        for i = 1, g_n do
            local dx, dy = imp.x - g_x[i], imp.y - g_y[i]
            if dx * dx + dy * dy <= near2 then return i end
        end
        return nil
    end

    local function in_instance()
        local world = ctx.world
        if not world then return false end
        local ok, yes = pcall(function() return world.in_raid_instance() or world.in_dungeon() end)
        return ok and yes == true
    end

    --- "Show telegraphs for": 1 every hostile cast, 2 elites, bosses and
    --- boss-mod spells, 3 boss-mod spells only (as modules/telegraphs.lua).
    local function shown_for(t, who)
        if who <= 1 or (t.level or 1) >= 2 then return true end
        if who >= 3 then return false end
        local rank = type(t.rank) == "number" and t.rank
            or (t.source and units.classification and tonumber(ask(units.classification, t.source))) or 0
        return rank > 0
    end

    --- The telegraph rows the AIO's telegraphs draw a missile's landing for
    --- this frame: phase "missile", placed, with their module and switches on
    --- ("Enable ESP", not "RestedXP guide only", tele_on, tele_missiles, and
    --- "Show telegraphs for" / "in" / their range). Anything the telegraphs
    --- would leave out gets its ring here.
    local function gather_cover()
        t_n = 0
        if not P.telegraphs then return end
        if not opt("enabled", true) or opt("rxp_only", false) then return end
        if not opt("tele_on", true) or not opt("tele_missiles", true) then return end
        if opt("tele_where", 1) == 2 and not in_instance() then return end
        local svc = ctx.telegraphs
        local list = svc and ask(svc.active)
        if type(list) ~= "table" then return end
        local who = tonumber(opt("tele_who", 1)) or 1
        local reach = tonumber(opt("tele_range", 60)) or 60
        for i = 1, #list do
            local t = list[i]
            if type(t) == "table" and t.phase == "missile" and t.placed ~= false and type(t.x) == "number"
                and (t.dist or 0) <= reach + (t.radius or 0) and shown_for(t, who) then
                t_n = t_n + 1
                t_spell[t_n], t_src[t_n], t_x[t_n], t_y[t_n], t_r[t_n] = t.spell_id, t.source_guid, t.x, t.y, t.radius or 0
            end
        end
    end

    --- Is this landing one a telegraph paints: the same spell, from the same
    --- caster when both are known, landing inside its circle (+1 yd)?
    local function covered(spell_id, src_guid, x, y)
        for i = 1, t_n do
            if t_spell[i] == spell_id and (t_src[i] == nil or src_guid == nil or t_src[i] == src_guid) then
                local dx, dy = x - t_x[i], y - t_y[i]
                local r = t_r[i] + 1
                if dx * dx + dy * dy <= r * r then return true end
            end
        end
        return false
    end

    local function dist3(a, b)
        local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
        return sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- 0..1 of the flight behind it: from where it was fired when the row says,
    --- else from how far it had left to go when first seen.
    local function progress_of(p, landing, now)
        local m = p.m
        local left = dist3(p.cur, landing)
        local src = m.source_position
        if src and type(src.x) == "number" then
            local done = dist3(src, p.cur)
            local total = done + left
            if total <= 0.05 then return 1 end
            return min(1, max(0, done / total))
        end
        local key = tostring(p.cguid or "?") .. ":" .. tostring(m.spell_id) .. ":" ..
            (p.tguid and tostring(p.tguid) or (floor(p.imp.x) .. "," .. floor(p.imp.y)))
        local first = first_left[key]
        if not first or left > first then
            first = left
            first_left[key] = left
        end
        first_at[key] = now
        if first <= 0.05 then return 1 end
        return min(1, max(0, 1 - left / first))
    end

    --- The model's edge under a unit, as the ESP and the world layer measure it.
    local function edge_of(draw, unit)
        local e = draw.edge and tonumber(ask(draw.edge, unit))
        if e then return e end
        local reach = tonumber(units.combat_reach and ask(units.combat_reach, unit)) or 1.2
        return min(4, max(0.9, reach + 0.3))
    end

    local function lane_offset(draw)
        local lanes = draw.LANES
        return type(lanes) == "table" and tonumber(lanes.missile) or LANE
    end

    local function draw_missile(draw, p, me_guid, layer, pc, now)
        local warn = p.on_me
        -- Where it lands: on the one it is aimed at, followed; else where it was sent.
        local under, landing = nil, p.imp
        if p.target and p.tguid then
            local tpos = units.position and ask(units.position, p.target)
            if tpos then under, landing = p.target, tpos end
        end
        stats.missiles = stats.missiles + 1
        if draw.line_3d then
            line_opts.thickness = warn and 2.0 or 1.5
            line_opts.layer, line_opts.droppable = layer, not warn
            ask(draw.line_3d, p.cur, landing, warn and pc.line_warn or pc.line_info, line_opts)
        end
        if covered(p.m.spell_id, p.cguid, p.imp.x, p.imp.y) then
            stats.covered = stats.covered + 1
            return
        end
        if not draw.ring_3d then return end
        local radius
        if under then
            local nth = min(3, (per_target[p.tguid] or 0) + 1)
            per_target[p.tguid] = nth
            radius = edge_of(draw, under) + lane_offset(draw) + (nth - 1) * STEP + BAND
        else
            radius = GROUND
        end
        stats.rings = stats.rings + 1
        local o = ring_opts[stats.rings]
        if not o then
            o = {}
            ring_opts[stats.rings] = o
        end
        o.to, o.bg = warn and C.warn_to or C.info_to, warn and C.warn_bg or C.info_bg
        o.inner, o.outer, o.layer = 0.8, 1.0, layer
        o.prio, o.module = warn and "warn" or "info", "missiles"
        -- Under someone else: the layer fades it behind a wall. Never under you.
        o.unit = (under and p.tguid ~= me_guid) and under or nil
        draw.ring_3d(landing, radius, progress_of(p, landing, now), warn and C.warn or C.info, o)
    end

    local function render_missiles(draw, me_guid, mpos, range, layer, pc, now)
        local svc = ctx.missiles
        local list = svc and ask(svc.all)
        if type(list) ~= "table" or #list == 0 then return end
        local mx, my = mpos.x, mpos.y
        local range2, near2 = range * range, NEAR * NEAR
        gather_group(me_guid)
        gather_cover()
        pick_n = 0
        for i = 1, #list do
            local m = list[i]
            local cur = m and m.current_position
            local imp = m and m.impact_position
            if cur and imp and type(cur.x) == "number" and type(imp.x) == "number" then
                local caster = m.caster or m.source
                local cguid = caster and guid_of(caster)
                local csnap = caster and units.snapshot and ask(units.snapshot, caster)
                local mine = cguid ~= nil and cguid == me_guid
                -- In the sweep and not attackable: a friend's. Out of it: unknown.
                local friendly = type(csnap) == "table" and csnap.is_enemy ~= true
                if not mine and not friendly then
                    local hostile = type(csnap) == "table" and csnap.is_enemy == true
                    local target = m.target
                    local tguid = target and guid_of(target)
                    local dx, dy = imp.x - mx, imp.y - my
                    local on_me = (tguid ~= nil and tguid == me_guid) or dx * dx + dy * dy <= near2
                    local member = not on_me and member_hit(tguid, imp, near2) or nil
                    local close = false
                    if hostile then
                        local cx, cy = cur.x - mx, cur.y - my
                        close = cx * cx + cy * cy <= range2 or dx * dx + dy * dy <= range2
                    end
                    if on_me or member or close then
                        pick_n = pick_n + 1
                        local p = picks[pick_n]
                        if not p then
                            p = {}
                            picks[pick_n] = p
                        end
                        p.m, p.cur, p.imp, p.cguid, p.target, p.tguid, p.on_me = m, cur, imp, cguid, target, tguid, on_me
                    end
                end
            end
        end
        if pick_n == 0 then return end
        for k in pairs(per_target) do per_target[k] = nil end
        -- What lands on you first, then the rest, up to MISSILES_MAX.
        local drawn = 0
        for pass = 1, 2 do
            for i = 1, pick_n do
                local p = picks[i]
                if (pass == 1) == (p.on_me == true) and drawn < MISSILES_MAX then
                    drawn = drawn + 1
                    draw_missile(draw, p, me_guid, layer, pc, now)
                end
            end
        end
        for i = 1, pick_n do
            local p = picks[i]
            p.m, p.cur, p.imp, p.target = nil, nil, nil, nil
        end
    end

    -- --- the mobs: facing and routes ---------------------------------------------------

    local known = {}             -- guid -> what is kept about a mob
    local swept_at = 0

    local function known_of(guid, now)
        local k = known[guid]
        if not k then
            k = { level_at = -1e9, hostile_at = -1e9, face_at = -1e9, route = {}, route_t = {}, ver = 0,
                stepped = -1e9, len = 0 }
            known[guid] = k
        end
        k.seen = now
        return k
    end

    local function hostile_of(k, obj, me, now)
        if now - k.hostile_at > HOSTILE_EVERY then
            k.hostile = call(me, "is_enemy_with", obj) == true
            k.hostile_at = now
        end
        return k.hostile
    end

    local function level_of(k, obj, now)
        if now - k.level_at > LEVEL_EVERY then
            k.level = tonumber(call(obj, "get_level")) or k.level
            k.level_at = now
        end
        return k.level
    end

    --- How far it notices you from: Pull safety's own rule when it is loaded.
    local function aggro_radius(level, my_level)
        local base = tonumber(opt("pull_base", 20)) or 20
        local pull = P.pull
        if pull and type(pull.aggro_radius) == "function" then
            local r = tonumber(ask(pull.aggro_radius, level, my_level, base))
            if r then return r end
        end
        if not level or not my_level or level <= 0 then return base end
        return max(5, min(45, base + (level - my_level)))
    end

    -- Routes ----------------------------------------------------------------------------

    local function clear_route(k)
        local route, times = k.route, k.route_t
        for i = #route, 1, -1 do route[i], times[i] = nil, nil end
        k.ver, k.len, k.stepped = k.ver + 1, 0, -1e9
    end

    local function add_point(k, x, y, z, t, step)
        local route, times = k.route, k.route_t
        local n = #route
        if n >= ROUTE_MAX then
            table.remove(route, 1)
            table.remove(times, 1)
            n = n - 1
        end
        route[n + 1], times[n + 1] = vec(x, y, (z or 0) + 0.1), t
        if step then k.stepped = t end
        k.ver = k.ver + 1
    end

    --- The enemies service's own trail: trail_n samples in a ring, trail_head
    --- the newest, so the oldest is the one after it. Its points a stride
    --- apart start a route.
    local function seed(k, r, now)
        local n, h = tonumber(r.trail_n) or 0, tonumber(r.trail_head) or 0
        local tx, ty, tt = r.trail_x, r.trail_y, r.trail_t
        if n < 2 or h < 1 or h > n or type(tx) ~= "table" or type(ty) ~= "table" then return end
        local s2 = STRIDE * STRIDE
        for j = 0, n - 1 do
            local i = ((h + j) % n) + 1
            local x, y = tx[i], ty[i]
            if type(x) == "number" and type(y) == "number" then
                local route = k.route
                local last = route[#route]
                if not last or (x - last.x) ^ 2 + (y - last.y) ^ 2 >= s2 then
                    add_point(k, x, y, r.z, type(tt) == "table" and tonumber(tt[i]) or now, last ~= nil)
                end
            end
        end
    end

    local function route_step(k, r, now)
        local route, times = k.route, k.route_t
        local old = 0
        while old < #route and now - times[old + 1] > ROUTE_AGE do old = old + 1 end
        if old > 0 then
            for _ = 1, old do
                table.remove(route, 1)
                table.remove(times, 1)
            end
            k.ver = k.ver + 1
        end
        local x, y = r.x, r.y
        if type(x) ~= "number" or type(y) ~= "number" then return end
        local n = #route
        if n == 0 then
            seed(k, r, now)
            local last = route[#route]
            if not last or (x - last.x) ^ 2 + (y - last.y) ^ 2 >= STRIDE * STRIDE then
                add_point(k, x, y, r.z, now, last ~= nil)
            end
            return
        end
        local last = route[n]
        if (x - last.x) ^ 2 + (y - last.y) ^ 2 >= STRIDE * STRIDE then add_point(k, x, y, r.z, now, true) end
    end

    --- Which way it is walking: over the enemies' own trail (the last second),
    --- else from the route's last point to where it stands. Radians or nil.
    local function heading(r, k, pos)
        local n, h = tonumber(r.trail_n) or 0, tonumber(r.trail_head) or 0
        local tx, ty = r.trail_x, r.trail_y
        if n >= 2 and h >= 1 and h <= n and type(tx) == "table" and type(ty) == "table" then
            local o = (h % n) + 1
            local x1, y1, x0, y0 = tx[h], ty[h], tx[o], ty[o]
            if type(x1) == "number" and type(y1) == "number" and type(x0) == "number" and type(y0) == "number" then
                local dx, dy = x1 - x0, y1 - y0
                if dx * dx + dy * dy > 0.25 then return atan2(dy, dx) end
            end
        end
        local route = k.route
        local last = route[#route]
        if last then
            local dx, dy = pos.x - last.x, pos.y - last.y
            if dx * dx + dy * dy > 0.25 then return atan2(dy, dx) end
            local prev = route[#route - 1]
            if prev then
                dx, dy = last.x - prev.x, last.y - prev.y
                if dx * dx + dy * dy > 0.25 then return atan2(dy, dx) end
            end
        end
        return nil
    end

    local old_opts = { thickness = 1.2, droppable = true }
    local new_opts = { thickness = 1.6, droppable = true }
    local arrow_opts = { thickness = 2.0, droppable = true }

    --- The route: its older half faint, its newer half and the step to where
    --- the mob stands now brighter; an arrow ahead of it. False when there is
    --- not enough of it to draw.
    local function draw_route(draw, k, r, obj, pos, layer, pc, now)
        local route = k.route
        local n = #route
        if n < 1 or now - k.stepped > ROUTE_HOLD then return false end
        if k.drawn_ver ~= k.ver then
            local older, newer = k.older or {}, k.newer or {}
            for i = #older, 1, -1 do older[i] = nil end
            for i = #newer, 1, -1 do newer[i] = nil end
            local split = max(1, floor(n / 2))
            for i = 1, split do older[#older + 1] = route[i] end
            for i = split, n do newer[#newer + 1] = route[i] end
            newer[#newer + 1] = pos
            local len = 0
            for i = 2, n do
                local a, b = route[i - 1], route[i]
                len = len + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
            end
            k.older, k.newer, k.len, k.drawn_ver = older, newer, len, k.ver
        end
        local last = route[n]
        local live = sqrt((pos.x - last.x) ^ 2 + (pos.y - last.y) ^ 2)
        if k.len + live < ROUTE_MIN then return false end
        local newer = k.newer
        newer[#newer] = pos
        old_opts.layer, new_opts.layer, arrow_opts.layer = layer, layer, layer
        if #k.older >= 2 then ask(draw.path_3d, k.older, pc.route_old, old_opts) end
        ask(draw.path_3d, newer, pc.route_new, new_opts)
        local a = heading(r, k, pos)
        if a then
            local ca, sa = cos(a), sin(a)
            local reach = edge_of(draw, obj) + 1.2
            local z = (pos.z or 0) + 0.1
            local tx, ty = pos.x + ca * reach, pos.y + sa * reach
            local bx, by = tx - ca * 0.9, ty - sa * 0.9
            ask(draw.path_3d, { vec(bx - sa * 0.6, by + ca * 0.6, z), vec(tx, ty, z), vec(bx + sa * 0.6, by - ca * 0.6, z) },
                pc.arrow, arrow_opts)
        end
        return true
    end

    -- Facing ----------------------------------------------------------------------------

    --- Radians it faces, read at most five times a second: get_direction (it
    --- answers on Forever), else get_rotation. A zero vector or a rotation of
    --- exactly 0 is taken for "not answered" rather than for due east.
    local function facing_of(k, obj, now)
        if now - k.face_at >= FACE_EVERY then
            k.face_at = now
            local a = nil
            local d = call(obj, "get_direction")
            if d ~= nil then
                local ok, x, y = pcall(xy, d)
                if ok and type(x) == "number" and type(y) == "number" and (x ~= 0 or y ~= 0) then a = atan2(y, x) end
            end
            if not a then
                local rot = tonumber(call(obj, "get_rotation"))
                if rot and rot == rot and rot ~= 0 then a = rot end
            end
            k.face = a
        end
        return k.face
    end

    --- The wedge's points, worked out again only once it has moved or turned.
    local function wedge(k, pos, face, radius)
        local c = k.cone
        if c and abs(c.x - pos.x) < MOVED and abs(c.y - pos.y) < MOVED and abs(wrap(c.a - face)) < TURNED
            and c.r == radius then
            return c
        end
        c = c or {}
        c.x, c.y, c.a, c.r = pos.x, pos.y, face, radius
        local z = (pos.z or 0) + 0.1
        local apex = vec(pos.x, pos.y, z)
        local half = (CONE_DEG / 2) * pi / 180
        local fan, edge = { apex }, { apex }
        for i = 0, ARC do
            local a = face - half + 2 * half * i / ARC
            local p = vec(pos.x + cos(a) * radius, pos.y + sin(a) * radius, z)
            fan[#fan + 1] = p
            edge[#edge + 1] = p
        end
        edge[#edge + 1] = apex
        c.fan, c.edge, c.apex = fan, edge, apex
        c.ahead = vec(pos.x + cos(face) * radius, pos.y + sin(face) * radius, z)
        k.cone = c
        return c
    end

    local fill_opts = { filled = true, droppable = true }
    local edge_opts = { thickness = 1.0, droppable = true }
    local cone_opts = { droppable = true }

    local function draw_wedge(draw, c, pc, layer)
        if draw.polygon_3d then
            fill_opts.layer = layer
            ask(draw.polygon_3d, c.fan, pc.cone, fill_opts)
            if draw.path_3d then
                edge_opts.layer = layer
                ask(draw.path_3d, c.edge, pc.cone_edge, edge_opts)
            end
            return true
        elseif draw.cone_3d then
            cone_opts.layer = layer
            ask(draw.cone_3d, c.apex, c.ahead, c.r, CONE_DEG, pc.cone_edge, cone_opts)
            return true
        end
        return false
    end

    local function render_mobs(draw, me, range, layer, pc, now, want_facing, want_routes)
        local svc = ctx.enemies
        local rows = svc and ask(svc.all)
        if type(rows) ~= "table" then return end
        if want_routes and not draw.path_3d then want_routes = false end
        if want_facing and not (draw.polygon_3d or draw.cone_3d) then want_facing = false end
        if not want_facing and not want_routes then return end
        local my_level = tonumber(ctx.player and ask(ctx.player.level)) or tonumber(call(me, "get_level"))
        if my_level and my_level <= 0 then my_level = nil end
        local keep_within = range + SAMPLE_PAST
        -- The enemies' rows come nearest first: the first eight and four are the nearest.
        for i = 1, #rows do
            local r = rows[i]
            local obj, guid = r and r.obj, r and r.guid
            if obj and guid then
                local k = known_of(guid, now)
                local dist = tonumber(r.dist) or huge
                if r.in_combat or r.engaged or r.dead or r.activity == "dead" then
                    -- A fight is not a patrol: its route starts again after.
                    if #k.route > 0 then clear_route(k) end
                elseif dist <= keep_within then
                    if want_routes then route_step(k, r, now) end
                    local tried = stats.facing + stats.unread
                    if dist <= range and (tried < FACING_MAX or stats.patrols < PATROLS_MAX)
                        and hostile_of(k, obj, me, now) then
                        local pos = units.position and ask(units.position, obj)
                        if pos and type(pos.x) == "number" then
                            if want_routes and stats.patrols < PATROLS_MAX
                                and draw_route(draw, k, r, obj, pos, layer, pc, now) then
                                stats.patrols = stats.patrols + 1
                            end
                            -- The nearest eight are asked, answered or not.
                            if want_facing and tried < FACING_MAX then
                                local face = facing_of(k, obj, now)
                                -- Nothing answered: a mob on the move faces the way it walks.
                                if not face and (r.moving == true or now - k.stepped <= ROUTE_HOLD) then
                                    face = heading(r, k, pos)
                                end
                                if face then
                                    local radius = aggro_radius(level_of(k, obj, now), my_level)
                                    if draw_wedge(draw, wedge(k, pos, face, radius), pc, layer) then
                                        stats.facing = stats.facing + 1
                                    end
                                else
                                    stats.unread = stats.unread + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    --- Forget the mobs not seen for a while, and the missiles long landed.
    local function sweep(now)
        if now - swept_at < SWEEP_EVERY then return end
        swept_at = now
        for guid, k in pairs(known) do
            if now - (k.seen or 0) > FORGET then known[guid] = nil end
        end
        for key, at in pairs(first_at) do
            if now - at > SWEEP_EVERY then first_at[key], first_left[key] = nil, nil end
        end
    end

    --- One frame. Called by main.lua's world-marks render job (before the
    --- world layer's flush at 190) under the master switch and toggle key.
    function M.render()
        stats.missiles, stats.rings, stats.covered, stats.facing, stats.unread, stats.patrols = 0, 0, 0, 0, 0, 0
        local draw = P.worldmarks or P.draw
        if not draw then return end
        if not opt("tracks_on", true) or not opt("world_on", true) then return end
        local me = units.player and ask(units.player)
        if not me then return end
        local mpos = units.position and ask(units.position, me)
        if not mpos or type(mpos.x) ~= "number" then return end
        local now = clock()
        local range = tonumber(opt("tracks_range", 40)) or 40
        local layer = (ctx.LAYER or {}).WORLD or 100
        local pc = passthrough_colors(draw)
        local me_guid = guid_of(me)

        if opt("tracks_missiles", true) then render_missiles(draw, me_guid, mpos, range, layer, pc, now) end

        local want_facing = opt("tracks_facing", true) and true or false
        local want_routes = (opt("tracks_patrols", true) and floor(tonumber(opt("world_density", 1)) or 1) < 3)
            and true or false
        if want_facing or want_routes then render_mobs(draw, me, range, layer, pc, now, want_facing, want_routes) end
        sweep(now)
    end

    --- This frame's count: missiles drawn, their rings, those a telegraph
    --- covers, wedges, mobs whose facing did not answer, routes.
    function M.stats() return stats end

    return M
end

-- Jambix AIO / worldlayer -- every world mark through one place (1.89.0).
--
-- The user, 2026-10-09, choosing what comes first: "Calibration window,
-- Performance budget, Ring layout + World marks page, Line-of-sight fade".
-- The AIO's world marks (pull safety, fight timers, the group, beacons, PvP,
-- your reactions, the reactions' marks, the aurora) call this instead of
-- JCore's draw directly, with the same names and arguments:
--
--   ring_3d(center, radius, fraction, col, opts)   curtain_3d(center, radius, col, opts)
--   beacon_3d(pos, col, opts)                      pulse(at, col, opts)
--
-- and a few more options: `prio` ("warn", "info" or "decor"), `module` (a
-- name for the stats), `unit` (the game object a mark stands under, for its
-- lane and the wall check) and, on a ring, `lane` (and `index`).
--
-- Nothing is drawn as it is called. The marks are kept, and at the end of
-- the AIO's render jobs (flush, from main.lua) they are:
--
--   LANED      a ring under a unit with a lane gets the lane's radius, so
--              the kick, time-to-die, your timers, CC, the trinket and your
--              reactions each have a band of their own and never overlap
--              (LANES below; the ESP's aggro and cast rings are the first
--              two, drawn by the ESP). Under a mob the player-only lanes
--              (trinket, CC, diminishing returns) take no room.
--   BUDGETED   past "Most world shapes a frame", decoration goes first, then
--              information; a warning is never dropped. A curtain costs by
--              its lines, a beacon three, a ring or a pulse one.
--   SHADED     brightness, a colour-blind correction (protanopia,
--              deuteranopia, tritanopia: the colours are shifted so what
--              tells them apart is a difference you can see), and density
--              (fewer points and a fainter sheet on curtains; Minimal leaves
--              decoration out).
--   FADED      a mark under a unit behind a wall is drawn at a third,
--              through JCore's rationed line-of-sight checks.
--
-- Then each goes to JCore's draw as it was asked for.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil

    local W = {}

    -- --- lanes ------------------------------------------------------------------
    --
    -- Yards outside a unit's model edge (combat reach + 0.3, 0.9 to 4, as the
    -- ESP measures it). Each band is BAND wide. A lane with an index steps
    -- outward by STEP for each.

    local BAND, STEP = 0.25, 0.35
    W.LANES = {
        aggro = 0.0,        -- the ESP's ring under anything on you (drawn by the ESP)
        cast = 0.35,        -- the ESP's cast ring (drawn by the ESP)
        kick = 0.7,         -- the reactions' kick lined up
        ttd = 1.05,         -- time to die
        trinket = 1.4,      -- an enemy player's PvP trinket
        cc = 1.75,          -- your crowd control on it, up to three
        dr = 2.8,           -- its diminishing returns, up to three
        timers = 3.85,      -- your damage and healing over time, up to four
        reaction = 5.25,    -- a reaction of yours about to fire, stacked
        -- under a party member
        party = 0.35,       -- their health
        reach = 0.7,        -- out of your heal range
        mana = 1.05,        -- a healer's mana
        -- under you
        control = 0.3,      -- the control on you
        gcd = 0.65,         -- your global cooldown
        swing = 1.0,        -- your swing
        missile = 1.4,      -- a missile on its way (under you or a party member)
    }
    -- Under anything not a player: no trinket, CC or diminishing returns, so
    -- your timers and reactions move in to where those would be.
    W.NPC_LANES = { timers = 1.4, reaction = 2.8 }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    --- The model's edge under a unit, as the ESP measures it.
    function W.edge(unit)
        local reach = unit and tonumber(ask(units.combat_reach, unit)) or 1.2
        return min(4, max(0.9, reach + 0.3))
    end

    -- Whether a unit is a player: the sweep's row (free), else asked once a
    -- frame each (cleared by flush).
    local player_seen = setmetatable({}, { __mode = "k" })
    local function is_player(unit)
        local v = player_seen[unit]
        if v == nil then
            local row = units.snapshot and ask(units.snapshot, unit)
            if type(row) == "table" and row.is_player ~= nil then
                v = row.is_player == true
            else
                v = type(unit) == "userdata" or type(unit) == "table"
                v = v and ask(unit.is_player, unit) == true or false
            end
            player_seen[unit] = v
        end
        return v
    end

    --- A lane's outer radius under a unit.
    ---@param unit game_object|nil
    ---@param lane string
    ---@param index? integer 1-based, for a lane with several
    ---@return number
    function W.lane_radius(unit, lane, index)
        local off = W.LANES[lane] or 0
        local npc = unit and W.NPC_LANES[lane]
        if npc and not is_player(unit) then off = npc end
        return W.edge(unit) + off + ((index or 1) - 1) * STEP + BAND
    end

    -- --- colours ------------------------------------------------------------------

    local function channels(c)
        local kind = type(c)
        if kind == "number" or kind == "string" or kind == "boolean" then return 255, 255, 255, 255 end
        if kind == "table" and c.r then return c.r, c.g, c.b, c.a or 255 end
        if c ~= nil then
            local ok, r, g, b, a = pcall(function() return c.r, c.g, c.b, c.a end)
            if ok and type(r) == "number" then return r, g, b, a or 255 end
            if c.get then
                local ok2, r2, g2, b2, a2 = pcall(c.get, c)
                if ok2 and r2 then return r2, g2, b2, a2 or 255 end
            end
        end
        return 255, 255, 255, 255
    end

    local function make(r, g, b, a)
        r, g, b = floor(max(0, min(255, r)) + 0.5), floor(max(0, min(255, g)) + 0.5), floor(max(0, min(255, b)) + 0.5)
        a = floor(max(0, min(255, a)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    -- Daltonisation: simulate the colour blindness in LMS space, take what is
    -- lost, and put it where it can be seen (Fidaner, Lin and Ozguven).
    local RGB2LMS = { { 17.8824, 43.5161, 4.11935 }, { 3.45565, 27.1554, 3.86714 }, { 0.0299566, 0.184309, 1.46709 } }
    local LMS2RGB = { { 0.0809444479, -0.130504409, 0.116721066 }, { -0.0102485335, 0.0540193266, -0.113614708 },
        { -0.000365296938, -0.00412161469, 0.693511405 } }
    local SIM = {
        [2] = { { 0, 2.02344, -2.52581 }, { 0, 1, 0 }, { 0, 0, 1 } },              -- protanopia
        [3] = { { 1, 0, 0 }, { 0.494207, 0, 1.24827 }, { 0, 0, 1 } },              -- deuteranopia
        [4] = { { 1, 0, 0 }, { 0, 1, 0 }, { -0.395913, 0.801109, 0 } },            -- tritanopia
    }
    local function mul(m, v)
        return { m[1][1] * v[1] + m[1][2] * v[2] + m[1][3] * v[3],
                 m[2][1] * v[1] + m[2][2] * v[2] + m[2][3] * v[3],
                 m[3][1] * v[1] + m[3][2] * v[2] + m[3][3] * v[3] }
    end
    --- r, g, b corrected for a colour blindness (mode 2..4); mode 1 as given.
    function W.daltonize(r, g, b, mode)
        local sim = SIM[mode]
        if not sim then return r, g, b end
        local seen = mul(LMS2RGB, mul(sim, mul(RGB2LMS, { r, g, b })))
        local er, eg, eb = r - seen[1], g - seen[2], b - seen[3]
        return r, g + 0.7 * er + eg, b + 0.7 * er + eb
    end

    -- Shaded colours, made once per colour, per setting and per fade.
    local shade_cache = setmetatable({}, { __mode = "k" })
    local look = { bright = 1, cb = 1, epoch = 0 }
    local function shade(c, fade)
        if c == nil then return nil end
        local key = look.epoch * 4 + (fade and 1 or 0)
        local per = shade_cache[c]
        if not per then
            per = {}
            shade_cache[c] = per
        end
        local hit = per[key]
        if hit then return hit end
        local r, g, b, a = channels(c)
        r, g, b = W.daltonize(r, g, b, look.cb)
        a = a * look.bright * (fade and 0.35 or 1)
        hit = make(r, g, b, a)
        per[key] = hit
        return hit
    end

    -- --- the frame's marks ----------------------------------------------------------

    local RANK = { warn = 1, info = 2, decor = 3 }
    local marks, n = {}, 0
    local stats = { kept = 0, dropped = 0, weight = 0, faded = 0, by = {}, budget = 0 }

    local function keep(kind, a1, a2, a3, a4, o)
        o = o or {}
        n = n + 1
        local m = marks[n]
        if not m then
            m = {}
            marks[n] = m
        end
        m.kind, m.a1, m.a2, m.a3, m.a4, m.o, m.order = kind, a1, a2, a3, a4, o, n
        m.rank = RANK[o.prio or "info"] or 2
        m.unit = o.unit
        if kind == "curtain" then
            m.weight = ceil(((o.points or 36) * (o.rings or 4)) / 40) + ((o.fill or 0) > 0 and 1 or 0)
        elseif kind == "beacon" then
            m.weight = 3
        else
            m.weight = 1
        end
    end

    function W.ring_3d(center, radius, fraction, col, o)
        if o and o.lane and o.unit then radius = W.lane_radius(o.unit, o.lane, o.index) end
        keep("ring", center, radius, fraction, col, o)
    end
    function W.curtain_3d(center, radius, col, o) keep("curtain", center, radius, col, nil, o) end
    function W.beacon_3d(pos, col, o) keep("beacon", pos, col, nil, nil, o) end
    function W.pulse(at, col, o) keep("pulse", at, col, nil, nil, o) end

    -- Whatever else a module asks JCore's draw for passes straight through.
    setmetatable(W, { __index = function(_, k) return P.draw and P.draw[k] end })

    local function by_rank(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.order < b.order
    end
    local sorted = {}

    local DENSITY_POINTS = { 1, 0.66, 0.4 }
    local DENSITY_FILL = { 1, 0.6, 0 }

    local DEFAULT_POINTS = { curtain = 36, beacon = 14 }
    local DEFAULT_FILL = { beacon = 0.5 }

    local function copy_opts(o, density, fade, kind)
        local c = {}
        for k, v in pairs(o) do c[k] = v end
        c.prio, c.module, c.unit, c.lane, c.index = nil, nil, nil, nil, nil
        -- A pulse's `from` and `to` are yards; every other mark's `to` and
        -- `bg` are colours.
        if kind ~= "pulse" then
            if c.to then c.to = shade(c.to, fade) end
            if c.bg then c.bg = shade(c.bg, fade) end
        end
        if density > 1 and DEFAULT_POINTS[kind] then
            c.points = max(8, floor((c.points or DEFAULT_POINTS[kind]) * DENSITY_POINTS[density] + 0.5))
            local fill = c.fill or DEFAULT_FILL[kind]
            if fill then c.fill = fill * DENSITY_FILL[density] end
        end
        return c
    end

    local function draw_one(draw, m, density, fade)
        local c = copy_opts(m.o, density, fade, m.kind)
        if m.kind == "ring" and draw.ring_3d then
            draw.ring_3d(m.a1, m.a2, m.a3, shade(m.a4, fade), c)
        elseif m.kind == "curtain" and draw.curtain_3d then
            draw.curtain_3d(m.a1, m.a2, shade(m.a3, fade), c)
        elseif m.kind == "beacon" and draw.beacon_3d then
            draw.beacon_3d(m.a1, shade(m.a2, fade), c)
        elseif m.kind == "pulse" and draw.pulse then
            draw.pulse(m.a1, shade(m.a2, fade), c)
        end
    end

    --- The end of the AIO's world marks for this frame (main.lua, priority 190).
    function W.flush()
        local draw = P.draw
        for k in pairs(stats.by) do stats.by[k] = nil end
        for k in pairs(player_seen) do player_seen[k] = nil end
        stats.kept, stats.dropped, stats.weight, stats.faded = 0, 0, 0, 0
        if n == 0 or not draw then
            n = 0
            return
        end
        local on = opt("world_on", true) ~= false
        local bright = (tonumber(opt("world_brightness", 100)) or 100) / 100
        local cb = floor(tonumber(opt("world_colorblind", 1)) or 1)
        if bright ~= look.bright or cb ~= look.cb then
            look.bright, look.cb, look.epoch = bright, cb, look.epoch + 1
        end
        local density = floor(tonumber(opt("world_density", 1)) or 1)
        local budget = floor(tonumber(opt("world_budget", 200)) or 200)
        local los = opt("world_los", true) ~= false and draw.unit_los
        if los and draw.set_los_budget then
            draw.set_los_budget(floor(tonumber(opt("world_los_checks", 8)) or 8))
        end
        stats.budget = budget

        for i = 1, n do sorted[i] = marks[i] end
        for i = n + 1, #sorted do sorted[i] = nil end
        table.sort(sorted, by_rank)

        local spent = 0
        for i = 1, n do
            local m = sorted[i]
            local o = m.o
            local name = o.module or "?"
            local drop = not on
                or (density >= 3 and m.rank >= 3)
                or (budget > 0 and m.rank > 1 and spent + m.weight > budget)
            if drop then
                stats.dropped = stats.dropped + 1
            else
                spent = spent + m.weight
                local fade = false
                if los and m.unit then
                    local seen = ask(draw.unit_los, m.unit)
                    fade = seen == false
                    if fade then stats.faded = stats.faded + 1 end
                end
                -- One bad mark must not cost the rest, nor stop the queue
                -- clearing: every later frame would fail the same way.
                local ok, err = pcall(draw_one, draw, m, density, fade)
                if ok then
                    stats.kept = stats.kept + 1
                    stats.by[name] = (stats.by[name] or 0) + 1
                else
                    stats.errors = (stats.errors or 0) + 1
                    stats.last_error = tostring(err)
                    stats.dropped = stats.dropped + 1
                end
            end
        end
        stats.weight = spent
        for i = 1, n do
            local m = marks[i]
            m.o, m.a1, m.a2, m.a3, m.a4, m.unit = nil, nil, nil, nil, nil, nil
        end
        n = 0
    end

    --- This frame's count: kept, dropped, the budget spent, faded, and per module.
    function W.stats() return stats end

    return W
end

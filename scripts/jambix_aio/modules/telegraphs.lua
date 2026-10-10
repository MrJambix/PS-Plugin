-- Jambix AIO / telegraphs -- the ground an enemy spell is about to hit (1.65.0).
--
-- JCore 1.8.0 works out every live telegraph (services/telegraphs.lua, from
-- the client's own spell tables and DBM's boss mods); this paints the danger,
-- never the safe ground:
--
--   ground   a circle around the caster, a circle where it aims, a cone in
--            front of it: a SEE-THROUGH fill and a crisp edge. The cast's
--            progress is a thin line sweeping out from the middle to the edge
--            (a ring for a circle, an arc for a cone), so "how long have I
--            got" reads off the shape without covering what stands in it.
--            Red while you are standing in it; a boss's mechanics (classified
--            boss, or a spell a boss mod warns of) get a heavier edge.
--   label    the spell, what to do about it (the boss mod's advice: "Dodge",
--            "Run out", "Breath: get out of the front") and the seconds left.
--   alerts   a short stack at the top of the screen for what has no ground to
--            paint: the room-wide (Bellowing Roar), the unplaceable (a
--            player's Blizzard), what is on you (Chill, Living Bomb), and
--            whatever you are standing in right now.
--
-- 1.65.1, the user: "it shouldnt be Full one color cant see other mobs or
-- myself in it". 1.65.0 grew a second, denser fill over the first as the cast
-- ran, which ended near two thirds opaque. Now the only fill is the faint one
-- (the "Fill strength" slider, capped at half), and progress is a line.
-- The cone is drawn from its own points (a fan polygon, edges and arc), so its
-- fill and its outline are the same shape whatever the native cone's angle
-- convention is.
--
-- 1.69.1, the user again: "u cant see shit with it", a 5 yd Throw Dynamite
-- painted solid gold. Not the fill: the native ring glows inward from its rim,
-- alpha * (d / r) ^ fade at d from the middle, and JCore passes a fade of 1.0,
-- so the glow fell off in a straight line over the whole disc (off the
-- screenshot: 92% at the rim, still 45% two thirds of the way in). The sweep
-- ring, at 200, glowed over the middle the same way. Every ring here now gets
-- the fade that keeps its glow to a thin band at the rim, whatever its size
-- (the Forever ESP's rings learned the same in 1.66.2).
--
-- Nothing is read from the game here but the instance type (for "Raids and
-- dungeons only") and a caster's classification, once per caster. A JCore
-- without the service (older than 1.8.0) leaves this module inert.

local ARC_STEPS = 16         -- points along a cone's arc
local FILL_CAP = 50          -- percent: the fill never goes past half opaque
local RIM_GLOW = 0.5         -- yards in from the edge where its glow is down to a quarter
local SWEEP_GLOW = 0.3       -- the same for the progress ring
local FADE_MIN, FADE_MAX = 2.5, 128   -- the native default; past the top a ring is a line anyway

--- The fade that brings a ring's inward glow down to a quarter `band` yards
--- in from its rim: (1 - band / r) ^ fade = 1/4. A ring too small for a band
--- keeps the native default.
local function fade_for(r, band)
    if not r or r <= band * 2 then return FADE_MIN end
    local f = math.log(0.25) / math.log(1 - band / r)
    return math.max(FADE_MIN, math.min(FADE_MAX, f))
end

return function(P)
    local ctx = P.ctx
    local draw = P.draw
    local opt = P.opt

    local M = {}

    local function service()
        local t = ctx and ctx.telegraphs
        if type(t) == "table" and type(t.active) == "function" then return t end
        return nil
    end
    M.available = function() return service() ~= nil end

    -- "Show telegraphs for" (cfg.TELE_WHO): 1 every hostile cast, 2 elites,
    -- bosses and boss-mod spells, 3 boss-mod spells only.
    -- "Show telegraphs in" (cfg.TELE_WHERE): 1 everywhere, 2 raids and dungeons only.

    -- --- colour ------------------------------------------------------------------

    local LEVEL_RGB = {
        [1] = { 255, 214, 64 },    -- the spell tables alone
        [2] = { 255, 150, 40 },    -- a boss mod warns of it
        [3] = { 255, 84, 32 },     -- a boss mod says move
    }
    local INSIDE_RGB = { 255, 32, 32 }
    local WHITE = { 255, 255, 255 }

    -- Colours by (rgb table, alpha), made once: allocating a colour per shape
    -- per frame is the cost that only shows with five plugins loaded.
    local palette = {}
    local function col(rgb, a)
        a = math.max(0, math.min(255, math.floor(a)))
        local by_alpha = palette[rgb]
        if not by_alpha then
            by_alpha = {}
            palette[rgb] = by_alpha
        end
        local c = by_alpha[a]
        if not c then
            c = P.color(rgb[1], rgb[2], rgb[3], a)
            by_alpha[a] = c
        end
        return c
    end

    -- --- who and where --------------------------------------------------------------

    local rank_cache = {}       -- guid -> classification (0 normal, 1 elite, 2 rare elite, 3 boss)
    local rank_seen = 0

    local function rank_of(t)
        if type(t.rank) == "number" then return t.rank end
        local src = t.source
        if not src or not t.source_guid then return 0 end
        local hit = rank_cache[t.source_guid]
        if hit == nil then
            local units = ctx.units
            local ok, c = pcall(function() return units.classification(src) end)
            hit = ok and type(c) == "number" and c or 0
            rank_cache[t.source_guid] = hit
        end
        return hit
    end

    --- A boss's mechanic: a classified boss, or a spell a boss mod warns of.
    local function boss_mechanic(t)
        return (t.level or 1) >= 2 or t.boss == true or rank_of(t) == 3
    end
    M.boss_mechanic = boss_mechanic

    local function in_instance()
        local world = ctx.world
        local ok, yes = pcall(function() return world.in_raid_instance() or world.in_dungeon() end)
        return ok and yes == true
    end

    local function wanted(t, who, range)
        if t.anchor == "player" then return true end
        if who == 3 and (t.level or 1) < 2 then return false end
        if who == 2 and not ((t.level or 1) >= 2 or rank_of(t) > 0) then return false end
        if t.by_player and not opt("tele_players", true) then return false end
        if t.phase == "missile" and not opt("tele_missiles", true) then return false end
        if t.phase == "linger" and not opt("tele_linger", true) then return false end
        if (t.dist or 0) > range + (t.radius or 0) then return false end
        return true
    end

    -- --- text --------------------------------------------------------------------------

    local function seconds(t)
        local r = t.remaining
        if type(r) ~= "number" or r <= 0 or r > 99 then return nil end
        return string.format("%.1fs", r)
    end

    local function label_of(t, with_hint)
        local parts = {}
        if t.inside and t.placed and not t.wide then parts[#parts + 1] = "MOVE:" end
        parts[#parts + 1] = t.name or ("spell " .. tostring(t.spell_id))
        if with_hint and t.hint then parts[#parts + 1] = "- " .. t.hint end
        local s = seconds(t)
        if s then parts[#parts + 1] = s end
        return table.concat(parts, " ")
    end

    -- --- painting ----------------------------------------------------------------------

    local function vec(x, y, z)
        local geo = ctx.geometry
        return geo and geo.vec(x, y, z) or { x = x, y = y, z = z }
    end

    --- Points along a cone's arc at `r`, from one edge to the other.
    local function arc_points(t, r)
        local half = math.rad((t.degrees or 60) / 2)
        local f = t.facing or 0
        local pts = {}
        for i = 0, ARC_STEPS do
            local a = f - half + (2 * half) * i / ARC_STEPS
            pts[#pts + 1] = vec(t.x + math.cos(a) * r, t.y + math.sin(a) * r, t.z)
        end
        return pts
    end

    --- THE COUNTDOWN WALL (1.85.0): a circle still to land gets JCore 1.11's
    --- ring_3d round its edge, filling as the cast runs, and Aurora Systems'
    --- curtain standing on that edge, rising toward impact -- how long you
    --- have, read off its height. Where JCore has no ring_3d, the old sweep.
    local WALL_HEIGHT = 1.4      -- yards at impact
    local WALL_POINTS = 40

    local function paint_wall(t, rgb, p, LAYER)
        local r = t.radius or 0
        draw.ring_3d(t.pos, r, p, col(rgb, 150), { to = col(INSIDE_RGB, 220), bg = col(rgb, 40),
            inner = 0.9, outer = 1.0, layer = LAYER })
        if draw.curtain_3d then
            draw.curtain_3d(t.pos, r, col(rgb, 200), { to = col(rgb, 70), height = 0.15 + WALL_HEIGHT * p,
                rings = 3, points = WALL_POINTS, verticals = 4, folds = 6, wave = 0.08, vwave = 0.1,
                spin = 0.35, layer = LAYER, droppable = not t.inside and not boss_mechanic(t) })
        end
    end

    local function paint_ground(t, fill_a, labels, wall)
        local LAYER = draw.LAYER and draw.LAYER.DANGER or 200
        local rgb = t.inside and INSIDE_RGB or (LEVEL_RGB[t.level or 1] or LEVEL_RGB[1])
        local p = t.progress
        local r = t.radius or 0
        local heavy = boss_mechanic(t)
        local edge = t.inside and 3 or (heavy and 2.5 or 1.5)
        local sweeping = type(p) == "number" and p > 0 and p < 1 and t.phase ~= "linger"
        if t.shape == "circle" then
            if fill_a > 0 then
                draw.circle_3d(t.pos, r, col(rgb, fill_a), { filled = true, layer = LAYER, droppable = not heavy and not t.inside })
            end
            draw.circle_3d(t.pos, r, col(rgb, 235), { thickness = edge, fade = fade_for(r, RIM_GLOW), layer = LAYER })
            if sweeping and wall and draw.ring_3d then
                paint_wall(t, rgb, p, LAYER)
            elseif sweeping then
                local rs = math.max(0.3, r * p)
                draw.circle_3d(t.pos, rs, col(rgb, 200), { thickness = 1.5, fade = fade_for(rs, SWEEP_GLOW), layer = LAYER })
            end
        elseif t.shape == "cone" and t.facing then
            local arc = arc_points(t, r)
            if fill_a > 0 then
                local fan = { t.pos }
                for i = 1, #arc do fan[#fan + 1] = arc[i] end
                draw.polygon_3d(fan, col(rgb, fill_a), { filled = true, layer = LAYER, droppable = not heavy and not t.inside })
            end
            local outline = { t.pos }
            for i = 1, #arc do outline[#outline + 1] = arc[i] end
            outline[#outline + 1] = t.pos
            draw.path_3d(outline, col(rgb, 235), { thickness = edge, layer = LAYER })
            if sweeping then
                draw.path_3d(arc_points(t, math.max(0.3, r * p)), col(rgb, 200), { thickness = 1.5, layer = LAYER })
            end
        end
        if labels then
            local at
            if t.shape == "cone" and t.facing then
                at = vec(t.x + math.cos(t.facing) * r * 0.35, t.y + math.sin(t.facing) * r * 0.35, t.z + 1.0)
            else
                at = vec(t.x, t.y, t.z + 1.0)
            end
            draw.text_3d(at, label_of(t, true), col(t.inside and INSIDE_RGB or WHITE, 255), { size = t.inside and 16 or 13 })
        end
    end

    local function paint_alerts(list)
        if #list == 0 then return end
        local ok, w, h = pcall(draw.screen_size)
        if not ok or type(w) ~= "number" then w, h = 1920, 1080 end
        local x, y = w * 0.5, h * 0.2
        for i = 1, math.min(#list, 4) do
            local t = list[i]
            local rgb = t.inside and INSIDE_RGB or (LEVEL_RGB[t.level or 1] or LEVEL_RGB[1])
            local text = label_of(t, true)
            if t.inside and t.placed and not t.wide then text = "Standing in " .. (t.name or "it") .. (t.hint and (" - " .. t.hint) or "") end
            draw.text_bg({ x = x, y = y + (i - 1) * 24 }, text, col(rgb, 255), { size = 16, centered = true, layer = draw.LAYER and draw.LAYER.HUD })
        end
    end

    local alerts = {}

    --- One frame. Called by main.lua's render job while the overlay is on.
    function M.render()
        local svc = service()
        if not svc or not opt("tele_on", true) then return end
        local list = svc.active()
        if #list == 0 then return end
        if opt("tele_where", 1) == 2 and not in_instance() then return end
        local who = opt("tele_who", 1)
        local range = opt("tele_range", 60)
        local pct = math.max(0, math.min(FILL_CAP, opt("tele_fill", 15)))
        local fill_a = 255 * pct / 100
        local labels = opt("tele_labels", true)
        local show_alerts = opt("tele_alerts", true)
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        local wall = opt("tele_wall", false)
        for i = #alerts, 1, -1 do alerts[i] = nil end

        -- A rank answer is kept for a while, not for ever: a guid can be reused.
        local now = core.time()
        if now - rank_seen > 60 then rank_cache, rank_seen = {}, now end

        for i = 1, #list do
            local t = list[i]
            if wanted(t, who, range) then
                if t.placed and not t.wide and t.pos then
                    paint_ground(t, fill_a, labels, wall)
                    if t.inside then alerts[#alerts + 1] = t end
                else
                    alerts[#alerts + 1] = t
                end
            end
        end
        if show_alerts then paint_alerts(alerts) end
    end

    --- For the debug page: one line saying what the service holds.
    function M.summary()
        local svc = service()
        if not svc then return "telegraphs: JCore 1.8.0 or newer needed" end
        local ok, s = pcall(svc.stats)
        if not ok or type(s) ~= "table" then return "telegraphs: no stats" end
        if not s.available then return "telegraphs: " .. tostring(s.error or "no data") end
        return string.format("telegraphs: %d live, %d on you (%d casts, %d missiles, %d ground, %d hazards) from %s",
            s.active or 0, s.on_me or 0, s.casts or 0, s.missiles or 0, s.lingering or 0, s.hazards or 0, tostring(s.source))
    end

    return M
end

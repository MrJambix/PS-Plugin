-- Jambix AIO / aurora -- an aurora around you that reads the fight (1.86.0).
--
-- The user, 2026-10-08, on Lemons' Aurora Systems plugin: "if i dont enable
-- lemons aurora how owuld it look??" ... "I'd like to go beyond that and
-- improve it even More!". This is that curtain, drawn with JCore 1.11's
-- curtain_3d (180 lines where Aurora Systems draws 1,020, its settings read
-- once a frame rather than 9,400 times) and made to say something:
--
--   CALM / FIGHT  out of combat it stands low and drifts; in a fight it
--                 rises and quickens. The change is eased, never a jump.
--   HEALTH        under half health it warms toward amber, under a quarter
--                 it burns red and breathes, faster the lower you are.
--   ATTACKERS     each enemy on you (up to three) adds a fold to its wave.
--   SHEET (1.87)  a see-through glowing sheet between its rings, fading
--                 upward (JCore 1.13's `fill`), stronger in a fight.
--
-- Colours: "Reacts to the fight" (your class colour rising into violet,
-- warmed by your health), your class colour alone, Aurora Systems' own
-- turquoise to purple, or a rainbow.
--
-- 1.88.0: the glow ring under it and the ring at your feet filling with your
-- cast are gone. The user: "Take the Ring around me and remove it I dont
-- htink its necessary" (both, asked which). With the glow gone the style
-- choice went too; the curtain is all there is.

return function(P)
    local ctx = P.ctx
    local opt = P.opt
    local floor, max, min, sin, abs = math.floor, math.max, math.min, math.sin, math.abs

    local M = {}

    -- The Colours dropdown (config.lua's AURORA_COLORS), in this order.
    local COLOR_REACT, COLOR_CLASS, COLOR_AURORA, COLOR_RAINBOW = 1, 2, 3, 4

    local CLASS_KEY = {
        [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
        [6] = "DEATHKNIGHT", [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [10] = "MONK",
        [11] = "DRUID", [12] = "DEMONHUNTER", [13] = "EVOKER",
    }
    local VIOLET = { 147, 112, 219 }
    local TURQUOISE = { 64, 224, 208 }
    local AMBER = { 245, 175, 60 }
    local RED = { 240, 70, 60 }

    local EASE = 2.5             -- per second: how fast calm and fight blend
    local ATTACKERS_EVERY = 0.25 -- seconds between counts of what is on you

    local function clock() return core.time() end
    local function color(rgb, a)
        local r, g, b = floor(rgb[1] + 0.5), floor(rgb[2] + 0.5), floor(rgb[3] + 0.5)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local function mix(a, b, t)
        return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
    end
    --- Hue 0..1 at full saturation, a little softened.
    local function hue(h)
        h = h % 1
        local i, f = floor(h * 6), h * 6 - floor(h * 6)
        local q, t = 1 - f, f
        local rgb = ({ { 1, t, 0 }, { q, 1, 0 }, { 0, 1, t }, { 0, q, 1 }, { t, 0, 1 }, { 1, 0, q } })[i + 1]
        return { 60 + 195 * rgb[1], 60 + 195 * rgb[2], 60 + 195 * rgb[3] }
    end

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    -- --- the fight, read once a frame -------------------------------------------

    local heat = 0               -- 0 calm .. 1 fighting, eased
    local last_t = nil
    -- The wave's and the breath's own clocks, advanced by their rate each
    -- frame. A rate that changes (calm to fight, health dropping) then speeds
    -- the motion up; times the clock since injection by a changed rate would
    -- jump it ten radians a frame.
    local wave_phase, breath_phase = 0, 0
    local attackers, attackers_at = 0, -1
    local stats = { drawn = 0, heat = 0, attackers = 0, hp = 1, lines = 0 }

    local function count_attackers(now)
        if now - attackers_at < ATTACKERS_EVERY then return attackers end
        attackers_at = now
        local n = 0
        local rows = ask(ctx.enemies and ctx.enemies.all)
        if type(rows) == "table" then
            for i = 1, #rows do
                local r = rows[i]
                if r and r.targeting_me and not r.dead then n = n + 1 end
            end
        end
        attackers = n
        return n
    end

    local function class_rgb()
        local id = ctx.player and ask(ctx.player.class_id)
        local key = CLASS_KEY[id or 0]
        local rgb = key and P.cfg and P.cfg.CLASS_RGB and P.cfg.CLASS_RGB[key]
        return rgb or TURQUOISE
    end

    -- --- drawing -----------------------------------------------------------------

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.drawn, stats.lines = 0, 0
        -- Through the world layer (1.89.0): the look, the budget (decoration).
        local draw = P.worldmarks or P.draw
        if not (draw and draw.curtain_3d) then return end
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        if not opt("aurora_on", false) then return end
        local pl = ctx.player
        local pos = pl and ask(pl.position)
        if not pos then return end

        local now = clock()
        local dt = last_t and min(0.25, max(0, now - last_t)) or 0
        last_t = now
        local fighting = ask(pl.in_combat) == true
        local target = fighting and 1 or 0
        heat = heat + (target - heat) * min(1, dt * EASE)
        if abs(heat - target) < 0.01 then heat = target end
        -- "Only in a fight": it fades out with the fight rather than vanishing.
        local presence = 1
        if opt("aurora_combat_only", false) then
            presence = heat
            if presence <= 0 then return end
        end
        local hp = tonumber(ask(pl.health_pct)) or 1
        if hp > 1.5 then hp = hp / 100 end
        local on_me = fighting and count_attackers(now) or 0
        stats.heat, stats.attackers, stats.hp = heat, on_me, hp

        local mode = tonumber(opt("aurora_colors", COLOR_REACT)) or COLOR_REACT
        local radius = tonumber(opt("aurora_radius", 2.0)) or 2.0
        local height = tonumber(opt("aurora_height", 1.2)) or 1.2
        local speed = tonumber(opt("aurora_speed", 1.0)) or 1.0
        local points = floor(tonumber(opt("aurora_detail", 36)) or 36)

        -- Low health: warmer, and a breath in the height that quickens.
        local danger = hp < 0.5 and min(1, (0.5 - hp) / 0.35) or 0
        local rate = speed * (0.5 + 0.8 * heat + 0.8 * danger)
        wave_phase = wave_phase + dt * rate
        stats.rate = rate
        local breath = 0
        if hp < 0.25 then
            breath_phase = breath_phase + dt * (2 + 6 * (0.25 - max(0, hp)) / 0.25) * math.pi
            breath = 0.5 + 0.5 * sin(breath_phase)
        end

        local bottom, top
        if mode == COLOR_CLASS then
            bottom, top = class_rgb(), class_rgb()
        elseif mode == COLOR_AURORA then
            local phase = (sin(now * speed) + 1) / 2
            bottom, top = mix(TURQUOISE, VIOLET, phase), mix(VIOLET, TURQUOISE, phase)
        elseif mode == COLOR_RAINBOW then
            bottom, top = hue(now * 0.08 * speed), hue(now * 0.08 * speed + 0.33)
        else
            bottom, top = class_rgb(), VIOLET
            if danger > 0 then
                local warm = hp < 0.25 and RED or AMBER
                bottom, top = mix(bottom, warm, danger), mix(top, warm, danger * 0.8)
            end
        end
        local alpha = (140 + 70 * heat) * presence

        local h = height * (0.55 + 0.45 * heat) * (1 + 0.25 * breath)
        draw.curtain_3d(pos, radius, color(bottom, alpha), {
            to = color(top, alpha * 0.45),
            height = h,
            points = points,
            rings = 4,
            verticals = 3,
            folds = 3 + min(3, on_me),
            wave = min(0.5, radius * 0.22) * (0.6 + 0.4 * heat),
            vwave = 0.15 + 0.2 * heat,
            speed = 1,
            spin = 0.6,          -- turns with the wave: faster in a fight
            time = wave_phase,
            fill = opt("aurora_fill", true) and (0.22 + 0.18 * heat) * presence or nil,
            layer = ctx.LAYER and ctx.LAYER.WORLD,
            prio = "decor", module = "aurora",
        })
        stats.drawn = stats.drawn + 1
        stats.lines = 4 * points + floor((points + 2) / 3) * 3
    end

    function M.stats() return stats end

    return M
end

-- Jambix AIO / react / marks -- what the reactions decide, on the ground (1.85.0).
--
-- The user, 2026-10-08: "what can it do for ... Reactions??? how can
-- reactions benefit and improve from this!! PVP wise too". JCore 1.11's
-- ring_3d and curtain_3d put the reactions' decisions where the eye already
-- is, under the units they are about:
--
--   KICK      under a caster an interrupt is lined up for, a ring filling
--             toward the moment the kick goes: a harmless cast is kicked in
--             its last 2 s (the Interrupt rule's "kick it late"), anything
--             else at once. Amber while it waits, green once it is chosen,
--             grey when the kick is refused (on cooldown, out of range).
--   ACTED     a ring opening out under whoever a reaction just acted on --
--             the mob it kicked, the add it put to sleep, you for a
--             defensive -- in the colour of the reaction's kind.
--   VANISHED  where an enemy player vanished or stealthed beside you: a red
--             curtain on the spot, sinking over the 3 s the reactions treat
--             it as news, with a ring emptying under it.
--   CONTROL   a ring at your feet emptying as the stun, fear or sheep on you
--             runs out, purple turning green as you come free.
--   BURST     a red curtain around the enemy player bursting on you.
--
-- R.tick hands each decision over (capture); the render job draws it
-- (render). What is kept is values, plus the unit objects positions are
-- read from at draw time. A mark not refreshed for a moment goes, so a
-- paused rotation leaves nothing behind.

return function(P)
    local units = P.units
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local KICK_AT = 2.0          -- seconds left: when the Interrupt rule kicks a harmless cast
    local STALE = 0.6            -- seconds: a kick or burst mark not refreshed this long is gone
    local PULSE_LIFE = 0.7       -- seconds an ACTED ring takes to open out and fade
    local PULSE_MAX = 8
    local VANISH_KEEP = 3.0      -- pvp.lua's: how long a vanish is news
    local RING_GAP = 0.9         -- yards outside the model: clear of the ESP's aggro and cast rings

    local function clock() return core.time() end
    local function game_ms()
        local ok, v = pcall(core.game_time)
        return ok and tonumber(v) or nil
    end

    local function color(r, g, b, a)
        if P.color then return P.color(r, g, b, a or 255) end
        return { r = r, g = g, b = b, a = a or 255 }
    end
    local C = {
        band    = color(0, 0, 0, 170),
        wait    = color(240, 180, 60),
        go      = color(100, 220, 130),
        blocked = color(150, 150, 158),
        vanish  = color(235, 70, 60),
        vanish_top = color(120, 20, 30, 120),
        control = color(170, 120, 250),
        free    = color(100, 220, 130),
        burst   = color(240, 70, 60),
        burst_top = color(250, 170, 60, 140),
    }
    -- ACTED's colour by the reaction's category (rules/core.lua's list).
    local KIND_RGB = {
        survival = { 100, 220, 130 }, defensive = { 100, 220, 130 }, escape = { 90, 180, 250 },
        bailout = { 90, 180, 250 }, interrupt = { 170, 120, 250 }, cc = { 170, 120, 250 },
        pet = { 240, 180, 60 }, threat = { 240, 180, 60 }, utility = { 200, 200, 210 },
        buff = { 200, 200, 210 }, low = { 200, 200, 210 },
    }
    local OFFENSE_RGB = { 240, 90, 70 }
    -- A pulse's colour per kind and per tenth of its fade, made once.
    local pulse_colors = {}
    local function pulse_color(kind, offensive, step)
        local key = (offensive and "!" or "") .. (kind or "?")
        local list = pulse_colors[key]
        if not list then
            list = {}
            pulse_colors[key] = list
        end
        local c = list[step]
        if not c then
            local rgb = offensive and OFFENSE_RGB or KIND_RGB[kind] or KIND_RGB.utility
            c = color(rgb[1], rgb[2], rgb[3], floor(220 * step / 10 + 0.5))
            list[step] = c
        end
        return c
    end

    -- --- what the last decision said -----------------------------------------

    local kicks, kick_n = {}, 0   -- one per caster
    local pulses = {}             -- newest last
    local burst = nil             -- { obj, at }
    local vanish = nil            -- { pos, at }
    local control = nil           -- { name, total, left, at }
    local stats = { kicks = 0, pulses = 0, vanish = 0, control = 0, burst = 0, drawn = 0 }

    local RANK = { selected = 3, waiting = 2 }

    --- Called by R.tick after the decision has been carried out.
    ---@param W table the world
    ---@param d table engine.decide's decision
    ---@param verdict table which lanes acted this tick
    function M.capture(W, d, verdict)
        local now = W.now or clock()
        local now_ms = game_ms()

        -- KICK: every candidate carrying a cast, one mark per caster, the
        -- most decided state winning.
        local by_guid = {}
        kick_n = 0
        local cands = d and d.cands or {}
        for i = 1, #cands do
            local c = cands[i]
            local cast = c.cast
            if cast and c.target and cast.started and (cast.total or 0) > 0 then
                local guid = cast.guid or tostring(c.target)
                local rank = RANK[c.state] or 1
                local k = by_guid[guid]
                if not k or rank > k.rank then
                    if not k then
                        kick_n = kick_n + 1
                        k = kicks[kick_n] or {}
                        kicks[kick_n] = k
                        by_guid[guid] = k
                    end
                    k.obj, k.rank, k.at = c.target, rank, now
                    k.start_ms = cast.started
                    k.end_ms = cast.started + cast.total * 1000
                    k.channel = cast.channel == true
                    -- Waiting is the Interrupt rule's "kick it late": the
                    -- kick goes with KICK_AT seconds left.
                    k.kick_at = (c.state == "waiting") and KICK_AT or 0
                    k.fallback_ms = now_ms
                end
            end
        end
        for i = kick_n + 1, #kicks do kicks[i] = nil end
        stats.kicks = kick_n

        -- ACTED: the lanes that acted this tick.
        if verdict and d then
            local me = W.player and W.player.unit
            for _, lane in ipairs({ "fast", "gcd", "pet" }) do
                local c = verdict[lane] and d[lane]
                if c then
                    local def = c.rule or {}
                    pulses[#pulses + 1] = { obj = c.target or me, at = now, kind = def.category,
                        offensive = c.offensive == true and def.category ~= "interrupt" }
                    if #pulses > PULSE_MAX then table.remove(pulses, 1) end
                end
            end
        end

        -- PvP.
        local V = W.pvp
        if V then
            local b = V.burster
            burst = (b and b.unit) and { obj = b.unit, at = now } or nil
            local v = V.vanished
            if v and v.pos then
                if not vanish or vanish.at ~= v.at then vanish = { pos = v.pos, at = v.at } end
            end
            local ctl = V.control
            if ctl and (ctl.remaining or 0) > 0 then
                local left = ctl.remaining
                -- A new control, or the same one renewed: its length is what
                -- was left when it was first seen.
                if not control or control.name ~= ctl.name or left > control.left + 0.3 then
                    control = { name = ctl.name, total = left }
                end
                control.left, control.at = left, now
            else
                control = nil
            end
        end
    end

    -- --- drawing ---------------------------------------------------------------

    local function radius_of(obj)
        local reach = units.combat_reach and units.combat_reach(obj) or nil
        return min(4, max(0.9, (tonumber(reach) or 1.2) + 0.3)) + RING_GAP
    end

    local function position(obj)
        if not obj then return nil end
        local ok, pos = pcall(units.position, obj)
        return ok and pos or nil
    end

    --- The render job: everything captured, drawn on the world layer.
    function M.render()
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        if P.opt and P.opt("react_world", true) == false then return end
        local now, now_ms = clock(), game_ms()
        local L = P.ctx and P.ctx.LAYER or {}
        local layer = L.WORLD or 100
        stats.drawn = 0

        for i = 1, kick_n do
            local k = kicks[i]
            local pos = (now - k.at) <= STALE and position(k.obj) or nil
            if pos then
                local ms = now_ms or k.fallback_ms or k.start_ms
                local total = (k.end_ms - k.start_ms) / 1000
                local left = max(0, (k.end_ms - ms) / 1000)
                local frac
                if k.rank == 3 then
                    frac = 1
                else
                    frac = min(1, max(0, (total - left) / max(0.1, total - k.kick_at)))
                end
                local col, to
                if k.rank == 3 then col, to = C.go, C.go
                elseif k.rank == 2 then col, to = C.wait, C.go
                else col, to = C.blocked, C.blocked end
                draw.ring_3d(pos, radius_of(k.obj), frac, col,
                    { to = to, bg = C.band, layer = layer, inner = 0.82,
                      unit = k.obj, lane = "kick", prio = k.rank >= 2 and "warn" or "info", module = "react" })
                stats.drawn = stats.drawn + 1
            end
        end

        local keep = 1
        for i = 1, #pulses do
            local p = pulses[i]
            local age = now - p.at
            if age < PULSE_LIFE then
                pulses[keep] = p
                keep = keep + 1
                local pos = position(p.obj)
                if pos then
                    local t = age / PULSE_LIFE
                    local step = max(1, floor((1 - t) * 10 + 0.5))
                    draw.ring_3d(pos, 0.8 + 1.6 * t, 1, pulse_color(p.kind, p.offensive, step),
                        { bg = pulse_color(p.kind, p.offensive, max(1, floor(step / 3))), layer = layer,
                          inner = 0.86, outer = 1.0, prio = "info", module = "react" })
                    stats.drawn = stats.drawn + 1
                end
            end
        end
        for i = #pulses, keep, -1 do pulses[i] = nil end
        stats.pulses = keep - 1

        stats.vanish, stats.control, stats.burst = 0, 0, 0
        if vanish then
            local age = now - vanish.at
            if age >= 0 and age <= VANISH_KEEP then
                local left = 1 - age / VANISH_KEEP
                -- 1.7.6: the curtain has its own switch, off by default.
                if draw.curtain_3d and P.opt and P.opt("react_curtain_vanish", false) == true then
                    draw.curtain_3d(vanish.pos, 1.6, C.vanish, { to = C.vanish_top, height = 0.3 + 1.3 * left,
                        rings = 3, points = 28, spin = 2.5, layer = layer, prio = "warn", module = "react" })
                end
                draw.ring_3d(vanish.pos, 1.8, left, C.vanish, { bg = C.band, layer = layer, prio = "warn", module = "react" })
                stats.vanish, stats.drawn = 1, stats.drawn + 1
            elseif age > VANISH_KEEP then
                vanish = nil
            end
        end

        if control and (now - control.at) <= STALE then
            local left = max(0, control.left - (now - control.at))
            local frac = control.total > 0 and min(1, left / control.total) or 0
            local pos = position(units.player and units.player() or nil)
            if pos and frac > 0 then
                -- Purple while it holds you, turning green as it runs out.
                local col = draw.blend and draw.blend(C.control, C.free, 1 - frac) or C.control
                draw.ring_3d(pos, 1.3, frac, col, { to = col, bg = C.band, layer = layer, direction = -1,
                    prio = "warn", module = "react" })
                stats.control, stats.drawn = 1, stats.drawn + 1
            end
        end

        -- 1.7.6: the burst mark is a curtain: its own switch, off by default.
        if burst and (now - burst.at) <= STALE and draw.curtain_3d
            and P.opt and P.opt("react_curtain_burst", false) == true then
            local pos = position(burst.obj)
            if pos then
                draw.curtain_3d(pos, radius_of(burst.obj) - 0.2, C.burst, { to = C.burst_top, height = 1.8,
                    rings = 4, points = 32, spin = 1.6, speed = 2.2, layer = layer,
                    unit = burst.obj, prio = "warn", module = "react" })
                stats.burst, stats.drawn = 1, stats.drawn + 1
            end
        end
    end

    --- For the Debug page and the tests.
    function M.stats() return stats end

    --- Between fights: nothing carried over.
    function M.reset()
        kick_n, burst, vanish, control = 0, nil, nil, nil
        for i = #kicks, 1, -1 do kicks[i] = nil end
        for i = #pulses, 1, -1 do pulses[i] = nil end
    end

    return M
end

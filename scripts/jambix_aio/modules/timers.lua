-- Jambix AIO / timers -- your spells' clocks under your target (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "Fight timers".
--
--   YOUR TIMERS  every damage or healing over time spell of yours on your
--                target, as rings round its feet, one inside the other,
--                each emptying as it runs out (a spell's ring keeps its
--                colour). Red with 3 s left: refresh it now. A pulse when
--                one runs out on a target still standing.
--   KILL NEXT    the mob the reactions' plan says to kill next, when it is
--                not your target: a red curtain round it, and a pulse when
--                the plan changes its mind. (The plan exists in a fight of
--                two or more when you are not the tank or the healer.)
--
-- Auras are read off the target five times a second, kept only when your
-- guid cast them. A spell's full length is not read: the client's duration
-- field is unproven, so a ring empties from what was left the first time
-- it was seen, and starts again when the spell is refreshed.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local READ_EVERY = 0.2       -- seconds between aura reads
    local RINGS = 4              -- at most this many timers
    local WARN = 3.0             -- seconds left: red
    local GAP = 0.4              -- yards between rings
    local PERMANENT = 600        -- seconds: longer is not a timer

    local function clock() return core.time() end
    local function game_ms()
        local ok, v = pcall(core.game_time)
        return ok and tonumber(v) or 0
    end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    local PALETTE = {
        color(140, 120, 240), color(90, 200, 220), color(120, 210, 120),
        color(240, 180, 60), color(230, 120, 200), color(200, 200, 210),
    }
    local C = {
        band = color(0, 0, 0, 110), warn = color(240, 70, 60), gone = color(240, 70, 60, 230),
        focus = color(240, 70, 60), focus_top = color(240, 70, 60, 30), focus_pulse = color(250, 120, 90, 230),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    -- --- reading your auras on the target ---------------------------------------

    local read_at, read_guid = -1e9, nil
    local mine = {}              -- spell id -> { expire_ms, total, slot }
    local next_slot = 1
    local my_guid = nil

    local function guid_of(obj)
        if not obj then return nil end
        return (units.guid and units.guid(obj)) or ask(obj.get_guid, obj)
    end

    local function read(target, now)
        local tguid = guid_of(target)
        if tguid ~= read_guid then
            mine, next_slot, read_guid = {}, 1, tguid
        end
        if now - read_at < READ_EVERY then return end
        read_at = now
        my_guid = my_guid or guid_of(units.player and units.player())
        local list = ask(target.get_auras, target)
        local seen = {}
        local ms = game_ms()
        if type(list) == "table" and my_guid then
            for i = 1, #list do
                local a = list[i]
                local id, expire = a and tonumber(a.buff_id), a and tonumber(a.expire_time)
                local caster = a and a.caster
                if id and expire and caster and guid_of(caster) == my_guid then
                    local left = (expire - ms) / 1000
                    if left > 0 and left < PERMANENT then
                        seen[id] = true
                        local m = mine[id]
                        if not m then
                            m = { slot = next_slot }
                            next_slot = next_slot % #PALETTE + 1
                            mine[id] = m
                        end
                        -- Refreshed (or new): its length is what is left now.
                        if not m.total or left > m.left_at_read + 0.5 then m.total = left end
                        m.expire_ms, m.left_at_read = expire, left
                    end
                end
            end
        end
        for id, m in pairs(mine) do
            if not seen[id] then
                mine[id] = nil
                m.fell_off = true
                M._fell_off = (M._fell_off or 0) + 1
                -- A timer that ran out on a target still standing: a pulse.
                local dead = ask(units.is_dead, target)
                local d = P.worldmarks or P.draw
                if not dead and d and d.pulse and opt("timers_warn", true) then
                    d.pulse(target, C.gone, { life = 0.8, from = 0.8, to = 3, prio = "info", module = "timers" })
                end
            end
        end
    end

    -- --- the plan's next kill -----------------------------------------------------

    local focus_guid = nil

    local stats = { timers = 0, focus = false }

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.timers, stats.focus = 0, false
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        local now = clock()
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100
        local target = P.combat and ask(P.combat.target)

        if target and opt("timers_on", true) then
            read(target, now)
            local pos = units.position and units.position(target)
            if pos then
                local list = {}
                for id, m in pairs(mine) do list[#list + 1] = { id = id, m = m } end
                table.sort(list, function(a, b) return a.m.expire_ms < b.m.expire_ms end)
                local reach = tonumber(units.combat_reach and units.combat_reach(target)) or 1.5
                local base = min(4, max(0.9, reach + 0.3)) + 0.6
                local ms = game_ms()
                local warn = opt("timers_warn", true)
                for i = 1, min(RINGS, #list) do
                    local m = list[i].m
                    local left = max(0, (m.expire_ms - ms) / 1000)
                    local frac = m.total > 0 and min(1, left / m.total) or 0
                    local col = PALETTE[m.slot] or PALETTE[1]
                    local to = col
                    if warn and left <= WARN then col, to = C.warn, C.warn end
                    draw.ring_3d(pos, base + (i - 1) * GAP, frac, col, { to = to, bg = C.band,
                        inner = 0.9, outer = 1.0, direction = -1, layer = layer,
                        unit = target, lane = "timers", index = i,
                        prio = (warn and left <= WARN) and "warn" or "info", module = "timers" })
                    stats.timers = stats.timers + 1
                end
            end
        elseif not target then
            read_guid, mine = nil, {}
        end

        -- KILL NEXT.
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        if opt("killnext_on", false) and P.react and P.react.focus and draw.curtain_3d then
            local unit = ask(P.react.focus)
            local g = guid_of(unit)
            if g and g ~= focus_guid then
                if focus_guid and draw.pulse then
                    draw.pulse(unit, C.focus_pulse, { life = 0.9, from = 1, to = 4, prio = "info", module = "killnext" })
                end
                focus_guid = g
            elseif not g then
                focus_guid = nil
            end
            if unit and g ~= guid_of(target) then
                local pos = units.position and units.position(unit)
                if pos then
                    local reach = tonumber(units.combat_reach and units.combat_reach(unit)) or 1.5
                    draw.curtain_3d(pos, max(1, reach + 0.5), C.focus, { to = C.focus_top, height = 2.4,
                        points = 24, rings = 3, fill = 0.3, speed = 1.4, spin = 1, lod = true, layer = layer,
                        unit = unit, prio = "info", module = "killnext" })
                    stats.focus = true
                end
            end
        end
    end

    function M.stats() return stats end

    return M
end

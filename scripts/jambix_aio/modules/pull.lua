-- Jambix AIO / pull -- how close you can walk before something comes (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "Pull safety". On hardcore one extra mob is the death; the rings say how
-- close you can walk past a pack without bringing it.
--
--   AGGRO RINGS  under each hostile mob not yet fighting, near enough to
--                matter, a ring at the radius it notices you from: 20 yd at
--                your level, a yard less for each level you are above it, a
--                yard more for each it is above you, 5 to 45 yd (Classic's
--                rule; the base is a setting, Forever's may differ). The
--                ring fills as you walk toward its edge and turns from amber
--                to red: full and red, you are inside it.
--   HEADING YOUR WAY  an elite, rare or boss walking toward you, not yet in a
--                fight: a curtain round it, gold for an elite, silver for a
--                rare, red for a boss.
--   A RARE       the first time a rare is seen, a pulse under it.
--
-- Neutral mobs never come for you, so only what the client calls your enemy
-- is ringed. The rings are the nearest few; the rest would only be clutter.
--
-- Mobs only (1.8.1). A player, or a player's pet or minion, notices nobody
-- from a distance, so none has a ring, a curtain or a pulse. The user's
-- screenshot, 2026-10-11 (Forever, Booty Bay on a PvP realm): every Horde
-- player on the dock stood in a 20-yard ring, red because you were inside
-- them all, and the rings covered the screen.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min = math.floor, math.max, math.min

    local M = {}

    local LEVEL_EVERY = 30       -- seconds a mob's level is kept
    local HOSTILE_EVERY = 3      -- seconds its hostility is kept
    local HUNT = 60              -- yards: nothing further is looked at
    local CLOSING = 0.4          -- yards a second toward you: "heading your way"

    local RANK_ELITE, RANK_RAREELITE, RANK_BOSS, RANK_RARE = 1, 2, 3, 4

    local function clock() return core.time() end
    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end

    local C = {
        far = color(240, 200, 80, 150), near = color(240, 70, 60, 230), band = color(0, 0, 0, 90),
        elite = color(245, 190, 60), elite_top = color(245, 190, 60, 40),
        rare = color(200, 210, 235), rare_top = color(200, 210, 235, 40),
        boss = color(240, 70, 60), boss_top = color(240, 70, 60, 40),
        pulse = color(220, 225, 245, 230),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    -- --- what a mob is, kept for a while ------------------------------------------

    local known = {}             -- guid -> { level, level_at, hostile, hostile_at, rank, rare_seen }
    local known_n, swept_at = 0, 0

    --- A player, or a pet or minion a player owns. One whose owner does not
    --- answer keeps its ring: a ring too many is safer than one missing.
    local function players_own(obj)
        local snap = units.snapshot and ask(units.snapshot, obj)
        if type(snap) == "table" and snap.is_player ~= nil then
            if snap.is_player == true then return true end
        elseif ask(obj.is_player, obj) == true then
            return true
        end
        if ask(obj.is_pet, obj) ~= true and ask(obj.is_minion, obj) ~= true then return false end
        local owner = ask(obj.get_owner, obj)
        return owner ~= nil and ask(owner.is_player, owner) == true
    end

    local function facts(row, player, now)
        local k = known[row.guid]
        if not k then
            k = { level_at = -1e9, hostile_at = -1e9 }
            known[row.guid] = k
            known_n = known_n + 1
        end
        local obj = row.obj
        if now - k.level_at > LEVEL_EVERY then
            k.level = tonumber(ask(obj.get_level, obj)) or k.level
            k.rank = tonumber(units.classification and ask(units.classification, obj)) or 0
            k.level_at = now
        end
        if now - k.hostile_at > HOSTILE_EVERY then
            k.hostile = player ~= nil and not players_own(obj) and ask(player.is_enemy_with, player, obj) == true
            k.hostile_at = now
        end
        return k
    end

    --- Classic's aggro radius: `base` at your level, a yard per level between.
    ---@param mob_level number
    ---@param my_level number
    ---@param base? number
    ---@return number
    function M.aggro_radius(mob_level, my_level, base)
        base = base or 20
        if not mob_level or not my_level or mob_level <= 0 then return base end
        return max(5, min(45, base + (mob_level - my_level)))
    end

    local stats = { rings = 0, curtains = 0, pulses = 0, looked = 0 }

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.rings, stats.curtains, stats.looked = 0, 0, 0
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.ring_3d) then return end
        if not opt("pull_on", true) then return end
        local rows = ask(ctx.enemies and ctx.enemies.all)
        if type(rows) ~= "table" then return end
        local player = units.player and units.player()
        if not player then return end
        local now = clock()
        local my_level = tonumber(ctx.player and ask(ctx.player.level)) or tonumber(ask(player.get_level, player)) or 0
        local base = tonumber(opt("pull_base", 20)) or 20
        local margin = tonumber(opt("pull_margin", 12)) or 12
        local most = floor(tonumber(opt("pull_max", 8)) or 8)
        local want_rings = opt("pull_rings", true)
        -- 1.7.6: curtains are off by default (main.lua, CURTAINS).
        local want_curtains = opt("pull_curtains", false)
        local want_pulse = opt("pull_rare_pulse", true)
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100

        -- The candidates, nearest first.
        local near = {}
        for i = 1, #rows do
            local r = rows[i]
            if r and r.obj and r.guid and not r.dead and not r.in_combat and not r.engaged
                and (r.dist or HUNT + 1) <= HUNT then
                near[#near + 1] = r
            end
        end
        table.sort(near, function(a, b) return (a.dist or 0) < (b.dist or 0) end)

        for i = 1, #near do
            local r = near[i]
            local k = facts(r, player, now)
            stats.looked = stats.looked + 1
            if k.hostile then
                local pos = units.position and units.position(r.obj)
                if pos then
                    local radius = M.aggro_radius(k.level, my_level, base)
                    local gap = (r.dist or 0) - radius
                    if want_rings and stats.rings < most and gap <= margin then
                        local close = min(1, max(0, 1 - gap / margin))
                        draw.ring_3d(pos, radius, close, C.far, { to = C.near, bg = C.band,
                            inner = 0.96, outer = 1.0, layer = layer, droppable = gap > 0,
                            unit = r.obj, prio = gap <= 0 and "warn" or "info", module = "pull" })
                        stats.rings = stats.rings + 1
                    end
                    local rank = k.rank or 0
                    if rank == RANK_RARE or rank == RANK_RAREELITE then
                        if not k.rare_seen then
                            k.rare_seen = true
                            if want_pulse and draw.pulse then
                                draw.pulse(r.obj, C.pulse, { life = 1.2, from = 1, to = 6, prio = "info", module = "pull" })
                                stats.pulses = stats.pulses + 1
                            end
                        end
                    end
                    if want_curtains and draw.curtain_3d and rank >= RANK_ELITE and rank <= RANK_RARE
                        and (r.closing or 0) >= CLOSING then
                        local col, top = C.elite, C.elite_top
                        if rank == RANK_BOSS then col, top = C.boss, C.boss_top
                        elseif rank == RANK_RARE or rank == RANK_RAREELITE then col, top = C.rare, C.rare_top end
                        local reach = units.combat_reach and tonumber(units.combat_reach(r.obj)) or 1.5
                        draw.curtain_3d(pos, max(1, reach + 0.5), col, { to = top, height = 2.2, points = 24,
                            rings = 3, fill = 0.35, speed = 1.6, spin = 1.2, lod = true, layer = layer,
                            unit = r.obj, prio = "warn", module = "pull" })
                        stats.curtains = stats.curtains + 1
                    end
                end
            end
        end

        -- Forget what has not been seen for a while.
        if now - swept_at > 30 then
            swept_at = now
            local live = {}
            for i = 1, #rows do if rows[i] and rows[i].guid then live[rows[i].guid] = true end end
            for guid in pairs(known) do
                if not live[guid] then known[guid], known_n = nil, known_n - 1 end
            end
        end
    end

    function M.stats() return stats end

    return M
end

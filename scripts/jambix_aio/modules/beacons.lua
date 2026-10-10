-- Jambix AIO / beacons -- where to go, as pillars of light (1.87.0).
--
-- The user, 2026-10-08, choosing what the curtains and rings should do next:
-- "Where to go". JCore 1.13's beacon_3d is a tall thin pillar, drawn while
-- its top shows over a hill, with fewer points the further it is:
--
--   THE GUIDE   RestedXP's next waypoint, in gold (quests.lua's
--               rxp.world_waypoint; its height is the guide's guess).
--   QUESTS      the quest areas the game's quest map gives on Forever, green
--               for one to turn in, yellow for one to do (the nearest three).
--               The map's areas come through the game Lua bridge, which is
--               often down; then there are none.
--   NODES       herbs green, veins orange, chests gold: the ESP's own nodes
--               this frame (the nearest few within range), so a node shows
--               only while its ESP category is on. Not one your skill is
--               short of (1.88.0): the ESP marks that "(Requires Skill N)"
--               and hands it on with `requires`, and a pillar would say "go
--               there" about a node you cannot gather.
--
-- Nothing within a few yards gets a beacon: you are there.

return function(P)
    local ctx = P.ctx
    local units = P.units
    local opt = P.opt
    local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

    local M = {}

    local HERE = 8               -- yards: closer than this, no beacon
    local QUEST_RANGE = 400      -- yards: quest areas further are left out
    local QUESTS_MAX = 3

    local function color(r, g, b, a)
        a = floor(max(0, min(255, a or 255)) + 0.5)
        if P.color then return P.color(r, g, b, a) end
        return { r = r, g = g, b = b, a = a }
    end
    local C = {
        guide = color(245, 200, 70), quest = color(240, 220, 90), turn_in = color(110, 220, 120),
        herb = color(90, 210, 110), ore = color(230, 150, 70), container = color(240, 200, 80),
    }

    local function ask(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function vec(x, y, z)
        local geo = ctx.geometry
        local v = geo and ask(geo.vec, x, y, z)
        return v or { x = x, y = y, z = z }
    end

    local function dist2d(a, b)
        local dx, dy = a.x - b.x, a.y - b.y
        return sqrt(dx * dx + dy * dy)
    end

    local stats = { guide = 0, quests = 0, nodes = 0 }

    --- This frame's nodes, Forever's ESP or the Classic one: { obj, kind, d, pos }.
    --- Leaves out a node whose entry carries `requires` (1.88.0).
    local function nodes()
        local esp = P.esp
        if not esp then return {} end
        local out = {}
        local fe = esp.forever
        local list = fe and ask(fe.node_marks)
        if type(list) == "table" then
            for i = 1, #list do
                local m = list[i]
                if not m.requires then
                    out[#out + 1] = { obj = m.obj, kind = m.cat, d = m.d, pos = m.pos }
                end
            end
            return out
        end
        list = ask(esp.nodes)
        if type(list) == "table" then
            for i = 1, #list do
                local n = list[i]
                if not n.requires then
                    out[#out + 1] = { obj = n.obj, kind = n.kind, d = n.distance }
                end
            end
        end
        return out
    end

    --- One frame. Called by main.lua's render job under the toggle key.
    function M.render()
        stats.guide, stats.quests, stats.nodes = 0, 0, 0
        -- Through the world layer (1.89.0): lanes, the budget, the look, the wall fade.
        local draw = P.worldmarks or P.draw
        if not (draw and draw.beacon_3d) then return end
        if not opt("beacons_on", true) then return end
        local me = units.player_position and units.player_position()
        if not me then return end
        local height = tonumber(opt("beacon_height", 14)) or 14
        local L = ctx.LAYER or {}
        local layer = L.WORLD or 100

        -- THE GUIDE.
        if opt("beacon_waypoint", true) then
            local rxp = P.quests and P.quests.rxp
            local wp = rxp and rxp.world_waypoint
            if wp and wp.x and dist2d(wp, me) > HERE then
                draw.beacon_3d(vec(wp.x, wp.y, wp.z or me.z), C.guide, { height = height + 4, layer = layer,
                    prio = "info", module = "beacons" })
                stats.guide = 1
            end
        end

        -- QUESTS.
        if opt("beacon_quests", true) then
            local fq = P.esp and P.esp.forever and P.esp.forever.quests
            local list = fq and ask(fq.locations)
            if type(list) == "table" then
                local near = {}
                for i = 1, #list do
                    local l = list[i]
                    if l and l.x and l.y then
                        local d = dist2d(l, me)
                        if d > HERE and d <= QUEST_RANGE then near[#near + 1] = { l = l, d = d } end
                    end
                end
                table.sort(near, function(a, b) return a.d < b.d end)
                for i = 1, min(QUESTS_MAX, #near) do
                    local l = near[i].l
                    local done = l.done == true or (l.quest and l.quest.complete == true)
                    local z = (l.poi and tonumber(l.poi.ground)) or l.z or me.z
                    draw.beacon_3d(vec(l.x, l.y, z), done and C.turn_in or C.quest, { height = height, layer = layer,
                        prio = "info", module = "beacons" })
                    stats.quests = stats.quests + 1
                end
            end
        end

        -- NODES.
        if opt("beacon_nodes", true) then
            local range = tonumber(opt("beacon_node_range", 90)) or 90
            local most = floor(tonumber(opt("beacon_max_nodes", 5)) or 5)
            local list = nodes()
            table.sort(list, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
            for i = 1, #list do
                if stats.nodes >= most then break end
                local n = list[i]
                local col = C[n.kind or ""]
                if col and (n.d or 1e9) > HERE and (n.d or 1e9) <= range then
                    local pos = n.pos or (units.position and units.position(n.obj))
                    if pos then
                        draw.beacon_3d(pos, col, { height = height * 0.7, radius = 0.35, layer = layer,
                            unit = n.obj, prio = "decor", module = "beacons" })
                        stats.nodes = stats.nodes + 1
                    end
                end
            end
        end
    end

    function M.stats() return stats end

    return M
end

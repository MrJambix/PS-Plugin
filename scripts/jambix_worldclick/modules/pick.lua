-- World Click to Move / pick -- what a click is on.
--
-- THE GAME'S OWN ANSWER FIRST. core.object_manager.get_mouse_over_object is
-- the object the client has under the mouse. On Forever it answered an
-- object 1,803 times in the recorder (Jambix Debug's loot study), for live
-- mobs and their corpses alike.
--
-- IT MUST BE UNDER THE CURSOR ON SCREEN. The client's mouseover also follows
-- the unit frames: a cursor on your party frame names that party member, who
-- may stand forty yards off. So the object is projected, from its feet to
-- just above its head (its nameplate), and the cursor must be near that line
-- on screen. A unit frame is nowhere near the unit it shows.
--
-- THEN THE NEAREST ON SCREEN. When the client names nothing (nothing under
-- the mouse, or a node the mouseover does not cover), the gatherable
-- objects and the corpses in range are projected and the one nearest the
-- cursor, within PICK_PX, is taken. On Forever can_be_used is true on every
-- herb and vein recorded and false on scenery (Jambix AIO's Forever ESP), so
-- it is what makes an object worth walking to. A living unit (any npc or
-- mob; a player only with "Players" on) counts when the cursor is within
-- UNIT_NEAR_PX of the line from its feet to its nameplate: any npc you can
-- see is clickable, the mouseover or not (the user, 2026-10-11: "Should be
-- any NPC"). That is tighter than a node's PICK_PX, so a click on the ground
-- beside a mob walks you to the ground, not to the mob.
--
-- BEHIND THE CAMERA. w2s answers a mirrored position for a point behind the
-- camera instead of nil, and there is no camera read to rule it out. A point
-- in front of the camera has the point one yard above it drawn higher on the
-- screen; behind the camera the mirror puts it lower. That is the test.

return function(P)
    local units, draw = P.units, P.draw
    local sqrt = math.sqrt

    local M = {}

    local PICK_PX = 36            -- px from the cursor: the nearest object within this is the click's
    local UNIT_PX = 44            -- px from a unit's feet-to-head line: the cursor is on it
    local UNIT_NEAR_PX = 24       -- px from that line: a living unit the mouseover did not name
    local OBJECT_HEIGHT = 1.5     -- yd: an object's "head" for the screen test
    local PLATE_LIFT = 0.8        -- yd above the head: its nameplate, which takes clicks too
    local UP_TEST = 1.0           -- yd: the behind-the-camera test

    local stats = { mouse = 0, near = 0, rejected_screen = 0, nothing = 0 }

    -- --- reads --------------------------------------------------------------------

    local vec = P.vec3

    local function project(pos)
        if not pos then return nil end
        local fn = draw and draw.project
        if type(fn) ~= "function" then return nil end
        local ok, s = pcall(fn, pos)
        if not ok or type(s) ~= "table" and type(s) ~= "userdata" then return nil end
        local x, y = tonumber(s.x), tonumber(s.y)
        if not x or not y or x ~= x or y ~= y or math.abs(x) > 1e6 or math.abs(y) > 1e6 then return nil end
        return x, y
    end

    --- Is `pos` in front of the camera? Its point UP_TEST above is drawn higher.
    local function in_front(pos, sx, sy)
        local ux, uy = project(vec(pos.x, pos.y, (pos.z or 0) + UP_TEST))
        if not ux then return false end
        return uy < sy
    end

    --- How far the cursor is from the segment a..b on screen, and its length.
    local function to_segment(px, py, ax, ay, bx, by)
        local vx, vy = bx - ax, by - ay
        local len2 = vx * vx + vy * vy
        local t = 0
        if len2 > 0 then
            t = ((px - ax) * vx + (py - ay) * vy) / len2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local dx, dy = px - (ax + t * vx), py - (ay + t * vy)
        return sqrt(dx * dx + dy * dy), sqrt(len2)
    end

    local function position_of(obj)
        local pos = units.position(obj)
        if not pos then return nil end
        local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
        if not x or not y then return nil end
        return vec(x, y, z or 0)
    end

    --- The top of a unit (its name's anchor, from JCore) or of an object.
    local function top_of(obj, is_unit, pos)
        if is_unit and draw and draw.unit_head then
            local ok, head = pcall(draw.unit_head, obj)
            if ok and head and tonumber(head.z) then
                return vec(head.x, head.y, head.z + PLATE_LIFT)
            end
            return vec(pos.x, pos.y, pos.z + 2.0 + PLATE_LIFT)
        end
        return vec(pos.x, pos.y, pos.z + OBJECT_HEIGHT)
    end

    --- Is the cursor on `obj` on screen? Near the line from its feet to just
    --- above its head: UNIT_PX, or half the line's length for something
    --- drawn big (a giant up close).
    function M.on_screen(obj, cx, cy)
        local pos = position_of(obj)
        if not pos then return false end
        local is_unit = P.call(obj, "is_unit") == true
        local fx, fy = project(pos)
        local tx, ty = project(top_of(obj, is_unit, pos))
        if not fx and not tx then return false end
        if fx and not in_front(pos, fx, fy) then return false end
        fx, fy = fx or tx, fy or ty
        tx, ty = tx or fx, ty or fy
        local d, len = to_segment(cx, cy, fx, fy, tx, ty)
        local tolerance = math.max(UNIT_PX, len * 0.5)
        return d <= tolerance, d
    end

    -- --- what it is ----------------------------------------------------------------

    --- "enemy" (a mob you can attack), "npc" (alive, not attackable),
    --- "player" (another player, alive), "corpse" (any dead unit) or
    --- "object" (a node, a chest, a mailbox, a quest object).
    function M.kind_of(obj)
        if P.call(obj, "is_unit") ~= true then return "object" end
        if P.call(obj, "is_dead") == true then return "corpse" end
        if P.call(obj, "is_player") == true then return "player" end
        local row = units.snapshot and units.snapshot(obj)
        if row and row.is_enemy ~= nil then return row.is_enemy and "enemy" or "npc" end
        local me = units.player()
        if me and P.call(me, "can_attack", obj) == true then return "enemy" end
        return "npc"
    end

    local WHAT = { enemy = "mob", npc = "npc", player = "player", corpse = "corpse", object = "object" }

    --- A name to say: the client's (JCore's names service on Forever), else
    --- what it is.
    function M.name_of(obj, kind)
        local name
        if P.call(obj, "is_unit") == true and units.name then
            local ok, n = pcall(units.name, obj)
            if ok then name = n end
        end
        if type(name) ~= "string" or name == "" then name = P.call(obj, "get_name") end
        if type(name) ~= "string" or name == "" or name == "Unknown" then
            return WHAT[kind] or "it"
        end
        return name
    end

    --- The thing a click is on, as the walk keeps it.
    function M.thing(obj, how)
        local guid = units.guid(obj)
        local pos = position_of(obj)
        if not guid or not pos then return nil end
        local kind = M.kind_of(obj)
        return { obj = obj, guid = guid, kind = kind, name = M.name_of(obj, kind), pos = pos, how = how }
    end

    --- Worth walking to when picked by the cursor's nearness: a corpse, or an
    --- object the client says can be used (every herb and vein; never
    --- scenery). Living units are judged apart (on_screen, UNIT_NEAR_PX).
    local function pickable(obj)
        if P.call(obj, "is_unit") == true then return P.call(obj, "is_dead") == true end
        return P.call(obj, "can_be_used") == true
    end

    --- A living unit a click may walk to: any npc or mob, a player only with
    --- the "Players" switch on.
    local function living(obj)
        if P.call(obj, "is_unit") ~= true or P.call(obj, "is_dead") == true then return false end
        if P.call(obj, "is_player") == true then return P.opt("walk_players", false) == true end
        return true
    end

    -- --- the click ------------------------------------------------------------------

    --- The client's mouseover object, or nil.
    function M.mouse_over()
        local om = type(core) == "table" and core.object_manager or nil
        local fn = om and om.get_mouse_over_object
        if type(fn) ~= "function" then return nil end
        local ok, obj = pcall(fn)
        if not ok or not obj then return nil end
        if P.call(obj, "is_valid") ~= true then return nil end
        return obj
    end

    local function is_me(obj)
        local me = units.player()
        if not me then return false end
        local a, b = units.guid(obj), units.guid(me)
        return a ~= nil and a == b
    end

    --- The nearest pickable object, corpse or living unit to the cursor on
    --- screen (a node or a corpse within PICK_PX of its feet, a living unit
    --- within UNIT_NEAR_PX of its body), within `range` yards of you.
    local function nearest_on_screen(cx, cy, range)
        local best, best_d = nil, math.huge
        local function consider(list)
            if type(list) ~= "table" then return end
            for i = 1, #list do
                local obj = list[i]
                if obj and not is_me(obj) and units.distance(obj) <= range then
                    if pickable(obj) then
                        local pos = position_of(obj)
                        local sx, sy = project(pos)
                        if sx and in_front(pos, sx, sy) then
                            local dx, dy = sx - cx, sy - cy
                            local d = sqrt(dx * dx + dy * dy)
                            if d <= PICK_PX and d < best_d then best, best_d = obj, d end
                        end
                    elseif living(obj) then
                        local on, d = M.on_screen(obj, cx, cy)
                        if on and d and d <= UNIT_NEAR_PX and d < best_d then best, best_d = obj, d end
                    end
                end
            end
        end
        consider(units.objects())
        consider(units.units and units.units() or nil)
        return best
    end

    --- What the cursor at (cx, cy) is on: a thing, or nil and why not, and
    --- true when the client named something nowhere near the cursor (a unit
    --- frame: the cursor is on the game's own UI, so not on the ground).
    ---@param range number yards: farther is not looked at
    ---@param hover? game_object the mouseover to judge (mouse.lua keeps the
    --- one from before the press: the game may drop it once the button is down)
    function M.under_cursor(cx, cy, range, hover)
        local obj = hover or M.mouse_over()
        local framed = false
        if obj and not is_me(obj) then
            if M.on_screen(obj, cx, cy) then
                stats.mouse = stats.mouse + 1
                return M.thing(obj, "mouse")
            end
            -- A unit frame, or the mouseover lagging: not this one.
            stats.rejected_screen = stats.rejected_screen + 1
            framed = true
        end
        local near = nearest_on_screen(cx, cy, range)
        if near then
            stats.near = stats.near + 1
            return M.thing(near, "near")
        end
        stats.nothing = stats.nothing + 1
        return nil, framed and "not under the cursor on screen" or "nothing there", framed
    end

    --- The thing's object again, by its guid (a game_object is good for one
    --- tick only), and where it is now.
    function M.refresh(thing)
        local obj = units.by_guid(thing.guid)
        if not obj or P.call(obj, "is_valid") ~= true then return nil end
        thing.obj = obj
        local pos = position_of(obj)
        if pos then thing.pos = pos end
        return obj
    end

    function M.stats() return stats end

    -- For the ground search (ground.lua).
    M.project, M.in_front = project, in_front

    -- For the tests.
    M._to_segment = to_segment

    return M
end

-- Jambix AIO / assist -- "Assist the tank" (1.69.0).
--
-- The user, 2026-10-04: "in all dps classes lets add an option to assist
-- tank meaning his target and swaps to his targets". One switch, in every
-- class's window (Group) and on the Rotation page (Targeting), off until it
-- is turned on.
--
-- WHEN IT ACTS. Switched on, in a group, with a tank that is not you, alive
-- and in sight -- and you are not the tank or the healer yourself (the
-- group's role, else the rotation's profile: a tank or a healing one).
-- Anywhere else targeting is what it always was.
--
-- WHAT IT DOES (targeting.better_target and rotation.may_engage_unit ask it)
--   your target   the tank's, and it follows: the tank changes target and so
--                 do you, once the tank has kept the new one 0.3 s (a tab
--                 through the pack is not followed mob by mob). With no live
--                 target of your own, at once. Ahead of "Pick targets
--                 automatically", the fight plan and the score.
--   the kill      IN A FIGHT, THE MOB YOU ARE KILLING IS KEPT (1.74.0). A
--                 warrior holds a pack by tabbing through it for a Sunder on
--                 each, a second or two apiece. Followed every time, the live
--                 log (Forever, a five-man) had a hunter change target every
--                 one to three seconds: a Hunter's Mark, an Auto Shot re-armed
--                 and a fresh sting with each, the damage spread over three
--                 mobs and nothing dying. Now, once the fight is on, your
--                 target stays until it dies, unless the tank has kept another
--                 mob KEEP seconds (a real switch, not a Sunder), or a skull
--                 or cross is on the tank's and not on yours. A mob of yours
--                 under FINISH health is finished first whatever the tank is
--                 on. Out of a fight (the tank picking the pull) as before.
--   not followed  the tank on nothing or on a friend, on a mob crowd-
--                 controlled in a way damage breaks, on somebody else's mob,
--                 on one past 60 yd -- and, in a fight, on one not in combat
--                 yet (a tank looking at the next pack is not a pull). Then
--                 the choice is made as before.
--   the pull      the tank's. While assisting, a mob is not opened on -- not
--                 by you, not by the pet, not by a hunter's opener -- until it
--                 is in combat; once it is in combat with the group you join
--                 in, though you are not in combat yourself yet. The engage
--                 key still opens at once.
--
-- WHO THE TANK IS. The group's role (the dungeon finder's, a raid's, the
-- party row's on Forever). Era players rarely set one, so without it the
-- group shows who: the member the mobs in combat are on (3 points a mob) and
-- the member in a tank's stance or form -- Defensive Stance, Bear or Dire
-- Bear Form, Righteous Fury (6). The one found last keeps 4 more, so a mob
-- turning on a damage dealer for a moment does not move the tank, and a
-- druid out of Bear Form between pulls stays the tank. Asked once a second:
-- one aura read per member, and the tank's target read every 0.1 s, only
-- while the switch is on.

local huge, floor = math.huge, math.floor

local EVERY = 1.0               -- s between looks for the tank and our own role
local READ = 0.1                -- s between reads of the tank's target
local STEADY = 0.3              -- s the tank keeps a target before we follow
local KEEP = 4.0                -- s, in a fight: the tank on another mob this long is a real switch
local FINISH = 0.35             -- in a fight: our mob under this health is finished first
-- Raid marks the group kills by: skull first, then cross.
local MARK_RANK = { [8] = 2, [7] = 1 }
local FAR = 60                  -- yd past which the tank's target is not followed
local NOTE_FOR = 1.0            -- s a note stays true without a fresh look
local MOB_POINTS, AURA_POINTS, KEEP_POINTS = 3, 6, 4
-- Defensive Stance, Bear Form, Dire Bear Form, Righteous Fury.
local TANK_AURAS = { 71, 5487, 9634, 25780 }
local HEALER_PROFILES = { Holy = true, Discipline = true, Restoration = true }

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat

    local M = {}

    local function try(fn, ...)
        if type(fn) ~= "function" then return nil end
        local ok, v = pcall(fn, ...)
        if ok then return v end
        return nil
    end

    local function guid_of(unit)
        if not unit then return nil end
        if units.guid then return try(units.guid, unit) end
        return try(unit.get_guid, unit)
    end

    local function name_of(unit)
        local n = unit and units.name and try(units.name, unit)
        if type(n) == "string" and n ~= "" then return n end
        n = unit and try(unit.get_name, unit)
        if type(n) == "string" and n ~= "" then return n end
        return "?"
    end

    local function alive(unit)
        return unit ~= nil and try(unit.is_valid, unit) == true and try(unit.is_dead, unit) ~= true
    end

    --- Is the switch on?
    ---@return boolean
    function M.on()
        return P.opt("rot_assist_tank", false) == true
    end

    -- --- who is who, once a second ---------------------------------------------

    local st = {
        at = -huge, live = false, why = nil,
        tank = nil, tank_guid = nil, tank_name = nil, how = nil,
        kept_guid = nil,        -- the tank found last without a role: it keeps KEEP_POINTS
        logged_guid = nil,
        members = {},           -- guid -> true: the group, us included
        note = nil, note_at = -huge, on_name = nil,
    }
    M.state = st

    --- "tank", "healer" or nil: what we are in this group.
    local function my_role(player)
        local g = ctx.group
        if g and try(g.is_tank, player) == true then return "tank" end
        if g and try(g.is_healer, player) == true then return "healer" end
        local rot = P.rotation
        local cm = rot and try(rot.active_class)
        if type(cm) == "table" and type(cm.profiles) == "table" and rot.active_profile_key then
            local key = try(rot.active_profile_key, cm)
            local prof = key and cm.profiles[key]
            if type(prof) == "table" then
                local label = type(prof.label) == "string" and prof.label or ""
                local low = label:lower()
                if prof.tank == true or low:find("tank", 1, true) or low:find("prot", 1, true) then
                    return "tank"
                end
                if HEALER_PROFILES[label] then return "healer" end
            end
        end
        return nil
    end

    --- The tank: the group's role first, else what the group shows.
    ---@return game_object|nil tank
    ---@return string|nil guid
    ---@return string how it was found, or why there is none
    local function find_tank(g, my_guid, fighting)
        local tanks = try(g.tanks)
        if type(tanks) == "table" then
            local dead = false
            for i = 1, #tanks do
                local u = tanks[i]
                local guid = guid_of(u)
                if guid and guid ~= my_guid then
                    if alive(u) then return u, guid, "group role" end
                    dead = true
                end
            end
            if dead then return nil, nil, "the tank is dead" end
        end

        -- Who the mobs in combat are on.
        local on = {}
        local en = ctx.enemies
        local rows = en and try(en.all)
        if type(rows) == "table" then
            local n = try(en.count) or #rows
            for i = 1, n do
                local r = rows[i]
                local t = r and r.in_combat and r.activity ~= "dead" and r.target_guid
                if t then on[t] = (on[t] or 0) + 1 end
            end
        end

        local members = try(g.objects) or {}
        local best, best_guid, best_score, best_how = nil, nil, 0, nil
        for i = 1, #members do
            local u = members[i]
            local guid = guid_of(u)
            if guid and guid ~= my_guid then
                if alive(u) then
                    local mobs = on[guid] or 0
                    local stance = units.has_aura ~= nil and try(units.has_aura, u, TANK_AURAS) == true
                    local kept = guid == st.kept_guid
                    local score = mobs * MOB_POINTS + (stance and AURA_POINTS or 0) + (kept and KEEP_POINTS or 0)
                    if score > best_score then
                        local how
                        if stance then
                            how = "tank stance or form"
                        elseif mobs > 0 then
                            how = mobs == 1 and "a mob is on them" or string.format("%d mobs are on them", mobs)
                        else
                            how = "found earlier"
                        end
                        best, best_guid, best_score, best_how = u, guid, score, how
                    end
                elseif guid == st.kept_guid and fighting then
                    -- Our tank died mid-fight: nobody else is the tank for it.
                    return nil, nil, "the tank is dead"
                end
            end
        end
        if not best then
            return nil, nil, "no tank found yet (no role set, nobody holding mobs or in a tank stance)"
        end
        return best, best_guid, best_how
    end

    local function refresh(now)
        if (now - st.at) < EVERY then return end
        st.at = now
        st.live, st.tank, st.tank_guid, st.tank_name, st.how = false, nil, nil, nil, nil
        local player = units.player()
        if not player then st.why = "no player yet" return end
        local g = ctx.group
        if not (g and try(g.in_group) == true) then st.why = "not in a group" return end
        local role = my_role(player)
        if role == "tank" then st.why = "you are the tank" return end
        if role == "healer" then st.why = "you are the healer" return end

        local my_guid = guid_of(player)
        local fighting = combat.in_combat and combat.in_combat() == true
        local tank, guid, how = find_tank(g, my_guid, fighting)
        if not tank then st.why = how return end

        local set = {}
        local members = try(g.objects) or {}
        for i = 1, #members do
            local mg = guid_of(members[i])
            if mg then set[mg] = true end
        end
        if my_guid then set[my_guid] = true end
        st.members = set

        st.live, st.why = true, nil
        st.tank, st.tank_guid, st.tank_name, st.how = tank, guid, name_of(tank), how
        if how ~= "group role" then st.kept_guid = guid end
        if guid ~= st.logged_guid then
            st.logged_guid = guid
            log.fmt("info", "assist: the tank is %s (%s)", st.tank_name, how)
        end
    end

    -- --- the tank's target -------------------------------------------------------

    local follow = { guid = nil, since = -huge, unit = nil, read_at = -huge }

    local function tank_target(now)
        if (now - follow.read_at) < READ then return follow.unit end
        follow.read_at = now
        local t = st.tank and try(st.tank.get_target, st.tank) or nil
        if t and try(t.is_valid, t) ~= true then t = nil end
        local guid = guid_of(t)
        if guid ~= follow.guid then follow.guid, follow.since = guid, now end
        follow.unit = t
        return t
    end

    local function note(text, now)
        st.note, st.note_at = text, now
    end

    --- Why the tank's target is not followed, or nil when it is.
    local function refuse(unit, player, fighting)
        if not unit then return "the tank has no target" end
        if not alive(unit) then return "the tank's target is dead" end
        if try(player.can_attack, player, unit) ~= true then return "the tank is targeting a friend" end
        local react = P.react
        if react and react.out_of_fight and try(react.out_of_fight, unit) == true then
            return string.format("%s is crowd-controlled: left alone", name_of(unit))
        end
        local targeting = P.targeting
        if targeting and targeting.others_mob and try(targeting.others_mob, unit) == true then
            return string.format("%s is somebody else's", name_of(unit))
        end
        local d = units.distance and try(units.distance, unit)
        if type(d) == "number" and d > FAR then
            return string.format("%s is %d yd away", name_of(unit), floor(d))
        end
        if fighting and try(unit.is_in_combat, unit) ~= true then
            return string.format("%s is not pulled yet", name_of(unit))
        end
        return nil
    end

    --- Skull 2, cross 1, anything else 0.
    local function mark_rank(unit)
        local m = unit and try(unit.get_target_marker_index, unit)
        return MARK_RANK[m] or 0
    end

    --- In a fight: do we stay on `current` while the tank is on `theirs`?
    --- The second value says why, for the class window (staying) or the
    --- log (leaving).
    ---@return boolean stay
    ---@return string|nil why
    local function keep_kill(current, theirs, now)
        local ours = name_of(current)
        local hp = units.health_fraction and try(units.health_fraction, current)
        if type(hp) == "number" and hp > 0 and hp < FINISH then
            return true, string.format("finishing %s (%d%%) before %s", ours, floor(hp * 100 + 0.5), st.on_name)
        end
        local their_mark, our_mark = mark_rank(theirs), mark_rank(current)
        if their_mark > our_mark then
            return false, string.format("%s is marked %s: leaving %s for it", st.on_name,
                their_mark == 2 and "skull" or "cross", ours)
        end
        local held = now - follow.since
        if held < KEEP then
            return true, string.format("staying on %s until it dies (the tank is on %s, %.1fs)", ours, st.on_name, held)
        end
        return false, string.format("the tank has been on %s %.0fs: leaving %s for it", st.on_name, held, ours)
    end

    --- targeting.better_target asks this first.
    ---@param current game_object|nil our target now
    ---@return game_object|nil unit the one to switch to; nil stays on `current`
    ---@return boolean holding true: the tank's target decides; false: targeting as before
    function M.pick(current)
        if not M.on() then return nil, false end
        local now = core.time()
        refresh(now)
        if not st.live then return nil, false end
        local player = units.player()
        if not player then return nil, false end
        local unit = tank_target(now)
        local fighting = combat.in_combat and combat.in_combat() == true
        local why = refuse(unit, player, fighting)
        if why then
            note(why, now)
            st.on_name = nil
            return nil, false
        end
        st.on_name = name_of(unit)
        note(nil, now)
        local cur = (current and alive(current)) and guid_of(current) or nil
        if cur == follow.guid then return nil, true end
        if cur and (now - follow.since) < STEADY then return nil, true end
        -- In a fight, the mob we are killing is kept (see THE KILL above).
        if cur and fighting and refuse(current, player, true) == nil then
            local stay, why = keep_kill(current, unit, now)
            if stay then
                note(why, now)
                return nil, true
            end
            if why then log.fmt("info", "assist: %s", why) end
        end
        log.fmt("debug", "assist: on %s's target, %s", st.tank_name or "the tank", st.on_name)
        return unit, true
    end

    --- rotation.may_engage_unit asks this out of combat: true joins the
    --- group's fight, false waits for the tank's pull, nil has no say.
    ---@param target game_object|nil
    ---@return boolean|nil
    function M.engage(target)
        if not M.on() then return nil end
        local now = core.time()
        refresh(now)
        if not st.live or not alive(target) then return nil end
        if try(target.is_in_combat, target) ~= true then
            note(string.format("waiting for %s to pull %s", st.tank_name or "the tank", name_of(target)), now)
            return false
        end
        local guid = guid_of(target)
        if guid and guid == follow.guid then return true end
        local en = ctx.enemies
        local row = en and en.get and try(en.get, target) or nil
        if row and (row.engaged or row.targeting_me or row.targeting_pet) then return true end
        local tg = row and row.target_guid
        if not tg then tg = guid_of(try(target.get_target, target)) end
        if tg and st.members[tg] then return true end
        return nil
    end

    --- One line for the class window, "" while the switch is off.
    ---@return string
    function M.status()
        if not M.on() then return "" end
        local now = core.time()
        refresh(now)
        if not st.live then return "Assist: " .. (st.why or "no tank found yet") .. "." end
        local head = string.format("Assisting %s (%s)", st.tank_name or "the tank", st.how or "?")
        if P.rotation_active and P.rotation_active() ~= true then
            return head .. ": waiting for the rotation."
        end
        if st.note and (now - st.note_at) <= NOTE_FOR then return head .. ": " .. st.note .. "." end
        if st.on_name and (now - st.note_at) <= NOTE_FOR then return head .. ": on " .. st.on_name .. "." end
        return head .. "."
    end

    --- For the tests and the Debug page.
    function M.stats()
        return { on = M.on(), live = st.live, why = st.why, tank = st.tank_name, how = st.how,
            following = follow.guid, note = st.note }
    end

    return M
end

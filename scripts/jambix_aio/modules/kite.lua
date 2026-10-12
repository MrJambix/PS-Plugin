-- Jambix AIO / kite -- the levelling hunter's run-and-shoot before there is a pet.
--
-- THE PROBLEM IT SOLVES
-- Levels one to ten a hunter has no pet, and the guide's advice for those
-- levels is a movement pattern, not a priority list: "get as many Auto Shots
-- off as possible before the target reaches you, by kiting backwards, moving
-- in between each shot". A priority list cannot express that. This module
-- owns the legs; the rotation keeps owning the shots.
--
-- WHY IT WORKS
-- A mob runs at the same speed you do, so running never gains ground on its
-- own. What gains ground is that Auto Shot only needs you STANDING for the
-- half-second aim before it fires. Stand for the aim, run for the rest of the
-- swing, stand for the next aim: every cycle the mob closes only by the time
-- you stood, and the fight that would have been three shots is five or six.
-- Concussive Shot, from level eight, dazes the mob and turns the same cycle
-- into real distance.
--
-- HOW IT MOVES
-- Not backwards. Backpedalling is walking speed and would hand the mob every
-- yard the cycle earned. It turns away, runs forward, and turns back to face
-- the target for the aim -- which is what a player's hands do, and why the
-- facing channel is leased along with movement.
--
-- WHEN A SHOT HAPPENED
-- The core's spell-cast callback reports every cast, Auto Shot included, so
-- the run phase starts from the real shot rather than a guess. Until the
-- first one has been seen the cycle runs on time alone: stand for the aim
-- plus a margin, run for the rest of the weapon's speed. The moment a real
-- shot event arrives it takes over.
--
-- WHEN IT STOPS
-- The mob inside minimum range and not slowed (running gains nothing; the
-- melee rules take over), a second attacker (kiting one mob into another is
-- how a hunter dies at level six), a cast in flight, a drop or water behind
-- us, the pull dragged further than the limit, or a pet -- the whole reason
-- to stop, and the guide's own end point.
--
-- WHEN IT NEVER STARTS
-- Once Tame Beast is trained. This is the guide's pattern for the levels
-- BEFORE a pet exists, not a fallback for a pet that died: a hunter at
-- thirty whose pet went down mid-fight does not want their legs taken over.
-- And never while the player is driving. The player's own movement keys
-- are not leased, so the only way not to fight them is to stand aside the
-- moment one is down.
--
-- THE STEP OUT (with a pet)
-- From the pet levels on, the legs keep exactly one job. A mob inside
-- minimum range is unshootable, and standing there trading Raptor Strikes
-- is a fraction of the class's damage. Once the class rules have clipped
-- it (Wing Clip, Concussive Shot, a Counterattack root) -- or when it is on
-- the pet and will not follow -- the right move is to walk out past eight
-- yards and shoot it. That is all this does: a bounded few seconds of
-- running directly away, then it lets go. An unslowed mob that is on us is
-- never run from, since it keeps pace and the run gains nothing; the melee
-- rules are the answer until the clip lands.
--
-- THE ADD (1.58.0). The same step, from a mob that is NOT the target: one
-- hitting us in melee that the reactions clipped ("Clip the add"). With the
-- target still shootable, we walk clear of the add's reach while the shots
-- stay on the target -- never so far that the target leaves range.
--
-- BEAST MASTERY'S MELEE WEAVE (1.8.1; the AOE melee weave's, 1.7.6). While
-- the hunter's Beast Mastery runs (classes/hunter.lua) and the pet levels
-- have begun, the walking in and out is yours, and this stands aside: a step
-- out would fight the walk in. Before Tame Beast the run-and-shoot is still
-- this module's, Beast Mastery or not (a hunter with no points reads as one).

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local book = P.spellbook

    local M = {}

    -- Settings live under the hunter's own options; the prefix is the one
    -- main.lua builds for that class file.
    local PREFIX = "rot_hunter_"
    local function opt(id, default) return P.opt(PREFIX .. id, default) end

    local AIM_TIME = 0.5        -- Auto Shot's stand-still aim
    -- A character in this game stops on the spot, so arriving early only has
    -- to cover a frame or two of latency. Every extra tenth here is a tenth
    -- the mob gains per cycle.
    local AIM_MARGIN = 0.15     -- arrive standing this much before the aim
    local FACE_HALF_ANGLE = 25  -- degrees off before re-facing; re-facing every tick is a twitch
    local REFACE_EVERY = 0.5    -- seconds between run-direction corrections
    local MIN_RANGE = 8         -- Auto Shot's minimum range
    local RUN_PROBE = 6         -- yards ahead that the ground is checked
    local START_RUNNING_AT = 28 -- closer than this, the mob is worth running from
    local DEFAULT_SPEED = 2.5   -- a starter bow, until the client says

    local STEP_OUT_TO = 11      -- yards: clear of the dead zone, with a margin
    local STEP_MAX = 4.0        -- seconds one step-out attempt may run
    local RESET_MAX = 6.0       -- the PvP reset's walk (1.7.6): 25 yd at run speed is ~3.6 s
    local STEP_RETRY = 3.0      -- seconds before a failed step-out is tried again
    local ADD_REACH = 6         -- an add this close is in melee with us
    local KEEP_IN_RANGE = 32    -- never step so far that the target is out of shot

    -- HITBOX TO HITBOX (1.58.1). The dead zone ends eight yards from the
    -- mob's EDGE, not its centre (rotation.lua, H.gap): the step out runs
    -- until the gap is past it by a yard. Without the helpers, eleven yards
    -- from the centre, as before.
    local function shootable(unit, distance)
        local H = P.rotation and P.rotation.helpers
        if H and H.gap then return H.gap(unit, distance) >= MIN_RANGE + 1 end
        return distance >= STEP_OUT_TO
    end
    local function near(unit, distance)
        local H = P.rotation and P.rotation.helpers
        if H and H.melee_range then return distance <= H.melee_range(unit) + 1 end
        return distance <= ADD_REACH
    end

    local phase = "idle"        -- idle | shoot | run | step
    local phase_since = 0
    local phase_until = 0
    local faced_at = 0          -- last run-direction correction
    local calibrated = false    -- an Auto Shot event has been seen
    local shots = 0
    local anchor = nil          -- where this fight started
    local last_reason = "off"

    -- --- readings -----------------------------------------------------------

    local function hunter_active()
        local class_module = P.rotation and P.rotation.active_class()
        return class_module ~= nil and class_module.key == "hunter"
    end

    --- The hunter's Beast Mastery, with its melee weave, is the profile
    --- running (1.8.1; the AOE melee weave's switch, 1.7.6).
    local function weave()
        local class_module = P.rotation and P.rotation.active_class()
        local fn = class_module and class_module.weave_running
        return type(fn) == "function" and fn() == true
    end

    local function pet_alive()
        return P.pet ~= nil and P.pet.alive()
    end

    --- Tame Beast trained: the pet levels have begun, whether or not a pet
    --- is out right now.
    local function pet_levels()
        return book.known("Tame Beast")
    end

    -- The default movement binds and mouse-move. Not every keyboard is bound
    -- this way, but a player who pressed one of these is driving, and the
    -- kite standing aside for a key it did not need to is the cheap
    -- mistake; running against a key it missed is the expensive one.
    local DRIVE_KEYS = { 0x57, 0x41, 0x53, 0x44, 0x51, 0x45, 0x25, 0x26, 0x27, 0x28 }

    --- Is the player moving the character themselves right now?
    local function user_driving()
        local pressed = ctx.input.is_key_pressed
        if type(pressed) ~= "function" then return false end
        for i = 1, #DRIVE_KEYS do
            if pressed(DRIVE_KEYS[i]) then return true end
        end
        -- Both mouse buttons: mouse-move forward.
        return pressed(0x01) and pressed(0x02)
    end

    ---@param player game_object
    ---@return number seconds between Auto Shots
    local function ranged_speed(player)
        local ok, info = pcall(player.get_unit_ranged_damage, player)
        if ok and type(info) == "table" and type(info.speed) == "number"
            and info.speed > 0.5 and info.speed < 10 then
            return info.speed
        end
        return DEFAULT_SPEED
    end

    --- Is the target under any slow or root of ours? The catalogue says
    --- which abilities those are and what aura each leaves; the two names
    --- are the fallback for a build without it.
    local function slowed(target)
        local H = P.rotation and P.rotation.helpers
        if not H then return false end
        local catalog = P.catalog
        if catalog then
            local found = false
            for _, role in ipairs({ "slow", "root" }) do
                local rows = catalog.with_role(role)
                for i = 1, #rows do
                    found = true
                    local aura = rows[i].applies and rows[i].applies.aura
                    if aura and H.debuff_up(target, aura) then return true end
                end
            end
            if found then return false end
        end
        return H.debuff_up(target, "Concussive Shot") or H.debuff_up(target, "Wing Clip")
    end

    --- The point a few yards directly away from the target, at our height.
    ---@return vec3|nil
    local function away_point(player_pos, target_pos)
        local dx, dy = player_pos.x - target_pos.x, player_pos.y - target_pos.y
        local flat = math.sqrt(dx * dx + dy * dy)
        if flat < 0.5 then return nil end
        return {
            x = player_pos.x + dx / flat * RUN_PROBE,
            y = player_pos.y + dy / flat * RUN_PROBE,
            z = player_pos.z,
        }
    end

    --- Is the ground behind us somewhere a character can run? A cliff edge,
    --- a drop, or a spot the terrain query cannot place answers no, and the
    --- cycle shoots in place instead of running off it.
    local function ground_ok(point)
        local ok, height = pcall(core.get_height_for_position,
            { x = point.x, y = point.y, z = point.z + 2 })
        if not ok or type(height) ~= "number" or height == 0 then return false end
        return math.abs(height - point.z) <= 4
    end

    -- --- the legs -----------------------------------------------------------

    local function release()
        ctx.input.set_key("forward", false)
        ctx.input.release(ctx.input.CHANNEL.MOVEMENT)
        ctx.input.release(ctx.input.CHANNEL.FACING)
    end

    local step_from = nil       -- the add a step is walking away from (its guid)

    local function stop(reason)
        step_from = nil
        if phase ~= "idle" then
            release()
            log.fmt("debug", "kite: stopped -- %s", reason)
        end
        phase = "idle"
        last_reason = reason
    end

    local function enter(new_phase, now, duration)
        phase = new_phase
        phase_since = now
        phase_until = now + (duration or 0)
    end

    --- One Auto Shot went out. The aim is over; the swing is ours to spend
    --- moving.
    local function on_shot(now, player)
        calibrated = true
        shots = shots + 1
        if phase == "shoot" or phase == "run" then
            local run_for = ranged_speed(player) - AIM_TIME - AIM_MARGIN
            if run_for > 0.3 then enter("run", now, run_for) end
        end
    end

    ctx.on("jcore.spell.cast", function(data)
        if phase == "idle" or type(data) ~= "table" then return end
        local ids = book.ids("Auto Shot")
        if not ids then return end
        local hit = false
        for i = 1, #ids do
            if ids[i] == data.spell_id then hit = true break end
        end
        if not hit then return end

        local player = units.player()
        if not player then return end
        -- Only OUR shot. Another hunter's Auto Shot lands in the same
        -- callback.
        if data.caster then
            local ok_a, a = pcall(data.caster.get_guid, data.caster)
            local ok_b, b = pcall(player.get_guid, player)
            if ok_a and ok_b and a ~= b then return end
        end
        on_shot(core.time(), player)
    end)

    ctx.on("jcore.combat.leave", function()
        anchor = nil
        stop("fight over")
    end)

    local function acquire(reason)
        return ctx.input.acquire(ctx.input.CHANNEL.MOVEMENT, ctx.input.PRIORITY.ROTATION, reason)
            and ctx.input.acquire(ctx.input.CHANNEL.FACING, ctx.input.PRIORITY.ROTATION, reason)
    end

    -- --- the step out -------------------------------------------------------

    local step_failed_at = 0

    --- Will this mob follow us if we walk away? A mob on the pet stays on
    --- the pet. Anything else follows unless it is slowed or rooted.
    --- A fight with a player, for the PvP hunter (pvphunter.lua).
    local function pvp_fight()
        local ph = P.pvphunter
        if not (ph and ph.mode) then return false end
        local ok, on = pcall(ph.mode)
        return ok and on == true
    end

    local function follows(target)
        local enemies = ctx.enemies
        local row = enemies and enemies.get and enemies.get(target) or nil
        if row and row.targeting_pet then return false end
        -- Held where it stands, in a PvP hunter's fight (1.7.6): frozen in a
        -- trap, scattered, stunned by Intimidation, rooted -- its peels end
        -- here. A mob held so in PvE is left as before.
        if row and row.control and pvp_fight() then return false end
        return not slowed(target)
    end

    --- How far to walk from this target: further than the dead zone from a
    --- player frozen in our trap (pvphunter.lua's reset), else nil.
    local function reset_to(target)
        local ph = P.pvphunter
        if not (ph and ph.reset_to) then return nil end
        local ok, yards = pcall(ph.reset_to, target)
        return ok and tonumber(yards) or nil
    end

    --- A mob hitting us in melee that is not the target and is held by a
    --- slow or root of ours: the nearest such, or nil. While a step away from
    --- one is under way, that one, wherever it now is.
    local function clipped_add(target)
        local enemies = ctx.enemies
        if not (enemies and enemies.all) then return nil end
        local ok, tguid = pcall(target.get_guid, target)
        local rows = enemies.all()
        local nearest = nil
        for i = 1, #rows do
            local r = rows[i]
            if phase == "step" and step_from ~= nil and r.guid == step_from then return r end
            if not nearest and r.obj and near(r.obj, r.dist or math.huge) and r.targeting_me
                and not r.control and not (ok and r.guid == tguid) and slowed(r.obj) then
                nearest = r
            end
        end
        return nearest
    end

    ---@param now number
    ---@param target game_object the unit to walk away from
    ---@param distance number
    ---@param from_add? boolean it is an add, not the target
    ---@param shoot_at? game_object the target, kept in range while stepping from an add
    local function step_out(now, target, distance, from_add, shoot_at)
        if not opt("step_out", true) then return stop("step out switched off") end
        if from_add and distance >= STEP_OUT_TO then return stop("clear of the add") end
        -- THE PVP RESET (1.7.6): from a player in our Freezing Trap, on to
        -- the reset distance, not just out of the dead zone.
        local reset = not from_add and reset_to(target) or nil
        if reset and distance >= reset then return stop("reset distance from the trapped player") end
        if not from_add and not reset and shootable(target, distance) then return stop("target shootable") end
        if from_add and shoot_at and units.distance(shoot_at) > KEEP_IN_RANGE then
            return stop("stepping further would put the target out of range")
        end
        if phase ~= "step" and (now - step_failed_at) < STEP_RETRY then
            return stop("last step out failed; waiting")
        end
        if follows(target) then return stop("target in melee and not slowed") end
        -- A cast in flight is the rotation's; moving would cancel it.
        if P.rotation.cast_gate_busy() then return stop("casting") end

        local player_pos = units.player_position()
        local target_pos = units.position(target)
        if not player_pos or not target_pos then return stop("no positions") end
        local ahead = away_point(player_pos, target_pos)
        if not ahead or not ground_ok(ahead) then
            step_failed_at = now
            return stop("nowhere safe to step back to")
        end

        if phase ~= "step" then
            if not acquire("stepping out of melee") then
                return stop("movement held by something else")
            end
            enter("step", now, reset and RESET_MAX or STEP_MAX)
            if from_add then
                local ok_g, g = pcall(target.get_guid, target)
                step_from = ok_g and g or nil
                log.fmt("info", "kite: %s clipped in melee at %.0fy, not the target -- stepping clear of it",
                    units.name(target), distance)
            else
                log.fmt("info", "kite: %s inside minimum range at %.0fy -- stepping out",
                    units.name(target), distance)
            end
        elseif now >= phase_until then
            step_failed_at = now
            return stop("could not get clear in time")
        end

        if faced_at < phase_since or (now - faced_at) >= REFACE_EVERY then
            ctx.input.look_at(ahead)
            faced_at = now
        end
        ctx.input.set_key("forward", true)
    end

    -- --- the tick -----------------------------------------------------------

    local function tick()
        if not P.master_on() or not P.opt("rot_enabled", false) or not P.rotation_active() then
            return stop("rotation off")
        end
        if not hunter_active() then return stop("not a hunter") end
        -- Beast Mastery's melee weave (1.8.1): you walk in and out yourself,
        -- and the walk in is what the step out would undo. From the pet
        -- levels on; the run-and-shoot before them is still ours.
        if weave() and (pet_levels() or pet_alive()) then
            return stop("Beast Mastery: you move in and out")
        end
        if user_driving() then return stop("you are driving") end

        local player = units.player()
        if not player then return stop("no player") end

        local target = combat.target()
        if not target or not target:is_valid() or target:is_dead()
            or not player:can_attack(target) then
            return stop("no target")
        end
        if not combat.in_combat() then return stop("not in combat") end

        local now = core.time()
        local distance = units.distance(target)

        -- The pet levels: the legs' only job is the step out of the dead
        -- zone. The run-and-shoot below is for the levels before a pet.
        if pet_levels() or pet_alive() then
            if shootable(target, distance) then
                local add = clipped_add(target)
                if add then return step_out(now, add.obj, add.dist or units.distance(add.obj), true, target) end
            end
            return step_out(now, target, distance)
        end

        if not opt("kite", false) then return stop("switched off") end

        -- One mob. Kiting a second one in is the failure this is not worth --
        -- but a second one clipped in melee is walked away from, the same step
        -- the pet levels use, while the target is still shootable.
        if P.field then
            local count = select(1, P.field.counts())
            if (count or 0) > 1 then
                local add = shootable(target, distance) and clipped_add(target) or nil
                if add then return step_out(now, add.obj, add.dist or units.distance(add.obj), true, target) end
                return stop("more than one attacker")
            end
        end

        -- A cast in flight is the rotation's; moving would cancel it.
        if P.rotation.cast_gate_busy() then return stop("casting") end

        local player_pos = units.player_position()
        local target_pos = units.position(target)
        if not player_pos or not target_pos then return stop("no positions") end

        local is_slowed = slowed(target)

        -- Inside minimum range and not slowed: running gains nothing, since
        -- the mob keeps pace, and the melee rules are the right answer. A
        -- slowed mob is different -- run until it is shootable again.
        if distance <= opt("kite_stop_at", 6) and not is_slowed then
            return stop("target in melee")
        end

        if not anchor then anchor = { x = player_pos.x, y = player_pos.y, z = player_pos.z } end
        local dax, day = player_pos.x - anchor.x, player_pos.y - anchor.y
        local dragged = math.sqrt(dax * dax + day * day)

        if not acquire("kiting") then
            return stop("movement held by something else")
        end

        if phase == "idle" then
            enter("shoot", now)
            log.fmt("info", "kite: %s at %.0fy, no pet -- run and shoot", units.name(target), distance)
        end

        local speed = ranged_speed(player)

        -- Reasons to stand and shoot rather than run this cycle. None of them
        -- ends the kite; the next cycle asks again.
        local hold = nil
        if distance > START_RUNNING_AT and not is_slowed then
            hold = "far enough"
        elseif dragged > opt("kite_max_distance", 60) then
            hold = "pulled far enough from the start"
        end

        if phase == "run" then
            local ahead = away_point(player_pos, target_pos)
            if hold or now >= phase_until or not ahead or not ground_ok(ahead) then
                enter("shoot", now)
            else
                -- The run direction is set on entering the phase and
                -- corrected a couple of times a second, not every tick: the
                -- mob moves, so the away line drifts, but a turn per frame
                -- is a visible shudder for a correction of a degree.
                if faced_at < phase_since or (now - faced_at) >= REFACE_EVERY then
                    ctx.input.look_at(ahead)
                    faced_at = now
                end
                ctx.input.set_key("forward", true)
                return
            end
        end

        -- phase == "shoot": stand, face, let the rotation press Auto Shot,
        -- and wait for the shot. Uncalibrated, the wait is a timer.
        ctx.input.set_key("forward", false)
        if not units.is_facing(player, target, FACE_HALF_ANGLE) then
            ctx.input.face(target)
        end

        if not hold and not calibrated and (now - phase_since) >= (AIM_TIME + AIM_MARGIN + 0.1) then
            local run_for = speed - AIM_TIME - AIM_MARGIN
            if run_for > 0.3 then enter("run", now, run_for) end
        end

        -- Calibrated but no shot for two full swings: the shot is not coming
        -- (out of range, not facing, no ammunition). Standing there is the
        -- wrong answer, so fall back to the timer for this cycle.
        if not hold and calibrated and (now - phase_since) > speed * 2 then
            local run_for = speed - AIM_TIME - AIM_MARGIN
            if run_for > 0.3 then enter("run", now, run_for) end
        end
    end

    ctx.tick(tick, { interval = 0.1, priority = 60 })

    -- --- for the rules ------------------------------------------------------

    ---@return boolean
    function M.active()
        return phase ~= "idle"
    end

    --- Should Concussive Shot go out now? While kiting, as early as it is
    --- available on a target that is not already dazed: the daze is what
    --- turns the cycle into distance.
    ---@param s table the rotation's situation
    ---@return boolean
    function M.wants_slow(s)
        if not (phase == "shoot" or phase == "run") or not s.target then return false end
        if slowed(s.target) then return false end
        return units.distance(s.target) <= 30
    end

    --- Stepping back out of the dead zone right now?
    ---@return boolean
    function M.stepping_out()
        return phase == "step"
    end

    function M.stats()
        return {
            phase = phase,
            shots = shots,
            calibrated = calibrated,
            reason = last_reason,
        }
    end

    return M
end

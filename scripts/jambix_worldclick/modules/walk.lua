-- World Click to Move / walk -- walking you to what you clicked, and what is
-- done once you are there.
--
-- HOW IT WALKS. Sentinel Navigation through JCore's ctx.nav, which takes the
-- movement lease in this plugin's name (PRIORITY: a click is you, so it is
-- over the rotation's 50 and every idle walk, and under JCore's utility and
-- defensive bands). Watched the way Jambix AIO's guide walk is, whose loot
-- walks are the evidence that Sentinel moves you on Forever:
--   * not moved a yard within NAV_PROVE s: Sentinel is dropped for this walk;
--   * no yard gained in STALL s: planned again (REPLANS times), then dropped;
--   * a route Sentinel gives up, or ends short: planned again, then dropped.
-- Dropped, a target within LINE_MAX yards is walked straight at (facing it,
-- holding forward, a jump and a sidestep when stuck); a farther one is given
-- up, and the page says why. A mob that moves gets a new route once it has
-- gone REPLAN_MOVE yards.
--
-- WHEN IT STOPS. You are there (REACH for what it is). You steer (W, A, S,
-- D, Q, E, Space, an arrow key or Escape). What you clicked is gone. You are
-- in combat and "Also in combat" is off. You die. It takes longer than its
-- time limit. Another click starts a new walk in its place.
--
-- WHAT IT DOES THERE (each behind its own switch, all but attacking on):
--   corpse   loots it (JCore's loot.open, which knows how a Forever corpse
--            opens and takes the window Forever leaves full); with nothing
--            left to loot, skins it when it can be skinned
--   object   uses it: a herb, a vein, a chest, a quest object, a mailbox
--            (use_object, the one call that opens a node; it answers false on
--            Forever even when it works, so it is judged by what follows)
--   npc      talks to it
--   mob      targets it; attacks it only with "Attack hostile mobs" on
--   player   targets them
--   spot     nothing: a spot on the ground or the minimap is only walked to
-- A mount is got off first for everything but targeting.
--
-- HOW FAR. As far as you click (the user, 2026-10-11: "should be as far as
-- I want"): no limit unless "Only walk to what is within" is on. A minimap
-- spot can be 230 yd off; the time limit grows with the distance.

return function(P)
    local ctx, units, pick = P.ctx, P.units, P.pick
    local input, nav = ctx.input, ctx.nav
    local opt = P.opt
    local floor, max, sqrt = math.floor, math.max, math.sqrt
    local CHANNEL = input and input.CHANNEL or {}

    local M = {}

    -- --- distances and times -----------------------------------------------------

    -- yd. 4 is inside the client's ~5 for using and talking (the guide walk's
    -- TALK_REACH). A corpse is walked right up to: on Forever every press
    -- made beside one (0.8 to 1.5 yd) opened it, one from a few yards seldom
    -- did (JCore's loot service, 1.6.7).
    -- A spot (the ground, the minimap) is reached a little short: Sentinel's
    -- own arrival is a yard or two off its goal.
    local REACH = { corpse = 2.0, object = 4.0, npc = 4.0, player = 4.0, spot = 3.0 }
    local MELEE_GAP = 1.0         -- yd hitbox to hitbox: in melee
    local MELEE_REACH = 3.5       -- yd centre to centre, for a mob whose combat reach does not read
    local CAST_REACH = 28         -- yd: casting and shooting range
    M.GAME_REACH = 5.0            -- yd: the game's own right-click interacts from here
    local RANGED_CLASS = { [3] = true, [5] = true, [8] = true, [9] = true }   -- hunter, priest, mage, warlock

    local NAV_PROVE = 4           -- s for Sentinel to have moved you a yard
    local START_GRACE = 1.0       -- s after a route is asked for before "not moving" counts
    local STALL = 6               -- s without a yard gained
    local REPLANS = 2
    local REPLAN_MOVE = 3         -- yd a mob moves before its route is planned again
    local REPLAN_GAP = 1.0        -- s between two of those
    local LINE_MAX = 40           -- yd: walked straight at when Sentinel cannot
    local UNSTICK_AFTER = 1.5     -- s without half a yard gained, walking straight
    local UNSTICKS = 4
    local SIDESTEP = 0.6
    local PRIORITY = 60

    local ACT_TRIES = 3
    local ACT_WAIT = 1.5          -- s after a press for its window or its cast
    local DISMOUNT_WAIT = 0.6
    local TAKE_AFTER = 0.3        -- s a loot window is open before its slots are taken (Forever)
    local TAKE_PASSES = 2

    -- W A S D Q E, Space, the arrows, Escape: you are steering, or saying stop.
    local STEER_KEYS = { 0x57, 0x41, 0x53, 0x44, 0x51, 0x45, 0x20, 0x25, 0x26, 0x27, 0x28, 0x1B }

    local VERB = { loot = "looting", skin = "skinning", use = "using", talk = "talking to",
        attack = "attacking", target = "targeting" }

    local function now() return core.time() end
    local try = P.try
    local call = P.call

    local function copy(p) return P.vec3(p.x, p.y, p.z or 0) end

    local function flat(a, b)
        if not a or not b then return math.huge end
        local dx, dy = a.x - b.x, a.y - b.y
        return sqrt(dx * dx + dy * dy)
    end

    local function me() return units.player_position() end

    -- --- what happened ---------------------------------------------------------------

    local state = { text = "waiting for a click", tone = "text_dim" }
    local stats = { clicks = 0, walks = 0, arrived = 0, by_nav = 0, by_line = 0, nav_drops = 0, cancelled = 0,
        failed = 0, acted = 0, ignored = 0 }
    local recent = {}
    local last = nil              -- { text, tone, at }: how the last walk ended

    local function say(text, tone) state.text, state.tone = text, tone or "text" end

    -- --- holding and letting go -------------------------------------------------------

    local held = false

    local function let_go()
        if not held then return end
        held = false
        if input then
            for _, key in ipairs({ "forward", "left", "right" }) do try(input.set_key, key, false) end
            try(input.release, CHANNEL.MOVEMENT)
            try(input.release, CHANNEL.FACING)
        end
        if nav then try(nav.stop) end
    end

    local function hold(facing)
        if not input then return false end
        held = true
        local ok = input.acquire(CHANNEL.MOVEMENT, PRIORITY, "world click") and true or false
        if facing then ok = (input.acquire(CHANNEL.FACING, PRIORITY, "world click") and ok) and true or false end
        return ok
    end

    -- --- reaching it ------------------------------------------------------------------

    --- How near a hostile mob the walk takes you: "melee" or yards.
    local function enemy_reach()
        local choice = opt("enemy_reach", 1)
        if choice == 2 then return "melee" end
        if choice == 3 then return CAST_REACH end
        local class = ctx.player and ctx.player.class_id and try(ctx.player.class_id) or 0
        return RANGED_CLASS[class or 0] and CAST_REACH or "melee"
    end
    M.enemy_reach = enemy_reach

    --- How far it is: the game's distance to a thing, across the ground to a
    --- spot (whose height is the ground's best guess).
    local function distance_to(thing)
        if thing.kind == "spot" or not thing.obj then return flat(me(), thing.pos) end
        return units.distance(thing.obj)
    end

    --- Are you there? Straight-line distance, as the game measures a reach.
    local function there(thing)
        local obj = thing.obj
        local d = distance_to(thing)
        if thing.kind == "enemy" then
            local reach = enemy_reach()
            if reach == "melee" then
                local gap = units.melee_distance and units.melee_distance(obj) or d
                return gap <= MELEE_GAP or d <= MELEE_REACH
            end
            return d <= reach
        end
        return d <= (REACH[thing.kind] or 3.0)
    end
    M.there = there

    -- --- the job ------------------------------------------------------------------------
    --
    -- job = { thing, phase = "walk" | "act", at, ... }; the walk's own state in
    -- job.leg = { mode = "nav" | "line", goal, started, proved, ... }.

    local job = nil
    local leg_seq = 0

    local function trace_name(thing)
        return string.format("%s (%s)", tostring(thing.name), thing.kind)
    end

    local function finish(text, tone, counted)
        if job then
            local took = now() - job.at
            P.note("%s: %s (%.1fs)", trace_name(job.thing), text, took)
            recent[#recent + 1] = { t = now(), text = tostring(job.thing.name) .. ": " .. text }
            while #recent > 8 do table.remove(recent, 1) end
        end
        if counted then stats[counted] = (stats[counted] or 0) + 1 end
        let_go()
        last = { text = text, tone = tone or "text", at = now(), name = job and job.thing.name or nil }
        job = nil
        say("waiting for a click", "text_dim")
    end

    --- Stops whatever is under way; `why` goes to the page and the trace.
    function M.cancel(why)
        if not job then return false end
        finish(why or "stopped", "text_dim", "cancelled")
        return true
    end

    local function fail(why)
        finish(why, "warning", "failed")
    end

    -- --- the walk ------------------------------------------------------------------------

    local function nav_up()
        return nav ~= nil and try(nav.available) == true
    end

    local function begin_line(leg, t)
        leg.mode, leg.best, leg.best_at, leg.unsticks, leg.side = "line", -math.huge, t, 0, nil
        stats.by_line = stats.by_line + 1
    end

    --- Sentinel is given up on for this walk: straight at it when that is
    --- allowed and near enough, else the walk ends.
    local function drop_nav(t, pos, why)
        local leg = job.leg
        stats.nav_drops = stats.nav_drops + 1
        try(nav.stop)
        if not opt("straight", true) then
            return fail("Sentinel " .. why)
        end
        if flat(pos, leg.goal) > LINE_MAX then
            return fail("Sentinel " .. why .. ", and it is too far to walk straight at")
        end
        P.note("%s: Sentinel %s; walking straight at it", trace_name(job.thing), why)
        begin_line(leg, t)
    end

    local function step_nav(t, pos)
        local leg = job.leg
        if not hold(false) then
            -- Something with a higher claim is moving you (JCore stops our
            -- route): start again when it lets go.
            leg.started, leg.best_at = false, t
            return
        end
        if not leg.started then
            leg.started, leg.started_at = true, t
            if not leg.restart then leg.start_pos = copy(pos) end
            leg_seq = leg_seq + 1
            local id = leg_seq
            leg.id, leg.done, leg.done_ok, leg.why = id, nil, nil, nil
            local ok = nav.move_to(copy(leg.goal), { priority = PRIORITY, reason = "world click",
                on_done = function(done_ok, why)
                    if job and job.leg and job.leg.id == id then
                        job.leg.done, job.leg.done_ok, job.leg.why = true, done_ok, why
                    end
                end })
            if not ok then return drop_nav(t, pos, "would not start a route") end
            return
        end
        if not leg.proved then
            if flat(pos, leg.start_pos) >= 1.0 then
                leg.proved = true
                leg.best, leg.best_at = -flat(pos, leg.goal), t
            elseif t - leg.started_at >= NAV_PROVE then
                return drop_nav(t, pos, string.format("did not move you in %ds (%s%s)", NAV_PROVE,
                    tostring(try(nav.state) or "?"), leg.why and (", " .. tostring(leg.why)) or ""))
            end
            return
        end
        local d = flat(pos, leg.goal)
        if -d > leg.best + 1 then leg.best, leg.best_at = -d, t end
        -- A mob on the move: a new route to where it is now.
        local target = job.thing.pos
        if flat(target, leg.goal) > REPLAN_MOVE and t - (leg.retarget_at or 0) >= REPLAN_GAP then
            leg.goal, leg.retarget_at = copy(target), t
            leg.started, leg.restart = false, true
            return
        end
        if t - leg.started_at < START_GRACE then return end
        if leg.done and not leg.done_ok then
            if leg.replans < REPLANS then
                leg.replans, leg.started, leg.restart = leg.replans + 1, false, true
                return
            end
            return drop_nav(t, pos, "gave up the route" .. (leg.why and (" (" .. tostring(leg.why) .. ")") or ""))
        end
        if not try(nav.is_moving) then
            -- Sentinel thinks it is there and you are not: plan again, then straight at it.
            if leg.replans < REPLANS then
                leg.replans, leg.started, leg.restart = leg.replans + 1, false, true
                return
            end
            return drop_nav(t, pos, "stopped short")
        end
        if t - leg.best_at > STALL then
            if leg.replans >= REPLANS then return drop_nav(t, pos, "made no progress") end
            leg.replans, leg.best_at = leg.replans + 1, t
            P.note("%s: no progress on Sentinel, planning again (%d)", trace_name(job.thing), leg.replans)
            try(nav.replan, "no progress")
        end
    end

    local function step_line(t, pos)
        local leg = job.leg
        leg.goal = copy(job.thing.pos)
        local d = flat(pos, leg.goal)
        if -d > leg.best + 0.5 then leg.best, leg.best_at = -d, t end
        if not hold(true) then
            for _, key in ipairs({ "forward", "left", "right" }) do try(input.set_key, key, false) end
            leg.side, leg.best_at = nil, t
            return
        end
        if leg.side and t >= leg.side.until_t then
            input.set_key(leg.side.key, false)
            leg.side, leg.best_at = nil, t
        end
        input.look_at(leg.goal)
        input.set_key("forward", true)
        if not leg.side and t - leg.best_at > UNSTICK_AFTER then
            if leg.unsticks >= UNSTICKS then return fail("stuck walking straight at it") end
            leg.unsticks = leg.unsticks + 1
            local key = leg.unsticks % 2 == 1 and "left" or "right"
            try(input.jump)
            input.set_key(key, true)
            leg.side = { key = key, until_t = t + SIDESTEP }
        end
    end

    -- --- being there ----------------------------------------------------------------------

    -- What the game says after a press, by its events: a loot window, any
    -- other window (a mailbox, a poster's quest, a gossip), the player's cast
    -- starting (a herb, a vein, a skin, a locked chest), or an error ("Requires
    -- Herbalism 50"), which ends the job with the game's own words.
    local loot_opened_at = -1e9
    local window_at = -1e9
    local cast_at = -1e9
    local error_at, error_text = -1e9, nil
    local WINDOW_EVENTS = { "MAIL_SHOW", "GOSSIP_SHOW", "QUEST_DETAIL", "QUEST_GREETING", "QUEST_PROGRESS",
        "QUEST_COMPLETE", "ITEM_TEXT_BEGIN", "MERCHANT_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" }

    local function mounted()
        local player = units.player()
        return player and call(player, "is_mounted") == true
    end

    --- What to do at it, by what it is and the switches: an action, or nil.
    local function action_for(thing)
        local kind, obj = thing.kind, thing.obj
        if kind == "corpse" then
            local lootable, skinnable = false, false
            if ctx.loot and ctx.loot.corpse then
                local ok, l, s = pcall(ctx.loot.corpse, obj)
                if ok then lootable, skinnable = l == true, s == true end
            end
            if lootable and opt("act_loot", true) then return "loot" end
            if skinnable and opt("act_skin", true) then return "skin" end
            return nil
        elseif kind == "object" then
            return opt("act_use", true) and "use" or nil
        elseif kind == "npc" then
            return opt("act_talk", true) and "talk" or nil
        elseif kind == "enemy" then
            return opt("act_attack", false) and "attack" or "target"
        elseif kind == "player" then
            return "target"
        end
        return nil
    end

    local function set_target(obj)
        if not input then return false end
        if not input.acquire(CHANNEL.TARGET, PRIORITY, "world click") then return false end
        local ok = try(input.set_target, obj) == true
        try(input.release, CHANNEL.TARGET)
        return ok
    end

    local function press(action, obj)
        if action == "loot" or action == "skin" then
            if ctx.loot and ctx.loot.open then return try(ctx.loot.open, obj, action) end
            if action == "loot" then return try(input.loot, obj) end
            return try(input.skin, obj)
        elseif action == "use" then
            return try(input.use_object, obj)
        elseif action == "talk" then
            return try(input.interact, obj)
        elseif action == "attack" then
            set_target(obj)
            return try(input.interact, obj)
        elseif action == "target" then
            return set_target(obj)
        end
        return nil
    end

    --- Is the player casting (a herb's, a vein's, a skin's bar)?
    local function casting()
        local player = units.player()
        if not player then return false end
        return call(player, "is_casting_spell") == true or call(player, "is_channelling_spell") == true
    end

    local function loot_count()
        local gui = type(core) == "table" and core.game_ui or nil
        local fn = gui and gui.get_loot_item_count
        if type(fn) ~= "function" then return 0 end
        local ok, n = pcall(fn)
        return ok and tonumber(n) or 0
    end

    --- Forever leaves a loot window full; JCore takes its slots.
    local function needs_taking()
        local loot = ctx.loot
        if not (loot and loot.window_needs_taking) then return false end
        local ok, yes = pcall(loot.window_needs_taking)
        return ok and yes == true
    end

    local function act_tick(t)
        local thing = job.thing
        local a = job.act
        if not a then
            local action = action_for(thing)
            if not action then
                return finish(thing.kind == "corpse" and "there (nothing to loot or skin)" or "there", "good", "arrived")
            end
            a = { action = action, tries = 0, at = -1e9 }
            job.act = a
            if action ~= "target" and mounted() then
                try(input.dismount)
                a.dismount_at = t
            end
        end
        if a.dismount_at and t - a.dismount_at < DISMOUNT_WAIT then
            return say("getting off your mount", "text")
        end

        -- A window opened by this press: the press worked. Forever's needs
        -- its slots taken.
        if a.tries > 0 and loot_opened_at >= a.at then
            if needs_taking() and loot_count() > 0 then
                a.takes = a.takes or 0
                if a.takes < TAKE_PASSES and t - loot_opened_at >= TAKE_AFTER * (a.takes + 1) then
                    a.takes = a.takes + 1
                    try(ctx.loot.take_window)
                end
                if a.takes < TAKE_PASSES then return say(VERB[a.action] .. " " .. tostring(thing.name), "text") end
            end
            stats.acted = stats.acted + 1
            return finish(a.action == "skin" and "skinned" or (a.action == "use" and "opened" or "looted"), "good",
                "arrived")
        end
        -- A cast started by this press (a herb, a vein, a skin): the game's now.
        if a.tries > 0 and (a.action == "use" or a.action == "skin") and (cast_at >= a.at or casting()) then
            stats.acted = stats.acted + 1
            return finish(a.action == "skin" and "skinning" or "gathering", "good", "arrived")
        end
        -- Another window (a mailbox, a quest from a poster): opened.
        if a.tries > 0 and window_at >= a.at then
            stats.acted = stats.acted + 1
            return finish("opened", "good", "arrived")
        end
        -- The game said no.
        if a.tries > 0 and error_at >= a.at then
            return finish("there; the game said \"" .. tostring(error_text) .. "\"", "warning", "arrived")
        end
        -- JCore still waiting on a corpse press it made.
        if (a.action == "loot" or a.action == "skin") and ctx.loot and ctx.loot.opening then
            local ok, waiting = pcall(ctx.loot.opening)
            if ok and waiting then return say(VERB[a.action] .. " " .. tostring(thing.name), "text") end
        end
        if a.tries > 0 and t - a.at < ACT_WAIT then
            return say(VERB[a.action] .. " " .. tostring(thing.name), "text")
        end
        if a.tries >= ACT_TRIES then
            return finish("there, but it did not open", "warning", "arrived")
        end
        a.tries, a.at = a.tries + 1, t
        local answered = press(a.action, thing.obj)
        P.note("%s: %s (try %d, answered %s)", trace_name(thing), a.action, a.tries, tostring(answered))
        -- One press is the whole of it: the game takes it from here.
        if a.action == "talk" or a.action == "attack" or a.action == "target" then
            stats.acted = stats.acted + 1
            return finish(a.action == "target" and "there; targeted" or ("there; " .. VERB[a.action] .. " it"),
                "good", "arrived")
        end
        say(VERB[a.action] .. " " .. tostring(thing.name), "text")
    end

    -- --- starting -------------------------------------------------------------------------

    --- A click on `thing`. `opts.game_clicks` says the game's own click
    --- interacts with it too (a right-click). Returns accepted, text, and
    --- "game" when it is left to the game's own click (no refusal to show).
    function M.start(thing, opts)
        opts = opts or {}
        stats.clicks = stats.clicks + 1
        local t = now()
        local pos = me()
        if not pos then return false, "not in the world" end
        local d = distance_to(thing)
        local limit = opt("limit_range", false) and opt("max_range", 100) or nil
        if limit and d > limit then
            stats.ignored = stats.ignored + 1
            return false, string.format("%s is %d yd away; the limit is %d", tostring(thing.name), floor(d), limit)
        end
        -- A spot: nothing to do there, so being there is the end of it.
        if thing.kind == "spot" and there(thing) then
            stats.ignored = stats.ignored + 1
            return false, "you are there already"
        end
        -- In the game's own reach. A right-click loots, gathers, talks or
        -- attacks from here by itself; a walk and a second press would only
        -- break it (moving cancels a gathering cast).
        local own_reach
        if thing.kind == "spot" then
            own_reach = false
        elseif thing.kind == "enemy" or thing.kind == "player" then
            own_reach = there(thing)
        else
            own_reach = d <= M.GAME_REACH
        end
        if opts.game_clicks and own_reach then
            stats.ignored = stats.ignored + 1
            return false, tostring(thing.name) .. " is in reach: the game's own click does it", "game"
        end
        -- Already there.
        if there(thing) then
            if job then finish("a new click", "text_dim", "cancelled") end
            job = { thing = thing, phase = "act", at = t }
            return true, "there"
        end
        local mode = nav_up() and "nav" or nil
        if not mode then
            if not opt("straight", true) then
                return false, "Sentinel Navigation is not connected"
            end
            if flat(pos, thing.pos) > LINE_MAX then
                return false, string.format("Sentinel Navigation is not connected, and %s is %d yd away",
                    tostring(thing.name), floor(d))
            end
            mode = "line"
        end
        if job then finish("a new click", "text_dim", "cancelled") end
        job = { thing = thing, phase = "walk", at = t,
            limit = max(30, d / 3 + 20),
            leg = { mode = mode, goal = copy(thing.pos), started = false, proved = false, replans = 0,
                best = -math.huge, best_at = t, unsticks = 0 } }
        stats.walks = stats.walks + 1
        if mode == "nav" then stats.by_nav = stats.by_nav + 1 else stats.by_line = stats.by_line + 1 end
        P.note("walking to %s, %.0f yd (%s, picked %s%s)", trace_name(thing), d,
            mode == "nav" and "Sentinel" or "straight at it", tostring(thing.how),
            thing.found and (", " .. tostring(thing.found)) or "")
        return true, mode
    end

    -- --- the tick -------------------------------------------------------------------------

    local function steering()
        if not input or try(input.is_typing) then return false end
        for i = 1, #STEER_KEYS do
            if try(input.is_key_pressed, STEER_KEYS[i]) == true then return true end
        end
        return false
    end

    function M.tick()
        if not job then return end
        local t = now()
        local player = units.player()
        local pos = me()
        if not player or not pos then return M.cancel("left the world") end
        if call(player, "is_dead") == true and call(player, "is_ghost") ~= true then return M.cancel("you died") end
        if steering() then return M.cancel("you moved") end
        if not opt("in_combat", false) and call(player, "is_in_combat") == true then
            return M.cancel("you are in combat")
        end

        local thing = job.thing
        if thing.kind ~= "spot" and not pick.refresh(thing) then
            if job.act and (job.act.action == "use" or job.act.action == "loot" or job.act.action == "skin") then
                stats.acted = stats.acted + 1
                return finish("done (it is gone)", "good", "arrived")
            end
            return fail(tostring(thing.name) .. " is gone")
        end
        -- A mob that died on the way is a corpse now.
        if thing.kind == "enemy" and call(thing.obj, "is_dead") == true then thing.kind = "corpse" end

        if job.phase == "walk" then
            if there(thing) then
                P.note("%s: got there (%s, %.1fs)", trace_name(thing),
                    job.leg.mode == "nav" and "Sentinel" or "straight", t - job.at)
                let_go()
                job.phase = "act"
                return act_tick(t)
            end
            if t - job.at > job.limit then
                return fail(string.format("took over %ds", floor(job.limit)))
            end
            say(string.format("walking to %s (%.0f yd%s)", tostring(thing.name), flat(pos, thing.pos),
                job.leg.mode == "line" and ", straight" or ""), "text")
            if job.leg.mode == "nav" then step_nav(t, pos) else step_line(t, pos) end
            return
        end
        act_tick(t)
    end

    -- --- events ---------------------------------------------------------------------------

    if ctx.on then
        ctx.on("jcore.game_event.LOOT_OPENED", function() loot_opened_at = now() end)
        for i = 1, #WINDOW_EVENTS do
            ctx.on("jcore.game_event." .. WINDOW_EVENTS[i], function() window_at = now() end)
        end
        ctx.on("jcore.game_event.UNIT_SPELLCAST_START", function(args)
            if type(args) == "table" and args[1] == "player" then cast_at = now() end
        end)
        -- args: the error's type and its message (a nil one leaves a hole).
        ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
            if not job or not job.act then return end
            local text = type(args) == "table" and (args[2] or args[1]) or nil
            error_at, error_text = now(), text ~= nil and tostring(text) or "an error"
        end)
        ctx.on("jcore.player.died", function() M.cancel("you died") end)
        ctx.on("jcore.zone.changed", function() M.cancel("zone changed") end)
    end

    -- --- what it is doing -------------------------------------------------------------------

    --- Where the walk is going, for the overlay: { goal, name, kind, mode,
    --- path } while it walks, else nil. `path` is Sentinel's route when it is
    --- this walk's: its last point within ROUTE_END of the goal.
    local ROUTE_END = 10
    function M.route()
        if not job or job.phase ~= "walk" then return nil end
        local leg = job.leg
        local path = nil
        if leg.mode == "nav" and leg.started then
            local public = P.JCore and P.JCore.nav
            local get = type(public) == "table" and public.current_path or nil
            local p = try(get)
            if type(p) == "table" and #p > 0 then
                local ok, d = pcall(flat, p[#p], leg.goal)
                if ok and d <= ROUTE_END then path = p end
            end
        end
        return { goal = job.thing.pos, name = job.thing.name, kind = job.thing.kind, mode = leg.mode, path = path,
            obj = job.thing.obj }
    end

    function M.active() return job ~= nil end
    function M.phase() return job and job.phase or nil end
    function M.target() return job and job.thing or nil end
    function M.status() return state.text, state.tone end
    function M.last() return last end
    function M.recent() return recent end

    function M.stats()
        return {
            clicks = stats.clicks, walks = stats.walks, arrived = stats.arrived, by_nav = stats.by_nav,
            by_line = stats.by_line, nav_drops = stats.nav_drops, cancelled = stats.cancelled,
            failed = stats.failed, acted = stats.acted, ignored = stats.ignored,
            walking = job and job.thing.name or nil, phase = job and job.phase or nil,
            mode = job and job.leg and job.leg.mode or nil, state = state.text,
        }
    end

    return M
end

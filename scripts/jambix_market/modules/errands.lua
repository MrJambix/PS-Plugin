-- Jambix Market / errands -- the mail run: walk to the mailbox, take the
-- mail, walk back to the auctioneer and open the auction house again.
--
-- The user (2026-10-07): "let's add pathin to Mailbox pick up all the mail
-- and pathing back to the auctioneer without getting stuck anywhere".
--
-- ONLY WITH THE BOX TICKED. "Walk to the mailbox and back to the auctioneer by
-- itself" (the settings page, and the window above the mail-run line) is off
-- by default (the user, 2026-10-08: "make the Moving to AH and the Mailbox a
-- checkbox if its not checked its gonna have to be manual! mainly cause im
-- reworking pathing"). Off, nothing here moves you: you walk to the mailbox,
-- Auto still takes the mail when you open it (auto.try_collect), and your
-- walks are still learned as routes. Unticked mid-run, the run stops at once
-- and lets go of every key.
--
-- WHEN. Auto is on, the auction house is open and nothing is under way (no
-- purchase or post, no full or quick scan), and the mailbox holds something
-- worth the walk (trader.mail_waiting, ledger.inbox_seen): sale money of at
-- least max(5s, 0.5% of your capital), or any money or items once
-- OLD_WAIT has passed since the last run. Not more often than RUN_GAP.
--
-- WHERE. The mailbox is the nearest game object named "Mailbox" (or of a
-- mailbox's entry id) in JCore's object sweep, within MAX_DIST of you: on
-- Forever game objects answer get_name and mailboxes are type 257 like a
-- herb, so the name is the test (the user's recorded catalog, 2026-10-07).
-- The way back is the spot you stood at when the auction house last opened;
-- the auctioneer is the unit with the auctioneer flag (0x200000) nearest it.
--
-- HOW IT WALKS. The first build walked with Sentinel Navigation alone, and in
-- the user's game it never moved (2026-10-08: "its thinking its collecting
-- mailbox but it never actually made the movement there"; the recorder shows
-- no movement at all that session). What does move a character on Forever is
-- facing a point and holding forward (Jambix AIO's kiting: look_at +
-- move_forward_start, answered by PLAYER_STARTED_MOVING in the recorder). So
-- a walk is, first choice first:
--   route  the way YOU walked it: while you walk, your positions are kept,
--          and a walk from the auction house to a mailbox you then opened
--          (or back from one to the auction house) is learned as a route
--          (scripts_data/jcore/jambix.market.routes.json). Followed point by
--          point, facing each and holding forward: it goes where you went,
--          around every wall you went around.
--   nav    Sentinel Navigation, when it is connected and no route is
--          learned. If it has not moved you NAV_PROVE seconds after it
--          started, it is dropped for the session and the walk goes on as:
--   line   straight at the target, facing it and holding forward, when it
--          is within LINE_MAX yards.
-- (JCore 1.12's obstacle map, ctx.walkmap, was used here for a day and is
-- gone: the user found it stuck everywhere, 2026-10-08. JCore's ctx.nav is
-- being rebuilt instead; walking is behind the checkbox meanwhile.)
-- With none of those, no run starts, and the window says to walk to the
-- mailbox and back once so the way is learned.
--
-- NEVER STUCK. Every walk is watched:
--   * route and line: no progress (a waypoint passed, or half a yard gained)
--     for UNSTICK_AFTER seconds -- a jump and a sidestep, left then right in
--     turn; after UNSTICKS of those the run stops;
--   * nav: no yard gained in STALL seconds -- the route is planned again;
--     after REPLANS without progress, the walk goes on as a line;
--   * LEG_LIMIT seconds for any one walk.
-- A run that stops lets go of every key (the character stands still), says
-- where and why, and pauses runs for FAIL_PAUSE. Combat, death, or Auto
-- turned off end a run at once.
--
-- Steps:
--   to_mail    walk until within REACH of the mailbox
--   open_mail  use_object on it until the mailbox opens (MAIL_SHOW;
--              use_object answers false on Forever even when it works)
--   collect    the ledger takes every mail but a COD one
--   to_ah      walk back to the spot
--   open_ah    interact with the auctioneer until the auction house opens
--
-- Every run is logged (the last 120 lines) in
-- scripts_data/jcore/jambix.market.errands.json, so how one went can be read
-- afterwards.

return function(M)
    local ctx, U, A, L, T, S = M.ctx, M.util, M.ah, M.ledger, M.trader, M.scanner

    local E = {}

    local MAILBOX_NAMES = { ["Mailbox"] = true }
    local MAILBOX_IDS = { [142075] = true }  -- the user's recorded catalog, 2026-10-07
    local AUCTIONEER_FLAG = 0x200000
    local REACH = 4.0             -- yd: close enough to use or interact (the client's ~5)
    local HOME_REACH = 3.0        -- yd from the spot you left
    local MAX_DIST = 100          -- yd: the mailbox in sight of the auction house
    local LINE_MAX = 60           -- yd: walked straight at without a route
    local WAYPOINT = 1.8          -- yd: a route point counts as passed
    local UNSTICK_AFTER = 1.5     -- s without progress, walking a route or a line
    local UNSTICKS = 5
    local SIDESTEP = 0.7          -- s of a sidestep
    local NAV_PROVE = 4           -- s for Sentinel to have moved you
    local STALL = 8               -- s without a yard gained, on Sentinel
    local REPLANS = 2
    local LEG_LIMIT = 90          -- s for one walk
    local OPEN_TRIES = 3
    local OPEN_WAIT = 4           -- s for a window to open after a try
    local SETTLE = 0.5            -- s standing still before a try
    local COLLECT_LIMIT = 60      -- s at the mailbox at most
    local RUN_GAP = 10 * 60
    local OLD_WAIT = 20 * 60
    local FAIL_PAUSE = 30 * 60
    local MIN_WAIT_FLOOR = 500    -- copper
    local MIN_WAIT_SHARE = 0.005  -- of capital
    local LOOK_EVERY = 5          -- s between checks for a run while idle
    local PRIORITY = 30           -- over idle; a rotation or a defensive comes first
    local TRAIL_STEP = 1.5        -- yd between kept positions of your own walking
    local TRAIL_KEEP = 600
    local TRAIL_AGE = 300         -- s: a walk older than this is not learned
    local ROUTE_MIN_GAP = 2.0     -- yd between the points a route keeps
    local ROUTES_KEPT = 20
    local LOG_KEPT = 120

    local run = nil               -- the run under way
    local home = nil              -- { pos, guid }: where you stood at the auctioneer
    local last_run_at = nil       -- core.time() of the last run that finished
    local paused_until = 0
    local last = nil              -- { ok, text, t }: how the last run ended
    local why_not = nil           -- why no run starts now, for the window
    local next_look = 0
    local leg_seq = 0
    local nav_dead = nil          -- why Sentinel is not used this session

    local store = ctx.store("errands")
    local saved = store:all()
    saved.log = type(saved.log) == "table" and saved.log or {}
    saved.routes = type(saved.routes) == "table" and saved.routes or {}

    --- A line in the run log (and the debug log).
    local function log(fmt, ...)
        local text = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        M.debug("mail run: %s", text)
        local list = saved.log
        list[#list + 1] = { t = U.now(), text = text }
        while #list > LOG_KEPT do table.remove(list, 1) end
        store:touch()
    end

    -- --- the world ---------------------------------------------------------------

    local function copy(pos)
        if not pos then return nil end
        return { x = pos.x, y = pos.y, z = pos.z or 0 }
    end

    local function dist(a, b)
        if not a or not b then return math.huge end
        local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end

    local function me() return ctx.units.player_position() end

    local function is_mailbox(obj)
        if U.method(obj, "is_unit") then return false end
        local name = U.method(obj, "get_name")
        if type(name) == "string" and MAILBOX_NAMES[name] then return true end
        local id = tonumber(U.method(obj, "get_npc_id"))
        return id ~= nil and MAILBOX_IDS[id] == true
    end

    --- The nearest mailbox within `within` yards: its guid, position, distance.
    local function find_mailbox(within)
        local from = me()
        if not from then return nil end
        local best, best_d = nil, nil
        for _, obj in ipairs(ctx.units.objects() or {}) do
            if is_mailbox(obj) then
                local d = dist(from, ctx.units.position(obj))
                if d <= (within or MAX_DIST) and (not best_d or d < best_d) then best, best_d = obj, d end
            end
        end
        if not best then return nil end
        return { guid = U.method(best, "get_guid"), pos = copy(ctx.units.position(best)), dist = best_d }
    end

    local function is_auctioneer(u)
        if U.method(u, "is_player") then return false end
        local flags = tonumber(U.method(u, "get_npc_flags")) or 0
        return math.floor(flags / AUCTIONEER_FLAG) % 2 == 1
    end

    --- The auctioneer nearest `pos` (within `within` yards).
    local function find_auctioneer(pos, within)
        if not pos then return nil end
        local best, best_d = nil, nil
        for _, u in ipairs(ctx.units.units() or {}) do
            if is_auctioneer(u) then
                local d = dist(pos, ctx.units.position(u))
                if d <= within and (not best_d or d < best_d) then best, best_d = u, d end
            end
        end
        return best, best_d
    end

    local function resolve(guid)
        if not guid then return nil end
        return ctx.units.by_guid(guid)
    end

    -- --- learning the way from your own walks -----------------------------------

    local trail = {}              -- { x, y, z, t } while you walk
    local last_mailbox = nil      -- { pos, at }: the mailbox you last opened

    local function simplify(points)
        local out = {}
        for i = 1, #points do
            local p = points[i]
            if #out == 0 or dist(out[#out], p) >= ROUTE_MIN_GAP or i == #points then
                out[#out + 1] = { x = p.x, y = p.y, z = p.z or 0 }
            end
        end
        return out
    end

    local function length(points)
        local total = 0
        for i = 2, #points do total = total + dist(points[i - 1], points[i]) end
        return total
    end

    --- The trail from the last time you were within `within` of `pos` (no
    --- longer ago than TRAIL_AGE) up to now, or nil.
    local function trail_from(pos, within)
        local now = core.time()
        for i = #trail, 1, -1 do
            if now - trail[i].t > TRAIL_AGE then return nil end
            if dist(trail[i], pos) <= within then
                local out = {}
                for j = i, #trail do out[#out + 1] = trail[j] end
                local here = me()
                if here then out[#out + 1] = here end
                return out
            end
        end
        return nil
    end

    --- Keeps a walk from `from` (the auction house spot) to `to` (a mailbox).
    local function learn(from, to, points)
        points = simplify(points)
        local len = length(points)
        if #points < 2 or len < 3 or len > 3 * MAX_DIST then return end
        local routes = saved.routes
        for i = #routes, 1, -1 do
            local r = routes[i]
            if dist(r.from, from) <= 8 and dist(r.to, to) <= 5 then table.remove(routes, i) end
        end
        routes[#routes + 1] = { from = copy(from), to = copy(to), points = points, at = U.now() }
        while #routes > ROUTES_KEPT do table.remove(routes, 1) end
        store:touch()
        log("learned the way between the auction house and the mailbox: %d points, %.0f yards", #points, len)
        M.activity(string.format("Mail run: learned the way to the mailbox from your walk (%.0f yards)", len))
    end

    --- A learned route from near `from` to near `to`, in walking order. A
    --- route runs from an auction house spot (r.from: you stand a few yards
    --- differently each time) to a mailbox (r.to: it does not move).
    local function route_for(from, to)
        if not from or not to then return nil end
        local best, best_score = nil, nil
        for _, r in ipairs(saved.routes) do
            -- To the mailbox: its end at the goal, its start near you.
            local fwd = dist(r.from, from) + dist(r.to, to)
            if dist(r.to, to) <= 6 and dist(r.from, from) <= 12 and (not best_score or fwd < best_score) then
                best, best_score = { points = r.points, reverse = false }, fwd
            end
            -- Back from it: its end near you, its start at the goal.
            local back = dist(r.to, from) + dist(r.from, to)
            if dist(r.to, from) <= 6 and dist(r.from, to) <= 12 and (not best_score or back < best_score) then
                best, best_score = { points = r.points, reverse = true }, back
            end
        end
        if not best then return nil end
        local out = {}
        local pts = best.points
        if best.reverse then
            for i = #pts, 1, -1 do out[#out + 1] = pts[i] end
        else
            for i = 1, #pts do out[#out + 1] = pts[i] end
        end
        return out
    end

    -- Your positions while you walk (not while a run walks for you).
    ctx.tick(function()
        if run then return end
        local p = me()
        if not p then return end
        local lastp = trail[#trail]
        if not lastp or dist(lastp, p) >= TRAIL_STEP then
            trail[#trail + 1] = { x = p.x, y = p.y, z = p.z or 0, t = core.time() }
            while #trail > TRAIL_KEEP do table.remove(trail, 1) end
        end
    end, { interval = 0.25 })

    -- You opened a mailbox: the walk from the auction house to it is a route.
    ctx.on("jcore.game_event.MAIL_SHOW", function()
        local box = find_mailbox(8)
        if not box then return end
        last_mailbox = { pos = box.pos, at = core.time() }
        if run or not home then return end
        local walk = trail_from(home.pos, 6)
        if walk then learn(home.pos, box.pos, walk) end
    end)

    -- Where you stood when the auction house opened: the way back -- and the
    -- walk back from a mailbox you had just opened is a route.
    ctx.on("jambix.market.ah_open", function()
        local pos = me()
        if not pos then return end
        local auctioneer = find_auctioneer(pos, 10)
        home = { pos = copy(pos), guid = auctioneer and U.method(auctioneer, "get_guid") or nil }
        if run or not last_mailbox or core.time() - last_mailbox.at > TRAIL_AGE then return end
        local walk = trail_from(last_mailbox.pos, 6)
        if walk then
            local forward = {}
            for i = #walk, 1, -1 do forward[#forward + 1] = walk[i] end
            learn(home.pos, last_mailbox.pos, forward)
        end
    end)


    -- --- ending a run --------------------------------------------------------------

    local function let_go()
        for _, key in ipairs({ "forward", "left", "right" }) do U.try(ctx.input.set_key, key, false) end
        U.try(ctx.nav.stop)
        U.try(ctx.input.release, ctx.input.CHANNEL.MOVEMENT)
        U.try(ctx.input.release, ctx.input.CHANNEL.FACING)
    end

    local function finish(ok, text, pause)
        let_go()
        local t = core.time()
        last = { ok = ok, text = text, t = t }
        if run and run.started then last_run_at = t end
        if pause then paused_until = t + pause end
        run = nil
        log("%s: %s", ok and "done" or "stopped", text)
        M.activity("Mail run: " .. text)
        if not ok then M.toast("Mail run stopped: " .. text, "warning") end
    end

    local function fail(text)
        local pos = me()
        return finish(false, text .. (pos and string.format(" (stopped at %.0f, %.0f)", pos.x, pos.y) or "")
            .. "; runs pause for " .. U.ago(FAIL_PAUSE), FAIL_PAUSE)
    end

    -- --- walking ---------------------------------------------------------------------

    local MODE_TEXT = { route = "the way you walked it", nav = "Sentinel Navigation", line = "straight at it" }


    --- How a walk to `goal` can go now: "route" (with its points), "nav",
    --- "line", or nil and why not.
    local function plan(from, goal)
        local pts = route_for(from, goal)
        if pts then return "route", pts end
        if not nav_dead and ctx.nav.available() then return "nav" end
        if dist(from, goal) <= LINE_MAX then return "line", { goal } end
        return nil, nil, "no way learned yet: walk from the auction house to the mailbox and back once, and the "
            .. "way is learned" .. (nav_dead and (" (Sentinel Navigation: " .. nav_dead .. ")")
                or (not ctx.nav.available() and " (Sentinel Navigation is not connected)" or ""))
    end

    local function begin_leg(t, goal, label, reach)
        local from = me()
        local mode, pts, why = plan(from, goal)
        if not mode then return false, why end
        local leg = { goal = goal, label = label, reach = reach, at = t, mode = mode, points = pts or { goal },
            idx = 1, best = -math.huge, best_at = t, unsticks = 0, start_pos = copy(from), replans = 0,
            started = false }
        -- A route is joined at its point nearest you.
        if mode == "route" then
            local near, near_d = 1, math.huge
            for i = 1, #leg.points do
                local d = dist(from, leg.points[i])
                if d < near_d then near, near_d = i, d end
            end
            leg.idx = near
        end
        run.leg = leg
        log("walking %s by %s (%.0f yards%s)", label, MODE_TEXT[mode], dist(from, goal),
            mode == "route" and string.format(", %d points", #leg.points) or "")
        return true
    end

    local function hold(t)
        local ok = ctx.input.acquire(ctx.input.CHANNEL.MOVEMENT, PRIORITY, "mail run")
        ok = ctx.input.acquire(ctx.input.CHANNEL.FACING, PRIORITY, "mail run") and ok
        return ok
    end

    --- One tick of a walk by facing and holding forward (a route or a line).
    local function step_direct(t, pos)
        local leg = run.leg
        local pts = leg.points
        while leg.idx < #pts and dist(pos, pts[leg.idx]) <= WAYPOINT do leg.idx = leg.idx + 1 end
        local wp = leg.idx < #pts and pts[leg.idx] or leg.goal
        local score = leg.idx * 1000 - dist(pos, wp)
        if score > leg.best + 0.5 then leg.best, leg.best_at = score, t end
        if not hold(t) then
            -- Something with a higher claim is moving or turning you: let go
            -- (never walk on blind, facing where it turned you) and wait.
            for _, key in ipairs({ "forward", "left", "right" }) do U.try(ctx.input.set_key, key, false) end
            leg.side = nil
            leg.best_at = t
            return
        end
        if leg.side then
            if t >= leg.side.until_t then
                ctx.input.set_key(leg.side.key, false)
                leg.side = nil
                leg.best_at = t
            end
            ctx.input.look_at(wp)
            ctx.input.set_key("forward", true)
            return
        end
        ctx.input.look_at(wp)
        ctx.input.set_key("forward", true)
        if t - leg.best_at > UNSTICK_AFTER then
            if leg.unsticks >= UNSTICKS then
                return fail("stuck " .. leg.label .. " (" .. MODE_TEXT[leg.mode] .. ")")
            end
            leg.unsticks = leg.unsticks + 1
            local key = leg.unsticks % 2 == 1 and "left" or "right"
            log("no progress %s: a jump and a sidestep %s (%d of %d)", leg.label, key, leg.unsticks, UNSTICKS)
            U.try(ctx.input.jump)
            ctx.input.set_key(key, true)
            leg.side = { key = key, until_t = t + SIDESTEP }
        end
    end

    --- Gives up on Sentinel for the session and walks on in a straight line
    --- (or stops when the goal is too far for one).
    local function drop_nav(t, pos, why)
        nav_dead = why
        log("Sentinel Navigation dropped: %s", why)
        U.try(ctx.nav.stop)
        local leg = run.leg
        if dist(pos, leg.goal) > LINE_MAX then
            return fail("Sentinel Navigation " .. why .. ", and " .. leg.label .. " is too far to walk straight")
        end
        leg.mode, leg.points, leg.idx, leg.best, leg.best_at = "line", { leg.goal }, 1, -math.huge, t
    end

    --- One tick of a walk by Sentinel.
    local function step_nav(t, pos)
        local leg = run.leg
        hold(t)
        if not leg.started then
            leg.started, leg.started_at = true, t
            leg_seq = leg_seq + 1
            local id = leg_seq
            leg.id = id
            local ok = ctx.nav.move_to(leg.goal, { priority = PRIORITY, reason = "mail run",
                on_done = function(done_ok, why)
                    if run and run.leg and run.leg.id == id and not done_ok then run.leg.why = why end
                end })
            log("Sentinel asked to walk %s: %s", leg.label, ok and "accepted" or "refused")
            if not ok then return drop_nav(t, pos, "would not start a route") end
            return
        end
        -- Proved within NAV_PROVE seconds, or dropped.
        if not leg.proved then
            if dist(pos, leg.start_pos) >= 1.0 then
                leg.proved = true
                log("Sentinel is moving you (state %s)", tostring(U.try(ctx.nav.state)))
            elseif t - leg.started_at >= NAV_PROVE then
                return drop_nav(t, pos, string.format("did not move you in %ds (state %s%s)", NAV_PROVE,
                    tostring(U.try(ctx.nav.state)), leg.why and (", " .. tostring(leg.why)) or ""))
            end
            return
        end
        local d = dist(pos, leg.goal)
        if -d > leg.best + 1 then leg.best, leg.best_at = -d, t end
        if not ctx.nav.is_moving() then
            return drop_nav(t, pos, "stopped short" .. (leg.why and (" (" .. tostring(leg.why) .. ")") or ""))
        end
        if t - leg.best_at > STALL then
            if leg.replans >= REPLANS then return drop_nav(t, pos, "made no progress") end
            leg.replans, leg.best_at = leg.replans + 1, t
            log("no progress %s on Sentinel: planning again (%d)", leg.label, leg.replans)
            U.try(ctx.nav.replan, "no progress")
        end
    end

    --- One tick of the walk under way. True on arrival (every key let go).
    local function walk(t, pos)
        local leg = run.leg
        if dist(pos, leg.goal) <= leg.reach then
            let_go()
            log("arrived %s (%.1f yards off) in %.0fs", leg.label, dist(pos, leg.goal), t - leg.at)
            return true
        end
        if t - leg.at > LEG_LIMIT then
            fail("took too long " .. leg.label .. " (" .. MODE_TEXT[leg.mode] .. ")")
            return false
        end
        if leg.mode == "nav" then step_nav(t, pos) else step_direct(t, pos) end
        return false
    end

    -- --- the run ---------------------------------------------------------------------

    --- Is the mail run allowed to move you (the checkbox)?
    local function walking_on() return M.cfg("mail_runs", false) == true end

    local function blocked()
        if not (M.cfg("enabled", true) and M.auto and M.auto.active()) then return "Auto is off" end
        if not walking_on() then return "mail runs switched off" end
        if ctx.player then
            if U.try(ctx.player.is_dead) or U.try(ctx.player.is_ghost) then return "dead" end
            if U.try(ctx.player.in_combat) then return "in combat" end
        end
        return nil
    end

    --- Is there something worth the walk?
    local function worth_it(t)
        local mw = T.mail_waiting()
        local seen = L.inbox_seen()
        local items = seen and (seen.items or 0) or 0
        local other = seen and (seen.other_money or 0) or 0
        if mw.total + other <= 0 and items <= 0 then return false, "nothing waiting in the mailbox" end
        local cap = M.policy.capital()
        local enough = math.max(MIN_WAIT_FLOOR, cap.capital * MIN_WAIT_SHARE)
        if mw.total >= enough then return true end
        if not last_run_at or t - last_run_at >= OLD_WAIT then return true end
        return false, string.format("%s waiting; fetched at %s, or after %s", U.money(mw.total + other),
            U.money(enough), U.ago(OLD_WAIT - (t - last_run_at)))
    end

    local function maybe_start(t)
        if t < next_look then return end
        next_look = t + LOOK_EVERY
        local b = blocked()
        if b then why_not = b return end
        if t < paused_until then why_not = "paused after the last run stopped" return end
        if last_run_at and t - last_run_at < RUN_GAP then why_not = "the last run was just now" return end
        if not A.is_open() then why_not = "starts from the auction house" return end
        if T.busy() or S.busy() or S.quick_busy() or A.pending() > 0 or A.locked() then
            why_not = "waiting for the auction house work to finish" return
        end
        if U.try(ctx.player and ctx.player.is_casting) then why_not = "casting" return end
        local ok, why = worth_it(t)
        if not ok then why_not = why return end
        if not home then why_not = "open the auction house once so it knows where you stand" return end
        local box = find_mailbox(MAX_DIST)
        if not box or not box.pos then why_not = "no mailbox within " .. MAX_DIST .. " yards" return end
        local mode, _, no_way = plan(me(), box.pos)
        if not mode then why_not = no_way return end
        why_not = nil
        run = { step = "to_mail", at = t, started = true, mailbox = box, gold0 = L.gold_now() }
        log("started: %s waiting, mailbox %.0f yards away", U.money(T.mail_waiting().total), box.dist)
        M.activity(string.format("Mail run: walking to the mailbox (%.0f yards, %s)%s", box.dist, MODE_TEXT[mode],
            T.mail_waiting().total > 0 and (", " .. U.money(T.mail_waiting().total) .. " waiting") or ""))
        local began, began_why = begin_leg(t, box.pos, "to the mailbox", REACH)
        if not began then return fail("no way to the mailbox: " .. tostring(began_why)) end
    end

    local function step(t)
        local b = blocked()
        if b then
            local no_pause = b == "Auto is off" or b == "mail runs switched off"
            return finish(false, "ended: " .. b, (not no_pause) and RUN_GAP or nil)
        end
        local pos = me()
        if not pos then return end
        if run.step == "to_mail" then
            if walk(t, pos) and run then
                run.step, run.tries, run.next_try = "open_mail", 0, t + SETTLE
            end
        elseif run.step == "open_mail" then
            if L.mailbox_open() then
                log("the mailbox opened")
                run.step, run.collect_at, run.asked_at = "collect", t, t
                L.collect()
                return
            end
            if t < run.next_try then return end
            if run.tries >= OPEN_TRIES then return fail("the mailbox would not open") end
            local obj = resolve(run.mailbox.guid)
            if not obj then return fail("the mailbox went out of sight") end
            if dist(pos, run.mailbox.pos) > REACH + 1 then
                run.step = "to_mail"
                local began, why = begin_leg(t, run.mailbox.pos, "to the mailbox", REACH)
                if not began then return fail("no way to the mailbox: " .. tostring(why)) end
                return
            end
            run.tries, run.next_try = run.tries + 1, t + OPEN_WAIT
            log("opening the mailbox (try %d)", run.tries)
            U.try(ctx.input.use_object, obj)
        elseif run.step == "collect" then
            local box = L.mailbox()
            -- Done once the inbox has been read and nothing takeable is left
            -- (a second at least: the ledger reads it twice a second).
            local done = L.mailbox_open() and box and not box.collecting and L.mail_pending() == 0
                and t - run.collect_at > 1.5
            if done or not L.mailbox_open() or t - run.collect_at > COLLECT_LIMIT then
                if box and (box.cod or 0) > 0 then
                    M.activity(string.format("Mail run: left %d COD mail(s) alone (taking one would pay for it)",
                        box.cod))
                end
                log("mail taken; walking back")
                run.step = "to_ah"
                local began, why = begin_leg(t, home.pos, "back to the auction house", HOME_REACH)
                if not began then return fail("no way back to the auction house: " .. tostring(why)) end
            elseif L.mailbox_open() and box and not box.collecting and L.mail_pending() > 0
                and t - (run.asked_at or 0) > 2 then
                run.asked_at = t
                L.collect()
            end
        elseif run.step == "to_ah" then
            local auctioneer = resolve(home.guid) or find_auctioneer(home.pos, 10)
            local near = auctioneer and dist(pos, ctx.units.position(auctioneer)) <= REACH
                and dist(pos, home.pos) <= HOME_REACH * 2
            if near or walk(t, pos) then
                if run then
                    let_go()
                    run.step, run.tries, run.next_try = "open_ah", 0, t + SETTLE
                end
            end
        elseif run.step == "open_ah" then
            if A.is_open() then
                local got = (L.gold_now() or 0) - (run.gold0 or 0)
                return finish(true, string.format("done in %ds%s; back at the auction house", math.floor(t - run.at),
                    got > 0 and (", " .. U.money(got) .. " collected") or ""))
            end
            if t < run.next_try then return end
            if run.tries >= OPEN_TRIES then return fail("the auction house would not open again") end
            local auctioneer = resolve(home.guid) or find_auctioneer(home.pos, 10)
            if not auctioneer then return fail("no auctioneer by the spot it left from") end
            home.guid = U.method(auctioneer, "get_guid") or home.guid
            local apos = copy(ctx.units.position(auctioneer))
            if dist(pos, apos) > REACH + 1 then
                run.step = "to_ah"
                local began, why = begin_leg(t, apos, "back to the auctioneer", REACH)
                if not began then return fail("no way back to the auctioneer: " .. tostring(why)) end
                return
            end
            run.tries, run.next_try = run.tries + 1, t + OPEN_WAIT
            log("opening the auction house (try %d)", run.tries)
            U.try(ctx.input.interact, auctioneer)
        end
    end

    ctx.tick(function()
        local t = core.time()
        if run then return step(t) end
        maybe_start(t)
    end, { interval = 0.1 })

    -- --- for the window and Auto ---------------------------------------------------------

    function E.running() return run ~= nil end

    --- Is walking switched on (the checkbox)?
    function E.walking_on() return walking_on() end

    --- One line: what the mail run is doing, or why it is not.
    function E.status()
        if run then
            local pos = me()
            local leg = run.leg
            local how = leg and (" by " .. MODE_TEXT[leg.mode]) or ""
            if run.step == "to_mail" or run.step == "to_ah" then
                return string.format("Mail run: walking %s%s (%.0f yards to go)", leg and leg.label or "",
                    how, (pos and leg) and dist(pos, leg.goal) or 0), "accent"
            elseif run.step == "open_mail" then return "Mail run: opening the mailbox", "accent"
            elseif run.step == "collect" then return "Mail run: taking the mail", "accent"
            else return "Mail run: opening the auction house", "accent" end
        end
        if not (M.auto and M.auto.active()) then return nil end
        if not walking_on() then
            return "Mail run off: walk to the mailbox yourself; Auto takes the mail when you open it", "text_dim"
        end
        local tail = last and string.format("  |  last run %s ago: %s", U.ago(core.time() - last.t), last.text) or ""
        if core.time() < paused_until then
            return "Mail run paused " .. U.ago(paused_until - core.time()) .. tail, "warning"
        end
        return "Mail run: " .. (why_not or "ready") .. tail, "text_dim"
    end

    --- The learned routes and the run log (for tests and the window).
    function E.routes() return saved.routes end
    function E.log() return saved.log end

    function E.stop()
        if run then finish(false, "stopped") end
    end

    return E
end

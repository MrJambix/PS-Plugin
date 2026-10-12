-- JCore / scheduler -- one native callback per phase, fanned out to everyone.
--
-- Depends on: util, log.
--
-- The core registers exactly ONE core.register_on_update_callback, ONE
-- register_on_render_callback and ONE register_on_pre_tick_callback, then
-- dispatches to every subscriber itself. Three things fall out of that which
-- you cannot get by letting each plugin register its own native callback:
--
--   1. Ordering is ours. Native callbacks fire in load order, which is an
--      accident of the file system. Here a job states its priority.
--   2. Throttling is ours. A job that only needs 10 Hz says so instead of
--      burning full frame rate and checking a timestamp itself.
--   3. Cost is attributable. Every job is timed, so the diagnostics page can
--      name the plugin that is eating the frame rather than leaving you to
--      bisect by unloading things one at a time.
--
-- Time base: core.time() is the wall clock the whole runtime schedules on.
-- core.game_time() pauses with the client and is therefore wrong for anything
-- that must keep running through a loading screen.

return function(rt)
    local util = rt.util
    local log = rt.log.for_tag("JCore/scheduler")
    -- Jobs and timers run through it: a plain pcall unless Jambix Debug listens
    -- (lib/faults, 1.8.1). A runtime built without it gets the plain pcall.
    local faults = rt.faults or rt.util.no_faults

    local M = {}

    -- core.cpu_time() answers NANOSECONDS. Every cost number this module
    -- reports is in milliseconds, so every delta goes through this factor.
    -- Getting it wrong is silent rather than loud: the budget comparison still
    -- runs, it just always trips, and every deferrable job is then dropped on
    -- every single frame.
    local NS_TO_MS = 1e-6

    local PHASES = {
        pre_tick = true,
        update = true,
        render = true,
        menu = true,
        control_panel = true,
    }

    -- phase -> array of jobs
    local jobs = {}
    for phase in pairs(PHASES) do jobs[phase] = {} end
    local dirty = {}

    -- Timers, kept in one flat array scanned on update.
    local timers = {}
    local next_timer_id = 1
    local next_job_id = 0

    --- Where in its cycle a timer or job runs, as a fraction in [0.2, 1.0].
    ---
    --- The golden ratio spreads consecutive ids as evenly as any sequence can:
    --- however many timers share an interval, no two land close together.
    --- Deterministic rather than random so a given build always schedules the
    --- same way, which is what makes a stutter reproducible.
    ---@param id integer
    ---@return number
    local function phase_for(id)
        local x = (id * 0.6180339887) % 1
        return 0.2 + 0.8 * x
    end

    -- Rolling per-phase cost, in milliseconds.
    local phase_cost = {}
    for phase in pairs(PHASES) do phase_cost[phase] = util.ring(120) end

    -- Soft budget for the update phase, in milliseconds. When a frame has
    -- already spent this much, jobs marked deferrable are skipped for the rest
    -- of that frame and run on the next one. Rotation and safety logic is never
    -- deferrable; drawing and telemetry is.
    local update_budget_ms = 8.0

    function M.set_update_budget(ms)
        update_budget_ms = math.max(1.0, ms or 8.0)
    end

    function M.get_update_budget()
        return update_budget_ms
    end

    ---@class jcore_job
    ---@field phase string
    ---@field fn function
    ---@field owner string
    ---@field priority number
    ---@field interval number  -- 0 = every frame
    ---@field deferrable boolean
    ---@field enabled boolean
    ---@field dead boolean
    ---@field last_run number
    ---@field cost table       -- ring buffer of ms samples

    --- Register a repeating job on a phase.
    ---
    ---@param phase "pre_tick"|"update"|"render"|"menu"|"control_panel"
    ---@param fn function
    ---@param opts? { owner?: string, priority?: number, interval?: number, deferrable?: boolean }
    ---@return jcore_job
    function M.add(phase, fn, opts)
        assert(PHASES[phase], "unknown scheduler phase: " .. tostring(phase))
        assert(type(fn) == "function", "job must be a function")
        opts = opts or {}

        local job = {
            phase      = phase,
            fn         = fn,
            owner      = opts.owner or "anonymous",
            priority   = opts.priority or 100,
            interval   = opts.interval or 0,
            deferrable = opts.deferrable and true or false,
            enabled    = true,
            dead       = false,
            -- Staggered for the same reason as timers: every job with a given
            -- interval was added during load, so last_run = 0 made them all
            -- due on the same first frame and kept them together from then on.
            last_run   = 0,
            cost       = util.ring(60),
            failures   = 0,
            suspended_until = 0,
        }
        next_job_id = next_job_id + 1
        if job.interval > 0 then
            -- First run at its own point in the cycle rather than immediately.
            job.last_run = core.time() - job.interval
                + job.interval * phase_for(next_job_id)
        end

        local list = jobs[phase]
        list[#list + 1] = job
        dirty[phase] = true
        return job
    end

    ---@param job jcore_job
    function M.remove(job)
        if type(job) ~= "table" or job.dead then return false end
        job.dead = true
        dirty[job.phase] = true
        return true
    end

    ---@param owner string
    ---@return integer removed
    function M.remove_owner(owner)
        local removed = 0
        for phase, list in pairs(jobs) do
            for i = 1, #list do
                local job = list[i]
                if not job.dead and job.owner == owner then
                    job.dead = true
                    removed = removed + 1
                    dirty[phase] = true
                end
            end
        end
        for i = #timers, 1, -1 do
            if timers[i].owner == owner then
                table.remove(timers, i)
                removed = removed + 1
            end
        end
        return removed
    end

    --- Enable or disable every job belonging to owner without removing them.
    --- This is how the registry pauses a plugin: its jobs stop running but its
    --- registrations survive, so re-enabling is free.
    function M.set_owner_enabled(owner, enabled)
        for _, list in pairs(jobs) do
            for i = 1, #list do
                local job = list[i]
                if job.owner == owner then job.enabled = enabled end
            end
        end
        for i = 1, #timers do
            if timers[i].owner == owner then timers[i].enabled = enabled end
        end
    end

    -- --- timers -------------------------------------------------------------

    --- Runs fn once, delay seconds from now.
    ---@param delay number seconds
    ---@param fn function
    ---@param owner? string
    ---@return integer timer_id
    function M.after(delay, fn, owner)
        local id = next_timer_id
        next_timer_id = id + 1
        timers[#timers + 1] = {
            id = id,
            fn = fn,
            owner = owner or "anonymous",
            due = core.time() + delay,
            repeating = false,
            enabled = true,
        }
        return id
    end

    --- Runs fn every interval seconds until cancelled.
    ---@param interval number seconds
    ---@param fn function
    ---@param owner? string
    ---@return integer timer_id
    function M.every(interval, fn, owner)
        assert(interval > 0, "timer interval must be > 0")
        local id = next_timer_id
        next_timer_id = id + 1
        local phase = phase_for(id)
        timers[#timers + 1] = {
            id = id,
            fn = fn,
            owner = owner or "anonymous",
            -- NOT now + interval. Every repeating timer is created during load,
            -- in the same frame, so "now + interval" put every five-second job
            -- on the same frame -- the bag scan, the talent scan, the quest
            -- index rebuild, the class check and the core housekeeping all
            -- together, every five seconds, and every ten-second job on top of
            -- them every other time. That was a periodic freeze by
            -- construction. Each timer now runs at its own point in the cycle.
            due = core.time() + interval * phase,
            interval = interval,
            phase = phase,
            repeating = true,
            enabled = true,
        }
        return id
    end

    ---@param timer_id integer
    function M.cancel(timer_id)
        for i = 1, #timers do
            if timers[i].id == timer_id then
                table.remove(timers, i)
                return true
            end
        end
        return false
    end

    -- A failing job gets this many consecutive tries before it is paused, then
    -- pauses that double from BACKOFF_BASE up to BACKOFF_MAX seconds.
    local FAIL_BEFORE_BACKOFF = 5
    local BACKOFF_BASE, BACKOFF_MAX = 2, 30

    local function run_timers(now)
        -- Reverse walk so an expired one-shot can be removed in place.
        for i = #timers, 1, -1 do
            local t = timers[i]
            if t.enabled and now >= t.due then
                local ok, err = faults.call("timer", t, t.fn)
                if not ok then
                    log.fmt("error", "timer from %s failed: %s", t.owner, tostring(err))
                end
                if t.repeating then
                    -- Advance from the due time, not from now, so a stalled
                    -- frame does not drift the whole schedule forward. Clamp to
                    -- now when we fell more than one interval behind, which
                    -- avoids a burst of catch-up calls after a loading screen.
                    t.due = t.due + t.interval
                    -- After a stall -- a loading screen is the usual one -- every
                    -- overdue timer lands here in the same frame. Clamping them
                    -- all to now + interval re-synchronised the whole schedule
                    -- after every zone change, undoing the spread above. Each
                    -- one goes back to its own phase instead.
                    if t.due < now then t.due = now + t.interval * (t.phase or 1) end
                else
                    table.remove(timers, i)
                end
            end
        end
    end

    -- --- dispatch -----------------------------------------------------------

    local function compact(phase)
        local list = jobs[phase]
        local out, n = {}, 0
        for i = 1, #list do
            if not list[i].dead then
                n = n + 1
                out[n] = list[i]
            end
        end
        util.stable_sort_by(out, function(j) return j.priority end)
        jobs[phase] = out
        dirty[phase] = nil
    end

    --- Runs one phase. A budget_ms above zero turns on deferral for that phase.
    ---@param phase string
    ---@param budget_ms? number
    function M.run_phase(phase, budget_ms)
        local list = jobs[phase]
        if not list then return end
        if dirty[phase] then
            compact(phase)
            list = jobs[phase]
        end
        if #list == 0 then return end

        local phase_start = core.cpu_time()
        local now = core.time()
        local deferred = 0

        for i = 1, #list do
            local job = list[i]
            if job.enabled and not job.dead then
                local due = job.interval == 0 or (now - job.last_run) >= job.interval

                if due and budget_ms and job.deferrable then
                    local spent = (core.cpu_time() - phase_start) * NS_TO_MS
                    if spent >= budget_ms then
                        deferred = deferred + 1
                        due = false
                    end
                end

                if due and job.suspended_until > now then due = false end

                if due then
                    job.last_run = now
                    local t0 = core.cpu_time()
                    local deep = faults.deep
                    if deep then faults.enter(job) end
                    local ok, err = faults.call("job", job, job.fn)
                    if deep then faults.leave(job) end
                    job.cost:push((core.cpu_time() - t0) * NS_TO_MS)
                    if ok then
                        job.failures = 0
                    else
                        -- A job that throws is re-run on the next frame, and the
                        -- one after, sixty times a second: the traceback string
                        -- is built, formatted and thrown away every frame for
                        -- as long as the bug lasts. That churn is its own
                        -- stutter, and the log limiter hides it rather than
                        -- stopping it. A found case: an ESP render job failing
                        -- on a %d format of a fractional health value, every
                        -- frame, indefinitely.
                        --
                        -- BACKED OFF, NOT SWITCHED OFF. A job that fails for a
                        -- few frames during a loading screen, when every object
                        -- is briefly invalid, must come back by itself -- a
                        -- permanent disable would let one transient error
                        -- silence the rotation for the whole session. So the
                        -- pause doubles each time and is capped, and a single
                        -- success resets it.
                        job.failures = job.failures + 1
                        if job.failures >= FAIL_BEFORE_BACKOFF then
                            local steps = job.failures - FAIL_BEFORE_BACKOFF
                            local pause = math.min(BACKOFF_MAX, BACKOFF_BASE * (2 ^ steps))
                            job.suspended_until = now + pause
                            log.fmt("error",
                                "%s job from %s keeps failing (%d in a row); pausing it %.0fs: %s",
                                phase, job.owner, job.failures, pause, tostring(err))
                        elseif job.failures == 1 then
                            log.fmt("error", "%s job from %s failed: %s",
                                phase, job.owner, tostring(err))
                        end
                    end
                end
            end
        end

        phase_cost[phase]:push((core.cpu_time() - phase_start) * NS_TO_MS)

        if deferred > 0 then
            log.fmt("debug", "deferred %d %s job(s) over the %.1fms budget", deferred, phase, budget_ms)
        end
    end

    --- Called by main.lua from the single native update callback.
    function M.on_update()
        run_timers(core.time())
        M.run_phase("update", update_budget_ms)
    end

    function M.on_pre_tick()
        M.run_phase("pre_tick")
    end

    function M.on_render()
        M.run_phase("render")
    end

    function M.on_render_menu()
        M.run_phase("menu")
    end

    function M.on_render_control_panel()
        M.run_phase("control_panel")
    end

    --- Whether any live job is registered on a phase. A pass with none runs
    --- nothing of any plugin's: Jambix Debug's black box leaves it unmarked.
    ---@param phase string
    ---@return boolean
    function M.has_jobs(phase)
        local list = jobs[phase]
        if not list then return false end
        for i = 1, #list do
            if not list[i].dead then return true end
        end
        return false
    end

    -- --- diagnostics --------------------------------------------------------

    --- Per-phase average and peak milliseconds over the sample window.
    function M.phase_stats()
        local out = {}
        for phase, ring in pairs(phase_cost) do
            out[phase] = { avg_ms = ring:avg(), max_ms = ring:max() }
        end
        return out
    end

    --- Cost per owner across every phase, heaviest first.
    function M.owner_stats()
        local by_owner = {}
        for phase, list in pairs(jobs) do
            for i = 1, #list do
                local job = list[i]
                if not job.dead then
                    local row = by_owner[job.owner]
                    if not row then
                        row = { owner = job.owner, avg_ms = 0, max_ms = 0, jobs = 0 }
                        by_owner[job.owner] = row
                    end
                    row.jobs = row.jobs + 1
                    row.avg_ms = row.avg_ms + job.cost:avg()
                    row.max_ms = math.max(row.max_ms, job.cost:max())
                    row[phase] = (row[phase] or 0) + job.cost:avg()
                end
            end
        end
        local rows = {}
        for _, row in pairs(by_owner) do rows[#rows + 1] = row end
        util.stable_sort_by(rows, function(r) return -r.avg_ms end)
        return rows
    end

    return M
end

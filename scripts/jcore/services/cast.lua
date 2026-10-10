-- JCore / cast -- one intent per GCD, arbitrated across every plugin.
--
-- Depends on: util, log, events, units, spells.
--
-- THE PROBLEM THIS SOLVES
-- Two plugins that both want to cast in the same global cooldown will both
-- push into the shared spell queue, and the queue will happily send both. The
-- second one lands a GCD later than its author expected, usually after the
-- state that justified it has gone. The classic symptom is an interrupt or a
-- defensive firing one beat late, and it is very hard to debug from inside
-- either plugin, because each one looks correct on its own.
--
-- So plugins do not queue. They REQUEST, every tick, describing what they want
-- and how badly. Once per tick, after every consumer has run, this module
-- picks the single best request and sends only that one. A request is valid
-- for exactly the tick that made it: nothing is remembered, nothing queues up
-- behind anything, and a plugin that stops asking stops being represented.
--
-- LANES
-- Off-GCD abilities do not compete with GCD abilities -- sending a trinket and
-- a rotational ability in the same tick is correct, not a conflict. They are
-- arbitrated separately, in the "fast" lane.
--
-- PRIORITY
-- Higher wins. The bands below are conventions, not enforcement, but plugins
-- that share them compose predictably without their authors having to talk to
-- each other.

return function(rt)
    local util = rt.util
    local events = rt.events
    local units = rt.units
    local spells = rt.spells
    local log = rt.log.for_tag("JCore/cast")

    local spell_queue
    do
        local ok, mod = pcall(require, "common/modules/spell_queue")
        if ok then spell_queue = mod end
    end

    -- The client's auto-attack helper: a START for Auto Shot (75), a wand's
    -- Shoot (5019) or the melee swing (6603) that is not a toggle. Cast as a
    -- spell, those three are toggles, and a second press is the off switch;
    -- started through this, a second start is a no-op. Optional: without it
    -- a direct request falls back to the spell cast.
    local auto_attack
    do
        local ok, mod = pcall(require, "common/utility/auto_attack_helper")
        if ok and type(mod) == "table" then auto_attack = mod end
    end

    --- Is this spell one of the auto attacks the helper can start?
    ---@param spell_id integer
    ---@return boolean
    local function is_auto_attack(spell_id)
        if not auto_attack or type(auto_attack.is_spell_auto_attack) ~= "function" then return false end
        local ok, yes = pcall(auto_attack.is_spell_auto_attack, auto_attack, spell_id)
        return ok and yes == true
    end

    local M = {}

    --- Whether a direct request for this spell is sent as an auto-attack
    --- START rather than a spell cast. For readouts and tests.
    M.is_auto_attack = is_auto_attack

    --- Suggested priority bands. A plugin should pick a band and vary within
    --- it, rather than inventing a number that outranks everything.
    M.PRIORITY = {
        IDLE      = 10,   -- flavour, out-of-combat upkeep
        FILLER    = 30,   -- the bottom of a rotation
        ROTATION  = 50,   -- normal rotational abilities
        COOLDOWN  = 70,   -- burst windows, on-use trinkets
        UTILITY   = 100,  -- dispels, taunts, purges
        INTERRUPT = 150,  -- kicks
        DEFENSIVE = 200,  -- damage reduction, self-heals under pressure
        EMERGENCY = 255,  -- last-stand buttons. Nothing should outrank these.
    }

    -- Requests made this tick, per lane.
    local pending = { gcd = {}, fast = {} }

    -- owner -> { until_time, reason } while a plugin holds the gate shut.
    local suppressions = {}

    -- spell_id -> time it was last actually sent, to swallow duplicates.
    local last_sent = {}

    -- Rolling record of what won, for the diagnostics page.
    local history = {}
    local HISTORY_MAX = 20

    local enabled = true

    --- Master switch. The core flips this off while the player is on a loading
    --- screen or dead, so nothing has to check those conditions itself.
    function M.set_enabled(state)
        enabled = state and true or false
    end

    function M.is_enabled()
        return enabled
    end

    -- --- suppression --------------------------------------------------------

    --- Holds the gate shut for `duration` seconds. Used by a plugin that is
    --- mid-sequence and must not be interleaved with -- a channel it is
    --- protecting, a cast it is setting up, a cinematic it is sitting through.
    ---
    --- Deliberately not a hard lock: EMERGENCY-band requests still get through,
    --- because a plugin holding the gate must never be able to stop a defensive
    --- from firing. A suppression is a strong preference, not a mutex.
    ---@param owner string
    ---@param duration number seconds
    ---@param reason? string
    function M.suppress(owner, duration, reason)
        suppressions[owner] = {
            until_time = core.time() + (duration or 0.5),
            reason = reason or "unspecified",
        }
        events.emit("jcore.cast.suppressed", owner, duration, reason)
    end

    ---@param owner string
    function M.release(owner)
        suppressions[owner] = nil
    end

    --- The active suppression, or nil. Expired entries are reaped here so the
    --- table cannot grow without bound.
    ---@return { owner: string, reason: string, remaining: number }|nil
    function M.active_suppression()
        local now = core.time()
        for owner, entry in pairs(suppressions) do
            if now >= entry.until_time then
                suppressions[owner] = nil
            else
                return { owner = owner, reason = entry.reason, remaining = entry.until_time - now }
            end
        end
        return nil
    end

    -- --- requests -----------------------------------------------------------

    ---@class jcore_cast_request
    ---@field spell_id integer
    ---@field target? game_object   Defaults to the player for a self-cast.
    ---@field position? vec3        For a ground-targeted spell.
    ---@field item_id? integer      Set instead of spell_id to use an item.
    ---@field priority number       See M.PRIORITY.
    ---@field reason? string        Shown in the cast log. Worth filling in.
    ---@field fast? boolean         Off-GCD; arbitrated in its own lane.
    ---@field direct? boolean       A one-shot toggle (Auto Shot, Shoot): sent to the client once, never queued.
    ---@field allow_movement? boolean
    ---@field owner? string         Filled in by the plugin context automatically.

    --- Ask to cast this tick. Returns true when the request was accepted into
    --- arbitration -- NOT that it will be sent. Losing arbitration is normal
    --- and is not an error.
    ---
    --- Call this every tick you want the spell. There is no state to clear.
    ---@param request jcore_cast_request
    ---@return boolean accepted
    function M.request(request)
        if not enabled then return false end
        if type(request) ~= "table" then return false end
        if not request.spell_id and not request.item_id then
            log.warn("cast request with neither spell_id nor item_id")
            return false
        end

        -- A priority that is not a number would throw in pick(), every tick,
        -- for every plugin's request.
        if type(request.priority) ~= "number" then request.priority = M.PRIORITY.ROTATION end
        request.owner = request.owner or "anonymous"

        local lane = request.fast and pending.fast or pending.gcd
        lane[#lane + 1] = request
        return true
    end

    -- --- arbitration --------------------------------------------------------

    local function describe(request)
        local what = request.item_id
            and ("item " .. request.item_id)
            or (spells.name(request.spell_id) ~= "" and spells.name(request.spell_id)
                or ("spell " .. request.spell_id))
        return string.format("%s (%s, p%d%s)", what, request.owner, request.priority,
            request.reason and (", " .. request.reason) or "")
    end

    --- Picks the winner from a lane. Highest priority wins; ties go to the
    --- request that was made first, which is registration order and therefore
    --- stable across frames.
    local function pick(lane, suppression)
        local best, best_priority = nil, -math.huge
        for i = 1, #lane do
            local request = lane[i]
            local eligible = true

            if suppression
                and request.owner ~= suppression.owner
                and request.priority < M.PRIORITY.EMERGENCY then
                eligible = false
            end

            if eligible and request.priority > best_priority then
                best, best_priority = request, request.priority
            end
        end
        return best
    end

    --- Sends a winning request into the shared spell queue.
    ---
    --- The spell queue's own priority is a different axis from ours: ours
    --- decides who wins this tick, the queue's decides ordering against
    --- anything the core itself has pending. Passing our band straight through
    --- keeps the two consistent.
    local function dispatch(request)
        if not spell_queue then
            log.once("error", "no_queue", "spell_queue module unavailable; cast requests cannot be sent")
            return false
        end

        local now = core.time()
        local key = request.item_id and ("i" .. request.item_id) or ("s" .. request.spell_id)

        -- Resending the same thing before the previous send has resolved just
        -- stacks duplicates in the queue. One round trip of latency is the
        -- right window: shorter and a legitimate re-cast gets eaten, longer and
        -- a genuinely repeatable instant feels sluggish.
        local ok_ping, ping = pcall(core.get_ping)
        local latency = util.clamp((ok_ping and tonumber(ping) or 0) / 1000.0, 0.05, 0.4)
        if last_sent[key] and (now - last_sent[key]) < latency then
            return false
        end

        local target = request.target or units.player()
        local priority = request.priority
        local message = request.reason or request.owner
        local ok = false

        -- A TOGGLE IS PRESSED ONCE. Auto Shot and a wand's Shoot start on one
        -- press and STOP on the next, and they report no cast to confirm
        -- against, so an entry left in the shared queue is a second press
        -- waiting to happen. A direct request goes to the client exactly
        -- once, and anything the queue still holds for it is purged first.
        if request.direct and request.spell_id and not request.position then
            pcall(spell_queue.purge_by_spell, spell_queue, request.spell_id)
            if is_auto_attack(request.spell_id) then
                -- A START, never a toggle: the helper's attack type is the
                -- auto attack's own spell id. Already running means nothing
                -- happens, which is the whole point. Never fall back to the
                -- spell cast here -- that would be the toggle again.
                ok = pcall(auto_attack.start_attack, auto_attack, target, request.spell_id)
            else
                ok = pcall(core.input.cast_target_spell, request.spell_id, target)
            end
        elseif request.item_id then
            if request.position then
                ok = pcall(spell_queue.queue_item_position, spell_queue,
                    request.item_id, request.position, priority, message)
            elseif request.fast then
                ok = pcall(spell_queue.queue_item_target_fast, spell_queue,
                    request.item_id, target, priority, message)
            else
                ok = pcall(spell_queue.queue_item_target, spell_queue,
                    request.item_id, target, priority, message, true)
            end
        elseif request.position then
            local fn = request.fast and spell_queue.queue_spell_position_fast
                or spell_queue.queue_spell_position
            ok = pcall(fn, spell_queue, request.spell_id, request.position, priority,
                message, request.allow_movement and true or false)
        else
            local fn = request.fast and spell_queue.queue_spell_target_fast
                or spell_queue.queue_spell_target
            ok = pcall(fn, spell_queue, request.spell_id, target, priority,
                message, request.allow_movement and true or false)
        end

        if not ok then
            log.fmt("error", "failed to queue %s", describe(request))
            return false
        end

        last_sent[key] = now

        history[#history + 1] = {
            time = now,
            owner = request.owner,
            spell_id = request.spell_id,
            item_id = request.item_id,
            priority = request.priority,
            reason = request.reason,
            fast = request.fast and true or false,
        }
        if #history > HISTORY_MAX then table.remove(history, 1) end

        log.fmt("debug", "sent %s", describe(request))
        events.emit("jcore.cast.sent", request)
        return true
    end

    --- Runs once per tick, last in the update phase.
    function M._arbitrate()
        local gcd_lane, fast_lane = pending.gcd, pending.fast

        if #gcd_lane == 0 and #fast_lane == 0 then return end

        -- Requests never survive the tick that made them, even when deciding
        -- between them throws: the lanes are handed out first and fresh ones
        -- take their place. Clearing them at the end, as before 1.5.3, left a
        -- throwing tick's requests queued -- re-decided next tick against a
        -- target that may have changed, one more per plugin per tick.
        pending.gcd, pending.fast = {}, {}

        local suppression = M.active_suppression()
        local player = units.player()

        if enabled and player and not player:is_dead() then
            -- The fast lane first: an off-GCD ability should land in the same
            -- tick as the GCD ability it is meant to buff, not after it.
            local fast_winner = pick(fast_lane, suppression)
            if fast_winner then dispatch(fast_winner) end

            local gcd_winner = pick(gcd_lane, suppression)
            if gcd_winner then
                local losers = #gcd_lane - 1
                if losers > 0 then
                    log.fmt("trace", "%s won over %d other request(s)",
                        describe(gcd_winner), losers)
                end
                dispatch(gcd_winner)
            end
        end

    end

    -- --- diagnostics --------------------------------------------------------

    --- Most recent sends, newest last.
    function M.history()
        return history
    end

    function M.stats()
        return {
            enabled     = enabled,
            pending_gcd = #pending.gcd,
            pending_fast = #pending.fast,
            suppressed_by = (M.active_suppression() or {}).owner,
            queue_available = spell_queue ~= nil,
        }
    end

    return M
end

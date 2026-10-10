-- Jambix AIO / actions -- the safety gate and the single-flight interaction queue.
--
-- EVERYTHING automated goes through here. Auto-loot and auto-gather do not
-- call core.input themselves; they submit a request and this module decides
-- whether, and when, it actually happens.
--
-- WHY A QUEUE AND NOT DIRECT CALLS
--
-- 1. The game accepts one interaction at a time. Two features each calling
--    use_object on the same frame means one of them is silently dropped, and
--    which one is a coin flip. Here exactly one request is in flight at a time.
--
-- 2. Interactions fail invisibly. loot_object answers true for "request
--    accepted", not "loot window opened"; interact_with_object explicitly
--    documents that its result means nothing. So the only honest way to tell
--    whether something worked is to look at the world afterwards, which needs
--    per-target state that individual callers should not each reinvent.
--
-- 3. A node you cannot reach, or lack the skill for, will fail forever. Left
--    alone that is an infinite retry loop that also blocks every other
--    interaction behind it. Failures are counted and the target is blacklisted.
--
-- SAFETY
-- The gate is deliberately conservative and checked immediately before the
-- call, not when the request was made. State changes between those two points
-- constantly -- you start moving, a cast begins -- and a check done at submit
-- time would be stale by the time it mattered.

return function(P)
    local ctx, log = P.ctx, P.log
    local units = P.units

    local M = {}

    -- guid -> { attempts, last_attempt, blacklisted_until }
    local attempts = {}

    local in_flight = nil     -- { guid, kind, at, target }
    local last_action_at = 0
    local last_block_reason = nil

    M.BLACKLIST_AFTER = 3
    M.BLACKLIST_SECONDS = 120

    -- WHAT EACH ATTEMPT DID (1.55.1). Where JCore's API recorder runs
    -- (world.client().recording: Forever), every attempt and what followed
    -- it go to the recorder trace as "auto-loot:" lines: the call, the
    -- distance, the attempt, then a loot window, the client's red text, or
    -- nothing within WATCH_FOR seconds, and the give-up after the third.
    -- The user, 2026-10-03: "the autoloot from corpses does not work" while
    -- the recorder had 63 loot_object calls and 17 windows right after them.
    -- Read live (1.60.0): the recorder is Jambix Debug's, which may attach
    -- after this module loads, and JCore then sets the flag on the same table.
    local client_flags = nil
    do
        local world = ctx and ctx.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        if ok and type(c) == "table" then client_flags = c end
    end
    local function recording() return client_flags ~= nil and client_flags.recording == true end
    local WATCH_FOR = 4.0
    local watching = nil      -- { guid, kind, label, at }

    local function trace(text)
        if recording() then pcall(ctx.emit, "jcore.recorder.trace", text) end
    end

    local function settle_watch(outcome)
        local w = watching
        if not w then return end
        watching = nil
        trace(string.format("auto-loot: %s %s: %s after %.1fs", w.kind, w.label, outcome, core.time() - w.at))
    end

    -- Where the recorder can run (Forever) or already does: the handlers only
    -- act while an attempt is watched, and one is watched only while recording.
    if client_flags and (client_flags.forever or client_flags.recording) and ctx.on then
        ctx.on("jcore.game_event.LOOT_OPENED", function(args)
            if not watching then return end
            local auto = type(args) == "table" and tostring(args[1]) or "?"
            settle_watch("loot window opened (auto-loot " .. auto .. ")")
        end)
        ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
            local w = watching
            if not w or type(args) ~= "table" or (core.time() - w.at) > WATCH_FOR then return end
            trace(string.format("auto-loot: %s %s: the client says %q", w.kind, w.label, tostring(args[2] or args[3])))
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_START", function(args)
            local w = watching
            if not w or type(args) ~= "table" or args[1] ~= "player" or w.kind == "loot" then return end
            settle_watch("cast started (" .. tostring(args[3]) .. ")")
        end)
        ctx.every(1.0, function()
            local w = watching
            if w and (core.time() - w.at) > WATCH_FOR then settle_watch("nothing opened") end
        end)
    end

    -- --- safety gate --------------------------------------------------------

    --- Why an interaction cannot happen right now, or nil when it can.
    ---
    --- Returns a reason string rather than a boolean so the debug page can
    --- show WHY nothing is happening. "Auto-loot does nothing" is the single
    --- most common complaint about a plugin like this and it is almost always
    --- one of these lines.
    ---
    --- `opts.ignore_channel` lets one interaction through during a channel.
    --- The only caller is fishing: the bobber has to be clicked WHILE the
    --- Fishing channel runs, so for it that check is the wrong question.
    ---@param opts? { ignore_channel?: boolean }
    ---@return string|nil reason
    function M.blocked_reason(opts)
        local player = units.player()
        if not player then return "no player (loading screen)" end
        if player:is_dead() then return "dead" end
        if player:is_ghost() then return "ghost" end

        if P.opt("safe_casting", true) then
            if player:is_casting_spell() then return "casting" end
            if player:is_channelling_spell()
                and not (opts and opts.ignore_channel) then
                return "channelling"
            end
        end

        if P.opt("safe_moving", true) and player:is_moving() then
            return "moving"
        end

        if P.opt("safe_mounted", true) and player:is_mounted() then
            return "mounted"
        end

        if P.opt("safe_combat", true) and player:is_in_combat() then
            return "in combat"
        end

        -- An open loot window swallows the next interaction. Waiting for it to
        -- close is what makes a chain of corpses work instead of stalling on
        -- the second one.
        local ok, count = pcall(core.game_ui.get_loot_item_count)
        if ok and count and count > 0 then return "loot window open" end

        if core.is_textbox_focused and core.is_textbox_focused() then
            return "typing"
        end

        return nil
    end

    ---@return boolean
    function M.can_interact()
        return M.blocked_reason() == nil
    end

    function M.last_block()
        return last_block_reason
    end

    -- --- per-target bookkeeping ---------------------------------------------

    local function record(guid)
        local row = attempts[guid]
        if not row then
            row = { attempts = 0, last_attempt = 0, blacklisted_until = 0 }
            attempts[guid] = row
        end
        return row
    end

    ---@param guid string
    ---@return boolean
    function M.is_blacklisted(guid)
        local row = attempts[guid]
        if not row then return false end
        return row.blacklisted_until > core.time()
    end

    --- Forget a target completely. Called on success, and by the debug page's
    --- reset button.
    ---@param guid string
    function M.forget(guid)
        attempts[guid] = nil
    end

    function M.reset()
        attempts = {}
        in_flight = nil
    end

    -- --- a success is not a failure (1.55.3) ---------------------------------
    --
    -- The three-attempt blacklist counted EVERY attempt, and a vein is mined
    -- several times: the user, 2026-10-03, "the automated Mining only does it
    -- 2 times instead of until it's depleted". The trace: attempt 1 started
    -- the Mining cast, attempt 2 landed between the cast ending and the loot
    -- window ("That is already being used."), attempt 3 came with the window,
    -- and the vein was given up on for two minutes, not yet empty. Now what an
    -- attempt brings -- a loot window, or the player starting a cast (mining,
    -- herbing, skinning, opening) within SUCCESS_WITHIN seconds, counted once
    -- per attempt -- clears that target's failures and lifts its blacklist,
    -- so it is worked until it is gone from the world. MAX_OPENS successes on
    -- one target end it anyway (bags full: the window opens and nothing
    -- leaves it). And a gathering cast that finishes holds the next press for
    -- HOLD_AFTER_CAST, until its loot window has had time to open.
    local SUCCESS_WITHIN = 6.0
    local MAX_OPENS = 6
    local HOLD_AFTER_CAST = 1.2
    local last_try = nil      -- { guid, kind, label, at, ok }: the latest attempt
    local hold_until = 0

    local function recent(cast)
        local t = last_try
        if not t or (core.time() - t.at) > SUCCESS_WITHIN then return nil end
        if cast and t.kind ~= "use" and t.kind ~= "skin" then return nil end
        return t
    end

    local function succeeded(cast)
        local t = recent(cast)
        if not t or t.ok then return end
        t.ok = true
        local row = attempts[t.guid]
        if not row then return end
        row.opens = (row.opens or 0) + 1
        if row.opens >= MAX_OPENS then
            row.blacklisted_until = core.time() + M.BLACKLIST_SECONDS
            log.fmt("debug", "done with %s after %d openings", tostring(t.guid), row.opens)
            trace(string.format("auto-loot: done with %s %s for %ds after %d openings",
                tostring(t.label or "?"), tostring(t.guid):sub(-10), M.BLACKLIST_SECONDS, row.opens))
            return
        end
        row.attempts = 0
        row.blacklisted_until = 0
    end

    if ctx and ctx.on then
        ctx.on("jcore.game_event.LOOT_OPENED", function(args)
            if type(args) == "table" and args[2] == true then return end
            succeeded(false)
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_START", function(args)
            if type(args) == "table" and args[1] == "player" then succeeded(true) end
        end)
        ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
            if type(args) ~= "table" or args[1] ~= "player" then return end
            if recent(true) then hold_until = core.time() + HOLD_AFTER_CAST end
        end)
    end

    --- True when this target is ready for another attempt: not blacklisted,
    --- and its retry delay has elapsed.
    ---@param guid string
    ---@return boolean
    function M.is_ready(guid)
        if M.is_blacklisted(guid) then return false end
        local row = attempts[guid]
        if not row then return true end
        return (core.time() - row.last_attempt) >= P.opt("retry_delay", 1.0)
    end

    -- --- dispatch -----------------------------------------------------------

    --- Attempts one interaction now.
    ---
    --- `kind` selects the native call, and the three are NOT interchangeable:
    --- loot_object rejects anything that is not a unit, and use_object is the
    --- only one that opens a herb node, an ore vein or a chest. Picking the
    --- wrong one fails silently, which is exactly the sort of bug the retry
    --- counter below would otherwise hide behind a blacklist.
    ---
    ---@param target game_object
    ---@param kind "loot"|"use"|"skin"|"interact"
    ---@param label? string
    ---@param opts? { ignore_channel?: boolean }
    ---@return boolean dispatched what the native call answered
    ---@return boolean|nil attempted true when the call was made at all,
    --- whatever it answered: use_object answers false on Forever even when the
    --- window opens (1.66.1, fishing)
    function M.perform(target, kind, label, opts)
        if not target or not target:is_valid() then return false end

        local reason = M.blocked_reason(opts)
        if reason then
            last_block_reason = reason
            return false
        end
        last_block_reason = nil

        -- A corpse attempt still walking or waiting on its window (JCore says
        -- so on Forever, 1.55.2): no second press on top of it.
        local opener = (kind == "loot" or kind == "skin") and ctx.loot or nil
        if opener and opener.opening then
            local ok_o, waiting = pcall(opener.opening)
            if ok_o and waiting then return false end
        end

        local guid = target:get_guid()
        if not guid then return false end
        if not M.is_ready(guid) then return false end

        -- Global pacing. Even when everything else is ready, firing an
        -- interaction on consecutive frames just produces dropped requests.
        local now = core.time()
        if (now - last_action_at) < P.opt("action_interval", 0.35) then
            return false
        end
        if now < hold_until then return false end

        local row = record(guid)
        row.attempts = row.attempts + 1
        row.last_attempt = now
        last_action_at = now

        local ok = false
        if opener and opener.open then
            -- JCore opens it the way that works on this client: on Era
            -- loot_object / skin_object as always; on Forever the call it
            -- learned (loot_object first since JCore 1.6.2, pressed once and
            -- waited on; the interact only if that brings nothing).
            ok = select(2, pcall(opener.open, target, kind)) == true
        elseif kind == "loot" then
            ok = select(2, pcall(core.input.loot_object, target, true)) == true
        elseif kind == "use" then
            ok = select(2, pcall(core.input.use_object, target)) == true
        elseif kind == "skin" then
            ok = select(2, pcall(core.input.skin_object, target)) == true
        else
            ok = select(2, pcall(core.input.interact_with_object, target)) == true
        end

        in_flight = { guid = guid, kind = kind, at = now, target = target }
        last_try = { guid = guid, kind = kind, label = label, at = now }

        if recording() then
            if watching then settle_watch("nothing opened before the next attempt") end
            local d = units and units.distance and units.distance(target) or nil
            local who = string.format("%s %s", tostring(label or "?"), tostring(guid):sub(-10))
            trace(string.format("auto-loot: %s %s at %s yd, attempt %d of %d, accepted=%s",
                kind, who, d and string.format("%.1f", d) or "?", row.attempts, M.BLACKLIST_AFTER, tostring(ok)))
            watching = { guid = guid, kind = kind, label = who, at = now }
        end

        if row.attempts >= M.BLACKLIST_AFTER then
            row.blacklisted_until = now + M.BLACKLIST_SECONDS
            log.fmt("debug", "giving up on %s after %d attempts",
                label or guid, row.attempts)
            trace(string.format("auto-loot: giving up on %s %s for %ds after %d attempts",
                tostring(label or "?"), tostring(guid):sub(-10), M.BLACKLIST_SECONDS, row.attempts))
        end

        log.fmt("trace", "%s -> %s (attempt %d, dispatched=%s)",
            kind, label or guid, row.attempts, tostring(ok))

        ctx.emit("jambix.aio.interact", {
            guid = guid, kind = kind, label = label,
            attempt = row.attempts, dispatched = ok,
        })

        return ok, true
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local tracked, blacklisted = 0, 0
        local now = core.time()
        for _, row in pairs(attempts) do
            tracked = tracked + 1
            if row.blacklisted_until > now then blacklisted = blacklisted + 1 end
        end
        return {
            tracked = tracked,
            blacklisted = blacklisted,
            blocked_by = last_block_reason,
            last_action = last_action_at > 0 and (now - last_action_at) or -1,
            in_flight = in_flight and in_flight.guid or nil,
        }
    end

    --- Reap bookkeeping for targets that are long gone, so a long farming
    --- session does not accumulate a row per corpse it ever looted.
    ctx.every(30.0, function()
        local now = core.time()
        for guid, row in pairs(attempts) do
            local expired = row.blacklisted_until > 0 and row.blacklisted_until < now
            local stale = (now - row.last_attempt) > 300
            if expired or stale then attempts[guid] = nil end
        end
    end)

    return M
end

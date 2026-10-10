-- Jambix Market / presence -- not going Away while Auto trades.
--
-- The user (2026-10-07): "Anti AFK where it wont go 'afk' status". The
-- client marks you Away after about five minutes without input, and logs you
-- out about half an hour after that. What resets its idle clock is input
-- through the client's input path (the .api, at core.input.clear_afk, which
-- itself only clears the flag and is no use). On Forever a jump alone did
-- not reset it (Jambix AIO's fishing, 1.67.1), and whether a turn does was
-- never seen. So while Auto is on, a keep-alive goes out every KEEP_EVERY
-- seconds, of the first kind that has not been shown to fail:
--
--   turn   a turn a tenth of a second each way (the facing ends where it was)
--   step   a sidestep a tenth of a second left, then right (left and right
--          strafe at the same speed, so it ends where it began, and it never
--          touches the forward key: walking forward and backpedalling do not,
--          and drifted an idle character about 11 yards an hour; the review,
--          1.1.0)
--   jump   a jump
--
-- Away is the system message "You are now Away" (recorded on Forever,
-- 2026-10-07). It says which kinds work:
--   * A keep-alive that resets the clock holds Away off for five minutes,
--     and they go out every two. So Away less than five minutes after one
--     means that kind does not reset it.
--   * Away with no keep-alive in the five minutes before (Auto just
--     started, after you had been idle) says nothing of the kind.
-- A kind that failed is dropped for good (scripts_data/jcore/
-- jambix.market.presence.json) and the next is tried at once, no more than
-- one answer a minute (an answer takes the Away off, and a failing one would
-- otherwise flip it back and forth). A kind with no Away for HOLD_FOR is
-- recorded as holding. When every kind has failed, keep-alives stop and the
-- window says so: on this client the game's idle clock does not see the
-- loader's input, and only your own keyboard or mouse keeps you in.
--
-- Never while you type, while dead, in combat, while something else holds
-- the character's movement (a mail run walking, a rotation), or with the
-- auction house busy buying (a keep-alive waits its turn).

return function(M)
    local ctx, U = M.ctx, M.util

    local Pr = {}

    local KEEP_EVERY = 120          -- s: well inside the five minutes
    local ECHO = 30                 -- s after a keep-alive: an Away then is its failure
    local IDLE_LIMIT = 300          -- s: the client's idle clock
    local ANSWER_GAP = 60           -- s between keep-alives sent because of an Away
    local HOLD_FOR = 15 * 60        -- s with no Away: the kind holds
    local TAP = 0.12                -- s for each half of a turn or a step
    local PRIORITY = 10             -- the lowest: anything else moving goes first

    local KINDS = { "turn", "step", "jump" }
    local LABEL = { turn = "a short turn each way", step = "a short sidestep each way", jump = "a jump" }

    local store = ctx.store("presence")
    local data = store:all()
    data.failed = type(data.failed) == "table" and data.failed or {}
    data.held = type(data.held) == "table" and data.held or {}

    local st = {
        sent_at = nil,              -- the last keep-alive
        first_at = nil,             -- the first keep-alive of the kind in use, this streak
        kind = nil,                 -- the kind in use
        away = false, away_at = nil,
        answered_at = nil,          -- the last keep-alive sent because of an Away
        seq = nil,                  -- a turn or step under way: { kind, phase, at }
        sent = 0,
        note = nil,                 -- the last thing worth saying
    }

    local function current_kind()
        for i = 1, #KINDS do
            if not data.failed[KINDS[i]] then return KINDS[i] end
        end
        return nil
    end

    local function active()
        return M.cfg("enabled", true) and M.auto and M.auto.active()
    end

    local function can_send()
        if U.try(ctx.input.is_typing) then return false end
        if ctx.player then
            if U.try(ctx.player.is_dead) or U.try(ctx.player.is_ghost) then return false end
            if U.try(ctx.player.in_combat) then return false end
        end
        if M.errands and M.errands.running() then return false end
        return true
    end

    local function release()
        U.try(ctx.input.set_key, "turn_left", false)
        U.try(ctx.input.set_key, "turn_right", false)
        U.try(ctx.input.set_key, "left", false)
        U.try(ctx.input.set_key, "right", false)
        U.try(ctx.input.release, ctx.input.CHANNEL.MOVEMENT)
    end

    --- Sends one keep-alive of the kind in use. True when it went out.
    local function send(t, why)
        local kind = current_kind()
        if not kind then return false end
        if kind ~= st.kind then st.kind, st.first_at = kind, nil end
        if kind == "jump" then
            U.try(ctx.input.jump)
        else
            if not ctx.input.acquire(ctx.input.CHANNEL.MOVEMENT, PRIORITY, "staying active") then return false end
            local first = kind == "turn" and "turn_left" or "left"
            ctx.input.set_key(first, true)
            st.seq = { kind = kind, phase = 1, at = t }
        end
        st.sent_at = t
        st.first_at = st.first_at or t
        st.sent = st.sent + 1
        M.debug("presence: keep-alive (%s)%s", kind, why and (" -- " .. why) or "")
        return true
    end

    --- The second half of a turn or a step, then letting go.
    local function seq_tick(t)
        local s = st.seq
        if not s then return end
        ctx.input.acquire(ctx.input.CHANNEL.MOVEMENT, PRIORITY, "staying active")
        if s.phase == 1 and t - s.at >= TAP then
            if s.kind == "turn" then
                ctx.input.set_key("turn_left", false)
                ctx.input.set_key("turn_right", true)
            else
                ctx.input.set_key("left", false)
                ctx.input.set_key("right", true)
            end
            s.phase, s.at = 2, t
        elseif s.phase == 2 and t - s.at >= TAP then
            release()
            st.seq = nil
        end
    end

    local function fail_kind(kind, why)
        if not kind or data.failed[kind] then return end
        data.failed[kind] = why
        data.held[kind] = nil
        store:touch()
        local next_kind = current_kind()
        st.kind, st.first_at = next_kind, nil
        if next_kind then
            st.note = string.format("%s did not keep you active (%s); trying %s", LABEL[kind], why, LABEL[next_kind])
            M.activity("Staying active: " .. st.note)
        else
            st.note = "none of the keep-alives kept you active: on this client the game's idle clock does not see "
                .. "the loader's input, so only your own keyboard or mouse keeps you in"
            M.activity("Staying active gave up: " .. st.note)
            M.toast("Anti-AFK: the game marks you Away whatever the plugin sends", "warning")
        end
    end

    -- Away and back, from the system messages.
    ctx.on("jcore.game_event.CHAT_MSG_SYSTEM", function(args)
        local text = args and args[1]
        if type(text) ~= "string" then return end
        if text:find("^You are now Away") or text:find("^You are now AFK") then
            local t = core.time()
            st.away, st.away_at = true, t
            if not active() then return end
            -- A keep-alive that reset the clock holds Away off five minutes:
            -- Away sooner than that after one means it did not.
            local kind = st.kind
            if kind and st.sent_at and t - st.sent_at < IDLE_LIMIT then
                fail_kind(kind, t - st.sent_at <= ECHO and "Away came back right after it"
                    or "Away came anyway")
            end
            -- Answered at once (the move takes the Away off), once a minute at most.
            if not st.answered_at or t - st.answered_at >= ANSWER_GAP then
                if can_send() and send(t, "Away") then st.answered_at = t end
            end
        elseif text:find("^You are no longer Away") or text:find("^You are no longer AFK") then
            st.away = false
        end
    end)

    ctx.tick(function()
        local t = core.time()
        if st.seq then return seq_tick(t) end
        if not active() then
            st.first_at = nil
            return
        end
        local kind = current_kind()
        if not kind then return end
        -- Held long enough without an Away: on record.
        if st.kind == kind and st.first_at and t - st.first_at >= HOLD_FOR and not data.held[kind]
            and not (st.away_at and st.away_at > st.first_at) then
            data.held[kind] = true
            store:touch()
            M.activity("Staying active: " .. LABEL[kind] .. " every 2 minutes is keeping you active")
        end
        if (not st.sent_at or t - st.sent_at >= KEEP_EVERY) and can_send() then send(t) end
    end, { interval = 0.05 })

    --- One line for the window.
    function Pr.status()
        if not active() then return nil end
        local kind = current_kind()
        if not kind then return "Anti-AFK gave up: " .. (st.note or "every keep-alive failed"), "warning" end
        local held = data.held[kind]
        local line = string.format("Anti-AFK: %s every %d min%s", LABEL[kind], KEEP_EVERY / 60,
            held and " (keeps you active)" or (st.sent > 0 and " (finding out whether it keeps you active)" or ""))
        if st.away then line = line .. "  |  Away right now" end
        if st.note and not held then line = line .. "  |  " .. st.note end
        return line, st.away and "warning" or "text_dim"
    end

    function Pr.state()
        return { kind = current_kind(), failed = data.failed, held = data.held, away = st.away, sent = st.sent,
            sent_at = st.sent_at }
    end

    --- Forgets what was learned (a new loader may answer differently).
    function Pr.reset()
        data.failed, data.held = {}, {}
        store:touch()
        st.kind, st.first_at, st.note = nil, nil, nil
    end

    return Pr
end

-- Jambix AIO / fishing -- cast, watch the bobber, click on a bite, loot, repeat.
--
-- ONE LOOP, FIVE STATES
--
--   idle      nothing in flight; casts when the gate allows it
--   casting   the cast was issued; waiting for the channel to start
--   waiting   channelling; looking for our bobber and for a bite on it
--   hooked    the bobber was clicked; waiting for the loot window
--   looting   the window is open; taking what the filter allows
--
-- Every state has a timeout. A step that does not happen -- the cast was
-- refused, the bobber never showed up, the loot window never opened -- drops
-- back to idle instead of waiting forever, and a run of refused casts turns
-- the whole thing off with the reason, rather than casting into a wall all
-- night.
--
-- WHICH BOBBER IS OURS
-- The shipped fish helper's test -- a basic object, no health, created by the
-- local player -- also matches a campfire or a hunter trap. So the guids of
-- everything the player already owned are taken when the cast goes out, and
-- only an object that appeared AFTER it counts. That is locale-independent,
-- unlike matching the name "Fishing Bobber".
--
-- THE BOBBER CLICK GOES THROUGH modules/actions.lua like every other
-- interaction, with one exemption: it happens DURING the fishing channel, so
-- the "never while channelling" safety check has to let this one through.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, actions = P.units, P.actions

    local M = {}

    local fish_helper
    do
        local ok, mod = pcall(require, "common/utility/fish_helper")
        if ok and type(mod) == "table" then fish_helper = mod end
    end

    M.LOOT_EVERYTHING = 1
    M.LOOT_GOLD_ONLY = 2
    M.LOOT_WHITELIST = 3
    M.LOOT_BLACKLIST = 4
    M.LOOT_MODES = {
        "Everything",
        "Gold only",
        "Only the item ids below",
        "Everything except the item ids below",
    }

    -- How long each state may last before it is given up on.
    local CAST_START_TIMEOUT = 2.5
    local BOBBER_TIMEOUT = 4.0
    local LOOT_OPEN_TIMEOUT = 2.5
    local LOOT_SETTLE = 0.25       -- the window is empty on the frame it opens
    local MAX_FAILED_CASTS = 4

    local state = "idle"
    local state_since = 0
    local next_cast_at = 0
    local react_at = nil           -- when a seen bite is clicked
    local failed_casts = 0
    local stop_reason = nil

    local owned_before = {}        -- guid -> true, what we owned before the cast
    local bobber = nil
    local bobber_guid = nil
    local channel_id = nil

    local session = {
        casts = 0, catches = 0, misses = 0, empty = 0,
        started = 0, last_loot = nil,
    }

    local function set_state(next_state)
        state = next_state
        state_since = core.time()
    end

    --- A delay with some spread, so the timings are not a metronome.
    ---@param base number seconds
    ---@return number
    local function jittered(base)
        return base * (0.7 + math.random() * 0.6)
    end

    -- What the click brought (1.66.1). See "A CATCH IS A LOOT WINDOW" below.
    local clicked_at = nil         -- when the bobber was last clicked
    local opened_at = nil          -- when a loot window opened for this cast
    local opened_names = nil       -- what was in it as it opened
    local loot_closed = false      -- and it has closed again
    local bags_full = nil          -- the game's "Inventory is full" after a click

    local function reset_cast()
        bobber, bobber_guid, channel_id, react_at = nil, nil, nil, nil
        opened_at, opened_names, loot_closed = nil, nil, false
        owned_before = {}
    end

    local function finish(outcome)
        if outcome == "miss" then session.misses = session.misses + 1 end
        reset_cast()
        next_cast_at = core.time() + jittered(P.opt("fish_recast_delay", 1.2))
        set_state("idle")
    end

    -- --- identification -----------------------------------------------------

    ---@param obj game_object
    ---@return string|nil guid of whoever created it
    local function creator_guid(obj)
        local ok, creator = pcall(obj.get_creator_object, obj)
        if not ok or not creator then return nil end
        local ok_valid, valid = pcall(creator.is_valid, creator)
        if not ok_valid or not valid then return nil end
        local ok_guid, guid = pcall(creator.get_guid, creator)
        return ok_guid and guid or nil
    end

    --- Every object the player currently owns, by guid.
    local function snapshot_owned(player_guid)
        local owned = {}
        local list = units.objects()
        for i = 1, #list do
            local obj = list[i]
            if creator_guid(obj) == player_guid then
                local guid = obj:get_guid()
                if guid then owned[guid] = true end
            end
        end
        return owned
    end

    --- Our bobber: player-created, appeared after the cast, and shaped like
    --- one (a basic object with no health pool).
    local function find_bobber(player_guid)
        local list = units.objects()
        for i = 1, #list do
            local obj = list[i]
            local guid = obj:get_guid()
            if guid and not owned_before[guid]
                and creator_guid(obj) == player_guid then
                local ok_basic, basic = pcall(obj.is_basic_object, obj)
                local ok_hp, max_hp = pcall(obj.get_max_health, obj)
                if ok_basic and basic and (not ok_hp or (max_hp or 0) == 0) then
                    return obj, guid
                end
            end
        end
        return nil
    end

    --- The native bite flag first; the helper's cached animation time as the
    --- fallback for a build where the native one never answers true.
    local function has_bite(obj)
        local ok, bite = pcall(obj.does_bobber_have_fish, obj)
        if ok and bite then return true end
        if fish_helper then
            local ok_h, bite_h = pcall(fish_helper.does_bobber_have_fish, fish_helper, obj)
            if ok_h and bite_h then return true end
        end
        return false
    end

    -- --- loot filter --------------------------------------------------------

    local parsed_ids, parsed_from = {}, nil

    --- The item id list, re-parsed only when the text changes.
    local function item_ids()
        local text = P.opt("fish_item_ids", "") or ""
        if text ~= parsed_from then
            parsed_ids, parsed_from = {}, text
            for token in tostring(text):gmatch("%d+") do
                parsed_ids[tonumber(token)] = true
            end
        end
        return parsed_ids
    end

    ---@param index integer 0 based loot slot
    ---@return boolean
    local function wants_slot(index)
        local mode = P.opt("fish_loot_mode", M.LOOT_EVERYTHING)
        local ok_gold, is_gold = pcall(core.game_ui.get_loot_is_gold, index)
        is_gold = ok_gold and is_gold

        if mode == M.LOOT_GOLD_ONLY then return is_gold end
        if mode == M.LOOT_EVERYTHING then return true end
        if is_gold then return true end

        local ok_id, item_id = pcall(core.game_ui.get_loot_item_id, index)
        if not ok_id or not item_id or item_id == 0 then return false end

        local listed = item_ids()[item_id] == true
        if mode == M.LOOT_WHITELIST then return listed end
        return not listed
    end

    --- One catch, counted once, whoever emptied the window. Not when the
    --- game said the bags were full: then the fish stayed in the water.
    ---@param names string[]|nil
    local function caught(names, taken, slots)
        if bags_full then return end
        session.catches = session.catches + 1
        if names and #names > 0 then session.last_loot = table.concat(names, ", ") end
        ctx.emit("jambix.aio.fishing.catch", { taken = taken, slots = slots, names = names or {} })
    end

    --- Takes what the filter allows and closes the window, so the actions gate
    --- -- which waits on an open loot window -- is free for the next cast.
    ---@param count integer
    local function loot_window(count)
        local taken, names = 0, {}
        for index = 0, count - 1 do
            if wants_slot(index) then
                -- The name first: a looted slot reads empty.
                local ok, name = pcall(core.game_ui.get_loot_item_name, index)
                pcall(core.input.loot_item, index)
                taken = taken + 1
                if ok and type(name) == "string" and name ~= "" then
                    names[#names + 1] = name
                end
            end
        end
        if taken < count or P.opt("fish_close_loot", true) then
            pcall(core.input.close_loot)
        end

        caught(names, taken, count)
        log.fmt("debug", "fishing: looted %d of %d slot(s)%s", taken, count,
            #names > 0 and (" -- " .. table.concat(names, ", ")) or "")
    end

    -- --- the cast ------------------------------------------------------------
    --
    -- THE RANK THE PLAYER HAS (1.61.0). core.profession.open_profession casts
    -- the Apprentice rank by its fixed id (7620; the .api says so). Once
    -- Journeyman Fishing (75-150) is learned the spellbook holds that rank
    -- instead, the cast never starts, and after MAX_FAILED_CASTS refused casts
    -- fishing switched itself off. Players: "does it not fish after u learn
    -- 75-150? It worked fine from 0-75". So a higher classic rank the player
    -- knows is cast by its id, whatever the client's language. Anything else
    -- keeps the call that always worked.
    --
    -- NOT BY NAME (1.61.1). 1.61.0 also took whatever the spellbook called
    -- Fishing. On Forever the book holds two: the classic 7620 and Forever's
    -- own 1240948, the highest id won, and casting 1240948 by id starts
    -- nothing -- nine casts, no channel, fishing switched off, below 75 too.
    --
    -- NEVER THE PROFESSION CALL ABOVE APPRENTICE (1.65.2). The user, on
    -- Forever: "Spell not learned for Fishing Journeyman". 1.61.1 also handed
    -- over to the profession call for the rest of the session after ONE cast
    -- by id that started no channel (not facing water, say). But training
    -- Journeyman takes Apprentice out of the book -- the Forever dump after
    -- it holds 7731 and Forever's own 1240959, no 7620 -- so that call can
    -- only be refused: "Spell not learned" on every cast until four of them
    -- switched fishing off. Now a rank cast that starts nothing counts like
    -- any failed cast and the next cast is by id again. The profession call
    -- is only for Apprentice, or when no rank is found.
    local FISHING_RANKS = { 18248, 7732, 7731 }     -- Artisan, Expert, Journeyman
    local last_cast = nil                           -- what was cast, for the trace

    local function known(id)
        local spells = ctx.spells
        if spells and spells.learned then return (spells.learned(id)) == true end
        local ok, yes = pcall(core.spell_book.is_spell_known, id)
        return ok and yes == true
    end

    --- The Fishing to cast by id: a classic rank above Apprentice, or nil for
    --- the profession call.
    local function fishing_rank()
        for i = 1, #FISHING_RANKS do
            if known(FISHING_RANKS[i]) then return FISHING_RANKS[i] end
        end
        return nil
    end
    M.fishing_rank = fishing_rank

    local function trace(text)
        pcall(ctx.emit, "jcore.recorder.trace", text)
    end

    -- The client's red text while a cast is starting, so a refused cast says
    -- why, in the trace and in the stop reason. The event does not say which
    -- spell it is about; inside this window it is almost always ours.
    local refusal = nil
    local refusal_until = 0

    -- A CATCH IS A LOOT WINDOW (1.66.1). The user, on Forever: "its also
    -- counting catches as got away". The trace: "use fishing bobber ...
    -- accepted=false", then "loot window opened (auto-loot true) after
    -- 0.4s". use_object answers false there every time (197 of 214 calls in
    -- the recording), so the loop never went to "hooked"; the catch ended
    -- the channel and that read as a fish that got away. And with the game's
    -- own auto-loot on, the window can open and empty between two ticks.
    -- Now a click is a click whatever the call answered, and a window that
    -- opens after it is the catch, read as it opens.
    --
    -- AND "STOP WHEN BAGS ARE FULL" TAKES THE GAME'S WORD (1.66.1). The
    -- free-slot count was stale on Forever (JCore 1.8.2 fixes it), and the
    -- recording has 80 "Inventory is full" refusals. That red text within
    -- FULL_WITHIN seconds of a click stops fishing, whatever the count says.
    local CATCH_SETTLE = 0.5       -- s: an open window read empty this long is emptied
    local FULL_WITHIN = 5.0        -- s after a click

    ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
        if type(args) ~= "table" then return end
        local now = core.time()
        local text = args[2] or args[3]
        local full = args[3] == "ERR_INV_FULL"
            or (type(text) == "string" and text:find("^Inventory is full") ~= nil)
        if full and clicked_at and now - clicked_at <= FULL_WITHIN
            and P.opt("fish_stop_full", true) then
            bags_full = tostring(text or "Inventory is full")
        end
        if now > refusal_until then return end
        if text ~= nil then refusal = tostring(text) end
    end)

    ctx.on("jcore.game_event.LOOT_OPENED", function()
        if not (state == "hooked" or (state == "waiting" and react_at)) then return end
        opened_at, loot_closed = core.time(), false
        local names = {}
        local ok, count = pcall(core.game_ui.get_loot_item_count)
        for index = 0, ((ok and tonumber(count)) or 0) - 1 do
            local ok_n, name = pcall(core.game_ui.get_loot_item_name, index)
            if ok_n and type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        opened_names = names
    end)

    ctx.on("jcore.game_event.LOOT_CLOSED", function()
        if opened_at then loot_closed = true end
    end)

    ---@return boolean issued
    local function cast_fishing(player)
        local id = fishing_rank()
        refusal, refusal_until = nil, core.time() + CAST_START_TIMEOUT
        if id then
            last_cast = "Fishing " .. id
            if not (core.input and core.input.cast_target_spell) then return false end
            local ok, issued = pcall(core.input.cast_target_spell, id, player)
            return (ok and issued) and true or false
        end
        last_cast = "the profession call (Apprentice Fishing)"
        local ok, issued = pcall(core.profession.open_profession, core.profession.FISHING)
        return ok and issued == true
    end

    -- --- gate ---------------------------------------------------------------

    --- Why a new cast cannot go out right now, or nil. Moving, mounting and
    --- combat are not optional here: each cancels the channel anyway.
    ---@return string|nil
    local function cast_blocked()
        local player = units.player()
        if not player then return "no player" end
        if player:is_dead() or player:is_ghost() then return "dead" end
        if player:is_in_combat() then return "in combat" end
        if player:is_mounted() then return "mounted" end
        if player:is_moving() then return "moving" end
        if player:is_casting_spell() or player:is_channelling_spell() then
            return "busy casting"
        end
        local ok, count = pcall(core.game_ui.get_loot_item_count)
        if ok and count and count > 0 then return "loot window open" end
        if P.opt("fish_stop_full", true) and ctx.inventory
            and ctx.inventory.is_full() then
            return "bags full"
        end
        return nil
    end

    local last_block = nil

    -- --- the loop -----------------------------------------------------------

    local function enabled()
        return P.master_on() and P.opt("fish_enabled", false) and not stop_reason
    end

    -- --- staying active (1.61.2, 1.67.1, 1.7.5) ------------------------------
    --
    -- The user, 2026-10-04: "while fishing I can go AFK/Away status, which
    -- means bad news". The client marks a player Away after about five
    -- minutes without input, and logs them out after about thirty. The loop's
    -- own calls do not count on Forever: the cast is core.profession's, and a
    -- session of casts and bobber clicks still went Away. core.input.clear_afk
    -- only clears the flag, which the client raises again on its next tick
    -- (the .api); what resets the idle clock is input through the input path.
    --
    -- 1.61.2 jumped between casts, and 1.67.1 found the jump never reached the
    -- idle clock. The user, on Forever: "the jumps arnt keeping the bot from
    -- going away. So then it finally gets marked away and just spam jumps.
    -- Chat just says 'you are away' 'you are no longer away' 30 times. If I
    -- babysit and move its fine".
    --
    -- JAMBIX MARKET'S KEEP-ALIVE (1.7.5). The user, 2026-10-09: "change
    -- finishs anti afk from jumping to the one marketplace uses". So this is
    -- Jambix Market's modules/presence.lua, between casts. Every KEEP_EVERY
    -- seconds a keep-alive goes out, of the first kind not shown to fail:
    --
    --   turn   turn left TAP seconds, then right as long, through JCore's
    --          movement lease (ctx.input.set_key); then the facing taken
    --          before is looked at again, so the bobber lands where it did
    --   step   a sidestep left, then right as long (left and right strafe at
    --          the same speed, so it ends where it began)
    --   jump   a jump; the next cast waits JUMP_SETTLE for the landing
    --
    -- Away is the system message "You are now Away" (recorded on Forever by
    -- Jambix Market, 2026-10-07); PLAYER_FLAGS_CHANGED, which 1.67.1 read,
    -- fires for Away coming off too and needed the echo rules. It says which
    -- kinds work:
    --   * a keep-alive that resets the clock holds Away off for five minutes,
    --     so Away less than IDLE_LIMIT after one means its kind does not;
    --   * a keep-alive sent while Away that has not taken it off ECHO seconds
    --     later failed too (a move always took it off, 1.67.1). Market has no
    --     such rule, and without it a kind that neither clears nor resets
    --     would be sent for ever while the logout clock ran;
    --   * Away with no keep-alive in the five minutes before (fishing just
    --     started, after you had been idle) says nothing of the kind.
    -- A kind that failed is dropped for good (scripts_data/jcore/
    -- jambix.aio.presence.json) and the next one answers the Away at the next
    -- gap, no more than one answer a minute. A kind with no Away for HOLD_FOR
    -- is recorded as holding. When every kind has failed, keep-alives stop and
    -- the Fishing page says so. Switching "Stay active" off and on forgets
    -- what was learned. Never while you type: the keys would not wait.
    local KEEP_EVERY = 120          -- s: well inside the five minutes
    local ECHO = 30                 -- s after a keep-alive: an Away then is its failure
    local IDLE_LIMIT = 300          -- s: the client's idle clock
    local ANSWER_GAP = 60           -- s between keep-alives sent because of an Away
    local HOLD_FOR = 15 * 60        -- s with no Away: the kind holds
    local TAP = 0.12                -- s for the first half of a turn or a step
    local JUMP_SETTLE = 1.5         -- s: a cast in the air is refused
    local PRIORITY = 10             -- the lowest: anything else moving goes first
    local LEASE = "staying active"

    local KINDS = { "turn", "step", "jump" }
    local LABEL = { turn = "a short turn each way", step = "a short sidestep each way", jump = "a jump" }

    local store = ctx.store and ctx.store("presence") or nil
    local learned = store and store.data or {}
    learned.failed = type(learned.failed) == "table" and learned.failed or {}
    learned.held = type(learned.held) == "table" and learned.held or {}
    local function remember() if store then store:touch() end end

    local keep = {
        sent_at = nil,              -- the last keep-alive
        first_at = nil,             -- the first keep-alive of the kind in use, this streak
        kind = nil,                 -- the kind in use
        away = false, away_at = nil,
        owed = false,               -- an Away not answered yet
        answered_at = nil,          -- the last keep-alive sent because of an Away
        judged = nil,               -- sent_at of the last keep-alive judged for staying Away
        seq = nil,                  -- a turn or step under way
        sent = 0,
        note = nil,                 -- the last thing worth saying
        switch_was = nil,           -- "Stay active" as last seen; off to on forgets
    }

    local function current_kind()
        for i = 1, #KINDS do
            if not learned.failed[KINDS[i]] then return KINDS[i] end
        end
        return nil
    end

    local function keeping()
        return enabled() and P.opt("fish_stay_active", true)
    end

    local function fail_kind(kind, why)
        if not kind or learned.failed[kind] then return end
        learned.failed[kind] = why
        learned.held[kind] = nil
        remember()
        local next_kind = current_kind()
        keep.kind, keep.first_at = next_kind, nil
        if next_kind then
            keep.note = string.format("%s did not keep you active (%s); trying %s",
                LABEL[kind], why, LABEL[next_kind])
            log.info("fishing: " .. keep.note)
        else
            keep.note = "none of the keep-alives kept you active: the game's idle clock does not see "
                .. "the loader's input, so only your own keyboard or mouse keeps you in"
            log.info("fishing: stopped staying active -- " .. keep.note)
        end
        trace("fishing: stay active: " .. keep.note)
    end

    -- Away and back, from the system messages.
    ctx.on("jcore.game_event.CHAT_MSG_SYSTEM", function(args)
        local text = type(args) == "table" and args[1]
        if type(text) ~= "string" then return end
        if text:find("^You are now Away") or text:find("^You are now AFK") then
            local now = core.time()
            keep.away, keep.away_at = true, now
            if not keeping() then return end
            -- A keep-alive that reset the clock holds Away off five minutes:
            -- Away sooner than that after one means it did not.
            if keep.kind and keep.sent_at and now - keep.sent_at < IDLE_LIMIT then
                fail_kind(keep.kind, now - keep.sent_at <= ECHO and "Away came back right after it"
                    or "Away came anyway")
            end
            keep.owed = true
        elseif text:find("^You are no longer Away") or text:find("^You are no longer AFK") then
            keep.away = false
        end
    end)

    --- A point ten yards along the player's facing, to look at again after a
    --- turn. get_direction answers on Forever, get_rotation elsewhere
    --- (esp/forever.lua); a zero vector or a rotation of exactly 0 is "not
    --- answered", as there. nil when neither answers.
    local function point_ahead(player)
        local ok, point = pcall(function()
            local pos = player:get_position()
            local dx, dy
            local got, d = pcall(player.get_direction, player)
            if got and d and type(d.x) == "number" and type(d.y) == "number" and (d.x ~= 0 or d.y ~= 0) then
                dx, dy = d.x, d.y
            else
                local r = tonumber(player:get_rotation())
                if not r or r ~= r or r == 0 then return nil end
                dx, dy = math.cos(r), math.sin(r)
            end
            local len = math.sqrt(dx * dx + dy * dy)
            return { x = pos.x + dx / len * 10, y = pos.y + dy / len * 10, z = pos.z }
        end)
        return ok and point or nil
    end

    local function release_keys()
        local input = ctx.input
        for _, key in ipairs({ "turn_left", "turn_right", "left", "right" }) do
            pcall(input.set_key, key, false)
        end
        pcall(input.release, input.CHANNEL.MOVEMENT)
    end

    --- Sends one keep-alive of the kind in use. True when it went out.
    local function send(now, player, why)
        local input = ctx.input
        local kind = current_kind()
        if not (kind and type(input) == "table") then return false end
        local typing_ok, typing = pcall(input.is_typing)
        if typing_ok and typing then return false end
        if kind ~= keep.kind then keep.kind, keep.first_at = kind, nil end
        if kind == "jump" then
            if not pcall(input.jump) then return false end
            next_cast_at = now + JUMP_SETTLE
        else
            local ok, granted = pcall(input.acquire, input.CHANNEL.MOVEMENT, PRIORITY, LEASE)
            if not (ok and granted) then return false end
            keep.seq = { kind = kind, phase = 1, at = now,
                ahead = kind == "turn" and point_ahead(player) or nil }
            input.set_key(kind == "turn" and "turn_left" or "left", true)
        end
        keep.sent_at = now
        keep.first_at = keep.first_at or now
        keep.sent = keep.sent + 1
        trace(string.format("fishing: keep-alive (%s)%s", kind, why and (" -- " .. why) or ""))
        return true
    end

    --- The second half of a turn or a step, then letting go. A lease taken
    --- by anything else ends it: JCore let go of the keys for us then.
    local function seq_tick(now)
        local s, input = keep.seq, ctx.input
        if not input.acquire(input.CHANNEL.MOVEMENT, PRIORITY, LEASE) then
            keep.seq = nil
            return
        end
        if s.phase == 1 and now - s.at >= TAP then
            input.set_key(s.kind == "turn" and "turn_left" or "left", false)
            input.set_key(s.kind == "turn" and "turn_right" or "right", true)
            s.phase, s.held, s.at = 2, now - s.at, now
        elseif s.phase == 2 and now - s.at >= s.held then
            release_keys()
            if s.ahead and input.acquire(input.CHANNEL.FACING, PRIORITY, LEASE) then
                input.look_at(s.ahead)
                input.release(input.CHANNEL.FACING)
            end
            keep.seq = nil
        end
    end

    --- A keep-alive, when it is time. True when one went out: the cast waits.
    local function stay_active(now, player)
        if not P.opt("fish_stay_active", true) then return false end
        local kind = current_kind()
        if not kind then return false end
        -- Sent while Away, and Away still on: it did not even take it off.
        if keep.away and keep.sent_at and keep.away_at and keep.away_at < keep.sent_at
            and now - keep.sent_at >= ECHO and keep.judged ~= keep.sent_at then
            keep.judged = keep.sent_at
            fail_kind(keep.kind, "Away stayed on")
            keep.owed = true
            kind = current_kind()
            if not kind then return false end
        end
        -- Held long enough without an Away: on record.
        if keep.kind == kind and keep.first_at and now - keep.first_at >= HOLD_FOR and not learned.held[kind]
            and not (keep.away_at and keep.away_at > keep.first_at) then
            learned.held[kind] = true
            remember()
            log.info("fishing: " .. LABEL[kind] .. " every 2 minutes is keeping you active")
        end
        local answer = keep.owed and not (keep.answered_at and now - keep.answered_at < ANSWER_GAP)
        if not answer and keep.sent_at and now - keep.sent_at < KEEP_EVERY then return false end
        if not send(now, player, answer and "Away" or nil) then return false end
        if keep.owed then keep.owed, keep.answered_at = false, now end
        return true
    end

    local function tick()
        -- A keep-alive's turn or step finishes first, fishing on or off: it
        -- holds a key down.
        if keep.seq then return seq_tick(core.time()) end
        -- The game said the bags are full (1.66.1): stop before anything else.
        if bags_full and not stop_reason then
            stop_reason = "bags full -- the game said: " .. bags_full
            log.info("fishing stopped: bags are full")
            trace(string.format("fishing: stopped, the game said %q after a catch", bags_full))
        end
        local switch = P.opt("fish_stay_active", true) and true or false
        if switch and keep.switch_was == false then M.reset_presence() end
        keep.switch_was = switch
        if not keeping() then keep.first_at = nil end
        if not enabled() then
            if state ~= "idle" then reset_cast(); set_state("idle") end
            return
        end

        local player = units.player()
        if not player then return end
        local player_guid = player:get_guid()
        local now = core.time()
        local elapsed = now - state_since

        if state == "idle" then
            if now < next_cast_at then return end
            last_block = cast_blocked()
            if last_block then
                -- Bags filling up is the one block that will not clear on its
                -- own; say so once and stop instead of re-checking forever.
                if last_block == "bags full" then
                    stop_reason = "bags full"
                    log.info("fishing stopped: bags are full")
                    trace("fishing: stopped before a cast, no bag slot free")
                end
                return
            end
            if stay_active(now, player) then return end

            owned_before = snapshot_owned(player_guid)
            if not cast_fishing(player) then
                failed_casts = failed_casts + 1
                next_cast_at = now + 2.0
                trace(string.format("fishing: %s was not issued (%d in a row)", tostring(last_cast), failed_casts))
            else
                session.casts = session.casts + 1
                if session.started == 0 then session.started = now end
                set_state("casting")
            end

        elseif state == "casting" then
            if player:is_channelling_spell() then
                local ok, id = pcall(player.get_active_channel_spell_id, player)
                channel_id = ok and id or nil
                failed_casts = 0
                set_state("waiting")
            elseif elapsed > CAST_START_TIMEOUT then
                -- No channel: no pole, no water in front, not trained, or
                -- interrupted. Repeated, it will not fix itself.
                failed_casts = failed_casts + 1
                local why = refusal and string.format(": the client says %q", refusal) or ""
                log.fmt("debug", "fishing: cast did not start (%d in a row)%s", failed_casts, why)
                trace(string.format("fishing: %s started no channel (%d in a row)%s",
                    tostring(last_cast), failed_casts, why))
                finish(nil)
            end

        elseif state == "waiting" then
            local still_fishing = player:is_channelling_spell()
            if still_fishing and channel_id then
                local ok, id = pcall(player.get_active_channel_spell_id, player)
                still_fishing = ok and id == channel_id
            end

            if not bobber or not bobber:is_valid() then
                bobber, bobber_guid = find_bobber(player_guid)
                if not bobber and elapsed > BOBBER_TIMEOUT then
                    log.debug("fishing: no bobber found for this cast")
                    finish("miss")
                    return
                end
            end

            if opened_at then
                -- A window opened for a click: that is a catch.
                set_state("hooked")
                return
            end

            if not still_fishing then
                -- The channel ran out (or was broken) with nothing clicked.
                finish("miss")
                return
            end

            if bobber and has_bite(bobber) then
                if not react_at then
                    react_at = now + jittered(P.opt("fish_reaction", 0.6))
                elseif now >= react_at then
                    -- Hooked once the click went out, whatever the call
                    -- answered (1.66.1).
                    local _, tried = actions.perform(bobber, "use", "fishing bobber",
                        { ignore_channel = true })
                    if tried then
                        clicked_at = now
                        set_state("hooked")
                    end
                end
            end

        elseif state == "hooked" then
            local ok, count = pcall(core.game_ui.get_loot_item_count)
            if ok and count and count > 0 then
                opened_at = opened_at or now
                set_state("looting")
            elseif opened_at and (loot_closed or now - opened_at > CATCH_SETTLE) then
                -- The window opened and is empty already: the game's own
                -- auto-loot took the catch between two ticks.
                caught(opened_names)
                if bobber_guid then actions.forget(bobber_guid) end
                finish(nil)
            elseif elapsed > LOOT_OPEN_TIMEOUT then
                -- No window: the click missed, or came too late. The channel
                -- tells which.
                if player:is_channelling_spell() then
                    set_state("waiting")
                else
                    session.empty = session.empty + 1
                    finish(nil)
                end
            end

        elseif state == "looting" then
            if elapsed < LOOT_SETTLE then return end
            local ok, count = pcall(core.game_ui.get_loot_item_count)
            if ok and count and count > 0 then
                loot_window(count)
            else
                caught(opened_names)        -- emptied by the game's auto-loot
            end
            if bobber_guid then actions.forget(bobber_guid) end
            finish(nil)
        end

        if failed_casts >= MAX_FAILED_CASTS then
            stop_reason = refusal and ("the cast keeps failing -- the client says: " .. refusal)
                or "the cast keeps failing -- pole equipped, facing water?"
            log.info("fishing stopped: " .. stop_reason)
            failed_casts = 0
        end
    end

    ctx.tick(tick, { interval = 0.1 })

    --- Turning the toggle back on is how the player says the reason for the
    --- last stop has been dealt with.
    function M.on_toggle()
        stop_reason = nil
        refusal = nil
        bags_full = nil
        failed_casts = 0
        next_cast_at = 0
        reset_cast()
        set_state("idle")
    end

    function M.reset_session()
        session = {
            casts = 0, catches = 0, misses = 0, empty = 0,
            started = 0, last_loot = nil,
        }
    end

    --- Forgets which keep-alives failed or held (1.7.5): "Stay active"
    --- switched back on is how the player asks for another try.
    function M.reset_presence()
        learned.failed, learned.held = {}, {}
        remember()
        keep.kind, keep.first_at, keep.note, keep.owed, keep.judged = nil, nil, nil, false, nil
    end

    --- What the keep-alive knows (1.7.5): the kind in use (nil once every
    --- kind failed), what failed and why, what held, and whether Away is on.
    function M.presence()
        return { kind = current_kind(), failed = learned.failed, held = learned.held,
            away = keep.away, sent = keep.sent, sent_at = keep.sent_at, note = keep.note }
    end

    ---@return boolean
    function M.active()
        return enabled() and state ~= "idle"
    end

    --- The cast in flight, read-only (1.89.0, for the world marks' ring on the
    --- bobber and its splash, modules/nodememory.lua): the bobber, its guid,
    --- and whether a bite has been seen on it. Nothing while none is out.
    ---@return game_object|nil, string|nil, boolean|nil
    function M.bobber()
        if not bobber then return nil end
        return bobber, bobber_guid, react_at ~= nil
    end

    --- The loop's bite read (the native flag, then the fish helper's), for a
    --- bobber cast by hand (1.89.0). Reads only.
    M.has_bite = has_bite

    function M.stats()
        local minutes = session.started > 0 and (core.time() - session.started) / 60 or 0
        return {
            state = state,
            stopped = stop_reason,
            blocked = last_block,
            casts = session.casts,
            catches = session.catches,
            misses = session.misses,
            empty = session.empty,
            per_hour = minutes > 1 and (session.catches / minutes * 60) or nil,
            minutes = minutes,
            last_loot = session.last_loot,
            helper = fish_helper ~= nil,
            away_anyway = not current_kind() and (keep.note or "every keep-alive failed") or nil,
        }
    end

    --- Lines for the Fishing page's live readout.
    function M.status_lines()
        local s = M.stats()
        local out = {}
        if not P.master_on() then
            out[1] = "Off -- the master switch on the overview page is off."
            return out
        end
        if not P.opt("fish_enabled", false) then
            out[1] = "Off."
        elseif s.stopped then
            out[1] = "STOPPED: " .. s.stopped .. "  (toggle off and on to resume)"
        elseif s.state == "idle" and s.blocked then
            out[1] = "Waiting: " .. s.blocked
        else
            out[1] = "Fishing: " .. s.state
        end
        out[#out + 1] = string.format("Casts %d   catches %d   got away %d%s",
            s.casts, s.catches, s.misses,
            s.per_hour and string.format("   %.0f / hour", s.per_hour) or "")
        out[#out + 1] = "Last catch: " .. (s.last_loot or "-")
        if P.opt("fish_stay_active", true) then
            local kind = current_kind()
            if not kind then
                out[#out + 1] = "Anti-AFK gave up: the game marks you Away anyway. Move now and then."
            elseif P.opt("fish_enabled", false) then
                local line = string.format("Anti-AFK: %s every %d min%s", LABEL[kind], KEEP_EVERY / 60,
                    learned.held[kind] and " (keeps you active)"
                    or (keep.sent > 0 and " (finding out whether it works)" or ""))
                if keep.away then line = line .. "  |  Away right now" end
                out[#out + 1] = line
            end
        end
        return out
    end

    return M
end

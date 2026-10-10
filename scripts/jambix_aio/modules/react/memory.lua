-- Jambix AIO / react / memory -- what was just done, and what came of it.
--
-- THE BUG SHAPE THIS EXISTS FOR
--   Mend Pet -> Mend Pet -> Mend Pet
--   Hunter's Mark -> switch -> Hunter's Mark -> switch -> Hunter's Mark
-- Each press was right against the frame it was decided on, and wrong against
-- the one before it. A rule that sees only the present cannot tell "the pet
-- is low" from "the pet is low AND I started healing it half a second ago".
-- So every action is remembered from the moment it is asked for until the
-- game says what happened to it, and an event that has been dealt with is
-- remembered as dealt with until its result has had time to show.
--
-- LIFECYCLE OF AN ATTEMPT
--   requested  we asked the cast arbiter (or the pet, or the bag)
--   sent       the arbiter dispatched it          (jcore.cast.sent)
--   ok         the client confirmed it            (UNIT_SPELLCAST_SUCCEEDED)
--   failed     the client refused it              (UNIT_SPELLCAST_FAILED, UI_ERROR_MESSAGE)
--   lost       never sent: it lost arbitration. Not a failure of the action.
--   unknown    sent, and neither answer came back. Only a failure for a spell
--              whose confirmations we have seen before -- otherwise silence is
--              the client not telling us, which is not the spell's fault.
--
-- Nothing here reads the game. It is fed by init.lua's event handlers and by
-- the engine, which is what lets the tests drive it with a scripted clock.

return function(clock, name_of)
    local M = {}

    local huge = math.huge

    -- --- tuning -------------------------------------------------------------

    local KEEP_ROWS = 48              -- attempts remembered, newest last
    local LOST_AFTER = 0.35           -- requested and never sent: lost arbitration
    local CONFIRM_SLACK = 1.5         -- beyond the cast time, before "unknown"
    local FAIL_WINDOW = 6.0           -- failures counted over this long
    local BACKOFF_BASE = 1.5          -- seconds, doubled per failure past the first
    local BACKOFF_MAX = 4.0           -- never longer than this: a silent rotation is worse
    local TRAIL_SPAN = 10.0           -- target changes remembered
    local HP_SPAN = 4.0               -- health samples remembered
    local HP_EVERY = 0.1

    M.BACKOFF_MAX = BACKOFF_MAX

    -- --- state --------------------------------------------------------------

    local rows = {}                   -- attempts, oldest first
    local names = {}                  -- name -> per-ability record
    local id_names = {}               -- spell id -> name, learned from attempts
    local handled = {}                -- event key -> { at, until_at, note }
    local applied = {}                -- name -> { guid, at }
    local trail = {}                  -- { t, guid } target changes
    local last_target = false         -- guid, nil, or false before the first read
    local hp = {}                     -- { t, hp }
    local states = {}                 -- name -> { value, since }
    local channel = nil               -- { id, since } while the client says we channel

    M.last_attempt, M.last_sent, M.last_success, M.last_failure = nil, nil, nil, nil

    --- Names of one-per-caster debuffs; init.lua fills it (R.unique).
    M.unique = {}

    -- WHICH REFUSALS MEAN ANYTHING. The client's red error text fires all the
    -- time for things that fix themselves a moment later -- "spell is not
    -- ready yet" and "another action is in progress" with every queued press,
    -- "not enough mana" while it regenerates. Counting those as failures held
    -- the rotation's own spells back for seconds at a time: a character
    -- standing still. Only a refusal that will still be true on the next
    -- press counts -- out of range, not facing, no line of sight, too close,
    -- the wrong target, immune.
    local PERSISTENT = {
        "OUT_OF_RANGE", "INFRONT", "FACING", "LINE_OF_SIGHT", "TOO_CLOSE",
        "BAD_TARGET", "BAD_IMPLICIT", "IMMUNE", "NOT_BEHIND", "TARGETS_DEAD",
        "ATTACKPOS", "TARGET_FRIENDLY", "TARGET_ENEMY", "NO_AMMO",
    }

    --- Is this UI error id one that will repeat on the next press?
    ---@param id string|nil the client's string id (UI_ERROR_MESSAGE args[3])
    ---@return boolean
    function M.persistent_error(id)
        if type(id) ~= "string" then return false end
        local up = id:upper()
        for i = 1, #PERSISTENT do
            if up:find(PERSISTENT[i], 1, true) then return true end
        end
        return false
    end

    local function record(name)
        local r = names[name]
        if not r then
            r = {
                attempt_at = -huge, sent_at = -huge, success_at = -huge, failure_at = -huge,
                failures = {},        -- times, newest last
                backoff_until = 0,
                confirmed = false,    -- a confirmation for this name has been read
                last_why = nil,
            }
            names[name] = r
        end
        return r
    end

    local function resolve(spell_id)
        if not spell_id then return nil end
        local name = id_names[spell_id]
        if name then return name end
        if name_of then
            local ok, n = pcall(name_of, spell_id)
            if ok and type(n) == "string" and n ~= "" then
                id_names[spell_id] = n
                return n
            end
        end
        return nil
    end

    local function push(row)
        rows[#rows + 1] = row
        if #rows > KEEP_ROWS then table.remove(rows, 1) end
    end

    --- The newest row for this spell id still waiting on the client.
    local function open_row(spell_id, states_ok)
        for i = #rows, 1, -1 do
            local row = rows[i]
            if row.id == spell_id and states_ok[row.state] then return row end
        end
        return nil
    end

    local WAITING = { requested = true, sent = true }
    local ANSWERABLE = { requested = true, sent = true, unknown = true }

    -- --- attempts -----------------------------------------------------------

    --- We asked for something. The engine calls this on execute.
    ---@param a table { name, id?, kind?, target_guid?, event_key?, rule?, score?, lane?, cast_time?, unique? }
    ---@return table row
    function M.attempt(a)
        local now = clock()
        local row = {
            name = a.name, id = a.id, kind = a.kind or "spell",
            target_guid = a.target_guid, event_key = a.event_key,
            rule = a.rule, score = a.score, lane = a.lane,
            cast_time = a.cast_time or 0, unique = a.unique == true,
            channel = a.channel == true,
            at = now, state = "requested",
        }
        if a.id and a.name then id_names[a.id] = a.name end
        -- A bag item or a pet order has no arbiter in between: asking IS sending.
        if row.kind == "item" or row.kind == "pet_spell" or row.kind == "pet_send" then
            row.state, row.sent_at = "sent", now
            if row.kind ~= "pet_spell" then row.state, row.resolved_at = "ok", now end
        end
        push(row)
        local r = record(a.name)
        r.attempt_at = now
        r.target_guid = a.target_guid
        if row.state == "sent" or row.state == "ok" then r.sent_at = now end
        if row.state == "ok" then r.success_at = now; M.last_success = row end
        M.last_attempt = row
        return row
    end

    --- The arbiter sent something of ours. Rotation presses arrive here too,
    --- so the memory knows about every press, not only the reactions.
    ---@param spell_id integer|nil
    ---@param target_guid string|nil
    ---@param reason string|nil
    function M.on_sent(spell_id, target_guid, reason)
        if not spell_id then return end
        local now = clock()
        local row = open_row(spell_id, { requested = true })
        if not row then
            local name = resolve(spell_id) or reason or ("spell " .. tostring(spell_id))
            row = {
                name = name, id = spell_id, kind = "spell", target_guid = target_guid,
                rule = "rotation", at = now, state = "requested", cast_time = 0,
            }
            push(row)
            record(name).attempt_at = now
        end
        row.state, row.sent_at = "sent", now
        if target_guid then row.target_guid = target_guid end
        local r = record(row.name)
        r.sent_at = now
        r.target_guid = row.target_guid
        M.last_sent = row
    end

    --- The client confirmed one of our casts.
    ---@param spell_id integer|nil
    function M.on_success(spell_id)
        if not spell_id then return end
        local now = clock()
        local row = open_row(spell_id, ANSWERABLE)
        -- A pet's skill by its NAME (1.73.1): the pet's book can name another
        -- rank's id than the one its cast event carries, and a press of ours
        -- that is never matched reads as "no confirmation" and is marked down.
        if not row then
            local n = resolve(spell_id)
            if n then
                for i = #rows, 1, -1 do
                    local r = rows[i]
                    if r.kind == "pet_spell" and r.name == n and ANSWERABLE[r.state] then row = r break end
                end
            end
        end
        local name = row and row.name or resolve(spell_id)
        if row then
            row.state, row.resolved_at = "ok", now
            M.last_success = row
            if (row.unique or (M.unique and M.unique[row.name])) and row.target_guid then
                applied[row.name] = { guid = row.target_guid, at = now }
            end
        end
        if not name then return end
        local r = record(name)
        r.success_at = now
        r.confirmed = true
        r.failures = {}
        r.backoff_until = 0
        if not row then
            M.last_success = { name = name, id = spell_id, at = now, resolved_at = now, state = "ok" }
        end
    end

    --- How long a name is held after its n-th failure inside the window.
    local function backoff_for(n)
        if n < 2 then return 0 end
        local secs = BACKOFF_BASE * (2 ^ (n - 2))
        if secs > BACKOFF_MAX then secs = BACKOFF_MAX end
        return secs
    end

    --- Lays a failure on one attempt (or on a bare name when no attempt of
    --- ours matches) and moves its back-off.
    local function fail(row, name, spell_id, why, soft)
        local now = clock()
        if row then
            row.state, row.resolved_at, row.why = "failed", now, why
            -- An answer that did not happen does not answer the event. A
            -- refused interrupt, or a Mend Pet cut off before it healed
            -- anything, leaves the cast or the dip open again -- the rule's
            -- own retry hold and the back-off still pace the next try.
            if row.event_key then handled[row.event_key] = nil end
        end

        local r = record(name)
        r.failure_at = now
        r.last_why = why
        if not soft then
            r.failures[#r.failures + 1] = now
            while #r.failures > 0 and (now - r.failures[1]) > FAIL_WINDOW do
                table.remove(r.failures, 1)
            end
            local hold = backoff_for(#r.failures)
            if hold > 0 then r.backoff_until = now + hold end
        end
        M.last_failure = row or { name = name, id = spell_id, at = now, resolved_at = now, state = "failed", why = why }
        return row
    end

    --- The client refused one of ours. `spell_id` may be nil for a UI error,
    --- which is then laid on whatever we sent in the last moment.
    ---@param spell_id integer|nil
    ---@param why string
    ---@param soft? boolean recorded, but not counted towards a back-off
    ---@return table|nil row the attempt it was laid on
    function M.on_failure(spell_id, why, soft)
        local now = clock()
        local row
        if spell_id then
            row = open_row(spell_id, ANSWERABLE)
        else
            for i = #rows, 1, -1 do
                local r = rows[i]
                if r.state == "sent" and r.sent_at and (now - r.sent_at) < 0.6 then row = r break end
                if (now - r.at) > 1.0 then break end
            end
        end
        -- Only a refusal of something WE sent counts. The player's own key
        -- presses fail too, and holding the rotation back for those would be
        -- punishing it for someone else's miss.
        if not row then return nil end
        return fail(row, row.name, spell_id, why, soft)
    end

    --- Ages the waiting rows. Called once per engine tick.
    ---@param busy boolean the player is mid-cast, so nothing is overdue yet
    function M.update(busy)
        local now = clock()
        for i = 1, #rows do
            local row = rows[i]
            if row.state == "requested" and (now - row.at) > LOST_AFTER then
                row.state, row.resolved_at = "lost", now
            elseif row.state == "sent" then
                local due = (row.sent_at or row.at) + (row.cast_time or 0) + CONFIRM_SLACK
                if busy and row.kind == "spell" then
                    -- A cast in flight: whatever we sent may still land.
                    row.sent_at = math.max(row.sent_at or row.at, now - CONFIRM_SLACK + 0.2)
                elseif now > due then
                    -- Silence only counts against a reaction, and only for a
                    -- name whose confirmations we can read. A rotation press
                    -- may be a toggle (Auto Shot) or ride the next swing
                    -- (Raptor Strike), and those answer late or never; the
                    -- rotation's own breaker judges them. Its EXPLICIT
                    -- failures still count, through on_failure.
                    local r = record(row.name)
                    if r.confirmed and row.rule ~= "rotation" then
                        fail(row, row.name, row.id, "no confirmation", false)
                    else
                        row.state, row.resolved_at = "unknown", now
                    end
                end
            end
        end
        -- Expire handled events.
        for key, h in pairs(handled) do
            if now >= h.until_at then handled[key] = nil end
        end
    end

    -- --- questions about an ability ------------------------------------------

    ---@param name string
    ---@return number seconds since we last asked for it
    function M.since(name)
        local r = names[name]
        return r and (clock() - r.attempt_at) or huge
    end

    ---@param name string
    ---@return number seconds since the client last confirmed it
    function M.since_success(name)
        local r = names[name]
        return r and (clock() - r.success_at) or huge
    end

    --- Failures inside the window, and the seconds left on its back-off.
    ---@param name string
    ---@return integer failures
    ---@return number backoff_left
    ---@return string|nil why
    function M.failures(name)
        local r = names[name]
        if not r then return 0, 0, nil end
        local now = clock()
        while #r.failures > 0 and (now - r.failures[1]) > FAIL_WINDOW do
            table.remove(r.failures, 1)
        end
        return #r.failures, math.max(0, r.backoff_until - now), r.last_why
    end

    --- Is an attempt at this (ability, target) still waiting on its answer?
    ---@param name string
    ---@param target_guid string|nil any target when nil
    ---@return boolean
    ---@return table|nil row
    function M.waiting(name, target_guid)
        for i = #rows, 1, -1 do
            local row = rows[i]
            if row.name == name and WAITING[row.state]
                and (target_guid == nil or row.target_guid == nil or row.target_guid == target_guid) then
                return true, row
            end
        end
        return false, nil
    end

    --- Did we press something at this unit in the last `window` seconds?
    --- "You started it": a Classic mob is not put in combat by a mark, so a
    --- pull we opened must not be dropped because the mob has not noticed.
    ---@param guid string
    ---@param window number
    ---@return boolean
    function M.attacked(guid, window)
        if not guid then return false end
        local now = clock()
        for i = #rows, 1, -1 do
            local row = rows[i]
            if (now - row.at) > window then break end
            if row.target_guid == guid and row.kind == "spell"
                and (row.state == "sent" or row.state == "ok" or row.state == "unknown") then
                return true
            end
        end
        return false
    end

    --- Names of everything of ours sent in the last `window` seconds, newest
    --- first: a client error with no spell named may be any of them.
    ---@param window number
    ---@return string[]
    function M.sent_recently(window)
        local now, out, seen = clock(), {}, {}
        for i = #rows, 1, -1 do
            local row = rows[i]
            if (now - row.at) > window + 1.0 then break end
            local at = row.sent_at or row.at
            if (row.state == "sent" or row.state == "ok" or row.state == "unknown") and (now - at) <= window
                and not seen[row.name] then
                seen[row.name] = true
                out[#out + 1] = row.name
            end
        end
        return out
    end

    --- Seconds since anything of ours went out (a cast sent, an item used).
    ---@return number
    function M.since_any_sent()
        local row = M.last_sent
        local at = row and (row.sent_at or row.at) or nil
        local a = M.last_attempt
        if a and (a.kind == "item" or a.kind == "pet_spell") then
            at = math.max(at or -huge, a.at)
        end
        if not at then return huge end
        return clock() - at
    end

    --- Has the client ever confirmed this name? Until it has, silence after a
    --- press says nothing about the press.
    ---@param name string
    ---@return boolean
    function M.confirmed(name)
        local r = names[name]
        return r ~= nil and r.confirmed
    end

    -- --- handled events -------------------------------------------------------

    --- Marks an event as dealt with for `ttl` seconds: an interrupt on one
    --- cast, a heal on one dip of the pet's health.
    ---@param key string
    ---@param ttl number
    ---@param note? string
    function M.handle(key, ttl, note)
        if not key then return end
        local now = clock()
        handled[key] = { at = now, until_at = now + (ttl or 2), note = note }
    end

    ---@param key string|nil
    ---@return boolean
    ---@return string|nil note
    ---@return number left seconds
    function M.handled(key)
        if not key then return false, nil, 0 end
        local h = handled[key]
        if not h then return false, nil, 0 end
        local left = h.until_at - clock()
        if left <= 0 then
            handled[key] = nil
            return false, nil, 0
        end
        return true, h.note, left
    end

    ---@param key string
    function M.release(key)
        handled[key] = nil
    end

    ---@return integer
    function M.handled_count()
        local n, now = 0, clock()
        for _, h in pairs(handled) do
            if h.until_at > now then n = n + 1 end
        end
        return n
    end

    --- Keys of everything currently handled, newest first, for the readout.
    ---@param prefix? string
    ---@return string[]
    function M.handled_keys(prefix)
        local out, now = {}, clock()
        for key, h in pairs(handled) do
            if h.until_at > now and (not prefix or key:sub(1, #prefix) == prefix) then
                out[#out + 1] = { key = key, at = h.at, note = h.note }
            end
        end
        table.sort(out, function(a, b) return a.at > b.at end)
        local keys = {}
        for i = 1, #out do keys[i] = out[i].note or out[i].key end
        return keys
    end

    -- --- what is on what --------------------------------------------------------

    --- Where a one-per-caster debuff (Hunter's Mark) was last confirmed.
    ---@param name string
    ---@return string|nil guid
    ---@return number seconds ago
    function M.applied(name)
        local a = applied[name]
        if not a then return nil, huge end
        return a.guid, clock() - a.at
    end

    ---@param name string
    ---@param guid string|nil
    function M.mark_applied(name, guid)
        if not guid then applied[name] = nil return end
        applied[name] = { guid = guid, at = clock() }
    end

    -- --- the target ---------------------------------------------------------------

    --- Fed with the current target's guid every tick. Records a change.
    ---@param guid string|nil
    ---@return boolean changed
    function M.target_seen(guid)
        if guid == last_target then return false end
        local first = last_target == false
        last_target = guid
        if first then return false end
        local now = clock()
        trail[#trail + 1] = { t = now, guid = guid }
        while #trail > 0 and (now - trail[1].t) > TRAIL_SPAN do table.remove(trail, 1) end
        return true
    end

    --- Target changes in the last `window` seconds.
    ---@param window number
    ---@return integer
    function M.flaps(window)
        local now, n = clock(), 0
        for i = #trail, 1, -1 do
            if (now - trail[i].t) > window then break end
            n = n + 1
        end
        return n
    end

    --- Seconds the current target has been the target.
    ---@return number
    function M.stable_for()
        if #trail == 0 then return huge end
        return clock() - trail[#trail].t
    end

    -- --- health --------------------------------------------------------------------

    local last_hp_at = -huge

    ---@param value number 0..1
    function M.sample_hp(value)
        local now = clock()
        if type(value) ~= "number" or (now - last_hp_at) < HP_EVERY then return end
        last_hp_at = now
        hp[#hp + 1] = { t = now, hp = value }
        while #hp > 2 and (now - hp[1].t) > HP_SPAN do table.remove(hp, 1) end
    end

    --- Health LOST over the last `window` seconds, heals not netted off: a
    --- heal landing between two hits does not make the hits smaller.
    ---@param window number
    ---@return number fraction of max health
    function M.damage_taken(window)
        local now, lost = clock(), 0
        for i = #hp, 2, -1 do
            if (now - hp[i - 1].t) > window then break end
            local d = hp[i - 1].hp - hp[i].hp
            if d > 0 then lost = lost + d end
        end
        return lost
    end

    -- --- named states ----------------------------------------------------------------

    --- Stores a named state ("mode", "bailout", "escape"). Answers whether it changed.
    ---@param name string
    ---@param value any
    ---@return boolean changed
    ---@return any previous
    function M.set_state(name, value)
        local s = states[name]
        if s and s.value == value then return false, value end
        local previous = s and s.value
        states[name] = { value = value, since = clock() }
        return true, previous
    end

    ---@param name string
    ---@return any value
    ---@return number seconds in it
    function M.state(name)
        local s = states[name]
        if not s then return nil, huge end
        return s.value, clock() - s.since
    end

    -- --- the channel in progress -------------------------------------------------------

    ---@param spell_id integer|nil
    ---@param on boolean
    function M.on_channel(spell_id, on)
        if on then
            channel = { id = spell_id, since = clock() }
        elseif channel and (spell_id == nil or channel.id == spell_id) then
            channel = nil
        end
    end

    --- The reaction behind the cast or channel in progress, when the client
    --- reports the spell we started: its score is what a later reaction has
    --- to beat before it may talk over it.
    ---@param spell_id integer|nil the spell the client says is in progress
    ---@return table|nil row
    function M.in_progress(spell_id)
        if not spell_id then return nil end
        local now = clock()
        for i = #rows, 1, -1 do
            local row = rows[i]
            if (now - row.at) > 30 then break end
            if row.id == spell_id and row.rule ~= "rotation"
                and (row.state == "ok" or row.state == "sent") then
                return row
            end
        end
        return nil
    end

    -- --- lifecycle --------------------------------------------------------------------

    --- Combat ended: everything that was about THIS fight goes.
    function M.combat_end()
        handled = {}
        applied = {}
        trail = {}
    end

    --- Everything, for the debug reset.
    function M.reset()
        rows, names, handled, applied, trail, hp, states = {}, {}, {}, {}, {}, {}, {}
        channel, last_target = nil, false
        M.last_attempt, M.last_sent, M.last_success, M.last_failure = nil, nil, nil, nil
    end

    ---@param n integer
    ---@return table[] newest first
    function M.recent(n)
        local out = {}
        for i = #rows, math.max(1, #rows - (n or 6) + 1), -1 do out[#out + 1] = rows[i] end
        return out
    end

    return M
end

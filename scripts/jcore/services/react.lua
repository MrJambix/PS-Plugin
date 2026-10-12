-- JCore / react -- the reaction framework: several things are happening;
-- which matters most? (1.8.0; Jambix AIO's modules/react engine until then)
--
-- Depends on: nothing at factory time. Each engine binds to the context
-- handle of the plugin that owns it (ctx.on, ctx.cast, ctx.PRIORITY,
-- ctx.spells, ctx.units, ctx.log), so a plugin's reactions are tagged, billed
-- and torn down like everything else it does.
--
-- WHAT A REACTION IS
-- A rule, as data: a name, a base priority, the lane it competes in, what it
-- needs, how often it is asked, and either a condition with an action or a
-- propose() that offers candidates. The engine supplies everything else: the
-- scoring, the memory, the safety checks, the cast and the journal. A rule
-- never casts.
--
--   {
--       name      = "Interrupt",            unique; the readouts show it
--       category  = "interrupt",            survival | bailout | interrupt | cc | escape |
--                                           defensive | pet | threat | utility | buff | low | resource
--       priority  = 90,                     the base score
--       lane      = "gcd" | "fast" | "pet", which lane it competes in
--       needs     = { "combat", "pet" },    cheap gates: combat, pet, target, group, casting
--       every     = 0.2,                    seconds between evaluations (0: every tick)
--       wake      = { "jcore.enemy.casting" },  events that force an evaluation now
--       enabled   = function(W) ... end,    the setting that governs it
--       retry     = { hold = 2 },           seconds after an attempt before another
--       owns      = { "Mend Pet" },         spells nothing else may cast while it is on
--       condition = function(W) ... end,    the simple form, with
--       action    = "Counter Shot" | { "A", "B" } | function(W) ... end,
--       target    = "enemy" | "self" | "pet" | function(W) ... end,
--       propose   = function(W, offer) offer({ name, target, event_key, ... }) end,
--       score     = function(W, c) c:add(25, "cast ends in 0.8s") end,
--       validate  = function(W, c) return "reason not to" end,
--   }
--
-- THE PIPELINE, ONE TICK (engine.decide(W), then engine.execute per lane)
--
--   rules propose      every enabled rule that is due looks at the world and
--                      offers zero or more candidate actions, each with the
--                      event it answers ("cast:<guid>:<spell>:<start>")
--   score              base priority + the rule's own modifiers + what the
--                      mode, the context and the memory add or take away.
--                      Every point carries its reason.
--   select             per lane (global cooldown, off-GCD, the pet), highest
--                      score first; the first candidate that passes
--                      validation wins. A "hold" (stop attacking) is not an
--                      action and never takes a lane: it only halts a rotation.
--   validate           known, ready, right kind of target, not already
--                      handled, not just failed, not talking over something
--                      more important
--   execute            through the cast arbiter, or the consumer's own kinds
--                      (the pet, the bag, a target switch)
--   remember           the attempt, and the event as handled
--
-- Every valid reaction is not fired: one per lane per tick, and only when it
-- outscores the rotation (ROTATION_SCORE); anything under that is deferred
-- for a tick on which the rotation had nothing to press.
--
-- THE PICTURE (W) IS THE CONSUMER'S. The engine reads a few fields of it and
-- hands the rest to the rules untouched: W.now, W.mode, W.context,
-- W.player.{unit, in_combat, busy, casting_id}, W.pet.{unit, alive},
-- W.target.{unit, casting}, W.group.in_group, W.enemies.casting_n, W.bailout,
-- W.fight_on, W.hold_fire, W.pending, W.yield, W.s. Any of them may be absent.
--
-- WHAT THE CONSUMER TELLS IT (engine.configure): how to read its spellbook by
-- name, what kind of target a spell takes, the gates a press has to pass,
-- and its own action kinds beyond "spell" and "hold" -- each with a validate
-- and an execute. See `configure` below.
--
-- The memory is fed by the game on its own: the arbiter's jcore.cast.sent
-- for this owner, UNIT_SPELLCAST_SUCCEEDED / FAILED / INTERRUPTED,
-- UI_ERROR_MESSAGE, the channel events, and jcore.combat.leave.

return function(rt)
    local M = {}

    local huge, floor = math.huge, math.floor

    -- =========================================================================
    -- THE LATCH -- a threshold that does not chatter
    -- =========================================================================
    --
    -- A single line is crossed in both directions by noise. Health at 30% with
    -- a defensive line at 30% reads "in trouble", "fine", "in trouble" on three
    -- frames running, and everything that keys off it flips with it. So every
    -- state here has TWO lines -- one to enter and a further one to leave --
    -- and, where it matters, a minimum time it holds once it has changed.
    --
    --   below = true   ON at value <= enter, OFF again only at value >= exit
    --   below = false  ON at value >= enter, OFF again only at value <= exit
    --
    -- The lines can move between calls (an auto-tuned threshold does), so
    -- update() takes them each time rather than freezing them at construction.

    local L = {}

    ---@param opts { name?: string, enter: number, exit: number, below?: boolean, hold?: number }
    ---@return table latch
    function L.new(opts)
        local self = {
            name = opts.name or "?",
            enter = opts.enter,
            exit = opts.exit,
            below = opts.below ~= false,
            hold = opts.hold or 0,
            on = false,
            since = -huge,          -- when it last changed
            value = nil,            -- the last value it was fed
            locked_exit = nil,      -- the exit line in force since it turned on
        }

        --- Feeds a value. Returns the state and whether it changed on this call.
        ---
        --- A MOVING LINE MUST NOT UNDO THE HYSTERESIS. An auto-tuned threshold
        --- can swing between ticks, and an exit line that swings with it
        --- switched the latch off a second after it came on. So the exit line
        --- is fixed at the moment the latch turns on, and may only move
        --- further from the entry line while it stays on.
        ---@param value number
        ---@param now number
        ---@param enter? number a moved entry line
        ---@param exit? number a moved exit line
        ---@return boolean on
        ---@return boolean changed
        function self.update(value, now, enter, exit)
            if enter then self.enter = enter end
            if exit then self.exit = exit end
            -- A reading that is not a number (nil, NaN) changes nothing.
            if type(value) ~= "number" or value ~= value then return self.on, false end
            self.value = value

            local exit_line = self.exit
            if self.on and self.locked_exit then
                if self.below then
                    exit_line = math.max(self.locked_exit, self.exit)
                else
                    exit_line = math.min(self.locked_exit, self.exit)
                end
                self.locked_exit = exit_line
            end

            -- Held: a state that has just changed keeps for `hold` seconds
            -- whatever the value does, so one bad frame cannot undo it.
            if (now - self.since) < self.hold then return self.on, false end

            local want = self.on
            if self.below then
                if self.on then
                    if value >= exit_line then want = false end
                elseif value <= self.enter then
                    want = true
                end
            else
                if self.on then
                    if value <= exit_line then want = false end
                elseif value >= self.enter then
                    want = true
                end
            end

            if want ~= self.on then
                self.on = want
                self.since = now
                self.locked_exit = want and self.exit or nil
                return want, true
            end
            return want, false
        end

        --- Forces a state, for a reset (combat ended) rather than a reading.
        ---@param on boolean
        ---@param now number
        function self.set(on, now)
            if self.on ~= on then
                self.on = on
                self.since = now
                self.locked_exit = on and self.exit or nil
            end
        end

        --- Seconds in the current state.
        ---@param now number
        ---@return number
        function self.age(now)
            return now - self.since
        end

        return self
    end

    --- A boolean that must hold for `settle` seconds before it counts, in
    --- either direction. For conditions that are already yes/no -- "the plan
    --- says FLEE" -- where there is no number to put two lines on.
    ---@param opts { name?: string, settle_on?: number, settle_off?: number }
    ---@return table
    function L.debounce(opts)
        local self = {
            name = opts.name or "?",
            settle_on = opts.settle_on or 0,
            settle_off = opts.settle_off or 0,
            on = false,
            since = -huge,
            pending = nil,          -- the raw value waiting to settle
            pending_at = 0,
        }

        ---@param raw boolean
        ---@param now number
        ---@return boolean on
        ---@return boolean changed
        function self.update(raw, now)
            raw = raw == true
            if raw == self.on then
                self.pending = nil
                return self.on, false
            end
            if self.pending ~= raw then
                self.pending, self.pending_at = raw, now
            end
            local need = raw and self.settle_on or self.settle_off
            if (now - self.pending_at) >= need then
                self.on, self.since, self.pending = raw, now, nil
                return self.on, true
            end
            return self.on, false
        end

        function self.set(on, now)
            if self.on ~= on then self.on, self.since = on, now end
            self.pending = nil
        end

        return self
    end

    M.latch = L

    -- =========================================================================
    -- THE MEMORY -- what was just done, and what came of it
    -- =========================================================================
    --
    -- THE BUG SHAPE THIS EXISTS FOR
    --   Mend Pet -> Mend Pet -> Mend Pet
    --   Hunter's Mark -> switch -> Hunter's Mark -> switch -> Hunter's Mark
    -- Each press was right against the frame it was decided on, and wrong
    -- against the one before it. A rule that sees only the present cannot
    -- tell "the pet is low" from "the pet is low AND I started healing it
    -- half a second ago". So every action is remembered from the moment it is
    -- asked for until the game says what happened to it, and an event that
    -- has been dealt with is remembered as dealt with until its result has
    -- had time to show.
    --
    -- LIFECYCLE OF AN ATTEMPT
    --   requested  we asked the cast arbiter
    --   sent       the arbiter dispatched it          (jcore.cast.sent)
    --   ok         the client confirmed it            (UNIT_SPELLCAST_SUCCEEDED)
    --   failed     the client refused it              (UNIT_SPELLCAST_FAILED, UI_ERROR_MESSAGE)
    --   lost       never sent: it lost arbitration. Not a failure of the action.
    --   unknown    sent, and neither answer came back. Only a failure for a
    --              spell whose confirmations we have seen before.
    --
    -- Nothing here reads the game. It is fed by the engine's event handlers
    -- and by execute(), which is what lets the tests drive it with a clock.

    ---@param clock fun(): number
    ---@param name_of? fun(id: integer): string|nil
    ---@return table memory
    function M.new_memory(clock, name_of)
        local MEM = {}

        local KEEP_ROWS = 48              -- attempts remembered, newest last
        local LOST_AFTER = 0.35           -- requested and never sent: lost arbitration
        local CONFIRM_SLACK = 1.5         -- beyond the cast time, before "unknown"
        local FAIL_WINDOW = 6.0           -- failures counted over this long
        local BACKOFF_BASE = 1.5          -- seconds, doubled per failure past the first
        local BACKOFF_MAX = 4.0           -- never longer than this: a silent rotation is worse
        local TRAIL_SPAN = 10.0           -- target changes remembered
        local HP_SPAN = 4.0               -- health samples remembered
        local HP_EVERY = 0.1

        MEM.BACKOFF_MAX = BACKOFF_MAX

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

        MEM.last_attempt, MEM.last_sent, MEM.last_success, MEM.last_failure = nil, nil, nil, nil

        --- Names of one-per-caster debuffs; engine.unique fills it.
        MEM.unique = {}

        -- WHICH REFUSALS MEAN ANYTHING. The client's red error text fires all
        -- the time for things that fix themselves a moment later -- "spell is
        -- not ready yet", "another action is in progress", "not enough mana".
        -- Only a refusal that will still be true on the next press counts.
        local PERSISTENT = {
            "OUT_OF_RANGE", "INFRONT", "FACING", "LINE_OF_SIGHT", "TOO_CLOSE",
            "BAD_TARGET", "BAD_IMPLICIT", "IMMUNE", "NOT_BEHIND", "TARGETS_DEAD",
            "ATTACKPOS", "TARGET_FRIENDLY", "TARGET_ENEMY", "NO_AMMO",
        }

        --- Is this UI error id one that will repeat on the next press?
        ---@param id string|nil the client's string id (UI_ERROR_MESSAGE args[3])
        ---@return boolean
        function MEM.persistent_error(id)
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

        --- We asked for something. The engine calls this on execute.
        ---
        --- `answer` says how the client answers this kind of action: "arbiter"
        --- (the default; the cast arbiter sends it, the client confirms it),
        --- "sent" (asking is sending; the client still confirms it), or
        --- "done" (asking is doing: a bag item, an order to the pet).
        ---@param a table { name, id?, kind?, target_guid?, event_key?, rule?, score?, lane?, cast_time?, unique?, channel?, answer? }
        ---@return table row
        function MEM.attempt(a)
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
            local answer = a.answer
            if answer == nil then
                -- A bag item or a pet order has no arbiter in between: asking IS sending.
                if row.kind == "item" or row.kind == "pet_send" then answer = "done"
                elseif row.kind == "pet_spell" then answer = "sent" end
            end
            if answer == "sent" or answer == "done" then
                row.state, row.sent_at = "sent", now
                if answer == "done" then row.state, row.resolved_at = "ok", now end
            end
            push(row)
            local r = record(a.name)
            r.attempt_at = now
            r.target_guid = a.target_guid
            if row.state == "sent" or row.state == "ok" then r.sent_at = now end
            if row.state == "ok" then r.success_at = now; MEM.last_success = row end
            MEM.last_attempt = row
            return row
        end

        --- The arbiter sent something of ours. Rotation presses arrive here
        --- too, so the memory knows about every press, not only the reactions.
        ---@param spell_id integer|nil
        ---@param target_guid string|nil
        ---@param reason string|nil
        function MEM.on_sent(spell_id, target_guid, reason)
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
            MEM.last_sent = row
        end

        --- The client confirmed one of our casts.
        ---@param spell_id integer|nil
        function MEM.on_success(spell_id)
            if not spell_id then return end
            local now = clock()
            local row = open_row(spell_id, ANSWERABLE)
            -- A pet's skill by its NAME: the pet's book can name another
            -- rank's id than the one its cast event carries, and a press of
            -- ours that is never matched reads as "no confirmation".
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
                MEM.last_success = row
                if (row.unique or (MEM.unique and MEM.unique[row.name])) and row.target_guid then
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
                MEM.last_success = { name = name, id = spell_id, at = now, resolved_at = now, state = "ok" }
            end
        end

        --- How long a name is held after its n-th failure inside the window.
        local function backoff_for(n)
            if n < 2 then return 0 end
            local secs = BACKOFF_BASE * (2 ^ (n - 2))
            if secs > BACKOFF_MAX then secs = BACKOFF_MAX end
            return secs
        end

        --- Lays a failure on one attempt (or on a bare name when no attempt
        --- of ours matches) and moves its back-off.
        local function fail(row, name, spell_id, why, soft)
            local now = clock()
            if row then
                row.state, row.resolved_at, row.why = "failed", now, why
                -- An answer that did not happen does not answer the event.
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
            MEM.last_failure = row or { name = name, id = spell_id, at = now, resolved_at = now, state = "failed", why = why }
            return row
        end

        --- The client refused one of ours. `spell_id` may be nil for a UI
        --- error, which is then laid on whatever we sent in the last moment.
        ---@param spell_id integer|nil
        ---@param why string
        ---@param soft? boolean recorded, but not counted towards a back-off
        ---@return table|nil row the attempt it was laid on
        function MEM.on_failure(spell_id, why, soft)
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
            -- Only a refusal of something WE sent counts. The player's own
            -- key presses fail too, and holding a rotation back for those
            -- would be punishing it for someone else's miss.
            if not row then return nil end
            return fail(row, row.name, spell_id, why, soft)
        end

        --- Ages the waiting rows. Called once per engine tick.
        ---@param busy boolean the player is mid-cast, so nothing is overdue yet
        function MEM.update(busy)
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
                        -- Silence only counts against a reaction, and only
                        -- for a name whose confirmations we can read. A
                        -- rotation press may be a toggle or ride the next
                        -- swing, and those answer late or never.
                        local r = record(row.name)
                        if r.confirmed and row.rule ~= "rotation" then
                            fail(row, row.name, row.id, "no confirmation", false)
                        else
                            row.state, row.resolved_at = "unknown", now
                        end
                    end
                end
            end
            for key, h in pairs(handled) do
                if now >= h.until_at then handled[key] = nil end
            end
        end

        -- --- questions about an ability -------------------------------------

        ---@param name string
        ---@return number seconds since we last asked for it
        function MEM.since(name)
            local r = names[name]
            return r and (clock() - r.attempt_at) or huge
        end

        ---@param name string
        ---@return number seconds since the client last confirmed it
        function MEM.since_success(name)
            local r = names[name]
            return r and (clock() - r.success_at) or huge
        end

        --- Failures inside the window, and the seconds left on its back-off.
        ---@param name string
        ---@return integer failures
        ---@return number backoff_left
        ---@return string|nil why
        function MEM.failures(name)
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
        function MEM.waiting(name, target_guid)
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
        ---@param guid string
        ---@param window number
        ---@return boolean
        function MEM.attacked(guid, window)
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

        --- Names of everything of ours sent in the last `window` seconds,
        --- newest first: a client error with no spell named may be any of them.
        ---@param window number
        ---@return string[]
        function MEM.sent_recently(window)
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
        function MEM.since_any_sent()
            local row = MEM.last_sent
            local at = row and (row.sent_at or row.at) or nil
            local a = MEM.last_attempt
            if a and (a.kind == "item" or a.kind == "pet_spell") then
                at = math.max(at or -huge, a.at)
            end
            if not at then return huge end
            return clock() - at
        end

        --- Has the client ever confirmed this name? Until it has, silence
        --- after a press says nothing about the press.
        ---@param name string
        ---@return boolean
        function MEM.confirmed(name)
            local r = names[name]
            return r ~= nil and r.confirmed
        end

        -- --- handled events -------------------------------------------------

        --- Marks an event as dealt with for `ttl` seconds: an interrupt on
        --- one cast, a heal on one dip of the pet's health.
        ---@param key string
        ---@param ttl number
        ---@param note? string
        function MEM.handle(key, ttl, note)
            if not key then return end
            local now = clock()
            handled[key] = { at = now, until_at = now + (ttl or 2), note = note }
        end

        ---@param key string|nil
        ---@return boolean
        ---@return string|nil note
        ---@return number left seconds
        function MEM.handled(key)
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
        function MEM.release(key)
            handled[key] = nil
        end

        ---@return integer
        function MEM.handled_count()
            local n, now = 0, clock()
            for _, h in pairs(handled) do
                if h.until_at > now then n = n + 1 end
            end
            return n
        end

        --- Keys of everything currently handled, newest first, for the readout.
        ---@param prefix? string
        ---@return string[]
        function MEM.handled_keys(prefix)
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

        -- --- what is on what ------------------------------------------------

        --- Where a one-per-caster debuff (Hunter's Mark) was last confirmed.
        ---@param name string
        ---@return string|nil guid
        ---@return number seconds ago
        function MEM.applied(name)
            local a = applied[name]
            if not a then return nil, huge end
            return a.guid, clock() - a.at
        end

        ---@param name string
        ---@param guid string|nil
        function MEM.mark_applied(name, guid)
            if not guid then applied[name] = nil return end
            applied[name] = { guid = guid, at = clock() }
        end

        -- --- the target -----------------------------------------------------

        --- Fed with the current target's guid every tick. Records a change.
        ---@param guid string|nil
        ---@return boolean changed
        function MEM.target_seen(guid)
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
        function MEM.flaps(window)
            local now, n = clock(), 0
            for i = #trail, 1, -1 do
                if (now - trail[i].t) > window then break end
                n = n + 1
            end
            return n
        end

        --- Seconds the target has been the same.
        ---@return number
        function MEM.stable_for()
            if #trail == 0 then return huge end
            return clock() - trail[#trail].t
        end

        -- --- health over time -------------------------------------------------

        local last_hp_at = -huge

        --- Fed with the player's health fraction every tick; kept sparsely.
        ---@param value number 0..1
        function MEM.sample_hp(value)
            local now = clock()
            if type(value) ~= "number" or (now - last_hp_at) < HP_EVERY then return end
            last_hp_at = now
            hp[#hp + 1] = { t = now, hp = value }
            while #hp > 2 and (now - hp[1].t) > HP_SPAN do table.remove(hp, 1) end
        end

        --- Health LOST over the last `window` seconds, heals not netted off:
        --- a heal landing between two hits does not make the hits smaller.
        ---@param window number
        ---@return number fraction of max health
        function MEM.damage_taken(window)
            local now, lost = clock(), 0
            for i = #hp, 2, -1 do
                if (now - hp[i - 1].t) > window then break end
                local d = hp[i - 1].hp - hp[i].hp
                if d > 0 then lost = lost + d end
            end
            return lost
        end

        -- --- named states ---------------------------------------------------

        --- Stores a named state ("mode", "bailout", "escape"). Answers whether it changed.
        ---@param name string
        ---@param value any
        ---@return boolean changed
        ---@return any previous
        function MEM.set_state(name, value)
            local s = states[name]
            if s and s.value == value then return false, value end
            local previous = s and s.value
            states[name] = { value = value, since = clock() }
            return true, previous
        end

        ---@param name string
        ---@return any value
        ---@return number seconds in it
        function MEM.state(name)
            local s = states[name]
            if not s then return nil, huge end
            return s.value, clock() - s.since
        end

        -- --- the channel in progress ----------------------------------------

        ---@param spell_id integer|nil
        ---@param on boolean
        function MEM.on_channel(spell_id, on)
            if on then
                channel = { id = spell_id, since = clock() }
            elseif channel and (spell_id == nil or channel.id == spell_id) then
                channel = nil
            end
        end

        --- The reaction behind the cast or channel in progress, when the
        --- client reports the spell we started: its score is what a later
        --- reaction has to beat before it may talk over it.
        ---@param spell_id integer|nil the spell the client says is in progress
        ---@return table|nil row
        function MEM.in_progress(spell_id)
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

        -- --- lifecycle --------------------------------------------------------

        --- Combat ended: everything that was about THIS fight goes.
        function MEM.combat_end()
            handled = {}
            applied = {}
            trail = {}
        end

        --- Everything, for the debug reset.
        function MEM.reset()
            rows, names, handled, applied, trail, hp, states = {}, {}, {}, {}, {}, {}, {}
            channel, last_target = nil, false
            MEM.last_attempt, MEM.last_sent, MEM.last_success, MEM.last_failure = nil, nil, nil, nil
        end

        ---@param n integer
        ---@return table[] newest first
        function MEM.recent(n)
            local out = {}
            for i = #rows, math.max(1, #rows - (n or 6) + 1), -1 do out[#out + 1] = rows[i] end
            return out
        end

        return MEM
    end

    -- =========================================================================
    -- THE ENGINE -- one per owner
    -- =========================================================================

    --- The score a rotation's own presses stand at. A reaction has to beat
    --- it to override the priority list; below it, it waits for an idle tick.
    M.ROTATION_SCORE = 40
    --- How many candidates per lane are put through validation in one tick.
    --- Validation can ask the client about range and sight; this caps it.
    local VALIDATE_PER_LANE = 4

    -- Added to a candidate's score by category. The base priorities already
    -- order the categories; these move them as the fight changes, which is
    -- the point of having a mode at all.
    local MODE_MODS = {
        NORMAL = {},
        RECOVERY = { pet = 5, defensive = 3, resource = 5, buff = -5 },
        DEFENSIVE = { survival = 5, defensive = 10, escape = 0, cc = 5, pet = -5, resource = -5,
                      buff = -10, low = -10 },
        EMERGENCY = { survival = 15, bailout = 5, defensive = 15, escape = 10, cc = 10, threat = 5,
                      pet = -25, interrupt = -5, resource = -15, utility = -15, buff = -25, low = -30 },
        ESCAPE = { survival = 10, escape = 30, cc = 15, defensive = 5, threat = 10,
                   pet = -40, interrupt = -20, resource = -30, utility = -30, buff = -35, low = -40 },
    }
    local CONTEXT_MODS = {
        BOSS = { interrupt = 10, defensive = 5, threat = 10 },
        AOE = { cc = 5, threat = 5 },
        PVP = { cc = 10, interrupt = 5, escape = 5 },
    }
    M.MODE_MODS, M.CONTEXT_MODS = MODE_MODS, CONTEXT_MODS

    -- Categories that are an attack on something: not while holding fire,
    -- and not during a bail-out.
    local OFFENSIVE = { interrupt = true, buff = true, low = false }

    local CATEGORIES = {
        survival = true, bailout = true, interrupt = true, cc = true, escape = true,
        defensive = true, pet = true, threat = true, utility = true, buff = true, low = true,
        resource = true,
    }
    M.CATEGORIES = CATEGORIES

    -- The journal's levels, by what kind of line it is.
    local LEVEL = { state = "info", trigger = "info", bailout = "warn", reject = "debug",
                    retry = "debug", error = "warn", select = "debug", idle = "warn", learn = "info",
                    plan = "info" }
    M.LEVELS = LEVEL
    local JOURNAL_MAX = 60

    local EMPTY = {}
    local function clock() return core.time() end

    local engines = {}          -- owner -> engine
    local engine_order = {}

    --- A reaction engine for one owner. `ctx` is the owner's context handle
    --- (what JCore.register returns): the engine casts, subscribes, logs and
    --- reads spells and units through it, so every hook carries the owner.
    ---@param owner string
    ---@param ctx table
    ---@return table engine
    function M.new(owner, ctx)
        ctx = ctx or {}
        local E = { owner = owner, ctx = ctx }

        E.ROTATION_SCORE = M.ROTATION_SCORE
        E.MODE_MODS, E.CONTEXT_MODS, E.CATEGORIES = MODE_MODS, CONTEXT_MODS, CATEGORIES
        E.latch = L

        -- --- the hooks ------------------------------------------------------
        --
        -- What the consumer tells the engine about its world. Every one has
        -- a default that works against JCore alone (spell ids as names).

        local H = {
            -- The spellbook, by name: known(name), ready(name), id(name).
            -- The default takes a spell id for the name.
            spells = nil,
            -- What a spell is called, for the memory's rows.
            spell_name = nil,
            -- What kind of target a spell takes, from a catalogue: "self",
            -- "pet", "ally", "enemy" or nil when it does not say.
            target_kind = nil,
            -- Gates a press has to pass: a key held, a channel of it not
            -- running, and the consumer's own reasons (range, facing).
            key_allows = nil,
            channel_active = nil,
            press_blocked = nil,
            -- The consumer's own action kinds, beyond "spell" and "hold":
            -- kinds[kind] = { validate(c, W) -> why|nil, execute(c, W) -> ok, id,
            --   target_kind?, lane?, answer? ("arbiter" | "sent" | "done"),
            --   spell_named? (the candidate's name is a spell to know) }
            kinds = {},
            -- The arbiter band a rule's cast goes out in; by category otherwise.
            band = nil,
            -- The player's switches on the rules: false keeps a rule out.
            filter = nil,
            -- Mirror the journal's debug lines at info.
            explain = nil,
            -- The journal's lines, into a recorder's timeline.
            trace = nil,
            -- Where the journal's lines go. ctx.log by default.
            log = nil,
            -- After a client error (UI_ERROR_MESSAGE) is laid on an attempt
            -- of ours: on_refused(row, error_id, error_text).
            on_refused = nil,
            -- The units service to read guids and the player through;
            -- ctx.units by default.
            units = nil,
        }
        E.hooks = H

        local function units_svc() return H.units or ctx.units end

        local function unit_guid(unit)
            local units = units_svc()
            if unit == nil or not units or not units.guid then return nil end
            local ok, guid = pcall(units.guid, unit)
            return ok and guid or nil
        end

        local function spell_name(id)
            local fn = H.spell_name
            if not fn then
                local spells = ctx.spells
                fn = spells and spells.name
            end
            if type(fn) ~= "function" then return nil end
            local ok, n = pcall(fn, id)
            if ok and type(n) == "string" and n ~= "" then return n end
            return nil
        end

        -- The default spellbook: names are spell ids.
        local default_spells = {
            id = function(name) return tonumber(name) end,
            known = function(name)
                local id = tonumber(name)
                local spells = ctx.spells
                if not id or not spells or not spells.known then return false end
                local ok, yes = pcall(spells.known, id)
                return ok and yes == true
            end,
            ready = function(name)
                local id = tonumber(name)
                local spells = ctx.spells
                if not id or not spells or not spells.ready then return false end
                local ok, yes = pcall(spells.ready, id)
                return ok and yes == true
            end,
        }
        local function book() return H.spells or default_spells end

        local function logger()
            return H.log or ctx.log
        end

        -- --- the journal ----------------------------------------------------
        --
        -- Every state change, every reaction sent, every refusal and why,
        -- every bail-out start and end, every retry held back. Kept as a
        -- ring for the readouts and mirrored to the log -- at info for what
        -- changes the fight, at debug for refusals unless `explain` says
        -- every decision.

        local journal_rows, journal_seen = {}, {}

        local function explain_on()
            local fn = H.explain
            if type(fn) ~= "function" then return false end
            local ok, yes = pcall(fn)
            return ok and yes == true
        end

        --- Would a line under this throttle key be kept right now? Asked
        --- before formatting one, so a refusal repeated every frame costs no
        --- string.
        ---@param key string
        ---@return boolean
        function E.journal_due(key)
            local last = journal_seen[key]
            return not last or (clock() - last) >= 3.0
        end

        ---@param kind string state | trigger | bailout | reject | retry | error | select | idle | learn | plan
        ---@param text string
        ---@param key? string throttle: one line per key per 3s
        function E.journal(kind, text, key)
            local now = clock()
            if key then
                local last = journal_seen[key]
                if last and (now - last) < 3.0 then return end
                journal_seen[key] = now
            end
            journal_rows[#journal_rows + 1] = { at = now, kind = kind, text = text }
            if #journal_rows > JOURNAL_MAX then table.remove(journal_rows, 1) end
            local level = LEVEL[kind] or "debug"
            if H.trace and level ~= "debug" then pcall(H.trace, "react " .. kind .. ": " .. text) end
            if level == "debug" and explain_on() then level = "info" end
            local log = logger()
            if log and log.fmt then log.fmt(level, "react %s: %s", kind, text) end
        end
        local journal = E.journal

        --- The journal's rows, oldest first.
        ---@return table[]
        function E.journal_rows() return journal_rows end

        --- The journal, newest first.
        ---@param n integer
        ---@return string[]
        function E.log_lines(n)
            local out, now = {}, clock()
            for i = #journal_rows, math.max(1, #journal_rows - (n or 10) + 1), -1 do
                local row = journal_rows[i]
                out[#out + 1] = string.format("%5.1fs  [%s] %s", now - row.at, row.kind, row.text)
            end
            if #out == 0 then out[1] = "(nothing yet)" end
            return out
        end

        -- --- the memory -----------------------------------------------------

        local memory = M.new_memory(clock, spell_name)
        E.memory = memory

        --- Declares a one-per-caster debuff (Hunter's Mark): the memory
        --- tracks where it was last confirmed.
        ---@param name string
        function E.unique(name) memory.unique[name] = true end

        -- --- the rule registry ----------------------------------------------

        local rules, by_name = {}, {}
        local next_eval = {}            -- rule -> earliest time it is asked again
        local owned = {}                -- spell name -> rule that owns casting it
        local errors = {}               -- rule name -> consecutive failures
        local order_seq = 0
        local woken = {}                -- event -> true once subscribed
        local attached = false
        local fired_total, decided_total = 0, 0

        --- The player's switches on the rules: false keeps a rule out,
        --- whatever its own gate says. A field, so a consumer may set it
        --- directly or through configure({ filter = ... }).
        E.filter = nil

        local function filtered_out(def, W)
            local f = E.filter or H.filter
            if not f then return false end
            local ok, yes = pcall(f, def, W)
            return ok and yes == false
        end

        --- Is the rule switched on? Its own switch, the player's, then its
        --- setting gate.
        local function enabled(def, W)
            if def.disabled then return false end
            if filtered_out(def, W) then return false end
            local gate = def.enabled
            if gate == nil then return true end
            if type(gate) == "function" then
                local ok, yes = pcall(gate, W)
                return ok and yes == true
            end
            return gate == true
        end

        --- Forces a rule to be asked on the next tick, whatever its interval.
        ---@param def table
        function E.wake(def)
            next_eval[def] = 0
        end

        -- A rule that waits on an interval is asked at once when the thing
        -- it answers happens. Subscribed per event, once.
        local function wire_wake(event)
            if woken[event] or type(ctx.on) ~= "function" then return end
            woken[event] = true
            ctx.on(event, function()
                for j = 1, #rules do
                    local d = rules[j]
                    for _, e in ipairs(d.wake or {}) do
                        if e == event then E.wake(d) end
                    end
                end
            end)
        end

        local attach   -- defined with the event wiring, below

        --- Adds a reaction. See the file comment for the shape.
        ---@param def table
        ---@return table def
        function E.add_rule(def)
            assert(type(def) == "table" and type(def.name) == "string", "a reaction needs a name")
            assert(type(def.priority) == "number", def.name .. ": a reaction needs a base priority")
            assert(type(def.propose) == "function" or type(def.condition) == "function",
                def.name .. ": a reaction needs propose() or condition()")
            def.category = def.category or "utility"
            assert(CATEGORIES[def.category], def.name .. ": unknown category " .. tostring(def.category))
            def.lane = def.lane or "gcd"
            assert(def.lane == "gcd" or def.lane == "fast" or def.lane == "pet",
                def.name .. ": lane must be gcd, fast or pet")
            def.retry = def.retry or {}
            if def.offensive == nil then def.offensive = OFFENSIVE[def.category] == true end

            if by_name[def.name] then E.remove_rule(def.name) end
            order_seq = order_seq + 1
            def.order = order_seq
            rules[#rules + 1] = def
            by_name[def.name] = def
            if type(def.owns) == "table" then
                for i = 1, #def.owns do owned[def.owns[i]] = def end
            end
            for _, event in ipairs(def.wake or {}) do wire_wake(event) end
            attach()
            return def
        end

        ---@param name string
        function E.remove_rule(name)
            local def = by_name[name]
            if not def then return end
            by_name[name] = nil
            for i = #rules, 1, -1 do
                if rules[i] == def then table.remove(rules, i) end
            end
            for spell, holder in pairs(owned) do
                if holder == def then owned[spell] = nil end
            end
            next_eval[def] = nil
        end

        ---@param name string
        ---@param on boolean
        function E.set_enabled(name, on)
            local def = by_name[name]
            if def then def.disabled = not on end
        end

        ---@param name string
        ---@return table|nil
        function E.rule(name) return by_name[name] end

        ---@return table[]
        function E.rules() return rules end

        --- Does a reaction own this spell? A rotation rule or another module
        --- that would cast the same spell on its own clock stands aside: two
        --- owners with two lockouts cast it twice as often as either intends.
        ---@param spell string
        ---@param W? table
        ---@return boolean
        function E.owns(spell, W)
            local def = owned[spell]
            if not def or def.disabled then return false end
            if filtered_out(def, W) then return false end
            if def.enabled == nil or def.enabled == true then return true end
            if type(def.enabled) == "function" then
                local ok, yes = pcall(def.enabled, W)
                return ok and yes == true
            end
            return false
        end

        --- A channel of ours that should give way now: the rule that owns the
        --- spell has a yield(W, spell), and it says standing still any longer
        --- would get us killed. Asked only while something is being cast.
        ---@param W table
        ---@return table|nil { name, why, rule }
        function E.yielding(W)
            local pl = W.player or EMPTY
            if not pl.busy then return nil end
            local active = H.channel_active
            if type(active) ~= "function" then return nil end
            for spell, def in pairs(owned) do
                if def.yield and not def.disabled and active(spell) then
                    local ok, why = pcall(def.yield, W, spell)
                    if ok and why then return { name = spell, why = why, rule = def.name } end
                end
            end
            return nil
        end

        local function due(def, now)
            local every = def.every or 0
            if every <= 0 then return true end
            if now < (next_eval[def] or 0) then return false end
            next_eval[def] = now + every
            return true
        end

        local function needs_ok(def, W)
            local needs = def.needs
            if not needs then return true end
            local pl, pet, tg, grp, en = W.player or EMPTY, W.pet or EMPTY, W.target or EMPTY,
                W.group or EMPTY, W.enemies or EMPTY
            for i = 1, #needs do
                local need = needs[i]
                if need == "combat" then
                    if not pl.in_combat then return false end
                elseif need == "pet" then
                    if not pet.alive then return false end
                elseif need == "target" then
                    if not tg.unit then return false end
                elseif need == "group" then
                    if not grp.in_group then return false end
                elseif need == "casting" then
                    if (en.casting_n or 0) == 0 and not tg.casting then return false end
                end
            end
            return true
        end

        -- --- candidates -----------------------------------------------------

        local CAND = {}
        CAND.__index = CAND

        --- Adds points, with the reason they were added. The readouts print
        --- these lines exactly.
        ---@param points number
        ---@param why string
        function CAND:add(points, why)
            if points == nil or points == 0 then return self end
            self.score = self.score + points
            self.reasons[#self.reasons + 1] = { points, why }
            return self
        end

        --- Marks the candidate as one to show but not to press yet.
        ---@param why string
        function CAND:wait(why)
            self.hold = why
            return self
        end

        local current_def, current_W, cands = nil, nil, {}

        local function target_for(kind, W)
            if kind == "self" then return (W.player or EMPTY).unit end
            if kind == "pet" then return (W.pet or EMPTY).unit end
            if kind == "enemy" then return (W.target or EMPTY).unit end
            return nil
        end

        local function kind_spec(kind)
            local k = H.kinds and H.kinds[kind]
            return type(k) == "table" and k or EMPTY
        end

        --- What a rule's propose() calls, once per action it wants considered.
        ---@param spec table { name, kind?, target?, target_kind?, event_key?, handled_for?, why?, lane?, item?, channel?, offensive?, position?, cast_time? }
        ---@return table candidate
        local function offer(spec)
            local def, W = current_def, current_W
            local kind = spec.kind or def.kind or "spell"
            local ks = kind_spec(kind)
            -- A SPELL YOU HAVE NOT LEARNED IS NOT A CANDIDATE. It used to be
            -- offered and then refused at validation ("not trained"): never
            -- pressed, but listed, refused in the readouts and written to
            -- the journal -- which reads as the engine trying spells that are
            -- not in your spellbook. The rule still gets a candidate to fill
            -- in; it just never joins the list.
            if (kind == "spell" or ks.spell_named) and not book().known(spec.name or def.name) then
                return setmetatable({ rule = def, name = spec.name or def.name, kind = kind, score = 0,
                    reasons = {}, dropped = "not learned" }, CAND)
            end
            local target_kind = spec.target_kind or def.target_kind
                or (type(def.target) == "string" and def.target)
                or ks.target_kind or (kind == "hold" and "none") or "enemy"
            local target = spec.target
            if target == nil and kind ~= "hold" then
                if type(def.target) == "function" then
                    local ok, unit = pcall(def.target, W)
                    target = ok and unit or nil
                else
                    target = target_for(target_kind, W)
                end
            end
            local c = setmetatable({
                rule = def,
                name = spec.name or def.name,
                kind = kind,
                item = spec.item,
                target = target,
                target_kind = target_kind,
                target_guid = target and unit_guid(target) or nil,
                -- A kind with its own global cooldown (an order to the pet)
                -- never takes the player's lane, and never stops a rotation.
                lane = spec.lane or ks.lane or def.lane,
                event_key = spec.event_key,
                handled_for = spec.handled_for or def.handled_for,
                why = spec.why,
                channel = spec.channel or def.channel or false,
                cast_time = spec.cast_time or 0,
                -- A ground-targeted spell's spot; its target_kind is "ground".
                position = spec.position,
                offensive = (spec.offensive == nil) and def.offensive or spec.offensive,
                score = def.priority,
                reasons = { { def.priority, "base: " .. def.name } },
                order = def.order * 100 + #cands,
            }, CAND)
            cands[#cands + 1] = c
            return c
        end
        E.offer = offer

        --- The simple rule shape: condition(W) and an action, which may be a
        --- name, a list of names (the first ready one is used), or a function
        --- returning either.
        local function simple_propose(def, W)
            if def.condition and not def.condition(W) then return end
            local action = def.action
            if type(action) == "function" then action = action(W) end
            if action == nil then return end
            local names = type(action) == "table" and action or { action }
            local B = book()
            local pick, first_known = nil, nil
            for i = 1, #names do
                local name = names[i]
                if (def.kind or "spell") ~= "spell" or B.known(name) then
                    first_known = first_known or name
                    if (def.kind or "spell") ~= "spell" or B.ready(name) then pick = name break end
                end
            end
            pick = pick or first_known
            if not pick then return end
            offer({ name = pick })
        end

        -- --- safety validation ----------------------------------------------

        local function can_attack(W, unit)
            local player = (W.player or EMPTY).unit
            if not player or not unit then return false end
            local ok, yes = pcall(player.can_attack, player, unit)
            return ok and yes == true
        end

        local function alive(unit)
            if not unit then return false end
            local ok_v, valid = pcall(unit.is_valid, unit)
            if not ok_v or valid ~= true then return false end
            local ok_d, dead = pcall(unit.is_dead, unit)
            return not (ok_d and dead == true)
        end

        --- Why this candidate must not be executed now, or nil when it may.
        ---@param c table
        ---@param W table
        ---@return string|nil
        function E.validate(c, W)
            local def = c.rule
            if c.kind == "hold" then return nil end
            local pl, pet, tg = W.player or EMPTY, W.pet or EMPTY, W.target or EMPTY

            -- The engine's own refusals: the moment, and the memory.
            if c.offensive and W.bailout and not W.fight_on then return "bail-out: no attacks" end
            if c.offensive and W.hold_fire and c.target ~= nil and c.target == tg.unit then
                return "holding fire: target not engaged"
            end
            local handled, note, left = memory.handled(c.event_key)
            if handled then
                return string.format("already handled (%s, %.1fs)", note or c.event_key, left)
            end
            local hold = def.retry.hold or 0
            if hold > 0 then
                local since = memory.since(c.name)
                if since < hold then
                    local waiting = memory.waiting(c.name, c.target_guid)
                    return string.format("%s %.1fs ago, %s", c.name, since,
                        waiting and "waiting for the result" or "holding before another")
                end
            end
            local fails, backoff_left, last_why = memory.failures(c.name)
            if backoff_left > 0 then
                return string.format("failed %d time(s) (%s); retry in %.1fs",
                    fails, last_why or "?", backoff_left)
            end

            -- The target.
            local t, tk = c.target, c.target_kind
            if tk == "enemy" then
                if not t or t == pl.unit then return "no enemy target (would self-cast)" end
                if not alive(t) then return "target is gone" end
                if not can_attack(W, t) then return "target is not hostile" end
            elseif tk == "self" then
                if t ~= pl.unit then return "self-cast aimed elsewhere" end
            elseif tk == "pet" then
                if not pet.alive or t ~= pet.unit then return "no pet" end
            elseif tk == "ally" then
                if not alive(t) then return "ally is gone" end
                if can_attack(W, t) then return "ally target is hostile" end
            end

            if c.kind == "spell" then
                local B = book()
                if not B.known(c.name) then return "not trained" end
                local says = H.target_kind and H.target_kind(c.name) or nil
                if says == "self" and tk == "enemy" then return "catalogue: self-only, not cast on an enemy" end
                if says == "enemy" and tk == "self" then return "catalogue: needs an enemy, refusing to self-cast" end
                if H.key_allows and not H.key_allows(c.name) then return "its key is not held" end
                if not B.ready(c.name) then return "not ready (cooldown or resources)" end
                if H.channel_active and H.channel_active(c.name) then return "its channel is running" end
                if H.press_blocked then
                    local why = H.press_blocked(c.name, W.s, t)
                    if why then return why end
                end
                -- Our last cast is still on its way: anything not clearly
                -- more important waits for it rather than cutting it off.
                local p = W.pending
                if c.lane == "gcd" and p and c.score < (p.score or 0) + 10 then
                    return string.format("waiting for %s to start", p.name)
                end
                -- Busy with something more important: the cast in progress
                -- is a reaction of ours that scored higher.
                if c.lane == "gcd" and pl.busy then
                    local row = memory.in_progress(pl.casting_id)
                    -- A channel that gives way (E.yielding) may be cut by
                    -- anything that beats the rotation.
                    local gives_way = W.yield ~= nil and (row == nil or row.name == W.yield.name)
                    if row and not gives_way and c.score < (row.score or 0) + 10 then
                        return string.format("busy: %s (score %d) in progress", row.name, floor((row.score or 0) + 0.5))
                    end
                    if pl.casting_id and pl.casting_id == B.id(c.name) then
                        return "already casting it"
                    end
                end
            else
                local ks = kind_spec(c.kind)
                if ks.validate then
                    local ok, why = pcall(ks.validate, c, W)
                    if not ok then return "validate raised: " .. tostring(why) end
                    if why then return why end
                elseif ks == EMPTY then
                    return "unknown action kind " .. tostring(c.kind)
                end
            end
            if tk == "ground" and not c.position then return "no spot to cast it on" end

            if def.validate then
                local ok, why = pcall(def.validate, W, c)
                if not ok then return "validate raised: " .. tostring(why) end
                if why then return why end
            end
            return nil
        end

        -- --- execution ------------------------------------------------------

        local function band_for(def)
            if def.band then return def.band end
            if H.band then
                local ok, b = pcall(H.band, def)
                if ok and type(b) == "number" then return b end
            end
            local PR = ctx.PRIORITY or EMPTY
            local cat = def.category
            if cat == "survival" or cat == "bailout" or cat == "escape" or cat == "defensive" then
                return PR.EMERGENCY or 255
            end
            if cat == "interrupt" then return PR.INTERRUPT or 150 end
            if cat == "cc" then return PR.DEFENSIVE or 200 end
            if cat == "pet" or cat == "threat" or cat == "utility" or cat == "resource" then
                return PR.UTILITY or 100
            end
            if cat == "buff" then return (PR.ROTATION or 50) + 5 end
            return PR.FILLER or 30
        end
        E.band_for = band_for

        ---@param c table
        ---@param W table
        ---@return boolean sent
        function E.execute(c, W)
            local def = c.rule
            local reason = string.format("react: %s (%s)", c.name, def.name)
            local ok, id = false, nil
            local ks = kind_spec(c.kind)

            if c.kind == "spell" then
                id = book().id(c.name)
                if not id or type(ctx.cast) ~= "function" then return false end
                ctx.cast({
                    spell_id = id, target = c.target, position = c.position, priority = band_for(def),
                    reason = reason, fast = c.lane == "fast", direct = def.direct == true,
                })
                ok = true
            elseif ks.execute then
                local ran, sent, got_id = pcall(ks.execute, c, W)
                ok = ran and sent == true
                if ran then id = got_id end
            end
            if not ok then
                journal("reject", string.format("%s: the %s call did not go through", c.name, c.kind),
                    "exec:" .. c.name)
                return false
            end

            memory.attempt({
                name = c.name, id = id, kind = c.kind, target_guid = c.target_guid,
                event_key = c.event_key, rule = def.name, score = c.score, lane = c.lane,
                cast_time = c.cast_time, unique = def.unique == true, channel = c.channel,
                answer = ks.answer,
            })
            if c.event_key then
                local ttl = c.handled_for
                if type(ttl) == "function" then
                    local ok_ttl, value = pcall(ttl, W, c)
                    ttl = ok_ttl and value or nil
                end
                memory.handle(c.event_key, ttl or 2.0, def.name .. ": " .. c.name)
            end
            if def.on_execute then pcall(def.on_execute, W, c) end
            -- For the readouts: how often each reaction went out.
            def.fired_n = (def.fired_n or 0) + 1
            def.fired_at = W.now
            def.fired_name = c.name
            fired_total = fired_total + 1
            return true
        end

        -- --- one decision ---------------------------------------------------

        local function rule_error(def, err)
            errors[def.name] = (errors[def.name] or 0) + 1
            if errors[def.name] == 1 or errors[def.name] % 100 == 0 then
                journal("error", string.format("%s raised: %s", def.name, tostring(err)), "err:" .. def.name)
            end
        end

        local function by_score(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.order < b.order
        end

        --- Runs the pipeline up to (not including) execution.
        ---@param W table
        ---@return table decision { cands, gcd, fast, pet, deferred, holds, rejected }
        function E.decide(W)
            local now = W.now or clock()
            cands = {}
            current_W = W
            decided_total = decided_total + 1

            for i = 1, #rules do
                local def = rules[i]
                if enabled(def, W) and needs_ok(def, W) and due(def, now) then
                    current_def = def
                    local ok, err
                    if def.propose then
                        ok, err = pcall(def.propose, W, offer)
                    else
                        ok, err = pcall(simple_propose, def, W)
                    end
                    if not ok then rule_error(def, err) else errors[def.name] = nil end
                end
            end
            current_def = nil

            -- Score: the rule's own view, then the moment's, then the memory's.
            local mode_mods = MODE_MODS[W.mode or "NORMAL"] or EMPTY
            local ctx_mods = W.context and CONTEXT_MODS[W.context] or nil
            for i = 1, #cands do
                local c = cands[i]
                local def = c.rule
                if def.score then
                    local ok, err = pcall(def.score, W, c)
                    if not ok then rule_error(def, err) end
                end
                local m = mode_mods[def.category]
                if m then c:add(m, "mode " .. tostring(W.mode)) end
                if ctx_mods and ctx_mods[def.category] then
                    c:add(ctx_mods[def.category], "context " .. W.context)
                end
                if c.kind ~= "hold" then
                    local fails, backoff_left = memory.failures(c.name)
                    if backoff_left > 0 then
                        c:add(-50, string.format("failed %d time(s) recently", fails))
                    elseif fails > 0 then
                        c:add(-10 * fails, "failed recently")
                    end
                end
            end
            table.sort(cands, by_score)

            -- Select, per lane.
            local decision = { cands = cands, gcd = nil, fast = nil, pet = nil, deferred = nil,
                               holds = {}, rejected = {} }
            local tried = { gcd = 0, fast = 0, pet = 0 }
            -- One event, one answer: once a cast is being kicked in one lane,
            -- the pet's kick for the same cast in another lane stands down.
            local claimed = {}
            for i = 1, #cands do
                local c = cands[i]
                if c.kind == "hold" then
                    decision.holds[#decision.holds + 1] = c
                    c.state = "hold"
                elseif c.hold then
                    c.state, c.rejected = "waiting", c.hold
                elseif c.event_key and claimed[c.event_key] then
                    c.state = "answered by " .. claimed[c.event_key]
                elseif decision[c.lane] then
                    c.state = "outscored"
                elseif (tried[c.lane] or 0) >= VALIDATE_PER_LANE then
                    c.state = "not checked"
                else
                    tried[c.lane] = (tried[c.lane] or 0) + 1
                    local why = E.validate(c, W)
                    if why then
                        c.state, c.rejected = "rejected", why
                        decision.rejected[#decision.rejected + 1] = c
                    elseif c.score >= E.ROTATION_SCORE then
                        c.state = "selected"
                        decision[c.lane] = c
                        if c.event_key then claimed[c.event_key] = c.name end
                    elseif not decision.deferred and c.lane == "gcd" then
                        c.state = "deferred"
                        decision.deferred = c
                    else
                        c.state = "below the rotation"
                    end
                end
            end
            return decision
        end

        -- --- wiring the memory to the game ----------------------------------
        --
        -- Done once, the first time a rule is added (or configure is called),
        -- so a plugin that never reacts costs no subscriptions.

        local function is_ours(request)
            return not (owner and request.owner and request.owner ~= owner)
        end

        local function player_or_pet(args)
            return type(args) == "table" and (args[1] == "player" or args[1] == "pet")
        end

        local function my_guid()
            local units = units_svc()
            local player = units and units.player and units.player()
            return player and unit_guid(player) or nil
        end

        attach = function()
            if attached or type(ctx.on) ~= "function" then return end
            attached = true

            ctx.on("jcore.cast.sent", function(request)
                if type(request) ~= "table" or not request.spell_id or not is_ours(request) then return end
                memory.on_sent(request.spell_id, unit_guid(request.target), request.reason)
            end)

            ctx.on("jcore.game_event.UNIT_SPELLCAST_SUCCEEDED", function(args)
                if not player_or_pet(args) then return end
                memory.on_success(tonumber(args[3]))
            end)

            ctx.on("jcore.spell.cast", function(data)
                if type(data) ~= "table" or not data.spell_id then return end
                local mine = my_guid()
                if not mine then return end
                if data.caster and data.caster.get_guid then
                    local ok, guid = pcall(data.caster.get_guid, data.caster)
                    if ok and guid ~= mine then return end
                end
                memory.on_success(data.spell_id)
            end)

            -- FAILED carries no reason, and most of them are a queued press
            -- arriving a moment early: recorded, never counted towards a back-off.
            ctx.on("jcore.game_event.UNIT_SPELLCAST_FAILED", function(args)
                if not player_or_pet(args) then return end
                local row = memory.on_failure(tonumber(args[3]), "refused", true)
                if row then journal("reject", string.format("%s was refused by the client", row.name), "fail:" .. row.name) end
            end)

            ctx.on("jcore.game_event.UNIT_SPELLCAST_INTERRUPTED", function(args)
                if not player_or_pet(args) then return end
                memory.on_failure(tonumber(args[3]), "interrupted", true)
            end)

            ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
                if type(args) ~= "table" then return end
                -- Only an error that will repeat on the next press counts
                -- (out of range, not facing, no sight); "not ready yet"
                -- fixes itself.
                local soft = not memory.persistent_error(args[3])
                -- Which press it was, the client does not say: name the
                -- others sent with it, so a pet's refused Growl is not read
                -- as Auto Shot's.
                local also = {}
                for _, n in ipairs(memory.sent_recently(0.6)) do also[#also + 1] = n end
                local row = memory.on_failure(nil, tostring(args[3] or args[2] or "error"), soft)
                if not row then return end
                for i = #also, 1, -1 do
                    if also[i] == row.name then table.remove(also, i) end
                end
                journal("reject", string.format("client error after %s%s: %s", row.name,
                    #also > 0 and (" (or " .. table.concat(also, ", ") .. ", sent with it)") or "",
                    tostring(args[2] or args[3] or "error")), "uierr:" .. row.name)
                if H.on_refused then pcall(H.on_refused, row, args[3], args[2]) end
            end)

            ctx.on("jcore.game_event.UNIT_SPELLCAST_CHANNEL_START", function(args)
                if type(args) == "table" and args[1] == "player" then memory.on_channel(tonumber(args[3]), true) end
            end)
            ctx.on("jcore.game_event.UNIT_SPELLCAST_CHANNEL_STOP", function(args)
                if type(args) == "table" and args[1] == "player" then memory.on_channel(tonumber(args[3]), false) end
            end)

            ctx.on("jcore.combat.leave", function()
                memory.combat_end()
            end)
        end

        --- Tells the engine about the consumer's world. May be called more
        --- than once; each call sets the hooks it names and keeps the rest.
        ---@param hooks table see the hooks table above
        ---@return table engine
        function E.configure(hooks)
            for k, v in pairs(hooks or EMPTY) do
                if k == "kinds" and type(v) == "table" then
                    H.kinds = H.kinds or {}
                    for kind, spec in pairs(v) do H.kinds[kind] = spec end
                else
                    H[k] = v
                end
            end
            if hooks and hooks.filter ~= nil then E.filter = hooks.filter end
            attach()
            return E
        end

        --- Forgets the memory and the journal (a debug reset).
        function E.reset()
            memory.reset()
            journal_rows, journal_seen = {}, {}
        end

        --- Drops every rule. The owner's subscriptions go with the owner.
        function E.clear()
            for i = #rules, 1, -1 do E.remove_rule(rules[i].name) end
        end

        ---@return table
        function E.stats()
            local on = 0
            for i = 1, #rules do if not rules[i].disabled then on = on + 1 end end
            return {
                owner = owner, rules = #rules, enabled = on, fired = fired_total,
                decided = decided_total, handled = memory.handled_count(),
                last = memory.last_attempt and memory.last_attempt.name or nil,
                attached = attached,
            }
        end

        return E
    end

    --- The engine for an owner, built once. What ctx.react is.
    ---@param owner string
    ---@param ctx table
    ---@return table engine
    function M.for_owner(owner, ctx)
        local E = engines[owner]
        if E then return E end
        E = M.new(owner, ctx)
        engines[owner] = E
        engine_order[#engine_order + 1] = owner
        return E
    end

    --- Tears down an owner's engine with the owner (the registry calls it).
    ---@param owner string
    function M.remove_owner(owner)
        local E = engines[owner]
        if not E then return end
        E.clear()
        engines[owner] = nil
        for i = #engine_order, 1, -1 do
            if engine_order[i] == owner then table.remove(engine_order, i) end
        end
    end

    ---@return table[] every engine's stats, in the order they were made
    function M.engines()
        local out = {}
        for i = 1, #engine_order do
            local E = engines[engine_order[i]]
            if E then out[#out + 1] = E.stats() end
        end
        return out
    end

    ---@return { engines: integer, rules: integer, enabled: integer, fired: integer, decided: integer }
    function M.stats()
        local s = { engines = 0, rules = 0, enabled = 0, fired = 0, decided = 0 }
        for _, row in ipairs(M.engines()) do
            s.engines = s.engines + 1
            s.rules = s.rules + row.rules
            s.enabled = s.enabled + row.enabled
            s.fired = s.fired + row.fired
            s.decided = s.decided + row.decided
        end
        return s
    end

    return M
end

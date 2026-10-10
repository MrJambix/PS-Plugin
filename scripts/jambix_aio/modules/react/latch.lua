-- Jambix AIO / react / latch -- a threshold that does not chatter.
--
-- THE PROBLEM
-- A single line is crossed in both directions by noise. Health at 30% with a
-- defensive line at 30% reads "in trouble", "fine", "in trouble" on three
-- frames running, and everything that keys off it flips with it: the
-- behaviour state, the scores, the log. So every state here has TWO lines --
-- one to enter and a further one to leave -- and, where it matters, a
-- minimum time it holds once it has changed.
--
--   below = true   ON at value <= enter, OFF again only at value >= exit
--   below = false  ON at value >= enter, OFF again only at value <= exit
--
-- The lines can move between calls (an auto-tuned threshold does), so
-- update() takes them each time rather than freezing them at construction.

return function()
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
            since = -math.huge,     -- when it last changed
            value = nil,            -- the last value it was fed
            locked_exit = nil,      -- the exit line in force since it turned on
        }

        --- Feeds a value. Returns the state and whether it changed on this call.
        ---
        --- A MOVING LINE MUST NOT UNDO THE HYSTERESIS. An auto-tuned threshold
        --- can swing between ticks -- the pet-heal line follows how fast the
        --- pet is losing health, 10% one moment and 50% the next -- and an exit
        --- line that swings with it switched the latch off at 35% a second
        --- after it came on at 49% (the live log: four edges in four seconds).
        --- So the exit line is fixed at the moment the latch turns on, and may
        --- only move further away from the entry while it stays on.
        ---@param value number|nil nil leaves the state alone
        ---@param now number
        ---@param enter? number this call's entry line, when it moves
        ---@param exit? number this call's exit line
        ---@return boolean on
        ---@return boolean changed
        function self.update(value, now, enter, exit)
            if enter then self.enter = enter end
            if exit then self.exit = exit end
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
            since = -math.huge,
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

    return L
end

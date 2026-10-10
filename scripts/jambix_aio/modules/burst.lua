-- Jambix AIO / burst -- when to spend the big cooldowns, and in what order.
--
-- WHAT WAS WRONG
-- Every class file gated its cooldowns on `s.ttd > 15`, or 20, or 25 --
-- numbers I picked, differing between classes for no reason anyone could
-- state. Worse, nothing coordinated them: Recklessness, a trinket and a racial
-- were three independent rules that happened to be in the same list, so they
-- fired on three different ticks across three different mobs and multiplied
-- nothing. Bursting is the one thing in a rotation where ORDER and OVERLAP are
-- the whole point, and there was no code that knew that.
--
-- WHEN A BURST IS WORTH IT
-- A cooldown spent is only wasted if the fight would have been won anyway or
-- lost anyway. So the question is never "is this mob big" -- it is whether
-- spending changes an outcome:
--
--   1. The fight must LAST long enough to use the window. That is not a taste
--      either: it is the buff's own duration against the target's measured
--      time to die. A twenty-second buff on a mob with four seconds left is
--      sixteen seconds of nothing.
--
--   2. It must CHANGE something. Three ways it can:
--        * we are losing the race and killing faster is the way out of it;
--        * the fight is long enough that the cooldown comes back before the
--          next one anyway, which makes holding it a pure loss;
--        * there are enough enemies that clearing sooner means taking less
--          damage in total.
--
--   3. We must be ABLE to follow through. A burst window on an empty mana bar
--      is a buff ticking away over a wand.
--
-- HOW TO BURST
-- Ramp first, spend second, and get everything into the same window. The class
-- module supplies an ordered list and says which entries are ramp; this module
-- fires the ramp abilities off the global cooldown lane so they cost no
-- damage, pulls trinkets and offensive racials into the same few seconds, and
-- then holds the window open so the class's own burst rules can see it.
--
-- The window is a STATE, not an instant, which is what lets the priority list
-- behave differently for its duration instead of each rule re-deciding.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    local book = P.spellbook

    local M = {}

    local window_until = 0
    local window_opened = 0
    local window_reason = ""
    local last_attempt = 0
    local window_closed_at = 0

    -- Real cooldowns are minutes apart, so a second window opening seconds
    -- after the first has closed is the arbitration stuttering rather than a
    -- decision. It also means the trinket and the racial get spent twice for
    -- one fight, which is the opposite of what a window is for.
    local REOPEN_AFTER = 20.0
    local fired = {}              -- name -> time, within this window
    local ramp_index = 1

    -- A window that never closes is just "always burst". Six seconds is the
    -- floor; the real length comes from the longest ramp buff we actually
    -- managed to fire, so a class with a fifteen-second cooldown gets fifteen.
    local MIN_WINDOW = 6.0
    local MAX_WINDOW = 30.0

    -- --- is it worth it -----------------------------------------------------

    --- How long the window needs the fight to last to pay for itself.
    ---
    --- Derived from the ramp abilities' own buff durations where the client
    --- will say, and from the window floor otherwise. Nothing here is a
    --- per-class number: a warrior and a mage get different answers because
    --- their cooldowns are different lengths, which is the actual reason.
    ---@param class_module table
    ---@return number seconds
    function M.needed_fight_length(class_module)
        local list = class_module and class_module.burst or nil
        if not list then return MIN_WINDOW end

        local longest = 0
        for i = 1, #list do
            local entry = list[i]
            local seconds = entry.duration
            if type(seconds) == "number" and seconds > longest then
                longest = seconds
            end
        end
        if longest <= 0 then return MIN_WINDOW end

        -- Half the buff is the bar, not all of it: a fifteen-second
        -- Recklessness on a mob with nine seconds left is still most of the
        -- value, and demanding the full duration means never using it while
        -- levelling.
        local needed = math.max(MIN_WINDOW, longest * 0.5)

        -- A class that opens by applying a set of damage-over-time spells
        -- needs longer still, and for a different reason: those global
        -- cooldowns are spent on damage that arrives LATER. Four DoTs is six
        -- seconds of setup, and a fight that ends in eight has been fought
        -- almost entirely in setup. Twice the ramp is the bar.
        local helpers = P.rotation and P.rotation.helpers
        if helpers and helpers.dot_names then
            local ok, dots = pcall(helpers.dot_names)
            if ok and type(dots) == "table" and #dots > 0 then
                needed = math.max(needed, #dots * 1.5 * 2)
            end
        end

        return needed
    end

    --- Should a burst window open right now?
    ---
    --- Returns the reason as well, because a rotation that does something
    --- expensive should be able to say why on the readout.
    ---@param s table the situation snapshot
    ---@param class_module table
    ---@return boolean
    ---@return string reason
    function M.should_open(s, class_module)
        -- No switch (1.39.0): whether a window is worth it is the question
        -- below, from the fight -- the same as the racials always were.
        if not s.in_combat or not s.target then return false, "not fighting" end
        if not class_module then return false, "no class" end

        -- Never into a fight we are about to leave. The escape needs the
        -- global cooldowns more than the damage does.
        local field = P.field
        if field and field.plan() == "FLEE" then
            return false, "breaking contact"
        end

        -- Not into crowd control that damage breaks, nor a bubble (1.7.6):
        -- the window would tick away while nothing may hit the target. The
        -- PvP hunter's trap opener presses Rapid Fire itself, at the moment
        -- it breaks the trap.
        local react = P.react
        if react and react.out_of_fight then
            local ok, held = pcall(react.out_of_fight, s.target)
            if ok and held == true then return false, "the target is held by crowd control" end
        end

        -- 1. Will the fight last?
        local needed = M.needed_fight_length(class_module)
        local lasting = s.ttd
        if field then
            -- Against several enemies the window covers the whole pack, not
            -- just whatever is targeted, so the clear time is the honest
            -- measure of how long there is something to hit.
            local clear = field.time_to_clear()
            if clear < math.huge and (lasting >= math.huge or clear > lasting) then lasting = clear end
        end
        -- An unmeasured fight is not a long one. The time to die reads
        -- infinite until the mob has lost health for a moment, and taking
        -- that as "it will last" opened a window on the first second of
        -- every pull -- logged as an "infs fight" -- including the ones over
        -- in ten. A second or two of damage is all the answer needs.
        if lasting >= math.huge then
            return false, "the fight's length is not measured yet"
        end
        if lasting < needed then
            return false, string.format(
                "fight is %.0fs, the window wants %.0fs", lasting, needed)
        end

        -- 3. Can we follow through? Checked before the reasons to burst,
        -- because an empty bar makes all of them moot.
        if s.power_max > 0 and (s.power / s.power_max) < P.tune("res_conserve_power", 35) then
            local class_power = (s.profile_power or class_module.power)
            if class_power == "MANA" then
                return false, "not enough mana to use the window"
            end
        end

        -- 2. Would it change anything?
        if field and not field.winning() then
            return true, "losing the race -- kill it faster"
        end

        local count = field and select(1, field.counts()) or 1
        if count >= 3 then
            return true, string.format(
                "%d on us -- clearing sooner is less damage taken", count)
        end

        if field and field.elites() > 0 then
            return true, "elite -- this fight is long enough to matter"
        end

        -- The levelling case, and the most common one. A three-minute cooldown
        -- against fights every half a minute comes back before it is wanted
        -- again, so holding it is not patience, it is waste. The bar for this
        -- is simply that the fight is long enough, which was checked above.
        if P.opt("rot_burst_freely", true) then
            return true, string.format("%.0fs fight and the cooldown is up", lasting)
        end

        return false, "saving it for something bigger"
    end

    -- --- the window ---------------------------------------------------------

    ---@return boolean
    function M.open()
        return core.time() < window_until
    end

    ---@return number seconds remaining, 0 when closed
    function M.remaining()
        return math.max(0, window_until - core.time())
    end

    --- How long this window was opened for in total, so a caller can work out
    --- how far into it we are.
    ---@return number
    function M.window_length()
        if not M.open() then return 0 end
        return window_until - window_opened
    end

    ---@return string
    function M.reason()
        return M.open() and window_reason or ""
    end

    --- Is an open window still the right thing to be doing?
    ---
    --- Deliberately a shorter list than should_open: a window that has already
    --- started has sunk its ramp abilities, so the bar for abandoning it is
    --- higher than the bar for not starting. Only the things that make the
    --- REMAINDER worthless count.
    ---@param s table
    ---@param class_module table
    ---@return boolean
    ---@return string reason
    function M.still_valid(s, class_module)
        if not s.in_combat then return false, "combat ended" end

        local field = P.field
        if field and field.plan() == "FLEE" then
            return false, "breaking contact"
        end

        -- Nothing left worth hitting. The target check alone is not enough,
        -- because a pack fight replaces the target as each one dies.
        local lasting = s.target and s.ttd or 0
        if field then
            local clear = field.time_to_clear()
            if clear < math.huge and clear > lasting then lasting = clear end
            if select(1, field.counts()) == 0 then
                return false, "nothing left engaged"
            end
        end
        if lasting < 2 then return false, "the fight is over" end

        -- The bar that was going to pay for this has emptied.
        local class_power = (s.profile_power or (class_module and class_module.power))
        if class_power == "MANA" and s.power_max > 0 then
            if (s.power / s.power_max) < P.tune("res_critical_power", 10) then
                return false, "out of mana to spend"
            end
        end

        return true, ""
    end

    --- Extends the window to cover a buff we just fired.
    local function hold_for(seconds)
        local now = core.time()
        local until_time = now + math.max(MIN_WINDOW, math.min(MAX_WINDOW, seconds or 0))
        if until_time > window_until then window_until = until_time end
    end

    --- Fires the next ramp ability, one per tick.
    ---
    --- ONE PER TICK ON PURPOSE. Several of these are off the global cooldown
    --- and the cast service will happily take them all in one frame, but the
    --- client will not: a queue of six instant buffs in a single frame is how
    --- half of them get dropped. Spreading them over consecutive ticks costs
    --- a fraction of a second and lands all of them.
    ---@param class_module table
    ---@param s table
    ---@return boolean fired
    local function ramp(class_module, s)
        local list = class_module.burst
        if not list then return false end

        while ramp_index <= #list do
            local entry = list[ramp_index]
            ramp_index = ramp_index + 1

            local name = entry.spell or entry[1]
            if name and not fired[name] then
                -- `when` lets a class veto its own entry -- a stance
                -- requirement, a talent, a resource floor.
                local allowed = true
                if type(entry.when) == "function" then
                    local ok, verdict = pcall(entry.when, s)
                    allowed = ok and verdict == true
                end

                if allowed and book.ready(name) then
                    fired[name] = core.time()
                    hold_for(entry.duration)
                    ctx.cast({
                        spell_id = book.id(name),
                        target = entry.self ~= false and s.player or s.target,
                        priority = ctx.PRIORITY.COOLDOWN,
                        reason = "burst: " .. name,
                        -- Ramp is off the global cooldown lane so it does not
                        -- displace the damage it is meant to amplify.
                        fast = entry.fast ~= false,
                    })
                    return true
                end
            end
        end
        return false
    end

    -- --- trinkets and racials, inside the window ----------------------------
    --
    -- These used to be independent rules on their own timers, which meant a
    -- trinket could fire on one mob and a racial on the next and neither ever
    -- overlapped the class cooldowns they exist to multiply. They now belong
    -- to the window.

    local TRINKET_SLOTS = { 13, 14 }
    local last_trinket = 0
    local kept_said = {}

    --- A trinket that breaks control (the Insignia, Season of Discovery's
    --- PvP Trinket) is the answer to the stun that loses a fight, five
    --- minutes apart. Spent here for its nothing, it was gone when the stun
    --- came (1.81.0). react/pvp.lua knows which they are.
    local function kept_for_control(item_id, slot)
        local pvp = P.react and P.react.pvp
        if not (pvp and pvp.keeps) then return false end
        local ok, keep = pcall(pvp.keeps, item_id)
        if ok and keep then
            if not kept_said[item_id] then
                kept_said[item_id] = true
                log.fmt("info", "burst: the trinket in slot %d breaks crowd control -- kept for that", slot)
            end
            return true
        end
        return false
    end

    local function trinkets(s)
        local now = core.time()
        -- A second apart at most, so two trinkets do not go into the same
        -- frame; and once per slot per window, because pressing a trinket
        -- that is already active is not more of it.
        if (now - last_trinket) < 2 then return false end

        for i = 1, #TRINKET_SLOTS do
            local key = "trinket:" .. TRINKET_SLOTS[i]
            -- Written as a guard rather than folded into the condition below:
            -- pcall returns two values, and an `and/or` chain keeps only the
            -- first, which silently throws the row away.
            local ok, row = false, nil
            if fired[key] == nil then
                ok, row = pcall(s.player.get_item_at_inventory_slot,
                    s.player, TRINKET_SLOTS[i])
            end
            if ok and type(row) == "table" and row.object then
                local ok_id, item_id = pcall(row.object.get_item_id, row.object)
                if ok_id and item_id and item_id > 0 and not kept_for_control(item_id, TRINKET_SLOTS[i]) then
                    local ok_usable, usable = pcall(core.spell_book.is_item_usable, item_id)
                    local ok_cd, cooldown = pcall(s.player.get_item_cooldown, s.player, item_id)
                    if ok_usable and usable and (not ok_cd or (cooldown or 0) <= 0) then
                        last_trinket = now
                        fired[key] = now
                        pcall(core.input.use_item, item_id)
                        log.fmt("debug", "trinket in slot %d, inside the burst window",
                            TRINKET_SLOTS[i])
                        return true
                    end
                end
            end
        end
        return false
    end

    -- Resolved by NAME, so whichever one the character has is the one that
    -- exists and the rest simply do not -- no race detection needed.
    local OFFENSIVE_RACIALS = { "Blood Fury", "Berserking", "Arcane Torrent" }

    -- No switch of their own (1.32.0): inside a burst window -- which "Use
    -- offensive cooldowns" already governs -- the offensive racial goes in
    -- with the rest. The "anything to burst with" check below counts it on
    -- the same terms, so a window never opens for a racial nobody presses.
    local function racials(s)
        for i = 1, #OFFENSIVE_RACIALS do
            local name = OFFENSIVE_RACIALS[i]
            if not fired[name] and book.ready(name) then
                fired[name] = core.time()
                ctx.cast({
                    spell_id = book.id(name), target = s.player,
                    priority = ctx.PRIORITY.COOLDOWN,
                    reason = "racial, inside the burst window: " .. name,
                    fast = true,
                })
                return true
            end
        end
        return false
    end

    -- --- the entry point ----------------------------------------------------

    --- Called once per rotation tick, before the priority walk.
    ---@param class_module table
    ---@param s table
    ---@return boolean spent_the_tick
    function M.tick(class_module, s)
        local now = core.time()

        if M.open() then
            -- A WINDOW HAS TO KEEP EARNING ITSELF. It was opened on what was
            -- true a moment ago, and a fight changes: the mob dies, adds
            -- arrive and the plan becomes a retreat, the mana that was going
            -- to pay for it goes somewhere else. Checking only at the moment
            -- of opening meant a window that opened on a healthy pull kept
            -- feeding trinkets into a corpse, or into a retreat.
            local still, why = M.still_valid(s, class_module)
            if not still then
                log.fmt("debug", "burst window closed early: %s", why)
                window_reason = why
                M.reset()
                return false
            end

            -- Inside a window: finish the ramp, then stack the extras.
            if ramp(class_module, s) then return true end
            if racials(s) then return true end
            if trinkets(s) then return true end
            return false
        end

        -- A window that ran its course is closed as surely as one closed
        -- early. Only an early close used to start the reopen guard, so a
        -- window that simply expired opened again on the next second: the
        -- live log has "burst:" six seconds apart, three times in a row,
        -- each one a fresh set of trinket and racial presses.
        if window_until > 0 then
            window_closed_at = window_until
            window_until = 0
            ctx.emit("jambix.aio.burst", false, "window ran out")
        end

        -- Closed. Do not re-ask every frame; the answer needs a measured
        -- time-to-die that does not change meaningfully in a tenth of a second.
        if (now - last_attempt) < 1.0 then return false end
        last_attempt = now

        if window_closed_at > 0 and (now - window_closed_at) < REOPEN_AFTER then
            window_reason = string.format("%.0fs since the last window",
                now - window_closed_at)
            return false
        end

        local should, reason = M.should_open(s, class_module)
        if not should then
            window_reason = reason
            return false
        end

        -- Only actually open it if there is something to fire. Opening a
        -- window a class cannot use would change the priority list's behaviour
        -- for six seconds in exchange for nothing.
        local list = class_module.burst
        local anything = false
        if list then
            for i = 1, #list do
                local name = list[i].spell or list[i][1]
                if name and book.ready(name) then anything = true; break end
            end
        end
        -- A racial counts on the same terms the racial pass presses it.
        if not anything then
            for i = 1, #OFFENSIVE_RACIALS do
                if book.ready(OFFENSIVE_RACIALS[i]) then anything = true; break end
            end
        end
        if not anything then
            window_reason = "nothing to burst with"
            return false
        end

        fired = {}
        ramp_index = 1
        window_opened = now
        window_until = now + MIN_WINDOW
        window_reason = reason

        log.fmt("info", "burst: %s", reason)
        ctx.emit("jambix.aio.burst", true, reason)
        if P.narrate then
            P.narrate.say("action", "Cooldowns", reason, "burst")
        end

        return ramp(class_module, s)
    end

    --- Called when combat ends, so a window cannot leak into the next pull.
    function M.reset()
        if M.open() then
            ctx.emit("jambix.aio.burst", false, "combat ended")
            window_closed_at = core.time()
        end
        window_until, ramp_index, fired = 0, 1, {}
    end

    function M.stats()
        return {
            open = M.open(),
            remaining = M.remaining(),
            reason = window_reason,
            opened_at = window_opened,
            fired = (function()
                local out = {}
                for name in pairs(fired) do out[#out + 1] = name end
                table.sort(out)
                return out
            end)(),
        }
    end

    ctx.on("jcore.combat.leave", function() M.reset() end)

    return M
end

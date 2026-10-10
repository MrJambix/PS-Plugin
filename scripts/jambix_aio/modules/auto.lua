-- Jambix AIO / auto -- work the numbers out instead of asking for them.
--
-- WHY THIS EXISTS
-- Every threshold in this plugin used to be a slider with a number I picked.
-- "Life Tap needs health above 60%." Sixty percent of what, at what level,
-- against what? A level 12 warlock and a level 60 warlock have nothing in
-- common except the shape of the bar, and a number that is right for one is
-- wrong for the other. Worse, a slider is a guess the player is now
-- responsible for, and the plugin blames them when it dies.
--
-- The client knows the real numbers. It will tell us what a spell costs, how
-- long it takes to cast, how far it reaches, and how fast mana comes back. It
-- will also tell us, if we watch, how hard the thing hitting us hits. Every
-- threshold in this file is derived from those, per tick, at the level and
-- gear the character actually has.
--
-- THE SHAPE OF EVERY DERIVATION
-- A threshold is never a taste. It is always the answer to a question with a
-- unit attached:
--
--   "How low is too low on health?"  ->  the health needed to survive what is
--       currently hitting us for as long as this fight has left.
--   "How low is too low on mana?"    ->  the mana needed to finish this fight
--       at what our spells actually cost.
--   "Is this cast worth its mana?"   ->  compare the cost to the damage it
--       buys over the time the target will actually live.
--
-- WHAT HAPPENS WHEN THE CLIENT WILL NOT SAY
-- get_spell_costs can answer an empty table while data loads, and a fresh
-- character has no damage history. Every derivation therefore returns nil
-- rather than a guess, and the caller falls back to the slider -- which is
-- why the sliders still exist even though nothing normally reads them.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat

    local M = {}

    -- --- what the client will tell us directly ------------------------------

    local MANA = 0                 -- Enum.PowerType.Mana

    local cost_cache = {}          -- spell id -> { mana, per_sec } or false
    local cast_cache = {}          -- spell id -> seconds
    local range_cache = {}         -- spell id -> yards

    local function spell_id(name)
        local book = P.spellbook
        if not book then return nil end
        local ok, id = pcall(book.id, name)
        return ok and id or nil
    end

    --- Mana cost of a spell, in mana, straight from the client.
    ---
    --- Two shapes come back: an absolute `cost`, which is what Classic spells
    --- use, and a `cost_percent` of base mana, which is what later designs
    --- use. Both are handled, and a channel's `cost_per_sec` is carried
    --- separately because a channel's real cost is rate times duration.
    ---@param name string
    ---@return number|nil mana
    ---@return number|nil per_second
    function M.cost(name)
        local id = spell_id(name)
        if not id then return nil end

        local cached = cost_cache[id]
        if cached ~= nil then
            if cached == false then return nil end
            return cached.mana, cached.per_sec
        end

        local ok, rows = pcall(core.spell_book.get_spell_costs, id)
        if not ok or type(rows) ~= "table" or #rows == 0 then
            -- Not "free" -- not known yet. Do not cache a negative, because
            -- spell data loads asynchronously and this will answer later.
            return nil
        end

        for i = 1, #rows do
            local row = rows[i]
            if row and (tonumber(row.cost_type) or MANA) == MANA then
                local mana = tonumber(row.cost) or 0
                if mana <= 0 then
                    local percent = tonumber(row.cost_percent) or 0
                    if percent > 0 then
                        -- Percent is of BASE mana, which the client does not
                        -- expose separately. Max mana is the closest thing we
                        -- have and is exact for an unbuffed caster.
                        mana = (P.power_max("MANA") or 0) * percent / 100
                    end
                end
                local entry = { mana = mana, per_sec = tonumber(row.cost_per_sec) or 0 }
                cost_cache[id] = entry
                return entry.mana, entry.per_sec
            end
        end

        cost_cache[id] = false
        return nil
    end

    --- Cost as a fraction of our mana bar, which is the unit every threshold
    --- in this plugin actually wants.
    ---@param name string
    ---@return number|nil 0..1
    function M.cost_fraction(name)
        local mana, per_sec = M.cost(name)
        if not mana then return nil end

        local maximum = P.power_max("MANA")
        if not maximum or maximum <= 0 then return nil end

        -- A channel costs its per-second rate for its whole duration.
        if per_sec and per_sec > 0 then
            mana = mana + per_sec * (M.cast_time(name) or 0)
        end
        return mana / maximum
    end

    ---@param name string
    ---@return number|nil seconds
    function M.cast_time(name)
        local id = spell_id(name)
        if not id then return nil end
        if cast_cache[id] then return cast_cache[id] end

        local ok, seconds = pcall(core.spell_book.get_spell_cast_time, id)
        if not ok or type(seconds) ~= "number" then return nil end
        -- Zero is a real answer (an instant), so it is cached as such, but a
        -- zero from a client that has not loaded the spell is indistinguishable
        -- from an instant. Instants are common enough that treating zero as
        -- truth is the right call.
        cast_cache[id] = seconds
        return seconds
    end

    ---@param name string
    ---@return number|nil yards
    function M.range(name)
        local id = spell_id(name)
        if not id then return nil end
        if range_cache[id] then return range_cache[id] end

        local ok, yards = pcall(core.spell_book.get_spell_max_range, id)
        if not ok or type(yards) ~= "number" or yards <= 0 then return nil end
        range_cache[id] = yards
        return yards
    end

    --- Mana per second coming back on its own.
    ---@return number
    function M.regen()
        local casting = combat.in_combat()
        local fn = casting and core.spell_book.get_casting_power_regen
            or core.spell_book.get_base_power_regen
        if type(fn) ~= "function" then return 0 end
        local ok, rate = pcall(fn)
        if not ok or type(rate) ~= "number" or rate < 0 then return 0 end
        return rate
    end

    -- Spell data arrives asynchronously, so a cost that answered nil early
    -- must be asked again. Clearing on SPELLS_CHANGED also picks up a new rank.
    ctx.on("jambix.aio.spells_changed", function()
        cost_cache, cast_cache, range_cache = {}, {}, {}
    end)

    -- --- what we have to watch for ourselves --------------------------------
    --
    -- Nothing tells us how hard the thing in front of us hits. The health
    -- slope in modules/resources.lua does, though, and the peak of that slope
    -- over the last few seconds is a usable incoming-damage figure.

    local worst_incoming = 0       -- fraction of max health per second
    local worst_seen_at = 0
    local INCOMING_MEMORY = 10.0   -- seconds before the worst case is forgiven

    local function incoming()
        local res = P.resources
        if not res then return 0 end

        local rate = -res.hp_rate()
        local now = core.time()

        if rate > worst_incoming then
            worst_incoming, worst_seen_at = rate, now
        elseif (now - worst_seen_at) > INCOMING_MEMORY then
            -- Decay rather than reset: a pull that has calmed down should stop
            -- dominating the threshold, but forgetting it instantly makes the
            -- threshold oscillate between pulls.
            worst_incoming = worst_incoming * 0.5
            worst_seen_at = now
        end

        -- Out of combat nothing is hitting us and the memory is noise.
        if not combat.in_combat() then return 0 end
        return math.max(rate, worst_incoming)
    end

    M.incoming = incoming

    --- The observed health cost of a spell that is paid in health.
    ---
    --- Life Tap is the whole reason for this. Its cost is health, which
    --- get_spell_costs does not report, and it scales with rank and with
    --- Improved Life Tap. So it is MEASURED: remember the health bar when the
    --- cast goes out, compare a moment later, and keep the result.
    local observed_hp_cost = {}    -- spell name -> fraction of max health
    local watching = nil           -- { name, hp, at }

    --- Ask for the health cost of a spell to be measured on its next cast.
    ---@param name string
    function M.watch_health_cost(name)
        if observed_hp_cost[name] then return end
        if watching then return end
        local player = units.player()
        if not player then return end
        watching = { name = name, hp = units.health_fraction(player), at = core.time() }
    end

    ---@param name string
    ---@return number|nil fraction of max health
    function M.health_cost(name)
        return observed_hp_cost[name]
    end

    local function settle_measurement()
        if not watching then return end
        local player = units.player()
        if not player then watching = nil; return end

        local elapsed = core.time() - watching.at
        if elapsed < 0.6 then return end

        -- Longer than this and whatever changed the bar was probably not the
        -- spell. Throw the sample away rather than record a mob's hit as the
        -- cost of Life Tap.
        if elapsed > 2.5 then watching = nil; return end

        local name = watching.name
        local drop = watching.hp - units.health_fraction(player)
        watching = nil

        -- Only a drop counts, and only a plausible one: a rise means the cast
        -- never happened, and a huge drop means a mob hit us at the same time.
        if drop > 0.02 and drop < 0.60 then
            observed_hp_cost[name] = drop
            log.fmt("debug", "measured %s health cost: %.0f%%", name, drop * 100)
        end
    end

    -- --- the derivations ----------------------------------------------------
    --
    -- Keyed by the widget id they replace, so a caller asks for the same thing
    -- either way and the slider stays meaningful as a manual override.

    local derive = {}

    --- The filler this class leans on, for "what does a cast cost" questions.
    --- Read off the active profile rather than hard-coded, because the answer
    --- is Shadow Bolt for one class and Frostbolt for another.
    local function filler_name()
        local rot = P.rotation
        if not rot then return nil end
        local class_module = rot.active_class()
        if not class_module then return nil end
        local profile = rot.active_profile and rot.active_profile(class_module)
        if not profile or not profile.rules then return nil end

        -- The last GCD rule in the list is the filler by construction: a
        -- priority list ends with the thing you do when nothing better is
        -- available. That is what a filler IS.
        for i = #profile.rules, 1, -1 do
            local rule = profile.rules[i]
            local name = rule[1]
            if name and name ~= "Shoot" and not rule.fast then return name end
        end
        return nil
    end
    M.filler_name = filler_name

    --- How long the fight has left, from the resource module so there is one
    --- answer to the question.
    local function fight_left()
        local res = P.resources
        if not res then return 12 end
        local left = res.fight_left()
        if left == math.huge then return 0 end       -- no fight, no deadline
        return left
    end

    --- Health below which we are in real trouble.
    ---
    --- Not a taste. It is the health needed to survive what is currently
    --- hitting us for as long as this fight has left, plus one hit of margin.
    --- Against a caster that hits for a fifth of the bar this lands high;
    --- against a boar it lands low. Neither is a number anyone should have to
    --- choose.
    derive["res_critical_hp"] = function()
        local dps = incoming()
        if dps <= 0 then return nil end

        local horizon = math.min(math.max(fight_left(), 3), 8)
        local needed = dps * horizon

        -- One more hit of slack, on the reasoning that the measurement is a
        -- floor rather than a worst case.
        needed = needed * 1.35
        return math.max(0.12, math.min(0.50, needed))
    end

    --- Health below which we stop spending it on anything optional. Twice the
    --- critical line, because CONSERVE is meant to fire before the trouble.
    derive["res_conserve_hp"] = function()
        local critical = derive["res_critical_hp"]()
        if not critical then return nil end
        return math.max(0.30, math.min(0.75, critical * 2.0))
    end

    --- Mana below which we cannot cast anything meaningful again. Exactly one
    --- filler cast, because that is what "out of mana" means in practice.
    derive["res_critical_power"] = function()
        local name = filler_name()
        if not name then return nil end
        local cost = M.cost_fraction(name)
        if not cost then return nil end
        return math.max(0.03, math.min(0.25, cost * 1.5))
    end

    --- Mana below which we start conserving: not enough to finish this fight.
    ---
    --- Casts needed is the fight's remaining time divided by the time one cast
    --- takes, so this is "the mana this fight still wants", net of what
    --- regenerates while we cast it.
    derive["res_conserve_power"] = function()
        local name = filler_name()
        if not name then return nil end

        local cost = M.cost_fraction(name)
        if not cost then return nil end

        local cast = M.cast_time(name) or 0
        local gcd = 1.5
        local per_cast = math.max(cast, gcd)

        local left = fight_left()
        if left <= 0 then
            -- Out of combat the useful question is "enough for a pull", and a
            -- levelling pull is a handful of casts.
            left = 15
        end

        local casts = math.min(left / per_cast, 20)
        local needed = casts * cost

        local maximum = P.power_max("MANA")
        if maximum and maximum > 0 then
            local back = M.regen() * left / maximum
            needed = needed - back
        end

        return math.max(0.10, math.min(0.80, needed))
    end

    --- The health floor for trading health into mana. The critical line plus
    --- the cost of the trade plus what will land on us while it happens.
    derive["res_trade_floor_hp"] = function()
        local critical = derive["res_critical_hp"]()
        if not critical then return nil end
        local during = incoming() * 2.0        -- roughly a global cooldown and a half
        return math.max(0.25, math.min(0.85, critical + during + 0.10))
    end

    --- "Bleeding" is losing health fast enough that the bar will not last the
    --- fight. Expressed as a rate so the caller can compare it to a slope.
    derive["res_bleeding_rate"] = function()
        local left = fight_left()
        if left <= 0 then return nil end
        local res = P.resources
        if not res then return nil end
        -- The rate that empties the current bar exactly when the fight ends.
        return math.max(0.02, math.min(0.30, res.hp() / math.max(left, 1)))
    end

    -- --- ranges and durations ----------------------------------------------
    --
    -- The client knows how far a spell reaches. Asking the player to type a
    -- number into "target search range" was always a way of asking them to
    -- guess something the game already knows, and to get it wrong twice: too
    -- far and the rotation picks targets it cannot hit, too near and it
    -- ignores ones it can.

    --- How far this character can actually reach.
    ---
    --- Taken from the longest range among the abilities the active profile
    --- uses, because that is the real answer for a caster and for a melee
    --- class both -- a warrior's list tops out at Charge range and a mage's
    --- at thirty-odd yards, and neither needs to be told.
    derive["rot_target_range"] = function()
        local rot = P.rotation
        if not rot then return nil end
        local class_module = rot.active_class()
        if not class_module then return nil end
        local profile = rot.active_profile and rot.active_profile(class_module)
        if not profile or not profile.rules then return nil end

        local longest = 0
        for i = 1, #profile.rules do
            local yards = M.range(profile.rules[i][1])
            if yards and yards > longest then longest = yards end
        end
        if longest <= 0 then return nil end

        -- A little past the furthest thing we can do, so a target walking in
        -- is already being considered when it arrives.
        return math.max(8, math.min(60, longest + 5))
    end

    --- Healing reach, from the class's own heals rather than a flat forty.
    derive["rot_heal_range"] = function()
        local rot = P.rotation
        if not rot then return nil end
        local class_module = rot.active_class()
        if not class_module or not class_module.heals then return nil end

        local longest = 0
        for i = 1, #class_module.heals do
            local entry = class_module.heals[i]
            local name = type(entry) == "table" and (entry.spell or entry[1]) or entry
            local yards = name and M.range(name) or nil
            if yards and yards > longest then longest = yards end
        end
        if longest <= 0 then return nil end
        return math.max(10, math.min(60, longest))
    end

    --- The health at which a defensive is worth a global cooldown. The same
    --- question as "how low is too low", so the same answer -- two names for
    --- one number is how they drift apart.
    derive["rot_defensive_hp"] = function()
        return derive["res_critical_hp"]()
    end

    --- Stop hard-casting and let the wand carry once mana will not last the
    --- fight. Identical reasoning to the conserve line, and deliberately the
    --- same number.
    derive["rot_wand_below_mana"] = function()
        return derive["res_conserve_power"]()
    end

    --- The time a target must have left for a damage-over-time spell to be
    --- worth its mana.
    ---
    --- A DoT pays back over time, so the bar is "will it tick long enough to
    --- beat just casting the filler instead". That is the DoT's cost over the
    --- filler's cost, times the filler's cast time -- the number of filler
    --- casts the DoT is worth, converted back into seconds.
    derive["rot_rend_min_ttd"] = function()
        local filler = filler_name()
        if not filler then return nil end

        local filler_cost = M.cost_fraction(filler)
        local filler_cast = M.cast_time(filler)
        if not filler_cost or filler_cost <= 0 then return nil end
        if not filler_cast or filler_cast <= 0 then filler_cast = 1.5 end

        -- Averaged over the profile's damage-over-time spells rather than
        -- picked from one, because the answer feeds a shared helper.
        local rot = P.rotation
        local class_module = rot and rot.active_class()
        local profile = class_module and rot.active_profile
            and rot.active_profile(class_module)
        if not profile or not profile.rules then return nil end

        local total, seen = 0, 0
        for i = 1, #profile.rules do
            local rule = profile.rules[i]
            if rule.upkeep and rule.upkeep >= 2 and rule.upkeep <= 5 then
                local cost = M.cost_fraction(rule[1])
                if cost and cost > 0 then total = total + cost; seen = seen + 1 end
            end
        end
        if seen == 0 then return nil end

        local average = total / seen
        return math.max(3, math.min(25, (average / filler_cost) * filler_cast * 2))
    end

    -- --- the field ----------------------------------------------------------

    --- How much life we need left for running to still be an option.
    ---
    --- Not a taste: it is the time it takes to actually get away. That is the
    --- escape ability's own cast time plus a global cooldown to press it in,
    --- and a class whose only escape is a three-second Fear needs more runway
    --- than one that blinks.
    derive["rot_flee_runway"] = function()
        local rot = P.rotation
        local class_module = rot and rot.active_class()
        if not class_module or not class_module.escapes then return nil end

        local best = nil
        for i = 1, #class_module.escapes do
            local seconds = M.cast_time(class_module.escapes[i])
            if seconds then
                -- The best escape is the quickest one, because that is the
                -- one we will reach for first.
                if not best or seconds < best then best = seconds end
            end
        end
        if not best then return nil end

        -- The cast, the global cooldown to start it, and a second of running.
        return math.max(2, math.min(12, best + 1.5 + 1.0))
    end

    -- --- class-level derivations -------------------------------------------
    --
    -- Same idea, for the numbers a class file used to expose as sliders. The
    -- ids carry the class prefix, so these are looked up by suffix.

    local by_suffix = {}

    --- Mana counts as low when it will not finish the fight. Identical
    --- reasoning to res_conserve_power, and deliberately the same number:
    --- two names for one question is how they drift apart.
    by_suffix["mana_low"] = function()
        return derive["res_conserve_power"]()
    end

    --- Life Tap's health cost, measured if we have seen one, and otherwise
    --- derived from the fact that Classic's Life Tap converts health to mana
    --- at roughly one for one. That makes its health cost, as a fraction of
    --- the health bar, the mana it returns over the health bar's size.
    by_suffix["lifetap_cost_hp"] = function()
        local seen = M.health_cost("Life Tap")
        if seen then return seen end

        -- Life Tap reports no mana cost, so the client cannot help here. Fall
        -- back to the ratio of the two bars: a caster whose health pool is
        -- much smaller than its mana pool pays proportionally more.
        local player = units.player()
        if not player then return nil end
        local ok_hp, max_hp = pcall(player.get_max_health, player)
        if not ok_hp or not max_hp or max_hp <= 0 then return nil end

        local max_mana = P.power_max("MANA")
        if not max_mana or max_mana <= 0 then return nil end

        -- The tap returns about fifteen percent of a typical mana bar at any
        -- given level, and takes the same number in health.
        local tap = max_mana * 0.15
        return math.max(0.05, math.min(0.45, tap / max_hp))
    end

    --- Health floor for Life Tap: the shared trade floor.
    by_suffix["lifetap_min_hp"] = function()
        return derive["res_trade_floor_hp"]()
    end

    --- Drain Life is worth starting while it can still finish. Its own channel
    --- length is the deadline, and the client knows it.
    by_suffix["drainlife_hp"] = function()
        local critical = derive["res_critical_hp"]()
        if not critical then return nil end
        -- Start draining before the critical line, not at it, so the channel
        -- has somewhere to work from.
        return math.max(0.20, math.min(0.70, critical * 1.6))
    end

    --- Drain Life needs enough mana to be SUSTAINABLE, not enough for one
    --- cast. A single channel at the bottom of the bar buys a sliver of health
    --- and empties the mana that would have killed the mob -- which is the
    --- spiral, arriving by a different road. Three casts is the bar.
    by_suffix["drainlife_min_mana"] = function()
        local cost = M.cost_fraction("Drain Life")
        if not cost then return nil end
        return math.max(0.10, math.min(0.60, cost * 3))
    end

    by_suffix["drainlife_min_runway"] = function()
        local seconds = M.cast_time("Drain Life")
        -- Zero would make the runway check inert, and Drain Life is not an
        -- instant. A zero here means the client has not loaded the spell, so
        -- say nothing and let the slider answer.
        if not seconds or seconds <= 0 then return nil end
        return seconds
    end

    --- The execute window: how much health a target can have and still die
    --- inside a Drain Soul channel. Derived from the channel's own length and
    --- how fast the target is currently losing health.
    by_suffix["drainsoul_max_ttd"] = function()
        local seconds = M.cast_time("Drain Soul")
        -- ZERO IS NOT AN ANSWER HERE. Drain Soul is a channel, so a zero means
        -- the client has not loaded the spell rather than that it is instant --
        -- and a zero would make "will it die inside the channel" impossible to
        -- satisfy, which switches the whole execute window off silently.
        if not seconds or seconds <= 0 then return nil end
        return seconds
    end

    --- The health a target can have and still die INSIDE a Drain Soul channel.
    ---
    --- This is the one number that decides whether the mana refund is ever
    --- collected, and it is not a taste at all: it is how much of the target's
    --- bar we remove during one channel. Measured damage, measured bar.
    ---
    --- A warlock doing a fifth of a mob's health per second over a five second
    --- channel can start at nearly full and still land the killing tick; one
    --- chipping away at a tough elite has to wait until it is almost dead.
    --- Those are different numbers for the same character an hour apart, which
    --- is exactly why a slider was the wrong shape for it.
    by_suffix["drainsoul_hp"] = function()
        local channel = M.cast_time("Drain Soul")
        if not channel or channel <= 0 then return nil end

        local field = P.field
        if not field then return nil end

        local state = field.state
        if not state or state.my_dps <= 0 then return nil end

        -- What fraction of the CURRENT target's bar that damage represents.
        local player = units.player()
        local target = combat.target()
        if not player or not target then return nil end

        local ok, max_hp = pcall(target.get_max_health, target)
        if not ok or type(max_hp) ~= "number" or max_hp <= 0 then return nil end

        -- Drain Soul on its own ticks for less than a full rotation does, so
        -- the measured rate is an over-estimate of what the channel alone
        -- will manage. Two thirds keeps it honest, and starting slightly too
        -- late costs one wasted tick while starting too early costs the whole
        -- refund.
        local removable = (state.my_dps * channel * 0.66) / max_hp

        return math.max(0.05, math.min(0.45, removable))
    end

    --- Dark Pact wants enough pet mana to be worth a global cooldown: about
    --- what one filler cast costs us.
    by_suffix["darkpact_pet_mana"] = function()
        local cost = M.cost_fraction(filler_name() or "")
        if not cost then return nil end
        return math.max(0.05, math.min(0.60, cost * 3))
    end

    -- --- pet derivations ----------------------------------------------------

    --- Heal the pet when it has about five seconds of life left at the rate it
    --- is currently losing, not at a fixed percentage. A pet holding one mob
    --- and a pet holding three want very different numbers, and the difference
    --- shows up in the slope rather than in the bar.
    derive["pet_heal_hp"] = function()
        local pet = P.pet
        if not pet or not pet.alive() then return nil end
        -- THE SLIDER IS A CEILING, not a fallback. "Heal the pet below 20%"
        -- means never above twenty, however fast it is losing health: Mend
        -- Pet is a five-second channel during which nothing else happens,
        -- and a pet at half health holding one mob is not in danger. The
        -- slope may only bring the threshold DOWN from the slider.
        -- THE CEILING IS THE SITUATION, not a slider (1.32.0). Solo the pet
        -- is the tank and losing it loses the fight, so it may be healed from
        -- 45%; in a group somebody else holds the mob and the pet is damage,
        -- so not above 25%. The slope still brings it down from there.
        local targeting = P.targeting
        local solo = not targeting or type(targeting.context) ~= "function"
            or targeting.context() == targeting.SOLO
        local cap = solo and 0.45 or 0.25
        local losing = -pet.hp_rate()
        if losing <= 0.001 then
            -- Nothing is hurting it. Heal only when it is genuinely low, so a
            -- pet idling at 60% does not eat a global cooldown.
            return math.min(cap, 0.35)
        end
        return math.min(cap, math.max(0.10, losing * 5))
    end

    --- Health Funnel is paid in our health; the floor is the shared trade floor.
    derive["pet_funnel_min_hp"] = function()
        return derive["res_trade_floor_hp"]()
    end

    --- What a funnel actually costs us, measured from a real one where we have
    --- seen it and estimated from the channel length otherwise.
    derive["pet_funnel_cost_hp"] = function()
        local seen = M.health_cost("Health Funnel")
        if seen then return seen end
        local seconds = M.cast_time("Health Funnel")
        if not seconds or seconds <= 0 then return nil end
        -- Health Funnel transfers a percentage of the caster's health per
        -- second; a tenth of the bar per second is the right order of
        -- magnitude across the levelling range.
        return math.max(0.05, math.min(0.60, seconds * 0.10))
    end

    --- A funnel is futile once the pet is losing health faster than the funnel
    --- restores it. The funnel's rate is its cost spread over its channel,
    --- scaled by the ratio of the two health pools.
    derive["pet_funnel_futile_rate"] = function()
        local cost = derive["pet_funnel_cost_hp"]()
        local seconds = M.cast_time("Health Funnel")
        if not cost or not seconds or seconds <= 0 then return nil end

        local player = units.player()
        local pet = P.pet and P.pet.pet()
        if not player or not pet then return nil end

        local ok_p, my_max = pcall(player.get_max_health, player)
        local ok_t, pet_max = pcall(pet.get_max_health, pet)
        if not ok_p or not ok_t or not my_max or not pet_max or pet_max <= 0 then
            return nil
        end

        -- Our health, in units of the pet's bar, delivered per second.
        local healed_per_sec = (cost * my_max / pet_max) / seconds
        return math.max(0.02, math.min(0.50, healed_per_sec))
    end

    -- --- measuring health costs automatically -------------------------------
    --
    -- get_spell_costs reports mana, and says nothing about a spell paid for in
    -- health. Those are measured instead, off the cast event, so the number is
    -- this character's number at this rank rather than one I guessed.

    local HEALTH_PAID = {
        ["Life Tap"] = true,
        ["Health Funnel"] = true,
        ["Hellfire"] = true,
    }

    -- The spellbook resolves name -> ids, not the reverse, so the match runs
    -- the direction it supports. The list is three entries long; a reverse
    -- index would be more code than the thing it indexes.
    ---@param id integer
    ---@return string|nil
    local function health_paid_name(id)
        local book = P.spellbook
        if not book then return nil end
        for name in pairs(HEALTH_PAID) do
            local ok, ids = pcall(book.ids, name)
            if ok and type(ids) == "table" then
                for i = 1, #ids do
                    if ids[i] == id then return name end
                end
            end
        end
        return nil
    end

    ctx.on("jcore.spell.cast", function(data)
        if type(data) ~= "table" or not data.spell_id then return end

        local player = units.player()
        if not player then return end
        if data.caster and data.caster.get_guid
            and data.caster:get_guid() ~= player:get_guid() then
            return
        end

        local name = health_paid_name(data.spell_id)
        if name then M.watch_health_cost(name) end
    end)

    -- --- the lookup ---------------------------------------------------------

    local last_value = {}          -- id -> last answer, for the readout
    local memo = {}                -- id -> { at, value }

    -- A derivation is cheap but not free -- the range one walks the whole
    -- priority list -- and the targeting module asks for the same number
    -- several times a frame. Half a second is far shorter than anything these
    -- numbers respond to and long enough to make the cost vanish.
    local MEMO_TTL = 0.5

    --- The automatic value for a widget id, or nil when it cannot be derived.
    ---@param id string
    ---@return number|nil 0..1 for a percentage, or seconds for a duration
    function M.value(id)
        local now = core.time()
        local cached = memo[id]
        if cached and (now - cached.at) < MEMO_TTL then return cached.value end

        local fn = derive[id]
        if not fn then
            -- Class ids are prefixed "rot_<class>_"; match on the suffix.
            local suffix = id:match("^rot_[%a]+_(.+)$")
            fn = suffix and by_suffix[suffix] or nil
        end
        if not fn then
            memo[id] = { at = now, value = nil }
            return nil
        end

        local ok, value = pcall(fn)
        -- value ~= value catches NaN, which arithmetic on an unloaded figure
        -- can produce and which would compare false against every threshold.
        if not ok or type(value) ~= "number" or value ~= value then
            memo[id] = { at = now, value = nil }
            return nil
        end

        memo[id] = { at = now, value = value }
        last_value[id] = value
        return value
    end

    ---@return table id -> value
    function M.chosen()
        return last_value
    end

    function M.stats()
        local name = filler_name()
        return {
            filler = name,
            filler_cost = name and M.cost_fraction(name) or nil,
            filler_cast = name and M.cast_time(name) or nil,
            incoming = incoming(),
            regen = M.regen(),
            chosen = last_value,
        }
    end

    ctx.tick(function() settle_measurement() end)

    return M
end

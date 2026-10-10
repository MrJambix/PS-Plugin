-- Jambix AIO / classes / warlock
--
-- Source: Icy Veins and Wowhead Classic warlock levelling guides. The shape
-- they describe is Immolate, Corruption and Curse of Agony carrying the damage
-- with a wand filling the gaps, while the pet holds the mob.
--
-- THE BUG THIS REVISION EXISTS TO FIX
-- The previous rule list had Life Tap at "mana below 25%, health above 60%"
-- and Drain Life at "health below 40%". Each read correctly on its own, and
-- together they were a death spiral: tap for mana, lose health, drain for
-- health, lose mana, tap again. Every step passed its own threshold check and
-- the warlock died with both bars empty.
--
-- The fix is not a better threshold. It is that the health-for-mana trade now
-- goes through modules/resources.lua, which looks at where the bars are
-- HEADED and refuses a trade that ends on a corpse. See the long note there.
--
-- TALENTS CHANGE WHAT YOU DO, NOT JUST HOW HARD IT HITS
-- A warlock is the clearest case of this in the game, and the rules below
-- read the talent tree rather than assuming a build:
--
--   Dark Pact          mana from the PET, at no health cost. When this is
--                      talented it replaces Life Tap outright, and it is the
--                      single best answer to the spiral above.
--   Improved Drain Soul  killing a mob with Drain Soul refunds mana. That
--                      turns the execute window from a mana cost into a mana
--                      SOURCE, which reorders the whole end of the fight.
--   Nightfall          procs Shadow Trance: the next Shadow Bolt is instant.
--                      It has to be consumed before it falls off, and it is
--                      castable while moving, which no other bolt is.
--   Improved Drain Life  is what makes Drain Life an actual heal rather than
--                      a slow way to lose a fight.
--   Improved Life Tap  makes the trade better, so it is worth taking at a
--                      slightly higher mana level.
--   Siphon Life        is itself a talent, so the rule only exists when taken.
--
-- A note on Improved Drain Soul's wording: Vanilla and TBC phrase it as a
-- flat refund of maximum mana when the target dies while you are channelling,
-- and a later expansion phrases the same idea as a burst of mana regeneration.
-- Nothing here depends on which: the rule is "a kill with Drain Soul pays for
-- itself", and that holds in every version.

return function(P, H, CS)
    -- THE NUMBERS ARE THE FIGHT'S (1.35.x). Every threshold below is derived
    -- (modules/auto.lua); the "manual override" sliders that stood behind them
    -- are gone with automatic tuning's off switch, and nothing reads them.
    local function tuned(id, default_pct)
        if P.derived then return P.derived(CS.prefix .. id, default_pct) end
        return default_pct / 100
    end
    local function tuned_secs(id, default)
        if P.derived_secs then return P.derived_secs(CS.prefix .. id, default) end
        return default
    end

    local book = H.book

    -- --- talent reads -------------------------------------------------------
    --
    -- Called per rule evaluation rather than cached at load, because a
    -- levelling character spends points mid-session and a respec must not
    -- need a reload. modules/talents.lua caches the scan, so this is cheap.

    local function has_dark_pact()        return H.has_talent("Dark Pact") end
    local function imp_drain_soul()       return H.talent("Improved Drain Soul") end
    -- Forever's Soul Harvest (1.73.3): a non-trivial mob that dies afflicted
    -- by your Drain Soul raises your mana regeneration for 10 s (the client's
    -- spell tables, spell 1242853: regen up, and kept while casting).
    local function soul_harvest()         return H.talent("Soul Harvest") end
    -- Forever has no Improved Drain Life. Its Improved Drains and Soul Siphon
    -- (Improved Drain Life's old spell, 17804) both make the drain heal for
    -- more, which is all this read decides (1.80.0).
    local function imp_drain_life()
        return math.max(H.talent("Improved Drain Life"), H.talent("Improved Drains"),
            H.talent("Soul Siphon"))
    end
    local function imp_life_tap()         return H.talent("Improved Life Tap") end
    local function has_nightfall()        return H.has_talent("Nightfall") end

    -- AURAS THAT ARE NO SPELL OF YOURS (1.78.2), read by id as 1.77.3 did for
    -- the other classes. Asked for by name, an aura is looked up in your own
    -- spellbook, and neither of these is there, so neither was ever seen: a
    -- Nightfall proc was never spent on an instant bolt, and a soulstone
    -- already on you was conjured and offered again. The ids are the same on
    -- Era and Forever (the clients' spell tables).
    local SHADOW_TRANCE = { 17941 }
    local SOULSTONE_RESURRECTION = { 20707, 20762, 20763, 20764, 20765 }

    -- AGONY HAS ANOTHER NAME ON FOREVER (1.80.0). Forever calls Curse of
    -- Agony "Bane of Agony" (the same spell ids, 980 and its ranks), and
    -- spells are found by name, so every Agony rule was never a candidate
    -- there and a Forever warlock never put it up. The debuff on the target
    -- carries the same name. A Bane is no curse on Forever, so it shares the
    -- target with one: see CURSES below.
    local AGONY = P.forever and "Bane of Agony" or "Curse of Agony"

    -- --- mana ---------------------------------------------------------------

    --- Dark Pact: the pet's mana becomes ours, and nothing is paid in health.
    ---
    --- Strictly better than Life Tap whenever it is available and the pet has
    --- anything left, so it sits above Life Tap in every list and Life Tap
    --- stands down while it is usable.
    local function dark_pact_wanted(s)
        if not has_dark_pact() then return false end
        if H.power_fraction(s) > tuned("mana_low", 35) then return false end

        local pet = P.pet
        if not pet or not pet.alive() then return false end
        return pet.power_fraction() >= tuned("darkpact_pet_mana", 20)
    end

    --- Life Tap, through the trade gate rather than a bare threshold.
    ---
    --- THIS IS THE RULE THAT USED TO KILL US. It now refuses when health is
    --- falling fast enough that the tap plus the incoming damage empties the
    --- bar before the mob dies -- which is the case a percentage floor cannot
    --- express and the one that actually matters.
    local function life_tap_wanted(s)
        -- Dark Pact is free; never pay health for mana we can have for nothing.
        if dark_pact_wanted(s) then return false end

        -- Improved Life Tap returns more mana for the same health, so the
        -- trade is worth taking a little earlier.
        local threshold = tuned("mana_low", 35) + (imp_life_tap() * 0.03)

        local cost = tuned("lifetap_cost_hp", 15)
        local ok, reason = H.may_trade_health(cost, {
            floor = tuned("lifetap_min_hp", 60),
            need_power = threshold,
        })
        if not ok then
            -- "info" rather than a warning: this is the plugin doing the
            -- right thing, and it is off by default. It is here at all
            -- because a warlock watching its mana sit at 10% deserves to be
            -- able to find out that the tap is being held back on purpose.
            if P.narrate then
                P.narrate.say("info", "Holding Life Tap", reason, "lifetap_refused")
            end
            return false
        end
        return true
    end

    --- Drain Soul as the finisher, and as the mana bar.
    ---
    --- WITH IMPROVED DRAIN SOUL THIS IS NOT A FINISHER AT ALL -- it is the
    --- warlock's mana bar, and the refund only arrives if the mob dies WHILE
    --- THE CHANNEL IS RUNNING. Everything below exists to make that tick the
    --- killing one:
    ---
    ---   * the window is measured, not chosen: how much of this target's bar
    ---     we actually remove during one channel (see modules/auto.lua);
    ---   * it must be close enough to death to die inside the channel, and
    ---     not so close that a DoT tick beats us to it;
    ---   * and once it is running, nothing else may take the kill -- which is
    ---     what protect_the_channel below is for.
    ---
    --- Without the talent none of that applies and it goes back to being a
    --- shard and a slightly better bolt into a corpse.
    -- The shard budget, defined with the shards further down (a forward
    -- declaration: Drain Soul below asks it, 1.73.2).
    local shard_count, shard_cap

    -- --- Soul Harvest: every kill it can (Forever, 1.73.3) -------------------
    --
    -- The user: "If its talented then try to get it to trigger as much as
    -- possible". It triggers on a kill that counts -- not a grey mob, not a
    -- critter or a totem -- that dies with the channel on it. So the drain
    -- goes on whichever mob we are fighting dies soonest inside one channel:
    -- the target in its execute window, or another engaged mob that will die
    -- at least a second sooner. Never on one we crowd-controlled (the drain
    -- would break it). The shard limit does not hold it back: its kills are
    -- the point, and the limit still trims the spares out of combat.
    local CRITTER, TOTEM = 8, 11
    local SWITCH_FOR = 1.0          -- seconds sooner another mob must die to be drained instead

    local function harvests(unit, s)
        local ok_t, kind = pcall(unit.get_creature_type, unit)
        if ok_t and (kind == CRITTER or kind == TOTEM) then return false end
        local ok_l, level = pcall(unit.get_level, unit)
        local ok_m, mine = pcall(s.player.get_level, s.player)
        local cfg = P.cfg
        if ok_l and ok_m and cfg and cfg.difficulty_band
            and cfg.difficulty_band(tonumber(level) or 0, tonumber(mine) or 0) == "trivial" then
            return false
        end
        return true
    end

    local function harvest_target(s, channel)
        local best, best_ttd = nil, math.huge
        if s.target and type(s.ttd) == "number" and s.ttd > 0 and s.ttd <= channel
            and H.execute_phase(s, tuned("drainsoul_hp", 25)) and harvests(s.target, s) then
            best, best_ttd = s.target, s.ttd
        end
        local combat = P.combat
        local rows = s.enemies or {}
        for i = 1, math.min(s.enemy_count or #rows, 12) do
            local r = rows[i]
            if r and r.obj and r.engaged and not r.dead and not r.control and (r.hp or 1) <= 0.45
                and not rawequal(r.obj, s.target) and combat and combat.time_to_die then
                local ok, ttd = pcall(combat.time_to_die, r.obj)
                if ok and type(ttd) == "number" and ttd > 0 and ttd <= channel
                    and ttd < best_ttd - SWITCH_FOR and harvests(r.obj, s) then
                    best, best_ttd = r.obj, ttd
                end
            end
        end
        return best
    end

    local function drain_soul_wanted(s)
        -- The unit the rule casts on (retarget): the target unless Soul
        -- Harvest picks a mob that dies sooner.
        s.drain_soul_target = s.target
        if s.player:is_moving() then return false end

        if soul_harvest() > 0 then
            local unit = harvest_target(s, tuned_secs("drainsoul_max_ttd", 8))
            if not unit then return false end
            s.drain_soul_target = unit
            return true
        end

        if not s.target then return false end

        local window = tuned("drainsoul_hp", 25)
        if not H.execute_phase(s, window) then return false end

        local channel = tuned_secs("drainsoul_max_ttd", 8)

        -- The refund only happens if the mob dies during the channel, so
        -- starting one on something with twenty seconds left wastes the
        -- channel and the mana both.
        if s.ttd > channel then return false end

        -- THE SHARD BUDGET STOPS THE SHARDS (1.73.2). A player on Forever: "it
        -- keeps casting drain soul and my backpack is always full ... i even
        -- set the slider to max 5 shards". The limit only ever said what to do
        -- with shards once made: spend them, else destroy them out of combat.
        -- At the limit a Drain Soul is now cast only for Improved Drain Soul's
        -- mana refund, and only while mana is short. Otherwise Shadow Bolt or
        -- the wand finishes the mob.
        if CS.opt("shard_dump", true) and shard_count() >= shard_cap() then
            if imp_drain_soul() == 0 then return false end
            if H.power_fraction(s) > tuned("mana_low", 35) then return false end
        end

        -- NO LOWER BOUND, and the first version of this had one, which was
        -- backwards. The refund is paid for a death that happens WHILE THE
        -- CHANNEL IS RUNNING, so starting earlier is strictly better and
        -- there is no such thing as too close to death to bother.
        --
        -- The floor also made the window about half a second wide, which the
        -- cast service could not hold on to: the intent was superseded by the
        -- filler on the following tick before the global cooldown came round.
        -- A rule that is only true for one tick may as well be false.
        if imp_drain_soul() > 0 then return true end

        -- Untalented: only worth it when mana is not the constraint, because
        -- a plain Drain Soul is a mediocre finisher.
        return H.power_fraction(s) > tuned("mana_low", 35)
    end

    --- Do not steal the kill from our own channel.
    ---
    --- Returned by every damage rule below as part of its condition. While a
    --- Drain Soul is running on a nearly-dead target and the talent is taken,
    --- a Shadow Bolt landing first turns a full mana bar into nothing -- the
    --- refund is paid on the drain's killing tick and on nothing else.
    ---
    --- The engine's cast gate already keeps the global cooldown lane shut
    --- while a channel is in flight, so this mostly matters for the off-GCD
    --- lane and for the frame the channel ends on. It costs one comparison
    --- and it protects the single most valuable thing a levelling Affliction
    --- warlock does, so it is worth stating explicitly rather than relying on
    --- a gate that is allowed to distrust itself.
    ---@param s table
    ---@return boolean
    local function may_add_damage(s)
        if imp_drain_soul() == 0 and soul_harvest() == 0 then return true end
        if not s.target then return true end
        if not H.channel_active("Drain Soul") then return true end
        -- Once it is running, let it finish: anything else we add can only
        -- land the killing blow instead of the drain.
        return false
    end

    -- --- health -------------------------------------------------------------

    --- Drain Life, as a heal rather than as a reflex.
    ---
    --- The other half of the spiral. Drain Life costs mana to return health,
    --- so firing it while mana is the binding constraint trades the resource
    --- we need for the one we do not. It is correct only when:
    ---
    ---   * health is genuinely low, AND
    ---   * we can pay for it, AND
    ---   * the channel will finish -- a three second channel with two seconds
    ---     of life left in us is two seconds not spent escaping.
    ---
    --- Improved Drain Life raises how much this returns, so an untalented
    --- warlock needs to be in real trouble before it beats simply killing the
    --- mob faster.
    local function drain_life_wanted(s)
        if not s.in_combat or not s.target then return false end

        local threshold = tuned("drainlife_hp", 40)
        if imp_drain_life() == 0 then
            threshold = threshold - 0.10     -- weaker heal, later use
        end
        if s.hp > threshold then return false end

        -- Mana we do not have is not a heal. Below this we are better off
        -- wanding and backing away than starting a channel we cannot finish.
        if H.power_fraction(s) < tuned("drainlife_min_mana", 20) then
            return false
        end

        -- THE OTHER HALF OF THE SPIRAL, explicitly. Draining life costs mana
        -- to return health. If the cast would leave us unable to cast at all,
        -- we have converted a health problem into a health AND mana problem,
        -- which is how the warlock ended up with both bars empty. The wand
        -- and the escape list are both better answers at that point.
        local cost = (P.auto and P.auto.cost_fraction("Drain Life")) or 0
        local floor = P.tune("res_critical_power", 10)
        if (H.power_fraction(s) - cost) < floor then return false end

        -- If health runs out before the channel returns anything, this is not
        -- a heal, it is a stand-still animation. Escape instead; the escape
        -- list is handled by the engine.
        local res = P.resources
        if res and res.hp_empty() < tuned_secs("drainlife_min_runway", 4) then
            return false
        end

        return true
    end

    --- The soulstone, which the plugin was ignoring entirely.
    ---
    --- A soulstone on yourself is a free resurrection on the spot: no run
    --- back, no durability, and on a hardcore character the difference
    --- between a bad pull and the end of the character. It lasts thirty
    --- minutes, costs one global cooldown between pulls, and there is no
    --- reason ever to be without one.
    ---
    --- Two steps, because they are two spells. Making the stone puts an item
    --- in the bags; using the item puts the buff on somebody. Both are done
    --- out of combat only -- mid-fight either one is a global cooldown spent
    --- on something that will not help with the fight we are in.
    local function make_soulstone(s)
        if s.in_combat then return false end
        if not CS.opt("soulstone", true) then return false end
        local hc = P.hardcore
        if not hc or not hc.item then return false end
        return hc.item("soulstone") == nil
    end

    --- True when we are holding a soulstone and nothing is wearing it.
    ---
    --- The buff is checked on OURSELVES only. In a group the stone belongs on
    --- whoever can restart the fight -- the healer -- and deciding that is a
    --- judgement this module has no way to make well, so it does the thing
    --- that is right when solo and says so rather than guessing in a party.
    ---@return boolean
    local function soulstone_unused()
        if not CS.opt("soulstone", true) then return false end
        local hc = P.hardcore
        if not hc or not hc.item then return false end
        if hc.item("soulstone") == nil then return false end

        local player = H.units.player()
        if not player then return false end
        return not H.buff_up(player, SOULSTONE_RESURRECTION)
    end

    -- --- soul shards ---------------------------------------------------------
    --
    -- A shard is one bag slot and they do not stack, so a levelling warlock
    -- spends the whole game watching its bags fill with them. The cap is a
    -- real decision rather than a tidiness preference: past it, every Drain
    -- Soul is costing a slot that could hold loot.
    --
    -- SPENDING BEATS DESTROYING, always, and there is usually something to
    -- spend one on. The stone rules above already conjure a healthstone and a
    -- soulstone when the bags have none, and each of those eats a shard, so
    -- by the time anything here fires the productive uses are genuinely
    -- exhausted.

    ---@return integer
    shard_count = function()
        local hc = P.hardcore
        if not hc or not hc.count then return 0 end
        return hc.count("soulshard")
    end

    --- The shard budget. Twenty by default, which is a full small bag.
    ---@return integer
    shard_cap = function()
        return CS.opt("shard_cap", 20)
    end

    --- Is there something useful to turn a spare shard into?
    ---
    --- Only ever true when we are ALSO over the cap, so a warlock with three
    --- shards is not burning one on a spellstone it did not ask for.
    ---@param s table
    ---@param name string
    ---@return boolean
    local function spend_spare_shard(s, name)
        if s.in_combat then return false end
        if not CS.opt("shard_dump", true) then return false end
        if shard_count() <= shard_cap() then return false end
        return book.knows_prefix(name)
    end

    --- Drain Life as the FILLER, which is the whole drain-tank idea.
    ---
    --- Source: the noobtoboss Classic warlock levelling guide, which builds
    --- the entire levelling plan around it -- pet tanks, every DoT goes up,
    --- and then Drain Life is channelled while they tick, so the health it
    --- returns and the mana Life Tap converts form a closed loop and "you
    --- never stop to eat or drink".
    ---
    --- This is a DIFFERENT SPELL from the emergency Drain Life in the
    --- preamble, which fires on low health in every profile. Here it is the
    --- damage, so the health test is gone; what stays is affordability,
    --- because a channel that empties the bar breaks the loop it is part of.
    local function drain_life_filler(s)
        if not s.in_combat or not s.target then return false end
        if s.player:is_moving() then return false end
        if not may_add_damage(s) then return false end
        if not H.filler_after_dots(s) then return false end

        -- The same floors the emergency version uses. The loop only works
        -- while both halves of it can keep running.
        local cost = (P.auto and P.auto.cost_fraction("Drain Life")) or 0
        if (H.power_fraction(s) - cost) < P.tune("res_critical_power", 10) then
            return false
        end

        -- Below the conserve line the wand is the better filler: it is free,
        -- and mana spent here is mana not available for the DoTs that are
        -- doing most of the damage.
        return H.power_fraction(s) > P.tune("res_conserve_power", 35)
    end

    --- Fear the add, not the target.
    ---
    --- The guide is specific about when: "Fear dangerous enemies when your
    --- Voidwalker loses aggro or you pull accidental adds". Both are the same
    --- unit -- something engaged with us that we are not killing -- and
    --- feared is where it should be while the pet holds the one we are.
    ---
    --- Never on the current target: it is covered in our damage-over-time
    --- spells, so the fear would break on the first tick and the cast would be
    --- a global cooldown thrown away.
    local function fear_the_add(s)
        -- The key is checked by the engine as well, through key_gated below.
        -- Repeated here so the rule reads honestly on its own: this never
        -- fires unasked.
        if not H.key_allows("Fear") then return false end
        if not s.in_combat or not s.add then return false end
        if s.player:is_moving() then return false end

        -- Our own DoTs break it immediately, so only an undotted add is worth
        -- fearing at all.
        for _, name in ipairs({ "Corruption", AGONY, "Immolate", "Siphon Life" }) do
            if H.debuff_up(s.add, name) then return false end
        end

        return not H.debuff_up(s.add, "Fear")
    end

    --- Create a Healthstone when we do not have one.
    ---
    --- Out of combat only, and cheap. A warlock without a healthstone in the
    --- bags has thrown away the best instant heal in the game for one global
    --- cooldown spent standing still between pulls.
    local function make_healthstone(s)
        if s.in_combat then return false end
        if not CS.opt("make_healthstone", true) then return false end
        local hc = P.hardcore
        if not hc or not hc.item then return true end
        return hc.item("healthstone") == nil
    end

    -- --- damage -------------------------------------------------------------

    --- Shadow Trance, from Nightfall: the next Shadow Bolt is instant.
    ---
    --- Worth its own rule above everything else, for three reasons: it expires,
    --- it is free damage for no cast time, and it is the only bolt a warlock
    --- can cast while moving. Kiting with a Shadow Trance charge unspent is
    --- the most common way to waste the talent.
    local function shadow_trance(s)
        if not has_nightfall() then return false end
        if not s.target then return false end
        return H.buff_up(s.player, SHADOW_TRANCE)
    end

    --- Hard-cast Shadow Bolt. The expensive filler.
    ---
    --- Stops once the wand is carrying and mana is the constraint -- see
    --- H.filler_ok, which owns that judgement for every caster -- and stops
    --- while recovering, because a bolt cast during a mana crisis is the
    --- crisis getting worse.
    local function bolt_wanted(s)
        if s.player:is_moving() then return false end
        if not may_add_damage(s) then return false end

        -- INSIDE A BURST WINDOW, EVERY DOT GOES ON FIRST. A DoT snapshots
        -- spell power when it is applied and ticks at that strength for its
        -- whole duration, so one landed under a trinket keeps hitting like
        -- that long after the trinket is gone. Spending those seconds on a
        -- bolt instead trades a full duration of amplified ticks for a single
        -- amplified cast, which is the worst trade Affliction can make.
        if not H.filler_after_dots(s) then return false end

        if not H.filler_ok(s) then return false end
        if H.should_recover() and H.power_fraction(s) < tuned("mana_low", 35) then
            return false
        end
        return true
    end

    -- Wand handling lives in the engine: "Shoot" is a TOGGLE, so requesting
    -- it while it is already firing turns it OFF. The live log showed exactly
    -- that -- Shoot dispatched over and over, never landing a shot.
    local base_wand_wanted = H.wand_wanted

    --- The wand is the likeliest thief of the killing tick: it fires on its
    --- own timer, off the global cooldown, for damage we did not ask for at
    --- that instant.
    local function wand_wanted(s)
        if not may_add_damage(s) then return false end
        if not H.filler_after_dots(s) then return false end
        return base_wand_wanted(s)
    end

    --- A DoT is only worth its mana when the mob lives long enough to take the
    --- ticks, and the bar for that goes UP when mana is short. Refreshing
    --- Corruption on a mob with four seconds left is how a warlock ends a
    --- levelling session sitting down every pull.
    local function dot(name, min_ttd)
        return function(s)
            if not may_add_damage(s) then return false end
            local floor = min_ttd
            if H.should_recover() then floor = floor + CS.opt("dot_ttd_penalty", 4) end
            return H.dot_worth_it(s, name, floor)
        end
    end

    --- A CURSE BESIDE THE BANE (Forever, 1.80.0). Every Forever guide puts
    --- Curse of the Elements (or Recklessness) on elites and bosses: with
    --- Agony a Bane there, a curse no longer costs the warlock its best DoT.
    --- Elements, because it raises our own Shadow and Fire damage. Never on
    --- Era, where Agony is the curse and the two would replace each other;
    --- never over a curse of ours already on the target.
    local CURSES = { "Curse of the Elements", "Curse of Recklessness", "Curse of Weakness",
        "Curse of Tongues", "Curse of Exhaustion" }
    local function worth_cursing(s)
        if not P.forever or not s.in_combat or not s.target then return false end
        local units_service = P.units
        local rank = 0
        if units_service and units_service.classification then
            local ok, value = pcall(units_service.classification, s.target)
            if ok and type(value) == "number" then rank = value end
        end
        -- Elite, rare elite or boss; or anything that will take half a minute.
        if not (rank == 1 or rank == 2 or rank == 3 or (s.ttd or 0) > 30) then return false end
        if H.debuff_remaining(s.target, "Curse of the Elements") > 2 then return false end
        for i = 2, #CURSES do
            if H.debuff_up(s.target, CURSES[i]) then return false end
        end
        return s.ttd > 12
    end

    --- Wrack, Forever's Affliction capstone: a six-second channel that also
    --- raises our other Shadow DoTs on the target, and the filler wowtbc.gg
    --- and Mobalytics put in place of Shadow Bolt once the DoTs are up.
    local function wrack_wanted(s)
        if not s.target or s.player:is_moving() then return false end
        if not may_add_damage(s) or not H.filler_after_dots(s) then return false end
        return s.ttd > 6
    end

    -- --- shared opening rules ----------------------------------------------
    -- Every profile starts the same way: armour up, take free mana, take the
    -- refunding execute. Written once and spliced in, because three copies of
    -- this drifting apart is exactly how the spiral survived as long as it did.

    local function preamble()
        return {
            { "Demon Skin", function(s)
                return not s.in_combat and not H.buff_up(s.player, "Demon Armor")
                    and not H.buff_up(s.player, "Demon Skin")
            end, self = true, upkeep = 30 },
            { "Demon Armor", function(s)
                return not s.in_combat and not H.buff_up(s.player, "Demon Armor")
            end, self = true, upkeep = 30 },
            -- prefix: the ranks of these two are named "Create Healthstone
            -- (Minor)", "(Lesser)", "(Greater)" and so on, so an exact lookup
            -- resolves for one level band and silently answers nil for every
            -- other.
            { "Create Healthstone", make_healthstone,
              self = true, upkeep = 20, prefix = true },
            { "Create Soulstone", make_soulstone,
              self = true, upkeep = 20, prefix = true },
            -- Shard sinks, and only while over the cap. A spellstone or a
            -- firestone is a weapon enchant worth having anyway, so this
            -- turns the overflow into something rather than deleting it.
            { "Create Spellstone", function(s)
                return spend_spare_shard(s, "Create Spellstone")
            end, self = true, upkeep = 30, prefix = true },
            { "Create Firestone", function(s)
                return spend_spare_shard(s, "Create Firestone")
            end, self = true, upkeep = 30, prefix = true },
            -- Free mana first, paid mana second.
            { "Dark Pact", dark_pact_wanted, self = true, upkeep = 2 },
            { "Life Tap", life_tap_wanted, self = true, upkeep = 3 },
            { "Drain Life", drain_life_wanted, channel = true },
            { "Drain Soul", drain_soul_wanted, channel = true, retarget = "drain_soul_target" },
        }
    end

    --- core rules (the damage-over-time spells) -> wand -> filler.
    ---
    --- THE WAND GOES BEFORE THE FILLER, not after. Put Shoot last and hard-cast
    --- Shadow Bolt wins every tick, the wand never starts, and H.filler_ok --
    --- which only stands the filler down once the wand IS running -- never gets
    --- the chance to do its job.
    local function build(core_rules, filler_rules)
        local out = preamble()
        -- A Nightfall proc before the damage over time (1.78.2): it was in no
        -- list, so the instant bolt was never cast, read by id or not.
        out[#out + 1] = { "Shadow Bolt", shadow_trance }
        -- The curse goes on before the DoTs, the guides' order (Forever only).
        out[#out + 1] = { "Curse of the Elements", worth_cursing, upkeep = 2 }
        for i = 1, #core_rules do out[#out + 1] = core_rules[i] end
        out[#out + 1] = { "Shoot", wand_wanted, upkeep = 3 }
        for i = 1, #filler_rules do out[#out + 1] = filler_rules[i] end
        return out
    end

    --- Siphon Life is itself a talent, so the rule only applies when taken.
    --- Hoisted rather than built per evaluation: a priority list is walked
    --- every tick and a closure per rule per tick is garbage for nothing.
    local siphon_life_dot = dot("Siphon Life", 12)
    local function siphon_life(s)
        return H.has_talent("Siphon Life") and siphon_life_dot(s)
    end

    local profiles = {}

    -- THE DRAIN TANK, from the noobtoboss Classic warlock levelling guide.
    -- Its opener, in its order: send the pet, Corruption, Curse of Agony,
    -- Immolate, Siphon Life, then channel Drain Life while they tick, and the
    -- wand when mana will not carry the channel.
    --
    -- Corruption leads because it is instant once talented, so it is the one
    -- spell that can be up before the mob arrives. That is a different reason
    -- from the one the old order used -- longest duration first -- and it is
    -- the better one while levelling.
    --
    -- SPREADING IS CORRUPTION ONLY here, also from the guide: "Apply
    -- Corruption to 2-3 enemies, then focus your other DoTs and drains on the
    -- primary target". Immolate and Siphon Life on a mob the pet is holding
    -- are mana spent to kill something slowly that was never the problem.
    profiles.leveling = {
        label = "Levelling (drain tank)",
        power = "MANA",
        rules = build({
            { "Corruption", dot("Corruption", 10), upkeep = 2, dot = true, spread = true },
            { AGONY, dot(AGONY, 12), upkeep = 2, dot = true },
            { "Immolate", dot("Immolate", 8), upkeep = 2, dot = true },
            { "Siphon Life", siphon_life, upkeep = 2, dot = true },
            { "Fear", fear_the_add, retarget = "add", upkeep = 8 },
        }, {
            { "Drain Life", drain_life_filler, channel = true },
            { "Shadow Bolt", bolt_wanted },
        }),
    }

    -- The shape this profile had before the guide: DoTs, wand, and Shadow Bolt
    -- as the filler. Kept because it is the right answer for a warlock who has
    -- not talented into the drains yet, and because deleting a working profile
    -- to replace it with a different one is not an upgrade.
    profiles.leveling_bolt = {
        label = "Levelling (bolt)",
        power = "MANA",
        rules = build({
            { AGONY, dot(AGONY, 12), upkeep = 2, dot = true, spread = true },
            { "Corruption", dot("Corruption", 10), upkeep = 2, dot = true, spread = true },
            { "Immolate", dot("Immolate", 8), upkeep = 2, dot = true, spread = true },
            { "Siphon Life", siphon_life, upkeep = 2, dot = true, spread = true },
        }, {
            { "Shadow Bolt", bolt_wanted },
        }),
    }

    profiles.affliction = {
        label = "Affliction",
        power = "MANA",
        rules = build({
            { "Haunt", dot("Haunt", 8), upkeep = 2, dot = true, spread = true },
            { "Unstable Affliction", dot("Unstable Affliction", 12), upkeep = 2, dot = true, spread = true },
            { "Corruption", dot("Corruption", 10), upkeep = 2, dot = true, spread = true },
            { AGONY, dot(AGONY, 12), upkeep = 2, dot = true, spread = true },
            { "Siphon Life", dot("Siphon Life", 12), upkeep = 2, dot = true, spread = true },
            { "Immolate", dot("Immolate", 8), upkeep = 2, dot = true, spread = true },
        }, {
            { "Wrack", wrack_wanted, channel = true },
            { "Shadow Bolt", bolt_wanted },
        }),
    }

    profiles.destruction = {
        label = "Destruction",
        power = "MANA",
        rules = build({
            -- Immolate is a prerequisite here, not just a DoT: Conflagrate
            -- consumes it, so it goes up first and Conflagrate only fires when
            -- there is something to consume.
            { "Immolate", dot("Immolate", 6), upkeep = 2, dot = true, spread = true },
            { "Conflagrate", function(s) return H.debuff_up(s.target, "Immolate") end,
              upkeep = 1 },
            { AGONY, dot(AGONY, 12), upkeep = 2, dot = true, spread = true },
            { "Shadowburn", function(s) return H.execute_phase(s, 0.2) end, upkeep = 1 },
        }, {
            { "Incinerate", bolt_wanted },
            { "Shadow Bolt", bolt_wanted },
        }),
    }

    profiles.demonology = {
        label = "Demonology",
        power = "MANA",
        rules = build({
            { "Corruption", dot("Corruption", 10), upkeep = 2, dot = true, spread = true },
            { "Immolate", dot("Immolate", 8), upkeep = 2, dot = true, spread = true },
            { AGONY, dot(AGONY, 12), upkeep = 2, dot = true, spread = true },
        }, {
            { "Shadow Bolt", bolt_wanted },
        }),
    }

    return {
        key = "warlock",
        label = "Warlock",
        wand_capable = true,
        trees = { "Affliction", "Demonology", "Destruction" },
        -- Devour Magic belongs to the Felhunter, so it is a PET dispel and the
        -- player path would never resolve it.
        pet_dispels = { { spell = "Devour Magic", types = { "MAGIC" } } },
        -- No group buff: Fel Intelligence is the Felhunter's from TBC on, and
        -- neither Era nor Forever has it (1.78.2).
        buffs = {},
        icon = "flame",
        pet_capable = true,
        settings = function(s, P)
            s:label("Nothing here is a number you have to choose. Every threshold")
            s:label("below is worked out from what is happening: the real mana cost")
            s:label("of your spells, the measured rate you are dealing and taking")
            s:label("damage, and which talents you actually have. The Rotation page")
            s:label("prints what it chose.")
            s:separator()

            -- These stay as behaviour switches rather than thresholds: whether
            -- to bother with a stone at all is a preference, not something
            -- that can be read off the fight.
            s:toggle("make_healthstone", "Keep a Healthstone in the bags", true)
            s:toggle("soulstone", "Keep a Soulstone, and wear it", true)
            s:label("Adds the pet is not holding are feared while the crowd-control")
            s:label("key is held -- never the target, which your own damage over time")
            s:label("would break on the first tick.")
            s:separator()
            s:toggle("shard_dump", "Keep soul shards under a limit", true)
            s:slider("shard_cap", "Soul shards to keep", 4, 32, 20, "")
            s:label("At the limit Drain Soul stops making more (unless Improved Drain")
            s:label("Soul's mana refund is needed while mana is short).")
            s:label("Spare shards become a Spellstone or a Firestone where they")
            s:label("can, out of combat; what is left over is destroyed. In a fight")
            s:label("a shard over the limit is destroyed at once. Destroying cannot")
            s:label("be undone.")
            s:label("A soulstone on yourself is a free resurrection where you stand.")
            s:separator()
        end,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        burst = {
            { spell = "Amplify Curse", duration = 6 },
        },

        --- In combat (1.73.4): over the limit, a shard is destroyed at once,
        --- one every two seconds at most (hardcore.destroy_one's lockout).
        --- The user: "Dump Soul shards if it hits the limits" -- Soul
        --- Harvest's kills pass the limit by design, and a long fight used to
        --- leave every spare in the bags until it ended. Out of combat the
        --- idle hook below still turns a spare into a stone first.
        combat_upkeep = function(s)
            if not CS.opt("shard_dump", true) then return false end
            local hc = P.hardcore
            if not hc or not hc.destroy_one then return false end
            local held, cap = shard_count(), shard_cap()
            if held <= cap then return false end
            return hc.destroy_one("soulshard", string.format("%d shards, over the %d we keep", held, cap))
        end,

        --- Out of combat housekeeping. Applying the soulstone is an ITEM
        --- use rather than a cast, so it cannot be a priority rule -- the
        --- engine resolves rules through the spellbook.
        idle = function(s)
            local hc = P.hardcore
            if not hc then return false end

            if soulstone_unused() then
                if hc.use_item("soulstone", "so a death is recoverable") then
                    return true
                end
            end

            -- The overflow, after every productive use above has had its turn.
            -- Destroying is irreversible and there is no confirmation step, so
            -- it happens one shard at a time, out of combat only, and never
            -- below the cap.
            if CS.opt("shard_dump", true) then
                local held, cap = shard_count(), shard_cap()
                if held > cap then
                    if hc.destroy_one("soulshard", string.format(
                        "%d shards, over the %d we keep", held, cap)) then
                        return true
                    end
                end
            end

            return false
        end,

        class_name = "WARLOCK",
        power = "MANA",
        -- Spell Lock is a PET spell. Routing it through the player interrupt
        -- list would silently never fire, because the player does not know it.
        interrupts = {},
        pet_interrupts = { "Spell Lock" },
        defensives = { "Death Coil", "Drain Life" },
        escapes = { "Howl of Terror", "Fear", "Death Coil" },
        -- Abilities that wait for a key rather than firing on their own. Fear
        -- stays in the escape list above on purpose: with the key held it is
        -- still the right thing to break contact with, and without it Howl of
        -- Terror and Death Coil cover the emergency on their own.
        key_gated = { ["Fear"] = "rot_fear_key" },
        profiles = profiles,
        profile_order = { "leveling", "leveling_bolt", "affliction",
                          "destruction", "demonology" },
        suggest = function(t)
            local affliction, demonology, destruction = t.points()
            local total = affliction + demonology + destruction
            if total < 20 then return "leveling" end
            if affliction >= demonology and affliction >= destruction then return "affliction" end
            if destruction >= demonology then return "destruction" end
            return "demonology"
        end,
    }
end

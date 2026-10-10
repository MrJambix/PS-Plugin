-- Jambix AIO / classes / hunter
--
-- Source for the levelling profile: the Classic Beast Mastery levelling
-- guide's rotation, which reads, in order --
--
--   pet attacks; Hunter's Mark; Intimidation; Bestial Wrath; Aimed Shot;
--   Auto Shot; Serpent Sting; Auto Shot; Aimed Shot if fine on mana;
--   Multi-Shot if fine on mana; Auto Shot until the enemy is dead.
--
-- Three things in that list are not casts and each was missing at some
-- point:
--
--   THE MARK IS THE PULL; THE DAMAGE WAITS FOR THE PET. Hunter's Mark goes
--   first, always: it carries almost no threat and it is what starts the
--   mob moving. Solo, the pet is the tank, and a mob switches to whoever
--   has the most threat -- so the big threat (Aimed Shot, the sting) waits
--   until the mob is actually ON the pet, or the wait has
--   stopped being useful (the pet was never sent, is not getting there, or
--   the mob is already on us in melee). One Aimed Shot before the pet has
--   the mob is 600 threat the pet cannot out-growl, and that is how a mob
--   ends up in your face. Auto Shot never waits: its threat is a fraction
--   of one Growl, and it is most of the damage. In a group with its own
--   tank nothing waits. The pet is sent by modules/pet.lua; this file only
--   reads who the mob is on.
--
--   AUTO SHOT IS A TOGGLE. Like a wand's Shoot, pressing it starts
--   auto-repeat and pressing it again STOPS it, and no shot ability starts it
--   for you. It goes through the same guarded press logic as the wand
--   (H.auto_repeat in rotation.lua), which is what stops a toggle from
--   flickering on and off every tick.
--
--   THE OPENER IS A QUESTION OF TIME, NOT OF HEALTH. Aimed Shot is a
--   three-second cast that is worth it exactly when it lands before the
--   mob does: on a mob the pet holds, or on one far enough away. A mob that
--   will be in our face in two seconds gets instants instead -- Concussive
--   Shot to daze it, Arcane Shot and Serpent Sting on the way in -- and a
--   mob that reaches us gets Wing Clip and a step back out of the dead zone
--   (modules/kite.lua owns the legs), not Raptor Strike.
--
-- The pet is half the class. Everything pet-related is owned by
-- modules/pet.lua; this file only declares which pet abilities matter.

return function(P, H, CS)
    local book, units = H.book, H.units

    local RUN_SPEED = 7            -- yards per second: a mob at normal run speed
    local AIMED_CAST = 3.0         -- seconds; the cast the opener has to land
    local MIN_RANGE = 8            -- inside this no shot works
    local MELEE_REACH = 5
    local PET_LEAD_PATIENCE = 4    -- seconds to wait for the mob to turn onto the pet
    local SEND_PATIENCE = 2        -- seconds to wait for the pet module to send it at all

    --- An ordered ability list from the catalogue, or the fallback.
    ---@param name string
    ---@param fallback string[]
    ---@return string[]
    local function catalog_list(name, fallback)
        local data = P.catalog and P.catalog.for_class("hunter")
        local list = data and data.lists and data.lists[name]
        if type(list) == "table" and #list > 0 then return list end
        return fallback
    end

    -- --- mana ---------------------------------------------------------------
    --
    -- Auto Shot is free and is most of the damage. Every special is mana
    -- spent to end the fight a little sooner, and mana spent is drinking
    -- later -- and the five-second rule makes it worse: any cast stops mana
    -- regeneration for five seconds, so a hunter who only shoots regenerates
    -- through the fight, while one who casts a filler every global cooldown
    -- never does. So specials are bought in TIERS, best value first, from
    -- what the bar and the resource model's posture say:
    --
    --   0  nothing that costs mana except safety (the slows, the clip) and
    --      Mend Pet: the bar will not last this fight, or it is nearly empty
    --   1  the essentials: Hunter's Mark, the Aimed Shot opener, a sting on
    --      a mob that will live to take every tick
    --   2  plus the second Aimed Shot and a sting on a normal mob
    --   3  plus the fillers -- Multi-Shot and Arcane Shot on one target --
    --      which add the least damage for the most mana
    --
    -- Absolute fractions, not the auto-tuned conserve line: that line is
    -- derived from the cost of a caster's filler, and a hunter's filler is a
    -- free shot.
    -- TIER 3 IS THE FIGHT'S CALL, NOT A SLIDER (1.33.0). The fillers used to
    -- wait for 70% mana whatever was happening. Now they go out while the bar
    -- will last the fight -- the resource model measures how fast it is going
    -- and how long the mobs have left -- and stop once it will not, or once
    -- the posture says conserve. The reaction engine also scores each spell
    -- by what it costs (react/adapt.lua), so a cheap one still beats a dear one.
    --
    -- LET THE SPIRIT WORK (1.7.4). The user: "hunter rotaiton burns through
    -- alot of mana doest let the spirit recharge up". The live log (a level
    -- 19 hunter on Forever, 606 mana) went from a full bar to 30 in three
    -- minutes of seven-second fights, with a press that costs mana every two
    -- seconds of each: Multi-Shot on one mob at a full bar, the hawks, the
    -- sting, then Concussive Shot, Wing Clip and Raptor Strike on a mob with
    -- a second to live. The five-second rule never ran out, so spirit gave
    -- nothing back until the fight was over. "The bar will last this fight"
    -- was true of every one of them; it was the next ten it would not last.
    -- Three answers:
    --
    --   THE REFILL. Once the bar falls under a line, the specials stop at
    --   the essentials (tier 1) and stay there until spirit has it back up
    --   to a higher one. A gap, not a line: on a line every fight spends the
    --   bar straight back down to it, and it never refills.
    --   THE FILLERS ARE FOR A NEARLY FULL BAR. Tier 3 only near the top,
    --   where regeneration is about to have nowhere to go.
    --   NOTHING ON A MOB ABOUT TO DIE (dying, below).
    --
    -- How hard is the class option "Mana for extra shots". Spend freely is
    -- the rule as it was before 1.7.4.
    local MANA_USE = { "Spend freely", "Balanced", "Save for regen" }
    local MANA_BALANCED = 2
    local MANA_LINES = {
        { refill_below = 0, refill_until = 0, fillers_from = 0 },
        { refill_below = 0.50, refill_until = 0.80, fillers_from = 0.80 },
        { refill_below = 0.70, refill_until = 0.95, fillers_from = 0.95 },
    }
    local refilling = false

    local function mana_lines()
        local pick = CS and CS.opt("mana_use", MANA_BALANCED) or MANA_BALANCED
        return MANA_LINES[pick] or MANA_LINES[MANA_BALANCED]
    end

    --- Is spirit refilling the bar? From under the low line until the high one.
    local function refill(mana, lines)
        if refilling then
            if mana >= lines.refill_until then refilling = false end
        elseif mana < lines.refill_below then
            refilling = true
        end
        return refilling
    end

    local function spend_tier(s)
        local posture = s.posture or "HEALTHY"
        local mana = H.power_fraction(s)
        local lines = mana_lines()
        -- Read before the early returns, so an empty bar starts the refill too.
        local held = refill(mana, lines)
        if posture == "CRITICAL" or posture == "RECOVER" or mana < 0.15 then return 0 end
        if mana < 0.45 or held then return 1 end
        if posture == "CONSERVE" then return 2 end
        local res = s.res
        local empty = res and res.power_empty
        local left = s.fight_left
        if type(empty) == "number" and type(left) == "number" and empty < left then return 2 end
        if mana < lines.fillers_from then return 2 end
        return 3
    end

    -- NOTHING ON A MOB ABOUT TO DIE (1.7.4). Each special is mana and five
    -- more seconds without regeneration, and Auto Shot and the pet finish a
    -- mob this close to dead anyway. The reaction engine's own version
    -- (react/adapt.lua, FINISHING) stands aside once the mob is on us; this
    -- does not: a mob dead in two seconds needs no clip and no swing either.
    -- 0 is a mob at no health; an unmeasured one reads huge and is not dying.
    local DYING = 2.5

    local function dying(s)
        return s.in_combat == true and s.target ~= nil and (s.ttd or math.huge) < DYING
    end

    --- Serpent Sting when the mob will live long enough for it to be worth
    --- its mana: every tick when mana is short, most of them when it is not.
    local Sting_ttd = { [0] = math.huge, [1] = 13, [2] = 10, [3] = 8 }

    -- ON MORE THAN ONE MOB (1.84.0). The user: "multi dot functionality when
    -- 2-3 mobs are up with serpent sting". The rules carry `spread`, so the
    -- engine asks about every engaged mob once the target has its sting;
    -- this caps how many carry one (the class option, default three). Each
    -- one still has to live long enough for the sting, on that mob's own
    -- time to die, and the bar has to afford it (the tiers above).
    local STING_SPREAD = { "My target only", "Up to 2 mobs", "Up to 3 mobs" }
    local STING_CAP = { 1, 2, 3 }

    local function stung(s)
        local list, n = s.engaged_units, 0
        if type(list) ~= "table" then return 0 end
        for i = 1, #list do
            local unit = list[i]
            if unit:is_valid() and not unit:is_dead() and H.debuff_remaining(unit, "Serpent Sting") > 0 then
                n = n + 1
            end
        end
        return n
    end

    --- Asked about another mob (the engine's `spread`): under the cap?
    local function spread_ok(s)
        if not s.spreading then return true end
        local cap = STING_CAP[CS and CS.opt("sting_spread", 3) or 3] or 1
        return cap > 1 and stung(s) < cap
    end

    local function sting_wanted(s)
        if not spread_ok(s) then return false end
        return H.dot_worth_it(s, "Serpent Sting", Sting_ttd[spend_tier(s)])
    end

    --- A hunter's damage comes from Auto Shot, and every special that is not
    --- worth its mana is a shot not taken. At range the melee abilities are
    --- dead entries; in melee the shots are. The client's usability answer
    --- sorts that out, so distance only gates what it genuinely has to.
    -- HITBOX TO HITBOX (1.58.1): the client's geometry, from the rotation's
    -- helpers (rotation.lua, H.gap / H.in_melee); the centre against five and
    -- eight where a build has none.
    local function gap(unit, distance)
        if H.gap then return H.gap(unit, distance) end
        return distance or units.distance(unit)
    end

    local function in_melee(s)
        if s.target == nil then return false end
        if H.in_melee then return H.in_melee(s.target) end
        return units.distance(s.target) <= MELEE_REACH
    end

    local function at_range(s)
        return s.target ~= nil and gap(s.target) > MIN_RANGE
    end

    local function standing(s)
        return not s.player:is_moving()
    end

    --- Nobody else here to hold a mob: no party, no dungeon, no raid.
    local function solo()
        local targeting = P.targeting
        if not targeting or type(targeting.context) ~= "function" then return true end
        local ok, here = pcall(targeting.context)
        return not ok or here == nil or here == targeting.SOLO
    end

    -- THE AOE MELEE WEAVE (1.7.6, ALPHA/TEST). Its class option runs the
    -- `aoe_weave` profile (below); you walk in and out yourself. Read this
    -- early because Auto Shot needs it: a strike or the swing in melee stops
    -- Auto Shot, so its first press back at range goes at once.
    local AOE_WEAVE = "aoe_weave"

    local function aoe_weave_on()
        return CS ~= nil and CS.opt(AOE_WEAVE, false) == true
    end

    local function forecast()
        return H.forecasting ~= nil and H.forecasting() == true
    end

    local melee_seen_at, restarted_at = -math.huge, -math.huge

    --- In melee with the target. With the AOE weave on, the moment is kept
    --- (not by the spell window's forecast, which asks about other mobs).
    local function aoe_in_melee(s)
        local inside = in_melee(s)
        if inside and aoe_weave_on() and not forecast() then melee_seen_at = core.time() end
        return inside
    end

    --- Auto Shot is owed a press straight back from melee: true once per
    --- trip out, while the AOE weave is on.
    local function aoe_back()
        if not aoe_weave_on() or forecast() or melee_seen_at <= restarted_at then return false end
        restarted_at = core.time()
        return true
    end

    -- --- reading the fight --------------------------------------------------
    --
    -- The awareness snapshot (s.target_row, from the core's enemies reader)
    -- says who the target is looking at and how fast it is closing. Every
    -- reader below answers sensibly without it, so a build without the
    -- reader degrades to the old distance-only behaviour rather than to
    -- nothing.

    local function on_me(s)
        local row = s.target_row
        return row ~= nil and row.targeting_me == true
    end

    local function pet_alive()
        return P.pet ~= nil and P.pet.alive()
    end

    --- Is the mob on the pet? The awareness row says so when it can; the
    --- mob's own target is read as well, because the row's detail can lag
    --- a moment and a moment here is a shot not taken.
    local function on_pet(s)
        local row = s.target_row
        if row and row.targeting_pet == true then return true end
        if not s.target or not pet_alive() then return false end
        local ok, their = pcall(s.target.get_target, s.target)
        if not ok or not their then return false end
        local pet = P.pet.pet()
        local theirs = units.guid(their)
        return pet ~= nil and theirs ~= nil and theirs == units.guid(pet)
    end

    --- Is the pet on our target? Intimidation stuns whatever the PET is
    --- hitting, so firing it while the pet is still running in stuns nothing.
    local function pet_on_target(s)
        if not s.target or not pet_alive() then return false end
        local held = P.pet.pet_target()
        if not held then return false end
        local ok_a, a = pcall(held.get_guid, held)
        local ok_b, b = pcall(s.target.get_guid, s.target)
        return ok_a and ok_b and a ~= nil and a == b
    end

    --- Under any slow or root of ours. The catalogue says which abilities
    --- those are and what aura each leaves; the two names are the fallback
    --- for a build without it.
    ---@param target game_object|nil
    local function slowed(target)
        if not target then return false end
        local catalog = P.catalog
        if catalog then
            local any = false
            for _, role in ipairs({ "slow", "root" }) do
                local rows = catalog.with_role(role)
                for i = 1, #rows do
                    any = true
                    local aura = rows[i].applies and rows[i].applies.aura
                    if aura and H.debuff_up(target, aura) then return true end
                end
            end
            if any then return false end
        end
        return H.debuff_up(target, "Concussive Shot") or H.debuff_up(target, "Wing Clip")
    end

    --- Seconds until the target is in melee with us. Huge when it is not
    --- coming: it is on the pet, or engaged and not closing.
    ---@param s table
    ---@return number
    local function reach_in(s)
        if not s.target then return math.huge end
        local distance = s.distance or units.distance(s.target)
        if distance <= MELEE_REACH and on_me(s) then return 0 end
        if on_pet(s) then return math.huge end

        local row = s.target_row
        if row then
            if row.targeting_me and (row.closing or 0) > 0.5 then
                local eta = row.time_to_reach
                if type(eta) == "number" and eta < math.huge then return eta end
                return math.max(0, (distance - MELEE_REACH) / row.closing)
            end
            -- Engaged with us but not closing on us: on the pet, or standing.
            if row.engaged then return math.huge end
        end

        -- Not engaged. The first thing that hits it sends it at whoever hit
        -- it: the pet if the pet is on it, otherwise us, at run speed.
        if pet_on_target(s) then return math.huge end
        local speed = slowed(s.target) and (RUN_SPEED / 2) or RUN_SPEED
        return math.max(0, (distance - MELEE_REACH) / speed)
    end

    --- Will a cast of this length land before the mob lands on us?
    local function cast_safe(s, seconds)
        return reach_in(s) > seconds + 0.5
    end

    -- --- the pet goes first -------------------------------------------------

    local lead_guid, lead_since = nil, 0

    --- May the damage start? Solo with a pet out, only once the mob is ON
    --- the pet: the pet is the tank, and threat put on us before it has the
    --- mob is threat it has to out-growl. Waiting stops being useful when
    --- the pet module has not sent it, when it was sent and is not getting
    --- there, or when the mob is already on us in melee -- then the shots
    --- (and the clip) go. In a group with its own tank nothing waits.
    ---@param s table
    ---@return boolean
    local function pet_leads(s)
        if not s.target then return true end
        if not pet_alive() or not solo() then return true end
        local mode = P.pet.mode()
        if mode == P.pet.OFF or mode == P.pet.FOCUS then return true end

        if on_pet(s) then return true end
        -- On us and not closing: it is already hitting us (or casting at
        -- us) and holding fire only lets it. The wait is for the mob that
        -- is still RUNNING at us behind a fresh mark, where the pet can
        -- still catch it first.
        if on_me(s) then
            local row = s.target_row
            local closing = row and row.closing or 0
            if (s.distance or units.distance(s.target)) <= MELEE_REACH then return true end
            if closing <= 0.5 then return true end
        end

        local now = core.time()
        local sent = P.pet.sent_for and P.pet.sent_for(s.target) or nil
        if not sent then
            -- The pet module decides on its own tick; give it a moment, and
            -- if it will not send the pet (held back, no path), go anyway.
            local guid = units.guid(s.target)
            -- The spell window's forecast asks too, about a mob the walk
            -- is not acting on yet. It reads the clock and never starts
            -- it, or merely selecting a mob would use up the wait.
            if H.forecasting and H.forecasting() then
                return guid == lead_guid and (now - lead_since) > SEND_PATIENCE
            end
            if guid ~= lead_guid then lead_guid, lead_since = guid, now end
            return (now - lead_since) > SEND_PATIENCE
        end
        return sent > PET_LEAD_PATIENCE
    end

    --- Wraps a damage predicate so it waits for the pet to have the mob,
    --- and (1.7.4) is not spent on a mob about to die.
    local function lead(pred)
        return function(s) return pet_leads(s) and not dying(s) and pred(s) end
    end

    --- Our mark on another mob of this fight, one that will live a while
    --- yet. A hunter has ONE mark: marking the new target takes it off the
    --- old one. In a pack the target changes whenever a mob turns onto us,
    --- and the live log has the mark following it four times in twenty
    --- seconds -- a global cooldown and mana per switch for a bonus that
    --- only moves. It stays where it is until that mob is nearly dead.
    local function mark_elsewhere(s)
        local list = s.engaged_units
        if type(list) ~= "table" then return false end
        for i = 1, #list do
            local unit = list[i]
            if unit ~= s.target and unit:is_valid() and not unit:is_dead()
                and H.debuff_up(unit, "Hunter's Mark") then
                local ok, hp = pcall(units.health_fraction, unit)
                if not ok or type(hp) ~= "number" or hp > 0.2 then return true end
            end
        end
        return false
    end

    -- WHICH MOBS ARE WORTH A MARK (1.84.0). The user, on Forever: "my hunter
    -- spends more time putting up mark than actually dpsing" and "a setting
    -- to only mark bosses? in dungeon also". Every pull opened with it: a
    -- global cooldown and mana for a bonus a levelling mob dies under. A
    -- boss is the client's own word: its classification (3) or its boss flag
    -- (`is_boss`, which answers on Forever and retail; Era has none, and its
    -- dungeon bosses read as elites there). The setting holds everywhere,
    -- dungeons included.
    local MARK_ON = { "Every target", "Elites and bosses", "Bosses only", "Never" }
    local MARK_EVERY, MARK_ELITES, MARK_BOSSES, MARK_NEVER = 1, 2, 3, 4

    local function rank_of(unit)
        local svc = P.units or units
        local rank = 0
        if svc and svc.classification then
            local ok, value = pcall(svc.classification, unit)
            if ok and type(value) == "number" then rank = value end
        end
        local ok_b, boss = pcall(function() return unit:is_boss() end)
        return rank, rank == 3 or (ok_b and boss == true)
    end

    local function worth_marking(target)
        local mode = CS and CS.opt("mark_on", MARK_EVERY) or MARK_EVERY
        if mode == MARK_EVERY then return true end
        if mode == MARK_NEVER then return false end
        local rank, boss = rank_of(target)
        if mode == MARK_BOSSES then return boss end
        return boss or rank == 1 or rank == 2
    end

    --- The mark, on every pull the bar can afford (or only the mobs the
    --- class option names). On an empty bar only when the fight is long
    --- enough for its attack power to pay for itself.
    local function mark_wanted(s)
        if not s.target or H.debuff_up(s.target, "Hunter's Mark") then return false end
        if not worth_marking(s.target) then return false end
        if s.in_combat and mark_elsewhere(s) then return false end
        -- Not on a mob about to die (1.74.0): its bonus would last a shot or
        -- two, and at the kill the mark is already gone while the client
        -- still calls the mob alive -- the live log's "Your target is dead".
        if s.in_combat and (s.ttd or math.huge) < 3 then return false end
        if spend_tier(s) >= 1 then return true end
        return s.ttd > 15 and H.power_fraction(s) > 0.05
    end

    -- --- opening the pull ---------------------------------------------------
    --
    -- The rotation holds fire on a mob that has not engaged us unless the
    -- "start fights" switch or the engage key says otherwise. For a hunter
    -- that default is the whole problem: the mob is only "engaged" once it
    -- has aggroed by walking into its own radius, ten to fifteen yards out,
    -- and it reaches melee before a mark and a three-second cast can land.
    -- A hunter opens at thirty yards, so this says when the selected mob is
    -- ours to open on.
    --
    -- ONLY WITH "START FIGHTS" ON (1.75.0). It used to be asked with the
    -- switch off too, and with auto-targeting that pulled whatever was
    -- selected in shot range. The user: "i shouldnt be just auto initiating
    -- fights either. Should be when I go into Attack mode". Off, the pull is
    -- yours (Attack, a right-click, your own shot) and the rotation takes it
    -- from there; on, this is which selected mobs the switch opens on.

    local PULL_MAX = 35            -- shot range, not the mark's 100: the shots follow the mark

    --- Is this a player? Only the client's own answer, and only a definite
    --- yes counts. NOT the class id: every creature in this game carries one
    --- too (a wolf is a "warrior" for stat purposes), so reading that would
    --- call every mob a player and never open on anything.
    local function is_player(target)
        local ok, yes = pcall(function() return target:is_player() end)
        return ok and yes == true
    end

    --- May the rotation open on this selected, unengaged mob? The second
    --- value is why not, for the watch line.
    ---@param target game_object
    ---@return boolean
    ---@return string|nil reason
    local function may_open(target)
        if not target or not target:is_valid() or target:is_dead() then return false, "no live target" end
        -- Where pulls are ours to start: the aggro-scope setting, never PvP.
        local targeting = P.targeting
        if targeting and type(targeting.may_control_pull) == "function"
            and not targeting.may_control_pull() then
            local here = type(targeting.context) == "function" and targeting.context() or "?"
            return false, "pulls are not ours to start here (" .. tostring(here) .. ")"
        end
        if is_player(target) then return false, "target is a player" end
        -- Something has to be trained that makes a pull from range a pull.
        if not (book.known("Hunter's Mark") or book.known("Auto Shot")) then
            return false, "neither Hunter's Mark nor Auto Shot is trained"
        end

        local distance = units.distance(target)
        if gap(target, distance) < MIN_RANGE then
            return false, string.format("inside minimum range (%.1fy from its edge)", gap(target, distance))
        end
        if distance > PULL_MAX then return false, string.format("beyond shot range (%.0fy)", distance) end

        -- Not a mob already fighting someone else, and not one under control.
        local enemies = P.ctx and P.ctx.enemies
        local row = enemies and enemies.get and enemies.get(target) or nil
        if row then
            if row.in_combat and not row.targeting_me and not row.targeting_pet then
                return false, "already fighting someone else"
            end
            if row.control then return false, "under crowd control" end
        end
        return true, nil
    end

    -- No aspect rule (1.49.0): the aspect is the player's, switched in the
    -- Aspects window (modules/aspects.lua), and the catalogue gate refuses
    -- one from any rule or reaction.

    -- --- Auto Shot ----------------------------------------------------------

    -- Auto Shot IS the auto attack, so the unit's own attack flag counts as
    -- "running", and a shot within one swing of the weapon does too. The
    -- weave's readout of the last real shot (it also reads the swing timer
    -- addon) is handed in, so a shot the cast stream missed still counts.
    -- What this client does with an auto-repeat press (JCore's world.client(),
    -- 1.6.0): one shot per press (auto_repeat_once: re-arm after each shot),
    -- melee Attack taking the START (auto_start_melee), and whether the API
    -- recorder runs (recording: the per-mob trace line). All false on Era.
    local client = {}
    do
        local world = P.ctx and P.ctx.world
        local ok, c = pcall(function() return world and world.client and world.client() end)
        if ok and type(c) == "table" then client = c end
    end

    local auto_shot = H.auto_repeat("Auto Shot", {
        auto_attack = true, period = 3.5,
        -- Kept on: the press is the client's START, which cannot switch it
        -- off, so every new target gets Auto Shot at once and a stop is
        -- noticed within a swing (rotation.lua, make_auto_repeat).
        keep_on = true,
        -- Forever fires one shot per press (the beta recording, 2026-10-03):
        -- every shot is followed by the next press there. Era: unchanged.
        rearm = client.auto_repeat_once == true,
        shot_at = function()
            local weave = P.weave
            return weave and weave.last_shot_at and weave.last_shot_at() or 0
        end,
    })

    local RANGED_MAX = 41           -- 35 base plus Hawk Eye; the client's range check is the real gate
    local eligible_since = nil      -- since when we have been standing, in range, able to shoot

    local speed_read_at, speed_known = 0, 2.5

    --- Seconds between Auto Shots, from the weapon. Read every few seconds
    --- rather than every tick: it changes when the bow does.
    local function ranged_period(s)
        local now = core.time()
        if (now - speed_read_at) > 5 then
            speed_read_at = now
            local ok, info = pcall(s.player.get_unit_ranged_damage, s.player)
            if ok and type(info) == "table" and type(info.speed) == "number"
                and info.speed > 0.5 and info.speed < 10 then
                speed_known = info.speed
            end
        end
        return speed_known + 1.0
    end

    --- True only when pressing Auto Shot would START it. Minimum range is
    --- eight yards; inside it the press does nothing but toggle.
    ---
    --- THE MELEE FLAG. Wing Clip or Raptor Strike starts the melee auto
    --- attack, which in Classic STOPS Auto Shot -- and then the unit's
    --- attack flag reads "attacking" for as long as we stay in combat, which
    --- the guard would take as Auto Shot running. So the guard is also told
    --- what it cannot see: we have been standing, in range, able to shoot,
    --- for longer than a swing, and no shot has come. Once shots have been
    --- observed this session at all, that is believed over the flag.
    local shooting_guid = nil       -- the target Auto Shot was last asked about

    -- WHAT AUTO SHOT DID AT EACH MOB (Forever only): presses by reason and
    -- the shots that followed, one recorder trace line per mob when the next
    -- one is taken. One shot per press there is the reason for the re-arm;
    -- this line is how the next session shows whether the re-arm keeps a
    -- shot going out every swing.
    local tally = nil

    -- 1.52.0: and WHY a press made no shot. Where the time went (standing in
    -- range able to shoot, moving, inside the minimum range, too far), how
    -- often the client refused Auto Shot (UNIT_SPELLCAST_FAILED, _QUIET),
    -- and the red text that came within 1.5 s of a press (the event does not
    -- say which spell it was about). Session 26 had "3 presses, 0 shots in
    -- 17.4s" at 9.5 to 11 yards with nothing to say why.
    local function tally_flush()
        local t = tally
        tally = nil
        if not t or t.presses == 0 then return end
        local emit = P.ctx and P.ctx.emit
        if type(emit) ~= "function" then return end
        local shots = (auto_shot.shots or 0) - t.shots_before
        local errs = {}
        for text, n in pairs(t.errors or {}) do errs[#errs + 1] = string.format("%s x%d", text, n) end
        table.sort(errs)
        pcall(emit, "jcore.recorder.trace", string.format(
            "hunter Auto Shot at %s: %d presses (%d new target, %d after a shot, %d retries), %d shots in %.1fs;"
                .. " ready %.1fs, moving %.1fs, too close %.1fs, too far %.1fs; refused %d (quietly %d)%s",
            tostring(t.guid):sub(-10), t.presses, t.fresh, t.after_shot, t.retry, shots,
            core.time() - t.started, t.ready or 0, t.moving or 0, t.close or 0, t.far or 0,
            t.failed or 0, t.quiet or 0, #errs > 0 and ("; errors: " .. table.concat(errs, ", ")) or "")
            .. ((t.melee_stops or 0) > 0 and string.format("; melee attack stopped %d", t.melee_stops) or ""))
    end

    if client.recording and P.ctx and type(P.ctx.on) == "function" then
        local AUTO_SHOT_ID = 75
        P.ctx.on("jcore.game_event.UI_ERROR_MESSAGE", function(args)
            local t = tally
            if not t or type(args) ~= "table" then return end
            if core.time() - (t.last_press or -math.huge) > 1.5 then return end
            local text = tostring(args[2] or args[3] or "?")
            t.errors = t.errors or {}
            t.errors[text] = (t.errors[text] or 0) + 1
        end)
        P.ctx.on("jcore.game_event.UNIT_SPELLCAST_FAILED", function(args)
            local t = tally
            if t and type(args) == "table" and args[1] == "player" and tonumber(args[3]) == AUTO_SHOT_ID then
                t.failed = (t.failed or 0) + 1
            end
        end)
        P.ctx.on("jcore.game_event.UNIT_SPELLCAST_FAILED_QUIET", function(args)
            local t = tally
            if t and type(args) == "table" and args[1] == "player" and tonumber(args[3]) == AUTO_SHOT_ID then
                t.failed = (t.failed or 0) + 1
                t.quiet = (t.quiet or 0) + 1
            end
        end)
    end

    local function auto_shot_wanted(s)
        local now = core.time()
        -- A new target: Auto Shot stopped with the old one, and whatever we
        -- cast since says nothing about it. Press as soon as it is wanted.
        local guid = s.target and units.guid(s.target) or nil
        if guid ~= shooting_guid then
            if client.recording then tally_flush() end
            shooting_guid = guid
            eligible_since = nil
            if auto_shot.forget then auto_shot.forget() end
        end
        -- Where the time goes while this mob is the target (the trace line).
        if tally then
            local bucket = (not standing(s)) and "moving"
                or (not at_range(s)) and "close"
                or (s.distance > RANGED_MAX) and "far" or "ready"
            local dt = now - (tally.clock or now)
            if dt > 0 and dt < 1 then tally[bucket] = (tally[bucket] or 0) + dt end
            tally.clock = now
        end
        if not at_range(s) or not standing(s) or s.distance > RANGED_MAX then
            eligible_since = nil
            return false
        end
        eligible_since = eligible_since or now

        -- BACK FROM MELEE (1.7.6, the AOE melee weave): a strike or the swing
        -- stopped Auto Shot, so the press goes now, not a swing later.
        local back = aoe_back()
        if back and auto_shot.restart then auto_shot.restart() end

        local period = ranged_period(s)
        auto_shot.set_period(period)
        local stale = (now - eligible_since) > period and auto_shot.since_shot() > period

        local fresh = auto_shot.is_fresh ~= nil and auto_shot.is_fresh()
        -- Read before the press moves pressed_at: did a shot follow the last one?
        local after_shot = (auto_shot.last_fired or 0) > 0
            and (auto_shot.last_fired or 0) >= (auto_shot.pressed_at or 0)
        if auto_shot.press_wanted(P.opt("rot_wand_recheck", 6), stale) then
            -- Measure the next absence from this press, not from before it.
            eligible_since = now
            if client.recording and guid then
                if not tally then
                    tally = { guid = guid, started = now, presses = 0, fresh = 0,
                              after_shot = 0, retry = 0, shots_before = auto_shot.shots or 0, clock = now }
                end
                tally.presses = tally.presses + 1
                tally.last_press = now
                if fresh then
                    tally.fresh = tally.fresh + 1
                elseif after_shot then
                    tally.after_shot = tally.after_shot + 1
                else
                    tally.retry = tally.retry + 1
                end
            end
            -- MELEE ATTACK LEFT ON (1.52.0; client.auto_start_melee). The
            -- press goes out through the loader's auto-attack helper as a
            -- START, and the helper reads the player's one attack flag,
            -- which a melee swing sets too: after Raptor Strike, or a
            -- right-click on the mob, the START at range is taken as
            -- "already running" and nothing is sent ("1 press, 0 shots in
            -- 15.7s" after a wolf fought in melee). So when a press has had
            -- no shot after it -- Auto Shot is plainly not running -- and the
            -- flag still reads on, out here past the minimum range, it is
            -- melee: stop it, and the START goes through (at the latest, the
            -- next retry). Straight back from the AOE weave's melee it is
            -- melee for certain (1.7.6).
            if client.auto_start_melee and (back or (not fresh and not after_shot)) and s.player then
                local ok_m, melee = pcall(s.player.is_auto_attacking, s.player)
                if ok_m and melee == true then
                    local input = core.input
                    if input and type(input.stop_attack) == "function" and pcall(input.stop_attack) then
                        if tally then tally.melee_stops = (tally.melee_stops or 0) + 1 end
                    end
                end
            end
            if fresh and P.log then
                -- JCore's name for it: get_name is often "" on Forever (1.55.4).
                local u = P.units
                local ok, name = pcall(function()
                    if u and u.name then return u.name(s.target) end
                    return s.target:get_name()
                end)
                P.log.fmt("info", "Auto Shot: on for %s (new target)",
                    (ok and type(name) == "string" and name ~= "") and name or "the target")
            end
            return true
        end
        return false
    end

    --- For the watch line: what the Auto Shot rule would do now, without
    --- pressing. Returns a reason it is held, or (nil, "firing ...") when
    --- shots are landing on this target. Moving and range are the
    --- catalogue's to say, and the watch already says them.
    ---@return string|nil held
    ---@return string|nil running
    local function auto_shot_status(s)
        if auto_shot.since_shot_here and auto_shot.since_shot_here() < auto_shot.period then
            return nil, "firing at this target"
        end
        -- Only the kept-on path is asked: the cautious one keeps
        -- calibration state that a reader must not move.
        if auto_shot.keep_on and auto_shot.starts_safely and auto_shot.starts_safely()
            and not auto_shot.would_press(P.opt("rot_wand_recheck", 6), false) then
            return "started, waiting for its first shot"
        end
        return nil
    end

    -- AUTO SHOT NEVER WAITS FOR THE PET. lead()'s wait exists for the
    -- threat that a pet cannot out-growl -- Aimed Shot's six hundred, the
    -- sting -- and Auto Shot is neither: a shot is its damage in threat, a
    -- fraction of one Growl. Waiting cost far more than it saved. The live
    -- log has two to four seconds of nothing after every mark, a quarter of
    -- a twelve-second fight, and the first version of this exempted only
    -- a switch mid-fight. Every target, the pull's included, now gets Auto
    -- Shot as soon as it can fire.
    local auto_shot_rule = auto_shot_wanted

    -- --- the pet's part -----------------------------------------------------

    local function intimidation_wanted(s)
        if not s.in_combat then return false end
        return pet_on_target(s)
    end

    --- Bestial Wrath on cooldown while levelling, the way the guide has it:
    --- a two-minute cooldown against fights every half a minute is back
    --- before it is wanted again, so holding it is waste. The fight still
    --- has to last long enough to use some of it, and a burst window the
    --- burst module opened always counts.
    local function bestial_wrath_wanted(s)
        if H.bursting() then return pet_alive() end
        if not s.in_combat or not pet_on_target(s) then return false end
        return s.ttd > 8 or (s.melee or 0) >= 2
    end

    -- --- the shots ----------------------------------------------------------

    --- The opener: the first Aimed Shot of a fight, from range, standing
    --- still, and only when its three seconds land before the mob does.
    local function aimed_opener(s)
        if not at_range(s) or not standing(s) or spend_tier(s) < 1 then return false end
        if H.since_cast("Aimed Shot") < 15 then return false end
        return cast_safe(s, AIMED_CAST)
    end

    --- The second Aimed Shot, after the sting, while the bar allows and the
    --- mob is not about to arrive.
    local function aimed_filler(s)
        return at_range(s) and standing(s) and spend_tier(s) >= 2 and cast_safe(s, AIMED_CAST)
    end

    --- Multi-Shot as the guide uses it: the AoE it obviously is against a
    --- pack whenever the bar allows anything, and a single-target filler
    --- only when mana is plentiful -- it is the worst damage per mana here.
    local function multishot_wanted(s)
        if not at_range(s) then return false end
        local tier = spend_tier(s)
        if H.spread(s, 3) then return tier >= 1 end
        return tier >= 3
    end

    -- SUMMON HAWK (Forever, Beast Mastery, 25; 1.80.0). A hawk keeps at the
    -- target for 18 s, two at once, on a 6 s cooldown shared with Arcane Shot.
    -- Every guide keeps two out, so the hawks sent are counted here, one per
    -- press. Arcane Shot gives the cooldown up to them (arcane_wanted, 1.7.5).
    local HAWK_LASTS = 18
    local hawk_presses = {}

    local function hawks_out()
        local now = core.time()
        local since = H.since_cast("Summon Hawk")
        if since < HAWK_LASTS then
            local at = now - since
            local last = hawk_presses[#hawk_presses]
            if not last or (at - last) > 1 then hawk_presses[#hawk_presses + 1] = at end
        end
        for i = #hawk_presses, 1, -1 do
            if (now - hawk_presses[i]) >= HAWK_LASTS then table.remove(hawk_presses, i) end
        end
        return #hawk_presses
    end

    --- Another hawk while fewer than two are out, on anything that lives
    --- long enough for one to work (the guides: "treat it like a DoT").
    --- While the bar refills (tier 1, 1.7.4), one hawk, and only on a mob
    --- that lives as long as a sting needs.
    local function hawk_wanted(s)
        if not s.target or not s.in_combat then return false end
        local tier = spend_tier(s)
        if tier < 1 then return false end
        local wanted, lives = 2, 6
        if tier < 2 then wanted, lives = 1, Sting_ttd[1] end
        if (s.ttd or 0) > 0 and s.ttd < lives then return false end
        return hawks_out() < wanted
    end

    --- Arcane Shot where Aimed Shot cannot do the job -- not trained yet, on
    --- the move, the mob too close for a three-second cast -- and as a
    --- standing filler only when mana is plentiful.
    -- NONE ONCE THE HAWKS ARE TRAINED (1.7.5). Its cooldown is the hawks'
    -- (Forever), and the Mobalytics levelling guide leaves it out for that
    -- reason: "Summon Hawk shares a cooldown with Arcane Shot. This is the
    -- primary reason we aren't using it in the rotation at all." The user
    -- took that over Icy Veins' one Arcane Shot in the gap while both hawks
    -- are up, which is what this did before 1.7.5.
    local function arcane_wanted(s)
        if not at_range(s) then return false end
        if book.known("Summon Hawk") then return false end
        local tier = spend_tier(s)
        if tier < 2 then return false end
        if not book.known("Aimed Shot") then return true end
        if not standing(s) then return true end
        if not cast_safe(s, AIMED_CAST) then return true end
        return tier >= 3
    end

    --- Concussive Shot, for three reasons: a runner heading for friends, a
    --- mob charging us that the pet does not have, and the pre-pet kite's
    --- cycle. Never inside minimum range -- that is Wing Clip's job -- and
    --- never on a mob already slowed. Not on a mob about to die (1.7.4),
    --- unless it is running for help and has more than a second left.
    local RUNNER_DYING = 1
    local function slow_wanted(s)
        if not s.target or slowed(s.target) then return false end
        local distance = s.distance or units.distance(s.target)
        if gap(s.target, distance) <= MIN_RANGE then return false end

        do
            local row = s.target_row
            if row then
                if row.activity == "fleeing" then return (s.ttd or math.huge) >= RUNNER_DYING end
            else
                -- No awareness reader: moving and not looking at us.
                local ok, moving = pcall(s.target.is_moving, s.target)
                if ok and moving then
                    local ok_t, their = pcall(s.target.get_target, s.target)
                    if not (ok_t and their and their:is_valid()
                        and their:get_guid() == s.player:get_guid()) then
                        return (s.ttd or math.huge) >= RUNNER_DYING
                    end
                end
            end
        end

        if dying(s) then return false end

        local row = s.target_row
        if row and row.targeting_me and (row.closing or 0) > 0.5 and distance <= 30 then
            return true
        end

        if P.kite and P.kite.wants_slow and P.kite.wants_slow(s) then return true end
        return false
    end

    --- The mob reached us. Clip it so it cannot follow, then the kite steps
    --- us back out past eight yards and the shots resume. A mob on the pet
    --- that merely stands next to us needs no clip: it will not follow.
    --- Nor does a mob about to die (1.7.4).
    local function clip_wanted(s)
        if not in_melee(s) or slowed(s.target) or dying(s) then return false end
        return not on_pet(s)
    end

    --- Melee is for being stuck, not for being close. While the kite is
    --- stepping us out, a melee swing is a step not taken, and a swing at a
    --- mob about to die (1.7.4) is mana for a kill already made.
    local function melee_stuck(s)
        if not in_melee(s) or dying(s) then return false end
        return not (P.kite and P.kite.active and P.kite.active())
    end

    --- Whatever costs mana and is not the leveling profile's own rule, in
    --- the other three: not on an empty bar or a fight it will not last
    --- (tier 0, 1.7.4).
    local function afford(pred)
        return function(s) return spend_tier(s) >= 1 and pred(s) end
    end

    local function on_pack(s) return H.spread(s, 3) end

    --- The reaction engine owns Mend Pet (one decision per dip of the pet's
    --- health, made before it reaches the line); this rule is what fires if
    --- the engine is not there. The line is the derived one -- the slider
    --- that used to set it is gone.
    local function mend_pet_wanted(s)
        if P.react and P.react.owns and P.react.owns("Mend Pet") then return false end
        local pet = P.pet and P.pet.pet()
        local line = P.derived and P.derived("pet_heal_hp", 20) or 0.20
        return pet ~= nil and P.pet.health() < line
    end

    -- --- Beast Mastery (1.7.6) -----------------------------------------------
    --
    -- The user, 2026-10-10: "let's work on a beast master build (do the
    -- research)". The Beast Mastery profile used to be the Survival list plus
    -- two Era runes Forever lacks (Kill Command, Steady Shot), and under
    -- twenty talent points it never ran at all. This one is built from the
    -- three Forever guides, read 2026-10-10 (Icy Veins, 5 Oct; wowtbc.gg's
    -- Level 30 list; Mobalytics, 9 Oct), which agree:
    --
    --   pet in; Hunter's Mark; the shots once the pet has hit; Serpent Sting;
    --   two hawks out (Summon Hawk: 6 s cooldown, 18 s each); Aimed Shot on
    --   its cooldown, Multi-Shot instead on a pack (one shared cooldown);
    --   Intimidation once the pet is on the mob, for its threat; a mob that
    --   comes to you anyway is fought in melee while the pet takes it back.
    --
    -- It shipped first as an ALPHA behind its own switch. The user, the same
    -- day: "make it the new Rotation for beast master ... then Remove the
    -- option". It runs for every hunter whose talents lead with Beast
    -- Mastery, from the first point (and with none): under twenty points in
    -- place of Levelling, which keeps the hunters led by the other two.
    --
    -- Where it parts from Levelling, on purpose:
    --   THE PET HITS FIRST, AUTO SHOT TOO. Every guide says so. The wait ends
    --   at the pet's first hit, never at a fixed patience (the 2-4 s of
    --   nothing that "AUTO SHOT NEVER WAITS" answered): the mob turning onto
    --   the pet, or losing health with the pet on it, or a beat with the pet
    --   on it. Forever has no combat log to say so outright.
    --   NO DAZE ON A CHARGING MOB AND NO CLIP while the pet is out: no guide
    --   uses them, and the step out only follows a clip. A runner is still
    --   dazed. With no pet out, Levelling's slow and clip come back.
    --   FOREVER'S TWO-SECOND AIMED SHOT, from the catalogue (Era: three).
    --   No Arcane Shot once the hawks are trained (the user's choice, 1.7.5),
    --   no Disengage (they prefer Mobalytics' melee, 2026-10-09).

    local PET_REACH = 5             -- yards, centre to centre: the least a pet strikes from
    local FIRST_HIT_BEAT = 1.0      -- seconds in reach: by then its first swing has landed
    local FIRST_HIT_CAP = 5         -- seconds since it was sent: it is not getting there
    local HURT = 0.995              -- under this much health the mob has been hit

    local reach_guid, reach_since = nil, 0

    --- Is the pet going for our target? The client's answer when it gives
    --- one; else the mob the pet was last sent at (1.73.1: a client that
    --- does not say what the pet is attacking).
    local function pet_on_ours(s)
        if pet_on_target(s) then return true end
        if P.pet.pet_target() ~= nil then return false end
        return P.pet.sent_for ~= nil and P.pet.sent_for(s.target) ~= nil
    end

    --- Close enough to the target to strike it: the client's combat reach
    --- of both when it says, five yards when it does not.
    local function pet_in_reach(s)
        local pet = P.pet.pet()
        if not pet or not units.position then return false end
        local ok_a, a = pcall(units.position, pet)
        local ok_b, b = pcall(units.position, s.target)
        if not (ok_a and ok_b and type(a) == "table" and type(b) == "table") then return false end
        local reach = PET_REACH
        if units.combat_reach then
            local ok_r, r = pcall(function() return units.combat_reach(pet) + units.combat_reach(s.target) + 4 / 3 end)
            if ok_r and type(r) == "number" and r > reach then reach = r end
        end
        local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
        return dx * dx + dy * dy + dz * dz <= reach * reach
    end

    --- Has the pet's first hit landed on our target? The second value says
    --- how it was read.
    local function pet_has_hit(s)
        if on_pet(s) then return true, "the mob is on the pet" end
        -- The spell window's forecast asks about other mobs too: it reads
        -- the beat's clock and never starts or stops it.
        local forecast = H.forecasting ~= nil and H.forecasting()
        local guid = units.guid(s.target)
        if not pet_on_ours(s) or not pet_in_reach(s) then
            if not forecast and guid == reach_guid then reach_guid = nil end
            return false
        end
        local ok, hp = pcall(units.health_fraction, s.target)
        if ok and type(hp) == "number" and hp < HURT then return true, "the pet has hit" end
        local now = core.time()
        if guid ~= reach_guid then
            if forecast then return false end
            reach_guid, reach_since = guid, now
        end
        if (now - reach_since) >= FIRST_HIT_BEAT then return true, "the pet has been on it a beat" end
        return false
    end

    --- May the damage start? Solo with a pet out, once its first hit has
    --- landed. Not waiting: no pet, a group's tank, the pet not ours to
    --- lead (off, or held on a focus), the mob already on us, or the pet
    --- never sent or not getting there.
    ---@param s table
    ---@return boolean
    ---@return string why
    local function pet_hit_first(s)
        if not s.target then return true, "no target" end
        if not pet_alive() then return true, "no pet out" end
        if not solo() then return true, "a group: the tank pulls" end
        local mode = P.pet.mode()
        if mode == P.pet.OFF or mode == P.pet.FOCUS then return true, "the pet is not assisting" end
        local hit, how = pet_has_hit(s)
        if hit then return true, how end
        if on_me(s) then return true, "the mob is on you" end

        local now = core.time()
        local sent = P.pet.sent_for and P.pet.sent_for(s.target) or nil
        if not sent then
            -- The same moment for the pet module as Levelling gives it, and
            -- the same rule for the spell window's forecast: read the clock,
            -- never start it.
            local guid = units.guid(s.target)
            if H.forecasting and H.forecasting() then
                if guid == lead_guid and (now - lead_since) > SEND_PATIENCE then
                    return true, "the pet was not sent"
                end
                return false, "waiting for the pet to be sent"
            end
            if guid ~= lead_guid then lead_guid, lead_since = guid, now end
            if (now - lead_since) > SEND_PATIENCE then return true, "the pet was not sent" end
            return false, "waiting for the pet to be sent"
        end
        if sent > FIRST_HIT_CAP then return true, "the pet is not getting there" end
        return false, string.format("waiting for the pet's first hit (sent %.1fs ago)", sent)
    end

    --- Wraps a damage predicate so it waits for the pet's first hit.
    local function first(pred)
        return function(s)
            return pet_hit_first(s) and pred(s)
        end
    end

    --- Aimed Shot's cast on this client: the catalogue's, Forever's 2.0
    --- laid over Era's 3.0 there.
    local function aimed_cast()
        local catalog = P.catalog
        if catalog and catalog.ability then
            local ok, row = pcall(catalog.ability, "Aimed Shot")
            if ok and type(row) == "table" and type(row.cast) == "number" then return row.cast end
        end
        return P.forever and 2.0 or AIMED_CAST
    end

    --- Aimed Shot on its cooldown: standing at range, the cast landing
    --- before the mob does, not on a pack (Multi-Shot has the cooldown
    --- there). While the bar refills (tier 1), one a fight.
    local function bm_aimed(s)
        if not at_range(s) or not standing(s) or on_pack(s) then return false end
        local tier = spend_tier(s)
        if tier < 1 or dying(s) then return false end
        if tier < 2 and H.since_cast("Aimed Shot") < 15 then return false end
        return cast_safe(s, aimed_cast())
    end

    --- Multi-Shot on a pack whenever the bar allows anything; on one mob
    --- only when Aimed Shot's cast would not land first and the bar is
    --- fine: the shared cooldown's quick shot.
    local MULTI_CAST = 0.5
    local function bm_multi(s)
        if not at_range(s) or dying(s) then return false end
        local tier = spend_tier(s)
        if on_pack(s) then return tier >= 1 end
        if tier < 2 or not standing(s) then return false end
        return not cast_safe(s, aimed_cast()) and cast_safe(s, MULTI_CAST)
    end

    --- Is the target running off? The awareness row's word for it; without
    --- one, moving and not at us.
    local function running_off(s)
        local row = s.target_row
        if row then return row.activity == "fleeing" end
        local ok, moving = pcall(s.target.is_moving, s.target)
        if not ok or not moving then return false end
        local ok_t, their = pcall(s.target.get_target, s.target)
        return not (ok_t and their and their:is_valid() and their:get_guid() == s.player:get_guid())
    end

    --- Concussive Shot: with a pet out, a runner only. The pet holds the
    --- rest, and a mob on us is fought where it stands.
    local function bm_slow(s)
        if not s.target then return false end
        if pet_alive() and not running_off(s) then return false end
        return slow_wanted(s)
    end

    --- Wing Clip only with no pet out: then nothing else holds the mob.
    local function bm_clip(s)
        return not pet_alive() and clip_wanted(s)
    end

    --- The plain swing at a mob that came to us (Mobalytics: "finish them
    --- off with Raptor Strike/Mongoose Bite and Melee Swings"). A START: it
    --- cannot switch a running swing off.
    local function bm_swing(s)
        if not in_melee(s) or not on_me(s) then return false end
        if P.kite and P.kite.active and P.kite.active() then return false end
        return H.melee_start_wanted ~= nil and H.melee_start_wanted(s) == true
    end

    -- --- PvP (1.7.6, ALPHA/TEST) --------------------------------------------
    --
    -- The user, 2026-10-10: "Look up all PVP hunter for forever guides and
    -- Rotations and lets make an unstoppable PVP hunter where it can detect
    -- its in pvp mode and react instantly... know what to do what the player
    -- is doing how to Cast CC and kill". Its class option (`pvp_alpha`, off
    -- by default) switches it on, and it is its one option ("Remove all the
    -- PVP hunter Options off the UI and just into one option still Alpha",
    -- the same day: the four that tuned it are fixed at what they
    -- defaulted to). Then, while modules/pvphunter.lua says
    -- this is a fight with a player, this profile runs in place of every
    -- other. The urgent part -- the peels, the trap at your feet, the cast
    -- stopped, the player who attacks you -- is the reactions'
    -- (react/rules/hunter_pvp.lua). This is what the hunter shoots, and
    -- when.
    --
    --   NOTHING INTO OUR OWN CONTROL. A player in our Freezing Trap or
    --   Scatter Shot (or anyone's sheep) takes no shot, sting or hawk; the
    --   one exception is the opener that ends the trap on purpose.
    --   THE TRAP OPENER. Frozen and walked away from (the kite's reset), the
    --   player gets Aimed Shot from range: its damage breaks the trap, and
    --   the player has the whole distance to cover again under Concussive
    --   Shot. Also into an Intimidation stun with the cast's time left.
    --   THE TRAP FIRST. A melee player coming at you while Freezing Trap is
    --   ready gets no sting and no hawk yet: either keeps ticking and breaks
    --   the trap the moment it lands. Once the trap is spent everything goes.
    --   THE MELEE IS KEPT OFF. Concussive Shot on a melee player coming at
    --   you and on anyone running away; Wing Clip on whoever is in melee with
    --   you and not slowed, Strider Kick (Forever) for its run speed, then the
    --   step out; Raptor Strike and Mongoose Bite only while stuck there.
    --   THE STINGS BY CLASS. One sting of ours per target. Viper Sting (36)
    --   on a mana user who casts or heals; Scorpid Sting (22) on a player who
    --   fights with attacks -- melee, or a hunter's bow -- for its lower
    --   chance to hit (the user, 2026-10-10: "in pvp we should also use
    --   Scorpid Sting cause it reduces targest chance to hit with attacks for
    --   20 seconds"); Serpent Sting on the rest, and on those before Scorpid
    --   Sting is trained. A rogue or a druid now gets Scorpid Sting, not the
    --   dot that kept it in combat: Forever's Hunter's Mark shows it stealthed.
    --   MULTI-SHOT ONLY ON TWO OR MORE. The user, the same day: "Neither PvP
    --   or AoE meele wave should Multishot if its not 2+ enemy mobs".
    --   THE BURST. Rapid Fire (and Bestial Wrath) on a player at range who is
    --   not immune and not in Deterrence, once the fight is on -- not into a
    --   trap, not into a bubble.

    local PVP, PVP_ALPHA = "pvp", "pvp_alpha"
    local PVP_OPEN_AT = 18          -- yards: a trapped player this far off gets the opener
    local PVP_SLOW_AT = 30          -- yards: Concussive Shot on a melee player inside this

    local function pvp_alpha_on()
        return CS ~= nil and CS.opt(PVP_ALPHA, false) == true
    end

    local function pvp_mode()
        local m = P.pvphunter
        if not (m and m.mode) then return false end
        local ok, on = pcall(m.mode)
        return ok and on == true
    end

    local function react_pvp() return P.react and P.react.pvp end

    --- The target as an enemy player: class, role, mana (react/pvp.lua).
    local function foe_of(s)
        local pvp = react_pvp()
        if not (pvp and pvp.foe and s.target) then return nil end
        local ok, f = pcall(pvp.foe, s.target)
        return ok and f or nil
    end

    --- Immunities and avoidance on the target (Blessing of Protection,
    --- Deterrence, Divine Shield...).
    local function foe_state(s)
        local pvp = react_pvp()
        if not (pvp and pvp.state and s.target) then return nil end
        local ok, st = pcall(pvp.state, s.target)
        return ok and st or nil
    end

    --- Our control on the target that damage breaks: its kind and time left.
    local function our_hold(s)
        local m = P.pvphunter
        if not (m and m.held and s.target) then return nil, 0 end
        local ok, kind, left = pcall(m.held, s.target)
        if not ok then return nil, 0 end
        return kind, left or 0
    end

    --- Nothing that hurts goes at it: our control on it, anyone's control
    --- that damage breaks, or immune to us.
    local function hands_off(s)
        if not s.target then return true end
        if our_hold(s) then return true end
        local react = P.react
        return react ~= nil and react.out_of_fight ~= nil and react.out_of_fight(s.target) == true
    end

    --- Physical damage is wasted or halved: Blessing of Protection,
    --- Deterrence, a bubble.
    local function shrugs(s)
        local st = foe_state(s)
        return st ~= nil and (st.immune ~= nil or st.avoid == "physical")
    end

    --- Is the target held where it stands by something that does not break:
    --- a stun or a root (Intimidation, Improved Concussive Shot, a
    --- Counterattack)? Seconds left, 0 when not.
    local function pinned_for(s)
        local row = s.target_row
        local c = row and row.control
        if not c or c.breaks == true then return 0 end
        return tonumber(c.remaining) or 0
    end

    --- An enemy player in melee with us and on us, other than nobody: the
    --- count, and the nearest.
    local function melee_players_on_me(s)
        local rows, n, nearest = s.enemies, 0, nil
        if type(rows) ~= "table" then return 0, nil end
        for i = 1, #rows do
            local r = rows[i]
            if r and r.obj and r.targeting_me and is_player(r.obj) and not r.control then
                local close = (H.in_melee and H.in_melee(r.obj, r.dist)) or (r.dist or 99) <= MELEE_REACH
                if close then
                    n = n + 1
                    if not nearest or (r.dist or 99) < (nearest.dist or 99) then nearest = r end
                end
            end
        end
        return n, nearest
    end

    --- Is Freezing Trap ours to spend soon: known, and ready within a few
    --- seconds?
    local TRAP_SOON = 5
    local function trap_soon()
        if not book.known("Freezing Trap") then return false end
        if book.ready("Freezing Trap") then return true end
        local ok, left = pcall(book.cooldown, "Freezing Trap")
        return ok and type(left) == "number" and left <= TRAP_SOON
    end

    --- Keep what keeps ticking (a sting, the hawks) off a melee player still
    --- to be trapped: each tick breaks the trap the moment it lands -- Viper
    --- Sting's drain too (Wowhead's Classic dueling guide). Never once
    --- something of ours ticks on it already.
    local function trap_first(s)
        local f = foe_of(s)
        if not f or not f.melee then return false end
        if H.debuff_up(s.target, "Serpent Sting") or H.debuff_up(s.target, "Viper Sting") then return false end
        if hawks_out() > 0 and H.since_cast("Summon Hawk") < HAWK_LASTS then return false end
        -- Not a player the next trap would not hold (diminishing returns).
        local pvpx = P.pvpx
        if pvpx and pvpx.dr then
            local ok, mult = pcall(pvpx.dr, s.target, "incapacitate")
            if ok and mult == 0 then return false end
        end
        return trap_soon()
    end

    --- Hunter's Mark on every enemy player: on a rogue or a druid it is
    --- what keeps them in sight through Stealth. "Hunter's Mark on: Never"
    --- still means never; the other choices are about mobs.
    local function pvp_mark(s)
        if not s.target or H.debuff_up(s.target, "Hunter's Mark") then return false end
        if CS and CS.opt("mark_on", MARK_EVERY) == MARK_NEVER then return false end
        return spend_tier(s) >= 1 or (foe_of(s) or {}).stealth == true
    end

    --- The trap opener may go: the player in our trap, walked away from (the
    --- kite done with its reset) or the trap about to end, the pet off it.
    local function trap_opener_ready(s)
        local kind, left = our_hold(s)
        if kind ~= "trap" or pet_on_target(s) then return false end
        if left <= aimed_cast() + 0.4 then return true end
        if P.kite and P.kite.active and P.kite.active() then return false end
        local distance = s.distance or units.distance(s.target)
        return distance >= PVP_OPEN_AT
    end

    --- Rapid Fire, and Bestial Wrath with it: once the fight is on, at
    --- range, into nothing that wastes it.
    local function pvp_burst(s)
        if not s.in_combat or not s.target or shrugs(s) then return false end
        if not at_range(s) then return false end
        -- Into the trap opener: pressed in the moment before the Aimed Shot
        -- that breaks it, so the whole fifteen seconds are spent shooting.
        if our_hold(s) == "trap" then return trap_opener_ready(s) end
        if hands_off(s) then return false end
        local row = s.target_row
        return (s.thp or 1) < 0.9 or (row ~= nil and row.targeting_me == true) or pinned_for(s) > 1
    end

    local function pvp_wrath(s)
        return pet_alive() and pet_on_target(s) and pvp_burst(s)
    end

    --- Concussive Shot: a melee player coming at us, anyone running off,
    --- and the trapped player's first seconds out (pvp_open follows it).
    local function pvp_slow(s)
        if not s.target or hands_off(s) or slowed(s.target) or pinned_for(s) > 1 then return false end
        local distance = s.distance or units.distance(s.target)
        if gap(s.target, distance) <= MIN_RANGE then return false end
        if running_off(s) then return true end
        local f = foe_of(s)
        local row = s.target_row
        if f and f.melee and distance <= PVP_SLOW_AT then
            return row == nil or row.targeting_me == true or (row.closing or 0) > 0.5
        end
        return false
    end

    --- Wing Clip on the player in melee with us, not yet slowed.
    local function pvp_clip(s)
        if not in_melee(s) or hands_off(s) or slowed(s.target) or pinned_for(s) > 1 then return false end
        return true
    end

    --- Strider Kick (Forever, Survival): the strike that hands us thirty
    --- percent run speed to get out -- on a clipped player still on us.
    local function pvp_kick(s)
        if not in_melee(s) or hands_off(s) then return false end
        return on_me(s) and slowed(s.target)
    end

    --- Stuck in melee: the strikes, while the step out is not walking us.
    local function pvp_stuck(s)
        if not in_melee(s) or hands_off(s) then return false end
        return not (P.kite and P.kite.active and P.kite.active())
    end

    --- The opener into our control, and Aimed Shot where its cast lands:
    ---   * a player in our trap, walked away from (or the trap about to end);
    ---   * a stun (Intimidation) with the cast's time left on it;
    ---   * a caster or a healer standing, or a melee player held or far off.
    local function pvp_aimed(s)
        if not at_range(s) or not standing(s) or shrugs(s) then return false end
        if melee_players_on_me(s) > 0 then return false end
        local cast = aimed_cast()
        local kind = our_hold(s)
        if kind == "trap" then return trap_opener_ready(s) end
        if kind or hands_off(s) then return false end
        if pinned_for(s) >= cast - 0.3 then return true end
        if spend_tier(s) < 1 then return false end
        local f = foe_of(s)
        if f and not f.melee and not running_off(s) then return true end
        return cast_safe(s, cast)
    end

    --- Auto Shot, but never into our own control. Forever fires one shot
    --- per press, so not pressing is enough there; Era's auto-repeat keeps
    --- going, so the attack is stopped once (an untested guess: that the
    --- client's stop-attack ends Auto Shot as /stopattack does).
    local stopped_for = nil
    local function pvp_auto_shot(s)
        if s.target and hands_off(s) then
            local guid = units.guid(s.target)
            if not client.auto_repeat_once and guid ~= stopped_for and s.player then
                stopped_for = guid
                local ok_a, attacking = pcall(s.player.is_auto_attacking, s.player)
                local input = core.input
                if ok_a and attacking == true and input and type(input.stop_attack) == "function" then
                    pcall(input.stop_attack)
                end
            end
            return false
        end
        stopped_for = nil
        return auto_shot_rule(s)
    end

    --- Is there mana to drain: a mana user with a fifth of a bar or more.
    local function drainable(s)
        local f = foe_of(s)
        if not f or not f.mana then return false end
        local ok_m, max_mana = pcall(s.target.get_max_power, s.target, 0)
        local ok_c, mana = pcall(s.target.get_power, s.target, 0)
        if ok_m and ok_c and type(max_mana) == "number" and type(mana) == "number" and max_mana > 0 then
            return mana / max_mana >= 0.2
        end
        return true
    end

    --- Viper Sting on a caster or a healer with mana to lose (the Classic
    --- guides: "Viper any mana user and kite"). Forever has it from 36.
    local function pvp_viper(s)
        if not s.target or hands_off(s) or not at_range(s) or trap_first(s) then return false end
        local f = foe_of(s)
        if not f or not (f.caster or f.healer) then return false end
        if H.debuff_up(s.target, "Viper Sting") then return false end
        return drainable(s)
    end

    --- A player who fights with attacks: melee, or a hunter's bow.
    local function attacker(f)
        return f ~= nil and (f.melee == true or f.ranged == true)
    end

    local SCORPID_RENEW = 2         -- seconds left: put it up again

    --- Scorpid Sting (22) on a player who fights with attacks: on Forever it
    --- takes their chance to hit for 20 s. It does no damage, so it goes
    --- before the trap too; never into our own control, and never over
    --- another sting of ours.
    local function pvp_scorpid(s)
        if not s.target or hands_off(s) or not at_range(s) then return false end
        if not attacker(foe_of(s)) then return false end
        if H.debuff_up(s.target, "Serpent Sting") or H.debuff_up(s.target, "Viper Sting") then return false end
        if H.debuff_remaining(s.target, "Scorpid Sting") > SCORPID_RENEW then return false end
        return spend_tier(s) >= 1
    end

    --- Serpent Sting on the rest (and on a caster before Viper Sting is
    --- trained, or once its mana is gone; on an attacker before Scorpid
    --- Sting is), never on a melee player still to be trapped.
    local function pvp_serpent(s)
        if not s.target or hands_off(s) or not at_range(s) or not spread_ok(s) then return false end
        if H.debuff_up(s.target, "Serpent Sting") or H.debuff_up(s.target, "Viper Sting")
            or H.debuff_up(s.target, "Scorpid Sting") then return false end
        if trap_first(s) then return false end
        if book.known("Viper Sting") and pvp_viper(s) then return false end
        if book.known("Scorpid Sting") and attacker(foe_of(s)) then return false end
        return spend_tier(s) >= 1 or (foe_of(s) or {}).stealth == true
    end

    --- Two hawks on the player, as levelling, but not before the trap.
    local function pvp_hawk(s)
        if not s.target or not s.in_combat or hands_off(s) or trap_first(s) then return false end
        if spend_tier(s) < 1 then return false end
        return hawks_out() < 2
    end

    --- A breakable control of ours near the target: Multi-Shot would hit it.
    local function breaks_near(s)
        local rows = s.enemies
        if type(rows) ~= "table" or not s.target then return false end
        local m = P.pvphunter
        local at = units.position and units.position(s.target)
        if not (m and m.held and at) then return false end
        for i = 1, #rows do
            local r = rows[i]
            if r and r.obj and r.obj ~= s.target and m.held(r.obj) then
                local p = units.position(r.obj)
                if p then
                    local dx, dy = (p.x or 0) - (at.x or 0), (p.y or 0) - (at.y or 0)
                    if dx * dx + dy * dy <= 100 then return true end
                end
            end
        end
        return false
    end

    --- Multi-Shot: only with two or more enemies where it lands (H.spread
    --- counts what it would hit round the target), standing, never beside a
    --- trapped player.
    local function pvp_multi(s)
        if not s.target or hands_off(s) or not at_range(s) or breaks_near(s) then return false end
        if spend_tier(s) < 1 then return false end
        if not standing(s) or not H.spread(s, 2) then return false end
        return cast_safe(s, MULTI_CAST)
    end

    --- Arcane Shot on the move, until the hawks take its cooldown.
    local function pvp_arcane(s)
        if not s.target or hands_off(s) or not at_range(s) then return false end
        if book.known("Summon Hawk") then return false end
        return spend_tier(s) >= 1
    end

    -- --- the AOE melee weave (1.7.6, ALPHA/TEST) ----------------------------
    --
    -- The user, 2026-10-10, in place of the melee weave on a key (which ran
    -- the hunter in and out by itself between Auto Shots, and is gone): "When
    -- in meele range u can still cast summon hawk, immolation trap and other
    -- Meele skilss to burst down dmg same as Rapid fire (this is both meele
    -- and rnage).... We manually Move out and when we move out we use
    -- Multi-shot! At this time We also renew as many Serpent stings on
    -- Multiple target in combat with US!!! it can Swap through target
    -- automatically Aslong as its in combat with us and Renew while we mvoe
    -- back in!! again at all times keep 2 hawks up For maximized DPS!"
    --
    -- Its class option (`aoe_weave`, off) runs this profile in place of the
    -- talents' (PvP mode still comes first). Nothing here moves you: the step
    -- out and the run-and-shoot stand aside while it runs (kite.lua). Which
    -- side of the dead zone you stand on says what goes out:
    --
    --   BOTH SIDES. Two hawks at all times (Summon Hawk has no minimum
    --   range); Rapid Fire (on Forever +40% ranged AND melee attack speed);
    --   Intimidation and Bestial Wrath as in Beast Mastery.
    --   IN MELEE, THE BURST. Explosive Trap at your feet with two or more
    --   mobs round you, Immolation Trap otherwise (Forever lays traps in a
    --   fight); Raptor Strike, Mongoose Bite, Strider Kick, Counterattack,
    --   Lacerate on a mob that lives for it, and the swing.
    --   OUT. Multi-Shot on its cooldown as soon as you stand, and Serpent
    --   Sting renewed on every mob in the fight -- no cap -- on the way out
    --   and on the way back in. Multi-Shot only with two or more mobs where
    --   it lands, and then before everything (the user: "if its 2+ mobs it
    --   should be priority to multishot", then "Neither PvP or AoE meele
    --   wave should Multishot if its not 2+ enemy mobs"). Its reaction (react/rules/hunter.lua, "AOE
    --   weave: sting the next mob") moves the target on to the next mob whose
    --   sting is missing or running out, only among mobs fighting you or your
    --   pet; the rule's spread does it from here where that reaction is not
    --   loaded. Auto Shot is pressed again the moment you are back out.
    --
    -- The mana rules (1.7.4) still hold: the refill keeps to tier 1, and
    -- nothing that costs mana goes at a mob about to die.

    local AOE_RAPID_TTD = 10        -- seconds: one mob worth Rapid Fire
    local AOE_TRAP_TTD = 6          -- seconds: a mob worth a fire trap
    local AOE_LACERATE_TTD = 12     -- seconds: a mob worth Lacerate's 21 s bleed

    --- Is the AOE weave the profile running: its option on, and no PvP.
    local function aoe_running()
        return aoe_weave_on() and not pvp_mode()
    end

    local function engaged_count(s)
        local list, n = s.engaged_units, 0
        if type(list) ~= "table" then return s.target and 1 or 0 end
        for i = 1, #list do
            local unit = list[i]
            if unit:is_valid() and not unit:is_dead() then n = n + 1 end
        end
        return n
    end

    --- Rapid Fire in melee or at range, once the fight is worth it: a pack,
    --- a mob that lives a while, or a burst window.
    local function aoe_rapid_fire(s)
        if not s.in_combat or not s.target or dying(s) or spend_tier(s) < 1 then return false end
        if H.bursting() then return true end
        return engaged_count(s) >= 2 or (s.ttd or 0) >= AOE_RAPID_TTD
    end

    --- Two hawks out at all times, in melee or out of it.
    local function aoe_hawk(s)
        if not s.target or not s.in_combat or dying(s) or spend_tier(s) < 1 then return false end
        return hawks_out() < 2
    end

    local function aoe_burst(s)
        return aoe_in_melee(s) and s.in_combat and not dying(s) and spend_tier(s) >= 1
    end

    --- Explosive Trap at your feet, in melee with two or more round you.
    local function aoe_explosive(s)
        return aoe_burst(s) and H.spread(s, 2)
    end

    --- Immolation Trap at your feet, in melee, on a mob that lives to burn.
    local function aoe_immolation(s)
        return aoe_burst(s) and (s.ttd or 0) >= AOE_TRAP_TTD
    end

    --- The strikes, in melee, on anything not about to die.
    local function aoe_strike(s)
        return aoe_in_melee(s) and not dying(s)
    end

    --- Lacerate (Forever's melee bleed), on a mob that lives for it.
    local function aoe_lacerate(s)
        if not aoe_burst(s) or H.debuff_up(s.target, "Lacerate") then return false end
        return (s.ttd or 0) >= AOE_LACERATE_TTD
    end

    --- The swing in melee. A START: it cannot switch a running swing off.
    local function aoe_swing(s)
        if not aoe_in_melee(s) then return false end
        return H.melee_start_wanted ~= nil and H.melee_start_wanted(s) == true
    end

    --- Multi-Shot out of melee, on its cooldown, as soon as you stand, and
    --- only with two or more mobs where it lands. H.spread counts what this
    --- Multi-Shot would hit round the target, and none beside a mob we hold
    --- with control that damage breaks.
    local function aoe_multi(s)
        if not at_range(s) or not standing(s) or dying(s) then return false end
        return spend_tier(s) >= 1 and H.spread(s, 2)
    end

    --- Serpent Sting out of melee, moving or not: renewed on the target and
    --- (the engine's spread) on every other mob in the fight, with no cap.
    local function aoe_sting(s)
        if not at_range(s) then return false end
        return H.dot_worth_it(s, "Serpent Sting", Sting_ttd[spend_tier(s)])
    end

    --- One line for the class window: off, or which side of the weave you
    --- stand on and what that side does.
    local function aoe_status()
        local tag = "AOE melee weave (ALPHA/TEST): "
        if not aoe_weave_on() then return tag .. "off" end
        if pvp_mode() then return tag .. "on; a fight with a player runs PvP instead" end
        local combat = P.combat
        local target = combat and combat.target and combat.target() or nil
        local fighting = combat and combat.in_combat and combat.in_combat() == true
        if not target or not fighting then return tag .. "on, waiting for a fight" end
        local hawks = hawks_out()
        if in_melee({ target = target }) then
            return string.format("%sin melee: traps, strikes, Rapid Fire; hawks %d/2. Move out for Multi-Shot", tag, hawks)
        end
        local list = P.field and P.field.by_weakest and P.field.by_weakest() or { target }
        local n, stung_n = 0, 0
        for i = 1, #list do
            local unit = list[i]
            if unit:is_valid() and not unit:is_dead() then
                n = n + 1
                if H.debuff_remaining(unit, "Serpent Sting") > 2 then stung_n = stung_n + 1 end
            end
        end
        local multi = n >= 2 and "Multi-Shot; " or "one mob, no Multi-Shot; "
        return string.format("%sout: %sSerpent Sting on %d of %d; hawks %d/2", tag, multi, stung_n, n, hawks)
    end

    local profiles = {}

    -- The guide's order, as a priority list. Auto Shot sits right after the
    -- mark: it is a single press that costs no global cooldown once it is
    -- running, and the rule only fires when it is NOT running. Everything
    -- else that would hit the mob is wrapped in lead(): on a fresh solo
    -- pull it waits for the pet to get there first.
    profiles.leveling = {
        label = "Levelling",
        power = "MANA",
        rules = {
            { "Hunter's Mark", mark_wanted, upkeep = 5 },
            -- The pet is the tank while levelling, so keeping it alive
            -- outranks any shot.
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            { "Intimidation", intimidation_wanted, self = true, upkeep = 5 },
            { "Bestial Wrath", bestial_wrath_wanted, self = true, upkeep = 5 },
            -- A mob charging us, or running away, is slowed before anything
            -- else is spent on it; a mob that reached us is clipped.
            { "Concussive Shot", slow_wanted, upkeep = 4 },
            { "Wing Clip", clip_wanted, upkeep = 3 },
            { "Aimed Shot", lead(aimed_opener) },
            { "Auto Shot", auto_shot_rule, upkeep = 1, direct = true },
            { "Serpent Sting", lead(sting_wanted),
              upkeep = 2, dot = true, spread = true },
            { "Summon Hawk", lead(hawk_wanted), upkeep = 1 },
            { "Aimed Shot", lead(aimed_filler) },
            { "Multi-Shot", lead(multishot_wanted) },
            { "Arcane Shot", lead(arcane_wanted) },
            { "Raptor Strike", melee_stuck },
            { "Mongoose Bite", melee_stuck },
        },
    }

    -- The guides' order (see "Beast Mastery" above). Everything that hits
    -- the mob from range waits for the pet's first hit. Kill Command and
    -- Steady Shot are Era's runes, kept from the old list; Forever has
    -- neither, so there they never go.
    profiles.beast_mastery = {
        label = "Beast Mastery",
        power = "MANA",
        rules = {
            { "Hunter's Mark", mark_wanted, upkeep = 5 },
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            { "Intimidation", intimidation_wanted, self = true, upkeep = 5 },
            { "Bestial Wrath", bestial_wrath_wanted, self = true, upkeep = 5 },
            { "Concussive Shot", bm_slow, upkeep = 4 },
            { "Wing Clip", bm_clip, upkeep = 3 },
            { "Auto Shot", first(auto_shot_rule), upkeep = 1, direct = true },
            { "Kill Command", first(afford(function(s) return s.in_combat and not dying(s) end)), upkeep = 1 },
            { "Serpent Sting", first(sting_wanted),
              upkeep = 2, dot = true, spread = true },
            { "Summon Hawk", first(hawk_wanted), upkeep = 1 },
            { "Aimed Shot", first(bm_aimed) },
            { "Multi-Shot", first(bm_multi) },
            -- Before the hawks (under 25) the instant still has a place;
            -- arcane_wanted gives it up once Summon Hawk is trained.
            { "Arcane Shot", first(arcane_wanted) },
            { "Steady Shot", first(afford(at_range)) },
            { "Raptor Strike", melee_stuck },
            { "Mongoose Bite", melee_stuck },
            { "Attack", bm_swing, direct = true, fast = true, upkeep = 1 },
        },
    }

    profiles.marksmanship = {
        label = "Marksmanship",
        power = "MANA",
        rules = {
            { "Hunter's Mark", mark_wanted, upkeep = 5 },
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            { "Concussive Shot", slow_wanted, upkeep = 4 },
            { "Wing Clip", clip_wanted, upkeep = 3 },
            { "Aimed Shot", lead(aimed_opener) },
            { "Auto Shot", auto_shot_rule, upkeep = 1, direct = true },
            { "Serpent Sting", lead(sting_wanted),
              upkeep = 2, dot = true, spread = true },
            { "Multi-Shot", lead(afford(on_pack)) },
            { "Aimed Shot", lead(aimed_filler) },
            { "Arcane Shot", lead(arcane_wanted) },
            { "Steady Shot", lead(afford(at_range)) },
            { "Raptor Strike", melee_stuck },
            { "Mongoose Bite", melee_stuck },
        },
    }

    profiles.survival = {
        label = "Survival",
        power = "MANA",
        rules = {
            { "Hunter's Mark", mark_wanted, upkeep = 5 },
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            { "Concussive Shot", slow_wanted, upkeep = 4 },
            { "Wing Clip", clip_wanted, upkeep = 3 },
            { "Auto Shot", auto_shot_rule, upkeep = 1, direct = true },
            { "Explosive Trap", afford(on_pack), self = true, upkeep = 20 },
            { "Serpent Sting", lead(sting_wanted),
              upkeep = 2, dot = true, spread = true },
            { "Multi-Shot", lead(afford(on_pack)) },
            { "Aimed Shot", lead(aimed_filler) },
            { "Arcane Shot", lead(arcane_wanted) },
            { "Steady Shot", lead(afford(at_range)) },
            -- Forever's Survival fights in melee (1.80.0): Strider Kick and
            -- Mongoose Bite (Expose Prey lets it go without a dodge) whenever
            -- the mob is on us.
            { "Mongoose Bite", melee_stuck },
            { "Strider Kick", melee_stuck, upkeep = 1 },
            { "Raptor Strike", melee_stuck },
        },
    }

    -- The AOE melee weave (1.7.6, ALPHA/TEST; see its section above).
    -- Multi-Shot first, and only, when two or more mobs are where it lands;
    -- then both sides, the burst in melee, and what goes out from range.
    -- Only the pull's shots wait for the pet's first hit, as in Beast
    -- Mastery; once you walk in, nothing waits.
    profiles.aoe_weave = {
        label = "AOE melee weave (ALPHA/TEST)",
        power = "MANA",
        rules = {
            { "Hunter's Mark", mark_wanted, upkeep = 5 },
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            -- Out, with two or more where it lands: Multi-Shot first.
            { "Auto Shot", first(auto_shot_rule), upkeep = 1, direct = true },
            { "Multi-Shot", first(aoe_multi) },
            -- Both sides of the weave.
            { "Rapid Fire", aoe_rapid_fire, self = true, upkeep = 5 },
            { "Intimidation", intimidation_wanted, self = true, upkeep = 5 },
            { "Bestial Wrath", bestial_wrath_wanted, self = true, upkeep = 5 },
            { "Summon Hawk", aoe_hawk, upkeep = 1 },
            -- In melee: the burst.
            { "Explosive Trap", aoe_explosive, self = true, upkeep = 20 },
            { "Immolation Trap", aoe_immolation, self = true, upkeep = 20 },
            { "Raptor Strike", aoe_strike },
            { "Mongoose Bite", aoe_strike },
            { "Strider Kick", aoe_strike, upkeep = 1 },
            { "Counterattack", aoe_strike, upkeep = 1 },
            { "Lacerate", aoe_lacerate, upkeep = 2, dot = true },
            { "Wing Clip", bm_clip, upkeep = 3 },
            { "Attack", aoe_swing, direct = true, fast = true, upkeep = 1 },
            -- Out: the stings on every mob.
            { "Serpent Sting", first(aoe_sting),
              upkeep = 2, dot = true, spread = true },
            { "Concussive Shot", bm_slow, upkeep = 4 },
            { "Arcane Shot", first(arcane_wanted) },
        },
    }

    -- The PvP hunter (1.7.6, ALPHA/TEST; see "PvP" above). The peels, the
    -- trap at your feet, Scatter Shot, Intimidation, Deterrence, Feign Death
    -- and the target switches are its reactions (react/rules/hunter_pvp.lua),
    -- which come before this list every tick.
    profiles.pvp = {
        label = "PvP (ALPHA/TEST)",
        power = "MANA",
        rules = {
            { "Hunter's Mark", pvp_mark, upkeep = 3 },
            -- In melee: slow it and get out (the kite's step out follows).
            { "Wing Clip", pvp_clip, upkeep = 1 },
            { "Strider Kick", pvp_kick, upkeep = 1 },
            -- Coming at us, or running away.
            { "Concussive Shot", pvp_slow, upkeep = 2 },
            { "Rapid Fire", pvp_burst, self = true, upkeep = 5 },
            { "Bestial Wrath", pvp_wrath, self = true, upkeep = 5 },
            { "Aimed Shot", pvp_aimed },
            { "Auto Shot", pvp_auto_shot, upkeep = 1, direct = true },
            { "Viper Sting", pvp_viper, upkeep = 2 },
            { "Scorpid Sting", pvp_scorpid, upkeep = 2 },
            { "Serpent Sting", pvp_serpent, upkeep = 2, dot = true, spread = true },
            { "Summon Hawk", pvp_hawk, upkeep = 1 },
            { "Multi-Shot", pvp_multi },
            { "Arcane Shot", pvp_arcane },
            { "Mend Pet", mend_pet_wanted, self = true, upkeep = 8 },
            { "Counterattack", pvp_stuck, upkeep = 1 },
            { "Mongoose Bite", pvp_stuck },
            { "Raptor Strike", pvp_stuck },
        },
    }

    --- One line for the class window: off, waiting, or what it faces.
    local function pvp_status()
        local m = P.pvphunter
        if m and m.status then
            local ok, text = pcall(m.status)
            if ok and type(text) == "string" then return text end
        end
        return pvp_alpha_on() and "PvP hunter (ALPHA/TEST): on" or "PvP hunter (ALPHA/TEST): off"
    end

    return {
        key = "hunter",
        label = "Hunter",
        trees = { "Beast Mastery", "Marksmanship", "Survival" },
        buffs = {},
        icon = "target",
        pet_capable = true,
        -- How this class opens: asked by the engage gate for a selected mob
        -- that has not engaged us. See may_open above.
        may_open = may_open,
        -- Rules whose reason for not firing is logged whenever it changes
        -- ("watch: Auto Shot held: ..."). It was Hunter's Mark while the
        -- pull's first press was the open question; that has worked in
        -- every log since. Auto Shot is most of the damage, and when it is
        -- not firing this line says why.
        watch = { "Auto Shot" },
        -- What a toggle's rule would do, for the watch line, since asking
        -- the rule itself would press it.
        toggle_status = { ["Auto Shot"] = auto_shot_status },
        -- Only what moves the character is left to choose (1.33.0): the
        -- pull, the opener, the fillers, Intimidation, Bestial Wrath and the
        -- slows are decided by the fight.
        settings = function(s, P)
            s:label("The pull is yours: attack (right-click, Attack, Auto Shot) and the")
            s:label("opener, fillers, Intimidation, Bestial Wrath and slows follow the fight.")
            s:label("These two move your character:")
            -- Off by default since 1.64.1 (the user, 2026-10-04).
            s:toggle("kite", "Run and shoot before there is a pet", false)
            s:toggle("step_out", "Step out of melee once the mob is clipped or on the pet", true)
            -- 1.7.6: the one aspect swap made for you (modules/aspects.lua),
            -- off by default (the user, 2026-10-10). Also in the Hunter window.
            s:toggle("auto_aspect", "Auto swap aspects", false)
            s:label("Auto swap aspects: out of Cheetah or Pack into the aspect you last")
            s:label("fought in (Hawk, else Monkey) just before a hit would daze you. Off:")
            s:label("no aspect is ever swapped for you; the one you switched on is kept up.")
            -- 1.84.0: which mobs get the mark, and how many a sting.
            s:dropdown("mark_on", "Hunter's Mark on", MARK_ON, MARK_EVERY)
            s:label("Bosses only: dungeon and raid bosses (on Era, whose dungeon bosses")
            s:label("read as elites, take Elites and bosses for those).")
            s:dropdown("sting_spread", "Serpent Sting on", STING_SPREAD, 3)
            -- 1.7.4: how much of the bar the extra shots may have.
            s:dropdown("mana_use", "Mana for extra shots", MANA_USE, MANA_BALANCED)
            s:label("Balanced: under half a bar only the essentials, until spirit has it")
            s:label("back to 80%; the fillers (Multi-Shot on one mob, Arcane Shot) above 80%.")
            s:label("Save for regen: the same from 70% to 95%. Spend freely: as before 1.7.4.")
            -- 1.7.6: Beast Mastery is the Forever guides' rotation.
            s:label("Beast Mastery: the Forever guides' rotation. The pet hits first, then Auto")
            s:label("Shot, Serpent Sting, two hawks, Aimed Shot on its cooldown (Multi-Shot on a")
            s:label("pack); a mob that reaches you is meleed while the pet takes it back. Keep")
            s:label("Aspect of the Hawk up in a fight (Deadly Aspects).")
            -- 1.7.6: the AOE melee weave. You move; it picks the side's spells.
            s:toggle(AOE_WEAVE, "AOE melee weave (ALPHA/TEST)", false)
            s:label("AOE melee weave (ALPHA/TEST): you walk in and out yourself. In melee: Raptor")
            s:label("Strike, Mongoose Bite, Strider Kick, Lacerate, Immolation Trap (Explosive Trap")
            s:label("round a pack). Out: Multi-Shot first, and only, with 2+ mobs where it lands;")
            s:label("Serpent Sting renewed on every mob fighting you, the target moved from one")
            s:label("to the next. Both: two hawks, Rapid Fire.")
            -- 1.7.6: the PvP hunter (modules/pvphunter.lua, rules/hunter_pvp.lua).
            s:toggle(PVP_ALPHA, "PvP hunter (ALPHA/TEST)", false)
            s:label("PvP hunter (ALPHA/TEST): while your target is an enemy player, or one is on")
            s:label("you, or in a battleground, the PvP rotation and its reactions run: Concussive")
            s:label("Shot and Wing Clip keep melee off, Freezing Trap at your feet, Scatter Shot,")
            s:label("Intimidation and Deterrence when they reach you, a walk out to range and an")
            s:label("Aimed Shot opener from the trap; Viper Sting on casters, Scorpid Sting on")
            s:label("melee and hunters, Multi-Shot only on 2+, Feign Death into a Polymorph or")
            s:label("Fear, a switch to the player who attacks you.")
        end,
        -- The class window's lines under the switches (classwin.lua NOTES).
        aoe_status = aoe_status,
        pvp_status = pvp_status,
        -- Is the AOE melee weave the profile running? The kite stands aside
        -- (kite.lua) and its reaction moves the target (react/rules/hunter.lua).
        aoe_running = aoe_running,
        -- This class has something that hits more than one target, so the
        -- field module may plan an AoE. Declared rather than inferred: a rule
        -- predicate is a closure and cannot be asked what it would do.
        aoe_capable = true,
        -- THE BURST SEQUENCE, in order. modules/burst.lua fires these off the
        -- global cooldown lane when it decides a window is worth opening, and
        -- pulls the trinkets and the offensive racial into the same few
        -- seconds so they multiply each other instead of landing on three
        -- different mobs. `duration` is what the window is held open for.
        burst = {
            { spell = "Rapid Fire", duration = 15 },
            { spell = "Bestial Wrath", duration = 18 },
        },

        class_name = "HUNTER",
        power = "MANA",
        -- The lists come from the catalogue, which is where what an ability
        -- IS now lives; the literals are the fallback for a build without it.
        interrupts = catalog_list("interrupts", { "Silencing Shot" }),
        pet_interrupts = catalog_list("pet_interrupts", { "Pummel", "Nether Shock" }),
        defensives = catalog_list("defensives", { "Feign Death", "Deterrence" }),
        escapes = catalog_list("escapes", { "Feign Death", "Wing Clip", "Disengage" }),
        -- Assist: the pet attacks what we attack. Growl follows context in
        -- modules/pet.lua -- on when solo, where the pet is the tank, off in
        -- a group, where a pet taunting off the tank is worse than the
        -- damage it adds.
        default_pet_mode = 2,
        profiles = profiles,
        profile_order = { "leveling", "beast_mastery", "marksmanship", "survival", AOE_WEAVE, PVP },
        suggest = function(t)
            -- 1.7.6: a fight with a player runs the PvP profile, whatever
            -- the talents, while its switch is on; then the AOE melee weave,
            -- while its switch is on.
            if pvp_mode() then return PVP end
            if aoe_weave_on() then return AOE_WEAVE end
            local bm, mm, surv = t.points()
            local total = bm + mm + surv
            -- 1.7.6: Beast Mastery from the first point (and with none);
            -- under twenty, Levelling keeps the hunters led by the other two.
            if bm >= mm and bm >= surv then return "beast_mastery" end
            if total < 20 then return "leveling" end
            if mm >= surv then return "marksmanship" end
            return "survival"
        end,
    }
end

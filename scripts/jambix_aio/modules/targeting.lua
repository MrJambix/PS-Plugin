-- Jambix AIO / targeting -- who to hit, how many are on us, and who is loose.
--
-- Three questions the rotation cannot answer from a single target handle:
--
--   1. IS THIS THE RIGHT TARGET? A levelling warrior fighting three mobs
--      should usually be finishing the one that is nearly dead, not the one
--      the client happened to leave selected.
--
--   2. IS THIS AN AoE SITUATION? Not "how many enemies are nearby" but "how
--      many are actually engaged with me and clustered enough for Thunder Clap
--      or Whirlwind to hit them". Counting every enemy in an 8 yard bubble
--      says yes in the middle of a camp you have not pulled.
--
--   3. WHO IS NOT HITTING ME? For a tank that is the only question that
--      matters. get_threat_situation answers it per unit, authoritatively,
--      rather than by inferring from who the mob is facing.
--
-- CONTEXT
-- Every aggressive behaviour here is gated on where you are. Grabbing every
-- loose mob is correct solo and actively harmful in a dungeon or raid, where
-- the loose mob is usually somebody else's job and the pull is deliberate. The
-- context is read from the client, not guessed.

return function(P)
    local ctx, log = P.ctx, P.log
    local units, combat = P.units, P.combat
    -- JCore 1.6.0 answers these per client: the rank (units.classification,
    -- the creature cache's on Forever) and whose mob it is (loot.tapped,
    -- false on Era with no read).
    local loot = ctx and ctx.loot

    --- The client's threat entry for you on a unit, asked the way round the
    --- client answers: JCore's enemies.situation works that out, since the
    --- contract and the old mob-first call disagree. The old call on a JCore
    --- without it.
    local function my_situation(unit, player)
        local enemies = ctx and ctx.enemies
        if enemies and type(enemies.situation) == "function" then
            local ok, t = pcall(enemies.situation, unit, player)
            if ok then return t end
            return nil
        end
        local ok, t = pcall(unit.get_threat_situation, unit, player)
        if ok then return t end
        return nil
    end

    --- Does a threat entry say you hold the mob? Status 2 or 3, or the scaled
    --- 100% the holder reads. Not is_tanking (1.82.0): before the 2026-10-06
    --- core it compared a hardcoded offset on Era, MoP, Titan and the private
    --- servers, and status was 0 on every classic build, while threat_percent
    --- was right everywhere (the .api). From that core on is_tanking is
    --- status >= 2, so this agrees with it.
    local function holds(situation)
        return (tonumber(situation.status) or 0) >= 2
            or (tonumber(situation.threat_percent) or 0) >= 100
    end

    local M = {}

    -- --- context ------------------------------------------------------------

    M.SOLO, M.PARTY, M.DUNGEON, M.RAID, M.PVP = "solo", "party", "dungeon", "raid", "pvp"

    local cached_context = M.SOLO
    local context_checked = 0

    --- Where we are, from the client's own instance type plus group size.
    ---
    --- GetInstanceInfo answers "none" out in the world, so a five-man in the
    --- open world with a group reads as `party` rather than `dungeon`. The two
    --- are separated because the tank behaviour that is right for a world pull
    --- with friends is not the one that is right inside an instance.
    ---@return string
    function M.context()
        local now = core.time()
        if (now - context_checked) < 2 then return cached_context end
        context_checked = now

        local ok, instance = pcall(core.get_instance_type)
        instance = (ok and type(instance) == "string") and instance:lower() or "none"

        -- Resolved as a callable first: indexing straight through
        -- core.object_manager.get_party_members would raise outside any pcall
        -- on a build that does not expose it, and this runs every two seconds
        -- inside the rotation tick -- so it would take the whole rotation down
        -- rather than degrade.
        local group_size = 0
        local get_party = type(core.object_manager) == "table"
            and core.object_manager.get_party_members or nil
        if type(get_party) == "function" then
            local ok_party, party = pcall(get_party)
            if ok_party and type(party) == "table" then group_size = #party end
        end

        -- The stub documents get_instance_type only as `string`, with no list
        -- of values. The names below are WoW's own GetInstanceInfo vocabulary,
        -- which is where they almost certainly come from -- but "almost
        -- certainly" decides whether a tank taunts in someone else's dungeon.
        --
        -- So an UNRECOGNISED non-"none" value is treated as a dungeon, not as
        -- the open world. Getting it wrong that way costs a missed taunt out
        -- in the world; getting it wrong the other way pulls a pack somebody
        -- else was managing.
        if instance == "raid" then
            cached_context = M.RAID
        elseif instance == "pvp" or instance == "arena" then
            cached_context = M.PVP
        elseif instance ~= "none" and instance ~= "" then
            cached_context = M.DUNGEON
        elseif group_size > 0 then
            cached_context = M.PARTY
        else
            cached_context = M.SOLO
        end

        return cached_context
    end

    --- True where the rotation is allowed to start fights and grab everything
    --- loose. False anywhere a pull is somebody's deliberate decision.
    ---
    --- The setting is a dropdown rather than a toggle because "solo only" and
    --- "solo and party" are genuinely different answers, and a tank levelling
    --- with one friend wants the second.
    ---@return boolean
    function M.may_control_pull()
        local scope = P.opt("rot_aggro_scope", 2)
        local here = M.context()

        if here == M.PVP then return false end
        if scope == 1 then return here == M.SOLO end
        if scope == 2 then return here == M.SOLO or here == M.PARTY end
        if scope == 3 then return here ~= M.RAID end
        return true  -- 4: everywhere, including raid
    end

    -- --- engagement ---------------------------------------------------------

    --- Is this unit actually fighting US?
    ---
    --- `unit:is_in_combat()` answers "is in combat with ANYONE" -- a mob
    --- fighting another player, or one something else just pulled, reads as
    --- true. Treating that as ours is how the rotation reaches out and taps
    --- something that was never our problem.
    ---
    --- The threat table is asked first because it is the client's own answer.
    --- Falling back to "who is it hitting" covers the moment before threat
    --- registers, and counts our pet's attacker as ours too, since a warlock
    --- whose voidwalker is holding a mob is very much in that fight.
    ---@param unit game_object
    ---@return boolean
    function M.engaged_with_me(unit)
        local player = units.player()
        if not player or not unit or not unit:is_valid() then return false end
        if not unit:is_in_combat() then return false end

        local ok, situation = true, my_situation(unit, player)
        if ok and type(situation) == "table" then
            if holds(situation) then return true end
            if (situation.threat_percent or 0) > 0 then return true end
        end

        local ok_target, their = pcall(unit.get_target, unit)
        if ok_target and their and their:is_valid() then
            if their:get_guid() == player:get_guid() then return true end
            local pet = P.pet and P.pet.pet()
            if pet and their:get_guid() == pet:get_guid() then return true end
        end

        return false
    end

    --- Enemies that are fighting US, inside `range`.
    ---
    --- This is what target selection and the AoE count are built on. "In
    --- combat with anyone" is not good enough for either: another player
    --- fighting three mobs beside you is not an AoE opportunity, and it is
    --- certainly not a target list.
    ---@param range number
    ---@return game_objects_table
    function M.my_enemies(range)
        local out = {}
        if not units.player() then return out end

        local enemies = units.enemies()
        for i = 1, #enemies do
            local enemy = enemies[i]
            if units.distance(enemy) <= range and M.engaged_with_me(enemy) then
                out[#out + 1] = enemy
            end
        end
        return out
    end

    --- Enemies in combat with ANYONE, inside `range`.
    ---
    --- Kept separate from my_enemies on purpose: a tank reclaiming loose mobs
    --- specifically wants the ones fighting somebody else.
    ---@param range number
    ---@return game_objects_table
    function M.engaged(range)
        local out = {}
        local player = units.player()
        if not player then return out end

        local enemies = units.enemies()
        for i = 1, #enemies do
            local enemy = enemies[i]
            if enemy:is_in_combat() and units.distance(enemy) <= range then
                out[#out + 1] = enemy
            end
        end
        return out
    end

    --- How many engaged enemies sit within `radius` of the player. The honest
    --- input to "is this worth a Thunder Clap".
    ---@param radius number
    ---@return integer
    function M.aoe_count(radius)
        -- my_enemies, not engaged: another player fighting three mobs beside
        -- you is not an AoE opportunity.
        return #M.my_enemies(radius)
    end

    --- The largest cluster of engaged enemies centred on any one of them, and
    --- that unit. Used to decide whether an AoE is worth it when the pack is
    --- spread out and the player is on the edge of it.
    ---@param radius number
    ---@return integer size
    ---@return game_object|nil centre
    function M.best_cluster(radius)
        local engaged = M.engaged(40)
        local best, best_size = nil, 0

        for i = 1, #engaged do
            local origin = engaged[i]:get_position()
            if origin then
                local size = 0
                for j = 1, #engaged do
                    local pos = engaged[j]:get_position()
                    if pos and origin:dist_to(pos) <= radius then size = size + 1 end
                end
                if size > best_size then best, best_size = engaged[i], size end
            end
        end

        return best_size, best
    end

    -- --- target selection ---------------------------------------------------

    --- Is this somebody else's mob? JCore's answer (loot.tapped): on Forever
    --- the client's is_tap_denied (true since patch 1.60.1.70205) or a
    --- stranger's fight; on Era false, with no read.
    local function others_mob(unit)
        if not (loot and loot.tapped) then return false end
        local ok, tapped = pcall(loot.tapped, unit)
        return ok and tapped == true
    end
    M.others_mob = others_mob

    --- Scores a candidate. Higher wins; nil excludes.
    ---
    --- The weights encode a levelling priority, in this order:
    ---   * finish what is nearly dead, because a dead mob stops hitting you
    ---   * prefer what is already hitting us, because it is already committed
    ---   * prefer quest and guide targets, because that is why we are here
    ---   * prefer close over far
    --- Elites are pushed DOWN rather than up: on a levelling character an
    --- elite is usually a thing to avoid, not to select.
    local function score(unit, player)
        if not unit:is_valid() or unit:is_dead() then return nil end

        -- Crowd-controlled in a way damage breaks (a sheep, a trap, a fear):
        -- picking it is waking it (1.56.0).
        local react = P.react
        if react and react.out_of_fight and react.out_of_fight(unit) then return nil end

        local distance = units.distance(unit)
        if distance > P.tune_secs("rot_target_range", 30) then return nil end

        -- Somebody else's mob is never picked (1.52.0). The nearly dead mob
        -- the score below likes best is, on a busy Forever realm, usually
        -- exactly that, and it gives no loot and no experience. JCore only
        -- ever says so on Forever, so Era scores as it always did.
        if others_mob(unit) and not M.engaged_with_me(unit) then return nil end

        local hp = units.health_fraction(unit)
        local value = 0

        -- Nearly dead is worth the most, and steeply so.
        value = value + (1 - hp) * 120

        -- Fighting US, not merely fighting. A mob in combat with someone
        -- else is not a reason to prefer it.
        if M.engaged_with_me(unit) then value = value + 60 end

        local ok, their_target = pcall(unit.get_target, unit)
        if ok and their_target and their_target:is_valid()
            and their_target:get_guid() == player:get_guid() then
            value = value + 40
        end

        if P.quests and P.quests.is_guide_target then
            local ok_name, name = pcall(unit.get_name, unit)
            if P.quests.is_guide_target(unit, (ok_name and name) or "") then
                value = value + 50
            elseif P.quests.is_quest_target(unit) then
                value = value + 35
            end
        end

        local ok_class, classification
        if units.classification then
            ok_class, classification = pcall(units.classification, unit)
        else
            ok_class, classification = pcall(unit.get_classification, unit)
        end
        if ok_class and classification then
            if classification == P.cfg.CLASS_WORLD_BOSS then
                value = value - 200
            elseif classification == P.cfg.CLASS_ELITE
                or classification == P.cfg.CLASS_RARE_ELITE then
                value = value - 60
            end
        end

        value = value - distance * 2
        return value
    end

    --- The enemy the rotation would rather be on, or nil when the current one
    --- is fine.
    ---
    --- Returns nil rather than the current target when nothing beats it, so a
    --- caller can treat a non-nil result as "a switch is worth it" without
    --- comparing guids itself.
    ---@return game_object|nil
    function M.better_target()
        -- "Assist the tank" (1.70.0) is a choice of its own: it works with
        -- automatic picking off too.
        local auto = P.opt("rot_auto_target", true)
        local assist = P.assist
        local assisting = assist ~= nil and assist.on ~= nil and assist.on() == true
        if not auto and not assisting then return nil end

        local player = units.player()
        if not player then return nil end

        -- Disengaging. Picking a target is the opposite of what is wanted
        -- while the hardcore layer has decided this fight is lost.
        if P.hardcore and P.hardcore.should_stop_fighting({
            player = player,
            hp = units.health_fraction(player),
            in_combat = combat.in_combat(),
        }) then
            return nil
        end

        local current = combat.target()
        local current_score = nil
        if current and current:is_valid() and not current:is_dead()
            and player:can_attack(current) then
            current_score = score(current, player)
        end

        -- THE TANK'S TARGET (1.70.0, modules/assist.lua). With "Assist the
        -- tank" on, a damage dealer in a group is on whatever the tank is
        -- on, and follows it. Where the tank's target will not do (nothing,
        -- a friend, a sheep, a pack not pulled yet mid-fight) the choice
        -- below is made as before.
        if assisting then
            local ok, unit, holding = pcall(assist.pick, current)
            if ok and holding then return unit end
        end
        if not auto then return nil end

        -- FOLLOWING THE GUIDE (1.7.4, modules/guidewalk.lua): out of combat
        -- the mob it is pulling for the step is the target, not the best
        -- scoring one near it.
        local walker = P.guidewalk
        if walker and walker.pull_target and not combat.in_combat() then
            local ok, unit = pcall(walker.pull_target)
            if ok and unit then
                if current and current:is_valid() and unit:get_guid() == current:get_guid() then return nil end
                return unit
            end
        end

        -- THE FIGHT DECIDES THE KILL ORDER (1.56.0). Solo with two or more
        -- engaged, the reaction engine's plan says who dies first -- what each
        -- mob does to us against how long it takes to kill, never one we have
        -- crowd-controlled (react/tactics.lua) -- with its own margin against
        -- flapping. The score below is for everything else: the opener, a
        -- group, a single mob.
        local react = P.react
        if react and react.focus and combat.in_combat() then
            local ok, focus, live = pcall(react.focus)
            if ok and live and focus then
                if current and current:is_valid() and focus:get_guid() == current:get_guid() then
                    return nil
                end
                return focus
            end
        end

        -- NEVER PULL SOMETHING NEW WHILE ALREADY IN A FIGHT.
        --
        -- Reported from live play: running away at low health, the mob being
        -- fought dropped out of the search range, the candidate list went
        -- empty, and the fallback below happily selected an unengaged hostile
        -- standing to the left -- pulling a fresh mob onto someone who was
        -- already trying to escape one.
        --
        -- So the "nearest enemy" fallback is now strictly an OUT OF COMBAT
        -- opener. In combat the only candidates are units already fighting us;
        -- if none is in range the answer is no target, not a new one.
        local range = P.tune_secs("rot_target_range", 30)
        local candidates = M.my_enemies(range)

        if #candidates == 0 then
            if combat.in_combat() then return nil end
            -- Selecting is not attacking: the target is picked whether or
            -- not fights may be started, and the rotation decides separately
            -- whether it may open on it (rotation.may_engage_unit).
            if not M.may_control_pull() then return nil end

            -- Do not start a fight we have not finished paying for. Pulling
            -- at half a mana bar is how a character ends up sitting down
            -- after every single mob; the recovery target is derived from
            -- what the next pull actually costs.
            if P.rest then
                local recovering, why = P.rest.recovering()
                if recovering then
                    log.once("debug", "hold_pull", "holding the pull: " .. why)
                    return nil
                end
            end
            if P.hardcore and not P.hardcore.may_pull() then return nil end

            -- What is coming for us IS the fight, whether or not it has
            -- reached the search range yet. The core's picture of every
            -- hostile says which ones are closing or already looking at us;
            -- opening on one of those beats opening on the nearest thing
            -- standing still.
            local enemies = P.ctx.enemies
            if enemies then
                local reach = range * 1.5
                local coming = enemies.where(function(row)
                    return (row.activity == "approaching" or row.targeting_me)
                        and row.dist <= reach
                end)
                for i = 1, #coming do
                    local obj = coming[i].obj
                    if obj and obj:is_valid() and not obj:is_dead() then
                        candidates[#candidates + 1] = obj
                    end
                end
            end
            if #candidates == 0 then candidates = units.enemies_within(range) end
        end

        local best, best_score = nil, -math.huge
        for i = 1, #candidates do
            local value = score(candidates[i], player)
            if value and value > best_score then best, best_score = candidates[i], value end
        end

        if not best then return nil end
        if current and best:get_guid() == current:get_guid() then return nil end

        -- A margin, so two mobs at similar health do not make the rotation
        -- flip between them every tick and land nothing on either.
        local margin = P.opt("rot_switch_margin", 25)
        if current_score and best_score < (current_score + margin) then return nil end

        return best
    end

    --- Switches target. Separate from better_target so the decision and the
    --- side effect are not tangled, and so the debug page can show the one
    --- without triggering the other.
    ---@param unit game_object
    ---@return boolean
    function M.switch_to(unit)
        if not unit or not unit:is_valid() then return false end
        local ok = pcall(core.input.set_target, unit)
        if ok then
            local ok_name, name = pcall(unit.get_name, unit)
            log.fmt("debug", "target -> %s", (ok_name and name) or "?")
            ctx.emit("jambix.aio.target_switched", unit:get_guid())
        end
        return ok
    end

    -- --- tank threat --------------------------------------------------------

    --- Engaged enemies we are NOT tanking.
    ---
    --- get_threat_situation is the client's own threat table, so this is a
    --- fact rather than an inference from facing or target. A valid situation
    --- that does not say we hold it (see holds) means somebody else is.
    ---@param range number
    ---@return game_objects_table
    function M.loose(range)
        local out = {}
        local player = units.player()
        if not player then return out end

        local engaged = M.engaged(range)
        for i = 1, #engaged do
            local enemy = engaged[i]
            local ok, situation = true, my_situation(enemy, player)
            if ok and type(situation) == "table" then
                if not holds(situation) then out[#out + 1] = enemy end
            else
                -- No threat data. Fall back to who it is hitting, which is
                -- worse but still better than assuming we have it.
                local ok_t, their_target = pcall(enemy.get_target, enemy)
                if ok_t and their_target and their_target:is_valid()
                    and their_target:get_guid() ~= player:get_guid() then
                    out[#out + 1] = enemy
                end
            end
        end
        return out
    end

    --- Threat percentage on a unit, 0 when unknown.
    ---@param unit game_object
    ---@return number
    function M.threat_on(unit)
        local player = units.player()
        if not player or not unit then return 0 end
        local ok, situation = true, my_situation(unit, player)
        if not ok or type(situation) ~= "table" then return 0 end
        return situation.threat_percent or 0
    end

    ---@param unit game_object
    ---@return boolean
    function M.tanking(unit)
        local player = units.player()
        if not player or not unit then return false end
        local ok, situation = true, my_situation(unit, player)
        if not ok or type(situation) ~= "table" then return false end
        return holds(situation)
    end

    --- The nearest loose enemy worth reclaiming, or nil.
    ---
    --- In a dungeon or raid this answers nil unless the scope setting allows
    --- it, because taunting something in an instance is a decision with
    --- consequences for four other people.
    ---@param range number
    ---@return game_object|nil
    function M.reclaim_target(range)
        if not P.opt("rot_hold_aggro", true) then return nil end
        if not M.may_control_pull() then return nil end

        local loose = M.loose(range)
        if #loose == 0 then return nil end

        local best, best_distance = nil, math.huge
        for i = 1, #loose do
            local distance = units.distance(loose[i])
            if distance < best_distance then best, best_distance = loose[i], distance end
        end
        return best
    end

    -- --- diagnostics --------------------------------------------------------

    function M.stats()
        local range = P.tune_secs("rot_target_range", 30)
        local engaged = M.engaged(range)
        local loose = M.loose(range)
        local cluster = M.best_cluster(P.opt("rot_aoe_radius", 8))
        return {
            context = M.context(),
            may_pull = M.may_control_pull(),
            engaged = #engaged,
            loose = #loose,
            cluster = cluster,
        }
    end

    return M
end

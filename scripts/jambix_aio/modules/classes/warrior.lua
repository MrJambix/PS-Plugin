-- Jambix AIO / classes / warrior
--
-- Sources: Icy Veins Classic Arms and Fury levelling guides; Icy Veins and
-- Wowhead Classic warrior tank guides.

return function(P, H, CS)
    local talents, book, targeting = H.talents, H.book, H.targeting

    -- Creature types immune to bleeds. Rend on them is pure rage loss.
    local BLEED_IMMUNE = { [4] = true, [9] = true }  -- Elemental, Mechanical

    local BATTLE, DEFENSIVE, BERSERKER =
        "Battle Stance", "Defensive Stance", "Berserker Stance"

    --- Improved Slam deep enough to make Slam worth its cast: 4 of Era's 5
    --- ranks, or all of Forever's 2 (1.77.3; it waited for rank 4 there, so a
    --- Forever Arms warrior never slammed). Forever's Slam is a strike on an
    --- 18 s cooldown, and the talent stops it touching the swing at all.
    local function improved_slam()
        local rank = talents.rank("Improved Slam")
        local max = talents.max_rank and talents.max_rank("Improved Slam") or 0
        if max <= 0 then max = 5 end
        return rank > 0 and rank >= math.min(4, max)
    end

    local function shout_upkeep(s)
        return not H.buff_up(s.player, "Battle Shout")
            or H.buff_remaining(s.player, "Battle Shout") < 10
    end

    -- THE RAGE LINES ARE THE SPEC'S OWN (1.35.x; they were sliders). The
    -- main attack's cost -- Mortal Strike and Bloodthirst 30, Whirlwind 25,
    -- Shield Slam 20 -- is what a warrior must be able to press; below it
    -- Bloodrage is worth its health, and above it plus a Heroic Strike the
    -- rest can be dumped. A warrior without them presses Heroic Strike at 30.
    local MAIN_COST = { { "Mortal Strike", 30 }, { "Bloodthirst", 30 },
                        { "Whirlwind", 25 }, { "Shield Slam", 20 } }
    local function main_cost()
        for i = 1, #MAIN_COST do
            if book.known(MAIN_COST[i][1]) then return MAIN_COST[i][2] end
        end
        return 15
    end

    local function bloodrage_wanted(s)
        if s.power >= main_cost() then return false end
        -- Bloodrage costs health: not while health is the problem.
        local posture = s.posture or "HEALTHY"
        if posture == "CRITICAL" or posture == "RECOVER" then return false end
        if s.in_combat then return true end
        return s.target ~= nil and H.units.distance(s.target) <= 30
    end

    local function opener_wanted(s)
        if s.in_combat then return false end
        if not P.opt("rot_open_combat", false) then return false end
        if not targeting.may_control_pull() then return false end
        if P.hardcore and not P.hardcore.may_pull() then return false end
        return true
    end

    local function rend_worth_it(s)
        if not s.target then return false end
        if H.debuff_remaining(s.target, "Rend") > 3 then return false end
        local ok, creature = pcall(s.target.get_creature_type, s.target)
        if ok and creature and BLEED_IMMUNE[creature] then return false end
        return s.ttd > P.tune_secs("rot_rend_min_ttd", 10)
    end

    local function sunder_worth_it(s)
        if not s.target then return false end
        if H.debuff_stacks(s.target, "Sunder Armor") >= 5 then return false end
        -- Worth stacking while the fight will last to use the armour off it
        -- (1.35.x; was a "target above 60%" slider, a stand-in for the same).
        return s.ttd > math.max(12, P.tune_secs("rot_rend_min_ttd", 10))
    end

    --- Execute consumes ALL remaining rage, so spending it on a next-swing
    --- attack during the execute window throws damage away.
    local function rage_to_dump(s)
        if s.power < main_cost() + 15 then return false end
        if H.execute_phase(s) and book.ready("Execute") then
            return false
        end
        return true
    end

    --- A mob that stopped targeting us while still moving is running. On a
    --- hardcore character a runner is a survival problem, not a damage one:
    --- it aggroes everything it passes and brings it back.
    local function target_fleeing(s)
        if not s.target or not s.in_combat then return false end
        local ok_move, moving = pcall(s.target.is_moving, s.target)
        if not ok_move or not moving then return false end
        local ok_t, their = pcall(s.target.get_target, s.target)
        if ok_t and their and their:is_valid()
            and their:get_guid() == s.player:get_guid() then
            return false
        end
        return not H.debuff_up(s.target, "Hamstring")
    end

    --- VICTORY RUSH (1.80.0): trained at 20 on Forever (a rune in Season of
    --- Discovery). Free, a tenth of your health back, and usable only for 20 s
    --- after a kill, which the client's own usable answer says. Icy Veins and
    --- Mobalytics press it whenever it is there.
    local function victory_rush_wanted(s)
        return s.target ~= nil
    end

    --- BLOODTHRILL (Forever, Arms, 1.80.0): swings at a target with your Rend
    --- may open Overpower. With it, Rend goes up first (every Forever guide);
    --- without it, it keeps its place lower down.
    local function bloodthrill_rend(s)
        return H.has_talent("Bloodthrill") and rend_worth_it(s)
    end

    local function player_feared(s)
        local ok, info = pcall(s.player.get_loss_of_control_info, s.player)
        if not ok or type(info) ~= "table" or not info.valid then return false end
        local kinds = P.loc_types
        if not kinds then return false end
        return info.type == kinds.FEAR or info.type == kinds.FEAR_MECHANIC
    end

    --- Threat spine shared by all three tank profiles. Shield Slam then
    --- Revenge then Sunder is threat per global cooldown, and the aggro
    --- recovery above it outranks all of them: extra threat on the current
    --- target does nothing for a mob nobody is holding.
    local function tank_core(main_attack)
        return {
            { "Berserker Rage", player_feared, self = true, fast = true },
            { "Bloodrage", bloodrage_wanted, fast = true, self = true },
            { "Battle Shout", shout_upkeep, self = true, upkeep = 20 },
            { "Charge", opener_wanted },
            { "Challenging Shout", function(s)
                return #s.loose >= P.opt("rot_challenging_shout_count", 3)
                    and targeting.reclaim_target(P.tune_secs("rot_target_range", 30)) ~= nil
            end, self = true, upkeep = 20 },
            { "Taunt", function(s)
                local loose = targeting.reclaim_target(P.tune_secs("rot_target_range", 30))
                if not loose then return false end
                s.reclaim = loose
                return true
            end, retarget = "reclaim", upkeep = 1 },
            { "Mocking Blow", function(s)
                local loose = targeting.reclaim_target(8)
                if not loose then return false end
                s.reclaim = loose
                return true
            end, retarget = "reclaim", upkeep = 1 },
            -- Off-GCD. As a GCD rule it displaced Revenge or Shield Slam every
            -- time it came off cooldown, which is a straight threat loss.
            { "Shield Block", function(s)
                return s.in_combat
            end, self = true, fast = true, upkeep = 2 },
            { "Revenge", function() return true end },
            { "Victory Rush", victory_rush_wanted },
            { "Shield Slam", function() return true end },
            { "Thunder Clap", function(s) return H.spread(s, 2) end, self = true, upkeep = 4 },
            { "Demoralizing Shout", function(s)
                return H.spread(s, 2) and not H.debuff_up(s.target, "Demoralizing Shout")
            end, self = true, upkeep = 4 },
            { "Sunder Armor", function(s)
                return s.target ~= nil and H.debuff_stacks(s.target, "Sunder Armor") < 5
            end, upkeep = 1.5 },
            { main_attack, function() return true end },
            { "Execute", H.execute_phase },
            { "Cleave", function(s) return rage_to_dump(s) and H.spread(s, 2) end, fast = true },
            { "Heroic Strike", rage_to_dump, fast = true },
        }
    end

    local profiles = {}

    -- Arms. Mortal Strike is the core; Overpower is free damage whenever the
    -- client says the dodge window is open. Sweeping Strikes and Overpower sit
    -- ABOVE Execute because both are windows that expire and the execute
    -- window does not close while the target lives.
    profiles.dps_arms = {
        label = "DPS Arms",
        form = BATTLE,
        acceptable = { [BATTLE] = true },
        rules = {
            { "Berserker Rage", player_feared, self = true, fast = true },
            { "Bloodrage", bloodrage_wanted, fast = true, self = true },
            { "Battle Shout", shout_upkeep, self = true, upkeep = 20 },
            { "Charge", opener_wanted },
            { "Hamstring", target_fleeing, upkeep = 2 },
            { "Sweeping Strikes", function(s) return H.spread(s, 2) end, self = true, upkeep = 5 },
            { "Rend", bloodthrill_rend, upkeep = 2 },
            { "Overpower", function() return true end },
            { "Execute", H.execute_phase },
            { "Victory Rush", victory_rush_wanted },
            { "Mortal Strike", function() return true end },
            -- Spearing Strike (Forever, Arms): weapon damage, more against
            -- Giants, Dragonkin and anything mounted, on a 20 s cooldown.
            { "Spearing Strike", function() return true end },
            { "Whirlwind", function() return true end, self = true },
            { "Thunder Clap", function(s) return H.spread(s, 3) end, self = true, upkeep = 4 },
            { "Demoralizing Shout", function(s)
                -- Two or more hitting us is when less of their damage matters.
                return H.spread(s, 2)
                    and not H.debuff_up(s.target, "Demoralizing Shout")
            end, self = true, upkeep = 4 },
            { "Rend", rend_worth_it, upkeep = 2 },
            { "Sunder Armor", sunder_worth_it, upkeep = 1.5 },
            { "Slam", function(s)
                -- Only with Improved Slam. At base it is a 1.5s cast that
                -- clips the swing timer and loses damage.
                return improved_slam() and not s.player:is_moving()
            end },
            { "Cleave", function(s) return rage_to_dump(s) and H.spread(s, 2) end, fast = true },
            { "Heroic Strike", rage_to_dump, fast = true },
        },
    }

    profiles.dps_fury = {
        label = "DPS Fury",
        form = BERSERKER,
        acceptable = { [BERSERKER] = true },
        rules = {
            { "Berserker Rage", player_feared, self = true, fast = true },
            { "Bloodrage", bloodrage_wanted, fast = true, self = true },
            { "Battle Shout", shout_upkeep, self = true, upkeep = 20 },
            { "Charge", opener_wanted },
            -- Only to close a gap the fight opened: the target out of reach
            -- and not coming to us.
            { "Intercept", function(s)
                if not s.in_combat or not s.target then return false end
                local d = s.distance or H.units.distance(s.target)
                if d < 8 or d > 25 then return false end
                local row = s.target_row
                return not (row and row.targeting_me and (row.closing or 0) > 1)
            end },
            { "Hamstring", target_fleeing, upkeep = 2 },
            { "Execute", H.execute_phase },
            { "Victory Rush", victory_rush_wanted },
            { "Bloodthirst", function() return true end },
            { "Whirlwind", function() return true end, self = true },
            { "Rampage", function(s) return not H.buff_up(s.player, "Rampage") end,
              self = true, upkeep = 2 },
            { "Overpower", function() return true end },
            { "Rend", rend_worth_it, upkeep = 2 },
            { "Sunder Armor", sunder_worth_it, upkeep = 1.5 },
            { "Cleave", function(s) return rage_to_dump(s) and H.spread(s, 2) end, fast = true },
            { "Heroic Strike", rage_to_dump, fast = true },
        },
    }

    profiles.tank_arms = {
        label = "Tank Arms", form = DEFENSIVE,
        acceptable = { [DEFENSIVE] = true }, rules = tank_core("Mortal Strike"),
    }

    profiles.tank_fury = {
        label = "Tank Fury", form = DEFENSIVE,
        acceptable = { [DEFENSIVE] = true }, rules = tank_core("Bloodthirst"),
    }

    profiles.tank_prot = {
        label = "Tank Full Spec", form = DEFENSIVE,
        acceptable = { [DEFENSIVE] = true },
        rules = (function()
            local rules = tank_core("Mortal Strike")
            -- Concussion Blow is a STUN, not a damage cooldown, and gating
            -- it on a burst window was simply wrong: its value is stopping a
            -- cast or peeling something off you, neither of which has
            -- anything to do with whether cooldowns are worth spending.
            table.insert(rules, #rules - 1, { "Concussion Blow", function(s)
                if H.enemy_caster() then return true end
                -- Otherwise it is worth a global cooldown only when the fight
                -- is going badly enough that four seconds of one mob not
                -- acting changes something.
                return H.in_trouble()
            end })
            return rules
        end)(),
    }

    return {
        key = "warrior",
        label = "Warrior",
        trees = { "Arms", "Fury", "Protection" },
        buffs = {},
        icon = "swords",
        tank_capable = true,
        uses_forms = true,
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
            { spell = "Death Wish", duration = 30 },
            { spell = "Recklessness", duration = 15 },
        },

        class_name = "WARRIOR",
        power = "RAGE",
        forms = { BATTLE, DEFENSIVE, BERSERKER },
        interrupts = { "Pummel", "Shield Bash" },
        defensives = { "Shield Wall", "Last Stand" },
        escapes = { "Intimidating Shout", "Piercing Howl" },
        profiles = profiles,
        profile_order = { "dps_arms", "dps_fury", "tank_arms", "tank_fury", "tank_prot" },

        --- Protection points win outright: nobody spends there without meaning
        --- to tank. Otherwise the dominant damage tree decides Arms or Fury.
        --- Warrior-only settings. Every one of these names a warrior ability,
        --- which is exactly why none of them belongs in a shared list.

        suggest = function(t, prefer_tank)
            local arms, fury, prot = t.points()
            if prot > 0 and prot >= arms and prot >= fury then return "tank_prot" end
            if fury > arms then return prefer_tank and "tank_fury" or "dps_fury" end
            return prefer_tank and "tank_arms" or "dps_arms"
        end,
    }
end

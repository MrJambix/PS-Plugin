-- Jambix AIO / react / adapt -- the rotation, changed by what is happening.
--
-- A REACTION IS NOT ONLY A DEFENSIVE. It is what the fight does to every
-- choice, and the biggest of those choices is the rotation's: which damage
-- spell, of the ones that would go out right now, is the right one HERE.
--
-- modules/rotation.lua asks this for every rule that passes. The rule's
-- place in its class's list is the starting score; this moves it, with a
-- reason for every point, from the same world state the reactions read:
--
--   the pack      area damage by what it would hit where it lands (tactics.lua):
--                 up from two in reach, down on one, never beside a mob we
--                 crowd-controlled or (solo) an idle one it would pull
--   the target    a cast it will not live through, a DoT it will not live to
--                 take, an execute in range, a DoT on a long fight
--   your legs     a cast or channel while moving is not a candidate at all
--   the mana      an expensive spell down as the bar runs out -- by what it
--                 costs, not by a line
--   the moment    control up and damage down when the fight goes wrong, a
--                 slow up on a runner or on a mob closing in, a long cast
--                 down when the mob arrives before it lands
--   the pet       solo, a damage special waits while the pet is still
--                 settling the mob or we are close to pulling it off
--
-- Toggles (Auto Shot, a wand) and rules marked `fixed` are never moved: they
-- are a running state or a deliberate sequence, not a choice between spells.

return function(P, world, damage, tactics)
    local units, combat = P.units, P.combat
    local book = P.spellbook
    local ctx = P.ctx

    local A = {}

    local floor, min, max, huge = math.floor, math.min, math.max, math.huge
    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    -- --- what a spell is -------------------------------------------------------
    --
    -- The catalogue says it for every ability it describes; these names cover
    -- the classes it does not describe yet.

    local AOE_NAMES = {
        ["Multi-Shot"] = true, ["Volley"] = true, ["Explosive Trap"] = true,
        ["Cleave"] = true, ["Whirlwind"] = true, ["Thunder Clap"] = true,
        ["Arcane Explosion"] = true, ["Blizzard"] = true, ["Flamestrike"] = true,
        ["Cone of Cold"] = true, ["Blast Wave"] = true, ["Consecration"] = true,
        ["Holy Wrath"] = true, ["Hurricane"] = true, ["Swipe"] = true, ["Swipe (Cat)"] = true, ["Holy Nova"] = true,
        ["Chain Lightning"] = true, ["Magma Totem"] = true, ["Fire Nova Totem"] = true,
        ["Rain of Fire"] = true, ["Hellfire"] = true, ["Blade Flurry"] = true,
        ["Seed of Corruption"] = true,
    }
    local EXECUTE_NAMES = {
        ["Execute"] = true, ["Hammer of Wrath"] = true, ["Drain Soul"] = true,
        ["Shadowburn"] = true, ["Kill Shot"] = true,
    }
    local CONTROL_NAMES = {
        ["Concussive Shot"] = true, ["Wing Clip"] = true, ["Scatter Shot"] = true,
        ["Hamstring"] = true, ["Piercing Howl"] = true, ["Frost Nova"] = true,
        ["Earthbind Totem"] = true, ["Frost Shock"] = true, ["Hammer of Justice"] = true,
        ["Entangling Roots"] = true, ["Bash"] = true, ["Kidney Shot"] = true,
        ["Cheap Shot"] = true, ["Gouge"] = true, ["Intimidating Shout"] = true,
        ["Psychic Scream"] = true, ["Fear"] = true, ["Howl of Terror"] = true,
        ["Death Coil"] = true, ["Polymorph"] = true, ["Blind"] = true,
        ["Hibernate"] = true, ["War Stomp"] = true, ["Concussion Blow"] = true,
        ["Repentance"] = true, ["Crippling Poison"] = true, ["Mind Flay"] = true,
    }
    -- Only usable for a moment after something happens -- a dodge, a parry, a
    -- block, a kill. A window that closes unused is damage that never was.
    local REACTIVE = {
        ["Overpower"] = true, ["Revenge"] = true, ["Riposte"] = true,
        ["Counterattack"] = true, ["Mongoose Bite"] = true, ["Victory Rush"] = true,
    }
    local REACTIVE_NEEDS = { after_dodge = true, after_parry = true, after_block = true }

    -- Procs on us that change which spell is right: the next one free, or the
    -- next cast instant.
    local PROCS = {
        ["Clearcasting"] = { free = true },
        ["Inner Focus"] = { free = true },
        ["Shadow Trance"] = { instant = { ["Shadow Bolt"] = true } },
        ["Presence of Mind"] = { instant = "any" },
        ["Nature's Swiftness"] = { instant = "any" },
    }

    local CONTROL_ROLES = { slow = true, root = true, stun = true, disorient = true,
                            fear = true, sleep = true, cc = true }

    -- The moving flag drops for a frame between two movement keys; a cast
    -- pressed on that frame is "Can't do that while moving".
    local SETTLE = 0.25

    -- LET THE PET KEEP IT (1.36.0). Solo, the pet is the tank, and a mob turns
    -- to whoever has the most threat on it. The live log has the same pull
    -- over and over: the mark, the sting a second later, an Arcane Shot, and
    -- the mob leaves the pet and spends the fight in the dead zone, where a
    -- hunter's damage is a Raptor Strike every six seconds. So while the pet
    -- holds the target, a damage special waits --
    --   for the pet to settle it   PET_SETTLE seconds on the pet first: its
    --                              opening Growl is most of its threat
    --   while we are near pulling  our threat on it (the client's percent,
    --                              100 = it turns to us) at 85 or more, until
    --                              it is back under 70 (detect.lua, pet_threat)
    --   when this one would do it  what we have dealt it so far and that
    --                              percent say what one more of this spell
    --                              makes the percent; at THREAT_HOLD it waits
    -- Auto Shot, a wand and melee swings never wait (a toggle is not asked),
    -- nothing waits once the mob is on us anyway, and nothing waits on a mob
    -- that dies before it could reach us.
    local PET_SETTLE, THREAT_HOLD = 1.5, 85
    local DOT_NEAR = 0.5          -- a DoT's threat comes over its duration, the pet's keeps coming too
    local DYING = 4               -- seconds: pulling it no longer matters

    -- NOTHING SPENT ON THE DEAD (1.37.0). A mob the pet and Auto Shot finish in
    -- the next moment does not need a special: its mana is the next pull's,
    -- and the live log's hunter was at 8% mana twice in five minutes. Only
    -- while something else is hitting it (a shot, a swing, the pet), only
    -- while it is not on us (then quicker is safer), and only for a spell
    -- that costs mana while the bar is not nearly full.
    local FINISHING = 2.0

    -- KEEP THE SLOW FOR THE RUN (1.38.0). A mob that runs when it is low comes
    -- back with company, and a slow on cooldown when it goes is that company.
    -- A slow with a real cooldown (Concussive Shot's twelve seconds) is not
    -- spent on a mob that will run before it is back -- unless it is running
    -- now. Which mobs run is learned (learn.lua); until then, humanoids do.
    local FLEE_AT, SAVE_CD = 0.2, 5
    local SLOW_NAMES = {
        ["Concussive Shot"] = true, ["Wing Clip"] = true, ["Hamstring"] = true,
        ["Frost Shock"] = true, ["Earthbind Totem"] = true, ["Crippling Poison"] = true,
    }

    local tag_cache = {}          -- name -> { at, tags }
    local TAG_TTL = 10.0          -- a rank change can change a cast time

    local function tags_for(name, rule, row)
        local now = core.time()
        local hit = tag_cache[name]
        if hit and (now - hit.at) < TAG_TTL then return hit.tags end

        local t = { aoe = false, dot = false, execute = false, control = false,
                    damage = false, heal = false, cast = 0, channel = false }
        local roles = {}
        if row and row.roles then
            for i = 1, #row.roles do roles[row.roles[i]] = true end
        end
        t.aoe = roles.aoe or rule.aoe == true or AOE_NAMES[name] == true
        t.dot = rule.dot == true or roles.dot == true
        t.execute = roles.execute or EXECUTE_NAMES[name] == true
        t.heal = rule.heal == true or roles.heal == true
        t.control = CONTROL_NAMES[name] == true
        t.slow = roles.slow == true or roles.root == true or SLOW_NAMES[name] == true
        t.cooldown = row and tonumber(row.cooldown) or 0
        t.reactive = REACTIVE[name] == true
        if row and row.needs then
            for i = 1, #row.needs do
                if REACTIVE_NEEDS[row.needs[i]] then t.reactive = true end
            end
        end
        for role in pairs(roles) do
            if CONTROL_ROLES[role] then t.control = true end
        end
        if row then
            t.damage = roles.damage == true or roles.dot == true or roles.aoe == true
        else
            t.damage = not rule.self and not rule.heal
        end

        -- Cast and channel time: the catalogue's figure, else the client's.
        local cast = row and tonumber(row.cast) or nil
        if row and (row.kind == "channel" or tonumber(row.channel)) then t.channel = true end
        if rule.channel then t.channel = true end
        if cast == nil then
            local id = book.id(name)
            local spells = ctx and ctx.spells
            if id and spells and spells.info then
                local ok, info = pcall(spells.info, id)
                if ok and type(info) == "table" then cast = tonumber(info.cast_time) end
            end
        end
        t.cast = cast or 0
        t.channel_time = (row and tonumber(row.channel)) or (t.channel and 3) or 0

        tag_cache[name] = { at = now, tags = t }
        return t
    end
    A.tags_for = tags_for

    -- Mana cost, once per name per tick.
    local cost_cache, cost_at = {}, -1
    local function cost_of(name)
        local now = core.time()
        if now ~= cost_at then cost_cache, cost_at = {}, now end
        local hit = cost_cache[name]
        if hit ~= nil then return hit or nil end
        local auto = P.auto
        local cost = auto and auto.cost_fraction and auto.cost_fraction(name) or nil
        cost_cache[name] = cost or false
        return cost
    end

    --- How the fight moves one rotation candidate.
    ---@param rule table the class rule
    ---@param row table|nil its catalogue row
    ---@param s table the rotation's snapshot
    ---@param c table the candidate ({ target })
    ---@return number bonus
    ---@return table|nil reasons { {points, why}, ... }
    ---@return string|nil refuse a reason it is not a candidate at all
    function A.adjust(rule, row, s, c)
        -- This tick's picture, built a moment ago by the reaction tick. A
        -- stale one (the engine failed this tick) moves nothing.
        local W = world.W
        if not W or not W.player or math.abs(core.time() - (W.now or -huge)) > 0.25 then
            return 0, nil, nil
        end

        local name = rule[1]
        local t = tags_for(name, rule, row)
        -- The words are for the readout: formatted only while something is
        -- reading them, so a walk every frame does not build strings nobody sees.
        local explain = W.explain == true
        local bonus, reasons = 0, nil
        local function add(points, fmt, ...)
            if not points or points == 0 then return end
            bonus = bonus + points
            if explain then
                reasons = reasons or {}
                reasons[#reasons + 1] = { points, select("#", ...) > 0 and string.format(fmt, ...) or fmt }
            end
        end

        local pl, en = W.player, W.enemies
        local casts = t.cast > 0 or t.channel

        -- Triggers on us: the next spell free, or the next cast instant.
        local proc_free, proc_instant, proc_name = nil, false, nil
        local auras = pl.aura_names
        if auras then
            for aura, p in pairs(PROCS) do
                if auras[aura] then
                    if p.free then proc_free = aura end
                    if p.instant and t.cast > 0 and not t.channel
                        and (p.instant == "any" or p.instant[name]) then
                        proc_instant, proc_name = true, aura
                    end
                end
            end
        end
        if proc_instant then casts = false end

        -- Your legs: nothing with a cast bar goes out on the move, or the
        -- moment the character stops.
        if casts and not rule.while_moving then
            if pl.moving then return 0, nil, "moving: it has a cast time" end
            if (pl.still_for or huge) < SETTLE then return 0, nil, "just stopped moving: it has a cast time" end
        end

        -- The target.
        local target = c.target
        local ttd = nil
        if target and target ~= s.player then
            if target == s.target then
                ttd = s.ttd
            else
                local ok, value = pcall(combat.time_to_die, target)
                ttd = ok and value or nil
            end
        end
        if type(ttd) == "number" and ttd > 0 and ttd < huge then
            if t.cast > 0 and not proc_instant and (t.cast + 0.3) >= ttd then
                add(-20, "it dies in %.1fs, before the %.1fs cast lands", ttd, t.cast)
            end
            if t.dot and ttd < 8 then add(-12, "dies in %.0fs: the DoT will not tick out", ttd) end
            if t.dot and ttd > 25 then add(5, "a long fight: the DoT pays") end
            if t.execute and ((s.thp or 1) <= 0.2 or ttd < 6) then add(10, "finish it") end
        end

        -- A mob that will run before this slow is back: keep it for the run.
        if t.slow and t.cooldown >= SAVE_CD and W.target.runs and target ~= nil and target == s.target then
            local tr0 = s.target_row
            local running = tr0 ~= nil and tr0.activity == "fleeing"
            local hp = s.thp or 1
            if not running and type(ttd) == "number" and ttd > 0 and ttd < huge and hp > 0 then
                local to_run = math.max(0, ttd * (hp - FLEE_AT) / hp)
                if to_run < t.cooldown then
                    return 0, nil, string.format("saving it: it runs at %d%% in about %.0fs", pct(FLEE_AT), to_run)
                end
            end
        end

        -- Nearly dead and being finished anyway: keep the mana.
        if t.damage and not t.control and target ~= nil and target == s.target
            and type(ttd) == "number" and ttd > 0 and ttd < FINISHING
            and pl.power_kind == "MANA" and pl.power_max > 0 and pl.power_pct < 0.8
            and not W.target.targets_me
            and (pl.shooting or pl.auto_attacking or W.pet.tanking) then
            local cost = cost_of(name)
            if cost and cost > 0 then
                return 0, nil, string.format("it dies in %.1fs anyway: keep the mana", ttd)
            end
        end

        -- The pet is the tank: let it keep the mob.
        local pet = W.pet
        if pet.tanking and t.damage and not t.control and not t.heal and not rule.self
            and target ~= nil and target == s.target
            and not (type(ttd) == "number" and ttd > 0 and ttd < DYING) then
            if (pet.held_for or 0) < PET_SETTLE then
                return 0, nil, string.format("the pet has held it %.1fs: let it build threat first", pet.held_for or 0)
            end
            local p = W.target.threat_pct
            if W.sit.pet_threat then
                return 0, nil, string.format("%d%% threat: the pet keeps it", floor(p or 0))
            end
            local done = damage and damage.dealt and damage.dealt(W.target.guid) or 0
            if type(p) == "number" and p >= 5 and done > 0 then
                local e = damage.expected(name, ttd)
                if e and e > 0 then
                    if t.dot then e = e * DOT_NEAR end
                    local after = p * (done + e) / done
                    if after >= THREAT_HOLD then
                        return 0, nil, string.format("%d%% threat, about %d%% after it: the pet would lose it",
                            floor(p), floor(after))
                    end
                end
            end
        end

        -- The pack: what an area spell would hit, counted where it lands --
        -- around the target for a shot, around us for a nova (tactics.lua).
        -- Two in reach is enough to weigh it; weigh() below counts each one.
        local engaged = en.engaged or 0
        local aoe_now = W.sit.aoe or W.field.plan == "AOE"
        if t.aoe then
            local reach, wakes, pulls = nil, nil, nil
            if tactics then reach, wakes, pulls = tactics.reach(name, row, target) end
            if wakes then return 0, nil, string.format("it would wake %s: crowd-controlled beside it", wakes) end
            if pulls and W.env.solo then
                return 0, nil, string.format("it would pull %s, standing beside it", pulls)
            end
            reach = reach or engaged
            if reach >= 2 then
                add(min(12, 4 * (reach - 1)), "%d in reach: hit them all", reach)
            else
                add(-15, "one in reach: area damage is wasted")
            end
        elseif aoe_now and t.damage and not t.dot and not t.control then
            add(-3, "single-target while area damage pays more")
        end
        if t.dot and rule.spread and engaged >= 2 then add(3, "spread across the pack") end

        -- Triggers: use the window, spend the proc where it is worth most.
        if t.reactive then add(8, "only usable for a moment: use the window") end
        if proc_instant then add(10, "%s: instant now", proc_name) end
        if proc_free and pl.power_kind == "MANA" then
            local cost = cost_of(name)
            if cost and cost > 0 then
                add(min(15, cost * 120), "%s: free -- the dearest spell gains most", proc_free)
            end
        end

        -- The mana: by what the spell costs. Not while the next one is free.
        if pl.power_kind == "MANA" and pl.power_max > 0 and not proc_free then
            local cost = cost_of(name)
            if cost and cost > 0 then
                if W.sit.mana_low or pl.posture == "RECOVER" or pl.posture == "CRITICAL" then
                    add(-min(25, cost * 150), "mana low: it costs %d%%", pct(cost))
                elseif pl.power_empty < pl.fight_left then
                    add(-min(15, cost * 90), "mana runs out before the fight: %d%% a cast", pct(cost))
                elseif pl.posture == "CONSERVE" then
                    add(-min(8, cost * 50), "conserving mana")
                end
            elseif t.damage and (W.sit.mana_low or pl.posture == "RECOVER") then
                add(3, "costs no mana")
            end
        end

        -- The moment.
        local mode = W.mode
        if mode == "DEFENSIVE" or mode == "EMERGENCY" then
            if t.control then add(8, "control takes the pressure off") end
            if t.heal then add(8, "healing first") end
            if t.cast > 1.5 and (en.melee_on_me or 0) > 0 then add(-6, "a long cast gets pushed back while you are hit") end
        elseif mode == "ESCAPE" then
            if t.control then
                add(15, "control buys the escape")
            elseif t.damage then
                add(-10, "breaking off, not trading damage")
            end
        end

        -- The target's legs.
        local tr = s.target_row
        if tr and target == s.target then
            if t.control then
                if tr.activity == "fleeing" then
                    add(10, "it is running")
                elseif tr.targeting_me and (tr.closing or 0) > 1 and (tr.dist or 0) > 8 then
                    add(6, "it is closing on you")
                end
            end
            if t.cast > 0 and tr.targeting_me and (tr.closing or 0) > 1 then
                local eta = tr.time_to_reach
                if type(eta) == "number" and eta < t.cast then
                    add(-10, "it reaches you in %.1fs, before the cast lands", eta)
                end
            end
        end

        if W.env.pvp and t.control then add(5, "PvP: control wins fights") end

        return bonus, reasons, nil
    end

    -- --- weighing the candidates against each other ------------------------------
    --
    -- WHAT EACH SKILL DOES, NOT WHERE IT SITS IN A LIST. Of the damage skills
    -- that could go out right now, each is worth its damage (damage.lua:
    -- measured from the combat log, the tooltip until then) per second of the
    -- lane it holds -- a three-second cast holds it for three, an instant for
    -- the global cooldown. An area skill counts every target it would hit; a
    -- damage-over-time skill counts only the ticks the target lives to take.
    -- When mana is what runs out first, it is damage per point of mana instead.
    --
    -- The best gets nothing; every other loses up to DAMAGE_WEIGHT in
    -- proportion, so setup that is not damage -- a mark, an aspect, a toggle --
    -- keeps its place, and among the damage skills the one that kills fastest
    -- rises.
    --
    -- AND THE KILL ITSELF. When a skill does enough to finish what is left of
    -- the target, the quickest and cheapest such skill gets KILL_BONUS: there
    -- is no point spending a three-second, two-hundred-mana spell on a mob an
    -- instant would have killed.
    local DAMAGE_WEIGHT, KILL_BONUS = 8, 6
    local AOE_CAP = 5

    ---@param cands table[] candidates with rule, row, target, fast, score, reasons
    ---@param s table the rotation's snapshot
    function A.weigh(cands, s)
        local W = world.W
        if not damage or not W or not W.player or math.abs(core.time() - (W.now or -huge)) > 0.25 then
            return
        end
        local explain = W.explain == true
        local pl, en = W.player, W.enemies
        local mana_bound = pl.power_kind == "MANA" and pl.power_max > 0
            and (W.sit.mana_low or pl.posture == "CONSERVE" or pl.posture == "RECOVER"
                or pl.power_empty < pl.fight_left)
        local remaining = damage.remaining(s.target)

        local function add(c, points, fmt, ...)
            if not points or math.abs(points) < 0.05 then return end
            c.score = c.score + points
            if explain then
                c.reasons = c.reasons or {}
                c.reasons[#c.reasons + 1] = { points, select("#", ...) > 0 and string.format(fmt, ...) or fmt }
            end
        end

        for pass = 1, 2 do
            local fast = pass == 2
            local rows, best, best_name = {}, 0, nil
            for i = 1, #cands do
                local c = cands[i]
                if (c.fast == true) == fast and not c.lazy and c.rule then
                    local rule = c.rule
                    local name = rule[1]
                    local t = tags_for(name, rule, c.row)
                    if t.damage then
                        local ttd = (c.target == s.target) and s.ttd or nil
                        local dmg, source = damage.expected(name, ttd)
                        if dmg then
                            if t.aoe then
                                local reach = tactics and tactics.reach(name, c.row, c.target) or nil
                                dmg = dmg * min(max(reach or en.engaged or 1, 1), AOE_CAP)
                            end
                            local lane = fast and 1 or max(1.5, t.cast or 0, t.channel_time or 0)
                            local cost = cost_of(name)
                            local v
                            if mana_bound then
                                v = dmg / max(cost or 0, 0.002)
                            else
                                v = dmg / lane
                            end
                            rows[#rows + 1] = { c = c, dmg = dmg, v = v, lane = lane, cost = cost or 0,
                                                source = source, name = name }
                            if v > best then best, best_name = v, name end
                        end
                    end
                end
            end
            if best > 0 then
                for i = 1, #rows do
                    local r = rows[i]
                    local share = r.v / best
                    if share < 0.995 then
                        add(r.c, DAMAGE_WEIGHT * (share - 1), "%d%% of the best %s (%s)",
                            floor(share * 100 + 0.5), mana_bound and "damage per mana" or "damage per second",
                            best_name)
                    elseif explain then
                        r.c.reasons = r.c.reasons or {}
                        r.c.reasons[#r.c.reasons + 1] = { 0, string.format("the best %s: %.0f %s (%s)",
                            mana_bound and "damage per mana" or "damage per second",
                            mana_bound and r.dmg or r.v, mana_bound and "a cast" or "a second", r.source) }
                    end
                end
                -- The killing blow: the quickest, then cheapest, skill that finishes it.
                if remaining then
                    local killer = nil
                    for i = 1, #rows do
                        local r = rows[i]
                        if r.c.target == s.target and r.dmg >= remaining * 0.95 then
                            if not killer or r.lane < killer.lane
                                or (r.lane == killer.lane and r.cost < killer.cost) then
                                killer = r
                            end
                        end
                    end
                    if killer then
                        add(killer.c, KILL_BONUS, "kills it: %d health left, %d damage", floor(remaining),
                            floor(killer.dmg))
                    end
                end
            end
        end
    end

    return A
end

-- Jambix AIO / react / tactics -- the plan for the fight in front of us.
--
-- THE ROTATION IS THE DEFAULT; THE FIGHT DECIDES (1.56.0)
-- A class's priority list knows its spells. It does not know that a second
-- mob has just walked in, and every choice it made after that moment was a
-- choice about one mob in a fight with two: the old target score kept the
-- same mob whatever it was doing, the area spells waited for a third mob
-- (and counted every engaged mob, wherever it stood), and the pet only let
-- go of its mob once that one was nearly dead. This is the part of the
-- reaction engine that re-plans the fight whenever its shape changes; the
-- rotation reads the plan instead of deciding those things itself:
--
--   who dies first   the kill order: what each mob is doing to us against how
--                    long it takes to kill. The mob that hits hardest for the
--                    health it has left goes first, so its damage leaves the
--                    fight soonest; a heal being cast weighs more; one we have
--                    crowd-controlled is never chosen (hitting it wakes it)
--   who holds what   solo with a pet: the pet takes the add that is hitting
--                    us when the mob it holds will stay on it -- our threat on
--                    that one, the client's percent, says whether it would
--   what an area spell reaches   counted where it lands: around the target
--                    for a Multi-Shot, around us for an Arcane Explosion. Two
--                    in reach is enough to weigh it against the single-target
--                    spell; a mob we controlled beside it, or an idle one it
--                    would pull, rules it out
--   whether we survive it   the race again (field.lua), with each mob's damage
--                    on us counted from its first hit -- the combat log, by
--                    source -- instead of after the health bar shows it
--
-- Nothing here casts. targeting.lua takes the kill order (in combat, solo),
-- adapt.lua and rotation.lua's H.spread take the reach, the "Pet: pick up the
-- add" reaction takes the hold, behavior.lua takes the race.
--
-- No game reads beyond what world.lua already made, except each engaged mob's
-- health in points, once per re-plan (JCore's per-frame cache), so the kill
-- order compares a big mob's 40% with a small one's 40% honestly.
--
-- IN A GROUP (1.58.0). A damage dealer in a group with a living tank gets a
-- plan too, weighted the way a group kills: everyone on the tank's target
-- (x1.6), a skull (x2.5) or a cross (x1.8) first, a mob on the healer before
-- one on the tank, and nothing whose threat would leave the tank for you --
-- our threat on it, the client's percent, takes the urgency down towards 0.1
-- at 95. Damage on any member of the group counts (the combat log, by
-- source). The tank and the healer keep their own targeting; the pet is the
-- tank's business there; the race is the healer's. A group whose tank is dead
-- is fought as solo.
--
-- THE SAME PLAN ON FOREVER (1.57.0). Its client leaves three of these inputs
-- out, and JCore (1.6.4) answers each from what it does say; nothing here
-- asks which client it is:
--   damage on us   no combat log: JCore shares each drop in our own and the
--                  pet's health among the mobs attacking each
--                  (enemies.damage_rate), asked when our own tally is empty
--   crowd control  no loss of control on mobs: JCore reads the mob's debuffs
--                  and says whether damage breaks it (row.control.breaks)
--   threat         answered as zeros: JCore proves it and reports it unread,
--                  so "the pet's mob stays on it" falls back to "you have not
--                  hit it" instead of believing a fake 0%
--
-- A PET THAT TAUNTS (1.68.0). With Growl or Torment (react/petthreat.lua),
-- solo, the plan leans on the pet. The mob on you goes to the pet even when
-- it is the one to kill first: you kill it once it is on the pet. If the
-- mob the pet leaves would turn on you, the pet still goes when the one on
-- you is hitting you in melee or you are under 60%. And a mob on the pet
-- that your threat is close to pulling (75%, 90% from the client's percent)
-- drops down the kill order, unless the pet's taunt lands on it within a
-- second: shoot something else and leave it to the pet.

return function(P, world, memory)
    local units = P.units

    local T = {}

    local floor, min, max, huge, sqrt = math.floor, math.min, math.max, math.huge, math.sqrt
    local function pct(x) return floor((x or 0) * 100 + 0.5) end

    local EVERY = 0.2             -- seconds between re-plans, unless the fight changes shape
    local SWITCH = 1.3            -- a new focus must be this much more urgent than the one we are on
    local SETTLE = 1.5            -- seconds a focus the plan chose is kept before another may replace it
    -- IN A GROUP THE KILL IS KEPT LONGER (1.74.0). The tank tabs through the
    -- pack for a Sunder on each, and its target is weighed x1.6 (ASSIST): a
    -- margin under that moved the focus with every tab. The live log (a
    -- five-man on Forever) re-planned "kill X first" every one to three
    -- seconds. Twice as urgent, and four seconds on it first; a skull
    -- (x2.5) still wins, and a mob nearly dead is soon twice as urgent anyway.
    local SWITCH_GROUP, SETTLE_GROUP = 2.0, 4.0
    local PET_LEAVE = 60          -- our threat on the pet's mob under which it stays on the pet
    local PET_FIT = 0.4           -- pet health under which it is not given more to hold
    local RUNWAY = 30             -- past this much life the race is no worry (field.lua's SAFE_RUNWAY)
    local MARGIN = 1.15           -- the head start a race needs before it counts as won
    local DEAD_ZONE = 8           -- a hunter's minimum range: inside it, no shots on that mob
    local MELEE_REACH = 8         -- a melee class's reach, give or take a step
    local FAR = 40                -- past this, nobody's spells reach it
    -- Classes that fight in melee whatever their talents; a druid does when
    -- its profile reads rage or energy (bear, cat).
    local MELEE = { warrior = true, rogue = true, paladin = true }
    local SWING = 2.0             -- a mob's swing, for the rate of its first hits
    local TAKEN_KEEP = 6          -- seconds without a hit before a mob's rate is forgotten
    local ADD_GRACE = 1.0         -- the pull's first second brings the pull, not adds
    local REMEMBER = 20           -- a mob seen this long ago is not an add when it comes back
    local AOE_CAP = 5
    -- In a group: who it is on, and what the group is killing.
    local ON_TANK, ON_HEALER, ON_MEMBER, ON_ME_GROUP, LOOSE_GROUP = 1.0, 1.6, 1.3, 1.3, 0.6
    local ASSIST, SKULL, CROSS = 1.6, 2.5, 1.8
    local MARK_SKULL, MARK_CROSS = 8, 7

    -- --- where an area spell lands ---------------------------------------------------
    --
    -- around the target: a shot or a ground spell, centred where we aim it.
    -- around us: a nova, a clap, a swing at everything in front.
    -- `max` is how many it hits at most (Multi-Shot three, Cleave two).
    local AREA = {
        ["Multi-Shot"] = { at = "target", radius = 8, max = 3 },
        ["Volley"] = { at = "target", radius = 8 },
        ["Chain Lightning"] = { at = "target", radius = 12, max = 3 },
        ["Blizzard"] = { at = "target", radius = 8 },
        ["Flamestrike"] = { at = "target", radius = 8 },
        ["Rain of Fire"] = { at = "target", radius = 8 },
        ["Hurricane"] = { at = "target", radius = 10 },
        ["Seed of Corruption"] = { at = "target", radius = 10 },
        ["Cleave"] = { at = "me", radius = 6, max = 2 },
        ["Swipe"] = { at = "me", radius = 6, max = 3 },
        -- The cat's (411128) strikes every enemy around its target: no cap.
        ["Swipe (Cat)"] = { at = "me", radius = 6 },
        ["Blade Flurry"] = { at = "me", radius = 6, max = 2 },
        ["Whirlwind"] = { at = "me", radius = 8, max = 4 },
        ["Thunder Clap"] = { at = "me", radius = 8, max = 4 },
        ["Arcane Explosion"] = { at = "me", radius = 10 },
        ["Cone of Cold"] = { at = "me", radius = 10 },
        ["Frost Nova"] = { at = "me", radius = 10 },
        ["Blast Wave"] = { at = "me", radius = 10 },
        ["Holy Nova"] = { at = "me", radius = 10 },
        ["Consecration"] = { at = "me", radius = 8 },
        ["Hellfire"] = { at = "me", radius = 10 },
        ["Holy Wrath"] = { at = "me", radius = 20 },
        ["Magma Totem"] = { at = "me", radius = 8 },
        ["Fire Nova Totem"] = { at = "me", radius = 10 },
        ["Explosive Trap"] = { at = "me", radius = 10 },
    }
    T.AREA = AREA

    -- --- crowd control that damage breaks ----------------------------------------------
    --
    -- A stun, a root, a silence leave the mob in the fight (or about to be),
    -- and damage does not end them. Everything else -- polymorph, a fear, a
    -- trap, a sap, a scatter -- takes it OUT of the fight until something
    -- hits it. A control whose kind the client does not say counts as the
    -- breakable kind: waking a sheep is the mistake to avoid.
    local KEEPS_FIGHTING = { "STUN", "STUN_MECHANIC", "ROOT", "SILENCE", "DISARM", "SCHOOL_INTERRUPT",
                             "NONE", "NONE_2", "NONE_3" }
    local fighting_ids = nil
    local function fighting_types()
        if fighting_ids then return fighting_ids end
        local ids, types = {}, P.loc_types
        if type(types) == "table" then
            for i = 1, #KEEPS_FIGHTING do
                local id = types[KEEPS_FIGHTING[i]]
                if type(id) == "number" then ids[id] = true end
            end
        end
        fighting_ids = ids
        return ids
    end

    --- Out of the fight until something hits it: a mob we must not damage.
    ---@param row table|nil an enemies row
    ---@return boolean
    local function out_of_fight(row)
        local c = row and row.control
        if not c then return false end
        -- JCore says it outright where it read the control from a debuff (Forever).
        if c.breaks ~= nil then return c.breaks == true end
        if c.type ~= nil and fighting_types()[c.type] then return false end
        return true
    end
    T.out_of_fight = out_of_fight

    --- A mob's name, for the readout; init.lua replaces this with its own
    --- (JCore's names, which also answer on Forever).
    T.name_of = function(unit)
        local n = unit and units.name and units.name(unit)
        if type(n) == "string" and n ~= "" then return n end
        return "a mob"
    end

    -- --- what each mob does to us -------------------------------------------------------
    --
    -- The combat log names the source of every hit on us and on the pet. A
    -- mob's rate is what it dealt since its first hit, over that time plus a
    -- swing (the hits come at the start of each swing, not the end), so one
    -- hit of 30 reads 15 a second and a steady 30 every two seconds stays 15.
    local taken = {}              -- source guid -> { first, last, total }

    ---@param guid string the source
    ---@param amount number
    function T.taken(guid, amount)
        if type(guid) ~= "string" or type(amount) ~= "number" or amount <= 0 then return end
        local now = core.time()
        local t = taken[guid]
        if not t or (now - t.last) > TAKEN_KEEP then
            t = { first = now, last = now, total = 0 }
            taken[guid] = t
        elseif (now - t.first) > 12 then
            -- A long fight: halve the window, keep the rate, follow a change.
            t.total = t.total * 0.5
            t.first = now - (now - t.first) * 0.5
        end
        t.total = t.total + amount
        t.last = now
    end

    local function measured(guid, now)
        local t = guid and taken[guid]
        if t and (now - t.last) <= TAKEN_KEEP then
            return t.total / ((now - t.first) + SWING)
        end
        -- No combat log on this client (Forever): JCore's rate, from our own
        -- and the pet's health. nil wherever the combat log speaks.
        local es = guid and P.ctx and P.ctx.enemies
        if es and es.damage_rate then
            local ok, r = pcall(es.damage_rate, guid)
            if ok and type(r) == "number" and r > 0 then return r end
        end
        return nil
    end

    -- Said in the readout: where the damage on us was read from.
    local from_health = false
    do
        local w = P.ctx and P.ctx.world
        local ok, c = pcall(function() return w and w.client and w.client() end)
        from_health = ok and type(c) == "table" and c.combat_log == false
    end
    T.measured = function(guid) return measured(guid, core.time()) end

    -- --- the plan ------------------------------------------------------------------------

    local plan = {
        at = -huge, live = false, count = 0,
        order = {},               -- { row, guid, name, hp, frac, on, dps, real, value, out }
        focus = nil, focus_guid = nil, focus_at = -huge,
        add_guid = nil, add_name = nil, add_at = -huge,
        pet_add = nil, pet_held = nil, pet_ok = nil, pet_why = nil,
        their = 0, ttl = huge, ttc = huge, losing = false, on_me = 0,
    }
    T.state = plan

    local seen = {}               -- guid -> first seen this fight
    local recent = {}             -- guid -> last seen engaged, across fights
    local fight_at = nil
    local shape = ""              -- the engaged set last re-plan, to re-plan at once on a change
    local was_losing = false

    local function reset()
        for k in pairs(seen) do seen[k] = nil end
        for k in pairs(taken) do taken[k] = nil end
        fight_at = nil
        plan.live, plan.count, plan.order = false, 0, {}
        plan.focus, plan.focus_guid, plan.focus_at = nil, nil, -huge
        plan.add_guid, plan.add_name, plan.add_at = nil, nil, -huge
        plan.pet_add, plan.pet_held, plan.pet_ok, plan.pet_why = nil, nil, nil, nil
        plan.their, plan.ttl, plan.ttc, plan.losing, plan.on_me = 0, huge, huge, false, 0
        shape, was_losing = "", false
    end
    T.reset = reset

    local function health_points(unit, frac)
        if units.health then
            local ok, hp = pcall(units.health, unit)
            if ok and type(hp) == "number" and hp > 0 then return hp end
        end
        return max(frac or 1, 0.01) * 100
    end

    local function dist3(a, b)
        if not (a and b and a.x and b.x) then return nil end
        local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0)
        return sqrt(dx * dx + dy * dy + dz * dz)
    end

    --- Will the mob the pet holds stay on it if the pet goes to another?
    --- The pet's threat on it does not go with the pet, so it stays -- unless
    --- ours on it is close to the pet's already.
    ---@param held table|nil the enemies row the pet is on
    ---@return boolean
    ---@return string why
    function T.pet_may_leave(held)
        if not held then return true, "the pet is free" end
        local name = T.name_of(held.obj)
        if out_of_fight(held) then return true, string.format("%s is controlled", name) end
        if (held.hp or 1) < 0.25 then return true, string.format("%s is nearly dead", name) end
        local th = held.threat
        local p = type(th) == "table" and tonumber(th.percent) or nil
        if p then
            if p < PET_LEAVE then
                return true, string.format("your threat on %s is %d%%: it stays on the pet", name, floor(p))
            end
            return false, string.format("your threat on %s is %d%%: it would turn on you", name, floor(p))
        end
        if memory and memory.attacked and not memory.attacked(held.guid, 20) then
            return true, string.format("you have not hit %s", name)
        end
        return false, string.format("your threat on %s is unread", name)
    end

    local scratch = {}

    local function build_order(W, now, rows, grouped)
        local pet, en = W.pet, W.enemies
        local G = W.group
        -- The pet's taunt about to land on this mob (react/petthreat.lua).
        local S = W.petthreat
        local function taunt_coming(guid)
            if not (S and S.live and S.name) or S.short or (S.ready_in or 0) > 1.0 then return false end
            for i = 1, #S.list do
                local e = S.list[i]
                if e.guid == guid then return e.reach == true end
            end
            return false
        end
        -- What the tank is hitting: one read per re-plan, in a group only.
        local tank_target = nil
        if grouped and G.tank then
            local ok, t = pcall(G.tank.get_target, G.tank)
            if ok and t then tank_target = units.guid and units.guid(t) or nil end
        end
        local key = W.class and W.class.key
        local hunter = key == "hunter"
        local kind = W.player.power_kind
        local melee = MELEE[key] == true or (key == "druid" and (kind == "RAGE" or kind == "ENERGY"))
        local healing = {}
        for i = 1, en.casting_n or 0 do
            local c = en.casting[i]
            if c and c.guid and c.kind == "heal" then healing[c.guid] = true end
        end

        -- What the mobs we have measured hit for: the guess for one that has
        -- not hit anything yet (same zone, same level, most of the time).
        local sum, n = 0, 0
        for i = 1, #rows do
            local d = measured(rows[i].guid, now)
            if d then sum, n = sum + d, n + 1 end
        end
        local guess = n > 0 and (sum / n) or nil
        if not guess then
            local fs = P.field and P.field.state
            local their = fs and tonumber(fs.their_dps) or 0
            if their > 0 then guess = their / max(1, en.on_me or 1) end
        end
        if not guess then
            local fs = P.field and P.field.state
            local mine = fs and tonumber(fs.my_hp) or 0
            local hp = W.player.hp or 1
            -- A mob of our level alone takes about half a minute to kill us.
            guess = (mine > 0 and hp > 0) and (mine / hp) / 30 or 10
        end

        local order = {}
        for i = 1, #rows do
            local r = rows[i]
            local frac = r.hp or 1
            local hp = health_points(r.obj, frac)
            local on = "none"
            if r.targeting_me then
                on = "me"
            elseif r.targeting_pet then
                on = "pet"
            elseif r.target_guid and world.in_group and world.in_group(r.target_guid) then
                on = "group"
                if grouped and r.target_guid == G.tank_guid then
                    on = "tank"
                elseif grouped and r.target_guid == G.healer_guid then
                    on = "healer"
                end
            end
            local dps, real = measured(r.guid, now), true
            if not dps then
                dps, real = guess, false
                local f = world.facts and world.facts(r.obj, r.guid)
                if f and f.elite then dps = dps * 2.5 end
            end
            local weight = (on == "me" and 1) or (on == "pet" and ((pet.hp or 1) < PET_FIT and 0.9 or 0.5))
                or (on == "group" and 0.6) or 0.3
            local assist, mark, threat_p = false, nil, nil
            if grouped then
                weight = (on == "tank" and ON_TANK) or (on == "healer" and ON_HEALER)
                    or (on == "group" and ON_MEMBER) or (on == "me" and ON_ME_GROUP)
                    or (on == "pet" and 0.5) or LOOSE_GROUP
                -- Everyone on one mob kills it soonest: the tank's target first.
                if tank_target and r.guid == tank_target then
                    assist = true
                    weight = weight * ASSIST
                end
                local ok_m, m = pcall(r.obj.get_target_marker_index, r.obj)
                if ok_m and m == MARK_SKULL then
                    mark, weight = "skull", weight * SKULL
                elseif ok_m and m == MARK_CROSS then
                    mark, weight = "cross", weight * CROSS
                end
                -- Our threat on it, against the tank's: close to 100 it turns on us.
                local th = r.threat
                threat_p = type(th) == "table" and tonumber(th.percent) or nil
                if threat_p then
                    if threat_p >= 95 then
                        weight = weight * 0.1
                    else
                        weight = weight * max(0.2, 1 - threat_p / 130)
                    end
                end
            elseif on == "pet" and S and S.live and S.name then
                -- Solo, a mob on a pet that taunts: ours on it close to the
                -- pet's, and the next shots would pull it. Something else
                -- first, for a moment.
                local th = r.threat
                threat_p = type(th) == "table" and tonumber(th.percent) or nil
                if threat_p and threat_p >= 75 and not taunt_coming(r.guid) then
                    weight = weight * (threat_p >= 90 and 0.4 or 0.7)
                end
            end
            -- How much of our damage can land on it from here. A hunter shoots
            -- past a mob hitting it in melee; the one inside the dead zone gets
            -- only the melee strikes. A melee class does not run off after a
            -- caster thirty yards away that is not coming, while the one in
            -- front of it is nearly as urgent.
            local reach = 1
            local dist = r.dist or huge
            -- Hitbox to hitbox, as the client measures it (rotation.lua H.gap).
            local Hh = P.rotation and P.rotation.helpers
            local edge = (Hh and Hh.gap) and Hh.gap(r.obj, dist) or dist
            if dist > FAR then
                reach = 0.3
            elseif hunter and edge < DEAD_ZONE and on ~= "pet" then
                reach = 0.6
            elseif melee and edge > MELEE_REACH - 3 and (r.closing or 0) <= 0.5 then
                reach = 0.7
            end
            local boost = healing[r.guid] and 1.5 or 1
            local out = out_of_fight(r)
            order[#order + 1] = {
                row = r, guid = r.guid, obj = r.obj, hp = hp, frac = frac, on = on,
                dps = dps, real = real, out = out, assist = assist, mark = mark, threat_p = threat_p,
                value = out and -1 or (dps * weight * reach * boost / max(hp, 1)),
            }
        end
        table.sort(order, function(a, b)
            if a.value ~= b.value then return a.value > b.value end
            return a.hp < b.hp
        end)
        return order
    end

    local function entry_for(order, guid)
        if not guid then return nil end
        for i = 1, #order do
            if order[i].guid == guid then return order[i] end
        end
        return nil
    end

    local function on_text(e)
        if e.on == "me" then return "on you" end
        if e.on == "pet" then return "on the pet" end
        if e.on == "group" then return "on the group" end
        if e.on == "tank" then return "on the tank" end
        if e.on == "healer" then return "on the healer" end
        return "loose"
    end
    T.on_text = on_text

    --- Re-plans the fight from a freshly built world state. Writes W.plan and
    --- W.sit.outnumbered; returns the journal lines for what changed.
    ---@param W table
    ---@param now number
    ---@return string[]
    function T.update(W, now)
        local lines = {}
        W.plan = plan
        local pl, en, pet = W.player, W.enemies, W.pet

        if not pl.in_combat then
            if fight_at then reset() end
            W.sit.outnumbered = false
            return lines
        end
        fight_at = fight_at or now

        -- Solo, or a damage dealer in a group with a living tank; a group
        -- whose tank is dead is fought as solo. The tank and the healer keep
        -- their own targeting.
        local G = W.group
        local solo_like = W.env.solo == true or (G.in_group and not G.tank_alive)
        local grouped = not solo_like and G.in_group == true and G.tank_alive == true
            and not pl.is_tank and not (pl.guid ~= nil and pl.guid == G.healer_guid)

        -- The engaged mobs, alive; in a group, everything fighting the group.
        local rows = scratch
        for i = #rows, 1, -1 do rows[i] = nil end
        local list, n = en.list or {}, en.count or 0
        local key = {}
        for i = 1, n do
            local r = list[i]
            local ours = r and (r.engaged or (grouped and r.in_combat and r.target_guid ~= nil
                and world.in_group and world.in_group(r.target_guid)))
            if ours and r.obj and r.guid and r.activity ~= "dead" and (r.hp or 1) > 0 then
                rows[#rows + 1] = r
                key[#key + 1] = r.guid
            end
        end
        local count = #rows

        -- The add: something engaged after the pull that we have not met.
        for i = 1, count do
            local r = rows[i]
            if not seen[r.guid] then
                seen[r.guid] = now
                if (now - fight_at) > ADD_GRACE and not (recent[r.guid] and (now - recent[r.guid]) < REMEMBER) then
                    plan.add_guid, plan.add_at = r.guid, now
                    plan.add_name = T.name_of(r.obj)
                end
            end
            recent[r.guid] = now
        end
        for guid, at in pairs(recent) do
            if (now - at) > REMEMBER then recent[guid] = nil end
        end

        table.sort(key)
        local new_shape = table.concat(key, ",")
        if new_shape == shape and (now - plan.at) < EVERY and plan.count == count then
            W.sit.outnumbered = plan.losing
            return lines
        end
        local shape_changed = new_shape ~= shape
        shape = new_shape
        plan.at, plan.count = now, count

        plan.live = (solo_like or grouped) and count >= 2
        plan.mode = grouped and "group" or "solo"
        if not plan.live then
            plan.order = {}
            plan.focus, plan.focus_guid = nil, nil
            plan.pet_add, plan.pet_held, plan.pet_ok, plan.pet_why = nil, nil, nil, nil
            plan.losing, plan.on_me = false, 0
            W.sit.outnumbered = false
            if was_losing then lines[#lines + 1] = "no longer outnumbered" end
            was_losing = false
            return lines
        end

        local order = build_order(W, now, rows, grouped)
        plan.order = order

        -- WHO DIES FIRST. The most urgent candidate, unless the one we are on
        -- is nearly as urgent: a switch costs a global cooldown, the mark, and
        -- the damage already on it.
        local best = nil
        for i = 1, #order do
            if not order[i].out then best = order[i] break end
        end
        local previous = plan.focus_guid
        local chosen = nil
        -- The group's margins guard a focus the plan already holds; the
        -- fight's first choice is made as solo (the tank's target, a skull).
        local switch, settle = SWITCH, SETTLE
        if grouped and previous ~= nil then switch, settle = SWITCH_GROUP, SETTLE_GROUP end
        if best then
            local kept = entry_for(order, previous)
            if kept and not kept.out and (now - plan.focus_at) < settle then
                chosen = kept
            else
                local incumbent = entry_for(order, W.target.guid)
                if not incumbent or incumbent.out then incumbent = kept end
                if incumbent and incumbent.out then incumbent = nil end
                if incumbent and best ~= incumbent and best.value <= incumbent.value * switch then
                    chosen = incumbent
                else
                    chosen = best
                end
            end
        end
        plan.focus = chosen and chosen.obj or nil
        plan.focus_guid = chosen and chosen.guid or nil
        if plan.focus_guid ~= previous then plan.focus_at = now end

        -- WHO HOLDS WHAT. Solo with a pet that can take more: the add on us
        -- that we are not killing goes to the pet, if what it holds stays.
        plan.pet_add, plan.pet_held, plan.pet_ok, plan.pet_why = nil, nil, nil, nil
        local pets = P.pet
        local pet_mode_ok = not (pets and pet.mode and (pet.mode == pets.OFF or pet.mode == pets.FOCUS))
        -- A pet that taunts (Growl, Torment): it can take a mob off you and hold it.
        local taunting = W.petthreat ~= nil and W.petthreat.live == true and W.petthreat.name ~= nil
        if pet.alive and pet_mode_ok and not grouped then
            for i = 1, #order do
                local e = order[i]
                if pet.target_guid and e.guid == pet.target_guid then plan.pet_held = e.row end
                -- The one to kill first too, when the pet taunts: it is killed
                -- once it is on the pet, not while it is on you.
                if not plan.pet_add and e.on == "me" and not e.out and (taunting or e.guid ~= plan.focus_guid)
                    and e.guid ~= pet.target_guid then
                    plan.pet_add = e.row
                end
            end
            if plan.pet_add then
                if (pet.hp or 1) < PET_FIT then
                    plan.pet_ok, plan.pet_why = false, string.format("the pet is at %d%%", pct(pet.hp))
                elseif pet.target_guid and not plan.pet_held then
                    plan.pet_ok, plan.pet_why = false, "the pet is on something out of sight"
                else
                    plan.pet_ok, plan.pet_why = T.pet_may_leave(plan.pet_held)
                    -- WHAT IS HITTING YOU COMES FIRST (1.68.0). The mob the pet
                    -- leaves keeps the pet's threat; the kill order stops
                    -- shooting it while ours is close (above).
                    if not plan.pet_ok and taunting and plan.pet_held then
                        local add = plan.pet_add
                        local Hh = P.rotation and P.rotation.helpers
                        local melee = (Hh and Hh.in_melee and Hh.in_melee(add.obj, add.dist))
                            or (add.dist or huge) <= 5
                        local hp = W.player.hp or 1
                        if melee or hp < 0.6 then
                            plan.pet_ok = true
                            plan.pet_why = string.format("%s is %s: the pet takes it, %s stays on the pet's threat",
                                T.name_of(add.obj),
                                melee and "hitting you in melee" or string.format("on you at %d%%", pct(hp)),
                                T.name_of(plan.pet_held.obj))
                        end
                    end
                end
            end
        end

        -- THE RACE, WITH EVERY MOB COUNTED. The field measures the damage we
        -- take from our own health bar, which needs seconds to show an add.
        -- Each mob on us is counted from its first hit instead.
        local their, real, on_me = 0, 0, 0
        for i = 1, #order do
            local e = order[i]
            if e.on == "me" and not e.out then
                their = their + e.dps
                if e.real then real = real + e.dps end
                on_me = on_me + 1
            end
        end
        local fs = P.field and P.field.state
        local my_hp = fs and tonumber(fs.my_hp) or 0
        plan.their, plan.on_me = their, on_me
        plan.ttl = (their > 0 and my_hp > 0) and (my_hp / their) or huge
        plan.ttc = W.field.time_to_clear or huge
        -- In a group the healer is the other half of that race: not ours to call.
        plan.losing = not grouped and their > 0 and real >= their * 0.5 and plan.ttl < RUNWAY
            and plan.ttc < huge and (plan.ttl * MARGIN) < plan.ttc
        W.sit.outnumbered = plan.losing

        -- What changed, in words, for the journal.
        local focus_entry = chosen
        local function first_text()
            if not focus_entry then return "nothing to focus (all controlled)" end
            return string.format("kill %s first (%d%%, %s)", T.name_of(focus_entry.obj),
                pct(focus_entry.frac), on_text(focus_entry))
        end
        if plan.add_guid and plan.add_at == now then
            lines[#lines + 1] = string.format("%s joined: %d in the fight -- %s", plan.add_name or "a mob",
                count, first_text())
        elseif previous == nil and shape_changed then
            lines[#lines + 1] = string.format("%d in the fight -- %s", count, first_text())
        elseif plan.focus_guid ~= previous and focus_entry then
            lines[#lines + 1] = "kill order: " .. first_text()
        end
        if plan.losing and not was_losing then
            lines[#lines + 1] = string.format("outnumbered: %d on you, %.0fs to live against %.0fs to clear",
                on_me, plan.ttl, plan.ttc)
        elseif was_losing and not plan.losing then
            lines[#lines + 1] = "no longer outnumbered"
        end
        was_losing = plan.losing
        return lines
    end

    --- The unit to kill first, while there is a plan for this fight.
    ---@return game_object|nil focus
    ---@return boolean live
    function T.focus()
        local W = world.W
        if not plan.live or not W or math.abs(core.time() - plan.at) > 1.0 then return nil, false end
        local f = plan.focus
        if f then
            local ok, valid = pcall(f.is_valid, f)
            if not ok or not valid then return nil, true end
            local ok_d, dead = pcall(f.is_dead, f)
            if ok_d and dead then return nil, true end
        end
        return f, true
    end

    -- --- what an area spell reaches ------------------------------------------------------

    local reach_cache, reach_at = {}, -1

    --- How many engaged mobs this area spell would hit, aimed at `target`;
    --- the name of a controlled mob it would wake, and of an idle one it
    --- would pull. nil when the spell is not an area spell we can place.
    ---@param name string
    ---@param cat_row table|nil its catalogue row
    ---@param target game_object|nil
    ---@return integer|nil count
    ---@return string|nil wakes
    ---@return string|nil pulls
    function T.reach(name, cat_row, target)
        local W = world.W
        if not W or not W.enemies or type(name) ~= "string" then return nil end
        local area = AREA[name]
        if not area then
            local aoe = false
            if cat_row and cat_row.roles then
                for i = 1, #cat_row.roles do if cat_row.roles[i] == "aoe" then aoe = true end end
            end
            if not aoe then return nil end
            area = { at = (cat_row.range == "ranged") and "target" or "me", radius = 8 }
        end
        local cap = area.max or (cat_row and cat_row.damage and tonumber(cat_row.damage.targets)) or AOE_CAP

        -- rawequal, never ~=: a game object compares through the client's
        -- own __eq, which raises once either side has gone stale (1.48.2).
        local tguid = (target and not rawequal(target, W.player.unit)) and units.guid and units.guid(target) or nil
        local key = name .. "|" .. tostring(tguid)
        if reach_at ~= W.now then reach_cache, reach_at = {}, W.now end
        local hit = reach_cache[key]
        if hit then return hit[1], hit[2], hit[3] end

        local en = W.enemies
        local list, n = en.list or {}, en.count or 0
        local count, wakes, pulls = nil, nil, nil
        if n == 0 then
            count = min(max(en.engaged or 0, 0), cap)
        else
            local centre = nil
            if area.at == "target" then
                if tguid then
                    for i = 1, n do
                        local r = list[i]
                        if r and r.guid == tguid then centre = r break end
                    end
                end
                if not centre or not centre.x then
                    count = min(max(en.engaged or 0, 0), cap)
                end
            end
            if not count then
                count = 0
                for i = 1, n do
                    local r = list[i]
                    if r and r.obj and r.activity ~= "dead" then
                        local d
                        if centre then d = dist3(r, centre) else d = r.dist end
                        if d and d <= area.radius then
                            if r.engaged then
                                if out_of_fight(r) then
                                    wakes = wakes or T.name_of(r.obj)
                                else
                                    count = count + 1
                                end
                            elseif not r.in_combat and r ~= centre then
                                pulls = pulls or T.name_of(r.obj)
                            end
                        end
                    end
                end
                count = min(count, cap)
            end
        end
        reach_cache[key] = { count, wakes, pulls }
        return count, wakes, pulls
    end

    -- --- the readout -----------------------------------------------------------------------

    --- The plan in words: at most two lines, none with fewer than two engaged.
    ---@param now number
    ---@return string[]
    function T.lines(now)
        local out = {}
        if not plan.live or #plan.order < 2 then return out end
        local parts = {}
        for i = 1, min(#plan.order, 3) do
            local e = plan.order[i]
            if e.out then
                parts[#parts + 1] = string.format("%s (controlled: leave it)", T.name_of(e.obj))
            else
                local tags = on_text(e)
                if e.assist then tags = tags .. ", the tank's target" end
                if e.mark then tags = tags .. ", " .. e.mark end
                if e.threat_p and e.threat_p >= 80 then tags = tags .. string.format(", your threat %d%%", floor(e.threat_p)) end
                parts[#parts + 1] = string.format("%s (%d%%, %s)", T.name_of(e.obj), pct(e.frac), tags)
            end
        end
        local joined = ""
        if plan.add_name and (now - plan.add_at) < 30 then
            joined = string.format(" (%s joined %.0fs ago)", plan.add_name, now - plan.add_at)
        end
        local group = plan.mode == "group"
        out[1] = string.format("Plan%s: %d in the fight%s -- kill %s", group and " (group)" or "", plan.count, joined,
            table.concat(parts, ", then "))
        if group then
            out[2] = "  group: the tank's target and the marks first, the healer's attackers next, nothing you would pull off the tank"
            return out
        end
        local second = {}
        if plan.pet_add then
            second[#second + 1] = string.format("pet %s %s: %s", plan.pet_ok and "takes" or "leaves",
                T.name_of(plan.pet_add.obj), plan.pet_why or "?")
        end
        local function secs(v) return v == huge and "--" or string.format("%.0fs", v) end
        second[#second + 1] = string.format("race: %s to live, %s to clear%s%s", secs(plan.ttl), secs(plan.ttc),
            from_health and " (their damage read from your health)" or "",
            plan.losing and " -- OUTNUMBERED" or "")
        out[2] = "  " .. table.concat(second, " | ")
        return out
    end

    return T
end
